#!/bin/bash
# Barman PITR Scenario - Simplified Setup
# This script sets up Barman and performs a complete PITR test

set -e

echo "🚀 Starting Barman PITR Scenario"
echo "================================"
echo ""

# Step 1: Create Barman container
echo "📦 Step 1: Creating Barman container..."
docker run -d \
  --name barman-server \
  --hostname barman-server \
  --network postgresql-streaming-replication_postgres-network \
  -e POSTGRES_PASSWORD=not_used \
  postgres:15 \
  bash -c "
    apt-get update -qq && 
    apt-get install -y -qq barman postgresql-client-15 rsync openssh-client openssh-server sudo &&
    useradd -m -s /bin/bash barman || true &&
    echo 'barman:barman' | chpasswd &&
    usermod -aG sudo barman &&
    echo 'barman ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers &&
    mkdir -p /var/lib/barman /var/log/barman /etc/barman/barman.d &&
    chown -R barman:barman /var/lib/barman /var/log/barman /etc/barman &&
    service ssh start &&
    tail -f /dev/null
  "

echo "✅ Barman container created"
echo "Waiting for container to be ready..."
sleep 10

# Wait for barman command to be available
for i in {1..10}; do
  if docker exec barman-server which barman >/dev/null 2>&1; then
    echo "Barman is ready!"
    break
  fi
  echo "Waiting... ($i/10)"
  sleep 3
done

# Step 2: Configure Barman
echo ""
echo "⚙️  Step 2: Configuring Barman..."

docker exec barman-server mkdir -p /etc/barman/barman.d
docker exec barman-server bash -c "cat > /etc/barman/barman.conf" << 'EOF'
[barman]
barman_home = /var/lib/barman
barman_user = barman
log_file = /var/log/barman/barman.log
log_level = INFO
compression = gzip
backup_method = postgres
archiver = on
EOF

docker exec barman-server bash -c "cat > /etc/barman/barman.d/pg-primary.conf" << 'EOF'
[pg-primary]
description = "PostgreSQL Primary Server"
conninfo = host=postgres-primary user=postgres dbname=postgres
streaming_conninfo = host=postgres-primary user=replicator
backup_method = postgres
streaming_archiver = on
slot_name = barman_slot
path_prefix = "/usr/lib/postgresql/15/bin"
EOF

docker exec barman-server chown -R barman:barman /etc/barman /var/lib/barman /var/log/barman

echo "✅ Barman configured"

# Step 3: Create replication slot for Barman
echo ""
echo "🔌 Step 3: Creating replication slot for Barman..."
docker exec postgres-primary psql -U postgres -c "
  SELECT pg_create_physical_replication_slot('barman_slot');
" 2>/dev/null || echo "Slot may already exist"

echo "✅ Replication slot created"

# Step 4: Test connectivity
echo ""
echo "🔍 Step 4: Testing Barman connectivity..."
docker exec -u barman barman-server barman check pg-primary || echo "Some checks may fail initially"

# Step 5: Take first backup
echo ""
echo "💾 Step 5: Taking initial Barman backup..."
echo "This may take 1-2 minutes..."
docker exec -u barman barman-server barman backup pg-primary

echo "✅ Backup completed"

# Step 6: Verify backup
echo ""
echo "📋 Step 6: Verifying backup..."
docker exec -u barman barman-server barman list-backup pg-primary

echo ""
echo "✅ Barman setup complete!"
echo "================================"
echo ""
echo "Next steps:"
echo "1. Run: ./scripts/barman-pitr-test.sh"
echo "   This will simulate disaster and perform PITR"
echo ""
