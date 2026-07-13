<#
  chatgpt-rtl.ps1 — build a right-to-left (RTL) copy of the ChatGPT desktop app on Windows.

  Produces %LOCALAPPDATA%\ChatGPT-RTL: a standalone, patched copy of the installed
  ChatGPT app with smart bidirectional text support injected into every window
  (both "ChatGPT Work" and "Codex" modes). The original app is never touched and
  keeps updating normally. A Scheduled Task rebuilds the RTL copy automatically
  whenever the original app is updated.

  Usage (Windows PowerShell 5.1, run as Administrator only if the source is under
  a protected path):
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1           # build + auto-updater
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -NoWatch  # build only
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -Restore  # remove copy + task
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -Auto     # (internal) rebuild if changed

  Prerequisites: Node.js (provides `node` and `npx`) on PATH.

  NOTE: This mirrors the macOS build, which was verified end to end. It has not
  been run on a Windows machine yet — validate on Windows before relying on it.
#>
[CmdletBinding()]
param(
  [switch]$Restore,
  [switch]$NoWatch,
  [switch]$Auto
)

$ErrorActionPreference = 'Stop'

# ------------------------------- configuration -------------------------------
$AppName      = 'ChatGPT'
$DestRoot     = Join-Path $env:LOCALAPPDATA 'ChatGPT-RTL'
$SupportDir   = Join-Path $env:LOCALAPPDATA 'chatgpt-rtl'
$SelfCopy     = Join-Path $SupportDir 'chatgpt-rtl.ps1'
$VersionFile  = Join-Path $SupportDir 'patched-version'
$LogFile      = Join-Path $SupportDir 'updater.log'
$TaskName     = 'ChatGPT RTL Updater'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ChatGPT RTL.lnk'

function Info($m) { if (-not $Auto) { Write-Host "==> $m" -ForegroundColor Cyan } }
function Ok($m)   { if (-not $Auto) { Write-Host " ok $m" -ForegroundColor Green } }
function Die($m)  { Write-Host "error $m" -ForegroundColor Red; exit 1 }

# ----------------------------- locate the app --------------------------------
# Returns the directory that contains the ChatGPT executable + resources\app.asar.
function Find-SourceDir {
  $candidates = @()

  # Per-user / machine "Programs"-style installs (Squirrel/NSIS layouts).
  $candidates += Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT'
  $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Codex'
  $candidates += Join-Path ${env:ProgramFiles} 'ChatGPT'

  # MSIX (Microsoft Store) install under WindowsApps.
  try {
    $pkg = Get-AppxPackage -Name '*ChatGPT*','*OpenAI*','*Codex*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { $candidates += $pkg.InstallLocation }
  } catch {}

  foreach ($dir in $candidates) {
    if (-not $dir) { continue }
    # An Electron app: <dir>\resources\app.asar with the launcher exe next to resources\.
    $found = Get-ChildItem -Path $dir -Recurse -Filter 'app.asar' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\resources\\app\.asar$' } | Select-Object -First 1
    if ($found) { return (Split-Path (Split-Path $found.FullName -Parent) -Parent) }
  }
  return $null
}

function Get-MainExe($appDir) {
  $exe = Get-ChildItem -Path $appDir -Filter '*.exe' -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match '(?i)chatgpt|codex' -and $_.Name -notmatch '(?i)helper|crashpad|update|squirrel' } |
         Select-Object -First 1
  if (-not $exe) {
    $exe = Get-ChildItem -Path $appDir -Filter '*.exe' -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notmatch '(?i)helper|crashpad|update|squirrel' } | Select-Object -First 1
  }
  return $exe
}

# Locate the @electron/asar module cached by npx, so we can call its Node API.
function Get-AsarNodePath {
  & npx --yes @electron/asar --version *> $null
  if ($LASTEXITCODE -ne 0) { Die 'could not run @electron/asar (Node + one-time network access required)' }
  $npxCache = Join-Path $env:USERPROFILE 'AppData\Local\npm-cache\_npx'
  if (-not (Test-Path $npxCache)) { $npxCache = Join-Path $env:APPDATA 'npm-cache\_npx' }
  $mod = Get-ChildItem -Path $npxCache -Recurse -Directory -Filter 'asar' -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -match '\\@electron\\asar$' } | Select-Object -First 1
  if (-not $mod) { Die 'could not locate the @electron/asar module' }
  return (Split-Path (Split-Path $mod.FullName -Parent) -Parent)   # ...\node_modules
}

# ------------------------------ the RTL loader -------------------------------
# Identical behaviour to the macOS build: attach to every web-contents and inject
# CSS + a small bidi tagger. insertCSS runs at the Electron layer, bypassing the
# page's Content-Security-Policy.
$Loader = @'
/* __CGPT_RTL__ */
'use strict';
try {
  const { app } = require('electron');

  const CSS = `
    p, li, h1, h2, h3, h4, h5, h6, blockquote, dd, dt, figcaption, summary,
    td, th, [class*="markdown"] p, [class*="markdown"] li {
      unicode-bidi: plaintext !important;
    }
    [dir="auto"], [dir="rtl"] { text-align: start !important; }
    textarea, [contenteditable="true"], [data-lexical-editor="true"], [role="textbox"] {
      unicode-bidi: plaintext !important;
    }
    pre, pre *, code, code *, kbd, samp, tt,
    .katex, .katex-display, mjx-container, math,
    [class*="hljs"], [class*="language-"], [class*="token"],
    [class*="cm-"], .cm-editor, .monaco-editor, .monaco-editor * {
      unicode-bidi: isolate !important;
      direction: ltr !important;
    }
    pre, .katex-display, .cm-editor, .monaco-editor { text-align: left !important; }
    [dir="rtl"] ul, [dir="rtl"] ol { padding-right: 1.5rem !important; padding-left: 0 !important; }
  `;

  const JS = `(function(){
    if (window.__cgptRtl__) return; window.__cgptRtl__ = 1;
    var RTL = /[\\u0590-\\u05FF\\u0600-\\u06FF\\u0700-\\u074F\\u0750-\\u077F\\u08A0-\\u08FF\\uFB1D-\\uFB4F\\uFB50-\\uFDFF\\uFE70-\\uFEFF]/;
    var SEL = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,dd,dt,figcaption,summary,td,th';
    var LIVE = 'textarea,[contenteditable="true"],[data-lexical-editor="true"],[role="textbox"]';
    var SKIP = 'pre,code,kbd,samp,.katex,.katex-display,mjx-container,math,.monaco-editor,.cm-editor,[class*="hljs"],[class*="language-"]';
    function mark(el){ try{
      if(!el||el.nodeType!==1||el.hasAttribute('dir'))return;
      if(el.closest&&el.closest(SKIP))return;
      var t=el.textContent; if(t&&RTL.test(t))el.setAttribute('dir','auto');
    }catch(e){} }
    function live(el){ try{ if(el&&el.nodeType===1&&!el.hasAttribute('dir'))el.setAttribute('dir','auto'); }catch(e){} }
    function scan(root){ try{
      if(root.nodeType===1&&root.matches){ if(root.matches(SEL))mark(root); if(root.matches(LIVE))live(root); }
      if(root.querySelectorAll){
        var a=root.querySelectorAll(SEL),i; for(i=0;i<a.length;i++)mark(a[i]);
        var b=root.querySelectorAll(LIVE),j; for(j=0;j<b.length;j++)live(b[j]);
      }
    }catch(e){} }
    var queue=[], scheduled=false;
    var idle=window.requestIdleCallback||function(f){return setTimeout(function(){f({timeRemaining:function(){return 5;}});},200);};
    function flush(){ scheduled=false; var n=queue; queue=[]; for(var i=0;i<n.length;i++)scan(n[i]); }
    function schedule(){ if(scheduled)return; scheduled=true; idle(flush); }
    function boot(){
      scan(document);
      try{
        var mo=new MutationObserver(function(muts){
          for(var i=0;i<muts.length;i++){ var a=muts[i].addedNodes; if(!a)continue;
            for(var k=0;k<a.length;k++){ if(a[k].nodeType===1)queue.push(a[k]); } }
          if(queue.length)schedule();
        });
        mo.observe(document.documentElement,{childList:true,subtree:true});
      }catch(e){}
    }
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
  })();`;

  const attach = (wc) => {
    if (!wc || wc.__cgptRtl) return;
    wc.__cgptRtl = true;
    const apply = () => {
      try { Promise.resolve(wc.insertCSS(CSS, { cssOrigin: 'user' })).catch(() => {}); } catch (e) {}
      try { Promise.resolve(wc.executeJavaScript(JS, true)).catch(() => {}); } catch (e) {}
    };
    wc.on('dom-ready', apply);
    wc.on('did-frame-finish-load', apply);
  };

  app.on('web-contents-created', (_e, wc) => attach(wc));
  app.on('browser-window-created', (_e, win) => { try { attach(win.webContents); } catch (e) {} });
} catch (e) {
  try { console.error('[chatgpt-rtl] init failed:', e && e.message); } catch (_) {}
}
'@

# --------------------------------- build -------------------------------------
function Build {
  $srcDir = Find-SourceDir
  if (-not $srcDir) { Die "ChatGPT install not found. Install the ChatGPT desktop app first." }
  Info "Source: $srcDir"

  $asarNodePath = Get-AsarNodePath

  Info "Copying app -> $DestRoot"
  if (Test-Path $DestRoot) { Remove-Item -Recurse -Force $DestRoot }
  New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null
  # robocopy is far faster than Copy-Item for large trees; /MIR mirrors exactly.
  & robocopy $srcDir $DestRoot /MIR /NFL /NDL /NJH /NJS /NP *> $null
  if ($LASTEXITCODE -ge 8) { Die "copy failed (robocopy exit $LASTEXITCODE)" }

  $asar     = Join-Path $DestRoot 'resources\app.asar'
  $unpacked = Join-Path $DestRoot 'resources\app.asar.unpacked'
  if (-not (Test-Path $asar)) { Die "app.asar not found under $DestRoot\resources" }

  $exe = Get-MainExe $DestRoot
  if (-not $exe) { Die "could not find the ChatGPT executable in $DestRoot" }

  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("cgptrtl_" + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  try {
    # Original header hash, needed later to find/replace it inside the exe.
    $oldHash = Get-AsarHeaderHash $asar $asarNodePath

    Info "Extracting app.asar"
    & npx --yes @electron/asar extract "$asar" (Join-Path $work 'app')
    if ($LASTEXITCODE -ne 0) { Die "asar extract failed" }
    # Overlay the authoritative native-module tree (extract can miss sidecar files).
    if (Test-Path $unpacked) {
      & robocopy $unpacked (Join-Path $work 'app') /E /NFL /NDL /NJH /NJS /NP *> $null
    }

    $mainRel  = & node -p "require('$((Join-Path $work 'app\package.json') -replace '\\','/')').main"
    $mainFile = Join-Path $work (Join-Path 'app' $mainRel)
    if (-not (Test-Path $mainFile)) { Die "main entry '$mainRel' not found in app.asar" }

    Info "Injecting RTL loader into $mainRel"
    $loaderPath = Join-Path (Split-Path $mainFile -Parent) '__cgpt_rtl__.js'
    [System.IO.File]::WriteAllText($loaderPath, $Loader, (New-Object System.Text.UTF8Encoding($false)))
    $mainText = [System.IO.File]::ReadAllText($mainFile)
    if ($mainText -notmatch '__CGPT_RTL__') {
      $mainText = "/* __CGPT_RTL__ */try{require('./__cgpt_rtl__.js');}catch(e){}`n" + $mainText
      [System.IO.File]::WriteAllText($mainFile, $mainText, (New-Object System.Text.UTF8Encoding($false)))
    }

    # Build the unpack-dir glob from the packages that were unpacked originally.
    $glob = ''
    $nmDir = Join-Path $unpacked 'node_modules'
    if (Test-Path $nmDir) {
      $names = (Get-ChildItem -Path $nmDir -Directory | ForEach-Object { $_.Name }) -join '|'
      if ($names) { $glob = "node_modules/@($names)" }
    }

    Info "Repacking app.asar (preserving native modules)"
    Remove-Item -Force $asar -ErrorAction SilentlyContinue
    if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
    $packScript = @'
const asar = require("@electron/asar");
const [src, out, unpackDir] = process.argv.slice(1);
const opts = { unpack: "**/*.node" };
if (unpackDir) opts.unpackDir = unpackDir;
asar.createPackageWithOptions(src, out, opts)
  .then(() => process.exit(0))
  .catch((err) => { console.error(err); process.exit(1); });
'@
    $packFile = Join-Path $work 'pack.js'
    [System.IO.File]::WriteAllText($packFile, $packScript)
    $env:NODE_PATH = $asarNodePath
    & node $packFile (Join-Path $work 'app') $asar $glob
    if ($LASTEXITCODE -ne 0) { Die "asar repack failed" }

    Info "Updating ASAR integrity hash"
    $newHash = Get-AsarHeaderHash $asar $asarNodePath
    if (-not $newHash) { Die "could not compute new asar hash" }
    Set-ExeAsarHash $exe.FullName $oldHash $newHash $DestRoot $asarNodePath

    Info "Creating shortcut"
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($ShortcutPath)
    $sc.TargetPath = $exe.FullName
    $sc.WorkingDirectory = $DestRoot
    $sc.Description = 'ChatGPT RTL'
    $sc.Save()

    # Record the patched version for the auto-updater.
    New-Item -ItemType Directory -Force -Path $SupportDir | Out-Null
    (Get-ItemProperty $exe.FullName).VersionInfo.ProductVersion | Out-File -Encoding ascii $VersionFile
    Ok "Built $DestRoot"
  } finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue
  }
}

function Get-AsarHeaderHash($asarPath, $nodePath) {
  $env:NODE_PATH = $nodePath
  $script = 'const a=require("@electron/asar"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(a.getRawHeader(process.argv[1]).headerString).digest("hex"));'
  $h = & node -e $script $asarPath
  Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue
  return $h
}

# Electron validates the app.asar header hash against a value baked into the exe.
# Replace the old hash with the new one; if it isn't found (different storage),
# fall back to disabling the integrity fuse.
function Set-ExeAsarHash($exePath, $oldHash, $newHash, $appDir, $nodePath) {
  if ($oldHash -and $newHash -and ($oldHash.Length -eq $newHash.Length)) {
    $bytes    = [System.IO.File]::ReadAllBytes($exePath)
    $oldBytes = [System.Text.Encoding]::ASCII.GetBytes($oldHash)
    $newBytes = [System.Text.Encoding]::ASCII.GetBytes($newHash)
    $count = 0; $i = 0
    while ($i -le ($bytes.Length - $oldBytes.Length)) {
      $match = $true
      for ($j = 0; $j -lt $oldBytes.Length; $j++) { if ($bytes[$i + $j] -ne $oldBytes[$j]) { $match = $false; break } }
      if ($match) { [Array]::Copy($newBytes, 0, $bytes, $i, $newBytes.Length); $count++; $i += $oldBytes.Length }
      else { $i++ }
    }
    if ($count -gt 0) {
      [System.IO.File]::WriteAllBytes($exePath, $bytes)
      Ok "Patched $count integrity hash reference(s) in $(Split-Path $exePath -Leaf)"
      return
    }
  }
  Info "Integrity hash not embedded in exe — disabling the integrity fuse instead"
  & npx --yes @electron/fuses write --app $appDir EnableEmbeddedAsarIntegrityValidation=off *> $null
  if ($LASTEXITCODE -ne 0) {
    Info "note: could not adjust the integrity fuse; if the app refuses to start, the build needs the fuse-flip step for this version"
  }
}

# --------------------------- auto-update watcher -----------------------------
function Install-Watch {
  New-Item -ItemType Directory -Force -Path $SupportDir | Out-Null
  if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    Copy-Item -Force $PSCommandPath $SelfCopy
  } else {
    Info "note: run from a saved .ps1 file to enable auto-updates"
    return
  }

  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfCopy`" -Auto"
  # Fire on logon, and daily as a backstop. (Electron updates land in-place or in
  # a new version dir; -Auto compares versions and rebuilds only when needed.)
  $t1 = New-ScheduledTaskTrigger -AtLogOn
  $t2 = New-ScheduledTaskTrigger -Daily -At 3am
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($t1, $t2) `
      -Settings $settings -Force -Description 'Rebuilds the ChatGPT RTL copy after the app updates.' | Out-Null
    Ok "Installed auto-updater (Scheduled Task '$TaskName')"
  } catch {
    Info "note: could not register the Scheduled Task ($($_.Exception.Message)). Re-run this script after each app update."
  }
}

function Invoke-Auto {
  $srcDir = Find-SourceDir
  if (-not $srcDir) { return }
  $exe = Get-MainExe $srcDir
  $cur = if ($exe) { (Get-ItemProperty $exe.FullName).VersionInfo.ProductVersion } else { '' }
  $prev = if (Test-Path $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { '' }
  if ((-not (Test-Path $DestRoot)) -or ($cur -ne $prev)) {
    "[{0}] rebuilding RTL app (was '{1}', now '{2}')" -f (Get-Date), $prev, $cur | Out-File -Append -Encoding utf8 $LogFile
    Build
  }
}

function Invoke-Restore {
  Info "Removing auto-updater"
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Info "Removing $DestRoot"
  Remove-Item -Recurse -Force $DestRoot -ErrorAction SilentlyContinue
  Remove-Item -Force $ShortcutPath -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $SupportDir -ErrorAction SilentlyContinue
  Ok "Restored — the original ChatGPT app was never modified."
}

# --------------------------------- dispatch ----------------------------------
if ($Restore) { Invoke-Restore; return }
if ($Auto)    { Invoke-Auto;    return }

Build
if (-not $NoWatch) { Install-Watch }
Info "Launching ChatGPT RTL (close the original ChatGPT first if it's open)"
$exe = Get-MainExe $DestRoot
if ($exe) { Start-Process $exe.FullName }
Ok "Done. Type Hebrew in Work or Codex mode to see RTL alignment."
