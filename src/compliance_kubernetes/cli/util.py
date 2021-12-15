"""Compliance Kubernetes - Apply and measure compliance profiles.

This module contains the utility CLI functions like reusable argument
definitions.
"""

import click
import sys

from ..util import get_logger


def verbose_opt(func):
    """Wrap the function in a click.option for verbosity."""
    return click.option(
        "-v", "--verbose", count=True,
        help="Increase verbosity (specify multiple times for more)."
    )(func)


def config_opt(func):
    """Wrap the fucntion in a click.option for configurations."""
    return click.option(
        '--config', '-c', type=click.Path(), multiple=True,
        help='The path to an alternate configfile to parse.'
    )(func)


def cli_logger(verbose: int = None):
    """Initialize a logger, provide some debugging output about invocation."""
    logger = get_logger(verbose)
    logger.debug(sys.argv)
    logger.debug(f'verbose: {verbose}')
    return logger
