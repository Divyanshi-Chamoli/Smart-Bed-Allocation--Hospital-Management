"""Two users try to grab the last free General bed at the same instant.

Expected: exactly one patient is admitted, the other is queued, and the bed has one active admission.
Run:  .venv\\Scripts\\python tests\\concurrency_test.py   (from the frontend folder)
"""
import os
import threading
from datetime import date

import oracledb

DSN = os.environ.get("DB_DSN", "localhost/XEPDB1")
USER = os.environ.get("DB_USER", "hms")
PASSWORD = os.environ.get("DB_PASSWORD", "hms123")
ROUNDS = 3


def connect(app_user):
    conn = oracledb.connect(user=USER, password=PASSWORD, dsn=DSN)
    conn.client_identifier = app_user
    return conn


def call(conn, name, *args, outs=()):
    cur = conn.cursor()
    out_vars = [cur.var(t, 4000) if t is str else cur.var(t) for t in outs]
    cur.callproc(name, list(args) + out_vars)
    return [v.getvalue() for v in out_vars]


def one_round(admin, round_no):
    cur = admin.cursor()
    free = [r[0] for r in cur.execute(
        "SELECT b.bed_id FROM bed b JOIN ward w ON w.ward_id = b.ward_id "
        "WHERE w.ward_type = 'General' AND b.bed_status = 'AVAILABLE' ORDER BY b.bed_id")]
    if not free:
        raise SystemExit("No free General bed to race for")
    last_bed, parked = free[0], free[1:]
    for bed in parked:
        call(admin, "pkg_bed_allocation.set_bed_status", bed, "MAINTENANCE", outs=[str])

    patients = []
    for i in (1, 2):
        (pid,) = call(admin, "pkg_admin.add_patient", "Race", f"R{round_no}P{i}", date(1990, 1, 1), "Other",
                      None, None, None, outs=[int])
        patients.append(pid)

    barrier = threading.Barrier(2)
    results = {}

    def worker(app_user, patient_id):
        conn = connect(app_user)
        try:
            barrier.wait()
            adm, queue_id, msg = call(conn, "pkg_bed_allocation.request_admission", patient_id, 1, "General",
                                      "LOW", "concurrency test", outs=[int, int, str])
            results[patient_id] = (adm, queue_id, msg)
        except oracledb.DatabaseError as exc:
            results[patient_id] = (None, None, f"ERROR {exc}")
        finally:
            conn.close()

    threads = [threading.Thread(target=worker, args=(user, pid))
               for user, pid in zip(("rahul", "ananya"), patients)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    admitted = [pid for pid, (adm, _, _) in results.items() if adm]
    queued = [pid for pid, (adm, q, _) in results.items() if not adm and q]
    (active_on_bed,) = cur.execute(
        "SELECT COUNT(*) FROM admission WHERE bed_id = :b AND admission_status = 'ADMITTED'", b=last_bed).fetchone()

    for pid, (_, _, msg) in results.items():
        print(f"  patient {pid}: {msg}")
    ok = len(admitted) == 1 and len(queued) == 1 and active_on_bed == 1
    print(f"Round {round_no}: {'PASS' if ok else 'FAIL'} - admitted={admitted} queued={queued} "
          f"active admissions on bed {last_bed} = {active_on_bed}")

    # Clean up: cancel the queue entry and the admission, turn the raced bed around, put the parked beds back
    for pid in queued:
        (qid,) = cur.execute("SELECT queue_id FROM waiting_queue WHERE patient_id = :p AND queue_status = 'WAITING'",
                             p=pid).fetchone()
        call(admin, "pkg_bed_allocation.cancel_queue_entry", qid, "concurrency test cleanup")
    for pid in admitted:
        (adm,) = cur.execute("SELECT admission_id FROM admission WHERE patient_id = :p AND admission_status = 'ADMITTED'",
                             p=pid).fetchone()
        call(admin, "pkg_bed_allocation.cancel_admission", adm, "concurrency test cleanup", outs=[str])
    if admitted:
        # Cancelling sends the bed for cleaning; clean and pass inspection to make it available again
        call(admin, "pkg_bed_allocation.mark_bed_cleaned", last_bed, outs=[str])
        call(admin, "pkg_bed_allocation.inspect_bed", last_bed, "Y", outs=[str])
    for bed in parked:
        call(admin, "pkg_bed_allocation.set_bed_status", bed, "AVAILABLE", outs=[str])
    return ok


def main():
    admin = connect("admin")
    passed = sum(one_round(admin, n) for n in range(1, ROUNDS + 1))
    admin.close()
    print(f"\n{passed}/{ROUNDS} rounds passed")
    raise SystemExit(0 if passed == ROUNDS else 1)


if __name__ == "__main__":
    main()
