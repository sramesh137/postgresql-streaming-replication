# Scenario 09: Advanced Replication Monitoring

**Difficulty:** Advanced  
**Duration:** 30-35 minutes  
**Prerequisites:** All previous scenarios completed

## 🎯 Learning Objectives

- Create comprehensive monitoring queries
- Build custom monitoring dashboard
- Set up alerting thresholds
- Understand all replication metrics
- Create automated health checks

## 📚 Background

Production replication requires monitoring:
- Replication lag
- WAL accumulation
- Slot health
- Connection status
- Performance metrics

---

## Step 1: Create Comprehensive Monitoring View

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
CREATE OR REPLACE VIEW replication_dashboard AS
SELECT 
    -- Connection info
    application_name,
    client_addr,
    client_hostname,
    state,
    sync_state,
    -- LSN positions
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    -- Lag metrics
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag_size,
    pg_size_pretty(pg_wal_lsn_diff(write_lsn, flush_lsn)) AS flush_lag_size,
    pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn)) AS replay_lag_size,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS total_lag,
    -- Time lags
    write_lag,
    flush_lag,
    replay_lag,
    -- Health status
    CASE 
        WHEN state != 'streaming' THEN '🔴 CRITICAL: Not streaming'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 104857600 THEN '🔴 CRITICAL: Lag > 100MB'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 10485760 THEN '🟡 WARNING: Lag > 10MB'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 1048576 THEN '🟢 CAUTION: Lag > 1MB'
        ELSE '✅ HEALTHY'
    END AS health_status
FROM pg_stat_replication;

SELECT * FROM replication_dashboard;
EOF
```

---

## Step 2: Create Alert Thresholds

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
CREATE OR REPLACE FUNCTION check_replication_health()
RETURNS TABLE(
    alert_level TEXT,
    alert_message TEXT,
    current_value TEXT
) AS $$
BEGIN
    -- Check if standby is connected
    IF NOT EXISTS (SELECT 1 FROM pg_stat_replication) THEN
        RETURN QUERY SELECT 
            'CRITICAL'::TEXT,
            'No standby connected'::TEXT,
            '0 replicas'::TEXT;
        RETURN;
    END IF;
    
    -- Check lag
    RETURN QUERY
    SELECT 
        CASE 
            WHEN lag_bytes > 104857600 THEN 'CRITICAL'
            WHEN lag_bytes > 10485760 THEN 'WARNING'
            WHEN lag_bytes > 1048576 THEN 'INFO'
            ELSE 'OK'
        END,
        'Replication lag: ' || pg_size_pretty(lag_bytes),
        application_name
    FROM (
        SELECT 
            application_name,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
        FROM pg_stat_replication
    ) AS lag_data;
END;
$$ LANGUAGE plpgsql;

-- Test it
SELECT * FROM check_replication_health();
EOF
```

---

## Step 3: WAL Statistics

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    -- Current WAL info
    pg_current_wal_lsn() AS current_wal,
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file,
    -- WAL directory size
    pg_size_pretty(pg_wal_directory_size()) AS wal_directory_size,
    -- Slot retention
    (SELECT pg_size_pretty(SUM(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))) 
     FROM pg_replication_slots) AS total_wal_retained;
EOF
```

---

## Step 4: Historical Performance Tracking

Create a table to log replication metrics over time.

---

## 🎓 Key Takeaways

✅ **Comprehensive monitoring essential** for production  
✅ **Multiple metrics needed** for complete picture  
✅ **Alert thresholds prevent** outages  
✅ **Historical data helps** capacity planning  
✅ **Automated checks reduce** manual work  

---

## ➡️ Next: [Scenario 10: Disaster Recovery Drill](./10-disaster-recovery.md)
