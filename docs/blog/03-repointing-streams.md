# Part 3: Repointing Database References and Recreating Streams

**Previously:** In [Part 2](02-permissions-rbac.md), we solved permission problems with dynamic role creation and RBAC mapping.

**In this post:** Learn how to find and fix hardcoded database references in views, stored procedures, functions, and tasks — plus how to recreate streams that broke during cloning.

---

## The Reference Problem

Your cloned database has perfect permissions, but nothing works:

```sql
-- Try to query a view in the clone
SELECT * FROM dev_project_db.analytics.customer_metrics;

-- Error: Object 'PRODUCTION_DB.SILVER.CUSTOMERS' does not exist
```

The view definition is still pointing to production:

```sql
SELECT GET_DDL('VIEW', 'dev_project_db.analytics.customer_metrics');

-- Result:
CREATE OR REPLACE VIEW dev_project_db.analytics.customer_metrics AS
SELECT 
    customer_id,
    COUNT(*) as order_count
FROM production_db.silver.customers  -- ⚠️ Wrong database!
GROUP BY customer_id;
```

**The code was copied exactly as-is.** Every database reference needs updating.

---

## The Challenge: Finding All References

Database references hide everywhere:

### 1. Views (The Easy Ones)
```sql
SELECT table_name, view_definition
FROM dev_project_db.information_schema.views
WHERE view_definition ILIKE '%production_db%';
-- Result: 186 views need fixing
```

### 2. Stored Procedures (The Tricky Ones)
```sql
SELECT procedure_name, procedure_definition
FROM dev_project_db.information_schema.procedures
WHERE procedure_definition ILIKE '%production_db%';
-- Problem: JavaScript, SQL, Python, Scala, Java...
```

### 3. Functions
```sql
SELECT function_name, function_definition
FROM dev_project_db.information_schema.functions
WHERE function_definition ILIKE '%production_db%';
```

### 4. Tasks (The Sneaky Ones)
```sql
SELECT name, definition
FROM dev_project_db.information_schema.tasks
WHERE definition ILIKE '%production_db%';
-- Tasks can call procedures that call views...
```

### 5. Streams (The Broken Ones)
```sql
SHOW STREAMS IN DATABASE dev_project_db;
-- Result: Every stream shows STALE = TRUE
```

---

## Strategy: GET_DDL + String Replacement

Our battle plan:

1. **Identify** objects with stale references (INFORMATION_SCHEMA)
2. **Extract** full DDL using `GET_DDL()` function
3. **Replace** all occurrences of source database with clone database
4. **Execute** updated DDL to recreate the object

Simple concept, but devils in the details.

---

## Repointing Views

Views are straightforward because their definitions are directly accessible:

```javascript
// Conceptual flow
var viewRS = execSQL(
    "SELECT TABLE_NAME, VIEW_DEFINITION " +
    "FROM clone_db.INFORMATION_SCHEMA.VIEWS " +
    "WHERE TABLE_SCHEMA = '" + schema + "' " +
    "AND VIEW_DEFINITION ILIKE '%source_db%'"
);

while (viewRS.next()) {
    var viewDef = viewRS.getColumnValue(2);
    
    // Replace database references (case-insensitive)
    var newDef = viewDef
        .split(sourceDb).join(cloneDb)
        .split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());
    
    // Execute updated DDL
    execSQL(newDef);
    views_fixed++;
}
```

**Why this works:**
- `VIEW_DEFINITION` contains full CREATE statement
- Simple string replacement updates all references
- Re-executing DDL replaces the view atomically

**Full implementation:** [`sql/02_clone_repoint.sql#L75-L130`](../../sql/02_clone_repoint.sql)

---

## Repointing Procedures (The Hard Part)

Procedures are tricky because:

1. **INFORMATION_SCHEMA truncates long definitions**
2. Must use **GET_DDL()** for full text
3. Must handle **parameter signatures** correctly

### The Parameter Signature Problem

```sql
-- INFORMATION_SCHEMA shows:
PROCEDURE_NAME: calculate_metrics
ARGUMENT_SIGNATURE: (start_date DATE, end_date DATE, customer_id NUMBER)

-- But GET_DDL requires type-only signature:
SELECT GET_DDL('PROCEDURE', 'schema.calculate_metrics(DATE, DATE, NUMBER)');
--                                                      ^^^^ Types only!
```

We must parse signatures to extract just the types.

### Parsing Logic

```javascript
// Convert "(start_date DATE, end_date DATE)" 
// To: "(DATE, DATE)"
function stripParamNames(sig) {
    if (!sig || sig.trim() === "()") return "()";
    
    var params = sig.replace(/[()]/g, "").split(",");
    var types = [];
    
    for (var i = 0; i < params.length; i++) {
        var parts = params[i].trim().split(/\s+/);
        // "start_date DATE" → ["start_date", "DATE"]
        types.push(parts.slice(1).join(" ")); // Take type part
    }
    
    return "(" + types.join(", ") + ")";
}
```

### The Repointing Flow

```javascript
// Get procedures that reference source database
var procRS = execSQL(
    "SELECT PROCEDURE_NAME, ARGUMENT_SIGNATURE " +
    "FROM clone_db.INFORMATION_SCHEMA.PROCEDURES " +
    "WHERE PROCEDURE_DEFINITION ILIKE '%source_db%'"
);

while (procRS.next()) {
    var procName = procRS.getColumnValue(1);
    var procSig = procRS.getColumnValue(2);
    var typeSig = stripParamNames(procSig);  // Key step!
    
    // Get full DDL with correct signature
    var ddl = execSQL(
        "SELECT GET_DDL('PROCEDURE', '" + 
        cloneDb + "." + schema + "." + procName + typeSig + "')"
    );
    
    // Replace database references
    var newDDL = ddl
        .split(sourceDb).join(cloneDb)
        .split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());
    
    // Recreate procedure
    execSQL(newDDL);
    procedures_fixed++;
}
```

**Full implementation:** [`sql/02_clone_repoint.sql#L132-L195`](../../sql/02_clone_repoint.sql)

---

## Repointing Functions

Functions work exactly like procedures (same signature challenge):

```javascript
// Same pattern as procedures
// 1. Find functions with stale references
// 2. Strip parameter names from signatures
// 3. Get full DDL using GET_DDL('FUNCTION', ...)
// 4. Replace database references
// 5. Execute updated DDL
```

**Full implementation:** [`sql/02_clone_repoint.sql#L197-L250`](../../sql/02_clone_repoint.sql)

---

## Repointing Tasks

Tasks have an additional requirement: **SUSPEND first**.

```javascript
// Get tasks that reference source database
var taskRS = execSQL(
    "SELECT NAME FROM clone_db.INFORMATION_SCHEMA.TASKS " +
    "WHERE DEFINITION ILIKE '%source_db%'"
);

while (taskRS.next()) {
    var taskName = taskRS.getColumnValue(1);
    
    // IMPORTANT: Suspend before modifying
    execSQL("ALTER TASK " + taskName + " SUSPEND");
    
    // Get DDL, replace references, recreate
    var taskDDL = execSQL("SELECT GET_DDL('TASK', '" + taskName + "')");
    var newTaskDDL = taskDDL.split(sourceDb).join(cloneDb);
    execSQL(newTaskDDL);
    
    tasks_fixed++;
    // Tasks remain SUSPENDED (intentional for non-prod)
}
```

**Key Point:** Tasks remain SUSPENDED after repointing. Perfect for dev/test environments.

**Full implementation:** [`sql/02_clone_repoint.sql#L252-L295`](../../sql/02_clone_repoint.sql)

---

## Recreating Streams (The Special Case)

Streams can't be "repointed" — they must be **dropped and recreated**.

### Why Streams Are Different

When you clone:

```
Production Stream                 Cloned Stream (BROKEN)
  ├─ Tracks: prod_db.data.orders    ├─ Still tracks: prod_db.data.orders ⚠️
  ├─ Offset: Transaction 12,456     ├─ Offset: LOST ⚠️
  └─ Status: Current                └─ Status: STALE ⚠️
```

The stream object clones but:
1. Still tracks the **source table in production**
2. Loses its **offset position**
3. Becomes immediately **STALE**

### Recreation Flow

```javascript
// Get all streams in schema
execSQL("SHOW STREAMS IN SCHEMA " + cloneDb + "." + schema);
var streamRS = execSQL(
    'SELECT "name", "base_tables", "stale" ' +
    'FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))'
);

while (streamRS.next()) {
    var streamName = streamRS.getColumnValue(1);
    
    // Get stream DDL
    var ddl = execSQL(
        "SELECT GET_DDL('STREAM', '" + 
        cloneDb + "." + schema + "." + streamName + "')"
    );
    
    // Replace database references
    var newDDL = ddl.split(sourceDb).join(cloneDb);
    
    // Drop and recreate
    execSQL("DROP STREAM IF EXISTS " + streamName);
    execSQL(newDDL);
    
    streams_recreated++;
}
```

**Full implementation:** [`sql/03_clone_streams.sql#L65-L140`](../../sql/03_clone_streams.sql)

### Important: Stream Offset Behavior

```sql
-- Original stream (in production)
CREATE STREAM prod_stream ON TABLE production_db.data.customers;
-- Has been tracking changes for weeks, offset at transaction 12345

-- After recreating in clone
CREATE STREAM dev_stream ON TABLE dev_db.data.customers;
-- Offset starts at CURRENT_TIMESTAMP (no historical changes)
```

**Implication:** Cloned streams don't have historical change data. They start fresh.

---

## Validation: Ensuring Everything Worked

After repointing, verify the clone is healthy:

```javascript
// Check for views still referencing production
var staleViews = execSQL(
    "SELECT TABLE_SCHEMA, TABLE_NAME " +
    "FROM clone_db.INFORMATION_SCHEMA.VIEWS " +
    "WHERE VIEW_DEFINITION ILIKE '%source_db%'"
);

// Check for procedures still referencing production
var staleProcs = execSQL(
    "SELECT PROCEDURE_SCHEMA, PROCEDURE_NAME " +
    "FROM clone_db.INFORMATION_SCHEMA.PROCEDURES " +
    "WHERE PROCEDURE_DEFINITION ILIKE '%source_db%'"
);

// Check for stale streams
var staleStreams = execSQL(
    "SHOW STREAMS WHERE stale = 'true' " +
    "OR base_tables ILIKE '%source_db%'"
);

// Generate report
return {
    status: (staleViews.count + staleProcs.count + staleStreams.count === 0) 
        ? 'PASS' : 'WARN',
    stale_views: staleViews.count,
    stale_procedures: staleProcs.count,
    stale_streams: staleStreams.count
};
```

**Full implementation:** [`sql/02_clone_repoint.sql#L297-L365`](../../sql/02_clone_repoint.sql)

### Usage

```sql
CALL sp_validate_clone('DEV_PROJECT_DB', 'PRODUCTION_DB');

-- Result:
-- {
--   "status": "PASS",
--   "stale_views": 0,
--   "stale_procedures": 0,
--   "stale_streams": 0
-- }
```

---

## Performance: Sequential vs Parallel

For large databases with many schemas:

| Approach | Time for 6 schemas |
|----------|-------------------|
| Sequential (one at a time) | ~45 minutes |
| **Parallel (ASYNC/AWAIT)** | **~8 minutes** |

We'll cover parallelization in detail in Part 4.

---

## Common Gotchas

### 1. Case Sensitivity

```javascript
// ❌ Won't catch lowercase references
var newDDL = ddl.split(sourceDb).join(cloneDb);

// ✅ Handle both cases
var newDDL = ddl.split(sourceDb).join(cloneDb)
                .split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());
```

### 2. Partial Matches

```javascript
// If source_db = "PROD"
// This accidentally replaces "PRODUCTION_TABLE" → "DEV_DUCTION_TABLE"

// Solution: Use specific database names or word boundaries
```

### 3. Hardcoded Strings in Procedures

```javascript
// This won't be caught by simple string replacement
CREATE PROCEDURE my_proc() AS
$$
    var db = "PRODUCTION_DB";  // Hardcoded!
    snowflake.execute({sqlText: "SELECT * FROM " + db + ".schema.table"});
$$;
```

**Best practice:** Use parameters or configuration tables, not hardcoded strings.

---

## Production Metrics

After implementing automated repointing:

| Metric | Before (Manual) | After (Automated) |
|--------|-----------------|-------------------|
| Time to repoint 6 schemas | 8-12 hours | 8 minutes (parallel) |
| Missed references | 10-15 per clone | 0-1 per clone |
| Failed views | 5-8 | 0 |
| Human errors | Several per clone | None |
| Success rate | 80-85% | 99%+ |

---

## What's Next?

We've now solved:
- ✅ Permissions and RBAC
- ✅ Database reference repointing
- ✅ Stream recreation

But our solution still processes schemas **sequentially**. In Part 4, we'll add:

- **Parallel processing** with ASYNC/AWAIT (73% faster)
- **Resume-from-failure** capabilities
- **Audit logging** and observability
- **Task suspension** for cost control
- **Production-grade** orchestration

---

**Next:** [Part 4: Parallelization and Production Features →](04-advanced-topics.md)  
**Previous:** [Part 2: Solving Permissions and RBAC](02-permissions-rbac.md)  
**Code:** [`sql/02_clone_repoint.sql`](../../sql/02_clone_repoint.sql), [`sql/03_clone_streams.sql`](../../sql/03_clone_streams.sql)

---

**About This Series**

This is Part 3 of a 4-part series on production-grade Snowflake database cloning. All code is available in the [GitHub repository](https://github.com/LALITHASWAROOPK/snowflake_cloning) with complete documentation and examples.
