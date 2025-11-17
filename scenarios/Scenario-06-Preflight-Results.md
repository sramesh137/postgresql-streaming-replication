# Scenario 06 Pre-Flight Check Results

**Date:** November 17, 2025  
**Time:** 13:22 UTC  
**Status:** ✅ ALL CHECKS PASSED - READY FOR HEAVY LOAD TEST!

---

## ✅ Pre-Flight Checklist Results

| Check | Status | Details |
|-------|--------|---------|
| **1. Containers Running** | ✅ PASS | Primary: Up 26 hours, Standby: Up 18 minutes |
| **2. Replication Active** | ✅ PASS | State: streaming, Sync: async |
| **3. Zero Lag** | ✅ PASS | 0 bytes lag, replay_lag: minimal |
| **4. Orders Table** | ✅ PASS | Table exists, current rows: 4 |
| **5. Replication Slot** | ✅ PASS | standby_slot: physical, active, 0 bytes retained |
| **6. Disk Space** | ✅ PASS | Both servers: 51 GB available (91% free) |
| **7. Baseline Recorded** | ✅ PASS | LSN: 0/E579A20, WAL file: 00000003000000000000000E |

---

## 📊 Baseline Metrics (Before Heavy Load)

### Replication Status:
```
Application: walreceiver
State: streaming ✓
Sync Mode: async ✓
Lag: 0 bytes ✓
Replay Lag: minimal ✓
```

### Current Data:
```
Orders table rows: 4
(Will insert 50,000 more rows during heavy load test)
```

### Replication Slot:
```
Slot Name: standby_slot
Type: physical ✓
Active: true ✓
Retained WAL: 0 bytes ✓
```

### Disk Space:
```
PRIMARY:  51 GB available (91% free) ✓
STANDBY:  51 GB available (91% free) ✓

Note: Plenty of space for WAL accumulation!
Expected WAL generation: ~10-20 MB (no risk)
```

### Baseline WAL Position:
```
Starting LSN:      0/E579A20
Starting WAL File: 00000003000000000000000E
Baseline Time:     2025-11-17 13:22:32 UTC

📝 Record this for comparison after heavy load!
   We'll measure: Final LSN - Starting LSN = Total WAL generated
```

---

## 🎯 What Scenario 06 Will Test

### The Core Question:
**"How does PostgreSQL replication perform under sustained heavy write pressure?"**

Think of it like this (MySQL DBA perspective):

**MySQL Scenario:**
```
Your e-commerce site during Black Friday:
- 10,000 orders per second flooding in
- Binary logs growing rapidly
- Replica lag showing "Seconds_Behind_Master: 45"
- You're worried: Will replica keep up? Should we add more replicas?
```

**PostgreSQL Equivalent (What we'll test):**
```
┌────────────────────────────────────────────────────────┐
│ PHASE 1: BASELINE (Done! ✓)                           │
│ • Starting position: LSN 0/E579A20                    │
│ • Current rows: 4                                     │
│ • Lag: 0 bytes                                        │
└────────────────────────────────────────────────────────┘
                        ↓
┌────────────────────────────────────────────────────────┐
│ PHASE 2: HEAVY WRITE LOAD (Next!)                     │
│ • Insert 50,000 rows in tight loop                    │
│ • Expected: 5,000-10,000 rows/second                  │
│ • Expected WAL: ~10-20 MB                             │
│ • Duration: ~5-10 seconds                             │
│                                                        │
│ What happens on PRIMARY:                              │
│   ✓ Processes INSERTs                                │
│   ✓ Generates WAL continuously                        │
│   ✓ Streams WAL to standby                           │
│   ✓ Performance NOT impacted by standby lag          │
│                                                        │
│ What happens on STANDBY:                              │
│   • Receives WAL stream                               │
│   • Tries to replay in real-time                      │
│   • May fall behind (lag increases)                   │
│   • Lag expected: 100 KB to 10 MB temporarily        │
└────────────────────────────────────────────────────────┘
                        ↓
┌────────────────────────────────────────────────────────┐
│ PHASE 3: REAL-TIME MONITORING                         │
│ • Watch lag grow and shrink (1-second refresh)        │
│ • Monitor WAL generation rate                         │
│ • Track standby replay speed                          │
│ • Observe resource utilization                        │
└────────────────────────────────────────────────────────┘
                        ↓
┌────────────────────────────────────────────────────────┐
│ PHASE 4: CATCH-UP & VERIFICATION                      │
│ • Wait for lag to return to 0 bytes                   │
│ • Measure catch-up time                               │
│ • Calculate total WAL generated                       │
│ • Verify row counts match (both have 50,004 rows)     │
│ • Confirm no data loss                                │
└────────────────────────────────────────────────────────┘
```

---

## 🔬 What You'll Learn

### 1. **Replication Lag Behavior**
**Question:** Does lag spike during heavy writes?  
**Answer:** Yes! Standby may temporarily lag by MB during burst writes.

**Why it happens:**
```
PRIMARY writes:  10,000 rows/sec → Generates 2 MB/sec WAL
                 ↓
STANDBY replays: 8,000 rows/sec → Can only apply 1.6 MB/sec
                 ↓
Result: Lag grows by 0.4 MB/sec during load
```

**MySQL Comparison:**
```sql
-- During heavy load on MySQL master:
SHOW SLAVE STATUS\G
Seconds_Behind_Master: 30  ← Replica lagging behind

-- In PostgreSQL:
SELECT replay_lag FROM pg_stat_replication;
replay_lag: 00:00:15  ← Similar concept, different measurement
```

---

### 2. **WAL Generation Rate**
**Question:** How much WAL does heavy load generate?  
**Answer:** ~200-400 KB per 1,000 rows (depends on row size).

**Our test:**
```
Insert 50,000 rows
Expected WAL: 10-20 MB
Rate: 1-2 MB/second

Calculation:
  50,000 rows × 200 bytes/row = 10 MB WAL (approx)
```

**Why this matters:**
- **Network bandwidth:** Standby must receive 1-2 MB/sec
- **Disk space:** Replication slot retains WAL if standby disconnects
- **Capacity planning:** Project future growth (1M rows = 200 MB WAL)

**MySQL Comparison:**
```sql
-- Check binary log size:
SHOW BINARY LOGS;

mysql-bin.000123 | 15728640  ← 15 MB binlog
-- Similar size to PostgreSQL WAL for same data!
```

---

### 3. **Standby Catch-Up Capability**
**Question:** How fast can standby catch up after falling behind?  
**Answer:** Typically 1-5 MB/second (depends on hardware).

**Test scenario:**
```
1. Heavy load creates 10 MB lag
2. Load stops
3. Standby catches up:
   - 10 MB ÷ 2 MB/sec = 5 seconds to catch up ✓
```

**Real-world implications:**
```
If standby offline for 1 hour:
  - Light load (1 MB/hour): 1 MB accumulated → 0.5 sec catch-up ✓
  - Heavy load (100 MB/hour): 100 MB accumulated → 50 sec catch-up ⚠️
  - Extreme load (1 GB/hour): 1 GB accumulated → 8-10 min catch-up ⚠️
```

**MySQL Comparison:**
```sql
-- Replica catch-up speed:
-- Depends on:
--   1. Binary log size accumulated
--   2. SQL thread speed (single-threaded in MySQL < 5.7)
--   3. Disk I/O speed on replica

-- Monitor catch-up:
SHOW SLAVE STATUS\G
Relay_Log_Space: 10485760  ← 10 MB to replay
Seconds_Behind_Master: 30  ← Gradually decreases
```

---

### 4. **Resource Utilization**
**Question:** How does heavy load affect CPU, memory, disk?  
**Answer:** CPU spikes on both, disk I/O increases significantly.

**Expected resource usage:**

**PRIMARY during heavy load:**
```
CPU:     50-80% (processing INSERTs, generating WAL)
Memory:  Moderate (transaction buffers)
Disk:    High writes (data + WAL)
Network: Sending WAL stream (1-2 MB/sec)
```

**STANDBY during heavy load:**
```
CPU:     40-70% (replaying WAL, applying transactions)
Memory:  Moderate (replay buffers)
Disk:    High writes (replaying data)
Network: Receiving WAL stream (1-2 MB/sec)
```

**After load completes:**
```
CPU:     Returns to normal (< 10%)
Disk:    Drops to minimal
Network: Minimal traffic (only new changes)
Lag:     Returns to 0 bytes within seconds
```

**MySQL Comparison:**
```bash
# Monitor MySQL master during load:
mysqladmin processlist  # See many INSERT statements
iostat -x 1            # High disk write I/O
top                    # mysqld using 50-80% CPU

# Monitor replica:
SHOW PROCESSLIST;      # See SQL thread applying transactions
SHOW SLAVE STATUS\G    # Watch Seconds_Behind_Master
```

---

### 5. **Async Replication Characteristics**
**Question:** Does standby lag slow down the primary?  
**Answer:** NO! Async replication doesn't block primary commits.

**Async behavior:**
```
Application → INSERT INTO orders → PRIMARY
                                      ↓
                                   Commit ✓
                                      ↓
                              Return SUCCESS to app
                                      ↓
                          (Primary doesn't wait for standby!)
                                      ↓
                              Stream WAL to standby
                                      ↓
                            Standby replays (eventually)
```

**Advantage:**
- ✅ Primary performance NOT affected by slow standby
- ✅ Primary continues accepting writes even if standby offline

**Disadvantage:**
- ❌ If primary crashes before standby catches up → data loss!
- ❌ No guarantee standby has all transactions

**Example risk:**
```
1. Insert 10,000 orders on primary (commits successfully)
2. Primary streams WAL to standby (in progress...)
3. Standby has 5 MB lag (not caught up yet)
4. PRIMARY SERVER CRASHES! 💥
5. Failover to standby
6. Result: Lost 5 MB of transactions (recent 2,000 orders) ❌
```

**We'll fix this in Scenario 08 with SYNCHRONOUS replication!**

**MySQL Comparison:**
```
MySQL Replication Modes:

1. Asynchronous (default):
   - Master doesn't wait for replica
   - Same risk as PostgreSQL async

2. Semi-synchronous:
   - Master waits for 1 replica to ACK
   - Similar to PostgreSQL sync replication
   
3. Group Replication:
   - Majority consensus required
   - Even stronger guarantee
```

---

## 📈 Performance Expectations

### Write Performance:
```
┌──────────────────────┬─────────────────────────────┐
│ Environment          │ Expected INSERT Rate        │
├──────────────────────┼─────────────────────────────┤
│ Docker (Mac/Win)     │ 5,000-10,000 rows/sec      │
│ Docker (Linux)       │ 10,000-20,000 rows/sec     │
│ Bare Metal (SSD)     │ 20,000-50,000 rows/sec     │
│ Cloud (AWS/Azure)    │ 10,000-30,000 rows/sec     │
└──────────────────────┴─────────────────────────────┘
```

**Our test: 50,000 rows**
- Expected duration: 5-10 seconds
- Expected WAL: 10-20 MB
- Expected lag peak: 1-10 MB

### Lag Behavior:
```
Time (sec) │ Lag (bytes)    │ What's happening
───────────┼────────────────┼────────────────────────────
0          │ 0 bytes        │ Starting point ✓
2          │ 500 KB         │ Load started, lag building
5          │ 5 MB           │ Peak lag (max)
6          │ 3 MB           │ Load finished, catching up
8          │ 500 KB         │ Almost caught up
10         │ 0 bytes        │ Fully caught up ✓
```

### Resource Usage Timeline:
```
PRIMARY CPU:
  0-5 sec:   80% (heavy INSERT processing)
  5-10 sec:  60% (finishing inserts)
  10+ sec:   10% (back to normal)

STANDBY CPU:
  0-5 sec:   70% (replaying WAL rapidly)
  5-10 sec:  50% (catching up)
  10+ sec:   10% (caught up, back to normal)

NETWORK:
  0-5 sec:   2 MB/sec (streaming WAL)
  5-10 sec:  1 MB/sec (catching up)
  10+ sec:   minimal (idle)
```

---

## 🚨 What Could Go Wrong?

### Issue 1: Lag Keeps Growing (Never Catches Up)
**Symptom:**
```
Lag: 1 MB → 5 MB → 10 MB → 20 MB → keeps increasing!
```

**Causes:**
- Standby hardware too slow (CPU, disk)
- Network bottleneck (can't stream fast enough)
- Standby doing other work (queries on hot standby)

**Fix:**
- Upgrade standby hardware
- Reduce load on primary
- Move queries off standby during heavy writes

---

### Issue 2: Disk Space Fills Up
**Symptom:**
```
ERROR: could not write to file "pg_wal/000000030000000000000F": No space left on device
```

**Causes:**
- Replication slot retaining too much WAL
- Standby disconnected during heavy load
- Disk too small for write volume

**Fix:**
```bash
# Check disk space:
docker exec postgres-primary df -h /var/lib/postgresql/data

# Check WAL retained:
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
FROM pg_replication_slots;

# If critical, drop slot (rebuild standby later):
SELECT pg_drop_replication_slot('standby_slot');
```

---

### Issue 3: Standby Disconnects
**Symptom:**
```
SELECT * FROM pg_stat_replication;
(0 rows)  ← No standby connected!
```

**Impact:**
- Primary continues working (async advantage)
- WAL accumulates in replication slot
- Disk space risk increases

**Fix:**
```bash
# Check standby logs:
docker logs postgres-standby --tail 50

# Restart standby:
docker restart postgres-standby

# Verify reconnection:
docker exec postgres-primary psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

---

### Issue 4: Performance Slower Than Expected
**Symptom:**
```
Only 1,000 rows/sec (expected 10,000 rows/sec)
```

**Causes:**
- Docker overhead (Mac/Windows especially)
- CPU throttling
- Disk I/O limits
- Table has many indexes (slower INSERTs)

**Not a problem!**
- This is a learning exercise, not a benchmark
- Focus on understanding BEHAVIOR, not absolute numbers
- Production hardware will be different anyway

---

## 🎓 Key Concepts Summary

### 1. WAL = Write-Ahead Log
- Records all changes BEFORE writing to data files
- Similar to MySQL binary logs
- Streamed continuously to standby
- Measured in LSN (Log Sequence Number)

### 2. Replication Lag
- **Byte lag:** How many bytes standby is behind
- **Time lag:** How much time delay
- Normal during heavy load (temporary spike)
- Should return to 0 after load finishes

### 3. Replication Slot
- Prevents WAL deletion while standby catching up
- CRITICAL for async replication
- Protects against data loss after disconnection
- **Risk:** Can fill disk if standby offline long time

### 4. Async Replication
- Primary doesn't wait for standby
- Fast performance on primary
- Risk: Data loss if primary crashes with lag

### 5. Capacity Planning
- Measure WAL generation rate during peak load
- Calculate storage needs (WAL retention)
- Plan network bandwidth (standby must receive WAL)
- Set alert thresholds (when to worry about lag)

---

## 🎬 Ready to Execute!

**All pre-flight checks passed:**
- ✅ Containers healthy and running
- ✅ Replication active (streaming, 0 lag)
- ✅ Replication slot active (standby_slot)
- ✅ Disk space sufficient (51 GB free)
- ✅ Baseline recorded (LSN: 0/E579A20)
- ✅ Orders table exists (4 rows currently)

**Test parameters:**
- Insert: 50,000 rows
- Expected duration: 5-10 seconds
- Expected WAL: 10-20 MB
- Expected lag peak: 1-10 MB
- Expected catch-up: < 30 seconds

**What you'll observe:**
1. INSERT loop running (progress every 10,000 rows)
2. Lag increasing during writes (monitor in real-time)
3. Lag decreasing after writes complete
4. Final lag: 0 bytes (full catch-up)
5. Row counts match: 50,004 on both servers

**MySQL comparison mindset:**
- Think of this as testing `Seconds_Behind_Master` during peak load
- WAL = Binary logs
- Replay lag = Replication delay
- Catch-up = Replica closing the gap

**Proceed with Scenario 06 execution!** 🚀

---

*Pre-flight completed: November 17, 2025 13:22 UTC*  
*Baseline LSN: 0/E579A20*  
*All systems GO for heavy write load test!*
