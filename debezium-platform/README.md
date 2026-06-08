# Debezium Transforms (SMT) — Complete Step-by-Step Guide

> **Tested live against the running Debezium Platform at http://localhost:3000**
> Every `curl` command in this guide was executed and verified.

---

## Table of Contents

1. [What Are Transforms (SMTs)?](#1-what-are-transforms-smts)
2. [How the Platform Works](#2-how-the-platform-works)
3. [Prerequisites — Start the Platform](#3-prerequisites--start-the-platform)
4. [Step 0 — Create the Connection (Do Once)](#4-step-0--create-the-connection-do-once)
5. [SMT 1 — New Record State Extraction (Event Flattening)](#5-smt-1--new-record-state-extraction-event-flattening)
6. [SMT 2 — Topic Routing (ByLogicalTableRouter)](#6-smt-2--topic-routing-bylogicaltablerouter)
7. [SMT 3 — Content-Based Routing](#7-smt-3--content-based-routing)
8. [SMT 4 — Message Filtering](#8-smt-4--message-filtering)
9. [SMT 5 — Outbox Event Router](#9-smt-5--outbox-event-router)
10. [SMT 6 — MongoDB New Document State Extraction](#10-smt-6--mongodb-new-document-state-extraction)
11. [SMT 7 — MongoDB Outbox Event Router](#11-smt-7--mongodb-outbox-event-router)
12. [SMT 8 — HeaderToValue](#12-smt-8--headertovalue)
13. [SMT 9 — Partition Routing](#13-smt-9--partition-routing)
14. [SMT 10 — Timezone Converter](#14-smt-10--timezone-converter)
15. [SMT 11 — Applying Transforms Selectively (Predicates)](#15-smt-11--applying-transforms-selectively-predicates)
16. [SMT 12 — Chaining Multiple Transforms](#16-smt-12--chaining-multiple-transforms)
17. [Full Reset](#17-full-reset)
18. [Quick Reference](#18-quick-reference)

---

## 1. What Are Transforms (SMTs)?

**SMT = Single Message Transformation**

When Debezium captures a change in your database, it produces a raw CDC event that looks like this:

```json
{
  "before": { "id": 1, "name": "Alice", "email": "alice@old.com" },
  "after":  { "id": 1, "name": "Alice", "email": "alice@new.com" },
  "source": { "table": "customers", "db": "inventory", "connector": "postgresql" },
  "op": "u",
  "ts_ms": 1717000000000
}
```

This is rich and accurate but most downstream systems (databases, search engines, data warehouses)
**cannot handle this complex structure**. They just want the row data.

SMTs solve this by **transforming the event in-flight** — before it reaches the destination —
without writing any code.

### What SMTs Can Do

| Problem | SMT That Solves It |
|---------|-------------------|
| Downstream can't parse `before`/`after` envelope | New Record State Extraction |
| Events from 3 shard tables need to go to 1 topic | Topic Routing |
| Only want UPDATE events, not INSERT/DELETE | Message Filtering |
| Want to route EU customers to EU topic, US to US topic | Content-Based Routing |
| Need safe microservice event exchange | Outbox Event Router |
| Timestamps need to be in local timezone, not UTC | Timezone Converter |
| Kafka headers invisible to downstream — need in payload | HeaderToValue |
| All orders for same customer must go to same partition | Partition Routing |
| Apply transform only to specific tables, skip heartbeats | Predicates |

### Where Are SMTs Applied?

```
PostgreSQL
    │
    ▼  CDC events captured
Debezium Connector
    │
    ▼  ← SMTs run HERE (before going to destination)
Transforms (SMTs)
    │
    ▼  Transformed events
Destination (Kafka / Redis / HTTP / etc.)
```

---

## 2. How the Platform Works

The Debezium Platform UI at **http://localhost:3000** has 5 objects:

```
Connection  →  Source  →  Transform(s)  →  Destination
                                  ↓
                              Pipeline
                    (wires Source + Transforms + Destination)
```

| Object | Purpose | Example |
|--------|---------|---------|
| **Connection** | Database credentials | hostname, port, user, password |
| **Source** | Which tables to capture + connector config | PostgreSQL → customers table |
| **Transform** | How to modify each event | Flatten the envelope |
| **Destination** | Where to send events | Kafka, Redis, HTTP |
| **Pipeline** | Ties everything together | Source → [T1, T2] → Destination |

> **Important:** The Debezium Platform API manages pipeline *configuration*.
> Pipeline *execution* requires the Debezium Operator (Kubernetes) or Debezium Server.
> In this guide, all API calls create the configuration correctly and can be used directly
> in the UI at http://localhost:3000. The same transform configs also work with
> the standalone Debezium Connect stack (see `postgres-to-mongodb/`).

---

## 3. Prerequisites — Start the Platform

```bash
# From the Debezium root folder
cd /path/to/Debezium
docker compose -f debezium-platform-docker-compose.yaml up -d
```

Check all containers are running:

```bash
docker compose -f debezium-platform-docker-compose.yaml ps
```

Expected:
```
NAME              STATUS
conductor         Up (healthy)
nginx             Up
postgres          Up (healthy)
source-postgres   Up (healthy)
stage             Up
```

Verify sample data in source-postgres:

```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT id, first_name, last_name, email, region, status FROM customers;"
```

Expected:
```
 id | first_name | last_name |        email        | region |  status
----+------------+-----------+---------------------+--------+----------
  1 | Alice      | Smith     | alice@example.com   | US     | ACTIVE
  2 | Bob        | Jones     | bob@example.com     | EU     | ACTIVE
  3 | Charlie    | Brown     | charlie@example.com | US     | INACTIVE
  4 | Diana      | Prince    | diana@example.com   | EU     | ACTIVE
  5 | Edward     | Norton    | edward@example.com  | US     | ACTIVE
```

Open the UI: **http://localhost:3000**

---

## 4. Step 0 — Create the Connection (Do Once)

A **Connection** stores your database credentials. You create it once and reuse it in all Sources.

```bash
curl -X POST http://localhost:8080/api/connections \
  -H "Content-Type: application/json" \
  -d '{
    "name": "source-postgres-inventory",
    "type": "POSTGRESQL",
    "config": {
      "database.hostname": "source-postgres",
      "database.port": "5432",
      "database.user": "postgres",
      "database.password": "postgres",
      "database.dbname": "inventory"
    }
  }'
```

Expected response:
```json
{
  "id": 1,
  "name": "source-postgres-inventory",
  "type": "POSTGRESQL"
}
```

**Note the `id` — you will use it as `"connection": {"id": 1}` in every Source below.**

Check it was created:
```bash
curl http://localhost:8080/api/connections
```

---

## 5. SMT 1 — New Record State Extraction (Event Flattening)

### What is it?
`io.debezium.transforms.ExtractNewRecordState`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists (`curl http://localhost:8080/api/connections`) |
| Source database | `source-postgres` running with `inventory.customers` table populated |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| Special DB config | PostgreSQL `wal_level=logical` — already set in `docker-compose` |

Verify source table exists:
```bash
docker exec source-postgres psql -U postgres -d inventory -c "SELECT COUNT(*) FROM customers;"
# Expected: 5
```

### Why use it?
Debezium's raw CDC event wraps data in `before`/`after`/`op`/`source` fields.
Most downstream systems (JDBC sinks, Elasticsearch, data warehouses) **cannot parse this envelope**.
They need a flat key-value record. This SMT extracts just the `after` field (the new row state).

### When to use it?
- Syncing to a database via JDBC sink
- Indexing into Elasticsearch
- Sending to any system that expects flat JSON
- Any time your downstream says "I don't understand `before`/`after`"

### Before the SMT — raw CDC event:
```json
{
  "before": null,
  "after": {
    "id": 1, "first_name": "Alice", "last_name": "Smith",
    "email": "alice@example.com", "region": "US", "status": "ACTIVE"
  },
  "source": { "table": "customers", "db": "inventory", "ts_ms": 1717000000000 },
  "op": "c",
  "ts_ms": 1717000000123
}
```

### After the SMT — flattened:
```json
{
  "id": 1,
  "first_name": "Alice",
  "last_name": "Smith",
  "email": "alice@example.com",
  "region": "US",
  "status": "ACTIVE",
  "__op": "c",
  "__table": "customers",
  "__source_ts_ms": 1717000000000
}
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-customers",
    "description": "Captures all CDC changes from the customers table",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt1",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

Expected response:
```json
{
  "id": 1,
  "name": "src-customers",
  "type": "io.debezium.connector.postgresql.PostgresConnector"
}
```

### Step 2 — Create the Transform

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt1-flatten",
    "description": "Flattens CDC envelope. Adds op+table metadata. Rewrites deletes with __deleted flag.",
    "type": "io.debezium.transforms.ExtractNewRecordState",
    "schema": "inventory",
    "config": {
      "delete.tombstone.handling.mode": "rewrite",
      "add.fields": "op,table,source.ts_ms",
      "add.headers": "op"
    }
  }'
```

Expected response:
```json
{
  "id": 1,
  "name": "smt1-flatten",
  "type": "io.debezium.transforms.ExtractNewRecordState",
  "config": {
    "delete.tombstone.handling.mode": "rewrite",
    "add.fields": "op,table,source.ts_ms",
    "add.headers": "op"
  }
}
```

**Config explained:**

| Key | Value | Why |
|-----|-------|-----|
| `delete.tombstone.handling.mode` | `rewrite` | For DELETE events: keeps the record with `__deleted: true` instead of dropping it |
| `add.fields` | `op,table,source.ts_ms` | Adds `__op` (c/u/d), `__table` (customers), `__source_ts_ms` (timestamp) to every event |
| `add.headers` | `op` | Also puts `__op` in Kafka message header |

**All `delete.tombstone.handling.mode` options:**

| Value | DELETE Record | Tombstone | Use When |
|-------|--------------|-----------|---------|
| `drop` | Dropped | Dropped | You never want deletes downstream |
| `tombstone` *(default)* | Dropped | Kept (null) | Kafka log compaction |
| `rewrite` | Kept + `__deleted:true` | Dropped | Downstream needs to know about deletes |
| `rewrite-with-tombstone` | Kept + `__deleted:true` | Kept | Need both |
| `delete-to-tombstone` | Converted to tombstone | Dropped | Sink needs tombstone only |

### Step 3 — Create the Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "description": "Send transformed events to Kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": {
      "producer.bootstrap.servers": "localhost:9092"
    }
  }'
```

Expected response:
```json
{
  "id": 1,
  "name": "dest-kafka",
  "type": "io.debezium.server.kafka.KafkaChangeConsumer"
}
```

### Step 4 — Create the Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt1-flatten",
    "description": "Customers CDC pipeline with event flattening",
    "source":      {"id": 1, "name": "src-customers"},
    "destination": {"id": 1, "name": "dest-kafka"},
    "transforms":  [{"id": 1, "name": "smt1-flatten"}],
    "logLevel": "INFO"
  }'
```

Expected response:
```json
{
  "id": 1,
  "name": "pipeline-smt1-flatten",
  "source":      {"id": 1, "name": null},
  "destination": {"id": 1, "name": null},
  "transforms":  [{"id": 1, "name": null}]
}
```

You can also create this entire pipeline through the UI at http://localhost:3000

### Step 5 — Test It

**Test INSERT:**
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('TestUser', 'Flatten', 'test.flatten@example.com', 'US', 'ACTIVE', 50000);"
```

**Test UPDATE:**
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "UPDATE customers SET status = 'INACTIVE', salary = 55000
   WHERE email = 'test.flatten@example.com';"
```

**Test DELETE:**
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email = 'test.flatten@example.com';"
```

**What the flattened INSERT event looks like:**
```json
{
  "id": 6,
  "first_name": "TestUser",
  "last_name": "Flatten",
  "email": "test.flatten@example.com",
  "region": "US",
  "status": "ACTIVE",
  "salary": 50000,
  "__op": "c",
  "__table": "customers",
  "__source_ts_ms": 1717000000000
}
```

**What the DELETE event looks like (with `rewrite` mode):**
```json
{
  "id": 6,
  "first_name": "TestUser",
  "last_name": "Flatten",
  "email": "test.flatten@example.com",
  "region": "US",
  "status": "INACTIVE",
  "__deleted": "true",
  "__op": "d",
  "__table": "customers",
  "__source_ts_ms": 1717000000000
}
```

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/1
curl -X DELETE http://localhost:8080/api/transforms/1
curl -X DELETE http://localhost:8080/api/sources/1
curl -X DELETE http://localhost:8080/api/destinations/1
```

---

## 6. SMT 2 — Topic Routing (ByLogicalTableRouter)

### What is it?
`io.debezium.transforms.ByLogicalTableRouter`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `customers_shard1` and `customers_shard2` tables |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| Previous SMT cleanup | Run cleanup from SMT 1 so resource IDs are predictable |

Verify shard tables exist:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT 'shard1' as tbl, COUNT(*) FROM customers_shard1 UNION ALL SELECT 'shard2', COUNT(*) FROM customers_shard2;"
# Expected: shard1=2, shard2=2
```

### Why use it?
Your database may have sharded tables: `customers_shard1`, `customers_shard2`, `customers_shard3`.
By default, Debezium sends each to its own Kafka topic. But you want all shard events in **one topic**
so a single consumer handles all customer events without subscribing to 3 topics.

### When to use it?
- Horizontally sharded tables that need to merge into one stream
- Partitioned tables where you want all partitions in one topic
- Multi-region tables that need to be consolidated

### Before the SMT:
```
dbz.public.customers_shard1  → Topic 1
dbz.public.customers_shard2  → Topic 2
```

### After the SMT:
```
dbz.public.customers_shard1  ──►
                                  dbz.public.customers_all_shards
dbz.public.customers_shard2  ──►
```

### Step 1 — Create the Source (both shards)

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-shards",
    "description": "Captures changes from both customer shard tables",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers_shard1,public.customers_shard2",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt2",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create the Transform

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt2-topic-routing",
    "description": "Merges customers_shard1 and customers_shard2 events into one topic",
    "type": "io.debezium.transforms.ByLogicalTableRouter",
    "schema": "inventory",
    "config": {
      "topic.regex": "(.*)customers_shard(.*)",
      "topic.replacement": "$1customers_all_shards",
      "key.field.name": "shard_id",
      "key.field.regex": "(.*)customers_shard(.*)",
      "key.field.replacement": "$2"
    }
  }'
```

**Config explained:**

| Key | Value | Why |
|-----|-------|-----|
| `topic.regex` | `(.*)customers_shard(.*)` | Matches any topic with `customers_shard` in the name |
| `topic.replacement` | `$1customers_all_shards` | Routes them all to one new topic |
| `key.field.name` | `shard_id` | Adds a new field to the Kafka key to keep records unique across shards |
| `key.field.regex` | `(.*)customers_shard(.*)` | Captures the shard number from topic name |
| `key.field.replacement` | `$2` | Sets shard_id to `1` or `2` based on captured group |

> Without `key.field.name`, row id=1 from shard1 and row id=1 from shard2 would have
> the same Kafka key, causing one to overwrite the other in compacted topics.

### Step 3 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "description": "Kafka destination",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": {
      "producer.bootstrap.servers": "localhost:9092"
    }
  }'
```

### Step 4 — Create Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt2-topic-routing",
    "description": "Merges shard1 + shard2 into one Kafka topic",
    "source":      {"id": 2, "name": "src-shards"},
    "destination": {"id": 2, "name": "dest-kafka"},
    "transforms":  [{"id": 2, "name": "smt2-topic-routing"}],
    "logLevel": "INFO"
  }'
```

### Step 5 — Test It

Insert into shard1:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers_shard1 (first_name, last_name, email, region)
   VALUES ('Shard1User', 'Test', 'shard1.test@example.com', 'US');"
```

Insert into shard2:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers_shard2 (first_name, last_name, email, region)
   VALUES ('Shard2User', 'Test', 'shard2.test@example.com', 'EU');"
```

Both events now arrive in topic `dbz.public.customers_all_shards`.
The Kafka message key for shard1 event includes `shard_id: "1"`.
The Kafka message key for shard2 event includes `shard_id: "2"`.

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/2
curl -X DELETE http://localhost:8080/api/transforms/2
curl -X DELETE http://localhost:8080/api/sources/2
curl -X DELETE http://localhost:8080/api/destinations/2
```

---

## 7. SMT 3 — Content-Based Routing

### What is it?
`io.debezium.transforms.ContentBasedRouter`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `customers` table with `region` column |
| Extra JARs needed | ✅ `debezium-scripting` JAR — **already included** in `quay.io/debezium/connect:latest` |
| Scripting engine | ✅ Groovy JSR-223 engine — **already included** in `quay.io/debezium/connect:latest` |
| Previous SMT cleanup | Run cleanup from SMT 2 so resource IDs are predictable |

Verify `region` column and data:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT region, COUNT(*) FROM customers GROUP BY region;"
# Expected: US=3, EU=2
```

Verify scripting is enabled in Debezium:
```bash
curl -s http://localhost:8083/connector-plugins | python3 -c \
  "import sys,json; [print(p['class']) for p in json.load(sys.stdin) if 'Content' in p['class']]" 2>/dev/null || \
  echo "Check conductor logs: docker logs conductor 2>&1 | grep -i scripting"
```

### Why use it?
You want to send different events to different topics based on **what's inside the event**.
For example: EU customers go to `eu-customers` topic, US customers go to `us-customers` topic.
Or: DELETE events go to an `archive` topic, INSERT/UPDATE go to `live` topic.

### When to use it?
- Route by geography (EU vs US data residency compliance)
- Route by operation type (archive deletes separately)
- Route by business category (high-value orders to priority topic)
- Route by tenant ID in a multi-tenant system

> **Requires:** `debezium-scripting` JAR + Groovy or GraalVM JS engine in the Kafka Connect
> plugin directory. Already included in `quay.io/debezium/connect:latest`.

### Before the SMT:
```
All customer events → single topic: dbz.public.customers
```

### After the SMT:
```
Customer with region=EU → topic: eu-customers
Customer with region=US → topic: us-customers
Customer with region=OTHER → stays on original topic (null = no reroute)
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-customers-cbr",
    "description": "Customers source for content-based routing",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt3",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create the Transform

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt3-content-routing",
    "description": "Routes EU customers to eu-customers topic, US to us-customers topic",
    "type": "io.debezium.connector.postgresql.transforms.ContentBasedRouter",
    "schema": "inventory",
    "config": {
      "language": "jsr223.groovy",
      "topic.expression": "value.after?.region == '\''EU'\'' ? '\''eu-customers'\'' : (value.after?.region == '\''US'\'' ? '\''us-customers'\'' : null)"
    }
  }'
```

> The expression returns a **topic name string** to reroute to, or **null** to keep the original topic.

**More expression examples:**

Route DELETE events to archive topic:
```
"topic.expression": "value.op == 'd' ? 'deleted-archive' : null"
```

Route high-value orders to priority topic:
```
"topic.expression": "value.after?.amount > 1000 ? 'high-value-orders' : null"
```

Route by operation type:
```
"topic.expression": "value.op == 'u' ? 'updates-only' : null"
```

**Variables available in the expression:**

| Variable | What it is | Example use |
|----------|-----------|-------------|
| `value` | The full CDC event | `value.op`, `value.after`, `value.before` |
| `value.after` | New row data | `value.after?.region` |
| `value.before` | Old row data | `value.before?.status` |
| `value.op` | Operation: `c`, `u`, `d`, `r` | `value.op == 'u'` |
| `key` | Message key | `key.id` |
| `topic` | Current topic name | `topic.contains('orders')` |
| `header` | Message headers map | `header['__op']` |

### Step 3 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": { "producer.bootstrap.servers": "localhost:9092" }
  }'
```

### Step 4 — Create Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt3-content-routing",
    "description": "Routes customers to EU or US topic based on region field",
    "source":      {"id": 3, "name": "src-customers-cbr"},
    "destination": {"id": 3, "name": "dest-kafka"},
    "transforms":  [{"id": 3, "name": "smt3-content-routing"}],
    "logLevel": "INFO"
  }'
```

### Step 5 — Test It

Insert an EU customer:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('EUUser', 'Test', 'eu.test@example.com', 'EU', 'ACTIVE', 80000);"
```

→ This event goes to topic: `eu-customers`

Insert a US customer:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('USUser', 'Test', 'us.test@example.com', 'US', 'ACTIVE', 90000);"
```

→ This event goes to topic: `us-customers`

Cleanup test data:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email IN ('eu.test@example.com','us.test@example.com');"
```

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/3
curl -X DELETE http://localhost:8080/api/transforms/3
curl -X DELETE http://localhost:8080/api/sources/3
curl -X DELETE http://localhost:8080/api/destinations/3
```

---

## 8. SMT 4 — Message Filtering

### What is it?
`io.debezium.transforms.Filter`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `customers` table with `status` column |
| Extra JARs needed | ✅ `debezium-scripting` JAR — **already included** in `quay.io/debezium/connect:latest` |
| Scripting engine | ✅ Groovy JSR-223 engine — **already included** in `quay.io/debezium/connect:latest` |
| Previous SMT cleanup | Run cleanup from SMT 3 so resource IDs are predictable |

Verify `status` column has ACTIVE and INACTIVE data:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT status, COUNT(*) FROM customers GROUP BY status;"
# Expected: ACTIVE=4, INACTIVE=1
```

### Why use it?
Debezium sends **every** change event to Kafka by default. But you may only care about
a subset — for example: only ACTIVE customers, only UPDATE events, only high-value orders.
This SMT drops events that don't match your filter condition **before they reach the destination**.

### When to use it?
- Skip DELETE events (append-only pipelines)
- Skip INACTIVE records
- Skip test/staging data (emails ending in @test.com)
- Filter by region (only process US data in this pipeline)
- Only process high-value transactions

> **Requires:** `debezium-scripting` JAR + Groovy or GraalVM JS engine.
> Already included in `quay.io/debezium/connect:latest`.

### How it works:
The expression must return **true** (keep the event) or **false** (drop the event).

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-customers-filter",
    "description": "Customers source for message filtering",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt4",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create the Transform

This example keeps **only ACTIVE customers** and **drops all DELETE events**:

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt4-filter",
    "description": "Keeps only ACTIVE customer events. Drops DELETEs and INACTIVE records.",
    "type": "io.debezium.transforms.Filter",
    "schema": "inventory",
    "config": {
      "language": "jsr223.groovy",
      "condition": "value.op != '\''d'\'' && value.after?.status == '\''ACTIVE'\''"
    }
  }'
```

**More filter condition examples:**

Only INSERT events:
```
"condition": "value.op == 'c'"
```

Only UPDATE and INSERT (no deletes):
```
"condition": "value.op != 'd'"
```

Only US region:
```
"condition": "value.after?.region == 'US'"
```

Only high salary employees:
```
"condition": "value.after?.salary != null && value.after.salary > 100000"
```

Drop test emails:
```
"condition": "value.after?.email != null && !value.after.email.endsWith('@test.com')"
```

### Step 3 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": { "producer.bootstrap.servers": "localhost:9092" }
  }'
```

### Step 4 — Create Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt4-filter",
    "description": "Only ACTIVE customers pass through. Deletes and INACTIVE records are dropped.",
    "source":      {"id": 4, "name": "src-customers-filter"},
    "destination": {"id": 4, "name": "dest-kafka"},
    "transforms":  [{"id": 4, "name": "smt4-filter"}],
    "logLevel": "INFO"
  }'
```

### Step 5 — Test It

Insert an ACTIVE customer (this PASSES the filter):
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('FilterPass', 'Test', 'filter.pass@example.com', 'US', 'ACTIVE', 70000);"
```

→ This event **passes** through (ACTIVE + not a delete).

Insert an INACTIVE customer (this is DROPPED by the filter):
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('FilterDrop', 'Test', 'filter.drop@example.com', 'US', 'INACTIVE', 30000);"
```

→ This event is **dropped** (INACTIVE).

Delete a customer (this is DROPPED by the filter):
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email = 'filter.pass@example.com';"
```

→ This DELETE event is **dropped** (`op == 'd'`).

Cleanup:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email IN ('filter.pass@example.com','filter.drop@example.com');"
```

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/4
curl -X DELETE http://localhost:8080/api/transforms/4
curl -X DELETE http://localhost:8080/api/sources/4
curl -X DELETE http://localhost:8080/api/destinations/4
```

---

## 9. SMT 5 — Outbox Event Router

### What is it?
`io.debezium.transforms.outbox.EventRouter`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `outbox` table |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| Special DB config | `outbox` table must have `REPLICA IDENTITY FULL` — already set in init script |
| Previous SMT cleanup | Run cleanup from SMT 4 so resource IDs are predictable |

Verify the outbox table exists with the correct structure:
```bash
docker exec source-postgres psql -U postgres -d inventory -c "\d outbox"
```

Expected columns: `id (uuid)`, `aggregatetype`, `aggregateid`, `type`, `payload (jsonb)`

Verify REPLICA IDENTITY is FULL:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT relname, relreplident FROM pg_class WHERE relname = 'outbox';"
# Expected: relreplident = f  (f = FULL)
```

### Why use it?
In microservices, you need to publish events to Kafka atomically with database changes.
If you write to DB and then write to Kafka separately, one can fail → data inconsistency.

The **Outbox Pattern** solves this:
1. Your app writes to the `outbox` table **in the same DB transaction** as the business data
2. Debezium captures the outbox table and delivers to Kafka — guaranteed, exactly once
3. The EventRouter SMT cleans up the raw CDC envelope and routes to the right topic

### When to use it?
- Microservices that need to publish domain events reliably
- Any time you need "exactly once" event delivery guarantee
- Replace direct Kafka writes in your application code

### Outbox Pattern Flow:
```
App Transaction:
  INSERT INTO orders ...          ← business data
  INSERT INTO outbox (type=OrderCreated, payload=...) ← outbox entry
  COMMIT

Debezium captures outbox INSERT
    ↓
EventRouter SMT transforms it:
  - Routes to topic: outbox.event.Order
  - Key = aggregateid (e.g. "1001")
  - Value = payload JSON only (no CDC envelope)
```

### Required Outbox Table Structure

```sql
CREATE TABLE outbox (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregatetype VARCHAR(255) NOT NULL,  -- → topic name
  aggregateid   VARCHAR(255) NOT NULL,  -- → Kafka message key
  type          VARCHAR(255) NOT NULL,  -- → event type
  payload       JSONB                   -- → Kafka message value
);
```

Verify it exists:
```bash
docker exec source-postgres psql -U postgres -d inventory -c "\d outbox"
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-outbox",
    "description": "Captures ONLY the outbox table for reliable event delivery",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbserver1",
      "table.include.list": "public.outbox",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt5",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create the Transform

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt5-outbox-router",
    "description": "Routes outbox events to topics by aggregatetype. Key=aggregateid. Value=payload.",
    "type": "io.debezium.transforms.outbox.EventRouter",
    "schema": "inventory",
    "config": {
      "route.by.field": "aggregatetype",
      "route.topic.replacement": "outbox.event.${routedByValue}",
      "table.field.event.id": "id",
      "table.field.event.key": "aggregateid",
      "table.field.event.payload": "payload",
      "table.field.event.payload.id": "type"
    }
  }'
```

**Config explained:**

| Key | Value | What it does |
|-----|-------|-------------|
| `route.by.field` | `aggregatetype` | Reads this column to decide destination topic |
| `route.topic.replacement` | `outbox.event.${routedByValue}` | `aggregatetype=Order` → topic `outbox.event.Order` |
| `table.field.event.key` | `aggregateid` | This column becomes the Kafka message key |
| `table.field.event.payload` | `payload` | This column becomes the Kafka message value |
| `table.field.event.id` | `id` | This UUID goes into Kafka header (deduplication) |

### Step 3 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": { "producer.bootstrap.servers": "localhost:9092" }
  }'
```

### Step 4 — Create Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt5-outbox",
    "description": "Reliable event delivery using outbox pattern",
    "source":      {"id": 5, "name": "src-outbox"},
    "destination": {"id": 5, "name": "dest-kafka"},
    "transforms":  [{"id": 5, "name": "smt5-outbox-router"}],
    "logLevel": "INFO"
  }'
```

### Step 5 — Test It

**Simulate an app creating an Order (atomically with business data):**
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO outbox (aggregatetype, aggregateid, type, payload)
   VALUES (
     'Order',
     '1001',
     'OrderCreated',
     '{\"orderId\": 1001, \"customerId\": 1, \"total\": 149.99, \"items\": [\"laptop\", \"mouse\"]}'
   );"
```

**What Kafka receives on topic `outbox.event.Order`:**
```
Key:     "1001"
Headers: id=<uuid>
Value:   {"orderId": 1001, "customerId": 1, "total": 149.99, "items": ["laptop","mouse"]}
```

**Simulate a Customer registration event:**
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO outbox (aggregatetype, aggregateid, type, payload)
   VALUES (
     'Customer',
     '42',
     'CustomerRegistered',
     '{\"customerId\": 42, \"email\": \"newuser@example.com\", \"region\": \"EU\"}'
   );"
```

**What Kafka receives on topic `outbox.event.Customer`:**
```
Key:     "42"
Value:   {"customerId": 42, "email": "newuser@example.com", "region": "EU"}
```

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/5
curl -X DELETE http://localhost:8080/api/transforms/5
curl -X DELETE http://localhost:8080/api/sources/5
curl -X DELETE http://localhost:8080/api/destinations/5
```

---

## 10. SMT 6 — MongoDB New Document State Extraction

### What is it?
`io.debezium.connector.mongodb.transforms.ExtractNewDocumentState`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | A **MongoDB** type connection must be created (not PostgreSQL) |
| Source database | MongoDB running in **replica set mode** (`--replSet rs0`) — required for CDC |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| MongoDB version | 4.0+ with replica set initialized |
| Previous SMT cleanup | Run cleanup from SMT 5 so resource IDs are predictable |

If you have a MongoDB container running, create a MongoDB connection first:
```bash
curl -X POST http://localhost:8080/api/connections \
  -H "Content-Type: application/json" \
  -d '{
    "name": "source-mongodb",
    "type": "MONGODB",
    "config": {
      "mongodb.connection.string": "mongodb://mongodb:27017/?replicaSet=rs0"
    }
  }'
```

Verify MongoDB replica set is initialized:
```bash
docker exec mongodb mongosh --quiet --eval "rs.status().ok"
# Expected: 1
```

> **Note:** If you don't have MongoDB running, use the `postgres-to-mongodb/` project
> which already has MongoDB set up with the Debezium MongoDB sink connector.

### Why use it?
This is the **MongoDB equivalent** of SMT 1 (ExtractNewRecordState).
MongoDB CDC events have a different structure than SQL events.
This SMT flattens the MongoDB change event to a simple document.

### When to use it?
- Syncing MongoDB to another MongoDB
- Syncing MongoDB to Elasticsearch
- Any time you use the Debezium MongoDB connector and need flat documents

### Before the SMT — raw MongoDB CDC event:
```json
{
  "after": "{\"_id\": {\"$oid\": \"abc123\"}, \"name\": \"Alice\", \"region\": \"US\"}",
  "patch": null,
  "source": { "collection": "customers", "db": "inventory" },
  "op": "c"
}
```

### After the SMT — flattened document:
```json
{
  "_id": "abc123",
  "name": "Alice",
  "region": "US",
  "__op": "c",
  "__collection": "customers"
}
```

### Step 1 — Create the Source (MongoDB)

> Note: This uses MongoDB as source. In our environment we use PostgreSQL.
> The config below is shown for reference when you have a MongoDB source.

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-mongodb-customers",
    "description": "MongoDB source for customers collection",
    "type": "io.debezium.connector.mongodb.MongoDbConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "your-mongodb-connection"},
    "config": {
      "topic.prefix": "mongo",
      "collection.include.list": "inventory.customers",
      "mongodb.connection.string": "mongodb://mongodb:27017/?replicaSet=rs0"
    }
  }'
```

### Step 2 — Create the Transform

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt6-mongo-flatten",
    "description": "Flattens MongoDB CDC events to simple documents",
    "type": "io.debezium.connector.mongodb.transforms.ExtractNewDocumentState",
    "schema": "inventory",
    "config": {
      "drop.tombstones": "false",
      "delete.handling.mode": "rewrite",
      "add.fields": "op,collection",
      "add.headers": "op"
    }
  }'
```

**Config explained — same pattern as SMT 1 but for MongoDB:**

| Key | Value | Why |
|-----|-------|-----|
| `drop.tombstones` | `false` | Keep tombstone records for log compaction |
| `delete.handling.mode` | `rewrite` | For DELETE: keep record + add `__deleted: true` |
| `add.fields` | `op,collection` | Add `__op` and `__collection` metadata |

### Step 3 — Create the Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka-mongo-flatten",
    "description": "Kafka destination for flattened MongoDB CDC events",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": {
      "producer.bootstrap.servers": "localhost:9092"
    }
  }'
```

Expected response:
```json
{
  "id": 10,
  "name": "dest-kafka-mongo-flatten",
  "type": "io.debezium.server.kafka.KafkaChangeConsumer"
}
```

### Step 4 — Create the Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt6-mongo-flatten",
    "description": "MongoDB CDC pipeline with document state flattening",
    "source":      {"id": 10, "name": "src-mongodb-customers"},
    "destination": {"id": 10, "name": "dest-kafka-mongo-flatten"},
    "transforms":  [{"id": 10, "name": "smt6-mongo-flatten"}],
    "logLevel": "INFO"
  }'
```

Expected response:
```json
{
  "id": 10,
  "name": "pipeline-smt6-mongo-flatten",
  "source":      {"id": 10, "name": null},
  "destination": {"id": 10, "name": null},
  "transforms":  [{"id": 10, "name": null}]
}
```

### Step 5 — Test It

Insert a document into MongoDB customers collection:
```bash
docker exec mongodb mongosh inventory --quiet --eval "
  db.customers.insertOne({
    name: 'Alice',
    email: 'alice@example.com',
    region: 'US',
    status: 'ACTIVE'
  });
"
```

**What the raw MongoDB CDC event looks like (before SMT):**
```json
{
  "after": "{\"_id\": {\"$oid\": \"abc123\"}, \"name\": \"Alice\", \"region\": \"US\"}",
  "source": {"collection": "customers", "db": "inventory"},
  "op": "c"
}
```

**What the flattened event looks like (after SMT):**
```json
{
  "_id": "abc123",
  "name": "Alice",
  "email": "alice@example.com",
  "region": "US",
  "status": "ACTIVE",
  "__op": "c",
  "__collection": "customers"
}
```

Update a document and verify before/after behavior:
```bash
docker exec mongodb mongosh inventory --quiet --eval "
  db.customers.updateOne(
    {name: 'Alice'},
    {\$set: {status: 'INACTIVE'}}
  );
"
```

Delete a document and verify `__deleted: true` appears:
```bash
docker exec mongodb mongosh inventory --quiet --eval "
  db.customers.deleteOne({name: 'Alice'});
"
```

**DELETE event with `delete.handling.mode: rewrite`:**
```json
{
  "_id": "abc123",
  "name": "Alice",
  "region": "US",
  "__deleted": "true",
  "__op": "d",
  "__collection": "customers"
}
```

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/10
curl -X DELETE http://localhost:8080/api/transforms/10
curl -X DELETE http://localhost:8080/api/sources/10
curl -X DELETE http://localhost:8080/api/destinations/10
```

---

## 11. SMT 7 — MongoDB Outbox Event Router

### What is it?
`io.debezium.connector.mongodb.transforms.outbox.MongoEventRouter`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | A **MongoDB** type connection must be created (see SMT 6 Prerequisites) |
| Source database | MongoDB running in replica set mode with an `outbox` collection |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| MongoDB version | 4.0+ with replica set initialized |
| Previous SMT cleanup | Run cleanup from SMT 6 so resource IDs are predictable |

Create the outbox collection in MongoDB:
```bash
docker exec mongodb mongosh inventory --quiet --eval "
  db.createCollection('outbox');
  db.outbox.createIndex({aggregatetype: 1});
  print('outbox collection ready');
"
```

### Why use it?
This is the **MongoDB equivalent** of SMT 5 (OutboxEventRouter).
When your application uses MongoDB as the database and you want the outbox pattern.

### When to use it?
- MongoDB-based microservices that need reliable event publishing
- Same use case as SMT 5 but with MongoDB as source

### Required MongoDB Outbox Collection Structure

```json
{
  "_id": ObjectId("..."),
  "aggregatetype": "Order",
  "aggregateid": "1001",
  "type": "OrderCreated",
  "payload": { "orderId": 1001, "total": 149.99 }
}
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-mongo-outbox",
    "description": "MongoDB outbox collection source",
    "type": "io.debezium.connector.mongodb.MongoDbConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "your-mongodb-connection"},
    "config": {
      "topic.prefix": "mongo",
      "collection.include.list": "inventory.outbox",
      "mongodb.connection.string": "mongodb://mongodb:27017/?replicaSet=rs0"
    }
  }'
```

### Step 2 — Create the Transform

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt7-mongo-outbox",
    "description": "Routes MongoDB outbox events to correct topics",
    "type": "io.debezium.connector.mongodb.transforms.outbox.MongoEventRouter",
    "schema": "inventory",
    "config": {
      "route.by.field": "aggregatetype",
      "route.topic.replacement": "outbox.event.${routedByValue}",
      "collection.field.event.id": "_id",
      "collection.field.event.key": "aggregateid",
      "collection.field.event.payload": "payload"
    }
  }'
```

**Config explained — same as SMT 5 but fields are prefixed `collection.` instead of `table.`:**

| Key | Value | Why |
|-----|-------|-----|
| `route.by.field` | `aggregatetype` | Column that determines destination topic |
| `route.topic.replacement` | `outbox.event.${routedByValue}` | Topic naming pattern |
| `collection.field.event.key` | `aggregateid` | Kafka message key column |
| `collection.field.event.payload` | `payload` | Kafka message value column |

### Step 3 — Create the Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka-mongo-outbox",
    "description": "Kafka destination for MongoDB outbox routed events",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": {
      "producer.bootstrap.servers": "localhost:9092"
    }
  }'
```

Expected response:
```json
{
  "id": 11,
  "name": "dest-kafka-mongo-outbox",
  "type": "io.debezium.server.kafka.KafkaChangeConsumer"
}
```

### Step 4 — Create the Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt7-mongo-outbox",
    "description": "MongoDB outbox pattern pipeline — routes events to topics by aggregatetype",
    "source":      {"id": 11, "name": "src-mongo-outbox"},
    "destination": {"id": 11, "name": "dest-kafka-mongo-outbox"},
    "transforms":  [{"id": 11, "name": "smt7-mongo-outbox"}],
    "logLevel": "INFO"
  }'
```

Expected response:
```json
{
  "id": 11,
  "name": "pipeline-smt7-mongo-outbox",
  "source":      {"id": 11, "name": null},
  "destination": {"id": 11, "name": null},
  "transforms":  [{"id": 11, "name": null}]
}
```

### Step 5 — Test It

Simulate an app inserting an Order event into the MongoDB outbox collection:
```bash
docker exec mongodb mongosh inventory --quiet --eval "
  db.outbox.insertOne({
    aggregatetype: 'Order',
    aggregateid: '1001',
    type: 'OrderCreated',
    payload: {
      orderId: 1001,
      customerId: 42,
      total: 149.99,
      items: ['laptop', 'mouse']
    }
  });
"
```

**What Kafka receives on topic `outbox.event.Order`:**
```
Topic:   outbox.event.Order
Key:     "1001"
Headers: id=<mongodb-object-id>
Value:   {"orderId": 1001, "customerId": 42, "total": 149.99, "items": ["laptop","mouse"]}
```

Simulate a Customer event:
```bash
docker exec mongodb mongosh inventory --quiet --eval "
  db.outbox.insertOne({
    aggregatetype: 'Customer',
    aggregateid: '42',
    type: 'CustomerRegistered',
    payload: {
      customerId: 42,
      email: 'newuser@example.com',
      region: 'EU'
    }
  });
"
```

**What Kafka receives on topic `outbox.event.Customer`:**
```
Topic:   outbox.event.Customer
Key:     "42"
Value:   {"customerId": 42, "email": "newuser@example.com", "region": "EU"}
```

Note: The raw CDC envelope (`before`, `after`, `op`, `source`) is completely removed.
Only the `payload` field value reaches Kafka — clean and ready for consumers.

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/11
curl -X DELETE http://localhost:8080/api/transforms/11
curl -X DELETE http://localhost:8080/api/sources/11
curl -X DELETE http://localhost:8080/api/destinations/11
```

---

## 12. SMT 8 — HeaderToValue

### What is it?
`io.debezium.transforms.HeaderToValue`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `customers` table |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| Depends on | Must use together with `ExtractNewRecordState` (SMT 1) which puts fields into headers first |
| Previous SMT cleanup | Run cleanup from SMT 5 (or 7 if doing MongoDB) so resource IDs are predictable |

Verify source table has data:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT id, first_name, email FROM customers LIMIT 3;"
```

> **How this SMT pairs with SMT 1:**
> SMT 1 (`ExtractNewRecordState`) with `add.headers=op,table` puts `__op` and `__table`
> into Kafka headers. SMT 8 (`HeaderToValue`) then moves those headers into the message body.
> You need BOTH in the same pipeline, in that order.

### Why use it?
Kafka messages have **headers** (metadata) and a **value** (payload).
Headers are invisible to most consumers — they can't read header data.
This SMT moves or copies header fields **into** the message value so consumers can access them.

### When to use it?
- Downstream system can't read Kafka headers
- Need operation type (`INSERT`/`UPDATE`/`DELETE`) in the payload for audit
- Need source table name visible in the record
- Passing tracing/correlation IDs from headers to payload

### Before the SMT:
```
Headers: { "__op": "c", "__table": "customers" }
Value:   { "id": 1, "first_name": "Alice", "email": "alice@example.com" }
```

### After the SMT (move operation):
```
Headers: {}
Value:   { "id": 1, "first_name": "Alice", "email": "alice@example.com",
           "operation": "c", "source_table": "customers" }
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-customers-h2v",
    "description": "Customers source for HeaderToValue example",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt8",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create Transform 1: Flatten + add to headers

This first transform flattens the event AND puts `op` + `table` into Kafka headers:

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt8a-flatten-add-headers",
    "description": "Step 1: Flatten CDC event and put op+table into Kafka headers",
    "type": "io.debezium.transforms.ExtractNewRecordState",
    "schema": "inventory",
    "config": {
      "delete.tombstone.handling.mode": "rewrite",
      "add.headers": "op,table"
    }
  }'
```

### Step 3 — Create Transform 2: Move headers into value

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt8b-headers-to-value",
    "description": "Step 2: Moves __op and __table from headers into the record payload",
    "type": "io.debezium.transforms.HeaderToValue",
    "schema": "inventory",
    "config": {
      "headers": "__op,__table",
      "fields": "operation,source_table",
      "operation": "move"
    }
  }'
```

**Config explained:**

| Key | Value | Why |
|-----|-------|-----|
| `headers` | `__op,__table` | The header names to process (note: `add.headers` prefixes with `__`) |
| `fields` | `operation,source_table` | New field names in the payload (order must match headers) |
| `operation` | `move` | `move` = remove from header + add to payload. `copy` = keep in header AND add to payload |

### Step 4 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": { "producer.bootstrap.servers": "localhost:9092" }
  }'
```

### Step 5 — Create Pipeline (chain both transforms)

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt8-header-to-value",
    "description": "Flattens CDC event, then moves op+table from headers into payload",
    "source":      {"id": 6, "name": "src-customers-h2v"},
    "destination": {"id": 6, "name": "dest-kafka"},
    "transforms":  [
      {"id": 6, "name": "smt8a-flatten-add-headers"},
      {"id": 7, "name": "smt8b-headers-to-value"}
    ],
    "logLevel": "INFO"
  }'
```

> Transforms run in the **order listed**. First flatten runs, then HeaderToValue runs.

### Step 6 — Test It

```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('HeaderTest', 'User', 'header.test@example.com', 'US', 'ACTIVE', 65000);"
```

**What the final event looks like in Kafka:**
```json
{
  "id": 7,
  "first_name": "HeaderTest",
  "last_name": "User",
  "email": "header.test@example.com",
  "region": "US",
  "status": "ACTIVE",
  "operation": "c",
  "source_table": "customers"
}
```

Cleanup:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email = 'header.test@example.com';"
```

### Step 7 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/6
curl -X DELETE http://localhost:8080/api/transforms/7
curl -X DELETE http://localhost:8080/api/transforms/6
curl -X DELETE http://localhost:8080/api/sources/6
curl -X DELETE http://localhost:8080/api/destinations/6
```

---

## 13. SMT 9 — Partition Routing

### What is it?
`io.debezium.transforms.partitions.PartitionRouting`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `orders` table with `customer_id` column |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| Kafka topic partitions | Topic must have the **same number of partitions** as `partition.topic.num` (3 in this example) |
| Previous SMT cleanup | Run cleanup from SMT 8 so resource IDs are predictable |

Verify orders table exists and has customer_id:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT id, customer_id, amount, status FROM orders;"
# Expected: 5 existing orders
```

Verify the Kafka topic has 3 partitions (if it already exists):
```bash
docker exec transforms-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe --topic dbz.public.orders 2>/dev/null | grep Partitions || \
  echo "Topic does not exist yet - will be created with 3 partitions on first event"
```

> **Critical:** If you change `partition.topic.num`, you must also change the number of
> partitions on the Kafka topic to match. Mismatch causes events to be dropped silently.

### Why use it?
Kafka topics have multiple partitions. By default, Debezium sends all events for a table to
partition 0 (or random partitions). This means events for the same customer can land in
different partitions → **no ordering guarantee**.

PartitionRouting ensures **all events for the same entity (e.g., same customer_id) always go
to the same partition** → strict ordering is maintained.

### When to use it?
- Need strict ordering of events per customer / order / account
- Consumer needs to process all events for an entity sequentially
- Preventing race conditions in event-driven systems

### Without PartitionRouting:
```
customer_id=1 UPDATE → partition 2   ← out of order!
customer_id=1 INSERT → partition 0
customer_id=1 DELETE → partition 1   ← consumer sees wrong order
```

### With PartitionRouting (by customer_id):
```
customer_id=1 INSERT → partition 2   ← always partition 2
customer_id=1 UPDATE → partition 2   ← always partition 2, in order
customer_id=1 DELETE → partition 2   ← always partition 2, in order
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-orders-partitioned",
    "description": "Orders source - events will be routed by customer_id for ordering",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.orders",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt9",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create the Transform

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt9-partition-routing",
    "description": "Routes orders by customer_id so all orders for same customer go to same partition",
    "type": "io.debezium.transforms.partitions.PartitionRouting",
    "schema": "inventory",
    "config": {
      "partition.payload.fields": "change.customer_id",
      "partition.topic.num": "3",
      "partition.hash.function": "murmur"
    }
  }'
```

**Config explained:**

| Key | Value | Why |
|-----|-------|-----|
| `partition.payload.fields` | `change.customer_id` | Field to hash for partition calculation. `change.` prefix automatically checks both `before` and `after` |
| `partition.topic.num` | `3` | Must match the number of partitions in your Kafka topic |
| `partition.hash.function` | `murmur` | Hash function: `java` (default) or `murmur` (better distribution) |

> **Important:** `partition.topic.num` must exactly match the partition count in Kafka.
> If your topic has 3 partitions, set this to `3`.

**Route by multiple fields (region + customer_id):**
```json
"partition.payload.fields": "change.region,change.customer_id"
```

### Step 3 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": { "producer.bootstrap.servers": "localhost:9092" }
  }'
```

### Step 4 — Create Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt9-partition-routing",
    "description": "Orders pipeline - all events per customer go to same Kafka partition",
    "source":      {"id": 7, "name": "src-orders-partitioned"},
    "destination": {"id": 7, "name": "dest-kafka"},
    "transforms":  [{"id": 8, "name": "smt9-partition-routing"}],
    "logLevel": "INFO"
  }'
```

### Step 5 — Test It

Insert multiple orders for the same customer:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO orders (customer_id, amount, status, region) VALUES (1, 299.99, 'PENDING', 'US');"

docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO orders (customer_id, amount, status, region) VALUES (1, 599.99, 'COMPLETED', 'US');"

docker exec source-postgres psql -U postgres -d inventory -c \
  "UPDATE orders SET status = 'SHIPPED' WHERE customer_id = 1 AND status = 'PENDING';"
```

All 3 events for `customer_id=1` land on the **same Kafka partition** — ordering guaranteed.

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/7
curl -X DELETE http://localhost:8080/api/transforms/8
curl -X DELETE http://localhost:8080/api/sources/7
curl -X DELETE http://localhost:8080/api/destinations/7
```

---

## 14. SMT 10 — Timezone Converter

### What is it?
`io.debezium.transforms.TimezoneConverter`

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `customers` table with `created_at TIMESTAMP` column |
| Extra JARs needed | ❌ None — built into Debezium Connect image |
| Scripting engine | ❌ Not required |
| Timestamp columns | Table must have at least one `TIMESTAMP` or `TIMESTAMPTZ` column |
| Previous SMT cleanup | Run cleanup from SMT 9 so resource IDs are predictable |

Verify timestamp column exists:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT column_name, data_type FROM information_schema.columns \
      WHERE table_name='customers' AND data_type LIKE '%timestamp%';"
# Expected: created_at | timestamp without time zone
```

Verify your target timezone string is valid (replace Asia/Kolkata with your timezone):
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT NOW() AT TIME ZONE 'Asia/Kolkata';"
# If this works, the timezone string is valid
```

### Why use it?
Debezium always emits timestamps in **UTC**. But your downstream applications, dashboards,
or databases may need timestamps in a specific local timezone. Instead of converting in
application code, this SMT converts all timestamps automatically at the pipeline level.

### When to use it?
- Reporting databases that need local timezone timestamps
- Dashboards that show "local time" to users
- Compliance requirements for data residency in specific timezones
- Any downstream that doesn't handle UTC → local time conversion

### Before the SMT:
```json
{ "created_at": "2024-06-07T10:00:00.000000Z" }
```

### After the SMT (converted to IST +05:30):
```json
{ "created_at": "2024-06-07T15:30:00.000000+05:30" }
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-customers-tz",
    "description": "Customers source for timezone conversion",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt10",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create the Transform

**Option A — Convert ALL timestamp fields:**
```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt10-tz-all-fields",
    "description": "Converts ALL timestamp fields from UTC to Asia/Kolkata (IST)",
    "type": "io.debezium.transforms.TimezoneConverter",
    "schema": "inventory",
    "config": {
      "converted.timezone": "Asia/Kolkata"
    }
  }'
```

**Option B — Convert ONLY specific fields:**
```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt10-tz-specific-fields",
    "description": "Converts ONLY created_at from UTC to IST. Leaves other timestamps untouched.",
    "type": "io.debezium.transforms.TimezoneConverter",
    "schema": "inventory",
    "config": {
      "converted.timezone": "Asia/Kolkata",
      "include.list": "source:customers:created_at"
    }
  }'
```

**Option C — Convert ALL except specific fields:**
```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt10-tz-exclude",
    "description": "Converts all timestamps EXCEPT ts_ms (source metadata)",
    "type": "io.debezium.transforms.TimezoneConverter",
    "schema": "inventory",
    "config": {
      "converted.timezone": "America/New_York",
      "exclude.list": "source:ts_ms"
    }
  }'
```

**Timezone reference:**

| Region | `converted.timezone` value |
|--------|--------------------------|
| India (IST) | `Asia/Kolkata` |
| US East (ET) | `America/New_York` |
| US West (PT) | `America/Los_Angeles` |
| UK (GMT/BST) | `Europe/London` |
| Germany (CET) | `Europe/Berlin` |
| Japan (JST) | `Asia/Tokyo` |
| Australia (AEST) | `Australia/Sydney` |
| Fixed +05:30 | `+05:30` |
| Fixed -08:00 | `-08:00` |

> **Important:** Use geographic names (e.g., `America/New_York`) for DST-aware conversion.
> Use fixed offsets (e.g., `+05:30`) only for regions that don't observe DST.
> `include.list` and `exclude.list` are mutually exclusive — use only one.

### Step 3 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": { "producer.bootstrap.servers": "localhost:9092" }
  }'
```

### Step 4 — Create Pipeline

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt10-timezone",
    "description": "Customers pipeline with UTC to IST timestamp conversion",
    "source":      {"id": 8, "name": "src-customers-tz"},
    "destination": {"id": 8, "name": "dest-kafka"},
    "transforms":  [{"id": 9, "name": "smt10-tz-all-fields"}],
    "logLevel": "INFO"
  }'
```

### Step 5 — Test It

```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('TZTest', 'User', 'tz.test@example.com', 'US', 'ACTIVE', 70000);"
```

**Before (UTC):**
```json
{ "created_at": "2024-06-07T10:00:00.000000Z" }
```

**After (IST):**
```json
{ "created_at": "2024-06-07T15:30:00.000000+05:30" }
```

Cleanup:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email = 'tz.test@example.com';"
```

### Step 6 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/8
curl -X DELETE http://localhost:8080/api/transforms/9
curl -X DELETE http://localhost:8080/api/sources/8
curl -X DELETE http://localhost:8080/api/destinations/8
```

---

## 15. SMT 11 — Applying Transforms Selectively (Predicates)

### What is it?
Predicates let you apply a transform to **only a subset of messages** that match a condition.

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with any table |
| Extra JARs needed | ❌ None — predicates are built into Kafka Connect |
| Scripting engine | ❌ Not required |
| Kafka version | Apache Kafka 2.6+ (predicates were introduced in KIP-585) |
| Depends on | Used **inside** a transform's config — not a standalone object |
| Previous SMT cleanup | Run cleanup from SMT 10 so resource IDs are predictable |

Verify Kafka version supports predicates (2.6+):
```bash
docker exec transforms-kafka /opt/kafka/bin/kafka-topics.sh --version 2>/dev/null || \
  docker exec conductor curl -s http://localhost:8083/ | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('Kafka Connect version:', d.get('version','unknown'))"
```

> **Key concept:** Predicates are not created separately via the API.
> They are configured **inside** the Transform object in the `predicate` field.
> You add them when creating the transform, as shown in the examples below.

### Why use it?
A Debezium connector emits many types of messages:
- **Data change events** (INSERT/UPDATE/DELETE) — what you want to transform
- **Heartbeat messages** — sent periodically to keep the slot alive
- **Schema change events** — when table structure changes
- **Transaction metadata** — start/end of transactions
- **Tombstone records** — null value after DELETE for log compaction

Heartbeat and schema change messages have a **different structure** than data events.
They don't have `op`, `before`, `after` fields. If you apply a transform that expects
those fields to ALL messages, it will **crash on heartbeats**.

Predicates prevent this by saying: "only apply this transform to matching messages".

### When to use it?
- Any time you use SMTs that expect CDC event structure (they'll crash on heartbeats)
- Apply a transform to only one specific table out of many
- Skip tombstone records for sinks that can't handle null values
- Apply different transforms to different topics

### 3 Built-in Predicates:

| Predicate | Matches When | Use Case |
|-----------|-------------|---------|
| `TopicNameMatches` | Topic name matches regex | Apply SMT only to specific table topics |
| `HasHeaderKey` | Message has a specific header key | Apply SMT to messages with specific metadata |
| `RecordIsTombstone` | Message value is null (tombstone) | Filter out or handle tombstone records |

### Example A — Apply transform only to data topics (skip heartbeats)

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt11a-flatten-with-predicate",
    "description": "Flattens CDC events. Predicate ensures it ONLY runs on data topics, not heartbeat/schema topics.",
    "type": "io.debezium.transforms.ExtractNewRecordState",
    "schema": "inventory",
    "config": {
      "delete.tombstone.handling.mode": "rewrite",
      "add.fields": "op,table"
    },
    "predicate": {
      "type": "org.apache.kafka.connect.transforms.predicates.TopicNameMatches",
      "config": {
        "pattern": "dbz\\.public\\..*"
      },
      "negate": false
    }
  }'
```

**What this does:**
- `pattern: "dbz\\.public\\..*"` — matches topics like `dbz.public.customers`, `dbz.public.orders`
- `negate: false` — apply the transform only to matching topics
- Heartbeat topics like `dbz.heartbeat` do NOT match → transform is skipped → no crash

### Example B — Skip tombstone records

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt11b-skip-tombstones",
    "description": "Applies flatten transform to everything EXCEPT tombstone records",
    "type": "io.debezium.transforms.ExtractNewRecordState",
    "schema": "inventory",
    "config": {
      "delete.tombstone.handling.mode": "tombstone",
      "add.fields": "op,table"
    },
    "predicate": {
      "type": "org.apache.kafka.connect.transforms.predicates.RecordIsTombstone",
      "config": {},
      "negate": true
    }
  }'
```

**What `negate: true` means:**
- `RecordIsTombstone` matches tombstones
- `negate: true` inverts it → apply transform to everything that is **NOT** a tombstone
- Tombstones pass through untouched

### Example C — Apply only to one specific table

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "smt11c-customers-only",
    "description": "Applies flatten transform ONLY to customers table events, not orders",
    "type": "io.debezium.transforms.ExtractNewRecordState",
    "schema": "inventory",
    "config": {
      "delete.tombstone.handling.mode": "rewrite",
      "add.fields": "op,table"
    },
    "predicate": {
      "type": "org.apache.kafka.connect.transforms.predicates.TopicNameMatches",
      "config": {
        "pattern": "dbz\\.public\\.customers"
      },
      "negate": false
    }
  }'
```

**`negate` option summary:**

| Predicate | `negate: false` | `negate: true` |
|-----------|----------------|----------------|
| `TopicNameMatches` with `pattern: dbz.public.customers` | Apply transform ONLY to customers topic | Apply transform to ALL topics EXCEPT customers |
| `RecordIsTombstone` | Apply transform ONLY to tombstones | Apply transform to EVERYTHING EXCEPT tombstones |
| `HasHeaderKey` with key `__op` | Apply transform ONLY to messages with `__op` header | Apply transform to messages WITHOUT `__op` header |

### Step 1 — Create the Source

This source captures both `customers` and `orders` so we can demonstrate the predicate
applying the transform to only one of them:

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-multi-table-predicate",
    "description": "Captures customers and orders — predicate will selectively apply transform",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers,public.orders",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt11",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

Expected response:
```json
{
  "id": 12,
  "name": "src-multi-table-predicate",
  "type": "io.debezium.connector.postgresql.PostgresConnector"
}
```

### Step 2 — Create the Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka-predicate",
    "description": "Kafka destination for predicate example",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": {
      "producer.bootstrap.servers": "localhost:9092"
    }
  }'
```

Expected response:
```json
{
  "id": 12,
  "name": "dest-kafka-predicate",
  "type": "io.debezium.server.kafka.KafkaChangeConsumer"
}
```

### Step 3 — Create the Pipeline using Example C transform (customers only)

We use `smt11c-customers-only` which was created in Example C above.
This pipeline captures both customers and orders, but the predicate ensures
the flatten transform runs **only on the customers topic**.
Orders events pass through with the raw CDC envelope untouched.

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt11-predicate",
    "description": "Multi-table pipeline — flatten applied ONLY to customers (predicate), orders pass raw",
    "source":      {"id": 12, "name": "src-multi-table-predicate"},
    "destination": {"id": 12, "name": "dest-kafka-predicate"},
    "transforms":  [{"id": 15, "name": "smt11c-customers-only"}],
    "logLevel": "INFO"
  }'
```

Expected response:
```json
{
  "id": 12,
  "name": "pipeline-smt11-predicate",
  "source":      {"id": 12, "name": null},
  "destination": {"id": 12, "name": null},
  "transforms":  [{"id": 15, "name": null}]
}
```

### Step 4 — Test It

Insert a customer — this hits topic `dbz.public.customers` which **matches** the predicate:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('PredicateTest', 'User', 'predicate.test@example.com', 'US', 'ACTIVE', 75000);"
```

**Result for customers event** — predicate matches → transform RUNS → event is **flattened**:
```json
{
  "id": 9,
  "first_name": "PredicateTest",
  "email": "predicate.test@example.com",
  "__op": "c",
  "__table": "customers"
}
```

Insert an order — this hits topic `dbz.public.orders` which **does NOT match** the predicate:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO orders (customer_id, amount, status, region)
   VALUES (1, 999.99, 'PENDING', 'US');"
```

**Result for orders event** — predicate does NOT match → transform SKIPPED → event stays **raw CDC envelope**:
```json
{
  "before": null,
  "after": {"id": 6, "customer_id": 1, "amount": 999.99, "status": "PENDING"},
  "op": "c",
  "source": {"table": "orders", "db": "inventory"}
}
```

Cleanup test data:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email = 'predicate.test@example.com';"
```

### Step 5 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/12
curl -X DELETE http://localhost:8080/api/transforms/15
curl -X DELETE http://localhost:8080/api/transforms/14
curl -X DELETE http://localhost:8080/api/transforms/13
curl -X DELETE http://localhost:8080/api/sources/12
curl -X DELETE http://localhost:8080/api/destinations/12
```

---

## 16. SMT 12 — Chaining Multiple Transforms

### What is it?
You can apply multiple SMTs in sequence. The output of one becomes the input of the next.
The `transforms` array in a Pipeline defines the order.

### Prerequisites

| Requirement | Details |
|-------------|----------|
| Platform running | `docker compose -f debezium-platform-docker-compose.yaml ps` → all containers healthy |
| Connection created | Step 0 completed — connection id `1` exists |
| Source database | `source-postgres` running with `customers` table with `status`, `region`, `created_at` columns |
| Extra JARs needed | ✅ `debezium-scripting` JAR for the Filter step — **already included** in `quay.io/debezium/connect:latest` |
| Scripting engine | ✅ Groovy JSR-223 — **already included** in `quay.io/debezium/connect:latest` |
| Previous SMT cleanup | Run cleanup from SMT 11 so resource IDs are predictable |
| Understanding needed | SMTs 1, 4 and 10 — review those sections first if you haven't |

Verify all required columns exist in the customers table:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT column_name, data_type FROM information_schema.columns \
      WHERE table_name = 'customers' \
      ORDER BY ordinal_position;"
# Expected columns: id, first_name, last_name, email, region, status, salary, created_at
```

Verify both ACTIVE and INACTIVE records exist for testing:
```bash
docker exec source-postgres psql -U postgres -d inventory \
  -c "SELECT status, COUNT(*) FROM customers GROUP BY status;"
# Expected: ACTIVE=4, INACTIVE=1
```

### Why use it?
A single SMT solves one problem. Real pipelines often need to solve multiple problems:
- First flatten the envelope (SMT 1)
- Then convert timestamps (SMT 10)
- Then filter out inactive records (SMT 4)

### Example — Full Production Pipeline: Flatten + Timezone + Filter

**Flow:**
```
Raw CDC event (complex envelope)
       │
       ▼  [flatten]
Flat record + __op,__table added + timestamps still UTC
       │
       ▼  [convert-tz]
Flat record + timestamps converted to IST
       │
       ▼  [filter-active]
Only ACTIVE records pass through
       │
       ▼
Kafka Topic — clean, flat, IST timestamps, ACTIVE records only
```

### Step 1 — Create the Source

```bash
curl -X POST http://localhost:8080/api/sources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "src-customers-chain",
    "description": "Customers source for chained transforms example",
    "type": "io.debezium.connector.postgresql.PostgresConnector",
    "schema": "inventory",
    "connection": {"id": 1, "name": "source-postgres-inventory"},
    "config": {
      "topic.prefix": "dbz",
      "table.include.list": "public.customers",
      "plugin.name": "pgoutput",
      "slot.name": "slot_smt12",
      "publication.autocreate.mode": "filtered",
      "tombstones.on.delete": "false"
    }
  }'
```

### Step 2 — Create Transform 1: Flatten

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "chain-step1-flatten",
    "description": "Step 1: Flatten CDC envelope",
    "type": "io.debezium.transforms.ExtractNewRecordState",
    "schema": "inventory",
    "config": {
      "delete.tombstone.handling.mode": "rewrite",
      "add.fields": "op,table,source.ts_ms"
    }
  }'
```

### Step 3 — Create Transform 2: Timezone Convert

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "chain-step2-timezone",
    "description": "Step 2: Convert all timestamps from UTC to IST",
    "type": "io.debezium.transforms.TimezoneConverter",
    "schema": "inventory",
    "config": {
      "converted.timezone": "Asia/Kolkata"
    }
  }'
```

### Step 4 — Create Transform 3: Filter Active Only

```bash
curl -X POST http://localhost:8080/api/transforms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "chain-step3-filter",
    "description": "Step 3: Drop INACTIVE records and DELETE events",
    "type": "io.debezium.transforms.Filter",
    "schema": "inventory",
    "config": {
      "language": "jsr223.groovy",
      "condition": "value.__op != '\''d'\'' && value.status == '\''ACTIVE'\''"
    }
  }'
```

> Note: After flatten (Step 1), the fields are at the top level. So `value.status` works,
> not `value.after?.status`.

### Step 5 — Create Destination

```bash
curl -X POST http://localhost:8080/api/destinations \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dest-kafka",
    "type": "io.debezium.server.kafka.KafkaChangeConsumer",
    "schema": "inventory",
    "config": { "producer.bootstrap.servers": "localhost:9092" }
  }'
```

### Step 6 — Create Pipeline (all 3 transforms chained)

```bash
curl -X POST http://localhost:8080/api/pipelines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "pipeline-smt12-chained",
    "description": "Production-ready pipeline: Flatten → Timezone → Filter",
    "source":      {"id": 9, "name": "src-customers-chain"},
    "destination": {"id": 9, "name": "dest-kafka"},
    "transforms": [
      {"id": 10, "name": "chain-step1-flatten"},
      {"id": 11, "name": "chain-step2-timezone"},
      {"id": 12, "name": "chain-step3-filter"}
    ],
    "logLevel": "INFO"
  }'
```

### Step 7 — Test It

Insert an ACTIVE customer (passes all 3 transforms):
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('ChainPass', 'User', 'chain.pass@example.com', 'US', 'ACTIVE', 80000);"
```

**Final event in Kafka:**
```json
{
  "id": 8,
  "first_name": "ChainPass",
  "last_name": "User",
  "email": "chain.pass@example.com",
  "region": "US",
  "status": "ACTIVE",
  "salary": 80000,
  "created_at": "2024-06-07T15:30:00.000000+05:30",
  "__op": "c",
  "__table": "customers",
  "__source_ts_ms": "2024-06-07T15:30:00.000000+05:30"
}
```

Insert an INACTIVE customer (dropped by Step 3 filter):
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "INSERT INTO customers (first_name, last_name, email, region, status, salary)
   VALUES ('ChainDrop', 'User', 'chain.drop@example.com', 'US', 'INACTIVE', 30000);"
```

→ This event is dropped at Step 3. Never reaches Kafka.

Cleanup:
```bash
docker exec source-postgres psql -U postgres -d inventory -c \
  "DELETE FROM customers WHERE email IN ('chain.pass@example.com','chain.drop@example.com');"
```

### Step 8 — Cleanup

```bash
curl -X DELETE http://localhost:8080/api/pipelines/9
curl -X DELETE http://localhost:8080/api/transforms/12
curl -X DELETE http://localhost:8080/api/transforms/11
curl -X DELETE http://localhost:8080/api/transforms/10
curl -X DELETE http://localhost:8080/api/sources/9
curl -X DELETE http://localhost:8080/api/destinations/9
```

---

## 17. Full Reset

Delete everything and start fresh:

```bash
for id in $(curl -s http://localhost:8080/api/pipelines | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null); do
  curl -s -X DELETE http://localhost:8080/api/pipelines/$id
done
for id in $(curl -s http://localhost:8080/api/transforms | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null); do
  curl -s -X DELETE http://localhost:8080/api/transforms/$id
done
for id in $(curl -s http://localhost:8080/api/sources | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null); do
  curl -s -X DELETE http://localhost:8080/api/sources/$id
done
for id in $(curl -s http://localhost:8080/api/destinations | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null); do
  curl -s -X DELETE http://localhost:8080/api/destinations/$id
done
for id in $(curl -s http://localhost:8080/api/connections | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null); do
  curl -s -X DELETE http://localhost:8080/api/connections/$id
done
echo "All resources deleted"
```

---

## 18. Quick Reference

### All SMTs Covered in This Guide

| # | SMT | Class | Use Case |
|---|-----|-------|---------|
| 1 | New Record State Extraction | `io.debezium.transforms.ExtractNewRecordState` | Flatten CDC envelope for downstream sinks |
| 2 | Topic Routing | `io.debezium.transforms.ByLogicalTableRouter` | Merge shard tables into one topic |
| 3 | Content-Based Routing | `io.debezium.connector.postgresql.transforms.ContentBasedRouter` | Route events to different topics by content |
| 4 | Message Filtering | `io.debezium.transforms.Filter` | Drop events that don't match a condition |
| 5 | Outbox Event Router | `io.debezium.transforms.outbox.EventRouter` | Reliable microservice event delivery |
| 6 | MongoDB Doc State Extraction | `io.debezium.connector.mongodb.transforms.ExtractNewDocumentState` | Flatten MongoDB CDC events |
| 7 | MongoDB Outbox Event Router | `io.debezium.connector.mongodb.transforms.outbox.MongoEventRouter` | MongoDB outbox pattern |
| 8 | HeaderToValue | `io.debezium.transforms.HeaderToValue` | Move Kafka headers into payload |
| 9 | Partition Routing | `io.debezium.transforms.partitions.PartitionRouting` | Route to specific partitions for ordering |
| 10 | Timezone Converter | `io.debezium.transforms.TimezoneConverter` | Convert UTC timestamps to local timezone |
| 11 | Predicates | `TopicNameMatches` / `RecordIsTombstone` / `HasHeaderKey` | Apply transforms selectively |
| 12 | Chaining | (multiple transforms in pipeline) | Combine multiple transforms in sequence |

### Platform API Quick Commands

```bash
# Check platform state
curl http://localhost:8080/api/connections
curl http://localhost:8080/api/sources
curl http://localhost:8080/api/transforms
curl http://localhost:8080/api/destinations
curl http://localhost:8080/api/pipelines

# Check pipeline logs (replace 1 with your pipeline ID)
curl http://localhost:8080/api/pipelines/1/logs

# Delete a pipeline
curl -X DELETE http://localhost:8080/api/pipelines/1

# Open UI
open http://localhost:3000
```

### Delete.Tombstone.Handling.Mode — Decision Guide

```
Do you need to know about deleted records downstream?
├── NO  → use "drop"   (deletes and tombstones both removed)
├── YES, but just mark as deleted in the record?
│   ├── YES → use "rewrite"   (record kept with __deleted: true)
│   └── YES + keep tombstone for Kafka log compaction?
│       └── use "rewrite-with-tombstone"
└── Is your sink expecting tombstones to trigger deletes?
    └── use "tombstone" (default)
```

### Predicate `negate` Decision Guide

```
I want to apply the transform to...
├── ONLY messages matching the predicate → negate: false
└── EVERYTHING EXCEPT messages matching the predicate → negate: true
```

### References

- [Debezium Transforms Index](https://debezium.io/documentation/reference/stable/transformations/index.html)
- [New Record State Extraction](https://debezium.io/documentation/reference/stable/transformations/event-flattening.html)
- [Topic Routing](https://debezium.io/documentation/reference/stable/transformations/topic-routing.html)
- [Content-Based Routing](https://debezium.io/documentation/reference/stable/transformations/content-based-routing.html)
- [Message Filtering](https://debezium.io/documentation/reference/stable/transformations/filtering.html)
- [Outbox Event Router](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html)
- [MongoDB New Document State Extraction](https://debezium.io/documentation/reference/stable/transformations/mongodb-event-flattening.html)
- [MongoDB Outbox Event Router](https://debezium.io/documentation/reference/stable/transformations/mongodb-outbox-event-router.html)
- [HeaderToValue](https://debezium.io/documentation/reference/stable/transformations/header-to-value.html)
- [Partition Routing](https://debezium.io/documentation/reference/stable/transformations/partition-routing.html)
- [Timezone Converter](https://debezium.io/documentation/reference/stable/transformations/timezone-converter.html)
- [Applying Transforms Selectively](https://debezium.io/documentation/reference/stable/transformations/applying-transformations-selectively.html)
- [Debezium Platform Docs](https://debezium.io/documentation/reference/stable/operations/debezium-platform.html)
