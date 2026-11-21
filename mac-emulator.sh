#!/usr/bin/env bash
#
# Mac Emulator - run Android apps (APKs) on your Mac with the official Android Emulator.
# https://github.com/YOUR_USERNAME/mac-emulator
#
# Run with no arguments (or "help") to see all commands.

set -euo pipefail

VERSION="1.0.0"
AVD_NAME="${AVD_NAME:-MacEmulator}"
API_LEVEL="${API_LEVEL:-34}"
VARIANT="${VARIANT:-google_apis_playstore}"   # google_apis_playstore | google_apis
PROFILE="${PROFILE:-auto}"                    # auto | light | balanced | performance
BUILD_TOOLS="34.0.0"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"
AAPT2="$ANDROID_HOME/build-tools/$BUILD_TOOLS/aapt2"
LOG="/tmp/${AVD_NAME}.log"
LAST_PKG=""

# ---------- helpers ----------------------------------------------------------

say()  { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
bad()  { printf "  \033[1;31m✗\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33mNote: %s\033[0m\n" "$*" >&2; }
die()  { printf "\033[1;31mError: %s\033[0m\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Mac Emulator $VERSION - Android apps on your Mac

Usage: $(basename "$0") <command> [args]

Commands:
  setup               Install everything and create a virtual phone tuned to your Mac
  start               Start the emulator
  run <file>          Start (if needed), install an .apk/.xapk and open the app
  install <file>      Install an .apk/.xapk on the running emulator
  list                List installed third-party apps
  tune [profile]      Re-tune CPU/RAM/screen: light | balanced | performance
  screenshot          Save a screenshot of the emulator to your Desktop
  doctor              Check your setup and print diagnostics
  stop                Shut the emulator down
  delete              Delete the virtual phone (frees disk space)
  help, version

Environment overrides (optional):
  AVD_NAME   (default: MacEmulator)            name of the virtual phone
  API_LEVEL  (default: 34)                Android version, e.g. 33, 34, 35
  VARIANT    (default: google_apis_playstore)  or google_apis (no Play Store)
  PROFILE    (default: auto)              light | balanced | performance
EOF
}

require_mac() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Mac Emulator is for macOS only."
}

# Apple Silicon detection that also works inside a Rosetta (x86_64) terminal.
abi() {
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then
    echo "arm64-v8a"
  else
    echo "x86_64"
  fi
}

sysimg() { echo "system-images;android-${API_LEVEL};${VARIANT};$(abi)"; }

java_ok() {
  local d
  if /usr/libexec/java_home -v 17+ >/dev/null 2>&1; then
    JAVA_HOME="$(/usr/libexec/java_home -v 17+)"; export JAVA_HOME; return 0
  fi
  for d in /opt/homebrew/opt/openjdk@17 /usr/local/opt/openjdk@17 \
           /opt/homebrew/opt/openjdk /usr/local/opt/openjdk; do
    if [[ -x "$d/libexec/openjdk.jdk/Contents/Home/bin/java" ]]; then
      JAVA_HOME="$d/libexec/openjdk.jdk/Contents/Home"; export JAVA_HOME; return 0
    fi
  done
  return 1
}

ensure_java() {
  java_ok || return 1
  export PATH="$JAVA_HOME/bin:$PATH"
}

emulator_running() {
  [[ -x "$ADB" ]] && "$ADB" devices 2>/dev/null | grep -q "^emulator-.*device$"
}

avd_exists() {
  [[ -x "$EMULATOR" ]] && "$EMULATOR" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"
}

avd_config() { echo "$HOME/.android/avd/${AVD_NAME}.avd/config.ini"; }

# ---------- setup ------------------------------------------------------------

setup() {
  command -v brew >/dev/null 2>&1 || die "Homebrew is required. Install it from https://brew.sh and run setup again."

  say "Step 1/5  Java (needed by the Android command-line tools)"
  if ! ensure_java; then
    brew install openjdk@17
    ensure_java || die "Java 17 installed but not found. Open a new Terminal and retry."
  fi
  ok "Java found: $JAVA_HOME"

  say "Step 2/5  Android command-line tools"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  if [[ -L "$ANDROID_HOME/cmdline-tools/latest" || ! -x "$SDKMANAGER" ]]; then
    brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools
    local brew_clt
    brew_clt="$(brew --prefix)/share/android-commandlinetools/cmdline-tools/latest"
    [[ -d "$brew_clt" ]] || die "Could not find cmdline-tools at: $brew_clt"
    # Copy (not symlink): avdmanager would otherwise look for the SDK in the wrong place.
    rm -rf "$ANDROID_HOME/cmdline-tools/latest"
    cp -R "$brew_clt" "$ANDROID_HOME/cmdline-tools/latest"
  fi
  ok "cmdline-tools ready"

  say "Step 3/5  Accepting licenses and downloading Android $API_LEVEL ($(abi))"
  yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
  "$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
    "platform-tools" "emulator" "build-tools;${BUILD_TOOLS}" "$(sysimg)"
  [[ -x "$EMULATOR" ]] || die "Emulator was not installed. Re-run setup and check the output above."

  say "Step 4/5  Creating the virtual phone '$AVD_NAME'"
  if avd_exists; then
    ok "'$AVD_NAME' already exists"
  else
    # The devices.xml message printed by some SDK versions is harmless, so it is hidden.
    echo "no" | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$(sysimg)" -d pixel_6 --force 2>&1 \
      | grep -v "devices.xml" || true
    if ! avd_exists; then
      echo "no" | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$(sysimg)" --force 2>&1 \
        | grep -v "devices.xml" || true
    fi
    avd_exists || die "Could not create the virtual phone. Run: $(basename "$0") doctor"
    ok "'$AVD_NAME' created"
  fi

  say "Step 5/5  Tuning for this Mac"
  tune "${1:-}"

  say "All done! Next: $(basename "$0") run /path/to/app.apk   (or: $(basename "$0") start)"
}

# ---------- tune -------------------------------------------------------------

resolve_profile() {
  local p="${1:-$PROFILE}" mem_gb
  mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  if [[ -z "$p" || "$p" == "auto" ]]; then
    if   (( mem_gb <= 8 ));  then p="light"
    elif (( mem_gb <= 16 )); then p="balanced"
    else p="performance"; fi
  fi
  echo "$p"
}

tune() {
  local cfg; cfg="$(avd_config)"
  [[ -f "$cfg" ]] || die "No virtual phone yet. Run: $(basename "$0") setup"
  if emulator_running; then die "Stop the emulator first: $(basename "$0") stop"; fi

  local p ncpu mem_gb cap cores ram w h d
  p="$(resolve_profile "${1:-}")"
  ncpu="$(sysctl -n hw.ncpu)"
  mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))

  case "$p" in
    light)       cap=3; ram=3072; w=720;  h=1600; d=280 ;;
    balanced)    cap=4; ram=4096; w=720;  h=1600; d=280 ;;
    performance) cap=6; ram=6144; w=1080; h=2400; d=420 ;;
    *) die "Unknown profile '$p'. Use: light | balanced | performance" ;;
  esac
  if [[ "$p" == "performance" ]] && (( mem_gb < 16 )); then
    warn "The 'performance' profile wants 16 GB+ RAM; your Mac has ${mem_gb} GB. Consider 'balanced'."
  fi

  cores=$(( ncpu / 2 )); (( cores < 2 )) && cores=2; (( cores > cap )) && cores=$cap

  # The emulator refuses to start if the phone's storage does not fit on disk.
  local free_gb data
  free_gb="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
  data="8G"
  if (( free_gb < 14 )); then data="4G"; fi
  if (( free_gb < 8 )); then
    data="2G"
    warn "Only ${free_gb} GB of disk space is free. Free up space or the emulator may not start."
  fi

  say "Profile '$p': ${cores} CPU cores, ${ram} MB RAM, ${w}x${h} screen, ${data} storage  (your Mac: ${ncpu} cores, ${mem_gb} GB RAM)"
  sed -i '' -E '/^(hw[.]cpu[.]ncore|hw[.]ramSize|vm[.]heapSize|hw[.]lcd[.](width|height|density)|hw[.]gpu[.](enabled|mode)|hw[.]keyboard|disk[.]dataPartition[.]size|fastboot[.]forceColdBoot|fastboot[.]forceFastBoot)=/d' "$cfg"
  {
    echo "hw.cpu.ncore=${cores}"
    echo "hw.ramSize=${ram}"
    echo "vm.heapSize=512"
    echo "hw.lcd.width=${w}"
    echo "hw.lcd.height=${h}"
    echo "hw.lcd.density=${d}"
    echo "hw.gpu.enabled=yes"
    echo "hw.gpu.mode=host"
    echo "hw.keyboard=yes"
    echo "disk.dataPartition.size=${data}"
    echo "fastboot.forceColdBoot=no"
    echo "fastboot.forceFastBoot=yes"
  } >> "$cfg"
  ok "Saved. The first start is a cold boot; later starts use quick boot."
}

# ---------- start / stop -----------------------------------------------------

start() {
  [[ -x "$EMULATOR" ]] || die "Emulator not installed. Run: $(basename "$0") setup"
  avd_exists || die "Virtual phone '$AVD_NAME' not found. Run: $(basename "$0") setup"
  if emulator_running; then say "Emulator is already running"; return; fi

  say "Starting emulator (first boot can take 1-3 minutes)"
  nohup "$EMULATOR" -avd "$AVD_NAME" -gpu host -no-boot-anim -netdelay none -netspeed full \
    >"$LOG" 2>&1 &

  local waited=0
  until [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    sleep 3; waited=$(( waited + 3 ))
    if ! pgrep -f "qemu-system.*${AVD_NAME}|emulator.*${AVD_NAME}" >/dev/null 2>&1; then
      die "Emulator exited during startup. See: tail -50 $LOG"
    fi
    if (( waited > 300 )); then
      die "Not booted after 5 minutes. See: tail -50 $LOG"
    fi
  done
  ok "Emulator is ready"
}

stop() {
  if emulator_running; then "$ADB" emu kill >/dev/null 2>&1 || true; ok "Emulator stopped"
  else say "Emulator is not running"; fi
}

delete_avd() {
  ensure_java || die "Java 17+ not found. Run setup first."
  emulator_running && stop
  [[ -x "$AVDMANAGER" ]] || die "Nothing to delete."
  "$AVDMANAGER" delete avd -n "$AVD_NAME" || true
  ok "Virtual phone '$AVD_NAME' deleted"
}

# ---------- apps -------------------------------------------------------------

install_apk_file() {
  local apk="$1" out
  if ! out="$("$ADB" install -r -t "$apk" 2>&1)"; then
    echo "$out"
    case "$out" in
      *NO_MATCHING_ABIS*) warn "This app has no build for your emulator's CPU ($(abi)). Try a universal or $(abi) APK." ;;
      *VERSION_DOWNGRADE*) warn "A newer version is already installed. Uninstall it first: adb uninstall <package>" ;;
    esac
    exit 1
  fi
  echo "$out"
  if [[ -x "$AAPT2" ]]; then
    LAST_PKG="$("$AAPT2" dump packagename "$apk" 2>/dev/null || true)"
  fi
}

install_xapk_file() {
  local f="$1" tmp a
  local apks=()
  tmp="$(mktemp -d)"
  unzip -q "$f" -d "$tmp"
  while IFS= read -r a; do apks+=("$a"); done < <(find "$tmp" -maxdepth 2 -name '*.apk')
  (( ${#apks[@]} > 0 )) || { rm -rf "$tmp"; die "No .apk files found inside $f"; }
  "$ADB" install-multiple -r "${apks[@]}"
  if [[ -d "$tmp/Android/obb" ]]; then
    say "Copying game data (OBB)"
    "$ADB" push "$tmp/Android/obb/." /sdcard/Android/obb/
  fi
  if [[ -f "$tmp/manifest.json" ]]; then
    LAST_PKG="$(sed -n 's/.*"package_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/manifest.json" | head -1)"
  fi
  rm -rf "$tmp"
}

install_file() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] || die "File not found: '${f}'"
  emulator_running || die "Emulator is not running. Start it with: $(basename "$0") start"
  say "Installing: $f"
  case "$f" in
    *.apk)  install_apk_file "$f" ;;
    *.xapk) install_xapk_file "$f" ;;
    *.apks|*.aab) die "Bundles ($f) are not supported. Use a universal .apk or .xapk." ;;
    *) die "Unsupported file type. Use .apk or .xapk" ;;
  esac
}

run_file() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] || die "File not found: '${f}'"
  start
  install_file "$f"
  if [[ -n "$LAST_PKG" ]]; then
    say "Opening $LAST_PKG"
    "$ADB" shell monkey -p "$LAST_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  else
    say "Installed. Open it from the app drawer in the emulator."
  fi
}

list_apps() {
  emulator_running || die "Emulator is not running."
  "$ADB" shell pm list packages -3 | tr -d '\r' | sed 's/^package://'
}

screenshot() {
  emulator_running || die "Emulator is not running."
  local out="$HOME/Desktop/mac-emulator-$(date +%Y%m%d-%H%M%S).png"
  "$ADB" exec-out screencap -p > "$out"
  ok "Saved: $out"
}

# ---------- doctor -----------------------------------------------------------

doctor() {
  say "Mac Emulator $VERSION diagnostics"
  printf "  macOS %s | %s | %s GB RAM | %s cores | image ABI: %s\n" \
    "$(sw_vers -productVersion)" "$(uname -m)" "$(( $(sysctl -n hw.memsize) / 1073741824 ))" "$(sysctl -n hw.ncpu)" "$(abi)"
  if [[ "$(uname -m)" == "x86_64" && "$(abi)" == "arm64-v8a" ]]; then
    warn "Your Terminal runs under Rosetta. That works, but a native Terminal is faster."
  fi
  echo "  Suggested profile: $(resolve_profile auto)"
  echo
  command -v brew >/dev/null 2>&1 && ok "Homebrew installed" || bad "Homebrew missing (https://brew.sh)"
  if ensure_java; then ok "Java 17+: $JAVA_HOME"; else bad "Java 17+ missing (run setup)"; fi
  [[ -x "$SDKMANAGER" ]] && ok "cmdline-tools" || bad "cmdline-tools missing (run setup)"
  [[ -x "$ADB" ]]        && ok "platform-tools (adb)" || bad "platform-tools missing (run setup)"
  [[ -x "$EMULATOR" ]]   && ok "emulator" || bad "emulator missing (run setup)"
  local imgdir="$ANDROID_HOME/system-images/android-${API_LEVEL}/${VARIANT}/$(abi)"
  [[ -d "$imgdir" ]]     && ok "system image: android-${API_LEVEL} ${VARIANT} $(abi)" || bad "system image missing (run setup)"
  avd_exists             && ok "virtual phone '$AVD_NAME'" || bad "virtual phone missing (run setup)"
  emulator_running       && ok "emulator is running" || echo "  - emulator not running"
  local free_gb
  free_gb="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
  if (( free_gb >= 15 )); then ok "free disk: ${free_gb} GB"; else bad "free disk: ${free_gb} GB (15 GB+ recommended)"; fi
  [[ -f "$LOG" ]] && echo "  Last emulator log: $LOG"
}

# ---------- main -------------------------------------------------------------

cmd="${1:-help}"
case "$cmd" in
  help|-h|--help)       usage; exit 0 ;;
  version|-v|--version) echo "Mac Emulator $VERSION"; exit 0 ;;
esac

require_mac

case "$cmd" in
  setup)      setup "${2:-}" ;;
  start)      start ;;
  run)        run_file "${2:-}" ;;
  install)    install_file "${2:-}" ;;
  list)       list_apps ;;
  tune)       tune "${2:-}" ;;
  screenshot) screenshot ;;
  doctor)     doctor ;;
  stop)       stop ;;
  delete)     delete_avd ;;
  *)          usage; exit 1 ;;
esac
