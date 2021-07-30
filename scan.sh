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
    if [ -n "$manual_scans" ]; then
        oc get compliancecheckresults -l \
            "compliance.openshift.io/check-status=$status,compliance.openshift.io/check-severity=$severity,compliance.openshift.io/scan-name notin ($manual_scans)" \
            "${@}"
    else
        oc get compliancecheckresults -l \
            compliance.openshift.io/check-status=$status,compliance.openshift.io/check-severity=$severity \
            "${@}"
    fi
}

# TODO: Better abstraction to reduce duplication
function ManualComplianceCheckResults {
    status=${1:-FAIL}
    shift
    severity=${1:-high}
    shift
    oc get compliancecheckresults -l \
        "compliance.openshift.io/check-status=$status,compliance.openshift.io/check-severity=$severity,compliance.openshift.io/scan-name in ($manual_scans)" \
        "${@}"
}

function ComplianceCheckResults_rules {
    ComplianceCheckResults ${1:-FAIL} ${2:-high} --no-headers -o \
        jsonpath='{range .items[*]}{.metadata.annotations.compliance\.openshift\.io/rule}{"\n"}{end}' \
        | sort -u
}

# TODO: Better abstraction to reduce duplication
function ManualComplianceCheckResults_rules {
    ManualComplianceCheckResults ${1:-FAIL} ${2:-high} --no-headers -o \
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
    oc get clusteroperators -o json 2>/dev/null | jq -e "$(operator_query Progressing True)" &>/dev/null && (( ret += 2 ))
    oc get clusteroperators -o json 2>/dev/null | jq -e "$(operator_query Degraded True)" &>/dev/null && (( ret += 4 ))
    oc get clusteroperators -o json 2>/dev/null | jq -e "$(operator_query Available False)" &>/dev/null && (( ret += 8 ))
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
    # TODO: Refactor into a wait_on function
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
    # TODO: Refactor into a reusable function based on scan name
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

# TODO: Refactor into a more useful function for collating results
declare -A original_passed
original_passed[high]=$(ComplianceCheckResults_rules PASS | sort -u | wc -l)
original_passed[medium]=$(ComplianceCheckResults_rules PASS medium | sort -u | wc -l)
original_passed[low]=$(ComplianceCheckResults_rules PASS low | sort -u | wc -l)
original_passed[unknown]=$(ComplianceCheckResults_rules PASS unknown | sort -u | wc -l)
total_passed=0
for sev in high medium low unknown; do
    (( total_passed += ${original_passed[$sev]} )) ||:
done
declare -A original_failed
original_failed[high]=$(ComplianceCheckResults_rules | sort -u | wc -l)
original_failed[medium]=$(ComplianceCheckResults_rules FAIL medium | sort -u | wc -l)
original_failed[low]=$(ComplianceCheckResults_rules FAIL low | sort -u | wc -l)
original_failed[unknown]=$(ComplianceCheckResults_rules FAIL unknown | sort -u | wc -l)
total_failed=0
for sev in high medium low unknown; do
    (( total_failed += ${original_failed[$sev]} )) ||:
done
declare -A original_manual
original_manual[high]=$(ComplianceCheckResults_rules MANUAL | sort -u | wc -l)
original_manual[medium]=$(ComplianceCheckResults_rules MANUAL medium | sort -u | wc -l)
original_manual[low]=$(ComplianceCheckResults_rules MANUAL low | sort -u | wc -l)
original_manual[unknown]=$(ComplianceCheckResults_rules MANUAL unknown | sort -u | wc -l)
total_manual=0
for sev in high medium low unknown; do
    (( total_manual += ${original_manual[$sev]} )) ||:
done

echo
echo "You passed $total_passed rules on your original or scheduled scan."
echo "You had ${original_failed[high]} high-severity failures, $total_failed failures in total, and $total_manual manual checks on your original or scheduled scan."
echo

echo -n 'Running manually-triggered scans to validate'
# We need to clean up the old compliancescans to make the manual ones applyable
purge_fields=''
for metadata_item in selfLink resourceVersion uid creationTimestamp generation managedFields ownerReferences finalizers; do
    purge_fields+=".metadata.$metadata_item,"
done
purge_fields+='.status'
# We need to save off the names of our manual scans
manual_scans=''

# All non-manual scans should be replicated
for scan in $(oc get compliancescan -l '!compliance.openshift.io/manual-run' -ojsonpath='{.items[*].metadata.name}'); do
    # Label the new scans as manual so we can identify them
    manual_label='.metadata.labels={"compliance.openshift.io/manual-run":"true"}'
    # Rename them so as not to step on old scans
    rename='.metadata.name=(.metadata.name + "-manual")'
    # Define the new manual scan with our changes
    new_scan="$(oc get compliancescan $scan -ojson | \
        jq "del($purge_fields) | $manual_label | $rename")"
    manual_scans+="$(echo "$new_scan" | jq -r .metadata.name), "
    # Delete any previous manual scan attempts so we can rerun
    echo "$new_scan" | oc delete --wait -f - &>/dev/null ||:
    # Recreate the manual scans
    echo "$new_scan" | oc create -f - &>/dev/null
    echo -n '.'
done
# We need to strip our manual scan set
manual_scans="${manual_scans::-2}"

# Wait for the manual scans to complete
# TODO: reuse wait_for function from above
while [ "$(oc get compliancescan -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort -u)" != "DONE" ]; do
    echo -n '.'
    sleep 1
done; echo

# TODO: reuse result collation function from above
declare -A new_passed
new_passed[high]=$(ManualComplianceCheckResults_rules PASS | sort -u | wc -l)
new_passed[medium]=$(ManualComplianceCheckResults_rules PASS medium | sort -u | wc -l)
new_passed[low]=$(ManualComplianceCheckResults_rules PASS low | sort -u | wc -l)
new_passed[unknown]=$(ManualComplianceCheckResults_rules PASS unknown | sort -u | wc -l)
new_total_passed=0
for sev in high medium low unknown; do
    (( new_total_passed += ${new_passed[$sev]} )) ||:
done
declare -A new_failed
new_failed[high]=$(ManualComplianceCheckResults_rules | sort -u | wc -l)
new_failed[medium]=$(ManualComplianceCheckResults_rules FAIL medium | sort -u | wc -l)
new_failed[low]=$(ManualComplianceCheckResults_rules FAIL low | sort -u | wc -l)
new_failed[unknown]=$(ManualComplianceCheckResults_rules FAIL unknown | sort -u | wc -l)
new_total_failed=0
for sev in high medium low unknown; do
    (( new_total_failed += ${new_failed[$sev]} )) ||:
done
declare -A new_manual
new_manual[high]=$(ManualComplianceCheckResults_rules MANUAL | sort -u | wc -l)
new_manual[medium]=$(ManualComplianceCheckResults_rules MANUAL medium | sort -u | wc -l)
new_manual[low]=$(ManualComplianceCheckResults_rules MANUAL low | sort -u | wc -l)
new_manual[unknown]=$(ManualComplianceCheckResults_rules MANUAL unknown | sort -u | wc -l)
new_total_manual=0
for sev in high medium low unknown; do
    (( new_total_manual += ${new_manual[$sev]} )) ||:
done

echo
echo "You passed $new_total_passed rules on your present reevaluation."
echo "You had ${new_failed[high]} high-severity failures, $new_total_failed failures in total, and $new_total_manual manual checks upon reevaluation."
