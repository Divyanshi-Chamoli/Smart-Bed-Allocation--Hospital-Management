# Hospital Management System: Smart Bed Allocation

Oracle 21c XE database + Flask frontend. Instead of handing out whichever bed is free, the system
**recommends** a bed from the patient's urgency, required ward type, age and availability, puts patients in a
**prioritised waiting queue** when nothing suitable is free, and makes it **impossible for two patients to hold
the same bed**.

## Setup

```
# 1. Database (once, as SYSDBA in XEPDB1): create the schema owner
#    CREATE USER hms IDENTIFIED BY hms123 DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
#    GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE PROCEDURE, CREATE TRIGGER,
#          CREATE VIEW, CREATE TYPE, CREATE ROLE TO hms;

# 2. Install everything (from this folder)
sqlplus hms/hms123@localhost/XEPDB1 @install.sql

# 3. Frontend
cd frontend
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
copy .env.example .env          # adjust DB settings / SECRET_KEY if needed
.venv\Scripts\python app.py     # http://127.0.0.1:5000
```

Demo logins (password = username + `123`): `admin` (ADMIN), `rahul` / `priya` / `kavya` (DOCTOR),
`ananya` (NURSE), `riya` (LAB_STAFF), `arjun` (BILLING_STAFF).

Reset the database: `@sql/99_drop_all.sql` then `@install.sql`.

**Upgrading a database installed before bed turnaround tracking** (keeps all existing data):

```
sqlplus hms/hms123@localhost/XEPDB1 @sql/migrate_bed_turnaround.sql
```

It adds the new bed states and history table, swaps the `bed_status` CHECK constraint (looked up by name in
`USER_CONSTRAINTS`), installs the new trigger, package and views, and adds backdated example history. It does not
change any bed's current status or create admissions, and it is safe to run more than once.

**Adding lab test ordering to an existing database** (after the step above; keeps all existing data):

```
sqlplus hms/hms123@localhost/XEPDB1 @sql/migrate_lab_orders.sql
```

**Running the tests** without touching real data: install into a separate schema (for example `hms_test`) and
point the scripts at it:

```
sqlplus hms_test/hms123@localhost/XEPDB1 @install.sql
sqlplus hms_test/hms123@localhost/XEPDB1 @sql/95_test_allocation.sql
set DB_USER=hms_test
frontend\.venv\Scripts\python frontend\tests\concurrency_test.py
frontend\.venv\Scripts\python frontend\tests\smoke_test.py
```

## Files

| File | Contents |
|---|---|
| `hospitalmanagement.sql`, `createseq.sql`, `INSERTION/` | Original schema, sequences, seed data; `insert_more_patients.sql` adds 10 more patients |
| `sql/10_allocation_schema.sql` | Rule tables, `waiting_queue`, `bed_allocation_log`, extra columns, double-booking indexes |
| `sql/12_bed_turnaround_schema.sql` | Five bed states (`ck_bed_status`), `bed_status_history` table |
| `sql/14_lab_orders_schema.sql` | `lab_order` table (one open order per test per admission) |
| `sql/20_triggers.sql` | Auto IDs, admission guard, bed life-cycle guard + status history, bill totals (compound trigger), payment status, password hashing |
| `sql/25_seed_allocation.sql` | Urgency bands, ward compatibility rules, tunable config, tariffs, demo patients |
| `sql/27_seed_turnaround.sql` | Cleaning/inspection targets, backdated turnaround history, one bed past its cleaning target (fresh install only) |
| `sql/30_pkg_security.sql` | Login + `assert_role` used by every write procedure |
| `sql/40_pkg_bed_allocation.sql` | **The allocation algorithm, queue and discharge logic** |
| `sql/50_pkg_clinical_billing.sql` | `pkg_admin`, `pkg_lab` (order, cancel, complete, unordered results), `pkg_billing` |
| `procedures.sql` | Original `admit_patient` / `discharge_patient`, now wrappers over the package |
| `sql/60_views.sql` | Reporting views (occupancy, bed board, queue, billing, lab, history …) |
| `sql/62_turnaround_views.sql` | `v_bed_turnaround`, `v_ward_turnaround`, `v_blocked_capacity`, `v_beds_blocking_queue` |
| `sql/migrate_bed_turnaround.sql` | Upgrade script for databases installed before turnaround tracking |
| `sql/migrate_lab_orders.sql` | Upgrade script that adds lab test ordering |
| `sql/70_db_roles.sql` | Oracle roles `HMS_ADMIN`, `HMS_DOCTOR`, `HMS_NURSE`, `HMS_LAB`, `HMS_BILLING` |
| `sql/90_sample_queries.sql` | 20 reporting queries (joins, aggregates, analytic functions, subqueries) |
| `sql/95_test_allocation.sql` | 65 automated checks (run on a fresh install) |
| `frontend/` | Flask app; `tests/smoke_test.py` (role access), `tests/concurrency_test.py` (race for the last bed) |

## How allocation works (`pkg_bed_allocation`)

**Recommendation** (`candidate_beds`, a pipelined function using explicit cursors):
1. *Age rule:* a child (< `PEDIATRIC_MAX_AGE`) asking for General is sent to Pediatric; an adult asking for
   Pediatric is sent to General. Adults are never placed in a Pediatric ward.
2. *Compatibility rules* (`ward_compatibility`): each requested ward type lists the ward types that may serve it,
   by preference. Fallbacks apply only above an urgency threshold, e.g. ICU full → Emergency for CRITICAL only.
3. *Critical reserve:* each ward keeps `reserved_critical_beds` free beds that only CRITICAL patients can take.
4. *Load balancing:* among suitable beds, the least-occupied ward wins.

Each candidate carries a human-readable reason ("Fallback #2: ICU full: critical patient stabilised in Emergency").

**Prioritised queue:** every request is first inserted into `waiting_queue`, then the whole queue is served in
priority order. So a new patient only gets a bed if nobody more urgent who is already waiting can use it.

```
priority = urgency weight (CRITICAL 100, HIGH 70, MEDIUM 40, LOW 10)
         + AGING_POINTS per AGING_INTERVAL_MIN waited (capped at AGING_CAP)
         + OVERDUE_BONUS once past the band's target wait
         + VULNERABLE_BONUS for children and elderly patients
```
The cap keeps a waiting patient below the next band: aging orders patients within a band but never lets a LOW
patient overtake a HIGH one. The queue is re-served automatically on discharge, cancellation, and when a bed
comes back from maintenance.

**Double-booking prevention (three layers):**
1. Candidate beds are locked with `SELECT … FOR UPDATE SKIP LOCKED`, so concurrent requests take different beds.
2. `trg_admission_guard` re-checks the bed is AVAILABLE under a row lock before any admission insert.
3. Unique function-based index `uq_active_admission_bed` allows only one ADMITTED row per bed, so even direct
   SQL with the trigger disabled cannot double-book (same for one active admission per patient and one
   WAITING entry per patient).

`trg_bed_status_guard` keeps bed status consistent with admissions (OCCUPIED only via an admission; an occupied
bed cannot be freed or sent to maintenance by hand).

## Bed turnaround

After a discharge or cancellation a bed is not free until it has been cleaned and inspected:

```
AVAILABLE -> OCCUPIED -> AWAITING_CLEANING -> AWAITING_INSPECTION -> AVAILABLE
                              ^                       |
                              +--- inspection failed -+
AVAILABLE / AWAITING_CLEANING / AWAITING_INSPECTION -> MAINTENANCE -> AVAILABLE
```

- `trg_bed_status_guard` rejects every other change (ORA-20070) and writes each change to `bed_status_history`.
- `pkg_bed_allocation.mark_bed_cleaned(bed, msg)` and `inspect_bed(bed, 'Y'|'N', msg)` (ADMIN and NURSE only).
  The waiting queue is served when a bed passes inspection, not at discharge.
- Only AVAILABLE beds are recommended or allocated. Beds being turned around count as in use for occupancy and
  load balancing and never count toward the critical reserve.
- Targets `CLEANING_TARGET_MIN` (60) and `INSPECTION_TARGET_MIN` (30) are editable on the Allocation rules page.
- Views:
  - `v_bed_turnaround`: one row per cycle, with minutes per stage, using `LEAD()` over the history.
  - `v_ward_turnaround`: averages and maximums per ward, slowest first.
  - `v_blocked_capacity`: every unavailable bed with its reason, time in that state and a past-target flag.
  - `v_beds_blocking_queue`: beds held up by cleaning or inspection while patients of that ward type wait.
- In the app: the bed board has Mark cleaned and Pass/Fail inspection actions, the dashboard has a "Why beds are
  unavailable" card, and Reports has turnaround by ward.

## Lab test orders

1. A doctor or nurse orders a test for an admitted patient, from the patient's page (or the Lab page for doctors),
   choosing Routine or Urgent (`pkg_lab.order_test`).
2. The lab sees **Pending orders** on the Lab page, urgent first, enters the result and clicks Complete
   (`pkg_lab.complete_order`). This creates the `lab_result` row, which billing charges for as before.
3. Open orders can be cancelled (`pkg_lab.cancel_order`); discharging or cancelling the admission cancels any
   still pending.

The same test cannot be open twice on one admission (unique index `uq_open_lab_order`). Tests done without an
order can still be entered with "Record an unordered result". `v_lab_orders` lists orders with status and waiting
time; `v_lab_order_turnaround` gives order-to-result times per test (also in Reports).

## Roles

Enforced twice: Flask decorators hide and refuse pages (HTTP 403), and every PL/SQL write procedure calls
`pkg_security.assert_role`, which reads the signed-in user that the app attaches to the Oracle session
(`DBMS_SESSION.SET_IDENTIFIER`). Users signing in with their own Oracle accounts are identified by
`user_account.db_username` instead, so they cannot impersonate anyone.

| Action | ADMIN | DOCTOR | NURSE | LAB_STAFF | BILLING_STAFF |
|---|---|---|---|---|---|
| Register / edit patients | ✔ | ✔ | ✔ | | |
| Request admission, queue | ✔ | ✔ | ✔ | | |
| Discharge | ✔ | ✔ | | | |
| Bed maintenance, mark cleaned, inspect | ✔ | | ✔ | | |
| Order / cancel lab tests | ✔ | ✔ | ✔ | | |
| Complete lab orders, record lab results | ✔ | | | ✔ | |
| View lab results | ✔ | ✔ | | ✔ | |
| Billing and payments | ✔ | | | | ✔ |
| Staff, users, wards, rules, reports | ✔ | | | | |

Passwords are stored as SHA-256 hashes (`trg_user_password_hash`). They are unsalted, which is fine for a
course project; a production system would use a salted, slow hash.
