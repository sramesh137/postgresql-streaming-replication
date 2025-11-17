# Scenario 08: Synchronous Replication - Zero Data Loss

**Difficulty:** Advanced  
**Duration:** 30-35 minutes  
**Prerequisites:** Understanding of async replication

## 🎯 Learning Objectives

- Configure synchronous replication
- Understand performance tradeoffs
- Compare async vs sync replication
- Learn when to use synchronous mode
- Measure latency impact

## 📚 Background

**Synchronous replication** waits for standby confirmation before completing transactions:
- **Zero data loss** guarantee
- **Higher latency** on writes
- **Standby availability critical** (blocks if standby down)

### Async vs Sync:
```
ASYNC:  Client → Primary → "OK!" → (later) → Standby
SYNC:   Client → Primary → Wait → Standby confirms → "OK!"
```

---

## Step 1: Configure Synchronous Commit

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Enable synchronous replication
ALTER SYSTEM SET synchronous_commit = 'on';
ALTER SYSTEM SET synchronous_standby_names = 'standby1';

-- Reload configuration
SELECT pg_reload_conf();

-- Verify
SHOW synchronous_commit;
SHOW synchronous_standby_names;
EOF
```

---

## Step 2: Test Write Performance

### Async Performance (baseline):
```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Temporarily set to async for this session
SET synchronous_commit = off;

\timing on
INSERT INTO users (username, email)
SELECT 'async_' || i, 'async' || i || '@test.com'
FROM generate_series(1, 1000) i;
\timing off
EOF
```

### Sync Performance:
```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Use synchronous commit
SET synchronous_commit = on;

\timing on
INSERT INTO users (username, email)
SELECT 'sync_' || i, 'sync' || i || '@test.com'
FROM generate_series(1, 1000) i;
\timing off
EOF
```

---

## Step 3: Compare Latencies

Record the timing differences and calculate performance impact percentage.

---

## Step 4: Test Failure Scenario

Stop standby and observe that writes block when standby is unavailable in sync mode.

---

## 🎓 Key Takeaways

✅ **Sync replication guarantees** zero data loss  
✅ **Performance tradeoff** - higher write latency  
✅ **Standby availability critical** - can block writes  
✅ **Use for critical transactions** only  
✅ **Consider remote_apply** for read-after-write consistency  

---

## ➡️ Next: [Scenario 09: Replication Monitoring](./09-monitoring-queries.md)
