<#
  chatgpt-rtl.ps1 - build a right-to-left (RTL) copy of the ChatGPT desktop app on Windows.

  Produces %LOCALAPPDATA%\ChatGPT-RTL: a standalone, patched copy of the installed
  ChatGPT app with smart bidirectional text support injected into every window
  (both "ChatGPT Work" and "Codex" modes). The original app is never touched and
  keeps updating normally. A Scheduled Task rebuilds the RTL copy automatically
  whenever the original app is updated.

  Usage (Windows PowerShell 5.1, run as Administrator only if the source is under
  a protected path):
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1                 # build + auto-updater
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -NoWatch        # build only
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -CloseOriginal  # close original without prompting
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -Restore        # remove copy + task
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -Auto           # (internal) rebuild if changed

  Prerequisites: Node.js (provides `node` and `npx`) on PATH.

  The RTL copy keeps the original app's identity, so it shares the Electron
  single-instance lock: the original ChatGPT/Codex app must be closed for the RTL
  copy to open with RTL applied. The build closes it for you (prompting first,
  unless -CloseOriginal is given).
#>
[CmdletBinding()]
param(
  [switch]$Restore,
  [switch]$NoWatch,
  [switch]$Auto,
  [switch]$CloseOriginal
)

$ErrorActionPreference = 'Stop'

# When piped into PowerShell (irm | iex) the session runs under the machine's
# default policy, which is usually Restricted and blocks npm/npx - on Windows
# those are .ps1 shims, so calling them fails with "running scripts is disabled".
# Relax the policy for THIS process only: no admin required, not persisted, and
# it also overrides a session started with -ExecutionPolicy Restricted.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

# ------------------------------- configuration -------------------------------
$AppName      = 'ChatGPT'
$DestRoot     = Join-Path $env:LOCALAPPDATA 'ChatGPT-RTL'
$SupportDir   = Join-Path $env:LOCALAPPDATA 'chatgpt-rtl'
$SelfCopy     = Join-Path $SupportDir 'chatgpt-rtl.ps1'
$VersionFile  = Join-Path $SupportDir 'patched-version'
$LogFile      = Join-Path $SupportDir 'updater.log'
$LauncherPath = Join-Path $SupportDir 'launch-rtl.ps1'
$TaskName     = 'ChatGPT RTL Updater'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ChatGPT RTL.lnk'
# Canonical location of this script, used by the auto-updater when the tool is
# run piped (irm | iex) and therefore has no copy of itself on disk.
$RawUrl       = if ($env:CHATGPT_RTL_RAW_URL) { $env:CHATGPT_RTL_RAW_URL } else { 'https://raw.githubusercontent.com/Asher-pro/ChatGPT-app-RTL/main/chatgpt-rtl.ps1' }

function Info($m) { if (-not $Auto) { Write-Host "==> $m" -ForegroundColor Cyan } }
function Ok($m)   { if (-not $Auto) { Write-Host " ok $m" -ForegroundColor Green } }
function Die($m)  { Write-Host "error $m" -ForegroundColor Red; exit 1 }

# Windows PowerShell 5.1 turns any output a native tool writes to stderr into a
# terminating error while $ErrorActionPreference is 'Stop' (e.g. npm/npx print an
# "npm notice" update banner to stderr). Run node/npx/robocopy through this wrapper
# so their diagnostics don't abort the build; check $LASTEXITCODE for real failures.
function Use-NativeErrors {
  param([Parameter(Mandatory)][scriptblock]$Command)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Command } finally { $ErrorActionPreference = $prev }
}

# The copied app nests node_modules deep enough to exceed the classic 260-char
# MAX_PATH limit, and Remove-Item cannot delete those paths ("Could not find a
# part of the path ..."). robocopy uses long-path-aware APIs, so mirroring an
# empty directory over the target clears everything inside; then the now-empty
# top folder deletes normally.
function Remove-Tree {
  param([Parameter(Mandatory)][string]$Path)
  # -LiteralPath throughout: on a non-ASCII profile (e.g. a Hebrew user name)
  # TEMP can be an 8.3 short path like C:\Users\2922~1\..., and the tilde would
  # be misread by the wildcard-aware -Path. Cleanup must never throw, so guarded.
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return } catch {}
  if (-not (Test-Path -LiteralPath $Path)) { return }
  # Long-path fallback: the copied app nests node_modules past MAX_PATH, which
  # Remove-Item cannot delete. robocopy is long-path aware, so mirroring an empty
  # directory over the target clears everything inside; then the shell removes it.
  try {
    $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('cgptrtl_empty_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $empty -Force -ErrorAction Stop | Out-Null
    Use-NativeErrors { & robocopy $empty $Path /MIR /NFL /NDL /NJH /NJS /NP *> $null }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
  } catch {}
}

# ----------------------------- locate the app --------------------------------
# Returns the directory that contains the ChatGPT executable + resources\app.asar.
function Find-SourceDir {
  $candidates = @()

  # Per-user / machine "Programs"-style installs (Squirrel/NSIS layouts).
  $candidates += Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT'
  $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Codex'
  $candidates += Join-Path ${env:ProgramFiles} 'ChatGPT'

  # MSIX (Microsoft Store) install under WindowsApps. Get-AppxPackage's -Name
  # parameter takes a single string, so filter with Where-Object to match any of
  # the possible package identities (the unified app ships as "OpenAI.Codex").
  try {
    Get-AppxPackage -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(?i)ChatGPT|OpenAI|Codex' -and $_.InstallLocation } |
      ForEach-Object { $candidates += $_.InstallLocation }
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

# The unified ChatGPT/Codex app on Windows ships as an MSIX package. Its native
# code calls WinRT APIs (e.g. ApplicationData.Current.LocalCacheFolder) that only
# work when the process has a *package identity*. A plain copy under AppData has
# none, so it crashes at startup with "Operation is not valid due to the current
# state of the object". The fix is to launch our patched copy *with the original
# package's identity* via Invoke-CommandInDesktopPackage. This resolves the source
# package's family name and its manifest AppId; returns $null for non-MSIX
# (Squirrel/NSIS) installs, which need no identity.
function Get-SourceIdentity($srcDir) {
  try {
    $pkg = Get-AppxPackage -ErrorAction SilentlyContinue |
           Where-Object { $_.InstallLocation -and $srcDir.StartsWith($_.InstallLocation, [StringComparison]::OrdinalIgnoreCase) } |
           Select-Object -First 1
    if (-not $pkg) { return $null }
    $app = (Get-AppxPackageManifest $pkg).Package.Applications.Application
    if ($app -is [array]) { $app = $app[0] }
    $appId = $app.Id
    if (-not $appId) { return $null }
    return @{ Family = $pkg.PackageFamilyName; AppId = $appId }
  } catch { return $null }
}

# Locate the @electron/asar module cached by npx, so we can call its Node API.
function Get-AsarNodePath {
  Use-NativeErrors { & npx --yes @electron/asar --version *> $null }
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
  # A previous RTL build leaves deeply nested node_modules under
  # app.asar.unpacked that exceed MAX_PATH, so use the long-path-safe remover.
  Remove-Tree $DestRoot
  New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null
  # robocopy is far faster than Copy-Item for large trees; /MIR mirrors exactly.
  Use-NativeErrors { & robocopy $srcDir $DestRoot /MIR /NFL /NDL /NJH /NJS /NP *> $null }
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
    Use-NativeErrors { & npx --yes @electron/asar extract "$asar" (Join-Path $work 'app') }
    if ($LASTEXITCODE -ne 0) { Die "asar extract failed" }
    # Overlay the authoritative native-module tree (extract can miss sidecar files).
    if (Test-Path $unpacked) {
      Use-NativeErrors { & robocopy $unpacked (Join-Path $work 'app') /E /NFL /NDL /NJH /NJS /NP *> $null }
    }

    $mainRel  = Use-NativeErrors { & node -p "require('$((Join-Path $work 'app\package.json') -replace '\\','/')').main" }
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
    Remove-Tree $unpacked
    $packScript = @'
const asar = require("@electron/asar");
const [src, out, unpackDir] = process.argv.slice(2);
const opts = { unpack: "**/*.node" };
if (unpackDir) opts.unpackDir = unpackDir;
asar.createPackageWithOptions(src, out, opts)
  .then(() => process.exit(0))
  .catch((err) => { console.error(err); process.exit(1); });
'@
    $packFile = Join-Path $work 'pack.js'
    [System.IO.File]::WriteAllText($packFile, $packScript)
    $env:NODE_PATH = $asarNodePath
    Use-NativeErrors { & node $packFile (Join-Path $work 'app') $asar $glob }
    if ($LASTEXITCODE -ne 0) { Die "asar repack failed" }

    Info "Updating ASAR integrity hash"
    $newHash = Get-AsarHeaderHash $asar $asarNodePath
    if (-not $newHash) { Die "could not compute new asar hash" }
    Set-ExeAsarHash $exe.FullName $oldHash $newHash $DestRoot $asarNodePath

    New-Item -ItemType Directory -Force -Path $SupportDir | Out-Null

    Info "Writing launcher"
    # The patched copy must start with the original MSIX package identity, or its
    # WinRT calls crash. Generate a launcher that does exactly that; regenerated on
    # every build so the identity stays current.
    #
    # The launcher must NOT embed the destination path as a string literal: on a
    # non-ASCII profile (e.g. a Hebrew user name) the path contains characters that
    # Windows PowerShell 5.1 mangles, because it reads a BOM-less .ps1 as ANSI. So
    # the launcher discovers its own exe from $env:LOCALAPPDATA at run time (env
    # vars are always correct Unicode), and we write the file WITH a UTF-8 BOM so
    # 5.1 decodes it correctly regardless.
    $identity = Get-SourceIdentity $srcDir
    $find = @'
$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'ChatGPT-RTL'
$exe = Get-ChildItem -LiteralPath $root -Filter '*.exe' -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notmatch '(?i)helper|crashpad|update|squirrel' } |
  Sort-Object { $_.Name -notmatch '(?i)chatgpt|codex' } | Select-Object -First 1
'@
    if ($identity) {
      $fam = $identity.Family.Replace("'", "''")
      $aid = $identity.AppId.Replace("'", "''")
      $launcher = @"
# Auto-generated by chatgpt-rtl. Launches the patched RTL copy with the original
# MSIX package identity, so the app's WinRT APIs (ApplicationData.Current) work.
$find
if (`$exe) {
  try { Invoke-CommandInDesktopPackage -PackageFamilyName '$fam' -AppId '$aid' -Command `$exe.FullName -PreventBreakaway }
  catch { Start-Process `$exe.FullName }
}
"@
    } else {
      # Non-MSIX install (Squirrel/NSIS): no package identity needed.
      $launcher = @"
$find
if (`$exe) { Start-Process `$exe.FullName }
"@
    }
    # UTF-8 *with* BOM so Windows PowerShell 5.1 reads the script as UTF-8.
    [System.IO.File]::WriteAllText($LauncherPath, $launcher, (New-Object System.Text.UTF8Encoding($true)))

    Info "Creating shortcut"
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($ShortcutPath)
    $sc.TargetPath = $psExe
    $sc.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherPath`""
    $sc.WorkingDirectory = $DestRoot
    $sc.IconLocation = "$($exe.FullName),0"
    $sc.Description = 'ChatGPT RTL'
    $sc.Save()

    # Record the patched version for the auto-updater.
    (Get-ItemProperty $exe.FullName).VersionInfo.ProductVersion | Out-File -Encoding ascii $VersionFile
    Ok "Built $DestRoot"
  } finally {
    Remove-Tree $work
    Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue
  }
}

function Get-AsarHeaderHash($asarPath, $nodePath) {
  $env:NODE_PATH = $nodePath
  # Use single quotes inside the JS: Windows PowerShell 5.1 strips embedded double
  # quotes when passing a string as a native-command argument, which would corrupt
  # the script before node ever sees it.
  $nodeScript = "const a=require('@electron/asar'),c=require('crypto');process.stdout.write(c.createHash('sha256').update(a.getRawHeader(process.argv[1]).headerString).digest('hex'));"
  $h = Use-NativeErrors { & node -e $nodeScript $asarPath }
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
  Info "Integrity hash not embedded in exe - disabling the integrity fuse instead"
  Use-NativeErrors { & npx --yes @electron/fuses write --app $appDir EnableEmbeddedAsarIntegrityValidation=off *> $null }
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
    # Piped install (irm | iex) - fetch a copy so the updater can re-run it.
    Info "Fetching script for the auto-updater"
    try { Invoke-WebRequest -UseBasicParsing -Uri $RawUrl -OutFile $SelfCopy }
    catch { Info "note: couldn't fetch the updater script; auto-update disabled (re-run the installer after app updates)"; return }
  }

  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfCopy`" -Auto"
  # Fire on logon, and daily as a backstop. (Electron updates land in-place or in
  # a new version dir; -Auto compares versions and rebuilds only when needed.)
  $t1 = New-ScheduledTaskTrigger -AtLogOn
  $t2 = New-ScheduledTaskTrigger -Daily -At 3am
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  # Register as an interactive, limited (non-elevated) task for the current user,
  # so it installs without administrator rights (the default principal targets the
  # machine task store and fails with "Access is denied" for a standard user).
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
  try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($t1, $t2) `
      -Settings $settings -Principal $principal -Force `
      -Description 'Rebuilds the ChatGPT RTL copy after the app updates.' | Out-Null
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

  # Windows locks the files of a running app, so if the RTL copy is open the
  # delete below silently skips its locked files and leaves a half-removed
  # folder behind. Close the running RTL copy first, then delete.
  $rtlPrefix = (Resolve-Path $DestRoot -ErrorAction SilentlyContinue).Path
  if ($rtlPrefix) {
    $rtlProcs = Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(?i)^(ChatGPT|codex)$' -and $_.Path -and
                     $_.Path.StartsWith($rtlPrefix, [StringComparison]::OrdinalIgnoreCase) }
    if ($rtlProcs) {
      Info "Closing the running ChatGPT RTL copy"
      $rtlProcs | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
      Start-Sleep -Seconds 2
      $rtlProcs | Where-Object { -not $_.HasExited } | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      Start-Sleep -Seconds 1
    }
  }

  Info "Removing $DestRoot"
  Remove-Tree $DestRoot
  Remove-Item -Force $ShortcutPath -ErrorAction SilentlyContinue
  Remove-Tree $SupportDir

  if (Test-Path $DestRoot) {
    Info "note: some files under $DestRoot could not be removed. Close any ChatGPT RTL window and run -Restore again."
  } else {
    Ok "Restored - the original ChatGPT app was never modified."
  }
}

# The RTL copy keeps the original app's identity (productName "Codex"), so it
# shares the same userData directory and therefore the same Electron
# single-instance lock. If the original app is already running when the RTL copy
# launches, Electron hands the launch off to the original window and the RTL copy
# quits immediately - the user sees the unpatched app and no RTL. Closing the
# original first is the only way the RTL copy can take the lock and apply RTL.
function Stop-OriginalInstances {
  $rtlPrefix = (Resolve-Path $DestRoot -ErrorAction SilentlyContinue).Path
  $running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '(?i)^(ChatGPT|codex)$' -and $_.Path } |
    Where-Object { -not ($rtlPrefix -and $_.Path.StartsWith($rtlPrefix, [StringComparison]::OrdinalIgnoreCase)) }
  if (-not $running) { return $true }

  if (-not $CloseOriginal) {
    Write-Host ""
    Write-Host "The original ChatGPT/Codex app is running. It holds the single-instance" -ForegroundColor Yellow
    Write-Host "lock, so the RTL copy cannot open with RTL until it is closed." -ForegroundColor Yellow
    $ans = Read-Host "Close the original app now? (unsaved work in it will be lost) [y/N]"
    if ($ans -notmatch '(?i)^y') {
      Info "Leaving the original running. Launch 'ChatGPT RTL' after you close it manually."
      return $false
    }
  }

  Info "Closing the original ChatGPT/Codex app"
  $running | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
  Start-Sleep -Seconds 2
  $running | Where-Object { -not $_.HasExited } | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
  return $true
}

# --------------------------------- dispatch ----------------------------------
if ($Restore) { Invoke-Restore; return }
if ($Auto)    { Invoke-Auto;    return }

Build
if (-not $NoWatch) { Install-Watch }
$closed = Stop-OriginalInstances
if ($closed -and (Test-Path $LauncherPath)) {
  Info "Launching ChatGPT RTL"
  # Launch through the identity-aware launcher (same path the shortcut uses).
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Start-Process $psExe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherPath`""
} else {
  Info "Skipping launch. Start 'ChatGPT RTL' from the desktop shortcut once the original is closed."
}
Ok "Done. Type Hebrew in Work or Codex mode to see RTL alignment."
