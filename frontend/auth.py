"""Application-layer role enforcement (the database checks again in pkg_security)."""
from functools import wraps

from flask import abort, redirect, request, session, url_for

ADMIN = "ADMIN"
DOCTOR = "DOCTOR"
NURSE = "NURSE"
LAB = "LAB_STAFF"
BILLING = "BILLING_STAFF"
ALL_ROLES = (ADMIN, DOCTOR, NURSE, LAB, BILLING)

CLINICAL = (ADMIN, DOCTOR, NURSE)

# (endpoint, label, roles allowed) - drives the navigation bar
NAV = [
    ("dashboard", "Dashboard", ALL_ROLES),
    ("patients", "Patients", CLINICAL),
    ("admit", "Admit", CLINICAL),
    ("queue", "Waiting queue", CLINICAL),
    ("beds", "Beds", CLINICAL),
    ("admissions", "Admissions", (ADMIN, DOCTOR, NURSE, LAB)),
    ("lab", "Lab", (ADMIN, DOCTOR, LAB)),
    ("billing", "Billing", (ADMIN, BILLING)),
    ("admin_staff", "Staff", (ADMIN,)),
    ("admin_users", "Users", (ADMIN,)),
    ("admin_wards", "Wards", (ADMIN,)),
    ("admin_rules", "Allocation rules", (ADMIN,)),
    ("reports", "Reports", (ADMIN,)),
]


def current_role():
    return session.get("role")


def has_role(*roles):
    return current_role() in roles


def login_required(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        if "username" not in session:
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)

    return wrapper


def roles_required(*roles):
    def decorator(view):
        @wraps(view)
        @login_required
        def wrapper(*args, **kwargs):
            if current_role() not in roles:
                abort(403)
            return view(*args, **kwargs)

        return wrapper

    return decorator


def nav_for_role(role):
    return [(endpoint, label) for endpoint, label, roles in NAV if role in roles]
