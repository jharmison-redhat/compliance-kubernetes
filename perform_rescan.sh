#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
. common.sh


echo "Applying a manual rescan"

for scan in $(oc get compliancescan -oname); do
    oc annotate $scan compliance.openshift.io/rescan=$(date +%s) &>/dev/null
    echo -n '.'
done

# Wait for the manual scans to complete
while [ "$(oc get compliancescan -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort -u)" != "DONE" ]; do
    echo -n '.'
    sleep 1
done; echo
