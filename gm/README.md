# GM Enhanced Diagnostics & Tuning Integration

FreeOBD is an ELM327-based scanner. Full GM VPW PCM flashing/backups require a different adapter and toolset.

## Recommended open-source stack

| Tool | Purpose | Link |
|------|---------|------|
| **PCM Hammer** | Read/write GM VPW PCMs (P01, P59, P04, Black Box, etc.). CLI available. | https://github.com/PcmHammer/PcmHammer |
| **UniversalPatcher** | Edit bins, apply patches, generate XDFs, checksums. Often bundles PCM Hammer. | https://github.com/joukoy/UniversalPatcher |
| **TunerPro** | Table editor (uses XDF definitions from pcmhacking.net). | http://tunerpro.net |

**Hardware note:** Cheap Bluetooth ELM327 clones are unreliable for flashing. PCM Hammer recommends OBDX Pro, OBDLink, or proper J2534 devices. Bench flashing with a good 12.5–14 V supply is safest.

## Workflow (backup → edit → flash)

1. Use FreeOBD to identify the vehicle (VIN, Mode 09 cal ID / CVN, codes, misfires).
2. Use PCM Hammer (or the `gm-service.ps1` wrapper below) to **read a full backup**. Save the `.bin` or `.phz` somewhere safe.
3. Edit the backup with UniversalPatcher or TunerPro + matching XDF (OSID from Mode 09 or PCM Hammer).
4. Write the modified file back with PCM Hammer. Always keep the original backup.
5. Return to FreeOBD for live data, fuel trims, misfire counters, and logging.

## Already available in FreeOBD

- Live data, fuel trims, codes, freeze frame, readiness monitors
- Mode 06 raw monitor results
- Mode 09 (VIN, Cal ID, ECU name, CVN) per module
- GM Mode 22 per-cylinder misfire candidate PIDs (community-sourced, verify on your vehicle)
- CSV datalogging

## New in this expansion

- `gm/gm-service.ps1`: enhanced GM Mode 22 probes + PCM Hammer CLI wrapper for backups
- Better documentation and safety notes

## Safety

Never flash without a verified backup. Mid-flash power loss or a bad adapter can brick the PCM. Check pcmhacking.net for your specific PCM and hardware recommendations.
