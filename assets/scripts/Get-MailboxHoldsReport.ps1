<#
================================================================================
 Get-MailboxHoldsReport.ps1
 Tenant-wide Exchange Online mailbox HOLD audit — who is on what kind of hold.
--------------------------------------------------------------------------------
 Enumerates every mailbox (including inactive) and reports each hold type that
 keeps data from being purged:
   - LitigationHoldEnabled        (classic litigation hold)
   - InPlaceHolds                 (Purview / eDiscovery / retention-policy GUIDs)
   - RetentionHoldEnabled         (retention hold)
   - ComplianceTagHoldApplied     (retention-label hold)
   - DelayHoldApplied / DelayReleaseHoldApplied (residual backend holds)

 Read-only. Requires the ExchangeOnlineManagement module:
     Install-Module ExchangeOnlineManagement -Scope CurrentUser
 Connect as a reader:  Connect-ExchangeOnline -UserPrincipalName <you@contoso.com>

 JUST RUN IT:  .\Get-MailboxHoldsReport.ps1
   Prompts for an output folder; writes a date-stamped CSV.
   -HoldsOnly           only rows that carry at least one hold (default)
   -IncludeAll          every mailbox, held or not
   -OutputDir <path>    skip the prompt
================================================================================
#>
[CmdletBinding()]
param([switch]$IncludeAll,[string]$OutputDir)

$ErrorActionPreference='Stop'
function Say($m,$c='Gray'){Write-Host $m -ForegroundColor $c}

# --- verify a live EXO session (read-only) --------------------------------
try { $ci = Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' } }
catch { $ci = $null }
if (-not $ci) {
    Say "Not connected to Exchange Online." 'Yellow'
    Say "Run:  Connect-ExchangeOnline -UserPrincipalName <you@contoso.com>  then re-run." 'Yellow'
    return
}
Say "Connected as $($ci.UserPrincipalName)" 'Green'

if (-not $PSBoundParameters.ContainsKey('OutputDir')) {
    $def = Join-Path ([Environment]::GetFolderPath('Desktop')) 'MailboxHolds'
    $ans = Read-Host "Output folder [$def]"
    $OutputDir = if ([string]::IsNullOrWhiteSpace($ans)) { $def } else { $ans.Trim() }
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Say "Enumerating mailboxes (including inactive)..." 'Cyan'
$rows = New-Object System.Collections.Generic.List[object]
$all  = Get-Mailbox -IncludeInactiveMailbox -ResultSize Unlimited
$i=0
foreach ($mb in $all) {
    $i++; Write-Progress -Activity "Scanning holds" -Status "$($mb.PrimarySmtpAddress) ($i/$($all.Count))" -PercentComplete (($i/$all.Count)*100)
    $inplace = @($mb.InPlaceHolds | Where-Object { $_ })
    $held = $mb.LitigationHoldEnabled -or $mb.RetentionHoldEnabled -or $mb.ComplianceTagHoldApplied -or ($inplace.Count -gt 0) -or $mb.DelayHoldApplied -or $mb.DelayReleaseHoldApplied
    if (-not $IncludeAll -and -not $held) { continue }
    $rows.Add([pscustomobject]@{
        DisplayName            = $mb.DisplayName
        UserPrincipalName      = $mb.UserPrincipalName
        RecipientTypeDetails   = $mb.RecipientTypeDetails
        IsInactive             = [bool]$mb.IsInactiveMailbox
        LitigationHoldEnabled  = $mb.LitigationHoldEnabled
        LitigationHoldDate     = $mb.LitigationHoldDate
        RetentionHoldEnabled   = $mb.RetentionHoldEnabled
        ComplianceTagHold      = $mb.ComplianceTagHoldApplied
        DelayHoldApplied       = $mb.DelayHoldApplied
        DelayReleaseHoldApplied= $mb.DelayReleaseHoldApplied
        InPlaceHoldCount        = $inplace.Count
        InPlaceHolds            = ($inplace -join '; ')
        RetentionPolicy         = $mb.RetentionPolicy
        ExchangeGuid            = $mb.ExchangeGuid
    })
}
Write-Progress -Activity "Scanning holds" -Completed

$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$out   = Join-Path $OutputDir "MailboxHolds_$stamp.csv"
$rows | Sort-Object -Property @{e={$_.LitigationHoldEnabled}} -Descending, DisplayName | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8

Say ""
Say "==================== SUMMARY ====================" 'Cyan'
Say ("Mailboxes scanned     : {0}" -f $all.Count)
Say ("On litigation hold    : {0}" -f (@($rows | Where-Object {$_.LitigationHoldEnabled}).Count)) 'Yellow'
Say ("With InPlace/Purview  : {0}" -f (@($rows | Where-Object {$_.InPlaceHoldCount -gt 0}).Count)) 'Yellow'
Say ("Retention hold        : {0}" -f (@($rows | Where-Object {$_.RetentionHoldEnabled}).Count))
Say ("Residual delay holds  : {0}" -f (@($rows | Where-Object {$_.DelayHoldApplied -or $_.DelayReleaseHoldApplied}).Count))
Say ("Rows written          : {0}" -f $rows.Count)
Say ("CSV                   : {0}" -f $out) 'Green'
