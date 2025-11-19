#!/bin/bash
# Replication Health Check Script
# Purpose: Quick health check for PostgreSQL streaming replication
# Usage: ./check-replication.sh

set -e

echo "=== PostgreSQL Replication Health Check ==="
echo "Time: $(date)"
echo ""

# Check if containers are running
echo "📦 Container Status:"
docker ps --filter name=postgres --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -4
echo ""

# Check replication connections
echo "🔗 Replication Connections:"
docker exec postgres-primary psql -U postgres -t -c "
SELECT 
    application_name || ' (' || client_addr || ')' AS standby,
    state,
    sync_state,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
FROM pg_stat_replication;
" | sed 's/^/  /'
echo ""

# Check WAL statistics
echo "📊 WAL Statistics:"
docker exec postgres-primary psql -U postgres -t -c "
SELECT 
    'Total WAL Size: ' || pg_size_pretty(SUM(size)) ||
    ' (' || COUNT(*) || ' files)' AS wal_info
FROM pg_ls_waldir();
" | sed 's/^/  /'
echo ""

# Check replication slots
echo "🎰 Replication Slots:"
docker exec postgres-primary psql -U postgres -t -c "
SELECT 
    slot_name || ' [' || 
    CASE WHEN active THEN 'ACTIVE' ELSE 'INACTIVE' END || 
    '] - Retained: ' || 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS slot_info
FROM pg_replication_slots
ORDER BY slot_name;
" | sed 's/^/  /'
echo ""

# Simple health status
LAG_COUNT=$(docker exec postgres-primary psql -U postgres -t -c "
SELECT COUNT(*) FROM pg_stat_replication 
WHERE pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 10485760;
" | tr -d ' ')

INACTIVE_SLOTS=$(docker exec postgres-primary psql -U postgres -t -c "
SELECT COUNT(*) FROM pg_replication_slots WHERE active = false;
" | tr -d ' ')

TOTAL_STANDBYS=$(docker exec postgres-primary psql -U postgres -t -c "
SELECT COUNT(*) FROM pg_stat_replication;
" | tr -d ' ')

echo "🏥 Health Summary:"
if [ "$TOTAL_STANDBYS" -eq 0 ]; then
    echo "  ❌ CRITICAL: No standby servers connected!"
    exit 1
elif [ "$LAG_COUNT" -gt 0 ]; then
    echo "  ⚠️  WARNING: $LAG_COUNT standby(s) with lag > 10MB"
    exit 1
elif [ "$INACTIVE_SLOTS" -gt 0 ]; then
    echo "  ⚠️  WARNING: $INACTIVE_SLOTS inactive replication slot(s)"
    exit 1
else
    echo "  ✅ OK: All standbys healthy ($TOTAL_STANDBYS connected, 0 lag)"
    exit 0
fi
