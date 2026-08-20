<#
================================================================================
 Get-IntunePrivilegedAccess.ps1
 Privileged access to Microsoft Intune - point-in-time evidence generator
--------------------------------------------------------------------------------
 Scans Entra ID directory-role holders for the Intune-relevant roles
 (Intune Administrator, Global Administrator), and CORRECTLY distinguishes:
   - Assigned  : permanent / standing role assignment (the real exception)
   - Activated : a live PIM (JIT) activation of an ELIGIBLE role - time-bound,
                 with a linked eligible assignment as proof (NOT standing)
   - Eligible  : PIM-eligible, not currently active (baseline "no standing" state)
 Resolves role-assignable groups to members, flags partner (GDAP) grants, and
 writes a date-stamped, SHA-256'd HTML evidence file.

 Requires the Microsoft Graph PowerShell SDK:
     Install-Module Microsoft.Graph -Scope CurrentUser

 Read-only. Connect as a user who can read role management + directory + groups.

 ---------------------------------------------------------------------------
 SANITIZED TEMPLATE. Everything in the CONFIG block below is example data.
 Replace the tenant id, tier group names, justifications, partner rows and
 dispositions with your own before running. Do NOT assert controls (e.g.
 break-glass hardening) that you have not actually implemented.
 ---------------------------------------------------------------------------
#>

[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PrivilegedAccess-Evidence'),
    [string]$ExpectedTenantId = '<your-tenant-id-guid>'
)

Add-Type -AssemblyName System.Web

# =============================== CONFIG (edit) ================================

$RolesInScope = @('Intune Administrator', 'Global Administrator')

# Map your role-assignable tier group display names to a short tier label.
$TierMap = [ordered]@{
    'Contoso SOC - L3 Admin'    = 'L3'
    'Contoso SOC - L2 Operator' = 'L2'
    'Contoso SOC - L1 Read'     = 'L1'
}

# Groups whose displayName matches this are treated as cross-tenant partner
# (GDAP) grants; members live in the partner tenant and are NOT enumerable here.
$PartnerGroupPattern = '(?i)\bGDAP\b'

# Per-UPN business justification + review status. EDIT for your tenant.
$Justification = @{
    'admin@contoso.onmicrosoft.com' = 'EXAMPLE: legacy standing Global Administrator identified during this access review and flagged for disposition. Confirm ownership, active use, and whether GA is required versus a least-privilege alternative (e.g. Billing Administrator), break-glass hardening, or removal.'
    'operator1@contoso.com'         = 'EXAMPLE: managed-service administration. Eligible via L3 tier group; access is JIT, time-bound, no standing assignment.'
    'operator2@contoso.com'         = 'EXAMPLE: managed-service administration. Eligible via L2 tier group; access is JIT, time-bound, no standing assignment.'
}

# Accounts designated as break-glass / emergency access. Standing GA on these is
# BY DESIGN (not an exception) - PROVIDED the break-glass control set is in place:
# cloud-only on the onmicrosoft domain, excluded from Conditional Access, strong
# auth (FIDO2), password vaulted split-knowledge and rotated, sign-in alerting,
# GA-only (no operational group membership), excluded from lifecycle disable.
# Edit the justification down to only the controls that are ACTUALLY in place
# before submitting - do not assert controls you have not implemented.
$BreakGlassUpns = @('breakglass@contoso.onmicrosoft.com')
$BreakGlassJustification = 'EXAMPLE: designated break-glass / emergency-access account. Standing Global Administrator retained BY DESIGN so the tenant stays reachable if PIM, MFA, or Conditional Access fail. Cloud-only account on the tenant onmicrosoft domain. Controls: excluded from Conditional Access; strong authentication (FIDO2) with weak methods removed; password held split-knowledge in the vault and rotated; sign-in alerting enabled; GA-only (operational group memberships removed); excluded from lifecycle / inactivity disable. Included in the privileged access review.'

# Justification applied to partner (GDAP) rows (no per-user UPN to key on).
$PartnerJustification = 'EXAMPLE: managed security service provider administrative access for delivery of contracted endpoint / Intune management under the MSA. Where partner access is retained, it is least-privilege GDAP, scoped to the roles required and time-bound at the relationship level.'

# Partner (GDAP) relationships observed in M365 Admin Center >
# Settings > Partner relationships. EDIT for your tenant.
$PartnerRelationships = @(
    [pscustomobject]@{
        Name='<relationship-name>'; Partner='<partner org name + tenant id>'
        Type='GDAP'; Expires='<yyyy-mm-dd>'; AutoExtend='On / Off'
        Roles='<roles carried, incl. whether Intune Administrator>'; Status='Active / REMOVED'
        Decision='EXAMPLE: disposition and date. Confirm sign-in activity on the path before removal; note if redundant to in-tenant PIM accounts.'
    }
)

# Direct-assignment & remediation dispositions (audit trail rendered in the HTML).
$Dispositions = @(
    [pscustomobject]@{
        Item='<account or path>'
        Finding='EXAMPLE: what was found (standing role, dormancy, licensing, mailbox state, etc.).'
        Action='EXAMPLE: what was done (retained as break-glass, role removed, relationship terminated, hardening applied...).'
        Status='EXAMPLE: current status'
    }
)

# ============================================================================

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function HE($s) { [System.Web.HttpUtility]::HtmlEncode([string]$s) }

# --- Connect ---------------------------------------------------------------
$scopes = @('RoleManagement.Read.Directory','Directory.Read.All','GroupMember.Read.All','User.Read.All')
Say "Connecting to Microsoft Graph..." 'Cyan'
Connect-MgGraph -Scopes $scopes -NoWelcome
$ctx = Get-MgContext
$Collector = $ctx.Account
$TenantId  = $ctx.TenantId
if ($ExpectedTenantId -notmatch '^<' -and $TenantId -ne $ExpectedTenantId) {
    Write-Warning "Connected tenant $TenantId does NOT match expected $ExpectedTenantId."
}
Say "Connected as $Collector in tenant $TenantId" 'Green'

# --- Helpers ---------------------------------------------------------------
function Get-PrincipalInfo($principalObj, $principalId) {
    $ap = $principalObj.AdditionalProperties
    [pscustomobject]@{
        Id=$principalId; Type=($ap['@odata.type'] -replace '#microsoft.graph.','')
        Name=$ap['displayName']; Upn=$ap['userPrincipalName']
    }
}

$records = New-Object System.Collections.Generic.List[object]

function Add-Record {
    param($Role,$Name,$Upn,$Tier,$State,$AssignmentType,$ActiveUntil,$Proof,$ViaGroup,[bool]$IsPartner,[bool]$IsStanding,$JustText='',[bool]$IsBreakGlass=$false)
    $key = if ($Upn) { $Upn.ToLower() } else { $null }
    $just = if ($JustText) { $JustText } elseif ($key -and $Justification.ContainsKey($key)) { $Justification[$key] } else { '' }
    $records.Add([pscustomobject]@{
        Role=$Role; Name=$Name; Upn=$Upn; Tier=$Tier; State=$State
        AssignmentType=$AssignmentType; ActiveUntil=$ActiveUntil; Proof=$Proof
        ViaGroup=$ViaGroup; IsPartner=$IsPartner; IsStanding=$IsStanding; IsBreakGlass=$IsBreakGlass; Justification=$just
    })
}

function Resolve-GroupMembers($groupId, $tier, $role, $state, $atype, $until, $proof) {
    foreach ($m in (Get-MgGroupMember -GroupId $groupId -All)) {
        $mi = Get-PrincipalInfo $m $m.Id
        if ($mi.Type -eq 'user') {
            Add-Record $role $mi.Name $mi.Upn $tier $state $atype $until $proof $null $false $false
        }
    }
}

# --- Scan each in-scope role ----------------------------------------------
foreach ($roleName in $RolesInScope) {
    Say "Scanning role: $roleName" 'Cyan'
    $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$roleName'"
    if (-not $roleDef) { Write-Warning "Role definition not found: $roleName"; continue }
    $rid = $roleDef.Id

    # Active schedule instances - carry AssignmentType (Assigned vs Activated),
    # MemberType, EndDateTime, LinkedEligibleRoleAssignmentId. This is the source
    # that lets us separate true standing from a live JIT activation.
    $sched = Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -Filter "roleDefinitionId eq '$rid'" -ExpandProperty Principal -All
    # Durable assignments - safety net to catch partner/GDAP grants that may not
    # surface as schedule instances.
    $plain = Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$rid'" -ExpandProperty Principal -All
    # Eligible (PIM) - baseline "no standing" state.
    $eligible = Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -Filter "roleDefinitionId eq '$rid'" -ExpandProperty Principal -All

    $seenPrincipals = @{}

    # 1) Active schedule instances (rich) -----------------------------------
    foreach ($inst in $sched) {
        $pi     = Get-PrincipalInfo $inst.Principal $inst.PrincipalId
        $atype  = "$($inst.AssignmentType)"                       # Assigned | Activated
        $mtype  = "$($inst.MemberType)"                           # Direct | Group | Inherited
        $end    = if ($inst.EndDateTime) { ([datetime]$inst.EndDateTime).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC' } else { 'No end (permanent)' }
        $linked = "$($inst.LinkedEligibleRoleAssignmentId)"
        $seenPrincipals[$pi.Id] = $true

        if ($pi.Type -eq 'group' -and $pi.Name -match $PartnerGroupPattern) {
            Add-Record $roleName "$($pi.Name) (members in partner tenant)" '' 'Partner' 'Active - partner (GDAP)' $atype 'Time-bound at relationship level - see partner table' 'Cross-tenant GDAP grant; members managed in the partner tenant and not enumerable here. Not a permanent per-user assignment - the GDAP relationship is time-bound (see partner relationships table for expiry / auto-extend).' $pi.Name $true $false $PartnerJustification
            continue
        }
        if ($pi.Type -eq 'group') {
            $tier = if ($TierMap.Contains($pi.Name)) { $TierMap[$pi.Name] } else { '(group)' }
            # A standing (Assigned) role on a non-partner group means members hold it via the group.
            Resolve-GroupMembers $pi.Id $tier $roleName 'Active - via group' $atype $end "Role assigned to group '$($pi.Name)' ($atype)."
            continue
        }
        if ($pi.Type -eq 'user') {
            if ($atype -eq 'Activated') {
                $proof = "PIM JIT activation (assignmentType=Activated, memberType=$mtype). Expires $end. Derived from eligible assignment id $linked."
                Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - PIM-activated (JIT)' $atype $end $proof $null $false $false
            } else {
                if ($BreakGlassUpns -contains $pi.Upn) {
                    $proof = "assignmentType=Assigned, memberType=$mtype. $end. Standing by design - designated break-glass / emergency-access account."
                    Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - BREAK-GLASS (by design)' $atype $end $proof $null $false $false $BreakGlassJustification $true
                } else {
                    $proof = "assignmentType=Assigned, memberType=$mtype. $end. Standing/permanent - not JIT."
                    Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - STANDING/DIRECT' $atype $end $proof $null $false $true
                }
            }
            continue
        }
        # service principal / other
        $isP = ($pi.Name -match $PartnerGroupPattern)
        Add-Record $roleName "$($pi.Name) [$($pi.Type)]" $pi.Upn '-' 'Active' $atype $end '' $null $isP $false
    }

    # 2) Durable assignments not seen above (typically partner GDAP) ---------
    foreach ($a in $plain) {
        if ($seenPrincipals.ContainsKey($a.PrincipalId)) { continue }
        $pi = Get-PrincipalInfo $a.Principal $a.PrincipalId
        if ($pi.Type -eq 'group' -and $pi.Name -match $PartnerGroupPattern) {
            Add-Record $roleName "$($pi.Name) (members in partner tenant)" '' 'Partner' 'Active - partner (GDAP)' 'Assigned' 'Time-bound at relationship level - see partner table' 'Cross-tenant GDAP grant; members managed in the partner tenant and not enumerable here. Not a permanent per-user assignment - the GDAP relationship is time-bound (see partner relationships table).' $pi.Name $true $false $PartnerJustification
        }
        elseif ($pi.Type -eq 'group') {
            $tier = if ($TierMap.Contains($pi.Name)) { $TierMap[$pi.Name] } else { '(group)' }
            Resolve-GroupMembers $pi.Id $tier $roleName 'Active - via group' 'Assigned' 'No end (permanent)' "Role assigned to group '$($pi.Name)'."
        }
        elseif ($pi.Type -eq 'user') {
            if ($BreakGlassUpns -contains $pi.Upn) {
                Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - BREAK-GLASS (by design)' 'Assigned' 'No end (permanent)' 'Standing by design - designated break-glass / emergency-access account.' $null $false $false $BreakGlassJustification $true
            } else {
                Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - STANDING/DIRECT' 'Assigned' 'No end (permanent)' 'Durable assignment (not a PIM schedule instance).' $null $false $true
            }
        }
    }

    # 3) Eligible (PIM) - baseline no-standing state ------------------------
    foreach ($e in $eligible) {
        $pi = Get-PrincipalInfo $e.Principal $e.PrincipalId
        if ($pi.Type -eq 'user') {
            Add-Record $roleName $pi.Name $pi.Upn '-' 'Eligible (PIM / JIT)' 'Eligible' 'Not currently active' 'PIM-eligible; no standing access until activated.' $null $false $false
        }
        elseif ($pi.Type -eq 'group' -and $pi.Name -notmatch $PartnerGroupPattern) {
            $tier = if ($TierMap.Contains($pi.Name)) { $TierMap[$pi.Name] } else { '(group)' }
            Resolve-GroupMembers $pi.Id $tier $roleName 'Eligible (PIM / JIT)' 'Eligible' 'Not currently active' "Eligible via group '$($pi.Name)'; JIT, time-bound, no standing access."
        }
    }
}

# --- Dedup (user may appear as eligible AND currently activated) -----------
# Keep the most privileged/active representation per (Role, Upn): Standing >
# Activated > via-group > Eligible. Users with no UPN (partner rows) are kept as-is.
$rank = @{ 'Active - STANDING/DIRECT'=5; 'Active - BREAK-GLASS (by design)'=5; 'Active - partner (GDAP)'=4; 'Active - PIM-activated (JIT)'=3; 'Active - via group'=2; 'Eligible (PIM / JIT)'=1 }
$deduped = $records | Group-Object Role, { $_.Upn } | ForEach-Object {
    if (-not $_.Group[0].Upn) { $_.Group }   # partner/no-upn rows: keep all
    else { $_.Group | Sort-Object @{e={$rank[$_.State]}} -Descending | Select-Object -First 1 }
}
$records = [System.Collections.Generic.List[object]]::new()
$deduped | ForEach-Object { $records.Add($_) }

# --- Summary + flags -------------------------------------------------------
$distinctUsers = ($records | Where-Object { $_.Upn } | Select-Object -ExpandProperty Upn -Unique).Count
$standing      = $records | Where-Object { $_.IsStanding }
$standingCount = @($standing).Count
$activated     = $records | Where-Object { $_.State -like '*PIM-activated*' }
$breakGlass    = $records | Where-Object { $_.IsBreakGlass } | Select-Object -ExpandProperty Upn -Unique
$partnerGrants = $records | Where-Object { $_.IsPartner } | Select-Object -ExpandProperty ViaGroup -Unique

$flags = New-Object System.Collections.Generic.List[string]
if ($standingCount -gt 0) {
    $names = ($standing | ForEach-Object { if ($_.Upn) { $_.Upn } else { $_.Name } } | Sort-Object -Unique) -join ', '
    $flags.Add("STANDING / DIRECT admin present ($standingCount, target 0): $names. assignmentType=Assigned, no expiry. Review/remediate or document justification.")
} else {
    $flags.Add("No unmanaged standing/direct admin - administrative access is PIM-eligible for tier users; the only standing GA is the designated break-glass account (by design).")
}
if (@($breakGlass).Count -gt 0) {
    $flags.Add("$(@($breakGlass).Count) break-glass / emergency-access account (standing GA BY DESIGN): $($breakGlass -join ', '). Retained so the tenant stays reachable if PIM/MFA/CA fail. Verify the break-glass control set (CA-excluded, FIDO2, vaulted rotated password, sign-in alerting, GA-only) is in place - the designation depends on it.")
}
if (@($activated).Count -gt 0) {
    $an = ($activated | ForEach-Object { $_.Upn } | Sort-Object -Unique) -join ', '
    $flags.Add("$(@($activated).Count) user(s) had a LIVE PIM activation at scan time ($an). These are JIT (assignmentType=Activated), time-bound, and linked to an eligible assignment - proof the eligible->activate model is working, NOT standing access.")
}
$partnerIntune = @($records | Where-Object { $_.IsPartner -and $_.Role -eq 'Intune Administrator' } | Select-Object -ExpandProperty ViaGroup -Unique)
if ($partnerIntune.Count -gt 1) {
    $flags.Add("MORE THAN ONE partner group holds Intune Administrator ($($partnerIntune.Count)): $($partnerIntune -join ', '). Two partner paths into Intune - both must be dispositioned.")
} elseif ($partnerIntune.Count -eq 1) {
    $flags.Add("Partner (GDAP) group holds Intune Administrator: $($partnerIntune -join ', '). Cross-tenant standing grant - disposition it.")
}

# --- Integrity hash --------------------------------------------------------
$nowUtc = (Get-Date).ToUniversalTime()
$stamp  = $nowUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
$fstamp = $nowUtc.ToString('yyyyMMdd_HHmmss')
$canonical = ($records | Sort-Object Role, Name, State |
    ForEach-Object { "$($_.Role)|$($_.Name)|$($_.Upn)|$($_.Tier)|$($_.State)|$($_.AssignmentType)|$($_.IsPartner)|$($_.IsStanding)" }) -join "`n"
$canonical += "`n$TenantId`n$stamp`n$Collector"
$sha = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLower()

# --- HTML ------------------------------------------------------------------
$rowsHtml = ($records | Sort-Object @{e={$_.IsPartner}}, Role | ForEach-Object {
    $cls = if ($_.IsBreakGlass) { ' class="bg"' }
           elseif ($_.IsStanding) { ' class="flag"' }
           elseif ($_.IsPartner) { ' class="partner"' }
           elseif ($_.State -like '*PIM-activated*') { ' class="jit"' }
           else { '' }
    "<tr$cls><td>$(HE $_.Role)</td><td>$(HE $_.Name)</td><td>$(HE $_.Upn)</td><td>$(HE $_.Tier)</td><td>$(HE $_.State)</td><td>$(HE $_.ActiveUntil)</td><td class='ev'>$(HE $_.Proof)</td><td>$(HE $_.Justification)</td></tr>"
}) -join "`n"

$partnerHtml = ($PartnerRelationships | ForEach-Object {
    "<tr><td>$(HE $_.Name)</td><td>$(HE $_.Partner)</td><td>$(HE $_.Type)</td><td>$(HE $_.Roles)</td><td>$(HE $_.Expires)</td><td>$(HE $_.AutoExtend)</td><td>$(HE $_.Decision)</td></tr>"
}) -join "`n"
$flagsHtml = ($flags | ForEach-Object { "<li>$(HE $_)</li>" }) -join "`n"
$dispHtml = ($Dispositions | ForEach-Object {
    "<tr><td>$(HE $_.Item)</td><td>$(HE $_.Finding)</td><td>$(HE $_.Action)</td><td>$(HE $_.Status)</td></tr>"
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Intune Privileged Access Evidence - $fstamp</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;color:#1a1a1a;margin:32px;font-size:12.5px;line-height:1.45}
 h1{font-size:20px;margin:0 0 2px} h2{font-size:15px;margin:22px 0 6px;border-bottom:1px solid #ddd;padding-bottom:3px}
 .sub{color:#555;margin:0 0 16px}
 table{border-collapse:collapse;width:100%;margin-top:6px} th,td{border:1px solid #d0d0d0;padding:5px 7px;text-align:left;vertical-align:top}
 th{background:#f3f5f7} td.ev{font-size:11px;color:#444;max-width:280px}
 .meta td{border:none;padding:2px 10px 2px 0} .meta td:first-child{color:#555;white-space:nowrap;width:190px}
 tr.flag td{background:#fff2f2} tr.partner td{background:#eef3fb} tr.jit td{background:#eefbf0} tr.bg td{background:#eeeefb}
 .legend span{display:inline-block;margin-right:14px;font-size:11px;color:#555}
 .legend i{display:inline-block;width:11px;height:11px;border:1px solid #bbb;vertical-align:middle;margin-right:4px}
 .callout{border:1px solid #e0a800;background:#fff9e8;border-radius:6px;padding:10px 14px;margin:14px 0}
 .callout h3{margin:0 0 6px;font-size:14px;color:#8a6100}
 .hash{font-family:Consolas,monospace;font-size:11px;word-break:break-all;color:#333}
 footer{margin-top:22px;color:#666;font-size:11px;border-top:1px solid #ddd;padding-top:8px}
</style></head><body>

<h1>Microsoft Intune - Privileged Access Evidence</h1>
<p class="sub">Point-in-time export &middot; access-review control evidence</p>

<table class="meta">
 <tr><td>Tenant ID</td><td>$TenantId</td></tr>
 <tr><td>Generated (UTC)</td><td>$stamp</td></tr>
 <tr><td>Collected by</td><td>$(HE $Collector)</td></tr>
 <tr><td>Method</td><td>Microsoft Graph role-management API (read-only). Active assignments read from roleAssignmentScheduleInstances to distinguish standing (Assigned) from PIM-activated (Activated); eligible from roleEligibilityScheduleInstances; groups resolved to members.</td></tr>
 <tr><td>Roles in scope</td><td>$(HE ($RolesInScope -join ', '))</td></tr>
 <tr><td>Distinct users</td><td>$distinctUsers</td></tr>
 <tr><td>Standing / direct admin</td><td>$standingCount&nbsp;&nbsp;(unmanaged standing, assignmentType=Assigned, target 0)</td></tr>
 <tr><td>Break-glass accounts</td><td>$(@($breakGlass).Count)&nbsp;&nbsp;(standing GA by design - emergency access)</td></tr>
 <tr><td>Live PIM activations at scan</td><td>$(@($activated).Count)&nbsp;&nbsp;(assignmentType=Activated - JIT, time-bound)</td></tr>
 <tr><td>Partner (GDAP) grants</td><td>$(@($partnerGrants).Count)</td></tr>
</table>

<h2>Access model</h2>
<p>Administrative access to Intune is governed by a tiered PIM model. L2 operators and L3 administrators hold Intune / Global Administrator as <strong>PIM-eligible</strong> assignments inherited through role-assignable security groups; activation is just-in-time and time-bound, so no standing administrative access exists for these users. A row shown as <em>Active - PIM-activated (JIT)</em> is a live activation of an eligible role at the moment of the scan (see the expiry and linked-eligible evidence), <strong>not</strong> a standing assignment. L1 read-only staff are excluded. Any designated <strong>break-glass / emergency-access</strong> account holding standing Global Administrator by design (shown as <em>Active - BREAK-GLASS</em>) is retained so the tenant remains reachable if PIM, MFA, or Conditional Access fail; it is hardened per the break-glass control set. Partner (GDAP) grants are cross-tenant and controlled from the partner tenant; they are listed and labelled for completeness.</p>

<p class="legend">
 <span><i style="background:#fff2f2"></i>Standing / direct (exception)</span>
 <span><i style="background:#eeeefb"></i>Break-glass (standing by design)</span>
 <span><i style="background:#eefbf0"></i>PIM-activated (JIT, time-bound)</span>
 <span><i style="background:#eef3fb"></i>Partner (GDAP)</span>
 <span><i style="background:#fff"></i>Eligible / via group</span>
</p>

<div class="callout"><h3>Exceptions &amp; flags</h3><ul>
 $flagsHtml
</ul></div>

<h2>Privileged assignments</h2>
<table>
 <tr><th>Role</th><th>Name</th><th>User principal name</th><th>Tier</th><th>State</th><th>Active until</th><th>Evidence</th><th>Business justification / status</th></tr>
 $rowsHtml
</table>

<h2>Partner (GDAP) relationships</h2>
<p class="sub">Observed in Microsoft 365 admin center &rarr; Settings &rarr; Partner relationships. These are <strong>GDAP</strong> relationships (not legacy DAP).</p>
<table>
 <tr><th>Relationship</th><th>Partner</th><th>Type</th><th>Roles</th><th>Expires</th><th>Auto-extend</th><th>Decision</th></tr>
 $partnerHtml
</table>

<h2>Remediation &amp; dispositions</h2>
<p class="sub">Actions taken during this access review, retained as the audit trail for the control.</p>
<table>
 <tr><th>Item</th><th>Finding</th><th>Action</th><th>Status</th></tr>
 $dispHtml
</table>

<h2>Integrity</h2>
<p>This document is a point-in-time export. The hash below is computed over the assignment data, tenant ID, timestamp, and operator. Any later change invalidates it.</p>
<p class="hash">SHA-256: $sha</p>

<footer>Generated $stamp from tenant $TenantId by $(HE $Collector). Access is enforced via Entra ID Privileged Identity Management and role-assignable groups. Integrity hash SHA-256 $sha.</footer>
</body></html>
"@

# --- Write out -------------------------------------------------------------
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$outFile = Join-Path $OutputDir "Intune_Privileged_Access_Evidence_$fstamp.html"
$html | Out-File -FilePath $outFile -Encoding utf8

Say ""
Say "==================== SUMMARY ====================" 'Cyan'
Say ("Distinct users            : {0}" -f $distinctUsers)
Say ("Standing / direct admin   : {0} (assignmentType=Assigned, target 0)" -f $standingCount) $(if($standingCount -gt 0){'Yellow'}else{'Green'})
Say ("Live PIM activations      : {0} (assignmentType=Activated, JIT)" -f @($activated).Count) 'Green'
Say ("Partner GDAP grants       : {0}" -f @($partnerGrants).Count)
foreach ($f in $flags) { Say ("  ! " + $f) 'Yellow' }
Say ""
Say ("HTML evidence : {0}" -f $outFile) 'Green'
Say ("SHA-256       : {0}" -f $sha) 'Green'
Say "Open the HTML and capture the date-stamped screenshot for your evidence store."
