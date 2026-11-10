<#
  READ-ONLY ECU probe over an ELM327 serial port.
  Sends only: standard OBD identification (Mode 09), UDS ReadDataByIdentifier (22),
  DiagnosticSessionControl default/extended (10 01/03), SecurityAccess *seed request only* (27 01),
  and one ReadMemoryByAddress (23) to see how the ECU answers. It NEVER sends a security key,
  never writes, never starts a programming session.
#>
param([Parameter(Mandatory)][string]$Port, [string]$Out = "$PSScriptRoot\probe-result.txt")

$Allowed = '^(09(00|02|04|06)|22F1[0-9A-F]{2}|1001|1003|2701|23[0-9A-F]+|3E00)$'
$sp = New-Object System.IO.Ports.SerialPort $Port, 38400, 'None', 8, 'One'
$sp.ReadTimeout = 3000; $sp.WriteTimeout = 3000; $sp.Open()
$log = New-Object System.Collections.Generic.List[string]
function Say($s) { Write-Host $s; $log.Add($s) }

function Cmd([string]$c, [int]$to = 4000) {
    $sp.DiscardInBuffer(); $sp.Write("$c`r"); $buf = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $to) {
        if ($sp.BytesToRead -gt 0) { $buf += $sp.ReadExisting(); if ($buf.Contains('>')) { break } } else { Start-Sleep -Milliseconds 10 }
    }
    ($buf -replace '>', '').Trim()
}
function Req([string]$hex) {
    if ($hex -notmatch $Allowed) { throw "blocked by read-only allowlist: $hex" }
    $r = Cmd $hex 6000
    $flat = (($r -split "[\r\n]+" | ForEach-Object { ($_ -replace '\s', '') -replace '^[0-9]:', '' }) -join '')
    Say ("  > {0,-12} {1}" -f $hex, $(if ($flat) { $flat } else { '(no data)' }))
    $flat
}
function Describe-Nrc($flat) {
    if ($flat -match '^7F([0-9A-F]{2})([0-9A-F]{2})') {
        $n = @{ '11'='service not supported'; '12'='sub-function not supported'; '13'='bad message length'; '22'='conditions not correct'; '31'='request out of range';
                '33'='security access denied'; '35'='invalid key'; '36'='attempts exceeded'; '37'='time delay required'; '7E'='sub-function not supported in session'; '7F'='service not supported in session' }
        return "negative response: " + $(if ($n.ContainsKey($Matches[2])) { $n[$Matches[2]] } else { "NRC 0x$($Matches[2])" })
    }
    $null
}
function Ascii([string]$hex) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i + 1 -lt $hex.Length; $i += 2) {
        $b = [Convert]::ToInt32($hex.Substring($i, 2), 16)
        if ($b -ge 32 -and $b -le 126) { [void]$sb.Append([char]$b) } else { [void]$sb.Append('.') }
    }
    $sb.ToString()
}

try {
    Say "== ELM327 init"
    foreach ($c in 'ATZ','ATE0','ATL0','ATS0','ATH0','ATSP6','ATSH7E0','ATCRA7E8') { $r = Cmd $c 3000; if ($c -eq 'ATZ') { Say "  adapter: $($r -replace '[\r\n]+',' ')" } }
    Say "  battery: $(Cmd 'ATRV' 1500)"

    Say "`n== Standard OBD identification (Mode 09)"
    $v = Req '0902'; if ($v -match '4902') { Say "  VIN text: $(Ascii ($v.Substring($v.IndexOf('4902') + 6)))" }
    $c = Req '0904'; if ($c -match '4904') { Say "  Calibration ID text: $(Ascii ($c.Substring($c.IndexOf('4904') + 6)))" }
    [void](Req '0906')

    Say "`n== UDS identification (ReadDataByIdentifier)"
    foreach ($d in 'F187','F18A','F18B','F18C','F190','F191','F192','F193','F194','F195','F197','F199','F19D','F1A0') {
        $r = Req "22$d"
        if ($r -match "^62$d") { Say "      ascii: $(Ascii $r.Substring(6))" } elseif ($n = Describe-Nrc $r) { Say "      $n" }
    }

    Say "`n== Session + security (seed request only, NO key is ever sent)"
    $r = Req '1003'; $n = Describe-Nrc $r; if ($n) { Say "      $n" }
    $r = Req '2701'
    if ($r -match '^6701(.+)$') { Say "      seed received: $($Matches[1]) ($($Matches[1].Length / 2) bytes) - security access is required before memory can be read" }
    elseif ($n = Describe-Nrc $r) { Say "      $n" }

    Say "`n== Memory read attempt (expected to be refused while locked)"
    $r = Req '2324000000000010'
    if ($r -match '^63') { Say "      ECU returned memory WITHOUT unlocking" } elseif ($n = Describe-Nrc $r) { Say "      $n" }

    [void](Req '1001')
} finally {
    $sp.Close()
    $log | Set-Content $Out -Encoding utf8
    Write-Host "`nSaved $Out"
}
