-- LAB TEST ORDERS
-- A doctor or nurse orders a test for an admitted patient; the lab completes the order by entering
-- the result (which creates the lab_result row that billing already charges for).
-- Safe to run more than once: used by install.sql and by migrate_lab_orders.sql.

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
        CREATE TABLE lab_order (
            order_id NUMBER PRIMARY KEY,
            admission_id NUMBER NOT NULL,
            test_id NUMBER NOT NULL,
            ordered_by NUMBER NOT NULL,
            ordered_at DATE DEFAULT SYSDATE NOT NULL,
            priority VARCHAR2(10) DEFAULT 'ROUTINE' NOT NULL,
            order_status VARCHAR2(20) DEFAULT 'ORDERED' NOT NULL,
            notes VARCHAR2(500),
            result_id NUMBER,
            completed_at DATE,
            cancel_reason VARCHAR2(200),
            CONSTRAINT fk_order_admission FOREIGN KEY (admission_id) REFERENCES admission(admission_id),
            CONSTRAINT fk_order_test FOREIGN KEY (test_id) REFERENCES lab_test(test_id),
            CONSTRAINT fk_order_staff FOREIGN KEY (ordered_by) REFERENCES staff(staff_id),
            CONSTRAINT fk_order_result FOREIGN KEY (result_id) REFERENCES lab_result(result_id),
            CONSTRAINT uq_order_result UNIQUE (result_id),
            CONSTRAINT ck_order_priority CHECK (priority IN ('ROUTINE','URGENT')),
            CONSTRAINT ck_order_status CHECK (order_status IN ('ORDERED','COMPLETED','CANCELLED')),
            CONSTRAINT ck_order_completed CHECK (order_status <> 'COMPLETED' OR result_id IS NOT NULL)
        )]');
    run_ddl('CREATE SEQUENCE lab_order_seq START WITH 1 INCREMENT BY 1');

    -- At most one open order for the same test on the same admission
    run_ddl(q'[
        CREATE UNIQUE INDEX uq_open_lab_order ON lab_order (
            CASE WHEN order_status = 'ORDERED' THEN admission_id END,
            CASE WHEN order_status = 'ORDERED' THEN test_id END)]');

    run_ddl('CREATE INDEX ix_lab_order_status ON lab_order (order_status, priority, ordered_at)');
END;
/
