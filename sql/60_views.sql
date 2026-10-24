-- REPORTING VIEWS

CREATE OR REPLACE VIEW v_bed_occupancy AS
SELECT w.ward_id,
       w.ward_name,
       w.ward_type,
       w.floor_no,
       w.capacity,
       w.reserved_critical_beds,
       COUNT(b.bed_id) AS total_beds,
       SUM(CASE WHEN b.bed_status = 'AVAILABLE' THEN 1 ELSE 0 END) AS available_beds,
       SUM(CASE WHEN b.bed_status = 'OCCUPIED' THEN 1 ELSE 0 END) AS occupied_beds,
       SUM(CASE WHEN b.bed_status = 'AWAITING_CLEANING' THEN 1 ELSE 0 END) AS awaiting_cleaning_beds,
       SUM(CASE WHEN b.bed_status = 'AWAITING_INSPECTION' THEN 1 ELSE 0 END) AS awaiting_inspection_beds,
       SUM(CASE WHEN b.bed_status = 'MAINTENANCE' THEN 1 ELSE 0 END) AS maintenance_beds,
       -- Beds still being turned around after a discharge are in use, not free
       ROUND(100 * SUM(CASE WHEN b.bed_status IN ('OCCUPIED','AWAITING_CLEANING','AWAITING_INSPECTION')
                            THEN 1 ELSE 0 END)
             / NULLIF(COUNT(b.bed_id), 0), 1) AS occupancy_pct
FROM ward w
LEFT JOIN bed b ON b.ward_id = w.ward_id
GROUP BY w.ward_id, w.ward_name, w.ward_type, w.floor_no, w.capacity, w.reserved_critical_beds;


-- When each bed entered its current status. Uses the latest history row only if it matches the
-- current status (beds changed before history existed have none); occupied beds fall back to
-- the admission date.
CREATE OR REPLACE VIEW v_bed_status_since AS
SELECT b.bed_id,
       b.bed_status,
       CASE
           WHEN lh.last_to_status = b.bed_status THEN lh.last_changed_at
           WHEN b.bed_status = 'OCCUPIED' THEN a.admission_date
       END AS status_since
FROM bed b
LEFT JOIN (
    SELECT bed_id,
           MAX(changed_at) KEEP (DENSE_RANK LAST ORDER BY changed_at, history_id) AS last_changed_at,
           MAX(to_status) KEEP (DENSE_RANK LAST ORDER BY changed_at, history_id) AS last_to_status
    FROM bed_status_history
    GROUP BY bed_id
) lh ON lh.bed_id = b.bed_id
LEFT JOIN admission a ON a.bed_id = b.bed_id AND a.admission_status = 'ADMITTED';


CREATE OR REPLACE VIEW v_bed_board AS
SELECT b.bed_id,
       b.bed_number,
       b.bed_status,
       w.ward_id,
       w.ward_name,
       w.ward_type,
       a.admission_id,
       a.urgency_code,
       a.admission_date,
       p.patient_id,
       NVL2(p.patient_id, p.first_name || ' ' || p.last_name, NULL) AS patient_name,
       s.status_since
FROM bed b
JOIN ward w ON w.ward_id = b.ward_id
LEFT JOIN admission a ON a.bed_id = b.bed_id AND a.admission_status = 'ADMITTED'
LEFT JOIN patient p ON p.patient_id = a.patient_id
LEFT JOIN v_bed_status_since s ON s.bed_id = b.bed_id;


CREATE OR REPLACE VIEW v_current_admissions AS
SELECT a.admission_id,
       a.admission_date,
       ROUND(SYSDATE - a.admission_date, 1) AS days_admitted,
       a.urgency_code,
       p.patient_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       FLOOR(MONTHS_BETWEEN(SYSDATE, p.dob) / 12) AS age,
       p.gender,
       p.blood_group,
       w.ward_name,
       w.ward_type,
       b.bed_id,
       b.bed_number,
       s.staff_id AS doctor_id,
       s.staff_name AS doctor_name,
       a.queue_id
FROM admission a
JOIN patient p ON p.patient_id = a.patient_id
JOIN bed b ON b.bed_id = a.bed_id
JOIN ward w ON w.ward_id = b.ward_id
JOIN staff s ON s.staff_id = a.doctor_id
WHERE a.admission_status = 'ADMITTED';


CREATE OR REPLACE VIEW v_waiting_queue_ranked AS
SELECT ROW_NUMBER() OVER (ORDER BY q.priority_score DESC, q.request_time, q.queue_id) AS queue_position,
       q.*
FROM (
    SELECT wq.queue_id,
           wq.patient_id,
           p.first_name || ' ' || p.last_name AS patient_name,
           FLOOR(MONTHS_BETWEEN(SYSDATE, p.dob) / 12) AS age,
           wq.required_ward_type,
           wq.urgency_code,
           u.base_weight,
           pkg_bed_allocation.priority_score(wq.queue_id) AS priority_score,
           wq.request_time,
           ROUND((SYSDATE - wq.request_time) * 1440) AS minutes_waiting,
           u.target_wait_minutes,
           CASE WHEN (SYSDATE - wq.request_time) * 1440 > u.target_wait_minutes THEN 'Y' ELSE 'N' END AS overdue,
           s.staff_name AS doctor_name,
           wq.notes
    FROM waiting_queue wq
    JOIN patient p ON p.patient_id = wq.patient_id
    JOIN urgency_level u ON u.urgency_code = wq.urgency_code
    JOIN staff s ON s.staff_id = wq.doctor_id
    WHERE wq.queue_status = 'WAITING'
) q;


CREATE OR REPLACE VIEW v_unpaid_bills AS
SELECT bl.bill_id,
       bl.bill_date,
       bl.admission_id,
       p.patient_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       a.admission_status,
       bl.total_amount,
       bl.amount_paid,
       bl.total_amount - bl.amount_paid AS balance_due,
       bl.payment_status
FROM bill bl
JOIN admission a ON a.admission_id = bl.admission_id
JOIN patient p ON p.patient_id = a.patient_id
WHERE bl.payment_status <> 'PAID';


CREATE OR REPLACE VIEW v_bill_summary AS
SELECT bl.bill_id,
       bl.bill_date,
       bl.admission_id,
       p.patient_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       a.admission_status,
       bl.total_amount,
       bl.amount_paid,
       bl.total_amount - bl.amount_paid AS balance_due,
       bl.payment_status,
       (SELECT COUNT(*) FROM bill_item bi WHERE bi.bill_id = bl.bill_id) AS item_count
FROM bill bl
JOIN admission a ON a.admission_id = bl.admission_id
JOIN patient p ON p.patient_id = a.patient_id;


-- Admissions that have ended but have no bill or unbilled lab work
CREATE OR REPLACE VIEW v_admissions_to_bill AS
SELECT a.admission_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       a.admission_status,
       a.admission_date,
       a.discharge_date,
       bl.bill_id,
       (SELECT COUNT(*) FROM lab_result r
        WHERE r.admission_id = a.admission_id
        AND NOT EXISTS (SELECT 1 FROM bill_item bi WHERE bi.lab_result_id = r.result_id)) AS unbilled_labs
FROM admission a
JOIN patient p ON p.patient_id = a.patient_id
LEFT JOIN bill bl ON bl.admission_id = a.admission_id
WHERE a.admission_status = 'DISCHARGED'
AND (bl.bill_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM bill_item bi WHERE bi.bill_id = bl.bill_id AND bi.source_type = 'BED')
     OR EXISTS (SELECT 1 FROM lab_result r
                WHERE r.admission_id = a.admission_id
                AND NOT EXISTS (SELECT 1 FROM bill_item bi WHERE bi.lab_result_id = r.result_id)));


CREATE OR REPLACE VIEW v_lab_results_detail AS
SELECT r.result_id,
       r.test_date,
       r.admission_id,
       p.patient_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       t.test_id,
       t.test_name,
       t.test_cost,
       r.result_value,
       r.remarks,
       s.staff_name AS recorded_by
FROM lab_result r
JOIN admission a ON a.admission_id = r.admission_id
JOIN patient p ON p.patient_id = a.patient_id
JOIN lab_test t ON t.test_id = r.test_id
JOIN staff s ON s.staff_id = r.staff_id;


CREATE OR REPLACE VIEW v_doctor_workload AS
SELECT s.staff_id AS doctor_id,
       s.staff_name AS doctor_name,
       s.department,
       COUNT(CASE WHEN a.admission_status = 'ADMITTED' THEN 1 END) AS current_patients,
       COUNT(a.admission_id) AS total_admissions,
       (SELECT COUNT(*) FROM waiting_queue q
        WHERE q.doctor_id = s.staff_id AND q.queue_status = 'WAITING') AS patients_waiting
FROM staff s
LEFT JOIN admission a ON a.doctor_id = s.staff_id
WHERE s.designation = 'Doctor'
GROUP BY s.staff_id, s.staff_name, s.department;


CREATE OR REPLACE VIEW v_allocation_history AS
SELECT l.log_id,
       l.acted_at,
       l.action,
       l.patient_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       l.bed_id,
       w.ward_name,
       b.bed_number,
       l.queue_id,
       l.admission_id,
       l.priority_score,
       l.rule_applied,
       l.acted_by
FROM bed_allocation_log l
LEFT JOIN patient p ON p.patient_id = l.patient_id
LEFT JOIN bed b ON b.bed_id = l.bed_id
LEFT JOIN ward w ON w.ward_id = b.ward_id;


-- How long patients waited before getting a bed, per urgency band
CREATE OR REPLACE VIEW v_queue_wait_stats AS
SELECT u.urgency_code,
       u.base_weight,
       u.target_wait_minutes,
       COUNT(q.queue_id) AS requests,
       SUM(CASE WHEN q.queue_status = 'ALLOCATED' THEN 1 ELSE 0 END) AS allocated,
       SUM(CASE WHEN q.queue_status = 'WAITING' THEN 1 ELSE 0 END) AS still_waiting,
       SUM(CASE WHEN q.queue_status = 'CANCELLED' THEN 1 ELSE 0 END) AS cancelled,
       ROUND(AVG(CASE WHEN q.queue_status = 'ALLOCATED'
                      THEN (q.resolved_time - q.request_time) * 1440 END), 1) AS avg_wait_minutes,
       ROUND(MAX(CASE WHEN q.queue_status = 'ALLOCATED'
                      THEN (q.resolved_time - q.request_time) * 1440 END), 1) AS max_wait_minutes
FROM urgency_level u
LEFT JOIN waiting_queue q ON q.urgency_code = u.urgency_code
GROUP BY u.urgency_code, u.base_weight, u.target_wait_minutes;


CREATE OR REPLACE VIEW v_patient_history AS
SELECT p.patient_id,
       NVL2(p.patient_id, p.first_name || ' ' || p.last_name, NULL) AS patient_name,
       a.admission_id,
       a.admission_date,
       a.discharge_date,
       a.admission_status,
       a.urgency_code,
       w.ward_name,
       b.bed_number,
       s.staff_name AS doctor_name,
       (SELECT COUNT(*) FROM lab_result r WHERE r.admission_id = a.admission_id) AS lab_tests,
       bl.total_amount AS bill_total,
       bl.payment_status
FROM patient p
JOIN admission a ON a.patient_id = p.patient_id
JOIN bed b ON b.bed_id = a.bed_id
JOIN ward w ON w.ward_id = b.ward_id
JOIN staff s ON s.staff_id = a.doctor_id
LEFT JOIN bill bl ON bl.admission_id = a.admission_id;


CREATE OR REPLACE VIEW v_user_accounts AS
SELECT u.user_id,
       u.username,
       r.role_name,
       u.account_status,
       s.staff_id,
       s.staff_name,
       s.designation,
       s.department
FROM user_account u
JOIN role r ON r.role_id = u.role_id
JOIN staff s ON s.staff_id = u.staff_id;


-- Lab orders with patient, location, who ordered and how long they have been waiting
CREATE OR REPLACE VIEW v_lab_orders AS
SELECT o.order_id,
       o.order_status,
       o.priority,
       o.ordered_at,
       o.completed_at,
       ROUND((NVL(o.completed_at, SYSDATE) - o.ordered_at) * 1440) AS minutes_open,
       o.notes,
       o.cancel_reason,
       o.admission_id,
       a.admission_status,
       p.patient_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       w.ward_name,
       b.bed_number,
       t.test_id,
       t.test_name,
       t.test_cost,
       s.staff_name AS ordered_by_name,
       o.result_id,
       r.result_value,
       r.remarks AS result_remarks
FROM lab_order o
JOIN admission a ON a.admission_id = o.admission_id
JOIN patient p ON p.patient_id = a.patient_id
JOIN bed b ON b.bed_id = a.bed_id
JOIN ward w ON w.ward_id = b.ward_id
JOIN lab_test t ON t.test_id = o.test_id
JOIN staff s ON s.staff_id = o.ordered_by
LEFT JOIN lab_result r ON r.result_id = o.result_id;


-- How long completed orders took from order to result, per test
CREATE OR REPLACE VIEW v_lab_order_turnaround AS
SELECT t.test_name,
       COUNT(*) AS completed_orders,
       SUM(CASE WHEN o.priority = 'URGENT' THEN 1 ELSE 0 END) AS urgent_orders,
       ROUND(AVG((o.completed_at - o.ordered_at) * 1440), 1) AS avg_minutes_to_result,
       ROUND(MAX((o.completed_at - o.ordered_at) * 1440), 1) AS max_minutes_to_result
FROM lab_order o
JOIN lab_test t ON t.test_id = o.test_id
WHERE o.order_status = 'COMPLETED'
GROUP BY t.test_name;
