-- ============================================================
-- Project: Master Data Signal Integrity Validation
-- Author:  Hussain Merchant
-- Role:    Business Analyst & Supply Chain Operations (Microsoft, Contract)
-- Purpose: Validate signal integrity of master data across cloud
--          capacity planning datasets to identify anomalies,
--          duplicates, null violations, and stale records.
-- ============================================================


-- ============================================================
-- SECTION 1: NULL / MISSING VALUE CHECKS
-- Identifies required fields that are unexpectedly empty
-- ============================================================

-- 1a. Find records with missing critical identifiers
SELECT
    record_id,
    region,
    sku_id,
    capacity_unit,
    demand_signal_date,
    CASE
        WHEN record_id       IS NULL THEN 'Missing record_id'
        WHEN region          IS NULL THEN 'Missing region'
        WHEN sku_id          IS NULL THEN 'Missing sku_id'
        WHEN capacity_unit   IS NULL THEN 'Missing capacity_unit'
        WHEN demand_signal_date IS NULL THEN 'Missing demand_signal_date'
        ELSE 'OK'
    END AS integrity_flag
FROM
    cloud_capacity_master
WHERE
    record_id IS NULL
    OR region IS NULL
    OR sku_id IS NULL
    OR capacity_unit IS NULL
    OR demand_signal_date IS NULL
ORDER BY
    demand_signal_date DESC;


-- 1b. Summary count of null violations per column
SELECT
    'record_id'          AS column_name, COUNT(*) AS null_count FROM cloud_capacity_master WHERE record_id IS NULL
UNION ALL
SELECT 'region',              COUNT(*) FROM cloud_capacity_master WHERE region IS NULL
UNION ALL
SELECT 'sku_id',              COUNT(*) FROM cloud_capacity_master WHERE sku_id IS NULL
UNION ALL
SELECT 'capacity_unit',       COUNT(*) FROM cloud_capacity_master WHERE capacity_unit IS NULL
UNION ALL
SELECT 'demand_signal_date',  COUNT(*) FROM cloud_capacity_master WHERE demand_signal_date IS NULL
UNION ALL
SELECT 'allocated_capacity',  COUNT(*) FROM cloud_capacity_master WHERE allocated_capacity IS NULL
ORDER BY null_count DESC;


-- ============================================================
-- SECTION 2: DUPLICATE RECORD DETECTION
-- Flags duplicate primary keys and logical duplicates
-- ============================================================

-- 2a. Hard duplicate: same record_id appearing more than once
SELECT
    record_id,
    COUNT(*) AS occurrence_count
FROM
    cloud_capacity_master
GROUP BY
    record_id
HAVING
    COUNT(*) > 1
ORDER BY
    occurrence_count DESC;


-- 2b. Logical duplicate: same (region, sku_id, demand_signal_date) with different record_ids
--     Indicates possible data ingestion or ETL issues
SELECT
    region,
    sku_id,
    demand_signal_date,
    COUNT(DISTINCT record_id)   AS distinct_records,
    MIN(record_id)              AS first_record_id,
    MAX(record_id)              AS last_record_id
FROM
    cloud_capacity_master
GROUP BY
    region,
    sku_id,
    demand_signal_date
HAVING
    COUNT(DISTINCT record_id) > 1
ORDER BY
    demand_signal_date DESC,
    region,
    sku_id;


-- ============================================================
-- SECTION 3: VALUE RANGE & DOMAIN VALIDATION
-- Ensures numeric and categorical fields contain valid values
-- ============================================================

-- 3a. Negative or zero capacity values (should always be > 0)
SELECT
    record_id,
    region,
    sku_id,
    allocated_capacity,
    requested_capacity,
    'Negative/Zero capacity' AS signal_issue
FROM
    cloud_capacity_master
WHERE
    allocated_capacity <= 0
    OR requested_capacity <= 0;


-- 3b. Allocated capacity exceeding requested capacity by >20%
--     (Possible over-provisioning or data entry error)
SELECT
    record_id,
    region,
    sku_id,
    requested_capacity,
    allocated_capacity,
    ROUND(
        (allocated_capacity - requested_capacity) * 100.0 / NULLIF(requested_capacity, 0),
        2
    ) AS over_provision_pct
FROM
    cloud_capacity_master
WHERE
    allocated_capacity > requested_capacity * 1.20
ORDER BY
    over_provision_pct DESC;


-- 3c. Region values not in approved master list
SELECT
    record_id,
    region,
    sku_id,
    'Invalid region code' AS signal_issue
FROM
    cloud_capacity_master
WHERE
    region NOT IN (
        'EASTUS', 'WESTUS', 'WESTUS2', 'CENTRALUS',
        'NORTHEUROPE', 'WESTEUROPE',
        'SOUTHEASTASIA', 'EASTASIA',
        'AUSTRALIAEAST', 'BRAZILSOUTH'
    );


-- 3d. Utilization rate outside valid 0–100% band
SELECT
    record_id,
    region,
    sku_id,
    utilization_rate,
    'Utilization out of range [0,100]' AS signal_issue
FROM
    cloud_capacity_master
WHERE
    utilization_rate < 0
    OR utilization_rate > 100;


-- ============================================================
-- SECTION 4: TEMPORAL / DATE SIGNAL INTEGRITY
-- Validates date fields for staleness, future-dates, and gaps
-- ============================================================

-- 4a. Records with demand_signal_date in the future
SELECT
    record_id,
    region,
    sku_id,
    demand_signal_date,
    'Future-dated demand signal' AS signal_issue
FROM
    cloud_capacity_master
WHERE
    demand_signal_date > GETDATE();   -- Use CURRENT_DATE for PostgreSQL/BigQuery


-- 4b. Stale signals: last updated more than 30 days ago (for active SKUs)
SELECT
    record_id,
    region,
    sku_id,
    last_updated_date,
    DATEDIFF(DAY, last_updated_date, GETDATE()) AS days_since_update,
    'Stale master record (>30 days)' AS signal_issue
FROM
    cloud_capacity_master
WHERE
    DATEDIFF(DAY, last_updated_date, GETDATE()) > 30
    AND status = 'ACTIVE';


-- 4c. Detect gaps in expected daily demand signal continuity per region-SKU
--     (Uses a calendar/date spine CTE for gap detection)
WITH date_spine AS (
    -- Generate last 90 days of dates
    SELECT DATEADD(DAY, -n, CAST(GETDATE() AS DATE)) AS signal_date
    FROM (
        SELECT TOP 90 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
        FROM sys.objects
    ) nums
),
expected_signals AS (
    SELECT DISTINCT
        r.region,
        s.sku_id,
        d.signal_date
    FROM
        (SELECT DISTINCT region FROM cloud_capacity_master) r
        CROSS JOIN (SELECT DISTINCT sku_id FROM cloud_capacity_master) s
        CROSS JOIN date_spine d
),
actual_signals AS (
    SELECT
        region,
        sku_id,
        CAST(demand_signal_date AS DATE) AS signal_date
    FROM
        cloud_capacity_master
)
SELECT
    e.region,
    e.sku_id,
    e.signal_date AS missing_signal_date
FROM
    expected_signals e
LEFT JOIN
    actual_signals a
    ON  e.region      = a.region
    AND e.sku_id      = a.sku_id
    AND e.signal_date = a.signal_date
WHERE
    a.signal_date IS NULL
ORDER BY
    e.region,
    e.sku_id,
    e.signal_date;


-- ============================================================
-- SECTION 5: CROSS-TABLE REFERENTIAL INTEGRITY
-- Validates foreign key relationships across master data tables
-- ============================================================

-- 5a. Orphaned SKUs: capacity records referencing SKUs not in sku_master
SELECT
    c.record_id,
    c.sku_id,
    c.region,
    'Orphaned SKU – not in sku_master' AS signal_issue
FROM
    cloud_capacity_master c
LEFT JOIN
    sku_master s ON c.sku_id = s.sku_id
WHERE
    s.sku_id IS NULL;


-- 5b. Capacity records for regions not in region_master
SELECT
    c.record_id,
    c.region,
    'Region not in region_master' AS signal_issue
FROM
    cloud_capacity_master c
LEFT JOIN
    region_master r ON c.region = r.region_code
WHERE
    r.region_code IS NULL;


-- 5c. Validate that allocated GPU capacity sums align with datacenter-level totals
SELECT
    c.region,
    SUM(c.allocated_capacity)   AS total_allocated,
    dc.total_capacity           AS datacenter_total,
    dc.total_capacity - SUM(c.allocated_capacity) AS unaccounted_capacity
FROM
    cloud_capacity_master c
JOIN
    datacenter_capacity dc ON c.region = dc.region
GROUP BY
    c.region,
    dc.total_capacity
HAVING
    ABS(dc.total_capacity - SUM(c.allocated_capacity)) > 100  -- flag if gap > 100 units
ORDER BY
    unaccounted_capacity DESC;


-- ============================================================
-- SECTION 6: SIGNAL INTEGRITY SUMMARY DASHBOARD QUERY
-- One-stop view of all integrity flags for reporting/dashboards
-- ============================================================

WITH integrity_flags AS (

    -- Null violations
    SELECT record_id, region, sku_id, 'NULL_VIOLATION'      AS flag_type, 'Required field is NULL'                     AS description FROM cloud_capacity_master WHERE record_id IS NULL OR region IS NULL OR sku_id IS NULL OR capacity_unit IS NULL

    UNION ALL
    -- Hard duplicates
    SELECT c.record_id, c.region, c.sku_id, 'DUPLICATE_KEY', 'Duplicate record_id detected'
    FROM cloud_capacity_master c
    JOIN (SELECT record_id FROM cloud_capacity_master GROUP BY record_id HAVING COUNT(*) > 1) d
        ON c.record_id = d.record_id

    UNION ALL
    -- Negative capacity
    SELECT record_id, region, sku_id, 'INVALID_VALUE', 'Negative or zero capacity'
    FROM cloud_capacity_master WHERE allocated_capacity <= 0 OR requested_capacity <= 0

    UNION ALL
    -- Future dates
    SELECT record_id, region, sku_id, 'FUTURE_DATE', 'demand_signal_date is in the future'
    FROM cloud_capacity_master WHERE demand_signal_date > GETDATE()

    UNION ALL
    -- Stale records
    SELECT record_id, region, sku_id, 'STALE_RECORD', 'No update in > 30 days (active SKU)'
    FROM cloud_capacity_master WHERE DATEDIFF(DAY, last_updated_date, GETDATE()) > 30 AND status = 'ACTIVE'

    UNION ALL
    -- Invalid region
    SELECT record_id, region, sku_id, 'INVALID_DOMAIN', 'Region not in approved list'
    FROM cloud_capacity_master
    WHERE region NOT IN ('EASTUS','WESTUS','WESTUS2','CENTRALUS','NORTHEUROPE','WESTEUROPE','SOUTHEASTASIA','EASTASIA','AUSTRALIAEAST','BRAZILSOUTH')

    UNION ALL
    -- Orphaned SKU
    SELECT c.record_id, c.region, c.sku_id, 'ORPHAN_FK', 'SKU not found in sku_master'
    FROM cloud_capacity_master c LEFT JOIN sku_master s ON c.sku_id = s.sku_id WHERE s.sku_id IS NULL
)

SELECT
    flag_type,
    COUNT(*)        AS issue_count,
    COUNT(DISTINCT region) AS regions_affected,
    COUNT(DISTINCT sku_id) AS skus_affected
FROM
    integrity_flags
GROUP BY
    flag_type
ORDER BY
    issue_count DESC;
