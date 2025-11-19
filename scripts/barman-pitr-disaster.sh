#!/bin/bash
# Barman PITR Test - Complete Disaster Recovery Scenario
# This simulates accidental data deletion and performs point-in-time recovery

set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Barman PITR Scenario: Disaster Recovery Test           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Function to get PostgreSQL timestamp
get_pg_time() {
    docker exec postgres-primary psql -U postgres -t -A -c "SELECT now();"
}

# Function to count orders
count_orders() {
    docker exec postgres-primary psql -U postgres -t -A -c "
        SELECT 
            'Total: ' || COUNT(*) || ' | Completed: ' || 
            COUNT(*) FILTER (WHERE status='completed') || 
            ' | Pending: ' || COUNT(*) FILTER (WHERE status='pending')
        FROM critical_orders;
    "
}

# ============================================================
# CHECKPOINT 1: Baseline State
# ============================================================
echo "📍 CHECKPOINT 1: BASELINE STATE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
CP1_TIME=$(get_pg_time)
echo "Time: $CP1_TIME"
echo "Data: $(count_orders)"
echo ""
sleep 3

# ============================================================
# CHECKPOINT 2: Add more orders (normal business)
# ============================================================
echo "📍 CHECKPOINT 2: ADDING NEW ORDERS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker exec postgres-primary psql -U postgres -c "
INSERT INTO critical_orders (order_number, customer_email, amount, status)
SELECT 
    'ORD-' || LPAD((10000 + i)::text, 8, '0'),
    'newcustomer' || i || '@example.com',
    (random() * 2000 + 100)::numeric(10,2),
    'completed'
FROM generate_series(1, 500) i;
" > /dev/null

CP2_TIME=$(get_pg_time)
echo "Time: $CP2_TIME"
echo "Data: $(count_orders)"
echo ""
sleep 3

# ============================================================
# CHECKPOINT 3: GOOD STATE (Recovery Target)
# ============================================================
echo "🟢 CHECKPOINT 3: GOOD STATE - THIS IS OUR RECOVERY TARGET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker exec postgres-primary psql -U postgres -c "
    SELECT pg_create_restore_point('good_state_before_disaster');
" > /dev/null

GOOD_STATE_TIME=$(get_pg_time)
echo "Time: $GOOD_STATE_TIME"
echo "Data: $(count_orders)"
echo ""
echo "✅ SAVING THIS TIMESTAMP FOR RECOVERY!"
echo "$GOOD_STATE_TIME" > /tmp/barman_pitr_recovery_time.txt
echo ""
sleep 5

# ============================================================
# CHECKPOINT 4: DISASTER STRIKES!
# ============================================================
echo "🔴 CHECKPOINT 4: DISASTER - ACCIDENTAL DELETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Simulating: Junior developer runs DELETE without WHERE clause..."
sleep 2

docker exec postgres-primary psql -U postgres -c "
-- Accidental deletion of all completed orders!
DELETE FROM critical_orders WHERE status = 'completed';
" > /dev/null

DISASTER_TIME=$(get_pg_time)
echo "Time: $DISASTER_TIME"
echo "Data: $(count_orders)"
echo ""
echo "❌ DISASTER: All completed orders deleted!"
echo ""
sleep 3

# ============================================================
# CHECKPOINT 5: Discovery
# ============================================================
echo "⚠️  CHECKPOINT 5: DISASTER DISCOVERED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DISCOVERY_TIME=$(get_pg_time)
echo "Time: $DISCOVERY_TIME"
echo "Current Data: $(count_orders)"
echo ""
echo "🚨 ALERT: DBA paged - Mass deletion detected!"
echo ""

# ============================================================
# SUMMARY
# ============================================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  TIMELINE SUMMARY                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "CP1 - Baseline:      $CP1_TIME"
echo "CP2 - New Orders:    $CP2_TIME"
echo "CP3 - 🟢 GOOD STATE:  $GOOD_STATE_TIME  ← RECOVERY TARGET"
echo "CP4 - 🔴 DISASTER:    $DISASTER_TIME"
echo "CP5 - Discovery:     $DISCOVERY_TIME"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Recovery timestamp saved to: /tmp/barman_pitr_recovery_time.txt"
echo ""
echo "Next step: Run ./scripts/barman-pitr-recover.sh to perform recovery"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
