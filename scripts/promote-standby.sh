#!/bin/bash
# Failover script - Promotes standby to primary
# Use this when the primary server fails

set -e

echo "========================================"
echo "PostgreSQL Failover - Promote Standby"
echo "========================================"
echo ""
echo "WARNING: This will promote the standby to primary!"
echo "Only do this if the primary has failed."
echo ""

read -p "Are you sure you want to promote standby? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Failover cancelled."
    exit 0
fi

echo ""
echo "Step 1: Checking standby status..."
IS_RECOVERY=$(docker exec postgres-standby psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]')

if [ "$IS_RECOVERY" != "t" ]; then
    echo "ERROR: Standby is not in recovery mode. It may already be promoted."
    exit 1
fi

echo "✓ Standby is in recovery mode"
echo ""

echo "Step 2: Promoting standby to primary..."
docker exec postgres-standby psql -U postgres -c "SELECT pg_promote();"

echo ""
echo "Step 3: Waiting for promotion to complete..."
sleep 3

echo ""
echo "Step 4: Verifying promotion..."
IS_RECOVERY_AFTER=$(docker exec postgres-standby psql -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]')

if [ "$IS_RECOVERY_AFTER" = "f" ]; then
    echo "✓ SUCCESS: Standby promoted to primary!"
    echo ""
    echo "The standby (port 5433) is now a read-write primary server."
    echo ""
    echo "Next steps:"
    echo "1. Update application connection strings to point to port 5433"
    echo "2. If you want to add the old primary as a new standby, run:"
    echo "   bash scripts/reestablish-old-primary.sh"
else
    echo "✗ ERROR: Promotion may have failed. Check logs:"
    echo "docker-compose logs postgres-standby"
    exit 1
fi

echo ""
echo "========================================"
echo ""
