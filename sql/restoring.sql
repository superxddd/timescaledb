-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

CREATE OR REPLACE FUNCTION @extschema@.timeudb_pre_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
BEGIN
    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I SET timeudb.restoring ='on'$$, db);
    SET SESSION timeudb.restoring = 'on';
    PERFORM _timeudb_functions.stop_background_workers();
    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL SET search_path TO pg_catalog, pg_temp;


CREATE OR REPLACE FUNCTION @extschema@.timeudb_post_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
    catalog_version text;
BEGIN
    SELECT m.value INTO catalog_version FROM pg_extension x
    JOIN _timeudb_catalog.metadata m ON m.key='timeudb_version'
    WHERE x.extname='timeudb' AND x.extversion <> m.value;

    -- check that a loaded dump is compatible with the currently running code
    IF FOUND THEN
        RAISE EXCEPTION 'catalog version mismatch, expected "%" seen "%"', '@PROJECT_VERSION_MOD@', catalog_version;
    END IF;

    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I RESET timeudb.restoring $$, db);
    -- we cannot use reset here because the reset_val might not be off
    SET timeudb.restoring TO off;
    PERFORM _timeudb_functions.restart_background_workers();

    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL SET search_path TO pg_catalog, pg_temp;
