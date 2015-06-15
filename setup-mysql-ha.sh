#!/bin/bash
#------------------------------------------------------------------------------- 
# This script is used to setup a 2 node MySQL HA Cluster via keepalived.
# And this script should be run on each of the 2 nodes.
#-------------------------------------------------------------------------------
#
#-------------------------------------------------------------------------------
# include conf file
#-------------------------------------------------------------------------------
source ./conf/mysql-ha.conf

#-------------------------------------------------------------------------------
# include useage file
#-------------------------------------------------------------------------------
source ./lib/usage.sh

#-------------------------------------------------------------------------------
# include common file
#-------------------------------------------------------------------------------
source ./lib/common.sh

#-------------------------------------------------------------------------------
# Initialize args
#-------------------------------------------------------------------------------
SELF_PRIVATE_IP=$(get_nic_ip "${PRIVATE_NIC}")
SELF_PUBLIC_IP=$(get_nic_ip "${PUBLIC_NIC}")
if [ "${SELF_PRIVATE_IP}" == "${MASTER_NODE_IP}" ]; then
    PEER_NODE_IP=${SECOND_NODE_IP}
    PEER_NODE_ID='2'
    SELF_NODE_ID='1'
else
    PEER_NODE_IP=${MASTER_NODE_IP}
    PEER_NODE_ID='1'
    SELF_NODE_ID='2'
fi


#
# generate ssh-key
#
function generate_ssh_key() {
    cd /root/
    ssh-keygen -t dsa -f /root/.ssh/id_dsa -N ""
    cp /root/.ssh/id_dsa.pub /root/.ssh/authorized_keys
    log_info "ssh_key is generated."
}

#
# copy ssh-key
#
function get_ssh_key() {
    mkdir -p /root/.ssh
    cp ./ssh_key/ssh/* /root/.ssh/
    chown -R root:root /root/.ssh/
    chmod -x /root/.ssh/*
}

#
# copy ssh-key to the other node
#
# scp -r .ssh/ root@THE_OTHER_NODE_IP:/root/

#
# install mysql
#
function install_mysql() {
    yum -y install --nogpgcheck mysql mysql-server
    YUM_RESULT=$?
    if [ "${YUM_RESULT}" == "0" ]; then
        log_info "MySQL is installed."
    else
        log_err "Failed. Check your network setting or YUM settings."
        exit 1
    fi
}

#
# setting mysql root password and grant remote access by root
#
function init_mysql() {
    service mysqld restart
    # local MYSQL_ROOT_PWD=${1}
    # Get MySQL root access.
    if ! $(mysqladmin -u root password ${MYSQL_ROOT_PWD}); then
        if ! echo "SELECT 1;" | mysql -u root --password=${MYSQL_ROOT_PWD} > /dev/null; then
            log_err "Failed to set password for 'root' of MySQL."
            log_err "-- Password for 'root' is already set."
            exit 1
        else
            log_info "Password is set for 'root' of MySQL."
            log_info "-- Connection to MySQL is verified."
        fi
    fi
    # Sanity check MySQL credentials.
    if ! echo "SELECT 1;" | mysql -u root --password=${MYSQL_ROOT_PWD} > /dev/null; then
        log_err "Connection to MySQL server is failed." 
        log_err "-- Please check your root credentials for MySQL." 
        exit 1
    else
        log_info "Connection to MySQL is verified."
    fi
    # restart mysqld
    service mysqld restart
    # grant root remote access
    mysql -u root -p${MYSQL_ROOT_PWD} -e "GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PWD}';"
    mysql -u root -p${MYSQL_ROOT_PWD} -e "FLUSH PRIVILEGES;"
    log_info "Remote access for root of MySQL is granted."
}

#
# grant user access for HA nodes
#
function grant_HA_access() {
    mysql -u root -p${MYSQL_ROOT_PWD} -e "GRANT REPLICATION SLAVE, FILE ON *.* TO 'dbsync'@'${PEER_NODE_IP}' IDENTIFIED BY 'dbsync';"
    log_info "HA access for dbsync is granted."
}

#
# modify /etc/my.cnf
#
function modify_my_cnf() {
    service mysqld stop
    # modify the my.cnf
    if [ -f /etc/my.cnf ]; then
        cp /etc/my.cnf /etc/my.cnf.orig
        log_info "Old my.cnf saved as my.cnf.orig"
    fi
    echo "[mysqld]"                               > /etc/my.cnf
    echo "datadir=/var/lib/mysql"                 >> /etc/my.cnf
    echo "socket=/var/lib/mysql/mysql.sock"       >> /etc/my.cnf
    echo "user=mysql"                             >> /etc/my.cnf 
    echo "symbolic-links=0"                       >> /etc/my.cnf 
    echo "#"                                      >> /etc/my.cnf
    echo "# add for HA"                           >> /etc/my.cnf
    echo "#"                                      >> /etc/my.cnf
    echo "log-bin=mysql-bin"                      >> /etc/my.cnf 
    echo "server-id=${SELF_NODE_ID}"              >> /etc/my.cnf 
    echo ""                                       >> /etc/my.cnf 
    echo "[mysqld_safe]"                          >> /etc/my.cnf 
    echo "log-error=/var/log/mysqld.log"          >> /etc/my.cnf 
    echo "pid-file=/var/run/mysqld/mysqld.pid"    >> /etc/my.cnf
    echo "#"                                      >> /etc/my.cnf 
    echo "# add for HA"                           >> /etc/my.cnf 
    echo "#"                                      >> /etc/my.cnf
    echo "master-host=${PEER_NODE_IP}"            >> /etc/my.cnf 
    echo "master-user=dbsync"                     >> /etc/my.cnf 
    echo "master-pass=dbsync"                     >> /etc/my.cnf 
    echo "master-port=3306"                       >> /etc/my.cnf 
    echo "master-connect-retry=60"                >> /etc/my.cnf 
    echo "binlog-ignore-db=mysql"                 >> /etc/my.cnf 
    echo "replicate-ignore-db=mysql"              >> /etc/my.cnf 
    echo "binlog-do-db=test"                      >> /etc/my.cnf 
    echo "replicate-do-db=test"                   >> /etc/my.cnf 
    echo "log-slave-updates"                      >> /etc/my.cnf 
    echo "slave-skip-errors=all"                  >> /etc/my.cnf 
    echo "sync_binlog=1"                          >> /etc/my.cnf 
    echo "auto_increment_increment=2"             >> /etc/my.cnf 
    echo "auto_increment_offset=${SELF_NODE_ID}"  >> /etc/my.cnf 

    # restart mysqld
    service mysqld restart
    log_info "mysqld is restarted"
}

#
# lock tables
#
function lock_tables() {
    mysql -u root -p${MYSQL_ROOT_PWD} -e "FLUSH TABLES WITH READ LOCK\G"
    log_info "All tables is locked."
}

#
# get master status
#
function get_master_status() {
    #mysql -u root -p${MYSQL_ROOT_PWD} -e "SHOW MASTER STATUS\G"
    MASTER_LOG_FILE=$(mysql -u root -p${MYSQL_ROOT_PWD} -e "SHOW MASTER STATUS\G" | awk '/File/ {print $2}')
    MASTER_LOG_POS=$(mysql -u root -p${MYSQL_ROOT_PWD} -e "SHOW MASTER STATUS\G" | awk '/Position/ {print $2}')
    log_info "Master status is get."
}

#
# change master on both node
#
function change_master() {
    mysql -u root -p${MYSQL_ROOT_PWD} -e "CHANGE MASTER TO master_host='${PEER_NODE_IP}', master_user='dbsync', master_password='dbsync', master_log_file='${MASTER_LOG_FILE}', master_log_pos=${MASTER_LOG_POS};"
    log_info "Master info is changed."
}

#
# start slave
#
function start_slave() {
    mysql -u root -p${MYSQL_ROOT_PWD} -e "START SLAVE;"
    log_info "Slave is started."
}
#
# check proccesslist
#

#
# unlock tables
#
function unlock_tables() {
    mysql -u root -p${MYSQL_ROOT_PWD} -e "UNLOCK TABLES;"
    log_info "All tables is unlocked."
}

#
# check slave status
#

#
# install keepalived
#
function install_keepalived() {
    yum -y install --nogpgcheck keepalived
    YUM_RESULT=$?
    if [ "${YUM_RESULT}" == "0" ]; then
        log_info "keepalived is installed."
    else
        log_err "Failed. Check your network setting or YUM settings."
        exit 1
    fi
}

#
# modify the /etc/keepalived/keepalived.conf
#
function modify_keepalived_conf() {
    if [ -f /etc/keepalived/keepalived.conf ]; then 
        cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.orig
        log_info "Old keepalived.conf saved as keepalived.conf.orig"
    fi
    # generate new keepalived.conf
    echo "#"                                    > /etc/keepalived/keepalived.conf
    echo "# global define #"                    >> /etc/keepalived/keepalived.conf
    echo "#"                                    >> /etc/keepalived/keepalived.conf
    echo "global_defs {"                        >> /etc/keepalived/keepalived.conf
    echo "        router_id mysql_ha"           >> /etc/keepalived/keepalived.conf
    echo "}"                                    >> /etc/keepalived/keepalived.conf
    echo "vrrp_sync_group VGM {"                >> /etc/keepalived/keepalived.conf
    echo "        group {"                      >> /etc/keepalived/keepalived.conf
    echo "                VI_HA"                >> /etc/keepalived/keepalived.conf
    echo "                }"                    >> /etc/keepalived/keepalived.conf
    echo "}"                                    >> /etc/keepalived/keepalived.conf
    echo "vrrp_script chk_mysql {"              >> /etc/keepalived/keepalived.conf
    echo "        script \"killall -0 mysqld\"" >> /etc/keepalived/keepalived.conf
    echo "        interval 5"                   >> /etc/keepalived/keepalived.conf
    echo "}"                                    >> /etc/keepalived/keepalived.conf
    echo "#"                                    >> /etc/keepalived/keepalived.conf
    echo "# vvrp_instance define #"             >> /etc/keepalived/keepalived.conf
    echo "#"                                    >> /etc/keepalived/keepalived.conf
    echo "vrrp_instance VI_HA {"                >> /etc/keepalived/keepalived.conf
    echo "        state MASTER"                 >> /etc/keepalived/keepalived.conf
    echo "        interface ${PUBLIC_NIC}"      >> /etc/keepalived/keepalived.conf
    echo "        virtual_router_id 51"         >> /etc/keepalived/keepalived.conf
    echo "        priority 100"                 >> /etc/keepalived/keepalived.conf
    echo "        advert_int 5"                 >> /etc/keepalived/keepalived.conf
    echo "        authentication {"             >> /etc/keepalived/keepalived.conf
    echo "                auth_type PASS"       >> /etc/keepalived/keepalived.conf
    echo "                auth_pass mysqlha"    >> /etc/keepalived/keepalived.conf
    echo "        }"                            >> /etc/keepalived/keepalived.conf
    echo "        virtual_ipaddress {"          >> /etc/keepalived/keepalived.conf
    echo "                ${MySQL_VIRT_IP}"     >> /etc/keepalived/keepalived.conf
    echo "        }"                            >> /etc/keepalived/keepalived.conf
    echo "        track_script {"               >> /etc/keepalived/keepalived.conf
    echo "                chk_mysql"            >> /etc/keepalived/keepalived.conf
    echo "        }"                            >> /etc/keepalived/keepalived.conf
    echo "}"                                    >> /etc/keepalived/keepalived.conf

    # start keepalived
    # service keepalived start
    # log_info "keep alived started"
    
}

#
# main function
#
function main() {
    echo "@@==== Script started ====@@"
    check_system
    check_user
    set_selinux
    # disable firewall
    service iptables stop && chkconfig iptables off
    # generate ssh_key on master node
    #if [ "${SELF_NODE_ID}" == "1" ]; then
    #    generate_ssh_key
    #    scp -r .ssh/ root@${PEER_NODE_IP}:/root/
    #fi
    get_ssh_key
    install_mysql
    init_mysql
    grant_HA_access
    modify_my_cnf
    lock_tables
    get_master_status
    change_master
    start_slave
    unlock_tables
    install_keepalived
    modify_keepalived_conf
    # starting mysqld
    if [ $(ssh root@${PEER_NODE_IP} 'ls /etc/keepalived/keepalived.conf') ]; then
        service keepalived stop
        log_info "keepalived stopped on ${SELF_PRIVATE_IP}"
        ssh root@${PEER_NODE_IP} 'service keepalived stop'
        log_info "keepalived stopped on ${PEER_NODE_IP}"
        sleep 5
        service mysqld restart
        log_info "mysqld restarted on ${SELF_PRIVATE_IP}"
        ssh root@${PEER_NODE_IP} 'service mysqld restart'
        log_info "mysqld restarted on ${PEER_NODE_IP}"
        sleep 5
        service keepalived start
        log_info "keepalived started on ${SELF_PRIVATE_IP}"
        ssh root@${PEER_NODE_IP} 'service keepalived start'
        log_info "keepalived started on ${PEER_NODE_IP}"
    fi
    echo "@@==== Script Ended ====@@"
}

#
# excute the script
#
(main $@ 2>&1) | sed '/^[@\[]/!s/^/    >>>> &/g' | tee ${LOG_FILE}

