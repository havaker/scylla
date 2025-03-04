# Copyright 2021-present ScyllaDB
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Tests for materialized views

import time
import pytest

from util import new_test_table, unique_name, new_materialized_view
from cassandra.protocol import InvalidRequest

import nodetool

# Test that building a view with a large value succeeds. Regression test
# for a bug where values larger than 10MB were rejected during building (#9047)
def test_build_view_with_large_row(cql, test_keyspace):
    schema = 'p int, c int, v text, primary key (p,c)'
    mv = unique_name()
    with new_test_table(cql, test_keyspace, schema) as table:
        big = 'x'*11*1024*1024
        cql.execute(f"INSERT INTO {table}(p,c,v) VALUES (1,1,'{big}')")
        cql.execute(f"CREATE MATERIALIZED VIEW {test_keyspace}.{mv} AS SELECT * FROM {table} WHERE p IS NOT NULL AND c IS NOT NULL PRIMARY KEY (c,p)")
        try:
            retrieved_row = False
            for _ in range(50):
                res = [row for row in cql.execute(f"SELECT * FROM {test_keyspace}.{mv}")]
                if len(res) == 1 and res[0].v == big:
                    retrieved_row = True
                    break
                else:
                    time.sleep(0.1)
            assert retrieved_row
        finally:
            cql.execute(f"DROP MATERIALIZED VIEW {test_keyspace}.{mv}")

# Test that updating a view with a large value succeeds. Regression test
# for a bug where values larger than 10MB were rejected during building (#9047)
def test_update_view_with_large_row(cql, test_keyspace):
    schema = 'p int, c int, v text, primary key (p,c)'
    mv = unique_name()
    with new_test_table(cql, test_keyspace, schema) as table:
        cql.execute(f"CREATE MATERIALIZED VIEW {test_keyspace}.{mv} AS SELECT * FROM {table} WHERE p IS NOT NULL AND c IS NOT NULL PRIMARY KEY (c,p)")
        try:
            big = 'x'*11*1024*1024
            cql.execute(f"INSERT INTO {table}(p,c,v) VALUES (1,1,'{big}')")
            res = [row for row in cql.execute(f"SELECT * FROM {test_keyspace}.{mv}")]
            assert len(res) == 1 and res[0].v == big
        finally:
            cql.execute(f"DROP MATERIALIZED VIEW {test_keyspace}.{mv}")

# Test that a `CREATE MATERIALIZED VIEW` request, that contains bind markers in
# its SELECT statement, fails gracefully with `InvalidRequest` exception and
# doesn't lead to a database crash.
def test_mv_select_stmt_bound_values(cql, test_keyspace):
    schema = 'p int PRIMARY KEY'
    mv = unique_name()
    with new_test_table(cql, test_keyspace, schema) as table:
        try:
            with pytest.raises(InvalidRequest, match="CREATE MATERIALIZED VIEW"):
                cql.execute(f"CREATE MATERIALIZED VIEW {test_keyspace}.{mv} AS SELECT * FROM {table} WHERE p = ? PRIMARY KEY (p)")
        finally:
            cql.execute(f"DROP MATERIALIZED VIEW IF EXISTS {test_keyspace}.{mv}")

# In test_null.py::test_empty_string_key() we noticed that an empty string
# is not allowed as a partition key. However, an empty string is a valid
# value for a string column, so if we have a materialized view with this
# string column becoming the view's partition key - the empty string may end
# up being the view row's partition key. This case should be supported,
# because the "IS NOT NULL" clause in the view's declaration does not
# eliminate this row (an empty string is *not* considered NULL).
# Reproduces issue #9375.
def test_mv_empty_string_partition_key(cql, test_keyspace):
    schema = 'p int, v text, primary key (p)'
    with new_test_table(cql, test_keyspace, schema) as table:
        with new_materialized_view(cql, table, '*', 'v, p', 'v is not null and p is not null') as mv:
            cql.execute(f"INSERT INTO {table} (p,v) VALUES (123, '')")
            # Note that because cql-pytest runs on a single node, view
            # updates are synchronous, and we can read the view immediately
            # without retrying. In a general setup, this test would require
            # retries.
            # The view row with the empty partition key should exist.
            # In #9375, this failed in Scylla:
            assert list(cql.execute(f"SELECT * FROM {mv}")) == [('', 123)]
            # Verify that we can flush an sstable with just an one partition
            # with an empty-string key (in the past we had a summary-file
            # sanity check preventing this from working).
            nodetool.flush(cql, mv)

# Reproducer for issue #9450 - when a view's key column name is a (quoted)
# keyword, writes used to fail because they generated internally broken CQL
# with the column name not quoted.
def test_mv_quoted_column_names(cql, test_keyspace):
    for colname in ['"dog"', '"Dog"', 'DOG', '"to"', 'int']:
        with new_test_table(cql, test_keyspace, f'p int primary key, {colname} int') as table:
            with new_materialized_view(cql, table, '*', f'{colname}, p', f'{colname} is not null and p is not null') as mv:
                cql.execute(f'INSERT INTO {table} (p, {colname}) values (1, 2)')
                # Validate that not only the write didn't fail, it actually
                # write the right thing to the view. NOTE: on a single-node
                # Scylla, view update is synchronous so we can just read and
                # don't need to wait or retry.
                assert list(cql.execute(f'SELECT * from {mv}')) == [(2, 1)]

# Same as test_mv_quoted_column_names above (reproducing issue #9450), just
# check *view building* - i.e., pre-existing data in the base table that
# needs to be copied to the view. The view building cannot return an error
# to the user, but can fail to write the desired data into the view.
def test_mv_quoted_column_names_build(cql, test_keyspace):
    for colname in ['"dog"', '"Dog"', 'DOG', '"to"', 'int']:
        with new_test_table(cql, test_keyspace, f'p int primary key, {colname} int') as table:
            cql.execute(f'INSERT INTO {table} (p, {colname}) values (1, 2)')
            with new_materialized_view(cql, table, '*', f'{colname}, p', f'{colname} is not null and p is not null') as mv:
                # When Scylla's view builder fails as it did in issue #9450,
                # there is no way to tell this state apart from a view build
                # that simply hasn't completed (besides looking at the logs,
                # which we don't). This means, unfortunately, that a failure
                # of this test is slow - it needs to wait for a timeout.
                start_time = time.time()
                while time.time() < start_time + 30:
                    if list(cql.execute(f'SELECT * from {mv}')) == [(2, 1)]:
                        break
                assert list(cql.execute(f'SELECT * from {mv}')) == [(2, 1)]

# The previous test (test_mv_empty_string_partition_key) verifies that a
# row with an empty-string partition key can appear in the view. This was
# checked with a full-table scan. This test is about reading this one
# view partition individually, with WHERE v=''.
# Surprisingly, Cassandra does NOT allow to SELECT this specific row
# individually - "WHERE v=''" is not allowed when v is the partition key
# (even of a view). We consider this to be a Cassandra bug - it doesn't
# make sense to allow the user to add a row and to see it in a full-table
# scan, but not to query it individually. This is why we mark this test as
# a Cassandra bug and want Scylla to pass it.
# Reproduces issue #9375 and #9352.
def test_mv_empty_string_partition_key_individual(cassandra_bug, cql, test_keyspace):
    schema = 'p int, v text, primary key (p)'
    with new_test_table(cql, test_keyspace, schema) as table:
        with new_materialized_view(cql, table, '*', 'v, p', 'v is not null and p is not null') as mv:
            # Insert a bunch of (p,v) rows. One of the v's is the empty
            # string, which we would like to test, but let's insert more
            # rows to make it more likely to exercise various possibilities
            # of token ordering (see #9352).
            rows = [[123, ''], [1, 'dog'], [2, 'cat'], [700, 'hello'], [3, 'horse']]
            for row in rows:
                cql.execute(f"INSERT INTO {table} (p,v) VALUES ({row[0]}, '{row[1]}')")
            # Note that because cql-pytest runs on a single node, view
            # updates are synchronous, and we can read the view immediately
            # without retrying. In a general setup, this test would require
            # retries.
            # Check that we can read the individual partition with the
            # empty-string key:
            assert list(cql.execute(f"SELECT * FROM {mv} WHERE v=''")) == [('', 123)]
            # The SELECT above works from cache. However, empty partition
            # keys also used to be special-cased and be buggy when reading
            # and writing sstables, so let's verify that the empty partition
            # key can actually be written and read from disk, by forcing a
            # memtable flush and bypassing the cache on read.
            # In the past Scylla used to fail this flush because the sstable
            # layer refused to write empty partition keys to the sstable:
            nodetool.flush(cql, mv)
            # First try a full-table scan, and then try to read the
            # individual partition with the empty key:
            assert set(cql.execute(f"SELECT * FROM {mv} BYPASS CACHE")) == {
                (x[1], x[0]) for x in rows}
            # Issue #9352 used to prevent us finding WHERE v='' here, even
            # when the data is known to exist (the above full-table scan
            # saw it!) and despite the fact that WHERE v='' is parsed
            # correctly because we tested above it works from memtables.
            assert list(cql.execute(f"SELECT * FROM {mv} WHERE v='' BYPASS CACHE")) == [('', 123)]

# Test that the "IS NOT NULL" clause in the materialized view's SELECT
# functions as expected - namely, rows which have their would-be view
# key column unset (aka null) do not get copied into the view.
def test_mv_is_not_null(cql, test_keyspace):
    schema = 'p int, v text, primary key (p)'
    with new_test_table(cql, test_keyspace, schema) as table:
        with new_materialized_view(cql, table, '*', 'v, p', 'v is not null and p is not null') as mv:
            cql.execute(f"INSERT INTO {table} (p,v) VALUES (123, 'dog')")
            cql.execute(f"INSERT INTO {table} (p,v) VALUES (17, null)")
            # Note that because cql-pytest runs on a single node, view
            # updates are synchronous, and we can read the view immediately
            # without retrying. In a general setup, this test would require
            # retries.
            # The row with 123 should appear in the view, but the row with
            # 17 should not, because v *is* null.
            assert list(cql.execute(f"SELECT * FROM {mv}")) == [('dog', 123)]
            # The view row should disappear and reappear if its key is
            # changed to null and back in the base table:
            cql.execute(f"UPDATE {table} SET v=null WHERE p=123")
            assert list(cql.execute(f"SELECT * FROM {mv}")) == []
            cql.execute(f"UPDATE {table} SET v='cat' WHERE p=123")
            assert list(cql.execute(f"SELECT * FROM {mv}")) == [('cat', 123)]
            cql.execute(f"DELETE v FROM {table} WHERE p=123")
            assert list(cql.execute(f"SELECT * FROM {mv}")) == []

# Refs #10851. The code used to create a wildcard selection for all columns,
# which erroneously also includes static columns if such are present in the
# base table. Currently views only operate on regular columns and the filtering
# code assumes that. TODO: once we implement static column support for materialized
# views, this test case will be a nice regression test to ensure that everything still
# works if the static columns are *not* used in the view.
def test_filter_with_unused_static_column(cql, test_keyspace):
    schema = 'p int, c int, v int, s int static, primary key (p,c)'
    with new_test_table(cql, test_keyspace, schema) as table:
        with new_materialized_view(cql, table, select='p,c,v', pk='p,c,v', where='p IS NOT NULL and c IS NOT NULL and v = 44') as mv:
            cql.execute(f"INSERT INTO {table} (p,c,v) VALUES (42,43,44)")
            cql.execute(f"INSERT INTO {table} (p,c,v) VALUES (1,2,3)")
            assert list(cql.execute(f"SELECT * FROM {mv}")) == [(42, 43, 44)]
