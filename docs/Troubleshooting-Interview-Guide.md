# Troubleshooting Scenarios for PostgreSQL Replication - Interview Guide

**Target Audience:** Backend/Database Engineers  
**Difficulty:** Mid to Senior Level  
**Purpose:** Common production issues and how to diagnose/fix them

---

## 📋 Table of Contents

1. [Scenario 1: Replication Lag](#scenario-1-replication-lag)
2. [Scenario 2: Standby Won't Connect](#scenario-2-standby-wont-connect)
3. [Scenario 3: Disk Space Full on Primary](#scenario-3-disk-space-full-on-primary)
4. [Scenario 4: Synchronous Standby Down - Writes Blocked](#scenario-4-synchronous-standby-down---writes-blocked)
5. [Scenario 5: Standby Diverged from Primary](#scenario-5-standby-diverged-from-primary)
6. [Scenario 6: Replication Slot Not Advancing](#scenario-6-replication-slot-not-advancing)
7. [Scenario 7: High CPU on Standby](#scenario-7-high-cpu-on-standby)
8. [Scenario 8: Application Reads Stale Data](#scenario-8-application-reads-stale-data)
9. [Scenario 9: Failover Doesn't Complete](#scenario-9-failover-doesnt-complete)
10. [Scenario 10: Connection Pool Exhaustion](#scenario-10-connection-pool-exhaustion)

---

## Scenario 1: Replication Lag

### 🔴 Problem
> "Our standby is lagging 10GB behind the primary. Reads are returning stale data from 30 minutes ago. What do you do?"

### 🔍 Diagnosis

**Step 1: Quantify the lag**
```sql
-- On PRIMARY
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / 1024 / 1024 AS lag_mb,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

**Expected output with issue:**
```
 application_name | lag_bytes  | lag_mb |  replay_lag  
------------------+------------+--------+--------------
 walreceiver      | 10737418240| 10240  | 00:30:45.123
```

**Step 2: Check network bandwidth**
```bash
# On standby server
iftop -i eth0   # Check network usage
netstat -s | grep -i retrans   # Check for packet retransmissions
```

**Step 3: Check standby resource usage**
```bash
# CPU and I/O
top
iostat -x 1

# Disk write speed
sudo dd if=/dev/zero of=/var/lib/postgresql/test.tmp bs=1M count=1000 oflag=direct
```

**Step 4: Check for long-running queries on standby**
```sql
-- On STANDBY
SELECT pid, usename, state, query_start, 
       now() - query_start AS duration, query
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC;
```

### 💡 Root Causes

**1. Network Bottleneck**
- Symptom: Low bandwidth, high packet loss
- Solution: Upgrade network, enable WAL compression

**2. Slow Disk on Standby**
- Symptom: High `iostat` await times (>20ms)
- Solution: Upgrade to SSD, increase `checkpoint_completion_target`

**3. Hot Standby Queries Blocking Replay**
- Symptom: Long-running queries on standby
- Solution: Enable `hot_standby_feedback` or set `max_standby_streaming_delay`

**4. Insufficient CPU on Standby**
- Symptom: High CPU usage (>90%)
- Solution: Scale up standby hardware

### ✅ Solutions

**Quick Fix: Enable WAL compression**
```sql
-- On PRIMARY
ALTER SYSTEM SET wal_compression = on;
SELECT pg_reload_conf();
```
**Result:** Reduces network traffic by 30-50%

**Medium Fix: Adjust standby settings**
```sql
-- On STANDBY
ALTER SYSTEM SET max_standby_streaming_delay = '60s';  -- Kill blocking queries
ALTER SYSTEM SET hot_standby_feedback = on;             -- Prevent query conflicts
SELECT pg_reload_conf();
```

**Long-term Fix: Scale infrastructure**
- Upgrade standby to match primary specs
- Use faster network (1Gbps → 10Gbps)
- Enable synchronous replication for critical data

### 📊 Interview Answer Template

> "First, I'd quantify the lag using `pg_stat_replication` to see the byte difference and time lag. Then I'd investigate three main areas:
> 
> 1. **Network** - Check bandwidth and packet loss. If network is the bottleneck, enable `wal_compression` for immediate relief.
> 
> 2. **Standby Resources** - Check CPU and disk I/O. Slow disks are a common cause. Use `iostat` to measure disk latency.
> 
> 3. **Query Conflicts** - Long-running queries on the standby can block WAL replay. Enable `hot_standby_feedback` or set `max_standby_streaming_delay` to kill blocking queries.
> 
> In production, I'd also look at historical metrics to see if this is a new issue or recurring pattern, which would inform whether we need infrastructure scaling."

---

## Scenario 2: Standby Won't Connect

### 🔴 Problem
> "After setting up replication, the standby won't connect. It keeps retrying. How do you troubleshoot?"

### 🔍 Diagnosis

**Step 1: Check standby logs**
```bash
docker logs postgres-standby --tail 50
# Or on server:
tail -f /var/log/postgresql/postgresql-15-main.log
```

**Common error messages:**

**Error 1: Authentication failed**
```
FATAL: password authentication failed for user "replicator"
```

**Error 2: No pg_hba.conf entry**
```
FATAL: no pg_hba.conf entry for replication connection from host "172.19.0.3"
```

**Error 3: Connection refused**
```
could not connect to server: Connection refused
Is the server running on host "postgres-primary" (172.19.0.2) and accepting connections?
```

**Error 4: Replication slot not found**
```
ERROR: replication slot "standby_slot" does not exist
```

### 💡 Solutions by Error Type

**Solution 1: Fix Authentication**
```sql
-- On PRIMARY: Verify replicator user exists
\du replicator

-- Create if missing:
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'secure_password';

-- Verify pg_hba.conf allows replication connections:
# On PRIMARY
cat /var/lib/postgresql/data/pg_hba.conf | grep replication
```

Should contain:
```
host    replication    replicator    172.19.0.0/24    scram-sha-256
```

**Solution 2: Fix pg_hba.conf**
```sql
-- On PRIMARY
ALTER SYSTEM SET listen_addresses = '*';
SELECT pg_reload_conf();
```

Add to `pg_hba.conf`:
```
host    replication    replicator    <standby_ip>/32    scram-sha-256
```

Then reload:
```bash
docker exec postgres-primary psql -U postgres -c "SELECT pg_reload_conf();"
```

**Solution 3: Fix Network/DNS**
```bash
# From standby container, test connectivity:
docker exec postgres-standby ping postgres-primary
docker exec postgres-standby nc -zv postgres-primary 5432

# Check if primary is listening:
docker exec postgres-primary netstat -tlnp | grep 5432
```

**Solution 4: Create Replication Slot**
```sql
-- On PRIMARY
SELECT pg_create_physical_replication_slot('standby_slot');

-- Verify:
SELECT slot_name, slot_type, active FROM pg_replication_slots;
```

### 📊 Interview Answer

> "I'd start by checking the standby logs for specific error messages. The most common issues are:
> 
> 1. **Authentication** - Wrong password or user doesn't exist. Verify the replicator user and check `pg_hba.conf` allows replication connections from the standby's IP.
> 
> 2. **Network** - Use `ping` and `nc` to verify connectivity. Check firewalls and DNS resolution.
> 
> 3. **Configuration** - Verify `primary_conninfo` in standby's config has correct host, port, and credentials. Check if replication slot exists if configured.
> 
> The systematic approach is: logs first, then test connectivity, then verify authentication, finally check configuration files."

---

## Scenario 3: Disk Space Full on Primary

### 🔴 Problem
> "Primary disk is 95% full. WAL files consuming 200GB. What's happening and how do you fix it?"

### 🔍 Diagnosis

**Step 1: Check disk usage**
```bash
df -h /var/lib/postgresql/data
du -sh /var/lib/postgresql/data/pg_wal/*
```

**Step 2: Check replication slots**
```sql
-- On PRIMARY
SELECT 
    slot_name,
    slot_type,
    active,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1024 / 1024 AS retained_mb,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) / 1024 / 1024 AS pending_mb
FROM pg_replication_slots;
```

**Problem indicators:**
```
 slot_name    | active | retained_mb 
--------------+--------+-------------
 standby_slot | f      | 204800       -- 200GB retained!
```

**Step 3: Check for disconnected standbys**
```sql
SELECT * FROM pg_stat_replication;  -- Should show connected standbys
```

### 💡 Root Causes

1. **Inactive replication slot** - Standby disconnected, but slot prevents WAL deletion
2. **Standby too slow** - Can't keep up with WAL generation
3. **No standby connected** - Slot created but no standby exists

### ✅ Solutions

**Emergency Fix: Drop inactive slot (DATA LOSS WARNING!)**
```sql
-- On PRIMARY
-- ⚠️ This will prevent standby from catching up!
SELECT pg_drop_replication_slot('standby_slot');
```

**Better Fix: Reconnect or rebuild standby**
```bash
# Option 1: If standby is just disconnected, restart it
docker-compose restart postgres-standby

# Option 2: If standby is too far behind, rebuild from scratch
bash scripts/setup-replication.sh
```

**Prevention: Set max_slot_wal_keep_size**
```sql
-- On PRIMARY (PostgreSQL 13+)
ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';
SELECT pg_reload_conf();
```
This limits WAL retention, but may cause standby to lose connection if lag exceeds limit.

**Monitoring Alert:**
```sql
-- Create this as a monitoring query:
SELECT 
    slot_name,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1024 / 1024 AS retained_mb
FROM pg_replication_slots
WHERE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1024 / 1024 > 10000;  -- Alert if >10GB
```

### 📊 Interview Answer

> "Disk full on the primary is critical - it can cause the database to stop accepting writes. First, I'd check `pg_replication_slots` to see if there's an inactive slot preventing WAL deletion. This happens when a standby disconnects but the slot remains.
> 
> If I find an inactive slot retaining 200GB of WAL, I have two options:
> 
> 1. **Quick fix** - Drop the slot with `pg_drop_replication_slot()`. This frees disk immediately but means the standby can't catch up and must be rebuilt.
> 
> 2. **Better fix** - Reconnect the standby if possible, or rebuild it from scratch with `pg_basebackup`.
> 
> For prevention, I'd set `max_slot_wal_keep_size` to limit WAL retention and create alerts when retained WAL exceeds a threshold like 10GB. I'd also monitor standby lag daily to catch issues before they become critical."

---

## Scenario 4: Synchronous Standby Down - Writes Blocked

### 🔴 Problem
> "We enabled synchronous replication for zero data loss. Now the synchronous standby crashed and all writes are blocked. The application is down. What do you do?"

### 🔍 Current State

**Symptom:** All INSERT/UPDATE/DELETE commands hang indefinitely

**Verification:**
```sql
-- On PRIMARY
SHOW synchronous_standby_names;  -- Returns: 'walreceiver'

SELECT application_name, sync_state FROM pg_stat_replication;
-- walreceiver is missing (standby down)
```

### 💡 Root Cause

Synchronous replication waits for standby acknowledgment before commit completes. If standby is down, PRIMARY can't complete transactions.

### ✅ Solutions (Ordered by Impact)

**Option 1: IMMEDIATE - Disable sync replication (allows data loss)**
```sql
-- On PRIMARY (emergency - restores writes immediately)
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
```
**Result:** Writes work immediately, but potential data loss if primary crashes

**Option 2: FAST - Switch to another standby**
```sql
-- If you have multiple standbys
ALTER SYSTEM SET synchronous_standby_names = 'walreceiver2';  -- Use STANDBY2
SELECT pg_reload_conf();
```
**Result:** Writes work, zero data loss continues

**Option 3: MEDIUM - Use FIRST or ANY for multiple standbys**
```sql
-- Better configuration for HA
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (walreceiver, walreceiver2)';
SELECT pg_reload_conf();
```
**Result:** Waits for ANY one standby - more resilient

**Option 4: SLOW - Repair the synchronous standby**
```bash
# Fix the crashed standby
docker-compose restart postgres-standby
```

### 📊 Interview Answer

> "This is a classic synchronous replication problem - high consistency comes with availability risk. The situation is critical because the application is completely down.
> 
> **Immediate action (30 seconds):**
> Set `synchronous_standby_names = ''` to restore writes immediately. This temporarily sacrifices zero-data-loss guarantee for availability.
> 
> **Short-term (5 minutes):**
> If we have multiple standbys, switch to `FIRST 1 (standby1, standby2)` configuration so ANY one standby satisfies the sync requirement.
> 
> **Medium-term (1 hour):**
> Repair the failed standby and restore it to the replication pool.
> 
> **Long-term:**
> This highlights why synchronous replication should be used carefully. For production, I'd recommend:
> - Always configure FIRST 1 with multiple standbys (never depend on single standby)
> - Use sync replication ONLY for critical transactions (e.g., financial data)
> - Most apps can tolerate async replication with good monitoring
> - Implement proper monitoring with alerts when sync standbys disconnect
> 
> The key lesson: Synchronous replication trades availability for consistency. Design accordingly."

---

## Scenario 5: Standby Diverged from Primary

### 🔴 Problem
> "After a crash and restart, the standby is in recovery mode but data doesn't match the primary. We have data inconsistency. How did this happen and how do you fix it?"

### 🔍 Diagnosis

**Check timeline:**
```sql
-- On PRIMARY
SELECT pg_controldata('/var/lib/postgresql/data')::text LIKE '%Timeline:%';

-- On STANDBY
SELECT pg_controldata('/var/lib/postgresql/data')::text LIKE '%Timeline:%';
```

**Check WAL position:**
```sql
-- On PRIMARY
SELECT pg_current_wal_lsn();

-- On STANDBY
SELECT pg_last_wal_replay_lsn();
```

**Different timelines = divergence!**

### 💡 Root Cause

**Most common scenarios:**

1. **Standby was promoted, then primary came back**
   - Two masters existed temporarily
   - Split-brain scenario

2. **Standby had old backup restored**
   - Restored from old backup point
   - Doesn't follow primary's timeline

3. **WAL corruption**
   - Disk failure on standby
   - Corrupted WAL files

### ✅ Solution

**No recovery possible - Must rebuild standby:**

```bash
# Step 1: Stop standby
docker-compose stop postgres-standby

# Step 2: Remove old data
docker volume rm postgresql-streaming-replication_standby-data

# Step 3: Recreate from fresh backup
docker-compose up -d postgres-standby
bash scripts/setup-replication.sh
```

**Verification:**
```sql
-- On PRIMARY
SELECT application_name, state FROM pg_stat_replication;
-- Should show standby connected

-- On STANDBY
SELECT pg_last_wal_replay_lsn();
-- Should be close to primary's pg_current_wal_lsn()
```

### 🛡️ Prevention

**1. Use replication slots**
```sql
SELECT pg_create_physical_replication_slot('standby_slot');
```

**2. Implement proper failover tools**
- Use Patroni, repmgr, or Pgpool-II
- These prevent split-brain scenarios

**3. Monitor timeline changes**
```sql
-- Alert if timeline changes unexpectedly
SELECT timeline_id FROM pg_control_checkpoint();
```

### 📊 Interview Answer

> "Data divergence is serious - it means the standby is no longer a valid replica. This typically happens in split-brain scenarios where both primary and standby accepted writes, or if the standby was restored from an old backup.
> 
> **Diagnosis:**
> Check timelines on both servers using `pg_controldata`. Different timelines indicate divergence.
> 
> **Solution:**
> Unfortunately, there's no automatic reconciliation. The standby must be completely rebuilt from a fresh `pg_basebackup` of the primary. Any data on the diverged standby is lost.
> 
> **Prevention:**
> - Use proper HA tools like Patroni that prevent split-brain
> - Implement fencing to ensure old primary can't accept writes after failover
> - Use replication slots to ensure standby doesn't fall too far behind
> - Have monitoring alerts for timeline changes
> 
> This is why proper failover procedures are critical - manual failover without proper procedures can lead to divergence."

---

## Scenario 6: Replication Slot Not Advancing

### 🔴 Problem
> "The replication slot shows `active = t` but the `restart_lsn` hasn't advanced in hours. Standby appears to be receiving data. What's wrong?"

### 🔍 Diagnosis

```sql
-- On PRIMARY
SELECT 
    slot_name,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1024 / 1024 AS gap_mb
FROM pg_replication_slots;
```

**Problem indicator:**
```
 slot_name    | active | restart_lsn | gap_mb 
--------------+--------+-------------+--------
 standby_slot | t      | 0/3000000   | 15360   -- Not advancing!
```

**Check standby status:**
```sql
SELECT * FROM pg_stat_replication;
```

### 💡 Root Causes

**1. Logical replication slot with no subscriber**
- Slot exists but nothing is consuming from it
- Solution: Drop unused slot or start subscriber

**2. Hot standby feedback enabled with long queries**
- Standby queries prevent vacuum on primary
- Slot doesn't advance due to old transactions

**3. Prepared transactions not committed**
```sql
-- Check for prepared transactions
SELECT * FROM pg_prepared_xacts;
```

### ✅ Solutions

**Solution 1: Identify and fix long-running queries**
```sql
-- On STANDBY
SELECT pid, now() - query_start AS duration, query
FROM pg_stat_activity
WHERE state != 'idle' AND now() - query_start > interval '1 hour'
ORDER BY duration DESC;

-- Kill blocking queries
SELECT pg_terminate_backend(pid) FROM pg_stat_activity 
WHERE pid = <problem_pid>;
```

**Solution 2: Resolve prepared transactions**
```sql
-- Commit or rollback prepared transactions
COMMIT PREPARED 'transaction_id';
-- or
ROLLBACK PREPARED 'transaction_id';
```

**Solution 3: If slot is truly stuck, recreate it**
```bash
# This requires rebuilding the standby!
docker exec postgres-primary psql -U postgres << 'EOF'
SELECT pg_drop_replication_slot('standby_slot');
SELECT pg_create_physical_replication_slot('standby_slot');
EOF

# Rebuild standby
bash scripts/setup-replication.sh
```

### 📊 Interview Answer

> "A replication slot not advancing despite being active usually indicates the standby can't acknowledge WAL receipt, often due to long-running queries or prepared transactions.
> 
> I'd check `pg_stat_activity` on the standby for queries running longer than expected. With `hot_standby_feedback` enabled, long queries on the standby can prevent the primary from advancing the slot.
> 
> I'd also check for prepared transactions using `pg_prepared_xacts` - these can block advancement until committed or rolled back.
> 
> If the slot is genuinely stuck, the last resort is to drop and recreate it, but this requires rebuilding the standby from scratch."

---

## Scenario 7: High CPU on Standby

### 🔴 Problem
> "Standby CPU is at 100% constantly, but we're barely running any queries on it. Primary is fine. What could cause this?"

### 🔍 Diagnosis

**Check processes:**
```bash
top
# Look for postgres processes consuming CPU
```

**Check active queries:**
```sql
-- On STANDBY
SELECT pid, state, query, now() - query_start AS duration
FROM pg_stat_activity
WHERE state = 'active';
```

**Check WAL replay rate:**
```sql
SELECT pg_last_wal_replay_lsn(), now();
-- Run again after 10 seconds
SELECT pg_last_wal_replay_lsn(), now();
-- Calculate replay speed
```

### 💡 Root Causes

**1. Hot standby replay conflicts**
- Primary doing heavy DELETEs/UPDATEs
- Standby must replay all these operations
- Solution: This is expected - scale up hardware

**2. Excessive WAL generation on primary**
```sql
-- On PRIMARY
SELECT * FROM pg_stat_bgwriter;
-- High buffers_backend indicates heavy writes
```

**3. Long-running transactions being replayed**
- Bulk updates with millions of rows
- Each row change must be replayed

**4. Checkpoint timing issues**
```sql
-- Check checkpoint frequency
SELECT * FROM pg_stat_bgwriter;
```

### ✅ Solutions

**Solution 1: Tune checkpoint settings**
```sql
-- On STANDBY
ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
SELECT pg_reload_conf();
```

**Solution 2: Increase hardware**
- Standby should have similar specs to primary
- Consider scaling up CPU if consistently high

**Solution 3: Reduce load on primary**
- Batch large operations during off-peak hours
- Optimize heavy write queries

**Solution 4: Check for conflicts**
```sql
-- On STANDBY
SELECT * FROM pg_stat_database_conflicts;
```

### 📊 Interview Answer

> "High CPU on standby during WAL replay is often normal - it needs to replay all operations from the primary. However, 100% CPU is concerning.
> 
> I'd first verify this is actually WAL replay by checking the process list. If it's a postgres WAL receiver/startup process, then the standby is working hard to apply changes.
> 
> Common causes:
> - Primary doing heavy write operations (bulk updates/deletes)
> - Checkpoint settings too aggressive on standby
> - Standby hardware weaker than primary
> 
> Solutions depend on the cause. If the primary is doing legitimate heavy writes, the standby needs matching hardware. If it's checkpoint-related, I'd tune `checkpoint_timeout` and `checkpoint_completion_target`.
> 
> Key principle: Standby should have similar hardware to primary, especially for write-heavy workloads."

---

## Scenario 8: Application Reads Stale Data

### 🔴 Problem
> "User updated their profile, but when they refresh the page, they see old data. We're using read/write splitting. How do you handle read-after-write consistency?"

### 🔍 The Problem

**Setup:**
```
User → App → Writes to PRIMARY → Success
User → App → Reads from STANDBY → Sees old data (replication lag!)
```

**Replication lag:**
```sql
-- On PRIMARY
SELECT write_lag, flush_lag, replay_lag FROM pg_stat_replication;
-- Even 500ms lag causes this issue!
```

### 💡 Root Cause

Replication is **asynchronous** by nature. Even with millisecond lag, read-after-write can return stale data.

### ✅ Solutions

**Solution 1: Read from PRIMARY after writes (Simple)**
```python
def update_user_profile(user_id, data):
    # Write to PRIMARY
    primary_conn.execute("UPDATE users SET name = %s WHERE id = %s", (data['name'], user_id))
    
    # Read from PRIMARY (same session)
    result = primary_conn.execute("SELECT * FROM users WHERE id = %s", (user_id,))
    return result

# For subsequent reads (non-critical), use standby
def get_user_profile(user_id):
    # OK to use standby for general reads
    return standby_conn.execute("SELECT * FROM users WHERE id = %s", (user_id,))
```

**Solution 2: Session-based routing (Better)**
```python
class DatabaseRouter:
    def __init__(self):
        self.last_write_time = {}
        
    def get_connection(self, user_id):
        last_write = self.last_write_time.get(user_id, 0)
        
        # If wrote in last 2 seconds, use PRIMARY
        if time.time() - last_write < 2:
            return primary_connection
        
        # Otherwise, use STANDBY
        return standby_connection
    
    def mark_write(self, user_id):
        self.last_write_time[user_id] = time.time()
```

**Solution 3: Use synchronous replication (Strongest)**
```sql
-- On PRIMARY
ALTER SYSTEM SET synchronous_commit = 'remote_apply';
ALTER SYSTEM SET synchronous_standby_names = 'walreceiver';
```

Now writes wait until standby has applied changes. Reads from standby will be consistent!

**Trade-off:** Write latency increases (~2-10x slower)

**Solution 4: Application-level caching**
```python
cache = {}

def update_user(user_id, data):
    # Write to PRIMARY
    primary_conn.execute("UPDATE users SET name = %s WHERE id = %s", (data['name'], user_id))
    
    # Cache the updated data
    cache[user_id] = data
    cache_expiry[user_id] = time.time() + 5  # Cache for 5 seconds
    
def get_user(user_id):
    # Check cache first
    if user_id in cache and time.time() < cache_expiry[user_id]:
        return cache[user_id]
    
    # Otherwise read from standby
    return standby_conn.execute("SELECT * FROM users WHERE id = %s", (user_id,))
```

### 📊 Interview Answer

> "Read-after-write consistency is a common problem with read/write splitting. Even with minimal replication lag, users can see stale data immediately after updates.
> 
> **Solutions ranked by complexity:**
> 
> 1. **Route reads to PRIMARY after writes** (Simplest) - For the user who just wrote data, read from PRIMARY for a few seconds. Use sticky sessions or track last write time.
> 
> 2. **Application caching** - Cache written data for a few seconds. Subsequent reads hit cache instead of potentially stale standby.
> 
> 3. **Synchronous replication with remote_apply** (Strongest) - Writes wait until standby has applied changes. Guarantees consistency but increases write latency significantly.
> 
> 4. **Stale reads with indicators** - Accept stale data but show users a timestamp: 'Data as of 2 seconds ago'. Set user expectations.
> 
> In practice, I'd use Solution 1 (session-based routing) as it's simple and effective. Users who just modified data get reads from PRIMARY for ~2 seconds, then switch to standby. This handles 99% of cases without the performance penalty of synchronous replication."

---

## Scenario 9: Failover Doesn't Complete

### 🔴 Problem
> "Primary crashed. We promoted the standby, but the application can't connect. What went wrong?"

### 🔍 Diagnosis

**Step 1: Verify promotion succeeded**
```sql
-- On promoted server
SELECT pg_is_in_recovery();
-- Should return: f (false = not in recovery = is primary)
```

**Step 2: Check if it's accepting writes**
```sql
CREATE TABLE failover_test (id int);
-- Should succeed if promotion worked
DROP TABLE failover_test;
```

**Step 3: Check application connection string**
```python
# Application might still be pointing to old primary!
DATABASE_URL = "postgresql://user:pass@old-primary:5432/db"  # ❌ Dead server
```

### 💡 Root Causes

**1. Application still points to old primary (Most common!)**
- DNS not updated
- Hard-coded IP address in config
- Connection pooler not restarted

**2. Firewall rules**
- New primary IP not in firewall whitelist

**3. pg_hba.conf doesn't allow connections**
- Standby had restrictive pg_hba.conf

**4. Promotion incomplete**
- `pg_promote()` didn't finish
- Server still in recovery mode

### ✅ Solutions

**Solution 1: Update connection strings**
```python
# Option A: Update application config
DATABASE_PRIMARY = "postgresql://user:pass@new-primary:5432/db"

# Option B: Use VIP (Virtual IP) that moves during failover
DATABASE_PRIMARY = "postgresql://user:pass@vip:5432/db"

# Option C: Use DNS with short TTL
DATABASE_PRIMARY = "postgresql://user:pass@db-primary.example.com:5432/db"
```

**Solution 2: Complete promotion manually**
```bash
# If promotion didn't finish
docker exec postgres-standby psql -U postgres -c "SELECT pg_promote();"

# Or via CLI
docker exec postgres-standby pg_ctl promote -D /var/lib/postgresql/data
```

**Solution 3: Fix pg_hba.conf**
```bash
# On new primary (old standby)
echo "host all all 0.0.0.0/0 scram-sha-256" >> /var/lib/postgresql/data/pg_hba.conf
docker exec postgres-standby psql -U postgres -c "SELECT pg_reload_conf();"
```

**Solution 4: Restart connection pooler**
```bash
# If using Pgpool or PgBouncer
docker-compose restart pgpool
```

### 🏗️ Proper Failover Architecture

**Manual failover (Basic):**
```bash
# 1. Confirm primary is dead
pg_isready -h primary || echo "Primary is down"

# 2. Promote standby
psql -h standby -U postgres -c "SELECT pg_promote();"

# 3. Update DNS or VIP
# (Manual step or script)

# 4. Reconfigure old primary as new standby (when it comes back)
```

**Automatic failover (Production):**
```
Use tools like:
- Patroni (recommended)
- repmgr
- Pgpool-II with watchdog

These handle:
- Automatic promotion
- VIP failover
- DNS updates
- Old primary fencing
```

### 📊 Interview Answer

> "Failover not completing usually means the promotion worked, but the application can't reach the new primary. This is why proper failover requires more than just promoting the standby.
> 
> **Complete failover checklist:**
> 
> 1. **Promote standby** - `SELECT pg_promote()` and verify with `pg_is_in_recovery()`
> 
> 2. **Update routing** - Either:
>    - Update DNS to point to new primary
>    - Move VIP (Virtual IP) to new primary
>    - Update load balancer configuration
> 
> 3. **Restart connection poolers** - PgBouncer/Pgpool may cache old connections
> 
> 4. **Verify application connectivity** - Test writes succeed
> 
> 5. **Reconfigure old primary** - When it comes back, make it a standby
> 
> In production, I'd never do this manually. Tools like Patroni handle all these steps automatically, including:
> - Consensus-based promotion (prevents split-brain)
> - Automatic VIP movement
> - Old primary fencing (prevents dual-master)
> - Health checks and monitoring
> 
> Manual failover should only be used for testing or emergency procedures."

---

## Scenario 10: Connection Pool Exhaustion

### 🔴 Problem
> "Application throwing 'FATAL: sorry, too many clients already' errors. How do you diagnose and fix?"

### 🔍 Diagnosis

**Step 1: Check current connections**
```sql
SELECT count(*) FROM pg_stat_activity;
SHOW max_connections;
```

**Example output:**
```
 count 
-------
   298
   
 max_connections 
-----------------
   300
```
**Problem:** Only 2 connections available!

**Step 2: Analyze connection sources**
```sql
SELECT 
    usename,
    application_name,
    client_addr,
    count(*),
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'active') AS active
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
GROUP BY usename, application_name, client_addr
ORDER BY count(*) DESC;
```

**Example output:**
```
 usename | application_name | client_addr | count | idle | active 
---------+------------------+-------------+-------+------+--------
 webapp  | backend-api      | 172.19.0.5  |   150 |  145 |      5
 webapp  | worker           | 172.19.0.6  |   100 |   95 |      5
```

**Problem:** 240 idle connections doing nothing!

### 💡 Root Causes

**1. Application doesn't use connection pooling**
```python
# ❌ BAD: Creates new connection per request
def handle_request():
    conn = psycopg2.connect("dbname=mydb user=postgres")
    conn.execute("SELECT * FROM users")
    # Never closes! Connection leaks
```

**2. Connection pooler misconfigured**
- Application-side pool too large
- No timeout settings
- Connections never released

**3. Long-running transactions**
- Transactions left open
- Forgot to commit/rollback

**4. max_connections too low**
- Default is only 100
- Production needs more

### ✅ Solutions

**Immediate Fix: Kill idle connections**
```sql
-- Kill connections idle for more than 5 minutes
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < now() - interval '5 minutes'
  AND pid != pg_backend_pid();
```

**Short-term: Increase max_connections**
```sql
-- On database server
ALTER SYSTEM SET max_connections = 500;
-- Requires restart!
```
```bash
docker-compose restart postgres-primary
```

**Long-term Fix 1: Implement PgBouncer (Recommended)**
```yaml
# docker-compose.yml
pgbouncer:
  image: pgbouncer/pgbouncer
  environment:
    DATABASES_HOST: postgres-primary
    DATABASES_PORT: 5432
    DATABASES_USER: postgres
    DATABASES_PASSWORD: password
    DATABASES_DBNAME: mydb
    PGBOUNCER_POOL_MODE: transaction
    PGBOUNCER_MAX_CLIENT_CONN: 1000
    PGBOUNCER_DEFAULT_POOL_SIZE: 25
  ports:
    - "6432:6432"
```

**Result:** 1000 app connections → PgBouncer → 25 DB connections

**Long-term Fix 2: Fix application code**
```python
# ✅ GOOD: Use connection pooling
from sqlalchemy import create_engine
from sqlalchemy.pool import QueuePool

engine = create_engine(
    'postgresql://user:pass@host/db',
    poolclass=QueuePool,
    pool_size=10,              # Max connections per app instance
    max_overflow=20,            # Extra connections if needed
    pool_timeout=30,            # Wait time for connection
    pool_recycle=3600,          # Recreate connections after 1 hour
    pool_pre_ping=True          # Test connection before using
)

# Proper usage with context manager
def get_user(user_id):
    with engine.connect() as conn:
        result = conn.execute("SELECT * FROM users WHERE id = %s", (user_id,))
        return result.fetchone()
    # Connection automatically returned to pool
```

**Long-term Fix 3: Set connection timeouts**
```sql
-- Kill idle connections automatically
ALTER DATABASE mydb SET idle_in_transaction_session_timeout = '5min';
ALTER DATABASE mydb SET statement_timeout = '60s';
```

### 📊 Monitoring Query

```sql
-- Create this as a dashboard metric
SELECT 
    max_conn,
    used,
    res_for_super,
    max_conn - used - res_for_super AS available,
    ROUND(100.0 * used / max_conn, 2) AS pct_used
FROM (
    SELECT count(*) AS used FROM pg_stat_activity
) t1, (
    SELECT setting::int AS max_conn FROM pg_settings WHERE name = 'max_connections'
) t2, (
    SELECT setting::int AS res_for_super FROM pg_settings WHERE name = 'superuser_reserved_connections'
) t3;
```

**Alert when `pct_used` > 80%**

### 📊 Interview Answer

> "Connection exhaustion is a common production issue, usually caused by connection leaks in the application or lack of connection pooling.
> 
> **Diagnosis steps:**
> 1. Check `pg_stat_activity` to see current connections vs `max_connections`
> 2. Group connections by source to identify which service is leaking
> 3. Check for idle connections that should have been closed
> 
> **Immediate fix:**
> Kill idle connections over 5 minutes old to free up slots.
> 
> **Long-term solutions:**
> 
> 1. **Implement PgBouncer** - This is the standard solution. PgBouncer sits between apps and database, multiplexing many client connections to fewer backend connections. For example, 1000 app connections can share 25 database connections.
> 
> 2. **Fix application code** - Use proper connection pooling with frameworks like SQLAlchemy. Always use context managers or try/finally to ensure connections are returned to the pool.
> 
> 3. **Set timeouts** - Configure `idle_in_transaction_session_timeout` to automatically kill hung transactions.
> 
> 4. **Monitor proactively** - Alert when connection usage exceeds 80% so you can investigate before hitting the limit.
> 
> In production, I'd always use PgBouncer as the first line of defense. It's lightweight, battle-tested, and solves most connection problems."

---

## 🎓 Summary: Key Troubleshooting Principles

### 1. **Always Check Logs First**
```bash
# Docker
docker logs postgres-primary --tail 100

# Server
tail -f /var/log/postgresql/postgresql-15-main.log
```

### 2. **Quantify the Problem**
- Don't just say "lag exists" - measure it
- Use `pg_stat_replication` for exact numbers
- Compare metrics over time

### 3. **Have Monitoring in Place**
Essential metrics to monitor:
- Replication lag (bytes and time)
- Connection count
- Disk space
- Replication slot WAL retention
- Query performance

### 4. **Understand Trade-offs**
- Sync replication = Consistency but slower writes
- Async replication = Fast writes but potential data loss
- More standbys = More read capacity but more complexity

### 5. **Automate Failover**
Manual failover is error-prone. Use:
- **Patroni** (recommended for Kubernetes)
- **repmgr** (traditional VMs)
- **Pgpool-II** (all-in-one solution)

### 6. **Test Your DR Plan**
- Regularly test failover procedures
- Time how long failover takes
- Verify applications reconnect correctly
- Document the steps

---

## 📝 Interview Preparation Checklist

Can you explain:
- [ ] How to diagnose replication lag?
- [ ] What causes standby connection failures?
- [ ] How to handle synchronous standby downtime?
- [ ] Why disk space fills up on primary?
- [ ] How to ensure read-after-write consistency?
- [ ] Complete failover procedure?
- [ ] When to use PgBouncer vs Pgpool-II?
- [ ] How to prevent connection exhaustion?
- [ ] What causes high CPU on standby?
- [ ] How to detect and fix standby divergence?

If you can answer all these, you're ready for senior-level database interviews! 🚀

---

*This guide covers real-world troubleshooting scenarios that come up in production PostgreSQL environments. Practice these scenarios in your test environment to build confidence for interviews.*
