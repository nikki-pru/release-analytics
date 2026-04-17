#!/bin/bash

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
    size=$(docker exec "$MYSQL_CONTAINER_NAME" mysql --defaults-file=/tmp/mysql.cnf -N -e "SELECT SUM(data_length + index_length) FROM information_schema.tables WHERE table_schema='$TARGET_DB';")
    docker exec "$MYSQL_CONTAINER_NAME" /usr/bin/mysqldump --defaults-file=/tmp/mysql.cnf --quick --single-transaction "$TARGET_DB" | pv -s "$size" > "$OUTPUT_FILE" || {
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

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  [[ -z "$TARGET_DB" ]] && { echo "Error: Target database not specified." >&2; return 1; }
  [[ -z "$INPUT_FILE" ]] && { echo "Error: Input file not specified." >&2; return 1; }
  [[ ! -f "$INPUT_FILE" ]] && { echo "Error: Input file '$INPUT_FILE' does not exist." >&2; return 1; }
  [[ -z "$MYSQL_CONTAINER_NAME" ]] && { echo "Error: MYSQL_CONTAINER_NAME is unset." >&2; return 1; }

  if ! docker ps --filter "name=^${MYSQL_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER_NAME}$"; then
    echo "Error: MySQL container '$MYSQL_CONTAINER_NAME' is not running." >&2
    return 1
  fi

  if ! docker exec "$MYSQL_CONTAINER_NAME" test -f /tmp/mysql.cnf; then
    echo "Creating /tmp/mysql.cnf in container..." >&2
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

  echo "Ensuring database '$TARGET_DB' exists..."
  docker exec "$MYSQL_CONTAINER_NAME" mysql --defaults-file=/tmp/mysql.cnf --protocol=TCP -e "DROP DATABASE IF EXISTS \`$TARGET_DB\`; CREATE DATABASE \`$TARGET_DB\`;" || {
    echo "Error creating database '$TARGET_DB'." >&2
    return 1
  }

  echo "Importing '$INPUT_FILE' into '$TARGET_DB'..."
  local import_output
  if command -v pv >/dev/null; then
    local file_size=$(stat -c %s "$INPUT_FILE" 2>/dev/null || stat -f %z "$INPUT_FILE" 2>/dev/null)
    if [[ -n "$file_size" ]]; then
      if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
      else
        import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
      fi
    else
      if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
      else
        import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
      fi
    fi
  else
    echo "Warning: pv not installed. Proceeding without progress bar." >&2
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
      import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
    else
      import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
    fi
  fi
  [[ $? -ne 0 ]] && { echo "Import failed: $import_output" >&2; return 1; }

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
  local main_choice=$1

  if [[ -z "$main_choice" ]]; then
    echo "Error: Main menu choice not provided. Exiting."
    exit 1
  fi

  echo "Choose a database to import:"
  echo "1. Ovam --> ovam-liferay74.sql"
  echo "2. Church Mutual --> church_postgresql_20241220.sql"
  echo "3. Other"
  read -p "Enter your choice: " import_choice
  case $import_choice in
    1)
      dump_file="ovam-liferay74.sql"
      ;;
    2)
      dump_file="church_postgresql_20241220.sql"
      ;;
    3)
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

  PORT_PREFIX="2$import_choice"
  echo "Using port prefix: $PORT_PREFIX"

  run_postgresql_with_local_tomcat "$main_choice" "$db_choice" "$PORT_PREFIX"
}

import_sqlserver() {
  local main_choice=$1

  if [[ -z "$main_choice" ]]; then
    echo "Error: Main menu choice not provided. Exiting."
    exit 1
  fi

  echo "Importing SQL Server database..."

  databases=(
    "Brinks --> brinks_dmp_7.4.bak"
    "Kubota --> stg-kpp-2024-08-06.bak"
    "Zain --> dxp72212_Kartik.bak"
  )

  echo "Choose a database to import:"
  for i in "${!databases[@]}"; do
    echo "$((i + 1)). ${databases[$i]}"
  done

  echo "4. Other"

  while true; do
    read -rp "Enter your choice: " db_choice
    if [[ "$db_choice" =~ ^[1-4]$ ]]; then
      break
    else
      echo "Invalid choice. Please enter a number between 1 and 4."
    fi
  done

  PORT_PREFIX="1$db_choice"
  echo "Using port prefix: $PORT_PREFIX"

  if [[ "$choice" == "4" ]]; then
    read -rp "Enter the path to your SQL Server dump file: " DUMP_FILE
    DB_NAME="Custom"
  else
    DB_NAME="${databases[$((db_choice - 1))]%% --> *}"
    DUMP_FILE="${databases[$((db_choice - 1))]##*--> }"
  fi

  echo "Importing $DB_NAME from $DUMP_FILE..."

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
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/brinks_dmp_7.4.bak' WITH MOVE 'cportal_72' TO '/var/opt/mssql/data/cportal_72.mdf', MOVE 'cportal_72_log' TO '/var/opt/mssql/data/cportal_72_log.ldf'\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "2" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/stg-kpp-2024-08-06.bak' WITH MOVE 'liferay' TO '/var/opt/mssql/data/liferay.mdf', MOVE 'liferay_log' TO '/var/opt/mssql/data/liferay_log.ldf'\" 2>&1; echo -n \$?")
    restore_exit_code=$(echo "$restore_output" | tail -n 1)
    echo "$restore_output"
    if [ "$restore_exit_code" -ne 0 ]; then
      echo "Database restore failed. Check SQL Server logs for details:"
      docker exec -it sqlserver_db cat /var/opt/mssql/log/errorlog
      exit 1
    fi
  elif [[ "$choice" == "3" ]]; then
    restore_output=$(docker exec -i sqlserver_db bash -c "cd /opt/mssql-tools18/bin && ./sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q \"RESTORE DATABASE lportal FROM DISK = '/var/opt/mssql/backup/dxp72212_Kartik.bak' WITH MOVE 'zainCommerce212' TO '/var/opt/mssql/data/zainCommerce212.mdf', MOVE 'zainCommerce212_log' TO '/var/opt/mssql/data/zainCommerce212_log.ldf'\" 2>&1; echo -n \$?")
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

  run_sqlserver_with_local_tomcat "$main_choice" "$db_choice"
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

run_postgresql_with_local_tomcat() {
  local TOMCAT_DIR="$1"
  local TOMCAT_ARCHIVE="$2"

  echo "Starting Tomcat setup..."

  local TOMCAT_ARCHIVE_PATH TOMCAT_VERSION
  local LIFERAY_DIR="$db_choice-liferay-dxp"
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

  echo "Setting the server.xml port..."
  local server_xml_file="$LIFERAY_DIR/tomcat/conf/server.xml"
  if [[ ! -f "$server_xml_file" ]]; then
    echo "Error: server.xml not found at '$server_xml_file'." >&2
    exit 1
  fi

  # Replace ports starting with '8' (8005, 8080, 8443) with PORT_PREFIX
  sed -i "s/port=\"8\([0-9]\{3\}\)\"/port=\"$PORT_PREFIX\1\"/g" "$server_xml_file" || {
    echo "Error: Failed to update ports in '$server_xml_file'." >&2
    exit 1
  }
  echo "Ports updated in server.sh with prefix '$PORT_PREFIX'."

  echo "Using Tomcat version: $VERSION"
  echo "Tomcat directory: $TOMCAT_DIR"

  echo "Navigating to $LIFERAY_DIR and creating portal-ext.properties..."
  cd "$LIFERAY_DIR" || { echo "Failed to enter $LIFERAY_DIR"; return 1; }

  cat > portal-ext.properties <<EOF
jdbc.default.driverClassName=org.postgresql.Driver
jdbc.default.url=jdbc:postgresql://localhost:5433/lportal
jdbc.default.username=root
jdbc.default.password=
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

run_sqlserver_with_local_tomcat() {
  local main_choice=$1
  local db_choice=$2
  local server_xml="/path/to/your/tomcat/conf/server.xml"
  local TOMCAT_DIR="$1"
  local TOMCAT_ARCHIVE="$2"
  local MSSQL_JDBC_JAR="mssql-jdbc-12.2.0.jre8.jar"

  if [[ -z "$main_choice" || -z "$db_choice" ]]; then
    echo "Error: Both main_choice and db_choice must be provided. Exiting."
    exit 1
  fi

  echo "Starting Tomcat setup..."

  local TOMCAT_ARCHIVE_PATH TOMCAT_VERSION
  local LIFERAY_DIR="$db_choice-liferay-dxp"
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

  echo "Setting the server.xml port..."
  local server_xml_file="$LIFERAY_DIR/tomcat/conf/server.xml"
  if [[ ! -f "$server_xml_file" ]]; then
    echo "Error: server.xml not found at '$server_xml_file'." >&2
    exit 1
  fi

  # Replace ports starting with '8' (8005, 8080, 8443) with PORT_PREFIX
  sed -i "s/port=\"8\([0-9]\{3\}\)\"/port=\"$PORT_PREFIX\1\"/g" "$server_xml_file" || {
    echo "Error: Failed to update ports in '$server_xml_file'." >&2
    exit 1
  }
  echo "Ports updated in server.sh with prefix '$PORT_PREFIX'."

  echo "Using Tomcat version: $VERSION"
  echo "Tomcat directory: $TOMCAT_DIR"

  echo "Navigating to $LIFERAY_DIR and creating portal-ext.properties..."
  cd "$LIFERAY_DIR" || { echo "Failed to enter $LIFERAY_DIR"; return 1; }

  cat > portal-ext.properties <<EOF
jdbc.default.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
jdbc.default.url=jdbc:sqlserver://localhost:1433;databaseName=lportal;trustServerCertificate=true;
jdbc.default.username=sa
jdbc.default.password=R00t@1234
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
  local TARGET_DB ZIP_FILE SQL_FILE temp_dir
  local DEBUG=${DEBUG:-false}
  local MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-""}
  local MYSQL_ALLOW_EMPTY
  local DOCKER_IMAGE="mysql:8.0"  # Default image
  local IS_DXP_CLOUD=false      # Flag for DXP Cloud path

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  echo 'Choose a database to import:'
  echo '1) Actinver'
  echo '2) APCOA'
  echo '3) Argus'
  echo '4) CNO Bizlink'
  echo '5) Metos'
  echo '6) TUDelft'
  echo '7) Other (custom path)'
  echo '8) Liferay DXP Cloud'
  read -rp 'Enter your choice: ' CHOICE

  case "$CHOICE" in
    1) TARGET_DB="actinver_db"; ZIP_FILE="24Q1_Actinver_database_dump.zip" ;;
    2) TARGET_DB="apcoa_db"; ZIP_FILE="24Q2_APCOA_database_dump.sql" ;;
    3) TARGET_DB="argus_db"; ZIP_FILE="24Q2_Argus_database_dump.sql" ;;
    4) TARGET_DB="cno_bizlink_db"; ZIP_FILE="24Q1_CNOBizlink_database_dump.sql" ;;
    5) TARGET_DB="metos_db"; ZIP_FILE="24Q3_Metos_database_dump.zip" ;;
    6) TARGET_DB="tudelft_db"; ZIP_FILE="24Q1_TUDelft_database_dump.sql" ;;
    7) read -rp "Enter the path to your custom dump zip: " ZIP_FILE
       read -rp "Enter your target database name: " TARGET_DB ;;
    8)
      TARGET_DB="lportal"
      read -rp "Enter the LPD ticket number (e.g., LPD-52788): " LPD_TICKET
      read -rp "Enter the MODL code (e.g., r8k1): " MODL_CODE
      # Validate inputs
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

  PORT_PREFIX="2$CHOICE"
  echo "Using port prefix: $PORT_PREFIX"

  debug "You selected: $TARGET_DB with dump file: $ZIP_FILE"
  echo '📦 Importing MySQL database...' >&2
  echo "Target database is: $TARGET_DB" >&2

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
    echo "Creating and starting MySQL container '$MYSQL_CONTAINER_NAME'..."
    if [[ "$MYSQL_ALLOW_EMPTY" == "yes" ]]; then
      docker_run_cmd="docker run -d \
        --name \"$MYSQL_CONTAINER_NAME\" \
        -e MYSQL_ROOT_PASSWORD=\"$MYSQL_ROOT_PASSWORD\" \
        -e MYSQL_DATABASE=\"$TARGET_DB\" \
        -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
        -p 3306:3306 \
        --network \"$NETWORK_NAME\" \
        --memory=8g \
        --cpus=2 \
        $DOCKER_IMAGE \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci \
        --default-time-zone='GMT' \
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
        --name \"$MYSQL_CONTAINER_NAME\" \
        -e MYSQL_ROOT_PASSWORD=\"$MYSQL_ROOT_PASSWORD\" \
        -e MYSQL_DATABASE=\"$TARGET_DB\" \
        -p 3306:3306 \
        --network \"$NETWORK_NAME\" \
        --memory=8g \
        --cpus=2 \
        $DOCKER_IMAGE \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci \
        --default-time-zone='GMT' \
        --innodb_buffer_pool_size=4G \
        --max-allowed-packet=943718400 \
        --wait-timeout=6000 \
        --innodb_log_file_size=512M \
        --innodb_flush_log_at_trx_commit=2 \
        --innodb_io_capacity=2000 \
        --innodb_write_io_threads=8 \
        --sync_binlog=0"
    fi
    if [[ "$IS_DXP_CLOUD" == "true" ]]; then
      docker_run_cmd=$(echo "$docker_run_cmd" | sed 's/ --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci//')
    else
      docker_run_cmd="$docker_run_cmd \
        --default-time-zone='GMT' \
        --innodb_buffer_pool_size=4G \
        --max-allowed-packet=943718400 \
        --wait-timeout=6000 \
        --innodb_log_file_size=512M \
        --innodb_flush_log_at_trx_commit=2 \
        --innodb_io_capacity=2000 \
        --innodb_write_io_threads=8 \
        --sync_binlog=0"
    fi
    debug "Docker run command: $docker_run_cmd"
    eval "$docker_run_cmd" || { echo "Error creating container." >&2; return 1; }
  fi

  debug "Creating MySQL config file at /tmp/mysql.cnf"
  cat > /tmp/mysql.cnf <<'EOF' || { echo "Error: Failed to create /tmp/mysql.cnf" >&2; return 1; }
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
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
      ping_output=$(docker exec "$MYSQL_CONTAINER_NAME" mysqladmin ping -u root --host=127.0.0.1 --port=3306 --silent 2>&1)
      if [[ $? -eq 0 ]]; then
        echo "MySQL is ready."
        break
      else
        debug "mysqladmin ping failed: $ping_output"
      fi
    else
      ping_output=$(docker exec "$MYSQL_CONTAINER_NAME" mysqladmin ping -u root -p"$MYSQL_ROOT_PASSWORD" --host=127.0.0.1 --port=3306 --silent 2>&1)
      if [[ $? -eq 0 ]]; then
        echo "MySQL is ready."
        break
      else
        debug "mysqladmin ping failed: $ping_output"
      fi
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

  if [[ "$IS_DXP_CLOUD" == "true" ]]; then
    echo "Executing DXP Cloud specific setup..."
    # Search for SQL files in common directories
    echo "Searching for SQL files in container..."
    local sql_files
    sql_files=$(docker exec "$MYSQL_CONTAINER_NAME" find /docker-entrypoint-initdb.d /tmp / -maxdepth 3 -name "*.sql" -type f 2>/dev/null)
    if [[ -z "$sql_files" ]]; then
      echo "Error: No SQL files found in container. Please inspect the container manually to locate the file:" >&2
      echo "  Run: docker exec -it $MYSQL_CONTAINER_NAME sh" >&2
      echo "  Then use: find / -name '*.sql' to locate the file." >&2
      rm -f /tmp/mysql.cnf
      return 1
    fi
    # Convert to array and count files
    readarray -t sql_file_array <<<"$sql_files"
    local file_count=${#sql_file_array[@]}
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
    ZIP_FILE=$(basename "$CONTAINER_SQL_PATH")

    # Check if lportal database is already populated
    echo "Checking if database '$TARGET_DB' is already populated..."
    local table_count
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
      table_count=$(docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TARGET_DB';" | grep -Eo '[0-9]+' | head -n 1)
    else
      table_count=$(docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TARGET_DB';" | grep -Eo '[0-9]+' | head -n 1)
    fi
    if [[ -n "$table_count" && "$table_count" -gt 0 ]]; then
      echo "Database '$TARGET_DB' already contains $table_count tables. Skipping SQL import."
      SQL_FILE="$CONTAINER_SQL_PATH"
      CONTAINER_SQL_FILE="$SQL_FILE"
    else
      echo "Database '$TARGET_DB' is empty. Proceeding with SQL import."
    fi

    # Check if dxpcloud user exists
    echo "Checking for existing 'dxpcloud' user..."
    local user_exists
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
      user_exists=$(docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user='dxpcloud' AND host='%');" | grep -Eo '[0-1]' | tail -n 1)
    else
      user_exists=$(docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user='dxpcloud' AND host='%');" | grep -Eo '[0-1]' | tail -n 1)
    fi
    if [[ "$user_exists" -eq 1 ]]; then
      echo "'dxpcloud' user already exists. Updating privileges..."
    else
      echo "Creating 'dxpcloud' user..."
      if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -e "CREATE USER 'dxpcloud'@'%' IDENTIFIED BY '';" || {
          echo "Error creating dxpcloud user." >&2
          rm -f /tmp/mysql.cnf
          return 1
        }
      else
        docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER 'dxpcloud'@'%' IDENTIFIED BY '';" || {
          echo "Error creating dxpcloud user." >&2
          rm -f /tmp/mysql.cnf
          return 1
        }
      fi
    fi
    # Grant privileges to dxpcloud user
    echo "Granting privileges to 'dxpcloud' user..."
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
      docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'dxpcloud'@'%' WITH GRANT OPTION;" || {
        echo "Error granting privileges to dxpcloud user." >&2
        rm -f /tmp/mysql.cnf
        return 1
      }
      docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -e "FLUSH PRIVILEGES;" || {
        echo "Error flushing privileges." >&2
        rm -f /tmp/mysql.cnf
        return 1
      }
    else
      docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON *.* TO 'dxpcloud'@'%' WITH GRANT OPTION;" || {
        echo "Error granting privileges to dxpcloud user." >&2
        rm -f /tmp/mysql.cnf
        return 1
      }
      docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || {
        echo "Error flushing privileges." >&2
        rm -f /tmp/mysql.cnf
        return 1
      }
    fi
  fi

  if [[ "$ZIP_FILE" == *.zip ]]; then
    temp_dir=$(mktemp -d)
    unzip -o "$ZIP_FILE" -d "$temp_dir" || { echo "Failed to extract $ZIP_FILE" >&2; rm -f /tmp/mysql.cnf; rm -rf "$temp_dir"; return 1; }
    SQL_FILE=$(find "$temp_dir" -name "*.sql" | head -n 1)
    [[ -z "$SQL_FILE" ]] && { echo "No SQL file found in $ZIP_FILE" >&2; rm -f /tmp/mysql.cnf; rm -rf "$temp_dir"; return 1; }
  elif [[ "$ZIP_FILE" == *.sql ]]; then
    if [[ "$IS_DXP_CLOUD" == "true" ]]; then
      SQL_FILE="$CONTAINER_SQL_PATH"
    else
      SQL_FILE="$ZIP_FILE"
    fi
  else
    echo "Error: Input file must be a .zip or .sql file" >&2
    rm -f /tmp/mysql.cnf
    return 1
  fi

  debug "SQL_FILE set to: $SQL_FILE"

  echo "Ensuring database '$TARGET_DB' exists..."
  if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
    docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\`;" || {
      echo "Error creating database." >&2
      rm -f /tmp/mysql.cnf
      rm -rf "$temp_dir"
      return 1
    }
  else
    docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\`;" || {
      echo "Error creating database." >&2
      rm -f /tmp/mysql.cnf
      rm -rf "$temp_dir"
      return 1
    }
  fi

  # For DXP Cloud, set CONTAINER_SQL_FILE directly; for others, copy the file
  if [[ "$IS_DXP_CLOUD" == "true" ]]; then
    CONTAINER_SQL_FILE="$SQL_FILE"
    debug "CONTAINER_SQL_FILE set to: $CONTAINER_SQL_FILE"
    # Verify SQL file exists in container before import
    docker exec "$MYSQL_CONTAINER_NAME" test -f "$CONTAINER_SQL_FILE" || {
      echo "Error: SQL file '$CONTAINER_SQL_FILE' not found in container." >&2
      rm -f /tmp/mysql.cnf
      return 1
    }
  else
    CONTAINER_SQL_FILE="/tmp/$(basename "$SQL_FILE")"
    debug "Copying SQL file '$SQL_FILE' to container at '$CONTAINER_SQL_FILE'"
    docker cp "$SQL_FILE" "$MYSQL_CONTAINER_NAME:$CONTAINER_SQL_FILE" || {
      echo "Error copying SQL file." >&2
      rm -f /tmp/mysql.cnf
      rm -rf "$temp_dir"
      return 1
    }
  fi

  # Skip import if database is already populated (checked earlier)
  if [[ "$IS_DXP_CLOUD" == "true" && -n "$table_count" && "$table_count" -gt 0 ]]; then
    echo "Skipping SQL import as database is already populated."
  elif [[ "$CHOICE" != "2" ]]; then
    echo "Importing SQL file '$CONTAINER_SQL_FILE' into '$TARGET_DB'..."
    local import_output
    if command -v pv >/dev/null; then
      if [[ "$IS_DXP_CLOUD" == "true" ]]; then
        # For DXP Cloud, get file size from container
        local file_size=$(docker exec "$MYSQL_CONTAINER_NAME" stat -c %s "$CONTAINER_SQL_FILE" 2>/dev/null || docker exec "$MYSQL_CONTAINER_NAME" stat -f %z "$CONTAINER_SQL_FILE" 2>/dev/null)
        debug "File size of '$CONTAINER_SQL_FILE': ${file_size:-unknown}"
        if [[ -n "$file_size" ]]; then
          if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
            import_output=$(docker exec "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$CONTAINER_SQL_FILE'" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          else
            import_output=$(docker exec "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$CONTAINER_SQL_FILE'" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          fi
        else
          if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
            import_output=$(docker exec "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$CONTAINER_SQL_FILE'" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          else
            import_output=$(docker exec "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$CONTAINER_SQL_FILE'" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          fi
        fi
      else
        local file_size=$(stat -c %s "$SQL_FILE" 2>/dev/null || stat -f %z "$SQL_FILE" 2>/dev/null)
        debug "File size of '$SQL_FILE': ${file_size:-unknown}"
        if [[ -n "$file_size" ]]; then
          if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
            import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$SQL_FILE" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          else
            import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$SQL_FILE" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          fi
        else
          if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
            import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$SQL_FILE" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          else
            import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$SQL_FILE" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
          fi
        fi
      fi
    else
      echo "Warning: pv not installed. Proceeding without progress bar." >&2
      if [[ "$IS_DXP_CLOUD" == "true" ]]; then
        if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
          import_output=$(docker exec "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$CONTAINER_SQL_FILE'" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
        else
          import_output=$(docker exec "$MYSQL_CONTAINER_NAME" sh -c "echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;' && cat '$CONTAINER_SQL_FILE'" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
        fi
      else
        if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
          import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$SQL_FILE" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
        else
          import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$SQL_FILE" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -p"$MYSQL_ROOT_PASSWORD" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
        fi
      fi
    fi
    if [[ $? -ne 0 ]]; then
      echo "Import failed: $import_output" >&2
      rm -f /tmp/mysql.cnf
      [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
      return 1
    fi
    echo "Successfully imported SQL file into '$TARGET_DB'"
  else
    echo "Skipping SQL import for choice 2 (apcoa)"
  fi

  rm -f /tmp/mysql.cnf
  rm -rf "$temp_dir"
  echo "MySQL database '$TARGET_DB' imported successfully!"

  echo "Starting Tomcat setup..."

  local TOMCAT_ARCHIVE_PATH TOMCAT_ARCHIVE TOMCAT_VERSION
  local LIFERAY_DIR="$TARGET_DB-liferay-dxp"
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

  echo "Setting the server.xml port..."
  local server_xml_file="$LIFERAY_DIR/tomcat/conf/server.xml"
  if [[ ! -f "$server_xml_file" ]]; then
    echo "Error: server.xml not found at '$server_xml_file'." >&2
    exit 1
  fi

  # Replace ports starting with '8' (8005, 8080, 8443) with PORT_PREFIX
  sed -i "s/port=\"8\([0-9]\{3\}\)\"/port=\"$PORT_PREFIX\1\"/g" "$server_xml_file" || {
    echo "Error: Failed to update ports in '$server_xml_file'." >&2
    exit 1
  }
  echo "Ports updated in server.sh with prefix '$PORT_PREFIX'."

  echo "Creating portal-ext.properties..."
  local properties_file="$LIFERAY_DIR/portal-ext.properties"
  cat > "$properties_file" <<EOF || { echo "Error: Failed to create '$properties_file'." >&2; return 1; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://$MYSQL_CONTAINER_NAME:3306/$TARGET_DB?useUnicode=true&characterEncoding=UTF-8
jdbc.default.username=root
jdbc.default.password=
EOF
  if [[ "$IS_DXP_CLOUD" == "true" ]]; then
    cat >> "$properties_file" <<EOF || { echo "Error: Failed to append DXP Cloud properties to '$properties_file'." >&2; return 1; }
company.default.web.id=admin-$MODL_CODE.lxc.liferay.com
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
    cat > "$upgrade_tool_dir/portal-upgrade-database.properties" <<EOF || { echo "Error: Failed to create portal-upgrade-database.properties." >&2; return 1; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/${TARGET_DB}?characterEncoding=UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&serverTimezone=GMT&useFastDateParsing=false&useUnicode=true
jdbc.default.username=root
jdbc.default.password=
EOF
    echo "portal-upgrade-database.properties updated successfully."

    if [[ -f "$upgrade_tool_dir/db_upgrade_client.sh" ]]; then
      echo "Running database upgrade script..."
      cd "$upgrade_tool_dir" || { echo "Error: Failed to navigate to '$upgrade_tool_dir'." >&2; return 1; }
      ./db_upgrade_client.sh -j "-Dfile.encoding=UTF-8 -Duser.timezone=GMT -Xmx4096m" || {
        echo "Warning: Database upgrade script failed." >&2
        cd - >/dev/null
        return 0  # Continue despite upgrade failure
      }
      cd - >/dev/null
    else
      echo "Skipping database upgrade — 'db_upgrade_client.sh' not found in '$upgrade_tool_dir'."
    fi
  else
    echo "Skipping database upgrade — directory '$upgrade_tool_dir' does not exist."
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
    "Brinks --> brinks_dmp_7.4.bak"
    "Kubota --> stg-kpp-2024-08-06.bak"
    "Zain --> dxp72212_Kartik.bak"
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

echo "Choose a database to set up and import:"
echo "1. SQL Server"
echo "2. MySQL"
echo "3. Oracle 19"
echo "4. PostgreSQL"
echo "5. Export apcoa dump"
echo "6. Import apcoa dump"
echo "7. Stop and drop mysql_db container"
read -p "Enter your choice (1/2/3/4/5/6/7): " CHOICE

case $CHOICE in
  1)
    run_sqlserver
    import_sqlserver "$CHOICE"
    #import_sqlserver_rsync
    #run_sqlserver_with_local_tomcat
    ;;
  2)
    setup_and_import_mysql "$CHOICE"
    ;;
  3)
    run_oracle
    import_oracle
    ;;
  4)
    run_postgresql
    import_postgresql "$CHOICE"
    #run_postgresql_with_local_tomcat "$CHOICE"
    ;;
  5)
    export_mysql_dump "apcoa_db" "mysql_dump.sql"
    ;;
  6)
    import_mysql_dump "apcoa_db" "mysql_dump.sql"
    ;;
  7)
    stop_drop_mysql_db
    ;;
  *)
    echo "Invalid choice. Exiting."
    ;;
esac
