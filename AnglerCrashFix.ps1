<#
.SYNOPSIS
  Angler Crash Fix: a reversible patch for the random "We're sorry, something went wrong"
  renderer crash in Call of the Wild: The Angler (Steam build 16541670).

.DESCRIPTION
  The game records rendering commands on several worker threads. Two bugs let two threads use the
  same command list at once, and the game then reads a null pointer
  (access violation at CotWTheAngler_Steam.exe+0x104A725 / +0x104A832 / +0x104ACDF / +0x1049F7C /
  +0x104ABE2).

  Fix 1 (5 bytes): when the game waits for a graphics pipeline (shader) to compile, its wait loop
  ran other queued jobs on the same thread. The wait now yields the thread instead.

  Fix 2 (a small lock): the same render pass of two consecutive frames could run on two worker
  threads at the same time. The second run reset the command list while the first was still
  recording into it. Fix 2 adds a lock around that render-pass function so the second run waits for
  the first to finish. It gives up waiting after a few seconds rather than risk a freeze.

  Fix 2 adds a 512-byte code section and a 4 KB data section to the exe (it uses the unused
  DOS-stub area of the header for the two extra section entries).

  The script only patches the exact known Steam exe (SHA-256 checked), keeps a backup, verifies the
  result, and can revert to the original.

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

$Version    = "2.0.0"
$ExeName    = "CotWTheAngler_Steam.exe"
$GameFolder = "Call of the Wild The Angler"
$StockSha   = "F3042F580F7EF79349313388522249EB906D91266D760893B7BF1A0BDE169021"
$V1Sha      = "3B28D0D8159377832F6CD367880A67B4847D54F15184FA94FA5EEF4A618A8B81"   # fix 1 only (v1.x of this tool)
$V2Sha      = "1772756AE66AF5C5AD0CD326721B03381F43833ACD781A7991E95B8FFB090E78"                                                          # fix 1 + fix 2
$StockLen   = 0x3263800
$PatchedLen = 0x3263A00

# Fix 1: RVA 0x1062F7F
$F1Offset = 0x106237F
[byte[]]$F1Old = 0xE8, 0x5C, 0xF2, 0xEA, 0xFF                  # call 0x140F121E0 (run another job)
[byte[]]$F1New = 0x31, 0xC0, 0x0F, 0x1F, 0x00                  # xor eax,eax ; nop  (-> SwitchToThread)

# Fix 2: hooks at function entry (RVA 0x1BCD20) and exit (RVA 0x1BCFB0) of the render-pass function
$AcqOffset = 0x1BC120
[byte[]]$AcqOld = 0x40, 0x56, 0x57, 0x41, 0x56     # push rsi; push rdi; push r14
[byte[]]$AcqNew = 0xE9, 0xDB, 0xB2, 0x3A, 0x03     # jmp .afixc (take the lock)
$RelOffset = 0x1BC3B0
[byte[]]$RelOld = 0x48, 0x8B, 0x5C, 0x24, 0x70     # mov rbx,[rsp+0x70]
[byte[]]$RelNew = 0xE9, 0x0A, 0xB1, 0x3A, 0x03     # jmp .afixc (release the lock)

# Header with the two extra section entries, and the lock code that goes at the end of the file
$HdrOld  = [Convert]::FromBase64String(
  'TVqQAAMAAAAEAAAA//8AALgAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAiAEAAA4fug4AtAnNIbgB' + `
  'TM0hVGhpcyBwcm9ncmFtIGNhbm5vdCBiZSBydW4gaW4gRE9TIG1vZGUuDQ0KJAAAAAAAAABuCfhNKmiWHipolh4qaJYeIxAFHjJo' + `
  'lh4+A5IfKGiWHj8Xlx8saJYePxdrHitolh4/F5MfDWiWHj8Xkh8gaJYePxeVHzlolh7uHZcfKGiWHhUPkx8raJYeqxGXHy5olh6w' + `
  'BpMfFGiWHrQBlR8raJYesAGSH2Jolh7rHZMfAmiWHu4dkx8jaJYePgOQHytolh4+A5cfDWiWHipolx5Ka5YesAGTH7Ftlh4qaJYe' + `
  'PmiWHhzolR8raJYeHOiSH+Folh4c6J8fQWiWHhzokx/sapYeHOiWHytolh4c6GkeK2iWHhzolB8raJYeUmljaCpolh4AAAAAAAAA' + `
  'AAAAAAAAAAAAAAAAAAAAAABQRQAAZIYJAOwGRmcAAAAAAAAAAPAAIgALAg4lACr0AQAKMgEAAAAAQFUZAQAQAAAAAABAAQAAAAAQ' + `
  'AAAAAgAABgAAAAAAAAAGAAAAAAAAAACAVgMABAAAS6omAwIAYIEAABAAAAAAAAAQAAAAAAAAAAAQAAAAAAAAEAAAAAAAAAAAAAAQ' + `
  'AAAAwFDhAnRlAAA0tuEC0AIAAAAwTQOACgEAAPA2A3TdFAAAAAAAAAAAAABATgNsNAgAsKqaAlQAAAAAAAAAAAAAAAAAAAAAAAAA' + `
  'gKuaAigAAABwqZoCQAEAAAAAAAAAAAAAAED0AQgYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAudGV4dAAAAJwp9AEAEAAAACr0' + `
  'AQAEAAAAAAAAAAAAAAAAAAAgAABgLnJkYXRhAAA62O0AAED0AQDa7QAALvQBAAAAAAAAAAAAAAAAQAAAQC5kYXRhAAAAwM5UAAAg' + `
  '4gIAyiQAAAjiAgAAAAAAAAAAAAAAAEAAAMAucGRhdGEAAHTdFAAA8DYDAN4UAADSBgMAAAAAAAAAAAAAAABAAABAQ1BBRGluZm84' + `
  'AAAAANBLAwACAAAAsBsDAAAAAAAAAAAAAAAAQAAAwF9SREFUQQAAsDkBAADgSwMAOgEAALIbAwAAAAAAAAAAAAAAAEAAAEAucm9k' + `
  'YXRhAGAJAAAAIE0DAAoAAADsHAMAAAAAAAAAAAAAAABAAABALnJzcmMAAACACgEAADBNAwAMAQAA9hwDAAAAAAAAAAAAAAAAQAAA' + `
  'QC5yZWxvYwAAbDQIAABATgMANggAAAIeAwAAAAAAAAAAAAAAAEAAAEIAAAAAAAAAAA==')
$HdrNew  = [Convert]::FromBase64String(
  'TVqQAAMAAAAEAAAA//8AALgAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAA4fug4AtAnNIbgB' + `
  'TM0hVGhpcyBwcm9ncmFtIGNhbm5vdCBiZSBydW4gaW4gRE9TIG1vZGUuDQ0KJAAAAAAAAABQRQAAZIYLAOwGRmcAAAAAAAAAAPAA' + `
  'IgALAg4lACr0AQAKMgEAAAAAQFUZAQAQAAAAAABAAQAAAAAQAAAAAgAABgAAAAAAAAAGAAAAAAAAAACgVgMABAAAS6omAwIAYIEA' + `
  'ABAAAAAAAAAQAAAAAAAAAAAQAAAAAAAAEAAAAAAAAAAAAAAQAAAAwFDhAnRlAAA0tuEC0AIAAAAwTQOACgEAAPA2A3TdFAAAAAAA' + `
  'AAAAAABATgNsNAgAsKqaAlQAAAAAAAAAAAAAAAAAAAAAAAAAgKuaAigAAABwqZoCQAEAAAAAAAAAAAAAAED0AQgYAAAAAAAAAAAA' + `
  'AAAAAAAAAAAAAAAAAAAAAAAudGV4dAAAAJwp9AEAEAAAACr0AQAEAAAAAAAAAAAAAAAAAAAgAABgLnJkYXRhAAA62O0AAED0AQDa' + `
  '7QAALvQBAAAAAAAAAAAAAAAAQAAAQC5kYXRhAAAAwM5UAAAg4gIAyiQAAAjiAgAAAAAAAAAAAAAAAEAAAMAucGRhdGEAAHTdFAAA' + `
  '8DYDAN4UAADSBgMAAAAAAAAAAAAAAABAAABAQ1BBRGluZm84AAAAANBLAwACAAAAsBsDAAAAAAAAAAAAAAAAQAAAwF9SREFUQQAA' + `
  'sDkBAADgSwMAOgEAALIbAwAAAAAAAAAAAAAAAEAAAEAucm9kYXRhAGAJAAAAIE0DAAoAAADsHAMAAAAAAAAAAAAAAABAAABALnJz' + `
  'cmMAAACACgEAADBNAwAMAQAA9hwDAAAAAAAAAAAAAAAAQAAAQC5yZWxvYwAAbDQIAABATgMANggAAAIeAwAAAAAAAAAAAAAAAEAA' + `
  'AEIuYWZpeGMAAAAQAAAAgFYDAAIAAAA4JgMAAAAAAAAAAAAAAAAgAABgLmFmaXhkAAAAEAAAAJBWAwAAAAAAAAAAAAAAAAAAAAAA' + `
  'AAAAgAAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' + `
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' + `
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==')
$CaveNew = [Convert]::FromBase64String(
  'QFZXQVZTVVZXQVRIg+woSInLidZMicdJacCxeTeeSMHoOkjB4ARIjS3TDwAASI1sBQBlSIsUJUgAAABIOVUAdGNFMeQxwPBID7FV' + `
  'AHQwQf/EQYH83AUAAHdBQYP8ZHINuQEAAAD/FW3Enf7rBv8VXcKd/mVIixQlSAAAAOvGSMdFCAEAAABI/wVzEwAARYXkdBZI/wVv' + `
  'EwAA6w1I/wVuEwAA6wRI/0UISInZifJJifhIg8QoQVxfXl1b6WZMxfxIacWxeTeeSMHoOkjB4ARIjQ0rDwAASI0MAWVIixQlSAAA' + `
  'AEg5EXUNSP9JCHUHSMcBAAAAAEiLXCRw6bdOxfzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM' + `
  'zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM' + `
  'zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM' + `
  'zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMw=')

function Find-Game {
  if ($GamePath) {
    $p = Join-Path $GamePath $ExeName
    if (-not (Test-Path $p)) { throw "No $ExeName in ""$GamePath""." }
    return $p
  }
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
  # Not in any Steam library: ask for the folder (Steam > right-click game > Manage > Browse local files)
  Write-Host "Could not find the game automatically." -ForegroundColor Yellow
  Write-Host "In Steam, right-click the game > Manage > Browse local files, and copy that folder's address."
  while ($true) {
    $in = "$(Read-Host "Paste the game folder here and press Enter (or just press Enter to cancel)")".Trim().Trim('"')
    if (-not $in) { throw "Cancelled. Nothing was changed." }
    $p = if ($in -like "*.exe") { $in } else { Join-Path $in $ExeName }
    if (Test-Path $p) { return $p }
    Write-Host "No $ExeName in that folder. Try again." -ForegroundColor Yellow
  }
}

function Read-Bytes([System.IO.FileStream]$fs, [long]$pos, [int]$n) {
  $fs.Position = $pos; $b = New-Object byte[] $n
  $got = 0
  while ($got -lt $n) { $r = $fs.Read($b, $got, $n - $got); if ($r -le 0) { break }; $got += $r }
  if ($got -ne $n) { throw "Short read at offset $pos." }
  return ,$b
}

function Write-Bytes([System.IO.FileStream]$fs, [long]$pos, [byte[]]$bytes) {
  $fs.Position = $pos; $fs.Write($bytes, 0, $bytes.Length)
}

function Same([byte[]]$a, [byte[]]$b) {
  if ($a.Length -ne $b.Length) { return $false }
  for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
  return $true
}

function Sha([string]$p) { return (Get-FileHash $p -Algorithm SHA256).Hash }

# Put back everything fix 2 changed (and fix 1 too when $AlsoFix1 is set). Safe to run on a partly patched file.
function Undo-Fix2([string]$Path, [bool]$AlsoFix1) {
  $fs = [System.IO.File]::Open($Path, "Open", "ReadWrite", "None")
  try {
    Write-Bytes $fs 0 $HdrOld
    Write-Bytes $fs $AcqOffset $AcqOld
    Write-Bytes $fs $RelOffset $RelOld
    if ($fs.Length -gt $StockLen) { $fs.SetLength($StockLen) }
    if ($AlsoFix1) { Write-Bytes $fs $F1Offset $F1Old }
    $fs.Flush()
  } finally { $fs.Dispose() }
}

Write-Host "Angler Crash Fix v$Version"
$exe = Find-Game
$sha = Sha $exe
$state = if ($sha -eq $StockSha) { "original (not patched)" }
         elseif ($sha -eq $V1Sha) { "PATCHED with fix 1 only (older version of this tool)" }
         elseif ($sha -eq $V2Sha) { "PATCHED (fix 1 + fix 2)" }
         else { "unknown build: this fix does not support it" }
Write-Host "Game exe : $exe"
Write-Host "SHA-256  : $sha"
Write-Host "State    : $state"

if ($Apply -or $Revert) {
  if (Get-Process ($ExeName -replace '\.exe$', '') -ErrorAction SilentlyContinue) { throw "Close the game first." }
}

if ($Apply) {
  if ($sha -eq $V2Sha) { Write-Host "Already patched."; return }
  if ($sha -ne $StockSha -and $sha -ne $V1Sha) { throw "Refused: this is not the supported game build, so nothing was changed." }
  $wasStock = ($sha -eq $StockSha)
  $backup = "$exe.stock-backup"
  if ($wasStock -and -not (Test-Path $backup)) {
    Copy-Item $exe $backup
    if ((Sha $backup) -ne $StockSha) { Remove-Item $backup; throw "Backup check failed; nothing was changed." }
    Write-Host "Backup   : $backup"
  } elseif (-not $wasStock) {
    $backup1 = "$exe.fix1-backup"
    if (-not (Test-Path $backup1)) {
      Copy-Item $exe $backup1
      if ((Sha $backup1) -ne $V1Sha) { Remove-Item $backup1; throw "Backup check failed; nothing was changed." }
      Write-Host "Backup   : $backup1"
    }
  }
  $fs = [System.IO.File]::Open($exe, "Open", "ReadWrite", "None")
  try {
    if ($fs.Length -ne $StockLen) { throw "Refused: unexpected file size, so nothing was changed." }
    if (-not (Same (Read-Bytes $fs 0 0x400) $HdrOld)) { throw "Refused: unexpected file header, so nothing was changed." }
    if (-not (Same (Read-Bytes $fs $AcqOffset 5) $AcqOld) -or -not (Same (Read-Bytes $fs $RelOffset 5) $RelOld)) {
      throw "Refused: unexpected code at the patch sites, so nothing was changed."
    }
    $f1 = Read-Bytes $fs $F1Offset 5
    if (-not ((Same $f1 $F1Old) -or (Same $f1 $F1New))) { throw "Refused: unexpected code at the patch site, so nothing was changed." }
  } finally { $fs.Dispose() }
  try {
    $fs = [System.IO.File]::Open($exe, "Open", "ReadWrite", "None")
    try {
      Write-Bytes $fs $F1Offset $F1New
      Write-Bytes $fs $StockLen $CaveNew
      Write-Bytes $fs 0 $HdrNew
      Write-Bytes $fs $AcqOffset $AcqNew     # the hooks go in last: until then the new code is never reached
      Write-Bytes $fs $RelOffset $RelNew
      $fs.Flush()
    } finally { $fs.Dispose() }
    if ((Sha $exe) -ne $V2Sha) { throw "Patch check failed." }
  } catch {
    $msg = $_.Exception.Message
    Undo-Fix2 $exe $wasStock
    $back = Sha $exe
    $restored = if ($wasStock) { $StockSha } else { $V1Sha }
    if ($back -ne $restored) { throw "$msg Restoring the original also failed. Use Steam > Verify integrity of game files." }
    throw "$msg The original game file was restored."
  }
  Write-Host "Done: crash fix applied." -ForegroundColor Green
}

if ($Revert) {
  if ($sha -eq $StockSha) { Write-Host "Already original."; return }
  if ($sha -ne $V1Sha -and $sha -ne $V2Sha) { throw "Refused: unexpected file contents. Use Steam > Verify integrity of game files instead." }
  if ($sha -eq $V1Sha) {
    $fs = [System.IO.File]::Open($exe, "Open", "ReadWrite", "None")
    try { Write-Bytes $fs $F1Offset $F1Old } finally { $fs.Dispose() }
  } else {
    Undo-Fix2 $exe $true
  }
  if ((Sha $exe) -ne $StockSha) { throw "Revert check failed. Use Steam > Verify integrity of game files." }
  Write-Host "Done: original game exe restored." -ForegroundColor Green
}
