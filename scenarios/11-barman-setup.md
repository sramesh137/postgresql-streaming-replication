# Scenario 11: Barman Setup and Testing

**Difficulty:** Advanced  
**Duration:** 45-60 minutes  
**Prerequisites:** Scenarios 01-08 completed

---

## 🎯 Learning Objectives

- Set up Barman backup server with Docker
- Configure WAL archiving
- Perform full and incremental backups
- Test backup integrity
- Practice restoration procedures

---

## 📋 Architecture

```
┌─────────────────────┐       SSH/rsync        ┌──────────────────────┐
│  Barman Server      │ ◄──────────────────── │  PostgreSQL Primary  │
│  (Backup Manager)   │                        │  (Production DB)     │
│                     │                        │                      │
│  /var/lib/barman/   │                        │  WAL Archiving: ON   │
│    ├── pg-primary/  │                        │  archive_command     │
│    │   ├── base/    │                        │  replication slot    │
│    │   └── wals/    │                        │                      │
└─────────────────────┘                        └──────────────────────┘
```

---

## Step 1: Add Barman Server to Docker Compose

### Update docker-compose.yml

Add this service to your existing `docker-compose.yml`:

```yaml
  barman:
    image: postgres:15
    container_name: barman-server
    hostname: barman-server
    environment:
      POSTGRES_PASSWORD: not_used
    volumes:
      - barman-data:/var/lib/barman
      - barman-config:/etc/barman
      - barman-home:/home/barman
    command: |
      bash -c "
        apt-get update && 
        apt-get install -y barman postgresql-client-15 rsync openssh-client &&
        
        # Create barman user
        useradd -m -s /bin/bash barman || true &&
        echo 'barman:barman' | chpasswd &&
        
        # Create directories
        mkdir -p /var/lib/barman /var/log/barman /etc/barman/barman.d &&
        chown -R barman:barman /var/lib/barman /var/log/barman /etc/barman &&
        
        # Keep container running
        tail -f /dev/null
      "
    networks:
      - default
    healthcheck:
      test: ["CMD", "test", "-f", "/usr/bin/barman"]
      interval: 10s
      timeout: 5s
      retries: 3

volumes:
  barman-data:
  barman-config:
  barman-home:
```

### Start Barman Container

```bash
docker-compose up -d barman
```

---

## Step 2: Configure SSH Access

### Generate SSH Keys

```bash
# Generate SSH key for barman user
docker exec -u barman barman-server bash -c "
  ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa
"

# Show public key
docker exec -u barman barman-server cat /home/barman/.ssh/id_rsa.pub
```

### Add Barman's Public Key to PostgreSQL Primary

```bash
# Copy the public key
BARMAN_PUB_KEY=$(docker exec -u barman barman-server cat /home/barman/.ssh/id_rsa.pub)

# Add to postgres user on primary
docker exec postgres-primary bash -c "
  mkdir -p /var/lib/postgresql/.ssh
  echo '$BARMAN_PUB_KEY' >> /var/lib/postgresql/.ssh/authorized_keys
  chown -R postgres:postgres /var/lib/postgresql/.ssh
  chmod 700 /var/lib/postgresql/.ssh
  chmod 600 /var/lib/postgresql/.ssh/authorized_keys
"
```

### Generate SSH Key for PostgreSQL Primary

```bash
# Generate SSH key for postgres user on primary
docker exec postgres-primary bash -c "
  sudo -u postgres ssh-keygen -t rsa -b 4096 -N '' -f /var/lib/postgresql/.ssh/id_rsa
"

# Show public key
docker exec postgres-primary cat /var/lib/postgresql/.ssh/id_rsa.pub
```

### Add Primary's Public Key to Barman

```bash
# Copy the public key
PRIMARY_PUB_KEY=$(docker exec postgres-primary cat /var/lib/postgresql/.ssh/id_rsa.pub)

# Add to barman user
docker exec barman-server bash -c "
  mkdir -p /home/barman/.ssh
  echo '$PRIMARY_PUB_KEY' >> /home/barman/.ssh/authorized_keys
  chown -R barman:barman /home/barman/.ssh
  chmod 700 /home/barman/.ssh
  chmod 600 /home/barman/.ssh/authorized_keys
"
```

### Test SSH Connections

```bash
# Test barman → primary
docker exec -u barman barman-server ssh -o StrictHostKeyChecking=no postgres@postgres-primary "echo 'SSH from barman to primary works!'"

# Test primary → barman
docker exec postgres-primary sudo -u postgres ssh -o StrictHostKeyChecking=no barman@barman-server "echo 'SSH from primary to barman works!'"
```

---

## Step 3: Configure Barman

### Create Barman Global Configuration

```bash
docker exec barman-server bash -c "cat > /etc/barman.conf << 'EOF'
[barman]
barman_home = /var/lib/barman
barman_user = barman
log_file = /var/log/barman/barman.log
log_level = INFO
compression = gzip
retention_policy = RECOVERY WINDOW OF 7 DAYS
minimum_redundancy = 1
last_backup_maximum_age = 1 DAY
EOF"
```

### Create PostgreSQL Server Configuration

```bash
docker exec barman-server bash -c "cat > /etc/barman/barman.d/pg-primary.conf << 'EOF'
[pg-primary]
description = 'PostgreSQL Primary Server'
conninfo = host=postgres-primary user=barman dbname=postgres
backup_method = postgres
streaming_conninfo = host=postgres-primary user=streaming_barman dbname=postgres
streaming_archiver = on
slot_name = barman
path_prefix = /usr/lib/postgresql/15/bin
retention_policy = RECOVERY WINDOW OF 7 DAYS
minimum_redundancy = 1
EOF"

# Set ownership
chown -R barman:barman /etc/barman
```

---

## Step 4: Configure PostgreSQL for Barman

### Create Barman Users

```bash
docker exec postgres-primary psql -U postgres << 'EOF'
-- Create users
CREATE USER barman WITH SUPERUSER PASSWORD 'barman_password';
CREATE USER streaming_barman WITH REPLICATION PASSWORD 'streaming_password';

-- Grant permissions for non-superuser backup (optional)
-- GRANT EXECUTE ON FUNCTION pg_start_backup(text, boolean, boolean) TO barman;
-- GRANT EXECUTE ON FUNCTION pg_stop_backup() TO barman;
-- GRANT EXECUTE ON FUNCTION pg_switch_wal() TO barman;

-- For monitoring
GRANT pg_read_all_settings TO barman;
GRANT pg_read_all_stats TO barman;

-- Show users
\du barman
\du streaming_barman
EOF
```

### Configure pg_hba.conf

```bash
docker exec postgres-primary bash -c "
  echo 'host postgres barman 0.0.0.0/0 scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf
  echo 'host replication streaming_barman 0.0.0.0/0 scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf
"

# Reload PostgreSQL
docker exec postgres-primary psql -U postgres -c "SELECT pg_reload_conf();"
```

### Create .pgpass for Password-less Access

```bash
# On Barman server
docker exec -u barman barman-server bash -c "
  cat > ~/.pgpass << 'EOF'
postgres-primary:5432:postgres:barman:barman_password
postgres-primary:5432:postgres:streaming_barman:streaming_password
postgres-primary:5432:replication:streaming_barman:streaming_password
EOF
  chmod 600 ~/.pgpass
"
```

---

## Step 5: Verify Barman Configuration

### Run Barman Check

```bash
docker exec -u barman barman-server barman check pg-primary
```

**Expected output (some items may fail initially):**
```
Server pg-primary:
  PostgreSQL: OK
  superuser or standard user with backup privileges: OK
  PostgreSQL streaming: OK
  wal_level: OK
  replication slot: FAILED (slot 'barman' does not exist)
  directories: OK
  retention policy settings: OK
  backup maximum age: OK (no last_backup_maximum_age provided)
  compression settings: OK
  failed backups: OK (there are 0 failed backups)
  minimum redundancy requirements: FAILED (have 0 backups, expected at least 1)
  pg_basebackup: OK
  systemid coherence: OK (no system Id stored on disk)
  archive_mode: OK
  archive_command: OK
  continuous archiving: OK
  archiver errors: OK
```

---

## Step 6: Create Replication Slot

```bash
# Create replication slot for WAL streaming
docker exec -u barman barman-server barman receive-wal --create-slot pg-primary
```

**Output:**
```
Creating physical replication slot 'barman' on server 'pg-primary'
Replication slot 'barman' created
```

### Verify Replication Slot

```bash
docker exec postgres-primary psql -U postgres -c "SELECT * FROM pg_replication_slots;"
```

**Expected:**
```
 slot_name | plugin | slot_type | ... | active 
-----------+--------+-----------+-----+--------
 barman    |        | physical  | ... | f
```

---

## Step 7: Start WAL Streaming

```bash
# Start WAL receiver in background
docker exec -u barman -d barman-server barman receive-wal pg-primary
```

### Verify WAL Streaming

```bash
# Check receive-wal process
docker exec barman-server ps aux | grep "receive-wal"

# Check replication slot is active
docker exec postgres-primary psql -U postgres -c "SELECT slot_name, active FROM pg_replication_slots;"
```

**Expected:**
```
 slot_name | active 
-----------+--------
 barman    | t       ← Active!
```

---

## Step 8: Perform First Backup

```bash
# Take a full backup
docker exec -u barman barman-server barman backup pg-primary
```

**Output:**
```
Starting backup using postgres method for server pg-primary in /var/lib/barman/pg-primary/base/20251117T160000
Backup start at LSN: 0/14000028 (000000010000000000000014, 00000028)
Starting backup copy via pg_basebackup for 20251117T160000
Copy done (time: 15 seconds)
Finalising the backup.
Backup size: 45.2 MiB
Backup end at LSN: 0/14000160 (000000010000000000000014, 00000160)
Backup completed (start time: 2025-11-17 16:00:00.123456, elapsed time: 15 seconds)
```

---

## Step 9: List and Inspect Backups

### List All Backups

```bash
docker exec -u barman barman-server barman list-backup pg-primary
```

**Output:**
```
pg-primary 20251117T160000 - Sun Nov 17 16:00:00 2025 - Size: 45.2 MiB - WAL Size: 16.0 MiB
```

### Show Backup Details

```bash
docker exec -u barman barman-server barman show-backup pg-primary latest
```

**Output:**
```
Backup 20251117T160000:
  Server Name            : pg-primary
  System Id              : 7302509887943450845
  Status                 : DONE
  PostgreSQL Version     : 150003
  PGDATA directory       : /var/lib/postgresql/data
  Base backup information:
    Disk usage           : 45.2 MiB
    Timeline             : 1
    Begin WAL            : 000000010000000000000014
    End WAL              : 000000010000000000000014
    Begin time           : 2025-11-17 16:00:00.123456+00:00
    End time             : 2025-11-17 16:00:15.789012+00:00
    Begin LSN            : 0/14000028
    End LSN              : 0/14000160
  WAL information:
    No of files          : 1
    Disk usage           : 16.0 MiB
```

---

## Step 10: Test Backup Integrity

### Insert Test Data

```bash
# Insert some data
docker exec postgres-primary psql -U postgres << 'EOF'
CREATE TABLE IF NOT EXISTS backup_test (
    id serial PRIMARY KEY,
    backup_time timestamp DEFAULT now(),
    data text
);

INSERT INTO backup_test (data) 
SELECT 'Before backup test ' || i 
FROM generate_series(1, 1000) i;

SELECT COUNT(*) FROM backup_test;
EOF
```

### Force WAL Switch

```bash
# Force PostgreSQL to archive current WAL
docker exec postgres-primary psql -U postgres -c "SELECT pg_switch_wal();"
```

### Wait for WAL Archiving

```bash
# Check WAL files received
docker exec -u barman barman-server ls -lh /var/lib/barman/pg-primary/streaming/
```

---

## Step 11: Take Second Backup

```bash
# Take another backup
docker exec -u barman barman-server barman backup pg-primary

# List backups
docker exec -u barman barman-server barman list-backup pg-primary
```

**Expected:**
```
pg-primary 20251117T161500 - Sun Nov 17 16:15:00 2025 - Size: 46.8 MiB - WAL Size: 32.0 MiB
pg-primary 20251117T160000 - Sun Nov 17 16:00:00 2025 - Size: 45.2 MiB - WAL Size: 16.0 MiB
```

---

## Step 12: Test Simple Restoration

### Prepare Recovery Directory

```bash
# Create recovery directory on Barman server
docker exec barman-server mkdir -p /tmp/recovery-test
docker exec barman-server chown barman:barman /tmp/recovery-test
```

### Perform Recovery

```bash
# Recover latest backup
docker exec -u barman barman-server barman recover pg-primary latest /tmp/recovery-test
```

**Output:**
```
Starting remote restore for server pg-primary using backup 20251117T161500
Destination directory: /tmp/recovery-test
Copying the base backup.
Copying required WAL segments.
Generating recovery configuration
Restore completed (start time: 2025-11-17 16:20:00, elapsed time: 5 seconds)

Your PostgreSQL server has been successfully prepared for recovery!
```

### Inspect Recovery Files

```bash
# Check recovery files created
docker exec barman-server ls -lh /tmp/recovery-test/

# Check recovery configuration
docker exec barman-server cat /tmp/recovery-test/postgresql.auto.conf | grep restore
```

---

## Step 13: Verify Barman Status

```bash
# Overall status
docker exec -u barman barman-server barman status pg-primary

# Run full check
docker exec -u barman barman-server barman check pg-primary
```

**All checks should be OK now:**
```
Server pg-primary:
  PostgreSQL: OK
  superuser or standard user with backup privileges: OK
  PostgreSQL streaming: OK
  wal_level: OK
  replication slot: OK
  directories: OK
  retention policy settings: OK
  backup maximum age: OK (interval provided: 1 day, latest backup age: 5 minutes)
  compression settings: OK
  failed backups: OK (there are 0 failed backups)
  minimum redundancy requirements: OK (have 2 backups, expected at least 1)
  pg_basebackup: OK
  systemid coherence: OK
  archive_mode: OK
  archive_command: OK
  continuous archiving: OK
  archiver errors: OK
```

---

## 📊 Key Findings

### Backup Timing

| Operation | Duration |
|-----------|----------|
| First full backup | ~15 seconds |
| Second full backup | ~15 seconds |
| Recovery | ~5 seconds |

**Note:** Times are fast because database is small (~45 MB)

### Storage Usage

```bash
# Check Barman storage
docker exec barman-server du -sh /var/lib/barman/pg-primary/*
```

**Expected:**
```
48M     /var/lib/barman/pg-primary/base
32M     /var/lib/barman/pg-primary/streaming
Total:  ~80M for 2 backups + WALs
```

### Replication Slots

```bash
docker exec postgres-primary psql -U postgres -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

**Expected:**
```
 slot_name | active |  restart_lsn  
-----------+--------+---------------
 barman    | t      | 0/15000000     ← Active and advancing
```

---

## 🎓 Key Lessons

### 1. SSH Configuration is Critical
- Both directions: barman→primary AND primary→barman
- Use `.pgpass` for PostgreSQL authentication
- Test SSH before proceeding with Barman

### 2. Replication Slot Required
- Creates dedicated WAL stream for Barman
- Prevents WAL deletion before archiving
- Monitor slot activity

### 3. Backup Methods
- **postgres method:** Uses pg_basebackup, simpler
- **rsync method:** Incremental backups, faster for large DBs

### 4. WAL Streaming vs Archive Command
- **Streaming:** Lower latency, better for PITR
- **Archive command:** Fallback, higher latency

### 5. Testing is Essential
- Always test recovery after backup
- Verify backup integrity
- Measure RTO (Recovery Time Objective)

---

## 🔗 Next Steps

**✅ Completed:**
- Barman server setup with Docker
- SSH key exchange
- PostgreSQL user creation
- Replication slot configuration
- WAL streaming
- Full backup creation
- Backup verification
- Basic recovery test

**➡️ Next:**
- [Scenario 12: Point-in-Time Recovery](./12-pitr-recovery.md)
- [Scenario 13: Disaster Recovery Drill](./13-disaster-recovery.md)

---

## 📝 Commands Reference

### Barman Management

```bash
# Check configuration
barman check pg-primary

# List servers
barman list-server

# Server status
barman status pg-primary

# Backup operations
barman backup pg-primary
barman list-backup pg-primary
barman show-backup pg-primary <backup-id>
barman delete pg-primary <backup-id>

# Recovery
barman recover pg-primary <backup-id> /path/to/recovery

# WAL management
barman receive-wal --create-slot pg-primary
barman receive-wal pg-primary
barman cron  # Maintenance operations

# Diagnostics
barman diagnose
```

### PostgreSQL Operations

```bash
# Force WAL switch
SELECT pg_switch_wal();

# Check replication slots
SELECT * FROM pg_replication_slots;

# Drop replication slot
SELECT pg_drop_replication_slot('barman');
```

---

**Status:** ✅ Scenario 11 Complete!
