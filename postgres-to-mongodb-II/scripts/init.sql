-- ============================================================
-- Debezium Transforms Guide - Sample Data
-- ============================================================

\c inventory;

-- 1. customers table (used in most examples)
CREATE TABLE IF NOT EXISTS customers (
    id         SERIAL PRIMARY KEY,
    first_name VARCHAR(100),
    last_name  VARCHAR(100),
    email      VARCHAR(255) UNIQUE,
    region     VARCHAR(50),
    status     VARCHAR(50) DEFAULT 'ACTIVE',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. orders table (used in partition routing + outbox examples)
CREATE TABLE IF NOT EXISTS orders (
    id          SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(id),
    amount      DECIMAL(10,2),
    status      VARCHAR(50),
    region      VARCHAR(50),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. outbox table (used in Outbox Event Router example)
CREATE TABLE IF NOT EXISTS outbox (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregatetype VARCHAR(255) NOT NULL,
    aggregateid   VARCHAR(255) NOT NULL,
    type          VARCHAR(255) NOT NULL,
    payload       JSONB
);

-- 4. customers_shard1, shard2 (used in Topic Routing example)
CREATE TABLE IF NOT EXISTS customers_shard1 (
    id         SERIAL PRIMARY KEY,
    first_name VARCHAR(100),
    last_name  VARCHAR(100),
    email      VARCHAR(255) UNIQUE,
    region     VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS customers_shard2 (
    id         SERIAL PRIMARY KEY,
    first_name VARCHAR(100),
    last_name  VARCHAR(100),
    email      VARCHAR(255) UNIQUE,
    region     VARCHAR(50)
);

-- ── Sample Data ──────────────────────────────────────────────

INSERT INTO customers (first_name, last_name, email, region, status) VALUES
    ('Alice',   'Smith',   'alice@example.com',   'US', 'ACTIVE'),
    ('Bob',     'Jones',   'bob@example.com',     'EU', 'ACTIVE'),
    ('Charlie', 'Brown',   'charlie@example.com', 'US', 'INACTIVE'),
    ('Diana',   'Prince',  'diana@example.com',   'EU', 'ACTIVE'),
    ('Edward',  'Norton',  'edward@example.com',  'US', 'ACTIVE')
ON CONFLICT DO NOTHING;

INSERT INTO orders (customer_id, amount, status, region) VALUES
    (1, 150.00, 'COMPLETED', 'US'),
    (2, 2500.00,'PENDING',   'EU'),
    (3, 75.50,  'COMPLETED', 'US'),
    (1, 980.00, 'SHIPPED',   'US'),
    (4, 300.00, 'PENDING',   'EU')
ON CONFLICT DO NOTHING;

INSERT INTO customers_shard1 (first_name, last_name, email, region) VALUES
    ('John', 'Doe',  'john.shard1@example.com', 'US'),
    ('Jane', 'Doe',  'jane.shard1@example.com', 'EU')
ON CONFLICT DO NOTHING;

INSERT INTO customers_shard2 (first_name, last_name, email, region) VALUES
    ('Mark', 'Lee',  'mark.shard2@example.com', 'US'),
    ('Mary', 'Lee',  'mary.shard2@example.com', 'EU')
ON CONFLICT DO NOTHING;

-- Set REPLICA IDENTITY FULL so before values are captured on UPDATE/DELETE
ALTER TABLE customers       REPLICA IDENTITY FULL;
ALTER TABLE orders          REPLICA IDENTITY FULL;
ALTER TABLE outbox          REPLICA IDENTITY FULL;
ALTER TABLE customers_shard1 REPLICA IDENTITY FULL;
ALTER TABLE customers_shard2 REPLICA IDENTITY FULL;
