-- MASTER INSTALL SCRIPT
-- Usage (from this folder):  sqlplus hms/hms123@localhost/XEPDB1 @install.sql
-- For a clean reinstall run  @sql/99_drop_all.sql  first.

SET DEFINE OFF
SET SERVEROUTPUT ON
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT == Base schema
@@hospitalmanagement.sql
@@createseq.sql

PROMPT == Base data
@@INSERTION/createroles.sql
@@INSERTION/insert_staff.sql
@@INSERTION/insert_user.sql
@@INSERTION/insert_wards.sql
@@INSERTION/insert_beds.sql
@@INSERTION/insert_patients.sql
@@INSERTION/insert_labtests.sql
COMMIT;

PROMPT == Allocation extension: tables, indexes
@@sql/10_allocation_schema.sql
@@sql/12_bed_turnaround_schema.sql

PROMPT == Triggers
@@sql/20_triggers.sql

PROMPT == Allocation rules and demo data
@@sql/25_seed_allocation.sql
@@sql/27_seed_turnaround.sql

PROMPT == Packages
@@sql/30_pkg_security.sql
@@sql/40_pkg_bed_allocation.sql
@@sql/50_pkg_clinical_billing.sql
@@procedures.sql

PROMPT == Views
@@sql/60_views.sql
@@sql/62_turnaround_views.sql

PROMPT == Database roles
@@sql/70_db_roles.sql

WHENEVER SQLERROR CONTINUE
EXEC DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE);

SET FEEDBACK ON
PROMPT == Invalid objects (should be none):
SELECT object_type, object_name FROM user_objects WHERE status = 'INVALID';

PROMPT == Compilation errors (should be none):
SELECT name, type, line, text FROM user_errors ORDER BY name, sequence;

PROMPT == Install complete
