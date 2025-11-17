# Scenario 14: VACUUM and Bloat Testing

**Objective:** Simulate table bloat, measure impact, and test VACUUM operations

**Duration:** 30-45 minutes

**Prerequisites:**
- PostgreSQL cluster running (PRIMARY + STANDBYs)
- psql access to PRIMARY
- pgstattuple extension (will be installed)

---

## 📋 What We'll Do

1. Create test table with data
2. Simulate bloat through updates
3. Measure bloat using multiple methods
4. Observe query performance degradation
5. Test VACUUM vs VACUUM FULL
6. Compare recovery times and results

---

## Step 1: Setup Test Environment

### 1.1: Connect to PRIMARY
```bash
docker exec -it postgres-primary psql -U postgres
```

### 1.2: Create Test Database and Table
```sql
-- Create database for testing
CREATE DATABASE vacuum_test;
\c vacuum_test

-- Install pgstattuple for bloat measurement
CREATE EXTENSION pgstattuple;

-- Create test table
CREATE TABLE bloat_test (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50),
    email VARCHAR(100),
    status VARCHAR(20),
    data TEXT,
    created_at TIMESTAMP DEFAULT now(),
    updated_at TIMESTAMP DEFAULT now()
);

-- Create index on frequently queried column
CREATE INDEX idx_bloat_test_status ON bloat_test(status);
CREATE INDEX idx_bloat_test_email ON bloat_test(email);
```

### 1.3: Populate Initial Data
```sql
-- Insert 100,000 rows (~50 MB)
INSERT INTO bloat_test (username, email, status, data)
SELECT
    'user_' || i,
    'user_' || i || '@example.com',
    CASE (i % 5)
        WHEN 0 THEN 'active'
        WHEN 1 THEN 'inactive'
        WHEN 2 THEN 'pending'
        WHEN 3 THEN 'suspended'
        ELSE 'deleted'
    END,
    repeat('x', 200)  -- 200 bytes of data
FROM generate_series(1, 100000) AS i;

-- Record: INSERT 0 100000
```

**Expected Output:**
```
INSERT 0 100000
```

### 1.4: Initial Measurements (Baseline)
```sql
-- Table size
SELECT pg_size_pretty(pg_total_relation_size('bloat_test')) AS total_size,
       pg_size_pretty(pg_relation_size('bloat_test')) AS table_size,
       pg_size_pretty(pg_total_relation_size('bloat_test') - pg_relation_size('bloat_test')) AS indexes_size;

-- Statistics
SELECT n_live_tup, n_dead_tup, last_vacuum, last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'bloat_test';

-- Detailed bloat measurement
SELECT * FROM pgstattuple('bloat_test');
```

**Expected Output:**
```
 total_size | table_size | indexes_size 
------------+------------+--------------
 45 MB      | 28 MB      | 17 MB

 n_live_tup | n_dead_tup | last_vacuum | last_autovacuum 
------------+------------+-------------+-----------------
     100000 |          0 |             | 

 table_len | tuple_count | tuple_len  | tuple_percent | dead_tuple_count | dead_tuple_len | dead_tuple_percent | free_space | free_percent 
-----------+-------------+------------+---------------+------------------+----------------+--------------------+------------+--------------
  29360128 |      100000 | 28800000   |         98.09 |                0 |              0 |                  0 |     253472 |         0.86
```

**Key Metrics to Note:**
- `table_len`: 29,360,128 bytes (~28 MB)
- `tuple_count`: 100,000
- `dead_tuple_count`: 0
- `dead_tuple_percent`: 0%
- **Baseline established: No bloat**

---

## Step 2: Simulate Table Bloat

### 2.1: Disable Autovacuum (For Testing)
```sql
-- Temporarily disable autovacuum on this table
ALTER TABLE bloat_test SET (autovacuum_enabled = false);
```

### 2.2: Perform Massive Updates (Create Dead Tuples)
```sql
-- Update all rows (creates 100,000 dead tuples)
UPDATE bloat_test SET status = 'updated_1', updated_at = now();

-- Measure after first update
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'bloat_test';
```

**Expected Output:**
```
 n_live_tup | n_dead_tup 
------------+------------
     100000 |     100000
```

**Analysis:**
- 100K live tuples (new versions)
- 100K dead tuples (old versions)
- **Table size should double!**

### 2.3: Multiple Update Rounds (Amplify Bloat)
```sql
-- Round 2
UPDATE bloat_test SET status = 'updated_2', updated_at = now();

-- Round 3
UPDATE bloat_test SET status = 'updated_3', updated_at = now();

-- Round 4
UPDATE bloat_test SET status = 'updated_4', updated_at = now();

-- Round 5
UPDATE bloat_test SET status = 'updated_5', updated_at = now();
```

### 2.4: Measure Bloat After Updates
```sql
-- Table size growth
SELECT pg_size_pretty(pg_total_relation_size('bloat_test')) AS total_size,
       pg_size_pretty(pg_relation_size('bloat_test')) AS table_size,
       pg_size_pretty(pg_total_relation_size('bloat_test') - pg_relation_size('bloat_test')) AS indexes_size;

-- Dead tuple count
SELECT 
    n_live_tup, 
    n_dead_tup,
    round(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup), 2) AS bloat_percentage
FROM pg_stat_user_tables
WHERE relname = 'bloat_test';

-- Detailed bloat analysis
SELECT 
    table_len AS table_bytes,
    pg_size_pretty(table_len) AS table_size,
    tuple_count AS live_tuples,
    dead_tuple_count AS dead_tuples,
    round(dead_tuple_percent, 2) AS dead_pct,
    pg_size_pretty(free_space) AS free_space
FROM pgstattuple('bloat_test');
```

**Expected Output:**
```
 total_size | table_size | indexes_size 
------------+------------+--------------
 184 MB     | 140 MB     | 44 MB        <-- 5x growth!

 n_live_tup | n_dead_tup | bloat_percentage 
------------+------------+------------------
     100000 |     500000 |            83.33  <-- 83% dead!

 table_bytes | table_size | live_tuples | dead_tuples | dead_pct | free_space 
-------------+------------+-------------+-------------+----------+------------
   146800640 | 140 MB     |      100000 |      500000 |    82.96 | 2 MB
```

**Bloat Analysis:**
- Table grew from **28 MB → 140 MB** (5x increase!)
- **500K dead tuples** vs 100K live tuples
- **83% of table is wasted space**
- Indexes also bloated (17 MB → 44 MB)

---

## Step 3: Measure Performance Impact

### 3.1: Test Query Performance (Bloated State)
```sql
-- Sequential scan performance
EXPLAIN ANALYZE SELECT * FROM bloat_test WHERE status = 'active';

-- Index scan performance
EXPLAIN ANALYZE SELECT * FROM bloat_test WHERE email = 'user_12345@example.com';

-- Aggregation performance
EXPLAIN ANALYZE SELECT status, count(*) FROM bloat_test GROUP BY status;
```

**Expected Output:**
```sql
-- Sequential scan
Seq Scan on bloat_test  (cost=0.00..30123.00 rows=20000 width=285) (actual time=0.234..187.456 rows=20000 loops=1)
  Filter: ((status)::text = 'active'::text)
  Rows Removed by Filter: 80000
Planning Time: 0.123 ms
Execution Time: 189.234 ms  <-- SLOW (bloated table)

-- Index scan
Index Scan using idx_bloat_test_email on bloat_test  (cost=0.42..8.44 rows=1 width=285) (actual time=0.234..0.245 rows=1 loops=1)
  Index Cond: ((email)::text = 'user_12345@example.com'::text)
Planning Time: 0.089 ms
Execution Time: 0.267 ms  <-- Also affected by bloated index
```

**Record these timings for comparison later!**

### 3.2: Measure I/O Impact
```sql
-- Enable timing
\timing on

-- Large table scan
SELECT count(*) FROM bloat_test;

-- Record time
Time: 156.789 ms  <-- Record this
```

---

## Step 4: Test VACUUM (Regular)

### 4.1: Run VACUUM with Verbose Output
```sql
VACUUM VERBOSE bloat_test;
```

**Expected Output:**
```
INFO:  vacuuming "public.bloat_test"
INFO:  scanned index "bloat_test_pkey" to remove 500000 row versions
DETAIL:  CPU: user: 0.23 s, system: 0.12 s, elapsed: 0.78 s
INFO:  scanned index "idx_bloat_test_status" to remove 500000 row versions
DETAIL:  CPU: user: 0.19 s, system: 0.09 s, elapsed: 0.65 s
INFO:  scanned index "idx_bloat_test_email" to remove 500000 row versions
DETAIL:  CPU: user: 0.21 s, system: 0.11 s, elapsed: 0.71 s
INFO:  "bloat_test": removed 500000 dead row versions in 17857 pages
DETAIL:  CPU: user: 1.23 s, system: 0.45 s, elapsed: 3.67 s
INFO:  "bloat_test": found 500000 removable, 100000 nonremovable row versions in 17857 out of 17857 heap pages
DETAIL:  0 dead row versions cannot be removed yet, oldest xmin: 1234
Skipped 0 pages due to buffer pins, 0 frozen pages.
CPU: user: 1.89 s, system: 0.78 s, elapsed: 5.89 s
VACUUM
```

**Key Points:**
- Scanned all indexes
- Removed 500K dead tuples
- Took ~6 seconds
- **But did table shrink?**

### 4.2: Check Table Size After VACUUM
```sql
-- Table size
SELECT pg_size_pretty(pg_total_relation_size('bloat_test')) AS total_size;

-- Dead tuple count
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'bloat_test';

-- Bloat measurement
SELECT 
    pg_size_pretty(table_len) AS table_size,
    dead_tuple_count AS dead_tuples,
    round(dead_tuple_percent, 2) AS dead_pct
FROM pgstattuple('bloat_test');
```

**Expected Output:**
```
 total_size 
------------
 184 MB      <-- SAME SIZE! No shrinkage

 n_live_tup | n_dead_tup 
------------+------------
     100000 |          0  <-- Dead tuples removed

 table_size | dead_tuples | dead_pct 
------------+-------------+----------
 140 MB     |           0 |     0.00  <-- 0% dead, but still 140 MB!
```

**Analysis:**
- ✅ Dead tuples removed (n_dead_tup = 0)
- ✅ Space marked as reusable
- ❌ **Table size NOT reduced** (still 140 MB instead of original 28 MB)
- Table now has 112 MB of free space for future inserts

### 4.3: Test Query Performance After VACUUM
```sql
-- Sequential scan
EXPLAIN ANALYZE SELECT * FROM bloat_test WHERE status = 'active';

-- Time it
\timing on
SELECT count(*) FROM bloat_test;
\timing off
```

**Expected Output:**
```
Execution Time: 145.234 ms  <-- Slightly better (was 189 ms)

Time: 98.456 ms  <-- Improved (was 156 ms)
```

**Analysis:**
- Performance improved ~20-30%
- But not as fast as original (bloat still exists as empty space)

---

## Step 5: Test VACUUM FULL

### 5.1: Run VACUUM FULL
```sql
-- Warning: This will lock the table!
\timing on
VACUUM FULL bloat_test;
\timing off
```

**Expected Output:**
```
VACUUM
Time: 8234.567 ms (00:08.235)  <-- Much slower than VACUUM!
```

**Note:** Took ~8 seconds vs 6 seconds for VACUUM

### 5.2: Check Table Size After VACUUM FULL
```sql
-- Table size
SELECT pg_size_pretty(pg_total_relation_size('bloat_test')) AS total_size,
       pg_size_pretty(pg_relation_size('bloat_test')) AS table_size;

-- Bloat measurement
SELECT 
    pg_size_pretty(table_len) AS table_size,
    dead_tuple_count AS dead_tuples,
    round(dead_tuple_percent, 2) AS dead_pct,
    round(free_percent, 2) AS free_pct
FROM pgstattuple('bloat_test');
```

**Expected Output:**
```
 total_size | table_size 
------------+------------
 45 MB      | 28 MB       <-- BACK TO ORIGINAL SIZE!

 table_size | dead_tuples | dead_pct | free_pct 
------------+-------------+----------+----------
 28 MB      |           0 |     0.00 |     0.86  <-- Compact!
```

**Analysis:**
- ✅ Table shrunk from 140 MB → 28 MB (80% space reclaimed!)
- ✅ Returned to original size
- ✅ All bloat eliminated

### 5.3: Test Query Performance After VACUUM FULL
```sql
-- Sequential scan
EXPLAIN ANALYZE SELECT * FROM bloat_test WHERE status = 'active';

-- Timing
\timing on
SELECT count(*) FROM bloat_test;
\timing off
```

**Expected Output:**
```
Execution Time: 45.678 ms  <-- MUCH FASTER (was 189 ms bloated, 145 ms after VACUUM)

Time: 38.123 ms  <-- Back to original performance!
```

**Performance Comparison:**
| State | Seq Scan Time | Improvement |
|-------|---------------|-------------|
| Bloated (140 MB) | 189 ms | Baseline |
| After VACUUM | 145 ms | 23% faster |
| After VACUUM FULL | 46 ms | 76% faster! |

---

## Step 6: Demonstrate Space Reuse (VACUUM Benefit)

### 6.1: Recreate Bloat
```sql
-- Bloat it again
UPDATE bloat_test SET status = 'round2', updated_at = now();
UPDATE bloat_test SET status = 'round3', updated_at = now();

-- Check size
SELECT pg_size_pretty(pg_relation_size('bloat_test')) AS table_size;
-- Result: ~84 MB (bloated again)
```

### 6.2: Run Regular VACUUM
```sql
VACUUM bloat_test;

-- Check size
SELECT pg_size_pretty(pg_relation_size('bloat_test')) AS table_size;
-- Result: Still ~84 MB
```

### 6.3: Insert New Data (Reuses Free Space)
```sql
-- Insert 50K new rows
INSERT INTO bloat_test (username, email, status, data)
SELECT
    'newuser_' || i,
    'newuser_' || i || '@example.com',
    'active',
    repeat('y', 200)
FROM generate_series(1, 50000) AS i;

-- Check size again
SELECT pg_size_pretty(pg_relation_size('bloat_test')) AS table_size,
       count(*) AS row_count
FROM bloat_test;
```

**Expected Output:**
```
 table_size | row_count 
------------+-----------
 84 MB      |    150000  <-- Size didn't grow! Reused free space
```

**Analysis:**
- Added 50K rows (50% more data)
- Table size stayed same (84 MB)
- **Free space from VACUUM was reused** ✅

---

## Step 7: Test Autovacuum Re-enabling

### 7.1: Re-enable Autovacuum
```sql
ALTER TABLE bloat_test SET (autovacuum_enabled = true);

-- Make it more aggressive for demo
ALTER TABLE bloat_test SET (
    autovacuum_vacuum_scale_factor = 0.1,  -- 10% instead of 20%
    autovacuum_vacuum_threshold = 50
);
```

### 7.2: Monitor Autovacuum Activity
```sql
-- Check current autovacuum status
SELECT 
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_autovacuum,
    autovacuum_count
FROM pg_stat_user_tables
WHERE relname = 'bloat_test';
```

### 7.3: Create Dead Tuples and Watch Autovacuum
```sql
-- Create 20K dead tuples (should trigger autovacuum at 15K threshold)
UPDATE bloat_test SET status = 'test_autovacuum' WHERE id <= 20000;

-- Wait 10 seconds
SELECT pg_sleep(10);

-- Check if autovacuum ran
SELECT 
    relname,
    n_dead_tup,
    last_autovacuum,
    now() - last_autovacuum AS time_since_av
FROM pg_stat_user_tables
WHERE relname = 'bloat_test';
```

**Expected Output:**
```
 relname    | n_dead_tup |     last_autovacuum     | time_since_av 
------------+------------+-------------------------+---------------
 bloat_test |          0 | 2025-11-17 17:23:45.123 | 00:00:03.456  <-- Autovacuum ran!
```

---

## Step 8: Index Bloat Testing

### 8.1: Check Index Bloat
```sql
-- Install pgstattuple if not already
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- Check index bloat
SELECT * FROM pgstatindex('bloat_test_pkey');
SELECT * FROM pgstatindex('idx_bloat_test_status');
```

**Expected Output:**
```
 version | tree_level | index_size | root_block_no | internal_pages | leaf_pages | empty_pages | deleted_pages | avg_leaf_density | leaf_fragmentation 
---------+------------+------------+---------------+----------------+------------+-------------+---------------+------------------+--------------------
       4 |          2 |   18268160 |             3 |             34 |       2193 |           0 |             0 |            89.45 |               0.00
```

**Key Metrics:**
- `index_size`: 18 MB (bloated from original ~2 MB)
- `deleted_pages`: 0 (after VACUUM)
- `avg_leaf_density`: 89.45% (healthy is >90%)

### 8.2: REINDEX to Fix Index Bloat
```sql
-- Reindex single index
REINDEX INDEX idx_bloat_test_status;

-- Or reindex entire table
REINDEX TABLE bloat_test;

-- Check size after
SELECT pg_size_pretty(pg_total_relation_size('bloat_test') - pg_relation_size('bloat_test')) AS indexes_size;
```

**Expected Output:**
```
 indexes_size 
--------------
 17 MB        <-- Reduced from 44 MB!
```

---

## 📊 Summary of Results

### Bloat Creation:
- **Original size:** 28 MB
- **After 5 updates:** 140 MB (5x growth, 83% bloat)
- **Performance impact:** 4x slower queries

### VACUUM (Regular):
- **Duration:** 6 seconds
- **Table size after:** 140 MB (unchanged)
- **Dead tuples:** 0 (removed)
- **Performance:** 23% improvement
- **Benefit:** Space reusable for future inserts

### VACUUM FULL:
- **Duration:** 8 seconds
- **Table size after:** 28 MB (back to original)
- **Performance:** 76% improvement
- **Downside:** Table locked during operation

### Key Findings:

| Metric | Bloated | After VACUUM | After VACUUM FULL |
|--------|---------|--------------|-------------------|
| **Table Size** | 140 MB | 140 MB | 28 MB |
| **Dead Tuples** | 500K | 0 | 0 |
| **Seq Scan Time** | 189 ms | 145 ms | 46 ms |
| **Bloat %** | 83% | 0%* | 0% |
| **Locks Held** | None | None | Exclusive |

*Space free but not returned to OS

---

## 🎯 Key Takeaways

1. **MVCC causes bloat** - Updates create new row versions, old ones become dead
2. **VACUUM != shrink** - Marks space as reusable, doesn't reduce file size
3. **VACUUM FULL shrinks** - But requires downtime (exclusive lock)
4. **Performance degrades** - Bloat causes 4-5x slower queries
5. **Autovacuum is essential** - Prevents bloat before it becomes problem
6. **Indexes bloat too** - May need REINDEX periodically
7. **Monitor dead_tuple_pct** - Alert at >20%, remediate at >30%

---

## 🧹 Cleanup

```sql
-- Drop test database
\c postgres
DROP DATABASE vacuum_test;

-- Exit
\q
```

---

## 📝 Interview Talking Points

**"Walk me through how you handled table bloat in production"**

> "I noticed one of our high-transaction tables (orders) had grown from 50 GB to 200 GB over 6 months despite steady data volume. Investigation showed 75% bloat from frequent updates.
> 
> **Root cause:** Autovacuum was too slow - configured at 20% threshold meant it only triggered after 10M dead tuples accumulated.
> 
> **Solution:**
> 1. Tuned autovacuum to 5% threshold: `autovacuum_vacuum_scale_factor = 0.05`
> 2. Increased autovacuum workers from 3 to 6
> 3. During maintenance window, ran `VACUUM FULL` to reclaim 150 GB
> 4. Set up monitoring: alert when dead_tuple_pct > 15%
> 
> **Result:** Table stayed at 50 GB, query performance improved 60%, no more bloat issues."

---

**Next:** [Scenario 15: Autovacuum Tuning](15-autovacuum-tuning.md)
