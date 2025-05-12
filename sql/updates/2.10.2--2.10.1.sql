DROP FUNCTION _timeudb_internal.ping_data_node(NAME, INTERVAL);

CREATE OR REPLACE FUNCTION _timeudb_internal.ping_data_node(node_name NAME) RETURNS BOOLEAN
AS '@MODULE_PATHNAME@', 'ts_data_node_ping' LANGUAGE C VOLATILE;

-- drop dependent views
DROP VIEW IF EXISTS timeudb_information.job_errors;
DROP VIEW IF EXISTS timeudb_information.job_stats;
DROP VIEW IF EXISTS timeudb_information.jobs;
DROP VIEW IF EXISTS timeudb_experimental.policies;

ALTER TABLE _timeudb_config.bgw_job
    ALTER COLUMN owner DROP DEFAULT,
    ALTER COLUMN owner TYPE name USING owner::name,
    ALTER COLUMN owner SET DEFAULT current_role;
CREATE TABLE _timeudb_config.bgw_job_tmp AS SELECT * FROM _timeudb_config.bgw_job;

ALTER EXTENSION timeudb DROP TABLE _timeudb_config.bgw_job;
ALTER EXTENSION timeudb DROP SEQUENCE _timeudb_config.bgw_job_id_seq;
ALTER TABLE _timeudb_internal.bgw_job_stat
      DROP CONSTRAINT IF EXISTS bgw_job_stat_job_id_fkey;
ALTER TABLE _timeudb_internal.bgw_policy_chunk_stats
      DROP CONSTRAINT IF EXISTS bgw_policy_chunk_stats_job_id_fkey;
CREATE TABLE _timeudb_internal.tmp_bgw_job_seq_value AS
       SELECT last_value, is_called FROM _timeudb_config.bgw_job_id_seq;
DROP TABLE _timeudb_config.bgw_job;

CREATE SEQUENCE _timeudb_config.bgw_job_id_seq MINVALUE 1000;
SELECT pg_catalog.pg_extension_config_dump('_timeudb_config.bgw_job_id_seq', '');
SELECT pg_catalog.setval('_timeudb_config.bgw_job_id_seq', last_value, is_called)
  FROM _timeudb_internal.tmp_bgw_job_seq_value;
DROP TABLE _timeudb_internal.tmp_bgw_job_seq_value;

CREATE TABLE _timeudb_config.bgw_job (
  id integer NOT NULL DEFAULT nextval('_timeudb_config.bgw_job_id_seq'),
  application_name name NOT NULL,
  schedule_interval interval NOT NULL,
  max_runtime interval NOT NULL,
  max_retries integer NOT NULL,
  retry_period interval NOT NULL,
  proc_schema name NOT NULL,
  proc_name name NOT NULL,
  owner name NOT NULL DEFAULT current_role,
  scheduled bool NOT NULL DEFAULT TRUE,
  fixed_schedule bool not null default true,
  initial_start timestamptz,
  hypertable_id integer,
  config jsonb,
  check_schema name,
  check_name name,
  timezone text,
  CONSTRAINT bgw_job_pkey PRIMARY KEY (id),
  CONSTRAINT bgw_job_hypertable_id_fkey FOREIGN KEY (hypertable_id) REFERENCES _timeudb_catalog.hypertable (id) ON DELETE CASCADE
);

ALTER SEQUENCE _timeudb_config.bgw_job_id_seq OWNED BY _timeudb_config.bgw_job.id;
CREATE INDEX bgw_job_proc_hypertable_id_idx
       ON _timeudb_config.bgw_job(proc_schema,proc_name,hypertable_id);
INSERT INTO _timeudb_config.bgw_job
       SELECT * FROM _timeudb_config.bgw_job_tmp ORDER BY id;
DROP TABLE _timeudb_config.bgw_job_tmp;
ALTER TABLE _timeudb_internal.bgw_job_stat
      ADD CONSTRAINT bgw_job_stat_job_id_fkey
      	  FOREIGN KEY(job_id)
	  REFERENCES _timeudb_config.bgw_job(id)
	  ON DELETE CASCADE;
ALTER TABLE _timeudb_internal.bgw_policy_chunk_stats
      ADD CONSTRAINT bgw_policy_chunk_stats_job_id_fkey
      	  FOREIGN KEY(job_id)
	  REFERENCES _timeudb_config.bgw_job(id)
	  ON DELETE CASCADE;

SELECT pg_catalog.pg_extension_config_dump('_timeudb_config.bgw_job', 'WHERE id >= 1000');
GRANT SELECT ON _timeudb_config.bgw_job TO PUBLIC;
GRANT SELECT ON _timeudb_config.bgw_job_id_seq TO PUBLIC;
