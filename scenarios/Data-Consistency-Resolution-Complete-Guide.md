# Data Consistency Resolution - Complete Step-by-Step Guide

**Date:** November 16, 2025  
**Problem:** After manual failover, we had split-brain with divergent data  
**Solution:** Remove old data, copy from new primary, restore replication

---

## 🎯 The Core Concept (Simple!)

You nailed it! Here's the simple 3-step process:

```
1. Remove old divergent data from old primary
2. Take backup from new primary (pg_basebackup)
3. Start old primary as new standby
```

**In MySQL terms:**
```bash
# MySQL equivalent:
1. rm -rf /var/lib/mysql/*
2. mysqldump master | mysql slave  (or rsync)
3. CHANGE MASTER TO ...; START SLAVE;
```

**In PostgreSQL:**
```bash
1. Remove data directory
2. pg_basebackup from new primary
3. Start with standby.signal
```

---

## 📊 Starting Situation (The Problem)

### Before Resolution:

**NEW PRIMARY (postgres-standby:5433):**
- Timeline: 2
- Status: Writable, accepting connections
- Products: 10,002 rows
- Has: ID 10034 "Post-Failover Product"

**OLD PRIMARY (postgres-primary:5432):**
- Timeline: 1 
- Status: Stopped, has divergent data
- Products: 10,002 rows
- Has: ID 10002 "Old Primary Write"

**Problem:** Same row count, but **different data!** Cannot automatically sync.

---

## 🔧 Step-by-Step Resolution (What We Did)

### Step 1: Stop and Clean Old Primary

**Goal:** Remove divergent data completely

**What we tried (FAILED):**
```bash
docker stop postgres-primary
docker exec postgres-primary bash -c "rm -rf /var/lib/postgresql/data/*"
```

**Why it failed:**
- `docker exec` only works on **RUNNING** containers
- Can't execute commands in stopped container

**What worked:**
```bash
# Start container first
docker start postgres-primary
sleep 3  # Wait for container to boot

# Remove data
docker exec postgres-primary bash -c "rm -rf /var/lib/postgresql/data/* /var/lib/postgresql/data/.*" 2>/dev/null

# Stop container
docker stop postgres-primary
```

**Problem encountered:**
- This didn't fully clean the directories
- PostgreSQL has nested subdirectories (base/, pg_wal/, etc.)
- Some files remained

**Final solution that worked:**
```bash
# Stop everything
docker-compose down

# Remove the Docker volume completely
docker volume rm postgresql-streaming-replication_primary-data

# Recreate clean container
docker-compose up -d postgres-primary
```

**MySQL DBA Note:**
- In native MySQL: `rm -rf /var/lib/mysql/*` works when stopped
- In Docker: Must use volume management or running container
- Docker isolates filesystem - different approach needed!

---

### Step 2: Configure New Primary to Accept Replication

**Goal:** Allow old primary to connect for backup

**What we needed to do:**
```bash
# Add replication access to pg_hba.conf on NEW primary
docker exec postgres-standby bash -c \
  "echo 'host replication replicator 0.0.0.0/0 trust' >> /var/lib/postgresql/data/pg_hba.conf"

# Reload configuration
docker exec postgres-standby psql -U postgres -c "SELECT pg_reload_conf();"
```

**Why this was needed:**
- New primary (postgres-standby) was promoted from standby
- It didn't have replication access configured
- Old setup: standby connected to primary (one direction)
- New setup: need reverse connection (old primary connecting to new primary)

**MySQL equivalent:**
```sql
-- MySQL: Grant replication privileges
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
FLUSH PRIVILEGES;
```

---

### Step 3: Take Base Backup (pg_basebackup)

**Goal:** Copy all data from new primary to old primary

**This is the MOST IMPORTANT step!**

**What we tried (FAILED):**
```bash
docker start postgres-primary
sleep 3
docker exec postgres-primary pg_basebackup -h postgres-standby ...
```

**Why it failed:**
- Old primary's PostgreSQL process was running
- Can't overwrite data directory while PostgreSQL is active
- Got error: "directory exists but is not empty"

**What worked:**
```bash
# Use docker-compose run (creates temporary container)
docker-compose run --rm postgres-primary bash -c \
  "PGPASSWORD=replicator_password pg_basebackup \
   -h postgres-standby \
   -D /var/lib/postgresql/data \
   -U replicator \
   -v -P -X stream -R"
```

**Key parameters explained:**
- `-h postgres-standby`: Connect to NEW primary
- `-D /var/lib/postgresql/data`: Destination directory
- `-U replicator`: Replication user
- `-v`: Verbose output
- `-P`: Show progress
- `-X stream`: Stream WAL during backup
- `-R`: Write recovery configuration automatically (creates standby.signal)

**What this command does:**
1. Connects to new primary (Timeline 2)
2. Takes consistent snapshot of entire database
3. Copies all data files to old primary
4. Streams WAL changes during copy (ensures consistency)
5. Creates standby.signal (tells PostgreSQL to start as standby)
6. Writes connection info to postgresql.auto.conf

**MySQL equivalent:**
```bash
# MySQL: Multiple approaches
# 1. Using mysqldump:
mysqldump --all-databases --master-data=2 > backup.sql
mysql < backup.sql

# 2. Using rsync:
rsync -avz master:/var/lib/mysql/ /var/lib/mysql/

# 3. Using Percona XtraBackup:
xtrabackup --backup --target-dir=/backup
xtrabackup --prepare --target-dir=/backup
xtrabackup --copy-back --target-dir=/backup
```

**Difference:**
- PostgreSQL `pg_basebackup`: One command, atomic, safe
- MySQL: Multiple steps, more manual work

---

### Step 4: Create Replication Slot

**Goal:** Prevent WAL deletion while standby catches up

**What we did:**
```bash
docker exec postgres-standby psql -U postgres -c \
  "SELECT pg_create_physical_replication_slot('standby_slot');"
```

**Why this was needed:**
- Old primary's configuration references 'standby_slot'
- New primary didn't have this slot (it was on old primary before)
- Without slot: replication connection fails

**What we encountered:**
```
FATAL: could not start WAL streaming: ERROR: replication slot "standby_slot" does not exist
```

**After creating slot:**
- Replication connected immediately
- Old primary started receiving WAL

**MySQL equivalent:**
```sql
-- MySQL: No direct equivalent
-- Closest: Binary log retention
SET GLOBAL expire_logs_days = 7;
```

**Difference:**
- PostgreSQL: Per-standby slot (fine-grained control)
- MySQL: Global binlog retention (coarse-grained)

---

### Step 5: Start Old Primary as New Standby

**Goal:** Bring old primary online as replica

**What we did:**
```bash
docker-compose start postgres-primary
sleep 5
```

**What happened internally:**
1. PostgreSQL found `standby.signal` file
2. Read connection info from `postgresql.auto.conf`
3. Connected to new primary (postgres-standby)
4. Started receiving WAL stream
5. Entered recovery mode (read-only)

**Verification:**
```bash
docker exec postgres-primary psql -U postgres -c \
  "SELECT pg_is_in_recovery(), 
          (SELECT received_tli FROM pg_stat_wal_receiver);"
```

**Result:**
```
 pg_is_in_recovery | received_tli 
-------------------+--------------
 t                 |            2
```

✅ **Success indicators:**
- `pg_is_in_recovery() = true` (it's a standby)
- `received_tli = 2` (following Timeline 2)

---

### Step 6: Verify Data Consistency

**Goal:** Confirm both servers have identical data

**What we checked:**
```bash
# Check NEW PRIMARY
docker exec postgres-standby psql -U postgres -c \
  "SELECT id, name FROM products WHERE id >= 10000 ORDER BY id;"

# Check NEW STANDBY
docker exec postgres-primary psql -U postgres -c \
  "SELECT id, name FROM products WHERE id >= 10000 ORDER BY id;"
```

**Results (IDENTICAL!):**
```
  id   |         name          
-------+-----------------------
 10000 | Product 10000
 10001 | Brand New Product
 10034 | Post-Failover Product
```

✅ **Both servers have:**
- Same row count: 10,002 products
- Same data: ID 10034 exists on both
- Timeline 2 on both

❌ **Divergent data (ID 10002 "Old Primary Write") is GONE**
- This was on Timeline 1
- We chose to discard it (intentionally!)

---

## 🔍 Understanding Timeline Change

This is the **KEY** PostgreSQL concept:

### Before Failover (Timeline 1):
```
PRIMARY (postgres-primary)
Timeline: 1
LSN: 0/639EC30
   ↓
STANDBY (postgres-standby)
Timeline: 1
LSN: 0/639EC30 (same)
```

### After Failover (Timeline 2):
```
Old Primary (STOPPED)          New Primary (PROMOTED)
Timeline: 1                    Timeline: 2
LSN: 0/639ECE0                LSN: 0/639EDC0
Data: ID 10002                Data: ID 10034
```

### After Resolution (Timeline 2 - Consistent):
```
New Primary (postgres-standby)
Timeline: 2
LSN: 0/8000060
Data: ID 10034
   ↓ (replication)
New Standby (postgres-primary - REBUILT)
Timeline: 2
LSN: 0/8000060
Data: ID 10034 (replicated from primary)
```

**Key insight:**
- Timeline is like a "version number" for the database cluster
- Each failover increments timeline
- Servers on different timelines **cannot sync automatically**
- Must rebuild to jump timelines (1 → 2)

**MySQL comparison:**
- MySQL: No timeline concept
- MySQL: Uses binlog position (linear)
- MySQL: Can sync between servers more easily (but riskier!)

---

## 📝 Complete Command Sequence (Clean Version)

Here's the final working sequence without troubleshooting:

```bash
# 1. Stop everything and clean
docker-compose down
docker volume rm postgresql-streaming-replication_primary-data
docker-compose up -d postgres-standby  # Start new primary only
sleep 5

# 2. Configure new primary for replication
docker exec postgres-standby bash -c \
  "echo 'host replication replicator 0.0.0.0/0 trust' >> /var/lib/postgresql/data/pg_hba.conf"
docker exec postgres-standby psql -U postgres -c "SELECT pg_reload_conf();"

# 3. Create replication slot
docker exec postgres-standby psql -U postgres -c \
  "SELECT pg_create_physical_replication_slot('standby_slot');"

# 4. Take base backup
docker-compose run --rm postgres-primary bash -c \
  "PGPASSWORD=replicator_password pg_basebackup \
   -h postgres-standby -D /var/lib/postgresql/data \
   -U replicator -v -P -X stream -R"

# 5. Start old primary as new standby
docker-compose start postgres-primary
sleep 5

# 6. Verify replication
docker exec postgres-standby psql -U postgres -c \
  "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

# 7. Verify data consistency
docker exec postgres-standby psql -U postgres -c \
  "SELECT count(*) FROM products;"
docker exec postgres-primary psql -U postgres -c \
  "SELECT count(*) FROM products;"
```

---

## 🐛 Troubleshooting Guide

### Issue 1: "Container not running" when using docker exec

**Error:**
```
Error response from daemon: container is not running
```

**Cause:**
- Tried to run `docker exec` on stopped container

**Solution:**
- Always start container first
- Add `sleep` to wait for boot
```bash
docker start postgres-primary
sleep 3
docker exec postgres-primary ...
```

---

### Issue 2: "rm -rf didn't fully clean directories"

**Problem:**
- Command ran but data still exists
- Subdirectories remained

**Cause:**
- `rm -rf /data/*` removes files, not hidden files
- PostgreSQL has `.` and `..` entries

**Solution:**
- Add `.*` to pattern: `rm -rf /data/* /data/.*`
- OR use Docker volume removal (cleaner):
```bash
docker-compose down
docker volume rm <volume-name>
```

---

### Issue 3: "Directory exists but is not empty"

**Error:**
```
pg_basebackup: error: directory "/var/lib/postgresql/data" exists but is not empty
```

**Cause:**
- PostgreSQL process running or data exists

**Solution:**
- Stop PostgreSQL first
- Clean directory
- Use `docker-compose run --rm` (creates temporary container)

---

### Issue 4: "No pg_hba.conf entry for replication"

**Error:**
```
FATAL: no pg_hba.conf entry for replication connection from host "172.19.0.4"
```

**Cause:**
- New primary doesn't allow replication connections
- pg_hba.conf not configured

**Solution:**
```bash
echo 'host replication replicator 0.0.0.0/0 trust' >> pg_hba.conf
SELECT pg_reload_conf();
```

---

### Issue 5: "Replication slot does not exist"

**Error:**
```
FATAL: could not start WAL streaming: ERROR: replication slot "standby_slot" does not exist
```

**Cause:**
- Standby configuration references slot
- New primary doesn't have it

**Solution:**
```sql
SELECT pg_create_physical_replication_slot('standby_slot');
```

---

## 🎓 Learning Summary

### What You Learned:

1. **Core Concept** ✅
   - Remove old data → Copy from primary → Start as standby
   - Simple 3-step process!

2. **Docker Challenges** ✅
   - `docker exec` needs running container
   - `sleep` is critical after `docker start`
   - Volume management for clean state

3. **PostgreSQL Specifics** ✅
   - `pg_basebackup`: One command to copy everything
   - `-R` flag: Auto-configures standby
   - Replication slots: Prevent WAL deletion

4. **Timeline Concept** ✅
   - Failover creates new timeline
   - Different timelines can't sync automatically
   - Must rebuild to jump timelines

5. **Replication Setup** ✅
   - pg_hba.conf: Control access
   - standby.signal: Marks as standby
   - primary_conninfo: Connection string

### MySQL DBA Takeaways:

| Task | MySQL | PostgreSQL |
|------|-------|------------|
| **Remove data** | `rm -rf /var/lib/mysql/*` (when stopped) | Docker volume removal or exec in running container |
| **Copy data** | `mysqldump` or `rsync` (multiple steps) | `pg_basebackup` (one command) |
| **Configure replica** | `CHANGE MASTER TO` (manual SQL) | `-R` flag (automatic) |
| **Start replica** | `START SLAVE` | Start with `standby.signal` present |
| **Verify** | `SHOW SLAVE STATUS` | `pg_stat_replication` |
| **Timeline tracking** | None (binlog position only) | Timeline ID (failover history) |
| **WAL retention** | `expire_logs_days` (global) | Replication slots (per-standby) |

---

## ✅ Final Verification Checklist

After resolution, verify these:

- [ ] Old primary is in recovery mode:
  ```sql
  SELECT pg_is_in_recovery();  -- Should return 't' (true)
  ```

- [ ] Timeline matches new primary:
  ```sql
  SELECT received_tli FROM pg_stat_wal_receiver;  -- Should be 2
  ```

- [ ] Replication is streaming:
  ```sql
  -- On new primary:
  SELECT state FROM pg_stat_replication;  -- Should be 'streaming'
  ```

- [ ] Data is identical:
  ```sql
  -- Run on both servers:
  SELECT count(*) FROM products;
  SELECT md5(string_agg(id::text, ',')) FROM (SELECT id FROM products ORDER BY id) t;
  ```

- [ ] No lag:
  ```sql
  -- On new primary:
  SELECT sent_lsn - replay_lsn AS lag FROM pg_stat_replication;  -- Should be 0
  ```

---

## 🎯 Key Takeaway

**Your understanding is PERFECT:**

> "Remove the datadir and take a backup from the other node, and push the data directory here, and then start"

That's **exactly** what we did! The troubleshooting was just:
- Learning Docker quirks (`docker exec` on running containers)
- Configuring pg_hba.conf (access control)
- Creating replication slot (WAL retention)
- Using correct commands (`docker-compose run` vs `docker exec`)

The **concept** is simple. The **execution** had some Docker-specific challenges.

---

*Document created: November 16, 2025*  
*Purpose: Explain data consistency resolution with all troubleshooting details*  
*For: MySQL DBAs learning PostgreSQL streaming replication*
