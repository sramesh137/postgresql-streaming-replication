# Scenario 04 Execution Log: Manual Failover

**Executed:** November 16, 2025  
**Duration:** ~12 minutes  
**Difficulty:** ⭐⭐⭐ Intermediate  
**Status:** ✅ COMPLETED

---

## 🎯 Learning Objectives Achieved

✅ Understood manual failover process  
✅ Promoted standby to primary using `pg_promote()`  
✅ Verified timeline changes (Timeline 1 → Timeline 2)  
✅ Tested write operations on new primary  
✅ Experienced split-brain scenario  
✅ Compared PostgreSQL vs MySQL failover approaches

---

## 📊 Pre-Failover State

### Step 1: Health Check (11:26:12 CET)

**PRIMARY SERVER:**
```sql
SELECT 'PRIMARY' as server_type, 
       pg_is_in_recovery() as in_recovery, 
       pg_current_wal_lsn() as current_lsn;
```

| server_type | in_recovery | current_lsn |
|-------------|-------------|-------------|
| PRIMARY     | f (false)   | 0/639EC30   |

✅ Primary is writable (not in recovery)  
✅ Current WAL position: 0/639EC30

**STANDBY SERVER:**
```sql
SELECT 'STANDBY' as server_type,
       pg_is_in_recovery() as in_recovery,
       pg_last_wal_receive_lsn() as received_lsn,
       pg_last_wal_replay_lsn() as replayed_lsn;
```

| server_type | in_recovery | received_lsn | replayed_lsn |
|-------------|-------------|--------------|--------------|
| STANDBY     | t (true)    | 0/639EC30    | 0/639EC30    |

✅ Standby in recovery mode (read-only)  
✅ **Perfect sync: received_lsn = replayed_lsn = primary LSN**  
✅ **0 bytes lag - ideal for failover**

### Data Verification

**Both servers had identical data:**
- **Products:** 10,001 rows
- **Users:** 5 rows  
- **Orders:** 4 rows

### Timeline Check

**Primary:** Timeline 1 (normal operation)  
**Standby:** Timeline 1 (following primary)

**MySQL DBA Note:** PostgreSQL uses "timelines" to track failover history. Each failover creates a new timeline (like a branch). MySQL doesn't have this concept - binlog positions are linear even after failover.

---

## 💥 Step 2: Simulating Primary Failure (11:29:58 CET)

```bash
docker stop postgres-primary
```

**Result:** ✅ Primary stopped successfully

**Standby reaction after 3 seconds:**
```sql
SELECT status, conninfo FROM pg_stat_wal_receiver;
```

| status | conninfo |
|--------|----------|
| (0 rows) | - |

✅ **Standby detected primary disconnection**  
✅ **WAL receiver stopped** (no active replication)

**MySQL Comparison:**
- **MySQL:** Standby continues running, shows `Seconds_Behind_Master: NULL`
- **PostgreSQL:** Standby keeps running in read-only mode, can be promoted
- **Key difference:** PostgreSQL standby **doesn't panic** - waits for operator decision

---

## 🚀 Step 3: Promoting Standby (11:30:33 CET)

```sql
SELECT pg_promote();
```

| pg_promote |
|------------|
| t (true)   |

✅ **Promotion initiated successfully**

**What happened internally:**
1. PostgreSQL created new timeline (Timeline 2)
2. Standby exited recovery mode
3. Server became writable
4. Created timeline history file: `00000002.history`

**MySQL DBA Translation:**
```
PostgreSQL: SELECT pg_promote();
MySQL:      STOP SLAVE; RESET SLAVE ALL;
            (then reconfigure app to point to new master)
```

**Key Difference:** PostgreSQL's promotion is **atomic and safe** - timeline ensures old primary can't accidentally rejoin without manual intervention.

---

## ✅ Step 4: Verification (11:30:38 CET - after 5 sec wait)

```sql
SELECT 'NEW PRIMARY' as server_type,
       pg_is_in_recovery() as in_recovery,
       pg_current_wal_lsn() as current_lsn;
```

| server_type  | in_recovery | current_lsn |
|--------------|-------------|-------------|
| NEW PRIMARY  | f (false)   | 0/639EDC0   |

✅ **Server is now writable** (in_recovery = false)  
✅ **LSN advanced:** 0/639EC30 → 0/639EDC0 (small jump during promotion)

**Timeline verification:**
```sql
SELECT timeline_id FROM pg_control_checkpoint();
```

| timeline_id |
|-------------|
| 2           |

✅ **Timeline changed from 1 to 2**

**Timeline History File Content:**
```
1       0/639ECA8       no recovery target specified
```

**Translation:** "Timeline 2 branched from Timeline 1 at position 0/639ECA8 during promotion"

---

## 🔧 Step 5: Testing Writes on New Primary (11:31:52 CET)

### INSERT Test

```sql
INSERT INTO products (name, category, price, stock_quantity) 
VALUES ('Post-Failover Product', 'Test', 99.99, 100) 
RETURNING id, name, category, price, created_at;
```

| id    | name                  | category | price | created_at                 |
|-------|-----------------------|----------|-------|----------------------------|
| 10034 | Post-Failover Product | Test     | 99.99 | 2025-11-16 10:31:52.402211 |

✅ **INSERT successful on new primary**

**Note:** ID jumped from 10001 to 10034 due to sequence caching behavior. This is normal!

### UPDATE Test

```sql
UPDATE products SET price = 79.99 
WHERE id = 10034 
RETURNING id, name, price;
```

| id    | name                  | price |
|-------|-----------------------|-------|
| 10034 | Post-Failover Product | 79.99 |

✅ **UPDATE successful**

### Row Count Verification

```sql
SELECT count(*) as total_products FROM products;
```

| total_products |
|----------------|
| 10002          |

✅ **New row confirmed** (10,001 → 10,002)

---

## 📈 Step 6: Understanding Timeline Change

```sql
SELECT timeline_id,
       pg_walfile_name(redo_lsn) as current_wal_file,
       pg_current_wal_lsn() as current_lsn
FROM pg_control_checkpoint();
```

| timeline_id | current_wal_file         | current_lsn |
|-------------|--------------------------|-------------|
| 2           | 000000020000000000000006 | 0/63A07B8   |

**WAL Filename Breakdown:**
```
00000002 0000000000000006
   ↓            ↓
Timeline 2   Segment 6
```

**Before Failover:**  
`000000010000000000000006` (Timeline 1, Segment 6)

**After Failover:**  
`000000020000000000000006` (Timeline 2, Segment 6)

**MySQL DBA Note:**  
- **PostgreSQL:** WAL filename contains timeline (first 8 digits)
- **MySQL:** Binlog filename is simple sequential: `mysql-bin.000001`, `mysql-bin.000002`
- **Why it matters:** Timeline prevents old primary from corrupting new primary's data

---

## ⚠️ Step 7: Split-Brain Scenario (11:36:22 CET)

### Starting Old Primary

```bash
docker start postgres-primary
```

✅ Old primary started (still on Timeline 1)

### Checking Old Primary Status

```sql
SELECT pg_is_in_recovery() as in_recovery,
       pg_current_wal_lsn() as current_lsn,
       (SELECT timeline_id FROM pg_control_checkpoint()) as timeline_id;
```

| in_recovery | current_lsn | timeline_id |
|-------------|-------------|-------------|
| f (false)   | 0/639ECE0   | 1           |

⚠️ **DANGER:** Old primary thinks it's still the master!

### Testing Write to Old Primary (11:37:27 CET)

```sql
INSERT INTO products (name, category, price) 
VALUES ('Old Primary Write', 'Danger', 666.00) 
RETURNING id, name, created_at;
```

| id    | name              | created_at                 |
|-------|-------------------|----------------------------|
| 10002 | Old Primary Write | 2025-11-16 10:37:27.632321 |

💥 **SPLIT BRAIN CONFIRMED!** Write succeeded on old primary.

### Row Count Comparison

**Old Primary (Timeline 1):**
```sql
SELECT count(*) as products,
       (SELECT timeline_id FROM pg_control_checkpoint()) as timeline
FROM products;
```

| products | timeline |
|----------|----------|
| 10002    | 1        |

**New Primary (Timeline 2):**
```sql
SELECT count(*) as products,
       (SELECT timeline_id FROM pg_control_checkpoint()) as timeline
FROM products;
```

| products | timeline |
|----------|----------|
| 10002    | 2        |

⚠️ **Same count, different data!**

### Data Divergence Proof

**Old Primary (Timeline 1) - Last 3 rows:**
| id    | name              | category    | price  |
|-------|-------------------|-------------|--------|
| 10000 | Product 10000     | Electronics | 677.82 |
| 10001 | Brand New Product | Electronics | 999.99 |
| 10002 | Old Primary Write | **Danger**  | 666.00 |

**New Primary (Timeline 2) - Last 3 rows:**
| id    | name                  | category    | price  |
|-------|-----------------------|-------------|--------|
| 10000 | Product 10000         | Electronics | 677.82 |
| 10001 | Brand New Product     | Electronics | 999.99 |
| 10034 | Post-Failover Product | **Test**    | 79.99  |

💥 **SPLIT BRAIN VISUALIZED:**
- Old primary has ID 10002: "Old Primary Write"
- New primary has ID 10034: "Post-Failover Product"
- **Both servers think they're the master!**

### Resolving Split Brain (11:38:36 CET)

```bash
docker stop postgres-primary
```

✅ Old primary stopped to prevent further divergence

**MySQL vs PostgreSQL Split-Brain Protection:**

| Aspect                | MySQL                                      | PostgreSQL                          |
|-----------------------|--------------------------------------------|-------------------------------------|
| **Prevention**        | Manual (VIP, ProxySQL, Orchestrator)       | Timeline-based (built-in)           |
| **Old master rejoin** | Can rejoin with GTID or position           | **CANNOT rejoin automatically**     |
| **Safety**            | Depends on external tools                  | **Protected by timeline mismatch**  |
| **Data recovery**     | `mysqldump` + `CHANGE MASTER TO`           | `pg_rewind` (rewinds diverged data) |
| **Risk level**        | High (without orchestration)               | Low (timeline prevents corruption)  |

---

## 🧠 Key Learnings

### 1. Timeline Concept (PostgreSQL-Specific)

**What it is:**
- Timeline = failover counter/branch identifier
- Each promotion creates new timeline
- WAL filenames include timeline prefix
- Timeline history file records branch point

**Why it matters:**
- **Prevents accidental data corruption**
- Old primary **cannot rejoin** without manual intervention
- Forces operator to choose: use `pg_rewind` or rebuild from scratch

**MySQL equivalent:**
- No direct equivalent
- Closest: GTID (Global Transaction ID) but different purpose
- MySQL allows easier (but riskier) rejoin

### 2. Failover Process Comparison

**PostgreSQL Manual Failover:**
```sql
-- On standby:
SELECT pg_promote();

-- Verify:
SELECT pg_is_in_recovery();  -- Should return 'f' (false)
```

**MySQL Manual Failover:**
```sql
-- On standby:
STOP SLAVE;
RESET SLAVE ALL;

-- Verify:
SHOW SLAVE STATUS;  -- Should return empty
```

**Key differences:**
- PostgreSQL: Timeline protects against split-brain
- MySQL: Relies on external tools (MHA, Orchestrator, ProxySQL)
- PostgreSQL: `pg_promote()` is atomic and safe
- MySQL: Multiple steps, higher risk of human error

### 3. Split-Brain Experience

**What we saw:**
1. Old primary kept running after network split
2. Both servers accepted writes
3. Data diverged silently
4. Row counts matched but data was different

**Production implications:**
- **Never allow old primary to accept connections after failover**
- Use VIP (Virtual IP) or connection pooler
- Implement application-level routing
- Monitor timelines to detect split-brain

### 4. Recovery Options After Split-Brain

**Option 1: Discard old primary's data (safest)**
```bash
# Stop old primary
docker stop postgres-primary

# Rebuild from new primary (next scenario will cover this)
```

**Option 2: Use pg_rewind (if no logical conflicts)**
```bash
# Rewind old primary to match new primary's timeline
pg_rewind --target-pgdata=/var/lib/postgresql/data \
          --source-server='host=new-primary port=5432'
```

**MySQL equivalent:**
```bash
# Rebuild replica from master
mysqldump --all-databases --master-data=2 | mysql -h old_master
```

### 5. Promotion Verification Checklist

✅ `pg_is_in_recovery()` returns `false`  
✅ Timeline incremented  
✅ WAL receiver stopped (`pg_stat_wal_receiver` empty)  
✅ Can accept writes  
✅ Timeline history file created

---

## 📊 Performance Metrics

| Metric                        | Value            |
|-------------------------------|------------------|
| **Pre-failover lag**          | 0 bytes          |
| **Promotion time**            | ~5 seconds       |
| **LSN jump during promotion** | 0/639EC30 → 0/639EDC0 (192 bytes) |
| **Timeline change**           | 1 → 2            |
| **Data loss**                 | 0 rows (clean failover) |
| **Divergent writes (split-brain)** | 2 rows (old=1, new=1) |

---

## 🚨 Critical MySQL DBA Takeaways

### 1. Timeline vs GTID

**PostgreSQL Timeline:**
- **Purpose:** Track failover history, prevent split-brain
- **Format:** Integer counter (1, 2, 3...)
- **WAL files:** Include timeline prefix (00000001, 00000002)
- **Old server behavior:** **Cannot rejoin** different timeline

**MySQL GTID:**
- **Purpose:** Track transaction replication, enable easier failover
- **Format:** UUID:transaction_number (3E11FA47-71CA-11E1-9E33-C80AA9429562:1-5)
- **Binlog files:** Don't include GTID in filename
- **Old server behavior:** **Can rejoin** if GTID subset

**Key difference:** PostgreSQL timeline is **more restrictive** (safer) but requires more manual work to recover old primary.

### 2. Promotion Command Comparison

| Database   | Command                  | Requirements                | Safety                          |
|------------|--------------------------|-----------------------------|----------------------------------|
| PostgreSQL | `SELECT pg_promote();`   | Standby in recovery mode    | Very safe (timeline protection)  |
| MySQL      | `STOP SLAVE; RESET SLAVE ALL;` | Slave running  | Manual (relies on external VIP)  |

### 3. Post-Failover Topology

**PostgreSQL:**
```
Before:  Primary (TL1) ──> Standby (TL1)
After:   Old Primary (TL1, stopped)  ✗✗✗  New Primary (TL2)
```

**MySQL:**
```
Before:  Master ──> Slave
After:   Old Master (stopped)  ✗✗✗  New Master
         (can rejoin as slave with CHANGE MASTER TO)
```

### 4. Split-Brain Prevention

**PostgreSQL (built-in):**
- Timeline mismatch prevents old primary from rejoining
- Must use `pg_rewind` or full rebuild

**MySQL (external tools required):**
- MHA (Master High Availability)
- Orchestrator (GitHub)
- ProxySQL (connection routing)
- Manual VIP management

### 5. Data Recovery Complexity

**Scenario:** Old primary has 100 transactions not on new primary.

**PostgreSQL:**
```bash
# Option 1: Discard old data, rebuild
rm -rf /var/lib/postgresql/data
pg_basebackup -h new-primary -D /var/lib/postgresql/data

# Option 2: Rewind (if possible)
pg_rewind --target-pgdata=/var/lib/postgresql/data \
          --source-server='host=new-primary port=5432'
```

**MySQL:**
```sql
-- Option 1: Extract divergent transactions
mysqldump --skip-gtid old_master > divergent.sql
# Manually merge into new master

-- Option 2: Rebuild replica
CHANGE MASTER TO MASTER_HOST='new_master',
                 MASTER_AUTO_POSITION=1;
START SLAVE;
```

**Complexity:** PostgreSQL requires understanding timelines; MySQL requires GTID knowledge.

---

## 🎓 Quiz for MySQL DBAs

**Q1:** What is the PostgreSQL equivalent of MySQL's GTID for preventing split-brain?  
**A1:** Timeline. But they serve different purposes: GTID tracks transactions, timeline tracks failovers.

**Q2:** After failover, can the old PostgreSQL primary rejoin automatically?  
**A2:** No. Timeline mismatch prevents automatic rejoin. Must use `pg_rewind` or rebuild.

**Q3:** What happens if you promote a standby while primary is still running?  
**A3:** Split-brain! Both servers accept writes. Timeline prevents them from syncing again without manual intervention.

**Q4:** How do you verify a PostgreSQL promotion succeeded?  
**A4:** Check: (1) `pg_is_in_recovery()` = false, (2) timeline incremented, (3) can accept writes.

**Q5:** What's PostgreSQL's equivalent of `SHOW SLAVE STATUS`?  
**A5:** `SELECT * FROM pg_stat_wal_receiver;` (on standby) and `SELECT * FROM pg_stat_replication;` (on primary).

---

## 📝 Production Best Practices

### Do's ✅

1. **Always verify 0 lag before failover** (check `pg_stat_replication`)
2. **Use connection pooler** (PgBouncer, HAProxy) to redirect connections
3. **Monitor timelines** to detect accidental split-brain
4. **Document failover runbook** with timeline verification steps
5. **Test failover regularly** in non-production environment

### Don'ts ❌

1. **Never start old primary** without verifying timeline
2. **Don't skip timeline verification** after promotion
3. **Never assume zero data loss** (verify LSN positions)
4. **Don't use pg_rewind blindly** (understand data divergence first)
5. **Never failover with lag** (finish replication first)

---

## 🔄 Current Topology After Scenario

```
┌─────────────────────────────────────┐
│  postgres-primary (STOPPED)         │
│  Timeline: 1                        │
│  Last LSN: 0/639ECE0                │
│  Data: 10,002 products (divergent)  │
│  Status: Cannot rejoin without      │
│          pg_rewind or rebuild       │
└─────────────────────────────────────┘
                 ✗
                 ✗ (timeline mismatch)
                 ✗
┌─────────────────────────────────────┐
│  postgres-standby (NOW PRIMARY!)    │
│  Timeline: 2                        │
│  Current LSN: 0/63A07B8             │
│  Data: 10,002 products (divergent)  │
│  Status: WRITABLE, accepting        │
│          connections on port 5433   │
└─────────────────────────────────────┘
```

**Next steps:** Scenario 05 will cover rebuilding old primary as new standby.

---

## 📚 Related Documentation

- **TUTORIAL.md** → Section 4: Manual Failover Procedure
- **MySQL-Failover-Comparison.md** → Detailed MySQL vs PostgreSQL failover guide
- **Async-vs-Sync-Replication.md** → Section 11: Failover differences
- **QUICK_REFERENCE.md** → Failover commands cheatsheet
- **scenarios/05-network-interruption.md** → Next scenario (rebuilding after failover)

---

## ✅ Completion Status

**Scenario 04 completed successfully!**

**What we learned:**
- ✅ Manual failover process end-to-end
- ✅ Timeline concept and importance
- ✅ Split-brain scenario and detection
- ✅ PostgreSQL vs MySQL failover differences
- ✅ Production-ready promotion verification

**Ready for:** Scenario 05 - Network Interruption and Reconnection

**Estimated time for MySQL DBA:** 30-45 minutes to fully understand timeline concept

---

*Log completed: Sun Nov 16 11:38:36 CET 2025*  
*Executed by: MySQL DBA learning PostgreSQL*  
*Environment: Docker-based PostgreSQL 15.15 streaming replication*
