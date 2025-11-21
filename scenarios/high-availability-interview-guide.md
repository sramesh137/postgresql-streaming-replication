# PostgreSQL High Availability (HA) - Interview Guide

**Complete HA Architecture & Implementation for Senior DBAs**

---

## 🎯 What is High Availability?

**Definition:** The ability to keep the database operational with minimal downtime despite failures.

**Key Metrics:**
- **Availability:** 99.9% (8.76 hours downtime/year), 99.99% (52.56 minutes/year), 99.999% (5.26 minutes/year)
- **RTO (Recovery Time Objective):** Maximum acceptable downtime (e.g., 5 minutes)
- **RPO (Recovery Point Objective):** Maximum acceptable data loss (e.g., 0 seconds)

```
┌────────────────────────────────────────────────────────────┐
│  HIGH AVAILABILITY SPECTRUM                                │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  Basic          Intermediate        Advanced      Mission  │
│  99%            99.9%               99.99%        Critical │
│  ↓              ↓                   ↓             99.999%  │
│  Backups        + Hot Standby       + Sync Rep    ↓        │
│  only           + Auto failover     + Multi-AZ    + Multi  │
│                                                     Region  │
└────────────────────────────────────────────────────────────┘
```

---

## 🏗️ HA Architecture Patterns

### Pattern 1: Primary + Hot Standby (Basic HA)

```
┌─────────────────────────────────────┐
│  Application Layer                  │
│  (connection string with failover)  │
└──────────────┬──────────────────────┘
               │
       ┌───────┴───────┐
       ↓               ↓
┌──────────────┐  ┌──────────────┐
│  PRIMARY     │  │  STANDBY     │
│  (Read/Write)│→→│  (Read-Only) │
│  Port 5432   │  │  Port 5432   │
└──────────────┘  └──────────────┘
       │               │
       ↓               ↓
  Streaming WAL  Applies WAL

Characteristics:
- RTO: 1-5 minutes (manual failover)
- RPO: 0-30 seconds (async replication)
- Availability: 99.9%
- Cost: Low
```

**When to Use:**
- Small to medium applications
- Can tolerate manual failover
- Budget-conscious projects
- Development/staging environments

---

### Pattern 2: Primary + Multi-Standby + Automatic Failover

```
┌─────────────────────────────────────┐
│  Application Layer                  │
└──────────────┬──────────────────────┘
               │
       ┌───────┴─────────┐
       ↓                 ↓
┌──────────────┐   ┌──────────────┐
│  HAProxy/    │   │  Patroni/    │
│  pgBouncer   │   │  Repmgr      │
│  (Proxy)     │   │  (Failover)  │
└──────┬───────┘   └──────┬───────┘
       │                  │
       │         ┌────────┴────────┐
       │         ↓                 ↓
       │   ┌──────────┐      ┌──────────┐
       └──→│ PRIMARY  │─────→│ STANDBY1 │
           │          │      │          │
           └────┬─────┘      └──────────┘
                │                  ↓
                │            ┌──────────┐
                └───────────→│ STANDBY2 │
                             │          │
                             └──────────┘

Characteristics:
- RTO: 30 seconds - 2 minutes (automatic)
- RPO: 0 seconds (sync rep to 1 standby)
- Availability: 99.95-99.99%
- Cost: Medium
```

**When to Use:**
- Production applications
- Need automatic failover
- Can afford synchronous replication lag
- Most common enterprise setup

---

### Pattern 3: Multi-Region HA (Disaster Recovery)

```
┌─────── Region 1 (Primary) ──────┐    ┌─────── Region 2 (DR) ──────┐
│                                  │    │                             │
│  ┌──────────┐    ┌──────────┐  │    │  ┌──────────┐               │
│  │ PRIMARY  │───→│ STANDBY1 │  │    │  │ STANDBY2 │               │
│  │ US-East  │    │ US-East  │  │ ═══╪═→│ US-West  │               │
│  └──────────┘    └──────────┘  │    │  └──────────┘               │
│       ↓               ↓          │    │       ↓                     │
│   ┌────────────────────────┐   │    │  ┌──────────┐               │
│   │  S3/Azure Blob         │   │ ═══╪═→│  S3 Copy │               │
│   │  (WAL Archive)         │   │    │  │          │               │
│   └────────────────────────┘   │    │  └──────────┘               │
└──────────────────────────────────┘    └─────────────────────────────┘
        Sync Replication                    Async Replication

Characteristics:
- RTO: 2-10 minutes (regional failover)
- RPO: 0 seconds (sync in primary region)
- Availability: 99.99-99.999%
- Cost: High
```

**When to Use:**
- Mission-critical applications
- Must survive regional disasters
- Financial services, healthcare
- 24/7 global operations

---

## 🔧 HA Components & Tools

### 1. Patroni (Recommended for Production)

**What:** HA solution using distributed consensus (etcd/Consul/ZooKeeper)

**Architecture:**
```
┌─────────────────────────────────────────┐
│  etcd Cluster (Consensus)               │
│  Stores: Leader info, config            │
└──────────────┬──────────────────────────┘
               │
       ┌───────┼───────┐
       ↓       ↓       ↓
┌─────────┐ ┌─────────┐ ┌─────────┐
│Patroni 1│ │Patroni 2│ │Patroni 3│
│+ PG     │ │+ PG     │ │+ PG     │
│PRIMARY  │ │STANDBY1 │ │STANDBY2 │
└─────────┘ └─────────┘ └─────────┘
```

**Installation (Ubuntu):**
```bash
# Install prerequisites
sudo apt-get install -y python3-pip python3-dev postgresql-15

# Install Patroni
sudo pip3 install patroni[etcd]

# Install etcd (consensus layer)
sudo apt-get install etcd

# Configure Patroni
sudo vi /etc/patroni.yml
```

**Patroni Configuration:**
```yaml
# /etc/patroni.yml
scope: postgres-cluster
namespace: /db/
name: node1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.1.10:8008

etcd:
  hosts: 10.0.1.10:2379,10.0.1.11:2379,10.0.1.12:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576  # 1MB
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: on
        max_connections: 200
        max_wal_senders: 10
        wal_keep_size: 1GB
        max_replication_slots: 10
        
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.1.10:5432
  data_dir: /var/lib/postgresql/15/main
  bin_dir: /usr/lib/postgresql/15/bin
  authentication:
    replication:
      username: replicator
      password: rep_password
    superuser:
      username: postgres
      password: postgres_password
  parameters:
    unix_socket_directories: '/var/run/postgresql'

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

**Start Patroni:**
```bash
# Start as systemd service
sudo systemctl start patroni
sudo systemctl enable patroni

# Check cluster status
patronictl -c /etc/patroni.yml list

# Output:
+ Cluster: postgres-cluster (7456789012345678901) ----+----+-----------+
| Member | Host        | Role    | State     | TL | Lag in MB |
+--------+-------------+---------+-----------+----+-----------+
| node1  | 10.0.1.10   | Leader  | running   |  1 |           |
| node2  | 10.0.1.11   | Replica | streaming |  1 |         0 |
| node3  | 10.0.1.12   | Replica | streaming |  1 |         0 |
+--------+-------------+---------+-----------+----+-----------+
```

**Patroni Operations:**
```bash
# Manual failover
patronictl -c /etc/patroni.yml failover

# Switchover (graceful)
patronictl -c /etc/patroni.yml switchover

# Restart node
patronictl -c /etc/patroni.yml restart node1

# Reload configuration
patronictl -c /etc/patroni.yml reload postgres-cluster

# Reinitialize node
patronictl -c /etc/patroni.yml reinit postgres-cluster node2
```

---

### 2. Repmgr (Simpler Alternative)

**What:** Lightweight replication management tool

**Installation:**
```bash
sudo apt-get install postgresql-15-repmgr
```

**Configuration:**
```ini
# /etc/repmgr.conf
node_id=1
node_name=node1
conninfo='host=10.0.1.10 user=repmgr dbname=repmgr connect_timeout=2'
data_directory='/var/lib/postgresql/15/main'
replication_user='replicator'

failover='automatic'
promote_command='/usr/bin/repmgr standby promote -f /etc/repmgr.conf --log-to-file'
follow_command='/usr/bin/repmgr standby follow -f /etc/repmgr.conf --log-to-file --upstream-node-id=%n'

monitoring_history=yes
monitor_interval_secs=5
reconnect_attempts=3
reconnect_interval=5
```

**Setup:**
```bash
# On primary
repmgr primary register

# On standby
repmgr standby clone -h 10.0.1.10 -U repmgr
repmgr standby register

# Start repmgrd daemon (monitors and handles failover)
repmgrd -f /etc/repmgr.conf --daemonize

# Check cluster
repmgr cluster show
```

---

### 3. HAProxy (Connection Routing)

**What:** Load balancer that routes connections to healthy nodes

**Configuration:**
```
# /etc/haproxy/haproxy.cfg

global
    maxconn 1000

defaults
    mode tcp
    timeout connect 10s
    timeout client 30m
    timeout server 30m

# PostgreSQL Primary (writes)
listen postgresql-primary
    bind *:5432
    option httpchk
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 10.0.1.10:5432 maxconn 100 check port 8008
    server node2 10.0.1.11:5432 maxconn 100 check port 8008 backup
    server node3 10.0.1.12:5432 maxconn 100 check port 8008 backup

# PostgreSQL Replicas (reads)
listen postgresql-replicas
    bind *:5433
    option httpchk
    http-check expect status 200
    default-server inter 3s fall 3 rise 2
    server node2 10.0.1.11:5432 maxconn 100 check port 8008
    server node3 10.0.1.12:5432 maxconn 100 check port 8008

# Statistics
listen stats
    bind *:7000
    stats enable
    stats uri /
    stats refresh 5s
```

**How it Works:**
- Checks Patroni REST API (port 8008) for node health
- Routes writes to primary (port 5432)
- Load balances reads across replicas (port 5433)
- Automatic rerouting when primary changes

---

### 4. PgBouncer (Connection Pooling)

**Configuration for HA:**
```ini
# /etc/pgbouncer/pgbouncer.ini

[databases]
production = host=haproxy-host port=5432 dbname=production

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 5000
default_pool_size = 25
reserve_pool_size = 5
reserve_pool_timeout = 3

# Connection limits
server_lifetime = 3600
server_idle_timeout = 600
```

**Application Connection String:**
```
# Instead of: postgresql://primary:5432/production
# Use:        postgresql://pgbouncer:6432/production
# Or:         postgresql://haproxy:5432/production
```

---

## 🚀 Failover Scenarios & Procedures

### Scenario 1: Planned Maintenance (Switchover)

**Goal:** Zero downtime, zero data loss

**Procedure:**
```bash
# 1. Verify replication healthy
patronictl -c /etc/patroni.yml list
# Check: All replicas have Lag=0

# 2. Announce maintenance window
# Inform team: "Switching primary in 5 minutes"

# 3. Perform switchover (Patroni)
patronictl -c /etc/patroni.yml switchover
# Patroni will:
#   - Pause writes to primary
#   - Wait for standby to catch up
#   - Promote standby
#   - Demote old primary to standby
#   - Resume writes on new primary

# 4. Verify new primary
patronictl -c /etc/patroni.yml list

# 5. Perform maintenance on old primary
# (Now a standby)

# 6. Switchover back if desired
```

**RTO:** 10-30 seconds
**RPO:** 0 seconds (no data loss)

---

### Scenario 2: Unplanned Primary Failure

**Automatic Failover (Patroni):**
```
Timeline:
00:00 - Primary fails (power outage, hardware failure)
00:05 - Patroni detects failure (missed 3 heartbeats)
00:10 - Patroni initiates failover
00:15 - Standby1 promoted to primary
00:20 - HAProxy detects new primary
00:25 - Application connections restored

Total RTO: 25 seconds
```

**Manual Steps (if automatic failover fails):**
```bash
# 1. Verify primary is down
pg_isready -h 10.0.1.10 -p 5432
# Output: no response

# 2. Check cluster status
patronictl -c /etc/patroni.yml list
# Output: Leader is missing

# 3. Manual failover
patronictl -c /etc/patroni.yml failover
# Select: node2

# 4. Verify new primary
patronictl -c /etc/patroni.yml list

# 5. Investigate old primary
# When it comes back online, it will become a standby
```

---

### Scenario 3: Split-Brain Prevention

**Problem:** Network partition causes two primaries

**PostgreSQL Timeline Protection:**
```
Before Failover:
Primary (Timeline 3) ← Standby1 ← Standby2

Network Partition:
Primary (Timeline 3, isolated)
Standby1 promoted → New Primary (Timeline 4)

When Old Primary Returns:
- Timeline 3 vs Timeline 4
- PostgreSQL: "You're on old timeline, cannot rejoin!"
- Must use pg_rewind or rebuild from new primary
```

**Patroni/etcd Prevention:**
```
- Patroni uses etcd for consensus
- Node must hold "leader lock" in etcd to be primary
- If network partitioned, old primary loses lock
- Old primary automatically demotes itself
- Prevents split-brain automatically ✅
```

**Recovery Process:**
```bash
# When old primary comes back
# Patroni automatically detects timeline mismatch

# If rewind possible:
patronictl -c /etc/patroni.yml reinit postgres-cluster node1
# Patroni uses pg_rewind to rejoin

# If rewind not possible:
# Manual rebuild:
pg_basebackup -h new-primary -U replicator -D /data -R
```

---

## 📊 Monitoring & Health Checks

### Patroni REST API Endpoints

```bash
# Check node role
curl http://10.0.1.10:8008/
# Output: {"state":"running","role":"master"}

# Liveness check
curl http://10.0.1.10:8008/liveness
# Returns 200 if PostgreSQL is up

# Readiness check
curl http://10.0.1.10:8008/readiness
# Returns 200 if accepting connections

# Primary check (for HAProxy)
curl http://10.0.1.10:8008/primary
# Returns 200 if this node is primary

# Replica check
curl http://10.0.1.10:8008/replica
# Returns 200 if this node is replica

# Asynchronous replica check
curl http://10.0.1.10:8008/async
# Returns 200 if replica and not sync
```

### Key Metrics to Monitor

```sql
-- 1. Replication lag (on primary)
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;
-- Alert if: lag_bytes > 100MB OR replay_lag > 10 seconds

-- 2. Connection count
SELECT count(*) FROM pg_stat_activity WHERE state != 'idle';
-- Alert if: > 80% of max_connections

-- 3. Long-running transactions
SELECT 
    pid,
    usename,
    state,
    now() - xact_start AS duration,
    query
FROM pg_stat_activity
WHERE state != 'idle'
  AND xact_start < now() - interval '5 minutes'
ORDER BY xact_start;
-- Alert if: transactions > 5 minutes

-- 4. Replication slots lag (prevents WAL deletion)
SELECT 
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots;
-- Alert if: lag > 10GB (disk could fill!)
```

### Prometheus Metrics

```yaml
# Key metrics to export:

# 1. Replication lag
pg_replication_lag_bytes{node="node1"} 0
pg_replication_lag_seconds{node="node1"} 0.05

# 2. Node role
pg_node_is_primary{node="node1"} 1
pg_node_is_primary{node="node2"} 0

# 3. Cluster health
pg_cluster_healthy{cluster="postgres-cluster"} 1
pg_cluster_member_count{cluster="postgres-cluster"} 3

# 4. Failover count
pg_failover_count{cluster="postgres-cluster"} 2

# 5. Connection count
pg_connections_active{node="node1"} 45
pg_connections_idle{node="node1"} 155
```

---

## 💼 Interview Questions & Answers

### Q1: "Explain your HA setup for a mission-critical application with 99.99% availability requirement."

**Answer:**
> "For 99.99% availability (52 minutes downtime/year), I designed a multi-AZ HA setup:
>
> **Architecture:**
> - Primary + 2 standbys across 3 availability zones
> - Patroni for automatic failover with etcd consensus
> - HAProxy for connection routing (writes → primary, reads → replicas)
> - PgBouncer for connection pooling (5000 → 200 connections)
> - Synchronous replication to 1 standby (RPO = 0)
> - Async replication to 2nd standby (performance)
>
> **Key Configurations:**
> ```yaml
> # Patroni DCS config
> synchronous_mode: true
> synchronous_mode_strict: false  # Don't block if sync standby fails
> synchronous_node_count: 1
> ```
>
> **Failover Process:**
> 1. Primary fails (hardware, network, software)
> 2. Patroni detects after 30 seconds (missed 3 heartbeats)
> 3. Sync standby promoted automatically
> 4. HAProxy redirects traffic to new primary
> 5. Old primary becomes standby when recovered (pg_rewind)
>
> **RTO:** 30-60 seconds
> **RPO:** 0 seconds (synchronous replication)
> **Measured Availability:** 99.98% over 12 months (only 1 hour 45 minutes downtime, mostly planned maintenance)
>
> **Costs:**
> - 3× hardware cost (3 nodes)
> - ~20% performance overhead (synchronous replication)
> - Worth it: Zero customer-facing outages in critical incidents"

---

### Q2: "How do you handle a split-brain scenario in PostgreSQL?"

**Answer:**
> "Split-brain is when two nodes think they're primary—can cause data divergence. PostgreSQL + Patroni have multiple layers of protection:
>
> **Layer 1: Timeline Protection (PostgreSQL Native)**
> - Every promotion creates new timeline (3 → 4)
> - Old primary on Timeline 3 cannot accept writes after new primary on Timeline 4 exists
> - Automatic prevention of accidental rejoining
>
> **Layer 2: Distributed Consensus (Patroni + etcd)**
> - Primary must hold 'leader lock' in etcd
> - Lock has TTL (30 seconds)
> - If network partitioned, old primary loses lock
> - Old primary automatically demotes itself
> - New primary acquires lock before accepting writes
>
> **Layer 3: Fencing (if needed)**
> ```yaml
> # Patroni can execute custom fencing scripts
> pre_promote: /usr/local/bin/fence_old_primary.sh
> ```
>
> **Example Scenario:**
> ```
> T0: Primary in AZ1, Standby in AZ2, network partition
> T+10s: AZ1 isolated, cannot reach etcd (in AZ2)
> T+15s: Primary in AZ1 loses leader lock
> T+20s: Primary demotes itself to standby (read-only)
> T+30s: Standby in AZ2 promoted, acquires lock
> T+35s: HAProxy switches traffic to AZ2
> Result: Zero data divergence ✅
> ```
>
> **Recovery When Network Heals:**
> ```bash
> # Old primary tries to rejoin
> patronictl list
> # node1 (AZ1): Timeline 3, State: starting
> # node2 (AZ2): Timeline 4, State: Leader
>
> # Patroni automatically runs pg_rewind
> # Brings node1 to Timeline 4
> # Rejoins as standby
> ```
>
> **Key Learning:** This is why I always use Patroni + etcd in production. Raw streaming replication without consensus is risky."

---

### Q3: "Walk me through responding to a production primary failure at 3 AM."

**Answer:**
> "I get paged at 3:00 AM: 'PostgreSQL primary down, automatic failover triggered.' Here's my runbook:
>
> **Immediate Actions (0-5 minutes):**
> 1. Check monitoring dashboard
>    - Grafana shows: Primary flatlined at 2:58 AM
>    - Standby1 promoted at 3:00 AM
>    - Application error rate: Spiked to 5% for 30 seconds, now 0%
>
> 2. Verify cluster health
>    ```bash
>    patronictl -c /etc/patroni.yml list
>    # node1: no response (was primary)
>    # node2: Leader, running (new primary) ✅
>    # node3: Replica, streaming ✅
>    ```
>
> 3. Check application
>    - Login to app: Works ✅
>    - Test write: `INSERT INTO test_table VALUES (...)` ✅
>    - Test read: `SELECT * FROM orders` ✅
>
> 4. Alert team
>    - Slack: 'Automatic failover successful, investigating root cause'
>    - No customer action needed
>
> **Investigation (5-30 minutes):**
> 5. Check old primary node
>    ```bash
>    ssh node1
>    # No response - hardware failure suspected
>    
>    # Check cloud console
>    aws ec2 describe-instance-status --instance-id i-node1
>    # Status: impaired, system reachability check failed
>    ```
>
> 6. Review logs before failure
>    ```bash
>    # On node2 (new primary)
>    tail -100 /var/log/patroni/patroni.log
>    
>    2025-11-21 02:58:45: Lost connection to primary
>    2025-11-21 02:59:15: Starting leader election
>    2025-11-21 03:00:00: Acquired leader lock, promoting
>    2025-11-21 03:00:10: Promotion complete, timeline 3 → 4
>    ```
>
> 7. Document incident
>    - PagerDuty: Update incident with timeline
>    - Jira: Create ticket for root cause analysis
>
> **Recovery Actions (30 minutes - 2 hours):**
> 8. Provision new node (if hardware failure)
>    ```bash
>    # Launch new EC2 instance
>    aws ec2 run-instances --image-id ami-postgres --instance-type r5.2xlarge
>    
>    # Install PostgreSQL + Patroni
>    # Configure as replica
>    patronictl -c /etc/patroni.yml reinit postgres-cluster node1-new
>    ```
>
> 9. Verify replication
>    ```bash
>    patronictl list
>    # node1-new: Replica, streaming, lag=0 ✅
>    # node2: Leader, running ✅
>    # node3: Replica, streaming, lag=0 ✅
>    ```
>
> 10. Update monitoring
>     - Grafana: Add annotation 'Failover at 03:00, node1 replaced'
>     - PagerDuty: Resolve incident
>
> **Post-Mortem (Next Day):**
> - **RTO:** 2 minutes (02:58 failure → 03:00 recovered)
> - **RPO:** 0 seconds (synchronous replication)
> - **Customer Impact:** None (30-second error spike, no data loss)
> - **Root Cause:** EC2 instance hardware failure (confirmed by AWS)
> - **Action Items:**
>   1. Enable AWS auto-recovery for EC2 instances
>   2. Improve monitoring to predict hardware failures
>   3. Document: This is why we have HA! 🎉
>
> **Key Point for Interview:** This demonstrates I remain calm under pressure, follow runbooks, document everything, and understand the entire HA stack."

---

### Q4: "How do you test your HA setup to ensure it works?"

**Answer:**
> "Testing is critical—you don't want to discover issues during real outages. I run quarterly DR drills:
>
> **1. Automated Testing (Monthly):**
> ```bash
> # Test script
> #!/bin/bash
> 
> # Simulate primary failure
> patronictl -c /etc/patroni.yml pause
> sudo systemctl stop patroni@node1
> 
> # Wait for failover (should be < 60 seconds)
> sleep 60
> 
> # Verify new primary
> NEW_PRIMARY=$(patronictl -c /etc/patroni.yml list | grep Leader | awk '{print $2}')
> echo "New primary: $NEW_PRIMARY"
> 
> # Test writes
> psql -h $NEW_PRIMARY -U postgres -c "INSERT INTO test_table VALUES (NOW());"
> 
> # Bring old primary back
> sudo systemctl start patroni@node1
> 
> # Unpause cluster
> patronictl -c /etc/patroni.yml resume
> 
> # Verify replication
> sleep 30
> patronictl -c /etc/patroni.yml list
> ```
>
> **2. Manual Testing (Quarterly):**
>
> *Test 1: Kill Primary Process*
> ```bash
> # On primary
> sudo kill -9 $(cat /var/lib/postgresql/15/main/postmaster.pid | head -1)
> 
> # Verify: Failover < 60 seconds
> # Measure: RTO, RPO
> # Check: Application errors minimal
> ```
>
> *Test 2: Network Partition*
> ```bash
> # Simulate network partition
> sudo iptables -A INPUT -s 10.0.1.0/24 -j DROP
> sudo iptables -A OUTPUT -d 10.0.1.0/24 -j DROP
> 
> # Verify: Split-brain prevention works
> # Verify: Automatic recovery when network heals
> 
> # Cleanup
> sudo iptables -F
> ```
>
> *Test 3: Disk Full*
> ```bash
> # Fill /var/lib/postgresql/15/main/pg_wal
> dd if=/dev/zero of=/var/lib/postgresql/15/main/pg_wal/dummy bs=1M count=10000
> 
> # Verify: Failover triggered
> # Verify: Alerts fired
> # Verify: Monitoring caught issue
> 
> # Cleanup
> rm /var/lib/postgresql/15/main/pg_wal/dummy
> ```
>
> *Test 4: Synchronous Standby Failure*
> ```bash
> # Kill sync standby (not primary)
> sudo systemctl stop patroni@node2
> 
> # Verify: Primary switches to async mode
> # Verify: Writes still work (not blocked)
> # Verify: Alert fired for degraded mode
> 
> # Bring standby back
> sudo systemctl start patroni@node2
> ```
>
> **3. Chaos Engineering (Annual):**
> - Random failures during business hours (with approval!)
> - Measure actual customer impact
> - Test incident response procedures
>
> **4. Metrics Collected:**
> ```
> Test #  | Scenario         | RTO    | RPO | Data Loss | App Errors |
> --------|------------------|--------|-----|-----------|------------|
> 2025-09 | Kill primary     | 35s    | 0s  | None      | 2%×30s    |
> 2025-10 | Network partition| 40s    | 0s  | None      | 3%×25s    |
> 2025-11 | Disk full        | 45s    | 0s  | None      | 4%×35s    |
> --------|------------------|--------|-----|-----------|------------|
> Target  | Any failure      | < 60s  | 0s  | None      | < 5%×60s  |
> Status  | PASS ✅          | ✅     | ✅   | ✅        | ✅        |
> ```
>
> **5. Documentation:**
> - Record all test results
> - Update runbooks with learnings
> - Train on-call engineers on failures observed
>
> **Key Point:** We discovered the synchronous replication trap (today's Scenario 10!) during a drill—not during a real outage. That's the value of testing!"

---

### Q5: "Compare Patroni vs Repmgr for HA. Which would you choose and why?"

**Answer:**
> "Both provide automatic failover, but with different philosophies:
>
> **Patroni:**
> - Uses distributed consensus (etcd/Consul/ZooKeeper)
> - Strong split-brain protection
> - More complex setup
> - Better for large clusters (5+ nodes)
> - REST API for health checks
> - Configuration stored in DCS (dynamic updates)
> - Active development, modern architecture
>
> **Repmgr:**
> - Uses PostgreSQL database for coordination
> - Simpler setup
> - Lightweight daemon
> - Better for small clusters (2-3 nodes)
> - Built-in BDR support
> - Configuration file-based
> - Mature, stable
>
> **Comparison Table:**
>
> | Feature              | Patroni          | Repmgr       |
> |---------------------|------------------|--------------|
> | Consensus Layer     | External (etcd)  | PostgreSQL   |
> | Split-Brain Protection | Excellent     | Good         |
> | Setup Complexity    | High             | Low          |
> | Configuration Changes | Dynamic        | Restart needed |
> | Cloud-Native        | Yes              | No           |
> | REST API            | Yes              | No           |
> | Kubernetes Support  | Excellent        | Manual       |
> | Learning Curve      | Steep            | Moderate     |
>
> **My Recommendation:**
>
> *Choose Patroni if:*
> - Running in cloud/Kubernetes
> - Need strong split-brain protection
> - Have >3 nodes
> - Need dynamic reconfiguration
> - Team familiar with etcd/Consul
> - Budget for additional infrastructure (etcd cluster)
>
> *Choose Repmgr if:*
> - On-premises deployment
> - Small cluster (2-3 nodes)
> - Want simple setup
> - Limited operational experience
> - Budget constraints
> - Just need basic automatic failover
>
> **What I Use:**
> - **Production:** Patroni (mission-critical, 99.99% SLA)
> - **Staging:** Repmgr (simpler, cost-effective)
> - **Development:** Raw streaming replication (manual failover OK)
>
> **Real Example:**
> In my previous role, we migrated from Repmgr to Patroni after a split-brain incident cost us 2 hours of downtime. Patroni's etcd-based consensus prevented this from ever happening again. The additional complexity was worth the reliability."

---

## 📚 HA Best Practices Checklist

**Architecture:**
- ✅ Minimum 3 nodes (1 primary + 2 standbys) for quorum
- ✅ Deploy across multiple availability zones
- ✅ Use odd number of consensus nodes (3 or 5 etcd)
- ✅ Separate compute and consensus infrastructure

**Replication:**
- ✅ Synchronous replication to 1 standby (RPO=0)
- ✅ Async replication to other standbys (performance)
- ✅ Replication slots for all standbys (prevent WAL deletion)
- ✅ Monitor replication lag < 10 seconds

**Failover:**
- ✅ Automatic failover with Patroni/Repmgr
- ✅ Failover timeout < 60 seconds
- ✅ Connection pooler (pgBouncer/HAProxy)
- ✅ Application retry logic (exponential backoff)

**Monitoring:**
- ✅ Node health checks every 10 seconds
- ✅ Replication lag alerts
- ✅ Disk space alerts (80% threshold)
- ✅ Connection count alerts
- ✅ Long-running transaction alerts (> 5 minutes)

**Testing:**
- ✅ Monthly automated failover tests
- ✅ Quarterly DR drills
- ✅ Annual chaos engineering
- ✅ Document RTO/RPO metrics

**Operations:**
- ✅ Runbooks for common scenarios
- ✅ On-call rotation (24/7 coverage)
- ✅ Incident response procedures
- ✅ Post-mortem after every incident

**Backup & Recovery:**
- ✅ Continuous WAL archiving (Barman/pgBackRest)
- ✅ Daily full backups
- ✅ Test restores monthly
- ✅ Separate backup storage (different region)

---

## ✅ Summary

**HA Levels:**
1. **Basic (99.9%):** Primary + standby, manual failover
2. **Standard (99.95%):** + Automatic failover (Patroni/Repmgr)
3. **Advanced (99.99%):** + Synchronous replication, multi-AZ
4. **Mission-Critical (99.999%):** + Multi-region, geo-distributed

**Key Technologies:**
- ✅ **Patroni** - Automatic failover with consensus
- ✅ **HAProxy** - Connection routing
- ✅ **PgBouncer** - Connection pooling
- ✅ **etcd/Consul** - Distributed consensus

**Interview Readiness:**
- ✅ Can design HA architecture for different SLAs
- ✅ Understand split-brain prevention
- ✅ Know Patroni vs Repmgr trade-offs
- ✅ Can respond to 3 AM primary failure
- ✅ Have testing and DR drill procedures

You're ready to discuss HA architecture in senior PostgreSQL DBA interviews! 🚀
