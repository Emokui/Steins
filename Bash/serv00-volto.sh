#!/bin/sh
# serv00-volto.sh — FreeBSD/Serv00 用户态 Volto MASQUE 管理脚本
#
# Serv00 没有 root、systemd 和固定的系统目录；本脚本从 Volto 源码编译
# FreeBSD amd64 版本，所有文件放在用户 HOME 下，用 nohup + PID 文件运行。
# Surge 客户端使用 masque policy，服务端只监听 UDP。

set -u
umask 077

REPO_API="https://api.github.com/repos/vcarus/volto/releases/latest"
SOURCE_BASE="https://github.com/vcarus/volto/archive/refs/tags"

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || {
    echo "[错误] HOME 目录不可用" >&2
    exit 1
}

HOME_DIR="$HOME"
WORK_DIR="${WORK_DIR:-$HOME_DIR/volto}"
BIN_PATH="$WORK_DIR/volto"
CONFIG_PATH="$WORK_DIR/config.toml"
CERT_PATH="$WORK_DIR/cert.pem"
KEY_PATH="$WORK_DIR/key.pem"
STATE_PATH="$WORK_DIR/state"
PID_PATH="$WORK_DIR/volto.pid"
LOG_PATH="$WORK_DIR/volto.log"
BUILD_DIR=""
INSTALLING=0

case "$WORK_DIR" in
    ''|/|"$HOME_DIR")
        echo "[错误] WORK_DIR 不安全: $WORK_DIR" >&2
        exit 1
        ;;
esac

script_path() {
    case "$0" in
        /*) printf '%s\n' "$0" ;;
        */*) printf '%s/%s\n' "$(cd "${0%/*}" 2>/dev/null && pwd -P)" "${0##*/}" ;;
        *) command -v "$0" 2>/dev/null || printf '%s/%s\n' "$(pwd -P)" "$0" ;;
    esac
}

SCRIPT_PATH="$(script_path)"

say() { printf '%s\n' "$*" >&2; }
ok() { say "[成功] $*"; }
warn() { say "[警告] $*"; }
err() { say "[错误] $*"; }

is_interactive() { [ -t 0 ] && [ -t 1 ]; }

require_commands() {
    missing=""
    for command in awk chmod date head kill mkdir mv nohup openssl ps sed sleep stty tail tr uname wc tar; do
        command -v "$command" >/dev/null 2>&1 || missing="$missing $command"
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v fetch >/dev/null 2>&1; then
        missing="$missing curl-or-fetch"
    fi
    [ -n "$missing" ] && { err "缺少依赖命令:$missing"; return 1; }
}

check_platform() {
    os=$(uname -s 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)
    [ "$os" = FreeBSD ] || { err "本脚本仅支持 FreeBSD，当前系统: ${os:-unknown}"; return 1; }
    [ "$arch" = amd64 ] || { err "本脚本仅支持 FreeBSD amd64，当前架构: ${arch:-unknown}"; return 1; }
}

fetch_text() {
    url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 60 "$url"
    else
        fetch -qo - "$url"
    fi
}

download_file() {
    url="$1"
    target="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 --max-time 900 "$url" -o "$target"
    else
        fetch -o "$target" "$url"
    fi
}

latest_version() {
    fetch_text "$REPO_API" | awk -F '"' '
        /"tag_name"[[:space:]]*:/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
            }
        }
    '
}

installed_version() {
    [ -x "$BIN_PATH" ] || return 1
    "$BIN_PATH" --version 2>/dev/null | awk '
        { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit } }
    '
}

cleanup_build() {
    if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
    BUILD_DIR=""
}

cleanup() {
    status=$?
    trap - EXIT
    cleanup_build
    if [ "$INSTALLING" = 1 ] && [ "$status" -ne 0 ]; then
        rm -rf "$WORK_DIR"
    fi
    exit "$status"
}
trap cleanup EXIT

require_rust() {
    if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
        err "Serv00 未找到 cargo / rustc。请先在账户中安装 Rust 1.95 或更新版本。"
        return 1
    fi
    rust_version=$(rustc --version | awk '{print $2}')
    say "[信息] Rust: ${rust_version:-unknown}"
}

build_release() {
    version="$1"
    require_rust || return 1
    cleanup_build
    BUILD_DIR=$(mktemp -d "$WORK_DIR/.build.XXXXXX") || return 1
    archive="$BUILD_DIR/source.tar.gz"
    source_dir="$BUILD_DIR/source"
    mkdir -p "$source_dir" || { cleanup_build; return 1; }

    say "[信息] 正在下载 Volto ${version} 源码..."
    download_file "${SOURCE_BASE}/${version}.tar.gz" "$archive" || {
        err "Volto 源码下载失败"
        cleanup_build
        return 1
    }
    tar -xzf "$archive" -C "$source_dir" --strip-components 1 || {
        err "Volto 源码解压失败"
        cleanup_build
        return 1
    }
    [ -f "$source_dir/Cargo.lock" ] || {
        err "源码中缺少 Cargo.lock，拒绝无锁定编译"
        cleanup_build
        return 1
    }

    say "[信息] 正在编译 Volto ${version}，首次编译可能需要较长时间..."
    if ! (
        cd "$source_dir" || exit 1
        CARGO_HOME="$WORK_DIR/.cargo" \
        CARGO_TARGET_DIR="$BUILD_DIR/target" \
        cargo build --release --locked
    ); then
        err "Volto 编译失败"
        cleanup_build
        return 1
    fi
    [ -x "$BUILD_DIR/target/release/volto" ] || {
        err "编译完成但未找到 Volto 二进制"
        cleanup_build
        return 1
    }
    built_version=$("$BUILD_DIR/target/release/volto" --version 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
    }')
    [ "$built_version" = "${version#v}" ] || {
        err "编译版本校验失败: ${built_version:-unknown} != ${version#v}"
        cleanup_build
        return 1
    }
}

random_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

prompt_input() {
    label="$1"
    default="${2:-}"
    secret="${3:-0}"
    value=""
    if [ "$secret" = 1 ]; then
        [ -n "$default" ] && printf '%s（默认值已隐藏）: ' "$label" >&2 || printf '%s: ' "$label" >&2
        stty -echo 2>/dev/null || true
        IFS= read -r value
        stty echo 2>/dev/null || true
        printf '\n' >&2
    else
        [ -n "$default" ] && printf '%s（默认：%s）: ' "$label" "$default" >&2 || printf '%s: ' "$label" >&2
        IFS= read -r value
    fi
    [ -n "$value" ] || value="$default"
    printf '%s\n' "$value"
}

valid_port() {
    case "$1" in *[!0-9]*|'') return 1;; esac
    [ "$1" -ge 1024 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

prompt_port() {
    while :; do
        value=$(prompt_input '请输入已在 Serv00 面板分配的 UDP 端口' "${1:-24843}")
        valid_port "$value" && { printf '%s\n' "$value"; return 0; }
        warn '非 root 用户端口必须是 1024–65535 的已分配端口。'
    done
}

valid_token() {
    value="$1"
    [ -n "$value" ] && [ "$(printf %s "$value" | wc -c)" -le 128 ] || return 1
    case "$value" in *[!A-Za-z0-9]*) return 1;; esac
}

valid_sni() {
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in ''|*[!a-z0-9.-]*|.*|*.|-*|*-|*..*|*-.*|*.-*) return 1;; esac
    case "$value" in *.*) return 0;; *) return 1;; esac
}

valid_path() {
    value="$1"
    [ -n "$value" ] && [ "${value#/}" != "$value" ] || return 1
    case "$value" in *'"'*|*'='*|*'|'*) return 1;; esac
}

toml_escape() {
    printf '%s' "$1" | sed 's/[\\"]/[\\&]/g'
}

same_public_key() {
    cert_pub=$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    key_pub=$(openssl pkey -in "$2" -passin pass: -pubout -outform DER 2>/dev/null |
        openssl dgst -sha256) || return 1
    [ "$cert_pub" = "$key_pub" ]
}

certificate_fingerprint() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^.*=//' | tr -d ':'
}

generate_selfsigned() {
    sni="$1"
    openssl_conf="$WORK_DIR/.openssl.cnf"
    cat > "$openssl_conf" <<EOF
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = $sni
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$sni
EOF
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -days 3650 -keyout "$KEY_PATH" -out "$CERT_PATH" \
        -config "$openssl_conf" >/dev/null 2>&1 || return 1
    rm -f "$openssl_conf"
    chmod 600 "$CERT_PATH" "$KEY_PATH"
}

verify_certificate() {
    mode="$1"
    sni="$2"
    [ -s "$CERT_PATH" ] && [ -s "$KEY_PATH" ] || { err '证书或私钥为空'; return 1; }
    openssl x509 -in "$CERT_PATH" -noout >/dev/null 2>&1 || { err '证书格式无效'; return 1; }
    openssl pkey -in "$KEY_PATH" -noout >/dev/null 2>&1 || { err '私钥格式无效'; return 1; }
    same_public_key "$CERT_PATH" "$KEY_PATH" || { err '证书与私钥不匹配'; return 1; }
    case "$mode" in
        pin)
            # Pinning deliberately does not turn the leaf into a CA. Checking
            # expiry and parsing is the portable part; Volto validates that the
            # configured expected_sni is covered by the certificate at startup.
            openssl x509 -in "$CERT_PATH" -checkend 0 -noout >/dev/null 2>&1 || {
                err '指纹证书已过期或格式无效'; return 1;
            }
            ;;
        ca)
            verify_status=0
            if openssl verify -help 2>&1 | awk '/verify_hostname/ { found = 1 } END { exit(found ? 0 : 1) }'; then
                openssl verify -purpose sslserver -verify_hostname "$sni" \
                    -untrusted "$CERT_PATH" "$CERT_PATH" >/dev/null 2>&1 || verify_status=$?
            else
                warn '当前 OpenSSL 不支持命令行 SNI 检查，将由 Volto 启动时校验证书与 SNI。'
                openssl verify -purpose sslserver -untrusted "$CERT_PATH" "$CERT_PATH" >/dev/null 2>&1 || verify_status=$?
            fi
            if [ "$verify_status" -ne 0 ]; then
                err '证书链、有效期、用途或 SNI 校验失败'; return 1;
            fi
            ;;
        *) err '未知证书校验模式'; return 1;;
    esac
}

choose_certificate() {
    printf '\n请选择证书方式：\n' >&2
    printf '1. 生成自签名证书 + Surge 指纹固定 (无需域名证书)\n' >&2
    printf '2. 使用已有域名证书 + CA 验证\n' >&2
    printf '3. 使用已有证书 + Surge 指纹固定\n' >&2
    choice=$(prompt_input '请输入选项 [1-3]' 1)
    case "$choice" in 1|2|3) ;; *) err '证书选项无效'; return 1;; esac

    default_sni=volto.internal
    sni=$(prompt_input '请输入 SNI / 证书域名' "$default_sni")
    valid_sni "$sni" || { err 'SNI 必须是有效域名，例如 volto.example.com'; return 1; }
    sni=$(printf '%s' "$sni" | tr '[:upper:]' '[:lower:]')

    case "$choice" in
        1)
            generate_selfsigned "$sni" || { err '自签名证书生成失败'; return 1; }
            mode=pin
            cert_source=
            key_source=
            ;;
        2|3)
            cert_source=$(prompt_input '完整证书链 PEM 路径')
            key_source=$(prompt_input '私钥 PEM 路径')
            valid_path "$cert_source" && valid_path "$key_source" &&
                [ -r "$cert_source" ] && [ -r "$key_source" ] || {
                err '证书和私钥必须是存在且可读的绝对路径'; return 1;
            }
            if ! cp "$cert_source" "$CERT_PATH" || ! cp "$key_source" "$KEY_PATH"; then
                err '复制证书或私钥失败'; return 1;
            fi
            chmod 600 "$CERT_PATH" "$KEY_PATH" || return 1
            [ "$choice" = 2 ] && mode=ca || mode=pin
            ;;
    esac
    verify_certificate "$mode" "$sni" || return 1
    printf '%s\n' "$mode|$sni|$cert_source|$key_source"
}

write_config() {
    port="$1" sni="$2" username="$3" password="$4"
    cert=$(toml_escape "$CERT_PATH")
    key=$(toml_escape "$KEY_PATH")
    sni_escaped=$(toml_escape "$sni")
    {
        printf '%s\n' '[server]' \
            "listen = \"0.0.0.0:$port\"" \
            "cert = \"$cert\"" \
            "key = \"$key\"" \
            '' '[auth]' \
            "users = [{ username = \"$username\", password = \"$password\" }]" \
            '' '[limits]' \
            'max_connections = 32' \
            'max_targets_per_conn = 128' \
            'max_streams_bidi = 512' \
            'ip_family_preference = "ipv4"' \
            '' '[security]' \
            'allow_private_networks = false' \
            'denied_ports = [25]' \
            "expected_sni = [\"$sni_escaped\"]" \
            '' '[log]' \
            'level = "info"' \
            'keylog = false'
    } > "$CONFIG_PATH" || return 1
    chmod 600 "$CONFIG_PATH"
}

write_state() {
    port="$1" sni="$2" username="$3" password="$4" mode="$5" cert_source="$6" key_source="$7"
    {
        printf 'PORT=%s\n' "$port"
        printf 'SNI=%s\n' "$sni"
        printf 'USERNAME=%s\n' "$username"
        printf 'PASSWORD=%s\n' "$password"
        printf 'CERT_MODE=%s\n' "$mode"
        printf 'CERT_SOURCE=%s\n' "$cert_source"
        printf 'KEY_SOURCE=%s\n' "$key_source"
    } > "$STATE_PATH" || return 1
    chmod 600 "$STATE_PATH"
}

state_value() {
    key="$1"
    [ -r "$STATE_PATH" ] || return 1
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE_PATH"
}

write_pid() { printf '%s\n' "$1" > "$PID_PATH" && chmod 600 "$PID_PATH"; }

process_command() {
    pid="$1"
    ps -p "$pid" -o command= 2>/dev/null || true
}

running_pid() {
    [ -r "$PID_PATH" ] || return 1
    pid=$(sed -n '1p' "$PID_PATH")
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    command=$(process_command "$pid")
    case "$command" in *"$BIN_PATH"*"$CONFIG_PATH"*) printf '%s\n' "$pid";; *) return 1;; esac
}

is_running() { running_pid >/dev/null 2>&1; }

validate_install() {
    [ -x "$BIN_PATH" ] || { err "未找到 Volto: $BIN_PATH"; return 1; }
    [ -r "$CONFIG_PATH" ] || { err "未找到配置: $CONFIG_PATH"; return 1; }
    "$BIN_PATH" --check-config --config "$CONFIG_PATH" || {
        err 'Volto 配置校验失败'; return 1;
    }
}

start_process() {
    if is_running; then
        say "[提示] Volto 已在运行，PID: $(running_pid)"
        return 0
    fi
    validate_install || return 1
    nohup "$BIN_PATH" --config "$CONFIG_PATH" >> "$LOG_PATH" 2>&1 </dev/null &
    pid=$!
    write_pid "$pid" || return 1
    sleep 2
    if is_running; then
        ok "Volto 已启动（PID: $(running_pid)）"
        return 0
    fi
    err 'Volto 启动失败，请查看日志:'
    tail -n 30 "$LOG_PATH" 2>/dev/null || true
    return 1
}

stop_process() {
    pid=$(running_pid 2>/dev/null || true)
    [ -n "$pid" ] || { rm -f "$PID_PATH"; say '[提示] Volto 当前未运行'; return 0; }
    say "[信息] 正在停止 PID: $pid"
    kill "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 15 ]; do
        is_running || { rm -f "$PID_PATH"; ok 'Volto 已停止'; return 0; }
        i=$((i + 1)); sleep 1
    done
    warn '正常停止超时，发送 KILL'
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_PATH"
    is_running && { err 'Volto 停止失败'; return 1; }
    ok 'Volto 已停止'
}

surge_config() {
    port=$(state_value PORT 2>/dev/null) || return 1
    sni=$(state_value SNI 2>/dev/null) || return 1
    username=$(state_value USERNAME 2>/dev/null) || return 1
    password=$(state_value PASSWORD 2>/dev/null) || return 1
    endpoint=$(state_value ENDPOINT 2>/dev/null || true)
    [ -n "$endpoint" ] || endpoint=$(prompt_input 'Surge 连接的公网 IP / 域名')
    mode=$(state_value CERT_MODE 2>/dev/null) || return 1
    extra=''
    case "$mode" in
        pin) fp=$(certificate_fingerprint "$CERT_PATH") || return 1; extra=", server-cert-fingerprint-sha256=$fp";;
        ca) extra=", server-cert-verify-name=$sni";;
        *) return 1;;
    esac
    printf 'Volto-%s = masque, %s, %s, sni=%s%s, username=%s, password=%s\n' \
        "$username" "$endpoint" "$port" "$sni" "$extra" "$username" "$password"
}

show_surge() {
    validate_install || return 1
    say '请将下面一行放入 Surge 的 [Proxy]，再把节点加入策略组：'
    surge_config
    say "配置文件: $CONFIG_PATH"
}

show_status() {
    version=$(installed_version 2>/dev/null || true)
    echo "Volto: ${version:-未安装}"
    echo "目录: $WORK_DIR"
    if is_running; then echo "状态: 运行中（PID: $(running_pid)）"; else echo '状态: 未运行'; fi
    [ -r "$STATE_PATH" ] && {
        echo "UDP 端口: $(state_value PORT)"
        echo "SNI: $(state_value SNI)"
        echo "账号: $(state_value USERNAME)"
        echo "密码: 已隐藏"
        echo "证书模式: $(state_value CERT_MODE)"
    }
}

check_install() {
    validate_install || return 1
    mode=$(state_value CERT_MODE 2>/dev/null) || return 1
    sni=$(state_value SNI 2>/dev/null) || return 1
    verify_certificate "$mode" "$sni" || return 1
    ok '配置、证书和私钥检查通过。'
}

install_service() {
    [ -t 0 ] || { err '首次安装需要交互式终端'; return 1; }
    check_platform || return 1
    mkdir -p "$WORK_DIR" || return 1
    INSTALLING=1
    [ ! -e "$BIN_PATH" ] && [ ! -e "$CONFIG_PATH" ] || {
        err "检测到已有安装目录: $WORK_DIR，请使用管理菜单或先备份"; return 1;
    }
    version=$(latest_version) || { err '获取 Volto 最新 Release 失败'; return 1; }
    [ -n "$version" ] || { err '无法解析 Volto Release 版本'; return 1; }
    build_release "$version" || return 1
    port=$(prompt_port)
    endpoint=$(prompt_input '请输入 Surge 连接的公网 IP / 域名')
    [ -n "$endpoint" ] || { err '连接地址不能为空'; return 1; }
    username=$(prompt_input '用户名' surge)
    valid_token "$username" && [ "$(printf %s "$username" | wc -c)" -le 32 ] || {
        err '用户名只能使用 1–32 位字母数字'; return 1;
    }
    password=$(prompt_input '密码（8–128 位字母数字，回车随机生成 16 位）' "$(random_password)" 1)
    valid_token "$password" && [ "$(printf %s "$password" | wc -c)" -ge 8 ] || {
        err '密码只能使用 8–128 位字母数字'; return 1;
    }
    cert_info=$(choose_certificate) || return 1
    mode=$(printf '%s' "$cert_info" | awk -F'|' '{print $1}')
    sni=$(printf '%s' "$cert_info" | awk -F'|' '{print $2}')
    cert_source=$(printf '%s' "$cert_info" | awk -F'|' '{print $3}')
    key_source=$(printf '%s' "$cert_info" | awk -F'|' '{print $4}')
    write_config "$port" "$sni" "$username" "$password" || return 1
    write_state "$port" "$sni" "$username" "$password" "$mode" "$cert_source" "$key_source" || return 1
    printf 'ENDPOINT=%s\n' "$endpoint" >> "$STATE_PATH"
    chmod 600 "$STATE_PATH"
    original_bin_path="$BIN_PATH"
    BIN_PATH="$BUILD_DIR/target/release/volto"
    validate_install || return 1
    BIN_PATH="$original_bin_path"
    cp "$BUILD_DIR/target/release/volto" "$BIN_PATH" || return 1
    chmod 700 "$BIN_PATH"
    cleanup_build
    start_process || return 1
    INSTALLING=0
    ok 'Volto 安装完成。'
    say "建议在 Serv00 面板添加定时任务，保持进程运行："
    say "* * * * * /bin/sh $SCRIPT_PATH ensure >/dev/null 2>&1"
    show_surge
}

update_service() {
    [ -x "$BIN_PATH" ] || { err '尚未安装 Volto'; return 1; }
    latest=$(latest_version) || { err '获取最新版本失败'; return 1; }
    current=$(installed_version 2>/dev/null || true)
    [ -n "$latest" ] || return 1
    [ "$current" = "${latest#v}" ] && { say "[信息] Volto 已是最新版本: $current"; return 0; }
    say "[信息] 检测到新版本: ${current:-unknown} -> ${latest#v}"
    build_release "$latest" || return 1
    was_running=0; is_running && was_running=1
    [ "$was_running" = 0 ] || stop_process || { cleanup_build; return 1; }
    cp "$BIN_PATH" "$WORK_DIR/volto.previous" || { cleanup_build; return 1; }
    if ! cp "$BUILD_DIR/target/release/volto" "$BIN_PATH" || ! chmod 700 "$BIN_PATH"; then
        cp "$WORK_DIR/volto.previous" "$BIN_PATH"; cleanup_build; [ "$was_running" = 0 ] || start_process; return 1;
    fi
    cleanup_build
    if [ "$was_running" = 1 ] && ! start_process; then
        warn '新版本启动失败，正在恢复旧版本'
        stop_process >/dev/null 2>&1 || true
        cp "$WORK_DIR/volto.previous" "$BIN_PATH" && chmod 700 "$BIN_PATH" && start_process
        return 1
    fi
    rm -f "$WORK_DIR/volto.previous"
    ok "Volto 已更新到 ${latest#v}"
}

renew_certificate() {
    mode=$(state_value CERT_MODE 2>/dev/null) || { err '未找到安装状态'; return 1; }
    [ "$mode" = pin ] || [ "$mode" = ca ] || return 1
    cert_source=$(state_value CERT_SOURCE 2>/dev/null || true)
    key_source=$(state_value KEY_SOURCE 2>/dev/null || true)
    [ -r "$cert_source" ] && [ -r "$key_source" ] || {
        err '原始证书路径不可读，请检查 Serv00 文件路径'; return 1;
    }
    cp "$cert_source" "$CERT_PATH" && cp "$key_source" "$KEY_PATH" || return 1
    chmod 600 "$CERT_PATH" "$KEY_PATH"
    sni=$(state_value SNI) || return 1
    verify_certificate "$mode" "$sni" || return 1
    validate_install || return 1
    if is_running; then restart_process; else ok '证书已同步，服务当前保持停止'; fi
    [ "$mode" = pin ] && warn '证书指纹可能已经变化，请重新执行 show-surge 并更新 Surge。'
}

delete_service() {
    [ -d "$WORK_DIR" ] || { say '[提示] 未找到 Volto 安装目录'; return 0; }
    stop_process || return 1
    rm -rf "$WORK_DIR" || { err "删除失败: $WORK_DIR"; return 1; }
    ok 'Volto 程序、配置、证书和编译缓存已删除。'
}

restart_process() { stop_process && start_process; }

menu() {
    while :; do
        printf '\n✦ Volto Serv00 管理 ✦\n'
        printf '1. 查看状态\n2. 启动服务\n3. 重启服务\n4. 查看 Surge 节点\n5. 检查配置和证书\n6. 更新内核\n7. 同步已有证书\n8. 删除服务\n0. 退出\n'
        choice=$(prompt_input '✦ 请输入选项' '')
        case "$choice" in
            1) show_status;; 2) start_process;; 3) restart_process;; 4) show_surge;;
            5) check_install;; 6) update_service;; 7) renew_certificate;;
            8) delete_service;; 0) return 0;; *) warn '无效选项';;
        esac
    done
}

usage() {
    cat <<EOF
用法: $0 [install|start|stop|restart|ensure|status|show-surge|check|update|renew-cert|delete]

首次运行直接执行 $0，或执行 $0 install。
适用: FreeBSD Serv00 amd64，无 root / systemd / pkg。
首次安装会从 Volto 官方源码按 Cargo.lock 编译 FreeBSD amd64 版本。
EOF
}

main() {
    case "${1:-}" in -h|--help) usage; return 0;; esac
    require_commands || return 1
    check_platform || return 1
    case "${1:-}" in
        install) install_service;;
        start) start_process;;
        stop) stop_process;;
        restart) restart_process;;
        ensure) [ -x "$BIN_PATH" ] && { is_running || start_process; };;
        status) show_status;;
        show-surge) show_surge;;
        check) check_install;;
        update) update_service;;
        renew-cert) renew_certificate;;
        delete) delete_service;;
        '')
            if [ -x "$BIN_PATH" ] && [ -r "$CONFIG_PATH" ]; then menu; else install_service; fi
            ;;
        *) usage >&2; return 1;;
    esac
}

main "$@"
