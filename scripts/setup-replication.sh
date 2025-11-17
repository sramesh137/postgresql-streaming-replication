#!/bin/bash
# Automated setup script for PostgreSQL streaming replication
# This script configures the standby server to replicate from primary

set -e

echo "================================================"
echo "PostgreSQL Streaming Replication Setup Script"
echo "================================================"
echo ""

# Configuration
PRIMARY_HOST="postgres-primary"
STANDBY_CONTAINER="postgres-standby"
REPLICATION_USER="replicator"
REPLICATION_PASSWORD="replicator_password"
SLOT_NAME="standby_slot"

echo "Step 1: Creating replication slot on primary..."
docker exec -it postgres-primary psql -U postgres -c "SELECT pg_create_physical_replication_slot('${SLOT_NAME}');" 2>/dev/null || echo "Replication slot may already exist"

echo ""
echo "Step 2: Stopping standby container..."
docker-compose stop ${STANDBY_CONTAINER}

echo ""
echo "Step 3: Cleaning standby data directory..."
docker-compose run --rm ${STANDBY_CONTAINER} bash -c "rm -rf /var/lib/postgresql/data/*" || true

echo ""
echo "Step 4: Creating base backup from primary..."
echo "This may take a few minutes..."
docker-compose run --rm ${STANDBY_CONTAINER} bash -c "PGPASSWORD=${REPLICATION_PASSWORD} pg_basebackup -h ${PRIMARY_HOST} -D /var/lib/postgresql/data -U ${REPLICATION_USER} -v -P -X stream"

echo ""
echo "Step 5: Creating standby.signal file..."
docker-compose run --rm ${STANDBY_CONTAINER} bash -c "touch /var/lib/postgresql/data/standby.signal"

echo ""
echo "Step 6: Configuring primary connection info..."
docker-compose run --rm ${STANDBY_CONTAINER} bash -c "cat >> /var/lib/postgresql/data/postgresql.conf <<EOF

# Streaming Replication Configuration
primary_conninfo = 'host=${PRIMARY_HOST} port=5432 user=${REPLICATION_USER} password=${REPLICATION_PASSWORD} application_name=standby1'
primary_slot_name = '${SLOT_NAME}'
hot_standby = on
hot_standby_feedback = on
EOF"

echo ""
echo "Step 7: Starting standby container..."
docker-compose start ${STANDBY_CONTAINER}

echo ""
echo "Step 8: Waiting for standby to start..."
sleep 5

echo ""
echo "================================================"
echo "Setup Complete!"
echo "================================================"
echo ""
echo "Verification Commands:"
echo "----------------------"
echo "# Check replication status on primary:"
echo "docker exec -it postgres-primary psql -U postgres -c 'SELECT * FROM pg_stat_replication;'"
echo ""
echo "# Check standby is in recovery mode:"
echo "docker exec -it postgres-standby psql -U postgres -c 'SELECT pg_is_in_recovery();'"
echo ""
echo "# Monitor replication lag:"
echo "bash scripts/monitor.sh"
echo ""
