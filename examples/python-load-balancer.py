#!/usr/bin/env python3
"""
PostgreSQL Load Balancing Demo
Demonstrates automatic read query distribution across multiple standbys
"""

import psycopg2
import itertools
import time
from typing import Dict, List

# Configuration
PRIMARY_CONFIG = {
    'host': 'localhost',
    'port': 5432,
    'user': 'postgres',
    'password': 'postgres_password',
    'database': 'postgres'
}

STANDBY_CONFIGS = [
    {'host': 'localhost', 'port': 5433, 'user': 'postgres', 'password': 'postgres_password', 'database': 'postgres', 'name': 'STANDBY1'},
    {'host': 'localhost', 'port': 5434, 'user': 'postgres', 'password': 'postgres_password', 'database': 'postgres', 'name': 'STANDBY2'},
]

# Round-robin iterator
standby_cycle = itertools.cycle(STANDBY_CONFIGS)


def get_write_connection():
    """Get connection to PRIMARY for writes"""
    return psycopg2.connect(**PRIMARY_CONFIG)


def get_read_connection():
    """Get connection to next standby in round-robin"""
    standby = next(standby_cycle)
    conn = psycopg2.connect(**{k: v for k, v in standby.items() if k != 'name'})
    conn.standby_name = standby['name']  # Track which standby
    return conn


def demonstrate_load_balancing():
    """Demonstrate automatic load balancing across standbys"""
    
    print("=" * 70)
    print("PostgreSQL Load Balancing Demo")
    print("=" * 70)
    print()
    
    # Test 1: Write to PRIMARY
    print("Test 1: INSERT query (goes to PRIMARY)")
    print("-" * 70)
    write_conn = get_write_connection()
    cursor = write_conn.cursor()
    
    try:
        cursor.execute("""
            INSERT INTO orders (user_id, product, amount)
            VALUES (999, 'LoadBalanceTest', 99.99)
        """)
        write_conn.commit()
        print("✅ INSERT successful on PRIMARY:5432")
    except Exception as e:
        print(f"❌ Error: {e}")
    finally:
        cursor.close()
        write_conn.close()
    
    print()
    
    # Test 2: Read load balancing
    print("Test 2: SELECT queries (distributed across standbys)")
    print("-" * 70)
    
    query_distribution = {'STANDBY1': 0, 'STANDBY2': 0}
    
    for i in range(1, 11):
        read_conn = get_read_connection()
        cursor = read_conn.cursor()
        
        try:
            cursor.execute("SELECT COUNT(*) FROM orders")
            count = cursor.fetchone()[0]
            standby_name = read_conn.standby_name
            query_distribution[standby_name] += 1
            
            print(f"Query {i:2d}: {standby_name}:5433/5434 → {count:,} rows")
            
        except Exception as e:
            print(f"Query {i:2d}: Error - {e}")
        finally:
            cursor.close()
            read_conn.close()
        
        time.sleep(0.1)  # Small delay for readability
    
    print()
    print("=" * 70)
    print("Load Distribution Summary:")
    print("=" * 70)
    for standby, count in query_distribution.items():
        percentage = (count / 10) * 100
        bar = "█" * count
        print(f"{standby}: {bar} {count}/10 ({percentage:.0f}%)")
    
    print()
    
    # Test 3: Verify data consistency
    print("Test 3: Data consistency check")
    print("-" * 70)
    
    servers = [
        ('PRIMARY', PRIMARY_CONFIG),
        ('STANDBY1', {'host': 'localhost', 'port': 5433, 'user': 'postgres', 'password': 'postgres_password', 'database': 'postgres'}),
        ('STANDBY2', {'host': 'localhost', 'port': 5434, 'user': 'postgres', 'password': 'postgres_password', 'database': 'postgres'}),
    ]
    
    counts = {}
    for name, config in servers:
        try:
            conn = psycopg2.connect(**config)
            cursor = conn.cursor()
            cursor.execute("SELECT COUNT(*) FROM orders")
            counts[name] = cursor.fetchone()[0]
            cursor.close()
            conn.close()
            print(f"{name:9s}: {counts[name]:,} rows")
        except Exception as e:
            print(f"{name:9s}: Error - {e}")
    
    print()
    if len(set(counts.values())) == 1:
        print("✅ All servers have identical data - perfect replication!")
    else:
        print("⚠️  Warning: Data inconsistency detected!")
    
    print()
    
    # Test 4: Read-only enforcement
    print("Test 4: Write protection on standbys")
    print("-" * 70)
    
    read_conn = get_read_connection()
    cursor = read_conn.cursor()
    
    try:
        cursor.execute("INSERT INTO orders (user_id, product, amount) VALUES (1, 'test', 1)")
        print(f"❌ {read_conn.standby_name} accepted write (should be read-only!)")
    except psycopg2.errors.ReadOnlySqlTransaction:
        print(f"✅ {read_conn.standby_name} correctly rejected write (read-only mode)")
    except Exception as e:
        print(f"✅ {read_conn.standby_name} rejected write: {type(e).__name__}")
    finally:
        cursor.close()
        read_conn.close()
    
    print()
    print("=" * 70)
    print("Demo Complete!")
    print("=" * 70)


if __name__ == '__main__':
    demonstrate_load_balancing()
