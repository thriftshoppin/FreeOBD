# Simple OBD2 scanner window for ELM327 adapters. Run: powershell -ExecutionPolicy Bypass -File obd2gui.ps1
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:sp = $null; $script:sup = @(); $script:i = 0; $script:vals = @{}
$script:logW = $null; $script:perf = $null
$LogDir = Join-Path $PSScriptRoot 'logs'

# ---------- core ----------
function Send-Obd([string]$cmd, [int]$to = 3000) {
    $sp = $script:sp
    $sp.DiscardInBuffer()
    # This cheap Bluetooth clone can still be flushing a previous response's trailing bytes
    # into the OS buffer a few ms after we saw its '>' prompt and moved on. If we write the
    # next command right then, those stragglers land mixed in with the new reply and corrupt
    # the frame reassembly. A short settle + second drain clears them out first.
    Start-Sleep -Milliseconds 20
    if ($sp.BytesToRead -gt 0) { try { [void]$sp.ReadExisting() } catch {}; $sp.DiscardInBuffer() }
    $sp.Write("$cmd`r")
    $buf = ''; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $to) {
        if ($sp.BytesToRead -gt 0) { $buf += $sp.ReadExisting(); if ($buf.Contains('>')) { break } }
        else { Start-Sleep -Milliseconds 10 }
    }
    ($buf -replace '>', '').Trim()
}
function Get-EcuBuckets([string]$resp) {
    # CAN cars often have several modules answer the same request at once (normal, not an
    # error). With headers on (ATH1) every line is tagged with its 3-char source CAN ID, so we
    # bucket lines by that header and reassemble each bucket's own ISO-TP payload (single frame
    # or first+consecutive frames) independently. This is what stops one module's reply from
    # corrupting another's, and lets us show results per-module instead of just the first one.
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
    foreach ($kv in (Get-EcuBuckets $resp).GetEnumerator()) { if ($kv.Value.StartsWith($expectPrefix.ToUpper())) { return $kv.Value } }
    $null
}
function Get-AllEcuPayloads([string]$resp, [string]$expectPrefix) {
    $out = [ordered]@{}
    foreach ($kv in (Get-EcuBuckets $resp).GetEnumerator()) { if ($kv.Value.StartsWith($expectPrefix.ToUpper())) { $out[$kv.Key] = $kv.Value } }
    $out
}
function Get-Bytes([string]$resp, [string]$prefix) {
    $payload = Get-EcuPayload $resp $prefix
    if (-not $payload) { return $null }
    $d = $payload.Substring($prefix.Length)
    if ($d.Length -lt 2) { return $null }
    ,@(for ($n = 0; $n + 1 -lt $d.Length; $n += 2) { [Convert]::ToInt32($d.Substring($n, 2), 16) })
}
$Pids = @(
 @{P='0104';N='Engine load';U='%';F={param($a)[math]::Round($a[0]*100/255,1)}},
 @{P='0105';N='Coolant temp';U='C';F={param($a)$a[0]-40}},
 @{P='010C';N='RPM';U='rpm';F={param($a)[math]::Round((256*$a[0]+$a[1])/4)}},
 @{P='010D';N='Speed';U='km/h';F={param($a)$a[0]}},
 @{P='010F';N='Intake air temp';U='C';F={param($a)$a[0]-40}},
 @{P='0110';N='MAF';U='g/s';F={param($a)[math]::Round((256*$a[0]+$a[1])/100,2)}},
 @{P='0106';N='STFT bank 1';U='%';F={param($a)[math]::Round(($a[0]-128)*100/128,1)}},
 @{P='0107';N='LTFT bank 1';U='%';F={param($a)[math]::Round(($a[0]-128)*100/128,1)}},
 @{P='0108';N='STFT bank 2';U='%';F={param($a)[math]::Round(($a[0]-128)*100/128,1)}},
 @{P='0109';N='LTFT bank 2';U='%';F={param($a)[math]::Round(($a[0]-128)*100/128,1)}},
 @{P='010B';N='MAP';U='kPa';F={param($a)$a[0]}},
 @{P='010E';N='Timing advance';U='deg';F={param($a)[math]::Round($a[0]/2-64,1)}},
 @{P='0133';N='Baro';U='kPa';F={param($a)$a[0]}},
 @{P='0144';N='Commanded lambda';U='';F={param($a)[math]::Round((256*$a[0]+$a[1])/32768,3)}},
 @{P='0111';N='Throttle';U='%';F={param($a)[math]::Round($a[0]*100/255,1)}},
 @{P='012F';N='Fuel level';U='%';F={param($a)[math]::Round($a[0]*100/255,1)}},
 @{P='015E';N='Fuel rate';U='L/h';F={param($a)[math]::Round((256*$a[0]+$a[1])/20,2)}},
 @{P='0142';N='Module voltage';U='V';F={param($a)[math]::Round((256*$a[0]+$a[1])/1000,2)}},
 @{P='010A';N='Fuel pressure';U='kPa';F={param($a)$a[0]*3}},
 @{P='011F';N='Run time since start';U='s';F={param($a)256*$a[0]+$a[1]}},
 @{P='0121';N='Distance w/ MIL on';U='km';F={param($a)256*$a[0]+$a[1]}},
 @{P='0131';N='Distance since codes cleared';U='km';F={param($a)256*$a[0]+$a[1]}},
 @{P='012E';N='EVAP purge %';U='%';F={param($a)[math]::Round($a[0]*100/255,1)}},
 @{P='0143';N='Absolute load';U='%';F={param($a)[math]::Round((256*$a[0]+$a[1])*100/255,1)}},
 @{P='0145';N='Relative throttle';U='%';F={param($a)[math]::Round($a[0]*100/255,1)}},
 @{P='0146';N='Ambient air temp';U='C';F={param($a)$a[0]-40}},
 @{P='014C';N='Cmd throttle actuator';U='%';F={param($a)[math]::Round($a[0]*100/255,1)}},
 @{P='015C';N='Oil temp';U='C';F={param($a)$a[0]-40}}
)
function Read-Pid($d) { $b = Get-Bytes (Send-Obd $d.P 1500) ('41' + $d.P.Substring(2)); if ($null -eq $b) { $null } else { & $d.F $b } }

# Mode 06 on-board monitor test results: standard read-only PID family (same as Mode 01/09), no security access.
function Get-SupportedMids {
    $b = Get-Bytes (Send-Obd '0600' 3000) '4600'
    if (-not $b) { return @() }
    $mids = @()
    for ($i = 0; $i -lt $b.Count; $i++) { for ($bit = 7; $bit -ge 0; $bit--) { if ($b[$i] -band (1 -shl $bit)) { $mids += ($i*8 + (8 - $bit)) } } }
    $mids
}
function Get-Mode06Raw([int]$mid) {
    # Raw hex payload for one MID. Deliberately not split into TID/UAS/value/min/max: per
    # ISO 15031-5 each record's length depends on the UAS byte, and a fixed-width guess would
    # silently misalign and corrupt everything after the first record that doesn't match it.
    Get-EcuPayload (Send-Obd ("06{0:X2}" -f $mid) 4000) ("46{0:X2}" -f $mid)
}
# Vehicle profile: free public VIN decode, NHTSA vPIC API, no key needed.
function Get-Vin {
    $payload = Get-EcuPayload (Send-Obd '0902' 5000) '4902'
    # payload = "4902" + 1-byte item count + 17 ASCII bytes (VIN) = 20 bytes = 40 hex chars
    if (-not $payload -or $payload.Length -lt 40) { return $null }
    $d = $payload.Substring(6)
    $chars = for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { $n = [Convert]::ToInt32($d.Substring($k, 2), 16); if ($n -ge 32 -and $n -le 126) { [char]$n } else { '?' } }
    (-join $chars).Substring(0, 17)
}
function Get-VinInfo([string]$vin) {
    try {
        $resp = Invoke-RestMethod -Uri "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/$vin`?format=json" -TimeoutSec 8
        $row = $resp.Results[0]
        [pscustomobject]@{ Year = $row.ModelYear; Make = $row.Make; Model = $row.Model; Engine = "$($row.EngineCylinders)cyl $($row.DisplacementL)L $($row.FuelTypePrimary)".Trim(); Error = $row.ErrorText }
    } catch { $null }
}
function Get-Recalls([string]$make, [string]$model, [string]$year) {
    try {
        $resp = Invoke-RestMethod -Uri "https://api.nhtsa.gov/recalls/recallsByVehicle?make=$make&model=$model&modelYear=$year" -TimeoutSec 8
        ,@($resp.results)
    } catch { ,@() }
}
# Mode 09 extras (Calibration ID, ECU name, CVN) - same read-only family as VIN, shown per
# module since each module has its own, and the name often reveals what that module actually is.
function Get-Mode09Extra($sp) {
    $rows = [ordered]@{}
    foreach ($x in @(@('04','CalId'), @('0A','Name'))) {
        foreach ($kv in (Get-AllEcuPayloads (Send-Obd "09$($x[0])" 6000) "49$($x[0])").GetEnumerator()) {
            $d = $kv.Value.Substring(6)
            $chars = for ($k = 0; $k + 1 -lt $d.Length; $k += 2) { $n = [Convert]::ToInt32($d.Substring($k,2),16); if ($n -ge 32 -and $n -le 126) { [char]$n } }
            $txt = (-join $chars).Trim(); if (-not $txt) { $txt = "(raw: $d)" }
            if (-not $rows.Contains($kv.Key)) { $rows[$kv.Key] = @{ CalId = ''; Name = ''; Cvn = '' } }
            $rows[$kv.Key][$x[1]] = $txt
        }
    }
    foreach ($kv in (Get-AllEcuPayloads (Send-Obd '0906' 6000) '4906').GetEnumerator()) {
        if (-not $rows.Contains($kv.Key)) { $rows[$kv.Key] = @{ CalId = ''; Name = ''; Cvn = '' } }
        $rows[$kv.Key]['Cvn'] = "0x$($kv.Value.Substring(6,8))"
    }
    $rows
}
# GM enhanced Mode 22 per-cylinder misfire counts - community-sourced candidate PIDs (GM
# Nation / Torque app lists), NOT verified against GM's own documentation. Reports the ECU's
# actual response (value or rejection reason) rather than guessing numbers.
function Get-GmMisfire($sp) {
    $out = @()
    for ($cyl = 1; $cyl -le 8; $cyl++) {
        $pidByte = '{0:X2}' -f (0x04 + $cyl)
        $raw = Send-Obd "2212$pidByte" 3000
        $payload = Get-EcuPayload $raw "6212$pidByte"
        if ($payload -and $payload.Length -gt 6) {
            $rem = $payload.Substring(6)
            $v = [Convert]::ToInt32($rem.Substring(0, [Math]::Min(4, $rem.Length)), 16)
            $out += [pscustomobject]@{ Cyl = $cyl; Pid = "22 12$pidByte"; Result = "$v" }
        } elseif ($raw -match '7F22(\w\w)') {
            $nrc = $Matches[1]
            $why = switch ($nrc) { '12' { 'sub-function (PID) not supported' } '31' { 'request out of range' } '11' { 'service not supported' } default { "NRC 0x$nrc" } }
            $out += [pscustomobject]@{ Cyl = $cyl; Pid = "22 12$pidByte"; Result = "rejected - $why" }
        } else {
            $out += [pscustomobject]@{ Cyl = $cyl; Pid = "22 12$pidByte"; Result = '(no response)' }
        }
    }
    $out
}
function ConvertTo-Dtc([int]$hi, [int]$lo) { '{0}{1}{2:X}{3:X2}' -f ('P','C','B','U')[($hi -shr 6) -band 3], (($hi -shr 4) -band 3), ($hi -band 15), $lo }
function Describe-Dtc([string]$c) {
    $map = @{ P0171='System too lean, bank 1'; P0174='System too lean, bank 2'; P0172='System too rich, bank 1'; P0175='System too rich, bank 2';
              P2177='System too lean off idle, bank 1'; P2179='System too lean off idle, bank 2'; P2178='System too rich off idle, bank 1'; P2180='System too rich off idle, bank 2';
              P0300='Random/multiple cylinder misfire'; P0420='Catalyst efficiency below threshold, bank 1'; P0430='Catalyst efficiency below threshold, bank 2';
              P0101='MAF sensor range/performance'; P0128='Coolant thermostat below regulating temp' }
    if ($map.ContainsKey($c)) { return $map[$c] }
    if ($c -match '^P030([1-8])$') { return "Cylinder $($Matches[1]) misfire detected" }
    ''
}

# ---------- UI ----------
$f = New-Object Windows.Forms.Form
$f.Text = 'OBD2 Scanner'; $f.Size = '720,560'; $f.StartPosition = 'CenterScreen'; $f.Font = New-Object Drawing.Font('Segoe UI', 9)
$top = New-Object Windows.Forms.Panel; $top.Dock = 'Top'; $top.Height = 40
$lp = New-Object Windows.Forms.Label; $lp.Text = 'Port:'; $lp.Location = '10,12'; $lp.AutoSize = $true
$cb = New-Object Windows.Forms.ComboBox; $cb.Location = '48,8'; $cb.Width = 90; $cb.DropDownStyle = 'DropDownList'
$bc = New-Object Windows.Forms.Button; $bc.Text = 'Connect'; $bc.Location = '148,7'; $bc.Width = 90
$st = New-Object Windows.Forms.Label; $st.Text = 'Not connected'; $st.Location = '250,12'; $st.AutoSize = $true
$top.Controls.AddRange(@($lp, $cb, $bc, $st))
$tabs = New-Object Windows.Forms.TabControl; $tabs.Dock = 'Fill'
foreach ($n in 'Live','Fuel Trims','Codes','Log','Performance','Vehicle','Module Info','Misfire (GM)') { $t = New-Object Windows.Forms.TabPage; $t.Text = $n; [void]$tabs.TabPages.Add($t) }
$f.Controls.Add($tabs); $f.Controls.Add($top)
$tabs.BringToFront()

# Live
$lv = New-Object Windows.Forms.ListView; $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true
[void]$lv.Columns.Add('Parameter', 260); [void]$lv.Columns.Add('Value', 140); [void]$lv.Columns.Add('Unit', 80)
$tabs.TabPages[0].Controls.Add($lv)

# Trims
$bars = @{}; $y = 20
foreach ($n in 'STFT bank 1','LTFT bank 1','STFT bank 2','LTFT bank 2') {
    $l = New-Object Windows.Forms.Label; $l.Text = $n; $l.Location = "20,$y"; $l.AutoSize = $true
    $pnl = New-Object Windows.Forms.Panel; $pnl.Location = "130,$($y-2)"; $pnl.Size = '400,24'; $pnl.BorderStyle = 'FixedSingle'; $pnl.BackColor = 'White'
    $fill = New-Object Windows.Forms.Panel; $fill.Height = 22; $pnl.Controls.Add($fill)
    $mid = New-Object Windows.Forms.Panel; $mid.Size = '1,24'; $mid.Location = '200,0'; $mid.BackColor = 'Gray'; $pnl.Controls.Add($mid); $mid.BringToFront()
    $v = New-Object Windows.Forms.Label; $v.Location = "545,$y"; $v.AutoSize = $true; $v.Text = '--'
    $tabs.TabPages[1].Controls.AddRange(@($l, $pnl, $v)); $bars[$n] = @{ Fill = $fill; Val = $v }; $y += 40
}
$note = New-Object Windows.Forms.Label; $note.Location = '20,190'; $note.Size = '650,120'
$note.Text = "Scale: -30% to +30%. Near 0 is healthy.`r`nLong-term trim above about +10% means the ECU is adding fuel to fix a lean condition`r`n(vacuum leak, weak fuel delivery, dirty MAF, or ethanol fuel). At about +25% it is at its limit."
$tabs.TabPages[1].Controls.Add($note)

# Codes
$lc = New-Object Windows.Forms.ListView; $lc.View = 'Details'; $lc.Location = '10,45'; $lc.Size = '670,380'; $lc.FullRowSelect = $true; $lc.GridLines = $true
[void]$lc.Columns.Add('Code', 90); [void]$lc.Columns.Add('Type', 140); [void]$lc.Columns.Add('Description', 420)
$br = New-Object Windows.Forms.Button; $br.Text = 'Read codes'; $br.Location = '10,10'; $br.Width = 110
$bx = New-Object Windows.Forms.Button; $bx.Text = 'Clear codes'; $bx.Location = '130,10'; $bx.Width = 110
$tabs.TabPages[2].Controls.AddRange(@($br, $bx, $lc))

# Log
$bl = New-Object Windows.Forms.Button; $bl.Text = 'Start logging'; $bl.Location = '10,10'; $bl.Width = 120
$ll = New-Object Windows.Forms.Label; $ll.Location = '10,50'; $ll.Size = '670,60'; $ll.Text = "Saves a CSV to $LogDir. Open in Excel, or load into your tuning software."
$tabs.TabPages[3].Controls.AddRange(@($bl, $ll))

# Perf
$bp = New-Object Windows.Forms.Button; $bp.Text = 'Arm run'; $bp.Location = '10,10'; $bp.Width = 120
$pl = New-Object Windows.Forms.Label; $pl.Location = '10,50'; $pl.Size = '670,200'; $pl.Font = New-Object Drawing.Font('Consolas', 11)
$pl.Text = 'Press Arm run, come to a stop on a closed course, then launch. Q-mile and 0-60 times are estimates (Bluetooth is slow).'
$tabs.TabPages[4].Controls.AddRange(@($bp, $pl))

# Vehicle (VIN profile + recalls + Mode 06 monitor tests)
$bvin = New-Object Windows.Forms.Button; $bvin.Text = 'Identify vehicle (VIN)'; $bvin.Location = '10,10'; $bvin.Width = 170
$lvin = New-Object Windows.Forms.Label; $lvin.Location = '10,45'; $lvin.Size = '670,70'; $lvin.Text = 'Not identified yet.'
$bm6 = New-Object Windows.Forms.Button; $bm6.Text = 'Read monitor tests (Mode 06)'; $bm6.Location = '10,120'; $bm6.Width = 210
$lm6 = New-Object Windows.Forms.ListView; $lm6.View = 'Details'; $lm6.Location = '10,155'; $lm6.Size = '670,280'; $lm6.FullRowSelect = $true; $lm6.GridLines = $true
[void]$lm6.Columns.Add('MID', 55); [void]$lm6.Columns.Add('Raw payload (not decoded - see tooltip/README)', 600)
$tabs.TabPages[5].Controls.AddRange(@($bvin, $lvin, $bm6, $lm6))

# Module Info (Mode 09: Calibration ID, ECU name, CVN - per responding module)
$bmi = New-Object Windows.Forms.Button; $bmi.Text = 'Read module info (Mode 09)'; $bmi.Location = '10,10'; $bmi.Width = 200
$lmi = New-Object Windows.Forms.ListView; $lmi.View = 'Details'; $lmi.Location = '10,45'; $lmi.Size = '670,390'; $lmi.FullRowSelect = $true; $lmi.GridLines = $true
[void]$lmi.Columns.Add('Module', 70); [void]$lmi.Columns.Add('ECU name', 150); [void]$lmi.Columns.Add('Calibration ID', 220); [void]$lmi.Columns.Add('CVN', 100)
$tabs.TabPages[6].Controls.AddRange(@($bmi, $lmi))

# Misfire (GM) - unverified Mode 22 candidate PIDs, honest pass/reject reporting
$bmf = New-Object Windows.Forms.Button; $bmf.Text = 'Read misfire counters (GM)'; $bmf.Location = '10,10'; $bmf.Width = 200
$lmfNote = New-Object Windows.Forms.Label; $lmfNote.Location = '10,45'; $lmfNote.Size = '670,45'
$lmfNote.Text = "Community-sourced candidate PIDs, NOT verified against GM documentation. Shows the ECU's`r`nactual response (value or rejection reason) rather than guessed numbers."
$lmf = New-Object Windows.Forms.ListView; $lmf.View = 'Details'; $lmf.Location = '10,95'; $lmf.Size = '670,340'; $lmf.FullRowSelect = $true; $lmf.GridLines = $true
[void]$lmf.Columns.Add('Cylinder', 70); [void]$lmf.Columns.Add('PID', 90); [void]$lmf.Columns.Add('Result', 480)
$tabs.TabPages[7].Controls.AddRange(@($bmf, $lmfNote, $lmf))

# ---------- behavior ----------
function Set-Status([string]$m) { $st.Text = $m }
function Update-Bar($name, $val) {
    $b = $bars[$name]; if (-not $b) { return }
    $c = [math]::Max(-30, [math]::Min(30, $val)); $px = [int]([math]::Abs($c) / 30 * 200)
    $b.Fill.Width = [math]::Max(1, $px); $b.Fill.Left = $(if ($c -ge 0) { 200 } else { 200 - $px })
    $b.Fill.BackColor = $(if ([math]::Abs($val) -le 5) { 'SeaGreen' } elseif ([math]::Abs($val) -le 10) { 'Goldenrod' } else { 'Firebrick' })
    $b.Val.Text = "$val %"
}
$bc.Add_Click({
    if ($script:sp) { $timer.Stop(); $script:sp.Close(); $script:sp = $null; $bc.Text = 'Connect'; Set-Status 'Not connected'; return }
    if (-not $cb.SelectedItem) { Set-Status 'Pick a COM port (pair the adapter in Windows first).'; return }
    $f.Cursor = 'WaitCursor'; Set-Status 'Connecting...'; $f.Refresh()
    try {
        $s = New-Object System.IO.Ports.SerialPort $cb.SelectedItem, 38400, 'None', 8, 'One'; $s.ReadTimeout = 2000; $s.WriteTimeout = 2000; $s.Open(); $script:sp = $s
        $r = Send-Obd 'ATZ' 3000
        if ($r -notmatch 'ELM|OBD') { throw "No ELM327 response" }
        foreach ($c in 'ATE0','ATL0','ATS0','ATH1','ATCAF1','ATSP0') { [void](Send-Obd $c) }
        Set-Status 'Finding supported sensors (a few seconds)...'; $f.Refresh()
        $script:sup = @(); $lv.Items.Clear()
        foreach ($d in $Pids) { if ($null -ne (Read-Pid $d)) { $script:sup += $d; $it = $lv.Items.Add($d.N); [void]$it.SubItems.Add('--'); [void]$it.SubItems.Add($d.U) } }
        $bc.Text = 'Disconnect'; Set-Status "Connected on $($cb.SelectedItem) - $($script:sup.Count) sensors"; $script:i = 0; $timer.Start()
    } catch { Set-Status "Error: $($_.Exception.Message)"; if ($script:sp) { $script:sp.Close(); $script:sp = $null } }
    $f.Cursor = 'Default'
})
$br.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    $timer.Stop(); $lc.Items.Clear()
    foreach ($m in @(@('03','Stored'), @('07','Pending'), @('0A','Permanent'))) {
        $hdr = '{0:X2}' -f ([Convert]::ToInt32($m[0], 16) + 0x40)
        foreach ($kv in (Get-AllEcuPayloads (Send-Obd $m[0] 5000) $hdr).GetEnumerator()) {
            $d = $kv.Value.Substring(2); if ($d.Length % 4 -eq 2) { $d = $d.Substring(2) }
            for ($k = 0; $k + 3 -lt $d.Length; $k += 4) { $hi = [Convert]::ToInt32($d.Substring($k, 2), 16); $lo = [Convert]::ToInt32($d.Substring($k + 2, 2), 16)
                if ($hi -or $lo) { $c = ConvertTo-Dtc $hi $lo; $it = $lc.Items.Add($c); [void]$it.SubItems.Add("$($m[1]) [0x$($kv.Key)]"); [void]$it.SubItems.Add((Describe-Dtc $c)) } }
        }
    }
    if ($lc.Items.Count -eq 0) { [void]$lc.Items.Add('(none)') }
    $timer.Start()
})
$bx.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    $q = [Windows.Forms.MessageBox]::Show("Clear codes and reset the check-engine light?`nThis also erases freeze-frame data and resets emissions readiness monitors.", 'Clear codes', 'YesNo', 'Warning')
    if ($q -eq 'Yes') { $timer.Stop(); [void](Send-Obd '04' 4000); $lc.Items.Clear(); Set-Status 'Codes cleared.'; $timer.Start() }
})
$bl.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    if ($script:logW) { $script:logW.Close(); $script:logW = $null; $bl.Text = 'Start logging'; $ll.Text += "`r`nStopped."; return }
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    $file = Join-Path $LogDir ("obd_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
    $script:logW = New-Object IO.StreamWriter $file; $script:logT = [Diagnostics.Stopwatch]::StartNew()
    $script:logW.WriteLine((@('time_s') + ($script:sup | ForEach-Object { "$($_.N) [$($_.U)]" })) -join ',')
    $bl.Text = 'Stop logging'; $ll.Text = "Logging to $file"
})
$bp.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    $script:perf = @{ State = 'stop'; Dist = 0.0; Last = 0.0; LastV = 0.0; T60 = $null; TQ = $null; Top = 0.0; SW = $null }
    $pl.Text = 'Waiting for the car to be stationary...'
})

$bvin.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    $timer.Stop(); $lvin.Text = 'Reading VIN...'; $f.Refresh()
    $vin = Get-Vin
    if (-not $vin) { $lvin.Text = 'VIN not available from this vehicle.'; $timer.Start(); return }
    $lvin.Text = "VIN: $vin`r`nLooking up vehicle profile..."; $f.Refresh()
    $info = Get-VinInfo $vin
    if ($info -and ($info.Make -or $info.Error -match '^0\b')) {
        $lvin.Text = "VIN: $vin`r`n$($info.Year) $($info.Make) $($info.Model) - $($info.Engine)`r`nLooking up recalls..."
        $f.Refresh()
        $recalls = Get-Recalls $info.Make $info.Model $info.Year
        if ($recalls.Count -gt 0) {
            $names = ($recalls | ForEach-Object { $_.Component } | Select-Object -Unique) -join '; '
            $lvin.Text = "VIN: $vin`r`n$($info.Year) $($info.Make) $($info.Model) - $($info.Engine)`r`n$($recalls.Count) open NHTSA recall(s): $names"
        } else {
            $lvin.Text = "VIN: $vin`r`n$($info.Year) $($info.Make) $($info.Model) - $($info.Engine)`r`nNo open NHTSA recalls found."
        }
    }
    elseif ($info) { $lvin.Text = "VIN: $vin`r`nLookup: $($info.Error)" }
    else { $lvin.Text = "VIN: $vin`r`n(no internet, or NHTSA API unreachable)" }
    $timer.Start()
})
$bmi.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    $timer.Stop(); $lmi.Items.Clear(); Set-Status 'Reading module info (Mode 09)...'; $f.Refresh()
    foreach ($kv in (Get-Mode09Extra $script:sp).GetEnumerator()) {
        $it = $lmi.Items.Add("0x$($kv.Key)")
        [void]$it.SubItems.Add($(if ($kv.Value.Name) { $kv.Value.Name } else { '--' }))
        [void]$it.SubItems.Add($(if ($kv.Value.CalId) { $kv.Value.CalId } else { '--' }))
        [void]$it.SubItems.Add($(if ($kv.Value.Cvn) { $kv.Value.Cvn } else { '--' }))
    }
    if ($lmi.Items.Count -eq 0) { [void]$lmi.Items.Add('(no module responded)') }
    Set-Status 'Module info read.'; $timer.Start()
})
$bmf.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    $timer.Stop(); $lmf.Items.Clear(); Set-Status 'Reading GM misfire candidates...'; $f.Refresh()
    foreach ($row in (Get-GmMisfire $script:sp)) { $it = $lmf.Items.Add("$($row.Cyl)"); [void]$it.SubItems.Add($row.Pid); [void]$it.SubItems.Add($row.Result) }
    Set-Status 'Done.'; $timer.Start()
})
$bm6.Add_Click({
    if (-not $script:sp) { Set-Status 'Connect first.'; return }
    $timer.Stop(); $lm6.Items.Clear(); Set-Status 'Reading Mode 06 monitor tests...'; $f.Refresh()
    foreach ($mid in (Get-SupportedMids)) {
        $p = Get-Mode06Raw $mid
        if ($p) { $it = $lm6.Items.Add(('0x{0:X2}' -f $mid)); [void]$it.SubItems.Add($p.Substring(4)) }
    }
    if ($lm6.Items.Count -eq 0) { [void]$lm6.Items.Add('(no Mode 06 data reported by this vehicle)') }
    Set-Status 'Monitor tests read.'; $timer.Start()
})

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 20
$spdDef = $Pids | Where-Object { $_.P -eq '010D' }
$timer.Add_Tick({
    if (-not $script:sp -or $script:sup.Count -eq 0) { return }
    $timer.Stop()
    try {
        if ($script:perf -and $script:perf.State -ne 'done') {
            $p = $script:perf; $v = Read-Pid $spdDef
            if ($null -ne $v) {
                $mph = $v * 0.621371
                switch ($p.State) {
                    'stop'  { if ($v -eq 0) { $p.State = 'armed'; $pl.Text = 'ARMED - launch when ready.' } }
                    'armed' { if ($v -gt 0) { $p.State = 'run'; $p.SW = [Diagnostics.Stopwatch]::StartNew() } }
                    'run'   { $t = $p.SW.Elapsed.TotalSeconds
                              $p.Dist += (($mph + $p.LastV) / 2) * 0.44704 * ($t - $p.Last); $p.Last = $t; $p.LastV = $mph; if ($mph -gt $p.Top) { $p.Top = $mph }
                              if (-not $p.T60 -and $mph -ge 60) { $p.T60 = $t }
                              if (-not $p.TQ -and $p.Dist -ge 402.336) { $p.TQ = $t; $p.TQs = $mph; $p.State = 'done' }
                              if ($t -gt 40) { $p.State = 'done' }
                              $pl.Text = ("Speed {0,5:N0} mph`r`nTime  {1,5:N1} s`r`n0-60  {2}`r`n1/4 mi {3}" -f $mph, $t, $(if ($p.T60) { '{0:N2} s' -f $p.T60 } else { '...' }), $(if ($p.TQ) { '{0:N2} s @ {1:N0} mph' -f $p.TQ, $p.TQs } else { '...' })) }
                }
                if ($p.State -eq 'done') { $pl.Text += "`r`nDone. Top speed $([math]::Round($p.Top)) mph." }
            }
        } else {
            $d = $script:sup[$script:i]; $v = Read-Pid $d
            $lv.Items[$script:i].SubItems[1].Text = $(if ($null -eq $v) { '--' } else { "$v" })
            if ($null -ne $v) { $script:vals[$d.N] = $v; if ($bars.ContainsKey($d.N)) { Update-Bar $d.N $v } }
            $script:i++
            if ($script:i -ge $script:sup.Count) {
                $script:i = 0
                if ($script:logW) { $row = @([math]::Round($script:logT.Elapsed.TotalSeconds, 2)) + ($script:sup | ForEach-Object { $script:vals[$_.N] }); $script:logW.WriteLine($row -join ','); $script:logW.Flush() }
            }
        }
    } catch { Set-Status "Connection error: $($_.Exception.Message)" }
    if ($script:sp) { $timer.Start() }
})

$cb.Items.AddRange([string[]][System.IO.Ports.SerialPort]::GetPortNames()); if ($cb.Items.Count) { $cb.SelectedIndex = 0 }
$f.Add_FormClosing({ $timer.Stop(); if ($script:logW) { $script:logW.Close() }; if ($script:sp) { $script:sp.Close() } })
[void]$f.ShowDialog()
