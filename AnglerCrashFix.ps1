<#
.SYNOPSIS
  Angler Crash Fix: a reversible 5-byte patch for the random "We're sorry, something went wrong"
  renderer crash in Call of the Wild: The Angler (Steam build 16541670).

.DESCRIPTION
  When the game must wait for a graphics pipeline (shader) to finish compiling, its wait loop runs
  other queued jobs on the same thread. One of those jobs can change or reset the command list the
  waiting render pass is still recording. When the pass resumes, it reads a null pointer and the
  game crashes (access violation at CotWTheAngler_Steam.exe+0x104A725 / +0x104A832 / +0x104ACDF /
  +0x1049F7C).

  This patch changes one call in that wait loop so it yields the thread (SwitchToThread) instead of
  running other jobs. Pipelines still compile on the game's other worker threads.

  The script only patches the exact known Steam exe (SHA-256 checked), keeps a backup, and can revert.

.EXAMPLE
  .\AnglerCrashFix.ps1            # show status
  .\AnglerCrashFix.ps1 -Apply     # apply the fix
  .\AnglerCrashFix.ps1 -Revert    # restore the original bytes
  .\AnglerCrashFix.ps1 -Apply -GamePath "D:\Games\Call of the Wild The Angler"
#>
[CmdletBinding(DefaultParameterSetName = "Status")]
param(
  [Parameter(ParameterSetName = "Apply")][switch]$Apply,
  [Parameter(ParameterSetName = "Revert")][switch]$Revert,
  [string]$GamePath
)
$ErrorActionPreference = "Stop"
trap { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$ExeName    = "CotWTheAngler_Steam.exe"
$GameFolder = "Call of the Wild The Angler"
$StockSha   = "F3042F580F7EF79349313388522249EB906D91266D760893B7BF1A0BDE169021"
$PatchedSha = "3B28D0D8159377832F6CD367880A67B4847D54F15184FA94FA5EEF4A618A8B81"
$FileOffset = 0x106237F                                  # RVA 0x1062F7F
[byte[]]$Old = 0xE8, 0x5C, 0xF2, 0xEA, 0xFF                  # call 0x140F121E0 (run another job)
[byte[]]$New = 0x31, 0xC0, 0x0F, 0x1F, 0x00                  # xor eax,eax ; nop  (-> SwitchToThread)

function Find-Game {
  if ($GamePath) { return (Join-Path $GamePath $ExeName) }
  $roots = @()
  try { $roots += (Get-ItemProperty "HKCU:\Software\Valve\Steam" -Name SteamPath).SteamPath } catch {}
  foreach ($r in @($roots)) {
    $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
      foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
        $roots += $m.Groups[1].Value -replace '\\\\', '\'
      }
    }
  }
  foreach ($r in ($roots | Select-Object -Unique)) {
    $p = Join-Path $r "steamapps\common\$GameFolder\$ExeName"
    if (Test-Path $p) { return $p }
  }
  throw "Could not find $ExeName. Pass -GamePath ""<folder that contains $ExeName>""."
}

function Read-Site([string]$Path) {
  $fs = [System.IO.File]::OpenRead($Path)
  try { $fs.Position = $FileOffset; $b = New-Object byte[] 5; [void]$fs.Read($b, 0, 5); return ,$b }
  finally { $fs.Dispose() }
}

function Write-Site([string]$Path, [byte[]]$Bytes) {
  $fs = [System.IO.File]::Open($Path, "Open", "ReadWrite", "None")
  try { $fs.Position = $FileOffset; $fs.Write($Bytes, 0, 5) } finally { $fs.Dispose() }
}

function Same([byte[]]$a, [byte[]]$b) { return (Compare-Object $a $b -SyncWindow 0) -eq $null }

$exe = Find-Game
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash
$site = Read-Site $exe
$state = if ($sha -eq $StockSha) { "original (not patched)" }
         elseif ($sha -eq $PatchedSha) { "PATCHED" }
         else { "unknown build: this fix does not support it" }
Write-Host "Game exe : $exe"
Write-Host "SHA-256  : $sha"
Write-Host "State    : $state"

if ($Apply -or $Revert) {
  if (Get-Process ($ExeName -replace '\.exe$', '') -ErrorAction SilentlyContinue) { throw "Close the game first." }
}

if ($Apply) {
  if ($sha -eq $PatchedSha) { Write-Host "Already patched."; return }
  if ($sha -ne $StockSha -or -not (Same $site $Old)) { throw "Refused: this is not the supported game build, so nothing was changed." }
  $backup = "$exe.stock-backup"
  if (-not (Test-Path $backup)) {
    Copy-Item $exe $backup
    if ((Get-FileHash $backup -Algorithm SHA256).Hash -ne $StockSha) { Remove-Item $backup; throw "Backup check failed; nothing was changed." }
    Write-Host "Backup   : $backup"
  }
  Write-Site $exe $New
  if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $PatchedSha) { Write-Site $exe $Old; throw "Patch check failed; original bytes restored." }
  Write-Host "Done: crash fix applied." -ForegroundColor Green
}

if ($Revert) {
  if ($sha -eq $StockSha) { Write-Host "Already original."; return }
  if ($sha -ne $PatchedSha -or -not (Same $site $New)) { throw "Refused: unexpected file contents. Use Steam > Verify integrity of game files instead." }
  Write-Site $exe $Old
  if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $StockSha) { throw "Revert check failed. Use Steam > Verify integrity of game files." }
  Write-Host "Done: original game exe restored." -ForegroundColor Green
}
