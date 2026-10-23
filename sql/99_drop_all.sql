-- DROPS EVERY OBJECT CREATED BY install.sql (tables, data, sequences, packages, views, roles)
-- Usage: sqlplus hms/hms123@localhost/XEPDB1 @sql/99_drop_all.sql

SET SERVEROUTPUT ON

BEGIN
    FOR o IN (
        SELECT object_type, object_name
        FROM user_objects
        WHERE object_type IN ('VIEW','PACKAGE','PROCEDURE','FUNCTION','SEQUENCE')
        AND object_name IN (
            'V_BED_OCCUPANCY','V_BED_BOARD','V_CURRENT_ADMISSIONS','V_WAITING_QUEUE_RANKED',
            'V_UNPAID_BILLS','V_BILL_SUMMARY','V_ADMISSIONS_TO_BILL','V_LAB_RESULTS_DETAIL',
            'V_DOCTOR_WORKLOAD','V_ALLOCATION_HISTORY','V_QUEUE_WAIT_STATS','V_PATIENT_HISTORY',
            'V_USER_ACCOUNTS','V_BED_STATUS_SINCE','V_BED_TURNAROUND','V_WARD_TURNAROUND',
            'V_BLOCKED_CAPACITY','V_BEDS_BLOCKING_QUEUE',
            'PKG_SECURITY','PKG_BED_ALLOCATION','PKG_ADMIN','PKG_LAB','PKG_BILLING',
            'ADMIT_PATIENT','DISCHARGE_PATIENT',
            'PATIENT_SEQ','STAFF_SEQ','WARD_SEQ','BED_SEQ','ADMISSION_SEQ','LAB_TEST_SEQ',
            'LAB_RESULT_SEQ','BILL_SEQ','BILL_ITEM_SEQ','ROLE_SEQ','USER_SEQ',
            'WARD_RULE_SEQ','QUEUE_SEQ','ALLOC_LOG_SEQ','BED_HISTORY_SEQ')
    ) LOOP
        EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' ' || o.object_name;
    END LOOP;

    FOR t IN (
        SELECT table_name
        FROM user_tables
        WHERE table_name IN (
            'BED_STATUS_HISTORY','BED_ALLOCATION_LOG','WAITING_QUEUE','WARD_TARIFF','ALLOCATION_CONFIG',
            'WARD_COMPATIBILITY','URGENCY_LEVEL',
            'BILL_ITEM','BILL','LAB_RESULT','LAB_TEST','ADMISSION','BED','WARD',
            'USER_ACCOUNT','ROLE','STAFF','PATIENT')
    ) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
    END LOOP;
END;
/

-- The creator of a role is granted it automatically, so the owner's role list finds them
BEGIN
    FOR r IN (SELECT granted_role FROM user_role_privs
              WHERE granted_role IN ('HMS_ADMIN','HMS_DOCTOR','HMS_NURSE','HMS_LAB','HMS_BILLING')) LOOP
        EXECUTE IMMEDIATE 'DROP ROLE ' || r.granted_role;
    END LOOP;
END;
/

PROMPT == Hospital schema objects dropped
