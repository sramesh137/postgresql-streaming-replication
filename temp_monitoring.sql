-- Scenario 09: Advanced Monitoring Queries

-- Health Check Function
CREATE OR REPLACE FUNCTION check_replication_health()
RETURNS TABLE(
    alert_level TEXT,
    alert_message TEXT,
    standby_name TEXT,
    lag_value TEXT
) AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_stat_replication) THEN
        RETURN QUERY SELECT 
            'CRITICAL'::TEXT,
            'No standby servers connected'::TEXT,
            'N/A'::TEXT,
            '0 replicas'::TEXT;
        RETURN;
    END IF;
    
    RETURN QUERY
    SELECT 
        CASE 
            WHEN state != 'streaming' THEN 'CRITICAL'
            WHEN lag_bytes > 104857600 THEN 'CRITICAL'
            WHEN lag_bytes > 10485760 THEN 'WARNING'
            WHEN lag_bytes > 1048576 THEN 'INFO'
            ELSE 'OK'
        END::TEXT,
        CASE 
            WHEN state != 'streaming' THEN 'Standby not in streaming state'
            WHEN lag_bytes > 104857600 THEN 'Lag exceeds 100MB'
            WHEN lag_bytes > 10485760 THEN 'Lag exceeds 10MB'
            WHEN lag_bytes > 1048576 THEN 'Lag exceeds 1MB'
            ELSE 'Replication healthy'
        END::TEXT,
        application_name::TEXT,
        pg_size_pretty(lag_bytes)::TEXT
    FROM (
        SELECT 
            application_name,
            state,
            pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
        FROM pg_stat_replication
    ) AS lag_data;
END;
$$ LANGUAGE plpgsql;

-- Test the function
SELECT * FROM check_replication_health();
