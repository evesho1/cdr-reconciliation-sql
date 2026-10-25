-- =============================================================================
-- CDR Reconciliation Script (MySQL)
-- Workflow:
--   1. Load the LCL and CDR CSVs into staging tables (full month)
--   2. Normalize phone number formats (Callee has a prefix in front of the
--      same 13-digit MSISDN that B_NUM uses) and parse dates/numbers - restricted
--      to June 1-3 (see @date_start/@date_end_exclusive below) so the cleaned
--      tables, indexes, and joins only ever operate on a few days of data
--   3. Drop the stray header-as-data row(s) found in the CDR file
--   4. Check for duplicate-key blowup risk before joining
--   5. Run the three comparison sets. A_NUM/Caller turned out not to be the same field
--      (A_NUM looks like an internal trunk/route code, not the CDR's Caller - see the
--      diagnostic queries in step 4), so B_NUM/Callee is the real join key; A_NUM/Caller
--      agreement is reported as an informational flag instead:
--       Set 1: B_NUM/Callee            (A_NUM = Caller flagged, not required)
--       Set 2: B_NUM/Callee/Duration   (A_NUM = Caller flagged, not required)
--       Set 3: Call time               vs Begin time   (built on Set 2)
--
-- Requirements:
--   - MySQL 8.0+ (uses REGEXP_REPLACE, REGEXP)
--   - local_infile enabled on both server and client:
--       SET GLOBAL local_infile = 1;
--       mysql --local-infile=1 -u <user> -p < cdr_reconciliation.sql
--   - Input files placed in a local data/ folder (not included in this repo)
-- =============================================================================

CREATE DATABASE IF NOT EXISTS cdr_reconciliation;
USE cdr_reconciliation;

-- Restrict to June 1-3 only: applied inside the cleaning step below (step 3) so the
-- date check happens before the normalization expressions run, not after - rows
-- outside this range never get the (relatively expensive) regex/cast work done on them.
-- Change these two values to adjust the window.
SET @date_start = '2025-06-01';
SET @date_end_exclusive = '2025-06-04';  -- through end of June 3rd

-- -----------------------------------------------------------------------------
-- 1. Staging tables - raw load, text columns so malformed rows don't error out
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS lcl_staging;
CREATE TABLE lcl_staging (
    CALLDATE     VARCHAR(20),
    CALLTIME     VARCHAR(20),
    A_NUM        VARCHAR(50),
    B_NUM        VARCHAR(50),
    DURATION     VARCHAR(20),
    IN_NOP_NAME  VARCHAR(50),
    OG_NOP_NAME  VARCHAR(50)
);

DROP TABLE IF EXISTS cdr_staging;
CREATE TABLE cdr_staging (
    Caller        VARCHAR(50),
    Callee        VARCHAR(50),
    Begin_time    VARCHAR(30),
    End_time      VARCHAR(30),
    Call_duration VARCHAR(20)
);

-- -----------------------------------------------------------------------------
-- 2. Load CSVs
--    Note: the CDR export has at least one malformed line with extra
--    fields (17 instead of 5). LOAD DATA will take
--    the first 5 comma-separated values for that line rather than erroring -
--    check the row counts below if results look off.
-- -----------------------------------------------------------------------------
LOAD DATA LOCAL INFILE 'data/lcl_june_2025.csv'
INTO TABLE lcl_staging
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(CALLDATE, CALLTIME, A_NUM, B_NUM, DURATION, IN_NOP_NAME, OG_NOP_NAME);

LOAD DATA LOCAL INFILE 'data/cdr_june_2025.csv'
INTO TABLE cdr_staging
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(Caller, Callee, Begin_time, End_time, Call_duration);

-- -----------------------------------------------------------------------------
-- 3. Cleaned/typed tables
--    Normalization applied to A_NUM/B_NUM/Caller/Callee before matching:
--      - strip a stray trailing ".0" (mixed-type column artifact)
--      - strip a leading "+" (international-format prefix on some rows)
--      - strip leading zeros (zero-padded on some rows, not others)
--    These three only show up when the columns are inspected as raw text - any
--    numeric coercion silently hides them.
--    On top of that normalized value:
--      - B_NUM_clean:  >= 1e14 (15+ digits) -> strip first 5 digits
--                      >= 1e12 (13-14 digits) -> strip first 3 digits
--      - Callee_clean: >= 1e15 (16+ digits) -> strip first 6 digits
--                      >= 1e12 (13-15 digits) -> strip first 3 digits
--    Rows where Begin_time fails to parse are dropped: these are the stray
--    header-as-data rows mixed into the CDR export (literal "Begin time"
--    string found in the data)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS lcl_data;
CREATE TABLE lcl_data (
    CALLDATE        DATE,
    CALLTIME        TIME,
    A_NUM           VARCHAR(50),
    B_NUM           VARCHAR(50),
    DURATION        INT,
    IN_NOP_NAME     VARCHAR(50),
    OG_NOP_NAME     VARCHAR(50),
    A_NUM_clean     VARCHAR(50),
    B_NUM_clean     VARCHAR(50),
    CALL_DATETIME   DATETIME,
    INDEX idx_lcl_ab (A_NUM_clean, B_NUM_clean),
    INDEX idx_lcl_abd (A_NUM_clean, B_NUM_clean, DURATION),
    INDEX idx_lcl_b (B_NUM_clean),
    INDEX idx_lcl_bd (B_NUM_clean, DURATION)
);

INSERT INTO lcl_data (CALLDATE, CALLTIME, A_NUM, B_NUM, DURATION,
                       IN_NOP_NAME, OG_NOP_NAME,
                       A_NUM_clean, B_NUM_clean, CALL_DATETIME)
WITH lcl_norm AS (
    SELECT
        CALLDATE, CALLTIME, A_NUM, B_NUM, DURATION, IN_NOP_NAME, OG_NOP_NAME,
        -- strip trailing ".0", then leading "+", then leading zeros (fall back to '0' if that empties the string)
        CASE WHEN REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(A_NUM, '\\.0$', '')), '^\\+', ''), '^0+', '') = ''
             THEN '0'
             ELSE REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(A_NUM, '\\.0$', '')), '^\\+', ''), '^0+', '')
        END AS A_NUM_norm,
        CASE WHEN REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(B_NUM, '\\.0$', '')), '^\\+', ''), '^0+', '') = ''
             THEN '0'
             ELSE REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(B_NUM, '\\.0$', '')), '^\\+', ''), '^0+', '')
        END AS B_NUM_norm
    FROM lcl_staging
    WHERE CALLDATE >= @date_start AND CALLDATE < @date_end_exclusive
)
SELECT
    STR_TO_DATE(CALLDATE, '%Y-%m-%d'),
    STR_TO_DATE(CALLTIME, '%H:%i:%s'),
    A_NUM,
    B_NUM,
    CASE WHEN DURATION REGEXP '^[0-9]+$' THEN CAST(DURATION AS UNSIGNED) ELSE NULL END,
    IN_NOP_NAME,
    OG_NOP_NAME,
    A_NUM_norm,
    CASE
        WHEN B_NUM_norm REGEXP '^[0-9]+$' AND CAST(B_NUM_norm AS DECIMAL(20,0)) >= 100000000000000
            THEN SUBSTRING(B_NUM_norm, 6)
        WHEN B_NUM_norm REGEXP '^[0-9]+$' AND CAST(B_NUM_norm AS DECIMAL(20,0)) >= 1000000000000
            THEN SUBSTRING(B_NUM_norm, 4)
        ELSE B_NUM_norm
    END,
    STR_TO_DATE(CONCAT(CALLDATE, ' ', CALLTIME), '%Y-%m-%d %H:%i:%s')
FROM lcl_norm;

DROP TABLE IF EXISTS cdr_data;
CREATE TABLE cdr_data (
    Caller         VARCHAR(50),
    Callee         VARCHAR(50),
    Begin_time     DATETIME,
    End_time       DATETIME,
    Call_duration  INT,
    Caller_clean   VARCHAR(50),
    Callee_clean   VARCHAR(20),
    INDEX idx_cdr_cc (Caller_clean, Callee_clean),
    INDEX idx_cdr_ccd (Caller_clean, Callee_clean, Call_duration),
    INDEX idx_cdr_begin (Begin_time),
    INDEX idx_cdr_callee (Callee_clean),
    INDEX idx_cdr_callee_dur (Callee_clean, Call_duration)
);

INSERT INTO cdr_data (Caller, Callee, Begin_time, End_time, Call_duration,
                       Caller_clean, Callee_clean)
WITH cdr_norm AS (
    SELECT
        Caller, Callee, Begin_time, End_time, Call_duration,
        -- strip trailing ".0", then leading "+", then leading zeros (fall back to '0' if that empties the string)
        CASE WHEN REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(Caller, '\\.0$', '')), '^\\+', ''), '^0+', '') = ''
             THEN '0'
             ELSE REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(Caller, '\\.0$', '')), '^\\+', ''), '^0+', '')
        END AS Caller_norm,
        CASE WHEN REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(Callee, '\\.0$', '')), '^\\+', ''), '^0+', '') = ''
             THEN '0'
             ELSE REGEXP_REPLACE(REGEXP_REPLACE(TRIM(REGEXP_REPLACE(Callee, '\\.0$', '')), '^\\+', ''), '^0+', '')
        END AS Callee_norm
    FROM cdr_staging
    -- Filter on a plain pattern match, not STR_TO_DATE: in strict SQL mode (MySQL default),
    -- STR_TO_DATE raises a hard error on unparseable input instead of returning NULL, so it
    -- can't be used to filter out the bad rows in the first place.
    WHERE Begin_time REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
      AND End_time   REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
      AND Begin_time >= @date_start AND Begin_time < @date_end_exclusive
)
SELECT
    Caller,
    Callee,
    STR_TO_DATE(Begin_time, '%Y-%m-%d %H:%i:%s'),
    STR_TO_DATE(End_time, '%Y-%m-%d %H:%i:%s'),
    CASE WHEN Call_duration REGEXP '^[0-9]+$' THEN CAST(Call_duration AS UNSIGNED) ELSE NULL END,
    Caller_norm,
    CASE
        WHEN Callee_norm REGEXP '^[0-9]+$' AND CAST(Callee_norm AS DECIMAL(20,0)) >= 1000000000000000
            THEN SUBSTRING(Callee_norm, 7)
        WHEN Callee_norm REGEXP '^[0-9]+$' AND CAST(Callee_norm AS DECIMAL(20,0)) >= 1000000000000
            THEN SUBSTRING(Callee_norm, 4)
        ELSE Callee_norm
    END
FROM cdr_norm;

-- Row count sanity check (staging vs cleaned - expect only the bad CDR rows to drop)
SELECT (SELECT COUNT(*) FROM lcl_staging) AS lcl_staging_rows,
       (SELECT COUNT(*) FROM lcl_data)    AS lcl_clean_rows,
       (SELECT COUNT(*) FROM cdr_staging) AS cdr_staging_rows,
       (SELECT COUNT(*) FROM cdr_data)    AS cdr_clean_rows;

-- -----------------------------------------------------------------------------
-- 4. Safety check - duplicate keys before joining
--    A high max here means a join on that key will multiply rows - a join on
--    Duration alone, for example, explodes into a near-cross join.
--
--    Diagnostic: A_NUM/Caller overlap is far lower than B_NUM/Callee overlap, and
--    sample values show Caller includes number ranges A_NUM never has - they are not
--    the same field. So B_NUM/Callee is the real join key below, not A_NUM/Caller.
--      SELECT SUM(B_NUM_clean IN (SELECT Callee_clean FROM cdr_data)) FROM lcl_data;   -- ~76.6% of LCL rows
--      SELECT SUM(A_NUM_clean IN (SELECT Caller_clean FROM cdr_data)) FROM lcl_data;   -- ~37.7% of LCL rows
-- -----------------------------------------------------------------------------
SELECT MAX(cnt) AS max_lcl_rows_per_a_b_num
FROM (SELECT COUNT(*) AS cnt FROM lcl_data GROUP BY A_NUM_clean, B_NUM_clean) t;

SELECT MAX(cnt) AS max_cdr_rows_per_caller_callee
FROM (SELECT COUNT(*) AS cnt FROM cdr_data GROUP BY Caller_clean, Callee_clean) t;

-- The actual Set 1/2 join key is B_NUM/Callee alone - check its cardinality too: a
-- single popular number can repeat hundreds of times across the month, and joining on
-- it alone can multiply rows the same way a Duration-only join would.
SELECT MAX(cnt) AS max_lcl_rows_per_b_num
FROM (SELECT COUNT(*) AS cnt FROM lcl_data GROUP BY B_NUM_clean) t;

SELECT MAX(cnt) AS max_cdr_rows_per_callee
FROM (SELECT COUNT(*) AS cnt FROM cdr_data GROUP BY Callee_clean) t;

-- -----------------------------------------------------------------------------
-- 5. Set 1: B_NUM/Callee is the actual join key (A_NUM/Caller flagged, not required)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS set1;
CREATE TABLE set1 AS
SELECT l.*, c.Caller, c.Callee, c.Begin_time, c.End_time, c.Call_duration,
       c.Caller_clean, c.Callee_clean,
       (l.A_NUM_clean = c.Caller_clean) AS A_NUM_matches_Caller
FROM lcl_data l
LEFT JOIN cdr_data c
  ON l.B_NUM_clean = c.Callee_clean;

SELECT
    (SELECT COUNT(*) FROM lcl_data) AS lcl_rows,
    COUNT(*)                        AS matched_rows,
    COUNT(*) / (SELECT COUNT(*) FROM lcl_data) AS match_rate,
    SUM(A_NUM_matches_Caller)       AS also_matched_a_num_caller
FROM set1
WHERE Callee_clean IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 6. Set 2: B_NUM/Callee/Duration (A_NUM/Caller flagged, not required)
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS set2;
CREATE TABLE set2 AS
SELECT l.*, c.Caller, c.Callee, c.Begin_time, c.End_time, c.Call_duration,
       c.Caller_clean, c.Callee_clean,
       (l.A_NUM_clean = c.Caller_clean) AS A_NUM_matches_Caller
FROM lcl_data l
LEFT JOIN cdr_data c
  ON l.B_NUM_clean = c.Callee_clean
 AND l.DURATION    = c.Call_duration;

SELECT
    (SELECT COUNT(*) FROM lcl_data) AS lcl_rows,
    COUNT(*)                        AS matched_rows,
    COUNT(*) / (SELECT COUNT(*) FROM lcl_data) AS match_rate,
    SUM(A_NUM_matches_Caller)       AS also_matched_a_num_caller
FROM set2
WHERE Callee_clean IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 7. Set 3: Call time (LCL) vs Begin time (CDR), built on the Set 2 match
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS set3;
CREATE TABLE set3 AS
SELECT *,
       TIMESTAMPDIFF(SECOND, Begin_time, CALL_DATETIME) AS TIME_DIFF_SECONDS
FROM set2;

SELECT A_NUM_clean, B_NUM_clean, CALL_DATETIME, Begin_time, TIME_DIFF_SECONDS
FROM set3
LIMIT 100;
