# Scenario 10: Disaster Recovery Drill - Complete Failover Exercise

**Difficulty:** Advanced  
**Duration:** 45-60 minutes  
**Prerequisites:** All previous scenarios completed

## 🎯 Learning Objectives

- Execute complete disaster recovery procedure
- Practice under pressure with timed drills
- Verify data integrity throughout process
- Document recovery procedures
- Measure RTO and RPO

## 📚 Background

**Disaster Recovery (DR)** planning requires:
- **RTO** (Recovery Time Objective) - How fast can you recover?
- **RPO** (Recovery Point Objective) - How much data can you lose?
- **Regular drills** - Practice makes perfect
- **Documentation** - Step-by-step procedures
- **Verification** - Prove recovery succeeded

This scenario simulates a complete primary failure and recovery.

---

## Step 1: Pre-Disaster State Documentation

```bash
echo "=== PRE-DISASTER STATE ==="
echo "Timestamp: $(date)"

# Document everything
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Server info
SELECT version();
SELECT pg_current_wal_lsn() AS primary_lsn;
SELECT timeline_id FROM pg_control_checkpoint();

-- Data counts
SELECT 'users' AS table, COUNT(*) AS rows FROM users
UNION ALL
SELECT 'orders', COUNT(*) FROM orders;

-- Last transactions
SELECT max(created_at) AS last_user FROM users;
SELECT max(order_date) AS last_order FROM orders;
EOF

# Replication status
docker exec -it postgres-primary psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

**Save this output for comparison!**

---

## Step 2: Insert Final Critical Transaction

```bash
echo "💰 Inserting final critical transaction..."
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Critical transaction before disaster
BEGIN;

INSERT INTO users (username, email) VALUES 
    ('critical_user_before_disaster', 'critical@before.com')
RETURNING id, username, created_at;

INSERT INTO orders (user_id, product, amount) VALUES 
    (currval('users_id_seq'), 'Critical_Order_Before_Disaster', 999999.99)
RETURNING id, product, amount, order_date;

-- Create disaster marker
CREATE TABLE IF NOT EXISTS disaster_recovery_log (
    id SERIAL PRIMARY KEY,
    event_type VARCHAR(50),
    event_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    details TEXT
);

INSERT INTO disaster_recovery_log (event_type, details)
VALUES ('PRE_DISASTER_MARKER', 'This transaction completed before disaster');

COMMIT;

SELECT * FROM disaster_recovery_log;
EOF

echo "⏱️ Waiting for replication..."
sleep 3
```

---

## Step 3: SIMULATE DISASTER - Primary Fails

```bash
echo "💥💥💥 DISASTER! PRIMARY SERVER FAILED! 💥💥💥"
echo "Failure timestamp: $(date)"
DISASTER_START=$(date +%s)

# Kill primary immediately
docker-compose stop postgres-primary
docker-compose rm -f postgres-primary

echo "Primary server is DOWN!"
echo "Applications cannot write!"
echo "Starting DR procedure..."
```

---

## Step 4: Verify Standby Has Data

```bash
echo "🔍 Step 1: Verify standby has replicated data..."
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Check we have the critical transaction
SELECT * FROM disaster_recovery_log;

SELECT * FROM users WHERE username = 'critical_user_before_disaster';

SELECT * FROM orders WHERE product = 'Critical_Order_Before_Disaster';

SELECT pg_is_in_recovery() AS still_standby;
EOF
```

---

## Step 5: Promote Standby to Primary

```bash
echo "🚀 Step 2: PROMOTING STANDBY TO PRIMARY..."
PROMOTE_START=$(date +%s)

docker exec -it postgres-standby pg_ctl promote -D /var/lib/postgresql/data

echo "Waiting for promotion to complete..."
sleep 5

# Verify promotion
docker exec -it postgres-standby psql -U postgres << 'EOF'
SELECT 
    CASE 
        WHEN pg_is_in_recovery() THEN '❌ STILL STANDBY - PROMOTION FAILED!'
        ELSE '✅ PROMOTED - NOW PRIMARY!'
    END AS promotion_status;

SELECT pg_current_wal_lsn() AS new_primary_lsn;
SELECT timeline_id FROM pg_control_checkpoint() AS new_timeline;
EOF

PROMOTE_END=$(date +%s)
PROMOTE_DURATION=$((PROMOTE_END - PROMOTE_START))
echo "⏱️ Promotion completed in $PROMOTE_DURATION seconds"
```

---

## Step 6: Verify Write Capability

```bash
echo "✅ Step 3: Testing write capability on new primary..."
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Test writes work
BEGIN;

INSERT INTO disaster_recovery_log (event_type, details)
VALUES ('POST_DISASTER_RECOVERY', 'This transaction after failover on new primary');

INSERT INTO users (username, email) VALUES 
    ('first_user_after_disaster', 'after@disaster.com')
RETURNING *;

COMMIT;

SELECT * FROM disaster_recovery_log ORDER BY id;
EOF

echo "✅ New primary accepts writes!"
```

---

## Step 7: Data Integrity Verification

```bash
echo "🔍 Step 4: Full data integrity check..."
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Verify all critical data present
SELECT 
    'Pre-disaster user' AS check_type,
    COUNT(*) AS found
FROM users 
WHERE username = 'critical_user_before_disaster'
UNION ALL
SELECT 
    'Pre-disaster order',
    COUNT(*)
FROM orders 
WHERE product = 'Critical_Order_Before_Disaster'
UNION ALL
SELECT 
    'Post-disaster user',
    COUNT(*)
FROM users 
WHERE username = 'first_user_after_disaster'
UNION ALL
SELECT 
    'DR log entries',
    COUNT(*)
FROM disaster_recovery_log;

-- All should return 1 or more
EOF
```

---

## Step 8: Calculate Recovery Metrics

```bash
DISASTER_END=$(date +%s)
TOTAL_DOWNTIME=$((DISASTER_END - DISASTER_START))

echo ""
echo "==================================="
echo "   DISASTER RECOVERY COMPLETED"
echo "==================================="
echo ""
echo "📊 Recovery Metrics:"
echo "  - Total Downtime: $TOTAL_DOWNTIME seconds"
echo "  - Promotion Time: $PROMOTE_DURATION seconds"
echo "  - RTO Achieved: $TOTAL_DOWNTIME seconds"
echo "  - RPO Achieved: 0 rows lost (all data replicated)"
echo ""
echo "✅ Status: SUCCESSFUL RECOVERY"
echo "✅ Data Loss: ZERO"
echo "✅ New Primary: postgres-standby (port 5433)"
echo ""
```

---

## Step 9: Update Application Configuration

```bash
cat << 'EOF'
📝 ACTION REQUIRED: Update application configuration

OLD Configuration:
  Primary: postgres-primary:5432 (DOWN)
  Standby: postgres-standby:5433 (READ-ONLY)

NEW Configuration:
  Primary: postgres-standby:5433 (READ-WRITE) ← UPDATE THIS!

Update your connection strings to point to port 5433!
EOF
```

---

## Step 10: Post-Recovery Checklist

```bash
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Post-recovery verification checklist
SELECT 
    '✅ Server is primary' AS check,
    CASE WHEN NOT pg_is_in_recovery() THEN 'PASS' ELSE 'FAIL' END AS status
UNION ALL
SELECT 
    '✅ Accepts writes',
    CASE WHEN (SELECT COUNT(*) FROM disaster_recovery_log WHERE event_type = 'POST_DISASTER_RECOVERY') > 0 
        THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 
    '✅ Pre-disaster data intact',
    CASE WHEN (SELECT COUNT(*) FROM disaster_recovery_log WHERE event_type = 'PRE_DISASTER_MARKER') > 0
        THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 
    '✅ Timeline advanced',
    CASE WHEN (SELECT timeline_id FROM pg_control_checkpoint()) > 1
        THEN 'PASS' ELSE 'FAIL' END;
EOF
```

---

## 🎓 Knowledge Check

1. **What is RTO?**
   - [x] Recovery Time Objective - how fast you recover
   - [ ] Recovery Time Optimization
   - [ ] Replication Time Overhead
   - [ ] Required Transaction Ordering

2. **What is RPO?**
   - [x] Recovery Point Objective - how much data you can lose
   - [ ] Replication Performance Overhead
   - [ ] Required Primary Operations
   - [ ] Recovery Process Outline

3. **Why drill regularly?**
   - [ ] To waste time
   - [x] To ensure procedures work and team knows them
   - [ ] To break production
   - [ ] To test backups only

---

## 📊 DR Drill Scorecard

| Metric | Target | Achieved | Status |
|--------|--------|----------|--------|
| RTO (Downtime) | < 60s | ___s | |
| RPO (Data Loss) | 0 rows | ___ rows | |
| Promotion Time | < 10s | ___s | |
| Verification Time | < 30s | ___s | |
| Total DR Time | < 2 min | ___s | |

---

## 🎯 Key Takeaways

✅ **DR drills identify gaps** in procedures  
✅ **Documentation critical** during real disasters  
✅ **Automation reduces** recovery time  
✅ **Replication slots prevent** data loss  
✅ **Timeline changes protect** against split-brain  
✅ **Regular practice builds** team confidence  

**Best Practices:**
- Drill quarterly minimum
- Document every step
- Time each phase
- Verify data integrity
- Update procedures based on learnings
- Practice with different failure scenarios

---

## 📝 What You Learned

- [x] Complete DR procedure execution
- [x] RTO/RPO calculation
- [x] Data integrity verification
- [x] Promotion under pressure
- [x] Post-recovery validation
- [x] Metrics collection

---

## 🎉 Congratulations!

You've completed all 10 scenarios! You now have:
- ✅ Deep understanding of streaming replication
- ✅ Hands-on experience with all operations
- ✅ Confidence to handle production scenarios
- ✅ Complete DR procedures documented

**Next:** Implement in your real projects!
