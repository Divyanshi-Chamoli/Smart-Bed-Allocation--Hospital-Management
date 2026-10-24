-- SAMPLE REPORTING QUERIES
-- sqlplus hms/hms123@localhost/XEPDB1 @sql/90_sample_queries.sql

SET LINESIZE 200
SET PAGESIZE 100
COLUMN patient_name FORMAT A22
COLUMN ward_name FORMAT A16
COLUMN doctor_name FORMAT A20
COLUMN rule_applied FORMAT A60

PROMPT 1. Bed occupancy per ward (beds awaiting cleaning/inspection count as in use)
SELECT ward_name, ward_type, total_beds, available_beds, occupied_beds,
       awaiting_cleaning_beds, awaiting_inspection_beds, maintenance_beds, occupancy_pct
FROM v_bed_occupancy
ORDER BY occupancy_pct DESC;

PROMPT 2. Hospital-wide occupancy (aggregate over all wards)
SELECT SUM(total_beds) AS beds,
       SUM(occupied_beds) AS occupied,
       ROUND(100 * SUM(occupied_beds) / SUM(total_beds), 1) AS occupancy_pct
FROM v_bed_occupancy;

PROMPT 3. Patients currently admitted, longest stay first
SELECT patient_name, age, ward_name, bed_number, urgency_code, doctor_name, days_admitted
FROM v_current_admissions
ORDER BY days_admitted DESC;

PROMPT 4. Waiting queue in priority order
SELECT queue_position, patient_name, age, required_ward_type, urgency_code,
       priority_score, minutes_waiting, overdue
FROM v_waiting_queue_ranked
ORDER BY queue_position;

PROMPT 5. Recommended beds for a patient (patient 4, ICU, CRITICAL)
SELECT candidate_rank, ward_name, bed_number, rule_applied
FROM TABLE(pkg_bed_allocation.candidate_beds(4, 'ICU', 'CRITICAL'))
WHERE ROWNUM <= 5;

PROMPT 6. Average wait before getting a bed, by urgency
SELECT urgency_code, requests, allocated, still_waiting, avg_wait_minutes, max_wait_minutes
FROM v_queue_wait_stats
ORDER BY base_weight DESC;

PROMPT 7. Doctors ranked by current workload
SELECT doctor_name, department, current_patients, patients_waiting, total_admissions,
       RANK() OVER (ORDER BY current_patients DESC) AS workload_rank
FROM v_doctor_workload;

PROMPT 8. Allocations that used a fallback ward or a reserved bed
SELECT acted_at, patient_name, ward_name, bed_number, rule_applied
FROM v_allocation_history
WHERE action = 'ALLOCATED'
AND (rule_applied LIKE 'Fallback%' OR rule_applied LIKE '%reserved%' OR rule_applied LIKE 'Age rule%')
ORDER BY acted_at;

PROMPT 9. Most requested lab tests and revenue
SELECT t.test_name, COUNT(r.result_id) AS times_done, COUNT(r.result_id) * t.test_cost AS revenue
FROM lab_test t
LEFT JOIN lab_result r ON r.test_id = t.test_id
GROUP BY t.test_name, t.test_cost
ORDER BY times_done DESC, t.test_name;

PROMPT 10. Outstanding bills
SELECT bill_id, patient_name, total_amount, amount_paid, balance_due, payment_status
FROM v_unpaid_bills
ORDER BY balance_due DESC;

PROMPT 11. Revenue by billing source
SELECT bi.source_type, COUNT(*) AS lines, SUM(bi.amount) AS amount
FROM bill_item bi
GROUP BY bi.source_type
ORDER BY amount DESC;

PROMPT 12. Patients who have never been admitted (anti-join)
SELECT p.patient_id, p.first_name || ' ' || p.last_name AS patient_name
FROM patient p
WHERE NOT EXISTS (SELECT 1 FROM admission a WHERE a.patient_id = p.patient_id)
AND NOT EXISTS (SELECT 1 FROM waiting_queue q WHERE q.patient_id = p.patient_id AND q.queue_status = 'WAITING');

PROMPT 13. Wards busier than the hospital average (subquery)
SELECT ward_name, occupancy_pct
FROM v_bed_occupancy
WHERE occupancy_pct > (SELECT AVG(occupancy_pct) FROM v_bed_occupancy);

PROMPT 14. Staff and their login accounts (outer join: staff without accounts too)
SELECT s.staff_name, s.designation, u.username, r.role_name, u.account_status
FROM staff s
LEFT JOIN user_account u ON u.staff_id = s.staff_id
LEFT JOIN role r ON r.role_id = u.role_id
ORDER BY s.staff_id;

PROMPT 15. Bed turnaround by ward, slowest first (completed cycles)
SELECT slowest_rank, ward_name, cycles, avg_cleaning_minutes, avg_inspection_minutes,
       avg_total_minutes, max_total_minutes, inspection_failures, cleaning_over_target
FROM v_ward_turnaround
ORDER BY slowest_rank;

PROMPT 16. Why beds are unavailable right now
SELECT ward_name, reason, COUNT(*) AS beds, MAX(minutes_in_state) AS longest_minutes,
       SUM(CASE WHEN past_target = 'Y' THEN 1 ELSE 0 END) AS past_target
FROM v_blocked_capacity
GROUP BY ward_name, reason
ORDER BY ward_name, reason;

PROMPT 17. Beds held up by cleaning/inspection while patients of that ward type wait
SELECT ward_type, waiting_patients, longest_wait_minutes, ward_name, bed_number, reason, minutes_in_state, past_target
FROM v_beds_blocking_queue
ORDER BY ward_type, minutes_in_state DESC;

PROMPT 18. Status history of one bed with time spent in each state (LEAD)
SELECT b.bed_number, h.from_status, h.to_status, h.changed_at, h.changed_by,
       ROUND((LEAD(h.changed_at) OVER (ORDER BY h.changed_at, h.history_id) - h.changed_at) * 1440) AS minutes_in_state
FROM bed_status_history h
JOIN bed b ON b.bed_id = h.bed_id
WHERE b.bed_number = 'I201'
ORDER BY h.changed_at, h.history_id;

PROMPT 19. Pending lab orders, urgent first
SELECT order_id, priority, patient_name, ward_name, bed_number, test_name, ordered_by_name, minutes_open
FROM v_lab_orders
WHERE order_status = 'ORDERED'
ORDER BY CASE priority WHEN 'URGENT' THEN 0 ELSE 1 END, ordered_at;

PROMPT 20. Time from order to result per lab test
SELECT test_name, completed_orders, urgent_orders, avg_minutes_to_result, max_minutes_to_result
FROM v_lab_order_turnaround
ORDER BY avg_minutes_to_result DESC;
