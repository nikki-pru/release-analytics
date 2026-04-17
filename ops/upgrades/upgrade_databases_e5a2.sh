#!/bin/bash
#
# Author: Brian Joyner Wulbern <brian.wulbern@liferay.com>
# Platform: Linux/Unix
# VERSION: 1.11.0
#

export_mysql_dump() {
  local MYSQL_CONTAINER_NAME="mysql_db"
  local TARGET_DB="$1"
  local OUTPUT_FILE="$2"
  local DEBUG=${DEBUG:-false}

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  [[ -z "$TARGET_DB" ]] && { echo "Error: Target database not specified." >&2; return 1; }
  [[ -z "$OUTPUT_FILE" ]] && { echo "Error: Output file not specified." >&2; return 1; }
  [[ -z "$MYSQL_CONTAINER_NAME" ]] && { echo "Error: MYSQL_CONTAINER_NAME is unset." >&2; return 1; }

  if ! docker ps --filter "name=^${MYSQL_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER_NAME}$"; then
    echo "Error: MySQL container '$MYSQL_CONTAINER_NAME' is not running." >&2
    return 1
  fi

  if ! docker exec "$MYSQL_CONTAINER_NAME" test -f /tmp/mysql.cnf; then
    echo "Error: /tmp/mysql.cnf not found in container. Creating..." >&2
    cat > /tmp/mysql.cnf <<'EOF' || { echo "Error: Failed to create /tmp/mysql.cnf" >&2; return 1; }
[client]
user=root
password=
host=127.0.0.1
EOF
    chmod 600 /tmp/mysql.cnf
    docker cp /tmp/mysql.cnf "$MYSQL_CONTAINER_NAME:/tmp/mysql.cnf" || {
      echo "Error copying MySQL config file to container." >&2
      rm -f /tmp/mysql.cnf
      return 1
    }
    rm -f /tmp/mysql.cnf
  fi

  if ! docker exec "$MYSQL_CONTAINER_NAME" mysql --defaults-file=/tmp/mysql.cnf -e "SHOW DATABASES LIKE '$TARGET_DB';" | grep -q "$TARGET_DB"; then
    echo "Error: Database '$TARGET_DB' does not exist." >&2
    return 1
  fi

  echo "Exporting '$TARGET_DB' to '$OUTPUT_FILE'..."
  if command -v pv >/dev/null; then
    # Get the size of the database in bytes and sanitize the output.
    local size_output
    size_output=$(docker exec "$MYSQL_CONTAINER_NAME" mysql --defaults-file=/tmp/mysql.cnf -N --raw -e "SELECT SUM(data_length + index_length) FROM information_schema.tables WHERE table_schema='$TARGET_DB';")
    
    local size_in_bytes
    if [[ -z "$size_output" || "$size_output" == "NULL" ]]; then
      size_in_bytes=0
    else
      size_in_bytes="$size_output"
    fi

    docker exec "$MYSQL_CONTAINER_NAME" /usr/bin/mysqldump --defaults-file=/tmp/mysql.cnf --quick --single-transaction "$TARGET_DB" | pv -s "$size_in_bytes" > "$OUTPUT_FILE" || {
      echo "Error: mysqldump failed." >&2
      return 1
  }
  else
    echo "Warning: pv not installed. Proceeding without progress bar." >&2
    docker exec "$MYSQL_CONTAINER_NAME" /usr/bin/mysqldump --defaults-file=/tmp/mysql.cnf --quick --single-transaction "$TARGET_DB" > "$OUTPUT_FILE" || {
      echo "Error: mysqldump failed." >&2
      return 1
    }
  fi

  echo "Database '$TARGET_DB' exported successfully to '$OUTPUT_FILE'."
}

import_mysql_dump() {
  local MYSQL_CONTAINER_NAME="mysql_db"
  local TARGET_DB="$1"
  local INPUT_FILE="$2"
  local DEBUG=${DEBUG:-false}
  local MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-""}

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  [[ -z "$TARGET_DB" ]] && { echo "Error: Target database not specified." >&2; return 1; }
  [[ -z "$INPUT_FILE" ]] && { echo "Error: Input file not specified." >&2; return 1; }
  [[ ! -f "$INPUT_FILE" ]] && { echo "Error: Input file '$INPUT_FILE' does2 not exist." >&2; return 1; }
  [[ -z "$MYSQL_CONTAINER_NAME" ]] && { echo "Error: MYSQL_CONTAINER_NAME is unset." >&2; return 1; }

  echo "Ensuring database '$TARGET_DB' exists..."
  local mysql_exec_cmd="mysql -u root"
  [[ -n "$MYSQL_ROOT_PASSWORD" ]] && mysql_exec_cmd+=" -p\"$MYSQL_ROOT_PASSWORD\""
  docker exec "$MYSQL_CONTAINER_NAME" bash -c "$mysql_exec_cmd -e \"DROP DATABASE IF EXISTS $TARGET_DB; CREATE DATABASE $TARGET_DB;\"" || {
    echo "Error creating database '$TARGET_DB'." >&2
    return 1
  }

  echo "Importing '$INPUT_FILE' into '$TARGET_DB'..."
  
  local import_output
  local mysql_import_cmd="$mysql_exec_cmd --force --max-allowed-packet=943718400 \"$TARGET_DB\""
  local awk_command='BEGIN {IGNORECASE=1} !/^[[:space:]]*(CREATE DATABASE|USE)[[:space:]]/'

  if command -v pv >/dev/null; then
    local file_size=$(stat -c %s "$INPUT_FILE" 2>/dev/null || stat -f %z "$INPUT_FILE" 2>/dev/null)
    if [[ -n "$file_size" ]]; then
      import_output=$(awk "$awk_command" "$INPUT_FILE" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" bash -c "cat - | $mysql_import_cmd" 2>&1)
    else
      import_output=$(awk "$awk_command" "$INPUT_FILE" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" bash -c "cat - | $mysql_import_cmd" 2>&1)
    fi
  else
    echo "Warning: pv not installed. Proceeding without progress bar." >&2
    import_output=$(awk "$awk_command" "$INPUT_FILE" | docker exec -i "$MYSQL_CONTAINER_NAME" bash -c "cat - | $mysql_import_cmd" 2>&1)
  fi

  if [[ $? -ne 0 ]]; then
    echo "Import failed: $import_output" >&2
    return 1
  fi

  echo "Database '$TARGET_DB' imported successfully from '$INPUT_FILE'."
}

import_oracle() {
  echo "Importing Oracle database..."

  declare -A databases=(
    ["1"]="Actinver --> dump.dmp"
    ["2"]="Argus --> dump2.dmp"
  )

  echo "Choose a database to import:"
  for i in "${!databases[@]}"; do
    echo "$i. ${databases[$i]}"
  done

  echo "8. Other"

  while true; do
    read -rp "Enter your choice: " choice
    if [[ $choice =~ ^[1-8]$ ]]; then
      break
    else
      echo "Invalid choice. Please enter a number between 1 and 8."
    fi
  done

  if [[ $choice == 8 ]]; then
    read -rp "Enter the path to your Oracle dump file (.dmp): " DUMP_FILE
  elif [[ $choice =~ ^[1-7]$ ]]; then
    DUMP_FILE="${databases[$choice]##*--> }"
  fi

  if [[ -z "$DUMP_FILE" ]]; then
    echo "No dump file specified. Skipping import."
    return 1
  fi

  if [[ ! -f "$DUMP_FILE" ]]; then
    echo "Dump file '$DUMP_FILE' not found. Skipping import."
    return 1
  fi

  if [[ ! "$DUMP_FILE" == *.dmp ]]; then
    echo "Invalid file type.  Oracle import requires a .dmp file (Data Pump export)."
    return 1
  fi

  chmod a+r "$DUMP_FILE"

  if ! docker cp "$DUMP_FILE" oracle_db:/opt/oracle/admin/ORCLCDB/dpdump/; then
    echo "Error copying dump file to Oracle container. Check Docker and file permissions."
    return 1
  fi

  echo "Dump file copied to Oracle container.  Execute the following command *inside* the container (as the oracle user):"
  echo "impdp LPORTAL/1234@ORCLCDB dumpfile=$(basename "$DUMP_FILE") logfile=LPORTAL.log remap_schema=LPORTAL:LPORTAL table_exists_action=replace"

  echo "Or, if you've set up a directory object in Oracle:"
  echo "impdp LPORTAL/1234@ORCLCDB directory=DATA_PUMP_DIR dumpfile=$(basename "$DUMP_FILE") logfile=LPORTAL.log remap_schema=LPORTAL:LPORTAL table_exists_action=replace"

  echo "Remember to replace LPORTAL/1234 with your actual username and password, and ORCLCDB with your service name."
}

import_postgresql() {
  echo "Choose a database to import:"
  echo "1. Ovam --> 24Q3_OVAM_database_dump.sql"
  echo "2. Church Mutual --> 24Q3_ChurchMutual_database_dump.sql"
  echo "3. Jessa --> 24Q4_Jessa_database_dump.sql"
  echo "4. RWTH Aachen University --> 25Q1_RWTH_database_dump.sql"
  echo "5. Other"
  read -p "Enter your choice: " import_choice
  case $import_choice in
    1)
      dump_file="24Q3_OVAM_database_dump.sql"
      ;;
    2)
      dump_file="24Q3_ChurchMutual_database_dump.sql"
      ;;
    3)
      dump_file="24Q4_Jessa_database_dump.sql"
      ;;
    4)
      dump_file="25Q1_RWTH_database_dump.sql"
      ;;
    5)
      read -p "Enter the path to your PostgreSQL dump file: " dump_file
      ;;
    *)
      echo "Invalid choice!"
      exit 1
      ;;
  esac

  if [ -f "$dump_file" ]; then
    echo "Importing PostgreSQL database from $dump_file..."
    docker exec -i postgresql_db psql -q -U root -d lportal < "$dump_file"
    if [ $? -eq 0 ]; then
      echo "Database imported successfully!"
    else
      echo "Error: Database import failed!"
      exit 1
    fi
  else
    echo "Error: Dump file $dump_file not found!"
    exit 1
  fi
}

import_sqlserver() {
  echo "Importing SQL Server database..."

  databases=(
    "Brinks --> 24Q3_Brinks_database_dump.bak"
    "Kubota --> 24Q1_Kubota_database_dump.bak"
    "Zain --> 23Q4_Zain_database_dump.bak"
  )

  echo "Choose a database to import:"
  for i in "${!databases[@]}"; do
    echo "$((i + 1)). ${databases[$i]}"
  done

  echo "4. Other"

  while true; do
    read -rp "Enter your choice: " choice
    if [[ "$choice" =~ ^[1-4]$ ]]; then
      break
    else
      echo "Invalid choice. Please enter a number between 1 and 4."
    fi
  done

  if [[ "$choice" == "4" ]]; then
    read -rp "Enter the path to your SQL Server dump file: " DUMP_FILE
    DB_NAME="Custom"
  else
    DB_NAME="${databases[$((choice - 1))]%% --> *}"
    DUMP_FILE="${databases[$((choice - 1))]##*--> }"
  fi

  if [[ -z "$DUMP_FILE" ]]; then
    echo "No dump file specified. Skipping import."
    exit 1
  fi

  if [[ ! -f "$DUMP_FILE" ]]; then
    echo "Dump file '$DUMP_FILE' not found. Skipping import."
    exit 1
  fi

  docker exec -it sqlserver_db mkdir -p /var/opt/mssql/backup

  if ! docker cp "$DUMP_FILE" sqlserver_db:/var/opt/mssql/backup; then
    echo "Error copying dump file to container. Check Docker and file permissions."
    exit 1
  fi

  echo "Dump file copied to SQL Server container."

  echo "Waiting for SQL Server to be ready..."
  for i in {1..30}; do
    docker exec sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT 1" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "SQL Server is ready!"
      break
    fi
    echo "Waiting for SQL Server... ($i/30)"
    sleep 2
  done

  filename=$(basename "$DUMP_FILE")
  echo "The file name is: $filename"

  file_list=$(docker exec -it sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "RESTORE FILELISTONLY FROM DISK = '/var/opt/mssql/backup/$filename'" 2>&1)
  if echo "$file_list" | grep -q "Msg [0-9]\+,"; then
    echo "Error listing files in backup. Check SQL Server logs in the container."
    docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
    exit 1
  fi

  echo "Files in backup directory:"
  echo "$file_list" | tr -s ' ' | cut -d ' ' -f 1-2

  if [[ "$choice" == "1" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/24Q3_Brinks_database_dump.bak' WITH MOVE 'cportal_72' TO '/var/opt/mssql/data/cportal_72.mdf', MOVE 'cportal_72_log' TO '/var/opt/mssql/data/cportal_72_log.ldf'\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "2" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/24Q1_Kubota_database_dump.bak' WITH MOVE 'liferay' TO '/var/opt/mssql/data/liferay.mdf', MOVE 'liferay_log' TO '/var/opt/mssql/data/liferay_log.ldf'\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "3" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/23Q4_Zain_database_dump.bak' WITH MOVE 'zainCommerce212' TO '/var/opt/mssql/data/zainCommerce212.mdf', MOVE 'zainCommerce212_log' TO '/var/opt/mssql/data/zainCommerce212_log.ldf'\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "4" ]]; then
    readarray -t logical_names < <(echo "$file_list" | awk '{print $1}' | tail -n +2 | head -n -2)
    move_clauses=""
    for logical_name in "${logical_names[@]}"; do
      if [[ "$logical_name" == *_log ]]; then
        continue
      fi
      data_file="/var/opt/mssql/data/${logical_name}.mdf"
      log_file="/var/opt/mssql/data/${logical_name}_log.ldf"
      move_clauses+="MOVE '${logical_name}' TO '${data_file}', MOVE '${logical_name}_log' TO '${log_file}', "
    done
    move_clauses="${move_clauses%, }"
    restore_command="RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/$filename' WITH $move_clauses"
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"$restore_command\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  fi

  echo "Checking SQL Server container status..."
  if docker exec -it sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT 1" 2>/dev/null; then
    echo "SQL Server container is running and accessible."
  else
    echo "Error: SQL Server container is not accessible. Please ensure the container is running and the database is available."
    exit 1
  fi

  echo "Verifying database restore..."
  docker exec -it sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT name FROM sys.databases WHERE name = 'lportal'" | grep lportal
  if [ $? -eq 0 ]; then
    echo "Database 'lportal' restored successfully!"
  else
    echo "Database 'lportal' not found. Restore failed."
    docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
    exit 1
  fi
}

run_oracle() {
  if docker ps -aqf name=oracle_db > /dev/null; then
    echo "Container 'oracle_db' already exists. Removing..."
    docker rm -f oracle_db
  fi

  echo "Setting up Oracle 19 environment..."
  mkdir -p ~/oracle/{dump,oradata,scripts-setup}
  cat <<EOF > ~/oracle/Dockerfile
FROM oracle/database:19.3.0-se2
COPY --chown=54321:54322 dump /opt/oracle/import
COPY --chown=54321:54322 oradata /opt/oracle/oradata
COPY --chown=54321:54322 scripts-setup /opt/oracle/scripts/setup
EOF
  docker build -t oracle/database:19.3.0-se2 ~/oracle
  docker run --name oracle_db -p 1521:1521 oracle/database:19.3.0-se2
  if [ $? -eq 0 ]; then
    echo "Oracle container started successfully!"
  else
    echo "Failed to start Oracle container."
  fi
}

run_postgresql() {
  if docker ps -aqf name=postgresql_db > /dev/null; then
    echo "Container 'postgresql_db' already exists. Removing..."
    docker rm -f postgresql_db
  fi

  echo "Starting PostgreSQL container..."
  docker run --name postgresql_db -d \
    -e POSTGRES_USER=root \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_DB=lportal \
    -p 5433:5432 \
    postgres:15.5
  if [ $? -eq 0 ]; then
    echo "Waiting for PostgreSQL to be ready..."
    until docker exec postgresql_db pg_isready -U root -h localhost; do
      sleep 1
    done
    echo "PostgreSQL container started successfully!"
  else
    echo "Failed to start PostgreSQL container."
    exit 1
  fi

  echo "Dropping and recreating lportal."
  docker exec -i postgresql_db psql -U root -d postgres -c "DROP DATABASE IF EXISTS lportal;"
  docker exec -i postgresql_db psql -U root -d postgres -c "CREATE DATABASE lportal;"
  docker exec -i postgresql_db psql -U root -d postgres -c "CREATE ROLE liferay WITH LOGIN PASSWORD 'liferay';"
}

upgrade_postgresql_with_local_tomcat() {
  local TOMCAT_DIR="$1"
  local TOMCAT_ARCHIVE="$2"

  echo "Starting Tomcat setup..."

  local TOMCAT_ARCHIVE_PATH TOMCAT_VERSION
  local LIFERAY_DIR="liferay-dxp"
  while true; do
    read -rp "Enter the path to your Tomcat bundle directory (or press Enter to search for a Liferay Tomcat archive in the current folder): " TOMCAT_ARCHIVE_PATH

    if [[ -z "$TOMCAT_ARCHIVE_PATH" ]]; then
      TOMCAT_ARCHIVE_PATH="./"
      TOMCAT_ARCHIVE=$(find "$TOMCAT_ARCHIVE_PATH" -maxdepth 1 \( \
        -name "liferay-dxp-tomcat-7.4.13-u*.zip" \
        -o -name "liferay-dxp-tomcat-7.4.13-u*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2024.*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2024.*.zip" \
        -o -name "liferay-dxp-tomcat-2025.*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2025.*.zip" \
        -o -name "liferay-fixed.zip" \) -print | head -n 1)

      if [[ -z "$TOMCAT_ARCHIVE" ]]; then
        echo "No Liferay Tomcat archive found in the current directory." >&2
        continue
      fi
      break
    elif [[ -f "$TOMCAT_ARCHIVE_PATH" ]]; then
      TOMCAT_ARCHIVE="$TOMCAT_ARCHIVE_PATH"
      break
    elif [[ -d "$TOMCAT_ARCHIVE_PATH" ]]; then
      echo "Error: '$TOMCAT_ARCHIVE_PATH' is a directory. Please provide a Tomcat archive file." >&2
      continue
    else
      echo "Invalid path. Please enter a valid Tomcat archive file or press Enter." >&2
      continue
    fi
  done

  local TOMCAT_VERSION=$(basename "$TOMCAT_ARCHIVE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
  echo "Using Tomcat version: $TOMCAT_VERSION"

  echo "Navigating to $(pwd)..."
  cd "$(pwd)" || { echo "Error: Failed to navigate to current directory." >&2; return 1; }

  if [[ -d "$LIFERAY_DIR" ]]; then
    echo "Deleting existing '$LIFERAY_DIR' folder..."
    rm -rf "$LIFERAY_DIR" || { echo "Error: Failed to delete '$LIFERAY_DIR'." >&2; return 1; }
  fi

  echo "Unzipping '$TOMCAT_ARCHIVE'..."
  if [[ "$TOMCAT_ARCHIVE" == *.zip ]]; then
    unzip -o "$TOMCAT_ARCHIVE" -d . || { echo "Error: Failed to unzip '$TOMCAT_ARCHIVE'." >&2; return 1; }
  elif [[ "$TOMCAT_ARCHIVE" == *.tar.gz ]]; then
    tar -xzf "$TOMCAT_ARCHIVE" -C . || { echo "Error: Failed to extract '$TOMCAT_ARCHIVE'." >&2; return 1; }
  else
    echo "Error: Unsupported archive format for '$TOMCAT_ARCHIVE'." >&2
    return 1
  fi
  if [[ ! -d "$LIFERAY_DIR" ]]; then
    echo "Error: Unzipped archive did not create '$LIFERAY_DIR' folder." >&2
    return 1
  fi

  echo "Using Tomcat version: $VERSION"
  echo "Tomcat directory: $TOMCAT_DIR"

  echo "Navigating to $LIFERAY_DIR and creating portal-ext.properties..."
  cd "$LIFERAY_DIR" || { echo "Failed to enter $LIFERAY_DIR"; return 1; }

  cat > portal-ext.properties <<EOF
jdbc.default.driverClassName=org.postgresql.Driver
jdbc.default.url=jdbc:postgresql://localhost:5433/lportal
jdbc.default.username=root
jdbc.default.password=
upgrade.database.dl.storage.check.disabled=true
EOF

  echo "portal-ext.properties created successfully in $LIFERAY_DIR."
  cd ../

  DB_UPGRADE_DIR="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
  if [[ -d "$DB_UPGRADE_DIR" ]]; then
    echo "Navigating to $DB_UPGRADE_DIR and updating portal-upgrade-database.properties..."
    cd "$DB_UPGRADE_DIR" || { echo "Failed to enter $DB_UPGRADE_DIR"; return 1; }

    cat > portal-upgrade-database.properties <<EOF
jdbc.default.driverClassName=org.postgresql.Driver
jdbc.default.url=jdbc:postgresql://localhost:5433/lportal
jdbc.default.username=root
jdbc.default.password=
upgrade.database.dl.storage.check.disabled=true
EOF

    echo "portal-upgrade-database.properties updated successfully."

    echo "Running database upgrade script..."
    ./db_upgrade_client.sh -j "-Dfile.encoding=UTF-8 -Duser.timezone=GMT -Xmx4096m"
  else
    echo "Error: Database upgrade directory $DB_UPGRADE_DIR not found."
    return 1
  fi

  echo "Script execution completed with database: $dump_file"
}

run_sqlserver() {
  echo "Starting SQL Server container..."

  # Remove existing container if it exists
  if docker ps -aqf name=sqlserver_db > /dev/null; then
    echo "Container 'sqlserver_db' already exists. Removing..."
    docker rm -f sqlserver_db
  fi
  
  # Start SQL Server container
  docker run --user root -d \
    -e 'ACCEPT_EULA=Y' -e 'MSSQL_SA_PASSWORD=R00t@1234' \
    --name sqlserver_db -p 1433:1433 \
    mcr.microsoft.com/mssql/server:2022-latest
  if [ $? -eq 0 ]; then
    echo "SQL Server container started successfully!"
  else
    echo "Failed to start SQL Server container."
    exit 1
  fi

  echo "Waiting for SQL Server to be ready..."
  # Initial delay to allow container to start logging
  sleep 5
  # Timeout after 60 seconds
  timeout=60
  start_time=$(date +%s)
  until docker logs sqlserver_db | grep -q "SQL Server is now ready for client connections"; do
    current_time=$(date +%s)
    if [ $((current_time - start_time)) -gt $timeout ]; then
      echo "Error: SQL Server failed to become ready within $timeout seconds."
      echo "Container logs:"
      docker logs sqlserver_db
      exit 1
    fi
    echo "SQL Server not ready yet..."
    sleep 3
  done
  echo "SQL Server is ready!"
}

upgrade_sqlserver_with_local_tomcat() {
  local TOMCAT_DIR="$1"
  local TOMCAT_ARCHIVE="$2"
  local MSSQL_JDBC_JAR="mssql-jdbc-12.2.0.jre8.jar"

  echo "Starting Tomcat setup..."

  local TOMCAT_ARCHIVE_PATH TOMCAT_VERSION
  local LIFERAY_DIR="liferay-dxp"
  while true; do
    read -rp "Enter the path to your Tomcat bundle directory (or press Enter to search for a Liferay Tomcat archive in the current folder): " TOMCAT_ARCHIVE_PATH

    if [[ -z "$TOMCAT_ARCHIVE_PATH" ]]; then
      TOMCAT_ARCHIVE_PATH="./"
      TOMCAT_ARCHIVE=$(find "$TOMCAT_ARCHIVE_PATH" -maxdepth 1 \( \
        -name "liferay-dxp-tomcat-7.4.13-u*.zip" \
        -o -name "liferay-dxp-tomcat-7.4.13-u*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2024.*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2024.*.zip" \
        -o -name "liferay-dxp-tomcat-2025.*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2025.*.zip" \
        -o -name "liferay-fixed.zip" \) -print | head -n 1)

      if [[ -z "$TOMCAT_ARCHIVE" ]]; then
        echo "No Liferay Tomcat archive found in the current directory." >&2
        continue
      fi
      break
    elif [[ -f "$TOMCAT_ARCHIVE_PATH" ]]; then
      TOMCAT_ARCHIVE="$TOMCAT_ARCHIVE_PATH"
      break
    elif [[ -d "$TOMCAT_ARCHIVE_PATH" ]]; then
      echo "Error: '$TOMCAT_ARCHIVE_PATH' is a directory. Please provide a Tomcat archive file." >&2
      continue
    else
      echo "Invalid path. Please enter a valid Tomcat archive file or press Enter." >&2
      continue
    fi
  done

  local TOMCAT_VERSION=$(basename "$TOMCAT_ARCHIVE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
  echo "Using Tomcat version: $TOMCAT_VERSION"

  echo "Navigating to $(pwd)..."
  cd "$(pwd)" || { echo "Error: Failed to navigate to current directory." >&2; return 1; }

  if [[ -d "$LIFERAY_DIR" ]]; then
    echo "Deleting existing '$LIFERAY_DIR' folder..."
    rm -rf "$LIFERAY_DIR" || { echo "Error: Failed to delete '$LIFERAY_DIR'." >&2; return 1; }
  fi

  echo "Unzipping '$TOMCAT_ARCHIVE'..."
  if [[ "$TOMCAT_ARCHIVE" == *.zip ]]; then
    unzip -o "$TOMCAT_ARCHIVE" -d . || { echo "Error: Failed to unzip '$TOMCAT_ARCHIVE'." >&2; return 1; }
  elif [[ "$TOMCAT_ARCHIVE" == *.tar.gz ]]; then
    tar -xzf "$TOMCAT_ARCHIVE" -C . || { echo "Error: Failed to extract '$TOMCAT_ARCHIVE'." >&2; return 1; }
  else
    echo "Error: Unsupported archive format for '$TOMCAT_ARCHIVE'." >&2
    return 1
  fi
  if [[ ! -d "$LIFERAY_DIR" ]]; then
    echo "Error: Unzipped archive did not create '$LIFERAY_DIR' folder." >&2
    return 1
  fi

  echo "Using Tomcat version: $VERSION"
  echo "Tomcat directory: $TOMCAT_DIR"

  echo "Navigating to $LIFERAY_DIR and creating portal-ext.properties..."
  cd "$LIFERAY_DIR" || { echo "Failed to enter $LIFERAY_DIR"; return 1; }

  cat > portal-ext.properties <<EOF
jdbc.default.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
jdbc.default.url=jdbc:sqlserver://localhost:1433;databaseName=lportal;trustServerCertificate=true;
jdbc.default.username=sa
jdbc.default.password=R00t@1234
upgrade.database.dl.storage.check.disabled=true
EOF

  echo "portal-ext.properties created successfully in $LIFERAY_DIR."
  cd ../

  JDBC_DEST="$LIFERAY_DIR/tomcat/webapps/ROOT/WEB-INF/shielded-container-lib/"
  if [[ -f "$MSSQL_JDBC_JAR" ]]; then
      echo "Copying $MSSQL_JDBC_JAR to $JDBC_DEST"
      mkdir -p "$JDBC_DEST"

      rsync -av "$MSSQL_JDBC_JAR" "$JDBC_DEST"

      if [[ -f "$JDBC_DEST/$MSSQL_JDBC_JAR" ]]; then
          echo "JDBC driver copied successfully."
      else
          echo "Error: Failed to copy JDBC driver to $JDBC_DEST"
          return 1
      fi
  else
      echo "Warning: JDBC driver file $MSSQL_JDBC_JAR not found in the current directory."
  fi

  DB_UPGRADE_DIR="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
  if [[ -d "$DB_UPGRADE_DIR" ]]; then
    echo "Navigating to $DB_UPGRADE_DIR and updating portal-upgrade-database.properties..."
    cd "$DB_UPGRADE_DIR" || { echo "Failed to enter $DB_UPGRADE_DIR"; return 1; }

    cat > portal-upgrade-database.properties <<EOF
jdbc.default.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
jdbc.default.url=jdbc:sqlserver://localhost:1433;databaseName=lportal;trustServerCertificate=true;
jdbc.default.username=sa
jdbc.default.password=R00t@1234
upgrade.database.dl.storage.check.disabled=true
EOF

    echo "portal-upgrade-database.properties updated successfully."

    echo "Running database upgrade script..."
    ./db_upgrade_client.sh -j "-Dfile.encoding=UTF-8 -Duser.timezone=GMT -Xmx4096m"
  else
    echo "Error: Database upgrade directory $DB_UPGRADE_DIR not found."
    return 1
  fi

  echo "Script execution completed with database: $DB_NAME"
}

setup_and_import_mysql() {
    local NETWORK_NAME="my_app_network"
    local MYSQL_CONTAINER_NAME="mysql_db"
    local TARGET_DB ZIP_FILE temp_dir
    local DEBUG=${DEBUG:-false}
    local MODL_CODE=""
    local MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-""}
    local MYSQL_ALLOW_EMPTY
    local DOCKER_IMAGE="mysql:8.0" # Default image
    local IS_DXP_CLOUD=false       # Flag for DXP Cloud path
    # Variable to hold the actual directory name if unzipped from e5a2.zip
    local E5A2_DUMP_SUBDIR=""

    debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

    echo 'Choose a database to import:'
    echo '1) Actinver'
    echo '2) APCOA'
    echo '3) Argus'
    echo '4) CNO Bizlink'
    echo '5) Metos'
    echo '6) TUDelft'
    echo '7) e5a2'
    echo '8) Other (custom path)'
    echo '9) Liferay DXP Cloud'
    read -rp 'Enter your choice: ' CHOICE

    case "$CHOICE" in
        1) TARGET_DB="actinver_db"; ZIP_FILE="24Q1_Actinver_database_dump.zip" ;;
        2) TARGET_DB="apcoa_db"; ZIP_FILE="24Q2_APCOA_database_dump.sql" ;;
        3) TARGET_DB="argus_db"; ZIP_FILE="24Q2_Argus_database_dump.sql" ;;
        4) TARGET_DB="cno_bizlink_db"; ZIP_FILE="24Q1_CNOBizlink_database_dump.sql" ;;
        5) TARGET_DB="metos_db"; ZIP_FILE="24Q3_Metos_database_dump.zip" ;;
        6) TARGET_DB="tudelft_db"; ZIP_FILE="24Q1_TUDelft_database_dump.sql" ;;
        7) TARGET_DB="lportal"; ZIP_FILE="cleaned_with_use.sql"
           # Store the specific subdirectory name for e5a2 unzipped content
           E5A2_DUMP_SUBDIR="5ff380f7-ced4-4df3-bac0-6af9537f5c9d"
           MODL_CODE="e5a2"
           ;;
        8) read -rp "Enter the path to your custom dump zip: " ZIP_FILE
           read -rp "Enter your target database name: " TARGET_DB ;;
        9)
            TARGET_DB="lportal"
            read -rp "Enter the LPD ticket number (e.g., LPD-52788): " LPD_TICKET
            read -rp "Enter the MODL code (e.g., r8k1): " MODL_CODE
            [[ -z "$LPD_TICKET" ]] && { echo "Error: LPD ticket number cannot be empty." >&2; return 1; }
            [[ -z "$MODL_CODE" ]] && { echo "Error: MODL code cannot be empty." >&2; return 1; }
            DOCKER_IMAGE="liferay/database-upgrades:$LPD_TICKET"
            IS_DXP_CLOUD=true
            ;;
        *)
            echo "Invalid MySQL choice." >&2
            return 1
            ;;
    esac

    debug "You selected: $TARGET_DB with dump file: $ZIP_FILE"
    echo '📦 Importing MySQL database...' >&2
    echo "Target database is: $TARGET_DB" >&2

    # --- Common Docker Setup (Container, Network, MySQL config) ---
    [[ -z "$MYSQL_CONTAINER_NAME" ]] && { echo "Error: MYSQL_CONTAINER_NAME is unset." >&2; return 1; }
    [[ -z "$NETWORK_NAME" ]] && { echo "Error: NETWORK_NAME is unset." >&2; return 1; }
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        echo "Warning: MYSQL_ROOT_PASSWORD is unset. Using empty password with MYSQL_ALLOW_EMPTY_PASSWORD=yes." >&2
        MYSQL_ROOT_PASSWORD=""
        MYSQL_ALLOW_EMPTY="yes"
    else
        MYSQL_ALLOW_EMPTY="no"
    fi

    debug "Checking for Docker network '$NETWORK_NAME'"
    if ! docker network ls --filter name=^${NETWORK_NAME}$ --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
        echo "Creating Docker network '$NETWORK_NAME'..."
        docker network create "$NETWORK_NAME" || { echo "Error creating network." >&2; return 1; }
    fi

    debug "Checking MySQL container '$MYSQL_CONTAINER_NAME'"
    if docker ps -a --filter "name=^${MYSQL_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER_NAME}$"; then
        if [[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER_NAME")" == "false" ]]; then
            echo "Starting existing MySQL container '$MYSQL_CONTAINER_NAME'..."
            docker start "$MYSQL_CONTAINER_NAME" || { echo "Error starting container." >&2; return 1; }
        else
            echo "MySQL container '$MYSQL_CONTAINER_NAME' is already running."
        fi
    else

      local password_env_var=""
        if [[ "$MYSQL_ALLOW_EMPTY" == "yes" ]]; then
            password_env_var="-e MYSQL_ALLOW_EMPTY_PASSWORD=yes"
        else
            password_env_var="-e MYSQL_ROOT_PASSWORD=\"$MYSQL_ROOT_PASSWORD\""
        fi

        echo "Creating and starting MySQL container '$MYSQL_CONTAINER_NAME'..."
        docker_run_cmd="docker run -d \
            --name \"$MYSQL_CONTAINER_NAME\" \
            $password_env_var \
            -e MYSQL_DATABASE=\"$TARGET_DB\" \
            -p 3306:3306 \
            --network \"$NETWORK_NAME\" \
            --memory=8g \
            --cpus=2 \
            $DOCKER_IMAGE \
            --default-time-zone='GMT' \
            --innodb_buffer_pool_size=4G \
            --max-allowed-packet=943718400 \
            --wait-timeout=6000 \
            --innodb_log_file_size=512M \
            --innodb_flush_log_at_trx_commit=2 \
            --innodb_io_capacity=2000 \
            --innodb_write_io_threads=8 \
            --sync_binlog=0"

        debug "Docker run command: $docker_run_cmd"
        eval "$docker_run_cmd" || { echo "Error creating container." >&2; return 1; }
    fi

    debug "Creating MySQL config file at /tmp/mysql.cnf"
    cat > /tmp/mysql.cnf <<EOF || { echo "Error: Failed to create /tmp/mysql.cnf" >&2; return 1; }
[client]
user=root
password=%%PASSWORD%%
host=127.0.0.1
EOF
    sed -i "s/%%PASSWORD%%/$(printf '%s' "$MYSQL_ROOT_PASSWORD" | sed -e 's/[\/&]/\\&/g')/" /tmp/mysql.cnf || {
        echo "Error: Failed to set password in /tmp/mysql.cnf" >&2
        rm -f /tmp/mysql.cnf
        return 1
    }
    chmod 600 /tmp/mysql.cnf || {
        echo "Error: Failed to set permissions on /tmp/mysql.cnf" >&2
        rm -f /tmp/mysql.cnf
        return 1
    }
    debug "Copying /tmp/mysql.cnf to container $MYSQL_CONTAINER_NAME"
    docker cp /tmp/mysql.cnf "$MYSQL_CONTAINER_NAME:/tmp/mysql.cnf" 2>&1 | tee /tmp/docker_cp_error.log || {
        echo "Error copying MySQL config file to container: $(cat /tmp/docker_cp_error.log)" >&2
        rm -f /tmp/mysql.cnf /tmp/docker_cp_error.log
        return 1
    }
    rm -f /tmp/docker_cp_error.log

    debug "Verifying /tmp/mysql.cnf in container"
    docker exec "$MYSQL_CONTAINER_NAME" test -f /tmp/mysql.cnf || {
        echo "Error: /tmp/mysql.cnf not found in container after copy." >&2
        rm -f /tmp/mysql.cnf
        return 1
    }
    debug "Config file contents:"
    docker exec "$MYSQL_CONTAINER_NAME" cat /tmp/mysql.cnf >&2

    local max_attempts=30 attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        echo "Checking if MySQL is ready (attempt $attempt)..."
        local ping_output
        local mysql_admin_cmd="mysqladmin ping -u root"
        [[ -n "$MYSQL_ROOT_PASSWORD" ]] && mysql_admin_cmd+=" -p\"$MYSQL_ROOT_PASSWORD\""
        ping_output=$(docker exec "$MYSQL_CONTAINER_NAME" $mysql_admin_cmd --host=127.0.0.1 --port=3306 --silent 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "MySQL is ready."
            break
        else
            debug "mysqladmin ping failed: $ping_output"
        fi

        if ! docker ps --filter "name=^${MYSQL_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER_NAME}$"; then
            echo "Error: Container '$MYSQL_CONTAINER_NAME' stopped unexpectedly." >&2
            echo "Container logs:" >&2
            docker logs "$MYSQL_CONTAINER_NAME" >&2
            rm -f /tmp/mysql.cnf
            return 1
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
    [[ $attempt -gt $max_attempts ]] && {
        echo "MySQL not ready after $max_attempts attempts." >&2
        echo "Container logs:" >&2
        docker logs "$MYSQL_CONTAINER_NAME" >&2
        rm -f /tmp/mysql.cnf
        return 1
    }

    # --- Start of the NEW insertion point ---
    # Create dxpcloud user and grant privileges if TARGET_DB is e5a2,
    # as the dump seems to contain objects defined by this user.
    if [[ "$TARGET_DB" == "lportal" ]]; then
        echo "Configuring 'dxpcloud' user for e5a2 database (due to definer issues)..."
        
        # Build the common MySQL client arguments separately
        local mysql_client_args="-u root"
        [[ -n "$MYSQL_ROOT_PASSWORD" ]] && mysql_client_args+=" -p\"$MYSQL_ROOT_PASSWORD\""

        # Check for user existence
        local dxpcloud_user_exists_query="SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user='dxpcloud' AND host='%');"
        local dxpcloud_user_exists=$(docker exec "$MYSQL_CONTAINER_NAME" bash -c "mysql $mysql_client_args -e \"$dxpcloud_user_exists_query\"" | grep -Eo '[0-1]' | tail -n 1)

        if [[ "$dxpcloud_user_exists" -eq 1 ]]; then
            echo "'dxpcloud'@'%' user already exists. Updating privileges..."
        else
            echo "Creating 'dxpcloud'@'%' user with empty password..."
            local create_user_query="CREATE USER 'dxpcloud'@'%' IDENTIFIED BY '';"
            docker exec "$MYSQL_CONTAINER_NAME" bash -c "mysql $mysql_client_args -e \"$create_user_query\"" || {
                echo "Error creating dxpcloud user." >&2
                rm -f /tmp/mysql.cnf
                return 1
            }
        fi

        echo "Granting ALL PRIVILEGES on $TARGET_DB.* to 'dxpcloud'@'%'..."
        # FIX: Remove the backticks. 'e5a2' is a simple enough name not to need them,
        # and it avoids bash's command substitution.
        local grant_privs_query="GRANT ALL PRIVILEGES ON $TARGET_DB.* TO 'dxpcloud'@'%';"
        docker exec "$MYSQL_CONTAINER_NAME" bash -c "mysql $mysql_client_args -e \"$grant_privs_query\"" || {
            echo "Error granting privileges to dxpcloud user on $TARGET_DB." >&2
            rm -f /tmp/mysql.cnf
            return 1
        }
        echo "Flushing privileges..."
        local flush_privs_query="FLUSH PRIVILEGES;"
        docker exec "$MYSQL_CONTAINER_NAME" bash -c "mysql $mysql_client_args -e \"$flush_privs_query\"" || {
            echo "Error flushing privileges for dxpcloud user." >&2
            rm -f /tmp/mysql.cnf
            return 1
        }
        echo "'dxpcloud' user configured successfully."
    fi
    # --- End of the NEW insertion point ---

    echo "Ensuring database '$TARGET_DB' exists..."
    local mysql_exec_cmd="mysql -u root"
    [[ -n "$MYSQL_ROOT_PASSWORD" ]] && mysql_exec_cmd+=" -p\"$MYSQL_ROOT_PASSWORD\""
    docker exec "$MYSQL_CONTAINER_NAME" $mysql_exec_cmd -e "CREATE DATABASE IF NOT EXISTS $TARGET_DB" || {
        echo "Error creating database." >&2
        rm -f /tmp/mysql.cnf
        return 1
    }

    # --- Start Refactored Import Section ---
    local SQL_FILES_TO_IMPORT=()
    local temp_unzip_dir=""

    if [[ "$IS_DXP_CLOUD" == "true" ]]; then
        echo "Executing DXP Cloud specific setup and preparing import..."
        # ... (Your DXP Cloud logic - keep as is if it's working for that case) ...
        # Ensure it correctly populates SQL_FILES_TO_IMPORT with the container path
        local sql_files_container=$(docker exec "$MYSQL_CONTAINER_NAME" find /docker-entrypoint-initdb.d /tmp / -maxdepth 3 -name "*.sql" -type f 2>/dev/null)
        if [[ -z "$sql_files_container" ]]; then
            echo "Error: No SQL files found in container for DXP Cloud path." >&2
            rm -f /tmp/mysql.cnf
            return 1
        fi
        readarray -t sql_file_array <<<"$sql_files_container"
        local file_count=${#sql_file_array[@]}
        local CONTAINER_SQL_PATH=""
        if [[ $file_count -eq 1 ]]; then
            CONTAINER_SQL_PATH="${sql_file_array[0]}"
            echo "Found SQL file: $CONTAINER_SQL_PATH"
        else
            echo "Multiple SQL files found in container:"
            for i in "${!sql_file_array[@]}"; do
                echo "$((i+1))) ${sql_file_array[$i]}"
            done
            read -rp "Select the number of the SQL file to use (1-$file_count): " file_choice
            if [[ ! "$file_choice" =~ ^[0-9]+$ || "$file_choice" -lt 1 || "$file_choice" -gt $file_count ]]; then
                echo "Error: Invalid selection." >&2
                rm -f /tmp/mysql.cnf
                return 1
            fi
            CONTAINER_SQL_PATH="${sql_file_array[$((file_choice-1))]}"
            echo "Selected SQL file: $CONTAINER_SQL_PATH"
        fi
        SQL_FILES_TO_IMPORT+=("$CONTAINER_SQL_PATH") # Add the selected path

    elif [[ "$ZIP_FILE" == *.zip ]]; then
        temp_unzip_dir=$(mktemp -d)
        echo "Unzipping $ZIP_FILE to temporary directory $temp_unzip_dir..."
        unzip -o "$ZIP_FILE" -d "$temp_unzip_dir" || { echo "Failed to extract $ZIP_FILE" >&2; rm -f /tmp/mysql.cnf; rm -rf "$temp_unzip_dir"; return 1; }

        # --- MODIFIED: Identify the single unzipped file directly ---
        local unzipped_file=""
        # Assuming there's only one file extracted at the root of the zip
        unzipped_file=$(find "$temp_unzip_dir" -maxdepth 1 -type f -print | head -n 1)

        if [[ -z "$unzipped_file" ]]; then
            echo "Error: No file found in '$temp_unzip_dir' after unzipping '$ZIP_FILE'." >&2
            rm -f /tmp/mysql.cnf
            rm -rf "$temp_unzip_dir"
            return 1
        fi

        # Verify it's an SQL dump (optional but good practice)
        if ! head -n 100 "$unzipped_file" | grep -E -i '^(CREATE|INSERT|UPDATE|DELETE|ALTER|DROP|SET)' >/dev/null; then
            echo "Error: Unzipped file '$unzipped_file' does not appear to be a SQL dump." >&2
            rm -f /tmp/mysql.cnf
            rm -rf "$temp_unzip_dir"
            return 1
        fi

        SQL_FILES_TO_IMPORT+=("$unzipped_file") # Add the single unzipped file to the list
        # --- END MODIFIED ---

    # Handle single .sql, .bak, or other directly detected SQL files (keep this block)
    elif [[ "$ZIP_FILE" == *.sql || "$ZIP_FILE" == *.bak || "$(head -n 100 "$ZIP_FILE" | grep -E -i '^(CREATE|INSERT|UPDATE|DELETE|ALTER|DROP|SET)')" ]]; then
        SQL_FILES_TO_IMPORT+=("$ZIP_FILE")
    else # Fallback for unknown file types
        echo "Error: Input file must be a .zip file or a valid SQL dump file" >&2
        rm -f /tmp/mysql.cnf
        return 1
    fi # End of file type checks (DXP Cloud, ZIP, SQL, other)

    if [[ "$IS_DXP_CLOUD" == "true" && -n "$table_count" && "$table_count" -gt 0 ]]; then
        echo "Skipping SQL import as database is already populated for DXP Cloud."
    else # Only proceed with import if not skipped by DXP Cloud check
        if [[ ${#SQL_FILES_TO_IMPORT[@]} -eq 0 ]]; then
            echo "No SQL files were identified for import. Exiting." >&2
            rm -f /tmp/mysql.cnf
            [[ -n "$temp_unzip_dir" ]] && rm -rf "$temp_unzip_dir"
            return 1
        fi

        for current_sql_file_path in "${SQL_FILES_TO_IMPORT[@]}"; do
            echo "Importing: $(basename "$current_sql_file_path") into '$TARGET_DB'..."

            local container_src_file=""
            # local_cleaned_file is needed only if IS_DXP_CLOUD is false.
            local local_cleaned_file_to_remove="" # Declare for cleanup later

            if [[ "$IS_DXP_CLOUD" == "true" ]]; then
                # For DXP Cloud, file is already in container, no local cleaning/copy
                container_src_file="$current_sql_file_path"
                echo "  - Using DXP Cloud container file: $container_src_file (assumed pre-cleaned/direct)"
            else
                # For local files (zipped or single), clean locally and copy
                local local_original_file="${current_sql_file_path}" # Original file path
                local_cleaned_file_to_remove="${local_original_file}.cleaned" # Path to the .cleaned file on host
                local temp_intermediate_file="${local_original_file}.cleaned.tmp" # For two-pass sed

                echo "  - Cleaning local SQL file: $(basename "$local_original_file")"

                # First pass: Remove CREATE DATABASE lines (case-insensitive without 'I' flag)
                sed -E '/^[[:space:]]*[Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Dd][Aa][Tt][Aa][Bb][Aa][Ss][Ee][^;]*;[[:space:]]*$/d' "$local_original_file" > "$temp_intermediate_file" || {
                    echo "Error: First SED pass (CREATE DATABASE) failed for $(basename "$local_original_file")" >&2
                    rm -f /tmp/mysql.cnf
                    [[ -n "$temp_unzip_dir" ]] && rm -rf "$temp_unzip_dir"
                    return 1
                }

                # Second pass: Remove USE statements (case-insensitive without 'I' flag)
                sed -E '/^[[:space:]]*[Uu][Ss][Ee][^;]*;[[:space:]]*$/d' "$temp_intermediate_file" > "$local_cleaned_file_to_remove" || {
                    echo "Error: Second SED pass (USE) failed for $(basename "$local_original_file")" >&2
                    rm -f /tmp/mysql.cnf
                    [[ -n "$temp_unzip_dir" ]] && rm -rf "$temp_unzip_dir"
                    return 1
                }

                # Clean up the intermediate temporary file
                rm "$temp_intermediate_file"

                container_src_file="/tmp/$(basename "$local_cleaned_file_to_remove")"
                debug "Copying cleaned SQL file '$local_cleaned_file_to_remove' to container at '$container_src_file'"
                docker cp "$local_cleaned_file_to_remove" "$MYSQL_CONTAINER_NAME:$container_src_file" || {
                    echo "Error copying cleaned SQL file." >&2
                    rm -f /tmp/mysql.cnf
                    [[ -n "$temp_unzip_dir" ]] && rm -rf "$temp_unzip_dir"
                    return 1
                }
                # echo "--- SCRIPT HALTED FOR SED OUTPUT VERIFICATION ---"
                # echo "Please run the following commands in a NEW terminal tab:"
                # echo "1. docker exec -it $MYSQL_CONTAINER_NAME bash"
                # echo "2. Inside container: head -n 200 $container_src_file | grep -i 'CREATE DATABASE'"
                # echo "3. Inside container: head -n 200 $container_src_file | grep -i 'USE'"
                # echo "4. Inside container: grep -i 'CREATE TABLE.*Company' $container_src_file"
                # echo "5. Inside container: grep -i 'INSERT INTO.*Company' $container_src_file"
                # echo "--- IMPORTANT: Is the Company table definition/insert present? Are CREATE/USE statements GONE? ---"
                # echo "--- After inspection, remove the 'exit 0' line from the script to continue. ---"
                # exit 0 # <--- TEMPORARY LINE TO HALT SCRIPT
            fi

            local import_output
            local mysql_import_cmd="$mysql_exec_cmd --force --max-allowed-packet=943718400 \"$TARGET_DB\""

            echo "Importing $(basename "$container_src_file") into $TARGET_DB (forcing into this DB)..."
            if [[ "$CHOICE" != "2" && "$CHOICE" != "7" ]]; then
              # This uses the $container_src_file, whether it was copied or originally in container
              if command -v pv >/dev/null; then
                  local file_size=$(docker exec "$MYSQL_CONTAINER_NAME" stat -c %s "$container_src_file" 2>/dev/null || docker exec "$MYSQL_CONTAINER_NAME" stat -f %z "$container_src_file" 2>/dev/null)
                  debug "File size: ${file_size:-unknown}"

                  if [[ -n "$file_size" ]]; then
                      import_output=$(docker exec -i "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$container_src_file' | pv -s \"$file_size\"" | docker exec -i "$MYSQL_CONTAINER_NAME" bash -c "cat - | $mysql_import_cmd" 2>&1)
                  else
                      import_output=$(docker exec -i "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$container_src_file' | pv" | docker exec -i "$MYSQL_CONTAINER_NAME" bash -c "cat - | $mysql_import_cmd" 2>&1)
                  fi
              else
                  import_output=$(docker exec -i "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$container_src_file'" | docker exec -i "$MYSQL_CONTAINER_NAME" bash -c "cat - | $mysql_import_cmd" 2>&1)
              fi

              if [[ $? -ne 0 ]]; then
                  echo "Import of $(basename "$current_sql_file_path") failed: $import_output" >&2
                  rm -f /tmp/mysql.cnf
                  [[ -n "$temp_unzip_dir" ]] && rm -rf "$temp_unzip_dir"
                  return 1
              fi
            fi
            echo "Successfully imported $(basename "$current_sql_file_path") into '$TARGET_DB'"

            # --- MODIFIED CLEANUP ---
            # Clean up the copied file in the container if it was a local file (not for DXP Cloud original files)
            # And clean up the local cleaned file on the host.
            if [[ "$IS_DXP_CLOUD" != "true" ]]; then
                docker exec "$MYSQL_CONTAINER_NAME" rm "$container_src_file" || debug "Failed to remove $container_src_file from container."
                rm "$local_cleaned_file_to_remove" || debug "Failed to remove $local_cleaned_file_to_remove from local."
            fi
            # --- END MODIFIED CLEANUP ---
        done # End of for current_sql_file_path loop
    fi # End of if/else for skipping import based on DXP Cloud populated check

    # --- FINAL CLEANUP (outside the loop, applies after all imports are done) ---
    rm -f /tmp/mysql.cnf # MySQL config file
    [[ -n "$temp_unzip_dir" ]] && rm -rf "$temp_unzip_dir" # Temporary unzipped directory on host

    echo "MySQL database '$TARGET_DB' imported successfully!"

  echo "Starting Tomcat setup..."

  local TOMCAT_ARCHIVE_PATH TOMCAT_ARCHIVE TOMCAT_VERSION
  local LIFERAY_DIR="liferay-dxp"
  while true; do
    read -rp "Enter the path to your Tomcat bundle directory (or press Enter to search for a Liferay Tomcat archive in the current folder): " TOMCAT_ARCHIVE_PATH

    if [[ -z "$TOMCAT_ARCHIVE_PATH" ]]; then
      TOMCAT_ARCHIVE_PATH="./"
      TOMCAT_ARCHIVE=$(find "$TOMCAT_ARCHIVE_PATH" -maxdepth 1 \( \
        -name "liferay-dxp-tomcat-7.4.13-u*.zip" \
        -o -name "liferay-dxp-tomcat-7.4.13-u*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2024.*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2024.*.zip" \
        -o -name "liferay-dxp-tomcat-2025.*.tar.gz" \
        -o -name "liferay-dxp-tomcat-2025.*.zip" \
        -o -name "liferay-fixed.zip" \) -print | head -n 1)

      if [[ -z "$TOMCAT_ARCHIVE" ]]; then
        echo "No Liferay Tomcat archive found in the current directory." >&2
        continue
      fi
      break
    elif [[ -f "$TOMCAT_ARCHIVE_PATH" ]]; then
      TOMCAT_ARCHIVE="$TOMCAT_ARCHIVE_PATH"
      break
    elif [[ -d "$TOMCAT_ARCHIVE_PATH" ]]; then
      echo "Error: '$TOMCAT_ARCHIVE_PATH' is a directory. Please provide a Tomcat archive file." >&2
      continue
    else
      echo "Invalid path. Please enter a valid Tomcat archive file or press Enter." >&2
      continue
    fi
  done

  local TOMCAT_VERSION=$(basename "$TOMCAT_ARCHIVE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
  echo "Using Tomcat version: $TOMCAT_VERSION"

  echo "Navigating to $(pwd)..."
  cd "$(pwd)" || { echo "Error: Failed to navigate to current directory." >&2; return 1; }

  if [[ -d "$LIFERAY_DIR" ]]; then
    echo "Deleting existing '$LIFERAY_DIR' folder..."
    rm -rf "$LIFERAY_DIR" || { echo "Error: Failed to delete '$LIFERAY_DIR'." >&2; return 1; }
  fi

  echo "Unzipping '$TOMCAT_ARCHIVE'..."
  if [[ "$TOMCAT_ARCHIVE" == *.zip ]]; then
    unzip -o "$TOMCAT_ARCHIVE" -d . || { echo "Error: Failed to unzip '$TOMCAT_ARCHIVE'." >&2; return 1; }
  elif [[ "$TOMCAT_ARCHIVE" == *.tar.gz ]]; then
    tar -xzf "$TOMCAT_ARCHIVE" -C . || { echo "Error: Failed to extract '$TOMCAT_ARCHIVE'." >&2; return 1; }
  else
    echo "Error: Unsupported archive format for '$TOMCAT_ARCHIVE'." >&2
    return 1
  fi
  if [[ ! -d "$LIFERAY_DIR" ]]; then
    echo "Error: Unzipped archive did not create '$LIFERAY_DIR' folder." >&2
    return 1
  fi

  echo "Creating portal-ext.properties..."
  local properties_file="$LIFERAY_DIR/portal-ext.properties"
  cat > "$properties_file" <<EOF || { echo "Error: Failed to create '$properties_file'." >&2; return 1; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/$TARGET_DB?useUnicode=true&characterEncoding=UTF-8
jdbc.default.username=root
jdbc.default.password=
upgrade.database.dl.storage.check.disabled=true
EOF
  if [[ "$IS_DXP_CLOUD" == "true" ]]; then
    cat >> "$properties_file" <<EOF || { echo "Error: Failed to append DXP Cloud properties to '$properties_file'." >&2; return 1; }
company.default.web.id=admin-$MODL_CODE.lxc.liferay.com
database.partition.enabled=true
EOF
  fi
if [[ "$MODL_CODE" == "e5a2" ]]; then
    cat >> "$properties_file" <<EOF || { echo "Error: Failed to append DXP Cloud properties to '$properties_file'." >&2; return 1; }
company.default.web.id=admin-e5a2.lxc.liferay.com
database.partition.enabled=true
EOF
  fi
  chmod 600 "$properties_file" || { echo "Error: Failed to set permissions on '$properties_file'." >&2; return 1; }
  debug "portal-ext.properties contents:"
  cat "$properties_file" >&2
  echo "portal-ext.properties updated successfully."

  # Check for database upgrade tool
  local upgrade_tool_dir="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
  if [[ -d "$upgrade_tool_dir" ]]; then
    echo "Creating portal-upgrade-database.properties..."
    local upgrade_properties_file="$upgrade_tool_dir/portal-upgrade-database.properties"
    cat > "$upgrade_properties_file" <<EOF || { echo "Error: Failed to create '$upgrade_properties_file'." >&2; return 2; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/lportal?${characterEncoding=UTF-8}&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&${serverTimezone=GMT}&useFastDateParsing=${false}&useUnicode=${true}
jdbc.default.username=root
jdbc.default.password=
#liferay.home=${LIFERAY_DIR}
upgrade.database.dl.storage.check.disabled=true

jdbc.lpartition_11162231691175.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11162231691175.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11162231691175.username=root
jdbc.lpartition_11162231691175.password=

jdbc.lpartition_11706165.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11706165.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11706165.username=root
jdbc.lpartition_11706165.password=

jdbc.lpartition_11711847.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11711847.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11711847.username=root
jdbc.lpartition_11711847.password=

jdbc.lpartition_11726111.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11726111.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11726111.username=root
jdbc.lpartition_11726111.password=

jdbc.lpartition_11816620.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11816620.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11816620.username=root
jdbc.lpartition_11816620.password=

jdbc.lpartition_11819872.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11819872.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11819872.username=root
jdbc.lpartition_11819872.password=

jdbc.lpartition_11822045.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11822045.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11822045.username=root
jdbc.lpartition_11822045.password=

jdbc.lpartition_11940122.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_11940122.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_11940122.username=root
jdbc.lpartition_11940122.password=

jdbc.lpartition_13982314.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_13982314.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_13982314.username=root
jdbc.lpartition_13982314.password=

jdbc.lpartition_16684433639393.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_16684433639393.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_16684433639393.username=root
jdbc.lpartition_16684433639393.password=

jdbc.lpartition_17855804202317.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_17855804202317.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_17855804202317.username=root
jdbc.lpartition_17855804202317.password=

jdbc.lpartition_1860468.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_1860468.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_1860468.username=root
jdbc.lpartition_1860468.password=

jdbc.lpartition_18804743.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_18804743.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_18804743.username=root
jdbc.lpartition_18804743.password=

jdbc.lpartition_18807698.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_18807698.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_18807698.username=root
jdbc.lpartition_18807698.password=

jdbc.lpartition_1996101.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_1996101.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_1996101.username=root
jdbc.lpartition_1996101.password=

jdbc.lpartition_26053188.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_26053188.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_26053188.username=root
jdbc.lpartition_26053188.password=

jdbc.lpartition_45286218349995.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_45286218349995.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_45286218349995.username=root
jdbc.lpartition_45286218349995.password=

jdbc.lpartition_57868206215768.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_57868206215768.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_57868206215768.username=root
jdbc.lpartition_57868206215768.password=

jdbc.lpartition_66138412237889.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_66138412237889.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_66138412237889.username=root
jdbc.lpartition_66138412237889.password=

jdbc.lpartition_83909668433076.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_83909668433076.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_83909668433076.username=root
jdbc.lpartition_83909668433076.password=

jdbc.lpartition_9184961.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.lpartition_9184961.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
jdbc.lpartition_9184961.username=root
jdbc.lpartition_9184961.password=
EOF
      # Enable multi-tenancy upgrade
    if [[ "$MODL_CODE" == "e5a2" ]]; then
      echo "database.partition.enabled=true" >> "$upgrade_properties_file"
      # Add partition schemas if multiple exist
      if [[ "${#partitions[@]}" -gt 1 ]]; then
        echo "database.partition.schemas=${partitions[*]}" >> "$upgrade_properties_file"
      fi
    fi
    chmod 644 "$upgrade_properties_file" || { echo "Error: Failed to set permissions on '$upgrade_properties_file'." >&2; return 644; }
    echo "Successfully updated portal-upgrade-database.properties."

    if [[ -f "$upgrade_tool_dir/db_upgrade_client.sh" ]]; then
      echo "Running database upgrade script for all partitions..."
      cd "$upgrade_tool_dir" || { echo "Error: Failed to navigate to '$upgrade_tool_dir'." >&2; return 1; }
      # Try single-run upgrade with all partitions
      ./db_upgrade_client.sh -j "-Dfile.encoding=UTF-8 -Duser.timezone=GMT -Xmx4096m" || {
        echo "Warning: Single-run database upgrade failed. Attempting individual partition upgrades..." >&2
        # Fallback: Upgrade each partition individually
        for partition in "${partitions[@]}"; do
          echo "Upgrading partition: $partition"
          # Create temporary properties file for this partition
          local temp_properties_file="$upgrade_tool_dir/portal-upgrade-database-$partition.properties"
          cat > "$temp_properties_file" <<EOF || { echo "Error: Failed to create '$temp_properties_file'." >&2; return 2; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/${partition}?characterEncoding=UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose}&serverTimezone=GMT&useFastDateParsing=false&useUnicode=true}
jdbc.default.username=root
jdbc.default.password=
liferay.home=${LIFERAY_DIR}
database.partition.enabled=true
upgrade.database.dl.storage.check.disabled=true
EOF
          chmod 644 "$temp_properties_file" || { echo "Error: chmod on '$temp_properties_file'." >&2; return 644; }
          ./db_upgrade_client.sh -j "-Dfile.encoding=UTF-8 -Duser.timezone=GMT -Xmx4096m}" -p "$temp_properties_file" || {
            echo "Error: Database upgrade for partition '$partition' failed." >&2
            rm -f "$temp_properties_file"
            cd - >/dev/null
            return 1
          }
          rm -f "$temp_properties_file"
          echo "Successfully upgraded partition: $partition'"
        done
      }
      cd - >/dev/null
    else
      echo "Warning: 'db_upgrade_client.sh' not found in '$upgrade_tool_dir'. Skipping database upgrade."
    fi
  else
    echo "Warning: Directory '$upgrade_tool_dir' not found. Skipping database upgrade."
  fi

  echo "Script execution completed with database: $TARGET_DB"
  return 0
}

stop_drop_mysql_db(){
  echo "Stopping mysql_db container"
  docker stop mysql_db

  echo "Removing mysql_db container"
  docker rm mysql_db
}

import_sqlserver_rsync() {
  echo "Importing SQL Server database..."

  databases=(
    "Brinks --> 24Q3_Brinks_database_dump.bak"
    "Kubota --> 24Q1_Kubota_database_dump.bak"
    "Zain --> 23Q4_Zain_database_dump.bak"
  )

  echo "Choose a database to import:"
  for i in "${!databases[@]}"; do
    echo "$((i + 1)). ${databases[$i]}"
  done

  echo "4. Other"

  while true; do
    read -rp "Enter your choice: " choice
    if [[ "$choice" =~ ^[1-4]$ ]]; then
      break
    else
      echo "Invalid choice. Please enter a number between 1 and 4."
    fi
  done

  if [[ "$choice" == "4" ]]; then
    read -rp "Enter the path to your SQL Server dump file: " DUMP_FILE
    DB_NAME="Custom"
  else
    DB_NAME="${databases[$((choice - 1))]%% --> *}"
    DUMP_FILE="${databases[$((choice - 1))]##*--> }"
  fi

  if [[ -z "$DUMP_FILE" ]]; then
    echo "No dump file specified. Skipping import."
    exit 1
  fi

  # Ensure DUMP_FILE is a full path for predefined databases
  if [[ "$choice" != "4" ]]; then
    DUMP_FILE="/home/me/Documents/db_upgrades/bak_files/$DUMP_FILE"
  fi

  if [[ ! -f "$DUMP_FILE" ]]; then
    echo "Dump file '$DUMP_FILE' not found. Skipping import."
    exit 1
  fi

  # Copy dump file to temporary directory with rsync progress
  filename=$(basename "$DUMP_FILE")
  temp_file="/tmp/$filename"
  echo "Copying $DUMP_FILE to temporary directory..."
  rsync --progress "$DUMP_FILE" "$temp_file"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to copy $DUMP_FILE to $temp_file."
    exit 1
  fi

  # Create backup directory in container
  docker exec -it sqlserver_db mkdir -p /var/opt/mssql/backup

  # Copy dump file to container
  echo "Copying $filename to SQL Server container..."
  if ! docker cp "$temp_file" sqlserver_db:/var/opt/mssql/backup; then
    echo "Error copying dump file to container. Check Docker and file permissions."
    exit 1
  fi

  echo "Dump file copied to SQL Server container."

  echo "Waiting for SQL Server to be ready..."
  for i in {1..30}; do
    docker exec sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT 1" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "SQL Server is ready!"
      break
    fi
    echo "Waiting for SQL Server... ($i/30)"
    sleep 2
  done

  echo "The file name is: $filename"

  file_list=$(docker exec -it sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "RESTORE FILELISTONLY FROM DISK = '/var/opt/mssql/backup/$filename'" 2>&1)
  if echo "$file_list" | grep -q "Msg [0-9]\+,"; then
    echo "Error listing files in backup. Check SQL Server logs in the container."
    docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
    exit 1
  fi

  echo "Files in backup directory:"
  echo "$file_list" | tr -s ' ' | cut -d ' ' -f 1-2

  if [[ "$choice" == "1" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/$filename' WITH MOVE 'cportal_72' TO '/var/opt/mssql/data/cportal_72.mdf', MOVE 'cportal_72_log' TO '/var/opt/mssql/data/cportal_72_log.ldf', STATS=10\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "2" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/$filename' WITH MOVE 'liferay' TO '/var/opt/mssql/data/liferay.mdf', MOVE 'liferay_log' TO '/var/opt/mssql/data/liferay_log.ldf', STATS=10\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "3" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/$filename' WITH MOVE 'zainCommerce212' TO '/var/opt/mssql/data/zainCommerce212.mdf', MOVE 'zainCommerce212_log' TO '/var/opt/mssql/data/zainCommerce212_log.ldf', STATS=10\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "4" ]]; then
    readarray -t logical_names < <(echo "$file_list" | awk '{print $1}' | tail -n +2 | head -n -2)
    move_clauses=""
    for logical_name in "${logical_names[@]}"; do
      if [[ "$logical_name" == *_log ]]; then
        continue
      fi
      data_file="/var/opt/mssql/data/${logical_name}.mdf"
      log_file="/var/opt/mssql/data/${logical_name}_log.ldf"
      move_clauses+="MOVE '${logical_name}' TO '${data_file}', MOVE '${logical_name}_log' TO '${log_file}', "
    done
    move_clauses="${move_clauses%, }"
    restore_command="RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/$filename' WITH $move_clauses, STATS=10"
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"$restore_command\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  fi

  echo "Checking SQL Server container status..."
  if docker exec -it sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT 1" 2>/dev/null; then
    echo "SQL Server container is running and accessible."
  else
    echo "Error: SQL Server container is not accessible. Please ensure the container is running and the database is available."
    exit 1
  fi

  echo "Verifying database restore..."
  docker exec -it sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT name FROM sys.databases WHERE name = 'lportal'" | grep lportal
  if [ $? -eq 0 ]; then
    echo "Database 'lportal' restored successfully!"
  else
    echo "Database 'lportal' not found. Restore failed."
    docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
    exit 1
  fi
}

create_alter_tables(){
  local MYSQL_CONTAINER_NAME="mysql_db"
  local TARGET_DB="$1"
  local INPUT_FILE="$2"
  local DEBUG=${DEBUG:-false}

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  [[ -z "$TARGET_DB" ]] && { echo "Error: Target database not specified." >&2; return 1; }
  [[ -z "$INPUT_FILE" ]] && { echo "Error: Input file not specified." >&2; return 1; }
  [[ ! -f "$INPUT_FILE" ]] && { echo "Error: Input file '$INPUT_FILE' does not exist." >&2; return 1; }
  [[ -z "$MYSQL_CONTAINER_NAME" ]] && { echo "Error: MYSQL_CONTAINER_NAME is unset." >&2; return 1; }

  if ! docker ps --filter "name=^${MYSQL_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER_NAME}$"; then
    echo "Error: MySQL container '$MYSQL_CONTAINER_NAME' is not running." >&2
    return 1
  fi
    echo "Generating ALTER TABLE statements and executing them..."
  mysql -u root -p -D $TARGET_DB -NBe "
SELECT CONCAT(
    'ALTER TABLE \`', TABLE_SCHEMA, '\`.\`', TABLE_NAME, '\` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;'
)
FROM information_schema.tables
WHERE TABLE_SCHEMA='lportal'
  AND (TABLE_COLLATION <> 'utf8mb4_unicode_ci' OR TABLE_COLLATION IS NULL);
" | mysql -u root -p -D $TARGET_DB # Pipe the generated SQL back into mysql for execution
  echo "Character set alteration process complete (check MySQL logs for details)."
}

create_alter_tables_original_script(){
  mysql -u root -p -D lportal -NBe "
SELECT CONCAT(
    'SELECT ''INFO: Altering table \`', TABLE_SCHEMA, '\`.\`', TABLE_NAME, '\`...'';',
    'ALTER TABLE \`', TABLE_SCHEMA, '\`.\`', TABLE_NAME, '\` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;',
    'SELECT ''INFO: Successfully altered \`', TABLE_SCHEMA, '\`.\`', TABLE_NAME, '\`.'';'
)
FROM information_schema.tables
WHERE TABLE_SCHEMA='lportal'
  AND (TABLE_COLLATION <> 'utf8mb4_unicode_ci' OR TABLE_COLLATION IS NULL);
" > alter_all_tables.sql
}

echo "Choose a database to set up and import:"
echo "1. SQL Server"
echo "2. MySQL"
echo "3. Oracle 19"
echo "4. PostgreSQL"
echo "5. Export e5a2 dump"
echo "6. Import e5a2 dump"
echo "7. Import e5a2 from backup"
echo "8. Create ALTER TABLES"
echo "9. Stop and drop mysql_db container"
read -p "Enter your choice (1/2/3/4/5/6/7): " CHOICE

case $CHOICE in
  1)
    run_sqlserver
    import_sqlserver
    #import_sqlserver_rsync
    upgrade_sqlserver_with_local_tomcat
    ;;
  2)
    setup_and_import_mysql
    ;;
  3)
    run_oracle
    import_oracle
    ;;
  4)
    run_postgresql
    import_postgresql
    upgrade_postgresql_with_local_tomcat
    ;;
  5)
    export_mysql_dump "e5a2" "e5a2_backup.sql"
    ;;
  6)
    import_mysql_dump "lportal" "cleaned_with_use.sql"
    ;;
  7)
    import_mysql_dump "e5a2" "e5a2_backup.sql"
    ;;
  8)
    create_alter_tables "tudelft_db" "24Q1_TUDelft_database_dump.sql"
    ;;
  9)
    stop_drop_mysql_db
    ;;
  *)
    echo "Invalid choice. Exiting."
    ;;
esac
