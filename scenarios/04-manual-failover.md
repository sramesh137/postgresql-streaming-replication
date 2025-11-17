# Scenario 04: Manual Failover - Promoting Standby to Primary

**Difficulty:** Intermediate  
**Duration:** 30-40 minutes  
**Prerequisites:** Scenarios 01-03 completed, understanding of replication basics

⚠️ **WARNING:** This scenario permanently changes your replication topology. Make sure you understand each step before proceeding.

## 🎯 Learning Objectives

By completing this scenario, you will:
- Understand the failover process
- Learn how to promote a standby to primary
- Handle the old primary after failover
- Understand timeline changes in PostgreSQL
- Practice disaster recovery procedures
- Learn post-failover verification steps

## 📚 Background

**Failover** is the process of promoting a standby server to become the new primary when the current primary fails or needs maintenance. This is a critical skill for:

- **Disaster Recovery:** Primary server crashes
- **Planned Maintenance:** Upgrading primary hardware/software
- **Data Center Migration:** Moving operations to different location
- **Testing:** Validating your DR procedures

### Failover Process Overview:
```
BEFORE FAILOVER:
Primary (5432) ──WAL──> Standby (5433)
  [R/W]                  [R-Only]

AFTER FAILOVER:
Old Primary (down)      New Primary (5433)
  [Offline]                [R/W]
```

---

## ⚠️ Important Concepts

### Timeline

PostgreSQL uses **timelines** to track database history across failovers:
- **Timeline 1:** Original primary
- **Timeline 2:** After first failover
- **Timeline 3:** After second failover, etc.

This prevents old primary from rejoining without manual intervention (protecting against split-brain scenarios).

### Split-Brain

A dangerous situation where two servers both think they're primary:
```
BAD SCENARIO:
Primary (5432) ←─┐
  [R/W]          └─── Writes going to both!
New Primary (5433)  
  [R/W]          ┌─── Data divergence!
```

PostgreSQL prevents this with timelines.

---

## Step 1: Pre-Failover Health Check

Before starting, document your current state:

```bash
echo "=== PRE-FAILOVER STATE ==="

# Check current replication status
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    'PRIMARY SERVER' as server_type,
    pg_is_in_recovery() as in_recovery,
    pg_current_wal_lsn() as current_lsn,
    (SELECT timeline_id FROM pg_control_checkpoint()) as timeline;
EOF

docker exec -it postgres-standby psql -U postgres << 'EOF'
SELECT 
    'STANDBY SERVER' as server_type,
    pg_is_in_recovery() as in_recovery,
    pg_last_wal_receive_lsn() as received_lsn,
    pg_last_wal_replay_lsn() as replayed_lsn,
    (SELECT timeline_id FROM pg_control_checkpoint()) as timeline;
EOF

# Count rows for verification later
echo -e "\n=== ROW COUNTS ==="
docker exec -it postgres-primary psql -U postgres -c "SELECT 'users' as table_name, COUNT(*) FROM users UNION ALL SELECT 'orders', COUNT(*) FROM orders;"
```

**Document these values:**
- Primary timeline: _______
- Primary LSN: _______
- Standby timeline: _______
- User count: _______
- Order count: _______

---

## Step 2: Insert Final Data Before Failover

Let's add some data that we'll verify after failover:

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Insert identifiable data
INSERT INTO users (username, email) VALUES 
    ('pre_failover_user', 'before@failover.com')
RETURNING *;

-- Create a marker table
CREATE TABLE failover_markers (
    id SERIAL PRIMARY KEY,
    marker_name VARCHAR(50),
    marker_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    timeline INTEGER
);

INSERT INTO failover_markers (marker_name, timeline)
VALUES ('BEFORE_FAILOVER', (SELECT timeline_id FROM pg_control_checkpoint()));

SELECT * FROM failover_markers;
EOF
```

**Wait for replication:**
```bash
sleep 2

# Verify on standby
docker exec -it postgres-standby psql -U postgres -c "SELECT * FROM failover_markers;"
```

---

## Step 3: Simulate Primary Failure

Now let's simulate a primary server failure:

```bash
echo "🔴 Simulating primary server failure..."

# Stop the primary container
docker-compose stop postgres-primary

echo "Primary server stopped!"

# Verify standby is now orphaned
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Check replication status
SELECT pg_is_in_recovery();

-- Try to see if we can still query (we should!)
SELECT COUNT(*) FROM users;
EOF
```

**What just happened:**
- ✅ Standby still runs (Read-only)
- ✅ Standby has all replicated data
- ❌ No new data coming from primary
- ⚠️  Applications can't write (no primary!)

---

## Step 4: Promote Standby to Primary

Now comes the critical step - promotion:

```bash
echo "🚀 PROMOTING STANDBY TO PRIMARY..."

# Method 1: Using pg_ctl promote (preferred)
docker exec -it postgres-standby pg_ctl promote -D /var/lib/postgresql/data

echo "Promotion command sent!"
echo "Waiting for promotion to complete..."
sleep 5

# Verify promotion
docker exec -it postgres-standby psql -U postgres << 'EOF'
SELECT 
    CASE 
        WHEN pg_is_in_recovery() THEN '❌ Still in recovery - promotion failed'
        ELSE '✅ PROMOTED - Now accepting writes!'
    END AS promotion_status,
    pg_current_wal_lsn() AS new_primary_lsn,
    (SELECT timeline_id FROM pg_control_checkpoint()) AS new_timeline;
EOF
```

**Expected Output:**
- `pg_is_in_recovery()` = FALSE
- Timeline increased (likely from 1 to 2)
- New LSN position

---

## Step 5: Verify New Primary Accepts Writes

Test that the promoted standby now accepts writes:

```bash
echo "📝 Testing writes on new primary..."

docker exec -it postgres-standby psql -U postgres << 'EOF'
-- This should work now (it wouldn't before!)
INSERT INTO users (username, email) VALUES 
    ('post_failover_user', 'after@failover.com')
RETURNING *;

-- Record the failover event
INSERT INTO failover_markers (marker_name, timeline)
VALUES ('AFTER_FAILOVER', (SELECT timeline_id FROM pg_control_checkpoint()));

-- Show both markers
SELECT * FROM failover_markers ORDER BY id;
EOF
```

**Success indicators:**
- ✅ INSERT succeeds without error
- ✅ Two markers with different timelines
- ✅ New data created

---

## Step 6: Update Application Configuration

In a real scenario, you'd update your application to point to the new primary:

**OLD Configuration:**
```yaml
Primary: localhost:5432 (DOWN)
Standby: localhost:5433 (READ-ONLY)
```

**NEW Configuration:**
```yaml
Primary: localhost:5433 (READ-WRITE) ← Changed!
```

**Simulate application traffic:**
```bash
echo "📱 Simulating application traffic to new primary..."

docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Application writes
INSERT INTO orders (user_id, product, amount)
SELECT 
    (random() * 5 + 1)::INTEGER,
    'Product_' || i,
    (random() * 500 + 50)::NUMERIC(10,2)
FROM generate_series(1, 100) AS i;

-- Application reads
SELECT COUNT(*) AS total_orders FROM orders;
SELECT COUNT(*) AS total_users FROM users;
EOF
```

---

## Step 7: Examine Timeline Change

Let's understand what happened with timelines:

```bash
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Check timeline history
SELECT * FROM pg_control_checkpoint();

-- Show current timeline
SELECT timeline_id, redo_lsn, reason 
FROM pg_control_checkpoint();

-- Explain timeline change
SELECT 
    'Timeline' as concept,
    'Incremented during promotion to prevent old primary from reconnecting' as purpose,
    'Protects against split-brain scenarios' as benefit;
EOF
```

**Look in the data directory:**
```bash
# View timeline history files
docker exec -it postgres-standby ls -la /var/lib/postgresql/data/pg_wal/ | grep -E "\.history$|^total"
```

---

## Step 8: Check standby.signal File

The promotion removed the `standby.signal` file:

```bash
echo "Checking for standby.signal file..."

docker exec -it postgres-standby bash -c '
if [ -f /var/lib/postgresql/data/standby.signal ]; then
    echo "❌ standby.signal exists - still a standby"
else
    echo "✅ standby.signal removed - now a primary"
fi
'
```

**Why this matters:**
- Presence of `standby.signal` = Server is standby
- Absence = Server is primary
- This is how PostgreSQL knows its role

---

## Step 9: Attempt to Restart Old Primary (Demonstrates Protection)

Let's see what happens if we try to bring back the old primary:

```bash
echo "🔴 Attempting to start old primary..."
docker-compose start postgres-primary

# Wait for it to start
sleep 5

# Check its logs
echo -e "\n📋 OLD PRIMARY LOGS:"
docker-compose logs --tail=20 postgres-primary
```

**What you'll see:**
- Old primary starts on timeline 1
- It won't automatically become standby
- It's isolated (no replication connections)
- It has old data (before failover)

**Check its state:**
```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    'OLD PRIMARY' as server_name,
    pg_is_in_recovery() as in_recovery,
    (SELECT timeline_id FROM pg_control_checkpoint()) as timeline,
    COUNT(*) as user_count
FROM users;
EOF
```

**Compare with new primary:**
```bash
docker exec -it postgres-standby psql -U postgres << 'EOF'
SELECT 
    'NEW PRIMARY' as server_name,
    pg_is_in_recovery() as in_recovery,
    (SELECT timeline_id FROM pg_control_checkpoint()) as timeline,
    COUNT(*) as user_count
FROM users;
EOF
```

**Notice:**
- Old primary: Timeline 1, missing post-failover data
- New primary: Timeline 2, has all data

---

## Step 10: Verify Data Consistency

Check that no data was lost:

```bash
docker exec -it postgres-standby psql -U postgres << 'EOF'
-- Check all our markers
SELECT * FROM failover_markers ORDER BY id;

-- Verify specific users exist
SELECT username, email, created_at 
FROM users 
WHERE username IN ('pre_failover_user', 'post_failover_user')
ORDER BY created_at;

-- Summary
SELECT 
    'Total Users' as metric,
    COUNT(*)::TEXT as value
FROM users
UNION ALL
SELECT 
    'Total Orders',
    COUNT(*)::TEXT
FROM orders
UNION ALL
SELECT
    'Failover Markers',
    COUNT(*)::TEXT
FROM failover_markers;
EOF
```

---

## Step 11: Configure Old Primary as New Standby (Optional Advanced)

To reuse the old primary as a standby:

```bash
echo "🔄 Converting old primary to standby of new primary..."

# Stop old primary
docker-compose stop postgres-primary

# Clean its data directory
docker-compose run --rm postgres-primary bash -c "rm -rf /var/lib/postgresql/data/*"

# Take base backup from NEW primary (standby container on port 5433)
docker-compose run --rm postgres-primary bash -c "
PGPASSWORD=replicator_password pg_basebackup \
  -h postgres-standby \
  -p 5432 \
  -D /var/lib/postgresql/data \
  -U replicator \
  -v -P -X stream
"

# Create standby.signal
docker-compose run --rm postgres-primary bash -c "touch /var/lib/postgresql/data/standby.signal"

# Configure to follow new primary
docker-compose run --rm postgres-primary bash -c "cat >> /var/lib/postgresql/data/postgresql.conf <<EOFCONF

# New Replication Configuration (following new primary)
primary_conninfo = 'host=postgres-standby port=5432 user=replicator password=replicator_password application_name=old_primary_now_standby'
EOFCONF
"

# Start it
docker-compose start postgres-primary

echo "Waiting for new topology to establish..."
sleep 10
```

**Verify new topology:**
```bash
# Check on NEW primary (standby container)
docker exec -it postgres-standby psql -U postgres -c "SELECT application_name, state, replay_lag FROM pg_stat_replication;"

# Check on NEW standby (primary container)  
docker exec -it postgres-primary psql -U postgres -c "SELECT pg_is_in_recovery();"
```

---

## 🎓 Knowledge Check

1. **What happens to the timeline after promotion?**
   - [ ] Stays the same
   - [ ] Increments by 1
   - [ ] Resets to 0
   - [ ] Becomes random

2. **Can the old primary automatically rejoin as standby?**
   - [ ] Yes, automatically
   - [ ] Yes, but only if you restart it
   - [ ] No, requires manual reconfiguration
   - [ ] Only if timelines match

3. **What file indicates a server is in standby mode?**
   - [ ] recovery.conf
   - [ ] standby.signal
   - [ ] postgresql.conf
   - [ ] pg_hba.conf

4. **After failover, where should applications write?**
   - [ ] Both servers
   - [ ] Old primary
   - [ ] New primary (promoted standby)
   - [ ] Neither

---

## 🧪 Post-Failover Verification Checklist

- [ ] New primary accepts writes
- [ ] New primary accepts reads
- [ ] `pg_is_in_recovery()` returns FALSE
- [ ] Timeline has incremented
- [ ] standby.signal file removed
- [ ] Applications updated to new primary
- [ ] All expected data present
- [ ] No replication lag (if new standby configured)
- [ ] Monitoring updated
- [ ] Documentation updated

---

## 📊 Results Summary

| Metric | Before Failover | After Failover |
|--------|----------------|----------------|
| Primary server | postgres-primary:5432 | postgres-standby:5433 |
| Standby server | postgres-standby:5433 | (optional: reconfigured primary) |
| Timeline | 1 | 2 |
| Data loss | N/A | 0 rows |
| Downtime | N/A | ~5 seconds |

---

## 🎯 Real-World Failover Scenarios

### Scenario 1: Hardware Failure
```
1. Primary server crashes (hardware failure)
2. Monitoring detects primary down
3. DBA promotes standby to primary
4. Applications updated to new primary
5. Order new hardware
6. Configure new hardware as standby
```

### Scenario 2: Planned Maintenance
```
1. Schedule maintenance window
2. Stop writes to application
3. Let standby catch up completely (lag = 0)
4. Promote standby
5. Update application configuration
6. Resume writes (to new primary)
7. Perform maintenance on old primary
8. Rejoin as new standby
```

### Scenario 3: Data Center Migration
```
1. Setup standby in new data center
2. Let it sync completely
3. During migration window:
   - Promote remote standby
   - Update DNS/load balancers
   - Point apps to new primary
4. Decommission old primary
```

---

## ⚠️ Common Pitfalls

### Pitfall 1: Forgetting to Update Applications
```
❌ Primary fails, standby promoted
❌ Apps still pointing to old primary
❌ All writes fail
✅ Update connection strings immediately!
```

### Pitfall 2: Not Waiting for Full Sync
```
❌ Promote standby while lag = 10MB
❌ Last 10MB of data lost
✅ Always wait for lag = 0 in planned failover
```

### Pitfall 3: Split-Brain
```
❌ Old primary comes back online
❌ Both accept writes
❌ Data diverges
✅ Timeline protection prevents this
✅ Always reconfigure before rejoining
```

---

## 🔧 Cleanup / Reset

To return to original state for other scenarios:

```bash
# Stop everything
docker-compose down -v

# Start fresh
docker-compose up -d

# Wait for primary
sleep 10

# Setup replication
bash scripts/setup-replication.sh
```

---

## 🎯 Key Takeaways

✅ **Failover promotes standby to primary** in ~5-10 seconds  
✅ **Timeline changes prevent split-brain** scenarios  
✅ **Old primary can't auto-rejoin** - requires reconfiguration  
✅ **standby.signal file** controls server role  
✅ **Manual failover is straightforward** but needs testing  
✅ **Automated failover tools** (Patroni, repmgr) handle this automatically  

**Critical Skills Learned:**
- Emergency failover procedure
- Timeline management
- Data consistency verification
- Old primary handling
- Post-failover validation

---

## 📝 What You Learned

- [x] How to promote standby to primary
- [x] Understanding timeline changes
- [x] Split-brain protection mechanisms
- [x] Post-failover verification steps
- [x] Reconfiguring old primary as standby
- [x] Real-world failover scenarios

---

## ➡️ Next Steps

### Practice More Failover Scenarios:
1. Failover with heavy write load
2. Failover with multiple standbys
3. Cascading replication failover
4. Automated failover with Patroni

### Explore Automation:
- **Patroni**: Automatic failover and HA
- **repmgr**: Replication management
- **pgBouncer**: Connection pooling during failover
- **HAProxy**: Load balancing with health checks

---

## ➡️ Next Scenario

**[Scenario 05: Network Interruption](./05-network-interruption.md)**

Learn what happens when network connectivity between primary and standby is lost, and how the system recovers.

```bash
cat scenarios/05-network-interruption.md
```
