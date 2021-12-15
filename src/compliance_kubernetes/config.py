"""Compliance Kubernetes - Apply and measure compliance profiles.

This module contains the configuration logic for the compliance-kubernetes
tooling.
"""

import json

from enum import Enum

from pydantic import BaseModel
from typing import Optional


class StrEnum(str, Enum):
    """Represent a choice between a fixed set of strings.

    A mix-in of string and enum, representing itself as the string value.
    """

    @classmethod
    def list(cls) -> list:
        """Return a list of the available options in the Enum."""
        return [e.value for e in cls]

    def __str__(self) -> str:
        """Return only the value of the enum when cast to String."""
        return self.value


class ComplianceKubernetesBaseModel(BaseModel):
    """Compliance Kubernetes base model for configuration classes."""

    class Config:
        """Configuration class for Pydantic models."""

        allow_population_by_field_name = True


class PydanticEncoder(json.JSONEncoder):
    """Serialize Pydantic models.

    A JSONEncoder subclass that prepares Pydantic models for serialization.
    """

    def default(self, obj):
        """Encode model objects based on their type."""
        if isinstance(obj, BaseModel) and callable(obj.dict):
            return obj.dict(exclude_none=True)
        else:  # pragma: nocover
            return json.JSONEncoder.default(self, obj)

class ComplianceKubernetesOperatorConfig(ComplianceKubernetesBaseModel):
    """Configuration model representing Operator configuration."""

    version: str = '0.1.44'
    channel: str = 'release-0.1'

class ComplianceKubernetesClusterConfig(ComplianceKubernetesBaseModel):
    """Configuration model representing Cluster configuration."""

    context: Optional[str]
