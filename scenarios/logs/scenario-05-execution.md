# Scenario 05 Execution Log: Network Interruption & Recovery

**Started:** November 17, 2025  
**Status:** In Progress  
**For:** MySQL DBA learning PostgreSQL replication resilience

---

## 🎯 Scenario Overview

**What we're testing:**
- What happens when standby loses network connection to primary?
- How does PostgreSQL handle WAL accumulation?
- How does standby catch up after reconnection?
- What role do replication slots play?

**MySQL Equivalent:**
- Similar to replica network outage
- MySQL: Binary logs accumulate (if not purged)
- PostgreSQL: WAL accumulates in replication slot

---

## Step 1: Baseline - Check Current Replication State

### Check replication status on primary:

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT application_name, state, sync_state, 
   pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as lag 
   FROM pg_stat_replication;"
```

**Output:**
```
 application_name |   state   | sync_state | lag 
------------------+-----------+------------+-----
 walreceiver      | streaming | async      | 0 bytes
(1 row)
```

**Status:** ✅ Replication active, 0 lag

---

### Check replication slot:

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT slot_name, slot_type, active, 
   restart_lsn, confirmed_flush_lsn,
   pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as wal_retained 
   FROM pg_replication_slots;"
```

**Output:**
```
  slot_name   | slot_type | active | restart_lsn | confirmed_flush_lsn | wal_retained 
--------------+-----------+--------+-------------+---------------------+--------------
 standby_slot | physical  | t      | 0/E000148   |                     | 0 bytes
(1 row)
```

**Analysis:**
- ✅ Slot name: `standby_slot` (physical replication)
- ✅ Active: `t` (true) - standby is connected
- ✅ Restart LSN: `0/E000148` - position where standby would restart from
- ✅ WAL retained: `0 bytes` - no WAL accumulation (standby is caught up)

**MySQL Equivalent:**
```sql
SHOW SLAVE STATUS\G
-- Seconds_Behind_Master: 0
-- Relay_Master_Log_File: mysql-bin.000123
```

---

## Step 2: Simulate Network Interruption

### Stop standby (simulates network/server failure):

```bash
docker stop postgres-standby
```

**Output:**
```
postgres-standby
```

**Status:** ✅ Standby disconnected (simulating network outage)

---

### Check replication status - standby should be gone:

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT application_name, state FROM pg_stat_replication;"
```

**Output:**
```
 application_name | state 
------------------+-------
(0 rows)
```

**Analysis:** ✅ No active replication connections (standby is offline)

---

### Check replication slot - should still exist but inactive:

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

**Output:**
```
  slot_name   | active | restart_lsn 
--------------+--------+-------------
 standby_slot | f      | 0/E000148
(1 row)
```

**Analysis:**
- ✅ Slot exists: `standby_slot` (NOT deleted!)
- ✅ Active: `f` (false) - standby is disconnected
- ✅ Restart LSN: `0/E000148` - **SAVED!** (standby will resume from here)

**KEY INSIGHT:** Replication slot **preserves the restart point** even when standby is offline!

**MySQL Equivalent:**
```sql
SHOW SLAVE STATUS\G
-- Slave_IO_Running: No
-- Slave_SQL_Running: No
-- Master keeps binary logs if binlog_expire_logs_seconds allows
```

---

## Step 3: Generate Write Activity During Outage

### Insert 10,000 rows while standby is offline:

```bash
docker exec postgres-primary psql -U postgres -c \
  "INSERT INTO products (name, description, price) 
   SELECT 'Product ' || generate_series(1, 10000), 
          'Created during network outage', 
          random() * 1000;"
```

**Output:**
```
INSERT 0 10000
```

**Status:** ✅ 10,000 rows inserted on primary (standby is offline, won't receive these yet)

---

### Check WAL accumulation:

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT slot_name, active, restart_lsn, pg_current_wal_lsn() as current_lsn, 
   pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as wal_retained 
   FROM pg_replication_slots;"
```

**Output:**
```
  slot_name   | active | restart_lsn | current_lsn | wal_retained 
--------------+--------+-------------+-------------+--------------
 standby_slot | f      | 0/E000148   | 0/E1D3220   | 1868 kB
(1 row)
```

**Analysis:**
- ✅ Restart LSN: `0/E000148` (unchanged - standby's last position)
- ✅ Current LSN: `0/E1D3220` (primary has moved forward)
- ✅ WAL retained: **1868 kB** (1.8 MB of WAL accumulated!)

**What happened:**
- Primary wrote 10,000 rows → generated WAL
- Replication slot **kept the WAL files** (didn't delete them)
- WAL files waiting for standby to catch up

**MySQL Equivalent:**
```sql
SHOW BINARY LOGS;
-- mysql-bin.000123 | 1048576  (old position)
-- mysql-bin.000124 | 1048576  (accumulated)
-- mysql-bin.000125 | 1048576  (accumulated)
```

---

### Insert 20,000 MORE rows:

```bash
docker exec postgres-primary psql -U postgres -c \
  "INSERT INTO products (name, description, price) 
   SELECT 'Product ' || generate_series(1, 20000), 
          'More data during outage', 
          random() * 1000;"
```

**Output:**
```
INSERT 0 20000
```

**Status:** ✅ Another 20,000 rows inserted (total: 30,000 rows during outage)

---

### Check WAL accumulation after more writes:

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT slot_name, active, 
   pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as wal_retained 
   FROM pg_replication_slots;"
```

**Output:**
```
  slot_name   | active | wal_retained 
--------------+--------+--------------
 standby_slot | f      | 5562 kB
(1 row)
```

**Analysis:**
- ✅ WAL retained: **5562 kB** (5.4 MB!)
- ✅ WAL grew from 1868 kB → 5562 kB (added ~3.7 MB)
- ✅ This is ~30,000 rows worth of WAL data

**Calculation:**
- 10,000 rows = 1.8 MB WAL
- 20,000 rows = 3.7 MB WAL
- Total: 30,000 rows = 5.5 MB WAL ✓

---

### Check WAL files on disk:

```bash
docker exec postgres-primary bash -c \
  "ls -lh /var/lib/postgresql/data/pg_wal/ | grep -E '^-' | wc -l"
```

**Output:**
```
11
```

**Analysis:** 11 WAL files exist (each 16 MB, but only 5.5 MB used for our data)

---

### Show recent WAL files:

```bash
docker exec postgres-primary bash -c \
  "ls -lh /var/lib/postgresql/data/pg_wal/ | grep -E '^-' | tail -5"
```

**Output:**
```
-rw------- 1 postgres postgres  16M Nov 16 13:23 00000003000000000000000B
-rw------- 1 postgres postgres  16M Nov 16 13:45 00000003000000000000000C
-rw------- 1 postgres postgres  16M Nov 16 13:45 00000003000000000000000D
-rw------- 1 postgres postgres  16M Nov 17 13:02 00000003000000000000000E
-rw------- 1 postgres postgres   83 Nov 16 12:07 00000003.history
```

**Analysis:**
- ✅ Each WAL segment: 16 MB (standard size)
- ✅ Files kept by replication slot
- ✅ Timeline 3 (from previous failover scenario)

**KEY INSIGHT:** Without replication slot, PostgreSQL would **delete old WAL files** after checkpoint!

---

## Step 4: Reconnect Standby (Network Recovery)

### Start standby (simulate network recovery):

```bash
docker start postgres-standby
```

**Output:**
```
postgres-standby
```

**Status:** ✅ Standby reconnected

---

### Check replication status after reconnection:

```bash
sleep 5
docker exec postgres-primary psql -U postgres -c \
  "SELECT application_name, state, sync_state, 
   pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as replay_lag 
   FROM pg_stat_replication;"
```

**Output:**
```
 application_name |   state   | sync_state | replay_lag 
------------------+-----------+------------+------------
 walreceiver      | streaming | async      | 0 bytes
(1 row)
```

**Analysis:**
- ✅ State: `streaming` (reconnected!)
- ✅ Replay lag: `0 bytes` (already caught up!)
- ✅ Standby received all 5.5 MB of accumulated WAL
- ✅ Standby replayed all 30,000 missed rows

**How fast did it catch up?**
- WAL size: 5.5 MB
- Catch-up time: < 5 seconds
- Speed: ~1 MB/sec (very fast!)

---

### Verify data consistency:

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT count(*) as primary_count FROM products;"

docker exec postgres-standby psql -U postgres -c \
  "SELECT count(*) as standby_count FROM products;"
```

**Output:**
```
=== PRIMARY ===
 primary_count 
---------------
         40003
(1 row)

=== STANDBY ===
 standby_count 
---------------
         40003
(1 row)
```

**Analysis:**
- ✅ PRIMARY: 40,003 rows
- ✅ STANDBY: 40,003 rows
- ✅ **IDENTICAL!** Data consistency maintained!

**Breakdown:**
- Original: 10,003 rows (from previous scenarios)
- Added during outage: 30,000 rows
- Total: 40,003 rows ✓

---

## 🎓 What Just Happened? (Detailed Explanation)

