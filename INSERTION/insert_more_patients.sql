INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Aditi',
    'Rao',
    TO_DATE('2016-03-18','YYYY-MM-DD'),
    'Female',
    '9000000012',
    'Bangalore',
    'B+'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Vihaan',
    'Singh',
    TO_DATE('1995-07-09','YYYY-MM-DD'),
    'Male',
    '9000000013',
    'Delhi',
    'O+'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Ananya',
    'Iyer',
    TO_DATE('1989-11-23','YYYY-MM-DD'),
    'Female',
    '9000000014',
    'Chennai',
    'A+'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Arjun',
    'Desai',
    TO_DATE('1956-01-14','YYYY-MM-DD'),
    'Male',
    '9000000015',
    'Ahmedabad',
    'AB+'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Kavya',
    'Menon',
    TO_DATE('2003-09-30','YYYY-MM-DD'),
    'Female',
    '9000000016',
    'Kochi',
    'O-'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Reyansh',
    'Verma',
    TO_DATE('2014-05-06','YYYY-MM-DD'),
    'Male',
    '9000000017',
    'Lucknow',
    'A-'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Priya',
    'Banerjee',
    TO_DATE('1978-02-27','YYYY-MM-DD'),
    'Female',
    '9000000018',
    'Kolkata',
    'B-'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Siddharth',
    'Kulkarni',
    TO_DATE('1968-08-15','YYYY-MM-DD'),
    'Male',
    '9000000019',
    'Pune',
    'O+'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Nisha',
    'Choudhary',
    TO_DATE('1951-12-04','YYYY-MM-DD'),
    'Female',
    '9000000020',
    'Jaipur',
    'AB-'
);

INSERT INTO patient
VALUES (
    patient_seq.NEXTVAL,
    'Yash',
    'Malhotra',
    TO_DATE('1999-04-21','YYYY-MM-DD'),
    'Male',
    '9000000021',
    'Chandigarh',
    'B+'
);

COMMIT;
