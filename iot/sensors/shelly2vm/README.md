# shelly2vm

Scrapes Shelly Gen2+ devices over local HTTP RPC and pushes to VictoriaMetrics
(`/api/v1/import/prometheus`). Push, not scrape — the devices sit on a remote
LAN with no inbound route.

## Device classes

Two flags, because the failure modes are genuinely different:

- `-devices` — mains-powered. Polled every `-interval` (30s). A failure is a
  real outage and emits `shelly_up 0`.
- `-sleepy` — battery sensors (H&T) that deep-sleep between wakes. Polled every
  `-sleepy-interval` (1s) and **silent on failure**: asleep is not down, so a
  gap in the series means "no reading", never "device offline".

Each device runs on its own goroutine; a slow or absent one never stalls the rest.

## Notes

- Build with `CGO_ENABLED=0` — NixOS hosts reject dynamically linked
  generic-Linux binaries.
- Optional metered fields are `*float64`, so a device without power metering
  (e.g. Shelly Plus 1) emits no wattage rather than a misleading `0`.
- Site-specific addresses are deliberately not in this repo.

## Run

    shelly2vm -devices "label=10.0.0.2,other=10.0.0.3" \
              -sleepy "sensor=10.0.0.4" \
              -vm-host hopper

`-dry-run` prints the exposition instead of pushing; `-once` polls a single
round and exits.
