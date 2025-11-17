# Scenario 05: Network Interruption - Replication Recovery

**Difficulty:** Intermediate  
**Duration:** 20-25 minutes  
**Prerequisites:** Scenarios 01-04 completed

## 🎯 Learning Objectives

- Understand what happens when standby loses connection
- Learn how replication slots protect against data loss
- Observe WAL accumulation during disconnection
- Practice reconnection and catch-up procedures
- Monitor replication slot space usage

## 📚 Background

Network interruptions between primary and standby are common in production:
- Network outages
- Firewall changes
- Standby server restarts
- Maintenance windows

PostgreSQL handles this gracefully with **replication slots**, which ensure the primary keeps WAL files until standby catches up.

---

## Step 1: Baseline - Check Current State

```bash
echo "=== BASELINE STATE ==="
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;
EOF
```

---

## Step 2: Simulate Network Interruption

```bash
echo "🔴 Simulating network interruption..."
# Stop standby (simulates network disconnect)
docker-compose stop postgres-standby

echo "Standby disconnected!"
```

---

## Step 3: Generate WAL on Primary While Disconnected

```bash
echo "📝 Generating writes on primary..."
docker exec -it postgres-primary psql -U postgres << 'EOF'
-- Insert data while standby is offline
DO $$
BEGIN
    FOR i IN 1..5000 LOOP
        INSERT INTO orders (user_id, product, amount)
        VALUES (
            (random() * 10 + 1)::INTEGER,
            'Offline_Product_' || i,
            (random() * 500 + 50)::NUMERIC(10,2)
        );
        
        IF i % 1000 = 0 THEN
            RAISE NOTICE 'Inserted % orders', i;
        END IF;
    END LOOP;
END $$;

SELECT COUNT(*) FROM orders WHERE product LIKE 'Offline_Product_%';
EOF
```

---

## Step 4: Check WAL Accumulation

```bash
echo "📊 Checking WAL accumulation..."
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
    restart_lsn,
    pg_current_wal_lsn() AS current_lsn
FROM pg_replication_slots;
EOF
```

**Observe:** WAL retained is growing (primary keeping WAL for standby)

---

## Step 5: Reconnect Standby

```bash
echo "🔵 Reconnecting standby..."
docker-compose start postgres-standby

echo "Waiting for standby to start..."
sleep 10
```

---

## Step 6: Monitor Catch-Up Process

```bash
echo "📈 Monitoring catch-up..."
for i in {1..10}; do
    echo "--- Check $i ---"
    docker exec -it postgres-primary psql -U postgres -t -c "
        SELECT 
            state,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
        FROM pg_stat_replication;
    "
    sleep 2
done
```

---

## Step 7: Verify Data Consistency

```bash
# Count on primary
PRIMARY_COUNT=$(docker exec -it postgres-primary psql -U postgres -t -c "SELECT COUNT(*) FROM orders WHERE product LIKE 'Offline_Product_%';")

# Count on standby  
STANDBY_COUNT=$(docker exec -it postgres-standby psql -U postgres -t -c "SELECT COUNT(*) FROM orders WHERE product LIKE 'Offline_Product_%';")

echo "Primary count: $PRIMARY_COUNT"
echo "Standby count: $STANDBY_COUNT"

if [ "$PRIMARY_COUNT" = "$STANDBY_COUNT" ]; then
    echo "✅ Data consistency verified!"
else
    echo "⚠️  Counts don't match - still catching up"
fi
```

---

## 🎓 Key Takeaways

✅ **Replication slots prevent data loss** during disconnections  
✅ **WAL accumulates on primary** until standby catches up  
✅ **Catch-up is automatic** when standby reconnects  
✅ **No manual intervention needed** in most cases  
✅ **Monitor WAL disk space** during long disconnections  

---

## ➡️ Next: [Scenario 06: Heavy Write Load](./06-heavy-write-load.md)
