# SPDX-License-Identifier: MIT
"""A bounded control for one parent-owned cancellation after pytest starts."""

import time


def test_sleep() -> None:
    """Finish after 90 seconds if the owned run is not cancelled."""
    print("#1297 sleeping sentinel started", flush=True)
    time.sleep(90)
