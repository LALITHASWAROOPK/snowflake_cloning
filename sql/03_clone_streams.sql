-- ============================================================================
-- Clone Management: Stream Recreation
-- Database: <PLATFORM_DB>.<ADMIN_SCHEMA>
-- ============================================================================
-- Problem: Streams become stale after cloning. They point to tables in the
--          source database and lose their offset position.
-- Solution: Drop and recreate streams with updated references using GET_DDL.
-- ============================================================================

-- Orchestrator: launches per-schema stream workers in parallel
CREATE OR REPLACE PROCEDURE <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_RECREATE_STREAMS_PARALLEL(
    CLONE_DB VARCHAR, 
    SOURCE_DB VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_STREAM_RESULTS (
        SCHEMA_NAME VARCHAR,
        RESULT VARIANT,
        COMPLETED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
    );

    LET sql_text VARCHAR;
    LET schema_rs RESULTSET;

    sql_text := 'SELECT SCHEMA_NAME FROM ' || :clone_db || '.INFORMATION_SCHEMA.SCHEMATA 
                 WHERE SCHEMA_NAME != ''INFORMATION_SCHEMA''';
    schema_rs := (EXECUTE IMMEDIATE :sql_text);

    -- Launch parallel workers per schema
    FOR rec IN schema_rs DO
        LET sn VARCHAR := rec.SCHEMA_NAME;
        ASYNC (
            CALL <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_RECREATE_STREAMS_SCHEMA_AND_LOG(:clone_db, :source_db, :sn)
        );
    END FOR;

    AWAIT ALL;

    LET final_result VARIANT := (
        SELECT OBJECT_CONSTRUCT(
            'parallel_schemas', COUNT(*),
            'schema_results', ARRAY_AGG(RESULT)
        )
        FROM <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_STREAM_RESULTS
    );

    DROP TABLE IF EXISTS <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_STREAM_RESULTS;
    RETURN :final_result;
EXCEPTION
    WHEN OTHER THEN
        LET err_result VARIANT := (
            SELECT OBJECT_CONSTRUCT('error', :SQLERRM, 'partial_results', ARRAY_AGG(RESULT))
            FROM <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_STREAM_RESULTS
        );
        RETURN :err_result;
END;

-- Logging wrapper
CREATE OR REPLACE PROCEDURE <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_RECREATE_STREAMS_SCHEMA_AND_LOG(
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
    CALL <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_RECREATE_STREAMS_SCHEMA(:clone_db, :source_db, :schema_name);
    SELECT * INTO :result FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    INSERT INTO <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_STREAM_RESULTS (SCHEMA_NAME, RESULT)
        SELECT :schema_name, TRY_PARSE_JSON(:result);
    RETURN 'done';
EXCEPTION
    WHEN OTHER THEN
        INSERT INTO <PLATFORM_DB>.<ADMIN_SCHEMA>.TEMP_STREAM_RESULTS (SCHEMA_NAME, RESULT)
            SELECT :schema_name, OBJECT_CONSTRUCT('error', :SQLERRM);
        RETURN 'error';
END;

-- Per-schema worker: recreates streams for a single schema
CREATE OR REPLACE PROCEDURE <PLATFORM_DB>.<ADMIN_SCHEMA>.SP_CLONE_RECREATE_STREAMS_SCHEMA(
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
    streams_recreated: 0,
    streams_failed: 0,
    streams_skipped: 0,
    errors: []
};

var cloneDb = CLONE_DB.toUpperCase();
var sourceDb = SOURCE_DB.toUpperCase();
var schemaName = SCHEMA_NAME.toUpperCase();

function execSQL(sql) {
    return snowflake.execute({sqlText: sql});
}

try {
    // Get all streams in the schema
    execSQL("SHOW STREAMS IN SCHEMA " + cloneDb + "." + schemaName);
    var streamRS = execSQL(
        'SELECT "name", "source_type", "base_tables", "type", "mode", ' +
        '       "table_name", "stale", "stale_after" ' +
        'FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))'
    );

    var streamDefs = [];
    while (streamRS.next()) {
        streamDefs.push({
            name: streamRS.getColumnValue(1),
            sourceType: streamRS.getColumnValue(2),
            baseTables: streamRS.getColumnValue(3) || '',
            streamType: streamRS.getColumnValue(4),
            mode: streamRS.getColumnValue(5),
            tableName: streamRS.getColumnValue(6) || '',
            stale: streamRS.getColumnValue(7),
            staleAfter: streamRS.getColumnValue(8)
        });
    }

    // Process each stream
    for (var i = 0; i < streamDefs.length; i++) {
        var s = streamDefs[i];
        var streamName = s.name;

        try {
            // Get the stream DDL
            var getDDL = execSQL(
                "SELECT GET_DDL('STREAM', '" + cloneDb + "." + schemaName + "." + streamName + "')"
            );
            var ddl = '';
            if (getDDL.next()) {
                ddl = getDDL.getColumnValue(1);
            }

            if (!ddl) {
                results.streams_skipped++;
                continue;
            }

            // Replace source database references with clone database
            var newDDL = ddl.split(sourceDb).join(cloneDb);
            newDDL = newDDL.split(sourceDb.toLowerCase()).join(cloneDb.toLowerCase());

            // Drop and recreate the stream
            execSQL("DROP STREAM IF EXISTS " + cloneDb + "." + schemaName + "." + streamName);
            execSQL("USE DATABASE " + cloneDb);
            execSQL("USE SCHEMA " + schemaName);
            execSQL(newDDL);

            results.streams_recreated++;
        } catch (streamErr) {
            results.streams_failed++;
            results.errors.push({
                type: 'STREAM',
                object: schemaName + '.' + streamName,
                baseTables: s.baseTables,
                error: streamErr.message.substring(0, 200)
            });
        }
    }
} catch (schemaErr) {
    results.errors.push({
        type: 'SCHEMA_ERR', 
        error: schemaErr.message.substring(0, 200)
    });
}

return JSON.stringify(results);
$$;
