-- BED TURNAROUND VIEWS
-- Run after 60_views.sql (uses v_bed_status_since).


-- One row per bed cycle: from the moment a patient leaves (OCCUPIED -> AWAITING_CLEANING) until the
-- bed is AVAILABLE again. Each history row's stage lasts until the next row for that bed (LEAD);
-- the open stage of an unfinished cycle is measured up to now.
CREATE OR REPLACE VIEW v_bed_turnaround AS
WITH stages AS (
    SELECT h.bed_id,
           h.from_status,
           h.to_status,
           h.admission_id,
           h.changed_at,
           LEAD(h.changed_at) OVER (PARTITION BY h.bed_id ORDER BY h.changed_at, h.history_id) AS next_changed_at,
           -- Position in the bed's history; used to cut cycles because several changes can share a timestamp
           ROW_NUMBER() OVER (PARTITION BY h.bed_id ORDER BY h.changed_at, h.history_id) AS seq,
           -- Running count of vacate events numbers the cycles
           SUM(CASE WHEN h.from_status = 'OCCUPIED' AND h.to_status = 'AWAITING_CLEANING' THEN 1 ELSE 0 END)
               OVER (PARTITION BY h.bed_id ORDER BY h.changed_at, h.history_id
                     ROWS UNBOUNDED PRECEDING) AS cycle_no
    FROM bed_status_history h
),
cycles AS (
    SELECT bed_id,
           cycle_no,
           MIN(CASE WHEN from_status = 'OCCUPIED' THEN changed_at END) AS vacated_at,
           MIN(CASE WHEN to_status = 'AVAILABLE' THEN changed_at END) AS ready_at,
           MIN(CASE WHEN to_status = 'AVAILABLE' THEN seq END) AS ready_seq,
           MAX(CASE WHEN from_status = 'OCCUPIED' THEN admission_id END) AS admission_id
    FROM stages
    WHERE cycle_no > 0
    GROUP BY bed_id, cycle_no
)
SELECT c.bed_id,
       b.bed_number,
       w.ward_id,
       w.ward_name,
       w.ward_type,
       c.cycle_no,
       c.admission_id,
       c.vacated_at,
       MIN(CASE WHEN s.to_status = 'AWAITING_INSPECTION' THEN s.changed_at END) AS cleaned_at,
       c.ready_at,
       ROUND(SUM(CASE WHEN s.to_status = 'AWAITING_CLEANING'
                      THEN (NVL(s.next_changed_at, SYSDATE) - s.changed_at) * 1440 ELSE 0 END), 1) AS cleaning_minutes,
       ROUND(SUM(CASE WHEN s.to_status = 'AWAITING_INSPECTION'
                      THEN (NVL(s.next_changed_at, SYSDATE) - s.changed_at) * 1440 ELSE 0 END), 1) AS inspection_minutes,
       ROUND(SUM(CASE WHEN s.to_status = 'MAINTENANCE'
                      THEN (NVL(s.next_changed_at, SYSDATE) - s.changed_at) * 1440 ELSE 0 END), 1) AS maintenance_minutes,
       COUNT(CASE WHEN s.from_status = 'AWAITING_INSPECTION' AND s.to_status = 'AWAITING_CLEANING' THEN 1 END)
           AS inspection_failures,
       ROUND((NVL(c.ready_at, SYSDATE) - c.vacated_at) * 1440, 1) AS total_turnaround_minutes,
       CASE WHEN c.ready_at IS NOT NULL THEN 'Y' ELSE 'N' END AS is_complete
FROM cycles c
JOIN stages s ON s.bed_id = c.bed_id
             AND s.cycle_no = c.cycle_no
             AND (c.ready_seq IS NULL OR s.seq < c.ready_seq)
JOIN bed b ON b.bed_id = c.bed_id
JOIN ward w ON w.ward_id = b.ward_id
GROUP BY c.bed_id, b.bed_number, w.ward_id, w.ward_name, w.ward_type, c.cycle_no, c.admission_id,
         c.vacated_at, c.ready_at;


-- Completed cycles per ward, slowest ward first
CREATE OR REPLACE VIEW v_ward_turnaround AS
SELECT RANK() OVER (ORDER BY AVG(t.total_turnaround_minutes) DESC) AS slowest_rank,
       t.ward_id,
       t.ward_name,
       t.ward_type,
       COUNT(*) AS cycles,
       ROUND(AVG(t.cleaning_minutes), 1) AS avg_cleaning_minutes,
       MAX(t.cleaning_minutes) AS max_cleaning_minutes,
       ROUND(AVG(t.inspection_minutes), 1) AS avg_inspection_minutes,
       MAX(t.inspection_minutes) AS max_inspection_minutes,
       ROUND(AVG(t.total_turnaround_minutes), 1) AS avg_total_minutes,
       MAX(t.total_turnaround_minutes) AS max_total_minutes,
       SUM(t.inspection_failures) AS inspection_failures,
       SUM(CASE WHEN t.cleaning_minutes > cfg.cleaning_target THEN 1 ELSE 0 END) AS cleaning_over_target,
       SUM(CASE WHEN t.inspection_minutes > cfg.inspection_target THEN 1 ELSE 0 END) AS inspection_over_target
FROM v_bed_turnaround t
CROSS JOIN (
    SELECT MAX(CASE WHEN config_key = 'CLEANING_TARGET_MIN' THEN config_value END) AS cleaning_target,
           MAX(CASE WHEN config_key = 'INSPECTION_TARGET_MIN' THEN config_value END) AS inspection_target
    FROM allocation_config
) cfg
WHERE t.is_complete = 'Y'
GROUP BY t.ward_id, t.ward_name, t.ward_type;


-- Every bed that is not AVAILABLE right now, why, for how long, and whether it is past its target
CREATE OR REPLACE VIEW v_blocked_capacity AS
SELECT x.*,
       CASE WHEN x.target_minutes IS NOT NULL AND x.minutes_in_state > x.target_minutes
            THEN 'Y' ELSE 'N' END AS past_target
FROM (
    SELECT w.ward_id,
           w.ward_name,
           w.ward_type,
           b.bed_id,
           b.bed_number,
           b.bed_status,
           CASE b.bed_status
               WHEN 'OCCUPIED' THEN 'Occupied'
               WHEN 'AWAITING_CLEANING' THEN 'Awaiting cleaning'
               WHEN 'AWAITING_INSPECTION' THEN 'Awaiting inspection'
               WHEN 'MAINTENANCE' THEN 'Maintenance'
           END AS reason,
           s.status_since AS since,
           ROUND((SYSDATE - s.status_since) * 1440) AS minutes_in_state,
           CASE b.bed_status
               WHEN 'AWAITING_CLEANING' THEN cfg.cleaning_target
               WHEN 'AWAITING_INSPECTION' THEN cfg.inspection_target
           END AS target_minutes
    FROM bed b
    JOIN ward w ON w.ward_id = b.ward_id
    JOIN v_bed_status_since s ON s.bed_id = b.bed_id
    CROSS JOIN (
        SELECT MAX(CASE WHEN config_key = 'CLEANING_TARGET_MIN' THEN config_value END) AS cleaning_target,
               MAX(CASE WHEN config_key = 'INSPECTION_TARGET_MIN' THEN config_value END) AS inspection_target
        FROM allocation_config
    ) cfg
    WHERE b.bed_status <> 'AVAILABLE'
) x;


-- Ward types with patients waiting, and the beds of that ward type held up only by cleaning or inspection
CREATE OR REPLACE VIEW v_beds_blocking_queue AS
SELECT q.ward_type,
       q.waiting_patients,
       q.oldest_request,
       ROUND((SYSDATE - q.oldest_request) * 1440) AS longest_wait_minutes,
       bc.ward_name,
       bc.bed_id,
       bc.bed_number,
       bc.bed_status,
       bc.reason,
       bc.minutes_in_state,
       bc.target_minutes,
       bc.past_target
FROM (
    SELECT required_ward_type AS ward_type,
           COUNT(*) AS waiting_patients,
           MIN(request_time) AS oldest_request
    FROM waiting_queue
    WHERE queue_status = 'WAITING'
    GROUP BY required_ward_type
) q
JOIN v_blocked_capacity bc ON bc.ward_type = q.ward_type
                          AND bc.bed_status IN ('AWAITING_CLEANING','AWAITING_INSPECTION');
