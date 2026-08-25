#!/usr/bin/env bash

set -euo pipefail

PROGRAM_NAME="1pup"
PROGRAM_VERSION="0.1.0"
REPOSITORY="Aethersailor/1Panel-Auto-Upgrade"
RAW_URL="https://raw.githubusercontent.com/${REPOSITORY}/main/1pup.sh"

MANAGER_PATH="/usr/local/bin/1pup"
LONG_ALIAS="/usr/local/bin/1panel-auto-upgrade"
CONFIG_DIR="/etc/1panel-auto-upgrade"
CONFIG_FILE="${CONFIG_DIR}/config.conf"
BACKUP_DIR="${CONFIG_DIR}/backups"
APP_SERVICE="1panel-app-auto-upgrade.service"
APP_TIMER="1panel-app-auto-upgrade.timer"
PANEL_SERVICE="1panel-system-auto-upgrade.service"
PANEL_TIMER="1panel-system-auto-upgrade.timer"
SYSTEMD_DIR="/etc/systemd/system"

DEFAULT_MODE="all"
DEFAULT_APPS_TIME="03:17"
DEFAULT_PANEL_TIME="04:47"

MODE="${DEFAULT_MODE}"
APPS_TIME="${DEFAULT_APPS_TIME}"
PANEL_TIME="${DEFAULT_PANEL_TIME}"
TIMEZONE=""

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

info() {
    printf '%b[信息]%b %s\n' "${COLOR_BLUE}" "${COLOR_RESET}" "$*"
}

success() {
    printf '%b[成功]%b %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "$*"
}

warn() {
    printf '%b[警告]%b %s\n' "${COLOR_YELLOW}" "${COLOR_RESET}" "$*" >&2
}

error() {
    printf '%b[错误]%b %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        return 0
    fi
    if command_exists sudo; then
        exec sudo -- "$0" "$@"
    fi
    die "此操作需要 root 权限，请使用 sudo 重新运行。"
}

detect_timezone() {
    local detected=""
    if command_exists timedatectl; then
        detected="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    if [[ -z "${detected}" && -r /etc/timezone ]]; then
        detected="$(tr -d '[:space:]' </etc/timezone)"
    fi
    if [[ -z "${detected}" ]]; then
        detected="UTC"
    fi
    printf '%s\n' "${detected}"
}

validate_mode() {
    [[ "$1" == "apps" || "$1" == "panel" || "$1" == "all" ]]
}

validate_time() {
    local value="$1"
    [[ "${value}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

validate_timezone() {
    local timezone="$1"
    local at_time="${2:-03:17}"
    if ! command_exists systemd-analyze; then
        return 1
    fi
    systemd-analyze calendar "*-*-* ${at_time}:00 ${timezone}" >/dev/null 2>&1
}

time_to_minutes() {
    local value="$1"
    local hour="${value%%:*}"
    local minute="${value##*:}"
    printf '%d\n' "$((10#${hour} * 60 + 10#${minute}))"
}

time_distance_minutes() {
    local first second diff
    first="$(time_to_minutes "$1")"
    second="$(time_to_minutes "$2")"
    diff=$((first - second))
    ((diff < 0)) && diff=$((-diff))
    ((diff > 720)) && diff=$((1440 - diff))
    printf '%d\n' "${diff}"
}

load_config() {
    MODE="${DEFAULT_MODE}"
    APPS_TIME="${DEFAULT_APPS_TIME}"
    PANEL_TIME="${DEFAULT_PANEL_TIME}"
    TIMEZONE="$(detect_timezone)"

    [[ -r "${CONFIG_FILE}" ]] || return 0

    local key value
    while IFS='=' read -r key value; do
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        case "${key}" in
            MODE) MODE="${value}" ;;
            APPS_TIME) APPS_TIME="${value}" ;;
            PANEL_TIME) PANEL_TIME="${value}" ;;
            TIMEZONE) TIMEZONE="${value}" ;;
        esac
    done <"${CONFIG_FILE}"

    validate_mode "${MODE}" || die "配置中的 MODE 无效：${MODE}"
    validate_time "${APPS_TIME}" || die "配置中的 APPS_TIME 无效：${APPS_TIME}"
    validate_time "${PANEL_TIME}" || die "配置中的 PANEL_TIME 无效：${PANEL_TIME}"
    validate_timezone "${TIMEZONE}" "${APPS_TIME}" || die "配置中的 TIMEZONE 无效：${TIMEZONE}"
}

write_config() {
    local temp_file stamp
    install -d -o root -g root -m 0755 "${CONFIG_DIR}"
    temp_file="$(mktemp "${CONFIG_DIR}/config.conf.XXXXXX")"
    chmod 0600 "${temp_file}"
    {
        printf 'MODE=%s\n' "${MODE}"
        printf 'APPS_TIME=%s\n' "${APPS_TIME}"
        printf 'PANEL_TIME=%s\n' "${PANEL_TIME}"
        printf 'TIMEZONE=%s\n' "${TIMEZONE}"
    } >"${temp_file}"
    chown root:root "${temp_file}"
    stamp="$(date +%Y%m%d%H%M%S)"
    backup_file_if_changed "${temp_file}" "${CONFIG_FILE}" "${stamp}"
    mv -f "${temp_file}" "${CONFIG_FILE}"
}

backup_file_if_changed() {
    local source="$1"
    local target="$2"
    local stamp="$3"
    if [[ -e "${target}" ]] && ! cmp -s "${source}" "${target}"; then
        install -d -o root -g root -m 0700 "${BACKUP_DIR}"
        cp -a -- "${target}" "${BACKUP_DIR}/$(basename "${target}").bak-${stamp}"
    fi
}

install_atomic() {
    local source="$1"
    local target="$2"
    local mode="$3"
    local target_dir temp_target
    target_dir="$(dirname "${target}")"
    install -d -o root -g root -m 0755 "${target_dir}"
    temp_target="$(mktemp "${target_dir}/.$(basename "${target}").XXXXXX")"
    install -o root -g root -m "${mode}" "${source}" "${temp_target}"
    mv -f "${temp_target}" "${target}"
}

render_app_service() {
    cat <<EOF
[Unit]
Description=Automatically upgrade 1Panel App Store applications
Wants=network-online.target
After=network-online.target 1panel-agent.service
ConditionPathIsSocket=/etc/1panel/agent.sock

[Service]
Type=oneshot
ExecStart=${MANAGER_PATH} _run apps
TimeoutStartSec=infinity
EOF
}

render_panel_service() {
    cat <<EOF
[Unit]
Description=Automatically upgrade the 1Panel system through its native API
Wants=network-online.target
After=network-online.target 1panel-core.service 1panel-agent.service

[Service]
Type=oneshot
ExecStart=${MANAGER_PATH} _run panel
TimeoutStartSec=75min
EOF
}

render_timer() {
    local description="$1"
    local on_calendar="$2"
    local unit="$3"
    cat <<EOF
[Unit]
Description=${description}

[Timer]
OnCalendar=${on_calendar}
AccuracySec=1min
Unit=${unit}

[Install]
WantedBy=timers.target
EOF
}

generate_systemd_units() {
    local staging stamp
    staging="$(mktemp -d /tmp/1pup-units.XXXXXX)"
    stamp="$(date +%Y%m%d%H%M%S)"

    render_app_service >"${staging}/${APP_SERVICE}"
    render_panel_service >"${staging}/${PANEL_SERVICE}"
    render_timer \
        "Daily automatic upgrade of 1Panel App Store applications" \
        "*-*-* ${APPS_TIME}:00 ${TIMEZONE}" \
        "${APP_SERVICE}" >"${staging}/${APP_TIMER}"
    render_timer \
        "Daily automatic upgrade check for the 1Panel system" \
        "*-*-* ${PANEL_TIME}:00 ${TIMEZONE}" \
        "${PANEL_SERVICE}" >"${staging}/${PANEL_TIMER}"

    systemd-analyze calendar "*-*-* ${APPS_TIME}:00 ${TIMEZONE}" >/dev/null
    systemd-analyze calendar "*-*-* ${PANEL_TIME}:00 ${TIMEZONE}" >/dev/null
    systemd-analyze verify \
        "${staging}/${APP_SERVICE}" \
        "${staging}/${APP_TIMER}" \
        "${staging}/${PANEL_SERVICE}" \
        "${staging}/${PANEL_TIMER}"

    local unit
    for unit in "${APP_SERVICE}" "${APP_TIMER}" "${PANEL_SERVICE}" "${PANEL_TIMER}"; do
        backup_file_if_changed "${staging}/${unit}" "${SYSTEMD_DIR}/${unit}" "${stamp}"
        install_atomic "${staging}/${unit}" "${SYSTEMD_DIR}/${unit}" 0644
    done
    rm -f -- \
        "${staging}/${APP_SERVICE}" \
        "${staging}/${APP_TIMER}" \
        "${staging}/${PANEL_SERVICE}" \
        "${staging}/${PANEL_TIMER}"
    rmdir "${staging}"

    systemctl daemon-reload
    systemd-analyze verify \
        "${SYSTEMD_DIR}/${APP_SERVICE}" \
        "${SYSTEMD_DIR}/${APP_TIMER}" \
        "${SYSTEMD_DIR}/${PANEL_SERVICE}" \
        "${SYSTEMD_DIR}/${PANEL_TIMER}"
}

apply_timer_selection() {
    case "${MODE}" in
        apps)
            systemctl disable --now "${PANEL_TIMER}" >/dev/null 2>&1 || true
            systemctl enable --now "${APP_TIMER}" >/dev/null
            ;;
        panel)
            systemctl disable --now "${APP_TIMER}" >/dev/null 2>&1 || true
            systemctl enable --now "${PANEL_TIMER}" >/dev/null
            ;;
        all)
            systemctl enable --now "${APP_TIMER}" >/dev/null
            systemctl enable --now "${PANEL_TIMER}" >/dev/null
            ;;
    esac
}

timer_next() {
    local timer="$1"
    systemctl show "${timer}" -p NextElapseUSecRealtime --value 2>/dev/null || true
}

manager_source() {
    local source="${BASH_SOURCE[0]:-}"
    if [[ -n "${source}" && -f "${source}" ]]; then
        readlink -f "${source}"
        return 0
    fi
    return 1
}

download_script() {
    local target="$1"
    if command_exists curl; then
        curl -fsSL "${RAW_URL}" -o "${target}"
    elif command_exists wget; then
        wget -qO "${target}" "${RAW_URL}"
    else
        die "需要 curl 或 wget 才能下载脚本。"
    fi
}

install_manager_script() {
    local source temp_download stamp
    stamp="$(date +%Y%m%d%H%M%S)"
    temp_download=""
    if source="$(manager_source)"; then
        :
    else
        temp_download="$(mktemp /tmp/1pup.XXXXXX.sh)"
        download_script "${temp_download}"
        source="${temp_download}"
    fi

    bash -n "${source}"
    bash "${source}" --self-check >/dev/null
    backup_file_if_changed "${source}" "${MANAGER_PATH}" "${stamp}"
    install_atomic "${source}" "${MANAGER_PATH}" 0755
    ln -sfn "${MANAGER_PATH}" "${LONG_ALIAS}"
    [[ -z "${temp_download}" ]] || rm -f -- "${temp_download}"
}

python_action() {
    local action="$1"
    shift || true
    ONEPUP_CONFIG_FILE="${CONFIG_FILE}" python3 - "${action}" "$@" <<'PYTHON'
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import hmac
import http.client
import json
import os
import re
import socket
import sqlite3
import ssl
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any


EARLY_ACTION = sys.argv[1] if len(sys.argv) > 1 else "self-check"
if EARLY_ACTION == "self-check":
    print("embedded Python syntax: ok")
    raise SystemExit(0)


AGENT_SOCKET = "/etc/1panel/agent.sock"
GLOBAL_LOCK = "/run/lock/1panel-auto-upgrade-global.lock"
APP_LOCK = "/run/lock/1panel-app-auto-upgrade.lock"
PANEL_LOCK = "/run/lock/1panel-system-auto-upgrade.lock"
APP_SERVICE = "1panel-app-auto-upgrade.service"
MIN_FREE_BYTES = 500 << 20
VERIFY_TIMEOUT = int(os.environ.get("ONEPUP_VERIFY_TIMEOUT", "3600"))
ROLLBACK_VERIFY_TIMEOUT = int(os.environ.get("ONEPUP_ROLLBACK_TIMEOUT", "600"))
TERMINAL_TASK_STATES = {"Success", "Failed"}


def log(message: str) -> None:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    print(f"{stamp} {message}", flush=True)


def detect_base_dir() -> Path:
    env_value = os.environ.get("ONEPANEL_BASE_DIR", "").strip()
    if env_value and (Path(env_value) / "1panel/db/core.db").is_file():
        return Path(env_value)

    ctl = Path("/usr/local/bin/1pctl")
    if ctl.is_file():
        with contextlib.suppress(Exception):
            content = ctl.read_text(encoding="utf-8", errors="ignore")
            match = re.search(r'^BASE_DIR=["\']?([^"\'\n]+)', content, re.MULTILINE)
            if match:
                candidate = Path(match.group(1).strip())
                if (candidate / "1panel/db/core.db").is_file():
                    return candidate

    for candidate in (Path("/opt"), Path("/usr/local"), Path("/data"), Path("/www")):
        if (candidate / "1panel/db/core.db").is_file():
            return candidate
    raise RuntimeError("无法定位 1Panel 安装目录")


BASE_DIR = detect_base_dir()
CORE_DB = BASE_DIR / "1panel/db/core.db"
AGENT_DB = BASE_DIR / "1panel/db/agent.db"


def read_settings(db_path: Path, keys: list[str]) -> dict[str, str]:
    connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
    try:
        placeholders = ",".join("?" for _ in keys)
        rows = connection.execute(
            f"SELECT key, value FROM settings WHERE key IN ({placeholders})", keys
        ).fetchall()
    finally:
        connection.close()
    return {str(key): str(value) for key, value in rows}


def read_setting(db_path: Path, key: str) -> str:
    return read_settings(db_path, [key]).get(key, "")


def read_core_state() -> tuple[str, str]:
    values = read_settings(CORE_DB, ["SystemVersion", "SystemStatus"])
    return values.get("SystemVersion", ""), values.get("SystemStatus", "")


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float = 45.0) -> None:
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.unix_path)
        self.sock = sock


def decode_response(response: http.client.HTTPResponse, method: str, path: str) -> dict[str, Any]:
    raw = response.read()
    text = raw.decode("utf-8", errors="replace")
    if response.status < 200 or response.status >= 300:
        raise RuntimeError(f"{method} {path} 返回 HTTP {response.status}: {text}")
    try:
        result = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{method} {path} 返回了无效 JSON") from exc
    if result.get("code") != 200:
        raise RuntimeError(f"{method} {path} 失败: {result.get('message', text)}")
    return result


def agent_request(method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    body = None if payload is None else json.dumps(payload, separators=(",", ":"))
    headers = {"Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    connection = UnixHTTPConnection(AGENT_SOCKET)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return decode_response(response, method, path)
    finally:
        connection.close()


class PanelAPI:
    def __init__(self) -> None:
        values = read_settings(
            CORE_DB, ["ApiInterfaceStatus", "ApiKey", "ServerPort", "SSL"]
        )
        if values.get("ApiInterfaceStatus") != "Enable":
            raise RuntimeError("1Panel API 未启用，请先在面板中启用 API")
        self.api_key = values.get("ApiKey", "")
        if not self.api_key:
            raise RuntimeError("1Panel API Key 为空")
        try:
            self.port = int(values.get("ServerPort", "0"))
        except ValueError as exc:
            raise RuntimeError("1Panel 端口无效") from exc
        if self.port <= 0 or self.port > 65535:
            raise RuntimeError("1Panel 端口无效")
        self.use_tls = values.get("SSL") == "Enable"

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        timestamp = str(int(time.time()))
        token = hmac.new(
            self.api_key.encode(), f"1panel:{timestamp}".encode(), hashlib.sha256
        ).hexdigest()
        headers = {
            "Accept": "application/json",
            "1Panel-Token": token,
            "1Panel-Timestamp": timestamp,
        }
        body = None
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":"))
            headers["Content-Type"] = "application/json"
        if self.use_tls:
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            connection: http.client.HTTPConnection = http.client.HTTPSConnection(
                "127.0.0.1", self.port, timeout=45, context=context
            )
        else:
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=45)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return decode_response(response, method, path)
        finally:
            connection.close()


def lock_file(path: str) -> Any:
    item = open(path, "w", encoding="utf-8")
    try:
        fcntl.flock(item.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        item.close()
        return None
    return item


def service_active(name: str) -> bool:
    result = subprocess.run(
        ["systemctl", "is-active", "--quiet", name],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def panel_services_active() -> bool:
    return service_active("1panel-core.service") and service_active("1panel-agent.service")


def task_by_id(task_id: str) -> dict[str, Any] | None:
    result = agent_request(
        "POST",
        "/api/v2/logs/tasks/search",
        {"page": 1, "pageSize": 1, "status": "", "type": "", "taskID": task_id},
    )
    items = (result.get("data") or {}).get("items") or []
    return items[0] if items else None


def wait_task(task_id: str) -> dict[str, Any]:
    missing = 0
    last_status = ""
    while True:
        task = task_by_id(task_id)
        if task is None:
            missing += 1
            if missing >= 30:
                raise RuntimeError(f"1Panel 任务未创建: {task_id}")
            time.sleep(1)
            continue
        status = str(task.get("status", ""))
        if status != last_status:
            log(f"任务 {task_id} 状态={status} 名称={task.get('name', '')}")
            last_status = status
        if status in TERMINAL_TASK_STATES:
            return task
        time.sleep(10)


def sync_app_store() -> None:
    task_id = str(uuid.uuid4())
    result = agent_request("POST", "/api/v2/apps/sync/remote", {"taskID": task_id})
    time.sleep(1)
    task = task_by_id(task_id)
    if task is not None:
        finished = wait_task(task_id)
        if finished.get("status") != "Success":
            raise RuntimeError(f"应用商店同步失败: {finished.get('errorMsg', '')}")
        return
    while read_setting(AGENT_DB, "AppStoreSyncStatus") == "Syncing":
        time.sleep(2)
    log(f"应用商店同步未创建任务: {result.get('message', '')}")


def app_candidates() -> list[dict[str, Any]]:
    result = agent_request(
        "POST",
        "/api/v2/apps/installed/search",
        {
            "page": 1,
            "pageSize": 10000,
            "name": "",
            "tags": [],
            "update": True,
            "sync": True,
        },
    )
    return list((result.get("data") or {}).get("items") or [])


def app_versions(install_id: int) -> list[dict[str, Any]]:
    result = agent_request(
        "POST",
        "/api/v2/apps/installed/update/versions",
        {"appInstallID": install_id},
    )
    return list(result.get("data") or [])


def app_defaults() -> tuple[bool, bool]:
    values = read_settings(CORE_DB, ["UpgradeBackup", "UpgradeDeleteImage"])
    return values.get("UpgradeBackup") == "Enable", values.get("UpgradeDeleteImage") == "Enable"


def upgrade_app(candidate: dict[str, Any]) -> bool:
    install_id = int(candidate["id"])
    versions = app_versions(install_id)
    label = f"{candidate.get('appKey', '')}/{candidate.get('name', '')}"
    if not versions:
        log(f"跳过 {label}: 1Panel 未返回目标版本")
        return True
    selected = versions[0]
    backup, delete_image = app_defaults()
    task_id = str(uuid.uuid4())
    log(
        f"升级 {label}: {candidate.get('version', '')} -> {selected.get('version', '')}; "
        f"backup={str(backup).lower()} pullImage=true deleteImage={str(delete_image).lower()}"
    )
    agent_request(
        "POST",
        "/api/v2/apps/installed/op",
        {
            "detailId": int(selected["detailId"]),
            "operate": "upgrade",
            "installId": install_id,
            "backup": backup,
            "pullImage": True,
            "deleteImage": delete_image,
            "dockerCompose": "",
            "taskID": task_id,
        },
    )
    finished = wait_task(task_id)
    if finished.get("status") == "Success":
        log(f"应用升级成功: {label} {selected.get('version', '')}")
        return True
    log(f"应用升级失败: {label}: {finished.get('errorMsg', '')}")
    return False


def check_apps() -> int:
    if not Path(AGENT_SOCKET).exists():
        raise RuntimeError("1Panel Agent Socket 不存在")
    candidates = app_candidates()
    print(f"可升级应用：{len(candidates)}")
    for item in candidates:
        print(f"  - {item.get('appKey', '')}/{item.get('name', '')}: {item.get('version', '')}")
    return len(candidates)


def run_apps() -> int:
    try:
        sync_app_store()
    except Exception as exc:
        log(f"应用商店同步失败，继续使用当前目录: {exc}")
    candidates = app_candidates()
    log(f"可升级应用数量={len(candidates)}")
    failures = 0
    for candidate in candidates:
        try:
            if not upgrade_app(candidate):
                failures += 1
        except Exception as exc:
            failures += 1
            log(f"应用升级请求失败 {candidate.get('name', '')}: {exc}")
    log(f"应用自动升级完成: total={len(candidates)} failed={failures}")
    return 1 if failures else 0


def select_panel_target(data: dict[str, Any]) -> str:
    return str(data.get("latestVersion") or data.get("testVersion") or data.get("newVersion") or "")


def check_panel() -> tuple[str, str, str]:
    api = PanelAPI()
    current, status = read_core_state()
    result = api.request("GET", "/api/v2/core/settings/upgrade")
    target = select_panel_target(result.get("data") or {})
    print(f"当前面板版本：{current}")
    print(f"面板状态：{status}")
    print(f"可升级版本：{target or '无'}")
    return current, status, target


def cli_version() -> str:
    result = subprocess.run(
        ["/usr/local/bin/1pctl", "version"],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    match = re.search(r"(?:version|版本):\s*(v\S+)", result.stdout)
    return "" if match is None else match.group(1)


def wait_panel_upgrade(api: PanelAPI, old_version: str, target: str) -> bool:
    deadline = time.monotonic() + VERIFY_TIMEOUT
    while time.monotonic() < deadline:
        with contextlib.suppress(Exception):
            core_version, status = read_core_state()
            agent_version = read_setting(AGENT_DB, "SystemVersion")
            if (
                core_version == target
                and agent_version == target
                and status == "Free"
                and panel_services_active()
                and cli_version() == target
            ):
                api.request("GET", "/api/v2/core/settings/upgrade")
                return True
            if status == "Free" and core_version == old_version and time.monotonic() > deadline - VERIFY_TIMEOUT + 90:
                return False
        time.sleep(5)
    return False


def restore_panel(old_version: str) -> bool:
    log(f"开始调用 1pctl restore 恢复 {old_version}")
    result = subprocess.run(
        ["/usr/local/bin/1pctl", "restore"],
        check=False,
        capture_output=True,
        text=True,
        timeout=600,
    )
    if result.returncode != 0:
        log(f"1pctl restore 失败: {result.stderr.strip()}")
        return False
    deadline = time.monotonic() + ROLLBACK_VERIFY_TIMEOUT
    while time.monotonic() < deadline:
        with contextlib.suppress(Exception):
            core_version, status = read_core_state()
            agent_version = read_setting(AGENT_DB, "SystemVersion")
            if (
                core_version == old_version
                and agent_version == old_version
                and status == "Free"
                and panel_services_active()
                and cli_version() == old_version
            ):
                log(f"面板恢复成功: {old_version}")
                return True
        time.sleep(5)
    return False


def run_panel() -> int:
    api = PanelAPI()
    current, status = read_core_state()
    result = api.request("GET", "/api/v2/core/settings/upgrade")
    target = select_panel_target(result.get("data") or {})
    log(f"面板版本检查: current={current} target={target or 'none'} status={status}")
    if not target:
        return 0
    if status != "Free":
        raise RuntimeError(f"SystemStatus={status}，不是 Free")
    if service_active(APP_SERVICE):
        raise RuntimeError("应用自动升级正在运行")
    if not panel_services_active():
        raise RuntimeError("1Panel Core 或 Agent 服务异常")
    stat = os.statvfs(BASE_DIR / "1panel")
    available = stat.f_bavail * stat.f_frsize
    if available < MIN_FREE_BYTES:
        raise RuntimeError(f"可用空间仅 {available >> 20} MB，少于 500 MB")
    log(f"开始官方面板升级: {current} -> {target}")
    api.request("POST", "/api/v2/core/settings/upgrade", {"version": target})
    if wait_panel_upgrade(api, current, target):
        log(f"面板升级成功: {target}")
        return 0
    final_version, final_status = read_core_state()
    if final_version == target and final_status == "Free":
        restored = restore_panel(current)
        raise RuntimeError(f"目标版本不健康，自动恢复结果={str(restored).lower()}")
    raise RuntimeError(
        f"面板升级未到达目标状态: version={final_version} status={final_status} target={target}"
    )


def run_with_locks(module: str) -> int:
    global_lock = lock_file(GLOBAL_LOCK)
    if global_lock is None:
        log("已有其他 1Panel 自动升级任务运行，本次跳过")
        return 0
    module_lock = lock_file(APP_LOCK if module == "apps" else PANEL_LOCK)
    if module_lock is None:
        global_lock.close()
        log("同类自动升级任务已经运行，本次跳过")
        return 0
    try:
        return run_apps() if module == "apps" else run_panel()
    finally:
        module_lock.close()
        global_lock.close()


def run_all_with_lock() -> int:
    global_lock = lock_file(GLOBAL_LOCK)
    if global_lock is None:
        log("已有其他 1Panel 自动升级任务运行，本次跳过")
        return 0
    failures = 0
    try:
        app_lock = lock_file(APP_LOCK)
        if app_lock is None:
            log("应用自动升级任务已经运行，本次应用升级跳过")
        else:
            try:
                failures += 1 if run_apps() else 0
            finally:
                app_lock.close()

        panel_lock = lock_file(PANEL_LOCK)
        if panel_lock is None:
            log("面板自动升级任务已经运行，本次面板升级跳过")
        else:
            try:
                failures += 1 if run_panel() else 0
            finally:
                panel_lock.close()
        return 1 if failures else 0
    finally:
        global_lock.close()


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "self-check"
    target = sys.argv[2] if len(sys.argv) > 2 else "all"
    if action == "check-env":
        print(f"1Panel 安装目录：{BASE_DIR}")
        print(f"Agent Socket：{'正常' if Path(AGENT_SOCKET).exists() else '缺失'}")
        return 0
    if action == "check":
        if target in ("apps", "all"):
            check_apps()
        if target in ("panel", "all"):
            check_panel()
        return 0
    if action == "run":
        if target == "apps":
            return run_with_locks("apps")
        if target == "panel":
            return run_with_locks("panel")
        if target == "all":
            return run_all_with_lock()
    raise RuntimeError(f"不支持的内部操作: {action} {target}")


try:
    raise SystemExit(main())
except Exception as exc:
    log(f"失败: {exc}")
    raise SystemExit(1)
PYTHON
}

check_dependencies() {
    command_exists python3 || die "缺少 Python 3。请先安装 python3 后重试。"
    python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
        || die "需要 Python 3.8 或更高版本。"
    command_exists systemctl || die "当前系统不支持 systemd。"
    command_exists systemd-analyze || die "缺少 systemd-analyze。"
    [[ -e /usr/local/bin/1pctl ]] || die "未检测到 1Panel V2 的 1pctl。"
    python_action check-env
}

check_target() {
    local target="$1"
    case "${target}" in
        apps|panel|all) python_action check "${target}" ;;
        *) die "检查目标必须是 apps、panel 或 all。" ;;
    esac
}

print_plan() {
    printf '\n将应用以下配置：\n'
    printf '  功能模式：%s\n' "${MODE}"
    printf '  应用升级：%s %s\n' "${APPS_TIME}" "${TIMEZONE}"
    printf '  面板升级：%s %s\n' "${PANEL_TIME}" "${TIMEZONE}"
    printf '  管理命令：%s\n\n' "${MANAGER_PATH}"
}

prompt_value() {
    local prompt="$1"
    local default="$2"
    local value=""
    read -r -p "${prompt} [${default}]: " value || true
    printf '%s\n' "${value:-${default}}"
}

configure_wizard() {
    load_config
    printf '\n请选择需要启用的功能：\n'
    printf '  1) 仅应用自动升级\n'
    printf '  2) 仅 1Panel 本体自动升级\n'
    printf '  3) 两者都启用 [默认]\n'
    local choice=""
    read -r -p '请选择 [3]: ' choice || true
    case "${choice:-3}" in
        1) MODE="apps" ;;
        2) MODE="panel" ;;
        3) MODE="all" ;;
        *) die "无效选择。" ;;
    esac

    if [[ "${MODE}" == "apps" || "${MODE}" == "all" ]]; then
        APPS_TIME="$(prompt_value '应用升级时间' "${APPS_TIME}")"
        validate_time "${APPS_TIME}" || die "应用升级时间格式无效，应为 HH:MM。"
    fi
    if [[ "${MODE}" == "panel" || "${MODE}" == "all" ]]; then
        PANEL_TIME="$(prompt_value '面板升级时间' "${PANEL_TIME}")"
        validate_time "${PANEL_TIME}" || die "面板升级时间格式无效，应为 HH:MM。"
    fi
    TIMEZONE="$(prompt_value '时区' "${TIMEZONE}")"
    validate_timezone "${TIMEZONE}" "${APPS_TIME}" || die "时区无法被 systemd 解析：${TIMEZONE}"

    if [[ "${MODE}" == "all" ]]; then
        local distance
        distance="$(time_distance_minutes "${APPS_TIME}" "${PANEL_TIME}")"
        if ((distance < 60)); then
            warn "两个升级时间仅相隔 ${distance} 分钟。"
            local confirm=""
            read -r -p '仍然保存？[y/N]: ' confirm || true
            [[ "${confirm}" =~ ^[Yy]$ ]] || die "已取消。"
        fi
    fi

    print_plan
    local confirm=""
    read -r -p '确认保存？[Y/n]: ' confirm || true
    [[ -z "${confirm}" || "${confirm}" =~ ^[Yy]$ ]] || die "已取消。"
}

configure_noninteractive() {
    load_config
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode) MODE="${2:-}"; shift 2 ;;
            --apps-time) APPS_TIME="${2:-}"; shift 2 ;;
            --panel-time) PANEL_TIME="${2:-}"; shift 2 ;;
            --timezone) TIMEZONE="${2:-}"; shift 2 ;;
            *) die "未知参数：$1" ;;
        esac
    done
    validate_mode "${MODE}" || die "模式必须是 apps、panel 或 all。"
    validate_time "${APPS_TIME}" || die "应用升级时间格式无效。"
    validate_time "${PANEL_TIME}" || die "面板升级时间格式无效。"
    validate_timezone "${TIMEZONE}" "${APPS_TIME}" || die "时区无效：${TIMEZONE}"
}

apply_configuration() {
    write_config
    generate_systemd_units
    apply_timer_selection
    success "配置已保存。"
    [[ "${MODE}" == "panel" ]] || info "应用升级下次执行：$(timer_next "${APP_TIMER}")"
    [[ "${MODE}" == "apps" ]] || info "面板升级下次执行：$(timer_next "${PANEL_TIMER}")"
}

install_flow() {
    require_root install "$@"
    check_dependencies
    if [[ $# -gt 0 ]]; then
        configure_noninteractive "$@"
    elif [[ -t 0 ]]; then
        configure_wizard
    else
        load_config
        info "非交互环境使用默认配置。"
        print_plan
    fi
    check_target "${MODE}"
    install_manager_script
    apply_configuration
    success "安装完成。以后运行 1pup 即可管理自动升级。"
}

configure_flow() {
    require_root configure "$@"
    check_dependencies
    if [[ $# -gt 0 ]]; then
        configure_noninteractive "$@"
    else
        configure_wizard
    fi
    check_target "${MODE}"
    apply_configuration
}

unit_state() {
    local timer="$1"
    printf '  %-12s enabled=%-8s active=%-8s next=%s\n' \
        "${timer}" \
        "$(systemctl is-enabled "${timer}" 2>/dev/null || true)" \
        "$(systemctl is-active "${timer}" 2>/dev/null || true)" \
        "$(timer_next "${timer}")"
}

status_flow() {
    require_root status
    load_config
    printf '\n1Panel 自动升级管理器 v%s\n' "${PROGRAM_VERSION}"
    printf '  模式：%s\n' "${MODE}"
    printf '  时区：%s\n' "${TIMEZONE}"
    printf '  应用升级时间：%s\n' "${APPS_TIME}"
    printf '  面板升级时间：%s\n' "${PANEL_TIME}"
    unit_state "${APP_TIMER}"
    unit_state "${PANEL_TIMER}"
    printf '\n'
    check_target "${MODE}" || true
}

select_target_menu() {
    local prompt="$1"
    printf '\n%s\n' "${prompt}" >&2
    printf '  1) 应用\n  2) 面板\n  3) 全部\n  0) 取消\n' >&2
    local choice=""
    read -r -p '请选择 [0]: ' choice || true
    case "${choice:-0}" in
        1) printf 'apps\n' ;;
        2) printf 'panel\n' ;;
        3) printf 'all\n' ;;
        *) printf 'cancel\n' ;;
    esac
}

check_flow() {
    require_root check "$@"
    check_dependencies
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        target="$(select_target_menu '只读检查更新')"
    fi
    [[ "${target}" == "cancel" ]] && return 0
    check_target "${target}"
}

run_flow() {
    require_root run "$@"
    check_dependencies
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        target="$(select_target_menu '立即执行升级')"
    fi
    [[ "${target}" == "cancel" ]] && return 0
    local confirm=""
    warn "即将立即执行 ${target} 升级，可能重启应用容器或 1Panel 服务。"
    read -r -p '确认执行？[y/N]: ' confirm || true
    [[ "${confirm}" =~ ^[Yy]$ ]] || return 0
    python_action run "${target}"
}

logs_flow() {
    require_root logs "$@"
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        target="$(select_target_menu '查看日志')"
    fi
    case "${target}" in
        apps) journalctl -u "${APP_SERVICE}" -n 100 --no-pager ;;
        panel) journalctl -u "${PANEL_SERVICE}" -n 100 --no-pager ;;
        all)
            journalctl -u "${APP_SERVICE}" -n 50 --no-pager
            journalctl -u "${PANEL_SERVICE}" -n 50 --no-pager
            ;;
    esac
}

upgrade_services_running() {
    systemctl is-active --quiet "${APP_SERVICE}" || systemctl is-active --quiet "${PANEL_SERVICE}"
}

repair_flow() {
    require_root repair
    upgrade_services_running && die "升级任务正在运行，不能修复。"
    check_dependencies
    local source
    source="$(manager_source)" || die "无法读取当前脚本。"
    bash -n "${source}"
    bash "${source}" --self-check >/dev/null
    install_manager_script
    load_config
    write_config
    generate_systemd_units
    apply_timer_selection
    check_target "${MODE}"
    success "修复完成，未启动任何升级。"
}

uninstall_flow() {
    require_root uninstall "$@"
    upgrade_services_running && die "升级任务正在运行，不能卸载。"
    local purge="false"
    [[ "${1:-}" == "--purge" ]] && purge="true"
    local confirm=""
    warn "将卸载 1Panel 自动升级管理器，不会卸载或重启 1Panel。"
    read -r -p '确认卸载？[y/N]: ' confirm || true
    [[ "${confirm}" =~ ^[Yy]$ ]] || return 0

    systemctl disable --now "${APP_TIMER}" >/dev/null 2>&1 || true
    systemctl disable --now "${PANEL_TIMER}" >/dev/null 2>&1 || true
    rm -f -- \
        "${SYSTEMD_DIR}/${APP_SERVICE}" \
        "${SYSTEMD_DIR}/${APP_TIMER}" \
        "${SYSTEMD_DIR}/${PANEL_SERVICE}" \
        "${SYSTEMD_DIR}/${PANEL_TIMER}" \
        "${LONG_ALIAS}"
    systemctl daemon-reload
    if [[ "${purge}" == "true" ]]; then
        rm -f -- "${CONFIG_FILE}"
        if [[ -d "${BACKUP_DIR}" ]]; then
            find "${BACKUP_DIR}" -maxdepth 1 -type f -name '*.bak-*' -delete
            rmdir "${BACKUP_DIR}" 2>/dev/null || true
        fi
    fi
    if [[ "${purge}" == "true" && -d "${CONFIG_DIR}" ]]; then
        rmdir "${CONFIG_DIR}" 2>/dev/null || true
    fi
    rm -f -- "${MANAGER_PATH}"
    success "卸载完成。"
}

update_flow() {
    require_root update
    upgrade_services_running && die "升级任务正在运行，不能更新管理脚本。"
    local temp
    temp="$(mktemp /tmp/1pup-update.XXXXXX.sh)"
    download_script "${temp}"
    bash -n "${temp}"
    bash "${temp}" --self-check >/dev/null
    bash "${temp}" repair
    rm -f -- "${temp}"
    success "管理脚本已更新。"
}

menu() {
    while true; do
        load_config
        clear 2>/dev/null || true
        printf '┌──────────────────────────────────────────┐\n'
        printf '│       1Panel 自动升级管理器 v%-8s │\n' "${PROGRAM_VERSION}"
        printf '├──────────────────────────────────────────┤\n'
        printf '│ 当前模式：%-29s│\n' "${MODE}"
        printf '│ 应用升级：%-5s %-21s│\n' "${APPS_TIME}" "${TIMEZONE}"
        printf '│ 面板升级：%-5s %-21s│\n' "${PANEL_TIME}" "${TIMEZONE}"
        printf '├──────────────────────────────────────────┤\n'
        printf '│ 1. 查看状态                              │\n'
        printf '│ 2. 修改功能和时间                        │\n'
        printf '│ 3. 只读检查更新                          │\n'
        printf '│ 4. 立即执行升级                          │\n'
        printf '│ 5. 查看日志                              │\n'
        printf '│ 6. 修复自动升级工具                      │\n'
        printf '│ 7. 卸载                                  │\n'
        printf '│ 8. 更新管理脚本                          │\n'
        printf '│ 0. 退出                                  │\n'
        printf '└──────────────────────────────────────────┘\n'
        local choice=""
        read -r -p '请选择：' choice || return 0
        case "${choice}" in
            1) status_flow ;;
            2) configure_flow ;;
            3) check_flow ;;
            4) run_flow ;;
            5) logs_flow ;;
            6) repair_flow ;;
            7) uninstall_flow; return 0 ;;
            8) update_flow ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
        printf '\n按 Enter 返回菜单...'
        read -r _ || true
    done
}

self_check() {
    command_exists python3 || die "缺少 python3，无法检查嵌入代码。"
    python_action self-check || die "嵌入的 Python 代码自检失败。"
    success "脚本自检通过。"
}

validate_unit_templates() {
    command_exists systemd-analyze || die "缺少 systemd-analyze。"
    local staging original_manager source
    staging="$(mktemp -d /tmp/1pup-unit-check.XXXXXX)"
    original_manager="${MANAGER_PATH}"
    source="$(manager_source)" || die "无法读取当前脚本。"
    install -m 0755 "${source}" "${staging}/1pup"
    MANAGER_PATH="${staging}/1pup"
    TIMEZONE="$(detect_timezone)"
    APPS_TIME="${DEFAULT_APPS_TIME}"
    PANEL_TIME="${DEFAULT_PANEL_TIME}"
    render_app_service >"${staging}/${APP_SERVICE}"
    render_panel_service >"${staging}/${PANEL_SERVICE}"
    render_timer \
        "Daily automatic upgrade of 1Panel App Store applications" \
        "*-*-* ${APPS_TIME}:00 ${TIMEZONE}" \
        "${APP_SERVICE}" >"${staging}/${APP_TIMER}"
    render_timer \
        "Daily automatic upgrade check for the 1Panel system" \
        "*-*-* ${PANEL_TIME}:00 ${TIMEZONE}" \
        "${PANEL_SERVICE}" >"${staging}/${PANEL_TIMER}"
    MANAGER_PATH="${original_manager}"
    systemd-analyze verify \
        "${staging}/${APP_SERVICE}" \
        "${staging}/${APP_TIMER}" \
        "${staging}/${PANEL_SERVICE}" \
        "${staging}/${PANEL_TIMER}"
    rm -f -- \
        "${staging}/${APP_SERVICE}" \
        "${staging}/${APP_TIMER}" \
        "${staging}/${PANEL_SERVICE}" \
        "${staging}/${PANEL_TIMER}" \
        "${staging}/1pup"
    rmdir "${staging}"
    success "systemd 单元模板检查通过。"
}

usage() {
    cat <<EOF
1Panel 自动升级管理器 ${PROGRAM_VERSION}

用法：
  1pup                  打开交互菜单
  1pup install          安装
  1pup configure        修改功能和时间
  1pup status           查看状态
  1pup check [目标]     只读检查，目标为 apps、panel 或 all
  1pup run [目标]       立即执行升级
  1pup logs [目标]      查看日志
  1pup repair           修复工具自身
  1pup update           从仓库 main 分支更新管理脚本
  1pup uninstall        卸载
EOF
}

main() {
    local command="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "${command}" in
        "")
            if [[ -x "${MANAGER_PATH}" && "$(readlink -f "$0" 2>/dev/null || true)" == "$(readlink -f "${MANAGER_PATH}" 2>/dev/null || true)" ]]; then
                require_root
                menu
            else
                install_flow
            fi
            ;;
        install) install_flow "$@" ;;
        configure) configure_flow "$@" ;;
        status) status_flow ;;
        check) check_flow "$@" ;;
        run) run_flow "$@" ;;
        logs) logs_flow "$@" ;;
        repair) repair_flow ;;
        update) update_flow ;;
        uninstall) uninstall_flow "$@" ;;
        _run) require_root _run "$@"; python_action run "${1:-}" ;;
        --check) require_root --check; check_dependencies; check_target all ;;
        --self-check) self_check ;;
        --validate-units) validate_unit_templates ;;
        -h|--help|help) usage ;;
        *) die "未知命令：${command}。运行 1pup --help 查看帮助。" ;;
    esac
}

main "$@"
