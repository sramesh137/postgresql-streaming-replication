# MySQL DBA → PostgreSQL DBA: Replication & HA Guide

**For Senior DBAs Transitioning from MySQL to PostgreSQL**

---

## 🎯 Quick Reference: Side-by-Side Comparison

### Replication Setup

| Task | MySQL | PostgreSQL |
|------|-------|-----------|
| **Enable Replication** | `log_bin = ON` | Enabled by default (WAL) |
| **Replication User** | `GRANT REPLICATION SLAVE` | `host replication replicator` in pg_hba.conf |
| **Initial Copy** | `mysqldump` or `mysqlpump` | `pg_basebackup` |
| **Position Tracking** | Binlog file + position or GTID | LSN (automatic) |
| **Start Replica** | `CHANGE MASTER TO` + `START SLAVE` | Just start PostgreSQL (automatic) |
| **Replica Status** | `SHOW SLAVE STATUS\G` | `SELECT * FROM pg_stat_replication` |

---

## 📚 Core Concept Mapping

### 1. WAL (Write-Ahead Log) = Binlog

**MySQL:**
```sql
-- Binary log
SHOW BINARY LOGS;
SHOW BINLOG EVENTS IN 'mysql-bin.000042';

-- Position tracking
SHOW MASTER STATUS;
-- File: mysql-bin.000042, Position: 154321
```

**PostgreSQL:**
```sql
-- WAL segments (16MB each)
SELECT pg_current_wal_lsn();
-- LSN: 0/4B52BED0 (single number, no file tracking!)

-- WAL location on disk
/var/lib/postgresql/data/pg_wal/
-- Files: 00000004000000000000004B
```

**Key Differences:**
- **MySQL:** File + position (manual tracking)
- **PostgreSQL:** LSN (automatic, no manual tracking needed!)
- **MySQL GTID** ≈ PostgreSQL LSN (but LSN is simpler)

---

### 2. Replication User Setup

**MySQL:**
```sql
-- Create replication user
CREATE USER 'replicator'@'%' IDENTIFIED BY 'password';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
FLUSH PRIVILEGES;
```

**PostgreSQL:**
```bash
# 1. Create user on primary
CREATE USER replicator WITH REPLICATION PASSWORD 'password';

# 2. Configure pg_hba.conf on primary
host replication replicator 0.0.0.0/0 md5

# 3. Reload configuration
SELECT pg_reload_conf();
```

**Key Difference:** PostgreSQL uses `pg_hba.conf` for replication authentication, not SQL grants.

---

### 3. Initial Replica Setup

**MySQL:**
```bash
# 1. Backup primary
mysqldump --all-databases --master-data=2 > backup.sql

# 2. Get position from backup file
grep "CHANGE MASTER TO" backup.sql
# MASTER_LOG_FILE='mysql-bin.000042', MASTER_LOG_POS=154321

# 3. Restore on replica
mysql < backup.sql

# 4. Configure replica
CHANGE MASTER TO
  MASTER_HOST='primary.example.com',
  MASTER_USER='replicator',
  MASTER_PASSWORD='password',
  MASTER_LOG_FILE='mysql-bin.000042',
  MASTER_LOG_POS=154321;

# 5. Start replication
START SLAVE;

# 6. Check status
SHOW SLAVE STATUS\G
```

**PostgreSQL:**
```bash
# 1. One command does everything!
pg_basebackup -h primary -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R

# That's it! PostgreSQL automatically:
# - Creates full backup
# - Configures replication settings
# - Sets up recovery mode
# - Tracks LSN position

# 2. Start PostgreSQL
pg_ctl start

# Replication begins automatically!
```

**Key Difference:** PostgreSQL's `pg_basebackup` with `-R` flag does EVERYTHING automatically. No manual position tracking!

---

### 4. Monitoring Replication

**MySQL:**
```sql
SHOW SLAVE STATUS\G

Key fields:
- Slave_IO_Running: Yes
- Slave_SQL_Running: Yes
- Seconds_Behind_Master: 0
- Master_Log_File: mysql-bin.000042
- Read_Master_Log_Pos: 154321
- Exec_Master_Log_Pos: 154321
- Last_Error: (check for errors)
```

**PostgreSQL:**
```sql
-- On primary (like SHOW MASTER STATUS)
SELECT * FROM pg_stat_replication;

Key columns:
- application_name: Standby identifier
- state: streaming (=running), catchup, backup
- sent_lsn: WAL sent to standby
- write_lsn: WAL written on standby
- flush_lsn: WAL flushed to disk
- replay_lsn: WAL applied to database
- sync_state: async or sync
- replay_lag: Time behind primary

-- On standby (like SHOW SLAVE STATUS)
SELECT pg_is_in_recovery();  -- Should be 't'
SELECT pg_last_wal_replay_lsn();
SELECT pg_last_xact_replay_timestamp();
```

**Key Difference:** PostgreSQL shows replication status on PRIMARY, MySQL shows on replica.

---

### 5. Replication Lag Calculation

**MySQL:**
```sql
SHOW SLAVE STATUS\G
-- Look at: Seconds_Behind_Master

-- Or calculate from position difference
Master: mysql-bin.000042, Position: 200000
Slave:  mysql-bin.000042, Position: 195000
Lag: 5000 bytes (but no direct time calculation)
```

**PostgreSQL:**
```sql
-- On primary: Lag in bytes
SELECT 
    application_name,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes
FROM pg_stat_replication;

-- Lag in time (built-in!)
SELECT 
    application_name,
    replay_lag AS lag_time
FROM pg_stat_replication;

-- On standby: Time since last replay
SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds;
```

**Key Difference:** PostgreSQL has built-in `replay_lag` in time units!

---

### 6. Failover / Promotion

**MySQL:**
```bash
# Manual failover process:

# 1. On replica: Stop replication
STOP SLAVE;

# 2. Check replica is caught up
SHOW SLAVE STATUS\G
# Verify: Seconds_Behind_Master: 0

# 3. Make replica read-write
SET GLOBAL read_only = OFF;
SET GLOBAL super_read_only = OFF;

# 4. Reset replica metadata
RESET SLAVE ALL;

# 5. Update application to point to new primary
# (Manual configuration change)

# 6. OLD PRIMARY: If coming back online
# Must become replica of new primary:
CHANGE MASTER TO
  MASTER_HOST='new-primary',
  MASTER_USER='replicator',
  MASTER_PASSWORD='password',
  MASTER_AUTO_POSITION=1;  -- If using GTID
START SLAVE;
```

**PostgreSQL:**
```bash
# Automatic failover - ONE COMMAND!

# 1. Promote standby to primary
pg_ctl promote
# OR from SQL:
SELECT pg_promote();

# PostgreSQL automatically:
# - Exits recovery mode
# - Creates new timeline (prevents split-brain!)
# - Becomes read-write
# - Ready to accept writes

# 2. Update application connection strings
# (Same as MySQL)

# 3. OLD PRIMARY: Must be rebuilt as new standby
# Cannot rejoin automatically due to timeline safety
pg_basebackup -h new-primary -U replicator -D /data -R
```

**Key Differences:**
- **MySQL:** 5+ steps, manual configuration
- **PostgreSQL:** ONE command (`pg_promote()`)
- **PostgreSQL Timeline:** Prevents split-brain automatically
- **MySQL:** No built-in split-brain protection

---

### 7. Synchronous vs Asynchronous Replication

**MySQL:**
```sql
-- Asynchronous (default)
# No configuration needed

-- Semi-Synchronous (requires plugin)
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
SET GLOBAL rpl_semi_sync_master_enabled = 1;
SET GLOBAL rpl_semi_sync_master_wait_for_slave_count = 1;

-- On replica:
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';
SET GLOBAL rpl_semi_sync_slave_enabled = 1;
```

**PostgreSQL:**
```sql
-- Asynchronous (default)
# No configuration needed

-- Synchronous (built-in, no plugins!)
-- On primary:
ALTER SYSTEM SET synchronous_standby_names = 'standby1';
SELECT pg_reload_conf();

-- On standby: Give it a name
ALTER SYSTEM SET primary_conninfo = '... application_name=standby1';

-- Verify
SELECT sync_state FROM pg_stat_replication;  -- Should show 'sync'
```

**Key Differences:**
- **MySQL:** Requires plugin installation
- **PostgreSQL:** Built-in, just configuration
- **PostgreSQL:** More granular control (FIRST, ANY, ALL)

---

### 8. Replication Slots (PostgreSQL Only!)

**MySQL Equivalent:** None! This is a PostgreSQL superpower.

**Problem:** Without replication slots:
```
Primary: "Replica is slow? I'll delete old binlogs to save space."
Replica comes back: "I need binlog.000035!"
Primary: "Sorry, I deleted it. You need full rebuild."
Result: 4-hour downtime for 2TB database rebuild ❌
```

**PostgreSQL Solution:**
```sql
-- Create replication slot on primary
SELECT pg_create_physical_replication_slot('standby_slot');

-- Standby uses the slot
-- In postgresql.auto.conf:
primary_slot_name = 'standby_slot'

-- Primary keeps WAL until standby consumes it!
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;

-- Result: Zero-touch recovery after network outages ✅
```

**Real Example from Today:**
```
Standby offline: 4 minutes
WAL accumulated: 921 KB
Reconnect time: < 1 second
Manual steps: ZERO
```

In MySQL, you'd need to:
1. Check binlog position manually
2. Ensure binlogs not deleted
3. Possibly rebuild replica

---

### 9. Network Interruption Recovery

**MySQL:**
```bash
# Replica reconnects but may fail:
SHOW SLAVE STATUS\G
-- Last_IO_Error: Got fatal error 1236 from master
-- Binlog has been purged!

# Solution: Rebuild replica
mysqldump --master-data=2 | mysql
# or use Percona XtraBackup
```

**PostgreSQL:**
```bash
# Replica reconnects automatically
# Primary kept WAL via replication slot
# Catch-up happens automatically
# NO MANUAL INTERVENTION NEEDED!

# Verify:
SELECT * FROM pg_stat_replication;
-- state: streaming, lag: 0 bytes ✅
```

**Interview Answer:**
> *"A major advantage of PostgreSQL replication slots is automatic recovery from network interruptions. When we disconnected a standby for 4 minutes, the primary retained 921 KB of WAL. Upon reconnection, the standby caught up in under 1 second with zero manual intervention. In MySQL, if binlogs were purged, we'd need to rebuild the replica from scratch."*

---

### 10. Common Errors & Troubleshooting

| Error | MySQL | PostgreSQL |
|-------|-------|-----------|
| **Replica not starting** | Check `SHOW SLAVE STATUS\G` for Last_Error | Check `docker logs` or `/var/log/postgresql/` |
| **Replication lag** | `Seconds_Behind_Master` | `replay_lag` column |
| **Position mismatch** | `CHANGE MASTER TO` with correct position | Automatic via LSN, no manual tracking |
| **Binlog/WAL purged** | Rebuild replica | Prevented by replication slots |
| **Split-brain** | No built-in protection | Timeline prevents automatic rejoin |
| **Authentication failed** | Check `GRANT REPLICATION SLAVE` | Check `pg_hba.conf` |

---

## 🚨 Critical Differences MySQL DBAs MUST Know

### 1. No `CHANGE MASTER TO` in PostgreSQL!

**MySQL Muscle Memory:**
```sql
CHANGE MASTER TO
  MASTER_HOST='primary',
  MASTER_LOG_FILE='mysql-bin.000042',
  MASTER_LOG_POS=154321;
```

**PostgreSQL Way:**
```bash
# pg_basebackup with -R flag creates recovery config automatically!
pg_basebackup -h primary -U replicator -D /data -R

# Configuration is in postgresql.auto.conf (automatic)
primary_conninfo = 'host=primary user=replicator password=xxx'
# NO manual LSN position needed!
```

### 2. Timeline Safety (Prevents Split-Brain)

**MySQL:**
```
Primary fails → Promote Replica A → Old Primary restarts
Old Primary: "I'm still the primary!" 
Replica B: "I'll follow old primary!"
Result: Split-brain! Two primaries accepting writes! 💥
```

**PostgreSQL:**
```
Primary (Timeline 3) fails → Promote Standby (Timeline 4)
Old Primary restarts: "I'm Timeline 3"
Standby: "I'm Timeline 4 now, you're outdated!"
Result: Old primary CANNOT rejoin automatically ✅
         Must be rebuilt to prevent data corruption
```

**Production Impact:** PostgreSQL's timeline prevents accidental split-brain.

### 3. Synchronous Replication Trap (TODAY'S LESSON!)

**The Problem:**
```sql
-- Primary is configured for sync replication
synchronous_standby_names = 'standby1'

-- Primary crashes, you promote standby
SELECT pg_promote();  -- Success!

-- Try to write:
INSERT INTO orders VALUES (...);
-- HANGS! Waiting for 'standby1' (the dead primary) to acknowledge!
```

**The Fix (MUST be in failover runbook!):**
```sql
-- Immediately after promotion:
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
-- Now writes work!
```

**MySQL Equivalent:** Similar issue with semi-sync, but less common.

### 4. Read-Only Enforcement

**MySQL:**
```sql
-- On replica
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;  -- Blocks even SUPER users

-- But can be changed accidentally:
SET GLOBAL read_only = OFF;  -- Oops! Now accepting writes on replica!
```

**PostgreSQL:**
```sql
-- Standby is ALWAYS read-only (recovery mode)
-- Cannot be changed while in recovery mode
SELECT pg_is_in_recovery();  -- 't' = read-only, immutable!

-- Any write attempt:
INSERT INTO orders VALUES (...);
ERROR: cannot execute INSERT in a read-only transaction

-- No way to accidentally make it writable while in recovery
```

**Production Safety:** PostgreSQL standby cannot accidentally accept writes.

---

## 💼 Interview Questions & Answers

### Q1: "What's the biggest difference between MySQL and PostgreSQL replication?"

**Answer:**
> "The biggest difference is automatic position tracking. In MySQL, you manually track binlog file and position or use GTID. In PostgreSQL, LSN (Log Sequence Number) tracking is completely automatic. When setting up a replica, pg_basebackup with the -R flag configures everything—you never specify a position manually. 
>
> Additionally, PostgreSQL's replication slots ensure the primary retains WAL until replicas consume it, preventing the 'binlog has been purged' error that requires full replica rebuilds in MySQL. This saved us 4 hours of downtime during a network interruption."

### Q2: "How do you handle failover in PostgreSQL vs MySQL?"

**Answer:**
> "PostgreSQL failover is significantly simpler. In MySQL, you need 5+ steps: STOP SLAVE, verify lag, SET GLOBAL read_only=OFF, RESET SLAVE ALL, then update applications. 
>
> In PostgreSQL, it's one command: `SELECT pg_promote()`. PostgreSQL automatically exits recovery mode, becomes writable, and creates a new timeline to prevent split-brain. 
>
> However, there's a critical gotcha: if the new primary was configured for synchronous replication, you must immediately run `ALTER SYSTEM SET synchronous_standby_names = ''` or writes will hang waiting for the dead primary. We experienced this in a DR drill—writes blocked on 'SyncRep' wait event until we disabled sync replication. It's now step 3 in our failover runbook."

### Q3: "What happens when a replica loses network connection to the primary?"

**Answer:**
> "In MySQL, if binlogs are purged before the replica reconnects, you get 'Got fatal error 1236: binlog has been purged' and must rebuild the replica—typically 2-4 hours for large databases.
>
> In PostgreSQL, replication slots prevent this. When we disconnected a standby for 4 minutes during a test, the primary's replication slot retained 921 KB of WAL. Upon reconnection, the standby automatically caught up in under 1 second with zero manual intervention. No position tracking, no manual CHANGE MASTER TO, no replica rebuild needed."

### Q4: "How do you monitor replication lag?"

**Answer:**
> "In MySQL, I use `SHOW SLAVE STATUS` and check `Seconds_Behind_Master`. For more accuracy, I compare binlog positions.
>
> In PostgreSQL, monitoring is done on the PRIMARY with `SELECT * FROM pg_stat_replication`. It provides both byte lag (`pg_wal_lsn_diff(sent_lsn, replay_lsn)`) and built-in time lag (`replay_lag` column). 
>
> Key advantage: PostgreSQL's replay_lag is built-in and accurate, whereas MySQL's Seconds_Behind_Master can be misleading with long-running transactions.
>
> For capacity planning, I also track WAL generation rate: we found 100,000 inserts generate ~17 MB of WAL, so at 5,000 TPS, we need ~850 KB/sec network bandwidth with 50% buffer."

### Q5: "Explain PostgreSQL timelines and why they matter."

**Answer:**
> "Timelines are PostgreSQL's built-in split-brain protection—something MySQL lacks. Every time you promote a standby, PostgreSQL increments the timeline (e.g., Timeline 3 → Timeline 4).
>
> If the old primary restarts, it sees it's on Timeline 3 while the new primary is on Timeline 4. PostgreSQL prevents the old primary from automatically rejoining because they've diverged. This forces you to make a conscious decision: rebuild the old primary as a new standby or recover it manually.
>
> In our DR drill, after promoting the standby from Timeline 3 to Timeline 4, the old primary couldn't rejoin without pg_basebackup. This prevented split-brain where both servers accept writes and cause data divergence. MySQL requires external tools like MHA or Orchestrator for equivalent protection."

---

## 📊 Command Cheat Sheet

### Daily Operations

| Task | MySQL Command | PostgreSQL Command |
|------|--------------|-------------------|
| **Check if server is replica** | `SHOW SLAVE STATUS\G` | `SELECT pg_is_in_recovery();` |
| **View replication status** | `SHOW SLAVE STATUS\G` | `SELECT * FROM pg_stat_replication;` (on primary) |
| **Check lag** | `Seconds_Behind_Master` | `SELECT replay_lag FROM pg_stat_replication;` |
| **Current position** | `SHOW MASTER STATUS;` | `SELECT pg_current_wal_lsn();` |
| **Last replayed position** | N/A (on master) | `SELECT pg_last_wal_replay_lsn();` (on standby) |
| **Stop replication** | `STOP SLAVE;` | PostgreSQL stops when primary stops (automatic) |
| **Start replication** | `START SLAVE;` | Starts automatically when PostgreSQL starts |
| **Promote replica** | `STOP SLAVE; SET GLOBAL read_only=OFF;` | `SELECT pg_promote();` |
| **Reset replication** | `RESET SLAVE ALL;` | Remove `standby.signal` file |

### Troubleshooting

| Issue | MySQL | PostgreSQL |
|-------|-------|-----------|
| **View errors** | `SHOW SLAVE STATUS\G` → Last_Error | `tail -f /var/log/postgresql/postgresql.log` |
| **Skip error** | `SET GLOBAL sql_slave_skip_counter=1;` | Fix on primary, replay automatically |
| **Check connectivity** | `mysql -h primary -u replicator -p` | `psql -h primary -U replicator -c "SELECT 1"` |
| **View WAL/binlog files** | `SHOW BINARY LOGS;` | `ls -lh /var/lib/postgresql/data/pg_wal/` |
| **Calculate lag bytes** | Manual (compare positions) | `pg_wal_lsn_diff(sent_lsn, replay_lsn)` |

---

## 🎯 Production Best Practices

### MySQL → PostgreSQL Migration Tips

1. **Always use replication slots**
   ```sql
   SELECT pg_create_physical_replication_slot('standby_slot');
   ```
   Prevents WAL deletion, no equivalent in MySQL.

2. **Monitor WAL accumulation**
   ```sql
   SELECT 
       slot_name,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
   FROM pg_replication_slots;
   ```
   Alert if > 10 GB (primary disk could fill).

3. **Disable sync replication after failover**
   ```sql
   ALTER SYSTEM SET synchronous_standby_names = '';
   SELECT pg_reload_conf();
   ```
   MUST be in failover runbook!

4. **Use pg_basebackup with -R flag**
   ```bash
   pg_basebackup -h primary -U replicator -D /data -Fp -Xs -P -R
   ```
   Automatic configuration, no manual position tracking.

5. **Test failovers monthly**
   ```bash
   # DR drill script:
   1. SELECT pg_promote();
   2. ALTER SYSTEM SET synchronous_standby_names = '';
   3. SELECT pg_reload_conf();
   4. Test writes
   5. Document RTO/RPO
   ```

6. **Monitor on PRIMARY, not standby**
   ```sql
   SELECT * FROM pg_stat_replication;
   ```
   Unlike MySQL's SHOW SLAVE STATUS (on replica).

---

## 📚 Further Reading

**PostgreSQL Documentation:**
- [Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION)
- [High Availability](https://www.postgresql.org/docs/current/high-availability.html)
- [Replication Slots](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS)

**MySQL Comparison:**
- [MySQL Replication](https://dev.mysql.com/doc/refman/8.0/en/replication.html)
- [MySQL Semi-Sync](https://dev.mysql.com/doc/refman/8.0/en/replication-semisync.html)

---

## ✅ Readiness Checklist for Interviews

**Can you explain:**
- [ ] PostgreSQL LSN vs MySQL binlog position?
- [ ] How replication slots prevent data loss?
- [ ] Timeline concept and split-brain prevention?
- [ ] Synchronous replication trap after failover?
- [ ] Why PostgreSQL failover is simpler (pg_promote())?
- [ ] Network interruption recovery (automatic in PostgreSQL)?
- [ ] Monitoring replication on primary vs replica?
- [ ] WAL generation rate for capacity planning?

**Can you demonstrate:**
- [ ] Set up replication with pg_basebackup?
- [ ] Monitor lag with pg_stat_replication?
- [ ] Perform failover with pg_promote()?
- [ ] Fix synchronous replication issue after failover?
- [ ] Calculate WAL generation for capacity planning?

---

**You're now ready to confidently discuss PostgreSQL replication in senior DBA interviews!** 🎉

*Key Advantage: PostgreSQL's automated position tracking, replication slots, and timeline safety make it more reliable and easier to manage than traditional MySQL replication.*
