#!/usr/bin/env bash
set -euo pipefail

# Local test helper for validating the umu offline setup on an already installed system.
# This version targets umu-launcher 1.2.9 semantics and installs assets into the
# target user's XDG data directory for easy local verification.
#
# Usage:
#   bash umu-offline-test.sh
#   sudo bash umu-offline-test.sh
# Optional overrides:
#   TARGET_USER=alice bash umu-offline-test.sh
#   TARGET_HOME=/home/alice bash umu-offline-test.sh
#   TARGET_XDG_DATA_HOME=/home/alice/.local/share bash umu-offline-test.sh
#   CACHE_DIR=/var/cache/umu-offline-test bash umu-offline-test.sh

RUNTIME_NAME="${RUNTIME_NAME:-SteamLinuxRuntime_sniper}"
PROTON_NAME="${PROTON_NAME:-GE-Proton10-28}"
RUNTIME_URL="${RUNTIME_URL:-https://repo.steampowered.com/steamrt3/images/latest-container-runtime-public-beta/SteamLinuxRuntime_sniper.tar.xz}"
PROTON_URL="${PROTON_URL:-https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton10-28/GE-Proton10-28.tar.gz}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="${TARGET_HOME:-}"
TARGET_XDG_DATA_HOME="${TARGET_XDG_DATA_HOME:-}"
TARGET_XDG_CONFIG_HOME="${TARGET_XDG_CONFIG_HOME:-}"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}

curl_download() {
    local url="$1"
    local output="$2"
    local -a curl_args=(--fail --location --retry 3 --retry-delay 2 --retry-max-time 300 -o "$output")

    if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://github.com/* ]]; then
        curl "${curl_args[@]}" -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
    else
        curl "${curl_args[@]}" "$url"
    fi
}

write_shim() {
    local file_path="$1"

    cat > "$file_path" <<'EOF'
#!/bin/sh

if [ "${XDG_CURRENT_DESKTOP}" = "gamescope" ] || [ "${XDG_SESSION_DESKTOP}" = "gamescope" ]; then
    if [ "${STEAM_MULTIPLE_XWAYLANDS}" = "1" ] && [ -z "${DISPLAY}" ]; then
        export DISPLAY=":1"
    fi
fi

exec "$@"
EOF

    chmod 0700 "$file_path"
}

resolve_home() {
    local user="$1"

    if [[ -n "$TARGET_HOME" ]]; then
        printf '%s\n' "$TARGET_HOME"
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        getent passwd "$user" | awk -F: 'NR == 1 { print $6 }'
        return 0
    fi

    eval "printf '%s\\n' ~${user}"
}

for cmd in awk cat chmod chown cp curl id install ln mkdir mktemp mv rm sha256sum tar; do
    need_cmd "$cmd"
done

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "Target user does not exist: $TARGET_USER" >&2
    exit 1
fi

TARGET_HOME="$(resolve_home "$TARGET_USER")"
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "Unable to resolve a valid home directory for user: $TARGET_USER" >&2
    exit 1
fi

TARGET_XDG_DATA_HOME="${TARGET_XDG_DATA_HOME:-${TARGET_HOME}/.local/share}"
TARGET_XDG_CONFIG_HOME="${TARGET_XDG_CONFIG_HOME:-${TARGET_HOME}/.config}"
ENV_FILE="${ENV_FILE:-${TARGET_XDG_CONFIG_HOME}/environment.d/90-umu-offline-test.conf}"
ENV_DIR="$(dirname "$ENV_FILE")"

if [[ -n "${CACHE_DIR:-}" ]]; then
    :
elif [[ "$EUID" -eq 0 ]]; then
    CACHE_DIR="/var/cache/umu-offline-test"
else
    CACHE_DIR="${HOME}/.cache/umu-offline-test"
fi

RUNTIME_ARCHIVE="${CACHE_DIR}/${RUNTIME_NAME}.tar.xz"
PROTON_ARCHIVE="${CACHE_DIR}/${PROTON_NAME}.tar.gz"
UMU_LOCAL="${TARGET_XDG_DATA_HOME}/umu"
UMU_COMPAT_DIR="${UMU_LOCAL}/compatibilitytools"
STEAM_COMPAT_DIR="${TARGET_XDG_DATA_HOME}/Steam/compatibilitytools.d"
RUNTIME_DIR="${UMU_LOCAL}/steamrt3"
PROTON_DIR="${STEAM_COMPAT_DIR}/${PROTON_NAME}"
STATE_FILE="${UMU_LOCAL}/.offline-source-sha256"
DEFAULT_XDG_DATA_HOME="${TARGET_HOME}/.local/share"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

install -d -m 0755 "$CACHE_DIR" "$UMU_LOCAL" "$UMU_COMPAT_DIR" "$STEAM_COMPAT_DIR" "$ENV_DIR"

echo "Target user: ${TARGET_USER}"
echo "Target home: ${TARGET_HOME}"
echo "Target XDG data home: ${TARGET_XDG_DATA_HOME}"
echo "Target XDG config home: ${TARGET_XDG_CONFIG_HOME}"
echo

echo "Downloading Steam runtime archive..."
curl_download "$RUNTIME_URL" "$RUNTIME_ARCHIVE"

echo "Downloading Proton archive..."
curl_download "$PROTON_URL" "$PROTON_ARCHIVE"

expected_state="$({ sha256sum "$RUNTIME_ARCHIVE"; sha256sum "$PROTON_ARCHIVE"; } | sha256sum | awk '{print $1}')"

if [[ -f "$STATE_FILE" ]] && [[ "$(<"$STATE_FILE")" == "$expected_state" ]] && \
   [[ -f "${RUNTIME_DIR}/.installed.ok" ]] && \
   [[ -x "${RUNTIME_DIR}/umu" ]] && \
   [[ -x "${RUNTIME_DIR}/umu-shim" ]] && \
   [[ -f "${PROTON_DIR}/toolmanifest.vdf" ]] && \
   [[ -f "${PROTON_DIR}/compatibilitytool.vdf" ]] && \
   [[ -x "${PROTON_DIR}/proton" ]]; then
    echo "umu offline assets already prepared; refreshing shims and environment file only."
else
    tmpdir="$(mktemp -d /var/tmp/umu-offline-test.XXXXXX)"
    trap 'rm -rf "$tmpdir"' EXIT

    runtime_stage="${tmpdir}/steamrt3"
    proton_stage_root="${tmpdir}/proton"
    proton_stage_dir="${proton_stage_root}/${PROTON_NAME}"

    mkdir -p "$runtime_stage" "$proton_stage_root"

    echo "Extracting Steam runtime..."
    tar -xJf "$RUNTIME_ARCHIVE" -C "$tmpdir"
    if [[ ! -d "${tmpdir}/${RUNTIME_NAME}" ]]; then
        echo "Expected runtime directory ${RUNTIME_NAME} was not found after extraction" >&2
        exit 1
    fi
    cp -a "${tmpdir}/${RUNTIME_NAME}/." "$runtime_stage/"

    [[ -d "${runtime_stage}/pressure-vessel" ]] || { echo "Missing pressure-vessel in extracted Steam runtime" >&2; exit 1; }
    [[ -f "${runtime_stage}/VERSIONS.txt" ]] || { echo "Missing VERSIONS.txt in extracted Steam runtime" >&2; exit 1; }
    [[ -f "${runtime_stage}/mtree.txt.gz" ]] || { echo "Missing mtree.txt.gz in extracted Steam runtime" >&2; exit 1; }
    compgen -G "${runtime_stage}/sniper_platform_*" >/dev/null || { echo "Missing sniper_platform_* directory in extracted Steam runtime" >&2; exit 1; }
    [[ -f "${runtime_stage}/_v2-entry-point" ]] || { echo "Missing _v2-entry-point in extracted Steam runtime" >&2; exit 1; }
    mv "${runtime_stage}/_v2-entry-point" "${runtime_stage}/umu"
    chmod 0755 "${runtime_stage}/umu"
    write_shim "${runtime_stage}/umu-shim"
    : > "${runtime_stage}/.installed.ok"

    echo "Extracting Proton..."
    tar -xzf "$PROTON_ARCHIVE" -C "$proton_stage_root"
    if [[ ! -d "$proton_stage_dir" ]]; then
        echo "Expected proton directory ${PROTON_NAME} was not found after extraction" >&2
        exit 1
    fi

    [[ -f "${proton_stage_dir}/toolmanifest.vdf" ]] || { echo "Missing toolmanifest.vdf in extracted Proton" >&2; exit 1; }
    [[ -f "${proton_stage_dir}/compatibilitytool.vdf" ]] || { echo "Missing compatibilitytool.vdf in extracted Proton" >&2; exit 1; }
    [[ -x "${proton_stage_dir}/proton" ]] || { echo "Missing proton executable in extracted Proton" >&2; exit 1; }

    rm -rf "$RUNTIME_DIR"
    mv "$runtime_stage" "$RUNTIME_DIR"

    rm -rf "$PROTON_DIR"
    mv "$proton_stage_dir" "$PROTON_DIR"

    rm -rf "${UMU_COMPAT_DIR:?}/${PROTON_NAME}"
    ln -sfn "../../Steam/compatibilitytools.d/${PROTON_NAME}" "${UMU_COMPAT_DIR}/${PROTON_NAME}"

    chmod -R a+rX "$RUNTIME_DIR" "$PROTON_DIR"
    printf '%s\n' "$expected_state" > "$STATE_FILE"
fi

write_shim "${RUNTIME_DIR}/umu-shim"

cat <<EOF > "$ENV_FILE"
# umu-launcher 1.2.9 offline test environment
UMU_RUNTIME_UPDATE=0
RUNTIMEPATH=steamrt3
PROTONPATH=${PROTON_NAME}
EOF

if [[ "$TARGET_XDG_DATA_HOME" != "$DEFAULT_XDG_DATA_HOME" ]]; then
    cat <<EOF >> "$ENV_FILE"
XDG_DATA_HOME=${TARGET_XDG_DATA_HOME}
EOF
fi

if [[ "$EUID" -eq 0 ]]; then
    chown -R "$TARGET_UID:$TARGET_GID" "$UMU_LOCAL" "$STEAM_COMPAT_DIR"
    chown "$TARGET_UID:$TARGET_GID" "$ENV_DIR" "$ENV_FILE"
fi

echo
echo "umu offline assets are ready for user ${TARGET_USER}."
echo "Runtime dir : ${RUNTIME_DIR}"
echo "Proton dir  : ${PROTON_DIR}"
echo "Env file    : ${ENV_FILE}"
echo
echo "If you previously exported UMU_FOLDERS_PATH, unset it before testing this XDG-based layout."
echo "Open a new login session for ${TARGET_USER}, or run the following in that user's shell:"
echo "  unset UMU_FOLDERS_PATH"
echo "  export UMU_RUNTIME_UPDATE=0"
echo "  export RUNTIMEPATH=steamrt3"
echo "  export PROTONPATH=${PROTON_NAME}"
if [[ "$TARGET_XDG_DATA_HOME" != "$DEFAULT_XDG_DATA_HOME" ]]; then
    echo "  export XDG_DATA_HOME=${TARGET_XDG_DATA_HOME}"
fi
