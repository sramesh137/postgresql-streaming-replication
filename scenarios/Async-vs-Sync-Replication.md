# Streaming Replication: Async vs Sync Explained

**For MySQL DBAs:** This is PostgreSQL's equivalent of MySQL's async/semi-sync replication, but with more granular control!

**Quick Answer:** "Streaming replication" refers to **HOW** data is transmitted (real-time stream), not **WHETHER** it's synchronous or asynchronous. You can have **both**:
- ✅ Asynchronous Streaming Replication (your current setup) = MySQL Async Replication
- ✅ Synchronous Streaming Replication (alternative) = MySQL Semi-Sync Replication

---

## 🔄 MySQL vs PostgreSQL: Quick Mapping

| MySQL Term | PostgreSQL Equivalent | What It Means |
|------------|----------------------|---------------|
| **Async Replication** | Async Streaming Replication | Master doesn't wait for slave |
| **Semi-Sync Replication** | Synchronous Streaming Replication | Master waits for slave ACK |
| `Slave_IO_Running` | `state: streaming` | Replication is active |
| `Seconds_Behind_Master` | `replay_lag` (in milliseconds) | How far behind replica is |
| Binlog position | LSN (Log Sequence Number) | Location in log stream |
| `rpl_semi_sync_master_enabled` | `synchronous_standby_names` | Enable sync mode |
| `SHOW SLAVE STATUS` | `SELECT * FROM pg_stat_replication` | Check replication status |

---

## 🎯 Your Current Configuration

```sql
-- Your setup:
SELECT application_name, state, sync_state FROM pg_stat_replication;

Result:
application_name |   state   | sync_state 
-----------------+-----------+------------
standby1         | streaming | async
```

**Configuration:**
- ✅ **Streaming:** YES (real-time WAL transmission)
- ✅ **sync_state:** async (asynchronous)
- ✅ **synchronous_commit:** off
- ✅ **synchronous_standby_names:** (empty)

**Type:** **Asynchronous Streaming Replication**

---

## 📡 Understanding "Streaming"

### Streaming Replication = Transport Method

**Definition:** WAL changes are sent continuously in real-time from primary to standby.

**How it works:**
```
Primary → [WAL Stream] → Standby
   ↓                        ↓
Continuous                Applied
flow of data              immediately
```

**Alternative (old method):**
- **File-based shipping:** WAL files copied after they're filled (batch mode)
- **Streaming is better:** Real-time, lower lag

**Bottom line:** "Streaming" = **how fast** data travels, not **when commits return**

---

## ⚖️ Async vs Sync: The Key Difference

### Asynchronous (Your Current Setup)

**MySQL Equivalent:** Traditional Async Replication (default mode)

**What happens when you commit:**

```
PostgreSQL Timeline:
┌─────────────────────────────────────────────────────────────┐
│ 1. INSERT data                                               │
│ 2. Write to primary's WAL                                    │
│ 3. COMMIT returns to client ✅ ← You get control back here  │
│ 4. Stream WAL to standby (background)                        │
│ 5. Standby applies WAL                                       │
└─────────────────────────────────────────────────────────────┘

MySQL Timeline (IDENTICAL behavior):
┌─────────────────────────────────────────────────────────────┐
│ 1. INSERT data                                               │
│ 2. Write to master's binlog                                  │
│ 3. COMMIT returns to client ✅ ← You get control back here  │
│ 4. IO thread sends binlog to slave (background)             │
│ 5. SQL thread applies changes on slave                       │
└─────────────────────────────────────────────────────────────┘
```

**Key point:** Primary **does NOT wait** for standby before returning SUCCESS.

**Your PostgreSQL results:**
- 100,000 rows in 807ms = ~124,000 rows/second
- Commit latency: ~0.15ms
- Lag: 0 bytes (but data loss risk exists)

**MySQL comparison:**
- Similar throughput: ~100K-150K rows/sec
- Lag measured in: `Seconds_Behind_Master` (vs PostgreSQL's milliseconds)
- Same risk: Transactions committed but not yet on slave can be lost

**Risk (both databases):**
- If primary/master crashes between step 3 and 5, last few transactions lost
- PostgreSQL risk window: ~0.17ms (your write_lag measurement)
- MySQL risk window: Usually 1-3 seconds (depends on binlog sync frequency)

---

### Synchronous (Alternative Configuration)

**MySQL Equivalent:** Semi-Synchronous Replication (`rpl_semi_sync_master_enabled=1`)

**What happens when you commit:**

```
PostgreSQL Timeline:
┌─────────────────────────────────────────────────────────────┐
│ 1. INSERT data                                               │
│ 2. Write to primary's WAL                                    │
│ 3. Stream WAL to standby                                     │
│ 4. Standby receives and writes WAL                           │
│ 5. Standby sends ACK to primary                              │
│ 6. COMMIT returns to client ✅ ← You get control back here  │
└─────────────────────────────────────────────────────────────┘

MySQL Semi-Sync Timeline (IDENTICAL behavior):
┌─────────────────────────────────────────────────────────────┐
│ 1. INSERT data                                               │
│ 2. Write to master's binlog                                  │
│ 3. Send binlog to slave                                      │
│ 4. Slave receives and writes to relay log                    │
│ 5. Slave sends ACK to master                                 │
│ 6. COMMIT returns to client ✅ ← You get control back here  │
└─────────────────────────────────────────────────────────────┘
```

**Key point:** Primary **waits** for standby confirmation before returning SUCCESS.

**Expected PostgreSQL performance:**
- Throughput: 50-70% of async (network dependent)
- Commit latency: + network round-trip (~1-5ms local, 50-200ms WAN)
- **Zero data loss guarantee** ✅

**MySQL Semi-Sync performance (similar):**
- Throughput: 40-60% of async
- Commit latency: + network RTT + `rpl_semi_sync_master_timeout` (default 10s)
- Same guarantee: Zero data loss

**Protection (both databases):**
- If primary/master crashes, standby/slave ALWAYS has all committed data
- No risk window

**Key Difference:**
- **PostgreSQL:** Can configure per-transaction (`SET LOCAL synchronous_commit`)
- **MySQL:** Global setting only (`SET GLOBAL rpl_semi_sync_master_enabled`)

---

## 📊 Detailed Comparison: PostgreSQL vs MySQL

| Aspect | PostgreSQL Async | MySQL Async | PostgreSQL Sync | MySQL Semi-Sync |
|--------|------------------|-------------|-----------------|-----------------|
| **Config Variable** | `synchronous_commit=off` | (default mode) | `synchronous_standby_names='...'` | `rpl_semi_sync_master_enabled=1` |
| **Commit Speed** | ⚡ ~0.15ms | ⚡ ~0.2-1ms | 🐌 +network RTT | 🐌 +network RTT |
| **Your Throughput** | 🚀 121K rows/sec | ~100-150K rows/sec | 📉 60-85K rows/sec | 📉 50-90K rows/sec |
| **Data Loss Risk** | ⚠️ 0.17ms window | ⚠️ 1-3s window | ✅ Zero | ✅ Zero |
| **Lag Measurement** | write/flush/replay_lag | `Seconds_Behind_Master` | Same | Same |
| **Lag Units** | Milliseconds + Bytes | Seconds only | Milliseconds + Bytes | Seconds only |
| **Replica Failure** | 😊 Primary unaffected | 😊 Master unaffected | 😱 Primary blocks* | 😱 Master falls back to async* |
| **Per-Transaction Control** | ✅ `SET LOCAL synchronous_commit` | ❌ Global only | ✅ Per transaction | ❌ Global only |
| **Monitoring Query** | `SELECT * FROM pg_stat_replication` | `SHOW SLAVE STATUS\G` | Same | Same |

*Can be configured to fall back to async mode if standby/slave fails

---

## 🎭 Real-World Analogy

### Asynchronous = Email

```
You: Send email → ✅ "Sent" confirmation immediately
Reality: Email still traveling to recipient
Risk: If server crashes, email might be lost
```

### Synchronous = Certified Mail

```
You: Send package → ⏳ Wait for delivery confirmation
Reality: Recipient signs, you get receipt
Risk: None - guaranteed delivery before you leave post office
```

---

## 🔧 Configuration Commands: PostgreSQL vs MySQL

### Enable Synchronous/Semi-Sync Replication

**PostgreSQL:**

```sql
-- Step 1: Configure primary
ALTER SYSTEM SET synchronous_standby_names = 'standby1';
ALTER SYSTEM SET synchronous_commit = on;

-- Step 2: Reload configuration (no restart needed!)
SELECT pg_reload_conf();

-- Step 3: Verify
SELECT application_name, sync_state FROM pg_stat_replication;
-- Should show: sync_state = sync
```

**MySQL:**

```sql
-- Step 1: Install plugin on master
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';

-- Step 2: Enable on master
SET GLOBAL rpl_semi_sync_master_enabled = 1;
SET GLOBAL rpl_semi_sync_master_timeout = 10000; -- 10 seconds

-- Step 3: Install plugin on slave
INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';

-- Step 4: Enable on slave
SET GLOBAL rpl_semi_sync_slave_enabled = 1;

-- Step 5: Restart slave I/O thread
STOP SLAVE IO_THREAD;
START SLAVE IO_THREAD;

-- Step 6: Verify
SHOW STATUS LIKE 'Rpl_semi_sync_master_status';
-- Should show: ON
```

**Winner:** PostgreSQL (simpler, no plugins, no restart)

**Step 3: Verify**
```sql
SELECT application_name, state, sync_state FROM pg_stat_replication;

Expected Result:
application_name |   state   | sync_state 
-----------------+-----------+------------
standby1         | streaming | sync       ← Changed!
```

---

### Revert to Asynchronous

```sql
-- On primary:
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
```

---

## 📊 Monitoring Commands Comparison

### Check Replication Status

**PostgreSQL:**
```sql
-- Comprehensive replication view:
SELECT 
    application_name,
    client_addr,
    state,                -- 'streaming' = active
    sync_state,           -- 'async' or 'sync'
    pg_current_wal_lsn() as current_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as lag_bytes,
    write_lag,            -- Network time
    flush_lag,            -- Disk write time
    replay_lag            -- Apply time
FROM pg_stat_replication;

-- Result:
 application_name | state     | sync_state | lag_bytes | write_lag | flush_lag | replay_lag 
------------------+-----------+------------+-----------+-----------+-----------+------------
 standby1         | streaming | async      | 0 bytes   | 00:00:00.00017 | 00:00:00.00059 | 00:00:00.00066
```

**MySQL:**
```sql
-- Traditional slave status:
SHOW SLAVE STATUS\G

-- Key fields:
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
Master_Log_File: mysql-bin.000123
Read_Master_Log_Pos: 4567
Relay_Log_Space: 12345
```

**PostgreSQL Advantages:**
- ✅ Three lag metrics (write/flush/replay) vs one (Seconds_Behind_Master)
- ✅ Lag in both bytes AND time
- ✅ Real-time LSN tracking
- ✅ Can see exact network vs disk vs apply latency

---

### Check if Sync/Semi-Sync is Active

**PostgreSQL:**
```sql
-- Check configuration:
SHOW synchronous_commit;
SHOW synchronous_standby_names;

-- Check actual state:
SELECT sync_state FROM pg_stat_replication;
-- Result: 'sync' or 'async'
```

**MySQL:**
```sql
-- Check if enabled:
SHOW VARIABLES LIKE 'rpl_semi_sync%';

-- Check status:
SHOW STATUS LIKE 'Rpl_semi_sync_master_status';
-- Result: ON or OFF

SHOW STATUS LIKE 'Rpl_semi_sync_master_clients';
-- Result: Number of semi-sync slaves connected
```

---

## 🎯 Per-Transaction Control (PostgreSQL Advantage!)

**PostgreSQL:** Can choose **per transaction** ✅

### Critical Transaction (Force Sync)
```sql
BEGIN;
SET LOCAL synchronous_commit = on;  -- Wait for standby for THIS transaction only
INSERT INTO financial_transactions (amount, account) VALUES (10000.00, 'ACC123');
COMMIT;  -- Waits for standby confirmation
```

### Fast Transaction (Allow Async)
```sql
BEGIN;
SET LOCAL synchronous_commit = off;  -- Don't wait
INSERT INTO page_views (url, timestamp) VALUES ('/home', NOW());
COMMIT;  -- Returns immediately
```

**MySQL:** Global setting only ❌

```sql
-- Must change globally (affects ALL connections):
SET GLOBAL rpl_semi_sync_master_enabled = 1;  -- All transactions wait
SET GLOBAL rpl_semi_sync_master_enabled = 0;  -- No transactions wait

-- Cannot do per-transaction control!
```

**PostgreSQL wins here:** Mix critical and non-critical transactions in same application!

### Application Example
```python
# Critical: Payment processing
cursor.execute("SET LOCAL synchronous_commit = on;")
cursor.execute("INSERT INTO payments ...")
conn.commit()  # Waits for replica

# Non-critical: Logging
cursor.execute("SET LOCAL synchronous_commit = off;")
cursor.execute("INSERT INTO access_logs ...")
conn.commit()  # Fast return
```

---

## 🧪 Test It Yourself (Optional)

### Measure Current Async Performance

```bash
# 100 inserts, measure time
docker exec postgres-primary psql -U postgres -c "
SELECT insert_bulk_users(100);
"
# Expected: < 10ms
```

### Switch to Sync and Compare

```bash
# Enable sync
docker exec postgres-primary psql -U postgres -c "
ALTER SYSTEM SET synchronous_standby_names = 'standby1';
ALTER SYSTEM SET synchronous_commit = on;
SELECT pg_reload_conf();
"

# Same test
docker exec postgres-primary psql -U postgres -c "
SELECT insert_bulk_users(100);
"
# Expected: Slower (network latency added)

# Check sync_state changed
docker exec postgres-primary psql -U postgres -c "
SELECT application_name, sync_state FROM pg_stat_replication;
"
# Should show: sync_state = sync
```

---

## 🎓 When to Use Each

### Use Asynchronous (Your Current Setup) For:

✅ **High-performance applications**
- Web analytics
- Session storage
- Caching layers
- Log aggregation
- Real-time metrics

✅ **When:**
- Throughput matters more than guaranteed durability
- Brief data loss (milliseconds) is acceptable
- Network latency would hurt user experience

---

### Use Synchronous For:

✅ **Mission-critical data**
- Financial transactions
- E-commerce orders
- Payment processing
- Medical records
- Audit trails

✅ **When:**
- Zero data loss is required
- Regulatory compliance mandates
- Can tolerate slower commits
- RPO (Recovery Point Objective) = 0

---

## 💡 Industry Patterns

### Pattern 1: Hybrid Configuration

```
Production Setup:
├── Primary (sync_commit = on)
├── Standby 1 (synchronous) ← Zero data loss
└── Standby 2 (asynchronous) ← Read scaling
```

Configure:
```ini
synchronous_standby_names = 'standby1'  # Only standby1 is sync
```

Result:
- Standby1: sync (guaranteed delivery)
- Standby2: async (fast, for reads)

---

### Pattern 2: Quorum-based Sync

```ini
synchronous_standby_names = 'ANY 1 (standby1, standby2)'
```

Meaning: Wait for **any 1** of 2 standbys to confirm.

**Benefit:** 
- If one standby is slow/down, other can confirm
- No single point of failure

---

## 🔍 Monitoring Queries

### Check Current Mode
```sql
-- On primary:
SHOW synchronous_commit;
SHOW synchronous_standby_names;

-- Check sync state:
SELECT application_name, state, sync_state, sync_priority
FROM pg_stat_replication;
```

### Monitor Sync Performance Impact
```sql
-- Track how long commits are waiting:
SELECT 
    application_name,
    sync_state,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

If sync mode:
- `write_lag` = time waiting for standby to receive
- Higher values = slower commits

---

## ❓ Common Questions

### Q: Can I have streaming replication without it being sync or async?

**A:** No. **All** replication is either:
- Asynchronous (don't wait)
- Synchronous (wait for confirmation)

"Streaming" just means **how** WAL is transmitted (real-time vs file-based).

---

### Q: Is async replication unreliable?

**A:** No! It's very reliable:
- Your tests: 0 byte lag (sub-millisecond replication)
- Data loss risk: only if primary crashes in tiny window (0.17ms)
- Most companies use async successfully

---

### Q: Why is my sync_state = async if I have streaming replication?

**A:** Because:
- `streaming` in the `state` column = HOW data is transmitted (real-time)
- `async` in the `sync_state` column = WHEN commits return (immediately)

Both are independent settings!

---

### Q: Can one standby be sync and another async?

**A:** Yes! Common pattern:
```ini
synchronous_standby_names = 'standby1'
```

Result:
- standby1: sync (zero data loss)
- standby2: async (read scaling)
- standby3: async (DR site in different region)

---

## ✅ Summary

**Your Current Setup:**
```
Mode: Asynchronous Streaming Replication
  ├── Streaming: ✅ Real-time WAL transmission
  ├── Async: ✅ Commits return immediately
  ├── Performance: 🚀 121K rows/second
  └── Protection: ⚠️ Millisecond data loss risk

Perfect for: High-throughput applications where brief data loss acceptable
```

**Alternative:**
```
Mode: Synchronous Streaming Replication
  ├── Streaming: ✅ Real-time WAL transmission
  ├── Sync: ⏳ Commits wait for standby
  ├── Performance: 📉 50-70% of async
  └── Protection: ✅ Zero data loss

Perfect for: Mission-critical data requiring guarantees
```

---

## 🏆 PostgreSQL vs MySQL: Feature Comparison Summary

| Feature | PostgreSQL | MySQL | Winner |
|---------|------------|-------|--------|
| **Setup Complexity** | Simple config, no plugins | Requires plugins on master & slave | 🏆 PostgreSQL |
| **Hot Reload** | ✅ `pg_reload_conf()` | ❌ Requires slave restart | 🏆 PostgreSQL |
| **Lag Granularity** | 3 metrics (write/flush/replay) | 1 metric (seconds behind) | 🏆 PostgreSQL |
| **Lag Units** | Bytes + Milliseconds | Seconds only | 🏆 PostgreSQL |
| **Per-Transaction Control** | ✅ `SET LOCAL synchronous_commit` | ❌ Global only | 🏆 PostgreSQL |
| **Quorum Sync** | ✅ `ANY N (...)` syntax | ❌ Not available | 🏆 PostgreSQL |
| **Monitoring Views** | Rich `pg_stat_replication` | Basic `SHOW SLAVE STATUS` | 🏆 PostgreSQL |
| **Ecosystem Maturity** | Excellent | Excellent | 🤝 Tie |
| **Performance (Async)** | ~121K rows/sec (your test) | ~100-150K rows/sec | 🤝 Tie |
| **Physical Replication** | ✅ Built-in (what you're using) | ❌ (MySQL uses logical) | 🏆 PostgreSQL |
| **Logical Replication** | ✅ Also available | ✅ Primary method | 🤝 Tie |

**Overall:** PostgreSQL has more advanced replication features and easier management!

---

## 💼 Real-World Migration Tips (MySQL DBA → PostgreSQL)

### Common Misconceptions to Avoid:

1. **❌ "I need to install plugins for semi-sync"**
   - ✅ PostgreSQL: Built-in, just set `synchronous_standby_names`

2. **❌ "Lag is measured in seconds like MySQL"**
   - ✅ PostgreSQL: Sub-millisecond granularity (write/flush/replay_lag)

3. **❌ "I need to restart after changing sync settings"**
   - ✅ PostgreSQL: Just `pg_reload_conf()`, no restart!

4. **❌ "Sync mode is all-or-nothing for the server"**
   - ✅ PostgreSQL: Can mix sync/async per transaction!

5. **❌ "SHOW SLAVE STATUS is the monitoring command"**
   - ✅ PostgreSQL: `SELECT * FROM pg_stat_replication`

### What Stays the Same:

✅ Replication lag increases under heavy write load (both)  
✅ Sync mode reduces throughput ~40-60% (both)  
✅ Zero data loss requires waiting for replica (both)  
✅ Async mode is faster but risks data loss (both)  
✅ Network latency directly impacts sync performance (both)

---

## 🎓 Quick Quiz for MySQL DBAs

Test your understanding:

1. **What's the PostgreSQL equivalent of `SHOW SLAVE STATUS`?**
   - Answer: `SELECT * FROM pg_stat_replication;`

2. **What's the PostgreSQL equivalent of `rpl_semi_sync_master_enabled=1`?**
   - Answer: `synchronous_standby_names = 'standby1'`

3. **In PostgreSQL, can you have one transaction sync and another async?**
   - Answer: ✅ Yes! Use `SET LOCAL synchronous_commit`

4. **What's better than MySQL's `Seconds_Behind_Master`?**
   - Answer: PostgreSQL's three lag metrics: write_lag, flush_lag, replay_lag

5. **Do you need to restart after enabling synchronous replication?**
   - Answer: ❌ No! Just `SELECT pg_reload_conf();`

---

## 🚀 Key Takeaways for MySQL DBAs

**"Streaming replication" = transport method (always real-time)**
- MySQL equivalent: Binlog streaming (vs polling)

**sync_state (async/sync) = transaction behavior (when commits return)**
- MySQL equivalent: Async vs Semi-Sync

**PostgreSQL Advantages:**
- 🎯 More granular lag monitoring (3 metrics vs 1)
- 🎯 Per-transaction sync control
- 🎯 Simpler configuration (no plugins)
- 🎯 No restart required for changes
- 🎯 Physical replication = faster

**You have:** Async streaming = MySQL async (maximum performance)  
**You could have:** Sync streaming = MySQL semi-sync (zero data loss)

**Best practice:** Same as MySQL - use async for most workloads, sync for critical transactions!

---

**Your current setup is perfect for learning and most real-world applications!** 🎯

**Coming from MySQL?** You'll love PostgreSQL's replication features - they're more powerful and easier to manage!
