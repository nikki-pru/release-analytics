#!/bin/bash
#
# Author: Brian Joyner Wulbern <brian.wulbern@liferay.com>
# Platform: Linux/Unix
# VERSION: 2.1.0
# Added support for Antel, Lee Health, and new CNO Bizlink dump (MySQL)
# Added environment clearing step for Oracle
# 

CURRENT_IMPORT_NAME="None"
LIFERAY_HOME_ABS="Not Setup"
MODL_CODE="N/A"
MYSQL_CONTAINER_NAME="mysql_db"
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-""}
TARGET_DB="lportal"

debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo "[DEBUG] $@" >&2
    fi
}

set_tab_title() {
    # Send the ANSI escape sequence to rename the terminal tab
    echo -ne "\033]0;$1\007"
}

import_oracle() {
  local ORACLE_CONTAINER_NAME="oracle_db"
  local ORACLE_PDB_NAME="FREEPDB1"
  local SYSTEM_PASSWORD="LportalPassword123"
  local CONTAINER_DP_DIR="/opt/oracle/dpdump"
  local DUMP_FILE_NAME=""
  local DUMP_FILE_PATH=""

  declare -A dump_names=( [1]="Cuscal" [2]="Tokio Marine" )
  declare -A dump_files=( [1]="25Q1_cuscal_dump_upgraded_with_kt_changes.dmp" [2]="25Q3_tokio_marine_old.dmp" )

  echo "Choose a database to import (.dmp file):"
  for i in $(seq 1 ${#dump_files[@]}); do echo "$i. ${dump_names[$i]}"; done
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
    return 1
  fi

  local remap_arg=""
  if [[ "$import_choice" == "1" ]]; then  # Cuscal
    remap_arg="REMAP_SCHEMA=LPORTAL_CUSCAL_73:LPORTAL REMAP_TABLESPACE=CUSCAL_DATA:USERS REMAP_TABLESPACE=TOKIOMARINE:USERS REMAP_TABLESPACE=USERS:USERS"
  elif [[ "$import_choice" == "2" ]]; then  # Tokio Marine
    remap_arg="REMAP_SCHEMA=ADMLIFRYEXT:LPORTAL REMAP_TABLESPACE=USERS:USERS"
  fi

  echo "Copying $DUMP_FILE_NAME into container volume..."
  set_tab_title "Copying: Oracle ($DUMP_FILE_NAME)"
  docker cp "$DUMP_FILE_PATH" "$ORACLE_CONTAINER_NAME":"$CONTAINER_DP_DIR/$DUMP_FILE_NAME"

  echo "Executing Data Pump import (using SYSTEM + targeted remap)..."
  set_tab_title "Importing: Oracle ($DUMP_FILE_NAME)"

  local impdp_output
  impdp_output=$(docker exec -u oracle "$ORACLE_CONTAINER_NAME" bash -c "
    source /home/oracle/.bashrc
    impdp \"SYSTEM/$SYSTEM_PASSWORD@$ORACLE_PDB_NAME\" \
      DIRECTORY=LPORTAL_IMPORT_DIR DUMPFILE=$DUMP_FILE_NAME \
      NOLOGFILE=Y $remap_arg TABLE_EXISTS_ACTION=REPLACE FULL=Y \
      TRANSFORM=SEGMENT_ATTRIBUTES:N EXCLUDE=STATISTICS METRICS=YES
  " 2>&1)

  local impdp_exit_code=$?
  echo "$impdp_output" > "impdp_console_${DUMP_FILE_NAME}.txt"

  if [ $impdp_exit_code -eq 0 ] || [ $impdp_exit_code -eq 5 ] || echo "$impdp_output" | grep -qi "successfully completed"; then
    echo "✅ Database imported. Applying Legacy Quota and Context fixes..."
    
    # Conditional SQL block based on project
    local custom_surgery_sql=""
    if [[ "$import_choice" == "1" ]]; then
        custom_surgery_sql="
        ALTER SESSION SET CURRENT_SCHEMA = LPORTAL;
        
        -- 1. Fix Context
        UPDATE Release_ SET servletContextName = 'portal-impl' WHERE servletContextName = 'portal';
        
        -- 2. Fix missing Admin (Targeted Link for Company 18131)
        INSERT INTO Users_Roles (companyId, userId, roleId)
        SELECT 18131, 18131, roleId FROM Role_ WHERE name = 'Administrator' AND companyId = 18131
        AND NOT EXISTS (SELECT 1 FROM Users_Roles WHERE userId = 18131 AND roleId = (SELECT roleId FROM Role_ WHERE name = 'Administrator' AND companyId = 18131));
        
        -- 3. Explicit Fix: Resurrect missing user 930698
        MERGE INTO User_ u
        USING (SELECT 930698 as userId FROM DUAL) src
        ON (u.userId = src.userId)
        WHEN NOT MATCHED THEN
            INSERT (mvccVersion, uuid_, userId, companyId, createDate, modifiedDate, contactId, password_, passwordEncrypted, passwordReset, screenName, emailAddress, facebookId, greeting, firstName, middleName, lastName, jobTitle, loginDate, lastLoginDate, status) 
            VALUES (0, 'dummy-930698', 930698, 10131, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 930698, 'dummy', 1, 0, 'dummy_930698', 'dummy930698@liferay.com', 0, 'Welcome', 'Dummy', '', 'User', '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 0);

        MERGE INTO Contact_ c
        USING (SELECT 930698 as contactId FROM DUAL) src
        ON (c.contactId = src.contactId)
        WHEN NOT MATCHED THEN
            INSERT (mvccVersion, contactId, companyId, userId, userName, createDate, modifiedDate, firstName, middleName, lastName, male, birthday)
            VALUES (0, 930698, 10131, 930698, 'Dummy User', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'Dummy', '', 'User', 1, CURRENT_TIMESTAMP);
        "
    fi

    docker exec -u oracle "$ORACLE_CONTAINER_NAME" sqlplus "SYSTEM/$SYSTEM_PASSWORD@$ORACLE_PDB_NAME" <<EOF
      ALTER SESSION SET CONTAINER = $ORACLE_PDB_NAME;
      -- Core Quotas
      ALTER USER LPORTAL QUOTA UNLIMITED ON USERS;
      BEGIN EXECUTE IMMEDIATE 'ALTER USER LPORTAL QUOTA UNLIMITED ON TOKIOMARINE'; EXCEPTION WHEN OTHERS THEN NULL; END;
      /
      $custom_surgery_sql
      COMMIT;
      EXIT;
EOF
  else
    echo "❌ Import failed critically (exit code $impdp_exit_code)."
    echo "--- DATA PUMP ERROR LOG (Last 20 lines) ---"
    tail -n 20 "impdp_console_${DUMP_FILE_NAME}.txt"
    echo "-------------------------------------------"
    return 1
  fi
  set_tab_title "Imported: Oracle ($DUMP_FILE_NAME)"
}

run_oracle() {
  local ORACLE_CONTAINER_NAME="oracle_db"
  local ORACLE_IMAGE="container-registry.oracle.com/database/free:latest"
  local ORACLE_PASSWORD="LportalPassword123"
  local LPORTAL_PASSWORD="LPORTAL"
  local ORACLE_PDB_NAME="FREEPDB1"
  local CONTAINER_DP_DIR="/opt/oracle/dpdump"
  
  local force_recreate_user=${FORCE_ORACLE_WIPE:-0}
  local start_container=1

  # --- NEW: Aggressive 12GB Limit Prevention ---
  if docker ps -a --filter "name=^${ORACLE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${ORACLE_CONTAINER_NAME}$"; then
    echo "---------------------------------------------------"
    echo "⚠️  EXISTING ORACLE CONTAINER DETECTED ⚠️"
    echo "Oracle Free Edition has a strict 12GB disk limit. Since our"
    echo "database dumps (Cuscal, Tokio, etc.) are massive, importing"
    echo "into a used container will trigger an ORA-12954 storage error."
    echo "---------------------------------------------------"
    read -rp "Destroy the existing container and start fresh? (Y/n): " nuke_choice
    
    if [[ ! "$nuke_choice" =~ ^[Nn]$ ]]; then
      echo "🧹 Nuking old container and volume to reclaim space..."
      docker rm -f "$ORACLE_CONTAINER_NAME" 2>/dev/null || true
      docker volume rm oracle-dpdump 2>/dev/null || true
      start_container=1
    else
      echo "Proceeding with existing container. Checking if database is ready..."
      if docker logs "$ORACLE_CONTAINER_NAME" 2>/dev/null | grep -q "DATABASE IS READY TO USE!"; then
        echo "Database is already initialized and ready! Skipping container startup. 🎉"
        start_container=0
        docker exec -u oracle "$ORACLE_CONTAINER_NAME" bash -c "source /home/oracle/.bashrc; echo \"ALTER PLUGGABLE DATABASE $ORACLE_PDB_NAME OPEN;\" | sqlplus -S / as sysdba" > /dev/null 2>&1
      else
        echo "Container running but database not ready. Restarting..."
        docker rm -f "$ORACLE_CONTAINER_NAME"
        start_container=1
      fi
    fi
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

    echo "⏳ Waiting for database to report ready (up to 7 min first time)... ⏳"
    set_tab_title "Starting: Oracle Engine"
    local max_attempts=30
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

  # Core setup: Set Schema, Create Tablespaces, Configure User
  local setup_tablespace_sql="
    ALTER SESSION SET \"_ORACLE_SCRIPT\"=true;
    ALTER SESSION SET CONTAINER = $ORACLE_PDB_NAME;
    
    -- Restore missing TOKIOMARINE Tablespace
    BEGIN
      EXECUTE IMMEDIATE 'CREATE TABLESPACE TOKIOMARINE DATAFILE ''tokiomarine01.dbf'' SIZE 100M AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -01543 THEN RAISE; END IF;
    END;
    /
    
    -- Restore missing SERVICE_ACCOUNT Profile to prevent ORA-02380 during Data Pump
    BEGIN
      EXECUTE IMMEDIATE 'CREATE PROFILE SERVICE_ACCOUNT LIMIT PASSWORD_LIFE_TIME UNLIMITED';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE != -02379 THEN RAISE; END IF; -- Ignore if profile already exists
    END;
    /
  "

  if [[ $force_recreate_user -eq 1 ]]; then
    echo "⚠️  Wipe Mode: Ensuring LPORTAL user is RECREATED in PDB ($ORACLE_PDB_NAME)..."
    local user_sql="
      $setup_tablespace_sql
      
      -- Kill active sessions to avoid ORA-01940
      BEGIN
        FOR r IN (SELECT sid, serial# FROM v\\\$session WHERE username = 'LPORTAL') LOOP
          EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || r.sid || ',' || r.serial# || '''';
        END LOOP;
      END;
      /
      BEGIN EXECUTE IMMEDIATE 'DROP USER LPORTAL CASCADE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1918 THEN RAISE; END IF; END;
      /
      CREATE USER LPORTAL IDENTIFIED BY \"$LPORTAL_PASSWORD\" DEFAULT TABLESPACE USERS;
      GRANT CONNECT, RESOURCE, DBA, IMP_FULL_DATABASE TO LPORTAL;
      ALTER USER LPORTAL QUOTA UNLIMITED ON USERS;
    "
  else
    echo "✅ Safe Mode: Ensuring LPORTAL user exists without wiping data..."
    local user_sql="
      $setup_tablespace_sql
      
      DECLARE
        v_count NUMBER;
      BEGIN
        SELECT count(*) INTO v_count FROM dba_users WHERE username = 'LPORTAL';
        IF v_count = 0 THEN
          EXECUTE IMMEDIATE 'CREATE USER LPORTAL IDENTIFIED BY \"$LPORTAL_PASSWORD\" DEFAULT TABLESPACE USERS';
          EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE, DBA, IMP_FULL_DATABASE TO LPORTAL';
          EXECUTE IMMEDIATE 'ALTER USER LPORTAL QUOTA UNLIMITED ON USERS';
        END IF;
      END;
      /
    "
  fi

  docker exec -u oracle "$ORACLE_CONTAINER_NAME" bash -c "source /home/oracle/.bashrc; sqlplus -S / as sysdba <<SQL
    $user_sql
    CREATE OR REPLACE DIRECTORY LPORTAL_IMPORT_DIR AS '$CONTAINER_DP_DIR';
    GRANT READ, WRITE ON DIRECTORY LPORTAL_IMPORT_DIR TO PUBLIC;
    EXIT;
SQL"

  echo
  echo "Oracle Database Free is fully ready!"
  echo "• Use docker cp to place .dmp files into the volume:"
  echo "  docker cp your_dump.dmp ${ORACLE_CONTAINER_NAME}:${CONTAINER_DP_DIR}/"
  echo "• Logs: docker logs -f ${ORACLE_CONTAINER_NAME}"
  echo

  unset FORCE_ORACLE_WIPE
  set_tab_title "Ready: Oracle Menu"
}

import_postgresql() {
  echo "Choose a database to import:"
  echo "1. Balearia      2. Church Mutual   3. DPESP"
  echo "4. Jessa          5. Otis            6. Ovam"
  echo "7. RWTH Aachen    8. Sapphire        9. Lee Health"
  echo "10. Antel         11. Other"
  read -p "Enter your choice: " import_choice
  
  local dump_file=""
  local alteration_sql=""
  local apply_boolean_fixes=false
  TARGET_DB=""
  MODL_CODE=""

  case $import_choice in
    1) dump_file="25Q2_Balearia_dump.sql"; TARGET_DB="balearia_db"; MODL_CODE="balearia" ;;
    2) dump_file="24Q3_ChurchMutual_database_dump.sql"; TARGET_DB="churchmutual_db"; MODL_CODE="churchmutual"
       alteration_sql="ALTER TABLE public.cpdefinition_x_20102 ALTER COLUMN cpdefinitionid SET NOT NULL;"
       apply_boolean_fixes=true ;;
    3) dump_file="25Q3_dpesp_dump_20251013.sql"; TARGET_DB="dpesp_db"; MODL_CODE="dpesp" ;;
    4) dump_file="24Q4_Jessa_database_dump.sql"; TARGET_DB="jessa_db"; MODL_CODE="jessa" ;;
    5) dump_file="2025Q1_lportal-postgresql-2025.q1.14-08182025.sql"; TARGET_DB="otis_db"; MODL_CODE="otis" ;;
    6) dump_file="24Q3_OVAM_database_dump.sql"; TARGET_DB="ovam_db"; MODL_CODE="ovam" ;;
    7) dump_file="25Q1_RWTH_database_dump.sql"; TARGET_DB="rwth_db"; MODL_CODE="rwth" ;;
    8) dump_file="25Q1_sapphire-postgres-20250415.sql"; TARGET_DB="sapphire_db"; MODL_CODE="sapphire"
       alteration_sql="ALTER TABLE public.cpdefinition_x_20097 ALTER COLUMN cpdefinitionid SET NOT NULL;" ;;
    9) dump_file="25Q1_lee_health_dump-2025-12-30.zip"; TARGET_DB="lee_health_db"; MODL_CODE="lee-health" ;;
    10) dump_file="antel-database-dump.zip"; TARGET_DB="antel_db"; MODL_CODE="antel" ;;
    11) read -p "Enter path to SQL/ZIP: " dump_file
        TARGET_DB="custom_pg_db"; MODL_CODE="custom-pg" ;;
    *) echo "Invalid choice!"; return 1 ;;
  esac

  CURRENT_IMPORT_NAME="$dump_file"

  if [[ ! -f "$dump_file" ]]; then
    echo "Error: Dump file $dump_file not found! ⚠️"
    return 1
  fi

  echo "Recreating database $TARGET_DB..."
  docker exec -i postgresql_db psql -U root -d postgres -c "DROP DATABASE IF EXISTS $TARGET_DB;"
  docker exec -i postgresql_db psql -U root -d postgres -c "CREATE DATABASE $TARGET_DB;"

  echo "🚀 Streaming $dump_file into $TARGET_DB..."

  if type set_tab_title &>/dev/null; then
      set_tab_title "Copying: SQL ($TARGET_DB)"
  fi

  # 1. Determine extraction command
  local ext_cmd="cat \"$dump_file\""
  if [[ "$dump_file" == *.zip ]]; then
    ext_cmd="unzip -p \"$dump_file\""
  elif [[ "$dump_file" == *.gz ]]; then
    ext_cmd="gunzip -c \"$dump_file\""
  fi

  set_tab_title "Importing: PSQL ($TARGET_DB)"

  # 2. Execute Stream with specific filters for Lee Health anomalies
  # We use grep -v to completely drop lines that are EXACTLY "\restrict" or "\unrestrict"
  eval "$ext_cmd" | grep -v '^\\restrict$' | grep -v '^\\unrestrict$' | \
  docker exec -i postgresql_db psql -U root -d "$TARGET_DB" -v ON_ERROR_STOP=0 --quiet

  # 3. Capture the exit code of the Docker command specifically
  local import_status=${PIPESTATUS[3]}

  if [ "$import_status" -eq 0 ]; then
    echo "Database import finished! 🎉 (Note: 'role does not exist' errors above are harmless and expected)"
    
    # Fix search path
    docker exec -i postgresql_db psql -U root -d "$TARGET_DB" -c "ALTER USER root SET search_path TO \"\$user\", public;"
    
    if [[ -n "$alteration_sql" ]]; then
      echo "Running post-import table alterations..."
      docker exec -i postgresql_db psql -U root -d "$TARGET_DB" -c "$alteration_sql"
    fi
  else
    echo "Error: Database stream failed with status $import_status! ❌"
    return 1
  fi

  # 4. Global Boolean Fixes
  if [ "$apply_boolean_fixes" = true ]; then
      echo "Applying global boolean type fixes..."
      local boolean_sql="
        ALTER TABLE public.company ALTER COLUMN system_ TYPE boolean USING (CASE WHEN system_ = 'Y' THEN true WHEN system_ = 'N' THEN false ELSE NULL END);
        ALTER TABLE public.dlfilerank ALTER COLUMN active_ TYPE boolean USING (CASE WHEN active_ = 'Y' THEN true WHEN active_ = 'N' THEN false ELSE NULL END);
        ALTER TABLE public.oauth2application 
          ALTER COLUMN rememberdevice TYPE boolean USING (CASE WHEN rememberdevice = 'Y' THEN true WHEN rememberdevice = 'N' THEN false ELSE NULL END), 
          ALTER COLUMN trustedapplication TYPE boolean USING (CASE WHEN trustedapplication = 'Y' THEN true WHEN trustedapplication = 'N' THEN false ELSE NULL END);
      "
      docker exec -i postgresql_db psql -U root -d "$TARGET_DB" -c "$boolean_sql"
  fi
  
  # Export the TARGET_DB so the upgrade function knows what to use
  export CURRENT_TARGET_DB="$TARGET_DB"
  set_tab_title "Imported: PSQL ($TARGET_DB)"
}

import_sqlserver() {
  echo "--- SQL Server Management ---"
  echo "1. List/Upgrade Existing Databases"
  echo "2. Import New .bak File"
  read -rp "Enter choice: " mode

  if [[ "$mode" == "1" ]]; then
    select_existing_sqlserver_db && return 0
  fi

  echo "Proceeding to Import New..."

  declare -A db_names=( [1]="Brinks" [2]="Kubota" [3]="Zain" )
  declare -A db_files=( [1]="24Q3_Brinks_database_dump.bak" [2]="24Q1_Kubota_database_dump.bak" [3]="23Q4_Zain_database_dump.bak" )
  declare -A db_logical=( [1]="cportal_72" [2]="liferay" [3]="zainCommerce212" )

  for i in 1 2 3; do echo "$i. ${db_names[$i]} --> ${db_files[$i]}"; done
  echo "4. Other"
  read -rp "Enter choice: " sub_choice

  if [[ "$sub_choice" =~ ^[1-3]$ ]]; then
    # Converts 'Brinks' to 'brinks_db', etc.
    TARGET_DB="${db_names[$sub_choice],,}_db"
    DUMP_FILE="${db_files[$sub_choice]}"
    LOGICAL_NAME="${db_logical[$sub_choice]}"
    local move_clauses="MOVE '$LOGICAL_NAME' TO '/var/opt/mssql/data/${TARGET_DB}.mdf', MOVE '${LOGICAL_NAME}_log' TO '/var/opt/mssql/data/${TARGET_DB}_log.ldf'"
  elif [[ "$sub_choice" == "4" ]]; then
    read -rp "Enter path to .bak: " DUMP_FILE
    TARGET_DB="custom_sql_db"
    local move_clauses="MOVE 'liferay' TO '/var/opt/mssql/data/custom.mdf', MOVE 'liferay_log' TO '/var/opt/mssql/data/custom_log.ldf'"
  else
    echo "❌ Invalid choice."
    return 1
  fi

  # 🚀 NEW: Safely wipe the targeted database before restoring the new .bak
  echo "🧹 Cleaning up existing database [$TARGET_DB] (if it exists)..."
  docker exec -i sqlserver_db /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'R00t@1234' -Q "
    IF DB_ID('$TARGET_DB') IS NOT NULL 
    BEGIN 
        ALTER DATABASE [$TARGET_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE [$TARGET_DB]; 
    END
  " > /dev/null 2>&1

  # Now it's safe to continue with your docker cp and RESTORE commands...
  if type set_tab_title &>/dev/null; then
      set_tab_title "Copying: SQL ($TARGET_DB)"
  fi

  docker exec -i sqlserver_db mkdir -p /var/opt/mssql/backup
  echo "🚚 Copying backup to container..."
  docker cp "$DUMP_FILE" sqlserver_db:/var/opt/mssql/backup/

  echo "🚀 Restoring SQL Server database as '$TARGET_DB'..."

  set_tab_title "Importing: SQL ($TARGET_DB)"

  docker exec -i sqlserver_db /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U SA -P 'R00t@1234' -C \
    -Q "IF EXISTS (SELECT name FROM sys.databases WHERE name = '$TARGET_DB') 
          ALTER DATABASE [$TARGET_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        RESTORE DATABASE [$TARGET_DB] FROM DISK = '/var/opt/mssql/backup/$(basename "$DUMP_FILE")' 
        WITH $move_clauses, REPLACE;
        ALTER DATABASE [$TARGET_DB] SET MULTI_USER;"

  if [ $? -eq 0 ]; then
    echo "⚙️ Enabling Read Committed Snapshot for $TARGET_DB..."
    docker exec -i sqlserver_db /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U SA -P 'R00t@1234' -C \
      -Q "ALTER DATABASE [$TARGET_DB] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;"
    
    docker exec -i sqlserver_db rm "/var/opt/mssql/backup/$(basename "$DUMP_FILE")"

    set_tab_title "Imported: SQL ($TARGET_DB)"
    
    upgrade_liferay_tomcat "$TARGET_DB" "$TARGET_DB" "$sub_choice" "sqlserver"
  else
    echo "❌ Restore failed."
    return 1
  fi
}

select_existing_oracle_db() {
  echo "🔍 Querying Oracle for existing Liferay schemas..."

  local raw_output=$(docker exec -i oracle_db sqlplus -S / as sysdba <<EOF
    SET FEEDBACK OFF
    SET PAGESIZE 0
    SET HEADING OFF
    SET VERIFY OFF
    SET LINESIZE 200
    ALTER SESSION SET CONTAINER = FREEPDB1;
    SELECT username FROM dba_users 
    WHERE username NOT IN ('SYS','SYSTEM','PDBADMIN','OUTLN','DBSNMP','APPQOSSYS','DVSYS','DVF','AUDSYS','LBACSYS','GSMADMIN_INTERNAL','XDB','WMSYS','OJVMSYS','CTXSYS','ORDSYS','ORDDATA','MDSYS','OLAPSYS','MDDATA','SPATIAL_WFS_ADMIN_USR','SPATIAL_CSW_ADMIN_USR','GSMCATUSER','GSMUSER','GSMROOTUSER','DIP','REMOTE_SCHEDULER_AGENT','DGPDB_INT','SYSBACKUP','SYSDG','SYSKM','SYSRAC','SYS$UMF','XS\$NULL','VECSYS','BAASSYS','GGSYS','ANONYMOUS','MDDATA')
    AND username NOT LIKE 'APEX_%'
    AND username NOT LIKE 'FLOWS_%'
    ORDER BY username;
    EXIT;
EOF
)

  local schemas=()
  while read -r line; do
    clean_line=$(echo "$line" | tr -d '\r' | xargs)

    if [[ -n "$clean_line" && ! "$clean_line" =~ "Session" && ! "$clean_line" =~ "Connected" ]]; then
       if [[ "$clean_line" =~ ^[A-Z0-9_]+$ ]]; then
          schemas+=("$clean_line")
       fi
    fi
  done <<< "$raw_output"

  if [ ${#schemas[@]} -eq 0 ]; then
    echo "❌ No Liferay schemas found in Oracle."
    echo "Full output from Oracle was:"
    echo "$raw_output"
    return 1
  fi

  echo "Select an Oracle schema to upgrade:"
  for i in "${!schemas[@]}"; do
    printf "%2d. %s\n" $((i+1)) "${schemas[$i]}"
  done
  echo "$(( ${#schemas[@]} + 1 )). [Back to Menu]"

  read -rp "Enter choice: " SCHEMA_CHOICE

  if [[ "$SCHEMA_CHOICE" -eq $(( ${#schemas[@]} + 1 )) ]]; then
    return 0
  fi

  local selected_schema="${schemas[$((SCHEMA_CHOICE-1))]}"
  if [[ -n "$selected_schema" ]]; then
      if [[ "$selected_schema" == "LPORTAL" ]]; then
          echo "LPORTAL schema detected. Which project is this for?"
          echo "1. Cuscal"
          echo "2. Tokio Marine"
          read -rp "Enter choice [1-2]: " PROJECT_CHOICE

          if [[ "$PROJECT_CHOICE" == "1" ]]; then
              PROJECT_NAME="CUSCAL"
          else
              PROJECT_NAME="TOKIO"
          fi
      else
          PROJECT_NAME="$selected_schema"
      fi

      echo "✅ Selected Schema: $selected_schema"
      echo "📂 Project Folder Name: ${PROJECT_NAME}-bundle"

      TARGET_DB="$selected_schema" 

      upgrade_liferay_tomcat "$PROJECT_NAME" "$selected_schema" 12 "oracle"
  else
      echo "❌ Invalid selection."
  fi
}

select_existing_sqlserver_db() {
  echo "🔍 Querying SQL Server for existing databases..."
  
  # Fetch list of user databases
  local db_list=$(docker exec -i sqlserver_db /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U SA -P 'R00t@1234' -C -W -h -1 \
    -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name NOT IN ('master', 'tempdb', 'model', 'msdb');")

  if [[ -z "$db_list" ]]; then
    echo "⚠️ No existing user databases found."
    return 1
  fi

  echo "Select an existing database to upgrade:"
  local i=1
  local dbs=()
  while read -r line; do
    [[ -z "$line" ]] && continue
    echo "$i. $line"
    dbs[$i]=$line
    ((i++))
  done <<< "$db_list"
  echo "$i. [Back to Import Menu]"

  read -rp "Enter choice: " db_choice
  
  if [[ "$db_choice" -eq "$i" ]]; then
    return 1
  elif [[ -n "${dbs[$db_choice]}" ]]; then
    TARGET_DB="${dbs[$db_choice]}"
    echo "✅ Selected: $TARGET_DB"
    
    # FIX: Change $SELECTED_DB to $TARGET_DB
    upgrade_liferay_tomcat "$TARGET_DB" "$TARGET_DB" "1" "sqlserver"
    return 0
  else
    echo "❌ Invalid selection."
    return 1
  fi
}

run_postgresql() {
  echo "Checking PostgreSQL container status..."

  # 1. Check if the container exists
  if docker ps -a --format '{{.Names}}' | grep -Eq "^postgresql_db$"; then
    
    # 2. Check if it is currently running
    if [ "$(docker inspect -f '{{.State.Running}}' postgresql_db)" = "true" ]; then
      echo "Container 'postgresql_db' is already running. Reusing for parallel upgrades! ♻️"
    else
      echo "Container 'postgresql_db' exists but is stopped. Starting it..."
      docker start postgresql_db
      
      echo "⏳ Waiting for PostgreSQL to wake up... ⏳"
      until docker exec postgresql_db pg_isready -U root -h localhost > /dev/null 2>&1; do
        sleep 2
      done
      echo "PostgreSQL container started successfully!"
    fi

  else
    # 3. Container does not exist, build it fresh
    echo "Starting new PostgreSQL container..."
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
      echo "❌ Failed to start PostgreSQL container."
      return 1
    fi
  fi

  # 4. Role Loop: Ensure common roles exist (Safe to run multiple times)
  echo "Ensuring required roles exist..."
  local common_roles=("liferay" "portal" "pgadmin" "db_user" "admin" "liferay_user")

  for role in "${common_roles[@]}"; do
    docker exec -i postgresql_db psql -U root -d postgres -c \
      "DO \$\$ 
       BEGIN 
         IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$role') THEN 
           CREATE ROLE $role WITH LOGIN PASSWORD '$role' SUPERUSER; 
         END IF; 
       END \$\$;" > /dev/null 2>&1
  done

  echo "Roles verified. PostgreSQL is ready for import. ✅"
  set_tab_title "Ready: PostgreSQL Menu"
}

run_sqlserver() {
  echo "Checking SQL Server container status..."

  # 1. Check if the container exists
  if docker ps -a --format '{{.Names}}' | grep -Eq "^sqlserver_db$"; then
    
    # 2. Check if it is currently running
    if [ "$(docker inspect -f '{{.State.Running}}' sqlserver_db)" = "true" ]; then
      echo "Container 'sqlserver_db' is already running. Reusing for parallel upgrades! ♻️"
    else
      echo "Container 'sqlserver_db' exists but is stopped. Starting it..."
      docker start sqlserver_db
      
      echo "⏳ Waiting for SQL Server to wake up... ⏳"
      # Microsoft uses different paths for sqlcmd depending on the image year, we try both to be safe
      until docker exec sqlserver_db bash -c "/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'R00t@1234' -Q 'SELECT 1' > /dev/null 2>&1 || /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'R00t@1234' -C -Q 'SELECT 1' > /dev/null 2>&1"; do
        sleep 2
      done
      echo "SQL Server container started successfully!"
    fi

  else
    # 3. Container does not exist, build it fresh
    echo "Starting new SQL Server container..."
    docker run --name sqlserver_db -d \
      -e 'ACCEPT_EULA=Y' \
      -e 'SA_PASSWORD=R00t@1234' \
      -e 'MSSQL_PID=Developer' \
      -p 1433:1433 \
      --memory=8g \
      --cpus=2 \
      mcr.microsoft.com/mssql/server:2022-latest

    if [ $? -eq 0 ]; then
      echo "⏳ Waiting for SQL Server to be ready... ⏳"
      until docker exec sqlserver_db bash -c "/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'R00t@1234' -Q 'SELECT 1' > /dev/null 2>&1 || /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'R00t@1234' -C -Q 'SELECT 1' > /dev/null 2>&1"; do
        sleep 2
      done
      echo "SQL Server container started successfully!"
    else
      echo "❌ Failed to start SQL Server container."
      return 1
    fi
  fi
}

setup_and_import_mysql() {
  local NETWORK_NAME="my_app_network"
  local MYSQL_CONTAINER_NAME="mysql_db"
  local TARGET_DB ZIP_FILE MODL_CODE

  trap cleanup EXIT SIGINT SIGTERM

  debug() { [ "$DEBUG" = "true" ] && echo "[DEBUG] $@" >&2; }

  echo 'Choose a database to import:'
  echo '1) Actinver     6) IPC            11) TUDelft'
  echo '2) APCOA        7) Metos          12) e5a2 (LXC)'
  echo '3) Argus        8) OPAP           13) Custom Path'
  echo '4) Bosch        9) TBG Internet   14) DXP Cloud (LPD)'
  echo '5) CNO Bizlink 10) TBG Intranet'
  read -rp 'Enter choice: ' CHOICE

  alteration_sql=""

  case "$CHOICE" in
    1) TARGET_DB="actinver_db"; ZIP_FILE="24Q1_Actinver_database_dump.zip"; MODL_CODE="actinver" ;;
    2) TARGET_DB="apcoa_db";    ZIP_FILE="24Q2_APCOA_database_dump.sql";    MODL_CODE="apcoa" ;;
    3) TARGET_DB="argus_db";    ZIP_FILE="24Q2_Argus_database_dump.sql";    MODL_CODE="argus" ;;
    4) TARGET_DB="bosch_db";    ZIP_FILE="25Q2_bosch_dump.sql";             MODL_CODE="bosch" ;;
    5) TARGET_DB="cno_bizlink_db"; ZIP_FILE="25Q1_cno-bspn-2025.qx.22012026.zip"; MODL_CODE="cno-bizlink" ;;
    6) TARGET_DB="ipc_db";      ZIP_FILE="25Q1_ipc_dump_2025-05-05-164823.zip"; MODL_CODE="ipc" ;;
    7) TARGET_DB="metos_db";    ZIP_FILE="24Q3_Metos_database_dump.zip";    MODL_CODE="metos"
       alteration_sql="DROP TABLE IF EXISTS ctscore; DROP TABLE IF EXISTS exportimportreportentry; DELETE FROM Configuration_ WHERE configurationId = 'com.liferay.portal.tika.internal.configuration.TikaConfiguration';" ;;
    8) TARGET_DB="opap_db";     ZIP_FILE="2025Q1_opap_merged_dump_2025-09-04.sql"; MODL_CODE="opap" ;;
    9) TARGET_DB="tbg_internet"; ZIP_FILE="25Q3_tbg_internet_dump.sql";     MODL_CODE="tbg-internet" ;;
    10) TARGET_DB="tbg_intranet"; ZIP_FILE="25Q3_tbg_intranet_dump.sql";    MODL_CODE="tbg-intranet" ;;
    11) TARGET_DB="tudelft_db";  ZIP_FILE="24Q1_TUDelft_database_dump.sql"; MODL_CODE="tudelft" ;;
    12) TARGET_DB="lportal"      ZIP_FILE="25Q4_lxce5a2-e5a2prd.gz"              MODL_CODE="e5a2" ;;
    13) read -rp "Custom dump path: " ZIP_FILE; read -rp "Target DB Name: " TARGET_DB; MODL_CODE="custom-project" ;;
    14) 
      TARGET_DB="lportal"
      read -rp "LPD Ticket (e.g. LPD-52788): " LPD_TICKET
      read -rp "MODL code (e.g. r8k1): " MODL_CODE
      DOCKER_IMAGE="liferay/database-upgrades:$LPD_TICKET"; IS_DXP_CLOUD=true ;;
    *) echo "Invalid choice!"; return 1 ;;
  esac

  # --- FIX 1: Ensure Turbo Engine is running ---
  if ! docker ps --filter "name=^${MYSQL_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER_NAME}$"; then
      run_mysql_engine
  elif [[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER_NAME")" == "false" ]]; then
      echo "⏳ Starting stopped MySQL container..."
      docker start "$MYSQL_CONTAINER_NAME"
  fi

  smart_import "$ZIP_FILE" "$TARGET_DB"

  if [ -n "$alteration_sql" ]; then
    echo "🛠️ Applying Pre-Upgrade Patches..."
    docker exec -i "$MYSQL_CONTAINER_NAME" mysql -u root -D "$TARGET_DB" -e "SET FOREIGN_KEY_CHECKS=0; $alteration_sql"
  fi

  # --- FIX 4: Correct Parameter Order ---
  # $1=FolderID (MODL_CODE), $2=Schema (TARGET_DB), $3=Choice, $4=DBType
  upgrade_liferay_tomcat "$MODL_CODE" "$TARGET_DB" "$CHOICE" "mysql"
}

setup_and_import_oracle() {
    echo "--- Oracle Database Setup & Import ---"
    
    # 1. Start the engine with wipe mode enabled for fresh imports
    FORCE_ORACLE_WIPE=1 run_oracle
    if [ $? -ne 0 ]; then
        echo "❌ Oracle container failed to start or timed out. Aborting."
        return 1
    fi
    
    # 2. Run the import process
    import_oracle
    local import_status=$?
    
    if [ $import_status -ne 0 ]; then
        echo "❌ Oracle import failed. Aborting upgrade."
        return 1
    fi

    # 3. Map the user's choice from import_oracle to the folder name
    local PROJECT_NAME="CUSTOM"
    case "$import_choice" in
        1) PROJECT_NAME="CUSCAL" ;;
        2) PROJECT_NAME="TOKIO" ;;
    esac

    TARGET_DB="LPORTAL"
    DB_TYPE="oracle"
    
    # 4. Trigger the Tomcat upgrade
    upgrade_liferay_tomcat "$PROJECT_NAME" "$TARGET_DB" "$import_choice" "oracle"
}

run_mysql_engine() {
    local MYSQL_CONTAINER_NAME="mysql_db"
    local NETWORK_NAME="my_app_network"
    
    # Ensure network exists
    docker network ls | grep -q "$NETWORK_NAME" || docker network create "$NETWORK_NAME"

    echo "🚀 Initializing Turbo-Charged MySQL Engine..."
    
    docker run -d \
          --name "$MYSQL_CONTAINER_NAME" \
          -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
          -e MYSQL_DATABASE=lportal \
          -p 3306:3306 \
          --network "$NETWORK_NAME" \
          --memory=8g \
          --cpus=4 \
          mysql:8.0 \
          --default-time-zone='GMT' \
          --innodb_buffer_pool_size=4G \
          --innodb_log_file_size=1G \
          --innodb_flush_log_at_trx_commit=0 \
          --innodb_doublewrite=0 \
          --innodb_io_capacity=2000 \
          --innodb_write_io_threads=8 \
          --max-allowed-packet=1G \
          --wait-timeout=6000 \
          --sync_binlog=0 \
          --lower_case_table_names=1

    echo "⏳ Waiting for MySQL to finish initialization bounce..."
    set_tab_title "Starting: MySQL Engine"

    # 1. Wait for the final TCP port bind log entry (Bypasses the "Init Bounce")
    local max_attempts=40
    local attempt=1
    until docker logs "$MYSQL_CONTAINER_NAME" 2>&1 | grep -q "port: 3306  MySQL Community Server"; do
        if [[ $attempt -gt $max_attempts ]]; then
            echo -e "\n❌ Error: MySQL startup timeout. Run 'docker logs $MYSQL_CONTAINER_NAME' to investigate." >&2
            return 1
        fi
        printf "  Initializing (waiting for Phase 2)... attempt %d/%d\r" "$attempt" "$max_attempts"
        sleep 3
        ((attempt++))
    done

    # 2. Final Socket Verification (Just to be 100% sure the socket is accepting commands)
    until docker exec "$MYSQL_CONTAINER_NAME" mysql -u root -e "SELECT 1;" > /dev/null 2>&1; do
        printf "  Verifying internal socket connection...               \r"
        sleep 2
    done

    echo -e "\n✅ Engine is fully initialized, stable, and responsive!"
    sleep 2
    set_tab_title "Ready: MySQL Menu"
}

smart_import() {
  local file=$1
  local db=$2
  local container="mysql_db"
  local pwd_arg=""
  [[ -n "$MYSQL_ROOT_PASSWORD" ]] && pwd_arg="-p$MYSQL_ROOT_PASSWORD"
  local sql_init="SET SESSION UNIQUE_CHECKS=0; SET SESSION FOREIGN_KEY_CHECKS=0; SET SESSION SQL_LOG_BIN=0;"
  
  # Ensure target database exists
  docker exec -i "$container" mysql -u root $pwd_arg -e "CREATE DATABASE IF NOT EXISTS \`$db\`;"

  echo "🚀 Streaming $file into $db..."

  set_tab_title "Importing: MySQL ($db)"

  if [[ "$file" == *.gz ]]; then
      # Decompress on host, pipe to container mysql
      gunzip -c "$file" | pv -N "Importing" | docker exec -i "$container" mysql -u root $pwd_arg --force --max-allowed-packet=1G --binary-mode --init-command="$sql_init" "$db"
  elif [[ "$file" == *.zip ]]; then
      # Unzip on host, pipe to container mysql
      unzip -p "$file" | pv -N "Importing" | docker exec -i "$container" mysql -u root $pwd_arg --force --max-allowed-packet=1G --binary-mode --init-command="$sql_init" "$db"
  else
      # Pipe SQL file directly
      pv "$file" | docker exec -i "$container" mysql -u root $pwd_arg --force --max-allowed-packet=1G --binary-mode --init-command="$sql_init" "$db"
  fi

  echo -e "\n✅ Import Complete."
  set_tab_title "Imported: MySQL ($db)"
}

cleanup() {
  local exit_code=$?
  if [[ -f "/tmp/mysql.cnf" || -d "${temp_dir:-/dev/null}" ]]; then
    echo -e "\n🧹 Cleaning up temporary files..."
    rm -f /tmp/mysql.cnf
    [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf "$temp_dir"
  fi
  
  exit $exit_code
}

upgrade_liferay_tomcat() {
  local folder_id=$1
  local schema_name=$2
  local sub_choice=$3
  local db_type=$4

  if [[ -z "$folder_id" ]]; then folder_id="$schema_name"; fi
  if [[ -z "$folder_id" || "$folder_id" == "N/A" ]]; then
      echo "❌ ERROR: No database/folder name provided to upgrade function."
      return 1
  fi

  local BUNDLE_DIR="./${folder_id}-bundle"
  LIFERAY_HOME_ABS="$(pwd)/${folder_id}-bundle"
  TARGET_DB="$schema_name"
  DB_TYPE="$db_type"
  local MODL_CODE="$folder_id"

  # Port Calculation
  # Note: Ensure CHOICE is exported globally from your main menu!
  local PORT_OFFSET=$(( (${CHOICE:-0} * 1000) + (sub_choice * 100) ))
  local HTTP_PORT=$(( 10000 + PORT_OFFSET + 80 ))
  local SHUT_PORT=$(( 10000 + PORT_OFFSET + 5 ))
  local REDI_PORT=$(( 10000 + PORT_OFFSET + 43 ))
  local ES_PORT=$(( 10000 + PORT_OFFSET + 201 ))
  local ES_TCP_PORT=$(( ES_PORT + 100 ))  # FIX 1: Added missing TCP port calculation
  local GOGO_PORT=$(( 10000 + PORT_OFFSET + 311 ))

  # Partition Logic
  local final_partition_setting="false"
  if [[ "$MODL_CODE" == "e5a2" ]]; then
      final_partition_setting="true"
  fi

  local JDBC_DRIVER=""
  local JDBC_URL=""
  local JDBC_JAR_PREFIX=""
  local DB_USER="root"
  local DB_PWD="${MYSQL_ROOT_PASSWORD:-}"

  case "$DB_TYPE" in
    "postgres")
      JDBC_DRIVER="org.postgresql.Driver"
      JDBC_URL="jdbc:postgresql://localhost:5433/${schema_name}"
      JDBC_JAR_PREFIX="postgresql"
      DB_PWD=""
      ;;
    "sqlserver")
      JDBC_DRIVER="com.microsoft.sqlserver.jdbc.SQLServerDriver"
      JDBC_URL="jdbc:sqlserver://localhost:1433;databaseName=${TARGET_DB};trustServerCertificate=true;"
      JDBC_JAR_PREFIX="mssql-jdbc"
      DB_USER="sa"
      DB_PWD="R00t@1234"
      ;;
    "oracle")
      JDBC_DRIVER="oracle.jdbc.OracleDriver"
      JDBC_URL="jdbc:oracle:thin:@//localhost:1521/FREEPDB1"
      JDBC_JAR_PREFIX="ojdbc"
      DB_USER="${TARGET_DB^^}"
      DB_PWD="${TARGET_DB^^}"
      ;;
    *) # MySQL
      JDBC_DRIVER="com.mysql.cj.jdbc.Driver"
      JDBC_URL="jdbc:mysql://localhost:3306/${schema_name}?characterEncoding=UTF-8&dontTrackOpenResources=true&holdResultsOpenOverStatementClose=true&serverTimezone=GMT&useFastDateParsing=false&useUnicode=true"
      JDBC_JAR_PREFIX="mysql-connector"
      ;;
  esac

  echo "---------------------------------------------------"
  echo "🚀 Upgrading: $TARGET_DB | Home: $LIFERAY_HOME_ABS"
  echo "🌐 Ports: HTTP:$HTTP_PORT | ES:$ES_PORT | Gogo:$GOGO_PORT"
  echo "---------------------------------------------------"

  # Extraction
  # Added -type f to ensure we only grab files, not directories
  local TOMCAT_ARCHIVE=$(find . -maxdepth 1 -type f \( -name "*liferay-dxp-tomcat-*" -o -name "*${MODL_CODE}*.tar*" -o -name "*${MODL_CODE}*.zip" -o -name "liferay-fixed.zip" \) | grep -Ei -v "dump|mysql|postgres|oracle|sql|backup" | head -n 1)
  
  # Safety check: Did we actually find a file?
  if [[ -z "$TOMCAT_ARCHIVE" ]]; then
      echo "❌ Error: Could not find a Liferay Tomcat archive (.tar, .tar.gz, or .zip) to extract."
      return 1 
  fi

  if [[ -d "$BUNDLE_DIR" ]]; then rm -rf "$BUNDLE_DIR"; fi
  
  echo "📦 Extracting $TOMCAT_ARCHIVE into $BUNDLE_DIR..."
  mkdir -p "$BUNDLE_DIR"
  
  # Changed tar -xzf to tar -xf to support both .tar and .tar.gz safely
  if [[ "$TOMCAT_ARCHIVE" == *.zip ]]; then 
      unzip -oq "$TOMCAT_ARCHIVE" -d "$BUNDLE_DIR"
  else 
      tar -xf "$TOMCAT_ARCHIVE" -C "$BUNDLE_DIR" --strip-components=1
  fi

  mkdir -p "$BUNDLE_DIR/data/document_library"
  local SHIELDED_LIB="$BUNDLE_DIR/tomcat/webapps/ROOT/WEB-INF/shielded-container-lib"
  
  if [[ -n "$JDBC_JAR_PREFIX" ]]; then
      local FOUND_JAR=$(find . -maxdepth 1 -type f -name "${JDBC_JAR_PREFIX}*.jar" | head -n 1)
      if [[ -f "$FOUND_JAR" ]]; then cp "$FOUND_JAR" "$SHIELDED_LIB/"; fi
  fi

  local SERVER_XML="$BUNDLE_DIR/tomcat/conf/server.xml"
  if [[ -f "$SERVER_XML" ]]; then
      sed -i "s/port=\"8005\"/port=\"$SHUT_PORT\"/g" "$SERVER_XML"
      sed -i "s/port=\"8080\"/port=\"$HTTP_PORT\"/g" "$SERVER_XML"
      sed -i "s/redirectPort=\"8443\"/redirectPort=\"$REDI_PORT\"/g" "$SERVER_XML"
  fi

  if [[ "$db_type" == "mysql" ]]; then
      echo "👤 Ensuring 'dxpcloud' user exists in MySQL..."
      docker exec -i mysql_db mysql -u root ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} -e "CREATE USER IF NOT EXISTS 'dxpcloud'@'%' IDENTIFIED BY ''; GRANT ALL PRIVILEGES ON *.* TO 'dxpcloud'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;"
  fi

  local upgrade_tool_dir="$BUNDLE_DIR/tools/portal-tools-db-upgrade-client"
  mkdir -p "$upgrade_tool_dir"

  # 📝 Writing Configuration Files
  cat > "$upgrade_tool_dir/portal-upgrade-ext.properties" <<EOF
jdbc.default.driverClassName=$JDBC_DRIVER
jdbc.default.url=$JDBC_URL
jdbc.default.username=$DB_USER
jdbc.default.password=$DB_PWD
liferay.home=${LIFERAY_HOME_ABS}
database.partition.enabled=$final_partition_setting
upgrade.database.dl.storage.check.disabled=true
upgrade.database.gogo.shell.port=${GOGO_PORT}
module.framework.properties.osgi.console=127.0.0.1:${GOGO_PORT}
EOF
  # FIX 2: Added the GOGO_PORT properties back into the config file above ^

  if [[ "$MODL_CODE" == "e5a2" ]]; then
      cat >> "$upgrade_tool_dir/portal-upgrade-ext.properties" <<EOF
company.default.web.id=admin-${MODL_CODE}.lxc.liferay.com
EOF
  fi

  cp "$upgrade_tool_dir/portal-upgrade-ext.properties" "$upgrade_tool_dir/portal-upgrade-database.properties"

  cat > "$upgrade_tool_dir/app-server.properties" <<EOF
dir=${LIFERAY_HOME_ABS}/tomcat
extra.lib.dirs=bin
global.lib.dir=lib
portal.dir=webapps/ROOT
server.detector.server.id=tomcat
EOF

  local heap_size="4096m"
  if [[ "$TARGET_DB" == "brinks_db" || "$TARGET_DB" == "lportal" ]]; then heap_size="8192m"; fi

  local osgi_config_dir="$BUNDLE_DIR/osgi/configs"
  mkdir -p "$osgi_config_dir"
  cat > "$osgi_config_dir/com.liferay.portal.search.elasticsearch7.configuration.ElasticsearchConfiguration.config" <<EOF
sidecarHttpPort="${ES_PORT}"
sidecarTcpPort="${ES_TCP_PORT}"
EOF
  cat > "$osgi_config_dir/com.liferay.portal.search.elasticsearch8.configuration.ElasticsearchConfiguration.config" <<EOF
sidecarHttpPort="${ES_PORT}"
sidecarTcpPort="${ES_TCP_PORT}"
EOF

  # FIX 3: Cleaned up JVM args since Gogo is handled in properties file now
  local jvm_args="-Xmx${heap_size} -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Dfile.encoding=UTF-8 -Duser.timezone=GMT"

  # 5. EXECUTION
  read -rp "Run upgrade script now for $TARGET_DB? (y/n): " RUN_NOW
  if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
      echo "🏃 Starting Upgrade Client ($TARGET_DB)..."
      cd "$upgrade_tool_dir" || return 1
      
      if type set_tab_title &>/dev/null; then
          set_tab_title "Upgrading: $TARGET_DB"
      fi
      
      ./db_upgrade_client.sh -j "$jvm_args"
      
      if type set_tab_title &>/dev/null; then
          set_tab_title "Upgraded: $TARGET_DB"
      fi
      cd - >/dev/null

      echo "🧹 Cleaning up temporary files..."
      if [[ -d "$BUNDLE_DIR/tomcat" ]]; then
          rm -rf "$BUNDLE_DIR/tomcat/work"/*
          rm -rf "$BUNDLE_DIR/tomcat/temp"/*
      fi

      echo "✅ Upgrade process finished for $TARGET_DB."
      read -rp "Press Enter to return to the main menu..."
  fi
}

run_upgrade_only() {
    echo ""
    echo "--- Select Database Type for Upgrade ---"
    echo "1. MySQL"
    echo "2. PostgreSQL"
    echo "3. SQL Server"
    echo "4. Oracle"
    echo "B. Back to Main Menu"
    read -p "Enter DB type: " db_choice

    local db_type=""
    case "$db_choice" in
        1) db_type="mysql" ;;
        2) db_type="postgres" ;; 
        3) db_type="sqlserver" ;;
        4) db_type="oracle" ;;
        [Bb]*) return ;;
        *) echo "❌ Invalid choice."; return ;;
    esac

    if [[ "$db_type" == "oracle" ]]; then
        DB_TYPE="oracle"
        FORCE_ORACLE_WIPE=0 run_oracle 
        select_existing_oracle_db
    else
        # --- Dynamic Target DB Name Menu ---
        echo ""
        echo "--- Select Target DB Name ---"
        
        local found_dbs=()
        
        # 🐳 Query the respective Docker container for existing databases
        if [[ "$db_type" == "mysql" ]] && docker ps | grep -q "mysql_db"; then
            # Grab all DBs, ignoring system schemas
            found_dbs=($(docker exec -i mysql_db mysql -uroot ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} -sN -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "^(information_schema|performance_schema|mysql|sys|dxpcloud)$"))
        
        elif [[ "$db_type" == "postgres" ]] && docker ps | grep -q "postgresql_db"; then
            # Grab all non-template DBs, ignoring the default 'postgres' DB
            found_dbs=($(docker exec -i postgresql_db psql -U root -d postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | xargs))
        
        elif [[ "$db_type" == "sqlserver" ]] && docker ps | grep -q "sqlserver_db"; then
            # Grab all DBs, ignoring master, tempdb, etc. (Note: path to sqlcmd might be /opt/mssql-tools18/bin/sqlcmd depending on your image version)
            found_dbs=($(docker exec -i sqlserver_db /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'R00t@1234' -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name NOT IN ('master', 'tempdb', 'model', 'msdb');" 2>/dev/null | tr -d '\r' | grep -v "^\s*$"))
        fi

        local db_idx=1
        if [[ ${#found_dbs[@]} -gt 0 ]]; then
            for db in "${found_dbs[@]}"; do
                echo "$db_idx. $db"
                ((db_idx++))
            done
        else
            echo "⚠️  No imported databases found (or container is not running)."
        fi
        
        echo "$db_idx. Custom (Enter manually)"
        read -p "Enter choice: " db_name_choice
        
        if [[ "$db_name_choice" -eq "$db_idx" ]]; then
            read -rp "Enter custom DB name: " TARGET_DB
        elif [[ "$db_name_choice" -gt 0 && "$db_name_choice" -lt "$db_idx" ]]; then
            TARGET_DB="${found_dbs[$((db_name_choice-1))]}"
        else
            echo "❌ Invalid choice."; return
        fi

        # Auto-guess the MODL code from the database name
        # Strips "_db" from the end, and replaces underscores with hyphens
        local guessed_modl="${TARGET_DB%_db}"
        guessed_modl="${guessed_modl//_/-}"

        # --- Smart MODL Code Menu ---
        echo ""
        echo "--- Select Project / MODL Code ---"
        echo "1. e5a2 (LXC - Partitioned)"
        echo "2. Auto-Detect: $guessed_modl"
        echo "3. Custom (Enter manually)"
        read -p "Enter choice: " modl_choice
        
        case "$modl_choice" in
            1) MODL_CODE="e5a2" ;;
            2) MODL_CODE="$guessed_modl" ;;
            3) read -rp "Enter custom MODL Code: " MODL_CODE ;;
            *) echo "❌ Invalid choice."; return ;;
        esac
        
        echo ""
        echo "Starting upgrade for $TARGET_DB ($db_type) with MODL $MODL_CODE..."
        upgrade_liferay_tomcat "$MODL_CODE" "$TARGET_DB" "6" "$db_type"
    fi
}

stop_drop_containers() {
  echo "---------------------------------------------------"
  echo "🗑️  Which database container would you like to drop?"
  echo "1. SQL Server  (sqlserver_db)"
  echo "2. MySQL       (mysql_db)"
  echo "3. PostgreSQL  (postgresql_db)"
  echo "4. Oracle      (oracle_db)"
  echo "5. ALL of the above 💥"
  echo "6. 🧹 Prune Docker System (Reclaim Hard Drive Space)"
  echo "Q. Cancel"
  echo "---------------------------------------------------"
  read -rp "Enter your choice: " drop_choice

  # Helper function to keep the logic DRY (Don't Repeat Yourself)
  remove_container() {
    local container_name=$1
    if docker ps -aqf name="^${container_name}$" > /dev/null; then
      echo "🛑 Stopping and removing container: $container_name..."
      docker rm -f "$container_name" > /dev/null
      echo "✅ $container_name destroyed."
    else
      echo "ℹ️  Container '$container_name' is not running/does not exist."
    fi
  }

  case "$drop_choice" in
    1) remove_container "sqlserver_db" ;;
    2) remove_container "mysql_db" ;;
    3) remove_container "postgresql_db" ;;
    4) remove_container "oracle_db" ;;
    5) 
       echo "Initiating Factory Reset..."
       remove_container "sqlserver_db"
       remove_container "mysql_db"
       remove_container "postgresql_db"
       remove_container "oracle_db"
       ;;
    6)
       echo "🧹 Pruning unused Docker containers, networks, and volumes..."
       docker system prune -a --volumes -f
       echo "✅ Docker system cleaned."
       ;;
    [Qq]*|"") 
       echo "Canceled." 
       ;;
    *) 
       echo "❌ Invalid choice." 
       ;;
  esac
}

while true; do
  set_tab_title "Menu: DB Upgrades"

  # Disk Space Safety Check (Warn if < 10GB)
  FREE_SPACE=$(df -h . | awk 'NR==2 {print $4}' | sed 's/G//')
  if (( $(echo "$FREE_SPACE < 10" | bc -l) )); then
      echo "⚠️  WARNING: Low disk space ($FREE_SPACE GB remaining). Consider cleaning up old bundles."
  fi

  echo ""
  echo "--- Liferay Upgrade Factory ---"
  echo "1. Setup & Import: SQL Server"
  echo "2. Setup & Import: MySQL"
  echo "3. Setup & Import: PostgreSQL"
  echo "4. Setup & Import: Oracle"
  echo "5. 🚀 Upgrade Existing Imported Database..."
  echo "6. 🗑️  Stop/Drop Database Containers..."
  echo "Q. Quit"
  read -p "Enter choice: " CHOICE

  case "$CHOICE" in
    1) run_sqlserver; import_sqlserver ;;
    2) setup_and_import_mysql ;;
    3) run_postgresql; import_postgresql; upgrade_liferay_tomcat "$MODL_CODE" "$TARGET_DB" "$import_choice" "postgres" ;;
    4) setup_and_import_oracle ;;
    5) run_upgrade_only ;;
    6) stop_drop_containers ;;
    [Qq]*) echo "Goodbye!"; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac

  if [[ "$CHOICE" =~ ^[1-5]$ ]]; then
      echo -e "\n---------------------------------------------------"
      echo "✅ ACTION COMPLETE"
      echo "Target DB:    ${TARGET_DB:-N/A}"
      echo "Liferay Home: ${LIFERAY_HOME_ABS:-Not Setup}"
      echo "---------------------------------------------------"
  fi
done