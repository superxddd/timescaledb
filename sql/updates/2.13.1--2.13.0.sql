-- Manually drop the following functions / procedures since 'OR REPLACE' is missing in 2.13.0
DROP PROCEDURE IF EXISTS _timeudb_functions.repair_relation_acls();
DROP FUNCTION IF EXISTS _timeudb_functions.makeaclitem(regrole, regrole, text, bool);
