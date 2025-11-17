# Visual Guide: How pg_basebackup Copies PRIMARY → STANDBY

**Your Understanding:** ✅ **CORRECT!**  
"We are doing pg_basebackup of primary and pushing it to the standby server"

---

## 🎯 Yes! Here's Exactly What Happens:

```
┌─────────────────────────────────────────────────────────────┐
│                    BEFORE pg_basebackup                     │
└─────────────────────────────────────────────────────────────┘

    PRIMARY SERVER                      STANDBY SERVER
  ┌──────────────────┐                ┌──────────────────┐
  │ postgres-primary │                │ postgres-standby │
  │                  │                │                  │
  │ /data/           │                │ /data/           │
  │  ├── base/       │  ─────────────▶│  (empty!)        │
  │  ├── pg_wal/     │                │                  │
  │  ├── global/     │                │                  │
  │  └── products    │                │                  │
  │      (10,003 rows)│                │                  │
  │                  │                │                  │
  │ Has data! ✓      │                │ No data! ✗       │
  └──────────────────┘                └──────────────────┘
```

---

```
┌─────────────────────────────────────────────────────────────┐
│              DURING pg_basebackup -R                        │
└─────────────────────────────────────────────────────────────┘

    PRIMARY SERVER                      STANDBY SERVER
  ┌──────────────────┐                ┌──────────────────┐
  │ postgres-primary │                │ postgres-standby │
  │                  │   📦 COPYING   │                  │
  │ /data/           │   ══════════▶  │ /data/           │
  │  ├── base/       │   ══════════▶  │  ├── base/       │
  │  ├── pg_wal/     │   ══════════▶  │  ├── pg_wal/     │
  │  ├── global/     │   ══════════▶  │  ├── global/     │
  │  └── products    │   ══════════▶  │  └── products    │
  │      (10,003 rows)│                │      (10,003 rows)│
  │                  │                │                  │
  │                  │   🏷️ CREATES:  │                  │
  │                  │   ══════════▶  │  + standby.signal│
  │                  │   ══════════▶  │  + primary_conninfo
  │                  │                │                  │
  └──────────────────┘                └──────────────────┘
         Source                            Target
       (copied FROM)                    (copied TO)
```

---

```
┌─────────────────────────────────────────────────────────────┐
│              AFTER pg_basebackup Completes                  │
└─────────────────────────────────────────────────────────────┘

    PRIMARY SERVER                      STANDBY SERVER
  ┌──────────────────┐                ┌──────────────────┐
  │ postgres-primary │                │ postgres-standby │
  │                  │                │                  │
  │ /data/           │                │ /data/           │
  │  ├── base/       │                │  ├── base/       │
  │  ├── pg_wal/     │                │  ├── pg_wal/     │
  │  ├── global/     │                │  ├── global/     │
  │  └── products    │                │  └── products    │
  │      (10,003 rows)│                │      (10,003 rows)│
  │                  │                │                  │
  │ ❌ NO standby.signal               │ ✅ HAS standby.signal
  │                  │                │ ✅ HAS primary_conninfo
  │                  │                │                  │
  │ Mode: PRIMARY    │                │ Mode: STANDBY    │
  │ Accepts writes ✅│                │ Blocks writes ❌ │
  └──────────────────┘                └──────────────────┘
```

---

```
┌─────────────────────────────────────────────────────────────┐
│            AFTER Starting Standby (Replication Active)      │
└─────────────────────────────────────────────────────────────┘

    PRIMARY SERVER                      STANDBY SERVER
  ┌──────────────────┐                ┌──────────────────┐
  │ postgres-primary │                │ postgres-standby │
  │                  │                │                  │
  │ Accepts writes   │  ══WAL══▶      │ Replays WAL      │
  │                  │  streaming     │                  │
  │ INSERT INTO...   │  ══════════▶   │ Applies changes  │
  │ UPDATE ...       │  ══════════▶   │ Stays in sync    │
  │ DELETE ...       │  ══════════▶   │                  │
  │                  │                │                  │
  │ products:        │                │ products:        │
  │ 10,003 rows      │  ══data══▶     │ 10,003 rows      │
  │                  │                │                  │
  │ Timeline: 3      │                │ Timeline: 3      │
  │ LSN: 0/C000018   │  ══sync══▶     │ LSN: 0/C000018   │
  │                  │                │                  │
  │ Read + Write ✅  │                │ Read only ✅     │
  └──────────────────┘                └──────────────────┘
         Master                           Replica
    (sends changes)                  (receives changes)
```

---

## 📋 Step-by-Step: What Actually Happens

### Step 1: Run pg_basebackup Command

**From standby server (or any machine):**

```bash
pg_basebackup \
  -h postgres-primary \        # Connect TO primary
  -U replicator \              # Using replication user
  -D /standby/data \           # Copy TO standby location
  -R                           # Setup replication automatically
```

**What this means:**
- "Connect to PRIMARY server"
- "Copy all data FROM primary"
- "Put it TO standby location"
- "Configure as standby automatically"

---

### Step 2: pg_basebackup Connects to Primary

```
Standby ──────────▶ Primary
        "Hi! I'm replicator user, can I copy your data?"

Primary ◀────────── Standby
        "Yes! Here's the data..."
```

---

### Step 3: Primary Creates Checkpoint

**On primary:**
```sql
-- PostgreSQL automatically runs:
CHECKPOINT;

-- This ensures all data is written to disk
-- Ready for clean copy
```

**Output:**
```
waiting for checkpoint
```

---

### Step 4: Data Transfer (Binary Copy)

**Primary → Standby:**

```
/primary/data/base/16384/16385    ──copy──▶  /standby/data/base/16384/16385
/primary/data/base/16384/16386    ──copy──▶  /standby/data/base/16384/16386
/primary/data/global/1260         ──copy──▶  /standby/data/global/1260
/primary/data/pg_wal/000000...    ──copy──▶  /standby/data/pg_wal/000000...
...
(thousands of files copied!)
```

**Output:**
```
32618/32618 kB (100%), 0/1 tablespace ✓
```

---

### Step 5: Create Replication Files (Because of -R flag)

**pg_basebackup automatically creates:**

1. **standby.signal** (empty file)
```bash
touch /standby/data/standby.signal
# This makes it a STANDBY!
```

2. **primary_conninfo** (in postgresql.auto.conf)
```bash
echo "primary_conninfo = 'host=postgres-primary user=replicator ...'" \
  >> /standby/data/postgresql.auto.conf
# This tells standby how to connect to primary!
```

---

### Step 6: Start Standby Server

```bash
pg_ctl start -D /standby/data
```

**What happens automatically:**

1. PostgreSQL starts
2. Finds `standby.signal` file → "Oh, I'm a standby!"
3. Reads `primary_conninfo` → "I should connect to postgres-primary"
4. Enters recovery mode → `pg_is_in_recovery() = TRUE`
5. Connects to primary automatically
6. Starts receiving WAL stream
7. Starts replaying WAL
8. **Replication is ACTIVE!** ✓

**No manual START SLAVE needed!**

---

## 🔍 Real Files: Primary vs Standby

### PRIMARY Server Files:

```bash
docker exec postgres-primary ls -la /var/lib/postgresql/data/

# Output:
drwx------ 19 postgres postgres   4096 Nov 16 12:07 .
-rw-------  1 postgres root     139497 Nov 16 11:01 backup_manifest
drwx------  6 postgres root       4096 Nov 16 12:54 base/          ← Database
drwx------  2 postgres root       4096 Nov 16 11:50 global/        ← System
drwx------  5 postgres root       4096 Nov 16 13:50 pg_wal/        ← WAL
-rw-------  1 postgres root       4897 Nov 16 12:28 pg_hba.conf
-rw-------  1 postgres root      29758 Nov 16 11:01 postgresql.conf

# ❌ NO standby.signal file!
docker exec postgres-primary ls standby.signal
# ls: cannot access 'standby.signal': No such file or directory
```

---

### STANDBY Server Files:

```bash
docker exec postgres-standby ls -la /var/lib/postgresql/data/

# Output:
drwx------ 19 postgres postgres   4096 Nov 16 13:40 .
-rw-------  1 postgres root     139498 Nov 16 13:23 backup_manifest
drwx------  5 postgres root       4096 Nov 16 13:23 base/          ← Database (copied!)
drwx------  2 postgres root       4096 Nov 16 13:41 global/        ← System (copied!)
drwx------  5 postgres root       4096 Nov 16 13:23 pg_wal/        ← WAL (copied!)
-rw-------  1 postgres root       4897 Nov 16 13:23 pg_hba.conf
-rw-------  1 postgres root      29758 Nov 16 13:23 postgresql.conf
-rw-------  1 postgres root          0 Nov 16 13:23 standby.signal ← ADDED! ✓
-rw-------  1 postgres root        794 Nov 16 13:23 postgresql.auto.conf ← ADDED! ✓

# ✅ HAS standby.signal file!
docker exec postgres-standby ls -la standby.signal
# -rw------- 1 postgres root 0 Nov 16 13:23 standby.signal
```

**Key differences:**
1. ✅ Standby HAS `standby.signal` (primary doesn't)
2. ✅ Standby HAS `primary_conninfo` in postgresql.auto.conf
3. ✅ All other files are IDENTICAL (binary copy!)

---

## 🎯 Comparison with MySQL

### MySQL Way: mysqldump

```bash
# On PRIMARY:
mysqldump --all-databases > backup.sql
# Creates ONE SQL file

# Copy to REPLICA:
scp backup.sql replica:/tmp/

# On REPLICA:
mysql < backup.sql
# Executes SQL statements one by one (SLOW!)

# Then configure replication:
CHANGE MASTER TO ...;
START SLAVE;
```

**Flow:**
```
Primary (database) → SQL file → Replica → Execute SQL → Configure replication
```

---

### PostgreSQL Way: pg_basebackup

```bash
# On STANDBY (or any machine):
pg_basebackup -h primary -U replicator -D /data -R
# Connects to primary, copies ALL files, configures replication

# Start STANDBY:
pg_ctl start -D /data
# Replication starts automatically!
```

**Flow:**
```
Primary (files) ══binary copy══▶ Standby (files) → Start → Replication active!
```

**Much simpler!** ✓

---

## 💡 Analogy Time!

### MySQL mysqldump:
```
🏠 Want to copy a house?

1. Write down every detail:
   - "First brick at position (0,0)"
   - "Second brick at position (0,1)"
   - "Paint color: white"
   - "Door size: 2m x 1m"
   (thousands of instructions!)

2. Give instructions to builder

3. Builder reads each line and builds new house
   (takes DAYS!)

4. Then manually connect plumbing/electricity
   (configure replication)
```

---

### PostgreSQL pg_basebackup:
```
🏠 Want to copy a house?

1. Use 3D printer/photocopier! 🖨️
   - Scan entire house
   - Create exact replica instantly
   - All connections already in place!

2. Turn on power
   - House starts working immediately!
   - Automatic connection to main house!
   (takes HOURS, not days!)
```

---

## 📊 Summary Table

| Aspect | MySQL mysqldump | PostgreSQL pg_basebackup |
|--------|----------------|-------------------------|
| **What it copies** | SQL statements | Binary files |
| **File type** | Text (.sql) | Binary (many files) |
| **Direction** | Primary → File → Standby | **Primary → Standby directly** ✓ |
| **Size** | Large (SQL text) | Smaller (binary) |
| **Speed (1 TB)** | ~8 hours | ~1 hour |
| **Replication setup** | Manual (CHANGE MASTER + START SLAVE) | **Automatic (-R flag)** ✓ |
| **Start replication** | Manual (START SLAVE) | **Automatic (on startup)** ✓ |
| **Equivalent to** | pg_dump | xtrabackup (but better!) |

---

## 🎓 Key Takeaways

### Your Understanding is CORRECT! ✅

1. ✅ **YES!** pg_basebackup copies FROM primary TO standby
2. ✅ It's a **binary copy** (not SQL dump)
3. ✅ Copies **ALL database files** (base/, pg_wal/, global/, etc.)
4. ✅ Adds **standby.signal** to mark as standby
5. ✅ Adds **primary_conninfo** to configure connection
6. ✅ Replication starts **automatically** on startup

### The Flow:

```
1. Run: pg_basebackup -h PRIMARY -D STANDBY -R
   ↓
2. PRIMARY data copied TO STANDBY location
   ↓
3. standby.signal created (marks as standby)
   ↓
4. primary_conninfo configured (connection details)
   ↓
5. Start STANDBY server
   ↓
6. Replication ACTIVE automatically! ✓
```

**Bottom line:** pg_basebackup = "Copy primary to standby + setup replication automatically" 🎉

---

*Document created: November 16, 2025*  
*Purpose: Visual guide showing how pg_basebackup copies primary to standby*  
*For: MySQL DBAs understanding the data flow in PostgreSQL replication setup*
