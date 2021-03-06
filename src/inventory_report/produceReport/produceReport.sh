#!/bin/bash -e
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
SOS_REPORT_UNPACK_DIR="${1}"
SCRIPT_DIR="$(dirname $(readlink -f $0))"

. $(dirname "${0}")/security-checks

if [[ -f ${SCRIPT_DIR}/docs-helper ]]; then
    . ${SCRIPT_DIR}/docs-helper
else
    echo "Unable to load docs-helper"
    exit -1
fi

if [[ -f ${SCRIPT_DIR}/../inventory-profile ]]; then
    . ${SCRIPT_DIR}/../inventory-profile
else
    echo "Unable to load inventory-profile"
    exit -1
fi

if [[ -f ${SOS_REPORT_UNPACK_DIR}/.metadata-inventory ]]; then
    . ${SOS_REPORT_UNPACK_DIR}/.metadata-inventory
else
    echo "Unable to load .metadata-inventory"
    exit -1
fi

# Load some Engine vars, like FQDN and others
if [[ -f ${ENGINE_UNPACKED_SOSREPORT}/etc/ovirt-engine/engine.conf.d/10-setup-protocols.conf ]]; then
    . ${ENGINE_UNPACKED_SOSREPORT}/etc/ovirt-engine/engine.conf.d/10-setup-protocols.conf
fi

DB_NAME="report";
DBDIR="${SOS_REPORT_UNPACK_DIR}"/postgresDb
PGDATA="${DBDIR}"/pgdata
PGRUN="${DBDIR}"/pgrun
SQLS=$(dirname "${0}")/sqls

# If engine_address is not set it is local env
if [ -z "${PG_DB_ADDRESS}" ]; then
    PSQL="${PSQL_CMD} --quiet --tuples-only --no-align --dbname ${TEMPORARY_DB_NAME} --username ${ENGINE_DB_USER} --host $PGRUN"
else
    PSQL="${PSQL_CMD} --quiet --tuples-only --no-align --dbname ${TEMPORARY_DB_NAME} --username ${PG_DB_USER} --host ${PG_DB_ADDRESS}"
fi

# PKI
ENGINE_PKI_CONF_DIR="/etc/ovirt-engine/engine.conf.d"
ENGINE_PKI_FILE="10-setup-pki.conf"
ENGINE_PKI_SETTINGS="${ENGINE_PKI_CONF_DIR}/${ENGINE_PKI_FILE}"
DEFAULT_PKI_TRUSTSTORE="/etc/pki/ovirt-engine/.truststore"

function printUsage() {
cat << __EOF__
Usage: $0 <analyzer_working_dir>

Script generates from db adoc file describing current system.
__EOF__

}

function execute_SQL_from_file() {
    PGPASSWORD=${PG_DB_PASSWORD} ${PSQL} --file "$1";
}

function executeSQL() {
    PGPASSWORD=${PG_DB_PASSWORD} ${PSQL} --command "$1";
}

function cleanup_db() {
    execute_SQL_from_file "${SQLS}"/cleanup.sql &> /dev/null
}

function bulletize() {
    sed "s/^/* /"
}

function enumerate() {
    sed "s/^/. /"
}

function createStatementExportingToCsvFromSelect() {
    echo "Copy ($1) To STDOUT With CSV DELIMITER E'${CSV_SEPARATOR}' HEADER;"
}

function printTable() {
    # Argument:
    #   SQL query
    #
    # Description:
    #   This function uses createStatementExportingToCsvFromSelect()
    #   to insert into SQL query the COPY() statement and save the SQL
    #   query output with CSV delimiter |. The delimiter | is used to
    #   create AsciiDoc tables and later converted to HTML tables.
    executeSQL "$(createStatementExportingToCsvFromSelect "$1")" | createAsciidocTable
}

#function you can pipe output into, and which rearrange data to produce asciidoc table.
# Creates an ascii doc table
    #
    # Args that affect adoc output:
    #     - If no argument, the header option will be
    #       included (first item displayed in bold)
    #
    #     - noheader, no additional option will be added
function createAsciidocTable() {
    if [[ ! -z ${1} && ${1} == "noheader" ]]; then
        echo "[options=\"\"]"
    else
        echo "[options=\"header\"]"
    fi

    echo "|===="
    while read A; do echo ${CSV_SEPARATOR}${A};done
    echo "|===="

}

function projectionCountingRowsWithOrder() {
    if [ $# -eq 0 ]; then
        #coding error

        echo "Coding error, supply at least one projection" >&2
        exit 1
    fi
    echo "row_number() OVER (ORDER BY $@ NULLs last) AS \"NO.\" "
}

function display_host_config() {
    configs=""
    vdsm_settings=false
    multipath_settings=false

    # Skip if dir is empty
    if [ ! "$(ls -A ${HOSTS_SOSREPORT_EXTRACTED_DIR})" ]; then
        return
    fi

    for dir in ${HOSTS_SOSREPORT_EXTRACTED_DIR}/*/
    do
        dir=${dir%*/}
        SOS_REPORT_DIRS=$(find "$dir" -maxdepth 2 -name 'sosreport*' -type d 2> /dev/null)
        for SOS_REPORT_DIR in $SOS_REPORT_DIRS
        do
            if [[ ! -z "${SOS_REPORT_DIR}/hostname" ]]; then
                hostname_hypervisor=$(cat ${SOS_REPORT_DIR}/hostname 2> /dev/null)
                configs+="${hostname_hypervisor}"

                vdsm_config=$(${SCRIPT_DIR}/../vdsm-config-reader --sos-report-path ${SOS_REPORT_DIR})
                if [ ${#vdsm_config} -gt 0 ]; then
                    configs+="| ${vdsm_config}"
                    vdsm_settings=true
                fi

                # Based on vdsm project:
                # https://github.com/oVirt/vdsm/blob/3225f848dbc614694751af5fe16fa93be21c385b/lib/vdsm/tool/configurators/multipath.py#L161
                if [[ $(grep -E '# (RHEV|VDSM) PRIVATE$' ${SOS_REPORT_DIR}/etc/multipath.conf) ]]; then
                    configs+="| icon:exclamation-triangle[size=2x]"
                    multipath_settings=true
                fi
                echo
                configs+="\n"
            fi
        done
    done

    # Dynamic set the title
    output=""
    if [ ${multipath_settings} = true ] && [ ${vdsm_settings} = true ]; then
        output="Hypervisor | vdsm.conf | multipath.conf\n"
        output+="${configs}"
    fi

    if [ ${multipath_settings} = true ] && [ ${vdsm_settings} = false ]; then
        output="Hypervisor | multipath.conf\n"
        output+="${configs}"
    fi

    if [ ${multipath_settings} = false ] && [ ${vdsm_settings} = true ]; then
        output="Hypervisor | vdsm.conf\n"
        output+="${configs}"
    fi

    if [ ${multipath_settings} = true ] || [ ${vdsm_settings} = true ]; then
        printSection "Hypervisor(s) Settings"
        echo ".Configurations with non default value:"
        echo -e "${output}" | createAsciidocTable
        if [ ${multipath_settings} = true ]; then
            echo -e "_Exclamation triangle in multipath.conf column means: Manual override for multipath.conf, it is recommended to inspect closely the current /etc/multipath.conf and possibly re-apply it if the hypervisor requires a fresh install_"
        fi
    fi
    echo
}

function printSection() {
    echo
    echo "== $1"
}

function printFileHeader() {
    echo '= oVirt/Red Hat Virtualization Log Collection Analysis'
    echo ${ENGINE_FQDN} $(date +"%m-%d-%Y %T")'
:doctype: book
:source-highlighter: coderay
:listing-caption: Listing
:pdf-page-size: A4
:toc:
:icons: font
:OK: icon:check-circle-o[size=2x]
:WARNING: icon:exclamation-triangle[size=2x]
:INFO: icon:info-circle[size=2x]
:sectnums:
'
}

function initVariablesForVaryingNamesInSchema() {
    CLUSTER_TABLE=$(executeSQL "SELECT CASE (SELECT EXISTS (SELECT 1 FROM   information_schema.tables WHERE  table_name = 'vds_groups')) WHEN TRUE then 'vds_groups' else 'cluster' END AS name;" )
    NETWORK_ATTACHMENTS_TABLE_EXISTS=$(executeSQL "SELECT CASE (SELECT EXISTS (SELECT 1 FROM   information_schema.tables WHERE  table_name = 'network_attachments')) WHEN TRUE then 'exists' else 'does not exist' END AS name;")
    CLUSTER_PK_COLUMN=$(executeSQL "SELECT CASE (SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vds_groups' AND column_name='vds_group_id')) WHEN TRUE then 'vds_group_id' else 'cluster_id' END AS name;" )
    VMS_CLUSTER_FK_COLUMN=$(executeSQL "SELECT CASE (SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vms' AND column_name='vds_group_id')) WHEN TRUE THEN 'vds_group_id' else 'cluster_id' END AS name;" )
    VMS_CLUSTER_COMPATIBILITY_VERSION_COLUMN=$(executeSQL "SELECT CASE (SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vms' AND column_name='vds_group_compatibility_version')) WHEN TRUE THEN 'vds_group_compatibility_version' else 'cluster_compatibility_version' END AS name;" )
}

function list_rhn_channels() {
    # Look for the rhn channels based on yum_-C_repolist file from sosreport
    find "${SOS_REPORT_UNPACK_DIR}" -name yum_-C_repolist -exec tail -n +3 '{}' \; | cut -f 1 -d ' ' | sed -e '/repolist:/d' -e '/This/d' -e '/repo/d' | bulletize
}

function collect_rhn_data() {
    #
    # Reads /etc/sysconfig/rhn/systemid stored in sosreport
    # and returns the value assigned to the configuration key
    # provided as argument.
    #
    # Argument
    #     configuration key, example: system_id, username, etc
    PATH_SYSTEMID=$(find "${SOS_REPORT_UNPACK_DIR}" -name systemid)

    if [[ ! -z ${PATH_SYSTEMID} ]]; then
        xmlcmd="xmllint --xpath 'string(//member[* = \"$1\"]/value/string)' ${PATH_SYSTEMID}"
        # Withot a subshell the xmllint command complain, for now using sh -c
        sh -c "${xmlcmd}"
        echo
    fi
}

function collect_ip_addr_engine() {
    PATH_IP_ADDR=$(find "${SOS_REPORT_UNPACK_DIR}" -name ip_addr)
    if [ ${#PATH_IP_ADDR} -gt 0 ]; then
        echo ".Engine ip addr table"
        echo "[source]"
        cat ${PATH_IP_ADDR}
    fi
}

function reportVirtualMachines() {
    printSection "Virtual Machines"
    TOTAL_NUMBER_OF_VMS=$(execute_SQL_from_file "${SQLS}/vms_query_total_number_of_virtual_machines_in_engine.sql")
    TOTAL_WIN_VMS=$(execute_SQL_from_file "${SQLS}/vms_query_total_number_of_virtual_machines_windows_OS.sql")
    TOTAL_LINUX_OR_OTHER_OS=$(execute_SQL_from_file "${SQLS}/vms_query_total_number_of_virtual_machines_linux_other_OS.sql")

    echo -e ".Number of Virtual Machine(s) per Cluster:\n"
    sql_query=$(execute_SQL_from_file "${SQLS}"/cluster_query_vms_per_cluster.sql)
    if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
        echo "${sql_query}" | createAsciidocTable
    fi

    echo -e ".Number of Virtual Machine(s) per Operating System:\n"
    echo "[options=\"header\"]"
    echo "|===="
    echo "| Operating System | Number of Virtual Machine(s)"
    echo "| Linux OS or Other OS | ${TOTAL_LINUX_OR_OTHER_OS}"
    echo "| Windows OS | ${TOTAL_WIN_VMS}"
    echo "| Total number of Virtual Machines in Engine | ${TOTAL_NUMBER_OF_VMS}"
    echo "|===="
}

#-----------------------------------------------------------------------------------------------------------------------

if [ $# -ne 1 ]; then
    printUsage
    exit 1
fi

CSV_SEPARATOR=\|;

# Make sure nothing was left behind in case an exception happen during runtime
cleanup_db

execute_SQL_from_file "${SQLS}"/hosts_create_related_lookup_tables.sql
execute_SQL_from_file "${SQLS}"/storage_create_related_lookup_tables.sql
execute_SQL_from_file "${SQLS}"/vms_create_related_lookup_tables.sql

initVariablesForVaryingNamesInSchema

ENGINE_VERSIONS=$(execute_SQL_from_file "${SQLS}"/engine_versions_through_all_upgrades.sql)
ENGINE_FIRST_VERSION=$(echo "${ENGINE_VERSIONS}" | head -n 1)
ENGINE_CURRENT_VERSION=$(echo "${ENGINE_VERSIONS}" | tail -n 1)
ENGINE_PAST_VERSIONS=$(echo "${ENGINE_VERSIONS}" | sort -u | sed -e s/"${ENGINE_CURRENT_VERSION}//")

printFileHeader

if [[ -z "${SUMMARY_REPORT}" ]]; then
    if [[ ! -z "${LAST_SOSREPORT_EXTRACTED}" ]]; then
        printSection "Sosreport"
        echo -e "**Engine sosreport**:\n"
        echo -e "${LAST_SOSREPORT_EXTRACTED}\n${LAST_SOSREPORT_EXTRACTED_SHA256SUM} (**SHA256**)\n"

        if [[ -f ${SOS_REPORT_UNPACK_DIR}/.metadata-hosts && -s ${SOS_REPORT_UNPACK_DIR}/.metadata-hosts ]]; then
            echo -e "**Hypervisor(s) sosreport**:\n"
            cat ${SOS_REPORT_UNPACK_DIR}/.metadata-hosts
        fi
    fi

    printSection "Health checks"
    . $(dirname "${0}")/pre-upgrade-checks

    # Backup check
    check_backup_engine

    # Datacenter
    check_minimum_datacenter_compat_version
    check_mixedrhelversion

    # Cluster Check
    check_cluster_no_dc
    check_minimum_cluster_compat_version
    check_cluster_legacy_policy

    # Hosts Check
    check_hosts_health
    check_hosts_pretty_name
    check_hosts_with_tls_disabled
    check_number_of_hosts
    check_clusters_with_mixed_selinux_disabled

    # Storage domain
    check_storage_domains_failing

    # VMs Check
    check_vms_health
    check_images_locked_or_illegal
    check_vms_running_obsolete_cluster
    check_vm_snapshot_id_zero
    check_vms_windows_with_incorrect_timezone
    check_vms_linux_and_others_with_incorrect_timezone
    check_vms_with_cluster_lower_3_6_with_virtio_serial_console
    check_vms_miminum_20_percent_memory_guaranteed
    check_in_preview_snapshots
    check_pinned_virtual_machines
    check_for_cpu_model_Conroe_and_Penryn

    # Engine
    check_async_tasks
    check_runnning_commands
    check_compensation_tasks
    check_min_and_max_engine_heap
    check_third_party_certificate

    # Hosted Engine
    check_hosted_engine_environment

    # LDAP
    check_AAA_legacy

    # Imageproxy
    check_imageproxyaddress_as_localhost

    # Apache
    check_legacy_apache_sso_config

    # Network
    check_dirty_network

    # Power Management
    check_ip_not_null_and_pm_user_null

    # IPTables
    check_custom_ip_tables_config

    # Audit Log
    check_audit_log
fi

printSection "Engine Details"

if [[ -z ${SUMMARY_REPORT} ]]; then
    echo "{INFO} Before engine upgrades it is recommended to execute " \
         "https://access.redhat.com/documentation/en-us/red_hat_virtualization/4.1/html-single/upgrade_guide/#Upgrading_between_Minor_Releases[engine-upgrade-check]"
    echo
fi

echo "=== First version deployed"
echo
echo ".Approximate version of initially installed engine"
echo ${ENGINE_FIRST_VERSION}
echo

echo "=== Current version"
echo
echo ".Approximate current engine version"
echo ${ENGINE_CURRENT_VERSION}
echo

if [ ${#ENGINE_PAST_VERSIONS} -gt 0 ]; then
    if [[ -z ${SUMMARY_REPORT} ]]; then
        echo "=== Past version(s)"
        echo
        echo ".Probable past Engine versions " \
             "footnote:[<We group the upgrade scripts by the time when the script was fully applied. " \
             "All scripts which finished in same 30 minutes span are considered to be " \
             "related to same upgrade. The last script then determines the version " \
             "of this 'upgrade'.>]"
    else
        echo ".Probable past Engine versions"
    fi

    echo
    echo "${ENGINE_PAST_VERSIONS}" | bulletize
    echo
fi

echo "=== FQDN"
echo
echo ".Engine FQDN";
echo "${ENGINE_FQDN}"
echo

sql_query="SELECT pg_size_pretty(pg_database_size(pg_database.datname)) AS size FROM pg_database where pg_database.datname='${TEMPORARY_DB_NAME}'"
DB_SIZE=$(executeSQL "${sql_query}")

echo "=== DB Size"
echo
echo ".Engine DB size"
echo "${DB_SIZE}"
echo

echo "=== Network"
echo
collect_ip_addr_engine
echo

user_rhn=$(collect_rhn_data "username")
id_rhn=$(collect_rhn_data "system_id")

if [ ${#user_rhn} -gt 0 ]; then
    echo "=== RHN"
    echo
    printSection "RHN data from Engine"
    echo "*RHN Username*:"
    echo "${user_rhn}"
    echo
fi

if [ ${#id_rhn} -gt 0 ]; then
    echo "*RHN System id*:"
    echo "${id_rhn}"
    echo
fi

rhn_channels=$(list_rhn_channels)
if [[ ${#rhn_channels} -gt 0 && ${#user_rhn} -gt 0 ]]; then
    echo ".Engine subscribed channels"
    echo "${rhn_channels}"
fi

if [[ ${ENGINE_CURRENT_VERSION} > 3.5 ]]; then
    sql_query=$(execute_SQL_from_file "${SQLS}"/engine_backup_log_last_backup.sql)
    if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
        echo "=== Last Backup"
        echo
        echo ".Last Engine backup"
        echo "${sql_query}" | createAsciidocTable
    fi
fi

echo

sql_query=$(execute_SQL_from_file "${SQLS}"/datacenter_show_all.sql)
printSection "Data Centers"
echo "${sql_query}" | createAsciidocTable

printSection "Clusters"
execute_SQL_from_file "${SQLS}"/cluster_query_show_all_clusters.sql | createAsciidocTable

sql_query=$(execute_SQL_from_file "${SQLS}"/cluster_query_migration_policies.sql)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    echo ".Cluster Migration Policies"
    echo "${sql_query}" | createAsciidocTable
fi

reportVirtualMachines

sql_query=$(execute_SQL_from_file "${SQLS}"/hosts_query_all.sql)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    printSection "Hosts"
    echo "${sql_query}" | createAsciidocTable
fi

# Fence
if [[ "${SHOW_FENCE_AGENT_PASSWORDS}" = true ]]; then
    execute_SQL_from_file "${SQLS}/prepare_procedures_for_reporting_agent_passwords_as_csv.sql"
    AGENT_PASSWORDS_AS_CSV=$(execute_SQL_from_file "${SQLS}"/agent_passwords.sql)
    execute_SQL_from_file "${SQLS}/cleanup_procedures_for_reporting_agent_passwords_as_csv.sql"

    #note gt 1, ie >1. It is because csv contains header, thus 0 records = 1 line.
    if [ $(echo "${AGENT_PASSWORDS_AS_CSV}" | wc -l) -gt 1 ]; then
        printSection "Fence agent password per host"
        echo "${AGENT_PASSWORDS_AS_CSV}" | createAsciidocTable
    fi
fi

# Adding 2> /dev/null to avoid psql warning about global temporary table
# This warning might show during import of old engine dbs which contain tt_TEMP22
#
# GLOBAL is deprecated in temporary table creation
# LINE 1: CREATE GLOBAL TEMPORARY TABLE tt_TEMP22
sql_query=$(execute_SQL_from_file "${SQLS}"/storage_domains_query_data.sql 2>/dev/null)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    printSection "Storage Domains"
    echo "${sql_query}" | createAsciidocTable
fi

sql_query=$(execute_SQL_from_file "${SQLS}"/storage_domains_nfs_path.sql)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    printSection "Storage Domain: NFS"
    echo "${sql_query}" | createAsciidocTable
fi

sql_query=$(execute_SQL_from_file "${SQLS}"/lun_storage_server_connection_map_query_number_connection_map.sql)
if [ ${sql_query} -gt 0 ]; then
    printSection "Storage Domain: Luns"
    execute_SQL_from_file "${SQLS}"/storage_domains_lun_data.sql | createAsciidocTable
fi

sql_query=$(execute_SQL_from_file "${SQLS}"/luns_query_all_data.sql)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    printSection "Luns"
    echo "${sql_query}" | createAsciidocTable
fi

sql_query=$(execute_SQL_from_file "${SQLS}"/dwh_query_check_if_its_running.sql)
printSection "Data Warehouse (DWH)"
echo "${sql_query}" | createAsciidocTable

printSection "Networks"

if [ "$NETWORK_ATTACHMENTS_TABLE_EXISTS" = "exists" ]; then
    sql_query=$(execute_SQL_from_file "${SQLS}"/networks_table_using_network_attachments.sql)
else
    sql_query=$(execute_SQL_from_file "${SQLS}"/networks_table_not_using_network_attachments.sql)
fi
echo "${sql_query}" | createAsciidocTable

tablesWithOverriddenCompatibilityVersionSQL="SELECT
v.vm_name, v.$VMS_CLUSTER_COMPATIBILITY_VERSION_COLUMN
FROM vms v JOIN $CLUSTER_TABLE c ON c.$CLUSTER_PK_COLUMN=v.$VMS_CLUSTER_FK_COLUMN
WHERE v.$VMS_CLUSTER_COMPATIBILITY_VERSION_COLUMN <> c.compatibility_version"

if [ $(executeSQL "$tablesWithOverriddenCompatibilityVersionSQL" | wc -l) -gt 0 ]; then
  printSection "VMs with overridden cluster compatibility version"
  printTable "$tablesWithOverriddenCompatibilityVersionSQL"
fi

sql_query=$(execute_SQL_from_file "${SQLS}"/mac_pools_query_show_data_based_on_datacenter_and_cluster.sql)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    printSection "MAC Pools"
    echo "${sql_query}" | createAsciidocTable
fi

printSection "System Users"
execute_SQL_from_file "${SQLS}"/users_query_system_users.sql | createAsciidocTable

sql_query=$(execute_SQL_from_file "${SQLS}"/bookmarks_query_name_value.sql)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    printSection "Bookmarks"
    echo "${sql_query}" | createAsciidocTable
fi

sql_query=$(execute_SQL_from_file "${SQLS}"/providers_query_show_data.sql)
if [ $(echo "${sql_query}" | wc -l) -gt 1 ]; then
    printSection "External Providers"
    echo "${sql_query}" | createAsciidocTable
fi

printSection "Security"
echo "=== Meltdown and Spectre"
check_cluster_with_non_IBRS_CPUS
check_hosts_non_supporting_IBRS
check_vms_running_with_non_IBRS_CPUS

if [[ -z ${SUMMARY_REPORT} ]]; then
    pkgs_engine="Packages list\n"
    pkgs_engine+=$(rpm_version)
    if [ ${#pkgs_engine} -gt 0 ]; then
        printSection "Engine components"
        echo ".Main components installed in Engine"
        echo -e "${pkgs_engine}" | createAsciidocTable
    fi

    display_host_config

    printSection "Auxiliary documentation"
    auxiliary_docs
fi

printSection "About"
echo "This report was generated by https://access.redhat.com/node/3049721[ovirt-log-collector-analyzer] ${ANALYZER_VERSION}-${ANALYZER_RELEASE} https://github.com/oVirt/ovirt-log-collector[git (${ANALYZER_GITHEAD})]"

cleanup_db
