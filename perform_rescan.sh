#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
. common.sh


# All non-manual scans should be replicated
for scan in $(oc get compliancescan -oname); do
    oc annotate $scan compliance.openshift.io/rescan=$(date +%s)
    echo -n '.'
done

# Wait for the manual scans to complete
# TODO: reuse wait_for function from above
while [ "$(oc get compliancescan -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort -u)" != "DONE" ]; do
    echo -n '.'
    sleep 1
done; echo
