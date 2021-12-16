# compliance-kubernetes

Shell Script Edition

## Requirements

- An installed OpenShift cluster
- `~/.kube/config` or `$KUBECONFIG` defined with a cluster-admin logged in
- The following binaries in your `$PATH`:
  - oc
  - helm
    - Helm 3!
  - bunzip2
  - jq

## Use

- Install the Compliance Operator

    ```sh
    ./deploy_compliance_operator.sh
    ```

- Perform an initial scan, and apply remediations immediately

    ```sh
    ./perform_initial_scan.sh
    ```

- Recover the SCAP results from the scans

    ```sh
    ./recover_results.sh
    ```

- Measure the results of the scan

    ```sh
    ./measure_compliance_check_results.sh
    ```

- Trigger a manual rescan, after remediation

    ```sh
    ./perform_rescan.sh
    ```

- Measure the results of the rescan

    ```sh
    ./measure_compliance_check_results.sh
    ```

- Recover the SCAP results from the rescans

    ```sh
    ./recover_results.sh after
    ```
