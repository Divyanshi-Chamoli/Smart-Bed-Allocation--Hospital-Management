-- HOSPITAL MANAGEMENT SYSTEM

CREATE TABLE patient (
    patient_id NUMBER PRIMARY KEY,
    first_name VARCHAR2(50) NOT NULL,
    last_name VARCHAR2(50) NOT NULL,
    dob DATE NOT NULL,
    gender VARCHAR2(10) NOT NULL CHECK (gender IN ('Male','Female','Other')),
    phone VARCHAR2(15) UNIQUE,
    address VARCHAR2(200),
    blood_group VARCHAR2(5) CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-'))
);

CREATE TABLE staff (
    staff_id NUMBER PRIMARY KEY,
    staff_name VARCHAR2(100) NOT NULL,
    designation VARCHAR2(50) NOT NULL,
    department VARCHAR2(50),
    phone VARCHAR2(15) UNIQUE,
    email VARCHAR2(100) UNIQUE
);

CREATE TABLE ward (
    ward_id NUMBER PRIMARY KEY,
    ward_name VARCHAR2(50) NOT NULL UNIQUE,
    ward_type VARCHAR2(30) NOT NULL,
    floor_no NUMBER NOT NULL CHECK (floor_no >= 0),
    capacity NUMBER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE bed (
    bed_id NUMBER PRIMARY KEY,
    ward_id NUMBER NOT NULL,
    bed_number VARCHAR2(10) NOT NULL,
    bed_status VARCHAR2(20) DEFAULT 'AVAILABLE' NOT NULL CHECK (bed_status IN ('AVAILABLE','OCCUPIED','MAINTENANCE')),
    CONSTRAINT fk_bed_ward FOREIGN KEY (ward_id) REFERENCES ward(ward_id),
    CONSTRAINT uq_bed_number UNIQUE (ward_id, bed_number)
);

CREATE TABLE admission (
    admission_id NUMBER PRIMARY KEY,
    patient_id NUMBER NOT NULL,
    bed_id NUMBER NOT NULL,
    doctor_id NUMBER NOT NULL,
    admission_date DATE DEFAULT SYSDATE NOT NULL,
    discharge_date DATE,
    admission_status VARCHAR2(20) DEFAULT 'ADMITTED' NOT NULL CHECK (admission_status IN ('ADMITTED','DISCHARGED','CANCELLED')),
    CONSTRAINT fk_admission_patient FOREIGN KEY (patient_id) REFERENCES patient(patient_id),
    CONSTRAINT fk_admission_bed FOREIGN KEY (bed_id) REFERENCES bed(bed_id),
    CONSTRAINT fk_admission_doctor FOREIGN KEY (doctor_id) REFERENCES staff(staff_id)
);

CREATE TABLE lab_test (
    test_id NUMBER PRIMARY KEY,
    test_name VARCHAR2(100) NOT NULL UNIQUE,
    test_cost NUMBER(10,2) NOT NULL CHECK (test_cost >= 0)
);

CREATE TABLE lab_result (
    result_id NUMBER PRIMARY KEY,
    admission_id NUMBER NOT NULL,
    test_id NUMBER NOT NULL,
    staff_id NUMBER NOT NULL,
    test_date DATE DEFAULT SYSDATE NOT NULL,
    result_value VARCHAR2(500),
    remarks VARCHAR2(500),
    CONSTRAINT fk_result_admission FOREIGN KEY (admission_id) REFERENCES admission(admission_id),
    CONSTRAINT fk_result_test FOREIGN KEY (test_id) REFERENCES lab_test(test_id),
    CONSTRAINT fk_result_staff FOREIGN KEY (staff_id) REFERENCES staff(staff_id)
);

CREATE TABLE bill (
    bill_id NUMBER PRIMARY KEY,
    admission_id NUMBER NOT NULL,
    bill_date DATE DEFAULT SYSDATE NOT NULL,
    total_amount NUMBER(10,2) DEFAULT 0 NOT NULL CHECK (total_amount >= 0),
    payment_status VARCHAR2(20) DEFAULT 'PENDING' NOT NULL CHECK (payment_status IN ('PENDING','PAID','PARTIAL')),
    CONSTRAINT fk_bill_admission FOREIGN KEY (admission_id) REFERENCES admission(admission_id)
);

CREATE TABLE bill_item (
    bill_item_id NUMBER PRIMARY KEY,
    bill_id NUMBER NOT NULL,
    description VARCHAR2(200) NOT NULL,
    quantity NUMBER NOT NULL CHECK (quantity > 0),
    unit_price NUMBER(10,2) NOT NULL CHECK (unit_price >= 0),
    amount NUMBER(10,2) NOT NULL CHECK (amount >= 0),
    CONSTRAINT fk_bill_item_bill FOREIGN KEY (bill_id) REFERENCES bill(bill_id)
);

CREATE TABLE role (
    role_id NUMBER PRIMARY KEY,
    role_name VARCHAR2(30) NOT NULL UNIQUE
);

CREATE TABLE user_account (
    user_id NUMBER PRIMARY KEY,
    staff_id NUMBER NOT NULL UNIQUE,
    role_id NUMBER NOT NULL,
    username VARCHAR2(50) NOT NULL UNIQUE,
    password VARCHAR2(100) NOT NULL,
    account_status VARCHAR2(20) DEFAULT 'ACTIVE' NOT NULL CHECK (account_status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT fk_user_staff FOREIGN KEY (staff_id) REFERENCES staff(staff_id),
    CONSTRAINT fk_user_role FOREIGN KEY (role_id) REFERENCES role(role_id)
);

COMMIT;

PROMPT =====================================
PROMPT HOSPITAL DATABASE CREATED
PROMPT =====================================

SELECT table_name
FROM user_tables
WHERE table_name IN (
    'PATIENT',
    'STAFF',
    'WARD',
    'BED',
    'ADMISSION',
    'LAB_TEST',
    'LAB_RESULT',
    'BILL',
    'BILL_ITEM',
    'ROLE',
    'USER_ACCOUNT'
)
ORDER BY table_name;