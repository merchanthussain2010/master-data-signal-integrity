-- ============================================================
-- Project: Master Data Signal Integrity Validation
-- File:    02_remediation_and_monitoring.sql
-- Author:  Hussain Merchant
-- Purpose: Automated logging of integrity violations into an
--          audit table, plus monitoring queries for trend tracking
-- ============================================================


-- ============================================================
-- STEP 1: CREATE AUDIT / LOGGING TABLE
-- Run once to set up the audit infrastructure
-- ============================================================

CREATE TABLE IF NOT EXISTS master_data_integrity_log (
    log_id              INT IDENTITY(1,1) PRIMARY KEY,
    run_timestamp       DATETIME         NOT NULL DEFAULT GETDATE(),
    record_id           VARCHAR(50),
    region              VARCHAR(30),
    sku_id              VARCHAR(50),
    flag_type           VARCHAR(50)      NOT NULL,   -- e.g. NULL_VIOLATION, DUPLICATE_KEY
    description         VARCHAR(255),
    source_table        VARCHAR(100)     DEFAULT 'cloud_capacity_master',
    resolved            BIT              DEFAULT 0,
    resolved_timestamp  DATETIME,
    resolved_by         VARCHAR(100)
);


-- ============================================================
-- STEP 2: POPULATE AUDIT TABLE (run on a schedule via pipeline)
-- ============================================================

INSERT INTO master_data_integrity_log
    (record_id, region, sku_id, flag_type, description)

-- Null violations
SELECT record_id, region, sku_id, 'NULL_VIOLATION', 'Required field is NULL'
FROM cloud_capacity_master
WHERE record_id IS NULL OR region IS NULL OR sku_id IS NULL OR capacity_unit IS NULL

UNION ALL
-- Duplicate primary keys
SELECT c.record_id, c.region, c.sku_id, 'DUPLICATE_KEY', 'Duplicate record_id detected'
FROM cloud_capacity_master c
JOIN (
    SELECT record_id FROM cloud_capacity_master
    GROUP BY record_id HAVING COUNT(*) > 1
) d ON c.record_id = d.record_id

UNION ALL
-- Negative/zero capacity
SELECT record_id, region, sku_id, 'INVALID_VALUE', 'Negative or zero capacity detected'
FROM cloud_capacity_master
WHERE allocated_capacity <= 0 OR requested_capacity <= 0

UNION ALL
-- Future demand signals
SELECT record_id, region, sku_id, 'FUTURE_DATE', 'demand_signal_date is in the future'
FROM cloud_capacity_master
WHERE demand_signal_date > GETDATE()

UNION ALL
-- Stale active records
SELECT record_id, region, sku_id, 'STALE_RECORD', 'Active SKU not updated in > 30 days'
FROM cloud_capacity_master
WHERE DATEDIFF(DAY, last_updated_date, GETDATE()) > 30 AND status = 'ACTIVE'

UNION ALL
-- Invalid region domain values
SELECT record_id, region, sku_id, 'INVALID_DOMAIN', 'Region code not in approved list'
FROM cloud_capacity_master
WHERE region NOT IN (
    'EASTUS', 'WESTUS', 'WESTUS2', 'CENTRALUS',
    'NORTHEUROPE', 'WESTEUROPE',
    'SOUTHEASTASIA', 'EASTASIA',
    'AUSTRALIAEAST', 'BRAZILSOUTH'
)

UNION ALL
-- Orphaned SKU foreign keys
SELECT c.record_id, c.region, c.sku_id, 'ORPHAN_FK', 'SKU not present in sku_master'
FROM cloud_capacity_master c
LEFT JOIN sku_master s ON c.sku_id = s.sku_id
WHERE s.sku_id IS NULL;


-- ============================================================
-- STEP 3: MONITORING QUERIES FOR TREND ANALYSIS
-- Use in Power BI / dashboards or exec-ready reports
-- ============================================================

-- 3a. Daily trend: how many new issues are being logged per day?
SELECT
    CAST(run_timestamp AS DATE)     AS log_date,
    flag_type,
    COUNT(*)                        AS new_issues
FROM
    master_data_integrity_log
GROUP BY
    CAST(run_timestamp AS DATE),
    flag_type
ORDER BY
    log_date DESC,
    new_issues DESC;


-- 3b. Open (unresolved) issues by region and flag type
SELECT
    region,
    flag_type,
    COUNT(*)    AS open_issue_count,
    MIN(run_timestamp) AS oldest_unresolved
FROM
    master_data_integrity_log
WHERE
    resolved = 0
GROUP BY
    region,
    flag_type
ORDER BY
    open_issue_count DESC;


-- 3c. Resolution rate: % of issues resolved within 7 days
SELECT
    flag_type,
    COUNT(*)                                                        AS total_issues,
    SUM(CASE WHEN resolved = 1 THEN 1 ELSE 0 END)                  AS resolved_count,
    ROUND(
        SUM(CASE WHEN resolved = 1 THEN 1.0 ELSE 0 END) / COUNT(*) * 100,
        1
    )                                                               AS resolution_rate_pct,
    AVG(
        CASE WHEN resolved = 1
            THEN DATEDIFF(HOUR, run_timestamp, resolved_timestamp)
        END
    )                                                               AS avg_resolution_hours
FROM
    master_data_integrity_log
GROUP BY
    flag_type
ORDER BY
    total_issues DESC;


-- 3d. Top SKUs with the most integrity violations
SELECT TOP 20
    sku_id,
    COUNT(*)    AS total_violations,
    COUNT(DISTINCT flag_type) AS distinct_flag_types,
    MAX(run_timestamp)        AS last_seen
FROM
    master_data_integrity_log
WHERE
    resolved = 0
GROUP BY
    sku_id
ORDER BY
    total_violations DESC;


-- ============================================================
-- STEP 4: MARK ISSUES AS RESOLVED (use after data remediation)
-- ============================================================

UPDATE master_data_integrity_log
SET
    resolved           = 1,
    resolved_timestamp = GETDATE(),
    resolved_by        = 'hussain.merchant'   -- replace with actual user/pipeline name
WHERE
    resolved = 0
    AND record_id IN (
        -- Paste list of remediated record_ids here
        'REC-00123', 'REC-00456', 'REC-00789'
    );


-- ============================================================
-- STEP 5: WEEKLY EXEC SUMMARY SNAPSHOT
-- Suitable for pasting into a leadership email or Tableau report
-- ============================================================

SELECT
    'Total active records'          AS metric,
    CAST(COUNT(*) AS VARCHAR)       AS value
FROM cloud_capacity_master

UNION ALL
SELECT
    'Records with integrity issues',
    CAST(COUNT(DISTINCT record_id) AS VARCHAR)
FROM master_data_integrity_log WHERE resolved = 0

UNION ALL
SELECT
    'Issues resolved this week',
    CAST(COUNT(*) AS VARCHAR)
FROM master_data_integrity_log
WHERE resolved = 1
  AND resolved_timestamp >= DATEADD(DAY, -7, GETDATE())

UNION ALL
SELECT
    'Regions affected (open issues)',
    CAST(COUNT(DISTINCT region) AS VARCHAR)
FROM master_data_integrity_log WHERE resolved = 0

UNION ALL
SELECT
    'Most common flag type',
    flag_type
FROM (
    SELECT TOP 1 flag_type, COUNT(*) AS cnt
    FROM master_data_integrity_log WHERE resolved = 0
    GROUP BY flag_type ORDER BY cnt DESC
) top_flag;
