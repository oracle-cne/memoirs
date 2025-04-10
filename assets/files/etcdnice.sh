#! /bin/bash
ETCDPID=$(jq -r .pid < /dev/stdin)
ionice -c 1 -p $ETCDPID
