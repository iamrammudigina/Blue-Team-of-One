#Requires -Version 5.1
<#
.SYNOPSIS
    Captures DNS + registry evidence for a mail-routing issue and exports it (TXT report, CSV, RDAP JSON).

.DESCRIPTION
    Use when mail to a domain stops arriving and you need to prove whether DNS is the cause
    (missing MX / SPF, zone reset, nameserver move) before handing it to whoever owns the DNS.
    For each domain it queries MX, TXT (SPF), A, NS, SOA, _dmarc, DKIM selector1/2 and autodiscover
    against:
      - the domain's authoritative nameserver
      - public resolvers (8.8.8.8, 1.1.1.1)
    It also pulls registry RDAP data (registered / last changed dates, delegated nameservers, registrar),
    which is what shows a nameserver move.

    Put the problem domain first and add one or two working domains of the same organisation
    as controls, so the report shows the difference side by side.

    Read-only. No admin rights or modules needed (Resolve-DnsName + public RDAP).

.EXAMPLE
    .\Get-DnsMailEvidence.ps1
    # Prompts for domains and an optional ticket number.

.EXAMPLE
    .\Get-DnsMailEvidence.ps1 -Domains problem.com,working.com -Ticket INC0000000 -OutRoot C:\Temp
#>
[CmdletBinding()]
param(
    [string[]]$Domains,
    [string]  $OutRoot = [Environment]::GetFolderPath('Desktop'),
    [string]  $Ticket
)

if (-not $Domains) {
    $in = Read-Host 'Domains to check, comma-separated (problem domain first, then working domain(s) for comparison)'
    $Domains = @($in -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() })
}
if (-not $Domains) { Write-Host 'No domains entered. Exiting.' -ForegroundColor Yellow; return }
if (-not $PSBoundParameters.ContainsKey('Ticket')) {
    $Ticket = Read-Host 'Ticket number for the report header (Enter to skip)'
}
$label = if ($Ticket) { $Ticket.Trim() } else { 'DNS' }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$stamp  = Get-Date -Format 'yyyyMMdd_HHmm'
$outDir = Join-Path $OutRoot "${label}_DNS_Evidence_$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$reportPath = Join-Path $outDir '01_DNS_Evidence_Report.txt'
$csvPath    = Join-Path $outDir '02_DNS_Evidence.csv'
$rdapPath   = Join-Path $outDir '03_Registry_RDAP.txt'

$publicResolvers = @('8.8.8.8', '1.1.1.1')
$results = New-Object System.Collections.Generic.List[object]
$authMap = @{}

$checks = @(
    @{ Name = '{0}';                      Type = 'MX'    },
    @{ Name = '{0}';                      Type = 'TXT'   },
    @{ Name = '{0}';                      Type = 'A'     },
    @{ Name = '{0}';                      Type = 'NS'    },
    @{ Name = '{0}';                      Type = 'SOA'   },
    @{ Name = '_dmarc.{0}';               Type = 'TXT'   },
    @{ Name = 'selector1._domainkey.{0}'; Type = 'CNAME' },
    @{ Name = 'selector2._domainkey.{0}'; Type = 'CNAME' },
    @{ Name = 'autodiscover.{0}';         Type = 'CNAME' }
)

function Format-DnsValue {
    param($Record)
    switch ([string]$Record.Type) {
        'MX'    { return "$($Record.Preference) $($Record.NameExchange)" }
        'TXT'   { return ($Record.Strings -join '') }
        'A'     { return $Record.IPAddress }
        'AAAA'  { return $Record.IPAddress }
        'NS'    { return $Record.NameHost }
        'CNAME' { return $Record.NameHost }
        'SOA'   { return "Primary=$($Record.PrimaryServer); Admin=$($Record.NameAdministrator); Serial=$($Record.SerialNumber)" }
        default { return [string]$Record }
    }
}

function Add-Result {
    param($Domain, $Name, $Type, $Server, $Status, $Value, $Ttl, $Section)
    $results.Add([pscustomobject]@{
        Domain      = $Domain
        QueryName   = $Name
        Type        = $Type
        Server      = $Server
        Status      = $Status
        Section     = $Section
        Value       = $Value
        TTL         = $Ttl
        CapturedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    })
}

function Invoke-DnsCheck {
    param($Domain, $Name, $Type, $Server, [switch]$IncludeAuthority)
    try {
        $res = @(Resolve-DnsName -Name $Name -Type $Type -Server $Server -DnsOnly -NoHostsFile -ErrorAction Stop)
        # Include CNAME answers so delegated records (e.g. _dmarc -> EasyDMARC) are not reported as missing
        $answers = @($res | Where-Object { $_.Section -eq 'Answer' -and ([string]$_.Type -eq $Type -or [string]$_.Type -eq 'CNAME') })
        if ($IncludeAuthority) {
            $answers += @($res | Where-Object { $_.Section -eq 'Authority' -and [string]$_.Type -eq $Type })
        }
        if ($answers.Count -gt 0) {
            foreach ($a in $answers) {
                Add-Result $Domain $Name $Type $Server 'FOUND' (Format-DnsValue $a) $a.TTL ([string]$a.Section)
            }
        }
        else {
            $soa  = $res | Where-Object { [string]$_.Type -eq 'SOA' } | Select-Object -First 1
            $note = if ($soa) { "No $Type record (NODATA). Zone SOA serial $($soa.SerialNumber)" } else { "No $Type record returned" }
            Add-Result $Domain $Name $Type $Server 'NO RECORD' $note '' ''
        }
    }
    catch {
        $msg    = $_.Exception.Message
        $status = if ($_.FullyQualifiedErrorId -match 'RCODE_NAME_ERROR' -or $msg -match 'does not exist') { 'NXDOMAIN' } else { 'ERROR' }
        Add-Result $Domain $Name $Type $Server $status $msg '' ''
    }
}

function Get-AuthoritativeServer {
    param($Domain)
    try {
        Resolve-DnsName -Name $Domain -Type NS -Server $publicResolvers[0] -DnsOnly -ErrorAction Stop |
            Where-Object { [string]$_.Type -eq 'NS' } |
            Select-Object -ExpandProperty NameHost -First 1
    }
    catch { $null }
}

# ---------------- DNS queries ----------------
foreach ($d in $Domains) {
    Write-Host "Checking $d ..." -ForegroundColor Cyan

    $auth = Get-AuthoritativeServer $d
    $authMap[$d] = if ($auth) { $auth } else { $publicResolvers[0] }

    $servers = @()
    if ($auth) { $servers += $auth }
    $servers += $publicResolvers

    foreach ($c in $checks) {
        $name = $c.Name -f $d
        foreach ($s in $servers) {
            Invoke-DnsCheck -Domain $d -Name $name -Type $c.Type -Server $s
        }
    }
}
# Registry delegation (current nameservers + last-changed date) comes from RDAP below.

# ---------------- Registry (RDAP) ----------------
Write-Host "Pulling registry (RDAP) data ..." -ForegroundColor Cyan
$rdapLines = New-Object System.Collections.Generic.List[string]
foreach ($d in $Domains) {
    $rdapLines.Add("==== $d ====")
    try {
        $r = Invoke-RestMethod -Uri "https://rdap.org/domain/$d" -TimeoutSec 30
        ($r | ConvertTo-Json -Depth 15) | Out-File (Join-Path $outDir "04_RDAP_raw_$d.json") -Encoding utf8

        foreach ($e in $r.events) { $rdapLines.Add(("{0,-38} {1}" -f $e.eventAction, $e.eventDate)) }
        $rdapLines.Add("Nameservers: " + (($r.nameservers | ForEach-Object { $_.ldhName }) -join ', '))
        $rdapLines.Add("Status     : " + ($r.status -join ', '))

        try {
            $registrar = $r.entities | Where-Object { $_.roles -contains 'registrar' } | Select-Object -First 1
            if ($registrar) {
                $fn = $registrar.vcardArray[1] | Where-Object { $_[0] -eq 'fn' } | Select-Object -First 1
                if ($fn) { $rdapLines.Add("Registrar  : $($fn[3])") }
            }
        }
        catch { }
    }
    catch {
        $rdapLines.Add("RDAP lookup failed: $($_.Exception.Message)")
    }
    $rdapLines.Add('')
}
$rdapLines | Out-File $rdapPath -Encoding utf8

# ---------------- Exports ----------------
$results | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8

$sb = New-Object System.Text.StringBuilder
$title = "DNS evidence for mail delivery - $($Domains -join ', ')"
if ($Ticket) { $title = "$Ticket - $title" }
[void]$sb.AppendLine($title)
[void]$sb.AppendLine("Captured   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')  (UTC $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')))")
[void]$sb.AppendLine("Captured by: $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('SUMMARY (answers from each domain''s authoritative nameserver)')
[void]$sb.AppendLine('------------------------------------------------------------')
foreach ($d in $Domains) {
    $srv = $authMap[$d]
    $mx  = @($results | Where-Object { $_.Domain -eq $d -and $_.QueryName -eq $d -and $_.Type -eq 'MX'  -and $_.Server -eq $srv })
    $txt = @($results | Where-Object { $_.Domain -eq $d -and $_.QueryName -eq $d -and $_.Type -eq 'TXT' -and $_.Server -eq $srv })
    $soa = $results | Where-Object { $_.Domain -eq $d -and $_.QueryName -eq $d -and $_.Type -eq 'SOA' -and $_.Server -eq $srv -and $_.Status -eq 'FOUND' } | Select-Object -First 1
    $spf = @($txt | Where-Object { $_.Value -like 'v=spf1*' })

    $mxText = ($mx | ForEach-Object { if ($_.Status -eq 'FOUND') { $_.Value } else { "$($_.Status) - $($_.Value)" } }) -join ' | '

    [void]$sb.AppendLine("$d   (queried: $srv)")
    [void]$sb.AppendLine("   MX  : $mxText")
    [void]$sb.AppendLine("   SPF : " + $(if ($spf.Count) { ($spf.Value -join ' | ') } else { 'NOT FOUND' }))
    [void]$sb.AppendLine("   SOA : " + $(if ($soa) { $soa.Value } else { 'n/a' }))
    [void]$sb.AppendLine('')
}

[void]$sb.AppendLine('DETAIL (all queries)')
[void]$sb.AppendLine('--------------------')
[void]$sb.AppendLine(($results | Format-Table Domain, QueryName, Type, Server, Status, Value, TTL -AutoSize -Wrap | Out-String -Width 400))

[void]$sb.AppendLine('REGISTRY (RDAP) - registered / last changed dates and delegated nameservers')
[void]$sb.AppendLine('---------------------------------------------------------------------------')
[void]$sb.AppendLine(($rdapLines -join "`r`n"))

$sb.ToString() | Out-File $reportPath -Encoding utf8

Write-Host ""
Write-Host "Evidence saved to: $outDir" -ForegroundColor Green
Get-ChildItem $outDir | Select-Object Name, Length | Format-Table -AutoSize
Invoke-Item $outDir
