-- MIGRATION: add bed turnaround tracking to an existing database
-- Usage (from the project folder):  sqlplus hms/hms123@localhost/XEPDB1 @sql/migrate_bed_turnaround.sql
-- Every step is safe to re-run. Existing rows are kept; no bed states or admissions are changed.

SET DEFINE OFF
SET SERVEROUTPUT ON
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT == New bed states and status history table
@@12_bed_turnaround_schema.sql

PROMPT == Triggers (bed life cycle guard + history)
@@20_triggers.sql

PROMPT == Targets and backdated turnaround history
@@27_seed_turnaround.sql

PROMPT == Allocation package (procedures.sql wrappers are unchanged; COMPILE_SCHEMA below revalidates them)
@@40_pkg_bed_allocation.sql

PROMPT == Views
@@60_views.sql
@@62_turnaround_views.sql

PROMPT == Database roles
@@70_db_roles.sql

WHENEVER SQLERROR CONTINUE
EXEC DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE);

SET FEEDBACK ON
PROMPT == Bed status constraint (expect CK_BED_STATUS only):
SELECT uc.constraint_name, uc.search_condition_vc
FROM user_constraints uc
JOIN user_cons_columns cc ON cc.constraint_name = uc.constraint_name
WHERE uc.table_name = 'BED' AND uc.constraint_type = 'C' AND cc.column_name = 'BED_STATUS'
AND uc.search_condition_vc LIKE '%IN%';

PROMPT == Invalid objects (should be none):
SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID';

PROMPT == Compilation errors (should be none):
SELECT name, type, line, text FROM user_errors ORDER BY name, sequence;

PROMPT == Migration complete
