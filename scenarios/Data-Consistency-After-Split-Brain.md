# Data Consistency After Split-Brain: Resolution Guide

**Scenario:** After manual failover, both servers have divergent data  
**Problem:** Old primary (Timeline 1) and New primary (Timeline 2) cannot sync  
**Goal:** Restore single source of truth

---

## 🔍 Current Situation Analysis

### New Primary (Timeline 2) - Production Server
```
Products: 10,002 rows
Timeline: 2
Port: 5433

Recent data:
- ID 10034: "Post-Failover Product" (created after promotion)
```

### Old Primary (Timeline 1) - Stopped Server  
```
Products: 10,002 rows
Timeline: 1
Port: 5432

Recent data:
- ID 10002: "Old Primary Write" (created during split-brain)
```

**Key Issue:** Same row count, but ID 10002 vs ID 10034 are completely different products!

---

## 🎯 Three Resolution Options

### Option 1: Discard Old Data (RECOMMENDED) ⭐⭐⭐⭐⭐

**When to use:** Old primary's divergent data is NOT important (most common case)

**Pros:**
- ✅ Safest approach
- ✅ Clean slate - no corruption risk
- ✅ Fast recovery
- ✅ Simple to execute

**Cons:**
- ❌ Loses old primary's divergent writes (ID 10002 in our case)

**Steps:**
```bash
# 1. Stop old primary
docker stop postgres-primary

# 2. Remove old data directory
docker exec postgres-primary rm -rf /var/lib/postgresql/data/*

# 3. Rebuild from new primary using pg_basebackup
docker exec postgres-primary pg_basebackup \
  -h postgres-standby -p 5432 -U replicator \
  -D /var/lib/postgresql/data -Fp -Xs -P -R

# 4. Start as new standby
docker start postgres-primary
```

**MySQL DBA Translation:**
```bash
# MySQL equivalent:
mysqldump --all-databases --master-data=2 | mysql -h old_master
# or
CHANGE MASTER TO MASTER_HOST='new_master', MASTER_AUTO_POSITION=1;
START SLAVE;
```

---

### Option 2: Use pg_rewind (CONDITIONAL) ⭐⭐⭐

**When to use:** 
- Old primary's divergent transactions are minimal
- New primary already has newer data
- You want to "rewind" old primary to match new primary's timeline

**Requirements:**
- ✅ `wal_log_hints = on` OR `data_checksums` enabled
- ✅ New primary must be reachable
- ✅ Old primary must have been cleanly shut down

**Pros:**
- ✅ Faster than full rebuild (only copies changed blocks)
- ✅ Automatically handles timeline switch

**Cons:**
- ❌ Still loses old primary's divergent data
- ❌ Requires specific PostgreSQL settings
- ❌ More complex than Option 1

**Steps:**
```bash
# 1. Stop old primary (if running)
docker stop postgres-primary

# 2. Run pg_rewind
docker exec postgres-primary pg_rewind \
  --target-pgdata=/var/lib/postgresql/data \
  --source-server='host=postgres-standby port=5432 user=postgres' \
  --progress

# 3. Update recovery configuration
docker exec postgres-primary bash -c "cat > /var/lib/postgresql/data/standby.signal <<EOF
standby_mode = 'on'
primary_conninfo = 'host=postgres-standby port=5432 user=replicator'
EOF"

# 4. Start as new standby
docker start postgres-primary
```

**What pg_rewind does:**
1. Identifies divergence point (Timeline 1 → Timeline 2)
2. Copies only changed data blocks from new primary
3. Rewinds old primary to match new primary's state
4. Prepares it to follow Timeline 2

**MySQL equivalent:** No direct equivalent! Closest is using `mysqlbinlog` to extract and replay transactions.

---

### Option 3: Manual Merge (HIGH RISK) ⭐

**When to use:** ONLY when old primary's data is absolutely critical and must be preserved

**Pros:**
- ✅ Can preserve old primary's divergent transactions

**Cons:**
- ❌ Very high risk of logical conflicts
- ❌ Requires manual SQL intervention
- ❌ Time-consuming
- ❌ Can cause foreign key violations
- ❌ Not recommended for production

**Steps:**
```bash
# 1. Extract divergent data from old primary
docker exec postgres-primary pg_dump -U postgres \
  --table=products \
  --data-only \
  --inserts \
  > old_primary_divergent.sql

# 2. Manually edit SQL file to:
#    - Change conflicting IDs
#    - Resolve foreign key issues
#    - Handle duplicate data

# 3. Apply to new primary (CAREFULLY!)
docker exec -i postgres-standby psql -U postgres < old_primary_divergent.sql

# 4. Then follow Option 1 or 2 to rebuild old primary
```

**Example of manual conflict resolution:**
```sql
-- Old primary had:
INSERT INTO products (id, name, category) VALUES (10002, 'Old Primary Write', 'Danger');

-- But new primary might already have id=10002 or that ID is too low
-- Must change to:
INSERT INTO products (name, category) VALUES ('Old Primary Write', 'Danger');
-- Let sequence assign new ID (10035, 10036, etc.)
```

**Risks:**
- Foreign key violations if referenced by other tables
- Duplicate business logic conflicts
- Sequence mismatches
- Trigger side effects

---

## 🎬 Hands-On Demo: Option 1 (Recommended)

Let's rebuild old primary as new standby, **discarding** its divergent data.

### Current State Verification

**New Primary (Timeline 2):**
- Products: 10,002 (including ID 10034: "Post-Failover Product")
- Timeline: 2
- Status: Production server, accepting writes

**Old Primary (Timeline 1):**
- Products: 10,002 (including ID 10002: "Old Primary Write")  
- Timeline: 1
- Status: Stopped, divergent data

**Decision:** Discard ID 10002 "Old Primary Write", keep ID 10034 "Post-Failover Product"

---

## 🔧 Step-by-Step: Rebuilding Old Primary

### Step 1: Stop and Clean Old Primary

```bash
# IMPORTANT: Must START container first (docker exec only works on running containers)
docker start postgres-primary

# Wait for container to fully boot (critical!)
sleep 3

# Remove divergent data (DESTRUCTIVE!)
docker exec postgres-primary bash -c "rm -rf /var/lib/postgresql/data/* /var/lib/postgresql/data/.*" 2>/dev/null

# Stop container
docker stop postgres-primary
```

**Why this sequence?**
- `docker exec` ONLY works on RUNNING containers
- `docker start` returns immediately (async) - container needs 2-3 seconds to boot
- `sleep 3` prevents race condition
- `2>/dev/null` suppresses "file not found" warnings
- Semicolon (`;`) continues even if rm has warnings

### Step 2: Take Base Backup from New Primary

```bash
# Create replication slot on new primary (optional but recommended)
docker exec postgres-standby psql -U postgres -c \
  "SELECT pg_create_physical_replication_slot('standby_slot');"

# Perform base backup from new primary
docker exec postgres-primary bash -c "
  pg_basebackup -h postgres-standby -p 5432 -U replicator \
    -D /var/lib/postgresql/data \
    -Fp -Xs -P -R \
    -S standby_slot
"
```

**Parameters explained:**
- `-h postgres-standby`: Connect to NEW primary (formerly standby!)
- `-p 5432`: Port
- `-U replicator`: Replication user
- `-D /var/lib/postgresql/data`: Target directory
- `-Fp`: Plain format (file system copy)
- `-Xs`: Stream WAL during backup
- `-P`: Show progress
- `-R`: Write recovery configuration automatically
- `-S standby_slot`: Use replication slot

### Step 3: Configure Recovery (if not using -R flag)

If you didn't use `-R`, manually create `standby.signal`:

```bash
docker exec postgres-primary bash -c "touch /var/lib/postgresql/data/standby.signal"

docker exec postgres-primary bash -c "cat >> /var/lib/postgresql/data/postgresql.auto.conf <<EOF
primary_conninfo = 'host=postgres-standby port=5432 user=replicator password=replicator_password'
primary_slot_name = 'standby_slot'
EOF"
```

### Step 4: Start Old Primary as New Standby

```bash
# Start container
docker start postgres-primary

# Wait for startup
sleep 5

# Verify it's in recovery mode
docker exec postgres-primary psql -U postgres -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn();"
```

**Expected result:**
```
 pg_is_in_recovery | pg_last_wal_receive_lsn 
-------------------+-------------------------
 t                 | 0/63A07B8
```

✅ `pg_is_in_recovery() = true` means it's a standby!

### Step 5: Verify Replication

```bash
# Check on NEW primary
docker exec postgres-standby psql -U postgres -c \
  "SELECT client_addr, state, sync_state, 
          sent_lsn, write_lsn, replay_lsn 
   FROM pg_stat_replication;"
```

**Expected result:**
```
  client_addr   |   state   | sync_state | sent_lsn  | write_lsn | replay_lsn 
----------------+-----------+------------+-----------+-----------+------------
 172.19.0.2     | streaming | async      | 0/63A07B8 | 0/63A07B8 | 0/63A07B8
```

✅ State = streaming  
✅ All LSNs match = 0 lag

### Step 6: Verify Data Consistency

```bash
# Check NEW primary (Timeline 2)
docker exec postgres-standby psql -U postgres -c \
  "SELECT id, name FROM products WHERE id >= 10000 ORDER BY id;"

# Check NEW standby (Timeline 2)
docker exec postgres-primary psql -U postgres -c \
  "SELECT id, name FROM products WHERE id >= 10000 ORDER BY id;"
```

**Both should show:**
```
  id   |         name          
-------+-----------------------
 10000 | Product 10000
 10001 | Brand New Product
 10034 | Post-Failover Product
```

✅ **Data is consistent!**  
✅ **ID 10002 "Old Primary Write" is gone** (divergent data discarded)  
✅ **ID 10034 "Post-Failover Product" replicated to new standby**

### Step 7: Verify Timeline

```bash
# Check timeline on new standby
docker exec postgres-primary psql -U postgres -c \
  "SELECT received_tli FROM pg_stat_wal_receiver;"
```

**Expected result:**
```
 received_tli 
--------------
            2
```

✅ **New standby is now following Timeline 2!**

---

## 🔄 Final Topology

### Before Resolution:
```
┌─────────────────────────────────┐
│ Old Primary (STOPPED)           │
│ Timeline: 1                     │
│ Data: 10,002 products           │
│ Divergent: ID 10002             │
└─────────────────────────────────┘
          ✗ (cannot sync)
┌─────────────────────────────────┐
│ New Primary                     │
│ Timeline: 2                     │
│ Data: 10,002 products           │
│ Divergent: ID 10034             │
└─────────────────────────────────┘
```

### After Resolution (Option 1):
```
┌─────────────────────────────────┐
│ New Primary                     │
│ Timeline: 2                     │
│ Port: 5433 (postgres-standby)   │
│ Data: 10,002 products           │
│ Has: ID 10034                   │
└─────────────────────────────────┘
          ↓ (streaming replication)
┌─────────────────────────────────┐
│ New Standby (rebuilt)           │
│ Timeline: 2                     │
│ Port: 5432 (postgres-primary)   │
│ Data: 10,002 products           │
│ Has: ID 10034 (replicated)      │
└─────────────────────────────────┘
```

✅ **Topology restored!**  
✅ **Single source of truth**  
✅ **Replication healthy**

---

## 📊 Comparison: Three Options

| Aspect                  | Option 1: Discard    | Option 2: pg_rewind  | Option 3: Manual Merge |
|-------------------------|----------------------|----------------------|------------------------|
| **Data Loss**           | Divergent data lost  | Divergent data lost  | No data loss (risky)   |
| **Speed**               | Slow (full copy)     | Fast (delta only)    | Very slow              |
| **Complexity**          | Simple               | Medium               | Very complex           |
| **Safety**              | Very safe            | Safe                 | High risk              |
| **Requirements**        | None                 | wal_log_hints=on     | DBA expertise          |
| **Recommended?**        | ✅ YES               | ⚠️ Conditional       | ❌ Avoid               |
| **MySQL Equivalent**    | Rebuild replica      | No equivalent        | Manual binlog merge    |

---

## 🎓 Key Learnings for MySQL DBAs

### 1. Timeline Prevents Auto-Sync (Good!)

**PostgreSQL:**
- Timeline mismatch **blocks** old primary from rejoining
- Forces manual decision: discard or merge
- Safer by design

**MySQL:**
- Can rejoin with `CHANGE MASTER TO` (easier but riskier)
- Requires external tools for safety (MHA, Orchestrator)
- Split-brain protection not built-in

### 2. pg_basebackup = MySQL's mysqldump + START SLAVE

**PostgreSQL:**
```bash
pg_basebackup -h new_primary -D /data -R
```

**MySQL:**
```bash
mysqldump --all-databases --master-data=2 > backup.sql
mysql < backup.sql
CHANGE MASTER TO ...
START SLAVE;
```

**Difference:** PostgreSQL's `pg_basebackup` is binary-level (faster, exact replica).

### 3. pg_rewind = Smart Delta Sync

**PostgreSQL:**
- Identifies divergence point using timelines
- Copies only changed blocks
- Automatic timeline switch

**MySQL:**
- No direct equivalent
- Must use `mysqlbinlog` manually or rebuild replica

### 4. Replication Slot Importance

**PostgreSQL:**
```sql
SELECT pg_create_physical_replication_slot('standby_slot');
```

**Purpose:** Prevents WAL deletion while standby catches up

**MySQL equivalent:**
```sql
SET GLOBAL sync_binlog = 1;
SET GLOBAL expire_logs_days = 7;
```

**Difference:** PostgreSQL slot is per-standby, MySQL is global.

---

## 🚨 Production Best Practices

### Prevention (Better Than Cure!)

1. **Use Connection Pooler**
   - PgBouncer: Routes connections to correct primary
   - HAProxy: Health checks + automatic routing
   - Patroni: Automated failover with lease-based leader election

2. **Implement Fencing**
   ```bash
   # STONITH (Shoot The Other Node In The Head)
   # Stop old primary before promoting standby
   docker stop postgres-primary  # Or use VM power-off
   ```

3. **Monitor Timelines**
   ```sql
   -- Alert if timeline mismatch detected
   SELECT DISTINCT timeline_id FROM pg_control_checkpoint();
   ```

4. **Test Failover Regularly**
   - Monthly failover drills
   - Document actual timings
   - Practice rebuilding standby

### Resolution (If Split-Brain Happens)

1. **Assess Data Divergence**
   ```sql
   -- Find divergent rows
   SELECT * FROM products 
   WHERE created_at > (failover_timestamp);
   ```

2. **Choose Option Based on:**
   - Divergent data importance: Low → Option 1
   - Recovery speed needed: High → Option 2 (if configured)
   - Data criticality: High → Option 3 (last resort)

3. **Communicate with Stakeholders**
   - Inform about data loss (if using Option 1/2)
   - Get approval before discarding data
   - Document decision in runbook

4. **Verify Thoroughly**
   - Row counts match
   - Critical tables consistent
   - Application queries work
   - Replication lag = 0

---

## 🧪 Quiz for MySQL DBAs

**Q1:** Why can't PostgreSQL old primary automatically rejoin after failover?  
**A1:** Timeline mismatch. PostgreSQL uses timelines to track failover history. Old primary (Timeline 1) cannot sync with new primary (Timeline 2) without manual intervention.

**Q2:** What's the safest way to restore replication after split-brain?  
**A2:** Option 1 - Discard old primary's data and rebuild using `pg_basebackup`. This ensures single source of truth.

**Q3:** When should you use `pg_rewind` instead of `pg_basebackup`?  
**A3:** When `wal_log_hints=on`, divergence is minimal, and you need faster recovery. But it still loses old primary's divergent data.

**Q4:** Can you merge divergent data from both servers?  
**A4:** Technically yes (Option 3), but extremely risky. High chance of foreign key violations, duplicate data, and logical conflicts. Avoid in production.

**Q5:** What's PostgreSQL's equivalent of MySQL's `CHANGE MASTER TO`?  
**A5:** Creating `standby.signal` file and setting `primary_conninfo` in `postgresql.auto.conf`. The `-R` flag in `pg_basebackup` does this automatically.

---

## 📝 Summary

**The split-brain problem:**
- Two servers both think they're primary
- Each accepted different writes
- Data diverged → cannot automatically sync

**The solution (Option 1 - Recommended):**
1. Accept that divergent data on old primary will be lost
2. Stop old primary
3. Rebuild it from new primary using `pg_basebackup`
4. Verify replication and data consistency
5. Resume normal operations

**Key takeaway:** PostgreSQL's timeline system **prevents** auto-sync after split-brain. This is **safer** than MySQL's approach, but requires understanding of timelines and manual recovery.

**Next scenario:** We'll automate this with Patroni for production-grade HA!

---

*Document created: November 16, 2025*  
*Context: Post-failover data consistency resolution*  
*For: MySQL DBAs learning PostgreSQL*
