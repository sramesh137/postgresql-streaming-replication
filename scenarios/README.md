# Learning Scenarios for PostgreSQL Streaming Replication

This directory contains hands-on scenarios to help you master PostgreSQL streaming replication concepts through practical exercises.

## 📚 Scenarios Overview

### Beginner Level
1. **[Scenario 01: Understanding Replication Lag](./01-replication-lag.md)**
   - Insert bulk data and measure lag
   - Understand LSN positions
   - Monitor replication performance

2. **[Scenario 02: Read Load Distribution](./02-read-load-distribution.md)**
   - Connect application to both servers
   - Distribute reads to standby
   - Measure performance benefits

3. **[Scenario 03: Read-Only Testing](./03-read-only-enforcement.md)**
   - Test various write operations on standby
   - Understand transaction isolation
   - Learn read-only mode behavior

### Intermediate Level
4. **[Scenario 04: Manual Failover](./04-manual-failover.md)**
   - Simulate primary failure
   - Promote standby to primary
   - Understand failover process

5. **[Scenario 05: Network Interruption](./05-network-interruption.md)**
   - Disconnect standby from primary
   - Observe replication slot behavior
   - Reconnect and catch up

6. **[Scenario 06: Heavy Write Load](./06-heavy-write-load.md)**
   - Generate high transaction volume
   - Monitor WAL generation
   - Observe standby performance

### Advanced Level
7. **[Scenario 07: Adding Second Standby](./07-second-standby.md)**
   - Configure additional replica
   - Test multi-standby replication
   - Load balance reads across replicas

8. **[Scenario 08: Synchronous Replication](./08-synchronous-replication.md)**
   - Switch from async to sync mode
   - Measure performance impact
   - Understand durability guarantees

9. **[Scenario 09: Replication Monitoring](./09-monitoring-queries.md)**
   - Advanced monitoring queries
   - Create custom monitoring dashboard
   - Set up alerts for lag

10. **[Scenario 10: Disaster Recovery Drill](./10-disaster-recovery.md)**
    - Full primary failure simulation
    - Complete recovery procedure
    - Post-recovery verification

## 🎯 How to Use These Scenarios

### Step-by-Step Approach:
1. **Read the scenario** - Understand the objective
2. **Follow prerequisites** - Ensure your system is ready
3. **Execute commands** - Run step-by-step instructions
4. **Observe results** - Learn from the output
5. **Answer questions** - Test your understanding
6. **Experiment** - Try variations and edge cases

### Learning Path:
```
START HERE
    ↓
Scenario 01-03 (Beginner)
    ↓
Scenario 04-06 (Intermediate)
    ↓
Scenario 07-10 (Advanced)
    ↓
MASTERY!
```

## 📝 Tracking Your Progress

Create a progress file to track completed scenarios:

```bash
# Copy this template
cp scenarios/progress-template.md scenarios/my-progress.md

# Update after each scenario
```

## 🚀 Quick Start

### Your Current Status:
✅ Basic setup completed  
✅ Replication verified  
✅ Ready for scenarios!

### Next Recommended Scenario:
**[Scenario 01: Understanding Replication Lag](./01-replication-lag.md)**

This scenario will help you understand how data flows from primary to standby and how to measure replication performance.

```bash
# Start with scenario 01
cat scenarios/01-replication-lag.md
```

## 💡 Tips for Maximum Learning

1. **Don't rush** - Take time to understand each concept
2. **Experiment freely** - Your setup is in Docker, easy to reset
3. **Take notes** - Document what you learn
4. **Ask questions** - Use the explanation sections
5. **Modify scenarios** - Try different parameters
6. **Break things** - Learn from failures

## 🔧 Resetting Your Environment

If you need to start fresh between scenarios:

```bash
# Stop and remove everything
docker-compose down -v

# Start fresh
docker-compose up -d
bash scripts/setup-replication.sh
```

## 📚 Additional Resources

- **TUTORIAL.md** - Complete theoretical guide
- **SETUP_AND_TEST_LOGS.md** - Your initial setup logs
- **README.md** - Project overview
- **scripts/** - Utility scripts for common tasks

---

Happy Learning! 🎓
