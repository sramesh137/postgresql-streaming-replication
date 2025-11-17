# Scenario 07: Adding a Second Standby - Multi-Replica Setup

**Difficulty:** Advanced  
**Duration:** 35-40 minutes  
**Prerequisites:** All previous scenarios completed

## 🎯 Learning Objectives

- Configure multiple standby servers
- Understand multi-standby replication topology
- Load balance reads across multiple replicas
- Monitor multiple replication streams
- Handle multiple standbys during failover

## 📚 Background

Multiple standbys provide:
- **More read capacity** - Distribute reads across multiple servers
- **Higher availability** - More failover options
- **Geographic distribution** - Place replicas in different regions
- **Workload isolation** - Dedicated replicas for different purposes

### Topology:
```
        Primary
       /       \
  Standby1  Standby2
```

---

## Step 1: Add Second Standby to docker-compose.yml

Create a new standby configuration and follow setup similar to first standby.

---

## Step 2: Create Replication Slot for Second Standby

```bash
docker exec -it postgres-primary psql -U postgres -c "
SELECT pg_create_physical_replication_slot('standby2_slot');
"
```

---

## Step 3: Take Base Backup for Second Standby

Similar to initial setup, use pg_basebackup.

---

## Step 4: Monitor Both Standbys

```bash
docker exec -it postgres-primary psql -U postgres << 'EOF'
SELECT 
    application_name,
    client_addr,
    state,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag,
    replay_lag
FROM pg_stat_replication
ORDER BY application_name;
EOF
```

---

## Step 5: Test Load Distribution

Query both standbys simultaneously and compare performance.

---

## 🎓 Key Takeaways

✅ **Multiple standbys scale reads** horizontally  
✅ **Each standby needs** its own replication slot  
✅ **All standbys receive** same WAL stream  
✅ **Independent lag** for each standby  
✅ **Load balancing** improves overall throughput  

---

## ➡️ Next: [Scenario 08: Synchronous Replication](./08-synchronous-replication.md)
