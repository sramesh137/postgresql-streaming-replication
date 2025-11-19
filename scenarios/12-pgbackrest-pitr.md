# Scenario 12: Point-in-Time Recovery with pgBackRest

**Difficulty:** Advanced  
**Duration:** 45-55 minutes  
**Technology:** pgBackRest (industry-standard backup solution)  
**Interview Relevance:** ⭐⭐⭐⭐⭐ (Critical for production DBA roles)

---

## 🎯 Learning Objectives

- Set up pgBackRest for PostgreSQL backup/recovery
- Understand full, differential, and incremental backups
- Perform Point-in-Time Recovery (PITR)
- Simulate and recover from accidental data deletion
- Master production backup strategies

---

## 📚 Why pgBackRest?

### Industry Standard Features:
✅ **Parallel backup/restore** - Faster than pg_basebackup  
✅ **Compression & encryption** - Save storage, secure data  
✅ **Multiple backup types** - Full, differential, incremental  
✅ **PITR support** - Restore to any point in time  
✅ **Cloud storage** - S3, Azure, GCS support  
✅ **Retention policies** - Automatic cleanup of old backups  

### Production Usage:
- **AWS RDS** uses pgBackRest internally
- **Azure Database for PostgreSQL** similar architecture
- **Major enterprises** prefer it over Barman
- **Kubernetes operators** (Crunchy Data) use it

---

## Real-World Scenario

```
09:00 AM - Last full backup completed
11:45 AM - Database healthy, 50,000 orders in system
11:50 AM - Junior dev runs: DELETE FROM orders WHERE 1=1; (typo!)
11:51 AM - Disaster discovered! All orders gone!
11:52 AM - DBA paged: "URGENT: All orders deleted!"

Challenge: Recover to 11:49 AM (1 minute before disaster)
RTO Target: < 15 minutes
RPO: 0 data loss
```

**Your mission:** Demonstrate professional disaster recovery using pgBackRest.

---

## Architecture Overview

```
┌─────────────────┐         ┌──────────────────┐
│  Primary DB     │         │  pgBackRest      │
│  (Port 5432)    │────────▶│  Repository      │
│                 │ Archive │  - Full backups  │
│  Streaming Rep  │  WAL    │  - Incremental   │
│  to Standbys    │         │  - WAL archive   │
└─────────────────┘         └──────────────────┘
        │
        ├─────────────┬─────────────┐
        ▼             ▼             ▼
   Standby 1     Standby 2     Standby 3
   (Sync)        (Async)       (Recovery Test)
```

---

## Prerequisites

### Check Current Cluster
```bash
docker ps --filter name=postgres --format "table {{.Names}}\t{{.Status}}"
```

Expected: Primary + 2 standbys running

### Verify Data Exists
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
  schemaname, 
  tablename, 
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
"
```

---

## Step 1: Set Up pgBackRest

### 1.1: Create pgBackRest Docker Container

Create `docker-compose-backrest.yml`:

```yaml
version: '3.8'

services:
  pgbackrest:
    image: pgbackrest/pgbackrest:latest
    container_name: pgbackrest-server
    hostname: pgbackrest
    networks:
      - postgres-replication_postgres-network
    volumes:
      - pgbackrest-data:/var/lib/pgbackrest
      - pgbackrest-config:/etc/pgbackrest
      - pgbackrest-log:/var/log/pgbackrest
      # Mount SSH keys for PostgreSQL access
      - ./pgbackrest/ssh:/home/pgbackrest/.ssh:ro
    environment:
      - PGBACKREST_STANZA=main
      - PGBACKREST_REPO1_PATH=/var/lib/pgbackrest
      - PGBACKREST_LOG_PATH=/var/log/pgbackrest
    restart: unless-stopped

volumes:
  pgbackrest-data:
    driver: local
  pgbackrest-config:
    driver: local
  pgbackrest-log:
    driver: local

networks:
  postgres-replication_postgres-network:
    external: true
```

### 1.2: Create pgBackRest Configuration

Create directory:
```bash
mkdir -p pgbackrest/config pgbackrest/ssh
```

Create `pgbackrest/config/pgbackrest.conf`:
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-diff=4
repo1-cipher-type=none

log-level-console=info
log-level-file=debug
start-fast=y
stop-auto=y

# Parallel processing (faster backups)
process-max=4

[main]
pg1-path=/var/lib/postgresql/data
pg1-port=5432
pg1-host=postgres-primary
pg1-host-user=postgres
pg1-database=postgres

# Archive settings
archive-async=y
archive-push-queue-max=1GB
```

### 1.3: Configure PostgreSQL for Archiving

Update primary PostgreSQL to use pgBackRest for archiving:

```bash
# Add to primary's postgresql.conf
docker exec postgres-primary bash -c "cat >> /var/lib/postgresql/data/postgresql.conf" << 'EOF'

# pgBackRest archiving
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
EOF

# Reload configuration
docker exec postgres-primary psql -U postgres -c "SELECT pg_reload_conf();"
```

### 1.4: Start pgBackRest Container

```bash
docker-compose -f docker-compose-backrest.yml up -d

# Verify it's running
docker ps --filter name=pgbackrest
```

---

## Step 2: Initialize pgBackRest Stanza

### 2.1: Create Stanza Configuration

```bash
# Initialize the stanza (repository structure)
docker exec pgbackrest-server pgbackrest --stanza=main --log-level-console=info stanza-create

# Verify stanza
docker exec pgbackrest-server pgbackrest --stanza=main info
```

**Expected output:**
```
stanza: main
    status: ok
    cipher: none

    db (current)
        wal archive min/max (15): 000000010000000000000001/000000010000000000000010
```

### 2.2: Check Archive Status

```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
  archived_count,
  last_archived_wal,
  last_archived_time,
  failed_count,
  last_failed_wal
FROM pg_stat_archiver;
"
```

---

## Step 3: Create Full Backup

### 3.1: Take First Full Backup

```bash
# Record start time
echo "=== BACKUP START: $(date '+%Y-%m-%d %H:%M:%S') ==="

# Execute full backup
docker exec pgbackrest-server pgbackrest --stanza=main \
  --type=full \
  --log-level-console=info \
  backup

echo "=== BACKUP COMPLETE: $(date '+%Y-%m-%d %H:%M:%S') ==="
```

**Expected output:**
```
INFO: backup command begin 2.48
INFO: execute non-exclusive backup start: backup begins after the next regular checkpoint completes
INFO: backup start archive = 000000010000000000000015, lsn = 0/15000028
INFO: full backup size = 45.2MB, file total = 1203
INFO: backup command end: completed in 23s
```

### 3.2: Verify Backup

```bash
# List all backups
docker exec pgbackrest-server pgbackrest --stanza=main info

# Detailed backup info
docker exec pgbackrest-server pgbackrest --stanza=main info --output=json | jq '.[]'
```

**Expected:**
```json
{
  "archive": [
    {
      "database": {
        "id": 1
      },
      "id": "15-1",
      "max": "000000010000000000000015",
      "min": "000000010000000000000001"
    }
  ],
  "backup": [
    {
      "archive": {
        "start": "000000010000000000000015",
        "stop": "000000010000000000000015"
      },
      "backrest": {
        "format": 5,
        "version": "2.48"
      },
      "database": {
        "id": 1
      },
      "info": {
        "size": 47382641,
        "delta": 47382641
      },
      "label": "20251119-110000F",
      "timestamp": {
        "start": 1700392800,
        "stop": 1700392823
      },
      "type": "full"
    }
  ],
  "name": "main",
  "status": {
    "code": 0,
    "message": "ok"
  }
}
```

---

## Step 4: Create Test Data Timeline

### 4.1: Record Baseline State

```bash
# Create test table if not exists
docker exec postgres-primary psql -U postgres << 'EOF'
CREATE TABLE IF NOT EXISTS critical_orders (
    id SERIAL PRIMARY KEY,
    order_number VARCHAR(50) UNIQUE NOT NULL,
    customer_email VARCHAR(100),
    amount NUMERIC(10,2),
    status VARCHAR(20),
    created_at TIMESTAMP DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_created ON critical_orders(created_at);

-- Insert baseline data
INSERT INTO critical_orders (order_number, customer_email, amount, status)
SELECT 
    'ORD-' || LPAD(i::text, 8, '0'),
    'customer' || i || '@example.com',
    (random() * 1000 + 50)::numeric(10,2),
    CASE 
        WHEN random() < 0.7 THEN 'completed'
        WHEN random() < 0.9 THEN 'pending'
        ELSE 'cancelled'
    END
FROM generate_series(1, 10000) i;

SELECT COUNT(*) as baseline_count FROM critical_orders;
EOF
```

### 4.2: Create Timeline with Checkpoints

```bash
# Checkpoint 1: Initial state
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📍 CHECKPOINT 1: INITIAL STATE"
CHECKPOINT_1=$(docker exec postgres-primary psql -U postgres -t -A -c "SELECT now();")
echo "Time: $CHECKPOINT_1"
docker exec postgres-primary psql -U postgres -c "
  SELECT COUNT(*) as total_orders, 
         COUNT(*) FILTER (WHERE status='completed') as completed_orders
  FROM critical_orders;
"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sleep 3

# Checkpoint 2: Add more orders
echo ""
echo "📍 CHECKPOINT 2: ADDING NEW ORDERS"
docker exec postgres-primary psql -U postgres << 'EOF'
INSERT INTO critical_orders (order_number, customer_email, amount, status)
SELECT 
    'ORD-' || LPAD((10000 + i)::text, 8, '0'),
    'newcustomer' || i || '@example.com',
    (random() * 2000 + 100)::numeric(10,2),
    'completed'
FROM generate_series(1, 500) i;

SELECT 'Added 500 new orders' as status;
SELECT COUNT(*) as total_orders FROM critical_orders;
EOF

CHECKPOINT_2=$(docker exec postgres-primary psql -U postgres -t -A -c "SELECT now();")
echo "Time: $CHECKPOINT_2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sleep 3

# Checkpoint 3: GOOD STATE - Record this for recovery!
echo ""
echo "🟢 CHECKPOINT 3: GOOD STATE (SAVE THIS TIME!)"
GOOD_STATE_TIME=$(docker exec postgres-primary psql -U postgres -t -A -c "SELECT now();")
echo "Time: $GOOD_STATE_TIME"

docker exec postgres-primary psql -U postgres -c "
  SELECT pg_create_restore_point('good_state_before_disaster');
  SELECT COUNT(*) as good_state_count FROM critical_orders;
"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Store for later use
echo $GOOD_STATE_TIME > /tmp/pitr_good_state_time.txt
echo "✅ Good state time saved to: /tmp/pitr_good_state_time.txt"

sleep 5

# Checkpoint 4: DISASTER STRIKES!
echo ""
echo "🔴 CHECKPOINT 4: DISASTER - ACCIDENTAL DELETE!"
DISASTER_TIME=$(docker exec postgres-primary psql -U postgres -t -A -c "SELECT now();")
echo "Time: $DISASTER_TIME"

docker exec postgres-primary psql -U postgres << 'EOF'
-- Simulate accidental deletion by junior developer
DELETE FROM critical_orders WHERE status = 'completed';

SELECT 'DISASTER: Deleted all completed orders!' as status;
SELECT COUNT(*) as remaining_orders FROM critical_orders;
EOF
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sleep 2

# Checkpoint 5: Discovery
echo ""
echo "⚠️  CHECKPOINT 5: DISASTER DISCOVERED"
DISCOVERY_TIME=$(docker exec postgres-primary psql -U postgres -t -A -c "SELECT now();")
echo "Time: $DISCOVERY_TIME"
docker exec postgres-primary psql -U postgres -c "
  SELECT 
    COUNT(*) as current_count,
    COUNT(*) FILTER (WHERE status='completed') as completed_count,
    COUNT(*) FILTER (WHERE status='pending') as pending_count
  FROM critical_orders;
"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "📊 TIMELINE SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checkpoint 1: $CHECKPOINT_1 (Baseline)"
echo "Checkpoint 2: $CHECKPOINT_2 (Added orders)"
echo "Checkpoint 3: $GOOD_STATE_TIME (🟢 GOOD STATE - RECOVERY TARGET)"
echo "Checkpoint 4: $DISASTER_TIME (🔴 DISASTER)"
echo "Checkpoint 5: $DISCOVERY_TIME (⚠️  DISCOVERED)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

---

## Step 5: Verify Current (Broken) State

```bash
echo "🔍 CURRENT DATABASE STATE (AFTER DISASTER)"
docker exec postgres-primary psql -U postgres -c "
SELECT 
  'Total orders: ' || COUNT(*) as metric
FROM critical_orders
UNION ALL
SELECT 'Completed: ' || COUNT(*) FROM critical_orders WHERE status='completed'
UNION ALL
SELECT 'Pending: ' || COUNT(*) FROM critical_orders WHERE status='pending'
UNION ALL
SELECT 'Cancelled: ' || COUNT(*) FROM critical_orders WHERE status='cancelled';
"
```

**Expected (broken state):**
```
         metric          
-------------------------
 Total orders: 3500
 Completed: 0           ← DISASTER: All completed orders deleted!
 Pending: 2800
 Cancelled: 700
```

---

## Step 6: Point-in-Time Recovery

### 6.1: Stop Primary Database

```bash
# Stop primary to prevent new writes during recovery
docker stop postgres-primary

# Stop standbys (optional, but cleaner)
docker stop postgres-standby postgres-standby2
```

### 6.2: Restore to Good State Time

```bash
# Load the good state time
GOOD_STATE_TIME=$(cat /tmp/pitr_good_state_time.txt)
echo "🎯 Recovering to: $GOOD_STATE_TIME"

# Restore with PITR
docker exec pgbackrest-server pgbackrest --stanza=main \
  --type=time \
  --target="$GOOD_STATE_TIME" \
  --target-action=promote \
  --delta \
  --log-level-console=info \
  restore
```

**What this does:**
- `--type=time`: Restore to specific timestamp
- `--target="$GOOD_STATE_TIME"`: The exact time before disaster
- `--target-action=promote`: Promote to standalone (not standby)
- `--delta`: Only restore changed files (faster)

**Expected output:**
```
INFO: restore command begin 2.48
INFO: restore backup set 20251119-110000F, recovery 20251119-113000 to time '2025-11-19 11:49:45'
INFO: write updated /var/lib/postgresql/data/postgresql.auto.conf
INFO: restore global/pg_control (performed last to ensure aborted restores cannot be started)
INFO: restore command end: completed in 12s
```

### 6.3: Start Primary with Recovery Configuration

```bash
# Start primary - it will perform PITR automatically
docker start postgres-primary

# Wait for recovery to complete (check logs)
docker logs -f postgres-primary
```

**Look for these log messages:**
```
LOG: starting point-in-time recovery to 2025-11-19 11:49:45+00
LOG: restored log file "000000010000000000000018" from archive
LOG: redo starts at 0/18000028
LOG: consistent recovery state reached at 0/180000F8
LOG: recovery stopping before commit of transaction 12345, time 2025-11-19 11:50:12
LOG: recovery has paused
LOG: selected new timeline ID: 2
LOG: archive recovery complete
LOG: database system is ready to accept connections
```

### 6.4: Verify Recovery Success

```bash
echo "🔍 RECOVERED DATABASE STATE"
docker exec postgres-primary psql -U postgres -c "
SELECT 
  'Total orders: ' || COUNT(*) as metric
FROM critical_orders
UNION ALL
SELECT 'Completed: ' || COUNT(*) FROM critical_orders WHERE status='completed'
UNION ALL
SELECT 'Pending: ' || COUNT(*) FROM critical_orders WHERE status='pending'
UNION ALL
SELECT 'Cancelled: ' || COUNT(*) FROM critical_orders WHERE status='cancelled';
"
```

**Expected (recovered state):**
```
         metric          
-------------------------
 Total orders: 10500     ← Restored!
 Completed: 7350         ← All completed orders back!
 Pending: 2450
 Cancelled: 700
```

**✅ SUCCESS!** Data recovered to state before disaster!

---

## Step 7: Measure Recovery Metrics

### 7.1: Calculate RTO (Recovery Time Objective)

```bash
# Recovery started
RECOVERY_START=$(date -d "$(docker logs postgres-primary 2>&1 | grep 'starting point-in-time recovery' | head -1 | awk '{print $1, $2}')" +%s)

# Recovery completed
RECOVERY_END=$(date -d "$(docker logs postgres-primary 2>&1 | grep 'database system is ready' | tail -1 | awk '{print $1, $2}')" +%s)

# Calculate RTO
RTO=$((RECOVERY_END - RECOVERY_START))
echo "⏱️  RTO (Recovery Time Objective): ${RTO} seconds"
```

### 7.2: Verify RPO (Recovery Point Objective)

```bash
# Check if we lost any data
docker exec postgres-primary psql -U postgres -c "
SELECT 
  COUNT(*) as recovered_orders,
  COUNT(*) FILTER (WHERE created_at <= '$GOOD_STATE_TIME') as should_exist,
  COUNT(*) FILTER (WHERE created_at > '$GOOD_STATE_TIME') as should_not_exist
FROM critical_orders;
"
```

**Expected:**
```
 recovered_orders | should_exist | should_not_exist 
------------------+--------------+------------------
            10500 |        10500 |                0
```

**RPO = 0 seconds** (no data loss - recovered to exact good state)

---

## Step 8: Rebuild Replication

### 8.1: Recreate Standbys from New Timeline

```bash
# Take new base backup from recovered primary
docker exec pgbackrest-server pgbackrest --stanza=main \
  --type=full \
  --log-level-console=info \
  backup

# Restore to standby1
docker exec pgbackrest-server pgbackrest --stanza=main \
  --delta \
  --target-timeline=current \
  --recovery-option="standby_mode=on" \
  --recovery-option="primary_conninfo=host=postgres-primary port=5432 user=replicator" \
  restore --pg1-path=/var/lib/postgresql/standby1/data

# Start standby1
docker start postgres-standby

# Repeat for standby2...
```

---

## 📊 Production Best Practices

### Backup Schedule (Production Recommendation)

```bash
# Full backup: Weekly (Sunday 2 AM)
0 2 * * 0 pgbackrest --stanza=main --type=full backup

# Differential backup: Daily (2 AM)
0 2 * * 1-6 pgbackrest --stanza=main --type=diff backup

# Incremental backup: Every 4 hours
0 */4 * * * pgbackrest --stanza=main --type=incr backup

# Retention policy: 2 full + 4 diff + 7 days incremental
```

### Backup Types Explained

| Type | Description | Use Case | Speed | Size |
|------|-------------|----------|-------|------|
| **Full** | Complete database copy | Base for all other backups | Slowest | Largest |
| **Differential** | Changes since last full | Daily backups | Medium | Medium |
| **Incremental** | Changes since last backup | Hourly backups | Fastest | Smallest |

### Recovery Scenarios

```bash
# 1. Recover to latest (most common)
pgbackrest --stanza=main restore

# 2. Recover to specific time (PITR)
pgbackrest --stanza=main --type=time --target="2025-11-19 11:49:45" restore

# 3. Recover to specific transaction ID
pgbackrest --stanza=main --type=xid --target="12345678" restore

# 4. Recover to named restore point
pgbackrest --stanza=main --type=name --target="before_migration" restore

# 5. Recover specific database only
pgbackrest --stanza=main --db-include=myapp restore
```

---

## 🎓 Interview Preparation

### Question 1: "Explain PITR and when you'd use it"

**Expert Answer:**
```
"PITR (Point-in-Time Recovery) allows restoring a database to any moment 
in time, not just backup snapshots. It requires:

1. BASE BACKUP - Full backup before the disaster
2. WAL ARCHIVES - All transaction logs from backup to target time
3. TARGET TIME - Exact timestamp of last known good state

USE CASES:
✅ Accidental data deletion: Dev runs 'DELETE FROM orders'
✅ Bad deployment: Application bug corrupts data
✅ Ransomware: Restore to before encryption
✅ Compliance: Recreate exact state for audit
✅ Testing: Restore to specific state for debugging

In production at my last company, we recovered from a mass DELETE that 
affected 2 million rows. Because we had PITR with pgBackRest:
- RTO: 12 minutes (restore + replay WAL)
- RPO: 0 seconds (zero data loss)
- Business impact: Minimal (under 15 minutes)

Without PITR, we'd have lost an entire day's transactions (last backup 
was 24 hours old)."
```

---

### Question 2: "Why pgBackRest over pg_basebackup?"

**Expert Answer:**
```
"pgBackRest is enterprise-grade, pg_basebackup is basic:

PGBACKREST ADVANTAGES:
1. PARALLEL OPERATIONS
   - Multi-threaded backup/restore (4-8x faster)
   - pg_basebackup is single-threaded

2. COMPRESSION & ENCRYPTION
   - Saves 60-70% storage costs
   - Encrypt at rest (compliance requirement)
   - pg_basebackup: no native compression

3. MULTIPLE BACKUP TYPES
   - Full + Differential + Incremental
   - Reduces backup windows from hours to minutes
   - pg_basebackup: full only

4. RETENTION POLICIES
   - Automatic cleanup: 'repo1-retention-full=2'
   - pg_basebackup: manual cleanup required

5. CLOUD STORAGE
   - Native S3/Azure/GCS support
   - Async archiving (doesn't block writes)
   - pg_basebackup: local only

6. VERIFICATION
   - Built-in backup validation
   - Checksum verification
   - pg_basebackup: manual verification

REAL NUMBERS (1TB database):
- pg_basebackup: 4 hours (full backup)
- pgBackRest (4 processes): 45 minutes
- pgBackRest (incremental): 8 minutes

In production, we migrated from pg_basebackup to pgBackRest:
- Backup window: 4 hours → 30 minutes
- Storage costs: $5000/month → $1800/month (compression)
- Recovery: 6 hours → 45 minutes (parallel restore)

AWS RDS and Azure PostgreSQL use pgBackRest-like architecture internally."
```

---

### Question 3: "Walk through a disaster recovery scenario"

**Expert Answer:**
```
"Real incident from production:

TIMELINE:
11:45 AM - Developer runs migration script with typo:
           DELETE FROM payments WHERE processed = true; (missing WHERE!)
           Result: 850,000 payment records deleted

11:47 AM - User reports: "My payment history is empty"
11:48 AM - Support escalates to engineering
11:49 AM - Engineering confirms: Mass deletion detected
11:50 AM - DBA paged (me): CRITICAL: Data loss incident

MY RESPONSE:

1. ASSESS DAMAGE (2 minutes):
   - Check pg_stat_activity: No active DELETE (already finished)
   - Check row counts: payments table 95% empty
   - Check logs: Found DELETE at 11:45:23

2. IDENTIFY RECOVERY TARGET (1 minute):
   - Last known good state: 11:45:00 (before DELETE)
   - Verify backup exists: Full backup from 2 AM
   - Verify WAL archives: Continuous from 2 AM to now
   - RTO estimate: 15 minutes

3. COMMUNICATE (1 minute):
   - Notify stakeholders: "Recovery in progress, 15 min ETA"
   - Stop application writes: Prevent new transactions
   - Document incident: Timestamp, query, impact

4. EXECUTE RECOVERY (12 minutes):
   # Stop database
   systemctl stop postgresql
   
   # Restore with PITR
   pgbackrest --stanza=prod --type=time \
     --target="2025-03-15 11:45:00" \
     --delta restore
   
   # Start database (automatic WAL replay)
   systemctl start postgresql
   
   # Monitor recovery
   tail -f /var/log/postgresql/postgresql.log

5. VERIFY (2 minutes):
   - Check row counts: 850,000 payments restored
   - Verify data integrity: Sample payment IDs match backup
   - Test application: Payment history displays correctly

6. POST-RECOVERY (5 minutes):
   - Rebuild standbys from new timeline
   - Resume application writes
   - Notify stakeholders: Recovery complete
   - Post-mortem: Add WHERE clause validation to migration tool

FINAL METRICS:
- Detection time: 4 minutes
- Recovery time: 12 minutes
- Total downtime: 18 minutes
- Data loss: 0 transactions (PITR to exact second before DELETE)
- Business impact: Minimal (payment processing paused 18 min)

ROOT CAUSE: Migration tool allowed DELETE without WHERE confirmation
PREVENTION: Added double-confirmation for DELETE operations
DOCUMENTATION: Updated runbook with this scenario

KEY LEARNING: Having PITR ready saved us. Without it, we'd have lost
an entire day's transactions (850K payments + 9 hours of new payments)."
```

---

### Question 4: "How do you size pgBackRest infrastructure?"

**Expert Answer:**
```
"Backup infrastructure sizing requires analyzing:

1. DATABASE SIZE
   - Current: 500 GB
   - Growth rate: 50 GB/month
   - 12-month projection: 1.1 TB

2. CHANGE RATE
   - Daily change: ~5% (25 GB/day)
   - Weekly change: ~20% (100 GB/week)
   - This determines incremental/diff backup sizes

3. RETENTION REQUIREMENTS
   - Full backups: 2 (weekly)
   - Differential: 4 (daily for a week)
   - Incremental: 7 days
   - Total storage = (2 full) + (4 diff × 20%) + (7 incr × 5%)
                   = (2 × 500GB) + (4 × 100GB) + (7 × 25GB)
                   = 1000 + 400 + 175 = 1575 GB

4. COMPRESSION
   - PostgreSQL compresses ~60% (typical)
   - Actual storage: 1575 × 0.4 = 630 GB

5. SAFETY MARGIN
   - Add 30% for WAL archives, temp space, growth
   - Final: 630 × 1.3 = 820 GB

6. INFRASTRUCTURE SPECS:
   BACKUP SERVER:
   - Storage: 1 TB SSD (820 GB + growth room)
   - CPU: 8 cores (4 parallel processes × 2 for overhead)
   - RAM: 16 GB (2 GB per process + OS)
   - Network: 10 Gbps (minimize backup window)

   NETWORK BANDWIDTH:
   - Full backup: 500 GB × 0.4 (compressed) = 200 GB
   - At 10 Gbps: 200 GB / 1.25 GB/s = 160 seconds = 2.7 minutes
   - At 1 Gbps: 200 GB / 125 MB/s = 1600 seconds = 27 minutes

7. CLOUD STORAGE (ALTERNATIVE):
   - S3 Standard: 820 GB × $0.023/GB = $19/month
   - Data transfer: ~200 GB/week × $0.09/GB = $18/month
   - Total: $37/month vs $200/month (server)
   
   Decision: Use cloud for disaster recovery, local for fast restore

ACTUAL IMPLEMENTATION:
- Primary backup: Local NAS (1 TB SSD) - 3 min restore
- Secondary backup: S3 (for DR) - 15 min restore
- Tertiary: Offsite (tape) - 24 hour restore (compliance)

MONITORING:
- Alert if backup > 30 minutes
- Alert if storage > 80%
- Alert if compression ratio drops (indicates problem)
- Weekly backup test: Restore to test server

This sizing supported 99.95% uptime with < 15 minute RTO."
```

---

## 🧹 Cleanup

```bash
# Stop pgBackRest
docker-compose -f docker-compose-backrest.yml down

# Clean up test data (optional)
docker exec postgres-primary psql -U postgres -c "DROP TABLE IF EXISTS critical_orders;"

# Remove volumes (if starting fresh)
docker volume rm pgbackrest-data pgbackrest-config pgbackrest-log
```

---

## 📝 Scenario Summary

### Completed Objectives:
✅ Set up pgBackRest backup infrastructure  
✅ Created full backup with WAL archiving  
✅ Simulated disaster (accidental mass DELETE)  
✅ Performed Point-in-Time Recovery to exact timestamp  
✅ Verified 100% data recovery (0 data loss)  
✅ Measured RTO (< 15 minutes) and RPO (0 seconds)  
✅ Rebuilt replication after recovery  

### Key Takeaways:
- **pgBackRest is production-grade** - Faster, more features than pg_basebackup
- **PITR saves businesses** - Recover to exact second before disaster
- **Backup strategy matters** - Full + Differential + Incremental balance speed and coverage
- **Test your backups** - Untested backups are not backups
- **Automation is critical** - Manual backups are forgotten backups

### Interview Confidence:
🎯 **You can now discuss:**
- Enterprise backup strategies
- Disaster recovery procedures
- PITR concepts and execution
- RTO/RPO calculations
- Production incident response

---

**Next:** Document your execution in `scenarios/logs/scenario-12-execution.md`!
