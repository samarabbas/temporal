#!/bin/bash

set -eux -o pipefail

# === Auto setup defaults ===

DB="${DB:-cassandra}"
SKIP_SCHEMA_SETUP="${SKIP_SCHEMA_SETUP:-false}"

# Cassandra
KEYSPACE="${KEYSPACE:-temporal}"
VISIBILITY_KEYSPACE="${VISIBILITY_KEYSPACE:-temporal_visibility}"

CASSANDRA_SEEDS="${CASSANDRA_SEEDS:-}"
CASSANDRA_PORT="${CASSANDRA_PORT:-9042}"
CASSANDRA_USER="${CASSANDRA_USER:-}"
CASSANDRA_PASSWORD="${CASSANDRA_PASSWORD:-}"
CASSANDRA_TLS_ENABLED="${CASSANDRA_TLS_ENABLED:-}"
CASSANDRA_CERT="${CASSANDRA_CERT:-}"
CASSANDRA_CERT_KEY="${CASSANDRA_CERT_KEY:-}"
CASSANDRA_CA="${CASSANDRA_CA:-}"
CASSANDRA_REPLICATION_FACTOR="${CASSANDRA_REPLICATION_FACTOR:-1}"

# MySQL/PostgreSQL
DBNAME="${DBNAME:-temporal}"
VISIBILITY_DBNAME="${VISIBILITY_DBNAME:-temporal_visibility}"
DB_PORT="${DB_PORT:-3306}"

MYSQL_SEEDS="${MYSQL_SEEDS:-}"
MYSQL_USER="${MYSQL_USER:-}"
MYSQL_PWD="${MYSQL_PWD:-}"
MYSQL_TX_ISOLATION_COMPAT="${MYSQL_TX_ISOLATION_COMPAT:-false}"

POSTGRES_SEEDS="${POSTGRES_SEEDS:-}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PWD="${POSTGRES_PWD:-}"

# Elasticsearch
ENABLE_ES="${ENABLE_ES:-false}"
ES_SCHEME="${ES_SCHEME:-http}"
ES_SEEDS="${ES_SEEDS:-}"
ES_PORT="${ES_PORT:-9200}"
ES_USER="${ES_USER:-}"
ES_PWD="${ES_PWD:-}"
ES_VERSION="${ES_VERSION:-v6}"
ES_VIS_INDEX="${ES_VIS_INDEX:-temporal-visibility-dev}"
ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS="${ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS:-0}"

# Default namespace
TEMPORAL_CLI_ADDRESS="${TEMPORAL_CLI_ADDRESS:-}"
SKIP_DEFAULT_NAMESPACE_CREATION="${SKIP_DEFAULT_NAMESPACE_CREATION:-false}"
DEFAULT_NAMESPACE="${DEFAULT_NAMESPACE:-default}"
DEFAULT_NAMESPACE_RETENTION=${DEFAULT_NAMESPACE_RETENTION:-1}

# === Main database functions ===

validate_db_env() {
    if [ "${DB}" == "mysql" ]; then
        if [ -z "${MYSQL_SEEDS}" ]; then
            echo "MYSQL_SEEDS env must be set if DB is ${DB}."
            exit 1
        fi
    elif [ "${DB}" == "postgresql" ]; then
        if [ -z "${POSTGRES_SEEDS}" ]; then
            echo "POSTGRES_SEEDS env must be set if DB is ${DB}."
            exit 1
        fi
    elif [ "${DB}" == "cassandra" ]; then
        if [ -z "${CASSANDRA_SEEDS}" ]; then
            echo "CASSANDRA_SEEDS env must be set if DB is ${DB}."
            exit 1
        fi
    else
        echo "Unsupported DB type: ${DB}."
        exit 1
    fi
}

wait_for_cassandra() {
    # TODO (alex): Remove exports
    export CASSANDRA_USER=${CASSANDRA_USER}
    export CASSANDRA_PORT=${CASSANDRA_PORT}
    export CASSANDRA_ENABLE_TLS=${CASSANDRA_TLS_ENABLED}
    export CASSANDRA_TLS_CERT=${CASSANDRA_CERT}
    export CASSANDRA_TLS_KEY=${CASSANDRA_CERT_KEY}
    export CASSANDRA_TLS_CA=${CASSANDRA_CA}

    { export CASSANDRA_PASSWORD=${CASSANDRA_PASSWORD}; } 2> /dev/null

    until temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" validate-health; do
        echo 'Waiting for Cassandra to start up.'
        sleep 1
    done
    echo 'Cassandra started.'
}

wait_for_mysql() {
    SERVER=$(echo "${MYSQL_SEEDS}" | awk -F ',' '{print $1}')
    until nc -z "${SERVER}" "${DB_PORT}"; do
        echo 'Waiting for MySQL to start up.'
      sleep 1
    done

    echo 'MySQL started.'
}

wait_for_postgres() {
    SERVER=$(echo "${POSTGRES_SEEDS}" | awk -F ',' '{print $1}')
    until nc -z "${SERVER}" "${DB_PORT}"; do
      echo 'Waiting for PostgreSQL to startup.'
      sleep 1
    done

    echo 'PostgreSQL started.'
}

wait_for_db() {
    if [ "${DB}" == "mysql" ]; then
        wait_for_mysql
    elif [ "${DB}" == "postgresql" ]; then
        wait_for_postgres
    elif [ "${DB}" == "cassandra" ]; then
        wait_for_cassandra
    else
        echo "Unsupported DB type: ${DB}."
        exit 1
    fi
}

setup_cassandra_schema() {
    # TODO (alex): Remove exports
    export CASSANDRA_USER=${CASSANDRA_USER}
    export CASSANDRA_PORT=${CASSANDRA_PORT}
    export CASSANDRA_ENABLE_TLS=${CASSANDRA_TLS_ENABLED}
    export CASSANDRA_TLS_CERT=${CASSANDRA_CERT}
    export CASSANDRA_TLS_KEY=${CASSANDRA_CERT_KEY}
    export CASSANDRA_TLS_CA=${CASSANDRA_CA}

    { export CASSANDRA_PASSWORD=${CASSANDRA_PASSWORD}; } 2> /dev/null

    SCHEMA_DIR=${TEMPORAL_HOME}/schema/cassandra/temporal/versioned
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" create -k "${KEYSPACE}" --rf "${CASSANDRA_REPLICATION_FACTOR}"
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${KEYSPACE}" setup-schema -v 0.0
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${KEYSPACE}" update-schema -d "${SCHEMA_DIR}"

    VISIBILITY_SCHEMA_DIR=${TEMPORAL_HOME}/schema/cassandra/visibility/versioned
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" create -k "${VISIBILITY_KEYSPACE}" --rf "${CASSANDRA_REPLICATION_FACTOR}"
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${VISIBILITY_KEYSPACE}" setup-schema -v 0.0
    temporal-cassandra-tool --ep "${CASSANDRA_SEEDS}" -k "${VISIBILITY_KEYSPACE}" update-schema -d "${VISIBILITY_SCHEMA_DIR}"
}

setup_mysql_schema() {
    # TODO (alex): Remove exports
    { export SQL_PASSWORD=${MYSQL_PWD}; } 2> /dev/null

    if [ "${MYSQL_TX_ISOLATION_COMPAT}" == "true" ]; then
        MYSQL_CONNECT_ATTR=(--connect-attributes "tx_isolation=READ-COMMITTED")
    else
        MYSQL_CONNECT_ATTR=()
    fi

    SCHEMA_DIR=${TEMPORAL_HOME}/schema/mysql/v57/temporal/versioned
    temporal-sql-tool --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" "${MYSQL_CONNECT_ATTR[@]}" create --db "${DBNAME}"
    temporal-sql-tool --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" "${MYSQL_CONNECT_ATTR[@]}" --db "${DBNAME}" setup-schema -v 0.0
    temporal-sql-tool --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" "${MYSQL_CONNECT_ATTR[@]}" --db "${DBNAME}" update-schema -d "${SCHEMA_DIR}"
    VISIBILITY_SCHEMA_DIR=${TEMPORAL_HOME}/schema/mysql/v57/visibility/versioned
    temporal-sql-tool --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" "${MYSQL_CONNECT_ATTR[@]}" create --db "${VISIBILITY_DBNAME}"
    temporal-sql-tool --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" "${MYSQL_CONNECT_ATTR[@]}" --db "${VISIBILITY_DBNAME}" setup-schema -v 0.0
    temporal-sql-tool --ep "${MYSQL_SEEDS}" -u "${MYSQL_USER}" "${MYSQL_CONNECT_ATTR[@]}" --db "${VISIBILITY_DBNAME}" update-schema -d "${VISIBILITY_SCHEMA_DIR}"
}

setup_postgres_schema() {
    # TODO (alex): Remove exports
    { export SQL_PASSWORD=${POSTGRES_PWD}; } 2> /dev/null

    SCHEMA_DIR=${TEMPORAL_HOME}/schema/postgresql/v96/temporal/versioned
    temporal-sql-tool --plugin postgres --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" create --db "${DBNAME}"
    temporal-sql-tool --plugin postgres --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" --db "${DBNAME}" setup-schema -v 0.0
    temporal-sql-tool --plugin postgres --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" --db "${DBNAME}" update-schema -d "${SCHEMA_DIR}"
    VISIBILITY_SCHEMA_DIR=${TEMPORAL_HOME}/schema/postgresql/v96/visibility/versioned
    temporal-sql-tool --plugin postgres --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" create --db "${VISIBILITY_DBNAME}"
    temporal-sql-tool --plugin postgres --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" --db "${VISIBILITY_DBNAME}" setup-schema -v 0.0
    temporal-sql-tool --plugin postgres --ep "${POSTGRES_SEEDS}" -u "${POSTGRES_USER}" -p "${DB_PORT}" --db "${VISIBILITY_DBNAME}" update-schema -d "${VISIBILITY_SCHEMA_DIR}"
}

setup_schema() {
    if [ "${DB}" == "mysql" ]; then
        echo 'Setup MySQL schema.'
        setup_mysql_schema
    elif [ "${DB}" == "postgresql" ]; then
        echo 'Setup PostgreSQL schema.'
        setup_postgres_schema
    else
        echo 'Setup Cassandra schema.'
        setup_cassandra_schema
    fi
}

# === Elasticsearch functions ===

validate_es_env() {
    if [ "${ENABLE_ES}" == true ]; then
        if [ -z "${ES_SEEDS}" ]; then
            echo "ES_SEEDS env must be set if ENABLE_ES is ${ENABLE_ES}"
            exit 1
        fi
    fi
}

wait_for_es() {
    SECONDS=0

    ES_SERVER=$(echo "${ES_SEEDS}" | awk -F ',' '{print $1}')
    URL="${ES_SCHEME}://${ES_SERVER}:${ES_PORT}"

    until curl --silent --fail --user "${ES_USER}":"${ES_PWD}" "${URL}" > /dev/null 2>&1; do
        DURATION=${SECONDS}

        if [ "${ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS}" -gt 0 ] && [ ${DURATION} -ge "${ES_SCHEMA_SETUP_TIMEOUT_IN_SECONDS}" ]; then
            echo 'WARNING: timed out waiting for Elasticsearch to start up. Skipping index creation.'
            return;
        fi

        echo 'Waiting for Elasticsearch to start up.'
        sleep 1
    done

    echo 'Elasticsearch started.'
}

setup_es_template() {
    SCHEMA_FILE=${TEMPORAL_HOME}/schema/elasticsearch/${ES_VERSION}/visibility/index_template.json
    ES_SERVER=$(echo "${ES_SEEDS}" | awk -F ',' '{print $1}')
    TEMPLATE_URL="${ES_SCHEME}://${ES_SERVER}:${ES_PORT}/_template/temporal-visibility-template"
    INDEX_URL="${ES_SCHEME}://${ES_SERVER}:${ES_PORT}/${ES_VIS_INDEX}"
    curl --user "${ES_USER}":"${ES_PWD}" -X PUT "${TEMPLATE_URL}" -H 'Content-Type: application/json' --data-binary "@${SCHEMA_FILE}" --write-out "\n"
    curl --user "${ES_USER}":"${ES_PWD}" -X PUT "${INDEX_URL}" --write-out "\n"
}

# === Default namespace functions ===

register_default_namespace() {
    echo "Temporal CLI address: ${TEMPORAL_CLI_ADDRESS}."
    sleep 5
    echo "Registering default namespace: ${DEFAULT_NAMESPACE}."
    until tctl --ns "${DEFAULT_NAMESPACE}" namespace describe; do
        echo "Default namespace ${DEFAULT_NAMESPACE} not found. Creating..."
        sleep 1
        tctl --ns "${DEFAULT_NAMESPACE}" namespace register --rd "${DEFAULT_NAMESPACE_RETENTION}" --desc "Default namespace for Temporal Server."
    done
    echo "Default namespace registration complete."
}

# === Main ===

if [ "${SKIP_SCHEMA_SETUP}" != true ]; then
    validate_db_env
    wait_for_db
    setup_schema
fi

if [ "${ENABLE_ES}" == true ]; then
    validate_es_env
    wait_for_es
    setup_es_template
fi

if [ "${SKIP_DEFAULT_NAMESPACE_CREATION}" != true ]; then
    register_default_namespace &
fi
