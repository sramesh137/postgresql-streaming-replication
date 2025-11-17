# Quick Reference - PostgreSQL Streaming Replication

Quick lookup guide for common commands and queries while working through scenarios.

---

## 🚀 Environment Management

### Start/Stop
```bash
# Start all services
docker-compose up -d

# Stop all services (keep data)
docker-compose stop

# Stop and remove (keep data)
docker-compose down

# Full cleanup (removes all data)
docker-compose down -v

# Restart specific service
docker-compose restart postgres-primary
docker-compose restart postgres-standby
```

### Setup Replication
```bash
# Initial setup
bash scripts/setup-replication.sh

# Monitor status
bash scripts/monitor.sh

# Test replication
bash scripts/test-replication.sh
```

---

## 🔌 Connections

### Command Line
```bash
# Connect to primary
docker exec -it postgres-primary psql -U postgres

# Connect to standby
docker exec -it postgres-standby psql -U postgres

# Execute single command
docker exec -it postgres-primary psql -U postgres -c "SELECT version();"

# Execute from file
docker exec -i postgres-primary psql -U postgres < script.sql
```

### Connection Strings
```
# Primary (Read-Write)
postgresql://postgres:postgres_password@localhost:5432/postgres

# Standby (Read-Only)
postgresql://postgres:postgres_password@localhost:5433/postgres
```

---

## 📊 Monitoring Queries

### Check Server Role
```sql
-- Returns 't' if standby, 'f' if primary
SELECT pg_is_in_recovery();
```

### Replication Status (on Primary)
```sql
-- Full replication status
SELECT * FROM pg_stat_replication;

-- Quick check
SELECT 
    application_name,
    state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;
```

### Replication Lag (Human Readable)
```sql
SELECT 
    application_name,
    client_addr,
    state,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_size,
    EXTRACT(EPOCH FROM replay_lag) AS lag_seconds
FROM pg_stat_replication;
```

### LSN Positions
```sql
-- Current LSN on primary
SELECT pg_current_wal_lsn();

-- On standby - what's received vs replayed
SELECT 
    pg_last_wal_receive_lsn() AS received,
    pg_last_wal_replay_lsn() AS replayed,
    pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS pending_bytes;
```

### Replication Slots
```sql
SELECT 
    slot_name,
    slot_type,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;
```

### Timeline Information
```sql
SELECT * FROM pg_control_checkpoint();

-- Just the timeline
SELECT timeline_id FROM pg_control_checkpoint();
```

---

## 🔧 Administration

### Promote Standby to Primary
```bash
# Method 1: pg_ctl
docker exec -it postgres-standby pg_ctl promote -D /var/lib/postgresql/data

# Method 2: SQL function
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_promote();"
```

### Check for standby.signal
```bash
docker exec -it postgres-standby bash -c '
if [ -f /var/lib/postgresql/data/standby.signal ]; then
    echo "SERVER IS STANDBY"
else
    echo "SERVER IS PRIMARY"
fi
'
```

### Reload Configuration
```sql
SELECT pg_reload_conf();
```

### Force Checkpoint
```sql
CHECKPOINT;
```

---

## 📈 Performance Queries

### Active Connections
```sql
SELECT 
    datname,
    usename,
    application_name,
    client_addr,
    state,
    query
FROM pg_stat_activity
WHERE state = 'active';
```

### Database Statistics
```sql
SELECT 
    datname,
    numbackends AS connections,
    xact_commit AS commits,
    xact_rollback AS rollbacks,
    blks_read AS disk_reads,
    blks_hit AS cache_hits,
    round((blks_hit::float / NULLIF(blks_hit + blks_read, 0) * 100)::numeric, 2) AS cache_hit_ratio
FROM pg_stat_database
WHERE datname = 'postgres';
```

### Table Sizes
```sql
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### WAL Statistics
```sql
-- Current WAL position and file
SELECT 
    pg_current_wal_lsn(),
    pg_walfile_name(pg_current_wal_lsn());

-- WAL generation rate (requires pg_stat_statements)
SELECT 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) AS total_wal_generated;
```

---

## 🧪 Testing Commands

### Bulk Insert
```sql
-- Insert N rows
INSERT INTO users (username, email)
SELECT 
    'user_' || i,
    'user' || i || '@test.com'
FROM generate_series(1, 1000) AS i;
```

### Generate Load
```sql
DO $$
BEGIN
    FOR i IN 1..10000 LOOP
        INSERT INTO orders (user_id, product, amount)
        VALUES (
            (random() * 10 + 1)::INTEGER,
            'Product_' || i,
            (random() * 1000)::NUMERIC(10,2)
        );
    END LOOP;
END $$;
```

### Count Rows
```sql
SELECT 
    schemaname,
    tablename,
    n_live_tup AS row_count
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;
```

---

## 🐛 Troubleshooting

### View Logs
```bash
# Follow all logs
docker-compose logs -f

# Specific service
docker-compose logs -f postgres-primary

# Last N lines
docker-compose logs --tail=50 postgres-standby

# Since timestamp
docker-compose logs --since 2025-11-16T07:00:00
```

### Check Container Status
```bash
# Running containers
docker-compose ps

# Container resource usage
docker stats

# Inspect network
docker network inspect postgresql-streaming-replication_postgres-network
```

### Configuration Files
```bash
# View postgresql.conf
docker exec -it postgres-primary cat /var/lib/postgresql/data/postgresql.conf | grep -v "^#" | grep -v "^$"

# View pg_hba.conf
docker exec -it postgres-primary cat /var/lib/postgresql/data/pg_hba.conf | grep -v "^#" | grep -v "^$"
```

### Check Replication Configuration
```sql
-- Show replication settings
SHOW wal_level;
SHOW max_wal_senders;
SHOW max_replication_slots;
SHOW hot_standby;
SHOW synchronous_commit;
```

---

## 💾 Backup & Recovery

### Take Base Backup
```bash
docker exec -it postgres-standby bash -c "
PGPASSWORD=replicator_password pg_basebackup \
  -h postgres-primary \
  -D /tmp/backup \
  -U replicator \
  -v -P -X stream
"
```

### Export Data
```bash
# Dump entire database
docker exec -it postgres-primary pg_dump -U postgres postgres > backup.sql

# Dump specific table
docker exec -it postgres-primary pg_dump -U postgres -t users postgres > users_backup.sql

# Dump in custom format (compressed)
docker exec -it postgres-primary pg_dump -U postgres -Fc postgres > backup.dump
```

### Import Data
```bash
# From SQL file
docker exec -i postgres-primary psql -U postgres < backup.sql

# From custom format
docker exec -i postgres-primary pg_restore -U postgres -d postgres backup.dump
```

---

## 📋 Useful Views

### Create Replication Health View
```sql
CREATE OR REPLACE VIEW replication_health AS
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
    EXTRACT(EPOCH FROM replay_lag) AS lag_seconds,
    CASE 
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 10485760 THEN '⚠️  WARNING'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) > 1048576 THEN '⚠️  CAUTION'
        ELSE '✅ OK'
    END AS status
FROM pg_stat_replication;

-- Use it
SELECT * FROM replication_health;
```

---

## 🔑 Quick Checks

### One-Liner Health Check
```bash
# Primary status
docker exec -it postgres-primary psql -U postgres -t -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END || ' | Timeline: ' || (SELECT timeline_id FROM pg_control_checkpoint());"

# Standby status
docker exec -it postgres-standby psql -U postgres -t -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END || ' | Timeline: ' || (SELECT timeline_id FROM pg_control_checkpoint());"
```

### Quick Lag Check
```bash
docker exec -it postgres-primary psql -U postgres -t -c "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) FROM pg_stat_replication;"
```

### Quick Row Count
```bash
docker exec -it postgres-primary psql -U postgres -t -c "SELECT 'Users: ' || COUNT(*) FROM users;"
```

---

## 🎯 Common Scenarios

### Scenario: Check if Setup is Working
```bash
# 1. Check both servers are up
docker-compose ps

# 2. Check replication is streaming
docker exec -it postgres-primary psql -U postgres -c "SELECT state FROM pg_stat_replication;"
# Should show: streaming

# 3. Check standby is in recovery
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should show: t (true)

# 4. Test data replication
docker exec -it postgres-primary psql -U postgres -c "INSERT INTO users (username, email) VALUES ('test', 'test@test.com');"
docker exec -it postgres-standby psql -U postgres -c "SELECT * FROM users WHERE username='test';"
# Should see the row
```

### Scenario: Standby is Lagging
```bash
# 1. Check lag amount
docker exec -it postgres-primary psql -U postgres -c "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag FROM pg_stat_replication;"

# 2. Check standby system resources
docker stats postgres-standby

# 3. Check for long-running queries on standby
docker exec -it postgres-standby psql -U postgres -c "SELECT pid, usename, now() - query_start AS duration, query FROM pg_stat_activity WHERE state = 'active' ORDER BY duration DESC;"

# 4. Check replication slot is active
docker exec -it postgres-primary psql -U postgres -c "SELECT active FROM pg_replication_slots;"
```

### Scenario: Reset Everything
```bash
# Complete reset
docker-compose down -v
docker-compose up -d
sleep 10
bash scripts/setup-replication.sh
bash scripts/monitor.sh
```

---

## 📞 Getting Help

### PostgreSQL Documentation
```bash
# In psql
\? -- help on psql commands
\h SELECT -- help on SQL commands

# Online
https://www.postgresql.org/docs/current/warm-standby.html
```

### Check Versions
```bash
docker exec -it postgres-primary psql -U postgres -c "SELECT version();"
docker --version
docker-compose --version
```

---

**Tip:** Bookmark this file for quick reference while working through scenarios!
