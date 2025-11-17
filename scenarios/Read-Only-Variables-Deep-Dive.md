# PostgreSQL Read-Only Variables: What Happens If You Change Them?

**Question:** What if `default_transaction_read_only` is disabled on a standby?  
**Answer:** **NOTHING! Recovery mode overrides ALL settings!**

---

## 🎯 Key Concept: Recovery Mode is the ULTIMATE Protection

PostgreSQL has **multiple layers** of read-only protection, but **recovery mode is supreme**.

### Hierarchy of Protection (from strongest to weakest):

```
1. Recovery Mode (pg_is_in_recovery = true)  ← STRONGEST, CANNOT BE BYPASSED
   ↓
2. hot_standby setting
   ↓
3. default_transaction_read_only setting     ← WEAKEST, easily changed
```

---

## 📊 The Three Read-Only Variables Explained

### 1. Recovery Mode (`pg_is_in_recovery()`)

**What it is:**
- Internal PostgreSQL state
- Server is **replaying WAL** from primary
- **NOT a configurable setting** - it's a mode

**How to check:**
```sql
SELECT pg_is_in_recovery();
-- Returns: 't' (true)  = Standby (read-only)
--          'f' (false) = Primary (writable)
```

**Effect when TRUE (standby):**
```sql
INSERT INTO products (name) VALUES ('test');
-- Result: ERROR: cannot execute INSERT in a read-only transaction

UPDATE products SET price = 100;
-- Result: ERROR: cannot execute UPDATE in a read-only transaction

DELETE FROM products;
-- Result: ERROR: cannot execute DELETE in a read-only transaction

CREATE TEMP TABLE test (id int);
-- Result: ERROR: cannot execute CREATE TABLE in a read-only transaction

-- EVERYTHING is blocked! Even:
TRUNCATE products;  -- ERROR
COPY products FROM stdin;  -- ERROR
ALTER TABLE products ADD COLUMN x int;  -- ERROR
```

**How to change it:**
```sql
-- The ONLY way to exit recovery mode:
SELECT pg_promote();

-- This converts standby → primary
-- After promotion: pg_is_in_recovery() returns 'f'
-- Now writes are allowed
```

**Can you bypass it?** 
- ❌ **ABSOLUTELY NOT!**
- No configuration can override recovery mode
- It's PostgreSQL's **core replication protection**

**MySQL equivalent:**
- Closest: `read_only = 1` + `super_read_only = 1`
- But MySQL has NO equivalent to recovery mode
- MySQL replica can be made writable easily

---

### 2. `hot_standby` Setting

**What it is:**
- Configuration parameter
- Controls if standby accepts **read queries**
- Does NOT control write protection (recovery mode does that)

**Default value:** `on` (in modern PostgreSQL)

**How to check:**
```sql
SHOW hot_standby;
-- Returns: 'on' or 'off'
```

**Effect of `hot_standby = on` (default):**
```sql
-- Read queries work:
SELECT * FROM products;  -- SUCCESS ✓
SELECT count(*) FROM orders;  -- SUCCESS ✓

-- Write queries still blocked by recovery mode:
INSERT INTO products VALUES (...);  -- ERROR ✗
```

**Effect of `hot_standby = off`:**
```sql
-- ALL queries blocked (even reads):
SELECT * FROM products;  
-- ERROR: cannot execute query during recovery
```

**When to use `hot_standby = off`:**
- Never! Unless you don't want standby to serve reads
- Wastes standby resources
- Used in old PostgreSQL versions (< 9.0) when hot standby didn't exist

**Can you enable writes with `hot_standby = on`?**
- ❌ **NO!** 
- `hot_standby` only controls READS
- Writes are blocked by recovery mode (cannot be bypassed)

**MySQL equivalent:**
- No direct equivalent
- MySQL replica always accepts connections
- Control via `read_only` setting

---

### 3. `default_transaction_read_only` Setting

**What it is:**
- Session-level default
- Sets whether transactions default to read-only
- **Weakest protection** (easily overridden)

**Default value:** `off`

**How to check:**
```sql
SHOW default_transaction_read_only;
-- Returns: 'on' or 'off'
```

**Effect of `default_transaction_read_only = on`:**
```sql
-- On a PRIMARY (not standby):
BEGIN;
INSERT INTO products VALUES (...);
-- ERROR: cannot execute INSERT in a read-only transaction

-- But can be easily bypassed:
BEGIN READ WRITE;  -- Override the default
INSERT INTO products VALUES (...);  -- SUCCESS!
COMMIT;
```

**Effect of `default_transaction_read_only = off` (default):**
```sql
-- Transactions are read-write by default
BEGIN;
INSERT INTO products VALUES (...);  -- SUCCESS (on primary)
```

**On a STANDBY (recovery mode), this setting is IGNORED:**
```sql
-- Even with default_transaction_read_only = off:
INSERT INTO products VALUES (...);
-- ERROR: cannot execute INSERT in a read-only transaction

-- Recovery mode overrides everything!
```

**Can you enable writes on standby with this?**
- ❌ **NO!** 
- Recovery mode overrides this setting completely
- This setting only works on PRIMARY servers

**MySQL equivalent:**
```sql
-- Closest equivalent:
SET GLOBAL read_only = 1;  -- Similar effect

-- But MySQL allows SUPER users to write even with read_only=1
-- Must use:
SET GLOBAL super_read_only = 1;  -- Block even SUPER users
```

---

## 🧪 Live Testing: What Happens on a Standby?

### Test 1: Default Settings (Recovery Mode)

```sql
-- Standby status:
SELECT pg_is_in_recovery();
-- Result: t (true) - in recovery mode

SHOW hot_standby;
-- Result: on

SHOW default_transaction_read_only;
-- Result: off

-- Try to write:
INSERT INTO products (name) VALUES ('test');
-- Result: ERROR: cannot execute INSERT in a read-only transaction
```

**Conclusion:** Recovery mode blocks writes, regardless of settings ✓

---

### Test 2: Enable `default_transaction_read_only = on`

```sql
-- On standby:
ALTER SYSTEM SET default_transaction_read_only = on;
SELECT pg_reload_conf();

SHOW default_transaction_read_only;
-- Result: on

-- Try to write:
INSERT INTO products (name) VALUES ('test');
-- Result: ERROR: cannot execute INSERT in a read-only transaction
```

**Conclusion:** No difference! Recovery mode still blocks writes ✓

---

### Test 3: Disable `default_transaction_read_only = off`

```sql
-- On standby:
ALTER SYSTEM SET default_transaction_read_only = off;
SELECT pg_reload_conf();

SHOW default_transaction_read_only;
-- Result: off

-- Try to write:
INSERT INTO products (name) VALUES ('test');
-- Result: ERROR: cannot execute INSERT in a read-only transaction
```

**Conclusion:** Still no writes! Recovery mode cannot be bypassed ✓

---

### Test 4: What About `hot_standby = off`?

```sql
-- On standby:
ALTER SYSTEM SET hot_standby = off;
-- Requires restart

-- After restart:
SELECT * FROM products;
-- Result: ERROR: cannot execute query during recovery

-- Writes still blocked:
INSERT INTO products (name) VALUES ('test');
-- Result: ERROR: cannot execute query during recovery
```

**Conclusion:** `hot_standby = off` blocks EVERYTHING (reads + writes) ✓

---

## 🔍 Complete Truth Table

| Setting | Recovery | hot_standby | default_tx_ro | Reads Allowed? | Writes Allowed? |
|---------|----------|-------------|---------------|----------------|-----------------|
| **Standby** | ✓ (true) | on | off | ✅ YES | ❌ NO |
| **Standby** | ✓ (true) | on | on | ✅ YES | ❌ NO |
| **Standby** | ✓ (true) | off | off | ❌ NO | ❌ NO |
| **Standby** | ✓ (true) | off | on | ❌ NO | ❌ NO |
| **Primary** | ✗ (false) | on | off | ✅ YES | ✅ YES |
| **Primary** | ✗ (false) | on | on | ✅ YES | ⚠️ NO (by default) |
| **Primary** | ✗ (false) | off | off | ✅ YES | ✅ YES |
| **Primary** | ✗ (false) | off | on | ✅ YES | ⚠️ NO (by default) |

**Key takeaway:** On standby (recovery = true), **writes ALWAYS blocked**, regardless of other settings!

---

## 🚨 So Why Do These Settings Exist?

### Purpose of `default_transaction_read_only`:

**Use case:** Run a PRIMARY in read-only mode temporarily

```sql
-- On PRIMARY (not standby):
ALTER SYSTEM SET default_transaction_read_only = on;
SELECT pg_reload_conf();

-- Now primary only accepts reads (useful for maintenance)
SELECT * FROM products;  -- SUCCESS
INSERT INTO products VALUES (...);  -- ERROR

-- Users can still override if needed:
BEGIN READ WRITE;
INSERT INTO products VALUES (...);  -- SUCCESS
COMMIT;
```

**Real-world scenario:**
- Maintenance window
- Migration preparation
- Testing disaster recovery
- Preventing accidental writes during audit

**NOT for standby protection!** (recovery mode handles that)

---

### Purpose of `hot_standby`:

**Use case:** Disable standby queries to reduce load

```sql
-- Standby is replaying heavy write load
-- Read queries slow down WAL replay
-- Solution: Disable hot_standby temporarily

ALTER SYSTEM SET hot_standby = off;
-- Restart required

-- Now standby focuses only on replication
-- No query load, faster catch-up
```

**Real-world scenario:**
- Standby lagging behind (high write load)
- Want faster WAL replay
- Don't need read queries temporarily

**NOT for write protection!** (recovery mode handles that)

---

## 💡 MySQL vs PostgreSQL: Read-Only Protection

| Aspect | PostgreSQL Standby | MySQL Replica |
|--------|-------------------|---------------|
| **Default state** | Read-only (recovery mode) | **WRITABLE!** (if not configured) |
| **Protection mechanism** | Recovery mode (cannot bypass) | `read_only = 1` (can bypass) |
| **Can SUPER user write?** | ❌ NO (recovery mode blocks all) | ✅ YES (unless `super_read_only = 1`) |
| **Can be bypassed?** | ❌ NO (must promote to primary) | ✅ YES (disable `read_only`) |
| **Configuration required?** | ✅ NO (automatic) | ⚠️ YES (must set `read_only = 1`) |
| **Additional settings** | `hot_standby`, `default_transaction_read_only` | `read_only`, `super_read_only` |

**Bottom line:** PostgreSQL standby is **MORE SECURE** than MySQL replica!

---

## 🎯 Practical Recommendations

### For Production Standbys:

```ini
# postgresql.conf
hot_standby = on                        # Allow read queries ✅
default_transaction_read_only = off     # No effect on standby, leave default ✅
wal_log_hints = on                      # Enable for pg_rewind ✅
```

**Why `default_transaction_read_only = off` is OK:**
- Recovery mode provides ALL write protection
- Changing this setting does NOTHING on standby
- Save it for PRIMARY read-only mode scenarios

---

### For MySQL DBAs Migrating to PostgreSQL:

**Old MySQL habit (REQUIRED in MySQL):**
```ini
# my.cnf (MySQL replica)
read_only = 1              # Required!
super_read_only = 1        # Required to block SUPER users!
```

**New PostgreSQL habit (NOT needed):**
```ini
# postgresql.conf (PostgreSQL standby)
# No special config needed!
# Recovery mode handles everything automatically ✅
hot_standby = on          # Just enable read queries
```

**Mental shift:**
- MySQL: Must configure read-only protection manually
- PostgreSQL: Read-only protection is built-in (recovery mode)

---

### When to Use Each Setting:

| Setting | Use On | Purpose |
|---------|--------|---------|
| **Recovery mode** | Standby | Automatic write protection ✅ |
| **hot_standby = on** | Standby | Enable read queries ✅ |
| **hot_standby = off** | Standby | Disable queries (rare, for fast catch-up) |
| **default_transaction_read_only = on** | Primary | Temporary read-only mode for maintenance |
| **default_transaction_read_only = off** | Primary | Default (normal operation) |

---

## 🔥 Common Misconceptions

### Myth 1: "Need to set `default_transaction_read_only = on` on standby"
**Reality:** ❌ Unnecessary! Recovery mode already blocks writes.

### Myth 2: "Can enable writes by changing config"
**Reality:** ❌ Impossible! Must promote standby to primary (`pg_promote()`).

### Myth 3: "SUPERUSER can write to standby"
**Reality:** ❌ No one can write to standby, not even postgres user!

### Myth 4: "hot_standby = on enables writes"
**Reality:** ❌ Only enables READ queries, not writes!

### Myth 5: "PostgreSQL and MySQL read-only work the same"
**Reality:** ❌ PostgreSQL is STRONGER (recovery mode vs read_only setting)!

---

## 🎓 Summary: The Answer to Your Question

**Question:** "What if `default_transaction_read_only` variable is enabled/disabled on standby?"

**Answer:** 
- ✅ **NOTHING happens!** 
- Recovery mode **overrides** all read-only settings
- Standby remains **strictly read-only** regardless of configuration
- You **CANNOT bypass** recovery mode protection
- The only way to enable writes: **promote standby to primary**

**Key insight for MySQL DBAs:**
- MySQL: Must configure `read_only = 1` (manually)
- PostgreSQL: Recovery mode handles it (automatically)
- PostgreSQL is **MORE SECURE** by design!

---

## 📝 Quick Reference Commands

```sql
-- Check if server is standby:
SELECT pg_is_in_recovery();

-- Check read-only settings:
SHOW hot_standby;
SHOW default_transaction_read_only;

-- Promote standby to primary (ONLY way to enable writes):
SELECT pg_promote();

-- Put primary in read-only mode temporarily:
ALTER SYSTEM SET default_transaction_read_only = on;
SELECT pg_reload_conf();

-- Restore primary to writable:
ALTER SYSTEM SET default_transaction_read_only = off;
SELECT pg_reload_conf();
```

---

*Document created: November 16, 2025*  
*Purpose: Explain read-only variable behavior on PostgreSQL standby*  
*For: MySQL DBAs learning PostgreSQL replication protection mechanisms*
