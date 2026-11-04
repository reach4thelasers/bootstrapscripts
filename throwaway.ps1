<#
.SYNOPSIS
    Runs setup.ps1 with the TemporaryDev preset, for a throwaway PC.

.DESCRIPTION
    This is a wrapper, so the address that was published for the throwaway PC keeps working.
    Run it once, in an elevated Windows PowerShell 5.1:

        irm https://raw.githubusercontent.com/reach4thelasers/bootstrapscripts/main/throwaway.ps1 | iex

    It fetches setup.ps1 from the branch named by -StarterBranch and runs it with
    -Preset TemporaryDev. setup.ps1 asks its own questions.

    A script run by irm | iex cannot know the branch it came from, so the branch is a parameter.
    To use another branch, run the scriptblock form:

        & ([scriptblock]::Create((irm <url>))) -StarterBranch <branch>

.PARAMETER StarterBranch
    The branch of this repository to fetch setup.ps1 from. The default is main.
#>
[CmdletBinding()]
param(
    [string]$StarterBranch = 'main'
)

& ([scriptblock]::Create((Invoke-RestMethod "https://raw.githubusercontent.com/reach4thelasers/bootstrapscripts/$StarterBranch/setup.ps1"))) -Preset TemporaryDev
