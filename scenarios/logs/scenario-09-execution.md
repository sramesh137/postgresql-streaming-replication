# Scenario 09: Advanced Replication Monitoring - Execution Log

**Date:** November 19, 2025  
**Objective:** Master production-grade monitoring and alerting for PostgreSQL replication  
**Duration:** 35 minutes  
**Interview Relevance:** ⭐⭐⭐⭐⭐ (Critical for production DBA roles)

---

## 🎯 Why This Scenario Matters for Interviews

### Critical Interview Topics Covered:
1. **Production monitoring patterns** - What metrics to track
2. **Alert threshold design** - When to alert and at what levels  
3. **Automated health checks** - Reducing manual monitoring burden
4. **Historical tracking** - Capacity planning and trend analysis
5. **Dashboard creation** - Single pane of glass for ops teams

### What Interviewers Look For:
- ✅ Do you know which metrics matter most?
- ✅ Can you set appropriate alert thresholds?
- ✅ Do you understand lag vs availability trade-offs?
- ✅ Can you troubleshoot using monitoring data?
- ✅ Do you automate rather than manual checking?

---

## Prerequisites Check

```bash
# Verify cluster is running
docker ps --filter name=postgres

# Expected: 3 containers (primary + 2 standbys)
```

**Result:**
```
postgres-primary   - Up 3 days (healthy)  - Port 5432
postgres-standby   - Up 2 days            - Port 5433
postgres-standby2  - Up 2 days            - Port 5434
```

---

## Step 1: Create Comprehensive Replication Dashboard

### 1.1: Drop existing view and create enhanced version

```bash
docker exec postgres-primary psql -U postgres -c "
DROP VIEW IF EXISTS replication_dashboard CASCADE;

CREATE VIEW replication_dashboard AS
SELECT 
    -- Identification
    application_name,
    client_addr,
    client_hostname,
    
    -- Connection status
    state,
    sync_state,
    backend_start,
    
    -- LSN positions
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    
    -- Lag metrics (size)
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag_size,
    pg_size_pretty(pg_wal_lsn_diff(write_lsn, flush_lsn)) AS flush_lag_size,
    pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn)) AS replay_lag_size,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS total_lag_size,
    
    -- Time lags
    write_lag,
    flush_lag,
    replay_lag,
    
    -- Connection uptime
    now() - backend_start AS uptime
    
FROM pg_stat_replication;
"
```

**What this does:**
- Creates unified view of all replication metrics
- **application_name**: Identifies which standby
- **client_addr**: IP address of standby server
- **state**: Should be 'streaming' (healthy)
- **sync_state**: 'sync' or 'async' replication mode
- **LSN values**: Write-Ahead Log sequence numbers showing progress
- **Lag sizes**: How far behind standby is (in bytes)
- **Time lags**: How long it takes for changes to propagate
- **uptime**: How long replication connection has been active

**Result:**
```
 application_name | client_addr |   state   | sync_state | backend_start | sent_lsn   | replay_lsn | total_lag_size | write_lag | flush_lag | replay_lag | uptime
------------------+-------------+-----------+------------+---------------+------------+------------+----------------+-----------+-----------+------------+----------
 walreceiver      | 172.19.0.3  | streaming | sync       | 18:25:24      | 0/44AA4848 | 0/44AA4848 | 0 bytes        | 0.35ms    | 1.30ms    | 2.82ms     | 06:45
 walreceiver2     | 172.19.0.4  | streaming | async      | 18:25:24      | 0/44AA4848 | 0/44AA4848 | 0 bytes        | 0.35ms    | 1.00ms    | 2.83ms     | 06:45
```

**Analysis:**
- ✅ Both standbys in 'streaming' state (healthy)
- ✅ walreceiver is 'sync' (synchronous replication)
- ✅ walreceiver2 is 'async' (asynchronous)
- ✅ 0 bytes lag (real-time replication)
- ✅ Sub-millisecond time lags (< 3ms)
- ✅ 6+ hours uptime (stable connections)

**Interview Key Point:**
> *"I created a unified dashboard view combining all critical replication metrics. This provides a single query for ops teams to check health. The key insight: lag_size shows how far behind, but time_lag shows user-perceived latency. Both matter for different reasons."*

---

## Step 2: Query the Dashboard

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM replication_dashboard;"
```

**What this does:**
- Retrieves current snapshot of all replication metrics
- Production teams would run this every 30-60 seconds
- Can be exported to monitoring tools (Prometheus, Datadog, etc.)

---

## Step 3: Create Health Check Alert Function

### 3.1: Create health check function

Save this to a file (monitoring_functions.sql):

```sql
CREATE OR REPLACE FUNCTION check_replication_health()
RETURNS TABLE(
    alert_level TEXT,
    alert_message TEXT,
    standby_name TEXT,
    lag_value TEXT
) AS $$
BEGIN
    -- Critical: No standby connected
    IF NOT EXISTS (SELECT 1 FROM pg_stat_replication) THEN
        RETURN QUERY SELECT 
            'CRITICAL'::TEXT,
            'No standby servers connected'::TEXT,
            'N/A'::TEXT,
            '0 replicas'::TEXT;
        RETURN;
    END IF;
    
    -- Check each standby's health
    RETURN QUERY
    SELECT 
        -- Alert level based on lag
        CASE 
            WHEN state != 'streaming' THEN 'CRITICAL'
            WHEN lag_bytes > 104857600 THEN 'CRITICAL'  -- > 100MB
            WHEN lag_bytes > 10485760 THEN 'WARNING'    -- > 10MB
            WHEN lag_bytes > 1048576 THEN 'INFO'        -- > 1MB
            ELSE 'OK'
        END::TEXT AS alert_level,
        
        -- Human-readable message
        CASE 
            WHEN state != 'streaming' THEN 'Standby not streaming - connection lost'
            WHEN lag_bytes > 104857600 THEN 'Replication lag exceeds 100MB - investigate immediately'
            WHEN lag_bytes > 10485760 THEN 'Replication lag exceeds 10MB - monitor closely'
            WHEN lag_bytes > 1048576 THEN 'Replication lag exceeds 1MB - minor concern'
            ELSE 'Replication healthy - all systems normal'
        END::TEXT AS alert_message,
        
        application_name::TEXT AS standby_name,
        pg_size_pretty(lag_bytes)::TEXT AS lag_value
    FROM (
        SELECT 
            application_name,
            state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
        FROM pg_stat_replication
    ) AS lag_data;
END;
$$ LANGUAGE plpgsql;
```

### 3.2: Execute the function

```bash
docker exec -i postgres-primary psql -U postgres < monitoring_functions.sql
```

### 3.3: Test the health check

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM check_replication_health();"
```

**Expected Result:**
```
 alert_level |         alert_message          | standby_name  | lag_value 
-------------+--------------------------------+---------------+-----------
 OK          | Replication healthy            | walreceiver   | 0 bytes
 OK          | Replication healthy            | walreceiver2  | 0 bytes
```

**What this does:**
- **Automated health checking**: Single function call shows all problems
- **Alert levels**: CRITICAL → WARNING → INFO → OK
- **Thresholds**:
  - CRITICAL: No connection OR lag > 100MB
  - WARNING: Lag > 10MB
  - INFO: Lag > 1MB
  - OK: Everything normal

**Interview Key Point:**
> *"I designed a 4-tier alert system: CRITICAL (> 100MB lag or disconnected), WARNING (> 10MB), INFO (> 1MB), and OK. These thresholds based on:*
> - *100MB = ~6 minutes of high-volume writes (recovery takes time)*
> - *10MB = ~30 seconds of writes (manageable)*
> - *1MB = ~3 seconds (informational only)*
> 
> *Page DBA for CRITICAL, email for WARNING, log for INFO."*

---

## Step 4: WAL Statistics Monitoring

### 4.1: Create WAL monitoring view

```bash
docker exec postgres-primary psql -U postgres -c "
CREATE OR REPLACE VIEW wal_statistics AS
SELECT 
    -- Current WAL position
    pg_current_wal_lsn() AS current_wal_lsn,
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file,
    
    -- WAL directory size
    pg_size_pretty(pg_wal_directory_size()) AS wal_directory_size,
    pg_wal_directory_size() AS wal_directory_bytes,
    
    -- Replication slot statistics
    (SELECT COUNT(*) FROM pg_replication_slots) AS replication_slots,
    (SELECT COUNT(*) FROM pg_replication_slots WHERE active = true) AS active_slots,
    
    -- WAL retained by slots
    (SELECT pg_size_pretty(SUM(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))) 
     FROM pg_replication_slots) AS total_wal_retained,
     
    -- WAL generation rate (approximate)
    pg_size_pretty(pg_wal_directory_size() / EXTRACT(epoch FROM (now() - pg_postmaster_start_time()))) AS wal_rate_per_second
FROM pg_stat_replication
LIMIT 1;
"
```

### 4.2: Query WAL statistics

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM wal_statistics;"
```

**Expected Result:**
```
 current_wal_lsn | current_wal_file    | wal_directory_size | replication_slots | active_slots | total_wal_retained | wal_rate_per_second
-----------------+---------------------+--------------------+-------------------+--------------+--------------------+--------------------
 0/44AA5000      | 0000000100000000000000044 | 385 MB           | 2                 | 2            | 32 MB              | 1234 bytes
```

**What this does:**
- **current_wal_lsn**: Latest write position in WAL
- **current_wal_file**: Active WAL segment file
- **wal_directory_size**: Total WAL storage used (should be monitored)
- **replication_slots**: How many standbys configured
- **active_slots**: How many standbys currently connected
- **total_wal_retained**: WAL kept for standby catch-up (grows if standby is down!)
- **wal_rate_per_second**: How fast WAL is being generated

**Alert on:**
- wal_directory_size > 10GB (disk filling up)
- active_slots < replication_slots (standby disconnected)
- total_wal_retained > 5GB (standby far behind)

**Interview Key Point:**
> *"WAL monitoring is critical because:*
> 1. *If standby disconnects, primary must retain WAL until it reconnects*
> 2. *If WAL fills disk, database crashes*
> 3. *WAL growth rate helps capacity planning*
> 
> *I monitor WAL directory size and alert if > 10GB. Also track WAL retention per standby - if one standby is down, its slot retains WAL indefinitely until manually dropped."*

---

## Step 5: Replication Slot Details

### 5.1: View replication slot information

```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    slot_name,
    slot_type,
    database,
    active,
    restart_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
    confirmed_flush_lsn,
    temporary
FROM pg_replication_slots
ORDER BY slot_name;
"
```

**Expected Result:**
```
   slot_name   | slot_type | database | active | restart_lsn | wal_retained | confirmed_flush_lsn | temporary 
---------------+-----------+----------+--------+-------------+--------------+---------------------+-----------
 standby_slot  | physical  | NULL     | t      | 0/44A00000  | 16 MB        | NULL                | f
 standby_slot2 | physical  | NULL     | t      | 0/44A00000  | 16 MB        | NULL                | f
```

**What this does:**
- **slot_name**: Identifier for each standby
- **slot_type**: 'physical' (streaming) or 'logical' (logical replication)
- **active**: Is standby currently connected?
- **restart_lsn**: Where standby will resume if reconnected
- **wal_retained**: How much WAL kept for this slot
- **temporary**: Permanent or temporary slot

**Interview Key Point:**
> *"Replication slots guarantee WAL availability for standbys, but have a dangerous side effect: if a standby never reconnects, its slot retains WAL forever, filling the disk. I monitor wal_retained per slot and alert if > 5GB. I also have a policy to manually drop slots if standby is down > 7 days."*

---

## Step 6: Historical Performance Tracking

### 6.1: Create performance metrics table

```bash
docker exec postgres-primary psql -U postgres -c "
CREATE TABLE IF NOT EXISTS replication_metrics_history (
    id SERIAL PRIMARY KEY,
    recorded_at TIMESTAMP DEFAULT now(),
    standby_name TEXT,
    state TEXT,
    sync_state TEXT,
    lag_bytes BIGINT,
    write_lag_ms NUMERIC,
    flush_lag_ms NUMERIC,
    replay_lag_ms NUMERIC,
    connection_uptime INTERVAL
);

CREATE INDEX IF NOT EXISTS idx_metrics_recorded_at ON replication_metrics_history(recorded_at);
CREATE INDEX IF NOT EXISTS idx_metrics_standby ON replication_metrics_history(standby_name);
"
```

### 6.2: Create function to log metrics

```bash
docker exec postgres-primary psql -U postgres -c "
CREATE OR REPLACE FUNCTION log_replication_metrics() 
RETURNS void AS \$\$
BEGIN
    INSERT INTO replication_metrics_history (
        standby_name, state, sync_state, lag_bytes,
        write_lag_ms, flush_lag_ms, replay_lag_ms, connection_uptime
    )
    SELECT 
        application_name,
        state,
        sync_state,
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),
        EXTRACT(epoch FROM write_lag) * 1000,
        EXTRACT(epoch FROM flush_lag) * 1000,
        EXTRACT(epoch FROM replay_lag) * 1000,
        now() - backend_start
    FROM pg_stat_replication;
END;
\$\$ LANGUAGE plpgsql;
"
```

### 6.3: Log current metrics

```bash
docker exec postgres-primary psql -U postgres -c "SELECT log_replication_metrics();"
```

### 6.4: Schedule periodic logging (optional - would use cron in production)

```bash
docker exec postgres-primary psql -U postgres -c "
-- In production, this would be a cron job:
-- */5 * * * * psql -U postgres -c 'SELECT log_replication_metrics();'

SELECT 'Metrics logging function created!' AS status;
"
```

### 6.5: Query historical data

```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    recorded_at,
    standby_name,
    state,
    pg_size_pretty(lag_bytes) AS lag,
    round(write_lag_ms::numeric, 2) || ' ms' AS write_lag,
    round(replay_lag_ms::numeric, 2) || ' ms' AS replay_lag
FROM replication_metrics_history
ORDER BY recorded_at DESC
LIMIT 10;
"
```

**What this does:**
- **Historical tracking**: Stores metrics over time for trend analysis
- **Capacity planning**: See peak lag times, identify patterns
- **Root cause analysis**: When incident occurs, look back at metrics
- **SLA reporting**: Prove 99.99% uptime with data

**Production Usage:**
```bash
# Cron job (every 5 minutes):
*/5 * * * * psql -U postgres -c "SELECT log_replication_metrics();"

# Retention policy (keep 90 days):
0 2 * * * psql -U postgres -c "DELETE FROM replication_metrics_history WHERE recorded_at < now() - interval '90 days';"
```

**Interview Key Point:**
> *"Historical metrics are essential for:*
> 1. *Trend analysis - is lag increasing over time?*
> 2. *Capacity planning - peak times need more resources?*
> 3. *RCA - what happened before the incident?*
> 4. *SLA reporting - prove 99.99% uptime to management*
> 
> *I log metrics every 5 minutes, retain 90 days, and create weekly reports showing max/avg/p95 lag. This data drove our decision to add a third standby last year."*

---

## Step 7: Create Alert Summary View

### 7.1: Comprehensive alert dashboard

```bash
docker exec postgres-primary psql -U postgres -c "
CREATE OR REPLACE VIEW alert_summary AS
WITH health AS (
    SELECT * FROM check_replication_health()
),
wal_info AS (
    SELECT 
        pg_wal_directory_size() AS wal_bytes,
        (SELECT COUNT(*) FROM pg_replication_slots WHERE active = false) AS inactive_slots
)
SELECT 
    -- Overall health
    CASE 
        WHEN EXISTS (SELECT 1 FROM health WHERE alert_level = 'CRITICAL') THEN 'CRITICAL'
        WHEN EXISTS (SELECT 1 FROM health WHERE alert_level = 'WARNING') THEN 'WARNING'
        WHEN EXISTS (SELECT 1 FROM health WHERE alert_level = 'INFO') THEN 'INFO'
        ELSE 'OK'
    END AS overall_status,
    
    -- Counts
    (SELECT COUNT(*) FROM health WHERE alert_level = 'CRITICAL') AS critical_alerts,
    (SELECT COUNT(*) FROM health WHERE alert_level = 'WARNING') AS warning_alerts,
    (SELECT COUNT(*) FROM health WHERE alert_level = 'INFO') AS info_alerts,
    
    -- WAL health
    CASE 
        WHEN wal_bytes > 10737418240 THEN 'CRITICAL: WAL > 10GB'
        WHEN wal_bytes > 5368709120 THEN 'WARNING: WAL > 5GB'
        ELSE 'OK'
    END AS wal_status,
    pg_size_pretty(wal_bytes) AS wal_size,
    
    -- Slot health
    CASE 
        WHEN inactive_slots > 0 THEN 'WARNING: ' || inactive_slots || ' inactive slots'
        ELSE 'OK'
    END AS slot_status
    
FROM wal_info;
"
```

### 7.2: Query alert summary

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM alert_summary;"
```

**Expected Result:**
```
 overall_status | critical_alerts | warning_alerts | info_alerts | wal_status | wal_size | slot_status 
----------------+-----------------+----------------+-------------+------------+----------+-------------
 OK             |               0 |              0 |           0 | OK         | 385 MB   | OK
```

**What this does:**
- **Single pane of glass**: One query shows everything
- **Traffic light system**: GREEN (OK) → YELLOW (WARNING) → RED (CRITICAL)
- **Actionable**: Tells you what's wrong, not just that something is wrong

**Interview Key Point:**
> *"I created a unified alert dashboard that aggregates all health checks into a traffic light system. This is what NOC teams see on their monitoring screens. If overall_status = 'CRITICAL', they page the DBA. If 'WARNING', they create a ticket. This reduces alert fatigue - only actionable alerts reach humans."*

---

## Step 8: Simulate High Load and Monitor

### 8.1: Generate write load

```bash
docker exec postgres-primary psql -U postgres -c "
CREATE TABLE IF NOT EXISTS load_test (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP DEFAULT now()
);

-- Insert 50,000 rows to create some lag
INSERT INTO load_test (data)
SELECT 'Test data ' || i
FROM generate_series(1, 50000) i;

SELECT 'Load test complete - 50,000 rows inserted' AS status;
"
```

### 8.2: Immediately check lag

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM replication_dashboard;"
```

### 8.3: Check health during load

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM check_replication_health();"
```

### 8.4: Monitor lag recovery

```bash
# Check every 2 seconds for 10 seconds
for i in {1..5}; do
  echo "Check $i:"
  docker exec postgres-primary psql -U postgres -c "SELECT application_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag FROM pg_stat_replication;"
  sleep 2
done
```

**Expected Behavior:**
```
Check 1: lag = 2-5 MB (during load)
Check 2: lag = 1-2 MB (catching up)
Check 3: lag = 512 KB (almost caught up)
Check 4: lag = 0 bytes (caught up)
Check 5: lag = 0 bytes (stable)
```

**What this demonstrates:**
- Replication lag during high write load
- Recovery time (how fast standby catches up)
- Resilience (no connection loss, just temporary lag)

---

## Step 9: Test Alert Scenarios

### 9.1: Simulate standby disconnection

```bash
# Stop standby2 to simulate failure
docker stop postgres-standby2

# Wait 5 seconds
sleep 5

# Check health
docker exec postgres-primary psql -U postgres -c "SELECT * FROM check_replication_health();"
```

**Expected Result:**
```
 alert_level |         alert_message          | standby_name  | lag_value 
-------------+--------------------------------+---------------+-----------
 OK          | Replication healthy            | walreceiver   | 0 bytes
```

Note: walreceiver2 should be missing (disconnected).

### 9.2: Check slot status after disconnection

```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;
"
```

**Expected Result:**
```
   slot_name   | active | wal_retained 
---------------+--------+--------------
 standby_slot  | t      | 0 bytes
 standby_slot2 | f      | 5-10 MB      ← Inactive, accumulating WAL!
```

**What this demonstrates:**
- Inactive slot retains WAL
- WAL grows while standby is down
- This is why monitoring active_slots is critical

### 9.3: Restart standby and verify recovery

```bash
# Restart standby2
docker start postgres-standby2

# Wait for reconnection (30 seconds)
sleep 30

# Verify reconnection
docker exec postgres-primary psql -U postgres -c "SELECT * FROM replication_dashboard;"
```

**Expected Result:**
Both standbys should show state = 'streaming' and lag = 0 bytes.

---

## 📊 Final Monitoring Summary

### Key Metrics Created:

1. **replication_dashboard** - Unified view of all replication metrics
2. **check_replication_health()** - Automated health check with alert levels
3. **wal_statistics** - WAL growth and retention monitoring
4. **replication_metrics_history** - Historical tracking for trends
5. **alert_summary** - Single pane of glass for NOC teams

### Alert Thresholds:

| Metric | INFO | WARNING | CRITICAL |
|--------|------|---------|----------|
| **Lag** | > 1 MB | > 10 MB | > 100 MB |
| **WAL Size** | - | > 5 GB | > 10 GB |
| **Connection** | - | - | Disconnected |
| **Inactive Slots** | - | > 0 | - |

### Production Cron Jobs:

```bash
# Every 5 minutes: Log metrics
*/5 * * * * psql -U postgres -c "SELECT log_replication_metrics();"

# Every minute: Check health
* * * * * psql -U postgres -c "SELECT * FROM alert_summary;" | grep -v "OK" && send_alert

# Daily: Cleanup old metrics
0 2 * * * psql -U postgres -c "DELETE FROM replication_metrics_history WHERE recorded_at < now() - interval '90 days';"

# Hourly: Check WAL growth
0 * * * * psql -U postgres -c "SELECT * FROM wal_statistics;" >> /var/log/wal_stats.log
```

---

## 🎓 Interview Preparation Section

### Question 1: "What metrics do you monitor for replication?"

**Expert Answer:**
```
"I monitor 5 categories of metrics:

1. CONNECTION HEALTH:
   - State (should be 'streaming')
   - Uptime (unexpected restarts indicate issues)
   - Sync state (sync vs async)

2. LAG METRICS:
   - Total lag (current_wal_lsn - replay_lsn)
   - Write lag (network latency)
   - Flush lag (disk I/O on standby)
   - Replay lag (CPU on standby)
   
   Alert thresholds: > 10MB warning, > 100MB critical

3. WAL STATISTICS:
   - WAL directory size (alert if > 10GB)
   - WAL generation rate (capacity planning)
   - WAL retained per slot (detect disconnected standbys)

4. REPLICATION SLOTS:
   - Active vs inactive slots
   - WAL retained per slot
   - Slot with highest retention

5. HISTORICAL TRENDS:
   - Peak lag times
   - Recovery time after incidents
   - Uptime percentage

I export these to Prometheus and visualize in Grafana with automated alerting."
```

---

### Question 2: "How do you set alert thresholds?"

**Expert Answer:**
```
"Threshold setting requires balancing false positives vs missed incidents:

LAG THRESHOLDS:
- INFO (1 MB): Informational only, log but don't alert
- WARNING (10 MB): ~30 seconds of writes at moderate load
  Action: Email to ops team
- CRITICAL (100 MB): ~5-10 minutes of writes
  Action: Page DBA immediately

These are based on our write volume (~300 MB/hour average, 2 GB/hour peak).

CALCULATION:
Average write: 300 MB / 60 min = 5 MB/min
10 MB = 2 minutes of average load (acceptable)
100 MB = 20 minutes at average (unacceptable)

WAL SIZE THRESHOLDS:
- WARNING (5 GB): 70% of typical max (7 GB normal)
- CRITICAL (10 GB): Approaching disk capacity or indicates
  disconnected standby accumulating WAL

CONNECTION THRESHOLDS:
- CRITICAL: Any standby disconnected > 5 minutes
- WARNING: Standby reconnected but lag > 10 MB

I review these quarterly based on:
1. False positive rate (should be < 1%)
2. Missed incidents (should be 0)
3. Growth in write volume (adjust thresholds accordingly)"
```

---

### Question 3: "Walk me through troubleshooting high replication lag"

**Expert Answer:**
```
"My systematic approach:

1. IDENTIFY THE PROBLEM:
   SELECT * FROM replication_dashboard;
   
   Look for:
   - Which standby has lag?
   - How much lag? (bytes and time)
   - Is it write, flush, or replay lag?

2. CATEGORIZE LAG TYPE:
   
   a) HIGH WRITE LAG:
      Cause: Network latency
      Check: ping, network throughput
      Solution: Network optimization, closer data centers
   
   b) HIGH FLUSH LAG:
      Cause: Disk I/O on standby
      Check: iostat on standby server
      Solution: Faster disks, increase checkpoint segments
   
   c) HIGH REPLAY LAG:
      Cause: CPU on standby
      Check: top, pg_stat_activity on standby
      Solution: More CPU, investigate slow queries
   
   d) OVERALL LAG BUT NO SPECIFIC:
      Cause: Primary write burst
      Check: Primary write volume
      Solution: Wait for standby to catch up, or add resources

3. CHECK FOR BLOCKERS:
   -- Long queries on standby
   SELECT * FROM pg_stat_activity WHERE state != 'idle';
   
   -- Hot standby feedback issues
   SHOW hot_standby_feedback;

4. IMMEDIATE ACTIONS:
   - If CRITICAL (> 100 MB):
     * Identify if standby can catch up
     * Consider failing over if primary is struggling
   
   - If WARNING (> 10 MB):
     * Monitor closely
     * Reduce non-critical read load on standby
   
   - If write burst on primary:
     * Throttle application writes if possible
     * Add temporary standby resources

5. PREVENTION:
   - Monitor write patterns, scale before hitting limits
   - Size standby resources >= primary
   - Test failover regularly
   - Keep standby close to primary (low network latency)

Example from production:
- Noticed replay lag at 50 MB during ETL job
- Checked standby: Single slow DELETE query blocking replay
- Killed query (safe on read-only standby)
- Lag recovered in 30 seconds
- Root cause: ETL job running on standby instead of dedicated analytics replica"
```

---

### Question 4: "How do you prevent WAL accumulation?"

**Expert Answer:**
```
"WAL accumulation happens when replication slots retain WAL for disconnected standbys.

MONITORING:
1. Check slot activity:
   SELECT slot_name, active, 
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) 
   FROM pg_replication_slots;

2. Alert on:
   - Inactive slots (active = false)
   - WAL retention > 5 GB per slot
   - Total WAL directory > 10 GB

PREVENTION:
1. Set wal_keep_size (PostgreSQL 13+):
   wal_keep_size = 2GB  # Limit WAL retained
   
   After 2GB, standby must use archive (safer)

2. Monitor slot inactivity:
   SELECT slot_name, 
          now() - last_used_time AS inactive_for
   FROM pg_replication_slots
   WHERE active = false;

3. Drop inactive slots policy:
   # Automated cleanup script
   if slot inactive > 7 days:
       pg_drop_replication_slot(slot_name)
   
   Send alert to team: "Dropped slot X due to inactivity"

4. Use archive as fallback:
   - Configure archive_command
   - Standby can catch up from archive if slot dropped
   - Slower but prevents disk full

INCIDENT RESPONSE:
- Disk 90% full, WAL directory 15 GB
- Identified inactive slot (standby down 3 days)
- Confirmed standby unrecoverable
- Dropped slot: pg_drop_replication_slot('standby_slot')
- WAL space freed immediately
- Rebuilt standby from fresh base backup

KEY LESSON: Slots are powerful but dangerous. Must monitor and have
cleanup policy. I prefer wal_keep_size as safety net - prevents one
broken standby from taking down primary."
```

---

### Question 5: "How do you use historical metrics?"

**Expert Answer:**
```
"Historical metrics are essential for 3 things:

1. TREND ANALYSIS:
   SELECT 
       date_trunc('hour', recorded_at) AS hour,
       standby_name,
       AVG(lag_bytes) AS avg_lag,
       MAX(lag_bytes) AS max_lag,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY lag_bytes) AS p95_lag
   FROM replication_metrics_history
   WHERE recorded_at > now() - interval '7 days'
   GROUP BY 1, 2
   ORDER BY 1 DESC;

   INSIGHTS:
   - Peak lag times (11 PM-1 AM during batch jobs)
   - Growing lag trend (need more resources)
   - Correlation with application events

2. CAPACITY PLANNING:
   - Calculate max write volume: max_lag / time
   - Size standby resources for peak, not average
   - Plan hardware upgrades before hitting limits
   
   Example:
   - Saw p95 lag increasing 10% month-over-month
   - Projected hitting 100MB threshold in 3 months
   - Proactively upgraded standby SSD 2 months early
   - Avoided production incident

3. ROOT CAUSE ANALYSIS:
   When incident occurs, look back:
   
   SELECT * FROM replication_metrics_history
   WHERE recorded_at BETWEEN 
       '2025-11-17 14:00:00' AND '2025-11-17 15:00:00'
   ORDER BY recorded_at;
   
   FINDINGS:
   - Incident at 14:30: Lag spiked to 150 MB
   - Metrics show lag started at 14:15 (15 min before alert)
   - Correlate with application deploy at 14:12
   - Root cause: New feature doing large batch updates
   - Solution: Throttle batch size, deploy reverted

RETENTION STRATEGY:
- 5-minute samples: Keep 90 days
- 1-hour rollups: Keep 2 years
- Daily summaries: Keep 5 years

This supports compliance (data retention policies) and
long-term trend analysis for architecture planning."
```

---

## 🧹 Cleanup

```bash
# Optional: Clean up test data
docker exec postgres-primary psql -U postgres -c "DROP TABLE IF EXISTS load_test;"

# Keep monitoring views and functions for future use!
```

---

## 📝 Final Summary

### Monitoring Stack Created:

1. **replication_dashboard** - Single query for current state
2. **check_replication_health()** - Automated alerting logic
3. **wal_statistics** - WAL growth tracking
4. **replication_metrics_history** - Historical data
5. **alert_summary** - NOC dashboard

### Key Production Practices:

✅ **Multi-layer monitoring** - Connection, lag, WAL, slots  
✅ **Tiered alerting** - INFO → WARNING → CRITICAL  
✅ **Historical tracking** - Trends, RCA, capacity planning  
✅ **Automation** - Functions reduce manual work  
✅ **Single pane of glass** - Ops teams see everything in one view  

### Next Steps for Production:

1. Export metrics to Prometheus/Datadog/CloudWatch
2. Create Grafana dashboards with visualizations
3. Set up PagerDuty/Opsgenie for critical alerts
4. Document runbooks for each alert type
5. Schedule quarterly threshold review
6. Test failover procedures monthly

---

**Scenario 09 completed successfully!** ✅

**Next:** [Scenario 10: Disaster Recovery Drill](./10-disaster-recovery.md)
