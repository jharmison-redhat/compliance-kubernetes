#!/bin/bash

cd "$(dirname "$(realpath "$0")")"
. common.sh

resultsdir=${resultsdir}/${1:-before}

echo -n "Recovering scan results"
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
    mkdir -p $resultsdir/$pvc
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
