#!/bin/bash
# /usr/local/bin/r36_config.sh
# Early boot: detect hardware → select correct battery LED warning script → apply if needed
# Handles gamma + ALSA audio path/volume every boot (persistent in config.ini, default from devices.ini)
# Writes current gamma to /dev/shm/CURRENT_GAMMA every boot (volatile runtime file)
# FIXED: 80% default volume ONLY on first boot/hardware change.  No alsa_volume line = manual control.
# NEW: control_scheme handling (default / no_function) for R36H support
# NEW: resolution-based video profile system (mirrors controls exactly)
#       → applies custom video/display tweaks from /usr/local/bin/r36_config/video/<resolution>.ini
#       → perfect sync with DTB selection, LED GPIO variant, and controls
# NEW: speaker_enable_gpio + headphone_detect_gpio support (SoySauce + specific clones)
#       → exported/permissions set for ogage (ark user)
#       → initial speaker state based on headphone jack detect (reversed logic)
#       → full sync with DTB/hardware detection to prevent audio mute conflicts and double-power issues

set -euo pipefail

CONFIG_FILE="/etc/r36_config.ini"
DEVICES_FILE="/boot/dtb/r36_devices.ini"
SCRIPT_DIR="/usr/local/bin/r36_config/batt_life_warning"
TARGET_LINK="/usr/local/bin/batt_life_warning.py"
LOG_FILE="/boot/darkosre_device.log"
GAMMA_BIN="/usr/local/bin/gamma"
OGAGE_DIR="/usr/local/bin/r36_config/ogage"

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [r36_config] $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" > /dev/kmsg 2>/dev/null || true
}

log "Early boot LED variant + gamma + ALSA audio + controls config + VIDEO PROFILE + SPEAKER GPIO starting..."

# Hardware detection
HARDWARE_RAW=$(grep -i '^Hardware' /proc/cpuinfo | awk -F': ' '{print $2}' | head -n1 | sed 's/^[ \t]*//;s/[ \t]*$//')
[ -z "$HARDWARE_RAW" ] && HARDWARE_RAW="Unknown RK3326"
log "Hardware string: '$HARDWARE_RAW'"

HARDWARE_NORM=$(echo "$HARDWARE_RAW" | tr '[:upper:]' '[:lower:]' | sed 's/^[ \t]*//;s/[ \t]*$//')

# Variant lookup
lookup_variant() {
    local orig="$1" norm="$2"
    local variant=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([^]]+)\] ]]; then
            local sec="${BASH_REMATCH[1]}"
            local sec_norm=$(echo "$sec" | tr '[:upper:]' '[:lower:]' | sed 's/^[ \t]*//;s/[ \t]*$//')
            if [ "$sec_norm" = "$norm" ]; then
                variant=$(sed -n "/^\[$sec\]/,/^\[/ s/^variant[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
                [ -n "$variant" ] && echo "$variant" && return 0
            fi
        fi
    done < "$DEVICES_FILE"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([^]]+)\] ]]; then
            local sec="${BASH_REMATCH[1]}"
            local sec_norm=$(echo "$sec" | tr '[:upper:]' '[:lower:]' | sed 's/^[ \t]*//;s/[ \t]*$//')
            if echo "$norm" | grep -q "$sec_norm"; then
                variant=$(sed -n "/^\[$sec\]/,/^\[/ s/^variant[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
                [ -n "$variant" ] && echo "$variant" && return 0
            fi
        fi
    done < "$DEVICES_FILE"
    echo "unknown"
}

VARIANT=$(lookup_variant "$HARDWARE_RAW" "$HARDWARE_NORM")
log "Determined variant: $VARIANT"

# ALSA path lookup (defaults to SPK_HP)
ALSA_PATH=""
if [ -f "$DEVICES_FILE" ]; then
    ALSA_PATH=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^alsa_path[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    if [ -z "$ALSA_PATH" ]; then
        ALSA_PATH=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^alsa_path[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    fi
fi
[ -z "$ALSA_PATH" ] && ALSA_PATH="SPK_HP"
log "ALSA path from devices.ini (or default): $ALSA_PATH"

# Control scheme lookup (default / no_function for R36H)
CONTROL_SCHEME="default"
if [ -f "$DEVICES_FILE" ]; then
    CONTROL_SCHEME=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^control_scheme[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    if [ -z "$CONTROL_SCHEME" ]; then
        CONTROL_SCHEME=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^control_scheme[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    fi
fi
[ -z "$CONTROL_SCHEME" ] && CONTROL_SCHEME="default"
log "Control scheme from devices.ini (or default): $CONTROL_SCHEME"

# Gamma lookup – moved early so it's always defined before config write
GAMMA_VALUE=""
if [ -f "$DEVICES_FILE" ]; then
    GAMMA_VALUE=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^gamma[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    [ -z "$GAMMA_VALUE" ] && GAMMA_VALUE=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^gamma[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
fi
[ -z "$GAMMA_VALUE" ] && GAMMA_VALUE="1.0"
log "Gamma value from devices.ini (or default 1.0): $GAMMA_VALUE"

# NEW: Resolution lookup for video profile (used by r36_video.sh + R36 Control menu)
RESOLUTION=""
if [ -f "$DEVICES_FILE" ]; then
    RESOLUTION=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^resolution[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    if [ -z "$RESOLUTION" ]; then
        RESOLUTION=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^resolution[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    fi
fi
[ -z "$RESOLUTION" ] && RESOLUTION="640x480"
log "Resolution from devices.ini (or default): $RESOLUTION"

# NEW: Speaker / Headphone GPIO lookup (for SoySauce + specific clones)
# This ensures perfect synchronisation between DTB settings and early-boot GPIO handling
SPEAKER_GPIO=""
HP_DETECT_GPIO=""
if [ -f "$DEVICES_FILE" ]; then
    SPEAKER_GPIO=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^speaker_enable_gpio[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    if [ -z "$SPEAKER_GPIO" ]; then
        SPEAKER_GPIO=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^speaker_enable_gpio[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    fi
    HP_DETECT_GPIO=$(sed -n "/^\[$HARDWARE_RAW\]/,/^\[/ s/^headphone_detect_gpio[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    if [ -z "$HP_DETECT_GPIO" ]; then
        HP_DETECT_GPIO=$(sed -n "/^\[.*$HARDWARE_NORM.*\]/,/^\[/ s/^headphone_detect_gpio[ \t]*=[ \t]*//p" "$DEVICES_FILE" | head -1 | xargs)
    fi
fi
log "speaker_enable_gpio from devices.ini: ${SPEAKER_GPIO:-none}"
log "headphone_detect_gpio from devices.ini: ${HP_DETECT_GPIO:-none}"

# LED + config handling (first boot / hardware change)
NEEDS_LED_UPDATE=0
NEEDS_CONTROLS_UPDATE=0
NEEDS_VIDEO_UPDATE=0

if [ ! -f "$CONFIG_FILE" ]; then
    NEEDS_LED_UPDATE=1
    if [ "$CONTROL_SCHEME" != "default" ]; then
        NEEDS_CONTROLS_UPDATE=1
    fi
    NEEDS_VIDEO_UPDATE=1
    log "Config file missing (first boot) - performing full setup (LED + controls + VIDEO + GPIO)"
else
    CURRENT_HARDWARE=$(grep '^hardware[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || echo "")
    CURRENT_CONTROL_SCHEME=$(grep '^control_scheme[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^[ \t]*//;s/[ \t]*$//' || echo "default")
    CURRENT_RESOLUTION=$(grep '^resolution[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || echo "640x480")

    if [ "$CURRENT_HARDWARE" != "$HARDWARE_RAW" ]; then
        NEEDS_LED_UPDATE=1
        NEEDS_VIDEO_UPDATE=1
        log "Hardware change detected: '$CURRENT_HARDWARE' → '$HARDWARE_RAW' (LED + VIDEO + GPIO will be reapplied)"
    fi

    if [ "$CURRENT_CONTROL_SCHEME" != "$CONTROL_SCHEME" ]; then
        NEEDS_CONTROLS_UPDATE=1
        log "Control scheme changed: '$CURRENT_CONTROL_SCHEME' → '$CONTROL_SCHEME'"
    fi

    if [ "$CURRENT_RESOLUTION" != "$RESOLUTION" ]; then
        NEEDS_VIDEO_UPDATE=1
        log "Resolution change detected: '$CURRENT_RESOLUTION' → '$RESOLUTION' (video profile will be reapplied)"
    fi
fi

# ────────────────────────────────────────────────
# LED SCRIPT SELECTION
# ────────────────────────────────────────────────
if [ "$NEEDS_LED_UPDATE" = "1" ]; then
    case "$VARIANT" in
        r36s)     SELECTED="R36S_Green_30_Red.py" ;;
        soysauce) SELECTED="SoySauce_Blue_30_Pink_10_Red.py" ;;
        unknown)  SELECTED="Clone_PMIC_Controlled.py" ;;
        *)        SELECTED="Clone_Blue_30_Purple_10_Red.py" ;;
    esac

    SELECTED_PATH="$SCRIPT_DIR/$SELECTED"
    log "Selected LED script: $SELECTED"

    rm -f "$TARGET_LINK" 2>/dev/null || true
    if [ -f "$SELECTED_PATH" ]; then
        cp "$SELECTED_PATH" "$TARGET_LINK" 2>>"$LOG_FILE" && chmod +x "$TARGET_LINK" && log "Copied and made executable: $SELECTED"
    else
        log "CRITICAL: Source script missing: $SELECTED_PATH"
    fi
fi

# ────────────────────────────────────────────────
# CONTROL SCHEME HANDLING (modular)
# ────────────────────────────────────────────────
if [ "$NEEDS_CONTROLS_UPDATE" = "1" ]; then
    CONTROLS_SCRIPT="/usr/local/bin/r36_config/r36_controls.sh"
    if [ -x "$CONTROLS_SCRIPT" ]; then
        log "Executing modular controls: $CONTROLS_SCRIPT $CONTROL_SCHEME"
        "$CONTROLS_SCRIPT" "$CONTROL_SCHEME" 2>>"$LOG_FILE" || log "WARNING: r36_controls.sh returned non-zero"
    else
        log "WARNING: $CONTROLS_SCRIPT missing/not executable"
    fi
fi

# ────────────────────────────────────────────────
# VIDEO PROFILE HANDLING (mirrors controls exactly - NEW)
# ────────────────────────────────────────────────
if [ "$NEEDS_VIDEO_UPDATE" = "1" ]; then
    VIDEO_SCRIPT="/usr/local/bin/r36_config/r36_video.sh"
    if [ -x "$VIDEO_SCRIPT" ]; then
        log "Applying video profile for resolution: $RESOLUTION"
        "$VIDEO_SCRIPT" "$RESOLUTION" 2>>"$LOG_FILE" || log "WARNING: r36_video.sh returned non-zero"
    else
        log "WARNING: $VIDEO_SCRIPT missing/not executable"
    fi
fi

# ────────────────────────────────────────────────
# WRITE / UPDATE CONFIG FILE (now includes new GPIO fields)
# ────────────────────────────────────────────────
if [ "$NEEDS_LED_UPDATE" = "1" ] || [ "$NEEDS_CONTROLS_UPDATE" = "1" ] || [ "$NEEDS_VIDEO_UPDATE" = "1" ]; then
    log "Writing/updating config file (including speaker/headphone GPIOs)"

    TMP_CONFIG=$(mktemp /tmp/r36_config.XXXXXX 2>/dev/null) || true
    if [ -n "$TMP_CONFIG" ]; then
        cat > "$TMP_CONFIG" <<EOF
[Device]
hardware = $HARDWARE_RAW
variant = $VARIANT
config_version = 1.0
active_script = ${SELECTED:-None}
alsa_path = $ALSA_PATH
control_scheme = $CONTROL_SCHEME
gamma = $GAMMA_VALUE
resolution = $RESOLUTION
speaker_enable_gpio = ${SPEAKER_GPIO}
headphone_detect_gpio = ${HP_DETECT_GPIO}
EOF
        if mv "$TMP_CONFIG" "$CONFIG_FILE" 2>>"$LOG_FILE" && sync && chmod 666 "$CONFIG_FILE" 2>>"$LOG_FILE"; then
            log "Config successfully written via temp file: $CONFIG_FILE"
        else
            log "ERROR: Failed to move temp config or set permissions"
        fi
    else
        # fallback – use heredoc to reduce risk of partial writes
        log "mktemp failed - falling back to direct write"
        cat > "$CONFIG_FILE" <<EOF
[Device]
hardware = $HARDWARE_RAW
variant = $VARIANT
config_version = 1.0
active_script = ${SELECTED:-None}
alsa_path = $ALSA_PATH
control_scheme = $CONTROL_SCHEME
gamma = $GAMMA_VALUE
resolution = $RESOLUTION
speaker_enable_gpio = ${SPEAKER_GPIO}
headphone_detect_gpio = ${HP_DETECT_GPIO}
EOF
        sync
        chmod 666 "$CONFIG_FILE" 2>>"$LOG_FILE" || log "chmod failed in fallback (but file may still exist)"
        if [ -f "$CONFIG_FILE" ]; then
            log "Fallback direct write succeeded"
        else
            log "CRITICAL: Fallback write failed - config not created"
        fi
    fi
fi

# ────────────────────────────────────────────────
# GAMMA HANDLING (application only – value already looked up earlier)
# ────────────────────────────────────────────────
if [ -n "$GAMMA_VALUE" ] && [ -x "$GAMMA_BIN" ]; then
    log "Applying gamma $GAMMA_VALUE"
    "$GAMMA_BIN" -s "$GAMMA_VALUE" 2>>"$LOG_FILE" && log "Gamma applied successfully" || log "WARNING: gamma command failed"
fi
[ -n "$GAMMA_VALUE" ] && echo "$GAMMA_VALUE" > /dev/shm/CURRENT_GAMMA && chmod 666 /dev/shm/CURRENT_GAMMA

# ────────────────────────────────────────────────
# ALSA AUDIO HANDLING
# ────────────────────────────────────────────────
log "=== Starting ALSA audio configuration ==="

CUR_ALSA_PATH=$(grep '^alsa_path[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || echo "$ALSA_PATH")
log "Applying ALSA Playback Path: $CUR_ALSA_PATH"
# rk817 clone boards (e.g. G80CA-MB) power up with 'Playback Path' already at the
# target value, so re-setting the same value is a no-op: the codec never reprograms
# the output route and there is NO audio on cold boot until a suspend/resume.
# Force a real transition (OFF -> target) so the driver reprograms/enables the route.
amixer -c 0 cset iface=MIXER,name='Playback Path' 'OFF' 2>>"$LOG_FILE" || true
sleep 1
amixer -c 0 cset iface=MIXER,name='Playback Path' "$CUR_ALSA_PATH" 2>>"$LOG_FILE" || log "WARNING: amixer Playback Path failed"

OGAGE_SRC="$OGAGE_DIR/ogage.${CUR_ALSA_PATH}"
if [ -f "$OGAGE_SRC" ]; then
    log "Copying ogage for $CUR_ALSA_PATH"
    cp "$OGAGE_SRC" /usr/local/bin/ogage && chmod +x /usr/local/bin/ogage
else
    log "WARNING: ogage source missing for $CUR_ALSA_PATH"
fi

ALSA_VOLUME=""
if [ -f "$CONFIG_FILE" ]; then
    ALSA_VOLUME=$(grep '^alsa_volume[ \t]*=' "$CONFIG_FILE" | cut -d'=' -f2 | xargs || true)
fi

if [ -n "$ALSA_VOLUME" ]; then
    log "Setting persistent boot volume from config: ${ALSA_VOLUME}%"
    amixer -c 0 -M sset 'Playback' "${ALSA_VOLUME}%" 2>>"$LOG_FILE" || log "amixer volume (config) failed"
elif [ "$NEEDS_LED_UPDATE" = "1" ]; then
    log "First boot/hardware change - setting default boot volume 80%"
    amixer -c 0 -M sset 'Playback' 80% 2>>"$LOG_FILE" || log "amixer default volume failed"
else
    log "No alsa_volume in config and not first boot - leaving volume untouched (manual control)"
fi

log "ALSA audio configuration complete."

# ────────────────────────────────────────────────
# DYNAMIC SPEAKER + HEADPHONE DETECT GPIO SETUP
# (runs every boot if configured - export + permissions for ark + initial state)
# This fixes speaker mute conflicts when switching ALSA paths and prevents double-power-button issues
# ────────────────────────────────────────────────
if [ -n "$SPEAKER_GPIO" ]; then
    log "=== [r36_config] Setting up speaker GPIO $SPEAKER_GPIO (and HP detect if present) ==="

    # 1. Setup Speaker GPIO (output)
    if [ ! -d "/sys/class/gpio/gpio$SPEAKER_GPIO" ]; then
        echo "$SPEAKER_GPIO" > /sys/class/gpio/export 2>>"$LOG_FILE" || log "WARNING: Failed to export speaker GPIO $SPEAKER_GPIO"
    fi
    echo "out" > "/sys/class/gpio/gpio$SPEAKER_GPIO/direction" 2>>"$LOG_FILE" || log "WARNING: Failed to set speaker direction out"

    # Permissions for ogage (runs as ark)
    chown ark:ark "/sys/class/gpio/gpio$SPEAKER_GPIO/value" 2>>"$LOG_FILE" || log "WARNING: chown speaker failed"
    chmod 666 "/sys/class/gpio/gpio$SPEAKER_GPIO/value" 2>>"$LOG_FILE" || log "WARNING: chmod speaker 666 failed"

    # 2. Setup Headphone Detect GPIO (input) if configured
    if [ -n "$HP_DETECT_GPIO" ]; then
        if [ ! -d "/sys/class/gpio/gpio$HP_DETECT_GPIO" ]; then
            echo "$HP_DETECT_GPIO" > /sys/class/gpio/export 2>>"$LOG_FILE" || log "WARNING: Failed to export HP detect GPIO $HP_DETECT_GPIO"
        fi
        echo "in" > "/sys/class/gpio/gpio$HP_DETECT_GPIO/direction" 2>>"$LOG_FILE" || log "WARNING: Failed to set HP direction in"
        chown ark:ark "/sys/class/gpio/gpio$HP_DETECT_GPIO/value" 2>>"$LOG_FILE" || log "WARNING: chown HP detect failed"
        chmod 666 "/sys/class/gpio/gpio$HP_DETECT_GPIO/value" 2>>"$LOG_FILE" || log "WARNING: chmod HP detect 666 failed"
        log "Headphone detect GPIO $HP_DETECT_GPIO ready for ogage"
    fi

    # 3. Determine and set initial speaker state (reversed logic as confirmed)
    INITIAL=1  # default speaker ON
    if [ -n "$HP_DETECT_GPIO" ] && [ -f "/sys/class/gpio/gpio$HP_DETECT_GPIO/value" ]; then
        HP_STATE=$(cat "/sys/class/gpio/gpio$HP_DETECT_GPIO/value" 2>/dev/null | tr -d ' \n\r' || echo "0")
        if [ "$HP_STATE" = "1" ]; then
            INITIAL=0
            log "Headphones detected (HP=$HP_STATE) → speaker MUTED (value=0)"
        else
            INITIAL=1
            log "No headphones (HP=$HP_STATE) → speaker ENABLED (value=1)"
        fi
    else
        log "No valid headphone_detect_gpio → default speaker ON (1)"
    fi

    echo "$INITIAL" > "/sys/class/gpio/gpio$SPEAKER_GPIO/value" 2>>"$LOG_FILE" || log "WARNING: Failed to set initial speaker value"
    log "✅ Speaker GPIO $SPEAKER_GPIO initialized to $INITIAL | Current value: $(cat "/sys/class/gpio/gpio$SPEAKER_GPIO/value" 2>/dev/null || echo 'ERROR')"
fi

# Safer enforcement of control scheme on first boot / config regen
if [ "$NEEDS_LED_UPDATE" = "1" ] || [ "$NEEDS_CONTROLS_UPDATE" = "1" ] || [ ! -f "$CONFIG_FILE" ]; then
        log "Detected first boot / config change - attempting to enforce control scheme: $CONTROL_SCHEME"

        if [ -x "/usr/local/bin/r36_config/r36_controls.sh" ]; then
                (
                        set +e
                        /usr/local/bin/r36_config/r36_controls.sh "$CONTROL_SCHEME" >> "$LOG_FILE" 2>&1
                        status=$?
                        if [ $status -eq 0 ]; then
                                log "Control scheme '$CONTROL_SCHEME' applied OK during early boot"
                        else
                                log "WARNING: Early boot scheme apply exited $status - manual re-apply may be needed"
                        fi
                ) || true
        else
                log "WARNING: r36_controls.sh not executable - skipping early scheme apply"
        fi
fi

log "Early boot configuration complete (LED + audio + controls + VIDEO + speaker GPIO fully synced)."
exit 0
