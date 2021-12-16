#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
. common.sh

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

echo "Measuring compliance scan pass rates..."

declare -A passed
passed[high]=$(ComplianceCheckResults_rules PASS | sort -u | wc -l)
passed[medium]=$(ComplianceCheckResults_rules PASS medium | sort -u | wc -l)
passed[low]=$(ComplianceCheckResults_rules PASS low | sort -u | wc -l)
passed[unknown]=$(ComplianceCheckResults_rules PASS unknown | sort -u | wc -l)
total_passed=0
for sev in high medium low unknown; do
    (( total_passed += ${passed[$sev]} )) ||:
done
declare -A failed
failed[high]=$(ComplianceCheckResults_rules | sort -u | wc -l)
failed[medium]=$(ComplianceCheckResults_rules FAIL medium | sort -u | wc -l)
failed[low]=$(ComplianceCheckResults_rules FAIL low | sort -u | wc -l)
failed[unknown]=$(ComplianceCheckResults_rules FAIL unknown | sort -u | wc -l)
total_failed=0
for sev in high medium low unknown; do
    (( total_failed += ${failed[$sev]} )) ||:
done
declare -A manual
manual[high]=$(ComplianceCheckResults_rules MANUAL | sort -u | wc -l)
manual[medium]=$(ComplianceCheckResults_rules MANUAL medium | sort -u | wc -l)
manual[low]=$(ComplianceCheckResults_rules MANUAL low | sort -u | wc -l)
manual[unknown]=$(ComplianceCheckResults_rules MANUAL unknown | sort -u | wc -l)
total_manual=0
for sev in high medium low unknown; do
    (( total_manual += ${manual[$sev]} )) ||:
done

echo
echo "You passed $total_passed rules on the current compliance scans."
echo "You had ${failed[high]} high-severity failures, $total_failed failures in total, and $total_manual manual checks that cannot be automated by the operator."
