# PostgreSQL Streaming Replication with Docker

A comprehensive guide to understanding and implementing **PostgreSQL streaming replication** using Docker. This project demonstrates master-standby (primary-replica) architecture for high availability, disaster recovery, and read scaling.

## What is Streaming Replication?

**Streaming replication** is PostgreSQL's physical replication method where changes are continuously streamed from a primary server to one or more standby servers. Unlike logical replication (which replicates at the table/row level), streaming replication copies the entire database cluster at the WAL (Write-Ahead Log) level.

### Key Concepts

- **Primary Server:** The main database that handles all write operations
- **Standby/Replica Server:** Read-only copies that continuously sync with the primary
- **WAL (Write-Ahead Log):** Transaction logs that record all database changes
- **WAL Sender:** Process on primary that sends WAL records to standbys
- **WAL Receiver:** Process on standby that receives and applies WAL records
- **Replication Slots:** Ensure primary retains WAL files until standbys consume them

### Streaming vs Logical Replication

| Feature | Streaming Replication | Logical Replication |
|---------|----------------------|---------------------|
| **Level** | Physical (entire cluster) | Logical (tables/databases) |
| **Granularity** | All databases | Specific tables |
| **Standby Access** | Read-only queries | Full read-write |
| **Version Support** | Same major version | Can differ |
| **Use Case** | HA, failover, read scaling | Multi-tenant, selective sync |
| **Complexity** | Simpler setup | More complex |

## Table of Contents
- [What is Streaming Replication?](#what-is-streaming-replication)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Architecture Overview](#architecture-overview)
- [Setup Instructions](#setup-instructions)
- [How It Works](#how-it-works)
- [Testing Replication](#testing-replication)
- [Monitoring](#monitoring)
- [Failover Scenarios](#failover-scenarios)
- [Performance Tuning](#performance-tuning)
- [Common Issues](#common-issues)
- [Best Practices](#best-practices)
- [References](#references)

## Features

- ✅ **Automatic Failover:** Standby can be promoted to primary
- ✅ **Read Scaling:** Distribute read queries across replicas
- ✅ **High Availability:** Minimize downtime with hot standbys
- ✅ **Real-time Sync:** Near-zero replication lag
- ✅ **Docker-based:** Easy setup and teardown
- ✅ **Monitoring Tools:** Built-in queries to track replication status

## Prerequisites

- Docker & Docker Compose installed
- Basic understanding of PostgreSQL
- Terminal/command line knowledge
- 4GB+ RAM recommended for running multiple containers

## Project Structure

```
postgresql-streaming-replication/
├── docker-compose.yml          # Container orchestration
├── primary/
│   ├── init.sql               # Sample database schema
│   └── pg_hba.conf            # Authentication config
├── standby/
│   └── .gitkeep
├── scripts/
│   ├── setup-replication.sh   # Automated setup script
│   ├── promote-standby.sh     # Failover script
│   └── monitor.sh             # Status monitoring
└── README.md                   # This file
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Client Applications                      │
└────────────┬──────────────────────────────────┬─────────────┘
             │ Writes                            │ Reads
             ▼                                   ▼
    ┌─────────────────┐              ┌─────────────────┐
    │  Primary Server │◄─────────────┤ Standby Server  │
    │   (Port 5432)   │   WAL Stream │   (Port 5433)   │
    │                 ├──────────────►│                 │
    │  Read + Write   │  Replication │   Read-Only     │
    └─────────────────┘    Slot      └─────────────────┘
```

### How Data Flows:

1. Client writes data to **Primary**
2. Primary writes to WAL files
3. **WAL Sender** streams changes to Standby
4. **WAL Receiver** on Standby applies changes
5. Standby maintains identical data copy
6. Clients can read from Standby (read scaling)

## Setup Instructions

### 1. Clone/Create Project

```bash
cd /Users/ramesh/Documents/Learnings/gc-codings
git clone <your-repo-url> postgresql-streaming-replication
cd postgresql-streaming-replication
```

Or use this existing directory.

### 2. Create Configuration Files

**Primary Authentication Config** (`primary/pg_hba.conf`):
```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    replication     replicator      0.0.0.0/0               md5
host    all             all             0.0.0.0/0               md5
```

**Sample Schema** (`primary/init.sql`):
```sql
-- Sample database initialization
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO users (username, email) VALUES 
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com');
```

### 3. Docker Compose Configuration

See `docker-compose.yml` in the project.

### 4. Start the Replication Cluster

```bash
# Start containers
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

### 5. Configure Replication

**On Primary:**
```bash
# Connect to primary
docker exec -it postgres-primary psql -U postgres

# Create replication user
CREATE ROLE replicator WITH REPLICATION PASSWORD 'replicator_password' LOGIN;

# Create replication slot
SELECT * FROM pg_create_physical_replication_slot('standby_slot');

# Verify
SELECT * FROM pg_replication_slots;
\q
```

**On Standby:**
```bash
# Stop standby to configure
docker-compose stop postgres-standby

# Remove standby data
docker exec -it postgres-standby rm -rf /var/lib/postgresql/data/*

# Create base backup from primary
docker exec -it postgres-standby pg_basebackup -h postgres-primary -D /var/lib/postgresql/data -U replicator -v -P -W

# Create standby.signal file
docker exec -it postgres-standby touch /var/lib/postgresql/data/standby.signal

# Configure primary connection
docker exec -it postgres-standby bash -c "cat >> /var/lib/postgresql/data/postgresql.conf <<EOF
primary_conninfo = 'host=postgres-primary port=5432 user=replicator password=replicator_password'
primary_slot_name = 'standby_slot'
hot_standby = on
EOF"

# Start standby
docker-compose start postgres-standby
```

## How It Works

### 1. **WAL Generation on Primary**
When you execute a write operation:
```sql
INSERT INTO users (username, email) VALUES ('charlie', 'charlie@example.com');
```
- PostgreSQL first writes to WAL (Write-Ahead Log)
- Changes are then applied to data files
- WAL ensures durability

### 2. **WAL Streaming**
- **WAL Sender** process reads WAL segments
- Streams them over TCP connection to standby
- Uses replication slot to track progress
- Prevents WAL deletion before standby consumes it

### 3. **WAL Application on Standby**
- **WAL Receiver** receives WAL records
- Writes to standby's WAL files
- **Startup process** applies changes to data files
- Standby becomes identical to primary

### 4. **Hot Standby**
- Standby accepts read-only queries while replaying WAL
- Queries see consistent snapshot of data
- If query conflicts with WAL replay, query may be canceled

## Testing Replication

### Test 1: Basic Data Sync

**On Primary:**
```bash
docker exec -it postgres-primary psql -U postgres -d postgres -c "INSERT INTO users (username, email) VALUES ('test_user', 'test@example.com');"
docker exec -it postgres-primary psql -U postgres -d postgres -c "SELECT * FROM users;"
```

**On Standby:**
```bash
# Data should appear automatically
docker exec -it postgres-standby psql -U postgres -d postgres -c "SELECT * FROM users;"
```

### Test 2: Read-Only Enforcement

**Try writing to standby (should fail):**
```bash
docker exec -it postgres-standby psql -U postgres -d postgres -c "INSERT INTO users (username, email) VALUES ('fail', 'fail@example.com');"
# ERROR:  cannot execute INSERT in a read-only transaction
```

### Test 3: Replication Lag

```bash
# On primary - check current WAL position
docker exec -it postgres-primary psql -U postgres -c "SELECT pg_current_wal_lsn();"

# On standby - check received/replayed position
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

## Monitoring

### Check Replication Status (Primary)

```sql
-- View connected replicas
SELECT * FROM pg_stat_replication;

-- Key columns:
-- application_name: Standby identifier
-- state: streaming/catchup/backup
-- sent_lsn: WAL position sent
-- write_lsn: WAL position written by standby
-- flush_lsn: WAL position flushed to disk
-- replay_lsn: WAL position applied
-- sync_state: async/sync
```

### Check Replication Status (Standby)

```sql
-- Check if in recovery mode
SELECT pg_is_in_recovery();  -- Should return 't' (true)

-- View replication lag in bytes
SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS lag_bytes;

-- View last received WAL timestamp
SELECT pg_last_xact_replay_timestamp();
```

### Monitor with Shell Script

Create `scripts/monitor.sh`:
```bash
#!/bin/bash
echo "=== PRIMARY STATUS ==="
docker exec postgres-primary psql -U postgres -c "SELECT client_addr, state, sent_lsn, write_lsn, replay_lsn, sync_state FROM pg_stat_replication;"

echo ""
echo "=== STANDBY STATUS ==="
docker exec postgres-standby psql -U postgres -c "SELECT pg_is_in_recovery() AS in_recovery, pg_last_wal_receive_lsn() AS receive_lsn, pg_last_wal_replay_lsn() AS replay_lsn;"
```

Run: `bash scripts/monitor.sh`

## Failover Scenarios

### Manual Failover (Promote Standby)

When primary fails, promote standby to primary:

```bash
# 1. Stop primary (simulating failure)
docker-compose stop postgres-primary

# 2. Promote standby to primary
docker exec -it postgres-standby pg_ctl promote -D /var/lib/postgresql/data

# Or using SQL
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_promote();"

# 3. Verify standby is now read-write
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false)

# 4. Test writes on new primary
docker exec -it postgres-standby psql -U postgres -d postgres -c "INSERT INTO users (username, email) VALUES ('after_failover', 'failover@example.com');"
```

### Re-establish Replication (Old Primary as New Standby)

After failover, if you want old primary to become standby:

```bash
# 1. Clean old primary data
docker exec postgres-primary rm -rf /var/lib/postgresql/data/*

# 2. Take backup from new primary (promoted standby)
docker exec postgres-primary pg_basebackup -h postgres-standby -D /var/lib/postgresql/data -U replicator -v -P

# 3. Configure as standby
docker exec postgres-primary touch /var/lib/postgresql/data/standby.signal
docker exec postgres-primary bash -c "echo \"primary_conninfo = 'host=postgres-standby port=5432 user=replicator password=replicator_password'\" >> /var/lib/postgresql/data/postgresql.conf"

# 4. Restart
docker-compose restart postgres-primary
```

## Performance Tuning

### Key Parameters

**Primary Configuration:**
```conf
# postgresql.conf settings for primary
wal_level = replica                    # Enable replication
max_wal_senders = 10                   # Max concurrent replicas
wal_keep_size = 1GB                    # Retain WAL for slow standbys
synchronous_commit = off               # Async for performance (or 'remote_apply' for sync)
archive_mode = on                      # Optional: for point-in-time recovery
```

**Standby Configuration:**
```conf
# postgresql.conf settings for standby
hot_standby = on                       # Allow read queries
max_standby_streaming_delay = 30s      # Max delay before canceling queries
wal_receiver_status_interval = 10s     # Status update frequency
```

### Replication Modes

**Asynchronous (Default):**
- Fast writes on primary
- Standbys may lag slightly
- Risk: Data loss if primary crashes before WAL sent

**Synchronous:**
```sql
-- On primary
ALTER SYSTEM SET synchronous_commit = 'remote_apply';
ALTER SYSTEM SET synchronous_standby_names = 'standby1';
SELECT pg_reload_conf();
```
- Writes wait for standby confirmation
- Zero data loss
- Higher latency

## Common Issues

### Issue 1: Replication Slot Not Created
**Error:** `replication slot "standby_slot" does not exist`

**Fix:**
```sql
-- On primary
SELECT * FROM pg_create_physical_replication_slot('standby_slot');
```

### Issue 2: Authentication Failed
**Error:** `password authentication failed for user "replicator"`

**Fix:** Check `pg_hba.conf` has:
```conf
host replication replicator 0.0.0.0/0 md5
```

### Issue 3: Standby Not Streaming
**Check:**
```bash
# On standby, verify standby.signal exists
docker exec postgres-standby ls -la /var/lib/postgresql/data/standby.signal

# Check logs
docker-compose logs postgres-standby
```

### Issue 4: High Replication Lag
**Causes:**
- Slow network
- Heavy write load on primary
- Standby hardware slower than primary

**Solutions:**
- Increase `wal_keep_size`
- Add more standbys to distribute reads
- Use replication slots to prevent WAL deletion

## Best Practices

1. **Always Use Replication Slots:** Prevents WAL deletion, avoiding standby failure
2. **Monitor Lag Regularly:** Set up alerts for lag > 10s
3. **Test Failover:** Practice promotion in dev/staging
4. **Backup Strategy:** Streaming replication ≠ backup (use pg_dump/pg_basebackup)
5. **Network Security:** Use SSL for WAN replication
6. **Resource Planning:** Standby needs similar hardware to primary
7. **Multiple Standbys:** 1-2 for HA, more for read scaling
8. **Synchronous for Critical Data:** Use for financial/critical transactions

## Docker Commands Reference

```bash
# Start cluster
docker-compose up -d

# Stop cluster
docker-compose down

# View logs (real-time)
docker-compose logs -f

# Connect to primary
docker exec -it postgres-primary psql -U postgres

# Connect to standby
docker exec -it postgres-standby psql -U postgres

# Check container status
docker-compose ps

# Restart a specific container
docker-compose restart postgres-standby

# Clean everything (WARNING: deletes data)
docker-compose down -v
```

## Next Steps

After mastering streaming replication:
1. **Explore Logical Replication:** For selective table sync
2. **Implement pgBouncer:** Connection pooling
3. **Study pgBackRest:** Advanced backup/restore
4. **Learn Patroni:** Automated failover orchestration
5. **Try Citus:** Horizontal scaling (sharding)

## References

- [PostgreSQL Replication Documentation](https://www.postgresql.org/docs/current/runtime-config-replication.html)
- [High Availability Guide](https://www.postgresql.org/docs/current/high-availability.html)
- [pg_basebackup Documentation](https://www.postgresql.org/docs/current/app-pgbasebackup.html)
- [Monitoring Replication](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW)

## Contributing
Contributions are welcome! Open an issue or submit a pull request.

## License
MIT License - see LICENSE file for details.

## Author
**Ramesh S**
- GitHub: [@sramesh137](https://github.com/sramesh137)

---
⭐ Star this repo if it helped you learn PostgreSQL streaming replication!
