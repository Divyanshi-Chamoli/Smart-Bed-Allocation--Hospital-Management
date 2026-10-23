-- END-TO-END TEST OF ALLOCATION, QUEUE, BED TURNAROUND, DOUBLE-BOOKING, ROLES AND BILLING
-- Run on a FRESH install:  sqlplus hms/hms123@localhost/XEPDB1 @sql/95_test_allocation.sql
-- The admissions/queue entries it creates stay behind as demo data.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF

DECLARE
    v_passed NUMBER := 0;
    v_failed NUMBER := 0;
    v_adm NUMBER;
    v_queue NUMBER;
    v_msg VARCHAR2(500);
    v_num NUMBER;
    v_text VARCHAR2(300);
    v_bill NUMBER;
    v_icu_adm_1 NUMBER;
    v_lab_adm NUMBER;
    v_bed_a NUMBER;
    v_bed_b NUMBER;
    v_g110 NUMBER;
    v_n2 NUMBER;
    v_n3 NUMBER;

    PROCEDURE as_user (p_username IN VARCHAR2) IS
    BEGIN
        DBMS_SESSION.SET_IDENTIFIER(p_username);
    END;

    PROCEDURE check_true (p_name IN VARCHAR2, p_condition IN BOOLEAN, p_detail IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        IF p_condition THEN
            v_passed := v_passed + 1;
            DBMS_OUTPUT.PUT_LINE('PASS  ' || p_name);
        ELSE
            v_failed := v_failed + 1;
            DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_name || '  ' || p_detail);
        END IF;
    END;

    PROCEDURE expect_error (p_name IN VARCHAR2, p_code IN NUMBER, p_actual IN NUMBER, p_msg IN VARCHAR2) IS
    BEGIN
        check_true(p_name, p_actual = p_code, 'expected ' || p_code || ', got ' || p_actual || ' ' || p_msg);
    END;

    FUNCTION ward_type_of_admission (p_admission_id IN NUMBER) RETURN VARCHAR2 IS
        v_type ward.ward_type%TYPE;
    BEGIN
        SELECT w.ward_type INTO v_type
        FROM admission a JOIN bed b ON b.bed_id = a.bed_id JOIN ward w ON w.ward_id = b.ward_id
        WHERE a.admission_id = p_admission_id;
        RETURN v_type;
    END;

    FUNCTION active_admission (p_patient_id IN NUMBER) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        SELECT MAX(admission_id) INTO v_id FROM admission
        WHERE patient_id = p_patient_id AND admission_status = 'ADMITTED';
        RETURN v_id;
    END;

    FUNCTION bed_status_of (p_bed_id IN NUMBER) RETURN VARCHAR2 IS
        v_status bed.bed_status%TYPE;
    BEGIN
        SELECT bed_status INTO v_status FROM bed WHERE bed_id = p_bed_id;
        RETURN v_status;
    END;

    FUNCTION icu_available RETURN NUMBER IS
        v_count NUMBER;
    BEGIN
        SELECT available_beds INTO v_count FROM v_bed_occupancy WHERE ward_type = 'ICU';
        RETURN v_count;
    END;

    FUNCTION bed_of_admission (p_admission_id IN NUMBER) RETURN NUMBER IS
        v_bed NUMBER;
    BEGIN
        SELECT bed_id INTO v_bed FROM admission WHERE admission_id = p_admission_id;
        RETURN v_bed;
    END;

BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Authentication');
    check_true('admin/admin123 authenticates as ADMIN', pkg_security.authenticate('admin', 'admin123') = 'ADMIN');
    check_true('wrong password is rejected', pkg_security.authenticate('admin', 'nope') IS NULL);
    SELECT COUNT(*) INTO v_num FROM user_account WHERE NOT REGEXP_LIKE(password, '^[0-9A-F]{64}$');
    check_true('all stored passwords are SHA-256 hashes', v_num = 0, v_num || ' plain');

    DBMS_OUTPUT.PUT_LINE('--- Turnaround views (seeded history, checked before any real cycles)');
    SELECT MAX(cleaning_minutes), MAX(inspection_minutes) INTO v_n2, v_n3
    FROM v_bed_turnaround WHERE bed_number = 'I201' AND is_complete = 'Y';
    check_true('seeded ICU cycle: cleaning 150 min, inspection 60 min', v_n2 = 150 AND v_n3 = 60,
               'got ' || v_n2 || '/' || v_n3);
    SELECT MAX(cleaning_minutes), MAX(inspection_minutes), MAX(inspection_failures) INTO v_n2, v_n3, v_num
    FROM v_bed_turnaround WHERE bed_number = 'G103' AND is_complete = 'Y';
    check_true('failed-inspection cycle: cleaning 30+20, inspection 10+12, 1 failure',
               v_n2 = 50 AND v_n3 = 22 AND v_num = 1, 'got ' || v_n2 || '/' || v_n3 || '/' || v_num);
    SELECT ward_name INTO v_text FROM v_ward_turnaround WHERE slowest_rank = 1;
    check_true('v_ward_turnaround ranks ICU slowest', v_text = 'ICU', 'got ' || v_text);
    SELECT bed_id INTO v_g110 FROM bed WHERE bed_number = 'G110';
    SELECT MAX(past_target), MAX(minutes_in_state) INTO v_text, v_num FROM v_blocked_capacity WHERE bed_id = v_g110;
    check_true('G110 awaiting cleaning 95 min is past the 60 min target', v_text = 'Y' AND v_num BETWEEN 95 AND 100,
               v_text || ' ' || v_num);

    DBMS_OUTPUT.PUT_LINE('--- A bed awaiting cleaning is never recommended or allocated');
    SELECT COUNT(*) INTO v_num FROM TABLE(pkg_bed_allocation.candidate_beds(1, 'General', 'CRITICAL'))
    WHERE bed_id = v_g110;
    check_true('G110 (awaiting cleaning) is not a candidate', v_num = 0);
    as_user('admin');
    BEGIN
        pkg_bed_allocation.allocate_specific_bed(1, 1, v_g110, 'General', 'MEDIUM', v_adm, v_msg);
        check_true('even an admin override cannot allocate a bed awaiting cleaning', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN
        expect_error('even an admin override cannot allocate a bed awaiting cleaning', -20003, SQLCODE, SQLERRM);
    END;
    BEGIN
        INSERT INTO admission (patient_id, bed_id, doctor_id) VALUES (1, v_g110, 1);
        check_true('direct admission insert on a bed awaiting cleaning is blocked', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN
        expect_error('direct admission insert on a bed awaiting cleaning is blocked', -20010, SQLCODE, SQLERRM);
        ROLLBACK;
    END;

    DBMS_OUTPUT.PUT_LINE('--- Turnaround roles and illegal transitions');
    as_user('riya');  -- LAB_STAFF
    BEGIN
        pkg_bed_allocation.mark_bed_cleaned(v_g110, v_msg);
        check_true('lab staff cannot mark beds cleaned', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('lab staff cannot mark beds cleaned', -20100, SQLCODE, SQLERRM);
    END;
    as_user('arjun');  -- BILLING_STAFF
    BEGIN
        pkg_bed_allocation.inspect_bed(v_g110, 'Y', v_msg);
        check_true('billing staff cannot inspect beds', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('billing staff cannot inspect beds', -20100, SQLCODE, SQLERRM);
    END;
    BEGIN
        UPDATE bed SET bed_status = 'AVAILABLE' WHERE bed_id = v_g110;
        check_true('AWAITING_CLEANING -> AVAILABLE is rejected', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN
        expect_error('AWAITING_CLEANING -> AVAILABLE is rejected', -20070, SQLCODE, SQLERRM);
        ROLLBACK;
    END;
    as_user('ananya');  -- NURSE
    BEGIN
        pkg_bed_allocation.inspect_bed(v_g110, 'Y', v_msg);
        check_true('a bed still awaiting cleaning cannot be inspected', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('a bed still awaiting cleaning cannot be inspected', -20072, SQLCODE, SQLERRM);
    END;
    BEGIN
        pkg_bed_allocation.inspect_bed(v_g110, 'X', v_msg);
        check_true('an inspection result other than Y/N is rejected', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('an inspection result other than Y/N is rejected', -20073, SQLCODE, SQLERRM);
    END;
    SELECT bed_id INTO v_num FROM bed WHERE bed_number = 'G109';
    BEGIN
        pkg_bed_allocation.mark_bed_cleaned(v_num, v_msg);
        check_true('an AVAILABLE bed cannot be marked cleaned', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('an AVAILABLE bed cannot be marked cleaned', -20071, SQLCODE, SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('--- Cleaning and inspection');
    pkg_bed_allocation.mark_bed_cleaned(v_g110, v_msg);
    check_true('nurse marks G110 cleaned -> AWAITING_INSPECTION', bed_status_of(v_g110) = 'AWAITING_INSPECTION');
    pkg_bed_allocation.inspect_bed(v_g110, 'N', v_msg);
    check_true('failed inspection -> back to AWAITING_CLEANING', bed_status_of(v_g110) = 'AWAITING_CLEANING');
    pkg_bed_allocation.mark_bed_cleaned(v_g110, v_msg);
    pkg_bed_allocation.inspect_bed(v_g110, 'Y', v_msg);
    check_true('cleaned again and passed -> AVAILABLE', bed_status_of(v_g110) = 'AVAILABLE');
    SELECT COUNT(*) INTO v_num FROM bed_status_history WHERE bed_id = v_g110 AND changed_by = 'ananya';
    check_true('every change was written to bed_status_history (4 rows)', v_num = 4, 'got ' || v_num);
    SELECT MAX(inspection_failures), MAX(is_complete) INTO v_num, v_text FROM v_bed_turnaround WHERE bed_id = v_g110;
    check_true('G110 cycle is complete with 1 inspection failure', v_num = 1 AND v_text = 'Y');

    DBMS_OUTPUT.PUT_LINE('--- Role enforcement in the database');
    as_user('riya');  -- LAB_STAFF
    BEGIN
        pkg_bed_allocation.request_admission(1, 1, 'General', 'LOW', NULL, v_adm, v_queue, v_msg);
        check_true('lab staff cannot request admissions', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('lab staff cannot request admissions', -20100, SQLCODE, SQLERRM);
    END;

    as_user(NULL);
    BEGIN
        pkg_bed_allocation.request_admission(1, 1, 'General', 'LOW', NULL, v_adm, v_queue, v_msg);
        check_true('anonymous session is refused', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('anonymous session is refused', -20100, SQLCODE, SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('--- Rule: child requesting General goes to Pediatric');
    as_user('ananya');  -- NURSE
    pkg_bed_allocation.request_admission(6, 8, 'General', 'MEDIUM', 'Fever', v_adm, v_queue, v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    check_true('7-year-old placed in Pediatric ward', ward_type_of_admission(v_adm) = 'Pediatric');

    DBMS_OUTPUT.PUT_LINE('--- Rule: ICU keeps 1 bed reserved for CRITICAL');
    as_user('rahul');  -- DOCTOR
    FOR p IN (SELECT column_value AS patient_id FROM TABLE(sys.odcinumberlist(1, 2, 3, 5))) LOOP
        pkg_bed_allocation.request_admission(p.patient_id, 1, 'ICU', 'HIGH', NULL, v_adm, v_queue, v_msg);
        IF p.patient_id = 1 THEN v_icu_adm_1 := v_adm; END IF;
    END LOOP;
    SELECT available_beds INTO v_num FROM v_bed_occupancy WHERE ward_type = 'ICU';
    check_true('4 HIGH patients fill ICU down to the reserved bed', v_num = 1, v_num || ' free');

    pkg_bed_allocation.request_admission(8, 1, 'ICU', 'HIGH', NULL, v_adm, v_queue, v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    check_true('5th HIGH ICU patient is queued, not given the reserved bed', v_adm IS NULL AND v_queue IS NOT NULL);

    pkg_bed_allocation.request_admission(7, 1, 'ICU', 'CRITICAL', 'Cardiac arrest', v_adm, v_queue, v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    check_true('CRITICAL patient gets the reserved ICU bed', ward_type_of_admission(v_adm) = 'ICU'
               AND v_msg LIKE '%reserved for critical%');

    DBMS_OUTPUT.PUT_LINE('--- Rule: fallback ward when ICU is full');
    pkg_bed_allocation.request_admission(9, 7, 'ICU', 'CRITICAL', NULL, v_adm, v_queue, v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    check_true('CRITICAL patient falls back to Emergency', ward_type_of_admission(v_adm) = 'Emergency'
               AND v_msg LIKE '%Fallback%');

    DBMS_OUTPUT.PUT_LINE('--- Prioritised queue');
    pkg_bed_allocation.request_admission(4, 2, 'ICU', 'LOW', NULL, v_adm, v_queue, v_msg);
    SELECT patient_id INTO v_num FROM v_waiting_queue_ranked WHERE queue_position = 1;
    check_true('HIGH patient ranks above a LOW patient who arrived later', v_num = 8);

    -- Back-date the LOW request by 10 hours: aging raises its score but must not cross into HIGH
    UPDATE waiting_queue SET request_time = SYSDATE - 10/24 WHERE patient_id = 4 AND queue_status = 'WAITING';
    COMMIT;
    SELECT priority_score INTO v_num FROM v_waiting_queue_ranked WHERE patient_id = 4;
    check_true('aging raises LOW score (10 -> ' || v_num || ') but stays below HIGH (70)', v_num > 10 AND v_num < 70);
    SELECT patient_id INTO v_num FROM v_waiting_queue_ranked WHERE queue_position = 1;
    check_true('HIGH patient still first after aging', v_num = 8);

    BEGIN
        pkg_bed_allocation.request_admission(4, 2, 'ICU', 'LOW', NULL, v_adm, v_queue, v_msg);
        check_true('patient cannot be queued twice', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('patient cannot be queued twice', -20022, SQLCODE, SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('--- Discharge sends the bed for cleaning; the queue waits for inspection');
    as_user('ananya');
    BEGIN
        pkg_bed_allocation.discharge_patient(v_icu_adm_1, v_msg);
        check_true('nurse cannot discharge', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('nurse cannot discharge', -20100, SQLCODE, SQLERRM);
    END;

    v_bed_a := bed_of_admission(v_icu_adm_1);
    as_user('rahul');
    pkg_bed_allocation.discharge_patient(v_icu_adm_1, v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    check_true('discharge -> bed AWAITING_CLEANING', bed_status_of(v_bed_a) = 'AWAITING_CLEANING');
    check_true('discharge does not serve the queue (HIGH patient 8 still waiting, no free ICU bed)',
               active_admission(8) IS NULL AND icu_available = 0);
    SELECT COUNT(*) INTO v_num FROM TABLE(pkg_bed_allocation.candidate_beds(4, 'ICU', 'CRITICAL'))
    WHERE ward_type = 'ICU';
    check_true('the ICU bed awaiting cleaning is not recommended even for CRITICAL', v_num = 0);

    as_user('ananya');
    pkg_bed_allocation.mark_bed_cleaned(v_bed_a, v_msg);
    check_true('cleaned -> AWAITING_INSPECTION', bed_status_of(v_bed_a) = 'AWAITING_INSPECTION');
    pkg_bed_allocation.inspect_bed(v_bed_a, 'Y', v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    check_true('passed -> AVAILABLE; it is the critical reserve, so HIGH patient keeps waiting',
               bed_status_of(v_bed_a) = 'AVAILABLE' AND active_admission(8) IS NULL);

    v_bed_b := bed_of_admission(active_admission(2));
    as_user('rahul');
    pkg_bed_allocation.discharge_patient(active_admission(2), v_msg);
    as_user('ananya');
    pkg_bed_allocation.process_queue(v_num);
    check_true('a bed awaiting cleaning does not count toward the reserve (1 free + 1 awaiting: patient 8 waits)',
               icu_available = 1 AND active_admission(8) IS NULL);

    pkg_bed_allocation.mark_bed_cleaned(v_bed_b, v_msg);
    pkg_bed_allocation.inspect_bed(v_bed_b, 'Y', v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    check_true('after inspection passes, queue head (HIGH, patient 8) is auto-admitted to ICU',
               active_admission(8) IS NOT NULL AND ward_type_of_admission(active_admission(8)) = 'ICU');
    check_true('LOW patient 4 still waiting', active_admission(4) IS NULL);

    DBMS_OUTPUT.PUT_LINE('--- Double booking prevention');
    v_adm := active_admission(8);
    SELECT bed_id INTO v_num FROM admission WHERE admission_id = v_adm;
    BEGIN
        INSERT INTO admission (patient_id, bed_id, doctor_id) VALUES (4, v_num, 1);
        check_true('direct insert onto an occupied bed is blocked by trigger', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN
        expect_error('direct insert onto an occupied bed is blocked by trigger', -20010, SQLCODE, SQLERRM);
        ROLLBACK;
    END;

    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_admission_guard DISABLE';
    BEGIN
        INSERT INTO admission (patient_id, bed_id, doctor_id) VALUES (4, v_num, 1);
        check_true('unique index blocks it even with the trigger disabled', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN
        expect_error('unique index blocks it even with the trigger disabled', -1, SQLCODE, SQLERRM);
        ROLLBACK;
    END;
    EXECUTE IMMEDIATE 'ALTER TRIGGER trg_admission_guard ENABLE';

    BEGIN
        UPDATE bed SET bed_status = 'AVAILABLE' WHERE bed_id = v_num;
        check_true('occupied bed cannot be freed by hand', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN
        expect_error('occupied bed cannot be freed by hand', -20012, SQLCODE, SQLERRM);
        ROLLBACK;
    END;

    BEGIN
        UPDATE bed SET bed_status = 'AWAITING_INSPECTION' WHERE bed_id = v_num;
        check_true('OCCUPIED -> AWAITING_INSPECTION is rejected', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN
        expect_error('OCCUPIED -> AWAITING_INSPECTION is rejected', -20012, SQLCODE, SQLERRM);
        ROLLBACK;
    END;

    as_user('ananya');
    BEGIN
        pkg_bed_allocation.set_bed_status(v_num, 'MAINTENANCE', v_msg);
        check_true('occupied bed cannot go to maintenance', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('occupied bed cannot go to maintenance', -20012, SQLCODE, SQLERRM);
    END;

    DBMS_OUTPUT.PUT_LINE('--- Lab results and billing');
    v_lab_adm := active_admission(8);
    as_user('riya');
    pkg_lab.record_result(v_lab_adm, 1, 'Hb 13.2 g/dL', 'Normal', v_num);
    pkg_lab.record_result(v_lab_adm, 6, 'Sinus rhythm', NULL, v_num);
    check_true('lab staff recorded 2 results', v_num IS NOT NULL);

    as_user('rahul');
    pkg_bed_allocation.discharge_patient(v_lab_adm, v_msg);

    as_user('arjun');  -- BILLING_STAFF
    pkg_billing.generate_bill(v_lab_adm, v_bill, v_msg);
    DBMS_OUTPUT.PUT_LINE('      ' || v_msg);
    SELECT total_amount INTO v_num FROM bill WHERE bill_id = v_bill;
    check_true('bill = Blood Test 500 + ECG 700 + 1 ICU day 8000 = 9200', v_num = 9200, 'got ' || v_num);

    pkg_billing.generate_bill(v_lab_adm, v_bill, v_msg);
    SELECT total_amount INTO v_num FROM bill WHERE bill_id = v_bill;
    check_true('generating again does not double-charge', v_num = 9200, 'got ' || v_num);

    pkg_billing.record_payment(v_bill, 5000);
    SELECT payment_status INTO v_text FROM bill WHERE bill_id = v_bill;
    check_true('part payment -> PARTIAL', v_text = 'PARTIAL', v_text);

    BEGIN
        pkg_billing.record_payment(v_bill, 99999);
        check_true('overpayment rejected', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('overpayment rejected', -20040, SQLCODE, SQLERRM);
    END;

    pkg_billing.record_payment(v_bill, 4200);
    SELECT payment_status INTO v_text FROM bill WHERE bill_id = v_bill;
    check_true('full payment -> PAID', v_text = 'PAID', v_text);

    BEGIN
        pkg_billing.add_bill_item(v_bill, 'Late charge', 1, 100, v_num);
        check_true('paid bill is locked', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('paid bill is locked', -20041, SQLCODE, SQLERRM);
    END;

    as_user('rahul');
    BEGIN
        pkg_billing.record_payment(v_bill, 1);
        check_true('doctor cannot touch billing', FALSE, 'no error raised');
    EXCEPTION WHEN OTHERS THEN expect_error('doctor cannot touch billing', -20100, SQLCODE, SQLERRM);
    END;

    as_user(NULL);
    DBMS_OUTPUT.PUT_LINE('---');
    DBMS_OUTPUT.PUT_LINE(v_passed || ' passed, ' || v_failed || ' failed');
END;
/
