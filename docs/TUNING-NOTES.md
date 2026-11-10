# Tuning notes (work in progress)

## Why a generic ELM327 can't tune

Tuning rewrites the ECU's calibration (fuel, spark, boost tables). That needs manufacturer-specific flash protocols over a fast CAN link, often with seed-key security. Generic ELM327 adapters only speak the standard read-only diagnostic requests, and Bluetooth clones can drop the link, which can brick an ECU mid-flash. FreeOBD will not write calibrations through a generic ELM327.

What FreeOBD can do today is read and log the data a tuner needs: fuel trims, timing, MAF, lambda, load.

## Reading fuel trims

- Long-term trim within about +/-10% is healthy.
- Large positive long-term trim: the ECU is adding fuel to fix a lean condition (vacuum leak, weak fuel delivery, dirty MAF, or a fuel needing more fuel such as ethanol blends).
- Most GM ECUs cap long-term trim near +25%. At the cap, the ECU can't correct further and lean codes (e.g. P2177 / P2179) and misfires can follow.

## Example: running E85 on a non-flex-fuel engine

A non-flex-fuel engine on E85 needs roughly 30-40% more fuel than gasoline. The ECU's trim limit isn't enough, so expect lean codes and a check-engine light. Fixing it properly means a real tune plus hardware headroom (injector size, fuel pump, fuel system materials), and ideally an ethanol content sensor. E85 also has about 25-30% less energy per gallon, so it only saves money when it is much cheaper per gallon.

## Planned

- Datalog analysis helpers (trim maps, lean/rich under load)
- Integration notes for existing tuning tools
