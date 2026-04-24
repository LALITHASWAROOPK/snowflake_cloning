-- ============================================================================
-- RBAC Management for Cloned Databases
-- Database: <PLATFORM_DB>.<ADMIN_SCHEMA>
-- ============================================================================
-- Complete RBAC management procedures for automated permission provisioning
-- in cloned Snowflake databases.
-- ============================================================================

-- sp_grant_temp_ownership: Grants temporary ownership to service role
-- sp_revoke_prod_grants: Removes production-specific grants
-- sp_create_clone_roles: Creates environment-specific roles dynamically
-- sp_apply_rbac_mapping: Applies configuration-driven role mappings
-- sp_setup_clone_permissions: Orchestrates full permission setup

-- Full implementations available in GitHub repository
-- Procedures use placeholders: <PLATFORM_DB>, <ADMIN_SCHEMA>, <PRODUCTION_DB>

-- Usage Example:
-- CALL sp_setup_clone_permissions('DEV_PROJECT_DB', 'PRODUCTION_DB', 'DEV');
