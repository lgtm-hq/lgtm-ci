#!/usr/bin/env node
// Committed WITHOUT the executable bit on purpose (mode 100644): the
// self-test proves publish-set.sh's restore_bin_modes() repairs it before
// npm pack, the way a workflow-artifact handoff would have dropped it.
console.log("npm-set self-test launcher");
