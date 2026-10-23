-- SEED DATA FOR BED TURNAROUND TRACKING
-- Safe to run more than once: used by install.sql and by migrate_bed_turnaround.sql.

MERGE INTO allocation_config c
USING (
    SELECT 'CLEANING_TARGET_MIN' AS config_key, 60 AS config_value,
           'Minutes a vacated bed may wait for cleaning before it is flagged' AS description FROM dual
    UNION ALL
    SELECT 'INSPECTION_TARGET_MIN', 30,
           'Minutes a cleaned bed may wait for inspection before it is flagged' FROM dual
) s
ON (c.config_key = s.config_key)
WHEN NOT MATCHED THEN
    INSERT (config_key, config_value, description) VALUES (s.config_key, s.config_value, s.description);


-- Backdated, completed turnaround cycles so the reports have history to show.
-- Durations are exact whole minutes (the test script checks them):
--   ICU is clearly the slowest ward; General has one failed inspection.
DECLARE
    v_seeded NUMBER;

    PROCEDURE add_cycle (
        p_bed_number IN VARCHAR2,
        p_days_ago IN NUMBER,
        p_clean_min IN NUMBER,
        p_inspect_min IN NUMBER,
        p_failed_clean_min IN NUMBER DEFAULT NULL,
        p_failed_inspect_min IN NUMBER DEFAULT NULL
    ) IS
        v_bed_id bed.bed_id%TYPE;
        v_at DATE;

        PROCEDURE step (p_from IN VARCHAR2, p_to IN VARCHAR2) IS
        BEGIN
            INSERT INTO bed_status_history (bed_id, from_status, to_status, changed_by, changed_at)
            VALUES (v_bed_id, p_from, p_to, 'seed', v_at);
        END;
    BEGIN
        SELECT bed_id INTO v_bed_id FROM bed WHERE bed_number = p_bed_number;
        v_at := TRUNC(SYSDATE, 'MI') - p_days_ago;

        step('OCCUPIED', 'AWAITING_CLEANING');
        IF p_failed_clean_min IS NOT NULL THEN
            v_at := v_at + p_failed_clean_min / 1440;
            step('AWAITING_CLEANING', 'AWAITING_INSPECTION');
            v_at := v_at + p_failed_inspect_min / 1440;
            step('AWAITING_INSPECTION', 'AWAITING_CLEANING');
        END IF;
        v_at := v_at + p_clean_min / 1440;
        step('AWAITING_CLEANING', 'AWAITING_INSPECTION');
        v_at := v_at + p_inspect_min / 1440;
        step('AWAITING_INSPECTION', 'AVAILABLE');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;  -- bed not present in this database
    END add_cycle;
BEGIN
    SELECT COUNT(*) INTO v_seeded FROM bed_status_history WHERE changed_by = 'seed';
    IF v_seeded = 0 THEN
        add_cycle('I201', 3, 150, 60);
        add_cycle('I202', 2, 130, 50);
        add_cycle('E104', 3, 70, 25);
        add_cycle('G101', 3, 40, 15);
        add_cycle('G102', 2, 35, 10);
        add_cycle('G103', 2, 20, 12, 30, 10);   -- cleaned 30, failed inspection after 10, cleaned again 20, passed after 12
        add_cycle('P301', 3, 30, 20);
    END IF;
END;
/


-- Fresh install only (no admissions yet): a real discharged admission leaves General bed G110
-- AWAITING_CLEANING for 95 minutes, past the 60-minute cleaning target. On an existing database
-- this block does nothing, so live bed states and admissions are never invented.
DECLARE
    v_admissions NUMBER;
    v_bed_id bed.bed_id%TYPE;
    v_admission_id admission.admission_id%TYPE;
    v_admitted_at DATE := TRUNC(SYSDATE, 'MI') - 2;
    v_vacated_at DATE := TRUNC(SYSDATE, 'MI') - 95 / 1440;
BEGIN
    SELECT COUNT(*) INTO v_admissions FROM admission;
    IF v_admissions > 0 THEN
        RETURN;
    END IF;

    SELECT bed_id INTO v_bed_id FROM bed WHERE bed_number = 'G110';

    -- Goes through the normal guards: admission needs an AVAILABLE bed, bed becomes OCCUPIED,
    -- discharge closes the admission, the bed goes to AWAITING_CLEANING
    INSERT INTO admission (patient_id, bed_id, doctor_id, admission_date, admission_status, urgency_code)
    VALUES (3, v_bed_id, 2, v_admitted_at, 'ADMITTED', 'MEDIUM')
    RETURNING admission_id INTO v_admission_id;

    UPDATE bed SET bed_status = 'OCCUPIED' WHERE bed_id = v_bed_id;

    UPDATE admission
    SET admission_status = 'DISCHARGED', discharge_date = v_vacated_at
    WHERE admission_id = v_admission_id;

    UPDATE bed SET bed_status = 'AWAITING_CLEANING' WHERE bed_id = v_bed_id;

    -- The trigger stamped both history rows with SYSDATE; move them to the seeded times
    UPDATE bed_status_history
    SET changed_at = CASE to_status WHEN 'OCCUPIED' THEN v_admitted_at ELSE v_vacated_at END,
        changed_by = 'seed'
    WHERE bed_id = v_bed_id
    AND admission_id = v_admission_id;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        NULL;  -- bed G110 not present
END;
/

COMMIT;
