#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
. common.sh

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
