# Scenario 03: Read-Only Enforcement - Execution Log

**Date**: November 16, 2025  
**Time Started**: 10:05 UTC  
**Status**: ✅ COMPLETED  
**Duration**: 10 minutes

---

## 🎯 Learning Objective

Understand exactly what operations are allowed and prohibited on a hot standby server.

---

## ✅ Step 1: Verify Recovery Mode (COMPLETED)

**Command**:
```sql
SELECT pg_is_in_recovery() as is_standby;
```

**Result**:
```
is_standby = t (true)
Mode: READ-ONLY
```

**✅ Confirmed**: Standby is in recovery mode

---

## ✅ Step 2: Test SELECT Operations (COMPLETED)

### Test 1: Simple SELECT
```sql
SELECT COUNT(*) as total_users FROM users;
```
**Result**: ✅ Success - 5 users

### Test 2: Aggregate with GROUP BY
```sql
SELECT category, COUNT(*), AVG(price) 
FROM products 
GROUP BY category;
```
**Result**: ✅ Success
```
Electronics: 2,001 products, avg $500.82
Sports:      2,000 products, avg $506.02
Home:        2,000 products, avg $506.65
```

**Conclusion**: All SELECT operations work perfectly!

---

## ✅ Step 3: Test Write Operations (COMPLETED)

### ❌ Test 1: INSERT
```sql
INSERT INTO users (username, email) VALUES ('test_user', 'test@test.com');
```
**Result**: 
```
ERROR: cannot execute INSERT in a read-only transaction
```

### ❌ Test 2: UPDATE
```sql
UPDATE products SET price = 999.99 WHERE id = 1;
```
**Result**:
```
ERROR: cannot execute UPDATE in a read-only transaction
```

### ❌ Test 3: DELETE
```sql
DELETE FROM products WHERE id = 1;
```
**Result**:
```
ERROR: cannot execute DELETE in a read-only transaction
```

### ❌ Test 4: CREATE TABLE
```sql
CREATE TABLE test_table (id INT, name VARCHAR(50));
```
**Result**:
```
ERROR: cannot execute CREATE TABLE in a read-only transaction
```

**Conclusion**: All write operations properly rejected!

---

## ✅ Step 4: Test Temporary Tables (COMPLETED)

### ❌ Test: CREATE TEMP TABLE
```sql
CREATE TEMP TABLE temp_analysis (category VARCHAR(50), total INT);
```
**Result**:
```
ERROR: cannot execute CREATE TABLE in a read-only transaction
```

**Important Discovery**: Even TEMPORARY tables are not allowed on standby!

**Why?** 
- Standby is in strict read-only recovery mode
- Any catalog changes (even temp tables) are prohibited
- This ensures standby can replay WAL without conflicts

---

## ✅ Step 5: Test Read-Only Functions (COMPLETED)

### ✅ Test 1: Built-in Functions
```sql
SELECT NOW(), VERSION(), pg_database_size('postgres');
```
**Result**: ✅ Success
```
NOW():     2025-11-16 10:09:16.178567+00
VERSION(): PostgreSQL 15.15 (Debian...)
DB Size:   17,380,143 bytes (~17 MB)
```

### ✅ Test 2: String Functions
```sql
SELECT UPPER('hello'), LOWER('WORLD'), LENGTH('test');
```
**Result**: ✅ Success
```
UPPER:  HELLO
LOWER:  world
LENGTH: 4
```

**Conclusion**: Read-only functions work perfectly!

---

## ✅ Step 6: Test EXPLAIN (COMPLETED)

### ✅ Test: Query Planning
```sql
EXPLAIN SELECT * FROM products 
WHERE category = 'Electronics' AND price > 500;
```
**Result**: ✅ Success
```
Seq Scan on products (cost=0.00..277.00 rows=1005)
Filter: price > 500 AND category = 'Electronics'
```

**Key Learning**: EXPLAIN works on standby - great for query optimization testing!

---

## ✅ Step 7: Test Maintenance Operations (COMPLETED)

### ❌ Test 1: TRUNCATE
```sql
TRUNCATE TABLE products;
```
**Result**:
```
ERROR: cannot execute TRUNCATE TABLE in a read-only transaction
```

### ❌ Test 2: VACUUM
```sql
VACUUM products;
```
**Result**:
```
ERROR: cannot execute VACUUM during recovery
```

**Why VACUUM fails**: 
- VACUUM modifies system catalogs and pages
- Standby must remain unchanged except for WAL replay
- VACUUM on primary is sufficient (changes replicate)

---

## 📊 Complete Operation Matrix

| Operation | Standby | Primary | Notes |
|-----------|---------|---------|-------|
| **SELECT** | ✅ Yes | ✅ Yes | All read queries work |
| **INSERT** | ❌ No | ✅ Yes | Read-only transaction error |
| **UPDATE** | ❌ No | ✅ Yes | Read-only transaction error |
| **DELETE** | ❌ No | ✅ Yes | Read-only transaction error |
| **CREATE TABLE** | ❌ No | ✅ Yes | Cannot modify catalog |
| **CREATE TEMP TABLE** | ❌ No | ✅ Yes | Even temp tables rejected! |
| **DROP TABLE** | ❌ No | ✅ Yes | Cannot modify catalog |
| **CREATE INDEX** | ❌ No | ✅ Yes | Cannot modify catalog |
| **TRUNCATE** | ❌ No | ✅ Yes | Read-only transaction error |
| **VACUUM** | ❌ No | ✅ Yes | Cannot run during recovery |
| **EXPLAIN** | ✅ Yes | ✅ Yes | Query planning allowed |
| **Built-in Functions** | ✅ Yes | ✅ Yes | Read-only functions work |
| **Views** | ✅ Read | ✅ Read/Write | Can read existing views |
| **Transactions (BEGIN)** | ✅ Read-only | ✅ Read/Write | Only read transactions |

---

## 🎓 Key Learnings

### 1. **Standby is STRICTLY Read-Only**
- Cannot modify ANY data
- Cannot modify ANY catalog (tables, indexes, etc.)
- Cannot even create temporary tables
- Protection against accidental writes

### 2. **All SELECT Operations Work**
- Simple queries ✓
- Complex JOINs ✓
- Aggregations ✓
- Subqueries ✓
- CTEs (Common Table Expressions) ✓

### 3. **Read-Only Functions Work**
- Built-in functions (NOW, VERSION, etc.) ✓
- String manipulation ✓
- Math functions ✓
- Date/time functions ✓
- System information functions ✓

### 4. **Query Planning Works**
- EXPLAIN for performance analysis ✓
- EXPLAIN ANALYZE (read-only queries) ✓
- Great for testing query performance

### 5. **No Maintenance Operations**
- Cannot VACUUM (done on primary)
- Cannot ANALYZE (done on primary)
- Cannot REINDEX (done on primary)
- All maintenance on primary replicates

---

## 💡 Practical Implications

### For Application Development:

✅ **DO** on Standby:
- Product searches
- Order history lookups
- Analytics queries
- Report generation
- Dashboard queries
- Read-heavy operations
- Query performance testing

❌ **DON'T** on Standby:
- Any INSERT/UPDATE/DELETE
- Creating tables or indexes
- User registration (writes needed)
- Order placement (writes needed)
- Profile updates (writes needed)
- Any data modification

### For Database Administration:

✅ **DO** on Standby:
- Monitor query performance (EXPLAIN)
- Test read query optimization
- Validate replication lag
- Check data consistency
- Run read-only reports

❌ **DON'T** on Standby:
- Run VACUUM or ANALYZE
- Create indexes
- Perform schema changes
- Run maintenance tasks
- (All maintenance on primary!)

---

## 🔍 Error Messages Reference

| Error Message | Meaning | Solution |
|---------------|---------|----------|
| `cannot execute INSERT in a read-only transaction` | Tried to modify data | Use primary server |
| `cannot execute CREATE TABLE in a read-only transaction` | Tried to modify catalog | Use primary server |
| `cannot execute VACUUM during recovery` | Tried maintenance operation | Run on primary (will replicate) |
| `cannot execute <operation> in a read-only transaction` | Generic write attempt | Route to primary |

---

## 🎯 Testing Checklist

- [x] Verified standby is in recovery mode
- [x] Confirmed SELECT queries work
- [x] Confirmed INSERT fails
- [x] Confirmed UPDATE fails
- [x] Confirmed DELETE fails
- [x] Confirmed CREATE TABLE fails
- [x] Confirmed temporary tables fail
- [x] Confirmed read-only functions work
- [x] Confirmed EXPLAIN works
- [x] Confirmed TRUNCATE fails
- [x] Confirmed VACUUM fails

---

## 🚀 What This Means for You

1. **Safe Read Scaling**: Standby cannot accidentally corrupt data
2. **Application Routing**: Must separate read and write connections
3. **Error Handling**: Applications must handle read-only errors gracefully
4. **Testing**: Can safely test read queries on standby without risk
5. **Maintenance**: All maintenance on primary, automatically replicates

---

## ✅ SCENARIO 03 COMPLETE! 🎉

**Status**: Successfully completed  
**Key Achievement**: Fully understand standby capabilities and limitations

**What's Next**: Scenario 04 - Manual Failover (promoting standby to primary)

---

**Your Progress**: 3/10 scenarios complete (30%) ⭐⭐⭐
