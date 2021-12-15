"""Compliance Kubernetes - Apply and measure compliance profiles.

This module contains the main CLI functions, based on Click.
"""

import click

from .. import __version__
from ..config import ComplianceKubernetesConfig
from .util import cli_logger, config_opt, verbose_opt


@click.group()
@click.version_option(version=__version__)
@verbose_opt
@config_opt
@click.pass_context
def main(ctx, verbose, config):
    """Apply Compliance Operator profiles to an OpenShift cluster.

    This client is designed to measure the compliance state of an OpenShift
    cluster, apply remediations, and re-measure the state. This is useful for
    understanding how well-remediated a profile might make a cluster, compared
    to the checks included in the profile, and helps abstract application of
    compliance profiles to a very simple level.
    """
    logger = cli_logger(verbose)

    if config:
        logger.debug(f'adding config: {config}')
        ctx.obj = ComplianceKubernetesConfig(extra=config)
