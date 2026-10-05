<#
.SYNOPSIS
    Removes the rounded-corner "frame" (rounded corners + margin) that recent
    Microsoft Edge builds force around the web content area.

.DESCRIPTION
    Edge renders the page inside a rounded "central container" with a small
    margin. The old toggle (edge://flags/#edge-rounded-containers) no longer
    exists in current builds, but the internal Edge feature that switches the
    container off is still compiled in:

        --enable-features=msForceNoRoundedCornerAndMargin

    This script writes that switch everywhere Edge can be started from:

      * every Edge shortcut (Start Menu machine + user, Desktop, Public Desktop,
        Quick Launch, taskbar pin)
      * the URL / file protocol handlers, so links opened from other apps are
        covered too
      * the "Startup boost" and "keep running in background" policies, because
        an already running background Edge process silently ignores the switch

    Everything is backed up into %LOCALAPPDATA%\EdgeNoRoundedFrame (a JSON
    manifest plus copies of the shortcuts and exported .reg files) and can be
    reverted with -Undo.

.PARAMETER Undo
    Restore every change recorded in the backup manifest.

.PARAMETER Test
    Measure the content area with and without the switch using a throwaway Edge
    profile (no changes to your shortcuts or profile). Prints the pixel delta.

.PARAMETER SkipPolicies
    Never write policies (this is the default; accepted for compatibility).

.PARAMETER UsePolicies
    Also set StartupBoostEnabled=0 / BackgroundModeEnabled=0 as Edge policies.
    WARNING: Edge then reports itself as "managed by your organization" and locks
    those two switches in edge://settings/system. Prefer switching them off by hand
    in edge://settings/system, as the script's hint tells you to.

.PARAMETER SkipProtocolHandlers
    Do not touch the URL / file protocol handlers.

.PARAMETER NoElevate
    Never ask for administrator rights. Machine-wide shortcuts (ProgramData
    Start Menu) and HKLM policies are then skipped.

.PARAMETER Quiet
    Less console output.

.PARAMETER BackupDir
    Where the backup manifest and shortcut copies live.

.EXAMPLE
    .\EdgeNoRoundedFrame.ps1
    Apply the fix (asks for elevation once, for the machine-wide shortcut).

.EXAMPLE
    .\EdgeNoRoundedFrame.ps1 -Test
    Prove that the switch works on the installed Edge build.

.EXAMPLE
    .\EdgeNoRoundedFrame.ps1 -Undo
    Revert everything.

.NOTES
    Verified on Microsoft Edge 154.0.4258.53 (Windows 11): the switch removes
    an 8x4 px frame around the content area. Undocumented feature, Microsoft may
    remove it in a future build.
#>
[CmdletBinding()]
param(
    [switch]$Undo,
    [switch]$Test,
    [switch]$SkipPolicies,
    [switch]$UsePolicies,
    [switch]$SkipProtocolHandlers,
    [switch]$NoElevate,
    [switch]$Quiet,
    [string]$BackupDir,
    [switch]$MachineOnly
)

$ErrorActionPreference = 'Continue'

$Script:Feature = 'msForceNoRoundedCornerAndMargin'
$Script:Switch  = "--enable-features=$Script:Feature"
$Script:Quiet   = [bool]$Quiet
if (-not $BackupDir) { $BackupDir = Join-Path $env:LOCALAPPDATA 'EdgeNoRoundedFrame' }
$Script:BackupDir = $BackupDir
$Script:Manifest  = Join-Path $BackupDir 'backup.json'
$Script:PolicyNames = @('StartupBoostEnabled', 'BackgroundModeEnabled')

function Say     { param([string]$m) if (-not $Script:Quiet) { Write-Host $m } }
function SayOk   { param([string]$m) Write-Host "  [ok]    $m" -ForegroundColor Green }
function SayNote { param([string]$m) if (-not $Script:Quiet) { Write-Host "  [--]    $m" -ForegroundColor DarkGray } }
function SayWarn { param([string]$m) Write-Host "  [warn]  $m" -ForegroundColor Yellow }
function SayErr  { param([string]$m) Write-Host "  [error] $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-EdgeExe {
    $candidates = @()
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')) {
        if (Test-Path $k) {
            $v = [string](Get-Item $k).GetValue('')
            if ($v) { $candidates += $v.Trim('"') }
        }
    }
    $candidates += @(
        (Join-Path ${env:ProgramFiles} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'))
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# ---------------------------------------------------------------- manifest --

function Get-ManifestData {
    if (Test-Path $Script:Manifest) {
        try { return (Get-Content $Script:Manifest -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Save-ManifestData($m) {
    New-Item -ItemType Directory -Force -Path $Script:BackupDir | Out-Null
    ($m | ConvertTo-Json -Depth 6) | Set-Content -Path $Script:Manifest -Encoding UTF8
}

function Get-ManifestKey {
    param([string]$Kind, $Entry)
    if (-not $Entry) { return '' }
    switch ($Kind) {
        'shortcuts'        { return [string]$Entry.path }
        'protocolHandlers' { return [string]$Entry.key }
        'policies'         { return ([string]$Entry.root + '|' + [string]$Entry.name) }
    }
    return ''
}

function Add-ManifestEntry {
    param([string]$Kind, $Entry)
    $m = Get-ManifestData
    if (-not $m) {
        $m = [pscustomobject]@{
            version          = 2
            feature          = $Script:Feature
            created          = (Get-Date).ToString('s')
            shortcuts        = @()
            protocolHandlers = @()
            policies         = @()
        }
    }
    # replace a previous entry for the same target instead of appending a duplicate
    $newKey = Get-ManifestKey -Kind $Kind -Entry $Entry
    $kept = @()
    foreach ($e in @($m.$Kind)) {
        if ($e -and (Get-ManifestKey -Kind $Kind -Entry $e) -ne $newKey) { $kept += $e }
    }
    $m.$Kind = @($kept) + @($Entry)
    Save-ManifestData $m
}

function Test-ManifestEntry {
    param([string]$Kind, [string]$Property, [string]$Value)
    $m = Get-ManifestData
    if (-not $m) { return $false }
    foreach ($e in @($m.$Kind)) {
        if ($e -and ([string]$e.$Property) -eq $Value) { return $true }
    }
    return $false
}

function Copy-ShortcutBackup {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Script:BackupDir | Out-Null
    $safe = ($Path -replace '[\\/:*?"<>|]', '_')
    Copy-Item -LiteralPath $Path -Destination (Join-Path $Script:BackupDir ($safe + '.lnk.bak')) -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------- patch --

function Get-ShortcutPaths {
    param([string]$Scope)
    $roots = @()
    if ($Scope -eq 'Machine') {
        $roots += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
        $roots += (Join-Path $env:PUBLIC 'Desktop')
    } else {
        $roots += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
        $roots += (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch')
        $roots += (Join-Path $env:USERPROFILE 'Desktop')
    }
    $files = @()
    foreach ($r in $roots) {
        if (Test-Path $r) {
            # -Force is required: taskbar pins live in the hidden "User Pinned" folder
            $files += @(Get-ChildItem -Path $r -Filter *.lnk -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
    }
    return @($files | Sort-Object -Unique)
}

function Invoke-ShortcutPatch {
    param([string]$Scope)
    $sh = New-Object -ComObject WScript.Shell
    $patched = 0
    foreach ($f in (Get-ShortcutPaths -Scope $Scope)) {
        $sc = $null
        try { $sc = $sh.CreateShortcut($f) } catch { continue }
        if ([string]$sc.TargetPath -notlike '*msedge.exe') { continue }
        if ([string]$sc.Arguments -like "*$Script:Feature*") {
            # already patched (e.g. by a previous run or by hand): still record it,
            # otherwise -Undo would have nothing to restore
            $current = [string]$sc.Arguments
            if (Test-ManifestEntry -Kind 'shortcuts' -Property 'path' -Value $f) {
                SayNote "already enabled: $f"
            } else {
                $orig = (($current -replace [regex]::Escape($Script:Switch), '') -replace '\s{2,}', ' ').Trim()
                Copy-ShortcutBackup -Path $f
                Add-ManifestEntry -Kind 'shortcuts' -Entry ([pscustomobject]@{
                    path         = $f
                    originalArgs = $orig
                    patchedArgs  = $current
                    adopted      = $true
                })
                SayNote "already enabled, adopted for -Undo: $f"
            }
            continue
        }
        $before = [string]$sc.Arguments
        $sc.Arguments = ("$before $Script:Switch").Trim()
        try {
            $sc.Save()
        } catch {
            SayWarn "cannot write: $f ($($_.Exception.Message))"
            continue
        }
        $after = $null
        try { $after = [string](New-Object -ComObject WScript.Shell).CreateShortcut($f).Arguments } catch { $after = $null }
        if (-not $after -or $after -notlike "*$Script:Feature*") {
            SayWarn "not updated (access denied?): $f"
            continue
        }
        Copy-ShortcutBackup -Path $f
        Add-ManifestEntry -Kind 'shortcuts' -Entry ([pscustomobject]@{
            path         = $f
            originalArgs = $before
            patchedArgs  = $after
        })
        SayOk "shortcut: $f"
        $patched++
    }
    return $patched
}

function Invoke-ProtocolPatch {
    $classes = @('microsoft-edge', 'MSEdgeHTM', 'MSEdgeDHTML', 'MSEdgePDF', 'MSEdgeMHT', 'MicrosoftEdgeHTM')
    $patched = 0
    foreach ($c in $classes) {
        $src = "Registry::HKEY_CLASSES_ROOT\$c\shell\open\command"
        if (-not (Test-Path $src)) { continue }
        $old = [string](Get-Item $src).GetValue('')
        if ($old -notmatch 'msedge\.exe') { continue }
        if ($old -like "*$Script:Feature*") {
            $dstExisting = "HKCU:\Software\Classes\$c\shell\open\command"
            if ((Test-Path $dstExisting) -and -not (Test-ManifestEntry -Kind 'protocolHandlers' -Property 'key' -Value $dstExisting)) {
                Add-ManifestEntry -Kind 'protocolHandlers' -Entry ([pscustomobject]@{
                    key       = $dstExisting
                    className = $c
                    previous  = $null     # our own override -> remove it on -Undo
                    patched   = $old
                    adopted   = $true
                })
                SayNote "already enabled, adopted for -Undo: $c"
            } else {
                SayNote "already enabled: $c"
            }
            continue
        }
        $new = $old
        if ($old -match '^(?<exe>"[^"]+"|\S+)(?<rest>.*)$') {
            $new = $Matches['exe'] + ' ' + $Script:Switch + $Matches['rest']
        }
        $dst = "HKCU:\Software\Classes\$c\shell\open\command"
        $prev = $null
        if (Test-Path $dst) { $prev = [string](Get-Item $dst).GetValue('') }
        try {
            New-Item -Path $dst -Force | Out-Null
            Set-Item -Path $dst -Value $new
        } catch {
            SayWarn "cannot patch protocol handler $c ($($_.Exception.Message))"
            continue
        }
        if ($Script:BackupDir) {
            New-Item -ItemType Directory -Force -Path $Script:BackupDir | Out-Null
            & reg.exe export "HKEY_CLASSES_ROOT\$c" (Join-Path $Script:BackupDir "hkcr_$c.reg") /y 2>$null | Out-Null
        }
        Add-ManifestEntry -Kind 'protocolHandlers' -Entry ([pscustomobject]@{
            key        = $dst
            className  = $c
            previous   = $prev
            patched    = $new
        })
        SayOk "protocol handler: $c"
        $patched++
    }
    return $patched
}

function Invoke-PolicyPatch {
    param([string]$Scope)
    if ($Scope -eq 'Machine') { $root = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
    else { $root = 'HKCU:\Software\Policies\Microsoft\Edge' }
    $patched = 0
    try {
        New-Item -Path $root -Force -ErrorAction Stop | Out-Null
    } catch {
        SayWarn "cannot write $root ($($_.Exception.Message))"
        if ($Scope -eq 'User') { SayNote 'the policy is set machine-wide (HKLM) by the elevated pass instead' }
        return 0
    }
    foreach ($name in $Script:PolicyNames) {
        $prev = $null
        try { $prev = (Get-ItemProperty -Path $root -Name $name -ErrorAction Stop).$name } catch { $prev = $null }
        try {
            New-ItemProperty -Path $root -Name $name -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        } catch {
            SayWarn "cannot set $name in $root ($($_.Exception.Message))"
            continue
        }
        $check = $null
        try { $check = (Get-ItemProperty -Path $root -Name $name -ErrorAction Stop).$name } catch { $check = $null }
        if ($null -eq $check -or [int]$check -ne 0) { SayWarn "policy $name was not applied ($root)"; continue }

        if ($null -eq $prev -or [int]$prev -ne 0) {
            # value changed (or did not exist): remember the previous state for -Undo
            Add-ManifestEntry -Kind 'policies' -Entry ([pscustomobject]@{ root = $root; name = $name; previous = $prev })
            SayOk "policy: $name = 0 ($root)"
            $patched++
        } else {
            $known = $false
            $man = Get-ManifestData
            if ($man) {
                foreach ($e in @($man.policies)) {
                    if ($e -and ([string]$e.root) -eq $root -and ([string]$e.name) -eq $name) { $known = $true }
                }
            }
            if ($known) { SayNote "already set: $name = 0 ($root)" }
            else {
                Add-ManifestEntry -Kind 'policies' -Entry ([pscustomobject]@{ root = $root; name = $name; previous = $null; adopted = $true })
                SayNote "already set, adopted for -Undo: $name ($root)"
            }
        }
    }
    return $patched
}

# -------------------------------------------------------------------- undo --

function Remove-EmptyClassKey {
    param([string]$ClassName)
    $k = "HKCU:\Software\Classes\$ClassName"
    if (-not (Test-Path $k)) { return }
    try {
        $item = Get-Item $k
        if ($item.SubKeyCount -eq 0 -and $item.ValueCount -le 1) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Invoke-ShortcutUndo {
    param([string]$Scope)
    $m = Get-ManifestData
    if (-not $m) { return 0 }
    $sh = New-Object -ComObject WScript.Shell
    $restored = 0
    foreach ($s in @($m.shortcuts)) {
        if (-not $s -or -not $s.path) { continue }
        # machine paths only when running the machine pass
        $isMachine = ($s.path -like "$env:ProgramData*")
        if ($Scope -eq 'Machine' -and -not $isMachine) { continue }
        if ($Scope -eq 'User' -and $isMachine) { continue }
        if (-not (Test-Path $s.path)) { SayWarn "missing: $($s.path)"; continue }
        try {
            $sc = $sh.CreateShortcut($s.path)
            $sc.Arguments = [string]$s.originalArgs
            $sc.Save()
            $now = [string](New-Object -ComObject WScript.Shell).CreateShortcut($s.path).Arguments
            if ($now -eq [string]$s.originalArgs) { SayOk "restored shortcut: $($s.path)"; $restored++ }
            else { SayWarn "shortcut not restored (access denied?): $($s.path)" }
        } catch { SayWarn "cannot restore $($s.path) ($($_.Exception.Message))" }
    }
    return $restored
}

function Invoke-ProtocolUndo {
    $m = Get-ManifestData
    if (-not $m) { return 0 }
    $restored = 0
    foreach ($p in @($m.protocolHandlers)) {
        if (-not $p -or -not $p.key) { continue }
        if ($p.previous) {
            try {
                Set-Item -Path $p.key -Value ([string]$p.previous) -ErrorAction Stop
                $now = [string](Get-Item $p.key).GetValue('')
                if ($now -eq [string]$p.previous) { SayOk "restored handler: $($p.className)"; $restored++ }
                else { SayWarn "handler not restored: $($p.className)" }
            } catch { SayWarn "cannot restore $($p.className) ($($_.Exception.Message))" }
        } else {
            try {
                if (Test-Path $p.key) { Remove-Item -Path $p.key -Recurse -Force -ErrorAction SilentlyContinue }
                Remove-EmptyClassKey -ClassName $p.className
                if (-not (Test-Path $p.key)) { SayOk "removed handler override: $($p.className)"; $restored++ }
                else { SayWarn "handler override still present: $($p.className)" }
            } catch { SayWarn "cannot remove $($p.className)" }
        }
    }
    return $restored
}

function Invoke-PolicyUndo {
    param([string]$Scope)
    $m = Get-ManifestData
    if (-not $m) { return 0 }
    $restored = 0
    foreach ($p in @($m.policies)) {
        if (-not $p -or -not $p.root) { continue }
        $isMachine = ($p.root -like 'HKLM:*')
        if ($Scope -eq 'Machine' -and -not $isMachine) { continue }
        if ($Scope -eq 'User' -and $isMachine) { continue }
        try {
            if ($null -ne $p.previous) {
                New-ItemProperty -Path $p.root -Name $p.name -Value ([int]$p.previous) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                $now = $null
                try { $now = (Get-ItemProperty -Path $p.root -Name $p.name -ErrorAction Stop).$p.name } catch { $now = $null }
                if ($null -ne $now -and [int]$now -eq [int]$p.previous) { SayOk "restored policy: $($p.name) = $($p.previous)"; $restored++ }
                else { SayWarn "policy not restored: $($p.name)" }
            } else {
                Remove-ItemProperty -Path $p.root -Name $p.name -Force -ErrorAction SilentlyContinue
                $still = $null
                try { $still = (Get-ItemProperty -Path $p.root -Name $p.name -ErrorAction Stop).$p.name } catch { $still = $null }
                if ($null -eq $still) { SayOk "removed policy: $($p.name) ($($p.root))"; $restored++ }
                else { SayWarn "policy is still set: $($p.name) ($($p.root))" }
            }
        } catch { SayWarn "cannot revert policy $($p.name) ($($_.Exception.Message))" }
    }
    return $restored
}

# -------------------------------------------------------------------- test --

function Invoke-FlagTest {
    $exe = Get-EdgeExe
    if (-not $exe) { SayErr 'Microsoft Edge not found.'; return 2 }
    Say "Edge: $exe"
    $tmp = Join-Path $env:TEMP 'EdgeNoRoundedFrameTest'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    $probe = Join-Path $tmp 'probe.html'
    $html = @'
<!doctype html><html><head><meta charset="utf-8"><title>PROBE</title>
<style>html,body{margin:0;height:100%;background:#ff0000}</style></head><body>
<script>
function r(){document.title='M|i='+window.innerWidth+'x'+window.innerHeight+'|o='+window.outerWidth+'x'+window.outerHeight;}
window.addEventListener('load',r);setInterval(r,500);r();
</script></body></html>
'@
    Set-Content -Path $probe -Encoding ASCII -Value $html
    $probeUrl = ([uri]$probe).AbsoluteUri
    $port = 9333

    function Read-Sample {
        param([int]$Port)
        try { $list = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 3 } catch { return $null }
        if (-not $list) { return $null }
        $t = $list | Where-Object { $_.url -like '*probe.html*' -and $_.title -like 'M|*' } | Select-Object -First 1
        if ($t) { return [string]$t.title }
        return $null
    }

    $results = [ordered]@{}
    foreach ($phase in @(
            @{ name = 'without switch'; useSwitch = $false },
            @{ name = 'with switch';    useSwitch = $true })) {
        $prof = Join-Path $tmp ('prof-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $ea = @("--user-data-dir=$prof", "--remote-debugging-port=$port", '--no-first-run',
            '--no-default-browser-check', '--disable-sync', '--window-size=1100,760',
            '--window-position=60,60')
        if ($phase.useSwitch) { $ea += $Script:Switch }
        $ea += $probeUrl
        $proc = Start-Process -FilePath $exe -ArgumentList $ea -PassThru -ErrorAction SilentlyContinue
        $sample = $null
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline -and -not $sample) {
            Start-Sleep -Milliseconds 700
            $sample = Read-Sample -Port $port
        }
        if ($sample) { Start-Sleep -Milliseconds 1200; $sample2 = Read-Sample -Port $port; if ($sample2) { $sample = $sample2 } }
        $results[$phase.name] = $sample

        $mine = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$prof*" })
        foreach ($m in $mine) { Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue }
        if ($mine.Count -eq 0 -and $proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }

    function Convert-Sample {
        param([string]$s)
        if ($s -match 'i=(\d+)x(\d+)\|o=(\d+)x(\d+)') {
            return [pscustomobject]@{ iw = [int]$Matches[1]; ih = [int]$Matches[2]; ow = [int]$Matches[3]; oh = [int]$Matches[4] }
        }
        return $null
    }

    Say ''
    $parsed = [ordered]@{}
    foreach ($k in $results.Keys) {
        $parsed[$k] = Convert-Sample -s $results[$k]
        if ($parsed[$k]) { Say ("  {0,-15} content {1}x{2}  window {3}x{4}" -f $k, $parsed[$k].iw, $parsed[$k].ih, $parsed[$k].ow, $parsed[$k].oh) }
        else { Say ("  {0,-15} no measurement (Edge did not start?)" -f $k) }
    }
    $keys = @($parsed.Keys)
    if ($keys.Count -eq 2 -and $parsed[$keys[0]] -and $parsed[$keys[1]]) {
        $dw = $parsed[$keys[1]].iw - $parsed[$keys[0]].iw
        $dh = $parsed[$keys[1]].ih - $parsed[$keys[0]].ih
        Say ''
        Say ("  delta: {0:+0;-0;0} x {1:+0;-0;0} px" -f $dw, $dh)
        if ($dw -gt 0 -or $dh -gt 0) { SayOk "the switch works on this build ($Script:Feature)" }
        else { SayWarn 'no geometry change - the feature may have been removed in this build' }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return 0
}

# -------------------------------------------------------------------- main --

function Get-PolicyValue {
    param([string]$Root, [string]$Name)
    try { return (Get-ItemProperty -Path $Root -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Show-SystemSettingsHint {
    $found = @()
    foreach ($root in @('HKCU:\Software\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge')) {
        foreach ($name in $Script:PolicyNames) {
            $v = Get-PolicyValue -Root $root -Name $name
            if ($null -ne $v) { $found += "$name = $v in $root" }
        }
    }
    Say ''
    Say 'Startup boost / background mode'
    foreach ($f in $found) {
        SayWarn "policy is set: $f"
        SayWarn 'Edge will report itself as "managed by your organization" and lock that switch.'
    }
    SayNote 'A running Edge ignores the switch, and "Startup boost" pre-launches Edge at sign-in without'
    SayNote 'it - so both switches should be off. Edge 154 keeps them in an encrypted preference store,'
    SayNote 'which means they cannot be set safely from a script. Flip them once by hand:'
    SayNote '    edge://settings/system  ->  Startup boost = off'
    SayNote '                            ->  "Continue running background extensions and apps when Microsoft Edge is closed" = off'
    SayNote 'No policy is written by default, so Edge will not call itself managed.'
}

function Invoke-Patch {
    param([string]$Scope)
    Say "[$Scope scope]"
    $null = Invoke-ShortcutPatch -Scope $Scope
    if ($Scope -eq 'User' -and -not $SkipProtocolHandlers) { $null = Invoke-ProtocolPatch }
    if ($UsePolicies -and -not $SkipPolicies) { $null = Invoke-PolicyPatch -Scope $Scope }
}

function Invoke-Undo {
    param([string]$Scope)
    Say "[$Scope scope]"
    $null = Invoke-ShortcutUndo -Scope $Scope
    if ($Scope -eq 'User') { $null = Invoke-ProtocolUndo }
    $null = Invoke-PolicyUndo -Scope $Scope
}

$isAdmin = Test-Admin

if ($Test) {
    exit (Invoke-FlagTest)
}

if ($MachineOnly) {
    if ($Undo) { Invoke-Undo -Scope 'Machine' } else { Invoke-Patch -Scope 'Machine' }
    exit 0
}

$needsMachine = $false
if ($Undo) {
    if (-not (Test-Path $Script:Manifest)) {
        SayWarn "nothing to revert: no manifest at $Script:Manifest"
        exit 1
    }
    $m0 = Get-ManifestData
    if ($m0) {
        foreach ($s in @($m0.shortcuts)) { if ($s -and ([string]$s.path) -like "$env:ProgramData*") { $needsMachine = $true } }
        foreach ($pol in @($m0.policies)) { if ($pol -and ([string]$pol.root) -like 'HKLM:*') { $needsMachine = $true } }
    }
}

Say ''
if ($Undo) { Say 'Edge no-rounded-frame: UNDO' } else { Say 'Edge no-rounded-frame: apply' }
Say "feature switch: $Script:Switch"
Say "backup folder : $Script:BackupDir"
Say ''

$machineHandled = $isAdmin -or (-not $needsMachine)

if ($Undo) {
    Invoke-Undo -Scope 'User'
    if ($isAdmin) { Invoke-Undo -Scope 'Machine' }
} else {
    Invoke-Patch -Scope 'User'
    if ($isAdmin) { Invoke-Patch -Scope 'Machine' }
}

if (-not $isAdmin -and -not $NoElevate) {
    Say ''
    Say 'Asking for administrator rights (machine-wide Start Menu shortcut + HKLM policies)...'
    $ps = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-MachineOnly', '-BackupDir', "`"$Script:BackupDir`"")
    if ($Undo) { $argList += '-Undo' }
    if ($SkipPolicies) { $argList += '-SkipPolicies' }
    if ($UsePolicies) { $argList += '-UsePolicies' }
    try {
        $elevated = Start-Process -FilePath $ps -ArgumentList $argList -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if (-not $elevated -or $null -eq $elevated.ExitCode -or $elevated.ExitCode -eq 0) { $machineHandled = $true }
        else { SayWarn "the elevated pass exited with code $($elevated.ExitCode)" }
    } catch {
        SayWarn "elevation declined - machine-wide Start Menu shortcut and HKLM policies were skipped."
    }
} elseif (-not $isAdmin) {
    SayNote 'not elevated: machine-wide Start Menu shortcut and HKLM policies skipped (-NoElevate)'
}

Say ''
if ($Undo) {
    if ($machineHandled) {
        Remove-Item $Script:Manifest -Force -ErrorAction SilentlyContinue
        Say 'Undo finished; backup manifest removed.'
    } else {
        SayWarn 'machine-wide entries were not reverted (administrator rights are required); manifest kept.'
        SayWarn "Run -Undo again from an elevated PowerShell to finish: $Script:Manifest"
    }
} else {
    $running = @(Get-Process msedge -ErrorAction SilentlyContinue).Count
    if ($running -gt 0) {
        SayWarn "Edge is running ($running processes). Close it completely and start it again from a normal shortcut,"
        SayWarn 'otherwise the already running process keeps the frame.'
    }
    Show-SystemSettingsHint
    Say ''
    Say 'Done. Verify with:  .\EdgeNoRoundedFrame.ps1 -Test'
    Say 'Revert with:        .\EdgeNoRoundedFrame.ps1 -Undo'
}
exit 0
