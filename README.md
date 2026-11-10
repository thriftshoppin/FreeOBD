# FreeOBD

A small, free, no-install OBD2 scanner for Windows. Pure PowerShell, no dependencies. Works with ELM327-type adapters (Bluetooth or USB serial).

> **Work in progress.** Tuning support and more features are planned. See the roadmap.

## Features

- **GUI** (`obd2gui.ps1`): plain Windows window with tabs: Live data, Fuel trims, Codes, Log, Performance.
- **CLI** (`obd2scan.ps1`): menu and one-shot modes for scripting.
- Live sensor data (RPM, speed, coolant, MAF, MAP, timing, throttle, fuel level, trims, lambda, voltage)
- Read stored and pending trouble codes, with descriptions for common ones
- Clear codes (with confirmation)
- Fuel trim view with lean/rich hints
- Freeze frame, readiness monitors, VIN (CLI)
- CSV datalogging
- 0-60 mph and quarter-mile timer (estimates)

## Requirements

- Windows 10/11 with PowerShell 5.1 (included with Windows)
- An ELM327 adapter paired to your PC (Bluetooth adapters appear as a COM port)

## Quick start

1. Plug the adapter into the car's OBD2 port and turn the ignition on.
2. Pair it in **Settings > Bluetooth & devices** (PIN is usually `0000` or `1234`). Note the COM port Windows assigns.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File obd2gui.ps1
# or the command-line version:
powershell -ExecutionPolicy Bypass -File obd2scan.ps1 -Port COM3 -Mode Codes
```

CLI modes: `Menu` (default), `Live`, `Codes`, `Info`, `ClearCodes`, `Trims`, `Freeze`, `Monitors`, `Log`, `Perf`.

`bt-pair.ps1 -Address <12 hex digits>` can pair a classic Bluetooth adapter from the command line by trying common PINs.

## Safety and limits

- Only one program can use the adapter's COM port at a time.
- Clearing codes also erases freeze-frame data and resets emissions readiness monitors.
- The performance timer and power estimate are rough, since Bluetooth sampling is slow. Use a closed course or dyno only.
- Cheap ELM327 clones vary in quality.

## Roadmap

- [ ] Tuning support (see `docs/TUNING-NOTES.md`; flashing needs more than a generic ELM327)
- [ ] Manufacturer-specific PIDs (GM Mode 22)
- [ ] Charts and log playback
- [ ] Fuller trouble code database

## Disclaimer

Use at your own risk. This software is provided as is, without warranty. Not affiliated with any vehicle or adapter manufacturer. Check your local laws before modifying emissions-related settings.

## Sample data

See [docs/SAMPLE-OUTPUT.md](docs/SAMPLE-OUTPUT.md) and [docs/sample-idle-log.csv](docs/sample-idle-log.csv).

## License

MIT. See [LICENSE](LICENSE).
