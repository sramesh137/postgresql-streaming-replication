# Scenario 08 Execution Log: Synchronous Replication

**Date:** November 17, 2025  
**Duration:** ~30 minutes  
**Status:** ✅ Completed Successfully

---

## 📋 Objectives

1. Configure synchronous replication for zero data loss
2. Measure performance impact of sync vs async
3. Demonstrate blocking behavior when sync standby fails
4. Understand trade-offs between consistency and availability

---

## 🔧 Step 1: Verify Current Replication State

### Command:
```bash
docker exec postgres-primary psql -U postgres -c "SELECT application_name, state, sync_state, sync_priority FROM pg_stat_replication ORDER BY application_name;"
```

### Result:
```
 application_name |   state   | sync_state | sync_priority 
------------------+-----------+------------+---------------
 walreceiver      | streaming | async      |             0
 walreceiver2     | streaming | async      |             0
(2 rows)
```

**Analysis:** Both standbys in async mode (sync_priority = 0)

---

## 🔧 Step 2: Configure Synchronous Replication

### Command:
```bash
docker exec postgres-primary psql -U postgres \
  -c "ALTER SYSTEM SET synchronous_commit = 'on';" \
  -c "ALTER SYSTEM SET synchronous_standby_names = 'walreceiver';" \
  -c "SELECT pg_reload_conf();"
```

### Result:
```
ALTER SYSTEM
ALTER SYSTEM
 pg_reload_conf 
----------------
 t
(1 row)
```

### Verification:
```bash
docker exec postgres-primary psql -U postgres \
  -c "SELECT application_name, state, sync_state, sync_priority FROM pg_stat_replication ORDER BY application_name;"
```

### Result:
```
 application_name |   state   | sync_state | sync_priority 
------------------+-----------+------------+---------------
 walreceiver      | streaming | sync       |             1  ✅ Now SYNC!
 walreceiver2     | streaming | async      |             0
(2 rows)
```

**Analysis:** 
- `walreceiver` (STANDBY1) is now **synchronous** (sync_priority = 1)
- `walreceiver2` (STANDBY2) remains **asynchronous**
- PRIMARY will wait for `walreceiver` confirmation before commit

---

## 🔧 Step 3: Performance Testing

### Create Test Table:
```bash
docker exec postgres-primary psql -U postgres \
  -c "CREATE TABLE IF NOT EXISTS perf_test (id serial PRIMARY KEY, data text, created_at timestamp DEFAULT now());"
```

### Test 1: ASYNC Performance (Baseline)
```bash
docker exec postgres-primary bash -c "time psql -U postgres -c \"SET synchronous_commit = off; INSERT INTO perf_test (data) SELECT 'async_data_' || i FROM generate_series(1, 1000) i;\""
```

**Result:**
```
INSERT 0 1000

real    0m0.028s
user    0m0.019s
sys     0m0.004s
```

**Performance:** ~28ms for 1000 inserts (async mode)

### Test 2: SYNC Performance
```bash
docker exec postgres-primary bash -c "time psql -U postgres -c \"SET synchronous_commit = on; INSERT INTO perf_test (data) SELECT 'sync_data_' || i FROM generate_series(1, 1000) i;\""
```

**Result:**
```
INSERT 0 1000

real    0m0.030s
user    0m0.020s
sys     0m0.003s
```

**Performance:** ~30ms for 1000 inserts (sync mode)

**Analysis:** 
- Performance difference minimal in localhost Docker environment
- Production with network latency would show 2-10x slowdown
- This is because both containers share same host and network

---

## 🔧 Step 4: Check Replication Lag

### Command:
```bash
docker exec postgres-primary psql -U postgres \
  -c "SELECT application_name, state, sync_state, sync_priority, write_lag, flush_lag, replay_lag FROM pg_stat_replication ORDER BY application_name;"
```

### Result:
```
 application_name |   state   | sync_state | sync_priority |    write_lag    |    flush_lag    |   replay_lag    
------------------+-----------+------------+---------------+-----------------+-----------------+-----------------
 walreceiver      | streaming | sync       |             1 | 00:00:00.00023  | 00:00:00.000729 | 00:00:00.000978
 walreceiver2     | streaming | async      |             0 | 00:00:00.000199 | 00:00:00.000708 | 00:00:00.000961
(2 rows)
```

**Analysis:**
- **write_lag:** ~0.2-0.3ms (time to send WAL to standby)
- **flush_lag:** ~0.7ms (time for standby to flush to disk)
- **replay_lag:** ~1ms (time for standby to apply changes)
- Minimal lag due to localhost environment

---

## 🔧 Step 5: Demonstrate Blocking Behavior

### Stop Synchronous Standby:
```bash
docker-compose stop postgres-standby
```

**Result:**
```
[+] Stopping 1/1
 ✔ Container postgres-standby  Stopped                                                         0.2s
```

### Verify Only STANDBY2 Remains:
```bash
docker exec postgres-primary psql -U postgres \
  -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

**Result:**
```
 application_name |   state   | sync_state 
------------------+-----------+------------
 walreceiver2     | streaming | async
(1 row)
```

**Analysis:** Synchronous standby (`walreceiver`) is gone!

### Attempt INSERT (Should Block):
```bash
timeout 5 docker exec postgres-primary psql -U postgres \
  -c "SET synchronous_commit = on; INSERT INTO perf_test (data) VALUES ('this_will_block'); SELECT 'Insert succeeded' as status;"
```

**Result:**
```
=== INSERT BLOCKED/TIMED OUT (as expected) ===
```

**Analysis:** ✅ **Write blocked** as expected! PRIMARY waits for synchronous standby confirmation.

### Test ASYNC Still Works:
```bash
docker exec postgres-primary psql -U postgres \
  -c "SET synchronous_commit = off; INSERT INTO perf_test (data) VALUES ('async_works_without_standby'); SELECT 'ASYNC insert succeeded even with standby down!' as status;"
```

**Result:**
```
INSERT 0 1
                     status                     
------------------------------------------------
 ASYNC insert succeeded even with standby down!
(1 row)
```

**Analysis:** ✅ ASYNC writes work fine even with standby down!

---

## 🔧 Step 6: Restore Synchronous Standby

### Recreate STANDBY1:
```bash
docker-compose stop postgres-standby
docker-compose rm -f postgres-standby
docker volume rm postgresql-streaming-replication_standby-data
docker-compose up -d postgres-standby
sleep 5
bash scripts/setup-replication.sh
```

**Result:** STANDBY1 recreated with fresh pg_basebackup

### Fix primary_conninfo (Bug Found):
The setup script copied config from PRIMARY which had wrong host. Fixed manually:

```bash
docker exec postgres-standby psql -U postgres \
  -c "ALTER SYSTEM SET primary_conninfo = 'host=postgres-primary port=5432 user=replicator password=replicator_password application_name=walreceiver';" \
  -c "SELECT pg_reload_conf();"
```

### Restart and Verify:
```bash
docker-compose restart postgres-standby
sleep 5
docker exec postgres-primary psql -U postgres \
  -c "SELECT application_name, state, sync_state, sync_priority FROM pg_stat_replication ORDER BY application_name;"
```

**Result:**
```
 application_name |   state   | sync_state | sync_priority 
------------------+-----------+------------+---------------
 walreceiver      | streaming | sync       |             1  ✅ Back online!
 walreceiver2     | streaming | async      |             0
(2 rows)
```

**Analysis:** ✅ Synchronous replication restored!

---

## 🔧 Step 7: Verify Data Consistency

### Check Row Count on All Servers:
```bash
echo "=== PRIMARY ===" && docker exec postgres-primary psql -U postgres -c "SELECT COUNT(*) FROM perf_test;"
echo "=== STANDBY1 ===" && docker exec postgres-standby psql -U postgres -c "SELECT COUNT(*) FROM perf_test;"
echo "=== STANDBY2 ===" && docker exec postgres-standby2 psql -U postgres -c "SELECT COUNT(*) FROM perf_test;"
```

**Result:**
```
=== PRIMARY ===
 count 
-------
  2101
  
=== STANDBY1 ===
 count 
-------
  2101
  
=== STANDBY2 ===
 count 
-------
  2101
```

**Analysis:** ✅ All servers have identical data (2101 rows)

---

## 📊 Key Findings

### 1. Configuration Changes
- **synchronous_commit:** `off` → `on`
- **synchronous_standby_names:** `''` → `'walreceiver'`
- Effect: PRIMARY waits for STANDBY1 confirmation before commit

### 2. Performance Impact
| Mode | Time (1000 inserts) | Relative |
|------|---------------------|----------|
| **Async** | 28ms | Baseline |
| **Sync** | 30ms | +7% |

**Note:** Minimal difference in localhost. Production with network would show 2-10x slowdown.

### 3. Availability Impact
- ✅ **With sync standby:** Writes succeed normally
- ❌ **Without sync standby:** Writes BLOCK indefinitely
- ✅ **ASYNC writes:** Work regardless of standby status

### 4. Data Consistency
- **Zero data loss guarantee:** If PRIMARY commits, STANDBY has the data
- **Perfect synchronization:** All 2101 rows identical across all servers
- **Replication lag:** <1ms in localhost environment

---

## ⚠️ Critical Lessons Learned

### 1. Synchronous Replication Blocks Without Standby
**Problem:** If the synchronous standby fails, ALL writes block.

**Solution Options:**
- Use `FIRST 1 (standby1, standby2)` - wait for ANY one standby
- Have monitoring to alert on standby failures
- Keep async as backup: `FIRST 1 (standby1, standby2, standby3)`
- Be prepared to disable sync in emergencies

### 2. Configuration Validation is Critical
**Bug Found:** `setup-replication.sh` copied config from PRIMARY which had wrong `primary_conninfo`

**Fix:** Manually set correct `primary_conninfo` on standby

**Prevention:** Improve setup script to properly configure standby

### 3. Performance Trade-off
| Aspect | Async | Sync |
|--------|-------|------|
| **Data Loss Risk** | High (seconds of data) | Zero |
| **Write Latency** | Low (~5-10ms) | High (~20-100ms) |
| **Availability** | High (continues if standby down) | Low (blocks if standby down) |
| **Use Case** | General applications | Financial/critical data |

### 4. Monitoring is Essential
Must monitor:
- `sync_state` in `pg_stat_replication`
- `sync_priority` to know which standby is sync
- Write latency (p99, p95)
- Standby health checks

---

## 🎓 Interview Talking Points

### When to Use Synchronous Replication?

**✅ Good Use Cases:**
- Financial transactions (payments, banking)
- Healthcare records (HIPAA compliance)
- Legal documents
- Any data where loss is unacceptable

**❌ Poor Use Cases:**
- Social media posts (can tolerate loss)
- Analytics data (can be regenerated)
- Caching layers
- Session data

### Configuration Options

**synchronous_commit levels:**
```sql
-- None (fastest, highest data loss risk)
SET synchronous_commit = off;

-- Local only (fast, risk if crash before ship to standby)
SET synchronous_commit = local;

-- Remote write (medium, standby received but not flushed)
SET synchronous_commit = remote_write;

-- On (strong, standby flushed to disk)
SET synchronous_commit = on;

-- Remote apply (strongest, standby applied changes)
SET synchronous_commit = remote_apply;
```

**synchronous_standby_names patterns:**
```sql
-- Single standby (blocks if it fails)
synchronous_standby_names = 'standby1'

-- Wait for ANY one of multiple standbys
synchronous_standby_names = 'FIRST 1 (standby1, standby2, standby3)'

-- Wait for specific number (e.g., 2 standbys)
synchronous_standby_names = 'FIRST 2 (standby1, standby2, standby3)'

-- All standbys must confirm (strongest, slowest)
synchronous_standby_names = 'ANY 3 (standby1, standby2, standby3)'
```

### Best Practices

1. **Use FIRST N pattern for HA:**
   ```sql
   synchronous_standby_names = 'FIRST 1 (standby1, standby2)'
   ```
   This prevents blocking if one standby fails.

2. **Monitor religiously:**
   - Alert if sync standby disconnects
   - Track write latency p99
   - Watch for timeouts in application

3. **Have emergency plan:**
   ```sql
   -- Emergency: Disable sync to restore availability
   ALTER SYSTEM SET synchronous_standby_names = '';
   SELECT pg_reload_conf();
   ```

4. **Test failover regularly:**
   - Simulate standby failure
   - Measure application impact
   - Verify blocking behavior
   - Test recovery procedures

---

## 🔗 Related Scenarios

- **Scenario 07:** Multi-standby setup (prerequisite)
- **Scenario 09:** Monitoring replication (next)
- **Scenario 10:** Disaster recovery (uses sync concepts)

---

## 📝 Commands Reference

### Enable Synchronous Replication:
```sql
ALTER SYSTEM SET synchronous_commit = 'on';
ALTER SYSTEM SET synchronous_standby_names = 'walreceiver';
SELECT pg_reload_conf();
```

### Check Sync Status:
```sql
SELECT application_name, state, sync_state, sync_priority 
FROM pg_stat_replication;
```

### Emergency Disable:
```sql
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
```

### Measure Lag:
```sql
SELECT application_name, write_lag, flush_lag, replay_lag 
FROM pg_stat_replication;
```

---

## ✅ Completion Checklist

- [x] Configured synchronous replication
- [x] Verified sync_state changed from async to sync
- [x] Measured performance impact (minimal in localhost)
- [x] Demonstrated write blocking when sync standby down
- [x] Showed async writes continue working
- [x] Restored synchronous standby
- [x] Verified data consistency across all servers
- [x] Documented configuration and trade-offs
- [x] Created troubleshooting guide
- [x] Prepared interview talking points

**Status:** ✅ Scenario 08 Complete!

---

**Next:** Scenario 09 - Replication Monitoring
