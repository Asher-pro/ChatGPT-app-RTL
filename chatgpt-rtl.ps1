<#
  chatgpt-rtl.ps1 - add right-to-left (RTL) support to the ChatGPT/Codex desktop app on Windows.

  The unified app ships as an MSIX package under C:\Program Files\WindowsApps.
  Its native code needs the MSIX *package identity* to start, so a separate copy
  cannot run it and cannot load a patched app.asar. Therefore this patches the app
  IN PLACE inside its install folder (the same approach the Claude Desktop patcher
  uses), which keeps the package identity intact and makes the app load our patched
  code directly. Requires administrator rights (it elevates automatically) and takes
  ownership of the files it changes. Every changed file is backed up; -Restore puts
  the originals back. A scheduled task re-applies the patch after the app updates
  (or if Windows reverts it).

  Usage (Windows PowerShell 5.1):
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1              # patch + auto-updater
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -NoWatch     # patch only
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -CloseApp    # close the app without prompting
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -Restore     # undo (restore originals)
    powershell -ExecutionPolicy Bypass -File chatgpt-rtl.ps1 -Auto        # (internal) re-patch if changed

  Prerequisites: Node.js (provides `node` and `npx`) on PATH.
#>
[CmdletBinding()]
param(
  [switch]$Restore,
  [switch]$NoWatch,
  [switch]$Auto,
  [switch]$CloseApp
)

$ErrorActionPreference = 'Stop'

# When piped into PowerShell (irm | iex) the session runs under the machine's
# default policy, which is usually Restricted and blocks npm/npx (.ps1 shims).
# Relax the policy for THIS process only: no admin required, not persisted.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch {}

# ------------------------------- configuration -------------------------------
$SupportDir      = Join-Path $env:LOCALAPPDATA 'chatgpt-rtl'
$SelfCopy        = Join-Path $SupportDir 'chatgpt-rtl.ps1'
$BackupDir       = Join-Path $SupportDir 'backup'
$BkAsar          = Join-Path $BackupDir 'app.asar'
$BkUnpacked      = Join-Path $BackupDir 'app.asar.unpacked'
$BkExe           = Join-Path $BackupDir 'original.exe'
$VersionFile     = Join-Path $SupportDir 'patched-version'
$OrigHashFile    = Join-Path $SupportDir 'orig-hash.txt'
$PatchedHashFile = Join-Path $SupportDir 'patched-hash.txt'
$LogFile         = Join-Path $SupportDir 'updater.log'
$TaskName        = 'ChatGPT RTL Updater'
$RawUrl          = if ($env:CHATGPT_RTL_RAW_URL) { $env:CHATGPT_RTL_RAW_URL } else { 'https://raw.githubusercontent.com/Asher-pro/ChatGPT-app-RTL/main/chatgpt-rtl.ps1' }
$AdminsSid       = '*S-1-5-32-544'   # BUILTIN\Administrators, locale-independent

function Info($m) { if (-not $Auto) { Write-Host "==> $m" -ForegroundColor Cyan } }
function Ok($m)   { if (-not $Auto) { Write-Host " ok $m" -ForegroundColor Green } }
function Die($m)  { Write-Host "error $m" -ForegroundColor Red; exit 1 }

# Windows PowerShell 5.1 turns any output a native tool writes to stderr into a
# terminating error while $ErrorActionPreference is 'Stop' (e.g. npm/npx print an
# "npm notice" banner to stderr). Run node/npx/takeown/icacls/robocopy through this
# wrapper so their diagnostics don't abort; check $LASTEXITCODE for real failures.
function Use-NativeErrors {
  param([Parameter(Mandatory)][scriptblock]$Command)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Command } finally { $ErrorActionPreference = $prev }
}

# Some app trees nest node_modules past the 260-char MAX_PATH limit, which
# Remove-Item cannot delete. robocopy is long-path aware, so mirroring an empty
# directory over the target clears it; then the empty top folder deletes normally.
function Remove-Tree {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return } catch {}
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try {
    $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('cgptrtl_empty_' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $empty -Force -ErrorAction Stop | Out-Null
    Use-NativeErrors { & robocopy $empty $Path /MIR /NFL /NDL /NJH /NJS /NP *> $null }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
  } catch {}
}

# ------------------------------ elevation ------------------------------------
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
   ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# Patching files under WindowsApps requires administrator rights. Relaunch this
# script elevated, preserving the switches. When run piped (no script file on
# disk) we download a copy to %TEMP% so the elevated instance has something to run.
function Invoke-Elevated {
  $sp = $PSCommandPath
  if (-not $sp -or -not (Test-Path $sp)) {
    $sp = Join-Path $env:TEMP 'chatgpt-rtl.ps1'
    try { Invoke-WebRequest -UseBasicParsing -Uri $RawUrl -OutFile $sp } catch { Die "could not download the script to elevate: $($_.Exception.Message)" }
  }
  $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$sp`"")
  foreach ($k in $PSBoundParameters.Keys) {
    if ($PSBoundParameters[$k] -is [switch] -and $PSBoundParameters[$k]) { $argl += "-$k" }
  }
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  try { Start-Process -FilePath $ps -Verb RunAs -ArgumentList $argl }
  catch { Die "administrator rights are required. Approve the UAC prompt, or run PowerShell as Administrator." }
}

# ----------------------------- locate the app --------------------------------
# Returns the app directory that contains resources\app.asar plus the launcher exe.
function Find-AppDir {
  $candidates = @()
  $candidates += Join-Path $env:LOCALAPPDATA 'Programs\ChatGPT'
  $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Codex'
  $candidates += Join-Path ${env:ProgramFiles} 'ChatGPT'
  try {
    Get-AppxPackage -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(?i)ChatGPT|OpenAI|Codex' -and $_.InstallLocation } |
      ForEach-Object { $candidates += $_.InstallLocation }
  } catch {}

  foreach ($dir in $candidates) {
    if (-not $dir) { continue }
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
  Use-NativeErrors { & npx --yes @electron/asar --version *> $null }
  if ($LASTEXITCODE -ne 0) { Die 'could not run @electron/asar (Node + one-time network access required)' }
  $npxCache = Join-Path $env:USERPROFILE 'AppData\Local\npm-cache\_npx'
  if (-not (Test-Path $npxCache)) { $npxCache = Join-Path $env:APPDATA 'npm-cache\_npx' }
  $mod = Get-ChildItem -Path $npxCache -Recurse -Directory -Filter 'asar' -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -match '\\@electron\\asar$' } | Select-Object -First 1
  if (-not $mod) { Die 'could not locate the @electron/asar module' }
  return (Split-Path (Split-Path $mod.FullName -Parent) -Parent)   # ...\node_modules
}

# --------------------------- ownership / process -----------------------------
function Grant-WriteFile($path) {
  Use-NativeErrors { & takeown /f "$path" /d y *> $null }
  Use-NativeErrors { & icacls "$path" /grant "$AdminsSid`:(F)" /c *> $null }
}
function Grant-WriteTree($path) {
  Use-NativeErrors { & takeown /f "$path" /r /d y *> $null }
  Use-NativeErrors { & icacls "$path" /grant "$AdminsSid`:(OI)(CI)F" /t /c *> $null }
}

# The app's files are locked while it runs, so it must be closed to patch it.
function Close-App {
  $procs = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '(?i)^(ChatGPT|codex)$' -and $_.Path }
  if (-not $procs) { return $true }
  if (-not $CloseApp -and -not $Auto) {
    Write-Host ""
    Write-Host "ChatGPT/Codex is running and must be closed to patch it." -ForegroundColor Yellow
    $ans = Read-Host "Close it now? (unsaved work will be lost) [y/N]"
    if ($ans -notmatch '(?i)^y') { return $false }
  }
  Info "Closing ChatGPT/Codex"
  $procs | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
  Start-Sleep -Seconds 2
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '(?i)^(ChatGPT|codex)$' } |
    ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
  Start-Sleep -Seconds 1
  return $true
}

# ------------------------------ the RTL loader -------------------------------
# Identical behaviour to the macOS build: attach to every web-contents and inject
# CSS + a small bidi tagger. insertCSS runs at the Electron layer, bypassing CSP.
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

function Get-AsarHeaderHash($asarPath, $nodePath) {
  $env:NODE_PATH = $nodePath
  # Single quotes inside the JS: PowerShell 5.1 strips embedded double quotes when
  # passing a string as a native-command argument, which would corrupt the script.
  $nodeScript = "const a=require('@electron/asar'),c=require('crypto');process.stdout.write(c.createHash('sha256').update(a.getRawHeader(process.argv[1]).headerString).digest('hex'));"
  $h = Use-NativeErrors { & node -e $nodeScript $asarPath }
  Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue
  return $h
}

# Electron validates the app.asar header hash against a value baked into the exe.
# Replace the old hash with the new one; if it isn't found, fall back to disabling
# the integrity fuse. The exe passed in must be pristine (embeds the original hash).
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
    Info "note: could not adjust the integrity fuse; if the app refuses to start, this version needs the fuse-flip step"
  }
}

# --------------------------- patch (in place) --------------------------------
function Invoke-Patch {
  $appDir = Find-AppDir
  if (-not $appDir) { Die "ChatGPT install not found. Install the ChatGPT desktop app first." }
  $resources = Join-Path $appDir 'resources'
  $asar      = Join-Path $resources 'app.asar'
  $unpacked  = Join-Path $resources 'app.asar.unpacked'
  if (-not (Test-Path $asar)) { Die "app.asar not found under $resources" }
  $exe = Get-MainExe $appDir
  if (-not $exe) { Die "could not find the ChatGPT executable in $appDir" }
  $ver = (Get-ItemProperty $exe.FullName).VersionInfo.ProductVersion
  Info "App: $appDir  (v$ver)"

  $nodePath = Get-AsarNodePath

  if (-not (Close-App)) { Die "the app must be closed to patch it. Re-run and choose Yes (or pass -CloseApp)." }

  New-Item -ItemType Directory -Force -Path $SupportDir | Out-Null

  $curHash     = Get-AsarHeaderHash $asar $nodePath
  $savedOrig   = if (Test-Path $OrigHashFile)    { (Get-Content $OrigHashFile -Raw).Trim() }    else { '' }
  $savedPatch  = if (Test-Path $PatchedHashFile) { (Get-Content $PatchedHashFile -Raw).Trim() } else { '' }
  $havePristine   = (Test-Path $BkAsar) -and $savedOrig
  $isKnownPatched = $savedPatch -and ($curHash -eq $savedPatch)
  $isKnownOrig    = $savedOrig  -and ($curHash -eq $savedOrig)

  # Idempotency for the auto-updater: nothing to do if already our patch + same version.
  if ($Auto -and $isKnownPatched -and (Test-Path $VersionFile) -and ((Get-Content $VersionFile -Raw).Trim() -eq $ver)) {
    return
  }

  Info "Taking ownership of app files"
  Grant-WriteTree $resources
  Grant-WriteFile $exe.FullName

  # (Re)create the pristine backup when the in-place asar is an original we don't
  # yet have backed up - i.e. a fresh install or a new version after an update.
  if (-not $havePristine -or (-not $isKnownPatched -and -not $isKnownOrig)) {
    Info "Backing up original files"
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Copy-Item -LiteralPath $asar -Destination $BkAsar -Force
    Remove-Tree $BkUnpacked
    if (Test-Path $unpacked) { Use-NativeErrors { & robocopy $unpacked $BkUnpacked /MIR /NFL /NDL /NJH /NJS /NP *> $null } }
    Copy-Item -LiteralPath $exe.FullName -Destination $BkExe -Force
    $curHash | Out-File -Encoding ascii $OrigHashFile
    $savedOrig = $curHash
  }
  $oldHash = $savedOrig

  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("cgptrtl_" + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  try {
    Info "Extracting app.asar (from pristine backup)"
    Use-NativeErrors { & npx --yes @electron/asar extract "$BkAsar" (Join-Path $work 'app') }
    if ($LASTEXITCODE -ne 0) { Die "asar extract failed" }
    if (Test-Path $BkUnpacked) {
      Use-NativeErrors { & robocopy $BkUnpacked (Join-Path $work 'app') /E /NFL /NDL /NJH /NJS /NP *> $null }
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

    $glob = ''
    $nmDir = Join-Path $BkUnpacked 'node_modules'
    if (Test-Path $nmDir) {
      $names = (Get-ChildItem -Path $nmDir -Directory | ForEach-Object { $_.Name }) -join '|'
      if ($names) { $glob = "node_modules/@($names)" }
    }

    Info "Repacking app.asar in place (preserving native modules)"
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
    $env:NODE_PATH = $nodePath
    Use-NativeErrors { & node $packFile (Join-Path $work 'app') $asar $glob }
    Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { Die "asar repack failed (is the app closed and are the files writable?)" }

    Info "Updating ASAR integrity hash"
    $newHash = Get-AsarHeaderHash $asar $nodePath
    if (-not $newHash) { Die "could not compute new asar hash" }
    # Restore the pristine exe first, so the original hash is present to find/replace.
    Copy-Item -LiteralPath $BkExe -Destination $exe.FullName -Force
    Set-ExeAsarHash $exe.FullName $oldHash $newHash $appDir $nodePath

    $ver     | Out-File -Encoding ascii $VersionFile
    $newHash | Out-File -Encoding ascii $PatchedHashFile
    Ok "Patched in place: $appDir"
  } finally {
    Remove-Tree $work
    Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue
  }

  return $exe.FullName
}

# --------------------------- auto-update watcher -----------------------------
function Install-Watch {
  New-Item -ItemType Directory -Force -Path $SupportDir | Out-Null
  if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    Copy-Item -Force $PSCommandPath $SelfCopy
  } else {
    Info "Fetching script for the auto-updater"
    try { Invoke-WebRequest -UseBasicParsing -Uri $RawUrl -OutFile $SelfCopy }
    catch { Info "note: couldn't fetch the updater script; auto-update disabled (re-run the installer after updates)"; return }
  }

  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SelfCopy`" -Auto"
  # Logon + daily, and re-patch runs elevated (in-place patching needs admin).
  $t1 = New-ScheduledTaskTrigger -AtLogOn
  $t2 = New-ScheduledTaskTrigger -Daily -At 3am
  $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $me        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
  try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($t1, $t2) `
      -Settings $settings -Principal $principal -Force `
      -Description 'Re-applies the ChatGPT RTL patch after the app updates or is reverted.' | Out-Null
    Ok "Installed auto-updater (Scheduled Task '$TaskName')"
  } catch {
    Info "note: could not register the Scheduled Task ($($_.Exception.Message)). Re-run this script after each app update."
  }
}

function Invoke-Auto {
  $appDir = Find-AppDir
  if (-not $appDir) { return }
  $exe = Get-MainExe $appDir
  if (-not $exe) { return }
  $asar = Join-Path (Join-Path $appDir 'resources') 'app.asar'
  $ver  = (Get-ItemProperty $exe.FullName).VersionInfo.ProductVersion
  $prevVer = if (Test-Path $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { '' }
  $savedPatch = if (Test-Path $PatchedHashFile) { (Get-Content $PatchedHashFile -Raw).Trim() } else { '' }
  $curHash = try { Get-AsarHeaderHash $asar (Get-AsarNodePath) } catch { '' }
  # Re-patch when the app updated (version changed) or the patch was reverted
  # (in-place hash no longer matches ours, e.g. MSIX self-healing).
  if (($ver -ne $prevVer) -or (-not $savedPatch) -or ($curHash -ne $savedPatch)) {
    "[{0}] re-patching (ver '{1}'->'{2}', patched={3}, cur={4})" -f (Get-Date), $prevVer, $ver, $savedPatch, $curHash |
      Out-File -Append -Encoding utf8 $LogFile
    Invoke-Patch | Out-Null
  }
}

function Invoke-Restore {
  Info "Removing auto-updater"
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

  $appDir = Find-AppDir
  if ($appDir -and (Test-Path $BkAsar)) {
    if (-not (Close-App)) { Die "close the app first, then run -Restore again." }
    $resources = Join-Path $appDir 'resources'
    $asar      = Join-Path $resources 'app.asar'
    $unpacked  = Join-Path $resources 'app.asar.unpacked'
    $exe       = Get-MainExe $appDir
    Info "Restoring original files"
    Grant-WriteTree $resources
    if ($exe) { Grant-WriteFile $exe.FullName }
    Copy-Item -LiteralPath $BkAsar -Destination $asar -Force
    Remove-Tree $unpacked
    if (Test-Path $BkUnpacked) { Use-NativeErrors { & robocopy $BkUnpacked $unpacked /MIR /NFL /NDL /NJH /NJS /NP *> $null } }
    if ($exe -and (Test-Path $BkExe)) { Copy-Item -LiteralPath $BkExe -Destination $exe.FullName -Force }
    Ok "Restored the original app.asar and exe"
  } else {
    Info "No backup found - nothing to restore in the app folder."
  }
  Remove-Tree $SupportDir
  Ok "Done."
}

# --------------------------------- dispatch ----------------------------------
# Everything below needs administrator rights; elevate once, up front.
if (-not (Test-Admin)) {
  Info "Requesting administrator rights (approve the UAC prompt)..."
  Invoke-Elevated
  return
}

if ($Restore) { Invoke-Restore; return }
if ($Auto)    { Invoke-Auto;    return }

$exePath = Invoke-Patch
if (-not $NoWatch) { Install-Watch }
Info "Launching ChatGPT"
try { if ($exePath) { Start-Process $exePath } } catch {}
Ok "Done. Type Hebrew in Work or Codex mode to see RTL alignment."
