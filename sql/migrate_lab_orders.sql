-- MIGRATION: add lab test ordering to an existing database
-- Usage (from the project folder):  sqlplus hms/hms123@localhost/XEPDB1 @sql/migrate_lab_orders.sql
-- Run migrate_bed_turnaround.sql first if that has not been applied yet.
-- Every step is safe to re-run. Existing rows are kept.

SET DEFINE OFF
SET SERVEROUTPUT ON
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT == Lab order table
@@14_lab_orders_schema.sql

PROMPT == Triggers
@@20_triggers.sql

PROMPT == Packages (discharge cancels open orders; pkg_lab ordering procedures)
@@40_pkg_bed_allocation.sql
@@50_pkg_clinical_billing.sql

PROMPT == Views
@@60_views.sql
@@62_turnaround_views.sql

PROMPT == Database roles
@@70_db_roles.sql

WHENEVER SQLERROR CONTINUE
EXEC DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE);

SET FEEDBACK ON
PROMPT == Invalid objects (should be none):
SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID';

PROMPT == Compilation errors (should be none):
SELECT name, type, line, text FROM user_errors ORDER BY name, sequence;

PROMPT == Migration complete
