# Scenario 05: Network Interruption - Pre-Flight Check & Overview

**Date:** November 17, 2025  
**Duration:** 20-25 minutes  
**Difficulty:** Intermediate

---

## 🎯 What Does This Scenario Test?

### The Core Question:
**"What happens when the standby server loses connection to the primary during active replication?"**

### Real-World Situations:
1. 🌐 **Network Outage** - Cable unplugged, switch failure, firewall rule change
2. 🔧 **Standby Maintenance** - Server reboot, OS updates, hardware replacement
3. 🔥 **Network Congestion** - Bandwidth exhaustion, packet loss
4. 💥 **Standby Crash** - Process crash, out of memory, disk full

### What We're Testing:
- ✅ Does primary continue accepting writes when standby is offline?
- ✅ Does primary keep WAL files for offline standby?
- ✅ Does standby automatically reconnect after network recovery?
- ✅ Does standby catch up with missed data?
- ✅ Is data consistency maintained after reconnection?

### MySQL Comparison:
In MySQL, when a replica goes offline:
- Primary keeps binary logs (if `binlog_expire_logs_seconds` allows)
- Must manually reconnect: `START SLAVE;`
- Risk: If binary logs purged, must rebuild replica

In PostgreSQL:
- Primary keeps WAL files via **replication slot**
- Automatic reconnection (no manual START needed!)
- No risk: Slot prevents WAL deletion until standby catches up

---

## ✅ Pre-Requisites Check

### Step 1: Check Docker Containers Are Running

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

**Expected Output:**
```
NAMES              STATUS           PORTS
postgres-primary   Up XX hours      0.0.0.0:5432->5432/tcp
postgres-standby   Up XX hours      0.0.0.0:5433->5432/tcp
```

**If containers are stopped:**
```bash
docker-compose up -d
sleep 5  # Wait for startup
```

---

### Step 2: Verify Replication Is Active

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT application_name, state, sync_state 
   FROM pg_stat_replication;"
```

**Expected Output:**
```
 application_name |   state   | sync_state 
------------------+-----------+------------
 walreceiver      | streaming | async
(1 row)
```

**Status Checks:**
- ✅ Should have 1 row (standby connected)
- ✅ State should be: `streaming`
- ✅ Sync state should be: `async`

**If no rows (standby not connected):**
```bash
# Check standby is in recovery mode:
docker exec postgres-standby psql -U postgres -c \
  "SELECT pg_is_in_recovery();"
# Should return: t (true)

# Restart standby:
docker restart postgres-standby
sleep 5

# Recheck replication
```

---

### Step 3: Verify Replication Slot Exists

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT slot_name, slot_type, active 
   FROM pg_replication_slots;"
```

**Expected Output:**
```
  slot_name   | slot_type | active 
--------------+-----------+--------
 standby_slot | physical  | t
(1 row)
```

**Status Checks:**
- ✅ Slot name: `standby_slot`
- ✅ Type: `physical` (for streaming replication)
- ✅ Active: `t` (true - standby is using it)

**If slot is missing:**
```bash
# Create replication slot:
docker exec postgres-primary psql -U postgres -c \
  "SELECT pg_create_physical_replication_slot('standby_slot');"

# Restart standby to use the slot:
docker restart postgres-standby
```

**Why is replication slot critical for this scenario?**
- 🛡️ **Prevents WAL deletion** while standby is offline
- 🛡️ **Saves standby's restart position** (restart_lsn)
- 🛡️ **Enables automatic catch-up** after reconnection

**Without replication slot:**
- ❌ Primary deletes old WAL files after checkpoint
- ❌ Standby can't catch up (missing WAL data)
- ❌ Must rebuild standby with `pg_basebackup`

---

### Step 4: Check Replication Lag (Should Be Zero)

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT application_name,
   pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as lag 
   FROM pg_stat_replication;"
```

**Expected Output:**
```
 application_name | lag 
------------------+-----
 walreceiver      | 0 bytes
(1 row)
```

**Status:** ✅ Lag should be `0 bytes` or very small (< 1 MB)

**If lag is large (> 10 MB):**
- ⚠️ Standby is already behind
- Wait for standby to catch up before starting scenario
- Or investigate network/disk issues

---

### Step 5: Verify Data Consistency

```bash
echo "=== PRIMARY ==="
docker exec postgres-primary psql -U postgres -c \
  "SELECT count(*) FROM products;"

echo ""
echo "=== STANDBY ==="
docker exec postgres-standby psql -U postgres -c \
  "SELECT count(*) FROM products;"
```

**Expected Output:**
```
=== PRIMARY ===
 count 
-------
 10003
(1 row)

=== STANDBY ===
 count 
-------
 10003
(1 row)
```

**Status:** ✅ Both should have same row count

**If counts differ:**
- ⚠️ Replication is lagging or broken
- Check replication lag (Step 4)
- Wait for standby to catch up

---

### Step 6: Check Current WAL Position

```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT pg_current_wal_lsn() as current_lsn,
   (SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = 'standby_slot') as slot_lsn;"
```

**Expected Output:**
```
 current_lsn | slot_lsn  
-------------+-----------
 0/E000148   | 0/E000148
(1 row)
```

**Status:** ✅ Both LSNs should be same or very close

**Record this baseline LSN** - we'll compare it later to see how much WAL accumulated

---

### Step 7: Check Disk Space on Primary

```bash
docker exec postgres-primary bash -c \
  "df -h /var/lib/postgresql/data/pg_wal"
```

**Expected Output:**
```
Filesystem      Size  Used Avail Use% Mounted on
overlay         200G   10G  190G   5% /var/lib/postgresql/data
```

**Status:** ✅ Should have at least 1 GB free space for WAL accumulation

**Why check disk space?**
- During standby outage, WAL files accumulate
- If disk fills up, primary will **STOP accepting writes**!
- This is a safety mechanism to prevent data loss

---

## 📊 Pre-Flight Checklist Summary

Before starting Scenario 05, verify:

| Check | Command | Expected | Status |
|-------|---------|----------|--------|
| **Containers running** | `docker ps` | Both up | ⬜ |
| **Replication active** | `pg_stat_replication` | 1 row, streaming | ⬜ |
| **Replication slot exists** | `pg_replication_slots` | standby_slot, active=t | ⬜ |
| **Zero lag** | Check replay_lsn diff | 0 bytes | ⬜ |
| **Data consistency** | Count rows | Same count | ⬜ |
| **WAL position** | `pg_current_wal_lsn()` | Record baseline | ⬜ |
| **Disk space** | `df -h pg_wal` | > 1 GB free | ⬜ |

**✅ All checks passed?** → Ready to start scenario!  
**❌ Any check failed?** → Fix issues before proceeding

---

## 🎬 What Will Happen in This Scenario?

### Phase 1: Baseline (2 minutes)
- Record current state
- Note LSN positions
- Note replication status

### Phase 2: Disconnect Standby (1 minute)
- Stop standby server (`docker stop postgres-standby`)
- Simulates: Network outage, server crash, maintenance

### Phase 3: Generate Writes on Primary (5 minutes)
- Insert 30,000 rows while standby is offline
- Watch WAL accumulate (~5-6 MB)
- Primary continues operating normally

### Phase 4: Reconnect Standby (2 minutes)
- Start standby server (`docker start postgres-standby`)
- Standby automatically reconnects
- No manual `START SLAVE` needed!

### Phase 5: Watch Catch-Up (5 minutes)
- Standby streams accumulated WAL
- Standby replays missed transactions
- Verify data consistency

### Phase 6: Analysis (5 minutes)
- Compare before/after LSN positions
- Calculate WAL accumulated
- Verify no data loss

---

## 🎓 Key Learning Points

### What You'll Learn:

1. **Replication Slots Are Critical**
   - Prevent WAL deletion
   - Enable automatic recovery
   - MySQL equivalent: Binary log retention

2. **Automatic Reconnection**
   - No manual intervention needed
   - standby.signal + primary_conninfo = automatic
   - MySQL requires: `START SLAVE;`

3. **WAL Accumulation**
   - Understand WAL growth during outage
   - Monitor disk space usage
   - Know when to intervene

4. **Catch-Up Speed**
   - Measure replay performance
   - Understand network impact
   - Plan for large outages

5. **Data Consistency**
   - Verify no data loss
   - Check row counts match
   - Understand timeline consistency

---

## 🔧 Troubleshooting Common Issues

### Issue 1: Replication Slot Missing

**Symptom:**
```
 slot_name | slot_type | active 
-----------+-----------+--------
(0 rows)
```

**Fix:**
```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT pg_create_physical_replication_slot('standby_slot');"

docker restart postgres-standby
```

---

### Issue 2: Standby Not Connecting

**Symptom:**
```
 application_name | state 
------------------+-------
(0 rows)
```

**Fix:**
```bash
# Check standby logs:
docker logs postgres-standby --tail 20

# Common issues:
# - standby.signal missing
# - primary_conninfo wrong
# - replication slot missing

# Rebuild standby:
docker stop postgres-standby
docker run --rm --network postgresql-streaming-replication_postgres-network \
  -v postgresql-streaming-replication_standby-data:/backup \
  -e PGPASSWORD=replicator postgres:15 \
  sh -c "rm -rf /backup/* && \
    pg_basebackup -h postgres-primary -U replicator -D /backup -Fp -Xs -P -R"

docker start postgres-standby
```

---

### Issue 3: Large Replication Lag

**Symptom:**
```
 lag 
-----
 500 MB
```

**Fix:**
```bash
# Wait for catch-up (could take time):
watch -n 5 "docker exec postgres-primary psql -U postgres -c \
  \"SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) 
   FROM pg_stat_replication;\""

# If lag not decreasing:
# - Check network speed
# - Check standby CPU/disk
# - Check for errors in standby logs
```

---

### Issue 4: Disk Space Full

**Symptom:**
```bash
df -h
# Filesystem      Size  Used Avail Use% Mounted on
# overlay         200G  199G    1G  99% /
```

**Fix:**
```bash
# Emergency: Drop replication slot to allow WAL cleanup
docker exec postgres-primary psql -U postgres -c \
  "SELECT pg_drop_replication_slot('standby_slot');"

# Checkpoint to clean up WAL:
docker exec postgres-primary psql -U postgres -c "CHECKPOINT;"

# Then rebuild standby
```

---

## 🚀 Ready to Start?

Once all pre-requisites are met, proceed with the scenario:

1. ✅ Record baseline state
2. ✅ Stop standby server
3. ✅ Generate writes on primary
4. ✅ Monitor WAL accumulation
5. ✅ Restart standby
6. ✅ Watch catch-up process
7. ✅ Verify data consistency

**Let's begin!** 🎬

---

*Document created: November 17, 2025*  
*Purpose: Pre-flight checks and scenario overview for network interruption testing*  
*For: MySQL DBAs learning PostgreSQL replication resilience*
