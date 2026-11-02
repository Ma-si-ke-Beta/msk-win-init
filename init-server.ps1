<#
  init-server.ps1 - One-shot setup for a fresh Windows Server (2019+)
    1. OpenSSH Server (install, start, auto-start, firewall)
    2. Passwordless login for Administrators (public key)
    3. PowerShell 7 (latest stable) + set as SSH default shell
    4. Google Chrome (enterprise MSI)

  Run in an elevated PowerShell (Windows PowerShell 5.1 is fine):
    Set-ExecutionPolicy Bypass -Scope Process -Force; .\init-server.ps1

  Safe to re-run: every step is skipped if already done.
  Output is English on purpose (avoids encoding issues on PowerShell 5.1).
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ===== Config =====
$PublicKeys = @(
  'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDUMjqSibk+7DW33xX2oioEfKOI6lJj190sQlddlPkeD1a8nzcelRWJFOUm1spOsDK2kQVFbiiiZNIq00zlhFWQZx44CQg0ao53llnPqU08gH3Dbz8TzYqkJmo3VzEtgeqv7AxMlEzhl0o/bczAvVx7cwNLk04A85Oz7+QSxaT+aD19xwWhrZvoYmcmRknnXHkc6AHwkOpfEo1UbeMv8DC6qiZNcNQaUQ81IaI8dAVqa82qNg/reUcu7DQWXM9K8UNMWRe/1Nhzv+luevkFPsQSkeCzK0x3QFbmoP9cQfS1RzF/AF1Yoz+DEKCxaBoZ9dWc79IQTHeWPifHImsh55WkK0qT5PgWfF9D8Cqy+3ANPTUVsa7jGzyBnuZD9VMgPmn+6+KUYXW9Uor4mOQcngPjIyAXeu/I1crSObvv/E9l9FNJEkBWqQcbooF1Vt/+jaMYjdEcyFJuatM3Gp77YU5ijJ+VxvitqZYz+uyQq9yyfCq3a2CecXcwJjlH0eXrhls= Administrator@USER-20251007RU'
)
$InstallPwsh  = $true
$InstallChrome = $true
# ==================

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Skip($msg) { Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray }

function Install-SignedMsi([string]$Url, [string]$SignerPattern, [string]$ExtraArgs = '') {
  $f = Join-Path $env:TEMP ([IO.Path]::GetFileName(([Uri]$Url).AbsolutePath))
  Invoke-WebRequest $Url -OutFile $f -UseBasicParsing
  try {
    $sig = Get-AuthenticodeSignature $f
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerPattern) {
      throw "Signature check failed for $f ($($sig.Status) / $($sig.SignerCertificate.Subject))"
    }
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$f`" /qn /norestart $ExtraArgs" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec failed with exit code $($p.ExitCode)" }
  } finally { Remove-Item $f -ErrorAction SilentlyContinue }
}

function Get-LatestGitHubAsset([string]$Repo, [string]$NamePattern) {
  $r = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
  $a = $r.assets | Where-Object name -like $NamePattern | Select-Object -First 1
  if (-not $a) { throw "No asset matching '$NamePattern' in $Repo $($r.tag_name)" }
  [pscustomobject]@{ Tag = $r.tag_name; Url = $a.browser_download_url }
}

# --- Admin check ---
$id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Please run this script in an elevated (Administrator) PowerShell.'
}

$sshdChanged = $false

# --- 1. OpenSSH Server ---
Step 'OpenSSH Server'
if (Get-Service sshd -ErrorAction SilentlyContinue) {
  Skip 'sshd already installed'
} else {
  try {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Ok 'Installed via Windows capability'
  } catch {
    Write-Host "    Windows capability failed ($($_.Exception.Message)), falling back to GitHub MSI..." -ForegroundColor Yellow
    $asset = Get-LatestGitHubAsset 'PowerShell/Win32-OpenSSH' '*Win64*.msi'
    Install-SignedMsi $asset.Url 'O=Microsoft Corporation'
    Ok "Installed Win32-OpenSSH $($asset.Tag)"
  }
  $sshdChanged = $true
}
Set-Service sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd; Ok 'sshd started' } else { Skip 'sshd already running' }

if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
  Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
  Skip 'Firewall rule exists (ensured enabled)'
} else {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
    -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
  Ok 'Firewall rule for TCP 22 created'
}

# --- 2. Public keys for Administrators ---
Step 'Public keys (administrators_authorized_keys)'
$akf = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
New-Item -ItemType Directory -Force -Path (Split-Path $akf) | Out-Null
# Parse existing keys robustly (handles keys glued on one line / missing trailing newline),
# dedupe by "type base64", then rewrite the file cleanly: one key per line.
$keyRegex = '(ssh-(?:rsa|ed25519|dss)|ecdsa-sha2-nistp\d+|sk-[a-z0-9@.-]+)\s+([A-Za-z0-9+/=]+)'
function Get-KeyId([string]$line) { if ($line -match $keyRegex) { "$($Matches[1]) $($Matches[2])" } }
$oldRaw  = if (Test-Path $akf) { [IO.File]::ReadAllText($akf) } else { '' }
$oldKeys = [regex]::Matches($oldRaw, "$keyRegex(?:[ \t]+(?:(?!ssh-|ecdsa-|sk-)\S)+)?") | ForEach-Object { $_.Value.Trim() }
$final = [ordered]@{}
foreach ($k in @($oldKeys) + $PublicKeys) { $id = Get-KeyId $k; if ($id -and -not $final.Contains($id)) { $final[$id] = $k } }
$newRaw = ($final.Values -join "`r`n") + "`r`n"
if ($newRaw -ne $oldRaw) {
  [IO.File]::WriteAllText($akf, $newRaw, [Text.Encoding]::ASCII)
  Ok "Key file normalized: $($final.Count) unique key(s)"
} else { Skip "All keys already present ($($final.Count) key(s))" }
icacls.exe $akf /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

# --- 3. PowerShell 7 ---
$pwshExe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if ($InstallPwsh) {
  Step 'PowerShell 7'
  if (Test-Path $pwshExe) {
    Skip "Already installed: $((Get-Item $pwshExe).VersionInfo.FileVersion)"
  } else {
    $asset = Get-LatestGitHubAsset 'PowerShell/PowerShell' '*win-x64.msi'
    Install-SignedMsi $asset.Url 'O=Microsoft Corporation' 'ADD_PATH=1 REGISTER_MANIFEST=1'
    Ok "Installed PowerShell $($asset.Tag)"
  }
}

# --- SSH default shell ---
Step 'SSH default shell'
$shell = if (Test-Path $pwshExe) { 'C:\PROGRA~1\PowerShell\7\pwsh.exe' } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
# NOTE: never use New-Item -Force on an existing registry key - it wipes the key's values and subkeys.
if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' | Out-Null }
$cur = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue).DefaultShell
if ($cur -eq $shell) { Skip "Already $shell" } else {
  Set-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell
  Ok "DefaultShell = $shell"
}

# --- 4. Chrome ---
if ($InstallChrome) {
  Step 'Google Chrome'
  $chromeExe = Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
  if (Test-Path $chromeExe) {
    Skip "Already installed: $((Get-Item $chromeExe).VersionInfo.ProductVersion)"
  } else {
    Install-SignedMsi 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' 'O=Google LLC'
    Ok "Installed Chrome $((Get-Item $chromeExe).VersionInfo.ProductVersion)"
  }
}

if ($sshdChanged) { Restart-Service sshd; Ok 'sshd restarted' }

Write-Host "`nAll done. Test from your PC:  ssh Administrator@<server-ip>" -ForegroundColor Green
