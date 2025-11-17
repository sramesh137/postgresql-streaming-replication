# PostgreSQL Streaming Replication - Complete Tutorial

## 📚 Table of Contents
- [What is Streaming Replication?](#what-is-streaming-replication)
- [Why Use It?](#why-use-it)
- [How It Works](#how-it-works)
- [Architecture Deep Dive](#architecture-deep-dive)
- [Implementation Guide](#implementation-guide)
- [Key Concepts](#key-concepts)
- [Testing & Verification](#testing--verification)
- [Real-World Use Cases](#real-world-use-cases)
- [Troubleshooting](#troubleshooting)

---

## 🎯 What is Streaming Replication?

**Streaming replication** is PostgreSQL's method of continuously copying data from a **primary (master)** database to one or more **standby (replica)** databases in real-time. Think of it like having a live backup that's always synchronized with your main database.

### Key Terminology

- **Primary Server**: The main database that handles all write operations
- **Standby/Replica Server**: Read-only copies that continuously sync with the primary
- **WAL (Write-Ahead Log)**: Transaction logs that record all database changes
- **WAL Sender**: Process on primary that sends WAL records to standbys
- **WAL Receiver**: Process on standby that receives and applies WAL records
- **Replication Slot**: Ensures primary retains WAL files until standbys consume them

---

## 🤔 Why Use Streaming Replication?

### 1. **High Availability (HA)**
- If your primary server crashes, you can promote the standby to become the new primary
- Minimizes downtime (seconds instead of hours)
- Business continuity during hardware failures

### 2. **Disaster Recovery**
- Protects against hardware failures, data corruption, or accidental deletions
- Always have an up-to-date backup ready
- Point-in-time recovery capabilities

### 3. **Read Scaling**
- Distribute **read** queries across multiple standby servers
- Primary handles writes, standbys handle reads
- Improves performance for read-heavy applications

### 4. **Load Balancing**
- Analytics/reporting queries run on standbys
- Doesn't impact primary server performance
- Separate production from analytical workloads

### 5. **Geographic Distribution**
- Place standbys closer to users in different regions
- Reduce latency for read operations
- Better user experience globally

---

## 🏗️ How It Works - The Architecture

```
┌──────────────────────────────────────────────────────────┐
│                   Your Application                       │
└────────────┬─────────────────────────────┬───────────────┘
             │                              │
        WRITE ops                      READ ops
             │                              │
             ▼                              ▼
    ┌─────────────────┐           ┌─────────────────┐
    │  PRIMARY (5432) │           │ STANDBY (5433)  │
    │                 │           │                 │
    │  ✅ Reads       │◄──────────┤  ✅ Reads       │
    │  ✅ Writes      │  WAL      │  ❌ Writes      │
    │                 │  Stream   │  (Read-Only)    │
    └─────────────────┘           └─────────────────┘
           │                              │
           ▼                              ▼
    [Primary Data]                 [Replica Data]
```

### The Replication Flow

1. **Client writes data** to Primary
2. **Primary writes to WAL** (Write-Ahead Log) files first
3. **WAL Sender process** continuously monitors WAL files
4. **WAL Stream** sends changes to Standby server
5. **WAL Receiver process** on Standby receives the stream
6. **Standby applies changes** to its database
7. **Data is synchronized** (typically within milliseconds)

---

## 🔧 Architecture Deep Dive

### Components Explained

#### 1. **WAL (Write-Ahead Log)**
```
Every change in PostgreSQL follows this pattern:
1. Write to WAL file (durability guarantee)
2. Write to actual data files (performance optimized)
3. WAL is like a journal of all database operations
```

**Why WAL is critical:**
- Ensures crash recovery
- Provides replication source
- Guarantees ACID properties

#### 2. **WAL Sender Process** (Primary)
- Runs on the primary server
- Monitors WAL generation
- Streams WAL records to connected standbys
- Tracks how much each standby has received

#### 3. **WAL Receiver Process** (Standby)
- Runs on the standby server
- Connects to primary's WAL sender
- Receives and writes WAL to local files
- Triggers replay process

#### 4. **Replication Slot** (`standby_slot`)
- Named connection between primary and standby
- Prevents primary from deleting needed WAL files
- Tracks standby's position in WAL stream
- Critical for preventing data loss

**Without replication slot:**
```
Primary: "I'll keep WAL for 1GB"
Standby: "I'm offline for 2 hours..."
Primary: "WAL deleted, too old"
Standby: "I'm back! Where's the data?"
Primary: "Gone! Start from scratch!"
```

**With replication slot:**
```
Primary: "I'll keep WAL until standby confirms"
Standby: "I'm offline for 2 hours..."
Primary: "I'll wait and keep accumulating WAL"
Standby: "I'm back!"
Primary: "Here's all the WAL you missed!"
```

### Configuration Parameters Explained

#### Primary Server Configuration
```yaml
-c wal_level=replica
# Sets WAL to include enough info for replication
# Options: minimal, replica, logical

-c hot_standby=on
# Allows read-only queries on standby servers

-c max_wal_senders=10
# Maximum concurrent connections from standbys
# Plan: 1 per standby + 1-2 spare

-c max_replication_slots=10
# Maximum number of replication slots
# Should match max_wal_senders

-c wal_keep_size=1GB
# Minimum WAL to retain (safety buffer)
# Prevents deletion before standby catches up

-c synchronous_commit=off
# Async mode: Don't wait for standby acknowledgment
# Faster writes, but small risk of data loss on crash
```

#### Authentication Configuration (`pg_hba.conf`)
```
# Allow replication connections
host    replication     replicator      0.0.0.0/0               md5

Breakdown:
- host:         TCP/IP connections
- replication:  Special "database" for replication
- replicator:   Username that can replicate
- 0.0.0.0/0:    Allow from any IP (Docker network)
- md5:          Password authentication

⚠️ In production: Replace 0.0.0.0/0 with specific IP ranges!
```

---

## 📋 Implementation Guide

### Phase 1: Start the Containers

```bash
# Navigate to project directory
cd /Users/ramesh/Documents/Learnings/gc-codings/postgresql-streaming-replication

# Start both containers
docker-compose up -d

# Expected output:
# Creating network "postgresql-streaming-replication_postgres-network" ... done
# Creating volume "postgresql-streaming-replication_primary-data" ... done
# Creating volume "postgresql-streaming-replication_standby-data" ... done
# Creating postgres-primary ... done
# Creating postgres-standby ... done
```

**What happens:**
1. Docker creates a network for containers to communicate
2. Creates volumes to persist data
3. Starts primary server (port 5432)
4. Starts standby server (port 5433)
5. Primary runs `init.sql` to create tables and replication user

### Check Primary is Ready

```bash
# Watch the logs
docker-compose logs -f postgres-primary

# Look for these messages:
# ✅ "database system is ready to accept connections"
# ✅ "Database initialized successfully!"
# ✅ "Replication user created: replicator"

# Press Ctrl+C to exit logs
```

**At this point:** Both servers are running but **NOT replicating yet**.

---

### Phase 2: Setup Replication (Automated)

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Run the automated setup
bash scripts/setup-replication.sh
```

#### What the Setup Script Does (Step-by-Step)

**Step 1: Create Replication Slot**
```sql
SELECT pg_create_physical_replication_slot('standby_slot');
```
- Creates a named slot on primary
- Ensures WAL is retained for this standby
- Like reserving a seat for the standby

**Step 2: Stop Standby**
```bash
docker-compose stop postgres-standby
```
- Must stop to safely replace data directory

**Step 3: Clean Standby Data**
```bash
rm -rf /var/lib/postgresql/data/*
```
- Removes existing data on standby
- Prepares for base backup

**Step 4: Take Base Backup**
```bash
pg_basebackup -h postgres-primary \
              -D /var/lib/postgresql/data \
              -U replicator \
              -X stream
```
- Copies entire primary database to standby
- Includes all data files, configuration, and WAL
- Like taking a snapshot
- `-X stream`: Stream WAL during backup (consistency)

**Step 5: Create `standby.signal` File**
```bash
touch /var/lib/postgresql/data/standby.signal
```
- Critical file that tells PostgreSQL: "I'm a standby"
- Without this, server starts as independent primary
- Empty file, just needs to exist

**Step 6: Configure Primary Connection**
```bash
cat >> /var/lib/postgresql/data/postgresql.conf <<EOF
# Streaming Replication Configuration
primary_conninfo = 'host=postgres-primary port=5432 
                    user=replicator password=replicator_password 
                    application_name=standby1'
primary_slot_name = 'standby_slot'
hot_standby = on
hot_standby_feedback = on
EOF
```

- `primary_conninfo`: How to connect to primary
- `primary_slot_name`: Which replication slot to use
- `hot_standby`: Allow read queries on standby
- `hot_standby_feedback`: Tell primary about standby's queries

**Step 7: Start Standby**
```bash
docker-compose start postgres-standby
```
- Starts standby in recovery mode
- Connects to primary automatically
- Begins streaming WAL

**Step 8: Wait for Startup**
```bash
sleep 5
```
- Gives standby time to establish connection

---

### Phase 3: Verify Replication

#### Method 1: Use Monitor Script
```bash
bash scripts/monitor.sh
```

**Output shows:**
- Connected standbys
- Replication state (streaming/catching up)
- Lag in bytes and time
- Last WAL sent/received

#### Method 2: Manual Verification

**On Primary:**
```bash
docker exec -it postgres-primary psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

**Expected output:**
```
 pid | usesysid | usename    | application_name | client_addr | state     | sent_lsn  | write_lsn | flush_lsn | replay_lsn | sync_state
-----+----------+------------+------------------+-------------+-----------+-----------+-----------+-----------+------------+------------
 123 |    16385 | replicator | standby1         | 172.18.0.3  | streaming | 0/3000148 | 0/3000148 | 0/3000148 | 0/3000148  | async
```

**Key columns:**
- `state`: Should be "streaming"
- `sent_lsn` vs `replay_lsn`: Should be close (low lag)
- `sync_state`: "async" (asynchronous replication)

**On Standby:**
```bash
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_is_in_recovery();"
```

**Expected output:**
```
 pg_is_in_recovery 
-------------------
 t
(1 row)
```

`t` (true) = Server is in recovery mode = It's a standby ✅

---

### Phase 4: Test Replication

#### Automated Test
```bash
bash scripts/test-replication.sh
```

#### Manual Testing

**Test 1: Insert Data on Primary**
```bash
docker exec -it postgres-primary psql -U postgres -c \
  "INSERT INTO users (username, email) VALUES ('alice_test', 'alice@test.com');"
```

**Test 2: Verify on Standby**
```bash
docker exec -it postgres-standby psql -U postgres -c \
  "SELECT * FROM users WHERE username = 'alice_test';"
```

**Expected:** You should see the new row! 🎉

**Test 3: Try Writing to Standby (Should Fail)**
```bash
docker exec -it postgres-standby psql -U postgres -c \
  "INSERT INTO users (username, email) VALUES ('bob_test', 'bob@test.com');"
```

**Expected error:**
```
ERROR:  cannot execute INSERT in a read-only transaction
```

This confirms standby is truly read-only ✅

---

## 🔑 Key Concepts

### Physical vs Logical Replication

| Feature | **Streaming (Physical)** | **Logical** |
|---------|--------------------------|-------------|
| **What's replicated** | Entire cluster (all databases) | Specific tables/databases |
| **How** | Block-level, binary copy | Row-level, SQL statements |
| **Standby access** | Read-only queries | Full read-write |
| **Version support** | Same major version only | Can differ |
| **Use case** | HA, failover, read scaling | Multi-tenant, selective sync |
| **Complexity** | Simpler to setup | More complex |
| **This project** | ✅ **Uses this!** | ❌ |

### Synchronous vs Asynchronous Replication

#### Asynchronous (Your Setup)
```yaml
-c synchronous_commit=off
```

**How it works:**
```
Client → Primary → "OK, committed!" → Client continues
                ↓
            (Background)
                ↓
            Standby receives later
```

**Pros:**
- ✅ Fast writes (no waiting)
- ✅ Better performance
- ✅ Standby downtime doesn't affect primary

**Cons:**
- ⚠️ Small risk: If primary crashes before streaming, recent commits lost
- ⚠️ Standbys may be slightly behind (seconds)

#### Synchronous
```yaml
-c synchronous_commit=on
-c synchronous_standby_names='standby1'
```

**How it works:**
```
Client → Primary → Wait for Standby → "OK, committed!" → Client continues
                ↓                   ↑
            Standby receives     Standby confirms
```

**Pros:**
- ✅ Zero data loss guarantee
- ✅ Standbys always up-to-date

**Cons:**
- ⚠️ Slower writes (wait for network)
- ⚠️ Standby downtime blocks commits

### Replication Lag

**What is it?**
- Time/data difference between primary and standby
- Measured in bytes (WAL position) or seconds

**Causes:**
- Network latency
- Standby hardware slower than primary
- Heavy write load on primary
- Long-running queries on standby

**Monitoring:**
```sql
-- On primary
SELECT 
    client_addr,
    state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    extract(epoch from (now() - replay_timestamp)) AS lag_seconds
FROM pg_stat_replication;
```

**Good lag:** < 1MB, < 1 second  
**Concerning lag:** > 100MB, > 10 seconds

---

## 🧪 Testing & Verification

### Test 1: Basic Replication
```bash
# Insert 100 rows on primary
docker exec -it postgres-primary psql -U postgres << EOF
DO \$\$
BEGIN
    FOR i IN 1..100 LOOP
        INSERT INTO users (username, email) 
        VALUES ('user_' || i, 'user' || i || '@test.com');
    END LOOP;
END \$\$;
EOF

# Count on standby
docker exec -it postgres-standby psql -U postgres -c \
  "SELECT COUNT(*) FROM users WHERE username LIKE 'user_%';"
```

### Test 2: Replication Lag
```bash
# Generate heavy writes on primary
docker exec -it postgres-primary psql -U postgres << EOF
DO \$\$
BEGIN
    FOR i IN 1..10000 LOOP
        INSERT INTO orders (user_id, product, amount) 
        VALUES (1, 'Product_' || i, random() * 1000);
    END LOOP;
END \$\$;
EOF

# Check lag while writing
bash scripts/monitor.sh
```

### Test 3: Standby Read-Only Enforcement
```bash
# This should fail
docker exec -it postgres-standby psql -U postgres -c \
  "DELETE FROM users WHERE id = 1;"

# Expected: ERROR: cannot execute DELETE in a read-only transaction
```

### Test 4: Connection String Validation
```bash
# Connect to primary (read-write)
docker exec -it postgres-primary psql -U postgres

# In psql:
\dt                          -- List tables
SELECT pg_is_in_recovery();  -- Should return 'f' (false)
\q

# Connect to standby (read-only)
docker exec -it postgres-standby psql -U postgres

# In psql:
\dt                          -- Same tables
SELECT pg_is_in_recovery();  -- Should return 't' (true)
\q
```

---

## 🌍 Real-World Use Cases

### Use Case 1: E-commerce Platform
```
┌─────────────────────────┐
│   Application Layer     │
│  ┌─────────┐            │
│  │ Web App │            │
│  └────┬────┘            │
└───────┼─────────────────┘
        │
        ├─── Writes (Orders, Payments) ──→ PRIMARY
        │
        └─── Reads (Product Catalog,   ──→ STANDBY 1
             Search, Recommendations)  ──→ STANDBY 2
```

**Benefits:**
- Checkout and payments don't compete with browsing
- Can scale reads independently
- Fast product searches don't slow down orders

### Use Case 2: Analytics & Reporting
```
PRIMARY (Production)          STANDBY (Analytics)
├── Live transactions         ├── Heavy reports
├── OLTP queries             ├── Data aggregations
├── User-facing              ├── Business intelligence
└── Must be fast             └── Can take time
```

**Benefits:**
- Analytics don't impact production performance
- Can run experimental queries safely
- Separate failure domains

### Use Case 3: Geographic Distribution
```
         Internet
            │
    ┌───────┼───────┐
    │               │
US East          US West
PRIMARY          STANDBY
(Writes)      (Local Reads)
```

**Benefits:**
- West coast users get faster reads
- Reduced cross-country latency
- Can fail over regionally

### Use Case 4: Development/Testing
```
PRODUCTION            STAGING/DEV
PRIMARY          →    STANDBY
(Live data)          (Safe testing)
```

**Benefits:**
- Test on real production data
- No risk to production
- Validate migrations safely

---

## 🔧 Troubleshooting

### Problem 1: Standby Not Connecting

**Symptoms:**
```sql
SELECT * FROM pg_stat_replication;
-- Returns 0 rows
```

**Diagnosis:**
```bash
# Check standby logs
docker-compose logs postgres-standby

# Look for connection errors:
# "FATAL: password authentication failed"
# "FATAL: no pg_hba.conf entry for replication"
```

**Solutions:**
1. Verify replication user credentials
2. Check `pg_hba.conf` allows replication connections
3. Ensure network connectivity: `docker network inspect`
4. Verify `standby.signal` file exists

### Problem 2: Replication Lag Growing

**Symptoms:**
```sql
-- Lag keeps increasing
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
-- Returns millions of bytes and growing
```

**Solutions:**
1. **Increase resources:**
   ```yaml
   resources:
     limits:
       cpus: '2'
       memory: 4GB
   ```

2. **Optimize standby queries:**
   - Long-running queries block WAL replay
   - Add `hot_standby_feedback = on` (already in setup)

3. **Check disk I/O:**
   ```bash
   docker stats postgres-standby
   ```

### Problem 3: Standby Shows "wal receiver is not running"

**Symptoms:**
```bash
docker-compose logs postgres-standby
# "wal receiver is not running"
```

**Solutions:**
1. Restart standby:
   ```bash
   docker-compose restart postgres-standby
   ```

2. Check `primary_conninfo` in `postgresql.conf`
3. Verify replication slot exists on primary

### Problem 4: Disk Full on Primary

**Symptoms:**
```
ERROR: could not write to file "pg_wal/...": No space left on device
```

**Cause:** Replication slot preventing WAL deletion

**Solutions:**
1. **Check slot status:**
   ```sql
   SELECT * FROM pg_replication_slots;
   ```

2. **Drop inactive slots:**
   ```sql
   SELECT pg_drop_replication_slot('old_slot_name');
   ```

3. **Increase disk or decrease `wal_keep_size`**

---

## 📊 Monitoring Queries

### Essential Monitoring Queries

#### 1. Replication Status Overview
```sql
SELECT 
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    sync_state,
    replay_lag
FROM pg_stat_replication;
```

#### 2. Replication Lag (Detailed)
```sql
SELECT 
    application_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag_size,
    EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds
FROM pg_stat_replication;
```

#### 3. Replication Slots Health
```sql
SELECT 
    slot_name,
    slot_type,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

#### 4. Check if Server is Primary or Standby
```sql
SELECT 
    CASE 
        WHEN pg_is_in_recovery() THEN 'STANDBY (Read-Only)'
        ELSE 'PRIMARY (Read-Write)'
    END AS server_role;
```

#### 5. Last Replayed Transaction
```sql
-- On standby
SELECT 
    pg_last_xact_replay_timestamp() AS last_replay,
    now() - pg_last_xact_replay_timestamp() AS replay_lag;
```

---

## 🎓 Learning Path

### Beginner (You are here!)
- [x] Understand what streaming replication is
- [x] Learn why it's useful
- [x] Setup basic primary-standby
- [ ] Test replication manually
- [ ] Monitor replication status
- [ ] Practice connecting to both servers

### Intermediate
- [ ] Configure synchronous replication
- [ ] Add a second standby
- [ ] Practice manual failover
- [ ] Implement connection pooling (pgBouncer)
- [ ] Setup automated backups
- [ ] Monitor with Prometheus/Grafana

### Advanced
- [ ] Cascading replication (standby → standby)
- [ ] Implement automatic failover (Patroni)
- [ ] Load balancing with HAProxy
- [ ] Cross-datacenter replication
- [ ] Performance tuning
- [ ] Disaster recovery procedures

---

## 🚀 Next Steps

### Immediate Actions
1. **Start the setup** (you're ready!)
   ```bash
   docker-compose up -d
   bash scripts/setup-replication.sh
   ```

2. **Verify it works**
   ```bash
   bash scripts/monitor.sh
   bash scripts/test-replication.sh
   ```

3. **Experiment freely**
   - Insert data on primary
   - Query from standby
   - Try to write to standby (and see it fail)
   - Watch the logs

### Extended Learning
1. **Read the official docs:**
   - [PostgreSQL Replication](https://www.postgresql.org/docs/current/warm-standby.html)
   - [pg_basebackup](https://www.postgresql.org/docs/current/app-pgbasebackup.html)

2. **Try advanced scenarios:**
   - Add a second standby
   - Practice failover
   - Test with application load

3. **Explore related topics:**
   - WAL archiving
   - Point-in-time recovery
   - Logical replication
   - PostgreSQL high availability tools (Patroni, repmgr)

---

## 📚 Additional Resources

### Documentation
- [PostgreSQL High Availability](https://www.postgresql.org/docs/current/high-availability.html)
- [Streaming Replication Protocol](https://www.postgresql.org/docs/current/protocol-replication.html)
- [Recovery Configuration](https://www.postgresql.org/docs/current/runtime-config-replication.html)

### Tools & Extensions
- **Patroni**: Automated failover and HA
- **repmgr**: Replication manager
- **pgBouncer**: Connection pooling
- **Barman**: Backup and recovery
- **pg_auto_failover**: Simple HA setup

### Community
- PostgreSQL Slack
- PostgreSQL mailing lists
- Stack Overflow (postgresql tag)

---

## ✅ Quick Reference

### Essential Commands
```bash
# Start everything
docker-compose up -d

# Setup replication
bash scripts/setup-replication.sh

# Monitor status
bash scripts/monitor.sh

# Test replication
bash scripts/test-replication.sh

# View logs
docker-compose logs -f postgres-primary
docker-compose logs -f postgres-standby

# Connect to databases
docker exec -it postgres-primary psql -U postgres
docker exec -it postgres-standby psql -U postgres

# Stop everything
docker-compose down

# Full cleanup (removes all data)
docker-compose down -v
```

### Key SQL Queries
```sql
-- Check replication status
SELECT * FROM pg_stat_replication;

-- Check if standby
SELECT pg_is_in_recovery();

-- View replication slots
SELECT * FROM pg_replication_slots;

-- Check lag
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) 
FROM pg_stat_replication;
```

---

## 🎯 Summary

You've learned:
✅ What PostgreSQL streaming replication is  
✅ Why it's critical for production systems  
✅ How WAL-based replication works  
✅ The architecture and components involved  
✅ How to implement it with Docker  
✅ How to test and verify replication  
✅ Real-world use cases and patterns  

**You're ready to:** Start experimenting with your setup and understanding how production databases achieve high availability!

Happy learning! 🚀
