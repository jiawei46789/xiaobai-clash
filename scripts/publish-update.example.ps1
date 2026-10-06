# Example private-OTA script: build -> sign -> wireless install in one command.
# Copy to your local tools dir, fill in YOUR OWN paths, and keep the filled copy
# OUT of the repository (this example contains no credentials by design).
#
# Usage:
#   .\publish-update.ps1                # sign latest build output
#   .\publish-update.ps1 -Build         # rebuild first
#   .\publish-update.ps1 -Build -Target 192.168.0.10:41234   # + wireless install
#
# Credentials policy: the keystore password / alias / material paths are read at
# runtime from a local untracked JSON (your signing tool's config), NEVER hardcoded
# in this script or committed anywhere.

param(
  [string]$Hap = "",
  [string]$Target = "",
  [switch]$Build,
  [int]$CompatibleVersion = 24
)
$ErrorActionPreference = "Stop"

# ==== EDIT THESE to your machine ====
$Proj      = "C:\Path\To\ThisProject"                 # repo root (contains entry/)
$DevEco    = "C:\Path\To\DevEco Studio"               # DevEco Studio install dir
$SignCfg   = "C:\Path\To\my-sign-config.json"         # untracked; see shape below
# ====================================

# signConfig shape (your local, untracked file):
# { "keystoreFile": "...p12", "keystorePwd": "...", "keyAlias": "...",
#   "appCertFile": "...cer", "profileFile": "...p7b" }
$cfg = Get-Content $SignCfg -Raw | ConvertFrom-Json
foreach ($k in @('keystoreFile','keystorePwd','keyAlias','appCertFile','profileFile')) {
  if (-not $cfg.$k) { throw "signConfig missing field: $k" }
}

if ($Build) {
  $env:DEVECO_SDK_HOME = Join-Path $DevEco "sdk"
  $env:JAVA_HOME = Join-Path $DevEco "jbr"
  $env:Path = (Join-Path $DevEco "tools\node") + ";" + (Join-Path $DevEco "jbr\bin") + ";" + $env:Path
  Push-Location $Proj
  try {
    & (Join-Path $DevEco "tools\node\node.exe") (Join-Path $DevEco "tools\hvigor\bin\hvigorw.js") `
      --mode module -p product=default -p module=entry@default assembleHap --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "hvigor build failed" }
  } finally { Pop-Location }
}

if ($Hap -eq "") {
  $Hap = Get-ChildItem (Join-Path $Proj "entry\build\default\outputs\default\*unsigned*.hap") |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Hap -or -not (Test-Path $Hap)) { throw "no unsigned hap; pass -Build or -Hap" }

$signed = $Hap -replace "unsigned", "signed"
& (Join-Path $DevEco "jbr\bin\java.exe") -jar (Join-Path $DevEco "sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar") sign-app `
  -mode localSign -keyAlias $cfg.keyAlias -pwdInputMode 0 -keyPwd $cfg.keystorePwd -keystorePwd $cfg.keystorePwd `
  -keystoreFile $cfg.keystoreFile -appCertFile $cfg.appCertFile -profileFile $cfg.profileFile `
  -inFile $Hap -outFile $signed `
  -signAlg SHA256withECDSA -compatibleVersion $CompatibleVersion -signCode 1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $signed)) { throw "signing failed exit=$LASTEXITCODE" }
Write-Host "signed OK -> $signed"

if ($Target -ne "") {
  $hdc = Join-Path $DevEco "sdk\default\openharmony\toolchains\hdc.exe"
  & $hdc tconn $Target | Out-Host
  & $hdc -t $Target install -r $signed | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "install failed (uninstall old app on version/signature conflict)" }
  Write-Host "installed OK"
} else {
  Write-Host "no -Target: skipped install"
}
