#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
set -e

function ScanSettingBinding_differences {
    diff -y --suppress-common-lines compliance-operator/01-scansettingbindings.yml - < \
        <(oc apply view-last-applied -f compliance-operator/01-scansettingbindings.yml 2>/dev/null) \
        | grep -v '^---'
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

if [ -n "$(ScanSettingBinding_differences)" ]; then # we need to apply the scans
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
    done; echo

    echo -n "Recovering scan results"
    # Random folder each run
    resultsdir=output/$(uuidgen)
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

    echo "Your scan results are in:"
    pwd
    cd ../..
else
    echo "Not applying scans as they appear to already be updated"
fi
