#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
set -e

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
