#!/bin/bash

function check_copyright {
    copyright_text="""/**
 * SPDX-FileCopyrightText: (c) 2026 Liferay, Inc. https://liferay.com
 * SPDX-License-Identifier: LGPL-2.1-or-later OR LicenseRef-Liferay-DXP-EULA-2.0.0-2023-06
 */"""

    if [[ $(< liferay-dxp/license/copyright.txt) == "${copyright_text}" ]]
    then
        echo "PASSED: copyright text matches" >> ${1}validation.txt
    else
        echo "FAILED: copyright text does NOT match" >> ${1}validation.txt
    fi
}

function check_deploy_folder {
    if [ -z "$(ls -A liferay-dxp/deploy)" ]
    then
        echo "PASSED: Deploy is empty" >> ${1}validation.txt
    else
        echo "FAILED: Deploy is NOT empty" >> ${1}validation.txt
    fi
}

function check_githash_file {
    githash=$(<liferay-dxp/.githash)

    if [[ $(<liferay-dxp/.githash) != "" ]]
    then
        echo "PASSED: Git hash matches: $githash" >> ${1}validation.txt
    else
        echo "FAILED: Git hash does NOT match" >> ${1}validation.txt
    fi
}

function check_liferay_home {
    if [ -f liferay-dxp/.liferay-home ]
    then
        echo "PASSED: .liferay-home file exists" >> ${1}validation.txt
    else
        echo "FAILED: .liferay-home file does NOT exist" >> ${1}validation.txt
    fi
}

function check_logs_folder {
    if [ -z "$(ls -A liferay-dxp/logs)" ]
    then
        echo "PASSED: Logs is empty" >> ${1}validation.txt
    else
        echo "FAILED: Logs is NOT empty" >> ${1}validation.txt
    fi
}

function check_lts_version {
    input=${1}
    if [[ "$input" == *"-lts" ]]
    then
        if [[ "${PWD##*/}" == *"-lts"* ]]
        then
            echo "PASSED: LTS version check folder has LTS name" >> ${1}validation.txt
        else
            echo "FAILED: LTS version missing from folder name" >> ${1}validation.txt
        fi
    else
        echo "Check for LTS skip. Not an LTS version"
    fi
}

function check_mysql_jar {
    if [ ! -f liferay-dxp/tomcat/lib/mysql.jar ]
    then
        echo "PASSED: mysql jar is not present" >> ${1}validation.txt
    else
        echo "FAILED: mysql jar is present" >> ${1}validation.txt
    fi
}

function check_osgi_state {
    if [[ -d liferay-dxp/osgi/state/org.eclipse.osgi ]] && [[ "$(find liferay-dxp/osgi/state -maxdepth 1 -printf %y)" == "dd" ]]
    then
        echo "PASSED: org.eclipse.osgi is present" >> ${1}validation.txt
    else
        echo "FAILED: org.eclipse.osgi is NOT present" >> ${1}validation.txt
    fi
}

function check_osgi_marketplace {
    if [[ "$(find liferay-dxp/osgi/marketplace -maxdepth 1 -printf %y)" == "dd" ]]
    then
        if [[ ("$(ls -A liferay-dxp/osgi/marketplace/override)" == "README.md") || ("$(ls -A liferay-dxp/osgi/marketplace/override)" == "README.markdown") ]]
        then
            echo "PASSED: osgi/marketplace/override is present with README.md" >> ${1}validation.txt
        else
            echo "FAILED: Override folder contains more than one file" >> ${1}validation.txt
        fi
    else
        echo "FAILED: osgi/marketplace/override missing folder" >> ${1}validation.txt
    fi
}

function check_osgi_modules {
    if [ -z "$(ls -A liferay-dxp/osgi/modules)" ]
    then
        echo "PASSED: osgi/modules is empty" >> ${1}validation.txt
    else
        echo "FAILED: osgi/modules is NOT empty" >> ${1}validation.txt
    fi
}

function check_osgi_portal {
    if [[ -f liferay-dxp/osgi/portal/com.liferay.users.admin.web.jar ]] && \
        [[ -f liferay-dxp/osgi/portal/com.liferay.site.initializer.welcome.jar ]] && \
        [[ -f liferay-dxp/osgi/portal/com.liferay.portal.search.jar ]] && \
        [[ -f liferay-dxp/osgi/portal/com.liferay.content.dashboard.web.jar ]] && \
        [[ -f liferay-dxp/osgi/portal/com.liferay.commerce.frontend.impl.jar ]]
    then
        echo "PASSED: jar files are not missing" >> ${1}validation.txt
    else
        echo "FAILED: jar files are missing" >> ${1}validation.txt
    fi
}

function check_patching_tool {
    patching_tool_total=$(ls -A "liferay-dxp/patching-tool" | wc -l)

    if [[ -d liferay-dxp/patching-tool/lib ]] && \
        [[ -d liferay-dxp/patching-tool/logs ]] && \
        [[ -d liferay-dxp/patching-tool/patches ]] && \
        [[ -f liferay-dxp/patching-tool/default.properties ]] && \
        [[ -f liferay-dxp/patching-tool/patching-tool.bat ]] && \
        [[ -f liferay-dxp/patching-tool/patching-tool.sh ]] && \
        [[ "${patching_tool_total}" == "6" ]]
    then
        echo "PASSED: patching-tools are not missing" >> ${1}validation.txt
    else
        echo "FAILED: patching-tools are missing" >> ${1}validation.txt
    fi
}

function check_startup_error {
    if grep -q "ERROR" liferay-dxp/tomcat/bin/out.log
    then
        echo "FAILED: There is an error in the logs. Please see out.log in tomcat/bin" >> ${1}validation.txt
    else
        echo "PASSED: no error in log" >> ${1}validation.txt

        rm "liferay-dxp/tomcat/bin/out.log"
    fi
}

function check_startup_log {
    update=${1}
    current_month="$(date +%B)"
    current_year=", $(date +%Y))"

    if (echo "${update}" | grep -i --quiet "q")
    then
        if echo "$update" | grep -iq "lts" && ! echo "$update" | grep -q "2024"
        then
            update="${update%-lts}"
            portal_assertion="Liferay Digital Experience Platform ${update} LTS (${current_month}"
        else
            portal_assertion="Liferay Digital Experience Platform ${update} (${current_month}"
        fi
    else
        portal_assertion="Liferay Digital Experience Platform 7.4.13 Update ${update} (${current_month}"
    fi

    if grep -q "${portal_assertion}" liferay-dxp/tomcat/bin/out.log && grep -q "${current_year}" liferay-dxp/tomcat/bin/out.log
    then
        echo "PASSED: Matched portal name, version, version name, release date" >> ${1}validation.txt
    else
        echo "FAILED: Did NOT match Portal name, version, version name, or release date: ${current_month} ${current_year} see out.log" >> ${1}validation.txt
    fi
}

function get_branch_name {
    folder_name="${PWD##*/}"
    version_string1="${folder_name#liferay-dxp-tomcat-}"
    version_string2="${version_string1%*-*}"
    version_string3="${version_string2/-u/"."}"
    branch_name=release-"$version_string3"

    echo "${branch_name}"
    }

function get_release_url {
    release_version=${1}

    release_url=$(curl -s "https://releases.liferay.com/dxp/release-candidates/" | grep -i "$release_version" | sed -n 's/.*href="\([^"]*\).*/\1/p')

    echo "${release_url}"
}

function main {
    if [ $# -eq 0 ]
    then
        echo "Please add release version to argument. (Example: 130, 2025.Q3.3, 2025.Q1.5-lts)"
        exit 1
    fi

    if [[ "${1}" == *"Q1"* ]] && [[ "${1}" != "2024"* ]] && [[ "${1}" != *"-lts" ]]
    then
        echo "Update argument to include lts version for q1. (Example: 2026.Q1.1-lts)"
        exit 1
    fi


    get_branch_name
    get_release_url "${1}"
    check_lts_version "${1}"
    check_liferay_home "${1}"
    check_githash_file "${1}"
    check_copyright "${1}"
    check_deploy_folder "${1}"
    check_logs_folder "${1}"
    check_osgi_state "${1}"
    check_osgi_marketplace "${1}"
    check_osgi_modules "${1}"
    check_osgi_portal "${1}"
    check_mysql_jar "${1}"
    check_patching_tool "${1}"
    startup_portal "${1}"
}

function startup_portal {
    update_number=${1}

    cd liferay-dxp/tomcat/bin

    echo "Starting up portal..."

    sh ./catalina.sh run &> out.log & sleep 45

    cd ../../..

    check_startup_log ${update_number}

    check_startup_error "${1}"

    pkill -f 'catalina'
}

main "${@}"