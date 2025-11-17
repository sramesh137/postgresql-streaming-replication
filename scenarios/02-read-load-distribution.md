# Scenario 02: Read Load Distribution

**Difficulty:** Beginner  
**Duration:** 20-25 minutes  
**Prerequisites:** Scenario 01 completed

## 🎯 Learning Objectives

By completing this scenario, you will:
- Understand how to distribute reads across primary and standby
- Learn connection strategies for read scaling
- Measure performance benefits of read distribution
- Implement simple connection pooling
- Understand when to use which server

## 📚 Background

**Read Load Distribution** (or Read Scaling) is one of the primary benefits of streaming replication. By routing read queries to standby servers, you can:

- **Reduce primary server load** - Free up resources for writes
- **Improve response times** - Distribute queries across multiple servers
- **Scale horizontally** - Add more standbys as read load grows
- **Isolate workloads** - Run analytics on standbys without affecting production

### Typical Architecture:
```
Application Layer
       ↓
   Load Balancer
    /         \
Primary      Standby
(Writes)     (Reads)
```

---

## Step 1: Verify Current Setup

First, ensure both servers are healthy:

```bash
# Check status
bash scripts/monitor.sh

# Quick connectivity test
docker exec -it postgres-primary psql -U postgres -c "SELECT 'Primary: ' || version();"
docker exec -it postgres-standby psql -U postgres -c "SELECT 'Standby: ' || version();"
```

**Expected:** Both respond successfully

---

## Step 2: Create Test Data

Let's create realistic data for testing:

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Create a products table for read-heavy queries
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    category VARCHAR(50),
    price NUMERIC(10,2),
    description TEXT,
    stock_quantity INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample products
INSERT INTO products (name, category, price, description, stock_quantity)
SELECT 
    'Product ' || i,
    CASE (i % 5)
        WHEN 0 THEN 'Electronics'
        WHEN 1 THEN 'Books'
        WHEN 2 THEN 'Clothing'
        WHEN 3 THEN 'Home'
        ELSE 'Sports'
    END,
    (random() * 1000 + 10)::NUMERIC(10,2),
    'Description for product ' || i || '. ' || repeat('Lorem ipsum dolor sit amet. ', 5),
    (random() * 100)::INTEGER
FROM generate_series(1, 5000) AS i;

-- Create index for common queries
CREATE INDEX idx_products_category ON products(category);
CREATE INDEX idx_products_price ON products(price);

\echo 'Products table created with 5000 rows!'
EOF
```

**Verify on standby:**
```bash
docker exec -it postgres-standby psql -U postgres -c "SELECT COUNT(*) FROM products;"
```

---

## Step 3: Simple Read Query Performance

Let's compare query performance on both servers:

### Query 1: Simple SELECT

**On Primary:**
```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
\timing on
SELECT category, COUNT(*), AVG(price), MIN(price), MAX(price)
FROM products
GROUP BY category
ORDER BY category;
\timing off
EOF
```

**On Standby:**
```bash
docker exec -it postgres-standby psql -U postgres << 'EOF'
\timing on
SELECT category, COUNT(*), AVG(price), MIN(price), MAX(price)
FROM products
GROUP BY category
ORDER BY category;
\timing off
EOF
```

**Record Results:**
- Primary execution time: _____ ms
- Standby execution time: _____ ms

**Note:** Times should be very similar (both unloaded)

---

## Step 4: Simulate Write Load on Primary

Now let's load the primary with writes and see how reads perform:

**Terminal 1 - Generate write load on primary:**
```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
DO $$
BEGIN
    FOR i IN 1..10000 LOOP
        INSERT INTO orders (user_id, product, amount)
        VALUES (
            (random() * 10 + 1)::INTEGER,
            'Product_' || i,
            (random() * 1000)::NUMERIC(10,2)
        );
        
        IF i % 1000 = 0 THEN
            RAISE NOTICE 'Inserted % orders', i;
        END IF;
    END LOOP;
    RAISE NOTICE 'Write load completed!';
END $$;
EOF
```

**Terminal 2 - Query primary DURING writes:**
```bash
# Run this while Terminal 1 is still running
docker exec -it postgres-primary psql -U postgres << 'EOF'
\timing on
SELECT 
    p.category,
    COUNT(*) as product_count,
    AVG(p.price) as avg_price
FROM products p
WHERE p.price > 100
GROUP BY p.category
ORDER BY avg_price DESC;
\timing off
EOF
```

**Terminal 3 - Query standby DURING writes:**
```bash
# Run this while Terminal 1 is still running
docker exec -it postgres-standby psql -U postgres << 'EOF'
\timing on
SELECT 
    p.category,
    COUNT(*) as product_count,
    AVG(p.price) as avg_price
FROM products p
WHERE p.price > 100
GROUP BY p.category
ORDER BY avg_price DESC;
\timing off
EOF
```

**Compare:**
- Primary (under write load): _____ ms
- Standby (no write load): _____ ms

**Observation:** Standby should be faster or unaffected

---

## Step 5: Create Connection Test Script

Let's create a script to test connections programmatically:

```bash
cat > /tmp/test_connections.sh << 'EOF'
#!/bin/bash

echo "========================================="
echo "PostgreSQL Connection Distribution Test"
echo "========================================="

# Test primary
echo -e "\n📝 Testing PRIMARY (Read-Write):"
PRIMARY_TIME=$(docker exec -i postgres-primary psql -U postgres -t -c "\timing on" -c "SELECT COUNT(*) FROM products;" -c "\timing off" 2>&1 | grep "Time" | awk '{print $2}')
echo "Response time: $PRIMARY_TIME"

# Test standby  
echo -e "\n📖 Testing STANDBY (Read-Only):"
STANDBY_TIME=$(docker exec -i postgres-standby psql -U postgres -t -c "\timing on" -c "SELECT COUNT(*) FROM products;" -c "\timing off" 2>&1 | grep "Time" | awk '{print $2}')
echo "Response time: $STANDBY_TIME"

echo -e "\n========================================="
echo "✅ Connection test completed!"
echo "========================================="
EOF

chmod +x /tmp/test_connections.sh
bash /tmp/test_connections.sh
```

---

## Step 6: Connection String Strategy

In real applications, you'd use different connection strings:

### Example Connection Strings:

**Python (psycopg2):**
```python
# Primary connection (writes)
primary_conn = psycopg2.connect(
    host='localhost',
    port=5432,
    user='postgres',
    password='postgres_password',
    database='postgres'
)

# Standby connection (reads)
standby_conn = psycopg2.connect(
    host='localhost',
    port=5433,
    user='postgres',
    password='postgres_password',
    database='postgres'
)
```

**Node.js (pg):**
```javascript
// Primary pool
const primaryPool = new Pool({
    host: 'localhost',
    port: 5432,
    user: 'postgres',
    password: 'postgres_password',
    database: 'postgres'
});

// Standby pool
const standbyPool = new Pool({
    host: 'localhost',
    port: 5433,
    user: 'postgres',
    password: 'postgres_password',
    database: 'postgres'
});
```

**Let's create a simple Python test:**

```bash
cat > /tmp/test_read_distribution.py << 'EOF'
#!/usr/bin/env python3
import time
import subprocess

def query_server(port, query, label):
    """Execute query and measure time"""
    start = time.time()
    cmd = f'docker exec -i postgres-{"primary" if port == 5432 else "standby"} psql -U postgres -t -c "{query}"'
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    elapsed = (time.time() - start) * 1000  # Convert to ms
    print(f"{label}: {elapsed:.2f} ms")
    return elapsed

print("=" * 50)
print("Read Distribution Performance Test")
print("=" * 50)

# Test query
test_query = "SELECT COUNT(*) FROM products WHERE price > 100;"

# Test multiple times
primary_times = []
standby_times = []

for i in range(5):
    print(f"\nRound {i+1}:")
    p_time = query_server(5432, test_query, "  Primary")
    s_time = query_server(5433, test_query, "  Standby")
    primary_times.append(p_time)
    standby_times.append(s_time)
    time.sleep(0.5)

print("\n" + "=" * 50)
print("Summary:")
print(f"Primary average: {sum(primary_times)/len(primary_times):.2f} ms")
print(f"Standby average: {sum(standby_times)/len(standby_times):.2f} ms")
print("=" * 50)
EOF

python3 /tmp/test_read_distribution.py
```

---

## Step 7: Query Routing Strategy

Create a routing decision guide:

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Create a view to help decide query routing
CREATE OR REPLACE VIEW query_routing_guide AS
SELECT 
    'SELECT statements' AS query_type,
    'Standby' AS recommended_target,
    'Reduces primary load' AS reason,
    'Products catalog, user profiles, reports' AS examples
UNION ALL
SELECT 
    'INSERT/UPDATE/DELETE',
    'Primary ONLY',
    'Writes not allowed on standby',
    'Orders, user registration, updates'
UNION ALL
SELECT 
    'Analytics/Aggregations',
    'Standby',
    'Heavy queries on standby, primary free for transactions',
    'Dashboard metrics, business reports'
UNION ALL
SELECT 
    'Real-time data requirements',
    'Primary',
    'Need absolute latest data',
    'Inventory check before order, account balance'
UNION ALL
SELECT 
    'Bulk read operations',
    'Standby',
    'Don''t impact transactional performance',
    'Data export, batch processing';

SELECT * FROM query_routing_guide;
EOF
```

---

## Step 8: Practical Routing Examples

### Example 1: Product Catalog (→ Standby)
```bash
echo "📖 Reading from Standby (Product Catalog):"
docker exec -it postgres-standby psql -U postgres << 'EOF'
\timing on
SELECT id, name, category, price 
FROM products 
WHERE category = 'Electronics' 
  AND price BETWEEN 100 AND 500
LIMIT 20;
\timing off
EOF
```

### Example 2: Place Order (→ Primary)
```bash
echo "📝 Writing to Primary (Place Order):"
docker exec -it postgres-primary psql -U postgres << 'EOF'
\timing on
BEGIN;
INSERT INTO orders (user_id, product, amount)
VALUES (1, 'Product 42', 299.99)
RETURNING *;
COMMIT;
\timing off
EOF
```

### Example 3: Analytics Report (→ Standby)
```bash
echo "📊 Analytics on Standby:"
docker exec -it postgres-standby psql -U postgres << 'EOF'
\timing on
SELECT 
    category,
    COUNT(*) as products,
    AVG(price) as avg_price,
    SUM(stock_quantity) as total_stock,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price) as median_price
FROM products
GROUP BY category
ORDER BY products DESC;
\timing off
EOF
```

---

## Step 9: Concurrent Read Load Test

Test multiple simultaneous reads:

```bash
cat > /tmp/concurrent_reads.sh << 'EOF'
#!/bin/bash

echo "Testing concurrent reads..."

# Function to run query
run_query() {
    SERVER=$1
    ID=$2
    docker exec -i $SERVER psql -U postgres -t -c "SELECT COUNT(*) FROM products WHERE price > 100;" > /dev/null
    echo "Query $ID on $SERVER completed"
}

# Start timestamp
START=$(date +%s)

# Launch 10 concurrent queries on each server
for i in {1..10}; do
    run_query "postgres-primary" "$i-primary" &
    run_query "postgres-standby" "$i-standby" &
done

# Wait for all to complete
wait

# End timestamp
END=$(date +%s)
DURATION=$((END - START))

echo "All 20 queries completed in $DURATION seconds"
EOF

chmod +x /tmp/concurrent_reads.sh
bash /tmp/concurrent_reads.sh
```

---

## Step 10: Monitor Server Load Distribution

Check which server is handling load:

```bash
# Check active connections on both servers
echo "=== PRIMARY Connections ==="
docker exec -it postgres-primary psql -U postgres -c "SELECT COUNT(*) as active_connections FROM pg_stat_activity WHERE state = 'active';"

echo -e "\n=== STANDBY Connections ==="
docker exec -it postgres-standby psql -U postgres -c "SELECT COUNT(*) as active_connections FROM pg_stat_activity WHERE state = 'active';"

# Check database statistics
echo -e "\n=== Query Statistics ==="
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    datname,
    numbackends as connections,
    xact_commit as transactions_committed,
    xact_rollback as transactions_rolled_back,
    blks_read as disk_blocks_read,
    blks_hit as cache_blocks_hit,
    tup_returned as rows_returned,
    tup_fetched as rows_fetched
FROM pg_stat_database 
WHERE datname = 'postgres';
EOF
```

---

## 🎓 Knowledge Check

1. **When should you route queries to the standby?**
   - [ ] All SELECT statements
   - [ ] Only read-heavy analytics
   - [ ] Never, always use primary
   - [ ] When you can tolerate potential minimal lag

2. **Can you INSERT data on standby?**
   - [ ] Yes, if you use a special flag
   - [ ] No, standby is always read-only
   - [ ] Yes, but only small inserts
   - [ ] Only if lag is zero

3. **What's the main benefit of read distribution?**
   - [ ] Faster writes on primary
   - [ ] Lower cost
   - [ ] Reduced primary server load
   - [ ] Better security

4. **Which workload should stay on primary?**
   - [ ] Product catalog queries
   - [ ] Real-time inventory checks
   - [ ] Analytics reports
   - [ ] User profile lookups

---

## 🧪 Experiments to Try

### Experiment 1: Lag-Sensitive Reads

```bash
# Insert on primary
docker exec -it postgres-primary psql -U postgres -c "INSERT INTO products (name, category, price) VALUES ('Just Added', 'New', 999.99) RETURNING id;"

# Immediately query standby
docker exec -it postgres-standby psql -U postgres -c "SELECT * FROM products WHERE name = 'Just Added';"
```

**Question:** Did the row appear immediately? Why or why not?

### Experiment 2: Heavy Query Impact

```bash
# Terminal 1: Run heavy query on PRIMARY
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT pg_sleep(5);  -- Simulate heavy query
EOF

# Terminal 2: During sleep, query PRIMARY
docker exec -it postgres-primary psql -U postgres -c "SELECT COUNT(*) FROM products;"

# Terminal 3: During sleep, query STANDBY  
docker exec -it postgres-standby psql -U postgres -c "SELECT COUNT(*) FROM products;"
```

**Question:** Which responded faster?

---

## 📊 Results Summary

| Metric | Primary | Standby | Improvement |
|--------|---------|---------|-------------|
| Simple SELECT (ms) | | | |
| Under write load (ms) | | | |
| Concurrent queries (s) | | | |
| Connection handling | | | |

---

## 🎯 Real-World Application Patterns

### Pattern 1: E-commerce Site
```
User browsing products → Standby
User adding to cart → Primary
User checkout → Primary
Order history → Standby (can be slightly stale)
Product recommendations → Standby
```

### Pattern 2: Social Media
```
Reading feed → Standby
Posting → Primary
Reading notifications → Standby (fresh enough)
Updating profile → Primary
Analytics dashboard → Standby
```

### Pattern 3: Banking App
```
Account balance → Primary (must be real-time)
Transaction history → Primary (critical accuracy)
Transaction reports → Standby (can be 1s old)
User profile → Standby
```

---

## 🔧 Cleanup

```bash
# Optional: Keep the products table for next scenarios
# Or remove it:
docker exec -it postgres-primary psql -U postgres -c "DROP TABLE IF EXISTS products CASCADE;"
```

---

## 🎯 Key Takeaways

✅ **Standby servers reduce primary load** by handling read queries  
✅ **Route by workload type** - analytics to standby, critical reads to primary  
✅ **Connection pooling** helps manage multiple connections efficiently  
✅ **Minimal lag means** standby data is usually fresh enough  
✅ **Load distribution improves** overall system performance  

---

## 📝 What You Learned

- [x] How to route queries to different servers
- [x] When to use primary vs standby
- [x] Connection strategies for read scaling
- [x] Performance benefits of load distribution
- [x] Real-world routing patterns

---

## ➡️ Next Scenario

**[Scenario 03: Read-Only Enforcement](./03-read-only-enforcement.md)**

Explore the boundaries of standby read-only mode and understand what operations are allowed vs prohibited.

```bash
cat scenarios/03-read-only-enforcement.md
```
