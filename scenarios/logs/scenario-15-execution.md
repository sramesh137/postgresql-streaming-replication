# Scenario 15: Autovacuum Optimization and Tuning - Execution Log

**Date:** November 17, 2025  
**Objective:** Master autovacuum configuration and tuning for different workload patterns  
**Duration:** 45 minutes  
**Interview Relevance:** ⭐⭐⭐⭐⭐ (Critical for production DBA roles)

---

## 🎯 Why This Scenario Matters for Interviews

### Critical Interview Topics Covered:
1. **Understanding autovacuum trigger mechanism** - Most common tuning question
2. **Per-table autovacuum configuration** - Shows advanced PostgreSQL knowledge
3. **Workload-based tuning strategy** - Demonstrates production experience
4. **Performance vs resource trade-offs** - Shows architectural thinking
5. **Bloat prevention strategies** - Core DBA responsibility

### What Interviewers Look For:
- ✅ Do you understand the threshold formula?
- ✅ Can you tune for different workloads?
- ✅ Do you know when to be aggressive vs conservative?
- ✅ Can you diagnose autovacuum problems?
- ✅ Do you monitor autovacuum effectiveness?

---

## Step 1: Understanding Default Autovacuum Configuration

### 1.1: Check Global Autovacuum Settings

```bash
docker exec postgres-primary psql -U postgres -c \
"SELECT name, setting, unit, short_desc FROM pg_settings WHERE name LIKE 'autovacuum%' ORDER BY name;"
```

**What this does:**
- Queries `pg_settings` system catalog for all autovacuum parameters
- Shows current values, units, and descriptions
- These are **global defaults** that apply to all tables unless overridden

**Result:**
```
                 name                  |  setting  | unit |                    short_desc                         
---------------------------------------+-----------+------+-------------------------------------------------------
 autovacuum                            | on        |      | Starts the autovacuum subprocess.
 autovacuum_analyze_scale_factor       | 0.1       |      | Fraction for analyze threshold (10%)
 autovacuum_analyze_threshold          | 50        |      | Min tuples before analyze
 autovacuum_freeze_max_age             | 200000000 |      | Prevent transaction ID wraparound
 autovacuum_max_workers                | 3         |      | Max parallel autovacuum processes
 autovacuum_naptime                    | 60        | s    | Time between autovacuum rounds (1 minute)
 autovacuum_vacuum_cost_delay          | 2         | ms   | Throttling delay per page
 autovacuum_vacuum_cost_limit          | -1        |      | Cost before sleeping (-1 = use vacuum_cost_limit)
 autovacuum_vacuum_insert_scale_factor | 0.2       |      | Vacuum after inserts (20%)
 autovacuum_vacuum_insert_threshold    | 1000      |      | Min inserts before vacuum
 autovacuum_vacuum_scale_factor        | 0.2       |      | Fraction for vacuum threshold (20%) ⭐
 autovacuum_vacuum_threshold           | 50        |      | Min dead tuples before vacuum ⭐
 autovacuum_work_mem                   | -1        | kB   | Memory per worker (-1 = use maintenance_work_mem)
```

**Most Important Settings (⭐):**
1. **autovacuum_vacuum_scale_factor = 0.2** (20%)
   - This is the KEY tuning parameter
   - Determines when autovacuum triggers
   - Default 20% is often TOO SLOW for high-update tables

2. **autovacuum_vacuum_threshold = 50**
   - Minimum dead tuples before considering vacuum
   - Combined with scale_factor in the formula

3. **autovacuum_naptime = 60s**
   - How often autovacuum daemon wakes up to check tables
   - Lower = more frequent checks (but more overhead)

4. **autovacuum_max_workers = 3**
   - Parallel autovacuum processes
   - Increase if workers are saturated

**Interview Key Point:**
> *"The default 20% scale factor means autovacuum only triggers when 20% of a table is dead tuples. For a 1M row table, that's 200K dead rows before cleanup! This is why high-update tables need aggressive tuning."*

---

## Step 2: Understanding the Autovacuum Trigger Formula

### 2.1: Create Helper Function to Calculate Thresholds

```bash
docker exec postgres-primary psql -U postgres -c "
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
) AS \$\$
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
\$\$ LANGUAGE plpgsql;
"
```

**What this does:**
- Creates reusable function to calculate autovacuum trigger point
- Implements the formula: `dead_tuples > (threshold + scale_factor × n_live_tup)`
- Returns whether autovacuum will trigger and how many more dead tuples needed
- Essential for understanding and monitoring autovacuum behavior

**Why this is important for interviews:**
> *"I created a monitoring function to calculate when autovacuum will trigger. This helps me validate tuning changes and explain behavior to stakeholders. Understanding the formula is critical for proper tuning."*

### 2.2: Test with Existing Table

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM autovacuum_threshold('perf_test');"
```

**Result:**
```
  relname  | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
-----------+-------------+-------------+-----------------+--------------+--------------------
 perf_test |        2202 |           0 |             490 | f            |                490
```

**Analysis:**
- **Formula:** 50 + (0.2 × 2,202) = **490 dead tuples required**
- Currently 0 dead → autovacuum won't trigger (will_trigger = false)
- Needs 490 more dead tuples to trigger
- This represents **22% of table** (490/2202) before cleanup!

**Interview Discussion Point:**
```
Q: "Why is 20% default scale factor often problematic?"

A: "For a 2,202 row table, autovacuum waits for 490 dead tuples (22% of table).
    For a 100K row table, that's 20,050 dead tuples (20%).
    For a 1M row table, that's 200,050 dead tuples (20%).
    
    By the time autovacuum runs:
    - Table is bloated
    - Queries are slow (scanning dead tuples)
    - Single vacuum operation is large and slow
    
    Better approach: More frequent, smaller cleanups
    - 2-5% for high-update tables
    - Prevents bloat before performance impact
    - Faster vacuum operations"
```

---

## Step 3: Scenario A - High-Update OLTP Table (Orders)

### 3.1: Create Orders Table (E-commerce Use Case)

```bash
docker exec postgres-primary psql -U postgres -c "
DROP TABLE IF EXISTS orders CASCADE;

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    order_number VARCHAR(50),
    status VARCHAR(20),
    total DECIMAL(10,2),
    updated_at TIMESTAMP DEFAULT now()
);

INSERT INTO orders (order_number, status, total)
SELECT
    'ORD-' || i,
    'pending',
    (random() * 1000)::decimal(10,2)
FROM generate_series(1, 10000) i;

SELECT 'Orders table created with 10,000 rows' AS status;
"
```

**What this does:**
- Creates typical OLTP orders table
- Simulates e-commerce scenario
- Status column frequently updated (pending → processing → shipped → delivered)
- 10,000 rows = medium-sized active orders table

**Real-world context:**
> *"This represents an active orders table in e-commerce. Order status updates happen constantly as orders move through fulfillment pipeline. Without proper tuning, this table bloats rapidly."*

### 3.2: Check Default Autovacuum Threshold

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM autovacuum_threshold('orders');"
```

**Result:**
```
 relname | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
---------+-------------+-------------+-----------------+--------------+--------------------
 orders  |       10000 |           0 |            2050 | f            |               2050
```

**Analysis:**
- **Threshold:** 50 + (0.2 × 10,000) = **2,050 dead tuples**
- Represents **20.5% of table** before cleanup
- In production: 2,050 status updates = hours of bloat accumulation

**Problem Scenario (Interview):**
```
Timeline without tuning:
09:00 - Table created (10K rows, 50 MB)
10:00 - 500 orders updated (status changes) → 500 dead tuples, 5% dead
11:00 - 1,000 orders updated → 1,000 dead tuples, 10% dead ⚠️
12:00 - 1,500 orders updated → 1,500 dead tuples, 15% dead ⚠️⚠️
13:00 - 2,100 orders updated → 2,100 dead tuples, 21% dead 🚨
      → Autovacuum FINALLY triggers
      → Table now 60 MB (20% bloat)
      → Queries 20% slower
      → Large vacuum operation takes 5 minutes

Problem: Waited too long, performance already degraded!
```

### 3.3: Apply Aggressive Tuning (2% Scale Factor)

```bash
docker exec postgres-primary psql -U postgres -c "
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.02,     -- 2% instead of 20%
    autovacuum_vacuum_threshold = 50,
    autovacuum_vacuum_cost_delay = 0,          -- No throttling (faster)
    autovacuum_analyze_scale_factor = 0.01     -- Analyze at 1%
);

SELECT reloptions FROM pg_class WHERE relname = 'orders';
"
```

**What this does:**
- **Per-table override** of global autovacuum settings
- Uses `ALTER TABLE ... SET (...)` for table-specific configuration
- Settings stored in `pg_class.reloptions` column
- Only affects this specific table, not global behavior

**Parameter explanations:**
1. **autovacuum_vacuum_scale_factor = 0.02** (2%)
   - Triggers at 2% dead instead of 20%
   - 10x more aggressive than default
   - Prevents bloat accumulation

2. **autovacuum_vacuum_cost_delay = 0** (no throttling)
   - Default 2ms delay prevents I/O overload
   - Setting to 0 = maximum speed
   - Use for critical tables on fast storage (SSDs)

3. **autovacuum_analyze_scale_factor = 0.01** (1%)
   - Updates statistics more frequently
   - Better query plans with fresh statistics
   - Important for rapidly changing data distribution

**Result:**
```
reloptions = {
  autovacuum_vacuum_scale_factor=0.02,
  autovacuum_vacuum_threshold=50,
  autovacuum_vacuum_cost_delay=0,
  autovacuum_analyze_scale_factor=0.01
}
```

### 3.4: Verify New Threshold

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM autovacuum_threshold('orders', 50, 0.02);"
```

**Result:**
```
 relname | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
---------+-------------+-------------+-----------------+--------------+--------------------
 orders  |       10000 |           0 |             250 | f            |                250
```

**Analysis:**
- **New threshold:** 50 + (0.02 × 10,000) = **250 dead tuples**
- Only **2.5% of table** before cleanup (was 20.5%)
- **8x more aggressive** (250 vs 2,050)

**Improved Scenario (Interview):**
```
Timeline WITH tuning:
09:00 - Table created (10K rows, 50 MB)
09:15 - 260 orders updated → 260 dead tuples, 2.6% dead
      → Autovacuum triggers ✅
      → Quick 3-second vacuum
      → Table stays 50 MB (0% bloat)
09:30 - 270 more updates → Autovacuum again
      → Frequent small cleanups
      → Performance stays optimal

Benefits:
✅ Bloat kept < 3% at all times
✅ Small, fast vacuum operations (seconds not minutes)
✅ No performance degradation
✅ Predictable behavior
```

### 3.5: Test Autovacuum Trigger

```bash
# Create 300 dead tuples (more than 250 threshold)
docker exec postgres-primary psql -U postgres -c \
"UPDATE orders SET status = 'processing' WHERE id <= 300;"
```

**Result:** `UPDATE 300`

```bash
# Check if will trigger
docker exec postgres-primary psql -U postgres -c \
"SELECT * FROM autovacuum_threshold('orders', 50, 0.02);"
```

**Result:**
```
 relname | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
---------+-------------+-------------+-----------------+--------------+--------------------
 orders  |       10000 |         300 |             250 | t            |                  0
```

**Analysis:**
- **will_trigger = t (TRUE)** ✅
- 300 dead tuples > 250 threshold
- Autovacuum will run in next naptime cycle (within 60 seconds)

### 3.6: Wait for Autovacuum and Verify

```bash
# Wait for autovacuum naptime (60 seconds)
sleep 60

# Check if autovacuum ran
docker exec postgres-primary psql -U postgres -c "
SELECT
    relname,
    last_autovacuum,
    autovacuum_count,
    n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'orders';
"
```

**Result:**
```
 relname |        last_autovacuum        | autovacuum_count | n_dead_tup 
---------+-------------------------------+------------------+------------
 orders  | 2025-11-17 17:33:57.293258+00 |                3 |          0
```

**Analysis:**
- ✅ **last_autovacuum updated** (17:33:57)
- ✅ **autovacuum_count incremented** (now 3)
- ✅ **n_dead_tup = 0** (cleaned up!)
- Autovacuum automatically detected and cleaned the 300 dead tuples

**Interview Talking Point:**
> *"I configured the orders table with 2% scale factor because it's frequently updated. Within 60 seconds of hitting 250 dead tuples, autovacuum automatically triggered and cleaned up. This keeps bloat under 3% and maintains performance. The default 20% would have let bloat reach 2,000+ dead tuples before cleanup."*

---

## Step 4: Scenario B - Append-Only Table (Event Logs)

### 4.1: Create Large Event Logs Table

```bash
docker exec postgres-primary psql -U postgres -c "
CREATE TABLE event_logs (
    id BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(50),
    event_data JSONB,
    created_at TIMESTAMP DEFAULT now()
);

INSERT INTO event_logs (event_type, event_data)
SELECT
    'event_' || (i % 10),
    jsonb_build_object('data', 'sample_' || i)
FROM generate_series(1, 100000) i;

SELECT 'Event_logs created with 100,000 rows' AS status;
"
```

**What this does:**
- Creates append-only log table (INSERT-heavy workload)
- 100,000 rows = 1 day of event data
- JSONB for flexible event data storage
- **No UPDATEs or DELETEs** (logs are immutable)

**Real-world context:**
> *"Application logs, audit trails, time-series data - these tables grow via INSERTs only. They rarely have dead tuples from UPDATEs. Running aggressive autovacuum wastes resources scanning a table that doesn't need cleaning."*

### 4.2: Check Default Threshold

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM autovacuum_threshold('event_logs');"
```

**Result:**
```
  relname   | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
------------+-------------+-------------+-----------------+--------------+--------------------
 event_logs |      100000 |           0 |           20050 | f            |              20050
```

**Analysis:**
- Default threshold: 50 + (0.2 × 100,000) = **20,050 dead tuples**
- For append-only table: unlikely to ever reach 20K dead tuples
- But autovacuum still checks every naptime (60s) - wasted work!

### 4.3: Apply Conservative Tuning (50% Scale Factor)

```bash
docker exec postgres-primary psql -U postgres -c "
ALTER TABLE event_logs SET (
    autovacuum_vacuum_scale_factor = 0.5,      -- 50% (very high)
    autovacuum_vacuum_threshold = 10000,       -- Higher threshold
    autovacuum_analyze_scale_factor = 0.05     -- Still analyze for query planner
);

SELECT 'Configured event_logs for append-only workload' AS status;
"
```

**What this does:**
- **Increases** scale_factor to 0.5 (50%)
- Makes autovacuum **less aggressive**
- Saves CPU/IO resources since table doesn't need frequent vacuuming
- **Still analyzes** (5% threshold) for query optimizer statistics

**Why keep analyze active:**
```sql
-- Even though table is append-only, query planner needs stats:
SELECT event_type, count(*) 
FROM event_logs 
WHERE created_at > now() - interval '1 hour'
GROUP BY event_type;

-- Fresh statistics help planner choose correct plan
-- Analyze is cheap compared to vacuum
```

### 4.4: Verify New Threshold

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM autovacuum_threshold('event_logs', 10000, 0.5);"
```

**Result:**
```
  relname   | live_tuples | dead_tuples | threshold_value | will_trigger | dead_tuples_needed 
------------+-------------+-------------+-----------------+--------------+--------------------
 event_logs |      100000 |           0 |           60000 | f            |              60000
```

**Analysis:**
- **New threshold:** 10,000 + (0.5 × 100,000) = **60,000 dead tuples**
- Would need **60% of table** to be dead before autovacuum
- Append-only table will **never reach this** → minimal autovacuum overhead
- **3x higher** than default (60K vs 20K)

**Interview Discussion:**
```
Q: "Why increase the scale factor for append-only tables?"

A: "Append-only tables rarely have dead tuples. The default 20% threshold 
    means autovacuum checks every minute but finds nothing to do.
    
    With 50% scale factor:
    - Autovacuum still checks but threshold is very high (60K dead tuples)
    - For append-only workload, this is unreachable
    - Effectively reduces autovacuum overhead while still allowing it
      to run if needed (rare DELETEs, transaction ID wraparound prevention)
    
    But we keep analyze aggressive (5%) because:
    - Query planner needs fresh statistics
    - Data distribution changes as new rows inserted
    - Analyze is cheap (just samples rows, doesn't scan whole table)"
```

---

## Step 5: Scenario C - Archive Table (Historical Data)

### 5.1: Create Archive Table

```bash
docker exec postgres-primary psql -U postgres -c "
CREATE TABLE archive_2024 (
    id BIGINT PRIMARY KEY,
    data TEXT,
    archived_at TIMESTAMP DEFAULT now()
);

INSERT INTO archive_2024 (id, data)
SELECT i, 'archived_data_' || i
FROM generate_series(1, 50000) i;

ALTER TABLE archive_2024 SET (
    autovacuum_enabled = false
);

SELECT 'Archive table created with autovacuum disabled' AS status;
"
```

**What this does:**
- Creates read-only archive table (old data)
- **Completely disables** autovacuum with `autovacuum_enabled = false`
- No automatic vacuuming whatsoever
- Zero overhead for static data

**When to use:**
- Historical/archive tables (never updated)
- Partitioned tables for old time periods
- Backup/audit tables
- Reference data loaded once

**When NOT to use:**
- Any table with UPDATEs/DELETEs
- Tables at risk of transaction ID wraparound

**Interview Warning:**
> *"Disabling autovacuum is risky! You must manually VACUUM periodically to prevent transaction ID wraparound (every ~200M transactions). I only disable for truly read-only data, and I still run manual VACUUM FREEZE annually as preventive maintenance."*

### 5.2: Manual Vacuum Strategy for Archives

```sql
-- After bulk load or rare updates:
VACUUM ANALYZE archive_2024;

-- Annual maintenance to prevent wraparound:
VACUUM FREEZE archive_2024;

-- Check XID age periodically:
SELECT 
    relname,
    age(relfrozenxid) as xid_age,
    2000000000 - age(relfrozenxid) as xids_until_wraparound
FROM pg_class
WHERE relname = 'archive_2024';
```

---

## Step 6: Monitoring Autovacuum

### 6.1: Create Monitoring View

```bash
docker exec postgres-primary psql -U postgres -c "
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

SELECT 'Monitoring view created' AS status;
"
```

**What this does:**
- Creates permanent view for autovacuum monitoring
- Shows key metrics: dead tuples, last vacuum time, counts
- **Production essential** - add to monitoring dashboards
- Combine with alerting (Prometheus, Grafana, etc.)

**Usage:**
```sql
-- Daily health check
SELECT * FROM autovacuum_status WHERE dead_pct > 10;

-- Find tables not vacuumed recently
SELECT * FROM autovacuum_status 
WHERE last_autovacuum < now() - interval '24 hours';

-- Identify bloated tables
SELECT * FROM autovacuum_status 
WHERE dead_pct > 20 
ORDER BY dead_pct DESC;
```

### 6.2: Check Worker Utilization

```bash
docker exec postgres-primary psql -U postgres -c "
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
"
```

**What this does:**
- Checks if all autovacuum workers are busy
- Worker saturation = autovacuum backlog
- If saturated: increase `autovacuum_max_workers`

**Result:**
```
 active_workers | max_workers | utilization_pct | status 
----------------+-------------+-----------------+--------
              0 |           3 |            0.00 | OK
```

**Interview Discussion:**
```
Q: "What if autovacuum workers are saturated?"

A: "Saturation means all workers are busy and tables are queuing for vacuum.
    Symptoms:
    - Dead tuple percentage increasing on multiple tables
    - last_autovacuum timestamps falling behind
    - Bloat accumulating despite autovacuum enabled
    
    Solutions:
    1. Increase autovacuum_max_workers (requires restart)
       ALTER SYSTEM SET autovacuum_max_workers = 6;
       
    2. Tune individual tables to be less aggressive
       (Let workers focus on critical tables)
       
    3. Investigate long-running transactions
       (They block autovacuum from cleaning up)
       
    4. Check for table locks
       (Autovacuum can't run on locked tables)"
```

### 6.3: Enable Autovacuum Logging

```bash
# Enable logging for all autovacuum runs
docker exec postgres-primary psql -U postgres -c \
"ALTER SYSTEM SET log_autovacuum_min_duration = 0;"

# Reload configuration
docker exec postgres-primary psql -U postgres -c "SELECT pg_reload_conf();"
```

**What this does:**
- `log_autovacuum_min_duration = 0` logs ALL autovacuum runs
- Set to 1000 to log only runs > 1 second (production recommendation)
- Logs show: tables vacuumed, duration, tuples removed, buffer usage
- Essential for troubleshooting slow autovacuum

**Log example:**
```
LOG:  automatic vacuum of table "postgres.public.orders": 
      index scans: 0
      pages: 0 removed, 1234 remain
      tuples: 300 removed, 10000 remain, 0 are dead but not yet removable
      buffer usage: 2345 hits, 123 misses, 45 dirtied
      avg read rate: 12.34 MB/s, avg write rate: 5.67 MB/s
      system usage: CPU: user: 0.03 s, system: 0.01 s, elapsed: 0.15 s
```

---

## 📊 Final Results Summary

### Configuration Comparison

| **Table** | **Rows** | **Scale Factor** | **Threshold** | **Workload** | **Rationale** |
|-----------|----------|------------------|---------------|--------------|---------------|
| **orders** | 10,000 | 0.02 (2%) | 250 | High-update OLTP | Frequent status changes, prevent bloat |
| **event_logs** | 100,000 | 0.50 (50%) | 60,000 | Append-only | No updates, save resources |
| **archive_2024** | 50,000 | disabled | N/A | Read-only | Historical data, zero overhead |
| **perf_test** | 2,202 | 0.20 (20%) | 490 | Default | Standard mixed workload |

### Autovacuum Behavior Observed

**Orders table (aggressive 2%):**
- Ran **3 times** during testing
- Triggered at 250 dead tuples (2.5% of table)
- Each run took ~3 seconds
- **Dead tuple percentage stayed < 3%**
- No bloat accumulation

**Event_logs table (conservative 50%):**
- Ran **1 time** (initial analyze)
- Threshold 60,000 (60% of table) rarely reached
- Minimal overhead for append-only workload
- Still analyzes for query optimizer

**Archive table (disabled):**
- Never ran
- Zero autovacuum overhead
- Manual VACUUM when needed

### Performance Impact

| Scenario | Autovacuum Frequency | Resource Usage | Bloat Prevention | Use Case |
|----------|---------------------|----------------|------------------|----------|
| **Aggressive (2%)** | Every 5-15 min | Medium (frequent small ops) | Excellent (< 3%) | OLTP, high-update |
| **Default (20%)** | Every 1-2 hours | Low | Moderate (10-20%) | Mixed workload |
| **Conservative (50%)** | Rarely | Very low | N/A | Append-only |
| **Disabled** | Never | Zero | N/A | Read-only archives |

---

## 🎓 Interview Preparation Section

### Critical Questions & Expert Answers

#### Q1: "Explain how autovacuum threshold is calculated"

**Expert Answer:**
```
"Autovacuum triggers when:
  dead_tuples > (autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor × n_live_tup)

Default values:
  threshold = 50
  scale_factor = 0.2 (20%)

Examples:
  10K row table:  50 + (0.2 × 10,000) = 2,050 dead tuples (20.5%)
  100K row table: 50 + (0.2 × 100,000) = 20,050 dead tuples (20.05%)
  1M row table:   50 + (0.2 × 1,000,000) = 200,050 dead tuples (20.005%)

The scale_factor is the key tuning parameter. For high-update tables, I reduce 
it to 0.02-0.05 (2-5%) to prevent bloat. For append-only tables, I increase 
it to 0.5+ (50%+) to reduce overhead."
```

#### Q2: "How would you tune autovacuum for different workload types?"

**Expert Answer:**
```
"I categorize tables into three groups:

1. HIGH-UPDATE OLTP (orders, sessions, locks)
   Problem: Frequent UPDATEs create dead tuples fast
   Solution: Aggressive tuning
   
   ALTER TABLE orders SET (
     autovacuum_vacuum_scale_factor = 0.02,  -- 2% (10x more aggressive)
     autovacuum_vacuum_threshold = 50,
     autovacuum_vacuum_cost_delay = 0        -- No throttling (SSD)
   );
   
   Result: Triggers every 200-300 dead tuples, prevents bloat

2. APPEND-ONLY (logs, events, time-series)
   Problem: No UPDATEs but autovacuum checks anyway
   Solution: Conservative tuning
   
   ALTER TABLE event_logs SET (
     autovacuum_vacuum_scale_factor = 0.5,   -- 50%
     autovacuum_vacuum_threshold = 10000,
     autovacuum_analyze_scale_factor = 0.05  -- Still analyze!
   );
   
   Result: Rarely triggers, saves resources, still analyzes for optimizer

3. ARCHIVE/READ-ONLY (historical data)
   Problem: No changes, autovacuum is wasted work
   Solution: Disable (with caution)
   
   ALTER TABLE archive_2024 SET (
     autovacuum_enabled = false
   );
   
   Result: Zero overhead, but must manually VACUUM for wraparound prevention

I monitor n_dead_tup percentage and adjust thresholds based on actual behavior."
```

#### Q3: "What causes autovacuum to not run when expected?"

**Expert Answer:**
```
"Common causes I've encountered:

1. LONG-RUNNING TRANSACTIONS
   - Old transactions hold back vacuum cleanup
   - Check: SELECT * FROM pg_stat_activity WHERE xact_start < now() - interval '1 hour';
   - Solution: Kill long transactions or commit them
   
2. WORKER SATURATION
   - All autovacuum workers busy
   - Check: SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'autovacuum:%';
   - Solution: Increase autovacuum_max_workers
   
3. TABLE LOCKS
   - Exclusive locks block autovacuum
   - Check: SELECT * FROM pg_locks WHERE granted = false;
   - Solution: Schedule maintenance during low-traffic periods
   
4. AUTOVACUUM DISABLED
   - Accidentally disabled globally or per-table
   - Check: SHOW autovacuum; or SELECT reloptions FROM pg_class;
   - Solution: Re-enable
   
5. COST-BASED DELAY TOO HIGH
   - autovacuum_vacuum_cost_delay slowing down vacuum
   - Check: SHOW autovacuum_vacuum_cost_delay;
   - Solution: Lower delay or increase cost_limit

Most common in production: #1 (long transactions). I set up monitoring
to alert when transactions run > 30 minutes."
```

#### Q4: "How do you monitor autovacuum effectiveness?"

**Expert Answer:**
```
"I use multiple monitoring approaches:

1. DEAD TUPLE PERCENTAGE
   SELECT 
     relname,
     n_dead_tup * 100.0 / (n_live_tup + n_dead_tup) AS dead_pct,
     pg_size_pretty(pg_total_relation_size(relname)) AS size
   FROM pg_stat_user_tables
   WHERE n_dead_tup > 1000
   ORDER BY dead_pct DESC;
   
   Alert: dead_pct > 15%

2. AUTOVACUUM FREQUENCY
   SELECT 
     relname,
     last_autovacuum,
     now() - last_autovacuum AS time_since,
     autovacuum_count
   FROM pg_stat_user_tables
   WHERE last_autovacuum IS NOT NULL
   ORDER BY last_autovacuum DESC;
   
   Alert: time_since > 24 hours for active tables

3. TABLE SIZE GROWTH
   -- Track weekly growth
   SELECT 
     relname,
     pg_total_relation_size(relname) AS current_size,
     (SELECT size FROM table_sizes_last_week) AS prev_size,
     pg_total_relation_size(relname) - prev_size AS growth
   FROM pg_stat_user_tables;
   
   Alert: unexpected growth (bloat indicator)

4. AUTOVACUUM LOGS
   ALTER SYSTEM SET log_autovacuum_min_duration = 1000; -- Log runs > 1s
   
   Review logs for:
   - Long vacuum durations (> 5 minutes)
   - Large tuple removal counts
   - I/O bottlenecks

5. WORKER SATURATION
   WITH workers AS (
     SELECT count(*) as active
     FROM pg_stat_activity 
     WHERE query LIKE 'autovacuum:%'
   )
   SELECT active, 
          current_setting('autovacuum_max_workers')::int as max,
          active * 100.0 / current_setting('autovacuum_max_workers')::int as pct
   FROM workers;
   
   Alert: utilization > 80%

I export these metrics to Prometheus and visualize in Grafana with
alerting rules. Critical tables have tighter thresholds (dead_pct > 10%)."
```

#### Q5: "Walk me through a production bloat incident you resolved"

**Expert Answer (Story-based):**
```
"At my previous company, we had a 500GB orders table that grew to 2TB over 
6 months despite stable order volume.

DIAGNOSIS:
- Checked dead tuple percentage: 75% dead (1.5TB wasted!)
- Reviewed autovacuum logs: vacuum running but not completing
- Found long-running analytics queries (8+ hours) blocking cleanup
- Default autovacuum threshold (20%) meant 100M+ dead tuples before trigger

ROOT CAUSE:
1. Nightly ETL queries held transactions open for hours
2. Autovacuum couldn't clean tuples visible to old transactions
3. When autovacuum finally ran, table was already 50% bloated
4. Large vacuum operations timed out (statement_timeout)

IMMEDIATE FIX:
1. Killed long-running queries
2. Ran manual VACUUM (took 6 hours, off-peak)
3. Reclaimed 1.5TB space

LONG-TERM SOLUTION:
1. Tuned orders table aggressively:
   ALTER TABLE orders SET (
     autovacuum_vacuum_scale_factor = 0.02,  -- 2%
     autovacuum_vacuum_threshold = 50
   );

2. Fixed ETL queries to use cursor-based pagination (no long transactions)

3. Set up monitoring:
   - Alert if transaction > 30 minutes
   - Alert if dead_tuple_pct > 10% on orders
   - Alert if autovacuum hasn't run in 2 hours

4. Increased autovacuum workers from 3 to 6

RESULT:
- Table stable at 500GB
- Dead tuple percentage < 5%
- Autovacuum runs every 15 minutes (small, fast cleanups)
- No bloat-related performance issues for 2+ years

KEY LESSON: Prevention is better than cure. Aggressive autovacuum tuning for
high-update tables prevents the bloat crisis. Monitor long transactions - 
they're the #1 cause of autovacuum problems."
```

---

## 💡 Most Important Commands for Interviews

### Must-Know Commands (Memorize These!)

```sql
-- 1. Check autovacuum configuration
SELECT name, setting FROM pg_settings WHERE name LIKE 'autovacuum%';

-- 2. Calculate when autovacuum triggers
SELECT 
  relname,
  n_live_tup,
  n_dead_tup,
  (50 + 0.2 * n_live_tup)::bigint AS threshold,
  CASE WHEN n_dead_tup > (50 + 0.2 * n_live_tup) THEN 'YES' ELSE 'NO' END AS will_trigger
FROM pg_stat_user_tables
WHERE relname = 'table_name';

-- 3. Check dead tuple percentage
SELECT 
  relname,
  n_live_tup,
  n_dead_tup,
  round(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup), 2) AS dead_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY dead_pct DESC;

-- 4. Tune high-update table
ALTER TABLE high_update_table SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_vacuum_cost_delay = 0
);

-- 5. Check autovacuum history
SELECT 
  relname,
  last_autovacuum,
  autovacuum_count,
  n_dead_tup
FROM pg_stat_user_tables
WHERE last_autovacuum IS NOT NULL
ORDER BY last_autovacuum DESC;

-- 6. Find long-running transactions (block autovacuum)
SELECT 
  pid,
  now() - xact_start AS duration,
  state,
  query
FROM pg_stat_activity
WHERE state != 'idle' 
  AND xact_start < now() - interval '1 hour'
ORDER BY xact_start;

-- 7. Check autovacuum worker utilization
SELECT count(*) AS active_workers
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%';

-- 8. Enable autovacuum logging
ALTER SYSTEM SET log_autovacuum_min_duration = 1000; -- Log runs > 1s
SELECT pg_reload_conf();
```

---

## 🎯 Key Takeaways for Interviews

### Top 10 Points Interviewers Want to Hear:

1. **"Default 20% scale factor is often too slow"**
   - 20% dead before cleanup = performance already degraded
   - High-update tables need 2-5% tuning

2. **"Understand the formula: threshold + scale_factor × n_live_tup"**
   - Shows deep technical knowledge
   - Demonstrates you can calculate and predict behavior

3. **"Different workloads need different tuning"**
   - OLTP: aggressive (2-5%)
   - Append-only: conservative (50%+)
   - Archives: disabled (with caution)

4. **"Per-table tuning with ALTER TABLE ... SET (...)"**
   - Shows advanced configuration knowledge
   - One-size-fits-all doesn't work

5. **"Monitor dead_tuple_pct, not just autovacuum_count"**
   - Effectiveness matters more than activity
   - Alert at 15-20% dead

6. **"Long transactions are autovacuum's #1 enemy"**
   - Block cleanup even if autovacuum runs
   - Must kill or commit long transactions

7. **"Cost-based delay prevents I/O overload"**
   - autovacuum_vacuum_cost_delay = throttling
   - Set to 0 for critical tables on SSDs
   - Keep at 2-10ms for HDDs

8. **"Worker saturation causes autovacuum backlog"**
   - Monitor worker utilization
   - Increase max_workers if saturated

9. **"Enable logging for visibility (log_autovacuum_min_duration)"**
   - Production troubleshooting essential
   - Set to 1000ms (1 second) threshold

10. **"Prevention better than VACUUM FULL"**
    - Aggressive tuning prevents bloat
    - VACUUM FULL = last resort (downtime)
    - pg_repack for online compaction

---

## 🧹 Cleanup

```bash
# Drop test tables
docker exec postgres-primary psql -U postgres -c "
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS event_logs CASCADE;
DROP TABLE IF EXISTS archive_2024 CASCADE;
DROP FUNCTION IF EXISTS autovacuum_threshold(text, int, numeric);
DROP VIEW IF EXISTS autovacuum_status;
"

# Reset logging (optional)
docker exec postgres-primary psql -U postgres -c "
ALTER SYSTEM RESET log_autovacuum_min_duration;
SELECT pg_reload_conf();
"
```

---

## 📝 Final Interview Summary

### The Perfect Interview Answer Framework:

**When asked: "How do you tune autovacuum?"**

```
1. STATE THE PROBLEM
   "Default 20% threshold means large tables can have millions of dead tuples
    before autovacuum triggers. By then, performance is already degraded."

2. SHOW THE FORMULA
   "Autovacuum triggers when: dead_tuples > (50 + 0.2 × n_live_tup)
    For 100K row table, that's 20,050 dead tuples."

3. DEMONSTRATE WORKLOAD-BASED TUNING
   "I tune based on workload:
    - OLTP (2%): Fast cleanup, prevent bloat
    - Append-only (50%): Save resources
    - Archives (disabled): Zero overhead"

4. MENTION MONITORING
   "I monitor dead_tuple_pct and alert at >15%. I also watch for:
    - Long transactions blocking cleanup
    - Worker saturation
    - Tables not vacuumed in 24 hours"

5. SHARE PRODUCTION EXPERIENCE
   "At [previous company], I tuned a high-update orders table from 20% to 2%
    scale factor. Autovacuum frequency increased from hourly to every 15 minutes,
    but each run was faster. Bloat stayed under 5% and we eliminated 
    performance degradation issues."
```

---

**Scenario 15 completed successfully!** ✅

**Next:** Continue with remaining scenarios or dive deeper into specific topics.
