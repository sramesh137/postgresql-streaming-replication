# Barman - Backup and Recovery Manager for PostgreSQL

**Complete Guide for Interview Preparation**

---

## 📚 Table of Contents

1. [What is Barman?](#what-is-barman)
2. [Why Barman vs pg_basebackup?](#why-barman-vs-pg_basebackup)
3. [Architecture and Components](#architecture-and-components)
4. [Installation and Setup](#installation-and-setup)
5. [Configuration](#configuration)
6. [Backup Operations](#backup-operations)
7. [WAL Archiving](#wal-archiving)
8. [Point-in-Time Recovery (PITR)](#point-in-time-recovery-pitr)
9. [Incremental Backups](#incremental-backups)
10. [Monitoring and Maintenance](#monitoring-and-maintenance)
11. [Interview Questions](#interview-questions)
12. [Hands-on Scenarios](#hands-on-scenarios)

---

## 🎯 What is Barman?

**Barman** (Backup and Recovery Manager) is an **enterprise-grade disaster recovery solution** for PostgreSQL developed by EnterpriseDB (2ndQuadrant).

### Key Features:
- ✅ **Automated backups** - Scheduled full and incremental backups
- ✅ **WAL archiving** - Continuous archiving of transaction logs
- ✅ **Point-in-Time Recovery (PITR)** - Restore to any point in time
- ✅ **Multiple backup methods** - rsync, pg_basebackup, snapshot
- ✅ **Compression** - Built-in backup compression
- ✅ **Retention policies** - Automatic cleanup of old backups
- ✅ **Remote backups** - Backup over SSH to dedicated backup server
- ✅ **Backup validation** - Verify backup integrity
- ✅ **Monitoring** - Health checks and status reporting

### Use Cases:
- Production database backup strategy
- Disaster recovery planning
- Point-in-time recovery (undo bad transactions)
- Database cloning for testing/development
- Compliance (data retention policies)

---

## 🆚 Why Barman vs pg_basebackup?

| Feature | **Barman** | **pg_basebackup** |
|---------|-----------|------------------|
| **Automation** | ✅ Cron-based scheduling | ❌ Manual scripting required |
| **WAL Archiving** | ✅ Built-in continuous archiving | ❌ Manual configuration |
| **Incremental Backups** | ✅ Yes (rsync method) | ❌ No (always full) |
| **Retention Policies** | ✅ Automatic cleanup | ❌ Manual cleanup scripts |
| **PITR** | ✅ Simple commands | ⚠️ Manual WAL replay |
| **Backup Catalog** | ✅ Comprehensive metadata | ❌ No catalog |
| **Compression** | ✅ Built-in | ⚠️ Manual gzip |
| **Monitoring** | ✅ barman check, list-backup | ❌ None |
| **Remote Backups** | ✅ SSH-based pull model | ⚠️ Push from primary |
| **Complexity** | Medium | Low |
| **Production-Ready** | ✅ Yes | ⚠️ For simple setups |

### When to Use What?

**Use Barman when:**
- Production environments with strict RTO/RPO requirements
- Need automated backup scheduling
- Require PITR capabilities
- Multiple PostgreSQL servers to manage
- Need backup validation and monitoring
- Enterprise compliance requirements

**Use pg_basebackup when:**
- Simple dev/test environments
- One-time backups
- Setting up replication (initial standby creation)
- No budget for dedicated backup infrastructure

---

## 🏗️ Architecture and Components

### Typical Setup:

```
┌─────────────────────────────────────────────────────────┐
│                    BARMAN SERVER                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Barman (Backup Manager)                         │  │
│  │  - Backup catalog                                │  │
│  │  - Configuration                                 │  │
│  │  - Cron jobs                                     │  │
│  └──────────────────────────────────────────────────┘  │
│                          ↓                              │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Backup Storage                                  │  │
│  │  /var/lib/barman/                                │  │
│  │    ├── server1/                                  │  │
│  │    │   ├── base/          (Full backups)         │  │
│  │    │   ├── wals/          (WAL archives)         │  │
│  │    │   └── streaming/     (Replication slot)     │  │
│  │    └── server2/                                  │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                          ↑
                    SSH Connection
                          ↑
┌─────────────────────────────────────────────────────────┐
│              POSTGRESQL PRIMARY SERVER                  │
│  ┌──────────────────────────────────────────────────┐  │
│  │  PostgreSQL 15                                   │  │
│  │  - WAL archiving enabled                         │  │
│  │  - archive_command → Barman                      │  │
│  │  - Physical replication slot                     │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### Components:

**1. Barman Server:**
- Dedicated machine for backup storage
- Runs Barman software
- Connects to PostgreSQL via SSH
- Stores backups and WAL archives

**2. PostgreSQL Server (Primary):**
- Database server being backed up
- Configured with WAL archiving
- Allows replication connections for streaming

**3. Backup Methods:**

**a) rsync (Recommended for large databases):**
- Incremental backups (only changed blocks)
- Faster subsequent backups
- Lower network usage

**b) pg_basebackup (Streaming):**
- Full backup every time
- Works over replication protocol
- No SSH required
- Better for smaller databases

**c) Snapshot (Advanced):**
- LVM/ZFS snapshots
- Instant backups
- Requires storage-level support

---

## 🛠️ Installation and Setup

### On Barman Server (Backup Server):

**Option 1: Using Package Manager (Recommended)**
```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-get install barman

# RHEL/CentOS/Rocky
sudo yum install epel-release
sudo yum install barman

# macOS (for testing)
brew install barman
```

**Option 2: Using Docker**
```yaml
# docker-compose.yml
version: '3.8'

services:
  barman:
    image: postgres:15
    container_name: barman-server
    environment:
      POSTGRES_PASSWORD: barman_password
    volumes:
      - barman-data:/var/lib/barman
      - ./barman-config:/etc/barman.d
    command: |
      bash -c "
        apt-get update && 
        apt-get install -y barman postgresql-client-15 &&
        useradd -m barman &&
        mkdir -p /var/lib/barman /var/log/barman &&
        chown -R barman:barman /var/lib/barman /var/log/barman &&
        tail -f /dev/null
      "
    networks:
      - pg-network

volumes:
  barman-data:

networks:
  pg-network:
    name: postgresql-streaming-replication_default
    external: true
```

**Option 3: Python pip (For testing)**
```bash
pip install barman
# Requires PostgreSQL client tools installed
```

---

## ⚙️ Configuration

### 1. Barman Global Configuration

**File:** `/etc/barman.conf`

```ini
[barman]
# Main directory for Barman
barman_home = /var/lib/barman

# Log file location
log_file = /var/log/barman/barman.log

# Log level (DEBUG, INFO, WARNING, ERROR, CRITICAL)
log_level = INFO

# System user running Barman
barman_user = barman

# Lock directory
barman_lock_directory = /var/run/barman

# Compression
compression = gzip

# Retention policy (keep 7 days of backups)
retention_policy = RECOVERY WINDOW OF 7 DAYS

# Backup method
backup_method = rsync

# Minimum number of required backups
minimum_redundancy = 1

# Reuse backup (incremental with rsync)
reuse_backup = link

# Parallel workers for backup/recovery
parallel_jobs = 2
```

### 2. PostgreSQL Server Configuration

**File:** `/etc/barman.d/pg-primary.conf`

```ini
[pg-primary]
# Description
description = "PostgreSQL Primary Server"

# SSH connection to PostgreSQL server
ssh_command = ssh postgres@postgres-primary

# PostgreSQL connection string
conninfo = host=postgres-primary user=barman dbname=postgres port=5432

# Backup method (rsync or postgres)
backup_method = rsync

# Backup directory (on PostgreSQL server)
backup_directory = /var/lib/barman/pg-primary

# WAL archiving
archiver = on

# Archive command on PostgreSQL server
# (configured in postgresql.conf)
# archive_command = 'rsync -a %p barman@barman-server:/var/lib/barman/pg-primary/wals/%f'

# Streaming replication (for WAL streaming)
streaming_archiver = on
slot_name = barman
streaming_conninfo = host=postgres-primary user=streaming_barman dbname=postgres

# Retention policy (override global)
retention_policy = RECOVERY WINDOW OF 14 DAYS

# Minimum number of backups
minimum_redundancy = 2

# Bandwidth limit (MB/s) - optional
# bandwidth_limit = 10

# Parallel jobs
parallel_jobs = 4

# Path to pg_basebackup (if using postgres method)
path_prefix = /usr/lib/postgresql/15/bin
```

### 3. PostgreSQL Server Configuration (postgresql.conf)

```bash
# On PostgreSQL Primary Server
docker exec postgres-primary psql -U postgres << 'EOF'
-- Enable WAL archiving
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = 'rsync -a %p barman@barman-server:/var/lib/barman/pg-primary/wals/%f';
ALTER SYSTEM SET archive_timeout = '60s';  -- Force WAL switch every 60s

-- Replication settings (for streaming)
ALTER SYSTEM SET max_wal_senders = '10';
ALTER SYSTEM SET max_replication_slots = '10';

-- Reload configuration
SELECT pg_reload_conf();
EOF
```

**Restart PostgreSQL:**
```bash
docker-compose restart postgres-primary
```

### 4. Create Barman User on PostgreSQL

```sql
-- On PostgreSQL Primary
CREATE USER barman WITH REPLICATION PASSWORD 'barman_password';
CREATE USER streaming_barman WITH REPLICATION PASSWORD 'streaming_password';

-- Grant permissions
GRANT EXECUTE ON FUNCTION pg_start_backup(text, boolean, boolean) TO barman;
GRANT EXECUTE ON FUNCTION pg_stop_backup() TO barman;
GRANT EXECUTE ON FUNCTION pg_stop_backup(boolean, boolean) TO barman;
GRANT EXECUTE ON FUNCTION pg_switch_wal() TO barman;
GRANT EXECUTE ON FUNCTION pg_create_restore_point(text) TO barman;

-- For monitoring
GRANT pg_read_all_settings TO barman;
GRANT pg_read_all_stats TO barman;
```

### 5. Configure pg_hba.conf

```bash
# On PostgreSQL Primary
# Add to pg_hba.conf:
host    postgres        barman          barman-server/32    scram-sha-256
host    replication     streaming_barman barman-server/32    scram-sha-256
```

### 6. SSH Key Setup

```bash
# On Barman server
sudo su - barman
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Copy public key to PostgreSQL server
ssh-copy-id postgres@postgres-primary

# Test connection
ssh postgres@postgres-primary "psql -U postgres -c 'SELECT version();'"
```

---

## 💾 Backup Operations

### Check Configuration

```bash
# Check Barman can connect to PostgreSQL
barman check pg-primary
```

**Expected output:**
```
Server pg-primary:
  PostgreSQL: OK
  superuser or standard user with backup privileges: OK
  PostgreSQL streaming: OK
  wal_level: OK
  replication slot: OK
  directories: OK
  retention policy settings: OK
  backup maximum age: OK (no last_backup_maximum_age provided)
  compression settings: OK
  failed backups: OK (there are 0 failed backups)
  minimum redundancy requirements: OK (have 0 backups, expected at least 1)
  pg_basebackup: OK
  pg_basebackup compatible: OK
  pg_basebackup supports tablespaces mapping: OK
  systemid coherence: OK
  pg_receivexlog: OK
  pg_receivexlog compatible: OK
  receive-wal running: OK
  archiver errors: OK
```

### Create Replication Slot

```bash
# Create replication slot for WAL streaming
barman receive-wal --create-slot pg-primary
```

### Start WAL Streaming

```bash
# Start continuous WAL archiving
barman receive-wal pg-primary &
```

### Perform Full Backup

```bash
# Take a full backup
barman backup pg-primary
```

**Output:**
```
Starting backup using postgres method for server pg-primary in /var/lib/barman/pg-primary/base/20251117T153000
Backup start at LSN: 0/6000028 (000000010000000000000006, 00000028)
Starting backup copy via pg_basebackup for 20251117T153000
Copy done (time: 1 minute, 23 seconds)
Finalising the backup.
Backup size: 1.2 GiB
Backup end at LSN: 0/6000160 (000000010000000000000006, 00000160)
Backup completed (start time: 2025-11-17 15:30:00.123456, elapsed time: 1 minute, 23 seconds)
```

### List Backups

```bash
barman list-backup pg-primary
```

**Output:**
```
pg-primary 20251117T153000 - Sun Nov 17 15:30:00 2025 - Size: 1.2 GiB - WAL Size: 48 MiB
pg-primary 20251116T020000 - Sat Nov 16 02:00:00 2025 - Size: 1.1 GiB - WAL Size: 156 MiB
```

### Show Backup Details

```bash
barman show-backup pg-primary 20251117T153000
```

**Output:**
```
Backup 20251117T153000:
  Server Name            : pg-primary
  System Id              : 7302509887943450845
  Status                 : DONE
  PostgreSQL Version     : 150003
  PGDATA directory       : /var/lib/postgresql/data
  Base backup information:
    Disk usage           : 1.2 GiB (1.2 GiB with WALs)
    Incremental size     : 1.2 GiB (-0.00%)
    Timeline             : 1
    Begin WAL            : 000000010000000000000006
    End WAL              : 000000010000000000000006
    Begin time           : 2025-11-17 15:30:00.123456+00:00
    End time             : 2025-11-17 15:31:23.789012+00:00
    Begin LSN            : 0/6000028
    End LSN              : 0/6000160
  WAL information:
    No of files          : 3
    Disk usage           : 48 MiB
```

---

## 📜 WAL Archiving

### Understanding WAL Archiving

**WAL (Write-Ahead Log)** contains all database changes. Continuous archiving enables PITR.

### Archive Command Method

**Configure on PostgreSQL:**
```sql
ALTER SYSTEM SET archive_command = 'rsync -a %p barman@barman-server:/var/lib/barman/pg-primary/wals/%f';
```

**How it works:**
1. PostgreSQL completes a WAL segment (16MB by default)
2. Runs `archive_command` with WAL file path
3. Barman receives and stores WAL file
4. PostgreSQL marks WAL as archived

### Streaming Archiving Method (Better!)

**On Barman server:**
```bash
# Start WAL receiver
barman receive-wal pg-primary
```

**Advantages:**
- Lower latency (continuous streaming)
- No archive_command failures
- Better monitoring

### Check WAL Archiving Status

```bash
# On Barman
barman check pg-primary | grep -i wal

# List archived WALs
barman show-backup pg-primary latest | grep "No of files"

# Check for archiving errors
barman check pg-primary | grep "archiver errors"
```

### Manual WAL Switch (for testing)

```bash
# On PostgreSQL
docker exec postgres-primary psql -U postgres -c "SELECT pg_switch_wal();"
```

---

## ⏰ Point-in-Time Recovery (PITR)

### What is PITR?

**PITR** allows you to restore database to **any point in time** between backups, not just to backup time.

### Use Cases:

**1. Undo bad transactions:**
```
09:00 - Last backup
10:30 - Developer accidentally runs DELETE FROM orders WHERE 1=1;
10:31 - Disaster discovered!

Solution: Restore to 10:29 (1 minute before disaster)
```

**2. Recover from corruption:**
```
Disk corruption detected at 14:00
Last good state: 13:45

Solution: Restore to 13:45
```

**3. Audit/Investigation:**
```
Need to see database state from yesterday at 15:00 for audit

Solution: Create test instance restored to that time
```

### PITR Requirements:

✅ Full backup (base backup)  
✅ All WAL files since backup  
✅ WAL files up to target time  

### Perform PITR

**Step 1: List available backups**
```bash
barman list-backup pg-primary
```

**Step 2: Recover to specific time**
```bash
# Syntax:
barman recover \
  [SERVER_NAME] \
  [BACKUP_ID] \
  [DESTINATION_DIR] \
  --target-time "YYYY-MM-DD HH:MM:SS"

# Example: Restore to yesterday at 3:00 PM
barman recover pg-primary latest /var/lib/postgresql/15/main \
  --target-time "2025-11-16 15:00:00"
```

**Step 3: What Barman does:**
1. Copies base backup to destination
2. Creates `recovery.conf` or `postgresql.auto.conf`
3. Sets up WAL replay to target time
4. Creates `recovery.signal` file

**Step 4: Start PostgreSQL**
```bash
# PostgreSQL will:
# 1. Start in recovery mode
# 2. Replay WAL files up to target time
# 3. Stop at target time
# 4. Become available for connections

pg_ctl start -D /var/lib/postgresql/15/main
```

### PITR Options

**1. Recover to specific time:**
```bash
barman recover pg-primary latest /recovery \
  --target-time "2025-11-17 10:30:00"
```

**2. Recover to latest (crash recovery):**
```bash
barman recover pg-primary latest /recovery
```

**3. Recover to transaction ID:**
```bash
barman recover pg-primary latest /recovery \
  --target-xid 12345678
```

**4. Recover to named restore point:**
```sql
-- Create restore point
SELECT pg_create_restore_point('before_migration');
```

```bash
barman recover pg-primary latest /recovery \
  --target-name "before_migration"
```

**5. Recover and stop immediately (for inspection):**
```bash
barman recover pg-primary latest /recovery \
  --target-immediate
```

### Recovery Testing

**Test recovery without affecting production:**

```bash
# 1. Recover to test directory
mkdir /tmp/recovery-test
barman recover pg-primary latest /tmp/recovery-test

# 2. Start PostgreSQL on different port
docker run -d \
  --name pg-recovery-test \
  -v /tmp/recovery-test:/var/lib/postgresql/data \
  -p 5555:5432 \
  postgres:15

# 3. Verify data
docker exec pg-recovery-test psql -U postgres -c "SELECT COUNT(*) FROM orders;"

# 4. Cleanup
docker stop pg-recovery-test
docker rm pg-recovery-test
rm -rf /tmp/recovery-test
```

---

## 📦 Incremental Backups

### What are Incremental Backups?

**Full backup:** Copies entire database (slow, large)  
**Incremental backup:** Copies only changed blocks since last backup (fast, small)

### Enable Incremental Backups

**Use rsync method:**
```ini
# In /etc/barman.d/pg-primary.conf
[pg-primary]
backup_method = rsync
reuse_backup = link    # Enable incremental backups
```

### How It Works:

**First backup:**
```
/var/lib/barman/pg-primary/base/20251117T020000/
  ├── data/           (Full copy: 10 GB)
  └── backup.info
```

**Second backup (incremental):**
```
/var/lib/barman/pg-primary/base/20251118T020000/
  ├── data/           (Hardlinks + changed blocks: 500 MB)
  └── backup.info

Storage used: 10.5 GB (not 20 GB!)
```

### Benefits:

- ✅ Faster backups (only copy changes)
- ✅ Less network traffic
- ✅ Less storage space
- ✅ More frequent backups possible

### Example:

```bash
# First backup: 10 minutes, 10 GB
barman backup pg-primary

# Second backup: 2 minutes, 500 MB
barman backup pg-primary

# Third backup: 1 minute, 200 MB
barman backup pg-primary
```

---

## 📊 Monitoring and Maintenance

### Check Barman Status

```bash
# Overall status
barman status pg-primary

# Detailed check
barman check pg-primary

# List all servers
barman list-server
```

### Monitor Disk Usage

```bash
# Show disk usage per server
barman diagnose | grep -A 20 "pg-primary"

# Estimate backup size
barman estimate-size pg-primary
```

### Retention Policy Management

**Configure retention:**
```ini
# Keep 7 days of backups
retention_policy = RECOVERY WINDOW OF 7 DAYS

# Or keep specific number of backups
retention_policy = REDUNDANCY 5
```

**Apply retention policy:**
```bash
# Delete old backups per retention policy
barman cron
```

### Scheduled Backups (Cron)

**Create cron job:**
```bash
# Edit crontab for barman user
sudo crontab -u barman -e

# Add daily backup at 2 AM
0 2 * * * /usr/bin/barman backup pg-primary

# Run maintenance every hour
0 * * * * /usr/bin/barman cron
```

### Validate Backups

```bash
# Verify backup integrity
barman check-backup pg-primary latest

# Test recovery (dry-run)
barman recover pg-primary latest /tmp/test-recovery --dry-run
```

### Monitor WAL Archiving

```bash
# Check WAL streaming status
barman replication-status pg-primary

# Show WAL receive status
ps aux | grep "barman receive-wal"

# Check for missing WALs
barman check pg-primary | grep -i wal
```

---

## 💼 Interview Questions

### Q1: "What is Barman and why use it?"

**Answer:**
> "Barman is an enterprise backup solution for PostgreSQL. Unlike manual pg_basebackup scripts, Barman provides:
> 
> - **Automation** - Scheduled backups via cron
> - **WAL archiving** - Continuous transaction log backup for PITR
> - **Incremental backups** - Using rsync, saves time and space
> - **Retention policies** - Automatic cleanup of old backups
> - **Catalog** - Comprehensive backup metadata and monitoring
> - **PITR** - Restore to any point in time, not just backup time
> 
> For production databases, Barman is essential for meeting RTO/RPO requirements and disaster recovery planning."

---

### Q2: "Explain Point-in-Time Recovery and when you'd use it"

**Answer:**
> "PITR lets you restore a database to any moment in time, not just to a backup timestamp. This requires:
> 
> 1. A base backup (full backup)
> 2. All WAL files from backup to target time
> 
> **Use cases:**
> 
> - **Undo mistakes:** Developer accidentally deletes data at 10:30 AM. Restore to 10:29 AM to recover.
> - **Investigate issues:** App had errors between 2-3 PM yesterday. Restore test instance to that time to debug.
> - **Compliance:** Auditors need to see database state from last month.
> 
> With Barman, PITR is simple:
> ```bash
> barman recover pg-primary latest /recovery \
>   --target-time '2025-11-16 10:29:00'
> ```
> 
> This is why WAL archiving is critical - it enables recovery to any point, not just backup moments."

---

### Q3: "How do incremental backups work in Barman?"

**Answer:**
> "Barman supports incremental backups via the rsync method with `reuse_backup = link`. Here's how it works:
> 
> **First backup:** Full copy of database (e.g., 100 GB)
> 
> **Second backup:** Barman uses hardlinks for unchanged files and only copies changed blocks. If only 2 GB changed, backup uses 2 GB new space, but appears as full 100 GB backup.
> 
> **Benefits:**
> - Faster backups (minutes vs hours)
> - Less storage (5-10x savings typical)
> - More frequent backups possible
> 
> **Restoration:** Transparent - you recover just like a full backup. Barman reconstructs the full database.
> 
> For production with daily backups on 500 GB database, incrementals might save 90% of backup time and storage."

---

### Q4: "How do you test that your backups are actually restorable?"

**Answer:**
> "Untested backups are useless - must test regularly! My approach:
> 
> **1. Automated testing (weekly):**
> ```bash
> # Script to recover and verify
> barman recover pg-primary latest /tmp/test-recovery
> pg_ctl start -D /tmp/test-recovery -o '-p 5555'
> psql -p 5555 -U postgres -c 'SELECT COUNT(*) FROM critical_table;'
> pg_ctl stop -D /tmp/test-recovery
> rm -rf /tmp/test-recovery
> ```
> 
> **2. Quarterly DR drills:**
> - Full disaster scenario
> - Measure RTO (how long to restore)
> - Verify data integrity
> - Test application connectivity
> - Document findings
> 
> **3. Continuous monitoring:**
> ```bash
> barman check pg-primary  # Daily
> barman check-backup pg-primary latest  # After each backup
> ```
> 
> **4. WAL replay testing:**
> - Verify all WALs present
> - Test PITR to random timestamps
> 
> A backup is only good if you've proven you can restore it!"

---

### Q5: "What's your backup strategy for a 1TB production database?"

**Answer:**
> "For a 1TB database, I'd design a multi-tier backup strategy:
> 
> **1. Barman Continuous Archiving:**
> - **Full backups:** Weekly on Sunday 2 AM (low traffic)
> - **Incremental backups:** Daily at 2 AM using rsync
> - **WAL streaming:** Continuous via `barman receive-wal`
> - **Retention:** 30 days of backups, 60 days of WALs
> 
> **2. Storage:**
> - Dedicated backup server with 10TB storage
> - Separate disk arrays for backups and WALs
> - Compression enabled (30-40% savings)
> 
> **3. Recovery Objectives:**
> - **RPO (Recovery Point Objective):** < 5 minutes (via WAL streaming)
> - **RTO (Recovery Time Objective):** < 2 hours for 1TB restore
> 
> **4. Monitoring:**
> ```bash
> # Cron jobs
> 0 2 * * 0 barman backup pg-primary  # Weekly full
> 0 2 * * 1-6 barman backup pg-primary  # Daily incremental
> 0 * * * * barman cron  # Hourly maintenance
> 
> # Alerts
> - Backup failures
> - WAL archiving behind > 10 files
> - Disk usage > 80%
> - Last backup > 25 hours old
> ```
> 
> **5. Offsite:**
> - Replicate backups to AWS S3 or Azure Blob Storage
> - Use `barman-cloud-backup` for cloud integration
> 
> **6. Testing:**
> - Weekly automated restore test
> - Monthly PITR test to random timestamp
> - Quarterly full DR drill with team
> 
> This provides production-grade protection with minimal data loss risk."

---

## 🎯 Hands-on Scenarios

### Scenario 1: Setup Barman from Scratch

**See:** [Scenario 11: Barman Setup and Backup](../11-barman-setup.md)

### Scenario 2: Perform PITR

**See:** [Scenario 12: Point-in-Time Recovery](../12-pitr-recovery.md)

### Scenario 3: Disaster Recovery Drill

**See:** [Scenario 13: Full DR Test](../13-disaster-recovery.md)

---

## 📚 Additional Resources

- **Official Documentation:** https://docs.pgbarman.org/
- **Barman GitHub:** https://github.com/EnterpriseDB/barman
- **Barman Cloud:** Cloud-native backup to S3/Azure/GCS
- **Barman GUI:** pgBackRest (alternative with web interface)

---

## 🎓 Key Takeaways

1. **Barman is production-grade** - Automates complex backup workflows
2. **WAL archiving enables PITR** - Can recover to any second, not just backup times
3. **Incremental backups save resources** - Faster backups, less storage
4. **Test your backups** - Untested backups are useless
5. **Automate everything** - Cron for backups, monitoring for failures
6. **Document RTO/RPO** - Know how long recovery takes
7. **Practice DR drills** - Team must know recovery procedures

---

**Next:** [Scenario 11: Hands-on Barman Setup](../scenarios/11-barman-setup.md)
