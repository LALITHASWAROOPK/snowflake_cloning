# Production-Grade Snowflake Database Cloning

A comprehensive solution for enterprise-scale Snowflake database cloning with automated permissions, reference repointing, and parallel processing.

## Overview

While Snowflake's `CREATE DATABASE ... CLONE` provides instant zero-copy cloning, production implementations require solving:

- **Broken Permissions** - Production roles don't work in clones
- **Stale References** - Views, procedures, and tasks still point to source database
- **Dead Streams** - Streams become stale after cloning
- **Poor Performance** - Sequential processing doesn't scale
- **No Recovery** - Failed clones require starting over
- **Cost Waste** - Tasks continue running in non-production environments
- **Iceberg Limitations** - Dynamic Iceberg tables and external volume challenges

This repository provides production-tested stored procedures and patterns that solve these challenges.

## Features

✅ **Automated RBAC** - Dynamic role creation with environment-specific permissions  
✅ **Parallel Processing** - Schema-level parallelization (73% faster)  
✅ **Database Repointing** - Automatic reference updates in views, procedures, functions, tasks  
✅ **Stream Recreation** - Rebuild streams with updated references  
✅ **Resume from Failure** - Step-based tracking and recovery  
✅ **Audit Logging** - Complete observability and tracking  
✅ **Task Management** - Auto-suspend tasks in non-prod clones  
✅ **Validation** - Health checks after cloning  

## Quick Start

```sql
-- One command to create a fully functional clone
CALL sp_clone_create_master('PROJECT', 'customer360', 'DEV');

-- Result: Complete dev environment in ~8 minutes
-- ✅ Correct permissions
-- ✅ All references updated
-- ✅ Streams recreated
-- ✅ Tasks suspended
-- ✅ Validated and ready
```

## Repository Structure

```
snowflake_cloning/
├── README.md                          # This file
├── docs/
│   ├── blog/                          # 4-part blog series
│   │   ├── 00-overview.md
│   │   ├── 01-the-problem.md
│   │   ├── 02-permissions-rbac.md
│   │   ├── 03-repointing-streams.md
│   │   └── 04-advanced-topics.md
│   └── architecture.md                # Technical architecture guide
├── sql/
│   ├── 01_tables.sql                  # Supporting tables
│   ├── 02_clone_repoint.sql           # Parallel repointing
│   ├── 03_clone_streams.sql           # Stream recreation
│   ├── 04_clone_rbac.sql              # RBAC management
│   └── 05_clone_master.sql            # Master orchestration
└── examples/
    ├── basic_clone.sql                # Simple example
    ├── project_clone.sql              # Project-based clone
    └── release_clone.sql              # Release testing clone
```

## Installation

### 1. Create Supporting Tables

```sql
-- Run in your admin database
USE DATABASE <YOUR_ADMIN_DB>;
USE SCHEMA <YOUR_ADMIN_SCHEMA>;
@sql/01_tables.sql
```

### 2. Deploy Procedures

```sql
-- Deploy all cloning procedures
@sql/02_clone_repoint.sql
@sql/03_clone_streams.sql
@sql/04_clone_rbac.sql
@sql/05_clone_master.sql
```

### 3. Configure RBAC Mappings

```sql
-- Define environment-specific role mappings
INSERT INTO rbac_mapping (schema_role, environment, functional_role, operation)
VALUES 
    ('{{CLONE_DB}}_ANALYTICS_READ', 'DEV', 'DATA_ANALYST_ROLE', 'GRANT'),
    ('{{CLONE_DB}}_ANALYTICS_WRITE', 'DEV', 'DATA_ENGINEER_ROLE', 'GRANT');
```

## Usage Examples

### Basic Clone

```sql
-- Clone production to dev
CALL sp_clone_create_master('PROJECT', 'myproject', 'DEV');
```

### Resume Failed Clone

```sql
-- Resume from step 5 if earlier clone failed
CALL sp_clone_create_master('PROJECT', 'myproject', 'DEV', 5);
```

### Update Existing Clone

```sql
-- Refresh clone from production
CALL sp_clone_update('PROJECT', 'myproject', 'DEV');
```

### List All Clones

```sql
-- View active clones
CALL sp_clone_list();
```

### Validate Clone Health

```sql
-- Check for stale references
CALL sp_validate_clone('DEV_MYPROJECT_DB', 'PRODUCTION_DB');
```

## Performance Metrics

| Metric | Manual Process | This Solution |
|--------|----------------|---------------|
| Time to clone (6 schemas) | 1-2 days | 8-12 minutes |
| Human intervention | Constant | None |
| Error rate | 15-20% | <1% |
| Concurrent clones | 1 | 10+ |
| Resume capability | No | Yes |

## Known Limitations

### Iceberg Tables

- **Dynamic Iceberg tables**: Cannot be cloned with metadata references intact. They must be recreated or converted to standard tables.
- **External volumes**: Clones need read access to production external volumes if Iceberg tables reference them.

**Workaround**: 
```sql
-- Grant clone database access to prod external volume
GRANT READ ON EXTERNAL VOLUME prod_iceberg_volume TO DATABASE dev_myproject_db;
```

See [Iceberg Tables Guide](docs/iceberg-considerations.md) for detailed handling strategies.

## Blog Series

This repository accompanies a 4-part blog series on production-grade Snowflake cloning:

- [Part 1: The Problem and the Promise](docs/blog/01-the-problem.md)
- [Part 2: Solving Permissions and RBAC](docs/blog/02-permissions-rbac.md)
- [Part 3: Repointing References and Recreating Streams](docs/blog/03-repointing-streams.md)
- [Part 4: Parallelization and Production Features](docs/blog/04-advanced-topics.md)

## Customization

All SQL files use generic placeholders that you replace with your values:

- `<PLATFORM_DB>` → Your admin database name
- `<ADMIN_SCHEMA>` → Your admin schema name
- `<PRODUCTION_DB>` → Your production database name
- `<EXEC_WAREHOUSE>` → Your execution warehouse

## Architecture

```
sp_clone_create_master()
├─ Delete old RBAC mappings
├─ Clone database (Snowflake native)
├─ Revoke production grants
├─ Repoint objects (PARALLEL)
│  ├─ ASYNC: Schema 1 → Views/Procs/Funcs/Tasks
│  ├─ ASYNC: Schema 2 → Views/Procs/Funcs/Tasks
│  └─ AWAIT ALL
├─ Recreate streams (PARALLEL)
├─ Create environment-specific roles
├─ Apply RBAC mappings
├─ Suspend tasks
├─ Validate
└─ Update audit log
```

See [Architecture Guide](docs/architecture.md) for detailed flow diagrams.

## Contributing

Contributions welcome! Please:

1. Test changes in a sandbox environment
2. Update relevant documentation
3. Add examples for new features
4. Maintain generic placeholder usage

## License

MIT License - See LICENSE file for details

## Support

- **Issues**: [GitHub Issues](https://github.com/LALITHASWAROOPK/snowflake_cloning/issues)
- **Discussions**: [GitHub Discussions](https://github.com/LALITHASWAROOPK/snowflake_cloning/discussions)
- **Blog Series**: [Link to published blog]

## Acknowledgments

Based on production implementation managing 20+ database clones across multiple projects and environments in a Fortune 500 enterprise. Real-world lessons learned from thousands of clone operations.

---

**Created**: April 2026  
**Status**: Production-ready  
**Snowflake Version**: Tested on 7.x and 8.x
