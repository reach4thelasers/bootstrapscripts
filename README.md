# bootstrapscripts

Scripts that get a fresh machine ready for use. Each runs straight from its URL.

| Script | What it does | Run it |
|---|---|---|
| [`setup.ps1`](setup.ps1) | Gets a Windows 11 PC to the point where its set-up kit can run, then runs the kit. It asks for the set-up source (a folder or a network share) and the kit branch first, installs Git when missing, connects to the source, clones the kit from the source's bundle and runs the kit's set-up script, which shows its menu of modules. Run it from an elevated Windows PowerShell 5.1. | `irm https://raw.githubusercontent.com/reach4thelasers/bootstrapscripts/main/setup.ps1 \| iex` |
| [`throwaway.ps1`](throwaway.ps1) | Runs `setup.ps1` with the `TemporaryDev` preset, for a throwaway PC. It only fetches `setup.ps1` and hands it the preset, so the address published for it keeps working. Run it from an elevated Windows PowerShell 5.1. | `irm https://raw.githubusercontent.com/reach4thelasers/bootstrapscripts/main/throwaway.ps1 \| iex` |
