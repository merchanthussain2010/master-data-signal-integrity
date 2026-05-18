# Master Data Signal Integrity Validation
**Role:** Business Analyst & Supply Chain Operations | Microsoft (Contract)  
**Tools:** SQL (T-SQL / Azure Synapse compatible) | Power BI | Excel  
**Timeline:** Oct 2025 – Present

---

## Project Overview

At Microsoft's Cloud Planning team, one of the core challenges is ensuring that the master data feeding AI GPU capacity planning is **accurate, complete, and trustworthy**. Dirty or stale signals in the master dataset can propagate into demand forecasts, causing over- or under-provisioning of cloud infrastructure across regions.

This project implements a **multi-layer SQL-based validation framework** that continuously audits the `cloud_capacity_master` table for signal integrity issues — catching problems before they impact capacity planning decisions and AI infrastructure scalability.

---

## Problem Statement

The capacity planning pipeline ingests demand signals from multiple upstream systems across regions (EASTUS, WESTEUROPE, SOUTHEASTASIA, etc.). Without systematic validation, issues such as:
- Missing or null critical fields
- Duplicate records from ETL re-runs
- Out-of-range utilization values
- Stale signals for active SKUs
- Orphaned foreign key references

…can silently corrupt downstream forecasts and go undetected for days.

---

## Solution Architecture

```
Upstream Data Sources (ERP, Demand Systems, Regional Feeds)
            │
            ▼
  cloud_capacity_master  (master data table)
            │
            ▼
  ┌─────────────────────────────────┐
  │  Signal Integrity SQL Framework │
  │                                 │
  │  Layer 1: Null/Missing Checks   │
  │  Layer 2: Duplicate Detection   │
  │  Layer 3: Domain Validation     │
  │  Layer 4: Temporal Validation   │
  │  Layer 5: Referential Integrity │
  └─────────────┬───────────────────┘
                │
                ▼
  master_data_integrity_log  (audit table)
                │
                ▼
  Power BI Dashboard / Exec Summary Reports
```

---

## Files

| File | Description |
|------|-------------|
| `01_signal_integrity_checks.sql` | Core validation queries across 6 layers |
| `02_remediation_and_monitoring.sql` | Audit table setup, logging pipeline, trend monitoring, resolution tracking |

---

## Validation Layers

### Layer 1 — Null / Missing Value Checks
Identifies records where required fields (`record_id`, `region`, `sku_id`, `capacity_unit`, `demand_signal_date`) are null. Produces both row-level detail and a column-level summary count.

### Layer 2 — Duplicate Record Detection
- **Hard duplicates:** Same `record_id` appearing more than once
- **Logical duplicates:** Same `(region, sku_id, demand_signal_date)` combination with different `record_id` values — typically caused by ETL re-runs

### Layer 3 — Value Range & Domain Validation
- Negative or zero `allocated_capacity` / `requested_capacity`
- Over-provisioning beyond 20% of requested capacity
- `region` codes not in the approved datacenter list
- `utilization_rate` outside the valid [0, 100] band

### Layer 4 — Temporal / Date Signal Integrity
- Future-dated demand signals
- Active SKUs not updated in > 30 days (stale signals)
- **Gap detection:** Uses a date spine CTE to find days where an expected (region, SKU) combination is missing from the signal feed

### Layer 5 — Referential Integrity (Cross-Table)
- Orphaned SKUs: capacity records referencing `sku_id` values not present in `sku_master`
- Invalid regions: records referencing `region` codes not in `region_master`
- Datacenter capacity reconciliation: flags regions where summed allocated capacity diverges from the datacenter-level total by > 100 units

### Layer 6 — Summary Dashboard Query
Aggregates all flag types into a single reporting view showing issue count, regions affected, and SKUs affected per flag type — ready for Power BI or exec presentations.

---

## Monitoring & Audit Pipeline

The `master_data_integrity_log` table captures every flagged record with:
- `flag_type` — categorical issue label
- `run_timestamp` — when the validation ran
- `resolved` — whether the issue has been addressed
- `resolved_by` / `resolved_timestamp` — remediation tracking

Monitoring queries surface:
- Daily issue trends by flag type
- Open issues by region
- Resolution rate % and average resolution time (hours)
- Top 20 SKUs by open violation count
- Weekly executive summary snapshot

---

## Key Outcomes

- Identified **stale and duplicate signals** across multiple regions that were silently skewing demand variance metrics
- Enabled **root cause analysis** on capacity planning gaps by surfacing orphaned SKU references and missing daily signals
- Supported **executive reporting** with clean, validated KPIs on capacity utilization and fulfillment timelines
- Reduced data-quality-related escalations by providing an **early-warning audit trail** before signals reached the planning model

---

## How to Run

1. Run `01_signal_integrity_checks.sql` against your `cloud_capacity_master` database to get immediate validation results
2. Run the `CREATE TABLE` block in `02_remediation_and_monitoring.sql` once to set up the audit log
3. Schedule the `INSERT INTO master_data_integrity_log` block via Azure Data Factory, Airflow, or your preferred pipeline tool
4. Connect the monitoring queries to Power BI for live dashboards

> **Note:** Queries are written in T-SQL (SQL Server / Azure Synapse). For BigQuery/PostgreSQL, replace `GETDATE()` with `CURRENT_TIMESTAMP`, `DATEDIFF(DAY, ...)` with `DATE_DIFF(...)`, and `IDENTITY` with `SERIAL` / `AUTO_INCREMENT`.

---

## Skills Demonstrated

`SQL` · `Data Quality Validation` · `Root Cause Analysis` · `ETL Auditing` · `Supply Chain Data Integrity` · `KPI Monitoring` · `Executive Reporting` · `Azure Synapse / T-SQL`
