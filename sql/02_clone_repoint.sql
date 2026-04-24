-- ============================================================================
-- Clone Management: Database Reference Repointing
-- Database: <PLATFORM_DB>.<ADMIN_SCHEMA>
-- ============================================================================
-- Problem: After cloning, views/procedures/functions/tasks still reference
--          the source database (e.g., PRODUCTION_DB) instead of the clone.
-- Solution: Parallel repointing using GET_DDL and string replacement.
-- ============================================================================

-- Orchestrator: launches per-schema repoint workers in parallel
CREATE OR REPLACE PROCEDURE <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_REPOINT_PARALLEL(
    CLONE_DB VARCHAR, 
    SOURCE_DB VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
BEGIN
    -- Create temp results table
    CREATE OR REPLACE TEMPORARY TABLE <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_REPOINT_RESULTS (
        SCHEMA_NAME VARCHAR,
        RESULT VARIANT,
        COMPLETED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
    );

    LET sql_text VARCHAR;
    LET schema_rs RESULTSET;

    -- Get all schemas in clone
    sql_text := 'SELECT SCHEMA_NAME FROM ' || :clone_db || '.INFORMATION_SCHEMA.SCHEMATA 
                 WHERE SCHEMA_NAME != ''INFORMATION_SCHEMA''';
    schema_rs := (EXECUTE IMMEDIATE :sql_text);

    -- Launch parallel workers per schema (ASYNC/AWAIT pattern)
    FOR rec IN schema_rs DO
        LET sn VARCHAR := rec.SCHEMA_NAME;
        ASYNC (
            CALL <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_REPOINT_SCHEMA_AND_LOG(:clone_db, :source_db, :sn)
        );
    END FOR;

    -- Wait for all workers to complete
    AWAIT ALL;

    -- Aggregate results
    LET final_result VARIANT := (
        SELECT OBJECT_CONSTRUCT(
            'parallel_schemas', COUNT(*),
            'schema_results', ARRAY_AGG(RESULT)
        )
        FROM <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_REPOINT_RESULTS
    );

    DROP TABLE IF EXISTS <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_REPOINT_RESULTS;
    RETURN :final_result;
EXCEPTION
    WHEN OTHER THEN
        LET err_result VARIANT := (
            SELECT OBJECT_CONSTRUCT('error', :SQLERRM, 'partial_results', ARRAY_AGG(RESULT))
            FROM <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_REPOINT_RESULTS
        );
        RETURN :err_result;
END;

-- Logging wrapper: calls per-schema worker and writes result to temp table
CREATE OR REPLACE PROCEDURE <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_REPOINT_SCHEMA_AND_LOG(
    CLONE_DB VARCHAR, 
    SOURCE_DB VARCHAR, 
    SCHEMA_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
DECLARE
    result VARCHAR;
BEGIN
    CALL <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_REPOINT_SCHEMA(:clone_db, :source_db, :schema_name);
    SELECT * INTO :result FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    INSERT INTO <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_REPOINT_RESULTS (SCHEMA_NAME, RESULT)
        SELECT :schema_name, TRY_PARSE_JSON(:result);
    RETURN 'done';
EXCEPTION
    WHEN OTHER THEN
        INSERT INTO <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_REPOINT_RESULTS (SCHEMA_NAME, RESULT)
            SELECT :schema_name, OBJECT_CONSTRUCT('error', :SQLERRM);
        RETURN 'error';
END;

-- Per-schema worker: repoints views/procs/functions/tasks for a single schema
CREATE OR REPLACE PROCEDURE <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_REPOINT_SCHEMA(
    CLONE_DB VARCHAR, 
    SOURCE_DB VARCHAR, 
    SCHEMA_NAME VARCHAR
)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
var results = {
    schema: SCHEMA_NAME,
    views_fixed: 0, views_failed: 0,
    procedures_fixed: 0, procedures_failed: 0,
    functions_fixed: 0, functions_failed: 0,
    tasks_fixed: 0, tasks_failed: 0,
    errors: []
};

var cloneDb = CLONE_DB.toUpperCase();
var sourceDb = SOURCE_DB.toUpperCase();
var schemaName = SCHEMA_NAME.toUpperCase();

function execSQL(sql) {
    return snowflake.execute({sqlText: sql});
}

// Strip parameter names from signature, keeping only types
// Example: "(id NUMBER, name VARCHAR)" -> "(NUMBER, VARCHAR)"
function stripParamNames(sig) {
    if (!sig || sig.trim() === "" || sig.trim() === "()")  return "()";
    var inner = sig.replace(/^\(/, "").replace(/\)$/, "");
    var params = inner.split(",");
    var types = [];
    for (var i = 0; i < params.length; i++) {
        var p = params[i].trim();
        var parts = p.split(/\s+/);
        if (parts.length >= 2) {
            types.push(parts.slice(1).join(" "));
        } else {
            types.push(parts[0]);
        }
    }
    return "(" + types.join(", ") + ")";
}

// ============================================================================
// VIEWS: Find and repoint views that reference source database
// ============================================================================
try {
    var viewRS = execSQL(
        "SELECT TABLE_SCHEMA, TABLE_NAME, VIEW_DEFINITION " +
        "FROM " + cloneDb + ".INFORMATION_SCHEMA.VIEWS " +
        "WHERE TABLE_SCHEMA = '" + schemaName + "' " +
        "AND VIEW_DEFINITION ILIKE '%" + sourceDb + "%'"
    );
    while (viewRS.next()) {
        var viewName = viewRS.getColumnValue(2);
        var viewDef = viewRS.getColumnValue(3);
        try {
            // Replace all occurrences of source DB with clone DB (case-insensitive)
            var newDef = viewDef.split(sourceDb).join(cloneDb);
            newDef = newDef.split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());
            
            execSQL("USE DATABASE " + cloneDb);
            execSQL("USE SCHEMA " + schemaName);
            execSQL(newDef);
            results.views_fixed++;
        } catch (viewErr) {
            results.views_failed++;
            results.errors.push({
                type: 'VIEW', 
                object: schemaName + '.' + viewName, 
                error: viewErr.message.substring(0, 200)
            });
        }
    }
} catch (e) {
    results.errors.push({type: 'VIEW_SCAN', error: e.message.substring(0, 200)});
}

// ============================================================================
// PROCEDURES: Find and repoint procedures that reference source database
// ============================================================================
try {
    var procRS = execSQL(
        "SELECT PROCEDURE_SCHEMA, PROCEDURE_NAME, ARGUMENT_SIGNATURE " +
        "FROM " + cloneDb + ".INFORMATION_SCHEMA.PROCEDURES " +
        "WHERE PROCEDURE_SCHEMA = '" + schemaName + "' " +
        "AND PROCEDURE_DEFINITION ILIKE '%" + sourceDb + "%'"
    );
    while (procRS.next()) {
        var pName = procRS.getColumnValue(2);
        var pSig = procRS.getColumnValue(3);
        var pTypeSig = stripParamNames(pSig);
        try {
            // Get full DDL and replace database references
            var getddlRS = execSQL(
                "SELECT GET_DDL('PROCEDURE', '" + cloneDb + "." + schemaName + "." + pName + pTypeSig + "')"
            );
            if (getddlRS.next()) {
                var fullDDL = getddlRS.getColumnValue(1);
                var newDDL = fullDDL.split(sourceDb).join(cloneDb);
                newDDL = newDDL.split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());
                
                execSQL("USE DATABASE " + cloneDb);
                execSQL("USE SCHEMA " + schemaName);
                execSQL(newDDL);
                results.procedures_fixed++;
            }
        } catch (procErr) {
            results.procedures_failed++;
            results.errors.push({
                type: 'PROCEDURE', 
                object: schemaName + '.' + pName, 
                error: procErr.message.substring(0, 200)
            });
        }
    }
} catch (e) {
    results.errors.push({type: 'PROC_SCAN', error: e.message.substring(0, 200)});
}

// ============================================================================
// FUNCTIONS: Find and repoint functions that reference source database
// ============================================================================
try {
    var funcRS = execSQL(
        "SELECT FUNCTION_SCHEMA, FUNCTION_NAME, ARGUMENT_SIGNATURE " +
        "FROM " + cloneDb + ".INFORMATION_SCHEMA.FUNCTIONS " +
        "WHERE FUNCTION_SCHEMA = '" + schemaName + "' " +
        "AND FUNCTION_DEFINITION ILIKE '%" + sourceDb + "%'"
    );
    while (funcRS.next()) {
        var fName = funcRS.getColumnValue(2);
        var fSig = funcRS.getColumnValue(3);
        var fTypeSig = stripParamNames(fSig);
        try {
            var getFuncDDL = execSQL(
                "SELECT GET_DDL('FUNCTION', '" + cloneDb + "." + schemaName + "." + fName + fTypeSig + "')"
            );
            if (getFuncDDL.next()) {
                var funcDDL = getFuncDDL.getColumnValue(1);
                var newFuncDDL = funcDDL.split(sourceDb).join(cloneDb);
                newFuncDDL = newFuncDDL.split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());
                
                execSQL("USE DATABASE " + cloneDb);
                execSQL("USE SCHEMA " + schemaName);
                execSQL(newFuncDDL);
                results.functions_fixed++;
            }
        } catch (funcErr) {
            results.functions_failed++;
            results.errors.push({
                type: 'FUNCTION', 
                object: schemaName + '.' + fName, 
                error: funcErr.message.substring(0, 200)
            });
        }
    }
} catch (e) {
    results.errors.push({type: 'FUNC_SCAN', error: e.message.substring(0, 200)});
}

// ============================================================================
// TASKS: Find and repoint tasks that reference source database
// ============================================================================
try {
    var taskRS = execSQL(
        "SELECT NAME, DEFINITION " +
        "FROM " + cloneDb + ".INFORMATION_SCHEMA.TASKS " +
        "WHERE SCHEMA_NAME = '" + schemaName + "' " +
        "AND DEFINITION ILIKE '%" + sourceDb + "%'"
    );
    while (taskRS.next()) {
        var tName = taskRS.getColumnValue(1);
        var tDef = taskRS.getColumnValue(2);
        try {
            var getTaskDDL = execSQL(
                "SELECT GET_DDL('TASK', '" + cloneDb + "." + schemaName + "." + tName + "')"
            );
            if (getTaskDDL.next()) {
                var taskDDL = getTaskDDL.getColumnValue(1);
                var newTaskDDL = taskDDL.split(sourceDb).join(cloneDb);
                newTaskDDL = newTaskDDL.split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());
                
                execSQL("USE DATABASE " + cloneDb);
                execSQL("USE SCHEMA " + schemaName);
                execSQL(newTaskDDL);
                results.tasks_fixed++;
            }
        } catch (taskErr) {
            results.tasks_failed++;
            results.errors.push({
                type: 'TASK', 
                object: schemaName + '.' + tName, 
                error: taskErr.message.substring(0, 200)
            });
        }
    }
} catch (e) {
    results.errors.push({type: 'TASK_SCAN', error: e.message.substring(0, 200)});
}

return JSON.stringify(results);
$$;
