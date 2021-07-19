#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
set -e

helm version --short 2>/dev/null | grep -q '^v3' || { echo "Please install helm 3 into your \$PATH."; exit 1; }
oc whoami
oc whoami --show-server

read -sp "Continue with compliance operator against this cluster? (Press Enter, or Ctrl +C to cancel)" dummy; echo

echo -n "Deploying the Compliance Operator"
oc apply -f compliance-operator/00-subscription.yml &>/dev/null
oc project openshift-compliance &>/dev/null
while ! oc get deployment compliance-operator &>/dev/null; do
    echo -n '.'
    sleep 1
done; echo
oc rollout status deployment/compliance-operator &>/dev/null

echo -n "Waiting for Profile extraction"
for profile in ocp4-cis ocp4-cis-node ocp4-moderate rhcos4-moderate; do
    while ! oc get profiles.compliance.openshift.io |& grep -qF $profile; do
        echo -n '.'
        sleep 1
    done
done; echo

echo -n "Applying default scans"
oc apply -f compliance-operator/01-scansettingbindings.yml &>/dev/null
for scan in ocp4-cis ocp4-cis-node ocp4-moderate rhcos4-moderate; do
    while ! oc get compliancescan |& grep -qF $scan; do
        echo -n '.'
        sleep 1
    done
done
while [ "$(oc get compliancescan -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort -u)" != "DONE" ]; do
    echo -n '.'
    sleep 1
done; echo

echo -n "Recovering scan results"
resultsdir=output/$(uuidgen)
pvcs=(
    ocp4-cis
    ocp4-cis-node-master
    ocp4-cis-node-worker
    ocp4-moderate
    rhcos4-moderate-master
    rhcos4-moderate-worker
)
for pvc in ${pvcs[@]}; do
    mkdir -p $resultsdir/$pvc
    helm install --set volumes="{$pvc}" results-$pvc ./compliance-operator/results &>/dev/null
    echo -n '.'
done
for pvc in ${pvcs[@]}; do
    while [ $(oc get pod results-$pvc -ojsonpath='{.status.phase}') != 'Running' ]; do
        echo -n '.'
        sleep 1
    done
    oc cp results-$pvc:/results/0/ $resultsdir/$pvc &>/dev/null ||:
    echo -n '.'
done
for pvc in ${pvcs[@]}; do
    helm uninstall results-$pvc &>/dev/null
    echo -n '.'
done; echo

echo -n "Extracting scan results"
cd $resultsdir
for bzip in $(find . -type f -name '*.bzip2'); do
    bunzip2 $bzip &>/dev/null
    mv $bzip.out $(echo $bzip | rev | cut -d. -f2- | rev)
    echo -n '.'
done; echo

echo "Your scan results are in:"
pwd
