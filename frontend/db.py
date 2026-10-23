"""Oracle access layer.

Every request borrows a pooled connection and tags it with the signed-in username
(client_identifier). pkg_security.assert_role reads that tag, so the database itself
refuses actions the user's role does not allow, even if a page check were bypassed.
"""
import os
import re

import oracledb
from flask import g, session

_pool = None


class DbError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class Out:
    """Marker for an OUT parameter of a stored procedure."""

    def __init__(self, py_type, size=None):
        self.py_type = py_type
        self.size = size


OUT_NUM = Out(int)
OUT_STR = Out(str, 4000)
OUT_CURSOR = Out(oracledb.DB_TYPE_CURSOR)

_FRIENDLY = {
    1: "That value already exists (it must be unique).",
    1400: "A required field is missing.",
    2290: "A value is not allowed (check constraint).",
    2291: "A referenced record does not exist.",
    2292: "This record is still referenced by other records.",
    1840: "Invalid date.",
    1861: "Invalid date format.",
}


def init_pool(app):
    global _pool
    _pool = oracledb.create_pool(
        user=os.environ.get("DB_USER", "hms"),
        password=os.environ.get("DB_PASSWORD", "hms123"),
        dsn=os.environ.get("DB_DSN", "localhost/XEPDB1"),
        min=1,
        max=8,
        increment=1,
    )
    app.teardown_appcontext(_release)


def _release(_exc=None):
    conn = g.pop("db", None)
    if conn is not None:
        conn.rollback()
        _pool.release(conn)


def get_db():
    if "db" not in g:
        conn = _pool.acquire()
        # Pooled connections keep the previous request's identifier, so always set or clear it
        # (assigning "" to conn.client_identifier makes the thin driver drop the connection)
        with conn.cursor() as cur:
            username = session.get("username")
            if username:
                cur.callproc("dbms_session.set_identifier", [username])
            else:
                cur.callproc("dbms_session.clear_identifier")
        g.db = conn
    return g.db


def _to_db_error(exc):
    err = exc.args[0]
    code = getattr(err, "code", 0)
    first_line = str(getattr(err, "message", err)).splitlines()[0]
    if 20000 <= code <= 20999:
        return DbError(code, re.sub(r"^ORA-\d+:\s*", "", first_line))
    if code == 1:
        columns = _constraint_columns(first_line)
        if columns:
            return DbError(code, f"That {columns} is already in use.")
    if code in _FRIENDLY:
        detail = re.search(r"\(([^)]+)\)", first_line)
        suffix = f" [{detail.group(1)}]" if detail else ""
        return DbError(code, _FRIENDLY[code] + suffix)
    return DbError(code, first_line)


def _constraint_columns(message):
    """'unique constraint (HMS.SYS_C008367) violated' -> 'phone'"""
    match = re.search(r"\((\w+)\.(\w+)\)", message)
    if not match:
        return None
    try:
        with get_db().cursor() as cur:
            cur.execute("SELECT LOWER(LISTAGG(column_name, ', ') WITHIN GROUP (ORDER BY position)) "
                        "FROM user_cons_columns WHERE constraint_name = :c", c=match.group(2))
            row = cur.fetchone()
        if row and row[0]:
            return row[0].replace("_", " ")
        # Function-based unique indexes have no constraint row
        return None
    except oracledb.DatabaseError:
        return None


def _rows(cursor):
    cols = [d[0].lower() for d in cursor.description]
    return [dict(zip(cols, row)) for row in cursor]


def query(sql, params=None):
    with get_db().cursor() as cur:
        try:
            cur.execute(sql, params or {})
        except oracledb.DatabaseError as exc:
            raise _to_db_error(exc) from exc
        return _rows(cur)


def query_one(sql, params=None):
    rows = query(sql, params)
    return rows[0] if rows else None


def call(name, *args):
    """Call a stored procedure. Pass OUT_NUM / OUT_STR / OUT_CURSOR for OUT parameters.

    Returns the OUT values (a single value, a list, or None). Cursors come back as lists of dicts.
    """
    cur = get_db().cursor()
    params, outs = [], []
    for arg in args:
        if isinstance(arg, Out):
            var = cur.var(arg.py_type, arg.size) if arg.size else cur.var(arg.py_type)
            params.append(var)
            outs.append((arg, var))
        else:
            params.append(arg)
    try:
        cur.callproc(name, params)
        values = []
        for marker, var in outs:
            value = var.getvalue()
            if marker.py_type is oracledb.DB_TYPE_CURSOR:
                value = _rows(value)
            values.append(value)
    except oracledb.DatabaseError as exc:
        raise _to_db_error(exc) from exc
    finally:
        cur.close()
    if not values:
        return None
    return values[0] if len(values) == 1 else values


def call_func(name, return_type, *args):
    with get_db().cursor() as cur:
        try:
            return cur.callfunc(name, return_type, list(args))
        except oracledb.DatabaseError as exc:
            raise _to_db_error(exc) from exc
