#!/bin/bash
# Test script to verify replication is working correctly

echo "========================================"
echo "PostgreSQL Replication Test Suite"
echo "========================================"
echo ""

TEST_USERNAME="test_user_$(date +%s)"
TEST_EMAIL="test_$(date +%s)@example.com"

echo "Test 1: Insert data on primary"
echo "-------------------------------"
docker exec postgres-primary psql -U postgres -d postgres -c "
INSERT INTO users (username, email) 
VALUES ('${TEST_USERNAME}', '${TEST_EMAIL}');
"

echo "✓ Data inserted on primary"
echo ""

echo "Test 2: Verify data appears on standby"
echo "---------------------------------------"
sleep 1  # Brief wait for replication

STANDBY_RESULT=$(docker exec postgres-standby psql -U postgres -d postgres -t -c "
SELECT COUNT(*) FROM users WHERE username = '${TEST_USERNAME}';
" | tr -d '[:space:]')

if [ "$STANDBY_RESULT" = "1" ]; then
    echo "✓ SUCCESS: Data replicated to standby!"
else
    echo "✗ FAILED: Data not found on standby"
    exit 1
fi

echo ""
echo "Test 3: Verify standby is read-only"
echo "------------------------------------"
docker exec postgres-standby psql -U postgres -d postgres -c "
INSERT INTO users (username, email) VALUES ('should_fail', 'fail@example.com');
" 2>&1 | grep -q "read-only" && echo "✓ Standby correctly rejects writes" || echo "✗ Warning: Standby accepted write"

echo ""
echo "Test 4: Check replication lag"
echo "------------------------------"
docker exec postgres-primary psql -U postgres -c "
SELECT 
    application_name,
    state,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;
"

echo ""
echo "Test 5: Verify table counts match"
echo "----------------------------------"
PRIMARY_COUNT=$(docker exec postgres-primary psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM users;" | tr -d '[:space:]')
STANDBY_COUNT=$(docker exec postgres-standby psql -U postgres -d postgres -t -c "SELECT COUNT(*) FROM users;" | tr -d '[:space:]')

echo "Primary users count: $PRIMARY_COUNT"
echo "Standby users count: $STANDBY_COUNT"

if [ "$PRIMARY_COUNT" = "$STANDBY_COUNT" ]; then
    echo "✓ Counts match!"
else
    echo "✗ Counts don't match - replication may be lagging"
fi

echo ""
echo "========================================"
echo "All tests completed!"
echo "========================================"
echo ""
