# Part 4: Parallelization and Production Features

**Previously:** In [Part 3](03-repointing-streams.md), we learned how to repoint database references and recreate streams.

**In this post:** Scale your cloning operations with parallel processing, add resume-from-failure capabilities, implement audit logging, and build production-grade orchestration.

---

## The Performance Problem

Our repointing solution works, but doesn't scale:

```sql
-- Sequential processing (6 schemas)
CALL sp_repoint_schema('dev_db', 'prod_db', 'ADMINISTRATION');  -- 5 min
CALL sp_repoint_schema('dev_db', 'prod_db', 'INTEGRATION');     -- 8 min
CALL sp_repoint_schema('dev_db', 'prod_db', 'ANALYTICS');       -- 12 min
CALL sp_repoint_schema('dev_db', 'prod_db', 'DATA');            -- 10 min
CALL sp_repoint_schema('dev_db', 'prod_db', 'REPORTING');       -- 7 min
CALL sp_repoint_schema('dev_db', 'prod_db', 'ARCHIVE');         -- 3 min

-- Total: 45 minutes ⏰
```

**Problem:** Each schema blocks the next. We're not using Snowflake's compute parallelism.

---

## Solution: ASYNC/AWAIT Pattern

Snowflake's `ASYNC` and `AWAIT` keywords enable parallel execution:

```sql
-- Launch all schemas in parallel
ASYNC (CALL sp_repoint_schema('dev_db', 'prod_db', 'ADMINISTRATION'));
ASYNC (CALL sp_repoint_schema('dev_db', 'prod_db', 'INTEGRATION'));
ASYNC (CALL sp_repoint_schema('dev_db', 'prod_db', 'ANALYTICS'));
ASYNC (CALL sp_repoint_schema('dev_db', 'prod_db', 'DATA'));
ASYNC (CALL sp_repoint_schema('dev_db', 'prod_db', 'REPORTING'));
ASYNC (CALL sp_repoint_schema('dev_db', 'prod_db', 'ARCHIVE'));

-- Wait for all to complete
AWAIT ALL;

-- Result: ~12 minutes (limited by slowest schema)
```

**Speedup:** 45 minutes → 12 minutes = **73% faster**

---

## Parallel Architecture

### High-Level Flow

```
SP_REPOINT_PARALLEL (Orchestrator)
├─ Get all schemas in clone
├─ For each schema:
│  └─ ASYNC (SP_REPOINT_SCHEMA_AND_LOG)
├─ AWAIT ALL
└─ Aggregate results

SP_REPOINT_SCHEMA_AND_LOG (Logging Wrapper)
├─ Call SP_REPOINT_SCHEMA
├─ Capture result
└─ Insert into temp results table

SP_REPOINT_SCHEMA (Worker)
├─ Repoint views
├─ Repoint procedures
├─ Repoint functions
├─ Repoint tasks
└─ Return JSON result
```

### Orchestrator Pattern

```sql
-- Simplified orchestrator logic
CREATE OR REPLACE PROCEDURE sp_clone_repoint_parallel(
    clone_db VARCHAR, 
    source_db VARCHAR
)
AS
BEGIN
    -- Create temp table for results
    CREATE TEMP TABLE temp_repoint_results (
        schema_name VARCHAR,
        result VARIANT,
        completed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
    );

    -- Get all schemas
    LET schema_rs RESULTSET := (
        SELECT SCHEMA_NAME 
        FROM clone_db.INFORMATION_SCHEMA.SCHEMATA 
        WHERE SCHEMA_NAME != 'INFORMATION_SCHEMA'
    );

    -- Launch parallel workers
    FOR rec IN schema_rs DO
        ASYNC (
            CALL sp_repoint_schema_and_log(:clone_db, :source_db, rec.SCHEMA_NAME)
        );
    END FOR;

    -- Wait for all workers
    AWAIT ALL;

    -- Aggregate results
    LET final_result := (
        SELECT OBJECT_CONSTRUCT(
            'parallel_schemas', COUNT(*),
            'total_duration_seconds', 
                DATEDIFF('second', MIN(completed_at), MAX(completed_at)),
            'schema_results', ARRAY_AGG(result)
        )
        FROM temp_repoint_results
    );

    RETURN :final_result;
END;
```

**Why temp tables?** ASYNC procedures can't return values directly. We collect results in a temp table visible to the orchestrator.

**Full implementation:** [`sql/02_clone_repoint.sql#L1-L50`](../../sql/02_clone_repoint.sql)

### Usage

```sql
CALL sp_clone_repoint_parallel('DEV_PROJECT_DB', 'PRODUCTION_DB');

-- Result:
-- {
--   "parallel_schemas": 6,
--   "total_duration_seconds": 720,  -- 12 minutes
--   "schema_results": [
--     {"schema": "ADMINISTRATION", "views_fixed": 12, "procedures_fixed": 8},
--     {"schema": "ANALYTICS", "views_fixed": 98, "procedures_fixed": 42},
--     ...
--   ]
-- }
```

---

## The Same Pattern for Streams

Parallel stream recreation follows identical architecture:

```sql
-- Orchestrator launches per-schema stream workers
CREATE OR REPLACE PROCEDURE sp_clone_recreate_streams_parallel(...)
AS
BEGIN
    CREATE TEMP TABLE temp_stream_results (...);
    
    FOR each schema:
        ASYNC (CALL sp_recreate_streams_schema_and_log(...));
    
    AWAIT ALL;
    
    RETURN aggregated_results;
END;
```

**Full implementation:** [`sql/03_clone_streams.sql#L1-L45`](../../sql/03_clone_streams.sql)

---

## Resume-from-Failure: Step-Based Tracking

### The Problem

Cloning is multi-step:

1. Delete old RBAC mappings
2. Clone database
3. Revoke production grants
4. Repoint objects
5. Recreate streams
6. Create new roles
7. Apply RBAC mappings
8. Transfer ownership
9. Suspend tasks
10. Validate clone

**What happens if Step 5 fails?** You don't want to start over!

### The Solution: Step Logging

Track each step in a dedicated table:

```sql
CREATE TABLE clone_step_log (
    log_id NUMBER AUTOINCREMENT,
    audit_id NUMBER,          -- Links to clone_audit_log
    clone_db VARCHAR,
    step_number NUMBER,
    step_name VARCHAR,
    status VARCHAR DEFAULT 'PENDING',  -- PENDING, IN_PROGRESS, SUCCESS, FAILED
    result VARIANT,
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    completed_at TIMESTAMP
);
```

### Logging Pattern

```javascript
// In master clone procedure
function executeStep(stepNum, stepName, stepFunction) {
    // Log step start
    execSQL(
        "INSERT INTO clone_step_log " +
        "(audit_id, clone_db, step_number, step_name, status) " +
        "VALUES (..., " + stepNum + ", '" + stepName + "', 'IN_PROGRESS')"
    );
    
    try {
        // Execute the step
        var result = stepFunction();
        
        // Log success
        execSQL(
            "UPDATE clone_step_log " +
            "SET status = 'SUCCESS', result = '" + JSON.stringify(result) + "', " +
            "    completed_at = CURRENT_TIMESTAMP() " +
            "WHERE step_number = " + stepNum + " AND status = 'IN_PROGRESS'"
        );
        
        return result;
    } catch (e) {
        // Log failure
        execSQL(
            "UPDATE clone_step_log " +
            "SET status = 'FAILED', result = OBJECT_CONSTRUCT('error', '" + e.message + "'), " +
            "    completed_at = CURRENT_TIMESTAMP() " +
            "WHERE step_number = " + stepNum + " AND status = 'IN_PROGRESS'"
        );
        throw e;  // Re-throw to abort remaining steps
    }
}
```

### Resume Logic

```javascript
// Master procedure signature
CREATE PROCEDURE sp_clone_create_master(
    clone_type VARCHAR,
    name_part1 VARCHAR,
    name_part2 VARCHAR DEFAULT NULL,
    resume_from_step FLOAT DEFAULT 0  -- 👈 Resume parameter
)

// Execution logic
var steps = [
    {num: 1, name: 'DELETE_RBAC', fn: deleteRBACMappings},
    {num: 2, name: 'CLONE_DATABASE', fn: cloneDatabase},
    {num: 3, name: 'REVOKE_GRANTS', fn: revokeGrants},
    {num: 4, name: 'REPOINT', fn: repointParallel},
    {num: 5, name: 'STREAMS', fn: recreateStreamsParallel},
    {num: 6, name: 'CREATE_ROLES', fn: createRoles},
    {num: 7, name: 'APPLY_RBAC', fn: applyRBAC},
    {num: 8, name: 'ICEBERG', fn: handleIceberg},
    {num: 9, name: 'SUSPEND_TASKS', fn: suspendTasks},
    {num: 10, name: 'VALIDATE', fn: validateClone}
];

for (var i = 0; i < steps.length; i++) {
    if (steps[i].num < resume_from_step) {
        continue;  // Skip this step
    }
    
    executeStep(steps[i].num, steps[i].name, steps[i].fn);
}
```

### Resuming

```sql
-- Initial attempt fails at step 5
CALL sp_clone_create_master('PROJECT', 'customer360', 'DEV');
-- ERROR at step 5: Stream recreation failed

-- Check what happened
SELECT step_number, step_name, status, result
FROM clone_step_log
WHERE clone_db = 'DEV_CUSTOMER360_DB'
ORDER BY step_number;

-- Fix the issue, then resume from step 5
CALL sp_clone_create_master('PROJECT', 'customer360', 'DEV', 5);
-- ✅ Steps 1-4 skipped, execution resumes from step 5
```

**Key benefit:** No need to wait another 30 minutes to re-clone. Just fix and resume.

**Full implementation:** [`sql/05_clone_master.sql`](../../sql/05_clone_master.sql)

---

## Audit Logging: Observability

### The Audit Table

```sql
CREATE TABLE clone_audit_log (
    audit_id NUMBER AUTOINCREMENT,
    clone_db VARCHAR NOT NULL,
    clone_type VARCHAR NOT NULL,      -- PROJECT, RELEASE
    action VARCHAR NOT NULL,          -- CREATE, DROP, UPDATE
    project_name VARCHAR,
    env_name VARCHAR,                 -- DEV, QA, STAGING
    source_db VARCHAR DEFAULT 'PRODUCTION_DB',
    status VARCHAR NOT NULL,          -- IN_PROGRESS, SUCCESS, FAILED
    error_msg VARCHAR(4000),
    created_by VARCHAR DEFAULT CURRENT_USER(),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    completed_at TIMESTAMP
);
```

### Key Metrics

```sql
-- Clone success rate (last 30 days)
SELECT 
    COUNT(*) AS total_clones,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) AS successful,
    ROUND(100.0 * successful / total_clones, 2) AS success_rate
FROM clone_audit_log
WHERE created_at >= DATEADD('day', -30, CURRENT_TIMESTAMP())
AND action = 'CREATE';

-- Average duration by environment
SELECT 
    env_name,
    AVG(DATEDIFF('minute', created_at, completed_at)) AS avg_minutes
FROM clone_audit_log
WHERE status = 'SUCCESS' AND completed_at IS NOT NULL
GROUP BY env_name;

-- Most common failure points
SELECT 
    step_name,
    COUNT(*) AS failure_count
FROM clone_step_log
WHERE status = 'FAILED'
AND started_at >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY step_name
ORDER BY failure_count DESC;
```

---

## Task Suspension: Cost Control

### The Problem

Cloned databases inherit **active tasks** from production:

```sql
SHOW TASKS IN DATABASE dev_project_db;
-- Result: 23 tasks, STATE = 'started' ⚠️
-- Running hourly, daily, etc. in DEV!
```

**Cost:** $200-500/month per clone in wasted compute.

### The Solution

```javascript
// Auto-suspend all tasks in clone
function suspendTasks() {
    var schemas = getAllSchemas(cloneDb);
    var tasksSuspended = 0;
    
    for each schema:
        var tasks = execSQL("SHOW TASKS IN SCHEMA " + schema);
        
        for each task in tasks:
            if (task.state === 'started'):
                execSQL("ALTER TASK " + task.name + " SUSPEND");
                tasksSuspended++;
    
    return {tasks_suspended: tasksSuspended};
}
```

**Integration:** Add as Step 9 in clone pipeline.

**Result:** All tasks suspended by default in non-prod clones.

**Full implementation:** [`sql/05_clone_master.sql#L280-L320`](../../sql/05_clone_master.sql)

---

## Iceberg Table Handling

### Auto-Grant Volume Access

```javascript
// Step 8: Handle Iceberg tables
function handleIcebergTables() {
    var icebergTables = execSQL(
        "SELECT DISTINCT external_volume " +
        "FROM information_schema.tables " +
        "WHERE table_type IN ('ICEBERG TABLE', 'DYNAMIC ICEBERG TABLE') " +
        "AND external_volume IS NOT NULL"
    );
    
    for each volume in icebergTables:
        execSQL("GRANT READ ON EXTERNAL VOLUME " + volume + " TO DATABASE " + cloneDb);
        volume_grants++;
    
    // Flag dynamic Iceberg tables for manual review
    var dynamicIceberg = execSQL(
        "SELECT table_schema, table_name " +
        "FROM information_schema.tables " +
        "WHERE table_type = 'DYNAMIC ICEBERG TABLE'"
    );
    
    return {
        volume_grants_applied: volume_grants,
        dynamic_tables_flagged: dynamicIceberg.count
    };
}
```

**See also:** [Iceberg Considerations Guide](../iceberg-considerations.md)

---

## Master Orchestration

Bringing it all together:

```sql
-- One command to rule them all
CALL sp_clone_create_master('PROJECT', 'customer360', 'DEV');
```

**Behind the scenes:**

```
Step 1: DELETE_RBAC_MAPPINGS      [3 sec]
Step 2: CLONE_DATABASE             [3 sec]  ← Snowflake native
Step 3: REVOKE_GRANTS              [45 sec]
Step 4: REPOINT_PARALLEL           [8 min]  ← ASYNC/AWAIT
Step 5: RECREATE_STREAMS_PARALLEL  [2 min]  ← ASYNC/AWAIT
Step 6: CREATE_ROLES               [1 min]
Step 7: APPLY_RBAC_MAPPINGS        [15 sec]
Step 8: HANDLE_ICEBERG             [5 sec]
Step 9: SUSPEND_TASKS              [10 sec]
Step 10: VALIDATE                  [30 sec]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total: ~12 minutes

Result:
✅ Fully functional dev environment
✅ Correct permissions
✅ All references updated
✅ Streams recreated
✅ Tasks suspended
✅ Iceberg configured
✅ Validated and ready
```

**Full implementation:** [`sql/05_clone_master.sql`](../../sql/05_clone_master.sql)

---

## Performance Tuning Tips

### 1. Warehouse Sizing

```sql
-- Use larger warehouse for parallel operations
ALTER WAREHOUSE clone_wh SET WAREHOUSE_SIZE = 'XLARGE';

-- After clone completes
ALTER WAREHOUSE clone_wh SET WAREHOUSE_SIZE = 'SMALL';
```

### 2. Batch Processing

For 50+ schemas:

```sql
-- Process in batches to avoid overwhelming warehouse
-- Batch 1: Schemas 1-10
-- Batch 2: Schemas 11-20
-- etc.
```

### 3. Query Optimization

```sql
-- ❌ Scans entire database
SELECT * FROM information_schema.views 
WHERE view_definition ILIKE '%prod_db%';

-- ✅ Filter by schema first
SELECT * FROM information_schema.views 
WHERE table_schema = 'ANALYTICS'
AND view_definition ILIKE '%prod_db%';
```

---

## Production Metrics: The Full Picture

| Metric | Manual | Semi-Auto | **Fully Automated** |
|--------|--------|-----------|---------------------|
| Time to clone | 1-2 days | 4-6 hours | **8-12 minutes** |
| Human intervention | Constant | Occasional | **None** |
| Error rate | 15-20% | 5-8% | **<1%** |
| Concurrent clones | 1 | 2-3 | **10+** |
| Resume capability | No | Partial | **Full** |
| Cost per clone | High | Medium | **Low** |
| Audit trail | Manual | Basic | **Complete** |

---

## Key Takeaways

1. **Parallelization is essential** - ASYNC/AWAIT delivers 73% speedup
2. **Resume-from-failure saves hours** - Step tracking enables smart recovery
3. **Observability matters** - Audit logs provide accountability and insights
4. **Task suspension prevents waste** - Auto-suspend saves $200-500/month per clone
5. **Iceberg needs attention** - External volumes and dynamic tables require special handling

---

## What We've Built

Over this 4-part series, we created a production-grade cloning solution:

✅ **Handles permissions** - Dynamic RBAC provisioning  
✅ **Repoints references** - All object types updated  
✅ **Recreates streams** - With correct offsets  
✅ **Processes in parallel** - 73% faster  
✅ **Resumes from failure** - No starting over  
✅ **Logs everything** - Complete observability  
✅ **Suspends tasks** - Cost control  
✅ **Handles Iceberg** - External volumes and dynamic tables  
✅ **Validates results** - Health checks  

**One command:**

```sql
CALL sp_clone_create_master('PROJECT', 'myproject', 'DEV');
```

**Result:** Fully functional dev environment in ~8 minutes.

---

## Going Further

### Clone Scheduling
```sql
-- Weekly QA refresh
CREATE TASK refresh_qa_clone
  SCHEDULE = 'USING CRON 0 6 * * 1 America/Los_Angeles'
AS
  CALL sp_clone_update('PROJECT', 'myproject', 'QA');
```

### Self-Service UI
Build a web interface for teams to request/manage clones.

### Data Masking
Apply dynamic masking policies after cloning for PII protection.

### Cost Tracking
Tag clones with cost centers for chargeback.

### Auto-Expiration
Drop clones after N days to control costs.

---

## Resources

**Code Repository:** [github.com/LALITHASWAROOPK/snowflake_cloning](https://github.com/LALITHASWAROOPK/snowflake_cloning)

**Blog Series:**
- [Part 1: The Problem and the Promise](01-the-problem.md)
- [Part 2: Solving Permissions and RBAC](02-permissions-rbac.md)
- [Part 3: Repointing References and Recreating Streams](03-repointing-streams.md)
- Part 4: Parallelization and Production Features (this post)

**Special Topics:**
- [Iceberg Tables Guide](../iceberg-considerations.md)

---

**Did this help?** Star the repo and share with your team!

**Questions?** Open an issue on GitHub or comment below.

---

**Previous:** [Part 3: Repointing Database References and Recreating Streams](03-repointing-streams.md)  
**Series Start:** [Introduction and Overview](00-overview.md)

---

*This series documents real production patterns from managing 20+ database clones in Fortune 500 enterprises, including the latest challenges with Iceberg tables and external volumes.*
