#!/bin/bash
# pgPool Quick Start Script

echo "🚀 Starting pgPool-II Hands-On Demo"
echo "===================================="
echo ""

# Step 1: Verify PostgreSQL Setup
echo "📋 Step 1: Checking PostgreSQL containers..."
docker ps --format "table {{.Names}}\t{{.Status}}" | grep postgres
echo ""

# Step 2: Check replication
echo "📋 Step 2: Verifying replication..."
docker exec postgres-primary psql -U postgres -c "SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
echo ""

# Step 3: Ensure network exists
echo "📋 Step 3: Setting up Docker network..."
docker network ls | grep postgres_replication_network > /dev/null 2>&1 || docker network create postgres_replication_network
docker network connect postgres_replication_network postgres-primary 2>/dev/null || echo "Primary already connected"
docker network connect postgres_replication_network postgres-standby 2>/dev/null || echo "Standby already connected"
echo "✅ Network configured"
echo ""

# Step 4: Clean up any existing pgpool container
echo "📋 Step 4: Cleaning up existing pgpool..."
docker stop pgpool 2>/dev/null || true
docker rm pgpool 2>/dev/null || true
echo "✅ Cleanup done"
echo ""

# Step 5: Start pgPool
echo "📋 Step 5: Starting pgPool container..."
docker run -d \
  --name pgpool \
  --network postgres_replication_network \
  -p 9999:9999 \
  -e PGPOOL_BACKEND_NODES="0:postgres-primary:5432,1:postgres-standby:5432" \
  -e PGPOOL_SR_CHECK_USER=postgres \
  -e PGPOOL_SR_CHECK_PASSWORD=postgres \
  -e PGPOOL_POSTGRES_USERNAME=postgres \
  -e PGPOOL_POSTGRES_PASSWORD=postgres \
  -e PGPOOL_ADMIN_USERNAME=admin \
  -e PGPOOL_ADMIN_PASSWORD=admin \
  -e PGPOOL_ENABLE_LOAD_BALANCING=yes \
  -e PGPOOL_ENABLE_LDAP=no \
  bitnami/pgpool:4

echo "⏳ Waiting for pgPool to start..."
sleep 10
echo ""

# Step 6: Verify pgPool is running
echo "📋 Step 6: Checking pgPool status..."
docker ps | grep pgpool
echo ""

# Step 7: Show pgPool logs
echo "📋 Step 7: pgPool logs (last 15 lines)..."
docker logs pgpool --tail 15
echo ""

# Step 8: Test connection
echo "📋 Step 8: Testing connection through pgPool..."
psql -h localhost -p 9999 -U postgres -c "SELECT version();" 2>&1 | head -3
echo ""

echo "✅ pgPool Setup Complete!"
echo ""
echo "📚 Next Steps:"
echo "1. Connect to pgPool: psql -h localhost -p 9999 -U postgres"
echo "2. Create test database: psql -h localhost -p 9999 -U postgres -c 'CREATE DATABASE pgpool_test;'"
echo "3. Follow scenario: cat scenarios/13-pgpool-hands-on-demo.md"
echo ""
echo "🎯 Quick Tests:"
echo "  # Show pool nodes"
echo "  docker exec pgpool psql -h localhost -p 9999 -U postgres -c 'SHOW POOL_NODES;'"
echo ""
echo "  # Check load balancing"
echo "  psql -h localhost -p 9999 -U postgres -c 'SELECT inet_server_addr(), inet_server_port();'"
echo ""
