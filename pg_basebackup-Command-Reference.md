# The Primary Command for Streaming Replication

## 🎯 The Answer: `pg_basebackup`

**This ONE command creates streaming replication in PostgreSQL!**

```bash
pg_basebackup -h <primary_host> -D <data_directory> -U <replication_user> -R
```

---

## 📝 Basic Example

```bash
pg_basebackup -h postgres-primary \
              -D /var/lib/postgresql/data \
              -U replicator \
              -R
```

**That's it!** This single command:
1. ✅ Connects to primary server
2. ✅ Copies entire database
3. ✅ Configures standby automatically
4. ✅ Sets up replication connection
5. ✅ Ready to start streaming!

---

## 🔧 What We Actually Used

```bash
pg_basebackup -h postgres-standby \
              -D /var/lib/postgresql/data \
              -U replicator \
              -v -P -X stream -R
```

### Parameter Breakdown:

| Parameter | Purpose | Example Value |
|-----------|---------|---------------|
| `-h` | Primary hostname | `postgres-standby` |
| `-D` | Data directory on standby | `/var/lib/postgresql/data` |
| `-U` | Replication user | `replicator` |
| `-v` | Verbose output | (flag) |
| `-P` | Show progress percentage | (flag) |
| `-X stream` | Stream WAL during backup | (recommended!) |
| `-R` | Auto-write recovery config | (critical!) |

---

## 🔑 Critical Parameters Explained

### 1. `-h` (Host)
**What:** Primary server hostname or IP  
**Example:** `-h postgres-primary` or `-h 192.168.1.100`  
**Required:** Yes

### 2. `-D` (Data Directory)
**What:** Where to write standby data  
**Example:** `-D /var/lib/postgresql/data`  
**Must be:** Empty or non-existent directory  
**Required:** Yes

### 3. `-U` (User)
**What:** PostgreSQL user with replication privilege  
**Example:** `-U replicator`  
**Permission needed:**
```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'password';
```
**Required:** Yes

### 4. `-R` (Write Recovery Config)
**What:** Auto-creates standby configuration  
**Creates:**
- `standby.signal` file (marks as standby)
- `postgresql.auto.conf` (connection info)

**Without `-R`, you must manually create:**
```bash
# Manual way (DON'T DO THIS if you use -R):
touch /var/lib/postgresql/data/standby.signal
echo "primary_conninfo = 'host=primary user=replicator'" >> postgresql.auto.conf
```

**Recommendation:** **Always use `-R`!** It saves manual work.

### 5. `-X stream` (Stream WAL)
**What:** Streams WAL changes during backup  
**Why:** Ensures consistency even for long-running backups  
**Alternative:** `-X fetch` (less safe)  
**Recommendation:** **Always use `-X stream`**

### 6. `-P` (Progress)
**What:** Shows progress percentage  
**Output:**
```
230450/230450 kB (100%), 1/1 tablespace
```
**Useful for:** Large databases (know how long to wait)

### 7. `-v` (Verbose)
**What:** Detailed output  
**Shows:** Each step being performed  
**Useful for:** Debugging issues

---

## 🆚 MySQL Comparison

### PostgreSQL (ONE command):
```bash
pg_basebackup -h primary -D /data -U replicator -R
# Done! Start PostgreSQL and it's a replica.
```

### MySQL (FOUR steps):
```bash
# Step 1: Dump data
mysqldump --all-databases --master-data=2 > backup.sql

# Step 2: Transfer to replica
scp backup.sql replica:/tmp/

# Step 3: Restore on replica
mysql < backup.sql

# Step 4: Configure replication
mysql> CHANGE MASTER TO 
       MASTER_HOST='primary',
       MASTER_USER='replicator',
       MASTER_PASSWORD='password',
       MASTER_LOG_FILE='mysql-bin.000001',
       MASTER_LOG_POS=12345;
mysql> START SLAVE;
```

**Key Differences:**

| Aspect | PostgreSQL | MySQL |
|--------|------------|-------|
| **Commands** | 1 | 4+ |
| **Manual config** | No (with `-R`) | Yes |
| **Consistency** | Automatic | Manual (need exact position) |
| **Ease** | Very easy | More complex |
| **Error-prone** | Low | Higher (manual steps) |

---

## 🎓 Complete Setup Workflow

### Prerequisites (on Primary):

1. **Enable replication in postgresql.conf:**
```sql
wal_level = replica
max_wal_senders = 10
```

2. **Create replication user:**
```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'password';
```

3. **Allow replication connections in pg_hba.conf:**
```
host replication replicator 0.0.0.0/0 md5
```

4. **Reload configuration:**
```sql
SELECT pg_reload_conf();
```

### Creating Standby:

```bash
# ONE command does everything:
pg_basebackup -h primary-host \
              -D /var/lib/postgresql/data \
              -U replicator \
              -P -v -X stream -R

# Start PostgreSQL
pg_ctl start -D /var/lib/postgresql/data

# Verify it's a standby
psql -c "SELECT pg_is_in_recovery();"
# Should return 't' (true)
```

**That's it!** Streaming replication is now active.

---

## 🔍 What `pg_basebackup` Does Internally

### Step 1: Connect to Primary
```
Connects using: host=primary user=replicator
```

### Step 2: Start Backup Session
```sql
-- Primary executes:
SELECT pg_start_backup('pg_basebackup', false, false);
```

### Step 3: Copy All Data
```
Copies:
- base/ (database files)
- global/ (shared objects)
- pg_wal/ (WAL files)
- All other PostgreSQL data
```

### Step 4: Stream WAL (if `-X stream`)
```
While copying:
- Streams WAL changes in parallel
- Ensures consistency
- No gap in WAL
```

### Step 5: Finish Backup
```sql
-- Primary executes:
SELECT pg_stop_backup(false, true);
```

### Step 6: Create Standby Config (if `-R`)
```bash
# Creates:
/var/lib/postgresql/data/standby.signal

# Writes to:
/var/lib/postgresql/data/postgresql.auto.conf:
  primary_conninfo = 'host=primary user=replicator'
```

**All automatic!**

---

## 🚨 Common Issues

### Issue 1: "Directory not empty"

**Error:**
```
pg_basebackup: error: directory "/var/lib/postgresql/data" exists but is not empty
```

**Solution:**
```bash
# Clean directory first
rm -rf /var/lib/postgresql/data/*

# OR specify different directory
pg_basebackup -D /var/lib/postgresql/data_new ...
```

---

### Issue 2: "No pg_hba.conf entry"

**Error:**
```
FATAL: no pg_hba.conf entry for replication connection
```

**Solution on Primary:**
```bash
# Add to pg_hba.conf:
echo "host replication replicator 0.0.0.0/0 md5" >> pg_hba.conf

# Reload:
SELECT pg_reload_conf();
```

---

### Issue 3: "Role does not exist"

**Error:**
```
FATAL: role "replicator" does not exist
```

**Solution on Primary:**
```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'your_password';
```

---

### Issue 4: "Permission denied"

**Error:**
```
FATAL: must be superuser or replication role
```

**Solution:**
```sql
ALTER ROLE replicator WITH REPLICATION;
```

---

## 📋 Quick Reference Card

### Minimal Command:
```bash
pg_basebackup -h primary -D /data -U replicator -R
```

### Recommended Command:
```bash
pg_basebackup -h primary -D /data -U replicator -v -P -X stream -R
```

### With Password (for scripts):
```bash
PGPASSWORD='password' pg_basebackup -h primary -D /data -U replicator -R
```

### Over Network:
```bash
pg_basebackup -h 192.168.1.100 -p 5432 -D /data -U replicator -R
```

### With Compression (PostgreSQL 15+):
```bash
pg_basebackup -h primary -D /data -U replicator -R --compress=gzip
```

---

## ✅ Verification After pg_basebackup

### 1. Check files created:
```bash
ls -la /var/lib/postgresql/data/

# Should see:
# - standby.signal (marks as standby)
# - postgresql.auto.conf (connection info)
# - base/ (database files)
# - pg_wal/ (WAL files)
```

### 2. Check standby.signal:
```bash
test -f /var/lib/postgresql/data/standby.signal && echo "Standby configured ✓"
```

### 3. Check connection info:
```bash
cat /var/lib/postgresql/data/postgresql.auto.conf

# Should contain:
# primary_conninfo = 'host=primary user=replicator ...'
```

### 4. Start and verify:
```bash
# Start PostgreSQL
pg_ctl start -D /var/lib/postgresql/data

# Check it's in recovery (standby mode)
psql -c "SELECT pg_is_in_recovery();"
# Expected: t (true)

# Check replication status
psql -c "SELECT status FROM pg_stat_wal_receiver;"
# Expected: streaming
```

---

## 🎯 Summary

**The primary command for streaming replication:**

```bash
pg_basebackup
```

**Typical usage:**
```bash
pg_basebackup -h primary_host \
              -D /data_directory \
              -U replication_user \
              -R
```

**What it does:**
- Copies entire database from primary
- Configures standby automatically (with `-R`)
- One command replaces MySQL's 4+ step process
- Safe, atomic, and consistent

**Key takeaway for MySQL DBAs:**
- PostgreSQL: `pg_basebackup` = mysqldump + scp + CHANGE MASTER + config
- Everything in ONE command!
- Much simpler and less error-prone

---

*Document created: November 16, 2025*  
*Purpose: Explain the primary command for PostgreSQL streaming replication*  
*For: MySQL DBAs learning PostgreSQL*
