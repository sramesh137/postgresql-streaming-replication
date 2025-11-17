# Scenario 15: Autovacuum Optimization and Tuning

**Objective:** Master autovacuum configuration, monitoring, and tuning for different workload patterns

**Duration:** 30-40 minutes

**Prerequisites:**
- PostgreSQL cluster running
- Completed Scenario 14 (VACUUM basics)
- Understanding of autovacuum trigger formula

---

## 📋 What We'll Learn

1. Understanding autovacuum trigger thresholds
2. Monitoring autovacuum activity
3. Tuning for different table types
4. Preventing autovacuum issues
5. Troubleshooting blocked autovacuum

---

## Step 1: Understanding Current Autovacuum Configuration

### 1.1: Check Global Autovacuum Settings
```bash
docker exec -it postgres-primary psql -U postgres
```

```sql
-- View all autovacuum settings
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE 'autovacuum%'
ORDER BY name;
```

**Expected Output:**
```
                name                 | setting |  unit  |                    short_desc                     
-------------------------------------+---------+--------+---------------------------------------------------
 autovacuum                          | on      |        | Starts the autovacuum subprocess.
 autovacuum_analyze_scale_factor     | 0.1     |        | Number of tuple inserts, updates, or deletes prior to analyze as a fraction of reltuples.
 autovacuum_analyze_threshold        | 50      |        | Minimum number of tuple inserts, updates, or deletes prior to analyze.
 autovacuum_freeze_max_age           | 200000000|       | Age at which to autovacuum a table to prevent transaction ID wraparound.
 autovacuum_max_workers              | 3       |        | Sets the maximum number of simultaneously running autovacuum worker processes.
 autovacuum_multixact_freeze_max_age | 400000000|       | Multixact age at which to autovacuum a table to prevent multixact wraparound.
 autovacuum_naptime                  | 60      | s      | Time to sleep between autovacuum runs.
 autovacuum_vacuum_cost_delay        | 2       | ms     | Vacuum cost delay in milliseconds, for autovacuum.
 autovacuum_vacuum_cost_limit        | -1      |        | Vacuum cost amount available before napping, for autovacuum.
 autovacuum_vacuum_insert_scale_factor| 0.2    |        | Number of tuple inserts prior to vacuum as a fraction of reltuples.
 autovacuum_vacuum_insert_threshold  | 1000    |        | Minimum number of tuple inserts prior to vacuum.
 autovacuum_vacuum_scale_factor      | 0.2     |        | Number of tuple updates or deletes prior to vacuum as a fraction of reltuples.
 autovacuum_vacuum_threshold         | 50      |        | Minimum number of tuple updates or deletes prior to vacuum.
 autovacuum_work_mem                 | -1      | kB     | Sets the maximum memory to be used by each autovacuum worker process.
```

**Key Settings Explained:**

| Setting | Default | Meaning |
|---------|---------|---------|
| `autovacuum` | on | Enable/disable autovacuum |
| `autovacuum_max_workers` | 3 | Max concurrent autovacuum processes |
| `autovacuum_naptime` | 60s | Check interval between rounds |
| `autovacuum_vacuum_threshold` | 50 | Min dead tuples to trigger |
| `autovacuum_vacuum_scale_factor` | 0.2 | % of table (20%) |
| `autovacuum_vacuum_cost_delay` | 2ms | Throttle delay per page |

### 1.2: Calculate When Autovacuum Triggers
```sql
-- Create function to calculate autovacuum threshold
CREATE OR REPLACE FUNCTION autovacuum_threshold(
    table_name text,
    threshold int DEFAULT 50,
    scale_factor numeric DEFAULT 0.2
)
RETURNS TABLE(
    relname text,
    live_tuples bigint,
    dead_tuples bigint,
    threshold_value bigint,
    will_trigger boolean,
    dead_tuples_needed bigint
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.relname::text,
        t.n_live_tup,
        t.n_dead_tup,
        (threshold + (scale_factor * t.n_live_tup))::bigint AS threshold_val,
        t.n_dead_tup > (threshold + (scale_factor * t.n_live_tup)) AS triggers,
        GREATEST(0, (threshold + (scale_factor * t.n_live_tup))::bigint - t.n_dead_tup) AS needed
    FROM pg_stat_user_tables t
    WHERE t.relname = table_name;
END;
$$ LANGUAGE plpgsql;

-- Test with existing table
SELECT * FROM autovacuum_threshold('perf_test');
```

**Example Output:**
```
 relname   | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
-----------+-------------+-------------+-----------------+--------------+--------------------
 perf_test |        2202 |           0 |             490 | f            |                490
```

**Interpretation:**
- Table has 2,202 live tuples
- Threshold = 50 + (0.2 × 2,202) = 490 dead tuples
- Currently 0 dead tuples → autovacuum won't trigger
- Needs 490 dead tuples to trigger

---

## Step 2: Monitoring Autovacuum Activity

### 2.1: Create Comprehensive Monitoring View
```sql
CREATE OR REPLACE VIEW autovacuum_status AS
SELECT
    schemaname || '.' || relname AS table_name,
    n_live_tup AS live_tuples,
    n_dead_tup AS dead_tuples,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    (50 + (0.2 * n_live_tup))::bigint AS autovac_threshold,
    CASE
        WHEN n_dead_tup > (50 + (0.2 * n_live_tup)) THEN 'WILL TRIGGER'
        ELSE 'OK'
    END AS status,
    last_vacuum,
    last_autovacuum,
    vacuum_count,
    autovacuum_count,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size
FROM pg_stat_user_tables
WHERE n_live_tup > 0
ORDER BY n_dead_tup DESC;

-- Use it
SELECT * FROM autovacuum_status;
```

**Expected Output:**
```
   table_name   | live_tuples | dead_tuples | dead_pct | autovac_threshold |   status    |     last_vacuum     |   last_autovacuum   | vacuum_count | autovacuum_count | total_size 
----------------+-------------+-------------+----------+-------------------+-------------+---------------------+---------------------+--------------+------------------+------------
 public.perf_test|        2202 |           0 |     0.00 |               490 | OK          | 2025-11-17 16:30:00 |                     |            3 |                0 | 144 kB
```

### 2.2: Check Active Autovacuum Processes
```sql
-- See running autovacuum workers
SELECT
    pid,
    now() - query_start AS duration,
    query
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%'
ORDER BY query_start;
```

**When autovacuum is running:**
```
  pid  |   duration   |                              query                               
-------+--------------+------------------------------------------------------------------
 12345 | 00:00:23.456 | autovacuum: VACUUM public.large_table (to prevent wraparound)
```

### 2.3: Enable Autovacuum Logging
```sql
-- Log all autovacuum activity (in postgresql.conf or ALTER SYSTEM)
ALTER SYSTEM SET log_autovacuum_min_duration = 0;  -- Log everything (0ms+)
-- Or: = 1000 to log only runs taking > 1 second

-- Reload config
SELECT pg_reload_conf();
```

**Check logs:**
```bash
docker exec postgres-primary tail -f /var/log/postgresql/postgresql*.log | grep autovacuum
```

---

## Step 3: Tuning for Different Workload Patterns

### 3.1: Scenario A - High-Frequency Update Table (Orders, Transactions)

**Problem:** Small table, but very frequent updates (e.g., order status changes)

```sql
-- Create high-update table
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    order_number VARCHAR(50),
    status VARCHAR(20),
    total DECIMAL(10,2),
    updated_at TIMESTAMP DEFAULT now()
);

-- Insert sample data
INSERT INTO orders (order_number, status, total)
SELECT
    'ORD-' || i,
    'pending',
    (random() * 1000)::decimal(10,2)
FROM generate_series(1, 10000) i;
```

**Default autovacuum threshold:**
```
Threshold = 50 + (0.2 × 10,000) = 2,050 dead tuples
```

**Problem:** By time autovacuum triggers, 20% of table is dead → poor performance

**Solution:** Make autovacuum more aggressive
```sql
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.02,     -- 2% instead of 20%
    autovacuum_vacuum_threshold = 50,
    autovacuum_vacuum_cost_delay = 0,          -- No throttling (faster)
    autovacuum_analyze_scale_factor = 0.01     -- Analyze at 1%
);

-- Verify
SELECT reloptions FROM pg_class WHERE relname = 'orders';
```

**New threshold:**
```
Threshold = 50 + (0.02 × 10,000) = 250 dead tuples (much better!)
```

**Test it:**
```sql
-- Create dead tuples
UPDATE orders SET status = 'processing' WHERE id <= 300;

-- Check status
SELECT * FROM autovacuum_threshold('orders', 50, 0.02);
```

**Expected Output:**
```
 relname | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
---------+-------------+-------------+-----------------+--------------+--------------------
 orders  |       10000 |         300 |             250 | t            |                  0
                                               ^--- Will trigger! ✅
```

### 3.2: Scenario B - Large Append-Only Table (Logs, Events)

**Problem:** Huge table, mostly INSERTs, rare DELETEs, autovacuum too aggressive

```sql
-- Create append-only table
CREATE TABLE event_logs (
    id BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(50),
    event_data JSONB,
    created_at TIMESTAMP DEFAULT now()
);

-- Insert large dataset
INSERT INTO event_logs (event_type, event_data)
SELECT
    'event_' || (i % 10),
    jsonb_build_object('data', 'x')
FROM generate_series(1, 1000000) i;
```

**Default autovacuum threshold:**
```
Threshold = 50 + (0.2 × 1,000,000) = 200,050 dead tuples
```

**Problem:** Autovacuum rarely needed (no UPDATEs/DELETEs), but runs anyway checking table

**Solution:** Make autovacuum less aggressive (save resources)
```sql
ALTER TABLE event_logs SET (
    autovacuum_vacuum_scale_factor = 0.5,      -- 50% (very high)
    autovacuum_vacuum_threshold = 10000,       -- Higher threshold
    autovacuum_analyze_scale_factor = 0.05     -- Still analyze for query planner
);
```

**New threshold:**
```
Threshold = 10,000 + (0.5 × 1,000,000) = 510,000 dead tuples
```

**Rationale:** This table won't reach 510K dead tuples (append-only), so autovacuum won't waste time vacuuming. But ANALYZE still runs for statistics.

### 3.3: Scenario C - Archive Table (Historical Data)

**Problem:** Old data, never updated, autovacuum wastes resources

```sql
-- Create archive table
CREATE TABLE archive_2024 (
    id BIGINT PRIMARY KEY,
    data TEXT,
    archived_at TIMESTAMP DEFAULT now()
);

-- Insert historical data
INSERT INTO archive_2024 (id, data)
SELECT i, 'archived_data_' || i
FROM generate_series(1, 500000) i;
```

**Solution:** Disable autovacuum completely
```sql
ALTER TABLE archive_2024 SET (
    autovacuum_enabled = false  -- Don't autovacuum this table
);
```

**When to manually vacuum:**
```sql
-- After bulk load or rare updates
VACUUM ANALYZE archive_2024;
```

### 3.4: Scenario D - Partitioned Table

**Problem:** Parent table and child partitions may need different settings

```sql
-- Create partitioned table
CREATE TABLE measurements (
    id SERIAL,
    sensor_id INT,
    value DECIMAL(10,2),
    measured_at TIMESTAMP,
    PRIMARY KEY (id, measured_at)
) PARTITION BY RANGE (measured_at);

-- Create partitions
CREATE TABLE measurements_2024_11 PARTITION OF measurements
    FOR VALUES FROM ('2024-11-01') TO ('2024-12-01');

CREATE TABLE measurements_2024_12 PARTITION OF measurements
    FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

-- Current month: high activity
ALTER TABLE measurements_2024_12 SET (
    autovacuum_vacuum_scale_factor = 0.05
);

-- Old month: low activity
ALTER TABLE measurements_2024_11 SET (
    autovacuum_vacuum_scale_factor = 0.5
);
```

---

## Step 4: Identifying Autovacuum Problems

### 4.1: Tables Never Autovacuumed
```sql
-- Find tables never autovacuumed
SELECT
    schemaname || '.' || relname AS table_name,
    n_live_tup,
    n_dead_tup,
    last_autovacuum,
    now() - last_autovacuum AS time_since_av,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS size
FROM pg_stat_user_tables
WHERE (last_autovacuum IS NULL OR last_autovacuum < now() - interval '7 days')
  AND n_live_tup > 1000
ORDER BY n_dead_tup DESC;
```

**If tables found:**
- Check if autovacuum enabled: `SHOW autovacuum;`
- Check for long-running transactions blocking cleanup
- Check autovacuum workers not saturated

### 4.2: Long-Running Transactions Blocking Autovacuum
```sql
-- Find transactions blocking VACUUM
SELECT
    pid,
    now() - xact_start AS duration,
    state,
    query,
    backend_xmin
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL  -- Holding back vacuum
  AND state != 'idle'
ORDER BY xact_start;
```

**If found:**
```sql
-- Kill blocking transaction (carefully!)
SELECT pg_terminate_backend(12345);  -- Replace with actual PID
```

### 4.3: Autovacuum Workers Saturated
```sql
-- Check worker utilization
WITH worker_activity AS (
    SELECT count(*) AS active_workers
    FROM pg_stat_activity
    WHERE query LIKE 'autovacuum:%'
),
worker_config AS (
    SELECT setting::int AS max_workers
    FROM pg_settings
    WHERE name = 'autovacuum_max_workers'
)
SELECT
    a.active_workers,
    c.max_workers,
    round(a.active_workers * 100.0 / c.max_workers, 2) AS utilization_pct,
    CASE
        WHEN a.active_workers >= c.max_workers THEN 'SATURATED - Increase max_workers!'
        ELSE 'OK'
    END AS status
FROM worker_activity a, worker_config c;
```

**Expected Output:**
```
 active_workers | max_workers | utilization_pct |       status        
----------------+-------------+-----------------+---------------------
              0 |           3 |            0.00 | OK

-- Or if saturated:
 active_workers | max_workers | utilization_pct |           status            
----------------+-------------+-----------------+-----------------------------
              3 |           3 |          100.00 | SATURATED - Increase max_workers!
```

**Fix:**
```sql
-- Increase workers (requires restart)
ALTER SYSTEM SET autovacuum_max_workers = 6;
-- Then restart PostgreSQL
```

---

## Step 5: Advanced Tuning - Cost-Based Delay

### 5.1: Understanding Cost-Based Vacuum Delay

**Purpose:** Prevent autovacuum from overwhelming I/O system

**How it works:**
1. Autovacuum accumulates "cost" for each page read/write
2. When cost reaches `autovacuum_vacuum_cost_limit`, process sleeps for `autovacuum_vacuum_cost_delay`
3. This throttles I/O impact

**Cost calculation:**
```
- Hit (buffer cache): cost = 1
- Miss (disk read): cost = vacuum_cost_page_miss (default 2)
- Dirty page: cost = vacuum_cost_page_dirty (default 20)
```

### 5.2: Aggressive Autovacuum (Low Latency Systems)
```sql
-- Faster autovacuum, higher I/O impact
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 0;     -- No delay
ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 1000;  -- Higher limit
SELECT pg_reload_conf();
```

**When to use:**
- SSDs with high IOPS
- Low-traffic periods
- Critical tables need fast cleanup

### 5.3: Conservative Autovacuum (High-Traffic Systems)
```sql
-- Slower autovacuum, lower I/O impact
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 10;   -- 10ms delay
ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 200;  -- Lower limit
SELECT pg_reload_conf();
```

**When to use:**
- HDDs with limited IOPS
- High-traffic production
- Prevent autovacuum from impacting queries

---

## Step 6: Hands-on Autovacuum Testing

### 6.1: Simulate Autovacuum Trigger
```sql
-- Use orders table from earlier
-- Check current status
SELECT * FROM autovacuum_threshold('orders', 50, 0.02);

-- Create exactly enough dead tuples to trigger
-- (If threshold is 250, update 251 rows)
UPDATE orders SET status = 'shipped' WHERE id <= 251;

-- Verify will trigger
SELECT * FROM autovacuum_threshold('orders', 50, 0.02);
```

**Expected Output:**
```
 relname | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
---------+-------------+-------------+-----------------+--------------+--------------------
 orders  |       10000 |         251 |             250 | t            |                  0
                                               ^--- Yes! ✅
```

### 6.2: Watch Autovacuum Run
```bash
# Terminal 1: Watch logs
docker exec postgres-primary tail -f /var/log/postgresql/postgresql*.log | grep -i autovacuum

# Wait 60 seconds (autovacuum_naptime = 1min)
# You should see:
# LOG: automatic vacuum of table "postgres.public.orders": ...
```

### 6.3: Verify Cleanup
```sql
-- Check dead tuples after autovacuum
SELECT
    relname,
    n_dead_tup,
    last_autovacuum,
    autovacuum_count
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

**Expected Output:**
```
 relname | n_dead_tup |     last_autovacuum     | autovacuum_count 
---------+------------+-------------------------+------------------
 orders  |          0 | 2025-11-17 17:45:12.345 |                1
               ^--- Cleaned up! ✅
```

---

## 📊 Tuning Summary Table

| **Table Type** | **Workload** | **Scale Factor** | **Threshold** | **Cost Delay** | **Rationale** |
|----------------|--------------|------------------|---------------|----------------|---------------|
| **OLTP Orders** | High UPDATE frequency | 0.02 (2%) | 50 | 0 | Fast cleanup, prevent bloat |
| **Event Logs** | Append-only (INSERTs) | 0.5 (50%) | 10000 | 10 | Rare cleanup needed, save resources |
| **Archive** | Read-only | disabled | N/A | N/A | No updates, no autovacuum |
| **Current Partition** | Active writes | 0.05 (5%) | 50 | 2 | Moderate cleanup |
| **Old Partition** | Historical | 0.5 (50%) | 1000 | 10 | Minimal cleanup |
| **Reference Data** | Rare updates | 0.2 (20%) | 50 | 2 | Default settings |

---

## 🎯 Key Takeaways

1. **Default autovacuum (20%) is often too slow** for high-update tables
2. **Lower scale_factor = more aggressive** autovacuum (2-5% for OLTP)
3. **Higher scale_factor = less aggressive** for append-only tables (50%+)
4. **Monitor n_dead_tup ratio** - should stay < 10-15%
5. **Long transactions block autovacuum** - kill them if needed
6. **Cost-based delay prevents I/O overload** - tune for your hardware
7. **Disable autovacuum on archive tables** - save resources
8. **Enable autovacuum logging** - visibility into activity

---

## 🧹 Cleanup

```sql
-- Drop test tables
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS event_logs;
DROP TABLE IF EXISTS archive_2024;
DROP TABLE IF EXISTS measurements CASCADE;

-- Drop monitoring function/view
DROP FUNCTION IF EXISTS autovacuum_threshold(text, int, numeric);
DROP VIEW IF EXISTS autovacuum_status;

-- Reset logging (optional)
ALTER SYSTEM RESET log_autovacuum_min_duration;
SELECT pg_reload_conf();
```

---

## 📝 Interview Answer Template

**"How would you tune autovacuum for a high-traffic e-commerce orders table?"**

> "For a high-update table like orders, default autovacuum (20% threshold) is too slow. By the time autovacuum triggers, performance has already degraded.
> 
> **My approach:**
> 
> 1. **Lower scale_factor to 2-5%:**
> ```sql
> ALTER TABLE orders SET (
>   autovacuum_vacuum_scale_factor = 0.02,  -- 2% instead of 20%
>   autovacuum_vacuum_cost_delay = 0        -- No throttling for critical table
> );
> ```
> 
> 2. **Monitor dead tuple ratio:**
> ```sql
> SELECT n_dead_tup * 100.0 / n_live_tup FROM pg_stat_user_tables WHERE relname='orders';
> -- Alert if > 10%
> ```
> 
> 3. **Enable logging to track autovacuum frequency:**
> ```
> log_autovacuum_min_duration = 0
> ```
> 
> 4. **If still seeing bloat:** Investigate long-running transactions blocking cleanup
> 
> **Result:** Autovacuum runs every 10-15 minutes instead of hours, keeping dead tuple ratio < 5%, preventing bloat before it impacts performance."

---

**Next:** [Scenario 16: Bloat Crisis Management](16-bloat-crisis.md)
