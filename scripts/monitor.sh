#!/bin/bash
# Monitoring script for PostgreSQL streaming replication
# Shows real-time status of primary and standby servers

echo "========================================"
echo "PostgreSQL Streaming Replication Status"
echo "========================================"
echo ""

echo "PRIMARY SERVER STATUS"
echo "---------------------"
echo ""
echo "Connected Replicas:"
docker exec postgres-primary psql -U postgres -x -c "
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
" 2>/dev/null || echo "No replicas connected or primary not running"

echo ""
echo "Replication Slots:"
docker exec postgres-primary psql -U postgres -c "
SELECT 
    slot_name, 
    slot_type, 
    active, 
    restart_lsn,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
FROM pg_replication_slots;
" 2>/dev/null || echo "Primary not running"

echo ""
echo "========================================"
echo ""
echo "STANDBY SERVER STATUS"
echo "---------------------"
echo ""
echo "Recovery Status:"
docker exec postgres-standby psql -U postgres -c "
SELECT 
    CASE WHEN pg_is_in_recovery() THEN 'STANDBY (Read-Only)' ELSE 'PRIMARY (Read-Write)' END AS server_mode,
    pg_last_wal_receive_lsn() AS last_received_lsn,
    pg_last_wal_replay_lsn() AS last_replayed_lsn,
    pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS replay_lag_bytes,
    pg_last_xact_replay_timestamp() AS last_replay_time,
    now() - pg_last_xact_replay_timestamp() AS replication_delay;
" 2>/dev/null || echo "Standby not running"

echo ""
echo "========================================"
echo ""
echo "QUICK HEALTH CHECK"
echo "------------------"

# Check if primary is running
if docker exec postgres-primary pg_isready -U postgres > /dev/null 2>&1; then
    echo "✓ Primary: Running"
else
    echo "✗ Primary: Not running"
fi

# Check if standby is running
if docker exec postgres-standby pg_isready -U postgres > /dev/null 2>&1; then
    echo "✓ Standby: Running"
else
    echo "✗ Standby: Not running"
fi

# Check if standby is in recovery
IS_RECOVERY=$(docker exec postgres-standby psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]')
if [ "$IS_RECOVERY" = "t" ]; then
    echo "✓ Standby: In recovery mode (correct)"
else
    echo "⚠ Standby: Not in recovery mode (may be promoted)"
fi

echo ""
echo "========================================"
echo ""
echo "TIP: Run this script continuously with:"
echo "watch -n 2 bash scripts/monitor.sh"
echo ""
