-- SECURITY PACKAGE
-- Login check and role enforcement inside the database.
--
-- Who is the caller?
--   * The web app connects as the schema owner and tags every request with the logged-in
--     username via the client identifier (DBMS_SESSION.SET_IDENTIFIER / oracledb client_identifier).
--   * Any other Oracle login (see 70_db_roles.sql) is mapped through user_account.db_username,
--     so those users cannot impersonate someone else by setting a client identifier.

CREATE OR REPLACE PACKAGE pkg_security AS

    FUNCTION hash_password (p_password IN VARCHAR2) RETURN VARCHAR2;

    -- Returns the role name for valid credentials of an ACTIVE account, otherwise NULL
    FUNCTION authenticate (p_username IN VARCHAR2, p_password IN VARCHAR2) RETURN VARCHAR2;

    FUNCTION current_username RETURN VARCHAR2;
    FUNCTION current_user_id RETURN NUMBER;
    FUNCTION current_staff_id RETURN NUMBER;
    FUNCTION current_role RETURN VARCHAR2;

    -- Raises ORA-20100 unless the caller's role is in the comma separated list, e.g. 'ADMIN,DOCTOR'
    PROCEDURE assert_role (p_allowed_roles IN VARCHAR2);

    FUNCTION has_role (p_allowed_roles IN VARCHAR2) RETURN BOOLEAN;

END pkg_security;
/

CREATE OR REPLACE PACKAGE BODY pkg_security AS

    FUNCTION hash_password (p_password IN VARCHAR2) RETURN VARCHAR2 IS
        v_hash VARCHAR2(64);
    BEGIN
        SELECT RAWTOHEX(STANDARD_HASH(p_password, 'SHA256')) INTO v_hash FROM dual;
        RETURN v_hash;
    END hash_password;


    FUNCTION authenticate (p_username IN VARCHAR2, p_password IN VARCHAR2) RETURN VARCHAR2 IS
        v_role role.role_name%TYPE;
    BEGIN
        SELECT r.role_name INTO v_role
        FROM user_account u
        JOIN role r ON r.role_id = u.role_id
        WHERE u.username = LOWER(TRIM(p_username))
        AND u.password = hash_password(p_password)
        AND u.account_status = 'ACTIVE';

        RETURN v_role;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END authenticate;


    FUNCTION current_username RETURN VARCHAR2 IS
        v_username user_account.username%TYPE;
    BEGIN
        -- Schema owner = the trusted application connection: trust the client identifier
        IF SYS_CONTEXT('USERENV','SESSION_USER') = SYS_CONTEXT('USERENV','CURRENT_USER') THEN
            RETURN LOWER(SYS_CONTEXT('USERENV','CLIENT_IDENTIFIER'));
        END IF;

        SELECT username INTO v_username
        FROM user_account
        WHERE db_username = SYS_CONTEXT('USERENV','SESSION_USER');

        RETURN v_username;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END current_username;


    FUNCTION current_user_id RETURN NUMBER IS
        v_id user_account.user_id%TYPE;
    BEGIN
        SELECT user_id INTO v_id FROM user_account WHERE username = current_username;
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END current_user_id;


    FUNCTION current_staff_id RETURN NUMBER IS
        v_id user_account.staff_id%TYPE;
    BEGIN
        SELECT staff_id INTO v_id FROM user_account WHERE username = current_username;
        RETURN v_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END current_staff_id;


    FUNCTION current_role RETURN VARCHAR2 IS
        v_role role.role_name%TYPE;
    BEGIN
        SELECT r.role_name INTO v_role
        FROM user_account u
        JOIN role r ON r.role_id = u.role_id
        WHERE u.username = current_username
        AND u.account_status = 'ACTIVE';

        RETURN v_role;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END current_role;


    FUNCTION has_role (p_allowed_roles IN VARCHAR2) RETURN BOOLEAN IS
        v_role role.role_name%TYPE := current_role;
    BEGIN
        RETURN v_role IS NOT NULL
           AND INSTR(',' || UPPER(REPLACE(p_allowed_roles, ' ')) || ',', ',' || v_role || ',') > 0;
    END has_role;


    PROCEDURE assert_role (p_allowed_roles IN VARCHAR2) IS
    BEGIN
        IF current_username IS NULL THEN
            RAISE_APPLICATION_ERROR(-20100, 'Access denied: no application user is signed in');
        END IF;

        IF NOT has_role(p_allowed_roles) THEN
            RAISE_APPLICATION_ERROR(-20100, 'Access denied: user ' || current_username
                || ' (' || NVL(current_role, 'no active role') || ') is not allowed to do this. Required: '
                || p_allowed_roles);
        END IF;
    END assert_role;

END pkg_security;
/
