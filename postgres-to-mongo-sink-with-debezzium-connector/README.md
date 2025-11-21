# PostgreSQL to MongoDB CDC with Debezium

This project demonstrates **real-time Change Data Capture (CDC)** from PostgreSQL to MongoDB using **Debezium MongoDB Sink Connector**. It captures the complete CDC event structure including **`before`** and **`after`** fields for full change tracking.

## Key Features

- ✅ Full CDC event structure with `before` and `after` fields
- ✅ Supports INSERT, UPDATE, and DELETE operations  
- ✅ Uses Debezium's native MongoDB Sink Connector
- ✅ PostgreSQL replica identity set to FULL for complete change tracking
- ✅ Production-ready configuration with proper error handling

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Files](#configuration-files)
- [Testing the Pipeline](#testing-the-pipeline)
- [CDC Event Structure](#cdc-event-structure)
- [Troubleshooting](#troubleshooting)
- [Useful Commands](#useful-commands)
- [Cleanup](#cleanup)

## Architecture Overview

```text
PostgreSQL (Source Database)
    ↓ WAL + Logical Replication
Debezium PostgreSQL Connector
    ↓ Full CDC Events (before + after)
Apache Kafka
    ↓ Event Streaming
Debezium MongoDB Sink Connector
    ↓ Write Operations
MongoDB (Sink Database)
```

### Components

- **PostgreSQL 17.6**: Source database with `wal_level=logical` and `REPLICA IDENTITY FULL`
- **Apache Kafka**: Message broker for CDC event streaming
- **Debezium Connect**: Kafka Connect with PostgreSQL source and MongoDB sink connectors
- **MongoDB**: Target database in replica set mode
- **Kafka UI (AKHQ)**: Web interface at <http://localhost:7080>
- **Debezium UI**: Web interface at <http://localhost:8082>

## Prerequisites

- Docker and Docker Compose installed
- At least 4GB RAM available
- Free ports: 5433, 9092-9093, 8083, 8082, 7080, 27017

## Quick Start

### 1. Clone or Create Project Structure

```bash
mkdir postgres-to-mongodb
cd postgres-to-mongodb
```

Your project should have these files:

```text
postgres-to-mongodb/
├── docker-compose.yaml
├── postgres-source.json
├── mongodb-sink.json
├── scripts/
│   └── init-postgres.sql
└── README.md
```

### 2. Start All Services

```bash
# Start all services
docker-compose up -d

# Wait 30-60 seconds for services to become healthy
docker-compose ps
```

Expected output:

```text
NAME          STATUS
debezium      Up (healthy)
mongodb       Up (healthy)
postgres      Up (healthy)
kafka         Up (healthy)
kafka-ui      Up
debezium-ui   Up
```

### 3. Configure PostgreSQL Replica Identity

**IMPORTANT**: This step is required to capture `before` values in UPDATE and DELETE events.

```bash
docker exec -i postgres psql -U postgres -d inventory << 'EOF'
ALTER TABLE customers REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE products REPLICA IDENTITY FULL;
EOF
```

**What these commands do:**

| Command | Purpose |
|---------|---------|
| `ALTER TABLE <table> REPLICA IDENTITY FULL` | Captures all column values in the `before` field for UPDATE/DELETE operations |

**Replica Identity Options:**

- **DEFAULT** (default): Only primary key is included in `before` field
- **FULL**: All columns are included in `before` field (required for full CDC tracking)
- **INDEX**: Uses a specific unique index
- **NOTHING**: No `before` data is captured

**Verify replica identity settings:**

```bash
docker exec postgres psql -U postgres -d inventory -c \
  "SELECT schemaname, tablename, 
   CASE relreplident 
     WHEN 'd' THEN 'DEFAULT' 
     WHEN 'f' THEN 'FULL' 
     WHEN 'i' THEN 'INDEX' 
     WHEN 'n' THEN 'NOTHING' 
   END as replica_identity
   FROM pg_catalog.pg_tables t 
   JOIN pg_class c ON t.tablename = c.relname 
   WHERE schemaname = 'public';"
```

Expected output:

```text
 schemaname | tablename | replica_identity 
------------+-----------+------------------
 public     | customers | FULL
 public     | orders    | FULL
 public     | products  | FULL
```

### 4. Register Connectors

**PostgreSQL Source Connector:**

```bash
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @postgres-source.json
```

**MongoDB Sink Connector:**

```bash
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @mongodb-sink.json
```

### 5. Verify Setup

```bash
# Check connectors are running
curl http://localhost:8083/connectors

# Check connector status
curl -s http://localhost:8083/connectors/postgres-source/status | jq '.connector.state'
curl -s http://localhost:8083/connectors/mongodb-sink/status | jq '.connector.state'

# Both should return: "RUNNING"
```

### 6. Verify Data Replication

```bash
# Check MongoDB has the data (collections use clean table names)
docker exec mongodb mongosh inventory --eval "db.customers.find().pretty()"
docker exec mongodb mongosh inventory --eval "db.orders.find().pretty()"
docker exec mongodb mongosh inventory --eval "db.products.find().pretty()"
```

🎉 **Your CDC pipeline is now operational!**

## Configuration Files

### docker-compose.yaml

The complete Docker Compose configuration orchestrates all services:

- PostgreSQL with `wal_level=logical` for CDC
- Kafka in KRaft mode (no Zookeeper required)
- MongoDB in replica set mode
- Debezium Connect (official image with MongoDB sink connector included)
- Web UIs for monitoring

> **Note:** The official `quay.io/debezium/connect:latest` image already includes the MongoDB sink connector (`io.debezium.connector.mongodb.MongoDbSinkConnector`), so no custom Dockerfile is needed.

### postgres-source.json

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
        "slot.name": "debezium_slot_cdc",
        "key.converter": "org.apache.kafka.connect.json.JsonConverter",
        "key.converter.schemas.enable": "false",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "value.converter.schemas.enable": "false"
    }
}
```

**Key Configuration Points:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `plugin.name` | `pgoutput` | PostgreSQL's built-in logical replication plugin |
| `slot.name` | `debezium_slot_cdc` | Unique replication slot name |
| `schemas.enable` | `false` | Produces schema-less JSON for easier consumption |
| **NO `transforms`** | - | **Preserves full CDC envelope with `before` and `after`** |

### mongodb-sink.json

```json
{
    "name": "mongodb-sink",
    "config": {
        "connector.class": "io.debezium.connector.mongodb.MongoDbSinkConnector",
        "tasks.max": "1",
        "topics": "postgres.public.customers,postgres.public.orders,postgres.public.products",
        "mongodb.connection.string": "mongodb://mongodb:27017/?replicaSet=rs0",
        "sink.database": "inventory",
        "change.data.capture.handler": "io.debezium.connector.mongodb.sink.changestream.handler.MongoDbCdcHandler",
        "delete.enabled": "true",
        "delete.on.null.values": "true",
        "collection.name.format": "${source.table}",
        "key.converter": "org.apache.kafka.connect.json.JsonConverter",
        "key.converter.schemas.enable": "true",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "value.converter.schemas.enable": "true",
        "errors.tolerance": "all",
        "errors.log.enable": "true",
        "errors.log.include.messages": "true"
    }
}
```

**Key Configuration Points:**

| Setting | Value | Purpose |
|---------|-------|---------||
| `connector.class` | `io.debezium.connector.mongodb.MongoDbSinkConnector` | Debezium's native MongoDB sink |
| `topics` | Topic list | Kafka topics to consume |
| `mongodb.connection.string` | `mongodb://mongodb:27017/?replicaSet=rs0` | MongoDB replica set connection |
| `sink.database` | `inventory` | Target MongoDB database |
| `change.data.capture.handler` | `MongoDbCdcHandler` | **Required to process CDC events (INSERT/UPDATE/DELETE)** |
| `delete.enabled` | `true` | **Enables DELETE operation handling** |
| `delete.on.null.values` | `true` | **Treats null values as DELETE operations** |
| `collection.name.format` | `${source.table}` | **Extracts table name for clean collection naming (e.g., "customers" instead of "postgres_public_customers")** |
| `schemas.enable` | `true` | **Required for CDC handler to parse before/after fields** |
| `errors.tolerance` | `all` | Allows connector to continue on non-critical errors |
| `errors.log.enable` | `true` | Logs errors for debugging |

## Testing the Pipeline

### Test INSERT

```bash
docker exec postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email) 
   VALUES ('Alice', 'Wonder', 'alice@example.com');"

# Verify in MongoDB
docker exec mongodb mongosh inventory --eval "db.customers.find({first_name: 'Alice'}).pretty()"
```

### Test UPDATE

```bash
docker exec postgres psql -U postgres -d inventory -c \
  "UPDATE customers SET email = 'alice.updated@example.com' WHERE first_name = 'Alice';"

# Verify in MongoDB
docker exec mongodb mongosh inventory --eval "db.customers.find({first_name: 'Alice'}).pretty()"
```

### Test DELETE

```bash
docker exec postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE first_name = 'Alice';"

# Verify DELETE in MongoDB (should return 0)
docker exec mongodb mongosh inventory --eval "db.customers.countDocuments({first_name: 'Alice'})"
# Should return: 0
```

## CDC Event Structure

### INSERT Event (`op: "c"`)

```json
{
  "before": null,
  "after": {
    "id": 1,
    "first_name": "John",
    "last_name": "Doe",
    "email": "john.doe@example.com",
    "created_at": 1763697242160930
  },
  "source": {
    "version": "3.2.2.Final",
    "connector": "postgresql",
    "name": "postgres",
    "ts_ms": 1763697319348,
    "db": "inventory",
    "schema": "public",
    "table": "customers",
    "txId": 758,
    "lsn": 26685800
  },
  "op": "c",
  "ts_ms": 1763697319396
}
```

### UPDATE Event (`op: "u"`)

```json
{
  "before": {
    "id": 1,
    "first_name": "Jane",
    "last_name": "Doe",
    "email": "old@example.com",
    "created_at": 1763697242160930
  },
  "after": {
    "id": 1,
    "first_name": "Janet",
    "last_name": "Doe",
    "email": "new@example.com",
    "created_at": 1763697242160930
  },
  "source": { },
  "op": "u",
  "ts_ms": 1763698756505
}
```

### DELETE Event (`op: "d"`)

```json
{
  "before": {
    "id": 5,
    "first_name": "Alice",
    "last_name": "Wonder",
    "email": "alice@example.com",
    "created_at": 1763697453641480
  },
  "after": null,
  "source": { },
  "op": "d",
  "ts_ms": 1763698806071
}
```

## Troubleshooting

### Issue: DELETE Operations Not Working

**Symptom:** DELETE operations in PostgreSQL are not reflected in MongoDB. MongoDB sink connector fails with `NullPointerException: Cannot invoke "org.apache.kafka.connect.data.Schema.type()" because "schema" is null`.

**Root Cause:** PostgreSQL sends tombstone records (null value, null schema) after DELETE events, which causes the MongoDB CDC handler to crash.

**Solution:**

1. Add `tombstones.on.delete: false` to `postgres-source.json`:
```json
{
    "config": {
        ...
        "tombstones.on.delete": "false",
        ...
    }
}
```

2. Ensure MongoDB sink has proper DELETE configuration:
```json
{
    "config": {
        ...
        "change.data.capture.handler": "io.debezium.connector.mongodb.sink.changestream.handler.MongoDbCdcHandler",
        "delete.enabled": "true",
        "delete.on.null.values": "true",
        ...
    }
}
```

3. Restart connectors:
```bash
curl -X DELETE http://localhost:8083/connectors/postgres-source
curl -X DELETE http://localhost:8083/connectors/mongodb-sink
sleep 3
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @postgres-source.json
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @mongodb-sink.json
```

### Issue: Missing `before` Field in UPDATE/DELETE Events

**Symptom:** `before` field is always `null` even for UPDATE and DELETE operations.

**Solution:**

```bash
# Set REPLICA IDENTITY FULL for all tables
docker exec -i postgres psql -U postgres -d inventory << 'EOF'
ALTER TABLE customers REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE products REPLICA IDENTITY FULL;
EOF

# Verify the change
docker exec postgres psql -U postgres -d inventory -c \
  "SELECT schemaname, tablename, 
   CASE relreplident 
     WHEN 'd' THEN 'DEFAULT' 
     WHEN 'f' THEN 'FULL' 
     WHEN 'i' THEN 'INDEX' 
     WHEN 'n' THEN 'NOTHING' 
   END as replica_identity
   FROM pg_catalog.pg_tables t 
   JOIN pg_class c ON t.tablename = c.relname 
   WHERE schemaname = 'public';"
```

Expected output shows `FULL` for all tables.

### Issue: Connector Not Running

```bash
# Check connector status
curl -s http://localhost:8083/connectors/postgres-source/status | jq

# View connector logs
docker-compose logs -f debezium

# Restart connector
curl -X POST http://localhost:8083/connectors/postgres-source/restart
```

### Issue: No Data in MongoDB

```bash
# Check Kafka topics
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list

# Consume messages from topic
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.customers \
  --from-beginning \
  --max-messages 5
```

## Useful Commands

### Connector Management

```bash
# List all connectors
curl http://localhost:8083/connectors

# Get connector status
curl -s http://localhost:8083/connectors/postgres-source/status | jq

# Get connector configuration
curl -s http://localhost:8083/connectors/postgres-source | jq

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
# PostgreSQL: Query data
docker exec postgres psql -U postgres -d inventory -c "SELECT * FROM customers;"

# MongoDB: Query data (collections use clean table names)
docker exec mongodb mongosh inventory --eval "db.customers.find().pretty()"
docker exec mongodb mongosh inventory --eval "db.orders.find().pretty()"
docker exec mongodb mongosh inventory --eval "db.products.find().pretty()"

# MongoDB: Count documents
docker exec mongodb mongosh inventory --eval "db.customers.countDocuments()"

# PostgreSQL: Check replica identity
docker exec postgres psql -U postgres -d inventory -c \
  "SELECT schemaname, tablename, relreplident FROM pg_catalog.pg_tables t 
   JOIN pg_class c ON t.tablename = c.relname WHERE schemaname = 'public';"
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

# Consume messages
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic postgres.public.customers \
  --from-beginning
```

### Container Management

```bash
# View logs
docker-compose logs -f
docker-compose logs -f debezium

# Restart services
docker-compose restart debezium

# Stop all services
docker-compose down

# Stop and remove all data
docker-compose down -v
```

## Cleanup

```bash
# Delete connectors
curl -X DELETE http://localhost:8083/connectors/postgres-source
curl -X DELETE http://localhost:8083/connectors/mongodb-sink

# Stop and remove all containers
docker-compose down -v

# Remove data directories (optional)
rm -rf mongodb-data mongodb-log
```

## Important Notes

### Why No `transforms` Configuration?

The PostgreSQL source connector configuration **intentionally omits** the `ExtractNewRecordState` transform (also known as "unwrap"). This is **critical** for preserving the full CDC envelope structure:

**❌ With unwrap transform:**

```json
{
  "id": 1,
  "first_name": "John",
  "email": "john@example.com"
}
```

**✅ Without unwrap transform (our configuration):**

```json
{
  "before": { },
  "after": { },
  "op": "u",
  "source": { }
}
```

The Debezium MongoDB Sink Connector **requires the full CDC envelope** to properly handle all operation types.

### DELETE Operations and Tombstone Handling

**Important:** By default, Debezium PostgreSQL connector sends **two messages** for each DELETE operation:

1. **DELETE event** - Contains the `before` field with deleted data
2. **Tombstone record** - A null message for Kafka log compaction

The tombstone record has both null value and null schema, which causes the MongoDB CDC handler to crash with:
```
NullPointerException: Cannot invoke "org.apache.kafka.connect.data.Schema.type()" because "schema" is null
```

**Solution:** Set `tombstones.on.delete: false` in the PostgreSQL source connector to prevent tombstone generation. The DELETE event itself is sufficient for MongoDB to process the deletion.

**Why this works:**
- MongoDB CDC handler processes the DELETE event (`op: "d"`) with the `before` field
- No tombstone means no null schema to cause the crash
- DELETE operations propagate correctly to MongoDB

### PostgreSQL Configuration Explained

#### WAL (Write-Ahead Log) Settings

The docker-compose.yaml includes these critical PostgreSQL configurations:

```yaml
command: ["postgres", "-c", "wal_level=logical", "-c", "max_wal_senders=4", "-c", "max_replication_slots=4"]
```

**Configuration parameters:**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `wal_level` | `logical` | **Required for CDC**. Enables logical replication by writing additional information to WAL |
| `max_wal_senders` | `4` | Maximum concurrent replication connections. Set to number of connectors + buffer |
| `max_replication_slots` | `4` | Maximum replication slots. Each Debezium connector uses one slot |

**Why these settings are required:**

- `wal_level=logical` is **mandatory** for Debezium to capture changes
- Without logical WAL level, Debezium cannot read the change stream
- Default PostgreSQL WAL level is `replica` (physical replication only)

**Performance considerations:**

- Logical WAL adds ~5-10% overhead to write operations
- WAL files are larger with logical replication
- Replication slots prevent WAL cleanup until changes are consumed
- Monitor disk space if Debezium connector is stopped

**Check current settings:**

```bash
docker exec postgres psql -U postgres -c "SHOW wal_level;"
docker exec postgres psql -U postgres -c "SHOW max_wal_senders;"
docker exec postgres psql -U postgres -c "SHOW max_replication_slots;"
```

---

### Production Setup (AWS RDS PostgreSQL)

For AWS RDS PostgreSQL, you **cannot use command-line parameters**. Instead, modify the **DB Parameter Group**.

#### Step 1: Modify RDS Parameter Group

**Option A: AWS Console**

1. Go to AWS RDS Console → Parameter Groups
2. Create a new parameter group (or modify existing)
3. Edit parameters:
   - `rds.logical_replication` = `1` (RDS-specific, enables logical replication)
   - `max_wal_senders` = `4` (or higher)
   - `max_replication_slots` = `4` (or higher)
4. Save changes
5. Apply parameter group to your RDS instance
6. **Reboot the RDS instance** (required for `rds.logical_replication`)

**Option B: AWS CLI**

```bash
# Create parameter group (if needed)
aws rds create-db-parameter-group \
  --db-parameter-group-name debezium-postgres-params \
  --db-parameter-group-family postgres17 \
  --description "Parameter group for Debezium CDC"

# Modify parameters
aws rds modify-db-parameter-group \
  --db-parameter-group-name debezium-postgres-params \
  --parameters \
    "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" \
    "ParameterName=max_wal_senders,ParameterValue=10,ApplyMethod=immediate" \
    "ParameterName=max_replication_slots,ParameterValue=10,ApplyMethod=immediate"

# Apply to RDS instance
aws rds modify-db-instance \
  --db-instance-identifier your-db-instance \
  --db-parameter-group-name debezium-postgres-params \
  --apply-immediately

# Reboot (required for logical replication)
aws rds reboot-db-instance --db-instance-identifier your-db-instance
```

**Important Notes:**

- `rds.logical_replication=1` automatically sets `wal_level=logical` on RDS
- **Reboot is required** for logical replication to take effect
- `max_wal_senders` and `max_replication_slots` can be applied immediately

#### Step 2: Configure Replica Identity (No Reboot Required)

After the parameter group is applied and RDS is rebooted, connect to your RDS instance and run:

```sql
-- Connect to your RDS instance
psql -h your-rds-endpoint.rds.amazonaws.com -U postgres -d inventory

-- Set replica identity for tables
ALTER TABLE customers REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE products REPLICA IDENTITY FULL;

-- Or apply to all tables in public schema
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    LOOP
        EXECUTE format('ALTER TABLE %I REPLICA IDENTITY FULL', r.tablename);
        RAISE NOTICE 'Set REPLICA IDENTITY FULL for table: %', r.tablename;
    END LOOP;
END $$;
```

#### Step 3: Verify RDS Configuration

```sql
-- Check logical replication is enabled
SHOW wal_level;
-- Should return: logical

-- Check WAL senders
SHOW max_wal_senders;
-- Should return: 10 (or your configured value)

-- Check replication slots
SHOW max_replication_slots;
-- Should return: 10 (or your configured value)

-- Check replica identity for tables
SELECT schemaname, tablename, 
  CASE relreplident 
    WHEN 'd' THEN 'DEFAULT' 
    WHEN 'f' THEN 'FULL' 
    WHEN 'i' THEN 'INDEX' 
    WHEN 'n' THEN 'NOTHING' 
  END as replica_identity
FROM pg_catalog.pg_tables t 
JOIN pg_class c ON t.tablename = c.relname 
WHERE schemaname = 'public';
```

#### Step 4: Update Debezium Connector Configuration

Update your `postgres-source.json` with RDS endpoint:

```json
{
    "name": "postgres-source",
    "config": {
        "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
        "tasks.max": "1",
        "database.hostname": "your-rds-endpoint.rds.amazonaws.com",
        "database.port": "5432",
        "database.user": "postgres",
        "database.password": "your-password",
        "database.dbname": "inventory",
        "database.server.name": "postgres",
        "topic.prefix": "postgres",
        "table.include.list": "public.customers,public.orders,public.products",
        "plugin.name": "pgoutput",
        "publication.autocreate.mode": "filtered",
        "slot.name": "debezium_slot_cdc",
        "key.converter": "org.apache.kafka.connect.json.JsonConverter",
        "key.converter.schemas.enable": "false",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "value.converter.schemas.enable": "false"
    }
}
```

#### Production Checklist

- [ ] Create/modify RDS parameter group with `rds.logical_replication=1`
- [ ] Set `max_wal_senders` ≥ 10
- [ ] Set `max_replication_slots` ≥ 10
- [ ] Apply parameter group to RDS instance
- [ ] **Reboot RDS instance** (one-time, schedule during maintenance window)
- [ ] Verify `wal_level=logical` after reboot
- [ ] Run `ALTER TABLE` commands for replica identity (no reboot needed)
- [ ] Update Debezium connector with RDS endpoint
- [ ] Test with sample data

#### Downtime Considerations

| Action | Downtime Required | Can be Scheduled |
|--------|------------------|------------------|
| Parameter group modification | No | N/A |
| RDS reboot for logical replication | **Yes** (~2-5 minutes) | Yes (maintenance window) |
| ALTER TABLE replica identity | No | N/A |
| Debezium connector setup | No | N/A |

**Recommendation:** Schedule the RDS reboot during a planned maintenance window. All other steps can be done without downtime.

---

### Why REPLICA IDENTITY FULL?

PostgreSQL's default replica identity (`DEFAULT`) only includes the primary key in the `before` field. Setting it to `FULL` includes **all columns**, which is necessary for:

- Complete change tracking
- Audit trails
- Conflict resolution
- Understanding what changed in UPDATE operations

**Performance Impact:** Minimal for most workloads. The `before` data is already in memory during the transaction.

**To change replica identity for existing tables:**

```bash
# For all tables in public schema
docker exec -i postgres psql -U postgres -d inventory << 'EOF'
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    LOOP
        EXECUTE format('ALTER TABLE %I REPLICA IDENTITY FULL', r.tablename);
    END LOOP;
END $$;
EOF
```

**To revert to DEFAULT (if needed):**

```bash
docker exec -i postgres psql -U postgres -d inventory << 'EOF'
ALTER TABLE customers REPLICA IDENTITY DEFAULT;
ALTER TABLE orders REPLICA IDENTITY DEFAULT;
ALTER TABLE products REPLICA IDENTITY DEFAULT;
EOF
```

### Supported Operations

| Operation | PostgreSQL | Kafka Event | MongoDB Result |
|-----------|------------|-------------|----------------|
| INSERT | `INSERT` | `op: "c"` | Document created |
| UPDATE | `UPDATE` | `op: "u"` | Document updated |
| DELETE | `DELETE` | `op: "d"` | Document deleted |
| TRUNCATE | `TRUNCATE` | `op: "t"` | Not propagated by default |

## References

- [Debezium PostgreSQL Connector](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Debezium MongoDB Sink Connector](https://debezium.io/documentation/reference/3.3/connectors/mongodb-sink.html)
- [PostgreSQL Logical Replication](https://www.postgresql.org/docs/current/logical-replication.html)
- [PostgreSQL Replica Identity](https://www.postgresql.org/docs/current/sql-altertable.html#SQL-ALTERTABLE-REPLICA-IDENTITY)

## License

This project is for educational and demonstration purposes.

---

**Created:** November 2025  
**Last Updated:** November 21, 2025
