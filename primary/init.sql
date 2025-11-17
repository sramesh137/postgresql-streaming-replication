-- Sample database initialization for streaming replication demo
-- This script runs automatically when primary container starts

-- Create sample users table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create sample orders table
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    product VARCHAR(100),
    amount DECIMAL(10,2),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample data
INSERT INTO users (username, email) VALUES 
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com')
ON CONFLICT (username) DO NOTHING;

INSERT INTO orders (user_id, product, amount) VALUES 
    (1, 'Laptop', 999.99),
    (2, 'Mouse', 29.99),
    (1, 'Keyboard', 79.99)
ON CONFLICT DO NOTHING;

-- Create replication user (password: replicator_password)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION PASSWORD 'replicator_password' LOGIN;
    END IF;
END
$$;

-- Display success message
\echo 'Database initialized successfully!'
\echo 'Tables created: users, orders'
\echo 'Replication user created: replicator'
