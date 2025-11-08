# PostgreSQL to MongoDB CDC with DebeziumThe MongoDB Kafka Connector is NOT included in the Debezium image by default.



This project demonstrates real-time Change Data Capture (CDC) from PostgreSQL to MongoDB using Debezium and Kafka Connect.### Option 1: Download MongoDB Kafka Connector (Recommended)


### docker-compose.yml

```
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
    # environment:
    #   MONGO_INITDB_ROOT_USERNAME: root
    #   MONGO_INITDB_ROOT_PASSWORD: root

# For Debezium to capture data from MongoDB, MongoDB must be running in replica set mode. 
# This configuration enables Debezium to track the oplog (operation log) in MongoDB.
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
              # schema-registry:
              #   url: "http://schema-registry:8085"
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
    command: ["postgres", "-c", "wal_level=logical", "-c", "max_wal_senders=4", "-c", "max_replication_slots=4"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      # - ./postgres/postgresql_data:/var/lib/postgresql/data
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
    platform: linux/amd64 # Add this line
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

### postgres-source.json
```
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


### mongodb-sink.json
```
{
  "name": "mongodb-sink",
  "config": {
    "connector.class": "com.mongodb.kafka.connect.MongoSinkConnector",
    "topics": "postgres.public.customers,postgres.public.orders,postgres.public.products",
    "connection.uri": "mongodb://mongodb:27017",
    "database": "inventory",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
	"document.id.strategy": "com.mongodb.kafka.connect.sink.processor.id.strategy.FullKeyStrategy",
	"delete.on.null.values": "true",
	"max.num.retries": "3",
	"retries.defer.timeout": "5000",
    "topic.override.postgres.public.customers.collection": "customers",
    "topic.override.postgres.public.orders.collection": "orders",
    "topic.override.postgres.public.products.collection": "products"
  }
}

```

## Table of Contents```

- [Architecture Overview](#architecture-overview)cd postgres-to-mongodb && mkdir -p debezium-plugins

- [Prerequisites](#prerequisites)```

- [Project Structure](#project-structure)

- [Setup Instructions](#setup-instructions)```

- [Configuration Files](#configuration-files)cd postgres-to-mongodb/debezium-plugins && curl -L https://repo1.maven.org/maven2/org/mongodb/kafka/mongo-kafka-connect/1.13.0/mongo-kafka-connect-1.13.0-all.jar -o mongo-kafka-connect-1.13.0-all.jar

- [Deployment Steps](#deployment-steps)```

- [Testing the Pipeline](#testing-the-pipeline)

- [Troubleshooting](#troubleshooting)

- [Common Issues and Fixes](#common-issues-and-fixes)### Option 2: Use a Custom Debezium Image with MongoDB Connector Pre-installed

- [Useful Commands](#useful-commands)

Instead of manually downloading the plugin, you can create a custom Docker image that includes the MongoDB Kafka Connector.

## Architecture Overview

```

```cd postgres-to-mongodb

PostgreSQL (Source) ```

    ↓

Debezium PostgreSQL Connector#### Build the custom image (first time only)

    ↓

Apache Kafka (Message Broker)```

    ↓docker-compose build debezium

MongoDB Kafka Connector```

    ↓

MongoDB (Sink)### **Common steps for both options**

```

#### 1. Start the services

**Components:**cd postgres-to-mongodb

- **PostgreSQL**: Source database with logical replication enableddocker-compose up -d

- **Apache Kafka**: Message broker for streaming CDC events

- **Debezium Connect**: Kafka Connect cluster with PostgreSQL and MongoDB connectors#### 2. Wait for all services to be healthy, then register the source connector

- **MongoDB**: Target database in replica set mode```

- **Kafka UI**: Web interface for monitoring Kafka topicscurl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @postgres-source.json

- **Debezium UI**: Web interface for managing connectors```



## Prerequisites

#### 3. Register the sink connector

- Docker and Docker Compose installed

- At least 4GB of available RAM```

- Ports available: 5433 (PostgreSQL), 9092-9093 (Kafka), 8083 (Debezium), 8080 (Debezium UI), 7080 (Kafka UI), 27017 (MongoDB)

## Understanding PostgreSQL WAL Configuration

PostgreSQL requires specific Write-Ahead Log (WAL) configurations for Debezium CDC to work. These settings are **mandatory** and cannot be avoided.

### Required PostgreSQL Settings

```yaml
command: ["postgres", "-c", "wal_level=logical", "-c", "max_wal_senders=4", "-c", "max_replication_slots=4"]
```

#### Why These Settings Are Required

**1. `wal_level=logical`** - **CRITICAL for CDC**
- PostgreSQL uses Write-Ahead Log (WAL) to record all database changes
- By default, `wal_level=replica` (only physical replication)
- **`logical` level** is required for Debezium to:
  - Capture row-level changes (INSERT, UPDATE, DELETE)
  - Read the actual data values (not just disk blocks)
  - Use logical decoding plugins like `pgoutput`
- **Without this setting, Debezium cannot capture changes**

**2. `max_wal_senders=4`**
- Controls how many concurrent WAL streaming connections are allowed
- Debezium creates a replication connection to read the WAL
- Default is often `10`, but setting `4` ensures capacity for Debezium
- Can be adjusted based on number of connectors

**3. `max_replication_slots=4`**
- A replication slot tracks the WAL position for each consumer
- Debezium creates a slot (e.g., `debezium_slot`) to track its progress
- Prevents PostgreSQL from deleting WAL files before Debezium reads them
- Ensures no data loss if Debezium is temporarily disconnected

### Alternative Configuration Methods

#### Option 1: ALTER SYSTEM Commands (Runtime Change)

Instead of the `command` line in docker-compose, you can set these **after** PostgreSQL starts:

```sql
-- Connect to PostgreSQL
docker exec -it postgres psql -U postgres

-- Set configurations
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_wal_senders = 4;
ALTER SYSTEM SET max_replication_slots = 4;

-- Reload configuration
SELECT pg_reload_conf();

-- Check if restart is needed
SELECT name, setting, pending_restart 
FROM pg_settings 
WHERE name IN ('wal_level', 'max_wal_senders', 'max_replication_slots');
```

**Note:** `wal_level` change **requires PostgreSQL restart**:
```bash
docker restart postgres
```

#### Option 2: Custom postgresql.conf File

Create a custom config file and mount it:

**Create `postgres-config/postgresql.conf`:**
```conf
# CDC Configuration for Debezium
wal_level = logical
max_wal_senders = 4
max_replication_slots = 4

# Other settings
shared_buffers = 256MB
max_connections = 100
```

**Update docker-compose.yaml:**
```yaml
postgres:
  image: postgres:17.6
  volumes:
    - ./postgres-config/postgresql.conf:/etc/postgresql/postgresql.conf
    - ./scripts:/docker-entrypoint-initdb.d
  command: ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
```

#### Recommended Approach

**Keep the `command` line approach** (current setup) - it's the **simplest and most reliable**:

✅ Works immediately on container start  
✅ No extra files or scripts needed  
✅ Easy to see configuration in docker-compose.yaml  
✅ No restart required after setup  

### Verification Commands

Check current PostgreSQL WAL settings:

```bash
# Check wal_level
docker exec -it postgres psql -U postgres -c "SHOW wal_level;"

# Check max_wal_senders
docker exec -it postgres psql -U postgres -c "SHOW max_wal_senders;"

# Check max_replication_slots
docker exec -it postgres psql -U postgres -c "SHOW max_replication_slots;"

# View active replication slots (created by Debezium)
docker exec -it postgres psql -U postgres -c "SELECT * FROM pg_replication_slots;"
```

Expected output after Debezium connector is registered:
```
 slot_name     | plugin  | slot_type | datoid | database  | active | ...
---------------+---------+-----------+--------+-----------+--------+-----
 debezium_slot | pgoutput| logical   |  16384 | inventory | t      | ...
```

### Configuration Comparison

| Method | Pros | Cons |
|--------|------|------|
| **Command line** (current) | ✅ Simple, immediate | Requires restart if changed |
| **ALTER SYSTEM** | ✅ Can change after deployment | ❌ Requires manual SQL + restart |
| **Config file** | ✅ Centralized config | ❌ Extra file to manage |

### Important Notes

- These settings are **mandatory** for CDC - there's no way to avoid them if you want Debezium to work
- `wal_level=logical` increases WAL file size slightly (typically 5-10%)
- Monitor disk space for WAL files, especially if Debezium is down for extended periods
- Replication slots prevent WAL cleanup, so inactive slots should be removed:
  ```sql
  -- List all replication slots
  SELECT * FROM pg_replication_slots;
  
  -- Drop an inactive slot
  SELECT pg_drop_replication_slot('debezium_slot');
  ```

## Project Structure



```#### 4. Verify connectors are running

postgres-to-mongodb/```

├── docker-compose.yaml           # Main orchestration filecurl http://localhost:8083/connectors

├── Dockerfile                    # Custom Debezium image with MongoDB connector```

├── postgres-source.json          # PostgreSQL source connector configuration
├── mongodb-sink.json             # MongoDB sink connector configuration
├── scripts/
│   └── init-postgres.sql         # PostgreSQL initialization script
├── debezium-plugins/
│   └── mongodb-connector/
│       └── mongo-kafka-connect-1.13.0-all.jar
└── README.md
```

## Setup Instructions

### Step 1: Download MongoDB Kafka Connector

The MongoDB Kafka Connector is required but not included in the default Debezium image.

```bash
# Create plugins directory
mkdir -p debezium-plugins/mongodb-connector

# Download MongoDB Kafka Connector
cd debezium-plugins/mongodb-connector
curl -L https://repo1.maven.org/maven2/org/mongodb/kafka/mongo-kafka-connect/1.13.0/mongo-kafka-connect-1.13.0-all.jar -o mongo-kafka-connect-1.13.0-all.jar
cd ../..
```

**Note:** The plugin JAR must be in a subdirectory (not directly in `debezium-plugins/`) because Kafka Connect loads plugins from subdirectories only.

### Step 2: Build Custom Debezium Image

The `Dockerfile` creates a custom Debezium image with the MongoDB connector:

```dockerfile
FROM quay.io/debezium/connect:latest

# Download and install MongoDB Kafka Connector
RUN cd /kafka/connect && \
    curl -L https://repo1.maven.org/maven2/org/mongodb/kafka/mongo-kafka-connect/1.13.0/mongo-kafka-connect-1.13.0-all.jar \
    -o mongo-kafka-connect-1.13.0-all.jar

USER kafka
```

Build the image:

```bash
docker-compose build debezium
```

### Step 3: Start All Services

```bash
# Start all containers
docker-compose up -d

# Wait for all services to become healthy (30-60 seconds)
docker-compose ps
```

Expected output:
```
NAME            IMAGE                          STATUS
debezium        debezium-with-mongodb:latest   Up (healthy)
debezium-ui     debezium/debezium-ui:latest    Up
kafka           apache/kafka:latest            Up (healthy)
kafka-ui        tchiotludo/akhq                Up
mongodb         mongo:latest                   Up (healthy)
mongodb-init    mongo:latest                   Exited (0)
postgres        postgres:17.6                  Up (healthy)
```

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
        "transforms": "unwrap,addKey",
        "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
        "transforms.unwrap.drop.tombstones": "false",
        "transforms.unwrap.delete.handling.mode": "rewrite",
        "transforms.unwrap.add.fields": "table,lsn",
        "transforms.addKey.type": "org.apache.kafka.connect.transforms.ValueToKey",
        "transforms.addKey.fields": "id"
    }
}
```

**Key configurations explained:**

| Configuration | Value | Description |
|--------------|-------|-------------|
| `connector.class` | `io.debezium.connector.postgresql.PostgresConnector` | The Debezium PostgreSQL connector class |
| `tasks.max` | `1` | Maximum number of tasks for parallel processing |
| `database.hostname` | `postgres` | PostgreSQL container hostname |
| `database.port` | `5432` | PostgreSQL port |
| `database.dbname` | `inventory` | Database name to capture changes from |
| `database.server.name` | `postgres` | Logical name for the PostgreSQL server |
| `topic.prefix` | `postgres` | Prefix for Kafka topic names |
| `table.include.list` | `public.customers,public.orders,public.products` | Comma-separated list of tables to capture |
| `plugin.name` | `pgoutput` | PostgreSQL's built-in logical replication output plugin |
| `publication.autocreate.mode` | `filtered` | Auto-create publication for specified tables only |
| `slot.name` | `debezium_slot` | Replication slot name in PostgreSQL |
| `key.converter` | `org.apache.kafka.connect.json.JsonConverter` | Converts keys to JSON format |
| `key.converter.schemas.enable` | `false` | Disables schema in key (uses plain JSON) |
| `value.converter` | `org.apache.kafka.connect.json.JsonConverter` | Converts values to JSON format |
| `value.converter.schemas.enable` | `false` | Disables schema in value (uses plain JSON) |
| `transforms` | `unwrap,addKey` | List of transformations to apply |
| `transforms.unwrap.type` | `io.debezium.transforms.ExtractNewRecordState` | Extracts the actual row data from CDC envelope |
| `transforms.unwrap.drop.tombstones` | `false` | Keep delete event markers |
| `transforms.unwrap.delete.handling.mode` | `rewrite` | Rewrites delete events with null values |
| `transforms.addKey.type` | `org.apache.kafka.connect.transforms.ValueToKey` | Extracts fields from value to key |
| `transforms.addKey.fields` | `id` | Uses `id` field as the message key |

**Important notes:**
- `transforms.unwrap`: Simplifies CDC event structure by removing Debezium envelope
- `transforms.addKey`: Extracts the `id` field as the message key for MongoDB's `_id`
- `plugin.name: pgoutput`: Uses PostgreSQL's built-in logical replication (no extra plugin installation needed)

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
        "document.id.strategy": "com.mongodb.kafka.connect.sink.processor.id.strategy.PartialValueStrategy",
        "document.id.strategy.partial.value.projection.type": "AllowList",
        "document.id.strategy.partial.value.projection.list": "id",
        "writemodel.strategy": "com.mongodb.kafka.connect.sink.writemodel.strategy.ReplaceOneDefaultStrategy",
        "max.num.retries": "3",
        "retries.defer.timeout": "5000"
    }
}
```

**Key configurations explained:**

| Configuration | Value | Description |
|--------------|-------|-------------|
| `connector.class` | `com.mongodb.kafka.connect.MongoSinkConnector` | MongoDB Kafka Sink Connector class |
| `tasks.max` | `1` | Maximum number of tasks for parallel processing |
| `topics` | `postgres.public.customers,...` | Comma-separated list of Kafka topics to consume |
| `connection.uri` | `mongodb://mongodb:27017` | MongoDB connection string |
| `database` | `inventory` | Target MongoDB database name |
| `key.converter` | `org.apache.kafka.connect.json.JsonConverter` | Converts keys from JSON format |
| `key.converter.schemas.enable` | `false` | Disables schema in key (expects plain JSON) |
| `value.converter` | `org.apache.kafka.connect.json.JsonConverter` | Converts values from JSON format |
| `value.converter.schemas.enable` | `false` | Disables schema in value (expects plain JSON) |
| `document.id.strategy` | `PartialValueStrategy` | Uses specified fields from value as MongoDB `_id` |
| `document.id.strategy.partial.value.projection.type` | `AllowList` | Specifies which fields to use for `_id` |
| `document.id.strategy.partial.value.projection.list` | `id` | Uses the `id` field as MongoDB's `_id` |
| `writemodel.strategy` | `ReplaceOneDefaultStrategy` | Upsert strategy (insert or replace existing documents) |
| `max.num.retries` | `3` | Number of retry attempts on failure |
| `retries.defer.timeout` | `5000` | Milliseconds to wait between retries |
| `topic.override.<topic>.collection` | `customers` | Maps specific topic to collection name |

**Important notes:**
- `document.id.strategy`: Uses the `id` field from the value as MongoDB's `_id`
- `writemodel.strategy`: Uses upsert (replace) operation for INSERT and UPDATE events
- Topics follow the pattern: `<topic.prefix>.<schema>.<table>` (e.g., `postgres.public.customers`)
- `topic.override.*`: Maps full topic names to simple collection names (e.g., `customers` instead of `postgres.public.customers`)

## Deployment Steps

### Understanding Debezium's Data Replication Process

**IMPORTANT:** Debezium automatically handles both initial data copy AND real-time CDC. Here's how it works:

#### Phase 1: Initial Snapshot (Automatic)
When you register the PostgreSQL source connector for the first time:

1. **Snapshot Mode**: Debezium takes a complete snapshot of ALL existing data in the specified tables
2. **Data Capture**: All existing rows (e.g., 3 initial customers) are read from PostgreSQL
3. **Kafka Topics**: Each row is sent as a message to the corresponding Kafka topic
4. **One-time Process**: This snapshot happens ONLY when the connector is first created

#### Phase 2: Change Data Capture (Continuous)
After the initial snapshot completes:

1. **WAL Monitoring**: Debezium monitors PostgreSQL's Write-Ahead Log (WAL)
2. **Real-time Events**: Any INSERT, UPDATE, DELETE operation is captured immediately
3. **Kafka Stream**: Changes are streamed to Kafka topics in real-time
4. **Ongoing Process**: This runs continuously as long as the connector is active

#### Phase 3: MongoDB Sink Processing (Automatic)
When you register the MongoDB sink connector:

1. **Historical Data**: Reads ALL messages from Kafka topics from the beginning (includes initial snapshot)
2. **Initial Load**: Writes all existing data to MongoDB (e.g., 3 customers appear in MongoDB)
3. **Real-time Sync**: Continuously consumes new CDC events and applies them to MongoDB
4. **Consistency**: MongoDB stays in sync with PostgreSQL automatically

✅ Kafka topic name = postgres.public.customers (Debezium's standard, cannot change). 
✅ MongoDB collection name = customers (mapped via topic.override). 
This is by design and actually beneficial because:  

Kafka topics are descriptive (you know the source: postgres, schema: public, table: customers). 
MongoDB collections are simple (just customers). 
You can consume from multiple PostgreSQL schemas/databases into the same MongoDB database. 
If you had two databases both with a customers table:  

Topics: postgres1.public.customers and postgres2.public.customers. 
Can both write to: MongoDB customers collection (or map to customers1, customers2). 

**Data Flow Diagram:**

```
┌─────────────────────────────────────────────────────────────────┐
│ PostgreSQL Database (inventory)                                 │
│ ┌─────────────────────────────────────────────────────────┐    │
│ │ customers table (3 existing rows)                        │    │
│ │ - John Doe                                               │    │
│ │ - Jane Smith                                             │    │
│ │ - Bob Johnson                                            │    │
│ └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌──────────────────────────────────────────┐
        │ Step 1: Register PostgreSQL Connector    │
        │ → Triggers Initial Snapshot              │
        └──────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ Apache Kafka                                                    │
│ ┌─────────────────────────────────────────────────────────┐    │
│ │ Topic: postgres.public.customers                         │    │
│ │ Message 1: {"id": 1, "first_name": "John", ...}         │    │
│ │ Message 2: {"id": 2, "first_name": "Jane", ...}         │    │
│ │ Message 3: {"id": 3, "first_name": "Bob", ...}          │    │
│ │ [Waiting for new changes...]                             │    │
│ └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌──────────────────────────────────────────┐
        │ Step 2: Register MongoDB Sink Connector  │
        │ → Reads from beginning of topics         │
        └──────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ MongoDB Database (inventory)                                    │
│ ┌─────────────────────────────────────────────────────────┐    │
│ │ customers collection (3 documents created)               │    │
│ │ - John Doe                                               │    │
│ │ - Jane Smith                                             │    │
│ │ - Bob Johnson                                            │    │
│ └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌──────────────────────────────────────────┐
        │ Step 3: Make changes in PostgreSQL       │
        │ INSERT/UPDATE/DELETE                     │
        └──────────────────────────────────────────┘
                            │
                            ▼
        [Real-time CDC events flow automatically]
                            │
                            ▼
        MongoDB stays synchronized with PostgreSQL!
```

**Key Points:**

✅ **No manual data migration needed** - Debezium handles the initial copy automatically  
✅ **Existing data is replicated** - All rows present when connector is created are copied  
✅ **Real-time sync starts immediately** - After snapshot, CDC mode begins  
✅ **MongoDB gets all data** - Both historical (snapshot) and new (CDC) data  
✅ **Idempotent** - If connector fails and restarts, it resumes from last position (no duplicates)  

**Timeline Example:**

| Time | Action | PostgreSQL | Kafka | MongoDB |
|------|--------|------------|-------|---------|
| T0 | Initial state | 3 customers | Empty | Empty |
| T1 | Register PostgreSQL connector | 3 customers | Snapshot: 3 messages | Empty |
| T2 | Register MongoDB connector | 3 customers | 3 messages | 3 documents |
| T3 | INSERT new customer | 4 customers | 4 messages | 4 documents |
| T4 | UPDATE customer email | 4 customers | 5 messages | 4 documents (1 updated) |
| T5 | DELETE customer | 3 customers | 6 messages | 3 documents |

---

### 1. Register PostgreSQL Source Connector

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @postgres-source.json
```

**What happens:**
- Debezium immediately starts an initial snapshot of all tables listed in `table.include.list`
- All existing rows are read and sent to Kafka topics
- After snapshot completes, switches to CDC mode (monitoring WAL for changes)

**Expected response:**
```json
{
  "name": "postgres-source",
  "config": {...},
  "tasks": [],
  "type": "source"
}
```

**Verify snapshot progress:**
```bash
# Check connector status
curl -s http://localhost:8083/connectors/postgres-source/status | jq

# Check Kafka topics (should see data)
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
```

### 2. Register MongoDB Sink Connector

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @mongodb-sink.json
```

**What happens:**
- MongoDB connector starts consuming from Kafka topics **from the beginning**
- All snapshot messages (existing data) are written to MongoDB
- Continues consuming new CDC events in real-time

**Expected response:**
```json
{
  "name": "mongodb-sink",
  "config": {...},
  "tasks": [],
  "type": "sink"
}
```

**Verify data replication:**
```bash
# Check MongoDB has the initial data
docker exec -it mongodb mongosh inventory --eval "db.customers.countDocuments()"
# Should return: 3

docker exec -it mongodb mongosh inventory --eval "db.customers.find().pretty()"
# Should show all 3 initial customers
```

### 3. Verify Connector Status

```bash
# Check all connectors
curl http://localhost:8083/connectors

# Check PostgreSQL source status
curl http://localhost:8083/connectors/postgres-source/status | jq

# Check MongoDB sink status
curl http://localhost:8083/connectors/mongodb-sink/status | jq
```

**Healthy status:**
```json
{
  "name": "postgres-source",
  "connector": {
    "state": "RUNNING",
    "worker_id": "172.19.0.6:8083"
  },
  "tasks": [
    {
      "id": 0,
      "state": "RUNNING",
      "worker_id": "172.19.0.6:8083"
    }
  ],
  "type": "source"
}
```

## Testing the Pipeline

### 1. Verify Data Replication

Check that initial data was loaded:

```bash
# Check PostgreSQL data
docker exec -it postgres psql -U postgres -d inventory -c "SELECT * FROM customers;"

# Check MongoDB data
docker exec -it mongodb mongosh inventory --eval "db['postgres.public.customers'].find().pretty()"
```

### 2. Test Real-Time CDC

Insert new data in PostgreSQL and verify it appears in MongoDB:

```bash
# Insert a new customer
docker exec -it postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email) VALUES ('Alice', 'Wonder', 'alice@example.com');"

# Verify in MongoDB (should appear within seconds)
docker exec -it mongodb mongosh inventory --eval "db['postgres.public.customers'].find({first_name: 'Alice'}).pretty()"
```

### 3. Test Update Operations

```bash
# Update a customer
docker exec -it postgres psql -U postgres -d inventory -c \
  "UPDATE customers SET email = 'newemail@example.com' WHERE first_name = 'John';"

# Verify update in MongoDB
docker exec -it mongodb mongosh inventory --eval "db['postgres.public.customers'].find({first_name: 'John'}).pretty()"
```

### 4. Test Delete Operations

```bash
# Delete a customer
docker exec -it postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE first_name = 'Bob';"

# Check MongoDB (document should be removed)
docker exec -it mongodb mongosh inventory --eval "db['postgres.public.customers'].find({first_name: 'Bob'}).pretty()"
```

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

### Check Kafka Topics

```bash
# List all topics
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# Consume messages from a topic
docker exec -it kafka /opt/kafka/bin/kafka-console-consumer.sh \
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
docker exec -it mongodb mongosh --eval "rs.status()"
```

**Manual initialization (if needed):**
```bash
docker exec -it mongodb mongosh --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'mongodb:27017'}]})"
```

---

### Issue 2: Debezium PostgreSQL Connector Not Found

**Error:**
```
Failed to find any class that implements Connector and which name matches 
io.debezium.connector.postgresql.PostgresConnector
```

**Root Cause:**
Mounting `./debezium-plugins:/kafka/connect` replaces ALL default connectors.

**Fix:**
Use the custom Dockerfile approach instead of volume mounts. The Dockerfile adds MongoDB connector without removing default connectors.

---

### Issue 3: MongoDB Sink Connector - Missing _id Field

**Error:**
```
Provided id strategy is used but the document structure either contained 
no _id field or it was null
```

**Root Cause:**
The PostgreSQL source connector wasn't including the primary key in the message key.

**Fix:**
Add `ValueToKey` transform to PostgreSQL source connector:
```json
"transforms": "unwrap,addKey",
"transforms.addKey.type": "org.apache.kafka.connect.transforms.ValueToKey",
"transforms.addKey.fields": "id"
```

And use `PartialValueStrategy` in MongoDB sink:
```json
"document.id.strategy": "com.mongodb.kafka.connect.sink.processor.id.strategy.PartialValueStrategy",
"document.id.strategy.partial.value.projection.list": "id"
```

---

### Issue 4: Plugin Directory Structure Error

**Error:**
```
ln: failed to create symbolic link '/kafka/connect/*/': No such file or directory
```

**Root Cause:**
Kafka Connect expects plugin JARs to be in subdirectories, not directly in `/kafka/connect/`.

**Fix:**
Place the JAR in a subdirectory:
```bash
debezium-plugins/
└── mongodb-connector/
    └── mongo-kafka-connect-1.13.0-all.jar
```

Move the JAR file:
```bash
mkdir -p debezium-plugins/mongodb-connector
mv debezium-plugins/mongo-kafka-connect-1.13.0-all.jar debezium-plugins/mongodb-connector/
```

---

### Issue 5: PostgreSQL Init Script Syntax Error

**Error:**
```
ERROR: syntax error at or near "NOT"
LINE 1: CREATE DATABASE IF NOT EXISTS inventory;
```

**Root Cause:**
PostgreSQL doesn't support `IF NOT EXISTS` for `CREATE DATABASE`.

**Fix:**
The database is already created via `POSTGRES_DB` environment variable. Remove the `CREATE DATABASE` statement:
```sql
-- The database 'inventory' is already created by POSTGRES_DB environment variable
\c inventory;

-- Create tables...
```

---

### Issue 6: MongoDB Sink Delete Configuration Error

**Error:**
```
Invalid value true for configuration delete.on.null.values: 
DeleteOneDefaultStrategy can only be applied when the configured IdStrategy 
is an instance of: FullKeyStrategy or PartialKeyStrategy or ProvidedInKeyStrategy
```

**Root Cause:**
`delete.on.null.values: true` requires `DeleteOneDefaultStrategy`, but there's a compatibility issue with the ID strategy.

**Fix:**
Remove `delete.on.null.values: true` when using `ReplaceOneDefaultStrategy`:
```json
{
  "document.id.strategy": "com.mongodb.kafka.connect.sink.processor.id.strategy.PartialValueStrategy",
  "writemodel.strategy": "com.mongodb.kafka.connect.sink.writemodel.strategy.ReplaceOneDefaultStrategy"
}
```

---

### Issue 7: MongoDB Sink Tasks Failed

**Symptom:**
Connector shows `RUNNING` but tasks show `FAILED` state.

**Check:**
```bash
curl -s http://localhost:8083/connectors/mongodb-sink/status | jq '.tasks[0]'
```

**Common Causes:**
1. Missing or incorrect MongoDB connection
2. MongoDB not in replica set mode
3. Missing _id field in messages
4. Invalid topic names or routing

**Fix:**
Check the task trace in the status output, then apply the appropriate fix from issues above.

---

### Issue 8: MongoDB Collection Names Include Full Topic Path

**Problem:**
MongoDB collections are named with the full Kafka topic path (e.g., `postgres.public.customers`) instead of just the table name (e.g., `customers`).

**Root Cause:**
By default, the MongoDB sink connector uses the Kafka topic name as the collection name.

**Fix:**
Add topic-to-collection mapping in the MongoDB sink connector configuration:

```json
{
  "name": "mongodb-sink",
  "config": {
    ...
    "topic.override.postgres.public.customers.collection": "customers",
    "topic.override.postgres.public.orders.collection": "orders",
    "topic.override.postgres.public.products.collection": "products"
  }
}
```

Update the connector:
```bash
# Delete existing connector
curl -X DELETE http://localhost:8083/connectors/mongodb-sink

# Recreate with new configuration
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @mongodb-sink.json
```

After this change, new data will go to collections named `customers`, `orders`, `products` instead of the full topic path.

**Note:** Old collections with the full path will remain. You can either:
1. Drop them manually: `db['postgres.public.customers'].drop()`
2. Keep them as historical data

---

### Issue 9: Debezium UI Not Showing Connectors

**Symptom:**
Connectors are registered and running (visible via curl), but not showing in Debezium UI at http://localhost:8080.

**Root Cause:**
Debezium UI caching issue or connection problem.

**Fix:**

**Option 1: Restart Debezium UI**
```bash
docker restart debezium-ui

# Wait 10 seconds, then access http://localhost:8080
```

**Option 2: Hard refresh browser**
- Press `Ctrl + Shift + R` (Windows/Linux)
- Press `Cmd + Shift + R` (macOS)

**Option 3: Check Debezium UI configuration**
Verify the environment variable in `docker-compose.yaml`:
```yaml
debezium-ui:
  environment:
    KAFKA_CONNECT_URIS: http://debezium:8083
```

**Option 4: Verify connectors via API (as alternative)**
```bash
# List all connectors
curl http://localhost:8083/connectors

# View connector details
curl http://localhost:8083/connectors/postgres-source | jq
curl http://localhost:8083/connectors/mongodb-sink | jq
```

**Option 5: Use Kafka UI instead**
Access Kafka UI (AKHQ) at http://localhost:7080 which also shows Kafka Connect connectors.

---

### Issue 10: Extra Fields (__lsn, __table) in MongoDB Documents

**Problem:**
MongoDB documents contain extra metadata fields like `__lsn` and `__table`:
```json
{
  "_id": { "id": 1 },
  "__lsn": 26709272,
  "__table": "customers",
  "id": 1,
  "first_name": "John",
  "last_name": "Doe",
  "email": "john@example.com"
}
```

**Root Cause:**
The `transforms.unwrap.add.fields` configuration in PostgreSQL source connector adds these debugging fields:
- `__lsn`: PostgreSQL Log Sequence Number (transaction position)
- `__table`: Source table name

**Fix:**
Remove the `transforms.unwrap.add.fields` line from `postgres-source.json`:

**Before:**
```json
{
  "transforms": "unwrap,addKey",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.add.fields": "table,lsn",  ← Remove this line
  "transforms.addKey.type": "org.apache.kafka.connect.transforms.ValueToKey"
}
```

**After:**
```json
{
  "transforms": "unwrap,addKey",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.addKey.type": "org.apache.kafka.connect.transforms.ValueToKey"
}
```

Update the connector:
```bash
# Delete existing connector
curl -X DELETE http://localhost:8083/connectors/postgres-source

# Recreate with clean configuration
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @postgres-source.json
```

**Result - Clean documents:**
```json
{
  "_id": { "id": 1 },
  "id": 1,
  "first_name": "John",
  "last_name": "Doe",
  "email": "john@example.com",
  "created_at": 1762351355887530
}
```

**Note:** If you need these fields for debugging or audit purposes, you can keep them. Common use cases:
- `__lsn`: Track PostgreSQL transaction order
- `__table`: Identify source table when multiple tables write to same collection

---

## Useful Commands

### Connector Management

```bash
# List all connectors
curl http://localhost:8083/connectors

# Get connector configuration
curl http://localhost:8083/connectors/postgres-source | jq

# Get connector status
curl http://localhost:8083/connectors/postgres-source/status | jq

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

# PostgreSQL: List tables
docker exec -it postgres psql -U postgres -d inventory -c "\dt"

# PostgreSQL: View table data
docker exec -it postgres psql -U postgres -d inventory -c "SELECT * FROM customers;"

# MongoDB: Connect to database
docker exec -it mongodb mongosh inventory

# MongoDB: List collections
docker exec -it mongodb mongosh inventory --eval "db.getCollectionNames()"

# MongoDB: View collection data
docker exec -it mongodb mongosh inventory --eval "db['postgres.public.customers'].find().pretty()"

# MongoDB: Count documents
docker exec -it mongodb mongosh inventory --eval "db['postgres.public.customers'].countDocuments()"
```

### Kafka Operations

```bash
# List topics
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# Describe a topic
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe --topic postgres.public.customers

# Consume messages from beginning
docker exec -it kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.customers \
  --from-beginning

# Delete a topic
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --delete --topic postgres.public.customers
```

### Container Management

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# Stop and remove volumes (clean slate)
docker-compose down -v

# Rebuild custom Debezium image
docker-compose build debezium

# View container status
docker-compose ps

# View logs
docker-compose logs -f [service_name]

# Restart a specific service
docker-compose restart debezium
```

## Cleanup

To completely remove all data and start fresh:

```bash
# Stop and remove containers, networks, and volumes
docker-compose down -v

# Remove local data directories (if using volume mounts)
rm -rf mongodb-data/* mongodb-log/*

# Restart
docker-compose up -d
```



# Performance Guide: Migrating 2.5 Million Records from PostgreSQL to MongoDB

## Overview
This guide covers performance considerations and tuning for migrating 25 lakh (2.5 million) records from PostgreSQL to MongoDB using Debezium CDC.

---

## 1. Performance Impact Analysis

### Initial Snapshot Phase (One-time load of 2.5M records)

#### PostgreSQL Impact:
- **CPU Usage**: 20-40% increase during snapshot
- **I/O Impact**: Moderate read I/O (sequential scan of tables)
- **Load Type**: Debezium uses `SELECT * FROM table` with snapshot isolation
- **No Table Locks**: Production queries continue normally
- **Duration Estimate**: 
  - Record size: ~1-2KB average = 2.5-5GB total data
  - Network bandwidth dependent
  - **Expected time: 30-60 minutes for 2.5M records**

#### MongoDB Impact:
- **CPU Usage**: 40-60% during initial bulk insert
- **Disk I/O**: Heavy write operations
- **Memory**: WiredTiger cache usage will spike
- **Index Building**: Additional load if indexes exist

---

### CDC (Change Data Capture) Phase (After snapshot)

#### PostgreSQL Impact:
- **CPU Usage**: Very low (1-5%)
- **Replication Slot Overhead**: Minimal (~100-200MB WAL retention)
- **No Table Locks**: Uses logical replication (pgoutput plugin)
- **Production Safe**: Designed for zero production impact

#### MongoDB Impact:
- **CPU Usage**: Low (5-10%)
- **Writes**: Only incremental changes (inserts/updates/deletes)
- **Latency**: Sub-second synchronization

---

## 2. Performance Tuning Configurations

### A. PostgreSQL Source Connector (postgres-source.json)

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
        "transforms.unwrap.delete.handling.mode": "none",
        
        "snapshot.mode": "initial",
        "snapshot.fetch.size": "2000",
        "snapshot.max.threads": "1",
        "max.batch.size": "2048",
        "max.queue.size": "8192",
        "poll.interval.ms": "100",
        "heartbeat.interval.ms": "10000"
    }
}
```

**Key Performance Parameters:**
- `snapshot.fetch.size`: 2000 - Balance between memory and speed
- `max.batch.size`: 2048 - Larger batches for high throughput
- `max.queue.size`: 8192 - Buffer for CDC events
- `poll.interval.ms`: 100 - How often to check for changes

---

### B. MongoDB Sink Connector (mongodb-sink.json)

```json
{
  "name": "mongodb-sink",
  "config": {
    "connector.class": "com.mongodb.kafka.connect.MongoSinkConnector",
    "topics": "postgres.public.customers,postgres.public.orders,postgres.public.products",
    "connection.uri": "mongodb://mongodb:27017",
    "database": "inventory",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "document.id.strategy": "com.mongodb.kafka.connect.sink.processor.id.strategy.FullKeyStrategy",
    "delete.on.null.values": "true",
    
    "max.batch.size": "100",
    "rate.limiting.timeout": "0",
    "rate.limiting.every.n": "0",
    "bulk.write.ordered": "false",
    "retries.defer.timeout": "5000",
    "max.num.retries": "3",
    "topic.override.postgres.public.customers.collection": "customers",
    "topic.override.postgres.public.orders.collection": "orders",
    "topic.override.postgres.public.products.collection": "products"
  }
}
```

**Key Performance Parameters:**
- `max.batch.size`: 100 - Batch writes to MongoDB
- `bulk.write.ordered`: false - Parallel writes (faster but less strict ordering)
- `rate.limiting.timeout`: 0 - No rate limiting for maximum speed
- `retries.defer.timeout`: 5000 - Retry failed operations

---

## 3. Load Testing Estimates

| Phase | PostgreSQL CPU | MongoDB CPU | Network Bandwidth | Duration |
|-------|----------------|-------------|-------------------|----------|
| **Initial Snapshot** (2.5M records) | 20-40% | 40-60% | ~100-200 Mbps | 30-60 min |
| **CDC Steady State** | 1-5% | 5-10% | ~1-10 Mbps | Ongoing |
| **Peak Write Load** | 5-10% | 20-30% | ~50 Mbps | 5-10 min |

---

## 4. Migration Strategies

### Option A: Off-Peak Migration (Recommended)
```bash
# Schedule snapshot during low-traffic hours (e.g., 2 AM - 4 AM)
# Use default snapshot.mode = "initial"
# Expected impact: Minimal to production workload
```

**Pros:**
- Minimal production impact
- Full control over timing
- Easier rollback if issues occur

**Cons:**
- Requires maintenance window
- May need approval for off-hours work

---

### Option B: Incremental Table-by-Table Migration
```json
// Step 1: Migrate customers only
"table.include.list": "public.customers"

// Step 2: Add orders (after customers complete)
"table.include.list": "public.customers,public.orders"

// Step 3: Add products
"table.include.list": "public.customers,public.orders,public.products"
```

**Pros:**
- Spreads load over time
- Easier to monitor and troubleshoot
- Can pause between tables

**Cons:**
- Longer total migration time
- Multiple connector updates required

---

### Option C: Parallel Processing (For 5M+ records)
```json
// Increase parallel tasks
"tasks.max": "4"  // Instead of "1"

// Split by table
"table.include.list": "public.customers"  // Connector 1
"table.include.list": "public.orders"     // Connector 2
"table.include.list": "public.products"   // Connector 3
```

**Pros:**
- Fastest migration time
- Maximizes hardware utilization

**Cons:**
- Higher resource usage
- More complex setup
- Requires careful monitoring

---

## 5. Monitoring During Migration

### Monitor PostgreSQL Replication Lag
```bash
# Check replication slot status
docker exec postgres psql -U postgres -d inventory -c "
SELECT 
    slot_name,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size
FROM pg_replication_slots;
"
```

### Monitor Kafka Connect Status
```bash
# Check connector status
curl -s http://localhost:8083/connectors/postgres-source/status | jq '.'

# Check sink connector status
curl -s http://localhost:8083/connectors/mongodb-sink/status | jq '.'

# Monitor connector metrics
curl -s http://localhost:8083/connectors/postgres-source/metrics | jq '.'
```

### Monitor MongoDB Write Performance
```bash
# Check MongoDB operations per second
docker exec mongodb mongosh --eval "
db.serverStatus().opcounters
"

# Check current operations
docker exec mongodb mongosh --eval "
db.currentOp()
"

# Check collection stats
docker exec mongodb mongosh inventory --eval "
db.customers.stats()
"
```

### Monitor System Resources
```bash
# PostgreSQL CPU/Memory
docker stats postgres --no-stream

# MongoDB CPU/Memory
docker stats mongodb --no-stream

# Kafka Connect CPU/Memory
docker stats connect --no-stream
```

---

## 6. Expected Timeline for 2.5M Records

| Stage | Duration | PostgreSQL Load | MongoDB Load | Details |
|-------|----------|-----------------|--------------|---------|
| **Connector Setup** | 1-2 min | None | None | Register connectors |
| **Initial Snapshot** | 30-60 min | 20-40% CPU | 40-60% CPU | Full table scan + bulk insert |
| **Catch-up Replication** | 5-10 min | 10-20% CPU | 20-30% CPU | Process WAL backlog |
| **Steady-state CDC** | Ongoing | 1-5% CPU | 5-10% CPU | Real-time sync |

**Total Migration Time: ~45-75 minutes**

---

## 7. Risk Mitigation Strategies

### 1. Test with Subset First
```sql
-- Create test table with 10,000 records
CREATE TABLE customers_test AS 
SELECT * FROM customers LIMIT 10000;

-- Test connector with small dataset
"table.include.list": "public.customers_test"
```

### 2. Monitor Replication Slot Size
```sql
-- Prevent WAL disk full
SELECT 
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS confirmed_lag
FROM pg_replication_slots;

-- Alert if lag > 1GB
```

### 3. Set WAL Retention Safety Limits
```sql
-- Set maximum WAL retention (prevents disk full)
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';
SELECT pg_reload_conf();
```

### 4. Create Rollback Plan
```bash
# Backup MongoDB before migration
docker exec mongodb mongodump --out /backup/pre-migration

# Drop replication slot if migration fails
docker exec postgres psql -U postgres -c "
SELECT pg_drop_replication_slot('debezium_slot');
"
```

---

## 8. Production Checklist

### Before Migration
- [ ] Test with subset of data (10k-100k records)
- [ ] Verify disk space on PostgreSQL (WAL logs)
- [ ] Verify disk space on MongoDB (data + indexes)
- [ ] Set up monitoring dashboards
- [ ] Schedule maintenance window (if using off-peak strategy)
- [ ] Notify stakeholders of migration timeline
- [ ] Create rollback plan
- [ ] Backup MongoDB database

### During Migration
- [ ] Monitor PostgreSQL replication lag
- [ ] Monitor MongoDB write performance
- [ ] Monitor Kafka Connect health
- [ ] Check for connector errors every 10 minutes
- [ ] Monitor system resources (CPU, memory, disk I/O)
- [ ] Verify sample records in MongoDB

### After Migration
- [ ] Verify record counts match (PostgreSQL vs MongoDB)
- [ ] Test INSERT, UPDATE, DELETE operations
- [ ] Monitor CDC latency (should be <1 second)
- [ ] Document any issues encountered
- [ ] Update runbooks with lessons learned

---

## 9. Performance Optimization Tips

### PostgreSQL Optimization
```sql
-- Increase shared_buffers for better performance
ALTER SYSTEM SET shared_buffers = '2GB';

-- Increase max_wal_size to reduce checkpoints during snapshot
ALTER SYSTEM SET max_wal_size = '4GB';

-- Reload configuration
SELECT pg_reload_conf();
```

### MongoDB Optimization
```javascript
// Disable validation during initial load (re-enable after)
db.runCommand({
    collMod: "customers",
    validationLevel: "off"
});

// Create indexes AFTER initial load (faster)
// Run this after snapshot completes
db.customers.createIndex({ id: 1 });
db.customers.createIndex({ email: 1 });
```

### Kafka Connect Optimization
```json
// Increase Kafka Connect heap memory
// Edit docker-compose.yaml:
environment:
  KAFKA_HEAP_OPTS: "-Xms2G -Xmx4G"
```

---

## 10. Troubleshooting Common Issues

### Issue 1: Snapshot Taking Too Long
**Symptoms:** Snapshot phase exceeds 2 hours

**Solutions:**
```json
// Increase fetch size
"snapshot.fetch.size": "5000"

// Increase batch size
"max.batch.size": "4096"

// Check network bandwidth between containers
```

### Issue 2: Replication Slot Consuming Too Much Disk
**Symptoms:** PostgreSQL disk fills up with WAL logs

**Solutions:**
```sql
-- Check slot lag
SELECT slot_name, 
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) 
FROM pg_replication_slots;

-- Set retention limit
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';
```

### Issue 3: MongoDB Write Performance Degradation
**Symptoms:** MongoDB CPU hits 100%, writes slow down

**Solutions:**
```json
// Reduce batch size
"max.batch.size": "50"

// Enable rate limiting
"rate.limiting.timeout": "1000",
"rate.limiting.every.n": "10"
```

### Issue 4: Connector Keeps Failing
**Symptoms:** Task state = FAILED repeatedly

**Solutions:**
```bash
# Check connector logs
docker logs connect | grep ERROR

# Check PostgreSQL logs
docker logs postgres | grep ERROR

# Check MongoDB logs
docker logs mongodb | grep ERROR

# Common fixes:
# 1. Increase max.num.retries
# 2. Increase retries.defer.timeout
# 3. Check network connectivity
```

---

## 11. Cost Analysis

### Compute Resources (for 2.5M records)
| Resource | Current Usage | During Snapshot | Recommended |
|----------|---------------|-----------------|-------------|
| PostgreSQL | 2 CPU, 4GB RAM | 2 CPU, 4GB RAM | ✅ Sufficient |
| MongoDB | 2 CPU, 4GB RAM | 2 CPU, 4GB RAM | ✅ Sufficient |
| Kafka Connect | 1 CPU, 2GB RAM | 1 CPU, 2GB RAM | ⚠️ Consider 2 CPU, 4GB RAM |

### Storage Requirements
| Component | Current | During Migration | Post-Migration |
|-----------|---------|------------------|----------------|
| PostgreSQL WAL | ~500MB | ~2-5GB | ~500MB |
| MongoDB Data | 0 | ~3-4GB | ~3-4GB |
| Kafka Topics | ~100MB | ~500MB-1GB | ~100MB |

---

## 12. Summary

### ✅ Safe for Production
- Designed for zero-downtime migrations
- PostgreSQL load: 20-40% during snapshot, <5% during CDC
- MongoDB load: 40-60% during snapshot, <10% during CDC

### ⏱️ Timeline
- **Initial snapshot**: 30-60 minutes for 2.5M records
- **Catch-up**: 5-10 minutes
- **Total**: ~45-75 minutes
- **CDC latency**: <1 second ongoing

### 💡 Recommendations
1. **Run initial snapshot during maintenance window or low-traffic period**
2. **Monitor replication lag and system resources closely**
3. **Test with 10k-100k records first**
4. **Have rollback plan ready**
5. **Use bulk.write.ordered=false for faster writes**

### 📊 Expected Performance
- **Throughput**: ~40,000-50,000 records/minute during snapshot
- **CDC latency**: <1 second for real-time changes
- **Network bandwidth**: 100-200 Mbps during snapshot

---

## 13. Support and Resources

### Useful Commands
```bash
# Quick health check
curl -s http://localhost:8083/connectors/postgres-source/status | jq '.tasks[0].state'

# Record count comparison
docker exec postgres psql -U postgres -d inventory -c "SELECT COUNT(*) FROM customers;"
docker exec mongodb mongosh inventory --eval "db.customers.countDocuments()"

# Reset connector (if needed)
curl -X DELETE http://localhost:8083/connectors/postgres-source
curl -X POST http://localhost:8083/connectors/ -d @postgres-source.json
```

### Documentation Links
- Debezium PostgreSQL Connector: https://debezium.io/documentation/reference/stable/connectors/postgresql.html
- MongoDB Kafka Connector: https://www.mongodb.com/docs/kafka-connector/current/
- Performance Tuning: https://debezium.io/documentation/reference/stable/operations/performance.html

---

**Document Version:** 1.0  
**Last Updated:** November 8, 2025  
**Author:** Debezium CDC Setup Team


## References

- [Debezium PostgreSQL Connector Documentation](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [MongoDB Kafka Connector Documentation](https://www.mongodb.com/docs/kafka-connector/current/)
- [Kafka Connect Documentation](https://kafka.apache.org/documentation/#connect)
- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/current/logical-replication.html)
- [Reference Article: MongoDB to PostgreSQL CDC](https://gunesramazan.medium.com/real-time-data-flow-from-mongodb-to-postgresql-with-debezium-setup-configuration-and-example-2482c3dbb88c)


## License

This project is for educational and demonstration purposes.



