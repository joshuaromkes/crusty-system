# Issues Log

## Monitor Manager - Oscillation Issue (RESOLVED)

**Date**: 2026-03-17  
**Status**: Fixed in v1.1  
**Severity**: High

### Problem Description

Monitor Manager was causing monitors to move around on every refresh cycle, and the dummy monitor appeared to enable/disable repeatedly.

### Root Cause

The `get_output_status()` function in [`monitor-manager.sh`](../../scripts/arch/monitor-manager.sh) was incorrectly parsing `kscreen-doctor -o` output due to **two separate issues**:

**Issue 1: ANSI Color Codes**
`kscreen-doctor` outputs ANSI color codes (e.g., `[01;32m`, `[0;0m`) which interfered with field extraction in awk. The script was trying to match field `$3` but the color codes shifted the field positions.

**Issue 2: Single-line Parsing**
The function only captured the first line of each output block:
```
Output: 1 HDMI-A-1 5dc97b30-ce4a-41f5-a0d4-44a0de742523
```

But the status keywords (`enabled`, `connected`) appear on subsequent lines:
```
        enabled
        connected
        priority 2
```

**Combined Effect**: This caused the script to:
1. Always detect monitors as "unknown" (due to ANSI codes breaking field matching)
2. Never properly detect "connected" or "enabled" status
3. Repeatedly attempt to enable the dummy monitor
4. Trigger unnecessary `kscreen-doctor` commands that disrupted display layout

### Evidence from Logs

```
[2026-03-17 00:06:08] Status: primary=disconnected, dummy=disconnected
[2026-03-17 00:06:08] Enabling dummy monitor: HDMI-A-1
[2026-03-17 00:06:38] Enabling dummy monitor: HDMI-A-1
[2026-03-17 00:07:09] Enabling dummy monitor: HDMI-A-1
```

But `kscreen-doctor -o` showed both monitors were actually connected and enabled.

### Solution

**Fix 1: Strip ANSI Color Codes**
- Added `sed` command to strip ANSI escape sequences before parsing
- Prevents color codes from interfering with awk field extraction
- Command: `sed 's/\x1b\[[0-9;]*m//g'`

**Fix 2: Corrected Multi-line Parsing**
- Modified `get_output_status()` to capture the entire multi-line block for each output
- Used awk to extract from "Output: X NAME" until the next "Output:" line
- Now correctly detects "enabled" and "connected" keywords

**Fix 3: Added Cooldown Mechanism**
- Added 10-second cooldown period after making changes
- Prevents rapid state oscillation
- Tracks last action to avoid redundant operations

**Fix 4: Action Tracking**
- Tracks what action was last performed
- Prevents immediately reversing actions on next poll cycle
- Only sets primary when needed (not on every cycle)

### Files Modified

- [`scripts/arch/monitor-manager.sh`](../../scripts/arch/monitor-manager.sh) - Fixed parsing and added cooldown
- [`docs/MONITOR-MANAGER-README.md`](../MONITOR-MANAGER-README.md) - Added troubleshooting section

### Testing Recommendations

After reinstalling with the fixed version:

1. Monitor the daemon logs:
   ```bash
   tail -f ~/.local/share/monitor-manager/monitor-manager.log
   ```

2. Verify status detection is correct:
   - Should show `primary=connected enabled, dummy=connected enabled` when both are connected
   - Should NOT repeatedly enable/disable monitors

3. Check for cooldown behavior:
   - After making a change, should wait 10 seconds before next action
   - Should not see the same action repeated every poll interval

### Log Locations

For future debugging:
- **Daemon logs**: `~/.local/share/monitor-manager/monitor-manager.log`
- **Systemd journal**: `journalctl --user -u monitor-manager.service -f`
- **Install logs**: `/var/log/monitor-manager-install.log`
