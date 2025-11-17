# Scenario 06: Heavy Write Load - Performance Under Pressure

**Difficulty:** Intermediate  
**Duration:** 25-30 minutes  
**Prerequisites:** Scenarios 01-05 completed

## 🎯 Learning Objectives

- Test replication under sustained high write load
- Monitor WAL generation rates
- Observe lag behavior under pressure
- Understand standby performance impact
- Learn capacity planning metrics

## 📚 Background

Production databases experience varying write loads. Understanding how replication performs under heavy writes helps with:
- Capacity planning
- Performance tuning
- Identifying bottlenecks
- Setting alert thresholds

---

## Step 1: Baseline Performance

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT pg_current_wal_lsn() AS start_lsn;
\watch 5
EOF
```

---

## Step 2: Generate Heavy Write Load

```bash
echo "🔥 Generating heavy write load..."
docker exec -it postgres-primary psql -U postgres << 'EOF'
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
EOF
```

---

## Step 3: Monitor During Load

```bash
# Run in another terminal
watch -n 1 "docker exec -it postgres-primary psql -U postgres -t -c \"
SELECT 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
    replay_lag,
    state
FROM pg_stat_replication;
\""
```

---

## Step 4: Analyze WAL Generation

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) AS total_wal_generated;
EOF
```

---

## 🎓 Key Takeaways

✅ **Standby can handle heavy load** with proper resources  
✅ **Lag increases during bursts** but recovers quickly  
✅ **WAL generation rate** is key metric to monitor  
✅ **Async replication provides** good performance  
✅ **Resource monitoring essential** for capacity planning  

---

## ➡️ Next: [Scenario 07: Adding Second Standby](./07-second-standby.md)
