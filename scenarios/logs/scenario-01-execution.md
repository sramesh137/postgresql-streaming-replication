# Scenario 01: Understanding Replication Lag - Execution Log

**Date**: November 16, 2025  
**Time**: 07:43 - 07:47 UTC  
**Duration**: ~4 minutes  
**Status**: ✅ COMPLETED

---

## Executive Summary

Successfully completed hands-on testing of PostgreSQL streaming replication lag under various load conditions. Key finding: **Asynchronous streaming replication maintained near-zero lag even under 100,000 row bulk inserts**.

---

## Environment Details

```
PostgreSQL Version: 15.15 (Debian)
Primary Server: postgres-primary:5432
Standby Server: postgres-standby:5433
Replication Type: Asynchronous Streaming
Network: Docker bridge 172.19.0.0/16
```

---

## Pre-Execution Status

**Replication Health Check**:
```
Application: standby1
State: streaming
Lag: 0 bytes
Current LSN: 0/3020A50
Replay LSN: 0/3020A50
Timeline: 1
```

---

## Step-by-Step Execution

### Step 1: Create Bulk Insert Function

**Objective**: Create a utility function to generate test load

**Command**:
```sql
CREATE OR REPLACE FUNCTION insert_bulk_users(num_rows INTEGER)
RETURNS TABLE(inserted_count INTEGER, start_time TIMESTAMP, end_time TIMESTAMP) AS $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    inserted INTEGER;
BEGIN
    start_ts := clock_timestamp();
    FOR i IN 1..num_rows LOOP
        INSERT INTO users (username, email)
        VALUES ('bulk_user_' || i, 'bulk_user_' || i || '@test.com');
    END LOOP;
    end_ts := clock_timestamp();
    inserted := num_rows;
    RETURN QUERY SELECT inserted, start_ts, end_ts;
END;
$$ LANGUAGE plpgsql;
```

**Result**: ✅ Function created successfully

**Note**: Used proper escaping (`\$\$`) to avoid Docker/shell interpretation issues

---

### Step 2: Light Load Test - 1,000 Rows

**Objective**: Baseline test with small dataset

**Execution**:
```sql
SELECT * FROM insert_bulk_users(1000);
```

**Results**:
```
Inserted Count: 1,000
Start Time: 2025-11-16 07:43:36.634662
End Time: 2025-11-16 07:43:36.643548
Duration: 8.886 milliseconds
```

**Replication Lag**:
```
Lag Size: 32 bytes
State: streaming
```

**Standby Verification**:
```sql
SELECT COUNT(*) FROM users WHERE username LIKE 'bulk_user_%';
-- Result: 1000 rows ✅
```

**Key Observations**:
- Insert performance: ~112 rows/ms
- Replication lag: Negligible (32 bytes)
- Data consistency: 100% replicated
- Time to replicate: < 1 second

---

### Step 3: Medium Load Test - 10,000 Rows

**Objective**: Test with 10x more data

**Preparation**:
```sql
-- Clean up previous test data
DELETE FROM users WHERE username LIKE 'bulk_user_%';
-- Deleted: 1,000 rows
```

**Execution**:
```sql
SELECT * FROM insert_bulk_users(10000);
```

**Results**:
```
Inserted Count: 10,000
Start Time: 2025-11-16 07:46:35.719434
End Time: 2025-11-16 07:46:35.797499
Duration: 78.065 milliseconds
```

**Replication Lag Monitoring**:

*Immediately after insert*:
```
Application: standby1
State: streaming
Lag Size: 0 bytes
Sent vs Replay: 0 bytes
```

*After 1 second wait*:
```
Lag Size: 0 bytes
State: streaming
```

**Standby Verification**:
```
Count: 10,000 rows ✅
```

**WAL Generation Statistics**:
```
Current LSN: 0/3326580
Total WAL Generated: 51 MB
Retained WAL: 0 bytes (replication slot active)
```

**Key Observations**:
- Insert performance: ~128 rows/ms (slightly faster!)
- Replication lag: 0 bytes (perfect sync)
- WAL efficiency: ~5.1 KB per row
- Replication slot: Working perfectly, no WAL buildup

---

### Step 4: Create Monitoring View

**Objective**: Build reusable monitoring tool

**Command**:
```sql
CREATE OR REPLACE VIEW replication_health AS
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    pg_current_wal_lsn() as current_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as lag_size,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes,
    replay_lag as replay_time_lag,
    write_lag,
    flush_lag
FROM pg_stat_replication;
```

**Result**: ✅ View created successfully

**Initial Test Query**:
```
Application: standby1
Client: 172.19.0.3
State: streaming
Sync State: async
Current LSN: 0/3342000
Replay LSN: 0/33412E0
Lag Size: 3360 bytes
Lag Bytes: 3360
Replay Time Lag: 00:00:00.001794
Write Lag: 00:00:00.000452
Flush Lag: 00:00:00.001143
```

**Key Observations**:
- Lag types: replay (1.7ms), write (0.45ms), flush (1.1ms)
- All lag values < 2ms (excellent performance)
- View provides comprehensive health snapshot

---

### Step 5: Heavy Load Test - 100,000 Rows

**Objective**: Stress test with massive dataset

**Preparation**:
```sql
DELETE FROM users WHERE username LIKE 'bulk_user_%';
-- Deleted: 10,000 rows
```

**Execution**:
```sql
SELECT * FROM insert_bulk_users(100000);
```

**Results**:
```
Inserted Count: 100,000
Start Time: 2025-11-16 07:47:16.564677
End Time: 2025-11-16 07:47:17.371537
Duration: 806.86 milliseconds
```

**Replication Lag Analysis**:

*Immediately after insert*:
```
Application: standby1
State: streaming
Current LSN: 0/4E54DA0
Replay LSN: 0/4E54DA0
Lag Size: 0 bytes
Lag Bytes: 0
Replay Time Lag: 00:00:00.000662 (0.6ms)
Write Lag: 00:00:00.00017 (0.17ms)
Flush Lag: 00:00:00.000593 (0.59ms)
```

*After 2 seconds*:
```
Lag Size: 0 bytes
Replay Time Lag: 00:00:00.000662
State: streaming
```

**Standby Verification**:
```
Count: 100,000 rows ✅
```

**Key Observations**:
- Insert performance: ~124 rows/ms (consistent!)
- Replication lag: 0 bytes even under heavy load
- All lag metrics < 1ms
- Replication kept up in real-time

---

## Performance Summary

| Test | Rows | Duration (ms) | Rows/ms | Replication Lag | Time to Replicate |
|------|------|---------------|---------|-----------------|-------------------|
| Light | 1,000 | 8.89 | 112 | 32 bytes | < 1 second |
| Medium | 10,000 | 78.07 | 128 | 0 bytes | < 1 second |
| Heavy | 100,000 | 806.86 | 124 | 0 bytes | < 1 second |

**Average Insert Rate**: **121 rows/millisecond** (~121,000 rows/second)

---

## Key Learnings

### 1. **Asynchronous Replication is Fast**
- Even with async mode, lag remained near-zero
- Standby kept up with 100,000 row inserts in real-time
- Network latency minimal in Docker environment

### 2. **LSN (Log Sequence Number) Understanding**
- Started at: `0/3020A50`
- After 100K inserts: `0/4E54DA0`
- WAL growth: ~26 MB for 100,000 rows
- Average: ~260 bytes per row of WAL data

### 3. **Lag Types Explained**
- **Write Lag**: Time to write WAL to standby's OS cache (0.17ms)
- **Flush Lag**: Time to flush WAL to standby's disk (0.59ms)
- **Replay Lag**: Time to apply changes to standby's database (0.66ms)
- **Total pipeline**: < 1ms end-to-end

### 4. **Replication Slot Benefits**
- Prevents WAL deletion before standby consumes it
- `retained_wal: 0 bytes` = standby is keeping up perfectly
- If standby falls behind, primary would retain WAL automatically

### 5. **Monitoring Best Practices**
- Created `replication_health` view for easy checking
- Key metrics: lag_bytes, lag_size, replay_lag, state
- Monitor all three lag types for complete picture

---

## Real-World Implications

### What This Means for Production:

1. **Read Scaling**: Standby can safely serve reads with < 1ms delay
2. **Disaster Recovery**: In case of primary failure, standby is near-current
3. **Zero Data Loss**: With such low lag, failover would lose minimal data
4. **Capacity Planning**: System handled 121K rows/sec comfortably

### When Lag Might Increase:

1. **Network Issues**: Docker localhost = no latency; real networks vary
2. **Standby Under Load**: If standby is serving heavy read queries
3. **Large Transactions**: Single massive transaction could cause spike
4. **Disk I/O Bottleneck**: Slow standby disks would increase flush_lag

---

## Troubleshooting Notes

### Issue 1: Duplicate Key Error
**Problem**: Second bulk insert failed with unique constraint violation
**Cause**: Previous test data not cleaned up
**Solution**: Always DELETE previous test data before re-running
```sql
DELETE FROM users WHERE username LIKE 'bulk_user_%';
```

### Issue 2: Syntax Error with `\gx`
**Problem**: `\gx` psql meta-command doesn't work in non-interactive mode
**Solution**: Use `-x` flag with `psql` command instead
```bash
docker exec postgres-primary psql -U postgres -x -c "SELECT ..."
```

---

## Commands Reference

### Quick Lag Check:
```sql
SELECT * FROM replication_health;
```

### Detailed Replication Stats:
```sql
SELECT 
    application_name,
    state,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as lag,
    replay_lag,
    write_lag,
    flush_lag
FROM pg_stat_replication;
```

### Check WAL Generation:
```sql
SELECT 
    pg_current_wal_lsn() as current_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) as total_wal
FROM pg_stat_replication;
```

### Verify Data Consistency:
```bash
# On primary:
docker exec postgres-primary psql -U postgres -c \
  "SELECT COUNT(*) FROM users;"

# On standby:
docker exec postgres-standby psql -U postgres -c \
  "SELECT COUNT(*) FROM users;"
```

---

## Next Steps

- ✅ Scenario 01 Complete
- ⏭️ Next: Scenario 02 - Read Load Distribution
- 📝 Update `my-progress.md` with observations
- 🎯 Try experiments: Network latency, concurrent writes, large BLOBs

---

## Conclusion

Scenario 01 successfully demonstrated that PostgreSQL streaming replication can maintain near-zero lag even under significant write load. The asynchronous replication mode proved highly efficient, with sub-millisecond lag across all tests.

**Key Takeaway**: In a low-latency network (like Docker localhost), async streaming replication is effectively real-time for most practical purposes.

---

**Logged by**: GitHub Copilot  
**Reviewed by**: Ready for user review  
**Status**: Complete and ready for archival
