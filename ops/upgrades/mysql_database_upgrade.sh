#!/bin/bash

source ./_common.sh

# Configures MySQL client file in the container
configure_mysql_cnf() {
    local container_name="$1"
    local mysql_root_password="$2"
    local temp_cnf

    temp_cnf=$(create_temp_file mysql.cnf) || {
        echo "Error: Failed to create temporary mysql.cnf" >&2
        return 1
    }

    cat > "${temp_cnf}" <<EOF || {
        echo "Error: Failed to write to ${temp_cnf}" >&2
        remove_temp_file "${temp_cnf}"
        return 1
    }
[client]
user=root
password=${mysql_root_password}
host=127.0.0.1
EOF

    chmod 600 "${temp_cnf}" || {
        echo "Error: Failed to set permissions on ${temp_cnf}" >&2
        remove_temp_file "${temp_cnf}"
        return 1
    }

    docker cp "${temp_cnf}" "${container_name}:/tmp/mysql.cnf" || {
        echo "Error: Failed to copy mysql.cnf to ${container_name}" >&2
        remove_temp_file "${temp_cnf}"
        return 1
    }

    docker exec "${container_name}" test -f /tmp/mysql.cnf || {
        echo "Error: mysql.cnf not found in ${container_name}" >&2
        remove_temp_file "${temp_cnf}"
        return 1
    }

    remove_temp_file "${temp_cnf}"
}

# Exports a MySQL database dump
export_mysql_dump() {
    local container_name="mysql_db"
    local target_db="$1"
    local output_file="$2"
    local mysql_root_password="${MYSQL_ROOT_PASSWORD:-}"

    [[ -z "${target_db}" ]] && {
        echo "Error: Target database not specified" >&2
        return 1
    }
    [[ -z "${output_file}" ]] && {
        echo "Error: Output file not specified" >&2
        return 1
    }

    check_docker_container "${container_name}" || {
        echo "Error: MySQL container '${container_name}' is not running" >&2
        return 1
    }

    configure_mysql_cnf "${container_name}" "${mysql_root_password}" || return 1

    docker exec "${container_name}" mysql --defaults-file=/tmp/mysql.cnf -e "SHOW DATABASES LIKE '${target_db}';" | grep -q "${target_db}" || {
        echo "Error: Database '${target_db}' does not exist" >&2
        return 1
    }

    echo "Exporting '${target_db}' to '${output_file}'..."
    if command -v pv >/dev/null; then
        local size
        size=$(docker exec "${container_name}" mysql --defaults-file=/tmp/mysql.cnf -N -e "SELECT SUM(data_length + index_length) FROM information_schema.tables WHERE table_schema='${target_db}';")
        docker exec "${container_name}" /usr/bin/mysqldump --defaults-file=/tmp/mysql.cnf --quick --single-transaction "${target_db}" | pv -s "${size}" > "${output_file}" || {
            echo "Error: mysqldump failed" >&2
            return 1
        }
    else
        echo "Warning: pv not installed. Proceeding without progress bar" >&2
        docker exec "${container_name}" /usr/bin/mysqldump --defaults-file=/tmp/mysql.cnf --quick --single-transaction "${target_db}" > "${output_file}" || {
            echo "Error: mysqldump failed" >&2
            return 1
        }
    }

    echo "Database '${target_db}' exported successfully to '${output_file}'"
}

# Imports a MySQL database dump
import_mysql_dump() {
    local container_name="mysql_db"
    local target_db="$1"
    local input_file="$2"
    local mysql_root_password="${MYSQL_ROOT_PASSWORD:-}"

    [[ -z "${target_db}" ]] && {
        echo "Error: Target database not specified" >&2
        return 1
    }
    [[ -z "${input_file}" ]] && {
        echo "Error: Input file not specified" >&2
        return 1
    }
    [[ ! -f "${input_file}" ]] && {
        echo "Error: Input file '${input_file}' does not exist" >&2
        return 1
    }

    check_docker_container "${container_name}" || {
        echo "Error: MySQL container '${container_name}' is not running" >&2
        return 1
    }

    configure_mysql_cnf "${container_name}" "${mysql_root_password}" || return 1

    echo "Ensuring database '${target_db}' exists..."
    docker exec "${container_name}" mysql --defaults-file=/tmp/mysql.cnf -e "DROP DATABASE IF EXISTS \`${target_db}\`; CREATE DATABASE \`${target_db}\`;" || {
        echo "Error: Failed to create database '${target_db}'" >&2
        return 1
    }

    echo "Importing '${input_file}' into '${target_db}'..."
    local file_size
    file_size=$(stat -c %s "${input_file}" 2>/dev/null || stat -f %z "${input_file}" 2>/dev/null)
    if command -v pv >/dev/null && [[ -n "${file_size}" ]]; then
        echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "${input_file}" | pv -s "${file_size}" | \
            docker exec -i "${container_name}" mysql --defaults-file=/tmp/mysql.cnf --force --max-allowed-packet=943718400 "${target_db}" || {
            echo "Error: Failed to import '${input_file}'" >&2
            return 1
        }
    else
        echo "Warning: pv not installed or file size unavailable. Proceeding without progress bar" >&2
        echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "${input_file}" | \
            docker exec -i "${container_name}" mysql --defaults-file=/tmp/mysql.cnf --force --max-allowed-packet=943718400 "${target_db}" || {
            echo "Error: Failed to import '${input_file}'" >&2
            return 1
        }
    }

    echo "Database '${target_db}' imported successfully from '${input_file}'"
}

# Sets up MySQL container and imports a dump
setup_and_import_mysql() {
    local network_name="${LIFERAY_DOCKER_NETWORK:-my_app_network}"
    local container_name="mysql_db"
    local target_db="$1"
    local input_file="$2"
    local mysql_root_password="${MYSQL_ROOT_PASSWORD:-}"
    local mysql_allow_empty="no"
    local temp_dir

    [[ -z "${target_db}" ]] && {
        echo "Error: Target database not specified" >&2
        return 1
    }
    [[ -z "${input_file}" ]] && {
        echo "Error: Input file not specified" >&2
        return 1
    }
    [[ ! -f "${input_file}" ]] && {
        echo "Error: Input file '${input_file}' does not exist" >&2
        return 1
    }

    if [[ -z "${mysql_root_password}" ]]; then
        echo "Warning: MYSQL_ROOT_PASSWORD is unset. Using empty password" >&2
        mysql_allow_empty="yes"
    fi

    if ! docker network ls --filter name=^${network_name}$ --format '{{.Name}}' | grep -q "^${network_name}$"; then
        echo "Creating Docker network '${network_name}'..."
        docker network create "${network_name}" || {
            echo "Error: Failed to create network '${network_name}'" >&2
            return 1
        }
    fi

    if docker ps -a --filter "name=^${container_name}$" --format '{{.Names}}' | grep -q "^${container_name}$"; then
        if [[ "$(docker inspect -f '{{.State.Running}}' "${container_name}")" == "false" ]]; then
            echo "Starting existing MySQL container '${container_name}'..."
            docker start "${container_name}" || {
                echo "Error: Failed to start container '${container_name}'" >&2
                return 1
            }
        fi
    else
        echo "Creating and starting MySQL container '${container_name}'..."
        local docker_run_cmd
        if [[ "${mysql_allow_empty}" == "yes" ]]; then
            docker_run_cmd="docker run -d \
                --name \"${container_name}\" \
                -e MYSQL_ROOT_PASSWORD=\"${mysql_root_password}\" \
                -e MYSQL_DATABASE=\"${target_db}\" \
                -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
                -p 3306:3306 \
                --network \"${network_name}\" \
                --memory=8g \
                --cpus=2 \
                mysql:8.0 \
                --character-set-server=utf8mb4 \
                --collation-server=utf8mb4_unicode_ci \
                --default-time-zone=GMT \
                --innodb_buffer_pool_size=4G \
                --max-allowed-packet=943718400 \
                --wait-timeout=6000 \
                --innodb_log_file_size=512M \
                --innodb_flush_log_at_trx_commit=2 \
                --innodb_io_capacity=2000 \
                --innodb_write_io_threads=8 \
                --sync_binlog=0"
        else
            docker_run_cmd="docker run -d \
                --name \"${container_name}\" \
                -e MYSQL_ROOT_PASSWORD=\"${mysql_root_password}\" \
                -e MYSQL_DATABASE=\"${target_db}\" \
                -p 3306:3306 \
                --network \"${network_name}\" \
                --memory=8g \
                --cpus=2 \
                mysql:8.0 \
                --character-set-server=utf8mb4 \
                --collation-server=utf8mb4_unicode_ci \
                --default-time-zone=GMT \
                --innodb_buffer_pool_size=4G \
                --max-allowed-packet=943718400 \
                --wait-timeout=6000 \
                --innodb_log_file_size=512M \
                --innodb_flush_log_at_trx_commit=2 \
                --innodb_io_capacity=2000 \
                --innodb_write_io_threads=8 \
                --sync_binlog=0"
        fi
        eval "${docker_run_cmd}" || {
            echo "Error: Failed to create container '${container_name}'" >&2
            return 1
        }
    fi

    local max_attempts=30 attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        echo "Checking if MySQL is ready (attempt ${attempt}/${max_attempts})..."
        if docker exec "${container_name}" mysqladmin ping --defaults-file=/tmp/mysql.cnf --silent; then
            echo "MySQL is ready"
            break
        fi
        if ! check_docker_container "${container_name}"; then
            echo "Error: Container '${container_name}' stopped unexpectedly" >&2
            docker logs "${container_name}" >&2
            return 1
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    [[ ${attempt} -gt ${max_attempts} ]] && {
        echo "Error: MySQL not ready after ${max_attempts} attempts" >&2
        docker logs "${container_name}" >&2
        return 1
    }

    if [[ "${input_file}" == *.zip ]]; then
        temp_dir=$(mktemp -d) || {
            echo "Error: Failed to create temporary directory" >&2
            return 1
        }
        unzip -o "${input_file}" -d "${temp_dir}" || {
            echo "Error: Failed to extract '${input_file}'" >&2
            rm -rf "${temp_dir}"
            return 1
        }
        input_file=$(find "${temp_dir}" -name "*.sql" | head -n 1)
        [[ -z "${input_file}" ]] && {
            echo "Error: No SQL file found in '${input_file}'" >&2
            rm -rf "${temp_dir}"
            return 1
        }
    elif [[ "${input_file}" != *.sql ]]; then
        echo "Error: Input file must be a .zip or .sql file" >&2
        return 1
    fi

    import_mysql_dump "${target_db}" "${input_file}" || {
        [[ -n "${temp_dir}" ]] && rm -rf "${temp_dir}"
        return 1
    }

    [[ -n "${temp_dir}" ]] && rm -rf "${temp_dir}"
}

# Stops and removes the MySQL container
stop_drop_mysql_db() {
    local container_name="mysql_db"

    if check_docker_container "${container_name}"; then
        echo "Stopping MySQL container '${container_name}'..."
        docker stop "${container_name}" || {
            echo "Error: Failed to stop container '${container_name}'" >&2
            return 1
        }
    fi

    if docker ps -a --filter "name=^${container_name}$" --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "Removing MySQL container '${container_name}'..."
        docker rm "${container_name}" || {
            echo "Error: Failed to remove container '${container_name}'" >&2
            return 1
        }
    fi

    echo "MySQL container '${container_name}' stopped and removed"
}

# Main function to handle script execution
main() {
    local action="$1"
    local db_type="$2"
    local target_db="$3"
    local dump_file="$4"

    [[ -z "${action}" ]] && {
        echo "Usage: $0 <action> <db_type> <target_db> <dump_file>" >&2
        echo "Actions: export, import, stop" >&2
        echo "DB types: mysql" >&2
        exit 1
    }
    [[ "${db_type}" != "mysql" ]] && {
        echo "Error: Only 'mysql' database type is supported" >&2
        exit 1
    }

    case "${action}" in
        export)
            export_mysql_dump "${target_db}" "${dump_file}" || exit 1
            ;;
        import)
            setup_and_import_mysql "${target_db}" "${dump_file}" || exit 1
            ;;
        stop)
            stop_drop_mysql_db || exit 1
            ;;
        *)
            echo "Error: Invalid action '${action}'. Use 'export', 'import', or 'stop'" >&2
            exit 1
            ;;
    esac
}

# Execute main function with command-line arguments
main "$@"