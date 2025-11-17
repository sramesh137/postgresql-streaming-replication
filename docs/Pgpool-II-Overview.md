# Pgpool-II Overview - PostgreSQL's ProxySQL Equivalent

## 📝 What is Pgpool-II?

**Pgpool-II is to PostgreSQL what ProxySQL is to MySQL** - a middleware proxy that sits between applications and PostgreSQL servers, providing intelligent query routing, load balancing, and connection pooling.

---

## 🎯 Core Concept (Interview Answer)

**"Pgpool-II is a connection pooler and load balancer for PostgreSQL that acts as a transparent proxy. Applications connect to Pgpool-II on a single port, and it automatically routes:**
- **Write queries (INSERT/UPDATE/DELETE)** → PRIMARY server
- **Read queries (SELECT)** → STANDBY servers (load balanced)

**It's essentially PostgreSQL's equivalent of ProxySQL for MySQL."**

---

## 🆚 Pgpool-II vs ProxySQL Comparison

| Feature | **ProxySQL (MySQL)** | **Pgpool-II (PostgreSQL)** |
|---------|---------------------|----------------------------|
| **Purpose** | Query router & load balancer | Query router & load balancer |
| **Application Connection** | Single port (6033) | Single port (9999) |
| **Query Routing** | Reads → replicas, Writes → master | SELECTs → standbys, Writes → primary |
| **Load Balancing** | ✅ Weighted across replicas | ✅ Weighted across standbys |
| **Connection Pooling** | ✅ Reduces backend connections | ✅ Connection pooling |
| **Query Caching** | ✅ In-memory cache | ✅ Query cache |
| **Health Checks** | ✅ Monitors backends | ✅ Health checks |
| **Automatic Failover** | ✅ Promotes replica | ✅ Promotes standby |
| **Read/Write Split** | ✅ Automatic | ✅ Automatic |
| **Configuration** | SQL-based | Config file |
| **Complexity** | Medium | Medium-High |

---

## 🏗️ Architecture

### Without Pgpool-II (Manual):
```
Application
    ↓
Must know all servers and choose:
    • PRIMARY:5432 (for writes)
    • STANDBY1:5433 (for reads)
    • STANDBY2:5434 (for reads)
```

### With Pgpool-II (Automatic):
```
Application
    ↓
Pgpool-II:9999 (single connection point)
    ↓ (automatic routing)
    ├→ PRIMARY:5432 (writes + reads)
    ├→ STANDBY1:5433 (reads)
    └→ STANDBY2:5434 (reads)
```

**Application sees ONE database server!**

---

## ✨ Key Features

### 1. **Query Routing (Read/Write Split)**
```sql
-- These automatically go to PRIMARY:
INSERT INTO orders VALUES (1, 'Product A', 100);
UPDATE orders SET amount = 200 WHERE id = 1;
DELETE FROM orders WHERE id = 1;

-- These automatically go to STANDBY1 or STANDBY2:
SELECT * FROM orders;
SELECT COUNT(*) FROM users;
SELECT MAX(amount) FROM orders;
```

### 2. **Load Balancing**
```
Configuration:
  backend_weight0 = 0    → PRIMARY (no SELECT queries)
  backend_weight1 = 1    → STANDBY1 (50% of SELECTs)
  backend_weight2 = 1    → STANDBY2 (50% of SELECTs)

Result:
  100 SELECT queries:
    • 0 to PRIMARY
    • ~50 to STANDBY1
    • ~50 to STANDBY2
```

### 3. **Connection Pooling**
```
Instead of:
  1000 app connections → 1000 PostgreSQL connections ❌

With Pgpool-II:
  1000 app connections → Pgpool-II → 20 PostgreSQL connections ✅
  
Benefit: Reduces resource usage on PostgreSQL servers
```

### 4. **Health Checks & Failover**
```
If STANDBY1 fails:
  • Pgpool detects failure (health check)
  • Removes STANDBY1 from pool
  • Routes all reads to STANDBY2
  • Application unaware of failure ✓

If PRIMARY fails:
  • Pgpool detects failure
  • Can promote STANDBY1 to PRIMARY
  • Updates routing automatically
  • Minimal downtime
```

---

## 🔧 Common Configuration

### Basic Setup:
```ini
# Listen port
port = 9999

# Backends
backend_hostname0 = 'postgres-primary'
backend_port0 = 5432
backend_weight0 = 0           # Don't send SELECTs to primary

backend_hostname1 = 'postgres-standby1'
backend_port1 = 5432
backend_weight1 = 1           # 50% of SELECTs

backend_hostname2 = 'postgres-standby2'
backend_port2 = 5432
backend_weight2 = 1           # 50% of SELECTs

# Features
load_balance_mode = on        # Enable load balancing
backend_clustering_mode = 'streaming_replication'
```

---

## 🎓 Interview Key Points

### **"What is Pgpool-II?"**
✅ **Answer:**
"Pgpool-II is a middleware component for PostgreSQL that provides connection pooling, load balancing, and automatic query routing. It's similar to ProxySQL for MySQL. Applications connect to Pgpool-II on a single port, and it intelligently routes queries - sending writes to the primary and distributing reads across multiple standby servers. This improves scalability, reduces connection overhead, and provides high availability with automatic failover capabilities."

### **"When would you use Pgpool-II?"**
✅ **Answer:**
"Use Pgpool-II when you need:
1. **High read throughput** - distribute SELECT queries across multiple standbys
2. **Connection pooling** - reduce connection overhead (like 1000 app connections → 20 backend connections)
3. **Transparent failover** - automatic promotion of standby if primary fails
4. **Read/write splitting** - automatic routing without application changes
5. **Single entry point** - applications don't need to know about multiple servers"

### **"Pgpool-II vs HAProxy vs PgBouncer?"**
✅ **Answer:**

| Tool | Purpose | Best For |
|------|---------|----------|
| **Pgpool-II** | Query router + connection pooler | All-in-one solution (like ProxySQL) |
| **HAProxy** | TCP load balancer | Simple connection-level load balancing |
| **PgBouncer** | Connection pooler | Lightweight connection pooling only |

**Pgpool-II** = Most feature-rich, understands SQL
**HAProxy** = Simple, doesn't understand SQL (TCP level)
**PgBouncer** = Lightweight, connection pooling focus

---

## 🔄 Alternative Approaches

### 1. **Application-Level (Python)**
```python
import psycopg2
import itertools

READ_REPLICAS = ['standby1:5433', 'standby2:5434']
replicas = itertools.cycle(READ_REPLICAS)

def read_query():
    conn = psycopg2.connect(next(replicas))  # Round-robin
    
def write_query():
    conn = psycopg2.connect('primary:5432')
```

### 2. **HAProxy (TCP Level)**
```haproxy
frontend postgres_write
    bind *:5000
    default_backend postgres_primary

frontend postgres_read
    bind *:5001
    default_backend postgres_standbys
    balance roundrobin  # Automatic!
```

### 3. **PgBouncer (Connection Pooling)**
```ini
[databases]
postgres_write = host=primary port=5432
postgres_read1 = host=standby1 port=5432
postgres_read2 = host=standby2 port=5432
```

---

## ⚠️ Considerations

### **Pros:**
✅ Automatic read/write splitting
✅ Query-level routing (understands SQL)
✅ Built-in failover
✅ Connection pooling
✅ Single entry point for apps

### **Cons:**
❌ Complex configuration
❌ Single point of failure (need redundant Pgpool instances)
❌ Adds network hop (latency)
❌ May require tuning for optimal load balancing
❌ Learning curve

---

## 📊 Real-World Use Cases

### **E-commerce Platform**
```
Traffic: 10,000 queries/sec
  • 1,000 writes/sec → PRIMARY
  • 9,000 reads/sec → Pgpool → 4 STANDBYs (2,250 each)
  
Without Pgpool:
  PRIMARY handles 10,000 q/s (overloaded)
  
With Pgpool:
  PRIMARY handles 1,000 q/s (comfortable)
  Each STANDBY handles 2,250 q/s (comfortable)
```

### **Analytics Dashboard**
```
Heavy read workload:
  • 100 writes/sec
  • 50,000 reads/sec

Pgpool distributes reads:
  → 8 STANDBYs = 6,250 reads/sec each
  
Result: Each server handles manageable load
```

---

## 🎯 Summary for Interviews

**"Pgpool-II is PostgreSQL's answer to ProxySQL - it's a transparent middleware proxy that provides:**
1. **Automatic query routing** (reads to standbys, writes to primary)
2. **Load balancing** across multiple standbys
3. **Connection pooling** to reduce overhead
4. **Failover capabilities** for high availability
5. **Single connection point** simplifying application architecture

**It's most useful in read-heavy applications with replication, where you want to distribute read load across multiple standbys without changing application code."**

---

## 📚 Related Topics to Know

For PostgreSQL High Availability interviews, also understand:
- **Patroni** - Automatic failover orchestration
- **Repmgr** - Replication management
- **PgBouncer** - Lightweight connection pooler
- **HAProxy** - TCP-level load balancer
- **Streaming Replication** - PostgreSQL built-in replication
- **Logical Replication** - Row-level replication

---

*Note: In this demo project, we confirmed Pgpool-II works for connection and backend detection, but full load balancing configuration requires additional tuning based on specific PostgreSQL versions and workload patterns.*
