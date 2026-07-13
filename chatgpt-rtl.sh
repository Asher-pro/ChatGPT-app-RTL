#!/usr/bin/env bash
#
# chatgpt-rtl.sh — build a right-to-left (RTL) copy of the ChatGPT desktop app.
#
# Produces ~/Applications/ChatGPT-RTL.app: a standalone, re-signed copy of the
# installed ChatGPT app with smart bidirectional text support injected into every
# window (both "ChatGPT Work" and "Codex" modes). The original app is never
# touched and keeps updating normally. A LaunchAgent rebuilds the RTL copy
# automatically whenever the original app is updated.
#
# Usage:
#   bash chatgpt-rtl.sh            # build the RTL app + install the auto-updater
#   bash chatgpt-rtl.sh --no-watch # build without the auto-updater
#   bash chatgpt-rtl.sh --restore  # remove the RTL app + updater
#   bash chatgpt-rtl.sh --auto     # (internal) rebuild only if the app changed
#
set -euo pipefail

# ------------------------------- configuration -------------------------------
SRC_APP="/Applications/ChatGPT.app"
DEST_APP="$HOME/Applications/ChatGPT-RTL.app"
DISPLAY_NAME="ChatGPT RTL"
SUPPORT_DIR="$HOME/.chatgpt-rtl"
SELF_COPY="$SUPPORT_DIR/chatgpt-rtl.sh"
VERSION_FILE="$SUPPORT_DIR/patched-version"
LOG_FILE="$SUPPORT_DIR/updater.log"
AGENT_LABEL="com.chatgpt-rtl.updater"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

ACTION="install"
DO_WATCH=1
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --restore|--uninstall) ACTION="restore" ;;
    --auto)                ACTION="auto"; DO_WATCH=0; QUIET=1 ;;
    --no-watch)            DO_WATCH=0 ;;
    -h|--help)             ACTION="help" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --------------------------------- helpers -----------------------------------
c_blue=$'\033[34m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
info() { [ "$QUIET" = 1 ] || printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { [ "$QUIET" = 1 ] || printf '%s ok%s %s\n' "$c_green" "$c_off" "$*"; }
die()  { printf '%serror%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Locate the @electron/asar module (populated in the npx cache on first use) and
# echo the node_modules dir to put on NODE_PATH so we can call its Node API.
locate_asar_node_path() {
  npx --yes @electron/asar --version >/dev/null 2>&1 \
    || die "could not run @electron/asar (Node + one-time network access required)"
  local d
  d="$(find "$HOME/.npm/_npx" -type d -path '*/node_modules/@electron/asar' 2>/dev/null | head -1)"
  [ -n "$d" ] || die "could not locate the @electron/asar module"
  ( cd "$d/../.." && pwd )
}

# ----------------------------- the RTL loader --------------------------------
# Written verbatim into the app as a main-process module. It attaches to every
# web-contents and injects CSS + a small bidi tagger. insertCSS runs at the
# Electron layer, so it is not blocked by the page's Content-Security-Policy.
write_loader() {
  local dest="$1"
  cat > "$dest" <<'RTL_LOADER'
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
        // Only look at newly-added subtrees, coalesced during idle time. We do NOT
        // observe characterData — streaming a reply mutates text constantly, and
        // per-character rescans would peg the renderer. New tokens arrive as added
        // nodes (childList), which we catch; already-marked elements are skipped.
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
RTL_LOADER
}

# --------------------------- re-signing (ad-hoc) -----------------------------
# The original app is signed with a single Team ID and uses hardened runtime with
# Library Validation. Any change to the bundle invalidates that signature, and an
# ad-hoc re-sign gives components mismatched (empty) Team IDs — so every nested
# framework, helper app, and native library must be re-signed consistently
# inside-out, and Library Validation must be disabled via entitlement.
resign_app() {
  local app="$1" work="$2"
  local ent="$work/entitlements.plist"

  codesign -d --entitlements - --xml "$SRC_APP" >"$ent" 2>/dev/null || : >"$ent"
  if [ -s "$ent" ]; then
    for k in com.apple.application-identifier com.apple.developer.team-identifier \
             keychain-access-groups com.apple.security.application-groups; do
      /usr/libexec/PlistBuddy -c "Delete :$k" "$ent" 2>/dev/null || true
    done
  else
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict></dict></plist>' >"$ent"
  fi
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ent" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :com.apple.security.cs.disable-library-validation true" "$ent"

  local sign_ent=(codesign --force --options runtime --entitlements "$ent" --sign -)

  # 1) leaf libraries — no entitlements
  local f
  while IFS= read -r -d '' f; do codesign --force --sign - "$f" 2>/dev/null || true; done \
    < <(find "$app" \( -name '*.dylib' -o -name '*.node' \) -type f -print0)

  # 2) nested helper .app bundles (deeper than the frameworks that contain them)
  while IFS= read -r -d '' f; do "${sign_ent[@]}" "$f" 2>/dev/null || "${sign_ent[@]}" "$f"; done \
    < <(find "$app/Contents/Frameworks" -type d -name '*.app' -print0)

  # 3) standalone Mach-O executables shipped in Resources
  for f in codex codex-code-mode-host codex_chronicle rg; do
    [ -f "$app/Contents/Resources/$f" ] && { "${sign_ent[@]}" "$app/Contents/Resources/$f" 2>/dev/null || true; }
  done

  # 4) frameworks (re-seal, now that their contents are consistently signed)
  while IFS= read -r -d '' f; do "${sign_ent[@]}" "$f" 2>/dev/null || "${sign_ent[@]}" "$f"; done \
    < <(find "$app/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0)

  # 5) the outer bundle last
  "${sign_ent[@]}" "$app" || die "codesign failed on the app bundle"
}

# ------------------------------- core build ----------------------------------
build() {
  [ -d "$SRC_APP" ] || die "ChatGPT.app not found at $SRC_APP — install ChatGPT first."
  need node; need npx; need ditto; need codesign
  [ -x /usr/libexec/PlistBuddy ] || die "PlistBuddy not found (install Xcode Command Line Tools)"

  local asar_np; asar_np="$(locate_asar_node_path)"

  info "Copying app → $DEST_APP"
  mkdir -p "$(dirname "$DEST_APP")"
  rm -rf "$DEST_APP"
  ditto "$SRC_APP" "$DEST_APP"

  local res="$DEST_APP/Contents/Resources"
  local asar="$res/app.asar"
  local unpacked="$res/app.asar.unpacked"
  local plist="$DEST_APP/Contents/Info.plist"
  [ -f "$asar" ] || die "app.asar not found — the app layout may have changed."

  local work; work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN

  info "Extracting app.asar"
  npx --yes @electron/asar extract "$asar" "$work/app"
  # Overlay the authoritative native-module tree — asar extract does not always
  # reproduce every unpacked sidecar file.
  [ -d "$unpacked" ] && ditto "$unpacked" "$work/app"

  local main_rel main_file
  main_rel="$(node -p "require('$work/app/package.json').main")"
  main_file="$work/app/$main_rel"
  [ -f "$main_file" ] || die "main entry '$main_rel' not found in app.asar"

  info "Injecting RTL loader into $main_rel"
  write_loader "$work/app/$(dirname "$main_rel")/__cgpt_rtl__.js"
  if ! grep -q '__CGPT_RTL__' "$main_file"; then
    { printf "/* __CGPT_RTL__ */try{require('./__cgpt_rtl__.js');}catch(e){}\n"; cat "$main_file"; } > "$main_file.new"
    mv "$main_file.new" "$main_file"
  fi

  # Build the unpack-dir glob from the packages that were unpacked originally,
  # e.g. node_modules/@(better-sqlite3|node-pty|...). Combined with **/*.node
  # this keeps every native module loadable after repacking.
  local names=() e
  if [ -d "$unpacked/node_modules" ]; then
    for e in "$unpacked/node_modules"/*; do [ -e "$e" ] && names+=("$(basename "$e")"); done
  fi
  local glob="" oldifs="$IFS"
  if [ "${#names[@]}" -gt 0 ]; then IFS='|'; glob="node_modules/@(${names[*]})"; IFS="$oldifs"; fi

  info "Repacking app.asar (preserving native modules)"
  rm -f "$asar"; rm -rf "$unpacked"
  NODE_PATH="$asar_np" node -e '
    const asar = require("@electron/asar");
    const [src, out, unpackDir] = process.argv.slice(1);
    const opts = { unpack: "**/*.node" };
    if (unpackDir) opts.unpackDir = unpackDir;
    asar.createPackageWithOptions(src, out, opts)
      .then(() => process.exit(0))
      .catch((err) => { console.error(err); process.exit(1); });
  ' "$work/app" "$asar" "$glob" || die "asar repack failed"

  info "Updating ASAR integrity hash"
  local newhash
  newhash="$(NODE_PATH="$asar_np" node -e '
    const asar = require("@electron/asar"), crypto = require("crypto");
    process.stdout.write(crypto.createHash("sha256").update(asar.getRawHeader(process.argv[1]).headerString).digest("hex"));
  ' "$asar")"
  [ -n "$newhash" ] || die "could not compute new asar hash"
  /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $newhash" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $newhash" "$plist"

  info "Branding as \"$DISPLAY_NAME\""
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" "$plist"

  info "Re-signing (ad-hoc, inside-out)"
  resign_app "$DEST_APP" "$work"
  xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

  # Record the version we patched so the auto-updater can detect changes.
  mkdir -p "$SUPPORT_DIR"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC_APP/Contents/Info.plist" >"$VERSION_FILE" 2>/dev/null || true
  ok "Built $DEST_APP"
}

# --------------------------- auto-update watcher -----------------------------
install_watch() {
  # Keep an on-disk copy of this script so the LaunchAgent can re-run it.
  mkdir -p "$SUPPORT_DIR"
  if [ -f "${BASH_SOURCE[0]}" ]; then
    cp "${BASH_SOURCE[0]}" "$SELF_COPY"
  elif [ -f "$0" ]; then
    cp "$0" "$SELF_COPY"
  else
    info "note: run from a saved file to enable auto-updates (piped stdin can't self-install the watcher)"
    return 0
  fi
  chmod +x "$SELF_COPY"

  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF_COPY</string>
    <string>--auto</string>
  </array>
  <key>WatchPaths</key>
  <array><string>$SRC_APP/Contents/Info.plist</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>21600</integer>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null \
    || { launchctl unload "$AGENT_PLIST" 2>/dev/null || true; launchctl load -w "$AGENT_PLIST"; }
  ok "Installed auto-updater (rebuilds on app updates)"
}

auto() {
  # Rebuild only if the RTL copy is missing or the original app version changed.
  [ -d "$SRC_APP" ] || exit 0
  local cur prev=""
  cur="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC_APP/Contents/Info.plist" 2>/dev/null || true)"
  [ -f "$VERSION_FILE" ] && prev="$(cat "$VERSION_FILE" 2>/dev/null || true)"
  if [ ! -d "$DEST_APP" ] || [ "$cur" != "$prev" ]; then
    printf '[%s] rebuilding RTL app (was "%s", now "%s")\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$prev" "$cur"
    build
  fi
}

restore() {
  info "Removing auto-updater"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || launchctl unload "$AGENT_PLIST" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  info "Removing $DEST_APP"
  rm -rf "$DEST_APP"
  rm -rf "$SUPPORT_DIR"
  ok "Restored — the original ChatGPT app was never modified."
}

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --------------------------------- dispatch ----------------------------------
case "$ACTION" in
  help)    usage ;;
  restore) restore ;;
  auto)    auto ;;
  install)
    build
    [ "$DO_WATCH" = 1 ] && install_watch || true
    info "Opening $DISPLAY_NAME (quit the original ChatGPT first if it's running)"
    open "$DEST_APP" 2>/dev/null || true
    ok "Done. Type Hebrew in Work or Codex mode to see RTL alignment."
    ;;
esac
