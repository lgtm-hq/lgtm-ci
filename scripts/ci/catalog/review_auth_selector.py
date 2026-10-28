#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Represent the evidence available for one review authentication selector."""

from dataclasses import dataclass
from enum import StrEnum, auto


class SelectorSource(StrEnum):
    """Distinguish explicit inputs, inspected variables, and unknown selectors."""

    INPUT = auto()
    VARIABLE = auto()
    UNVERIFIED = auto()


@dataclass(frozen=True)
class ReviewAuthSelector:
    """Hold a selector value and whether its source could be inspected."""

    value: str
    source: SelectorSource
