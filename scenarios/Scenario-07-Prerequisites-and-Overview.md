# Scenario 07: Multi-Standby Setup - Complete Guide

**Date:** November 17, 2025  
**Duration:** 35-40 minutes  
**Difficulty:** Advanced

---

## 🎯 What This Scenario Tests

### The Big Question:
**"Can PostgreSQL handle multiple standby servers receiving replication from one primary?"**

### Real-World Context:

**As a MySQL DBA, you know:**
- MySQL Master → Multiple Replicas (1 master, N replicas)
- Each replica connects independently
- Replicas can lag differently
- Used for read scaling, DR, reporting

**In PostgreSQL:** Same concept, but called "standbys" instead of "replicas"

**Real-world use cases:**

**1. Read Scaling:**
```
Application Load Balancer
         ↓
    ┌────┴────┬─────────┐
    ↓         ↓         ↓
 Read1     Read2     Read3
(Standby1) (Standby2) (Standby3)
```

**2. Geographic Distribution:**
```
Primary (US-East)
    ↓
    ├──→ Standby1 (US-West)  ← Low latency for West Coast users
    ├──→ Standby2 (EU)       ← Low latency for European users
    └──→ Standby3 (Asia)     ← Low latency for Asian users
```

**3. Workload Isolation:**
```
Primary (OLTP workload - fast queries)
    ↓
    ├──→ Standby1 (Reporting - heavy analytics)
    ├──→ Standby2 (ETL - batch data exports)
    └──→ Standby3 (Development - testing queries)
```

**4. High Availability:**
```
Primary
    ↓
    ├──→ Standby1 (Hot failover candidate)
    └──→ Standby2 (Warm backup)

If Primary fails:
  → Promote Standby1 (seconds)
  → Standby2 still available as backup
```

---

## 🧪 What We'll Do

### Architecture We'll Build:

```
                    ┌─────────────────┐
                    │  PRIMARY        │
                    │  Port: 5432     │
                    │  (Read/Write)   │
                    └────────┬────────┘
                             │
                 WAL Stream  │  WAL Stream
                (Async)      │  (Async)
                    ┌────────┴────────┐
                    ↓                 ↓
        ┌──────────────────┐  ┌──────────────────┐
        │  STANDBY1        │  │  STANDBY2        │
        │  Port: 5433      │  │  Port: 5434      │
        │  (Read-Only)     │  │  (Read-Only)     │
        │  Replication     │  │  Replication     │
        │  Slot: standby   │  │  Slot: standby2  │
        └──────────────────┘  └──────────────────┘
        
Both standbys:
  • Receive same WAL from PRIMARY
  • Can lag independently
  • Can serve read queries
  • Can be promoted to primary if needed
```

### Test Flow:

```
┌─────────────────────────────────────────────────────────┐
│ PHASE 1: SETUP SECOND STANDBY (15 min)                  │
├─────────────────────────────────────────────────────────┤
│ • Add standby2 to docker-compose.yml                    │
│ • Create replication slot: standby2_slot                │
│ • Take base backup using pg_basebackup                  │
│ • Configure standby2 (standby.signal, configs)          │
│ • Start standby2 container                              │
│ • Verify connection and streaming                       │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ PHASE 2: VERIFY REPLICATION (5 min)                     │
├─────────────────────────────────────────────────────────┤
│ • Check pg_stat_replication (should show 2 rows)        │
│ • Verify both standbys in recovery mode                 │
│ • Check replication slots (2 active)                    │
│ • Verify initial data sync (row counts match)           │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ PHASE 3: TEST WRITE REPLICATION (10 min)                │
├─────────────────────────────────────────────────────────┤
│ • Insert 10,000 rows on PRIMARY                         │
│ • Monitor lag on BOTH standbys                          │
│ • Verify both received all rows                         │
│ • Compare lag between standby1 and standby2             │
│ • Check if lag differs (independent catch-up)           │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ PHASE 4: READ LOAD DISTRIBUTION (5 min)                 │
├─────────────────────────────────────────────────────────┤
│ • Run read query on standby1                            │
│ • Run read query on standby2                            │
│ • Compare performance                                   │
│ • Test round-robin read distribution                    │
└─────────────────────────────────────────────────────────┘
```

---

## 🔍 What Will Happen?

### 1. PRIMARY Sends WAL to Multiple Standbys

**Single WAL Stream → Multiple Recipients:**

```
PRIMARY generates WAL:
  INSERT INTO orders VALUES (...)
  ↓
  WAL record created: LSN 0/E000000
  ↓
  ┌─────────────────────────────┐
  │ PRIMARY sends same WAL to:  │
  ├─────────────────────────────┤
  │ → Standby1 (connection 1)   │
  │ → Standby2 (connection 2)   │
  └─────────────────────────────┘
```

**MySQL Equivalent:**
```
Master generates binary log:
  INSERT INTO orders VALUES (...)
  ↓
  Binlog event written
  ↓
  Master sends same event to:
  → Replica1 (connection 1)
  → Replica2 (connection 2)
```

### 2. Independent Replication Connections

**Each standby has its own:**
- TCP connection to primary
- Replication slot (tracks position)
- WAL receiver process
- WAL replay process
- Lag metrics (independent)

```
STANDBY1:
  Connection: Primary:5432 → Standby1:5433
  Process: walreceiver (PID 1234)
  Position: LSN 0/E000000
  Lag: 0 bytes

STANDBY2:
  Connection: Primary:5432 → Standby2:5434
  Process: walreceiver (PID 5678)
  Position: LSN 0/DFFFFF0 (slightly behind!)
  Lag: 16 KB
```

**They can lag DIFFERENTLY!**
- Standby1 might be faster (better disk)
- Standby2 might lag (slower network, busy with queries)

### 3. Resource Impact on PRIMARY

**With 1 standby:**
```
PRIMARY CPU:
  • Normal workload: 20%
  • WAL sender process: 2%
  Total: 22%

PRIMARY Network:
  • WAL streaming: 1 MB/sec (to standby1)
```

**With 2 standbys:**
```
PRIMARY CPU:
  • Normal workload: 20%
  • WAL sender 1: 2%
  • WAL sender 2: 2%
  Total: 24%

PRIMARY Network:
  • WAL streaming: 2 MB/sec (1 MB to each standby)
```

**Impact:** Minimal! Each standby adds ~2% CPU and proportional network bandwidth.

**With 10 standbys:** Would add ~20% CPU and 10 MB/sec network.

### 4. Read Load Distribution

**Before (1 standby):**
```
Application sends 1000 queries/sec
  ↓
All 1000 → Standby1 (overloaded!)
```

**After (2 standbys):**
```
Application sends 1000 queries/sec
  ↓
Load Balancer:
  • 500 queries → Standby1
  • 500 queries → Standby2
  
Result: Each handles 50% load!
```

**Benefits:**
- Lower CPU per standby
- Faster query response
- Better resource utilization
- Can handle more total read traffic

---

## 📋 Prerequisites Checklist

### ✅ 1. Scenario 06 Completed

**Why:** Need stable replication with current standby

**Check:**
- Previous scenarios 01-06 completed ✓
- Understand replication slots
- Understand pg_basebackup
- Understand streaming replication

**Status:** Should be complete from previous work ✓

---

### ✅ 2. Current Replication Healthy

**Why:** Start from known good state

**Check:**
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT application_name, state, sync_state 
FROM pg_stat_replication;"
```

**Expected:**
```
application_name | state     | sync_state
-----------------+-----------+------------
walreceiver      | streaming | async
```

**Must verify:**
- ✅ Standby1 currently connected
- ✅ State = streaming
- ✅ No lag or minimal lag

---

### ✅ 3. Sufficient Disk Space

**Why:** Need space for second standby data directory

**Check:**
```bash
df -h
```

**Requirements:**
```
Current database size: ~100 MB (estimated)
Second standby needs: ~100 MB for initial copy
WAL space: ~50 MB (for both standbys)
Total needed: ~150 MB free space

Recommended: 1 GB free space for safety
```

**Docker volumes:**
- Standby2 will need its own volume
- Will be created automatically by Docker

---

### ✅ 4. Docker Resources Available

**Why:** Running 3 PostgreSQL containers simultaneously

**Check:**
```bash
docker stats --no-stream
```

**Current usage:**
```
postgres-primary:  ~200 MB RAM
postgres-standby:  ~200 MB RAM
```

**After adding standby2:**
```
postgres-primary:  ~200 MB RAM
postgres-standby:  ~200 MB RAM (standby1)
postgres-standby2: ~200 MB RAM (new!)
Total: ~600 MB RAM
```

**Requirements:**
- RAM available: 1 GB+ free
- CPU: Not a bottleneck (3 idle containers minimal)

---

### ✅ 5. Port 5434 Available

**Why:** Standby2 will use port 5434

**Check:**
```bash
lsof -i :5434
# or
netstat -an | grep 5434
```

**Expected:** No output (port available)

**If port in use:**
- Stop other application using it
- Or choose different port (modify docker-compose.yml)

**Port mapping:**
```
PRIMARY:   localhost:5432 → container:5432
STANDBY1:  localhost:5433 → container:5432
STANDBY2:  localhost:5434 → container:5432 (new!)
```

---

### ✅ 6. Baseline Metrics Recorded

**Why:** Compare before/after adding second standby

**Check:**
```bash
# Current replication status:
docker exec postgres-primary psql -U postgres -c "
SELECT 
    COUNT(*) as standby_count,
    pg_current_wal_lsn() as current_lsn
FROM pg_stat_replication;"

# Current resource usage:
docker stats --no-stream postgres-primary
```

**Record:**
- Current standby count: 1
- Current WAL position: _____________
- Primary CPU: _____________%
- Primary memory: _____________

---

### ✅ 7. Understanding of pg_basebackup

**Why:** Will use pg_basebackup to initialize standby2

**Concepts to understand:**
- `pg_basebackup` copies entire data directory
- Must run while primary is running (online backup)
- Creates consistent snapshot
- Includes all databases, users, tables
- Does NOT include pg_wal/ directory (WAL files)

**Command we'll use:**
```bash
pg_basebackup -h primary -U replicator -D /data -Fp -Xs -P -R
```

**Parameters:**
- `-h primary` = Connect to primary server
- `-U replicator` = Use replicator user
- `-D /data` = Output directory
- `-Fp` = Plain format (not tar)
- `-Xs` = Stream WAL during backup
- `-P` = Show progress
- `-R` = Create standby.signal and configs automatically

**MySQL Equivalent:**
```bash
# MySQL backup for new replica:
mysqldump --all-databases --master-data=2 > backup.sql
# or
xtrabackup --backup --target-dir=/backup
```

---

## 🎓 Key Concepts to Understand

### 1. Multi-Standby Topology

**Star Topology (What we're building):**
```
        PRIMARY
       /   |   \
      /    |    \
   SB1   SB2   SB3

Advantages:
  ✓ Simple to understand
  ✓ Each standby gets WAL directly from primary
  ✓ Low latency (one hop)
  
Disadvantages:
  ✗ Primary handles all WAL sending (N connections)
  ✗ Network bandwidth from primary × N
```

**Cascading Topology (Alternative):**
```
    PRIMARY
       ↓
     SB1
    /   \
  SB2   SB3

Advantages:
  ✓ Reduces load on primary (only 1 connection)
  ✓ Reduces primary network bandwidth
  ✓ Scales better (100s of standbys possible)
  
Disadvantages:
  ✗ Higher latency (two hops: Primary→SB1→SB2)
  ✗ SB1 becomes bottleneck
  ✗ If SB1 fails, SB2 and SB3 stop receiving WAL
```

**MySQL Comparison:**
```
MySQL Multi-Source Replication:
  Master → Replica1
        → Replica2
        → Replica3

MySQL Chain Replication:
  Master → Replica1 → Replica2
```

---

### 2. Replication Slots for Each Standby

**Why each standby needs its own slot:**

```
Without slots:
  PRIMARY: "I'm at LSN 0/F000000"
  Standby1: "I need LSN 0/E000000" (lagging)
  PRIMARY: "Sorry, I deleted that WAL already!" ❌
  
With slots:
  Standby1 slot: restart_lsn = 0/E000000
  Standby2 slot: restart_lsn = 0/E500000
  PRIMARY: "I'll keep WAL from 0/E000000 (earliest slot)" ✓
```

**Slot tracking:**
```sql
SELECT 
    slot_name,
    restart_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;

Result:
slot_name    | restart_lsn | retained
-------------+-------------+----------
standby_slot | 0/E000000   | 16 MB    ← Standby1 lagging
standby2_slot| 0/EF00000   | 1 MB     ← Standby2 almost caught up
```

**PRIMARY retains WAL from EARLIEST slot** (0/E000000 in this case)

**MySQL Equivalent:**
```sql
-- MySQL doesn't have replication slots
-- Must manually configure:
SET GLOBAL binlog_expire_logs_seconds = 259200; -- 3 days

-- Risk: If replica offline > 3 days, binlogs purged!
-- PostgreSQL slots = automatic retention ✓
```

---

### 3. Independent Lag Metrics

**Each standby tracks lag separately:**

```sql
SELECT 
    application_name,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;

Result:
application_name | lag_bytes | replay_lag
-----------------+-----------+------------
walreceiver      | 0         | 00:00:00    ← Standby1 (fast)
walreceiver2     | 16384     | 00:00:02    ← Standby2 (lagging)
```

**Why lag differs:**

**Hardware differences:**
- Standby1: SSD (fast replay)
- Standby2: HDD (slower replay)

**Load differences:**
- Standby1: Idle (only replication)
- Standby2: Running heavy query (CPU busy, slow replay)

**Network differences:**
- Standby1: Same datacenter (1ms latency)
- Standby2: Remote datacenter (50ms latency)

**This is NORMAL and EXPECTED!**

---

### 4. Read Load Balancing

**Simple Round-Robin:**
```
Query 1 → Standby1
Query 2 → Standby2
Query 3 → Standby1
Query 4 → Standby2
...
```

**Least-Connections:**
```
Standby1: 50 active connections → Send query to Standby2
Standby2: 20 active connections → Send query here ✓
```

**Lag-Aware:**
```
Standby1: 0 bytes lag → Send query here ✓
Standby2: 10 MB lag   → Skip (too far behind)
```

**Geographic:**
```
User in US-East  → Route to Standby1 (US-East)
User in US-West  → Route to Standby2 (US-West)
User in Europe   → Route to Standby3 (EU)
```

**Application-level (connection string):**
```python
# Python example:
import random
standbys = ['localhost:5433', 'localhost:5434']
conn = psycopg2.connect(host=random.choice(standbys), ...)
```

**Load balancer (HAProxy, pgpool-II):**
```
Application → HAProxy (localhost:5432)
              ↓
              ├─→ Standby1 (50% traffic)
              └─→ Standby2 (50% traffic)
```

---

### 5. Failover with Multiple Standbys

**Scenario: Primary fails**

```
Before:
  PRIMARY (failed!) ×
     ↓
     ├──→ Standby1 (0 bytes lag)
     └──→ Standby2 (100 KB lag)

Decision: Promote Standby1 (less lag = more data)

After promotion:
  PRIMARY (was Standby1) ✓
     ↓
     └──→ Standby2 (reconnects to new primary)

Standby2 must:
  1. Follow new primary timeline
  2. Update primary_conninfo to point to Standby1
  3. Continue replication
```

**PostgreSQL timeline handling:**
```
Timeline 1: Original primary (before failover)
Timeline 2: Standby1 promoted (after failover)

Standby2 will follow timeline 2 automatically!
```

**MySQL Comparison:**
```sql
-- MySQL failover with multiple replicas:
-- Promote Replica1:
STOP SLAVE;
RESET MASTER;
-- Replica1 is now master

-- Reconfigure Replica2:
STOP SLAVE;
CHANGE MASTER TO MASTER_HOST='replica1', ...;
START SLAVE;
```

---

## 🚨 Important Notes

### 1. Resource Requirements Scale Linearly

**With N standbys:**
- PRIMARY CPU: +2% per standby (~24% with 2 standbys)
- PRIMARY Network: +(WAL rate) per standby (~2 MB/sec per standby)
- PRIMARY Memory: Minimal increase (~10 MB per connection)

**Practical limits:**
- **Small deployments:** 2-5 standbys (typical)
- **Medium deployments:** 5-10 standbys (requires monitoring)
- **Large deployments:** 10-20 standbys (use cascading)
- **Extreme:** 100+ standbys (use cascading replication)

---

### 2. WAL Retention Critical

**With multiple standbys:**
- PRIMARY retains WAL from SLOWEST standby
- If one standby lags badly, WAL accumulates
- Disk can fill up!

**Monitor:**
```sql
SELECT 
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots
ORDER BY restart_lsn;

-- If any standby shows > 1 GB retained: INVESTIGATE!
```

**Fix slow standby:**
- Upgrade hardware
- Reduce query load
- Move to cascading replication
- Drop slot and rebuild (last resort)

---

### 3. All Standbys Are Async (For Now)

**In this scenario:**
- Both standbys use async replication
- Primary doesn't wait for either standby
- Fast commits, but data loss risk if primary crashes

**In Scenario 08:**
- We'll configure synchronous replication
- Primary waits for at least 1 standby
- Slower commits, but zero data loss guarantee

---

### 4. Network Bandwidth Planning

**Calculate bandwidth needed:**
```
Average WAL rate: 10 MB/sec
Number of standbys: 2
Total bandwidth: 10 × 2 = 20 MB/sec = 160 Mbps

For 10 standbys: 100 MB/sec = 800 Mbps
For 100 standbys: 1 GB/sec = 8 Gbps ← Need cascading!
```

**Our Docker setup:** Localhost (no bandwidth limits)

**Production:** Ensure network can handle N × WAL rate

---

## 📊 Success Criteria

After completing Scenario 07, you should see:

### ✅ 1. Second Standby Running
- postgres-standby2 container up
- Listening on port 5434
- Data directory initialized

### ✅ 2. Both Standbys Connected
```sql
SELECT COUNT(*) FROM pg_stat_replication;
-- Should return: 2
```

### ✅ 3. Both Slots Active
```sql
SELECT COUNT(*) FROM pg_replication_slots WHERE active = true;
-- Should return: 2
```

### ✅ 4. Data Replicated to Both
```sql
-- PRIMARY:
SELECT COUNT(*) FROM orders;
-- STANDBY1:
SELECT COUNT(*) FROM orders;
-- STANDBY2:
SELECT COUNT(*) FROM orders;
-- All should match!
```

### ✅ 5. Both Can Serve Reads
- Connect to standby2:5434
- Run SELECT query successfully
- Verify read-only (INSERT fails)

### ✅ 6. Independent Lag Tracking
- Can monitor each standby separately
- Lag may differ between standbys
- Both eventually catch up

---

## 🎬 Ready to Start!

**Prerequisites understood:**
- ✅ What multi-standby topology is
- ✅ Why each standby needs its own slot
- ✅ How to use pg_basebackup
- ✅ How independent lag works
- ✅ How read load distribution benefits

**What we'll build:**
```
PRIMARY:5432 (Read/Write)
  ├──→ STANDBY1:5433 (Read-Only)
  └──→ STANDBY2:5434 (Read-Only)
```

**Next step:** Modify docker-compose.yml to add standby2!

---

*Prerequisites document created: November 17, 2025*  
*Ready for Scenario 07: Multi-Standby Setup execution*
