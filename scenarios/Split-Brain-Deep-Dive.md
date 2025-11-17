# Split-Brain Deep Dive: Complete Understanding Guide

**Purpose:** Drill down on split-brain scenarios in PostgreSQL streaming replication  
**For:** MySQL DBAs transitioning to PostgreSQL  
**Focus:** Timeline concept, prevention, detection, and resolution

---

## 🧠 What is Split-Brain? (Simple Explanation)

**Split-brain** = Two servers both think they're the PRIMARY at the same time.

### Real-World Analogy:

Imagine a company with one CEO. During a network outage:
- Office A thinks person X is CEO
- Office B thinks person Y is CEO
- Both "CEOs" make decisions
- When network reconnects: **CONFLICT!** Which decisions are valid?

### Database Context:

```
PRIMARY A (Timeline 1)          PRIMARY B (Timeline 2)
Accepts writes                  Accepts writes
├─ INSERT id=100               ├─ INSERT id=100
├─ UPDATE id=50                ├─ DELETE id=75
└─ DELETE id=25                └─ INSERT id=101

When they try to sync: IMPOSSIBLE!
Same ID 100 has different data.
```

---

## 🎯 Split-Brain in Our Scenario 04

### Timeline of Events:

**T0 - Normal Operation:**
```
PRIMARY (postgres-primary)      STANDBY (postgres-standby)
Timeline: 1                     Timeline: 1
LSN: 0/639EC30                 LSN: 0/639EC30 (replicated)
Products: 10,001               Products: 10,001 (same)
Status: Writable               Status: Read-only
         ↓
    [streaming replication]
         ↓
```

**T1 - Primary Fails:**
```
PRIMARY (STOPPED!)              STANDBY (still running)
Timeline: 1                     Timeline: 1
LSN: 0/639EC30                 LSN: 0/639EC30
Products: 10,001               Products: 10,001
Status: DOWN ❌                Status: Read-only, waiting...
```

**T2 - Standby Promoted:**
```
OLD PRIMARY (stopped)           NEW PRIMARY (promoted!)
Timeline: 1                     Timeline: 2 ← CHANGED!
LSN: 0/639EC30                 LSN: 0/639EDC0
Products: 10,001               Products: 10,001
Status: DOWN ❌                Status: Writable ✅
```

**T3 - Old Primary Accidentally Started (SPLIT-BRAIN!):**
```
OLD PRIMARY (started!)          NEW PRIMARY (running)
Timeline: 1 ← PROBLEM!         Timeline: 2
LSN: 0/639ECE0                 LSN: 0/63A07B8
Products: 10,002               Products: 10,002
Status: Writable ⚠️            Status: Writable ⚠️
Data: ID 10002 "Old Write"     Data: ID 10034 "New Write"

💥 BOTH ARE WRITABLE!
💥 BOTH ACCEPT DIFFERENT WRITES!
💥 DATA DIVERGES!
```

---

## 🔑 The Timeline Concept (PostgreSQL's Protection)

### What is Timeline?

**Timeline** = A counter that increments every time a standby is promoted to primary.

Think of it like **Git branches:**
```
Timeline 1 (main branch)
  ↓
  commit A → commit B → commit C
                          ↓
                    (failover happens)
                          ↓
Timeline 2 (new branch)    Timeline 1 (abandoned)
  ↓                        ↓
  commit D → commit E      (no new commits)
```

### Timeline in WAL Filenames:

```
BEFORE FAILOVER (Timeline 1):
000000010000000000000006
   ↑↑↑↑↑↑↑↑
   Timeline 1

AFTER FAILOVER (Timeline 2):
000000020000000000000006
   ↑↑↑↑↑↑↑↑
   Timeline 2 (same segment, different timeline!)
```

### Timeline History File:

After promotion, PostgreSQL creates `00000002.history`:

```
1       0/639ECA8       no recovery target specified
↑       ↑               ↑
Old     Branch point    Reason
timeline LSN
```

**Translation:** "Timeline 2 branched from Timeline 1 at position 0/639ECA8 because standby was promoted"

---

## 🚨 Why Timeline Prevents Split-Brain

### Scenario: Old Primary Tries to Rejoin

**Old Primary (Timeline 1) to New Primary (Timeline 2):**

```
Old Primary: "Hey, I want to replicate from you"
New Primary: "What timeline are you on?"
Old Primary: "Timeline 1"
New Primary: "I'm on Timeline 2. Timeline mismatch!"
New Primary: "ERROR: Cannot replicate across timelines!"
Old Primary: ❌ REJECTED
```

**This is INTENTIONAL protection!**

### Without Timeline (MySQL's Challenge):

**MySQL Scenario:**
```
Old Master: "Hey, I want to replicate"
New Master: "What's your binlog position?"
Old Master: "mysql-bin.000002:12345"
New Master: "That position exists on my binlog, let me send you data..."
Old Master: ✅ ACCEPTS (but data might be different!)
```

**Risk:** Old master can reconnect with wrong data!

### Comparison Table:

| Aspect | PostgreSQL (Timeline) | MySQL (No Timeline) |
|--------|----------------------|---------------------|
| **Old primary rejoin** | BLOCKED by timeline mismatch | ALLOWED (risky) |
| **Protection level** | Very high (automatic) | Medium (needs external tools) |
| **Manual intervention** | Required (pg_rewind or rebuild) | Optional (but recommended) |
| **Data safety** | Very safe | Depends on setup |
| **Complexity** | Higher (need to understand timelines) | Lower (but riskier) |

---

## 🔍 Detecting Split-Brain

### Method 1: Check Timeline on Both Servers

**On Server 1:**
```sql
SELECT timeline_id FROM pg_control_checkpoint();
-- Result: 1
```

**On Server 2:**
```sql
SELECT timeline_id FROM pg_control_checkpoint();
-- Result: 2
```

**Analysis:** Timeline mismatch = split-brain happened or will happen!

### Method 2: Check pg_is_in_recovery()

**Healthy replication:**
```sql
-- Primary:
SELECT pg_is_in_recovery();  -- Should be 'f' (false)

-- Standby:
SELECT pg_is_in_recovery();  -- Should be 't' (true)
```

**Split-brain:**
```sql
-- Old primary:
SELECT pg_is_in_recovery();  -- Returns 'f' (false) ⚠️

-- New primary:
SELECT pg_is_in_recovery();  -- Returns 'f' (false) ⚠️

-- BOTH FALSE = BOTH ARE WRITABLE = SPLIT-BRAIN!
```

### Method 3: Check Replication Slots

**On primary:**
```sql
SELECT slot_name, active, active_pid 
FROM pg_replication_slots;
```

**If you see:**
```
 slot_name    | active | active_pid 
--------------+--------+------------
 standby_slot | f      | NULL
```

**inactive + no PID = standby not connected = potential split-brain**

### Method 4: Monitor Application Behavior

**Symptoms:**
- Queries return different results from different servers
- Data inconsistencies in application
- Primary key violations (same ID inserted twice)
- Foreign key violations

**Example:**
```sql
-- Query on server 1:
SELECT * FROM products WHERE id = 10002;
-- Result: "Old Primary Write"

-- Query on server 2:
SELECT * FROM products WHERE id = 10002;
-- Result: (empty) - doesn't exist!

-- Query on server 2:
SELECT * FROM products WHERE id = 10034;
-- Result: "Post-Failover Product"

-- Query on server 1:
SELECT * FROM products WHERE id = 10034;
-- Result: (empty) - doesn't exist!
```

---

## 🛡️ Preventing Split-Brain (Best Practices)

### 1. Use Connection Pooler with Health Checks

**PgBouncer + Custom Health Script:**

```python
# health_check.py
import psycopg2

def is_primary(host):
    conn = psycopg2.connect(f"host={host} dbname=postgres user=monitor")
    cur = conn.cursor()
    cur.execute("SELECT pg_is_in_recovery();")
    in_recovery = cur.fetchone()[0]
    return not in_recovery  # False = primary, True = standby

# Only route writes to server returning False
```

**HAProxy Configuration:**
```
backend postgres_primary
    option httpchk
    http-check expect string primary
    server pg1 postgres-server1:5432 check
    server pg2 postgres-server2:5432 check backup
```

### 2. Use Patroni (Automated HA)

**Patroni** = Automatic failover with consensus (uses etcd/Consul/Zookeeper)

```yaml
# patroni.yml
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
```

**How Patroni prevents split-brain:**
- Uses distributed consensus (Raft algorithm)
- Only ONE server can hold "leader" lock at a time
- Old primary loses lock = automatically demotes itself
- **Impossible** for two servers to be primary simultaneously

**MySQL equivalent:** MHA (Master High Availability), Orchestrator

### 3. Implement STONITH (Shoot The Other Node In The Head)

**Concept:** Before promoting standby, KILL old primary

```bash
# Fencing script
#!/bin/bash
OLD_PRIMARY_IP="192.168.1.100"

# Before promoting standby, kill old primary
ssh root@$OLD_PRIMARY_IP "systemctl stop postgresql"
# OR
ipmitool -H $OLD_PRIMARY_IP power off

# NOW safe to promote standby
psql -c "SELECT pg_promote();"
```

**Production tools:**
- Pacemaker + Corosync (Linux HA stack)
- Keepalived (VIP management)
- Cloud provider fencing (AWS/Azure/GCP APIs to stop VMs)

### 4. Use Virtual IP (VIP)

**Concept:** Applications connect to VIP, not server IP

```
Application
    ↓
VIP: 192.168.1.200 (floats between servers)
    ↓
Currently on: Server A (primary)

After failover:
VIP moves to: Server B (new primary)
Old Server A: No longer has VIP = can't accept connections
```

**Implementation with Keepalived:**
```
# keepalived.conf
vrrp_script chk_postgres {
    script "/usr/local/bin/check_postgres.sh"
    interval 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 100
    virtual_ipaddress {
        192.168.1.200
    }
}
```

### 5. Monitor Timeline Changes

**Alert on timeline mismatch:**

```sql
-- Monitoring query (run on all servers)
WITH timelines AS (
  SELECT 
    inet_server_addr() as server_ip,
    (SELECT timeline_id FROM pg_control_checkpoint()) as timeline
)
SELECT * FROM timelines;
```

**Expected output (healthy):**
```
  server_ip   | timeline 
--------------+----------
 192.168.1.10 |        2
 192.168.1.11 |        2  ← SAME!
```

**Alert output (split-brain):**
```
  server_ip   | timeline 
--------------+----------
 192.168.1.10 |        1  ← DIFFERENT!
 192.168.1.11 |        2  ← DIFFERENT!
```

**Set up alerts:**
```bash
# Nagios/Zabbix alert:
if timeline_server1 != timeline_server2:
    send_alert("CRITICAL: Split-brain detected!")
```

---

## 🔧 Resolving Split-Brain (Three Options)

### Option 1: Discard Old Primary (Recommended)

**When to use:** Old primary's divergent data is not important

**Steps:**
```bash
# 1. Stop old primary
docker stop old-primary

# 2. Remove data
docker volume rm old-primary-data

# 3. Rebuild from new primary
pg_basebackup -h new-primary -D /data -U replicator -R

# 4. Start as standby
pg_ctl start -D /data
```

**Result:** ✅ Clean slate, single source of truth

**Data loss:** ❌ Yes, old primary's divergent writes are lost

### Option 2: Use pg_rewind

**When to use:** 
- Divergence is small
- `wal_log_hints = on` or `data_checksums` enabled
- Want faster recovery than full rebuild

**Steps:**
```bash
# 1. Stop old primary
pg_ctl stop -D /data -m fast

# 2. Rewind to match new primary
pg_rewind --target-pgdata=/data \
          --source-server='host=new-primary port=5432'

# 3. Create standby configuration
touch /data/standby.signal
echo "primary_conninfo = 'host=new-primary'" >> /data/postgresql.auto.conf

# 4. Start as standby
pg_ctl start -D /data
```

**Result:** ✅ Faster than rebuild, old primary syncs to new timeline

**Data loss:** ❌ Yes, still loses divergent writes (but faster recovery)

### Option 3: Manual Data Merge (Not Recommended)

**When to use:** ONLY if divergent data is absolutely critical

**Steps:**
```bash
# 1. Export divergent data from old primary
pg_dump -t specific_table old-primary > divergent.sql

# 2. Manually edit SQL to resolve conflicts
vim divergent.sql
# Change IDs, fix foreign keys, handle duplicates

# 3. Import to new primary
psql new-primary < divergent.sql

# 4. Rebuild old primary (Option 1)
```

**Result:** ⚠️ Risky! High chance of logical conflicts

**Data loss:** ✅ No, but risk of corruption

---

## 📊 Split-Brain Comparison Matrix

| Prevention Method | Cost | Complexity | Effectiveness | Auto-Recovery |
|-------------------|------|------------|---------------|---------------|
| **Manual fencing** | Low | Low | Medium | No |
| **VIP (Keepalived)** | Low | Medium | Medium | Partial |
| **Patroni** | Medium | High | Very High | Yes |
| **Pacemaker/Corosync** | Medium | Very High | Very High | Yes |
| **Cloud provider HA** | High | Medium | Very High | Yes |
| **Timeline monitoring** | Low | Low | Low (detection only) | No |

---

## 🎓 Quiz: Test Your Understanding

### Question 1:
**You just promoted a standby. Old primary is still running. Is this split-brain?**

A) No, replication will auto-sync them  
B) Yes, both can accept writes  
C) Maybe, depends on timeline

**Answer:** B - Yes! Both servers think they're primary. Timeline prevents auto-sync.

---

### Question 2:
**Timeline 1 and Timeline 2 can sync automatically using streaming replication.**

A) True  
B) False

**Answer:** B - False! Different timelines cannot sync. Must use pg_rewind or rebuild.

---

### Question 3:
**How do you check if a server is primary or standby?**

A) `SHOW MASTER STATUS` (MySQL syntax)  
B) `SELECT pg_is_in_recovery();`  
C) Check timeline number

**Answer:** B - `pg_is_in_recovery()` returns false for primary, true for standby.

---

### Question 4:
**What does the first 8 digits of WAL filename represent?**

A) Segment number  
B) Timeline ID  
C) LSN position

**Answer:** B - Timeline ID (e.g., `00000002` = Timeline 2)

---

### Question 5:
**MySQL has built-in split-brain protection like PostgreSQL's timeline.**

A) True  
B) False

**Answer:** B - False! MySQL requires external tools (MHA, Orchestrator) for split-brain protection.

---

### Question 6:
**After split-brain, you can merge data from both servers without risk.**

A) True  
B) False

**Answer:** B - False! Manual merge is very risky. Foreign key violations, duplicates, logical conflicts are common.

---

### Question 7:
**What file marks a PostgreSQL server as standby?**

A) `recovery.conf` (PostgreSQL 11 and earlier)  
B) `standby.signal` (PostgreSQL 12+)  
C) `postgresql.conf`

**Answer:** B - `standby.signal` (in PostgreSQL 12+). PostgreSQL 11 and earlier used `recovery.conf`.

---

### Question 8:
**Patroni prevents split-brain using:**

A) Timeline checking  
B) Distributed consensus (leader election)  
C) VIP failover

**Answer:** B - Distributed consensus (uses etcd/Consul/Zookeeper for leader election)

---

## 🎯 Key Takeaways

### For MySQL DBAs:

1. **Timeline = PostgreSQL's split-brain protection**
   - MySQL doesn't have this
   - PostgreSQL is MORE restrictive (safer)
   - Requires understanding new concept

2. **Split-brain = Both servers writable**
   - MySQL: Can happen easily without external tools
   - PostgreSQL: Timeline prevents auto-sync (forces manual resolution)

3. **Resolution requires rebuild**
   - MySQL: `CHANGE MASTER TO` (easier but riskier)
   - PostgreSQL: `pg_basebackup` or `pg_rewind` (harder but safer)

4. **Production needs automation**
   - Don't rely on manual failover
   - Use Patroni (PostgreSQL) or MHA (MySQL)
   - Implement fencing (STONITH)

5. **Monitor timelines actively**
   - Alert on timeline mismatch
   - Check `pg_is_in_recovery()` on all servers
   - Verify replication slot activity

---

## 📚 Further Reading

- **Scenario 04 execution log:** `scenarios/logs/scenario-04-execution.md`
- **Data consistency guide:** `scenarios/Data-Consistency-Resolution-Complete-Guide.md`
- **MySQL comparison:** `scenarios/MySQL-Failover-Comparison.md`
- **Timeline history:** PostgreSQL docs - "Backup and Restore > Timelines"
- **Patroni documentation:** https://patroni.readthedocs.io/

---

*Document created: November 16, 2025*  
*Purpose: Deep dive into split-brain scenarios and timeline concept*  
*For: MySQL DBAs mastering PostgreSQL streaming replication*  
*Status: Scenario 04 complete - Ready for Scenario 05*
