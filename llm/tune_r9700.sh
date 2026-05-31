#!/usr/bin/env bash
# Undervolt + power-cap tuning for the AMD Radeon AI PRO R9700 (RDNA4 / gfx1201) on hopper.
#
#   on  : -75mV VDDGFX offset (committed in `manual`, then back to `auto` so idle DPM is
#         preserved) + 315W power cap.
#   off : restore stock (0mV offset, default power cap), stays in `auto`.
#
# Prereq: amdgpu OverDrive enabled via ppfeaturemask (/etc/modprobe.d/amdgpu.conf,
#         options amdgpu ... ppfeaturemask=0xfff7ffff). Without it pp_od_clk_voltage and
#         the 330W cap ceiling do not exist.
#
# Validated 2026-05-31 on kernel 7.0.9: the -75mV offset persists in `auto`; under qwen-27b
# load the card was power-limited at 300W for 95/120 samples at only 69C (power-bound, not
# thermal-bound), so the 315W cap converts near-directly to sustained clock. cap_max=330W.
set -euo pipefail

VENDOR_DEVICE="1002:7551"   # R9700; resolved to a card path by PCI id (robust to card0/card1 reorder)
UV_MV=75                    # undervolt magnitude in mV, applied as a negative VDDGFX offset
CAP_W=315                   # power cap in watts (must be <= power1_cap_max, currently 330)

if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo "$0" "$@"; fi

# Locate the PCI device by vendor:device. The amdgpu sysfs knobs (pp_od_clk_voltage,
# power_dpm_force_performance_level, hwmon/) live directly here; /sys/class/drm/cardN/device
# is just a symlink back to it, so no card-name resolution is needed.
dev=""
for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x${VENDOR_DEVICE%%:*}" ] || continue
    [ "$(cat "$d/device" 2>/dev/null)" = "0x${VENDOR_DEVICE##*:}" ] || continue
    dev="$d"
    break
done
[ -n "$dev" ] && [ -e "$dev/pp_od_clk_voltage" ] || { echo "R9700 ($VENDOR_DEVICE) not found"; exit 1; }

od="$dev/pp_od_clk_voltage"
pl="$dev/power_dpm_force_performance_level"
cap=$(echo "$dev"/hwmon/hwmon*/power1_cap)
capdef=$(echo "$dev"/hwmon/hwmon*/power1_cap_default)

status() {
    echo "card      : $dev"
    echo "perf_level: $(cat "$pl")"
    echo "power_cap : $(( $(cat "$cap")/1000000 ))W (default $(( $(cat "$capdef")/1000000 ))W)"
    grep -A1 'OD_VDDGFX_OFFSET' "$od" || true
}

set_offset() {  # $1 = mV (signed), committed via manual then restored to auto
    echo manual > "$pl"
    echo "vo $1" > "$od"
    echo c > "$od"
    echo auto > "$pl"
}

case "${1:-status}" in
    on|apply)
        set_offset "-$UV_MV"
        echo $((CAP_W * 1000000)) > "$cap"
        echo "applied: -${UV_MV}mV, ${CAP_W}W"
        status
        ;;
    off|reset)
        set_offset 0
        cat "$capdef" > "$cap"
        echo "reset to stock"
        status
        ;;
    status)
        status
        ;;
    *)
        echo "usage: ${0##*/} {on|off|status}" >&2
        exit 2
        ;;
esac
