<#
.SYNOPSIS
    Gets a Windows 11 PC to the point where its set-up kit can run, then runs the kit.

.DESCRIPTION
    Run it once, in an elevated Windows PowerShell 5.1:

        irm https://raw.githubusercontent.com/reach4thelasers/bootstrapscripts/main/setup.ps1 | iex

    It asks its questions first, so you can walk away once they are answered. Then, in order, it:
      1. stops when the window is not elevated, and sets TLS 1.2;
      2. asks for the set-up source, unless it was given as a parameter;
      3. installs Git with winget, when missing, and reloads PATH from the registry;
      4. connects to the set-up source, takes the kit branch from the source's bundle (which holds
         one branch), clones the kit from the bundle to $HOME\dev\Toolkit (or brings an existing
         clone up to date), and prints the source's published.txt, so you can see how fresh the
         kit is;
      5. runs the kit's pc-setup\Setup.ps1, which shows its menu of modules unless -Preset or
         -Modules is given.

    The kit is not on the PC until step 4, so this script copies the connection rules the kit uses
    for a set-up source. It stops at the first failure and names the step. Every step tests whether
    it is already done, so a failed run can be repeated, and so can a run to update the kit.

    To skip the questions, give the values as parameters:

        & ([scriptblock]::Create((irm <url>))) -Source <path> -Preset Developer

.PARAMETER Source
    The set-up source: a folder, or a share path of the form \\server\share. Asked for when not
    given. Required. A share that cannot be reached yet is connected with a user name and password
    that are asked for; the connection lasts until sign-out and nothing saves the password.

.PARAMETER Branch
    An override for the kit branch. Not asked for. By default the branch is the one the set-up
    source's bundle holds; the script stops when the bundle holds none or several. When given, the
    bundle must hold this branch. An existing clone is switched to the branch, then fast-forwarded.

.PARAMETER Preset
    A ready-made combination of modules, passed to the kit's Setup.ps1. Without -Preset and
    -Modules, the kit shows its menu.

.PARAMETER Modules
    The modules to run, passed to the kit's Setup.ps1. Added to the preset's modules when both are
    given.
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Branch,
    [string]$Preset,
    [string[]]$Modules
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$kitDir = Join-Path $HOME 'dev\Toolkit'
$setupScript = Join-Path $kitDir 'pc-setup\Setup.ps1'
$wingetOk = @(0, -1978335135, -1978334963)   # installed, or already installed (winget returnCodes.md)
$script:StepName = 'start'

function Start-Step {
    param([string]$Name)
    $script:StepName = $Name
    Write-Host ''
    Write-Host ('== {0}' -f $Name)
}

function Update-SessionPath {
    # Rebuilds this window's PATH from the Machine and User registry values.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Tool {
    # Runs a native command and throws when its exit code is not allowed.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$Allowed = @(0)
    )
    & $FilePath @Arguments
    if ($Allowed -notcontains $LASTEXITCODE) {
        throw ('{0} {1} exited with code {2}.' -f $FilePath, ($Arguments -join ' '), $LASTEXITCODE)
    }
}

function Test-Tool {
    # True when a native command exits 0. Its output is discarded.
    param([string]$FilePath, [string[]]$Arguments = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $saved
    }
}

function Get-ToolOutput {
    # The standard output lines of a native command, or nothing when it exits non-zero.
    param([string]$FilePath, [string[]]$Arguments = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $FilePath @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($lines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    finally {
        $ErrorActionPreference = $saved
    }
}

function Read-Answer {
    # Asks until the answer is acceptable. A blank answer returns $Default when one is given,
    # or '' when $AllowBlank is set. $Pattern, when given, is a case-sensitive regex the answer must match.
    param(
        [string]$Prompt,
        [string]$Default,
        [switch]$AllowBlank,
        [string]$Pattern,
        [string]$PatternHelp
    )
    while ($true) {
        $answer = (Read-Host $Prompt).Trim().Trim('"').Trim()
        if (-not $answer) {
            if ($Default) { return $Default }
            if ($AllowBlank) { return '' }
            Write-Host 'An answer is required.'
            continue
        }
        if ($Pattern -and ($answer -cnotmatch $Pattern)) {
            Write-Host $PatternHelp
            continue
        }
        return $answer
    }
}

function Resolve-KitBranch {
    # The kit branch: the one branch the bundle holds, or $Requested when the bundle holds it.
    # Throws when the bundle holds no branch or several, or does not hold $Requested.
    param([string]$Bundle, [string]$Requested)

    $heads = @(Get-ToolOutput -FilePath 'git' -Arguments @('bundle', 'list-heads', $Bundle))
    if ($heads.Count -eq 0) {
        throw ('{0} is not a readable git bundle.' -f $Bundle)
    }
    $names = @($heads | ForEach-Object {
            if ($_ -match '^[0-9a-f]{40,64}\s+refs/heads/(.+)$') { $Matches[1] }
        })
    if ($Requested) {
        if ($names -cnotcontains $Requested) {
            throw ('The kit bundle does not hold branch "{0}". It holds: {1}' -f $Requested, ($heads -join '; '))
        }
        return $Requested
    }
    if ($names.Count -ne 1) {
        throw ('The kit bundle must hold exactly one branch (publish one branch). It holds {0}: {1}' -f $names.Count, ($heads -join '; '))
    }
    return $names[0]
}

function Connect-Source {
    # Makes the set-up source reachable, or throws naming its path. A local path must exist. A share
    # path that does not hold the kit's bundle yet is connected with net use, which asks for the
    # password. The connection lasts until sign-out; nothing saves the password.
    param([string]$Path)

    if ($Path -notmatch '^\\\\') {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw ('The set-up source does not exist: {0}' -f $Path) }
        return
    }
    $bundle = Join-Path $Path 'kit\toolkit.bundle'
    if (Test-Path -LiteralPath $bundle) { return }
    if ($Path -notmatch '^\\\\([^\\]+)\\([^\\]+)') {
        throw ('The set-up source is not a share path (\\server\share): {0}' -f $Path)
    }
    $server = $Matches[1]
    $share = $Matches[2]
    $user = (Read-Host ('User name for {0}' -f $server)).Trim().Trim('"').Trim("'")
    if (-not $user) { throw ('No user name given: the set-up source is not reachable: {0}' -f $Path) }
    $global:LASTEXITCODE = 0
    # Called directly, so the password prompt reaches the console. A failed attempt is not fatal
    # here: the test below decides.
    & net use ('\\' + $server + '\' + $share) ('/user:' + $user) '*' '/persistent:no'
    if ($LASTEXITCODE -ne 0) { Write-Host ('net use exited with code {0}' -f $LASTEXITCODE) }
    if (-not (Test-Path -LiteralPath $bundle)) { throw ('The set-up source is not reachable: {0}' -f $Path) }
}

try {
    # ---- Step 1: refuse where it must not run --------------------------------------------------
    Start-Step 'Step 1: check the window is elevated'
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run from an elevated Windows PowerShell.'
    }
    # Windows PowerShell 5.1 can default to old TLS versions, which some installers refuse.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host 'ok'

    # ---- Step 2: ask ---------------------------------------------------------------------------
    Start-Step 'Step 2: ask for the set-up source'
    Write-Host 'Questions first, so you can walk away once they are answered.'
    Update-SessionPath
    if ($Source) { $Source = $Source.Trim().Trim('"').Trim("'").Trim() }
    if (-not $Source) {
        $Source = Read-Answer -Prompt 'Set-up source (a folder, or \\server\share)'
    }

    # ---- Step 3: Git ---------------------------------------------------------------------------
    Start-Step 'Step 3: install Git'
    if (Test-Command 'git') {
        Write-Host '[skip] Git.Git is installed'
    }
    else {
        if (-not (Test-Command 'winget')) {
            throw 'winget is missing. Update App Installer from the Microsoft Store, then run this script again.'
        }
        Write-Host 'Installing Git.Git'
        # --source winget keeps the msstore source out of it: on a fresh image it can fail with a
        # pinned-certificate mismatch.
        Invoke-Tool -FilePath 'winget' -Allowed $wingetOk -Arguments @(
            'install', '--id', 'Git.Git', '--exact', '--source', 'winget', '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        Update-SessionPath
        if (-not (Test-Command 'git')) {
            throw 'Git.Git was installed, but "git" is still not found on PATH.'
        }
        Write-Host '[done] Git.Git'
    }

    # ---- Step 4: the kit -----------------------------------------------------------------------
    Start-Step 'Step 4: connect to the set-up source and clone or update the kit'
    Connect-Source -Path $Source
    $bundle = Join-Path $Source 'kit\toolkit.bundle'
    if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) {
        throw ('The set-up source holds no kit bundle: {0}' -f $bundle)
    }
    $kitSource = if ($Branch) { 'given as -Branch' } else { 'from the set-up source' }
    $Branch = Resolve-KitBranch -Bundle $bundle -Requested $Branch
    $published = Join-Path $Source 'kit\published.txt'
    Write-Host ''
    Write-Host ('Kit branch: {0} ({1})' -f $Branch, $kitSource)
    Write-Host 'Published to the set-up source:'
    if (Test-Path -LiteralPath $published -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $published) {
            if ($line.Trim()) { Write-Host ('  {0}' -f $line.Trim()) }
        }
    }
    else {
        Write-Host '  (the source has no published.txt)'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $kitDir '.git'))) {
        Invoke-Tool -FilePath 'git' -Arguments @('clone', '-b', $Branch, $bundle, $kitDir)
        Write-Host ('[done] cloned to {0}' -f $kitDir)
    }
    else {
        # A clone made from GitHub keeps its origin; any other origin becomes the bundle.
        $origin = @(Get-ToolOutput -FilePath 'git' -Arguments @('-C', $kitDir, 'remote', 'get-url', 'origin'))
        if ($origin.Count -eq 0) {
            Invoke-Tool -FilePath 'git' -Arguments @('-C', $kitDir, 'remote', 'add', 'origin', $bundle)
        }
        elseif ($origin[0] -notmatch '^https://github\.com/') {
            Invoke-Tool -FilePath 'git' -Arguments @('-C', $kitDir, 'remote', 'set-url', 'origin', $bundle)
        }
        Invoke-Tool -FilePath 'git' -Arguments @('-C', $kitDir, 'fetch', 'origin')
        Invoke-Tool -FilePath 'git' -Arguments @('-C', $kitDir, 'switch', $Branch)
        Invoke-Tool -FilePath 'git' -Arguments @('-C', $kitDir, 'pull', '--ff-only')
        Write-Host ('[done] updated {0} on branch {1}' -f $kitDir, $Branch)
    }
    if (-not (Test-Path -LiteralPath $setupScript)) {
        throw ('{0} does not exist. Is branch "{1}" the right one?' -f $setupScript, $Branch)
    }

    # ---- Step 5: the kit's set-up script -------------------------------------------------------
    Start-Step 'Step 5: run the kit set-up script'
    # A fresh Windows 11 PC blocks scripts by default. This lasts for this window only.
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    $setupArguments = @{ Source = $Source }
    if ($Preset) { $setupArguments.Preset = $Preset }
    if ($Modules) { $setupArguments.Modules = $Modules }
    $global:LASTEXITCODE = 0
    & $setupScript @setupArguments
    if ($LASTEXITCODE -ne 0) {
        throw ('Setup.ps1 exited with code {0}. Its summary and log path are above.' -f $LASTEXITCODE)
    }
}
catch {
    Write-Host ''
    Write-Host ('FAILED at {0}' -f $script:StepName) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    # No exit: under iex it would close the window and hide the message above.
    $global:LASTEXITCODE = 1
    return
}
