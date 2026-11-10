# Sample output

Real readings from a 2013 Chevrolet Camaro RS (3.6L V6) running E85, an ethanol blend the engine is not designed for. The VIN is not included.

## Trouble codes

| Code | Meaning |
|---|---|
| P2177 | System too lean off idle, bank 1 |
| P2179 | System too lean off idle, bank 2 |
| P0305 | Cylinder 5 misfire detected |

## Fuel trims at idle (warm-up in progress)

| | Bank 1 | Bank 2 |
|---|---|---|
| Short-term | -7% | -6.2% |
| Long-term | +18.8% | +26.6% |

Long-term trims near the ECU's ~+25% limit show it adding as much fuel as it can, which is what the lean codes reflect.

## Datalog

`sample-idle-log.csv` is one idle sample as written by the logger (RPM, load, MAF, trims, timing, lambda, voltage and more).
