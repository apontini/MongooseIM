#!/usr/bin/env bash

set -e

DBS=$(./tools/test_runner/presets_to_dbs.sh "$PRESET")
echo "Wait for $DBS"

function wait_for_db {
    case $1 in
        mysql)
            ./tools/wait-for-it.sh -p 3306
        ;;

        pgsql)
            ./tools/wait-for-it.sh -p 5432
        ;;

        mssql)
            ./tools/wait-for-it.sh -p 1433
            ./tools/wait-for-it.sh -p 1434 # SCHEMA_READY_PORT
        ;;

        rmq)
            ./tools/wait-for-it.sh -p 5672
        ;;

        redis)
            ./tools/wait-for-it.sh -p 6379
        ;;

        riak)
            ./tools/wait-for-it.sh -p 8098
            ./tools/wait-for-it.sh -p 8087
            ./tools/wait-for-it.sh -p 8999 # SCHEMA_READY_PORT
        ;;

        ldap)
            ./tools/wait-for-it.sh -p 636 # On Circle CI
        ;;

        elasticsearch)
            ./tools/wait-for-it.sh -p 9200
        ;;

        cassandra)
            ./tools/wait-for-it.sh -p 9242 # SCHEMA_READY_PORT
            ./tools/wait-for-it.sh -p 9142 # proxy
        ;;

        minio)
            ./tools/wait-for-it.sh -p 9000
        ;;
    esac
}

for db in ${DBS}; do
    wait_for_db $db
done
