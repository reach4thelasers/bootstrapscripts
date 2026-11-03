# bootstrapscripts

Scripts that get a fresh machine ready for use. Each runs straight from its URL.

| Script | What it does | Run it |
|---|---|---|
| [`throwaway.ps1`](throwaway.ps1) | Gets a fresh Windows 11 PC ready for a template repo's set-up script, then runs it. It asks its questions first, installs Git, the GitHub CLI and Claude Code, signs in to GitHub, clones the template repo and runs its set-up script. Run it from an elevated Windows PowerShell 5.1. | `irm https://raw.githubusercontent.com/reach4thelasers/bootstrapscripts/main/throwaway.ps1 \| iex` |
