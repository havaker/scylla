# Scylla CQL extensions

Scylla extends the CQL language to provide a few extra features. This document
lists those extensions.

## BYPASS CACHE clause

The `BYPASS CACHE` clause on `SELECT` statements informs the database that the data
being read is unlikely to be read again in the near future, and also
was unlikely to have been read in the near past; therefore no attempt
should be made to read it from the cache or to populate the cache with
the data. This is mostly useful for range scans; these typically
process large amounts of data with no temporal locality and do not
benefit from the cache.

The clause is placed immediately after the optional `ALLOW FILTERING`
clause:

    SELECT ... FROM ...
    WHERE ...
    ALLOW FILTERING          -- optional
    BYPASS CACHE

## "Paxos grace seconds" per-table option

The `paxos_grace_seconds` option is used to set the amount of seconds which
are used to TTL data in paxos tables when using LWT queries against the base
table.

This value is intentionally decoupled from `gc_grace_seconds` since,
in general, the base table could use completely different strategy to garbage
collect entries, e.g. can set `gc_grace_seconds` to 0 if it doesn't use
deletions and hence doesn't need to repair.

However, paxos tables still rely on repair to achieve consistency, and
the user is required to execute repair within `paxos_grace_seconds`.

Default value is equal to `DEFAULT_GC_GRACE_SECONDS`, which is 10 days.

The option can be specified at `CREATE TABLE` or `ALTER TABLE` queries in the same
way as other options by using `WITH` clause:

    CREATE TABLE tbl ...
    WITH paxos_grace_seconds=1234

## USING TIMEOUT

TIMEOUT extension allows specifying per-query timeouts. This parameter accepts a single
duration and applies it as a timeout specific to a single particular query.
The parameter is supported for prepared statements as well.
The parameter acts as part of the USING clause, and thus can be combined with other
parameters - like timestamps and time-to-live.
In order for this parameter to be effective for read operations as well, it's possible
to attach USING clause to SELECT statements.

Examples:
```cql
	SELECT * FROM t USING TIMEOUT 200ms;
```
```cql
	INSERT INTO t(a,b,c) VALUES (1,2,3) USING TIMESTAMP 42 AND TIMEOUT 50ms;
```

Working with prepared statements works as usual - the timeout parameter can be
explicitly defined or provided as a marker:

```cql
	SELECT * FROM t USING TIMEOUT ?;
```
```cql
	INSERT INTO t(a,b,c) VALUES (?,?,?) USING TIMESTAMP 42 AND TIMEOUT 50ms;
```

## Keyspace storage options

Storage options allows specifying the storage format assigned to a keyspace.
The default storage format is `LOCAL`, which simply means storing all the sstables
in a local directory.
Experimental support for `S3` storage format is also added. This option is not fully
implemented yet, but it will allow storing sstables in a shared, S3-compatible object store.

Storage options can be specified via `CREATE KEYSPACE` or `ALTER KEYSPACE` statement
and it's formatted as a map of options - similarly to how replication strategy is handled.

Examples:
```cql
CREATE KEYSPACE ks
    WITH REPLICATION = { 'class' : 'SimpleStrategy', 'replication_factor' : 3 }
    AND STORAGE = { 'type' : 'S3', 'bucket' : '/tmp/b1', 'endpoint' : 'localhost' } ;
```

```cql
ALTER KEYSPACE ks WITH REPLICATION = { 'class' : 'SimpleStrategy', 'replication_factor' : 3 }
    AND STORAGE = { 'type' : 'S3', 'bucket': '/tmp/b2', 'endpoint' : 'localhost' } ;
```

Storage options can be inspected by checking the new system schema table: `system_schema.scylla_keyspaces`:

```cql
    cassandra@cqlsh> select * from system_schema.scylla_keyspaces;
    
     keyspace_name | storage_options                                | storage_type
    ---------------+------------------------------------------------+--------------
               ksx | {'bucket': '/tmp/xx', 'endpoint': 'localhost'} |           S3
```

## PRUNE MATERIALIZED VIEW statements

A special statement is dedicated for pruning ghost rows from materialized views.
Ghost row is an inconsistency issue which manifests itself by having rows
in a materialized view which do not correspond to any base table rows.
Such inconsistencies should be prevented altogether and Scylla is striving to avoid
them, but *if* they happen, this statement can be used to restore a materialized view
to a fully consistent state without rebuilding it from scratch.

Example usages:
```cql
  PRUNE MATERIALIZED VIEW my_view;
  PRUNE MATERIALIZED VIEW my_view WHERE token(v) > 7 AND token(v) < 1535250;
  PRUNE MATERIALIZED VIEW my_view WHERE v = 19;
```

The statement works by fetching requested rows from a materialized view
and then trying to fetch their corresponding rows from the base table.
If it turns out that the base row does not exist, the row is considered
a ghost row and is thus deleted. The statement implicitly works with
consistency level ALL when fetching from the base table to avoid false
positives. As the example shows, a materialized view can be pruned
in one go, but one can also specify specific primary keys or token ranges,
which is recommended in order to make the operation less heavyweight
and allow for running multiple parallel pruning statements for non-overlapping
token ranges.

## Expressions

### Lists elements for filtering

Subscripting a list in a WHERE clause is supported as are maps.

```cql
WHERE some_list[:index] = :value
```
