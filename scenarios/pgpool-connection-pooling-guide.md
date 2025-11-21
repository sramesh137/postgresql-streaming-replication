# pgPool-II: Connection Pooling & Load Balancing Guide

**Essential Knowledge for PostgreSQL DBAs**

---

## 🎯 What is pgPool-II?

**pgPool-II** is a middleware that sits between your application and PostgreSQL servers, providing:

1. **Connection Pooling** - Reduces connection overhead
2. **Load Balancing** - Distributes read queries across replicas
3. **Query Routing** - Sends writes to primary, reads to standbys
4. **High Availability** - Automatic failover detection
5. **Connection Limiting** - Prevents server overload

```
┌─────────────────────────────────────────┐
│  Applications (1000 connections)        │
└──────────────┬──────────────────────────┘
               │
               ↓
┌─────────────────────────────────────────┐
│  pgPool-II (maintains 20 DB connections)│
│  - Connection pooling                   │
│  - Load balancing reads                 │
│  - Route writes to primary              │
└──────────────┬──────────────────────────┘
               │
       ┌───────┴───────┐
       ↓               ↓
┌──────────────┐  ┌──────────────┐
│ PRIMARY      │  │ STANDBY      │
│ (writes)     │  │ (reads)      │
└──────────────┘  └──────────────┘
```

---

## 🆚 pgPool-II vs pgBouncer

| Feature | pgPool-II | pgBouncer | Winner |
|---------|-----------|-----------|--------|
| **Connection Pooling** | ✅ Yes | ✅ Yes | Tie |
| **Load Balancing** | ✅ Yes | ❌ No | pgPool |
| **Automatic Failover** | ✅ Yes | ❌ No | pgPool |
| **Query Routing** | ✅ Yes (read/write split) | ❌ No | pgPool |
| **Replication Mode** | ✅ Multiple modes | ❌ N/A | pgPool |
| **Performance** | Good | ⚡ Excellent | pgBouncer |
| **Memory Usage** | Higher | Lower | pgBouncer |
| **Complexity** | Complex | Simple | pgBouncer |
| **Best For** | HA clusters with replicas | Simple connection pooling | Depends |

**Rule of Thumb:**
- Use **pgBouncer** for simple connection pooling (single server or app handles routing)
- Use **pgPool-II** for HA clusters with read/write splitting and load balancing

---

## 🏗️ pgPool-II Architecture

### Operating Modes

**1. Streaming Replication Mode (Most Common)**
```
App → pgPool → Primary (writes) + Standby (reads)
```
- Writes go to primary
- Reads distributed across all servers
- Built-in health checks
- Automatic failover

**2. Master-Slave Mode (Legacy)**
- Similar to streaming replication mode
- For older PostgreSQL versions (< 9.0)

**3. Native Replication Mode**
- pgPool manages replication (not recommended)
- Use PostgreSQL's built-in streaming replication instead

**4. Snapshot Isolation Mode**
- Ensures read consistency
- Used with logical replication

---

## 📦 Installation

### Docker Installation (For Testing)

```bash
# Create docker-compose.yml
cat > docker-compose-pgpool.yml << 'EOF'
version: '3.8'

services:
  pgpool:
    image: bitnami/pgpool:4
    ports:
      - "5432:5432"
    environment:
      - PGPOOL_BACKEND_NODES=0:postgres-primary:5432,1:postgres-standby:5432
      - PGPOOL_SR_CHECK_USER=postgres
      - PGPOOL_SR_CHECK_PASSWORD=postgres
      - PGPOOL_ENABLE_LDAP=no
      - PGPOOL_POSTGRES_USERNAME=postgres
      - PGPOOL_POSTGRES_PASSWORD=postgres
      - PGPOOL_ADMIN_USERNAME=admin
      - PGPOOL_ADMIN_PASSWORD=admin
      - PGPOOL_ENABLE_LOAD_BALANCING=yes
      - PGPOOL_MAX_POOL=20
      - PGPOOL_CHILD_MAX_CONNECTIONS=50
      - PGPOOL_NUM_INIT_CHILDREN=10
    depends_on:
      - postgres-primary
      - postgres-standby
    networks:
      - postgres-network

  postgres-primary:
    image: postgres:15
    environment:
      POSTGRES_PASSWORD: postgres
    volumes:
      - primary-data:/var/lib/postgresql/data
    networks:
      - postgres-network

  postgres-standby:
    image: postgres:15
    environment:
      POSTGRES_PASSWORD: postgres
    volumes:
      - standby-data:/var/lib/postgresql/data
    networks:
      - postgres-network

volumes:
  primary-data:
  standby-data:

networks:
  postgres-network:
    driver: bridge
EOF

# Start services
docker-compose -f docker-compose-pgpool.yml up -d
```

### Ubuntu/Debian Installation

```bash
# Install pgPool-II
sudo apt-get update
sudo apt-get install -y pgpool2

# Configuration files location
/etc/pgpool2/pgpool.conf
/etc/pgpool2/pool_hba.conf
/etc/pgpool2/pool_passwd
```

---

## ⚙️ Configuration

### Basic Configuration (`/etc/pgpool2/pgpool.conf`)

```ini
#------------------------------------------------------
# BACKEND CONNECTIONS
#------------------------------------------------------
# Define PostgreSQL servers
backend_hostname0 = 'primary.example.com'
backend_port0 = 5432
backend_weight0 = 1    # 0 = no reads, 1 = normal weight
backend_flag0 = 'ALWAYS_PRIMARY'

backend_hostname1 = 'standby1.example.com'
backend_port1 = 5432
backend_weight1 = 1    # Equal weight for load balancing
backend_flag1 = 'DISALLOW_TO_FAILOVER'

backend_hostname2 = 'standby2.example.com'
backend_port2 = 5432
backend_weight2 = 1
backend_flag2 = 'DISALLOW_TO_FAILOVER'

#------------------------------------------------------
# CONNECTION POOLING
#------------------------------------------------------
# Listen on all interfaces
listen_addresses = '*'
port = 9999

# Connection pool settings
num_init_children = 32           # Number of pre-forked child processes
max_pool = 4                     # Number of connection pools per child
child_life_time = 300            # Child process lifetime (seconds)
child_max_connections = 0        # Max connections per child (0=unlimited)
connection_life_time = 0         # Connection lifetime (0=unlimited)
client_idle_limit = 0            # Disconnect idle clients (0=never)

#------------------------------------------------------
# LOAD BALANCING
#------------------------------------------------------
load_balance_mode = on           # Enable load balancing
black_function_list = 'nextval,setval,lastval,currval'
white_function_list = ''

# Read query load balancing
statement_level_load_balance = on
read_only_function_list = ''
write_function_list = ''

#------------------------------------------------------
# STREAMING REPLICATION
#------------------------------------------------------
master_slave_mode = on           # Enable master/slave mode
master_slave_sub_mode = 'stream' # Streaming replication mode

# Streaming replication check
sr_check_period = 10             # Check interval (seconds)
sr_check_user = 'replicator'     # Replication user
sr_check_password = 'password'   # Replication password
sr_check_database = 'postgres'

# Delay threshold (milliseconds)
delay_threshold = 10000          # Don't route reads if lag > 10 seconds

#------------------------------------------------------
# HEALTH CHECK
#------------------------------------------------------
health_check_period = 10         # Health check interval
health_check_timeout = 20        # Health check timeout
health_check_user = 'postgres'
health_check_password = 'postgres'
health_check_database = 'postgres'
health_check_max_retries = 3
health_check_retry_delay = 1

#------------------------------------------------------
# FAILOVER
#------------------------------------------------------
failover_command = '/etc/pgpool2/failover.sh %d %h %p %D %m %H %M %P %r %R'
follow_master_command = '/etc/pgpool2/follow_master.sh %d %h %p %D %m %H %M %P %r %R'

# Watchdog (for HA - multiple pgPool instances)
use_watchdog = off               # Enable for multi-pgPool HA

#------------------------------------------------------
# LOGGING
#------------------------------------------------------
log_destination = 'stderr'
logging_collector = on
log_directory = '/var/log/pgpool'
log_filename = 'pgpool-%Y-%m-%d.log'
log_line_prefix = '%t: pid %p: '
log_connections = on
log_hostname = on
log_statement = off
log_per_node_statement = off
```

### Connection Pool Authentication (`/etc/pgpool2/pool_hba.conf`)

```
# TYPE  DATABASE    USER        ADDRESS          METHOD
host    all         all         0.0.0.0/0        md5
host    all         all         ::0/0            md5
```

### Password File (`/etc/pgpool2/pool_passwd`)

```bash
# Generate encrypted password
pg_md5 password
# Output: md53175bce1d3201d16594cebf9d7eb3f9d

# Add to pool_passwd
echo "postgres:md53175bce1d3201d16594cebf9d7eb3f9d" >> /etc/pgpool2/pool_passwd
```

---

## 🔄 Load Balancing Configuration

### Load Balancing Weights

**Scenario: Different server capacities**

```ini
# Primary: 8 cores, handle 10% of reads
backend_weight0 = 1

# Standby 1: 16 cores, handle 45% of reads
backend_weight1 = 4.5

# Standby 2: 16 cores, handle 45% of reads
backend_weight2 = 4.5

# Total weight = 1 + 4.5 + 4.5 = 10
# Primary: 1/10 = 10%
# Standby1: 4.5/10 = 45%
# Standby2: 4.5/10 = 45%
```

### Query Routing Examples

```sql
-- This goes to PRIMARY only
BEGIN;
INSERT INTO orders VALUES (1, 'test');
COMMIT;

-- This can go to ANY server (load balanced)
SELECT * FROM orders WHERE id = 1;

-- This goes to PRIMARY (SELECT FOR UPDATE)
SELECT * FROM orders WHERE id = 1 FOR UPDATE;

-- Functions in black_function_list go to PRIMARY
SELECT nextval('orders_id_seq');

-- Explicit primary routing using SQL comment
/*NO LOAD BALANCE*/ SELECT * FROM orders;
```

---

## 📊 Monitoring pgPool-II

### Show Pool Status

```sql
-- Connect to pgPool admin interface
psql -h localhost -p 9999 -U postgres

-- Show all backend nodes
SHOW pool_nodes;

-- Output:
 node_id | hostname | port | status | lb_weight | role    | select_cnt | load_balance_node | replication_delay 
---------+----------+------+--------+-----------+---------+------------+-------------------+-------------------
 0       | primary  | 5432 | up     | 0.100000  | primary | 1234       | false             | 0
 1       | standby1 | 5432 | up     | 0.450000  | standby | 5678       | true              | 0
 2       | standby2 | 5432 | up     | 0.450000  | standby | 5432       | false             | 100
```

### Show Pool Processes

```sql
SHOW pool_processes;

-- Output shows:
-- - Active connections
-- - Database and user
-- - Application name
-- - Connection start time
```

### Show Pool Pools

```sql
SHOW pool_pools;

-- Shows connection pool status:
-- - Pool ID
-- - Backend ID
-- - Database/User
-- - Connection create time
```

### PCP Commands (pgPool Control Protocol)

```bash
# Show node information
pcp_node_info -h localhost -p 9898 -U postgres 0

# Attach a node
pcp_attach_node -h localhost -p 9898 -U postgres 1

# Detach a node (graceful)
pcp_detach_node -h localhost -p 9898 -U postgres 1

# Show pool status
pcp_pool_status -h localhost -p 9898 -U postgres

# Reload configuration
pcp_reload_config -h localhost -p 9898 -U postgres
```

---

## 🚨 Common Issues & Solutions

### Issue 1: Reads Going to Primary Only

**Symptom:**
```sql
SHOW pool_nodes;
-- All select_cnt incrementing on node 0 only
```

**Causes:**
1. Load balancing disabled
2. Inside a transaction
3. Query contains write operations
4. Using session-level settings

**Solution:**
```ini
# Enable load balancing
load_balance_mode = on
statement_level_load_balance = on

# Check query doesn't start a transaction
# Explicit routing:
SELECT * FROM orders;  -- Load balanced ✅
BEGIN;
SELECT * FROM orders;  -- Goes to primary ❌
COMMIT;
```

### Issue 2: Connection Pool Exhaustion

**Symptom:**
```
ERROR: sorry, too many clients already
```

**Diagnosis:**
```sql
SHOW pool_processes;
-- Check num_init_children * max_pool
```

**Solution:**
```ini
# Increase pool size
num_init_children = 50    # From 32
max_pool = 4              # Pools per child

# Total connections: 50 * 4 = 200
```

### Issue 3: Replication Lag Causing Stale Reads

**Symptom:** Application reads old data from standby

**Solution:**
```ini
# Don't route to lagging standbys
delay_threshold = 10000   # 10 seconds

# Or disable load balancing for critical queries
/*NO LOAD BALANCE*/ SELECT * FROM orders WHERE id = 123;
```

### Issue 4: Failover Not Working

**Symptom:** Primary fails, pgPool doesn't promote standby

**Diagnosis:**
```bash
# Check health check settings
health_check_period = 10
health_check_timeout = 20
health_check_max_retries = 3

# Check failover script
/etc/pgpool2/failover.sh
```

**Solution:**
```bash
# Create failover script
cat > /etc/pgpool2/failover.sh << 'EOF'
#!/bin/bash
# Arguments: %d %h %p %D %m %H %M %P %r %R
FAILED_NODE=$1
FAILED_HOST=$2
FAILED_PORT=$3
NEW_MASTER=$4

# Promote standby
ssh $NEW_MASTER "pg_ctl promote -D /var/lib/postgresql/data"

# Update application DNS/config
# ...
EOF

chmod +x /etc/pgpool2/failover.sh
```

---

## 🎯 Production Best Practices

### 1. Connection Pool Sizing

**Formula:**
```
pgPool connections = num_init_children × max_pool
PostgreSQL connections needed = pgPool connections + overhead

Example:
num_init_children = 32
max_pool = 4
Total: 32 × 4 = 128 connections to PostgreSQL

PostgreSQL max_connections should be: 128 + 20 (overhead) = 150
```

**Tuning Guidelines:**
- Start with `num_init_children = CPU cores × 4`
- Monitor connection usage
- Adjust based on workload

### 2. Load Balancing Strategy

**For OLTP (transactional):**
```ini
# Most queries are inside transactions (go to primary)
statement_level_load_balance = off
```

**For OLAP/Reporting:**
```ini
# Heavy SELECT queries benefit from load balancing
statement_level_load_balance = on
backend_weight0 = 0.1  # Primary: minimal reads
backend_weight1 = 1    # Standby 1: heavy reads
```

**For Mixed Workload:**
```ini
statement_level_load_balance = on
backend_weight0 = 0.3  # Primary: 30% reads
backend_weight1 = 0.7  # Standby: 70% reads
```

### 3. Health Check Tuning

```ini
# Conservative (safe but slow to detect failures)
health_check_period = 30
health_check_timeout = 30
health_check_max_retries = 5

# Aggressive (fast detection but may false-positive)
health_check_period = 5
health_check_timeout = 10
health_check_max_retries = 2

# Recommended (balanced)
health_check_period = 10
health_check_timeout = 20
health_check_max_retries = 3
```

### 4. Monitoring & Alerting

**Key Metrics to Monitor:**
```bash
# Backend status
SHOW pool_nodes;
# Alert if: status != 'up'

# Connection pool usage
SHOW pool_processes;
# Alert if: usage > 80%

# Replication delay
SHOW pool_nodes;
# Alert if: replication_delay > 10000 ms

# Query distribution
SELECT node_id, select_cnt FROM pool_nodes;
# Alert if: imbalanced (one node has 90%+ traffic)
```

---

## 💼 Interview Questions & Answers

### Q1: "What's the difference between pgPool-II and pgBouncer?"

**Answer:**
> "Both provide connection pooling, but pgPool-II is much more feature-rich while pgBouncer is simpler and faster. pgPool-II offers load balancing, automatic failover, and read/write query routing, making it ideal for HA clusters with primary-standby replication. pgBouncer focuses solely on connection pooling with minimal overhead—about 100 bytes per connection.
>
> In our production environment, we use pgBouncer for simple connection pooling because our application handles read/write routing. But for a multi-tenant SaaS where we need automatic load balancing across read replicas, pgPool-II would be the better choice.
>
> Performance-wise, pgBouncer is lighter: it can handle 10,000+ connections with < 10 MB memory, whereas pgPool-II uses more resources for its additional features."

### Q2: "How does pgPool-II route queries to different backends?"

**Answer:**
> "pgPool-II uses several rules:
>
> 1. **Write queries always go to primary**: INSERT, UPDATE, DELETE, DDL
> 2. **SELECT queries are load balanced** across all healthy nodes based on weights
> 3. **Transactions go to primary**: Any query inside BEGIN...COMMIT
> 4. **SELECT FOR UPDATE goes to primary**: Requires write lock
> 5. **Functions in black_function_list go to primary**: Like nextval(), which must be consistent
>
> You can override this with SQL comments: `/*NO LOAD BALANCE*/ SELECT ...` forces routing to primary.
>
> There's also a delay threshold: if a standby lags more than 10 seconds (configurable), pgPool stops routing reads to it to avoid stale data."

### Q3: "How do you handle failover with pgPool-II?"

**Answer:**
> "pgPool-II handles failover through health checks and failover scripts. Every 10 seconds (configurable), it runs a health check query on each backend. If a node fails 3 consecutive checks, pgPool executes the failover script.
>
> The failover script typically:
> 1. Promotes a standby to primary using `pg_promote()`
> 2. Updates DNS or application configuration
> 3. Reconfigures other standbys to follow new primary
>
> Critical gotcha from my experience: After promotion, you must disable synchronous replication on the new primary or writes will hang waiting for the dead server. This should be step 3 in the failover script.
>
> For even higher availability, you can run multiple pgPool instances with watchdog mode, so if one pgPool fails, another takes over using virtual IP address."

### Q4: "How do you size pgPool connection pools?"

**Answer:**
> "Connection pool sizing depends on the formula: `num_init_children × max_pool = total connections to PostgreSQL`.
>
> For example, with `num_init_children = 32` and `max_pool = 4`, pgPool maintains 128 connections to each PostgreSQL backend. PostgreSQL's `max_connections` must be at least 128 + 20 overhead = 150.
>
> I start with `num_init_children = CPU cores × 4`. For a 16-core server, that's 64 child processes. Then monitor connection usage: if you consistently hit 80%+ utilization, increase it. But don't over-provision—more children means more memory usage.
>
> For `max_pool`, the default of 4 works for most workloads. Higher values help with connection reuse but increase memory per child.
>
> The goal is: **enough connections to avoid bottlenecks, but not so many that PostgreSQL context-switching becomes an issue**. On PostgreSQL side, generally don't exceed 2-3× CPU cores for max_connections."

### Q5: "What monitoring do you set up for pgPool?"

**Answer:**
> "I monitor four key areas:
>
> 1. **Backend health**: `SHOW pool_nodes` - Alert if any node status != 'up' or replication_delay > 10 seconds
> 2. **Connection pool usage**: `SHOW pool_processes` - Alert if usage > 80%, may need to increase num_init_children
> 3. **Query distribution**: Check select_cnt per node - Alert if load imbalance (one node handling 90%+ queries)
> 4. **pgPool process health**: Monitor pgPool itself with systemd/supervisord
>
> I export these metrics to Prometheus:
> ```sql
> SELECT node_id, status, replication_delay FROM pool_nodes;
> SELECT COUNT(*) FROM pool_processes WHERE database != '';
> ```
>
> Also monitor pgPool logs for failover events, health check failures, and authentication errors. Set up alerting in PagerDuty for critical events like backend failures."

---

## 🔧 Practical Example: Setting Up pgPool with Existing Replication

**Scenario:** You already have primary + 2 standbys, want to add pgPool

```bash
# 1. Install pgPool
sudo apt-get install pgpool2

# 2. Configure backends
sudo tee /etc/pgpool2/pgpool.conf > /dev/null << 'EOF'
backend_hostname0 = '10.0.1.10'
backend_port0 = 5432
backend_weight0 = 0.1
backend_flag0 = 'ALWAYS_PRIMARY'

backend_hostname1 = '10.0.1.11'
backend_port1 = 5432
backend_weight1 = 0.45

backend_hostname2 = '10.0.1.12'
backend_port2 = 5432
backend_weight2 = 0.45

listen_addresses = '*'
port = 9999
num_init_children = 32
max_pool = 4
load_balance_mode = on
master_slave_mode = on
master_slave_sub_mode = 'stream'
sr_check_user = 'replicator'
sr_check_password = 'password'
health_check_period = 10
health_check_user = 'postgres'
health_check_password = 'postgres'
EOF

# 3. Configure authentication
sudo cp /etc/pgpool2/pool_hba.conf.sample /etc/pgpool2/pool_hba.conf
sudo tee -a /etc/pgpool2/pool_hba.conf > /dev/null << 'EOF'
host all all 0.0.0.0/0 md5
EOF

# 4. Add passwords
sudo pg_md5 -m -u postgres postgres

# 5. Start pgPool
sudo systemctl start pgpool2
sudo systemctl enable pgpool2

# 6. Test connection
psql -h localhost -p 9999 -U postgres -c "SHOW pool_nodes;"

# 7. Update application connection string
# FROM: postgres://10.0.1.10:5432/mydb
# TO:   postgres://pgpool-server:9999/mydb
```

---

## 📚 Further Reading

**Official Documentation:**
- [pgPool-II Documentation](https://www.pgpool.net/docs/latest/en/html/)
- [Configuration Parameters](https://www.pgpool.net/docs/latest/en/html/runtime-config.html)

**Comparison:**
- [pgPool vs pgBouncer](https://www.cybertec-postgresql.com/en/pgbouncer-vs-pgpool-ii/)

**Tutorials:**
- [Setting Up pgPool with Streaming Replication](https://www.pgpool.net/docs/latest/en/html/example-cluster.html)

---

## ✅ Summary

**pgPool-II Strengths:**
- ✅ Connection pooling (reduces PostgreSQL connection overhead)
- ✅ Load balancing (distributes reads across replicas)
- ✅ Automatic failover (detects primary failure, promotes standby)
- ✅ Query routing (writes → primary, reads → standbys)
- ✅ Built-in health checks

**When to Use:**
- Large HA clusters with multiple read replicas
- Need automatic read/write splitting
- Want built-in failover capabilities
- Application can't handle connection routing

**When NOT to Use:**
- Simple connection pooling only → Use pgBouncer (faster)
- Single PostgreSQL server → Use pgBouncer
- Application already handles routing → Unnecessary complexity

**Production Recommendation:**
For most setups, use **pgBouncer for connection pooling** + **HAProxy/Consul for load balancing** as it's simpler and more performant. Use pgPool-II when you need its integrated HA features and can accept the additional complexity.
