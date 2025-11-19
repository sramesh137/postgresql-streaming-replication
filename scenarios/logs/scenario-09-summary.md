# Scenario 09 - Advanced Monitoring: Quick Reference

**Status:** ✅ COMPLETED  
**Date:** November 19, 2025  
**Duration:** 35 minutes

---

## What We Built

### 1. Monitoring Scripts
- **check-replication.sh** - Automated health check script
  - Container status
  - Replication connections and lag
  - WAL statistics
  - Slot status
  - Traffic light health summary (OK/WARNING/CRITICAL)

### 2. Database Objects Created
- **replication_dashboard** VIEW - Comprehensive metrics view
- **replication_metrics_history** TABLE - Historical tracking with indexes
- **load_test** TABLE - Used for testing replication under load

### 3. Key Metrics Monitored

| Metric | Purpose | Alert Threshold |
|--------|---------|-----------------|
| **Connection State** | Is standby connected? | CRITICAL if != 'streaming' |
| **Replication Lag** | How far behind? | WARNING > 10MB, CRITICAL > 100MB |
| **WAL Directory Size** | Disk usage | WARNING > 5GB, CRITICAL > 10GB |
| **Active Slots** | Standbys connected | CRITICAL if 0, WARNING if < expected |
| **Write/Flush/Replay Lag** | Where is bottleneck? | INFO for diagnosis |

---

## Test Results

### Current Cluster Status
```
✅ Primary: postgres-primary (Up 3 days, healthy)
✅ Standby 1: postgres-standby (sync mode, 0 lag)
✅ Standby 2: postgres-standby2 (async mode, 0 lag)
✅ WAL Size: 1024 MB (66 files) - Normal
✅ Slots: 2 active, 0 bytes retained
```

### Load Test Results (50,000 row insert)
- **Before:** 0 bytes lag
- **During:** Temporary spike (< 1MB)
- **After:** 0 bytes lag within 2 seconds
- **Write lag:** ~0.16ms (excellent)
- **Replay lag:** ~0.48ms (excellent)

**Conclusion:** Replication handles high write volume efficiently with sub-millisecond lag.

---

## Usage Examples

### Quick Health Check
```bash
./scripts/check-replication.sh
```

### Detailed Replication Status
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT * FROM replication_dashboard;
"
```

### Check WAL Statistics
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT pg_size_pretty(SUM(size)) AS total_wal,
       COUNT(*) AS file_count
FROM pg_ls_waldir();
"
```

### View Replication Slots
```bash
docker exec postgres-primary psql -U postgres -c "
SELECT slot_name, active, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
"
```

---

## Interview Talking Points

### 1. Monitoring Strategy
> *"I implement multi-layer monitoring covering connections, lag metrics, WAL growth, and slot activity. This provides early warning before issues impact users."*

### 2. Alert Thresholds
> *"I use tiered alerting: INFO (> 1MB lag - log only), WARNING (> 10MB - email ops), CRITICAL (> 100MB or disconnected - page DBA). Thresholds based on write volume: 10MB = ~30 seconds of writes."*

### 3. WAL Management
> *"WAL accumulation is dangerous - inactive slots retain WAL forever. I monitor slot activity and have a policy to drop slots inactive > 7 days after confirming standby is unrecoverable."*

### 4. Historical Tracking
> *"I log metrics every 5 minutes to identify trends, support RCA, and capacity planning. Last quarter, metrics showed increasing lag trend - upgraded standby SSD before hitting limits."*

### 5. Automation
> *"Manual monitoring doesn't scale. I automated health checks into monitoring stack (Prometheus/Grafana) with PagerDuty integration. Reduced manual checking from hourly to zero."*

---

## Production Recommendations

### Monitoring Stack Integration
```yaml
# Prometheus exporter config
scrape_configs:
  - job_name: 'postgres-replication'
    static_configs:
      - targets: ['postgres-primary:9187']
    scrape_interval: 30s
```

### Cron Jobs
```bash
# Every minute: Health check
* * * * * /opt/scripts/check-replication.sh || send_alert.sh

# Every 5 minutes: Log metrics
*/5 * * * * psql -U postgres -c "SELECT log_replication_metrics();"

# Daily: Cleanup old metrics (keep 90 days)
0 2 * * * psql -U postgres -c "DELETE FROM replication_metrics_history WHERE recorded_at < now() - interval '90 days';"
```

### Alert Routing
- **CRITICAL** → PagerDuty → DBA on-call
- **WARNING** → Email → Ops team
- **INFO** → Logs → Review weekly

---

## Common Troubleshooting

### High Lag Issues
1. **Identify lag type**: write_lag vs flush_lag vs replay_lag
   - Write lag = network issue
   - Flush lag = disk I/O on standby
   - Replay lag = CPU on standby

2. **Check standby resources**: CPU, disk I/O, network
3. **Look for blockers**: Long queries on standby
4. **Review primary**: Write burst or sustained high volume?

### Disconnected Standby
1. **Check standby logs**: Connection errors?
2. **Verify network**: Can standby reach primary?
3. **Check slot retention**: Is WAL accumulating?
4. **Decision**: Rebuild standby or wait for reconnection?

### WAL Accumulation
1. **Identify inactive slots**: `pg_replication_slots WHERE active=false`
2. **Check retention**: How much WAL per slot?
3. **Verify standby status**: Down permanently or temporary?
4. **Action**: Drop slot if unrecoverable, archive WAL if needed

---

## Files Created

```
scripts/
  check-replication.sh          # Automated health check script

scenarios/logs/
  scenario-09-execution.md      # Full execution guide with interview prep

temp_monitoring.sql              # Monitoring queries (archived)
```

---

## Key Learnings

✅ **Monitoring must be automated** - Manual checks don't scale  
✅ **Alert thresholds matter** - Too sensitive = alert fatigue, too lenient = missed incidents  
✅ **Historical data is valuable** - Trends, RCA, capacity planning  
✅ **WAL management is critical** - Inactive slots can crash primary  
✅ **Multi-layer monitoring** - No single metric tells the full story  

---

## Next Steps

1. ✅ Scenario 09 completed - Advanced monitoring implemented
2. 🔄 **Next:** Scenario 10 - Disaster Recovery Drill (failover testing)
3. ⏳ Scenario 11 - Barman hands-on (backup server setup)
4. ⏳ Scenario 12 - PITR testing (point-in-time recovery)

---

**Status:** Production-ready monitoring established! Ready for disaster recovery testing. 🚀
