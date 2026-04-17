#!/bin/bash
#
# Author: Brian Joyner Wulbern <brian.wulbern@liferay.com>
# Platform: Linux/Unix
# VERSION: 1.23.0
# Add support for upgrading Antel and Lee Health (PostgreSQL)
# 

MYSQL_CONTAINER_NAME="mysql_db"
debug() { :; }

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

import_e5a2_dump() {
  local MYSQL_CONTAINER_NAME="mysql_db"
  local TARGET_DB="lportal"
  local INPUT_FILE="lxce5a2-e5a2prd.gz"
  
  # 1. Handle Password Logic
  local PWD_ARG=""
  [[ -n "$MYSQL_ROOT_PASSWORD" ]] && PWD_ARG="-p$MYSQL_ROOT_PASSWORD"

  # 2. Ensure Database Exists (The fix for Error 1049)
  echo "Ensuring database '$TARGET_DB' exists..."
  docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root $PWD_ARG -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\`;" || {
    echo "Error: Could not create/access database '$TARGET_DB'." >&2
    return 1
  }

  # 3. Import with Decompression
  echo "Importing '$INPUT_FILE' into '$TARGET_DB'..."
  # Note: Use zcat to decompress the .gz stream directly into mysql
  zcat "$INPUT_FILE" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root $PWD_ARG "$TARGET_DB" || {
    echo "Error importing dump file." >&2
    return 1
  }

  echo "Database '$TARGET_DB' imported successfully."
}

import_mysql_dump() {
  local MYSQL_CONTAINER_NAME="mysql_db"
  local TARGET_DB="$1"
  local INPUT_FILE="$2"
  local DEBUG=${DEBUG:-false}
  local MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-""}
  local MYSQL_ALLOW_EMPTY=${MYSQL_ALLOW_EMPTY:-"no"}
  local MYSQL_CNF="/tmp/mysql.cnf"
  local CONTAINER_CNF_PATH="/tmp/mysql.cnf"
  local ALT_CONTAINER_CNF_PATH="/etc/mysql/conf.d/mysql.cnf"

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  # Input validation
  [[ -z "$TARGET_DB" ]] && { echo "Error: Target database not specified." >&2; return 1; }
  [[ -z "$INPUT_FILE" ]] && { echo "Error: Input file not specified." >&2; return 1; }
  [[ ! -f "$INPUT_FILE" ]] && { echo "Error: Input file '$INPUT_FILE' does not exist." >&2; return 1; }
  [[ -z "$MYSQL_CONTAINER_NAME" ]] && { echo "Error: MYSQL_CONTAINER_NAME is unset." >&2; return 1; }

  # Log script inputs
  debug "Function inputs: TARGET_DB=$TARGET_DB, INPUT_FILE=$INPUT_FILE, MYSQL_CONTAINER_NAME=$MYSQL_CONTAINER_NAME"
  debug "Environment: MYSQL_ROOT_PASSWORD=$(if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then echo 'unset'; else echo '[set]'; fi), MYSQL_ALLOW_EMPTY=$MYSQL_ALLOW_EMPTY"

  # Check container status
  debug "Checking if MySQL container '$MYSQL_CONTAINER_NAME' is running"
  if ! docker ps --filter "name=^${MYSQL_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER_NAME}$"; then
    echo "Error: MySQL container '$MYSQL_CONTAINER_NAME' is not running." >&2
    debug "Listing all containers (running and stopped):"
    docker ps -a --filter "name=^${MYSQL_CONTAINER_NAME}$" >&2
    return 1
  fi
  debug "Container status:"
  docker ps -f name="$MYSQL_CONTAINER_NAME" >&2
  debug "Container image:"
  docker inspect "$MYSQL_CONTAINER_NAME" --format '{{.Config.Image}}' >&2

  # Log Docker environment
  debug "Docker environment:"
  debug "Docker version: $(docker --version)"
  debug "Docker info: $(docker info --format '{{.OperatingSystem}} {{.StorageDriver}}')"
  debug "User groups:"
  groups >&2

  # Check /tmp permissions
  debug "Checking local /tmp permissions"
  ls -ld /tmp >&2 || { echo "Error: Cannot access /tmp directory" >&2; return 1; }
  if [[ ! -w /tmp ]]; then
    echo "Error: /tmp is not writable" >&2
    return 1
  fi

  # Create and copy mysql.cnf
  if ! docker exec "$MYSQL_CONTAINER_NAME" test -f "$CONTAINER_CNF_PATH"; then
    echo "Creating $MYSQL_CNF locally..." >&2
    debug "Validating MYSQL_ROOT_PASSWORD"
    if [[ -z "$MYSQL_ROOT_PASSWORD" && "$MYSQL_ALLOW_EMPTY" != "yes" ]]; then
      echo "Error: MYSQL_ROOT_PASSWORD is unset and MYSQL_ALLOW_EMPTY is not enabled" >&2
      return 1
    fi
    debug "Creating $MYSQL_CNF with password=$(if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then echo 'empty'; else echo '[set]'; fi)"
    printf "[client]\nuser=root\npassword=%s\nhost=127.0.0.1\n" "$(printf '%s' "$MYSQL_ROOT_PASSWORD" | sed -e 's/[\/&]/\\&/g')" > "$MYSQL_CNF" || {
      echo "Error: Failed to create $MYSQL_CNF" >&2
      return 1
    }
    debug "Setting permissions on $MYSQL_CNF"
    chmod 600 "$MYSQL_CNF" || {
      echo "Error: Failed to set permissions on $MYSQL_CNF" >&2
      rm -f "$MYSQL_CNF"
      return 1
    }
    debug "Local $MYSQL_CNF contents:"
    cat "$MYSQL_CNF" >&2
    debug "Local $MYSQL_CNF permissions:"
    ls -l "$MYSQL_CNF" >&2

    debug "Copying $MYSQL_CNF to container $MYSQL_CONTAINER_NAME at $CONTAINER_CNF_PATH"
    for i in {1..3}; do
      docker cp "$MYSQL_CNF" "$MYSQL_CONTAINER_NAME:$CONTAINER_CNF_PATH" 2>&1 | tee /tmp/docker_cp_error.log && break
      echo "Retry $i: Error copying MySQL config file: $(cat /tmp/docker_cp_error.log)" >&2
      sleep 1
    done || {
      echo "Error: Failed to copy $MYSQL_CNF to $CONTAINER_CNF_PATH after retries" >&2
      cat /tmp/docker_cp_error.log >&2
      debug "Trying alternative path $ALT_CONTAINER_CNF_PATH"
      docker cp "$MYSQL_CNF" "$MYSQL_CONTAINER_NAME:$ALT_CONTAINER_CNF_PATH" 2>&1 | tee /tmp/docker_cp_error.log && {
        echo "Success: Copied to alternative path $ALT_CONTAINER_CNF_PATH" >&2
        CONTAINER_CNF_PATH="$ALT_CONTAINER_CNF_PATH"
      } || {
        echo "Error: Failed to copy to $ALT_CONTAINER_CNF_PATH: $(cat /tmp/docker_cp_error.log)" >&2
        debug "Container /tmp directory status:"
        docker exec "$MYSQL_CONTAINER_NAME" ls -ld /tmp >&2
        debug "Testing container /tmp writability:"
        docker exec "$MYSQL_CONTAINER_NAME" bash -c "touch /tmp/testfile && echo 'Writable' || echo 'Not writable'" >&2
        debug "Container logs:"
        docker logs "$MYSQL_CONTAINER_NAME" >&2
        rm -f "$MYSQL_CNF" /tmp/docker_cp_error.log
        return 1
      }
    }
    rm -f /tmp/docker_cp_error.log
    debug "Verifying $CONTAINER_CNF_PATH in container"
    docker exec "$MYSQL_CONTAINER_NAME" test -f "$CONTAINER_CNF_PATH" || {
      echo "Error: $CONTAINER_CNF_PATH not found in container after copy." >&2
      debug "Container /tmp directory status:"
      docker exec "$MYSQL_CONTAINER_NAME" ls -ld /tmp >&2
      debug "Testing container /tmp writability:"
      docker exec "$MYSQL_CONTAINER_NAME" bash -c "touch /tmp/testfile && echo 'Writable' || echo 'Not writable'" >&2
      debug "Container logs:"
      docker logs "$MYSQL_CONTAINER_NAME" >&2
      rm -f "$MYSQL_CNF"
      return 1
    }
    debug "Container $CONTAINER_CNF_PATH contents:"
    docker exec "$MYSQL_CONTAINER_NAME" cat "$CONTAINER_CNF_PATH" >&2
    rm -f "$MYSQL_CNF"
  else
    debug "$CONTAINER_CNF_PATH already exists in container"
    debug "Container $CONTAINER_CNF_PATH contents:"
    docker exec "$MYSQL_CONTAINER_NAME" cat "$CONTAINER_CNF_PATH" >&2
  fi

  # Test MySQL connection
  debug "Testing MySQL connection with $CONTAINER_CNF_PATH"
  docker exec "$MYSQL_CONTAINER_NAME" mysql --defaults-file="$CONTAINER_CNF_PATH" -e "SELECT 1" 2>&1 | tee /tmp/mysql_test.log || {
    echo "Error: MySQL connection test failed: $(cat /tmp/mysql_test.log)" >&2
    debug "Container logs:"
    docker logs "$MYSQL_CONTAINER_NAME" >&2
    rm -f /tmp/mysql_test.log
    return 1
  }
  rm -f /tmp/mysql_test.log

  # Ensure database exists
  echo "Ensuring database '$TARGET_DB' exists..." >&2
  debug "Executing: DROP DATABASE IF EXISTS \`$TARGET_DB\`; CREATE DATABASE \`$TARGET_DB\`"
  docker exec "$MYSQL_CONTAINER_NAME" mysql --defaults-file="$CONTAINER_CNF_PATH" --protocol=TCP -e "DROP DATABASE IF EXISTS \`$TARGET_DB\`; CREATE DATABASE \`$TARGET_DB\`;" || {
    echo "Error creating database '$TARGET_DB'." >&2
    debug "Container logs:"
    docker logs "$MYSQL_CONTAINER_NAME" >&2
    return 1
  }

  # Copy input file to container
  local CONTAINER_SQL_FILE="/tmp/$(basename "$INPUT_FILE")"
  debug "Copying input file '$INPUT_FILE' to container at '$CONTAINER_SQL_FILE'"
  docker cp "$INPUT_FILE" "$MYSQL_CONTAINER_NAME:$CONTAINER_SQL_FILE" || {
    echo "Error copying input file to container." >&2
    debug "Container logs:"
    docker logs "$MYSQL_CONTAINER_NAME" >&2
    return 1
  }
  debug "Verifying input file in container"
  docker exec "$MYSQL_CONTAINER_NAME" test -f "$CONTAINER_SQL_FILE" || {
    echo "Error: Input file '$CONTAINER_SQL_FILE' not found in container." >&2
    debug "Container /tmp directory status:"
    docker exec "$MYSQL_CONTAINER_NAME" ls -ld /tmp >&2
    return 1
  }

  # Import the SQL file
  echo "Importing '$INPUT_FILE' into '$TARGET_DB'..." >&2
  local import_output
  debug "Checking for pv command"
  if command -v pv >/dev/null; then
    debug "pv is available"
    local file_size=$(stat -c %s "$INPUT_FILE" 2>/dev/null || stat -f %z "$INPUT_FILE" 2>/dev/null || echo "unknown")
    debug "Input file size: ${file_size:-unknown}"
    if [[ -n "$file_size" && "$file_size" != "unknown" ]]; then
      debug "Importing with pv progress bar (size: $file_size)"
      import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | pv -s "$file_size" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql --defaults-file="$CONTAINER_CNF_PATH" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
    else
      debug "Importing with pv (size unknown)"
      import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | pv | docker exec -i "$MYSQL_CONTAINER_NAME" mysql --defaults-file="$CONTAINER_CNF_PATH" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
    fi
  else
    echo "Warning: pv not installed. Proceeding without progress bar." >&2
    debug "Importing without pv"
    import_output=$(echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" | cat - "$INPUT_FILE" | docker exec -i "$MYSQL_CONTAINER_NAME" mysql --defaults-file="$CONTAINER_CNF_PATH" --force --max-allowed-packet=943718400 "$TARGET_DB" 2>&1)
  fi
  if [[ $? -ne 0 ]]; then
    echo "Import failed: $import_output" >&2
    debug "Container logs after import failure:"
    docker logs "$MYSQL_CONTAINER_NAME" >&2
    return 1
  fi

  echo "Database '$TARGET_DB' imported successfully from '$INPUT_FILE'."
}

import_oracle() {
  local ORACLE_CONTAINER_NAME="oracle_db"
  local ORACLE_PDB_NAME="FREEPDB1"
  local SYSTEM_PASSWORD="LportalPassword123"
  local CONTAINER_DP_DIR="/opt/oracle/dpdump"
  local DUMP_FILE_NAME=""
  local DUMP_FILE_PATH=""
  local alteration_sql=""

  # Dump metadata arrays
  declare -A dump_names=(
    [1]="CNO Bizlink"
    [2]="Cuscal"
    [3]="Tokio Marine"
  )

  declare -A dump_files=(
    [1]="cno_bizlink_dump.dmp"
    [2]="25Q1_cuscal_dump_upgraded_with_kt_changes.dmp"
    [3]="25Q3_tokio_marine_old.dmp"
  )

  # Optional remap per choice (only add when needed)
  local remap_arg=""
  if [[ "$import_choice" == "2" ]]; then  # Cuscal
    remap_arg="REMAP_SCHEMA=LPORTAL_CUSCAL_73:LPORTAL"
  elif [[ "$import_choice" == "3" ]]; then  # Tokio Marine
    remap_arg="REMAP_SCHEMA=ADMLIFRYEXT:LPORTAL"
  fi

  echo "Choose a database to import (.dmp file):"

  for i in $(seq 1 ${#dump_files[@]}); do
    echo "$i. ${dump_names[$i]}"
  done

  local OTHER_CHOICE=$(( ${#dump_files[@]} + 1 ))
  echo "$OTHER_CHOICE. Other (custom .dmp file path/name)"

  read -p "Enter your choice: " import_choice

  if [[ "$import_choice" =~ ^[0-9]+$ ]] && [[ "$import_choice" -ge 1 ]] && [[ "$import_choice" -le ${#dump_files[@]} ]]; then
    DUMP_FILE_NAME="${dump_files[$import_choice]}"
    DUMP_FILE_PATH="./$DUMP_FILE_NAME"
    echo "Selected: ${dump_names[$import_choice]} ($DUMP_FILE_NAME)"
  elif [[ "$import_choice" == "$OTHER_CHOICE" ]]; then
    read -p "Enter the full path to your .dmp file: " DUMP_FILE_PATH
    DUMP_FILE_NAME=$(basename "$DUMP_FILE_PATH")
  else
    echo "Invalid choice! ❌"
    return 1
  fi

  if [[ ! -f "$DUMP_FILE_PATH" ]]; then
    echo "Error: Dump file '$DUMP_FILE_PATH' not found. ⚠️"
    ls -l *.dmp 2>/dev/null || echo "No .dmp files found in current directory."
    return 1
  fi

  echo "Copying $DUMP_FILE_NAME into container volume..."
  docker cp "$DUMP_FILE_PATH" "$ORACLE_CONTAINER_NAME":"$CONTAINER_DP_DIR/$DUMP_FILE_NAME"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to copy dump file via docker cp. ❌"
    docker ps -a | grep oracle_db
    return 1
  fi

  if docker exec "$ORACLE_CONTAINER_NAME" ls "$CONTAINER_DP_DIR/$DUMP_FILE_NAME" > /dev/null 2>&1; then
    echo "Dump file successfully placed in container volume. ✅"
  else
    echo "Critical Error: File not found inside container after copy. ❌"
    return 1
  fi

  if ! docker ps --filter "name=^${ORACLE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${ORACLE_CONTAINER_NAME}$"; then
    echo "Error: Oracle container not running. ❌"
    return 1
  fi

  echo "Executing Data Pump import (using SYSTEM + remap)..."

  local remap_arg=""
  if [[ "$import_choice" == "2" ]]; then  # Cuscal
    remap_arg="REMAP_SCHEMA=LPORTAL_CUSCAL_73:LPORTAL \
               REMAP_TABLESPACE=CUSCAL_DATA:USERS \
               REMAP_TABLESPACE=TOKIOMARINE:USERS \
               REMAP_TABLESPACE=USERS:USERS"
  elif [[ "$import_choice" == "3" ]]; then  # Tokio Marine
    remap_arg="REMAP_SCHEMA=ADMLIFRYEXT:LPORTAL \
               REMAP_TABLESPACE=USERS:USERS"
  fi

  echo "Executing Data Pump import (using SYSTEM + targeted remap)..."

  local impdp_output
  impdp_output=$(docker exec -u oracle "$ORACLE_CONTAINER_NAME" bash -c "
    source /home/oracle/.bashrc
    impdp \"SYSTEM/$SYSTEM_PASSWORD@$ORACLE_PDB_NAME\" \
      DIRECTORY=LPORTAL_IMPORT_DIR \
      DUMPFILE=$DUMP_FILE_NAME \
      NOLOGFILE=Y \
      $remap_arg \
      TABLE_EXISTS_ACTION=REPLACE \
      FULL=Y \
      TRANSFORM=SEGMENT_ATTRIBUTES:N \
      EXCLUDE=STATISTICS \
      METRICS=YES
  " 2>&1)

  local impdp_exit_code=$?

  echo "$impdp_output" > "impdp_console_${DUMP_FILE_NAME}.txt"
  echo "Console output saved to impdp_console_${DUMP_FILE_NAME}.txt"

  echo "Import summary (last 50 lines + key phrases):"
  tail -n 50 "impdp_console_${DUMP_FILE_NAME}.txt" | grep -i "error\|skip\|schema\|owner\|tablespace\|user\|create\|processing\|object\|metrics\|completed\|warning" || echo "No key phrases found."

  if [ $impdp_exit_code -eq 0 ] || [ $impdp_exit_code -eq 5 ] || echo "$impdp_output" | grep -qi "successfully completed"; then
    echo "Database imported (completed with possible warnings)! 🎉"

    # Quota fix
    echo "Ensuring LPORTAL has unlimited quota..."
    docker exec -u oracle "$ORACLE_CONTAINER_NAME" sqlplus "SYSTEM/$SYSTEM_PASSWORD@$ORACLE_PDB_NAME" <<EOF
      ALTER USER LPORTAL QUOTA UNLIMITED ON USERS;
      ALTER USER LPORTAL QUOTA UNLIMITED ON TOKIOMARINE;
      EXIT;
EOF

    # ← Add the RELEASE_ fix here
    if [[ "$import_choice" == "2" ]]; then  # Only for Cuscal
    echo "Updating RELEASE_ SERVLETCONTEXTNAME to 'portal-impl'..."
    docker exec -u oracle "$ORACLE_CONTAINER_NAME" sqlplus "SYSTEM/$SYSTEM_PASSWORD@$ORACLE_PDB_NAME" <<EOF
      ALTER SESSION SET CONTAINER = $ORACLE_PDB_NAME;

      UPDATE LPORTAL.RELEASE_
      SET SERVLETCONTEXTNAME = 'portal-impl'
      WHERE SERVLETCONTEXTNAME = 'portal';

      COMMIT;

      SELECT SERVLETCONTEXTNAME, BUILDNUMBER, VERIFIED
      FROM LPORTAL.RELEASE_
      WHERE SERVLETCONTEXTNAME = 'portal-impl';

      EXIT;
EOF
    fi

    # Schema check (your existing one)
    echo "Quick schema verification (using SYSTEM)..."
    docker exec "$ORACLE_CONTAINER_NAME" sqlplus "SYSTEM/$SYSTEM_PASSWORD@$ORACLE_PDB_NAME" <<CHECK
      ALTER SESSION SET CONTAINER = $ORACLE_PDB_NAME;
      SET PAGESIZE 999 FEEDBACK ON HEADING ON ECHO OFF

      SELECT 'Total tables in LPORTAL: ' || COUNT(*) FROM LPORTAL.user_tables;
      SELECT 'RELEASE_ exists in LPORTAL: ' || CASE WHEN EXISTS (SELECT 1 FROM LPORTAL.user_tables WHERE table_name = 'RELEASE_') THEN 'YES' ELSE 'NO' END FROM dual;
      SELECT 'COMPANY exists in LPORTAL: ' || CASE WHEN EXISTS (SELECT 1 FROM LPORTAL.user_tables WHERE table_name = 'COMPANY') THEN 'YES' ELSE 'NO' END FROM dual;
      SELECT 'RELEASE_ build number (if exists): ' || BUILDNUMBER FROM LPORTAL."RELEASE_" WHERE ROWNUM = 1;

      EXIT;
CHECK
  else
    echo "Import failed critically (exit code $impdp_exit_code). Console tail:"
    echo "$impdp_output" | tail -n 50
    return 1
  fi

  # alteration_sql block (if any)
  if [ -n "$alteration_sql" ]; then
    echo "Running post-import table alteration..."
    docker exec -u oracle "$ORACLE_CONTAINER_NAME" bash -c "
      source /home/oracle/.bashrc
      sqlplus -S \"/ as sysdba\"@$ORACLE_PDB_NAME <<SQL
        SET SQLBLANKLINES ON
        $alteration_sql
        COMMIT;
        EXIT;
SQL
    "
    if [ $? -eq 0 ]; then
      echo "Table alteration completed successfully! ✅"
    else
      echo "Warning: Table alteration failed (non-critical). Continuing... ⚠️"
    fi
  fi
}

run_oracle() {
  local ORACLE_CONTAINER_NAME="oracle_db"
  local ORACLE_IMAGE="container-registry.oracle.com/database/free:latest"
  local ORACLE_PASSWORD="LportalPassword123"
  local LPORTAL_PASSWORD="LPORTAL"
  local ORACLE_PDB_NAME="FREEPDB1"
  local ORACLE_CDB_SERVICE="FREE"
  local CONTAINER_DP_DIR="/opt/oracle/dpdump"
  local start_container=1

  if docker ps --filter "name=^${ORACLE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${ORACLE_CONTAINER_NAME}$"; then
    echo "Oracle container '$ORACLE_CONTAINER_NAME' is already running. Checking if database is ready..."
    if docker logs "$ORACLE_CONTAINER_NAME" 2>/dev/null | grep -q "DATABASE IS READY TO USE!"; then
      echo "Database is already initialized and ready! Skipping container startup. 🎉"
      start_container=0
      if docker exec -u oracle "$ORACLE_CONTAINER_NAME" bash -c "
        source /home/oracle/.bashrc
        echo \"SELECT OPEN_MODE FROM V\\\$PDBS WHERE NAME = '${ORACLE_PDB_NAME^^}' AND OPEN_MODE = 'READ WRITE';\" | 
        sqlplus -S / as sysdba | grep -q 'READ WRITE'
      "; then
        echo "PDB $ORACLE_PDB_NAME is open READ WRITE. Proceeding..."
      else
        echo "Warning: PDB not fully open — continuing anyway (may be transient)."
      fi
    else
      echo "Container running but database not ready. Restarting..."
      docker rm -f "$ORACLE_CONTAINER_NAME"
    fi
  else
    echo "No running Oracle container found. Starting fresh..."
  fi

  if [[ $start_container -eq 1 ]]; then
    docker rm -f "$ORACLE_CONTAINER_NAME" 2>/dev/null || true

    docker volume create oracle-dpdump 2>/dev/null || true

    echo "Starting Oracle Database Free container..."
    docker run -d \
      --name "${ORACLE_CONTAINER_NAME}" \
      --platform linux/amd64 \
      -e ORACLE_PWD="$ORACLE_PASSWORD" \
      -p 1521:1521 \
      --volume oracle-dpdump:"$CONTAINER_DP_DIR" \
      --memory=16g \
      --cpus=6 \
      --shm-size=4g \
      "$ORACLE_IMAGE"

    if [ $? -ne 0 ]; then
      echo "Failed to start Oracle container. ❌"
      return 1
    fi

    echo "⏳ Waiting for database to report ready (1–4 min first time)... ⏳"
    local max_attempts=16
    local attempt=1
    until docker logs "$ORACLE_CONTAINER_NAME" 2>/dev/null | grep -q "DATABASE IS READY TO USE!"; do
      if [[ $attempt -gt $max_attempts ]]; then
        echo "Error: Timed out waiting for database. Check logs: docker logs $ORACLE_CONTAINER_NAME ❌"
        return 1
      fi
      printf " Attempt %3d/%d – waiting 15 seconds...\r" $attempt $max_attempts
      sleep 15
      attempt=$((attempt + 1))
    done
    echo
    echo "Database is ready! Finalizing..."
    sleep 10
  fi

  echo "Ensuring LPORTAL user exists in PDB ($ORACLE_PDB_NAME)..."
  docker exec -u oracle "$ORACLE_CONTAINER_NAME" bash -c "
    source /home/oracle/.bashrc
    sqlplus -S / as sysdba <<SQL
      ALTER SESSION SET \"_ORACLE_SCRIPT\"=true;

      -- Switch to PDB
      ALTER SESSION SET CONTAINER = $ORACLE_PDB_NAME;

      -- Create tablespace only if not exists
      BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLESPACE TOKIOMARINE DATAFILE ''tokiomarine01.dbf'' SIZE 100M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED';
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLCODE != -01543 THEN RAISE; END IF;
      END;
      /

      -- Drop and recreate LPORTAL user
      BEGIN
        EXECUTE IMMEDIATE 'DROP USER LPORTAL CASCADE';
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLCODE != -1918 THEN RAISE; END IF;
      END;
      /

      CREATE USER LPORTAL IDENTIFIED BY \"$LPORTAL_PASSWORD\" DEFAULT TABLESPACE USERS;
      GRANT CONNECT, RESOURCE, DBA TO LPORTAL;
      GRANT IMP_FULL_DATABASE TO LPORTAL;
      ALTER USER LPORTAL QUOTA UNLIMITED ON USERS;

      -- Create directory in PDB (for impdp)
      CREATE OR REPLACE DIRECTORY LPORTAL_IMPORT_DIR AS '/opt/oracle/dpdump';
      GRANT READ, WRITE ON DIRECTORY LPORTAL_IMPORT_DIR TO PUBLIC;

      EXIT;
SQL
  "
  if [ $? -eq 0 ]; then
    echo "LPORTAL user configured successfully! ✅"
  else
    echo "Warning: Issue creating LPORTAL user — check manually. ⚠️"
  fi

  echo
  echo "Oracle Database Free is fully ready!"
  echo "• Use docker cp to place .dmp files into the volume:"
  echo "  docker cp your_dump.dmp ${ORACLE_CONTAINER_NAME}:${CONTAINER_DP_DIR}/"
  echo "• Logs: docker logs -f ${ORACLE_CONTAINER_NAME}"
  echo
}

import_postgresql() {
  echo "Choose a database to import:"
  echo "1. Antel --> antel-database-dump.zip"
  echo "2. Balearia --> 02-dump_20250924-2.sql"
  echo "3. Church Mutual --> 24Q3_ChurchMutual_database_dump.sql"
  echo "4. DPESP --> 25Q3_dpesp_dump_20251013.sql"
  echo "5. Jessa --> 24Q4_Jessa_database_dump.sql"
  echo "6. Lee Health --> lee_health_dump-2025-12-30.zip"
  echo "7. Otis --> 2025Q1_lportal-postgresql-2025.q1.14-08182025.sql"
  echo "8. Ovam --> 24Q3_OVAM_database_dump.sql"
  echo "9. RWTH Aachen University --> 25Q1_RWTH_database_dump.sql"
  echo "10. Sapphire --> 25Q1_sapphire-postgres-20250415.sql"
  echo "11. Other"
  read -p "Enter your choice: " import_choice
  
  local dump_file=""
  local alteration_sql=""
  local apply_boolean_fixes=false

  case $import_choice in
    1) dump_file="antel-database-dump.zip" ;;
    2) dump_file="02-dump_20250924-2.sql" ;;
    3) 
      dump_file="24Q3_ChurchMutual_database_dump.sql"
      alteration_sql="ALTER TABLE public.cpdefinition_x_20102 ALTER COLUMN cpdefinitionid SET NOT NULL;"
      apply_boolean_fixes=true
      ;;
    4) dump_file="25Q3_dpesp_dump_20251013.sql" ;;
    5) dump_file="24Q4_Jessa_database_dump.sql" ;;
    6) dump_file="lee_health_dump-2025-12-30.zip"; TARGET_DB="lee_health_db"; MODL_CODE="lee-health" ;;
    7) dump_file="2025Q1_lportal-postgresql-2025.q1.14-08182025.sql" ;;
    8) dump_file="24Q3_OVAM_database_dump.sql" ;;
    9) dump_file="25Q1_RWTH_database_dump.sql" ;;
    10) 
      dump_file="25Q1_sapphire-postgres-20250415.sql"
      alteration_sql="ALTER TABLE public.cpdefinition_x_20097 ALTER COLUMN cpdefinitionid SET NOT NULL;"
      ;;
    11) read -p "Enter the path to your PostgreSQL dump file: " dump_file ;;
    *) echo "Invalid choice!"; exit 1 ;;
  esac

  if [[ -f "$dump_file" ]]; then
    echo "Importing PostgreSQL database from $dump_file..."
    
    # 1. We use --set ON_ERROR_STOP=0 so the script doesn't die on 'Owner' errors.
    # 2. We use < "$dump_file" to stream the entire file into the container.
    # 3. We use --quiet to avoid thousands of 'ALTER TABLE' lines in the console.
    docker exec -i postgresql_db psql -U root -d lportal --set ON_ERROR_STOP=0 --quiet < "$dump_file"
    
    if [ $? -eq 0 ]; then
      echo "Database import finished! 🎉"
      
      # Fix the search path: If the dump used a custom schema, Liferay needs to see it.
      echo "Ensuring search_path is inclusive..."
      docker exec -i postgresql_db psql -U root -d lportal -c "ALTER USER root SET search_path TO \"\$user\", public;"
      
      if [[ -n "$alteration_sql" ]]; then
        echo "Running post-import table alterations..."
        docker exec -i postgresql_db psql -U root -d lportal -c "$alteration_sql"
        [[ $? -eq 0 ]] && echo "Table alteration successful! ✅" || echo "Alteration failed! ❌"
      fi
    else
      echo "Error: Database import failed! ❌"
      exit 1
    fi
  else
    echo "Error: Dump file $dump_file not found! ⚠️"
    exit 1
  fi

  if [ "$apply_boolean_fixes" = true ]; then
      echo "Applying global boolean type fixes..."
      local boolean_sql="
        ALTER TABLE public.company ALTER COLUMN system_ TYPE boolean USING (CASE WHEN system_ = 'Y' THEN true WHEN system_ = 'N' THEN false ELSE NULL END);
        ALTER TABLE public.dlfilerank ALTER COLUMN active_ TYPE boolean USING (CASE WHEN active_ = 'Y' THEN true WHEN active_ = 'N' THEN false ELSE NULL END);
        ALTER TABLE public.oauth2application 
          ALTER COLUMN rememberdevice TYPE boolean USING (CASE WHEN rememberdevice = 'Y' THEN true WHEN rememberdevice = 'N' THEN false ELSE NULL END), 
          ALTER COLUMN trustedapplication TYPE boolean USING (CASE WHEN trustedapplication = 'Y' THEN true WHEN trustedapplication = 'N' THEN false ELSE NULL END);
      "
      docker exec -i postgresql_db psql -U root -d lportal -c "$boolean_sql"
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
      echo "Invalid choice. Please enter a number between 1 and 4. ❌"
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
    echo "Error copying dump file to container. Check Docker and file permissions. ❌"
    exit 1
  fi

  echo "Dump file copied to SQL Server container."

  echo "⏳ Waiting for SQL Server to be ready...⏳"
  for i in {1..30}; do
    docker exec sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT 1" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "SQL Server is ready!"
      break
    fi
    echo "⏳ Waiting for SQL Server... ($i/30) ⏳"
    sleep 2
  done

  filename=$(basename "$DUMP_FILE")
  echo "The file name is: $filename"

  file_list=$(docker exec -it sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "RESTORE FILELISTONLY FROM DISK = '/var/opt/mssql/backup/$filename'" 2>&1)
  if echo "$file_list" | grep -q "Msg [0-9]\+,"; then
    echo "Error listing files in backup. Check SQL Server logs in the container. ❌"
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

upgrade_oracle_with_local_tomcat() {
  local LIFERAY_DIR="liferay-dxp"
  local ORACLE_JDBC_JAR="ojdbc11.jar"
  local ORACLE_USER="LPORTAL"
  local ORACLE_PASSWORD="LPORTAL"
  local ORACLE_PDB_SERVICE="FREEPDB1"
  local JDBC_URL="jdbc:oracle:thin:@//localhost:1521/$ORACLE_PDB_SERVICE"
  local JDBC_DRIVER="oracle.jdbc.OracleDriver"

  echo "Starting Liferay DXP Tomcat setup + Database Upgrade for Oracle 19c..."

  local TOMCAT_ARCHIVE=""
  while [[ -z "$TOMCAT_ARCHIVE" || ! -f "$TOMCAT_ARCHIVE" ]]; do
    read -rp "Enter the full path to your Liferay DXP Tomcat bundle (.zip or .tar.gz), or press Enter to auto-search current directory: " user_input

    if [[ -z "$user_input" ]]; then
      echo "Searching current directory for Liferay Tomcat bundle..."
      TOMCAT_ARCHIVE=$(find . -maxdepth 1 \( \
        -name "liferay-dxp-tomcat-7.4*.zip" -o \
        -name "liferay-dxp-tomcat-7.4*.tar.gz" -o \
        -name "liferay-dxp-tomcat-202[4-9]*.zip" -o \
        -name "liferay-dxp-tomcat-202[4-9]*.tar.gz" -o \
        -name "liferay-fixed.zip" \) | head -n 1)

      if [[ -z "$TOMCAT_ARCHIVE" ]]; then
        echo "No Liferay Tomcat bundle found in current directory. Please provide a path." >&2
        continue
      fi
    else
      TOMCAT_ARCHIVE="$user_input"
    fi

    if [[ ! -f "$TOMCAT_ARCHIVE" ]]; then
      echo "File not found: $TOMCAT_ARCHIVE. Try again." >&2
      TOMCAT_ARCHIVE=""
    fi
  done

  echo "Using bundle: $TOMCAT_ARCHIVE"


  if [[ -d "$LIFERAY_DIR" ]]; then
    echo "Removing existing '$LIFERAY_DIR' directory..."
    rm -rf "$LIFERAY_DIR" || { echo "Failed to remove old directory. ❌"; return 1; }
  fi

  echo "Extracting bundle..."
  if [[ "$TOMCAT_ARCHIVE" == *.zip ]]; then
    unzip -q "$TOMCAT_ARCHIVE" || { echo "Failed to unzip archive. ❌"; return 1; }
  elif [[ "$TOMCAT_ARCHIVE" == *.tar.gz ]]; then
    tar -xzf "$TOMCAT_ARCHIVE" || { echo "Failed to extract tar.gz archive. ❌"; return 1; }
  else
    echo "Unsupported archive format. ❌"; return 1
  fi

  if [[ ! -d "$LIFERAY_DIR" ]]; then
    echo "Extraction failed – expected directory '$LIFERAY_DIR' not found. ❌"
    return 1
  fi

  local LIFERAY_HOME_ABS="$(pwd)/$LIFERAY_DIR"
  echo "Liferay home set to: $LIFERAY_HOME_ABS"

  if [[ ! -d "$LIFERAY_DIR/tomcat" ]]; then
    echo "Error: tomcat directory missing after extraction. ❌"
    ls -la "$LIFERAY_DIR"
    return 1
  fi

  cat > "$LIFERAY_DIR/portal-ext.properties" <<EOF
jdbc.default.driverClassName=$JDBC_DRIVER
jdbc.default.url=$JDBC_URL
jdbc.default.username=$ORACLE_USER
jdbc.default.password=$ORACLE_PASSWORD
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

  local SHIELDED_LIB="$LIFERAY_DIR/tomcat/webapps/ROOT/WEB-INF/shielded-container-lib"
  if [[ -f "$ORACLE_JDBC_JAR" ]]; then
    mkdir -p "$SHIELDED_LIB"
    cp "$ORACLE_JDBC_JAR" "$SHIELDED_LIB/" && echo "JDBC driver copied." || echo "JDBC copy failed (non-critical)."
  else
    echo "Warning: ojdbc11.jar not found. Download from Oracle and place here."
  fi

  local UPGRADE_DIR="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
  if [[ ! -d "$UPGRADE_DIR" ]]; then
    echo "Upgrade tool dir not found: $UPGRADE_DIR. ❌"
    ls -la "$LIFERAY_DIR/tools"
    return 1
  fi
  cd "$UPGRADE_DIR" || return 1

  rm -f portal-upgrade-*.properties app-server.properties 2>/dev/null

  cat > portal-upgrade-ext.properties <<EOF
jdbc.default.driverClassName=$JDBC_DRIVER
jdbc.default.url=$JDBC_URL
jdbc.default.username=$ORACLE_USER
jdbc.default.password=$ORACLE_PASSWORD
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

  cat > portal-upgrade-database.properties <<EOF
jdbc.default.driverClassName=$JDBC_DRIVER
jdbc.default.url=$JDBC_URL
jdbc.default.username=$ORACLE_USER
jdbc.default.password=$ORACLE_PASSWORD
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

  cat > app-server.properties <<EOF
dir=$LIFERAY_HOME_ABS/tomcat
extra.lib.dirs=bin
global.lib.dir=lib
portal.dir=webapps/ROOT
server.detector.server.id=tomcat
EOF

  echo "Starting database upgrade..."
  local upgrade_log="upgrade_$(date +%Y%m%d_%H%M%S).log"
  ./db_upgrade_client.sh -j "-Dfile.encoding=UTF-8 -Duser.timezone=GMT -Xmx4096m" 2>&1 | tee "$upgrade_log"

  if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "Upgrade completed successfully! 🎉"
    
    # NEW: Copy the log to the parent directory so it survives a 'rm -rf'
    cp "$upgrade_log" "../../upgrade_SUCCESS_$(date +%Y%m%d).log"
    
    echo "Start Liferay: $LIFERAY_HOME_ABS/tomcat/bin/startup.sh"
    echo "A backup of the log has been saved to the current directory."
    
    # Return to the original directory
    cd - >/dev/null
    
    # Stop the script here so it doesn't move on to MySQL/other DBs
    exit 0 
  else
    echo "Upgrade failed. Check $(pwd)/$upgrade_log for details. ❌"
    tail -n 50 "$upgrade_log"
    cd - >/dev/null
    return 1
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
    -e POSTGRES_DB=postgres \
    -p 5433:5432 \
    --memory=8g \
    --cpus=2 \
    postgres:15.5 \
    postgres \
    -c shared_buffers=2GB \
    -c max_wal_size=4GB \
    -c synchronous_commit=off \
    -c checkpoint_timeout=30min \
    -c wal_buffers=16MB \
    -c maintenance_work_mem=1GB

  if [ $? -eq 0 ]; then
    echo "⏳ Waiting for PostgreSQL to be ready... ⏳"
    until docker exec postgresql_db pg_isready -U root -h localhost > /dev/null 2>&1; do
      sleep 2
    done
    echo "PostgreSQL container started successfully!"
  else
    echo "Failed to start PostgreSQL container."
    exit 1
  fi

  echo "Cleaning up and preparing roles..."
  docker exec -i postgresql_db psql -U root -d postgres -c "DROP DATABASE IF EXISTS lportal;"
  docker exec -i postgresql_db psql -U root -d postgres -c "CREATE DATABASE lportal;"

  local common_roles=("liferay" "portal" "pgadmin" "db_user" "admin" "liferay_user")

  for role in "${common_roles[@]}"; do
    echo "Ensuring role '$role' exists..."
    docker exec -i postgresql_db psql -U root -d postgres -c \
      "DO \$\$ 
       BEGIN 
         IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$role') THEN 
           CREATE ROLE $role WITH LOGIN PASSWORD '$role' SUPERUSER; 
         END IF; 
       END \$\$;"
  done

  # 5. Optional: Set search path to ensure schemas created during import are visible
  docker exec -i postgresql_db psql -U root -d lportal -c "ALTER USER root SET search_path TO \"\$user\", public;"

  echo "Roles and Database initialized. Ready for import. ✅"
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

  LIFERAY_HOME_ABS=$(pwd)/$LIFERAY_DIR
  echo "LIFERAY_HOME_ABS set to: $LIFERAY_HOME_ABS" # For debugging

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
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

  echo "portal-ext.properties created successfully in $LIFERAY_DIR."
  cd ../

  DB_UPGRADE_DIR="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
  if [[ -d "$DB_UPGRADE_DIR" ]]; then
    echo "Navigating to $DB_UPGRADE_DIR and updating portal-upgrade-ext.properties..."
    cd "$DB_UPGRADE_DIR" || { echo "Failed to enter $DB_UPGRADE_DIR"; return 1; }

    cat > portal-upgrade-ext.properties <<EOF
jdbc.default.driverClassName=org.postgresql.Driver
jdbc.default.url=jdbc:postgresql://localhost:5433/lportal
jdbc.default.username=root
jdbc.default.password=
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

    cat > portal-upgrade-database.properties <<EOF
jdbc.default.driverClassName=org.postgresql.Driver
jdbc.default.url=jdbc:postgresql://localhost:5433/lportal
jdbc.default.username=root
jdbc.default.password=
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

    echo "portal-upgrade-ext.properties updated successfully."

    echo "Creating app-server.properties..."
    local upgrade_tool_dir="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
    local app_server_properties_file="app-server.properties"
    cat > "$app_server_properties_file" <<EOF || { echo "Error: Failed to create '$app_server_properties_file'." >&2; return 2; }
dir=${LIFERAY_HOME_ABS}/tomcat
extra.lib.dirs=bin
global.lib.dir=lib
portal.dir=webapps/ROOT
server.detector.server.id=tomcat
EOF

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

  echo "⏳Waiting for SQL Server to be ready...⏳"
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
  local MSSQL_JDBC_JAR="mssql-jdbc-12.8.2.jre11.jar"
  #local MSSQL_JDBC_JAR="mssql-jdbc-12.2.0.jre8.jar"

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

  LIFERAY_HOME_ABS=$(pwd)/$LIFERAY_DIR
  echo "LIFERAY_HOME_ABS set to: $LIFERAY_HOME_ABS" # For debugging

  echo "Using Tomcat version: $VERSION"
  echo "Tomcat directory: $TOMCAT_DIR"

  echo "Navigating to $LIFERAY_DIR and creating portal-ext.properties..."
  cd "$LIFERAY_DIR" || { echo "Failed to enter $LIFERAY_DIR"; return 1; }

  cat > portal-ext.properties <<EOF
jdbc.default.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
jdbc.default.url=jdbc:sqlserver://localhost:1433;databaseName=lportal;trustServerCertificate=true;
jdbc.default.username=sa
jdbc.default.password=R00t@1234
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
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
    echo "Navigating to $DB_UPGRADE_DIR and updating portal-upgrade-ext.properties..."
    cd "$DB_UPGRADE_DIR" || { echo "Failed to enter $DB_UPGRADE_DIR"; return 1; }

    cat > portal-upgrade-ext.properties <<EOF
jdbc.default.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
jdbc.default.url=jdbc:sqlserver://localhost:1433;databaseName=lportal;trustServerCertificate=true;
jdbc.default.username=sa
jdbc.default.password=R00t@1234
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

    cat > portal-upgrade-database.properties <<EOF
jdbc.default.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
jdbc.default.url=jdbc:sqlserver://localhost:1433;databaseName=lportal;trustServerCertificate=true;
jdbc.default.username=sa
jdbc.default.password=R00t@1234
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

    echo "portal-upgrade-ext.properties updated successfully."

    echo "Creating app-server.properties..."
    local upgrade_tool_dir="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
    local app_server_properties_file="app-server.properties"
    cat > "$app_server_properties_file" <<EOF || { echo "Error: Failed to create '$app_server_properties_file'." >&2; return 2; }
dir=${LIFERAY_HOME_ABS}/tomcat
extra.lib.dirs=bin
global.lib.dir=lib
portal.dir=webapps/ROOT
server.detector.server.id=tomcat
EOF

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

  trap cleanup EXIT SIGINT SIGTERM

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  echo 'Choose a database to import:'
  echo '1) Actinver     6) IPC            11) TUDelft'
  echo '2) APCOA        7) Metos          12) e5a2 (LXC)'
  echo '3) Argus        8) OPAP           13) Custom Path'
  echo '4) Bosch        9) TBG Internet   14) DXP Cloud (LPD)'
  echo '5) CNO Bizlink 10) TBG Intranet   15) d4a3'
  echo '16) Lee Health'
  read -rp 'Enter choice: ' CHOICE

  alteration_sql=""

  case "$CHOICE" in
    1) TARGET_DB="actinver_db"; ZIP_FILE="24Q1_Actinver_database_dump.zip" ;;
    2) TARGET_DB="apcoa_db"; ZIP_FILE="24Q2_APCOA_database_dump.sql" ;;
    3) TARGET_DB="argus_db"; ZIP_FILE="24Q2_Argus_database_dump.sql" ;;
    4) TARGET_DB="bosch_db"; ZIP_FILE="25Q2_bosch_dump.sql" ;;
    5) TARGET_DB="cno_bizlink_db"; ZIP_FILE="24Q1_CNOBizlink_database_dump.sql" ;;
    6) TARGET_DB="ipc_db"; ZIP_FILE="25Q1_ipc_dump_2025-05-05-164823.zip" ;;
    7) TARGET_DB="metos_db"; ZIP_FILE="24Q3_Metos_database_dump.zip"
       alteration_sql="DELETE FROM Configuration_ WHERE configurationId = 'com.liferay.portal.tika.internal.configuration.TikaConfiguration';"
      ;;
    8) TARGET_DB="opap_db"; ZIP_FILE="2025Q1_opap_merged_dump_2025-09-04.sql" ;;
    9) TARGET_DB="tbg_internet"; ZIP_FILE="25Q3_tbg_internet_dump.sql" ;;
    10) TARGET_DB="tbg_intranet"; ZIP_FILE="25Q3_tbg_intranet_dump.sql" ;;
    11) TARGET_DB="tudelft_db"; ZIP_FILE="24Q1_TUDelft_database_dump.sql" ;;
    12) TARGET_DB="lportal"
        ZIP_FILE="lxce5a2-e5a2prd.gz"
        MODL_CODE=e5a2
      ;;
    13) read -rp "Enter the path to your custom dump zip: " ZIP_FILE
       read -rp "Enter your target database name: " TARGET_DB ;;
    14)
      TARGET_DB="lportal"
      read -rp "Enter the LPD ticket number (e.g., LPD-52788): " LPD_TICKET
      read -rp "Enter the MODL code (e.g., r8k1): " MODL_CODE
      # Validate inputs
      [[ -z "$LPD_TICKET" ]] && { echo "Error: LPD ticket number cannot be empty." >&2; return 1; }
      [[ -z "$MODL_CODE" ]] && { echo "Error: MODL code cannot be empty." >&2; return 1; }
      DOCKER_IMAGE="liferay/database-upgrades:$LPD_TICKET"
      IS_DXP_CLOUD=true
      ;;
    15) TARGET_DB="lportal"; ZIP_FILE="dump-d4a3.sql" ;;
    16) TARGET_DB="lee_health_db"; ZIP_FILE="lee_health_dump-2025-12-30.zip" ;;
    *)
      echo "Invalid MySQL choice." >&2
      return 1
      ;;
  esac

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
        --default-time-zone='GMT' \
        --innodb_buffer_pool_size=8G \
        --innodb_doublewrite=0 \
        --innodb_log_file_size=4G \
        --innodb_flush_log_at_trx_commit=0 \
        --innodb_io_capacity=4000 \
        --innodb_write_io_threads=8 \
        --max-allowed-packet=943718400 \
        --wait-timeout=6000 \
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
        --default-time-zone='GMT' \
        --innodb_buffer_pool_size=8G \
        --innodb_doublewrite=0 \
        --innodb_log_file_size=4G \
        --innodb_flush_log_at_trx_commit=0 \
        --innodb_io_capacity=4000 \
        --innodb_write_io_threads=8 \
        --max-allowed-packet=943718400 \
        --wait-timeout=6000 \
        --sync_binlog=0"
    fi
    if [[ "$IS_DXP_CLOUD" == "true" ]]; then
      docker_run_cmd=$(echo "$docker_run_cmd" | sed 's/ --character-set-server=utf8mb3 --collation-server=utf8mb3_unicode_ci//')
    else
      docker_run_cmd="$docker_run_cmd \
        --default-time-zone='GMT' \
        --innodb_buffer_pool_size=4G \
        --lower_case_table_names=1 \
        --max-allowed-packet=943718400 \
        --wait-timeout=6000 \
        --innodb_log_file_size=512M \
        --innodb_flush_log_at_trx_commit=0 \
        --innodb_io_capacity=2000 \
        --innodb_write_io_threads=8 \
        --sync_binlog=0"
    fi
    debug "Docker run command: $docker_run_cmd"
    eval "$docker_run_cmd" || { echo "Error creating container." >&2; return 1; }
  fi

 # Debug-enhanced mysql.cnf creation and copy
  debug "Checking local /tmp permissions"
  ls -ld /tmp >&2 || { echo "Error: Cannot access /tmp directory" >&2; return 1; }
  if [[ ! -w /tmp ]]; then
    echo "Error: /tmp is not writable" >&2
    return 1
  fi
  debug "Creating MySQL config file at /tmp/mysql.cnf"
  if [[ -z "$MYSQL_ROOT_PASSWORD" && "$MYSQL_ALLOW_EMPTY" != "yes" ]]; then
    echo "Error: MYSQL_ROOT_PASSWORD is unset and MYSQL_ALLOW_EMPTY is not enabled" >&2
    return 1
  fi
  printf "[client]\nuser=root\npassword=%s\nhost=127.0.0.1\n" "$(printf '%s' "$MYSQL_ROOT_PASSWORD" | sed -e 's/[\/&]/\\&/g')" > /tmp/mysql.cnf || {
    echo "Error: Failed to create /tmp/mysql.cnf" >&2
    return 1
  }
  chmod 600 /tmp/mysql.cnf || {
    echo "Error: Failed to set permissions on /tmp/mysql.cnf" >&2
    rm -f /tmp/mysql.cnf
    return 1
  }
  debug "Local /tmp/mysql.cnf contents:"
  cat /tmp/mysql.cnf >&2
  ls -l /tmp/mysql.cnf >&2
  debug "Verifying Docker permissions"
  docker info --format '{{.OperatingSystem}}' >&2
  debug "Docker version: $(docker --version)" >&2
  debug "Container status:"
  docker ps -f name="$MYSQL_CONTAINER_NAME" >&2
  debug "Copying /tmp/mysql.cnf to container $MYSQL_CONTAINER_NAME"
  for i in {1..3}; do
    docker cp /tmp/mysql.cnf "$MYSQL_CONTAINER_NAME:/tmp/mysql.cnf" 2>&1 | tee /tmp/docker_cp_error.log && break
    echo "Retry $i: Error copying MySQL config file: $(cat /tmp/docker_cp_error.log)" >&2
    sleep 1
  done || {
    echo "Error: Failed to copy /tmp/mysql.cnf after retries" >&2
    cat /tmp/docker_cp_error.log >&2
    rm -f /tmp/mysql.cnf /tmp/docker_cp_error.log
    return 1
  }
  rm -f /tmp/docker_cp_error.log
  debug "Verifying /tmp/mysql.cnf in container"
  docker exec "$MYSQL_CONTAINER_NAME" test -f /tmp/mysql.cnf || {
    echo "Error: /tmp/mysql.cnf not found in container after copy." >&2
    debug "Container /tmp directory status:"
    docker exec "$MYSQL_CONTAINER_NAME" ls -ld /tmp >&2
    docker exec "$MYSQL_CONTAINER_NAME" bash -c "touch /tmp/testfile && echo 'Writable' || echo 'Not writable'" >&2
    debug "Container logs:"
    docker logs "$MYSQL_CONTAINER_NAME" >&2
    rm -f /tmp/mysql.cnf
    return 1
  }
  debug "Config file contents in container:"
  docker exec "$MYSQL_CONTAINER_NAME" cat /tmp/mysql.cnf >&2
  debug "Testing MySQL connection with /tmp/mysql.cnf"
  docker exec "$MYSQL_CONTAINER_NAME" mysql --defaults-file=/tmp/mysql.cnf -e "SELECT 1" 2>&1 | tee /tmp/mysql_test.log || {
    echo "Error: MySQL connection test failed: $(cat /tmp/mysql_test.log)" >&2
    rm -f /tmp/mysql.cnf /tmp/mysql_test.log
    return 1
  }
  rm -f /tmp/mysql_test.log

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

    # Look for a file that likely contains SQL content (e.g., contains CREATE, INSERT, or other SQL keywords)
    SQL_FILE=$(find "$temp_dir" -type f | while read -r file; do
        if head -n 100 "$file" | grep -E -i '^(CREATE|INSERT|UPDATE|DELETE|ALTER|DROP|SET)' >/dev/null; then
            echo "$file"
            break
        fi
    done)

    [[ -z "$SQL_FILE" ]] && { echo "No valid SQL file found in $ZIP_FILE" >&2; rm -f /tmp/mysql.cnf; rm -rf "$temp_dir"; return 1; }
  elif [[ "$ZIP_FILE" == *.sql || "$ZIP_FILE" == *.bak || "$(head -n 100 "$ZIP_FILE" | grep -E -i '^(CREATE|INSERT|UPDATE|DELETE|ALTER|DROP|SET)')" ]]; then
      # Accept .sql, .bak, or files with SQL content
      if [[ "$IS_DXP_CLOUD" == "true" ]]; then
          SQL_FILE="$CONTAINER_SQL_PATH"
      else
          SQL_FILE="$ZIP_FILE"
      fi
  else
      echo "Error: Input file must be a .zip file or a valid SQL dump file" >&2
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
  elif [[ "$CHOICE" != "2" && "$CHOICE" != "12" ]]; then
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

  if [[ "$INPUT_FILE" == *.gz ]]; then
    # Use your new smart_import logic just for this file type
    smart_import "$INPUT_FILE" "$TARGET_DB"
    import_result=$?
  fi

  if [ -n "$alteration_sql" ]; then
        echo "Running post-setup table alterations on MySQL (${TARGET_DB})..."

        local alter_cmd="SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET SESSION sql_mode='';"
        alter_cmd+=$'\n'"${alteration_sql}"

        # Build mysql command WITHOUT quoting the -D value
        local mysql_args=(-u root -D "$TARGET_DB" -e "$alter_cmd")
        if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
            mysql_args+=(-p"$MYSQL_ROOT_PASSWORD")
        fi

        echo "Executing alterations..." >&2
        docker exec "$MYSQL_CONTAINER_NAME" mysql "${mysql_args[@]}" 2>&1 | tee /tmp/alteration.log

        if [ "${PIPESTATUS[0]}" -eq 0 ]; then
            echo "MySQL table alterations completed successfully! ✅"
            rm -f /tmp/alteration.log
        else
            echo "Error: MySQL table alterations failed!" >&2
            echo "Last 20 lines of output:" >&2
            tail -n 20 /tmp/alteration.log >&2
            rm -f /tmp/alteration.log
            return 1
        fi
    fi

  rm -f /tmp/mysql.cnf
  rm -rf "$temp_dir"
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
    unzip -oq "$TOMCAT_ARCHIVE" -d . > /dev/null || { echo "Error: Failed to unzip '$TOMCAT_ARCHIVE'." >&2; return 1; }
  elif [[ "$TOMCAT_ARCHIVE" == *.tar.gz ]]; then
    tar -xzf "$TOMCAT_ARCHIVE" -C . > /dev/null || { echo "Error: Failed to extract '$TOMCAT_ARCHIVE'." >&2; return 1; }
  else
    echo "Error: Unsupported archive format for '$TOMCAT_ARCHIVE'." >&2
    return 1
  fi
  if [[ ! -d "$LIFERAY_DIR" ]]; then
    echo "Error: Unzipped archive did not create '$LIFERAY_DIR' folder." >&2
    return 1
  fi

  LIFERAY_HOME_ABS=$(pwd)/$LIFERAY_DIR
  echo "LIFERAY_HOME_ABS set to: $LIFERAY_HOME_ABS" # For debugging

  echo "Creating portal-ext.properties..."
  local properties_file="$LIFERAY_DIR/portal-ext.properties"
  cat > "$properties_file" <<EOF || { echo "Error: Failed to create '$properties_file'." >&2; return 1; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
#jdbc.default.url=jdbc:mysql://$MYSQL_CONTAINER_NAME:3306/$TARGET_DB?useUnicode=true&characterEncoding=UTF-8
jdbc.default.url=jdbc:mysql://localhost:3306/$TARGET_DB?useUnicode=true&characterEncoding=UTF-8
jdbc.default.username=root
jdbc.default.password=
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
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
company.security.strangers.verify=false
database.partition.enabled=true
dl.store.file.system.lenient=true
#include-and-override=portal-liferay-online.properties
#jdbc.lportal.driverClassName=com.mysql.cj.jdbc.Driver
#jdbc.lportal.url=jdbc:mysql://localhost:3306/lportal?UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&GMT&useFastDateParsing=&useUnicode=
#jdbc.lportal.username=root
#jdbc.lportal.password=
EOF
  fi
  # chmod 600 "$properties_file" || { echo "Error: Failed to set permissions on '$properties_file'." >&2; return 1; }
  # debug "portal-ext.properties contents:"
  # cat "$properties_file" >&2
  # echo "portal-ext.properties updated successfully."

  # Check for database upgrade tool
  local upgrade_tool_dir="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
  if [[ -d "$upgrade_tool_dir" ]]; then
    echo "Creating portal-upgrade-ext.properties..."
    local upgrade_properties_ext_file="$upgrade_tool_dir/portal-upgrade-ext.properties"
    cat > "$upgrade_properties_ext_file" <<EOF || { echo "Error: Failed to create '$upgrade_properties_ext_file'." >&2; return 2; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/${TARGET_DB}?characterEncoding=UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&serverTimezone=GMT&useFastDateParsing=false&useUnicode=true
jdbc.default.username=root
jdbc.default.password=
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

    echo "Creating portal-upgrade-database.properties..."
    local upgrade_properties_file="$upgrade_tool_dir/portal-upgrade-database.properties"
    cat > "$upgrade_properties_file" <<EOF || { echo "Error: Failed to create '$upgrade_properties_file'." >&2; return 2; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/${TARGET_DB}?characterEncoding=UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&serverTimezone=GMT&useFastDateParsing=false&useUnicode=true
jdbc.default.username=root
jdbc.default.password=
liferay.home=${LIFERAY_HOME_ABS}
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
EOF

    echo "Creating app-server.properties..."
    local app_server_properties_file="$upgrade_tool_dir/app-server.properties"
    cat > "$app_server_properties_file" <<EOF || { echo "Error: Failed to create '$app_server_properties_file'." >&2; return 2; }
dir=${LIFERAY_HOME_ABS}/tomcat
extra.lib.dirs=bin
global.lib.dir=lib
portal.dir=webapps/ROOT
server.detector.server.id=tomcat
EOF

      # Enable multi-tenancy upgrade
    if [[ "$MODL_CODE" == "e5a2" ]]; then
      cat >> "$upgrade_properties_file" <<EOF || { echo "Error: Failed to create '$upgrade_properties_file'." >&2; return 2; }
company.default.web.id=admin-e5a2.lxc.liferay.com      
# jdbc.lportal.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lportal.url=jdbc:mysql://localhost:3306/lportal?UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&GMT&useFastDateParsing=&useUnicode=
# jdbc.lportal.username=root
# jdbc.lportal.password=
# #database.partition.enabled=true
# upgrade.database.preupgrade.verify.enabled=true
# upgrade.database.preupgrade.data.cleanup.enabled=true

# database.partition.schemas=lportal,lpartition_11162231691175,lpartition_11706165,lpartition_11711847,lpartition_11726111,lpartition_11816620,lpartition_11819872,lpartition_11822045,lpartition_11940122,lpartition_13982314,lpartition_16684433639393,lpartition_17855804202317,lpartition_1860468,lpartition_18804743,lpartition_18807698,lpartition_1996101,lpartition_26053188,lpartition_45286218349995,lpartition_57868206215768,lpartition_66138412237889,lpartition_83909668433076,lpartition_9184961,lpartition_20097

# jdbc.lpartition_11162231691175.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11162231691175.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11162231691175.username=root
# jdbc.lpartition_11162231691175.password=

# jdbc.lpartition_11706165.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11706165.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11706165.username=root
# jdbc.lpartition_11706165.password=

# jdbc.lpartition_11711847.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11711847.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11711847.username=root
# jdbc.lpartition_11711847.password=

# jdbc.lpartition_11726111.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11726111.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11726111.username=root
# jdbc.lpartition_11726111.password=

# jdbc.lpartition_11816620.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11816620.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11816620.username=root
# jdbc.lpartition_11816620.password=

# jdbc.lpartition_11819872.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11819872.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11819872.username=root
# jdbc.lpartition_11819872.password=

# jdbc.lpartition_11822045.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11822045.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11822045.username=root
# jdbc.lpartition_11822045.password=

# jdbc.lpartition_11940122.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_11940122.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_11940122.username=root
# jdbc.lpartition_11940122.password=

# jdbc.lpartition_13982314.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_13982314.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_13982314.username=root
# jdbc.lpartition_13982314.password=

# jdbc.lpartition_16684433639393.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_16684433639393.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_16684433639393.username=root
# jdbc.lpartition_16684433639393.password=

# jdbc.lpartition_17855804202317.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_17855804202317.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_17855804202317.username=root
# jdbc.lpartition_17855804202317.password=

# jdbc.lpartition_1860468.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_1860468.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_1860468.username=root
# jdbc.lpartition_1860468.password=

# jdbc.lpartition_18804743.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_18804743.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_18804743.username=root
# jdbc.lpartition_18804743.password=

# jdbc.lpartition_18807698.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_18807698.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_18807698.username=root
# jdbc.lpartition_18807698.password=

# jdbc.lpartition_1996101.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_1996101.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_1996101.username=root
# jdbc.lpartition_1996101.password=

# jdbc.lpartition_26053188.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_26053188.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_26053188.username=root
# jdbc.lpartition_26053188.password=

# jdbc.lpartition_45286218349995.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_45286218349995.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_45286218349995.username=root
# jdbc.lpartition_45286218349995.password=

# jdbc.lpartition_57868206215768.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_57868206215768.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_57868206215768.username=root
# jdbc.lpartition_57868206215768.password=

# jdbc.lpartition_66138412237889.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_66138412237889.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_66138412237889.username=root
# jdbc.lpartition_66138412237889.password=

# jdbc.lpartition_83909668433076.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_83909668433076.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_83909668433076.username=root
# jdbc.lpartition_83909668433076.password=

# jdbc.lpartition_9184961.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_9184961.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_9184961.username=root
# jdbc.lpartition_9184961.password=

# jdbc.lpartition_20097.driverClassName=com.mysql.cj.jdbc.Driver
# jdbc.lpartition_20097.url=jdbc:mysql://localhost:3306/lportal?useUnicode=true&characterEncoding=UTF-8
# jdbc.lpartition_20097.username=root
# jdbc.lpartition_20097.password=
EOF
    fi

    # Add partition schemas if multiple exist
    if [[ "${#partitions[@]}" -gt 1 ]]; then
      echo "database.partition.schemas=${partitions[*]}" >> "$upgrade_properties_file"
    fi
  
    chmod 644 "$upgrade_properties_file" || { echo "Error: Failed to set permissions on '$upgrade_properties_file'." >&2; return 644; }
    echo "Successfully updated portal-upgrade-ext.properties."

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
          local temp_properties_file="$upgrade_tool_dir/portal-upgrade-ext-$partition.properties"
          cat > "$temp_properties_file" <<EOF || { echo "Error: Failed to create '$temp_properties_file'." >&2; return 2; }
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/${partition}?characterEncoding=UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose}&serverTimezone=GMT&useFastDateParsing=false&useUnicode=true}
jdbc.default.username=root
jdbc.default.password=
#liferay.home=${LIFERAY_DIR}
database.partition.enabled=true
upgrade.database.dl.storage.check.disabled=true
upgrade.database.preupgrade.verify.enabled=true
upgrade.database.preupgrade.data.cleanup.enabled=true
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

  echo "⏳Waiting for SQL Server to be ready...⏳"
  for i in {1..30}; do
    docker exec sqlserver_db /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P 'R00t@1234' -d master -C -Q "SELECT 1" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "SQL Server is ready!"
      break
    fi
    echo "⏳Waiting for SQL Server... ($i/30) ⏳"
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

ensure_db_exists() {
  local db=$1
  local pwd_arg=""
  
  # Ensure we have a container name; fallback to mysql_db if empty
  local container="${MYSQL_CONTAINER_NAME:-mysql_db}"
  
  [[ -n "$MYSQL_ROOT_PASSWORD" ]] && pwd_arg="-p$MYSQL_ROOT_PASSWORD"
  
  debug "Checking/Creating database: $db"
  
  # Using a subshell or checking the exit code here is safer
  if ! docker exec -i "$container" mysql -u root $pwd_arg -e "CREATE DATABASE IF NOT EXISTS \`$db\`;" 2>/dev/null; then
    echo "❌ Error: Could not connect to Docker container '$container'. Is it running?"
    return 1
  fi
}

# Handles .sql, .gz, and .zip imports automatically
smart_import() {
  local file=$1
  local db=$2
  local pwd_arg=""
  [[ -n "$MYSQL_ROOT_PASSWORD" ]] && pwd_arg="-p$MYSQL_ROOT_PASSWORD"

  # Fix 1: Ensure container name is set
  local container="${MYSQL_CONTAINER_NAME:-mysql_db}"

  ensure_db_exists "$db"

  local start_time=$(date +%s)
  echo "🚀 Importing $file into $db..."

  # Fix 2: Move the SESSION sets to a variable we prepend to the stream
  # This avoids the quoting nightmare with 'docker exec'
  local sql_init="SET SESSION UNIQUE_CHECKS=0; SET SESSION FOREIGN_KEY_CHECKS=0; SET SESSION SQL_LOG_BIN=0;"
  local mysql_cmd="mysql -u root $pwd_arg --force --max-allowed-packet=943718400 $db"

  if [[ "$file" == *.gz ]]; then
    # We use { echo ...; zcat ...; } to combine the init SQL with the dump
    { echo "$sql_init"; zcat "$file"; } | pv | docker exec -i "$container" sh -c "$mysql_cmd"
  elif [[ "$file" == *.zip ]]; then
    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")
    { echo "$sql_init"; unzip -p "$file"; } | pv -s "$size" | docker exec -i "$container" sh -c "$mysql_cmd"
  else
    { echo "$sql_init"; cat "$file"; } | pv | docker exec -i "$container" sh -c "$mysql_cmd"
  fi

  local duration=$(( $(date +%s) - start_time ))
  echo "✅ Import finished in $((duration / 60))m $((duration % 60))s"
}

cleanup() {
  local exit_code=$?
  # Only show message if we're actually cleaning something up
  if [[ -f "/tmp/mysql.cnf" || -d "${temp_dir:-/dev/null}" ]]; then
    echo -e "\n🧹 Cleaning up temporary files..."
    rm -f /tmp/mysql.cnf
    # Only remove temp_dir if it was actually defined and exists
    [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf "$temp_dir"
  fi
  
  # Ensure we exit with the original error code if there was one
  exit $exit_code
}

upgrade_liferay_tomcat() {
  # 1. Force Defaults if empty
  local TARGET_DB="${1:-lportal}"
  local MODL_CODE="${2:-e5a2}"
  local LIFERAY_DIR="liferay-dxp"

  # 2. Path Setup
  local CURRENT_DIR=$(pwd)
  local LIFERAY_HOME_ABS="$CURRENT_DIR/$LIFERAY_DIR"

  echo "---------------------------------------------------"
  echo "🚀 Upgrading: $TARGET_DB | Home: $LIFERAY_HOME_ABS"
  echo "---------------------------------------------------"

  # 3. Locate and Extract Bundle (Same as your existing logic)
  local TOMCAT_ARCHIVE=$(find . -maxdepth 1 \( -name "liferay-dxp-tomcat-*" -o -name "liferay-fixed.zip" \) | head -n 1)
  [[ -z "$TOMCAT_ARCHIVE" ]] && { echo "Error: Archive not found."; return 1; }

  [[ -d "$LIFERAY_DIR" ]] && rm -rf "$LIFERAY_DIR"
  echo "📦 Extracting $TOMCAT_ARCHIVE..."
  if [[ "$TOMCAT_ARCHIVE" == *.zip ]]; then unzip -oq "$TOMCAT_ARCHIVE" -d .; else tar -xzf "$TOMCAT_ARCHIVE" -C .; fi

  # 4. CONFIGURATION: Setting paths precisely
  local upgrade_tool_dir="$LIFERAY_DIR/tools/portal-tools-db-upgrade-client"
  
  # Ensure the directory exists before writing
  [[ ! -d "$upgrade_tool_dir" ]] && { echo "Error: Upgrade tool dir not found"; return 1; }

  echo "👤 Ensuring 'dxpcloud' user exists in MySQL..."
  docker exec -i mysql_db mysql -u root ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} -e "CREATE USER IF NOT EXISTS 'dxpcloud'@'%' IDENTIFIED BY ''; GRANT ALL PRIVILEGES ON *.* TO 'dxpcloud'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;"

  echo "📝 Writing Configuration Files to $upgrade_tool_dir..."

  # File 1: portal-upgrade-ext.properties (The modern standard)
  cat > "$upgrade_tool_dir/portal-upgrade-ext.properties" <<EOF
jdbc.default.driverClassName=com.mysql.cj.jdbc.Driver
jdbc.default.url=jdbc:mysql://localhost:3306/${TARGET_DB}?characterEncoding=UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&serverTimezone=GMT&useFastDateParsing=false&useUnicode=true
jdbc.default.username=root
jdbc.default.password=${MYSQL_ROOT_PASSWORD:-}
liferay.home=${LIFERAY_HOME_ABS}
company.default.web.id=admin-${MODL_CODE}.lxc.liferay.com
database.partition.enabled=true
upgrade.database.dl.storage.check.disabled=true
EOF

  # File 2: portal-upgrade-database.properties (Legacy support, just in case)
  cp "$upgrade_tool_dir/portal-upgrade-ext.properties" "$upgrade_tool_dir/portal-upgrade-database.properties"

  # File 3: app-server.properties (Tells Liferay where the Tomcat folder is)
  cat > "$upgrade_tool_dir/app-server.properties" <<EOF
dir=${LIFERAY_HOME_ABS}/tomcat
extra.lib.dirs=bin
global.lib.dir=lib
portal.dir=webapps/ROOT
server.detector.server.id=tomcat
EOF

  # 5. EXECUTION
  read -rp "Run upgrade script now for $TARGET_DB? (y/n): " RUN_NOW
  if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    echo "🏃 Starting Upgrade Client..."
    # We MUST be inside the tool directory for it to pick up the .properties files
    cd "$upgrade_tool_dir" || return 1
    
    # Removed the -n flag. 
    # If it still prompts, it means it's not finding portal-upgrade-ext.properties 
    # in the local folder.
    ./db_upgrade_client.sh -j "-Dfile.encoding=UTF-8 -Duser.timezone=GMT -Xmx4096m"
    
    cd - >/dev/null
  fi
}

echo "Choose a database to set up and import:"
echo "1. SQL Server"
echo "2. MySQL (if apcoa or e5a2, import first)"
echo "3. PostgreSQL"
echo "4. Oracle"
echo "5. Import apcoa dump"
echo "6. e5a2 - import & upgrade"
echo "7. e5a2 - just the upgrade"
echo "8. Stop and drop mysql_db container"
echo "9. Clean Oracle container (stop/rm oracle_db)"
read -p "Enter your choice (1/2/3/4/5/6/7/8/9): " CHOICE

case $CHOICE in
  1)
    run_sqlserver
    import_sqlserver
    #import_sqlserver_rsync
    upgrade_sqlserver_with_local_tomcat
    ;;
  2)
    #setup_and_import_mysql_2
    setup_and_import_mysql
    ;;
  3)
    run_postgresql
    import_postgresql
    upgrade_postgresql_with_local_tomcat
    ;;
  4)
    run_oracle
    import_oracle
    upgrade_oracle_with_local_tomcat
    ;;
  5)
    TARGET_DB="apcoa_db"
    INPUT_FILE="24Q2_APCOA_database_dump.sql"
    smart_import "$INPUT_FILE" "$TARGET_DB"
    ;;
  # 6)
  #   import_mysql_dump "lportal" "5ff380f7-ced4-4df3-bac0-6af9537f5c9d"
  #   ;;
  6)
    TARGET_DB="lportal"
    INPUT_FILE="lxce5a2-e5a2prd.gz"
    MODL_CODE="e5a2"
    
    smart_import "$INPUT_FILE" "$TARGET_DB"
    upgrade_liferay_tomcat "$TARGET_DB" "$MODL_CODE"
    ;;

  7) # Just the Upgrade (For when you've already imported the 15.5GB)
    read -rp "Which DB are we upgrading? (e.g. lportal): " TARGET_DB
    read -rp "MODL Code? (e.g. e5a2): " MODL_CODE
    upgrade_liferay_tomcat "$TARGET_DB" "$MODL_CODE"
    ;;
  8)
    stop_drop_mysql_db
    ;;
  9)
    echo "Cleaning Oracle container..."
    docker stop oracle_db 2>/dev/null || true
    docker rm oracle_db 2>/dev/null || true
    echo "Oracle container cleaned. Ready for fresh start."
    ;;
  *)
    echo "Invalid choice. Exiting."
    ;;
esac
