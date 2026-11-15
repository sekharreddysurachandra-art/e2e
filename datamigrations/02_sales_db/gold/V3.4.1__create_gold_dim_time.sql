-- =============================================================================
-- V3.4.1 : Gold DIM_TIME - minute-of-day dimension (1,440 rows + unknown)
-- Why     : sales headers carry a transaction timestamp; time-of-day analysis
--           (hour, day part, peak minutes) needs a small separate dimension.
--           Kept apart from DIM_DATE (a combined date-time table would hold
--           ~16 million rows). Regular table, loaded once - a generated
--           sequence cannot be a dynamic table.
-- Key     : TIME_SK = HHMM as a number (0 = 00:00 .. 2359 = 23:59), -1 = unknown.
-- Usage   : facts join on the LOCAL transaction time (Silver
--           SALES_HEADER.TRANSACTION_TIMESTAMP_LOCAL), so day parts reflect the
--           customer's local clock. CHANGE_TRACKING is on for incremental facts.
-- DEV/QA tables are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.DIM_TIME (  -- create only if missing
  TIME_SK          NUMBER(4,0)  NOT NULL COMMENT 'Time key HHMM (0 = 00:00 .. 2359 = 23:59, -1 = unknown)',
  TIME_OF_DAY      TIME                  COMMENT 'Time of day at minute precision (NULL for the unknown member)',
  TIME_LABEL       VARCHAR(5)            COMMENT 'Time as HH:MM (24-hour clock)',
  HOUR_24          NUMBER(2,0)           COMMENT 'Hour of day (0-23)',
  HOUR_12          NUMBER(2,0)           COMMENT 'Hour on the 12-hour clock (1-12)',
  AM_PM            VARCHAR(2)            COMMENT 'AM or PM',
  HOUR_LABEL       VARCHAR(5)            COMMENT 'Hour bucket as HH:00',
  MINUTE_OF_HOUR   NUMBER(2,0)           COMMENT 'Minute of the hour (0-59)',
  MINUTE_OF_DAY    NUMBER(4,0)           COMMENT 'Minute of the day (0-1439)',
  QUARTER_HOUR     VARCHAR(5)            COMMENT 'Start of the 15-minute bucket as HH:MM',
  DAY_PART         VARCHAR(9)            COMMENT 'Night 00-05, Morning 06-11, Afternoon 12-17, Evening 18-23',
  CONSTRAINT PK_DIM_TIME PRIMARY KEY (TIME_SK)
)
  CHANGE_TRACKING = TRUE                   -- lets Gold fact dynamic tables refresh incrementally
  COMMENT = 'Time-of-day dimension at minute grain, key TIME_SK = HHMM';

INSERT INTO SALES_{{ env }}.GOLD.DIM_TIME
WITH minutes AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS M
  FROM TABLE(GENERATOR(ROWCOUNT => 1440))
)
SELECT
  FLOOR(M / 60) * 100 + MOD(M, 60)                                  AS TIME_SK,
  TIMEADD(MINUTE, M, '00:00:00'::TIME)                              AS TIME_OF_DAY,
  TO_CHAR(TIMEADD(MINUTE, M, '00:00:00'::TIME), 'HH24:MI')          AS TIME_LABEL,
  FLOOR(M / 60)                                                     AS HOUR_24,
  IFF(MOD(FLOOR(M / 60), 12) = 0, 12, MOD(FLOOR(M / 60), 12))       AS HOUR_12,
  IFF(FLOOR(M / 60) < 12, 'AM', 'PM')                               AS AM_PM,
  LPAD(FLOOR(M / 60)::VARCHAR, 2, '0') || ':00'                     AS HOUR_LABEL,
  MOD(M, 60)                                                        AS MINUTE_OF_HOUR,
  M                                                                 AS MINUTE_OF_DAY,
  LPAD(FLOOR(M / 60)::VARCHAR, 2, '0') || ':'
    || LPAD((FLOOR(MOD(M, 60) / 15) * 15)::VARCHAR, 2, '0')         AS QUARTER_HOUR,
  CASE WHEN FLOOR(M / 60) < 6  THEN 'Night'
       WHEN FLOOR(M / 60) < 12 THEN 'Morning'
       WHEN FLOOR(M / 60) < 18 THEN 'Afternoon'
       ELSE 'Evening' END                                           AS DAY_PART
FROM minutes
UNION ALL   -- unknown member for facts without a valid time
SELECT -1, NULL, 'Unk', NULL, NULL, NULL, 'Unk', NULL, NULL, 'Unk', 'Unknown';

-- Post-deploy check (must return 1441):
-- SELECT COUNT(DISTINCT TIME_SK) FROM SALES_{{ env }}.GOLD.DIM_TIME;
