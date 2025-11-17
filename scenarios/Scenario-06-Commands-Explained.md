# Scenario 06: PostgreSQL Commands Explained

**Quick Reference Guide for Heavy Write Load Test**

---

## 🔍 Command 1: Generate Heavy Write Load

### The PostgreSQL Command:
```sql
DO $$
DECLARE
    start_time TIMESTAMP;
    end_time TIMESTAMP;
BEGIN
    start_time := clock_timestamp();
    
    FOR i IN 1..50000 LOOP
        INSERT INTO orders (user_id, product, amount)
        VALUES (
            (random() * 10 + 1)::INTEGER,
            'Heavy_Load_' || i,
            (random() * 1000)::NUMERIC(10,2)
        );
        
        IF i % 10000 = 0 THEN
            end_time := clock_timestamp();
            RAISE NOTICE '% rows - Rate: % rows/sec', 
                i, 
                ROUND(i / EXTRACT(EPOCH FROM (end_time - start_time)));
        END IF;
    END LOOP;
    
    end_time := clock_timestamp();
    RAISE NOTICE 'Completed in % seconds', EXTRACT(EPOCH FROM (end_time - start_time));
END $$;
```

### Line-by-Line Explanation:

| Line | What It Does | MySQL Equivalent |
|------|--------------|------------------|
| `DO $$` | Start anonymous code block | `DELIMITER $$ CREATE PROCEDURE` |
| `DECLARE` | Declare variables | `DECLARE` in procedure |
| `start_time := clock_timestamp()` | Record start time | `SET start_time = NOW()` |
| `FOR i IN 1..50000 LOOP` | Loop 50,000 times | `WHILE i <= 50000 DO` |
| `INSERT INTO orders` | Insert one row | Same in MySQL |
| `random() * 10 + 1` | Random number 1-11 | `FLOOR(1 + RAND() * 10)` |
| `'Heavy_Load_' \|\| i` | Concatenate string | `CONCAT('Heavy_Load_', i)` |
| `::INTEGER` | Cast to integer | `CAST(... AS SIGNED)` |
| `::NUMERIC(10,2)` | Cast to decimal | `CAST(... AS DECIMAL(10,2))` |
| `IF i % 10000 = 0` | Every 10,000 rows | `IF MOD(i, 10000) = 0` |
| `RAISE NOTICE` | Print message | `SELECT 'message'` (no equivalent) |
| `EXTRACT(EPOCH FROM ...)` | Get seconds from timestamp | `TIMESTAMPDIFF(SECOND, ...)` |
| `END $$` | End code block | `END$$ DELIMITER ;` |

### What This Creates:
```
Row 1:    user_id=7,  product='Heavy_Load_1',     amount=234.56
Row 2:    user_id=3,  product='Heavy_Load_2',     amount=789.12
Row 3:    user_id=10, product='Heavy_Load_3',     amount=45.67
...
Row 50000: user_id=5,  product='Heavy_Load_50000', amount=912.34
```

### Progress Output:
```
NOTICE:  10000 rows - Rate: 8765 rows/sec
NOTICE:  20000 rows - Rate: 9123 rows/sec
NOTICE:  30000 rows - Rate: 8890 rows/sec
NOTICE:  40000 rows - Rate: 9045 rows/sec
NOTICE:  50000 rows - Rate: 8998 rows/sec
NOTICE:  Completed in 5.55 seconds
```

### MySQL Equivalent:
```sql
DELIMITER $$
CREATE PROCEDURE generate_heavy_load()
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE start_time TIMESTAMP DEFAULT NOW();
    DECLARE end_time TIMESTAMP;
    
    WHILE i <= 50000 DO
        INSERT INTO orders (user_id, product, amount)
        VALUES (
            FLOOR(1 + RAND() * 10),
            CONCAT('Heavy_Load_', i),
            RAND() * 1000
        );
        
        IF MOD(i, 10000) = 0 THEN
            SET end_time = NOW();
            SELECT CONCAT(i, ' rows inserted') AS progress;
        END IF;
        
        SET i = i + 1;
    END WHILE;
    
    SET end_time = NOW();
    SELECT TIMESTAMPDIFF(SECOND, start_time, end_time) AS duration_seconds;
END$$
DELIMITER ;

CALL generate_heavy_load();
DROP PROCEDURE generate_heavy_load;
```

---

## 🔍 Command 2: Monitor Lag in Real-Time

### The PostgreSQL Command:
```sql
SELECT 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
    replay_lag,
    state
FROM pg_stat_replication;
```

### Function Breakdown:

**`pg_current_wal_lsn()`**
- **Returns:** Current Write-Ahead Log position on PRIMARY
- **Example:** `0/E579A20`
- **Think of it as:** "Where is PRIMARY now in the transaction log?"
- **MySQL equivalent:** `SHOW MASTER STATUS` → File + Position

**`replay_lsn`** (from pg_stat_replication view)
- **Returns:** Last WAL position STANDBY has replayed
- **Example:** `0/E479A20`
- **Think of it as:** "Where is STANDBY now in the transaction log?"
- **MySQL equivalent:** Relay_Log_Pos in `SHOW SLAVE STATUS`

**`pg_wal_lsn_diff(A, B)`**
- **Returns:** Bytes difference between two LSN positions
- **Calculation:** A - B
- **Example:** `pg_wal_lsn_diff('0/E579A20', '0/E479A20')` = 16,777,216 bytes = 16 MB
- **MySQL equivalent:** Manual calculation (Current Position - Replica Position)

**`pg_size_pretty(bytes)`**
- **Returns:** Human-readable size
- **Example:** `16777216` → `16 MB`
- **MySQL equivalent:** No built-in function (use `FORMAT()` or manual division)

**`replay_lag`**
- **Returns:** Time interval showing how far behind standby is
- **Example:** `00:00:05` = 5 seconds behind
- **MySQL equivalent:** `Seconds_Behind_Master` in `SHOW SLAVE STATUS`

**`state`**
- **Returns:** Replication connection state
- **Values:** `streaming`, `catchup`, `backup`
- **MySQL equivalent:** `Slave_IO_State` in `SHOW SLAVE STATUS`

### Output Example:
```
lag     | replay_lag | state
--------+------------+-----------
5 MB    | 00:00:03   | streaming
```

**Interpretation:**
- Standby is 5 MB behind in bytes
- Standby is 3 seconds behind in time
- Connection is active (streaming)

### MySQL Equivalent:
```sql
SHOW SLAVE STATUS\G

-- Key fields to compare:
Seconds_Behind_Master: 3        -- Like replay_lag
Relay_Log_Space: 5242880        -- Like our 5 MB lag
Slave_IO_State: Waiting for master to send event  -- Like state
Master_Log_File: mysql-bin.000123
Read_Master_Log_Pos: 1234567    -- Like pg_current_wal_lsn()
Relay_Log_File: relay-bin.000045
Relay_Log_Pos: 789012           -- Like replay_lsn
```

---

## 🔍 Command 3: Measure Total WAL Generated

### The PostgreSQL Command:
```sql
SELECT 
    pg_size_pretty(
        pg_wal_lsn_diff(
            pg_current_wal_lsn(), 
            '0/E579A20'  -- Your baseline LSN from pre-flight check
        )
    ) AS total_wal_generated;
```

### Step-by-Step Calculation:

**Step 1: Get current LSN**
```sql
SELECT pg_current_wal_lsn();
-- Returns: 0/E6D9A20 (after heavy load)
```

**Step 2: Calculate difference**
```sql
SELECT pg_wal_lsn_diff('0/E6D9A20', '0/E579A20');
-- Returns: 1441792 (bytes)
```

**Step 3: Make human-readable**
```sql
SELECT pg_size_pretty(1441792);
-- Returns: 1408 kB (or ~1.4 MB)
```

### Real Example:
```
Baseline LSN:  0/E579A20  (before heavy load)
Current LSN:   0/E6D9A20  (after inserting 50,000 rows)
Difference:    0x160000 hex = 1,441,792 bytes = 1.4 MB

This means: 50,000 row inserts generated 1.4 MB of WAL
Calculation: 1.4 MB ÷ 50,000 rows = ~29 bytes per row (in WAL, not actual data!)
```

### Why WAL Size ≠ Data Size:

**Data on disk:**
```
user_id:  4 bytes (INTEGER)
product:  varies, avg 20 bytes (VARCHAR)
amount:   8 bytes (NUMERIC)
Total:    ~32 bytes per row × 50,000 = 1.6 MB
```

**WAL contains:**
- Transaction start/commit records
- Index updates (if any)
- System catalog changes
- Checkpoint information
- **Result:** WAL is similar size but not exactly same

### MySQL Equivalent:
```sql
-- Get starting binlog position:
SHOW MASTER STATUS;
-- File: mysql-bin.000123, Position: 3000000

-- After heavy load:
SHOW MASTER STATUS;
-- File: mysql-bin.000123, Position: 4500000

-- Calculate:
-- 4,500,000 - 3,000,000 = 1,500,000 bytes generated
-- ~1.5 MB binary log for 50,000 rows

-- Or check binlog file size:
SELECT file_size 
FROM information_schema.FILES 
WHERE file_name = 'mysql-bin.000123';
```

---

## 🔍 Command 4: Verify Row Counts

### The PostgreSQL Command:
```sql
SELECT COUNT(*) FROM orders;
```

### Expected Results:

**On PRIMARY:**
```
count  
-------
50004
```

**On STANDBY:**
```
count  
-------
50004
```

### Breakdown:
```
Original rows:  4
New inserts:    50,000
Total:          50,004

If counts match → Replication successful ✓
If counts differ → Data loss or lag still present ✗
```

### Check Both Servers:
```bash
# PRIMARY:
docker exec postgres-primary psql -U postgres -c "SELECT COUNT(*) FROM orders;"

# STANDBY:
docker exec postgres-standby psql -U postgres -c "SELECT COUNT(*) FROM orders;"
```

### MySQL Equivalent:
```sql
-- On master:
SELECT COUNT(*) FROM orders;

-- On replica:
SELECT COUNT(*) FROM orders;

-- Should match exactly if replica caught up
```

---

## 🔍 Command 5: Real-Time Monitoring

### The Shell Command:
```bash
watch -n 1 "docker exec postgres-primary psql -U postgres -t -c \"
SELECT 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
    replay_lag
FROM pg_stat_replication;
\""
```

### What Each Part Does:

**`watch -n 1`**
- Re-run command every 1 second
- Updates display automatically
- Press `Ctrl+C` to stop

**`-t` flag in psql**
- Output tuples only (no table borders)
- Cleaner output for monitoring

**The backslashes `\"`**
- Escape quotes for nested command
- Needed because of: shell → docker → psql → SQL

### What You'll See:
```
Every 1.0s: docker exec postgres-primary psql...

 lag      | replay_lag 
----------+------------
 0 bytes  | 

(refreshing every second...)

 lag      | replay_lag 
----------+------------
 2 MB     | 00:00:01

(load in progress...)

 lag      | replay_lag 
----------+------------
 8 MB     | 00:00:04

(peak lag...)

 lag      | replay_lag 
----------+------------
 3 MB     | 00:00:02

(catching up...)

 lag      | replay_lag 
----------+------------
 0 bytes  | 

(caught up!)
```

### Timeline Example:
```
Time    | Lag       | What's Happening
--------+-----------+----------------------------------
00:00   | 0 bytes   | Starting point (zero lag)
00:02   | 2 MB      | Heavy load started, lag building
00:05   | 8 MB      | Peak lag reached
00:06   | 6 MB      | Load finished, standby catching up
00:08   | 2 MB      | Almost caught up
00:10   | 0 bytes   | Fully synchronized again ✓
```

### MySQL Equivalent:
```bash
# Monitor replica lag every 1 second:
watch -n 1 "mysql -u root -pPassword -e 'SHOW SLAVE STATUS\G' | grep -E 'Seconds_Behind_Master|Relay_Log_Space'"

# Output:
Every 1.0s: mysql...

Seconds_Behind_Master: 0
Relay_Log_Space: 154

(load starts...)

Seconds_Behind_Master: 3
Relay_Log_Space: 5242880

(peak lag: 3 seconds, 5 MB relay logs)

Seconds_Behind_Master: 1
Relay_Log_Space: 1048576

(catching up...)

Seconds_Behind_Master: 0
Relay_Log_Space: 154

(caught up!)
```

---

## 📊 Quick Reference Table

| PostgreSQL | What It Returns | Example | MySQL Equivalent |
|------------|-----------------|---------|------------------|
| `pg_current_wal_lsn()` | Current WAL position | `0/E579A20` | `SHOW MASTER STATUS` |
| `replay_lsn` | Standby's position | `0/E479A20` | Read_Master_Log_Pos |
| `pg_wal_lsn_diff(A,B)` | Bytes between A and B | `16777216` | Manual subtraction |
| `pg_size_pretty(bytes)` | Human-readable size | `16 MB` | Division by 1024 |
| `replay_lag` | Time delay | `00:00:05` | Seconds_Behind_Master |
| `pg_stat_replication` | Replication status view | (table) | `SHOW SLAVE STATUS` |
| `pg_walfile_name(lsn)` | WAL filename for LSN | `000000030000000000000E` | Binary log filename |

---

## 🎓 Key Concepts

### LSN = Log Sequence Number
```
Format: 0/E579A20

Breaking it down:
  0/        → Timeline ID (changes after failover)
  E579A20   → Hex offset within WAL

Think of it like:
  MySQL binlog position = (File: mysql-bin.000123, Position: 456789)
  PostgreSQL LSN       = Single unified address: 0/E579A20
```

### WAL = Write-Ahead Log
```
Similar to MySQL binary logs, but:
  - PostgreSQL: Continuous stream (LSN)
  - MySQL: Discrete files (binlog.000001, binlog.000002, ...)
  
Both record:
  - All data modifications (INSERT, UPDATE, DELETE)
  - Transaction commits
  - Used for replication
  - Used for crash recovery
```

### Replication Lag = Two Measurements
```
1. Byte Lag:
   - How many bytes STANDBY is behind
   - pg_wal_lsn_diff(current_lsn, replay_lsn)
   - Example: 5 MB behind
   
2. Time Lag (replay_lag):
   - How many seconds STANDBY is behind
   - Based on transaction timestamps
   - Example: 3 seconds behind
   
Both can differ:
  - 1 MB lag might be 1 second (fast writes)
  - 1 MB lag might be 10 seconds (slow writes)
```

---

## 🎬 You're Ready!

**Now you understand:**
- ✅ What `DO $$` block does (anonymous procedure)
- ✅ What `pg_wal_lsn_diff()` calculates (byte difference)
- ✅ What `pg_size_pretty()` formats (human-readable)
- ✅ What `replay_lag` shows (time delay)
- ✅ What `watch -n 1` does (auto-refresh monitoring)
- ✅ How to interpret the output (lag → catch up → zero)

**Ready to execute Scenario 06!** 🚀

---

*Command reference created: November 17, 2025*  
*All PostgreSQL commands explained with MySQL comparisons*
