# PostgreSQL Load Balancing & High Availability - Interview Guide

**Complete reference for Database/Backend Engineer interviews**

---

## 📚 Table of Contents

1. [Core Concepts](#-core-concepts)
2. [Common Interview Questions & Answers](#-common-interview-questions--answers)
3. [Architecture Patterns](#-architecture-patterns)
4. [Tool Comparison Matrix](#-tool-comparison-matrix)
5. [Real-World Scenarios](#-real-world-scenarios)
6. [Red Flags to Avoid](#-red-flags-to-avoid)
7. [Advanced Topics](#-advanced-topics)
8. [MySQL Equivalents](#-mysql-equivalents)

---

## 🎯 Core Concepts

### **1. Streaming Replication**
**What:** Continuous replication of WAL (Write-Ahead Log) from primary to standby servers.

**Key Points:**
- Physical replication (byte-level copy)
- Real-time or near real-time
- Standbys are read-only
- Asynchronous by default (can be synchronous)

**Interview Answer:**
> "Streaming replication in PostgreSQL continuously ships WAL records from the primary to standbys. The standby applies these changes to stay synchronized. It's physical replication at the block level, making standbys exact copies that can serve read queries or be promoted during failover."

---

### **2. Read/Write Splitting**
**What:** Routing write queries to primary, read queries to standbys.

**Why Important:**
- Most applications are read-heavy (80-95% reads)
- Distributes load horizontally
- Prevents primary from being bottleneck

**Implementation Options:**
1. **Application-level** - Code decides which server
2. **Proxy-level** - Pgpool-II/ProxySQL decides
3. **DNS-level** - Different endpoints for reads/writes

**Interview Answer:**
> "Read/write splitting distributes the load by routing SELECT queries to standbys and write operations to the primary. This is crucial for scaling read-heavy workloads. I'd implement it using Pgpool-II for PostgreSQL or ProxySQL for MySQL, which automatically routes queries based on type without application code changes."

---

### **3. Connection Pooling**
**What:** Reusing database connections instead of creating new ones for each request.

**Why Critical:**
- Connection creation is expensive (auth, state setup)
- Reduces memory on database server
- Improves response time

**Example:**
```
Without pooling:
  1000 app connections → 1000 DB connections
  Memory: 1000 × 10MB = 10GB

With pooling:
  1000 app connections → Pooler → 20 DB connections
  Memory: 20 × 10MB = 200MB
```

**Interview Answer:**
> "Connection pooling is essential for production databases. Each PostgreSQL connection consumes memory and requires authentication overhead. Tools like PgBouncer or Pgpool-II maintain a pool of persistent connections, multiplexing many client connections to fewer backend connections. This dramatically reduces resource usage - for example, 1000 app connections can share 20 backend connections."

---

### **4. Load Balancing**
**What:** Distributing queries across multiple standbys.

**Algorithms:**
- **Round-robin** - Query 1→S1, Query 2→S2, Query 3→S1...
- **Weighted** - More queries to powerful servers
- **Least connections** - Send to server with fewest active connections
- **Random** - Random distribution

**Interview Answer:**
> "Load balancing distributes read queries across standbys to prevent any single server from becoming a bottleneck. Pgpool-II uses weighted round-robin - you can assign higher weights to more powerful servers. For example, if STANDBY1 has better hardware, you might give it weight=2 while STANDBY2 gets weight=1, so STANDBY1 handles 66% of reads."

---

## 💼 Common Interview Questions & Answers

### **Q1: "How do you scale PostgreSQL for high read traffic?"**

**Good Answer:**
```
1. Set up streaming replication:
   - 1 PRIMARY (writes)
   - Multiple STANDBYs (reads)

2. Implement load balancing:
   - Pgpool-II for automatic query routing
   - Or application-level with connection pooling

3. Scale horizontally:
   - Add more standbys as read load increases
   - Each standby handles portion of read traffic

4. Monitor and adjust:
   - Track lag on standbys
   - Adjust weights based on performance
   - Use connection pooling to reduce overhead

Example: 100,000 reads/sec distributed across 4 standbys
= 25,000 reads/sec per standby (manageable)
```

**What This Shows:**
- You understand replication
- You know about load balancing
- You think about monitoring
- You can scale horizontally

---

### **Q2: "What's the difference between Pgpool-II and PgBouncer?"**

**Answer:**

| Feature | **Pgpool-II** | **PgBouncer** |
|---------|--------------|---------------|
| **Primary Purpose** | Query routing + pooling | Connection pooling only |
| **Understands SQL** | ✅ Yes (can route by query type) | ❌ No (just forwards connections) |
| **Load Balancing** | ✅ Weighted across standbys | ❌ Not built-in |
| **Failover** | ✅ Automatic detection/promotion | ❌ Not built-in |
| **Complexity** | Medium-High | Low |
| **Performance** | Slight overhead (SQL parsing) | Very fast (no parsing) |
| **Use Case** | All-in-one solution | Pure connection pooling |

**When to Use What:**
- **Pgpool-II**: Need query routing + pooling + failover (like ProxySQL)
- **PgBouncer**: Only need connection pooling, do routing elsewhere
- **Both**: PgBouncer for pooling, HAProxy for load balancing

---

### **Q3: "Explain asynchronous vs synchronous replication"**

**Answer:**

**Asynchronous (Default):**
```
PRIMARY commits transaction → Returns success → Sends WAL to standby
                                               (happens in background)

Pros: Fast commits (no waiting)
Cons: Potential data loss if primary crashes before WAL sent

Example: E-commerce product catalog (can tolerate slight lag)
```

**Synchronous:**
```
PRIMARY commits transaction → Waits for standby to receive WAL → Returns success

Pros: Zero data loss (guaranteed replication)
Cons: Slower commits (network latency impact)

Example: Financial transactions (zero data loss required)
```

**Configuration:**
```sql
-- Asynchronous (default)
synchronous_commit = off

-- Synchronous
synchronous_commit = on
synchronous_standby_names = 'standby1'  -- Wait for this standby
```

**Interview Tip:** Always mention the trade-off and give examples!

---

### **Q4: "How would you handle a failover scenario?"**

**Manual Failover:**
```bash
# 1. Confirm primary is down
pg_isready -h primary

# 2. Promote standby to primary
pg_ctl promote -D /var/lib/postgresql/data

# 3. Update application connection string
# Point to new primary

# 4. Configure old primary as new standby (when recovered)
```

**Automatic Failover (Production):**
```
Tools: Patroni, repmgr, Pgpool-II

Process:
1. Health check detects primary failure
2. Consensus algorithm selects best standby
3. Automatic promotion
4. Update DNS/VIP to point to new primary
5. Notify monitoring systems

Downtime: Typically 30-60 seconds
```

**Interview Answer:**
> "In production, I'd use Patroni or repmgr for automatic failover. These tools continuously monitor the primary using health checks. If the primary fails, they use consensus (etcd/consul) to elect a new primary from standbys, considering factors like replication lag and node health. The promotion happens automatically, minimizing downtime to under a minute. I'd also implement connection pooling with automatic retry logic so applications reconnect to the new primary seamlessly."

---

### **Q5: "Design a highly available database architecture for an e-commerce platform"**

**Answer:**

```
                      Internet
                         |
                    Load Balancer
                    (Application)
                         |
            +------------+------------+
            |                         |
      App Servers              App Servers
      (Region 1)               (Region 2)
            |                         |
            +------------+------------+
                         |
                   [Pgpool-II]
              (Active-Passive with VIP)
                         |
        +----------------+----------------+
        |                |                |
    PRIMARY          STANDBY1         STANDBY2
   (Region 1)       (Region 1)       (Region 2)
   [Writes]         [Reads]          [Reads + DR]
        |                |                |
        +----------------+----------------+
                         |
                  Backup to S3
               (Daily + WAL archiving)
```

**Key Components:**

**1. Database Layer:**
- **PRIMARY**: Handles all writes (Region 1)
- **STANDBY1**: Read queries, failover candidate (Region 1)
- **STANDBY2**: Read queries, disaster recovery (Region 2)

**2. Proxy Layer:**
- **Pgpool-II** in active-passive mode (with keepalived for VIP)
- Automatic query routing (writes→primary, reads→standbys)
- Weighted load balancing (STANDBY1: 60%, STANDBY2: 40%)
- Health checks every 10 seconds
- Automatic failover on primary failure

**3. Backup Strategy:**
- Daily base backups to S3
- Continuous WAL archiving
- Point-in-time recovery capability
- Retention: 30 days

**4. Monitoring:**
- Prometheus + Grafana
- Metrics: Replication lag, connection count, query performance
- Alerts: Lag > 5 seconds, primary down, high connection usage

**5. Security:**
- SSL/TLS for all connections
- Network isolation (private subnets)
- Connection pooling (reduce attack surface)
- Regular security patches

**Capacity Planning:**
```
Expected load: 10,000 req/sec
  • 1,000 writes/sec → PRIMARY
  • 9,000 reads/sec → STANDBY1 (5,400) + STANDBY2 (3,600)

Hardware:
  • PRIMARY: 32 vCPU, 128GB RAM, 1TB NVMe SSD
  • STANDBYs: 16 vCPU, 64GB RAM, 500GB NVMe SSD
  • Pgpool: 4 vCPU, 16GB RAM (lightweight)

Cost: ~$5,000/month (AWS)
```

**Failover Scenarios:**

**Scenario 1: Primary Fails**
```
1. Pgpool detects failure (health check timeout)
2. Promotes STANDBY1 to new PRIMARY (30 seconds)
3. STANDBY2 reconnects to new PRIMARY
4. Applications automatically reconnect via Pgpool
5. Old primary (when recovered) becomes new standby
```

**Scenario 2: STANDBY1 Fails**
```
1. Pgpool detects failure
2. Removes STANDBY1 from read pool
3. All reads go to STANDBY2
4. No application impact
5. STANDBY1 catches up when recovered
```

**Scenario 3: Region 1 Disaster**
```
1. Both PRIMARY and STANDBY1 down
2. Manual intervention (or automated with Patroni)
3. Promote STANDBY2 in Region 2
4. Point applications to Region 2
5. RTO: 5 minutes, RPO: < 10 seconds
```

**What This Answer Demonstrates:**
- Architecture design skills
- Understanding of HA concepts
- Practical experience
- Cost awareness
- Disaster recovery planning

---

### **Q6: "What metrics would you monitor for a PostgreSQL replication setup?"**

**Answer:**

**Critical Metrics:**

**1. Replication Lag**
```sql
SELECT application_name, 
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes,
       replay_lag
FROM pg_stat_replication;
```
- **Warning:** > 10 MB
- **Critical:** > 100 MB
- **Impact:** Stale data on standbys

**2. Connection Count**
```sql
SELECT count(*) FROM pg_stat_activity;
```
- **Warning:** > 80% of max_connections
- **Critical:** > 95%
- **Impact:** Connection rejection

**3. Replication Slot Usage**
```sql
SELECT slot_name, 
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal
FROM pg_replication_slots;
```
- **Warning:** > 1 GB WAL retained
- **Critical:** > 10 GB
- **Impact:** Disk space exhaustion

**4. Query Performance**
```sql
SELECT query, mean_exec_time, calls
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```
- Track slow queries
- Identify optimization opportunities

**5. Cache Hit Ratio**
```sql
SELECT sum(blks_hit)*100/sum(blks_hit+blks_read) AS cache_hit_ratio
FROM pg_stat_database;
```
- **Good:** > 99%
- **Warning:** < 95%
- **Action:** Increase shared_buffers

**Monitoring Stack:**
```
Prometheus (metrics collection)
    ↓
postgres_exporter (PostgreSQL metrics)
    ↓
Grafana (visualization)
    ↓
Alertmanager (alerts to Slack/PagerDuty)
```

**Key Alerts:**
1. Replication lag > 60 seconds
2. Primary down (no response to health check)
3. Standby down
4. Connections > 90% max
5. Disk usage > 85%
6. Slow queries > 10 seconds

---

### **Q7: "How do you handle connection pooling in a microservices architecture?"**

**Answer:**

**Scenario:** 50 microservices, each with 10 instances = 500 potential database connections

**Strategy 1: Application-Side Pooling**
```python
# Each microservice instance maintains its own pool
from sqlalchemy import create_engine

engine = create_engine(
    'postgresql://...',
    pool_size=5,           # 5 connections per instance
    max_overflow=10        # Allow 10 extra connections
)

Total connections: 500 instances × 5 = 2,500 connections ❌ Too many!
```

**Strategy 2: Centralized Pooler (Recommended)**
```
Microservices (500 instances)
         ↓
    PgBouncer (3 instances for HA)
         ↓
    PostgreSQL (100 connections)

Configuration:
  • pool_mode = transaction (most efficient)
  • max_client_conn = 10000 (accept many clients)
  • default_pool_size = 25 (per database)
  • reserve_pool_size = 10 (emergency connections)

Result: 500 instances share 100 backend connections
```

**PgBouncer Config:**
```ini
[databases]
mydb = host=postgres-primary port=5432 dbname=mydb

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = scram-sha-256
pool_mode = transaction
max_client_conn = 10000
default_pool_size = 25
reserve_pool_size = 10
```

**Best Practices:**
1. **Use transaction pooling** when possible (most efficient)
2. **Monitor pool saturation** (connections waiting)
3. **Scale pooler horizontally** (3+ instances with load balancer)
4. **Set realistic timeouts** (avoid connection hogging)
5. **Use connection limits per user** (prevent single service monopolizing)

---

## 🏗️ Architecture Patterns

### **Pattern 1: Basic Primary-Standby**
```
Application → PRIMARY → STANDBY

Use Case: Small apps, basic HA
Pros: Simple, easy to understand
Cons: No read scaling, manual failover
```

### **Pattern 2: Multi-Standby with Load Balancing**
```
Application → Pgpool-II → PRIMARY (writes)
                      → STANDBY1 (reads)
                      → STANDBY2 (reads)

Use Case: Read-heavy apps (e-commerce, news sites)
Pros: Read scaling, automatic routing
Cons: Pgpool-II single point of failure
```

### **Pattern 3: Multi-Region with DR**
```
Region 1:                    Region 2:
  PRIMARY                      STANDBY2 (DR)
  STANDBY1                         
    ↓                              ↓
  Pgpool-II                    Pgpool-II
    ↑                              ↑
Application                  Application (failover)

Use Case: Global apps, disaster recovery
Pros: Geographic distribution, DR capability
Cons: Complex, increased latency for Region 2
```

### **Pattern 4: Cascading Replication**
```
PRIMARY → STANDBY1 → STANDBY2
                  → STANDBY3

Use Case: Reduce load on primary (many standbys)
Pros: Primary sends WAL to one standby only
Cons: Increased lag on downstream standbys
```

---

## 📊 Tool Comparison Matrix

### **PostgreSQL Tools**

| Tool | Purpose | Complexity | Performance | Use Case |
|------|---------|------------|-------------|----------|
| **Pgpool-II** | All-in-one (routing+pooling+failover) | High | Good | Complete solution |
| **PgBouncer** | Connection pooling only | Low | Excellent | Just pooling needed |
| **HAProxy** | TCP load balancing | Medium | Excellent | Connection distribution |
| **Patroni** | HA/Failover orchestration | High | N/A | Automatic failover |
| **repmgr** | Replication management | Medium | N/A | Replication setup/failover |

### **MySQL Equivalents**

| PostgreSQL | MySQL Equivalent | Notes |
|------------|------------------|-------|
| Pgpool-II | ProxySQL | Query routing + load balancing |
| PgBouncer | ProxySQL (pooling mode) | Connection pooling |
| Patroni | MySQL Group Replication | Automatic failover |
| Streaming Replication | Binlog Replication | Built-in replication |

### **Decision Matrix**

**Need query routing?**
- Yes → Pgpool-II or application-level
- No → Continue

**Need connection pooling?**
- Yes + routing → Pgpool-II
- Yes only → PgBouncer
- No → Continue

**Need just load balancing?**
- Yes → HAProxy (TCP level)
- No → Direct connection

---

## 🌍 Real-World Scenarios

### **Scenario 1: E-Commerce Platform**

**Requirements:**
- 1M active users
- 95% read traffic (product browsing)
- 5% write traffic (orders, updates)
- 99.99% uptime required

**Solution:**
```
Architecture:
  • 1 PRIMARY (32 vCPU, 128GB RAM)
  • 4 STANDBYs (16 vCPU, 64GB RAM each)
  • Pgpool-II for routing (active-passive)
  
Load Distribution:
  • Writes: 5,000/sec → PRIMARY
  • Reads: 95,000/sec → 4 STANDBYs (23,750 each)

Failover Strategy:
  • Patroni for automatic failover
  • RTO: < 60 seconds
  • RPO: < 10 seconds (async replication)

Cost: $8,000/month (AWS)
```

---

### **Scenario 2: Analytics Dashboard**

**Requirements:**
- Heavy read workload (reports, dashboards)
- Minimal writes (data ingestion via batch jobs)
- Complex queries (aggregations, joins)

**Solution:**
```
Architecture:
  • 1 PRIMARY (64 vCPU, 256GB RAM) - for writes
  • 6 STANDBYs (32 vCPU, 128GB RAM) - for analytics queries
  • HAProxy for round-robin load balancing
  • PgBouncer for connection pooling
  
Special Configuration:
  • work_mem = 256MB (complex queries)
  • shared_buffers = 64GB (large dataset)
  • effective_cache_size = 192GB
  • Separate standbys for batch jobs vs real-time dashboards

Cost: $15,000/month (dedicated analytics hardware)
```

---

### **Scenario 3: SaaS Multi-Tenant**

**Requirements:**
- 10,000 tenants
- Isolated data per tenant
- Variable load per tenant

**Solution:**
```
Architecture:
  • Schema-per-tenant approach
  • 1 PRIMARY (all writes)
  • 3 STANDBYs (reads, tenant-aware routing)
  • Pgpool-II with custom routing rules
  
Connection Pooling:
  • PgBouncer with per-database pools
  • Each tenant gets dedicated pool
  • Prevents noisy neighbor problem

Monitoring:
  • Per-tenant query tracking
  • Resource usage by tenant
  • Alerting on tenant-specific thresholds
```

---

## ⚠️ Red Flags to Avoid

### **❌ Bad Answer Examples:**

**Q: "How do you scale PostgreSQL?"**
❌ "Just buy a bigger server"
- Shows no understanding of horizontal scaling

**Q: "What's the difference between Pgpool and PgBouncer?"**
❌ "They're the same thing"
- Shows lack of tool knowledge

**Q: "How do you handle failover?"**
❌ "Manually promote a standby whenever primary fails"
- Production systems need automation

**Q: "What's your monitoring strategy?"**
❌ "I check the logs when something breaks"
- Reactive, not proactive

---

### **✅ Good Answer Patterns:**

1. **Start with the problem** - "For read-heavy workloads..."
2. **Explain your solution** - "I'd use replication with load balancing..."
3. **Mention trade-offs** - "While this adds complexity..."
4. **Give alternatives** - "Another option would be..."
5. **Reference real experience** - "In my last project, we..."

---

## 🚀 Advanced Topics

### **1. Logical vs Physical Replication**

**Physical (Streaming):**
- Entire cluster replication
- Block-level copy
- Standby is exact replica
- Cannot be queried differently

**Logical:**
- Table/row-level replication
- Can replicate to different PostgreSQL version
- Can filter/transform data
- More flexible, more overhead

**When to use:**
- Physical: Standard HA/DR scenarios
- Logical: Partial replication, version upgrades, data distribution

---

### **2. Replication Slots**

**Purpose:** Ensure PRIMARY retains WAL until standby catches up

```sql
-- Create slot
SELECT pg_create_physical_replication_slot('standby_slot');

-- View slots
SELECT * FROM pg_replication_slots;

-- Configure standby to use slot
primary_slot_name = 'standby_slot'
```

**Why Important:**
- Prevents WAL deletion before standby receives it
- Critical for standbys that lag or go offline
- But: Can cause disk space issues if standby never reconnects

---

### **3. Synchronous vs Asynchronous Commit**

```sql
-- Async (default) - Fast commits, potential data loss
synchronous_commit = off

-- Local - Wait for local WAL write
synchronous_commit = local

-- Remote write - Wait for standby to receive WAL
synchronous_commit = remote_write

-- Remote apply - Wait for standby to apply WAL
synchronous_commit = remote_apply

-- On - Wait for standby to flush to disk
synchronous_commit = on
```

**Impact on Performance:**
```
Async:         ~5ms commit time, potential data loss
Local:         ~10ms commit time, no replication guarantee
Remote write:  ~20ms commit time, data safe on network
On:            ~50ms commit time, zero data loss
```

---

### **4. Cascading Replication**

**Setup:**
```
PRIMARY → STANDBY1 → STANDBY2
                  → STANDBY3
```

**Configuration on STANDBY1:**
```
hot_standby = on
hot_standby_feedback = on
```

**Benefits:**
- Reduces load on PRIMARY
- Scale to many standbys
- Geographic distribution

**Trade-offs:**
- Increased lag on downstream standbys
- Longer recovery chain if STANDBY1 fails

---

## 📖 MySQL Equivalents (for MySQL DBAs learning PostgreSQL)

| PostgreSQL Concept | MySQL Equivalent | Notes |
|-------------------|------------------|-------|
| WAL | Binary logs (binlog) | Transaction log |
| Streaming Replication | Replication | Built-in replication |
| Standby | Replica/Slave | Read-only copy |
| Pgpool-II | ProxySQL | Query routing + pooling |
| PgBouncer | ProxySQL (pool mode) | Connection pooling |
| pg_stat_replication | SHOW SLAVE STATUS | Replication monitoring |
| Logical Replication | Row-based replication | Row-level replication |
| PITR | Point-in-time recovery | Binary log recovery |

---

## 🎓 Key Takeaways for Interviews

### **Must Know:**
1. ✅ Streaming replication basics
2. ✅ Read/write splitting concept
3. ✅ Connection pooling importance
4. ✅ Pgpool-II vs PgBouncer vs HAProxy
5. ✅ Async vs sync replication trade-offs
6. ✅ How to handle failover
7. ✅ Monitoring key metrics

### **Nice to Know:**
8. ✅ Replication slots purpose
9. ✅ Cascading replication
10. ✅ Logical replication
11. ✅ Patroni/repmgr for automation
12. ✅ Multi-region architectures

### **Pro Tips:**
- Always mention **trade-offs** (no solution is perfect)
- Give **real-world examples** (shows experience)
- Know the **alternatives** (shows breadth)
- Understand **when to use what** (shows judgment)
- Think about **cost** (shows business awareness)

---

## 📝 Sample Interview Dialogue

**Interviewer:** "We're experiencing slow read queries. How would you approach this?"

**You:** 
> "First, I'd investigate whether it's a query optimization issue or a load issue by checking pg_stat_statements for slow queries and monitoring CPU/disk I/O.
> 
> If it's a load issue - say we're seeing high CPU from too many concurrent reads - I'd implement read replicas with load balancing. Specifically:
> 
> 1. Set up 2-3 standbys using streaming replication
> 2. Deploy Pgpool-II to automatically route SELECT queries to standbys
> 3. Configure weighted load balancing based on hardware capacity
> 4. Add connection pooling with PgBouncer to reduce connection overhead
> 
> This distributes read load horizontally. For example, if we have 10,000 reads/sec and 3 standbys, each handles about 3,300 reads/sec, making the system much more scalable.
> 
> I'd also ensure proper monitoring of replication lag and set up alerts if any standby falls behind, as that would impact data freshness on reads."

**What This Demonstrates:**
- Diagnostic thinking (check before implementing)
- Knowledge of tools and techniques
- Quantitative reasoning (actual numbers)
- Understanding of trade-offs (mentions lag monitoring)
- Complete solution (not just "add more servers")

---

## 🎯 Final Interview Checklist

Before your interview, ensure you can explain:

- [ ] What is streaming replication and how it works
- [ ] Difference between async and sync replication
- [ ] Purpose and benefits of read/write splitting
- [ ] How connection pooling works and why it's important
- [ ] Pgpool-II vs ProxySQL comparison
- [ ] When to use Pgpool-II vs PgBouncer vs HAProxy
- [ ] How to design a highly available architecture
- [ ] Key metrics to monitor in production
- [ ] How to handle failover (manual and automatic)
- [ ] Trade-offs of different approaches

**You're ready when you can design a complete, production-ready database architecture and explain every component's purpose!** 🚀

---

*This guide covers the essential PostgreSQL HA/replication knowledge for mid to senior backend/database engineer interviews. Practice explaining these concepts clearly and concisely, always relating to real-world scenarios.*
