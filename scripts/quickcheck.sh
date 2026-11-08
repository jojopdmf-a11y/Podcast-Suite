#!/bin/zsh
# Builds PodLeveler and Pod Lounge, clicks through the loudness checks, then
# deletes everything that run created. Exit 0 means every check passed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="${HOME}/Desktop/PodStudio-QuickCheck-Results"
WORK=""
STAMP=""
DISK_BEFORE=""
DISK_AFTER=""
XCODE_STATUS=1
ISOLATION_OK=0
ISOLATION_DETAIL="Preferences were not compared."
CRASH_DETAIL=""
LOG_TAIL=""
BLOCKED=0
FINALIZED=0
OVERALL="FAIL"

disk_free_bytes() {
  df -k "${HOME}" | awk 'NR==2 { printf "%.0f\n", $4 * 1024 }'
}

format_bytes() {
  awk -v bytes="$1" 'BEGIN {
    printf "%.2f GB (%s bytes)", bytes / 1024 / 1024 / 1024, bytes
  }'
}

hash_path() {
  local target="$1"
  local dest="$2"
  if [[ ! -e "$target" ]]; then
    print "absent" > "$dest"
    return
  fi
  if [[ -f "$target" ]]; then
    {
      shasum -a 256 "$target"
      stat -f 'mtime %m' "$target"
    } > "$dest"
    return
  fi
  {
    find "$target" -type f | LC_ALL=C sort | while IFS= read -r file; do
      shasum -a 256 "$file"
      stat -f 'mtime %m %N' "$file"
    done
  } > "$dest"
}

snapshot_user_state() {
  local dest="$1"
  mkdir -p "$dest"
  hash_path "${HOME}/Library/Preferences/com.cougarcalc.lilleveler.plist" "$dest/leveler-prefs"
  hash_path "${HOME}/Library/Preferences/com.cougarcalc.podlounge.plist" "$dest/lounge-prefs"
  hash_path "${HOME}/Library/Saved Application State/com.cougarcalc.lilleveler.savedState" "$dest/leveler-saved"
  hash_path "${HOME}/Library/Saved Application State/com.cougarcalc.podlounge.savedState" "$dest/lounge-saved"
  hash_path "${HOME}/Library/Application Support/CougarCalc/LilLeveler" "$dest/presets"
  hash_path "${HOME}/Library/Containers/com.cougarcalc.lilleveler" "$dest/leveler-container"
  hash_path "${HOME}/Library/Containers/com.cougarcalc.podlounge" "$dest/lounge-container"
}

compare_user_state() {
  local before="$1"
  local after="$2"
  local name
  ISOLATION_OK=1
  ISOLATION_DETAIL="Preferences, presets, saved windows, and app containers were unchanged."
  for name in leveler-prefs lounge-prefs leveler-saved lounge-saved presets leveler-container lounge-container; do
    if ! cmp -s "$before/$name" "$after/$name"; then
      ISOLATION_OK=0
      ISOLATION_DETAIL="A real app file changed during the check: $name"
      return
    fi
  done
}

stop_test_apps() {
  [[ -n "$WORK" && -d "$WORK/apps" ]] || return 0
  pkill -f "$WORK/apps/" >/dev/null 2>&1 || true
}

forget_quickcheck_domains() {
  local domain
  for domain in \
    com.cougarcalc.quickcheck.podleveler \
    com.cougarcalc.quickcheck.podlounge \
    com.cougarcalc.quickcheck.host \
    com.cougarcalc.quickcheck.uitests
  do
    defaults delete "$domain" >/dev/null 2>&1 || true
    rm -f "${HOME}/Library/Preferences/${domain}.plist"
    rm -rf "${HOME}/Library/Saved Application State/${domain}.savedState"
    rm -rf "${HOME}/Library/Caches/${domain}"
    rm -rf "${HOME}/Library/Containers/${domain}"
    rm -rf "${HOME}/Library/HTTPStorages/${domain}"
    rm -rf "${HOME}/Library/WebKit/${domain}"
    rm -rf "${HOME}/Library/Application Support/${domain}"
  done
  rm -rf "${TMPDIR:-/tmp}/podleveler-uitest-presets"
  rm -f /tmp/podstudio-quickcheck-active.json
}

cleanup_generated() {
  stop_test_apps
  forget_quickcheck_domains
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf "$WORK"
  fi
}

write_results() {
  local staging checks_file summary report line pass name
  staging="$(mktemp -d /tmp/podstudio-quickcheck-report.XXXXXX)"
  checks_file="$staging/checks.json"
  if [[ -n "$WORK" && -f "$WORK/checks.json" ]]; then
    cp "$WORK/checks.json" "$checks_file"
  else
    print "[]" > "$checks_file"
  fi
  if [[ -n "$WORK" && -d "$WORK/screenshots" ]]; then
    mkdir -p "$staging/shots"
    local total=0 copied=0 img size
    for img in "$WORK"/screenshots/*.jpg(N); do
      size=$(stat -f %z "$img")
      (( copied >= 4 )) && break
      (( total + size > 5 * 1024 * 1024 )) && continue
      cp "$img" "$staging/shots/"
      (( total += size ))
      (( copied++ ))
    done
  fi
  if [[ -n "$WORK" && -f "$WORK/BLOCKED.txt" ]]; then
    BLOCKED=1
    mkdir -p "$ROOT/.ppjob"
    cp "$WORK/BLOCKED.txt" "$ROOT/.ppjob/QUICKCHECK-BLOCKED.txt"
  fi
  if [[ -n "$WORK" && -f "$WORK/xcodebuild.log" ]]; then
    LOG_TAIL="$(tail -n 30 "$WORK/xcodebuild.log")"
  fi

  cleanup_generated
  DISK_AFTER="$(disk_free_bytes)"

  local disk_ok=1 disk_note
  local delta=$(( DISK_BEFORE - DISK_AFTER ))
  if (( delta < 0 )); then delta=$(( -delta )); fi
  if (( delta > 200 * 1024 * 1024 )); then
    disk_ok=0
    disk_note="Free space moved by more than 200 MB."
  else
    disk_note="Free space stayed within 200 MB."
  fi

  local crash_ok=1
  if [[ -n "$CRASH_DETAIL" ]]; then
    crash_ok=0
  else
    CRASH_DETAIL="No new crash reports for these apps."
  fi

  OVERALL="PASS"
  if [[ "$ISOLATION_OK" != 1 || "$disk_ok" != 1 || "$crash_ok" != 1 || "$XCODE_STATUS" != 0 || "$BLOCKED" == 1 ]]; then
    OVERALL="FAIL"
  fi
  if grep -q '"pass" : false' "$checks_file"; then
    OVERALL="FAIL"
  fi

  summary="$staging/summary.txt"
  {
    print "Pod Studio quick check"
    print "$(date "+%A, %B %d, %Y")"
    print ""
    print "Disk free before: $(format_bytes "$DISK_BEFORE")"
    print "Disk free after:  $(format_bytes "$DISK_AFTER")"
    print "$disk_note"
    print ""
    awk '
      /"name"/ {
        name = $0
        sub(/.*"name" *: *"/, "", name)
        sub(/",?$/, "", name)
      }
      /"pass"/ {
        if ($0 ~ /true/) print "PASS  " name
        else print "FAIL  " name
      }
    ' "$checks_file"
    if [[ "$BLOCKED" == 1 ]] && ! grep -q '"name"' "$checks_file"; then
      print "FAIL  Click-through did not start"
      print "      macOS asked for your Mac password before the apps could be clicked."
    fi
    if [[ "$ISOLATION_OK" == 1 ]]; then
      print "PASS  Your preferences and presets were not changed"
    else
      print "FAIL  Your preferences and presets were not changed"
      print "      $ISOLATION_DETAIL"
    fi
    if [[ "$crash_ok" == 1 ]]; then
      print "PASS  No new crash reports"
    else
      print "FAIL  No new crash reports"
      print "      $CRASH_DETAIL"
    fi
    if [[ "$disk_ok" == 1 ]]; then
      print "PASS  Disk free space stayed within 200 MB"
    else
      print "FAIL  Disk free space stayed within 200 MB"
    fi
    print ""
    print "Overall: $OVERALL"
    if [[ "$BLOCKED" == 1 ]]; then
      print ""
      print "macOS is waiting for a permission click. The steps are in .ppjob/QUICKCHECK-BLOCKED.txt."
    fi
    if [[ "$OVERALL" != "PASS" && -n "$LOG_TAIL" ]]; then
      print ""
      print "Last lines from the test log:"
      print "$LOG_TAIL"
    fi
  } > "$summary"

  report="$staging/report.json"
  {
    print "{"
    print "  \"overall\": \"$OVERALL\","
    print "  \"diskFreeBytesBefore\": $DISK_BEFORE,"
    print "  \"diskFreeBytesAfter\": $DISK_AFTER,"
    print "  \"diskNote\": \"$disk_note\","
    print "  \"isolation\": \"$([[ "$ISOLATION_OK" == 1 ]] && print PASS || print FAIL)\","
    print "  \"isolationDetail\": \"${ISOLATION_DETAIL//\"/\\\"}\","
    print "  \"crashes\": \"${CRASH_DETAIL//\"/\\\"}\","
    print "  \"checks\":"
    cat "$checks_file"
    print "}"
  } > "$report"

  rm -rf "$RESULTS"
  mkdir -p "$RESULTS"
  cp "$summary" "$RESULTS/summary.txt"
  cp "$report" "$RESULTS/report.json"
  if [[ -d "$staging/shots" ]]; then
    local shot
    for shot in "$staging"/shots/*.jpg(N); do
      cp "$shot" "$RESULTS/"
    done
  fi
  rm -rf "$staging"
  print ""
  cat "$RESULTS/summary.txt"
}

finalize() {
  [[ "$FINALIZED" == 1 ]] && return
  FINALIZED=1
  set +e
  write_results
  exit "$([[ "$OVERALL" == "PASS" ]] && print 0 || print 1)"
}
trap finalize EXIT

DISK_BEFORE="$(disk_free_bytes)"
WORK="$(mktemp -d /tmp/podstudio-quickcheck.XXXXXX)"
STAMP="$WORK/started"
touch "$STAMP"
mkdir -p "$WORK/apps" "$WORK/audio" "$WORK/export" "$WORK/project" \
  "$WORK/presets-leveler" "$WORK/presets-lounge" "$WORK/screenshots" "$WORK/snapshot-before"
snapshot_user_state "$WORK/snapshot-before"

print "Building PodLeveler..."
if ! SKIP_REVEAL=1 "$ROOT/LilLeveler/app/scripts/build_app.sh" >"$WORK/build-leveler.log" 2>&1; then
  LOG_TAIL="$(tail -n 30 "$WORK/build-leveler.log")"
  print "PodLeveler did not build."
  exit 1
fi
print "Building Pod Lounge..."
if ! SKIP_REVEAL=1 "$ROOT/PodLounge/app/scripts/build_app.sh" >"$WORK/build-lounge.log" 2>&1; then
  LOG_TAIL="$(tail -n 30 "$WORK/build-lounge.log")"
  print "Pod Lounge did not build."
  exit 1
fi

ditto "$ROOT/LilLeveler/dist/PodLeveler.app" "$WORK/apps/PodLeveler.app"
ditto "$ROOT/PodLounge/dist/PodLounge.app" "$WORK/apps/PodLounge.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.cougarcalc.quickcheck.podleveler" "$WORK/apps/PodLeveler.app/Contents/Info.plist" || exit 1
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.cougarcalc.quickcheck.podlounge" "$WORK/apps/PodLounge.app/Contents/Info.plist" || exit 1
codesign --force --deep --sign - "$WORK/apps/PodLeveler.app" || exit 1
codesign --force --deep --sign - "$WORK/apps/PodLounge.app" || exit 1
xattr -dr com.apple.quarantine "$WORK/apps/PodLeveler.app" >/dev/null 2>&1 || true
xattr -dr com.apple.quarantine "$WORK/apps/PodLounge.app" >/dev/null 2>&1 || true

cat > "$WORK/config.json" <<EOF
{
  "levelerApp": "$WORK/apps/PodLeveler.app",
  "loungeApp": "$WORK/apps/PodLounge.app",
  "audioA": "$WORK/audio/QuickCheck-A.wav",
  "audioB": "$WORK/audio/QuickCheck-B.wav",
  "exportDir": "$WORK/export",
  "project": "$WORK/project/QuickCheck.podlounge",
  "presetsLeveler": "$WORK/presets-leveler",
  "presetsLounge": "$WORK/presets-lounge",
  "checks": "$WORK/checks.json",
  "screenshots": "$WORK/screenshots",
  "blocked": "$WORK/BLOCKED.txt"
}
EOF
cp "$WORK/config.json" /tmp/podstudio-quickcheck-active.json
export QUICKCHECK_CONFIG="$WORK/config.json"

print "Clicking through PodLeveler and Pod Lounge..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project "$ROOT/QuickCheck/QuickCheck.xcodeproj" \
    -scheme QuickCheck \
    -destination "platform=macOS" \
    -derivedDataPath "$WORK/DerivedData" \
    -resultBundlePath "$WORK/Result.xcresult" \
    -parallel-testing-enabled NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGN_IDENTITY="-" \
    >"$WORK/xcodebuild.log" 2>&1
XCODE_STATUS=$?

if [[ -f "$WORK/xcodebuild.log" ]] && grep -q "enabling automation mode" "$WORK/xcodebuild.log"; then
  cat > "$WORK/BLOCKED.txt" <<'EOF'
macOS stopped the quick check before it could click anything.

A password window should appear. It is asking to turn on UI automation. It may mention testmanagerd, Xcode, or QuickCheckUITests-Runner.

1. Double-click Run QuickCheck.command again.
2. As soon as the password window appears, type the password you use to log in to this Mac.
3. Click Allow. If the button says OK instead of Allow, click OK.
4. Do not click Cancel or Deny. The window stays up for about a minute.
5. If a second window asks about Accessibility or Automation, click Allow there too.
6. Leave the check running. It continues on its own after you allow it.

If no password window appears, open Terminal, run automationmodetool, and run the quick check again. This Mac currently requires that password before UI automation can start.
EOF
fi

mkdir -p "$WORK/snapshot-after"
snapshot_user_state "$WORK/snapshot-after"
compare_user_state "$WORK/snapshot-before" "$WORK/snapshot-after"

CRASH_FILES=()
if [[ -d "${HOME}/Library/Logs/DiagnosticReports" ]]; then
  while IFS= read -r -d '' report; do
    CRASH_FILES+=("$report")
  done < <(find "${HOME}/Library/Logs/DiagnosticReports" -type f -newer "$STAMP" \( \
    -iname '*LilLeveler*' -o -iname '*PodLeveler*' -o -iname '*PodLounge*' -o -iname '*QuickCheck*' \
  \) -print0)
fi
if (( ${#CRASH_FILES[@]} > 0 )); then
  CRASH_DETAIL="New crash report: ${CRASH_FILES[*]}"
fi

exit "$XCODE_STATUS"
