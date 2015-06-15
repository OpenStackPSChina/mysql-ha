# --------------------------------------------------------------------------------------
# common functions
# --------------------------------------------------------------------------------------
# function log_info
log_info() {
    #local LOG_FILE='/tmp/openstack-install.log'
    local LEVEL='INFO'
    local CONTENT=${1}
    #printf "[$(date "+%m-%d-%Y %H:%M:%S")] ${LEVEL} -> ${CONTENT} \n" >> ${LOG_FILE}
    printf "[$(date "+%m-%d-%Y %H:%M:%S")] ${LEVEL} -> ${CONTENT} \n"
}

# function log_warn
log_warn() {
    #local LOG_FILE='/tmp/openstack-install.log'
    local LEVEL='WARN'
    local CONTENT=${1}
    #printf "[$(date "+%m-%d-%Y %H:%M:%S")] ${LEVEL} -> ${CONTENT} \n" >> ${LOG_FILE}
    printf "[$(date "+%m-%d-%Y %H:%M:%S")] ${LEVEL} -> ${CONTENT} \n"
}

# function log_err
log_err() {
    #local LOG_FILE='/tmp/openstack-install.log'
    local LEVEL='ERROR'
    local CONTENT=${1}
    #printf "[$(date "+%m-%d-%Y %H:%M:%S")] ${LEVEL} -> ${CONTENT} \n" >> ${LOG_FILE}
    printf "[$(date "+%m-%d-%Y %H:%M:%S")] ${LEVEL} -> ${CONTENT} \n"
}

# check operating system
function check_system() {
    if [[ ! -x $(which lsb_release 2>/dev/null) ]]; then
        yum --nogpgcheck -y install redhat-lsb
    fi
    if [[ -x $(which lsb_release 2>/dev/null) ]]; then
        CODENAME=$(lsb_release -c -s)
        VENDOR=$(lsb_release -i -s)
        MAIN_RELEASE=$(lsb_release -r -s | awk -F '.' '{print $1}')
        MINOR_RELEASE=$(lsb_release -r -s | awk -F '.' '{print $2}')
        if [ "${VENDOR}" == "RedHatEnterpriseServer" -o "${VENDOR}" == "CentOS" ]; then
            if [ ${MAIN_RELEASE} -eq 6 ]; then
                if [ ${MINOR_RELEASE} -ge 3 ]; then
                    log_info "This Operating System (${VENDOR} ${MAIN_RELEASE} Update ${MINOR_RELEASE}) is OK."
                else
                    log_warn "This Operating System is ${VENDOR}${MAIN_RELEASE} Update ${MINOR_RELEASE}, not tested."
                fi
            else
                log_err "This Operating System is ${VENDOR}${MAIN_RELEASE}, not RHEL6."
                exit 1
            fi
        else
            log_err "This Operating System is ${VENDOR}, not RedHatEnterpriseServer or CentOS."
            exit 1
        fi
    else
        log_err "You may not running RedHatEnterpriseServer or CentOS 6. Please check your OS."
        exit 1
    fi
}

# check user
function check_user() {
    CURRENT_USER=$(whoami)
    if [ "${CURRENT_USER}" == "root" ]; then
        log_info "Current active user is root."
    else
        log_err "Current active user is ${CURRENT_USER}, this script need to be run by root."
        exit 1
    fi
}

# check and set selinux
function set_selinux() {
    if [ $(getenforce) != 'Disabled' -o $(getenforce) != 'disabled' ]; then
        log_info "Setting SElinux to Disabled"
        setenforce 0
        sed "s#^SELINUX=.*#SELINUX=disabled#" -i /etc/selinux/config
        log_info "SELinux is set to 'permissive' now."
        log_info "SELinux will be set to 'disabled' after next reboot."
    else
        log_info "SELinux is already set to 'disabled'."
    fi
}
# get ip address of ethernet port
function get_nic_ip() {
    NIC_PORT=$1
    ifconfig ${NIC_PORT} | awk '/inet addr/ {print $2}' | awk -F ':' '{print $2}'
}
# get subnet mask of ethernet port
function get_nic_mask() {
    NIC_PORT=$1
    ifconfig ${NIC_PORT} | awk '/inet addr/ {print $4}' | awk -F ':' '{print $2}'
}
# get brodcast of some ethernet port
function get_nic_bcast() {
    NIC_PORT=$1
    ifconfig ${NIC_PORT} | awk '/inet addr/ {print $3}' | awk -F ':' '{print $2}'
}
# get gateway of some ethernet port
function get_nic_gateway() {
    NIC_PORT=$1
    ip route list | awk '/default/ && /'${NIC_PORT}'/ {print $3}'
}
# get mac address of some ethernet port
function get_nic_mac() {
    NIC_PORT=$1
    ifconfig ${NIC_PORT} | awk '/HWaddr/ {print $5}'
}
# get subnet of some ethernet port
function get_ip_net() {
    IP_ADDR=$1
    echo ${IP_ADDR} | awk -F '.' '{print $1"."$2"."$3"."0}'
}

# get reverse zone
function get_reverse_zone() {
    IP_ADDR_SUBNET=$1
    echo ${IP_ADDR_SUBNET} | awk -F '.' '{print $1"."$2"."$3}'
}

# generate yum stanz
function gen_yum_stanz() {
    REPO_NAME=$1
    REPO_URL=$2
    REPO_FILE=$3
    echo "[${REPO_NAME}]" > ${REPO_FILE}
    echo "name=${REPO_NAME}" >> ${REPO_FILE}
    echo "baseurl=${REPO_URL}" >> ${REPO_FILE} 
    echo "enabled=1" >> ${REPO_FILE}
    echo "gpgcheck=0" >> ${REPO_FILE} 
}

# add iptables rule
function iptables_allow_port() {
    PROTOCOL=$1
    PORT_NO=$2
    IPTABLES_SYSCONF='/etc/sysconfig/iptables'
    if [ -f ${IPTABLES_SYSCONF} ]; then
        BASE_LINE_NO=$(awk '/-A INPUT -m state --state NEW -m tcp -p tcp --dport 22 -j ACCEPT/{print NR}' ${IPTABLES_SYSCONF})
        sed "${BASE_LINE_NO}a\-A INPUT -m state --state NEW -m ${PROTOCOL} -p ${PROTOCOL} --dport ${PORT_NO} -j ACCEPT" -i ${IPTABLES_SYSCONF}
    else
        log_err "No ${IPTABLES_SYSCONF} found on your system, please manual allow ${PORT_NO} to your firewall."
    fi
}


