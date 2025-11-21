# PostgreSQL Replication - Complete Interview Guide

**Deep Dive into Streaming Replication for Senior DBAs**

---

## 🎯 Replication Overview: MySQL vs PostgreSQL

| Aspect | MySQL | PostgreSQL |
|--------|-------|-----------|
| **Position Tracking** | Binlog file + position or GTID | LSN (automatic) |
| **Replication Type** | Logical (row-based) or Statement | Physical (WAL) or Logical |
| **Setup Complexity** | Medium (CHANGE MASTER TO) | Easy (pg_basebackup -R) |
| **Lag Monitoring** | SHOW SLAVE STATUS | pg_stat_replication |
| **Network Failure Recovery** | Manual (binlog position) | Automatic (replication slots) |
| **Split-Brain Protection** | External tools (MHA, Orchestrator) | Built-in (timelines) |
| **Replication Delay** | Seconds_Behind_Master | replay_lag (more accurate) |
| **Cascade Replication** | Yes | Yes |
| **Multi-Master** | Galera Cluster | Logical replication, BDR |

---

## 📚 1. Physical Streaming Replication (Most Common)

### What is Physical Replication?

**Definition:** Byte-level replication of WAL (Write-Ahead Log) records from primary to standby

**Characteristics:**
- **Exact copy:** Standby is binary-identical to primary
- **Read-only standby:** Cannot write to standby (hot standby for reads)
- **Entire cluster:** Replicates all databases
- **Block-level:** Replicates data file changes, not SQL statements
- **Fast:** Near-zero overhead

```
┌──────────────────┐
│     PRIMARY      │
│  All databases   │
└────────┬─────────┘
         │ WAL Stream
         ↓
┌──────────────────┐
│     STANDBY      │
│  Exact copy      │
│  Read-only       │
└──────────────────┘
```

---

### Setup: Step-by-Step

**On Primary:**

```sql
-- 1. Enable replication
ALTER SYSTEM SET wal_level = replica;
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET hot_standby = on;

-- Restart PostgreSQL
sudo systemctl restart postgresql

-- 2. Create replication user
CREATE USER replicator WITH REPLICATION PASSWORD 'rep_password';

-- 3. Configure pg_hba.conf
sudo vi /etc/postgresql/15/main/pg_hba.conf
# Add:
host replication replicator 0.0.0.0/0 md5

-- Reload configuration
SELECT pg_reload_conf();

-- 4. Create replication slot (recommended)
SELECT pg_create_physical_replication_slot('standby_slot');
```

**On Standby:**

```bash
# 1. Stop PostgreSQL if running
sudo systemctl stop postgresql

# 2. Clear data directory
sudo rm -rf /var/lib/postgresql/15/main/*

# 3. Run pg_basebackup
sudo -u postgres pg_basebackup \
    -h primary.example.com \
    -U replicator \
    -D /var/lib/postgresql/15/main \
    -Fp \          # Plain format
    -Xs \          # Stream WAL
    -P \           # Show progress
    -R             # Create recovery configuration

# The -R flag automatically creates:
# - standby.signal file (marks as standby)
# - primary_conninfo in postgresql.auto.conf
# - primary_slot_name in postgresql.auto.conf (if using slots)

# 4. Start PostgreSQL
sudo systemctl start postgresql

# 5. Verify replication
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Should return: t (true = standby)
```

**Verify on Primary:**

```sql
-- Check replication status
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;

-- Check replication slot
SELECT 
    slot_name,
    slot_type,
    database,
    active,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal
FROM pg_replication_slots;
```

---

### Configuration Parameters

**Primary Configuration:**

```ini
# postgresql.conf

# --- WAL CONFIGURATION ---
wal_level = replica              # replica, logical, or minimal
                                 # replica: Enables physical replication
                                 # logical: Enables logical replication too

max_wal_senders = 10             # Max concurrent WAL sender processes
                                 # Rule: Number of standbys + 2

wal_keep_size = 1GB              # WAL retention (PostgreSQL 13+)
                                 # Prevents WAL deletion if standby falls behind
                                 # Older: wal_keep_segments

max_replication_slots = 10       # Maximum replication slots
                                 # Rule: Number of standbys + backup slots

# --- HOT STANDBY ---
hot_standby = on                 # Allow reads on standby
hot_standby_feedback = off       # Standby sends feedback to prevent VACUUM conflicts
                                 # on: Prevents VACUUM on primary (can cause bloat)
                                 # off: Standby queries may be canceled

# --- SYNCHRONOUS REPLICATION (optional) ---
synchronous_commit = on          # on: Wait for WAL write to standby
                                 # remote_write: Wait for standby to write WAL
                                 # remote_apply: Wait for standby to apply WAL
                                 # local: Don't wait for standby
                                 # off: Don't wait for disk write

synchronous_standby_names = ''   # Standby names for sync replication
                                 # Examples:
                                 # 'standby1' - One specific standby
                                 # 'FIRST 1 (standby1, standby2)' - First available
                                 # 'ANY 1 (standby1, standby2)' - Any one
                                 # 'standby1, standby2' - Both must confirm

# --- WAL ARCHIVING (for PITR) ---
archive_mode = on                # Enable WAL archiving
archive_command = 'cp %p /archive/%f'  # Archive command
archive_timeout = 300            # Force WAL switch every 5 minutes
```

**Standby Configuration (postgresql.auto.conf):**

```ini
# Created automatically by pg_basebackup -R

primary_conninfo = 'host=primary.example.com port=5432 user=replicator password=rep_password application_name=standby1'

primary_slot_name = 'standby_slot'  # Replication slot to use

restore_command = ''              # For archive recovery (PITR)
recovery_target_timeline = 'latest'  # Follow timeline changes

# Hot standby parameters
hot_standby = on
hot_standby_feedback = off
```

---

## 🔄 2. Synchronous vs Asynchronous Replication

### Asynchronous Replication (Default)

**How it Works:**
```
Primary: 
  1. Commit transaction
  2. Write to WAL
  3. Return success to client
  4. Send WAL to standby (in background)

Standby:
  1. Receive WAL
  2. Apply to data files
  3. No acknowledgment needed
```

**Characteristics:**
- ✅ **Fast:** No waiting for standby
- ✅ **High performance:** Primary not affected by standby lag
- ❌ **Data loss possible:** If primary fails before WAL sent to standby
- **RPO:** Seconds to minutes (depending on lag)
- **Use Case:** Most applications, read replicas

---

### Synchronous Replication

**How it Works:**
```
Primary:
  1. Commit transaction
  2. Write to WAL
  3. Send WAL to standby
  4. Wait for standby acknowledgment ⏱️
  5. Return success to client

Standby:
  1. Receive WAL
  2. Write to disk (remote_write) or apply (remote_apply)
  3. Send acknowledgment
```

**Characteristics:**
- ✅ **Zero data loss:** RPO = 0 seconds
- ✅ **Guaranteed durability:** Commit means data on 2+ servers
- ❌ **Slower:** Writes wait for network + standby
- ❌ **Standby failure blocks writes:** Unless using FIRST/ANY
- **Use Case:** Financial systems, healthcare, mission-critical

**Configuration:**

```sql
-- On primary
ALTER SYSTEM SET synchronous_standby_names = 'standby1';
SELECT pg_reload_conf();

-- Verify
SELECT sync_state FROM pg_stat_replication;
-- Output: sync (or potential, async)
```

**Advanced Synchronous Modes:**

```sql
-- Option 1: Specific standby
ALTER SYSTEM SET synchronous_standby_names = 'standby1';
-- Writes wait for standby1 only

-- Option 2: FIRST N (first N standbys to acknowledge)
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (standby1, standby2)';
-- Writes wait for first available standby
-- If standby1 fails, standby2 becomes sync

-- Option 3: ANY N (any N standbys)
ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (standby1, standby2, standby3)';
-- Writes wait for any 1 of 3 standbys
-- Fastest response wins

-- Option 4: Multiple synchronous standbys
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 2 (standby1, standby2, standby3)';
-- Writes wait for 2 standbys
-- Very safe but slower
```

**Synchronous Commit Levels:**

```sql
-- Per transaction control
BEGIN;
SET LOCAL synchronous_commit = off;  -- This transaction: async
INSERT INTO logs VALUES (...);
COMMIT;

-- Levels:
-- on: Wait for WAL flush to standby disk (default for sync rep)
-- remote_apply: Wait for WAL application (standby can read immediately)
-- remote_write: Wait for WAL write to standby (not flushed)
-- local: Don't wait for standby (async)
-- off: Don't even wait for local disk (dangerous!)
```

**Performance Impact:**

```
Test: 10,000 INSERT statements

Configuration          | TPS    | Latency (avg) |
-----------------------|--------|---------------|
Async                  | 10,000 | 1ms           |
Sync (remote_write)    | 5,000  | 2ms           | (+ network RTT)
Sync (remote_apply)    | 3,000  | 3ms           | (+ apply time)
Sync (FIRST 2)         | 2,000  | 5ms           | (+ 2 standbys)
```

---

## 📡 3. Replication Lag Monitoring

### Understanding Lag Metrics

```sql
SELECT 
    application_name,
    client_addr,
    state,
    
    -- Position metrics (LSN)
    sent_lsn,        -- WAL sent to standby
    write_lsn,       -- WAL written on standby (in memory)
    flush_lsn,       -- WAL flushed to disk on standby
    replay_lsn,      -- WAL applied to database on standby
    
    -- Lag in bytes
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
    
    -- Lag in time (PostgreSQL 10+)
    write_lag,       -- Time since write
    flush_lag,       -- Time since flush
    replay_lag,      -- Time since replay (most important!)
    
    -- Sync state
    sync_state       -- sync, async, potential
FROM pg_stat_replication;
```

**Lag Calculation:**

```sql
-- Bytes behind
SELECT 
    application_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
FROM pg_stat_replication;

-- Time behind (on standby)
SELECT 
    now() - pg_last_xact_replay_timestamp() AS lag
FROM pg_stat_replication;
```

**What's Normal?**

| Environment | Acceptable Lag |
|-------------|----------------|
| Same datacenter | < 1 second, < 10 MB |
| Different AZs (same region) | < 10 seconds, < 100 MB |
| Cross-region | < 60 seconds, < 1 GB |
| Analytics replica | Minutes, GBs (acceptable) |

**Alert Thresholds:**

```sql
-- Critical alert: lag > 10 seconds or 100 MB
SELECT 
    application_name,
    replay_lag > interval '10 seconds' AS lag_critical,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) > 104857600 AS bytes_critical
FROM pg_stat_replication;
```

---

### Causes of Replication Lag

**1. Network Bandwidth:**
```sql
-- High write volume exceeds network capacity
-- Check: WAL generation rate
SELECT 
    pg_size_pretty(
        pg_wal_lsn_diff(
            pg_current_wal_lsn(),
            pg_current_wal_lsn() - '0/100000'::pg_lsn
        )
    ) AS wal_per_second;

-- Solution: Upgrade network, add compression
ALTER SYSTEM SET wal_compression = on;
```

**2. Standby Hardware:**
```sql
-- Standby CPU/disk slower than primary
-- Check: pg_stat_activity on standby
SELECT * FROM pg_stat_activity WHERE backend_type = 'walreceiver';

-- Solution: Upgrade standby hardware
```

**3. Long-Running Queries on Standby:**
```sql
-- On standby
SELECT 
    pid,
    usename,
    state,
    now() - query_start AS duration,
    query
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY query_start;

-- Long query blocks WAL replay!
-- Solution: Kill query or enable hot_standby_feedback
ALTER SYSTEM SET hot_standby_feedback = on;
-- Warning: This prevents VACUUM on primary (can cause bloat)
```

**4. Vacuum Conflicts:**
```sql
-- On standby, check conflicts
SELECT * FROM pg_stat_database_conflicts WHERE datname = 'production';

-- Conflicts types:
-- confl_tablespace: Dropped tablespace
-- confl_lock: Acquired lock conflicts with replay
-- confl_snapshot: Old snapshot conflicts with VACUUM
-- confl_bufferpin: Holding buffer longer than max_standby_streaming_delay
-- confl_deadlock: Deadlock

-- Solution: Tune delays
ALTER SYSTEM SET max_standby_streaming_delay = '30s';  -- Default 30s
ALTER SYSTEM SET hot_standby_feedback = on;
```

---

## 🔌 4. Replication Slots

### Why Replication Slots?

**Problem Without Slots:**
```
Timeline:
10:00 - Standby falls behind (network issue)
10:05 - Primary generates 10 GB WAL
10:10 - Primary runs VACUUM, removes old WAL
10:15 - Standby reconnects
10:16 - Standby: "I need WAL segment 0000001000000ABC"
10:17 - Primary: "Sorry, I deleted it. You need full rebuild."
10:18 - DBA: Spends 4 hours rebuilding 2 TB standby ❌
```

**Solution With Slots:**
```
Timeline:
10:00 - Standby falls behind
10:05 - Primary generates 10 GB WAL
10:10 - Primary: "Standby slot is inactive, keeping WAL"
10:15 - Standby reconnects
10:16 - Standby: "I need WAL segment 0000001000000ABC"
10:17 - Primary: "Here you go! ✅"
10:18 - Standby: Catches up automatically in 30 seconds ✅
```

### Create Replication Slot

```sql
-- On primary
SELECT pg_create_physical_replication_slot('standby_slot');

-- Verify
SELECT * FROM pg_replication_slots;

-- Output:
  slot_name   | plugin | slot_type | active | restart_lsn | confirmed_flush_lsn
--------------+--------+-----------+--------+-------------+---------------------
standby_slot  | NULL   | physical  | t      | 0/4B000000  | NULL
```

### Configure Standby to Use Slot

```sql
-- On standby: postgresql.auto.conf
primary_slot_name = 'standby_slot'

-- Restart standby
sudo systemctl restart postgresql
```

### Monitor Slot Usage

```sql
-- On primary
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS pending_wal
FROM pg_replication_slots;

-- Alert if: retained_wal > 10 GB (disk could fill!)
```

### Danger: Inactive Slots

**Problem:**
```sql
-- Standby permanently offline (decommissioned)
-- But slot still exists!

SELECT * FROM pg_replication_slots WHERE NOT active;

-- Slot keeps WAL forever → disk fills → PRIMARY CRASHES! 💥
```

**Solution:**
```sql
-- Drop unused slot
SELECT pg_drop_replication_slot('old_standby_slot');

-- Or: Set max_slot_wal_keep_size (PostgreSQL 13+)
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';
-- Primary will delete WAL even if slot needs it
-- Standby will need rebuild, but primary stays alive
```

**Monitoring Script:**
```sql
-- Alert if slot inactive > 1 hour and retained_wal > 5 GB
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE NOT active
  AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 5368709120;  -- 5 GB
```

---

## 🌳 5. Cascade Replication

**Use Case:** Reduce load on primary, replicate across datacenters

```
┌──────────────┐
│   PRIMARY    │
│   US-East-1  │
└──────┬───────┘
       │ WAL Stream
       ↓
┌──────────────┐
│  STANDBY 1   │
│   US-East-1  │
└──────┬───────┘
       │ WAL Stream (cascade)
       ↓
┌──────────────┐
│  STANDBY 2   │
│   EU-West-1  │
└──────────────┘
```

**Setup:**

```sql
-- On STANDBY 1 (cascade source)
ALTER SYSTEM SET max_wal_senders = 5;
ALTER SYSTEM SET hot_standby = on;
SELECT pg_reload_conf();

-- Create slot for STANDBY 2
SELECT pg_create_physical_replication_slot('standby2_slot');

-- On STANDBY 2
pg_basebackup -h standby1 -U replicator -D /data -R

-- Edit postgresql.auto.conf on STANDBY 2
primary_conninfo = 'host=standby1 ...'
primary_slot_name = 'standby2_slot'

-- Start STANDBY 2
sudo systemctl start postgresql
```

**Verify Cascade:**

```sql
-- On PRIMARY
SELECT application_name FROM pg_stat_replication;
-- Shows: standby1 only

-- On STANDBY 1
SELECT application_name FROM pg_stat_replication;
-- Shows: standby2
```

---

## 🔀 6. Logical Replication

**Physical vs Logical:**

| Aspect | Physical | Logical |
|--------|----------|---------|
| **Granularity** | Entire cluster | Database, table, row-level |
| **Target** | Identical copy | Can be different version/OS |
| **Schema** | Same | Can be different |
| **Writes on standby** | No | Yes! |
| **Overhead** | Low | Medium |
| **Use case** | HA, DR | Selective replication, upgrades |

### Logical Replication Setup

**On Publisher (source):**

```sql
-- 1. Enable logical replication
ALTER SYSTEM SET wal_level = logical;
-- Requires restart
sudo systemctl restart postgresql

-- 2. Create publication
CREATE PUBLICATION my_publication FOR TABLE orders, customers;

-- Or: All tables
CREATE PUBLICATION all_tables FOR ALL TABLES;

-- 3. Create replication user
CREATE USER logical_rep WITH REPLICATION PASSWORD 'password';
GRANT SELECT ON orders, customers TO logical_rep;

-- 4. Configure pg_hba.conf
host all logical_rep 0.0.0.0/0 md5
```

**On Subscriber (target):**

```sql
-- 1. Create tables (same structure)
CREATE TABLE orders (...);
CREATE TABLE customers (...);

-- 2. Create subscription
CREATE SUBSCRIPTION my_subscription
    CONNECTION 'host=publisher user=logical_rep password=password dbname=production'
    PUBLICATION my_publication;

-- 3. Verify
SELECT * FROM pg_stat_subscription;

-- Output:
 subname         | pid  | relid | received_lsn | latest_end_lsn | last_msg_send_time
-----------------+------+-------+--------------+----------------+--------------------
my_subscription | 1234 | 16384 | 0/4B000000   | 0/4B000000     | 2025-11-21 10:30:00
```

### Logical Replication Use Cases

**1. Selective Replication:**
```sql
-- Replicate only active orders
CREATE PUBLICATION active_orders FOR TABLE orders
WHERE (status IN ('pending', 'processing'));
```

**2. Zero-Downtime Upgrades:**
```
Old Server (PostgreSQL 14)
  ↓ Logical Replication
New Server (PostgreSQL 16)

Process:
1. Set up logical replication
2. Let new server catch up
3. Switch applications to new server
4. Decommission old server
```

**3. Multi-Master (BDR):**
```
Using pglogical or BDR (Bi-Directional Replication):

DC1 ←→ DC2 ←→ DC3

Each datacenter accepts writes
Conflicts resolved automatically
```

**4. Data Warehousing:**
```sql
-- Replicate production to analytics
-- Publisher: production OLTP
CREATE PUBLICATION analytics_pub FOR TABLE orders, customers;

-- Subscriber: analytics OLAP
CREATE SUBSCRIPTION analytics_sub ...;

-- Analytics queries don't impact production ✅
```

---

## 💼 Interview Questions & Answers

### Q1: "Explain the difference between physical and logical replication in PostgreSQL."

**Answer:**
> "Physical replication replicates WAL records at the byte level—it's an exact binary copy. The standby is read-only and must be the same PostgreSQL version, OS, and architecture. It replicates the entire cluster (all databases).
>
> Logical replication replicates row changes—INSERTs, UPDATEs, DELETEs. You can replicate specific tables, and the subscriber can be a different PostgreSQL version or even have a different schema. Crucially, the subscriber is read-write, so you can have writes on both sides.
>
> **Comparison:**
> - **Physical:** HA/DR, read replicas, fast, low overhead
> - **Logical:** Selective replication, zero-downtime upgrades, multi-master, data warehousing
>
> **Example:** In my previous role, we used physical replication for HA (99.99% uptime) and logical replication to replicate production data to a separate analytics cluster. Analytics queries didn't impact production, and we could run PostgreSQL 16 on analytics while production was still on PostgreSQL 14 during our gradual upgrade."

---

### Q2: "How do replication slots prevent data loss, and what's the gotcha?"

**Answer:**
> "Replication slots ensure the primary retains WAL segments until all standbys using the slot have consumed them. This prevents the classic problem where a standby falls behind, primary deletes WAL, and standby needs a full rebuild.
>
> **Example:**
> In today's Scenario 5, we disconnected a standby for 4 minutes. The replication slot retained 921 KB of WAL. When the standby reconnected, it caught up automatically in under 1 second. Without the slot, if wal_keep_size was too small, the WAL might have been deleted, requiring a 4-hour rebuild of a 2 TB database.
>
> **The Gotcha:**
> If a standby is permanently offline but its slot still exists, the primary keeps WAL forever. I've seen cases where this filled the disk and crashed the primary—mission-critical outage.
>
> **Solution:**
> - Monitor slot usage: `pg_replication_slots`
> - Alert if `retained_wal > 10 GB` and slot inactive
> - Set `max_slot_wal_keep_size = '10GB'` (PostgreSQL 13+) as a safety valve
> - Drop slots for decommissioned standbys immediately
>
> I create a daily cron job that alerts on inactive slots older than 6 hours."

---

### Q3: "When would you use synchronous replication vs asynchronous?"

**Answer:**
> "Synchronous replication guarantees zero data loss (RPO=0) but has performance costs. I choose based on business requirements:
>
> **Use Synchronous When:**
> - Financial transactions (banking, payments)
> - Healthcare records (HIPAA compliance)
> - E-commerce orders (customer payment data)
> - Any scenario where losing even 1 transaction is unacceptable
>
> **Use Asynchronous When:**
> - Analytics data (can replay from source)
> - Logs, metrics (lossy data acceptable)
> - Read replicas (not for HA)
> - High write volume applications where performance matters
>
> **My Approach:**
> I use a hybrid:
> ```sql
> synchronous_standby_names = 'FIRST 1 (standby1, standby2)';
> ```
> - Primary → Standby1 (same AZ): Synchronous (RPO=0)
> - Primary → Standby2 (different AZ): Asynchronous (performance)
> - If Standby1 fails, Standby2 becomes sync automatically
>
> **Performance Impact:**
> In my testing:
> - Async: 10,000 TPS, 1ms latency
> - Sync (local): 8,000 TPS, 1.5ms latency (20% overhead)
> - Sync (cross-region): 2,000 TPS, 50ms latency (80% overhead)
>
> For a payment system, the 20% overhead is acceptable for zero data loss. For a logging system, async is fine."

---

### Q4: "A standby is lagging 10 seconds behind. How do you troubleshoot?"

**Answer:**
> "I follow a systematic approach:
>
> **1. Check current lag:**
> ```sql
> SELECT 
>     application_name,
>     pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes,
>     replay_lag
> FROM pg_stat_replication;
> -- Result: standby1, 150 MB, 10 seconds
> ```
>
> **2. Identify bottleneck:**
>
> *Network?*
> ```sql
> SELECT pg_wal_lsn_diff(sent_lsn, write_lsn) AS network_lag FROM pg_stat_replication;
> -- If large: Network bottleneck
> -- Solution: Upgrade network, enable wal_compression
> ```
>
> *Disk I/O?*
> ```bash
> # On standby
> iostat -x 1
> # Check: %util > 90% → Disk bottleneck
> # Solution: Upgrade to SSD/NVMe
> ```
>
> *CPU?*
> ```sql
> -- On standby
> SELECT * FROM pg_stat_activity WHERE backend_type = 'walreceiver';
> SELECT * FROM pg_stat_activity WHERE backend_type = 'startup';
> # Check: High CPU
> # Solution: Upgrade CPU
> ```
>
> *Long-running query on standby?*
> ```sql
> -- On standby
> SELECT pid, state, now() - query_start AS duration, query
> FROM pg_stat_activity
> WHERE state != 'idle'
> ORDER BY query_start;
> -- If query running > 30 minutes and lag increasing:
> -- Query blocks WAL replay!
> ```
>
> **3. Solutions by cause:**
>
> *Write volume too high:*
> ```sql
> -- Check WAL generation rate
> SELECT pg_current_wal_lsn();
> -- Wait 1 second
> SELECT pg_current_wal_lsn();
> -- Calculate: diff / 1 second = WAL/sec
> -- If > 50 MB/sec, network may not keep up
> ```
>
> *Vacuum conflicts:*
> ```sql
> -- On standby
> SELECT * FROM pg_stat_database_conflicts WHERE datname = 'production';
> -- If confl_snapshot > 0:
> ALTER SYSTEM SET hot_standby_feedback = on;
> SELECT pg_reload_conf();
> -- Warning: Prevents VACUUM on primary (monitor bloat!)
> ```
>
> **4. Immediate fix:**
> ```sql
> -- If critical queries blocking replay
> -- On standby, kill blocking query:
> SELECT pg_terminate_backend(1234);
>
> -- Replay resumes, lag drops to 0 seconds ✅
> ```
>
> **5. Long-term solutions:**
> - Tune max_standby_streaming_delay
> - Enable hot_standby_feedback (accept bloat trade-off)
> - Upgrade standby hardware
> - Implement cascade replication (reduce primary load)
> - Use logical replication for analytics (separate from HA)
>
> **Real Example:**
> I found a data scientist running a 6-hour analytical query on a production standby, blocking replay. Lag was 50 GB. I killed the query, lag caught up in 2 minutes. Long-term: Created separate analytics replica using logical replication, prevented from happening again."

---

### Q5: "How do you perform a major version upgrade with minimal downtime?"

**Answer:**
> "Logical replication enables near-zero downtime upgrades—critical for 24/7 systems. Here's my process:
>
> **Preparation (Week 1-2):**
> 1. Test upgrade in dev/staging
> 2. Identify incompatible extensions
> 3. Create rollback plan
> 4. Schedule upgrade window (night/weekend)
>
> **Execution (T-0 hours):**
>
> *T-4 hours: Set up new cluster*
> ```bash
> # Provision new PostgreSQL 16 server
> sudo apt-get install postgresql-16
>
> # Create database structure (no data)
> pg_dumpall --schema-only --host=old-server | psql -h new-server
> ```
>
> *T-3 hours: Start logical replication*
> ```sql
> -- Old server (PostgreSQL 14)
> ALTER SYSTEM SET wal_level = logical;
> -- Restart required (during maintenance window)
>
> CREATE PUBLICATION upgrade_pub FOR ALL TABLES;
>
> -- New server (PostgreSQL 16)
> CREATE SUBSCRIPTION upgrade_sub
>     CONNECTION 'host=old-server user=replicator dbname=production'
>     PUBLICATION upgrade_pub;
> ```
>
> *T-0 to T+2 hours: Initial sync*
> - Let new server catch up (may take hours for large DBs)
> - Monitor: `SELECT * FROM pg_stat_subscription;`
> - Application still using old server (no downtime yet)
>
> *T+2 hours: Verify sync*
> ```sql
> -- Check lag
> SELECT pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, received_lsn))
> FROM pg_stat_subscription;
> -- Result: 0 bytes (caught up) ✅
>
> -- Verify row counts
> SELECT count(*) FROM orders; -- Old and new should match
> ```
>
> *T+2.5 hours: Cutover (5-10 minute downtime)*
> ```bash
> # 1. Announce maintenance
> echo 'Maintenance in progress' > /var/www/html/maintenance.html
>
> # 2. Stop application writes (set to read-only)
> # or enable maintenance mode
>
> # 3. Wait for replication to catch up (seconds)
> # Monitor pg_stat_subscription
>
> # 4. Drop subscription (prevents further changes)
> DROP SUBSCRIPTION upgrade_sub;
>
> # 5. Verify data consistency
> # Compare row counts, checksums, critical records
>
> # 6. Update DNS/connection strings to new server
> # Or: Swap IPs (if using floating IP)
>
> # 7. Enable application writes on new server
> rm /var/www/html/maintenance.html
>
> # 8. Monitor for errors
> # Application now on PostgreSQL 16 ✅
> ```
>
> *T+3 hours: Post-upgrade*
> ```sql
> -- Update statistics
> ANALYZE;
>
> -- Rebuild bloated indexes
> REINDEX DATABASE production;
>
> -- Test critical queries
> EXPLAIN ANALYZE SELECT ... -- Verify plans look good
> ```
>
> **Rollback Plan:**
> ```sql
> -- If issues discovered:
> # 1. Set up reverse logical replication
> #    New server → Old server
> # 2. Switch application back
> # 3. Investigate issues
> # 4. Try again next week
> ```
>
> **Results:**
> - **Downtime:** 7 minutes (DNS propagation was bottleneck)
> - **Data loss:** 0 rows
> - **Performance:** 20% improvement (PostgreSQL 16 optimizations)
> - **Rollback:** Tested, not needed
>
> **Key Advantages:**
> - Most sync happens while old server is live (no downtime)
> - Can test new server before switching
> - Can roll back if issues
> - Works across major versions (14 → 16)
>
> Compare to pg_upgrade: 2-4 hours downtime for 2 TB database!"

---

## ✅ Summary

**Key Replication Concepts:**
- ✅ Physical replication: Block-level, fast, HA/DR
- ✅ Logical replication: Row-level, flexible, upgrades
- ✅ Replication slots: Prevent WAL deletion
- ✅ Synchronous vs async: RPO trade-off
- ✅ Lag monitoring: replay_lag, pg_stat_replication
- ✅ Cascade replication: Reduce primary load

**Interview Readiness:**
- ✅ Can explain physical vs logical replication
- ✅ Understand replication slots (and the gotcha!)
- ✅ Know when to use sync vs async
- ✅ Can troubleshoot replication lag
- ✅ Can design zero-downtime upgrade strategy

**MySQL → PostgreSQL Key Differences:**
- ✅ LSN vs binlog position (automatic!)
- ✅ Replication slots (prevent rebuild!)
- ✅ Timeline safety (prevent split-brain!)
- ✅ Built-in monitoring (pg_stat_replication)

You're ready for replication deep-dives in senior PostgreSQL DBA interviews! 🚀
