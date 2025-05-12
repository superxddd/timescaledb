-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

--
-- The general compressed_data type;
--
CREATE TYPE _timeudb_internal.compressed_data (
  INTERNALLENGTH = VARIABLE,
  STORAGE = EXTERNAL,
  ALIGNMENT = double, --needed for alignment in ARRAY type compression
  INPUT = _timeudb_functions.compressed_data_in,
  OUTPUT = _timeudb_functions.compressed_data_out,
  RECEIVE = _timeudb_functions.compressed_data_recv,
  SEND = _timeudb_functions.compressed_data_send
);

-- Dimension type used in create_hypertable, add_dimension, etc. It is
-- deliberately an opaque type.
CREATE TYPE _timeudb_internal.dimension_info (
    INPUT = _timeudb_functions.dimension_info_in,
    OUTPUT = _timeudb_functions.dimension_info_out,
    INTERNALLENGTH = VARIABLE
);

