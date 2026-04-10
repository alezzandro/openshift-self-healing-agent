#!/bin/bash
###############################################################################
#  reset-eda.sh  — UC3: Node Disk Pressure
#
#  Restarts the EDA activation to clear the 3-hour throttle for
#  NodeFilesystemSpaceFillingUp, so the same scenario can be triggered
#  again to demonstrate the "known incident" path.
#
#  Run this BETWEEN the first run (new incident) and second run
#  (known incident) of the same use case.
#
#  This does NOT wipe the knowledge base or Job Templates — the
#  resolution stored during the first run is preserved.
#
#  Sequence:
#    1. ./trigger.sh            → first run  (new incident path)
#    2. ./cleanup.sh            → restore cluster health
#    3. ./reset-eda.sh          → clear throttle  ← YOU ARE HERE
#    4. ./trigger.sh            → second run (known incident path)
#    5. ./cleanup.sh            → final cleanup
###############################################################################

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../reset-eda.sh"
