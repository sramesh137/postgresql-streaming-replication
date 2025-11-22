# PostgreSQL Streaming Replication - Interview Practical Demos

**Purpose:** Ready-to-execute demonstrations for technical interviews  
**Audience:** Backend/Database Engineers interviewing for mid-senior roles  
**Duration:** 10-20 minutes per demo  
**Environment:** Docker-based PostgreSQL cluster

---

## 🎯 Overview

These demos simulate **real interview scenarios** where you're asked to:
- "Show me how you'd handle [specific situation]"
- "Walk me through [technical process]"
- "Demonstrate your understanding of [concept]"
- "Troubleshoot this problem on the spot"

Each demo is **interview-ready** with:
- ✅ Clear objective
- ✅ Step-by-step execution
- ✅ Expected results
- ✅ Talking points while demonstrating
- ✅ Common follow-up questions

---

## 📚 Table of Contents

1. [Demo 1: Network Failure Recovery](#demo-1-network-failure-recovery) ⏱️ 10 min
2. [Demo 2: High-Volume Replication Performance](#demo-2-high-volume-replication-performance) ⏱️ 15 min
3. [Demo 3: Complete Disaster Recovery](#demo-3-complete-disaster-recovery) ⏱️ 20 min
4. [Demo 4: Replication Lag Troubleshooting](#demo-4-replication-lag-troubleshooting) ⏱️ 10 min
5. [Demo 5: Split-Brain Prevention](#demo-5-split-brain-prevention) ⏱️ 15 min
6. [Demo 6: Zero-Downtime Failover](#demo-6-zero-downtime-failover) ⏱️ 20 min

---

## Demo 1: Network Failure Recovery

### 🎯 Interview Scenario
**Interviewer asks:** *"Show me how PostgreSQL handles a network outage between primary and standby. What happens to WAL files? How does catch-up work?"*

### 📋 Demonstration Steps

#### Step 1: Show Current Healthy State
```bash
# Terminal split: Primary (left) | Standby (right)

# PRIMARY: Show replication status
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    state,
    sync_state,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
"
```

**Talking Point:**
> "Here we see healthy replication. Standby is streaming with 0 bytes lag. The `sent_lsn` and `replay_lsn` are identical, meaning no data is waiting."

#### Step 2: Simulate Network Failure
```bash
# Pause the standby container (simulates network partition)
docker pause postgres-standby

# Verify it's unreachable
docker exec postgres-primary psql -U postgres -c "
SELECT application_name, state FROM pg_stat_replication;
"
```

**Talking Point:**
> "I'm simulating a network partition by pausing the standby container. In production, this could be a network switch failure, firewall issue, or standby server crash."

#### Step 3: Generate Transactions While Standby is Down
```bash
# PRIMARY: Create test load
docker exec postgres-primary psql -U postgres -c "
CREATE TABLE IF NOT EXISTS network_test (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP DEFAULT now()
);

-- Insert 100,000 rows while standby is offline
INSERT INTO network_test (data)
SELECT 'Data row ' || generate_series(1, 100000);

-- Check how much WAL was generated
SELECT pg_current_wal_lsn();
"
```

**Talking Point:**
> "While the standby is offline, transactions continue on the primary. WAL files accumulate because the replication slot prevents PostgreSQL from removing them. Let me show you the WAL disk usage..."

#### Step 4: Monitor WAL Accumulation
```bash
# PRIMARY: Check WAL retention
docker exec postgres-primary psql -U postgres -c "
SELECT 
    slot_name,
    active,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS retained_wal
FROM pg_replication_slots;
"
```

**Expected Result:**
```
   slot_name    | active | retained_wal 
----------------+--------+--------------
 standby_slot   | f      | 17 MB
```

**Talking Point:**
> "The replication slot has retained 17 MB of WAL files. Without slots, PostgreSQL might have deleted these, forcing a full rebuild. This is why slots are critical for production."

#### Step 5: Resume Standby (Network Restored)
```bash
# Unpause standby
docker unpause postgres-standby

# Watch it catch up in real-time
watch -n 1 'docker exec postgres-primary psql -U postgres -t -c "
SELECT 
    application_name,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;
"'
```

**Talking Point:**
> "Watch the lag decrease. PostgreSQL streams the accumulated WAL at network speed. On a 1 Gbps network, 17 MB takes less than 1 second. The standby automatically catches up without manual intervention."

#### Step 6: Verify Data Consistency
```bash
# PRIMARY: Count rows
docker exec postgres-primary psql -U postgres -c "
SELECT count(*) FROM network_test;
"

# STANDBY: Verify same count (after lag = 0)
docker exec postgres-standby psql -U postgres -c "
SELECT count(*) FROM network_test;
"
```

**Expected Result:** Both show `100000` rows

**Talking Point:**
> "All 100,000 rows inserted during the outage are now on the standby. Zero data loss. This is the power of replication slots combined with streaming replication."

### 🎤 Interview Follow-up Questions

**Q: "What if the network outage lasted days, not minutes?"**

**A:** 
> "Three concerns: 
> 1. **Disk space**: WAL files accumulate. Monitor with `pg_replication_slots` and alert if `retained_wal > threshold`
> 2. **Catch-up time**: Calculate `retained_WAL_bytes / network_bandwidth`. For 100 GB over 1 Gbps = ~15 minutes
> 3. **Standby staleness**: If catch-up time exceeds business requirements, consider rebuilding with `pg_basebackup` instead
>
> In production, I'd set alerts for:
> - Replication slot inactive > 5 minutes
> - WAL retention > 50 GB
> - Standby lag > 1 hour"

**Q: "What if you didn't have replication slots?"**

**A:**
> "Without slots, you'd rely on `wal_keep_size` (e.g., 1GB). If the outage generated more than 1GB of WAL, the standby couldn't catch up and would need a full rebuild using `pg_basebackup`. This could take hours for a large database.
>
> This happened to me once in a MySQL setup (similar concept with binlog retention). We lost 3 hours rebuilding a 500 GB replica because we didn't set binlog retention high enough. After that, I always use replication slots in PostgreSQL."

---

## Demo 2: High-Volume Replication Performance

### 🎯 Interview Scenario
**Interviewer asks:** *"Show me how replication performs under heavy write load. How do you measure lag? When does async replication become a problem?"*

### 📋 Demonstration Steps

#### Step 1: Set Up Monitoring Dashboard
```bash
# Create monitoring query (save as /tmp/monitor_replication.sql)
cat > /tmp/monitor_replication.sql << 'EOF'
\timing on
SELECT 
    now() AS check_time,
    application_name,
    state,
    sync_state,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
    replay_lag,
    round(
        pg_wal_lsn_diff(sent_lsn, replay_lsn) / 1024.0 / 1024.0,
        2
    ) AS lag_mb
FROM pg_stat_replication;
EOF

# Start monitoring in separate terminal
watch -n 1 'docker exec postgres-primary psql -U postgres -f /tmp/monitor_replication.sql 2>&1 | tail -20'
```

**Talking Point:**
> "I've set up real-time monitoring of replication metrics. We'll watch lag grow under load and see how fast it recovers."

#### Step 2: Generate High-Volume Writes
```bash
# PRIMARY: Create test workload
docker exec postgres-primary psql -U postgres << 'EOF'
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    customer_id INT,
    product_code VARCHAR(50),
    amount NUMERIC(10,2),
    order_date TIMESTAMP DEFAULT now()
);

-- Create index for realistic workload
CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_date ON orders(order_date);

-- Insert 1 million rows as fast as possible
\timing on
INSERT INTO orders (customer_id, product_code, amount)
SELECT 
    (random() * 10000)::int,
    'PROD-' || (random() * 1000)::int,
    (random() * 1000 + 10)::numeric(10,2)
FROM generate_series(1, 1000000);

-- Check WAL generated
SELECT pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')
);
EOF
```

**Expected Result:**
```
INSERT 0 1000000
Time: 8234.567 ms (8.2 seconds)

 pg_size_pretty 
----------------
 234 MB
```

**Talking Point:**
> "1 million rows inserted in 8 seconds, generating 234 MB of WAL. Now let's see how the standby handles this burst. Watch the monitoring terminal..."

#### Step 3: Observe Lag Behavior
**In monitoring terminal, you should see:**

```
 check_time | application_name | state      | lag_bytes | replay_lag | lag_mb
------------+------------------+------------+-----------+------------+--------
 14:23:01   | standby          | streaming  | 45678234  | 00:00:02   | 43.56
 14:23:02   | standby          | streaming  | 23456123  | 00:00:01   | 22.37
 14:23:03   | standby          | streaming  | 8234567   | 00:00:00   | 7.85
 14:23:04   | standby          | streaming  | 0         | NULL       | 0.00
```

**Talking Point:**
> "Peak lag was 43 MB (about 2 seconds). It recovered to zero in 3 seconds. This is acceptable for most applications. If lag stayed high, we'd investigate:
> - Network bottleneck (1 Gbps should handle 125 MB/s)
> - Standby disk I/O (check `iostat`)
> - Standby CPU (replay is single-threaded)
> - Long-running queries on standby blocking replay"

#### Step 4: Calculate Throughput Metrics
```bash
# PRIMARY: Calculate write throughput
docker exec postgres-primary psql -U postgres -c "
WITH metrics AS (
    SELECT 
        1000000 AS rows_inserted,
        8.2 AS duration_seconds,
        234 AS wal_mb_generated
)
SELECT 
    rows_inserted / duration_seconds AS rows_per_sec,
    wal_mb_generated / duration_seconds AS wal_mb_per_sec,
    rows_inserted / 1000000.0 AS million_rows
FROM metrics;
"
```

**Expected Result:**
```
 rows_per_sec | wal_mb_per_sec | million_rows 
--------------+----------------+--------------
 121951.22    | 28.54          | 1.00
```

**Talking Point:**
> "We achieved ~122K inserts/second, generating 28.5 MB/s of WAL. On a 1 Gbps network (125 MB/s), this is only 23% utilization, so replication has plenty of headroom."

#### Step 5: Test Sustained Load
```bash
# Run continuous writes for 60 seconds
docker exec postgres-primary bash -c '
for i in {1..60}; do
    psql -U postgres -c "
        INSERT INTO orders (customer_id, product_code, amount)
        SELECT 
            (random() * 10000)::int,
            '\''PROD-'\'' || (random() * 1000)::int,
            (random() * 1000 + 10)::numeric(10,2)
        FROM generate_series(1, 10000);
    " > /dev/null
    echo "Batch $i completed"
    sleep 1
done
'

# Check max lag during sustained load
docker exec postgres-primary psql -U postgres -c "
SELECT 
    max(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS max_lag_bytes,
    max(replay_lag) AS max_replay_lag
FROM pg_stat_replication;
"
```

**Talking Point:**
> "Under sustained load (10K inserts/second for 60 seconds), lag should remain low and stable. If it grows continuously, that indicates replication can't keep up with write rate—a sign to investigate bottlenecks or consider synchronous replication for critical data."

### 🎤 Interview Follow-up Questions

**Q: "At what point would you switch from async to sync replication?"**

**A:**
> "It depends on business requirements for RPO (Recovery Point Objective):
>
> **Use ASYNC when:**
> - RPO of 1-10 seconds acceptable (most apps)
> - Write latency is critical (< 1ms)
> - Standby can be in different region/datacenter
> - Example: Analytics, reporting, non-critical apps
>
> **Use SYNC when:**
> - RPO must be zero (financial, healthcare)
> - Can tolerate 2-5ms additional write latency
> - Standby is in same datacenter (low network latency)
> - Example: Banking transactions, medical records
>
> Trade-off: Sync provides zero data loss but reduces write throughput by 15-30%."

**Q: "How would you troubleshoot if lag is consistently high?"**

**A:**
> "Systematic approach:
>
> **1. Check network (60% of issues):**
> ```sql
> -- Check sent vs replay
> SELECT sent_lsn, replay_lsn FROM pg_stat_replication;
> ```
> If `sent_lsn` >> `replay_lsn`: Network is fine, standby is slow
> If `sent_lsn` ≈ `replay_lsn`: Network bottleneck
>
> **2. Check standby resources:**
> ```bash
> # Disk I/O
> iostat -x 1
> # CPU (replay is single-threaded)
> top -H -p $(pgrep -f 'startup process')
> ```
>
> **3. Check for blocking queries:**
> ```sql
> -- On standby
> SELECT pid, wait_event_type, wait_event, query
> FROM pg_stat_activity
> WHERE wait_event_type = 'Lock';
> ```
>
> **4. Check for massive transactions:**
> Large transactions (e.g., `UPDATE 10M rows`) can cause lag spikes
>
> Real example: I once found a nightly batch job was holding a lock on standby, blocking replay. Solution: Set `hot_standby_feedback = on` and reduce `max_standby_streaming_delay`."

---

## Demo 3: Complete Disaster Recovery

### 🎯 Interview Scenario
**Interviewer asks:** *"Walk me through a production failover. Show me the actual commands and explain your decision-making process at each step."*

### 📋 Demonstration Steps

#### Step 1: Document Pre-Disaster State
```bash
# PRIMARY: Capture baseline
docker exec postgres-primary psql -U postgres << 'EOF'
-- Create critical production data
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    order_number VARCHAR(50) UNIQUE,
    customer_email VARCHAR(255),
    total_amount NUMERIC(10,2),
    created_at TIMESTAMP DEFAULT now()
);

INSERT INTO orders (order_number, customer_email, total_amount)
VALUES ('ORD-2025-001', 'customer@example.com', 599.99);

-- Capture current state
\echo '=== PRE-DISASTER STATE ==='
SELECT 
    pg_current_wal_lsn() AS primary_lsn,
    now() AS timestamp;

SELECT * FROM orders;
EOF
```

**Expected Result:**
```
=== PRE-DISASTER STATE ===
 primary_lsn  | timestamp 
--------------+-----------
 0/5A3B2C1D   | 2025-11-21 14:30:00
 
 id | order_number  | customer_email        | total_amount | created_at
----+---------------+-----------------------+--------------+------------
  1 | ORD-2025-001  | customer@example.com  | 599.99       | 2025-11-21 14:30:00
```

**Talking Point:**
> "In production, this would be a real customer order worth $599.99. Our goal: Ensure this order survives the disaster with zero data loss (RPO = 0)."

#### Step 2: Insert Final Critical Transaction
```bash
# PRIMARY: Last transaction before disaster
docker exec postgres-primary psql -U postgres -c "
INSERT INTO orders (order_number, customer_email, total_amount)
VALUES ('ORD-2025-002', 'vip@company.com', 1299.99)
RETURNING id, order_number, total_amount, created_at;
"
```

**Expected Result:**
```
 id | order_number | total_amount | created_at
----+--------------+--------------+------------
  2 | ORD-2025-002 | 1299.99      | 2025-11-21 14:30:15
```

**Talking Point:**
> "This is our last transaction before disaster—a VIP customer's $1,299.99 order. We must ensure this survives the failover."

#### Step 3: SIMULATE DISASTER - Primary Fails
```bash
# Record exact time of disaster
echo "DISASTER OCCURRED AT: $(date)"

# KILL PRIMARY (catastrophic failure)
docker stop postgres-primary

# Verify it's truly down
docker exec postgres-primary psql -U postgres -c "SELECT 1;" 2>&1 | head -5
```

**Expected Error:**
```
Error: Cannot connect to container
```

**Talking Point:**
> "Primary is down. In production, this could be:
> - Hardware failure
> - Data center outage
> - Accidental `rm -rf /var/lib/postgresql`
> - Network partition
>
> Detection time: Monitoring should alert within 30 seconds. Let's check if standby has our critical data..."

#### Step 4: Verify Standby Has Critical Data
```bash
# STANDBY: Check replication status
docker exec postgres-standby psql -U postgres << 'EOF'
-- Check if we're still in recovery (read-only)
SELECT pg_is_in_recovery();

-- Verify both orders made it to standby
SELECT 
    id,
    order_number,
    total_amount,
    pg_walfile_name(pg_last_wal_replay_lsn()) AS last_wal_file
FROM orders
ORDER BY id;
EOF
```

**Expected Result:**
```
 pg_is_in_recovery 
-------------------
 t
(True = still standby)

 id | order_number | total_amount | last_wal_file
----+--------------+--------------+---------------
  1 | ORD-2025-001 | 599.99       | 000000010000000000000005
  2 | ORD-2025-002 | 1299.99      | 000000010000000000000005
```

**Talking Point:**
> "✅ **ZERO DATA LOSS!** Both orders are on the standby, including the VIP order inserted seconds before the crash. RPO = 0 seconds. This is why replication slots are critical—they ensured WAL was retained."

#### Step 5: Decision Point - Promote Standby
**Talking Point (before promoting):**
> "**Decision time:** I need to confirm:
> 1. ✅ Primary is definitely dead (not recovering)
> 2. ✅ Standby has latest data (both orders present)
> 3. ✅ No split-brain risk (primary won't come back)
> 4. ⏰ Business downtime cost: $10K/minute
>
> **Decision: PROMOTE STANDBY TO PRIMARY**"

```bash
# Record promotion time
PROMOTE_START=$(date +%s)
echo "PROMOTION STARTED AT: $(date)"

# PROMOTE STANDBY
docker exec postgres-standby pg_ctl promote -D /var/lib/postgresql/data

# Wait for promotion (usually 1-2 seconds)
sleep 3

# Verify promotion completed
docker exec postgres-standby psql -U postgres -c "
SELECT 
    pg_is_in_recovery() AS still_in_recovery,
    pg_current_wal_lsn() AS new_primary_lsn;
"

PROMOTE_END=$(date +%s)
PROMOTE_DURATION=$((PROMOTE_END - PROMOTE_START))
echo "PROMOTION COMPLETED IN: ${PROMOTE_DURATION} seconds"
```

**Expected Result:**
```
PROMOTION STARTED AT: 2025-11-21 14:31:00
PROMOTION COMPLETED IN: 2 seconds

 still_in_recovery | new_primary_lsn 
-------------------+-----------------
 f                 | 0/5A3B2C20
(False = now primary!)
```

**Talking Point:**
> "Promotion took 2 seconds. The standby is now the new primary on a **new timeline** (timeline increments to prevent split-brain). Old primary can never rejoin without rebuild."

#### Step 6: Verify Write Capability (Now Accepting Production Traffic)
```bash
# NEW PRIMARY: Test writes work
docker exec postgres-standby psql -U postgres -c "
-- Insert new order on new primary
INSERT INTO orders (order_number, customer_email, total_amount)
VALUES ('ORD-2025-003', 'new@customer.com', 399.99)
RETURNING id, order_number, total_amount;
"
```

**Expected Result:**
```
 id | order_number | total_amount 
----+--------------+--------------
  3 | ORD-2025-003 | 399.99
```

**Talking Point:**
> "✅ **NEW PRIMARY IS OPERATIONAL!** Applications can now write to the new primary. This order was inserted after the disaster, proving write capability."

#### Step 7: Data Integrity Verification
```bash
# NEW PRIMARY: Verify all orders
docker exec postgres-standby psql -U postgres -c "
SELECT 
    count(*) AS total_orders,
    sum(total_amount) AS total_revenue,
    max(created_at) AS latest_order
FROM orders;

-- List all orders
SELECT * FROM orders ORDER BY id;
"
```

**Expected Result:**
```
 total_orders | total_revenue | latest_order
--------------+---------------+-------------
 3            | 2299.97       | 2025-11-21 14:31:30

 id | order_number | customer_email        | total_amount | created_at
----+--------------+-----------------------+--------------+------------
  1 | ORD-2025-001 | customer@example.com  | 599.99       | 2025-11-21 14:30:00
  2 | ORD-2025-002 | vip@company.com       | 1299.99      | 2025-11-21 14:30:15
  3 | ORD-2025-003 | new@customer.com      | 399.99       | 2025-11-21 14:31:30
```

**Talking Point:**
> "All three orders are intact:
> - Order 1: Before disaster ✅
> - Order 2: 15 seconds before disaster ✅  
> - Order 3: After failover ✅
> 
> **RPO (data loss): 0 rows / $0**  
> **RTO (downtime): ~2 minutes** (detection + decision + promotion + verification)"

#### Step 8: Calculate Recovery Metrics
```bash
# Generate DR Report
cat << EOF

╔═══════════════════════════════════════════════════════════╗
║             DISASTER RECOVERY REPORT                      ║
╠═══════════════════════════════════════════════════════════╣
║ Disaster Time:        2025-11-21 14:30:30                ║
║ Detection Time:       +30 seconds                         ║
║ Promotion Started:    2025-11-21 14:31:00                ║
║ Promotion Completed:  2025-11-21 14:31:02                ║
║ Verification Time:    +28 seconds                         ║
║                                                           ║
║ RTO (Recovery Time):  2 minutes 0 seconds                ║
║ RPO (Data Loss):      0 transactions / \$0                ║
║                                                           ║
║ Orders Before Disaster:  2                                ║
║ Orders After Failover:   3                                ║
║ Data Loss:               0                                ║
║                                                           ║
║ STATUS: ✅ RECOVERY SUCCESSFUL                            ║
╚═══════════════════════════════════════════════════════════╝

EOF
```

**Talking Point:**
> "This meets our SLA:
> - RTO target: < 5 minutes → Achieved: 2 minutes ✅
> - RPO target: 0 data loss → Achieved: 0 rows lost ✅
> - Business cost: 2 min × $10K/min = $20K downtime cost
>
> In production, we'd also:
> - Update DNS/load balancer to point to new primary
> - Update connection strings in application configs
> - Notify stakeholders
> - Start post-mortem investigation
> - Plan rebuild of old primary as new standby"

### 🎤 Interview Follow-up Questions

**Q: "What if the standby was also unavailable?"**

**A:**
> "This is a **complete disaster scenario**—both primary and standby down. Options:
>
> **Option 1: Restore from backup (Barman/pgBackRest)**
> - RTO: 2-6 hours (depends on DB size)
> - RPO: Last backup time (could lose hours of data)
> - Last resort when no standbys available
>
> **Option 2: Multi-standby architecture (recommended)**
> - 1 primary + 2 standbys in different availability zones
> - If standby-1 down, promote standby-2
> - Cost: 2x standby servers, but RTO/RPO much better
>
> **Option 3: Multi-region setup (mission-critical)**
> - Primary in us-east, standby in us-west, standby in eu-west
> - Survives entire region failure
> - Cost: Higher network latency, 3x servers
>
> My recommendation: **2 standbys minimum** for production. Cost is ~$500/month but prevents millions in data loss."

**Q: "How do you prevent the old primary from coming back online and causing split-brain?"**

**A:**
> "PostgreSQL has **timeline protection**:
>
> **Timeline concept:**
> - Primary starts on timeline 1
> - After promotion, new primary moves to timeline 2
> - Old primary (if it comes back) is still on timeline 1
>
> **If old primary comes back:**
> ```sql
> -- Old primary tries to rejoin (FAILS)
> ERROR: timeline 1 of the primary does not match recovery target timeline 2
> ```
>
> **Resolution:**
> Old primary cannot rejoin automatically. Must rebuild as new standby:
> ```bash
> # Option 1: pg_basebackup (clean rebuild)
> pg_basebackup -h new-primary -D /var/lib/postgresql/data
>
> # Option 2: pg_rewind (faster, reuses existing data)
> pg_rewind --target-pgdata=/var/lib/postgresql/data \\
>           --source-server='host=new-primary'
> ```
>
> This happened to me once—old primary came back after power restore. Timeline protection saved us from data corruption!"

---

## Demo 4: Replication Lag Troubleshooting

### 🎯 Interview Scenario
**Interviewer asks:** *"Our standby is lagging by 10 seconds. Walk me through how you'd diagnose and fix this."*

### 📋 Demonstration Steps

#### Step 1: Confirm the Problem
```bash
# PRIMARY: Check replication lag
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    state,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_size,
    replay_lag,
    write_lag,
    flush_lag,
    sync_state
FROM pg_stat_replication;
"
```

**Talking Point:**
> "First, I verify the problem and gather metrics:
> - `replay_lag`: 10 seconds (confirmed)
> - `lag_size`: 42 MB behind
> - `write_lag` vs `replay_lag`: Shows if network or replay is slow"

#### Step 2: Check What's Running on Primary
```bash
# PRIMARY: Check for long-running transactions
docker exec postgres-primary psql -U postgres -c "
SELECT 
    pid,
    usename,
    application_name,
    state,
    age(clock_timestamp(), query_start) AS query_age,
    wait_event_type,
    wait_event,
    substring(query, 1, 60) AS query_snippet
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY query_age DESC
LIMIT 10;
"
```

**Talking Point:**
> "Looking for massive batch operations or long transactions that generate tons of WAL. If I see something like `UPDATE 10M rows`, that explains the lag spike."

#### Step 3: Check Standby for Blocking Queries
```bash
# STANDBY: Check if queries are blocking replay
docker exec postgres-standby psql -U postgres -c "
SELECT 
    pid,
    usename,
    application_name,
    wait_event_type,
    wait_event,
    state,
    age(clock_timestamp(), query_start) AS query_age,
    substring(query, 1, 60) AS query_snippet
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY query_age DESC;
"
```

**Talking Point:**
> "If I see long-running SELECT queries on standby, they might be blocking replay. PostgreSQL waits up to `max_standby_streaming_delay` (default 30s) before canceling conflicting queries."

#### Step 4: Check Standby Resources
```bash
# Check standby CPU and I/O
docker exec postgres-standby bash -c "
echo '=== CPU Usage ==='
top -bn1 | grep 'Cpu' | head -1

echo ''
echo '=== Disk I/O (last 1 second) ==='
iostat -x 1 2 | grep -A20 'Device'

echo ''
echo '=== PostgreSQL processes ==='
ps aux | grep postgres | head -10
"
```

**Talking Point:**
> "Checking if standby is resource-constrained:
> - CPU: Replay is single-threaded, check startup process
> - Disk I/O: High %util or await means slow disk
> - Memory: Check if swapping"

#### Step 5: Check Network Between Primary and Standby
```bash
# Test network bandwidth
docker exec postgres-primary bash -c "
ping -c 5 postgres-standby 2>&1 | tail -2
"
```

**Talking Point:**
> "Network issues are rare in same-datacenter but common cross-region. Looking for:
> - High latency (> 50ms)
> - Packet loss
> - Bandwidth saturation"

#### Step 6: Analyze WAL Generation Rate
```bash
# PRIMARY: Calculate WAL generation rate
docker exec postgres-primary psql -U postgres -c "
WITH wal_metrics AS (
    SELECT 
        pg_current_wal_lsn() AS current_lsn,
        pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file
)
SELECT * FROM wal_metrics;

-- Check WAL size over last minute
SELECT 
    pg_size_pretty(
        pg_wal_lsn_diff(
            pg_current_wal_lsn(),
            '0/0'
        )
    ) AS total_wal_generated;
"
```

**Talking Point:**
> "If primary is generating WAL faster than standby can apply it, lag grows. Calculate:
> - WAL generation rate: MB/second
> - Network bandwidth: 1 Gbps = 125 MB/s
> - Disk write speed on standby: `dd` test
>
> If WAL rate > standby capacity, we have a problem."

#### Step 7: Implement Fixes

**Fix 1: Kill Blocking Queries on Standby**
```bash
# STANDBY: Cancel long-running queries blocking replay
docker exec postgres-standby psql -U postgres -c "
-- Find blocking queries
SELECT 
    pid,
    query_start,
    state,
    query
FROM pg_stat_activity
WHERE state = 'active'
  AND age(clock_timestamp(), query_start) > interval '1 minute';

-- Kill them (replace <PID> with actual PID)
-- SELECT pg_cancel_backend(<PID>);
"
```

**Fix 2: Reduce max_standby_streaming_delay**
```bash
# STANDBY: Be more aggressive canceling queries
docker exec postgres-standby psql -U postgres -c "
ALTER SYSTEM SET max_standby_streaming_delay = '5s';
SELECT pg_reload_conf();
"
```

**Talking Point:**
> "This tells PostgreSQL: Cancel any query that blocks replay for more than 5 seconds. Trade-off: Users may see 'query canceled due to conflict' errors."

**Fix 3: Enable hot_standby_feedback**
```bash
# STANDBY: Tell primary not to vacuum rows we're still reading
docker exec postgres-standby psql -U postgres -c "
ALTER SYSTEM SET hot_standby_feedback = on;
SELECT pg_reload_conf();
"
```

**Talking Point:**
> "This prevents primary from vacuuming rows that standby queries still need. Trade-off: Can cause bloat on primary if standby queries run for hours."

#### Step 8: Verify Fix
```bash
# PRIMARY: Check lag after fixes
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_size,
    replay_lag
FROM pg_stat_replication;
"
```

**Expected Result (after fixes):**
```
 application_name | lag_size | replay_lag 
------------------+----------+------------
 standby          | 0 bytes  | NULL
```

**Talking Point:**
> "Lag is now zero. Root cause was long-running analytical queries on standby blocking replay. Fix: Moved heavy queries to a second standby dedicated to analytics."

### 🎤 Interview Follow-up Questions

**Q: "What if the lag continues to grow despite fixes?"**

**A:**
> "This indicates standby can't keep up with write rate. Solutions:
>
> **Short-term (immediate):**
> 1. Reduce write load on primary (throttle batch jobs)
> 2. Scale up standby hardware (faster CPU, disk, network)
> 3. Remove heavy queries from standby
>
> **Long-term (architectural):**
> 1. Add second standby for read queries (dedicated reporting replica)
> 2. Switch to synchronous replication (if zero lag required)
> 3. Implement connection pooling (reduce overhead)
> 4. Use logical replication for selective tables only
> 5. Consider sharding if single server can't handle write volume
>
> Real example: We had a 500 GB e-commerce database with lag growing to 5 minutes during flash sales. Solution: Added NVMe SSD to standby (10x faster I/O), reduced lag to < 1 second."

---

## Demo 5: Split-Brain Prevention

### 🎯 Interview Scenario
**Interviewer asks:** *"Demonstrate how PostgreSQL prevents split-brain. What happens if both primary and standby think they're primary?"*

### 📋 Demonstration Steps

#### Step 1: Show Normal Timeline
```bash
# PRIMARY: Check timeline
docker exec postgres-primary psql -U postgres -c "
SELECT 
    pg_control_checkpoint()::text AS checkpoint_info;

SELECT timeline_id, redo_wal_file
FROM pg_control_checkpoint();
"
```

**Expected Result:**
```
 timeline_id | redo_wal_file
-------------+---------------
 1           | 000000010000000000000005
```

**Talking Point:**
> "We're on timeline 1. Timeline is like a version number for the database history. It increments after every promotion."

#### Step 2: Promote Standby (Create Split-Brain Scenario)
```bash
# PROMOTE STANDBY TO PRIMARY (simulating split-brain)
docker exec postgres-standby pg_ctl promote -D /var/lib/postgresql/data

# Wait for promotion
sleep 3

# CHECK NEW PRIMARY: Now on timeline 2
docker exec postgres-standby psql -U postgres -c "
SELECT pg_is_in_recovery();

SELECT timeline_id 
FROM pg_control_checkpoint();
"
```

**Expected Result:**
```
 pg_is_in_recovery 
-------------------
 f (False = now primary)

 timeline_id 
-------------
 2 (NEW TIMELINE!)
```

**Talking Point:**
> "Now we have two primaries:
> - Old primary: Timeline 1
> - New primary: Timeline 2
>
> This is split-brain. Both are accepting writes. Let's see what happens when they try to communicate..."

#### Step 3: Insert Conflicting Data
```bash
# OLD PRIMARY (Timeline 1): Insert order
docker exec postgres-primary psql -U postgres -c "
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    order_number VARCHAR(50),
    timeline INT
);

INSERT INTO orders (order_number, timeline)
VALUES ('ORD-TIMELINE-1', 1)
RETURNING *;
"

# NEW PRIMARY (Timeline 2): Insert different order
docker exec postgres-standby psql -U postgres -c "
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    order_number VARCHAR(50),
    timeline INT
);

INSERT INTO orders (order_number, timeline)
VALUES ('ORD-TIMELINE-2', 2)
RETURNING *;
"
```

**Expected Results:**
```
OLD PRIMARY:
 id | order_number    | timeline
----+-----------------+----------
  1 | ORD-TIMELINE-1  | 1

NEW PRIMARY:
 id | order_number    | timeline
----+-----------------+----------
  1 | ORD-TIMELINE-2  | 2
```

**Talking Point:**
> "Both have inserted order ID 1, but with different data. This is data divergence—a disaster waiting to happen!"

#### Step 4: Try to Reconnect (Timeline Protection Kicks In)
```bash
# Try to set up old primary as standby to new primary
docker exec postgres-primary psql -U postgres -c "
-- This simulates old primary trying to rejoin
SELECT pg_walfile_name(pg_current_wal_lsn()) AS old_primary_wal_file;
"

docker exec postgres-standby psql -U postgres -c "
SELECT pg_walfile_name(pg_current_wal_lsn()) AS new_primary_wal_file;
"
```

**Expected Results:**
```
OLD PRIMARY WAL: 000000010000000000000006 (timeline 1)
NEW PRIMARY WAL: 000000020000000000000006 (timeline 2)
                  ↑ Timeline in filename
```

**Talking Point:**
> "Notice the WAL filenames:
> - Old primary: 00000001... (timeline 1)
> - New primary: 00000002... (timeline 2)
>
> PostgreSQL embeds timeline in WAL filenames. If old primary tries to request WAL from new primary, it will reject with 'timeline mismatch' error."

#### Step 5: Demonstrate Rejection
```bash
# Simulate old primary trying to stream from new primary
# (This would fail in a real scenario)

docker exec postgres-primary psql -U postgres -c "
-- Show that we can't just switch replication target
-- Timeline protection prevents this
SELECT 
    'Timeline 1 cannot follow Timeline 2 without pg_rewind' AS protection_message;
"
```

**Talking Point:**
> "PostgreSQL prevents automatic reconnection across timelines. Old primary must be either:
> 1. **Discarded** (if data doesn't matter)
> 2. **Rebuilt** with `pg_basebackup` (clean slate)
> 3. **Rewound** with `pg_rewind` (if timelines diverged recently)
>
> This timeline protection is what saves PostgreSQL from split-brain data corruption!"

#### Step 6: Show Proper Resolution with pg_rewind
```bash
# Stop old primary
docker exec postgres-primary pg_ctl stop -D /var/lib/postgresql/data -m fast

# Run pg_rewind to resync with new primary timeline
docker exec postgres-primary bash -c "
pg_rewind \\
    --target-pgdata=/var/lib/postgresql/data \\
    --source-server='host=postgres-standby port=5432 user=postgres dbname=postgres' \\
    --progress
"
```

**Expected Result:**
```
pg_rewind: servers diverged at WAL location 0/5A3B2C1D on timeline 1
pg_rewind: rewinding from last common checkpoint at 0/5A3B2C00
...
pg_rewind: Done!
```

**Talking Point:**
> "`pg_rewind` identified where timelines diverged and resynced old primary with new primary's timeline 2. The old data (ORD-TIMELINE-1) is discarded. This is the safe way to handle split-brain."

### 🎤 Interview Follow-up Questions

**Q: "What if both primaries accepted writes for hours before you noticed?"**

**A:**
> "This is a **catastrophic split-brain**. Options:
>
> **Option 1: Accept data loss (fastest)**
> - Pick one primary as source of truth (usually the busier one)
> - Discard other primary's data
> - Rebuild with `pg_basebackup`
> - RPO: All data on discarded primary is lost
>
> **Option 2: Manual data merge (time-consuming)**
> - Export data from both primaries
> - Manually merge conflicting rows
> - Import into new primary
> - RPO: 0, but RTO could be days for large datasets
>
> **Option 3: Use application-level conflict resolution**
> - If using logical replication with multi-master (BDR, Postgres-XL)
> - Conflicts resolved automatically by rules (last-write-wins, etc.)
>
> **Prevention is key:**
> - Use quorum-based systems (Patroni + etcd)
> - Automatic fencing (STONITH in Pacemaker)
> - Network-based fencing (disable old primary's network)
>
> Real story: A company once had split-brain for 3 hours. They lost $500K in orders because they picked the wrong primary. Lesson: Always verify which primary has latest data before making decision!"

**Q: "How do quorum systems like Patroni prevent split-brain?"**

**A:**
> "Patroni uses **distributed consensus** with etcd or Consul:
>
> **How it works:**
> 1. All PostgreSQL nodes register in etcd
> 2. To be primary, node must hold a **lease** in etcd
> 3. Lease expires after 30 seconds if node crashes
> 4. Only ONE node can hold lease at a time (quorum guarantees this)
> 5. Standby can only promote if it wins lease election
>
> **Split-brain scenario:**
> ```
> Network partition:
> - Old primary loses etcd connection
> - Lease expires after 30 seconds
> - Old primary automatically demotes itself to standby
> - Standby wins lease election, becomes new primary
> - OLD PRIMARY CANNOT ACCEPT WRITES (no lease)
> ```
>
> **Key insight:** Quorum systems require **odd number** of etcd nodes (3 or 5) across availability zones. Even if 1 datacenter fails, quorum survives.
>
> Config:
> ```yaml
> # patroni.yml
> dcs:
>   ttl: 30
>   loop_wait: 10
>   retry_timeout: 10
>   maximum_lag_on_failover: 1048576  # 1 MB
> ```
>
> Cost: 3 etcd servers (~$150/month), but prevents split-brain 100%."

---

## Demo 6: Zero-Downtime Failover

### 🎯 Interview Scenario
**Interviewer asks:** *"Show me how you'd perform a planned maintenance failover with zero downtime and zero data loss."*

### 📋 Demonstration Steps

#### Step 1: Pre-Failover Checklist
```bash
# 1. Verify replication is healthy
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    state,
    sync_state,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
"
```

**Expected Result:**
```
 application_name | state      | sync_state | lag_bytes 
------------------+------------+------------+-----------
 standby          | streaming  | async      | 0
```

**Talking Point:**
> "Pre-flight checks:
> - ✅ Replication streaming
> - ✅ Zero lag
> - ✅ Standby is healthy
>
> This ensures standby has all data before we start."

#### Step 2: Enable Synchronous Replication (Zero Data Loss)
```bash
# PRIMARY: Switch to synchronous replication
docker exec postgres-primary psql -U postgres -c "
-- Enable sync replication
ALTER SYSTEM SET synchronous_standby_names = 'standby';
SELECT pg_reload_conf();

-- Wait 5 seconds for change to take effect
SELECT pg_sleep(5);

-- Verify sync is active
SELECT 
    application_name,
    sync_state,
    sync_priority
FROM pg_stat_replication;
"
```

**Expected Result:**
```
 application_name | sync_state | sync_priority 
------------------+------------+---------------
 standby          | sync       | 1
```

**Talking Point:**
> "Switched to synchronous replication. Now ALL writes wait for standby confirmation. This guarantees zero data loss but adds 2-5ms latency."

#### Step 3: Set Application to Read-Only Mode (Optional)
```bash
# If you have connection pooler like pgBouncer or HAProxy,
# you'd set it to read-only mode here
echo "In production: Update HAProxy to route all traffic to standby"
echo "Or: Set pgBouncer to 'session' mode and pause writes"
```

**Talking Point:**
> "For true zero-downtime:
> 1. Set application to read-only mode (prevents new writes)
> 2. Wait for active transactions to complete (< 5 seconds)
> 3. Promote standby
> 4. Update DNS/load balancer
> 5. Resume writes to new primary
>
> Total downtime: 0 seconds for reads, < 10 seconds for writes"

#### Step 4: Wait for In-Flight Transactions
```bash
# PRIMARY: Check for active transactions
docker exec postgres-primary psql -U postgres -c "
SELECT 
    count(*) AS active_transactions,
    max(age(clock_timestamp(), xact_start)) AS oldest_xact_age
FROM pg_stat_activity
WHERE state IN ('active', 'idle in transaction')
  AND pid != pg_backend_pid();
"
```

**Talking Point:**
> "Waiting for active transactions to complete. In production, I'd set a timeout (e.g., 30 seconds) and then force-cancel any stragglers."

#### Step 5: Promote Standby
```bash
# Record exact time
FAILOVER_START=$(date +%s)

# PROMOTE STANDBY
docker exec postgres-standby pg_ctl promote -D /var/lib/postgresql/data

# Wait for promotion
sleep 2

# Verify promotion
docker exec postgres-standby psql -U postgres -c "
SELECT 
    pg_is_in_recovery() AS still_in_recovery,
    pg_current_wal_lsn() AS new_primary_lsn;
"

FAILOVER_END=$(date +%s)
FAILOVER_DURATION=$((FAILOVER_END - FAILOVER_START))
```

**Expected Result:**
```
 still_in_recovery | new_primary_lsn 
-------------------+-----------------
 f                 | 0/5A3B2D00

Failover completed in: 2 seconds
```

**Talking Point:**
> "Promotion took 2 seconds. In production with HAProxy, you'd update backend configuration:
> ```bash
> # Update HAProxy to route to new primary
> echo 'set server postgres/primary state maint' | socat - /var/run/haproxy.sock
> echo 'set server postgres/standby state ready' | socat - /var/run/haproxy.sock
> ```"

#### Step 6: Verify Zero Data Loss
```bash
# NEW PRIMARY: Check last transaction before failover
docker exec postgres-standby psql -U postgres -c "
SELECT 
    xact_commit AS total_commits,
    xact_rollback AS total_rollbacks
FROM pg_stat_database
WHERE datname = 'postgres';
"
```

**Talking Point:**
> "All transactions committed before failover are on new primary. RPO = 0 seconds because we used synchronous replication."

#### Step 7: Demote Old Primary to Standby
```bash
# Stop old primary gracefully
docker exec postgres-primary pg_ctl stop -D /var/lib/postgresql/data -m fast

# Create standby.signal to make it a standby
docker exec postgres-primary bash -c "
touch /var/lib/postgresql/data/standby.signal

# Update primary_conninfo to point to new primary
echo \"primary_conninfo = 'host=postgres-standby port=5432 user=replicator password=replicator_password application_name=old_primary'\" >> /var/lib/postgresql/data/postgresql.auto.conf
"

# Use pg_rewind to sync with new timeline
docker exec postgres-primary pg_rewind \\
    --target-pgdata=/var/lib/postgresql/data \\
    --source-server='host=postgres-standby port=5432 user=postgres dbname=postgres'

# Start old primary as new standby
docker exec postgres-primary pg_ctl start -D /var/lib/postgresql/data
```

**Talking Point:**
> "`pg_rewind` syncs old primary with new primary's timeline. Now old primary becomes standby, ready for next failover."

#### Step 8: Verify New Replication Setup
```bash
# NEW PRIMARY: Check replication status
docker exec postgres-standby psql -U postgres -c "
SELECT 
    application_name,
    state,
    sync_state,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
"
```

**Expected Result:**
```
 application_name | state      | sync_state | lag_bytes 
------------------+------------+------------+-----------
 old_primary      | streaming  | async      | 0
```

**Talking Point:**
> "Roles have swapped:
> - Old primary → Now standby ✅
> - Old standby → Now primary ✅
> - Zero lag ✅
> - System fully operational ✅
>
> **Total downtime: 0 seconds for reads, 2 seconds for writes**"

#### Step 9: Switch Back to Async (Restore Performance)
```bash
# NEW PRIMARY: Disable sync replication (restore normal performance)
docker exec postgres-standby psql -U postgres -c "
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();

-- Verify back to async
SELECT application_name, sync_state
FROM pg_stat_replication;
"
```

**Expected Result:**
```
 application_name | sync_state 
------------------+------------
 old_primary      | async
```

**Talking Point:**
> "Switched back to async. Write performance restored to normal (no 2-5ms sync overhead). We only use sync during planned failovers to guarantee zero data loss."

### 🎤 Interview Follow-up Questions

**Q: "How would you automate this process?"**

**A:**
> "**Option 1: Shell script wrapper:**
> ```bash
> #!/bin/bash
> # planned-failover.sh
>
> # 1. Enable sync replication
> psql -c \"ALTER SYSTEM SET synchronous_standby_names = 'standby';\"
> psql -c \"SELECT pg_reload_conf();\"
> sleep 5
>
> # 2. Promote standby
> ssh standby 'pg_ctl promote'
> sleep 3
>
> # 3. Update HAProxy
> echo 'set server postgres/standby state ready' | socat - /var/run/haproxy.sock
>
> # 4. pg_rewind old primary
> ssh primary 'pg_ctl stop -m fast'
> ssh primary 'pg_rewind --target-pgdata=... --source-server=...'
> ssh primary 'pg_ctl start'
> ```
>
> **Option 2: Patroni (recommended):**
> ```bash
> # One command for planned switchover
> patronictl switchover --master primary --candidate standby
> ```
> Patroni handles all steps automatically:
> - Enables sync replication
> - Waits for lag = 0
> - Promotes standby
> - Demotes old primary
> - Updates HAProxy
> - All in < 10 seconds
>
> **Option 3: pg_auto_failover (Citus):**
> ```bash
> pg_autoctl perform switchover
> ```
>
> My preference: **Patroni** for production. Proven, well-documented, handles edge cases (network partition, split-brain, etc.)"

**Q: "What if writes are critical and you can't have even 2 seconds downtime?"**

**A:**
> "For **true zero-downtime**, use **logical replication** with multi-master:
>
> **Setup:**
> ```sql
> -- On old primary (publishing)
> CREATE PUBLICATION my_pub FOR ALL TABLES;
>
> -- On new primary (subscribing)
> CREATE SUBSCRIPTION my_sub 
>   CONNECTION 'host=old-primary' 
>   PUBLICATION my_pub;
> ```
>
> **Failover process:**
> 1. Set up bidirectional logical replication (both primaries)
> 2. Old primary replicates to new primary (running in parallel)
> 3. Wait for new primary to catch up (< 1 second)
> 4. Update application to write to BOTH primaries
> 5. After verification, stop writes to old primary
> 6. Drop replication
>
> **Result: 0 seconds downtime, writes continue throughout**
>
> Trade-offs:
> - More complex setup
> - Conflict resolution needed (last-write-wins, etc.)
> - Only works for specific schemas (needs primary keys)
>
> Used this for a fintech app—$10M/hour transaction volume, couldn't tolerate even 1 second downtime. Worked perfectly!"

---

## 🎯 Summary: Interview Success Metrics

### After Practicing These Demos:

✅ **Can demonstrate** network failure recovery with WAL slots  
✅ **Can measure** replication performance under load  
✅ **Can execute** complete disaster recovery with RTO/RPO  
✅ **Can troubleshoot** replication lag systematically  
✅ **Can explain** split-brain prevention with timelines  
✅ **Can perform** zero-downtime planned failovers  

### Interview Confidence Level: ⭐⭐⭐⭐⭐

**You're ready to:**
- Handle technical deep-dives
- Demonstrate real-world scenarios
- Answer "show me" questions
- Discuss production challenges
- Compare with MySQL confidently

### Key Talking Points to Memorize:

1. **Replication slots prevent data loss** (WAL retention)
2. **Timelines prevent split-brain** (automatic protection)
3. **Synchronous = 0 RPO, Async = better performance**
4. **RTO formula: Detection + Decision + Execution + Verification**
5. **pg_rewind syncs diverged timelines** (faster than pg_basebackup)

---

## 📚 Next Steps

1. **Practice each demo 2-3 times** until you can do it without notes
2. **Time yourself** - Be able to complete Demo 3 in < 20 minutes
3. **Modify scenarios** - Try with different data volumes
4. **Combine demos** - "Show me failover, then troubleshoot lag"
5. **Prepare STAR stories** - "Tell me about a time you handled an outage"

**Example STAR Story:**
> **Situation:** Production primary crashed during Black Friday (peak traffic)  
> **Task:** Restore service in < 5 minutes (SLA requirement)  
> **Action:** Executed disaster recovery procedure (Demo 3), promoted standby in 2 min  
> **Result:** RTO = 3 minutes, RPO = 0 rows, $0 data loss, $30K downtime cost saved

---

## 🎉 You're Interview-Ready!

**These demos combined with your interview guides give you:**
- ✅ Hands-on practical skills
- ✅ Theoretical deep knowledge
- ✅ Real-world production experience
- ✅ MySQL comparison expertise
- ✅ Confident technical communication

**Go ace that interview! 🚀**
