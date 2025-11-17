# Scenario 01: Understanding Replication Lag

**Difficulty:** Beginner  
**Duration:** 15-20 minutes  
**Prerequisites:** Basic setup completed and replication active

## 🎯 Learning Objectives

By completing this scenario, you will:
- Understand what replication lag is and how to measure it
- Learn about LSN (Log Sequence Numbers)
- See how bulk operations affect replication
- Use monitoring queries to track replication health

## 📚 Background

**Replication lag** is the delay between when a transaction commits on the primary and when it's applied on the standby. It can be measured in:
- **Bytes:** How much WAL data is behind
- **Time:** How many seconds behind
- **LSN difference:** Log Sequence Number positions

In production, monitoring lag is critical for:
- Ensuring data freshness for read queries
- Detecting replication issues early
- Capacity planning

## 🔍 What You'll Do

1. Measure current replication lag (should be ~0)
2. Insert bulk data on primary
3. Monitor lag in real-time
4. Understand LSN positions
5. Verify data consistency after bulk load

---

## Step 1: Check Initial Replication Status

First, let's see the current state with zero lag:

```bash
# Run the monitor script
bash scripts/monitor.sh
```

**Expected Output:**
- `state: streaming`
- `lag_bytes: 0`
- `replay_lag: < 1ms`

**Questions to Consider:**
- What does `sent_lsn` vs `replay_lsn` mean?
- Why is async mode showing near-zero lag?

---

## Step 2: Understand LSN Positions

LSN (Log Sequence Number) is PostgreSQL's way of tracking position in the WAL.

```bash
# Check current LSN on primary
docker exec -it postgres-primary psql -U postgres -c "SELECT pg_current_wal_lsn();"
```

**Expected Output:**
```
 pg_current_wal_lsn 
--------------------
 0/3000148
```

**What This Means:**
- Format: `timeline/byte_offset`
- `0/` = Timeline 1 (increments after failover)
- `3000148` = Byte position in WAL

```bash
# Check what standby has received
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

**Understanding the output:**
- `pg_last_wal_receive_lsn()`: What standby has downloaded
- `pg_last_wal_replay_lsn()`: What standby has applied
- These should be very close or identical

---

## Step 3: Create Bulk Data Insert Function

Let's create a function to generate load:

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Create a function to insert bulk data
CREATE OR REPLACE FUNCTION insert_bulk_users(num_rows INTEGER)
RETURNS TABLE(inserted_count INTEGER, start_time TIMESTAMP, end_time TIMESTAMP) AS $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    inserted INTEGER;
BEGIN
    start_ts := clock_timestamp();
    
    FOR i IN 1..num_rows LOOP
        INSERT INTO users (username, email)
        VALUES ('bulk_user_' || i, 'bulk_user_' || i || '@test.com');
    END LOOP;
    
    end_ts := clock_timestamp();
    inserted := num_rows;
    
    RETURN QUERY SELECT inserted, start_ts, end_ts;
END;
$$ LANGUAGE plpgsql;

\echo 'Bulk insert function created successfully!'
EOF
```

---

## Step 4: Insert Moderate Load (1,000 rows)

Now let's insert 1,000 rows and monitor lag:

**Terminal 1 - Start Monitoring (run this first):**
```bash
# Watch replication status in real-time (updates every 2 seconds)
watch -n 2 "docker exec -it postgres-primary psql -U postgres -t -c \"SELECT application_name, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes, replay_lag FROM pg_stat_replication;\""
```

**Terminal 2 - Insert Data:**
```bash
docker exec -it postgres-primary psql -U postgres -c "SELECT * FROM insert_bulk_users(1000);"
```

**Observe:**
- Did you see lag increase?
- How quickly did it return to zero?
- Check the timing

```bash
# Stop the watch command with Ctrl+C
```

**Expected Results:**
- Brief lag spike (few KB to few MB)
- Quick recovery (< 1 second)
- Lag returns to ~0

---

## Step 5: Insert Heavy Load (10,000 rows)

Let's increase the load:

**Terminal 1 - Monitor:**
```bash
watch -n 1 "docker exec -it postgres-primary psql -U postgres -t -c \"SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes, EXTRACT(EPOCH FROM replay_lag) AS lag_seconds FROM pg_stat_replication;\""
```

**Terminal 2 - Heavy Insert:**
```bash
docker exec -it postgres-primary psql -U postgres -c "SELECT * FROM insert_bulk_users(10000);"
```

**Observe:**
- Larger lag spike
- Longer recovery time
- LSN difference

**Record Your Observations:**
- Maximum lag in bytes: _______
- Maximum lag in seconds: _______
- Recovery time: _______

---

## Step 6: Calculate Lag in Human-Readable Format

PostgreSQL has helpful functions to make lag readable:

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    application_name,
    client_addr,
    state,
    -- Current vs replay LSN
    pg_current_wal_lsn() AS current_lsn,
    replay_lsn,
    -- Lag in bytes (human readable)
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_size,
    -- Lag in time
    EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds,
    replay_lag
FROM pg_stat_replication;
EOF
```

**Understanding the columns:**
- `lag_size`: e.g., "16 kB", "1024 MB" (easier to read)
- `lag_seconds`: Real-time lag
- `replay_lag`: How long last transaction took to replay

---

## Step 7: Verify Data Consistency

After bulk inserts, verify both servers have same data:

```bash
# Count on primary
docker exec -it postgres-primary psql -U postgres -c "SELECT COUNT(*) FROM users WHERE username LIKE 'bulk_user_%';"

# Count on standby
docker exec -it postgres-standby psql -U postgres -c "SELECT COUNT(*) FROM users WHERE username LIKE 'bulk_user_%';"
```

**Expected Result:**
Both should return **11,000** (1,000 + 10,000)

```bash
# Check specific rows exist
docker exec -it postgres-standby psql -U postgres -c "SELECT * FROM users WHERE username IN ('bulk_user_1', 'bulk_user_5000', 'bulk_user_10000');"
```

---

## Step 8: Monitor WAL Generation

See how much WAL was generated:

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_pending
FROM pg_replication_slots;
EOF
```

**Understanding:**
- `wal_retained`: How much WAL primary is keeping
- `wal_pending`: How much WAL standby hasn't confirmed yet

---

## Step 9: Create a Custom Lag Monitor

Let's create a simple monitoring query you can reuse:

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Create a monitoring view
CREATE OR REPLACE VIEW replication_health AS
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    -- Lag metrics
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) AS send_lag,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag,
    pg_size_pretty(pg_wal_lsn_diff(write_lsn, flush_lsn)) AS flush_lag,
    pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn)) AS replay_lag_bytes,
    -- Time lags
    EXTRACT(EPOCH FROM write_lag) AS write_lag_seconds,
    EXTRACT(EPOCH FROM flush_lag) AS flush_lag_seconds,
    EXTRACT(EPOCH FROM replay_lag) AS replay_lag_seconds,
    -- Status
    CASE 
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 10485760 THEN '⚠️  WARNING: Lag > 10MB'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 1048576 THEN '⚠️  Lag > 1MB'
        ELSE '✅ Healthy'
    END AS health_status
FROM pg_stat_replication;

\echo 'Monitoring view created! Use: SELECT * FROM replication_health;'
EOF
```

**Use your new view:**
```bash
docker exec -it postgres-primary psql -U postgres -c "SELECT * FROM replication_health;"
```

---

## Step 10: Generate Continuous Load (Optional)

Want to see sustained lag? Try continuous inserts:

```bash
# Run this in background (Terminal 1)
docker exec -it postgres-primary psql -U postgres << 'EOF'
DO $$
DECLARE
    i INTEGER := 0;
BEGIN
    LOOP
        INSERT INTO orders (user_id, product, amount)
        VALUES (
            (random() * 10 + 1)::INTEGER,
            'Product_' || i,
            (random() * 1000)::NUMERIC(10,2)
        );
        i := i + 1;
        
        IF i % 100 = 0 THEN
            RAISE NOTICE 'Inserted % rows', i;
            PERFORM pg_sleep(0.1);  -- Small pause every 100 rows
        END IF;
        
        EXIT WHEN i >= 5000;
    END LOOP;
END $$;
EOF

# Monitor in Terminal 2
watch -n 1 "docker exec -it postgres-primary psql -U postgres -c 'SELECT * FROM replication_health;'"
```

---

## 🎓 Knowledge Check

Answer these questions based on your observations:

1. **What is the typical replication lag in your setup under normal load?**
   - [ ] < 1 millisecond
   - [ ] 1-10 milliseconds
   - [ ] 10-100 milliseconds
   - [ ] > 100 milliseconds

2. **What happened to lag when you inserted 10,000 rows?**
   - [ ] No change
   - [ ] Brief spike, then recovered
   - [ ] Permanent increase
   - [ ] Standby disconnected

3. **Which LSN should always be ahead?**
   - [ ] replay_lsn (standby)
   - [ ] sent_lsn (primary)
   - [ ] They should be equal

4. **What does "lag_bytes: 0" mean?**
   - [ ] Replication is broken
   - [ ] Standby is perfectly synchronized
   - [ ] No data has been replicated
   - [ ] Primary is down

---

## 🧪 Experiments to Try

### Experiment 1: Large Single Transaction
```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
BEGIN;
SELECT insert_bulk_users(50000);
-- Monitor lag here - it won't change yet!
COMMIT;
-- Now lag will spike
EOF
```

**Question:** Why didn't lag increase until COMMIT?

### Experiment 2: Many Small Transactions
```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
DO $$
BEGIN
    FOR i IN 1..1000 LOOP
        INSERT INTO users (username, email) 
        VALUES ('small_txn_' || i, 'test' || i || '@test.com');
        COMMIT;  -- Commit each one
    END LOOP;
END $$;
EOF
```

**Question:** How does this compare to bulk insert?

### Experiment 3: Update Heavy Operation
```bash
docker exec -it postgres-primary psql -U postgres -c "UPDATE users SET email = LOWER(email) WHERE username LIKE 'bulk_user_%';"
```

**Question:** Does UPDATE generate more or less WAL than INSERT?

---

## 📊 Results Summary

Fill in your observations:

| Metric | Value |
|--------|-------|
| Initial lag (bytes) | |
| Lag after 1K inserts | |
| Lag after 10K inserts | |
| Peak lag observed | |
| Recovery time | |
| LSN difference at peak | |

---

## 🔧 Cleanup

Remove bulk test data (optional):

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Delete bulk users
DELETE FROM users WHERE username LIKE 'bulk_user_%';
DELETE FROM users WHERE username LIKE 'small_txn_%';

-- Drop the function
DROP FUNCTION IF EXISTS insert_bulk_users(INTEGER);

-- Vacuum to reclaim space
VACUUM FULL users;

\echo 'Cleanup completed!'
EOF
```

---

## 🎯 Key Takeaways

✅ **Replication lag is normal** under heavy write load  
✅ **LSN positions** track WAL progress across servers  
✅ **Lag measurement** uses byte difference and time  
✅ **Async replication** provides excellent performance with minimal lag  
✅ **Monitoring views** help track replication health  

**Remember:**
- Lag < 1MB is generally healthy
- Brief spikes during bulk operations are normal
- Sustained lag indicates a problem (slow standby, network issues)

---

## 📝 What You Learned

- [x] How to measure replication lag
- [x] Understanding LSN positions
- [x] Monitoring WAL generation
- [x] Creating custom monitoring queries
- [x] Interpreting lag metrics
- [x] Data consistency verification

---

## ➡️ Next Scenario

**[Scenario 02: Read Load Distribution](./02-read-load-distribution.md)**

Learn how to distribute read queries across primary and standby to improve application performance.

```bash
cat scenarios/02-read-load-distribution.md
```
