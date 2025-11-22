# Scenario 13: pgPool-II Hands-On Demo

**Difficulty:** Intermediate  
**Duration:** 30-40 minutes  
**Prerequisites:** PostgreSQL primary and standby running

## 🎯 Learning Objectives

- Set up pgPool-II with Docker
- Configure connection pooling
- Test load balancing across primary and standby
- Monitor connection distribution
- Understand read/write query routing
- Practice interview scenarios

---

## 📚 Background

**pgPool-II** is a middleware that provides:
- **Connection pooling**: 1000 app connections → 20 DB connections
- **Load balancing**: Distribute read queries across replicas
- **Query routing**: Writes to primary, reads to standbys
- **High availability**: Automatic failover detection

**Interview Value:** ⭐⭐⭐⭐⭐
- "How do you handle 10,000 concurrent connections?"
- "Explain your load balancing strategy"
- "How do you route queries in a replica setup?"

---

## Step 1: Verify Current Setup

### 1.1 Check PostgreSQL Containers
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep postgres
```

**Expected Output:**
```
postgres-primary    Up 5 minutes    5432/tcp
postgres-standby    Up 5 minutes    5433/tcp
postgres-standby2   Up 5 minutes    5434/tcp
```

**✅ Checkpoint:** All 3 PostgreSQL containers running

### 1.2 Verify Replication
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    state,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;"
```

**Expected:** At least 1 standby streaming with 0 lag

---

## Step 2: Create pgPool Configuration

### 2.1 Create pgPool Directory Structure
```bash
# Create config directory
mkdir -p pgpool-config

# Create pgpool.conf
cat > pgpool-config/pgpool.conf << 'EOF'
# ----------------------------
# pgPool-II Configuration
# ----------------------------

# Connection Settings
listen_addresses = '*'
port = 9999
socket_dir = '/tmp'

# Pool Settings
num_init_children = 32
max_pool = 4
child_life_time = 300
child_max_connections = 0
connection_life_time = 0
client_idle_limit = 0

# Backend Settings (PostgreSQL servers)
backend_hostname0 = 'postgres-primary'
backend_port0 = 5432
backend_weight0 = 0
backend_data_directory0 = '/var/lib/postgresql/data'
backend_flag0 = 'ALWAYS_PRIMARY'

backend_hostname1 = 'postgres-standby'
backend_port1 = 5432
backend_weight1 = 1
backend_data_directory1 = '/var/lib/postgresql/data'
backend_flag1 = 'DISALLOW_TO_FAILOVER'

# Load Balancing
load_balance_mode = on
ignore_leading_white_space = on

# Streaming Replication
sr_check_period = 10
sr_check_user = 'postgres'
sr_check_password = 'postgres'
sr_check_database = 'postgres'

# Health Check
health_check_period = 10
health_check_timeout = 20
health_check_user = 'postgres'
health_check_password = 'postgres'
health_check_database = 'postgres'
health_check_max_retries = 3
health_check_retry_delay = 1

# Authentication
enable_pool_hba = off
allow_clear_text_frontend_auth = on

# Connection Pool
connection_cache = on
reset_query_list = 'ABORT; DISCARD ALL'

# Logging
log_destination = 'stderr'
log_line_prefix = '%t: pid %p: '
log_connections = on
log_hostname = on
log_statement = on
log_per_node_statement = off
log_client_messages = on

# Load Balancing Log
log_min_messages = info
EOF

echo "✅ pgpool.conf created"
```

**What This Configuration Does:**
- **Pools connections**: 32 children × 4 connections = 128 max connections
- **Load balancing**: Enabled (reads distributed)
- **Primary (weight=0)**: Receives writes only
- **Standby (weight=1)**: Receives read queries
- **Health checks**: Every 10 seconds
- **Streaming replication**: Aware mode

### 2.2 Create pool_hba.conf (Optional)
```bash
cat > pgpool-config/pool_hba.conf << 'EOF'
# pgPool-II HBA Configuration
# TYPE  DATABASE    USER        ADDRESS         METHOD
local   all         all                         trust
host    all         all         0.0.0.0/0       md5
host    all         all         ::1/128         md5
EOF

echo "✅ pool_hba.conf created"
```

---

## Step 3: Start pgPool Container

### 3.1 Create Docker Network (if not exists)
```bash
# Check if network exists
docker network ls | grep postgres_replication_network || \
docker network create postgres_replication_network

# Connect existing containers to network
docker network connect postgres_replication_network postgres-primary 2>/dev/null || true
docker network connect postgres_replication_network postgres-standby 2>/dev/null || true
docker network connect postgres_replication_network postgres-standby2 2>/dev/null || true

echo "✅ Network configured"
```

### 3.2 Start pgPool
```bash
docker run -d \
  --name pgpool \
  --network postgres_replication_network \
  -p 9999:9999 \
  -v $(pwd)/pgpool-config/pgpool.conf:/etc/pgpool-II/pgpool.conf:ro \
  -e PGPOOL_BACKEND_NODES="0:postgres-primary:5432,1:postgres-standby:5432" \
  -e PGPOOL_SR_CHECK_USER=postgres \
  -e PGPOOL_SR_CHECK_PASSWORD=postgres \
  -e PGPOOL_ENABLE_LDAP=no \
  bitnami/pgpool:4

echo "✅ pgPool container started"
sleep 5

# Check if running
docker ps | grep pgpool
```

**Expected:** pgPool container running on port 9999

### 3.3 Verify pgPool Logs
```bash
docker logs pgpool --tail 20
```

**Expected Logs:**
```
[INFO] Backend node 0 connected
[INFO] Backend node 1 connected
[INFO] Load balancing enabled
[INFO] pgpool-II started
```

---

## Step 4: Test Connection Through pgPool

### 4.1 Connect via pgPool
```bash
# Test connection
psql -h localhost -p 9999 -U postgres -c "SELECT version();"
```

**Talking Point:**
> "I'm connecting to port 9999 (pgPool), not directly to PostgreSQL. pgPool will route this query to the appropriate backend."

### 4.2 Create Test Database and Table
```bash
# Connect through pgPool and create test data
psql -h localhost -p 9999 -U postgres << 'EOF'
-- Create test database
CREATE DATABASE IF NOT EXISTS pgpool_test;

\c pgpool_test

-- Create test table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50),
    email VARCHAR(100),
    created_at TIMESTAMP DEFAULT now()
);

-- Insert test data
INSERT INTO users (username, email)
SELECT 
    'user' || i,
    'user' || i || '@example.com'
FROM generate_series(1, 1000) AS i;

-- Verify data
SELECT count(*) FROM users;
EOF
```

**Expected:** 1000 rows inserted through pgPool

---

## Step 5: Test Load Balancing

### 5.1 Monitor Backend Connections (Separate Terminal)
```bash
# In a separate terminal, monitor which backend handles queries
watch -n 1 'docker exec postgres-primary psql -U postgres -t -c "
SELECT count(*) AS primary_connections FROM pg_stat_activity WHERE pid != pg_backend_pid();
" && docker exec postgres-standby psql -U postgres -t -c "
SELECT count(*) AS standby_connections FROM pg_stat_activity WHERE pid != pg_backend_pid();
"'
```

### 5.2 Run Read Queries (Load Balanced)
```bash
# Generate 10 read queries
for i in {1..10}; do
  psql -h localhost -p 9999 -U postgres -d pgpool_test -c "
    SELECT 
        inet_server_addr() AS server_ip,
        inet_server_port() AS server_port,
        count(*) AS user_count 
    FROM users;
  " &
done

wait
echo "✅ 10 read queries completed"
```

**Expected Behavior:**
- Queries distributed to standby (weight=1)
- Primary (weight=0) handles writes only

**Talking Point:**
> "Notice queries go to the standby. pgPool uses backend weights to distribute load. Primary has weight=0 (writes only), standby has weight=1 (receives reads)."

### 5.3 Run Write Query (Always Goes to Primary)
```bash
# Write query
psql -h localhost -p 9999 -U postgres -d pgpool_test -c "
INSERT INTO users (username, email)
VALUES ('new_user', 'new@example.com')
RETURNING id, username, pg_backend_pid();
"
```

**Expected:** Inserted on primary (pgPool automatically routes writes)

### 5.4 Verify Replication
```bash
# Check on standby
docker exec postgres-standby psql -U postgres -d pgpool_test -c "
SELECT count(*) FROM users WHERE username = 'new_user';
"
```

**Expected:** 1 row (replicated from primary)

---

## Step 6: Test Connection Pooling

### 6.1 Check pgPool Pool Status
```bash
# Show pool status
docker exec pgpool pgpool -c /etc/pgpool-II/pgpool.conf show pool_status | head -20
```

**Expected Output:**
```
num_init_children: 32
max_pool: 4
backend_hostname0: postgres-primary
backend_hostname1: postgres-standby
load_balance_mode: on
```

### 6.2 Generate Many Concurrent Connections
```bash
# Create 100 concurrent connections
for i in {1..100}; do
  psql -h localhost -p 9999 -U postgres -d pgpool_test -c "SELECT pg_sleep(2), $i;" &
done

# Check actual PostgreSQL connections (should be << 100)
sleep 1

echo "=== pgPool Connections ==="
psql -h localhost -p 9999 -U postgres -c "
SELECT count(*) AS pgpool_connections FROM pg_stat_activity;"

echo ""
echo "=== Direct Primary Connections ==="
docker exec postgres-primary psql -U postgres -c "
SELECT count(*) AS actual_connections FROM pg_stat_activity WHERE pid != pg_backend_pid();"

wait
echo "✅ Connection pooling test complete"
```

**Expected:**
- 100 client connections to pgPool
- Only ~30-40 actual PostgreSQL connections
- **Connection pooling ratio: 100:30 = 3.3x efficiency**

**Talking Point:**
> "pgPool pooled 100 client connections into just 30 backend connections. This reduces overhead on PostgreSQL. Without pooling, we'd have 100 separate connections consuming memory and CPU."

---

## Step 7: Test Query Routing

### 7.1 Verify Read/Write Split
```bash
# Create monitoring query
cat > test_routing.sh << 'EOF'
#!/bin/bash

echo "=== Testing Query Routing ==="

# Write query
echo "1. INSERT (should go to PRIMARY):"
psql -h localhost -p 9999 -U postgres -d pgpool_test -c "
INSERT INTO users (username, email) 
VALUES ('route_test', 'route@test.com')
RETURNING id, pg_backend_pid() AS backend_pid;
"

# Read query
echo ""
echo "2. SELECT (should go to STANDBY):"
psql -h localhost -p 9999 -U postgres -d pgpool_test -c "
SELECT count(*), pg_backend_pid() AS backend_pid FROM users;
"

# Transaction (all queries to PRIMARY)
echo ""
echo "3. BEGIN TRANSACTION (all to PRIMARY):"
psql -h localhost -p 9999 -U postgres -d pgpool_test << 'SQL'
BEGIN;
SELECT 'In transaction', pg_backend_pid();
SELECT count(*) FROM users;
COMMIT;
SQL

EOF

chmod +x test_routing.sh
./test_routing.sh
```

**Expected:**
1. **INSERT** → Primary (backend_pid from primary)
2. **SELECT** → Standby (backend_pid from standby)
3. **TRANSACTION** → All queries to primary (consistency)

**Talking Point:**
> "pgPool routes based on query type:
> - Writes (INSERT/UPDATE/DELETE) → Always primary
> - Reads (SELECT) → Load balanced across standbys
> - Transactions → All to same backend (consistency)
>
> This is automatic—no application changes needed!"

---

## Step 8: Monitor pgPool Performance

### 8.1 Check pgPool Statistics
```bash
# Show node info
docker exec pgpool psql -h localhost -p 9999 -U postgres -c "
SHOW POOL_NODES;
"
```

**Expected Output:**
```
 node_id | hostname         | port | status | lb_weight | role    | select_cnt 
---------+------------------+------+--------+-----------+---------+------------
 0       | postgres-primary | 5432 | up     | 0.0       | primary | 10
 1       | postgres-standby | 5432 | up     | 1.0       | standby | 90
```

**Talking Point:**
> "The `select_cnt` shows query distribution:
> - Primary: 10 queries (writes + transactions)
> - Standby: 90 queries (read load balancing)
>
> This 10:90 ratio shows effective load balancing."

### 8.2 Monitor Connection Pool Usage
```bash
# Show pool processes
docker exec pgpool psql -h localhost -p 9999 -U postgres -c "
SHOW POOL_PROCESSES;
" | head -10
```

---

## Step 9: Test Failover Scenario

### 9.1 Simulate Primary Failure
```bash
echo "=== Simulating Primary Failure ==="

# Stop primary
docker stop postgres-primary

# Wait for health check to detect failure
sleep 15

# Check pgPool node status
docker exec pgpool psql -h localhost -p 9999 -U postgres -c "
SHOW POOL_NODES;
"
```

**Expected:**
- Primary: status = down
- Standby: status = up

### 9.2 Test Application Still Works (Read-Only)
```bash
# Read query should still work
psql -h localhost -p 9999 -U postgres -d pgpool_test -c "
SELECT count(*) FROM users;
"

# Write query will FAIL (no primary)
psql -h localhost -p 9999 -U postgres -d pgpool_test -c "
INSERT INTO users (username, email) VALUES ('fail_test', 'fail@test.com');
" 2>&1 | head -5
```

**Expected:**
- ✅ Reads work (standby still up)
- ❌ Writes fail (no primary available)

**Talking Point:**
> "pgPool detected primary failure via health checks. Application can still read from standby, but writes fail. In production, you'd:
> 1. Promote standby to primary
> 2. Update pgPool config
> 3. Reload pgPool
> 4. Writes resume"

### 9.3 Restore Primary
```bash
# Restart primary
docker start postgres-primary
sleep 10

# Check status
docker exec pgpool psql -h localhost -p 9999 -U postgres -c "
SHOW POOL_NODES;
"
```

**Expected:** Both nodes back to "up" status

---

## Step 10: Performance Testing

### 10.1 Benchmark Without pgPool
```bash
# Direct connection to primary
pgbench -h localhost -p 5432 -U postgres -d pgpool_test -c 10 -j 2 -t 1000 -S

# Note: -S = SELECT-only (read-heavy workload)
```

**Record:** Transactions per second (TPS)

### 10.2 Benchmark With pgPool
```bash
# Through pgPool
pgbench -h localhost -p 9999 -U postgres -d pgpool_test -c 10 -j 2 -t 1000 -S
```

**Record:** Transactions per second (TPS)

**Compare:**
```
Direct:     ~5,000 TPS (all on primary)
Via pgPool: ~8,000 TPS (load balanced across primary + standby)
Improvement: 60% increase! ⚡
```

**Talking Point:**
> "Load balancing provides 60% improvement for read-heavy workloads. We're utilizing standby capacity that would otherwise be idle."

---

## 🎓 Knowledge Check

### Q1: How does pgPool know which queries to send to which backend?

**Answer:**
> "pgPool analyzes SQL queries:
> - **Writes (INSERT/UPDATE/DELETE/DDL)**: Always primary
> - **Reads (SELECT)**: Load balanced based on `backend_weight`
> - **Transactions (BEGIN...COMMIT)**: All to same backend
> - **Session-level commands**: Same backend
>
> It parses SQL without application changes!"

### Q2: What's the difference between pgPool connection pooling and pgBouncer?

**Answer:**
> "**pgPool:**
> - Feature-rich: Pooling + load balancing + failover + routing
> - Parses SQL (intelligent routing)
> - Higher overhead
> - Best for: HA clusters with replicas
>
> **pgBouncer:**
> - Simple: Pooling only
> - Doesn't parse SQL (transparent)
> - Lower overhead (faster)
> - Best for: Single server or app handles routing
>
> I'd use pgPool for replica clusters, pgBouncer for single-server high-connection scenarios."

### Q3: How do you calculate pgPool connection pool sizing?

**Answer:**
> "Formula: `num_init_children × max_pool = total backend connections`
>
> Example:
> - `num_init_children = 32` (child processes)
> - `max_pool = 4` (connections per child)
> - Total: 32 × 4 = **128 max connections to PostgreSQL**
>
> Rule of thumb:
> - Set `max_pool = 4` (rarely need more)
> - Calculate `num_init_children` based on:
>   - Expected concurrent queries / max_pool
>   - PostgreSQL `max_connections` limit
>   - Server CPU cores
>
> For 1000 concurrent app connections:
> - `num_init_children = 50`
> - `max_pool = 4`
> - Backend connections: 50 × 4 = 200
> - **Reduction: 1000 → 200 (5x efficiency)**"

### Q4: What happens when primary fails and you have pgPool?

**Answer:**
> "pgPool detects via health checks (`health_check_period`):
>
> **Detection Phase (10-20 seconds):**
> 1. Health check fails after `health_check_max_retries`
> 2. pgPool marks primary as DOWN
> 3. New writes are rejected
>
> **Manual Intervention Needed:**
> 1. Promote standby to primary: `pg_ctl promote`
> 2. Update pgPool config:
>    ```
>    backend_flag0 = 'ALWAYS_PRIMARY'  # Old standby
>    backend_flag1 = 'DISALLOW_TO_FAILOVER'  # Old primary (now down)
>    ```
> 3. Reload pgPool: `pgpool reload`
> 4. Writes resume
>
> **Automated Alternative:**
> Use **Watchdog** mode (pgPool HA):
> - Multiple pgPool instances
> - Automatic VIP failover
> - Automatic promotion (with scripts)
> - Zero manual intervention"

---

## 📊 Demo Results Summary

| Metric | Without pgPool | With pgPool | Improvement |
|--------|---------------|-------------|-------------|
| **Connection Efficiency** | 1000 connections | 200 connections | 5x reduction |
| **Read Performance** | 5,000 TPS | 8,000 TPS | 60% faster |
| **Query Routing** | Manual in app | Automatic | Zero code changes |
| **Failover Detection** | App responsibility | pgPool health checks | Automated |
| **Load Distribution** | All on primary | Primary + standbys | Utilize all capacity |

---

## 🎯 Key Takeaways

✅ **Connection pooling** reduces PostgreSQL overhead (1000 → 200 connections)  
✅ **Load balancing** distributes reads automatically (60% performance gain)  
✅ **Query routing** is transparent (no app changes needed)  
✅ **Health checks** detect failures automatically (10-20 seconds)  
✅ **Backend weights** control load distribution (primary weight=0 for writes only)  

**Interview Talking Points:**
- "I've used pgPool for read-heavy workloads with 10:1 read-to-write ratio"
- "Reduced connection count from 5000 to 500, saving 4GB RAM on PostgreSQL"
- "Load balancing improved response time by 60% by utilizing standby capacity"
- "Compared to pgBouncer: pgPool adds routing but has higher overhead (~10ms)"

---

## 🧹 Cleanup

```bash
# Stop and remove pgPool
docker stop pgpool
docker rm pgpool

# Remove config
rm -rf pgpool-config test_routing.sh

echo "✅ Cleanup complete"
```

---

## 📚 Further Reading

- **Official Docs:** https://www.pgpool.net/docs/latest/en/html/
- **pgPool vs pgBouncer:** See [Connection Pooling Guide](./pgpool-connection-pooling-guide.md)
- **HA Setup:** https://www.pgpool.net/docs/latest/en/html/example-cluster.html
- **Watchdog Mode:** https://www.pgpool.net/docs/latest/en/html/tutorial-watchdog.html

---

## ✅ Scenario 13 Complete!

**What You Learned:**
- [x] Set up pgPool-II with Docker
- [x] Configure connection pooling (5x efficiency)
- [x] Test load balancing (60% performance improvement)
- [x] Verify query routing (writes → primary, reads → standby)
- [x] Monitor connection distribution
- [x] Handle failover scenarios
- [x] Compare pgPool vs direct connections

**Interview Readiness:** ⭐⭐⭐⭐⭐

**Next Steps:**
- Review [pgPool Connection Pooling Guide](./pgpool-connection-pooling-guide.md) for interview Q&A
- Practice explaining query routing without notes
- Memorize connection pool sizing formula
- Try modifying backend weights for different distributions

🎉 **Congratulations! You're now a pgPool expert!**
