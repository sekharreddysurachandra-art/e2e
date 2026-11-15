-- =============================================================================
-- V3.4.0 : Gold DIM_DATE - fixed calendar 2015-01-01 .. 2044-12-31 (30 years)
-- Why     : sales analytics needs every day (also days without sales), complete
--           fiscal years and the same calendar in DEV/QA/PROD, so the range is
--           fixed instead of following the sales min/max. A generated calendar
--           cannot be a dynamic table (SEQ4/GENERATOR are not change-trackable),
--           so this is a regular table loaded once; extend it with a new script.
-- Key     : DATE_SK = YYYYMMDD (deterministic, readable, sortable). -1 = unknown
--           date member for facts with a missing / out-of-range date.
-- Fiscal  : Apple fiscal calendar - the fiscal year ends on the last Saturday of
--           September (52 or 53 weeks); quarters are 13 weeks, Q1 has 14 weeks
--           in a 53-week year. FISCAL_YEAR is named after the year it ends in.
-- Lineage : Gold fact dynamic tables join DIM_DATE on CALENDAR_DATE = local
--           transaction date and store DATE_SK, so DIM_DATE -> FACT shows in the
--           dynamic table graph. CHANGE_TRACKING is on for incremental facts.
-- DEV/QA tables are TRANSIENT; PROD is permanent.
-- =============================================================================
{% set transient = 'TRANSIENT ' if env in ['DEV', 'QA'] else '' %}

CREATE {{ transient }}TABLE IF NOT EXISTS SALES_{{ env }}.GOLD.DIM_DATE (  -- create only if missing
  DATE_SK               NUMBER(8,0)  NOT NULL COMMENT 'Date key YYYYMMDD (-1 = unknown date)',
  CALENDAR_DATE         DATE                  COMMENT 'Calendar date (NULL for the unknown member)',
  DAY_OF_WEEK_ISO       NUMBER(1,0)           COMMENT 'ISO day of week (1 = Monday .. 7 = Sunday)',
  DAY_NAME              VARCHAR(9)            COMMENT 'Day name (Monday .. Sunday)',
  DAY_NAME_SHORT        VARCHAR(3)            COMMENT 'Short day name (Mon .. Sun)',
  IS_WEEKEND            BOOLEAN               COMMENT 'TRUE for Saturday and Sunday',
  DAY_OF_MONTH          NUMBER(2,0)           COMMENT 'Day of the month (1-31)',
  DAY_OF_YEAR           NUMBER(3,0)           COMMENT 'Day of the calendar year (1-366)',
  ISO_WEEK              NUMBER(2,0)           COMMENT 'ISO week of the year (1-53)',
  ISO_YEAR              NUMBER(4,0)           COMMENT 'ISO week-numbering year',
  WEEK_START_DATE       DATE                  COMMENT 'Monday of the ISO week',
  MONTH_NUMBER          NUMBER(2,0)           COMMENT 'Calendar month (1-12)',
  MONTH_NAME            VARCHAR(9)            COMMENT 'Month name (January .. December)',
  MONTH_NAME_SHORT      VARCHAR(3)            COMMENT 'Short month name (Jan .. Dec)',
  YEAR_MONTH            VARCHAR(7)            COMMENT 'Calendar year and month (YYYY-MM)',
  MONTH_START_DATE      DATE                  COMMENT 'First day of the calendar month',
  MONTH_END_DATE        DATE                  COMMENT 'Last day of the calendar month',
  IS_MONTH_END          BOOLEAN               COMMENT 'TRUE on the last day of the calendar month',
  QUARTER_NUMBER        NUMBER(1,0)           COMMENT 'Calendar quarter (1-4)',
  YEAR_QUARTER          VARCHAR(7)            COMMENT 'Calendar year and quarter (YYYY-Q1)',
  QUARTER_START_DATE    DATE                  COMMENT 'First day of the calendar quarter',
  QUARTER_END_DATE      DATE                  COMMENT 'Last day of the calendar quarter',
  CALENDAR_YEAR         NUMBER(4,0)           COMMENT 'Calendar year',
  FISCAL_YEAR           NUMBER(4,0)           COMMENT 'Apple fiscal year (ends last Saturday of September)',
  FISCAL_YEAR_START_DATE DATE                 COMMENT 'First day of the fiscal year',
  FISCAL_YEAR_END_DATE  DATE                  COMMENT 'Last day of the fiscal year (last Saturday of September)',
  FISCAL_WEEKS_IN_YEAR  NUMBER(2,0)           COMMENT '52 or 53 weeks in the fiscal year',
  FISCAL_WEEK           NUMBER(2,0)           COMMENT 'Fiscal week of the year (1-53)',
  FISCAL_QUARTER        NUMBER(1,0)           COMMENT 'Fiscal quarter (13-week quarters, Q1 = 14 weeks in 53-week years)',
  FISCAL_YEAR_QUARTER   VARCHAR(9)            COMMENT 'Fiscal year and quarter (FY2019-Q1)',
  FISCAL_DAY_OF_YEAR    NUMBER(3,0)           COMMENT 'Day of the fiscal year (1-371)',
  CONSTRAINT PK_DIM_DATE PRIMARY KEY (DATE_SK),
  CONSTRAINT UK_DIM_DATE_CALENDAR_DATE UNIQUE (CALENDAR_DATE)
)
  CHANGE_TRACKING = TRUE                   -- lets Gold fact dynamic tables refresh incrementally
  COMMENT = 'Date dimension 2015-2044: calendar and Apple fiscal calendar, key DATE_SK = YYYYMMDD';

INSERT INTO SALES_{{ env }}.GOLD.DIM_DATE
WITH days AS (
  SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2015-01-01'::DATE) AS D
  FROM TABLE(GENERATOR(ROWCOUNT => 12000))
  QUALIFY D <= '2044-12-31'::DATE
),
fy AS (   -- fiscal year end = last Saturday of September of the date's year or the next
  SELECT
    D,
    DATE_FROM_PARTS(YEAR(D), 9, 30)
      - MOD(DAYOFWEEKISO(DATE_FROM_PARTS(YEAR(D), 9, 30)) + 1, 7)          AS FYE_THIS,
    DATE_FROM_PARTS(YEAR(D) + 1, 9, 30)
      - MOD(DAYOFWEEKISO(DATE_FROM_PARTS(YEAR(D) + 1, 9, 30)) + 1, 7)      AS FYE_NEXT,
    DATE_FROM_PARTS(YEAR(D) - 1, 9, 30)
      - MOD(DAYOFWEEKISO(DATE_FROM_PARTS(YEAR(D) - 1, 9, 30)) + 1, 7)      AS FYE_PREV
  FROM days
),
f AS (
  SELECT
    D,
    IFF(D <= FYE_THIS, YEAR(D), YEAR(D) + 1)                               AS FISCAL_YEAR,
    IFF(D <= FYE_THIS, FYE_PREV, FYE_THIS) + 1                             AS FY_START,
    IFF(D <= FYE_THIS, FYE_THIS, FYE_NEXT)                                 AS FY_END
  FROM fy
),
g AS (
  SELECT
    f.*,
    (DATEDIFF(DAY, FY_START, FY_END) + 1) / 7                              AS WEEKS_IN_FY,
    FLOOR(DATEDIFF(DAY, FY_START, D) / 7) + 1                              AS FISCAL_WEEK
  FROM f
)
SELECT
  TO_NUMBER(TO_CHAR(D, 'YYYYMMDD'))                                        AS DATE_SK,
  D                                                                        AS CALENDAR_DATE,
  DAYOFWEEKISO(D)                                                          AS DAY_OF_WEEK_ISO,
  DECODE(DAYOFWEEKISO(D), 1, 'Monday', 2, 'Tuesday', 3, 'Wednesday', 4, 'Thursday',
                          5, 'Friday', 6, 'Saturday', 7, 'Sunday')         AS DAY_NAME,
  DAYNAME(D)                                                               AS DAY_NAME_SHORT,
  DAYOFWEEKISO(D) IN (6, 7)                                                AS IS_WEEKEND,
  DAY(D)                                                                   AS DAY_OF_MONTH,
  DAYOFYEAR(D)                                                             AS DAY_OF_YEAR,
  WEEKISO(D)                                                               AS ISO_WEEK,
  YEAROFWEEKISO(D)                                                         AS ISO_YEAR,
  D - (DAYOFWEEKISO(D) - 1)                                                AS WEEK_START_DATE,
  MONTH(D)                                                                 AS MONTH_NUMBER,
  TO_CHAR(D, 'MMMM')                                                       AS MONTH_NAME,
  MONTHNAME(D)                                                             AS MONTH_NAME_SHORT,
  TO_CHAR(D, 'YYYY-MM')                                                    AS YEAR_MONTH,
  DATE_TRUNC('MONTH', D)                                                   AS MONTH_START_DATE,
  LAST_DAY(D)                                                              AS MONTH_END_DATE,
  D = LAST_DAY(D)                                                          AS IS_MONTH_END,
  QUARTER(D)                                                               AS QUARTER_NUMBER,
  YEAR(D) || '-Q' || QUARTER(D)                                            AS YEAR_QUARTER,
  DATE_TRUNC('QUARTER', D)                                                 AS QUARTER_START_DATE,
  LAST_DAY(D, 'QUARTER')                                                   AS QUARTER_END_DATE,
  YEAR(D)                                                                  AS CALENDAR_YEAR,
  FISCAL_YEAR,
  FY_START                                                                 AS FISCAL_YEAR_START_DATE,
  FY_END                                                                   AS FISCAL_YEAR_END_DATE,
  WEEKS_IN_FY                                                              AS FISCAL_WEEKS_IN_YEAR,
  FISCAL_WEEK,
  CASE WHEN FISCAL_WEEK <= 13 + (WEEKS_IN_FY - 52)      THEN 1
       WHEN FISCAL_WEEK <= 26 + (WEEKS_IN_FY - 52)      THEN 2
       WHEN FISCAL_WEEK <= 39 + (WEEKS_IN_FY - 52)      THEN 3
       ELSE 4 END                                                          AS FISCAL_QUARTER,
  'FY' || FISCAL_YEAR || '-Q' || FISCAL_QUARTER                            AS FISCAL_YEAR_QUARTER,
  DATEDIFF(DAY, FY_START, D) + 1                                           AS FISCAL_DAY_OF_YEAR
FROM g
UNION ALL   -- unknown member for facts without a valid date
SELECT -1, NULL, NULL, 'Unknown', 'Unk', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Unknown', 'Unk',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL;

-- Post-deploy checks (both must return 0 rows):
-- SELECT DATE_SK FROM SALES_{{ env }}.GOLD.DIM_DATE GROUP BY DATE_SK HAVING COUNT(*) > 1;
-- SELECT FISCAL_YEAR, FISCAL_YEAR_END_DATE FROM SALES_{{ env }}.GOLD.DIM_DATE
--  WHERE FISCAL_YEAR IN (2019, 2020, 2022, 2023)
--    AND FISCAL_YEAR_END_DATE NOT IN ('2019-09-28', '2020-09-26', '2022-09-24', '2023-09-30')
--  GROUP BY 1, 2;
