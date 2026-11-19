#!/usr/bin/env bash
# auto-trial.sh — One-command Google AI Ultra trial activation
# 博客：https://blog.caowo.de/
# 发卡网：https://faka.cdkey.si/
#
# Usage:
#   ./auto-trial.sh --list                        # show all available trials
#   ./auto-trial.sh --product 20x --dur 12mo      # Ultra 20x, 12-month trial
#   ./auto-trial.sh --product 5x --dur 6mo        # Ultra 5x, 6-month trial
#   ./auto-trial.sh --product pro --dur 3mo        # Pro 5TB, 3-month trial
#   ./auto-trial.sh --product pro12 --dur 12mo     # Pro 5TB variant, 12-month trial
#   ./auto-trial.sh --product 20x                  # Ultra 20x, longest available
#   ./auto-trial.sh --port 16416 --list            # specify MuMu ADB port
#
# Products: pro = g1.play.2tb.ai ($19.99), pro12 = g1.2tb.ai.subs_variant ($19.99, up to 12mo trial),
#           5x = g1.play.20tb ($99.99), 20x = g1.play.ai.pro ($199.99), auto = best match
# Durations: 1mo, 3mo, 6mo, 12mo, longest (default)
#
# Billing dialog is launched but NOT auto-confirmed — confirm manually (password required).
#
# Requirements: adb (MuMu bundled), frida CLI, frida-server on device, module.apk on device

set -euo pipefail

# ===== Paths =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRIDA_SCRIPT="${FRIDA_SCRIPT:-$SCRIPT_DIR/frida-auto-trial.js}"
FRIDA_DEVICE_PORT=27042
FRIDA_LOCAL_PORT=27043
GOOGLE_ONE_PKG="com.google.android.apps.subscriptions.red"

# Device paths (override via env vars if your layout differs)
MODULE_APK_DEVICE="${MODULE_APK_DEVICE:-/data/local/tmp/module.apk}"
FRIDA_SERVER_PATH="${FRIDA_SERVER_PATH:-/data/local/tmp/frida-server}"

# ===== Defaults =====
MODE="activate"
TARGET="auto"
DURATION="longest"
DEVICE_PORT=""

# ===== Auto-detect ADB =====
find_adb() {
    # 1. Explicit env var
    if [[ -n "${ADB_PATH:-}" ]] && [[ -x "$ADB_PATH" ]]; then
        echo "$ADB_PATH"; return
    fi
    # 2. PATH
    if command -v adb >/dev/null 2>&1; then
        command -v adb; return
    fi
    # 3. Known adb locations — test each directly
    #    glob/find fail on C:/ translated paths; -x on full paths works
    local candidates=(
        # MuMu — nested bundle (MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/…)
        "/Applications/MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "$HOME/Applications/MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "/Applications/MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        # MuMu — flat bundle (tools directly under MuMuPlayer.app)
        "/Applications/MuMuPlayer.app/Contents/MacOS/tools/adb"
        "$HOME/Applications/MuMuPlayer.app/Contents/MacOS/tools/adb"
        "/Applications/MuMuPlayer.app/Contents/MacOS/tools/adb"
        # MuMu Pro / alternate names
        "/Applications/MuMuPlayerPro.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "/Applications/MuMu Player.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "/Applications/MuMuPlayerPro.app/Contents/MacOS/tools/adb"
        "/Applications/MuMu Player.app/Contents/MacOS/tools/adb"
        # Android SDK
        "$HOME/Library/Android/sdk/platform-tools/adb"
        "/usr/local/share/android-sdk/platform-tools/adb"
        "$HOME/Android/Sdk/platform-tools/adb"
        "${LOCALAPPDATA:-_}/Android/Sdk/platform-tools/adb.exe"
        "${PROGRAMFILES:-_}/Android/android-sdk/platform-tools/adb.exe"
    )
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { echo "$c"; return; }
    done
    return 1
}
ADB="$(find_adb)" || { echo "[-] adb not found. Install Android SDK or set ADB_PATH"; exit 1; }

# ===== Parse args =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)        MODE="list"; shift ;;
        --product)     TARGET="$2"; shift 2 ;;
        --dur|--duration) DURATION="$2"; shift 2 ;;
        --port)        DEVICE_PORT="$2"; shift 2 ;;
        --adb)         ADB="$2"; shift 2 ;;
        --script)      FRIDA_SCRIPT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ===== Resolve product aliases =====
case "$TARGET" in
    20x|20X|ultra20x) TARGET="g1.play.ai.pro" ;;
    5x|5X|ultra5x)    TARGET="g1.play.20tb" ;;
    pro|Pro|PRO)      TARGET="g1.play.2tb.ai" ;;
    pro12|Pro12|PRO12) TARGET="g1.2tb.ai.subs_variant" ;;
    auto|g1.*)        ;; # keep as-is
    *) echo "Unknown product: $TARGET (use pro, 5x, 20x, pro12, or a g1.* product ID)"; exit 1 ;;
esac

# ===== Helpers =====
log()  { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
err()  { echo "[-] $*" >&2; }
die()  { err "$*"; exit 1; }

# ===== 1. Find MuMu device =====
detect_device() {
    if [[ -n "$DEVICE_PORT" ]]; then
        DEVICE="127.0.0.1:$DEVICE_PORT"
        log "Using specified device $DEVICE"
        "$ADB" connect "$DEVICE" >/dev/null 2>&1 || true
        return
    fi

    log "Scanning for MuMu devices..."
    # MuMu ports: 16384, 16416, 16448, 16480, ...
    for port in 16384 16416 16448 16480 16512; do
        if "$ADB" connect "127.0.0.1:$port" 2>/dev/null | grep -q "connected"; then
            DEVICE="127.0.0.1:$port"
            ok "Found device at $DEVICE"
            return
        fi
    done

    # Fallback: check already-connected devices
    local dev
    dev=$("$ADB" devices 2>/dev/null | grep -v "^List" | grep "device$" | head -1 | awk '{print $1}')
    if [[ -n "$dev" ]]; then
        DEVICE="$dev"
        ok "Using connected device $DEVICE"
        return
    fi

    die "No MuMu device found. Start the emulator or use --port <PORT>"
}

# ===== 2. Setup Frida =====
setup_frida() {
    log "Setting up Frida port forwarding ($FRIDA_LOCAL_PORT → $FRIDA_DEVICE_PORT)..."
    "$ADB" -s "$DEVICE" forward "tcp:$FRIDA_LOCAL_PORT" "tcp:$FRIDA_DEVICE_PORT" 2>/dev/null || true

    # Check frida-server (MuMu runs as root by default, no su needed)
    local fs_pid
    fs_pid=$("$ADB" -s "$DEVICE" shell "pidof frida-server" 2>/dev/null | tr -d '\r\n' || echo "")
    if [[ -z "$fs_pid" ]]; then
        log "Starting frida-server..."
        "$ADB" -s "$DEVICE" shell "$FRIDA_SERVER_PATH -D &"
        sleep 2
        fs_pid=$("$ADB" -s "$DEVICE" shell "pidof frida-server" 2>/dev/null | tr -d '\r\n' || echo "")
        [[ -n "$fs_pid" ]] || die "Could not start frida-server at $FRIDA_SERVER_PATH"
    fi
    ok "frida-server running (PID $fs_pid)"

    # Check module.apk
    if ! "$ADB" -s "$DEVICE" shell "ls $MODULE_APK_DEVICE" >/dev/null 2>&1; then
        die "module.apk not found at $MODULE_APK_DEVICE on device. Push it first:\n  \"\$ADB\" -s $DEVICE push module.apk $MODULE_APK_DEVICE"
    fi
    ok "module.apk present"
}

# ===== 3. Get Google One PID =====
get_pid() {
    # Force restart Google One for a clean Activity state
    # All status messages go to stderr — only the PID goes to stdout
    log "Restarting Google One for clean state..." >&2
    "$ADB" -s "$DEVICE" shell "am force-stop $GOOGLE_ONE_PKG" 2>/dev/null || true
    sleep 1
    "$ADB" -s "$DEVICE" shell "monkey -p $GOOGLE_ONE_PKG 1" >/dev/null 2>&1
    sleep 3
    local pid
    pid=$("$ADB" -s "$DEVICE" shell "pidof $GOOGLE_ONE_PKG" 2>/dev/null || echo "")
    [[ -n "$pid" ]] || die "Could not start Google One"
    # pidof may return multiple PIDs; take first
    pid=$(echo "$pid" | tr -s ' ' '\n' | head -1 | tr -d '\r\n')
    ok "Google One PID: $pid" >&2
    echo "$pid"
}

# ===== 4. Patch and run Frida script =====
run_frida() {
    local pid="$1"
    local tmp_script
    tmp_script="/tmp/.frida-run-$$.js"

    # Patch config into the script
    sed \
        -e "s|^var MODE = .*|var MODE = \"$MODE\";|" \
        -e "s|^var TARGET_PRODUCT = .*|var TARGET_PRODUCT = \"$TARGET\";|" \
        -e "s|^var PREFER_DURATION = .*|var PREFER_DURATION = \"$DURATION\";|" \
        -e "s|^var MODULE_APK = .*|var MODULE_APK = \"$MODULE_APK_DEVICE\";|" \
        "$FRIDA_SCRIPT" > "$tmp_script"

    log "Injecting (mode=$MODE target=$TARGET duration=$DURATION)..."

    # Clear logcat BEFORE injection so we don't lose early output
    "$ADB" -s "$DEVICE" logcat -c 2>/dev/null || true

    # Run frida in background (stdin from /dev/null to prevent REPL blocking).
    # Output goes to a file, not /dev/null: on Windows (Git Bash) the frida CLI
    # never injects when stdout is NUL.
    frida -H "127.0.0.1:$FRIDA_LOCAL_PORT" -p "$pid" -l "$tmp_script" \
        </dev/null >"$tmp_script.log" 2>&1 &
    FRIDA_PID=$!

    # Poll logcat in a loop instead of streaming pipe (avoids indefinite hang)
    log "Waiting for results..."
    local elapsed=0
    local max_wait=60
    local got_terminal=false
    local seen_lines=0

    while [[ $elapsed -lt $max_wait ]]; do
        sleep 2
        elapsed=$((elapsed + 2))

        # Read all AutoTrial messages so far
        local output
        output=$("$ADB" -s "$DEVICE" logcat -d -s "AutoTrial:*" 2>/dev/null \
            | sed 's/^.*AutoTrial *: \{0,1\}//')

        [[ -z "$output" ]] && continue

        # Skip lines we already printed
        local total_lines
        total_lines=$(echo "$output" | wc -l)
        if [[ $total_lines -le $seen_lines ]]; then continue; fi
        local new_output
        new_output=$(echo "$output" | tail -n +"$((seen_lines + 1))")
        seen_lines=$total_lines

        # Process only new lines
        while IFS= read -r msg; do
            case "$msg" in
                "=== AUTO_TRIAL_START"*)  log "Script started" ;;
                "BillingClient connected") ok "BillingClient connected" ;;
                "Products found:"*)       log "$msg" ;;
                PRODUCT*)                 echo ""; echo "  $msg" ;;
                "  ["*)                   echo "    $msg" ;;
                "  TRIAL "*)              ok "$msg" ;;
                TRIALS_FOUND*)            echo ""; log "$msg" ;;
                SELECTED*)                ok "$msg" ;;
                "Waiting for Activity"*)  log "Stabilizing Activity..." ;;
                BILLING_FLOW_LAUNCHED*)
                    ok "Billing dialog launched — confirm manually (Ctrl-C when done)"
                    got_terminal=true ;;
                "=== TRIAL_ACTIVATED ===")
                    echo ""; ok "TRIAL ACTIVATED SUCCESSFULLY"
                    echo ""; echo "  Auto-renews after trial. Cancel before expiry."
                    echo ""; got_terminal=true ;;
                "=== USER_CANCELLED ===")
                    err "User cancelled"; got_terminal=true ;;
                "=== ITEM_ALREADY_OWNED ===")
                    err "Already subscribed"; got_terminal=true ;;
                "=== PURCHASE_FAILED"*)
                    err "$msg"; got_terminal=true ;;
                "=== LIST_COMPLETE ===")
                    echo ""; ok "Listing complete"; got_terminal=true ;;
                "=== NO_TRIALS ===")
                    err "No trial offers found"; got_terminal=true ;;
                "=== SELECT_FAILED ==="|\
                "=== NO_ACTIVITY ==="|\
                "=== CONNECT_FAILED"*|\
                "=== LAUNCH_ERROR"*)
                    err "$msg"; got_terminal=true ;;
            esac
        done <<< "$new_output"

        $got_terminal && break
    done

    if ! $got_terminal; then
        err "Timed out after ${max_wait}s — check logcat manually: adb logcat -d -s AutoTrial:*"
    fi

    rm -f "$tmp_script" "$tmp_script.log"
}

# ===== Cleanup =====
cleanup() {
    [[ -n "${FRIDA_PID:-}" ]] && kill "$FRIDA_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ===== Main =====
main() {
    echo "=== Google AI Ultra Trial Tool ==="
    echo "博客：https://blog.caowo.de/"
    echo "发卡网：https://faka.cdkey.si/"
    echo ""

    detect_device
    setup_frida
    local pid
    pid=$(get_pid)

    [[ ! -f "$FRIDA_SCRIPT" ]] && die "Frida script not found: $FRIDA_SCRIPT"

    echo ""
    run_frida "$pid"
}

main
