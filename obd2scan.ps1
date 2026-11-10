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
    [ValidateSet('Menu','Live','Codes','Info','ClearCodes','Trims','Freeze','Monitors','Mode06','Mode09','GmMisfire','Recalls','Log','Perf')][string]$Mode = 'Menu',
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)


# ---------- connection ----------
function Send-Obd([System.IO.Ports.SerialPort]$sp, [string]$cmd, [int]$timeoutMs = 4000) {
    $sp.DiscardInBuffer()
    # This cheap Bluetooth clone can still be flushing a previous response's trailing bytes
    # into the OS buffer a few ms after we saw its '>' prompt and moved on. If we write the
    # next command right then, those stragglers land mixed in with the new reply and corrupt
    # the frame reassembly. A short settle + second drain clears them out first.
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

function Get-EcuBuckets([string]$resp) {
    # CAN cars often have several modules answer the same request at once (normal, not an
    # error). With headers on (ATH1) every line is tagged with its 3-char source CAN ID, so we
    # bucket lines by that header and reassemble each bucket's own ISO-TP payload (single frame
    # or first+consecutive frames). Returns an ordered header -> payload-hex map. This is what
    # stops one module's reply from corrupting another's.
    $buckets = [ordered]@{}
    foreach ($line in ($resp -split "[\r\n]+")) {
        $h = ($line -replace '[^0-9A-Fa-f]', '').ToUpper()
        if ($h.Length -lt 5) { continue }
        $hdr = $h.Substring(0, 3); $rest = $h.Substring(3)
        if (-not $buckets.Contains($hdr)) { $buckets[$hdr] = New-Object System.Collections.Generic.List[string] }
        $buckets[$hdr].Add($rest)
    }
    $out = [ordered]@{}
    foreach ($hdr in $buckets.Keys) {
        $frames = $buckets[$hdr]; $f0 = $frames[0]
        if ($f0.Length -lt 2) { continue }
        $pci = [Convert]::ToInt32($f0.Substring(0, 1), 16); $payload = $null
        if ($pci -eq 0) {
            $len = [Convert]::ToInt32($f0.Substring(1, 1), 16); $data = $f0.Substring(2)
            if ($data.Length -ge $len * 2) { $payload = $data.Substring(0, $len * 2) }
        } elseif ($pci -eq 1) {
            $len = ([Convert]::ToInt32($f0.Substring(1, 1), 16) -shl 8) + [Convert]::ToInt32($f0.Substring(2, 2), 16)
            $acc = $f0.Substring(4)
            for ($i = 1; $i -lt $frames.Count -and ($acc.Length / 2) -lt $len; $i++) {
                $fr = $frames[$i]; if ($fr.Length -lt 2) { continue }
                if ([Convert]::ToInt32($fr.Substring(0, 1), 16) -ne 2) { continue }
                $acc += $fr.Substring(2)
            }
            if (($acc.Length / 2) -ge $len) { $payload = $acc.Substring(0, $len * 2) }
        }
        if ($payload) { $out[$hdr] = $payload }
    }
    $out
}
function Get-EcuPayload([string]$resp, [string]$expectPrefix) {
    # First module whose payload starts with $expectPrefix (most callers only want one answer).
    foreach ($kv in (Get-EcuBuckets $resp).GetEnumerator()) { if ($kv.Value.StartsWith($expectPrefix.ToUpper())) { return $kv.Value } }
    $null
}
function Get-AllEcuPayloads([string]$resp, [string]$expectPrefix) {
    # Every module whose payload starts with $expectPrefix, as an ordered header -> payload map.
    # GM cars commonly have 2-3+ modules answer the same generic request (engine plus others);
    # this is what lets a scan show codes from all of them instead of just whichever answers first.
    $out = [ordered]@{}
    foreach ($kv in (Get-EcuBuckets $resp).GetEnumerator()) { if ($kv.Value.StartsWith($expectPrefix.ToUpper())) { $out[$kv.Key] = $kv.Value } }
    $out
}

function Get-Bytes([string]$resp, [string]$expectPrefix) {
    # returns data bytes after the expected response header (e.g. "410C"), or $null
    $payload = Get-EcuPayload $resp $expectPrefix
    if (-not $payload) { return $null }
    $d = $payload.Substring($expectPrefix.Length)
    if ($d.Length -lt 2) { return $null }
    ,@(for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { [Convert]::ToInt32($d.Substring($k, 2), 16) })
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
            foreach ($c in 'ATE0','ATL0','ATS0','ATH1','ATCAF1','ATSP0') { [void](Send-Obd $sp $c) }
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
    @{ P='0142'; N='Control module V'; U='V';    F={ param($a) [math]::Round((256*$a[0]+$a[1])/1000,2) } },
    @{ P='010A'; N='Fuel pressure';    U='kPa';  F={ param($a) $a[0]*3 } },
    @{ P='011F'; N='Run time since start'; U='s'; F={ param($a) (256*$a[0]+$a[1]) } },
    @{ P='0121'; N='Distance w/ MIL on'; U='km'; F={ param($a) (256*$a[0]+$a[1]) } },
    @{ P='0131'; N='Distance since codes cleared'; U='km'; F={ param($a) (256*$a[0]+$a[1]) } },
    @{ P='012E'; N='Commanded EVAP purge'; U='%'; F={ param($a) [math]::Round($a[0]*100/255,1) } },
    @{ P='0143'; N='Absolute load';    U='%';    F={ param($a) [math]::Round((256*$a[0]+$a[1])*100/255,1) } },
    @{ P='0145'; N='Relative throttle'; U='%';   F={ param($a) [math]::Round($a[0]*100/255,1) } },
    @{ P='0146'; N='Ambient air temp'; U='C';    F={ param($a) $a[0]-40 } },
    @{ P='014C'; N='Cmd throttle actuator'; U='%'; F={ param($a) [math]::Round($a[0]*100/255,1) } },
    @{ P='015C'; N='Engine oil temp';  U='C';    F={ param($a) $a[0]-40 } }
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

# ---------- Mode 06: on-board monitor test results (raw, per SAE J1979 CAN format) ----------
# This is a standard read-only PID request, same family as Mode 01/09. No security access of any kind.
function Get-SupportedMids($sp) {
    $b = Get-Bytes (Send-Obd $sp '0600' 3000) '4600'
    if (-not $b) { return @() }
    $mids = @()
    for ($i = 0; $i -lt $b.Count; $i++) { for ($bit = 7; $bit -ge 0; $bit--) { if ($b[$i] -band (1 -shl $bit)) { $mids += ($i*8 + (8 - $bit)) } } }
    $mids
}
function Get-Mode06Raw($sp, [int]$mid) {
    # Raw hex payload for one MID (after the "46xx" echo). NOTE: deliberately not split into
    # TID/UAS/value/min/max - per ISO 15031-5 each record's length varies with the UAS byte
    # (some carry no limit, some one, some both), and a fixed-width guess would silently
    # misalign and corrupt every record after the first one that doesn't match. Showing the
    # verified raw bytes is more honest than a guessed decode.
    Get-EcuPayload (Send-Obd $sp ("06{0:X2}" -f $mid) 4000) ("46{0:X2}" -f $mid)
}
function Show-Mode06($sp) {
    Write-Host "On-board monitor test results (Mode 06) - raw payload per MID, read-only."
    Write-Host "Record fields (TID/UAS/value/limits) are NOT decoded here - see the note in"
    Write-Host "Get-Mode06Raw for why. Cross-reference against ISO 15031-5 Appendix B if you"
    Write-Host "need the decoded fields.`n"
    $mids = Get-SupportedMids $sp
    if (-not $mids) { Write-Host "No Mode 06 data reported as supported by this vehicle."; return }
    foreach ($mid in $mids) {
        $p = Get-Mode06Raw $sp $mid
        if ($p) { Write-Host ("MID 0x{0:X2}  raw: {1}" -f $mid, $p.Substring(4)) }
    }
}

# ---------- vehicle profile: free public VIN decode (NHTSA vPIC API, no key needed) ----------
function Get-VinInfo([string]$vin) {
    try {
        $resp = Invoke-RestMethod -Uri "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/$vin`?format=json" -TimeoutSec 8
        $row = $resp.Results[0]
        [pscustomobject]@{ Year = $row.ModelYear; Make = $row.Make; Model = $row.Model; Engine = "$($row.EngineCylinders)cyl $($row.DisplacementL)L $($row.FuelTypePrimary)".Trim(); Error = $row.ErrorText }
    } catch { $null }
}

# ---------- NHTSA recalls (free public API, no vehicle communication - just make/model/year) ----------
function Show-Recalls([string]$make, [string]$model, [string]$year) {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.nhtsa.gov/recalls/recallsByVehicle?make=$make&model=$model&modelYear=$year" -TimeoutSec 8
        $items = $resp.results
        if (-not $items -or $items.Count -eq 0) { Write-Host "Recalls: none on file for $year $make $model."; return }
        Write-Host "Recalls: $($items.Count) on file for $year $make $model -"
        foreach ($i in $items) { Write-Host ("  [$($i.NHTSACampaignNumber)] $($i.Component): $($i.Summary)") }
    } catch { Write-Host "Recalls lookup failed (no internet, or NHTSA API unreachable)." }
}

# ---------- Mode 09 extras: Calibration ID, CVN, ECU name (same read-only family as VIN) ----------
# Shown per-module (like Show-Codes) rather than just the first answer - on a car with several
# modules on the bus, each one has its own calibration/CVN/name, and the name often reveals
# what that module actually is (e.g. a fuel pump controller), which is useful info on its own.
function Show-Mode09Extra($sp) {
    foreach ($x in @(@('04','Calibration ID'), @('0A','ECU name'))) {
        $any = $false
        foreach ($kv in (Get-AllEcuPayloads (Send-Obd $sp "09$($x[0])" 6000) "49$($x[0])").GetEnumerator()) {
            $d = $kv.Value.Substring(6)
            $chars = for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { $n = [Convert]::ToInt32($d.Substring($k,2),16); if ($n -ge 32 -and $n -le 126) { [char]$n } }
            $txt = (-join $chars).Trim()
            $any = $true
            Write-Host "$($x[1]) [module 0x$($kv.Key)]: $(if ($txt) { $txt } else { '(not printable - raw: ' + $d + ')' })"
        }
        if (-not $any) { Write-Host "$($x[1]): not supported by any responding module" }
    }
    $any = $false
    foreach ($kv in (Get-AllEcuPayloads (Send-Obd $sp '0906' 6000) '4906').GetEnumerator()) {
        $any = $true
        Write-Host "CVN [module 0x$($kv.Key)]: 0x$($kv.Value.Substring(6,8)) - matches GM's published value only if that module is still running its original stock calibration"
    }
    if (-not $any) { Write-Host "CVN: not supported by any responding module" }
}

# ---------- GM Mode 22 per-cylinder misfire counts ----------
# PIDs below are community-sourced (GM Nation / Torque app PID lists), NOT independently
# verified against GM's own documentation, and at least one forum thread flags cylinders 1/2
# as possibly swapped on some platforms. We read them from the real car and show the raw
# result - you decide whether the numbers look plausible (near zero, rising only when you
# know you have a misfire) rather than trusting the PID table blindly.
function Show-GmMisfire($sp) {
    Write-Host "GM enhanced (Mode 22) per-cylinder misfire counts - UNVERIFIED PID mapping, cross-check"
    Write-Host "against real driving behavior before trusting which number belongs to which cylinder.`n"
    $gotAny = $false
    for ($cyl = 1; $cyl -le 8; $cyl++) {
        $pidByte = '{0:X2}' -f (0x04 + $cyl)   # candidate pattern per forum source: 1205=cyl1, 1206=cyl2
        $req = "2212$pidByte"
        $raw = Send-Obd $sp $req 3000
        $payload = Get-EcuPayload $raw "6212$pidByte"
        if ($payload -and $payload.Length -gt 6) {
            $gotAny = $true
            $rem = $payload.Substring(6)
            $v = [Convert]::ToInt32($rem.Substring(0, [Math]::Min(4, $rem.Length)), 16)
            Write-Host ("Cylinder $cyl candidate (PID 22 12$pidByte): $v")
        } elseif ($raw -match '7F22(\w\w)') {
            $nrc = $Matches[1]
            $why = switch ($nrc) { '12' { 'sub-function (PID) not supported' } '31' { 'request out of range' } '11' { 'service not supported' } default { "NRC 0x$nrc" } }
            Write-Host ("Cylinder $cyl candidate (PID 22 12$pidByte): rejected by ECU - $why")
        }
    }
    if (-not $gotAny) {
        Write-Host "`nNo module on this car recognizes this candidate PID range (0x1205-0x120C)."
        Write-Host "This forum-sourced mapping does not apply to your ECM/calibration - rather than"
        Write-Host "report fabricated numbers, this feature is honestly reporting: not available this way."
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
    # Reads from EVERY module that answers (engine plus whatever else is at 7EA/7EB on your
    # car), not just the first - this is the "all modules" scan a dealer-grade tool does.
    $r = Send-Obd $sp $mode 6000
    $hdr = '{0:X2}' -f ([Convert]::ToInt32($mode,16) + 0x40)
    $any = $false
    foreach ($kv in (Get-AllEcuPayloads $r $hdr).GetEnumerator()) {
        $codes = @(); $d = $kv.Value.Substring(2)
        if ($d.Length % 4 -eq 2) { $d = $d.Substring(2) }   # skip count byte some ECUs prepend
        for ($k = 0; $k + 3 -lt $d.Length; $k += 4) {
            $hi = [Convert]::ToInt32($d.Substring($k,2),16); $lo = [Convert]::ToInt32($d.Substring($k+2,2),16)
            if ($hi -ne 0 -or $lo -ne 0) { $codes += ConvertTo-Dtc $hi $lo }
        }
        if ($codes) { $any = $true; Write-Host ("${label} [module 0x$($kv.Key)]: $($codes -join ', ')") }
    }
    if (-not $any) { Write-Host "${label}: none (from any responding module)" }
}

function Show-Info($sp) {
    Write-Host "Protocol: $(Send-Obd $sp 'ATDPN')"
    Write-Host "Adapter voltage: $(Send-Obd $sp 'ATRV')"
    $payload = Get-EcuPayload (Send-Obd $sp '0902' 6000) '4902'
    # payload = "4902" + 1-byte item count + 17 ASCII bytes (VIN) = 20 bytes = 40 hex chars
    if ($payload -and $payload.Length -ge 40) {
        $d = $payload.Substring(6)
        $chars = for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { $n = [Convert]::ToInt32($d.Substring($k,2),16); if ($n -ge 32 -and $n -le 126) { [char]$n } else { '?' } }
        $vin17 = (-join $chars).Substring(0, 17)
        Write-Host "VIN: $vin17"
        $info = Get-VinInfo $vin17
        if ($info -and ($info.Make -or $info.Error -match '^0\b')) {
            Write-Host "Vehicle: $($info.Year) $($info.Make) $($info.Model) - $($info.Engine)"
            Show-Recalls $info.Make $info.Model $info.Year
        }
        elseif ($info) { Write-Host "Vehicle profile lookup: $($info.Error)" }
        else { Write-Host "Vehicle profile lookup failed (no internet, or NHTSA API unreachable)." }
    } else { Write-Host "VIN: unavailable" }
    Show-Codes $sp '03' 'Stored codes'
    Show-Codes $sp '0A' 'Permanent codes'
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
        'Mode06'     { Show-Mode06 $sp }
        'Mode09'     { Show-Mode09Extra $sp }
        'GmMisfire'  { Show-GmMisfire $sp }
        'Recalls'    {
            $payload = Get-EcuPayload (Send-Obd $sp '0902' 6000) '4902'
            if ($payload -and $payload.Length -ge 40) {
                $d = $payload.Substring(6)
                $chars = for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { $n = [Convert]::ToInt32($d.Substring($k,2),16); if ($n -ge 32 -and $n -le 126) { [char]$n } else { '?' } }
                $vin17 = (-join $chars).Substring(0, 17)
                $info = Get-VinInfo $vin17
                if ($info -and ($info.Make -or $info.Error -match '^0\b')) { Show-Recalls $info.Make $info.Model $info.Year }
                else { Write-Host "Couldn't decode a vehicle profile for this VIN; can't look up recalls." }
            } else { Write-Host "VIN unavailable; can't look up recalls." }
        }
        'Log'        { Start-Log $sp }
        'Perf'       { Start-Perf $sp }
        'ClearCodes' {
            if ((Read-Host "Clear codes and reset check-engine light? (y/N)") -eq 'y') { Send-Obd $sp '04' 4000; Write-Host 'Cleared.' }
        }
        'Menu' {
            while ($true) {
                Write-Host "`nDIAGNOSE: 2) Codes (all modules)  3) Info/VIN/recalls  4) Clear codes  5) Fuel trims  6) Freeze frame"
                Write-Host "          7) Readiness  10) Mode 06 raw  11) Mode 09 extra (cal ID/CVN)  12) GM misfire (unverified)"
                Write-Host "LOG/TUNE: 1) Live data  8) Datalog to CSV  9) 0-60 / 1/4 mile / hp estimate   Q) Quit"
                switch ((Read-Host '>').ToUpper()) {
                    '5' { Show-Trims $sp }
                    '6' { Show-Freeze $sp }
                    '7' { Show-Monitors $sp }
                    '8' { Start-Log $sp }
                    '9' { Start-Perf $sp }
                    '10' { Show-Mode06 $sp }
                    '11' { Show-Mode09Extra $sp }
                    '12' { Show-GmMisfire $sp }
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
