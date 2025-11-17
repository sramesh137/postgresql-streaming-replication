# Scenario 04: Manual Failover - MySQL DBA Guide

**For:** MySQL DBAs Learning PostgreSQL Failover  
**Difficulty:** Intermediate  
**Your Background:** MySQL Master-Slave Failover

---

## 🔄 MySQL vs PostgreSQL Failover Comparison

### MySQL Failover Process (What You Know)

**Steps:**
```sql
-- On Slave (promoting to master):
STOP SLAVE;
RESET SLAVE ALL;
SET GLOBAL read_only = 0;

-- On Application:
-- Update connection strings to new master

-- On Old Master (if recovering):
CHANGE MASTER TO 
  MASTER_HOST='new_master_ip',
  MASTER_USER='repl_user',
  MASTER_PASSWORD='password',
  MASTER_LOG_FILE='mysql-bin.000123',
  MASTER_LOG_POS=4567;
START SLAVE;
```

**Characteristics:**
- ✓ Simple manual process
- ✓ Old master can easily become slave
- ⚠️ Risk: Split-brain if both servers accept writes
- ⚠️ Manual: Must manage `read_only` flag carefully
- ⚠️ Coordination: Need to track binlog position

---

### PostgreSQL Failover Process (New to Learn)

**Steps:**
```bash
# On Standby (promoting to primary):
pg_ctl promote
# OR
SELECT pg_promote();

# Standby automatically:
# - Exits recovery mode
# - Becomes read-write
# - Starts new timeline

# On Application:
# Update connection strings to new primary

# On Old Primary (if recovering):
# Cannot simply reconnect!
# Must use pg_rewind or rebuild from scratch
```

**Characteristics:**
- ✓ **Timeline protection** prevents split-brain
- ✓ Automatic: Standby becomes writable automatically
- ✓ Safe: Old primary cannot accidentally rejoin
- ✓ Built-in protection mechanisms
- ⚠️ Complex: Old primary needs special handling (pg_rewind)

---

## 🎯 Key Concept: Timelines (PostgreSQL Only!)

### What MySQL Does:
```
Master (binlog: mysql-bin.000123, pos: 4567)
  ↓
Slave tracks: (mysql-bin.000123, pos: 4567)

After failover:
New Master continues: mysql-bin.000124, pos: 890
Old Master can catch up from position 4567
```
**Problem:** If old master was ahead, data diverges!

---

### What PostgreSQL Does:
```
Timeline 1: Primary (LSN: 0/3000000)
  ↓
Standby tracks: Timeline 1, LSN: 0/3000000

After failover:
New Primary: Timeline 2, LSN: 0/3000100
Old Primary: Still Timeline 1, LSN: 0/3000050

Result: Old primary CANNOT rejoin (different timelines!)
```
**Benefit:** Prevents split-brain automatically!

---

## 📊 Comparison Table

| Aspect | MySQL | PostgreSQL |
|--------|-------|------------|
| **Promotion Command** | `SET GLOBAL read_only=0` | `pg_ctl promote` or `pg_promote()` |
| **Automatic Writable** | ❌ Manual flag change | ✅ Automatic after promotion |
| **Split-Brain Protection** | ❌ None (manual prevention) | ✅ Timeline mechanism |
| **Old Master Rejoin** | ✅ Easy (`CHANGE MASTER TO`) | ⚠️ Requires `pg_rewind` |
| **Position Tracking** | Binlog file + position | Timeline + LSN |
| **Failover Speed** | ~1-2 minutes (manual) | ~5-10 seconds (command-based) |
| **Application Changes** | Connection string | Connection string |
| **Data Safety** | ⚠️ Risk if mismanaged | ✅ Built-in protection |
| **Complexity** | Low (fewer steps) | Medium (timeline concept) |

**Winner**: PostgreSQL for safety, MySQL for simplicity

---

## 🎓 What You'll Learn in This Scenario

### MySQL DBA Perspective:

1. **Timeline Concept** (New!)
   - Like MySQL's binlog positions, but with version tracking
   - Prevents rejoining without explicit action

2. **Automatic Promotion** (Better!)
   - No need to manually change read_only flag
   - Standby automatically becomes writable

3. **Split-Brain Protection** (Game Changer!)
   - Built-in mechanism prevents dual-master scenario
   - Timeline mismatch blocks old primary from reconnecting

4. **pg_rewind Tool** (New!)
   - Like MySQL's "reset and resync" but smarter
   - Rewinds old primary to match new timeline

5. **Verification Steps** (Similar!)
   - Check server roles (like SHOW SLAVE STATUS)
   - Verify data consistency
   - Test write operations

---

## ⚠️ Important Warnings

### MySQL DBAs: Common Mistakes to Avoid

1. **❌ Don't assume old primary can rejoin easily**
   - MySQL: `CHANGE MASTER TO` works immediately
   - PostgreSQL: Requires `pg_rewind` or rebuild

2. **❌ Don't try to run two primaries**
   - MySQL: Both would accept writes (split-brain!)
   - PostgreSQL: Timeline prevents this, but still dangerous

3. **❌ Don't forget to update applications**
   - Both databases: Must point to new primary
   - PostgreSQL: Check `pg_is_in_recovery()` to confirm role

4. **❌ Don't skip verification**
   - Both databases: Verify writes work after failover
   - PostgreSQL: Check timeline changed

---

## 🔍 Monitoring Commands Comparison

### Check Server Role

**MySQL:**
```sql
-- On any server:
SHOW SLAVE STATUS\G
-- If empty: It's a master
-- If populated: It's a slave

SHOW VARIABLES LIKE 'read_only';
-- ON: Slave
-- OFF: Master
```

**PostgreSQL:**
```sql
-- On any server:
SELECT pg_is_in_recovery();
-- false: Primary (read-write)
-- true: Standby (read-only)

-- Check timeline:
SELECT timeline_id FROM pg_control_checkpoint();
```

---

### Check Replication Status

**MySQL (on Master):**
```sql
SHOW SLAVE HOSTS;
SHOW PROCESSLIST;  -- Look for "Binlog Dump" threads
```

**PostgreSQL (on Primary):**
```sql
SELECT * FROM pg_stat_replication;
-- If empty after promotion: No standbys connected (expected)
```

---

## 🚀 Scenario Steps Overview

We'll practice:

1. **Pre-Failover Check** (Document current state)
   - MySQL equivalent: `SHOW MASTER STATUS`, `SHOW SLAVE STATUS`

2. **Simulate Primary Failure** (Stop primary container)
   - MySQL equivalent: Stop master server

3. **Promote Standby** (Make it the new primary)
   - MySQL equivalent: `STOP SLAVE; SET GLOBAL read_only=0;`

4. **Verify Promotion** (Check new primary works)
   - MySQL equivalent: Test writes, check read_only flag

5. **Test Writes** (Confirm new primary accepts data)
   - MySQL equivalent: `INSERT INTO...` on new master

6. **Understand Timeline Change** (PostgreSQL-specific)
   - MySQL equivalent: N/A (no timeline concept)

7. **Attempt Old Primary Reconnection** (See why it fails)
   - MySQL equivalent: Would work with `CHANGE MASTER TO`

---

## 💡 Pro Tips for MySQL DBAs

### Concepts That Transfer:

✅ **Binlog Position → LSN**
- MySQL: Track (file, position)
- PostgreSQL: Track LSN (Log Sequence Number)

✅ **Master/Slave → Primary/Standby**
- Same concept, different terminology

✅ **SHOW SLAVE STATUS → pg_stat_replication**
- Similar information, different query

✅ **read_only flag → Recovery mode**
- MySQL: Manual flag
- PostgreSQL: Automatic recovery mode

### New Concepts to Learn:

📚 **Timeline** - Version tracking for database history  
📚 **pg_promote()** - Built-in promotion function  
📚 **pg_rewind** - Tool to resync old primary  
📚 **WAL** vs Binlog - Similar but different formats  

---

## ✅ Prerequisites Check

Before starting, ensure:
- [x] Scenarios 01-03 completed
- [x] Understanding of replication lag (Scenario 01)
- [x] Understanding of read distribution (Scenario 02)
- [x] Understanding of read-only enforcement (Scenario 03)
- [x] Both containers running (primary + standby)
- [x] Replication active (0 lag)

---

**Ready to start the failover process!** 🎯

**Next:** Pre-Failover Health Check
