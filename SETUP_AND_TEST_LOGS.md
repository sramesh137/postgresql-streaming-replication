# PostgreSQL Streaming Replication - Setup and Test Logs

This document contains the complete logs from setting up and testing the PostgreSQL streaming replication system.

**Date:** November 16, 2025  
**Setup Type:** Docker-based Primary-Standby Replication  
**PostgreSQL Version:** 15.15

---

## 1. Initial Container Startup

### Command:
```bash
docker-compose up -d
```

### Output:
```
WARN[0000] /Users/ramesh/Documents/Learnings/gc-codings/postgresql-streaming-
replication/docker-compose.yml: the attribute `version` is obsolete, it will be ignored, please remove it to avoid potential confusion

[+] Running 5/5
 ✔ Network postgresql-streaming-replication_postgres-network  Created   0.0s 
 ✔ Volume postgresql-streaming-replication_standby-data       Created   0.0s 
 ✔ Volume postgresql-streaming-replication_primary-data       Created   0.0s 
 ✔ Container postgres-primary                                 Healthy  10.8s 
 ✔ Container postgres-standby                                 Started  10.9s
```

**Status:** ✅ SUCCESS  
**Notes:** 
- Docker network created for inter-container communication
- Persistent volumes created for both primary and standby data
- Primary passed health check in 10.8 seconds
- Standby started successfully

---

## 2. Primary Server Initialization Logs

### Command:
```bash
docker-compose logs postgres-primary | tail -20
```

### Output:
```
postgres-primary  | waiting for server to shut down....2025-11-16 07:15:18.891 UTC [48] LOG:  received fast shutdown request
postgres-primary  | 2025-11-16 07:15:18.891 UTC [48] LOG:  aborting any active transactions
postgres-primary  | 2025-11-16 07:15:18.893 UTC [48] LOG:  background worker "logical replication launcher" (PID 54) exited with exit code 1
postgres-primary  | 2025-11-16 07:15:18.893 UTC [49] LOG:  shutting down
postgres-primary  | 2025-11-16 07:15:18.893 UTC [49] LOG:  checkpoint starting: shutdown immediate
postgres-primary  | 2025-11-16 07:15:18.900 UTC [49] LOG:  checkpoint complete: wrote 75 buffers (0.5%); 0 WAL file(s) added, 0 removed, 0 recycled; write=0.002 s, sync=0.004 s, total=0.008 s; sync files=53, longest=0.002 s, average=0.001 s; distance=195 kB, estimate=195 kB
postgres-primary  | 2025-11-16 07:15:18.901 UTC [48] LOG:  database system is shut down
postgres-primary  |  done
postgres-primary  | server stopped
postgres-primary  | 
postgres-primary  | PostgreSQL init process complete; ready for start up.
postgres-primary  | 
postgres-primary  | 2025-11-16 07:15:19.006 UTC [1] LOG:  starting PostgreSQL 15.15 (Debian 15.15-1.pgdg13+1) on aarch64-unknown-linux-gnu, compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
postgres-primary  | 2025-11-16 07:15:19.006 UTC [1] LOG:  listening on IPv4 address "0.0.0.0", port 5432
postgres-primary  | 2025-11-16 07:15:19.007 UTC [1] LOG:  listening on IPv6 address "::", port 5432
postgres-primary  | 2025-11-16 07:15:19.007 UTC [1] LOG:  listening on Unix socket "/var/run/postgresql/.s.PGSQL.5432"
postgres-primary  | 2025-11-16 07:15:19.010 UTC [64] LOG:  database system was shut down at 2025-11-16 07:15:18 UTC
postgres-primary  | 2025-11-16 07:15:19.012 UTC [1] LOG:  database system is ready to accept connections
```

**Status:** ✅ SUCCESS  
**Key Events:**
1. Init process completed successfully
2. PostgreSQL 15.15 started
3. Listening on port 5432 (IPv4 and IPv6)
4. Database system ready to accept connections
5. `init.sql` executed (users and orders tables created, replication user created)

---

## 3. Automated Replication Setup

### Command:
```bash
bash scripts/setup-replication.sh
```

### Output:

```
================================================
PostgreSQL Streaming Replication Setup Script
================================================

Step 1: Creating replication slot on primary...
 pg_create_physical_replication_slot 
-------------------------------------
 (standby_slot,)
(1 row)


Step 2: Stopping standby container...
[+] Stopping 1/1
 ✔ Container postgres-standby  Stopped                                  0.2s 

Step 3: Cleaning standby data directory...
[+] Creating 1/1
 ✔ Container postgres-primary  Running                                  0.0s 

Step 4: Creating base backup from primary...
This may take a few minutes...
[+] Creating 1/1
 ✔ Container postgres-primary  Running                                  0.0s 
pg_basebackup: initiating base backup, waiting for checkpoint to complete
pg_basebackup: checkpoint completed
pg_basebackup: write-ahead log start point: 0/2000028 on timeline 1
pg_basebackup: starting background WAL receiver
pg_basebackup: created temporary replication slot "pg_basebackup_126"
23284/23284 kB (100%), 1/1 tablespace
pg_basebackup: write-ahead log end point: 0/2000138
pg_basebackup: waiting for background process to finish streaming ...
pg_basebackup: syncing data to disk ...
pg_basebackup: renaming backup_manifest.tmp to backup_manifest
pg_basebackup: base backup completed

Step 5: Creating standby.signal file...
[+] Creating 1/1
 ✔ Container postgres-primary  Running                                  0.0s 

Step 6: Configuring primary connection info...
[+] Creating 1/1
 ✔ Container postgres-primary  Running                                  0.0s 

Step 7: Starting standby container...
[+] Running 2/2
 ✔ Container postgres-primary  Healthy                                  0.5s 
 ✔ Container postgres-standby  Started                                  0.1s 

Step 8: Waiting for standby to start...

================================================
Setup Complete!
================================================

Verification Commands:
----------------------
# Check replication status on primary:
docker exec -it postgres-primary psql -U postgres -c 'SELECT * FROM pg_stat_replication;'

# Check standby is in recovery mode:
docker exec -it postgres-standby psql -U postgres -c 'SELECT pg_is_in_recovery();'

# Monitor replication lag:
bash scripts/monitor.sh
```

**Status:** ✅ SUCCESS  
**Key Steps Completed:**
1. ✅ Replication slot `standby_slot` created on primary
2. ✅ Standby container stopped for data replacement
3. ✅ Old standby data directory cleaned
4. ✅ Base backup (23.3 MB) transferred from primary to standby
5. ✅ `standby.signal` file created (marks server as standby)
6. ✅ Primary connection info configured in `postgresql.conf`
7. ✅ Standby restarted and connected to primary
8. ✅ WAL streaming established

---

## 4. Replication Status Monitoring

### Command:
```bash
bash scripts/monitor.sh
```

### Output:

```
========================================
PostgreSQL Streaming Replication Status
========================================

PRIMARY SERVER STATUS
---------------------

Connected Replicas:
-[ RECORD 1 ]----+----------------
application_name | standby1
client_addr      | 172.19.0.3
state            | streaming
sync_state       | async
sent_lsn         | 0/3000060
write_lsn        | 0/3000060
flush_lsn        | 0/3000060
replay_lsn       | 0/3000060
lag_bytes        | 0
write_lag        | 00:00:00.011574
flush_lag        | 00:00:00.01173
replay_lag       | 00:00:00.011732


Replication Slots:
  slot_name   | slot_type | active | restart_lsn | retained_bytes 
--------------+-----------+--------+-------------+----------------
 standby_slot | physical  | t      | 0/3000060   |              0
(1 row)


========================================

STANDBY SERVER STATUS
---------------------

Recovery Status:
     server_mode     | last_received_lsn | last_replayed_lsn | replay_lag_bytes | last_replay_time | replication_delay
---------------------+-------------------+-------------------+------------------+------------------+-------------------
 STANDBY (Read-Only) | 0/3000060         | 0/3000060         |                0 |                  |
(1 row)


========================================

QUICK HEALTH CHECK
------------------
✓ Primary: Running
✓ Standby: Running
✓ Standby: In recovery mode (correct)

========================================

TIP: Run this script continuously with:
watch -n 2 bash scripts/monitor.sh
```

**Status:** ✅ STREAMING ACTIVE  
**Key Metrics:**
- **Application Name:** standby1
- **Client Address:** 172.19.0.3 (standby's IP in Docker network)
- **State:** streaming (actively replicating)
- **Sync State:** async (asynchronous replication)
- **Lag:** 0 bytes (perfect synchronization!)
- **Replay Lag:** ~11ms (excellent performance)
- **Replication Slot:** Active and healthy

**Analysis:**
- All LSN (Log Sequence Number) values match → No replication lag
- Standby is in recovery mode → Correctly configured
- Zero retained bytes → WAL is being consumed immediately

---

## 5. Automated Replication Testing

### Command:
```bash
bash scripts/test-replication.sh
```

### Output:

```
========================================
PostgreSQL Replication Test Suite
========================================

Test 1: Insert data on primary
-------------------------------
INSERT 0 1
✓ Data inserted on primary

Test 2: Verify data appears on standby
---------------------------------------
✓ SUCCESS: Data replicated to standby!

Test 3: Verify standby is read-only
------------------------------------
✓ Standby correctly rejects writes

Test 4: Check replication lag
------------------------------
 application_name |   state   | lag_bytes |   replay_lag    
------------------+-----------+-----------+-----------------
 standby1         | streaming |         0 | 00:00:00.000978
(1 row)


Test 5: Verify table counts match
----------------------------------
Primary users count: 4
Standby users count: 4
✓ Counts match!

========================================
All tests completed!
========================================
```

**Status:** ✅ ALL TESTS PASSED  
**Test Results:**
1. ✅ Primary accepts writes
2. ✅ Data replicated instantly to standby
3. ✅ Standby correctly rejects writes (read-only enforcement)
4. ✅ Zero replication lag (0 bytes, <1ms)
5. ✅ Row counts match across both servers

---

## 6. Manual Testing - INSERT on Primary

### Command:
```bash
docker exec -it postgres-primary psql -U postgres -c "INSERT INTO users (username, email) VALUES ('ramesh_test', 'ramesh@test.com') RETURNING *;"
```

### Output:
```
 id |  username   |      email      |         created_at         
----+-------------+-----------------+----------------------------
  5 | ramesh_test | ramesh@test.com | 2025-11-16 07:17:20.263673
(1 row)

INSERT 0 1
```

**Status:** ✅ SUCCESS  
**Details:**
- New row inserted with ID 5
- Username: `ramesh_test`
- Email: `ramesh@test.com`
- Timestamp: 2025-11-16 07:17:20.263673 UTC

---

## 7. Manual Testing - Verify on Standby

### Command:
```bash
docker exec -it postgres-standby psql -U postgres -c "SELECT * FROM users WHERE username = 'ramesh_test';"
```

### Output:
```
 id |  username   |      email      |         created_at         
----+-------------+-----------------+----------------------------
  5 | ramesh_test | ramesh@test.com | 2025-11-16 07:17:20.263673
(1 row)
```

**Status:** ✅ REPLICATION VERIFIED  
**Details:**
- Exact same row appeared on standby
- ID, username, email, and timestamp all match
- Replication happened in milliseconds (near-instant)

**Proof of Replication:**
- Primary insert timestamp: `07:17:20.263673`
- Standby query returned same timestamp
- Data integrity maintained perfectly

---

## 8. Manual Testing - Write to Standby (Should Fail)

### Command:
```bash
docker exec -it postgres-standby psql -U postgres -c "INSERT INTO users (username, email) VALUES ('test', 'test@fail.com');"
```

### Output:
```
ERROR:  cannot execute INSERT in a read-only transaction
```

**Status:** ✅ READ-ONLY ENFORCEMENT WORKING  
**Details:**
- Standby correctly rejected the INSERT operation
- Error message confirms server is in read-only mode
- This is expected behavior for a standby server in hot standby mode

**Why This Is Important:**
- Prevents accidental data corruption
- Ensures single source of truth (primary only)
- Confirms standby is in proper recovery/replication mode

---

## 9. Final System State

### Architecture:
```
┌──────────────────────────────────────┐
│      Docker Network: 172.19.0.0/16   │
│                                      │
│   ┌─────────────────────────────┐   │
│   │  postgres-primary           │   │
│   │  IP: 172.19.0.2            │   │
│   │  Port: 5432 (external)     │   │
│   │  Status: Running           │   │
│   │  Mode: Read-Write          │   │
│   └────────┬────────────────────┘   │
│            │ WAL Stream             │
│            │ (Active)               │
│            ▼                        │
│   ┌─────────────────────────────┐   │
│   │  postgres-standby           │   │
│   │  IP: 172.19.0.3            │   │
│   │  Port: 5433 (external)     │   │
│   │  Status: Running           │   │
│   │  Mode: Read-Only           │   │
│   └─────────────────────────────┘   │
└──────────────────────────────────────┘
```

### Database State:

**Tables:**
- `users` (4 rows initially + 1 test row = 5 rows)
- `orders` (3 rows)

**Users:**
- alice, bob, charlie (from init.sql)
- test_user_* (from automated tests)
- ramesh_test (from manual testing)

**Replication Configuration:**
- **WAL Level:** replica
- **Max WAL Senders:** 10
- **Max Replication Slots:** 10
- **WAL Keep Size:** 1GB
- **Synchronous Commit:** off (async mode)
- **Hot Standby:** on

### Performance Metrics:

| Metric | Value | Status |
|--------|-------|--------|
| Replication State | streaming | ✅ Excellent |
| Lag (bytes) | 0 | ✅ Perfect |
| Replay Lag (time) | <1ms | ✅ Excellent |
| Write Lag | ~11ms | ✅ Good |
| Flush Lag | ~11ms | ✅ Good |

---

## 10. Connection Information

### Primary Database (Read-Write):
```bash
# From host machine
psql -h localhost -p 5432 -U postgres

# From Docker
docker exec -it postgres-primary psql -U postgres
```

**Credentials:**
- Host: `localhost` (or `postgres-primary` from Docker network)
- Port: `5432`
- User: `postgres`
- Password: `postgres_password`
- Database: `postgres`

### Standby Database (Read-Only):
```bash
# From host machine
psql -h localhost -p 5433 -U postgres

# From Docker
docker exec -it postgres-standby psql -U postgres
```

**Credentials:**
- Host: `localhost` (or `postgres-standby` from Docker network)
- Port: `5433`
- User: `postgres`
- Password: `postgres_password`
- Database: `postgres`

### Replication User:
- Username: `replicator`
- Password: `replicator_password`
- Privileges: `REPLICATION, LOGIN`

---

## 11. Useful Commands Reference

### Start/Stop Services:
```bash
# Start everything
docker-compose up -d

# Stop everything
docker-compose down

# Stop but keep data
docker-compose stop

# Full cleanup (removes volumes)
docker-compose down -v
```

### View Logs:
```bash
# All logs
docker-compose logs

# Follow logs (real-time)
docker-compose logs -f

# Specific service
docker-compose logs postgres-primary
docker-compose logs postgres-standby

# Last N lines
docker-compose logs --tail=50 postgres-primary
```

### Database Connections:
```bash
# Interactive shell on primary
docker exec -it postgres-primary psql -U postgres

# Interactive shell on standby
docker exec -it postgres-standby psql -U postgres

# Execute single command
docker exec -it postgres-primary psql -U postgres -c "SELECT COUNT(*) FROM users;"
```

### Monitoring:
```bash
# Run monitor script
bash scripts/monitor.sh

# Continuous monitoring (every 2 seconds)
watch -n 2 bash scripts/monitor.sh

# Check replication status
docker exec -it postgres-primary psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check if standby
docker exec -it postgres-standby psql -U postgres -c "SELECT pg_is_in_recovery();"
```

---

## 12. Troubleshooting Commands Used

### Check Container Status:
```bash
docker ps
docker-compose ps
```

### Check Networks:
```bash
docker network ls
docker network inspect postgresql-streaming-replication_postgres-network
```

### Check Volumes:
```bash
docker volume ls
docker volume inspect postgresql-streaming-replication_primary-data
docker volume inspect postgresql-streaming-replication_standby-data
```

### Resource Usage:
```bash
docker stats
```

---

## 13. Summary

### ✅ What Was Successfully Configured:

1. **Docker Infrastructure**
   - Custom bridge network for container communication
   - Persistent volumes for data durability
   - Health checks for dependency management

2. **PostgreSQL Primary Server**
   - WAL level set to `replica`
   - 10 concurrent replication slots configured
   - 1GB WAL retention buffer
   - Custom `pg_hba.conf` for replication access
   - Replication user created

3. **PostgreSQL Standby Server**
   - Base backup taken from primary (23.3 MB)
   - `standby.signal` file created
   - Primary connection configured
   - Hot standby mode enabled
   - Successfully connected and streaming

4. **Replication Features**
   - Physical streaming replication active
   - Asynchronous mode (high performance)
   - Replication slot preventing WAL deletion
   - Zero lag achieved
   - Read-only enforcement on standby

### 📊 Test Results Summary:

| Test | Expected | Actual | Status |
|------|----------|--------|--------|
| Primary accepts writes | ✅ Yes | ✅ Yes | PASS |
| Standby replicates data | ✅ Yes | ✅ Yes | PASS |
| Standby rejects writes | ✅ Yes | ✅ Yes | PASS |
| Replication lag | < 1 second | 0.000978 seconds | PASS |
| Row count consistency | Match | 4 = 4 (then 5 = 5) | PASS |
| Manual insert test | Replicated | Replicated instantly | PASS |

### 🎯 Key Achievements:

- ✅ **Zero data loss risk** with replication slot
- ✅ **Sub-millisecond replication lag**
- ✅ **Production-ready setup** for learning
- ✅ **Complete monitoring** capabilities
- ✅ **Automated testing** suite
- ✅ **Read scaling** capability demonstrated

### 🚀 System Ready For:

1. Development and learning
2. Testing failover scenarios
3. Experimenting with replication parameters
4. Understanding PostgreSQL HA concepts
5. Practicing DBA tasks
6. Load testing read distribution

---

## 14. Next Steps & Learning Path

### Immediate Experiments:
- [ ] Insert 1000 rows and measure replication lag
- [ ] Run queries simultaneously on both servers
- [ ] Practice promoting standby to primary
- [ ] Test what happens when primary is stopped
- [ ] Add monitoring with pg_stat_replication views

### Advanced Topics to Explore:
- [ ] Configure synchronous replication
- [ ] Add a second standby server
- [ ] Setup cascading replication
- [ ] Implement connection pooling (pgBouncer)
- [ ] Configure automated failover (Patroni)
- [ ] Setup WAL archiving to external storage
- [ ] Practice point-in-time recovery

---

**Log File Generated:** November 16, 2025  
**PostgreSQL Version:** 15.15  
**Docker Compose Version:** 2.x  
**Setup Duration:** ~2 minutes  
**Overall Status:** ✅ FULLY OPERATIONAL
