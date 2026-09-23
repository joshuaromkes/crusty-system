#!/usr/bin/env bash
# Manual probe for the module-checklist pitfall guard (test 5).
# Defaults mirror crusty.sh: fail2ban+maintenance ON, docker OFF, no flags.
ENABLE_DOCKER=false
ENABLE_FAIL2BAN=true
ENABLE_MAINTENANCE=true
calls=0
ui_box()   { echo "box-ran"; return 0; }              # empty selection each time
ui_yesno() { calls=$((calls + 1)); echo "yesno-called-$calls"; return 1; }  # No: re-show
source <(bash tests/extract.sh prompt_modules)
prompt_modules
echo "rc=$? calls=$calls"