# Part 2: Solving Permissions and RBAC in Cloned Databases

**Previously:** In [Part 1](01-the-problem.md), we discovered why zero-copy cloning is revolutionary but leaves you with broken permissions and production roles in dev environments.

**In this post:** Learn how to programmatically manage permissions in cloned databases with dynamic role creation, ownership transfers, and automated RBAC provisioning.

---

## The Permission Problem (Recap)

After cloning:

```sql
CREATE DATABASE dev_project_db CLONE production_db;
SHOW GRANTS ON DATABASE dev_project_db;
```

**Result:**
```
| privilege | grantee_name   |
|-----------|----------------|
| OWNERSHIP | PROD_ADMIN     |  ⚠️ Wrong environment!
| USAGE     | PROD_READ_ONLY |  ⚠️ Dev needs different roles
```

This creates three immediate problems:

1. **Wrong Roles** - Production roles shouldn't access dev
2. **No Access** - Dev team roles aren't granted anything
3. **Ownership Lock** - Can't modify without PROD_ADMIN privileges

## The Solution: Four-Stage Automation

Our approach automates permission management in four stages:

```
Stage 1: Temporary Ownership Transfer
   ↓
Stage 2: Permission Cleanup
   ↓
Stage 3: Dynamic Role Creation
   ↓
Stage 4: RBAC Mapping Application
```

Let's dive into each.

---

## Stage 1: Temporary Ownership Transfer

First, we need control. Grant temporary ownership to a privileged service account:

```javascript
// Pseudocode for understanding
for each schema in clone_database:
    GRANT OWNERSHIP ON SCHEMA to SERVICE_ROLE COPY CURRENT GRANTS
    
    for each object_type in [TABLES, VIEWS, PROCEDURES, ...]:
        GRANT OWNERSHIP ON ALL object_type to SERVICE_ROLE COPY CURRENT GRANTS
```

**Key insight:** `COPY CURRENT GRANTS` preserves existing permissions while changing ownership.

**Full implementation:** [sql/04_clone_rbac.sql#L1-L45](../../sql/04_clone_rbac.sql)

### Usage

```sql
CALL sp_grant_temp_ownership('dev_project_db');

-- Result:
-- {
--   "schemas_granted": 4,
--   "objects_transferred": 1250,
--   "errors": []
-- }
```

Now we have control to make changes.

---

## Stage 2: Permission Cleanup

Revoke production-specific grants, especially **future grants** that auto-apply to new objects:

```sql
-- Example: Revoke future ownership from production roles
REVOKE OWNERSHIP ON FUTURE TABLES IN SCHEMA dev_db.analytics 
  FROM ROLE PROD_ANALYTICS_OWNER;
```

For multiple schemas and object types, we automate this:

```javascript
// Pseudocode
for each schema in schemas:
    prod_role = source_database + schema_owner_suffix
    
    for each object_type in [TABLES, VIEWS, PROCEDURES, ...]:
        REVOKE OWNERSHIP ON FUTURE object_type IN SCHEMA 
          FROM ROLE prod_role
```

**Full implementation:** [sql/04_clone_rbac.sql#L47-L95](../../sql/04_clone_rbac.sql)

---

## Stage 3: Dynamic Role Creation

Instead of hardcoding role names, we generate them dynamically based on:

- **Database name** (environment-specific)
- **Schema name** (domain-specific)
- **Access level** (READ, READ_WRITE, ADMIN)

### The Pattern

```
<DATABASE>_<SCHEMA>_<LEVEL>

Examples:
DEV_PROJECT_DB_ANALYTICS_READ
DEV_PROJECT_DB_ANALYTICS_READ_WRITE
DEV_PROJECT_DB_DATA_ADMIN
```

### The Logic

```javascript
// Simplified version for understanding
for each schema in schemas:
    for each access_level in [READ, READ_WRITE, ADMIN]:
        role_name = clone_db + "_" + schema + "_" + access_level
        
        CREATE ROLE IF NOT EXISTS role_name
        GRANT USAGE ON DATABASE to role_name
        GRANT USAGE ON SCHEMA to role_name
        
        if (access_level == READ):
            GRANT SELECT ON ALL TABLES to role_name
            GRANT SELECT ON FUTURE TABLES to role_name
        else if (access_level == READ_WRITE):
            GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES to role_name
        else if (access_level == ADMIN):
            GRANT ALL ON SCHEMA to role_name
```

**Why this scales:** From 3 schemas to 300, the pattern stays the same.

**Full implementation:** [sql/04_clone_rbac.sql#L97-L185](../../sql/04_clone_rbac.sql)

### Example Usage

```sql
CALL sp_create_clone_roles(
    'DEV_PROJECT_DB',
    ARRAY_CONSTRUCT('ADMINISTRATION', 'ANALYTICS', 'DATA')
);

-- Result:
-- {
--   "roles_created": [
--     "DEV_PROJECT_DB_ADMINISTRATION_READ",
--     "DEV_PROJECT_DB_ADMINISTRATION_READ_WRITE",
--     "DEV_PROJECT_DB_ADMINISTRATION_ADMIN",
--     "DEV_PROJECT_DB_ANALYTICS_READ",
--     "DEV_PROJECT_DB_ANALYTICS_READ_WRITE",
--     "DEV_PROJECT_DB_ANALYTICS_ADMIN",
--     "DEV_PROJECT_DB_DATA_READ",
--     "DEV_PROJECT_DB_DATA_READ_WRITE",
--     "DEV_PROJECT_DB_DATA_ADMIN"
--   ],
--   "total_created": 9
-- }
```

---

## Stage 4: RBAC Mapping

The final piece: map clone-specific roles to **functional roles** that users actually have:

```
CLONE ROLE                           FUNCTIONAL ROLE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DEV_PROJECT_DB_ANALYTICS_READ   →    DATA_ANALYST_ROLE
DEV_PROJECT_DB_ANALYTICS_WRITE  →    DATA_ENGINEER_ROLE  
DEV_PROJECT_DB_ANALYTICS_ADMIN  →    PROJECT_ADMIN_ROLE
```

### Configuration Table

Store mappings in a table (not hardcoded):

```sql
CREATE TABLE rbac_mapping (
    schema_role VARCHAR(255),         -- Clone-specific role
    environment VARCHAR(40),           -- DEV, QA, STAGING
    functional_role VARCHAR(255),     -- User's actual role
    operation VARCHAR(40),            -- GRANT or REVOKE
    execute_indicator VARCHAR DEFAULT 'Y'
);

-- Example mappings with placeholder
INSERT INTO rbac_mapping (schema_role, environment, functional_role, operation)
VALUES 
    ('{{CLONE_DB}}_ANALYTICS_READ', 'DEV', 'DATA_ANALYST_ROLE', 'GRANT'),
    ('{{CLONE_DB}}_ANALYTICS_WRITE', 'DEV', 'DATA_ENGINEER_ROLE', 'GRANT'),
    ('{{CLONE_DB}}_ANALYTICS_ADMIN', 'DEV', 'PROJECT_ADMIN_ROLE', 'GRANT');
```

**Note:** `{{CLONE_DB}}` is replaced dynamically at runtime.

### The Mapping Logic

```javascript
// Pseudocode
mappings = SELECT * FROM rbac_mapping WHERE environment = target_env

for each mapping in mappings:
    schema_role = mapping.schema_role.replace('{{CLONE_DB}}', actual_clone_db)
    
    if mapping.operation == 'GRANT':
        GRANT ROLE schema_role TO ROLE mapping.functional_role
    else:
        REVOKE ROLE schema_role FROM ROLE mapping.functional_role
```

**Full implementation:** [sql/04_clone_rbac.sql#L187-L245](../../sql/04_clone_rbac.sql)

### Result

```sql
CALL sp_apply_rbac_mapping('DEV_PROJECT_DB', 'DEV');

-- Now developers can use their normal roles:
USE ROLE DATA_ANALYST_ROLE;
SELECT * FROM dev_project_db.analytics.customer_summary;  -- ✅ Works!
```

---

## Putting It All Together

Complete permission setup in one command:

```sql
CALL sp_setup_clone_permissions(
    clone_db => 'DEV_PROJECT_DB',
    source_db => 'PRODUCTION_DB',
    environment => 'DEV'
);

-- Behind the scenes:
-- ✅ Temporary ownership transferred
-- ✅ Production grants revoked
-- ✅ 9 new environment-specific roles created
-- ✅ RBAC mappings applied
-- ✅ Developers have appropriate access
```

**Implementation:** [sql/04_clone_rbac.sql#L247-L285](../../sql/04_clone_rbac.sql)

---

## Key Design Principles

### 1. Configuration Over Code

```sql
-- ❌ Hardcoded in procedures
GRANT ROLE dev_analytics_read TO ROLE data_analyst;

-- ✅ Configuration-driven
INSERT INTO rbac_mapping VALUES (...);
CALL sp_apply_rbac_mapping(...);
```

**Benefits:**
- Non-developers can manage permissions
- Different mappings per environment
- Audit trail of changes

### 2. Dynamic Role Generation

```javascript
// This scales from 3 schemas to 300
role_name = database + "_" + schema + "_" + access_level
```

### 3. Temporary Ownership Pattern

```
User requests clone
   ↓
Service role takes ownership
   ↓
Service role makes all changes
   ↓
Service role transfers ownership to target roles
```

**Never** make permission changes as the requesting user.

### 4. Future Grants Are Critical

```sql
-- ❌ Only current objects
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO ROLE analyst;

-- ✅ Current AND future objects
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO ROLE analyst;
GRANT SELECT ON FUTURE TABLES IN SCHEMA analytics TO ROLE analyst;
```

---

## Common Pitfalls (And How We Avoid Them)

### Pitfall 1: Not Using COPY CURRENT GRANTS

```sql
-- ❌ Drops all existing grants during ownership transfer
GRANT OWNERSHIP ON SCHEMA my_schema TO ROLE new_owner;

-- ✅ Preserves grants during transfer
GRANT OWNERSHIP ON SCHEMA my_schema TO ROLE new_owner COPY CURRENT GRANTS;
```

**Our code:** Always uses `COPY CURRENT GRANTS`

### Pitfall 2: Forgetting Object Types

Don't forget:
- `DYNAMIC TABLES`
- `ICEBERG TABLES`
- `EVENT TABLES`
- `STAGES`, `FILE FORMATS`, `SEQUENCES`

**Our code:** Comprehensive object type list in [`sql/04_clone_rbac.sql`](../../sql/04_clone_rbac.sql)

### Pitfall 3: Not Handling Missing Roles

```javascript
// ❌ Fails if role doesn't exist
execSQL("GRANT ROLE clone_role TO ROLE functional_role");

// ✅ Graceful error handling (in our procedures)
try {
    execSQL("GRANT ROLE ...");
    success_count++;
} catch (e) {
    errors.push({error: e.message});
}
```

**Our code:** Try-catch blocks around all grant operations

---

## Production Metrics

After implementing automated RBAC:

| Metric | Before | After |
|--------|--------|-------|
| Time to grant permissions | 45-90 min | < 2 min |
| Permission errors per clone | 8-12 | 0-1 |
| Security audit failures | 4/mo | 0/mo |
| Developer self-service | No | Yes |
| Concurrent clone setup | 1 at a time | 10+ parallel |

---

## What's Next?

We've solved permissions, but our clones still have a critical flaw: **views, procedures, and streams still point to production**.

In Part 3, we'll tackle:
- Finding all hardcoded database references
- Repointing at scale with parallel processing
- Recreating streams with updated references
- Validation and health checks

---

**Next:** [Part 3: Repointing Database References →](03-repointing-streams.md)  
**Previous:** [Part 1: The Problem and the Promise](01-the-problem.md)  
**Code:** [sql/04_clone_rbac.sql](../../sql/04_clone_rbac.sql)

---

**About This Series**

This is Part 2 of a 4-part series on production-grade Snowflake database cloning. All code is available in the [GitHub repository](https://github.com/yourusername/snowflake_cloning) with complete documentation and examples.
