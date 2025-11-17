# Autovacuum Production Best Practices & Monitoring

**Interview Focus:** These are the exact questions senior DBAs get asked about production PostgreSQL management.

---

## 1. High-Churn Table Threshold Configuration

### Q: What thresholds are you using for high-churn tables? What parameters to check?

### Answer Framework:

**High-churn tables** = tables with frequent UPDATEs/DELETEs (orders, sessions, inventory, user_activity, etc.)

### Key Parameters to Check:

#### 1.1 Table-Level Settings (Most Important)

```sql
-- Check per-table autovacuum configuration
SELECT 
    c.relname AS table_name,
    c.reloptions AS table_settings,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.reloptions IS NOT NULL
ORDER BY pg_total_relation_size(c.oid) DESC;
```

**What this does:**
- Shows tables with custom autovacuum settings
- `reloptions` column contains `ALTER TABLE ... SET (...)` parameters
- Identifies which tables have been tuned

**Example output:**
```
  table_name  |                           table_settings                              | total_size 
--------------+-----------------------------------------------------------------------+------------
 orders       | {autovacuum_vacuum_scale_factor=0.02,autovacuum_vacuum_threshold=50}  | 150 MB
 sessions     | {autovacuum_vacuum_scale_factor=0.03,autovacuum_analyze_threshold=25} | 45 MB
```

#### 1.2 Extract Individual Settings

```sql
-- Parse reloptions to see individual parameters
SELECT 
    c.relname,
    (SELECT option_value 
     FROM unnest(c.reloptions) AS x(option_name) 
     WHERE option_name LIKE 'autovacuum_vacuum_scale_factor%'
    ) AS scale_factor,
    (SELECT option_value 
     FROM unnest(c.reloptions) AS x(option_name) 
     WHERE option_name LIKE 'autovacuum_vacuum_threshold%'
    ) AS threshold,
    (SELECT option_value 
     FROM unnest(c.reloptions) AS x(option_name) 
     WHERE option_name LIKE 'autovacuum_vacuum_cost_delay%'
    ) AS cost_delay
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.reloptions IS NOT NULL;
```

**What this does:**
- Extracts specific autovacuum parameters from reloptions array
- Shows scale_factor, threshold, cost_delay separately
- Easier to compare across tables

#### 1.3 Check Global Defaults

```sql
-- Check global autovacuum configuration
SELECT 
    name,
    setting,
    unit,
    context,
    short_desc
FROM pg_settings 
WHERE name IN (
    'autovacuum',
    'autovacuum_vacuum_threshold',
    'autovacuum_vacuum_scale_factor',
    'autovacuum_vacuum_cost_delay',
    'autovacuum_vacuum_cost_limit',
    'autovacuum_naptime',
    'autovacuum_max_workers',
    'autovacuum_analyze_threshold',
    'autovacuum_analyze_scale_factor'
)
ORDER BY name;
```

**What this does:**
- Shows system-wide defaults
- `context` column tells if setting requires restart ('postmaster') or reload ('sighup')
- Tables without per-table settings use these defaults

### Production Recommendations:

#### High-Churn Tables (Frequent UPDATEs/DELETEs)

```sql
-- AGGRESSIVE TUNING for high-update tables
ALTER TABLE orders SET (
    autovacuum_vacuum_threshold = 50,
    autovacuum_vacuum_scale_factor = 0.02,        -- 2% (vs default 20%)
    autovacuum_analyze_threshold = 50,
    autovacuum_analyze_scale_factor = 0.01,       -- 1% (vs default 10%)
    autovacuum_vacuum_cost_delay = 0,             -- No throttling (SSD only!)
    autovacuum_vacuum_cost_limit = 1000
);
```

**Why these values:**
- **0.02 scale_factor** = triggers at 2% dead tuples (10x more aggressive than default)
- **cost_delay = 0** = maximum speed, no I/O throttling (requires fast storage)
- **0.01 analyze** = keep statistics fresh for query planner

**Example Calculation:**
```
Table: orders (100,000 rows)
Default threshold: 50 + (0.2 × 100,000) = 20,050 dead tuples (20%)
Tuned threshold:   50 + (0.02 × 100,000) = 2,050 dead tuples (2%)

Result: Autovacuum triggers 10x faster, prevents bloat accumulation
```

#### Medium-Churn Tables (Moderate Updates)

```sql
-- MODERATE TUNING for mixed workload
ALTER TABLE user_profiles SET (
    autovacuum_vacuum_threshold = 50,
    autovacuum_vacuum_scale_factor = 0.05,        -- 5% 
    autovacuum_vacuum_cost_delay = 2              -- Slight throttling
);
```

**Why these values:**
- **0.05 scale_factor** = 5% threshold (4x more aggressive)
- **cost_delay = 2ms** = balanced (won't overload I/O)

#### Low-Churn / Append-Only Tables

```sql
-- CONSERVATIVE TUNING for append-only logs
ALTER TABLE event_logs SET (
    autovacuum_vacuum_threshold = 10000,
    autovacuum_vacuum_scale_factor = 0.5,         -- 50% (rarely reached)
    autovacuum_analyze_scale_factor = 0.05        -- Still analyze for stats
);
```

**Why these values:**
- **0.5 scale_factor** = 50% threshold (very high, saves resources)
- Append-only tables rarely need vacuum
- Still analyze for query optimizer

### Interview Talking Points:

```
Q: "What thresholds do you use for high-churn tables?"

A: "For high-update tables like orders or sessions, I tune aggressively:
   
   - autovacuum_vacuum_scale_factor = 0.02 (2% instead of 20%)
   - autovacuum_vacuum_cost_delay = 0 (no throttling on SSDs)
   
   This means autovacuum triggers when only 2% of the table is dead tuples,
   instead of waiting for 20%. For a 100K row table, that's 2,050 dead tuples
   vs 20,050 - a 10x improvement.
   
   I monitor with:
   SELECT relname, n_dead_tup, n_live_tup,
          n_dead_tup * 100.0 / (n_live_tup + n_dead_tup) as dead_pct
   FROM pg_stat_user_tables
   WHERE n_dead_tup > 0
   ORDER BY dead_pct DESC;
   
   If dead_pct consistently exceeds 5%, I tune more aggressively."
```

---

## 2. Visibility Map Monitoring

### Q: Do you use visibility map monitoring to know when tables need more vacuuming?

### What is the Visibility Map?

The **visibility map** tracks which pages (8KB blocks) contain:
- Only **all-visible** tuples (no dead tuples, all committed)
- **All-frozen** tuples (immune to transaction ID wraparound)

**Why it matters:**
- VACUUM can **skip pages** marked as all-visible (performance optimization)
- Index-only scans use visibility map to avoid heap access
- Low all-visible percentage = high bloat or churn

### Key Monitoring Queries:

#### 2.1 Check Visibility Map Coverage

```sql
-- Visibility map statistics per table
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    
    -- Page statistics
    seq_scan,
    seq_tup_read,
    idx_scan,
    
    -- Visibility map metrics
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    
    -- Last maintenance
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    
    -- Vacuum and analyze counts
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count
    
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
ORDER BY n_dead_tup DESC;
```

**What this does:**
- Shows dead tuple percentage (bloat indicator)
- Tracks maintenance frequency
- Identifies tables needing attention

#### 2.2 Detailed Visibility Map Analysis (pgstattuple extension)

```sql
-- Install extension (if not already)
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- Detailed visibility analysis for specific table
SELECT
    table_len,
    tuple_count,
    tuple_len,
    tuple_percent,
    dead_tuple_count,
    dead_tuple_len,
    dead_tuple_percent,
    free_space,
    free_percent
FROM pgstattuple('orders');
```

**What this does:**
- Scans entire table (slow on large tables!)
- Shows exact bloat percentage
- Calculates free space available for reuse

**Production usage:**
```sql
-- Only run on smaller tables or during maintenance windows
SELECT * FROM pgstattuple('orders') WHERE pg_total_relation_size('orders') < 1073741824; -- < 1GB
```

#### 2.3 Visibility Map Pages Check

```sql
-- Check all-visible and all-frozen pages using pg_visibility extension
CREATE EXTENSION IF NOT EXISTS pg_visibility;

-- Summary of visibility map state
SELECT
    'orders'::regclass AS table_name,
    all_visible,
    all_frozen,
    all_visible + all_frozen AS total_visible_pages,
    (SELECT relpages FROM pg_class WHERE relname = 'orders') AS total_pages,
    round((all_visible + all_frozen) * 100.0 / 
          NULLIF((SELECT relpages FROM pg_class WHERE relname = 'orders'), 0), 2) 
          AS visible_pct
FROM (
    SELECT
        count(*) FILTER (WHERE all_visible) AS all_visible,
        count(*) FILTER (WHERE all_frozen) AS all_frozen
    FROM pg_visibility_map('orders')
) vm;
```

**What this does:**
- Shows percentage of pages that are all-visible or all-frozen
- Low percentage = table needs VACUUM
- High percentage = VACUUM is effective, index-only scans possible

#### 2.4 Monitoring Query - Production Ready

```sql
-- Daily health check query
CREATE OR REPLACE VIEW visibility_map_health AS
SELECT
    c.relname AS table_name,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
    c.relpages AS total_pages,
    
    -- Dead tuple stats
    s.n_live_tup,
    s.n_dead_tup,
    round(s.n_dead_tup * 100.0 / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 2) AS dead_pct,
    
    -- Vacuum effectiveness
    s.last_autovacuum,
    now() - s.last_autovacuum AS time_since_autovacuum,
    s.autovacuum_count,
    
    -- Alert conditions
    CASE
        WHEN s.n_dead_tup * 100.0 / NULLIF(s.n_live_tup + s.n_dead_tup, 0) > 20 THEN '🚨 HIGH BLOAT'
        WHEN s.n_dead_tup * 100.0 / NULLIF(s.n_live_tup + s.n_dead_tup, 0) > 10 THEN '⚠️  MODERATE BLOAT'
        WHEN now() - s.last_autovacuum > interval '24 hours' THEN '⚠️  STALE VACUUM'
        ELSE '✅ OK'
    END AS status
    
FROM pg_class c
JOIN pg_stat_user_tables s ON c.oid = s.relid
WHERE c.relkind = 'r'
  AND s.n_live_tup > 1000
ORDER BY s.n_dead_tup DESC;

-- Use it:
SELECT * FROM visibility_map_health WHERE status != '✅ OK';
```

**What this does:**
- Production-ready monitoring view
- Automated health status
- Easy to integrate with monitoring tools (Prometheus, Datadog, etc.)

### Interview Answer:

```
Q: "Do you monitor visibility maps?"

A: "Yes, I monitor visibility map effectiveness using multiple approaches:

   1. DEAD TUPLE PERCENTAGE (Primary metric):
      SELECT relname, n_dead_tup * 100.0 / (n_live_tup + n_dead_tup) as dead_pct
      FROM pg_stat_user_tables;
      
      Alert thresholds:
      - > 20% = critical (immediate action)
      - > 10% = warning (investigate)
      - < 5% = healthy

   2. VISIBILITY MAP COVERAGE (pg_visibility extension):
      Shows percentage of pages marked all-visible or all-frozen.
      Low percentage indicates table needs VACUUM to mark pages clean.
      
   3. INDEX-ONLY SCAN EFFICIENCY:
      SELECT relname, idx_scan, idx_tup_fetch
      FROM pg_stat_user_tables;
      
      High idx_tup_fetch with index-only scans = poor visibility map coverage
      
   4. AUTOVACUUM FREQUENCY:
      If autovacuum runs frequently but dead_pct stays high, indicates:
      - Long-running transactions blocking cleanup
      - Insufficient autovacuum workers
      - Table needs more aggressive tuning

   I export these metrics to Grafana and alert on dead_pct > 15% for
   critical tables like orders, sessions, or inventory."
```

---

## 3. Measuring Table and Index Bloat

### Q: How do you measure table and index bloat internally?

### Three Approaches:

### 3.1 Quick Estimate (pgstattuple - Accurate but Slow)

```sql
-- Install extension
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- Table bloat analysis (SLOW on large tables!)
SELECT
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    
    round(dead_tuple_percent, 2) AS bloat_pct,
    pg_size_pretty((pg_total_relation_size(schemaname||'.'||tablename) * 
                   dead_tuple_percent / 100)::bigint) AS bloat_size,
    
    pg_size_pretty(free_space) AS free_space,
    round(free_percent, 2) AS free_pct,
    
    tuple_count AS live_tuples,
    dead_tuple_count AS dead_tuples
    
FROM pgstattuple('public.' || tablename), 
     pg_tables
WHERE schemaname = 'public'
  AND tablename = 'orders'; -- Specify table
```

**What this does:**
- Scans entire table to calculate exact bloat
- **WARNING:** Very slow on large tables (100GB+ = hours)
- Use only during maintenance windows or on replicas

**Production safe version:**
```sql
-- Only scan tables smaller than 1GB
SELECT
    c.relname,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
    s.dead_tuple_percent
FROM pg_class c
JOIN pg_stat_user_tables st ON c.oid = st.relid
CROSS JOIN LATERAL pgstattuple(c.oid) s
WHERE pg_total_relation_size(c.oid) < 1073741824 -- 1GB limit
  AND st.n_live_tup > 1000
ORDER BY s.dead_tuple_percent DESC;
```

### 3.2 Fast Estimate (Statistical - Production Safe)

```sql
-- Fast bloat estimation using pg_stat_user_tables
CREATE OR REPLACE VIEW table_bloat_estimate AS
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    pg_total_relation_size(schemaname||'.'||relname) AS total_bytes,
    
    n_live_tup,
    n_dead_tup,
    
    -- Bloat percentage (dead tuples)
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS bloat_pct,
    
    -- Estimated bloat size (rough calculation)
    pg_size_pretty((pg_total_relation_size(schemaname||'.'||relname) * 
                   n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 1))::bigint) AS bloat_size_estimate,
    
    -- Last maintenance
    last_vacuum,
    last_autovacuum,
    autovacuum_count,
    
    -- Action needed
    CASE
        WHEN n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0) > 30 THEN 'VACUUM FULL needed'
        WHEN n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0) > 20 THEN 'Immediate VACUUM'
        WHEN n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0) > 10 THEN 'Schedule VACUUM'
        ELSE 'OK'
    END AS action
    
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
ORDER BY n_dead_tup DESC;

-- Use it:
SELECT * FROM table_bloat_estimate WHERE action != 'OK';
```

**What this does:**
- Fast query (no table scan)
- Uses statistics from pg_stat_user_tables
- Estimates bloat based on dead tuple ratio
- Production-safe, run anytime

### 3.3 Index Bloat Detection

```sql
-- Index bloat estimate using pg_stat_user_indexes
CREATE OR REPLACE VIEW index_bloat_estimate AS
SELECT
    schemaname || '.' || indexrelname AS index_name,
    schemaname || '.' || relname AS table_name,
    
    pg_size_pretty(pg_total_relation_size(indexrelid)) AS index_size,
    pg_total_relation_size(indexrelid) AS index_bytes,
    
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    
    -- Bloat indicators
    CASE
        WHEN idx_scan = 0 THEN 'UNUSED - Consider dropping'
        WHEN pg_total_relation_size(indexrelid) > pg_total_relation_size(relid) THEN 'BLOATED - Larger than table!'
        WHEN idx_scan < 10 AND pg_total_relation_size(indexrelid) > 1073741824 THEN 'RARELY USED - Large & unused'
        ELSE 'OK'
    END AS status,
    
    -- Recommendation
    CASE
        WHEN idx_scan = 0 THEN 'DROP INDEX or monitor usage'
        WHEN pg_total_relation_size(indexrelid) > pg_total_relation_size(relid) THEN 'REINDEX immediately'
        WHEN idx_scan < 10 THEN 'Consider dropping if not needed'
        ELSE 'Monitor'
    END AS recommendation
    
FROM pg_stat_user_indexes
JOIN pg_class c ON c.oid = indexrelid
WHERE pg_total_relation_size(indexrelid) > 10485760 -- > 10MB
ORDER BY pg_total_relation_size(indexrelid) DESC;

-- Use it:
SELECT * FROM index_bloat_estimate WHERE status != 'OK';
```

**What this does:**
- Identifies bloated indexes (larger than table = red flag)
- Finds unused indexes (idx_scan = 0)
- Recommends REINDEX for bloated indexes

### 3.4 Advanced: pgstattuple for Index Bloat (Slow but Accurate)

```sql
-- Index bloat details using pgstattuple
SELECT
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    
    round(100 - pgstatindex(indexrelid)::record::text::json->>'avg_leaf_density'::text::numeric, 2) AS bloat_pct,
    
    (pgstatindex(indexrelid)::record::text::json->>'leaf_fragmentation')::numeric AS fragmentation
    
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
  AND pg_relation_size(indexrelid) > 10485760 -- > 10MB
ORDER BY bloat_pct DESC NULLS LAST;
```

**What this does:**
- Uses pgstatindex() for accurate index bloat
- Shows leaf density (lower = more bloated)
- **WARNING:** Slow on large indexes

### Automated Monitoring Script:

```sql
-- Create comprehensive bloat monitoring view
CREATE OR REPLACE VIEW bloat_monitoring_dashboard AS
WITH table_bloat AS (
    SELECT
        'TABLE' AS object_type,
        schemaname || '.' || relname AS object_name,
        pg_total_relation_size(schemaname||'.'||relname) AS size_bytes,
        n_live_tup,
        n_dead_tup,
        round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS bloat_pct,
        last_autovacuum,
        autovacuum_count
    FROM pg_stat_user_tables
    WHERE n_live_tup > 1000
),
index_bloat AS (
    SELECT
        'INDEX' AS object_type,
        schemaname || '.' || indexrelname AS object_name,
        pg_total_relation_size(indexrelid) AS size_bytes,
        NULL::bigint AS n_live_tup,
        NULL::bigint AS n_dead_tup,
        CASE
            WHEN pg_total_relation_size(indexrelid) > pg_total_relation_size(relid) * 2 THEN 50.0
            ELSE 0.0
        END AS bloat_pct,
        NULL::timestamp AS last_autovacuum,
        NULL::bigint AS autovacuum_count
    FROM pg_stat_user_indexes
    WHERE pg_total_relation_size(indexrelid) > 10485760
)
SELECT
    object_type,
    object_name,
    pg_size_pretty(size_bytes) AS size,
    bloat_pct,
    CASE
        WHEN bloat_pct > 50 THEN '🔴 CRITICAL'
        WHEN bloat_pct > 30 THEN '🟠 HIGH'
        WHEN bloat_pct > 15 THEN '🟡 MODERATE'
        ELSE '🟢 OK'
    END AS severity,
    CASE
        WHEN bloat_pct > 50 THEN 'VACUUM FULL / REINDEX immediately'
        WHEN bloat_pct > 30 THEN 'Schedule maintenance'
        WHEN bloat_pct > 15 THEN 'Monitor closely'
        ELSE 'No action needed'
    END AS recommendation,
    last_autovacuum,
    autovacuum_count
FROM (
    SELECT * FROM table_bloat
    UNION ALL
    SELECT * FROM index_bloat
) combined
WHERE bloat_pct > 10
ORDER BY bloat_pct DESC, size_bytes DESC;

-- Daily check:
SELECT * FROM bloat_monitoring_dashboard;
```

### Interview Answer:

```
Q: "How do you measure table and index bloat?"

A: "I use a multi-layered approach:

   1. FAST DAILY MONITORING (pg_stat_user_tables):
      - Dead tuple percentage as primary bloat indicator
      - Query runs in milliseconds, safe in production
      - Alert threshold: >15% bloat
      
   2. DETAILED ANALYSIS (pgstattuple - weekly on replicas):
      - Accurate bloat measurement but requires full table scan
      - Run on standby servers during low-traffic periods
      - For tables < 10GB only
      
   3. INDEX BLOAT DETECTION:
      - Compare index size to table size
      - Index > 2× table size = bloated, needs REINDEX
      - Check idx_scan to identify unused indexes
      
   4. AUTOMATED DASHBOARD:
      - Created view combining table and index bloat
      - Severity levels: OK / MODERATE / HIGH / CRITICAL
      - Integrated with Grafana for alerts
      
   Example from production:
   - Found orders_idx index at 15GB (table was 5GB)
   - REINDEX CONCURRENTLY reduced to 6GB
   - Improved query performance by 40%
   
   Key insight: Prevention better than cure. With 2-5% autovacuum tuning
   on high-churn tables, bloat stays under 10% and we rarely need 
   manual intervention."
```

---

## 4. Autovacuum Worker Configuration

### Q: How many autovacuum workers do you configure?

### Understanding Workers:

**autovacuum_max_workers** = maximum parallel autovacuum processes

Default: **3 workers**

### Key Factors to Consider:

#### 4.1 Check Current Worker Usage

```sql
-- See active autovacuum workers right now
SELECT
    pid,
    now() - xact_start AS duration,
    query,
    state
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY xact_start;
```

**What this does:**
- Shows currently running autovacuum processes
- If count = max_workers consistently = **saturated** (need more workers)

#### 4.2 Worker Saturation Analysis

```sql
-- Check if workers are saturated (run every 5 minutes)
WITH worker_snapshot AS (
    SELECT
        count(*) AS active_workers,
        current_setting('autovacuum_max_workers')::int AS max_workers,
        now() AS snapshot_time
    FROM pg_stat_activity
    WHERE query LIKE 'autovacuum:%'
)
SELECT
    active_workers,
    max_workers,
    round(active_workers * 100.0 / max_workers, 2) AS utilization_pct,
    CASE
        WHEN active_workers >= max_workers THEN '🚨 SATURATED - Increase workers!'
        WHEN active_workers >= max_workers * 0.8 THEN '⚠️  HIGH - Monitor closely'
        ELSE '✅ OK'
    END AS status
FROM worker_snapshot;
```

**What this does:**
- Calculates worker utilization
- Saturated = all workers busy = tables queueing for vacuum
- If consistently > 80% = increase workers

#### 4.3 Historical Worker Demand

```sql
-- Track tables waiting for autovacuum
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    now() - last_autovacuum AS time_since_vacuum,
    
    -- Calculate threshold
    (50 + 0.2 * n_live_tup)::bigint AS autovac_threshold,
    
    -- Check if should have triggered
    CASE
        WHEN n_dead_tup > (50 + 0.2 * n_live_tup) THEN 'WAITING FOR WORKER'
        ELSE 'Below threshold'
    END AS status
    
FROM pg_stat_user_tables
WHERE n_dead_tup > (50 + 0.2 * n_live_tup)
  AND last_autovacuum < now() - interval '5 minutes'
ORDER BY n_dead_tup DESC;
```

**What this does:**
- Identifies tables that SHOULD be vacuumed but aren't
- If multiple tables in "WAITING" status = worker shortage

### Production Recommendations:

| **Scenario** | **Workers** | **Rationale** |
|--------------|-------------|---------------|
| **Small DB (< 100GB, < 50 tables)** | 3 (default) | Sufficient for low-moderate workload |
| **Medium DB (100-500GB, 50-200 tables)** | 5-8 | Multiple tables need concurrent vacuum |
| **Large DB (500GB-2TB, 200-1000 tables)** | 10-15 | High table count, diverse workloads |
| **Very Large DB (2TB+, 1000+ tables)** | 15-20 | Enterprise scale, 24/7 operations |
| **High-Churn OLTP** | 8-12 | Frequent updates need aggressive cleanup |
| **Data Warehouse** | 3-5 | Lower update volume, larger batch jobs |

### Configuration:

```sql
-- Check current setting
SHOW autovacuum_max_workers;

-- Increase workers (REQUIRES RESTART!)
ALTER SYSTEM SET autovacuum_max_workers = 8;

-- Restart required:
-- sudo systemctl restart postgresql
-- or docker restart postgres-primary
```

**WARNING:** Requires PostgreSQL restart!

### Other Related Settings:

```sql
-- Adjust naptime (how often autovacuum launcher wakes up)
ALTER SYSTEM SET autovacuum_naptime = 30; -- 30 seconds (default 60s)
SELECT pg_reload_conf(); -- No restart needed

-- Worker memory (per worker)
ALTER SYSTEM SET autovacuum_work_mem = '256MB'; -- Default uses maintenance_work_mem
SELECT pg_reload_conf();
```

### Monitoring Worker Effectiveness:

```sql
-- Create monitoring view for worker health
CREATE OR REPLACE VIEW autovacuum_worker_health AS
WITH current_workers AS (
    SELECT count(*) AS active
    FROM pg_stat_activity
    WHERE query LIKE 'autovacuum:%'
),
config AS (
    SELECT current_setting('autovacuum_max_workers')::int AS max
),
waiting_tables AS (
    SELECT count(*) AS waiting
    FROM pg_stat_user_tables
    WHERE n_dead_tup > (50 + 0.2 * n_live_tup)
      AND (last_autovacuum IS NULL OR last_autovacuum < now() - interval '10 minutes')
)
SELECT
    w.active AS active_workers,
    c.max AS max_workers,
    round(w.active * 100.0 / c.max, 2) AS utilization_pct,
    t.waiting AS tables_waiting,
    CASE
        WHEN w.active >= c.max AND t.waiting > 5 THEN '🚨 SATURATED - Increase workers!'
        WHEN w.active >= c.max * 0.8 THEN '⚠️  HIGH UTILIZATION'
        WHEN t.waiting > 10 THEN '⚠️  BACKLOG BUILDING'
        ELSE '✅ HEALTHY'
    END AS status,
    CASE
        WHEN w.active >= c.max AND t.waiting > 5 THEN 'Increase autovacuum_max_workers'
        WHEN t.waiting > 10 THEN 'Check for long transactions or tune table thresholds'
        ELSE 'No action needed'
    END AS recommendation
FROM current_workers w, config c, waiting_tables t;

-- Check daily:
SELECT * FROM autovacuum_worker_health;
```

### Interview Answer:

```
Q: "How many autovacuum workers do you configure?"

A: "It depends on database size and workload, but I follow this framework:

   ASSESSMENT:
   1. Monitor current worker utilization:
      SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'autovacuum:%';
      
   2. Check for saturation (all workers busy consistently)
   
   3. Identify tables waiting for vacuum (dead tuples above threshold)

   TYPICAL CONFIGURATIONS:
   - Small DB (< 100GB): 3 workers (default is fine)
   - Medium DB (100-500GB): 5-8 workers
   - Large DB (500GB-2TB): 10-15 workers
   - Very large (2TB+): 15-20 workers
   
   At my previous company with a 1.5TB database and 500+ tables:
   - Started with default 3 workers = saturated (backlog building)
   - Increased to 8 workers = balanced (70% utilization)
   - Peak hours: 80-90% utilization (acceptable)
   - Off-peak: 20-30% utilization
   
   KEY METRICS I TRACK:
   - Worker saturation: Alert if > 95% for > 15 minutes
   - Tables waiting: Alert if > 10 tables above threshold
   - Dead tuple age: Alert if table hasn't been vacuumed in 24h
   
   IMPORTANT: autovacuum_max_workers requires restart!
   I test changes on standby first, then failover during maintenance window.
   
   Also tune autovacuum_naptime (default 60s) to 30s for faster response,
   which doesn't require restart."
```

---

## 5. Dead Tuple Impact on Index Scans - Reaction Time

### Q: How quickly do you react when dead tuples start affecting index scans?

### Understanding the Problem:

**Dead tuples hurt performance:**
- Index still points to dead tuple location
- PostgreSQL must check each row's visibility
- More dead tuples = more wasted I/O

### Detection Queries:

#### 5.1 Index Scan Efficiency Check

```sql
-- Compare index scans vs tuples fetched
SELECT
    schemaname || '.' || relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS index_scans,
    idx_tup_read AS tuples_read_from_index,
    idx_tup_fetch AS tuples_fetched_from_heap,
    
    -- Efficiency ratio
    CASE
        WHEN idx_tup_read > 0 THEN
            round((idx_tup_fetch::numeric / idx_tup_read) * 100, 2)
        ELSE 0
    END AS fetch_ratio_pct,
    
    -- Dead tuple context from table
    (SELECT n_dead_tup FROM pg_stat_user_tables WHERE relid = i.relid) AS dead_tuples,
    (SELECT n_live_tup FROM pg_stat_user_tables WHERE relid = i.relid) AS live_tuples,
    (SELECT round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2)
     FROM pg_stat_user_tables WHERE relid = i.relid) AS dead_pct,
    
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
    
FROM pg_stat_user_indexes i
WHERE idx_scan > 100 -- Only indexes actually used
  AND idx_tup_read > 0
ORDER BY fetch_ratio_pct DESC;
```

**What this does:**
- **idx_tup_read** = rows index said exist
- **idx_tup_fetch** = rows actually returned (after visibility check)
- **High fetch_ratio** with **high dead_pct** = dead tuples causing extra work

**Example output:**
```
  table_name  |    index_name     | index_scans | tuples_read | tuples_fetched | fetch_ratio_pct | dead_tuples | dead_pct 
--------------+-------------------+-------------+-------------+----------------+-----------------+-------------+----------
 public.orders| orders_status_idx |       15234 |     1523400 |        1295890 |           85.07 |       45000 |    23.50
```

**Analysis:** 85% fetch ratio with 23% dead tuples = dead tuples increasing I/O by ~15%

#### 5.2 Query Performance Degradation Tracking

```sql
-- Track query performance over time (requires pg_stat_statements extension)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Find queries hitting tables with high dead tuple counts
SELECT
    substring(query, 1, 100) AS query_sample,
    calls,
    total_exec_time / calls AS avg_time_ms,
    stddev_exec_time AS stddev_ms,
    rows / calls AS avg_rows,
    
    -- Extract table name (simple pattern matching)
    (regexp_matches(query, 'FROM\s+(\w+)', 'i'))[1] AS table_hint
    
FROM pg_stat_statements
WHERE query LIKE '%SELECT%'
  AND calls > 100
  AND total_exec_time / calls > 10 -- Slower than 10ms average
ORDER BY total_exec_time DESC
LIMIT 20;
```

**What this does:**
- Identifies slow queries
- Cross-reference with tables having high dead_pct
- Degrading avg_time_ms over time = bloat impact

#### 5.3 Real-Time Bloat Impact Alert

```sql
-- Alert when dead tuples impact performance
CREATE OR REPLACE VIEW performance_impact_alert AS
WITH table_stats AS (
    SELECT
        schemaname || '.' || relname AS table_name,
        n_live_tup,
        n_dead_tup,
        round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
        seq_scan + idx_scan AS total_scans,
        last_autovacuum,
        now() - last_autovacuum AS time_since_vacuum
    FROM pg_stat_user_tables
    WHERE n_live_tup > 1000
),
index_stats AS (
    SELECT
        schemaname || '.' || relname AS table_name,
        count(*) AS index_count,
        sum(idx_scan) AS total_idx_scans,
        sum(idx_tup_fetch) AS total_fetches
    FROM pg_stat_user_indexes
    GROUP BY schemaname, relname
)
SELECT
    t.table_name,
    t.dead_pct,
    t.total_scans AS recent_scans,
    i.total_idx_scans,
    t.time_since_vacuum,
    
    -- Calculate impact score (higher = worse)
    (t.dead_pct * t.total_scans / 100)::bigint AS impact_score,
    
    -- Severity
    CASE
        WHEN t.dead_pct > 25 AND t.total_scans > 10000 THEN '🔴 CRITICAL - Vacuum NOW'
        WHEN t.dead_pct > 15 AND t.total_scans > 5000 THEN '🟠 HIGH - Vacuum ASAP'
        WHEN t.dead_pct > 10 AND t.total_scans > 1000 THEN '🟡 MODERATE - Schedule vacuum'
        ELSE '🟢 OK'
    END AS severity,
    
    -- Estimated performance impact
    round(t.dead_pct * i.total_idx_scans / 10000, 2) AS est_wasted_scans
    
FROM table_stats t
JOIN index_stats i ON t.table_name = i.table_name
WHERE t.dead_pct > 5
ORDER BY impact_score DESC;

-- Run every 5 minutes:
SELECT * FROM performance_impact_alert WHERE severity != '🟢 OK';
```

**What this does:**
- **Impact score** = dead_pct × scan_frequency
- High impact score = bloat actively hurting performance
- Prioritizes tables needing immediate attention

### Reaction Time Framework:

| **Severity** | **Dead %** | **Scans** | **Reaction Time** | **Action** |
|--------------|------------|-----------|-------------------|------------|
| **CRITICAL** | > 25% | > 10K/hour | < 5 minutes | Manual VACUUM immediately |
| **HIGH** | > 15% | > 5K/hour | < 30 minutes | Priority autovacuum or manual |
| **MODERATE** | > 10% | > 1K/hour | < 2 hours | Tune autovacuum, monitor |
| **LOW** | > 5% | < 1K/hour | < 24 hours | Normal autovacuum |

### Immediate Actions:

#### CRITICAL (Immediate manual intervention):

```sql
-- 1. Check for blocking transactions
SELECT
    pid,
    now() - xact_start AS duration,
    state,
    query
FROM pg_stat_activity
WHERE state != 'idle'
  AND xact_start < now() - interval '30 minutes'
ORDER BY xact_start;

-- Kill if necessary:
-- SELECT pg_terminate_backend(pid);

-- 2. Manual VACUUM (non-blocking)
VACUUM (VERBOSE, ANALYZE) orders;

-- 3. If extremely bloated (> 50%), schedule VACUUM FULL
-- VACUUM FULL orders; -- Requires exclusive lock!
```

#### HIGH (Priority handling):

```sql
-- Aggressive autovacuum tuning
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.01,  -- 1% (very aggressive)
    autovacuum_vacuum_threshold = 50,
    autovacuum_vacuum_cost_delay = 0        -- Maximum speed
);

-- Force autovacuum to run sooner
-- Wait for next naptime cycle (30-60s)
```

#### MODERATE (Tune and monitor):

```sql
-- Tune to 2-5%
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.02
);

-- Monitor for 24 hours
SELECT * FROM performance_impact_alert WHERE table_name = 'public.orders';
```

### Automated Alerting (Prometheus/Grafana):

```sql
-- Export metric for monitoring
CREATE OR REPLACE VIEW autovacuum_metrics_export AS
SELECT
    relname AS table_name,
    n_dead_tup AS dead_tuples,
    n_live_tup AS live_tuples,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_percentage,
    (seq_scan + idx_scan) AS scan_count,
    extract(epoch from (now() - last_autovacuum)) AS seconds_since_vacuum
FROM pg_stat_user_tables
WHERE n_live_tup > 1000;

-- Prometheus alerting rule:
-- ALERT HighDeadTuples
--   IF postgres_dead_percentage{table="orders"} > 15
--   FOR 10m
--   ANNOTATIONS {
--     summary = "High dead tuple percentage on {{ $labels.table }}"
--   }
```

### Interview Answer:

```
Q: "How quickly do you react when dead tuples affect index scans?"

A: "I have a tiered response based on severity:

   MONITORING:
   I track 'impact score' = dead_tuple_pct × scan_frequency
   
   Query: 
   SELECT relname, 
          n_dead_tup * 100.0 / (n_live_tup + n_dead_tup) as dead_pct,
          seq_scan + idx_scan as scans
   FROM pg_stat_user_tables
   WHERE n_dead_tup > 1000
   ORDER BY (n_dead_tup * (seq_scan + idx_scan)) DESC;

   RESPONSE TIMES:
   
   CRITICAL (dead_pct > 25%, high scan rate):
   - Reaction: < 5 minutes
   - Action: Manual VACUUM immediately
   - Check for blocking long transactions
   - Example: Production orders table hit 28% dead, 15K scans/min
     → Killed 8-hour ETL query
     → Manual VACUUM reclaimed 40GB
     → Query performance restored in 3 minutes

   HIGH (dead_pct > 15%, moderate scans):
   - Reaction: < 30 minutes  
   - Action: Aggressive autovacuum tuning (1-2% scale factor)
   - Force autovacuum with cost_delay=0
   
   MODERATE (dead_pct > 10%):
   - Reaction: < 2 hours
   - Action: Tune autovacuum to 2-5%
   - Monitor for 24 hours
   
   LOW (dead_pct > 5%):
   - Reaction: < 24 hours
   - Action: Normal autovacuum handles it
   
   PREVENTION:
   - Proactive tuning of high-update tables (2% scale factor)
   - Alert on dead_pct > 15%
   - Weekly review of index scan efficiency
   - pg_stat_statements to track query performance trends
   
   KEY INSIGHT: Dead tuples > 15% with high index scans = immediate 
   performance degradation. I aim to keep all tables < 10% dead through
   aggressive autovacuum tuning."
```

---

## 6. Autovacuum Logging - log_autovacuum_min_duration

### Q: Do you enable log_autovacuum_min_duration? What does it do?

### What It Does:

**log_autovacuum_min_duration** controls when autovacuum operations are logged.

**Values:**
- **-1** (default in some versions) = Disabled, no autovacuum logging
- **0** = Log ALL autovacuum runs (verbose, use for troubleshooting)
- **1000** (recommended) = Log only autovacuum runs taking > 1 second

### Configuration:

```sql
-- Check current setting
SHOW log_autovacuum_min_duration;

-- Enable logging for all autovacuum runs (troubleshooting)
ALTER SYSTEM SET log_autovacuum_min_duration = 0;
SELECT pg_reload_conf(); -- No restart needed

-- Production recommendation: Log runs > 1 second
ALTER SYSTEM SET log_autovacuum_min_duration = 1000; -- 1000ms = 1 second
SELECT pg_reload_conf();

-- Disable logging (not recommended!)
ALTER SYSTEM SET log_autovacuum_min_duration = -1;
SELECT pg_reload_conf();
```

### What Gets Logged:

**Example log entry:**
```
2025-11-17 18:45:32 UTC [12345]: LOG:  automatic vacuum of table "mydb.public.orders": 
    index scans: 0
    pages: 145 removed, 12567 remain, 0 skipped due to pins, 234 skipped frozen
    tuples: 45000 removed, 250000 remain, 0 are dead but not yet removable, oldest xmin: 123456789
    buffer usage: 15234 hits, 1234 misses, 567 dirtied
    avg read rate: 12.345 MB/s, avg write rate: 5.678 MB/s
    system usage: CPU: user: 2.34 s, system: 0.56 s, elapsed: 3.45 s
    WAL usage: 234 records, 45 full page images, 1234567 bytes
```

### Key Information in Logs:

| **Field** | **Meaning** | **What to Look For** |
|-----------|-------------|----------------------|
| **pages removed** | Pages freed and returned to FSM | High number = effective cleanup |
| **pages remain** | Total pages in table | Compare to removed (bloat indicator) |
| **tuples removed** | Dead tuples cleaned up | Should match n_dead_tup before vacuum |
| **tuples remain** | Live tuples still in table | Stable = healthy |
| **dead but not yet removable** | Tuples blocked by old transactions | > 0 = long transaction problem! |
| **buffer usage** | Cache hits vs misses | High misses = I/O intensive |
| **elapsed** | Total duration | > 5 min = investigate |
| **WAL usage** | Write-ahead log overhead | High = I/O cost |

### Analysis Queries:

#### 6.1 Parse Autovacuum Logs (PostgreSQL 13+)

```sql
-- Enable CSV logging for easier parsing
ALTER SYSTEM SET log_destination = 'csvlog';
ALTER SYSTEM SET logging_collector = on;
SELECT pg_reload_conf();
```

#### 6.2 Find Long-Running Autovacuum Operations

```bash
# grep PostgreSQL logs for slow autovacuums (> 5 seconds)
grep "automatic vacuum" /var/log/postgresql/postgresql-*.log | \
grep -E "elapsed: [5-9]\.[0-9]+ s|elapsed: [0-9]{2,}\.[0-9]+ s" | \
tail -20

# Example output:
# 2025-11-17 18:45:32 UTC [12345]: LOG:  automatic vacuum of table "mydb.public.orders": 
#     elapsed: 12.45 s
```

```sql
-- Check current autovacuum activity in real-time
SELECT
    pid,
    now() - xact_start AS duration,
    now() - query_start AS query_duration,
    state,
    query,
    wait_event_type,
    wait_event
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY xact_start;
```

**What this does:**
- Shows currently running autovacuum jobs
- **wait_event** tells you what it's waiting for (I/O, locks, etc.)
- Long duration = slow vacuum (check logs for details)

#### 6.3 Autovacuum blocked by long transactions

**The #1 problem causing autovacuum ineffectiveness:**

```sql
-- Find long-running transactions blocking autovacuum
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - xact_start AS transaction_age,
    now() - state_change AS idle_age,
    state,
    wait_event_type,
    wait_event,
    substring(query, 1, 100) AS query_sample
FROM pg_stat_activity
WHERE state != 'idle'
  AND xact_start < now() - interval '1 hour' -- Transactions > 1 hour
ORDER BY xact_start
LIMIT 20;
```

**What this does:**
- Identifies long-running transactions
- These prevent autovacuum from cleaning dead tuples
- Log will show: "0 dead but not yet removable" (stuck waiting)

**Solution:**
```sql
-- Kill the blocking transaction (after confirming with team!)
SELECT pg_terminate_backend(12345); -- Use PID from query above
```

### Production Best Practices:

#### Recommended Settings:

```sql
-- Initial troubleshooting: Log everything
ALTER SYSTEM SET log_autovacuum_min_duration = 0;

-- After diagnosis: Log slow operations only
ALTER SYSTEM SET log_autovacuum_min_duration = 5000; -- 5 seconds

-- Additional helpful logging:
ALTER SYSTEM SET log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h ';
ALTER SYSTEM SET log_checkpoints = on;
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_lock_waits = on; -- Very important!
ALTER SYSTEM SET deadlock_timeout = '1s';

SELECT pg_reload_conf();
```

#### Log Monitoring Script:

```bash
#!/bin/bash
# autovacuum_monitor.sh - Daily autovacuum log analysis

LOG_FILE="/var/log/postgresql/postgresql-$(date +%Y-%m-%d).log"

echo "=== Autovacuum Summary for $(date +%Y-%m-%d) ==="

echo "Total autovacuum operations:"
grep -c "automatic vacuum" "$LOG_FILE"

echo ""
echo "Slow autovacuums (> 10 seconds):"
grep "automatic vacuum" "$LOG_FILE" | \
  grep -E "elapsed: [0-9]{2,}\." | \
  wc -l

echo ""
echo "Top 10 slowest autovacuums:"
grep "automatic vacuum" "$LOG_FILE" | \
  grep -oP 'table ".*?".*elapsed: \K[0-9.]+' | \
  sort -rn | \
  head -10

echo ""
echo "Tables with dead tuples not removable (long transaction problem):"
grep "automatic vacuum" "$LOG_FILE" | \
  grep "are dead but not yet removable" | \
  grep -v "0 are dead" | \
  wc -l

echo ""
echo "Autovacuum workers busy (if high, increase max_workers):"
grep "skipping vacuum" "$LOG_FILE" | wc -l
```

### Troubleshooting with Logs:

#### Problem 1: Autovacuum Taking Too Long

**Log shows:** `elapsed: 300.45 s` (5 minutes!)

**Investigation:**
```
1. Check log for buffer usage:
   - High "misses" = table not cached (I/O bottleneck)
   
2. Check for "pages skipped due to pins":
   - High = table heavily used during vacuum
   
3. Check autovacuum_vacuum_cost_delay:
   SHOW autovacuum_vacuum_cost_delay; -- If > 2, vacuum is throttled
   
   Solution:
   ALTER TABLE orders SET (autovacuum_vacuum_cost_delay = 0);
```

#### Problem 2: Dead Tuples Not Being Removed

**Log shows:** `12000 are dead but not yet removable`

**Root cause:** Long-running transaction holding back cleanup

**Investigation:**
```sql
SELECT
    pid,
    now() - xact_start AS age,
    state,
    query
FROM pg_stat_activity
WHERE xact_start < now() - interval '30 minutes'
ORDER BY xact_start;
```

**Solution:** Kill the long transaction or commit it

#### Problem 3: Autovacuum Constantly Running

**Log shows:** Same table vacuumed every 2-3 minutes

**Root cause:** Table churning faster than autovacuum can clean

**Solution:**
```sql
-- Even more aggressive tuning
ALTER TABLE high_churn_table SET (
    autovacuum_vacuum_scale_factor = 0.01,  -- 1%
    autovacuum_vacuum_cost_delay = 0
);

-- Or partition the table to reduce churn per partition
```

### Interview Answer:

```
Q: "Do you enable log_autovacuum_min_duration? What does it do?"

A: "Yes, absolutely! It's critical for production troubleshooting.

   WHAT IT DOES:
   - Controls when autovacuum operations are logged
   - Value in milliseconds: operations taking longer than this are logged
   - Set to 0 = log ALL autovacuums
   - Set to 1000 = log autovacuums taking > 1 second
   
   MY CONFIGURATION:
   ALTER SYSTEM SET log_autovacuum_min_duration = 1000; -- 1 second
   
   This captures slow vacuums without flooding logs. During troubleshooting,
   I temporarily set to 0 to see all activity.
   
   WHAT LOGS TELL ME:
   1. Duration (elapsed time) - Slow vacuums indicate I/O bottlenecks or
      cost-based delay throttling
      
   2. "Dead but not yet removable" - Indicates long-running transactions
      blocking cleanup. This is the #1 cause of bloat in production.
      
   3. Buffer usage (hits vs misses) - High misses = table not in cache,
      causing I/O pressure
      
   4. Pages removed vs remain - Shows effectiveness of vacuum
   
   5. WAL usage - High WAL generation = I/O cost
   
   REAL EXAMPLE FROM PRODUCTION:
   Found logs showing:
   - orders table vacuumed every 5 minutes
   - Each vacuum: "25000 dead but not yet removable"
   - Traced to nightly ETL job holding transaction for 8 hours
   
   Solution:
   - Changed ETL to use cursor-based pagination (no long transaction)
   - Dead tuples dropped from 25K to < 500
   - Bloat eliminated
   
   I export these logs to centralized logging (ELK stack) and alert on:
   - Autovacuum > 30 seconds
   - "Dead but not yet removable" > 1000
   - Same table vacuumed > 10 times/hour (churn problem)
   
   KEY TAKEAWAY: Logging is essential visibility into autovacuum health.
   Without it, you're flying blind on bloat prevention."
```

---

## Summary Checklist for Interviews

### ✅ Questions You Should Be Able to Answer:

1. **Threshold Configuration:**
   - Formula: `dead_tuples > (threshold + scale_factor × n_live_tup)`
   - High-churn: 2-5% scale factor
   - Append-only: 50%+ scale factor
   - Query: `SELECT * FROM pg_stat_user_tables;`

2. **Visibility Map:**
   - Tracks all-visible pages
   - Enables index-only scans
   - Monitor with `pg_visibility` extension
   - Key metric: dead_tuple_percentage

3. **Bloat Measurement:**
   - Fast: `pg_stat_user_tables` (dead_pct)
   - Accurate: `pgstattuple()` (slow, use on replicas)
   - Index bloat: Compare size to table size
   - Alert threshold: > 15%

4. **Worker Configuration:**
   - Default: 3 workers
   - Medium DB: 5-8 workers
   - Large DB: 10-15 workers
   - Check saturation: Count active autovacuum processes
   - Requires restart to change!

5. **Dead Tuple Impact:**
   - Impact score = dead_pct × scan_frequency
   - CRITICAL (> 25% dead, high scans): React < 5 minutes
   - HIGH (> 15%): React < 30 minutes
   - Use `pg_stat_statements` to track query degradation

6. **Autovacuum Logging:**
   - `log_autovacuum_min_duration = 1000` (1 second threshold)
   - Logs show: duration, tuples removed, buffer usage, blocking transactions
   - "Dead but not yet removable" = long transaction problem
   - Essential for troubleshooting bloat issues

### 🎯 Must-Memorize Queries:

```sql
-- 1. Dead tuple check
SELECT relname, n_dead_tup * 100.0 / (n_live_tup + n_dead_tup) AS dead_pct
FROM pg_stat_user_tables WHERE n_dead_tup > 0 ORDER BY dead_pct DESC;

-- 2. Autovacuum threshold calculation
SELECT relname, n_dead_tup, (50 + 0.2 * n_live_tup)::bigint AS threshold
FROM pg_stat_user_tables WHERE n_dead_tup > (50 + 0.2 * n_live_tup);

-- 3. Active autovacuum workers
SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'autovacuum:%';

-- 4. Long-running transactions (blocks autovacuum)
SELECT pid, now() - xact_start AS age, state, query
FROM pg_stat_activity WHERE xact_start < now() - interval '1 hour';

-- 5. Bloat monitoring
SELECT relname, pg_size_pretty(pg_total_relation_size(relname::regclass)) AS size,
       n_dead_tup, last_autovacuum
FROM pg_stat_user_tables WHERE n_dead_tup > 10000;
```

---

## 7. Real-World Troubleshooting Scenarios

### Scenario 1: Table Bloat Despite Autovacuum Running

#### Problem:
```
Orders table has grown from 50GB to 250GB over 3 months.
Dead tuple percentage consistently at 40-50%.
Autovacuum runs every 10 minutes but doesn't reduce bloat.
```

#### Investigation Steps:

**Step 1: Check if autovacuum is actually running**
```sql
SELECT
    relname,
    last_autovacuum,
    last_vacuum,
    autovacuum_count,
    vacuum_count,
    n_dead_tup,
    n_live_tup,
    round(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup), 2) AS dead_pct
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

**Result:**
```
 relname |      last_autovacuum      | autovacuum_count | n_dead_tup | n_live_tup | dead_pct 
---------+---------------------------+------------------+------------+------------+----------
 orders  | 2025-11-17 14:35:22+00    |              456 |    5000000 |   5000000  |    50.00
```

✅ Autovacuum IS running (456 times)  
❌ But dead_pct stays at 50%!

**Step 2: Check autovacuum logs for "not yet removable"**
```bash
# Look for the smoking gun in logs
grep "orders" /var/log/postgresql/postgresql-*.log | grep "autovacuum" | tail -5
```

**Log shows:**
```
LOG: automatic vacuum of table "mydb.public.orders": index scans: 1
     pages: 0 removed, 32051 remain, 0 skipped due to pins, 0 skipped frozen
     tuples: 0 removed, 10000000 remain, 5000000 are dead but not yet removable
     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
     THIS IS THE PROBLEM!
```

**Step 3: Find the culprit - long-running transaction**
```sql
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    backend_start,
    xact_start,
    state_change,
    now() - xact_start AS transaction_age,
    now() - query_start AS query_age,
    state,
    wait_event_type,
    wait_event,
    query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '1 hour'
ORDER BY xact_start;
```

**Result:**
```
  pid  | usename  | application_name | transaction_age |    state    | query
-------+----------+------------------+-----------------+-------------+-------
 12345 | etl_user | DataWarehouse    | 08:15:32        | idle in txn | BEGIN;
```

🔴 **ROOT CAUSE FOUND!** ETL job has transaction open for 8+ hours!

#### Solution:

**Immediate Fix:**
```sql
-- 1. Confirm it's safe to kill (check with ETL team)
-- 2. Terminate the blocking transaction
SELECT pg_terminate_backend(12345);

-- 3. Wait 1 minute, then check if autovacuum cleans up
-- After autovacuum runs:
SELECT n_dead_tup, n_live_tup FROM pg_stat_user_tables WHERE relname = 'orders';
-- n_dead_tup should drop significantly
```

**Long-term Fix:**
```sql
-- 1. Fix ETL process to avoid long transactions
--    Use cursor-based pagination instead of single transaction

-- 2. Set statement timeout for ETL user
ALTER ROLE etl_user SET statement_timeout = '30min';

-- 3. Monitor for long transactions
CREATE OR REPLACE VIEW long_transactions AS
SELECT
    pid,
    usename,
    application_name,
    now() - xact_start AS age,
    state,
    substring(query, 1, 100) AS query
FROM pg_stat_activity
WHERE xact_start < now() - interval '30 minutes'
  AND state != 'idle'
ORDER BY xact_start;

-- Alert if any found:
SELECT * FROM long_transactions;
```

**Prevention:**
```sql
-- Add monitoring alert
-- Alert: Transaction running > 30 minutes
-- Action: Page DBA immediately
```

#### Interview Talking Point:
```
"The most common cause of autovacuum ineffectiveness is long-running transactions.
At my previous company, we had an orders table that grew from 50GB to 250GB due
to an 8-hour ETL transaction keeping dead tuples 'not yet removable'.

I identified it by:
1. Checking autovacuum logs showing '5M dead but not yet removable'
2. Querying pg_stat_activity for old transactions
3. Finding ETL job holding transaction for 8+ hours

Solution was three-fold:
- Immediate: Killed the transaction, autovacuum cleaned up 200GB
- Short-term: Set statement_timeout for ETL role
- Long-term: Redesigned ETL to use cursor pagination (no long transactions)

Result: Table stable at 50GB, no bloat issues for 2+ years."
```

---

### Scenario 2: Autovacuum Workers Saturated - Tables Queue Up

#### Problem:
```
Multiple tables showing high dead tuple percentage (15-30%).
Monitoring shows all 3 autovacuum workers constantly busy.
Some tables haven't been vacuumed in 6+ hours despite hitting threshold.
```

#### Investigation:

**Step 1: Confirm worker saturation**
```sql
-- Check current workers
SELECT
    count(*) AS active_workers,
    current_setting('autovacuum_max_workers')::int AS max_workers
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%';
```

**Result:**
```
 active_workers | max_workers 
----------------+-------------
              3 |           3
```

🔴 **100% utilization!** All workers busy.

**Step 2: See what they're working on**
```sql
SELECT
    pid,
    now() - xact_start AS duration,
    query,
    wait_event_type,
    wait_event
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY xact_start;
```

**Result:**
```
  pid  | duration  |                query                | wait_event_type | wait_event 
-------+-----------+-------------------------------------+-----------------+------------
 23456 | 00:15:23  | autovacuum: VACUUM public.orders    | IO              | DataFileRead
 23457 | 00:12:45  | autovacuum: VACUUM public.inventory | IO              | DataFileRead
 23458 | 00:08:12  | autovacuum: VACUUM public.sessions  | IO              | DataFileRead
```

All workers doing I/O for 8-15 minutes! Other tables waiting.

**Step 3: Find tables waiting for autovacuum**
```sql
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup), 2) AS dead_pct,
    pg_size_pretty(pg_total_relation_size(relname::regclass)) AS size,
    now() - last_autovacuum AS time_since_vacuum,
    (50 + 0.2 * n_live_tup)::bigint AS threshold,
    CASE 
        WHEN n_dead_tup > (50 + 0.2 * n_live_tup) THEN 'WAITING'
        ELSE 'Below threshold'
    END AS status
FROM pg_stat_user_tables
WHERE n_dead_tup > (50 + 0.2 * n_live_tup)
  AND (last_autovacuum IS NULL OR last_autovacuum < now() - interval '1 hour')
ORDER BY n_dead_tup DESC;
```

**Result:**
```
   relname    | n_dead_tup | dead_pct | size  | time_since_vacuum | status  
--------------+------------+----------+-------+-------------------+---------
 user_activity|    450000  |   22.50  | 15 GB | 06:23:15          | WAITING
 cart_items   |    320000  |   18.70  | 8 GB  | 04:15:42          | WAITING
 product_views|    280000  |   15.20  | 12 GB | 03:45:33          | WAITING
 notifications|    210000  |   12.50  | 5 GB  | 02:30:21          | WAITING
```

🔴 **4 tables queued**, oldest waiting 6+ hours!

#### Solution:

**Immediate Action - Manual Vacuum Critical Tables:**
```sql
-- Run manual VACUUM on highest priority tables (in parallel if possible)
-- Terminal 1:
VACUUM (VERBOSE, ANALYZE) user_activity;

-- Terminal 2:
VACUUM (VERBOSE, ANALYZE) cart_items;

-- Monitor progress:
SELECT
    pid,
    now() - query_start AS duration,
    query
FROM pg_stat_activity
WHERE query LIKE 'VACUUM%';
```

**Short-term Fix - Increase Workers:**
```sql
-- Check server resources first (CPU, I/O capacity)
-- If resources available, increase workers

ALTER SYSTEM SET autovacuum_max_workers = 8;

-- Requires restart!
-- Schedule maintenance window:
-- sudo systemctl restart postgresql
-- or
-- docker restart postgres-primary
```

**Medium-term Fix - Tune Large Tables:**
```sql
-- The 3 large tables (orders, inventory, sessions) are hogging workers
-- If they're append-only or low-churn, tune them to be less aggressive

-- Check update frequency:
SELECT
    relname,
    n_tup_upd / NULLIF(n_tup_ins + n_tup_upd + n_tup_del, 0) AS update_ratio,
    n_tup_ins,
    n_tup_upd,
    n_tup_del
FROM pg_stat_user_tables
WHERE relname IN ('orders', 'inventory', 'sessions');

-- If update_ratio < 0.1 (mostly inserts), make less aggressive:
ALTER TABLE sessions SET (
    autovacuum_vacuum_scale_factor = 0.1  -- 10% instead of 20%
);

-- This frees workers for high-churn tables
```

**Long-term Fix - Optimize Vacuum Speed:**
```sql
-- Make individual vacuums faster so workers free up quicker

-- 1. Increase maintenance_work_mem (more memory = faster sorting)
ALTER SYSTEM SET maintenance_work_mem = '1GB';  -- Default 64MB
SELECT pg_reload_conf();

-- 2. Reduce cost delay on fast storage (SSDs)
ALTER TABLE orders SET (
    autovacuum_vacuum_cost_delay = 0  -- No throttling
);

-- 3. Partition large tables to reduce vacuum scope
-- Example: Partition orders by date, vacuum individual partitions
```

**Monitoring Alert:**
```sql
-- Create alert for worker saturation
CREATE OR REPLACE VIEW worker_saturation_alert AS
WITH workers AS (
    SELECT
        count(*) AS active,
        current_setting('autovacuum_max_workers')::int AS max
    FROM pg_stat_activity
    WHERE query LIKE 'autovacuum:%'
),
queued AS (
    SELECT count(*) AS waiting
    FROM pg_stat_user_tables
    WHERE n_dead_tup > (50 + 0.2 * n_live_tup)
      AND (last_autovacuum IS NULL OR last_autovacuum < now() - interval '30 minutes')
)
SELECT
    w.active,
    w.max,
    q.waiting,
    round(w.active * 100.0 / w.max, 2) AS utilization_pct,
    CASE
        WHEN w.active >= w.max AND q.waiting > 5 THEN '🔴 CRITICAL - Increase workers!'
        WHEN w.active >= w.max * 0.8 THEN '🟡 WARNING - High utilization'
        ELSE '🟢 OK'
    END AS status
FROM workers w, queued q;

-- Alert if status != OK
```

#### Interview Talking Point:
```
"We had worker saturation causing a vacuum backlog. All 3 workers were busy
for 10-15 minutes each on large tables, while smaller high-churn tables
waited with 20%+ dead tuples.

I diagnosed by:
1. Confirming all workers active (pg_stat_activity)
2. Identifying 4 tables waiting 2-6 hours
3. Seeing large tables (10-15GB) monopolizing workers

Solution was multi-layered:
- Immediate: Manual VACUUM on critical waiting tables
- Short-term: Increased workers from 3 to 8 (required restart)
- Medium-term: Tuned large append-only tables to be less aggressive
- Long-term: Increased maintenance_work_mem to 1GB (faster vacuums)

Result: Worker utilization dropped to 60%, no queuing, all tables 
maintained below 10% dead tuples."
```

---

### Scenario 3: Autovacuum Runs But Table Size Doesn't Decrease

#### Problem:
```
Ran VACUUM on orders table with 40% dead tuples.
VACUUM completed successfully in 5 minutes.
Dead tuple count dropped to 0.
But table size stayed at 200GB (was 120GB before bloat).
```

#### Investigation:

**Step 1: Confirm bloat is gone but space not reclaimed**
```sql
SELECT
    relname,
    pg_size_pretty(pg_total_relation_size(relname::regclass)) AS total_size,
    pg_size_pretty(pg_relation_size(relname::regclass)) AS table_size,
    pg_size_pretty(pg_total_relation_size(relname::regclass) - pg_relation_size(relname::regclass)) AS indexes_size,
    n_live_tup,
    n_dead_tup,
    last_vacuum
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

**Result:**
```
 relname | total_size | table_size | indexes_size | n_live_tup | n_dead_tup | last_vacuum 
---------+------------+------------+--------------+------------+------------+-------------
 orders  | 200 GB     | 150 GB     | 50 GB        |   10000000 |          0 | 5 min ago
```

✅ Dead tuples = 0 (VACUUM worked)  
❌ Table still 150GB (expected ~120GB)

**Step 2: Check with pgstattuple for free space**
```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT
    table_len AS table_bytes,
    pg_size_pretty(table_len) AS table_size,
    tuple_count,
    dead_tuple_count,
    pg_size_pretty(free_space) AS free_space_available,
    round(free_percent, 2) AS free_pct
FROM pgstattuple('orders');
```

**Result:**
```
 table_size | tuple_count | dead_tuple_count | free_space_available | free_pct 
------------+-------------+------------------+----------------------+----------
 150 GB     |  10000000   |        0         | 30 GB                |   20.00
```

✅ 0 dead tuples confirmed  
⚠️ **30GB (20%) free space exists but not returned to OS**

#### Understanding:

**Why VACUUM doesn't shrink files:**
- `VACUUM` marks dead space as **FREE** (reusable)
- New INSERTs/UPDATEs will **reuse** this space
- But disk space is **NOT returned to OS**
- File size stays large

**Diagram:**
```
Before VACUUM (200GB file):
[Live][Dead][Live][Dead][Live][Dead]...

After VACUUM (200GB file - same size!):
[Live][FREE][Live][FREE][Live][FREE]...
          ↑            ↑            ↑
    Reusable space but file size unchanged
```

#### Solutions:

**Option 1: Do Nothing (Recommended)**
```
If table is actively growing, free space will be reused.
No action needed - this is NORMAL behavior.

Monitor with:
SELECT pg_size_pretty(pg_total_relation_size('orders')) AS size
FROM generate_series(1,30) 
WHERE date_part('hour', now()) = 9; -- Daily 9 AM check

If size stays flat for 1 week = space is being reused ✅
```

**Option 2: VACUUM FULL (Requires Downtime)**
```sql
-- ⚠️ WARNING: Takes EXCLUSIVE LOCK - Blocks all reads/writes!
-- Only use during maintenance window

-- Check estimated duration (rough: 1GB per minute)
SELECT pg_size_pretty(pg_total_relation_size('orders')); -- 200GB = ~3 hours

-- Run during maintenance:
VACUUM FULL orders;

-- Result: Table compacted to 120GB, 80GB returned to OS
```

**Downside of VACUUM FULL:**
- **Exclusive lock** = no queries allowed
- Very slow (hours for large tables)
- Requires 2x disk space temporarily (new copy created)
- Indexes rebuilt completely

**Option 3: pg_repack (Online, Zero Downtime)**
```bash
# Install pg_repack extension
# On Ubuntu: apt-get install postgresql-15-repack
# On RHEL: yum install pg_repack

# Run online compaction (no exclusive lock!)
pg_repack -h localhost -U postgres -d mydb -t orders

# Progress monitoring:
SELECT * FROM pg_stat_progress_cluster;
```

**Advantages of pg_repack:**
- **Online operation** = no downtime
- Queries continue during compaction
- Safer than VACUUM FULL

**Downside:**
- Requires 2x disk space during operation
- Slower than VACUUM FULL
- Requires extension installation

**Option 4: Partition the Table (Best Long-term)**
```sql
-- Partition orders by date to limit bloat per partition
-- Example: Monthly partitions

CREATE TABLE orders_2025_11 PARTITION OF orders
    FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');

CREATE TABLE orders_2025_12 PARTITION OF orders
    FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');

-- Benefits:
-- 1. Each partition is smaller (VACUUM faster)
-- 2. Can drop old partitions (instant space reclaim)
-- 3. Easier to manage bloat
```

#### Decision Matrix:

| Scenario | Recommendation | Action |
|----------|---------------|--------|
| **Table actively growing** | Do nothing | Space will be reused naturally |
| **Table size stable, free space > 30%** | pg_repack | Online compaction |
| **Maintenance window available** | VACUUM FULL | Fastest compaction |
| **Recurring bloat issue** | Partition table | Prevent future bloat |
| **Emergency (disk full)** | VACUUM FULL or DROP partitions | Immediate space recovery |

#### Interview Talking Point:
```
"A common misconception is that VACUUM shrinks table files. It doesn't.

VACUUM marks dead space as FREE for reuse, but doesn't return it to the OS.
This is by design for performance - reallocating disk blocks is expensive.

At my previous company, we had an orders table that grew from 120GB to 200GB
due to bloat. After VACUUM, dead tuples dropped to 0, but size stayed 200GB.

My analysis:
1. Confirmed 0 dead tuples (VACUUM worked correctly)
2. Used pgstattuple to find 30GB (20%) free space in table
3. Checked table growth trend - it was actively growing

Decision: Did nothing! Over 2 weeks, natural INSERT activity filled the
free space, and table reached 210GB. No wasted space.

For tables not growing, I use pg_repack for online compaction. We repack
quarterly during low-traffic periods. Benefits:
- Zero downtime (online operation)
- Reclaim 20-40% space on high-churn tables
- Indexes rebuilt, improving performance

VACUUM FULL is last resort due to exclusive locking. I only use it:
- During scheduled maintenance windows
- For archive tables with one-time cleanup
- Emergency disk space recovery

Key insight: Understand the difference between 'free space in file' vs
'space returned to OS'. VACUUM gives you the first, VACUUM FULL the second."
```

---

### Scenario 4: Index Bloat Causing Slow Queries

#### Problem:
```
Queries using orders_status_idx index are slow (500ms, was 50ms).
Table has been regularly vacuumed (no table bloat).
Index size is 15GB, table size is 5GB (index > table!).
```

#### Investigation:

**Step 1: Confirm index bloat**
```sql
SELECT
    schemaname || '.' || indexrelname AS index_name,
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    
    -- Bloat indicator: index should be smaller than table
    CASE
        WHEN pg_relation_size(indexrelid) > pg_relation_size(relid) * 2 THEN '🔴 SEVERELY BLOATED'
        WHEN pg_relation_size(indexrelid) > pg_relation_size(relid) THEN '🟠 BLOATED'
        ELSE '🟢 OK'
    END AS status,
    
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE indexrelname = 'orders_status_idx';
```

**Result:**
```
     index_name      |   table_name   | index_size | table_size |      status       | idx_scan 
---------------------+----------------+------------+------------+-------------------+----------
 orders_status_idx   | public.orders  | 15 GB      | 5 GB       | 🔴 SEVERELY BLOATED | 125000
```

🔴 **Index 3x larger than table!** Definitely bloated.

**Step 2: Use pgstattuple to measure index bloat**
```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT
    'orders_status_idx' AS index_name,
    pg_size_pretty(pg_relation_size('orders_status_idx')) AS size,
    
    -- Index statistics
    (pgstatindex('orders_status_idx')).tree_level,
    (pgstatindex('orders_status_idx')).leaf_pages,
    (pgstatindex('orders_status_idx')).empty_pages,
    (pgstatindex('orders_status_idx')).deleted_pages,
    round((pgstatindex('orders_status_idx')).avg_leaf_density, 2) AS avg_leaf_density,
    round((pgstatindex('orders_status_idx')).leaf_fragmentation, 2) AS leaf_fragmentation;
```

**Result:**
```
   index_name      | size  | tree_level | leaf_pages | empty_pages | deleted_pages | avg_leaf_density | leaf_fragmentation 
-------------------+-------+------------+------------+-------------+---------------+------------------+--------------------
 orders_status_idx | 15 GB |     4      |   1920000  |   640000    |   320000      |      35.20       |       62.50
```

**Analysis:**
- **avg_leaf_density = 35%** (should be > 80%) = **severe bloat**
- **leaf_fragmentation = 62%** (should be < 20%) = **highly fragmented**
- **empty_pages = 640K** (1/3 of pages empty!)

🔴 **Index needs REINDEX**

**Step 3: Check query performance impact**
```sql
-- Enable timing
\timing on

-- Test query performance
EXPLAIN (ANALYZE, BUFFERS) 
SELECT * FROM orders WHERE status = 'pending';
```

**Result:**
```
 Index Scan using orders_status_idx on orders  (cost=0.56..1234.67 rows=5000 width=120) 
                                                (actual time=0.234..487.523 rows=5000 loops=1)
   Buffers: shared hit=125000 read=35000
   
Planning Time: 1.234 ms
Execution Time: 489.456 ms
```

**487ms execution** with **160K buffer reads** for 5K rows = inefficient!

#### Solution:

**Option 1: REINDEX (Requires EXCLUSIVE LOCK)**
```sql
-- ⚠️ WARNING: Blocks reads/writes on table during reindex!
-- For small-medium indexes (< 10GB), acceptable downtime

REINDEX INDEX orders_status_idx;

-- Check new size:
SELECT pg_size_pretty(pg_relation_size('orders_status_idx'));
-- Expected: 5-6 GB (down from 15 GB)
```

**Downside:**
- Exclusive lock on table (blocks all queries)
- Duration: ~5-10 minutes per GB

**Option 2: REINDEX CONCURRENTLY (Online, PostgreSQL 12+)**
```sql
-- ✅ RECOMMENDED: Online reindex, no blocking!
-- Available in PostgreSQL 12+

REINDEX INDEX CONCURRENTLY orders_status_idx;

-- Monitor progress:
SELECT
    phase,
    blocks_total,
    blocks_done,
    round(blocks_done * 100.0 / NULLIF(blocks_total, 0), 2) AS pct_done
FROM pg_stat_progress_create_index;
```

**Advantages:**
- **No blocking** - queries continue normally
- Safe for production during business hours

**Downside:**
- Takes 2-3x longer than regular REINDEX
- Requires 2x disk space temporarily

**Option 3: DROP + CREATE INDEX CONCURRENTLY**
```sql
-- If REINDEX CONCURRENTLY not available (PostgreSQL < 12)

-- Step 1: Create new index with different name
CREATE INDEX CONCURRENTLY orders_status_idx_new 
ON orders(status);

-- Step 2: Test new index works
SET enable_seqscan = off;
EXPLAIN SELECT * FROM orders WHERE status = 'pending';
-- Should use orders_status_idx_new

-- Step 3: Drop old bloated index
DROP INDEX orders_status_idx;

-- Step 4: Rename new index
ALTER INDEX orders_status_idx_new RENAME TO orders_status_idx;
```

**Option 4: Automated Index Maintenance**
```sql
-- Schedule monthly reindex for problem indexes
-- Via cron or pg_cron extension

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every 1st day of month at 2 AM
SELECT cron.schedule('reindex-orders-status', '0 2 1 * *', 
    'REINDEX INDEX CONCURRENTLY orders_status_idx');
```

#### Prevention:

**Identify indexes at risk:**
```sql
CREATE OR REPLACE VIEW index_bloat_monitoring AS
SELECT
    schemaname || '.' || indexrelname AS index_name,
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    
    -- Size ratio (index should be smaller than table generally)
    round(pg_relation_size(indexrelid)::numeric / 
          NULLIF(pg_relation_size(relid), 0), 2) AS size_ratio,
    
    idx_scan,
    
    -- Alert status
    CASE
        WHEN pg_relation_size(indexrelid) > pg_relation_size(relid) * 3 THEN '🔴 CRITICAL - REINDEX NOW'
        WHEN pg_relation_size(indexrelid) > pg_relation_size(relid) * 2 THEN '🟠 HIGH - Schedule REINDEX'
        WHEN pg_relation_size(indexrelid) > pg_relation_size(relid) THEN '🟡 MODERATE - Monitor'
        ELSE '🟢 OK'
    END AS status,
    
    now() - pg_stat_file('base/' || pg_relation_filenode(indexrelid))::record::text::timestamp AS index_age
    
FROM pg_stat_user_indexes
WHERE pg_relation_size(indexrelid) > 10485760 -- > 10MB
ORDER BY size_ratio DESC;

-- Weekly check:
SELECT * FROM index_bloat_monitoring WHERE status != '🟢 OK';
```

**After REINDEX - Verify Performance:**
```sql
-- Reset stats
SELECT pg_stat_reset_single_table_counters('orders'::regclass);

-- Test query again
EXPLAIN (ANALYZE, BUFFERS) 
SELECT * FROM orders WHERE status = 'pending';
```

**Expected Result:**
```
 Index Scan using orders_status_idx on orders  (cost=0.56..234.67 rows=5000 width=120) 
                                                (actual time=0.123..45.234 rows=5000 loops=1)
   Buffers: shared hit=5234
   
Execution Time: 47.123 ms
```

✅ **10x improvement!** 489ms → 47ms

#### Interview Talking Point:
```
"We had a production incident where order search queries degraded from 50ms
to 500ms. CPU and memory were fine, but queries were slow.

Investigation revealed index bloat:
- orders_status_idx was 15GB (table was only 5GB!)
- Index leaf density at 35% (should be > 80%)
- 62% fragmentation

Root cause: Frequent UPDATEs to status column created index bloat.
Table VACUUM doesn't fix index bloat - indexes need separate maintenance.

Solution:
1. Immediate: REINDEX CONCURRENTLY orders_status_idx (no downtime)
   - Index size dropped from 15GB to 6GB
   - Query performance restored: 500ms → 50ms
   
2. Short-term: Identified 5 other bloated indexes, scheduled REINDEXing
   
3. Long-term: Set up automated monitoring
   - Alert: index > 2x table size
   - Monthly REINDEX CONCURRENTLY for high-churn indexes via pg_cron
   - Created index_bloat_monitoring view

Key lesson: VACUUM maintains tables, but indexes need separate attention.
High-churn tables with frequent UPDATEs need regular REINDEX maintenance.

I now monitor index/table size ratio weekly and REINDEX any index > 2x its
table size. This prevents performance degradation before users notice."
```

---

### Scenario 5: Autovacuum Causing I/O Spikes and Performance Issues

#### Problem:
```
Every hour at :00, application becomes slow for 10-15 minutes.
Database I/O spikes to 100% disk utilization.
CPU is fine (20-30%).
Correlates exactly with autovacuum running on large tables.
```

#### Investigation:

**Step 1: Confirm autovacuum is causing I/O spikes**
```sql
-- Check active autovacuum and their I/O
SELECT
    pid,
    now() - query_start AS duration,
    query,
    wait_event_type,
    wait_event,
    
    -- I/O stats per backend (PostgreSQL 13+)
    (SELECT sum(reads + writes + writebacks) 
     FROM pg_stat_io 
     WHERE backend_type = 'autovacuum worker') AS total_io
     
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY query_start;
```

**Result:**
```
  pid  | duration  |              query               | wait_event_type | wait_event | total_io 
-------+-----------+----------------------------------+-----------------+------------+----------
 34567 | 00:12:34  | autovacuum: VACUUM public.orders | IO              | DataFileRead | 1250000
```

**Step 2: Check disk I/O during autovacuum**
```bash
# Monitor disk I/O in real-time
iostat -x 5

# Output shows:
Device  r/s    w/s    rkB/s   wkB/s  %util
sda     8234   2345   650000  180000  100.00  ← 100% disk utilization!
```

**Step 3: Check autovacuum I/O settings**
```sql
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name IN (
    'autovacuum_vacuum_cost_delay',
    'autovacuum_vacuum_cost_limit',
    'vacuum_cost_page_hit',
    'vacuum_cost_page_miss',
    'vacuum_cost_page_dirty'
)
ORDER BY name;
```

**Result:**
```
            name                 | setting | unit |           short_desc
---------------------------------+---------+------+------------------------------------
autovacuum_vacuum_cost_delay     |    2    | ms   | Sleep after reaching cost limit
autovacuum_vacuum_cost_limit     |   200   |      | Cost limit before sleeping
vacuum_cost_page_hit             |    1    |      | Cost for page in cache
vacuum_cost_page_miss            |   10    |      | Cost for page read from disk
vacuum_cost_page_dirty           |   20    |      | Cost for dirtying a page
```

#### Understanding Cost-Based Delay:

**How it works:**
1. Autovacuum accumulates "cost" as it processes pages
   - Page in cache = 1 cost
   - Page read from disk = 10 cost
   - Page dirtied (written) = 20 cost

2. When cost reaches limit (200), autovacuum **sleeps** for delay (2ms)

3. This throttles I/O to prevent overwhelming the system

**Problem:** Default settings too aggressive for large tables on slow storage!

**Calculation:**
```
200 cost limit / 20 cost per dirty page = 10 dirty pages before sleep
10 pages × 8KB = 80KB processed, then 2ms sleep
80KB / 2ms = 40 MB/s maximum write rate (too slow!)

For 50GB table: 50,000 MB / 40 MB/s = 1,250 seconds = 20 minutes!
```

#### Solutions:

**Option 1: Increase Cost Limit (Allow More Work Before Sleep)**
```sql
-- Global increase
ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 2000; -- 10x higher (default 200)
SELECT pg_reload_conf();

-- Or per-table (for critical high-I/O tables)
ALTER TABLE orders SET (
    autovacuum_vacuum_cost_limit = 5000
);
```

**Effect:** Autovacuum does more work before sleeping → faster vacuum → shorter I/O spike

**Option 2: Decrease Cost Delay (Sleep Less)**
```sql
-- Reduce sleep time
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 0; -- No sleeping (max speed)
SELECT pg_reload_conf();

-- ⚠️ WARNING: Only for SSD storage! HDD will get overwhelmed.
```

**Effect:** No throttling → very fast vacuum but **maximum I/O impact**

**Option 3: Spread Autovacuum Load (Adjust Naptime)**
```sql
-- Default naptime = 60 seconds (all tables checked every minute)
-- Reduce to check more frequently but do less work each time

ALTER SYSTEM SET autovacuum_naptime = 30; -- 30 seconds (check 2x as often)
SELECT pg_reload_conf();
```

**Effect:** Smaller, more frequent vacuums → spread I/O load over time

**Option 4: Schedule Autovacuum for Off-Peak Hours**
```sql
-- Disable autovacuum during peak hours (9 AM - 5 PM)
-- Run manual VACUUM during off-peak

-- Disable for specific table during peak:
ALTER TABLE orders SET (
    autovacuum_enabled = false
);

-- Cron job to run VACUUM at 2 AM:
-- 0 2 * * * psql -c "VACUUM (VERBOSE, ANALYZE) orders;"

-- Re-enable autovacuum for emergencies:
ALTER TABLE orders SET (
    autovacuum_enabled = true,
    autovacuum_vacuum_scale_factor = 0.5  -- Very high threshold
);
```

**Option 5: Tune Per-Table Based on Priority**
```sql
-- Critical tables: Fast vacuum, no throttling
ALTER TABLE orders SET (
    autovacuum_vacuum_cost_delay = 0,
    autovacuum_vacuum_cost_limit = 10000
);

-- Non-critical tables: Heavy throttling
ALTER TABLE audit_logs SET (
    autovacuum_vacuum_cost_delay = 10,  -- 10ms sleep (5x default)
    autovacuum_vacuum_cost_limit = 100  -- Low limit
);
```

**Balanced Production Configuration:**
```sql
-- For SSD storage with 8 workers
ALTER SYSTEM SET autovacuum_max_workers = 8;
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 2;     -- Keep default
ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 1000;  -- 5x increase
ALTER SYSTEM SET autovacuum_naptime = 30;              -- Check 2x as often
ALTER SYSTEM SET maintenance_work_mem = '1GB';         -- Faster vacuums

-- Restart required for max_workers
-- Reload for others:
SELECT pg_reload_conf();

-- Per-table tuning:
-- High-update OLTP tables
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_cost_delay = 0  -- SSD only!
);

-- Large analytical tables
ALTER TABLE event_logs SET (
    autovacuum_vacuum_scale_factor = 0.3,
    autovacuum_vacuum_cost_delay = 5  -- Throttle heavily
);
```

#### Monitoring I/O Impact:

```sql
-- Create real-time I/O monitoring view
CREATE OR REPLACE VIEW autovacuum_io_impact AS
SELECT
    a.pid,
    a.query,
    now() - a.query_start AS duration,
    a.wait_event,
    
    -- Table being vacuumed
    regexp_replace(a.query, '.*VACUUM (\S+).*', '\1') AS target_table,
    
    -- Table size
    pg_size_pretty(pg_total_relation_size(
        regexp_replace(a.query, '.*VACUUM (\S+).*', '\1')::regclass
    )) AS table_size,
    
    -- I/O stats
    CASE
        WHEN a.wait_event_type = 'IO' THEN '🔴 I/O Wait'
        ELSE '🟢 Processing'
    END AS status
    
FROM pg_stat_activity a
WHERE a.query LIKE 'autovacuum:%';

-- Monitor:
SELECT * FROM autovacuum_io_impact;
```

#### Interview Talking Point:
```
"We had mysterious hourly performance degradation - application responses
went from 50ms to 500ms every hour for 10-15 minutes.

Investigation showed:
1. Disk I/O spiked to 100% utilization exactly when issues occurred
2. Autovacuum was running on 50GB tables during these times
3. Default cost settings: delay=2ms, limit=200
4. Calculation: 50GB / 40 MB/s = 20+ minutes to vacuum

Root cause: Cost-based throttling was too conservative for our SSD storage,
causing long-running vacuums that blocked I/O for other operations.

Solution layered approach:
1. Immediate: Increased cost_limit from 200 to 1000 globally
   - Vacuums 5x faster, I/O spike reduced to 3-5 minutes
   
2. Short-term: Tuned per-table based on priority
   - Critical tables (orders): cost_delay=0 (max speed, SSD safe)
   - Non-critical (audit_logs): cost_delay=10 (heavy throttling)
   
3. Long-term: Adjusted naptime from 60s to 30s
   - Smaller, more frequent vacuums
   - Spread I/O load instead of large spikes
   
4. Capacity planning: Increased maintenance_work_mem to 1GB
   - Faster index cleanup during vacuum
   
Result: 
- I/O spikes eliminated
- Autovacuum still prevents bloat but doesn't impact users
- Performance stable 24/7

Key insight: Cost-based delay is critical for throttling, but defaults
are for HDDs. SSDs can handle much more aggressive settings. I now tune
based on storage type:
- SSDs: cost_delay=0-2, cost_limit=1000-5000
- HDDs: cost_delay=5-10, cost_limit=200-500

Monitor disk utilization during autovacuum and adjust accordingly."
```

---

## Summary: Troubleshooting Decision Tree

```
┌─────────────────────────────────────┐
│   Autovacuum Problem Detected?      │
└──────────────┬──────────────────────┘
               │
               ▼
     ┌─────────────────────┐
     │ What's the symptom? │
     └─────────┬───────────┘
               │
    ┌──────────┴────────────────────────────────────┐
    │                                                │
    ▼                                                ▼
┌────────────────────┐                    ┌──────────────────────┐
│ High dead tuple %  │                    │   Table bloated but  │
│ (> 15%) despite    │                    │   VACUUM did nothing │
│ autovacuum running │                    └──────────┬───────────┘
└─────────┬──────────┘                               │
          │                                          ▼
          ▼                                   ┌─────────────────┐
  Check logs for:                             │ NORMAL behavior │
  "dead but not yet                           │ Space marked    │
  removable"                                  │ FREE for reuse  │
          │                                   └─────────┬───────┘
          ▼                                             │
  ┌────────────────┐                                   ▼
  │ Find long      │                            ┌────────────────┐
  │ transactions:  │                            │ If space not   │
  │ pg_stat_       │                            │ being reused:  │
  │ activity       │                            │ - VACUUM FULL  │
  └────────┬───────┘                            │ - pg_repack    │
           │                                    │ - Partition    │
           ▼                                    └────────────────┘
  ┌─────────────────┐
  │ Kill transaction│
  │ pg_terminate_   │
  │ backend()       │
  └─────────────────┘

    │
    ▼
┌──────────────────────┐
│ Multiple tables      │
│ waiting for vacuum   │
│ (workers saturated)  │
└──────────┬───────────┘
           │
           ▼
  ┌──────────────────┐
  │ Check worker     │
  │ utilization:     │
  │ 100% = saturated │
  └─────────┬────────┘
            │
            ▼
  ┌─────────────────────┐
  │ Solutions:          │
  │ 1. Increase workers │
  │ 2. Manual VACUUM    │
  │ 3. Tune large tables│
  └─────────────────────┘

    │
    ▼
┌──────────────────────┐
│ Queries slow on      │
│ specific index       │
└──────────┬───────────┘
           │
           ▼
  ┌──────────────────┐
  │ Check index size │
  │ vs table size    │
  └─────────┬────────┘
            │
            ▼
  ┌──────────────────────┐
  │ If index > 2x table: │
  │ REINDEX CONCURRENTLY │
  └──────────────────────┘

    │
    ▼
┌──────────────────────┐
│ I/O spikes during    │
│ autovacuum           │
└──────────┬───────────┘
           │
           ▼
  ┌─────────────────────┐
  │ Check cost settings │
  └─────────┬───────────┘
            │
            ▼
  ┌──────────────────────────┐
  │ Solutions:               │
  │ - Increase cost_limit    │
  │ - Decrease cost_delay    │
  │ - Spread load (naptime)  │
  │ - Per-table tuning       │
  └──────────────────────────┘
```

---

**End of Production Best Practices Guide** ✅

This comprehensive document covers:
- 6 critical production questions senior DBAs must answer
- 5 real-world troubleshooting scenarios with complete solutions
- Decision trees for rapid problem diagnosis
- Interview-ready talking points for each scenario

Master these concepts and you'll be prepared for any PostgreSQL autovacuum question in senior DBA interviews!
