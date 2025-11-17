# Accidental Writes on Standby: Prevention, Detection, and Recovery

**Scenario:** Someone accidentally writes bulk data to standby (read-only replica)  
**Problem:** Data drift, replication breaks, or worse - silent corruption  
**For:** MySQL DBAs learning PostgreSQL recovery strategies

---

## 🎯 Can You Actually Write to a Standby?

### PostgreSQL Default Behavior:

**Short answer: NO!** PostgreSQL standby is **strictly read-only**.

```sql
-- On PostgreSQL standby:
INSERT INTO products (name) VALUES ('test');

-- Result:
ERROR:  cannot execute INSERT in a read-only transaction
```

**Why?** 
- Standby is in **recovery mode** (replaying WAL)
- ALL write operations are blocked at SQL level
- Even temp tables, sequences, functions are blocked
- Protection is **very strong**

### MySQL Behavior (Different!):

**MySQL standby CAN accept writes by default!**

```sql
-- On MySQL replica (if not using read_only=1):
INSERT INTO products (name) VALUES ('test');
-- Result: SUCCESS! ⚠️ (causes drift)
```

**Why MySQL allows it:**
- Default: `read_only = 0` (writable!)
- Must explicitly set `read_only = 1` in my.cnf
- Even with `read_only=1`, SUPER users can write
- Must use `super_read_only = 1` to block SUPER users

---

## 🚨 How Accidental Writes Happen (PostgreSQL)

Since PostgreSQL blocks writes, how can drift happen?

### Scenario 1: Standby Was Promoted (Not True Standby)

```bash
# Someone accidentally ran:
SELECT pg_promote();

# Now it's a PRIMARY, accepts writes!
INSERT INTO products ... -- SUCCESS!

# But replication is broken - it's no longer standby
```

**Detection:**
```sql
SELECT pg_is_in_recovery();
-- If returns 'f' (false) = IT'S A PRIMARY!
-- Should return 't' (true) for standby
```

---

### Scenario 2: Application Connected to Wrong Server

```
Application config:
  PRIMARY: postgres-primary:5432
  STANDBY: postgres-standby:5433

Developer mistake:
  Changed connection to postgres-standby:5433
  Ran bulk INSERT script
  BUT postgres-standby was actually promoted (is now primary)!
  
Result: Writes went to wrong server, data drift
```

---

### Scenario 3: Replication Slot Overflow (Not Writes, But Drift)

```
Standby disconnected for 3 days
Primary kept running, accepting writes
WAL accumulated: 50 GB

When standby reconnects:
- If no replication slot: WAL deleted, REPLICATION BROKEN
- Standby missing data (drift)
```

---

### Scenario 4: Manual pg_resetwal (DANGEROUS!)

```bash
# Someone ran on standby (trying to fix corruption):
pg_resetwal -f /var/lib/postgresql/data

# This DESTROYS WAL history
# Standby timeline resets
# Data drift + replication broken
```

**Never run pg_resetwal on standby!**

---

## 📊 Real Production Scenario: Bulk Data Drift

### Example Timeline:

**Day 1 - 9:00 AM:**
```
Primary: 1.5 TB data, Timeline 5
Standby: 1.5 TB data, Timeline 5 (synchronized)
Replication lag: 0 bytes ✅
```

**Day 1 - 2:00 PM:**
```
Someone accidentally promoted standby:
SELECT pg_promote();  -- Oops!

Standby becomes: Primary on Timeline 6
```

**Day 1 - 2:05 PM:**
```
Bulk data script runs (developer thought it was test server):
INSERT INTO orders SELECT ... (5 million rows inserted)

New "primary" (old standby):
  - Timeline: 6
  - Data: 1.5 TB + 50 GB (new inserts)
  - Total: 1.55 TB

Old primary (still running):
  - Timeline: 5
  - Data: 1.5 TB (no new orders)
  
SPLIT-BRAIN! Data diverged by 50 GB!
```

**Day 2 - 10:00 AM (Discovery):**
```
DBAs notice:
- Timeline mismatch (5 vs 6)
- Row count difference (5M rows)
- Applications seeing different data

Question: How to fix 1.55 TB database with 50 GB drift?
```

---

## 🔧 Recovery Strategies (From Fastest to Slowest)

### Strategy 1: Logical Export/Import (For Small Drift)

**When to use:**
- Drift is < 5% of database size
- Only specific tables affected
- Can identify divergent data

**Pros:**
- ✅ Fast for small datasets
- ✅ Can preserve specific data
- ✅ No full rebuild needed

**Cons:**
- ❌ Doesn't work for large drift
- ❌ Requires identifying affected tables
- ❌ Risk of foreign key violations

**Steps:**

```bash
# 1. Identify divergent tables
# On server with extra data:
SELECT schemaname, tablename, 
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) 
FROM pg_tables 
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

# 2. Export divergent data
pg_dump -t orders -t order_items \
        --data-only \
        --inserts \
        source_server > divergent.sql

# 3. Manually edit SQL to fix conflicts
vim divergent.sql
# Remove duplicate IDs, fix foreign keys, etc.

# 4. Import to correct server
psql target_server < divergent.sql

# 5. Rebuild divergent server using pg_basebackup
pg_basebackup -h correct_primary -D /data -R
```

**Time estimate:** 2-8 hours (manual work!)

**MySQL equivalent:**
```bash
mysqldump --tables orders order_items > divergent.sql
# Edit SQL
mysql < divergent.sql
# Rebuild replica
```

---

### Strategy 2: pg_rewind (For Small Block-Level Drift)

**When to use:**
- `wal_log_hints = on` enabled
- Divergence is < 10% of database size
- Both servers accessible
- Timeline difference exists

**Pros:**
- ✅ Fast (only copies changed blocks)
- ✅ Automatic timeline reconciliation
- ✅ Much faster than full rebuild

**Cons:**
- ❌ Requires `wal_log_hints` or data checksums
- ❌ Still discards divergent data
- ❌ Doesn't work if drift > 10-20%

**Steps:**

```bash
# 1. Stop divergent server
pg_ctl stop -D /data -m immediate

# 2. Run pg_rewind
pg_rewind --target-pgdata=/data \
          --source-server='host=correct_primary port=5432 user=postgres' \
          --progress

# 3. Configure as standby
touch /data/standby.signal
echo "primary_conninfo = '...'" >> /data/postgresql.auto.conf

# 4. Start server
pg_ctl start -D /data
```

**Time estimate:**
- 1.5 TB database: ~1-2 hours
- 50 GB drift: ~20-30 minutes actual rewind time

**Calculation:**
```
Total blocks: 1.5 TB / 8 KB = ~200 million blocks
Changed blocks (50 GB): 50 GB / 8 KB = ~6.5 million blocks
Transfer: 6.5M * 8 KB = 50 GB @ 100 MB/s = ~8 minutes
Plus metadata/verification: ~20-30 minutes total
```

**MySQL equivalent:** None! Must rebuild.

---

### Strategy 3: pg_basebackup (Full Rebuild - Safest)

**When to use:**
- Drift is large (> 10%)
- `wal_log_hints` not enabled
- Simplicity preferred over speed
- Data corruption suspected

**Pros:**
- ✅ Always works
- ✅ Clean slate, no corruption risk
- ✅ Simple, well-tested process
- ✅ No prerequisites needed

**Cons:**
- ❌ Slow for large databases
- ❌ Network bandwidth intensive
- ❌ Standby unavailable during rebuild

**Steps:**

```bash
# 1. Stop divergent server
pg_ctl stop -D /data

# 2. Remove old data
rm -rf /data/*

# 3. Take base backup
pg_basebackup -h correct_primary \
              -D /data \
              -U replicator \
              -P -v -X stream -R

# 4. Start server
pg_ctl start -D /data
```

**Time estimate:**
- 1.5 TB database
- Network: 1 Gbps = ~125 MB/s
- Transfer time: 1.5 TB / 125 MB/s = ~3.5 hours
- Plus compression/verification: ~4-5 hours total

**Optimization:**
```bash
# Use compression (PostgreSQL 15+):
pg_basebackup ... --compress=gzip:9

# Or use network compression:
ssh -C user@primary 'pg_basebackup ...' | tar -xz

# Time with compression: ~2-3 hours
```

**MySQL equivalent:**
```bash
# Similar time:
mysqldump --all-databases | gzip | ssh replica 'gunzip | mysql'
# or
xtrabackup --backup --stream=xbstream --compress | ssh replica 'xbstream -x'
```

---

### Strategy 4: Parallel pg_basebackup (Faster Rebuild)

**When to use:**
- Very large database (> 1 TB)
- Multiple network links available
- Can tolerate complexity

**Pros:**
- ✅ 2-4x faster than single pg_basebackup
- ✅ Utilizes multiple cores/networks
- ✅ Clean rebuild guaranteed

**Cons:**
- ❌ Complex setup
- ❌ Requires multiple tablespaces or manual splitting
- ❌ Risk of version/consistency issues

**Steps:**

```bash
# 1. Create multiple tablespaces (if not already)
CREATE TABLESPACE ts1 LOCATION '/data/ts1';
CREATE TABLESPACE ts2 LOCATION '/data/ts2';

# 2. Parallel backup (PostgreSQL 15+)
pg_basebackup -h primary \
              -D /data \
              --tablespace-mapping=/data/ts1=/data_standby/ts1 \
              --tablespace-mapping=/data/ts2=/data_standby/ts2 \
              -j 4 \  # 4 parallel jobs
              -P -R

# 3. Start server
pg_ctl start -D /data
```

**Time estimate:**
- 1.5 TB database
- 4 parallel streams
- Network: 1 Gbps per stream = 500 MB/s total
- Time: 1.5 TB / 500 MB/s = ~50 minutes

**MySQL equivalent:**
```bash
# mydumper (parallel dump):
mydumper --host=primary --threads=8 --outputdir=/backup
myloader --host=replica --threads=8 --directory=/backup
```

---

### Strategy 5: Use Replication Slot + WAL Archive (For Disconnected Standby)

**When to use:**
- Standby was disconnected (not divergent)
- Replication slot exists
- WAL archive available

**Scenario:**
```
Standby disconnected: 3 days
Primary kept running: Accepting writes
WAL generated: 50 GB
Replication slot: Retained WAL ✅

Challenge: How to catch up without full rebuild?
```

**Pros:**
- ✅ No full rebuild needed
- ✅ Uses existing replication infrastructure
- ✅ Standby can catch up automatically

**Cons:**
- ❌ Requires replication slot (otherwise WAL deleted)
- ❌ Can be slow for large WAL backlog
- ❌ May require WAL archive if slot insufficient

**Steps:**

```bash
# 1. Check replication slot on primary
SELECT slot_name, restart_lsn, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
FROM pg_replication_slots;

# Example output:
# slot_name    | restart_lsn | lag
# standby_slot | 0/8000000   | 50 GB

# 2. Start standby (it will catch up automatically)
pg_ctl start -D /data

# 3. Monitor catch-up progress
SELECT pg_last_wal_receive_lsn(), 
       pg_last_wal_replay_lsn(),
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), 
                                        pg_last_wal_replay_lsn())) as replay_lag;

# 4. Wait for lag = 0
# Time: 50 GB @ 100 MB/s = ~8 minutes
```

**If replication slot didn't exist:**
```bash
# WAL deleted, must rebuild:
pg_basebackup -h primary -D /data -R
```

**MySQL equivalent:**
```bash
# Similar with binlog retention:
CHANGE MASTER TO MASTER_LOG_FILE='mysql-bin.000123', 
                 MASTER_LOG_POS=4567890;
START SLAVE;

# If binlog purged:
# Must rebuild replica
```

---

## 📊 Strategy Comparison Matrix

| Method | 1.5 TB DB | 50 GB Drift | Preserves Data | Network | Downtime | Complexity |
|--------|-----------|-------------|----------------|---------|----------|------------|
| **Logical Export** | ❌ Too slow | ✅ Works | ✅ Can preserve | Low | High | Very High |
| **pg_rewind** | ⚠️ Slow | ✅ Fast | ❌ Discards | Medium | Medium | Medium |
| **pg_basebackup** | ❌ Slow | ❌ Full copy | ❌ Clean slate | Very High | High | Low |
| **Parallel backup** | ✅ Fast | ❌ Full copy | ❌ Clean slate | Very High | Medium | High |
| **Slot + Archive** | N/A | ✅ Catchup | ✅ No rebuild | Low | Low | Low |

---

## 🛡️ Prevention Strategies

### 1. Connection Monitoring

**Implement connection tracking:**

```sql
-- Create monitoring view
CREATE VIEW connection_audit AS
SELECT 
    usename,
    application_name,
    client_addr,
    backend_start,
    state,
    query,
    pg_is_in_recovery() as is_standby
FROM pg_stat_activity
WHERE usename NOT IN ('postgres', 'replicator');

-- Alert if write connections to standby
SELECT * FROM connection_audit 
WHERE is_standby = true 
  AND state = 'active'
  AND query ILIKE '%INSERT%' OR query ILIKE '%UPDATE%' OR query ILIKE '%DELETE%';
```

---

### 2. Application Connection Pooling

**Use PgBouncer with routing:**

```ini
# pgbouncer.ini
[databases]
myapp_write = host=primary port=5432 dbname=myapp
myapp_read  = host=standby port=5432 dbname=myapp

[pgbouncer]
pool_mode = transaction
max_client_conn = 1000

# Application uses:
# Writes:  connect to myapp_write
# Reads:   connect to myapp_read
```

**Benefits:**
- ✅ Clear separation (write vs read)
- ✅ Cannot accidentally write to standby
- ✅ Automatic failover with Patroni

---

### 3. Regular Verification Checks

**Daily verification script:**

```bash
#!/bin/bash
# verify_replication.sh

PRIMARY="postgres-primary"
STANDBY="postgres-standby"

# Check 1: Verify standby is in recovery
STANDBY_RECOVERY=$(docker exec $STANDBY psql -U postgres -t -c "SELECT pg_is_in_recovery();")
if [ "$STANDBY_RECOVERY" != " t" ]; then
    echo "ALERT: Standby is NOT in recovery mode!"
    exit 1
fi

# Check 2: Verify timeline match
PRIMARY_TIMELINE=$(docker exec $PRIMARY psql -U postgres -t -c \
    "SELECT timeline_id FROM pg_control_checkpoint();")
STANDBY_TIMELINE=$(docker exec $STANDBY psql -U postgres -t -c \
    "SELECT received_tli FROM pg_stat_wal_receiver;")

if [ "$PRIMARY_TIMELINE" != "$STANDBY_TIMELINE" ]; then
    echo "ALERT: Timeline mismatch! Primary: $PRIMARY_TIMELINE, Standby: $STANDBY_TIMELINE"
    exit 1
fi

# Check 3: Verify replication lag
LAG=$(docker exec $PRIMARY psql -U postgres -t -c \
    "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn) FROM pg_stat_replication;")

if [ -z "$LAG" ]; then
    echo "ALERT: No replication connection!"
    exit 1
fi

if [ "$LAG" -gt 10485760 ]; then  # 10 MB
    echo "WARNING: Replication lag > 10 MB: $LAG bytes"
fi

echo "All checks passed ✓"
```

**Run via cron:**
```bash
# crontab
*/5 * * * * /usr/local/bin/verify_replication.sh
```

---

### 4. Use Patroni for Automatic Protection

**Patroni configuration:**

```yaml
# patroni.yml
bootstrap:
  dcs:
    postgresql:
      parameters:
        wal_level: replica
        hot_standby: on
        wal_log_hints: on  # Enable for pg_rewind
        
scope: postgres_cluster
name: node1

restapi:
  listen: 0.0.0.0:8008

etcd:
  host: etcd:2379

postgresql:
  listen: 0.0.0.0:5432
  data_dir: /var/lib/postgresql/data
  parameters:
    max_connections: 100
```

**Benefits:**
- ✅ Automatic failover
- ✅ Prevents split-brain (DCS consensus)
- ✅ Automatic pg_rewind on rejoin
- ✅ Health checks built-in

---

## 🎯 Summary & Recommendations

### For 1.5 TB Database with 50 GB Drift:

**Recommended approach:**

1. **First: Try pg_rewind** (if `wal_log_hints = on`)
   - Time: ~30 minutes
   - Risk: Low
   - If fails → go to step 2

2. **Second: Parallel pg_basebackup**
   - Time: ~1 hour with 4 streams
   - Risk: None
   - Always works

3. **Never: Manual data merge**
   - Too risky for production
   - High chance of corruption
   - Only for specific critical data

### Prevention is Key:

1. ✅ Enable `wal_log_hints = on` (enables pg_rewind)
2. ✅ Use replication slots (prevents WAL deletion)
3. ✅ Implement connection pooling (PgBouncer)
4. ✅ Monitor timeline + recovery status daily
5. ✅ Use Patroni for automated HA (best practice!)

### MySQL DBA Takeaways:

| Aspect | PostgreSQL | MySQL |
|--------|------------|-------|
| **Standby writes** | Blocked by default ✅ | Allowed by default ⚠️ |
| **Timeline protection** | Built-in ✅ | Must configure |
| **Recovery options** | 3 options (export, rewind, rebuild) | 1 option (rebuild) |
| **Fast recovery** | pg_rewind (delta sync) | None (full rebuild only) |
| **Automatic protection** | Patroni | MHA/Orchestrator |

**Bottom line:** PostgreSQL has MORE protection and MORE recovery options than MySQL!

---

*Document created: November 16, 2025*  
*Purpose: Recovery strategies for large database drift scenarios*  
*For: Production DBAs managing multi-TB PostgreSQL clusters*
