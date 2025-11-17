# Scenario 03: Read-Only Enforcement - Testing Standby Limitations

**Difficulty:** Beginner  
**Duration:** 15-20 minutes  
**Prerequisites:** Scenarios 01-02 completed

## 🎯 Learning Objectives

By completing this scenario, you will:
- Understand what operations are allowed on standby
- Learn which operations are prohibited and why
- Explore the boundaries of hot standby mode
- Understand temporary tables and functions on standby
- Learn about read-only transaction context

## 📚 Background

A standby server in **hot standby mode** allows:
- ✅ SELECT queries (all types)
- ✅ Reading from views
- ✅ Executing read-only functions
- ✅ EXPLAIN plans
- ✅ Temporary tables (session-specific)

But prohibits:
- ❌ INSERT, UPDATE, DELETE
- ❌ CREATE TABLE (permanent)
- ❌ DROP TABLE
- ❌ CREATE INDEX
- ❌ TRUNCATE
- ❌ VACUUM
- ❌ Any DDL that modifies database

---

## Step 1: Verify Standby is in Recovery Mode

```bash
docker exec -it postgres-standby psql -U postgres << 'EOF'
SELECT 
    pg_is_in_recovery() as is_standby,
    CASE 
        WHEN pg_is_in_recovery() THEN 'READ-ONLY MODE'
        ELSE 'READ-WRITE MODE'
    END as mode;
EOF
```

**Expected:** `is_standby = t`, `mode = READ-ONLY MODE`

---

## Step 2: Test Basic SELECT Operations (Should Work)

```bash
echo "✅ Testing SELECT operations..."

docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Simple SELECT
SELECT COUNT(*) FROM users;

-- Complex SELECT with JOIN
SELECT u.username, COUNT(o.id) as order_count
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
GROUP BY u.username
ORDER BY order_count DESC
LIMIT 5;

-- Aggregate functions
SELECT 
    COUNT(*) as total_users,
    MIN(created_at) as first_user,
    MAX(created_at) as last_user
FROM users;

\echo '✅ All SELECT operations successful!'
EOF
```

---

## Step 3: Test INSERT (Should Fail)

```bash
echo "❌ Testing INSERT (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to insert
INSERT INTO users (username, email) 
VALUES ('test_insert', 'test@fail.com');
EOF
```

**Expected Error:**
```
ERROR:  cannot execute INSERT in a read-only transaction
```

---

## Step 4: Test UPDATE (Should Fail)

```bash
echo "❌ Testing UPDATE (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to update
UPDATE users 
SET email = 'updated@fail.com' 
WHERE username = 'alice';
EOF
```

**Expected Error:**
```
ERROR:  cannot execute UPDATE in a read-only transaction
```

---

## Step 5: Test DELETE (Should Fail)

```bash
echo "❌ Testing DELETE (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to delete
DELETE FROM users WHERE id = 1;
EOF
```

**Expected Error:**
```
ERROR:  cannot execute DELETE in a read-only transaction
```

---

## Step 6: Test CREATE TABLE (Should Fail)

```bash
echo "❌ Testing CREATE TABLE (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to create permanent table
CREATE TABLE test_table (
    id SERIAL PRIMARY KEY,
    data TEXT
);
EOF
```

**Expected Error:**
```
ERROR:  cannot execute CREATE TABLE in a read-only transaction
```

---

## Step 7: Test TEMPORARY Tables (Should Work!)

```bash
echo "✅ Testing TEMPORARY tables (should work)..."

docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Create temporary table (session-specific, not replicated)
CREATE TEMPORARY TABLE temp_calculations (
    id SERIAL PRIMARY KEY,
    calculation_result NUMERIC
);

-- Insert into temp table
INSERT INTO temp_calculations (calculation_result)
SELECT random() * 1000 FROM generate_series(1, 10);

-- Query temp table
SELECT COUNT(*), AVG(calculation_result) 
FROM temp_calculations;

\echo '✅ Temporary tables work on standby!'
EOF
```

**Why this works:**
- Temporary tables exist only in session memory
- Not written to WAL or disk permanently
- Don't affect replication

---

## Step 8: Test CREATE INDEX (Should Fail)

```bash
echo "❌ Testing CREATE INDEX (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to create index
CREATE INDEX idx_users_email ON users(email);
EOF
```

**Expected Error:**
```
ERROR:  cannot execute CREATE INDEX in a read-only transaction
```

---

## Step 9: Test TRUNCATE (Should Fail)

```bash
echo "❌ Testing TRUNCATE (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to truncate
TRUNCATE TABLE orders;
EOF
```

**Expected Error:**
```
ERROR:  cannot execute TRUNCATE TABLE in a read-only transaction
```

---

## Step 10: Test DROP TABLE (Should Fail)

```bash
echo "❌ Testing DROP TABLE (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to drop table
DROP TABLE IF EXISTS users;
EOF
```

**Expected Error:**
```
ERROR:  cannot execute DROP TABLE in a read-only transaction
```

---

## Step 11: Test VACUUM (Should Fail)

```bash
echo "❌ Testing VACUUM (should fail)..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Try to vacuum
VACUUM users;
EOF
```

**Expected Error:**
```
ERROR:  cannot execute VACUUM in a read-only transaction
```

---

## Step 12: Test Functions and Procedures

### Read-Only Function (Should Work)
```bash
echo "✅ Testing read-only function..."

docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Create function that only reads
CREATE OR REPLACE FUNCTION get_user_count()
RETURNS INTEGER AS $$
BEGIN
    RETURN (SELECT COUNT(*) FROM users);
END;
$$ LANGUAGE plpgsql;

-- Execute it
SELECT get_user_count();

\echo '✅ Read-only function works!'
EOF
```

### Function with Write Operations (Should Fail)
```bash
echo "❌ Testing write function..."

docker exec -it postgres-standby psql -U postgres << 'EOF' 2>&1 | head -20
-- Create function (this works)
CREATE OR REPLACE FUNCTION try_insert_user()
RETURNS VOID AS $$
BEGIN
    INSERT INTO users (username, email) VALUES ('func_test', 'func@test.com');
END;
$$ LANGUAGE plpgsql;

-- Execute it (this fails!)
SELECT try_insert_user();
EOF
```

**Expected:** Function creation succeeds, but execution fails

---

## Step 13: Test Views (Should Work)

```bash
echo "✅ Testing views..."

docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Create view (definition replicated from primary)
-- Query existing views
SELECT * FROM pg_views WHERE schemaname = 'public' LIMIT 5;

-- Create temporary view (should work)
CREATE TEMPORARY VIEW temp_user_summary AS
SELECT 
    COUNT(*) as total,
    MAX(created_at) as latest
FROM users;

SELECT * FROM temp_user_summary;

\echo '✅ Views work on standby!'
EOF
```

---

## Step 14: Test EXPLAIN (Should Work)

```bash
echo "✅ Testing EXPLAIN..."

docker exec -it postgres-standby psql -U postgres << 'EOF'
-- EXPLAIN plans work (read-only)
EXPLAIN ANALYZE
SELECT u.username, COUNT(o.id)
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
GROUP BY u.username;

\echo '✅ EXPLAIN works on standby!'
EOF
```

---

## Step 15: Test Transaction Behavior

```bash
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Start transaction
BEGIN;

-- Read operations work
SELECT COUNT(*) FROM users;

-- Write operation fails
INSERT INTO users (username, email) VALUES ('tx_test', 'tx@test.com');

-- Transaction automatically rolled back
COMMIT;  -- This will show error

\echo 'Transaction behavior demonstrated'
EOF
```

---

## 🎓 Knowledge Check

1. **Can you create temporary tables on standby?**
   - [x] Yes, they're session-specific
   - [ ] No, all writes are blocked
   - [ ] Only after promoting to primary
   - [ ] Only with special permissions

2. **What happens if you try to INSERT on standby?**
   - [ ] Data is queued for later
   - [x] Immediate error: read-only transaction
   - [ ] Silent failure
   - [ ] Waits for promotion

3. **Can you run EXPLAIN ANALYZE on standby?**
   - [x] Yes, it's a read-only operation
   - [ ] No, it modifies statistics
   - [ ] Only EXPLAIN, not ANALYZE
   - [ ] Only with special flag

4. **What DDL operations are allowed on standby?**
   - [ ] CREATE TABLE
   - [ ] CREATE INDEX
   - [x] CREATE TEMPORARY TABLE
   - [ ] ALTER TABLE

---

## 📊 Results Summary

| Operation | Allowed on Standby? | Reason |
|-----------|-------------------|---------|
| SELECT | ✅ Yes | Read-only |
| INSERT/UPDATE/DELETE | ❌ No | Modifies data |
| CREATE TABLE | ❌ No | Persistent DDL |
| CREATE TEMP TABLE | ✅ Yes | Session-only |
| CREATE INDEX | ❌ No | Modifies structure |
| TRUNCATE | ❌ No | Modifies data |
| DROP TABLE | ❌ No | Modifies structure |
| VACUUM | ❌ No | Maintenance operation |
| EXPLAIN | ✅ Yes | Read-only analysis |
| Functions (read-only) | ✅ Yes | No modifications |
| Functions (writes) | ❌ No | Would modify data |
| Views (query) | ✅ Yes | Read-only |
| CREATE TEMP VIEW | ✅ Yes | Session-only |

---

## 🧪 Experiment: Session Isolation

```bash
# Terminal 1: Create temp table in session 1
docker exec -it postgres-standby psql -U postgres << 'EOF'
CREATE TEMPORARY TABLE session1_temp (data TEXT);
INSERT INTO session1_temp VALUES ('Session 1 data');
SELECT * FROM session1_temp;
EOF

# Terminal 2: Try to access from session 2
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- This will fail - temp tables are session-specific
SELECT * FROM session1_temp;
EOF
```

**Learning:** Temporary objects are isolated per connection

---

## 🎯 Key Takeaways

✅ **Standby = Read-Only** for all permanent changes  
✅ **Temporary objects allowed** (session-specific, not replicated)  
✅ **All SELECT operations work** without restrictions  
✅ **EXPLAIN/ANALYZE work** (analysis is read-only)  
✅ **Error messages are immediate** and clear  
✅ **No risk of accidental writes** on standby  

**Best Practices:**
- Use standby for reporting/analytics
- Temporary tables OK for intermediate calculations
- Always handle read-only errors in application code
- Consider connection pooling to separate read/write pools

---

## 📝 What You Learned

- [x] Which operations work on standby
- [x] Which operations fail and why
- [x] Temporary vs permanent objects
- [x] Transaction behavior in read-only mode
- [x] Error handling for read-only transactions
- [x] Session isolation concepts

---

## ➡️ Next Scenario

**[Scenario 04: Manual Failover](./04-manual-failover.md)**

Now that you understand standby limitations, learn how to promote it to a full read-write primary!

```bash
cat scenarios/04-manual-failover.md
```
