DROP VIEW _timeudb_internal.hypertable_chunk_local_size;
DROP FUNCTION _timeudb_internal.relation_size(relation REGCLASS);
DROP INDEX _timeudb_catalog.chunk_constraint_dimension_slice_id_idx;
CREATE INDEX chunk_constraint_chunk_id_dimension_slice_id_idx ON _timeudb_catalog.chunk_constraint (chunk_id, dimension_slice_id);
DROP FUNCTION _timeudb_internal.freeze_chunk(chunk REGCLASS);
DROP FUNCTION _timeudb_internal.drop_chunk(chunk REGCLASS);

DO
$$
DECLARE
    caggs_finalized TEXT;
    caggs_count INTEGER;
BEGIN
    SELECT
        string_agg(format('%I.%I', user_view_schema, user_view_name), ', '),
        count(*)
    INTO
        caggs_finalized,
        caggs_count
    FROM
        _timeudb_catalog.continuous_agg
    WHERE
        finalized IS TRUE;

    IF caggs_count > 0 THEN
        RAISE EXCEPTION 'Downgrade is not possible because there are % continuous aggregates using the finalized form: %', caggs_count, caggs_finalized
            USING HINT = 'Remove the corresponding continuous aggregates manually before downgrading';
    END IF;
END;
$$
LANGUAGE 'plpgsql';

--
-- Rebuild the catalog table `_timeudb_catalog.continuous_agg`
--
-- We need to recreate the catalog from scratch because when we drop a column
-- Postgres mark the `pg_attribute.attisdropped=TRUE` instead of removing it from
-- the `pg_catalog.pg_attribute` table.
--
-- If we downgrade and upgrade the extension without rebuild the catalog table it
-- will mess with `pg_attribute.attnum` and we will end up with issues when trying
-- to update data in those catalog tables.
--
DROP VIEW IF EXISTS timeudb_information.hypertables;
DROP VIEW IF EXISTS timeudb_information.continuous_aggregates;

ALTER EXTENSION timeudb
    DROP TABLE _timeudb_catalog.continuous_agg;

ALTER TABLE _timeudb_catalog.continuous_aggs_materialization_invalidation_log
    DROP CONSTRAINT continuous_aggs_materialization_invalid_materialization_id_fkey;

ALTER TABLE _timeudb_catalog.continuous_agg
    DROP COLUMN finalized;

CREATE TABLE _timeudb_catalog._tmp_continuous_agg (
    LIKE _timeudb_catalog.continuous_agg
    INCLUDING ALL
    -- indexes and constraintes will be created later to keep original names
    EXCLUDING INDEXES
    EXCLUDING CONSTRAINTS
);

INSERT INTO _timeudb_catalog._tmp_continuous_agg
    SELECT
        mat_hypertable_id,
        raw_hypertable_id,
        user_view_schema,
        user_view_name,
        partial_view_schema,
        partial_view_name,
        bucket_width,
        direct_view_schema,
        direct_view_name,
        materialized_only
    FROM
        _timeudb_catalog.continuous_agg
    ORDER BY
        mat_hypertable_id;

DROP TABLE _timeudb_catalog.continuous_agg;

ALTER TABLE _timeudb_catalog._tmp_continuous_agg
    RENAME TO continuous_agg;

ALTER TABLE _timeudb_catalog.continuous_agg
    ADD CONSTRAINT continuous_agg_pkey PRIMARY KEY (mat_hypertable_id),
    ADD CONSTRAINT continuous_agg_partial_view_schema_partial_view_name_key UNIQUE (partial_view_schema, partial_view_name),
    ADD CONSTRAINT continuous_agg_user_view_schema_user_view_name_key UNIQUE (user_view_schema, user_view_name),
    ADD CONSTRAINT continuous_agg_mat_hypertable_id_fkey FOREIGN KEY (mat_hypertable_id) REFERENCES _timeudb_catalog.hypertable(id) ON DELETE CASCADE,
    ADD CONSTRAINT continuous_agg_raw_hypertable_id_fkey FOREIGN KEY (raw_hypertable_id) REFERENCES _timeudb_catalog.hypertable(id) ON DELETE CASCADE;

CREATE INDEX continuous_agg_raw_hypertable_id_idx ON _timeudb_catalog.continuous_agg (raw_hypertable_id);

SELECT pg_catalog.pg_extension_config_dump('_timeudb_catalog.continuous_agg', '');

GRANT SELECT ON TABLE _timeudb_catalog.continuous_agg TO PUBLIC;

ALTER TABLE _timeudb_catalog.continuous_aggs_materialization_invalidation_log
    ADD CONSTRAINT continuous_aggs_materialization_invalid_materialization_id_fkey
        FOREIGN KEY (materialization_id)
        REFERENCES _timeudb_catalog.continuous_agg(mat_hypertable_id) ON DELETE CASCADE;

ANALYZE _timeudb_catalog.continuous_agg;

DROP PROCEDURE timeudb_experimental.move_chunk(REGCLASS, NAME, NAME, NAME);
DROP PROCEDURE timeudb_experimental.copy_chunk(REGCLASS, NAME, NAME, NAME);

DROP FUNCTION IF EXISTS timeudb_experimental.subscription_exec(TEXT);

DROP FUNCTION _timeudb_internal.create_compressed_chunk(REGCLASS, REGCLASS,
	BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT);

--
-- Rebuild the catalog table `_timeudb_catalog.chunk_copy_operation`
--
-- We need to recreate the catalog from scratch because when we drop a column
-- Postgres mark the `pg_attribute.attisdropped=TRUE` instead of removing it from
-- the `pg_catalog.pg_attribute` table.
--
-- If we downgrade and upgrade the extension without rebuild the catalog table it
-- will mess with `pg_attribute.attnum` and we will end up with issues when trying
-- to update data in those catalog tables.

ALTER TABLE _timeudb_catalog.chunk_copy_operation
	DROP COLUMN compress_chunk_name;

CREATE TABLE _timeudb_catalog._tmp_chunk_copy_operation (
    LIKE _timeudb_catalog.chunk_copy_operation
    INCLUDING ALL
    EXCLUDING INDEXES
    EXCLUDING CONSTRAINTS
);

INSERT INTO _timeudb_catalog._tmp_chunk_copy_operation
    SELECT
        operation_id,
        backend_pid,
        completed_stage,
        time_start,
        chunk_id,
        source_node_name,
        dest_node_name,
        delete_on_source_node
    FROM
        _timeudb_catalog.chunk_copy_operation
    ORDER BY
        operation_id;

ALTER EXTENSION timeudb
    DROP TABLE _timeudb_catalog.chunk_copy_operation;

DROP TABLE _timeudb_catalog.chunk_copy_operation;

CREATE TABLE _timeudb_catalog.chunk_copy_operation (
    LIKE _timeudb_catalog._tmp_chunk_copy_operation
    INCLUDING ALL
    EXCLUDING INDEXES
    EXCLUDING CONSTRAINTS
);

-- Create a new table to void doing rename operation on the tmp table
--
INSERT INTO _timeudb_catalog.chunk_copy_operation
    SELECT
        operation_id,
        backend_pid,
        completed_stage,
        time_start,
        chunk_id,
        source_node_name,
        dest_node_name,
        delete_on_source_node
    FROM
        _timeudb_catalog._tmp_chunk_copy_operation
    ORDER BY
        operation_id;

DROP TABLE _timeudb_catalog._tmp_chunk_copy_operation;

ALTER TABLE _timeudb_catalog.chunk_copy_operation
    ADD CONSTRAINT chunk_copy_operation_pkey PRIMARY KEY (operation_id),
    ADD CONSTRAINT chunk_copy_operation_chunk_id_fkey FOREIGN KEY (chunk_id) REFERENCES _timeudb_catalog.chunk(id) ON DELETE CASCADE;

GRANT SELECT ON TABLE _timeudb_catalog.chunk_copy_operation TO PUBLIC;

ANALYZE _timeudb_catalog.chunk_copy_operation;
