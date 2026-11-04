<#
.SYNOPSIS
    Gets a fresh Windows 11 PC ready for the set-up script, then runs it.

.DESCRIPTION
    Run it once, in an elevated Windows PowerShell 5.1:

        irm https://raw.githubusercontent.com/reach4thelasers/bootstrapscripts/main/throwaway.ps1 | iex

    It asks its questions first, so you can walk away once they are answered. Then, in order, it:
      1. stops on a synced workstation, or when the window is not elevated, then asks for any
         value that was not given as a parameter;
      2. installs Git and the GitHub CLI with winget, when missing;
      3. installs Claude Code with its native installer, when missing;
      4. reloads PATH from the registry, so the new tools are found in this window;
      5. signs in to GitHub in the browser, when not signed in, and sets git to use that sign-in;
      6. clones the template repo to $HOME\dev\ClaudeProjectTemplate, or, for an existing
         clone, switches it to the answered branch and fast-forwards it;
      7. runs Setup-ThrowawayMachine.ps1 from that clone.

    It stops at the first failure and names the step. Every step tests whether it is already
    done, so a failed run can be repeated.

    To skip the questions, give the values as parameters:

        & ([scriptblock]::Create((irm <url>))) -Root D:\work -Workspace Example

.PARAMETER Branch
    The template repo branch to use. Asked for when not given; Enter accepts main. An existing
    clone is switched to this branch, then fast-forwarded.

.PARAMETER Root
    The workspace root, passed to Setup-ThrowawayMachine.ps1. Asked for when not given. Required.

.PARAMETER Workspace
    The workspace name, PascalCase (for example Example), passed to Setup-ThrowawayMachine.ps1.
    Asked for when not given. Required.

.PARAMETER GitName
    The git user name, passed to Setup-ThrowawayMachine.ps1. Asked for when not given. May be left
    blank only when git already has a global user name.

.PARAMETER GitEmail
    The git user email, passed to Setup-ThrowawayMachine.ps1. Asked for when not given. May be left
    blank only when git already has a global user email.
#>
[CmdletBinding()]
param(
    [string]$Branch,
    [string]$Root,
    [string]$Workspace,
    [string]$GitName,
    [string]$GitEmail
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$templateRepo = 'reach4thelasers/claude-project-template'
$templateDir = Join-Path $HOME 'dev\ClaudeProjectTemplate'
$claudeExe = Join-Path $HOME '.local\bin\claude.exe'
$setupScript = Join-Path $templateDir 'throwaway-machine\Setup-ThrowawayMachine.ps1'
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

function Get-GitGlobal {
    # The global git setting with this name, or '' when git is not installed or the setting is unset.
    param([string]$Key)
    if (-not (Test-Command 'git')) { return '' }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $value = & git config --global $Key 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $value) { return '' }
        return ([string]$value).Trim()
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

try {
    # ---- Step 1: refuse where it must not run, then ask -----------------------------------------
    Start-Step 'Step 1: check this is a throwaway machine and the window is elevated'
    if (Test-Path -LiteralPath (Join-Path $HOME '.claude\.stfolder')) {
        throw 'This is a synced workstation, not a throwaway machine. Nothing was changed.'
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run from an elevated Windows PowerShell.'
    }
    # Windows PowerShell 5.1 can default to old TLS versions, which the Claude installer refuses.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host 'ok'

    Write-Host ''
    Write-Host 'Questions first, so you can walk away once they are answered.'
    Update-SessionPath
    if (-not $Root) {
        $Root = Read-Answer -Prompt 'Root folder for the workspace'
    }
    if (-not $Workspace) {
        $Workspace = Read-Answer -Prompt 'Workspace name (PascalCase, for example Example)' `
            -Pattern '^[A-Z][A-Za-z0-9]+$' -PatternHelp 'Use PascalCase: a capital letter first, then letters and digits only.'
    }
    elseif ($Workspace -cnotmatch '^[A-Z][A-Za-z0-9]+$') {
        throw ('Workspace "{0}" is not PascalCase: a capital letter first, then letters and digits only.' -f $Workspace)
    }
    if (-not $GitName) {
        if (Get-GitGlobal 'user.name') {
            $GitName = Read-Answer -Prompt 'Git user name (Enter keeps the one git already has)' -AllowBlank
        }
        else {
            $GitName = Read-Answer -Prompt 'Git user name'
        }
    }
    if (-not $GitEmail) {
        if (Get-GitGlobal 'user.email') {
            $GitEmail = Read-Answer -Prompt 'Git user email (Enter keeps the one git already has)' -AllowBlank
        }
        else {
            $GitEmail = Read-Answer -Prompt 'Git user email'
        }
    }
    if (-not $Branch) {
        $Branch = Read-Answer -Prompt 'Template branch (Enter for main)' -Default 'main'
    }

    # ---- Step 2: Git and the GitHub CLI --------------------------------------------------------
    Start-Step 'Step 2: install Git and the GitHub CLI'
    Update-SessionPath
    $tools = @(
        @{ Id = 'Git.Git'; Command = 'git' },
        @{ Id = 'GitHub.cli'; Command = 'gh' }
    )
    foreach ($tool in $tools) {
        if (Test-Command $tool.Command) {
            Write-Host ('[skip] {0} is installed' -f $tool.Id)
            continue
        }
        if (-not (Test-Command 'winget')) {
            throw 'winget is missing. Update App Installer from the Microsoft Store, then run this script again.'
        }
        Write-Host ('Installing {0}' -f $tool.Id)
        # --source winget keeps the msstore source out of it: on a fresh image it can fail with a
        # pinned-certificate mismatch.
        Invoke-Tool -FilePath 'winget' -Allowed $wingetOk -Arguments @(
            'install', '--id', $tool.Id, '--exact', '--source', 'winget', '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        Update-SessionPath
        if (-not (Test-Command $tool.Command)) {
            throw ('{0} was installed, but "{1}" is still not found on PATH.' -f $tool.Id, $tool.Command)
        }
        Write-Host ('[done] {0}' -f $tool.Id)
    }

    # ---- Step 3: Claude Code -------------------------------------------------------------------
    Start-Step 'Step 3: install Claude Code'
    if (Test-Path -LiteralPath $claudeExe) {
        Write-Host '[skip] Claude Code is installed'
    }
    else {
        Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
        if (-not (Test-Path -LiteralPath $claudeExe)) {
            throw ('The Claude Code installer ran, but {0} does not exist.' -f $claudeExe)
        }
        Write-Host '[done] Claude Code'
    }

    # ---- Step 4: reload PATH -------------------------------------------------------------------
    Start-Step 'Step 4: reload PATH from the registry'
    Update-SessionPath
    foreach ($name in 'git', 'gh') {
        if (-not (Test-Command $name)) { throw ('"{0}" is not found on PATH.' -f $name) }
    }
    Write-Host 'ok'

    # ---- Step 5: GitHub sign-in ----------------------------------------------------------------
    Start-Step 'Step 5: sign in to GitHub'
    if (Test-Tool -FilePath 'gh' -Arguments @('auth', 'status')) {
        Write-Host '[skip] already signed in'
    }
    else {
        Write-Host 'A browser window opens. Follow the prompts, and sign in as the account that can read the template repo.'
        Invoke-Tool -FilePath 'gh' -Arguments @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web')
        Write-Host '[done] signed in'
    }
    Invoke-Tool -FilePath 'gh' -Arguments @('auth', 'setup-git')

    # ---- Step 6: the template repo -------------------------------------------------------------
    Start-Step 'Step 6: clone or update the template repo'
    if (-not (Test-Path -LiteralPath $templateDir)) {
        Invoke-Tool -FilePath 'gh' -Arguments @('repo', 'clone', $templateRepo, $templateDir, '--', '-b', $Branch)
        Write-Host ('[done] cloned to {0}' -f $templateDir)
    }
    else {
        Invoke-Tool -FilePath 'git' -Arguments @('-C', $templateDir, 'fetch', 'origin')
        Invoke-Tool -FilePath 'git' -Arguments @('-C', $templateDir, 'switch', $Branch)
        Invoke-Tool -FilePath 'git' -Arguments @('-C', $templateDir, 'pull', '--ff-only')
        Write-Host ('[done] updated {0} on branch {1}' -f $templateDir, $Branch)
    }
    if (-not (Test-Path -LiteralPath $setupScript)) {
        throw ('{0} does not exist. Is branch "{1}" the right one?' -f $setupScript, $Branch)
    }

    # ---- Step 7: the set-up script -------------------------------------------------------------
    Start-Step 'Step 7: run the set-up script'
    # A fresh Windows 11 PC blocks scripts by default. This lasts for this window only.
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    $setupArguments = @{ Root = $Root; Workspace = $Workspace }
    if ($GitName) { $setupArguments.GitName = $GitName }
    if ($GitEmail) { $setupArguments.GitEmail = $GitEmail }
    $global:LASTEXITCODE = 0
    & $setupScript @setupArguments
    if ($LASTEXITCODE -ne 0) {
        throw ('Setup-ThrowawayMachine.ps1 exited with code {0}. Its summary and log path are above.' -f $LASTEXITCODE)
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
