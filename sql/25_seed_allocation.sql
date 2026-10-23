-- SEED DATA FOR THE ALLOCATION EXTENSION
-- Run after 20_triggers.sql

-- Urgency bands. Weights are spaced 30 apart and aging is capped (see allocation_config)
-- so a waiting patient can catch up with the band directly above but never overtake it.
INSERT INTO urgency_level VALUES ('CRITICAL', 100,  15, 'Life threatening - needs a bed immediately');
INSERT INTO urgency_level VALUES ('HIGH',      70,  60, 'Serious - admit within the hour');
INSERT INTO urgency_level VALUES ('MEDIUM',    40, 240, 'Stable but needs inpatient care');
INSERT INTO urgency_level VALUES ('LOW',       10, 720, 'Elective / observation');


-- Allocation rules: requested ward type -> ward types that may serve it, by preference.
-- min_urgency_weight: 0 = any patient, 70 = HIGH or above, 100 = CRITICAL only.
INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('ICU', 'ICU', 1, 0, 'Requested ward type');
INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('ICU', 'Emergency', 2, 100, 'ICU full: critical patient stabilised in Emergency');

INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('Emergency', 'Emergency', 1, 0, 'Requested ward type');
INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('Emergency', 'ICU', 2, 100, 'Emergency full: critical patient moved to ICU');
INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('Emergency', 'General', 3, 70, 'Emergency full: high urgency patient placed in General ward');

INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('General', 'General', 1, 0, 'Requested ward type');
INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('General', 'Emergency', 2, 70, 'General full: high urgency patient placed in Emergency');

INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('Pediatric', 'Pediatric', 1, 0, 'Requested ward type');
INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('Pediatric', 'General', 2, 40, 'Pediatric full: child placed in General ward');
INSERT INTO ward_compatibility (required_ward_type, allowed_ward_type, preference_rank, min_urgency_weight, rule_description)
VALUES ('Pediatric', 'ICU', 3, 100, 'Pediatric full: critical child moved to ICU');


INSERT INTO allocation_config VALUES ('AGING_INTERVAL_MIN', 15, 'Minutes of waiting that earn one aging step');
INSERT INTO allocation_config VALUES ('AGING_POINTS',        3, 'Priority points added per aging step');
INSERT INTO allocation_config VALUES ('AGING_CAP',          20, 'Maximum points a patient can gain from waiting');
INSERT INTO allocation_config VALUES ('OVERDUE_BONUS',       5, 'Extra points once the urgency band target wait is exceeded');
INSERT INTO allocation_config VALUES ('VULNERABLE_BONUS',    4, 'Extra points for children and elderly patients');
INSERT INTO allocation_config VALUES ('PEDIATRIC_MAX_AGE',  14, 'Patients younger than this are treated as children');
INSERT INTO allocation_config VALUES ('ELDERLY_MIN_AGE',    65, 'Patients this age or older are treated as elderly');
INSERT INTO allocation_config VALUES ('RECOMMEND_TOP_N',     5, 'How many candidate beds the recommender returns');


INSERT INTO ward_tariff VALUES ('General',   1500);
INSERT INTO ward_tariff VALUES ('ICU',       8000);
INSERT INTO ward_tariff VALUES ('Emergency', 4000);
INSERT INTO ward_tariff VALUES ('Pediatric', 2000);


-- Keep one ICU bed and one Emergency bed for CRITICAL patients only
UPDATE ward SET reserved_critical_beds = 1 WHERE ward_type IN ('ICU','Emergency');


-- Hash the plain-text passwords from insert_user.sql (trg_user_password_hash fires on update)
UPDATE user_account SET password = password;


-- Extra demo staff and patients
INSERT INTO staff (staff_name, designation, department, phone, email)
VALUES ('Dr. Kavya Iyer', 'Doctor', 'Emergency Medicine', '9876543216', 'kavya@hospital.com');
INSERT INTO staff (staff_name, designation, department, phone, email)
VALUES ('Dr. Sameer Khan', 'Doctor', 'Pediatrics', '9876543217', 'sameer@hospital.com');

INSERT INTO user_account (staff_id, role_id, username, password, account_status)
SELECT staff_id, (SELECT role_id FROM role WHERE role_name = 'DOCTOR'), 'kavya', 'kavya123', 'ACTIVE'
FROM staff WHERE email = 'kavya@hospital.com';

INSERT INTO patient (first_name, last_name, dob, gender, phone, address, blood_group)
VALUES ('Ishaan', 'Reddy', DATE '2019-06-10', 'Male', '9000000006', 'Hyderabad', 'B-');
INSERT INTO patient (first_name, last_name, dob, gender, phone, address, blood_group)
VALUES ('Lakshmi', 'Pillai', DATE '1948-02-14', 'Female', '9000000007', 'Chennai', 'A-');
INSERT INTO patient (first_name, last_name, dob, gender, phone, address, blood_group)
VALUES ('Farhan', 'Ali', DATE '1992-09-03', 'Male', '9000000008', 'Mumbai', 'O+');
INSERT INTO patient (first_name, last_name, dob, gender, phone, address, blood_group)
VALUES ('Sneha', 'Gupta', DATE '2001-12-25', 'Female', '9000000009', 'Pune', 'AB-');

COMMIT;
