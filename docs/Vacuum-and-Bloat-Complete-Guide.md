# PostgreSQL VACUUM and Bloat Management - Complete Guide

**Essential Knowledge for Production DBAs and Interviews**

---

## 📚 Table of Contents

1. [Understanding MVCC](#-understanding-mvcc)
2. [What is VACUUM?](#-what-is-vacuum)
3. [VACUUM vs VACUUM FULL](#-vacuum-vs-vacuum-full)
4. [Autovacuum](#-autovacuum)
5. [Table and Index Bloat](#-table-and-index-bloat)
6. [Monitoring and Detection](#-monitoring-and-detection)
7. [Tuning and Best Practices](#-tuning-and-best-practices)
8. [Troubleshooting](#-troubleshooting)
9. [Interview Questions](#-interview-questions)
10. [Hands-on Scenarios](#-hands-on-scenarios)

---

## 🔄 Understanding MVCC

### What is MVCC?

**MVCC (Multi-Version Concurrency Control)** is PostgreSQL's approach to handling concurrent transactions without locks.

### How It Works:

```
Transaction 1: UPDATE users SET name='Bob' WHERE id=1;
Transaction 2: SELECT * FROM users WHERE id=1;

Instead of locking:
- PostgreSQL creates NEW version of the row
- OLD version remains visible to Transaction 2
- NEW version visible to Transaction 1 and future transactions
```

### The Problem: Dead Tuples

```
Time T1: Row version 1 (name='Alice')
Time T2: UPDATE → Row version 2 (name='Bob') + version 1 becomes DEAD
Time T3: UPDATE → Row version 3 (name='Charlie') + version 2 becomes DEAD

Table now contains:
- Version 1 (DEAD) ← needs cleanup
- Version 2 (DEAD) ← needs cleanup
- Version 3 (LIVE) ← currently visible
```

**Dead tuples:**
- Take up disk space
- Slow down queries (must scan past them)
- Cause table bloat
- Need to be reclaimed → **This is what VACUUM does!**

---

## 🧹 What is VACUUM?

**VACUUM** reclaims storage occupied by dead tuples.

### What VACUUM Does:

1. **Marks dead tuples as reusable** (doesn't return space to OS)
2. **Updates visibility map** (tracks clean pages for index-only scans)
3. **Updates free space map** (tracks available space for INSERTs)
4. **Prevents transaction ID wraparound** (critical for old databases)
5. **Updates table statistics** (if combined with ANALYZE)

### What VACUUM Does NOT Do:

❌ Does not shrink table files  
❌ Does not return disk space to OS  
❌ Does not lock table exclusively (allows reads/writes)  
❌ Does not compact data (use VACUUM FULL for that)  

### Basic VACUUM Commands:

```sql
-- Vacuum single table
VACUUM users;

-- Vacuum and update statistics
VACUUM ANALYZE users;

-- Vacuum entire database
VACUUM;

-- Verbose output (see details)
VACUUM VERBOSE users;

-- Vacuum specific columns for analyze
VACUUM ANALYZE users(email, created_at);
```

### VACUUM Output Example:

```sql
postgres=# VACUUM VERBOSE users;
INFO:  vacuuming "public.users"
INFO:  scanned index "users_pkey" to remove 1250 row versions
DETAIL:  CPU: user: 0.01 s, system: 0.00 s, elapsed: 0.02 s
INFO:  "users": removed 1250 dead row versions in 15 pages
DETAIL:  120000 live row versions, 1250 dead row versions
         0 pages contain useful free space
         CPU: user: 0.03 s, system: 0.01 s, elapsed: 0.05 s
VACUUM
```

**Translation:**
- Scanned table and indexes
- Found and marked 1,250 dead tuples as reusable
- Table still has 120,000 live rows
- Took 50ms total

---

## 💥 VACUUM vs VACUUM FULL

### VACUUM (Regular)

**What it does:**
- Marks dead tuples as reusable
- Space available for new inserts in SAME table
- Table size stays the same

**Characteristics:**
- ✅ Fast (minutes for GB-sized tables)
- ✅ Non-blocking (allows reads/writes)
- ✅ Can run anytime
- ❌ Doesn't shrink table

**When to use:**
- Regular maintenance (daily/hourly via autovacuum)
- After bulk UPDATEs/DELETEs
- As part of normal operations

**Example:**
```sql
-- Table: 1 GB, 20% dead tuples

VACUUM users;

-- Result:
-- - Dead tuples marked as reusable
-- - Table still 1 GB
-- - Next INSERTs will reuse dead space
-- - Duration: 30 seconds
```

### VACUUM FULL

**What it does:**
- Rewrites entire table
- Compacts data (removes all dead space)
- Returns unused space to OS
- Table size shrinks

**Characteristics:**
- ✅ Shrinks table (reclaims disk space)
- ✅ Eliminates bloat completely
- ❌ Very slow (hours for large tables)
- ❌ Requires exclusive lock (blocks all operations)
- ❌ Needs 2x table size free disk space
- ❌ Causes replication lag

**When to use:**
- Table severely bloated (>50% dead space)
- After massive DELETE operations
- During maintenance windows only
- When disk space critically low

**Example:**
```sql
-- Table: 1 GB, 50% bloat (500 MB wasted)

VACUUM FULL users;

-- Result:
-- - Table compacted and rewritten
-- - Table now 500 MB (50% savings!)
-- - Duration: 10 minutes
-- - Table locked during operation (downtime!)
```

### Comparison Table

| Feature | **VACUUM** | **VACUUM FULL** |
|---------|------------|-----------------|
| **Speed** | Fast (seconds-minutes) | Slow (minutes-hours) |
| **Locking** | None (concurrent access) | Exclusive (blocks everything) |
| **Disk Space** | No reduction | Shrinks table |
| **Free Space** | Yes (for reuse) | No requirement |
| **Bloat Removal** | Partial | Complete |
| **Replication Impact** | Minimal | High (generates lots of WAL) |
| **Production Safe** | ✅ Yes | ❌ No (requires downtime) |
| **When to Use** | Regular maintenance | Emergency bloat removal |

### Visual Comparison

**VACUUM (Regular):**
```
Before:
[Data][Data][DEAD][Data][DEAD][DEAD][Data]
^--- 1 GB file size

After VACUUM:
[Data][Data][FREE][Data][FREE][FREE][Data]
^--- Still 1 GB, but FREE space reusable
```

**VACUUM FULL:**
```
Before:
[Data][Data][DEAD][Data][DEAD][DEAD][Data]
^--- 1 GB file size

After VACUUM FULL:
[Data][Data][Data][Data]
^--- 580 MB file size (dead space returned to OS)
```

---

## 🤖 Autovacuum

**Autovacuum** is the automated VACUUM daemon that runs in the background.

### How Autovacuum Works:

```
1. Autovacuum launcher (always running)
   ↓
2. Checks statistics for tables needing vacuum
   ↓
3. Spawns autovacuum worker processes
   ↓
4. Workers vacuum tables automatically
   ↓
5. Updates statistics and sleeps
```

### When Does Autovacuum Trigger?

**Formula:**
```
autovacuum triggers when:
dead_tuples > (autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * row_count)

Default values:
- autovacuum_vacuum_threshold = 50 (minimum dead tuples)
- autovacuum_vacuum_scale_factor = 0.2 (20% of table)

Example for 10,000 row table:
dead_tuples > 50 + (0.2 * 10,000) = 2,050

Autovacuum runs when table has > 2,050 dead tuples
```

### Key Autovacuum Settings:

**Global Settings (postgresql.conf):**

```sql
-- Enable autovacuum (should always be ON)
autovacuum = on

-- Number of worker processes
autovacuum_max_workers = 3

-- Delay between vacuum runs
autovacuum_naptime = 1min

-- Trigger thresholds
autovacuum_vacuum_threshold = 50
autovacuum_vacuum_scale_factor = 0.2

-- Analyze thresholds
autovacuum_analyze_threshold = 50
autovacuum_analyze_scale_factor = 0.1

-- Cost-based delay (prevent I/O overload)
autovacuum_vacuum_cost_delay = 2ms
autovacuum_vacuum_cost_limit = 200

-- Prevent transaction ID wraparound
autovacuum_freeze_max_age = 200000000
```

**Per-Table Settings:**

```sql
-- Make autovacuum more aggressive for specific table
ALTER TABLE high_update_table SET (
  autovacuum_vacuum_scale_factor = 0.05,  -- 5% instead of 20%
  autovacuum_vacuum_threshold = 100,
  autovacuum_vacuum_cost_delay = 0        -- No delay (faster)
);

-- Disable autovacuum for specific table (not recommended!)
ALTER TABLE archive_table SET (
  autovacuum_enabled = false
);
```

### Check Autovacuum Status:

```sql
-- Check if autovacuum is enabled
SHOW autovacuum;

-- See autovacuum configuration
SELECT name, setting, unit 
FROM pg_settings 
WHERE name LIKE 'autovacuum%';

-- Check autovacuum activity
SELECT 
    schemaname,
    relname,
    last_vacuum,
    last_autovacuum,
    vacuum_count,
    autovacuum_count,
    n_dead_tup,
    n_live_tup
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

### Autovacuum Logs:

```sql
-- Enable autovacuum logging (in postgresql.conf)
log_autovacuum_min_duration = 0  -- Log all autovacuum runs
                                  -- or set to 1000 to log only runs > 1 second

-- View logs
tail -f /var/log/postgresql/postgresql-15-main.log | grep autovacuum
```

**Example log:**
```
2025-11-17 16:00:00 UTC [12345]: [1-1] LOG:  automatic vacuum of table "mydb.public.orders": 
    index scans: 1
    pages: 0 removed, 54321 remain, 0 skipped due to pins
    tuples: 150000 removed, 2000000 remain, 0 are dead but not yet removable
    buffer usage: 65432 hits, 1234 misses, 567 dirtied
    avg read rate: 12.345 MB/s, avg write rate: 5.678 MB/s
    system usage: CPU: user: 1.23 s, system: 0.45 s, elapsed: 23.45 s
```

---

## 📊 Table and Index Bloat

### What is Bloat?

**Bloat** = Wasted space in tables/indexes from dead tuples that haven't been cleaned up or reused.

### Causes of Bloat:

1. **High UPDATE/DELETE activity** without adequate vacuuming
2. **Long-running transactions** preventing VACUUM from cleaning
3. **Autovacuum too slow** or not aggressive enough
4. **Hot rows** (frequently updated rows near end of table)
5. **Insufficient fillfactor** (no room for HOT updates)

### Types of Bloat:

**1. Table Bloat:**
```
Ideal table:
[Row1][Row2][Row3][Row4][Row5] = 500 MB

Bloated table:
[Row1][DEAD][Row2][DEAD][DEAD][Row3][DEAD][Row4][DEAD][Row5] = 2 GB
                                                 ^--- 75% bloat!
```

**2. Index Bloat:**
```
Indexes also accumulate dead entries
B-tree indexes especially prone to bloat
```

### Detecting Bloat:

**Query 1: Table Bloat Estimation**

```sql
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    pg_size_pretty((pg_total_relation_size(schemaname||'.'||tablename) - pg_total_relation_size(schemaname||'.'||tablename) * current_setting('autovacuum_vacuum_scale_factor')::numeric / 100)) AS bloat_estimate,
    round(100 * (pg_total_relation_size(schemaname||'.'||tablename)::numeric - pg_relation_size(schemaname||'.'||tablename)::numeric) / pg_total_relation_size(schemaname||'.'||tablename)::numeric, 2) AS bloat_ratio
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

**Query 2: Detailed Bloat Analysis (pgstattuple extension)**

```sql
-- Install extension
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- Check table bloat
SELECT * FROM pgstattuple('users');

-- Output:
-- table_len    | 1073741824  (1 GB)
-- tuple_count  | 1000000
-- dead_tuple_count | 250000    ← 250K dead tuples!
-- dead_tuple_percent | 23.5     ← 23.5% bloat!
-- free_space   | 52428800    (50 MB available)
```

**Query 3: Top Bloated Tables**

```sql
SELECT
    schemaname || '.' || tablename AS table,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    n_dead_tup,
    n_live_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_ratio
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 10;
```

### Measuring Bloat Impact:

**Performance Impact:**
```sql
-- Seq scan performance (bloated vs non-bloated)
EXPLAIN ANALYZE SELECT * FROM bloated_table;
-- Planning Time: 0.5 ms
-- Execution Time: 1234.5 ms  ← Slow!

VACUUM FULL bloated_table;

EXPLAIN ANALYZE SELECT * FROM bloated_table;
-- Planning Time: 0.5 ms
-- Execution Time: 456.7 ms   ← 63% faster!
```

### Fixing Bloat:

**Option 1: VACUUM (Safe, preferred)**
```sql
VACUUM ANALYZE users;
-- Marks dead tuples as reusable
-- No downtime
-- Doesn't shrink table immediately
```

**Option 2: VACUUM FULL (Aggressive)**
```sql
VACUUM FULL users;
-- Rewrites entire table
-- Shrinks table to minimum size
-- Requires downtime (exclusive lock)
-- Takes long time
```

**Option 3: CLUSTER (Reorganize by index)**
```sql
CLUSTER users USING users_pkey;
-- Physically reorders table by index
-- Improves read performance
-- Exclusive lock required
-- Similar to VACUUM FULL but with ordering
```

**Option 4: pg_repack (Online, no locks)**
```sql
-- Install pg_repack extension
CREATE EXTENSION pg_repack;

-- Repack table online (no exclusive locks!)
pg_repack -t users mydb

-- This is the best option for production!
-- Reorganizes table without blocking
```

---

## 🔍 Monitoring and Detection

### Key Metrics to Monitor:

**1. Dead Tuple Count**
```sql
SELECT 
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;
```

**Alert when:** dead_pct > 20%

**2. Autovacuum Frequency**
```sql
SELECT
    relname,
    autovacuum_count,
    last_autovacuum,
    now() - last_autovacuum AS time_since_autovacuum
FROM pg_stat_user_tables
ORDER BY last_autovacuum DESC NULLS LAST;
```

**Alert when:** time_since_autovacuum > 24 hours

**3. Table Size Growth**
```sql
-- Create baseline
CREATE TABLE table_sizes AS
SELECT
    schemaname||'.'||tablename AS table_name,
    pg_total_relation_size(schemaname||'.'||tablename) AS size_bytes,
    now() AS measured_at
FROM pg_stat_user_tables;

-- Check weekly
SELECT
    t1.table_name,
    pg_size_pretty(t1.size_bytes) AS current_size,
    pg_size_pretty(t2.size_bytes) AS last_week_size,
    pg_size_pretty(t1.size_bytes - t2.size_bytes) AS growth,
    round((t1.size_bytes - t2.size_bytes) * 100.0 / t2.size_bytes, 2) AS growth_pct
FROM table_sizes t1
JOIN table_sizes_last_week t2 ON t1.table_name = t2.table_name
WHERE t1.size_bytes > t2.size_bytes * 1.1  -- > 10% growth
ORDER BY (t1.size_bytes - t2.size_bytes) DESC;
```

**4. Long-Running Transactions (Block VACUUM)**
```sql
SELECT
    pid,
    now() - xact_start AS duration,
    state,
    query
FROM pg_stat_activity
WHERE state != 'idle'
  AND xact_start < now() - interval '1 hour'
ORDER BY xact_start;
```

**Alert when:** transactions running > 1 hour

**5. Transaction ID Age (Wraparound Risk)**
```sql
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    2000000000 - age(datfrozenxid) AS xids_until_wraparound,
    round(100 * age(datfrozenxid)::numeric / 2000000000, 2) AS pct_toward_wraparound
FROM pg_database
ORDER BY age(datfrozenxid) DESC;
```

**Alert when:** pct_toward_wraparound > 50%

---

## ⚙️ Tuning and Best Practices

### 1. Tuning Autovacuum for Write-Heavy Tables

```sql
-- More aggressive autovacuum
ALTER TABLE high_activity_table SET (
    autovacuum_vacuum_scale_factor = 0.02,    -- 2% instead of 20%
    autovacuum_vacuum_threshold = 50,
    autovacuum_analyze_scale_factor = 0.01,   -- 1% instead of 10%
    autovacuum_vacuum_cost_delay = 0,         -- No delay (faster)
    autovacuum_vacuum_cost_limit = 1000       -- Higher limit
);
```

### 2. Adjusting Fillfactor for HOT Updates

**HOT Updates** (Heap-Only Tuple updates) avoid index updates when:
- Updated columns not in indexes
- Enough space on same page

```sql
-- Reserve 20% space for updates (default is 100% = no reserve)
ALTER TABLE users SET (fillfactor = 80);

-- Now HOT updates more likely
-- Less index bloat
-- Faster updates
```

### 3. Scheduled Manual VACUUM

```bash
# Cron job for off-peak vacuum
0 2 * * * psql -U postgres -c "VACUUM ANALYZE;"  # Daily at 2 AM
```

### 4. Monitoring and Alerting

```sql
-- Create monitoring function
CREATE OR REPLACE FUNCTION check_vacuum_health()
RETURNS TABLE(
    table_name text,
    issue text,
    severity text,
    recommendation text
) AS $$
BEGIN
    -- Check for tables with high dead tuple ratio
    RETURN QUERY
    SELECT
        schemaname||'.'||relname,
        'High dead tuple ratio: ' || round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) || '%',
        'WARNING',
        'Run VACUUM ANALYZE ' || schemaname||'.'||relname
    FROM pg_stat_user_tables
    WHERE n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0) > 20
      AND n_dead_tup > 1000;

    -- Check for tables not vacuumed recently
    RETURN QUERY
    SELECT
        schemaname||'.'||relname,
        'Not autovacuumed in: ' || (now() - last_autovacuum)::text,
        'CRITICAL',
        'Investigate why autovacuum not running'
    FROM pg_stat_user_tables
    WHERE last_autovacuum < now() - interval '7 days'
       OR last_autovacuum IS NULL;
END;
$$ LANGUAGE plpgsql;

-- Run health check
SELECT * FROM check_vacuum_health();
```

### 5. Preventing Transaction ID Wraparound

```sql
-- Check current XID age
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY age(datfrozenxid) DESC;

-- Force aggressive vacuum before emergency
VACUUM FREEZE;

-- This is automatic with autovacuum, but monitor!
```

---

## 🔧 Troubleshooting

### Problem 1: Autovacuum Not Running

**Symptoms:**
- Dead tuple count increasing
- No recent last_autovacuum timestamp
- Table performance degrading

**Diagnosis:**
```sql
-- Check if autovacuum enabled
SHOW autovacuum;

-- Check for blocking long transactions
SELECT pid, now() - xact_start AS duration, state, query
FROM pg_stat_activity
WHERE state != 'idle' AND xact_start < now() - interval '30 minutes'
ORDER BY xact_start;

-- Check autovacuum workers
SELECT * FROM pg_stat_activity WHERE query LIKE '%autovacuum%';
```

**Solutions:**
```sql
-- Enable autovacuum if disabled
ALTER SYSTEM SET autovacuum = on;
SELECT pg_reload_conf();

-- Kill blocking transactions
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE ...;

-- Increase autovacuum workers
ALTER SYSTEM SET autovacuum_max_workers = 5;
-- Requires restart
```

### Problem 2: VACUUM Taking Too Long

**Symptoms:**
- VACUUM command hangs for hours
- High I/O usage
- Blocking other operations

**Diagnosis:**
```sql
-- Check VACUUM progress (PostgreSQL 12+)
SELECT
    a.pid,
    a.query,
    p.phase,
    p.heap_blks_total,
    p.heap_blks_scanned,
    round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 2) AS percent_complete
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid;
```

**Solutions:**
```sql
-- Use parallel workers (PostgreSQL 13+)
SET max_parallel_maintenance_workers = 4;
VACUUM (PARALLEL 4) large_table;

-- Vacuum in smaller batches
VACUUM users;  -- Instead of VACUUM FULL
```

### Problem 3: High Bloat Despite Regular VACUUM

**Symptoms:**
- VACUUM runs regularly
- Bloat still increasing
- Table size not decreasing

**Cause:** HOT updates not possible (index on updated columns)

**Solutions:**
```sql
-- Adjust fillfactor
ALTER TABLE users SET (fillfactor = 70);

-- Rebuild table to apply fillfactor
VACUUM FULL users;
-- or better: pg_repack

-- More aggressive autovacuum
ALTER TABLE users SET (autovacuum_vacuum_scale_factor = 0.05);
```

---

## 💼 Interview Questions

### Q1: "What is VACUUM and why is it needed?"

**Answer:**
> "VACUUM is PostgreSQL's maintenance command that reclaims storage from dead tuples. PostgreSQL uses MVCC (Multi-Version Concurrency Control) which creates new row versions on updates instead of modifying in place. Old versions become 'dead tuples' that waste space and slow queries.
> 
> VACUUM marks these dead tuples as reusable space. Without VACUUM, tables would grow indefinitely even if actual data size stays constant. Autovacuum runs automatically, but manual VACUUM may be needed after bulk operations.
> 
> Example: After deleting 100K rows from a 1M row table, the table size doesn't shrink until VACUUM runs and marks that space as reusable."

### Q2: "When would you use VACUUM FULL vs regular VACUUM?"

**Answer:**
> "Regular VACUUM is for normal maintenance - it's fast, non-blocking, and runs continuously via autovacuum. It marks dead space as reusable but doesn't shrink the table.
> 
> VACUUM FULL is for extreme bloat situations - it rewrites the entire table, compacting data and returning space to the OS. But it:
> - Takes exclusive lock (blocks all operations)
> - Is very slow (hours for large tables)
> - Requires 2x table size free disk space
> - Generates massive WAL (replication lag)
> 
> **Use VACUUM FULL only when:**
> - Table is >50% bloated
> - During scheduled maintenance window
> - Disk space critically low
> 
> **Better alternatives:** pg_repack (online, no locks) or increase autovacuum aggressiveness to prevent bloat."

### Q3: "How do you detect and fix table bloat?"

**Answer:**
> "**Detection:**
> ```sql
> -- Check dead tuple ratio
> SELECT relname, n_live_tup, n_dead_tup,
>        round(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup), 2) AS bloat_pct
> FROM pg_stat_user_tables
> WHERE n_dead_tup > 1000
> ORDER BY bloat_pct DESC;
> 
> -- Detailed analysis with pgstattuple
> SELECT * FROM pgstattuple('table_name');
> ```
> 
> **Fixing:**
> 1. **Prevention:** Tune autovacuum before bloat occurs
> ```sql
> ALTER TABLE high_update_table SET (
>   autovacuum_vacuum_scale_factor = 0.05  -- 5% instead of 20%
> );
> ```
> 
> 2. **Regular bloat:** VACUUM ANALYZE
> 3. **Severe bloat (>30%):** pg_repack (online) or VACUUM FULL (offline)
> 
> I'd also investigate root cause: long transactions, insufficient autovacuum workers, or fillfactor issues."

### Q4: "Explain autovacuum and how to tune it"

**Answer:**
> "Autovacuum automatically runs VACUUM on tables when dead tuple threshold is exceeded:
> ```
> Triggers when: dead_tuples > threshold + (scale_factor × table_size)
> Default: 50 + (0.2 × row_count)
> ```
> 
> **For a 100K row table:** autovacuum runs at 20,050 dead tuples (20%)
> 
> **Tuning for write-heavy tables:**
> ```sql
> -- More aggressive (trigger at 5% instead of 20%)
> ALTER TABLE orders SET (
>   autovacuum_vacuum_scale_factor = 0.05,
>   autovacuum_vacuum_cost_delay = 0  -- Faster, no throttling
> );
> ```
> 
> **Global tuning (postgresql.conf):**
> - Increase autovacuum_max_workers for parallelism
> - Lower autovacuum_naptime for frequent checks
> - Adjust cost settings to prevent I/O overload
> 
> **Monitoring:**
> Check pg_stat_user_tables for last_autovacuum and n_dead_tup regularly."

### Q5: "How do you handle VACUUM during high-traffic hours?"

**Answer:**
> "**Strategies for production:**
> 
> 1. **Rely on autovacuum:** It's designed to run during production with minimal impact via cost-based delays
> 
> 2. **Throttle autovacuum:**
> ```sql
> -- Slower but less I/O impact
> ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 20;  -- Default: 2ms
> ```
> 
> 3. **Schedule manual VACUUM off-peak:**
> ```bash
> cron: 0 2 * * * psql -c "VACUUM ANALYZE;"  # 2 AM daily
> ```
> 
> 4. **Use VACUUM (VERBOSE)** to monitor progress and I/O impact
> 
> 5. **For critical tables during peak:** Temporarily disable autovacuum, run manual VACUUM with cost limits:
> ```sql
> SET vacuum_cost_delay = 10;
> VACUUM ANALYZE critical_table;
> ```
> 
> 6. **Never VACUUM FULL in production** - use pg_repack for online compaction
> 
> Key is monitoring: if dead tuple ratio exceeds 10-15%, VACUUM impact is smaller than bloat's query performance hit."

---

## 🎯 Hands-on Scenarios

### Scenario 1: Simulating and Measuring Bloat
**See:** [Scenario 14: VACUUM and Bloat Testing](../scenarios/14-vacuum-bloat-testing.md)

### Scenario 2: Autovacuum Tuning
**See:** [Scenario 15: Autovacuum Optimization](../scenarios/15-autovacuum-tuning.md)

### Scenario 3: Emergency Bloat Remediation
**See:** [Scenario 16: Bloat Crisis Management](../scenarios/16-bloat-crisis.md)

---

## 📚 Additional Resources

- **Official Docs:** https://www.postgresql.org/docs/current/routine-vacuuming.html
- **pgstattuple:** https://www.postgresql.org/docs/current/pgstattuple.html
- **pg_repack:** https://reorg.github.io/pg_repack/
- **Monitoring:** Prometheus postgres_exporter

---

## 🎓 Key Takeaways

1. **MVCC creates dead tuples** - Normal PostgreSQL behavior
2. **VACUUM is essential** - Without it, databases bloat infinitely
3. **Autovacuum is your friend** - Trust it, but tune it
4. **Monitor dead tuple ratio** - Alert at >20%
5. **VACUUM FULL is dangerous** - Use pg_repack instead
6. **Bloat prevention > remediation** - Tune before problems arise
7. **Long transactions block VACUUM** - Kill them if necessary
8. **Transaction ID wraparound is critical** - Monitor XID age

---

**Next:** [Scenario 14: Hands-on VACUUM and Bloat Testing](../scenarios/14-vacuum-bloat-testing.md)
