#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
. common.sh

function ScanSettingBinding_differences {
    diff -y --suppress-common-lines compliance-operator/01-scansettingbindings.yml - < \
        <(oc apply view-last-applied -f compliance-operator/01-scansettingbindings.yml 2>/dev/null) \
        | grep -v '^---'
}

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
    while [ "$(oc get compliancescan -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort -u)" != "DONE" ]; do
        echo -n '.'
        sleep 1
    done; echo; echo

    # Because we're auto-applying, wait for everything to finish rolling
    wait_on_cluster_stable; echo
else
    echo "Not applying scans as they appear to already be updated"
fi
