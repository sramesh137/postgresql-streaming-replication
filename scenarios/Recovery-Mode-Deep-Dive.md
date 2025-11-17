# How pg_is_in_recovery() Works: The Magic of standby.signal

**Key Questions Answered:**
1. Does `pg_is_in_recovery()` happen by default when enabling streaming replication?
2. Is this what prevents writes on standby?

**Short Answers:**
1. ✅ **YES** - Automatically triggered by `standby.signal` file
2. ✅ **YES** - This is THE mechanism that blocks writes

---

## 🎯 The Single File That Controls Everything

### The `standby.signal` File

**Location:** `/var/lib/postgresql/data/standby.signal`

**Content:** Usually empty (zero bytes)

**Effect:** When PostgreSQL starts and finds this file → **ENTERS RECOVERY MODE**

```bash
# Check if file exists:
ls -la /var/lib/postgresql/data/standby.signal
# -rw------- 1 postgres root 0 Nov 16 12:54 standby.signal

# Content (usually empty):
cat /var/lib/postgresql/data/standby.signal
# (empty - no output)
```

**This tiny file is the KEY to streaming replication!**

---

## 🔄 How Streaming Replication Starts (Step by Step)

### Method 1: Using pg_basebackup with -R flag

```bash
# Take base backup with replication config
pg_basebackup -h primary -U replicator -D /data -R

# The -R flag does TWO things:
# 1. Creates standby.signal file (empty file)
# 2. Adds primary_conninfo to postgresql.auto.conf
```

**What happens:**

```
1. pg_basebackup copies data from primary → standby
   ✓ Data files copied
   ✓ Configuration copied
   
2. -R flag creates standby.signal
   ✓ File: /data/standby.signal (0 bytes)
   
3. -R flag writes primary_conninfo
   ✓ File: /data/postgresql.auto.conf
   ✓ Content: primary_conninfo = 'host=primary user=replicator ...'
   
4. Start PostgreSQL server
   ✓ Reads standby.signal
   ✓ Enters recovery mode automatically
   ✓ pg_is_in_recovery() returns TRUE
   ✓ Connects to primary using primary_conninfo
   ✓ Starts streaming WAL
```

**Timeline:**
```
pg_basebackup -R
   ↓
standby.signal created
   ↓
Start PostgreSQL
   ↓
Sees standby.signal
   ↓
Enters RECOVERY MODE
   ↓
pg_is_in_recovery() = TRUE
   ↓
Blocks all writes ✓
```

---

### Method 2: Manual Configuration (Old Way, PostgreSQL < 12)

**PostgreSQL 11 and earlier used `recovery.conf`:**

```bash
# Old method (pre-PostgreSQL 12):
# File: recovery.conf
standby_mode = on
primary_conninfo = 'host=primary user=replicator ...'
```

**PostgreSQL 12+ simplified this:**
- Removed `recovery.conf`
- Replaced with `standby.signal` (simpler!)
- Replication settings moved to `postgresql.auto.conf`

**Current method (PostgreSQL 12+):**

```bash
# 1. Take base backup (without -R)
pg_basebackup -h primary -U replicator -D /data

# 2. Manually create standby.signal
touch /data/standby.signal

# 3. Manually configure primary_conninfo
echo "primary_conninfo = 'host=primary user=replicator password=xxx'" >> /data/postgresql.auto.conf

# 4. Start server
pg_ctl start -D /data
```

---

## 🧪 Live Demonstration: What Happens Without standby.signal?

### Test 1: Remove standby.signal

```bash
# 1. Stop standby
docker stop postgres-standby

# 2. Remove standby.signal file
docker run --rm -v standby-data:/data postgres:15 rm /data/standby.signal

# 3. Start standby
docker start postgres-standby
sleep 3

# 4. Check recovery mode
docker exec postgres-standby psql -U postgres -c "SELECT pg_is_in_recovery();"
```

**Result:**
```
 pg_is_in_recovery 
-------------------
 f                    ← FALSE! Not in recovery mode!
(1 row)
```

**What happened?**
- PostgreSQL started normally
- Did NOT enter recovery mode
- Became a **PRIMARY** (standalone server)
- **Accepts writes!**

```bash
# 5. Try to write (will succeed!)
docker exec postgres-standby psql -U postgres -c \
  "INSERT INTO products (name) VALUES ('Written without recovery') RETURNING id, name;"
```

**Result:**
```
  id   |             name              
-------+-------------------------------
 10036 | Written without recovery
(1 row)

INSERT 0 1          ← SUCCESS! ⚠️ This is dangerous!
```

**Why is this dangerous?**
- Server thinks it's a primary
- Accepts writes
- But data diverges from real primary
- **SPLIT-BRAIN scenario!**

---

### Test 2: Restore standby.signal

```bash
# 1. Stop server
docker stop postgres-standby

# 2. Rebuild with pg_basebackup -R (creates standby.signal automatically)
pg_basebackup -h primary -U replicator -D /data -R

# 3. Verify standby.signal exists
ls -la /data/standby.signal
# -rw------- 1 postgres root 0 Nov 16 13:23 /data/standby.signal

# 4. Start server
docker start postgres-standby
sleep 3

# 5. Check recovery mode
docker exec postgres-standby psql -U postgres -c "SELECT pg_is_in_recovery();"
```

**Result:**
```
 pg_is_in_recovery 
-------------------
 t                    ← TRUE! Back in recovery mode!
(1 row)
```

**What happened?**
- PostgreSQL found `standby.signal`
- Entered recovery mode automatically
- Connected to primary (using `primary_conninfo`)
- Started streaming WAL
- **Blocks all writes!**

```bash
# 6. Try to write (will fail)
docker exec postgres-standby psql -U postgres -c \
  "INSERT INTO products (name) VALUES ('Should fail');"
```

**Result:**
```
ERROR:  cannot execute INSERT in a read-only transaction
```

**Perfect! Write protection restored!** ✓

---

## 📊 Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│              STREAMING REPLICATION SETUP                │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
         ┌─────────────────────────────────┐
         │  pg_basebackup -R               │
         │  (or manual setup)              │
         └─────────────────────────────────┘
                           │
        ┌──────────────────┴────────────────────┐
        │                                       │
        ▼                                       ▼
┌─────────────────┐                 ┌─────────────────────┐
│ standby.signal  │                 │ postgresql.auto.conf│
│ (created)       │                 │ primary_conninfo=   │
└─────────────────┘                 └─────────────────────┘
        │                                       │
        └──────────────────┬────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │  Start PostgreSQL      │
              └────────────────────────┘
                           │
                           ▼
       ┌────────────────────────────────────┐
       │  PostgreSQL startup checks:        │
       │  1. Is standby.signal present?     │
       │     YES → Go to step 2             │
       │     NO  → Start as PRIMARY         │
       └────────────────────────────────────┘
                           │
                           ▼ (YES)
       ┌────────────────────────────────────┐
       │  2. Enter RECOVERY MODE            │
       │     - Set pg_is_in_recovery() = t  │
       │     - Enable write blocking        │
       │     - Enable WAL replay            │
       └────────────────────────────────────┘
                           │
                           ▼
       ┌────────────────────────────────────┐
       │  3. Read primary_conninfo          │
       │     from postgresql.auto.conf      │
       └────────────────────────────────────┘
                           │
                           ▼
       ┌────────────────────────────────────┐
       │  4. Connect to primary             │
       │     using primary_conninfo         │
       └────────────────────────────────────┘
                           │
                           ▼
       ┌────────────────────────────────────┐
       │  5. Start streaming WAL            │
       │     - Request WAL from primary     │
       │     - Replay WAL continuously      │
       └────────────────────────────────────┘
                           │
                           ▼
       ┌────────────────────────────────────┐
       │  STANDBY MODE ACTIVE               │
       │  ✓ pg_is_in_recovery() = TRUE      │
       │  ✓ Writes blocked                  │
       │  ✓ Reads allowed (hot_standby=on)  │
       │  ✓ WAL streaming active            │
       └────────────────────────────────────┘
```

---

## 🔍 Behind the Scenes: What PostgreSQL Does

### When standby.signal is Present:

```c
// PostgreSQL startup code (simplified):

if (file_exists("standby.signal")) {
    InRecovery = true;           // Set recovery mode flag
    StandbyMode = true;          // Enable standby features
    
    // Block all write operations:
    PreventCommandIfReadOnly("INSERT");
    PreventCommandIfReadOnly("UPDATE");
    PreventCommandIfReadOnly("DELETE");
    PreventCommandIfReadOnly("CREATE");
    PreventCommandIfReadOnly("DROP");
    // ... all DDL and DML blocked
    
    // Start WAL receiver:
    primary_conninfo = read_config("primary_conninfo");
    StartWalReceiver(primary_conninfo);
    
    // Start WAL replay:
    StartWalReplayer();
}
```

### Function: pg_is_in_recovery()

```c
// Returns the InRecovery flag
bool pg_is_in_recovery(void) {
    return InRecovery;  // Set to true if standby.signal exists
}
```

**This flag is checked before EVERY write operation!**

```c
// Before executing any write:
if (pg_is_in_recovery()) {
    ereport(ERROR,
        (errcode(ERRCODE_READ_ONLY_SQL_TRANSACTION),
         errmsg("cannot execute %s in a read-only transaction", 
                query_type)));
}
```

---

## 🛡️ How This Protects Your Standby

### Protection Layers:

```
┌────────────────────────────────────────────────┐
│ Layer 1: standby.signal file presence         │ ← File system level
│          (If missing → PRIMARY mode)           │
└────────────────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────────┐
│ Layer 2: Recovery mode flag (InRecovery)      │ ← Process level
│          (Set during startup)                  │
└────────────────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────────┐
│ Layer 3: SQL command validation                │ ← Query execution level
│          (Checks before every write)           │
└────────────────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────────┐
│ Layer 4: Transaction state enforcement        │ ← Transaction level
│          (Forces read-only transactions)       │
└────────────────────────────────────────────────┘
```

**All four layers must pass for a write to succeed!**

---

## 📋 Summary Table: standby.signal Effect

| Scenario | standby.signal | pg_is_in_recovery() | Writes | Replication |
|----------|---------------|---------------------|--------|-------------|
| **Normal standby** | ✅ Present | TRUE (t) | ❌ Blocked | ✅ Active |
| **No signal file** | ❌ Missing | FALSE (f) | ✅ Allowed | ❌ Inactive |
| **After pg_promote()** | ❌ Deleted by PostgreSQL | FALSE (f) | ✅ Allowed | ❌ Becomes primary |
| **Manual standby setup** | ✅ Created manually | TRUE (t) | ❌ Blocked | ✅ Active |

---

## 🎓 Answer to Your Questions

### Q1: "Does pg_is_in_recovery() happen by default when enabling streaming replication?"

**Answer:** ✅ **YES, automatically!**

**How it happens:**

1. You run: `pg_basebackup -R` (or create `standby.signal` manually)
2. PostgreSQL starts
3. Sees `standby.signal` file
4. **Automatically enters recovery mode**
5. `pg_is_in_recovery()` returns `TRUE`

**No manual intervention needed!** The `-R` flag in `pg_basebackup` does everything.

---

### Q2: "Does this help prevent writes on standby?"

**Answer:** ✅ **YES, this IS the mechanism!**

**How it prevents writes:**

```
standby.signal present
   ↓
Recovery mode enabled
   ↓
pg_is_in_recovery() = TRUE
   ↓
Every write command checked:
   ↓
if (pg_is_in_recovery()) {
    BLOCK WRITE ← This happens!
}
```

**This is THE core protection mechanism in PostgreSQL replication!**

---

## 💡 MySQL vs PostgreSQL: Recovery Mode Comparison

| Aspect | PostgreSQL | MySQL |
|--------|------------|-------|
| **Trigger mechanism** | `standby.signal` file | Manual `read_only = 1` |
| **Automatic?** | ✅ YES (via `pg_basebackup -R`) | ❌ NO (must configure) |
| **Protection level** | 🛡️ **STRONGEST** (recovery mode) | ⚠️ Moderate (setting) |
| **Can bypass?** | ❌ NO (must promote to primary) | ✅ YES (SUPER users can write) |
| **How to check?** | `SELECT pg_is_in_recovery();` | `SHOW VARIABLES LIKE 'read_only';` |
| **Setup complexity** | 🟢 Simple (one command) | 🟡 Manual (multiple configs) |

**Key difference:**
- **PostgreSQL:** State-based (recovery mode vs primary mode)
- **MySQL:** Setting-based (read_only variable)

**PostgreSQL's approach is more robust!**

---

## 🔧 Practical Commands Reference

### Check if standby.signal exists:
```bash
ls -la /var/lib/postgresql/data/standby.signal
```

### Check recovery status:
```sql
SELECT pg_is_in_recovery();
-- Returns: 't' (standby) or 'f' (primary)
```

### Create standby manually:
```bash
# 1. Take base backup
pg_basebackup -h primary -U replicator -D /data

# 2. Create standby.signal (empty file)
touch /data/standby.signal

# 3. Configure primary connection
echo "primary_conninfo = 'host=primary user=replicator password=xxx'" >> /data/postgresql.auto.conf

# 4. Start server (will enter recovery mode automatically)
pg_ctl start -D /data
```

### Remove standby mode (promote to primary):
```sql
SELECT pg_promote();
-- This deletes standby.signal and exits recovery mode
```

### Verify replication is active:
```sql
-- On primary:
SELECT * FROM pg_stat_replication;

-- On standby:
SELECT * FROM pg_stat_wal_receiver;
```

---

## 🚨 Common Mistakes and How to Avoid

### Mistake 1: Forgetting -R flag in pg_basebackup

```bash
# ❌ Wrong (no standby.signal created):
pg_basebackup -h primary -U replicator -D /data

# Server starts as PRIMARY (accepts writes!)

# ✅ Correct (creates standby.signal automatically):
pg_basebackup -h primary -U replicator -D /data -R

# Server starts as STANDBY (blocks writes)
```

---

### Mistake 2: Accidentally deleting standby.signal

```bash
# Server was standby, someone runs:
rm /var/lib/postgresql/data/standby.signal

# After restart → becomes PRIMARY! (split-brain risk!)

# Solution: Always use pg_basebackup -R to rebuild
```

---

### Mistake 3: Promoting without intention

```bash
# Someone runs:
SELECT pg_promote();

# standby.signal gets deleted automatically
# Server becomes PRIMARY (accepts writes)
# Original primary still running → SPLIT-BRAIN!

# Solution: Coordinate failover carefully
```

---

## 🎯 Key Takeaways

1. ✅ **`standby.signal` file is the KEY** to streaming replication
2. ✅ **`pg_basebackup -R`** creates it automatically
3. ✅ **Recovery mode is triggered automatically** when file exists
4. ✅ **`pg_is_in_recovery() = TRUE`** means write protection active
5. ✅ **No manual configuration needed** for write blocking
6. ✅ **More secure than MySQL** (automatic protection)

**Bottom line:** PostgreSQL's recovery mode is a **built-in safety mechanism** that protects your standby from accidental writes. It's enabled automatically when you set up streaming replication properly!

---

*Document created: November 16, 2025*  
*Purpose: Explain how pg_is_in_recovery() and standby.signal work together*  
*For: MySQL DBAs learning PostgreSQL replication internals*
