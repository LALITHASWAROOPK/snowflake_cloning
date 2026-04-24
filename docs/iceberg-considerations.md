# Iceberg Tables: Cloning Considerations

## Overview

Snowflake Iceberg tables introduce additional complexity when cloning databases. This guide covers the limitations and workarounds you need to know.

## What Are Iceberg Tables?

Apache Iceberg is an open table format designed for huge analytic datasets. Snowflake supports Iceberg tables with data stored in external volumes (object storage like S3, Azure Blob, or GCS).

```sql
-- Example: Iceberg table managed by Snowflake
CREATE ICEBERG TABLE events_iceberg (
    event_id NUMBER,
    event_time TIMESTAMP,
    user_id NUMBER,
    event_type VARCHAR
)
EXTERNAL_VOLUME = 'prod_iceberg_volume'
CATALOG = 'snowflake'
BASE_LOCATION = 's3://my-bucket/events/';
```

## Cloning Behavior

When you clone a database containing Iceberg tables:

```sql
CREATE DATABASE dev_db CLONE production_db;
```

The Iceberg table **metadata** is cloned, but:

1. **The table still references the production external volume**
2. **The underlying Iceberg data is NOT copied** (same as regular tables)
3. **Dynamic Iceberg tables lose their "dynamic" status**

## Limitation 1: External Volume Access

### The Problem

After cloning:

```sql
SELECT * FROM dev_db.data.events_iceberg;
-- ❌ Error: Database DEV_DB does not have READ access to 
--           EXTERNAL VOLUME 'prod_iceberg_volume'
```

The clone references the production external volume but doesn't have permission to access it.

### Solution: Grant Volume Access

```sql
-- Grant read access to production external volume
GRANT READ ON EXTERNAL VOLUME prod_iceberg_volume 
  TO DATABASE dev_db;

-- Now queries work
SELECT * FROM dev_db.data.events_iceberg;
-- ✅ Success
```

### Security Consideration

**Implication:** Your dev environment now has read access to production Iceberg storage.

**Alternative approaches:**

#### Option 1: Separate External Volumes Per Environment

```sql
-- Production
CREATE ICEBERG TABLE prod_db.data.events
  EXTERNAL_VOLUME = 'prod_iceberg_volume'
  ...

-- After cloning, repoint to dev external volume
ALTER ICEBERG TABLE dev_db.data.events
  SET EXTERNAL_VOLUME = 'dev_iceberg_volume';

-- Copy data if needed
INSERT INTO dev_db.data.events
SELECT * FROM prod_db.data.events
WHERE event_time >= DATEADD('day', -30, CURRENT_TIMESTAMP());
```

**Pros:** Complete environment isolation  
**Cons:** Data copy required (time + storage cost)

#### Option 2: Convert to Regular Tables in Clones

```sql
-- In clone creation procedure
if (object_type == 'ICEBERG_TABLE' and environment != 'PROD'):
    -- Get Iceberg table structure
    CREATE TABLE dev_db.data.events AS
    SELECT * FROM prod_db.data.events
    LIMIT 0;  -- Structure only, no data
    
    -- Optionally load recent data
    INSERT INTO dev_db.data.events
    SELECT * FROM prod_db.data.events
    WHERE event_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());
```

**Pros:** No external volume dependencies  
**Cons:** Loses Iceberg metadata benefits

#### Option 3: Read-Only Dev With Volume Access (Our Approach)

```sql
-- Grant read-only access, accept the security trade-off
GRANT READ ON EXTERNAL VOLUME prod_iceberg_volume 
  TO DATABASE dev_db;

-- Document in security audit
-- Monitor access via query history
```

**Pros:** Simple, fast, zero data copy  
**Cons:** Dev can read prod Iceberg data  

**Mitigation:** 
- Use separate warehouses for dev (cost tracking)
- Monitor via `QUERY_HISTORY` for unauthorized access patterns
- Apply data masking policies if needed

---

## Limitation 2: Dynamic Iceberg Tables

### The Problem

Dynamic Iceberg tables don't clone properly:

```sql
-- Production has dynamic Iceberg table
CREATE DYNAMIC ICEBERG TABLE prod_db.data.streaming_events
  TARGET_LAG = '1 minute'
  WAREHOUSE = prod_wh
  EXTERNAL_VOLUME = 'prod_iceberg_volume'
AS
  SELECT * FROM event_stream;

-- After cloning
SHOW DYNAMIC TABLES IN dev_db.data;
-- Result: Table listed, BUT...

DESCRIBE DYNAMIC TABLE dev_db.data.streaming_events;
-- Result: Table exists but is NOT refreshing
--         Target lag is lost
--         Warehouse assignment is broken
```

The metadata is cloned, but the **dynamic refresh mechanism is not maintained**.

### Solution: Recreate or Convert

#### Option 1: Recreate as Dynamic (If Needed in Dev)

```sql
-- Drop cloned version
DROP TABLE dev_db.data.streaming_events;

-- Recreate as dynamic
CREATE DYNAMIC ICEBERG TABLE dev_db.data.streaming_events
  TARGET_LAG = '5 minutes'  -- Can be different than prod
  WAREHOUSE = dev_wh        -- Use dev warehouse
  EXTERNAL_VOLUME = 'dev_iceberg_volume'
AS
  SELECT * FROM dev_event_stream;  -- Dev source
```

#### Option 2: Convert to Static Table (Common for Dev)

```sql
-- Drop dynamic metadata, keep as static Iceberg table
ALTER DYNAMIC TABLE dev_db.data.streaming_events
  SUSPEND;  -- Stop refresh

-- Or recreate as static
DROP TABLE dev_db.data.streaming_events;

CREATE ICEBERG TABLE dev_db.data.streaming_events
  EXTERNAL_VOLUME = 'dev_iceberg_volume'
AS
  SELECT * FROM prod_db.data.streaming_events
  WHERE event_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());
```

#### Option 3: Skip Dynamic Tables in Clones

```sql
-- In clone validation, flag dynamic Iceberg tables
SELECT 
    table_schema,
    table_name,
    'DYNAMIC_ICEBERG_TABLE' as issue_type,
    'Requires manual recreation or conversion' as resolution
FROM information_schema.tables
WHERE table_type = 'DYNAMIC ICEBERG TABLE';
```

---

## Automation Strategy

### During Clone Creation

Add Iceberg handling to your clone procedure:

```javascript
// Step 7: Handle Iceberg Tables
function handleIcebergTables() {
    var results = {
        iceberg_tables_found: 0,
        volume_grants_applied: 0,
        dynamic_tables_flagged: 0
    };
    
    // Find all Iceberg tables
    var icebergRS = execSQL(
        "SELECT table_schema, table_name, " +
        "       table_type, external_volume " +
        "FROM information_schema.tables " +
        "WHERE table_type IN ('ICEBERG TABLE', 'DYNAMIC ICEBERG TABLE') " +
        "AND table_schema != 'INFORMATION_SCHEMA'"
    );
    
    var uniqueVolumes = new Set();
    
    while (icebergRS.next()) {
        results.iceberg_tables_found++;
        
        var tableType = icebergRS.getColumnValue(3);
        var extVolume = icebergRS.getColumnValue(4);
        
        // Grant volume access
        if (extVolume && !uniqueVolumes.has(extVolume)) {
            try {
                execSQL(
                    "GRANT READ ON EXTERNAL VOLUME " + extVolume + 
                    " TO DATABASE " + cloneDb
                );
                uniqueVolumes.add(extVolume);
                results.volume_grants_applied++;
            } catch (e) {
                // May already be granted
            }
        }
        
        // Flag dynamic Iceberg tables
        if (tableType === 'DYNAMIC ICEBERG TABLE') {
            results.dynamic_tables_flagged++;
            // Log for manual review
        }
    }
    
    return results;
}
```

**Full implementation:** [`sql/05_clone_master.sql`](../../sql/05_clone_master.sql) (Step 7)

### Validation

Add Iceberg checks to clone validation:

```sql
-- Check for Iceberg tables without volume access
SELECT 
    t.table_schema,
    t.table_name,
    t.external_volume,
    CASE 
        WHEN v.external_volume_name IS NULL 
        THEN 'MISSING_VOLUME_ACCESS'
        ELSE 'OK'
    END as status
FROM information_schema.tables t
LEFT JOIN information_schema.external_volume_privileges v
    ON t.external_volume = v.external_volume_name
    AND v.grantee_name = '<CLONE_DB>'
WHERE t.table_type IN ('ICEBERG TABLE', 'DYNAMIC ICEBERG TABLE')
AND t.table_schema != 'INFORMATION_SCHEMA';
```

---

## Best Practices

### 1. Document External Volume Dependencies

```sql
-- Create metadata table
CREATE TABLE iceberg_table_metadata (
    table_name VARCHAR,
    external_volume VARCHAR,
    environment VARCHAR,
    access_granted_at TIMESTAMP,
    notes VARCHAR
);

-- Track volume grants
INSERT INTO iceberg_table_metadata
VALUES (
    'events_iceberg',
    'prod_iceberg_volume',
    'DEV',
    CURRENT_TIMESTAMP(),
    'Dev has READ access to prod volume for testing'
);
```

### 2. Monitor Volume Access

```sql
-- Query history monitoring
SELECT 
    query_text,
    user_name,
    warehouse_name,
    database_name,
    execution_time
FROM snowflake.account_usage.query_history
WHERE query_text ILIKE '%prod_iceberg_volume%'
AND database_name = 'DEV_DB'
AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

### 3. Apply Data Masking (If Needed)

If dev can read prod Iceberg data:

```sql
-- Create masking policy
CREATE MASKING POLICY pii_mask AS (val STRING) RETURNS STRING ->
  CASE 
    WHEN CURRENT_ROLE() IN ('PROD_ADMIN', 'SECURITY_ADMIN') 
      THEN val
    ELSE '***MASKED***'
  END;

-- Apply to sensitive columns
ALTER TABLE prod_db.data.events_iceberg
  MODIFY COLUMN user_email 
  SET MASKING POLICY pii_mask;
```

### 4. Use Tagging for Auditability

```sql
-- Tag Iceberg tables
CREATE TAG iceberg_source = 'Source external volume for Iceberg table';

ALTER TABLE dev_db.data.events
  SET TAG iceberg_source = 'prod_iceberg_volume (READ-ONLY)';

-- Query tagged objects
SELECT 
    tag_value,
    object_database,
    object_name
FROM snowflake.account_usage.tag_references
WHERE tag_name = 'ICEBERG_SOURCE'
AND object_database = 'DEV_DB';
```

---

## Troubleshooting

### Error: Cannot access external volume

```sql
-- Problem
SELECT * FROM dev_db.data.events_iceberg;
-- Error: Database DEV_DB does not have READ access to EXTERNAL VOLUME 'prod_iceberg_volume'

-- Solution
GRANT READ ON EXTERNAL VOLUME prod_iceberg_volume TO DATABASE dev_db;
```

### Error: Dynamic table not refreshing

```sql
-- Problem
SHOW DYNAMIC TABLES IN dev_db;
-- State: SUSPENDED or ERROR

-- Solution: Recreate or convert to static
DROP DYNAMIC TABLE dev_db.data.streaming_events;
CREATE ICEBERG TABLE dev_db.data.streaming_events ...
```

### Error: Metadata file not found

```sql
-- Problem
SELECT * FROM dev_db.data.events_iceberg;
-- Error: Metadata file not found in external volume

-- Possible causes:
-- 1. External volume path changed
-- 2. S3/Azure credentials expired
-- 3. Bucket deleted or moved

-- Solution: Validate external volume
DESCRIBE EXTERNAL VOLUME prod_iceberg_volume;
```

---

## Summary

| Aspect | Behavior | Workaround |
|--------|----------|------------|
| **Static Iceberg Tables** | Clone successfully but need volume access | `GRANT READ ON EXTERNAL VOLUME` |
| **Dynamic Iceberg Tables** | Metadata clones but dynamic behavior lost | Recreate or convert to static |
| **External Volume Access** | Not inherited by clone | Must grant explicitly |
| **Data Location** | Still points to prod storage | Accept trade-off or copy data |
| **Security** | Dev can read prod Iceberg data | Monitor + mask + tag |

---

## Related Documentation

- [Snowflake Iceberg Tables](https://docs.snowflake.com/en/user-guide/tables-iceberg)
- [External Volumes](https://docs.snowflake.com/en/sql-reference/sql/create-external-volume)
- [Dynamic Tables](https://docs.snowflake.com/en/user-guide/dynamic-tables)

---

**Back to:** [Blog Series Overview](../blog/00-overview.md)
