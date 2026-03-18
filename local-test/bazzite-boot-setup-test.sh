#!/usr/bin/bash
set -euo pipefail

# Standalone test script for `bazzite-boot-setup`
#
# Typical usage on an installed system:
#   sudo bash bazzite-boot-setup-test.sh
#
# Useful options:
#   sudo bash bazzite-boot-setup-test.sh --force-shortcut
#   sudo bash bazzite-boot-setup-test.sh --skip-mount
#   sudo bash bazzite-boot-setup-test.sh --launcher-archive /path/to/df-launcher.7z

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_LAUNCHER_URL="https://coscdnsintl-1251626029.cos.ap-hongkong.myqcloud.com/iedsafe/Client/drv/aceos/df-launcher.7z"
DOWNLOADED_ARCHIVE=""

BASE_MOUNT_DIR="${BASE_MOUNT_DIR:-/run/media/bazzite-auto}"
LAUNCHER_ARCHIVE="${LAUNCHER_ARCHIVE:-}"
LAUNCHER_NAME="df-launcher"
LAUNCHER_EXE_NAME="delta_force_launcher.exe"
UMU_RUN_BIN="${UMU_RUN_BIN:-$(command -v umu-run 2>/dev/null || true)}"
UMU_GAMEID="${UMU_GAMEID:-umu-default}"
UMU_RUNTIME_NAME="${UMU_RUNTIME_NAME:-steamrt3}"
UMU_PROTON_NAME="${UMU_PROTON_NAME:-GE-Proton10-28}"
TARGET_USER="${TARGET_USER:-}"
TARGET_UID="${TARGET_UID:-}"
TARGET_GID="${TARGET_GID:-}"
TARGET_HOME="${TARGET_HOME:-}"
TARGET_DESKTOP_DIR="${TARGET_DESKTOP_DIR:-}"
FORCE_SHORTCUT=0
SKIP_MOUNT=0

DF_LAUNCHER_DIR=""
DF_LAUNCHER_EXE_PATH=""
DELTAFORCE_GAME_EXE_PATH=""
DELTAFORCE_BINARY_DIR=""
DELTAFORCE_INSTALL_ROOT=""
DELTAFORCE_WINDOWS_INSTALL_PATH=""
DELTAFORCE_WINDOWS_SETUP_PATH=""
declare -a MOUNTED_DIRS=()

log() {
    printf '[bazzite-boot-setup-test] %s\n' "$*"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "Missing required command: $1"
        exit 1
    }
}

usage() {
    cat <<'EOF'
Usage: sudo bash bazzite-boot-setup-test.sh [options]

Options:
  --user USER              Target desktop user
  --home PATH              Target user home directory
  --desktop-dir PATH       Explicit desktop directory
  --base-mount-dir PATH    Override auto-mount base directory
  --launcher-archive PATH  Path to df-launcher.7z
  --force-shortcut         Overwrite/update existing DeltaForce.desktop
  --skip-mount             Skip part 1 mounting, only scan existing auto-mounted disks
  -h, --help               Show this help
EOF
}

sanitize_name() {
    local value="$1"
    value="$(printf '%s' "$value" | tr -cs '[:alnum:]._-' '_')"
    value="${value#_}"
    value="${value%_}"
    printf '%s' "${value:-volume}"
}

register_mounted_dir() {
    local dir="$1"
    local existing

    [[ -n "$dir" ]] || return 0
    [[ -d "$dir" ]] || return 0

    for existing in "${MOUNTED_DIRS[@]}"; do
        [[ "$existing" == "$dir" ]] && return 0
    done

    MOUNTED_DIRS+=("$dir")
}

resolve_desktop_dir() {
    local home_dir="$1"
    local user_dirs_file="${home_dir}/.config/user-dirs.dirs"
    local desktop_dir

    if [[ -r "$user_dirs_file" ]]; then
        desktop_dir="$(awk -F= '/^XDG_DESKTOP_DIR=/{print $2; exit}' "$user_dirs_file" | tr -d '"' || true)"
        if [[ -n "$desktop_dir" ]]; then
            desktop_dir="${desktop_dir//\$HOME/$home_dir}"
            printf '%s\n' "$desktop_dir"
            return 0
        fi
    fi

    printf '%s\n' "${home_dir}/Desktop"
}

desktop_escape_exec_arg() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

linux_path_to_wine_path() {
    local value="$1"

    value="${value//\//\\}"
    printf 'Z:%s' "$value"
}

resolve_launcher_exe_path() {
    find "$DF_LAUNCHER_DIR" -type f -iname "$LAUNCHER_EXE_NAME" -print -quit 2>/dev/null || true
}

compute_deltaforce_registry_paths() {
    if [[ "$DELTAFORCE_GAME_EXE_PATH" == */DeltaForce/Binaries/Win64/DeltaForceClient-Win64-Shipping.exe ]]; then
        DELTAFORCE_INSTALL_ROOT="${DELTAFORCE_GAME_EXE_PATH%/DeltaForce/Binaries/Win64/DeltaForceClient-Win64-Shipping.exe}"
    else
        DELTAFORCE_INSTALL_ROOT="$DELTAFORCE_BINARY_DIR"
    fi

    DELTAFORCE_WINDOWS_INSTALL_PATH="$(linux_path_to_wine_path "$DELTAFORCE_INSTALL_ROOT")"
    DELTAFORCE_WINDOWS_SETUP_PATH="$(linux_path_to_wine_path "$DELTAFORCE_GAME_EXE_PATH")"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                TARGET_USER="$2"
                shift 2
                ;;
            --home)
                TARGET_HOME="$2"
                shift 2
                ;;
            --desktop-dir)
                TARGET_DESKTOP_DIR="$2"
                shift 2
                ;;
            --base-mount-dir)
                BASE_MOUNT_DIR="$2"
                shift 2
                ;;
            --launcher-archive)
                LAUNCHER_ARCHIVE="$2"
                shift 2
                ;;
            --force-shortcut)
                FORCE_SHORTCUT=1
                shift
                ;;
            --skip-mount)
                SKIP_MOUNT=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

resolve_launcher_archive() {
    if [[ -n "$LAUNCHER_ARCHIVE" ]]; then
        return 0
    fi

    if [[ -f "/usr/share/bazzite/games/df-launcher.7z" ]]; then
        LAUNCHER_ARCHIVE="/usr/share/bazzite/games/df-launcher.7z"
        return 0
    fi

    need_cmd curl
    need_cmd mktemp

    DOWNLOADED_ARCHIVE="$(mktemp /tmp/df-launcher.XXXXXX.7z)"
    log "Downloading df-launcher.7z from CDN..."
    curl --retry 3 -L -o "$DOWNLOADED_ARCHIVE" "$DEFAULT_LAUNCHER_URL"
    LAUNCHER_ARCHIVE="$DOWNLOADED_ARCHIVE"
}

resolve_target_user() {
    local record=""
    local detected_home=""

    if [[ -n "$TARGET_USER" ]]; then
        record="$(getent passwd "$TARGET_USER" || true)"
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        record="$(getent passwd "$SUDO_USER" || true)"
    elif [[ "$(id -u)" -ne 0 ]]; then
        TARGET_USER="$(id -un)"
        TARGET_UID="$(id -u)"
        TARGET_GID="$(id -g)"
        TARGET_HOME="${HOME}"
    else
        record="$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print; exit }' /etc/passwd || true)"
    fi

    if [[ -n "$record" ]]; then
        IFS=: read -r TARGET_USER _ TARGET_UID TARGET_GID _ detected_home _ <<< "$record"
        [[ -n "$TARGET_HOME" ]] || TARGET_HOME="$detected_home"
    fi

    [[ -n "$TARGET_USER" ]] || {
        log "Unable to determine target desktop user. Use --user to specify one."
        exit 1
    }
    [[ -n "$TARGET_UID" ]] || TARGET_UID="$(id -u "$TARGET_USER")"
    [[ -n "$TARGET_GID" ]] || TARGET_GID="$(id -g "$TARGET_USER")"
    [[ -n "$TARGET_HOME" ]] || {
        log "Unable to determine home directory for ${TARGET_USER}. Use --home to specify one."
        exit 1
    }

    [[ -n "$TARGET_DESKTOP_DIR" ]] || TARGET_DESKTOP_DIR="$(resolve_desktop_dir "$TARGET_HOME")"

    log "Target user: ${TARGET_USER}"
    log "Target home: ${TARGET_HOME}"
    log "Target desktop dir: ${TARGET_DESKTOP_DIR}"
}

run_umu_as_target_user() {
    if [[ "$(id -u)" -eq 0 ]]; then
        runuser -u "$TARGET_USER" -- \
            env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
            UMU_RUNTIME_UPDATE=0 RUNTIMEPATH="$UMU_RUNTIME_NAME" PROTONPATH="$UMU_PROTON_NAME" \
            GAMEID="$UMU_GAMEID" WINEPREFIX="${TARGET_HOME}/Games/umu/${UMU_GAMEID}" \
            "$UMU_RUN_BIN" "$@"
    else
        env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
            UMU_RUNTIME_UPDATE=0 RUNTIMEPATH="$UMU_RUNTIME_NAME" PROTONPATH="$UMU_PROTON_NAME" \
            GAMEID="$UMU_GAMEID" WINEPREFIX="${TARGET_HOME}/Games/umu/${UMU_GAMEID}" \
            "$UMU_RUN_BIN" "$@"
    fi
}

collect_existing_auto_mounts() {
    local dir

    [[ -d "$BASE_MOUNT_DIR" ]] || return 0

    while IFS= read -r -d '' dir; do
        if mountpoint -q "$dir"; then
            register_mounted_dir "$dir"
        fi
    done < <(find "$BASE_MOUNT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

# part 1: mount ntfs/exfat disks
part_1_mount_ntfs_exfat_disks() {
    local dev type fstype uuid label mountpoint existing_mount name_source safe_name target_dir index opts

    mkdir -p "$BASE_MOUNT_DIR"
    collect_existing_auto_mounts

    if [[ "$SKIP_MOUNT" -eq 1 ]]; then
        log "Skipping mount step; will only scan existing mounts under ${BASE_MOUNT_DIR}."
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        log "Mount step requires root. Re-run with sudo or use --skip-mount."
        exit 1
    fi

    while IFS=$'\t' read -r dev type fstype uuid label mountpoint; do
        [[ -z "$dev" || -z "$fstype" ]] && continue

        case "$type" in
            part|disk) ;;
            *) continue ;;
        esac

        case "$fstype" in
            ntfs|ntfs3|exfat) ;;
            *) continue ;;
        esac

        existing_mount="$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null | head -n1 || true)"
        if [[ -n "$existing_mount" ]]; then
            if [[ "$existing_mount" == "$BASE_MOUNT_DIR"/* ]]; then
                register_mounted_dir "$existing_mount"
                log "Reusing existing auto-mounted disk: ${existing_mount}"
            fi
            continue
        fi

        [[ -n "$mountpoint" ]] && continue

        name_source="$label"
        [[ -n "$name_source" ]] || name_source="$uuid"
        [[ -n "$name_source" ]] || name_source="${dev##*/}"

        safe_name="$(sanitize_name "$name_source")"
        target_dir="$BASE_MOUNT_DIR/$safe_name"
        index=1
        while [[ -e "$target_dir" ]] && ! mountpoint -q "$target_dir"; do
            target_dir="$BASE_MOUNT_DIR/${safe_name}_$index"
            index=$((index + 1))
        done

        mkdir -p "$target_dir"

        if [[ "$fstype" == "exfat" ]]; then
            opts="rw,uid=${TARGET_UID},gid=${TARGET_GID},umask=022"
            if mount -t exfat -o "$opts" "$dev" "$target_dir"; then
                register_mounted_dir "$target_dir"
                log "Mounted ${dev} -> ${target_dir} (exfat)"
            else
                log "Failed to mount ${dev} to ${target_dir}"
                rmdir "$target_dir" 2>/dev/null || true
            fi
        else
            opts="rw,uid=${TARGET_UID},gid=${TARGET_GID},umask=022,windows_names"
            if mount -t ntfs3 -o "$opts" "$dev" "$target_dir"; then
                register_mounted_dir "$target_dir"
                log "Mounted ${dev} -> ${target_dir} (ntfs3)"
            else
                log "Failed to mount ${dev} to ${target_dir}"
                rmdir "$target_dir" 2>/dev/null || true
            fi
        fi
    done < <(
        lsblk -Jpo NAME,TYPE,FSTYPE,UUID,LABEL,MOUNTPOINT \
          | jq -r '.. | objects | select(has("name")) | [(.name // ""), (.type // ""), (.fstype // ""), (.uuid // ""), (.label // ""), (.mountpoint // "")] | @tsv'
    )
}

# part 2: unpack df-launcher into ~/Games
part_2_install_df_launcher() {
    local games_dir state_file expected_state

    [[ -f "$LAUNCHER_ARCHIVE" ]] || {
        log "Missing Delta Force launcher archive: $LAUNCHER_ARCHIVE"
        exit 1
    }

    games_dir="${TARGET_HOME}/Games"
    DF_LAUNCHER_DIR="${games_dir}/${LAUNCHER_NAME}"
    state_file="${games_dir}/.${LAUNCHER_NAME}-source-sha256"
    expected_state="$(sha256sum "$LAUNCHER_ARCHIVE" | awk '{print $1}')"

    if [[ "$(id -u)" -eq 0 ]]; then
        install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$games_dir"
    else
        install -d -m 0755 "$games_dir"
    fi

    if [[ -f "$state_file" ]] && [[ "$(<"$state_file")" == "$expected_state" ]] && [[ -d "$DF_LAUNCHER_DIR" ]]; then
        DF_LAUNCHER_EXE_PATH="$(resolve_launcher_exe_path)"
        if [[ -n "$DF_LAUNCHER_EXE_PATH" ]]; then
            log "Delta Force launcher already prepared at ${DF_LAUNCHER_DIR}."
            return 0
        fi
    fi

    log "Extracting Delta Force launcher into ${DF_LAUNCHER_DIR}..."
    rm -rf "$DF_LAUNCHER_DIR"

    if [[ "$(id -u)" -eq 0 ]]; then
        install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$DF_LAUNCHER_DIR"
    else
        install -d -m 0755 "$DF_LAUNCHER_DIR"
    fi

    7z x -y "-o${DF_LAUNCHER_DIR}" "$LAUNCHER_ARCHIVE" >/dev/null
    DF_LAUNCHER_EXE_PATH="$(resolve_launcher_exe_path)"

    [[ -n "$DF_LAUNCHER_EXE_PATH" ]] || {
        log "Unable to find ${LAUNCHER_EXE_NAME} after extracting ${LAUNCHER_ARCHIVE}"
        exit 1
    }

    printf '%s\n' "$expected_state" > "$state_file"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R "$TARGET_UID:$TARGET_GID" "$DF_LAUNCHER_DIR" "$state_file"
    fi
}

# part 3: search mounted disks for Delta Force install
part_3_find_deltaforce_install_dir() {
    local mount_dir exe_path candidate_dir

    for mount_dir in "${MOUNTED_DIRS[@]}"; do
        log "Scanning ${mount_dir} for Delta Force..."

        while IFS= read -r -d '' exe_path; do
            candidate_dir="${exe_path%/*}"
            if [[ -f "${candidate_dir}/DeltaForceClient-Win64-ShippingBase.dll" ]] && \
               [[ -d "${candidate_dir}/AntiCheatExpert" ]]; then
                DELTAFORCE_GAME_EXE_PATH="$exe_path"
                DELTAFORCE_BINARY_DIR="$candidate_dir"
                compute_deltaforce_registry_paths
                log "Found Delta Force install at ${DELTAFORCE_BINARY_DIR}."
                return 0
            fi
        done < <(find "$mount_dir" -type f -name 'DeltaForceClient-Win64-Shipping.exe' -print0 2>/dev/null)
    done

    return 1
}

# part 4: import Delta Force registry values into the umu prefix
part_4_import_deltaforce_registry() {
    local prefix_dir="${TARGET_HOME}/Games/umu/${UMU_GAMEID}"

    if [[ "$(id -u)" -eq 0 ]]; then
        install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "${TARGET_HOME}/Games" "$prefix_dir"
    else
        install -d -m 0755 "${TARGET_HOME}/Games" "$prefix_dir"
    fi

    log "Importing Delta Force registry values into ${prefix_dir}..."
    run_umu_as_target_user reg.exe ADD 'HKCU\SOFTWARE\Rail\Dfmclient-Win64-Test' /v InstallPath /t REG_SZ /d "$DELTAFORCE_WINDOWS_INSTALL_PATH" /f
    run_umu_as_target_user reg.exe ADD 'HKCU\SOFTWARE\Rail\Dfmclient-Win64-Test' /v setup /t REG_SZ /d "$DELTAFORCE_WINDOWS_SETUP_PATH" /f
    run_umu_as_target_user reg.exe ADD 'HKCU\SOFTWARE\Rail\Dfmclient-Win64-Test' /v setup_x64 /t REG_SZ /d '' /f
}

# part 5: create or refresh DeltaForce desktop shortcut
part_5_create_deltaforce_desktop_shortcut() {
    local desktop_file escaped_exe_path expected_exec expected_path

    escaped_exe_path="$(desktop_escape_exec_arg "$DF_LAUNCHER_EXE_PATH")"
    desktop_file="${TARGET_DESKTOP_DIR}/DeltaForce.desktop"
    expected_exec="Exec=env UMU_RUNTIME_UPDATE=0 RUNTIMEPATH=${UMU_RUNTIME_NAME} PROTONPATH=${UMU_PROTON_NAME} GAMEID=${UMU_GAMEID} WINEPREFIX=${TARGET_HOME}/Games/umu/${UMU_GAMEID} umu-run \"${escaped_exe_path}\""
    expected_path="Path=${DF_LAUNCHER_DIR}"

    if [[ -f "$desktop_file" ]] && [[ "$FORCE_SHORTCUT" -eq 0 ]] && grep -Fqx "$expected_exec" "$desktop_file" && grep -Fqx "$expected_path" "$desktop_file"; then
        log "DeltaForce desktop shortcut already up to date at ${desktop_file}."
        return 0
    fi

    install -d -m 0755 "$TARGET_DESKTOP_DIR"

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=DeltaForce
Comment=Launch Delta Force launcher with umu-run
Exec=env UMU_RUNTIME_UPDATE=0 RUNTIMEPATH=${UMU_RUNTIME_NAME} PROTONPATH=${UMU_PROTON_NAME} GAMEID=${UMU_GAMEID} WINEPREFIX=${TARGET_HOME}/Games/umu/${UMU_GAMEID} umu-run "$escaped_exe_path"
Path=${DF_LAUNCHER_DIR}
Terminal=false
Categories=Game;
StartupNotify=true
EOF

    chmod 0755 "$desktop_file"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown "$TARGET_UID:$TARGET_GID" "$desktop_file"
        chown "$TARGET_UID:$TARGET_GID" "$TARGET_DESKTOP_DIR"
    fi

    log "Created DeltaForce desktop shortcut at ${desktop_file}."
}

main() {
    parse_args "$@"
    resolve_launcher_archive

    for cmd in 7z awk cat chmod find findmnt getent grep head id install jq lsblk mkdir mount mountpoint rm rmdir runuser sha256sum tr; do
        need_cmd "$cmd"
    done

    [[ -n "$UMU_RUN_BIN" ]] || {
        log "Unable to locate umu-run in PATH."
        exit 1
    }

    resolve_target_user
    part_1_mount_ntfs_exfat_disks
    part_2_install_df_launcher

    if part_3_find_deltaforce_install_dir; then
        part_4_import_deltaforce_registry
        part_5_create_deltaforce_desktop_shortcut
        log "Test completed successfully."
    else
        log "No Delta Force install found on auto-mounted NTFS/exFAT disks."
        exit 1
    fi
}

main "$@"
