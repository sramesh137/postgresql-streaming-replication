# MySQL DBA → PostgreSQL Replication Cheatsheet

**For:** MySQL DBAs learning PostgreSQL Streaming Replication  
**Focus:** Key differences and equivalent concepts

---

## 🔄 Replication Concepts Comparison

| Concept | MySQL | PostgreSQL |
|---------|-------|------------|
| **Log Type** | Binary Log (binlog) | Write-Ahead Log (WAL) |
| **Position Tracking** | `(file, position)` <br/>e.g., `(mysql-bin.000123, 4567)` | **LSN** (Log Sequence Number) <br/>e.g., `0/3020A50` |
| **Modern Tracking** | GTID (Global Transaction ID) | Timeline + LSN |
| **Lag Measurement** | `Seconds_Behind_Master` (single metric) | **3 metrics**: write_lag, flush_lag, replay_lag |
| **Lag Units** | Seconds only | Bytes + Milliseconds |
| **Replication Type** | Logical (row-based/statement) | **Physical** (byte-level copy) |
| **Protection** | Manual binlog retention | **Replication Slot** (auto-holds WAL) |

---

## 📊 Monitoring Commands Comparison

### Check Replication Status

**MySQL:**
```sql
SHOW SLAVE STATUS\G
-- Key fields:
-- Slave_IO_Running: Yes
-- Slave_SQL_Running: Yes
-- Seconds_Behind_Master: 0
-- Master_Log_File: mysql-bin.000123
-- Read_Master_Log_Pos: 4567
```

**PostgreSQL (on Primary):**
```sql
SELECT * FROM pg_stat_replication;
-- Key fields:
-- state: streaming
-- sent_lsn, replay_lsn (positions)
-- write_lag, flush_lag, replay_lag (time)
-- sync_state: async/sync
```

---

### Check Current Position

**MySQL (on Master):**
```sql
SHOW MASTER STATUS;
-- Returns: File, Position, Binlog_Do_DB, Binlog_Ignore_DB
```

**PostgreSQL (on Primary):**
```sql
SELECT pg_current_wal_lsn();
-- Returns: 0/3020A50 (hex format)
```

---

### Calculate Lag

**MySQL:**
```sql
SHOW SLAVE STATUS\G
-- Look at: Seconds_Behind_Master
```

**PostgreSQL:**
```sql
-- Lag in bytes:
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) 
FROM pg_stat_replication;

-- Lag in human-readable:
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn))
FROM pg_stat_replication;

-- Time-based lag:
SELECT write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

---

## 🔐 Replication Safety Features

### Prevent Data Loss During Replica Downtime

**MySQL Problem:**
- If slave is down for long time, master might purge binlogs
- Need to manually set `expire_logs_days` or `binlog_expire_logs_seconds`
- Risk: Slave comes back, binlog gone = need full rebuild

**PostgreSQL Solution:**
- **Replication Slots** automatically hold WAL files
- Even if standby is down for days, WAL is retained
- No manual configuration needed (built-in safety)

```sql
-- Check slot status:
SELECT slot_name, active, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained
FROM pg_replication_slots;
```

---

## 🎯 LSN Deep Dive (PostgreSQL's "Position")

### Understanding LSN Format

**Format:** `timeline/offset` in hexadecimal

Example: `0/3020A50`
- `0` = Timeline (increments after failover)
- `3020A50` = Byte offset in WAL stream (hex)

**Your Scenario 01 Results:**
- Started: `0/3020A50`
- After 100K inserts: `0/4E54DA0`
- Difference: ~26 MB of WAL generated

### LSN Math

```sql
-- Calculate WAL difference:
SELECT pg_wal_lsn_diff('0/4E54DA0', '0/3020A50') as bytes_generated;
-- Result: ~27,000,000 bytes = ~26 MB

-- Human readable:
SELECT pg_size_pretty(pg_wal_lsn_diff('0/4E54DA0', '0/3020A50'));
-- Result: 26 MB
```

---

## ⚡ Lag Types Explained

### MySQL: Single Metric
```
Seconds_Behind_Master: 2
```
**What it means:** Replica is 2 seconds behind (that's all you know)

### PostgreSQL: Three-Stage Pipeline

```
write_lag:  0.17ms  ← WAL written to standby's OS cache
flush_lag:  0.59ms  ← WAL flushed to standby's disk
replay_lag: 0.66ms  ← WAL applied to standby's database
```

**Why it matters:**
- **High write_lag?** Network problem
- **High flush_lag?** Slow standby disk I/O
- **High replay_lag?** Standby CPU overloaded or complex queries

**Diagnosis Example:**
```
write_lag:  2000ms  ← Network bottleneck!
flush_lag:  5ms
replay_lag: 3ms
```
→ **Action:** Check network between servers

---

## 🔄 Transaction Behavior

### Both MySQL and PostgreSQL:
- Transactions don't replicate until **COMMIT**
- Rollback prevents replication
- Large transactions cause lag spikes at commit time

### Example Behavior:

```sql
-- This takes 10 seconds on primary:
BEGIN;
INSERT INTO users ... (10 million rows)
-- During this time: NO lag increase (not replicated yet)
COMMIT;
-- NOW: Lag spikes as standby applies all at once
```

**Your Results:**
- 100,000 row insert in 806ms
- Lag: 0 bytes (standby kept up in real-time)
- Why? Docker localhost = no network latency

---

## 📈 Performance Results from Your Tests

| Test | Rows | Duration | Throughput | Lag |
|------|------|----------|------------|-----|
| Light | 1,000 | 8.89ms | 112K rows/sec | 32 bytes |
| Medium | 10,000 | 78ms | 128K rows/sec | 0 bytes |
| Heavy | 100,000 | 807ms | 124K rows/sec | 0 bytes |

**Average:** ~**121,000 rows/second** with near-zero lag

---

## 🛠️ Common Admin Tasks

### Start/Stop Replication

**MySQL:**
```sql
STOP SLAVE;
START SLAVE;
SHOW SLAVE STATUS\G
```

**PostgreSQL:**
```sql
-- On standby (no direct command):
-- Stop: Shut down standby
-- Start: Start standby (auto-connects)

-- On primary, check:
SELECT * FROM pg_stat_replication;
```

---

### Failover/Promotion

**MySQL:**
```sql
-- On slave:
STOP SLAVE;
RESET SLAVE ALL;
-- Make it writeable (remove read_only)
SET GLOBAL read_only = 0;
```

**PostgreSQL:**
```bash
# On standby:
pg_ctl promote
# Or:
touch /tmp/postgresql.trigger.5433
# Or:
SELECT pg_promote();
```

---

### Check Replica is Read-Only

**MySQL:**
```sql
SHOW VARIABLES LIKE 'read_only';
-- Should be: ON
```

**PostgreSQL:**
```sql
SELECT pg_is_in_recovery();
-- Should return: true (means read-only standby)

-- Try to write (should fail):
INSERT INTO users ... 
-- ERROR: cannot execute INSERT in a read-only transaction
```

---

## 🎓 Key Takeaways for MySQL DBAs

1. **LSN = GTID/Position equivalent** (but in hex, never resets)

2. **Physical replication = faster** (byte copy vs logical parsing)

3. **Three lag metrics > one** (better troubleshooting)

4. **Replication slots = built-in safety** (no manual binlog retention config)

5. **Standby is truly read-only** (no need for `read_only` variable)

6. **Hot Standby** = read queries allowed on standby (like MySQL slave)

7. **Streaming = real-time** (not polling binlog every X seconds)

---

## 🔍 Monitoring View You Created

```sql
CREATE VIEW replication_health AS
SELECT 
    application_name,
    client_addr,
    state,                    -- 'streaming' = healthy
    sync_state,               -- 'async' or 'sync'
    pg_current_wal_lsn() as current_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as lag_size,
    replay_lag,               -- Time lag
    write_lag,
    flush_lag
FROM pg_stat_replication;
```

**Quick check:**
```sql
SELECT * FROM replication_health;
```

---

## ❓ Common Questions

### Q: Why measure lag in bytes AND milliseconds?

**A:** 
- **Bytes** = How much data behind (useful for estimating catch-up time)
- **Milliseconds** = How old the data is (useful for application SLAs)

Example: 
- Lag: 10 MB, 2 seconds
- Means: Standby is 2 seconds behind and needs to apply 10 MB of changes

---

### Q: Is 0-byte lag realistic in production?

**A:** 
- **In your Docker test:** Yes (localhost, no network latency)
- **In real production:** Typically 0-100 KB lag, 1-50ms is normal
- **Cross-datacenter:** Could be MB range, 50-500ms

---

### Q: What's a "bad" lag?

**A:**
- **< 1 MB / < 100ms:** ✅ Excellent
- **1-10 MB / 100ms-1s:** ⚠️ Acceptable, monitor
- **> 10 MB / > 1s:** 🚨 Investigate immediately

---

### Q: Can I have multiple standbys? (Like MySQL multi-slave)

**A:** Yes! PostgreSQL supports:
- Multiple streaming standbys (you'll test this in Scenario 07)
- Cascading replication (standby replicates from another standby)
- Mix of sync and async standbys

---

## ✅ You're Ready for Scenario 02 When You Can Answer:

1. ✅ What does LSN `0/3020A50` mean?
   - Timeline 0, offset 3020A50 in hex

2. ✅ If `write_lag` is high but `flush_lag` is low, what's the problem?
   - Network latency between primary and standby

3. ✅ What protects WAL from being deleted if standby goes down?
   - Replication slot

4. ✅ Why was your lag 0 bytes even with 100K inserts?
   - Docker localhost = no network latency, standby kept up in real-time

5. ✅ What's the PostgreSQL equivalent of `SHOW SLAVE STATUS`?
   - `SELECT * FROM pg_stat_replication;`

---

## 🚀 Next: Scenario 02 - Read Load Distribution

Now that you understand lag measurement, you'll learn:
- How to route read queries to standby
- Performance benefits of read scaling
- Connection pooling strategies
- When to read from primary vs standby

**Ready?** Let's move to Scenario 02! 🎯
