-- SMART BED ALLOCATION PACKAGE
--
-- Rule-based recommendation:
--   1. Effective ward type: children asking for General go to Pediatric, adults asking for
--      Pediatric go to General.
--   2. ward_compatibility gives the ward types that may serve the request, by preference rank.
--      Fallback ward types only apply when the urgency weight is high enough.
--   3. Adults are never placed in a Pediatric ward.
--   4. Each ward keeps reserved_critical_beds beds that only CRITICAL patients may take.
--   5. Among suitable beds, prefer the least occupied ward (spreads load), then bed number.
--
-- Prioritised waiting queue:
--   Every request enters waiting_queue and the queue is served in priority order, so a new
--   request can never jump ahead of a more urgent patient already waiting.
--   priority = urgency weight + aging (capped) + overdue bonus + vulnerable-age bonus
--   The queue is re-run automatically whenever a bed becomes AVAILABLE: when it passes inspection
--   (discharge only sends it for cleaning) or comes back from maintenance.
--
-- Double booking prevention:
--   candidate beds are locked with SELECT ... FOR UPDATE SKIP LOCKED, trg_admission_guard
--   re-checks the bed under lock, and the unique index uq_active_admission_bed makes a second
--   active admission on the same bed impossible even for direct SQL.

CREATE OR REPLACE PACKAGE pkg_bed_allocation AS

    TYPE t_candidate IS RECORD (
        candidate_rank NUMBER,
        bed_id NUMBER,
        bed_number VARCHAR2(10),
        ward_id NUMBER,
        ward_name VARCHAR2(50),
        ward_type VARCHAR2(30),
        preference_rank NUMBER,
        ward_occupancy_pct NUMBER,
        rule_applied VARCHAR2(300)
    );

    TYPE t_candidate_tab IS TABLE OF t_candidate;

    FUNCTION get_config (p_key IN VARCHAR2) RETURN NUMBER;
    FUNCTION urgency_weight (p_urgency IN VARCHAR2) RETURN NUMBER;
    FUNCTION patient_age (p_patient_id IN NUMBER) RETURN NUMBER;
    FUNCTION effective_ward_type (p_patient_id IN NUMBER, p_requested_type IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION priority_score (p_queue_id IN NUMBER) RETURN NUMBER;
    FUNCTION queue_position (p_queue_id IN NUMBER) RETURN NUMBER;
    FUNCTION bed_label (p_bed_id IN NUMBER) RETURN VARCHAR2;

    -- All suitable AVAILABLE beds for this patient, best first
    FUNCTION candidate_beds (
        p_patient_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2
    ) RETURN t_candidate_tab PIPELINED;

    -- Best bed id, or NULL when nothing suitable is free
    FUNCTION recommend_bed (
        p_patient_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2
    ) RETURN NUMBER;

    -- Top-N candidates with the rule that selected each one (for the UI)
    PROCEDURE recommend_beds (
        p_patient_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2,
        p_result OUT SYS_REFCURSOR
    );

    -- Main entry point: allocate the best bed now, or queue the patient
    PROCEDURE request_admission (
        p_patient_id IN NUMBER,
        p_doctor_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2,
        p_notes IN VARCHAR2,
        p_admission_id OUT NUMBER,
        p_queue_id OUT NUMBER,
        p_message OUT VARCHAR2
    );

    -- Allocate a bed the user picked from the recommendations (ADMIN may override the rules)
    PROCEDURE allocate_specific_bed (
        p_patient_id IN NUMBER,
        p_doctor_id IN NUMBER,
        p_bed_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2,
        p_admission_id OUT NUMBER,
        p_message OUT VARCHAR2
    );

    PROCEDURE process_queue (p_allocated OUT NUMBER);

    PROCEDURE cancel_queue_entry (p_queue_id IN NUMBER, p_reason IN VARCHAR2);

    PROCEDURE discharge_patient (p_admission_id IN NUMBER, p_message OUT VARCHAR2);

    PROCEDURE cancel_admission (p_admission_id IN NUMBER, p_reason IN VARCHAR2, p_message OUT VARCHAR2);

    PROCEDURE set_bed_status (p_bed_id IN NUMBER, p_status IN VARCHAR2, p_message OUT VARCHAR2);

    -- Turnaround: AWAITING_CLEANING -> AWAITING_INSPECTION
    PROCEDURE mark_bed_cleaned (p_bed_id IN NUMBER, p_message OUT VARCHAR2);

    -- Turnaround: p_passed 'Y' -> AVAILABLE (and the waiting queue is served), 'N' -> AWAITING_CLEANING
    PROCEDURE inspect_bed (p_bed_id IN NUMBER, p_passed IN VARCHAR2, p_message OUT VARCHAR2);

END pkg_bed_allocation;
/


CREATE OR REPLACE PACKAGE BODY pkg_bed_allocation AS

    -- ---------------------------------------------------------------- helpers

    FUNCTION get_config (p_key IN VARCHAR2) RETURN NUMBER IS
        v_value allocation_config.config_value%TYPE;
    BEGIN
        SELECT config_value INTO v_value
        FROM allocation_config
        WHERE config_key = p_key;
        RETURN v_value;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20025, 'Missing allocation_config key ' || p_key);
    END get_config;


    FUNCTION urgency_weight (p_urgency IN VARCHAR2) RETURN NUMBER IS
        v_weight urgency_level.base_weight%TYPE;
    BEGIN
        SELECT base_weight INTO v_weight
        FROM urgency_level
        WHERE urgency_code = p_urgency;
        RETURN v_weight;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20020, 'Unknown urgency level ' || p_urgency);
    END urgency_weight;


    FUNCTION patient_age (p_patient_id IN NUMBER) RETURN NUMBER IS
        v_dob patient.dob%TYPE;
    BEGIN
        SELECT dob INTO v_dob
        FROM patient
        WHERE patient_id = p_patient_id;
        RETURN FLOOR(MONTHS_BETWEEN(SYSDATE, v_dob) / 12);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'Patient does not exist');
    END patient_age;


    FUNCTION effective_ward_type (p_patient_id IN NUMBER, p_requested_type IN VARCHAR2) RETURN VARCHAR2 IS
        v_age NUMBER := patient_age(p_patient_id);
        v_child_limit NUMBER := get_config('PEDIATRIC_MAX_AGE');
    BEGIN
        IF p_requested_type = 'General' AND v_age < v_child_limit THEN
            RETURN 'Pediatric';
        ELSIF p_requested_type = 'Pediatric' AND v_age >= v_child_limit THEN
            RETURN 'General';
        END IF;
        RETURN p_requested_type;
    END effective_ward_type;


    FUNCTION priority_score (p_queue_id IN NUMBER) RETURN NUMBER IS
        v_weight NUMBER;
        v_target_wait NUMBER;
        v_waited_min NUMBER;
        v_age NUMBER;
        v_score NUMBER;
    BEGIN
        SELECT u.base_weight,
               u.target_wait_minutes,
               (NVL(q.resolved_time, SYSDATE) - q.request_time) * 1440,
               FLOOR(MONTHS_BETWEEN(SYSDATE, p.dob) / 12)
        INTO v_weight, v_target_wait, v_waited_min, v_age
        FROM waiting_queue q
        JOIN urgency_level u ON u.urgency_code = q.urgency_code
        JOIN patient p ON p.patient_id = q.patient_id
        WHERE q.queue_id = p_queue_id;

        -- Aging: points for every completed interval waited, capped
        v_score := v_weight
            + LEAST(get_config('AGING_CAP'),
                    FLOOR(v_waited_min / GREATEST(get_config('AGING_INTERVAL_MIN'), 1))
                        * get_config('AGING_POINTS'));

        -- Overdue: waited longer than the target for this urgency band
        IF v_waited_min > v_target_wait THEN
            v_score := v_score + get_config('OVERDUE_BONUS');
        END IF;

        -- Vulnerable patients: children and elderly
        IF v_age < get_config('PEDIATRIC_MAX_AGE') OR v_age >= get_config('ELDERLY_MIN_AGE') THEN
            v_score := v_score + get_config('VULNERABLE_BONUS');
        END IF;

        RETURN v_score;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END priority_score;


    FUNCTION queue_position (p_queue_id IN NUMBER) RETURN NUMBER IS
        v_position NUMBER;
    BEGIN
        SELECT position INTO v_position
        FROM (
            SELECT queue_id,
                   ROW_NUMBER() OVER (ORDER BY pkg_bed_allocation.priority_score(queue_id) DESC,
                                               request_time, queue_id) AS position
            FROM waiting_queue
            WHERE queue_status = 'WAITING'
        )
        WHERE queue_id = p_queue_id;
        RETURN v_position;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END queue_position;


    FUNCTION bed_label (p_bed_id IN NUMBER) RETURN VARCHAR2 IS
        v_label VARCHAR2(100);
    BEGIN
        SELECT w.ward_name || ' / ' || b.bed_number INTO v_label
        FROM bed b
        JOIN ward w ON w.ward_id = b.ward_id
        WHERE b.bed_id = p_bed_id;
        RETURN v_label;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'bed ' || p_bed_id;
    END bed_label;


    PROCEDURE log_action (
        p_patient_id IN NUMBER,
        p_bed_id IN NUMBER,
        p_queue_id IN NUMBER,
        p_admission_id IN NUMBER,
        p_action IN VARCHAR2,
        p_rule IN VARCHAR2,
        p_score IN NUMBER
    ) IS
    BEGIN
        INSERT INTO bed_allocation_log (patient_id, bed_id, queue_id, admission_id, action,
                                        rule_applied, priority_score, acted_by)
        VALUES (p_patient_id, p_bed_id, p_queue_id, p_admission_id, p_action,
                SUBSTR(p_rule, 1, 300), p_score, pkg_security.current_username);
    END log_action;


    PROCEDURE validate_doctor (p_doctor_id IN NUMBER) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count
        FROM staff
        WHERE staff_id = p_doctor_id
        AND designation = 'Doctor';

        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Doctor does not exist');
        END IF;
    END validate_doctor;


    PROCEDURE validate_not_admitted (p_patient_id IN NUMBER) IS
        v_admission_id NUMBER;
    BEGIN
        SELECT MAX(admission_id) INTO v_admission_id
        FROM admission
        WHERE patient_id = p_patient_id
        AND admission_status = 'ADMITTED';

        IF v_admission_id IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20021, 'Patient is already admitted (admission ' || v_admission_id || ')');
        END IF;
    END validate_not_admitted;


    -- ---------------------------------------------------------------- recommendation

    FUNCTION candidate_beds (
        p_patient_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2
    ) RETURN t_candidate_tab PIPELINED IS

        CURSOR c_rules (cp_type VARCHAR2, cp_weight NUMBER) IS
            SELECT allowed_ward_type, preference_rank, rule_description
            FROM ward_compatibility
            WHERE required_ward_type = cp_type
            AND is_active = 'Y'
            AND min_urgency_weight <= cp_weight
            ORDER BY preference_rank;

        CURSOR c_beds (cp_ward_type VARCHAR2) IS
            SELECT b.bed_id, b.bed_number, w.ward_id, w.ward_name, w.ward_type,
                   w.reserved_critical_beds, s.available_beds, s.occupancy_pct
            FROM bed b
            JOIN ward w ON w.ward_id = b.ward_id
            JOIN (
                SELECT ward_id,
                       SUM(CASE WHEN bed_status = 'AVAILABLE' THEN 1 ELSE 0 END) AS available_beds,
                       -- Beds still being turned around count as in use, not free
                       ROUND(100 * SUM(CASE WHEN bed_status IN ('OCCUPIED','AWAITING_CLEANING','AWAITING_INSPECTION')
                                            THEN 1 ELSE 0 END) / COUNT(*), 1) AS occupancy_pct
                FROM bed
                GROUP BY ward_id
            ) s ON s.ward_id = w.ward_id
            WHERE w.ward_type = cp_ward_type
            AND b.bed_status = 'AVAILABLE'
            ORDER BY s.occupancy_pct, w.ward_id, b.bed_number;

        TYPE t_rule IS RECORD (
            allowed_ward_type ward_compatibility.allowed_ward_type%TYPE,
            preference_rank ward_compatibility.preference_rank%TYPE,
            rule_description ward_compatibility.rule_description%TYPE
        );
        TYPE t_rule_tab IS TABLE OF t_rule;

        v_rules t_rule_tab;
        v_weight NUMBER := urgency_weight(p_urgency);
        v_type VARCHAR2(30) := effective_ward_type(p_patient_id, p_ward_type);
        v_is_child BOOLEAN := patient_age(p_patient_id) < get_config('PEDIATRIC_MAX_AGE');
        v_prefix VARCHAR2(100);
        v_row t_candidate;
        v_rank NUMBER := 0;
    BEGIN
        IF v_type <> p_ward_type THEN
            v_prefix := 'Age rule: ' || p_ward_type || ' request redirected to ' || v_type || '. ';
        END IF;

        OPEN c_rules(v_type, v_weight);
        FETCH c_rules BULK COLLECT INTO v_rules;
        CLOSE c_rules;

        -- A ward type without configured rules can still be served by its own wards
        IF v_rules.COUNT = 0 THEN
            v_rules.EXTEND;
            v_rules(1).allowed_ward_type := v_type;
            v_rules(1).preference_rank := 1;
            v_rules(1).rule_description := 'Requested ward type';
        END IF;

        FOR i IN 1 .. v_rules.COUNT LOOP
            -- Adults are never placed in a pediatric ward
            CONTINUE WHEN v_rules(i).allowed_ward_type = 'Pediatric' AND NOT v_is_child;

            FOR b IN c_beds(v_rules(i).allowed_ward_type) LOOP
                -- The last reserved_critical_beds free beds of a ward are kept for CRITICAL patients
                CONTINUE WHEN p_urgency <> 'CRITICAL' AND b.available_beds <= b.reserved_critical_beds;

                v_rank := v_rank + 1;
                v_row.candidate_rank := v_rank;
                v_row.bed_id := b.bed_id;
                v_row.bed_number := b.bed_number;
                v_row.ward_id := b.ward_id;
                v_row.ward_name := b.ward_name;
                v_row.ward_type := b.ward_type;
                v_row.preference_rank := v_rules(i).preference_rank;
                v_row.ward_occupancy_pct := b.occupancy_pct;
                v_row.rule_applied := v_prefix
                    || CASE WHEN v_rules(i).preference_rank = 1
                            THEN 'Preferred: ' || b.ward_type || ' ward'
                            ELSE 'Fallback #' || v_rules(i).preference_rank || ': ' || v_rules(i).rule_description
                       END
                    || CASE WHEN b.available_beds <= b.reserved_critical_beds
                            THEN ' (uses a bed reserved for critical cases)'
                       END
                    || '; ward ' || b.occupancy_pct || '% occupied';
                PIPE ROW (v_row);
            END LOOP;
        END LOOP;

        RETURN;
    END candidate_beds;


    FUNCTION recommend_bed (
        p_patient_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2
    ) RETURN NUMBER IS
        v_bed_id NUMBER;
    BEGIN
        SELECT MIN(bed_id) KEEP (DENSE_RANK FIRST ORDER BY candidate_rank)
        INTO v_bed_id
        FROM TABLE(pkg_bed_allocation.candidate_beds(p_patient_id, p_ward_type, p_urgency));
        RETURN v_bed_id;
    END recommend_bed;


    PROCEDURE recommend_beds (
        p_patient_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2,
        p_result OUT SYS_REFCURSOR
    ) IS
        v_top_n NUMBER := get_config('RECOMMEND_TOP_N');
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        OPEN p_result FOR
            SELECT candidate_rank, bed_id, bed_number, ward_id, ward_name, ward_type,
                   preference_rank, ward_occupancy_pct, rule_applied
            FROM TABLE(pkg_bed_allocation.candidate_beds(p_patient_id, p_ward_type, p_urgency))
            WHERE candidate_rank <= v_top_n
            ORDER BY candidate_rank;
    END recommend_beds;


    -- ---------------------------------------------------------------- allocation core

    -- Walk the candidates best-first and lock the first bed nobody else holds.
    -- SKIP LOCKED: if a concurrent transaction is allocating that bed, move on to the next one.
    FUNCTION lock_best_bed (
        p_patient_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2,
        p_rule OUT VARCHAR2
    ) RETURN NUMBER IS
        CURSOR c_candidates IS
            SELECT bed_id, rule_applied
            FROM TABLE(pkg_bed_allocation.candidate_beds(p_patient_id, p_ward_type, p_urgency))
            ORDER BY candidate_rank;

        v_locked_bed NUMBER;
    BEGIN
        FOR c IN c_candidates LOOP
            BEGIN
                SELECT bed_id INTO v_locked_bed
                FROM bed
                WHERE bed_id = c.bed_id
                AND bed_status = 'AVAILABLE'
                FOR UPDATE SKIP LOCKED;

                p_rule := c.rule_applied;
                RETURN v_locked_bed;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    NULL;
            END;
        END LOOP;

        RETURN NULL;
    END lock_best_bed;


    FUNCTION create_admission (
        p_patient_id IN NUMBER,
        p_bed_id IN NUMBER,
        p_doctor_id IN NUMBER,
        p_urgency IN VARCHAR2,
        p_queue_id IN NUMBER,
        p_rule IN VARCHAR2,
        p_score IN NUMBER
    ) RETURN NUMBER IS
        v_admission_id admission.admission_id%TYPE;
    BEGIN
        INSERT INTO admission (patient_id, bed_id, doctor_id, admission_date,
                               admission_status, urgency_code, queue_id)
        VALUES (p_patient_id, p_bed_id, p_doctor_id, SYSDATE,
                'ADMITTED', p_urgency, p_queue_id)
        RETURNING admission_id INTO v_admission_id;

        UPDATE bed
        SET bed_status = 'OCCUPIED'
        WHERE bed_id = p_bed_id;

        log_action(p_patient_id, p_bed_id, p_queue_id, v_admission_id, 'ALLOCATED', p_rule, p_score);

        RETURN v_admission_id;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            RAISE_APPLICATION_ERROR(-20030,
                'Double booking prevented: the bed or the patient already has an active admission');
    END create_admission;


    -- Serve the waiting queue in priority order. Does not commit.
    FUNCTION run_queue RETURN NUMBER IS
        CURSOR c_waiting IS
            SELECT queue_id, patient_id, doctor_id, required_ward_type, urgency_code
            FROM waiting_queue
            WHERE queue_status = 'WAITING'
            ORDER BY pkg_bed_allocation.priority_score(queue_id) DESC, request_time, queue_id
            FOR UPDATE SKIP LOCKED;

        v_bed_id NUMBER;
        v_rule VARCHAR2(300);
        v_score NUMBER;
        v_admission_id NUMBER;
        v_allocated NUMBER := 0;
    BEGIN
        FOR q IN c_waiting LOOP
            v_bed_id := lock_best_bed(q.patient_id, q.required_ward_type, q.urgency_code, v_rule);

            IF v_bed_id IS NOT NULL THEN
                v_score := priority_score(q.queue_id);
                v_admission_id := create_admission(q.patient_id, v_bed_id, q.doctor_id,
                                                   q.urgency_code, q.queue_id, v_rule, v_score);

                UPDATE waiting_queue
                SET queue_status = 'ALLOCATED',
                    allocated_bed_id = v_bed_id,
                    admission_id = v_admission_id,
                    resolved_time = SYSDATE
                WHERE CURRENT OF c_waiting;

                v_allocated := v_allocated + 1;
            END IF;
        END LOOP;

        RETURN v_allocated;
    END run_queue;


    -- ---------------------------------------------------------------- public operations

    PROCEDURE request_admission (
        p_patient_id IN NUMBER,
        p_doctor_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2,
        p_notes IN VARCHAR2,
        p_admission_id OUT NUMBER,
        p_queue_id OUT NUMBER,
        p_message OUT VARCHAR2
    ) IS
        v_type VARCHAR2(30);
        v_weight NUMBER;
        v_status waiting_queue.queue_status%TYPE;
        v_bed_id NUMBER;
        v_rule VARCHAR2(300);
        v_allocated NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        validate_doctor(p_doctor_id);
        validate_not_admitted(p_patient_id);
        v_weight := urgency_weight(p_urgency);  -- raises for an unknown urgency code
        v_type := effective_ward_type(p_patient_id, p_ward_type);

        BEGIN
            INSERT INTO waiting_queue (patient_id, doctor_id, required_ward_type, urgency_code,
                                       notes, requested_by)
            VALUES (p_patient_id, p_doctor_id, v_type, p_urgency,
                    p_notes, pkg_security.current_user_id)
            RETURNING queue_id INTO p_queue_id;
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                RAISE_APPLICATION_ERROR(-20022, 'Patient is already in the waiting queue');
        END;

        -- Serve the whole queue: the new request only gets a bed if nobody more urgent can use it
        v_allocated := run_queue;

        SELECT queue_status, admission_id, allocated_bed_id
        INTO v_status, p_admission_id, v_bed_id
        FROM waiting_queue
        WHERE queue_id = p_queue_id;

        IF v_status = 'ALLOCATED' THEN
            SELECT MAX(rule_applied) INTO v_rule
            FROM bed_allocation_log
            WHERE admission_id = p_admission_id
            AND action = 'ALLOCATED';

            p_message := 'Allocated ' || bed_label(v_bed_id) || ' (admission ' || p_admission_id
                || '). ' || v_rule;
        ELSE
            log_action(p_patient_id, NULL, p_queue_id, NULL, 'QUEUED',
                       'No suitable ' || v_type || ' bed available', priority_score(p_queue_id));

            p_message := 'No suitable bed is free. Patient added to the waiting queue at position '
                || queue_position(p_queue_id) || ' with priority score ' || priority_score(p_queue_id) || '.';
        END IF;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END request_admission;


    PROCEDURE allocate_specific_bed (
        p_patient_id IN NUMBER,
        p_doctor_id IN NUMBER,
        p_bed_id IN NUMBER,
        p_ward_type IN VARCHAR2,
        p_urgency IN VARCHAR2,
        p_admission_id OUT NUMBER,
        p_message OUT VARCHAR2
    ) IS
        v_rule VARCHAR2(300);
        v_locked NUMBER;
        v_queue_id NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        validate_doctor(p_doctor_id);
        validate_not_admitted(p_patient_id);

        -- Is this bed one the rules recommend for the patient?
        SELECT MAX(rule_applied) INTO v_rule
        FROM TABLE(pkg_bed_allocation.candidate_beds(p_patient_id, p_ward_type, p_urgency))
        WHERE bed_id = p_bed_id;

        IF v_rule IS NULL THEN
            IF pkg_security.has_role('ADMIN') THEN
                v_rule := 'Manual override by ' || pkg_security.current_username;
            ELSE
                RAISE_APPLICATION_ERROR(-20023, 'Bed ' || bed_label(p_bed_id)
                    || ' is not suitable for this patient under the allocation rules (only ADMIN can override)');
            END IF;
        END IF;

        BEGIN
            SELECT bed_id INTO v_locked
            FROM bed
            WHERE bed_id = p_bed_id
            AND bed_status = 'AVAILABLE'
            FOR UPDATE SKIP LOCKED;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20003,
                    'Bed is not available (occupied, under maintenance or being allocated by another user)');
        END;

        -- If the patient was waiting, this allocation resolves their queue entry
        SELECT MAX(queue_id) INTO v_queue_id
        FROM waiting_queue
        WHERE patient_id = p_patient_id
        AND queue_status = 'WAITING';

        p_admission_id := create_admission(p_patient_id, p_bed_id, p_doctor_id, p_urgency,
                                           v_queue_id, v_rule,
                                           CASE WHEN v_queue_id IS NOT NULL THEN priority_score(v_queue_id) END);

        IF v_queue_id IS NOT NULL THEN
            UPDATE waiting_queue
            SET queue_status = 'ALLOCATED',
                allocated_bed_id = p_bed_id,
                admission_id = p_admission_id,
                resolved_time = SYSDATE
            WHERE queue_id = v_queue_id;
        END IF;

        p_message := 'Allocated ' || bed_label(p_bed_id) || ' (admission ' || p_admission_id || '). ' || v_rule;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END allocate_specific_bed;


    PROCEDURE process_queue (p_allocated OUT NUMBER) IS
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');
        p_allocated := run_queue;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END process_queue;


    PROCEDURE cancel_queue_entry (p_queue_id IN NUMBER, p_reason IN VARCHAR2) IS
        v_status waiting_queue.queue_status%TYPE;
        v_patient_id NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR,NURSE');

        BEGIN
            SELECT queue_status, patient_id INTO v_status, v_patient_id
            FROM waiting_queue
            WHERE queue_id = p_queue_id
            FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20026, 'Queue entry does not exist');
        END;

        IF v_status <> 'WAITING' THEN
            RAISE_APPLICATION_ERROR(-20027, 'Queue entry is already ' || v_status);
        END IF;

        UPDATE waiting_queue
        SET queue_status = 'CANCELLED',
            resolved_time = SYSDATE,
            notes = SUBSTR(notes || CASE WHEN notes IS NOT NULL THEN ' | ' END
                           || 'Cancelled: ' || p_reason, 1, 500)
        WHERE queue_id = p_queue_id;

        log_action(v_patient_id, NULL, p_queue_id, NULL, 'CANCELLED', p_reason, NULL);

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END cancel_queue_entry;


    -- Shared by discharge and cancel: close the admission and send the bed for cleaning.
    -- The queue is not served here; it is served when the bed passes inspection (inspect_bed).
    PROCEDURE close_admission (
        p_admission_id IN NUMBER,
        p_new_status IN VARCHAR2,
        p_reason IN VARCHAR2,
        p_message OUT VARCHAR2
    ) IS
        v_bed_id NUMBER;
        v_patient_id NUMBER;
        v_status admission.admission_status%TYPE;
        v_cancelled_orders NUMBER;
    BEGIN
        BEGIN
            SELECT bed_id, patient_id, admission_status
            INTO v_bed_id, v_patient_id, v_status
            FROM admission
            WHERE admission_id = p_admission_id
            FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20006, 'Admission does not exist');
        END;

        IF v_status <> 'ADMITTED' THEN
            RAISE_APPLICATION_ERROR(-20005, 'Patient is not currently admitted');
        END IF;

        UPDATE admission
        SET admission_status = p_new_status,
            discharge_date = SYSDATE
        WHERE admission_id = p_admission_id;

        UPDATE bed
        SET bed_status = 'AWAITING_CLEANING'
        WHERE bed_id = v_bed_id;

        log_action(v_patient_id, v_bed_id, NULL, p_admission_id, 'RELEASED', p_reason, NULL);

        -- Lab tests still waiting to be done for this stay will not be done now
        UPDATE lab_order
        SET order_status = 'CANCELLED',
            cancel_reason = CASE p_new_status WHEN 'DISCHARGED' THEN 'Patient discharged'
                                              ELSE 'Admission cancelled' END
        WHERE admission_id = p_admission_id
        AND order_status = 'ORDERED';
        v_cancelled_orders := SQL%ROWCOUNT;

        p_message := 'Admission ' || p_admission_id || ' ' || LOWER(p_new_status) || '; '
            || bed_label(v_bed_id) || ' is now awaiting cleaning.'
            || CASE WHEN v_cancelled_orders > 0
                    THEN ' ' || v_cancelled_orders || ' pending lab order(s) were cancelled.'
               END;
    END close_admission;


    PROCEDURE discharge_patient (p_admission_id IN NUMBER, p_message OUT VARCHAR2) IS
    BEGIN
        pkg_security.assert_role('ADMIN,DOCTOR');
        close_admission(p_admission_id, 'DISCHARGED', 'Discharged', p_message);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END discharge_patient;


    PROCEDURE cancel_admission (p_admission_id IN NUMBER, p_reason IN VARCHAR2, p_message OUT VARCHAR2) IS
    BEGIN
        pkg_security.assert_role('ADMIN');
        close_admission(p_admission_id, 'CANCELLED', 'Admission cancelled: ' || p_reason, p_message);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END cancel_admission;


    PROCEDURE set_bed_status (p_bed_id IN NUMBER, p_status IN VARCHAR2, p_message OUT VARCHAR2) IS
        v_allocated NUMBER := 0;
        v_count NUMBER;
    BEGIN
        pkg_security.assert_role('ADMIN,NURSE');

        IF p_status NOT IN ('AVAILABLE','MAINTENANCE') THEN
            RAISE_APPLICATION_ERROR(-20024, 'A bed can only be set to AVAILABLE or MAINTENANCE; OCCUPIED is set by admissions');
        END IF;

        SELECT COUNT(*) INTO v_count FROM bed WHERE bed_id = p_bed_id;
        IF v_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20004, 'Bed does not exist');
        END IF;

        UPDATE bed
        SET bed_status = p_status
        WHERE bed_id = p_bed_id;

        IF p_status = 'AVAILABLE' THEN
            v_allocated := run_queue;
        END IF;

        p_message := bed_label(p_bed_id) || ' set to ' || p_status || '.'
            || CASE WHEN v_allocated > 0
                    THEN ' ' || v_allocated || ' waiting patient(s) were allocated beds from the queue.'
               END;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END set_bed_status;


    -- Locks the bed and returns its status; raises if it does not exist
    FUNCTION lock_bed_status (p_bed_id IN NUMBER) RETURN VARCHAR2 IS
        v_status bed.bed_status%TYPE;
    BEGIN
        SELECT bed_status INTO v_status
        FROM bed
        WHERE bed_id = p_bed_id
        FOR UPDATE;
        RETURN v_status;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20004, 'Bed does not exist');
    END lock_bed_status;


    PROCEDURE mark_bed_cleaned (p_bed_id IN NUMBER, p_message OUT VARCHAR2) IS
        v_status bed.bed_status%TYPE;
    BEGIN
        pkg_security.assert_role('ADMIN,NURSE');

        v_status := lock_bed_status(p_bed_id);
        IF v_status <> 'AWAITING_CLEANING' THEN
            RAISE_APPLICATION_ERROR(-20071, bed_label(p_bed_id) || ' is ' || v_status
                || ', not awaiting cleaning');
        END IF;

        UPDATE bed SET bed_status = 'AWAITING_INSPECTION' WHERE bed_id = p_bed_id;

        p_message := bed_label(p_bed_id) || ' cleaned; now awaiting inspection.';
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END mark_bed_cleaned;


    PROCEDURE inspect_bed (p_bed_id IN NUMBER, p_passed IN VARCHAR2, p_message OUT VARCHAR2) IS
        v_status bed.bed_status%TYPE;
        v_allocated NUMBER := 0;
    BEGIN
        pkg_security.assert_role('ADMIN,NURSE');

        IF p_passed IS NULL OR UPPER(p_passed) NOT IN ('Y','N') THEN
            RAISE_APPLICATION_ERROR(-20073, 'Inspection result must be Y (passed) or N (failed)');
        END IF;

        v_status := lock_bed_status(p_bed_id);
        IF v_status <> 'AWAITING_INSPECTION' THEN
            RAISE_APPLICATION_ERROR(-20072, bed_label(p_bed_id) || ' is ' || v_status
                || ', not awaiting inspection');
        END IF;

        IF UPPER(p_passed) = 'Y' THEN
            UPDATE bed SET bed_status = 'AVAILABLE' WHERE bed_id = p_bed_id;
            -- The bed is really free now, so serve the waiting queue
            v_allocated := run_queue;
            p_message := bed_label(p_bed_id) || ' passed inspection and is available.'
                || CASE WHEN v_allocated > 0
                        THEN ' ' || v_allocated || ' waiting patient(s) were allocated beds from the queue.'
                   END;
        ELSE
            UPDATE bed SET bed_status = 'AWAITING_CLEANING' WHERE bed_id = p_bed_id;
            p_message := bed_label(p_bed_id) || ' failed inspection; sent back for cleaning.';
        END IF;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END inspect_bed;

END pkg_bed_allocation;
/
