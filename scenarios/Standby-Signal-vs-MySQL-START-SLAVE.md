# PostgreSQL Standby Setup: standby.signal vs MySQL's START SLAVE

**Your Question:**
- "Does `standby.signal` happen based on `is_standby` flag?"
- "Where is the configuration that makes `is_standby`?"
- "In MySQL we run START SLAVE, what's the PostgreSQL equivalent?"

**Short Answer:**
- ❌ **NO!** You have it reversed!
- ✅ **`standby.signal` FILE creates the standby mode**, not a config variable
- ✅ PostgreSQL has **NO equivalent to START SLAVE** - it's automatic!

---

## 🎯 The Critical Difference: Cause vs Effect

### Your Understanding (Incorrect):
```
is_standby = true (config)
    ↓
Creates standby.signal file
    ↓
Server becomes standby
```

### Actual Reality (Correct):
```
standby.signal file EXISTS
    ↓
PostgreSQL enters recovery mode
    ↓
pg_is_in_recovery() returns TRUE
    ↓
Server IS standby
```

**Key insight:** `standby.signal` is the **CAUSE**, not the **EFFECT**!

---

## 📁 There is NO `is_standby` Configuration Variable!

### What Doesn't Exist in PostgreSQL:

```sql
-- ❌ DOES NOT EXIST:
SHOW is_standby;
-- ERROR: unrecognized configuration parameter "is_standby"

-- ❌ DOES NOT EXIST:
ALTER SYSTEM SET is_standby = on;
-- ERROR: unrecognized configuration parameter "is_standby"

-- ❌ DOES NOT EXIST in postgresql.conf:
is_standby = on
-- This setting doesn't exist!
```

### What Actually Exists:

```sql
-- ✅ This is a FUNCTION (not a setting):
SELECT pg_is_in_recovery();
-- Returns: 't' or 'f'

-- This function READS the server's current state
-- It does NOT SET the state
```

**Comparison:**
- `SHOW max_connections;` → Configuration setting (can be changed)
- `SELECT pg_is_in_recovery();` → Status function (reports current state)

---

## 🔧 How to Make a Server a Standby (PostgreSQL vs MySQL)

### MySQL Method (Manual, Multi-Step):

```sql
-- Step 1: Stop replication (if running)
STOP SLAVE;

-- Step 2: Configure replication connection
CHANGE MASTER TO
  MASTER_HOST='primary',
  MASTER_USER='replicator',
  MASTER_PASSWORD='password',
  MASTER_LOG_FILE='mysql-bin.000123',
  MASTER_LOG_POS=456789;

-- Step 3: START REPLICATION (the key command!)
START SLAVE;

-- Step 4: Check status
SHOW SLAVE STATUS\G
```

**Important:** In MySQL, replication is **OFF by default** after restore.  
You **MUST run `START SLAVE`** to begin replication.

---

### PostgreSQL Method (Automatic, File-Based):

```bash
# Step 1: Take base backup with -R flag
pg_basebackup -h primary -U replicator -D /data -R

# That's it! No START SLAVE equivalent needed!

# What -R does:
# 1. Creates standby.signal file (empty, 0 bytes)
# 2. Writes primary_conninfo to postgresql.auto.conf
```

**What happens when you start PostgreSQL:**

```bash
# Start server
pg_ctl start -D /data

# PostgreSQL startup process:
1. Checks: Does standby.signal file exist?
   YES → Enter standby mode automatically
   NO  → Start as primary

2. If standby mode:
   - Reads primary_conninfo from postgresql.auto.conf
   - Connects to primary automatically
   - Starts streaming WAL automatically
   - No manual START command needed!
```

**Important:** In PostgreSQL, replication is **AUTOMATIC** after restore with `-R`.  
**NO manual start command needed!**

---

## 📊 Live Demonstration: How It Actually Works

### Check Configuration Files:

```bash
# 1. Check postgresql.conf (main config)
docker exec postgres-standby grep -i "is_standby\|standby_mode" \
  /var/lib/postgresql/data/postgresql.conf

# Result: (empty - NO such settings exist!)
```

```bash
# 2. Check postgresql.auto.conf (automatic config)
docker exec postgres-standby cat /var/lib/postgresql/data/postgresql.auto.conf

# Result:
primary_conninfo = 'user=replicator password=xxx host=postgres-primary ...'
wal_log_hints = 'on'
# Note: NO is_standby setting!
```

```bash
# 3. Check for standby.signal file
docker exec postgres-standby ls -la /var/lib/postgresql/data/standby.signal

# Result:
-rw------- 1 postgres root 0 Nov 16 13:23 standby.signal
# ^ This file makes it a standby!
```

```bash
# 4. Check file content
docker exec postgres-standby cat /var/lib/postgresql/data/standby.signal

# Result: (empty file - 0 bytes)
# The FILE EXISTENCE is what matters, not content!
```

---

### What Triggers Standby Mode:

```bash
# Start PostgreSQL server
pg_ctl start -D /data

# PostgreSQL checks on startup:
if [ -f "/data/standby.signal" ]; then
    echo "standby.signal found → Enter recovery mode"
    InRecovery=true
    StartWALReceiver()
    StartWALReplay()
else
    echo "standby.signal not found → Start as primary"
    InRecovery=false
    AcceptWrites()
fi
```

**Proof from logs:**

```bash
# Check standby startup logs
docker logs postgres-standby --tail 20 | grep -i "standby mode"

# Output:
2025-11-16 13:40:48.737 UTC [28] LOG:  entering standby mode
```

**"entering standby mode"** happens because PostgreSQL **found standby.signal file**!

---

## 🔄 MySQL vs PostgreSQL: Starting Replication

### MySQL: Manual START SLAVE

```sql
-- Configuration (static):
[mysqld]
server_id = 2
relay_log = /var/lib/mysql/relay-log
read_only = 1

-- Connection setup (dynamic):
CHANGE MASTER TO
  MASTER_HOST='primary',
  MASTER_USER='replicator',
  MASTER_PASSWORD='password';

-- START REPLICATION (REQUIRED):
START SLAVE;  ← Must run this command!

-- Without START SLAVE:
-- - Replica does NOT connect to primary
-- - Replica does NOT receive binlog
-- - Replication is OFF
```

**Key characteristics:**
- ✅ Explicit control (manual start/stop)
- ⚠️ Easy to forget to start
- ⚠️ Replication OFF by default after restore

---

### PostgreSQL: Automatic Startup

```bash
# File-based configuration:
# File 1: standby.signal (empty file)
# File 2: postgresql.auto.conf (contains primary_conninfo)

# Start server:
pg_ctl start -D /data

# Automatic behavior:
# 1. Finds standby.signal → Enters standby mode
# 2. Reads primary_conninfo → Connects to primary
# 3. Starts WAL streaming → Replication active
# NO manual command needed! ✓
```

**Key characteristics:**
- ✅ Automatic (no manual start needed)
- ✅ Cannot forget (file-based)
- ✅ Replication ON by default after restore with -R

---

## 📋 Complete Comparison Table

| Aspect | MySQL | PostgreSQL |
|--------|-------|------------|
| **Replica/Standby trigger** | `START SLAVE` command | `standby.signal` file |
| **Configuration** | `CHANGE MASTER TO` | `primary_conninfo` in postgresql.auto.conf |
| **Start replication** | **Manual** (`START SLAVE`) | **Automatic** (on startup) |
| **Stop replication** | `STOP SLAVE` | Remove `standby.signal` + restart |
| **Check status** | `SHOW SLAVE STATUS` | `SELECT * FROM pg_stat_wal_receiver` |
| **After restore** | Must run `START SLAVE` | Automatically starts if `-R` used |
| **Is it a replica/standby?** | Check `Slave_IO_Running` | Check `pg_is_in_recovery()` |
| **Control file** | None (command-based) | `standby.signal` (file-based) |
| **Read-only enforcement** | `read_only = 1` (manual) | Recovery mode (automatic) |

---

## 🎯 The Exact Flow: PostgreSQL Standby Setup

### Step-by-Step with Files:

```
Step 1: Run pg_basebackup
┌────────────────────────────────────────┐
│ pg_basebackup -h primary -U replicator│
│               -D /data -R              │
└────────────────────────────────────────┘
                 │
                 ▼
Step 2: What -R flag creates
┌────────────────────────────────────────┐
│ File 1: /data/standby.signal          │
│         (empty file, 0 bytes)          │
│                                        │
│ File 2: /data/postgresql.auto.conf    │
│         primary_conninfo = 'host=...' │
└────────────────────────────────────────┘
                 │
                 ▼
Step 3: Start PostgreSQL
┌────────────────────────────────────────┐
│ pg_ctl start -D /data                  │
└────────────────────────────────────────┘
                 │
                 ▼
Step 4: PostgreSQL startup checks
┌────────────────────────────────────────┐
│ if (standby.signal exists):            │
│   ✓ Enter recovery mode                │
│   ✓ Set InRecovery = true              │
│   ✓ Read primary_conninfo              │
│   ✓ Connect to primary                 │
│   ✓ Start WAL receiver                 │
│   ✓ Start WAL replay                   │
└────────────────────────────────────────┘
                 │
                 ▼
Step 5: Replication active
┌────────────────────────────────────────┐
│ ✓ pg_is_in_recovery() = TRUE           │
│ ✓ Streaming WAL from primary           │
│ ✓ Replaying WAL automatically          │
│ ✓ Writes blocked                       │
│ ✓ NO manual START command needed!      │
└────────────────────────────────────────┘
```

**Compare with MySQL:**

```
Step 1: Restore backup
┌────────────────────────────────────────┐
│ mysql < backup.sql                     │
└────────────────────────────────────────┘
                 │
                 ▼
Step 2: Configure replication
┌────────────────────────────────────────┐
│ CHANGE MASTER TO                       │
│   MASTER_HOST='primary',               │
│   MASTER_USER='replicator',            │
│   MASTER_LOG_FILE='...',               │
│   MASTER_LOG_POS=...;                  │
└────────────────────────────────────────┘
                 │
                 ▼
Step 3: Start replication manually
┌────────────────────────────────────────┐
│ START SLAVE;  ← REQUIRED!              │
└────────────────────────────────────────┘
                 │
                 ▼
Step 4: Replication active
┌────────────────────────────────────────┐
│ ✓ Slave_IO_Running: Yes                │
│ ✓ Slave_SQL_Running: Yes               │
│ ✓ Receiving binlog from primary        │
│ ✓ Replaying binlog                     │
└────────────────────────────────────────┘
```

**Key difference:** PostgreSQL = **Automatic**, MySQL = **Manual**

---

## 🔍 Common Misconceptions Clarified

### Misconception 1: "There's an is_standby config"
**Reality:** ❌ No such config exists. Only `standby.signal` file.

### Misconception 2: "Need to run a command like START SLAVE"
**Reality:** ❌ No command needed. Automatic on startup if `standby.signal` exists.

### Misconception 3: "standby.signal is created by a config setting"
**Reality:** ❌ Reversed! The file creates the mode, not vice versa.

### Misconception 4: "pg_is_in_recovery() is a setting I can change"
**Reality:** ❌ It's a read-only function that reports current state.

### Misconception 5: "Must manually start replication like MySQL"
**Reality:** ❌ PostgreSQL starts automatically. Much simpler!

---

## 💡 What IS Configured (Actual Settings)

### Files That Matter:

#### 1. `standby.signal` (Standby Mode Trigger)
```bash
# Location:
/var/lib/postgresql/data/standby.signal

# Content:
(empty file - 0 bytes)

# Purpose:
Tells PostgreSQL to enter standby mode on startup

# Created by:
pg_basebackup -R
# or manually: touch standby.signal
```

---

#### 2. `postgresql.auto.conf` (Replication Connection)
```bash
# Location:
/var/lib/postgresql/data/postgresql.auto.conf

# Content:
primary_conninfo = 'user=replicator password=xxx host=primary port=5432 ...'

# Purpose:
Tells standby how to connect to primary

# Created by:
pg_basebackup -R
# or manually: echo "primary_conninfo = '...'" >> postgresql.auto.conf
```

---

#### 3. `postgresql.conf` (Optional Settings)
```bash
# Location:
/var/lib/postgresql/data/postgresql.conf

# Relevant settings:
hot_standby = on                 # Allow read queries on standby
wal_level = replica              # Enable WAL for replication
max_wal_senders = 10             # Max standby connections (on primary)
wal_log_hints = on               # Enable for pg_rewind

# Note: NONE of these "make it a standby"
# They only affect HOW standby works
# standby.signal is what MAKES it a standby
```

---

## 🎓 Answering Your Specific Questions

### Q1: "Does standby.signal happen based on is_standby flag?"

**Answer:** ❌ **NO, completely reversed!**

**Correct flow:**
```
standby.signal file exists
    ↓
PostgreSQL enters standby mode
    ↓
pg_is_in_recovery() function returns TRUE
    ↓
You can check "is it a standby?" with this function
```

**There is NO `is_standby` configuration variable!**

---

### Q2: "Where is the configuration that makes is_standby?"

**Answer:** There is **NO configuration variable** called `is_standby`.

**What actually makes a server a standby:**
1. ✅ **File:** `standby.signal` exists in data directory
2. ✅ **Config:** `primary_conninfo` set (where to connect)
3. ✅ **That's it!** Just these two things.

**No setting to toggle, no command to run!**

---

### Q3: "In MySQL we run START SLAVE, what's the PostgreSQL equivalent?"

**Answer:** There is **NO equivalent!** PostgreSQL is **automatic**.

**MySQL way:**
```sql
-- Must manually start:
START SLAVE;

-- Must manually stop:
STOP SLAVE;
```

**PostgreSQL way:**
```bash
# Replication starts automatically on server startup if:
# 1. standby.signal exists
# 2. primary_conninfo is set

# To stop replication:
# Remove standby.signal and restart
# Or promote to primary: SELECT pg_promote();
```

**PostgreSQL is MORE AUTOMATED than MySQL!**

---

## 🔧 Practical Examples

### Example 1: Make a Server a Standby (PostgreSQL)

```bash
# Simple way (automatic):
pg_basebackup -h primary -U replicator -D /data -R
pg_ctl start -D /data
# Done! Replication active automatically!

# Manual way (more control):
# 1. Take base backup
pg_basebackup -h primary -U replicator -D /data

# 2. Create standby.signal
touch /data/standby.signal

# 3. Set primary_conninfo
echo "primary_conninfo = 'host=primary user=replicator password=xxx'" >> \
  /data/postgresql.auto.conf

# 4. Start server
pg_ctl start -D /data
# Replication starts automatically!
```

---

### Example 2: Make a Server a Standby (MySQL)

```bash
# 1. Restore backup
mysql < backup.sql

# 2. Configure my.cnf
cat >> /etc/mysql/my.cnf <<EOF
server_id = 2
read_only = 1
log_bin = /var/lib/mysql/mysql-bin
relay_log = /var/lib/mysql/relay-log
EOF

# 3. Restart MySQL
systemctl restart mysql

# 4. Configure replication
mysql -e "CHANGE MASTER TO \
  MASTER_HOST='primary', \
  MASTER_USER='replicator', \
  MASTER_PASSWORD='password', \
  MASTER_LOG_FILE='mysql-bin.000123', \
  MASTER_LOG_POS=456789;"

# 5. START REPLICATION (REQUIRED!)
mysql -e "START SLAVE;"

# 6. Check status
mysql -e "SHOW SLAVE STATUS\G"
```

**PostgreSQL = 2 steps, MySQL = 6 steps!**

---

## 📊 Summary: Key Takeaways

1. ✅ **NO `is_standby` configuration variable exists** in PostgreSQL
2. ✅ **`standby.signal` FILE makes a server a standby**, not a config setting
3. ✅ **`pg_is_in_recovery()` is a STATUS FUNCTION**, not a configuration
4. ✅ **NO PostgreSQL equivalent to `START SLAVE`** - it's automatic!
5. ✅ **PostgreSQL is SIMPLER** than MySQL (file-based vs command-based)
6. ✅ **Replication starts automatically** when server starts with `standby.signal`

**Bottom line:** PostgreSQL uses a **file-based** approach (simpler) vs MySQL's **command-based** approach (more manual steps).

---

## 🎯 Mental Model for MySQL DBAs

**MySQL mindset (command-based):**
```
Configuration → START SLAVE command → Replication active
```

**PostgreSQL mindset (file-based):**
```
standby.signal file exists → Server starts → Replication active automatically
```

**Think of it this way:**
- MySQL: "Do you want to start replication?" (ask permission)
- PostgreSQL: "I see standby.signal, I'll start replication!" (automatic)

**PostgreSQL is more like "convention over configuration"** - the presence of a file automatically triggers behavior!

---

*Document created: November 16, 2025*  
*Purpose: Clarify standby.signal vs configuration settings, compare with MySQL's START SLAVE*  
*For: MySQL DBAs learning PostgreSQL's file-based replication control*
