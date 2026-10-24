"""Hospital Management System - Smart Bed Allocation frontend (Flask + Oracle)."""
import os
import secrets
from datetime import date, datetime
from pathlib import Path

from flask import (Flask, abort, flash, redirect, render_template, request,
                   session, url_for)

import db
from auth import (ADMIN, BILLING, CLINICAL, DOCTOR, LAB, NURSE, has_role,
                  login_required, nav_for_role, roles_required)
from db import OUT_NUM, OUT_STR, DbError, call, query, query_one


def load_env_file():
    env_path = Path(__file__).with_name(".env")
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip())


load_env_file()

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY") or secrets.token_hex(32)
db.init_pool(app)

URGENCIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
GENDERS = ["Male", "Female", "Other"]
BLOOD_GROUPS = ["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"]

# Status dot colour per stored value: ok = active/complete, moderate = pending,
# high/critical = urgency, anything else = inactive/closed
STATUS_TONES = {
    "CRITICAL": "critical", "HIGH": "high", "MEDIUM": "moderate", "LOW": "ok",
    "ADMITTED": "ok", "ALLOCATED": "ok", "PAID": "ok", "ACTIVE": "ok", "AVAILABLE": "ok",
    "WAITING": "moderate", "QUEUED": "moderate", "PENDING": "moderate", "PARTIAL": "moderate",
    "OCCUPIED": "high", "OVERDUE": "critical", "PAST_TARGET": "critical",
    # Turnaround states share the pending colour; inspection is drawn as a hollow dot to tell them apart
    "AWAITING_CLEANING": "moderate", "AWAITING_INSPECTION": "moderate-hollow",
    "ORDERED": "moderate", "COMPLETED": "ok", "URGENT": "high",
}
STATUS_LABELS = {"MEDIUM": "Moderate", "BED_STATUS": "Bed status"}


# ------------------------------------------------------------------ helpers

def form(name, cast=str):
    value = request.form.get(name, "").strip()
    if value == "":
        return None
    if cast is date:
        return date.fromisoformat(value)
    return cast(value)


def run(action, success=None):
    """Run a DB action; flash its message (or the DB error). Returns True on success."""
    try:
        result = action()
    except DbError as exc:
        flash(exc.message, "error")
        return False
    except ValueError as exc:
        flash(f"Invalid input: {exc}", "error")
        return False
    message = success(result) if callable(success) else success
    if message:
        flash(message, "success")
    return True


def back_to(default_endpoint, **kwargs):
    """Redirect to the form's local `next` path if given, otherwise to default_endpoint."""
    target = request.form.get("next", "")
    if target.startswith("/") and not target.startswith("//"):
        return redirect(target)
    return redirect(url_for(default_endpoint, **kwargs))


def ward_types():
    return [r["ward_type"] for r in query("SELECT DISTINCT ward_type FROM ward ORDER BY ward_type")]


def doctors():
    return query("SELECT staff_id, staff_name, department FROM staff WHERE designation = 'Doctor' ORDER BY staff_name")


def status_info(value):
    """(tone, sentence-case label) for a stored status or urgency value."""
    if not value:
        return "inactive", None
    key = str(value).upper()
    return STATUS_TONES.get(key, "inactive"), STATUS_LABELS.get(key, key.replace("_", " ").capitalize())


def initials(name):
    parts = [p for p in (name or "").replace(".", ". ").split() if p.rstrip(".").lower() not in ("dr", "mr", "ms", "mrs")]
    return "".join(p[0] for p in parts[:1] + parts[-1:]).upper() if parts else "?"


def role_label(role):
    return (role or "").replace("_", " ").capitalize()


@app.before_request
def csrf_protect():
    if "csrf" not in session:
        session["csrf"] = secrets.token_hex(16)
    if request.method == "POST" and request.form.get("csrf") != session["csrf"]:
        abort(400, "Form expired - please reload the page and try again.")


@app.context_processor
def inject_globals():
    return {
        "nav": nav_for_role(session.get("role")),
        "has_role": has_role,
        "csrf": session.get("csrf", ""),
        "ADMIN": ADMIN, "DOCTOR": DOCTOR, "NURSE": NURSE, "LAB": LAB, "BILLING": BILLING,
    }


# Globals (not context processors) so imported macros in _ui.html can use them
app.jinja_env.globals.update(status_info=status_info, initials=initials, role_label=role_label)


@app.template_filter("dt")
def format_datetime(value, fmt="%d %b %Y %H:%M"):
    if isinstance(value, (datetime, date)):
        return value.strftime(fmt)
    return value if value is not None else ""


@app.template_filter("d")
def format_date(value):
    return format_datetime(value, "%d %b %Y")


@app.template_filter("money")
def format_money(value):
    return f"₹{value:,.2f}" if value is not None else ""


@app.errorhandler(403)
def forbidden(_e):
    return render_template("error.html", code=403,
                           message="Your role does not allow access to this page."), 403


@app.errorhandler(400)
def bad_request(e):
    return render_template("error.html", code=400, message=e.description), 400


@app.errorhandler(404)
def not_found(_e):
    return render_template("error.html", code=404, message="Page not found."), 404


# ------------------------------------------------------------------ login

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = (request.form.get("username") or "").strip().lower()
        password = request.form.get("password") or ""
        role = db.call_func("pkg_security.authenticate", str, username, password)
        if role:
            user = query_one(
                "SELECT u.user_id, u.staff_id, s.staff_name FROM user_account u "
                "JOIN staff s ON s.staff_id = u.staff_id WHERE u.username = :u", {"u": username})
            csrf = session.get("csrf")
            session.clear()
            session.update(username=username, role=role, user_id=user["user_id"],
                           staff_id=user["staff_id"], name=user["staff_name"], csrf=csrf)
            target = request.args.get("next", "")
            return redirect(target if target.startswith("/") and not target.startswith("//")
                            else url_for("dashboard"))
        flash("Invalid username or password, or the account is inactive.", "error")
    return render_template("login.html")


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/account/password", methods=["GET", "POST"])
@login_required
def change_password():
    if request.method == "POST":
        if form("new_password") != form("confirm_password"):
            flash("The new passwords do not match.", "error")
        elif run(lambda: call("pkg_admin.change_own_password", form("old_password"), form("new_password")),
                 "Password changed."):
            return redirect(url_for("dashboard"))
    return render_template("password.html")


# ------------------------------------------------------------------ dashboard

@app.route("/")
@login_required
def dashboard():
    wards = query("SELECT * FROM v_bed_occupancy ORDER BY ward_id")
    totals = {
        "beds": sum(w["total_beds"] for w in wards),
        "available": sum(w["available_beds"] for w in wards),
        "occupied": sum(w["occupied_beds"] for w in wards),
        "maintenance": sum(w["maintenance_beds"] for w in wards),
    }
    stats = query_one("""
        SELECT (SELECT COUNT(*) FROM waiting_queue WHERE queue_status = 'WAITING') AS waiting,
               (SELECT COUNT(*) FROM admission WHERE admission_status = 'ADMITTED') AS admitted,
               (SELECT COUNT(*) FROM admission WHERE TRUNC(admission_date) = TRUNC(SYSDATE)) AS admitted_today,
               (SELECT COUNT(*) FROM bill WHERE payment_status <> 'PAID') AS unpaid_bills
        FROM dual""")
    queue_top = query("SELECT * FROM v_waiting_queue_ranked WHERE queue_position <= 5 ORDER BY queue_position") \
        if has_role(*CLINICAL) else []
    blocked = query("""
        SELECT ward_id, ward_name,
               SUM(CASE WHEN bed_status = 'OCCUPIED' THEN 1 ELSE 0 END) AS occupied,
               SUM(CASE WHEN bed_status = 'AWAITING_CLEANING' THEN 1 ELSE 0 END) AS awaiting_cleaning,
               SUM(CASE WHEN bed_status = 'AWAITING_INSPECTION' THEN 1 ELSE 0 END) AS awaiting_inspection,
               SUM(CASE WHEN bed_status = 'MAINTENANCE' THEN 1 ELSE 0 END) AS maintenance,
               SUM(CASE WHEN past_target = 'Y' THEN 1 ELSE 0 END) AS past_target
        FROM v_blocked_capacity GROUP BY ward_id, ward_name ORDER BY ward_id""")
    late_beds = query("SELECT * FROM v_blocked_capacity WHERE past_target = 'Y' ORDER BY minutes_in_state DESC")
    return render_template("dashboard.html", wards=wards, totals=totals, stats=stats, queue_top=queue_top,
                           blocked=blocked, late_beds=late_beds)


# ------------------------------------------------------------------ patients

def patient_args():
    return (form("first_name"), form("last_name"), form("dob", date), form("gender"),
            form("phone"), form("address"), form("blood_group"))


@app.route("/patients", methods=["GET", "POST"])
@roles_required(*CLINICAL)
def patients():
    if request.method == "POST":
        if run(lambda: call("pkg_admin.add_patient", *patient_args(), OUT_NUM),
               lambda pid: f"Patient registered with ID {pid}."):
            return redirect(url_for("patients"))
    search = request.args.get("q", "").strip()
    rows = query("""
        SELECT p.*, FLOOR(MONTHS_BETWEEN(SYSDATE, p.dob) / 12) AS age,
               CASE WHEN EXISTS (SELECT 1 FROM admission a WHERE a.patient_id = p.patient_id
                                 AND a.admission_status = 'ADMITTED') THEN 'Admitted'
                    WHEN EXISTS (SELECT 1 FROM waiting_queue q WHERE q.patient_id = p.patient_id
                                 AND q.queue_status = 'WAITING') THEN 'Waiting'
                    ELSE '' END AS status
        FROM patient p
        WHERE :q IS NULL
           OR UPPER(p.first_name || ' ' || p.last_name) LIKE '%' || UPPER(:q) || '%'
           OR p.phone LIKE '%' || :q || '%'
           OR TO_CHAR(p.patient_id) = :q
        ORDER BY p.patient_id""", {"q": search or None})
    return render_template("patients.html", patients=rows, search=search,
                           genders=GENDERS, blood_groups=BLOOD_GROUPS)


@app.route("/patients/<int:patient_id>", methods=["GET", "POST"])
@roles_required(*CLINICAL)
def patient_detail(patient_id):
    if request.method == "POST":
        run(lambda: call("pkg_admin.update_patient", patient_id, *patient_args()), "Patient updated.")
        return redirect(url_for("patient_detail", patient_id=patient_id))
    patient = query_one("SELECT p.*, FLOOR(MONTHS_BETWEEN(SYSDATE, p.dob) / 12) AS age "
                        "FROM patient p WHERE patient_id = :id", {"id": patient_id})
    if not patient:
        abort(404)
    history = query("SELECT * FROM v_patient_history WHERE patient_id = :id ORDER BY admission_date DESC",
                    {"id": patient_id})
    labs = query("SELECT * FROM v_lab_results_detail WHERE patient_id = :id ORDER BY test_date DESC",
                 {"id": patient_id})
    waiting = query_one("SELECT * FROM v_waiting_queue_ranked WHERE patient_id = :id", {"id": patient_id})
    current = query_one("SELECT * FROM v_current_admissions WHERE patient_id = :id", {"id": patient_id})
    orders = query("SELECT * FROM v_lab_orders WHERE patient_id = :id ORDER BY ordered_at DESC", {"id": patient_id})
    tests = query("SELECT * FROM lab_test ORDER BY test_name")
    return render_template("patient_detail.html", patient=patient, history=history, labs=labs,
                           waiting=waiting, current=current, orders=orders, tests=tests,
                           genders=GENDERS, blood_groups=BLOOD_GROUPS)


# ------------------------------------------------------------------ admission with recommendation

@app.route("/admit", methods=["GET", "POST"])
@roles_required(*CLINICAL)
def admit():
    selection = {
        "patient_id": request.values.get("patient_id", type=int),
        "doctor_id": request.values.get("doctor_id", type=int),
        "ward_type": request.values.get("ward_type") or None,
        "urgency": request.values.get("urgency") or None,
        "notes": (request.values.get("notes") or "").strip() or None,
    }
    candidates = None
    effective_type = None

    if request.method == "POST" and all(selection[k] for k in ("patient_id", "doctor_id", "ward_type", "urgency")):
        action = request.form.get("action")
        if action == "recommend":
            try:
                # Same result as pkg_bed_allocation.recommend_beds; queried directly because returning
                # that REF CURSOR with bound arguments hangs in python-oracledb thin mode
                candidates = query(
                    "SELECT * FROM TABLE(pkg_bed_allocation.candidate_beds(:p, :t, :u)) "
                    "WHERE candidate_rank <= pkg_bed_allocation.get_config('RECOMMEND_TOP_N') "
                    "ORDER BY candidate_rank",
                    {"p": selection["patient_id"], "t": selection["ward_type"], "u": selection["urgency"]})
                effective_type = query_one(
                    "SELECT pkg_bed_allocation.effective_ward_type(:p, :t) AS t FROM dual",
                    {"p": selection["patient_id"], "t": selection["ward_type"]})["t"]
            except DbError as exc:
                flash(exc.message, "error")
        elif action == "auto":
            result = {}

            def request_admission():
                result["admission_id"], _queue_id, message = call(
                    "pkg_bed_allocation.request_admission", selection["patient_id"], selection["doctor_id"],
                    selection["ward_type"], selection["urgency"], selection["notes"], OUT_NUM, OUT_NUM, OUT_STR)
                return message

            if run(request_admission, lambda m: m):
                return redirect(url_for("admissions") if result["admission_id"] else url_for("queue"))
        elif action == "allocate":
            bed_id = request.form.get("bed_id", type=int)
            if run(lambda: call("pkg_bed_allocation.allocate_specific_bed", selection["patient_id"],
                                selection["doctor_id"], bed_id, selection["ward_type"], selection["urgency"],
                                OUT_NUM, OUT_STR),
                   lambda r: r[1]):
                return redirect(url_for("admissions"))
    elif request.method == "POST":
        flash("Choose a patient, doctor, ward type and urgency.", "error")

    eligible = query("""
        SELECT p.patient_id, p.first_name || ' ' || p.last_name AS name,
               FLOOR(MONTHS_BETWEEN(SYSDATE, p.dob) / 12) AS age,
               (SELECT queue_status FROM waiting_queue q WHERE q.patient_id = p.patient_id
                AND q.queue_status = 'WAITING') AS waiting
        FROM patient p
        WHERE NOT EXISTS (SELECT 1 FROM admission a WHERE a.patient_id = p.patient_id
                          AND a.admission_status = 'ADMITTED')
        ORDER BY p.first_name, p.last_name""")
    urgency_levels = query("SELECT * FROM urgency_level ORDER BY base_weight DESC")
    return render_template("admit.html", patients=eligible, doctors=doctors(), ward_types=ward_types(),
                           urgencies=urgency_levels, sel=selection, candidates=candidates,
                           effective_type=effective_type)


# ------------------------------------------------------------------ queue

@app.route("/queue")
@roles_required(*CLINICAL)
def queue():
    rows = query("SELECT * FROM v_waiting_queue_ranked ORDER BY queue_position")
    recent = query("""SELECT * FROM v_allocation_history WHERE action IN ('ALLOCATED','QUEUED','CANCELLED')
                      ORDER BY log_id DESC FETCH FIRST 15 ROWS ONLY""")
    config = {r["config_key"]: r["config_value"] for r in query("SELECT * FROM allocation_config")}
    urgency_levels = query("SELECT * FROM urgency_level ORDER BY base_weight DESC")
    return render_template("queue.html", queue=rows, recent=recent, config=config, urgencies=urgency_levels)


@app.route("/queue/process", methods=["POST"])
@roles_required(*CLINICAL)
def queue_process():
    run(lambda: call("pkg_bed_allocation.process_queue", OUT_NUM),
        lambda n: f"Queue processed: {n} patient(s) allocated." if n else
        "Queue processed: no suitable beds are free for anyone waiting.")
    return redirect(url_for("queue"))


@app.route("/queue/<int:queue_id>/cancel", methods=["POST"])
@roles_required(*CLINICAL)
def queue_cancel(queue_id):
    run(lambda: call("pkg_bed_allocation.cancel_queue_entry", queue_id,
                     form("reason") or "Cancelled by " + session["username"]),
        "Queue entry cancelled.")
    return redirect(url_for("queue"))


# ------------------------------------------------------------------ beds

@app.route("/beds")
@roles_required(*CLINICAL)
def beds():
    rows = query("SELECT * FROM v_bed_board ORDER BY ward_id, bed_number")
    wards = {}
    for row in rows:
        wards.setdefault((row["ward_id"], row["ward_name"], row["ward_type"]), []).append(row)
    occupancy = {w["ward_id"]: w for w in query("SELECT * FROM v_bed_occupancy")}
    blocked = {b["bed_id"]: b for b in query("SELECT * FROM v_blocked_capacity")}
    return render_template("beds.html", wards=wards, occupancy=occupancy, blocked=blocked)


@app.route("/beds/<int:bed_id>/status", methods=["POST"])
@roles_required(ADMIN, NURSE)
def bed_status(bed_id):
    run(lambda: call("pkg_bed_allocation.set_bed_status", bed_id, form("status"), OUT_STR), lambda m: m)
    return redirect(url_for("beds"))


@app.route("/beds/<int:bed_id>/cleaned", methods=["POST"])
@roles_required(ADMIN, NURSE)
def bed_cleaned(bed_id):
    run(lambda: call("pkg_bed_allocation.mark_bed_cleaned", bed_id, OUT_STR), lambda m: m)
    return redirect(url_for("beds"))


@app.route("/beds/<int:bed_id>/inspect", methods=["POST"])
@roles_required(ADMIN, NURSE)
def bed_inspect(bed_id):
    run(lambda: call("pkg_bed_allocation.inspect_bed", bed_id, form("passed"), OUT_STR), lambda m: m)
    return redirect(url_for("beds"))


# ------------------------------------------------------------------ admissions

@app.route("/admissions")
@roles_required(ADMIN, DOCTOR, NURSE, LAB)
def admissions():
    current = query("SELECT * FROM v_current_admissions ORDER BY admission_date DESC")
    past = query("""SELECT * FROM v_patient_history WHERE admission_status <> 'ADMITTED'
                    ORDER BY discharge_date DESC NULLS LAST FETCH FIRST 20 ROWS ONLY""")
    return render_template("admissions.html", current=current, past=past)


@app.route("/admissions/<int:admission_id>/discharge", methods=["POST"])
@roles_required(ADMIN, DOCTOR)
def discharge(admission_id):
    run(lambda: call("pkg_bed_allocation.discharge_patient", admission_id, OUT_STR), lambda m: m)
    return redirect(url_for("admissions"))


@app.route("/admissions/<int:admission_id>/cancel", methods=["POST"])
@roles_required(ADMIN)
def cancel_admission(admission_id):
    run(lambda: call("pkg_bed_allocation.cancel_admission", admission_id,
                     form("reason") or "Entered in error", OUT_STR), lambda m: m)
    return redirect(url_for("admissions"))


# ------------------------------------------------------------------ lab

@app.route("/lab", methods=["GET", "POST"])
@roles_required(ADMIN, DOCTOR, LAB)
def lab():
    if request.method == "POST":
        if not has_role(ADMIN, LAB):
            abort(403)
        run(lambda: call("pkg_lab.record_result", form("admission_id", int), form("test_id", int),
                         form("result_value"), form("remarks"), OUT_NUM),
            lambda rid: f"Result {rid} recorded.")
        return redirect(url_for("lab"))
    results = query("SELECT * FROM v_lab_results_detail ORDER BY test_date DESC FETCH FIRST 100 ROWS ONLY")
    tests = query("SELECT * FROM lab_test ORDER BY test_name")
    current = query("SELECT admission_id, patient_name, ward_name, bed_number FROM v_current_admissions "
                    "ORDER BY patient_name")
    pending = query("SELECT * FROM v_lab_orders WHERE order_status = 'ORDERED' "
                    "ORDER BY CASE priority WHEN 'URGENT' THEN 0 ELSE 1 END, ordered_at")
    return render_template("lab.html", results=results, tests=tests, current=current, pending=pending)


@app.route("/lab/orders", methods=["POST"])
@roles_required(ADMIN, DOCTOR, NURSE)
def lab_order():
    run(lambda: call("pkg_lab.order_test", form("admission_id", int), form("test_id", int),
                     form("priority") or "ROUTINE", form("notes"), OUT_NUM),
        lambda oid: f"Lab order {oid} placed.")
    return back_to("lab")


@app.route("/lab/orders/<int:order_id>/complete", methods=["POST"])
@roles_required(ADMIN, LAB)
def lab_order_complete(order_id):
    run(lambda: call("pkg_lab.complete_order", order_id, form("result_value"), form("remarks"), OUT_NUM),
        f"Order {order_id} completed and result saved.")
    return back_to("lab")


@app.route("/lab/orders/<int:order_id>/cancel", methods=["POST"])
@roles_required(ADMIN, DOCTOR, NURSE)
def lab_order_cancel(order_id):
    run(lambda: call("pkg_lab.cancel_order", order_id, form("reason") or "Cancelled by " + session["username"]),
        f"Order {order_id} cancelled.")
    return back_to("lab")


@app.route("/lab/tests", methods=["POST"])
@roles_required(ADMIN)
def lab_tests():
    test_id = form("test_id", int)
    if test_id:
        run(lambda: call("pkg_admin.update_lab_test", test_id, form("test_name"), form("test_cost", float)),
            "Lab test updated.")
    else:
        run(lambda: call("pkg_admin.add_lab_test", form("test_name"), form("test_cost", float), OUT_NUM),
            "Lab test added.")
    return redirect(url_for("lab"))


# ------------------------------------------------------------------ billing

@app.route("/billing")
@roles_required(ADMIN, BILLING)
def billing():
    bills = query("SELECT * FROM v_bill_summary ORDER BY bill_id DESC")
    to_bill = query("SELECT * FROM v_admissions_to_bill ORDER BY discharge_date DESC")
    current = query("SELECT a.admission_id, a.patient_name, b.bill_id FROM v_current_admissions a "
                    "LEFT JOIN bill b ON b.admission_id = a.admission_id ORDER BY a.patient_name")
    return render_template("billing.html", bills=bills, to_bill=to_bill, current=current)


@app.route("/billing/generate", methods=["POST"])
@app.route("/billing/generate/<int:admission_id>", methods=["POST"])
@roles_required(ADMIN, BILLING)
def bill_generate(admission_id=None):
    admission_id = admission_id or form("admission_id", int)
    result = {}

    def generate():
        result["bill_id"], message = call("pkg_billing.generate_bill", admission_id, OUT_NUM, OUT_STR)
        return message

    if run(generate, lambda m: m):
        return redirect(url_for("bill_detail", bill_id=result["bill_id"]))
    return redirect(url_for("billing"))


@app.route("/billing/<int:bill_id>", methods=["GET", "POST"])
@roles_required(ADMIN, BILLING)
def bill_detail(bill_id):
    if request.method == "POST":
        action = request.form.get("action")
        if action == "item":
            run(lambda: call("pkg_billing.add_bill_item", bill_id, form("description"),
                             form("quantity", int), form("unit_price", float), OUT_NUM), "Item added.")
        elif action == "remove":
            run(lambda: call("pkg_billing.remove_bill_item", form("bill_item_id", int)), "Item removed.")
        elif action == "pay":
            run(lambda: call("pkg_billing.record_payment", bill_id, form("amount", float)), "Payment recorded.")
        return redirect(url_for("bill_detail", bill_id=bill_id))
    bill = query_one("SELECT * FROM v_bill_summary WHERE bill_id = :id", {"id": bill_id})
    if not bill:
        abort(404)
    items = query("SELECT * FROM bill_item WHERE bill_id = :id ORDER BY bill_item_id", {"id": bill_id})
    return render_template("bill_detail.html", bill=bill, items=items)


# ------------------------------------------------------------------ admin

@app.route("/admin/staff", methods=["GET", "POST"])
@roles_required(ADMIN)
def admin_staff():
    if request.method == "POST":
        args = (form("staff_name"), form("designation"), form("department"), form("phone"), form("email"))
        staff_id = form("staff_id", int)
        if staff_id:
            run(lambda: call("pkg_admin.update_staff", staff_id, *args), "Staff member updated.")
        else:
            run(lambda: call("pkg_admin.add_staff", *args, OUT_NUM), lambda sid: f"Staff member {sid} added.")
        return redirect(url_for("admin_staff"))
    staff = query("""SELECT s.*, u.username FROM staff s
                     LEFT JOIN user_account u ON u.staff_id = s.staff_id ORDER BY s.staff_id""")
    edit = query_one("SELECT * FROM staff WHERE staff_id = :id", {"id": request.args.get("edit", type=int)}) \
        if request.args.get("edit") else None
    return render_template("admin_staff.html", staff=staff, edit=edit,
                           designations=["Doctor", "Nurse", "Lab Staff", "Billing Staff", "Admin"])


@app.route("/admin/users", methods=["GET", "POST"])
@roles_required(ADMIN)
def admin_users():
    if request.method == "POST":
        action = request.form.get("action")
        user_id = form("user_id", int)
        if action == "create":
            run(lambda: call("pkg_admin.create_user", form("staff_id", int), form("role_name"),
                             form("username"), form("password"), OUT_NUM), "Account created.")
        elif action == "role":
            run(lambda: call("pkg_admin.set_user_role", user_id, form("role_name")), "Role changed.")
        elif action == "status":
            run(lambda: call("pkg_admin.set_user_status", user_id, form("status")), "Status changed.")
        elif action == "reset":
            run(lambda: call("pkg_admin.reset_password", user_id, form("password")), "Password reset.")
        return redirect(url_for("admin_users"))
    users = query("SELECT * FROM v_user_accounts ORDER BY user_id")
    roles = [r["role_name"] for r in query("SELECT role_name FROM role ORDER BY role_id")]
    no_account = query("""SELECT staff_id, staff_name, designation FROM staff s
                          WHERE NOT EXISTS (SELECT 1 FROM user_account u WHERE u.staff_id = s.staff_id)
                          ORDER BY staff_name""")
    return render_template("admin_users.html", users=users, roles=roles, no_account=no_account)


@app.route("/admin/wards", methods=["GET", "POST"])
@roles_required(ADMIN)
def admin_wards():
    if request.method == "POST":
        action = request.form.get("action")
        if action == "ward":
            run(lambda: call("pkg_admin.add_ward", form("ward_name"), form("ward_type"), form("floor_no", int),
                             form("capacity", int), form("reserved_critical_beds", int) or 0, OUT_NUM),
                "Ward added. Add a tariff and allocation rules for a new ward type.")
        elif action == "bed":
            run(lambda: call("pkg_admin.add_bed", form("ward_id", int), form("bed_number"), OUT_NUM), "Bed added.")
        elif action == "tariff":
            run(lambda: call("pkg_admin.set_ward_tariff", form("ward_type"), form("daily_rate", float)),
                "Tariff saved.")
        return redirect(url_for("admin_wards"))
    wards = query("SELECT * FROM v_bed_occupancy ORDER BY ward_id")
    tariffs = query("SELECT * FROM ward_tariff ORDER BY ward_type")
    return render_template("admin_wards.html", wards=wards, tariffs=tariffs, ward_types=ward_types())


@app.route("/admin/rules", methods=["GET", "POST"])
@roles_required(ADMIN)
def admin_rules():
    if request.method == "POST":
        action = request.form.get("action")
        if action == "rule":
            run(lambda: call("pkg_admin.save_ward_rule", form("rule_id", int), form("required_ward_type"),
                             form("allowed_ward_type"), form("preference_rank", int),
                             form("min_urgency_weight", int) or 0, form("rule_description"),
                             form("is_active") or "N"),
                "Rule saved.")
        elif action == "config":
            run(lambda: call("pkg_admin.set_config", form("config_key"), form("config_value", float)),
                "Setting saved.")
        return redirect(url_for("admin_rules"))
    rules = query("SELECT * FROM ward_compatibility ORDER BY required_ward_type, preference_rank")
    config = query("SELECT * FROM allocation_config ORDER BY config_key")
    urgency_levels = query("SELECT * FROM urgency_level ORDER BY base_weight DESC")
    return render_template("admin_rules.html", rules=rules, config=config, urgencies=urgency_levels,
                           ward_types=ward_types())


# ------------------------------------------------------------------ reports

REPORTS = [
    ("Bed occupancy by ward", "SELECT ward_name, ward_type, total_beds, available_beds, occupied_beds, "
     "awaiting_cleaning_beds, awaiting_inspection_beds, maintenance_beds, occupancy_pct "
     "FROM v_bed_occupancy ORDER BY occupancy_pct DESC"),
    ("Bed turnaround by ward (completed cycles, slowest first)",
     "SELECT slowest_rank, ward_name, cycles, avg_cleaning_minutes, max_cleaning_minutes, avg_inspection_minutes, "
     "max_inspection_minutes, avg_total_minutes, max_total_minutes, inspection_failures, cleaning_over_target, "
     "inspection_over_target FROM v_ward_turnaround ORDER BY slowest_rank"),
    ("Beds held up while patients wait", "SELECT ward_type, waiting_patients, longest_wait_minutes, ward_name, "
     "bed_number, reason, minutes_in_state, past_target FROM v_beds_blocking_queue ORDER BY ward_type, minutes_in_state DESC"),
    ("Waiting time by urgency", "SELECT urgency_code, target_wait_minutes, requests, allocated, still_waiting, "
     "cancelled, avg_wait_minutes, max_wait_minutes FROM v_queue_wait_stats ORDER BY base_weight DESC"),
    ("Doctor workload", "SELECT doctor_name, department, current_patients, patients_waiting, total_admissions "
     "FROM v_doctor_workload ORDER BY current_patients DESC, doctor_name"),
    ("Allocations using fallback wards, age rules or reserved beds",
     "SELECT acted_at, patient_name, ward_name, bed_number, priority_score, rule_applied, acted_by "
     "FROM v_allocation_history WHERE action = 'ALLOCATED' AND (rule_applied LIKE 'Fallback%' "
     "OR rule_applied LIKE '%reserved%' OR rule_applied LIKE 'Age rule%' OR rule_applied LIKE 'Manual%') "
     "ORDER BY acted_at DESC"),
    ("Lab order turnaround by test (order to result)",
     "SELECT test_name, completed_orders, urgent_orders, avg_minutes_to_result, max_minutes_to_result "
     "FROM v_lab_order_turnaround ORDER BY avg_minutes_to_result DESC"),
    ("Lab tests performed and revenue", "SELECT t.test_name, COUNT(r.result_id) AS times_done, "
     "COUNT(r.result_id) * t.test_cost AS revenue FROM lab_test t LEFT JOIN lab_result r ON r.test_id = t.test_id "
     "GROUP BY t.test_name, t.test_cost ORDER BY times_done DESC, t.test_name"),
    ("Outstanding bills", "SELECT bill_id, patient_name, total_amount, amount_paid, balance_due, payment_status "
     "FROM v_unpaid_bills ORDER BY balance_due DESC"),
    ("Revenue by source", "SELECT source_type, COUNT(*) AS lines, SUM(amount) AS amount FROM bill_item "
     "GROUP BY source_type ORDER BY amount DESC"),
    ("Allocation audit log (latest 50)", "SELECT acted_at, action, patient_name, ward_name, bed_number, "
     "priority_score, rule_applied, acted_by FROM v_allocation_history ORDER BY log_id DESC "
     "FETCH FIRST 50 ROWS ONLY"),
]


@app.route("/reports")
@roles_required(ADMIN)
def reports():
    sections = []
    for title, sql in REPORTS:
        rows = query(sql)
        columns = list(rows[0].keys()) if rows else []
        sections.append({"title": title, "rows": rows, "columns": columns, "sql": sql})
    return render_template("reports.html", sections=sections)


if __name__ == "__main__":
    app.run(debug=os.environ.get("FLASK_DEBUG") == "1", port=int(os.environ.get("PORT", 5000)))
