# Scenario 07: PostgreSQL Commands Explained

**Quick Reference for Multi-Standby Setup**

---

## 🔍 Command 1: Create Replication Slot for Second Standby

### The PostgreSQL Command:
```sql
SELECT pg_create_physical_replication_slot('standby2_slot');
```

### What It Does:
Creates a new physical replication slot named `standby2_slot` for the second standby.

### Parameters Explained:

**`pg_create_physical_replication_slot(slot_name)`**
- **Function:** Built-in PostgreSQL function
- **Purpose:** Creates persistent tracking point for standby server
- **Slot name:** Must be unique (can't reuse 'standby_slot')

**Physical vs Logical:**
```
Physical slot:  For streaming replication (byte-level)
Logical slot:   For logical replication (row-level, pub/sub)

We use: Physical (for streaming replication)
```

### Expected Output:
```
slot_name     | lsn       
--------------+-----------
standby2_slot | 0/F0BA410
(1 row)
```

### Why We Need This:

**Without slot:**
```
PRIMARY checkpoint occurs
  ↓
WAL files deleted (older than checkpoint)
  ↓
Standby2 tries to connect later
  ↓
ERROR: requested WAL segment has been removed ❌
  ↓
Must rebuild standby from scratch
```

**With slot:**
```
PRIMARY checkpoint occurs
  ↓
Checks replication slots:
  • standby_slot at LSN 0/F0BA410
  • standby2_slot at LSN 0/F0BA410 (new!)
  ↓
Keeps WAL from 0/F0BA410 onwards ✓
  ↓
Standby2 can connect anytime and catch up
```

### MySQL Equivalent:
```sql
-- MySQL doesn't have replication slots
-- Instead, configure binary log retention:
SET GLOBAL binlog_expire_logs_seconds = 259200;  -- 3 days

-- Problem: Fixed time, not position-based
-- If replica offline > 3 days → must rebuild ❌
```

---

## 🔍 Command 2: Take Base Backup for Second Standby

### The Shell Command:
```bash
docker exec -it postgres-primary pg_basebackup \
    -h localhost \
    -U replicator \
    -D /tmp/standby2_backup \
    -Fp \
    -Xs \
    -P \
    -R
```

### What It Does:
Copies the entire PRIMARY database directory to initialize STANDBY2.

### Parameters Explained:

| Parameter | What It Does | Why We Use It |
|-----------|--------------|---------------|
| `-h localhost` | Connect to this host | Connect to PRIMARY |
| `-U replicator` | User for authentication | Replication user with rights |
| `-D /tmp/standby2_backup` | Output directory | Where to save backup |
| `-Fp` | Plain format (not tar) | Direct directory copy |
| `-Xs` | Stream WAL during backup | Ensures consistent backup |
| `-P` | Show progress | See backup progress |
| `-R` | Create recovery config | Auto-creates standby.signal |

### Detailed Parameter Breakdown:

**`-D /tmp/standby2_backup`** (Destination Directory)
- Creates complete copy of data directory
- Includes all databases, tables, indexes
- Includes configuration files
- Does NOT include pg_wal/ (WAL files)

**`-Fp`** (Format: Plain)
```
Plain format (-Fp):
  /data/
    base/
    global/
    pg_wal/
    postgresql.conf
    ...

Tar format (-Ft):
  backup.tar (compressed archive)
  
We use plain: Easier to work with, no extraction needed
```

**`-Xs`** (WAL Stream)
```
Without -Xs:
  START backup → Copy files (5 min) → END backup
  Problem: Changes during 5 min might be missed!

With -Xs:
  START backup + Open WAL stream
  → Copy files (5 min) while streaming WAL
  → END backup with all changes captured ✓
```

**`-P`** (Progress)
```
Output:
123456/987654 kB (12%), 0/1 tablespace
456789/987654 kB (46%), 0/1 tablespace
...
987654/987654 kB (100%), 1/1 tablespace
```

**`-R`** (Recovery Setup)
```
Automatically creates:
  1. standby.signal (marks as standby)
  2. postgresql.auto.conf (replication settings)
  
Without -R: Must manually create these files
With -R: Ready to start as standby immediately ✓
```

### What Gets Copied:

```
SOURCE (PRIMARY):          →  DESTINATION (Standby2):
/var/lib/postgresql/data/  →  /tmp/standby2_backup/
  ├── base/                →    ├── base/          (all databases)
  ├── global/              →    ├── global/        (shared catalogs)
  ├── pg_tblspc/           →    ├── pg_tblspc/     (tablespaces)
  ├── postgresql.conf      →    ├── postgresql.conf
  ├── pg_hba.conf          →    ├── pg_hba.conf
  ├── pg_wal/              →    (NOT copied - recreated)
  └── postmaster.pid       →    (NOT copied - not needed)
```

### Expected Output:
```
NOTICE:  pg_stop_backup complete, all required WAL segments have been archived
123456/123456 kB (100%), 1/1 tablespace
```

### MySQL Equivalent:
```bash
# MySQL physical backup (similar):
xtrabackup --backup \
    --target-dir=/backup/standby2 \
    --user=replicator \
    --password=password \
    --stream=xbstream | gzip > standby2.xbstream.gz

# Or logical backup:
mysqldump --all-databases \
    --master-data=2 \
    --single-transaction \
    > standby2_backup.sql
```

---

## 🔍 Command 3: Monitor Both Standbys

### The PostgreSQL Command:
```sql
SELECT 
    application_name,
    client_addr,
    state,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
    replay_lag
FROM pg_stat_replication
ORDER BY application_name;
```

### What Each Column Means:

**`application_name`**
- Identifies the standby server
- Default: `walreceiver`
- Can customize in standby's `primary_conninfo`

**`client_addr`**
- IP address of standby
- Example: `172.18.0.3` (Docker network)
- Helps identify which physical server

**`state`**
- Connection state
- Values:
  - `streaming` = Actively receiving WAL ✓
  - `catchup` = Catching up after lag
  - `backup` = Taking backup (pg_basebackup)

**`pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)`**
- Calculates byte lag
- `pg_current_wal_lsn()` = PRIMARY's current position
- `replay_lsn` = STANDBY's last replayed position
- Difference = How many bytes behind

**`pg_size_pretty()`**
- Converts bytes to human-readable
- Example: `16384` → `16 kB`

**`replay_lag`**
- Time interval (not bytes!)
- Example: `00:00:05` = 5 seconds behind
- Based on transaction timestamps

### Expected Output (2 Standbys):
```
application_name | client_addr | state     | lag     | replay_lag
-----------------+-------------+-----------+---------+------------
walreceiver      | 172.18.0.3  | streaming | 0 bytes | 00:00:00
walreceiver      | 172.18.0.4  | streaming | 0 bytes | 00:00:00
(2 rows)
```

### Different Lag Example:
```
application_name | client_addr | state     | lag     | replay_lag
-----------------+-------------+-----------+---------+------------
walreceiver      | 172.18.0.3  | streaming | 0 bytes | 00:00:00    ← Fast
walreceiver      | 172.18.0.4  | streaming | 16 kB   | 00:00:02    ← Lagging
```

**Why lag differs:**
- Standby1: SSD, idle → Fast replay
- Standby2: HDD, busy → Slower replay

**This is NORMAL!** Each standby is independent.

### MySQL Equivalent:
```sql
-- MySQL must check each replica separately:

-- On Master:
SHOW SLAVE HOSTS;

-- On each Replica:
SHOW SLAVE STATUS\G
-- Check: Seconds_Behind_Master, Relay_Log_Space

-- No single query shows all replicas together ❌
-- Must connect to each replica individually
```

---

## 🔍 Command 4: Verify Replication Slots

### The PostgreSQL Command:
```sql
SELECT 
    slot_name,
    slot_type,
    active,
    restart_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
ORDER BY slot_name;
```

### What Each Column Means:

**`slot_name`**
- Unique identifier for slot
- Examples: `standby_slot`, `standby2_slot`

**`slot_type`**
- `physical` = Streaming replication
- `logical` = Logical replication (pub/sub)

**`active`**
- `t` = Standby currently connected ✓
- `f` = Standby disconnected ⚠️

**`restart_lsn`**
- Oldest WAL position this slot needs
- PRIMARY retains WAL from this point

**`retained_wal`**
- How much WAL PRIMARY is holding for this slot
- `0 bytes` = Standby caught up ✓
- `100 MB` = Standby lagging, WAL accumulating ⚠️

### Expected Output (2 Standbys):
```
slot_name     | slot_type | active | restart_lsn | retained_wal
--------------+-----------+--------+-------------+--------------
standby_slot  | physical  | t      | 0/F0BA410   | 0 bytes
standby2_slot | physical  | t      | 0/F0BA410   | 0 bytes
(2 rows)
```

### If One Standby Lagging:
```
slot_name     | slot_type | active | restart_lsn | retained_wal
--------------+-----------+--------+-------------+--------------
standby_slot  | physical  | t      | 0/F0BA410   | 0 bytes      ← Caught up
standby2_slot | physical  | t      | 0/F000000   | 700 kB       ← Lagging
```

**Interpretation:**
- Standby1 at LSN 0/F0BA410 (latest)
- Standby2 at LSN 0/F000000 (behind by ~700 KB)
- PRIMARY retaining 700 KB of WAL for Standby2

**Action:** Monitor Standby2, ensure it catches up

### MySQL Equivalent:
```sql
-- MySQL doesn't have replication slots
-- Must manually track binary log positions:

SHOW BINARY LOGS;

-- Check each replica's position:
-- (Must connect to each replica)
SHOW SLAVE STATUS\G
-- Master_Log_File: mysql-bin.000123
-- Read_Master_Log_Pos: 456789

-- Calculate manually which binlogs can be purged
```

---

## 🔍 Command 5: Test Data Consistency

### The PostgreSQL Commands:
```sql
-- On PRIMARY:
SELECT COUNT(*) FROM orders;

-- On STANDBY1:
SELECT COUNT(*) FROM orders;

-- On STANDBY2:
SELECT COUNT(*) FROM orders;
```

### What It Verifies:
- All standbys have same row count as PRIMARY
- No data loss during replication
- All standbys caught up completely

### Expected Output:
```
PRIMARY:  50004
STANDBY1: 50004
STANDBY2: 50004

All match ✓
```

### If Counts Differ:
```
PRIMARY:  50004
STANDBY1: 50004
STANDBY2: 50000  ← Missing 4 rows!
```

**Possible reasons:**
1. **Standby2 still catching up** (check lag)
2. **Replication broken** (check connection)
3. **WAL missing** (check if slot dropped)

**Fix:** Wait for replication to catch up, or investigate errors

### More Detailed Verification:
```sql
-- Check specific rows exist on all servers:
SELECT id, product, amount 
FROM orders 
WHERE product LIKE 'Heavy_Load_%'
ORDER BY id 
LIMIT 10;

-- On PRIMARY:
id | product        | amount
---+----------------+--------
5  | Heavy_Load_1   | 234.56
6  | Heavy_Load_2   | 789.12
...

-- On STANDBY1 and STANDBY2:
(Should show identical data!)
```

### MySQL Equivalent:
```sql
-- Check master:
SELECT COUNT(*) FROM orders;

-- Check each replica:
SELECT COUNT(*) FROM orders;

-- Should match if replica caught up
-- Check: SHOW SLAVE STATUS\G
--   Seconds_Behind_Master: 0 (must be zero)
```

---

## 🔍 Command 6: Test Read Load Distribution

### The Shell Commands:
```bash
# Query STANDBY1:
docker exec postgres-standby psql -U postgres -c "
SELECT COUNT(*) FROM orders WHERE amount > 500;
"

# Query STANDBY2:
docker exec postgres-standby2 psql -U postgres -c "
SELECT COUNT(*) FROM orders WHERE amount > 500;
"
```

### What It Tests:
- Both standbys can serve read queries
- Performance comparison
- Load distribution capability

### Expected Output:
```
STANDBY1:
 count  
--------
 25123

STANDBY2:
 count  
--------
 25123

(Same result, both can serve reads ✓)
```

### Performance Testing:
```bash
# Time query on STANDBY1:
time docker exec postgres-standby psql -U postgres -c "
SELECT COUNT(*), AVG(amount) FROM orders;
"

# Time same query on STANDBY2:
time docker exec postgres-standby2 psql -U postgres -c "
SELECT COUNT(*), AVG(amount) FROM orders;
"

# Compare execution times:
STANDBY1: 0.012 seconds
STANDBY2: 0.013 seconds

(Similar performance ✓)
```

### Load Balancing Simulation:
```bash
# Send 10 queries alternating between standbys:
for i in {1..10}; do
    if [ $((i % 2)) -eq 0 ]; then
        docker exec postgres-standby psql -U postgres -c "SELECT COUNT(*) FROM orders;" > /dev/null
        echo "Query $i → STANDBY1"
    else
        docker exec postgres-standby2 psql -U postgres -c "SELECT COUNT(*) FROM orders;" > /dev/null
        echo "Query $i → STANDBY2"
    fi
done

Output:
Query 1 → STANDBY2
Query 2 → STANDBY1
Query 3 → STANDBY2
Query 4 → STANDBY1
...
```

### Verify Read-Only:
```bash
# Try INSERT on STANDBY2 (should fail):
docker exec postgres-standby2 psql -U postgres -c "
INSERT INTO orders (user_id, product, amount) 
VALUES (1, 'test', 100);
"

Expected error:
ERROR: cannot execute INSERT in a read-only transaction
```

### MySQL Equivalent:
```sql
-- Query replica1:
SELECT COUNT(*) FROM orders WHERE amount > 500;

-- Query replica2:
SELECT COUNT(*) FROM orders WHERE amount > 500;

-- Load balance with connection pool:
-- (Application level or ProxySQL/MaxScale)
```

---

## 📊 Quick Reference Table

| Command | Purpose | Expected Result |
|---------|---------|-----------------|
| `pg_create_physical_replication_slot()` | Create slot for standby | Slot created |
| `pg_basebackup -R` | Initialize standby | Data copied |
| `pg_stat_replication` | Monitor all standbys | 2 rows (2 standbys) |
| `pg_replication_slots` | Check slot status | 2 active slots |
| `COUNT(*)` on all servers | Verify consistency | All match |
| Read queries on standbys | Test load distribution | Both work |

---

## 🎓 Key PostgreSQL Functions

### LSN Functions:
```sql
pg_current_wal_lsn()          -- Current position on PRIMARY
pg_last_wal_receive_lsn()     -- Last WAL received on STANDBY
pg_last_wal_replay_lsn()      -- Last WAL replayed on STANDBY
pg_wal_lsn_diff(lsn1, lsn2)   -- Calculate difference in bytes
pg_walfile_name(lsn)          -- Get WAL filename for LSN
```

### Slot Functions:
```sql
pg_create_physical_replication_slot(name)  -- Create slot
pg_drop_replication_slot(name)             -- Drop slot
pg_replication_slot_advance(name, lsn)     -- Advance slot position
```

### Replication Functions:
```sql
pg_is_in_recovery()           -- Check if server is standby (t/f)
pg_promote()                  -- Promote standby to primary
```

---

## 🎬 You're Ready!

**Now you understand:**
- ✅ How to create replication slots
- ✅ How pg_basebackup works
- ✅ How to monitor multiple standbys
- ✅ How to verify data consistency
- ✅ How to test read load distribution
- ✅ All PostgreSQL replication functions

**Ready to execute Scenario 07 and build multi-standby setup!** 🚀

---

*Command reference created: November 17, 2025*  
*All PostgreSQL commands explained with MySQL comparisons*
