-- ADMINISTRATION, LABORATORY AND BILLING PACKAGES
-- Every write goes through these procedures so pkg_security can enforce roles in the database.


-- ==================================================================== pkg_admin

CREATE OR REPLACE PACKAGE pkg_admin AS

    PROCEDURE add_patient (
        p_first_name IN VARCHAR2, p_last_name IN VARCHAR2, p_dob IN DATE, p_gender IN VARCHAR2,
        p_phone IN VARCHAR2, p_address IN VARCHAR2, p_blood_group IN VARCHAR2,
        p_patient_id OUT NUMBER);

    PROCEDURE update_patient (
        p_patient_id IN NUMBER, p_first_name IN VARCHAR2, p_last_name IN VARCHAR2, p_dob IN DATE,
        p_gender IN VARCHAR2, p_phone IN VARCHAR2, p_address IN VARCHAR2, p_blood_group IN VARCHAR2);

    PROCEDURE add_staff (
        p_staff_name IN VARCHAR2, p_designation IN VARCHAR2, p_department IN VARCHAR2,
        p_phone IN VARCHAR2, p_email IN VARCHAR2, p_staff_id OUT NUMBER);

    PROCEDURE update_staff (
        p_staff_id IN NUMBER, p_staff_name IN VARCHAR2, p_designation IN VARCHAR2,
        p_department IN VARCHAR2, p_phone IN VARCHAR2, p_email IN VARCHAR2);

    PROCEDURE add_ward (
        p_ward_name IN VARCHAR2, p_ward_type IN VARCHAR2, p_floor_no IN NUMBER,
        p_capacity IN NUMBER, p_reserved_critical IN NUMBER, p_ward_id OUT NUMBER);

    PROCEDURE add_bed (p_ward_id IN NUMBER, p_bed_number IN VARCHAR2, p_bed_id OUT NUMBER);

    PROCEDURE add_lab_test (p_test_name IN VARCHAR2, p_test_cost IN NUMBER, p_test_id OUT NUMBER);

    PROCEDURE update_lab_test (p_test_id IN NUMBER, p_test_name IN VARCHAR2, p_test_cost IN NUMBER);

    PROCEDURE create_user (
        p_staff_id IN NUMBER, p_role_name IN VARCHAR2, p_username IN VARCHAR2,
        p_password IN VARCHAR2, p_user_id OUT NUMBER);

    PROCEDURE set_user_role (p_user_id IN NUMBER, p_role_name IN VARCHAR2);

    PROCEDURE set_user_status (p_user_id IN NUMBER, p_status IN VARCHAR2);

    PROCEDURE reset_password (p_user_id IN NUMBER, p_new_password IN VARCHAR2);

    PROCEDURE change_own_password (p_old_password IN VARCHAR2, p_new_password IN VARCHAR2);

    PROCEDURE set_config (p_key IN VARCHAR2, p_value IN NUMBER);

    PROCEDURE save_ward_rule (
        p_rule_id IN NUMBER, p_required_type IN VARCHAR2, p_allowed_type IN VARCHAR2,
        p_rank IN NUMBER, p_min_urgency_weight IN NUMBER, p_description IN VARCHAR2,
        p_is_active IN VARCHAR2);

    PROCEDURE set_ward_tariff (p_ward_type IN VARCHAR2, p_daily_rate IN NUMBER);

END pkg_admin;
/

CREATE OR REPLACE PACKAGE BODY pkg_admin AS

    FUNCTION role_id_of (p_role_name IN VARCHAR2) RETURN NUMBER IS
        v_role_id role.role_id%TYPE;
    BEGIN
        SELECT role_id INTO v_role_id FROM role WHERE role_name = UPPER(p_role_name);
        RETURN v_role_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20050, 'Role ' || p_role_name || ' does not exist');
    END role_id_of;


    PROCEDURE check_found (p_rowcount IN NUMBER, p_what IN VARCHAR2) IS
    BEGIN
        IF p_rowcount = 0 THEN
            RAISE_APPLICATION_ERROR(-20051, p_what || ' does not exist');
        END IF;
    END check_found;


    PROCEDURE check_password (p_password IN VARCHAR2) IS
    BEGIN
        IF p_password IS NULL OR LENGTH(p_password) < 6 THEN
            RAISE_APPLICATION_ERROR(-20052, 'Password must be at least 6 characters');
        END IF;
    END check_password;


    PROCEDURE add_patient (
        p_first_name IN VARCHAR2, p_last_name IN VARCHAR2, p_dob IN DATE, p_gender IN VARCHAR2,
        p_phone IN VARCHAR2, p_address IN VARCHAR2, p_blood_group IN VARCHAR2,
        p_patient_id OUT NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        IF p_dob > SYSDATE THEN
            RAISE_APPLICATION_ERROR(-20053, 'Date of birth cannot be in the future');
        END IF;

        INSERT INTO patient (first_name, last_name, dob, gender, phone, address, blood_group)
        VALUES (p_first_name, p_last_name, p_dob, p_gender, p_phone, p_address, p_blood_group)
        RETURNING patient_id INTO p_patient_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END add_patient;


    PROCEDURE update_patient (
        p_patient_id IN NUMBER, p_first_name IN VARCHAR2, p_last_name IN VARCHAR2, p_dob IN DATE,
        p_gender IN VARCHAR2, p_phone IN VARCHAR2, p_address IN VARCHAR2, p_blood_group IN VARCHAR2) IS
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        IF p_dob > SYSDATE THEN
            RAISE_APPLICATION_ERROR(-20053, 'Date of birth cannot be in the future');
        END IF;

        UPDATE patient
        SET first_name = p_first_name, last_name = p_last_name, dob = p_dob, gender = p_gender,
            phone = p_phone, address = p_address, blood_group = p_blood_group
        WHERE patient_id = p_patient_id;
        check_found(SQL%ROWCOUNT, 'Patient');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END update_patient;


    PROCEDURE add_staff (
        p_staff_name IN VARCHAR2, p_designation IN VARCHAR2, p_department IN VARCHAR2,
        p_phone IN VARCHAR2, p_email IN VARCHAR2, p_staff_id OUT NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        INSERT INTO staff (staff_name, designation, department, phone, email)
        VALUES (p_staff_name, p_designation, p_department, p_phone, LOWER(p_email))
        RETURNING staff_id INTO p_staff_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END add_staff;


    PROCEDURE update_staff (
        p_staff_id IN NUMBER, p_staff_name IN VARCHAR2, p_designation IN VARCHAR2,
        p_department IN VARCHAR2, p_phone IN VARCHAR2, p_email IN VARCHAR2) IS
        v_active NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN');

        -- A doctor with patients in beds cannot stop being a doctor
        IF p_designation <> 'Doctor' THEN
            SELECT COUNT(*) INTO v_active
            FROM admission
            WHERE doctor_id = p_staff_id AND admission_status = 'ADMITTED';

            IF v_active > 0 THEN
                RAISE_APPLICATION_ERROR(-20054, 'Staff member is the doctor for ' || v_active
                    || ' current admission(s); designation must stay Doctor');
            END IF;
        END IF;

        UPDATE staff
        SET staff_name = p_staff_name, designation = p_designation, department = p_department,
            phone = p_phone, email = LOWER(p_email)
        WHERE staff_id = p_staff_id;
        check_found(SQL%ROWCOUNT, 'Staff member');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END update_staff;


    PROCEDURE add_ward (
        p_ward_name IN VARCHAR2, p_ward_type IN VARCHAR2, p_floor_no IN NUMBER,
        p_capacity IN NUMBER, p_reserved_critical IN NUMBER, p_ward_id OUT NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        INSERT INTO ward (ward_name, ward_type, floor_no, capacity, reserved_critical_beds)
        VALUES (p_ward_name, p_ward_type, p_floor_no, p_capacity, NVL(p_reserved_critical, 0))
        RETURNING ward_id INTO p_ward_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END add_ward;


    PROCEDURE add_bed (p_ward_id IN NUMBER, p_bed_number IN VARCHAR2, p_bed_id OUT NUMBER) IS
        v_capacity ward.capacity%TYPE;
        v_beds NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN');

        BEGIN
            SELECT capacity INTO v_capacity FROM ward WHERE ward_id = p_ward_id FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20055, 'Ward does not exist');
        END;

        SELECT COUNT(*) INTO v_beds FROM bed WHERE ward_id = p_ward_id;
        IF v_beds >= v_capacity THEN
            RAISE_APPLICATION_ERROR(-20056, 'Ward is at its capacity of ' || v_capacity || ' beds');
        END IF;

        INSERT INTO bed (ward_id, bed_number, bed_status)
        VALUES (p_ward_id, UPPER(p_bed_number), 'AVAILABLE')
        RETURNING bed_id INTO p_bed_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END add_bed;


    PROCEDURE add_lab_test (p_test_name IN VARCHAR2, p_test_cost IN NUMBER, p_test_id OUT NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        INSERT INTO lab_test (test_name, test_cost)
        VALUES (p_test_name, p_test_cost)
        RETURNING test_id INTO p_test_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END add_lab_test;


    PROCEDURE update_lab_test (p_test_id IN NUMBER, p_test_name IN VARCHAR2, p_test_cost IN NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        UPDATE lab_test
        SET test_name = p_test_name, test_cost = p_test_cost
        WHERE test_id = p_test_id;
        check_found(SQL%ROWCOUNT, 'Lab test');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END update_lab_test;


    PROCEDURE create_user (
        p_staff_id IN NUMBER, p_role_name IN VARCHAR2, p_username IN VARCHAR2,
        p_password IN VARCHAR2, p_user_id OUT NUMBER) IS
        v_role_id role.role_id%TYPE;
    BEGIN
        pkg_security.assert_role('ADMIN');
        check_password(p_password);
        v_role_id := role_id_of(p_role_name);

        INSERT INTO user_account (staff_id, role_id, username, password, account_status)
        VALUES (p_staff_id, v_role_id, LOWER(TRIM(p_username)), p_password, 'ACTIVE')
        RETURNING user_id INTO p_user_id;
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20057,
                'Username is taken or this staff member already has an account');
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END create_user;


    PROCEDURE set_user_role (p_user_id IN NUMBER, p_role_name IN VARCHAR2) IS
        v_role_id role.role_id%TYPE;
    BEGIN
        pkg_security.assert_role('ADMIN');

        IF p_user_id = pkg_security.current_user_id AND UPPER(p_role_name) <> 'ADMIN' THEN
            RAISE_APPLICATION_ERROR(-20058, 'You cannot remove your own ADMIN role');
        END IF;

        v_role_id := role_id_of(p_role_name);
        UPDATE user_account SET role_id = v_role_id WHERE user_id = p_user_id;
        check_found(SQL%ROWCOUNT, 'User account');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END set_user_role;


    PROCEDURE set_user_status (p_user_id IN NUMBER, p_status IN VARCHAR2) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        IF p_user_id = pkg_security.current_user_id AND p_status <> 'ACTIVE' THEN
            RAISE_APPLICATION_ERROR(-20058, 'You cannot deactivate your own account');
        END IF;

        UPDATE user_account SET account_status = p_status WHERE user_id = p_user_id;
        check_found(SQL%ROWCOUNT, 'User account');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END set_user_status;


    PROCEDURE reset_password (p_user_id IN NUMBER, p_new_password IN VARCHAR2) IS
    BEGIN
        pkg_security.assert_role('ADMIN');
        check_password(p_new_password);

        UPDATE user_account SET password = p_new_password WHERE user_id = p_user_id;
        check_found(SQL%ROWCOUNT, 'User account');
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END reset_password;


    PROCEDURE change_own_password (p_old_password IN VARCHAR2, p_new_password IN VARCHAR2) IS
        v_user_id user_account.user_id%TYPE;
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE,LAB_STAFF,BILLING_STAFF');
        check_password(p_new_password);

        IF pkg_security.authenticate(pkg_security.current_username, p_old_password) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20059, 'Current password is incorrect');
        END IF;

        -- Look the id up first: calling a function that reads user_account inside the UPDATE
        -- would raise ORA-04091 (mutating table) via the password trigger
        v_user_id := pkg_security.current_user_id;
        UPDATE user_account SET password = p_new_password WHERE user_id = v_user_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END change_own_password;


    PROCEDURE set_config (p_key IN VARCHAR2, p_value IN NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        UPDATE allocation_config SET config_value = p_value WHERE config_key = p_key;
        check_found(SQL%ROWCOUNT, 'Config key ' || p_key);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END set_config;


    PROCEDURE save_ward_rule (
        p_rule_id IN NUMBER, p_required_type IN VARCHAR2, p_allowed_type IN VARCHAR2,
        p_rank IN NUMBER, p_min_urgency_weight IN NUMBER, p_description IN VARCHAR2,
        p_is_active IN VARCHAR2) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        IF p_rule_id IS NULL THEN
            INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank,
                                            min_urgency_weight, rule_description, is_active)
            VALUES (p_required_type, p_allowed_type, p_rank, p_min_urgency_weight,
                    p_description, NVL(p_is_active, 'Y'));
        ELSE
            UPDATE ward_compatibility
            SET required_ward_type = p_required_type, allowed_ward_type = p_allowed_type,
                preference_rank = p_rank, min_urgency_weight = p_min_urgency_weight,
                rule_description = p_description, is_active = NVL(p_is_active, 'Y')
            WHERE rule_id = p_rule_id;
            check_found(SQL%ROWCOUNT, 'Allocation rule');
        END IF;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END save_ward_rule;


    PROCEDURE set_ward_tariff (p_ward_type IN VARCHAR2, p_daily_rate IN NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN');

        MERGE INTO ward_tariff t
        USING (SELECT p_ward_type AS ward_type, p_daily_rate AS daily_rate FROM dual) s
        ON (t.ward_type = s.ward_type)
        WHEN MATCHED THEN UPDATE SET t.daily_rate = s.daily_rate
        WHEN NOT MATCHED THEN INSERT (ward_type, daily_rate) VALUES (s.ward_type, s.daily_rate);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END set_ward_tariff;

END pkg_admin;
/


-- ==================================================================== pkg_lab

CREATE OR REPLACE PACKAGE pkg_lab AS

    -- Result for a test that was not ordered through the system (walk-in / verbal request)
    PROCEDURE record_result (
        p_admission_id IN NUMBER,
        p_test_id IN NUMBER,
        p_result_value IN VARCHAR2,
        p_remarks IN VARCHAR2,
        p_result_id OUT NUMBER
    );

    -- Doctor or nurse orders a test for an admitted patient
    PROCEDURE order_test (
        p_admission_id IN NUMBER,
        p_test_id IN NUMBER,
        p_priority IN VARCHAR2,
        p_notes IN VARCHAR2,
        p_order_id OUT NUMBER
    );

    PROCEDURE cancel_order (p_order_id IN NUMBER, p_reason IN VARCHAR2);

    -- Lab enters the result of an open order
    PROCEDURE complete_order (
        p_order_id IN NUMBER,
        p_result_value IN VARCHAR2,
        p_remarks IN VARCHAR2,
        p_result_id OUT NUMBER
    );

END pkg_lab;
/

CREATE OR REPLACE PACKAGE BODY pkg_lab AS

    PROCEDURE check_current_admission (p_admission_id IN NUMBER, p_error_code IN NUMBER, p_action IN VARCHAR2) IS
        v_status admission.admission_status%TYPE;
    BEGIN
        BEGIN
            SELECT admission_status INTO v_status FROM admission WHERE admission_id = p_admission_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20006, 'Admission does not exist');
        END;

        IF v_status <> 'ADMITTED' THEN
            RAISE_APPLICATION_ERROR(p_error_code, p_action || ' only for a current admission (this one is '
                || v_status || ')');
        END IF;
    END check_current_admission;


    PROCEDURE check_test (p_test_id IN NUMBER) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count FROM lab_test WHERE test_id = p_test_id;
        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20061, 'Lab test does not exist');
        END IF;
    END check_test;


    -- Shared by record_result and complete_order. Does not commit.
    FUNCTION insert_result (
        p_admission_id IN NUMBER,
        p_test_id IN NUMBER,
        p_result_value IN VARCHAR2,
        p_remarks IN VARCHAR2
    ) RETURN NUMBER IS
        v_result_id lab_result.result_id%TYPE;
    BEGIN
        check_current_admission(p_admission_id, -20060, 'Results can be recorded');
        check_test(p_test_id);

        INSERT INTO lab_result (admission_id, test_id, staff_id, test_date, result_value, remarks)
        VALUES (p_admission_id, p_test_id, pkg_security.current_staff_id, SYSDATE, p_result_value, p_remarks)
        RETURNING result_id INTO v_result_id;
        RETURN v_result_id;
    END insert_result;


    PROCEDURE record_result (
        p_admission_id IN NUMBER,
        p_test_id IN NUMBER,
        p_result_value IN VARCHAR2,
        p_remarks IN VARCHAR2,
        p_result_id OUT NUMBER
    ) IS
    BEGIN
        pkg_security.assert_role('ADMIN,LAB_STAFF');
        p_result_id := insert_result(p_admission_id, p_test_id, p_result_value, p_remarks);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END record_result;


    PROCEDURE order_test (
        p_admission_id IN NUMBER,
        p_test_id IN NUMBER,
        p_priority IN VARCHAR2,
        p_notes IN VARCHAR2,
        p_order_id OUT NUMBER
    ) IS
        v_priority lab_order.priority%TYPE := UPPER(NVL(p_priority, 'ROUTINE'));
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        IF v_priority NOT IN ('ROUTINE','URGENT') THEN
            RAISE_APPLICATION_ERROR(-20085, 'Priority must be ROUTINE or URGENT');
        END IF;
        check_current_admission(p_admission_id, -20080, 'Tests can be ordered');
        check_test(p_test_id);

        INSERT INTO lab_order (admission_id, test_id, ordered_by, ordered_at, priority, order_status, notes)
        VALUES (p_admission_id, p_test_id, pkg_security.current_staff_id, SYSDATE, v_priority, 'ORDERED', p_notes)
        RETURNING order_id INTO p_order_id;
        COMMIT;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20082, 'This test is already ordered for this admission and not yet done');
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END order_test;


    -- Locks an order and returns its status; raises if it does not exist
    FUNCTION lock_order (p_order_id IN NUMBER, p_admission_id OUT NUMBER, p_test_id OUT NUMBER) RETURN VARCHAR2 IS
        v_status lab_order.order_status%TYPE;
    BEGIN
        SELECT order_status, admission_id, test_id INTO v_status, p_admission_id, p_test_id
        FROM lab_order
        WHERE order_id = p_order_id
        FOR UPDATE;
        RETURN v_status;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20083, 'Lab order does not exist');
    END lock_order;


    PROCEDURE cancel_order (p_order_id IN NUMBER, p_reason IN VARCHAR2) IS
        v_status lab_order.order_status%TYPE;
        v_admission_id NUMBER;
        v_test_id NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        v_status := lock_order(p_order_id, v_admission_id, v_test_id);
        IF v_status <> 'ORDERED' THEN
            RAISE_APPLICATION_ERROR(-20084, 'Lab order ' || p_order_id || ' is already ' || v_status);
        END IF;

        UPDATE lab_order
        SET order_status = 'CANCELLED',
            cancel_reason = SUBSTR(NVL(p_reason, 'Cancelled by ' || pkg_security.current_username), 1, 200)
        WHERE order_id = p_order_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END cancel_order;


    PROCEDURE complete_order (
        p_order_id IN NUMBER,
        p_result_value IN VARCHAR2,
        p_remarks IN VARCHAR2,
        p_result_id OUT NUMBER
    ) IS
        v_status lab_order.order_status%TYPE;
        v_admission_id NUMBER;
        v_test_id NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN,LAB_STAFF');

        v_status := lock_order(p_order_id, v_admission_id, v_test_id);
        IF v_status <> 'ORDERED' THEN
            RAISE_APPLICATION_ERROR(-20084, 'Lab order ' || p_order_id || ' is already ' || v_status);
        END IF;

        p_result_id := insert_result(v_admission_id, v_test_id, p_result_value, p_remarks);

        UPDATE lab_order
        SET order_status = 'COMPLETED',
            result_id = p_result_id,
            completed_at = SYSDATE
        WHERE order_id = p_order_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END complete_order;

END pkg_lab;
/


-- ==================================================================== pkg_billing

CREATE OR REPLACE PACKAGE pkg_billing AS

    PROCEDURE create_bill (p_admission_id IN NUMBER, p_bill_id OUT NUMBER);

    PROCEDURE add_bill_item (
        p_bill_id IN NUMBER,
        p_description IN VARCHAR2,
        p_quantity IN NUMBER,
        p_unit_price IN NUMBER,
        p_bill_item_id OUT NUMBER
    );

    PROCEDURE remove_bill_item (p_bill_item_id IN NUMBER);

    -- Adds every unbilled lab test and, once the patient has left, the bed charge
    PROCEDURE generate_bill (p_admission_id IN NUMBER, p_bill_id OUT NUMBER, p_message OUT VARCHAR2);

    PROCEDURE record_payment (p_bill_id IN NUMBER, p_amount IN NUMBER);

END pkg_billing;
/

CREATE OR REPLACE PACKAGE BODY pkg_billing AS

    FUNCTION get_or_create_bill (p_admission_id IN NUMBER) RETURN NUMBER IS
        v_bill_id bill.bill_id%TYPE;
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count FROM admission WHERE admission_id = p_admission_id;
        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20006, 'Admission does not exist');
        END IF;

        BEGIN
            SELECT bill_id INTO v_bill_id FROM bill WHERE admission_id = p_admission_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                INSERT INTO bill (admission_id, bill_date, total_amount, amount_paid)
                VALUES (p_admission_id, SYSDATE, 0, 0)
                RETURNING bill_id INTO v_bill_id;
        END;

        RETURN v_bill_id;
    END get_or_create_bill;


    PROCEDURE create_bill (p_admission_id IN NUMBER, p_bill_id OUT NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN,BILLING_STAFF');
        p_bill_id := get_or_create_bill(p_admission_id);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END create_bill;


    PROCEDURE add_bill_item (
        p_bill_id IN NUMBER,
        p_description IN VARCHAR2,
        p_quantity IN NUMBER,
        p_unit_price IN NUMBER,
        p_bill_item_id OUT NUMBER
    ) IS
    BEGIN
        pkg_security.assert_role('ADMIN,BILLING_STAFF');

        -- amount is computed by trg_bill_item_amount, bill total by trg_bill_total_sync
        INSERT INTO bill_item (bill_id, description, quantity, unit_price, amount, source_type)
        VALUES (p_bill_id, p_description, p_quantity, p_unit_price, 0, 'MANUAL')
        RETURNING bill_item_id INTO p_bill_item_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END add_bill_item;


    PROCEDURE remove_bill_item (p_bill_item_id IN NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN,BILLING_STAFF');

        DELETE FROM bill_item WHERE bill_item_id = p_bill_item_id;
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'Bill item does not exist');
        END IF;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END remove_bill_item;


    PROCEDURE generate_bill (p_admission_id IN NUMBER, p_bill_id OUT NUMBER, p_message OUT VARCHAR2) IS

        -- Lab results of this admission that are not on the bill yet
        CURSOR c_unbilled_labs IS
            SELECT r.result_id, t.test_name, t.test_cost, r.test_date
            FROM lab_result r
            JOIN lab_test t ON t.test_id = r.test_id
            WHERE r.admission_id = p_admission_id
            AND NOT EXISTS (SELECT 1 FROM bill_item bi WHERE bi.lab_result_id = r.result_id)
            ORDER BY r.test_date;

        v_status admission.admission_status%TYPE;
        v_admitted admission.admission_date%TYPE;
        v_discharged admission.discharge_date%TYPE;
        v_ward_type ward.ward_type%TYPE;
        v_rate ward_tariff.daily_rate%TYPE;
        v_days NUMBER;
        v_has_bed_line NUMBER;
        v_labs_added NUMBER := 0;
        v_bed_added BOOLEAN := FALSE;
    BEGIN
        pkg_security.assert_role('ADMIN,BILLING_STAFF');

        p_bill_id := get_or_create_bill(p_admission_id);

        FOR lab IN c_unbilled_labs LOOP
            INSERT INTO bill_item (bill_id, description, quantity, unit_price, amount, source_type, lab_result_id)
            VALUES (p_bill_id, 'Lab: ' || lab.test_name || ' (' || TO_CHAR(lab.test_date, 'DD-Mon-YYYY') || ')',
                    1, lab.test_cost, 0, 'LAB', lab.result_id);
            v_labs_added := v_labs_added + 1;
        END LOOP;

        SELECT a.admission_status, a.admission_date, a.discharge_date, w.ward_type
        INTO v_status, v_admitted, v_discharged, v_ward_type
        FROM admission a
        JOIN bed b ON b.bed_id = a.bed_id
        JOIN ward w ON w.ward_id = b.ward_id
        WHERE a.admission_id = p_admission_id;

        SELECT COUNT(*) INTO v_has_bed_line
        FROM bill_item
        WHERE bill_id = p_bill_id AND source_type = 'BED';

        IF v_status = 'DISCHARGED' AND v_has_bed_line = 0 THEN
            BEGIN
                SELECT daily_rate INTO v_rate FROM ward_tariff WHERE ward_type = v_ward_type;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20063, 'No daily tariff defined for ward type ' || v_ward_type);
            END;

            -- Any part of a day counts as a full day, minimum one day
            v_days := GREATEST(1, CEIL(v_discharged - v_admitted));

            INSERT INTO bill_item (bill_id, description, quantity, unit_price, amount, source_type)
            VALUES (p_bill_id, v_ward_type || ' bed charges (' || TO_CHAR(v_admitted, 'DD-Mon') || ' to '
                    || TO_CHAR(v_discharged, 'DD-Mon') || ')', v_days, v_rate, 0, 'BED');
            v_bed_added := TRUE;
        END IF;

        p_message := 'Bill ' || p_bill_id || ': ' || v_labs_added || ' lab charge(s) added'
            || CASE WHEN v_bed_added THEN ', bed charges for ' || v_days || ' day(s) added'
                    WHEN v_status = 'ADMITTED' THEN '; bed charges will be added after discharge'
               END || '.';
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END generate_bill;


    PROCEDURE record_payment (p_bill_id IN NUMBER, p_amount IN NUMBER) IS
        v_balance NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN,BILLING_STAFF');

        IF p_amount IS NULL OR p_amount <= 0 THEN
            RAISE_APPLICATION_ERROR(-20064, 'Payment amount must be positive');
        END IF;

        BEGIN
            SELECT total_amount - amount_paid INTO v_balance
            FROM bill
            WHERE bill_id = p_bill_id
            FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20065, 'Bill does not exist');
        END;

        IF p_amount > v_balance THEN
            RAISE_APPLICATION_ERROR(-20040, 'Payment of ' || p_amount
                || ' is more than the balance due of ' || v_balance);
        END IF;

        -- trg_bill_payment_status sets PENDING / PARTIAL / PAID (and also blocks overpayment)
        UPDATE bill SET amount_paid = amount_paid + p_amount WHERE bill_id = p_bill_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN ROLLBACK; RAISE;
    END record_payment;

END pkg_billing;
/
