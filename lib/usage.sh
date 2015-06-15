# --------------------------------------------------------------------------------------
# Script usage
# --------------------------------------------------------------------------------------
usage() {
    VERSION='0.1'

    cat << EOF
Usage   : ./setup-mysql-ha.sh
Version : ${VERSION}
Options :
    --help | -h
        Print usage information.
Notice  : Check mysql-ha.conf before running this script
EOF

  exit 1
}
