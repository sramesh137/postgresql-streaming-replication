# Scenario 06: Heavy Write Load - Complete Guide

**Date:** November 17, 2025  
**Duration:** 25-30 minutes  
**Difficulty:** Intermediate

---

## 🎯 What This Scenario Tests

### The Big Question:
**"How does replication behave under sustained heavy write pressure?"**

### Real-World Context:
Imagine you're a MySQL DBA and your application suddenly experiences:
- Black Friday sales spike (1000s of orders/second)
- Batch job inserting millions of rows
- Data migration from old system
- Heavy reporting queries generating temp tables

**In MySQL:** You'd worry about:
- Binary log size explosion
- Replica lag growing
- `Seconds_Behind_Master` increasing
- Disk space filling up
- Replica falling too far behind

**In PostgreSQL:** We'll test the same concerns:
- WAL generation rate
- Replication lag behavior
- Standby catch-up capability
- Resource utilization
- At what point does replication break?

---

## 🧪 What Will We Do?

### Test Scenario Flow:

```
┌─────────────────────────────────────────────────────────┐
│ PHASE 1: BASELINE (5 min)                               │
├─────────────────────────────────────────────────────────┤
│ • Record starting WAL position                          │
│ • Verify zero lag                                       │
│ • Check resource usage (CPU, memory, disk)              │
│ • Establish normal operation metrics                    │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ PHASE 2: HEAVY WRITE LOAD (10-15 min)                   │
├─────────────────────────────────────────────────────────┤
│ • Insert 50,000 rows in tight loop                      │
│ • Monitor WAL generation in real-time                   │
│ • Watch lag increase during writes                      │
│ • Measure write rate (rows/second)                      │
│ • Track WAL file creation                               │
│                                                          │
│ Expected Results:                                        │
│   - ~5,000-10,000 rows/second write rate                │
│   - ~10-20 MB WAL generated                             │
│   - Lag may reach 100KB - 10MB temporarily              │
│   - Standby stays connected (streaming continues)       │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ PHASE 3: MONITORING UNDER LOAD (5 min)                  │
├─────────────────────────────────────────────────────────┤
│ • Real-time lag monitoring (refresh every 1 second)     │
│ • WAL position tracking                                 │
│ • Replay lag vs write lag difference                    │
│ • Network throughput (MB/sec streaming)                 │
│ • Standby I/O load (WAL replay speed)                   │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ PHASE 4: CATCH-UP & RECOVERY (5 min)                    │
├─────────────────────────────────────────────────────────┤
│ • Wait for writes to complete                           │
│ • Watch lag decrease to zero                            │
│ • Measure catch-up time                                 │
│ • Verify data consistency                               │
│ • Compare row counts                                    │
│                                                          │
│ Expected Results:                                        │
│   - Lag returns to 0 bytes within 5-30 seconds          │
│   - No data loss                                        │
│   - Row counts match                                    │
│   - Replication continues normally                      │
└─────────────────────────────────────────────────────────┘
```

---

## 🔍 What Will Happen?

### During Heavy Writes on Primary:

**1. WAL Generation Increases:**
```
Normal operation:  ~1-2 MB/hour
During heavy load: ~10-20 MB in 10 seconds!
```

**2. Standby Tries to Keep Up:**
```
Primary: Writing 10,000 rows/second → Generating WAL
          ↓
Network: Streaming WAL segments (max: 16 MB each)
          ↓
Standby: Receiving WAL → Replaying transactions
```

**3. Lag May Appear:**
```
If Primary writes faster than Standby can replay:
  → Lag increases (bytes behind)
  → replay_lag increases (time delay)
  
If Standby keeps up:
  → Lag stays near zero
  → Real-time replication maintained
```

**4. Resource Utilization:**
```
PRIMARY:
  • CPU: High (processing INSERTs)
  • Memory: Transaction buffers
  • Disk I/O: Writing data + WAL
  • Network: Sending WAL to standby

STANDBY:
  • CPU: High (replaying WAL)
  • Memory: Replay buffers
  • Disk I/O: Writing replayed data
  • Network: Receiving WAL stream
```

---

## 📋 Prerequisites Checklist

### ✅ 1. Previous Scenarios Complete
**Why:** Builds on concepts from Scenarios 01-05

**Check:**
```bash
# You should understand:
# - Replication lag (Scenario 01)
# - Read distribution (Scenario 02)
# - Failover process (Scenario 04)
# - Network interruption (Scenario 05)
```

**Status:** Should have completed Scenarios 01-05 ✓

---

### ✅ 2. Containers Running and Healthy

**Why:** Need both servers operational for load testing

**Check:**
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep postgres
```

**Expected Output:**
```
postgres-primary   Up X hours (healthy)   0.0.0.0:5432->5432/tcp
postgres-standby   Up X hours (healthy)   0.0.0.0:5433->5432/tcp
```

**Troubleshooting:**
- If containers down: `docker-compose up -d`
- If unhealthy: Check logs with `docker logs postgres-primary`

**MySQL Equivalent:**
```sql
-- Check MySQL servers running:
SHOW PROCESSLIST;
SELECT @@hostname, @@port;
```

---

### ✅ 3. Replication Active and Streaming

**Why:** Must start from healthy replication state

**Check:**
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    state,
    sync_state,
    replay_lag
FROM pg_stat_replication;"
```

**Expected Output:**
```
application_name | state     | sync_state | replay_lag
-----------------+-----------+------------+------------
walreceiver      | streaming | async      | 00:00:00
```

**What to verify:**
- ✅ `state = 'streaming'` (actively connected)
- ✅ `sync_state = 'async'` (asynchronous mode)
- ✅ `replay_lag` near zero (caught up)

**Troubleshooting:**
- If no rows: Standby not connected (check `docker logs postgres-standby`)
- If `state = 'catchup'`: Standby still replaying old WAL (wait for streaming)
- If `replay_lag` high: Wait for standby to catch up before starting

**MySQL Equivalent:**
```sql
-- Check replica status:
SHOW SLAVE STATUS\G
-- Look for:
--   Slave_IO_Running: Yes
--   Slave_SQL_Running: Yes
--   Seconds_Behind_Master: 0
```

---

### ✅ 4. Zero or Minimal Replication Lag

**Why:** Start from synchronized state to measure impact accurately

**Check:**
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;"
```

**Expected Output:**
```
application_name | lag_bytes | replay_lag
-----------------+-----------+------------
walreceiver      | 0 bytes   | 00:00:00
```

**Acceptable range:**
- ✅ `0 bytes` - Perfect (ideal)
- ✅ `< 1 MB` - Acceptable
- ⚠️ `> 10 MB` - Wait before starting scenario

**Troubleshooting:**
- If lag high: Wait 1-2 minutes and check again
- If lag not decreasing: Check standby CPU/disk (may be slow)

**MySQL Equivalent:**
```sql
SHOW SLAVE STATUS\G
-- Seconds_Behind_Master: 0 (ideal)
```

---

### ✅ 5. Test Table Exists (orders table)

**Why:** Scenario inserts into `orders` table

**Check:**
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT COUNT(*) as current_rows 
FROM orders;"
```

**Expected Output:**
```
current_rows
-------------
      10000 (or similar from previous scenarios)
```

**If table doesn't exist:**
```bash
docker exec postgres-primary psql -U postgres << 'EOF'
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    product VARCHAR(255) NOT NULL,
    amount NUMERIC(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);
EOF
```

**Verify on standby too:**
```bash
docker exec postgres-standby psql -U postgres -c "
SELECT COUNT(*) FROM orders;"
```

**MySQL Equivalent:**
```sql
-- Create orders table:
CREATE TABLE orders (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    product VARCHAR(255) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

### ✅ 6. Sufficient Disk Space

**Why:** Heavy writes generate lots of WAL (10-20 MB), need headroom

**Check:**
```bash
# Check primary disk space:
docker exec postgres-primary df -h /var/lib/postgresql/data

# Check standby disk space:
docker exec postgres-standby df -h /var/lib/postgresql/data
```

**Expected Output:**
```
Filesystem      Size  Used Avail Use% Mounted on
overlay         100G   10G   90G  10% /var/lib/postgresql/data
```

**Requirements:**
- ✅ `> 1 GB free` - Safe
- ⚠️ `< 500 MB free` - Risky (may fill up)
- ❌ `< 100 MB free` - Dangerous (stop and clean up!)

**What to monitor:**
- `/pg_wal/` directory (WAL segments, 16 MB each)
- Base tables growing from INSERT statements
- Temporary files from queries

**Troubleshooting if low space:**
```bash
# Find large files:
docker exec postgres-primary du -sh /var/lib/postgresql/data/* | sort -h

# Remove old WAL (careful!):
# Only if replication slot not retaining them
docker exec postgres-primary pg_archivecleanup /var/lib/postgresql/data/pg_wal/ 000000010000000000000001
```

**MySQL Equivalent:**
```bash
# Check MySQL disk space:
df -h /var/lib/mysql

# Check binary log size:
ls -lh /var/lib/mysql/mysql-bin.*
```

---

### ✅ 7. Replication Slot Active

**Why:** Protects WAL during heavy writes, prevents deletion

**Check:**
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    slot_name,
    slot_type,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;"
```

**Expected Output:**
```
slot_name    | slot_type | active | retained_wal
-------------+-----------+--------+--------------
standby_slot | physical  | t      | 0 bytes
```

**What to verify:**
- ✅ `active = 't'` (standby connected via slot)
- ✅ `retained_wal = '0 bytes'` (caught up)
- ✅ `slot_type = 'physical'` (correct type)

**Why this matters:**
During heavy load, if standby disconnects briefly:
- Slot retains WAL so standby can catch up
- Without slot: WAL deleted → standby rebuild needed!

**Troubleshooting:**
```bash
# If slot missing, create it:
docker exec postgres-primary psql -U postgres -c "
SELECT pg_create_physical_replication_slot('standby_slot');"

# Then restart standby:
docker restart postgres-standby
```

**MySQL Equivalent:**
```sql
-- Check binary log retention:
SHOW VARIABLES LIKE 'binlog_expire_logs_seconds';
-- Should be > 0 to retain logs for replica

-- Check current binlog position:
SHOW MASTER STATUS;
```

---

### ✅ 8. Baseline WAL Position Recorded

**Why:** Need starting point to measure WAL generated during load

**Check:**
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    pg_current_wal_lsn() AS current_position,
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file
FROM pg_stat_replication;"
```

**Expected Output:**
```
current_position | current_wal_file
-----------------+---------------------------
0/E579938        | 000000030000000000000E
```

**Record these values:**
- Starting LSN: `_________________`
- Starting WAL file: `_________________`
- Time: `_________________`

**Why record this:**
- Calculate total WAL generated: `current_lsn - start_lsn`
- Count WAL files created
- Measure time to generate X MB of WAL
- Capacity planning (project future needs)

**MySQL Equivalent:**
```sql
-- Record starting binlog position:
SHOW MASTER STATUS;
-- File: mysql-bin.000123
-- Position: 456789

-- Later, calculate bytes generated:
-- New Position - Old Position = Bytes generated
```

---

## 🎓 Key Concepts to Understand

### 1. WAL Generation Rate

**What is WAL generation rate?**
```
WAL Generation Rate = MB of WAL generated / Time period

Example:
  - Insert 50,000 rows in 10 seconds
  - Generates 15 MB of WAL
  - Rate: 15 MB / 10 sec = 1.5 MB/second
```

**Why it matters:**
- Network bandwidth planning (standby must receive this rate)
- Disk I/O capacity (standby must write/replay at this rate)
- Storage planning (how much WAL retained in slots)
- Alert thresholds (when to worry about lag)

**MySQL Equivalent:**
```sql
-- Binary log generation:
-- Check binlog size growth over time:
SELECT 
    log_name, 
    file_size 
FROM mysql.general_log 
ORDER BY log_name;

-- In MySQL 8.0:
SELECT @@binlog_transaction_dependency_tracking;
```

---

### 2. Replication Lag Types

**PostgreSQL has multiple lag metrics:**

**A) Byte Lag (sent_lsn - replay_lsn):**
```sql
SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn) AS byte_lag
FROM pg_stat_replication;
```
- Measures: Bytes not yet replayed on standby
- **During heavy load:** Can be 1-10 MB
- **Normal operation:** Usually 0 bytes

**B) Time Lag (replay_lag):**
```sql
SELECT replay_lag FROM pg_stat_replication;
```
- Measures: Time delay between primary and standby
- **During heavy load:** Can be 1-30 seconds
- **Normal operation:** Usually < 1 second

**C) Write Lag vs Replay Lag:**
```
write_lag:  Time for standby to RECEIVE WAL
replay_lag: Time for standby to APPLY WAL

replay_lag > write_lag means:
  → Standby receiving WAL fast
  → But slow at replaying it (CPU/disk bottleneck)
```

**MySQL Equivalent:**
```sql
SHOW SLAVE STATUS\G

-- Key metrics:
Seconds_Behind_Master: 5    ← Time lag (similar to replay_lag)
Relay_Log_Space: 5242880    ← Bytes lag (relay logs not applied)
```

---

### 3. Why Lag Happens Under Load

**The bottleneck chain:**

```
PRIMARY:
┌──────────────────────┐
│ Application          │
│ INSERT 10K rows/sec  │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Write to disk        │  ← Fast (buffered writes)
│ Generate WAL         │  ← Fast (sequential writes)
└──────────┬───────────┘
           │
           ▼ (Network streaming)
           
STANDBY:
┌──────────────────────┐
│ Receive WAL          │  ← Fast (network speed)
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Replay WAL           │  ← SLOWER (must apply transactions)
│ Write to disk        │  ← BOTTLENECK (random writes)
│ Update indexes       │  ← BOTTLENECK (CPU intensive)
└──────────────────────┘
```

**Why standby is slower:**
1. **Primary benefits from batching:**
   - Application inserts in transactions
   - Database groups commits
   - Writes multiple rows at once

2. **Standby must replay sequentially:**
   - Replays WAL records one by one
   - Cannot batch as efficiently
   - Single-threaded replay (PostgreSQL < 14)

3. **Disk I/O pattern difference:**
   - Primary: Buffered, cached, batched writes
   - Standby: Must physically write to catch up

**MySQL Similar Issue:**
```
Master writes: Multi-threaded (parallel INSERTs)
Replica applies: Single-threaded (until MySQL 5.7+)
Result: Replica can lag behind busy master
```

**PostgreSQL 14+ Improvement:**
- Parallel WAL replay for some operations
- Better catch-up performance
- Still single-threaded for most operations

---

### 4. Acceptable Lag Thresholds

**Production guidelines:**

```
┌─────────────────┬──────────────┬─────────────────────────┐
│ Lag Level       │ Byte Lag     │ Time Lag (replay_lag)   │
├─────────────────┼──────────────┼─────────────────────────┤
│ ✅ Excellent    │ < 100 KB     │ < 1 second              │
│ ✅ Good         │ < 1 MB       │ < 5 seconds             │
│ ⚠️  Acceptable  │ < 10 MB      │ < 30 seconds            │
│ ⚠️  Warning     │ < 100 MB     │ < 5 minutes             │
│ ❌ Critical     │ > 100 MB     │ > 5 minutes             │
└─────────────────┴──────────────┴─────────────────────────┘
```

**During heavy load (this scenario):**
- Expect lag to spike temporarily (1-10 MB)
- Should recover to 0 within 30 seconds after load stops
- If lag keeps growing: Standby can't keep up (upgrade hardware!)

**When to worry:**
- Lag continuously increases (never catches up)
- Lag > 100 MB (may indicate standby problems)
- Time to catch up > Write duration (falling further behind)

**MySQL Equivalent:**
```sql
-- Monitor Seconds_Behind_Master:
-- < 5 seconds:  Good
-- < 30 seconds: Acceptable
-- > 60 seconds: Warning
-- > 300 seconds: Critical (need investigation)
```

---

### 5. Resource Monitoring

**What to watch during heavy load:**

**PRIMARY:**
```bash
# CPU usage:
docker stats postgres-primary --no-stream

# Disk I/O:
docker exec postgres-primary iostat -x 1 3

# WAL rate:
SELECT pg_current_wal_lsn(); # Check every second, calculate diff
```

**STANDBY:**
```bash
# CPU usage (WAL replay):
docker stats postgres-standby --no-stream

# Disk I/O (writing replayed data):
docker exec postgres-standby iostat -x 1 3

# Lag metrics:
SELECT replay_lag FROM pg_stat_replication;
```

**Network:**
```bash
# Network traffic (WAL streaming):
docker exec postgres-primary iftop -i eth0
```

**What's normal during heavy load:**
- PRIMARY CPU: 50-80% (processing INSERTs)
- STANDBY CPU: 40-70% (replaying WAL)
- Network: 1-5 MB/second (WAL streaming)
- Disk I/O: High on both (writing data)

**MySQL Equivalent:**
```bash
# Monitor MySQL master:
mysqladmin -u root -p processlist
SHOW ENGINE INNODB STATUS;

# Monitor replica:
SHOW SLAVE STATUS\G
# Watch: Seconds_Behind_Master, Relay_Log_Space
```

---

## 🚨 Important Notes

### 1. This is ASYNC Replication

**What async means:**
```
PRIMARY commits transaction
          ↓
Returns SUCCESS to application  ← BEFORE standby confirms!
          ↓
Streams WAL to standby (in background)
          ↓
Standby replays (eventually)
```

**Implication during heavy load:**
- Primary performance NOT affected by standby lag
- Primary continues accepting writes even if standby slow
- **But:** If primary crashes during lag, standby missing recent transactions!

**Scenario example:**
```
1. Insert 10,000 rows on primary (commits successfully)
2. Standby has 5 MB lag (hasn't replayed yet)
3. Primary server crashes
4. Failover to standby → LOST 5 MB of transactions! ❌
```

**MySQL Similar Behavior:**
- Asynchronous replication: Master doesn't wait for replica
- Semi-sync replication: Master waits for 1 replica ACK
- Group replication: Majority consensus required

**We'll explore sync replication in Scenario 08!**

---

### 2. Disk Space Risk

**During heavy load:**
- Primary generates WAL rapidly (1-2 MB/second)
- If standby disconnects, replication slot retains ALL WAL
- WAL can accumulate and fill disk!

**Warning signs:**
```bash
# Check WAL size retained:
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
FROM pg_replication_slots;

# If > 500 MB: Investigate why standby not catching up!
```

**Emergency response:**
```bash
# If disk filling up, options:

# Option 1: Reconnect standby (best)
docker start postgres-standby

# Option 2: Drop slot (lose standby, rebuild later)
SELECT pg_drop_replication_slot('standby_slot');

# Option 3: Add more disk space
# (depends on your environment)
```

**MySQL Equivalent:**
```sql
-- Binary log accumulation:
SHOW BINARY LOGS;  -- Check how many binlogs retained

-- Purge old binlogs (careful!):
PURGE BINARY LOGS BEFORE '2025-11-16 12:00:00';
```

---

### 3. Write Rate Expectations

**Our test:** Insert 50,000 rows

**Expected performance:**
```
Docker on Mac/Windows: 5,000-10,000 rows/sec
Docker on Linux:       10,000-20,000 rows/sec
Bare metal:            20,000-50,000+ rows/sec
```

**Factors affecting speed:**
- CPU speed (transaction processing)
- Disk speed (writing data + WAL)
- Docker overhead (virtualization)
- Table indexes (more indexes = slower INSERTs)
- Concurrent load (other queries running)

**Don't worry if your numbers differ!**
- This is a learning exercise, not a benchmark
- Focus on understanding the BEHAVIOR, not absolute numbers
- Production will have different hardware anyway

---

### 4. Real-Time Monitoring

**During the scenario, we'll use `watch` command:**

```bash
watch -n 1 "docker exec postgres-primary psql -U postgres -t -c \"
SELECT 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
    replay_lag
FROM pg_stat_replication;
\""
```

**This refreshes every 1 second, showing:**
- Current lag in bytes
- Current lag in time
- Real-time updates as load progresses

**You'll see:**
```
Lag starts: 0 bytes
Load begins: Lag increases (100 KB → 1 MB → 5 MB)
Load ends: Lag decreases (5 MB → 1 MB → 100 KB → 0 bytes)
```

**To stop monitoring:** Press `Ctrl+C`

**MySQL Equivalent:**
```bash
# Monitor replica lag:
watch -n 1 "mysql -u root -p -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind"
```

---

## 📊 Success Criteria

After completing Scenario 06, you should see:

### ✅ 1. Load Completed Successfully
- 50,000 rows inserted on primary
- No errors during insert loop
- Write rate calculated (rows/second)

### ✅ 2. WAL Generated and Measured
- Total WAL generated: ~10-20 MB
- WAL generation rate: ~1-2 MB/second
- Number of WAL files created: 1-2 files

### ✅ 3. Replication Stayed Active
- Standby remained connected throughout
- No "connection lost" errors
- Streaming continued during entire load

### ✅ 4. Lag Behaved Predictably
- Lag increased during heavy writes (expected)
- Lag peaked at reasonable level (< 50 MB)
- Lag returned to 0 after load finished

### ✅ 5. Standby Caught Up
- Final lag: 0 bytes
- Catch-up time: < 1 minute
- No permanent lag remaining

### ✅ 6. Data Consistency Verified
- Row counts match on primary and standby
- Both servers have exactly 50,000 new rows
- No data loss or corruption

---

## 🎬 Ready to Start!

**All prerequisites understood:**
- ✅ What scenario tests (replication under heavy load)
- ✅ What will happen (lag spike, then catch-up)
- ✅ What to check beforehand (7-point checklist)
- ✅ What to monitor during (lag, WAL rate, resources)
- ✅ What success looks like (caught up, no data loss)

**Key differences from MySQL:**
- PostgreSQL: WAL streaming (continuous)
- MySQL: Binary log shipping (file-based)
- PostgreSQL: Replication slots (automatic retention)
- MySQL: Manual binary log retention policy
- PostgreSQL: Physical replication (byte-level)
- MySQL: Logical replication (SQL statement level)

**Next step:** Run pre-flight checks to verify your system is ready!

---

*Prerequisites document created: November 17, 2025*  
*Ready for Scenario 06: Heavy Write Load execution*
