#!/bin/bash
#
# This script is adapted from:
#
#   https://gist.github.com/samay-sharma/06852d9e7f7b08fe077a2c4e45eb3185
#
# ...as referred to me by lukas@cituscloud.com, and also some
# discussion and suggested edits from Lukas.
#
# I have expanded this to take CLI argument.
#
# This script exploits knowledge of Citus internals to effect
# an online index build.
#
# It interrogates the coordinator to find all the shard ids, data node
# hostnames, and data node ports.  Then with up to PARALLEL_FACTOR
# concurrency it generates indices CONCURRENTLY on each shard on each
# data node.  Once all of those exist, the index on the master table
# in the coordinator which ties all the pieces together is created,
# also CONCURRENTLY.
#
# This seems like magic - and it is magic.  This works because it is
# informed by Citus internals - this happens to generate the same data
# structures by which a Citus distributed index is composed, but by
# different means than the Citus extension uses to serve CREATE INDEX.
#
# Examples:
#
#   $ ./citus_create_index_concurrently.sh --pg postgres://localhost:9750/crm_dev --table foo --index index_bar --columns column_a
#
#   $ ./citus_create_index_concurrently.sh --pg `cat CITUS_COORDINATOR_PG_URL` --table gmail_msgid_mappings --index unique_on_user_msgid_hashid --columns company_id,company_user_id,gmail_msgid,correspondence_hash_id --unique --if-not-exists --num-jobs 4
#
# WARNING: THIS WILL NOT WORK VIA PGBOUNCER!!!
#
# PGOPTIONS="-c citus.enable_ddl_propagation=off" will be rejected by
# pgbouncer with error message:
#
#   psql: ERROR: Unsupported startup parameter: options
#
# Your --pg parameter must route directly to the PG process on the
# Citus coordinator node.
#
# author:  https://gist.github.com/samay-sharma
# advisor: lukas@cituscloud.com
# adoptor: jhw@prosperworks.com
# incept:  2017-03-08
# version: 0.0.1 pre-alpha
# license: MIT
#
# Copyright (c) 2017 ProsperWorks, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

function fail()
{
    echo "$*"
    exit 1
}

# Parse args:
#
NUM_JOBS="1"
WHERE_CLAUSE=""
while [[ $# -gt 0 ]]
do
    param="$1"
    shift # past param
    case $param in
        --pg)
            PG="$1"
            shift # past argument
            ;;
        --table)
            TABLE="$1"
            shift # past argument
            ;;
        --index)
            INDEX="$1"
            shift # past argument
            ;;
        --columns)
            COLUMNS="$1"
            shift # past argument
            ;;
        --unique)
            UNIQUE="UNIQUE"
            ;;
        --where)
            if [ "" == "$WHERE_CLAUSE" ]
            then
                WHERE_CLAUSE="WHERE ($1)"
                shift # past argument
            else
                echo "only one --where supported"
                exit 1
            fi
            ;;
        --if-not-exists)
            IF_NOT_EXISTS="IF NOT EXISTS"
            ;;
        -j|--num-jobs)
            NUM_JOBS="$1"
            shift # past argument
            ;;
        --drop)
            DROP="DROP"
            ;;
        *)
            echo "unknown option $param"
            exit 1
            ;;
    esac
done

if [ "" == "$PG" ]
then
    fail "--pg not specified"
fi
echo "PG:            $PG" | sed 's/:[^@ \/]*@/:ELIDED@/g'
PG_HOST=`echo $PG | ruby -r uri -e 'puts URI(STDIN.read).host'`
PG_PORT=`echo $PG | ruby -r uri -e 'puts URI(STDIN.read).port || "5432"'`
PG_SCHEME=`echo $PG | ruby -r uri -e 'puts URI(STDIN.read).scheme || "postgres"'`
PG_USER=`echo $PG | ruby -r uri -e 'puts URI(STDIN.read).user'`
PG_PASSWORD=`echo $PG | ruby -r uri -e 'puts URI(STDIN.read).password'`
PG_PATH=`echo $PG | ruby -r uri -e 'puts URI(STDIN.read).path'`
echo "PG_HOST:       $PG_HOST"
echo "PG_PORT:       $PG_PORT"
echo "PG_SCHEME:     $PG_SCHEME"
echo "PG_USER:       $PG_USER"
echo "PG_PASSWORD:   ELIDED"
echo "PG_PATH:       $PG_PATH"
PRE_HOST="postgres://"
if [ "" != "$PG_USER" ]
then
    PRE_HOST="${PRE_HOST}${PG_USER}"
    if [ "" != "$PG_PASSWORD" ]
    then
        PRE_HOST="${PRE_HOST}:${PG_PASSWORD}"
    fi
    PRE_HOST="${PRE_HOST}@"
fi

if [ "" == "$TABLE" ]
then
    fail "--table not specified"
fi
echo "TABLE:         $TABLE"

if [ "" == "$INDEX" ]
then
    fail "--index not specified"
fi
echo "INDEX:         $INDEX"
echo "DROP:          $DROP"
echo "NUM_JOBS:      $NUM_JOBS"

echo "WHERE_CLAUSE:  $WHERE_CLAUSE"

function for_each_shard()
{
    psql $PG -tA -F" " -c "SELECT s.shardid,nodename,nodeport FROM pg_dist_shard s JOIN pg_dist_shard_placement p ON (s.shardid = p.shardid) WHERE logicalrelid::regclass = '${TABLE}'::regclass" | xargs -n 3 -P "${NUM_JOBS}" sh -c "$*"
}

if [ "" != "$DROP" ]
then
    set -e
    env PGSSLMODE=require PGOPTIONS="-c citus.enable_ddl_propagation=off" psql $PG -c "DROP INDEX CONCURRENTLY IF EXISTS $INDEX"
    for_each_shard "psql ${PRE_HOST}\$1:\$2${PG_PATH} -c \"DROP INDEX CONCURRENTLY IF EXISTS ${INDEX}_\$0\""
    psql $PG -c "\d $TABLE"
else
    echo "COLUMNS:       $COLUMNS"
    echo "UNIQUE:        $UNIQUE"
    echo "IF_NOT_EXISTS: $IF_NOT_EXISTS"
    set -e
    for_each_shard "psql ${PRE_HOST}\$1:\$2${PG_PATH} -c \"CREATE ${UNIQUE} INDEX CONCURRENTLY ${IF_NOT_EXISTS} ${INDEX}_\$0 ON ${TABLE}_\$0 (${COLUMNS}) ${WHERE_CLAUSE}\""
    env PGSSLMODE=require PGOPTIONS="-c citus.enable_ddl_propagation=off" psql $PG -c "CREATE $UNIQUE INDEX CONCURRENTLY $IF_NOT_EXISTS $INDEX ON $TABLE (${COLUMNS}) ${WHERE_CLAUSE}"
    psql $PG -c "\d $TABLE" -c "\di $INDEX"
fi
