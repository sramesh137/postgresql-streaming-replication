# Load Balancing PostgreSQL Standbys - Implementation Guide

## 🎯 The Reality: NO Automatic Load Balancing!

**What we have now:**
```
PRIMARY:5432   ← All traffic goes here by default
STANDBY1:5433  ← Idle (waiting for manual connection)
STANDBY2:5434  ← Idle (waiting for manual connection)
```

**PostgreSQL does NOT automatically distribute reads!**

You must implement load balancing yourself using one of these methods:

---

## 🔧 Method 1: Application-Level Load Balancing

### Python Example (Round-Robin):

```python
import psycopg2
import itertools

# Define read replicas
READ_REPLICAS = [
    {'host': 'localhost', 'port': 5433},  # STANDBY1
    {'host': 'localhost', 'port': 5434},  # STANDBY2
]

# Create round-robin iterator
replica_cycle = itertools.cycle(READ_REPLICAS)

def get_read_connection():
    """Get connection to next standby in round-robin"""
    replica = next(replica_cycle)
    return psycopg2.connect(
        host=replica['host'],
        port=replica['port'],
        user='postgres',
        database='postgres'
    )

def get_write_connection():
    """Get connection to PRIMARY for writes"""
    return psycopg2.connect(
        host='localhost',
        port=5432,
        user='postgres',
        database='postgres'
    )

# Usage:
# For reads:
read_conn = get_read_connection()  # → STANDBY1
cursor = read_conn.cursor()
cursor.execute("SELECT COUNT(*) FROM orders")

# Next read:
read_conn2 = get_read_connection()  # → STANDBY2

# For writes:
write_conn = get_write_connection()  # → PRIMARY
cursor = write_conn.cursor()
cursor.execute("INSERT INTO orders ...")
```

**Distribution pattern:**
```
Query 1 → STANDBY1
Query 2 → STANDBY2
Query 3 → STANDBY1
Query 4 → STANDBY2
...
```

### Python Example (Random):

```python
import psycopg2
import random

READ_REPLICAS = [
    {'host': 'localhost', 'port': 5433},
    {'host': 'localhost', 'port': 5434},
]

def get_read_connection():
    """Get connection to random standby"""
    replica = random.choice(READ_REPLICAS)
    return psycopg2.connect(
        host=replica['host'],
        port=replica['port'],
        user='postgres',
        database='postgres'
    )
```

**Distribution pattern:**
```
Over 100 queries:
  STANDBY1: ~50 queries (50%)
  STANDBY2: ~50 queries (50%)
```

### Python Example (Weighted):

```python
import psycopg2
import random

# Give more load to STANDBY1 (better hardware?)
READ_REPLICAS = [
    {'host': 'localhost', 'port': 5433, 'weight': 70},  # 70% traffic
    {'host': 'localhost', 'port': 5434, 'weight': 30},  # 30% traffic
]

def get_read_connection():
    """Get connection based on weights"""
    weights = [r['weight'] for r in READ_REPLICAS]
    replica = random.choices(READ_REPLICAS, weights=weights)[0]
    return psycopg2.connect(
        host=replica['host'],
        port=replica['port'],
        user='postgres',
        database='postgres'
    )
```

**Distribution pattern:**
```
Over 100 queries:
  STANDBY1: ~70 queries (70%)
  STANDBY2: ~30 queries (30%)
```

---

## 🔧 Method 2: Connection Pooler (PgBouncer)

**Most common production solution!**

### PgBouncer Configuration:

```ini
# pgbouncer.ini

[databases]
; Write database (PRIMARY)
postgres_write = host=localhost port=5432 dbname=postgres

; Read databases (STANDBYs)
postgres_read1 = host=localhost port=5433 dbname=postgres
postgres_read2 = host=localhost port=5434 dbname=postgres

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
```

### Application Usage:

```python
import psycopg2

# For writes - connect to PRIMARY via pgbouncer
write_conn = psycopg2.connect(
    host='localhost',
    port=6432,
    dbname='postgres_write',
    user='postgres'
)

# For reads - application chooses replica
read_conn1 = psycopg2.connect(
    host='localhost',
    port=6432,
    dbname='postgres_read1',  # → STANDBY1
    user='postgres'
)

read_conn2 = psycopg2.connect(
    host='localhost',
    port=6432,
    dbname='postgres_read2',  # → STANDBY2
    user='postgres'
)
```

**Benefits:**
- Connection pooling (reuse connections)
- Centralized configuration
- Better resource management
- Still need app-level logic for replica selection

---

## 🔧 Method 3: Load Balancer (HAProxy)

**True automatic load balancing!**

### HAProxy Configuration:

```haproxy
# /etc/haproxy/haproxy.cfg

global
    maxconn 1000

defaults
    mode tcp
    timeout connect 10s
    timeout client 30s
    timeout server 30s

# Frontend for writes → PRIMARY only
frontend postgres_write
    bind *:5000
    default_backend postgres_primary

backend postgres_primary
    server primary localhost:5432 check

# Frontend for reads → Load balanced across standbys
frontend postgres_read
    bind *:5001
    default_backend postgres_standbys

backend postgres_standbys
    balance roundrobin                    # ← ROUND-ROBIN algorithm
    option tcp-check
    server standby1 localhost:5433 check
    server standby2 localhost:5434 check
```

### Application Usage:

```python
import psycopg2

# For writes - connect to HAProxy write port
write_conn = psycopg2.connect(
    host='localhost',
    port=5000,  # HAProxy write frontend
    dbname='postgres',
    user='postgres'
)

# For reads - connect to HAProxy read port
# HAProxy AUTOMATICALLY distributes across STANDBY1/STANDBY2
read_conn = psycopg2.connect(
    host='localhost',
    port=5001,  # HAProxy read frontend
    dbname='postgres',
    user='postgres'
)

# All read connections go to port 5001
# HAProxy handles distribution automatically!
for i in range(10):
    conn = psycopg2.connect(host='localhost', port=5001, ...)
    # Connection 1 → STANDBY1
    # Connection 2 → STANDBY2
    # Connection 3 → STANDBY1
    # Connection 4 → STANDBY2
    # ... automatic round-robin!
```

**Distribution algorithms available:**
```
roundrobin:  Query 1→S1, Query 2→S2, Query 3→S1, Query 4→S2
leastconn:   Send to standby with fewest active connections
random:      Random distribution
source:      Same client IP always to same standby
```

**Benefits:**
- ✅ TRUE automatic load balancing
- ✅ Application doesn't need to know about replicas
- ✅ Health checks (removes failed standby automatically)
- ✅ Connection-level distribution

---

## 🔧 Method 4: Pgpool-II (Most Feature-Rich)

**Combines connection pooling + load balancing + automatic failover!**

### Pgpool-II Configuration:

```ini
# pgpool.conf

# Load balancing
load_balance_mode = on
backend_weight0 = 1  # PRIMARY (for writes)
backend_weight1 = 1  # STANDBY1 (reads)
backend_weight2 = 1  # STANDBY2 (reads)

# Backend servers
backend_hostname0 = 'localhost'
backend_port0 = 5432
backend_flag0 = 'ALWAYS_PRIMARY'

backend_hostname1 = 'localhost'
backend_port1 = 5433
backend_flag1 = 'DISALLOW_TO_FAILOVER'

backend_hostname2 = 'localhost'
backend_port2 = 5434
backend_flag2 = 'DISALLOW_TO_FAILOVER'

# Query routing
black_function_list = ''
white_function_list = ''
```

### Application Usage:

```python
import psycopg2

# Single connection point!
conn = psycopg2.connect(
    host='localhost',
    port=9999,  # Pgpool-II port
    dbname='postgres',
    user='postgres'
)

cursor = conn.cursor()

# Pgpool-II AUTOMATICALLY routes queries:
cursor.execute("SELECT * FROM orders")  # → Sent to STANDBY1 or STANDBY2
cursor.execute("SELECT * FROM users")   # → Sent to STANDBY1 or STANDBY2
cursor.execute("INSERT INTO orders ...") # → Sent to PRIMARY
cursor.execute("UPDATE orders ...")     # → Sent to PRIMARY
```

**Magic features:**
- ✅ Automatic query routing (reads→standbys, writes→primary)
- ✅ Load balancing across standbys
- ✅ Connection pooling
- ✅ Automatic failover
- ✅ Application sees single database!

---

## 📊 Comparison Matrix

| Method | Automatic? | Health Checks | Complexity | Best For |
|--------|-----------|---------------|------------|----------|
| **App-Level** | ❌ Manual | ❌ No | Low | Small apps, learning |
| **PgBouncer** | ⚠️ Partial | ❌ No | Medium | Connection pooling focus |
| **HAProxy** | ✅ Yes | ✅ Yes | Medium | Simple load balancing |
| **Pgpool-II** | ✅ Yes | ✅ Yes | High | Enterprise production |

---

## 🧪 Let's Test Real Load Balancing

### Setup HAProxy (Quick Demo):

```bash
# Install HAProxy
brew install haproxy

# Create config
cat > /tmp/haproxy.cfg <<EOF
defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend postgres_read
    bind *:5001
    default_backend postgres_standbys

backend postgres_standbys
    balance roundrobin
    server standby1 localhost:5433
    server standby2 localhost:5434
EOF

# Start HAProxy
haproxy -f /tmp/haproxy.cfg

# Now test:
for i in {1..10}; do
    psql -h localhost -p 5001 -U postgres -c "SELECT 'Query $i' as query"
done
# HAProxy automatically distributes:
# Query 1 → STANDBY1
# Query 2 → STANDBY2
# Query 3 → STANDBY1
# Query 4 → STANDBY2
# ...
```

---

## 🎯 What Happens Without Load Balancing?

**Current situation:**

```python
# Application code:
conn = psycopg2.connect(host='localhost', port=5432, ...)

# ALL queries (reads + writes) go to PRIMARY!
cursor.execute("SELECT * FROM orders")  # → PRIMARY (port 5432)
cursor.execute("SELECT * FROM users")   # → PRIMARY (port 5432)
cursor.execute("INSERT INTO orders ...") # → PRIMARY (port 5432)

# STANDBY1 and STANDBY2 are IDLE!
```

**Load distribution:**
```
PRIMARY:  100% of traffic (overloaded!)
STANDBY1: 0% of traffic (wasted!)
STANDBY2: 0% of traffic (wasted!)
```

**With application-level load balancing:**

```python
# Separate read/write connections:
write_conn = psycopg2.connect(host='localhost', port=5432)
read_conn = get_read_connection()  # Round-robin to 5433 or 5434

# Writes to PRIMARY:
write_cursor = write_conn.cursor()
write_cursor.execute("INSERT INTO orders ...")  # → PRIMARY

# Reads to STANDBYs:
read_cursor = read_conn.cursor()
read_cursor.execute("SELECT * FROM orders")  # → STANDBY1 or STANDBY2
```

**Load distribution:**
```
PRIMARY:  100% writes + 0% reads = 40% total (comfortable)
STANDBY1: 50% of reads = 30% total (utilized)
STANDBY2: 50% of reads = 30% total (utilized)
```

---

## 🔍 Real-World Example

### Before Load Balancing:
```
Application: 1000 queries/sec
  • 100 writes/sec
  • 900 reads/sec

PRIMARY: 1000 queries/sec (100 writes + 900 reads)
  → CPU: 80% (near limit!)
  → Response time: 50ms (slow)
  
STANDBY1: 0 queries/sec
  → CPU: 5% (idle)
  
STANDBY2: 0 queries/sec
  → CPU: 5% (idle)
```

### After Load Balancing (HAProxy):
```
Application: 1000 queries/sec
  • 100 writes/sec → PRIMARY
  • 900 reads/sec → HAProxy → STANDBY1/STANDBY2

PRIMARY: 100 queries/sec (writes only)
  → CPU: 15% (healthy!)
  → Response time: 5ms (fast!)
  
STANDBY1: 450 queries/sec (50% of reads)
  → CPU: 40% (healthy)
  → Response time: 5ms
  
STANDBY2: 450 queries/sec (50% of reads)
  → CPU: 40% (healthy)
  → Response time: 5ms
```

**Result:** 10× faster response times by using standbys!

---

## 💡 Summary

**What you asked:** "How are reads split?"

**Answer:** They're NOT split automatically!

**You must implement:**
1. **Simple:** Application-level round-robin (manual)
2. **Better:** HAProxy (automatic connection-level)
3. **Best:** Pgpool-II (automatic query-level)

**In Scenario 07:** I demonstrated manual distribution by explicitly choosing which standby to query.

**In production:** You'd use HAProxy or Pgpool-II for automatic distribution.

---

## 🚀 Want to Try HAProxy?

I can help you:
1. Install HAProxy
2. Configure round-robin load balancing
3. Test automatic distribution
4. Compare performance with/without load balancing

Let me know! 🎯
