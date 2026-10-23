"""Signs in as every role and checks which pages each one can open (200) or is refused (403).

Run:  .venv\\Scripts\\python tests\\smoke_test.py   (from the frontend folder)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import app  # noqa: E402

PAGES = ["/", "/patients", "/admit", "/queue", "/beds", "/admissions", "/lab", "/billing",
         "/admin/staff", "/admin/users", "/admin/wards", "/admin/rules", "/reports", "/account/password"]

ALLOWED = {
    "admin": set(PAGES),
    "rahul": {"/", "/patients", "/admit", "/queue", "/beds", "/admissions", "/lab", "/account/password"},
    "ananya": {"/", "/patients", "/admit", "/queue", "/beds", "/admissions", "/account/password"},
    "riya": {"/", "/admissions", "/lab", "/account/password"},
    "arjun": {"/", "/billing", "/account/password"},
}


def login(client, username):
    client.get("/login")
    with client.session_transaction() as sess:
        token = sess["csrf"]
    resp = client.post("/login", data={"username": username, "password": username + "123", "csrf": token})
    assert resp.status_code == 302, f"login failed for {username}"
    return token


def main():
    failures = 0
    for username, allowed in ALLOWED.items():
        client = app.test_client()
        token = login(client, username)
        for page in PAGES:
            status = client.get(page).status_code
            expected = 200 if page in allowed else 403
            if status != expected:
                failures += 1
                print(f"FAIL {username:7} {page:18} got {status}, expected {expected}")
        # Bed turnaround actions: only ADMIN and NURSE may submit them (others get 403).
        # A non-existent bed id is used so the check never changes real data: allowed roles get
        # a "Bed does not exist" message (redirect), everyone else is refused before the database.
        turnaround_allowed = username in ("admin", "ananya")
        for path, data in (("/beds/999999/cleaned", {}), ("/beds/999999/inspect", {"passed": "Y"})):
            status = client.post(path, data={**data, "csrf": token}).status_code
            if (status == 403) == turnaround_allowed:
                failures += 1
                print(f"FAIL {username:7} POST {path:18} got {status}")
        # A forged POST without the CSRF token is rejected
        if client.post("/queue/process").status_code != 400:
            failures += 1
            print(f"FAIL {username} POST without CSRF token was accepted")
        print(f"{username:7} checked {len(PAGES)} pages + 2 bed turnaround actions")
        client.post("/logout", data={"csrf": token})

    anon = app.test_client()
    if anon.get("/patients").status_code != 302:
        failures += 1
        print("FAIL anonymous user was not redirected to login")

    print("ALL PASS" if not failures else f"{failures} FAILURE(S)")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
