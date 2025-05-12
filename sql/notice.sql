-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

DO language plpgsql $$
DECLARE
  telemetry_string TEXT;
  telemetry_level text;
BEGIN
  telemetry_level := current_setting('timeudb.telemetry_level', true);
  CASE telemetry_level
  WHEN 'off' THEN
    telemetry_string = E'Note: Please enable telemetry to help us improve our product by running: ALTER DATABASE "' || current_database() || E'" SET timeudb.telemetry_level = ''basic'';';
  WHEN 'basic' THEN
    telemetry_string = E'Note: TIMEUDB collects anonymous reports to better understand and assist our users.\nFor more information and how to disable, please see our docs https://docs.timescale.com/timeudb/latest/how-to-guides/configuration/telemetry.';
  ELSE
    telemetry_string = E'';
  END CASE;
END;
$$;
