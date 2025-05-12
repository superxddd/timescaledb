-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

SET LOCAL search_path TO pg_catalog, pg_temp;

CREATE SCHEMA _timeudb_catalog;
CREATE SCHEMA _timeudb_functions;
CREATE SCHEMA _timeudb_internal;
CREATE SCHEMA _timeudb_cache;
CREATE SCHEMA _timeudb_config;
CREATE SCHEMA timeudb_experimental;
CREATE SCHEMA timeudb_information;
CREATE SCHEMA _timeudb_debug;

GRANT USAGE ON SCHEMA
      _timeudb_cache,
      _timeudb_catalog,
      _timeudb_functions,
      _timeudb_internal,
      _timeudb_config,
      timeudb_information,
      timeudb_experimental
TO PUBLIC;

