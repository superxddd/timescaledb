GRANT ALL ON _timeudb_internal.job_errors TO PUBLIC;

ALTER EXTENSION timeudb DROP VIEW timeudb_information.job_errors;

DROP VIEW timeudb_information.job_errors;
