# Fix Git: correct directory structure (root = install.sh, core/, config/...) and UTF-8 commit message
# Run in PowerShell: cd to the folder that contains install.sh and this script, then: .\fix-git-structure.ps1

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot
Set-Location $repoRoot

# Remove wrong path from index (if any)
git rm -r --cached Xray-script-main 2>$null

# Add all files from CURRENT directory = repo root (install.sh, core/, config/ at root)
git add -A

# Commit: use COMMIT_MSG.txt (UTF-8) to avoid garbled Chinese
if (Test-Path "COMMIT_MSG.txt") { git commit -F "COMMIT_MSG.txt" } else { git commit -m "feat: VLESS enc, SNI self cert, GitHub proxy, haiyan1301/Xray-script" }

Write-Host "Done. Root should have: install.sh, core/, config/. Push: git push -u origin main"
