# Quick Start Guide

## 1. Start the containers
```bash
cd postgresql-streaming-replication
docker-compose up -d
```

## 2. Wait for primary to initialize (10-15 seconds)
```bash
docker-compose logs -f postgres-primary
# Wait for "database system is ready to accept connections"
```

## 3. Run the automated setup script
```bash
chmod +x scripts/*.sh
bash scripts/setup-replication.sh
```

## 4. Verify replication is working
```bash
bash scripts/monitor.sh
```

## 5. Test replication
```bash
bash scripts/test-replication.sh
```

## Common Commands

### Connect to databases
```bash
# Primary (read-write)
docker exec -it postgres-primary psql -U postgres

# Standby (read-only)
docker exec -it postgres-standby psql -U postgres
```

### Manual testing
```bash
# Insert on primary
docker exec -it postgres-primary psql -U postgres -c "INSERT INTO users (username, email) VALUES ('manual_test', 'manual@test.com');"

# Check on standby
docker exec -it postgres-standby psql -U postgres -c "SELECT * FROM users;"
```

### View logs
```bash
docker-compose logs -f postgres-primary
docker-compose logs -f postgres-standby
```

### Cleanup
```bash
docker-compose down -v
```

## Architecture

```
Primary (5432) ──WAL Stream──> Standby (5433)
[Read + Write]                  [Read Only]
```

For detailed information, see the main README.md
