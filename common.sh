#!/bin/bash

function wait_on {
    echo -n "Waiting on $1."
    shift
    timeout=$1
    shift
    retries=$(( timeout / 5 ))
    if [ $retries -eq 0 ]; then
        eval ${@} &>/dev/null
        return $?
    else
        while ! "${@}" &>/dev/null; do
            (( retries -- ))
            [ $retries -gt 0 ] || break
            sleep 5
            echo -n .
        done
        echo
        [ $retries -gt 0 ] || return 1
    fi
}

function operator_query {
    echo '[.items[].status.conditions[] | select(.type == "'"$1"'") | .status] | contains(["'"$2"'"])'
}

function cluster_done_upgrading {
    ret=0
    oc get nodes &>/dev/null || (( ret += 1 ))
    oc get clusteroperators -o json 2>/dev/null | jq -e "$(operator_query Progressing True)" &>/dev/null && (( ret += 2 ))
    oc get clusteroperators -o json 2>/dev/null | jq -e "$(operator_query Degraded True)" &>/dev/null && (( ret += 4 ))
    oc get clusteroperators -o json 2>/dev/null | jq -e "$(operator_query Available False)" &>/dev/null && (( ret += 8 ))
    return $ret
}

function wait_on_cluster_stable {
    stability_desired=${1:-60}
    echo -n 'Waiting for desired cluster stability.'
    local this_run=0
    while [ $stability_desired -gt $this_run ]; do
        if cluster_done_upgrading; then
            (( this_run += 5 ))
            sleep 5
            echo -n .
        else
            this_run=0
            echo -n .
        fi
    done
    echo
}

resultsdir=output

helm version --short 2>/dev/null | grep -q '^v3' || { echo "Please install helm 3 into your \$PATH."; exit 1; }
which jq &>/dev/null || { echo "Please install jq."; exit 1; }
which bunzip2 &>/dev/null || { echo "Please install bunzip2."; exit 1; }
which oc &>/dev/null || { echo "Please install the OpenShift CLI (oc)."; exit 1; }
# Make sure we're logged into the right cluster
oc whoami
oc whoami --show-server
read -sp "Continue with $(basename "$0") against this cluster? (Press Enter, or Ctrl +C to cancel)" dummy; echo
