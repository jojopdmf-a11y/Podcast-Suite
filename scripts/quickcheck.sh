#!/bin/zsh
# Builds PodLeveler and Pod Lounge, clicks through the loudness checks, then
# deletes everything that run created. Exit 0 means every check passed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="${HOME}/GrokBot/QuickCheck-Results"
OLD_RESULTS="${HOME}/Desktop/PodStudio-QuickCheck-Results"
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
LEFTOVER_OK=0
LEFTOVER_DETAIL="Cleanup was not checked."
RUNNER_SCRATCH=""
typeset -a MUST_REMOVE
MUST_REMOVE=()
typeset -a QUICKCHECK_DOMAINS
QUICKCHECK_DOMAINS=(
  com.cougarcalc.quickcheck.podleveler
  com.cougarcalc.quickcheck.podlounge
  com.cougarcalc.quickcheck.host
  com.cougarcalc.quickcheck.uitests
  com.cougarcalc.quickcheck.uitests.xctrunner
)

disk_free_bytes() {
  df -k "${HOME}" | awk 'NR==2 { printf "%.0f\n", $4 * 1024 }'
}

remember() {
  local item="$1"
  [[ -n "$item" ]] || return 0
  MUST_REMOVE+=("$item")
}

json_escape() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/; }"
  text="${text//$'\r'/}"
  print -r -- "$text"
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
  for domain in "${QUICKCHECK_DOMAINS[@]}"; do
    defaults delete "$domain" >/dev/null 2>&1 || true
    rm -f "${HOME}/Library/Preferences/${domain}.plist"
    rm -f "${HOME}/Library/Preferences/ByHost/${domain}".*.plist(N)
    rm -rf "${HOME}/Library/Saved Application State/${domain}.savedState"
    rm -rf "${HOME}/Library/Caches/${domain}"
    rm -rf "${HOME}/Library/Containers/${domain}/Data"
    rm -rf "${HOME}/Library/Containers/${domain}" 2>/dev/null || true
    rm -rf "${HOME}/Library/HTTPStorages/${domain}"
    rm -rf "${HOME}/Library/WebKit/${domain}"
    rm -rf "${HOME}/Library/Application Support/${domain}"
  done
  rm -rf "${TMPDIR:-/tmp}/podleveler-uitest-presets"
  rm -f /tmp/podstudio-quickcheck-active.json
}

remember_created_paths() {
  local domain preset_root
  remember "$WORK"
  remember "$WORK/DerivedData"
  remember "$WORK/DerivedData/Build"
  remember "$WORK/Result.xcresult"
  remember "$WORK/export"
  remember "$WORK/audio"
  remember "$WORK/project"
  remember "$WORK/apps"
  remember "$WORK/presets-leveler"
  remember "$WORK/presets-lounge"
  remember "/tmp/podstudio-quickcheck-active.json"
  remember "$OLD_RESULTS"
  preset_root="${TMPDIR:-/tmp}"
  preset_root="${preset_root%/}"
  remember "$preset_root/podleveler-uitest-presets"
  for domain in "${QUICKCHECK_DOMAINS[@]}"; do
    remember "${HOME}/Library/Preferences/${domain}.plist"
    remember "${HOME}/Library/Saved Application State/${domain}.savedState"
    remember "${HOME}/Library/Caches/${domain}"
    remember "${HOME}/Library/HTTPStorages/${domain}"
    remember "${HOME}/Library/WebKit/${domain}"
    remember "${HOME}/Library/Application Support/${domain}"
  done
}

discover_runner_scratch() {
  local line scratch_path container found scratch
  RUNNER_SCRATCH=""
  if [[ -n "$WORK" && -f "$WORK/xcodebuild.log" ]]; then
    line="$(/usr/bin/grep 'QUICKCHECK_SCRATCH ' "$WORK/xcodebuild.log" | /usr/bin/tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      scratch_path="${line##*QUICKCHECK_SCRATCH }"
      scratch_path="${scratch_path%%$'\r'}"
      scratch_path="${scratch_path%%$'\n'}"
      if [[ "$scratch_path" == *"/podstudio-quickcheck" || "$scratch_path" == *"/podstudio-quickcheck/"* ]]; then
        RUNNER_SCRATCH="${scratch_path%/}"
      fi
    fi
  fi
  if [[ -z "$RUNNER_SCRATCH" || ! -e "$RUNNER_SCRATCH" ]]; then
    for container in "${HOME}/Library/Containers"/com.cougarcalc.quickcheck.*(N); do
      found="$(/usr/bin/find "$container" -path '*/podstudio-quickcheck/checks.json' -print 2>/dev/null | /usr/bin/head -n 1 || true)"
      if [[ -n "$found" ]]; then
        RUNNER_SCRATCH="$(dirname "$found")"
        break
      fi
      scratch="$container/Data/tmp/podstudio-quickcheck"
      if [[ -d "$scratch" ]]; then
        RUNNER_SCRATCH="$scratch"
        break
      fi
    done
  fi
  if [[ -z "$RUNNER_SCRATCH" || ! -e "$RUNNER_SCRATCH" ]]; then
    local tmp_root="${TMPDIR:-/tmp}"
    tmp_root="${tmp_root%/}"
    found="$(/usr/bin/find "$tmp_root" /tmp -maxdepth 4 -path '*/podstudio-quickcheck/checks.json' -print 2>/dev/null | /usr/bin/head -n 1 || true)"
    if [[ -n "$found" ]]; then
      RUNNER_SCRATCH="$(dirname "$found")"
    fi
  fi
}

remember_runner_scratch() {
  [[ -n "$RUNNER_SCRATCH" ]] || return 0
  remember "$RUNNER_SCRATCH"
  remember "$RUNNER_SCRATCH/checks.json"
  remember "$RUNNER_SCRATCH/BLOCKED.txt"
  remember "$RUNNER_SCRATCH/QuickCheck-A.wav"
  remember "$RUNNER_SCRATCH/QuickCheck-B.wav"
  remember "$RUNNER_SCRATCH/export"
  remember "$RUNNER_SCRATCH/project"
  remember "$RUNNER_SCRATCH/screenshots"
  remember "$RUNNER_SCRATCH/presets-leveler"
  remember "$RUNNER_SCRATCH/presets-lounge"
}

cleanup_generated() {
  stop_test_apps
  pkill -f QuickCheckUITests-Runner >/dev/null 2>&1 || true
  if [[ "$RUNNER_SCRATCH" == *"/podstudio-quickcheck" && -e "$RUNNER_SCRATCH" ]]; then
    rm -rf "$RUNNER_SCRATCH"
  fi
  forget_quickcheck_domains
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf "$WORK"
  fi
  if [[ -e "$OLD_RESULTS" ]]; then
    rm -rf "$OLD_RESULTS"
  fi
}

leftovers_remaining() {
  local item domain found preset_root
  LEFTOVER_DETAIL=""
  for item in "${MUST_REMOVE[@]}"; do
    if [[ -e "$item" || -L "$item" ]]; then
      LEFTOVER_DETAIL+="$item"$'\n'
    fi
  done
  for domain in "${QUICKCHECK_DOMAINS[@]}"; do
    if defaults read "$domain" >/dev/null 2>&1; then
      LEFTOVER_DETAIL+="defaults domain ${domain}"$'\n'
    fi
    for found in "${HOME}/Library/Preferences/ByHost/${domain}".*.plist(N); do
      LEFTOVER_DETAIL+="$found"$'\n'
    done
  done
  preset_root="${TMPDIR:-/tmp}"
  preset_root="${preset_root%/}"
  if [[ -e "$preset_root/podleveler-uitest-presets" ]]; then
    LEFTOVER_DETAIL+="$preset_root/podleveler-uitest-presets"$'\n'
  fi
  local container scratch_left
  for container in "${HOME}/Library/Containers"/com.cougarcalc.quickcheck.*(N); do
    scratch_left="$(/usr/bin/find "$container" \( -path '*/podstudio-quickcheck' -o -path '*/podstudio-quickcheck/*' -o -name 'QuickCheck-A.wav' -o -name 'QuickCheck-B.wav' -o -name 'checks.json' \) -print 2>/dev/null | /usr/bin/head -n 1 || true)"
    if [[ -n "$scratch_left" ]]; then
      LEFTOVER_DETAIL+="$scratch_left"$'\n'
    fi
  done
  if [[ -n "$LEFTOVER_DETAIL" ]]; then
    LEFTOVER_OK=0
  else
    LEFTOVER_OK=1
    LEFTOVER_DETAIL="Work folder, build files, exports, runner temp, and temporary preferences were removed."
  fi
}

copy_tree_shots() {
  local source="$1"
  local staging="$2"
  [[ -d "$source" ]] || return 0
  mkdir -p "$staging/shots"
  local total=0 copied=0 img size
  for img in "$source"/*.jpg(N); do
    size=$(stat -f %z "$img")
    (( copied >= 4 )) && break
    (( total + size > 5 * 1024 * 1024 )) && continue
    cp "$img" "$staging/shots/"
    (( total += size ))
    (( copied++ ))
  done
}

write_results() {
  local staging checks_file summary report shots_dir blocked_file
  discover_runner_scratch
  remember_runner_scratch
  staging="$(mktemp -d /tmp/podstudio-quickcheck-report.XXXXXX)"
  checks_file="$staging/checks.json"
  if [[ -n "$RUNNER_SCRATCH" && -f "$RUNNER_SCRATCH/checks.json" ]]; then
    cp "$RUNNER_SCRATCH/checks.json" "$checks_file"
  elif [[ -n "$WORK" && -f "$WORK/checks.json" ]]; then
    cp "$WORK/checks.json" "$checks_file"
  else
    print "[]" > "$checks_file"
  fi
  if [[ -n "$RUNNER_SCRATCH" && -d "$RUNNER_SCRATCH/screenshots" ]]; then
    shots_dir="$RUNNER_SCRATCH/screenshots"
  else
    shots_dir="$WORK/screenshots"
  fi
  copy_tree_shots "$shots_dir" "$staging"
  if [[ -n "$RUNNER_SCRATCH" && -f "$RUNNER_SCRATCH/BLOCKED.txt" ]]; then
    blocked_file="$RUNNER_SCRATCH/BLOCKED.txt"
  elif [[ -n "$WORK" && -f "$WORK/BLOCKED.txt" ]]; then
    blocked_file="$WORK/BLOCKED.txt"
  else
    blocked_file=""
  fi
  if [[ -n "$blocked_file" ]]; then
    BLOCKED=1
    mkdir -p "$ROOT/.ppjob"
    cp "$blocked_file" "$ROOT/.ppjob/QUICKCHECK-BLOCKED.txt"
  fi
  if [[ -n "$WORK" && -f "$WORK/xcodebuild.log" ]]; then
    LOG_TAIL="$(tail -n 30 "$WORK/xcodebuild.log")"
  fi

  cleanup_generated
  DISK_AFTER="$(disk_free_bytes)"
  leftovers_remaining

  local delta=$(( DISK_BEFORE - DISK_AFTER ))
  if (( delta < 0 )); then delta=$(( -delta )); fi

  local crash_ok=1
  if [[ -n "$CRASH_DETAIL" ]]; then
    crash_ok=0
  else
    CRASH_DETAIL="No new crash reports for these apps."
  fi

  OVERALL="PASS"
  if [[ "$ISOLATION_OK" != 1 || "$LEFTOVER_OK" != 1 || "$crash_ok" != 1 || "$XCODE_STATUS" != 0 || "$BLOCKED" == 1 ]]; then
    OVERALL="FAIL"
  fi
  if grep -q '"pass" : false' "$checks_file"; then
    OVERALL="FAIL"
  fi
  if [[ "$XCODE_STATUS" == 0 ]] && ! grep -q '"name"' "$checks_file"; then
    OVERALL="FAIL"
  fi

  summary="$staging/summary.txt"
  {
    print "Pod Studio quick check"
    print "$(date "+%A, %B %d, %Y")"
    print ""
    print "Disk free before: $(format_bytes "$DISK_BEFORE")"
    print "Disk free after:  $(format_bytes "$DISK_AFTER")"
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
    if [[ "$LEFTOVER_OK" == 1 ]]; then
      print "PASS  Nothing created by the run was left behind"
    else
      print "FAIL  Nothing created by the run was left behind"
      local leftover_line
      while IFS= read -r leftover_line; do
        [[ -n "$leftover_line" ]] || continue
        print "      $leftover_line"
      done <<< "$LEFTOVER_DETAIL"
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
    print "  \"diskDeltaBytes\": $delta,"
    print "  \"isolation\": \"$([[ "$ISOLATION_OK" == 1 ]] && print PASS || print FAIL)\","
    print "  \"isolationDetail\": \"$(json_escape "$ISOLATION_DETAIL")\","
    print "  \"crashes\": \"$(json_escape "$CRASH_DETAIL")\","
    print "  \"leftovers\": \"$([[ "$LEFTOVER_OK" == 1 ]] && print PASS || print FAIL)\","
    print "  \"leftoverDetail\": \"$(json_escape "$LEFTOVER_DETAIL")\","
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
  if [[ -e "$staging" ]]; then
    OVERALL="FAIL"
    sed -i '' 's/^Overall: PASS$/Overall: FAIL/' "$RESULTS/summary.txt"
    print "      $staging" >> "$RESULTS/summary.txt"
  fi
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

rm -f "$ROOT/.ppjob/QUICKCHECK-BLOCKED.txt"
DISK_BEFORE="$(disk_free_bytes)"
WORK="$(mktemp -d /tmp/podstudio-quickcheck.XXXXXX)"
STAMP="$WORK/started"
touch "$STAMP"
mkdir -p "$WORK/apps" "$WORK/audio" "$WORK/export" "$WORK/project" \
  "$WORK/presets-leveler" "$WORK/presets-lounge" "$WORK/screenshots" "$WORK/snapshot-before"
remember_created_paths
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
