# PostgreSQL to MongoDB CDC with Debezium

This project demonstrates real-time Change Data Capture (CDC) from PostgreSQL to MongoDB using Debezium and Kafka Connect. This guide provides **complete, copy-paste ready** configurations so anyone can set up the entire pipeline from scratch.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Setup Instructions](#setup-instructions)
- [Configuration Files](#configuration-files)
- [Testing the Pipeline](#testing-the-pipeline)
- [Troubleshooting](#troubleshooting)
- [Common Issues and Fixes](#common-issues-and-fixes)
- [Useful Commands](#useful-commands)
- [Performance Guide](#performance-guide)
- [Cleanup](#cleanup)
- [References](#references)

## Architecture Overview

```
PostgreSQL (Source Database)
    ↓ WAL + Logical Replication
Debezium PostgreSQL Connector
    ↓ CDC Events
Apache Kafka (Message Broker)
    ↓ Stream Processing
MongoDB Kafka Connector
    ↓ Write Operations
MongoDB (Sink Database)
```

**Key Components:**

- **PostgreSQL 17.6**: Source database with `wal_level=logical` for CDC
- **Apache Kafka**: Message broker for CDC event streaming
- **Debezium Connect**: Kafka Connect with PostgreSQL source connector
- **MongoDB Kafka Connector**: Custom sink connector for writing to MongoDB
- **MongoDB**: Target database in replica set mode (required for change streams)
- **Kafka UI (AKHQ)**: Web interface at http://localhost:7080
- **Debezium UI**: Web interface at http://localhost:8080

## Prerequisites

- **Docker** and **Docker Compose** installed
- At least **4GB RAM** available
- **Free ports**: 5433 (PostgreSQL), 9092-9093 (Kafka), 8083 (Debezium), 8080 (Debezium UI), 7080 (Kafka UI), 27017 (MongoDB)
- Internet connection (for downloading MongoDB Kafka Connector)

## Project Structure

After following this guide, your project structure will be:

```
postgres-to-mongodb/
├── docker-compose.yaml              # Orchestration file with all services
├── Dockerfile                       # Custom Debezium image with MongoDB connector
├── postgres-source.json             # PostgreSQL source connector config
├── mongodb-sink.json                # MongoDB sink connector config
├── scripts/
│   └── init-postgres.sql            # PostgreSQL schema and sample data
├── mongodb-data/                    # MongoDB data directory (created automatically)
├── mongodb-log/                     # MongoDB logs (created automatically)
└── README.md                        # This file
```

## Setup Instructions

### Step 1: Create Project Structure

```bash
# Create main project directory
mkdir postgres-to-mongodb
cd postgres-to-mongodb

# Create subdirectories
mkdir scripts
```

### Step 2: Create docker-compose.yaml

Create `docker-compose.yaml` in the `postgres-to-mongodb` directory:

```yaml
version: '3'

services:
  mongodb:
    image: mongo:latest
    container_name: mongodb
    hostname: mongodb
    volumes:
      - ./mongodb-data:/data/db/
      - ./mongodb-log:/var/log/mongodb/
    ports:
      - "27017:27017"
    command: ["mongod", "--replSet", "rs0", "--bind_ip_all"]
    restart: always
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  # MongoDB must run in replica set mode for Debezium to capture changes
  mongodb-init:
    image: mongo:latest
    container_name: mongodb-init
    depends_on:
      mongodb:
        condition: service_healthy
    command: >
      mongosh --host mongodb:27017 --eval "
      try {
        rs.status();
        print('Replica set already initialized');
      } catch(err) {
        rs.initiate({
          _id: 'rs0',
          members: [{ _id: 0, host: 'mongodb:27017' }]
        });
        print('Replica set initialized');
      }"
    restart: "no"

  kafka-ui:
    image: tchiotludo/akhq
    container_name: kafka-ui
    restart: unless-stopped
    environment:
      AKHQ_CONFIGURATION: |
        akhq:
          connections:
            docker-kafka-server:
              properties:
                bootstrap.servers: "kafka:9092"
              connect:
                - name: "connect"
                  url: "http://debezium:8083"
    ports:
      - 7080:8080
    depends_on:
      - kafka

  kafka:
    image: apache/kafka:latest
    container_name: kafka
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_NUM_PARTITIONS: 3
    ports:
      - '9092:9092'
      - '9093:9093'
    healthcheck:
      test: ["CMD", "/opt/kafka/bin/kafka-broker-api-versions.sh", "--bootstrap-server", "localhost:9092"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgres:
    image: postgres:17.6
    container_name: postgres
    ports:
      - "5433:5432"
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=inventory
    # WAL configuration is REQUIRED for Debezium CDC
    command: ["postgres", "-c", "wal_level=logical", "-c", "max_wal_senders=4", "-c", "max_replication_slots=4"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - ./scripts:/docker-entrypoint-initdb.d

  debezium:
    build:
      context: .
      dockerfile: Dockerfile
    image: debezium-with-mongodb:latest
    restart: always
    container_name: debezium
    hostname: debezium
    depends_on:
      postgres:
        condition: service_healthy
      kafka:
        condition: service_healthy
    ports:
      - '8083:8083'
    environment:
      BOOTSTRAP_SERVERS: kafka:9092
      GROUP_ID: 1
      CONFIG_STORAGE_TOPIC: connect_configs
      STATUS_STORAGE_TOPIC: connect_statuses
      OFFSET_STORAGE_TOPIC: connect_offsets
      KEY_CONVERTER: org.apache.kafka.connect.json.JsonConverter
      VALUE_CONVERTER: org.apache.kafka.connect.json.JsonConverter
      ENABLE_DEBEZIUM_SCRIPTING: 'true'
    healthcheck:
      test:
        [
          'CMD',
          'curl',
          '--silent',
          '--fail',
          '-X',
          'GET',
          'http://localhost:8083/connectors',
        ]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 5

  debezium-ui:
    image: debezium/debezium-ui:latest
    platform: linux/amd64
    restart: always
    container_name: debezium-ui
    hostname: debezium-ui
    depends_on:
      debezium:
        condition: service_healthy
    ports:
      - '8080:8080'
    environment:
      KAFKA_CONNECT_URIS: http://debezium:8083
```

### Step 3: Create Dockerfile

Create `Dockerfile` in the `postgres-to-mongodb` directory:

```dockerfile
FROM quay.io/debezium/connect:latest

# Download and install MongoDB Kafka Connector
RUN cd /kafka/connect && \
    curl -L https://repo1.maven.org/maven2/org/mongodb/kafka/mongo-kafka-connect/1.13.0/mongo-kafka-connect-1.13.0-all.jar \
    -o mongo-kafka-connect-1.13.0-all.jar

USER kafka
```

**Why we need a custom Dockerfile:**
- The official Debezium image doesn't include the MongoDB Kafka Connector
- We download the MongoDB connector JAR file during image build
- This ensures the MongoDB sink connector is available when we start the services

### Step 4: Create PostgreSQL Init Script

Create `scripts/init-postgres.sql`:

```sql
-- The database 'inventory' is already created by POSTGRES_DB environment variable
-- Connect to inventory database
\c inventory;

-- Create customers table
CREATE TABLE IF NOT EXISTS customers (
    id SERIAL PRIMARY KEY,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    email VARCHAR(255) UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create orders table
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(id),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(10, 2),
    status VARCHAR(50)
);

-- Create products table
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    description TEXT,
    price DECIMAL(10, 2),
    stock_quantity INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample data into customers
INSERT INTO customers (first_name, last_name, email) VALUES
    ('John', 'Doe', 'john.doe@example.com'),
    ('Jane', 'Smith', 'jane.smith@example.com'),
    ('Bob', 'Johnson', 'bob.johnson@example.com')
ON CONFLICT (email) DO NOTHING;

-- Insert sample data into products
INSERT INTO products (name, description, price, stock_quantity) VALUES
    ('Laptop', 'High-performance laptop', 999.99, 50),
    ('Mouse', 'Wireless mouse', 29.99, 200),
    ('Keyboard', 'Mechanical keyboard', 89.99, 100)
ON CONFLICT DO NOTHING;

-- Insert sample data into orders
INSERT INTO orders (customer_id, total_amount, status) VALUES
    (1, 999.99, 'completed'),
    (2, 119.98, 'pending'),
    (1, 29.99, 'shipped')
ON CONFLICT DO NOTHING;
```

### Step 5: Start Services

```bash
# Verify you're in the project directory
pwd  # Should show: /path/to/postgres-to-mongodb

# Start all services (this will build the custom Debezium image on first run)
docker-compose up -d

# Wait 30-60 seconds for all services to become healthy
# Monitor the startup process
docker-compose logs -f
```

**Expected output:**
```
✔ Container mongodb          Healthy
✔ Container mongodb-init     Exited (0)
✔ Container kafka            Healthy
✔ Container postgres         Healthy
✔ Container debezium         Healthy
✔ Container debezium-ui      Started
✔ Container kafka-ui         Started
```

**Verify all services are running:**
```bash
docker-compose ps
```

All services should show `Up` or `Up (healthy)` status.

### Step 6: Register Connectors

**Register PostgreSQL Source Connector:**
```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @postgres-source.json
```

**Expected response:**
```json
{"name":"postgres-source","config":{...},"tasks":[],"type":"source"}
```

**Register MongoDB Sink Connector:**
```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @mongodb-sink.json
```

**Expected response:**
```json
{"name":"mongodb-sink","config":{...},"tasks":[],"type":"sink"}
```

**Verify both connectors are running:**
```bash
curl http://localhost:8083/connectors
```

**Expected output:**
```json
["postgres-source","mongodb-sink"]
```

**Check connector status:**
```bash
curl -s http://localhost:8083/connectors/postgres-source/status | jq
curl -s http://localhost:8083/connectors/mongodb-sink/status | jq
```

Both should show `"state": "RUNNING"`.

**Your CDC pipeline is now fully operational!** 🎉

## Configuration Files

### PostgreSQL Source Connector (`postgres-source.json`)

```json
{
    "name": "postgres-source",
    "config": {
        "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
        "tasks.max": "1",
        "database.hostname": "postgres",
        "database.port": "5432",
        "database.user": "postgres",
        "database.password": "postgres",
        "database.dbname": "inventory",
        "database.server.name": "postgres",
        "topic.prefix": "postgres",
        "table.include.list": "public.customers,public.orders,public.products",
        "plugin.name": "pgoutput",
        "publication.autocreate.mode": "filtered",
        "slot.name": "debezium_slot",
        "key.converter": "org.apache.kafka.connect.json.JsonConverter",
        "key.converter.schemas.enable": "false",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "value.converter.schemas.enable": "false",
        "transforms": "unwrap",
        "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
        "transforms.unwrap.drop.tombstones": "false",
        "transforms.unwrap.delete.handling.mode": "none"
    }
}
```

**Key configurations explained:**

| Configuration | Value | Description |
|--------------|-------|-------------|
| `connector.class` | `io.debezium.connector.postgresql.PostgresConnector` | The Debezium PostgreSQL connector class |
| `tasks.max` | `1` | Maximum number of tasks for parallel processing |
| `database.hostname` | `postgres` | PostgreSQL container hostname |
| `database.dbname` | `inventory` | Database name to capture changes from |
| `table.include.list` | `public.customers,public.orders,public.products` | Tables to capture |
| `plugin.name` | `pgoutput` | PostgreSQL's built-in logical replication output plugin |
| `slot.name` | `debezium_slot` | Replication slot name in PostgreSQL |
| `transforms.unwrap.delete.handling.mode` | `none` | Sends DELETE events as tombstones (null values) |
| `transforms.unwrap.drop.tombstones` | `false` | Keep tombstones for MongoDB delete handling |

**Important notes:**
- `delete.handling.mode=none`: Sends DELETE events as tombstones (value=null), required for MongoDB delete synchronization
- `plugin.name=pgoutput`: Uses PostgreSQL's built-in logical replication (no extra plugin installation needed)
- `transforms.unwrap`: Simplifies CDC event structure by removing Debezium envelope

### MongoDB Sink Connector (`mongodb-sink.json`)

```json
{
    "name": "mongodb-sink",
    "config": {
        "connector.class": "com.mongodb.kafka.connect.MongoSinkConnector",
        "tasks.max": "1",
        "topics": "postgres.public.customers,postgres.public.orders,postgres.public.products",
        "connection.uri": "mongodb://mongodb:27017",
        "database": "inventory",
        "key.converter": "org.apache.kafka.connect.json.JsonConverter",
        "key.converter.schemas.enable": "false",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "value.converter.schemas.enable": "false",
        "document.id.strategy": "com.mongodb.kafka.connect.sink.processor.id.strategy.FullKeyStrategy",
        "writemodel.strategy": "com.mongodb.kafka.connect.sink.writemodel.strategy.ReplaceOneDefaultStrategy",
        "delete.on.null.values": "true",
        "max.num.retries": "3",
        "retries.defer.timeout": "5000",
        "topic.override.postgres.public.customers.collection": "customers",
        "topic.override.postgres.public.orders.collection": "orders",
        "topic.override.postgres.public.products.collection": "products"
    }
}
```

**Key configurations explained:**

| Configuration | Value | Description |
|--------------|-------|-------------|
| `connector.class` | `com.mongodb.kafka.connect.MongoSinkConnector` | MongoDB Kafka Sink Connector class |
| `topics` | `postgres.public.customers,...` | Kafka topics to consume |
| `document.id.strategy` | `FullKeyStrategy` | Uses entire key document as MongoDB `_id` |
| `writemodel.strategy` | `ReplaceOneDefaultStrategy` | Upsert strategy (insert or replace existing documents) |
| `delete.on.null.values` | `true` | Enables DELETE synchronization (required!) |
| `topic.override.<topic>.collection` | `customers` | Maps topic to simple collection name |

**Important notes:**
- `delete.on.null.values=true`: **CRITICAL** - Enables MongoDB to process DELETE events
- `FullKeyStrategy`: Uses the entire key document as MongoDB's `_id`
- `topic.override.*`: Maps full topic names to simple collection names (e.g., `customers` instead of `postgres.public.customers`)

## Testing the Pipeline

### 1. Verify Initial Data Replication

Debezium automatically performs an initial snapshot of existing data:

```bash
# Check PostgreSQL data
docker exec postgres psql -U postgres -d inventory -c "SELECT COUNT(*) FROM customers;"
# Expected: 3

# Check MongoDB data (should match)
docker exec mongodb mongosh inventory --eval "db.customers.countDocuments()"
# Expected: 3
```

### 2. Test INSERT Operations

```bash
# Insert a new customer in PostgreSQL
docker exec postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email) VALUES ('Alice', 'Wonder', 'alice@example.com');"

# Verify it appears in MongoDB (wait 2 seconds for propagation)
sleep 2
docker exec mongodb mongosh inventory --eval "db.customers.find({first_name: 'Alice'}).pretty()"
```

✅ **Expected**: Alice appears in MongoDB with all fields

### 3. Test UPDATE Operations

```bash
# Update Alice's email in PostgreSQL
docker exec postgres psql -U postgres -d inventory -c \
  "UPDATE customers SET email = 'alice.updated@example.com' WHERE first_name = 'Alice';"

# Verify update in MongoDB
sleep 2
docker exec mongodb mongosh inventory --eval "db.customers.find({first_name: 'Alice'}).pretty()"
```

✅ **Expected**: Alice's email is updated in MongoDB

### 4. Test DELETE Operations

```bash
# Delete Alice from PostgreSQL
docker exec postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE first_name = 'Alice';"

# Verify deletion in MongoDB
sleep 2
docker exec mongodb mongosh inventory --eval "db.customers.find({first_name: 'Alice'}).count()"
```

✅ **Expected**: Count = 0 (Alice is deleted from MongoDB)

### 5. Verify Data Consistency

```bash
# Count in PostgreSQL
docker exec postgres psql -U postgres -d inventory -c "SELECT COUNT(*) FROM customers;"

# Count in MongoDB
docker exec mongodb mongosh inventory --eval "db.customers.countDocuments()"
```

✅ **Expected**: Both counts match

## Troubleshooting

### View Service Logs

```bash
# View all logs
docker-compose logs -f

# View specific service logs
docker-compose logs -f debezium
docker-compose logs -f postgres
docker-compose logs -f mongodb
```

### Check Connector Status

```bash
# List all connectors
curl http://localhost:8083/connectors

# Check status with details
curl -s http://localhost:8083/connectors/postgres-source/status | jq
curl -s http://localhost:8083/connectors/mongodb-sink/status | jq

# View connector configuration
curl -s http://localhost:8083/connectors/postgres-source | jq
```

### Check Kafka Topics

```bash
# List all topics
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# Expected topics:
# postgres.public.customers
# postgres.public.orders
# postgres.public.products

# View messages in a topic
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.customers \
  --from-beginning
```

### Access Web UIs

- **Debezium UI**: http://localhost:8080
- **Kafka UI (AKHQ)**: http://localhost:7080

## Common Issues and Fixes

### Issue 1: MongoDB Replica Set Not Initialized

**Error:**
```
MongoDB requires replica set mode for CDC
```

**Fix:**
The `mongodb-init` service automatically initializes the replica set. Verify:

```bash
docker exec mongodb mongosh --eval "rs.status()"
```

**Manual initialization (if needed):**
```bash
docker exec mongodb mongosh --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'mongodb:27017'}]})"
```

### Issue 2: Debezium PostgreSQL Connector Not Found

**Error:**
```
Failed to find any class that implements Connector and which name matches 
io.debezium.connector.postgresql.PostgresConnector
```

**Root Cause:**
Missing PostgreSQL connector in the image.

**Fix:**
Use the custom Dockerfile approach which includes all necessary connectors.

### Issue 3: MongoDB Sink Connector - Missing _id Field

**Error:**
```
Provided id strategy is used but the document structure either contained 
no _id field or it was null
```

**Fix:**
Ensure `FullKeyStrategy` is used in MongoDB sink configuration:
```json
"document.id.strategy": "com.mongodb.kafka.connect.sink.processor.id.strategy.FullKeyStrategy"
```

### Issue 4: DELETE Operations Not Working

**Symptom:** INSERT and UPDATE work, but DELETE doesn't remove documents from MongoDB.

**Root Cause:** Incorrect delete handling configuration.

**Fix:** Verify your configurations match exactly:

**postgres-source.json:**
```json
"transforms.unwrap.delete.handling.mode": "none",
"transforms.unwrap.drop.tombstones": "false"
```

**mongodb-sink.json:**
```json
"delete.on.null.values": "true"
```

### Issue 5: Port Already in Use

**Error:**
```
Error starting userland proxy: listen tcp 0.0.0.0:8083: bind: address already in use
```

**Fix:**
```bash
# Find what's using the port
lsof -i :8083  # macOS/Linux
netstat -ano | findstr :8083  # Windows

# Kill the process or change the port in docker-compose.yaml
# Example: Change "8083:8083" to "8084:8083"
```

## Useful Commands

### Connector Management

```bash
# List all connectors
curl http://localhost:8083/connectors

# Get connector status
curl http://localhost:8083/connectors/postgres-source/status | jq

# Get connector configuration
curl http://localhost:8083/connectors/postgres-source | jq

# Delete a connector
curl -X DELETE http://localhost:8083/connectors/postgres-source

# Restart a connector
curl -X POST http://localhost:8083/connectors/postgres-source/restart

# Pause a connector
curl -X PUT http://localhost:8083/connectors/postgres-source/pause

# Resume a connector
curl -X PUT http://localhost:8083/connectors/postgres-source/resume
```

### Database Operations

```bash
# PostgreSQL: Connect to database
docker exec -it postgres psql -U postgres -d inventory

# PostgreSQL: View table data
docker exec postgres psql -U postgres -d inventory -c "SELECT * FROM customers;"

# MongoDB: Connect to database
docker exec -it mongodb mongosh inventory

# MongoDB: View collection data
docker exec mongodb mongosh inventory --eval "db.customers.find().pretty()"

# MongoDB: Count documents
docker exec mongodb mongosh inventory --eval "db.customers.countDocuments()"
```

### Kafka Operations

```bash
# List topics
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# Describe a topic
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe --topic postgres.public.customers

# Consume messages from beginning
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.customers \
  --from-beginning
```

### Container Management

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# Stop and remove volumes (complete cleanup)
docker-compose down -v

# Rebuild images
docker-compose build --no-cache

# View logs for all services
docker-compose logs -f

# View logs for specific service
docker-compose logs -f debezium

# Restart a specific service
docker-compose restart debezium

# Check service status
docker-compose ps
```

## Performance Guide

For migrating large datasets (2.5 million+ records), consider these performance characteristics:

| Metric | Value |
|--------|-------|
| **Snapshot Duration** | 30-60 minutes for 2.5M records |
| **PostgreSQL CPU** | 20-40% during snapshot, <5% during CDC |
| **MongoDB CPU** | 40-60% during snapshot, <10% during CDC |
| **Throughput** | 40,000-50,000 records/minute |
| **CDC Latency** | <1 second for real-time changes |

**Performance Tips:**
- Run initial snapshot during off-peak hours
- Monitor disk space for PostgreSQL WAL files
- Consider increasing `tasks.max` for parallel processing
- Use SSD storage for better I/O performance

## Cleanup

To completely remove all data and start fresh:

```bash
# Stop and remove containers, networks, and volumes
docker-compose down -v

# Remove custom images
docker rmi debezium-with-mongodb:latest

# Remove downloaded data directories (optional)
rm -rf mongodb-data mongodb-log

# Start fresh
docker-compose up -d
```

## References

- [Debezium PostgreSQL Connector Documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [MongoDB Kafka Connector Documentation](https://www.mongodb.com/docs/kafka-connector/current/)
- [Kafka Connect Documentation](https://kafka.apache.org/documentation/#connect)
- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/current/logical-replication.html)
- [PostgreSQL WAL Configuration](https://www.postgresql.org/docs/current/wal-configuration.html)

## License

This project is for educational and demonstration purposes.

---

## Quick Start Summary

```bash
# 1. Create project
mkdir postgres-to-mongodb && cd postgres-to-mongodb
mkdir scripts

# 2. Create all files (docker-compose.yaml, Dockerfile, configs, SQL script)
#    Copy-paste the configurations from this README

# 3. Start services
docker-compose up -d

# 4. Wait for services to be healthy (30-60 seconds)
docker-compose ps

# 5. Register connectors
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @postgres-source.json
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @mongodb-sink.json

# 6. Verify
curl http://localhost:8083/connectors
docker exec mongodb mongosh inventory --eval "db.customers.find().pretty()"

# Done! Your CDC pipeline is operational. 🎉
```
