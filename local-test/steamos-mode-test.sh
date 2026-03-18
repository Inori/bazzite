#!/usr/bin/env bash

set -Eeuo pipefail

STATE_DIR="/var/lib/bazzite-steamos-test"
BACKUP_DIR="${STATE_DIR}/backup"
STATE_FILE="${STATE_DIR}/state.env"
AUTOLOGIN_CONF="/etc/sddm.conf.d/zz-bazzite-steamos-test.conf"
GLOBAL_LOCK_CONF="/etc/xdg/kscreenlockerrc"
SUDO_PAM_FILE="/etc/pam.d/sudo"
SUDO_PASSWORD_HELPER_DIR="${STATE_DIR}/bin"
SUDO_PASSWORD_HELPER="${SUDO_PASSWORD_HELPER_DIR}/require-user-password-for-sudo"
SUDO_PASSWORD_PAM_LINE="auth       requisite     pam_exec.so quiet stdout ${SUDO_PASSWORD_HELPER}"
MODE="apply"
TARGET_USER=""
TARGET_SESSION=""
SKIP_PASSWORD_CHANGES=0

log() {
    printf '[steamos-test] %s\n' "$*"
}

fail() {
    printf '[steamos-test] ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"
}

require_root() {
    [[ ${EUID} -eq 0 ]] || fail "请用 sudo 运行这个脚本"
}

usage() {
    cat <<'EOF'
用法:
  sudo bash steamos-mode-test.sh            # 应用 SteamOS 风格设置
  sudo bash steamos-mode-test.sh --revert   # 回滚到应用前状态

可选参数:
  --user USER                 指定自动登录用户，默认优先取 SUDO_USER，再回退到 UID 1000
  --session SESSION           指定 SDDM session，默认自动探测 KDE/GNOME
  --skip-password-changes     不修改用户密码与 root 锁定状态
  -h, --help                  显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --revert)
            MODE="revert"
            ;;
        --user)
            shift
            [[ $# -gt 0 ]] || fail "--user 需要一个参数"
            TARGET_USER="$1"
            ;;
        --session)
            shift
            [[ $# -gt 0 ]] || fail "--session 需要一个参数"
            TARGET_SESSION="$1"
            ;;
        --skip-password-changes)
            SKIP_PASSWORD_CHANGES=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知参数: $1"
            ;;
    esac
    shift
done

ensure_dirs() {
    install -d -m 700 "${STATE_DIR}" "${BACKUP_DIR}"
}

backup_path() {
    local source_path="$1"
    local backup_name="$2"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    local meta_path="${BACKUP_DIR}/${backup_name}.meta"

    if [[ -e "${source_path}" || -L "${source_path}" ]]; then
        cp -a --remove-destination "${source_path}" "${backup_path}"
        printf 'present=1\n' > "${meta_path}"
    else
        printf 'present=0\n' > "${meta_path}"
    fi
}

restore_path() {
    local target_path="$1"
    local backup_name="$2"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    local meta_path="${BACKUP_DIR}/${backup_name}.meta"

    [[ -f "${meta_path}" ]] || return 0

    # shellcheck disable=SC1090
    source "${meta_path}"

    if [[ "${present}" == "1" ]]; then
        install -d "$(dirname "${target_path}")"
        cp -a --remove-destination "${backup_path}" "${target_path}"
    else
        rm -f "${target_path}"
    fi
}

create_sudo_password_helper() {
    install -d -m 755 "${SUDO_PASSWORD_HELPER_DIR}"
    cat > "${SUDO_PASSWORD_HELPER}" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

CALLING_USER="${PAM_RUSER:-}"

if [[ -z "${CALLING_USER}" || "${CALLING_USER}" == "root" ]]; then
    exit 0
fi

PASSWORD_FIELD="$(awk -F: -v user="${CALLING_USER}" '$1 == user { print $2; exit }' /etc/shadow || true)"

if [[ -z "${PASSWORD_FIELD}" ]]; then
    echo "sudo 已禁用：请先执行 passwd 为 ${CALLING_USER} 设置密码。"
    exit 1
fi

exit 0
EOF
    chmod 755 "${SUDO_PASSWORD_HELPER}"
}

apply_sudo_password_policy() {
    local temp_file

    [[ -f "${SUDO_PAM_FILE}" ]] || fail "未找到 ${SUDO_PAM_FILE}"
    create_sudo_password_helper

    if grep -Fqx "${SUDO_PASSWORD_PAM_LINE}" "${SUDO_PAM_FILE}"; then
        return 0
    fi

    temp_file="$(mktemp "${STATE_DIR}/sudo.pam.XXXXXX")"
    {
        printf '%s\n' "${SUDO_PASSWORD_PAM_LINE}"
        cat "${SUDO_PAM_FILE}"
    } > "${temp_file}"
    cp -a --remove-destination "${temp_file}" "${SUDO_PAM_FILE}"
    rm -f "${temp_file}"
}

detect_target_user() {
    if [[ -n "${TARGET_USER}" ]]; then
        :
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="${SUDO_USER}"
    else
        TARGET_USER="$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd || true)"
    fi

    [[ -n "${TARGET_USER}" ]] || fail "无法确定目标用户，请通过 --user 显式指定"

    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"
    [[ -n "${TARGET_HOME}" ]] || fail "无法获取用户 ${TARGET_USER} 的 home 目录"

    USER_LOCK_CONF="${TARGET_HOME}/.config/kscreenlockerrc"
}

detect_target_session() {
    if [[ -n "${TARGET_SESSION}" ]]; then
        return 0
    fi

    if [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
        TARGET_SESSION="plasma.desktop"
    elif [[ -f /usr/share/wayland-sessions/gnome-wayland.desktop ]]; then
        TARGET_SESSION="gnome-wayland.desktop"
    elif [[ -f /usr/share/xsessions/plasmax11.desktop ]]; then
        TARGET_SESSION="plasmax11.desktop"
    else
        fail "无法自动判断桌面 session，请通过 --session 手动指定"
    fi
}

save_state() {
    {
        printf 'TARGET_USER=%q\n' "${TARGET_USER}"
        printf 'TARGET_HOME=%q\n' "${TARGET_HOME}"
        printf 'TARGET_SESSION=%q\n' "${TARGET_SESSION}"
        printf 'SKIP_PASSWORD_CHANGES=%q\n' "${SKIP_PASSWORD_CHANGES}"
        printf 'USER_LOCK_CONF=%q\n' "${USER_LOCK_CONF}"
    } > "${STATE_FILE}"
}

load_state() {
    [[ -f "${STATE_FILE}" ]] || fail "未找到回滚状态文件: ${STATE_FILE}"
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
}

apply_autologin() {
    install -d /etc/sddm.conf.d
    cat > "${AUTOLOGIN_CONF}" <<EOF
[Autologin]
User=${TARGET_USER}
Session=${TARGET_SESSION}
Relogin=true
EOF
}

apply_lockscreen_config() {
    install -d /etc/xdg
    cat > "${GLOBAL_LOCK_CONF}" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
Timeout=0
EOF

    install -d -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_HOME}/.config"
    cat > "${USER_LOCK_CONF}" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
Timeout=0
EOF
    chown "${TARGET_USER}:${TARGET_USER}" "${USER_LOCK_CONF}"
}

apply_password_changes() {
    if [[ "${SKIP_PASSWORD_CHANGES}" == "1" ]]; then
        log "已跳过密码修改"
        return 0
    fi

    cp -a --remove-destination /etc/shadow "${BACKUP_DIR}/shadow"
    passwd -d "${TARGET_USER}" || true
    passwd -l root || true
}

restore_password_changes() {
    if [[ "${SKIP_PASSWORD_CHANGES}" == "1" ]]; then
        return 0
    fi

    if [[ -f "${BACKUP_DIR}/shadow" ]]; then
        cp -a --remove-destination "${BACKUP_DIR}/shadow" /etc/shadow
    else
        log "未找到 /etc/shadow 备份，跳过密码状态恢复"
    fi
}

apply_mode() {
    need_cmd passwd
    need_cmd awk
    need_cmd getent
    need_cmd mktemp

    ensure_dirs
    if [[ -f "${STATE_FILE}" ]]; then
        fail "检测到已有测试状态，请先执行 --revert，避免覆盖最初备份"
    fi

    detect_target_user
    detect_target_session

    backup_path "${AUTOLOGIN_CONF}" "autologin.conf"
    backup_path "${GLOBAL_LOCK_CONF}" "global-kscreenlockerrc"
    backup_path "${USER_LOCK_CONF}" "user-kscreenlockerrc"
    backup_path "${SUDO_PAM_FILE}" "sudo-pam"

    save_state
    apply_autologin
    apply_lockscreen_config
    apply_sudo_password_policy
    apply_password_changes

    log "已应用 SteamOS 风格测试配置"
    log "自动登录用户: ${TARGET_USER}"
    log "SDDM session: ${TARGET_SESSION}"
    log "建议现在重启一次，验证开机直达桌面和不锁屏行为"
    if [[ "${SKIP_PASSWORD_CHANGES}" != "1" ]]; then
        log "当前已删除 ${TARGET_USER} 的密码并锁定 root；在你先执行 passwd 前，sudo 也会被拒绝"
        log "如需恢复，请执行 --revert"
    fi
}

revert_mode() {
    load_state
    ensure_dirs

    restore_path "${AUTOLOGIN_CONF}" "autologin.conf"
    restore_path "${GLOBAL_LOCK_CONF}" "global-kscreenlockerrc"
    restore_path "${USER_LOCK_CONF}" "user-kscreenlockerrc"
    restore_path "${SUDO_PAM_FILE}" "sudo-pam"
    restore_password_changes
    rm -f "${SUDO_PASSWORD_HELPER}"
    rm -f "${STATE_FILE}"

    log "已恢复到应用前状态"
    log "建议重启或至少注销后重新登录一次"
}

main() {
    require_root

    if [[ "${MODE}" == "apply" ]]; then
        apply_mode
    else
        revert_mode
    fi
}

main
