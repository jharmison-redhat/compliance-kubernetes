"""Compliance Kubernetes - Apply and measure compliance profiles.

This module contains the apply subcommands for the CLI.
"""

import click

from click_default_group import DefaultGroup

from ..cluster import ComplianceKubernetesCluster
from ..config import ComplianceKubernetesConfig
from .cli import main
from .util import cli_logger, config_opt, verbose_opt

pass_config = click.make_pass_decorator(ComplianceKubernetesConfig,
                                        ensure=True)


@main.group(cls=DefaultGroup, default='all', default_if_no_args=True)
@verbose_opt
@config_opt
@pass_config
def apply(passed_config, verbose, config):
    """Idempotently apply various objects to an OpenShift cluster.

    The objects that can be applied are related to the overall operation of the
    compliance-kubernetes tool. These include things like Operator installs,
    compliance profile bindings, etc.
    """
    logger = cli_logger(verbose)

    if config:
        logger.debug(f'adding config: {config}')
        passed_config.extend(config)


@apply.command()
@verbose_opt
@config_opt
@pass_config
def operator(passed_config, verbose, config):
    """Idempotently apply Compliance Operator installation."""
    logger = cli_logger(verbose)

    if config:
        logger.debug(f'adding config: {config}')
        passed_config.extend(config)
    config = passed_config

    cluster = ComplianceKubernetesCluster(config.cluster)
    cluster.operator_installed(version=config.operator.version)


@apply.command()
@verbose_opt
@config_opt
@pass_config
def profiles(passed_config, verbose, config):
    """Idempotently apply Compliance Operator profiles."""
    logger = cli_logger(verbose)

    if config:
        logger.debug(f'adding config: {config}')
        passed_config.extend(config)
    config = passed_config

    cluster = ComplianceKubernetesCluster(config.cluster)
    cluster.profiles_bound(profiles=config.profiles, setting=config.setting)


@apply.command()
@verbose_opt
@config_opt
@pass_config
def all(passed_config, verbose, config):
    """Idempotently apply Compliance Operator install and profiles."""
    logger = cli_logger(verbose)

    if config:
        logger.debug(f'adding config: {config}')
        passed_config.extend(config)
    config = passed_config

    cluster = ComplianceKubernetesCluster(config.cluster)
    cluster.operator_installed(version=config.operator.version)
    cluster.profiles_bound(profiles=config.profiles, setting=config.setting)
