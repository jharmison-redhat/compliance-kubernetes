"""Compliance Kubernetes - Apply and measure compliance profiles.

This package applies Compliance Operator profiles to OpenShift clusters, and
measures the progress in terms of overall benchmark achievement to demonstrate
compliance state deltas between unremediated clusters and post-remediation
state.
"""

from importlib.metadata import version, PackageNotFoundError

try:
    __version__ = version("compliance-kubernetes")
except PackageNotFoundError:  # pragma: nocover
    # Package is not installed (development?)
    __version__ = 'development'
