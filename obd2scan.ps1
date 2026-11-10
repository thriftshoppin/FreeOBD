<#
.SYNOPSIS  Lightweight OBD2 scanner for ELM327 adapters (Bluetooth SPP / USB serial).
.USAGE
  .\obd2scan.ps1                 # menu, auto-picks COM port if only one
  .\obd2scan.ps1 -Port COM5      # specify port
  .\obd2scan.ps1 -Port COM5 -Mode Live|Codes|Info|ClearCodes
#>
param(
    [string]$Port,
    [int]$Baud = 38400,
    [ValidateSet('Menu','Live','Codes','Info','ClearCodes','Trims','Freeze','Monitors','Log','Perf')][string]$Mode = 'Menu',
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)


# ---------- connection ----------
function Send-Obd([System.IO.Ports.SerialPort]$sp, [string]$cmd, [int]$timeoutMs = 4000) {
    $sp.DiscardInBuffer()
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

function Get-Bytes([string]$resp, [string]$expectPrefix) {
    # returns data bytes after the expected response header (e.g. "410C"), or $null
    foreach ($line in ($resp -split "[\r\n]+")) {
        $h = ($line -replace '\s', '').ToUpper()
        $i = $h.IndexOf($expectPrefix)
        if ($i -ge 0) {
            $d = $h.Substring($i + $expectPrefix.Length)
            if ($d.Length -ge 2) {
                return ,@(for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { [Convert]::ToInt32($d.Substring($k, 2), 16) })
            }
        }
    }
    $null
}

function Open-Elm {
    $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    if (-not $script:Port) {
        if (-not $ports) { throw "No COM ports found. Pair the OBD2 adapter in Windows Bluetooth settings first (PIN usually 1234 or 0000)." }
        if ($ports.Count -eq 1) { $script:Port = $ports[0] }
        else {
            Write-Host "Available ports: $($ports -join ', ')"
            $script:Port = Read-Host "Port to use"
        }
    }
    foreach ($b in @($Baud, 9600, 115200)) {
        $sp = New-Object System.IO.Ports.SerialPort $script:Port, $b, 'None', 8, 'One'
        $sp.ReadTimeout = 2000; $sp.WriteTimeout = 2000; $sp.NewLine = "`r"
        try { $sp.Open() } catch { Write-Host "Cannot open $($script:Port): $($_.Exception.Message)"; return $null }
        $r = Send-Obd $sp 'ATZ' 3000
        if ($r -match 'ELM|OBD|V\d') {
            Write-Host "Adapter: $(($r -split "[\r\n]+" | Where-Object { $_ -match 'ELM|OBD' } | Select-Object -First 1)) on $($script:Port) @ $b baud"
            foreach ($c in 'ATE0','ATL0','ATS0','ATH0','ATSP0') { [void](Send-Obd $sp $c) }
            return $sp
        }
        $sp.Close(); $sp.Dispose()
    }
    Write-Host "No ELM327 response on $($script:Port)."; $null
}

# ---------- PID table: pid, label, unit, decoder ----------
$Pids = @(
    @{ P='0104'; N='Engine load';      U='%';    F={ param($a) [math]::Round($a[0]*100/255,1) } },
    @{ P='0105'; N='Coolant temp';     U='C';    F={ param($a) $a[0]-40 } },
    @{ P='010C'; N='RPM';              U='rpm';  F={ param($a) [math]::Round((256*$a[0]+$a[1])/4) } },
    @{ P='010D'; N='Speed';            U='km/h'; F={ param($a) $a[0] } },
    @{ P='010F'; N='Intake air temp';  U='C';    F={ param($a) $a[0]-40 } },
    @{ P='0110'; N='MAF';              U='g/s';  F={ param($a) [math]::Round((256*$a[0]+$a[1])/100,2) } },
    @{ P='0106'; N='STFT bank1';       U='%';    F={ param($a) [math]::Round(($a[0]-128)*100/128,1) } },
    @{ P='0107'; N='LTFT bank1';       U='%';    F={ param($a) [math]::Round(($a[0]-128)*100/128,1) } },
    @{ P='0108'; N='STFT bank2';       U='%';    F={ param($a) [math]::Round(($a[0]-128)*100/128,1) } },
    @{ P='0109'; N='LTFT bank2';       U='%';    F={ param($a) [math]::Round(($a[0]-128)*100/128,1) } },
    @{ P='010B'; N='MAP';              U='kPa';  F={ param($a) $a[0] } },
    @{ P='010E'; N='Timing advance';   U='deg';  F={ param($a) [math]::Round($a[0]/2-64,1) } },
    @{ P='0133'; N='Baro';             U='kPa';  F={ param($a) $a[0] } },
    @{ P='0144'; N='Cmd lambda';       U='';     F={ param($a) [math]::Round((256*$a[0]+$a[1])/32768,3) } },
    @{ P='015E'; N='Fuel rate';        U='L/h';  F={ param($a) [math]::Round((256*$a[0]+$a[1])/20,2) } },
    @{ P='0111'; N='Throttle';         U='%';    F={ param($a) [math]::Round($a[0]*100/255,1) } },
    @{ P='012F'; N='Fuel level';       U='%';    F={ param($a) [math]::Round($a[0]*100/255,1) } },
    @{ P='0142'; N='Control module V'; U='V';    F={ param($a) [math]::Round((256*$a[0]+$a[1])/1000,2) } }
)

function Read-Pid($sp, $def) {
    $r = Send-Obd $sp $def.P
    $bytes = Get-Bytes $r ('41' + $def.P.Substring(2))
    if ($null -eq $bytes) { return $null }
    & $def.F $bytes
}

function Show-Live($sp) {
    Write-Host "Live data - press Q to stop.`n"
    $supported = @{}
    foreach ($d in $Pids) { $supported[$d.P] = ($null -ne (Read-Pid $sp $d)) }
    $top = [Console]::CursorTop
    while ($true) {
        [Console]::SetCursorPosition(0, $top)
        foreach ($d in $Pids) {
            if (-not $supported[$d.P]) { continue }
            $v = Read-Pid $sp $d
            $txt = if ($null -eq $v) { '--' } else { "$v $($d.U)" }
            Write-Host ("{0,-18}{1,-16}" -f $d.N, $txt)
        }
        $bv = Send-Obd $sp 'ATRV' 1500
        Write-Host ("{0,-18}{1,-16}" -f 'Adapter voltage', $bv)
        if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Q')) { break }
    }
}

function Get-Supported($sp) {
    $s = @()
    foreach ($d in $Pids) { if ($null -ne (Read-Pid $sp $d)) { $s += $d } }
    $s
}

# ---------- datalogging (CSV, opens in Excel / HP Tuners / EFILive viewers) ----------
function Start-Log($sp) {
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    $file = Join-Path $LogDir ("obd_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
    $sup = Get-Supported $sp
    Write-Host "Logging $($sup.Count) PIDs to $file - press Q to stop."
    $w = New-Object IO.StreamWriter $file
    $w.WriteLine((@('time_s') + ($sup | ForEach-Object { "$($_.N) [$($_.U)]" })) -join ',')
    $sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0
    try {
        while ($true) {
            $row = @([math]::Round($sw.Elapsed.TotalSeconds,2))
            foreach ($d in $sup) { $row += (Read-Pid $sp $d) }
            $w.WriteLine($row -join ','); $n++
            if ($n % 10 -eq 0) { $w.Flush(); Write-Host -NoNewline "`r$n samples  $([math]::Round($n/$sw.Elapsed.TotalSeconds,1)) Hz   " }
            if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Q')) { break }
        }
    } finally { $w.Close() }
    Write-Host "`nSaved $file"
}

# ---------- fuel trims: lean/rich diagnosis ----------
function Show-Trims($sp) {
    Write-Host "Reading fuel trims at idle (let the engine warm up first)..."
    $names = 'STFT bank1','LTFT bank1','STFT bank2','LTFT bank2'
    foreach ($n in $names) {
        $d = $Pids | Where-Object { $_.N -eq $n }
        $v = Read-Pid $sp $d
        if ($null -eq $v) { Write-Host ("{0,-12} n/a" -f $n); continue }
        $note = if ($v -gt 10) { 'LEAN (ECU adding fuel: vacuum leak, weak fuel pump/injector, MAF dirty)' }
                elseif ($v -lt -10) { 'RICH (ECU removing fuel: leaking injector, high fuel pressure)' }
                elseif ([math]::Abs($v) -gt 5) { 'slightly off' } else { 'ok' }
        Write-Host ("{0,-12} {1,6} %  {2}" -f $n, $v, $note)
    }
}

# ---------- freeze frame (snapshot when the last code set) ----------
function Show-Freeze($sp) {
    $r = Send-Obd $sp '020200'
    $b = Get-Bytes $r '420200'
    if ($b) { Write-Host ("Freeze frame was triggered by code: {0}" -f (ConvertTo-Dtc $b[0] $b[1])) } else { Write-Host 'No freeze frame stored.'; return }
    foreach ($d in $Pids) {
        $code = $d.P.Substring(2)
        $r = Send-Obd $sp ("02{0}00" -f $code)
        $v = Get-Bytes $r ("42{0}00" -f $code)
        if ($v) { Write-Host ("{0,-18}{1} {2}" -f $d.N, (& $d.F $v), $d.U) }
    }
}

# ---------- readiness monitors (emissions test status) ----------
function Show-Monitors($sp) {
    $b = Get-Bytes (Send-Obd $sp '0101') '4101'
    if (-not $b -or $b.Count -lt 4) { Write-Host 'Monitor status unavailable.'; return }
    Write-Host ("MIL (check engine): {0}   Stored codes: {1}" -f $(if ($b[0] -band 0x80) {'ON'} else {'off'}), ($b[0] -band 0x7F))
    $mon = @(
        @('Misfire',       ($b[1] -band 1),  ($b[1] -band 0x10)),
        @('Fuel system',   ($b[1] -band 2),  ($b[1] -band 0x20)),
        @('Components',    ($b[1] -band 4),  ($b[1] -band 0x40)),
        @('Catalyst',      ($b[2] -band 1),  ($b[3] -band 1)),
        @('Heated catalyst',($b[2] -band 2), ($b[3] -band 2)),
        @('EVAP',          ($b[2] -band 4),  ($b[3] -band 4)),
        @('Sec. air',      ($b[2] -band 8),  ($b[3] -band 8)),
        @('A/C',           ($b[2] -band 16), ($b[3] -band 16)),
        @('O2 sensor',     ($b[2] -band 32), ($b[3] -band 32)),
        @('O2 heater',     ($b[2] -band 64), ($b[3] -band 64)),
        @('EGR/VVT',       ($b[2] -band 128),($b[3] -band 128))
    )
    foreach ($m in $mon) {
        if (-not $m[1]) { continue }
        Write-Host ("{0,-16}{1}" -f $m[0], $(if ($m[2]) { 'NOT READY' } else { 'ready' }))
    }
}

# ---------- performance: 0-60, quarter mile, rough power estimate ----------
function Start-Perf($sp) {
    $dSpd = $Pids | Where-Object { $_.P -eq '010D' }
    $dMaf = $Pids | Where-Object { $_.P -eq '0110' }
    $dRpm = $Pids | Where-Object { $_.P -eq '010C' }
    $kmh2mph = 0.621371
    Write-Host "Perf run: stop on a safe, legal closed course or dyno. Waiting for car to be stationary... (Q to cancel)"
    while ($true) {
        if ((Read-Pid $sp $dSpd) -eq 0) { break }
        if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Q')) { return }
    }
    Write-Host "ARMED - timing starts when you launch."
    while ((Read-Pid $sp $dSpd) -eq 0) {
        if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Q')) { return }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $dist = 0.0; $last = 0.0; $lastV = 0.0; $t60 = $null; $tq = $null; $peakMaf = 0.0; $peakMafRpm = 0; $top = 0
    while ($sw.Elapsed.TotalSeconds -lt 40) {
        $v = Read-Pid $sp $dSpd; $t = $sw.Elapsed.TotalSeconds
        if ($null -eq $v) { continue }
        $mph = $v * $kmh2mph; if ($mph -gt $top) { $top = $mph }
        $dist += (($mph + $lastV) / 2) * 0.44704 * ($t - $last)   # meters
        $last = $t; $lastV = $mph
        if (-not $t60 -and $mph -ge 60) { $t60 = $t; Write-Host ("0-60 mph: {0:N2} s" -f $t60) }
        if (-not $tq -and $dist -ge 402.336) { $tq = $t; Write-Host ("1/4 mile: {0:N2} s @ {1:N0} mph" -f $tq, $mph) }
        $m = Read-Pid $sp $dMaf
        if ($m -and $m -gt $peakMaf) { $peakMaf = $m; $peakMafRpm = Read-Pid $sp $dRpm }
        if ($tq -or $mph -lt 1 -and $t -gt 3) { break }
        if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).Key -eq 'Q')) { break }
    }
    if ($peakMaf -gt 0) {
        # ~1.25 hp per g/s of airflow (BSFC ~0.5): rough crank-hp ballpark, NOT a dyno
        Write-Host ("Peak MAF {0} g/s @ {1} rpm  =>  ~{2:N0} hp (rough estimate)" -f $peakMaf, $peakMafRpm, ($peakMaf * 1.25))
    }
    Write-Host ("Top speed reached: {0:N0} mph. Sample rate is limited by Bluetooth, so times can be off by ~0.2 s." -f $top)
}

# ---------- trouble codes ----------
function ConvertTo-Dtc([int]$hi, [int]$lo) {
    $letter = 'P','C','B','U'
    $l = $letter[($hi -shr 6) -band 3]
    $d1 = ($hi -shr 4) -band 3
    $d2 = $hi -band 15
    '{0}{1}{2:X}{3:X2}' -f $l, $d1, $d2, $lo
}

function Show-Codes($sp, [string]$mode, [string]$label) {
    $r = Send-Obd $sp $mode 6000
    $hdr = '{0:X2}' -f ([Convert]::ToInt32($mode,16) + 0x40)
    $codes = @()
    foreach ($line in ($r -split "[\r\n]+")) {
        $h = ($line -replace '\s','').ToUpper()
        if ($h.StartsWith($hdr)) {
            $d = $h.Substring(2)
            # skip count byte on CAN-style responses when length is odd in pairs
            if ($d.Length % 4 -eq 2) { $d = $d.Substring(2) }
            for ($k = 0; $k + 3 -lt $d.Length; $k += 4) {
                $hi = [Convert]::ToInt32($d.Substring($k,2),16); $lo = [Convert]::ToInt32($d.Substring($k+2,2),16)
                if ($hi -ne 0 -or $lo -ne 0) { $codes += ConvertTo-Dtc $hi $lo }
            }
        }
    }
    if ($r -match 'NO DATA' -or -not $codes) { Write-Host "${label}: none" }
    else { Write-Host "${label}: $($codes -join ', ')" }
}

function Show-Info($sp) {
    Write-Host "Protocol: $(Send-Obd $sp 'ATDPN')"
    Write-Host "Adapter voltage: $(Send-Obd $sp 'ATRV')"
    $vin = Send-Obd $sp '0902' 6000
    $hex = ($vin -split "[\r\n]+" | ForEach-Object { ($_ -replace '\s','') -replace '^\d:','' }) -join ''
    $i = $hex.IndexOf('4902')
    if ($i -ge 0) {
        $d = $hex.Substring($i + 4)
        $chars = for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { $n = [Convert]::ToInt32($d.Substring($k,2),16); if ($n -ge 48 -and $n -le 90) { [char]$n } }
        $v = -join $chars
        if ($v.Length -ge 17) { Write-Host "VIN: $($v.Substring($v.Length-17))" } else { Write-Host "VIN: unavailable" }
    } else { Write-Host "VIN: not supported by this vehicle" }
    Show-Codes $sp '03' 'Stored codes'
}

# ---------- main ----------
$sp = Open-Elm
if (-not $sp) { exit 1 }
try {
    switch ($Mode) {
        'Live'       { Show-Live $sp }
        'Codes'      { Show-Codes $sp '03' 'Stored codes'; Show-Codes $sp '07' 'Pending codes' }
        'Info'       { Show-Info $sp }
        'Trims'      { Show-Trims $sp }
        'Freeze'     { Show-Freeze $sp }
        'Monitors'   { Show-Monitors $sp }
        'Log'        { Start-Log $sp }
        'Perf'       { Start-Perf $sp }
        'ClearCodes' {
            if ((Read-Host "Clear codes and reset check-engine light? (y/N)") -eq 'y') { Send-Obd $sp '04' 4000; Write-Host 'Cleared.' }
        }
        'Menu' {
            while ($true) {
                Write-Host "`nDIAGNOSE: 2) Codes  3) Info/VIN  4) Clear codes  5) Fuel trims  6) Freeze frame  7) Readiness"
                Write-Host "LOG/TUNE: 1) Live data  8) Datalog to CSV  9) 0-60 / 1/4 mile / hp estimate   Q) Quit"
                switch ((Read-Host '>').ToUpper()) {
                    '5' { Show-Trims $sp }
                    '6' { Show-Freeze $sp }
                    '7' { Show-Monitors $sp }
                    '8' { Start-Log $sp }
                    '9' { Start-Perf $sp }
                    '1' { Show-Live $sp }
                    '2' { Show-Codes $sp '03' 'Stored codes'; Show-Codes $sp '07' 'Pending codes' }
                    '3' { Show-Info $sp }
                    '4' { if ((Read-Host 'Clear codes and reset check-engine light? (y/N)') -eq 'y') { [void](Send-Obd $sp '04' 4000); Write-Host 'Cleared.' } }
                    'Q' { return }
                }
            }
        }
    }
} finally { $sp.Close(); $sp.Dispose() }
