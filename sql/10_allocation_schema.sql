-- SMART BED ALLOCATION EXTENSION
-- Rule tables, prioritised waiting queue, allocation audit log
-- Run AFTER hospitalmanagement.sql, createseq.sql and the INSERTION scripts.

CREATE TABLE urgency_level (
    urgency_code VARCHAR2(10) PRIMARY KEY CHECK (urgency_code IN ('CRITICAL','HIGH','MEDIUM','LOW')),
    base_weight NUMBER NOT NULL CHECK (base_weight > 0),
    target_wait_minutes NUMBER NOT NULL CHECK (target_wait_minutes > 0),
    description VARCHAR2(200)
);

-- Which ward types may serve a request for a given ward type, in order of preference.
-- A fallback rule only applies when the patient's urgency weight >= min_urgency_weight.
CREATE TABLE ward_compatibility (
    rule_id NUMBER PRIMARY KEY,
    required_ward_type VARCHAR2(30) NOT NULL,
    allowed_ward_type VARCHAR2(30) NOT NULL,
    preference_rank NUMBER NOT NULL CHECK (preference_rank > 0),
    min_urgency_weight NUMBER DEFAULT 0 NOT NULL CHECK (min_urgency_weight >= 0),
    rule_description VARCHAR2(200),
    is_active CHAR(1) DEFAULT 'Y' NOT NULL CHECK (is_active IN ('Y','N')),
    CONSTRAINT uq_ward_compat UNIQUE (required_ward_type, allowed_ward_type)
);

-- Tunable numbers used by the allocation and priority rules
CREATE TABLE allocation_config (
    config_key VARCHAR2(40) PRIMARY KEY,
    config_value NUMBER NOT NULL CHECK (config_value >= 0),
    description VARCHAR2(200)
);

CREATE TABLE ward_tariff (
    ward_type VARCHAR2(30) PRIMARY KEY,
    daily_rate NUMBER(10,2) NOT NULL CHECK (daily_rate >= 0)
);

CREATE TABLE waiting_queue (
    queue_id NUMBER PRIMARY KEY,
    patient_id NUMBER NOT NULL,
    doctor_id NUMBER NOT NULL,
    required_ward_type VARCHAR2(30) NOT NULL,
    urgency_code VARCHAR2(10) NOT NULL,
    request_time DATE DEFAULT SYSDATE NOT NULL,
    queue_status VARCHAR2(20) DEFAULT 'WAITING' NOT NULL CHECK (queue_status IN ('WAITING','ALLOCATED','CANCELLED')),
    allocated_bed_id NUMBER,
    admission_id NUMBER,
    resolved_time DATE,
    notes VARCHAR2(500),
    requested_by NUMBER,
    CONSTRAINT fk_queue_patient FOREIGN KEY (patient_id) REFERENCES patient(patient_id),
    CONSTRAINT fk_queue_doctor FOREIGN KEY (doctor_id) REFERENCES staff(staff_id),
    CONSTRAINT fk_queue_urgency FOREIGN KEY (urgency_code) REFERENCES urgency_level(urgency_code),
    CONSTRAINT fk_queue_bed FOREIGN KEY (allocated_bed_id) REFERENCES bed(bed_id),
    CONSTRAINT fk_queue_admission FOREIGN KEY (admission_id) REFERENCES admission(admission_id),
    CONSTRAINT fk_queue_user FOREIGN KEY (requested_by) REFERENCES user_account(user_id),
    CONSTRAINT ck_queue_resolved CHECK (queue_status = 'WAITING' OR resolved_time IS NOT NULL)
);

CREATE TABLE bed_allocation_log (
    log_id NUMBER PRIMARY KEY,
    patient_id NUMBER,
    bed_id NUMBER,
    queue_id NUMBER,
    admission_id NUMBER,
    action VARCHAR2(20) NOT NULL CHECK (action IN ('ALLOCATED','QUEUED','RELEASED','CANCELLED','BED_STATUS')),
    rule_applied VARCHAR2(300),
    priority_score NUMBER,
    acted_by VARCHAR2(50),
    acted_at DATE DEFAULT SYSDATE NOT NULL,
    CONSTRAINT fk_log_patient FOREIGN KEY (patient_id) REFERENCES patient(patient_id),
    CONSTRAINT fk_log_bed FOREIGN KEY (bed_id) REFERENCES bed(bed_id),
    CONSTRAINT fk_log_queue FOREIGN KEY (queue_id) REFERENCES waiting_queue(queue_id),
    CONSTRAINT fk_log_admission FOREIGN KEY (admission_id) REFERENCES admission(admission_id)
);

CREATE SEQUENCE ward_rule_seq START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE queue_seq START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE alloc_log_seq START WITH 1 INCREMENT BY 1;


-- Extensions to existing tables

-- Beds per ward that only CRITICAL patients may take (keeps the last ICU bed free for emergencies)
ALTER TABLE ward ADD (
    reserved_critical_beds NUMBER DEFAULT 0 NOT NULL CHECK (reserved_critical_beds >= 0)
);

ALTER TABLE admission ADD (
    urgency_code VARCHAR2(10),
    queue_id NUMBER,
    CONSTRAINT fk_admission_urgency FOREIGN KEY (urgency_code) REFERENCES urgency_level(urgency_code),
    CONSTRAINT fk_admission_queue FOREIGN KEY (queue_id) REFERENCES waiting_queue(queue_id),
    CONSTRAINT ck_admission_dates CHECK (discharge_date IS NULL OR discharge_date >= admission_date)
);

ALTER TABLE bill ADD (
    amount_paid NUMBER(10,2) DEFAULT 0 NOT NULL CHECK (amount_paid >= 0)
);

-- Where a billing line came from, so automatic charges are never billed twice
ALTER TABLE bill_item ADD (
    source_type VARCHAR2(10) DEFAULT 'MANUAL' NOT NULL CHECK (source_type IN ('BED','LAB','MANUAL')),
    lab_result_id NUMBER UNIQUE,
    CONSTRAINT fk_bill_item_lab FOREIGN KEY (lab_result_id) REFERENCES lab_result(result_id)
);

-- Optional link from an Oracle login to an application account (see 70_db_roles.sql)
ALTER TABLE user_account ADD (
    db_username VARCHAR2(30) UNIQUE
);


-- DOUBLE-BOOKING PREVENTION
-- Function-based unique indexes: rows that are not ADMITTED/WAITING map to NULL and are ignored,
-- so a bed can have many past admissions but only ONE active one.
CREATE UNIQUE INDEX uq_active_admission_bed
    ON admission (CASE WHEN admission_status = 'ADMITTED' THEN bed_id END);

CREATE UNIQUE INDEX uq_active_admission_patient
    ON admission (CASE WHEN admission_status = 'ADMITTED' THEN patient_id END);

CREATE UNIQUE INDEX uq_waiting_patient
    ON waiting_queue (CASE WHEN queue_status = 'WAITING' THEN patient_id END);

-- One bill per admission, and at most one bed-charge line per bill
CREATE UNIQUE INDEX uq_bill_admission ON bill (admission_id);

CREATE UNIQUE INDEX uq_bill_bed_line
    ON bill_item (CASE WHEN source_type = 'BED' THEN bill_id END);

-- Supporting indexes for lookups
CREATE INDEX ix_bed_ward_status ON bed (ward_id, bed_status);
CREATE INDEX ix_queue_status ON waiting_queue (queue_status, request_time);
CREATE INDEX ix_lab_result_admission ON lab_result (admission_id);
CREATE INDEX ix_bill_item_bill ON bill_item (bill_id);
