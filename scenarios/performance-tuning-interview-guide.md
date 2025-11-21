# PostgreSQL Performance Tuning - Interview Guide

**Essential Knowledge for Senior PostgreSQL DBA Roles**

---

## 🎯 Interview Framework: Performance Problem Solving

**Standard Interview Question Flow:**
1. "Describe your approach to troubleshooting slow queries"
2. "How do you identify performance bottlenecks?"
3. "Walk me through optimizing a specific scenario"
4. "What tools do you use for performance monitoring?"

---

## 📊 1. Performance Troubleshooting Methodology

### The 5-Step Approach

**Step 1: Identify the Problem**
```sql
-- Find slow queries
SELECT 
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    max_exec_time,
    stddev_exec_time,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- Requires: CREATE EXTENSION pg_stat_statements;
```

**Step 2: Analyze Query Plan**
```sql
-- EXPLAIN shows plan
EXPLAIN SELECT * FROM orders WHERE customer_id = 123;

-- EXPLAIN ANALYZE shows actual execution
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 123;

-- EXPLAIN with all details
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT JSON) 
SELECT * FROM orders WHERE customer_id = 123;
```

**Step 3: Check Statistics**
```sql
-- Are table statistics up to date?
SELECT 
    schemaname,
    tablename,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    n_dead_tup,
    n_live_tup
FROM pg_stat_user_tables
WHERE tablename = 'orders';

-- Update statistics
ANALYZE orders;
```

**Step 4: Look for System Issues**
```sql
-- Check for locks
SELECT 
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    query,
    backend_start,
    xact_start,
    state_change
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY xact_start;

-- Check for blocking queries
SELECT 
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS blocking_statement
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks 
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
```

**Step 5: Implement Solution & Verify**
```sql
-- After adding index/tuning
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 123;
-- Compare: Before 500ms → After 5ms ✅
```

---

## 🔍 2. EXPLAIN Plan Analysis

### Understanding EXPLAIN Output

```sql
EXPLAIN ANALYZE
SELECT o.*, c.name 
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.order_date > '2025-01-01'
ORDER BY o.order_date DESC
LIMIT 100;
```

**Key Metrics to Look For:**

```
Sort (cost=1234.56..1234.78 rows=100 width=64) (actual time=45.123..45.234 rows=100 loops=1)
  │
  ├─ cost=1234.56..1234.78    ← Planner's estimate (ignore for tuning)
  ├─ rows=100                  ← Estimated rows
  ├─ actual time=45.123        ← ACTUAL execution time (important!)
  ├─ rows=100                  ← Actual rows returned
  └─ loops=1                   ← Times this node executed
```

**Bad Signs in EXPLAIN:**

1. **Seq Scan on large table**
```
Seq Scan on orders (actual time=0.012..5234.567 rows=1000000)
  Filter: customer_id = 123
  Rows Removed by Filter: 999999
```
❌ Problem: Reading 1M rows to find 1 match!
✅ Solution: CREATE INDEX idx_customer ON orders(customer_id);

2. **Nested Loop with huge outer side**
```
Nested Loop (actual time=0.123..45678.901 rows=1000000)
  -> Seq Scan on orders (rows=1000000)
  -> Index Scan on customers (rows=1)
```
❌ Problem: 1M loop iterations!
✅ Solution: Add WHERE clause or swap join order

3. **Rows estimate very wrong**
```
Hash Join (cost=... rows=100 width=...) (actual rows=500000 loops=1)
```
❌ Problem: Planner expected 100, got 500K!
✅ Solution: ANALYZE table; (update statistics)

4. **Expensive Sort**
```
Sort (actual time=5234.567..5678.901 rows=1000000)
  Sort Key: order_date
  Sort Method: external merge Disk: 102400kB
```
❌ Problem: Sorting 1M rows on disk!
✅ Solution: CREATE INDEX idx_order_date ON orders(order_date);

---

## ⚡ 3. Common Performance Problems & Solutions

### Problem 1: Missing Index

**Symptom:**
```sql
-- Query takes 5 seconds
SELECT * FROM orders WHERE customer_id = 123;

-- EXPLAIN shows Seq Scan
Seq Scan on orders (actual time=0.012..5234.567 rows=100)
  Filter: customer_id = 123
  Rows Removed by Filter: 9999900
```

**Solution:**
```sql
-- Create index
CREATE INDEX CONCURRENTLY idx_customer ON orders(customer_id);

-- Now takes 5ms ✅
Index Scan using idx_customer on orders (actual time=0.012..0.234 rows=100)
  Index Cond: customer_id = 123
```

**Interview Answer:**
> "When I see a Seq Scan with 'Rows Removed by Filter' in the millions, that's a red flag. The query scanned 10M rows to return 100—classic missing index. I created a B-Tree index on customer_id using CONCURRENTLY to avoid locking, which reduced execution time from 5 seconds to 5 milliseconds—a 1000x improvement."

---

### Problem 2: Outdated Statistics

**Symptom:**
```sql
-- Planner chooses bad plan
Hash Join (rows=100 estimate) (actual rows=500000)
```

**Diagnosis:**
```sql
-- Check last analyze
SELECT last_analyze, last_autoanalyze 
FROM pg_stat_user_tables 
WHERE tablename = 'orders';
-- Result: 30 days ago!

-- Check statistics target
SELECT attname, attstattarget 
FROM pg_attribute 
WHERE attrelid = 'orders'::regclass;
-- Result: -1 (default 100)
```

**Solution:**
```sql
-- Update statistics
ANALYZE orders;

-- For specific column with high cardinality
ALTER TABLE orders ALTER COLUMN customer_id SET STATISTICS 1000;
ANALYZE orders;

-- Enable auto-analyze (should be default)
ALTER TABLE orders SET (autovacuum_analyze_scale_factor = 0.05);
```

**Interview Answer:**
> "When the estimated rows are off by 100x, statistics are usually stale. I check pg_stat_user_tables for last_analyze timestamp. If it's been weeks, I run ANALYZE. For high-cardinality columns, I increase statistics target to 1000 so the planner has better histograms. After updating statistics, the planner chose a Hash Join instead of Nested Loop, reducing query time from 30 seconds to 2 seconds."

---

### Problem 3: Table Bloat

**Symptom:**
```sql
-- Table is 10 GB but only 2 GB of live data
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

-- Result: orders has 80% dead tuples!
```

**Solution:**
```sql
-- Analyze bloat
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
                   pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_stat_user_tables
WHERE tablename = 'orders';

-- Quick fix: VACUUM
VACUUM VERBOSE orders;

-- Aggressive fix (locks table!): VACUUM FULL
VACUUM FULL orders;  -- Don't do in production without downtime window!

-- Better: Tune autovacuum
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.05,  -- VACUUM at 5% dead tuples
    autovacuum_analyze_scale_factor = 0.02   -- ANALYZE at 2% changes
);

-- Or: REINDEX CONCURRENTLY for index bloat
REINDEX INDEX CONCURRENTLY idx_customer;
```

**Interview Answer:**
> "I discovered the orders table was 10 GB but had 80% dead tuples—classic bloat from heavy UPDATEs. Regular VACUUM wasn't keeping up. I tuned autovacuum_vacuum_scale_factor from 0.2 to 0.05, so VACUUM runs at 5% dead tuples instead of 20%. For immediate relief, I ran VACUUM VERBOSE during off-hours. After a few autovacuum cycles, the table compacted to 3 GB, and sequential scan performance improved 3x."

---

### Problem 4: Lock Contention

**Symptom:**
```sql
-- Queries hanging
SELECT * FROM pg_stat_activity WHERE state = 'active' AND wait_event IS NOT NULL;

-- Many queries waiting
| pid  | wait_event_type | wait_event    | state  | query                        |
|------|----------------|---------------|--------|------------------------------|
| 1234 | Lock           | transactionid | active | UPDATE orders SET status...  |
| 1235 | Lock           | transactionid | active | UPDATE orders SET status...  |
| 1236 | Lock           | transactionid | active | UPDATE orders SET status...  |
```

**Diagnosis:**
```sql
-- Find blocking query
SELECT 
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query,
    blocking.state AS blocking_state
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid
JOIN pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_stat_activity blocking ON blocking.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted AND blocking_locks.granted;
```

**Solution:**
```sql
-- Kill blocking query (last resort!)
SELECT pg_terminate_backend(1234);

-- Better: Fix application code
-- Before (long transaction):
BEGIN;
UPDATE orders SET status = 'processed' WHERE id = 123;
-- ... do lots of application logic ...
-- ... network calls ...
COMMIT;  -- Lock held for minutes!

-- After (short transaction):
-- Do application logic first
BEGIN;
UPDATE orders SET status = 'processed' WHERE id = 123;
COMMIT;  -- Lock held for milliseconds!

-- Or use FOR UPDATE SKIP LOCKED
SELECT * FROM orders WHERE status = 'pending' 
FOR UPDATE SKIP LOCKED LIMIT 10;
-- Multiple workers can process different rows without blocking!
```

**Interview Answer:**
> "I identified lock contention using pg_stat_activity—dozens of queries waiting on transactionid locks. The root cause was a long-running transaction holding locks for minutes while doing application logic. I worked with the dev team to restructure: do business logic outside transactions, keep transactions minimal. We also implemented FOR UPDATE SKIP LOCKED for the job queue so workers don't block each other. Lock wait time dropped from 30 seconds average to under 100ms."

---

### Problem 5: N+1 Query Problem

**Symptom:**
```sql
-- Application runs 10,001 queries to display 10,000 orders with customer names!

-- Query 1:
SELECT * FROM orders LIMIT 10000;

-- Queries 2-10001 (in a loop!):
SELECT name FROM customers WHERE id = ?;
SELECT name FROM customers WHERE id = ?;
... (10,000 times!)
```

**Solution:**
```sql
-- Single query with JOIN
SELECT o.*, c.name AS customer_name
FROM orders o
JOIN customers c ON o.customer_id = c.id
LIMIT 10000;

-- Or: Batch query
SELECT * FROM orders WHERE id = ANY(ARRAY[1,2,3,...,10000]);

-- Check for N+1 in logs
-- Enable: log_min_duration_statement = 100
-- Then grep for patterns of identical queries
```

**Interview Answer:**
> "I noticed 10,000+ queries in a single page load—classic N+1 problem. The ORM was fetching orders, then looping to fetch each customer. I enabled pg_stat_statements and saw the same SELECT pattern repeated thousands of times. Solution: eager loading in the ORM (JOIN in SQL). Database queries dropped from 10,001 to 1, and page load time went from 5 seconds to 200ms."

---

### Problem 6: Inefficient JOIN Order

**Symptom:**
```sql
EXPLAIN ANALYZE
SELECT * FROM large_table l
JOIN small_table s ON l.small_id = s.id
WHERE s.category = 'active';

-- Bad plan: Nested Loop scanning large_table for each row in small_table
Nested Loop (actual time=0.123..45678.901 rows=100)
  -> Seq Scan on large_table (rows=10000000)
  -> Index Scan on small_table (rows=1)
```

**Solution:**
```sql
-- Rewrite with explicit filtering
SELECT * FROM large_table l
JOIN small_table s ON l.small_id = s.id
WHERE s.category = 'active'
  AND l.small_id IN (SELECT id FROM small_table WHERE category = 'active');

-- Or: Use CTE to materialize small result first
WITH active_small AS (
    SELECT id FROM small_table WHERE category = 'active'
)
SELECT * FROM large_table l
JOIN active_small s ON l.small_id = s.id;

-- Or: Better statistics + indexes
CREATE INDEX idx_small_category ON small_table(category);
ANALYZE small_table;
```

**Interview Answer:**
> "The planner chose a Nested Loop scanning 10M rows for each of 100 matches—very inefficient. I rewrote the query with a CTE to materialize the small result set first, forcing PostgreSQL to filter early. Execution time dropped from 45 seconds to 2 seconds. Additionally, I created an index on small_table.category and ran ANALYZE to help the planner make better decisions in the future."

---

## 🔧 4. PostgreSQL Configuration Tuning

### Memory Settings

```ini
# postgresql.conf

# --- MEMORY ---

# Shared buffers: 25% of RAM (max 40%)
# Rule: Start with 25% of RAM
shared_buffers = 8GB                    # For 32 GB RAM server

# Work memory per operation (sort, hash)
# Rule: (RAM - shared_buffers) / max_connections / 2
work_mem = 64MB                         # Per sort/hash operation
# Example: (32GB - 8GB) / 200 connections / 2 = 60MB

# Maintenance operations (VACUUM, CREATE INDEX)
maintenance_work_mem = 2GB              # For maintenance operations

# Effective cache size (hint to planner)
# Set to: 50-75% of total RAM
effective_cache_size = 24GB             # For 32 GB RAM

# Maximum memory for autovacuum
autovacuum_work_mem = 2GB               # -1 uses maintenance_work_mem
```

**Interview Answer:**
> "For a 32 GB server, I set shared_buffers to 8 GB (25%), work_mem to 64 MB based on expected concurrent operations, and effective_cache_size to 24 GB to tell the planner most data fits in memory. I also set maintenance_work_mem to 2 GB for faster index builds and VACUUM operations."

### Checkpoint Settings

```ini
# --- CHECKPOINTS ---

# Checkpoint timeout
checkpoint_timeout = 15min             # Default 5min (too frequent)

# Max WAL size before checkpoint
max_wal_size = 4GB                     # Increase for write-heavy workloads

# Min WAL size to keep
min_wal_size = 1GB

# Checkpoint completion target
checkpoint_completion_target = 0.9     # Spread writes over 90% of interval

# WAL segment size (compile-time, shown for reference)
# wal_segment_size = 16MB

# --- WAL ---

# WAL write optimization
wal_buffers = 16MB                     # -1 auto-tunes to shared_buffers/32
wal_writer_delay = 200ms               # How often WAL writer flushes

# Synchronous commit (durability vs performance)
synchronous_commit = on                # on=durable, off=faster but risk data loss
commit_delay = 0                       # Group commits (microseconds)
```

**Interview Answer:**
> "For write-heavy workloads, I increase checkpoint_timeout to 15 minutes and max_wal_size to 4 GB to reduce checkpoint frequency—frequent checkpoints cause I/O spikes. I set checkpoint_completion_target to 0.9 to spread writes over 90% of the interval, avoiding sudden I/O bursts. This reduced checkpoint-related stalls from 20 per hour to 4 per hour."

### Connection Settings

```ini
# --- CONNECTIONS ---

# Max connections (be conservative!)
max_connections = 200                  # Don't go crazy here

# Connection pooler is better for high connection counts
# Use pgBouncer: 5000 app connections → 200 DB connections

# Reserved connections for superuser
superuser_reserved_connections = 3

# Connection limits per role
ALTER ROLE app_user CONNECTION LIMIT 100;
```

**Interview Answer:**
> "I keep max_connections at 200 rather than 1000+ because each connection uses memory. For high connection counts, I use pgBouncer: 5000 app connections pool down to 200 database connections. This reduces context switching and memory overhead while still handling traffic spikes."

### Query Planner Settings

```ini
# --- QUERY PLANNER ---

# Random page cost (lower for SSD)
random_page_cost = 1.1                 # Default 4.0 (HDD)
                                       # SSD: 1.1-1.5
                                       # NVMe: 1.0-1.1

# Sequential page cost
seq_page_cost = 1.0                    # Default

# CPU costs
cpu_tuple_cost = 0.01                  # Cost per row processed
cpu_index_tuple_cost = 0.005           # Cost per index row
cpu_operator_cost = 0.0025             # Cost per operator

# Parallel query settings
max_parallel_workers_per_gather = 4    # Parallel workers per query
max_parallel_workers = 8               # Total parallel workers
max_worker_processes = 8               # Background workers

# Enable/disable planner features (for testing)
enable_seqscan = on
enable_indexscan = on
enable_bitmapscan = on
enable_nestloop = on
enable_hashjoin = on
enable_mergejoin = on
```

**Interview Answer:**
> "On SSD storage, I lower random_page_cost from 4.0 to 1.1 because SSDs have near-equal random and sequential read costs. This helps the planner choose index scans more often. I also enable parallel queries with max_parallel_workers_per_gather = 4 for large analytical queries, which reduced a 10-minute report to 3 minutes."

### Logging Settings

```ini
# --- LOGGING ---

# Log slow queries
log_min_duration_statement = 1000      # Log queries > 1 second

# Log all queries (development only!)
# log_statement = 'all'                # 'none', 'ddl', 'mod', 'all'

# Log connections/disconnections
log_connections = on
log_disconnections = on

# Log lock waits > 1 second
log_lock_waits = on
deadlock_timeout = 1s

# Log checkpoints
log_checkpoints = on

# Log autovacuum
log_autovacuum_min_duration = 0        # Log all autovacuum activity

# Log temp files > 10MB
log_temp_files = 10MB

# Line prefix for easier parsing
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

# Destination
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 1GB
```

**Interview Answer:**
> "I set log_min_duration_statement to 1000ms to capture slow queries for analysis. I enable log_checkpoints and log_autovacuum_min_duration to monitor system health. For production troubleshooting, I enable log_lock_waits to identify lock contention. These logs feed into pgBadger for daily performance reports."

---

## 📊 5. Monitoring & Tools

### Essential Monitoring Queries

**1. Current Activity**
```sql
-- Active queries
SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    query_start,
    state_change,
    LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY query_start;
```

**2. Table Statistics**
```sql
-- Most accessed tables
SELECT 
    schemaname,
    tablename,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    n_live_tup,
    n_dead_tup
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;
```

**3. Index Usage**
```sql
-- Unused indexes
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

**4. Database Size**
```sql
-- Database sizes
SELECT 
    datname,
    pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;

-- Table sizes with indexes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
                   pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

**5. Replication Lag**
```sql
-- On primary
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_size,
    replay_lag
FROM pg_stat_replication;
```

### Monitoring Tools

**1. pg_stat_statements**
```sql
-- Enable extension
CREATE EXTENSION pg_stat_statements;

-- Top slow queries by total time
SELECT 
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    max_exec_time,
    stddev_exec_time
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- Top slow queries by average time
SELECT 
    query,
    calls,
    mean_exec_time,
    max_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;
```

**2. pgBadger (Log Analyzer)**
```bash
# Install
sudo apt-get install pgbadger

# Generate report
pgbadger /var/log/postgresql/postgresql-2025-11-21.log -o report.html

# Incremental mode (daily cron job)
pgbadger --prefix '%t [%p]: ' \
         --incremental \
         --outdir /var/www/html/pgbadger \
         /var/log/postgresql/postgresql-*.log
```

**3. Prometheus + Grafana**
```yaml
# postgres_exporter for Prometheus
docker run -d \
  --name postgres-exporter \
  -p 9187:9187 \
  -e DATA_SOURCE_NAME="postgresql://user:password@localhost:5432/dbname?sslmode=disable" \
  quay.io/prometheuscommunity/postgres-exporter

# Key metrics:
# - pg_stat_database_tup_*
# - pg_stat_bgwriter_*
# - pg_stat_activity_count
# - pg_replication_lag
```

**4. pg_top / pg_activity**
```bash
# Real-time monitoring
sudo apt-get install pg-activity
pg_activity -U postgres -h localhost

# Shows:
# - Active queries
# - CPU usage
# - Memory usage
# - I/O wait
```

---

## 💼 Interview Questions & Answers

### Q1: "A critical query suddenly became slow. Walk me through your troubleshooting process."

**Answer:**
> "I follow a systematic approach:
>
> **1. Capture the query and current performance:**
> ```sql
> SELECT query, mean_exec_time, calls 
> FROM pg_stat_statements 
> WHERE query ILIKE '%critical_table%';
> ```
> Current: 5 seconds, was 50ms yesterday
>
> **2. Get the execution plan:**
> ```sql
> EXPLAIN (ANALYZE, BUFFERS) [the slow query];
> ```
> Found: Seq Scan instead of Index Scan
>
> **3. Check statistics freshness:**
> ```sql
> SELECT last_analyze FROM pg_stat_user_tables WHERE tablename = 'critical_table';
> ```
> Result: 30 days old—red flag!
>
> **4. Update statistics and retest:**
> ```sql
> ANALYZE critical_table;
> ```
> Result: Query back to 50ms
>
> **5. Implement monitoring:**
> - Add autovacuum tuning to prevent recurrence
> - Set up alert if analyze age > 7 days
> - Document the incident
>
> Root cause: Stale statistics after bulk INSERT caused planner to underestimate table size by 100x, choosing wrong plan."

### Q2: "How do you tune PostgreSQL for a read-heavy workload?"

**Answer:**
> "For read-heavy workloads, I focus on:
>
> **1. Memory allocation:**
> ```ini
> shared_buffers = 10GB        # 25% of 40GB RAM
> effective_cache_size = 30GB  # 75% of RAM (hint to planner)
> work_mem = 100MB             # Larger for complex queries
> ```
>
> **2. Query planner:**
> ```ini
> random_page_cost = 1.1       # SSD optimization
> effective_io_concurrency = 200  # SSD parallel reads
> ```
>
> **3. Read replicas:**
> - Set up 2-3 standbys for read traffic
> - Use pgPool or HAProxy for load balancing
> - Monitor replication lag < 100ms
>
> **4. Indexes:**
> - Create covering indexes for common queries
> - Use partial indexes for filtered queries
> - Monitor pg_stat_user_indexes for unused indexes
>
> **5. Connection pooling:**
> - pgBouncer in transaction mode
> - 5000 app connections → 200 DB connections
>
> **Result:** In my previous role, these changes reduced average query time from 200ms to 30ms and increased throughput from 5K QPS to 25K QPS."

### Q3: "Explain the difference between VACUUM and VACUUM FULL."

**Answer:**
> "VACUUM and VACUUM FULL both reclaim dead tuple space, but very differently:
>
> **VACUUM (regular):**
> - Marks dead tuples as reusable
> - Does NOT shrink table file
> - Runs concurrently (no locks!)
> - Fast (minutes for large tables)
> - Run frequently (autovacuum does this)
> - Space reused by new rows
>
> **VACUUM FULL:**
> - Completely rewrites table file
> - Shrinks table to minimum size
> - Takes EXCLUSIVE lock (blocks everything!)
> - Slow (hours for large tables)
> - Requires 2x disk space (old + new file)
> - Last resort only
>
> **Example scenario:**
> - Table: 100 GB total, 30 GB dead, 70 GB live
> - VACUUM: Marks 30 GB reusable, file stays 100 GB
> - VACUUM FULL: Rewrites to new 70 GB file, blocks all access
>
> **My approach:**
> 1. Never use VACUUM FULL in production during business hours
> 2. Tune autovacuum to prevent bloat reaching that point:
>    ```sql
>    ALTER TABLE large_table SET (
>        autovacuum_vacuum_scale_factor = 0.05
>    );
>    ```
> 3. If VACUUM FULL needed, schedule maintenance window or use pg_repack (zero-downtime alternative)"

### Q4: "How do you identify and fix lock contention?"

**Answer:**
> "Lock contention shows up as queries waiting with wait_event_type = 'Lock'. My process:
>
> **1. Identify waiting queries:**
> ```sql
> SELECT pid, state, wait_event, query
> FROM pg_stat_activity
> WHERE wait_event_type = 'Lock';
> ```
>
> **2. Find blocking query:**
> ```sql
> SELECT blocking.pid, blocking.query, blocked.pid, blocked.query
> FROM pg_locks blocked_locks
> JOIN pg_stat_activity blocked ON blocked.pid = blocked_locks.pid
> JOIN pg_locks blocking_locks ON blocking_locks.granted
> JOIN pg_stat_activity blocking ON blocking.pid = blocking_locks.pid
> WHERE NOT blocked_locks.granted;
> ```
>
> **3. Analyze root cause:**
> - Long-running transaction? → Fix application to commit faster
> - Lock escalation? → Break large updates into smaller batches
> - Row-level contention? → Use FOR UPDATE SKIP LOCKED
>
> **4. Implement solution:**
>
> *Example 1: Job queue processing*
> ```sql
> -- Before: Workers block each other
> SELECT * FROM jobs WHERE status = 'pending' LIMIT 10 FOR UPDATE;
>
> -- After: Workers skip locked rows
> SELECT * FROM jobs WHERE status = 'pending' 
> FOR UPDATE SKIP LOCKED LIMIT 10;
> ```
>
> *Example 2: Batch updates*
> ```sql
> -- Before: Single transaction locks 1M rows
> UPDATE orders SET processed = true WHERE created_at < '2025-01-01';
>
> -- After: Batches of 10K rows
> DO $$
> DECLARE batch_size INT := 10000;
> BEGIN
>   LOOP
>     UPDATE orders SET processed = true 
>     WHERE id IN (
>       SELECT id FROM orders 
>       WHERE created_at < '2025-01-01' AND NOT processed 
>       LIMIT batch_size
>     );
>     EXIT WHEN NOT FOUND;
>     COMMIT;
>     PERFORM pg_sleep(0.1); -- Brief pause between batches
>   END LOOP;
> END $$;
> ```
>
> **Result:** Average lock wait time dropped from 30 seconds to 100ms."

### Q5: "What's your approach to capacity planning for PostgreSQL?"

**Answer:**
> "I use a data-driven approach with these key metrics:
>
> **1. Storage growth:**
> ```sql
> -- Track daily growth
> SELECT 
>     date_trunc('day', now()) AS date,
>     pg_database_size('production') AS size_bytes
> FROM generate_series(now() - interval '30 days', now(), interval '1 day');
> ```
> Calculate: 100 GB/month growth → need 1.2 TB/year
>
> **2. CPU/Memory utilization:**
> - Monitor pg_stat_activity connection count
> - Track buffer hit ratio (should be > 99%)
> - Monitor checkpoint frequency (< 4/hour ideal)
>
> **3. I/O capacity:**
> ```sql
> -- Track IOPS requirements
> SELECT SUM(blks_read + blks_hit) AS total_io
> FROM pg_stat_user_tables;
> ```
> Current: 50K IOPS → upgrade to 100K IOPS SSD before reaching 80% capacity
>
> **4. Connection scaling:**
> - Current: 200 max_connections, peak 150 used
> - Headroom: 25% (50 connections)
> - Action: Implement pgBouncer before peak hits 180
>
> **5. Replication lag:**
> - Track replay_lag from pg_stat_replication
> - If lag > 10 seconds consistently → add standby or reduce write load
>
> **6. Proactive actions:**
> - Set alerts at 70% capacity (CPU, disk, connections)
> - Quarterly load testing
> - Annual architecture review
>
> **Example:** In my previous role, we grew from 500 GB to 5 TB over 2 years. By tracking weekly metrics, I planned upgrades 3 months in advance with zero outages."

---

## 📚 Performance Tuning Checklist

**Daily:**
- ✅ Monitor pg_stat_statements for slow queries
- ✅ Check replication lag < 10 seconds
- ✅ Verify autovacuum running
- ✅ Review error logs

**Weekly:**
- ✅ Review pgBadger report
- ✅ Check for table/index bloat > 30%
- ✅ Identify unused indexes
- ✅ Update statistics for large tables

**Monthly:**
- ✅ Capacity planning review
- ✅ Query optimization session
- ✅ Configuration tuning review
- ✅ REINDEX bloated indexes

**Quarterly:**
- ✅ Load testing
- ✅ Disaster recovery drill
- ✅ Performance baseline update
- ✅ Hardware upgrade planning

---

## ✅ Summary

**Key Performance Areas:**
1. ✅ Query optimization (EXPLAIN ANALYZE)
2. ✅ Index strategy (right type, right columns)
3. ✅ Configuration tuning (memory, checkpoints)
4. ✅ VACUUM maintenance (prevent bloat)
5. ✅ Lock contention (short transactions, SKIP LOCKED)
6. ✅ Monitoring (pg_stat_statements, pgBadger)

**Interview Readiness:**
- ✅ Can explain EXPLAIN output
- ✅ Know when to use each index type
- ✅ Understand VACUUM vs VACUUM FULL
- ✅ Can troubleshoot lock contention
- ✅ Know memory/configuration tuning
- ✅ Have real-world optimization examples

You're ready to tackle performance questions in senior PostgreSQL DBA interviews! 🚀
