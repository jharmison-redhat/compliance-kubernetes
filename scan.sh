#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
set -e

function ScanSettingBinding_differences {
    diff -y --suppress-common-lines compliance-operator/01-scansettingbindings.yml - < \
        <(oc apply view-last-applied -f compliance-operator/01-scansettingbindings.yml 2>/dev/null) \
        | grep -v '^---'
}

function ComplianceCheckResults {
    status=${1:-FAIL}
    shift
    severity=${1:-high}
    shift
    oc get compliancecheckresults -l \
        compliance.openshift.io/check-status=$status,compliance.openshift.io/check-severity=$severity \
        "${@}"
}

function ComplianceCheckResults_rules {
    ComplianceCheckResults ${1:-FAIL} ${2:-high} --no-headers -o \
        jsonpath='{range .items[*]}{.metadata.annotations.compliance\.openshift\.io/rule}{"\n"}{end}' \
        | sort -u
}

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
    oc get clusteroperators -o json | jq -e "$(operator_query Progressing True)" &>/dev/null && (( ret += 2 ))
    oc get clusteroperators -o json | jq -e "$(operator_query Degraded True)" &>/dev/null && (( ret += 4 ))
    oc get clusteroperators -o json | jq -e "$(operator_query Available False)" &>/dev/null && (( ret += 8 ))
    return $ret
}

function wait_on_cluster_upgrade {
    delay=${1:-300}
    retries=12
    echo -n 'Waiting for cluster operators to begin redploying.'
    while cluster_done_upgrading; do
        (( retries-- ))
        [ $retries -le 0 ] && break
        sleep 5
        echo -n .
    done
    echo
    [ $retries -gt 0 ] || { echo "Cluster operators don't appear to be redeploying." ; return 0 ; }
    wait_on "cluster operators to finish rollout" $delay cluster_done_upgrading || return 1
}

function wait_on_cluster_stable {
    stability_desired=${1:-300}
    echo -n 'Waiting for desired cluster stability.'
    local this_run=0
    while [ $stability_desired -gt $this_run ]; do
        if cluster_done_upgrading; then
            (( this_run += 5 ))
            sleep 5
            echo -n .
        else
            this_run=0
        fi
    done
    echo
}

# We're using helm for ease of templating
helm version --short 2>/dev/null | grep -q '^v3' || { echo "Please install helm 3 into your \$PATH."; exit 1; }
# Make sure we're logged into the right cluster
oc whoami
oc whoami --show-server
read -sp "Continue with compliance operator against this cluster? (Press Enter, or Ctrl +C to cancel)" dummy; echo

echo -n "Deploying the Compliance Operator"
oc apply -f compliance-operator/00-subscription.yml &>/dev/null
oc project openshift-compliance &>/dev/null
# Wait until the operator starts installing (OLM things)
while ! oc get deployment compliance-operator &>/dev/null; do
    echo -n '.'
    sleep 1
done; echo
# Wait until it's rolled out
oc rollout status deployment/compliance-operator &>/dev/null

# Once it's installed it needs to unpack and process the ProfileBundles
echo -n "Waiting for Profile extraction"
for profile in ocp4-cis ocp4-cis-node ocp4-moderate rhcos4-moderate; do
    while ! oc get profiles.compliance.openshift.io |& grep -qF $profile; do
        echo -n '.'
        sleep 1
    done
done; echo

resultsdir=output/before

if [ -n "$(ScanSettingBinding_differences)" ]; then # we need to apply the scans
    # Clean out old "before" results
    rm -rf $resultsdir

    echo -n "Applying default scans"
    oc apply -f compliance-operator/01-scansettingbindings.yml &>/dev/null
    # Wait for the operator to initiate ComplianceScans from our bindings
    for scan in ocp4-cis ocp4-cis-node ocp4-moderate rhcos4-moderate; do
        while ! oc get compliancescan |& grep -qF $scan; do
            echo -n '.'
            sleep 1
        done
    done
    # Wait for those ComplianceScans to finish
    while [ "$(oc get compliancescan -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort -u)" != "DONE" ]; do
        echo -n '.'
        sleep 1
    done; echo; echo

    # Because we're auto-applying, wait for everything to finish rolling
    wait_on_cluster_stable; echo
else
    echo "Not applying scans as they appear to already be updated"
fi

if [ ! -d $resultsdir ]; then
    echo -n "Recovering original scan results"
    # These are hard-coded to be the ones we expect from these profiles
    # TODO: Dynamically figure out which PVCs exist thanks to our specific scans
    pvcs=(
        ocp4-cis
        ocp4-cis-node-master
        ocp4-cis-node-worker
        ocp4-moderate
        rhcos4-moderate-master
        rhcos4-moderate-worker
    )
    # Create pods to hold open the PVCs using our Helm template
    for pvc in ${pvcs[@]}; do
        mkdir -p $resultsdir/$pvc
        # Clean out any hanging results pods
        helm uninstall results-$pvc &>/dev/null ||:
        helm install --set volumes="{$pvc}" results-$pvc ./compliance-operator/results &>/dev/null
        echo -n '.'
    done
    for pvc in ${pvcs[@]}; do
        # Wait for the pods to start
        while [ $(oc get pod results-$pvc -ojsonpath='{.status.phase}') != 'Running' ]; do
            echo -n '.'
            sleep 1
        done
        # Copy the results out
        oc cp results-$pvc:/results/0/ $resultsdir/$pvc &>/dev/null ||:
        echo -n '.'
    done
    # Remove each pod
    for pvc in ${pvcs[@]}; do
        helm uninstall results-$pvc &>/dev/null
        echo -n '.'
    done; echo

    echo -n "Extracting scan results"
    cd $resultsdir
    for bzip in $(find . -type f -name '*.bzip2'); do
        bunzip2 $bzip &>/dev/null
        # bunzip2 has no idea how to name these, so we drop to the .xml extension
        mv $bzip.out $(echo $bzip | rev | cut -d. -f2- | rev)
        echo -n '.'
    done; echo

    echo "Your pre-remediation scan results are in:"
    pwd
    cd ../..
fi

echo
echo "You passed $(echo "$(ComplianceCheckResults_rules PASS; ComplianceCheckResults_rules PASS medium; ComplianceCheckResults_rules PASS unknown; ComplianceCheckResults_rules PASS low)" | sort -u | wc -l) rules."
echo "You had $(ComplianceCheckResults_rules | wc -l) high-severity failures, $(ComplianceCheckResults_rules FAIL medium | wc -l) medium-severity failures, and $(ComplianceCheckResults_rules MANUAL | wc -l) remaining manual checks."

# Manually rerun scans
# Check updated results
