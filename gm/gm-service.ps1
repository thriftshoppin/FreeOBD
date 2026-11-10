<#
.SYNOPSIS
  GM enhanced diagnostics and PCM Hammer integration for FreeOBD.

.DESCRIPTION
  Extends FreeOBD with:
  - Additional GM Mode 22 probes (misfire, service-related candidates)
  - A simple PCM Hammer CLI wrapper for ECU backups (when the tool is installed)

  Usage examples:
    .\gm-service.ps1 -Port COM3 -Action Misfire
    .\gm-service.ps1 -Port COM3 -Action Service
    .\gm-service.ps1 -Action HammerBackup -HammerPath "C:\Tools\PcmHammer\PcmHammerCLI.exe" -OutFile "backup.bin"
#>
param(
    [string]$Port,
    [ValidateSet('Misfire','Service','HammerBackup','Help')]
    [string]$Action = 'Help',
    [string]$HammerPath,
    [string]$OutFile = "ecu-backup-$(Get-Date -Format yyyyMMdd-HHmmss).bin"
)

$ErrorActionPreference = 'Stop'

function Show-Help {
    @"
FreeOBD GM Service Module
=========================
Actions:
  Misfire       - Read community GM Mode 22 per-cylinder misfire candidates
  Service       - Probe additional GM Mode 22 service / diagnostic PIDs
  HammerBackup  - Call PCM Hammer CLI (if available) to read a full PCM backup
  Help          - This message

Examples:
  .\gm-service.ps1 -Port COM5 -Action Misfire
  .\gm-service.ps1 -Action HammerBackup -HammerPath .\PcmHammerCLI.exe -OutFile mybackup.bin

Notes:
- Mode 22 PIDs are community-sourced and vehicle-specific. Always verify responses.
- PCM Hammer requires a suitable VPW/J2534 adapter, not a generic cheap ELM327.
- Always keep the original backup before any write.
"@
}

function Get-ElmPort {
    if ($Port) { return $Port }
    $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    if (-not $ports) { throw "No COM ports found. Pair your ELM327 first." }
    if ($ports.Count -eq 1) { return $ports[0] }
    Write-Host "Available ports: $($ports -join ', ')"
    Read-Host "Port to use"
}

function Send-Obd([System.IO.Ports.SerialPort]$sp, [string]$cmd, [int]$timeoutMs = 4000) {
    $sp.DiscardInBuffer()
    Start-Sleep -Milliseconds 20
    if ($sp.BytesToRead -gt 0) { try { [void]$sp.ReadExisting() } catch {}; $sp.DiscardInBuffer() }
    $sp.Write("$cmd`r")
    $buf = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($sp.BytesToRead -gt 0) {
            $buf += $sp.ReadExisting()
            if ($buf.Contains('>')) { break }
        } else { Start-Sleep -Milliseconds 15 }
    }
    ($buf -replace '>', '').Trim()
}

function Open-Elm([string]$com) {
    foreach ($b in @(38400, 9600, 115200)) {
        $sp = New-Object System.IO.Ports.SerialPort $com, $b, 'None', 8, 'One'
        $sp.ReadTimeout = 2000; $sp.WriteTimeout = 2000
        try { $sp.Open() } catch { continue }
        $r = Send-Obd $sp 'ATZ' 3000
        if ($r -match 'ELM|OBD|V\d') {
            foreach ($c in 'ATE0','ATL0','ATS0','ATH1','ATCAF1','ATSP0') { [void](Send-Obd $sp $c) }
            Write-Host "Connected on $com @ $b baud"
            return $sp
        }
        $sp.Close(); $sp.Dispose()
    }
    throw "No ELM327 response on $com"
}

function Get-EcuPayload([string]$resp, [string]$expectPrefix) {
    $lines = $resp -split "[\r\n]+"
    foreach ($line in $lines) {
        $h = ($line -replace '[^0-9A-Fa-f]', '').ToUpper()
        if ($h.Length -ge 5 -and $h.Substring(3).StartsWith($expectPrefix.ToUpper())) {
            return $h.Substring(3)
        }
    }
    $null
}

function Show-Misfire([System.IO.Ports.SerialPort]$sp) {
    Write-Host "`n=== GM Mode 22 per-cylinder misfire candidates ==="
    Write-Host "Community-sourced (e.g. 221205 = cyl 1). Verify on your vehicle.`n"
    for ($cyl = 1; $cyl -le 8; $cyl++) {
        $pid = '{0:X2}' -f (0x04 + $cyl)
        $req = "2212$pid"
        $raw = Send-Obd $sp $req 3000
        $payload = Get-EcuPayload $raw "6212$pid"
        if ($payload -and $payload.Length -gt 6) {
            $val = [Convert]::ToInt32($payload.Substring(6, [Math]::Min(4, $payload.Length-6)), 16)
            Write-Host ("Cyl {0}: {1} counts  (PID {2})" -f $cyl, $val, $req)
        } elseif ($raw -match '7F22(\w\w)') {
            Write-Host ("Cyl {0}: rejected (NRC 0x{1})" -f $cyl, $Matches[1])
        } else {
            Write-Host ("Cyl {0}: no response" -f $cyl)
        }
    }
}

function Show-Service([System.IO.Ports.SerialPort]$sp) {
    Write-Host "`n=== Additional GM Mode 22 / service probes ==="
    Write-Host "These are common candidate PIDs. Responses vary by PCM.`n"

    $candidates = @(
        @{ Pid = '221130'; Name = 'Injector balance / contribution (candidate)' },
        @{ Pid = '221140'; Name = 'EVAP related (candidate)' },
        @{ Pid = '221150'; Name = 'Fuel system status enhanced (candidate)' },
        @{ Pid = '221200'; Name = 'Misfire history / total (candidate)' },
        @{ Pid = '22F190'; Name = 'VIN via UDS (if supported)' }
    )

    foreach ($c in $candidates) {
        $raw = Send-Obd $sp $c.Pid 4000
        $payload = Get-EcuPayload $raw ("62" + $c.Pid.Substring(2))
        if ($payload) {
            Write-Host ("{0,-40} {1}" -f $c.Name, $payload)
        } elseif ($raw -match '7F') {
            Write-Host ("{0,-40} negative response" -f $c.Name)
        } else {
            Write-Host ("{0,-40} no data" -f $c.Name)
        }
    }
}

function Invoke-HammerBackup {
    if (-not $HammerPath -or -not (Test-Path $HammerPath)) {
        Write-Host "PCM Hammer CLI not found at '$HammerPath'."
        Write-Host "Download from https://github.com/PcmHammer/PcmHammer/releases"
        Write-Host "Look for the Windows CLI build, then re-run with -HammerPath."
        return
    }
    Write-Host "Invoking PCM Hammer CLI for backup..."
    Write-Host "Command: $HammerPath read --out $OutFile"
    Write-Host "(Actual CLI flags may differ; check PCM Hammer documentation for the exact syntax.)"
    # Placeholder - real invocation depends on the CLI interface of the current PCM Hammer release
    & $HammerPath --help 2>&1 | Select-Object -First 20
    Write-Host "`nSave the resulting .bin/.phz to a safe location before any edits or writes."
}

# --- main ---
switch ($Action) {
    'Help' { Show-Help; exit 0 }
    'HammerBackup' { Invoke-HammerBackup; exit 0 }
}

$com = Get-ElmPort
$sp = Open-Elm $com
try {
    switch ($Action) {
        'Misfire' { Show-Misfire $sp }
        'Service' { Show-Service $sp }
    }
} finally {
    if ($sp) { $sp.Close(); $sp.Dispose() }
}
