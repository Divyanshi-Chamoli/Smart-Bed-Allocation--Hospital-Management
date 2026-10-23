-- TRIGGERS
-- Run after 10_allocation_schema.sql


-- 1. Automatic primary keys: fill the ID from its sequence when the caller leaves it NULL

CREATE OR REPLACE TRIGGER trg_patient_id BEFORE INSERT ON patient FOR EACH ROW
WHEN (new.patient_id IS NULL)
BEGIN :new.patient_id := patient_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_staff_id BEFORE INSERT ON staff FOR EACH ROW
WHEN (new.staff_id IS NULL)
BEGIN :new.staff_id := staff_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_ward_id BEFORE INSERT ON ward FOR EACH ROW
WHEN (new.ward_id IS NULL)
BEGIN :new.ward_id := ward_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_bed_id BEFORE INSERT ON bed FOR EACH ROW
WHEN (new.bed_id IS NULL)
BEGIN :new.bed_id := bed_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_admission_id BEFORE INSERT ON admission FOR EACH ROW
WHEN (new.admission_id IS NULL)
BEGIN :new.admission_id := admission_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_lab_test_id BEFORE INSERT ON lab_test FOR EACH ROW
WHEN (new.test_id IS NULL)
BEGIN :new.test_id := lab_test_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_lab_result_id BEFORE INSERT ON lab_result FOR EACH ROW
WHEN (new.result_id IS NULL)
BEGIN :new.result_id := lab_result_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_bill_id BEFORE INSERT ON bill FOR EACH ROW
WHEN (new.bill_id IS NULL)
BEGIN :new.bill_id := bill_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_bill_item_id BEFORE INSERT ON bill_item FOR EACH ROW
WHEN (new.bill_item_id IS NULL)
BEGIN :new.bill_item_id := bill_item_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_role_id BEFORE INSERT ON role FOR EACH ROW
WHEN (new.role_id IS NULL)
BEGIN :new.role_id := role_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_user_id BEFORE INSERT ON user_account FOR EACH ROW
WHEN (new.user_id IS NULL)
BEGIN :new.user_id := user_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_ward_rule_id BEFORE INSERT ON ward_compatibility FOR EACH ROW
WHEN (new.rule_id IS NULL)
BEGIN :new.rule_id := ward_rule_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_queue_id BEFORE INSERT ON waiting_queue FOR EACH ROW
WHEN (new.queue_id IS NULL)
BEGIN :new.queue_id := queue_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_alloc_log_id BEFORE INSERT ON bed_allocation_log FOR EACH ROW
WHEN (new.log_id IS NULL)
BEGIN :new.log_id := alloc_log_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER trg_bed_history_id BEFORE INSERT ON bed_status_history FOR EACH ROW
WHEN (new.history_id IS NULL)
BEGIN :new.history_id := bed_history_seq.NEXTVAL; END;
/


-- 2. Admission integrity: doctor must be a Doctor, a new admission needs an AVAILABLE bed
--    (the bed row is locked so a concurrent transaction cannot take it in between),
--    the bed of an admission cannot be swapped and a closed admission cannot be reopened.

CREATE OR REPLACE TRIGGER trg_admission_guard
BEFORE INSERT OR UPDATE ON admission
FOR EACH ROW
DECLARE
    v_bed_status bed.bed_status%TYPE;
    v_designation staff.designation%TYPE;
BEGIN
    IF INSERTING THEN
        BEGIN
            SELECT designation INTO v_designation
            FROM staff
            WHERE staff_id = :new.doctor_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20002, 'Doctor does not exist');
        END;

        IF v_designation <> 'Doctor' THEN
            RAISE_APPLICATION_ERROR(-20014, 'Staff member ' || :new.doctor_id || ' is not a doctor');
        END IF;

        IF :new.admission_status = 'ADMITTED' THEN
            BEGIN
                SELECT bed_status INTO v_bed_status
                FROM bed
                WHERE bed_id = :new.bed_id
                FOR UPDATE;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    RAISE_APPLICATION_ERROR(-20004, 'Bed does not exist');
            END;

            IF v_bed_status <> 'AVAILABLE' THEN
                RAISE_APPLICATION_ERROR(-20010, 'Bed ' || :new.bed_id || ' is ' || v_bed_status || ', not AVAILABLE');
            END IF;
        END IF;

    ELSIF UPDATING THEN
        IF :new.bed_id <> :old.bed_id THEN
            RAISE_APPLICATION_ERROR(-20015, 'The bed of an existing admission cannot be changed');
        END IF;

        IF :old.admission_status <> 'ADMITTED' AND :new.admission_status <> :old.admission_status THEN
            RAISE_APPLICATION_ERROR(-20016, 'A ' || :old.admission_status || ' admission cannot be reopened');
        END IF;

        IF :new.admission_status IN ('DISCHARGED','CANCELLED') AND :new.discharge_date IS NULL THEN
            :new.discharge_date := SYSDATE;
        END IF;
    END IF;
END;
/


-- 3. Bed status life cycle. Allowed changes:
--      AVAILABLE           -> OCCUPIED             (only through an admission)
--      OCCUPIED            -> AWAITING_CLEANING    (only once the admission is discharged/cancelled)
--      AWAITING_CLEANING   -> AWAITING_INSPECTION  (cleaning done)
--      AWAITING_INSPECTION -> AVAILABLE            (inspection passed)
--      AWAITING_INSPECTION -> AWAITING_CLEANING    (inspection failed)
--      AVAILABLE / AWAITING_CLEANING / AWAITING_INSPECTION -> MAINTENANCE, MAINTENANCE -> AVAILABLE
--    Every change is written to bed_status_history (for turnaround times) and bed_allocation_log.

CREATE OR REPLACE TRIGGER trg_bed_status_guard
BEFORE UPDATE OF bed_status ON bed
FOR EACH ROW
WHEN (new.bed_status <> old.bed_status)
DECLARE
    v_active_admission NUMBER;
    v_last_admission NUMBER;
    v_transition VARCHAR2(50) := :old.bed_status || '>' || :new.bed_status;
BEGIN
    SELECT MAX(admission_id) INTO v_active_admission
    FROM admission
    WHERE bed_id = :new.bed_id
    AND admission_status = 'ADMITTED';

    IF :new.bed_status = 'OCCUPIED' THEN
        IF :old.bed_status = 'MAINTENANCE' THEN
            RAISE_APPLICATION_ERROR(-20013, 'A bed under maintenance must be made AVAILABLE first');
        END IF;
        IF v_active_admission IS NULL THEN
            RAISE_APPLICATION_ERROR(-20011, 'A bed can only become OCCUPIED through an admission');
        END IF;
    ELSIF v_active_admission IS NOT NULL THEN
        RAISE_APPLICATION_ERROR(-20012, 'Bed ' || :new.bed_id || ' has an active admission');
    END IF;

    IF v_transition NOT IN (
        'AVAILABLE>OCCUPIED',
        'OCCUPIED>AWAITING_CLEANING',
        'AWAITING_CLEANING>AWAITING_INSPECTION',
        'AWAITING_INSPECTION>AVAILABLE',
        'AWAITING_INSPECTION>AWAITING_CLEANING',
        'AVAILABLE>MAINTENANCE',
        'AWAITING_CLEANING>MAINTENANCE',
        'AWAITING_INSPECTION>MAINTENANCE',
        'MAINTENANCE>AVAILABLE'
    ) THEN
        RAISE_APPLICATION_ERROR(-20070, 'Illegal bed status change ' || :old.bed_status || ' -> '
            || :new.bed_status || ' for bed ' || :new.bed_id);
    END IF;

    -- Link the history row to the admission that filled or just vacated the bed
    IF :old.bed_status = 'OCCUPIED' THEN
        SELECT MAX(admission_id) KEEP (DENSE_RANK LAST ORDER BY discharge_date NULLS FIRST, admission_id)
        INTO v_last_admission
        FROM admission
        WHERE bed_id = :new.bed_id;
    END IF;

    INSERT INTO bed_status_history (bed_id, from_status, to_status, admission_id, changed_by, changed_at)
    VALUES (:new.bed_id, :old.bed_status, :new.bed_status,
            COALESCE(v_active_admission, v_last_admission),
            NVL(SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'), USER), SYSDATE);

    INSERT INTO bed_allocation_log (bed_id, action, rule_applied, acted_by)
    VALUES (:new.bed_id, 'BED_STATUS', :old.bed_status || ' -> ' || :new.bed_status,
            SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'));
END;
/


-- 4. Billing

-- A line's amount is always quantity x unit price
CREATE OR REPLACE TRIGGER trg_bill_item_amount
BEFORE INSERT OR UPDATE OF quantity, unit_price, amount ON bill_item
FOR EACH ROW
BEGIN
    :new.amount := :new.quantity * :new.unit_price;
END;
/

-- Lines of a fully paid bill are frozen
CREATE OR REPLACE TRIGGER trg_bill_item_paid_lock
BEFORE INSERT OR UPDATE OR DELETE ON bill_item
FOR EACH ROW
DECLARE
    v_status bill.payment_status%TYPE;
BEGIN
    SELECT payment_status INTO v_status
    FROM bill
    WHERE bill_id = NVL(:new.bill_id, :old.bill_id);

    IF v_status = 'PAID' THEN
        RAISE_APPLICATION_ERROR(-20041, 'Bill ' || NVL(:new.bill_id, :old.bill_id) || ' is already PAID');
    END IF;
END;
/

-- Keep bill.total_amount equal to the sum of its lines.
-- Compound trigger: collect bill ids per row, update bill once after the statement
-- (avoids ORA-04091 mutating table on bill_item).
CREATE OR REPLACE TRIGGER trg_bill_total_sync
FOR INSERT OR UPDATE OR DELETE ON bill_item
COMPOUND TRIGGER

    TYPE t_bill_set IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    g_bills t_bill_set;

    AFTER EACH ROW IS
    BEGIN
        IF :new.bill_id IS NOT NULL THEN g_bills(:new.bill_id) := 1; END IF;
        IF :old.bill_id IS NOT NULL THEN g_bills(:old.bill_id) := 1; END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_bill_id PLS_INTEGER;
    BEGIN
        v_bill_id := g_bills.FIRST;
        WHILE v_bill_id IS NOT NULL LOOP
            UPDATE bill
            SET total_amount = (SELECT NVL(SUM(amount), 0) FROM bill_item WHERE bill_id = v_bill_id)
            WHERE bill_id = v_bill_id;
            v_bill_id := g_bills.NEXT(v_bill_id);
        END LOOP;
        g_bills.DELETE;
    END AFTER STATEMENT;

END trg_bill_total_sync;
/

-- Payment status is derived from amount_paid vs total_amount
CREATE OR REPLACE TRIGGER trg_bill_payment_status
BEFORE INSERT OR UPDATE OF total_amount, amount_paid, payment_status ON bill
FOR EACH ROW
BEGIN
    IF :new.amount_paid > :new.total_amount THEN
        RAISE_APPLICATION_ERROR(-20040, 'Amount paid (' || :new.amount_paid
            || ') cannot exceed the bill total (' || :new.total_amount || ')');
    END IF;

    :new.payment_status := CASE
        WHEN :new.amount_paid = 0 THEN 'PENDING'
        WHEN :new.amount_paid >= :new.total_amount THEN 'PAID'
        ELSE 'PARTIAL'
    END;
END;
/


-- 5. Passwords are stored as SHA-256 hex. Plain text written by any insert/update is hashed here.

CREATE OR REPLACE TRIGGER trg_user_password_hash
BEFORE INSERT OR UPDATE OF password ON user_account
FOR EACH ROW
DECLARE
    v_hash user_account.password%TYPE;
BEGIN
    IF NOT REGEXP_LIKE(:new.password, '^[0-9A-F]{64}$') THEN
        SELECT RAWTOHEX(STANDARD_HASH(:new.password, 'SHA256'))
        INTO v_hash
        FROM dual;
        :new.password := v_hash;
    END IF;
END;
/
