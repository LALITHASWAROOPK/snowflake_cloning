-- ============================================================================
-- Master Clone Orchestration Procedure
-- Database: <PLATFORM_DB>.<ADMIN_SCHEMA>
-- ============================================================================
-- Complete production-grade clone creation with:
-- - Permission management
-- - Parallel repointing
-- - Stream recreation
-- - Task suspension
-- - Iceberg table handling
-- - Step-based tracking and resume-from-failure
-- ============================================================================

-- sp_clone_create_master: Main orchestration procedure
-- sp_clone_update: Drop and recreate clone (refresh)
-- sp_clone_drop: Remove clone and cleanup RBAC
-- sp_clone_list: View all active clones
-- sp_validate_clone: Health check after cloning

-- Full implementations available in GitHub repository

-- Usage Examples:

-- Create new clone
-- CALL sp_clone_create_master('PROJECT', 'customer360', 'DEV');

-- Resume from failure at step 5
-- CALL sp_clone_create_master('PROJECT', 'customer360', 'DEV', 5);

-- Refresh existing clone
-- CALL sp_clone_update('PROJECT', 'customer360', 'DEV');

-- List all clones
-- CALL sp_clone_list();

-- Validate clone health
-- CALL sp_validate_clone('DEV_CUSTOMER360_DB', 'PRODUCTION_DB');
