# PostgreSQL Indexing Strategy Guide

**Complete Guide for MySQL DBAs Transitioning to PostgreSQL**

---

## 🎯 Index Types Comparison: MySQL vs PostgreSQL

| Index Type | MySQL (InnoDB) | PostgreSQL | Notes |
|------------|---------------|------------|-------|
| **B-Tree** | ✅ Default | ✅ Default | Most common, used for =, <, >, BETWEEN |
| **Hash** | ✅ (Memory) | ✅ | Fast for equality (=), not for ranges |
| **GiST** | ❌ | ✅ | Generalized Search Tree, geo data, full-text |
| **GIN** | ❌ | ✅ | Generalized Inverted Index, arrays, JSONB, full-text |
| **BRIN** | ❌ | ✅ | Block Range Index, huge tables with natural order |
| **SP-GiST** | ❌ | ✅ | Space-partitioned GiST, non-balanced structures |
| **Full-Text** | ✅ | ✅ | Different syntax and features |
| **Spatial (R-Tree)** | ✅ | ✅ (via GiST) | Geospatial data |
| **Covering Index** | ✅ | ✅ (INCLUDE) | Different syntax |
| **Function-Based** | ✅ (generated) | ✅ (expression) | Different implementation |

**Key Difference:** PostgreSQL has MORE index types, giving you more optimization options!

---

## 📚 1. B-Tree Index (Default)

**When to Use:** 
- Equality (=) and range queries (<, >, BETWEEN)
- Sorting (ORDER BY)
- Pattern matching with left-anchored LIKE ('ABC%')

**MySQL Example:**
```sql
CREATE INDEX idx_customer_email ON customers(email);

SELECT * FROM customers WHERE email = 'user@example.com';
-- Uses: idx_customer_email
```

**PostgreSQL - Same Syntax:**
```sql
CREATE INDEX idx_customer_email ON customers(email);

SELECT * FROM customers WHERE email = 'user@example.com';
-- Uses: idx_customer_email

-- Check index usage
EXPLAIN ANALYZE
SELECT * FROM customers WHERE email = 'user@example.com';
```

### Multi-Column B-Tree Index

**Rule:** Column order matters! (Same as MySQL)

```sql
-- Index on (last_name, first_name)
CREATE INDEX idx_name ON customers(last_name, first_name);

-- ✅ Uses index (left-most column)
SELECT * FROM customers WHERE last_name = 'Smith';

-- ✅ Uses index (both columns)
SELECT * FROM customers WHERE last_name = 'Smith' AND first_name = 'John';

-- ❌ Does NOT use index (skips left-most column)
SELECT * FROM customers WHERE first_name = 'John';
```

**PostgreSQL Advantage:** Can use index for partial matches
```sql
-- PostgreSQL can use idx_name for ORDER BY even without WHERE
SELECT * FROM customers ORDER BY last_name, first_name;
-- MySQL often requires explicit index hint
```

---

## 🔐 2. Unique Index

**MySQL:**
```sql
CREATE UNIQUE INDEX idx_email ON users(email);
-- Or
ALTER TABLE users ADD UNIQUE KEY idx_email (email);
```

**PostgreSQL:**
```sql
CREATE UNIQUE INDEX idx_email ON users(email);
-- Or (preferred)
ALTER TABLE users ADD CONSTRAINT uq_email UNIQUE (email);
```

### Partial Unique Index (PostgreSQL Only!)

**Problem:** Allow multiple NULLs but enforce uniqueness for non-NULL values

**MySQL:** Not possible, workaround with triggers

**PostgreSQL:**
```sql
-- Only one active email per user
CREATE UNIQUE INDEX idx_active_email 
ON users(email) 
WHERE deleted_at IS NULL;

-- Can insert:
INSERT INTO users (email, deleted_at) VALUES ('test@test.com', NULL);  -- ✅
INSERT INTO users (email, deleted_at) VALUES ('test@test.com', NOW()); -- ✅ (deleted)
INSERT INTO users (email, deleted_at) VALUES ('test@test.com', NULL);  -- ❌ Duplicate!
```

**Real-World Use Cases:**
```sql
-- Only one active subscription per user
CREATE UNIQUE INDEX idx_active_subscription
ON subscriptions(user_id)
WHERE status = 'active';

-- Only one primary address per user
CREATE UNIQUE INDEX idx_primary_address
ON addresses(user_id)
WHERE is_primary = true;
```

---

## 🚀 3. Hash Index

**When to Use:** Equality comparisons ONLY (=)

**MySQL:** Only in MEMORY engine, not persistent

**PostgreSQL:** Persistent, but limited use cases

```sql
CREATE INDEX idx_customer_id USING hash ON orders(customer_id);

-- ✅ Fast for exact match
SELECT * FROM orders WHERE customer_id = 12345;

-- ❌ Cannot use for range
SELECT * FROM orders WHERE customer_id > 12345;  -- Won't use hash index

-- ❌ Cannot use for sorting
SELECT * FROM orders ORDER BY customer_id;  -- Won't use hash index
```

**Recommendation:** Stick with B-Tree unless you have specific benchmarks showing hash is faster.

**Why Hash Rarely Used:**
- B-Tree is almost as fast for equality
- B-Tree works for ranges AND equality
- Hash doesn't support WAL before PostgreSQL 10 (crash safety)

---

## 📦 4. GIN Index (Generalized Inverted Index)

**PostgreSQL Superpower:** Best for JSONB, arrays, full-text search

**Use Cases:**
1. JSONB columns
2. Array columns
3. Full-text search
4. Any column with multiple values

### JSONB Indexing

```sql
-- Table with JSONB column
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name TEXT,
    attributes JSONB
);

-- Sample data
INSERT INTO products (name, attributes) VALUES
('Laptop', '{"brand": "Dell", "ram": "16GB", "storage": "512GB"}'),
('Phone', '{"brand": "Apple", "model": "iPhone 14", "storage": "256GB"}');

-- Create GIN index
CREATE INDEX idx_attributes ON products USING gin(attributes);

-- ✅ Fast queries
SELECT * FROM products WHERE attributes @> '{"brand": "Dell"}';
SELECT * FROM products WHERE attributes ? 'storage';
SELECT * FROM products WHERE attributes ?| ARRAY['ram', 'cpu'];
```

**GIN Operators:**
- `@>` - Contains (e.g., `{"brand": "Dell"}` in attributes)
- `?` - Key exists
- `?|` - Any key exists
- `?&` - All keys exist
- `@?` - JSON path exists

### Array Indexing

```sql
-- Table with array column
CREATE TABLE articles (
    id SERIAL PRIMARY KEY,
    title TEXT,
    tags TEXT[]
);

INSERT INTO articles (title, tags) VALUES
('PostgreSQL Tutorial', ARRAY['database', 'postgresql', 'tutorial']),
('Python Guide', ARRAY['python', 'programming', 'tutorial']);

-- Create GIN index
CREATE INDEX idx_tags ON articles USING gin(tags);

-- ✅ Fast array queries
SELECT * FROM articles WHERE tags @> ARRAY['postgresql'];
SELECT * FROM articles WHERE 'database' = ANY(tags);
SELECT * FROM articles WHERE tags && ARRAY['python', 'database'];
```

### Full-Text Search

```sql
-- Table for documents
CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    search_vector tsvector
);

-- Create GIN index on tsvector
CREATE INDEX idx_search ON documents USING gin(search_vector);

-- Insert with tsvector
INSERT INTO documents (title, content, search_vector) VALUES
(
    'PostgreSQL Performance',
    'Learn how to optimize PostgreSQL queries...',
    to_tsvector('english', 'PostgreSQL Performance Learn how to optimize PostgreSQL queries')
);

-- Search
SELECT * FROM documents 
WHERE search_vector @@ to_tsquery('english', 'PostgreSQL & optimize');

-- Alternative: Automatic tsvector generation
CREATE TABLE documents2 (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT
);

-- Create expression index
CREATE INDEX idx_search2 ON documents2 USING gin(
    to_tsvector('english', title || ' ' || content)
);

-- Query
SELECT * FROM documents2
WHERE to_tsvector('english', title || ' ' || content) @@ 
      to_tsquery('english', 'PostgreSQL & optimize');
```

**GIN vs GiST for Full-Text:**
- **GIN:** Faster searches, slower updates, larger index
- **GiST:** Slower searches, faster updates, smaller index
- **Rule:** Use GIN for read-heavy, GiST for write-heavy

---

## 🗺️ 5. GiST Index (Generalized Search Tree)

**Use Cases:**
1. Geospatial data (PostGIS)
2. Range types
3. Full-text search (alternative to GIN)
4. Custom data types with overlapping

### Geometric Data

```sql
-- PostGIS extension
CREATE EXTENSION postgis;

CREATE TABLE locations (
    id SERIAL PRIMARY KEY,
    name TEXT,
    location GEOGRAPHY(POINT)
);

-- Create GiST index for spatial queries
CREATE INDEX idx_location ON locations USING gist(location);

-- Find nearby locations
SELECT name FROM locations
WHERE ST_DWithin(
    location,
    ST_MakePoint(-122.4194, 37.7749)::geography,
    5000  -- 5km radius
);
```

### Range Types

```sql
-- Booking system with date ranges
CREATE TABLE reservations (
    id SERIAL PRIMARY KEY,
    room_id INT,
    period daterange
);

-- GiST index for range overlaps
CREATE INDEX idx_period ON reservations USING gist(period);

-- Find overlapping reservations
SELECT * FROM reservations
WHERE period && daterange('2025-11-20', '2025-11-25');

-- Find available rooms
SELECT room_id FROM rooms
WHERE NOT EXISTS (
    SELECT 1 FROM reservations
    WHERE reservations.room_id = rooms.room_id
    AND period && daterange('2025-11-20', '2025-11-25')
);
```

---

## 📊 6. BRIN Index (Block Range Index)

**PostgreSQL's Secret Weapon for HUGE Tables**

**Use Case:** Very large tables with natural ordering (time-series, logs, sequences)

**How it Works:**
- Stores min/max values per range of pages (default 128 pages)
- Tiny index size (1000x smaller than B-Tree!)
- Fast for range scans on correlated data

```sql
-- IoT sensor data (billions of rows)
CREATE TABLE sensor_data (
    sensor_id INT,
    timestamp TIMESTAMPTZ,
    value NUMERIC
);

-- B-Tree index: 10 GB for 1 billion rows
-- BRIN index:   10 MB for 1 billion rows! 🎉

-- Create BRIN index on timestamp
CREATE INDEX idx_timestamp ON sensor_data USING brin(timestamp);

-- Queries on time ranges are fast
SELECT * FROM sensor_data
WHERE timestamp BETWEEN '2025-11-01' AND '2025-11-30';
```

**BRIN Requirements:**
1. **Data must be naturally ordered** (e.g., INSERT always increasing timestamp)
2. **Very large table** (> 10 million rows)
3. **Range queries** (not equality)

**When NOT to Use:**
```sql
-- ❌ Random order insertion
INSERT INTO sensor_data VALUES (1, '2025-11-20', 100);
INSERT INTO sensor_data VALUES (2, '2025-11-19', 200);  -- Out of order!
-- BRIN becomes ineffective

-- ❌ Equality searches
SELECT * FROM sensor_data WHERE sensor_id = 12345;
-- Use B-Tree instead
```

**MySQL Equivalent:** None, but similar to partition pruning

---

## 🔍 7. Expression (Function-Based) Index

**MySQL:**
```sql
-- MySQL 8.0+
ALTER TABLE users ADD COLUMN email_lower VARCHAR(255) AS (LOWER(email)) VIRTUAL;
CREATE INDEX idx_email_lower ON users(email_lower);

SELECT * FROM users WHERE LOWER(email) = 'user@example.com';
```

**PostgreSQL:**
```sql
-- Create index on expression directly
CREATE INDEX idx_email_lower ON users(LOWER(email));

-- Query uses index
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';
```

**More Examples:**

```sql
-- Date extraction
CREATE INDEX idx_order_year ON orders(EXTRACT(YEAR FROM order_date));
SELECT * FROM orders WHERE EXTRACT(YEAR FROM order_date) = 2025;

-- Trim whitespace
CREATE INDEX idx_name_trimmed ON customers(TRIM(name));
SELECT * FROM customers WHERE TRIM(name) = 'John Smith';

-- Concatenation
CREATE INDEX idx_full_name ON users((first_name || ' ' || last_name));
SELECT * FROM users WHERE first_name || ' ' || last_name = 'John Smith';

-- JSON field extraction
CREATE INDEX idx_user_email ON orders((data->>'user_email'));
SELECT * FROM orders WHERE data->>'user_email' = 'user@test.com';
```

**Critical Rule:** Query must match index expression EXACTLY

```sql
-- Index
CREATE INDEX idx_email_lower ON users(LOWER(email));

-- ✅ Uses index
SELECT * FROM users WHERE LOWER(email) = 'test@test.com';

-- ❌ Does NOT use index (different function)
SELECT * FROM users WHERE email ILIKE 'test@test.com';

-- ❌ Does NOT use index (different expression)
SELECT * FROM users WHERE UPPER(email) = 'TEST@TEST.COM';
```

---

## 📋 8. Covering Index (INCLUDE)

**MySQL:**
```sql
-- Covering index includes all needed columns
CREATE INDEX idx_user_orders ON orders(user_id, order_date, total_amount);

-- Index-only scan (no table lookup)
SELECT order_date, total_amount 
FROM orders 
WHERE user_id = 123;
```

**PostgreSQL (Better Syntax):**
```sql
-- INCLUDE clause (PostgreSQL 11+)
CREATE INDEX idx_user_orders ON orders(user_id) INCLUDE (order_date, total_amount);

-- Advantages:
-- 1. Smaller index (included columns not searchable)
-- 2. Can include any type (even types not B-Tree indexable)
-- 3. Clearer intent

-- Index-only scan
SELECT order_date, total_amount 
FROM orders 
WHERE user_id = 123;
```

**Comparison:**

| MySQL Approach | PostgreSQL INCLUDE |
|---------------|-------------------|
| All columns in index key | Only search columns in key, others in INCLUDE |
| Larger index size | Smaller index |
| All columns must be B-Tree indexable | INCLUDE can have any type |

**Example: UUID with Metadata**

```sql
-- Without INCLUDE
CREATE INDEX idx_order_user_uuid ON orders(user_id, uuid, status, created_at);
-- Index size: 500 MB

-- With INCLUDE
CREATE INDEX idx_order_user_uuid ON orders(user_id) INCLUDE (uuid, status, created_at);
-- Index size: 300 MB (40% smaller!)

-- Same query performance
SELECT uuid, status, created_at FROM orders WHERE user_id = 123;
```

---

## 🎯 9. Partial Index (WHERE clause)

**MySQL:** Not supported

**PostgreSQL:** One of the most powerful features!

**Use Case:** Index only relevant rows

```sql
-- Index only active orders
CREATE INDEX idx_active_orders ON orders(created_at) WHERE status = 'active';

-- Much smaller index + faster queries for active orders
SELECT * FROM orders WHERE status = 'active' AND created_at > '2025-01-01';
```

**Real-World Examples:**

```sql
-- 1. Index only unread notifications
CREATE INDEX idx_unread_notifications ON notifications(user_id, created_at) 
WHERE read_at IS NULL;

-- Query
SELECT * FROM notifications 
WHERE user_id = 123 AND read_at IS NULL 
ORDER BY created_at DESC;

-- Index size: 100 MB (vs 1 GB for full index)
-- 90% of notifications are read, why index them?

-- 2. Index only pending payments
CREATE INDEX idx_pending_payments ON payments(user_id) 
WHERE status = 'pending';

-- Most payments are 'completed', we rarely query them

-- 3. Index only recent data
CREATE INDEX idx_recent_orders ON orders(customer_id, order_date)
WHERE order_date > '2024-01-01';

-- Old data rarely accessed, no need to index

-- 4. Index only non-deleted records (soft deletes)
CREATE INDEX idx_active_users ON users(email)
WHERE deleted_at IS NULL;
```

**Performance Impact:**

```sql
-- Full index
CREATE INDEX idx_orders_created ON orders(created_at);
-- Size: 1 GB, rows: 10 million

-- Partial index (only active)
CREATE INDEX idx_active_orders_created ON orders(created_at) 
WHERE status = 'active';
-- Size: 100 MB, rows: 1 million
-- 10x smaller index!
-- 10x faster inserts (less index to update)
-- Same speed for active order queries
```

---

## 🔧 10. Index Strategies by Query Pattern

### Equality Queries

```sql
-- Query
SELECT * FROM users WHERE email = 'user@example.com';

-- Index
CREATE INDEX idx_email ON users(email);
-- Type: B-Tree (default)
```

### Range Queries

```sql
-- Query
SELECT * FROM orders WHERE order_date BETWEEN '2025-11-01' AND '2025-11-30';

-- Small-Medium table
CREATE INDEX idx_order_date ON orders(order_date);
-- Type: B-Tree

-- Huge table with time-series data
CREATE INDEX idx_order_date ON orders USING brin(order_date);
-- Type: BRIN (much smaller)
```

### LIKE Queries

```sql
-- Left-anchored (ABC%)
SELECT * FROM products WHERE name LIKE 'Laptop%';
-- Index: CREATE INDEX idx_name ON products(name);
-- Type: B-Tree works ✅

-- Right-anchored (%ABC) or middle (%ABC%)
SELECT * FROM products WHERE name LIKE '%Laptop%';
-- Index: CREATE INDEX idx_name_trgm ON products USING gin(name gin_trgm_ops);
-- Type: GIN with pg_trgm extension ✅
-- Or: CREATE INDEX idx_name_fts ON products USING gin(to_tsvector('english', name));
```

### Case-Insensitive Search

```sql
-- Query
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';

-- Index
CREATE INDEX idx_email_lower ON users(LOWER(email));
-- Type: Expression index

-- Alternative: Use CITEXT type
CREATE TABLE users (
    email CITEXT  -- Case-insensitive text
);
CREATE INDEX idx_email ON users(email);
SELECT * FROM users WHERE email = 'USER@EXAMPLE.COM';  -- Works!
```

### JSON Queries

```sql
-- Query
SELECT * FROM products WHERE attributes @> '{"brand": "Apple"}';

-- Index
CREATE INDEX idx_attributes ON products USING gin(attributes);
-- Type: GIN

-- Specific key extraction
SELECT * FROM products WHERE attributes->>'brand' = 'Apple';
-- Index:
CREATE INDEX idx_brand ON products((attributes->>'brand'));
-- Type: Expression B-Tree (faster for single key)
```

### Array Membership

```sql
-- Query
SELECT * FROM articles WHERE tags @> ARRAY['postgresql'];

-- Index
CREATE INDEX idx_tags ON articles USING gin(tags);
-- Type: GIN
```

### Full-Text Search

```sql
-- Query
SELECT * FROM documents WHERE content @@ to_tsquery('postgresql & optimization');

-- Index
CREATE INDEX idx_content_fts ON documents USING gin(to_tsvector('english', content));
-- Type: GIN (read-heavy)

-- Or
CREATE INDEX idx_content_fts ON documents USING gist(to_tsvector('english', content));
-- Type: GiST (write-heavy)
```

---

## 📊 11. Monitoring & Maintenance

### Check Index Usage

```sql
-- PostgreSQL: See index scans
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan AS index_scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;

-- Find unused indexes
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
AND indexname NOT LIKE '%_pkey';  -- Exclude primary keys
```

**MySQL Equivalent:**
```sql
SELECT * FROM sys.schema_unused_indexes;
```

### Index Bloat

```sql
-- Check index bloat
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;

-- Rebuild bloated index (PostgreSQL 12+)
REINDEX INDEX CONCURRENTLY idx_name;

-- Or recreate
DROP INDEX CONCURRENTLY idx_name;
CREATE INDEX CONCURRENTLY idx_name ON table(column);
```

### VACUUM and Indexes

```sql
-- Update index statistics
ANALYZE table_name;

-- Vacuum to remove dead tuples
VACUUM table_name;

-- Aggressive cleanup
VACUUM FULL table_name;  -- Locks table!

-- Better: Regular autovacuum (enabled by default)
```

---

## 🎯 12. Index Strategy Decision Tree

```
Query Pattern
│
├─ Equality (=)
│  └─ B-Tree index (default)
│
├─ Range (<, >, BETWEEN)
│  ├─ Small-Medium table → B-Tree
│  └─ Huge time-series → BRIN
│
├─ LIKE 'ABC%'
│  └─ B-Tree index
│
├─ LIKE '%ABC%'
│  └─ GIN index with pg_trgm
│
├─ JSONB queries
│  ├─ Multiple keys → GIN on column
│  └─ Single key → Expression B-Tree on (column->>'key')
│
├─ Array contains
│  └─ GIN index
│
├─ Full-text search
│  ├─ Read-heavy → GIN
│  └─ Write-heavy → GiST
│
├─ Geospatial
│  └─ GiST index (PostGIS)
│
├─ Case-insensitive
│  ├─ Expression index on LOWER(column)
│  └─ Or use CITEXT type
│
└─ Need to exclude rows
   └─ Partial index with WHERE clause
```

---

## 💼 Interview Questions & Answers

### Q1: "What's the difference between GIN and GiST indexes?"

**Answer:**
> "Both are PostgreSQL's advanced index types for complex data, but with different trade-offs:
>
> **GIN (Generalized Inverted Index):**
> - Optimized for read-heavy workloads
> - Larger index size
> - Slower writes (index updates)
> - Better for: JSONB, arrays, full-text search on read-heavy tables
> - Example: Product catalog with JSONB attributes, searched frequently but updated rarely
>
> **GiST (Generalized Search Tree):**
> - Balanced read/write performance
> - Smaller index size
> - Faster writes
> - Lossy (may need recheck)
> - Better for: Geospatial data, range types, full-text on write-heavy tables
> - Example: Real-time sensor data with location queries
>
> Rule of thumb: Use GIN unless you have high write volume, then test GiST."

### Q2: "When would you use a BRIN index instead of B-Tree?"

**Answer:**
> "BRIN is ideal for huge tables with naturally ordered data—think time-series, logs, or sequential IDs. It stores min/max values per block range, making the index 1000x smaller than B-Tree.
>
> For example, with 1 billion sensor readings ordered by timestamp, a B-Tree index might be 10 GB, but BRIN is only 10 MB. Range queries like 'last month's data' are still fast because BRIN knows which blocks to scan.
>
> Key requirements:
> 1. Very large table (100M+ rows)
> 2. Data physically ordered (insertion order matches query order)
> 3. Range queries, not equality
>
> BRIN fails if data is randomly ordered. If you INSERT out-of-order timestamps, BRIN degrades to full table scan. Also, don't use for equality searches like 'sensor_id = 123'—B-Tree is better there."

### Q3: "How do PostgreSQL partial indexes differ from MySQL?"

**Answer:**
> "MySQL doesn't support partial indexes at all—this is a unique PostgreSQL feature that significantly improves performance.
>
> A partial index only indexes rows matching a WHERE condition. For example:
> ```sql
> CREATE INDEX idx_active_users ON users(email) WHERE deleted_at IS NULL;
> ```
>
> This indexes only active users. If 90% of users are deleted, the index is 10x smaller, inserts are 10x faster, and queries on active users are just as fast.
>
> Real-world use cases:
> - Soft deletes: Index only non-deleted records
> - Status filtering: Index only 'pending' orders
> - Time-based: Index only recent data
> - Boolean flags: Index only `is_active = true`
>
> In my previous project, we had a notifications table with 100M rows but only 5M unread. A partial index reduced index size from 2 GB to 100 MB and improved query performance by 3x while reducing write overhead."

### Q4: "Explain index-only scans and covering indexes in PostgreSQL."

**Answer:**
> "An index-only scan retrieves data entirely from the index without touching the table heap—much faster because it avoids disk I/O.
>
> PostgreSQL requires two things:
> 1. The index must include all columns in SELECT and WHERE
> 2. The visibility map shows rows are all-visible (no dead tuples)
>
> PostgreSQL 11+ introduced the INCLUDE clause for cleaner covering indexes:
> ```sql
> CREATE INDEX idx_user_orders 
> ON orders(user_id) 
> INCLUDE (order_date, total_amount);
> ```
>
> Advantages over MySQL's approach:
> - Smaller index (included columns aren't searchable, just stored)
> - Can include non-indexable types
> - Clearer intent in code
>
> Gotcha: If table hasn't been VACUUMed recently, PostgreSQL can't use index-only scan because it needs to check visibility in the table. Regular autovacuum solves this."

### Q5: "How do you identify and remove unused indexes?"

**Answer:**
> "I use pg_stat_user_indexes to find indexes with idx_scan = 0:
> ```sql
> SELECT schemaname, tablename, indexname, idx_scan
> FROM pg_stat_user_indexes
> WHERE idx_scan = 0
> AND indexname NOT LIKE '%_pkey'
> ORDER BY pg_relation_size(indexrelid) DESC;
> ```
>
> Before dropping, I check:
> 1. How long stats have been collected (pg_stat_reset_time)
> 2. Is it used for FOREIGN KEY constraints? (Still needed even if idx_scan=0)
> 3. Is it a UNIQUE constraint? (Can't drop without dropping constraint)
>
> Process:
> 1. Drop CONCURRENTLY to avoid locks:
>    ```sql
>    DROP INDEX CONCURRENTLY idx_unused;
>    ```
> 2. Monitor for a week for issues
> 3. If problems arise, recreate with CREATE INDEX CONCURRENTLY
>
> I also monitor index bloat and rebuild indexes >50% bloated:
> ```sql
> REINDEX INDEX CONCURRENTLY idx_bloated;
> ```
>
> In one project, we found 30% of indexes unused, removed them, and improved write performance by 20% while freeing 50 GB disk space."

---

## 📋 13. Common Indexing Mistakes

### Mistake 1: Over-Indexing

**Problem:**
```sql
CREATE INDEX idx1 ON orders(customer_id);
CREATE INDEX idx2 ON orders(order_date);
CREATE INDEX idx3 ON orders(status);
CREATE INDEX idx4 ON orders(customer_id, order_date);
CREATE INDEX idx5 ON orders(customer_id, status);
CREATE INDEX idx6 ON orders(customer_id, order_date, status);
-- 6 indexes!!! 🔥
```

**Impact:**
- Slower INSERTs (must update 6 indexes)
- Wasted disk space
- Confuses query planner

**Solution:**
```sql
-- Analyze actual query patterns
-- Keep only:
CREATE INDEX idx_customer_orders ON orders(customer_id, order_date) 
INCLUDE (status);
-- OR
CREATE INDEX idx_customer_status ON orders(customer_id, status);
-- One or two well-designed indexes > many poorly designed ones
```

### Mistake 2: Wrong Column Order

**Problem:**
```sql
-- Index: (order_date, customer_id)
CREATE INDEX idx_orders ON orders(order_date, customer_id);

-- Query searches by customer_id first
SELECT * FROM orders WHERE customer_id = 123 AND order_date > '2025-01-01';
-- Index not efficient! (customer_id is not left-most)
```

**Solution:**
```sql
-- Put most selective column first (usually foreign keys)
CREATE INDEX idx_orders ON orders(customer_id, order_date);
```

### Mistake 3: Not Using Expression Index

**Problem:**
```sql
-- Query
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';

-- Index (doesn't help!)
CREATE INDEX idx_email ON users(email);
```

**Solution:**
```sql
-- Expression index
CREATE INDEX idx_email_lower ON users(LOWER(email));
```

### Mistake 4: Missing INCLUDE for Index-Only Scans

**Problem:**
```sql
CREATE INDEX idx_orders ON orders(customer_id);

-- Query needs status too
SELECT customer_id, status FROM orders WHERE customer_id = 123;
-- PostgreSQL must look up table for status
```

**Solution:**
```sql
CREATE INDEX idx_orders ON orders(customer_id) INCLUDE (status);
-- Index-only scan! ✅
```

### Mistake 5: Not Using Partial Indexes

**Problem:**
```sql
-- Index all orders
CREATE INDEX idx_status ON orders(status);

-- But 95% are 'completed', rarely queried
```

**Solution:**
```sql
-- Index only active/pending
CREATE INDEX idx_active_orders ON orders(status) 
WHERE status IN ('pending', 'processing');
-- 20x smaller index!
```

---

## 🎯 14. Index Maintenance Checklist

**Daily/Automated:**
- ✅ Monitor autovacuum running
- ✅ Check for index bloat > 50%
- ✅ Alert on unused indexes (idx_scan = 0 for > 30 days)

**Weekly:**
- ✅ Review slow query log
- ✅ Check if new indexes needed
- ✅ Validate existing indexes used

**Monthly:**
- ✅ REINDEX bloated indexes CONCURRENTLY
- ✅ Drop confirmed unused indexes
- ✅ Review query patterns changed

**Quarterly:**
- ✅ Full index strategy review
- ✅ Test index removal in staging
- ✅ Benchmark critical queries

---

## 📚 Further Reading

**PostgreSQL Documentation:**
- [Index Types](https://www.postgresql.org/docs/current/indexes-types.html)
- [Indexes on Expressions](https://www.postgresql.org/docs/current/indexes-expressional.html)
- [Partial Indexes](https://www.postgresql.org/docs/current/indexes-partial.html)
- [Index-Only Scans](https://www.postgresql.org/docs/current/indexes-index-only-scans.html)

**Tools:**
- [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html) - Query statistics
- [pgBadger](https://github.com/darold/pgbadger) - Log analyzer
- [explain.depesz.com](https://explain.depesz.com/) - EXPLAIN plan visualizer

---

## ✅ Summary

**Key Differences from MySQL:**
1. ✅ **More index types**: GIN, GiST, BRIN, SP-GiST
2. ✅ **Partial indexes**: WHERE clause to index subset
3. ✅ **INCLUDE clause**: Cleaner covering indexes
4. ✅ **Expression indexes**: No need for generated columns
5. ✅ **Better for JSONB**: Native GIN support
6. ✅ **BRIN for big data**: 1000x smaller indexes

**Production Best Practices:**
- Start with B-Tree (default)
- Use GIN for JSONB/arrays
- Use BRIN for time-series > 100M rows
- Add partial indexes for filtered queries
- Monitor with pg_stat_user_indexes
- Rebuild bloated indexes CONCURRENTLY
- Drop unused indexes to improve writes

**Interview Readiness:**
- ✅ Explain GIN vs GiST trade-offs
- ✅ Demonstrate partial index use cases
- ✅ Calculate index size savings with BRIN
- ✅ Describe index-only scan requirements
- ✅ Show expression index examples

You're now ready to design PostgreSQL indexes like a senior DBA! 🚀
