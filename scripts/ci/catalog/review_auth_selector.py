#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Represent the evidence available for one review authentication selector."""

from dataclasses import dataclass
from enum import StrEnum, auto


class SelectorSource(StrEnum):
    """Identify the evidence for a known selector."""

    INPUT = auto()
    VARIABLE = auto()


@dataclass(frozen=True)
class ReviewAuthSelector:
    """Hold KNOWN(value, source); None represents UNKNOWN instead."""

    value: str
    source: SelectorSource
