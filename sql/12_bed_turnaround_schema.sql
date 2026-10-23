-- BED TURNAROUND TRACKING: extra bed states and status history
-- Safe to run more than once: used by install.sql and by migrate_bed_turnaround.sql.

-- 1. Replace the bed_status CHECK. The original one from hospitalmanagement.sql has a
--    system-generated name, so find it in USER_CONSTRAINTS instead of guessing.
DECLARE
    v_exists NUMBER;
BEGIN
    FOR c IN (
        SELECT uc.constraint_name, uc.search_condition_vc
        FROM user_constraints uc
        JOIN user_cons_columns cc ON cc.constraint_name = uc.constraint_name
        WHERE uc.table_name = 'BED'
        AND uc.constraint_type = 'C'
        AND cc.column_name = 'BED_STATUS'
        AND uc.constraint_name <> 'CK_BED_STATUS'
    ) LOOP
        -- Skip the NOT NULL constraint; drop only the list of allowed values
        IF UPPER(c.search_condition_vc) LIKE '%BED_STATUS%IN%(%' THEN
            EXECUTE IMMEDIATE 'ALTER TABLE bed DROP CONSTRAINT ' || c.constraint_name;
        END IF;
    END LOOP;

    SELECT COUNT(*) INTO v_exists FROM user_constraints WHERE constraint_name = 'CK_BED_STATUS';
    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE q'[ALTER TABLE bed ADD CONSTRAINT ck_bed_status CHECK (bed_status IN
            ('AVAILABLE','OCCUPIED','AWAITING_CLEANING','AWAITING_INSPECTION','MAINTENANCE'))]';
    END IF;
END;
/


-- 2. One row per bed status change, written by trg_bed_status_guard
DECLARE
    PROCEDURE run_ddl (p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    EXCEPTION
        WHEN OTHERS THEN
            -- ORA-00955 name already used, ORA-01408 column list already indexed
            IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
    END;
BEGIN
    run_ddl(q'[
        CREATE TABLE bed_status_history (
            history_id NUMBER PRIMARY KEY,
            bed_id NUMBER NOT NULL,
            from_status VARCHAR2(20),
            to_status VARCHAR2(20) NOT NULL,
            admission_id NUMBER,
            changed_by VARCHAR2(50),
            changed_at DATE DEFAULT SYSDATE NOT NULL,
            CONSTRAINT fk_history_bed FOREIGN KEY (bed_id) REFERENCES bed(bed_id),
            CONSTRAINT fk_history_admission FOREIGN KEY (admission_id) REFERENCES admission(admission_id)
        )]');
    run_ddl('CREATE SEQUENCE bed_history_seq START WITH 1 INCREMENT BY 1');
    run_ddl('CREATE INDEX ix_bed_history_bed ON bed_status_history (bed_id, changed_at)');
END;
/
