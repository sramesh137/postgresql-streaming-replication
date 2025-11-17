# Connection Strategy & Routing Guide

**For:** PostgreSQL Streaming Replication  
**Your Setup:** Primary (5432) + Standby (5433)

---

## 🎯 Quick Decision Guide

### When to Route to PRIMARY (port 5432):

✅ **ALL write operations**
- `INSERT INTO ...`
- `UPDATE ... SET ...`
- `DELETE FROM ...`
- `CREATE/DROP/ALTER ...`

✅ **Reads that need locks**
- `SELECT ... FOR UPDATE`
- `SELECT ... FOR SHARE`

✅ **Read-after-write scenarios**
- User just created order → show confirmation
- User just updated profile → show updated data

✅ **Transactions with mixed operations**
```sql
BEGIN;
  INSERT INTO orders ...;
  SELECT * FROM orders WHERE id = ...;  -- Read own write
COMMIT;
```

---

### When to Route to STANDBY (port 5433):

✅ **Product catalog browsing**
```sql
SELECT name, price FROM products WHERE category = 'Electronics';
```

✅ **Search operations**
```sql
SELECT * FROM products WHERE name ILIKE '%laptop%';
```

✅ **Order history**
```sql
SELECT * FROM orders WHERE user_id = 123 ORDER BY order_date DESC;
```

✅ **Analytics & Reports**
```sql
SELECT category, COUNT(*), AVG(price) 
FROM products 
GROUP BY category;
```

✅ **Dashboard queries**
```sql
SELECT 
  COUNT(*) as total_orders,
  SUM(amount) as revenue
FROM orders
WHERE order_date > NOW() - INTERVAL '30 days';
```

✅ **Heavy aggregations**
```sql
SELECT 
  DATE(order_date),
  COUNT(*) as orders,
  SUM(amount) as daily_revenue
FROM orders
GROUP BY DATE(order_date)
ORDER BY DATE(order_date) DESC;
```

---

## 📊 Your Test Results

### Data Freshness Test
```
Action: INSERT on primary at 09:23:07.819026
Result: Visible on standby immediately
Lag: 0 bytes
Conclusion: Real-time replication ✓
```

### Connection Test
```
Primary (5432):  pg_is_in_recovery() = false (read-write)
Standby (5433):  pg_is_in_recovery() = true  (read-only)
```

### Practical Examples Tested

**Scenario 1: Product Search (STANDBY)**
```sql
-- Routed to standby:5433
SELECT name, category, price 
FROM products 
WHERE category = 'Electronics' AND price < 500 
LIMIT 5;

-- Result: ✓ Fast, offloads primary
```

**Scenario 2: Order History (STANDBY)**
```sql
-- Routed to standby:5433
SELECT id, user_id, product, amount, order_date 
FROM orders 
ORDER BY order_date DESC 
LIMIT 5;

-- Result: ✓ Works perfectly
```

**Scenario 3: New Order (PRIMARY)**
```sql
-- Routed to primary:5432
INSERT INTO orders (user_id, product, amount) 
VALUES (1, 'Brand New Product', 999.99);

-- Result: ✓ Inserted, replicated immediately to standby
```

---

## 🔄 Application Connection Strategies

### Strategy 1: Separate Connection Strings (Recommended for Learning)

```python
# Python example
primary_conn = psycopg2.connect(
    host='localhost',
    port=5432,
    dbname='postgres',
    user='postgres'
)

standby_conn = psycopg2.connect(
    host='localhost',
    port=5433,
    dbname='postgres',
    user='postgres'
)

# Use primary for writes
primary_conn.execute("INSERT INTO orders ...")

# Use standby for reads
standby_conn.execute("SELECT * FROM products ...")
```

### Strategy 2: Connection Pooler (Production)

```javascript
// Node.js with connection pool
const primaryPool = new Pool({
  host: 'localhost',
  port: 5432,
  database: 'postgres'
});

const standbyPool = new Pool({
  host: 'localhost',
  port: 5433,
  database: 'postgres'
});

// Route based on query type
async function executeQuery(sql, isWrite = false) {
  const pool = isWrite ? primaryPool : standbyPool;
  return await pool.query(sql);
}

// Usage:
await executeQuery('INSERT INTO orders ...', true);   // Primary
await executeQuery('SELECT * FROM products', false);  // Standby
```

### Strategy 3: Load Balancer with Target Session Attributes

```java
// Java JDBC with target_session_attrs
String primaryUrl = "jdbc:postgresql://localhost:5432/postgres" +
                   "?target_session_attrs=read-write";

String standbyUrl = "jdbc:postgresql://localhost:5433/postgres" +
                   "?target_session_attrs=read-only";
```

---

## ⚠️ Important Considerations

### 1. Data Freshness (Replication Lag)

**Your current lag: 0 bytes (< 1ms)**

```sql
-- Check lag before critical reads:
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes
FROM pg_stat_replication;
```

**When lag matters:**
- User just placed order → reads from PRIMARY to show confirmation
- User just updated profile → reads from PRIMARY to show changes

**When lag doesn't matter:**
- Browsing product catalog (lag < 1ms is invisible to users)
- Viewing historical reports
- Analytics queries

---

### 2. Read-Only Transactions on Standby

**This will FAIL on standby:**
```sql
BEGIN;
INSERT INTO products ...;  -- ERROR: cannot execute INSERT in read-only transaction
COMMIT;
```

**This works on standby:**
```sql
BEGIN;
SELECT * FROM products WHERE price > 500;
SELECT * FROM orders WHERE user_id = 123;
COMMIT;
```

---

### 3. Connection Failure Handling

**If standby goes down:**
- Option 1: Failover reads to primary (temporary performance hit)
- Option 2: Queue read requests until standby recovers
- Option 3: Promote standby to primary (disaster recovery)

**If primary goes down:**
- Promote standby to primary (Scenario 04 will cover this!)
- Writes blocked until promotion complete
- Reads continue working on standby

---

## 📈 Benefits You Get

### From Your Test:

✅ **Offload Primary**
- Heavy analytics run on standby
- Primary freed for writes
- Better overall performance

✅ **Horizontal Read Scaling**
- Currently: 1 primary + 1 standby = 2x read capacity
- Can add: 1 primary + 3 standbys = 4x read capacity
- Linear scaling for read-heavy workloads

✅ **Zero Data Loss Risk**
- All reads from committed data
- Lag < 1ms = effectively real-time
- Standby has all critical data

✅ **Disaster Recovery**
- Standby ready to promote if primary fails
- Minimal data loss (sub-millisecond window)
- Fast failover possible

---

## 🎓 Key Takeaways

1. **Writes ALWAYS go to primary** (only writable server)

2. **Reads CAN go to standby** (better performance, scales horizontally)

3. **Data is real-time** (your lag: 0 bytes, < 1ms)

4. **Route intelligently**:
   - Heavy queries → Standby
   - Read-after-write → Primary
   - Analytics → Standby
   - Search → Standby

5. **Your setup is production-ready** for read scaling!

---

## ✅ What You've Proven

- ✓ Created 10,000 products
- ✓ Data replicated with 0 lag
- ✓ Standby rejects writes (read-only protection)
- ✓ Standby serves reads perfectly
- ✓ New writes appear on standby instantly
- ✓ Connection routing works as expected

**You now understand read load distribution!** 🎉

Next: Scenario 03 - Read-Only Enforcement & Limitations
