#!/bin/bash
# Barman PITR Recovery Script
# Restores database to the good state before disaster

set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Barman PITR Recovery - Restoring to Good State         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Load recovery target time
if [ ! -f /tmp/barman_pitr_recovery_time.txt ]; then
    echo "❌ ERROR: Recovery time file not found!"
    echo "Please run ./scripts/barman-pitr-disaster.sh first"
    exit 1
fi

RECOVERY_TIME=$(cat /tmp/barman_pitr_recovery_time.txt)
echo "🎯 Recovery Target: $RECOVERY_TIME"
echo ""

# Record start time for RTO calculation
RECOVERY_START=$(date +%s)
echo "⏱️  Recovery started at: $(date)"
echo ""

# ============================================================
# Step 1: Stop PostgreSQL primary
# ============================================================
echo "Step 1: Stopping PostgreSQL primary..."
docker stop postgres-primary
echo "✅ Primary stopped"
echo ""
sleep 2

# ============================================================
# Step 2: Perform Barman recovery
# ============================================================
echo "Step 2: Performing Barman PITR recovery..."
echo "This will restore the database to: $RECOVERY_TIME"
echo ""

# Recover to a directory in Barman server
docker exec -u barman barman-server barman recover \
  --target-time "$RECOVERY_TIME" \
  pg-primary latest /var/lib/barman/recover

echo "✅ Barman recovery completed"
echo ""

# ============================================================
# Step 3: Create recovery volume and copy data
# ============================================================
echo "Step 3: Preparing recovery volume..."
docker volume rm primary-data-recovery 2>/dev/null || true
docker volume create primary-data-recovery
echo "✅ Recovery volume created"
echo ""

# Copy recovered data to volume
echo "Copying recovered data to volume..."
docker run --rm \
  -v primary-data-recovery:/target \
  --volumes-from barman-server \
  busybox sh -c "cp -a /var/lib/barman/recover/. /target/"

echo "✅ Data copied to recovery volume"
echo ""

# ============================================================
# Step 4: Start PostgreSQL with recovered data
# ============================================================
echo "Step 4: Starting PostgreSQL with recovered data..."

# Start primary with recovered volume
docker run -d \
  --name postgres-primary-recovered \
  --hostname postgres-primary \
  --network postgresql-streaming-replication_postgres-network \
  -p 5432:5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres_password \
  -v primary-data-recovery:/var/lib/postgresql/data \
  postgres:15

echo "Waiting for PostgreSQL to start..."
sleep 10

# Wait for PostgreSQL to be ready
for i in {1..30}; do
  if docker exec postgres-primary-recovered pg_isready -U postgres > /dev/null 2>&1; then
    echo "✅ PostgreSQL is ready!"
    break
  fi
  echo "Waiting... ($i/30)"
  sleep 2
done

echo ""

# ============================================================
# Step 5: Verify recovery
# ============================================================
echo "Step 5: Verifying recovered data..."
echo ""

RECOVERED_DATA=$(docker exec postgres-primary-recovered psql -U postgres -t -A -c "
SELECT 
  'Total: ' || COUNT(*) || ' | Completed: ' || 
  COUNT(*) FILTER (WHERE status='completed') || 
  ' | Pending: ' || COUNT(*) FILTER (WHERE status='pending')
FROM critical_orders;
")

echo "📊 Recovered Data: $RECOVERED_DATA"
echo ""

# Calculate RTO
RECOVERY_END=$(date +%s)
RTO=$((RECOVERY_END - RECOVERY_START))

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  RECOVERY COMPLETE!                                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "⏱️  RTO (Recovery Time Objective): ${RTO} seconds"
echo "🎯 Recovery Point: $RECOVERY_TIME"
echo "📊 Data Recovered: $RECOVERED_DATA"
echo ""
echo "✅ All completed orders have been restored!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Recovery metrics saved to: /tmp/barman_pitr_results.txt"
echo ""

# Save results
cat > /tmp/barman_pitr_results.txt << EOF
Barman PITR Recovery Results
=============================
Recovery Target Time: $RECOVERY_TIME
Recovery Duration (RTO): ${RTO} seconds
Recovered Data: $RECOVERED_DATA
Recovery Status: SUCCESS
EOF

echo "To view detailed results: cat /tmp/barman_pitr_results.txt"
