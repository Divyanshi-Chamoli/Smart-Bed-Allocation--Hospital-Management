-- ORACLE DATABASE ROLES
-- Second layer of role enforcement: what each kind of Oracle login may touch at all.
-- No role gets INSERT/UPDATE/DELETE on tables; all changes go through the packages,
-- which check the application role again with pkg_security.assert_role.
-- Run as the schema owner (needs CREATE ROLE).

DECLARE
    PROCEDURE create_role (p_role IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE ROLE ' || p_role;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE <> -1921 THEN RAISE; END IF;  -- role already exists
    END;
BEGIN
    create_role('HMS_ADMIN');
    create_role('HMS_DOCTOR');
    create_role('HMS_NURSE');
    create_role('HMS_LAB');
    create_role('HMS_BILLING');
END;
/

-- Every role can sign in and check its own identity
GRANT EXECUTE ON pkg_security TO HMS_ADMIN, HMS_DOCTOR, HMS_NURSE, HMS_LAB, HMS_BILLING;
GRANT EXECUTE ON pkg_admin TO HMS_ADMIN, HMS_DOCTOR, HMS_NURSE, HMS_LAB, HMS_BILLING;  -- password change; other procedures re-check the role

-- ADMIN: everything
GRANT EXECUTE ON pkg_bed_allocation TO HMS_ADMIN;
GRANT EXECUTE ON pkg_lab TO HMS_ADMIN;
GRANT EXECUTE ON pkg_billing TO HMS_ADMIN;
GRANT EXECUTE ON admit_patient TO HMS_ADMIN;
GRANT EXECUTE ON discharge_patient TO HMS_ADMIN;
BEGIN
    FOR t IN (SELECT object_name FROM user_objects WHERE object_type IN ('TABLE','VIEW')) LOOP
        EXECUTE IMMEDIATE 'GRANT SELECT ON ' || t.object_name || ' TO HMS_ADMIN';
    END LOOP;
END;
/

-- DOCTOR: patients, admissions, queue, discharge, read lab results
GRANT EXECUTE ON pkg_bed_allocation TO HMS_DOCTOR;
GRANT EXECUTE ON admit_patient TO HMS_DOCTOR;
GRANT EXECUTE ON discharge_patient TO HMS_DOCTOR;
GRANT SELECT ON patient TO HMS_DOCTOR;
GRANT SELECT ON staff TO HMS_DOCTOR;
GRANT SELECT ON ward TO HMS_DOCTOR;
GRANT SELECT ON urgency_level TO HMS_DOCTOR;
GRANT SELECT ON v_bed_occupancy TO HMS_DOCTOR;
GRANT SELECT ON v_bed_board TO HMS_DOCTOR;
GRANT SELECT ON v_current_admissions TO HMS_DOCTOR;
GRANT SELECT ON v_waiting_queue_ranked TO HMS_DOCTOR;
GRANT SELECT ON v_lab_results_detail TO HMS_DOCTOR;
GRANT SELECT ON v_patient_history TO HMS_DOCTOR;
GRANT SELECT ON v_doctor_workload TO HMS_DOCTOR;
GRANT SELECT ON v_blocked_capacity TO HMS_DOCTOR;
GRANT SELECT ON v_beds_blocking_queue TO HMS_DOCTOR;
GRANT SELECT ON v_ward_turnaround TO HMS_DOCTOR;
-- Doctors and nurses order/cancel lab tests; completing an order re-checks the role inside pkg_lab
GRANT EXECUTE ON pkg_lab TO HMS_DOCTOR;
GRANT SELECT ON v_lab_orders TO HMS_DOCTOR;

-- NURSE: patients, admission requests, queue, bed maintenance
GRANT EXECUTE ON pkg_bed_allocation TO HMS_NURSE;
GRANT SELECT ON patient TO HMS_NURSE;
GRANT SELECT ON staff TO HMS_NURSE;
GRANT SELECT ON ward TO HMS_NURSE;
GRANT SELECT ON urgency_level TO HMS_NURSE;
GRANT SELECT ON v_bed_occupancy TO HMS_NURSE;
GRANT SELECT ON v_bed_board TO HMS_NURSE;
GRANT SELECT ON v_current_admissions TO HMS_NURSE;
GRANT SELECT ON v_waiting_queue_ranked TO HMS_NURSE;
GRANT SELECT ON v_blocked_capacity TO HMS_NURSE;
GRANT SELECT ON v_beds_blocking_queue TO HMS_NURSE;
GRANT SELECT ON v_ward_turnaround TO HMS_NURSE;
GRANT SELECT ON v_bed_turnaround TO HMS_NURSE;
GRANT EXECUTE ON pkg_lab TO HMS_NURSE;
GRANT SELECT ON v_lab_orders TO HMS_NURSE;

-- LAB STAFF: record and read results
GRANT EXECUTE ON pkg_lab TO HMS_LAB;
GRANT SELECT ON lab_test TO HMS_LAB;
GRANT SELECT ON v_current_admissions TO HMS_LAB;
GRANT SELECT ON v_lab_results_detail TO HMS_LAB;
GRANT SELECT ON v_lab_orders TO HMS_LAB;

-- BILLING STAFF: bills, items, payments
GRANT EXECUTE ON pkg_billing TO HMS_BILLING;
GRANT SELECT ON bill TO HMS_BILLING;
GRANT SELECT ON bill_item TO HMS_BILLING;
GRANT SELECT ON ward_tariff TO HMS_BILLING;
GRANT SELECT ON v_bill_summary TO HMS_BILLING;
GRANT SELECT ON v_unpaid_bills TO HMS_BILLING;
GRANT SELECT ON v_admissions_to_bill TO HMS_BILLING;


-- OPTIONAL: real Oracle logins per person (run the CREATE USER lines as SYSTEM, then the
-- GRANT/UPDATE lines as the schema owner). pkg_security maps them to their app account
-- through user_account.db_username, so they cannot pretend to be someone else.
--
--   CREATE USER hms_rahul IDENTIFIED BY "Rahul#2026";
--   GRANT CREATE SESSION TO hms_rahul;
--   GRANT HMS_DOCTOR TO hms_rahul;
--   UPDATE user_account SET db_username = 'HMS_RAHUL' WHERE username = 'rahul';
--   COMMIT;
--
-- hms_rahul can then run e.g.  EXEC hms.discharge_patient(1)  but not  SELECT * FROM hms.bill
