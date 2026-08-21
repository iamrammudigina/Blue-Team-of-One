<#
================================================================================
 Get-PrivilegedAccessReport.ps1
 Privileged access reporter - who holds admin, and is it standing or JIT?
--------------------------------------------------------------------------------
 Interactive. Just run it - it asks for everything it needs:

   1. The tenant ID to connect to.
   2. It checks the signed-in account can actually read role-management data,
      and if not, tells you what you need and exits.
   3. It scans EVERY privileged Entra role by default (you can add extra roles).
   4. For each holder it shows HOW the role is held:
        - Assigned  : permanent / standing assignment   (the real exception)
        - Activated : a live PIM (JIT) activation        (time-bound, NOT standing)
        - Eligible  : PIM-eligible, not currently active (baseline "no standing")
      Role-assignable groups are resolved to members; cross-tenant partner
      (GDAP) grants are detected and labelled.
   5. It asks where to save, and writes a date-stamped, SHA-256'd HTML report.

 Read-only. Requires the Microsoft Graph PowerShell SDK:
     Install-Module Microsoft.Graph -Scope CurrentUser
================================================================================
#>

[CmdletBinding()]
param(
    [string]  $TenantId,
    [string[]]$AdditionalRoles,
    [string]  $OutputDir
)

Add-Type -AssemblyName System.Web
$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function HE($s) { [System.Web.HttpUtility]::HtmlEncode([string]$s) }
function Ask($prompt, $default = '') {
    $p = if ($default) { "$prompt`n  [$default] > " } else { "$prompt`n  > " }
    $a = Read-Host -Prompt $p
    if ([string]::IsNullOrWhiteSpace($a)) { return $default } else { return $a.Trim() }
}
function AskList($prompt, $default = '') {
    $raw = Ask $prompt $default
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

Say ""
Say "===============================================================" 'Cyan'
Say " Privileged Access Report" 'Cyan'
Say " Read-only. Press Enter at a prompt to accept the [default]." 'DarkGray'
Say "===============================================================" 'Cyan'
Say ""

# --- 1. Tenant to connect to ----------------------------------------------
if (-not $PSBoundParameters.ContainsKey('TenantId')) {
    $TenantId = Ask "Tenant ID (GUID) or domain to connect to (Enter = your default tenant)" ''
}

# --- Connect --------------------------------------------------------------
$scopes = @('RoleManagement.Read.Directory','Directory.Read.All','GroupMember.Read.All','User.Read.All')
Say "Connecting to Microsoft Graph..." 'Cyan'
$connect = @{ Scopes = $scopes; NoWelcome = $true }
if ($TenantId) { $connect.TenantId = $TenantId }

function Test-Connected {
    try { $c = Get-MgContext; return ($null -ne $c -and $c.Account) } catch { return $false }
}

# Attempt 1: interactive browser.
try { Connect-MgGraph @connect -ErrorAction Stop } catch {
    Say ("  Interactive sign-in failed: {0}" -f $_.Exception.Message) 'Yellow'
}

# Attempt 2: device code (different auth path; gets past the WAM/MSAL bug).
if (-not (Test-Connected)) {
    Say "  Trying device-code sign-in instead." 'Yellow'
    Say "  >> A URL and a CODE will appear below - open the URL, enter the code, sign in. <<" 'Cyan'
    try { Connect-MgGraph @connect -UseDeviceCode -ErrorAction Stop } catch {
        Say ("  Device-code sign-in failed: {0}" -f $_.Exception.Message) 'Yellow'
    }
}

# Confirm we truly have a session (not just "no error").
if (-not (Test-Connected)) {
    Say ""
    Say "STILL NOT CONNECTED - the sign-in did not complete, so nothing can be read." 'Red'
    Say "This is a sign-in / SDK problem, NOT a permissions problem (your GA is fine)." 'Yellow'
    Say "If the error above mentions 'Method not found ... WithLogging' or InteractiveBrowser," 'Yellow'
    Say "the Microsoft Graph SDK on this machine is mismatched. Clean-reinstall it:" 'Yellow'
    Say "  Get-InstalledModule Microsoft.Graph* | ForEach-Object {" 'Gray'
    Say "      Uninstall-Module `$_.Name -AllVersions -Force -ErrorAction SilentlyContinue }" 'Gray'
    Say "  Install-Module Microsoft.Graph -Scope CurrentUser -Force" 'Gray'
    Say "Then open a NEW PowerShell 7 window (don't import Az/AzureAD) and re-run this script." 'Yellow'
    return
}
$ctx = Get-MgContext
$Collector       = $ctx.Account
$ConnectedTenant = $ctx.TenantId
Say "Connected as $Collector in tenant $ConnectedTenant" 'Green'

# --- 2. Access pre-check: can this account read what we need? --------------
# Probe the actual reads the report depends on. If they fail, the account is
# missing the role/permissions - tell the user what to do and exit.
Say "Checking your access..." 'Cyan'
try {
    $allDefs = Get-MgRoleManagementDirectoryRoleDefinition -All -ErrorAction Stop
    $null    = Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -Top 1 -ErrorAction Stop
    $null    = Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -Top 1 -ErrorAction Stop
    Say "Access OK - can read role definitions, assignments, and eligibility." 'Green'
} catch {
    Say ""
    Say "INSUFFICIENT ACCESS - this account can't read role-management data." 'Red'
    Say ("  Error: {0}" -f $_.Exception.Message) 'DarkGray'
    Say ""
    Say "To run this report you need BOTH:" 'Yellow'
    Say "  1) A directory role that can READ privileged access, e.g. one of:" 'Yellow'
    Say "       - Global Reader        (read-only, recommended)" 'Gray'
    Say "       - Security Reader" 'Gray'
    Say "       - Privileged Role Administrator" 'Gray'
    Say "       - Global Administrator" 'Gray'
    Say "  2) The Microsoft Graph PowerShell app consented for these (read-only)" 'Yellow'
    Say "     delegated scopes (an admin may need to grant consent once):" 'Yellow'
    Say "       RoleManagement.Read.Directory, Directory.Read.All," 'Gray'
    Say "       GroupMember.Read.All, User.Read.All" 'Gray'
    Say ""
    Say "Sign in with a suitable account (or get consent granted) and re-run." 'Yellow'
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}
    return
}

# --- PIM / Entra ID P2 detection ------------------------------------------
# PIM (just-in-time eligible roles) requires Entra ID P2. Check the tenant SKUs.
$p2Present = $false
try {
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop
    $p2Present = [bool]($skus.ServicePlans | Where-Object { $_.ServicePlanName -match 'AAD_PREMIUM_P2' -and $_.ProvisioningStatus -eq 'Success' })
} catch { }
if ($p2Present) {
    Say "Entra ID P2 detected - PIM (just-in-time) is available in this tenant." 'Green'
} else {
    Say "Entra ID P2 NOT detected - PIM/JIT is unavailable; expect standing admin (finding)." 'Yellow'
}

# --- 3. Build the role scope: ALL privileged roles + any extras -----------
$privDefs = @($allDefs | Where-Object { $_.IsPrivileged })
if (-not $privDefs -or $privDefs.Count -eq 0) {
    # Fallback if the tenant/API doesn't surface IsPrivileged: use a core set.
    $core = 'Global Administrator','Privileged Role Administrator','Privileged Authentication Administrator',
            'Security Administrator','Conditional Access Administrator','Application Administrator',
            'Cloud Application Administrator','User Administrator','Intune Administrator','Exchange Administrator',
            'SharePoint Administrator','Authentication Administrator','Helpdesk Administrator'
    $privDefs = @($allDefs | Where-Object { $_.DisplayName -in $core })
    Say "Note: tenant did not flag privileged roles; using a built-in core set." 'DarkGray'
}
Say ("Privileged roles found: {0} (scanned by default)." -f $privDefs.Count) 'Green'

if (-not $PSBoundParameters.ContainsKey('AdditionalRoles')) {
    $AdditionalRoles = AskList "Add any EXTRA (non-privileged) roles to scan? (comma-separated, Enter = none)" ''
}
$extraDefs = @()
foreach ($rn in $AdditionalRoles) {
    $d = $allDefs | Where-Object { $_.DisplayName -ieq $rn } | Select-Object -First 1
    if ($d) { $extraDefs += $d } else { Say "  (role not found, skipping: $rn)" 'Yellow' }
}

# de-dup by Id, keep Name + Id
$scopeRoles = @($privDefs + $extraDefs | Sort-Object Id -Unique | ForEach-Object {
    [pscustomobject]@{ Id = $_.Id; Name = $_.DisplayName }
})
Say ("Total roles in scope: {0}" -f $scopeRoles.Count) 'DarkGray'
Say ""

# How partner / GDAP groups are recognised by display name.
# Groups that are cross-tenant partner / delegated-admin (GDAP or legacy DAP)
# principals. Their members live in the PARTNER tenant and are NOT enumerable
# here. Recognise: the word GDAP, the classic "AdminAgents"/"HelpdeskAgents"
# delegated-admin group names, and the foreign-principal render "Name @( Org , domain )".
$PartnerGroupPattern = '(?i)(\bGDAP\b|\bAdminAgents\b|\bHelpdeskAgents\b|@\s*\()'
$PartnerNote = 'Cross-tenant partner / delegated-admin grant (GDAP or legacy DAP, e.g. "AdminAgents"/"HelpdeskAgents"). Members live in the partner tenant and are not enumerable here. Review under Partner relationships (M365 admin center) and confirm it is still required and least-privilege - legacy DAP in particular should be removed.'

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
    param($Role,$Name,$Upn,$Tier,$State,$AssignmentType,$ActiveUntil,$Proof,$ViaGroup,[bool]$IsPartner,[bool]$IsStanding,$Note='')
    $records.Add([pscustomobject]@{
        Role=$Role; Name=$Name; Upn=$Upn; Tier=$Tier; State=$State
        AssignmentType=$AssignmentType; ActiveUntil=$ActiveUntil; Proof=$Proof
        ViaGroup=$ViaGroup; IsPartner=$IsPartner; IsStanding=$IsStanding; Note=$Note
    })
}
function Resolve-GroupMembers($groupId, $groupName, $role, $state, $atype, $until, $proof, [bool]$isStanding) {
    $members = $null
    try {
        $members = Get-MgGroupMember -GroupId $groupId -All -ErrorAction Stop
    } catch {
        $short = (($_.Exception.Message -split "`n")[0]).Trim()
        if ($short -match 'ResourceNotFound|does not exist') {
            # The group no longer exists: an assignment/eligibility is still pointing
            # at a DELETED group. That's an orphaned, stale grant - a cleanup finding.
            $held = if ($isStanding) { 'assigned (standing)' } else { 'as eligible' }
            Add-Record $role "$groupName (group deleted)" '' '-' "$state - ORPHANED (group deleted)" $atype $until "Group no longer exists: $short" $groupName $false $false "ORPHANED: '$groupName' has been deleted, but this role is still $held to it. Remove the stale assignment/eligibility so the role no longer references a non-existent group."
        } else {
            # Access denied or some other read failure - list it as a group grant.
            Add-Record $role "$groupName (members not readable)" '' '-' $state $atype $until "Group members could not be read: $short" $groupName $false $isStanding "Group '$groupName' members are not readable (access denied). Listed as a group grant."
        }
        return
    }
    foreach ($m in $members) {
        $mi = Get-PrincipalInfo $m $m.Id
        if ($mi.Type -eq 'user') { Add-Record $role $mi.Name $mi.Upn '-' $state $atype $until $proof $groupName $false $isStanding }
    }
}

# --- 4. Scan each in-scope role -------------------------------------------
$i = 0; $roleErrors = 0
foreach ($rdef in $scopeRoles) {
    $i++; $roleName = $rdef.Name; $rid = $rdef.Id
    Write-Progress -Activity "Scanning privileged roles" -Status "$roleName ($i/$($scopeRoles.Count))" -PercentComplete (($i/$scopeRoles.Count)*100)

    try {
        $sched    = Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance   -Filter "roleDefinitionId eq '$rid'" -ExpandProperty Principal -All
        $plain    = Get-MgRoleManagementDirectoryRoleAssignment                    -Filter "roleDefinitionId eq '$rid'" -ExpandProperty Principal -All
        $eligible = Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance   -Filter "roleDefinitionId eq '$rid'" -ExpandProperty Principal -All

        $seen = @{}

        foreach ($inst in $sched) {
            $pi    = Get-PrincipalInfo $inst.Principal $inst.PrincipalId
            $atype = "$($inst.AssignmentType)"          # Assigned | Activated
            $mtype = "$($inst.MemberType)"
            $end   = if ($inst.EndDateTime) { ([datetime]$inst.EndDateTime).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC' } else { 'No end (permanent)' }
            $linked= "$($inst.LinkedEligibleRoleAssignmentId)"
            $seen[$pi.Id] = $true

            if ($pi.Type -eq 'group' -and $pi.Name -match $PartnerGroupPattern) {
                Add-Record $roleName "$($pi.Name) (members in partner tenant)" '' 'Partner' 'Active - partner (cross-tenant)' $atype 'Time-bound at relationship level' 'Cross-tenant partner (GDAP/DAP) grant; members in the partner tenant, not enumerable here.' $pi.Name $true $false $PartnerNote
            }
            elseif ($pi.Type -eq 'group') {
                # Role ASSIGNED (not eligible) to a group = members have STANDING access via the group.
                Resolve-GroupMembers $pi.Id $pi.Name $roleName 'Active - STANDING via group' $atype $end "Standing role assigned to group '$($pi.Name)' ($atype). Members hold it permanently via the group." $true
            }
            elseif ($pi.Type -eq 'user') {
                if ($atype -eq 'Activated') {
                    Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - PIM-activated (JIT)' $atype $end "PIM JIT activation (assignmentType=Activated, memberType=$mtype). Expires $end. From eligible assignment id $linked." $null $false $false
                } else {
                    Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - STANDING/DIRECT' $atype $end "assignmentType=Assigned, memberType=$mtype. $end. Standing/permanent - not JIT." $null $false $true
                }
            }
            else {
                $isP = ($pi.Name -match $PartnerGroupPattern)
                Add-Record $roleName "$($pi.Name) [$($pi.Type)]" $pi.Upn '-' 'Active' $atype $end '' $null $isP $false
            }
        }

        foreach ($a in $plain) {
            if ($seen.ContainsKey($a.PrincipalId)) { continue }
            $pi = Get-PrincipalInfo $a.Principal $a.PrincipalId
            if ($pi.Type -eq 'group' -and $pi.Name -match $PartnerGroupPattern) {
                Add-Record $roleName "$($pi.Name) (members in partner tenant)" '' 'Partner' 'Active - partner (cross-tenant)' 'Assigned' 'Time-bound at relationship level' 'Cross-tenant partner (GDAP/DAP) grant; members in the partner tenant, not enumerable here.' $pi.Name $true $false $PartnerNote
            }
            elseif ($pi.Type -eq 'group') {
                Resolve-GroupMembers $pi.Id $pi.Name $roleName 'Active - STANDING via group' 'Assigned' 'No end (permanent)' "Standing role assigned to group '$($pi.Name)'. Members hold it permanently via the group." $true
            }
            elseif ($pi.Type -eq 'user') {
                Add-Record $roleName $pi.Name $pi.Upn '-' 'Active - STANDING/DIRECT' 'Assigned' 'No end (permanent)' 'Durable assignment (not a PIM schedule instance).' $null $false $true
            }
        }

        foreach ($e in $eligible) {
            $pi = Get-PrincipalInfo $e.Principal $e.PrincipalId
            if ($pi.Type -eq 'user') {
                Add-Record $roleName $pi.Name $pi.Upn '-' 'Eligible (PIM / JIT)' 'Eligible' 'Not currently active' 'PIM-eligible; no standing access until activated.' $null $false $false
            }
            elseif ($pi.Type -eq 'group' -and $pi.Name -notmatch $PartnerGroupPattern) {
                Resolve-GroupMembers $pi.Id $pi.Name $roleName 'Eligible (PIM / JIT)' 'Eligible' 'Not currently active' "Eligible via group '$($pi.Name)'; JIT, time-bound, no standing access." $false
            }
        }
    } catch {
        $roleErrors++
        Write-Warning "Role '$roleName' could not be fully scanned: $((($_.Exception.Message -split "`n")[0]).Trim())"
    }
}
Write-Progress -Activity "Scanning privileged roles" -Completed
if ($roleErrors -gt 0) { Say "$roleErrors role(s) hit an error during scan (see warnings above); the rest completed." 'Yellow' }

# --- Dedup (user may appear as eligible AND currently activated) -----------
$rank = @{ 'Active - STANDING/DIRECT'=5; 'Active - STANDING via group'=4; 'Active - partner (cross-tenant)'=4; 'Active - PIM-activated (JIT)'=3; 'Eligible (PIM / JIT)'=1 }
$deduped = $records | Group-Object Role, { $_.Upn } | ForEach-Object {
    if (-not $_.Group[0].Upn) { $_.Group }
    else { $_.Group | Sort-Object @{e={$rank[$_.State]}} -Descending | Select-Object -First 1 }
}
$records = [System.Collections.Generic.List[object]]::new()
$deduped | ForEach-Object { $records.Add($_) }

# --- Summary + flags -------------------------------------------------------
$distinctUsers   = ($records | Where-Object { $_.Upn } | Select-Object -ExpandProperty Upn -Unique).Count
$standing        = $records | Where-Object { $_.IsStanding }
$standingCount   = @($standing).Count
$standingDirect  = @($records | Where-Object { $_.State -eq 'Active - STANDING/DIRECT' }).Count
$standingViaGrp  = @($records | Where-Object { $_.State -like '*STANDING via group*' }).Count
$activated       = $records | Where-Object { $_.State -like '*PIM-activated*' }
$eligibleCount   = @($records | Where-Object { $_.State -like 'Eligible*' }).Count
$jitCount        = @($activated).Count + $eligibleCount
$partnerGrants   = $records | Where-Object { $_.IsPartner } | Select-Object -ExpandProperty ViaGroup -Unique
$rolesWithHolders= ($records | Select-Object -ExpandProperty Role -Unique).Count

$flags = New-Object System.Collections.Generic.List[string]

# PIM / P2 finding
if (-not $p2Present) {
    $flags.Add("FINDING: Entra ID P2 not detected - Privileged Identity Management (just-in-time access) is unavailable, so privileged roles can only be held as STANDING assignments. There is no path to 'no standing admin' without P2.")
} elseif ($jitCount -eq 0 -and $standingCount -gt 0) {
    $flags.Add("FINDING: P2 is present but NO role is eligible/JIT - every in-scope holder has STANDING access. PIM is available but not being used for these roles.")
}

# Standing findings (direct + via group both count as standing)
if ($standingCount -gt 0) {
    $names = ($standing | ForEach-Object { if ($_.Upn) { $_.Upn } else { $_.Name } } | Sort-Object -Unique) -join ', '
    $flags.Add("STANDING admin present ($standingCount, target 0) - $standingDirect direct/user, $standingViaGrp via group. assignmentType=Assigned, no expiry. Holders: $names. Move to PIM-eligible or document a justification.")
} else {
    $flags.Add("No standing/direct admin on any in-scope role - administrative access is PIM-eligible/activated.")
}
if (@($activated).Count -gt 0) {
    $an = ($activated | ForEach-Object { $_.Upn } | Sort-Object -Unique) -join ', '
    $flags.Add("$(@($activated).Count) user(s) had a LIVE PIM activation at scan time ($an). JIT (assignmentType=Activated), time-bound, linked to an eligible assignment - proof the model works, NOT standing access.")
}
$partnerRoles = @($records | Where-Object { $_.IsPartner } | Select-Object -ExpandProperty ViaGroup -Unique)
if ($partnerRoles.Count -gt 0) {
    $flags.Add("$($partnerRoles.Count) cross-tenant partner (GDAP/DAP) group(s) hold an in-scope role: $($partnerRoles -join ', '). Members live in the partner tenant. Review under Partner relationships and confirm each is still required and least-privilege (remove any legacy DAP).")
}
$orphaned = @($records | Where-Object { $_.State -like '*ORPHANED*' })
if ($orphaned.Count -gt 0) {
    $og = ($orphaned | ForEach-Object { ($_.Name -replace ' \(group deleted\)$','') } | Sort-Object -Unique) -join ', '
    $flags.Add("FINDING: $($orphaned.Count) assignment(s)/eligibility point at a DELETED group ($og). These are orphaned - remove the stale role assignment/eligibility so the role no longer references a group that no longer exists.")
}

# --- Integrity hash --------------------------------------------------------
$nowUtc = (Get-Date).ToUniversalTime()
$stamp  = $nowUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
$fstamp = $nowUtc.ToString('yyyyMMdd_HHmmss')
$canonical = ($records | Sort-Object Role, Name, State |
    ForEach-Object { "$($_.Role)|$($_.Name)|$($_.Upn)|$($_.State)|$($_.AssignmentType)|$($_.IsPartner)|$($_.IsStanding)" }) -join "`n"
$canonical += "`n$ConnectedTenant`n$stamp`n$Collector"
$sha = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLower()

# --- HTML ------------------------------------------------------------------
$rowsHtml = ($records | Sort-Object @{e={$_.IsPartner}}, Role | ForEach-Object {
    $cls = if ($_.IsStanding) { ' class="flag"' } elseif ($_.IsPartner) { ' class="partner"' } elseif ($_.State -like '*PIM-activated*') { ' class="jit"' } else { '' }
    "<tr$cls><td>$(HE $_.Role)</td><td>$(HE $_.Name)</td><td>$(HE $_.Upn)</td><td>$(HE $_.State)</td><td>$(HE $_.ActiveUntil)</td><td class='ev'>$(HE $_.Proof)</td><td>$(HE $_.Note)</td></tr>"
}) -join "`n"
$flagsHtml = ($flags | ForEach-Object { "<li>$(HE $_)</li>" }) -join "`n"

$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Privileged Access Report - $fstamp</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;color:#1a1a1a;margin:32px;font-size:12.5px;line-height:1.45}
 h1{font-size:20px;margin:0 0 2px} h2{font-size:15px;margin:22px 0 6px;border-bottom:1px solid #ddd;padding-bottom:3px}
 .sub{color:#555;margin:0 0 16px}
 table{border-collapse:collapse;width:100%;margin-top:6px} th,td{border:1px solid #d0d0d0;padding:5px 7px;text-align:left;vertical-align:top}
 th{background:#f3f5f7} td.ev{font-size:11px;color:#444;max-width:320px}
 .meta td{border:none;padding:2px 10px 2px 0} .meta td:first-child{color:#555;white-space:nowrap;width:190px}
 tr.flag td{background:#fff2f2} tr.partner td{background:#eef3fb} tr.jit td{background:#eefbf0}
 .legend span{display:inline-block;margin-right:14px;font-size:11px;color:#555}
 .legend i{display:inline-block;width:11px;height:11px;border:1px solid #bbb;vertical-align:middle;margin-right:4px}
 .callout{border:1px solid #e0a800;background:#fff9e8;border-radius:6px;padding:10px 14px;margin:14px 0}
 .callout h3{margin:0 0 6px;font-size:14px;color:#8a6100}
 .hash{font-family:Consolas,monospace;font-size:11px;word-break:break-all;color:#333}
 footer{margin-top:22px;color:#666;font-size:11px;border-top:1px solid #ddd;padding-top:8px}
</style></head><body>

<h1>Privileged Access Report</h1>
<p class="sub">Point-in-time export &middot; who holds privileged roles, and how</p>

<table class="meta">
 <tr><td>Tenant ID</td><td>$ConnectedTenant</td></tr>
 <tr><td>Generated (UTC)</td><td>$stamp</td></tr>
 <tr><td>Collected by</td><td>$(HE $Collector)</td></tr>
 <tr><td>Method</td><td>Microsoft Graph role-management API (read-only). Active assignments read from roleAssignmentScheduleInstances to distinguish standing (Assigned) from PIM-activated (Activated); eligible from roleEligibilityScheduleInstances; groups resolved to members.</td></tr>
 <tr><td>Roles scanned</td><td>$($scopeRoles.Count)&nbsp;&nbsp;(all privileged roles$(if($extraDefs.Count){" + $($extraDefs.Count) extra"}))</td></tr>
 <tr><td>Roles with holders</td><td>$rolesWithHolders</td></tr>
 <tr><td>Entra ID P2 / PIM</td><td>$(if($p2Present){'Present - just-in-time (eligible) access available'}else{'NOT present - no PIM/JIT; standing only (finding)'})</td></tr>
 <tr><td>Distinct users</td><td>$distinctUsers</td></tr>
 <tr><td>Standing admin</td><td>$standingCount&nbsp;&nbsp;($standingDirect direct/user + $standingViaGrp via group; assignmentType=Assigned, target 0)</td></tr>
 <tr><td>Live PIM activations at scan</td><td>$(@($activated).Count)&nbsp;&nbsp;(assignmentType=Activated - JIT, time-bound)</td></tr>
 <tr><td>Partner (GDAP) grants</td><td>$(@($partnerGrants).Count)</td></tr>
</table>

<h2>How to read this</h2>
<p>Each row is a holder of a privileged (or added) role, classified by <strong>how</strong> they hold it. <em>Active - STANDING/DIRECT</em> is a permanent assignment (assignmentType=Assigned) - the exception a no-standing-admin control targets at zero. <em>Active - PIM-activated (JIT)</em> is a live activation of an eligible role at the moment of the scan (see expiry + linked-eligible evidence) - time-bound, <strong>not</strong> standing. <em>Eligible (PIM / JIT)</em> is the baseline no-standing state. Cross-tenant partner (GDAP) grants are listed and labelled; their members live in the partner tenant and aren't enumerable here.</p>

<p class="legend">
 <span><i style="background:#fff2f2"></i>Standing / direct (exception)</span>
 <span><i style="background:#eefbf0"></i>PIM-activated (JIT, time-bound)</span>
 <span><i style="background:#eef3fb"></i>Partner (cross-tenant)</span>
 <span><i style="background:#fff"></i>Eligible / via group</span>
</p>

<div class="callout"><h3>Flags</h3><ul>
 $flagsHtml
</ul></div>

<h2>Privileged assignments</h2>
<table>
 <tr><th>Role</th><th>Name</th><th>User principal name</th><th>State</th><th>Active until</th><th>Evidence</th><th>Notes</th></tr>
 $rowsHtml
</table>

<h2>Integrity</h2>
<p>This document is a point-in-time export. The hash below is computed over the assignment data, tenant ID, timestamp, and operator. Any later change invalidates it.</p>
<p class="hash">SHA-256: $sha</p>

<footer>Generated $stamp from tenant $ConnectedTenant by $(HE $Collector). Integrity hash SHA-256 $sha.</footer>
</body></html>
"@

# --- 5. Ask where to save, then write --------------------------------------
Say ""
if (-not $PSBoundParameters.ContainsKey('OutputDir')) {
    $defaultOut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PrivilegedAccess-Evidence'
    $OutputDir  = Ask "Where should I save the HTML report?" $defaultOut
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$outFile = Join-Path $OutputDir "Privileged_Access_Report_$fstamp.html"
$html | Out-File -FilePath $outFile -Encoding utf8

Say ""
Say "==================== SUMMARY ====================" 'Cyan'
Say ("Roles scanned             : {0} (all privileged{1})" -f $scopeRoles.Count, $(if($extraDefs.Count){" + $($extraDefs.Count) extra"}else{""}))
Say ("Distinct users            : {0}" -f $distinctUsers)
Say ("Standing / direct admin   : {0} (assignmentType=Assigned, target 0)" -f $standingCount) $(if($standingCount -gt 0){'Yellow'}else{'Green'})
Say ("Live PIM activations      : {0} (assignmentType=Activated, JIT)" -f @($activated).Count) 'Green'
Say ("Partner GDAP grants       : {0}" -f @($partnerGrants).Count)
foreach ($f in $flags) { Say ("  ! " + $f) 'Yellow' }
Say ""
Say ("HTML report   : {0}" -f $outFile) 'Green'
Say ("SHA-256       : {0}" -f $sha) 'Green'
Say "Open the HTML and capture the date-stamped screenshot for your evidence store."
