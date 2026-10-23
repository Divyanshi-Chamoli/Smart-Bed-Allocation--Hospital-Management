-- Original entry points, kept for compatibility.
-- They now delegate to pkg_bed_allocation, which adds role checks, rule validation,
-- double-booking protection and automatic waiting-queue processing.

CREATE OR REPLACE PROCEDURE admit_patient (
    p_patient_id IN NUMBER,
    p_bed_id IN NUMBER,
    p_doctor_id IN NUMBER
)
AS
    v_ward_type ward.ward_type%TYPE;
    v_admission_id NUMBER;
    v_message VARCHAR2(500);
BEGIN

    BEGIN
        SELECT w.ward_type
        INTO v_ward_type
        FROM bed b
        JOIN ward w ON w.ward_id = b.ward_id
        WHERE b.bed_id = p_bed_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20004, 'Bed does not exist');
    END;

    pkg_bed_allocation.allocate_specific_bed(
        p_patient_id,
        p_doctor_id,
        p_bed_id,
        v_ward_type,
        'MEDIUM',
        v_admission_id,
        v_message
    );

    DBMS_OUTPUT.PUT_LINE(
        'Patient admitted successfully. Admission ID: '
        || v_admission_id
    );

END;
/


CREATE OR REPLACE PROCEDURE discharge_patient (
    p_admission_id IN NUMBER
)
AS
    v_message VARCHAR2(500);
BEGIN

    pkg_bed_allocation.discharge_patient(p_admission_id, v_message);

    DBMS_OUTPUT.PUT_LINE(v_message);

END;
/
