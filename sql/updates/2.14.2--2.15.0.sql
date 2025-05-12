-- Remove multi-node CAGG support
DROP FUNCTION IF EXISTS _timeudb_internal.invalidation_cagg_log_add_entry(integer,bigint,bigint);
DROP FUNCTION IF EXISTS _timeudb_internal.invalidation_hyper_log_add_entry(integer,bigint,bigint);
DROP FUNCTION IF EXISTS _timeudb_internal.materialization_invalidation_log_delete(integer);
DROP FUNCTION IF EXISTS _timeudb_internal.invalidation_process_cagg_log(integer,integer,regtype,bigint,bigint,integer[],bigint[],bigint[]);
DROP FUNCTION IF EXISTS _timeudb_internal.invalidation_process_cagg_log(integer,integer,regtype,bigint,bigint,integer[],bigint[],bigint[],text[]);
DROP FUNCTION IF EXISTS _timeudb_internal.invalidation_process_hypertable_log(integer,integer,regtype,integer[],bigint[],bigint[]);
DROP FUNCTION IF EXISTS _timeudb_internal.invalidation_process_hypertable_log(integer,integer,regtype,integer[],bigint[],bigint[],text[]);
DROP FUNCTION IF EXISTS _timeudb_internal.hypertable_invalidation_log_delete(integer);

DROP FUNCTION IF EXISTS _timeudb_functions.invalidation_cagg_log_add_entry(integer,bigint,bigint);
DROP FUNCTION IF EXISTS _timeudb_functions.invalidation_hyper_log_add_entry(integer,bigint,bigint);
DROP FUNCTION IF EXISTS _timeudb_functions.materialization_invalidation_log_delete(integer);
DROP FUNCTION IF EXISTS _timeudb_functions.invalidation_process_cagg_log(integer,integer,regtype,bigint,bigint,integer[],bigint[],bigint[]);
DROP FUNCTION IF EXISTS _timeudb_functions.invalidation_process_cagg_log(integer,integer,regtype,bigint,bigint,integer[],bigint[],bigint[],text[]);
DROP FUNCTION IF EXISTS _timeudb_functions.invalidation_process_hypertable_log(integer,integer,regtype,integer[],bigint[],bigint[]);
DROP FUNCTION IF EXISTS _timeudb_functions.invalidation_process_hypertable_log(integer,integer,regtype,integer[],bigint[],bigint[],text[]);
DROP FUNCTION IF EXISTS _timeudb_functions.hypertable_invalidation_log_delete(integer);

-- Remove chunk metadata when marked as dropped
CREATE FUNCTION _timeudb_functions.remove_dropped_chunk_metadata(_hypertable_id INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
  _chunk_id INTEGER;
  _removed INTEGER := 0;
BEGIN
  FOR _chunk_id IN
    SELECT id FROM _timeudb_catalog.chunk
    WHERE hypertable_id = _hypertable_id
    AND dropped IS TRUE
    AND NOT EXISTS (
        SELECT FROM information_schema.tables
        WHERE tables.table_schema = chunk.schema_name
        AND tables.table_name = chunk.table_name
    )
    AND NOT EXISTS (
        SELECT FROM _timeudb_catalog.hypertable
        JOIN _timeudb_catalog.continuous_agg ON continuous_agg.raw_hypertable_id = hypertable.id
        WHERE hypertable.id = chunk.hypertable_id
        -- for the old caggs format we need to keep chunk metadata for dropped chunks
        AND continuous_agg.finalized IS FALSE
    )
  LOOP
    _removed := _removed + 1;
    RAISE INFO 'Removing metadata of chunk % from hypertable %', _chunk_id, _hypertable_id;
    WITH _dimension_slice_remove AS (
        DELETE FROM _timeudb_catalog.dimension_slice
        USING _timeudb_catalog.chunk_constraint
        WHERE dimension_slice.id = chunk_constraint.dimension_slice_id
        AND chunk_constraint.chunk_id = _chunk_id
        RETURNING _timeudb_catalog.dimension_slice.id
    )
    DELETE FROM _timeudb_catalog.chunk_constraint
    USING _dimension_slice_remove
    WHERE chunk_constraint.dimension_slice_id = _dimension_slice_remove.id;

    DELETE FROM _timeudb_internal.bgw_policy_chunk_stats
    WHERE bgw_policy_chunk_stats.chunk_id = _chunk_id;

    DELETE FROM _timeudb_catalog.chunk_index
    WHERE chunk_index.chunk_id = _chunk_id;

    DELETE FROM _timeudb_catalog.compression_chunk_size
    WHERE compression_chunk_size.chunk_id = _chunk_id
    OR compression_chunk_size.compressed_chunk_id = _chunk_id;

    DELETE FROM _timeudb_catalog.chunk
    WHERE chunk.id = _chunk_id
    OR chunk.compressed_chunk_id = _chunk_id;
  END LOOP;

  RETURN _removed;
END;
$$ SET search_path TO pg_catalog, pg_temp;

SELECT _timeudb_functions.remove_dropped_chunk_metadata(id) AS chunks_metadata_removed
FROM _timeudb_catalog.hypertable;

--
-- Rebuild the catalog table `_timeudb_catalog.continuous_aggs_bucket_function`
--

CREATE OR REPLACE FUNCTION _timeudb_functions.cagg_get_bucket_function(
    mat_hypertable_id INTEGER
) RETURNS regprocedure AS '@MODULE_PATHNAME@', 'ts_continuous_agg_get_bucket_function' LANGUAGE C STRICT VOLATILE;

-- Since we need now the regclass of the used bucket function, we have to recover it
-- by parsing the view query by calling 'cagg_get_bucket_function'.
CREATE TABLE _timeudb_catalog._tmp_continuous_aggs_bucket_function AS
    SELECT
      mat_hypertable_id,
      _timeudb_functions.cagg_get_bucket_function(mat_hypertable_id),
      bucket_width,
      origin,
      NULL::text AS bucket_offset,
      timezone,
      false AS bucket_fixed_width
    FROM
      _timeudb_catalog.continuous_aggs_bucket_function
    ORDER BY
         mat_hypertable_id;

ALTER EXTENSION timeudb
    DROP TABLE _timeudb_catalog.continuous_aggs_bucket_function;

DROP TABLE _timeudb_catalog.continuous_aggs_bucket_function;

CREATE TABLE _timeudb_catalog.continuous_aggs_bucket_function (
  mat_hypertable_id integer NOT NULL,
  -- The bucket function
  bucket_func regprocedure NOT NULL,
  -- `bucket_width` argument of the function, e.g. "1 month"
  bucket_width text NOT NULL,
  -- optional `origin` argument of the function provided by the user
  bucket_origin text,
  -- optional `offset` argument of the function provided by the user
  bucket_offset text,
  -- optional `timezone` argument of the function provided by the user
  bucket_timezone text,
  -- fixed or variable sized bucket
  bucket_fixed_width bool NOT NULL,
  -- table constraints
  CONSTRAINT continuous_aggs_bucket_function_pkey PRIMARY KEY (mat_hypertable_id),
  CONSTRAINT continuous_aggs_bucket_function_mat_hypertable_id_fkey FOREIGN KEY (mat_hypertable_id) REFERENCES _timeudb_catalog.hypertable (id) ON DELETE CASCADE
);

INSERT INTO _timeudb_catalog.continuous_aggs_bucket_function
  SELECT * FROM _timeudb_catalog._tmp_continuous_aggs_bucket_function;

DROP TABLE _timeudb_catalog._tmp_continuous_aggs_bucket_function;

SELECT pg_catalog.pg_extension_config_dump('_timeudb_catalog.continuous_aggs_bucket_function', '');

GRANT SELECT ON TABLE _timeudb_catalog.continuous_aggs_bucket_function TO PUBLIC;

ANALYZE _timeudb_catalog.continuous_aggs_bucket_function;

ALTER EXTENSION timeudb DROP FUNCTION _timeudb_functions.cagg_get_bucket_function(INTEGER);
DROP FUNCTION IF EXISTS _timeudb_functions.cagg_get_bucket_function(INTEGER);

--
-- End rebuild the catalog table `_timeudb_catalog.continuous_aggs_bucket_function`
--

-- Convert _timeudb_catalog.continuous_aggs_bucket_function.bucket_origin to TimestampTZ
UPDATE _timeudb_catalog.continuous_aggs_bucket_function
   SET bucket_origin = bucket_origin::timestamp::timestamptz::text
   WHERE length(bucket_origin) > 1;

-- Historically, we have used empty strings for undefined bucket_origin and timezone
-- attributes. This is now replaced by proper NULL values. We use TRIM() to ensure we handle empty string well.
UPDATE _timeudb_catalog.continuous_aggs_bucket_function SET bucket_origin = NULL WHERE TRIM(bucket_origin) = '';
UPDATE _timeudb_catalog.continuous_aggs_bucket_function SET bucket_timezone = NULL WHERE TRIM(bucket_timezone) = '';

-- So far, there were no difference between 0 and -1 retries. Since now on, 0 means no retries. Updating the retry
-- count of existing jobs to -1 to keep the current semantics.
UPDATE _timeudb_config.bgw_job SET max_retries = -1 WHERE max_retries = 0;

DROP FUNCTION IF EXISTS _timeudb_functions.get_chunk_relstats;
DROP FUNCTION IF EXISTS _timeudb_functions.get_chunk_colstats;
DROP FUNCTION IF EXISTS _timeudb_internal.get_chunk_relstats;
DROP FUNCTION IF EXISTS _timeudb_internal.get_chunk_colstats;

-- In older TSDB versions, we disabled autovacuum for compressed chunks
-- to keep the statistics. However, this restriction was removed in
-- #5118 but no migration was performed to remove the custom
-- autovacuum setting for existing chunks.
DO $$
DECLARE
  chunk regclass;
BEGIN
  FOR chunk IN
    SELECT pg_catalog.format('%I.%I', schema_name, table_name)::regclass
      FROM _timeudb_catalog.chunk c
      JOIN pg_catalog.pg_class AS pc ON (pc.oid=format('%I.%I', schema_name, table_name)::regclass)
      CROSS JOIN unnest(reloptions) AS u(option)
      WHERE
        dropped = false
        AND osm_chunk = false
        AND option LIKE 'autovacuum_enabled%'
  LOOP
    EXECUTE pg_catalog.format('ALTER TABLE %s RESET (autovacuum_enabled);', chunk::text);
  END LOOP;
END
$$;

--
-- Rebuild the catalog table `_timeudb_catalog.continuous_agg`
--

-- (1) Create missing entries in _timeudb_catalog.continuous_aggs_bucket_function
CREATE OR REPLACE FUNCTION _timeudb_functions.cagg_get_bucket_function(
    mat_hypertable_id INTEGER
) RETURNS regprocedure AS '@MODULE_PATHNAME@', 'ts_continuous_agg_get_bucket_function' LANGUAGE C STRICT VOLATILE;

-- Make sure function points to the new version of TSDB
CREATE OR REPLACE FUNCTION _timeudb_functions.to_interval(unixtime_us BIGINT) RETURNS INTERVAL
    AS '@MODULE_PATHNAME@', 'ts_pg_unix_microseconds_to_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- We need to create entries in continuous_aggs_bucket_function for all CAggs that were treated so far
-- as fixed indicated by a bucket_width != -1
INSERT INTO _timeudb_catalog.continuous_aggs_bucket_function
  SELECT
  mat_hypertable_id,
  _timeudb_functions.cagg_get_bucket_function(mat_hypertable_id),
  -- Intervals needs to be converted into the proper interval format
  -- Function name could be prefixed with 'public.'. Therefore LIKE instead of starts_with is used
  CASE WHEN _timeudb_functions.cagg_get_bucket_function(mat_hypertable_id)::text LIKE '%time_bucket(interval,%' THEN
    _timeudb_functions.to_interval(bucket_width)::text
  ELSE
    bucket_width::text
  END,
  NULL, -- bucket_origin
  NULL, -- bucket_offset
  NULL, -- bucket_timezone
  true  -- bucket_fixed_width
  FROM _timeudb_catalog.continuous_agg WHERE bucket_width != -1;

ALTER EXTENSION timeudb DROP FUNCTION _timeudb_functions.cagg_get_bucket_function(INTEGER);
DROP FUNCTION IF EXISTS _timeudb_functions.cagg_get_bucket_function(INTEGER);

-- (2) Rebuild catalog table
DROP VIEW IF EXISTS timeudb_experimental.policies;
DROP VIEW IF EXISTS timeudb_information.hypertables;
DROP VIEW IF EXISTS timeudb_information.continuous_aggregates;

DROP PROCEDURE IF EXISTS @extschema@.cagg_migrate (REGCLASS, BOOLEAN, BOOLEAN);
DROP FUNCTION IF EXISTS _timeudb_internal.cagg_migrate_pre_validation (TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS _timeudb_functions.cagg_migrate_pre_validation (TEXT, TEXT, TEXT);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_create_plan (_timeudb_catalog.continuous_agg, TEXT, BOOLEAN, BOOLEAN);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_create_plan (_timeudb_catalog.continuous_agg, TEXT, BOOLEAN, BOOLEAN);

DROP FUNCTION IF EXISTS _timeudb_functions.cagg_migrate_plan_exists (INTEGER);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_plan (_timeudb_catalog.continuous_agg);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_plan (_timeudb_catalog.continuous_agg);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_create_new_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_create_new_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_disable_policies (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_disable_policies (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_enable_policies (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_enable_policies (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_copy_policies (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_copy_policies (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_refresh_new_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_refresh_new_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_copy_data (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_copy_data (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_override_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_override_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_internal.cagg_migrate_execute_drop_old_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);
DROP PROCEDURE IF EXISTS _timeudb_functions.cagg_migrate_execute_drop_old_cagg (_timeudb_catalog.continuous_agg, _timeudb_catalog.continuous_agg_migrate_plan_step);

ALTER TABLE _timeudb_catalog.continuous_aggs_materialization_invalidation_log
    DROP CONSTRAINT continuous_aggs_materialization_invalid_materialization_id_fkey;

ALTER TABLE _timeudb_catalog.continuous_aggs_watermark
    DROP CONSTRAINT continuous_aggs_watermark_mat_hypertable_id_fkey;

ALTER EXTENSION timeudb
    DROP TABLE _timeudb_catalog.continuous_agg;

CREATE TABLE _timeudb_catalog._tmp_continuous_agg AS
    SELECT
        mat_hypertable_id,
        raw_hypertable_id,
        parent_mat_hypertable_id,
        user_view_schema,
        user_view_name,
        partial_view_schema,
        partial_view_name,
        direct_view_schema,
        direct_view_name,
        materialized_only,
        finalized
    FROM
        _timeudb_catalog.continuous_agg
    ORDER BY
        mat_hypertable_id;

DROP TABLE _timeudb_catalog.continuous_agg;

CREATE TABLE _timeudb_catalog.continuous_agg (
    mat_hypertable_id integer NOT NULL,
    raw_hypertable_id integer NOT NULL,
    parent_mat_hypertable_id integer,
    user_view_schema name NOT NULL,
    user_view_name name NOT NULL,
    partial_view_schema name NOT NULL,
    partial_view_name name NOT NULL,
    direct_view_schema name NOT NULL,
    direct_view_name name NOT NULL,
    materialized_only bool NOT NULL DEFAULT FALSE,
    finalized bool NOT NULL DEFAULT TRUE,
    -- table constraints
    CONSTRAINT continuous_agg_pkey PRIMARY KEY (mat_hypertable_id),
    CONSTRAINT continuous_agg_partial_view_schema_partial_view_name_key UNIQUE (partial_view_schema, partial_view_name),
    CONSTRAINT continuous_agg_user_view_schema_user_view_name_key UNIQUE (user_view_schema, user_view_name),
    CONSTRAINT continuous_agg_mat_hypertable_id_fkey
        FOREIGN KEY (mat_hypertable_id) REFERENCES _timeudb_catalog.hypertable (id) ON DELETE CASCADE,
    CONSTRAINT continuous_agg_raw_hypertable_id_fkey
        FOREIGN KEY (raw_hypertable_id) REFERENCES _timeudb_catalog.hypertable (id) ON DELETE CASCADE,
    CONSTRAINT continuous_agg_parent_mat_hypertable_id_fkey
        FOREIGN KEY (parent_mat_hypertable_id)
        REFERENCES _timeudb_catalog.continuous_agg (mat_hypertable_id) ON DELETE CASCADE
);

INSERT INTO _timeudb_catalog.continuous_agg
SELECT * FROM _timeudb_catalog._tmp_continuous_agg;
DROP TABLE _timeudb_catalog._tmp_continuous_agg;

CREATE INDEX continuous_agg_raw_hypertable_id_idx ON _timeudb_catalog.continuous_agg (raw_hypertable_id);

SELECT pg_catalog.pg_extension_config_dump('_timeudb_catalog.continuous_agg', '');

GRANT SELECT ON TABLE _timeudb_catalog.continuous_agg TO PUBLIC;

ALTER TABLE _timeudb_catalog.continuous_aggs_materialization_invalidation_log
    ADD CONSTRAINT continuous_aggs_materialization_invalid_materialization_id_fkey
        FOREIGN KEY (materialization_id)
        REFERENCES _timeudb_catalog.continuous_agg(mat_hypertable_id) ON DELETE CASCADE;

ALTER TABLE _timeudb_catalog.continuous_aggs_watermark
    ADD CONSTRAINT continuous_aggs_watermark_mat_hypertable_id_fkey
        FOREIGN KEY (mat_hypertable_id)
        REFERENCES _timeudb_catalog.continuous_agg (mat_hypertable_id) ON DELETE CASCADE;

ANALYZE _timeudb_catalog.continuous_agg;

--
-- END Rebuild the catalog table `_timeudb_catalog.continuous_agg`
--

--
-- START bgw_job_stat_history
--
DROP VIEW IF EXISTS timeudb_information.job_errors;

CREATE SEQUENCE _timeudb_internal.bgw_job_stat_history_id_seq MINVALUE 1;

CREATE TABLE _timeudb_internal.bgw_job_stat_history (
  id INTEGER NOT NULL DEFAULT nextval('_timeudb_internal.bgw_job_stat_history_id_seq'),
  job_id INTEGER NOT NULL,
  pid INTEGER,
  execution_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  execution_finish TIMESTAMPTZ,
  succeeded boolean NOT NULL DEFAULT FALSE,
  data jsonb,
  -- table constraints
  CONSTRAINT bgw_job_stat_history_pkey PRIMARY KEY (id)
);

ALTER SEQUENCE _timeudb_internal.bgw_job_stat_history_id_seq OWNED BY _timeudb_internal.bgw_job_stat_history.id;

CREATE INDEX bgw_job_stat_history_job_id_idx ON _timeudb_internal.bgw_job_stat_history (job_id);

REVOKE ALL ON _timeudb_internal.bgw_job_stat_history FROM PUBLIC;

INSERT INTO _timeudb_internal.bgw_job_stat_history (job_id, pid, execution_start, execution_finish, data)
SELECT
  job_errors.job_id,
  job_errors.pid,
  job_errors.start_time,
  job_errors.finish_time,
  jsonb_build_object('job', to_jsonb(bgw_job.*)) || jsonb_build_object('error_data', job_errors.error_data)
FROM
  _timeudb_internal.job_errors
  LEFT JOIN _timeudb_config.bgw_job ON bgw_job.id = job_errors.job_id
ORDER BY
  job_errors.job_id, job_errors.start_time;

ALTER EXTENSION timeudb
    DROP TABLE _timeudb_internal.job_errors;

DROP TABLE _timeudb_internal.job_errors;

UPDATE _timeudb_config.bgw_job SET scheduled = false WHERE id = 2;
INSERT INTO _timeudb_config.bgw_job (
    id,
    application_name,
    schedule_interval,
    max_runtime,
    max_retries,
    retry_period,
    proc_schema,
    proc_name,
    owner,
    scheduled,
    config,
    check_schema,
    check_name,
    fixed_schedule,
    initial_start
)
VALUES
(
    3,
    'Job History Log Retention Policy [3]',
    INTERVAL '1 month',
    INTERVAL '1 hour',
    -1,
    INTERVAL '1h',
    '_timeudb_functions',
    'policy_job_stat_history_retention',
    pg_catalog.quote_ident(current_role)::regrole,
    true,
    '{"drop_after":"1 month"}',
    '_timeudb_functions',
    'policy_job_stat_history_retention_check',
    true,
    '2000-01-01 00:00:00+00'::timestamptz
) ON CONFLICT (id) DO NOTHING;

DROP FUNCTION IF EXISTS _timeudb_internal.policy_job_error_retention(job_id integer,config jsonb);
DROP FUNCTION IF EXISTS _timeudb_internal.policy_job_error_retention_check(config jsonb);
DROP FUNCTION IF EXISTS _timeudb_functions.policy_job_error_retention(job_id integer,config jsonb);
DROP FUNCTION IF EXISTS _timeudb_functions.policy_job_error_retention_check(config jsonb);

--
-- END bgw_job_stat_history
--

-- Migrate existing CAggs using time_bucket_ng to time_bucket
CREATE PROCEDURE _timeudb_functions.cagg_migrate_to_time_bucket(cagg REGCLASS)
   AS '@MODULE_PATHNAME@', 'ts_continuous_agg_migrate_to_time_bucket' LANGUAGE C;

DO $$
DECLARE
  cagg_name regclass;
BEGIN
  FOR cagg_name IN
    SELECT pg_catalog.format('%I.%I', user_view_schema, user_view_name)::regclass
      FROM _timeudb_catalog.continuous_agg cagg
      JOIN _timeudb_catalog.continuous_aggs_bucket_function AS bf ON (cagg.mat_hypertable_id = bf.mat_hypertable_id)
      WHERE
         bf.bucket_func::text LIKE '%time_bucket_ng%'
  LOOP
    CALL _timeudb_functions.cagg_migrate_to_time_bucket(cagg_name);
  END LOOP;
END
$$;
