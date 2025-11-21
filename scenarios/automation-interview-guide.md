# PostgreSQL Automation - Interview Guide

**Infrastructure as Code & DevOps for PostgreSQL DBAs**

---

## 🎯 What Interviewers Want to See

**Key Areas:**
1. **Backup automation** - Scheduled, tested, monitored
2. **Monitoring & alerting** - Proactive problem detection
3. **Configuration management** - Ansible, Terraform, etc.
4. **CI/CD for database changes** - Schema migrations, testing
5. **Self-healing systems** - Automatic recovery, failover
6. **Capacity planning** - Auto-scaling, predictive analytics
7. **Operational tasks** - VACUUM, REINDEX, statistics updates

---

## 🔧 1. Backup Automation with Barman

### Setup Barman (Backup and Recovery Manager)

**Architecture:**
```
┌──────────────┐         ┌──────────────┐
│  PostgreSQL  │         │    Barman    │
│   Primary    │────────>│    Server    │
│              │ WAL     │              │
└──────────────┘ Archive └──────────────┘
       │                         │
       │                         ↓
       │                  ┌──────────────┐
       │                  │   Backups    │
       │                  │  - Daily     │
       └─────────────────>│  - WAL       │
         Replication      │  - 30 days   │
                          └──────────────┘
```

**Installation:**
```bash
# On Barman server
sudo apt-get install barman barman-cli

# On PostgreSQL server
sudo apt-get install barman-cli
```

**Configuration:**

```ini
# /etc/barman.conf (Barman server)
[barman]
barman_home = /var/lib/barman
barman_user = barman
log_file = /var/log/barman/barman.log
log_level = INFO
compression = gzip

[primary]
description = "Production Primary"
ssh_command = ssh postgres@primary-host
conninfo = host=primary-host user=barman dbname=postgres
backup_method = postgres
backup_options = concurrent_backup
archiver = on
streaming_archiver = on
slot_name = barman_slot
streaming_conninfo = host=primary-host user=streaming_barman
path_prefix = "/usr/pgsql-15/bin"
backup_directory = /var/lib/barman/primary
retention_policy = RECOVERY WINDOW OF 30 DAYS
```

**Setup on PostgreSQL:**
```sql
-- Create barman user
CREATE USER barman SUPERUSER PASSWORD 'barman_password';
CREATE USER streaming_barman REPLICATION PASSWORD 'streaming_password';

-- Configure pg_hba.conf
host all barman 0.0.0.0/0 md5
host replication streaming_barman 0.0.0.0/0 md5

-- Create replication slot
SELECT pg_create_physical_replication_slot('barman_slot');

-- Configure archiving
ALTER SYSTEM SET archive_mode = on;
ALTER SYSTEM SET archive_command = 'barman-wal-archive primary %p';
SELECT pg_reload_conf();
```

**Automated Backup Schedule:**
```bash
# /etc/cron.d/barman
# Daily full backup at 2 AM
0 2 * * * barman /usr/bin/barman backup primary --wait

# Check backup every hour
0 * * * * barman /usr/bin/barman check primary

# Daily maintenance
30 3 * * * barman /usr/bin/barman cron
```

**Backup Script with Notifications:**
```bash
#!/bin/bash
# /usr/local/bin/barman-backup-with-alert.sh

BACKUP_NAME="primary"
SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK"

# Run backup
/usr/bin/barman backup $BACKUP_NAME --wait

# Check status
if [ $? -eq 0 ]; then
    # Success
    BACKUP_ID=$(barman list-backup $BACKUP_NAME | head -1 | awk '{print $1}')
    SIZE=$(barman show-backup $BACKUP_NAME $BACKUP_ID | grep "Size:" | awk '{print $2}')
    
    MESSAGE="✅ Backup successful: $BACKUP_NAME ($SIZE)"
    curl -X POST -H 'Content-type: application/json' \
         --data "{\"text\":\"$MESSAGE\"}" \
         $SLACK_WEBHOOK
else
    # Failure
    MESSAGE="❌ Backup failed: $BACKUP_NAME"
    curl -X POST -H 'Content-type: application/json' \
         --data "{\"text\":\"$MESSAGE\"}" \
         $SLACK_WEBHOOK
    
    # Page on-call engineer
    # (integrate with PagerDuty API)
fi

# Delete old backups
/usr/bin/barman delete $BACKUP_NAME oldest
```

---

## 📊 2. Monitoring Automation

### Prometheus + Grafana + AlertManager

**Architecture:**
```
┌──────────────┐
│  PostgreSQL  │
└──────┬───────┘
       │ Metrics
       ↓
┌──────────────────┐
│ postgres_exporter│
└──────┬───────────┘
       │ HTTP :9187
       ↓
┌──────────────────┐     ┌──────────────┐
│   Prometheus     │────>│  Grafana     │
│   (Storage)      │     │  (Dashboard) │
└──────┬───────────┘     └──────────────┘
       │ Alerts
       ↓
┌──────────────────┐     ┌──────────────┐
│  AlertManager    │────>│  PagerDuty   │
└──────────────────┘     │  Slack       │
                         └──────────────┘
```

**postgres_exporter Setup:**
```yaml
# docker-compose.yml
version: '3.8'

services:
  postgres-exporter:
    image: quay.io/prometheuscommunity/postgres-exporter:latest
    ports:
      - "9187:9187"
    environment:
      DATA_SOURCE_NAME: "postgresql://exporter:password@postgres:5432/postgres?sslmode=disable"
    restart: always
```

**Prometheus Configuration:**
```yaml
# /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'postgresql'
    static_configs:
      - targets:
          - 'primary:9187'
          - 'standby1:9187'
          - 'standby2:9187'
        labels:
          cluster: 'production'

rule_files:
  - 'postgresql_alerts.yml'

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - 'alertmanager:9093'
```

**Alert Rules:**
```yaml
# /etc/prometheus/postgresql_alerts.yml
groups:
  - name: postgresql
    interval: 30s
    rules:
      # Database is down
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL instance {{ $labels.instance }} is down"
          description: "{{ $labels.instance }} has been down for more than 1 minute"

      # Replication lag
      - alert: ReplicationLagHigh
        expr: pg_replication_lag_seconds > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Replication lag on {{ $labels.instance }}"
          description: "Replication lag is {{ $value }} seconds"

      # Too many connections
      - alert: TooManyConnections
        expr: pg_stat_database_numbackends / pg_settings_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High connection count on {{ $labels.instance }}"
          description: "{{ $value | humanizePercentage }} of max connections used"

      # Disk space low
      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes{mountpoint="/var/lib/postgresql"} / node_filesystem_size_bytes) < 0.2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk space low on {{ $labels.instance }}"
          description: "Only {{ $value | humanizePercentage }} disk space remaining"

      # Long-running transactions
      - alert: LongRunningTransaction
        expr: pg_stat_activity_max_tx_duration{state!="idle"} > 3600
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Long-running transaction on {{ $labels.instance }}"
          description: "Transaction running for {{ $value }} seconds"

      # Table bloat high
      - alert: TableBloatHigh
        expr: pg_bloat_table_bloat_ratio > 0.5
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "High table bloat on {{ $labels.table }}"
          description: "Table {{ $labels.table }} has {{ $value | humanizePercentage }} bloat"

      # Checkpoint taking too long
      - alert: CheckpointTooSlow
        expr: rate(pg_stat_bgwriter_checkpoint_write_time[5m]) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Slow checkpoints on {{ $labels.instance }}"
          description: "Checkpoints taking too long"
```

**AlertManager Configuration:**
```yaml
# /etc/alertmanager/alertmanager.yml
global:
  resolve_timeout: 5m
  slack_api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK'

route:
  receiver: 'default'
  group_by: ['alertname', 'cluster']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # Critical alerts to PagerDuty
    - match:
        severity: critical
      receiver: 'pagerduty'
      continue: true

    # All alerts to Slack
    - match:
        severity: '.*'
      receiver: 'slack'

receivers:
  - name: 'default'
    email_configs:
      - to: 'dba-team@company.com'
        from: 'alertmanager@company.com'

  - name: 'slack'
    slack_configs:
      - channel: '#db-alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

  - name: 'pagerduty'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_KEY'
```

---

## 🤖 3. Configuration Management with Ansible

### PostgreSQL Installation & Configuration

**Directory Structure:**
```
postgres-ansible/
├── inventory/
│   ├── production
│   └── staging
├── group_vars/
│   ├── all.yml
│   ├── primary.yml
│   └── standby.yml
├── roles/
│   ├── postgresql/
│   │   ├── tasks/
│   │   │   ├── main.yml
│   │   │   ├── install.yml
│   │   │   ├── config.yml
│   │   │   └── replication.yml
│   │   ├── templates/
│   │   │   ├── postgresql.conf.j2
│   │   │   ├── pg_hba.conf.j2
│   │   │   └── recovery.conf.j2
│   │   └── handlers/
│   │       └── main.yml
│   └── patroni/
│       └── ...
└── playbooks/
    ├── setup-primary.yml
    ├── setup-standby.yml
    └── upgrade.yml
```

**Inventory:**
```ini
# inventory/production
[primary]
primary ansible_host=10.0.1.10

[standby]
standby1 ansible_host=10.0.1.11
standby2 ansible_host=10.0.1.12

[postgres:children]
primary
standby

[postgres:vars]
ansible_user=ubuntu
ansible_become=yes
postgresql_version=15
```

**Variables:**
```yaml
# group_vars/all.yml
postgresql_version: 15
postgresql_data_dir: "/var/lib/postgresql/{{ postgresql_version }}/main"
postgresql_max_connections: 200
postgresql_shared_buffers: "8GB"
postgresql_effective_cache_size: "24GB"
postgresql_work_mem: "64MB"
postgresql_maintenance_work_mem: "2GB"

# group_vars/primary.yml
postgresql_wal_level: replica
postgresql_max_wal_senders: 10
postgresql_max_replication_slots: 10
postgresql_archive_mode: on
postgresql_archive_command: "barman-wal-archive primary %p"

# group_vars/standby.yml
postgresql_hot_standby: on
```

**Playbook:**
```yaml
# playbooks/setup-primary.yml
---
- name: Setup PostgreSQL Primary
  hosts: primary
  roles:
    - postgresql

  tasks:
    - name: Create replication user
      postgresql_user:
        name: replicator
        password: "{{ replicator_password }}"
        role_attr_flags: REPLICATION
      become_user: postgres

    - name: Create replication slot
      postgresql_query:
        query: "SELECT pg_create_physical_replication_slot('{{ item }}_slot')"
        db: postgres
      loop: "{{ groups['standby'] }}"
      become_user: postgres
      ignore_errors: yes

    - name: Configure pg_hba for replication
      postgresql_pg_hba:
        dest: "{{ postgresql_config_dir }}/pg_hba.conf"
        contype: host
        databases: replication
        users: replicator
        source: "{{ item }}"
        method: md5
      loop: "{{ groups['standby'] | map('extract', hostvars, 'ansible_host') | list }}"
      notify: reload postgresql
```

**Configuration Template:**
```jinja2
# templates/postgresql.conf.j2
# PostgreSQL {{ postgresql_version }} Configuration
# Generated by Ansible

# --- CONNECTIONS ---
listen_addresses = '*'
port = 5432
max_connections = {{ postgresql_max_connections }}

# --- MEMORY ---
shared_buffers = {{ postgresql_shared_buffers }}
effective_cache_size = {{ postgresql_effective_cache_size }}
work_mem = {{ postgresql_work_mem }}
maintenance_work_mem = {{ postgresql_maintenance_work_mem }}

# --- WAL ---
{% if 'primary' in group_names %}
wal_level = {{ postgresql_wal_level }}
max_wal_senders = {{ postgresql_max_wal_senders }}
max_replication_slots = {{ postgresql_max_replication_slots }}
archive_mode = {{ postgresql_archive_mode }}
archive_command = '{{ postgresql_archive_command }}'
{% endif %}

# --- REPLICATION ---
{% if 'standby' in group_names %}
hot_standby = on
hot_standby_feedback = off
{% endif %}

# --- QUERY PLANNER ---
random_page_cost = 1.1  # SSD
effective_io_concurrency = 200

# --- LOGGING ---
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_line_prefix = '%t [%p]: user=%u,db=%d,app=%a,client=%h '

# --- AUTOVACUUM ---
autovacuum = on
autovacuum_max_workers = 3
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05
```

**Run Playbook:**
```bash
# Setup primary
ansible-playbook -i inventory/production playbooks/setup-primary.yml

# Setup standbys
ansible-playbook -i inventory/production playbooks/setup-standby.yml

# Upgrade all servers
ansible-playbook -i inventory/production playbooks/upgrade.yml --extra-vars "new_version=16"
```

---

## 🔄 4. Schema Migration Automation

### Flyway for Database Migrations

**Project Structure:**
```
migrations/
├── sql/
│   ├── V1__initial_schema.sql
│   ├── V2__add_orders_table.sql
│   ├── V3__add_indexes.sql
│   ├── V4__alter_customers.sql
│   └── R__create_views.sql
├── flyway.conf
└── migrate.sh
```

**flyway.conf:**
```ini
flyway.url=jdbc:postgresql://localhost:5432/production
flyway.user=flyway
flyway.password=flyway_password
flyway.schemas=public
flyway.locations=filesystem:sql
flyway.baselineOnMigrate=true
flyway.validateOnMigrate=true
```

**Migration Files:**
```sql
-- V1__initial_schema.sql
CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- V2__add_orders_table.sql
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(id),
    total NUMERIC(10,2) NOT NULL,
    status VARCHAR(50) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

-- V3__add_indexes.sql
CREATE INDEX idx_orders_customer_id ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_created_at ON orders(created_at);

-- R__create_views.sql (repeatable)
CREATE OR REPLACE VIEW customer_orders AS
SELECT 
    c.id,
    c.email,
    c.name,
    COUNT(o.id) AS order_count,
    SUM(o.total) AS total_spent
FROM customers c
LEFT JOIN orders o ON c.id = o.customer_id
GROUP BY c.id;
```

**Automation Script:**
```bash
#!/bin/bash
# migrate.sh

set -e

ENV=${1:-staging}
BACKUP_BEFORE=${2:-true}

echo "Running migrations on $ENV"

# Load environment config
source ./environments/$ENV.env

# Backup before migration
if [ "$BACKUP_BEFORE" = "true" ]; then
    echo "Creating backup..."
    pg_dump -h $DB_HOST -U $DB_USER -Fc $DB_NAME > backup_$(date +%Y%m%d_%H%M%S).dump
fi

# Run migration
flyway -configFiles=environments/$ENV.conf migrate

# Verify
flyway -configFiles=environments/$ENV.conf validate

echo "Migration completed successfully"

# Run tests
if [ "$ENV" = "staging" ]; then
    echo "Running integration tests..."
    ./run_tests.sh
fi
```

**CI/CD Integration (GitHub Actions):**
```yaml
# .github/workflows/database-migration.yml
name: Database Migration

on:
  push:
    branches: [main]
    paths:
      - 'migrations/**'

jobs:
  test-migration:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v2

      - name: Setup Flyway
        run: |
          wget -qO- https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/9.22.0/flyway-commandline-9.22.0-linux-x64.tar.gz | tar xvz
          sudo ln -s `pwd`/flyway-9.22.0/flyway /usr/local/bin

      - name: Run migration on test database
        run: flyway migrate -url=jdbc:postgresql://localhost:5432/test -user=postgres -password=postgres

      - name: Verify migration
        run: flyway validate -url=jdbc:postgresql://localhost:5432/test -user=postgres -password=postgres

  deploy-staging:
    needs: test-migration
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Deploy to staging
        run: |
          flyway migrate -configFiles=environments/staging.conf
        env:
          STAGING_DB_PASSWORD: ${{ secrets.STAGING_DB_PASSWORD }}

  deploy-production:
    needs: deploy-staging
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v2
      
      - name: Create backup
        run: |
          pg_dump -h $PROD_HOST -U flyway -Fc production > backup.dump
        env:
          PROD_HOST: ${{ secrets.PROD_DB_HOST }}
          PGPASSWORD: ${{ secrets.PROD_DB_PASSWORD }}

      - name: Deploy to production
        run: |
          flyway migrate -configFiles=environments/production.conf
        env:
          PROD_DB_PASSWORD: ${{ secrets.PROD_DB_PASSWORD }}

      - name: Notify Slack
        uses: 8398a7/action-slack@v3
        with:
          status: ${{ job.status }}
          text: 'Database migration ${{ job.status }}'
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK }}
```

---

## 🔧 5. Maintenance Automation

### Automated VACUUM & ANALYZE

**Script:**
```bash
#!/bin/bash
# /usr/local/bin/smart-vacuum.sh

DB_NAME="production"
DB_USER="postgres"
SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK"

# Log file
LOG_FILE="/var/log/postgresql/smart-vacuum-$(date +%Y%m%d).log"

echo "=== Smart VACUUM started at $(date) ===" | tee -a $LOG_FILE

# Find tables needing VACUUM
psql -U $DB_USER -d $DB_NAME -t -c "
SELECT 
    schemaname || '.' || tablename AS table_name,
    n_dead_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
  AND n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0) > 10
ORDER BY n_dead_tup DESC;
" | while read table dead_tuples dead_pct; do
    echo "VACUUM ANALYZE $table (dead: $dead_tuples, $dead_pct%)" | tee -a $LOG_FILE
    
    START=$(date +%s)
    psql -U $DB_USER -d $DB_NAME -c "VACUUM ANALYZE $table;" 2>&1 | tee -a $LOG_FILE
    END=$(date +%s)
    DURATION=$((END - START))
    
    echo "Completed in ${DURATION}s" | tee -a $LOG_FILE
done

echo "=== Smart VACUUM completed at $(date) ===" | tee -a $LOG_FILE

# Send summary to Slack
TABLES_VACUUMED=$(grep -c "VACUUM ANALYZE" $LOG_FILE)
curl -X POST -H 'Content-type: application/json' \
     --data "{\"text\":\"✅ Smart VACUUM completed: $TABLES_VACUUMED tables processed\"}" \
     $SLACK_WEBHOOK
```

**Cron Schedule:**
```cron
# /etc/cron.d/postgres-maintenance

# Smart VACUUM daily at 2 AM
0 2 * * * postgres /usr/local/bin/smart-vacuum.sh

# ANALYZE all tables (lightweight) every 6 hours
0 */6 * * * postgres psql -U postgres -d production -c "ANALYZE;"

# REINDEX bloated indexes weekly (Saturday 3 AM)
0 3 * * 6 postgres /usr/local/bin/reindex-bloated.sh

# Update pg_stat_statements (reset monthly)
0 0 1 * * postgres psql -U postgres -d production -c "SELECT pg_stat_statements_reset();"
```

### REINDEX Bloated Indexes

```bash
#!/bin/bash
# /usr/local/bin/reindex-bloated.sh

DB_NAME="production"
DB_USER="postgres"

# Find bloated indexes (>50% bloat)
psql -U $DB_USER -d $DB_NAME -t -c "
SELECT 
    schemaname || '.' || indexname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0  -- Unused
   OR pg_relation_size(indexrelid) > 100000000  -- >100MB
ORDER BY pg_relation_size(indexrelid) DESC;
" | while read index size; do
    echo "REINDEX $index (size: $size)"
    
    # REINDEX CONCURRENTLY (PostgreSQL 12+)
    psql -U $DB_USER -d $DB_NAME -c "REINDEX INDEX CONCURRENTLY $index;"
    
    if [ $? -eq 0 ]; then
        echo "✅ $index reindexed successfully"
    else
        echo "❌ $index reindex failed"
    fi
done
```

---

## 📈 6. Capacity Planning Automation

### Predictive Disk Space Monitoring

```python
#!/usr/bin/env python3
# /usr/local/bin/capacity-forecast.py

import psycopg2
import pandas as pd
from datetime import datetime, timedelta
import json

DB_CONFIG = {
    'host': 'localhost',
    'database': 'production',
    'user': 'postgres',
    'password': 'password'
}

def get_database_size_history():
    """Fetch database size history from monitoring DB"""
    conn = psycopg2.connect(**DB_CONFIG)
    cur = conn.cursor()
    
    cur.execute("""
        SELECT date, size_bytes
        FROM database_size_history
        WHERE date >= NOW() - INTERVAL '90 days'
        ORDER BY date
    """)
    
    data = cur.fetchall()
    conn.close()
    
    return pd.DataFrame(data, columns=['date', 'size_bytes'])

def forecast_capacity(df, days=30):
    """Forecast disk usage for next N days"""
    df['days'] = (df['date'] - df['date'].min()).dt.days
    
    # Linear regression
    from sklearn.linear_model import LinearRegression
    model = LinearRegression()
    model.fit(df[['days']], df['size_bytes'])
    
    # Predict future
    future_days = df['days'].max() + days
    predicted_size = model.predict([[future_days]])[0]
    
    # Daily growth rate
    daily_growth = model.coef_[0]
    
    return {
        'current_size_gb': df['size_bytes'].iloc[-1] / (1024**3),
        'predicted_size_gb': predicted_size / (1024**3),
        'daily_growth_gb': daily_growth / (1024**3),
        'days_until_full': (DISK_SIZE - df['size_bytes'].iloc[-1]) / daily_growth
    }

def send_alert(forecast):
    """Send alert if capacity issues predicted"""
    if forecast['days_until_full'] < 30:
        # Alert: Disk full in < 30 days
        message = f"""
        ⚠️ Capacity Alert
        Current: {forecast['current_size_gb']:.1f} GB
        Predicted (30 days): {forecast['predicted_size_gb']:.1f} GB
        Daily growth: {forecast['daily_growth_gb']:.2f} GB
        Days until full: {forecast['days_until_full']:.0f}
        Action: Plan disk expansion
        """
        # Send to Slack/PagerDuty
        print(message)

if __name__ == '__main__':
    df = get_database_size_history()
    forecast = forecast_capacity(df, days=30)
    send_alert(forecast)
    print(json.dumps(forecast, indent=2))
```

**Cron Schedule:**
```cron
# Run capacity forecast daily
0 8 * * * python3 /usr/local/bin/capacity-forecast.py
```

---

## 💼 Interview Questions & Answers

### Q1: "How do you automate PostgreSQL backups and ensure they're working?"

**Answer:**
> "I use Barman for automated backups with a comprehensive approach:
>
> **Backup Strategy:**
> 1. **Daily full backups** at 2 AM (low traffic)
> 2. **Continuous WAL archiving** (streaming + archive_command)
> 3. **30-day retention** policy
> 4. **Compression** (gzip, 70% space savings)
>
> **Automation:**
> ```bash
> # /etc/cron.d/barman
> 0 2 * * * barman /usr/bin/barman backup primary --wait
> 0 3 * * * barman /usr/bin/barman delete primary oldest
> 0 * * * * barman /usr/bin/barman check primary
> ```
>
> **Verification (Critical!):**
> ```bash
> # Monthly restore test (first Sunday 4 AM)
> 0 4 1-7 * 0 /usr/local/bin/test-restore.sh
> ```
>
> **Test Restore Script:**
> ```bash
> #!/bin/bash
> # Restore to temporary instance
> barman recover primary latest /tmp/restore-test --remote-ssh-command "ssh postgres@test-server"
>
> # Start PostgreSQL
> ssh postgres@test-server "pg_ctl start -D /tmp/restore-test"
>
> # Run verification queries
> psql -h test-server -U postgres -c "SELECT count(*) FROM orders;"
>
> # Cleanup
> ssh postgres@test-server "pg_ctl stop -D /tmp/restore-test && rm -rf /tmp/restore-test"
>
> # Report results to Slack
> ```
>
> **Monitoring:**
> - Prometheus metrics: `barman_backup_status`
> - Alert if: No successful backup in 25 hours
> - Alert if: Restore test fails
> - Monthly report: Backup size trends, restore times
>
> **Key Point:** I discovered backups were silently failing for 2 weeks once—restore tests caught it before disaster!"

---

### Q2: "Explain your approach to monitoring PostgreSQL in production."

**Answer:**
> "I use a layered monitoring approach with Prometheus + Grafana + AlertManager:
>
> **Layer 1: Infrastructure Metrics**
> - CPU, memory, disk, network
> - OS-level monitoring (node_exporter)
> - Alert: > 80% utilization for 5 minutes
>
> **Layer 2: PostgreSQL Metrics**
> - Connection count (pg_stat_activity)
> - Replication lag (pg_stat_replication)
> - Transaction rate (pg_stat_database)
> - Cache hit ratio (should be > 99%)
> - Checkpoint frequency
> - Table/index bloat
>
> **Layer 3: Query Performance**
> - pg_stat_statements: Top 20 slow queries
> - Long-running transactions (> 5 minutes)
> - Lock contention (wait_event_type = 'Lock')
> - Deadlocks
>
> **Layer 4: Business Metrics**
> - Order processing rate
> - User login success rate
> - API response times
> - Custom SQL queries (SELECT count(*) FROM critical_table)
>
> **Alert Priorities:**
>
> *P1 (Critical - page immediately):*
> - Database down
> - Replication broken
> - Disk > 90% full
> - Connection pool exhausted
>
> *P2 (High - alert on-call, no page):*
> - Replication lag > 10 seconds
> - Long-running transaction > 1 hour
> - Cache hit ratio < 95%
> - Checkpoint taking > 5 minutes
>
> *P3 (Medium - email):*
> - Table bloat > 50%
> - Unused index (idx_scan = 0 for 7 days)
> - Query > 1 second
>
> **Dashboards:**
> 1. **Overview:** Cluster health, connections, TPS
> 2. **Replication:** Lag, WAL generation, slots
> 3. **Performance:** Top queries, wait events, cache hit ratio
> 4. **Capacity:** Disk trends, connection trends, growth forecast
>
> **Example Alert:**
> ```yaml
> - alert: ReplicationLagCritical
>   expr: pg_replication_lag_seconds > 60
>   for: 2m
>   labels:
>     severity: critical
>   annotations:
>     summary: 'Replication lag {{ $value }}s on {{ $labels.instance }}'
>     runbook: 'Check standby health, network, long-running queries'
> ```
>
> **Result:** Average detection time: 30 seconds. No undetected outages in 18 months."

---

### Q3: "How do you handle schema migrations in a CI/CD pipeline?"

**Answer:**
> "I use Flyway with a rigorous CI/CD process:
>
> **Development Workflow:**
> 1. Developer writes migration: `V5__add_orders_index.sql`
> 2. Commit to feature branch
> 3. CI runs migration on test database
> 4. Automated tests verify schema changes
> 5. Code review checks migration quality
> 6. Merge to main → deploy to staging
> 7. Smoke tests on staging
> 8. Manual approval → deploy to production
>
> **CI/CD Pipeline (GitHub Actions):**
> ```yaml
> Test → Staging → Production
>  ↓       ↓         ↓
> Auto   Auto    Manual Approval
> ```
>
> **Safety Checks:**
>
> *1. Backward Compatibility:*
> ```sql
> -- ❌ Bad: Breaks old code
> ALTER TABLE orders DROP COLUMN old_field;
>
> -- ✅ Good: Phased approach
> -- V5: Add new field
> ALTER TABLE orders ADD COLUMN new_field VARCHAR(255);
>
> -- V6: (2 weeks later, after code deploy)
> -- Deploy code using new_field
>
> -- V7: (2 weeks later)
> ALTER TABLE orders DROP COLUMN old_field;
> ```
>
> *2. Zero-Downtime Migrations:*
> ```sql
> -- ❌ Bad: Locks table
> CREATE INDEX idx_orders_status ON orders(status);
>
> -- ✅ Good: CONCURRENTLY
> CREATE INDEX CONCURRENTLY idx_orders_status ON orders(status);
> ```
>
> *3. Rollback Strategy:*
> - Each migration has rollback SQL (U5__rollback.sql)
> - Test rollback in staging
> - Keep window open for quick rollback (15 minutes)
>
> *4. Large Data Migrations:*
> ```sql
> -- ❌ Bad: Locks table for hours
> UPDATE orders SET new_field = old_field;
>
> -- ✅ Good: Batch updates
> DO $$
> DECLARE batch_size INT := 10000;
> BEGIN
>   LOOP
>     UPDATE orders SET new_field = old_field
>     WHERE id IN (
>       SELECT id FROM orders WHERE new_field IS NULL LIMIT batch_size
>     );
>     EXIT WHEN NOT FOUND;
>     COMMIT;
>     PERFORM pg_sleep(0.1);
>   END LOOP;
> END $$;
> ```
>
> **Monitoring During Migration:**
> - Watch connection count (spike = blocking)
> - Monitor lock waits
> - Track migration duration
> - Alert team if migration > expected time
>
> **Production Deployment:**
> ```bash
> # 1. Backup
> barman backup primary --wait
>
> # 2. Run migration
> flyway migrate -configFiles=prod.conf
>
> # 3. Verify
> flyway validate
> SELECT count(*) FROM orders;  # Sanity check
>
> # 4. Monitor
> # Watch for errors, slow queries, connection spikes
>
> # 5. Rollback if needed (within 15 min window)
> flyway undo -configFiles=prod.conf
> ```
>
> **Real Example:**
> We had a migration that took 2 hours in staging but would take 6 hours in production (10× data). Solution: Split into 3 smaller migrations, ran over 3 nights, zero downtime."

---

### Q4: "Describe your automation for routine PostgreSQL maintenance tasks."

**Answer:**
> "I automate all routine maintenance with smart scheduling and monitoring:
>
> **Daily Tasks:**
>
> *1. Smart VACUUM (2 AM):*
> ```bash
> # Only VACUUM tables with >10% dead tuples
> SELECT tablename FROM pg_stat_user_tables
> WHERE n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0) > 10
> ```
> - Runs VACUUM ANALYZE on selected tables
> - Tracks duration (alert if > 2 hours)
> - Reports to Slack
>
> *2. Backup (2 AM):*
> - Barman full backup
> - Verify WAL archiving
> - Check retention policy
>
> *3. Statistics Update (every 6 hours):*
> ```sql
> ANALYZE;  # Lightweight, updates planner statistics
> ```
>
> **Weekly Tasks:**
>
> *1. REINDEX Bloated Indexes (Saturday 3 AM):*
> ```bash
> # Find indexes >50% bloated or unused
> REINDEX INDEX CONCURRENTLY idx_bloated;
> ```
>
> *2. Connection Pool Cleanup:*
> - Kill idle connections > 24 hours
> - Reset pgBouncer statistics
>
> *3. Log Rotation:*
> - Archive logs older than 7 days
> - Parse with pgBadger for weekly report
>
> **Monthly Tasks:**
>
> *1. Restore Test (First Sunday 4 AM):*
> - Restore latest backup to test instance
> - Run verification queries
> - Measure restore time (tracking trend)
>
> *2. Capacity Review:*
> - Database size growth rate
> - Predict disk full date
> - Index size analysis (drop unused?)
> - Connection trends
>
> *3. Performance Report:*
> - Top 20 slow queries
> - Cache hit ratio trend
> - Checkpoint frequency
> - Vacuum effectiveness
>
> **Automated Responses:**
>
> *Self-Healing Actions:*
> ```python
> # If replication lag > 60 seconds for 5 minutes:
> if replication_lag > 60:
>     # Check for blocking queries on standby
>     blocking_queries = get_blocking_queries()
>     if blocking_queries:
>         # Kill them automatically (if configured)
>         kill_query(blocking_queries)
>         log_action('Killed blocking query to reduce replication lag')
>         alert_team('Auto-remediation: Killed blocking query')
> ```
>
> **Monitoring Dashboard:**
> - Grafana panel showing last run time of each task
> - Alert if task skipped
> - Track task duration trends
> - Report failures immediately
>
> **Cron Schedule:**
> ```cron
> # Backups
> 0 2 * * * barman backup primary --wait
> 
> # Maintenance
> 0 2 * * * /usr/local/bin/smart-vacuum.sh
> 0 */6 * * * psql -c "ANALYZE;"
> 0 3 * * 6 /usr/local/bin/reindex-bloated.sh
> 
> # Monitoring
> */5 * * * * /usr/local/bin/check-replication-lag.sh
> */15 * * * * /usr/local/bin/check-locks.sh
> 0 0 1 * * /usr/local/bin/capacity-forecast.py
> 
> # Testing
> 0 4 1-7 * 0 /usr/local/bin/test-restore.sh
> ```
>
> **Result:** 
> - Zero manual maintenance tasks
> - 99.99% task success rate
> - Average detection-to-resolution: < 5 minutes for automated issues"

---

### Q5: "How do you implement infrastructure as code for PostgreSQL?"

**Answer:**
> "I use Terraform for infrastructure and Ansible for configuration:
>
> **Layer 1: Infrastructure (Terraform)**
> ```hcl
> # main.tf
> module 'postgresql_cluster' {
>   source = './modules/postgres'
>   
>   environment = 'production'
>   instance_type = 'db.r5.2xlarge'
>   instance_count = 3
>   disk_size_gb = 500
>   
>   availability_zones = ['us-east-1a', 'us-east-1b', 'us-east-1c']
>   vpc_id = var.vpc_id
>   subnet_ids = var.private_subnets
> }
> ```
>
> **Layer 2: Configuration (Ansible)**
> ```yaml
> # playbook.yml
> - hosts: postgres
>   roles:
>     - postgresql-install
>     - postgresql-config
>     - monitoring-agent
>     - backup-client
> ```
>
> **Full Stack:**
> ```
> Terraform:
> ├── VPC, Subnets, Security Groups
> ├── EC2 Instances (3 PostgreSQL nodes)
> ├── EBS Volumes (500 GB each)
> ├── Load Balancer (HAProxy)
> ├── S3 Bucket (Barman backups)
> └── Route53 DNS Records
>
> Ansible:
> ├── Install PostgreSQL 15
> ├── Configure postgresql.conf (templated)
> ├── Setup replication (primary + standbys)
> ├── Install Patroni
> ├── Install postgres_exporter (Prometheus)
> ├── Install Barman client
> ├── Configure cron jobs
> └── Setup log rotation
> ```
>
> **Workflow:**
> ```bash
> # 1. Plan infrastructure
> terraform plan -out=plan.out
> # Review: +3 EC2, +3 EBS, +1 S3, +1 ALB
>
> # 2. Apply infrastructure
> terraform apply plan.out
> # Creates: VMs, disks, networking
>
> # 3. Configure with Ansible
> ansible-playbook -i terraform-inventory.py setup-cluster.yml
> # Installs: PostgreSQL, replication, monitoring
>
> # 4. Verify
> ansible all -m command -a "psql -U postgres -c 'SELECT version()'"
> ```
>
> **Benefits:**
> - **Reproducible:** Spin up identical cluster in minutes
> - **Version controlled:** Git tracks all changes
> - **Testable:** Create staging clone instantly
> - **Documented:** Code IS documentation
> - **Auditable:** Who changed what, when
>
> **DR Scenario:**
> ```bash
> # Disaster: Primary datacenter destroyed
>
> # 1. Deploy to new region (15 minutes)
> cd terraform/
> terraform workspace select dr-west
> terraform apply -auto-approve
>
> # 2. Restore from S3 backups (2 hours for 500 GB)
> ansible-playbook restore-from-s3.yml
>
> # 3. Update DNS (5 minutes)
> terraform apply -target=route53_record.postgres_primary
>
> # Total RTO: 2 hours 20 minutes
> ```
>
> **Real Example:**
> When we needed to migrate from on-prem to AWS, I had Terraform + Ansible ready. Provisioned the entire production cluster (3 nodes, monitoring, backups) in 45 minutes. Migration took 4 hours total, mostly data transfer."

---

## ✅ Summary

**Key Automation Areas:**
- ✅ Backup automation (Barman, tested monthly)
- ✅ Monitoring (Prometheus, Grafana, AlertManager)
- ✅ Configuration management (Ansible, Terraform)
- ✅ Schema migrations (Flyway, CI/CD)
- ✅ Routine maintenance (VACUUM, REINDEX, ANALYZE)
- ✅ Capacity planning (predictive alerts)
- ✅ Self-healing (automatic remediation)

**Interview Readiness:**
- ✅ Can design comprehensive backup strategy
- ✅ Know monitoring best practices
- ✅ Understand IaC for databases
- ✅ Can implement CI/CD for schema changes
- ✅ Have automation examples with real metrics

**DevOps Philosophy:**
- ✅ Automate everything repeatable
- ✅ Test your automation
- ✅ Monitor your automation
- ✅ Document your automation
- ✅ Version control everything

You're ready to discuss PostgreSQL automation in senior DBA/DevOps interviews! 🚀
