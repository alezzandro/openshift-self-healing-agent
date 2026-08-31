#!/bin/bash
###############################################################################
#  reset-eda.sh  — GitOps: ImagePullBackOff (bad tag)
#
#  Restarts the EDA activation to clear the 3-hour throttle for
#  DemoCNFImagePullBackOff, so the same scenario can be triggered again
#  to demonstrate the "known incident" path.
#
#  Run this BETWEEN the first run (new incident, manual JT launch) and
#  the second run (known incident, auto JT). Do not wipe the knowledge
#  base or Job Templates — the git-fix resolution from the first run
#  must stay in place.
#
#  Sequence:
#    1. ./trigger.sh            → first run  (new incident; approve JT)
#    2. ./reset-eda.sh          → clear throttle  ← YOU ARE HERE
#    3. ./trigger.sh            → second run (known incident; auto JT)
#    4. ./cleanup.sh            → restore known-good image if needed
###############################################################################

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../reset-eda.sh"
