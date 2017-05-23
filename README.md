`citus_create_index_concurrently.sh` performs a function equivalent to
CREATE INDEX CONCURRENTLY or DROP INDEX CONCURRENTLY in Postgres/Citus
databases.

Examples:

    $ ./citus_create_index_concurrently.sh --pg postgres://localhost:9750/crm_dev --table foo --index index_bar --columns column_a
    $ ./citus_create_index_concurrently.sh --pg `heroku config:get DATABASE_URL --app ali-staging` --table gmail_msgid_mappings --index unique_on_user_msgid_hashid --columns company_id,company_user_id,gmail_msgid,correspondence_hash_id --unique --if-not-exists --num-jobs 4

WARNING: This will not work via pgbouncer!  Pgbouncer will reject
`PGOPTIONS="-c citus.enable_ddl_propagation=off"` with the error message:

    psql: ERROR: Unsupported startup parameter: options

Your `--pg` parameter must route directly to the PG process on the Citus
coordinator node.

This script is adapted by jhw@prosperworks.com from an original
pattern from
[samay-sharma](https://gist.github.com/samay-sharma/06852d9e7f7b08fe077a2c4e45eb3185),
with further advice and input from lukas@cituscloud.com.
