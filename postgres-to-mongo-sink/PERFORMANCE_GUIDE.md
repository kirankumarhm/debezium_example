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
