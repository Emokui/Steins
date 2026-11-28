#!/bin/bash

set -u

GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
RED=$'\033[0;31m'
PLAIN=$'\033[0m'

check_supported_system() {
    local os_id arch

    if [[ ! -r /etc/os-release ]]; then
        echo -e "${RED}不支持${PLAIN}"
        return 1
    fi

    source /etc/os-release
    os_id="${ID:-}"
    case "$os_id" in
        debian|ubuntu) ;;
        *)
            echo -e "${RED}不支持${PLAIN}"
            return 1
            ;;
    esac

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64|aarch64|arm64) return 0 ;;
        *)
            echo -e "${RED}不支持${PLAIN}"
            return 1
            ;;
    esac
}

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请用 root 用户运行本脚本${PLAIN}"
  exit 1
fi

check_supported_system || exit 1

get_root_home() {
    local user uid dir home=""
    if [[ -r /etc/passwd ]]; then
        while IFS=: read -r user _ uid _ _ dir _; do
            if [[ "$user" == "root" ]]; then
                home="$dir"
                break
            fi
        done < /etc/passwd
    fi
    [[ -n "$home" ]] || home=$(getent passwd root 2>/dev/null | cut -d: -f6)
    printf '%s\n' "${home:-/root}"
}

ROOT_HOME="$(get_root_home)"
SSHD_CONFIG="/etc/ssh/sshd_config"

press_any_key_to_continue() {
    if [ -t 0 ]; then
        local msg="${1:-按任意键返回菜单...}"
        printf '%s%s%s' "$GREEN" "$msg" "$PLAIN"
        read -n 1 -s -r || true
        echo
    else
        echo
    fi
}

pause_enter() {
    local msg="${1:-按回车继续...}"
    if [ -t 0 ]; then
        read -r -p "${BLUE}${msg}${PLAIN}" _ || true
    else
        echo
    fi
}

pause_enter_and_clear() {
    pause_enter "${1:-按回车返回...}"
    clear
}

trim_input() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

log_prefixed() {
    local color="$1"
    local prefix="$2"
    shift 2
    echo -e "${color}${prefix}${PLAIN} $*"
}

service_failure_hint() {
    local service_name="$1"
    [[ -n "$service_name" ]] && echo -e "${YELLOW}需要排查时: systemctl status --no-pager ${service_name}${PLAIN}"
}

normalize_numeric_choice() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        value="${value#"${value%%[!0]*}"}"
        printf '%s' "${value:-0}"
    else
        printf '%s' "$value"
    fi
}

read_menu_choice() {
    local prompt="$1"
    local value
    read -r -p "${BLUE}${prompt}${PLAIN}" value || return 1
    normalize_numeric_choice "$value"
}

valid_list_index() {
    local value="$1" count="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le ${#count} ]] && (( value <= count ))
}

show_invalid_option() {
    local message="${1:-无效选项}"
    local delay="${2:-0.5}"
    local clear_first="${3:-0}"

    (( clear_first )) && clear
    echo -e "${RED}${message}${PLAIN}"
    sleep "$delay"
}

get_default_interface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [[ -z "$iface" ]] && iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
    echo "${iface%%@*}"
}

zero_get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

zero_is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port >= 1 && port <= 65535 ))
}

zero_is_valid_uuid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

zero_random_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v openssl >/dev/null 2>&1; then
        local hex
        hex=$(openssl rand -hex 16 2>/dev/null) || return 1
        printf '%s-%s-4%s-%x%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" $(( 0x${hex:16:1} & 0x3 | 0x8 )) "${hex:17:3}" "${hex:20:12}"
    else
        return 1
    fi
}

ssh_ensure_run_dir() {
    [[ -d /run/sshd ]] && return 0
    install -d -m 0755 -o root -g root /run/sshd 2>/dev/null || mkdir -p -m 0755 /run/sshd 2>/dev/null || true
}

get_sshd_effective_option() {
    local option="$1"
    local value
    command -v sshd >/dev/null 2>&1 || return 1
    ssh_ensure_run_dir
    value=$(sshd -T -f "$SSHD_CONFIG" 2>/dev/null | awk -v key="$option" 'BEGIN { key = tolower(key) } tolower($1) == key { print $2; exit }')
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

update_sshd_option() {
    local option="$1"
    local value="$2"
    local config_file="${3:-$SSHD_CONFIG}"
    local dropin_dir="${config_file}.d" src_file="/dev/null" config_dir f tmp_file

    if [[ -d "$dropin_dir" ]]; then
        for f in "$dropin_dir"/*.conf; do
            [[ -f "$f" ]] || continue
            grep -Eqi "^[#[:space:]]*${option}([[:space:]]+|=)" "$f" 2>/dev/null || continue
            tmp_file=$(mktemp "${f}.zero.XXXXXX") || return 1
            chmod --reference="$f" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file"
            awk -v k="$option" '
                BEGIN { lk = tolower(k); in_match = 0 }
                tolower($1) == "match" { in_match = 1 }
                !in_match && tolower($0) ~ ("^[#[:space:]]*" lk "([[:space:]]+|=)") { next }
                { print }
            ' "$f" > "$tmp_file" && mv -f "$tmp_file" "$f" || { rm -f "$tmp_file"; return 1; }
        done
    fi

    if [[ "$config_file" == */* ]]; then
        config_dir="${config_file%/*}"
        mkdir -p "${config_dir:-/}" || return 1
    fi
    tmp_file=$(mktemp "${config_file}.zero.XXXXXX") || return 1
    if [[ -f "$config_file" ]]; then
        src_file="$config_file"
        chmod --reference="$config_file" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file"
    else
        chmod 644 "$tmp_file"
    fi

    if awk -v k="$option" -v v="$value" '
        BEGIN { inserted = 0; lk = tolower(k); in_match = 0 }
        {
            low = tolower($0)
            if (!in_match && low ~ "^[[:space:]]*match[[:space:]]+") {
                if (!inserted) {
                    print k " " v
                    inserted = 1
                }
                in_match = 1
            }
            if (!in_match && low ~ ("^[#[:space:]]*" lk "([[:space:]]+|=)")) next
            print
        }
        END {
            if (!inserted) print k " " v
        }
    ' "$src_file" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$config_file"; then
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

get_sshd_option() {
    local option="$1"
    local default="${2:-}"
    local config_file="${3:-$SSHD_CONFIG}"
    local effective value="" f dropin_list=""

    if [[ "$config_file" == "$SSHD_CONFIG" ]] && effective=$(get_sshd_effective_option "$option"); then
        printf '%s\n' "$effective"
        return 0
    fi

    if [[ -f "$config_file" ]]; then
        if [[ -d "${config_file}.d" ]]; then
            for f in "${config_file}.d"/*.conf; do
                [[ -f "$f" ]] && dropin_list+="${dropin_list:+$'\n'}$f"
            done
        fi
        value=$(awk -v k="$option" -v dropins="$dropin_list" '
            function check_line(raw,    line, kw) {
                if (raw ~ /^[[:space:]]*#/) return 0
                line = raw
                sub(/^[[:space:]]+/, "", line)
                kw = line
                sub(/[[:space:]=].*$/, "", kw)
                kw = tolower(kw)
                if (kw == "match") exit
                if (kw == lk) {
                    sub(/^[^[:space:]=]+[[:space:]=]+/, "", line)
                    sub(/[[:space:]]+$/, "", line)
                    print tolower(line)
                    exit
                }
                return (kw == "include")
            }
            BEGIN {
                lk = tolower(k)
                nd = split(dropins, dfiles, "\n")
            }
            {
                if (check_line($0)) {
                    for (i = 1; i <= nd; i++) {
                        if (dfiles[i] == "") continue
                        while ((getline dline < dfiles[i]) > 0) {
                            if (tolower(dline) ~ /^[[:space:]]*match([[:space:]]|$)/) break
                            check_line(dline)
                        }
                        close(dfiles[i])
                    }
                }
            }
        ' "$config_file" 2>/dev/null)
    fi
    printf '%s\n' "${value:-$default}"
}

ssh_get_current_port() {
    local current_port
    current_port=$(get_sshd_option "Port" "22")
    [[ "$current_port" =~ ^[0-9]+$ ]] || current_port=22
    printf '%s\n' "$current_port"
}

ssh_root_has_authorized_key() {
    local tok extra=""
    if (( $# > 0 )); then
        extra="$1"
    elif command -v sshd >/dev/null 2>&1; then
        ssh_ensure_run_dir
        extra=$(sshd -T -f "$SSHD_CONFIG" 2>/dev/null | awk 'tolower($1) == "authorizedkeysfile" { $1 = ""; print; exit }')
    fi
    for tok in $extra "$ROOT_HOME/.ssh/authorized_keys" "$ROOT_HOME/.ssh/authorized_keys2"; do
        [[ -n "$tok" && "$tok" != "none" ]] || continue
        tok="${tok//%%/__ZERO_PCT__}"
        tok="${tok//%h/$ROOT_HOME}"
        tok="${tok//%u/root}"
        tok="${tok//__ZERO_PCT__/%}"
        [[ "$tok" == /* ]] || tok="$ROOT_HOME/$tok"
        [[ -r "$tok" ]] && grep -Eq '^[[:space:]]*[^#[:space:]]' "$tok" 2>/dev/null && return 0
    done
    return 1
}

ssh_read_status() {
    local out="" port="" root="" pass="" pub="" authkeys="" has_key=0
    if command -v sshd >/dev/null 2>&1; then
        ssh_ensure_run_dir
        out=$(sshd -T -f "$SSHD_CONFIG" 2>/dev/null | awk '
            {
                k = tolower($1)
                if (k == "port" && port == "") port = $2
                else if (k == "permitrootlogin" && root == "") root = tolower($2)
                else if (k == "passwordauthentication" && pass == "") pass = tolower($2)
                else if (k == "kbdinteractiveauthentication" && kbd == "") kbd = tolower($2)
                else if (k == "challengeresponseauthentication" && chal == "") chal = tolower($2)
                else if (k == "pubkeyauthentication" && pub == "") pub = tolower($2)
                else if (k == "authorizedkeysfile" && authk == "") {
                    line = $0
                    sub(/^[^ \t]+[ \t]+/, "", line)
                    authk = line
                }
            }
            END {
                if (port != "" || root != "" || pass != "" || pub != "") {
                    if (port !~ /^[0-9]+$/) port = "22"
                    if (root == "") root = "prohibit-password"
                    eff_kbd = (kbd != "") ? kbd : chal
                    eff_pass = (pass == "yes" || eff_kbd == "yes") ? "yes" : (pass == "" ? "yes" : "no")
                    if (pub == "") pub = "yes"
                    printf "%s\n%s\n%s\n%s\n%s\n", port, root, eff_pass, pub, authk
                }
            }
        ')
    fi
    if [[ -n "$out" ]]; then
        {
            IFS= read -r port
            IFS= read -r root
            IFS= read -r pass
            IFS= read -r pub
            IFS= read -r authkeys || true
        } <<< "$out"
        ssh_root_has_authorized_key "$authkeys" && has_key=1
        printf '%s\n' "$port" "$root" "$pass" "$pub" "$has_key"
        return 0
    fi
    local raw_pass raw_kbd
    raw_pass=$(get_sshd_option "PasswordAuthentication" "yes")
    raw_kbd=$(get_sshd_option "KbdInteractiveAuthentication" "")
    [[ -n "$raw_kbd" ]] || raw_kbd=$(get_sshd_option "ChallengeResponseAuthentication" "no")
    if [[ "$raw_pass" == "yes" || "$raw_kbd" == "yes" ]]; then
        pass="yes"
    else
        pass="no"
    fi
    authkeys=$(get_sshd_option "AuthorizedKeysFile" "")
    ssh_root_has_authorized_key "$authkeys" && has_key=1
    printf '%s\n' \
        "$(ssh_get_current_port)" \
        "$(get_sshd_option "PermitRootLogin" "prohibit-password")" \
        "$pass" \
        "$(get_sshd_option "PubkeyAuthentication" "yes")" \
        "$has_key"
}

ssh_status_label() {
    [[ "$1" == "yes" ]] && echo "${GREEN}开启${PLAIN}" || echo "${RED}关闭${PLAIN}"
}

ssh_pubkey_status_label() {
    if [[ "$1" != "yes" ]]; then
        echo "${RED}关闭${PLAIN}"
    elif [[ "${2:-}" == "1" ]] || { [[ -z "${2:-}" ]] && ssh_root_has_authorized_key; }; then
        echo "${GREEN}开启${PLAIN}"
    else
        echo "${YELLOW}开启(无公钥)${PLAIN}"
    fi
}

ssh_root_login_label() {
    case "$1" in
        yes) echo "${GREEN}开启${PLAIN}" ;;
        prohibit-password|without-password) echo "${YELLOW}仅密钥${PLAIN}" ;;
        forced-commands-only) echo "${YELLOW}受限${PLAIN}" ;;
        no) echo "${RED}关闭${PLAIN}" ;;
        *) echo "${YELLOW}${1:-未知}${PLAIN}" ;;
    esac
}

zero_port_is_listening() {
    local port="$1" proto="${2:-tcp}"
    if command -v ss >/dev/null 2>&1; then
        case "$proto" in
            udp)  ss -H -lnu "sport = :$port" 2>/dev/null | grep -q . ;;
            both) ss -H -lntu "sport = :$port" 2>/dev/null | grep -q . ;;
            *)    ss -H -lnt "sport = :$port" 2>/dev/null | grep -q . ;;
        esac
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        local flag="-lnt"
        [[ "$proto" == "udp" ]] && flag="-lnu"
        [[ "$proto" == "both" ]] && flag="-lntu"
        netstat "$flag" 2>/dev/null | awk -v port="$port" '$4 ~ ":" port "$" || $4 ~ "\\]:" port "$" {found=1; exit} END {exit !found}'
        return $?
    fi
    return 1
}

ssh_socket_unit_managed() {
    local unit="$1"
    systemctl cat "$unit" >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "$unit" 2>/dev/null || systemctl is-enabled --quiet "$unit" 2>/dev/null
}

ssh_socket_units_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    local unit
    for unit in ssh.socket sshd.socket; do
        ssh_socket_unit_managed "$unit" && return 0
    done
    return 1
}

ssh_apply_socket_port() {
    local port="$1" systemd_dir="${SSH_SYSTEMD_DIR:-/etc/systemd/system}"
    local unit dropin_dir dropin_file socket_listen socket_address tok prev_tok
    local reloaded=0 need_reload=0 all_match=1 has_v4=0 has_v6=0 bind_v6="default"
    local -a socket_streams managed_units=()

    command -v systemctl >/dev/null 2>&1 || return 0

    for unit in ssh.socket sshd.socket; do
        ssh_socket_unit_managed "$unit" || continue
        managed_units+=("$unit")
        dropin_file="${systemd_dir}/${unit}.d/zero-port.conf"
        if [[ -f "$dropin_file" ]]; then
            rm -f "$dropin_file"
            reloaded=0
        fi
    done
    (( ${#managed_units[@]} )) || return 0

    systemctl daemon-reload >/dev/null 2>&1 || return 1
    reloaded=1

    for unit in "${managed_units[@]}"; do
        socket_listen=$(systemctl show -p Listen --value "$unit" 2>/dev/null) || return 1
        socket_streams=()
        all_match=1
        has_v4=0
        has_v6=0
        prev_tok=""
        for tok in $socket_listen; do
            if [[ "$tok" == "(Stream)" && -n "$prev_tok" ]]; then
                socket_address="$prev_tok"
                if [[ "$socket_address" =~ ^([0-9.]+|\[[^]]+\]|\*):([0-9]+)(%[^[:space:]]+)?$ ]]; then
                    [[ "${BASH_REMATCH[2]}" == "$port" ]] || all_match=0
                    socket_address="${BASH_REMATCH[1]}:${port}${BASH_REMATCH[3]:-}"
                    [[ "${BASH_REMATCH[1]}" == \[* ]] && has_v6=1 || has_v4=1
                elif [[ "$socket_address" =~ ^[0-9]+$ ]]; then
                    [[ "$socket_address" == "$port" ]] || all_match=0
                    socket_address="$port"
                    has_v6=1
                else
                    all_match=0
                fi
                socket_streams+=("$socket_address")
            fi
            prev_tok="$tok"
        done
        (( ${#socket_streams[@]} )) || return 1
        (( all_match == 1 )) && continue

        (( has_v4 == 1 && has_v6 == 1 )) && bind_v6="ipv6-only" || bind_v6="default"
        dropin_dir="${systemd_dir}/${unit}.d"
        dropin_file="${dropin_dir}/zero-port.conf"
        mkdir -p "$dropin_dir" || return 1
        {
            printf '[Socket]\nListenStream=\nBindIPv6Only=%s\n' "$bind_v6"
            printf 'ListenStream=%s\n' "${socket_streams[@]}"
        } > "$dropin_file" || return 1
        need_reload=1
    done

    if (( need_reload == 1 || reloaded == 0 )); then
        systemctl daemon-reload >/dev/null 2>&1 || return 1
    fi

    systemctl stop sshd.service ssh.service >/dev/null 2>&1 || true
    for unit in "${managed_units[@]}"; do
        systemctl restart "$unit" >/dev/null 2>&1 || return 1
    done

    return 0
}

restart_sshd_safe() {
    local expected_port="${1:-}" i unit

    ssh_ensure_run_dir
    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}sshd 配置有误,未重启sshd请检查${SSHD_CONFIG}${PLAIN}"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if [[ -n "$expected_port" ]] && ! ssh_apply_socket_port "$expected_port"; then
            echo -e "${RED}ssh.socket 端口更新失败,请手动检查 systemd socket 配置${PLAIN}"
            return 1
        fi

        if ssh_socket_units_available; then
            if [[ -z "$expected_port" ]]; then
                systemctl daemon-reload >/dev/null 2>&1 || true
                systemctl stop sshd.service ssh.service >/dev/null 2>&1 || true
                for unit in ssh.socket sshd.socket; do
                    ssh_socket_unit_managed "$unit" || continue
                    systemctl restart "$unit" >/dev/null 2>&1 || {
                        echo -e "${RED}ssh.socket 重启失败,请手动检查服务状态${PLAIN}"
                        return 1
                    }
                done
            fi
        elif ! systemctl restart sshd 2>/dev/null && ! systemctl restart ssh 2>/dev/null; then
            echo -e "${RED}sshd 服务重启失败,请手动检查服务状态${PLAIN}"
            return 1
        fi
    elif command -v service >/dev/null 2>&1; then
        if ! service sshd restart >/dev/null 2>&1 && ! service ssh restart >/dev/null 2>&1; then
            echo -e "${RED}sshd 服务重启失败,请手动检查服务状态${PLAIN}"
            return 1
        fi
    else
        echo -e "${RED}未找到 systemctl/service,无法自动重启 sshd${PLAIN}"
        return 1
    fi

    if [[ -n "$expected_port" ]]; then
        for ((i = 0; i < 6; i++)); do
            zero_port_is_listening "$expected_port" tcp && return 0
            sleep 0.2
        done
        echo -e "${RED}sshd 未监听新的端口 ${expected_port},已停止本次修改${PLAIN}"
        return 1
    fi
    return 0
}

pkg_install() {
    command -v apt-get >/dev/null 2>&1 || return 1
    ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" )
}

zero_ensure_systemd_and_pkgs() {
    local svc_label="$1" spec pkg cmd
    shift
    local -a missing=()

    for spec in "$@"; do
        pkg="${spec%%:*}"
        cmd="${spec#*:}"
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
    done

    command -v systemctl >/dev/null 2>&1 || {
        echo -e "${RED}未检测到 systemctl,无法管理 ${svc_label} 服务${PLAIN}"
        return 1
    }
    [[ -d /run/systemd/system ]] || {
        echo -e "${RED}当前环境没有运行 systemd,无法管理 ${svc_label} 服务${PLAIN}"
        return 1
    }
    (( ${#missing[@]} == 0 )) && return 0

    echo -e "${YELLOW}正在安装 ${svc_label} 依赖: ${missing[*]}${PLAIN}"
    command -v apt-get >/dev/null 2>&1 || {
        echo -e "${RED}未找到 apt-get,无法安装 ${svc_label} 依赖${PLAIN}"
        return 1
    }
    ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" )
}

linux_update() {
    clear
    echo -e "${YELLOW}正在更新系统...${PLAIN}"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}未检测到可用的 apt-get!${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    if ! ( umask 022; apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y ); then
        echo -e "${RED}系统更新失败，请检查软件源或网络连接${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    echo -e "${GREEN}系统更新完成${PLAIN}"
    press_any_key_to_continue
}

linux_extract_kernel_version() {
    local package="${1%%:*}" version
    version="${package#linux-}"
    version="${version#*-}"
    version="${version#extra-}"
    version="${version#unsigned-}"
    if [[ "$package" == linux-headers-* ]]; then
        case "$version" in
            *-common-rt) version="${version%-common-rt}-rt" ;;
            *-common) version="${version%-common}" ;;
        esac
    fi
    printf '%s\n' "$version"
}

linux_filter_old_kernel_packages() {
    local current="${1:-$(uname -r 2>/dev/null)}" package version prot ref="" link_target
    local kind="" val="" dpkg_info_dir="${LINUX_DPKG_INFO_DIR:-/var/lib/dpkg/info}" proc1="${LINUX_PROC1_PATH:-/proc/1}"
    local highest_stock="" highest_xanmod=""
    local -a pkgs=() ii_images=() protected=("$current")

    mapfile -t pkgs
    (( ${#pkgs[@]} > 0 )) || return 0

    if command -v dpkg-query >/dev/null 2>&1; then
        while IFS='|' read -r kind val; do
            case "$kind" in
                IMG) ii_images+=("$val") ;;
                DEP) protected+=("$(linux_extract_kernel_version "$val")") ;;
            esac
        done < <(
            dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Depends}\t${Pre-Depends}\n' 'linux-*' 2>/dev/null |
                awk -F '\t' '
                    $1 ~ /^ii/ {
                        pkg = $2; sub(/:.*/, "", pkg)
                        if (pkg ~ /^linux-image(-unsigned)?-[0-9]/ && pkg !~ /-dbg$/) {
                            print "IMG|" pkg
                        } else if (pkg !~ /^linux-(image|headers|modules|kbuild|support|tools|source|doc|perf)(-extra|-unsigned)?-[0-9]/) {
                            all_deps = $3 "," $4
                            n = split(all_deps, arr, /[,| \t]+/)
                            for (i = 1; i <= n; i++) {
                                d = arr[i]; sub(/:.*/, "", d)
                                if (d ~ /^linux-(image|headers)(-unsigned)?-[0-9]/ && d !~ /-dbg$/) {
                                    print "DEP|" d
                                }
                            }
                        }
                    }
                '
        )
    fi

    if (( ${#ii_images[@]} == 0 )); then
        for package in "${pkgs[@]}"; do
            [[ "${package%%:*}" =~ ^linux-image(-unsigned)?-[0-9] && "$package" != *-dbg ]] && ii_images+=("$package")
        done
    fi

    for package in ${ii_images[@]+"${ii_images[@]}"}; do
        version=$(linux_extract_kernel_version "$package")
        [[ -n "$version" ]] || continue
        if [[ -e "$proc1" && -f "${dpkg_info_dir}/${package%%:*}.list" && "${dpkg_info_dir}/${package%%:*}.list" -nt "$proc1" ]]; then
            protected+=("$version")
        fi
        if [[ "$version" == *xanmod* ]]; then
            if [[ -z "$highest_xanmod" ]] || dpkg --compare-versions "${version}-0" gt "${highest_xanmod}-0"; then
                highest_xanmod="$version"
            fi
        else
            if [[ -z "$highest_stock" ]] || dpkg --compare-versions "${version}-0" gt "${highest_stock}-0"; then
                highest_stock="$version"
            fi
        fi
    done

    [[ -n "$highest_stock" ]] && protected+=("$highest_stock")
    [[ -n "$highest_xanmod" ]] && protected+=("$highest_xanmod")

    for link_target in /vmlinuz /vmlinuz.old /boot/vmlinuz /boot/vmlinuz.old; do
        [[ -L "$link_target" ]] || continue
        link_target=$(readlink "$link_target" 2>/dev/null || true)
        [[ "$link_target" == *vmlinuz-* ]] && protected+=("${link_target##*vmlinuz-}")
    done

    for package in "${pkgs[@]}"; do
        [[ -n "$package" ]] || continue
        version=$(linux_extract_kernel_version "$package")
        [[ -n "$version" ]] || continue

        local keep=0
        for prot in "${protected[@]}"; do
            [[ -n "$prot" ]] || continue
            if [[ "$prot" == "$version" || "$prot" == "$version"-* ]]; then
                keep=1
                break
            fi
        done
        (( keep == 1 )) && continue

        if [[ "$version" == *xanmod* ]]; then
            ref="$highest_xanmod"
            if [[ "$current" == *xanmod* ]] && { [[ -z "$ref" ]] || dpkg --compare-versions "${current}-0" gt "${ref}-0"; }; then
                ref="$current"
            fi
        else
            ref="$highest_stock"
            if [[ "$current" != *xanmod* ]] && { [[ -z "$ref" ]] || dpkg --compare-versions "${current}-0" gt "${ref}-0"; }; then
                ref="$current"
            fi
        fi

        if [[ -n "$ref" ]] && dpkg --compare-versions "${version}-0" lt "${ref}-0"; then
            printf '%s\n' "$package"
        fi
    done
}

linux_clean_logs_and_tmp() {
    local log_dir="${1:-/var/log}"
    shift || true
    local -a tmp_dirs=("$@")
    (( ${#tmp_dirs[@]} > 0 )) || tmp_dirs=(/tmp /var/tmp)
    local tmp_root entry base

    if [[ -d "$log_dir" ]]; then
        find "$log_dir" -type f -name '*.log' \( -mtime +1 -o -size +50M \) -exec sh -c 'for f do : > "$f"; done' _ {} + 2>/dev/null || true
        find "$log_dir" -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.bz2' -o -name '*.zst' -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9][0-9]' \) -mtime +1 -delete 2>/dev/null || true
    fi

    for tmp_root in "${tmp_dirs[@]}"; do
        [[ -d "$tmp_root" ]] || continue
        while IFS= read -r -d '' entry; do
            base="${entry##*/}"
            case "$base" in
                systemd-private-*|snap-private-tmp|snap.*|.X11-unix|.XIM-unix|.font-unix|.ICE-unix|.Test-unix|.X*-lock|.s.PGSQL.*|lost+found|tmux-*|ssh-*|screen-*)
                    continue
                    ;;
            esac
            [[ -S "$entry" || -p "$entry" ]] && continue
            if [[ -d "$entry" && ! -L "$entry" ]]; then
                find "$entry" \( -type s -o -type p -o -mmin -60 \) -print -quit 2>/dev/null | grep -q . && continue
            fi
            rm -rf -- "$entry" 2>/dev/null || true
        done < <(find "$tmp_root" -mindepth 1 -maxdepth 1 -mmin +60 -print0 2>/dev/null)
    done
}

linux_clean() {
    local current_kernel cache_dir
    local -a old_kernel_pkgs=()

    clear
    echo -e "${YELLOW}正在清理系统垃圾...${PLAIN}"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}未检测到可用的 apt-get!${PLAIN}"
    elif ! ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get autoremove -y && apt-get autoclean -y && apt-get clean ); then
        echo -e "${YELLOW}警告: apt 缓存清理部分失败${PLAIN}"
    fi

    echo -e "${YELLOW}正在清理旧内核...${PLAIN}"
    current_kernel=$(uname -r)
    echo -e "${BLUE}当前运行内核: ${GREEN}${current_kernel}${PLAIN}"

    if command -v dpkg-query >/dev/null 2>&1; then
        mapfile -t old_kernel_pkgs < <(
            dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' 2>/dev/null |
                awk '$1 ~ /^(ii|rc)/ && $2 ~ /^linux-(image|headers|modules)(-extra|-unsigned)?-[0-9]/ { print $2 }' |
                linux_filter_old_kernel_packages "$current_kernel"
        )
    fi

    if (( ${#old_kernel_pkgs[@]} > 0 )); then
        echo -e "${YELLOW}发现以下旧内核包:${PLAIN}"
        printf '  %s\n' "${old_kernel_pkgs[@]}"
        if ! ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get purge -y "${old_kernel_pkgs[@]}" >/dev/null 2>&1 ); then
            echo -e "${YELLOW}批量清理失败，尝试逐个清理...${PLAIN}"
            local pkg
            for pkg in "${old_kernel_pkgs[@]}"; do
                ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" >/dev/null 2>&1 ) ||
                    echo -e "  ${RED}警告: $pkg 清理失败${PLAIN}"
            done
        fi
    else
        echo -e "${GREEN}无旧内核需要清理${PLAIN}"
    fi

    if command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}清理Docker悬空镜像与构建缓存...${PLAIN}"
        docker image prune -f >/dev/null 2>&1 || true
        docker builder prune -f >/dev/null 2>&1 || true
    fi

    echo -e "${YELLOW}正在清理系统日志与临时目录...${PLAIN}"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=1d --vacuum-size=10M >/dev/null 2>&1 || true
    fi
    linux_clean_logs_and_tmp /var/log /tmp /var/tmp

    echo -e "${YELLOW}正在清理用户缓存...${PLAIN}"
    for cache_dir in "${ROOT_HOME}/.cache" /home/*/.cache; do
        [[ -d "$cache_dir" && ! -L "$cache_dir" ]] && find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    done

    echo -e "${GREEN}系统清理完成${PLAIN}"
    press_any_key_to_continue
}

swapfile_path="/swapfile"

REINSTALL_DNS_V4="${REINSTALL_DNS_V4:-8.8.8.8 1.1.1.1}"
REINSTALL_DNS_V6="${REINSTALL_DNS_V6:-2001:4860:4860::8888 2606:4700:4700::1111}"
REINSTALL_DNS_LIST="${REINSTALL_DNS_LIST:-8.8.8.8 1.1.1.1 2001:4860:4860::8888}"
REINSTALL_STACK_PREF="${REINSTALL_STACK_PREF:-auto}"

reinstall_is_efi() {
    [[ -d "${REINSTALL_EFI_DIR:-/sys/firmware/efi}" ]]
}

reinstall_check_sys() {
    reinstall_release=''
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) reinstall_release="$ID" ;;
        esac
    fi
}

reinstall_install_dependencies() {
    local -a missing_pkgs=()
    command -v openssl >/dev/null 2>&1 || missing_pkgs+=("openssl")
    command -v awk >/dev/null 2>&1 || missing_pkgs+=("gawk")
    if ! command -v wget >/dev/null 2>&1 ||
       wget --help 2>&1 | grep -qi 'busybox' ||
       wget --version 2>&1 | grep -qi 'busybox'; then
        missing_pkgs+=("wget")
    fi
    [[ -f "${REINSTALL_CA_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" ]] || missing_pkgs+=("ca-certificates")
    command -v cpio >/dev/null 2>&1 || missing_pkgs+=("cpio")
    command -v gzip >/dev/null 2>&1 || missing_pkgs+=("gzip")
    command -v ip >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v lsblk >/dev/null 2>&1 || missing_pkgs+=("util-linux")
    command -v findmnt >/dev/null 2>&1 || missing_pkgs+=("mount")
    command -v grub-editenv >/dev/null 2>&1 || missing_pkgs+=("grub-common")

    (( ${#missing_pkgs[@]} == 0 )) && return 0

    command -v apt-get >/dev/null 2>&1 || return 1
    (
        umask 022
        DEBIAN_FRONTEND=noninteractive apt-get update ||
            echo -e "${YELLOW}警告: apt-get update 存在部分源错误，尝试直接安装缺失依赖 (${missing_pkgs[*]})...${PLAIN}"
        DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing_pkgs[@]}"
    )
}

reinstall_require_commands() {
    local missing=0 cmd=''
    for cmd in "$@"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo -e "[${GREEN}ok${PLAIN}]\t${cmd}"
        else
            echo -e "[${RED}missing${PLAIN}]\t${cmd}"
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || {
        echo -e "${RED}缺少依赖，请先修复环境。${PLAIN}"
        exit 1
    }
}

reinstall_cidr_to_netmask() {
    local n="${1:-32}" mask_u=0
    if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 0 || n > 32 )); then
        n=32
    fi
    if (( n == 0 )); then
        mask_u=0
    else
        mask_u=$(( (0xffffffff << (32 - n)) & 0xffffffff ))
    fi
    printf '%d.%d.%d.%d\n' \
        $(( (mask_u >> 24) & 255 )) \
        $(( (mask_u >> 16) & 255 )) \
        $(( (mask_u >> 8) & 255 )) \
        $(( mask_u & 255 ))
}

reinstall_ipv4_to_uint() {
    local ip="${1:-}" o1='' o2='' o3='' o4='' extra=''
    IFS='.' read -r o1 o2 o3 o4 extra <<< "$ip"
    [[ -z "$extra" && "$o1" =~ ^[0-9]+$ && "$o2" =~ ^[0-9]+$ && "$o3" =~ ^[0-9]+$ && "$o4" =~ ^[0-9]+$ ]] || return 1
    (( 10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255 )) || return 1
    printf '%u\n' $(( ((10#$o1 << 24) | (10#$o2 << 16) | (10#$o3 << 8) | 10#$o4) & 0xffffffff ))
}

reinstall_is_public_ipv4() {
    local ip="${1%%/*}" o1='' o2='' o3='' o4='' extra=''
    IFS='.' read -r o1 o2 o3 o4 extra <<< "$ip"
    [[ -z "$extra" && "$o1" =~ ^[0-9]+$ && "$o2" =~ ^[0-9]+$ && "$o3" =~ ^[0-9]+$ && "$o4" =~ ^[0-9]+$ ]] || return 1
    o1=$((10#$o1)); o2=$((10#$o2)); o3=$((10#$o3)); o4=$((10#$o4))
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
    (( o1 == 0 || o1 == 10 || o1 == 127 || o1 >= 224 )) && return 1
    (( o1 == 169 && o2 == 254 )) && return 1
    (( o1 == 172 && o2 >= 16 && o2 <= 31 )) && return 1
    (( o1 == 192 && o2 == 168 )) && return 1
    (( o1 == 100 && o2 >= 64 && o2 <= 127 )) && return 1
    return 0
}

reinstall_ipv4_in_same_subnet() {
    local ip="${1:-}" prefix="${2:-}" gw="${3:-}"
    local ip_u='' gw_u='' mask_u=0
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 1 && prefix <= 31 )) || return 1
    ip_u=$(reinstall_ipv4_to_uint "$ip") || return 1
    gw_u=$(reinstall_ipv4_to_uint "$gw") || return 1
    mask_u=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    (( (ip_u & mask_u) == (gw_u & mask_u) ))
}

reinstall_ipv6_prefix_to_netmask() {
    local p="${1:-64}" rem=0 i=0 val=0 chunk='' out=''
    if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 0 || p > 128 )); then
        p=64
    fi
    rem=$p
    for ((i = 0; i < 8; i++)); do
        if (( rem >= 16 )); then
            val=65535
            rem=$((rem - 16))
        elif (( rem <= 0 )); then
            val=0
        else
            val=$(( (0xffff << (16 - rem)) & 0xffff ))
            rem=0
        fi
        chunk=$(printf '%x' "$val")
        out="${out:+${out}:}${chunk}"
    done
    printf '%s\n' "$out"
}

reinstall_expand_ipv6() {
    local ip="${1:-}" left='' right='' i=0 n_left=0 n_right=0 missing=0 part='' out=''
    local -a lparts=() rparts=() full=()
    ip="${ip%%%*}"
    [[ -n "$ip" && "$ip" == *:* ]] || return 1

    if [[ "$ip" == *::* ]]; then
        [[ "${ip#*::}" != *::* ]] || return 1
        left="${ip%%::*}"
        right="${ip#*::}"
        [[ -n "$left" ]] && IFS=':' read -r -a lparts <<< "$left"
        [[ -n "$right" ]] && IFS=':' read -r -a rparts <<< "$right"
        n_left=${#lparts[@]}
        n_right=${#rparts[@]}
        missing=$((8 - n_left - n_right))
        (( missing >= 1 )) || return 1
        (( n_left > 0 )) && full+=("${lparts[@]}")
        for ((i = 0; i < missing; i++)); do
            full+=("0")
        done
        (( n_right > 0 )) && full+=("${rparts[@]}")
    else
        IFS=':' read -r -a full <<< "$ip"
        (( ${#full[@]} == 8 )) || return 1
    fi

    (( ${#full[@]} == 8 )) || return 1
    for part in "${full[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        part=$(printf '%04x' "$((16#$part))")
        out="${out:+${out}:}${part}"
    done
    printf '%s\n' "$out"
}

reinstall_ipv6_in_same_subnet() {
    local ip="${1:-}" prefix="${2:-}" gw="${3:-}"
    local exp_ip='' exp_gw='' rem=0 i=0 mask=0 h1=0 h2=0
    local -a g_ip=() g_gw=()

    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 1 && prefix <= 127 )) || return 1
    gw="${gw%%%*}"
    case "$gw" in
        [Ff][Ee]80:*|'') return 1 ;;
    esac

    exp_ip=$(reinstall_expand_ipv6 "$ip") || return 1
    exp_gw=$(reinstall_expand_ipv6 "$gw") || return 1
    IFS=':' read -r -a g_ip <<< "$exp_ip"
    IFS=':' read -r -a g_gw <<< "$exp_gw"

    rem=$prefix
    for ((i = 0; i < 8; i++)); do
        (( rem <= 0 )) && break
        if (( rem >= 16 )); then
            mask=65535
            rem=$((rem - 16))
        else
            mask=$(( (0xffff << (16 - rem)) & 0xffff ))
            rem=0
        fi
        h1=$((16#${g_ip[$i]}))
        h2=$((16#${g_gw[$i]}))
        (( (h1 & mask) == (h2 & mask) )) || return 1
    done
    return 0
}

reinstall_is_candidate_nic() {
    local iface="${1:-}" sys_net="${REINSTALL_SYS_NET_DIR:-/sys/class/net}" nic_type=''
    iface="${iface%%@*}"
    [[ -n "$iface" && "$iface" != "lo" ]] || return 1
    case "$iface" in
        docker*|br-*|veth*|virbr*|vnet*|fwbr*|fwpr*|fwln*|cni*|flannel*|cali*|cilium*|weave*|kube-*|tun*|tap*|wg*|warp*|CloudflareWARP*|tailscale*|zt*|sit*|gre*|ip6tnl*|erspan*|dummy*|ifb*|lxcbr*|lxdbr*|podman*|incusbr*|macvtap*|ipvtap*|venet*)
            return 1
            ;;
    esac
    [[ -e "${sys_net}/${iface}/master" ]] && return 1
    if [[ -r "${sys_net}/${iface}/type" ]]; then
        nic_type=$(cat "${sys_net}/${iface}/type" 2>/dev/null || true)
        [[ "$nic_type" == "1" ]] || return 1
    fi
    return 0
}

reinstall_get_default_routes() {
    local family="$1" dev="${2:-}" out=''
    if [[ -n "$dev" ]]; then
        out=$(ip "$family" route show default dev "$dev" 2>/dev/null | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)([[:space:]]|$)' || true)
        if [[ -z "$out" ]]; then
            out=$(ip "$family" route show table all default dev "$dev" 2>/dev/null | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)([[:space:]]|$)' || true)
        fi
    else
        out=$(
            {
                ip "$family" route show default 2>/dev/null
                ip "$family" route show table all default 2>/dev/null
            } | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)([[:space:]]|$)' || true
        )
    fi
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

reinstall_get_iface_mac() {
    local iface="${1:-}" sys_net="${REINSTALL_SYS_NET_DIR:-/sys/class/net}" mac=''
    [[ -n "$iface" ]] || return 1
    if [[ -r "${sys_net}/${iface}/address" ]]; then
        mac=$(tr '[:upper:]' '[:lower:]' < "${sys_net}/${iface}/address" 2>/dev/null || true)
    fi
    if [[ -z "$mac" ]]; then
        mac=$(ip -o link show dev "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "link/ether") {print tolower($(i + 1)); exit}}')
    fi
    if [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ && "$mac" != "00:00:00:00:00:00" ]]; then
        printf '%s\n' "$mac"
        return 0
    fi
    return 1
}

reinstall_find_family_iface() {
    local family="$1" cand='' fallback_routed='' pick_fn='reinstall_pick_ipv4_line'
    [[ "$family" == "-6" ]] && pick_fn='reinstall_pick_ipv6_line'

    while IFS= read -r cand; do
        cand="${cand%%@*}"
        reinstall_is_candidate_nic "$cand" || continue
        [[ -z "$fallback_routed" ]] && fallback_routed="$cand"
        if "$pick_fn" "$cand" >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            return 0
        fi
    done < <(reinstall_get_default_routes "$family" | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}')

    while IFS= read -r cand; do
        cand="${cand%%@*}"
        reinstall_is_candidate_nic "$cand" && "$pick_fn" "$cand" >/dev/null 2>&1 || continue
        printf '%s\n' "$cand"
        return 0
    done < <(ip "$family" -o addr show scope global 2>/dev/null | awk '{print $2}')

    if [[ -n "$fallback_routed" ]]; then
        printf '%s\n' "$fallback_routed"
        return 0
    fi

    while IFS= read -r cand; do
        cand="${cand%%@*}"
        if reinstall_is_candidate_nic "$cand"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}')
    return 1
}

reinstall_get_target_disk() {
    local root_source='' cur='' parent='' disk_by_dep='' disks=''
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null | head -n1)
    root_source="${root_source%%\[*}"
    if [[ -n "$root_source" && -e "$root_source" ]] && command -v readlink >/dev/null 2>&1; then
        root_source=$(readlink -f "$root_source" 2>/dev/null || printf '%s' "$root_source")
    fi
    if [[ -n "$root_source" ]]; then
        disk_by_dep=$(
            { lsblk -nls -o NAME,TYPE "$root_source" 2>/dev/null || lsblk -ns -o NAME,TYPE "$root_source" 2>/dev/null; } |
                awk '$2 == "disk" {print $1; exit}' |
                sed 's/^[^[:alnum:]\/]*//'
        )
        if [[ -n "$disk_by_dep" ]]; then
            [[ "$disk_by_dep" == /dev/* ]] && echo "$disk_by_dep" || echo "/dev/$disk_by_dep"
            return
        fi
        cur="$root_source"
        local depth=0
        while (( depth < 8 )); do
            parent=$(lsblk -ndo PKNAME "$cur" 2>/dev/null | tail -n1 | sed 's/^[^[:alnum:]\/]*//')
            [[ -n "$parent" ]] || break
            [[ "$parent" == /dev/* ]] && cur="$parent" || cur="/dev/$parent"
            depth=$((depth + 1))
        done
        if [[ "$cur" != "$root_source" && -n "$cur" ]]; then
            echo "$cur"
            return
        fi
    fi
    disks=$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2 == "disk" && $1 !~ /^(fd|sr|loop|ram|zram)[0-9]*/ {print $1; exit}' | sed 's/^[^[:alnum:]\/]*//')
    if [[ -z "$disks" ]]; then
        disks=$(lsblk 2>/dev/null | sed 's/[[:space:]]*$//g' | grep "disk$" | cut -d' ' -f1 | sed 's/^[^[:alnum:]\/]*//' | grep -v "fd[0-9]*\|sr[0-9]*" | head -n1)
    fi
    if [[ "$disks" == /dev/* ]]; then
        echo "$disks"
    elif [[ -n "$disks" ]]; then
        echo "/dev/$disks"
    fi
}

reinstall_get_grub() {
    local boot_dir="${1:-/boot}" folder='' file_name='' cfg_path='' ver=0 fallback=''
    while IFS= read -r cfg_path; do
        [[ -f "$cfg_path" ]] || continue
        folder="${cfg_path%/*}"
        file_name="${cfg_path##*/}"
        ver=0
        [[ "$file_name" == grub.conf ]] && ver=1
        if grep -q '^[[:space:]]*menuentry[[:space:]]' "$cfg_path" 2>/dev/null; then
            printf '%s:%s:%s\n' "$folder" "$file_name" "$ver"
            return 0
        fi
        [[ -z "$fallback" ]] && fallback="${folder}:${file_name}:${ver}"
    done < <(
        printf '%s\n' \
            "${boot_dir}/grub/grub.cfg" "${boot_dir}/grub/grub.conf" \
            "${boot_dir}/grub2/grub.cfg" "${boot_dir}/grub2/grub.conf"
        find "$boot_dir" -type f \( -name 'grub.cfg' -o -name 'grub.conf' \) 2>/dev/null
    )
    [[ -n "$fallback" ]] && printf '%s\n' "$fallback"
}

reinstall_low_mem() {
    local mem=''
    mem=$(grep "^MemTotal:" /proc/meminfo 2>/dev/null | grep -o "[0-9]*")
    [[ -n "$mem" ]] || return 0
    (( mem >= 360000 && mem <= 1048576 )) && return 1 || return 0
}

reinstall_validate_kernel_image() {
    local kfile="$1" arch="$2" fsize=0
    [[ -f "$kfile" ]] || return 1
    fsize=$(wc -c < "$kfile" 2>/dev/null | tr -d '[:space:]')
    [[ "$fsize" =~ ^[0-9]+$ ]] && (( fsize >= 524288 )) || return 1

    od -An -tx1 -v -N 518 "$kfile" 2>/dev/null | awk -v arch="$arch" '
        {
            for (i = 1; i <= NF; i++) b[++n] = tolower($i)
        }
        END {
            if (n < 518) exit 1
            m0 = b[1] b[2]
            mz = b[5] b[6] b[7] b[8]
            ma = b[57] b[58] b[59] b[60]
            mh = b[515] b[516] b[517] b[518]
            if (arch == "amd64") {
                exit((ma != "41524d64" && mz != "7a696d67" && (mh == "48647253" || m0 == "4d5a")) ? 0 : 1)
            }
            if (arch == "arm64") {
                exit((mh != "48647253" && (ma == "41524d64" || mz == "7a696d67" || m0 == "4d5a" || m0 == "1f8b")) ? 0 : 1)
            }
            exit 1
        }
    '
}

reinstall_validate_grub_config() {
    local grub_file="$1" open_count='' close_count='' log_file="${REINSTALL_TMP_ROOT:-/tmp}/grub-script-check.log"
    if command -v grub-script-check >/dev/null 2>&1; then
        grub-script-check "$grub_file" >"$log_file" 2>&1
        return $?
    elif command -v grub2-script-check >/dev/null 2>&1; then
        grub2-script-check "$grub_file" >"$log_file" 2>&1
        return $?
    fi
    open_count=$(grep -o '{' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
    close_count=$(grep -o '}' "$grub_file" 2>/dev/null | wc -l | tr -d ' ')
    if grep -q 'menuentry ' "$grub_file" && [[ "$open_count" == "$close_count" ]]; then
        : >"$log_file"
        return 0
    fi
    return 1
}

reinstall_hash_password() {
    local pw="$1"
    printf '%s\n' "$pw" | openssl passwd -6 -stdin 2>/dev/null ||
        printf '%s\n' "$pw" | openssl passwd -1 -stdin 2>/dev/null
}

reinstall_select_debian_mirror() {
    local dist="$1" arch="$2" stack_mode="$3"
    local current='' url='' fam=''
    local -a families=() mirrors=(
        "https://deb.debian.org/debian"
        "https://ftp.debian.org/debian"
        "https://archive.debian.org/debian"
        "http://deb.debian.org/debian"
        "http://ftp.debian.org/debian"
        "http://archive.debian.org/debian"
    )

    case "$stack_mode" in
        ipv4) families=("-4") ;;
        ipv6) families=("-6") ;;
        dual) families=("-4" "-6") ;;
        *) return 1 ;;
    esac

    for fam in "${families[@]}"; do
        for current in "${mirrors[@]}"; do
            url="${current}/dists/${dist}/main/installer-${arch}/current/images/netboot/debian-installer/${arch}/initrd.gz"
            if wget "$fam" --spider -q --timeout=4 --tries=1 "$url" >/dev/null 2>&1; then
                if [[ "$fam" == "-4" ]]; then
                    printf 'ipv4|%s\n' "$current"
                else
                    printf 'ipv6|%s\n' "$current"
                fi
                return 0
            fi
        done
    done
    return 1
}

reinstall_is_global_unicast_ipv6() {
    local addr="${1:-}" exp=''
    addr="${addr%%/*}"
    addr="${addr%%%*}"
    exp=$(reinstall_expand_ipv6 "$addr") || return 1
    case "$exp" in
        0000:0000:0000:0000:0000:0000:0000:0000|\
        0000:0000:0000:0000:0000:0000:0000:0001|\
        0064:ff9b:*|\
        fe[89ab]?:*|\
        fc??:*|fd??:*|\
        ff??:*)
            return 1
            ;;
    esac
    return 0
}

reinstall_pick_ipv4_line() {
    local iface="$1" line='' addr_tok='' addr_ip='' v4_src='' fallback_line=''
    local -a addr_lines=()
    [[ -n "$iface" ]] || return 1

    mapfile -t addr_lines < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null)
    (( ${#addr_lines[@]} > 0 )) || return 1

    v4_src=$(
        reinstall_get_default_routes -4 "$iface" |
            awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
    )
    if [[ -z "$v4_src" ]]; then
        v4_src=$(ip -4 route get 1.1.1.1 oif "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    fi

    if [[ -n "$v4_src" && ! "$v4_src" =~ ^(0\.|127\.|169\.254\.) ]] && reinstall_ipv4_to_uint "$v4_src" >/dev/null 2>&1; then
        for line in "${addr_lines[@]}"; do
            [[ "$line" =~ (^|[[:space:]])inet[[:space:]]+([^[:space:]]+) ]] || continue
            addr_tok="${BASH_REMATCH[2]}"
            addr_ip="${addr_tok%%/*}"
            if [[ "$addr_ip" == "$v4_src" ]]; then
                printf '%s\n' "$line"
                return 0
            fi
        done
    fi

    for line in "${addr_lines[@]}"; do
        [[ "$line" =~ (^|[[:space:]])inet[[:space:]]+([^[:space:]]+) ]] || continue
        addr_tok="${BASH_REMATCH[2]}"
        addr_ip="${addr_tok%%/*}"
        case "$addr_ip" in
            0.*|127.*|169.254.*|'') continue ;;
        esac
        reinstall_ipv4_to_uint "$addr_ip" >/dev/null 2>&1 || continue
        if reinstall_is_public_ipv4 "$addr_ip"; then
            printf '%s\n' "$line"
            return 0
        fi
        [[ -z "$fallback_line" ]] && fallback_line="$line"
    done

    if [[ -n "$fallback_line" ]]; then
        printf '%s\n' "$fallback_line"
        return 0
    fi
    return 1
}

reinstall_pick_ipv6_line() {
    local iface="$1" line='' addr_tok='' ip6_src='' src_exp='' tok_exp=''
    local -a addr_lines=()
    [[ -n "$iface" ]] || return 1

    mapfile -t addr_lines < <(ip -6 -o addr show dev "$iface" scope global 2>/dev/null)
    (( ${#addr_lines[@]} > 0 )) || return 1

    ip6_src=$(
        reinstall_get_default_routes -6 "$iface" |
            awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
    )
    if [[ -z "$ip6_src" ]]; then
        ip6_src=$(ip -6 route get 2001:4860:4860::8888 oif "$iface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    fi
    if reinstall_is_global_unicast_ipv6 "$ip6_src"; then
        src_exp=$(reinstall_expand_ipv6 "$ip6_src" || true)
        for line in "${addr_lines[@]}"; do
            [[ "$line" =~ (^|[[:space:]])(temporary|deprecated|tentative)([[:space:]]|$) ]] && continue
            [[ "$line" =~ (^|[[:space:]])inet6[[:space:]]+([^[:space:]]+) ]] || continue
            addr_tok="${BASH_REMATCH[2]}"
            tok_exp=$(reinstall_expand_ipv6 "${addr_tok%%/*}" || true)
            if [[ -n "$src_exp" && "$tok_exp" == "$src_exp" ]]; then
                printf '%s\n' "$line"
                return 0
            fi
        done
    fi

    for line in "${addr_lines[@]}"; do
        [[ "$line" =~ (^|[[:space:]])(temporary|deprecated|tentative)([[:space:]]|$) ]] && continue
        [[ "$line" =~ (^|[[:space:]])inet6[[:space:]]+([^[:space:]]+) ]] || continue
        addr_tok="${BASH_REMATCH[2]}"
        if reinstall_is_global_unicast_ipv6 "$addr_tok"; then
            printf '%s\n' "$line"
            return 0
        fi
    done

    return 1
}

reinstall_reset_v4_state() {
    REINSTALL_HAS_IPV4=0
    REINSTALL_IPV4_IFACE=''
    REINSTALL_IPV4_MAC=''
    REINSTALL_IPV4_MODE='none'
    REINSTALL_IPV4_ADDR=''
    REINSTALL_IPV4_PREFIX=''
    REINSTALL_IPV4_MASK=''
    REINSTALL_IPV4_GATE=''
}

reinstall_reset_v6_state() {
    REINSTALL_HAS_IPV6=0
    REINSTALL_IPV6_IFACE=''
    REINSTALL_IPV6_MAC=''
    REINSTALL_IPV6_MODE='none'
    REINSTALL_IPV6_ADDR=''
    REINSTALL_IPV6_PREFIX=''
    REINSTALL_IPV6_GATE=''
}

reinstall_probe_network_state() {
    local v4_line='' v4_tok='' v4_peer_tok='' v4_route=''
    local ip6_line='' v6_tok='' v6_peer_tok='' ip6_route='' cand='' v4_has_v6_main_route=''

    reinstall_reset_v4_state
    reinstall_reset_v6_state
    REINSTALL_NETWORK_INTERFACE=''

    REINSTALL_IPV4_IFACE=$(reinstall_find_family_iface -4 || true)
    if [[ -n "$REINSTALL_IPV4_IFACE" ]] && v4_line=$(reinstall_pick_ipv4_line "$REINSTALL_IPV4_IFACE"); then
        REINSTALL_IPV4_MAC=$(reinstall_get_iface_mac "$REINSTALL_IPV4_IFACE" || true)
        [[ "$v4_line" =~ (^|[[:space:]])inet[[:space:]]+([^[:space:]]+) ]] && v4_tok="${BASH_REMATCH[2]}"
        [[ "$v4_line" =~ (^|[[:space:]])peer[[:space:]]+([^[:space:]]+) ]] && v4_peer_tok="${BASH_REMATCH[2]}"
        if [[ "$v4_tok" == */* ]]; then
            REINSTALL_IPV4_ADDR="${v4_tok%/*}"
            REINSTALL_IPV4_PREFIX="${v4_tok#*/}"
        elif [[ "$v4_peer_tok" == */* ]]; then
            REINSTALL_IPV4_ADDR="$v4_tok"
            REINSTALL_IPV4_PREFIX="${v4_peer_tok#*/}"
        else
            REINSTALL_IPV4_ADDR="$v4_tok"
            REINSTALL_IPV4_PREFIX='32'
        fi

        if [[ -n "$REINSTALL_IPV4_ADDR" ]] && reinstall_ipv4_to_uint "$REINSTALL_IPV4_ADDR" >/dev/null 2>&1; then
            REINSTALL_IPV4_MASK=$(reinstall_cidr_to_netmask "$REINSTALL_IPV4_PREFIX")
            v4_route=$(reinstall_get_default_routes -4 "$REINSTALL_IPV4_IFACE" || true)
            if [[ -n "$v4_route" ]]; then
                [[ "$v4_route" =~ (^|[[:space:]])via[[:space:]]+([^[:space:]]+) ]] && REINSTALL_IPV4_GATE="${BASH_REMATCH[2]}"
                [[ -z "$REINSTALL_IPV4_GATE" && -n "$v4_peer_tok" ]] && REINSTALL_IPV4_GATE="${v4_peer_tok%%/*}"
                if [[ -n "$REINSTALL_IPV4_GATE" ]] && ! reinstall_ipv4_to_uint "$REINSTALL_IPV4_GATE" >/dev/null 2>&1; then
                    REINSTALL_IPV4_GATE=''
                fi
                if [[ "$v4_line" =~ (^|[[:space:]])dynamic([[:space:]]|$) || "$v4_route" =~ (^|[[:space:]])proto[[:space:]]+dhcp([[:space:]]|$) || -z "$REINSTALL_IPV4_GATE" ]]; then
                    REINSTALL_IPV4_MODE='dhcp'
                else
                    REINSTALL_IPV4_MODE='static'
                fi
                REINSTALL_HAS_IPV4=1
            fi
        fi
    fi
    (( REINSTALL_HAS_IPV4 == 0 )) && reinstall_reset_v4_state

    if (( REINSTALL_HAS_IPV4 == 1 )) && [[ -n "$REINSTALL_IPV4_IFACE" ]]; then
        v4_has_v6_main_route=$(ip -6 route show default dev "$REINSTALL_IPV4_IFACE" 2>/dev/null | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)([[:space:]]|$)' || true)
    fi
    if [[ -n "$v4_has_v6_main_route" ]] && ip6_line=$(reinstall_pick_ipv6_line "$REINSTALL_IPV4_IFACE"); then
        REINSTALL_IPV6_IFACE="$REINSTALL_IPV4_IFACE"
    else
        cand=$(reinstall_find_family_iface -6 || true)
        [[ -n "$cand" ]] && ip6_line=$(reinstall_pick_ipv6_line "$cand") && REINSTALL_IPV6_IFACE="$cand"
    fi

    if [[ -n "$REINSTALL_IPV6_IFACE" && -n "$ip6_line" ]]; then
        REINSTALL_IPV6_MAC=$(reinstall_get_iface_mac "$REINSTALL_IPV6_IFACE" || true)
        [[ "$ip6_line" =~ (^|[[:space:]])inet6[[:space:]]+([^[:space:]]+) ]] && v6_tok="${BASH_REMATCH[2]}"
        [[ "$ip6_line" =~ (^|[[:space:]])peer[[:space:]]+([^[:space:]]+) ]] && v6_peer_tok="${BASH_REMATCH[2]}"
        if [[ "$v6_tok" == */* ]]; then
            REINSTALL_IPV6_ADDR="${v6_tok%/*}"
            REINSTALL_IPV6_PREFIX="${v6_tok#*/}"
        elif [[ -n "$v6_peer_tok" ]]; then
            REINSTALL_IPV6_ADDR="$v6_tok"
            [[ "$v6_peer_tok" == */* ]] && REINSTALL_IPV6_PREFIX="${v6_peer_tok#*/}" || REINSTALL_IPV6_PREFIX='128'
        else
            REINSTALL_IPV6_ADDR="$v6_tok"
            REINSTALL_IPV6_PREFIX='64'
        fi
        REINSTALL_IPV6_ADDR="${REINSTALL_IPV6_ADDR%%%*}"
        [[ "$REINSTALL_IPV6_PREFIX" =~ ^[0-9]+$ ]] || REINSTALL_IPV6_PREFIX='64'

        ip6_route=$(reinstall_get_default_routes -6 "$REINSTALL_IPV6_IFACE" || true)
        if [[ -n "$ip6_route" ]]; then
            [[ "$ip6_route" =~ (^|[[:space:]])via[[:space:]]+([^[:space:]]+) ]] && REINSTALL_IPV6_GATE="${BASH_REMATCH[2]}"
            [[ -z "$REINSTALL_IPV6_GATE" && -n "$v6_peer_tok" ]] && REINSTALL_IPV6_GATE="${v6_peer_tok%%/*}"
            REINSTALL_IPV6_GATE="${REINSTALL_IPV6_GATE%%%*}"

            if [[ "$ip6_line" =~ mngtmpaddr|proto[[:space:]]+kernel_ra ]]; then
                REINSTALL_IPV6_MODE='slaac'
            elif [[ "$ip6_line" =~ (^|[[:space:]])dynamic([[:space:]]|$)|proto[[:space:]]+dhcp ]]; then
                [[ "$REINSTALL_IPV6_PREFIX" == "128" || "$ip6_line" =~ proto[[:space:]]+dhcp ]] && REINSTALL_IPV6_MODE='dhcp6' || REINSTALL_IPV6_MODE='slaac'
            else
                REINSTALL_IPV6_MODE='static'
            fi
            reinstall_expand_ipv6 "$REINSTALL_IPV6_ADDR" >/dev/null 2>&1 && REINSTALL_HAS_IPV6=1
        fi
    fi
    (( REINSTALL_HAS_IPV6 == 0 )) && reinstall_reset_v6_state

    if [[ -n "$REINSTALL_IPV4_IFACE" && "$REINSTALL_HAS_IPV4" -eq 1 ]]; then
        REINSTALL_NETWORK_INTERFACE="$REINSTALL_IPV4_IFACE"
    elif [[ -n "$REINSTALL_IPV6_IFACE" && "$REINSTALL_HAS_IPV6" -eq 1 ]]; then
        REINSTALL_NETWORK_INTERFACE="$REINSTALL_IPV6_IFACE"
    else
        REINSTALL_NETWORK_INTERFACE=$(reinstall_find_family_iface -4 || reinstall_find_family_iface -6 || get_default_interface || true)
    fi
}

reinstall_resolve_stack_mode() {
    local pref="${1:-${REINSTALL_STACK_PREF:-auto}}"
    REINSTALL_EFFECTIVE_STACK=''
    REINSTALL_STACK_ERROR=''

    case "$pref" in
        auto)
            if (( REINSTALL_HAS_IPV4 == 1 && REINSTALL_HAS_IPV6 == 1 )); then
                REINSTALL_EFFECTIVE_STACK='dual'
            elif (( REINSTALL_HAS_IPV4 == 1 )); then
                REINSTALL_EFFECTIVE_STACK='ipv4'
            elif (( REINSTALL_HAS_IPV6 == 1 )); then
                REINSTALL_EFFECTIVE_STACK='ipv6'
            else
                REINSTALL_STACK_ERROR='未检测到可用的公网 IPv4 或 IPv6 网络配置，无法执行重装。'
                return 1
            fi
            ;;
        dual)
            if (( REINSTALL_HAS_IPV4 != 1 )); then
                REINSTALL_STACK_ERROR='当前主机未检测到完整的公网 IPv4 配置，无法使用「双栈」模式重装。'
                return 1
            fi
            if (( REINSTALL_HAS_IPV6 != 1 )); then
                REINSTALL_STACK_ERROR='当前主机未检测到完整的公网 IPv6 配置，无法使用「双栈」模式重装。'
                return 1
            fi
            REINSTALL_EFFECTIVE_STACK='dual'
            ;;
        ipv4)
            if (( REINSTALL_HAS_IPV4 != 1 )); then
                REINSTALL_STACK_ERROR='当前主机未检测到完整的公网 IPv4 配置，无法使用「仅 IPv4」模式重装。'
                return 1
            fi
            REINSTALL_EFFECTIVE_STACK='ipv4'
            ;;
        ipv6)
            if (( REINSTALL_HAS_IPV6 != 1 )); then
                REINSTALL_STACK_ERROR='当前主机未检测到完整的公网 IPv6 配置，无法使用「仅 IPv6」模式重装。'
                return 1
            fi
            REINSTALL_EFFECTIVE_STACK='ipv6'
            ;;
        *)
            REINSTALL_STACK_ERROR="未知的网络栈模式: ${pref}"
            return 1
            ;;
    esac
    return 0
}

reinstall_stack_label() {
    case "${1:-}" in
        dual) echo "双栈 (IPv4 + IPv6)" ;;
        ipv4) echo "仅 IPv4" ;;
        ipv6) echo "仅 IPv6" ;;
        auto) echo "自动识别" ;;
        *)    echo "未知" ;;
    esac
}

reinstall_gather_network_state() {
    reinstall_probe_network_state
    [[ -n "$REINSTALL_NETWORK_INTERFACE" ]] || {
        echo -e "${RED}未检测到默认网卡。${PLAIN}"
        exit 1
    }
    if ! reinstall_resolve_stack_mode "${REINSTALL_STACK_PREF:-auto}"; then
        echo -e "${RED}${REINSTALL_STACK_ERROR}${PLAIN}"
        exit 1
    fi
}

reinstall_target_dns_list() {
    case "${1:-$REINSTALL_EFFECTIVE_STACK}" in
        ipv4) echo "$REINSTALL_DNS_V4" ;;
        ipv6) echo "$REINSTALL_DNS_V6" ;;
        dual) echo "$REINSTALL_DNS_LIST" ;;
        *)    echo "$REINSTALL_DNS_LIST" ;;
    esac
}

reinstall_build_ipv4_stanza() {
    local dns_line="$1" mask="$REINSTALL_IPV4_MASK" route_lines=''
    case "$REINSTALL_IPV4_MODE" in
        dhcp)
            cat <<'EOF'
cat >> /etc/network/interfaces <<EOF_IPV4

auto $iface4
iface $iface4 inet dhcp
EOF_IPV4
EOF
            ;;
        static)
            if reinstall_ipv4_in_same_subnet "$REINSTALL_IPV4_ADDR" "$REINSTALL_IPV4_PREFIX" "$REINSTALL_IPV4_GATE"; then
                route_lines="    gateway ${REINSTALL_IPV4_GATE}"
            elif [[ "$REINSTALL_IPV4_PREFIX" == "32" ]]; then
                mask="255.255.255.255"
                route_lines="    pointopoint ${REINSTALL_IPV4_GATE}
    gateway ${REINSTALL_IPV4_GATE}"
            else
                route_lines="    post-up ip -4 route replace ${REINSTALL_IPV4_GATE} dev \\\$IFACE
    post-up ip -4 route replace default via ${REINSTALL_IPV4_GATE} dev \\\$IFACE onlink"
            fi
            cat <<EOF
cat >> /etc/network/interfaces <<EOF_IPV4

auto \$iface4
iface \$iface4 inet static
    address ${REINSTALL_IPV4_ADDR}
    netmask ${mask}
${route_lines}
    dns-nameservers ${dns_line}
EOF_IPV4
EOF
            ;;
    esac
}

reinstall_build_ipv6_stanza() {
    local include_auto="$1" dns_line="$2" auto_header='' gw_lines=''
    [[ "$include_auto" == "1" ]] && auto_header=$'auto $iface6\n'
    case "$REINSTALL_IPV6_MODE" in
        slaac)
            cat <<EOF
cat >> /etc/network/interfaces <<EOF_IPV6

${auto_header}iface \$iface6 inet6 auto
    accept_ra 2
    dns-nameservers ${dns_line}
EOF_IPV6
EOF
            ;;
        dhcp6)
            cat <<EOF
cat >> /etc/network/interfaces <<EOF_IPV6

${auto_header}iface \$iface6 inet6 dhcp
    accept_ra 2
    pre-up echo 2 > /proc/sys/net/ipv6/conf/\\\$IFACE/accept_ra 2>/dev/null || true
    pre-up ip link set dev \\\$IFACE up 2>/dev/null || true
    pre-up for i in 1 2 3 4 5 6; do ip -6 addr show dev \\\$IFACE scope link 2>/dev/null | grep -q 'inet6 ' && ! ip -6 addr show dev \\\$IFACE scope link 2>/dev/null | grep -q 'tentative' && break; sleep 1; done
    dns-nameservers ${dns_line}
EOF_IPV6
EOF
            ;;
        static)
            if [[ -z "$REINSTALL_IPV6_GATE" ]]; then
                gw_lines='    accept_ra 2'
            elif [[ "$REINSTALL_IPV6_GATE" == [Ff][Ee]80:* ]] ||
                 reinstall_ipv6_in_same_subnet "$REINSTALL_IPV6_ADDR" "$REINSTALL_IPV6_PREFIX" "$REINSTALL_IPV6_GATE"; then
                gw_lines="    gateway ${REINSTALL_IPV6_GATE}
    accept_ra 2"
            else
                gw_lines="    accept_ra 2
    post-up ip -6 route replace ${REINSTALL_IPV6_GATE} dev \\\$IFACE
    post-up ip -6 route replace default via ${REINSTALL_IPV6_GATE} dev \\\$IFACE onlink"
            fi
            cat <<EOF
cat >> /etc/network/interfaces <<EOF_IPV6

${auto_header}iface \$iface6 inet6 static
    address ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX}
${gw_lines}
    dns-nameservers ${dns_line}
EOF_IPV6
EOF
            ;;
    esac
}

reinstall_write_netcfg_hook() {
    local boot_work_dir="$1" orig_postinst="$2"
    local installer_mac='' installer_iface=''

    [[ -s "$orig_postinst" ]] || return 1
    mkdir -p "$boot_work_dir" || return 1

    if [[ "$REINSTALL_INSTALLER_FAMILY" == "ipv6" ]]; then
        installer_mac="$REINSTALL_IPV6_MAC"
        installer_iface="$REINSTALL_IPV6_IFACE"
    else
        installer_mac="$REINSTALL_IPV4_MAC"
        installer_iface="$REINSTALL_IPV4_IFACE"
    fi

    cat > "${boot_work_dir}/fix-netcfg-route.sh" <<EOF || return 1
#!/bin/sh
exec </dev/null >/dev/null 2>&1 3>&- || exec </dev/null >/dev/null 2>&1
INSTALLER_MAC='${installer_mac}'
INSTALLER_IFACE='${installer_iface}'
INSTALLER_FAMILY='${REINSTALL_INSTALLER_FAMILY}'
EFFECTIVE_STACK='${REINSTALL_EFFECTIVE_STACK:-}'
IPV4_ADDR='${REINSTALL_IPV4_ADDR}'
IPV4_PREFIX='${REINSTALL_IPV4_PREFIX}'
IPV4_GATE='${REINSTALL_IPV4_GATE}'
IPV6_ADDR='${REINSTALL_IPV6_ADDR}'
IPV6_PREFIX='${REINSTALL_IPV6_PREFIX}'
IPV6_GATE='${REINSTALL_IPV6_GATE}'
DNS_V4='${REINSTALL_DNS_V4}'
DNS_V6='${REINSTALL_DNS_V6}'
EOF
    cat >> "${boot_work_dir}/fix-netcfg-route.sh" <<'EOF' || return 1

SYS_NET="${ZERO_SYS_NET_DIR:-/sys/class/net}"
PROC_ROOT="${ZERO_PROC_DIR:-/proc}"
IPV6_CONF_DIR="${PROC_ROOT}/sys/net/ipv6/conf"
RESOLV_CONF="${ZERO_RESOLV_CONF:-/etc/resolv.conf}"
tab_ch=$(printf '\t')
cr_ch=$(printf '\r')
ws=" ${tab_ch}${cr_ch}"

resolve_iface() {
    target_mac="$1"
    fallback_iface="$2"
    if [ -n "$target_mac" ]; then
        tmac=$(printf '%s' "$target_mac" | tr '[:upper:]' '[:lower:]')
        for p in "${SYS_NET}"/*/address; do
            [ -r "$p" ] || continue
            dev="${p#"${SYS_NET}/"}"
            dev="${dev%/address}"
            [ "$dev" = "lo" ] || [ -e "${SYS_NET}/${dev}/master" ] && continue
            if [ -r "${SYS_NET}/${dev}/type" ]; then
                ntype=$(cat "${SYS_NET}/${dev}/type" 2>/dev/null || true)
                [ "$ntype" = "1" ] || continue
            fi
            amac=$(tr '[:upper:]' '[:lower:]' < "$p" 2>/dev/null || true)
            if [ "$amac" = "$tmac" ]; then
                printf '%s\n' "$dev"
                return 0
            fi
        done
    fi
    for p in "${SYS_NET}"/*; do
        [ -e "$p" ] || continue
        dev="${p#"${SYS_NET}/"}"
        [ "$dev" = "lo" ] || [ -e "${SYS_NET}/${dev}/master" ] && continue
        if [ -r "${SYS_NET}/${dev}/type" ]; then
            ntype=$(cat "${SYS_NET}/${dev}/type" 2>/dev/null || true)
            [ "$ntype" = "1" ] || continue
        fi
        if ip link show dev "$dev" 2>/dev/null | grep -q 'UP'; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    printf '%s\n' "$fallback_iface"
}

stop_other_dhcp() {
    other_fam="$1"
    for pid_dir in "${PROC_ROOT}"/[0-9]*; do
        [ -r "${pid_dir}/cmdline" ] || continue
        pid_num="${pid_dir#"${PROC_ROOT}/"}"
        [ "$pid_num" = "$$" ] && continue
        arg0=$(tr '\0' '\n' < "${pid_dir}/cmdline" 2>/dev/null | sed -n '1p')
        prog="${arg0##*/}"
        prog="${prog%% *}"
        prog="${prog%:}"
        cmdline=" $(tr '\0' ' ' < "${pid_dir}/cmdline" 2>/dev/null || true) "
        should_kill=0
        if [ "$other_fam" = "ipv4" ]; then
            case "$prog" in
                udhcpc) should_kill=1 ;;
                dhclient) case "$cmdline" in *" -6 "*) ;; *) should_kill=1 ;; esac ;;
                dhcpcd)
                    case "$cmdline" in
                        *" -4 "*|*" --ipv4only "*) should_kill=1 ;;
                        *"[ip4]"*) case "$cmdline" in *"[ip6]"*) ;; *) should_kill=1 ;; esac ;;
                    esac
                    ;;
            esac
        else
            case "$prog" in
                odhcp6c|dhcp6c) should_kill=1 ;;
                dhclient) case "$cmdline" in *" -6 "*) should_kill=1 ;; esac ;;
                dhcpcd)
                    case "$cmdline" in
                        *" -6 "*|*" --ipv6only "*) should_kill=1 ;;
                        *"[ip6]"*) case "$cmdline" in *"[ip4]"*) ;; *) should_kill=1 ;; esac ;;
                    esac
                    ;;
            esac
        fi
        [ "$should_kill" -eq 1 ] && kill "$pid_num" 2>/dev/null || true
    done
}

has_default_route() {
    rfam="$1"
    {
        ip "$rfam" route show default 2>/dev/null
        ip "$rfam" route show 2>/dev/null
    } | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)([[:space:]]|$)' |
        grep -Eq '(^|[[:space:]])(default|0\.0\.0\.0/0|::/0)([[:space:]]|$)'
}

del_default_routes() {
    rfam="$1"
    ip "$rfam" route flush default 2>/dev/null || true
    ip "$rfam" route del default 2>/dev/null || true
    r_i=0
    while [ $r_i -lt 8 ]; do
        rline=$({
            ip "$rfam" route show default 2>/dev/null
            ip "$rfam" route show 2>/dev/null
        } | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)([[:space:]]|$)' |
            grep -E '(^|[[:space:]])(default|0\.0\.0\.0/0|::/0)([[:space:]]|$)' | sed -n '1p')
        [ -n "$rline" ] || break
        rgw=''
        rdev=''
        prev_tok=''
        for tok in $rline; do
            if [ "$prev_tok" = "via" ] && [ -z "$rgw" ]; then
                rgw="$tok"
            elif [ "$prev_tok" = "dev" ] && [ -z "$rdev" ]; then
                rdev="$tok"
            fi
            prev_tok="$tok"
        done
        deleted_one=0
        if [ -n "$rgw" ] && [ -n "$rdev" ]; then
            ip "$rfam" route del default via "$rgw" dev "$rdev" 2>/dev/null && deleted_one=1 || true
            if [ "$deleted_one" -eq 0 ] && [ "$rfam" = "-6" ]; then
                ip -6 route del ::/0 via "$rgw" dev "$rdev" 2>/dev/null && deleted_one=1 || true
            fi
        fi
        if [ "$deleted_one" -eq 0 ] && [ -n "$rdev" ]; then
            ip "$rfam" route del default dev "$rdev" 2>/dev/null && deleted_one=1 || true
            if [ "$deleted_one" -eq 0 ] && [ "$rfam" = "-6" ]; then
                ip -6 route del ::/0 dev "$rdev" 2>/dev/null && deleted_one=1 || true
            fi
        fi
        if [ "$deleted_one" -eq 0 ]; then
            ip "$rfam" route del default 2>/dev/null && deleted_one=1 || break
        fi
        r_i=$((r_i + 1))
    done
}

flush_ipv6_iface() {
    tdev="$1"
    [ -n "$tdev" ] && [ "$tdev" != "lo" ] || return 0
    if [ "$EFFECTIVE_STACK" = "ipv4" ]; then
        set --
    else
        set -- scope global
    fi
    ip -6 addr flush dev "$tdev" "$@" 2>/dev/null || true
    ip -6 addr show dev "$tdev" "$@" 2>/dev/null | while IFS= read -r aline; do
        case "$aline" in
            *inet6[${ws}]*)
                rest="${aline#*inet6}"
                rest="${rest#"${rest%%[!${ws}]*}"}"
                a6="${rest%%[${ws}]*}"
                [ -n "$a6" ] && ip -6 addr del "$a6" dev "$tdev" 2>/dev/null || true
                ;;
        esac
    done
}

flush_ipv4_iface() {
    tdev="$1"
    [ -n "$tdev" ] && [ "$tdev" != "lo" ] || return 0
    ip -4 addr flush dev "$tdev" 2>/dev/null || true
    ip -4 addr show dev "$tdev" 2>/dev/null | while IFS= read -r aline; do
        case "$aline" in
            *inet6[${ws}]*) continue ;;
            *inet[${ws}]*)
                rest="${aline#*inet}"
                rest="${rest#"${rest%%[!${ws}]*}"}"
                a4="${rest%%[${ws}]*}"
                [ -n "$a4" ] && ip -4 addr del "$a4" dev "$tdev" 2>/dev/null || true
                ;;
        esac
    done
    ip -4 route flush dev "$tdev" 2>/dev/null || true
}

clean_resolv_conf() {
    want_family="$1"
    fallback_dns="$2"
    tmp_resolv="${RESOLV_CONF}.zero.$$"
    has_usable_ns=0
    ll_ns_count=0

    : > "$tmp_resolv" 2>/dev/null || return 0
    if [ -r "$RESOLV_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%"$cr_ch"}"
            trimmed="${line#"${line%%[!${ws}]*}"}"
            case "$trimmed" in
                nameserver[${ws}]*)
                    rest="${trimmed#nameserver}"
                    rest="${rest#"${rest%%[!${ws}]*}"}"
                    ns_addr="${rest%%[${ws}#;]*}"
                    if [ "$want_family" = "ipv4" ]; then
                        case "$ns_addr" in
                            *:*) continue ;;
                            127.*|0.*) continue ;;
                            [0-9]*.[0-9]*.[0-9]*.[0-9]*)
                                has_usable_ns=1
                                printf 'nameserver %s\n' "$ns_addr" >> "$tmp_resolv"
                                ;;
                            *) continue ;;
                        esac
                    else
                        case "$ns_addr" in
                            *.*) continue ;;
                            ::1|::|0:0:0:0:0:0:0:1|0:0:0:0:0:0:0:0|0000:0000:0000:0000:0000:0000:0000:0001|0000:0000:0000:0000:0000:0000:0000:0000)
                                continue
                                ;;
                            *:*)
                                case "$ns_addr" in
                                    [Ff][Ee][89AaBb][0-9A-Fa-f]:*)
                                        if [ "$ll_ns_count" -lt 1 ]; then
                                            case "$ns_addr" in
                                                *%*) ;;
                                                *) [ -n "$iface" ] && ns_addr="${ns_addr}%${iface}" ;;
                                            esac
                                            printf 'nameserver %s\n' "$ns_addr" >> "$tmp_resolv"
                                            ll_ns_count=$((ll_ns_count + 1))
                                        fi
                                        ;;
                                    *)
                                        has_usable_ns=1
                                        printf 'nameserver %s\n' "$ns_addr" >> "$tmp_resolv"
                                        ;;
                                esac
                                ;;
                            *) continue ;;
                        esac
                    fi
                    ;;
                *)
                    printf '%s\n' "$line" >> "$tmp_resolv"
                    ;;
            esac
        done < "$RESOLV_CONF"
    fi
    if [ "$has_usable_ns" -eq 0 ]; then
        for ns in $fallback_dns; do
            printf 'nameserver %s\n' "$ns" >> "$tmp_resolv"
        done
    fi
    cat "$tmp_resolv" > "$RESOLV_CONF" 2>/dev/null || mv -f "$tmp_resolv" "$RESOLV_CONF" 2>/dev/null || true
    rm -f "$tmp_resolv" 2>/dev/null || true
}

disable_ipv6_ra() {
    full_disable="$1"
    for k in "${IPV6_CONF_DIR}/all/accept_ra" "${IPV6_CONF_DIR}/default/accept_ra" "${IPV6_CONF_DIR}/all/autoconf" "${IPV6_CONF_DIR}/default/autoconf"; do
        [ -w "$k" ] && echo 0 > "$k" 2>/dev/null || true
    done
    for d in "${IPV6_CONF_DIR}"/*; do
        [ -d "$d" ] || continue
        dev="${d#"${IPV6_CONF_DIR}/"}"
        [ "$dev" = "lo" ] && continue
        [ -w "${d}/accept_ra" ] && echo 0 > "${d}/accept_ra" 2>/dev/null || true
        [ -w "${d}/autoconf" ] && echo 0 > "${d}/autoconf" 2>/dev/null || true
        if [ "$full_disable" = "1" ] && [ "$dev" != "all" ] && [ "$dev" != "default" ]; then
            [ -w "${d}/disable_ipv6" ] && echo 1 > "${d}/disable_ipv6" 2>/dev/null || true
        fi
    done
}

if [ "${1:-}" = "--pre" ]; then
    [ "$INSTALLER_FAMILY" = "ipv4" ] && disable_ipv6_ra 0
    exit 0
fi

iface=$(resolve_iface "$INSTALLER_MAC" "$INSTALLER_IFACE")
[ -n "$iface" ] && ip link set dev "$iface" up 2>/dev/null || true

if [ "$INSTALLER_FAMILY" = "ipv4" ]; then
    stop_other_dhcp ipv6
    [ "$EFFECTIVE_STACK" = "ipv4" ] && disable_ipv6_ra 1 || disable_ipv6_ra 0
    if [ "$EFFECTIVE_STACK" = "ipv4" ] && [ -w "${IPV6_CONF_DIR}/lo/disable_ipv6" ]; then
        echo 0 > "${IPV6_CONF_DIR}/lo/disable_ipv6" 2>/dev/null || true
    fi
    [ -n "$iface" ] && flush_ipv6_iface "$iface"
    for p in "${SYS_NET}"/*; do
        [ -e "$p" ] || continue
        dev="${p#"${SYS_NET}/"}"
        [ "$dev" = "lo" ] || [ "$dev" = "$iface" ] && continue
        flush_ipv6_iface "$dev"
    done
    del_default_routes -6
    if [ -n "$IPV4_ADDR" ]; then
        if ! ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
            ip -4 addr add "${IPV4_ADDR}/${IPV4_PREFIX}" dev "$iface" 2>/dev/null || true
        fi
        if [ -n "$IPV4_GATE" ] && ! has_default_route -4; then
            ip -4 route add "$IPV4_GATE" dev "$iface" scope link 2>/dev/null ||
                ip -4 route add "$IPV4_GATE" dev "$iface" 2>/dev/null || true
            ip -4 route add default via "$IPV4_GATE" dev "$iface" onlink 2>/dev/null ||
                ip -4 route add default via "$IPV4_GATE" dev "$iface" 2>/dev/null || true
        fi
    fi
    clean_resolv_conf ipv4 "$DNS_V4"
else
    stop_other_dhcp ipv4
    del_default_routes -4
    [ -n "$iface" ] && flush_ipv4_iface "$iface"
    for p in "${SYS_NET}"/*; do
        [ -e "$p" ] || continue
        dev="${p#"${SYS_NET}/"}"
        [ "$dev" = "lo" ] || [ "$dev" = "$iface" ] && continue
        flush_ipv4_iface "$dev"
    done
    for k in "${IPV6_CONF_DIR}/all/accept_ra" "${IPV6_CONF_DIR}/default/accept_ra" "${IPV6_CONF_DIR}/${iface}/accept_ra"; do
        [ -w "$k" ] && echo 2 > "$k" 2>/dev/null || true
    done
    i=0
    while [ $i -lt 8 ]; do
        ip -6 addr show dev "$iface" 2>/dev/null | grep -q 'tentative' || break
        sleep 1
        i=$((i + 1))
    done
    if [ -n "$IPV6_ADDR" ] && ! ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q 'inet6 '; then
        ip -6 addr add "${IPV6_ADDR}/${IPV6_PREFIX}" dev "$iface" 2>/dev/null || true
        i=0
        while [ $i -lt 5 ]; do
            ip -6 addr show dev "$iface" 2>/dev/null | grep -q 'tentative' || break
            sleep 1
            i=$((i + 1))
        done
    fi
    if [ -n "$IPV6_GATE" ] && ! has_default_route -6; then
        case "$IPV6_GATE" in
            [Ff][Ee][89AaBb][0-9A-Fa-f]:*)
                ip -6 route add default via "$IPV6_GATE" dev "$iface" 2>/dev/null || true
                ;;
            *)
                ip -6 route add "$IPV6_GATE" dev "$iface" 2>/dev/null || true
                ip -6 route add default via "$IPV6_GATE" dev "$iface" onlink 2>/dev/null ||
                    ip -6 route add default via "$IPV6_GATE" dev "$iface" 2>/dev/null || true
                ;;
        esac
    fi
    clean_resolv_conf ipv6 "$DNS_V6"
fi
exit 0
EOF
    chmod 755 "${boot_work_dir}/fix-netcfg-route.sh" || return 1

    mkdir -p "${boot_work_dir}/var/lib/dpkg/info" || return 1
    cp -f "$orig_postinst" "${boot_work_dir}/var/lib/dpkg/info/netcfg.postinst.real" || return 1
    chmod 755 "${boot_work_dir}/var/lib/dpkg/info/netcfg.postinst.real" || return 1
    cat > "${boot_work_dir}/var/lib/dpkg/info/netcfg.postinst" <<'EOF' || return 1
#!/bin/sh
[ -x /fix-netcfg-route.sh ] && /fix-netcfg-route.sh --pre || true
/var/lib/dpkg/info/netcfg.postinst.real "$@"
rc=$?
[ -x /fix-netcfg-route.sh ] && /fix-netcfg-route.sh || true
exit $rc
EOF
    chmod 755 "${boot_work_dir}/var/lib/dpkg/info/netcfg.postinst" || return 1
}

reinstall_write_apt_hook() {
    local boot_work_dir="$1" is_archive_mirror="${2:-0}"
    local force_family_line=''
    if [[ "$REINSTALL_INSTALLER_FAMILY" == "ipv6" ]]; then
        force_family_line='Acquire::ForceIPv6 "true";'
    else
        force_family_line='Acquire::ForceIPv4 "true";'
    fi

    mkdir -p "${boot_work_dir}/usr/lib/post-base-installer.d" || return 1
    cat > "${boot_work_dir}/usr/lib/post-base-installer.d/05zero-apt-conf" <<EOF || return 1
#!/bin/sh
mkdir -p /target/etc/apt/apt.conf.d
printf '%s\n' '${force_family_line}' > /target/etc/apt/apt.conf.d/99zero-reinstall
chmod 644 /target/etc/apt/apt.conf.d/99zero-reinstall
if [ '${is_archive_mirror}' = '1' ]; then
    printf '%s\n' 'Acquire::Check-Valid-Until "false";' > /target/etc/apt/apt.conf.d/99archive-valid-until
    chmod 644 /target/etc/apt/apt.conf.d/99archive-valid-until
fi
exit 0
EOF
    chmod 755 "${boot_work_dir}/usr/lib/post-base-installer.d/05zero-apt-conf" || return 1
}

reinstall_probe_apt_services() {
    local mirror="$1" dist="$2" wget_fam="$3" mirror_host="$4"
    local services='' sec_ok=0 upd_ok=0
    if [[ "$mirror_host" == "archive.debian.org" ]]; then
        printf 'd-i apt-setup/services-select multiselect\n'
        return 0
    fi
    if wget "$wget_fam" --spider -q --timeout=4 --tries=1 "https://security.debian.org/debian-security/dists/${dist}-security/Release" >/dev/null 2>&1 ||
       wget "$wget_fam" --spider -q --timeout=4 --tries=1 "http://security.debian.org/debian-security/dists/${dist}-security/Release" >/dev/null 2>&1; then
        sec_ok=1
    fi
    if wget "$wget_fam" --spider -q --timeout=4 --tries=1 "${mirror}/dists/${dist}-updates/Release" >/dev/null 2>&1; then
        upd_ok=1
    fi
    if (( sec_ok && upd_ok )); then
        services='security, updates'
    elif (( sec_ok )); then
        services='security'
    elif (( upd_ok )); then
        services='updates'
    fi
    if [[ -n "$services" ]]; then
        printf 'd-i apt-setup/services-select multiselect %s\n' "$services"
    else
        printf 'd-i apt-setup/services-select multiselect\n'
    fi
}

reinstall_write_post_install_script() {
    local boot_work_dir="${1:-/tmp/boot}"
    local target_dns='' network_blocks='' sysctl_block=''
    mkdir -p "$boot_work_dir" || return 1
    target_dns=$(reinstall_target_dns_list "$REINSTALL_EFFECTIVE_STACK")

    case "$REINSTALL_EFFECTIVE_STACK" in
        ipv4)
            network_blocks=$(reinstall_build_ipv4_stanza "$REINSTALL_DNS_V4")
            sysctl_block='append_disable_ipv6_sysctl() {
    cand_dev="$1"
    [ -n "$cand_dev" ] || return 0
    case "$seen_devs" in
        *" ${cand_dev} "*) return 0 ;;
    esac
    case "$cand_dev" in
        lo|all|default|tun*|tap*|wg*|warp*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|virbr*|vnet*|fwbr*|fwpr*|fwln*|cni*|flannel*|cali*|cilium*|weave*|kube-*|podman*|incusbr*|lxcbr*|lxdbr*)
            return 0
            ;;
    esac
    if [ -r "/sys/class/net/${cand_dev}/type" ]; then
        ntype=$(cat "/sys/class/net/${cand_dev}/type" 2>/dev/null || true)
        if [ "$ntype" != "1" ] && [ "$cand_dev" != "$iface4" ] && [ "$cand_dev" != "$iface6" ]; then
            return 0
        fi
    fi
    seen_devs="${seen_devs}${cand_dev} "
    sysctl_dev=$(printf "%s" "$cand_dev" | tr "." "/")
    printf "net.ipv6.conf.%s.disable_ipv6 = 1\n" "$sysctl_dev"
    printf "net.ipv6.conf.%s.accept_ra = 0\n" "$sysctl_dev"
    printf "net.ipv6.conf.%s.autoconf = 0\n" "$sysctl_dev"
}
mkdir -p /etc/sysctl.d
{
    cat <<EOF_SYSCTL
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
EOF_SYSCTL
    seen_devs=" lo all default "
    append_disable_ipv6_sysctl "$iface4"
    append_disable_ipv6_sysctl "$iface6"
    for p in /sys/class/net/*; do
        [ -e "$p" ] || continue
        append_disable_ipv6_sysctl "${p#/sys/class/net/}"
    done
} > /etc/sysctl.d/99-zero-reinstall-stack.conf
chmod 644 /etc/sysctl.d/99-zero-reinstall-stack.conf
mkdir -p /etc/network/if-pre-up.d
cat > /etc/network/if-pre-up.d/zero-disable-ipv6 <<EOF_IFPREUP_HDR
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
TARGET_IFACE4="$iface4"
TARGET_IFACE6="$iface6"
EOF_IFPREUP_HDR
cat >> /etc/network/if-pre-up.d/zero-disable-ipv6 <<'\''EOF_IFPREUP'\''
PROC_IPV6_CONF="${ZERO_PROC_IPV6_CONF:-/proc/sys/net/ipv6/conf}"
SYS_NET_DIR="${ZERO_SYS_NET_DIR:-/sys/class/net}"
for k in all/disable_ipv6 default/disable_ipv6 lo/disable_ipv6; do
    [ -w "${PROC_IPV6_CONF}/${k}" ] && echo 0 > "${PROC_IPV6_CONF}/${k}" 2>/dev/null || true
done
for k in all/accept_ra default/accept_ra all/autoconf default/autoconf; do
    [ -w "${PROC_IPV6_CONF}/${k}" ] && echo 0 > "${PROC_IPV6_CONF}/${k}" 2>/dev/null || true
done
for d in "${PROC_IPV6_CONF}"/*; do
    [ -d "$d" ] || continue
    dev="${d#"${PROC_IPV6_CONF}/"}"
    case "$dev" in
        all|default|lo|tun*|tap*|wg*|warp*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|virbr*|vnet*|fwbr*|fwpr*|fwln*|cni*|flannel*|cali*|cilium*|weave*|kube-*|podman*|incusbr*|lxcbr*|lxdbr*)
            continue
            ;;
    esac
    if [ -r "${SYS_NET_DIR}/${dev}/type" ]; then
        ntype=$(cat "${SYS_NET_DIR}/${dev}/type" 2>/dev/null || true)
        if [ "$ntype" != "1" ] &&
           [ "$dev" != "${IFACE:-}" ] &&
           [ "$dev" != "${INTERFACE:-}" ] &&
           [ "$dev" != "${TARGET_IFACE4:-}" ] &&
           [ "$dev" != "${TARGET_IFACE6:-}" ]; then
            continue
        fi
    fi
    [ -w "${d}/accept_ra" ] && echo 0 > "${d}/accept_ra" 2>/dev/null || true
    [ -w "${d}/autoconf" ] && echo 0 > "${d}/autoconf" 2>/dev/null || true
    [ -w "${d}/disable_ipv6" ] && echo 1 > "${d}/disable_ipv6" 2>/dev/null || true
    ip -6 addr flush dev "$dev" 2>/dev/null || true
done
ip -6 route flush default 2>/dev/null || true
ip -6 route del default 2>/dev/null || true
exit 0
EOF_IFPREUP
chmod 755 /etc/network/if-pre-up.d/zero-disable-ipv6
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/90-zero-disable-ipv6.rules <<'\''EOF_UDEV'\''
ACTION=="add|change", SUBSYSTEM=="net", DEVPATH!="/devices/virtual/*", ATTR{type}=="1", RUN+="/etc/network/if-pre-up.d/zero-disable-ipv6"
EOF_UDEV
chmod 644 /etc/udev/rules.d/90-zero-disable-ipv6.rules
if [ -f /etc/dhcpcd.conf ]; then
    grep -Eq "^[[:space:]]*noipv6([[:space:]]|\$)" /etc/dhcpcd.conf || printf "\nnoipv6\nnoipv6rs\n" >> /etc/dhcpcd.conf
fi'
            ;;
        ipv6)
            network_blocks=$(reinstall_build_ipv6_stanza "1" "$REINSTALL_DNS_V6")
            sysctl_block='if [ -f /etc/dhcpcd.conf ]; then
    grep -Eq "^[[:space:]]*noipv4([[:space:]]|\$)" /etc/dhcpcd.conf || printf "\nnoipv4\nnoipv4ll\n" >> /etc/dhcpcd.conf
fi'
            ;;
        dual)
            local v4_part='' v6_part=''
            v4_part=$(reinstall_build_ipv4_stanza "$REINSTALL_DNS_LIST")
            v6_part=$(reinstall_build_ipv6_stanza "0" "$REINSTALL_DNS_V6")
            network_blocks="${v4_part}
if [ \"\$iface6\" != \"\$iface4\" ]; then
    printf '\\nauto %s\\n' \"\$iface6\" >> /etc/network/interfaces
fi
${v6_part}"
            ;;
    esac

    cat > "${boot_work_dir}/post-install.sh" <<EOF || return 1
#!/bin/sh
set -u

rm -f /etc/apt/apt.conf.d/99zero-reinstall

if [ -L /etc/systemd/system/multi-user.target.wants/dhcpcd.service ] || [ -f /lib/systemd/system/dhcpcd.service ] || [ -f /usr/lib/systemd/system/dhcpcd.service ]; then
    rm -f /etc/systemd/system/multi-user.target.wants/dhcpcd.service
    command -v systemctl >/dev/null 2>&1 && systemctl disable dhcpcd.service >/dev/null 2>&1 || true
fi

resolve_nic() {
    target_mac="\$1"
    fallback_name="\$2"
    default_from_ifaces="\$3"
    if [ -n "\$target_mac" ]; then
        tmac=\$(printf '%s' "\$target_mac" | tr '[:upper:]' '[:lower:]')
        for p in /sys/class/net/*/address; do
            [ -r "\$p" ] || continue
            dev="\${p#/sys/class/net/}"
            dev="\${dev%/address}"
            [ "\$dev" = "lo" ] || [ -e "/sys/class/net/\${dev}/master" ] && continue
            if [ -r "/sys/class/net/\${dev}/type" ]; then
                ntype=\$(cat "/sys/class/net/\${dev}/type" 2>/dev/null || true)
                [ "\$ntype" = "1" ] || continue
            fi
            amac=\$(tr '[:upper:]' '[:lower:]' < "\$p" 2>/dev/null || true)
            if [ "\$amac" = "\$tmac" ]; then
                printf '%s\n' "\$dev"
                return 0
            fi
        done
    fi
    if [ -n "\$default_from_ifaces" ]; then
        printf '%s\n' "\$default_from_ifaces"
        return 0
    fi
    printf '%s\n' "\$fallback_name"
}

detected_iface=\$(awk '/^(auto|allow-hotplug)[[:space:]]+/ {for (i = 2; i <= NF; i++) if (\$i != "lo") {print \$i; exit}}' /etc/network/interfaces 2>/dev/null || true)
iface4=\$(resolve_nic '${REINSTALL_IPV4_MAC}' '${REINSTALL_IPV4_IFACE:-${REINSTALL_NETWORK_INTERFACE}}' "\$detected_iface")
iface6=\$(resolve_nic '${REINSTALL_IPV6_MAC}' '${REINSTALL_IPV6_IFACE:-${REINSTALL_NETWORK_INTERFACE}}' "\$detected_iface")

update_sshd_option() {
    key="\$1"
    value="\$2"
    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "\$f" ] || continue
            awk -v k="\$key" '
                BEGIN { lk = tolower(k); in_match = 0 }
                tolower(\$1) == "match" { in_match = 1 }
                !in_match && tolower(\$0) ~ ("^[#[:space:]]*" lk "([[:space:]]+|=)") { next }
                { print }
            ' "\$f" > "\${f}.tmp" && mv -f "\${f}.tmp" "\$f" || rm -f "\${f}.tmp"
        done
    fi
    if [ -f /etc/ssh/sshd_config ]; then
        if awk -v k="\$key" -v v="\$value" '
            BEGIN { inserted = 0; lk = tolower(k); in_match = 0 }
            {
                low = tolower(\$0)
                if (!in_match && low ~ "^[[:space:]]*match[[:space:]]+") {
                    if (!inserted) {
                        print k " " v
                        inserted = 1
                    }
                    in_match = 1
                }
                if (!in_match && low ~ ("^[#[:space:]]*" lk "([[:space:]]+|=)")) next
                print
            }
            END {
                if (!inserted) print k " " v
            }
        ' /etc/ssh/sshd_config > /etc/ssh/sshd_config.tmp && mv -f /etc/ssh/sshd_config.tmp /etc/ssh/sshd_config; then
            chmod 644 /etc/ssh/sshd_config || true
        else
            rm -f /etc/ssh/sshd_config.tmp
        fi
    fi
}

mkdir -p /etc/network
cat > /etc/network/interfaces <<'EOF_INTERFACES'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF_INTERFACES
${network_blocks}

{
    :
${sysctl_block}
} || true

rm -f /etc/resolv.conf
: > /etc/resolv.conf
for ns in ${target_dns}; do
    echo "nameserver \$ns" >> /etc/resolv.conf
done
chmod 644 /etc/resolv.conf || true

update_sshd_option Port ${REINSTALL_SSH_PORT}
update_sshd_option PermitRootLogin yes
update_sshd_option PasswordAuthentication yes
update_sshd_option PubkeyAuthentication yes

for sock_unit in ssh.socket sshd.socket; do
    if [ -L "/etc/systemd/system/sockets.target.wants/\${sock_unit}" ] ||
       [ -L "/usr/lib/systemd/system/sockets.target.wants/\${sock_unit}" ] ||
       [ -L "/lib/systemd/system/sockets.target.wants/\${sock_unit}" ]; then
        mkdir -p "/etc/systemd/system/\${sock_unit}.d" &&
        cat > "/etc/systemd/system/\${sock_unit}.d/zero-port.conf" <<EOF_SOCKET || true
[Socket]
ListenStream=
BindIPv6Only=default
ListenStream=${REINSTALL_SSH_PORT}
EOF_SOCKET
    fi
done
exit 0
EOF
    chmod 700 "${boot_work_dir}/post-install.sh" || return 1
    mkdir -p "${boot_work_dir}/usr/lib/finish-install.d" || return 1
    cat > "${boot_work_dir}/usr/lib/finish-install.d/85zero-post-install" <<'EOF_FINISH' || return 1
#!/bin/sh
if [ -f /post-install.sh ] && [ -d /target/etc ]; then
    if cp /post-install.sh /target/root/reinstall-post.sh; then
        chmod 700 /target/root/reinstall-post.sh || true
        in-target /bin/sh /root/reinstall-post.sh || chroot /target /bin/sh /root/reinstall-post.sh || true
        rm -f /target/root/reinstall-post.sh
    fi
fi
exit 0
EOF_FINISH
    chmod 755 "${boot_work_dir}/usr/lib/finish-install.d/85zero-post-install" || return 1
}

reinstall_build_preseed_netcfg() {
    local ip_addr='' netmask='' preseed_gw='none' dns_servers='' use_autoconf=0 autoconf_lines=''
    if [[ "$REINSTALL_INSTALLER_FAMILY" == "ipv6" ]]; then
        ip_addr="$REINSTALL_IPV6_ADDR"
        netmask=$(reinstall_ipv6_prefix_to_netmask "$REINSTALL_IPV6_PREFIX")
        dns_servers="$REINSTALL_DNS_V6"
        if [[ -n "$REINSTALL_IPV6_GATE" ]] &&
           reinstall_ipv6_in_same_subnet "$REINSTALL_IPV6_ADDR" "$REINSTALL_IPV6_PREFIX" "$REINSTALL_IPV6_GATE"; then
            preseed_gw="$REINSTALL_IPV6_GATE"
        fi
        [[ "$REINSTALL_IPV6_MODE" != "static" ]] && use_autoconf=1
    else
        ip_addr="$REINSTALL_IPV4_ADDR"
        netmask="$REINSTALL_IPV4_MASK"
        dns_servers="$REINSTALL_DNS_V4"
        if [[ -n "$REINSTALL_IPV4_GATE" ]] &&
           reinstall_ipv4_in_same_subnet "$REINSTALL_IPV4_ADDR" "$REINSTALL_IPV4_PREFIX" "$REINSTALL_IPV4_GATE"; then
            preseed_gw="$REINSTALL_IPV4_GATE"
        fi
        [[ "$REINSTALL_IPV4_MODE" == "dhcp" ]] && use_autoconf=1
    fi

    if (( use_autoconf == 1 )); then
        autoconf_lines=$'d-i netcfg/disable_autoconfig boolean false\nd-i netcfg/use_autoconfig boolean true'
    else
        autoconf_lines='d-i netcfg/disable_autoconfig boolean true'
    fi

    cat <<EOF
d-i netcfg/choose_interface select auto
${autoconf_lines}
d-i netcfg/dhcp_failed note
d-i netcfg/dhcp_options select Configure network manually
d-i netcfg/get_ipaddress string ${ip_addr}
d-i netcfg/get_netmask string ${netmask}
d-i netcfg/get_gateway string ${preseed_gw}
d-i netcfg/get_nameservers string ${dns_servers}
d-i netcfg/confirm_static boolean true
EOF
}

reinstall_validate_target_disk() {
    local disk="$1"
    if [[ -z "$disk" ]]; then
        echo -e "${RED}未检测到目标磁盘。${PLAIN}"
        return 1
    fi
    if [[ "$(lsblk -ndo TRAN "$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]')" == "iscsi" ]]; then
        echo -e "${RED}检测到目标根磁盘 (${disk}) 为 iSCSI 挂载卷（常见于部分 Oracle Cloud 实例）。${PLAIN}"
        echo -e "${YELLOW}标准 netboot 镜像不支持重装 iSCSI 引导卷，请先在云控制台将引导卷连接类型切换为半虚拟化 (Paravirtualized) 后重试。${PLAIN}"
        return 1
    fi
    return 0
}

reinstall_install_target_system() (
    local debian_version="$1" target_disk="$2"
    local boot_root="${REINSTALL_BOOT_DIR:-/boot}" tmp_root="${REINSTALL_TMP_ROOT:-}"
    local arch='' dist='' grub='' grub_dir='' grub_file='' grub_ver='' grub_backup=''
    local mirror_info='' mirror='' mirror_host='' mirror_folder='' wget_fam='-4' is_archive_mirror=0
    local load_num='' cfg0='' cfg1='' cfg2='' tmp_cfg='' insert_grub=''
    local existing_kpath='' grub_boot_prefix='' linux_kernel='' linux_img=''
    local installer_mac='' bootif_opt='' console_opts='' add_option='' boot_option=''
    local vmlinuz_grub_path='' initrd_grub_path='' grub_target='' grub_bootdev=''
    local root_password_hash='' partman_early_command=''
    local apt_non_free_firmware_line='' apt_services_line='' efi_partman_lines=''
    local pkgsel_packages='' netcfg_preseed_block='' tmp_avail_kb=''
    grub_tmp=''
    read_grub=''
    grub_new=''
    boot_work_dir=''
    extract_work_dir=''
    overlay_gz=''
    initrd_dl=''
    vmlinuz_dl=''

    if [[ -z "$tmp_root" ]]; then
        tmp_avail_kb=$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 {print $4}')
        if [[ "$tmp_avail_kb" =~ ^[0-9]+$ ]] && (( tmp_avail_kb < 262144 )) && [[ -d /var/tmp ]]; then
            tmp_root='/var/tmp'
        else
            tmp_root='/tmp'
        fi
    fi

    arch=$(zero_get_arch) || {
        echo -e "${RED}不支持的 CPU 架构: $(uname -m)${PLAIN}"
        exit 1
    }

    case "$debian_version" in
        11)
            dist='bullseye'
            pkgsel_packages='openssh-server isc-dhcp-client ifupdown ca-certificates'
            ;;
        12)
            dist='bookworm'
            pkgsel_packages='openssh-server isc-dhcp-client ifupdown ca-certificates'
            apt_non_free_firmware_line='d-i apt-setup/non-free-firmware boolean true'
            ;;
        13)
            dist='trixie'
            pkgsel_packages='openssh-server isc-dhcp-client dhcpcd-base ifupdown ca-certificates'
            apt_non_free_firmware_line='d-i apt-setup/non-free-firmware boolean true'
            ;;
        *)
            echo -e "${RED}不支持的 Debian 版本: ${debian_version}${PLAIN}"
            exit 1
            ;;
    esac

    reinstall_require_commands ip wget awk grep sed cut cat dd od lsblk cpio gzip find dirname basename openssl findmnt readlink grub-editenv
    reinstall_gather_network_state
    reinstall_validate_target_disk "$target_disk" || exit 1

    grub=$(reinstall_get_grub "$boot_root") || {
        echo -e "${RED}未找到 GRUB 配置。${PLAIN}"
        exit 1
    }
    grub_dir=$(echo "$grub" | cut -d: -f1)
    grub_file=$(echo "$grub" | cut -d: -f2)
    grub_ver=$(echo "$grub" | cut -d: -f3)
    [[ "$grub_ver" == "0" ]] || {
        echo -e "${RED}当前仅支持 GRUB2。${PLAIN}"
        exit 1
    }

    mirror_info=$(reinstall_select_debian_mirror "$dist" "$arch" "$REINSTALL_EFFECTIVE_STACK") || {
        echo -e "${RED}未找到当前网络模式 (${REINSTALL_EFFECTIVE_STACK}) 下可达的 Debian ${debian_version} (${arch}) 镜像。${PLAIN}"
        exit 1
    }
    REINSTALL_INSTALLER_FAMILY="${mirror_info%%|*}"
    mirror="${mirror_info#*|}"
    [[ "$REINSTALL_INSTALLER_FAMILY" == "ipv6" ]] && wget_fam='-6' || wget_fam='-4'

    root_password_hash=$(reinstall_hash_password "$REINSTALL_ROOT_PASSWORD")
    [[ -n "$root_password_hash" ]] || {
        echo -e "${RED}生成 root 密码哈希失败。${PLAIN}"
        exit 1
    }

    if [[ -z "${REINSTALL_NO_CLEAR:-}" ]]; then
        clear
    fi
    echo -e "\n${BLUE}# Install${PLAIN}\n"
    echo -e "${YELLOW}目标系统: Debian ${debian_version} (${dist}) [${arch}]${PLAIN}"
    echo -e "${YELLOW}网络模式: $(reinstall_stack_label "$REINSTALL_EFFECTIVE_STACK") (安装拉取通道: ${REINSTALL_INSTALLER_FAMILY})${PLAIN}"
    echo -e "${YELLOW}目标磁盘: ${target_disk}${PLAIN}"
    if [[ "$REINSTALL_EFFECTIVE_STACK" == "ipv4" || "$REINSTALL_EFFECTIVE_STACK" == "dual" ]]; then
        if [[ "$REINSTALL_IPV4_MODE" == "dhcp" ]]; then
            echo -e "${YELLOW}IPv4: DHCP 自动获取 (${REINSTALL_IPV4_IFACE}: ${REINSTALL_IPV4_ADDR}/${REINSTALL_IPV4_PREFIX})${PLAIN}"
        else
            echo -e "${YELLOW}IPv4: 静态继承 (${REINSTALL_IPV4_IFACE}: ${REINSTALL_IPV4_ADDR}/${REINSTALL_IPV4_PREFIX} gw ${REINSTALL_IPV4_GATE})${PLAIN}"
        fi
    else
        echo -e "${YELLOW}IPv4: 禁用（仅 IPv6 模式）${PLAIN}"
    fi
    if [[ "$REINSTALL_EFFECTIVE_STACK" == "ipv6" || "$REINSTALL_EFFECTIVE_STACK" == "dual" ]]; then
        case "$REINSTALL_IPV6_MODE" in
            slaac)  echo -e "${YELLOW}IPv6: SLAAC 自动配置 (${REINSTALL_IPV6_IFACE}: ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX})${PLAIN}" ;;
            dhcp6)  echo -e "${YELLOW}IPv6: DHCPv6 自动配置 (${REINSTALL_IPV6_IFACE}: ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX})${PLAIN}" ;;
            static) echo -e "${YELLOW}IPv6: 静态继承 (${REINSTALL_IPV6_IFACE}: ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX}${REINSTALL_IPV6_GATE:+ gw ${REINSTALL_IPV6_GATE}})${PLAIN}" ;;
        esac
    else
        echo -e "${YELLOW}IPv6: 禁用自动下发（仅 IPv4 模式）${PLAIN}"
    fi

    mirror_host=$(echo "$mirror" | awk -F'://|/' '{print $2}')
    mirror_folder=$(echo "$mirror" | awk -F"${mirror_host}" '{print $2}')
    [[ -n "$mirror_folder" ]] || mirror_folder='/'
    [[ "$mirror_host" == "archive.debian.org" ]] && is_archive_mirror=1
    apt_services_line=$(reinstall_probe_apt_services "$mirror" "$dist" "$wget_fam" "$mirror_host")

    if reinstall_is_efi || [[ "$arch" == "arm64" ]]; then
        efi_partman_lines='d-i partman-efi/non_efi_system boolean true
d-i partman-partitioning/choose_label select gpt
d-i partman-partitioning/default_label string gpt'
        grub_bootdev='default'
    else
        grub_bootdev="$target_disk"
    fi

    mkdir -p "$tmp_root" || exit 1
    read_grub="${tmp_root}/grub.read"
    grub_new="${tmp_root}/grub.new"
    boot_work_dir="${tmp_root}/boot"
    extract_work_dir="${tmp_root}/initrd.extract"
    overlay_gz="${tmp_root}/initrd.overlay.gz"
    initrd_dl="${tmp_root}/initrd.img"
    vmlinuz_dl="${tmp_root}/vmlinuz"

    cleanup_reinstall_stage() {
        [[ -n "${grub_tmp:-}" ]] && rm -f -- "$grub_tmp"
        [[ -n "${boot_work_dir:-}" ]] && rm -rf -- "$boot_work_dir"
        [[ -n "${extract_work_dir:-}" ]] && rm -rf -- "$extract_work_dir"
        [[ -n "${overlay_gz:-}" ]] && rm -f -- "$overlay_gz"
        [[ -n "${initrd_dl:-}" ]] && rm -f -- "$initrd_dl"
        [[ -n "${vmlinuz_dl:-}" ]] && rm -f -- "$vmlinuz_dl"
        [[ -n "${read_grub:-}" ]] && rm -f -- "$read_grub"
        [[ -n "${grub_new:-}" ]] && rm -f -- "$grub_new"
        return 0
    }
    trap cleanup_reinstall_stage EXIT

    wget "$wget_fam" --timeout=30 --tries=3 -qO "$initrd_dl" "${mirror}/dists/${dist}/main/installer-${arch}/current/images/netboot/debian-installer/${arch}/initrd.gz" || {
        echo -e "${RED}下载 initrd (${arch}) 失败。${PLAIN}"
        exit 1
    }
    wget "$wget_fam" --timeout=30 --tries=3 -qO "$vmlinuz_dl" "${mirror}/dists/${dist}/main/installer-${arch}/current/images/netboot/debian-installer/${arch}/linux" || {
        echo -e "${RED}下载内核 (${arch}) 失败。${PLAIN}"
        exit 1
    }
    if ! reinstall_validate_kernel_image "$vmlinuz_dl" "$arch"; then
        echo -e "${RED}校验内核镜像 (${arch}) 失败，原引导配置未修改。${PLAIN}"
        exit 1
    fi
    if ! gzip -t "$initrd_dl" >/dev/null 2>&1; then
        echo -e "${RED}校验 initrd (${arch}) 压缩完整性失败，原引导配置未修改。${PLAIN}"
        exit 1
    fi

    [[ -f "${grub_dir}/${grub_file}" ]] || {
        echo -e "${RED}找不到 ${grub_file}。${PLAIN}"
        exit 1
    }
    grub_backup="${grub_dir}/${grub_file}.installnet.$(date +%Y%m%d%H%M%S).bak"
    cp -f "${grub_dir}/${grub_file}" "$grub_backup" || {
        echo -e "${RED}备份 GRUB 失败。${PLAIN}"
        exit 1
    }

    awk '
    /^[[:space:]]*menuentry[[:space:]]/ {
      if (found) exit
      found = 1
      depth = 0
    }
    found {
      print
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") depth--
      }
      if (depth == 0) exit
    }
    ' "${grub_dir}/${grub_file}" > "$read_grub"

    load_num=$(grep -c '^[[:space:]]*menuentry[[:space:]]' "$read_grub" || true)
    if [[ "$load_num" -eq 1 ]]; then
        awk 'NF > 0' "$read_grub" > "$grub_new" || exit 1
    elif [[ "$load_num" -gt 1 ]]; then
        cfg0=$(awk '/^[[:space:]]*menuentry[[:space:]]/ {print NR; exit}' "$read_grub")
        cfg2=$(awk '/^[[:space:]]*menuentry[[:space:]]/ {c++; if (c == 2) {print NR; exit}}' "$read_grub")
        cfg1=''
        for tmp_cfg in $(awk '/}/ {print NR}' "$read_grub"); do
            [[ "$tmp_cfg" -gt "$cfg0" && "$tmp_cfg" -lt "$cfg2" ]] && cfg1="$tmp_cfg"
        done
        [[ -n "$cfg1" ]] || {
            echo -e "${RED}解析 GRUB 菜单失败。${PLAIN}"
            exit 1
        }
        sed -n "${cfg0},${cfg1}p" "$read_grub" > "$grub_new" || exit 1
    else
        echo -e "${RED}未找到可复用的 GRUB 菜单项。${PLAIN}"
        exit 1
    fi

    insert_grub=$(awk '/^[[:space:]]*menuentry[[:space:]]/ {print NR; exit}' "${grub_dir}/${grub_file}")
    [[ -n "$insert_grub" && "$insert_grub" -gt 0 ]] || {
        echo -e "${RED}定位 GRUB 插入位置失败。${PLAIN}"
        exit 1
    }

    existing_kpath=$(grep -E '^[[:space:]]*(linux(efi|16)?|kernel)[[:space:]]+' "$grub_new" | awk '{print $2}' | tail -n1)
    if [[ "$existing_kpath" == */* ]]; then
        grub_boot_prefix="${existing_kpath%/*}"
    else
        grub_boot_prefix=''
    fi
    vmlinuz_grub_path="${grub_boot_prefix}/zero-install-vmlinuz"
    initrd_grub_path="${grub_boot_prefix}/zero-install-initrd.img"

    linux_kernel=$(grep -E '^[[:space:]]*(linux(efi|16)?|kernel)[[:space:]]+' "$grub_new" | awk '{print $1}' | head -n1)
    [[ -n "$linux_kernel" ]] || {
        echo -e "${RED}读取 GRUB 内核项失败。${PLAIN}"
        exit 1
    }
    linux_img=$(grep -E '^[[:space:]]*initrd(efi|16)?[[:space:]]+' "$grub_new" | awk '{print $1}' | tail -n1 || true)
    if [[ -z "$linux_img" ]]; then
        case "$linux_kernel" in
            linuxefi) linux_img='initrdefi' ;;
            linux16)  linux_img='initrd16' ;;
            *)        linux_img='initrd' ;;
        esac
    fi

    console_opts=$(grep -E '^[[:space:]]*(linux(efi|16)?|kernel)[[:space:]]+' "$grub_new" | head -n1 | awk '
        {
            out = ""
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^console=[A-Za-z0-9_,.:\/-]+$/) {
                    out = (out == "" ? $i : out " " $i)
                }
            }
            print out
        }
    ')

    if [[ "$REINSTALL_INSTALLER_FAMILY" == "ipv6" ]]; then
        installer_mac="$REINSTALL_IPV6_MAC"
    else
        installer_mac="$REINSTALL_IPV4_MAC"
    fi
    if [[ -n "$installer_mac" ]]; then
        bootif_opt=" BOOTIF=01-${installer_mac//:/-}"
    fi

    add_option=''
    reinstall_low_mem || add_option=' lowmem=+0'
    boot_option="auto=true priority=critical locale=en_US.UTF-8 keymap=us${add_option}${bootif_opt} hostname=debian domain=${console_opts:+ ${console_opts}} --- quiet${console_opts:+ ${console_opts}}"

    awk -v title="Install OS [${dist} ${arch}]" \
        -v kcmd="$linux_kernel" \
        -v kpath="$vmlinuz_grub_path" \
        -v bopt="$boot_option" \
        -v icmd="$linux_img" \
        -v ipath="$initrd_grub_path" '
        BEGIN {
            print "set default=\"0\""
            header_done = 0
            kernel_done = 0
            initrd_done = 0
        }
        !header_done && /^[[:space:]]*menuentry[[:space:]]/ {
            print "menuentry \047" title "\047 --class debian --class gnu-linux --class gnu --class os {"
            header_done = 1
            next
        }
        /^[[:space:]]*echo[[:space:]].*Loading/ { next }
        !kernel_done && $1 == kcmd {
            print "\t" kcmd "\t" kpath " " bopt
            kernel_done = 1
            next
        }
        !initrd_done && $1 ~ /^initrd(efi|16)?$/ {
            print "\t" icmd "\t" ipath
            initrd_done = 1
            next
        }
        /^[[:space:]]*}[[:space:]]*$/ && kernel_done && !initrd_done {
            print "\t" icmd "\t" ipath
            initrd_done = 1
        }
        { print }
        END { print "" }
    ' "$grub_new" > "${grub_new}.built" && mv -f "${grub_new}.built" "$grub_new" || exit 1

    grub_target=$(readlink -f "${grub_dir}/${grub_file}") || exit 1
    grub_tmp=$(mktemp "${grub_target}.installnet.tmp.XXXXXX") || exit 1
    if ! {
        if (( insert_grub > 1 )); then
            head -n $((insert_grub - 1)) "${grub_dir}/${grub_file}" > "$grub_tmp"
        else
            : > "$grub_tmp"
        fi
    } ||
       ! cat "$grub_new" >> "$grub_tmp" ||
       ! tail -n +"$insert_grub" "${grub_dir}/${grub_file}" >> "$grub_tmp" ||
       ! printf '\nset default="0"\nset timeout=5\n' >> "$grub_tmp" ||
       ! reinstall_validate_grub_config "$grub_tmp"; then
        echo -e "${RED}生成或校验 GRUB 配置失败，原配置未修改。${PLAIN}"
        exit 1
    fi

    rm -rf -- "$boot_work_dir" "$extract_work_dir" && mkdir -p "$boot_work_dir" "$extract_work_dir" || exit 1
    if cpio --version 2>/dev/null | grep -qi 'gnu'; then
        (cd "$extract_work_dir" && gzip -dc "$initrd_dl" 2>/dev/null | cpio -idm --no-absolute-filenames 'var/lib/dpkg/info/netcfg.postinst' './var/lib/dpkg/info/netcfg.postinst' >/dev/null 2>&1) || true
    else
        (cd "$extract_work_dir" && gzip -dc "$initrd_dl" 2>/dev/null | cpio -idm 'var/lib/dpkg/info/netcfg.postinst' './var/lib/dpkg/info/netcfg.postinst' >/dev/null 2>&1) || true
    fi
    if [[ ! -s "${extract_work_dir}/var/lib/dpkg/info/netcfg.postinst" ]]; then
        echo -e "${RED}解包或校验安装镜像失败（非有效 debian-installer 镜像），原引导配置未修改。${PLAIN}"
        exit 1
    fi

    reinstall_write_netcfg_hook "$boot_work_dir" "${extract_work_dir}/var/lib/dpkg/info/netcfg.postinst" || {
        echo -e "${RED}写入安装器网络钩子失败，原引导配置未修改。${PLAIN}"
        exit 1
    }
    rm -rf -- "$extract_work_dir"
    extract_work_dir=''

    reinstall_write_apt_hook "$boot_work_dir" "$is_archive_mirror" || {
        echo -e "${RED}写入安装器 APT 钩子失败，原引导配置未修改。${PLAIN}"
        exit 1
    }
    reinstall_write_post_install_script "$boot_work_dir" || {
        echo -e "${RED}写入安装后置脚本失败，原引导配置未修改。${PLAIN}"
        exit 1
    }

    netcfg_preseed_block=$(reinstall_build_preseed_netcfg)
    partman_early_command="if [ -b ${target_disk} ]; then debconf-set partman-auto/disk ${target_disk}; else debconf-set partman-auto/disk \"\$(list-devices disk | head -n1)\"; fi"

    cat > "${boot_work_dir}/preseed.cfg" <<EOF || { echo -e "${RED}写入 preseed 配置失败。${PLAIN}"; exit 1; }
d-i debconf/priority select critical
d-i lowmem/low note
d-i debian-installer/locale string en_US
d-i console-setup/layoutcode string us
d-i keyboard-configuration/xkb-keymap string us

${netcfg_preseed_block}
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string

d-i hw-detect/load_firmware boolean true

d-i mirror/country string manual
d-i mirror/http/hostname string ${mirror_host}
d-i mirror/http/directory string ${mirror_folder}
d-i mirror/http/proxy string
d-i apt-setup/contrib boolean true
d-i apt-setup/non-free boolean true
${apt_non_free_firmware_line}
${apt_services_line}

d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password ${root_password_hash}

d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean false

d-i partman/early_command string ${partman_early_command}
${efi_partman_lines}
d-i partman/unmount_active boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/mount_style select uuid
d-i partman/choose_partition select finish
d-i partman-auto/method string regular
d-i partman-auto/init_automatically_partition select Guided - use entire disk
d-i partman-auto/choose_recipe select atomic
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

tasksel tasksel/first multiselect standard
d-i pkgsel/include string ${pkgsel_packages}
d-i pkgsel/upgrade select none

popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string ${grub_bootdev}
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
EOF

    if ! (
        set -o pipefail
        cd "$boot_work_dir" &&
            find . | { cpio -H newc -o -R 0:0 2>/dev/null || cpio -H newc -o 2>/dev/null; } | gzip -9 > "$overlay_gz"
    ) || [[ ! -s "$overlay_gz" ]] || ! cat "$overlay_gz" >> "$initrd_dl"; then
        echo -e "${RED}打包安装镜像失败，原引导配置未修改。${PLAIN}"
        exit 1
    fi
    rm -rf -- "$boot_work_dir" "$overlay_gz"
    boot_work_dir=''
    overlay_gz=''

    if ! cp -f "$initrd_dl" "${boot_root}/zero-install-initrd.img" || ! cp -f "$vmlinuz_dl" "${boot_root}/zero-install-vmlinuz"; then
        echo -e "${RED}保存安装镜像失败，原引导配置未修改。${PLAIN}"
        exit 1
    fi
    if [[ "${EUID:-0}" -eq 0 ]]; then
        chown root:root "$grub_tmp" || exit 1
    fi
    chmod 444 "$grub_tmp" || exit 1
    if [[ -f "${grub_dir}/grubenv" ]]; then
        grub-editenv "${grub_dir}/grubenv" unset saved_entry next_entry || {
            echo -e "${RED}清除 GRUB 启动选择失败，原引导配置未修改。${PLAIN}"
            exit 1
        }
    fi
    mv -f -- "$grub_tmp" "$grub_target" || exit 1
    grub_tmp=''

    echo -e "${GREEN}[信息]${PLAIN} 安装引导已写入，系统将在 3 秒后自动重启继续安装。"
    sleep "${REINSTALL_REBOOT_DELAY:-3}"
    reboot || sudo reboot >/dev/null 2>&1
)

reinstall_debian() {
    local debian_version="$1" pw='' pw2='' confirm='' target_disk='' arch='' target_dns='' inline_choice=''
    local REINSTALL_STACK_PREF="${REINSTALL_STACK_PREF:-auto}"

    arch=$(zero_get_arch) || {
        echo -e "${RED}当前重装模块仅支持 amd64/x86_64 与 arm64/aarch64${PLAIN}"
        press_any_key_to_continue
        return 1
    }

    target_disk=$(reinstall_get_target_disk)
    if ! reinstall_validate_target_disk "$target_disk"; then
        press_any_key_to_continue
        return 1
    fi

    reinstall_probe_network_state
    if [[ "$REINSTALL_STACK_PREF" == "auto" ]] && (( REINSTALL_HAS_IPV4 == 1 && REINSTALL_HAS_IPV6 == 1 )); then
        while true; do
            [[ -z "${REINSTALL_NO_CLEAR:-}" ]] && clear
            echo -e "${BLUE}检测到当前主机支持双栈网络，请选择重装网络模式:${PLAIN}"
            echo -e " ${GREEN}1.${PLAIN} 双栈 (IPv4 + IPv6) [默认]"
            echo -e " ${GREEN}2.${PLAIN} 仅 IPv4"
            echo -e " ${GREEN}3.${PLAIN} 仅 IPv6"
            echo -e " ${YELLOW}0.${PLAIN} 返回上级"
            read -r -p "${BLUE} 请选择网络模式 [1-3, 回车默认 1]: ${PLAIN}" inline_choice || [[ -n "$inline_choice" ]] || return 1
            inline_choice=$(trim_input "$inline_choice")
            [[ -z "$inline_choice" ]] && inline_choice='1'
            inline_choice=$(normalize_numeric_choice "$inline_choice")
            case "$inline_choice" in
                1) REINSTALL_STACK_PREF='dual'; break ;;
                2) REINSTALL_STACK_PREF='ipv4'; break ;;
                3) REINSTALL_STACK_PREF='ipv6'; break ;;
                0) return 0 ;;
                *) show_invalid_option "请输入正确数字 [0-3]" "1" ;;
            esac
        done
    fi

    if ! reinstall_resolve_stack_mode "$REINSTALL_STACK_PREF"; then
        echo -e "${RED}${REINSTALL_STACK_ERROR}${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    IFS= read -r -s -p " 请设置 root 密码: " pw
    echo
    [[ -n "$pw" ]] || {
        echo -e "${RED}密码不能为空。${PLAIN}"
        sleep 1
        return 1
    }

    IFS= read -r -s -p " 请再次输入 root 密码: " pw2
    echo
    [[ "$pw" == "$pw2" ]] || {
        echo -e "${RED}两次输入密码不一致。${PLAIN}"
        sleep 1
        return 1
    }

    REINSTALL_SSH_PORT=$(ssh_get_current_port)
    REINSTALL_ROOT_PASSWORD="$pw"
    target_dns=$(reinstall_target_dns_list "$REINSTALL_EFFECTIVE_STACK")

    echo -e "${YELLOW} 将使用 Debian ${debian_version} (${arch}) 执行重装。${PLAIN}"
    echo -e "${YELLOW} 网络模式: $(reinstall_stack_label "$REINSTALL_EFFECTIVE_STACK")${PLAIN}"
    echo -e "${YELLOW} 目标磁盘: ${target_disk:-未检测到}${PLAIN}"
    echo -e "${YELLOW} 重装后 SSH 端口将保持为: ${REINSTALL_SSH_PORT}${PLAIN}"
    echo -e "${YELLOW} 默认 DNS: ${target_dns}${PLAIN}"
    echo -e "${YELLOW} 输入 YES 后将写入安装引导并自动重启。${PLAIN}"
    read -r -p " 输入「YES」确认开始重装，其它键取消: " confirm
    [[ "$confirm" == "YES" ]] || {
        echo -e "${YELLOW} 已取消重装。${PLAIN}"
        sleep 1
        return 0
    }

    if ! reinstall_install_target_system "$debian_version" "$target_disk"; then
        press_any_key_to_continue
        return 1
    fi
}

reinstall_stack_mode_menu() {
    local sub_choice=''
    while true; do
        clear
        reinstall_probe_network_state
        echo -e "${BLUE}————————————网络栈模式————————————${PLAIN}"
        echo -e " 当前主机 IPv4: $( (( REINSTALL_HAS_IPV4 )) && echo "${GREEN}${REINSTALL_IPV4_IFACE} ${REINSTALL_IPV4_ADDR}/${REINSTALL_IPV4_PREFIX}${PLAIN}" || echo "${RED}未检测到${PLAIN}" )"
        echo -e " 当前主机 IPv6: $( (( REINSTALL_HAS_IPV6 )) && echo "${GREEN}${REINSTALL_IPV6_IFACE} ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX}${PLAIN}" || echo "${RED}未检测到${PLAIN}" )"
        echo -e " 当前选择模式: ${GREEN}$(reinstall_stack_label "${REINSTALL_STACK_PREF:-auto}")${PLAIN}"
        echo -e "${BLUE}——————————————————————————————————${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 自动识别 (推荐)"
        echo -e " ${GREEN}2.${PLAIN} 双栈 (IPv4 + IPv6)"
        echo -e " ${GREEN}3.${PLAIN} 仅 IPv4"
        echo -e " ${GREEN}4.${PLAIN} 仅 IPv6"
        echo -e " ${YELLOW}0.${PLAIN} 返回上级\n"
        sub_choice=$(read_menu_choice " 请输入数字 [0-4]: ") || return 1
        case "$sub_choice" in
            1) REINSTALL_STACK_PREF='auto'; return 0 ;;
            2)
                if (( REINSTALL_HAS_IPV4 != 1 || REINSTALL_HAS_IPV6 != 1 )); then
                    echo -e "${RED}当前主机未同时具备可用的公网 IPv4 与 IPv6，无法选择「双栈」模式${PLAIN}"
                    sleep 1.2
                else
                    REINSTALL_STACK_PREF='dual'
                    return 0
                fi
                ;;
            3)
                if (( REINSTALL_HAS_IPV4 != 1 )); then
                    echo -e "${RED}当前主机未检测到可用的公网 IPv4，无法选择「仅 IPv4」模式${PLAIN}"
                    sleep 1.2
                else
                    REINSTALL_STACK_PREF='ipv4'
                    return 0
                fi
                ;;
            4)
                if (( REINSTALL_HAS_IPV6 != 1 )); then
                    echo -e "${RED}当前主机未检测到可用的公网 IPv6，无法选择「仅 IPv6」模式${PLAIN}"
                    sleep 1.2
                else
                    REINSTALL_STACK_PREF='ipv6'
                    return 0
                fi
                ;;
            0) return 0 ;;
            *) show_invalid_option "请输入正确数字 [0-4]" "1" ;;
        esac
    done
}

reinstall_main_loop() {
    local num='' arch='' boot_mode='BIOS' detected_desc='' mode_display=''
    arch=$(zero_get_arch || uname -m)
    if reinstall_is_efi || [[ "$arch" == "arm64" ]]; then
        boot_mode='UEFI'
    fi
    while true; do
        reinstall_probe_network_state
        if (( REINSTALL_HAS_IPV4 == 1 && REINSTALL_HAS_IPV6 == 1 )); then
            detected_desc="${GREEN}双栈${PLAIN} (v4: ${REINSTALL_IPV4_ADDR}/${REINSTALL_IPV4_PREFIX} | v6: ${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX})"
        elif (( REINSTALL_HAS_IPV4 == 1 )); then
            detected_desc="${GREEN}仅 IPv4${PLAIN} (${REINSTALL_IPV4_ADDR}/${REINSTALL_IPV4_PREFIX})"
        elif (( REINSTALL_HAS_IPV6 == 1 )); then
            detected_desc="${GREEN}仅 IPv6${PLAIN} (${REINSTALL_IPV6_ADDR}/${REINSTALL_IPV6_PREFIX})"
        else
            detected_desc="${RED}未检测到可用公网网络${PLAIN}"
        fi

        if reinstall_resolve_stack_mode "${REINSTALL_STACK_PREF:-auto}"; then
            if [[ "${REINSTALL_STACK_PREF:-auto}" == "auto" ]]; then
                mode_display="${GREEN}自动识别 -> $(reinstall_stack_label "$REINSTALL_EFFECTIVE_STACK")${PLAIN}"
            else
                mode_display="${GREEN}$(reinstall_stack_label "$REINSTALL_EFFECTIVE_STACK")${PLAIN}"
            fi
        else
            mode_display="${RED}$(reinstall_stack_label "${REINSTALL_STACK_PREF:-auto}") (不可用)${PLAIN}"
        fi

        clear
        echo -e "${BLUE}一键网络重装管理脚本${PLAIN}"
        echo -e " 当前架构: ${GREEN}${arch} (${boot_mode})${PLAIN}"
        echo -e " 主机网络: ${detected_desc}"
        echo -e " 重装模式: ${mode_display}\n"
        echo -e "${BLUE}————————————重装系统————————————${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 重装 Debian 11 (Bullseye)"
        echo -e " ${GREEN}2.${PLAIN} 重装 Debian 12 (Bookworm)"
        echo -e " ${GREEN}3.${PLAIN} 重装 Debian 13 (Trixie)"
        echo -e " ${GREEN}4.${PLAIN} 切换网络模式 (仅v4 / 仅v6 / 双栈)"
        echo -e " ${YELLOW}0.${PLAIN} 返回菜单\n"

        num=$(read_menu_choice " 请输入数字 [0-4]: ") || return 1
        case "$num" in
            1) reinstall_debian 11 ;;
            2) reinstall_debian 12 ;;
            3) reinstall_debian 13 ;;
            4) reinstall_stack_mode_menu ;;
            0) break ;;
            *) show_invalid_option "请输入正确数字 [0-4]" "1" ;;
        esac
    done
}

reinstall_menu() {
    local d
    for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
        case ":$PATH:" in *":$d:"*) ;; *) PATH="${PATH:+$PATH:}$d" ;; esac
    done
    export PATH
    reinstall_check_sys
    [[ "$EUID" -ne '0' ]] && echo -e "${RED}请使用 root 权限运行此脚本${PLAIN}" && return
    [[ -z "${reinstall_release:-}" ]] && echo -e "${RED}暂不支持当前系统${PLAIN}" && press_any_key_to_continue && return
    if ! zero_get_arch >/dev/null 2>&1; then
        echo -e "${RED}当前重装模块仅支持 amd64/x86_64 与 arm64/aarch64${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    if ! reinstall_install_dependencies; then
        echo -e "${RED}重装依赖安装失败,已停止本次操作${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    reinstall_main_loop
}

tz_is_valid() {
    local tz="$1"
    [[ -n "$tz" && "$tz" != /* && "$tz" != *..* && ! "$tz" =~ [[:space:]] ]] || return 1
    [[ -f "/usr/share/zoneinfo/$tz" ]] && return 0
    timedatectl list-timezones 2>/dev/null | grep -Fxq -- "$tz"
}

tz_get_system() {
    local sys_tz=""
    if [[ -L /etc/localtime ]]; then
        sys_tz=$(readlink /etc/localtime 2>/dev/null || true)
        [[ "$sys_tz" == */zoneinfo/* ]] && sys_tz="${sys_tz##*/zoneinfo/}" || sys_tz=""
    fi
    [[ -n "$sys_tz" ]] || sys_tz=$(trim_input "$(timedatectl show -p Timezone --value 2>/dev/null)")
    printf '%s\n' "${sys_tz:-未知}"
}

tz_get_zone_tab() {
    local zone_tab="/usr/share/zoneinfo/zone1970.tab"
    [[ -f "$zone_tab" ]] || zone_tab="/usr/share/zoneinfo/zone.tab"
    [[ -f "$zone_tab" ]] || return 1
    printf '%s\n' "$zone_tab"
}

tz_fetch_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -A 'Zero.sh/2.4' -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -U 'Zero.sh/2.4' -qO- --timeout=5 --tries=1 "$url" 2>/dev/null
    else
        return 1
    fi
}

tz_detect_recommended() {
    local tz=""
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo -e "${YELLOW}未安装 curl 或 wget，无法自动检测时区${PLAIN}" >&2
        return 1
    fi

    tz=$(tz_fetch_url 'https://ipwho.is/?fields=timezone.id' \
        | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1)
    tz=$(trim_input "$tz")
    if ! tz_is_valid "$tz"; then
        tz=$(tz_fetch_url 'https://ipapi.co/timezone' | head -n1)
        tz=$(trim_input "$tz")
        tz_is_valid "$tz" || return 1
    fi
    printf '%s\n' "$tz"
}

tz_apply() {
    local tz="$1" skip_validate="${2:-0}"
    if (( skip_validate == 0 )) && ! tz_is_valid "$tz"; then
        echo -e "${RED}无效的时区名称: ${tz}${PLAIN}"
        return 1
    fi

    echo -e "${YELLOW}正在设置时区为 ${tz} ...${PLAIN}"
    if timedatectl set-timezone "$tz"; then
        echo -e "${GREEN}✔ 设置成功! 当前时间: $(date)${PLAIN}"
        return 0
    fi

    echo -e "${RED}✘ 设置失败${PLAIN}"
    return 1
}

change_timezone() {
    local choice input_code zone_tab tz_idx sel_tz manual_tz detected_tz sys_tz pause_after i
    local -a lines=()

    if ! command -v timedatectl >/dev/null 2>&1; then
        echo -e "${RED}未安装 timedatectl,无法自动设置时区${PLAIN}"
        press_any_key_to_continue
        return
    fi

    while true; do
        pause_after=0
        sys_tz=$(tz_get_system)
        clear
        echo -e "${BLUE}======= 时区管理 =====${PLAIN}"
        echo -e "${YELLOW}当前 ${sys_tz}${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}自动检测  ${GREEN}2.${PLAIN}国家代码"
        echo -e "${GREEN}3.${PLAIN}手动输入  ${YELLOW}0.${PLAIN}返回菜单"
        echo -e "${BLUE}======================${PLAIN}"

        choice=$(read_menu_choice "请输入选项 [0-3]: ") || return 1

        case "$choice" in
            1)
                echo -e "${YELLOW}正在检测时区...${PLAIN}"
                detected_tz=$(tz_detect_recommended || true)
                if [[ -n "$detected_tz" ]]; then
                    echo -e "${GREEN}检测结果: ${detected_tz}${PLAIN}"
                    tz_apply "$detected_tz" 1
                else
                    echo -e "${YELLOW}自动检测失败，请使用国家代码或手动输入${PLAIN}"
                fi
                pause_after=1
                ;;
            2)
                clear
                read -r -p "${BLUE}请输入国家代码 (如 CN,US,JP): ${PLAIN}" input_code || return 1
                input_code=$(trim_input "$input_code")
                input_code=$(printf '%s' "$input_code" | tr '[:lower:]' '[:upper:]')
                [[ -z "$input_code" ]] && continue
                if [[ ! "$input_code" =~ ^[A-Z]{2}$ ]]; then
                    echo -e "${RED}国家代码必须是两个英文字母${PLAIN}"
                    press_any_key_to_continue
                    continue
                fi

                zone_tab=$(tz_get_zone_tab || true)
                if [[ -z "$zone_tab" ]]; then
                    echo -e "${RED}系统缺失时区索引文件 (zone1970.tab/zone.tab)，无法自动列表。${PLAIN}"
                    pause_after=1
                else
                    lines=()
                    mapfile -t lines < <(awk -v code="$input_code" '$1 !~ /^#/ && $1 ~ ("(^|,)" code "(,|$)") {print $3}' "$zone_tab" | sort -u)

                    if (( ${#lines[@]} == 0 )); then
                        echo -e "${RED}未找到代码 [$input_code] 对应的时区信息。${PLAIN}"
                        sleep 1
                        continue
                    fi

                    echo -e "${BLUE}=== [$input_code] 可选时区 ===${PLAIN}"
                    for i in "${!lines[@]}"; do
                        echo -e "  ${GREEN}$((i+1)).${PLAIN} ${lines[$i]}"
                    done
                    echo -e "${BLUE}==========================${PLAIN}"

                    tz_idx=$(read_menu_choice "请选择编号: ") || return 1
                    if valid_list_index "$tz_idx" "${#lines[@]}"; then
                        sel_tz="${lines[$((tz_idx-1))]}"
                        tz_apply "$sel_tz" 1
                    else
                        echo -e "${RED}无效编号${PLAIN}"
                    fi
                    pause_after=1
                fi
                ;;
            3)
                read -r -p "${BLUE}请输入时区全称 (例: Asia/Shanghai): ${PLAIN}" manual_tz || return 1
                manual_tz=$(trim_input "$manual_tz")
                if [[ -n "$manual_tz" ]]; then
                    tz_apply "$manual_tz"
                fi
                pause_after=1
                ;;
            0)
                return
                ;;
            *)
                show_invalid_option
                ;;
        esac
        (( pause_after == 1 )) && press_any_key_to_continue
    done
}

GAI_CONF_PATH="/etc/gai.conf"
GAI_BACKUP_PATH="/etc/gai.conf.zero.bak"
GAI_MANAGED_BEGIN="# Zero.sh IP Priority BEGIN"
GAI_MANAGED_END="# Zero.sh IP Priority END"

ip_priority_inspect() {
    local conf="${1:-$GAI_CONF_PATH}"
    [[ -f "$conf" ]] || {
        printf 'default|0|0\n'
        return 0
    }
    awk -v begin="$GAI_MANAGED_BEGIN" -v end="$GAI_MANAGED_END" '
        $0 == begin { in_zero = 1; has_zero = 1; next }
        $0 == end   { in_zero = 0; next }
        in_zero && $0 ~ /^precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100[[:space:]]*$/ { v4 = 1 }
        in_zero && $0 ~ /^precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+10[[:space:]]*$/  { v6 = 1 }
        !in_zero && $0 ~ /^[[:space:]]*precedence[[:space:]]+/ { unmanaged = 1 }
        END {
            if (v4) label = "IPv4 优先"
            else if (v6) label = "IPv6 优先"
            else if (has_zero) label = "Zero.sh 自定义"
            else if (unmanaged) label = "用户自定义"
            else label = "IPv6 优先（系统默认）"
            printf "%s|%d|%d\n", label, has_zero, unmanaged
        }
    ' "$conf"
}

ip_priority_write_config() {
    local mode="$1" conf="${2:-$GAI_CONF_PATH}" backup="${3:-$GAI_BACKUP_PATH}"
    local temp_file ipv4_precedence=""

    case "$mode" in
        ipv4) ipv4_precedence=100 ;;
        ipv6) ipv4_precedence=10 ;;
        default) ipv4_precedence="" ;;
        *) return 1 ;;
    esac

    temp_file=$(mktemp "${conf}.zero.XXXXXX") || return 1
    if [[ -f "$conf" ]]; then
        if [[ ! -f "$backup" ]] && ! grep -Fxq "$GAI_MANAGED_BEGIN" "$conf" 2>/dev/null; then
            cp -p "$conf" "$backup" 2>/dev/null || cp "$conf" "$backup" || { rm -f "$temp_file"; return 1; }
        fi
        if ! awk -v begin="$GAI_MANAGED_BEGIN" -v end="$GAI_MANAGED_END" '
            $0 == begin { managed = 1; next }
            $0 == end   { managed = 0; next }
            !managed    { print }
            END         { if (managed) exit 1 }
        ' "$conf" > "$temp_file"; then
            rm -f "$temp_file"
            echo -e "${RED}检测到不完整的 Zero.sh 配置块，未修改 ${conf}${PLAIN}"
            return 1
        fi
    else
        : > "$temp_file"
    fi

    if [[ -n "$ipv4_precedence" ]]; then
        {
            echo
            echo "$GAI_MANAGED_BEGIN"
            echo "precedence ::1/128 50"
            echo "precedence ::/0 40"
            echo "precedence 2002::/16 30"
            echo "precedence ::/96 20"
            echo "precedence ::ffff:0:0/96 ${ipv4_precedence}"
            echo "precedence 2001::/32 5"
            echo "precedence fc00::/7 3"
            echo "$GAI_MANAGED_END"
        } >> "$temp_file" || { rm -f "$temp_file"; return 1; }
    fi

    chmod 644 "$temp_file" && mv -f "$temp_file" "$conf" || {
        rm -f "$temp_file"
        return 1
    }
}

set_ip_priority() {
    local choice state_line current_priority has_managed has_unmanaged mode label

    while true; do
        clear
        state_line=$(ip_priority_inspect "$GAI_CONF_PATH")
        IFS='|' read -r current_priority has_managed has_unmanaged <<< "$state_line"
        [[ "$current_priority" == "default" ]] && current_priority="IPv6 优先（系统默认）"

        echo -e "${BLUE}=== IP连接优先级 ===${PLAIN}"
        echo -e "${YELLOW}当前优先级: ${GREEN}${current_priority}${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}IPv4优先"
        echo -e "${GREEN}2.${PLAIN}IPv6优先"
        echo -e "${GREEN}3.${PLAIN}系统默认"
        echo -e "${YELLOW}0.${PLAIN}返回菜单"
        echo -e "${BLUE}======================${PLAIN}"
        choice=$(read_menu_choice "请输入选项 [0-3]: ") || return 1

        mode=""
        label=""
        case "$choice" in
            1) mode="ipv4"; label="IPv4优先" ;;
            2) mode="ipv6"; label="IPv6优先" ;;
            3) mode="default"; label="IPv6优先（系统默认）" ;;
            0) return ;;
            *) show_invalid_option; continue ;;
        esac

        if [[ "$mode" == "default" && "$has_managed" == "0" ]]; then
            if [[ "$has_unmanaged" == "1" ]]; then
                echo -e "${YELLOW}当前由用户自定义规则管理，Zero.sh 没有可移除的配置${PLAIN}"
            else
                echo -e "${GREEN}当前已是 IPv6 优先（系统默认）${PLAIN}"
            fi
            press_any_key_to_continue
            continue
        fi

        if ip_priority_write_config "$mode" "$GAI_CONF_PATH" "$GAI_BACKUP_PATH"; then
            if [[ "$mode" == "default" && "$has_unmanaged" == "1" ]]; then
                echo -e "${GREEN}✔ 已移除 Zero.sh 设置，保留用户自定义规则${PLAIN}"
            else
                echo -e "${GREEN}✔ 已设置为 ${label}${PLAIN}"
            fi
            [[ -f "$GAI_BACKUP_PATH" ]] && echo -e "${YELLOW}备份: ${GAI_BACKUP_PATH}${PLAIN}"
        else
            echo -e "${RED}✘ IP 连接优先级设置失败${PLAIN}"
        fi
        press_any_key_to_continue
    done
}

BBR_SYSCTL_CONF="/etc/sysctl.d/99-bbr-ultimate.conf"
BBR_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
BBR_REPO_FILE="/etc/apt/sources.list.d/xanmod-release.list"
BBR_PERSIST_SERVICE="/etc/systemd/system/bbr-optimize-persist.service"
BBR_PERSIST_SERVICE_NAME="bbr-optimize-persist.service"
BBR_PERSIST_SCRIPT="/usr/local/bin/bbr-optimize-apply.sh"
BBR_SPEEDTEST_BIN="/usr/local/bin/speedtest"
BBR_SPEEDTEST_MARKER="/usr/local/bin/.zero-bbr-speedtest.sha256"

bbr_get_speedtest_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

bbr_confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    read -r -p "$prompt" answer || return 2
    answer=$(trim_input "$answer")
    [[ -z "$answer" ]] && answer="$default"
    [[ "$answer" =~ ^[Yy]$ ]]
}

bbr_fail_and_pause() {
    local message="$1"
    echo -e "${RED}${message}${PLAIN}"
    press_any_key_to_continue
    return 1
}

bbr_prompt_reboot() {
    if bbr_confirm "现在重启服务器使配置生效吗？(Y/N): "; then
        reboot_vps
    else
        echo -e "${YELLOW}已取消,请稍后手动执行 reboot${PLAIN}"
    fi
}

bbr_xanmod_installed() {
    if compgen -G '/boot/vmlinuz-*' >/dev/null 2>&1; then
        compgen -G '/boot/vmlinuz-*xanmod*' >/dev/null 2>&1
        return $?
    fi
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${db:Status-Abbrev}\n' 'linux-image-*xanmod*' 2>/dev/null | grep -q '^ii'
}

bbr_read_sysctl_val() {
    local proc_path="$1" key="$2" val=""
    if [[ -r "$proc_path" ]]; then
        IFS= read -r val < "$proc_path"
    else
        val=$(sysctl -n "$key" 2>/dev/null)
    fi
    printf '%s\n' "$val"
}

bbr_read_runtime_status() {
    local current_kernel xanmod_installed="no"
    current_kernel=$(uname -r 2>/dev/null)
    bbr_xanmod_installed "$current_kernel" && xanmod_installed="yes"
    printf '%s\n' \
        "$current_kernel" \
        "$(bbr_read_sysctl_val /proc/sys/net/ipv4/tcp_congestion_control net.ipv4.tcp_congestion_control)" \
        "$(bbr_read_sysctl_val /proc/sys/net/core/default_qdisc net.core.default_qdisc)" \
        "$(bbr_read_sysctl_val /proc/sys/net/ipv4/tcp_available_congestion_control net.ipv4.tcp_available_congestion_control)" \
        "$xanmod_installed"
}

bbr_cpu_has_flags() {
    local flags needle
    flags=$(awk -F': ' '/^flags[[:space:]]*:/ {print tolower($2); exit}' /proc/cpuinfo 2>/dev/null)
    [[ -n "$flags" ]] || return 1

    for needle in "$@"; do
        case " $flags " in
            *" ${needle} "*) ;;
            *) return 1 ;;
        esac
    done
}

bbr_detect_x86_64_level_local() {
    if ! bbr_cpu_has_flags cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2; then
        echo 1
        return 0
    fi

    if ! bbr_cpu_has_flags avx avx2 bmi1 bmi2 f16c fma movbe xsave; then
        echo 2
        return 0
    fi

    if ! bbr_cpu_has_flags abm && ! bbr_cpu_has_flags lzcnt; then
        echo 2
        return 0
    fi

    if ! bbr_cpu_has_flags avx512f avx512bw avx512cd avx512dq avx512vl; then
        echo 3
        return 0
    fi

    echo 4
}

bbr_ensure_apt_packages() {
    local missing_packages=()
    local package check_cmd

    for package in "$@"; do
        check_cmd="$package"
        case "$package" in
            gnupg) check_cmd="gpg" ;;
            ca-certificates) check_cmd="update-ca-certificates" ;;
        esac

        if ! command -v "$check_cmd" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    [[ "${#missing_packages[@]}" -eq 0 ]] && return 0

    echo -e "${YELLOW}正在更新软件仓库...${PLAIN}"
    ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get update ) || return 1

    echo -e "${YELLOW}正在安装依赖: ${missing_packages[*]}${PLAIN}"
    ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}" ) || return 1
}

bbr_select_xanmod_package() {
    local version="$1" package_name package_hint="" candidate_version
    local -a packages=()

    case "$version" in
        1) packages=("linux-xanmod-lts-x64v1") ;;
        2) packages=("linux-xanmod-x64v2" "linux-xanmod-lts-x64v2") ;;
        3|4) packages=("linux-xanmod-x64v3" "linux-xanmod-lts-x64v3") ;;
        *) return 1 ;;
    esac

    for package_name in "${packages[@]}"; do
        candidate_version=$(apt-cache policy "$package_name" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
        [[ -z "$candidate_version" || "$candidate_version" == "(none)" ]] && continue
        case "$package_name" in
            linux-xanmod-lts-x64v1) package_hint="x64v1 仅提供 LTS 包，已自动切换到 LTS" ;;
            linux-xanmod-lts-x64v2) package_hint="当前仓库仅提供 LTS 分支，已自动切换到 x64v2 LTS" ;;
            linux-xanmod-lts-x64v3) package_hint="当前仓库仅提供 LTS 分支，已自动切换到 x64v3 LTS" ;;
            linux-xanmod-x64v2)     package_hint="x64v2" ;;
            linux-xanmod-x64v3)     package_hint="x64v${version} 检测结果，按官方建议安装 x64v3" ;;
        esac
        echo "${package_name}|${package_hint}"
        return 0
    done
    return 1
}

bbr_fetch_xanmod_key() {
    local output_file="$1" log_file="$2"
    if curl -fsSL --connect-timeout 8 --max-time 20 "https://dl.xanmod.org/archive.key" -o "$output_file" >"$log_file" 2>&1 && [[ -s "$output_file" ]]; then
        return 0
    fi
    curl -fsSL --connect-timeout 8 --max-time 20 "https://gitlab.com/afrd.gpg" -o "$output_file" >>"$log_file" 2>&1 && [[ -s "$output_file" ]]
}

bbr_check_disk_space() {
    local required_gb="$1"
    local required_space_mb=$((required_gb * 1024))
    local available_space_mb
    available_space_mb=$(df -m / | awk 'NR==2 {print $4}')

    if (( available_space_mb >= required_space_mb )); then
        return 0
    fi

    echo -e "${YELLOW}警告: 磁盘空间不足${PLAIN}"
    echo -e "当前可用: ${GREEN}$((available_space_mb / 1024))G${PLAIN} | 最低需求: ${GREEN}${required_gb}G${PLAIN}"
    bbr_confirm "是否继续？(Y/N): "
}

bbr_check_and_prepare_swap() {
    local total_ram total_swap managed_swap recommend_swap other_swap target_swapfile
    total_ram=$(free -m | awk '/Mem:/ {print $2}')
    total_swap=$(get_current_swap_mb)
    managed_swap=$(get_managed_swap_mb)
    recommend_swap=$(swap_recommended_for_ram_mb "$total_ram")

    if (( total_swap >= recommend_swap )); then
        return 0
    fi

    other_swap=$((total_swap - managed_swap))
    target_swapfile=$((recommend_swap - other_swap))
    if (( target_swapfile < 128 )); then
        target_swapfile=128
    fi

    echo -e "${YELLOW}检测到虚拟内存（SWAP）需要优化${PLAIN}"
    echo -e "物理内存: ${GREEN}${total_ram}MB${PLAIN} | 总Swap: ${GREEN}${total_swap}MB${PLAIN} | 推荐: ${GREEN}${recommend_swap}MB${PLAIN}"
    echo -e "文件Swap: ${GREEN}${managed_swap}MB${PLAIN} -> ${GREEN}${target_swapfile}MB${PLAIN}（仅管理 ${swapfile_path}）"

    if bbr_confirm "是否现在配置虚拟内存？(Y/N): "; then
        set_swap "$target_swapfile" || return 1
    else
        [[ $? -ne 2 ]] || return 1
        echo -e "${YELLOW}已跳过虚拟内存配置${PLAIN}"
    fi
}

bbr_fetch_text_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        return 1
    fi
}

bbr_download_url_to_file() {
    local url="$1" output_file="$2" show_progress="${3:-0}"
    if command -v curl >/dev/null 2>&1; then
        if (( show_progress == 1 )) && [[ -t 2 ]]; then
            curl -fL --progress-bar "$url" -o "$output_file"
        else
            curl -fsSL "$url" -o "$output_file"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if (( show_progress == 1 )) && [[ -t 2 ]]; then
            wget --show-progress -q "$url" -O "$output_file" || wget "$url" -O "$output_file" >&2
        else
            wget -q "$url" -O "$output_file"
        fi
    else
        return 1
    fi
}

bbr_get_speedtest_download_url() {
    local speedtest_arch="$1" page_content download_url
    page_content=$(bbr_fetch_text_url "https://speedtest-static-dev.speedtest.dev/apps/cli") || return 1
    download_url=$(printf '%s\n' "$page_content" | grep -Eo "https://install\\.speedtest\\.net/app/cli/ookla-speedtest-[0-9.]+-linux-${speedtest_arch}\\.tgz" | head -n 1)
    [[ -n "$download_url" ]] || return 1
    echo "$download_url"
}

bbr_install_speedtest_from_url() {
    local download_url="$1" speedtest_tmp bin_dir="${BBR_SPEEDTEST_BIN%/*}"
    speedtest_tmp=$(mktemp -d) || return 1

    echo -e "${BLUE}正在下载测速组件 (${download_url##*/})...${PLAIN}" >&2
    if ! bbr_download_url_to_file "$download_url" "${speedtest_tmp}/speedtest.tgz" 1 ||
       ! tar -xzf "${speedtest_tmp}/speedtest.tgz" -C "$speedtest_tmp" ||
       { [[ ! -d "$bin_dir" ]] && ! install -d -m 0755 "$bin_dir"; } ||
       ! install -m 0755 "${speedtest_tmp}/speedtest" "$BBR_SPEEDTEST_BIN"; then
        rm -rf "$speedtest_tmp"
        return 1
    fi

    if [[ -x "$BBR_SPEEDTEST_BIN" ]] && command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$BBR_SPEEDTEST_BIN" 2>/dev/null | awk '{print $1}' > "$BBR_SPEEDTEST_MARKER" 2>/dev/null || true
    fi
    hash -r 2>/dev/null || true
    rm -rf "$speedtest_tmp"
    echo -e "${GREEN}speedtest 临时安装完成${PLAIN}" >&2
}

bbr_cleanup_managed_speedtest() {
    [[ -f "$BBR_SPEEDTEST_MARKER" ]] || return 0

    if [[ ! -e "$BBR_SPEEDTEST_BIN" ]]; then
        rm -f "$BBR_SPEEDTEST_MARKER"
        return 0
    fi

    command -v sha256sum >/dev/null 2>&1 || {
        rm -f "$BBR_SPEEDTEST_MARKER"
        return 0
    }

    local expected current
    expected=$(head -n 1 "$BBR_SPEEDTEST_MARKER" 2>/dev/null)
    current=$(sha256sum "$BBR_SPEEDTEST_BIN" 2>/dev/null | awk '{print $1}')
    if [[ -n "$expected" && "$expected" == "$current" ]]; then
        rm -f "$BBR_SPEEDTEST_BIN"
        hash -r 2>/dev/null || true
    fi
    rm -f "$BBR_SPEEDTEST_MARKER"
}

bbr_ensure_speedtest() {
    local cpu_arch speedtest_arch download_url
    cpu_arch=$(uname -m)
    speedtest_arch=$(bbr_get_speedtest_arch) || {
        echo -e "${RED}错误: 不支持的架构 ${cpu_arch}${PLAIN}" >&2
        return 1
    }

    if command -v speedtest >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}speedtest 未安装，正在临时安装...${PLAIN}" >&2
    download_url=$(bbr_get_speedtest_download_url "$speedtest_arch" 2>/dev/null || true)
    if [[ -z "$download_url" ]]; then
        download_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${speedtest_arch}.tgz"
    fi

    bbr_install_speedtest_from_url "$download_url" || return 1
}

bbr_detect_bandwidth() {
    local bw_choice="" preset_choice="" manual_bandwidth=""
    echo -e "${BLUE}======== BBR调优 ========${PLAIN}" >&2
    echo -e "${GREEN}1.${PLAIN}自动检测    ${GREEN}2.${PLAIN}预设档位" >&2
    echo -e "${GREEN}3.${PLAIN}恢复网络    ${YELLOW}0.${PLAIN}返回上级" >&2
    echo -e "${BLUE}==========================${PLAIN}" >&2
    bw_choice=$(read_menu_choice "请输入选项 [0-3, 默认1]: ") || return 2
    bw_choice=${bw_choice:-1}

    case "$bw_choice" in
        0)
            return 2
            ;;
        1)
            bbr_ensure_speedtest >/dev/null || {
                echo -e "${RED}测速工具安装失败，请选择预设或自定义带宽${PLAIN}" >&2
                bbr_cleanup_managed_speedtest
                return 1
            }
            echo -e "${YELLOW}正在运行 speedtest 自动测速...${PLAIN}" >&2

            local speedtest_output upload_speed upload_mbps
            if ! speedtest_output=$(speedtest --accept-license --accept-gdpr 2>&1); then
                printf '%s\n' "$speedtest_output" >&2
                echo -e "${RED}测速失败，请选择预设或自定义带宽${PLAIN}" >&2
                bbr_cleanup_managed_speedtest
                return 1
            fi
            printf '%s\n' "$speedtest_output" >&2
            upload_speed=$(printf '%s\n' "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n 1)
            upload_mbps=${upload_speed%.*}
            if [[ ! "$upload_mbps" =~ ^[0-9]+$ ]] || (( upload_mbps <= 0 )); then
                echo -e "${RED}无法读取上传带宽，请选择预设或自定义带宽${PLAIN}" >&2
                bbr_cleanup_managed_speedtest
                return 1
            fi

            echo -e "${GREEN}检测到上传带宽: ${upload_mbps} Mbps${PLAIN}" >&2
            bbr_cleanup_managed_speedtest
            echo "$upload_mbps"
            ;;
        2)
            local -a presets=(100 200 300 500 700 1000 1500 2000 2500)
            local idx
            for idx in "${!presets[@]}"; do
                echo "$((idx + 1)). ${presets[$idx]} Mbps" >&2
            done
            echo "10. 自定义输入" >&2
            read -r -p "请输入选择 [6]: " preset_choice || return 2
            preset_choice=$(trim_input "$preset_choice")
            preset_choice=${preset_choice:-6}
            if [[ "$preset_choice" =~ ^[1-9]$ ]]; then
                echo "${presets[$((preset_choice - 1))]}"
            elif [[ "$preset_choice" == "10" ]]; then
                read -r -p "请输入带宽值（Mbps）: " manual_bandwidth || return 2
                manual_bandwidth=$(trim_input "$manual_bandwidth")
                [[ "$manual_bandwidth" =~ ^[0-9]+$ ]] && (( manual_bandwidth > 0 )) || return 1
                echo "$manual_bandwidth"
            else
                return 1
            fi
            ;;
        3) return 3 ;;
        *) return 1 ;;
    esac
}

bbr_profile_label() {
    case "$1" in
        download) echo "下载增强" ;;
        *) echo "代理均衡" ;;
    esac
}

bbr_buffer_memory_cap_mb() {
    local mem_total="$1"
    local profile="${2:-balanced}"

    if ! [[ "$mem_total" =~ ^[0-9]+$ ]] || (( mem_total <= 0 )); then
        [[ "$profile" == "download" ]] && echo 96 || echo 64
        return 0
    fi

    if (( mem_total < 512 )); then
        [[ "$profile" == "download" ]] && echo 16 || echo 12
    elif (( mem_total < 768 )); then
        [[ "$profile" == "download" ]] && echo 32 || echo 24
    elif (( mem_total < 1024 )); then
        [[ "$profile" == "download" ]] && echo 64 || echo 48
    elif (( mem_total < 2048 )); then
        [[ "$profile" == "download" ]] && echo 80 || echo 64
    elif (( mem_total < 4096 )); then
        [[ "$profile" == "download" ]] && echo 96 || echo 80
    elif [[ "$profile" == "download" ]]; then
        echo 128
    else
        echo 96
    fi
}

bbr_calculate_buffer_size() {
    local bandwidth="$1"
    local region="${2:-asia}"
    local profile="${3:-balanced}"
    local mem_total="${4:-0}"
    local buffer_mb=0 table="" item limit val

    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || (( bandwidth <= 0 )); then
        case "$profile:$region" in
            download:overseas) buffer_mb=48 ;;
            download:*)        buffer_mb=24 ;;
            *:overseas)        buffer_mb=32 ;;
            *)                 buffer_mb=16 ;;
        esac
    else
        case "$profile:$region" in
            download:overseas) table="100:8 200:16 300:24 500:32 700:40 1000:48 1500:64 2500:80 *:96" ;;
            download:*)        table="100:6 200:8 300:12 500:16 700:20 1000:24 1500:32 2000:40 2500:48 *:64" ;;
            *:overseas)        table="100:8 200:12 300:16 500:20 700:28 1000:32 1500:40 *:48" ;;
            *)                 table="100:4 200:6 300:8 500:10 700:12 1000:16 1500:20 2000:24 *:32" ;;
        esac
        for item in $table; do
            limit="${item%:*}"
            val="${item#*:}"
            if [[ "$limit" == "*" ]] || (( bandwidth <= limit )); then
                buffer_mb="$val"
                break
            fi
        done
    fi

    local raw_buffer_mb mem_cap profile_label
    raw_buffer_mb="$buffer_mb"
    mem_cap=$(bbr_buffer_memory_cap_mb "$mem_total" "$profile")
    if [[ "$mem_cap" =~ ^[0-9]+$ ]] && (( buffer_mb > mem_cap )); then
        echo -e "${YELLOW}内存保护: 按带宽/地区计算 ${raw_buffer_mb}MB，物理内存 ${mem_total}MB，上限 ${mem_cap}MB${PLAIN}" >&2
        buffer_mb="$mem_cap"
    fi

    profile_label=$(bbr_profile_label "$profile")
    echo -e "${YELLOW}推荐缓冲区(${profile_label}): ${GREEN}${buffer_mb}MB${PLAIN}${YELLOW}（带宽/地区: ${raw_buffer_mb}MB，内存上限: ${mem_cap}MB）${PLAIN}" >&2
    if bbr_confirm "是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: " "Y"; then
        echo "$buffer_mb"
    else
        [[ "$?" == 2 ]] && return 1
        local custom_buffer
        read -r -p "请输入自定义缓冲区大小（MB）[${buffer_mb}]: " custom_buffer || return 1
        custom_buffer=$(trim_input "$custom_buffer")
        if [[ "$custom_buffer" =~ ^[0-9]+$ ]] && (( custom_buffer > 0 && custom_buffer <= 512 )); then
            if [[ "$mem_cap" =~ ^[0-9]+$ ]] && (( custom_buffer > mem_cap )); then
                echo -e "${YELLOW}内存保护: 自定义值超过 ${mem_cap}MB，已使用 ${mem_cap}MB${PLAIN}" >&2
                echo "$mem_cap"
                return 0
            fi
            echo "$custom_buffer"
        else
            echo "$buffer_mb"
        fi
    fi
}

bbr_check_conflicts() {
    echo -e "${BLUE}=== 检查 sysctl 配置冲突 ===${PLAIN}"
    local conflicts=()
    local conf
    local tune_key_regex='net\.(core\.(rmem_max|wmem_max|default_qdisc|somaxconn|netdev_max_backlog)|ipv4\.(ip_local_port_range|udp_(rmem_min|wmem_min)|tcp_(rmem|wmem|congestion_control|tw_reuse|max_syn_backlog|slow_start_after_idle|mtu_probing|notsent_lowat|fin_timeout|max_tw_buckets|fastopen|keepalive_time|keepalive_intvl|keepalive_probes|syncookies)))'
    local active_tune_regex="^[[:space:]]*${tune_key_regex}[[:space:]]*="

    for conf in /etc/sysctl.d/*.conf; do
        [[ -f "$conf" ]] || continue
        [[ "$conf" == "$BBR_SYSCTL_CONF" ]] && continue
        if grep -qE "$active_tune_regex" "$conf" 2>/dev/null; then
            conflicts+=("$conf")
        fi
    done

    local has_sysctl_conflict=0
    if [[ -f /etc/sysctl.conf ]] && grep -qE "$active_tune_regex" /etc/sysctl.conf 2>/dev/null; then
        has_sysctl_conflict=1
    fi

    if [[ "${#conflicts[@]}" -eq 0 && "$has_sysctl_conflict" -eq 0 ]]; then
        echo -e "${GREEN}✓ 未发现可能的覆盖配置${PLAIN}"
        return 0
    fi

    echo -e "${YELLOW}发现可能重复的网络参数，Zero.sh 不会修改这些文件:${PLAIN}"
    if [[ "${#conflicts[@]}" -gt 0 ]]; then
        printf '  - %s\n' "${conflicts[@]}"
    fi
    [[ "$has_sysctl_conflict" -eq 1 ]] && echo "  - /etc/sysctl.conf"
    echo -e "${YELLOW}若有同名参数，实际生效值以 sysctl 加载顺序为准${PLAIN}"
}

bbr_eligible_ifaces() {
    local path dev
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        dev=$(basename "$path")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|warp*|CloudflareWARP*|tun*|tap*) continue ;;
        esac
        echo "$dev"
    done
}

bbr_apply_tc_fq_now() {
    if ! command -v tc >/dev/null 2>&1; then
        echo -e "${YELLOW}警告: 未检测到 tc（iproute2），跳过 fq 应用${PLAIN}"
        return 0
    fi

    local applied=0 dev
    for dev in $(bbr_eligible_ifaces); do
        tc qdisc replace dev "$dev" root fq 2>/dev/null && applied=$((applied + 1))
    done

    if (( applied > 0 )); then
        echo -e "${GREEN}已对 ${applied} 个网卡应用 fq${PLAIN}"
    else
        echo -e "${YELLOW}未发现可应用 fq 的网卡${PLAIN}"
    fi
}

bbr_apply_mss_clamp() {
    local action="$1"
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${YELLOW}警告: 未检测到 iptables，跳过 MSS clamp${PLAIN}"
        return 0
    fi
    local -a mss_match=(-p tcp --tcp-flags "SYN,RST" SYN)
    local -a mss_rule=("${mss_match[@]}" -m comment --comment zero-bbr-mss -j TCPMSS --clamp-mss-to-pmtu)

    if [[ "$action" == enable ]]; then
        iptables -w 3 -t mangle -C FORWARD "${mss_match[@]}" -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 && return 0
        iptables -w 3 -t mangle -C FORWARD "${mss_rule[@]}" >/dev/null 2>&1 ||
            iptables -w 3 -t mangle -A FORWARD "${mss_rule[@]}"
        return $?
    fi
    while iptables -w 3 -t mangle -C FORWARD "${mss_rule[@]}" >/dev/null 2>&1; do
        iptables -w 3 -t mangle -D FORWARD "${mss_rule[@]}" || return 1
    done
}

bbr_cleanup_persist() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$BBR_PERSIST_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$BBR_PERSIST_SERVICE" "$BBR_PERSIST_SCRIPT"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

bbr_configure_direct() {
    local bbr_arch
    bbr_arch=$(zero_get_arch) || {
        bbr_fail_and_pause "错误: 当前架构 $(uname -m) 不支持 BBR 调优"
        return 1
    }

    echo -e "${YELLOW}[步骤 1/5] 带宽检测与缓冲区...${PLAIN}"
    local detected_bandwidth
    detected_bandwidth=$(bbr_detect_bandwidth)
    local bandwidth_status=$?
    case "$bandwidth_status" in
        0) ;;
        2) return 0 ;;
        3) bbr_restore_original_network_config; return $? ;;
        *) press_any_key_to_continue; return 1 ;;
    esac

    local region="asia" region_choice
    echo "1. 亚太地区（港/日/新/韩等）"
    echo "2. 美国/欧洲（跨太平洋/大西洋）"
    read -r -p "请输入选择 [1]: " region_choice || return 1
    region_choice=$(trim_input "$region_choice")
    [[ "${region_choice:-1}" == "2" ]] && region="overseas"

    local profile="balanced" profile_choice profile_label="代理均衡"
    echo "1. 代理均衡（网页响应 + 下载速度）"
    echo "2. 下载增强（大文件/高带宽，仍兼顾网页响应）"
    read -r -p "请输入优化目标 [1]: " profile_choice || return 1
    profile_choice=$(trim_input "$profile_choice")
    if [[ "${profile_choice:-1}" == "2" ]]; then
        profile="download"
        profile_label="下载增强"
    fi

    local mem_total
    mem_total=$(free -m | awk '/Mem:/ {print $2}')
    [[ "$mem_total" =~ ^[0-9]+$ ]] || mem_total=0

    local buffer_mb buffer_bytes
    buffer_mb=$(bbr_calculate_buffer_size "$detected_bandwidth" "$region" "$profile" "$mem_total") || return 1
    buffer_bytes=$((buffer_mb * 1024 * 1024))

    echo -e "${YELLOW}[步骤 2/5] 检查配置冲突...${PLAIN}"
    bbr_check_conflicts

    echo -e "${YELLOW}[步骤 3/5] 创建配置文件...${PLAIN}"
    local somaxconn=8192 tcp_max_syn_backlog=8192 netdev_max_backlog=5000 tcp_notsent_lowat=32768 tcp_max_tw_buckets=200000
    if [[ "$profile" == "download" ]]; then
        tcp_max_syn_backlog=16384
        netdev_max_backlog=10000
        tcp_notsent_lowat=131072
        tcp_max_tw_buckets=300000
    fi

    cat > "$BBR_SYSCTL_CONF" <<EOF || { bbr_fail_and_pause "写入 BBR 配置失败"; return 1; }
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=${buffer_bytes}
net.core.wmem_max=${buffer_bytes}
net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=${somaxconn}
net.ipv4.tcp_max_syn_backlog=${tcp_max_syn_backlog}
net.core.netdev_max_backlog=${netdev_max_backlog}
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=${tcp_notsent_lowat}
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=${tcp_max_tw_buckets}
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_syncookies=1
EOF

    echo -e "${YELLOW}[步骤 4/5] 应用所有优化参数...${PLAIN}"
    local sysctl_output sysctl_rc
    sysctl_output=$(sysctl -p "$BBR_SYSCTL_CONF" 2>&1)
    sysctl_rc=$?
    if [[ "$sysctl_rc" -ne 0 ]]; then
        echo -e "${YELLOW}部分 sysctl 参数应用失败（不支持的参数会被跳过）${PLAIN}"
        echo "$sysctl_output" | grep -i "error\|invalid\|unknown\|cannot" | head -n 5
    fi

    bbr_apply_tc_fq_now
    bbr_apply_mss_clamp enable
    firewall_sync_saved_rules_if_enabled
    bbr_cleanup_persist

    cat > "$BBR_PERSIST_SERVICE" <<'EOF' || { bbr_fail_and_pause "写入 BBR 服务文件失败"; return 1; }
[Unit]
Description=BBR Optimize - Restore tc fq and MSS clamp after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bbr-optimize-apply.sh

[Install]
WantedBy=multi-user.target
EOF

cat > "$BBR_PERSIST_SCRIPT" <<'EOF' || { bbr_fail_and_pause "写入 BBR 持久化脚本失败"; return 1; }
#!/bin/bash
if command -v tc >/dev/null 2>&1; then
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        dev=$(basename "$d")
        case "$dev" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|warp*|CloudflareWARP*|tun*|tap*) continue ;;
        esac
        tc qdisc replace dev "$dev" root fq 2>/dev/null
    done
fi
if command -v iptables >/dev/null 2>&1; then
    mss_match=(-p tcp --tcp-flags "SYN,RST" SYN)
    mss_rule=("${mss_match[@]}" -m comment --comment zero-bbr-mss -j TCPMSS --clamp-mss-to-pmtu)
    if ! iptables -w 3 -t mangle -C FORWARD "${mss_match[@]}" -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1; then
        iptables -w 3 -t mangle -C FORWARD "${mss_rule[@]}" >/dev/null 2>&1 ||
            iptables -w 3 -t mangle -A FORWARD "${mss_rule[@]}"
    fi
fi
EOF

    chmod +x "$BBR_PERSIST_SCRIPT" || return 1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || echo -e "${YELLOW}systemd 重新加载失败,BBR 持久化服务可能未生效${PLAIN}"
        systemctl enable "$BBR_PERSIST_SERVICE_NAME" >/dev/null 2>&1 || echo -e "${YELLOW}BBR 持久化服务启用失败,重启后可能需要重新应用调优${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 systemctl，已跳过持久化服务启用${PLAIN}"
    fi

    echo -e "${YELLOW}[步骤 5/5] 验证配置...${PLAIN}"
    local actual_qdisc actual_cc available_cc current_kernel
    local -a bbr_status
    mapfile -t bbr_status < <(bbr_read_runtime_status)
    current_kernel="${bbr_status[0]}"
    actual_cc="${bbr_status[1]}"
    actual_qdisc="${bbr_status[2]}"
    available_cc="${bbr_status[3]}"

    if [[ "$actual_qdisc" == "fq" && "$actual_cc" == "bbr" ]] && echo "$available_cc" | grep -qw bbr; then
        if [[ "$bbr_arch" == "arm64" ]]; then
            echo -e "${GREEN}✓ fq + bbr 已启用，当前使用 ARM64 原生内核${PLAIN}"
            echo -e "配置说明: ${GREEN}${profile_label}${PLAIN} / ${GREEN}${buffer_mb}MB${PLAIN} 缓冲区（${GREEN}${detected_bandwidth} Mbps${PLAIN} 带宽）"
        elif echo "$current_kernel" | grep -qi 'xanmod'; then
            echo -e "${GREEN}✓ fq + bbr 已启用，当前运行内核为 XanMod${PLAIN}"
            echo -e "配置说明: ${GREEN}${profile_label}${PLAIN} / ${GREEN}${buffer_mb}MB${PLAIN} 缓冲区（${GREEN}${detected_bandwidth} Mbps${PLAIN} 带宽）"
        else
            echo -e "${YELLOW}fq + bbr 已启用，但当前运行内核不是 XanMod${PLAIN}"
            echo -e "${YELLOW}如需确认 BBR v3，请先重启进入 XanMod 内核后再验证${PLAIN}"
        fi
    else
        echo -e "${YELLOW}配置已保存，但部分参数未立即生效${PLAIN}"
    fi

    press_any_key_to_continue
}

bbr_install_xanmod_kernel() {
    local action_label="安装"
    bbr_xanmod_installed && action_label="更新"

    if [[ "$(zero_get_arch 2>/dev/null || true)" != "amd64" ]]; then
        bbr_fail_and_pause "错误: XanMod 官方仓库仅提供 amd64/x86_64 内核，ARM64 请直接使用原生内核进行 BBR 调优"
        return 1
    fi

    echo -e "${BLUE}=== ${action_label} XanMod 内核与 BBR v3 ===${PLAIN}"
    echo "支持系统: Debian/Ubuntu (x86_64)"
    echo -e "${YELLOW}警告: 将升级 Linux 内核，请提前备份重要数据${PLAIN}"
    if ! bbr_confirm "确定继续${action_label}吗？(Y/N): "; then
        echo "已取消${action_label}"
        press_any_key_to_continue
        return 1
    fi

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            bbr_fail_and_pause "错误: 仅支持 Debian 和 Ubuntu"
            return 1
        fi
    else
        bbr_fail_and_pause "错误: 无法确定操作系统类型"
        return 1
    fi

    bbr_check_disk_space 3 || {
        press_any_key_to_continue
        return 1
    }
    bbr_check_and_prepare_swap || {
        bbr_fail_and_pause "虚拟内存配置失败，已停止安装"
        return 1
    }
    bbr_ensure_apt_packages curl gnupg ca-certificates || {
        bbr_fail_and_pause "依赖安装失败"
        return 1
    }

    echo -e "${YELLOW}正在添加 XanMod 仓库密钥...${PLAIN}"
    local had_xanmod=0 key_tmp key_log
    bbr_xanmod_installed && had_xanmod=1
    install -d -m 0755 "${BBR_KEYRING%/*}" "${BBR_REPO_FILE%/*}" || {
        bbr_fail_and_pause "无法创建 APT 密钥或源目录"
        return 1
    }
    key_tmp=$(mktemp) || {
        press_any_key_to_continue
        return 1
    }
    key_log="${key_tmp}.log"

    if ! bbr_fetch_xanmod_key "$key_tmp" "$key_log" || ! gpg --dearmor -o "$BBR_KEYRING" --yes < "$key_tmp" 2>>"$key_log" || ! chmod 0644 "$BBR_KEYRING"; then
        echo -e "${RED}错误: XanMod 仓库密钥下载或导入失败${PLAIN}"
        [[ -s "$key_log" ]] && tail -n 12 "$key_log"
        rm -f "$key_tmp" "$key_log"
        (( had_xanmod == 0 )) && rm -f "$BBR_KEYRING"
        press_any_key_to_continue
        return 1
    fi
    rm -f "$key_tmp" "$key_log"

    local distro_codename
    if [[ -n "${VERSION_CODENAME:-}" ]]; then
        distro_codename="$VERSION_CODENAME"
    elif [[ -n "${UBUNTU_CODENAME:-}" ]]; then
        distro_codename="$UBUNTU_CODENAME"
    elif command -v lsb_release >/dev/null 2>&1; then
        distro_codename=$(lsb_release -sc 2>/dev/null)
    else
        distro_codename=""
    fi

    if [[ -z "$distro_codename" ]]; then
        (( had_xanmod == 0 )) && rm -f "$BBR_KEYRING"
        bbr_fail_and_pause "错误: 无法确定系统代号，已停止安装"
        return 1
    fi

    echo "deb [signed-by=${BBR_KEYRING}] http://deb.xanmod.org ${distro_codename} main" > "$BBR_REPO_FILE" &&
        chmod 0644 "$BBR_REPO_FILE" || {
        rm -f "$BBR_REPO_FILE"
        (( had_xanmod == 0 )) && rm -f "$BBR_KEYRING"
        bbr_fail_and_pause "写入 XanMod 软件源失败"
        return 1
    }

    echo -e "${YELLOW}正在检测 CPU 支持的最优内核版本...${PLAIN}"
    local version package_name package_hint
    version=$(bbr_detect_x86_64_level_local)
    if ! [[ "$version" =~ ^[1-4]$ ]]; then
        (( had_xanmod == 0 )) && rm -f "$BBR_REPO_FILE" "$BBR_KEYRING"
        bbr_fail_and_pause "错误: 无法可靠检测 CPU 对应的 XanMod x64v 等级"
        return 1
    fi

    if ! ( umask 022; apt-get update ); then
        rm -f "$BBR_REPO_FILE"
        (( had_xanmod == 0 )) && rm -f "$BBR_KEYRING"
        bbr_fail_and_pause "apt-get update 失败，已清理 XanMod 软件源 (${distro_codename})"
        return 1
    fi

    local package_info package_status

    package_info=$(bbr_select_xanmod_package "$version") || {
        (( had_xanmod == 0 )) && rm -f "$BBR_REPO_FILE" "$BBR_KEYRING"
        bbr_fail_and_pause "错误: 当前仓库中未找到适配 x64v${version} 的 XanMod 内核包"
        return 1
    }

    package_name="${package_info%%|*}"
    package_hint="${package_info#*|}"

    echo -e "${GREEN}目标通道: ${package_name}${PLAIN}"
    echo -e "${YELLOW}说明: ${package_hint}${PLAIN}"
    echo -e "${YELLOW}安装元包: ${package_name}${PLAIN}"

    if ! ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name" ); then
        bbr_fail_and_pause "XanMod 内核安装失败"
        return 1
    fi

    package_status=$(dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null || true)
    if [[ "$package_status" != "install ok installed" ]] || ! bbr_xanmod_installed; then
        bbr_fail_and_pause "未检测到 XanMod 内核安装成功"
        return 1
    fi

    echo -e "${GREEN}XanMod 内核${action_label}成功${PLAIN}"
    echo -e "${YELLOW}提示: 请先重启系统加载新内核，然后再进行 BBR 调优${PLAIN}"
    press_any_key_to_continue
}

bbr_uninstall_xanmod_kernel() {
    if [[ "$(zero_get_arch 2>/dev/null || true)" == "arm64" ]]; then
        bbr_fail_and_pause "提示: ARM64 不使用 XanMod，无需执行卸载"
        return 1
    fi

    echo -e "${YELLOW}警告: 即将卸载 XanMod 内核${PLAIN}"
    local non_xanmod_kernels=0
    non_xanmod_kernels=$(dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' 'linux-image*' 2>/dev/null |
        awk '$1 == "ii" && $2 ~ /^linux-image(-unsigned)?-[0-9]/ && $2 !~ /xanmod/ && $2 !~ /-dbg$/ { c++ } END { print c + 0 }')
    if (( non_xanmod_kernels == 0 )); then
        echo -e "${RED}安全检查未通过：未检测到非 XanMod 的回退内核${PLAIN}"
        echo "建议先安装默认内核:"
        echo "  apt install -y linux-image-amd64   # Debian"
        echo "  apt install -y linux-image-generic # Ubuntu"
        press_any_key_to_continue
        return 1
    fi

    if bbr_confirm "确定继续吗？(Y/N): "; then
        echo -e "${YELLOW}正在卸载 XanMod 相关包...${PLAIN}"
        if ! ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get purge -y 'linux-*xanmod*' ); then
            bbr_fail_and_pause "卸载 XanMod 相关包失败"
            return 1
        fi
        rm -f "$BBR_REPO_FILE" "$BBR_KEYRING" /usr/share/keyrings/xanmod-archive-keyring.gpg
        rm -f "$BBR_SYSCTL_CONF" /etc/sysctl.d/99-zero-bbr.conf
        bbr_apply_mss_clamp disable || { bbr_fail_and_pause "移除 Zero.sh MSS 规则失败"; return 1; }
        firewall_sync_saved_rules_if_enabled
        bbr_cleanup_persist
        bbr_cleanup_managed_speedtest
        echo -e "${GREEN}XanMod 内核已卸载${PLAIN}"
        bbr_prompt_reboot
    else
        echo "已取消"
    fi
    press_any_key_to_continue
}

bbr_restore_original_network_config() {
    echo -e "${YELLOW}将删除 Zero.sh 创建的 BBR 配置，保留用户和系统的其他网络配置${PLAIN}"
    if ! bbr_confirm "确定恢复原始网络配置吗？(Y/N): "; then
        echo -e "${YELLOW}已取消${PLAIN}"
        press_any_key_to_continue
        return 0
    fi

    if ! rm -f "$BBR_SYSCTL_CONF" /etc/sysctl.d/99-zero-bbr.conf; then
        bbr_fail_and_pause "删除 Zero.sh BBR 配置失败"
        return 1
    fi
    bbr_apply_mss_clamp disable || { bbr_fail_and_pause "移除 Zero.sh MSS 规则失败"; return 1; }
    firewall_sync_saved_rules_if_enabled
    bbr_cleanup_persist
    bbr_cleanup_managed_speedtest

    if sysctl --system >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 已恢复原始网络配置${PLAIN}"
    else
        echo -e "${YELLOW}Zero.sh 配置已删除，但系统 sysctl 重新加载时有报错${PLAIN}"
    fi
    echo -e "${YELLOW}建议重启一次，使已在运行的 qdisc 和内核网络参数完全恢复${PLAIN}"
    press_any_key_to_continue
}

bbr_manage_menu() {
    local opt bbr_arch current_kernel cc qdisc xanmod_state xanmod_installed xanmod_action
    local -a bbr_status=()
    bbr_arch=$(zero_get_arch 2>/dev/null || true)
    while true; do
        mapfile -t bbr_status < <(bbr_read_runtime_status)
        current_kernel="${bbr_status[0]:-}"
        cc="${bbr_status[1]:-}"
        qdisc="${bbr_status[2]:-}"
        xanmod_installed="${bbr_status[4]:-no}"
        [[ "$xanmod_installed" == "yes" ]] && xanmod_action="更新XanMod" || xanmod_action="安装XanMod"
        if [[ "$bbr_arch" == "arm64" ]]; then
            xanmod_state="${YELLOW}ARM64不适用${PLAIN}"
        elif [[ "$xanmod_installed" == "yes" ]]; then
            xanmod_state="${GREEN}已安装${PLAIN}"
        else
            xanmod_state="${YELLOW}未安装${PLAIN}"
        fi

        clear
        echo -e "${BLUE}=========== BBR ===========${PLAIN}"
        echo -e "${BLUE}内核: ${YELLOW}${current_kernel:-unknown}${PLAIN}"
        echo -e "${BLUE}状态: XanMod ${xanmod_state} | BBR ${GREEN}${cc:-unknown}${PLAIN} | 队列 ${GREEN}${qdisc:-unknown}${PLAIN}"
        echo -e "${BLUE}===========================${PLAIN}"
        if [[ "$bbr_arch" != "arm64" ]]; then
            echo -e "${GREEN}1.BBR调优${PLAIN}         ${GREEN}2.${xanmod_action}${PLAIN}"
            echo -e "${RED}3.卸载XanMod${PLAIN}      ${YELLOW}0.返回菜单${PLAIN}"
            echo -e "${BLUE}===========================${PLAIN}"
            opt=$(read_menu_choice "请输入选项 [0-3]: ") || return 1
        else
            echo -e "${GREEN}1.BBR调优${PLAIN}         ${YELLOW}0.返回菜单${PLAIN}"
            echo -e "${BLUE}===========================${PLAIN}"
            opt=$(read_menu_choice "请输入选项 [0-1]: ") || return 1
            if [[ "$opt" == "2" || "$opt" == "3" ]]; then
                show_invalid_option
                continue
            fi
        fi

        case "$opt" in
            1) clear; bbr_configure_direct ;;
            2) clear; bbr_install_xanmod_kernel ;;
            3) clear; bbr_uninstall_xanmod_kernel ;;
            0) return ;;
            *) show_invalid_option ;;
        esac
    done
}

DNS_RESOLV_CONF="/etc/resolv.conf"
DNS_RESOLV_BACKUP="/etc/resolv.conf.zero.bak"
DNS_DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
DNS_DHCLIENT_BACKUP="/etc/dhcp/dhclient.conf.zero.bak"
DNS_DHCLIENT_HOOK_DIR="/etc/dhcp/dhclient-enter-hooks.d"
DNS_DHCLIENT_HOOK_FILE="$DNS_DHCLIENT_HOOK_DIR/zz-zero-dns"
DNS_DHCPCD_CONF="/etc/dhcpcd.conf"
DNS_DHCPCD_BACKUP="/etc/dhcpcd.conf.zero.bak"
DNS_OCI_CONF="/etc/oci-hostname.conf"
DNS_NETWORKD_DIR="/etc/systemd/network"
DNS_NETWORKD_RUN_DIR="/run/systemd/network"
DNS_NETWORKD_LIB_DIR="/usr/lib/systemd/network"
DNS_NM_DROPIN="/etc/NetworkManager/conf.d/90-zero-dns.conf"
DNS_RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
DNS_RESOLVED_DROPIN_FILE="$DNS_RESOLVED_DROPIN_DIR/zz-zero-dns.conf"
DNS_RESOLVED_PREVIOUS_FILE="$DNS_RESOLVED_DROPIN_DIR/90-zero-dns.conf"
DNS_RESOLVED_RESOLV_BACKUP="/etc/resolv.conf.zero-resolved.bak"
DNS_RESOLVED_STUB="/run/systemd/resolve/stub-resolv.conf"

dns_parent_dir() {
    local p="${1%/}"
    if [[ "$p" == */* ]]; then
        p="${p%/*}"
        printf '%s\n' "${p:-/}"
    else
        printf '.\n'
    fi
}

dns_resolv_backup_path() {
    [[ "$DNS_RESOLV_BACKUP" == "/etc/resolv.conf.zero.bak" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] &&
        printf '%s.zero.bak\n' "$DNS_RESOLV_CONF" || printf '%s\n' "$DNS_RESOLV_BACKUP"
}

dns_resolved_resolv_backup_path() {
    [[ "$DNS_RESOLVED_RESOLV_BACKUP" == "/etc/resolv.conf.zero-resolved.bak" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] &&
        printf '%s.zero-resolved.bak\n' "$DNS_RESOLV_CONF" || printf '%s\n' "$DNS_RESOLVED_RESOLV_BACKUP"
}

dns_dhclient_conf_path() {
    [[ -n "${DNS_DHCLIENT_CONF:-}" ]] || return 0
    [[ "$DNS_DHCLIENT_CONF" == "/etc/dhcp/dhclient.conf" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] &&
        printf '%s/dhcp/dhclient.conf\n' "$(dns_parent_dir "$DNS_RESOLV_CONF")" || printf '%s\n' "$DNS_DHCLIENT_CONF"
}

dns_dhclient_backup_path() {
    [[ "$DNS_DHCLIENT_BACKUP" == "/etc/dhcp/dhclient.conf.zero.bak" && "$1" != "/etc/dhcp/dhclient.conf" ]] &&
        printf '%s.zero.bak\n' "$1" || printf '%s\n' "$DNS_DHCLIENT_BACKUP"
}

dns_dhclient_hook_dir_path() {
    [[ "$DNS_DHCLIENT_HOOK_DIR" == "/etc/dhcp/dhclient-enter-hooks.d" && "$1" != "/etc/dhcp/dhclient.conf" ]] &&
        printf '%s/dhclient-enter-hooks.d\n' "$(dns_parent_dir "$1")" || printf '%s\n' "$DNS_DHCLIENT_HOOK_DIR"
}

dns_dhclient_hook_file_path() {
    [[ "$DNS_DHCLIENT_HOOK_FILE" == "/etc/dhcp/dhclient-enter-hooks.d/zz-zero-dns" && "$1" != "/etc/dhcp/dhclient-enter-hooks.d" ]] &&
        printf '%s/zz-zero-dns\n' "$1" || printf '%s\n' "$DNS_DHCLIENT_HOOK_FILE"
}

dns_dhcpcd_conf_path() {
    [[ -n "${DNS_DHCPCD_CONF:-}" ]] || return 0
    [[ "$DNS_DHCPCD_CONF" == "/etc/dhcpcd.conf" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] &&
        printf '%s/dhcpcd.conf\n' "$(dns_parent_dir "$DNS_RESOLV_CONF")" || printf '%s\n' "$DNS_DHCPCD_CONF"
}

dns_dhcpcd_backup_path() {
    [[ "$DNS_DHCPCD_BACKUP" == "/etc/dhcpcd.conf.zero.bak" && "$1" != "/etc/dhcpcd.conf" ]] &&
        printf '%s.zero.bak\n' "$1" || printf '%s\n' "$DNS_DHCPCD_BACKUP"
}

dns_should_sync_dhclient() {
    local conf_path dhclient_dir backup_file hook_dir hook_file
    conf_path=$(dns_dhclient_conf_path)
    [[ -n "$conf_path" ]] || return 1
    dhclient_dir=$(dns_parent_dir "$conf_path")
    backup_file=$(dns_dhclient_backup_path "$conf_path")
    hook_dir=$(dns_dhclient_hook_dir_path "$conf_path")
    hook_file=$(dns_dhclient_hook_file_path "$hook_dir")

    [[ -e "$conf_path" || -L "$conf_path" || -e "$backup_file" || -L "$backup_file" ||
       -e "$hook_file" || -L "$hook_file" || -d "$dhclient_dir" || -d "$hook_dir" ||
       "$DNS_DHCLIENT_CONF" != "/etc/dhcp/dhclient.conf" ]] && return 0
    [[ "$DNS_RESOLV_CONF" == "/etc/resolv.conf" ]] &&
        { command -v dhclient >/dev/null 2>&1 || [[ -x /sbin/dhclient || -x /usr/sbin/dhclient ]]; }
}

dns_should_sync_dhcpcd() {
    local conf_path backup_file
    conf_path=$(dns_dhcpcd_conf_path)
    [[ -n "$conf_path" ]] || return 1
    backup_file=$(dns_dhcpcd_backup_path "$conf_path")

    [[ -e "$conf_path" || -L "$conf_path" || -e "$backup_file" || -L "$backup_file" ||
       "$DNS_DHCPCD_CONF" != "/etc/dhcpcd.conf" ]] && return 0
    [[ "$DNS_RESOLV_CONF" == "/etc/resolv.conf" ]] &&
        { command -v dhcpcd >/dev/null 2>&1 || [[ -x /sbin/dhcpcd || -x /usr/sbin/dhcpcd ]]; }
}

dns_is_valid_ipv4() {
    local ip="$1" IFS=.
    local o1 o2 o3 o4 o

    [[ -n "$ip" && ! "$ip" =~ [[:space:]] && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" == "0" || "$o" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

dns_is_valid_ipv6() {
    local ip="$1" address="" zone="" ipv4_part="" left="" right="" part=""
    local -a lparts=() rparts=()

    [[ -n "$ip" && ! "$ip" =~ [[:space:]] && "$ip" == *:* && "$ip" != *:::* ]] || return 1
    if [[ "$ip" == *%* ]]; then
        [[ "$ip" != *%*%* ]] || return 1
        address="${ip%%%*}"
        zone="${ip#*%}"
        [[ -n "$zone" && "$zone" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    else
        address="$ip"
    fi
    [[ -n "$address" && "$address" == *:* && "$address" != *:::* ]] || return 1

    if [[ "$address" == *.* ]]; then
        ipv4_part="${address##*:}"
        dns_is_valid_ipv4 "$ipv4_part" || return 1
        address="${address%"$ipv4_part"}0:0"
    fi

    [[ "$address" == :* && "$address" != ::* ]] && return 1
    [[ "$address" == *: && "$address" != *:: ]] && return 1

    if [[ "$address" == *::* ]]; then
        [[ "${address#*::}" != *::* ]] || return 1
        left="${address%%::*}"
        right="${address#*::}"
        [[ -n "$left" ]] && IFS=':' read -r -a lparts <<< "$left"
        [[ -n "$right" ]] && IFS=':' read -r -a rparts <<< "$right"
        (( ${#lparts[@]} + ${#rparts[@]} <= 7 )) || return 1
        for part in ${lparts[@]+"${lparts[@]}"} ${rparts[@]+"${rparts[@]}"}; do
            [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        done
    else
        IFS=':' read -r -a lparts <<< "$address"
        (( ${#lparts[@]} == 8 )) || return 1
        for part in "${lparts[@]}"; do
            [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        done
    fi
    return 0
}

dns_is_valid_ip() {
    local ip="$1"
    [[ -n "$ip" && ! "$ip" =~ [[:space:]\"\'\`\\] ]] || return 1
    dns_is_valid_ipv4 "$ip" || dns_is_valid_ipv6 "$ip"
}

dns_has_ipv4() {
    command -v ip >/dev/null 2>&1 || return 2
    local route_out="" first_line="" src_ip="" def_v4=""
    route_out=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
    if [[ -n "$route_out" ]]; then
        IFS= read -r first_line <<< "$route_out"
        [[ "$first_line" =~ (^|[[:space:]])(unreachable|prohibit|blackhole|throw|dev[[:space:]]+lo)([[:space:]]|$) ]] && return 1
        if [[ "$first_line" =~ (^|[[:space:]])src[[:space:]]+([^[:space:]]+) ]]; then
            src_ip="${BASH_REMATCH[2]}"
            case "$src_ip" in
                0.*|127.*|169.254.*) return 1 ;;
            esac
            return 0
        fi
        ip -4 -o addr show scope global 2>/dev/null | grep -Evq 'inet[[:space:]]+(0\.|127\.|169\.254\.)'
        return $?
    fi
    def_v4=$(ip -4 route show default 2>/dev/null | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)|(^|[[:space:]])dev[[:space:]]+lo([[:space:]]|$)' || true)
    [[ -n "$def_v4" ]] && ip -4 -o addr show scope global 2>/dev/null | grep -Evq 'inet[[:space:]]+(0\.|127\.|169\.254\.)'
}

dns_has_ipv6() {
    command -v ip >/dev/null 2>&1 || return 2
    local route_out="" first_line="" src_ip="" def_v6=""
    route_out=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null || true)
    if [[ -n "$route_out" ]]; then
        IFS= read -r first_line <<< "$route_out"
        [[ "$first_line" =~ (^|[[:space:]])(unreachable|prohibit|blackhole|throw|dev[[:space:]]+lo)([[:space:]]|$) ]] && return 1
        if [[ "$first_line" =~ (^|[[:space:]])src[[:space:]]+([^[:space:]]+) ]]; then
            src_ip="${BASH_REMATCH[2]%%%*}"
            case "$src_ip" in
                ::|::1|0:0:0:0:0:0:0:0|0:0:0:0:0:0:0:1|[Ff][Ee][89AaBb][0-9A-Fa-f]:*) return 1 ;;
            esac
            return 0
        fi
        ip -6 -o addr show scope global 2>/dev/null | grep -Evq '(^|[[:space:]])(tentative|dadfailed)([[:space:]]|$)'
        return $?
    fi
    def_v6=$(ip -6 route show default 2>/dev/null | grep -Ev '^[[:space:]]*(unreachable|prohibit|blackhole|throw)|(^|[[:space:]])dev[[:space:]]+lo([[:space:]]|$)' || true)
    [[ -n "$def_v6" ]] && ip -6 -o addr show scope global 2>/dev/null | grep -Evq '(^|[[:space:]])(tentative|dadfailed)([[:space:]]|$)'
}

dns_detect_stack() {
    case "${DNS_STACK_MODE:-}" in
        dual|ipv4|ipv6|none|unknown) printf '%s\n' "$DNS_STACK_MODE"; return 0 ;;
    esac
    local rc4=0 rc6=0
    dns_has_ipv4 || rc4=$?
    dns_has_ipv6 || rc6=$?
    if (( rc4 == 0 && rc6 == 0 )); then
        printf 'dual\n'
    elif (( rc4 == 0 )); then
        printf 'ipv4\n'
    elif (( rc6 == 0 )); then
        printf 'ipv6\n'
    elif (( rc4 == 2 && rc6 == 2 )); then
        printf 'unknown\n'
    else
        printf 'none\n'
    fi
}

dns_stack_label() {
    case "$1" in
        dual) printf '%s' "${GREEN}双栈 (IPv4 + IPv6)${PLAIN}" ;;
        ipv4) printf '%s' "${GREEN}仅 IPv4${PLAIN}" ;;
        ipv6) printf '%s' "${GREEN}纯 IPv6${PLAIN}" ;;
        none) printf '%s' "${RED}未检测到默认路由${PLAIN}" ;;
        *)    printf '%s' "${YELLOW}未知${PLAIN}" ;;
    esac
}

dns_systemd_resolved_active() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active systemd-resolved >/dev/null 2>&1
}

dns_get_immutable_flags() {
    local target="${1:-$DNS_RESOLV_CONF}" attr_col="" flags=""
    [[ ! -L "$target" && -f "$target" ]] && command -v lsattr >/dev/null 2>&1 || return 1
    attr_col=$(lsattr -d -- "$target" 2>/dev/null | awk 'NR==1 {print $1}')
    [[ "$attr_col" == *-* && "$attr_col" =~ ^[A-Za-z-]+$ ]] || return 1
    [[ "$attr_col" == *i* ]] && flags+="i"
    [[ "$attr_col" == *a* ]] && flags+="a"
    [[ -n "$flags" ]] && printf '%s\n' "$flags"
}

dns_unlock_resolv_if_needed() {
    local target="${1:-$DNS_RESOLV_CONF}" flags=""
    flags=$(dns_get_immutable_flags "$target" || true)
    [[ -n "$flags" ]] || return 0
    echo -e "${YELLOW}检测到 ${target} 被文件属性锁定 (chattr +${flags})，正在自动解除锁定...${PLAIN}" >&2
    if ! command -v chattr >/dev/null 2>&1 || ! chattr "-${flags}" -- "$target" 2>/dev/null; then
        echo -e "${RED}无法解除 ${target} 的 chattr +${flags} 锁定，请检查权限${PLAIN}" >&2
        return 1
    fi
    [[ -z "$(dns_get_immutable_flags "$target" || true)" ]]
}

dns_copy_preserve() {
    local src="$1" dst="$2" link_target=""
    if [[ -L "$src" ]]; then
        link_target=$(readlink "$src") || return 1
        ln -sfn "$link_target" "$dst"
    else
        cp -p "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
    fi
}

dns_replace_resolv() {
    local source="$1" conf_dir="" temp="" link_target=""
    [[ ! -d "$DNS_RESOLV_CONF" ]] || return 1
    conf_dir=$(dns_parent_dir "$DNS_RESOLV_CONF")
    if [[ -L "$source" ]]; then
        link_target=$(readlink "$source") || return 1
        temp=$(mktemp "$conf_dir/.resolv.link.XXXXXX") || return 1
        ln -sfn "$link_target" "$temp" && mv -f "$temp" "$DNS_RESOLV_CONF" || { rm -f "$temp"; ln -sfn "$link_target" "$DNS_RESOLV_CONF"; }
        return $?
    fi
    temp=$(mktemp "$conf_dir/.resolv.zero.XXXXXX") || return 1
    if (cp -p "$source" "$temp" 2>/dev/null || cp "$source" "$temp") && mv -f "$temp" "$DNS_RESOLV_CONF"; then
        return 0
    fi
    rm -f "$temp"
    return 1
}

dns_prepare_managed_conf() {
    local conf_path="$1" backup_file="$2"
    DNS_PREP_SRC="/dev/null"
    DNS_PREP_CREATED=0
    if [[ -f "$conf_path" ]]; then
        DNS_PREP_SRC="$conf_path"
        if LC_ALL=C grep -Eq '^[[:space:]]*# Created by Zero\.sh[[:space:]]*$' "$conf_path" 2>/dev/null; then
            DNS_PREP_CREATED=1
        elif [[ ! -f "$backup_file" ]]; then
            dns_copy_preserve "$conf_path" "$backup_file" || return 1
        fi
    else
        DNS_PREP_CREATED=1
    fi
}

dns_restore_managed_conf() {
    local conf_path="$1" backup_file="$2" tmp_conf
    if [[ -f "$backup_file" ]]; then
        dns_copy_preserve "$backup_file" "$conf_path" || return 1
        rm -f "$backup_file"
        DNS_SUB_RESTORED=1
    elif [[ -f "$conf_path" ]] && LC_ALL=C grep -Eq '^[[:space:]]*# Created by Zero\.sh[[:space:]]*$' "$conf_path" 2>/dev/null; then
        rm -f "$conf_path"
        DNS_SUB_RESTORED=1
    elif [[ -f "$conf_path" ]] && LC_ALL=C grep -Eq '^[[:space:]]*# BEGIN Zero\.sh DNS[[:space:]]*$' "$conf_path" 2>/dev/null; then
        tmp_conf=$(mktemp "${conf_path}.zero.XXXXXX") || return 1
        chmod --reference="$conf_path" "$tmp_conf" 2>/dev/null || chmod 644 "$tmp_conf"
        LC_ALL=C awk '
            /^[[:space:]]*# BEGIN Zero\.sh DNS[[:space:]]*$/ { in_zero = 1; next }
            in_zero { if (/^[[:space:]]*# END Zero\.sh DNS[[:space:]]*$/) in_zero = 0; next }
            { print }
        ' "$conf_path" > "$tmp_conf" && mv -f "$tmp_conf" "$conf_path" || { rm -f "$tmp_conf"; return 1; }
        DNS_SUB_RESTORED=1
    fi
}

dns_sync_dhclient() {
    local v4_csv="$1" v6_csv="$2"
    shift 2
    local conf_path conf_dir backup_file hook_dir hook_file tmp_conf tmp_hook esc_resolv ns

    conf_path=$(dns_dhclient_conf_path)
    [[ -n "$conf_path" ]] || return 0
    conf_dir=$(dns_parent_dir "$conf_path")
    backup_file=$(dns_dhclient_backup_path "$conf_path")
    hook_dir=$(dns_dhclient_hook_dir_path "$conf_path")
    hook_file=$(dns_dhclient_hook_file_path "$hook_dir")

    if [[ -L "$conf_path" || ( -e "$conf_path" && ! -f "$conf_path" ) ||
          -L "$backup_file" || ( -e "$backup_file" && ! -f "$backup_file" ) ||
          -L "$hook_file" || ( -e "$hook_file" && ! -f "$hook_file" ) ]]; then
        echo -e "${RED}dhclient 配置路径异常，已停止同步${PLAIN}" >&2
        return 1
    fi

    mkdir -p "$conf_dir" "$hook_dir" || return 1
    dns_prepare_managed_conf "$conf_path" "$backup_file" || return 1

    tmp_conf=$(mktemp "${conf_path}.zero.XXXXXX") || return 1
    chmod --reference="$conf_path" "$tmp_conf" 2>/dev/null || chmod 644 "$tmp_conf"
    if ! LC_ALL=C awk -v v4="$v4_csv" -v v6="$v6_csv" -v created="$DNS_PREP_CREATED" '
        BEGIN { if (created) print "# Created by Zero.sh" }
        function emit_block() {
            if (emitted) return
            print "# BEGIN Zero.sh DNS"
            if (v4 != "") print "supersede domain-name-servers " v4 ";"
            if (v6 != "") print "supersede dhcp6.name-servers " v6 ";"
            print "# END Zero.sh DNS"
            emitted = 1
        }
        /^[[:space:]]*# Created by Zero\.sh[[:space:]]*$/ { next }
        /^[[:space:]]*# BEGIN Zero\.sh DNS[[:space:]]*$/ { in_zero = 1; next }
        in_zero { if (/^[[:space:]]*# END Zero\.sh DNS[[:space:]]*$/) in_zero = 0; next }
        skip_stmt { if (/;/) skip_stmt = 0; next }
        /^[[:space:]]*(supersede|prepend|append|default)[[:space:]]+(domain-name-servers|dhcp6\.name-servers)([[:space:];]|$)/ {
            if ($0 !~ /;/) skip_stmt = 1
            next
        }
        !emitted && /^[[:space:]]*(interface|pseudo|alias|lease)([[:space:]"{]|$)/ {
            emit_block()
            print ""
        }
        { print }
        END { if (!emitted) emit_block() }
    ' "$DNS_PREP_SRC" > "$tmp_conf"; then
        rm -f "$tmp_conf"
        return 1
    fi

    esc_resolv="${DNS_RESOLV_CONF//\'/\'\\\'\'}"
    tmp_hook=$(mktemp "${hook_file}.zero.XXXXXX") || { rm -f "$tmp_conf"; return 1; }
    chmod 644 "$tmp_hook"
    {
        printf '# Managed by Zero.sh\nmake_resolv_conf() {\n'
        printf "    if [ -L '%s' ] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then\n        return 0\n    fi\n" "$esc_resolv"
        printf "    _zero_r='%s'\n" "$esc_resolv"
        printf '    _zero_t="${_zero_r}.dhclient.$$"\n    {\n'
        printf "        printf '# Managed by Zero.sh\\n'\n"
        for ns in "$@"; do
            printf "        printf 'nameserver %s\\n'\n" "$ns"
        done
        printf '    } > "$_zero_t" 2>/dev/null && chmod 644 "$_zero_t" 2>/dev/null && mv -f "$_zero_t" "$_zero_r" 2>/dev/null || rm -f "$_zero_t" 2>/dev/null\n'
        printf '    unset _zero_r _zero_t\n    return 0\n}\n'
    } > "$tmp_hook" || { rm -f "$tmp_conf" "$tmp_hook"; return 1; }

    mv -f "$tmp_conf" "$conf_path" && mv -f "$tmp_hook" "$hook_file" || {
        rm -f "$tmp_conf" "$tmp_hook"
        return 1
    }
}

dns_sync_dhcpcd() {
    local conf_path conf_dir backup_file tmp_conf
    conf_path=$(dns_dhcpcd_conf_path)
    [[ -n "$conf_path" ]] || return 0
    conf_dir=$(dns_parent_dir "$conf_path")
    backup_file=$(dns_dhcpcd_backup_path "$conf_path")

    if [[ -L "$conf_path" || ( -e "$conf_path" && ! -f "$conf_path" ) ||
          -L "$backup_file" || ( -e "$backup_file" && ! -f "$backup_file" ) ]]; then
        echo -e "${RED}dhcpcd 配置路径异常，已停止同步${PLAIN}" >&2
        return 1
    fi

    mkdir -p "$conf_dir" || return 1
    dns_prepare_managed_conf "$conf_path" "$backup_file" || return 1

    tmp_conf=$(mktemp "${conf_path}.zero.XXXXXX") || return 1
    chmod --reference="$conf_path" "$tmp_conf" 2>/dev/null || chmod 644 "$tmp_conf"
    LC_ALL=C awk -v created="$DNS_PREP_CREATED" '
        BEGIN { if (created) print "# Created by Zero.sh" }
        function emit_block() {
            if (emitted) return
            print "# BEGIN Zero.sh DNS\nnohook resolv.conf\n# END Zero.sh DNS"
            emitted = 1
        }
        /^[[:space:]]*# Created by Zero\.sh[[:space:]]*$/ { next }
        /^[[:space:]]*# BEGIN Zero\.sh DNS[[:space:]]*$/ { in_zero = 1; next }
        in_zero { if (/^[[:space:]]*# END Zero\.sh DNS[[:space:]]*$/) in_zero = 0; next }
        !emitted && /^[[:space:]]*(interface|ssid)([[:space:]]|$)/ {
            emit_block()
            print ""
        }
        { print }
        END { if (!emitted) emit_block() }
    ' "$DNS_PREP_SRC" > "$tmp_conf" && mv -f "$tmp_conf" "$conf_path" || { rm -f "$tmp_conf"; return 1; }
}

dns_unsync_dhclient() {
    local conf_path backup_file hook_dir hook_file
    conf_path=$(dns_dhclient_conf_path)
    [[ -n "$conf_path" ]] || return 0
    backup_file=$(dns_dhclient_backup_path "$conf_path")
    hook_dir=$(dns_dhclient_hook_dir_path "$conf_path")
    hook_file=$(dns_dhclient_hook_file_path "$hook_dir")

    dns_restore_managed_conf "$conf_path" "$backup_file" || return 1
    if [[ -f "$hook_file" ]] && LC_ALL=C grep -qx '# Managed by Zero.sh' "$hook_file" 2>/dev/null; then
        rm -f "$hook_file"
        DNS_SUB_RESTORED=1
    fi
}

dns_unsync_dhcpcd() {
    local conf_path backup_file
    conf_path=$(dns_dhcpcd_conf_path)
    [[ -n "$conf_path" ]] || return 0
    backup_file=$(dns_dhcpcd_backup_path "$conf_path")
    dns_restore_managed_conf "$conf_path" "$backup_file"
}

dns_should_sync_oci() {
    [[ -n "${DNS_OCI_CONF:-}" ]] || return 1
    [[ "$DNS_OCI_CONF" == "/etc/oci-hostname.conf" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] && return 1
    [[ -e "$DNS_OCI_CONF" || -L "$DNS_OCI_CONF" || -e "${DNS_OCI_CONF}.zero.bak" || "$DNS_OCI_CONF" != "/etc/oci-hostname.conf" ]] && return 0
    grep -qi 'oraclecloud' /sys/devices/virtual/dmi/id/chassis_asset_tag /sys/devices/virtual/dmi/id/board_vendor 2>/dev/null
}

dns_sync_oci() {
    dns_should_sync_oci || return 0
    local backup="${DNS_OCI_CONF}.zero.bak" tmp
    [[ ! -L "$DNS_OCI_CONF" && ! -L "$backup" ]] || return 1
    mkdir -p "$(dns_parent_dir "$DNS_OCI_CONF")" || return 1
    dns_prepare_managed_conf "$DNS_OCI_CONF" "$backup" || return 1
    tmp=$(mktemp "${DNS_OCI_CONF}.zero.XXXXXX") || return 1
    chmod 644 "$tmp"
    LC_ALL=C awk -v created="$DNS_PREP_CREATED" '
        BEGIN { if (created) print "# Created by Zero.sh" }
        /^[[:space:]]*# Created by Zero\.sh[[:space:]]*$/ { next }
        /^[[:space:]]*PRESERVE_HOSTINFO[[:space:]]*=/ {
            val = $0; sub(/^[^=]*=[[:space:]]*/, "", val); sub(/[[:space:]#].*$/, "", val)
            print (val == "1" || val == "3") ? "PRESERVE_HOSTINFO=3" : "PRESERVE_HOSTINFO=2"
            done_p = 1
            next
        }
        { print }
        END { if (!done_p) print "PRESERVE_HOSTINFO=2" }
    ' "$DNS_PREP_SRC" > "$tmp" && mv -f "$tmp" "$DNS_OCI_CONF" || { rm -f "$tmp"; return 1; }
}

dns_unsync_oci() {
    [[ -n "${DNS_OCI_CONF:-}" ]] || return 0
    [[ "$DNS_OCI_CONF" == "/etc/oci-hostname.conf" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] && return 0
    dns_restore_managed_conf "$DNS_OCI_CONF" "${DNS_OCI_CONF}.zero.bak"
}

dns_networkd_active() {
    if [[ "$DNS_NETWORKD_DIR" != "/etc/systemd/network" ]]; then
        [[ -d "$DNS_NETWORKD_DIR" || -d "$DNS_NETWORKD_RUN_DIR" ||
           ( "$DNS_NETWORKD_LIB_DIR" != "/usr/lib/systemd/network" && -d "$DNS_NETWORKD_LIB_DIR" ) ]]
        return $?
    fi
    [[ "$DNS_RESOLV_CONF" == "/etc/resolv.conf" ]] &&
        command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-networkd 2>/dev/null
}

dns_collect_networkd_ifaces() {
    local iface
    local -a ifaces=()
    if command -v networkctl >/dev/null 2>&1; then
        mapfile -t ifaces < <(
            networkctl list --no-legend --no-pager 2>/dev/null |
                awk '$2 != "" && $2 != "lo" && $NF != "unmanaged" { print $2 }'
        )
    fi
    if (( ${#ifaces[@]} == 0 )); then
        iface=$(get_default_interface)
        [[ -n "$iface" ]] && ifaces=("$iface")
    fi
    (( ${#ifaces[@]} > 0 )) && printf '%s\n' "${ifaces[@]}"
}

dns_revert_resolved_links() {
    command -v resolvectl >/dev/null 2>&1 || return 0
    local iface
    local -a ifaces=()
    mapfile -t ifaces < <(dns_collect_networkd_ifaces)
    for iface in ${ifaces[@]+"${ifaces[@]}"}; do
        case "$iface" in lo|wg*|tun*|tap*|warp*|CloudflareWARP*|tailscale*|zt*) continue ;; esac
        resolvectl revert "$iface" >/dev/null 2>&1 || true
    done
}

dns_reconfigure_networkd_links() {
    local revert_resolved="${1:-0}"
    local -a ifaces=()
    if command -v networkctl >/dev/null 2>&1; then
        networkctl reload >/dev/null 2>&1 || true
        mapfile -t ifaces < <(dns_collect_networkd_ifaces)
        (( ${#ifaces[@]} > 0 )) && networkctl reconfigure "${ifaces[@]}" >/dev/null 2>&1 || true
    fi
    (( revert_resolved == 1 )) && dns_revert_resolved_links
    return 0
}

dns_sync_networkd() {
    dns_networkd_active || return 0
    local net_dir net_file base drop_dir drop_file seen=" " wrote=0
    local -a search_dirs=("$DNS_NETWORKD_DIR" "$DNS_NETWORKD_RUN_DIR")
    if [[ "$DNS_NETWORKD_DIR" == "/etc/systemd/network" ]]; then
        search_dirs+=("$DNS_NETWORKD_LIB_DIR" "/lib/systemd/network")
    elif [[ "$DNS_NETWORKD_LIB_DIR" != "/usr/lib/systemd/network" ]]; then
        search_dirs+=("$DNS_NETWORKD_LIB_DIR")
    fi

    for net_dir in "${search_dirs[@]}"; do
        [[ -d "$net_dir" ]] || continue
        for net_file in "$net_dir"/*.network; do
            [[ -f "$net_file" ]] || continue
            LC_ALL=C grep -Eqi '^[[:space:]]*(Unmanaged[[:space:]]*=[[:space:]]*(yes|true|1)|Name[[:space:]]*=[[:space:]]*(lo|wg|tun|tap|warp|tailscale|zt))' "$net_file" 2>/dev/null && continue
            base="${net_file##*/}"
            case "$seen" in *" $base "*) continue ;; esac
            seen+="${base} "
            drop_dir="${DNS_NETWORKD_DIR}/${base}.d"
            drop_file="${drop_dir}/zz-zero-dns.conf"
            mkdir -p "$drop_dir" || return 1
            cat > "$drop_file" <<'EOF' || return 1
# Managed by Zero.sh
[Network]
DNS=
Domains=
DNSDefaultRoute=false
[DHCPv4]
UseDNS=false
UseDomains=false
[DHCPv6]
UseDNS=false
UseDomains=false
[IPv6AcceptRA]
UseDNS=false
UseDomains=false
EOF
            chmod 644 "$drop_file"
            wrote=1
        done
    done
    (( wrote == 1 )) && dns_reconfigure_networkd_links 1
    return 0
}

dns_unsync_networkd() {
    [[ "$DNS_NETWORKD_DIR" == "/etc/systemd/network" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] && return 0
    local drop_file drop_dir removed=0
    for drop_file in "$DNS_NETWORKD_DIR"/*.network.d/zz-zero-dns.conf; do
        [[ -f "$drop_file" ]] || continue
        LC_ALL=C grep -qx '# Managed by Zero.sh' "$drop_file" 2>/dev/null || continue
        drop_dir="${drop_file%/*}"
        rm -f "$drop_file"
        rmdir "$drop_dir" 2>/dev/null || true
        removed=1
    done
    if (( removed == 1 )); then
        DNS_SUB_RESTORED=1
        dns_reconfigure_networkd_links 0
    fi
    return 0
}

dns_sync_nm() {
    local active=0
    if [[ "$DNS_NM_DROPIN" != "/etc/NetworkManager/conf.d/90-zero-dns.conf" ]]; then
        [[ -d "$(dns_parent_dir "$DNS_NM_DROPIN")" ]] && active=1
    elif [[ "$DNS_RESOLV_CONF" == "/etc/resolv.conf" ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        active=1
    fi
    (( active == 1 )) || return 0
    mkdir -p "$(dns_parent_dir "$DNS_NM_DROPIN")" || return 1
    printf '# Managed by Zero.sh\n[main]\ndns=none\nsystemd-resolved=false\n' > "$DNS_NM_DROPIN" || return 1
    chmod 644 "$DNS_NM_DROPIN"
    command -v systemctl >/dev/null 2>&1 && systemctl reload NetworkManager >/dev/null 2>&1 || true
    return 0
}

dns_unsync_nm() {
    [[ "$DNS_NM_DROPIN" == "/etc/NetworkManager/conf.d/90-zero-dns.conf" && "$DNS_RESOLV_CONF" != "/etc/resolv.conf" ]] && return 0
    if [[ -f "$DNS_NM_DROPIN" ]] && LC_ALL=C grep -qx '# Managed by Zero.sh' "$DNS_NM_DROPIN" 2>/dev/null; then
        rm -f "$DNS_NM_DROPIN"
        DNS_SUB_RESTORED=1
        command -v systemctl >/dev/null 2>&1 && systemctl reload NetworkManager >/dev/null 2>&1 || true
    fi
    return 0
}

dns_migrate_resolved_config() {
    if [[ -e "$DNS_RESOLVED_PREVIOUS_FILE" || -L "$DNS_RESOLVED_PREVIOUS_FILE" ]]; then
        if [[ -L "$DNS_RESOLVED_PREVIOUS_FILE" || -e "$DNS_RESOLVED_DROPIN_FILE" || -L "$DNS_RESOLVED_DROPIN_FILE" ]] ||
           ! LC_ALL=C grep -qx '# Managed by Zero.sh' "$DNS_RESOLVED_PREVIOUS_FILE" 2>/dev/null; then
            echo -e "${RED}检测到冲突 DNS 配置: ${DNS_RESOLVED_PREVIOUS_FILE}${PLAIN}" >&2
            return 1
        fi
        mv -f "$DNS_RESOLVED_PREVIOUS_FILE" "$DNS_RESOLVED_DROPIN_FILE" || return 1
    fi
}

dns_apply_static() {
    local ip v4_csv="" v6_csv="" conf_dir resolv_backup temp header="# Managed by Zero.sh"
    local had_existing=0 created_backup=0 prev_copy=""

    [[ $# -gt 0 ]] || return 1
    [[ ! -d "$DNS_RESOLV_CONF" ]] || { echo -e "${RED}${DNS_RESOLV_CONF} 是目录，无法写入${PLAIN}" >&2; return 1; }

    for ip in "$@"; do
        if dns_is_valid_ipv4 "$ip"; then
            v4_csv+="${v4_csv:+, }$ip"
        else
            v6_csv+="${v6_csv:+, }$ip"
        fi
    done

    dns_unlock_resolv_if_needed "$DNS_RESOLV_CONF" || return 1
    conf_dir=$(dns_parent_dir "$DNS_RESOLV_CONF")
    mkdir -p "$conf_dir" || return 1
    resolv_backup=$(dns_resolv_backup_path)

    if [[ -L "$DNS_RESOLV_CONF" || -f "$DNS_RESOLV_CONF" ]]; then
        had_existing=1
        if [[ ! -L "$DNS_RESOLV_CONF" ]] && LC_ALL=C grep -Eq '^[[:space:]]*# Created by Zero\.sh[[:space:]]*$' "$DNS_RESOLV_CONF" 2>/dev/null; then
            header="# Created by Zero.sh"
        elif [[ ! -L "$resolv_backup" && ! -f "$resolv_backup" ]]; then
            dns_copy_preserve "$DNS_RESOLV_CONF" "$resolv_backup" || return 1
            created_backup=1
        fi
        prev_copy=$(mktemp "$conf_dir/.resolv.prev.XXXXXX") || return 1
        dns_copy_preserve "$DNS_RESOLV_CONF" "$prev_copy" || { rm -f "$prev_copy"; return 1; }
    else
        header="# Created by Zero.sh"
    fi

    temp=$(mktemp "$conf_dir/.resolv.new.XXXXXX") || { rm -f "$prev_copy"; return 1; }
    chmod 644 "$temp"
    {
        printf '%s\n' "$header"
        for ip in "$@"; do
            printf 'nameserver %s\n' "$ip"
        done
    } > "$temp" || { rm -f "$temp" "$prev_copy"; return 1; }

    if ! mv -f "$temp" "$DNS_RESOLV_CONF"; then
        rm -f "$temp" "$prev_copy"
        (( created_backup == 1 )) && rm -f "$resolv_backup"
        return 1
    fi

    if { dns_should_sync_dhclient && ! dns_sync_dhclient "$v4_csv" "$v6_csv" "$@"; } ||
       { dns_should_sync_dhcpcd && ! dns_sync_dhcpcd; } ||
       ! dns_sync_oci || ! dns_sync_networkd || ! dns_sync_nm; then
        if (( had_existing == 1 )); then
            dns_replace_resolv "$prev_copy" 2>/dev/null || true
        else
            rm -f "$DNS_RESOLV_CONF"
        fi
        (( created_backup == 1 )) && rm -f "$resolv_backup"
        rm -f "$prev_copy"
        return 1
    fi

    rm -f "$prev_copy"
    return 0
}

dns_apply_resolved() {
    local resolv_backup resolved_backup temp_dropin link_target="" ip v4_csv="" v6_csv=""
    local primary_dns="" fallback_dns=""
    local -a v4_arr=() v6_arr=()
    [[ $# -gt 0 ]] || return 1

    for ip in "$@"; do
        if dns_is_valid_ipv4 "$ip"; then
            v4_arr+=("$ip")
            v4_csv+="${v4_csv:+, }$ip"
        else
            v6_arr+=("$ip")
            v6_csv+="${v6_csv:+, }$ip"
        fi
    done
    if (( ${DNS_SPLIT_DUAL_FALLBACK:-0} == 1 && ${#v4_arr[@]} > 0 && ${#v6_arr[@]} > 0 )); then
        primary_dns="${v4_arr[*]}"
        fallback_dns="${v6_arr[*]}"
    else
        primary_dns="$*"
    fi

    dns_migrate_resolved_config || return 1
    dns_unlock_resolv_if_needed "$DNS_RESOLV_CONF" || return 1
    mkdir -p "$DNS_RESOLVED_DROPIN_DIR" || return 1

    temp_dropin=$(mktemp "$DNS_RESOLVED_DROPIN_DIR/.zz-zero-dns.XXXXXX") || return 1
    chmod 644 "$temp_dropin"
    {
        printf '# Managed by Zero.sh\n[Resolve]\nDNS=%s\nFallbackDNS=%s\nDomains=~.\nDNSSEC=no\n' "$primary_dns" "$fallback_dns"
    } > "$temp_dropin" && mv -f "$temp_dropin" "$DNS_RESOLVED_DROPIN_FILE" || {
        rm -f "$temp_dropin"
        return 1
    }

    dns_sync_oci || return 1
    dns_sync_networkd || return 1
    dns_sync_nm || return 1
    if dns_should_sync_dhclient; then
        dns_sync_dhclient "$v4_csv" "$v6_csv" "$@" || return 1
    fi
    if dns_should_sync_dhcpcd; then
        dns_sync_dhcpcd || return 1
    fi

    if ! systemctl restart systemd-resolved 2>/dev/null || ! dns_systemd_resolved_active; then
        echo -e "${RED}systemd-resolved 重启失败${PLAIN}" >&2
        return 1
    fi
    dns_networkd_active && dns_revert_resolved_links

    resolv_backup=$(dns_resolv_backup_path)
    resolved_backup=$(dns_resolved_resolv_backup_path)
    local target_resolv="$DNS_RESOLVED_STUB" resolved_run_dir stub_disabled=0
    resolved_run_dir=$(dns_parent_dir "$DNS_RESOLVED_STUB")
    if LC_ALL=C grep -REqs '^[[:space:]]*DNSStubListener[[:space:]]*=[[:space:]]*(no|false|0)[[:space:]]*(#.*)?$' \
        "$(dns_parent_dir "$DNS_RESOLVED_DROPIN_DIR")/resolved.conf" "$DNS_RESOLVED_DROPIN_DIR" 2>/dev/null &&
       [[ -e "${resolved_run_dir}/resolv.conf" ]]; then
        target_resolv="${resolved_run_dir}/resolv.conf"
        stub_disabled=1
    elif [[ ! -e "$target_resolv" && -e "${resolved_run_dir}/resolv.conf" ]]; then
        target_resolv="${resolved_run_dir}/resolv.conf"
    fi
    if [[ -e "$target_resolv" ]]; then
        link_target=$(readlink "$DNS_RESOLV_CONF" 2>/dev/null || true)
        if [[ ( $stub_disabled -eq 1 && "$link_target" == *"systemd/resolve/stub-resolv.conf" ) ||
              ( "$link_target" != *"systemd/resolve/stub-resolv.conf" && "$link_target" != *"systemd/resolve/resolv.conf" ) ]]; then
            if [[ ! -L "$resolved_backup" && ! -f "$resolved_backup" ]]; then
                if [[ -L "$resolv_backup" || -f "$resolv_backup" ]]; then
                    mv -f "$resolv_backup" "$resolved_backup" || return 1
                elif [[ -L "$DNS_RESOLV_CONF" || -f "$DNS_RESOLV_CONF" ]] &&
                     ! LC_ALL=C grep -Eq '^[[:space:]]*# (Managed|Created) by Zero\.sh[[:space:]]*$' "$DNS_RESOLV_CONF" 2>/dev/null; then
                    dns_copy_preserve "$DNS_RESOLV_CONF" "$resolved_backup" || return 1
                fi
            fi
            ln -sfn "$target_resolv" "$DNS_RESOLV_CONF" || return 1
        fi
    fi

    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
    return 0
}

dns_apply() {
    local ip seen=" "
    local -a ok=()

    for ip in "$@"; do
        ip=$(trim_input "$ip")
        [[ -n "$ip" ]] || continue
        if ! dns_is_valid_ip "$ip"; then
            echo -e "${RED}无效的 DNS 地址: ${ip}${PLAIN}" >&2
            return 1
        fi
        case "$seen" in *" $ip "*) continue ;; esac
        seen+="${ip} "
        ok+=("$ip")
    done

    if (( ${#ok[@]} == 0 )); then
        echo -e "${RED}未提供有效的 DNS 地址${PLAIN}" >&2
        return 1
    fi

    if ! dns_systemd_resolved_active && (( ${#ok[@]} > 3 )); then
        echo -e "${YELLOW}提示: 当前为静态 resolv.conf 模式，glibc 最多使用前 3 个 DNS (MAXNS=3)${PLAIN}"
    fi

    if dns_systemd_resolved_active; then
        dns_apply_resolved "${ok[@]}"
    else
        dns_apply_static "${ok[@]}"
    fi
}

dns_restore() {
    local changed=0 resolv_backup resolved_backup dhclient_conf dhclient_backup dhcpcd_conf dhcpcd_backup
    local has_resolv_backup=0 has_resolv_created=0 restored_resolved=0 need_restart_resolved=0

    dns_migrate_resolved_config || return 1
    resolv_backup=$(dns_resolv_backup_path)
    resolved_backup=$(dns_resolved_resolv_backup_path)
    dhclient_conf=$(dns_dhclient_conf_path)
    dhcpcd_conf=$(dns_dhcpcd_conf_path)

    if [[ ( ! -L "$resolv_backup" && -e "$resolv_backup" && ! -f "$resolv_backup" ) ||
          ( ! -L "$resolved_backup" && -e "$resolved_backup" && ! -f "$resolved_backup" ) ]]; then
        echo -e "${RED}DNS 备份路径异常，已取消恢复${PLAIN}"
        return 1
    fi
    if [[ -n "$dhclient_conf" ]]; then
        dhclient_backup=$(dns_dhclient_backup_path "$dhclient_conf")
        if [[ -L "$dhclient_backup" || ( -e "$dhclient_backup" && ! -f "$dhclient_backup" ) ]] ||
           { [[ -f "$dhclient_backup" ]] && [[ -L "$dhclient_conf" || ( -e "$dhclient_conf" && ! -f "$dhclient_conf" ) ]]; }; then
            echo -e "${RED}dhclient 配置或备份路径异常，已取消恢复${PLAIN}"
            return 1
        fi
    fi
    if [[ -n "$dhcpcd_conf" ]]; then
        dhcpcd_backup=$(dns_dhcpcd_backup_path "$dhcpcd_conf")
        if [[ -L "$dhcpcd_backup" || ( -e "$dhcpcd_backup" && ! -f "$dhcpcd_backup" ) ]] ||
           { [[ -f "$dhcpcd_backup" ]] && [[ -L "$dhcpcd_conf" || ( -e "$dhcpcd_conf" && ! -f "$dhcpcd_conf" ) ]]; }; then
            echo -e "${RED}dhcpcd 配置或备份路径异常，已取消恢复${PLAIN}"
            return 1
        fi
    fi

    [[ -L "$resolv_backup" || -f "$resolv_backup" ]] && has_resolv_backup=1
    if (( has_resolv_backup == 0 )) && [[ ! -L "$DNS_RESOLV_CONF" && -f "$DNS_RESOLV_CONF" ]] &&
       LC_ALL=C grep -Eq '^[[:space:]]*# Created by Zero\.sh[[:space:]]*$' "$DNS_RESOLV_CONF" 2>/dev/null; then
        has_resolv_created=1
    fi

    if [[ -f "$DNS_RESOLVED_DROPIN_FILE" || -L "$resolved_backup" || -f "$resolved_backup" ]]; then
        need_restart_resolved=1
        dns_unlock_resolv_if_needed "$DNS_RESOLV_CONF" || return 1
        rm -f "$DNS_RESOLVED_DROPIN_FILE" || return 1
        if [[ -L "$resolved_backup" || -f "$resolved_backup" ]]; then
            dns_replace_resolv "$resolved_backup" || return 1
            rm -f "$resolved_backup"
            restored_resolved=1
        fi
        changed=1
    fi

    if (( has_resolv_backup == 1 )); then
        if [[ -L "$DNS_RESOLV_CONF" && $restored_resolved -eq 1 ]]; then
            rm -f "$resolv_backup"
        elif [[ -L "$DNS_RESOLV_CONF" && ! -L "$resolv_backup" ]]; then
            echo -e "${YELLOW}${DNS_RESOLV_CONF} 当前为符号链接，未覆盖静态备份${PLAIN}"
            return 1
        else
            dns_unlock_resolv_if_needed "$DNS_RESOLV_CONF" || return 1
            dns_replace_resolv "$resolv_backup" || return 1
            rm -f "$resolv_backup"
            changed=1
        fi
    elif (( has_resolv_created == 1 )); then
        dns_unlock_resolv_if_needed "$DNS_RESOLV_CONF" || return 1
        rm -f "$DNS_RESOLV_CONF" || return 1
        changed=1
    fi

    DNS_SUB_RESTORED=0
    dns_unsync_dhclient || return 1
    dns_unsync_dhcpcd || return 1
    dns_unsync_oci || return 1
    dns_unsync_networkd || return 1
    dns_unsync_nm || return 1
    (( DNS_SUB_RESTORED == 1 )) && changed=1

    if (( ${need_restart_resolved:-0} == 1 )) && dns_systemd_resolved_active; then
        systemctl restart systemd-resolved 2>/dev/null || return 1
    fi

    if (( changed == 0 )); then
        echo -e "${YELLOW}未找到 Zero.sh 创建的 DNS 配置或备份${PLAIN}"
        return 2
    fi

    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
    return 0
}

dns_read_runtime_status() {
    local active="0" iface="" dns_list=""
    if dns_systemd_resolved_active; then
        active="1"
        iface="$(get_default_interface)"
        if command -v resolvectl >/dev/null 2>&1; then
            dns_list="$(resolvectl dns 2>/dev/null | awk -F':[[:space:]]+' '
                NF > 1 {
                    count = split($2, server, /[[:space:]]+/)
                    for (i = 1; i <= count; i++)
                        if (server[i] != "" && server[i] != "(none)" && !seen[server[i]]++) print server[i]
                }
            ')"
        fi
    fi
    printf '%s\n' "$active" "$iface"
    [[ -n "$dns_list" ]] && printf '%s\n' "$dns_list"
}

dns_zero_persistence_summary() {
    local resolv_backup resolved_backup dhclient_conf dhclient_backup hook_dir hook_file dhcpcd_conf dhcpcd_backup
    local has_backup=0 mode_text="" backup_text=""
    local -a components=()

    resolv_backup=$(dns_resolv_backup_path)
    resolved_backup=$(dns_resolved_resolv_backup_path)
    dhclient_conf=$(dns_dhclient_conf_path)
    dhcpcd_conf=$(dns_dhcpcd_conf_path)

    if [[ -f "$DNS_RESOLVED_DROPIN_FILE" || -f "$DNS_RESOLVED_PREVIOUS_FILE" ]]; then
        components+=("systemd-resolved")
    fi
    if [[ ! -L "$DNS_RESOLV_CONF" && -f "$DNS_RESOLV_CONF" ]] &&
       LC_ALL=C grep -Eq '^[[:space:]]*# (Managed|Created) by Zero\.sh[[:space:]]*$' "$DNS_RESOLV_CONF" 2>/dev/null; then
        components+=("静态 resolv.conf")
    fi
    if [[ -n "$dhclient_conf" ]]; then
        dhclient_backup=$(dns_dhclient_backup_path "$dhclient_conf")
        hook_dir=$(dns_dhclient_hook_dir_path "$dhclient_conf")
        hook_file=$(dns_dhclient_hook_file_path "$hook_dir")
        if { [[ -f "$dhclient_conf" ]] && LC_ALL=C grep -Eq '^[[:space:]]*# (Created by Zero\.sh|BEGIN Zero\.sh DNS)[[:space:]]*$' "$dhclient_conf" 2>/dev/null; } ||
           { [[ -f "$hook_file" ]] && LC_ALL=C grep -qx '# Managed by Zero.sh' "$hook_file" 2>/dev/null; }; then
            components+=("dhclient")
        fi
        [[ -f "$dhclient_backup" ]] && has_backup=1
    fi
    if [[ -n "$dhcpcd_conf" ]]; then
        dhcpcd_backup=$(dns_dhcpcd_backup_path "$dhcpcd_conf")
        if [[ -f "$dhcpcd_conf" ]] && LC_ALL=C grep -Eq '^[[:space:]]*# (Created by Zero\.sh|BEGIN Zero\.sh DNS)[[:space:]]*$' "$dhcpcd_conf" 2>/dev/null; then
            components+=("dhcpcd")
        fi
        [[ -f "$dhcpcd_backup" ]] && has_backup=1
    fi
    if [[ "$DNS_NETWORKD_DIR" != "/etc/systemd/network" || "$DNS_RESOLV_CONF" == "/etc/resolv.conf" ]] &&
       compgen -G "$DNS_NETWORKD_DIR/*.network.d/zz-zero-dns.conf" >/dev/null 2>&1; then
        components+=("networkd")
    fi
    if [[ "$DNS_NM_DROPIN" != "/etc/NetworkManager/conf.d/90-zero-dns.conf" || "$DNS_RESOLV_CONF" == "/etc/resolv.conf" ]] &&
       [[ -f "$DNS_NM_DROPIN" ]] && LC_ALL=C grep -qx '# Managed by Zero.sh' "$DNS_NM_DROPIN" 2>/dev/null; then
        components+=("NetworkManager")
    fi
    if [[ -n "${DNS_OCI_CONF:-}" && ( "$DNS_OCI_CONF" != "/etc/oci-hostname.conf" || "$DNS_RESOLV_CONF" == "/etc/resolv.conf" ) ]] &&
       { [[ -f "${DNS_OCI_CONF}.zero.bak" ]] || { [[ -f "$DNS_OCI_CONF" ]] && LC_ALL=C grep -Eq '^[[:space:]]*# Created by Zero\.sh[[:space:]]*$' "$DNS_OCI_CONF" 2>/dev/null; }; }; then
        components+=("OCI防还原")
        has_backup=1
    fi
    [[ -L "$resolv_backup" || -f "$resolv_backup" || -L "$resolved_backup" || -f "$resolved_backup" ]] && has_backup=1

    if (( ${#components[@]} > 0 )); then
        local joined="${components[0]}" idx
        for ((idx = 1; idx < ${#components[@]}; idx++)); do
            joined+=" + ${components[$idx]}"
        done
        mode_text="${GREEN}已接管 (${joined})${PLAIN}"
        backup_text=" | 原始备份: ${GREEN}可恢复${PLAIN}"
    elif (( has_backup == 1 )); then
        mode_text="${YELLOW}存在备份 (当前配置已被外部修改)${PLAIN}"
        backup_text=" | 原始备份: ${GREEN}可恢复${PLAIN}"
    else
        mode_text="${YELLOW}未接管 (系统原始配置)${PLAIN}"
    fi
    printf '%s%s\n' "$mode_text" "$backup_text"
}

dns_show_current() {
    local iface="" dns_list="" resolved_active="0" dns="" trimmed=""
    local stack_mode="${1:-}" link_target="" imm_flags="" ns_count=0 is_resolved_stub=0
    local -a dns_status=()

    [[ -n "$stack_mode" ]] || stack_mode=$(dns_detect_stack)
    echo -e "${YELLOW}当前DNS配置:${PLAIN}"
    echo -e "${BLUE}网络环境:${PLAIN} $(dns_stack_label "$stack_mode")"
    echo -e "${BLUE}托管状态:${PLAIN} $(dns_zero_persistence_summary)"
    echo

    echo -e "${BLUE}resolv.conf:${PLAIN}"
    if [[ -L "$DNS_RESOLV_CONF" ]]; then
        link_target=$(readlink "$DNS_RESOLV_CONF" 2>/dev/null || echo "unknown")
        [[ "$link_target" == *"systemd/resolve/stub-resolv.conf" ]] && is_resolved_stub=1
        if [[ -e "$DNS_RESOLV_CONF" ]]; then
            echo -e "  符号链接: ${YELLOW}${link_target}${PLAIN}"
        else
            echo -e "  符号链接: ${RED}${link_target} (目标不存在)${PLAIN}"
        fi
    else
        imm_flags=$(dns_get_immutable_flags "$DNS_RESOLV_CONF" || true)
        [[ -n "$imm_flags" ]] && echo -e "  文件锁定: ${YELLOW}chattr +${imm_flags}${PLAIN}"
    fi

    if [[ -f "$DNS_RESOLV_CONF" ]]; then
        while IFS= read -r dns || [[ -n "$dns" ]]; do
            [[ "$dns" =~ ^[[:space:]]*nameserver[[:space:]]+ ]] || continue
            trimmed=$(trim_input "$dns")
            ns_count=$((ns_count + 1))
            echo -e "  ${GREEN}${trimmed}${PLAIN}"
        done < "$DNS_RESOLV_CONF"
        if (( ns_count == 0 )); then
            echo -e "  (未配置 nameserver)"
        elif (( ns_count > 3 && is_resolved_stub == 0 )); then
            echo -e "  ${YELLOW}(提示: 共 ${ns_count} 条，glibc 静态解析最多仅使用前 3 条 MAXNS=3)${PLAIN}"
        fi
    elif [[ ! -L "$DNS_RESOLV_CONF" ]]; then
        echo -e "  (不存在)"
    fi
    echo

    echo -e "${BLUE}systemd-resolved:${PLAIN}"
    mapfile -t dns_status < <(dns_read_runtime_status)
    resolved_active="${dns_status[0]:-0}"
    iface="${dns_status[1]:-}"
    (( ${#dns_status[@]} > 2 )) && dns_list=$(printf '%s\n' "${dns_status[@]:2}")

    if [[ "$resolved_active" == "1" ]]; then
        [[ -n "$iface" ]] && echo -e "  默认网卡: ${GREEN}${iface}${PLAIN}" || echo -e "  (未检测到默认网卡)"
        if [[ -n "$dns_list" ]]; then
            echo -e "  可见 DNS Servers:"
            while IFS= read -r dns || [[ -n "$dns" ]]; do
                [[ -n "$dns" ]] && echo -e "    ${GREEN}- ${dns}${PLAIN}"
            done <<< "$dns_list"
        else
            echo -e "  (未检测到 systemd-resolved DNS)"
        fi
    else
        echo -e "  (systemd-resolved 未运行)"
    fi
    echo
}

dns_apply_with_feedback() {
    if dns_apply "$@"; then
        echo -e "${GREEN}DNS 配置已更新${PLAIN}"
    else
        echo -e "${RED}DNS修改失败${PLAIN}"
    fi
    press_any_key_to_continue
}

dns_restore_with_feedback() {
    local result=0
    dns_restore || result=$?
    case "$result" in
        0) echo -e "${GREEN}DNS 已恢复${PLAIN}" ;;
        2) ;;
        *) echo -e "${RED}DNS 恢复失败${PLAIN}" ;;
    esac
    press_any_key_to_continue
}

dns_public_menu_hint() {
    case "$1" in
        ipv6) printf '%s' "${GREEN}2001:4860:4860::8888${PLAIN} / ${GREEN}2606:4700:4700::1111${PLAIN} (纯IPv6)" ;;
        dual) printf '%s' "${GREEN}Google${PLAIN} / ${GREEN}Cloudflare${PLAIN} (双栈自动适配)" ;;
        *)    printf '%s' "${GREEN}8.8.8.8${PLAIN} / ${GREEN}1.1.1.1${PLAIN}" ;;
    esac
}

dns_apply_public() {
    local stack_mode
    stack_mode=$(dns_detect_stack)
    case "$stack_mode" in
        ipv6)
            echo -e "${BLUE}检测到纯 IPv6 网络，选用 IPv6 公共 DNS: ${GREEN}2001:4860:4860::8888 / 2606:4700:4700::1111${PLAIN}"
            dns_apply_with_feedback "2001:4860:4860::8888" "2606:4700:4700::1111"
            ;;
        dual)
            echo -e "${BLUE}检测到双栈网络，选用双栈公共 DNS: ${GREEN}8.8.8.8 / 1.1.1.1 / 2001:4860:4860::8888${PLAIN}"
            DNS_SPLIT_DUAL_FALLBACK=1 dns_apply_with_feedback "8.8.8.8" "1.1.1.1" "2001:4860:4860::8888"
            ;;
        *)
            dns_apply_with_feedback "8.8.8.8" "1.1.1.1"
            ;;
    esac
}

dns_read_custom_servers() {
    local line="" tok="" eof_reached=0
    echo -e "\n${YELLOW}请输入DNS(每行一个或空格/逗号分隔，空行结束；静态解析建议不超过3个):${PLAIN}" >&2
    while true; do
        read -r -p "> " line || eof_reached=1
        line=$(trim_input "$line")
        [[ -z "$line" ]] && break
        line="${line//,/ }"
        for tok in $line; do
            [[ -n "$tok" ]] && printf '%s\n' "$tok"
        done
        (( eof_reached == 1 )) && break
    done
}

dns_enable_nat64() {
    local stack_mode
    stack_mode=$(dns_detect_stack)
    if [[ "$stack_mode" == "ipv4" || "$stack_mode" == "none" ]]; then
        echo -e "${RED}未检测到可用的 IPv6 路由，已阻止写入纯 IPv6 NAT64 DNS（否则会导致 DNS 解析中断）${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    [[ "$stack_mode" == "dual" ]] && echo -e "${YELLOW}提示: 本机已具备双栈网络，通常无需启用 NAT64${PLAIN}"
    echo -e "${YELLOW}使用 nat64.net 公共 DNS64/NAT64 (https://nat64.net/tos)${PLAIN}"
    dns_apply_with_feedback "2a00:1098:2c::1" "2a01:4f9:c010:3f02::1" "2a00:1098:2b::1"
}

dns_test_nat64() {
    local http_code="" stack_mode="" wget_headers=""
    echo -e "${YELLOW}正在测试 GitHub API 的 IPv6 连接...${PLAIN}"
    stack_mode=$(dns_detect_stack)
    if [[ "$stack_mode" == "ipv4" || "$stack_mode" == "none" ]]; then
        echo -e "${RED}未检测到可用的 IPv6 路由，无法建立 IPv6 / NAT64 连接${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    if command -v curl >/dev/null 2>&1; then
        if http_code=$(curl -6 --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 https://api.github.com); then
            case "$http_code" in
                2??) echo -e "${GREEN}IPv6 HTTPS 连通，GitHub API 访问成功（HTTP ${http_code}）${PLAIN}" ;;
                *)   echo -e "${YELLOW}IPv6 HTTPS 连通，但 GitHub API 返回 HTTP ${http_code}${PLAIN}" ;;
            esac
        else
            echo -e "${RED}IPv6 HTTPS 连接失败，请检查 DNS、网络或 NAT64 服务${PLAIN}"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget_headers=$(wget -6 --no-proxy --spider -S --timeout=10 --tries=1 https://api.github.com 2>&1); then
            http_code=$(printf '%s\n' "$wget_headers" | awk '/^[[:space:]]*HTTP\/[0-9.]+[[:space:]]+[0-9]+/ {code=$2} END {print code}')
            echo -e "${GREEN}IPv6 HTTPS 连通，GitHub API 访问成功（HTTP ${http_code:-200}）${PLAIN}"
        else
            echo -e "${RED}IPv6 HTTPS 连接失败，请检查 DNS、网络或 NAT64 服务${PLAIN}"
        fi
    else
        echo -e "${RED}未安装 curl 或 wget，无法测试${PLAIN}"
    fi
    press_any_key_to_continue
}

dns_fix() {
    local choice stack_mode
    local -a custom_dns=()
    while true; do
        stack_mode=$(dns_detect_stack)
        clear
        echo -e "${BLUE}======== DNS 配置工具 ========${PLAIN}\n"
        dns_show_current "$stack_mode"
        echo -e "${GREEN}1.${PLAIN}使用公共DNS $(dns_public_menu_hint "$stack_mode")"
        echo -e "${GREEN}2.${PLAIN}自定义DNS"
        echo -e "${GREEN}3.${PLAIN}恢复原始DNS配置"
        echo -e "${GREEN}4.${PLAIN}启用NAT64 ${GREEN}nat64.net${PLAIN} (IPv6访问IPv4)"
        echo -e "${GREEN}5.${PLAIN}测试NAT64连接"
        echo -e "${YELLOW}0.${PLAIN}返回主菜单"
        echo -e "${BLUE}==============================${PLAIN}"
        choice=$(read_menu_choice "请输入选项 [0-5]: ") || return 1
        case "$choice" in
            1) dns_apply_public ;;
            2)
                clear
                mapfile -t custom_dns < <(dns_read_custom_servers)
                if (( ${#custom_dns[@]} == 0 )); then
                    echo -e "${YELLOW}未输入DNS${PLAIN}"
                    press_any_key_to_continue
                else
                    dns_apply_with_feedback "${custom_dns[@]}"
                fi
                ;;
            3) dns_restore_with_feedback ;;
            4) dns_enable_nat64 ;;
            5) dns_test_nat64 ;;
            0) return ;;
            *) show_invalid_option ;;
        esac
    done
}

ssh_config_menu() {
    local current_port permit_root_login pass_auth pubkey_auth
    local root_login_text password_login_text pubkey_login_text ssh_choice
    local -a ssh_status

    while true; do
        mapfile -t ssh_status < <(ssh_read_status)
        current_port="${ssh_status[0]}"
        permit_root_login="${ssh_status[1]}"
        pass_auth="${ssh_status[2]}"
        pubkey_auth="${ssh_status[3]}"

        root_login_text=$(ssh_root_login_label "$permit_root_login")
        password_login_text=$(ssh_status_label "$pass_auth")
        pubkey_login_text=$(ssh_pubkey_status_label "$pubkey_auth" "${ssh_status[4]:-}")

        clear
        echo -e "${BLUE}======== SSH ========${PLAIN}"
        echo -e "${BLUE}端口 ${YELLOW}${current_port}${PLAIN} | Root ${root_login_text}"
        echo -e "${BLUE}密码 ${password_login_text} | 密钥 ${pubkey_login_text}"
        echo -e "${BLUE}======================${PLAIN}"
        echo -e "${GREEN}1.设置密码${PLAIN}  ${GREEN}2.设置密钥${PLAIN}"
        echo -e "${BLUE}3.修改端口${PLAIN}  ${RED}4.修改登录${PLAIN}"
        echo -e "${YELLOW}0.返回菜单${PLAIN}"
        echo -e "${BLUE}======================${PLAIN}"
        ssh_choice=$(read_menu_choice "请输入选项 [0-4]: ") || return 1
        case "$ssh_choice" in
            1) enable_or_change_root_password ;;
            2) enable_root_key_login ;;
            3) change_ssh_port ;;
            4) disable_ssh_login_menu ;;
            0) return ;;
            *) show_invalid_option "无效选项，请重试" "0.3" ;;
        esac
    done
}

change_ssh_port() {
    while true; do
        clear
        local current_port old_port new_port
        current_port=$(ssh_get_current_port)
        old_port="$current_port"
        echo -e "${YELLOW}当前SSH端口: ${GREEN}${current_port:-22}${PLAIN}\n"
        new_port=$(read_menu_choice "请输入新的SSH端口(输入0返回): ") || return 1
        [[ "$new_port" == "0" ]] && return
        if zero_is_valid_port "$new_port"; then
            if [[ "$new_port" == "$old_port" ]]; then
                echo -e "${YELLOW}SSH 端口已是 ${old_port},无需修改${PLAIN}"
                press_any_key_to_continue
                return
            fi
            if zero_port_is_listening "$new_port" tcp; then
                echo -e "${RED}TCP ${new_port} 已被占用，请选择其他端口${PLAIN}"
                press_any_key_to_continue
                continue
            fi

            if ! firewall_can_change_ssh_port "$new_port"; then
                echo -e "${RED}当前防火墙未放行 TCP ${new_port},请先到 FireWall -> 放行端口 中放行后再修改 SSH 端口${PLAIN}"
                press_any_key_to_continue
                continue
            fi

            if ! update_sshd_option "Port" "$new_port"; then
                echo -e "${RED}写入 SSH 端口配置失败,请检查 ${SSHD_CONFIG}${PLAIN}"
                press_any_key_to_continue
                continue
            fi

            if restart_sshd_safe "$new_port"; then
                echo -e "${YELLOW}[✓]SSH端口已修改为 $new_port${PLAIN}"
                press_any_key_to_continue
                return
            fi

            if update_sshd_option "Port" "$old_port" && restart_sshd_safe "$old_port" >/dev/null 2>&1; then
                echo -e "${YELLOW}已自动回滚到原 SSH 端口 ${old_port}${PLAIN}"
            else
                echo -e "${RED}回滚到原 SSH 端口 ${old_port} 失败,请立即通过控制台检查 SSH 配置${PLAIN}"
            fi
            press_any_key_to_continue
            continue
        else
            echo "[!] 无效的端口格式"
            press_any_key_to_continue
        fi
    done
}

enable_or_change_root_password() {
    local input
    clear
    echo -e "${YELLOW}设置 Root 密码并启用密码登录${PLAIN}"
    echo
    input=$(read_menu_choice "按回车继续,输入0返回: ") || return 1
    if [[ "$input" == "0" ]]; then
        return
    fi

    passwd root || { echo -e "${RED}密码设置失败${PLAIN}"; press_any_key_to_continue; return; }
    
    update_sshd_option "PermitRootLogin" "yes" || return 1
    update_sshd_option "PasswordAuthentication" "yes" || return 1
    
    if restart_sshd_safe; then
        echo -e "${GREEN}[✓]Root密码已设置,密码登录已启用${PLAIN}"
    fi
    press_any_key_to_continue
}

ssh_root_has_password() {
    [[ -r /etc/shadow ]] || return 0
    awk -F: '$1 == "root" { found = 1; ok = ($2 != "" && $2 !~ /^[!*]/); exit } END { exit(found ? !ok : 0) }' /etc/shadow 2>/dev/null
}

enable_root_key_login() {
    clear
    local SSH_DIR="$ROOT_HOME/.ssh"
    local AUTH_KEYS="$SSH_DIR/authorized_keys"
    local TMP_KEY TMP_PUB key_dir set_passwd
    local key_passphrase=""

    mkdir -p "$SSH_DIR" || return 1
    chmod 700 "$SSH_DIR" || return 1
    touch "$AUTH_KEYS" || return 1
    chmod 600 "$AUTH_KEYS" || return 1

    echo -e "${BLUE}是否需要为私钥设置密码？${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}是"
    echo -e "${GREEN}2.${PLAIN}否"
    echo -e "${YELLOW}0.${PLAIN}返回上级"
    set_passwd=$(read_menu_choice "choice [0-2]: ") || return 1

    if [[ "$set_passwd" == "0" ]]; then
        return 0
    fi
    if [[ "$set_passwd" != "1" && "$set_passwd" != "2" ]]; then
        echo -e "${RED}输入无效,已返回上级${PLAIN}"
        sleep 0.3
        return
    fi

    if [[ "$set_passwd" == "1" ]]; then
        clear
        echo -e "${BLUE}请输入私钥密码(不显示):${PLAIN}"
        read -r -s key_passphrase || return 1
        echo
    fi

    key_dir=$(mktemp -d "$SSH_DIR/.zero-key.XXXXXX") || return 1
    TMP_KEY="$key_dir/id_ed25519"
    TMP_PUB="$TMP_KEY.pub"
    if ! ssh-keygen -t ed25519 -N "$key_passphrase" -f "$TMP_KEY"; then
        rm -rf "$key_dir"
        echo -e "${RED}密钥生成失败${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    local PUB_CONTENT
    PUB_CONTENT=$(cat "$TMP_PUB") || { rm -rf "$key_dir"; return 1; }
    if ! grep -qxF "$PUB_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
        if ! printf '%s\n' "$PUB_CONTENT" >> "$AUTH_KEYS"; then
            rm -rf "$key_dir"
            echo -e "${RED}授权公钥写入失败，未修改 SSH 服务配置${PLAIN}"
            return 1
        fi
    fi

    if [ -f "$TMP_KEY" ]; then
        clear
        echo -e "${GREEN}请复制以下私钥内容(显示后立即删除):${PLAIN}"
        echo "-----------------------------------------------------"
        cat "$TMP_KEY"
        echo "-----------------------------------------------------"
        rm -rf "$key_dir"
    else
        rm -rf "$key_dir"
        echo -e "${RED}私钥生成失败！${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    echo -e "${YELLOW}私钥内容已显示并删除。请务必妥善保存！${PLAIN}"

    if [[ "$(get_sshd_option "PermitRootLogin" "prohibit-password")" != "yes" ]]; then
        update_sshd_option "PermitRootLogin" "prohibit-password" || return 1
    fi
    update_sshd_option "PubkeyAuthentication" "yes" || return 1

    if restart_sshd_safe; then
        echo -e "${GREEN}root ed25519 密钥登录已配置完成。${PLAIN}"
    fi
    press_any_key_to_continue
}

disable_ssh_login_menu() {
    local has_password has_pubkey has_auth_key has_root_pw
    local pass_auth pubkey_auth permit_root_login choice
    local password_login_text pubkey_login_text pass_action key_action
    local -a ssh_status

    while true; do
        clear
        has_password=0; has_pubkey=0; has_auth_key=0; has_root_pw=0
        mapfile -t ssh_status < <(ssh_read_status)
        permit_root_login="${ssh_status[1]}"
        pass_auth="${ssh_status[2]}"
        pubkey_auth="${ssh_status[3]}"
        [[ "${ssh_status[4]:-0}" == "1" ]] && has_auth_key=1

        ssh_root_has_password && has_root_pw=1
        [[ "$permit_root_login" == "yes" && "$pass_auth" == "yes" && $has_root_pw -eq 1 ]] && has_password=1
        [[ "$permit_root_login" =~ ^(yes|prohibit-password|without-password)$ && "$pubkey_auth" == "yes" && $has_auth_key -eq 1 ]] && has_pubkey=1

        password_login_text=$(ssh_status_label "$pass_auth")
        pubkey_login_text=$(ssh_pubkey_status_label "$pubkey_auth" "$has_auth_key")
        [[ "$pass_auth" == "yes" ]] && pass_action="${RED}关闭密码登录${PLAIN}" || pass_action="${GREEN}开启密码登录${PLAIN}"
        [[ "$pubkey_auth" == "yes" ]] && key_action="${RED}关闭密钥登录${PLAIN}" || key_action="${GREEN}开启密钥登录${PLAIN}"

        echo -e "${BLUE}==== 登录方式 ====${PLAIN}"
        echo -e "${BLUE}密码 ${password_login_text} | 密钥 ${pubkey_login_text}"
        if [[ "$pubkey_auth" == "yes" && $has_auth_key -eq 0 ]]; then
            echo -e "${YELLOW}提示: 未检测到已写入的公钥 (${ROOT_HOME}/.ssh/authorized_keys 为空)${PLAIN}"
        fi
        echo
        echo -e "${GREEN}1.${PLAIN}${pass_action}"
        echo -e "${GREEN}2.${PLAIN}${key_action}"
        echo -e "${YELLOW}0.返回上级${PLAIN}"
        choice=$(read_menu_choice "请输入选项 [0-2]: ") || return 1
        case "$choice" in
            1)
                if [[ "$pass_auth" == "yes" ]]; then
                    if (( has_pubkey != 1 )); then
                        echo -e "${RED}未检测到可用的 root 密钥登录(需开启密钥且已写入公钥),禁止关闭密码登录${PLAIN}"
                        press_any_key_to_continue
                        continue
                    fi
                    update_sshd_option "PasswordAuthentication" "no" || return 1
                    update_sshd_option "KbdInteractiveAuthentication" "no" || return 1
                    if grep -REqi '^[[:space:]]*ChallengeResponseAuthentication([[:space:]]+|=)' "$SSHD_CONFIG" "${SSHD_CONFIG}.d" 2>/dev/null; then
                        update_sshd_option "ChallengeResponseAuthentication" "no" || return 1
                    fi
                    if [[ "$permit_root_login" == "yes" ]]; then
                        update_sshd_option "PermitRootLogin" "prohibit-password" || return 1
                    fi
                    restart_sshd_safe && echo -e "${GREEN}[✓]密码登录已关闭${PLAIN}"
                else
                    if (( has_root_pw != 1 )); then
                        echo -e "${YELLOW}检测到 root 尚未设置密码,请先通过「1.设置密码」设置密码${PLAIN}"
                        press_any_key_to_continue
                        continue
                    fi
                    update_sshd_option "PermitRootLogin" "yes" || return 1
                    update_sshd_option "PasswordAuthentication" "yes" || return 1
                    restart_sshd_safe && echo -e "${GREEN}[✓]密码登录已开启${PLAIN}"
                fi
                press_any_key_to_continue
                ;;
            2)
                if [[ "$pubkey_auth" == "yes" ]]; then
                    if (( has_password != 1 )); then
                        echo -e "${RED}未检测到可用的 root 密码登录,禁止关闭密钥登录${PLAIN}"
                        press_any_key_to_continue
                        continue
                    fi
                    update_sshd_option "PubkeyAuthentication" "no" || return 1
                    restart_sshd_safe && echo -e "${GREEN}[✓]密钥登录已关闭${PLAIN}"
                else
                    [[ "$permit_root_login" == "no" ]] && { update_sshd_option "PermitRootLogin" "prohibit-password" || return 1; }
                    update_sshd_option "PubkeyAuthentication" "yes" || return 1
                    if restart_sshd_safe; then
                        echo -e "${GREEN}[✓]密钥登录已开启${PLAIN}"
                        (( has_auth_key == 0 )) && echo -e "${YELLOW}提示: 当前尚未写入公钥,可通过「2.设置密钥」生成或手动写入 authorized_keys${PLAIN}"
                    fi
                fi
                press_any_key_to_continue
                ;;
            0)
                return 0
                ;;
            *)
                show_invalid_option "无效选项" "0.4"
                ;;
        esac
    done
}

reboot_vps() {
    echo "即将重启系统..."
    reboot 2>/dev/null || systemctl reboot 2>/dev/null || shutdown -r now
}

swap_is_valid_size_mb() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 128 ))
}

swap_recommended_for_ram_mb() {
    local total_ram="${1:-0}"
    if (( total_ram <= 2048 )); then
        echo $((total_ram * 2))
    elif (( total_ram <= 8192 )); then
        echo $((total_ram))
    else
        echo 4096
    fi
}

get_swap_file_size_mb() {
    local path="$1"
    if [[ -f "$path" ]]; then
        local size_bytes
        size_bytes=$(stat -c %s "$path" 2>/dev/null || echo 0)
        echo $(((size_bytes + 1048575) / 1048576))
    else
        echo 0
    fi
}

get_current_swap_mb() {
    if [[ -r /proc/swaps ]]; then
        awk 'NR>1 {sum+=$3} END {print int((sum + 512) / 1024)}' /proc/swaps
    else
        free -m | awk '/Swap:/ {print $2}'
    fi
}

get_managed_swap_mb() {
    if [[ -r /proc/swaps ]]; then
        awk -v path="$swapfile_path" 'NR>1 && $1 == path {sum+=$3} END {print int((sum + 512) / 1024)}' /proc/swaps
    elif [[ -f "$swapfile_path" ]]; then
        get_swap_file_size_mb "$swapfile_path"
    else
        echo 0
    fi
}

update_swap_fstab() {
    local temp
    temp=$(mktemp /etc/.fstab.zero.XXXXXX) || return 1
    if awk '
        BEGIN {new_path=ARGV[2]; for (i=2; i<ARGC; i++) {paths[ARGV[i]]=1; delete ARGV[i]}}
        !($1 in paths && $3 == "swap")
        END {print new_path " none swap sw 0 0"}
    ' /etc/fstab "$@" > "$temp" &&
       { chmod --reference=/etc/fstab "$temp" 2>/dev/null || chmod 644 "$temp"; } &&
       { chown --reference=/etc/fstab "$temp" 2>/dev/null || true; } &&
       mv -f "$temp" /etc/fstab; then
        return 0
    fi
    rm -f "$temp"
    return 1
}

create_swap_file() {
    local path="$1" size_mb="$2" root_fstype="$3" need_dd=1

    rm -f "$path"
    if [[ "$root_fstype" == "btrfs" ]]; then
        echo -e "${YELLOW}检测到 btrfs,正在按 swapfile 要求创建文件...${PLAIN}"
        : > "$path" || return 1
        if ! command -v chattr >/dev/null 2>&1 || ! chattr +C "$path" >/dev/null 2>&1; then
            rm -f "$path"
            echo -e "${RED}btrfs Swap 文件创建失败: 无法为文件设置 NoCOW${PLAIN}"
            return 1
        fi
        command -v btrfs >/dev/null 2>&1 && btrfs property set "$path" compression none >/dev/null 2>&1 || true
    elif command -v fallocate >/dev/null 2>&1; then
        if fallocate -l "${size_mb}M" "$path" 2>/dev/null; then
            need_dd=0
        else
            echo -e "${YELLOW}fallocate 创建失败,改用 dd 写零...${PLAIN}"
        fi
    fi

    if (( need_dd )) && ! dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress; then
        rm -f "$path"
        return 1
    fi
    chmod 600 "$path" && mkswap "$path" >/dev/null
}

set_swap() {
    local size_mb="$1"
    local avail_kb avail_mb root_fstype
    local temp_swap_path="${swapfile_path}.zero.tmp"
    local backup_swap_path="${swapfile_path}.zero.bak"
    local had_existing=0 old_active=0

    echo -e "${YELLOW}正在检查环境...${PLAIN}"
    if ! swap_is_valid_size_mb "$size_mb"; then
        echo -e "${RED}无效的 Swap 大小${PLAIN}"
        return 1
    fi

    avail_kb=$(df --output=avail / | tail -1)
    avail_mb=$((avail_kb / 1024))
    
    if (( avail_mb < size_mb + 500 )); then
        echo -e "${RED}磁盘空间不足!当前可用: ${avail_mb}MB, 需要: ${size_mb}MB (+预留500MB)${PLAIN}"
        return 1
    fi

    root_fstype=$(trim_input "$(df --output=fstype / | tail -1)")
    [[ -f "$swapfile_path" ]] && had_existing=1
    awk -v path="$swapfile_path" 'NR>1 && $1 == path {found=1} END {exit !found}' /proc/swaps 2>/dev/null && old_active=1

    if awk -v path="$temp_swap_path" 'NR>1 && $1 == path {found=1} END {exit !found}' /proc/swaps 2>/dev/null; then
        swapoff "$temp_swap_path" 2>/dev/null || true
    fi
    rm -f "$temp_swap_path"
    rm -f "$backup_swap_path"

    echo -e "${BLUE}正在创建 ${size_mb}MB 的 Swap 文件...${PLAIN}"
    if ! create_swap_file "$temp_swap_path" "$size_mb" "$root_fstype"; then
        echo -e "${RED}Swap 文件创建失败${PLAIN}"
        rm -f "$temp_swap_path"
        return 1
    fi

    if (( old_active )); then
        echo -e "${YELLOW}正在切换旧 Swap...${PLAIN}"
        if ! swapoff "$swapfile_path"; then
            echo -e "${RED}旧 Swap 卸载失败,已保留原配置${PLAIN}"
            rm -f "$temp_swap_path"
            return 1
        fi
    fi

    if (( had_existing )); then
        if ! mv "$swapfile_path" "$backup_swap_path"; then
            echo -e "${RED}旧 Swap 备份失败,已保留原配置${PLAIN}"
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
            rm -f "$temp_swap_path"
            return 1
        fi
    fi

    if ! mv "$temp_swap_path" "$swapfile_path"; then
        echo -e "${RED}新 Swap 文件替换失败,已尝试恢复旧配置${PLAIN}"
        rm -f "$temp_swap_path"
        if (( had_existing )); then
            mv "$backup_swap_path" "$swapfile_path" 2>/dev/null || true
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
        fi
        return 1
    fi

    if ! swapon "$swapfile_path"; then
        echo -e "${RED}新 Swap 启用失败,已尝试恢复旧配置${PLAIN}"
        rm -f "$swapfile_path"
        if (( had_existing )); then
            mv "$backup_swap_path" "$swapfile_path" 2>/dev/null || true
            (( old_active )) && swapon "$swapfile_path" >/dev/null 2>&1 || true
        fi
        return 1
    fi

    if ! update_swap_fstab "$swapfile_path" "$temp_swap_path" "$backup_swap_path"; then
        echo -e "${RED}Swap 已启用,但 /etc/fstab 更新失败${PLAIN}"
        rm -f "$backup_swap_path"
        return 1
    fi
    rm -f "$backup_swap_path"

    echo -e "${GREEN}✓ Swap 设置成功!${PLAIN}"
    free -h
    return 0
}

ACME_HOME="$ROOT_HOME/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
ACME_CERT_PATH="/etc/cert"
ACME_PORT80_OPEN_HOOK="/usr/local/bin/zero-acme-port80-open"
ACME_PORT80_CLOSE_HOOK="/usr/local/bin/zero-acme-port80-close"
ACME_CF_API="https://api.cloudflare.com/client/v4"

ACME_CF_TOKEN=""
ACME_CF_RESPONSE=""
ACME_CF_HTTP_STATUS=""
ACME_CF_ZONE_ID=""
ACME_CF_ZONE_NAME=""
ACME_CF_ACCOUNT_ID=""
ACME_CF_CREDENTIAL_BACKUP=""
ACME_CF_CREDENTIALS_REMOVED=0
ACME_PROMPT_DOMAIN=""

acme_exec() {
    [[ -f "$ACME_BIN" ]] || return 1
    bash "$ACME_BIN" "$@"
}

acme_is_installed() {
    acme_exec -v >/dev/null 2>&1
}

acme_ensure_cert_path() {
    mkdir -p "$ACME_CERT_PATH"
}

acme_has_ipv4() {
    dns_has_ipv4
}

acme_install_dependencies() {
    echo -e "${YELLOW}正在安装 ACME 依赖...${PLAIN}"
    pkg_install curl socat openssl jq cron tar ca-certificates
}

acme_install_port80_hook_scripts() {
    local hook_dir="${ACME_PORT80_OPEN_HOOK%/*}" state_dir="${ACME_PORT80_STATE_DIR:-/run/zero-acme-port80}"
    install -d -m 755 "$hook_dir" || return 1
    install -d -m 700 "$state_dir" || return 1

    cat > "$ACME_PORT80_OPEN_HOOK" <<'EOF' || return 1
#!/bin/sh
set -eu
STATE_DIR="${ACME_PORT80_STATE_DIR:-/run/zero-acme-port80}"
STATE_FILE="$STATE_DIR/state"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$STATE_FILE"

for cmd in iptables ip6tables; do
    command -v "$cmd" >/dev/null 2>&1 || continue
    "$cmd" -w 3 -t filter -C INPUT -j ZERO_INPUT >/dev/null 2>&1 || continue
    if "$cmd" -w 3 -t filter -C ZERO_INPUT -p tcp --dport 80 -m comment --comment zero-acme-http01 -j ACCEPT >/dev/null 2>&1; then
        continue
    fi
    printf '%s\n' "$cmd" >> "$STATE_FILE"
    "$cmd" -w 3 -t filter -I ZERO_INPUT 1 -p tcp --dport 80 -m comment --comment zero-acme-http01 -j ACCEPT
done
EOF

    cat > "$ACME_PORT80_CLOSE_HOOK" <<'EOF' || return 1
#!/bin/sh
set -eu
STATE_FILE="${ACME_PORT80_STATE_DIR:-/run/zero-acme-port80}/state"
[ -f "$STATE_FILE" ] || exit 0
while IFS= read -r cmd; do
    case "$cmd" in iptables|ip6tables) ;; *) continue;; esac
    while "$cmd" -w 3 -t filter -C ZERO_INPUT -p tcp --dport 80 -m comment --comment zero-acme-http01 -j ACCEPT >/dev/null 2>&1; do
        "$cmd" -w 3 -t filter -D ZERO_INPUT -p tcp --dport 80 -m comment --comment zero-acme-http01 -j ACCEPT
    done
done < "$STATE_FILE"
rm -f "$STATE_FILE"
EOF

    chmod 700 "$ACME_PORT80_OPEN_HOOK" "$ACME_PORT80_CLOSE_HOOK" || return 1
}

acme_install_core() {
    local tempdir tarball acme_tar_url automail email current_version

    acme_ensure_cert_path
    if acme_is_installed; then
        current_version=$(acme_exec -v 2>/dev/null | head -n1)
        echo -e "${YELLOW}检测到 acme.sh 已安装${PLAIN}${current_version:+: ${GREEN}${current_version}${PLAIN}}"
        echo -e "${YELLOW}正在更新 acme.sh...${PLAIN}"
        acme_exec --upgrade --auto-upgrade >/dev/null 2>&1 || {
            echo -e "${RED}acme.sh 更新失败${PLAIN}"
            return 1
        }
        echo -e "${GREEN}acme.sh 已更新完成${PLAIN}"
        return 0
    fi

    acme_install_dependencies || return 1
    systemctl start cron 2>/dev/null || systemctl start cronie 2>/dev/null || true
    systemctl enable cron 2>/dev/null || systemctl enable cronie 2>/dev/null || true

    automail=$(date +%s%N | md5sum | cut -c 1-16)
    email="${automail}@gmail.com"
    acme_tar_url="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
    tempdir=$(mktemp -d /tmp/zero-acme.XXXXXX) || {
        echo -e "${RED}无法创建临时目录${PLAIN}"
        return 1
    }
    tarball="$tempdir/master.tar.gz"

    if ! curl -fsSL --connect-timeout 10 --max-time 180 "$acme_tar_url" -o "$tarball"; then
        echo -e "${RED}acme.sh 下载失败${PLAIN}"
        rm -rf "$tempdir"
        return 1
    fi

    if ! tar zxf "$tarball" -C "$tempdir"; then
        echo -e "${RED}acme.sh 解压失败${PLAIN}"
        rm -rf "$tempdir"
        return 1
    fi

    if ! (cd "$tempdir/acme.sh-master" && ./acme.sh --install --accountemail "$email"); then
        echo -e "${RED}acme.sh 安装失败${PLAIN}"
        rm -rf "$tempdir"
        return 1
    fi

    rm -rf "$tempdir"
    acme_exec --upgrade --auto-upgrade >/dev/null 2>&1 || true
    acme_exec --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    if acme_is_installed; then
        echo -e "${GREEN}acme.sh 安装成功${PLAIN}"
        return 0
    fi

    echo -e "${RED}acme.sh 安装失败${PLAIN}"
    return 1
}

acme_uninstall() {
    if ! acme_is_installed; then
        echo -e "${YELLOW}当前未安装 acme.sh${PLAIN}"
        press_any_key_to_continue
        return
    fi

    if acme_exec --uninstall; then
        if [[ -x "$ACME_PORT80_CLOSE_HOOK" ]]; then
            "$ACME_PORT80_CLOSE_HOOK" >/dev/null 2>&1 || true
        fi
        rm -rf "$ACME_HOME"
        rm -f "$ACME_PORT80_OPEN_HOOK" "$ACME_PORT80_CLOSE_HOOK"
        rm -rf /run/zero-acme-port80
        echo -e "${GREEN}acme.sh 已卸载${PLAIN}"
    else
        echo -e "${RED}acme.sh 卸载失败，请手动检查${PLAIN}"
    fi
    press_any_key_to_continue
}

acme_ensure_installed() {
    if acme_is_installed; then
        return 0
    fi

    echo -e "${YELLOW}检测到尚未安装 acme.sh，正在自动安装...${PLAIN}"
    acme_install_core || return 1
    acme_is_installed || {
        echo -e "${RED}acme.sh 安装失败，无法继续操作${PLAIN}"
        return 1
    }
}

acme_require_installed() {
    acme_ensure_installed || {
        press_any_key_to_continue
        return 1
    }
}

acme_require_port80_hook_scripts() {
    acme_install_port80_hook_scripts && return 0
    echo -e "${RED}ACME 80 端口钩子脚本安装失败${PLAIN}"
    press_any_key_to_continue
    return 1
}

acme_get_cert_list() {
    acme_exec --list --listraw 2>/dev/null | tail -n +2
}

acme_display_cert_list() {
    local cert_list
    if (( $# > 0 )); then
        cert_list="$1"
    else
        cert_list=$(acme_get_cert_list)
    fi

    if [[ -z "$cert_list" ]]; then
        echo -e "${YELLOW}暂无已申请的证书${PLAIN}"
        return 1
    fi

    printf "${GREEN}%-4s${PLAIN} | ${GREEN}%-40s${PLAIN} | ${GREEN}%-15s${PLAIN}\n" "序号" "域名" "计划续期"
    echo -e "${BLUE}------------------------------------------------------------------${PLAIN}"

    local index=1 line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local main_domain expire_time
        main_domain="${line%%|*}"
        expire_time="${line##*|}"
        expire_time="${expire_time%%T*}"
        expire_time="${expire_time%$'\r'}"
        [[ -n "$expire_time" ]] || expire_time="-"

        if [[ "$main_domain" == \** ]]; then
            printf "${YELLOW}%-4s${PLAIN} | ${YELLOW}%-40s${PLAIN} | %-15s\n" "$index" "$main_domain" "$expire_time"
        else
            printf "${GREEN}%-4s${PLAIN} | ${GREEN}%-40s${PLAIN} | %-15s\n" "$index" "$main_domain" "$expire_time"
        fi
        ((index++))
    done <<< "$cert_list"

    echo -e "${BLUE}------------------------------------------------------------------${PLAIN}"
    return 0
}

acme_validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

acme_prompt_validated_domain() {
    local prompt="$1"
    local restore_port80="${2:-0}"
    local domain
    ACME_PROMPT_DOMAIN=""

    read -r -p "${BLUE}${prompt}${PLAIN}" domain
    domain=$(trim_input "$domain")
    if [[ -z "$domain" ]]; then
        echo -e "${RED}未输入域名${PLAIN}"
        (( restore_port80 == 1 )) && acme_restore_port_80_firewall_if_needed
        press_any_key_to_continue
        return 1
    fi
    if ! acme_validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确${PLAIN}"
        (( restore_port80 == 1 )) && acme_restore_port_80_firewall_if_needed
        press_any_key_to_continue
        return 1
    fi
    ACME_PROMPT_DOMAIN="$domain"
    return 0
}

acme_cf_require_dependencies() {
    local missing_packages=() command_name
    for command_name in curl jq; do
        command -v "$command_name" >/dev/null 2>&1 || missing_packages+=("$command_name")
    done
    [[ "${#missing_packages[@]}" -eq 0 ]] && return 0
    echo -e "${YELLOW}正在安装 Cloudflare API 依赖: ${missing_packages[*]}${PLAIN}"
    pkg_install "${missing_packages[@]}"
}

acme_prompt_cf_token() {
    local token=""

    ACME_CF_TOKEN=""
    if ! read -r -s -p "${BLUE}请输入 Cloudflare API Token: ${PLAIN}" token; then
        echo
        echo -e "${RED}读取 Cloudflare API Token 失败${PLAIN}"
        return 1
    fi
    echo
    token=$(trim_input "$token")
    if [[ -z "$token" ]]; then
        echo -e "${RED}未输入 Cloudflare API Token${PLAIN}"
        return 1
    fi
    if [[ ! "$token" =~ ^[A-Za-z0-9._~-]+$ ]]; then
        echo -e "${RED}Cloudflare API Token 包含非法字符${PLAIN}"
        return 1
    fi
    ACME_CF_TOKEN="$token"
}

acme_cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local response_file header_file curl_rc
    local -a curl_args

    response_file=$(mktemp /tmp/zero-cf-api.XXXXXX) || return 1
    header_file=$(mktemp /tmp/zero-cf-header.XXXXXX) || {
        rm -f "$response_file"
        return 1
    }
    chmod 600 "$response_file"
    chmod 600 "$header_file"
    {
        printf 'Authorization: Bearer %s\n' "$ACME_CF_TOKEN"
        printf 'Content-Type: application/json\n'
    } > "$header_file"
    curl_args=(
        --silent --show-error
        --connect-timeout 10 --max-time 30
        --request "$method"
        --header "@${header_file}"
        --output "$response_file"
        --write-out "%{http_code}"
    )
    [[ -n "$data" ]] && curl_args+=(--data "$data")

    ACME_CF_HTTP_STATUS=$(curl "${curl_args[@]}" "${ACME_CF_API}/${endpoint}")
    curl_rc=$?
    ACME_CF_RESPONSE=$(<"$response_file")
    rm -f "$response_file" "$header_file"

    if (( curl_rc != 0 )); then
        ACME_CF_HTTP_STATUS="000"
        return 1
    fi
    return 0
}

acme_cf_response_success() {
    [[ "$ACME_CF_HTTP_STATUS" =~ ^2[0-9][0-9]$ ]] &&
        [[ $(jq -r '.success // false' <<<"$ACME_CF_RESPONSE" 2>/dev/null) == "true" ]]
}

acme_cf_print_errors() {
    local summary

    summary=$(jq -r '
        if (.errors // [] | length) > 0 then
            [.errors[] | "[\(.code // "unknown")] \(.message // "unknown error")"] | join("; ")
        elif .message then .message
        else "Cloudflare API 未返回具体错误"
        end
    ' <<<"$ACME_CF_RESPONSE" 2>/dev/null)
    echo -e "${RED}${summary:-Cloudflare API 请求失败} (HTTP ${ACME_CF_HTTP_STATUS:-000})${PLAIN}"
}

acme_cf_find_zone() {
    local domain="$1"
    local candidate="$domain"
    local count

    ACME_CF_RESPONSE=""
    ACME_CF_HTTP_STATUS=""
    ACME_CF_ZONE_ID=""
    ACME_CF_ZONE_NAME=""
    ACME_CF_ACCOUNT_ID=""

    echo -e "${YELLOW}正在确认 ${domain} 所属的 Cloudflare Zone...${PLAIN}"
    while [[ "$candidate" == *.* ]]; do
        if ! acme_cf_api GET "zones?name=${candidate}&per_page=1"; then
            acme_cf_print_errors
            return 1
        fi
        if ! acme_cf_response_success; then
            acme_cf_print_errors
            echo -e "${RED}Token 需要目标 Zone 的 Zone Read 权限${PLAIN}"
            return 1
        fi

        IFS='|' read -r count ACME_CF_ZONE_ID ACME_CF_ZONE_NAME ACME_CF_ACCOUNT_ID < <(
            jq -r '[((.result_info.total_count // (.result | length) // 0) | tostring), (.result[0].id // ""), (.result[0].name // ""), (.result[0].account.id // "")] | join("|")' <<<"$ACME_CF_RESPONSE"
        )
        if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) && [[ -n "$ACME_CF_ZONE_ID" ]]; then
            break
        fi
        ACME_CF_ZONE_ID=""; ACME_CF_ZONE_NAME=""; ACME_CF_ACCOUNT_ID=""
        candidate="${candidate#*.}"
    done

    if [[ -z "$ACME_CF_ZONE_ID" || -z "$ACME_CF_ZONE_NAME" ]]; then
        echo -e "${RED}Token 无法读取目标域名对应的 Cloudflare Zone${PLAIN}"
        echo -e "${YELLOW}请确认 Token 已包含目标 Zone，并拥有 Zone Read 权限${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}✓ Zone Read 验证通过: ${ACME_CF_ZONE_NAME}${PLAIN}"
}

acme_cf_clean_old_credentials() {
    local account_conf="$ACME_HOME/account.conf"
    local backup_dir backup_file temp_file

    ACME_CF_CREDENTIAL_BACKUP=""
    ACME_CF_CREDENTIALS_REMOVED=0
    [[ -f "$account_conf" ]] || return 0
    if ! grep -Eq '^(SAVED_)?CF_(Token|Key|Email|Account_ID|Zone_ID)=' "$account_conf"; then
        return 0
    fi

    backup_dir="$ACME_HOME/credential-backups"
    mkdir -p "$backup_dir" || return 1
    chmod 700 "$backup_dir"
    backup_file=$(mktemp "$backup_dir/account.conf.bak.XXXXXX") || return 1
    if ! cp -p "$account_conf" "$backup_file"; then
        rm -f "$backup_file"
        return 1
    fi
    temp_file=$(mktemp "$backup_dir/account.conf.clean.XXXXXX") || return 1
    if ! awk '!/^(SAVED_)?CF_(Token|Key|Email|Account_ID|Zone_ID)=/' "$account_conf" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    chmod 600 "$temp_file"
    if ! mv -f "$temp_file" "$account_conf"; then
        rm -f "$temp_file"
        cp -p "$backup_file" "$account_conf" >/dev/null 2>&1 || true
        return 1
    fi
    ACME_CF_CREDENTIAL_BACKUP="$backup_file"
    ACME_CF_CREDENTIALS_REMOVED=1
    echo -e "${GREEN}已临时清理账户级旧 Cloudflare 凭据${PLAIN}"
    echo -e "${YELLOW}凭据备份: ${backup_file}${PLAIN}"
}

acme_cf_restore_old_credentials() {
    local account_conf="$ACME_HOME/account.conf"

    if (( ACME_CF_CREDENTIALS_REMOVED != 1 )); then
        return 0
    fi
    if [[ -z "$ACME_CF_CREDENTIAL_BACKUP" || ! -f "$ACME_CF_CREDENTIAL_BACKUP" ]]; then
        echo -e "${RED}找不到旧 Cloudflare 凭据备份，无法自动恢复${PLAIN}"
        return 1
    fi
    if ! cp -p "$ACME_CF_CREDENTIAL_BACKUP" "$account_conf"; then
        echo -e "${RED}恢复旧 Cloudflare 凭据失败${PLAIN}"
        return 1
    fi
    chmod 600 "$account_conf"
    ACME_CF_CREDENTIALS_REMOVED=0
    echo -e "${YELLOW}已恢复申请前的账户级 Cloudflare 凭据${PLAIN}"
}

acme_cf_has_legacy_global_users() {
    local domain_conf

    while IFS= read -r domain_conf; do
        grep -Eq '^Le_Webroot=.*dns_cf' "$domain_conf" 2>/dev/null || continue
        grep -Eq '^CF_Token=' "$domain_conf" 2>/dev/null && continue
        return 0
    done < <(find "$ACME_HOME" -mindepth 2 -maxdepth 2 -type f -name '*.conf' -print 2>/dev/null)
    return 1
}

acme_cf_finish_credentials_cleanup() {
    if (( ACME_CF_CREDENTIALS_REMOVED != 1 )); then
        return 0
    fi

    if acme_cf_has_legacy_global_users; then
        echo -e "${YELLOW}检测到其他旧 dns_cf 证书仍依赖账户级凭据，为保证其续期将保留旧凭据${PLAIN}"
        acme_cf_restore_old_credentials || return 1
    else
        ACME_CF_CREDENTIALS_REMOVED=0
        echo -e "${GREEN}旧 Cloudflare 凭据已清理，新 Token 仅保存在当前域名配置中${PLAIN}"
    fi
}

acme_cf_persist_domain_credentials() {
    local domain="$1"
    local domain_conf="$ACME_HOME/${domain}_ecc/${domain}.conf"
    local backup_file temp_file

    if [[ ! -f "$domain_conf" ]]; then
        echo -e "${RED}找不到域名配置: ${domain_conf}${PLAIN}"
        return 1
    fi
    if [[ ! "$ACME_CF_ZONE_ID" =~ ^[A-Za-z0-9_-]+$ ]] ||
       [[ -n "$ACME_CF_ACCOUNT_ID" && ! "$ACME_CF_ACCOUNT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}Cloudflare Zone/Account ID 格式异常，拒绝写入证书配置${PLAIN}"
        return 1
    fi

    backup_file=$(mktemp "${domain_conf}.zero-cf.bak.XXXXXX") || return 1
    if ! cp -p "$domain_conf" "$backup_file"; then
        rm -f "$backup_file"
        return 1
    fi
    temp_file=$(mktemp "${domain_conf}.tmp.XXXXXX") || return 1
    if ! awk '!/^(CF_Token|CF_Zone_ID|CF_Account_ID)=/' "$domain_conf" > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    {
        printf "CF_Token='%s'\n" "$ACME_CF_TOKEN" &&
        printf "CF_Zone_ID='%s'\n" "$ACME_CF_ZONE_ID" &&
        if [[ -n "$ACME_CF_ACCOUNT_ID" ]]; then
            printf "CF_Account_ID='%s'\n" "$ACME_CF_ACCOUNT_ID"
        fi
    } >> "$temp_file" || { rm -f "$temp_file"; return 1; }
    chmod 600 "$temp_file" || { rm -f "$temp_file"; return 1; }
    if ! mv -f "$temp_file" "$domain_conf"; then
        rm -f "$temp_file"
        return 1
    fi
    echo -e "${GREEN}当前域名的 Cloudflare Token/Zone 凭据已保存，可用于自动续期${PLAIN}"
    echo -e "${YELLOW}域名配置备份: ${backup_file}${PLAIN}"
}

acme_cf_issue_with_token() {
    local -a issue_args=("$@")

    (
        unset CF_Key CF_Email
        export CF_Token="$ACME_CF_TOKEN"
        export CF_Zone_ID="$ACME_CF_ZONE_ID"
        if [[ -n "$ACME_CF_ACCOUNT_ID" ]]; then
            export CF_Account_ID="$ACME_CF_ACCOUNT_ID"
        else
            unset CF_Account_ID
        fi
        acme_exec --issue --dns dns_cf -k ec-256 "${issue_args[@]}"
    )
}

acme_cf_prepare_and_issue() {
    local domain="$1"
    local issue_rc
    shift

    acme_cf_clean_old_credentials || return 1
    acme_cf_issue_with_token "$@"
    issue_rc=$?

    case "$issue_rc" in
        0)
            ;;
        2)
            echo -e "${YELLOW}现有证书尚未到续期时间，将更新 Token 凭据并继续安装现有证书${PLAIN}"
            ;;
        *)
            acme_cf_restore_old_credentials || true
            return "$issue_rc"
            ;;
    esac

    if ! acme_cf_persist_domain_credentials "$domain"; then
        acme_cf_restore_old_credentials || true
        return 1
    fi
    if ! acme_cf_finish_credentials_cleanup; then
        acme_cf_restore_old_credentials || true
        return 1
    fi
    return 0
}

acme_check_cert_result() {
    local domain="$1"

    acme_ensure_cert_path
    if [[ -s "$ACME_CERT_PATH/$domain.crt" && -s "$ACME_CERT_PATH/$domain.key" ]]; then
        echo -e "${GREEN}证书申请成功${PLAIN}"
        echo -e "${YELLOW}证书: $ACME_CERT_PATH/$domain.crt${PLAIN}"
        echo -e "${YELLOW}私钥: $ACME_CERT_PATH/$domain.key${PLAIN}"
        return 0
    fi

    echo -e "${RED}证书申请失败${PLAIN}"
    return 1
}

acme_install_issued_cert() {
    local issue_domain="$1" save_name="${2:-$1}"
    local key_file="$ACME_CERT_PATH/$save_name.key" crt_file="$ACME_CERT_PATH/$save_name.crt"
    local mihomo_cfg="${MIHOMO_CONFIG_PATH:-/etc/mihomo/config.yaml}"
    local singbox_cfg="${SINGBOX_CONFIG_PATH:-/etc/sing-box/config.json}"
    local volto_mgr="${VOLTO_MANAGER_PATH:-/usr/local/sbin/volto-manager}"
    local q="'" sq="'\"'\"'"
    local esc_key="${key_file//$q/$sq}" esc_crt="${crt_file//$q/$sq}"
    local esc_mihomo_cfg="${mihomo_cfg//$q/$sq}" esc_singbox_cfg="${singbox_cfg//$q/$sq}"
    local esc_volto_mgr="${volto_mgr//$q/$sq}"
    local reload_cmd

    acme_ensure_cert_path || return 1
    [[ -f "$key_file" ]] || : > "$key_file" || return 1
    chmod 600 "$key_file" || return 1

    reload_cmd="PATH=\"\${PATH:+\$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"; export PATH; chmod 600 '${esc_key}' && chmod 644 '${esc_crt}'; if command -v systemctl >/dev/null 2>&1; then if systemctl is-active --quiet mihomo 2>/dev/null && grep -Fq -e '${esc_key}' -e '${esc_crt}' '${esc_mihomo_cfg}' 2>/dev/null; then systemctl restart mihomo >/dev/null 2>&1 || true; fi; if systemctl is-active --quiet sing-box-zero.service 2>/dev/null && grep -Fq -e '${esc_key}' -e '${esc_crt}' '${esc_singbox_cfg}' 2>/dev/null; then systemctl reload-or-restart sing-box-zero.service >/dev/null 2>&1 || true; fi; fi; if [ -x '${esc_volto_mgr}' ]; then '${esc_volto_mgr}' --renew-cert >/dev/null 2>&1 || true; fi"

    acme_exec --install-cert -d "$issue_domain" --key-file "$key_file" --fullchain-file "$crt_file" --reloadcmd "$reload_cmd" --ecc || return 1
    chmod 600 "$key_file" && chmod 644 "$crt_file" || return 1
    acme_check_cert_result "$save_name"
}

acme_issue_failed_cleanup() {
    local restore_port80="${1:-0}"
    echo -e "${RED}证书签发失败，已跳过证书安装${PLAIN}"
    echo -e "${YELLOW}如上方提示 rateLimited，请等待限制时间结束后重试${PLAIN}"
    (( restore_port80 == 1 )) && acme_restore_port_80_firewall_if_needed
    press_any_key_to_continue
}

acme_restore_port_80_firewall_if_needed() {
    if [[ -x "$ACME_PORT80_CLOSE_HOOK" ]]; then
        "$ACME_PORT80_CLOSE_HOOK" || {
            echo -e "${RED}临时 80 端口规则移除失败，请检查 Zero FireWall${PLAIN}"
            return 1
        }
    fi
}

acme_finalize_issue() {
    local issue_domain="$1"
    local save_name="$2"
    local restore_port80="${3:-0}"

    if (( restore_port80 == 1 )); then
        acme_restore_port_80_firewall_if_needed
    fi
    acme_install_issued_cert "$issue_domain" "$save_name" || echo -e "${RED}证书安装失败${PLAIN}"
    press_any_key_to_continue
}

acme_check_port_80() {
    local ss_out="" listen_pids="" yn=""

    echo -e "${YELLOW}正在检测 80 端口状态...${PLAIN}"
    echo -e "${YELLOW}申请期间会通过 ACME 钩子临时放行 Zero FireWall 的 TCP 80，结束后移除；其他防火墙需自行放行。${PLAIN}"

    if command -v ss >/dev/null 2>&1; then
        ss_out=$(ss -H -lntp 'sport = :80' 2>/dev/null || true)
        if [[ -z "$ss_out" ]]; then
            echo -e "${GREEN}检测到当前 80 端口未被占用${PLAIN}"
            return 0
        fi
        echo -e "${RED}检测到 80 端口被其他程序占用${PLAIN}"
        printf '%s\n' "$ss_out"
        listen_pids=$(printf '%s\n' "$ss_out" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    else
        if ! command -v lsof >/dev/null 2>&1; then
            echo -e "${YELLOW}未检测到 ss/lsof，正在安装 lsof...${PLAIN}"
            pkg_install lsof >/dev/null 2>&1 || {
                echo -e "${RED}lsof 安装失败，无法检测 80 端口${PLAIN}"
                return 1
            }
        fi
        listen_pids=$(lsof -t -iTCP:80 -sTCP:LISTEN 2>/dev/null | sort -u)
        if [[ -z "$listen_pids" ]]; then
            echo -e "${GREEN}检测到当前 80 端口未被占用${PLAIN}"
            return 0
        fi
        echo -e "${RED}检测到 80 端口被其他程序占用${PLAIN}"
        lsof -iTCP:80 -sTCP:LISTEN 2>/dev/null
    fi

    read -rp "${BLUE}如需结束占用进程请输入 Y，其他键返回菜单 [Y/N]: ${PLAIN}" yn
    if [[ "$yn" =~ ^[Yy]$ && -n "$listen_pids" ]]; then
        printf '%s\n' "$listen_pids" | xargs -r kill -9
        sleep 1
        return 0
    fi
    acme_restore_port_80_firewall_if_needed
    return 1
}

acme_standalone_should_listen_v6() {
    local domain="$1" bindv6only="0" bindv6_file="${ACME_BINDV6ONLY_FILE:-/proc/sys/net/ipv6/bindv6only}"
    dns_has_ipv6 || return 1
    acme_has_ipv4 || return 0
    [[ -r "$bindv6_file" ]] && IFS= read -r bindv6only < "$bindv6_file"
    [[ "$bindv6only" != "1" ]] && return 0
    command -v getent >/dev/null 2>&1 &&
        getent ahostsv6 "$domain" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ { found=1; exit } END { exit !found }'
}

acme_issue_standalone() {
    local domain issue_rc=0
    local -a listen_args=()

    acme_require_installed || return
    acme_require_port80_hook_scripts || return

    acme_check_port_80 || {
        press_any_key_to_continue
        return
    }

    acme_prompt_validated_domain "请输入解析完成的域名: " 1 || return
    domain="$ACME_PROMPT_DOMAIN"

    acme_ensure_cert_path
    acme_standalone_should_listen_v6 "$domain" && listen_args=(--listen-v6)
    acme_exec --issue -d "$domain" --standalone -k ec-256 ${listen_args[@]+"${listen_args[@]}"} --pre-hook "$ACME_PORT80_OPEN_HOOK" --post-hook "$ACME_PORT80_CLOSE_HOOK" || issue_rc=$?
    case "$issue_rc" in
        0) ;;
        2) echo -e "${YELLOW}现有证书尚未到续期时间，将继续安装现有证书${PLAIN}" ;;
        *)
            acme_issue_failed_cleanup 1
            return
            ;;
    esac

    acme_finalize_issue "$domain" "$domain" 1
}

acme_issue_cf() {
    local mode="$1" prompt="请输入需要申请证书的域名: " domain
    local -a domain_args=()
    [[ "$mode" == "wildcard" ]] && prompt="请输入需要申请证书的泛域名根域名: "

    acme_require_installed || return
    acme_cf_require_dependencies || {
        echo -e "${RED}Cloudflare API 依赖安装失败${PLAIN}"
        press_any_key_to_continue
        return
    }

    acme_prompt_validated_domain "$prompt" || return
    domain=$(printf '%s' "$ACME_PROMPT_DOMAIN" | tr '[:upper:]' '[:lower:]')
    if ! acme_prompt_cf_token; then
        press_any_key_to_continue
        return
    fi
    if ! acme_cf_find_zone "$domain"; then
        ACME_CF_TOKEN=""
        echo -e "${RED}无法获取 Cloudflare Zone，已取消证书申请${PLAIN}"
        press_any_key_to_continue
        return
    fi
    acme_ensure_cert_path
    domain_args=(-d "$domain")
    [[ "$mode" == "wildcard" ]] && domain_args+=(-d "*.${domain}")
    if ! acme_cf_prepare_and_issue "$domain" "${domain_args[@]}"; then
        ACME_CF_TOKEN=""
        acme_issue_failed_cleanup
        return
    fi
    ACME_CF_TOKEN=""
    acme_finalize_issue "$domain" "$domain"
}

acme_revoke_cert() {
    local cert_list choice confirm selected_domain base_domain line
    local -a domains=()

    acme_require_installed || return

    clear
    echo -e "${BLUE}================ 证书列表 ================${PLAIN}"
    cert_list=$(acme_get_cert_list)
    if ! acme_display_cert_list "$cert_list"; then
        press_any_key_to_continue
        return
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        domains+=("${line%%|*}")
    done <<< "$cert_list"
    echo

    choice=$(read_menu_choice "请输入要撤销的证书序号(0返回): ") || return 1
    if [[ "$choice" == "0" ]]; then
        return
    fi
    if ! valid_list_index "$choice" "${#domains[@]}"; then
        echo -e "${RED}无效序号${PLAIN}"
        press_any_key_to_continue
        return
    fi

    selected_domain="${domains[$((choice-1))]}"
    echo -e "${YELLOW}即将撤销证书: ${selected_domain}${PLAIN}"
    read -r -p "${BLUE}确认撤销? [y/N]: ${PLAIN}" confirm
    confirm=$(trim_input "$confirm")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消操作${PLAIN}"
        press_any_key_to_continue
        return
    fi

    if ! acme_exec --revoke -d "$selected_domain" --ecc; then
        echo -e "${RED}证书撤销失败,本地文件未删除${PLAIN}"
        press_any_key_to_continue
        return
    fi
    if ! acme_exec --remove -d "$selected_domain" --ecc; then
        echo -e "${RED}证书移除失败,请手动检查 acme.sh 状态${PLAIN}"
        press_any_key_to_continue
        return
    fi
    rm -rf "$ACME_HOME/${selected_domain}_ecc"

    base_domain="${selected_domain#\*.}"
    rm -f "$ACME_CERT_PATH/$base_domain.crt" "$ACME_CERT_PATH/$base_domain.key"
    rm -f "$ACME_CERT_PATH/$selected_domain.crt" "$ACME_CERT_PATH/$selected_domain.key" 2>/dev/null || true

    echo -e "${GREEN}证书 ${selected_domain} 已撤销${PLAIN}"
    press_any_key_to_continue
}

acme_renew_cert() {
    acme_require_installed || return
    if grep -Rqs -e "$ACME_PORT80_OPEN_HOOK" -e "$ACME_PORT80_CLOSE_HOOK" "$ACME_HOME" 2>/dev/null; then
        acme_require_port80_hook_scripts || return
    fi
    if acme_exec --cron; then
        echo -e "${GREEN}证书续期任务已执行${PLAIN}"
    else
        echo -e "${RED}证书续期执行失败${PLAIN}"
    fi
    press_any_key_to_continue
}

acme_switch_provider() {
    local provider
    acme_require_installed || return

    clear
    echo -e "${BLUE}======== 证书CA ========${PLAIN}"
    echo -e "${GREEN}1.LetsEncrypt${PLAIN}  ${GREEN}2.ZeroSSL${PLAIN}"
    echo -e "${YELLOW}0.返回菜单${PLAIN}"
    echo -e "${BLUE}========================${PLAIN}"
    provider=$(read_menu_choice "请输入选项 [0-2]: ") || return 1

    case "$provider" in
        1) acme_exec --set-default-ca --server letsencrypt && echo -e "${GREEN}已切换到 LetsEncrypt${PLAIN}" || echo -e "${RED}切换失败${PLAIN}" ;;
        2) acme_exec --set-default-ca --server zerossl && echo -e "${GREEN}已切换到 ZeroSSL${PLAIN}" || echo -e "${RED}切换失败${PLAIN}" ;;
        0) return ;;
        *) show_invalid_option; return ;;
    esac
    press_any_key_to_continue
}

acme_generate_self_signed_cert() {
    local default_domain="icloud.com.cn" days=3650 domain key_file crt_file workdir

    clear
    acme_ensure_cert_path || return 1
    read -r -p "${BLUE}请输入证书域名(默认: ${default_domain}): ${PLAIN}" domain || return 1
    domain=$(trim_input "$domain")
    domain="${domain:-$default_domain}"
    if ! acme_validate_domain "$domain"; then
        echo -e "${RED}域名格式不正确${PLAIN}"
        press_any_key_to_continue
        return
    fi

    key_file="$ACME_CERT_PATH/${domain}.key"
    crt_file="$ACME_CERT_PATH/${domain}.crt"
    workdir=$(mktemp -d "$ACME_CERT_PATH/.zero-cert.XXXXXX") || return 1
    if ! openssl ecparam -name prime256v1 -genkey -noout -out "$workdir/${domain}.key" ||
       ! openssl req -new -x509 -key "$workdir/${domain}.key" -out "$workdir/${domain}.crt" -days "$days" -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" ||
       ! chmod 600 "$workdir/${domain}.key" ||
       ! chmod 644 "$workdir/${domain}.crt" ||
       ! mv -f "$workdir/${domain}.key" "$workdir/${domain}.crt" "$ACME_CERT_PATH/"; then
        rm -rf "$workdir"
        echo -e "${RED}自签证书生成或保存失败${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    rmdir "$workdir"
    echo -e "${GREEN}自签证书生成完成${PLAIN}"
    echo -e "${YELLOW}证书: $crt_file${PLAIN}"
    echo -e "${YELLOW}私钥: $key_file${PLAIN}"
    press_any_key_to_continue
}

acme_menu() {
    local acme_choice
    while true; do
        clear
        echo -e "${BLUE}===============================${PLAIN}"
        echo -e "         ${RED}证书申请${PLAIN}"
        echo -e "${BLUE}===============================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN}安装Acme"
        echo -e " ${GREEN}2.${PLAIN}卸载Acme"
        echo -e "${BLUE}-------------${PLAIN}"
        echo -e " ${GREEN}3.${PLAIN}申请单域名证书 ${YELLOW}(80 端口申请)${PLAIN}"
        echo -e " ${GREEN}4.${PLAIN}申请单域名证书 ${YELLOW}(CF API Token)${PLAIN}"
        echo -e " ${GREEN}5.${PLAIN}申请泛域名证书 ${YELLOW}(CF API Token)${PLAIN}"
        echo -e "${BLUE}-------------${PLAIN}"
        echo -e " ${GREEN}6.${PLAIN}撤销已申请的证书"
        echo -e " ${GREEN}7.${PLAIN}续期已申请的证书"
        echo -e " ${GREEN}8.${PLAIN}切换证书颁发机构"
        echo -e " ${GREEN}9.${PLAIN}生成自签证书"
        echo -e "${BLUE}-------------${PLAIN}"
        echo -e " ${YELLOW}0.${PLAIN}返回菜单\n"
        acme_choice=$(read_menu_choice "请输入选项 [0-9]: ") || return 1
        case "$acme_choice" in
            1) acme_install_core; press_any_key_to_continue ;;
            2) acme_uninstall ;;
            3) acme_issue_standalone ;;
            4) acme_issue_cf single ;;
            5) acme_issue_cf wildcard ;;
            6) acme_revoke_cert ;;
            7) acme_renew_cert ;;
            8) acme_switch_provider ;;
            9) acme_generate_self_signed_cert ;;
            0) return ;;
            *) show_invalid_option ;;
        esac
    done
}

ZERO_SELECTED_CERT=""
ZERO_SELECTED_KEY=""

zero_select_tls_cert() {
    local title="${1:-证书配置}" cert_dir="${2:-${ACME_CERT_PATH:-/etc/cert}}"
    local custom_idx opt i cert_path key_path
    local -a cert_files=()

    while true; do
        clear
        echo -e "${BLUE}${title}${PLAIN}"
        cert_files=()
        if compgen -G "${cert_dir}/*.crt" >/dev/null 2>&1; then
            mapfile -t cert_files < <(find "$cert_dir" -maxdepth 1 -type f -name '*.crt' | sort)
        fi
        for ((i = 0; i < ${#cert_files[@]}; i++)); do
            echo -e "${GREEN}$((i + 1)).${PLAIN}$(basename "${cert_files[$i]}")"
        done
        custom_idx=$(( ${#cert_files[@]} + 1 ))
        echo -e "${GREEN}${custom_idx}.${PLAIN}自定义路径"
        echo -e "${YELLOW}0.${PLAIN}返回取消"

        opt=$(read_menu_choice "输入选项 [0-${custom_idx}]: ") || return 1
        if [[ "$opt" == "0" ]]; then
            return 2
        elif [[ "$opt" == "$custom_idx" ]]; then
            read -r -p "${BLUE}证书路径(留空返回): ${PLAIN}" cert_path || return 1
            cert_path=$(trim_input "$cert_path")
            [[ -z "$cert_path" ]] && continue
            read -r -p "${BLUE}私钥路径(留空返回): ${PLAIN}" key_path || return 1
            key_path=$(trim_input "$key_path")
            [[ -z "$key_path" ]] && continue
        elif valid_list_index "$opt" "${#cert_files[@]}"; then
            cert_path="${cert_files[$((opt - 1))]}"
            key_path="${cert_path%.crt}.key"
        else
            echo -e "${YELLOW}无效选项${PLAIN}"
            sleep 0.5
            continue
        fi

        if [[ -f "$cert_path" && -r "$cert_path" && -f "$key_path" && -r "$key_path" ]]; then
            ZERO_SELECTED_CERT="$cert_path"
            ZERO_SELECTED_KEY="$key_path"
            return 0
        fi
        echo -e "${RED}证书或私钥不存在/不可读${PLAIN}"
        sleep 1
    done
}

MIHOMO_EXEC_PATH="/usr/local/bin/mihomo"
MIHOMO_CONFIG_DIR="/etc/mihomo"
MIHOMO_CONFIG_PATH="${MIHOMO_CONFIG_DIR}/config.yaml"
MIHOMO_SERVICE_NAME="mihomo"
MIHOMO_SERVICE_FILE="/etc/systemd/system/mihomo.service"
MIHOMO_ALPHA_TAG="Prerelease-Alpha"
mihomo_cert_path=""
mihomo_key_path=""
MIHOMO_P_PORT=""
MIHOMO_P_PASS=""
MIHOMO_P_UUID=""
MIHOMO_P_OBFS="n"
MIHOMO_P_HOST="icloud.com.cn"
MIHOMO_P_CERT=""
MIHOMO_P_KEY=""
MIHOMO_P_PASS_RAND="n"
MIHOMO_P_UUID_RAND="n"

mihomo_get_arch() {
    zero_get_arch || {
        echo -e "${RED}不支持${PLAIN}" >&2
        return 1
    }
}

mihomo_yaml_string() {
    local value="$1" quote="'"
    value=${value//$quote/$quote$quote}
    printf "'%s'" "$value"
}

mihomo_random_pass() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12
}

mihomo_listener_proto() {
    case "$1" in
        tuicv5-in|hysteria2-in|tuic|hysteria2) echo "udp" ;;
        *) echo "tcp" ;;
    esac
}

mihomo_list_configured_endpoints() {
    [[ -f "$MIHOMO_CONFIG_PATH" ]] || return 0
    awk '
        function flush_item() {
            if (nm != "" && pr != "" && pt != "") print nm, pr, pt
            nm = ""; pr = ""; pt = ""
        }
        /^listeners:/ { in_l = 1; next }
        in_l && /^[^ -]/ { flush_item(); in_l = 0 }
        in_l && /^- name:[[:space:]]*/ {
            flush_item()
            v = $0; sub(/^- name:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            nm = v
        }
        in_l && /^  type:[[:space:]]*/ {
            v = $0; sub(/^  type:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            pr = (v == "tuic" || v == "hysteria2") ? "udp" : "tcp"
        }
        in_l && /^  port:[[:space:]]*/ {
            v = $0; sub(/^  port:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            pt = v
        }
        END { flush_item() }
    ' "$MIHOMO_CONFIG_PATH" 2>/dev/null
}

mihomo_port_available() {
    local port="$1" proto="$2" exclude_name="${3:-}" nm pr pt proto_label="TCP"
    [[ "$proto" == "udp" ]] && proto_label="UDP"
    while read -r nm pr pt; do
        [[ -n "$nm" && "$nm" != "$exclude_name" ]] || continue
        if [[ "$pr" == "$proto" && "$pt" == "$port" ]]; then
            echo -e "${RED}${proto_label} 端口 ${port} 已被另一项 Mihomo 监听器 (${nm}) 使用${PLAIN}" >&2
            return 1
        fi
    done < <(mihomo_list_configured_endpoints)

    if zero_port_is_listening "$port" "$proto"; then
        echo -e "${RED}${proto_label} 端口 ${port} 已被系统中的进程占用${PLAIN}" >&2
        return 1
    fi
    return 0
}

mihomo_channel_label() {
    case "$1" in
        alpha) echo "测试版" ;;
        release) echo "正式版" ;;
        *) return 1 ;;
    esac
}

mihomo_get_current_version_label() {
    local version_line
    version_line=$("$MIHOMO_EXEC_PATH" -v 2>/dev/null | head -1)
    if [[ "$version_line" =~ (alpha-[0-9a-f]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$version_line" =~ (v[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return
    fi
    echo "未知"
}

mihomo_select_asset_name() {
    local release_json="$1"
    local arch="$2"
    local channel="$3"
    local cpu_level="${4:-}"
    local asset_names ver_re pattern asset_name
    local -a patterns=()

    asset_names=$(printf '%s\n' "$release_json" | grep -oE '"name":[[:space:]]*"mihomo-linux-[^"]+\.gz"' | sed -E 's/^"name":[[:space:]]*"//; s/"$//')
    [[ -n "$asset_names" ]] || return 1

    case "$channel" in
        alpha)   ver_re='alpha-[0-9a-f]+' ;;
        release) ver_re='v[0-9]+\.[0-9]+\.[0-9]+' ;;
        *)       return 1 ;;
    esac

    case "$arch" in
        amd64)
            [[ -n "$cpu_level" ]] || cpu_level=$(bbr_detect_x86_64_level_local 2>/dev/null || true)
            if [[ "$cpu_level" =~ ^[34]$ ]]; then
                patterns=(
                    "^mihomo-linux-amd64-v3-${ver_re}\\.gz$"
                    "^mihomo-linux-amd64-${ver_re}\\.gz$"
                    "^mihomo-linux-amd64-v2-${ver_re}\\.gz$"
                    "^mihomo-linux-amd64-v1-${ver_re}\\.gz$"
                    "^mihomo-linux-amd64-compatible-${ver_re}\\.gz$"
                )
            elif [[ "$cpu_level" == "2" ]]; then
                patterns=(
                    "^mihomo-linux-amd64-v2-${ver_re}\\.gz$"
                    "^mihomo-linux-amd64-v1-${ver_re}\\.gz$"
                    "^mihomo-linux-amd64-compatible-${ver_re}\\.gz$"
                )
            else
                patterns=(
                    "^mihomo-linux-amd64-v1-${ver_re}\\.gz$"
                    "^mihomo-linux-amd64-compatible-${ver_re}\\.gz$"
                )
            fi
            ;;
        arm64)
            patterns=("^mihomo-linux-arm64(-v8)?-${ver_re}\\.gz$")
            ;;
        *)
            return 1
            ;;
    esac

    for pattern in "${patterns[@]}"; do
        asset_name=$(printf '%s\n' "$asset_names" | grep -E "$pattern" | head -n1)
        if [[ -n "$asset_name" ]]; then
            printf '%s\n' "$asset_name"
            return 0
        fi
    done
    return 1
}

mihomo_get_download_info() {
    local arch="$1"
    local channel="$2"
    local release_path latest_version asset_name download_url api_url release_json asset_version display_version

    case "$channel" in
        alpha) release_path="releases/tags/${MIHOMO_ALPHA_TAG}" ;;
        release) release_path="releases/latest" ;;
        *)
            return 1
            ;;
    esac

    api_url="https://api.github.com/repos/MetaCubeX/mihomo/${release_path}"

    release_json=$(curl -fsSL --connect-timeout 10 --max-time 30 "$api_url") || return 1
    latest_version=$(printf '%s\n' "$release_json" | grep '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/' | head -1)
    [[ -n "$latest_version" ]] || return 1

    asset_name=$(mihomo_select_asset_name "$release_json" "$arch" "$channel") || return 1
    download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${asset_name}"

    display_version="$latest_version"
    if [[ "$channel" == "alpha" ]]; then
        asset_version=$(printf '%s\n' "$asset_name" | grep -oE 'alpha-[0-9a-f]+' | tail -1)
        display_version="${MIHOMO_ALPHA_TAG} (${asset_version})"
    fi

    echo "${download_url}|${display_version}|${asset_name}"
}

mihomo_download_binary() {
    local download_url="$1" target="${2:-$MIHOMO_EXEC_PATH}"
    local tmpdir tmp_target

    tmpdir=$(mktemp -d /tmp/zero-mihomo.XXXXXX) || return 1
    if ! curl -fL --connect-timeout 10 --max-time 120 -o "$tmpdir/mihomo.gz" "$download_url"; then
        echo -e "${RED}下载失败${PLAIN}"
        rm -rf "$tmpdir"
        return 1
    fi

    if ! gzip -dc "$tmpdir/mihomo.gz" > "$tmpdir/mihomo"; then
        echo -e "${RED}解压失败${PLAIN}"
        rm -rf "$tmpdir"
        return 1
    fi

    install -d -m 755 "${target%/*}" || { rm -rf "$tmpdir"; return 1; }
    tmp_target=$(mktemp "${target}.tmp.XXXXXX") || { rm -rf "$tmpdir"; return 1; }
    if ! install -m 755 "$tmpdir/mihomo" "$tmp_target" || ! mv -f "$tmp_target" "$target"; then
        echo -e "${RED}安装内核失败${PLAIN}"
        rm -f "$tmp_target"
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
}

mihomo_install_dependencies() {
    zero_ensure_systemd_and_pkgs "Mihomo" curl:curl gzip:gunzip ca-certificates:update-ca-certificates iproute2:ss
}

mihomo_select_cert() {
    zero_select_tls_cert "===== Mihomo 证书配置 =====" || return $?
    mihomo_cert_path="$ZERO_SELECTED_CERT"
    mihomo_key_path="$ZERO_SELECTED_KEY"
}

mihomo_create_systemd_service() {
    cat > "$MIHOMO_SERVICE_FILE" <<EOF || return 1
[Unit]
Description=Mihomo Daemon, A rule-based tunnel in Go.
After=network.target network-online.target nss-lookup.target

[Service]
Type=simple
User=root
Environment=SKIP_SAFE_PATH_CHECK=1
ExecStart=${MIHOMO_EXEC_PATH} -d ${MIHOMO_CONFIG_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$MIHOMO_SERVICE_FILE"
}

mihomo_reload_systemd() {
    systemctl daemon-reload >/dev/null 2>&1 && return 0
    echo -e "${RED}systemd 重新加载失败${PLAIN}"
    return 1
}

mihomo_service_healthy() {
    local i pid nm pr pt sockets all_bound line
    local -a endpoints=()
    mapfile -t endpoints < <(mihomo_list_configured_endpoints)

    for ((i = 0; i < 15; i++)); do
        systemctl is-active --quiet "$MIHOMO_SERVICE_NAME" 2>/dev/null || return 1
        pid=$(systemctl show -p MainPID --value "$MIHOMO_SERVICE_NAME" 2>/dev/null || true)
        if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! command -v ss >/dev/null 2>&1 || (( ${#endpoints[@]} == 0 )); then
            (( i >= 1 )) && return 0
            sleep 0.2
            continue
        fi
        all_bound=1
        for line in "${endpoints[@]}"; do
            read -r nm pr pt <<< "$line"
            [[ "$pr" == "udp" ]] && sockets=$(ss -H -lunp "sport = :$pt" 2>/dev/null || true) || sockets=$(ss -H -lntp "sport = :$pt" 2>/dev/null || true)
            if [[ "$sockets" != *"pid=$pid,"* ]]; then
                all_bound=0
                break
            fi
        done
        (( all_bound == 1 )) && return 0
        sleep 0.2
    done
    return 1
}

mihomo_systemctl_checked() {
    local action="$1" success_msg="$2" failure_msg="${3:-Mihomo 服务操作失败}"

    if systemctl "$action" "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
        if [[ "$action" == "start" || "$action" == "restart" ]] && ! mihomo_service_healthy; then
            echo -e "${RED}${failure_msg} (进程退出或端口绑定失败)${PLAIN}"
            service_failure_hint "$MIHOMO_SERVICE_NAME"
            return 1
        fi
        [[ -n "$success_msg" ]] && echo -e "${GREEN}${success_msg}${PLAIN}"
        return 0
    fi

    echo -e "${RED}${failure_msg}${PLAIN}"
    service_failure_hint "$MIHOMO_SERVICE_NAME"
    return 1
}

mihomo_make_config_backup() {
    local backup
    backup="$(mktemp)" || return 1
    chmod 600 "$backup" 2>/dev/null || true
    cp "$MIHOMO_CONFIG_PATH" "$backup" || {
        rm -f "$backup"
        return 1
    }
    printf '%s\n' "$backup"
}

mihomo_commit_tmp_config() {
    local tmp_file="$1" backup="${2:-}"
    chmod 600 "$tmp_file" && mv -f "$tmp_file" "$MIHOMO_CONFIG_PATH" && return 0
    echo -e "${RED}配置写入失败${PLAIN}"
    rm -f "$tmp_file" "$backup"
    sleep 1
    return 1
}

mihomo_check_config() {
    local binary="${1:-$MIHOMO_EXEC_PATH}"
    SKIP_SAFE_PATH_CHECK=1 "$binary" -t -d "$MIHOMO_CONFIG_DIR" -f - < "$MIHOMO_CONFIG_PATH"
}

mihomo_restart_with_rollback() {
    local backup="$1" success_msg="$2" failure_msg="${3:-新配置重启失败}"

    if ! mihomo_check_config; then
        if ! cp "$backup" "$MIHOMO_CONFIG_PATH"; then
            echo -e "${RED}配置无效且恢复失败，备份保留在 ${backup}${PLAIN}"
            return 1
        fi
        chmod 600 "$MIHOMO_CONFIG_PATH" 2>/dev/null || true
        rm -f "$backup"
        echo -e "${YELLOW}配置检查失败，已恢复原配置，未重启服务${PLAIN}"
        return 1
    fi
    if ! systemctl is-active --quiet "$MIHOMO_SERVICE_NAME"; then
        rm -f "$backup"
        echo -e "${GREEN}${success_msg},服务保持停止状态${PLAIN}"
        return 0
    fi
    if systemctl restart "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1 && mihomo_service_healthy; then
        rm -f "$backup"
        echo -e "${GREEN}${success_msg}${PLAIN}"
        return 0
    fi

    if ! cp "$backup" "$MIHOMO_CONFIG_PATH"; then
        echo -e "${RED}恢复配置失败，备份保留在 ${backup}${PLAIN}"
        return 1
    fi
    chmod 600 "$MIHOMO_CONFIG_PATH" 2>/dev/null || true
    rm -f "$backup"
    if systemctl restart "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1 && mihomo_service_healthy; then
        echo -e "${YELLOW}${failure_msg},已回滚到上一份可用配置${PLAIN}"
        return 1
    fi

    echo -e "${RED}${failure_msg},回滚后服务仍未启动${PLAIN}"
    service_failure_hint "$MIHOMO_SERVICE_NAME"
    return 1
}

mihomo_render_listener() {
    local name="$1" port="$2" pass="$3" cert="${4:-}" key="${5:-}" extra1="${6:-}" extra2="${7:-}"
    case "$name" in
        anytls-in)
            cat <<EOF
- name: anytls-in
  type: anytls
  port: ${port}
  listen: ::0
  users:
    username1: $(mihomo_yaml_string "$pass")
  certificate: $(mihomo_yaml_string "$cert")
  private-key: $(mihomo_yaml_string "$key")
  padding-scheme: |
   stop=8
   0=30-30
   1=100-400
   2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
   3=9-9,500-1000
   4=500-1000
   5=500-1000
   6=500-1000
   7=500-1000

EOF
            ;;
        trojan-in)
            cat <<EOF
- name: trojan-in
  type: trojan
  port: ${port}
  listen: ::0
  users:
    - username: 1
      password: $(mihomo_yaml_string "$pass")
  ws-path: "/"
  certificate: $(mihomo_yaml_string "$cert")
  private-key: $(mihomo_yaml_string "$key")

EOF
            ;;
        snellv5-in)
            cat <<EOF
- name: snellv5-in
  type: snell
  port: ${port}
  listen: ::0
  psk: $(mihomo_yaml_string "$pass")
  version: 5
  udp: true
EOF
            if [[ "$extra1" == "y" ]]; then
                cat <<EOF
  obfs-opts:
    mode: http
    host: $(mihomo_yaml_string "$extra2")
EOF
            fi
            printf '\n'
            ;;
        tuicv5-in)
            cat <<EOF
- name: tuicv5-in
  type: tuic
  port: ${port}
  listen: ::0
  users:
    ${extra1}: $(mihomo_yaml_string "$pass")
  certificate: $(mihomo_yaml_string "$cert")
  private-key: $(mihomo_yaml_string "$key")
  congestion-controller: bbr
  max-idle-time: 15000
  authentication-timeout: 3000
  alpn:
    - h3
  max-udp-relay-packet-size: 1408

EOF
            ;;
        hysteria2-in)
            cat <<EOF
- name: hysteria2-in
  type: hysteria2
  port: ${port}
  listen: ::0
  users:
    user1: $(mihomo_yaml_string "$pass")
  masquerade: ""
  alpn:
  - h3
  certificate: $(mihomo_yaml_string "$cert")
  private-key: $(mihomo_yaml_string "$key")

EOF
            ;;
        *)
            return 1
            ;;
    esac
}

mihomo_generate_config() {
    cat > "$MIHOMO_CONFIG_PATH" <<EOF || return 1
tcp-concurrent: true
find-process-mode: off
allow-lan: false
mode: rule
log-level: silent
ipv6: true
dns:
  enable: true
  ipv6: true
  nameserver:
    - system
  enhanced-mode: redir-host
profile:
  store-selected: false
  store-fake-ip: false
listeners:
EOF
    chmod 600 "$MIHOMO_CONFIG_PATH" || return 1

    if [[ "$enable_anytls" == "y" ]]; then
        mihomo_render_listener "anytls-in" "$anytls_port" "$anytls_pass" "$anytls_cert" "$anytls_key" >> "$MIHOMO_CONFIG_PATH" || return 1
    fi
    if [[ "$enable_trojan" == "y" ]]; then
        mihomo_render_listener "trojan-in" "$trojan_port" "$trojan_pass" "$trojan_cert" "$trojan_key" >> "$MIHOMO_CONFIG_PATH" || return 1
    fi
    if [[ "$enable_snell" == "y" ]]; then
        mihomo_render_listener "snellv5-in" "$snell_port" "$snell_pass" "" "" "$snell_obfs" "$snell_obfs_host" >> "$MIHOMO_CONFIG_PATH" || return 1
    fi
    if [[ "$enable_tuic" == "y" ]]; then
        mihomo_render_listener "tuicv5-in" "$tuic_port" "$tuic_pass" "$tuic_cert" "$tuic_key" "$tuic_uuid" >> "$MIHOMO_CONFIG_PATH" || return 1
    fi
    if [[ "$enable_hy2" == "y" ]]; then
        mihomo_render_listener "hysteria2-in" "$hy2_port" "$hy2_pass" "$hy2_cert" "$hy2_key" >> "$MIHOMO_CONFIG_PATH" || return 1
    fi

    cat >> "$MIHOMO_CONFIG_PATH" <<EOF || return 1
rules:
  - MATCH,DIRECT
EOF
}

mihomo_cleanup_failed_install() {
    systemctl disable --now "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$MIHOMO_SERVICE_FILE" "$MIHOMO_EXEC_PATH" "$MIHOMO_CONFIG_PATH"
    rmdir "$MIHOMO_CONFIG_DIR" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

mihomo_prompt_listener_params() {
    local name="$1" header="$2" default_port="$3" mode="$4"
    local proto proto_label="TCP" pass_label="密码"
    proto=$(mihomo_listener_proto "$name")
    [[ "$proto" == "udp" ]] && proto_label="UDP"
    [[ "$name" == "snellv5-in" ]] && pass_label="PSK"

    MIHOMO_P_PORT=""
    MIHOMO_P_PASS=""
    MIHOMO_P_UUID=""
    MIHOMO_P_OBFS="n"
    MIHOMO_P_HOST="icloud.com.cn"
    MIHOMO_P_CERT=""
    MIHOMO_P_KEY=""
    MIHOMO_P_PASS_RAND="n"
    MIHOMO_P_UUID_RAND="n"

    clear
    echo -e "${BLUE}===== ${header} =====${PLAIN}"
    while true; do
        read -r -p "${BLUE}端口(默认:${default_port}): ${PLAIN}" MIHOMO_P_PORT || return 1
        MIHOMO_P_PORT=$(trim_input "$MIHOMO_P_PORT")
        MIHOMO_P_PORT=${MIHOMO_P_PORT:-$default_port}
        if ! zero_is_valid_port "$MIHOMO_P_PORT"; then
            echo -e "${RED}端口无效${PLAIN}"
            continue
        fi
        if [[ "$mode" == "install" ]]; then
            if [[ "$proto" == "udp" && "$used_udp_ports" == *" ${MIHOMO_P_PORT} "* ]] ||
               [[ "$proto" == "tcp" && "$used_tcp_ports" == *" ${MIHOMO_P_PORT} "* ]]; then
                echo -e "${RED}${proto_label} 端口 ${MIHOMO_P_PORT} 已在本次配置中使用${PLAIN}"
                continue
            fi
            if zero_port_is_listening "$MIHOMO_P_PORT" "$proto"; then
                echo -e "${RED}${proto_label} 端口 ${MIHOMO_P_PORT} 已被系统进程占用${PLAIN}"
                continue
            fi
            [[ "$proto" == "udp" ]] && used_udp_ports+="${MIHOMO_P_PORT} " || used_tcp_ports+="${MIHOMO_P_PORT} "
            break
        else
            mihomo_port_available "$MIHOMO_P_PORT" "$proto" "$name" && break
        fi
    done

    if [[ "$name" == "tuicv5-in" ]]; then
        read -r -p "${BLUE}UUID(回车随机): ${PLAIN}" MIHOMO_P_UUID || return 1
        MIHOMO_P_UUID=$(trim_input "$MIHOMO_P_UUID")
        if [[ -z "$MIHOMO_P_UUID" ]]; then
            MIHOMO_P_UUID=$(zero_random_uuid) || {
                echo -e "${RED}生成随机 UUID 失败${PLAIN}"
                return 3
            }
            MIHOMO_P_UUID_RAND="y"
        fi
        if ! zero_is_valid_uuid "$MIHOMO_P_UUID"; then
            echo -e "${RED}TUIC UUID 格式无效${PLAIN}"
            return 3
        fi
    fi

    read -r -p "${BLUE}${pass_label}(回车随机): ${PLAIN}" MIHOMO_P_PASS || return 1
    if [[ -z "$MIHOMO_P_PASS" ]]; then
        MIHOMO_P_PASS=$(mihomo_random_pass)
        MIHOMO_P_PASS_RAND="y"
    fi

    if [[ "$name" == "snellv5-in" ]]; then
        read -r -p "${BLUE}启用 OBFS(http)? [y/N]: ${PLAIN}" MIHOMO_P_OBFS || return 1
        if [[ "$MIHOMO_P_OBFS" =~ ^[Yy]$ ]]; then
            MIHOMO_P_OBFS="y"
            read -r -p "${BLUE}OBFS Host(默认:icloud.com.cn): ${PLAIN}" MIHOMO_P_HOST || return 1
            MIHOMO_P_HOST=$(trim_input "$MIHOMO_P_HOST")
            MIHOMO_P_HOST=${MIHOMO_P_HOST:-icloud.com.cn}
        else
            MIHOMO_P_OBFS="n"
        fi
    else
        mihomo_select_cert || return $?
        MIHOMO_P_CERT="$mihomo_cert_path"
        MIHOMO_P_KEY="$mihomo_key_path"
    fi
    return 0
}

mihomo_install() {
    clear
    if [[ -f "$MIHOMO_EXEC_PATH" && -f "$MIHOMO_CONFIG_PATH" ]]; then
        echo -e "${YELLOW}已安装,请使用管理服务功能${PLAIN}"
        pause_enter_and_clear
        return
    fi

    local ARCH
    ARCH=$(mihomo_get_arch) || { pause_enter_and_clear; return; }
    mihomo_install_dependencies || { pause_enter_and_clear; return 1; }

    clear
    echo -e "${BLUE}选择要启用的监听器:${PLAIN}"
    local enable_anytls enable_trojan enable_snell enable_tuic enable_hy2
    read -r -p "${BLUE}启用 Anytls?   [y/N]: ${PLAIN}" enable_anytls || return 1
    read -r -p "${BLUE}启用 Trojan?   [y/N]: ${PLAIN}" enable_trojan || return 1
    read -r -p "${BLUE}启用 Snellv5?  [y/N]: ${PLAIN}" enable_snell || return 1
    read -r -p "${BLUE}启用 Tuicv5?   [y/N]: ${PLAIN}" enable_tuic || return 1
    read -r -p "${BLUE}启用 Hysteria? [y/N]: ${PLAIN}" enable_hy2 || return 1
    [[ "$enable_anytls" =~ ^[Yy]$ ]] && enable_anytls="y" || enable_anytls="n"
    [[ "$enable_trojan" =~ ^[Yy]$ ]] && enable_trojan="y" || enable_trojan="n"
    [[ "$enable_snell" =~ ^[Yy]$ ]] && enable_snell="y" || enable_snell="n"
    [[ "$enable_tuic" =~ ^[Yy]$ ]] && enable_tuic="y" || enable_tuic="n"
    [[ "$enable_hy2" =~ ^[Yy]$ ]] && enable_hy2="y" || enable_hy2="n"

    if [[ "$enable_anytls" != "y" && "$enable_trojan" != "y" && "$enable_tuic" != "y" && "$enable_hy2" != "y" && "$enable_snell" != "y" ]]; then
        echo -e "${RED}至少需要启用一个监听器,已取消安装${PLAIN}"
        pause_enter_and_clear
        return
    fi

    local random_summary="" used_tcp_ports=" " used_udp_ports=" " prompt_rc=0 item lname lhdr lport lcred
    local anytls_port="" anytls_pass="" anytls_cert="" anytls_key=""
    local trojan_port="" trojan_pass="" trojan_cert="" trojan_key=""
    local snell_port="" snell_pass="" snell_obfs="n" snell_obfs_host="icloud.com.cn"
    local tuic_port="" tuic_uuid="" tuic_pass="" tuic_cert="" tuic_key=""
    local hy2_port="" hy2_pass="" hy2_cert="" hy2_key=""

    for item in \
        "anytls-in|AnyTLS 配置|8443|AnyTLS 密码|$enable_anytls" \
        "trojan-in|Trojan 配置|10819|Trojan 密码|$enable_trojan" \
        "snellv5-in|Snell v5 配置|10815|Snellv5 PSK|$enable_snell" \
        "tuicv5-in|TUIC 配置|28443|TUIC 密码|$enable_tuic" \
        "hysteria2-in|Hysteria2 配置|18443|Hysteria2 密码|$enable_hy2"; do
        IFS='|' read -r lname lhdr lport lcred _ <<< "$item"
        [[ "${item##*|}" == "y" ]] || continue
        prompt_rc=0
        mihomo_prompt_listener_params "$lname" "$lhdr" "$lport" "install" || prompt_rc=$?
        if (( prompt_rc != 0 )); then
            if (( prompt_rc == 2 )); then
                echo -e "${YELLOW}已取消证书选择,安装已取消${PLAIN}"
                pause_enter_and_clear
                return 0
            elif (( prompt_rc == 3 )); then
                pause_enter_and_clear
                return 1
            fi
            return "$prompt_rc"
        fi
        if [[ "$MIHOMO_P_UUID_RAND" == "y" ]]; then
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="TUIC UUID: $MIHOMO_P_UUID"
        fi
        if [[ "$MIHOMO_P_PASS_RAND" == "y" ]]; then
            [[ -n "$random_summary" ]] && random_summary+=$'\n'
            random_summary+="${lcred}: $MIHOMO_P_PASS"
        fi
        case "$lname" in
            anytls-in)    anytls_port="$MIHOMO_P_PORT"; anytls_pass="$MIHOMO_P_PASS"; anytls_cert="$MIHOMO_P_CERT"; anytls_key="$MIHOMO_P_KEY" ;;
            trojan-in)    trojan_port="$MIHOMO_P_PORT"; trojan_pass="$MIHOMO_P_PASS"; trojan_cert="$MIHOMO_P_CERT"; trojan_key="$MIHOMO_P_KEY" ;;
            snellv5-in)   snell_port="$MIHOMO_P_PORT"; snell_pass="$MIHOMO_P_PASS"; snell_obfs="$MIHOMO_P_OBFS"; snell_obfs_host="$MIHOMO_P_HOST" ;;
            tuicv5-in)    tuic_port="$MIHOMO_P_PORT"; tuic_uuid="$MIHOMO_P_UUID"; tuic_pass="$MIHOMO_P_PASS"; tuic_cert="$MIHOMO_P_CERT"; tuic_key="$MIHOMO_P_KEY" ;;
            hysteria2-in) hy2_port="$MIHOMO_P_PORT"; hy2_pass="$MIHOMO_P_PASS"; hy2_cert="$MIHOMO_P_CERT"; hy2_key="$MIHOMO_P_KEY" ;;
        esac
    done

    local install_label result download_url target_version target_asset
    install_label=$(mihomo_channel_label "release")
    echo -e "${BLUE}[*] 下载 Mihomo ${install_label}...${PLAIN}"
    if ! result=$(mihomo_get_download_info "$ARCH" "release"); then
        echo -e "${RED}获取 Mihomo ${install_label}失败${PLAIN}"
        pause_enter_and_clear
        return
    fi
    IFS='|' read -r download_url target_version target_asset <<< "$result"
    mihomo_download_binary "$download_url" || { pause_enter_and_clear; return; }
    echo -e "${GREEN}内核安装完成: ${target_version} (${target_asset})${PLAIN}"

    if [[ -n "$random_summary" ]]; then
        echo -e "${GREEN}随机凭据:${PLAIN}\n${GREEN}${random_summary}${PLAIN}"
    fi

    mkdir -p "$MIHOMO_CONFIG_DIR"
    if ! mihomo_generate_config || ! mihomo_check_config || ! mihomo_create_systemd_service; then
        echo -e "${RED}配置检查或文件写入失败${PLAIN}"
        mihomo_cleanup_failed_install
        pause_enter_and_clear
        return 1
    fi
    if ! mihomo_reload_systemd; then
        mihomo_cleanup_failed_install
        pause_enter_and_clear
        return 1
    fi
    if ! systemctl enable "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1; then
        echo -e "${RED}Mihomo 设置开机自启失败${PLAIN}"
        mihomo_cleanup_failed_install
        pause_enter_and_clear
        return 1
    fi
    if ! mihomo_systemctl_checked "start" "" "Mihomo 服务启动失败"; then
        mihomo_cleanup_failed_install
        pause_enter_and_clear
        return 1
    fi

    echo -e "${GREEN}安装完成,服务已启动${PLAIN}"
    pause_enter_and_clear
}

mihomo_manage_service() {
    local opt
    while true; do
        clear
        echo -e "${BLUE}✦ Mihomo_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看服务"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
        opt=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1

        case "$opt" in
            1)
                clear
                echo -e "${BLUE}Mihomo 服务状态:${PLAIN}"
                systemctl status --no-pager "$MIHOMO_SERVICE_NAME"
                pause_enter "按回车查看配置..."
                clear
                echo -e "${BLUE}---------------------- 配置内容 ----------------------${PLAIN}"
                [[ -f "$MIHOMO_CONFIG_PATH" ]] && cat "$MIHOMO_CONFIG_PATH" || echo -e "${RED}配置文件不存在${PLAIN}"
                echo -e "${BLUE}------------------------------------------------------${PLAIN}"
                pause_enter_and_clear
                ;;
            2)
                if [[ ! -f "$MIHOMO_CONFIG_PATH" ]]; then
                    echo -e "${RED}配置文件不存在${PLAIN}"
                    pause_enter_and_clear
                    continue
                fi
                mihomo_modify_config
                ;;
            3)
                mihomo_systemctl_checked "stop" "已停止" "Mihomo 服务停止失败"
                pause_enter_and_clear
                ;;
            4)
                mihomo_systemctl_checked "restart" "已重启" "Mihomo 服务重启失败"
                pause_enter_and_clear
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

mihomo_read_listener_statuses() {
    awk '
        /^- name: anytls-in([[:space:]]|$)/    { a=1 }
        /^- name: trojan-in([[:space:]]|$)/    { tr=1 }
        /^- name: snellv5-in([[:space:]]|$)/   { s=1 }
        /^- name: tuicv5-in([[:space:]]|$)/    { tu=1 }
        /^- name: hysteria2-in([[:space:]]|$)/ { h=1 }
        END {
            print (a  ? "已启用" : "未启用")
            print (tr ? "已启用" : "未启用")
            print (s  ? "已启用" : "未启用")
            print (tu ? "已启用" : "未启用")
            print (h  ? "已启用" : "未启用")
        }
    ' "$MIHOMO_CONFIG_PATH" 2>/dev/null
}

mihomo_modify_config() {
    local opt
    local -a statuses
    while true; do
        mapfile -t statuses < <(mihomo_read_listener_statuses)

        clear
        echo -e "${BLUE}✦ Modify_Conf ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}Anytls  [${YELLOW}${statuses[0]:-未启用}${PLAIN}]"
        echo -e "${GREEN}  2.${PLAIN}Trojan  [${YELLOW}${statuses[1]:-未启用}${PLAIN}]"
        echo -e "${GREEN}  3.${PLAIN}Snellv5 [${YELLOW}${statuses[2]:-未启用}${PLAIN}]"
        echo -e "${GREEN}  4.${PLAIN}Tuicv5  [${YELLOW}${statuses[3]:-未启用}${PLAIN}]"
        echo -e "${GREEN}  5.${PLAIN}Hysteria[${YELLOW}${statuses[4]:-未启用}${PLAIN}]"
        echo -e "${GREEN}  0.${PLAIN}Return"
        opt=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1

        case "$opt" in
            1) mihomo_toggle_or_modify_listener "anytls-in" "AnyTLS" "8443" ;;
            2) mihomo_toggle_or_modify_listener "trojan-in" "Trojan" "10819" ;;
            3) mihomo_toggle_or_modify_listener "snellv5-in" "Snellv5" "10815" ;;
            4) mihomo_toggle_or_modify_listener "tuicv5-in" "TUIC" "28443" ;;
            5) mihomo_toggle_or_modify_listener "hysteria2-in" "Hysteria2" "18443" ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

mihomo_toggle_or_modify_listener() {
    local name="$1" display_name="$2" default_port="$3"
    local opt enable is_enabled auth_item extra_item add_rc

    while true; do
        is_enabled="n"
        grep -Eq "^- name: ${name}([[:space:]]|$)" "$MIHOMO_CONFIG_PATH" && is_enabled="y"

        clear
        echo -e "${BLUE}✦ ${display_name}_Conf ✦${PLAIN}"
        if [[ "$is_enabled" == "y" ]]; then
            if [[ "$name" == "snellv5-in" ]]; then
                auth_item="修改PSK"
                extra_item="切换OBFS"
            else
                auth_item="修改密码"
                extra_item="修改证书"
            fi
            echo -e "${GREEN}  1.${PLAIN}修改端口"
            echo -e "${GREEN}  2.${PLAIN}${auth_item}"
            echo -e "${GREEN}  3.${PLAIN}${extra_item}"
            echo -e "${GREEN}  4.${PLAIN}禁用服务"
            echo -e "${GREEN}  0.${PLAIN}返回上级"
            opt=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1

            case "$opt" in
                1) mihomo_modify_listener_port "$name" ;;
                2) mihomo_modify_listener_pass "$name" ;;
                3) [[ "$name" == "snellv5-in" ]] && mihomo_toggle_snell_obfs || mihomo_modify_listener_cert "$name" ;;
                4) mihomo_disable_listener "$name" "$display_name"; break ;;
                0) break ;;
                *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
            esac
        else
            echo -e "${YELLOW}  当前未启用${PLAIN}"
            read -r -p "${BLUE}是否启用? [y/N]: ${PLAIN}" enable || return 1
            if [[ "$enable" =~ ^[Yy]$ ]]; then
                add_rc=0
                mihomo_add_listener "$name" "$display_name" "$default_port" || add_rc=$?
                if (( add_rc != 0 )); then
                    (( add_rc == 2 )) && return 0
                    return "$add_rc"
                fi
            else
                break
            fi
        fi
    done
}

mihomo_add_listener() {
    local name="$1" display_name="$2" default_port="$3"
    local tmp_config backup render_ok=0 prompt_rc=0 rc=0

    mihomo_prompt_listener_params "$name" "添加 ${display_name}" "$default_port" "add" || prompt_rc=$?
    if (( prompt_rc != 0 )); then
        if (( prompt_rc == 2 )); then
            echo -e "${YELLOW}已取消添加 ${display_name}${PLAIN}"
            sleep 0.5
            return 2
        fi
        (( prompt_rc == 3 )) && { sleep 1; return 1; }
        return "$prompt_rc"
    fi

    if [[ "$name" != "snellv5-in" ]]; then
        [[ "$MIHOMO_P_UUID_RAND" == "y" ]] && echo -e "${GREEN}UUID: $MIHOMO_P_UUID${PLAIN}"
        [[ "$MIHOMO_P_PASS_RAND" == "y" ]] && echo -e "${GREEN}密码: $MIHOMO_P_PASS${PLAIN}"
    else
        [[ "$MIHOMO_P_PASS_RAND" == "y" ]] && echo -e "${GREEN}PSK: $MIHOMO_P_PASS${PLAIN}"
    fi

    tmp_config=$(mktemp) || {
        echo -e "${RED}创建临时配置失败${PLAIN}"
        sleep 1
        return 1
    }
    backup=$(mihomo_make_config_backup) || {
        echo -e "${RED}备份配置失败${PLAIN}"
        rm -f "$tmp_config"
        sleep 1
        return 1
    }
    case "$name" in
        snellv5-in) mihomo_render_listener "$name" "$MIHOMO_P_PORT" "$MIHOMO_P_PASS" "" "" "$MIHOMO_P_OBFS" "$MIHOMO_P_HOST" > "$tmp_config" && render_ok=1 ;;
        tuicv5-in)  mihomo_render_listener "$name" "$MIHOMO_P_PORT" "$MIHOMO_P_PASS" "$MIHOMO_P_CERT" "$MIHOMO_P_KEY" "$MIHOMO_P_UUID" > "$tmp_config" && render_ok=1 ;;
        *)          mihomo_render_listener "$name" "$MIHOMO_P_PORT" "$MIHOMO_P_PASS" "$MIHOMO_P_CERT" "$MIHOMO_P_KEY" > "$tmp_config" && render_ok=1 ;;
    esac
    if (( render_ok == 0 )); then
        rm -f "$tmp_config" "$backup"
        return 1
    fi

    if ! awk -v tmpfile="$tmp_config" '
        BEGIN {inserted=0}
        /^rules:/ && !inserted {
            while ((getline line < tmpfile) > 0) print line
            close(tmpfile)
            inserted=1
        }
        {print}
        END {
            if (!inserted) {
                while ((getline line < tmpfile) > 0) print line
                close(tmpfile)
            }
        }
    ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" || ! mihomo_commit_tmp_config "${MIHOMO_CONFIG_PATH}.tmp" "$backup"; then
        rm -f "$tmp_config"
        return 1
    fi
    rm -f "$tmp_config"

    mihomo_restart_with_rollback "$backup" "${display_name} 已启用" "${display_name} 已写入,但服务重启失败" || rc=$?
    sleep 1
    return "$rc"
}

mihomo_snell_obfs_enabled() {
    awk '
        /^- name: /{block=($0 == "- name: snellv5-in")}
        block && /^  obfs-opts:/{found=1}
        END {exit found ? 0 : 1}
    ' "$MIHOMO_CONFIG_PATH"
}

mihomo_toggle_snell_obfs() {
    local backup host confirm rc=0

    if mihomo_snell_obfs_enabled; then
        echo -e "${BLUE}当前OBFS: 开启${PLAIN}"
        read -r -p "${RED}确定关闭 Snell OBFS? [y/N]: ${PLAIN}" confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            return
        fi

        backup=$(mihomo_make_config_backup) || {
            echo -e "${RED}备份配置失败${PLAIN}"
            sleep 1
            return 1
        }
        awk '
            /^- name: /{block=($0 == "- name: snellv5-in"); skip=0}
            block && /^  obfs-opts:/{skip=1; next}
            block && skip && /^    /{next}
            {skip=0; print}
        ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" &&
            mihomo_commit_tmp_config "${MIHOMO_CONFIG_PATH}.tmp" "$backup" || return 1

        mihomo_restart_with_rollback "$backup" "OBFS 已关闭" "OBFS 已移除,但服务重启失败" || rc=$?
        sleep 1
        return "$rc"
    fi

    echo -e "${BLUE}当前OBFS: 关闭${PLAIN}"
    read -r -p "${BLUE}OBFS Host(默认:icloud.com.cn): ${PLAIN}" host
    host=$(trim_input "$host")
    host=${host:-icloud.com.cn}

    backup=$(mihomo_make_config_backup) || {
        echo -e "${RED}备份配置失败${PLAIN}"
        sleep 1
        return 1
    }
    ZERO_MIHOMO_HOST="$(mihomo_yaml_string "$host")" awk '
        BEGIN {host=ENVIRON["ZERO_MIHOMO_HOST"]}
        /^- name: /{block=($0 == "- name: snellv5-in")}
        {print}
        block && /^  udp:/ && !inserted {
            print "  obfs-opts:"
            print "    mode: http"
            print "    host: " host
            inserted=1
        }
    ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" &&
        mihomo_commit_tmp_config "${MIHOMO_CONFIG_PATH}.tmp" "$backup" || return 1

    mihomo_restart_with_rollback "$backup" "OBFS 已开启" "OBFS 已写入,但服务重启失败" || rc=$?
    sleep 1
    return "$rc"
}

mihomo_disable_listener() {
    local name="$1"
    local display_name="$2"
    local confirm count rc=0

    count=$(mihomo_list_configured_endpoints | wc -l | tr -d ' ')
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count <= 1 )); then
        echo -e "${RED}至少需要保留一个监听器,不能禁用 ${display_name}${PLAIN}"
        sleep 1
        return 1
    fi

    read -r -p "${RED}确定禁用 ${display_name}? [y/N]: ${PLAIN}" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        local backup
        backup=$(mihomo_make_config_backup) || {
            echo -e "${RED}备份配置失败${PLAIN}"
            sleep 1
            return 1
        }
        awk -v target="- name: $name" '
            BEGIN {skip=0}
            /^- name: /{
                if ($0 == target) {skip=1; next}
                else {skip=0}
            }
            skip && /^rules:/{skip=0; print; next}
            skip && /^[^ -]/{skip=0}
            !skip {print}
        ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" &&
            mihomo_commit_tmp_config "${MIHOMO_CONFIG_PATH}.tmp" "$backup" || return 1

        mihomo_restart_with_rollback "$backup" "${display_name} 已禁用" "${display_name} 已移除,但服务重启失败" || rc=$?
        sleep 1
        return "$rc"
    fi
}

mihomo_modify_listener_port() {
    local name="$1" new_port current_port proto backup rc=0
    proto=$(mihomo_listener_proto "$name")
    current_port=$(mihomo_list_configured_endpoints | awk -v n="$name" '$1 == n { print $3; exit }')
    read -r -p "${BLUE}新端口${current_port:+(当前:${current_port})}: ${PLAIN}" new_port
    new_port=$(trim_input "$new_port")
    [[ -z "$new_port" || "$new_port" == "$current_port" ]] && return 0
    if zero_is_valid_port "$new_port"; then
        mihomo_port_available "$new_port" "$proto" "$name" || { sleep 1; return 1; }
        backup=$(mihomo_make_config_backup) || { echo -e "${RED}备份配置失败${PLAIN}"; sleep 1; return 1; }
        awk -v target="- name: $name" -v port="$new_port" '
            /^- name: /{found=($0 == target)}
            found && /^  port:/{$0="  port: "port; found=0}
            {print}
        ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" &&
            mihomo_commit_tmp_config "${MIHOMO_CONFIG_PATH}.tmp" "$backup" || return 1
        mihomo_restart_with_rollback "$backup" "已更新" "端口已写入,但服务重启失败" || rc=$?
    else
        echo -e "${RED}端口无效${PLAIN}"
        rc=1
    fi
    sleep 1
    return "$rc"
}

mihomo_modify_listener_pass() {
    local name="$1" new_pass backup prompt_label="新密码" failure_msg="密码已写入,但服务重启失败" rc=0
    if [[ "$name" == "snellv5-in" ]]; then
        prompt_label="新PSK"
        failure_msg="PSK已写入,但服务重启失败"
    fi

    read -r -p "${BLUE}${prompt_label}: ${PLAIN}" new_pass
    if [[ -n "$new_pass" ]]; then
        backup=$(mihomo_make_config_backup) || { echo -e "${RED}备份配置失败${PLAIN}"; sleep 1; return 1; }
        ZERO_MIHOMO_PASSWORD="$(mihomo_yaml_string "$new_pass")" awk -v name="$name" -v target="- name: $name" '
            BEGIN {pass=ENVIRON["ZERO_MIHOMO_PASSWORD"]}
            /^- name: /{found=($0 == target)}
            found && name == "anytls-in"    && /^    username1:/{$0="    username1: "pass; found=0}
            found && name == "trojan-in"    && /^      password:/{$0="      password: "pass; found=0}
            found && name == "hysteria2-in" && /^    user1:/{$0="    user1: "pass; found=0}
            found && name == "snellv5-in"   && /^  psk:/{$0="  psk: "pass; found=0}
            found && name == "tuicv5-in"    && /^    [A-Fa-f0-9-]+:/{
                split($0, arr, ":")
                uuid = arr[1]; gsub(/^[[:space:]]+/, "", uuid)
                $0 = "    " uuid ": " pass; found=0
            }
            {print}
        ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" &&
            mihomo_commit_tmp_config "${MIHOMO_CONFIG_PATH}.tmp" "$backup" || return 1
        mihomo_restart_with_rollback "$backup" "已更新" "$failure_msg" || rc=$?
        sleep 1
        return "$rc"
    fi
}

mihomo_modify_listener_cert() {
    local name="$1" backup rc=0
    mihomo_select_cert || {
        rc=$?
        (( rc == 2 )) && return 0
        return "$rc"
    }
    backup=$(mihomo_make_config_backup) || { echo -e "${RED}备份配置失败${PLAIN}"; sleep 1; return 1; }
    ZERO_MIHOMO_CERT="$(mihomo_yaml_string "$mihomo_cert_path")" \
    ZERO_MIHOMO_KEY="$(mihomo_yaml_string "$mihomo_key_path")" awk -v target="- name: $name" '
        BEGIN {cert=ENVIRON["ZERO_MIHOMO_CERT"]; key=ENVIRON["ZERO_MIHOMO_KEY"]}
        /^- name: /{block=($0 == target)}
        block && /^  certificate:/{$0="  certificate: "cert}
        block && /^  private-key:/{$0="  private-key: "key; block=0}
        {print}
    ' "$MIHOMO_CONFIG_PATH" > "${MIHOMO_CONFIG_PATH}.tmp" &&
        mihomo_commit_tmp_config "${MIHOMO_CONFIG_PATH}.tmp" "$backup" || return 1
    mihomo_restart_with_rollback "$backup" "已更新" "证书已写入,但服务重启失败" || rc=$?
    sleep 1
    return "$rc"
}

mihomo_update_channel() {
    local channel="$1"
    local channel_label current_version ARCH result download_url target_version target_asset confirm backup_exec new_exec was_active=0

    clear
    if [[ ! -f "$MIHOMO_EXEC_PATH" ]]; then
        echo -e "${RED}未安装${PLAIN}"
        pause_enter_and_clear
        return
    fi

    mihomo_install_dependencies || { pause_enter_and_clear; return 1; }
    channel_label=$(mihomo_channel_label "$channel")
    current_version=$(mihomo_get_current_version_label)
    ARCH=$(mihomo_get_arch) || { pause_enter_and_clear; return; }
    if ! result=$(mihomo_get_download_info "$ARCH" "$channel"); then
        echo -e "${RED}获取 Mihomo ${channel_label}失败${PLAIN}"
        pause_enter_and_clear
        return
    fi
    IFS='|' read -r download_url target_version target_asset <<< "$result"

    echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
    echo -e "${BLUE}目标版本: ${YELLOW}${target_version}${PLAIN}"
    echo -e "${BLUE}目标文件: ${YELLOW}${target_asset}${PLAIN}"

    if [[ "$channel" == "release" && "$current_version" == "$target_version" ]]; then
        echo -e "${GREEN}已是最新版本${PLAIN}"
        pause_enter_and_clear
        return
    fi

    read -r -p "${BLUE}是否更新到 Mihomo ${channel_label}? [y/N]: ${PLAIN}" confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || return

    echo -e "${BLUE}[*] 更新 Mihomo ${channel_label}中...${PLAIN}"
    new_exec=$(mktemp "${MIHOMO_EXEC_PATH}.new.XXXXXX") || return 1
    if ! mihomo_download_binary "$download_url" "$new_exec" ||
       ! "$new_exec" -v >/dev/null 2>&1 || ! mihomo_check_config "$new_exec"; then
        rm -f "$new_exec"
        echo -e "${RED}新版内核下载、版本或配置检查失败${PLAIN}"
        pause_enter_and_clear
        return 1
    fi
    backup_exec=$(mktemp) || { rm -f "$new_exec"; return 1; }
    if ! cp "$MIHOMO_EXEC_PATH" "$backup_exec"; then
        rm -f "$new_exec" "$backup_exec"
        echo -e "${RED}备份当前内核失败${PLAIN}"
        return 1
    fi
    systemctl is-active --quiet "$MIHOMO_SERVICE_NAME" && was_active=1
    if (( was_active )) && ! systemctl stop "$MIHOMO_SERVICE_NAME"; then
        rm -f "$new_exec" "$backup_exec"
        return 1
    fi

    if mv -f "$new_exec" "$MIHOMO_EXEC_PATH" &&
       { (( was_active == 0 )) || { systemctl start "$MIHOMO_SERVICE_NAME" && mihomo_service_healthy; }; }; then
        rm -f "$backup_exec"
        echo -e "${GREEN}更新完成: ${target_version}${PLAIN}"
        (( was_active )) || echo -e "${YELLOW}服务保持停止状态${PLAIN}"
    else
        systemctl stop "$MIHOMO_SERVICE_NAME" >/dev/null 2>&1 || true
        if install -m 755 "$backup_exec" "$new_exec" && mv -f "$new_exec" "$MIHOMO_EXEC_PATH"; then
            rm -f "$backup_exec"
            if (( was_active == 0 )) || { systemctl start "$MIHOMO_SERVICE_NAME" && mihomo_service_healthy; }; then
                echo -e "${YELLOW}更新失败,已恢复旧版本及启停状态${PLAIN}"
            else
                echo -e "${RED}已恢复旧版本,但服务未能启动${PLAIN}"
                service_failure_hint "$MIHOMO_SERVICE_NAME"
            fi
        else
            rm -f "$new_exec"
            echo -e "${RED}恢复旧版本失败,备份保留在 ${backup_exec}${PLAIN}"
        fi
        pause_enter_and_clear
        return 1
    fi
    pause_enter_and_clear
}

mihomo_update() {
    local option
    while true; do
        clear
        echo -e "${BLUE}✦ Mihomo_Update ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}更新测试版"
        echo -e "${GREEN}  2.${PLAIN}更新正式版"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
        option=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1
        case "$option" in
            1) mihomo_update_channel "alpha" ;;
            2) mihomo_update_channel "release" ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

mihomo_delete() {
    local confirm
    clear
    read -r -p "${RED}确定删除? [y/N]: ${PLAIN}" confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop "$MIHOMO_SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$MIHOMO_SERVICE_NAME" 2>/dev/null || true
        rm -f "$MIHOMO_SERVICE_FILE" "$MIHOMO_EXEC_PATH"
        rm -rf "$MIHOMO_CONFIG_DIR"
        mihomo_reload_systemd || true
        echo -e "${GREEN}已删除${PLAIN}"
    fi
    pause_enter_and_clear
}

mihomo_menu() {
    local option
    while true; do
        clear
        echo -e "${BLUE}✦ Mihomo_Ver.1.6 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}安装服务"
        echo -e "${GREEN}  2.${PLAIN}管理服务"
        echo -e "${GREEN}  3.${PLAIN}更新内核"
        echo -e "${GREEN}  4.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        option=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1
        case "$option" in
            1) mihomo_install ;;
            2)
                if [[ ! -f "$MIHOMO_EXEC_PATH" ]]; then
                    echo -e "${RED}未安装${PLAIN}"
                    pause_enter_and_clear
                    continue
                fi
                mihomo_manage_service
                ;;
            3) mihomo_update ;;
            4) mihomo_delete ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

# ============================ Shared WARP ============================

CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

WARP_WGCF_REPO="ViRb3/wgcf"
WARP_WGCF_MIRROR_URL="https://cdn-wgcf.pages.dev/ViRb3/wgcf"

WARP_REG_PRIV=""
WARP_REG_PUB=""
WARP_REG_V4=""
WARP_REG_V6=""
WARP_REG_ENDPOINT=""
WARP_REG_ORG=""
WARP_REG_EP_HOST=""
WARP_REG_EP_V4=""
WARP_REG_EP_V6=""
WARP_REG_EP_PORT=""
WARP_REG_HTTP_CODE=""
WARP_REG_ERR_BRIEF=""

warp_info()    { log_prefixed "$CYAN" "[INFO]" "$*"; }
warp_ok()      { log_prefixed "$GREEN" "[ OK ]" "$*"; }
warp_warn()    { log_prefixed "$YELLOW" "[WARN]" "$*"; }
warp_err()     { log_prefixed "$RED" "[ERROR]" "$*"; exit 1; }
warp_divider() { echo "  ══════════════════════════"; }

warp_make_backup() {
    local file="$1" backup
    backup="$(mktemp)" || warp_err "创建配置备份失败"
    chmod 600 "$backup" 2>/dev/null || true
    cp "$file" "$backup" || {
        rm -f "$backup"
        warp_err "备份配置失败: $file"
    }
    printf '%s\n' "$backup"
}

warp_update_conf_key() {
    local file="$1" section="" key val tmp
    if (( $# >= 4 )); then
        section="$2"; key="$3"; val="$4"
    else
        key="$2"; val="$3"
    fi
    tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    if ZERO_CONF_VAL="$val" awk -v sec="$section" -v k="$key" '
        BEGIN { v = ENVIRON["ZERO_CONF_VAL"]; in_sec = (sec == ""); saw_sec = in_sec; done_k = 0 }
        /^\[[^]]+\][[:space:]]*$/ {
            if (sec != "" && in_sec && !done_k) { print k " = " v; done_k = 1 }
            in_sec = (sec == "" || $0 ~ "^\\[" sec "\\][[:space:]]*$")
            if (in_sec) saw_sec = 1
            print; next
        }
        in_sec && !done_k {
            line = $0; sub(/^[[:space:]]+/, "", line)
            if (line ~ ("^" k "[[:space:]]*=")) { print k " = " v; done_k = 1; next }
        }
        { print }
        END {
            if (!done_k) {
                if (sec != "" && !saw_sec) print "[" sec "]"
                print k " = " v
            }
        }
    ' "$file" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

warp_endpoint_host() {
    local value="$1"
    if [[ "$value" =~ ^\[([0-9a-fA-F:]+)\]:[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^([^:]*):[0-9]{1,5}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$value"
    fi
}

warp_endpoint_port() {
    local value="$1"
    if [[ "$value" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[^:]*:([0-9]{1,5})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

warp_is_valid_endpoint() {
    local ep="$1" host port
    if [[ "$ep" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        dns_is_valid_ipv6 "$host" || return 1
    elif [[ "$ep" =~ ^([^:]+):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        if [[ "$host" =~ ^[0-9.]+$ ]]; then
            dns_is_valid_ipv4 "$host" || return 1
        else
            [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        fi
    else
        return 1
    fi
    zero_is_valid_port "$((10#$port))"
}

warp_trace_value() {
    local trace="$1" wanted="$2" k v
    while IFS='=' read -r k v; do
        if [[ "$k" == "$wanted" ]]; then
            printf '%s\n' "${v%$'\r'}"
            return 0
        fi
    done <<< "$trace"
}

warp_trace_warp_label() {
    local warp
    warp="$(warp_trace_value "$1" "warp")"
    [[ "$warp" == "on" ]] && warp="free"
    [[ -n "$warp" ]] && printf '%s\n' "$warp" || printf 'unknown\n'
}

warp_merge_warp_status() {
    local status="unknown" trace warp
    for trace in "$@"; do
        [[ -z "$trace" ]] && continue
        warp="$(warp_trace_warp_label "$trace")"
        case "$warp" in
            plus) printf 'plus\n'; return 0 ;;
            free) status="free" ;;
            off)  [[ "$status" == "unknown" ]] && status="off" ;;
        esac
    done
    printf '%s\n' "$status"
}

warp_parse_team_response() {
    local -a fields=()
    mapfile -d '' -t fields < <(jq -sj '
        select(length == 1) | .[0] | .config as $c | $c.peers[0] as $p |
        select(.account and $c.interface.addresses.v4 and $c.interface.addresses.v6 and $p.public_key) |
        [$c.interface.addresses.v4, $c.interface.addresses.v6, $p.public_key,
         (.account.organization // ""), (($p.endpoint.ports[0] // 2408) | tostring),
         ($p.endpoint.host // ""), ($p.endpoint.v4 // ""), ($p.endpoint.v6 // "")] |
        .[] | ., "\u0000"
    ')
    [[ "${#fields[@]}" == 8 ]] || return 1
    warp_v4="${fields[0]%%/*}"
    warp_v6="${fields[1]%%/*}"
    peer_pub="${fields[2]}"
    org="${fields[3]}"; ep_port="${fields[4]}"; ep_host="${fields[5]}"
    ep_v4="${fields[6]%%:*}"
    ep_v6="${fields[7]}"
    if [[ "$ep_v6" == \[* ]]; then
        ep_v6="${ep_v6#\[}"
        ep_v6="${ep_v6%%\]*}"
    fi
    { [[ "$ep_v6" == *"cf1"* ]] || ! dns_is_valid_ipv6 "$ep_v6"; } && ep_v6=""
    return 0
}

warp_release_latest_tag() {
    local repo="$1" mirror_url="$2" net_mode="$3" version=""

    if [[ "$net_mode" != "v6_only" ]]; then
        version="$(curl --connect-timeout 5 --max-time 20 -fsSI "https://github.com/${repo}/releases/latest" 2>/dev/null \
            | awk 'tolower($1)=="location:" {print $2}' \
            | tail -n1 \
            | tr -d '\r' \
            | awk -F/ '{print $NF}')"
    fi

    if [[ -z "$version" ]]; then
        version="$(curl --connect-timeout 5 --max-time 20 -fsSL "${mirror_url}/releases/latest" 2>/dev/null \
            | grep -oE '/releases/tag/v[0-9.]+' \
            | sed 's#.*/##' \
            | head -n1)"
    fi

    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

warp_download_verified_asset() {
    local repo="$1" mirror_url="$2" version="$3" asset="$4" target="$5" net_mode="$6"
    local official_url="https://github.com/${repo}" source_url checksum_file expected actual

    source_url="$official_url"
    [[ "$net_mode" == "v6_only" ]] && source_url="$mirror_url"

    if ! curl --connect-timeout 5 --max-time 120 -fL \
        "${source_url}/releases/download/${version}/${asset}" -o "$target"; then
        rm -f "$target"
        [[ "$source_url" == "$mirror_url" ]] && return 1
        source_url="$mirror_url"
        curl --connect-timeout 5 --max-time 120 -fL \
            "${source_url}/releases/download/${version}/${asset}" -o "$target" || {
            rm -f "$target"
            return 1
        }
    fi

    checksum_file="${target}.checksums"
    if [[ "$net_mode" != "v6_only" ]]; then
        curl --connect-timeout 5 --max-time 30 -fsSL \
            "${official_url}/releases/download/${version}/checksums.txt" -o "$checksum_file" 2>/dev/null || true
    fi
    if [[ ! -s "$checksum_file" ]]; then
        curl --connect-timeout 5 --max-time 30 -fsSL \
            "${mirror_url}/releases/download/${version}/checksums.txt" -o "$checksum_file" 2>/dev/null || {
            rm -f "$target" "$checksum_file"
            return 1
        }
    fi

    expected="$(awk -v wanted="$asset" '{file=$2; sub(/^\*/, "", file); if (file == wanted) {print $1; exit}}' "$checksum_file")"
    actual="$(sha256sum "$target" 2>/dev/null | awk '{print $1}')"
    rm -f "$checksum_file"

    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        rm -f "$target"
        return 1
    fi

    return 0
}

warp_resolve_host_by_family() {
    local host="$1" family="$2"
    command -v getent >/dev/null 2>&1 || return 1
    case "$family" in
        4) getent ahostsv4 "$host" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1; exit }' ;;
        6) getent ahostsv6 "$host" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ { print $1; exit }' ;;
        *) return 1 ;;
    esac
}

warp_detect_net_mode() {
    local has_v4=0 has_v6=0 check_v4=1 check_v6=1 pid4="" pid6=""
    if command -v ip >/dev/null 2>&1; then
        dns_has_ipv4 || check_v4=0
        dns_has_ipv6 || check_v6=0
    fi
    if (( check_v4 == 1 )); then
        curl -4 --noproxy '*' --connect-timeout 3 --max-time 5 -fsS http://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1 &
        pid4=$!
    fi
    if (( check_v6 == 1 )); then
        curl -6 -g --noproxy '*' --connect-timeout 3 --max-time 5 -fsS "http://[2606:4700:4700::1111]/cdn-cgi/trace" >/dev/null 2>&1 &
        pid6=$!
    fi
    [[ -n "$pid4" ]] && wait "$pid4" && has_v4=1
    [[ -n "$pid6" ]] && wait "$pid6" && has_v6=1

    if (( has_v4 == 1 && has_v6 == 1 )); then
        printf 'dual\n'
    elif (( has_v6 == 1 )); then
        printf 'v6_only\n'
    elif (( has_v4 == 1 )); then
        printf 'v4_only\n'
    elif (( check_v4 == 1 && check_v6 == 1 )); then
        printf 'dual\n'
    elif (( check_v6 == 1 )); then
        printf 'v6_only\n'
    elif (( check_v4 == 1 )); then
        printf 'v4_only\n'
    else
        printf 'none\n'
    fi
}

warp_select_endpoint() {
    local net_mode="$1" current="$2" preferred_v4="${3:-}" preferred_v6="${4:-}" preferred_port="${5:-}"
    local host port resolved=""

    port="${preferred_port:-$(warp_endpoint_port "$current")}"
    [[ -z "$port" ]] && port="2408"

    case "$net_mode" in
        v6_only)
            if [[ -n "$preferred_v6" ]]; then
                printf '[%s]:%s\n' "$preferred_v6" "$port"
                return 0
            fi
            host="$(warp_endpoint_host "$current")"
            if [[ -n "$host" ]] && dns_is_valid_ipv6 "$host" && ! dns_is_valid_ipv4 "$host"; then
                printf '[%s]:%s\n' "$host" "$port"
                return 0
            fi
            if [[ -n "$host" ]] && ! dns_is_valid_ipv4 "$host"; then
                resolved="$(warp_resolve_host_by_family "$host" 6 || true)"
            fi
            [[ -z "$resolved" ]] && resolved="$(warp_resolve_host_by_family "engage.cloudflareclient.com" 6 || true)"
            [[ -n "$resolved" ]] || return 1
            printf '[%s]:%s\n' "$resolved" "$port"
            ;;
        dual|v4_only)
            if [[ -n "$preferred_v4" ]] && dns_is_valid_ipv4 "$preferred_v4"; then
                printf '%s:%s\n' "$preferred_v4" "$port"
                return 0
            fi
            host="$(warp_endpoint_host "$current")"
            if [[ -n "$host" ]] && dns_is_valid_ipv4 "$host"; then
                printf '%s:%s\n' "$host" "$port"
                return 0
            fi
            if [[ -n "$host" ]] && ! dns_is_valid_ipv6 "$host"; then
                resolved="$(warp_resolve_host_by_family "$host" 4 || true)"
            fi
            [[ -z "$resolved" ]] && resolved="$(warp_resolve_host_by_family "engage.cloudflareclient.com" 4 || true)"
            [[ -n "$resolved" ]] || return 1
            printf '%s:%s\n' "$resolved" "$port"
            ;;
        *) return 1 ;;
    esac
}

warp_require_endpoint() {
    local net_mode="$1" current="$2" v4="${3:-}" v6="${4:-}" port="${5:-}" selected
    [[ "$net_mode" == "none" ]] && warp_err "当前服务器无可用网络，无法确定 Endpoint"
    selected="$(warp_select_endpoint "$net_mode" "$current" "$v4" "$v6" "$port")" ||
        warp_err "无法确定适配 ${net_mode} 的 Endpoint: ${current}"
    printf '%s\n' "$selected"
}

warp_register_wgcf_free() {
    local arch="$1" net_mode="$2"
    local wgcf_ver asset tmpdir wgcf_bin addr

    WARP_REG_PRIV=""
    WARP_REG_PUB=""
    WARP_REG_V4=""
    WARP_REG_V6=""
    WARP_REG_ENDPOINT=""

    wgcf_ver="$(warp_release_latest_tag "$WARP_WGCF_REPO" "$WARP_WGCF_MIRROR_URL" "$net_mode" || true)"
    [[ -n "$wgcf_ver" ]] || return 1

    tmpdir="$(mktemp -d /tmp/zero-wgcf.XXXXXX)" || return 1
    wgcf_bin="${tmpdir}/wgcf"
    asset="wgcf_${wgcf_ver#v}_linux_${arch}"

    if ! warp_download_verified_asset "$WARP_WGCF_REPO" "$WARP_WGCF_MIRROR_URL" "$wgcf_ver" "$asset" "$wgcf_bin" "$net_mode" ||
       ! chmod +x "$wgcf_bin"; then
        rm -rf "$tmpdir"
        return 1
    fi

    if ! ( set +o pipefail; cd "$tmpdir" && yes 2>/dev/null | ./wgcf register >/dev/null 2>&1 && ./wgcf generate >/dev/null 2>&1 ); then
        rm -rf "$tmpdir"
        return 1
    fi

    WARP_REG_PRIV="$(awk -F' = ' '/^PrivateKey = /{print $2; exit}' "$tmpdir/wgcf-profile.conf")"
    WARP_REG_PUB="$(awk -F' = ' '/^PublicKey = /{print $2; exit}' "$tmpdir/wgcf-profile.conf")"
    addr="$(awk -F' = ' '/^Address = /{print $2; exit}' "$tmpdir/wgcf-profile.conf")"
    WARP_REG_ENDPOINT="$(awk -F' = ' '/^Endpoint = /{print $2; exit}' "$tmpdir/wgcf-profile.conf")"
    WARP_REG_V4="$(printf '%s\n' "$addr" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    WARP_REG_V6="$(printf '%s\n' "$addr" | grep -oE '2606:[0-9a-fA-F:]+' | head -n1)"
    rm -rf "$tmpdir"

    [[ -n "$WARP_REG_PRIV" && -n "$WARP_REG_PUB" && -n "$WARP_REG_V4" && -n "$WARP_REG_V6" && -n "$WARP_REG_ENDPOINT" ]]
}

warp_register_team_api() {
    local jwt_token="$1"
    local priv pub serial api_result http_code response warp_v4="" warp_v6="" peer_pub="" org="" ep_port="" ep_host="" ep_v4="" ep_v6=""

    WARP_REG_PRIV=""
    WARP_REG_PUB=""
    WARP_REG_V4=""
    WARP_REG_V6=""
    WARP_REG_ORG=""
    WARP_REG_EP_HOST=""
    WARP_REG_EP_V4=""
    WARP_REG_EP_V6=""
    WARP_REG_EP_PORT=""
    WARP_REG_HTTP_CODE=""
    WARP_REG_ERR_BRIEF=""

    priv="$(wg genkey)" || return 1
    pub="$(printf '%s' "$priv" | wg pubkey)" || return 1
    serial="$(zero_random_uuid)" || return 1

    api_result="$(curl -sS --connect-timeout 5 --max-time 30 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "Content-Type: application/json" \
        -H "Cf-Access-Jwt-Assertion: ${jwt_token}" \
        -d "{
            \"key\": \"${pub}\",
            \"install_id\": \"\",
            \"fcm_token\": \"\",
            \"tos\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
            \"model\": \"Linux\",
            \"serial_number\": \"${serial}\"
        }" -w $'\n%{http_code}' 2>/dev/null || true)"

    http_code="${api_result##*$'\n'}"
    response="${api_result%$'\n'*}"
    WARP_REG_HTTP_CODE="${http_code:-000}"

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ || -z "$response" ]]; then
        WARP_REG_ERR_BRIEF="$(printf '%s' "$response" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
        return 1
    fi
    printf '%s' "$response" | grep -q '"account"' || return 2
    warp_parse_team_response <<< "$response" || return 3
    [[ -n "$warp_v4" && -n "$warp_v6" && -n "$peer_pub" ]] || return 3

    WARP_REG_PRIV="$priv"
    WARP_REG_PUB="$peer_pub"
    WARP_REG_V4="$warp_v4"
    WARP_REG_V6="$warp_v6"
    WARP_REG_ORG="$org"
    WARP_REG_EP_HOST="$ep_host"
    WARP_REG_EP_V4="$ep_v4"
    WARP_REG_EP_V6="$ep_v6"
    WARP_REG_EP_PORT="$ep_port"
    WARP_REG_ENDPOINT="${ep_host:-engage.cloudflareclient.com:${ep_port:-2408}}"
    return 0
}

warp_prompt_and_register_team() {
    local jwt_token="" reg_rc=0 read_ok=1

    echo -e "${YELLOW}获取 Token：${NC}"
    echo -e "  打开 ${CYAN}https://<组织名>.cloudflareaccess.com/warp${NC}"
    echo -e "  登陆后按 F12 -> Console 输入:"
    echo -e "  ${CYAN}console.log(document.querySelector(\"meta[http-equiv='refresh']\").content.split(\"=\")[2])${NC}"
    echo -e "  ${YELLOW}Token 有效期较短，复制后请立即粘贴${NC}"
    warp_warn "团队账户使用兼容注册接口，可能因 Cloudflare 调整而失效"
    read -rsp "请粘贴 JWT Token（直接回车取消）: " jwt_token || read_ok=0
    printf '\n'
    jwt_token="$(trim_input "${jwt_token//$'\r'/}")"
    if [[ -z "$jwt_token" ]]; then
        (( read_ok == 0 )) && return 1
        warp_warn "已取消"
        return 2
    fi
    [[ "$jwt_token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || warp_err "JWT Token 包含非法字符"

    warp_info "生成密钥并向 Cloudflare API 注册团队设备 ..."
    warp_register_team_api "$jwt_token" || reg_rc=$?
    if (( reg_rc != 0 )); then
        [[ -n "$WARP_REG_ERR_BRIEF" ]] && warp_warn "API 返回: ${WARP_REG_ERR_BRIEF}"
        case "$reg_rc" in
            2) warp_err "API 响应缺少账户信息，团队设备注册失败" ;;
            3) warp_err "无法从 API 响应中提取有效的 WARP 配置" ;;
            *) warp_err "团队设备注册失败（HTTP ${WARP_REG_HTTP_CODE:-000}），请检查 Token 与注册权限" ;;
        esac
    fi
    warp_ok "团队设备注册成功"
    warp_warn "该设备已登记到 Cloudflare，删除本机配置时需自行清理后台记录"
    [[ -n "$WARP_REG_ENDPOINT" ]] || warp_err "API 未返回可用的 Endpoint"
    return 0
}

# ============================ Sing-box ============================

SINGBOX_EXEC_PATH="/usr/local/bin/sing-box"
SINGBOX_CONFIG_DIR="/etc/sing-box"
SINGBOX_CONFIG_PATH="${SINGBOX_CONFIG_DIR}/config.json"
SINGBOX_WARP_ACCOUNT_FILE="${SINGBOX_CONFIG_DIR}/warp-account.json"
SINGBOX_SERVICE_NAME="sing-box-zero.service"
SINGBOX_SERVICE_FILE="/etc/systemd/system/${SINGBOX_SERVICE_NAME}"
SINGBOX_MANAGED_MARKER="${SINGBOX_CONFIG_DIR}/.zero-managed"
SINGBOX_RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases"
SINGBOX_SHADOWTLS_TAG="stls-in"
SINGBOX_WARP_TAG="WARP"

SINGBOX_STAGE_DIR=""
SINGBOX_STAGE_BIN=""
SINGBOX_STAGE_VERSION=""
SINGBOX_STAGE_ASSET=""
SINGBOX_STAGE_URL=""
SINGBOX_STAGE_DIGEST=""
SINGBOX_NEW_INBOUND=""
SINGBOX_NEW_SUMMARY=""
SINGBOX_CERT_PATH=""
SINGBOX_KEY_PATH=""
SINGBOX_WARP_JQ_DEFS='
    def is_warp_resolve:
        .action == "resolve" and
        ((.domain_suffix // []) == ["challenges.cloudflare.com", "googlevideo.com", "youtube.com"]);
    def is_warp_rule:
        (.outbound // "") == $tag or is_warp_resolve;
'

singbox_is_managed() {
    [[ -f "$SINGBOX_MANAGED_MARKER" ]]
}

singbox_is_installed() {
    [[ -x "$SINGBOX_EXEC_PATH" && -f "$SINGBOX_CONFIG_PATH" && -f "$SINGBOX_SERVICE_FILE" ]]
}

singbox_atomic_install() {
    local source_file="$1" destination="$2" mode="$3" dest_dir="${2%/*}" temp_file
    if [[ "$destination" == */* && -n "$dest_dir" && ! -d "$dest_dir" ]]; then
        install -d -m 755 "$dest_dir" || return 1
    fi
    temp_file=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if install -m "$mode" "$source_file" "$temp_file" && mv -f "$temp_file" "$destination"; then
        return 0
    fi
    rm -f "$temp_file"
    return 1
}

singbox_get_arch() {
    zero_get_arch || {
        echo -e "${RED}Sing-box 暂不支持当前架构: $(uname -m)${PLAIN}" >&2
        return 1
    }
}

singbox_install_dependencies() {
    zero_ensure_systemd_and_pkgs "Sing-box" \
        curl:curl jq:jq tar:tar ca-certificates:update-ca-certificates \
        openssl:openssl coreutils:sha256sum iproute2:ss
}

singbox_random_password() {
    local password
    password=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9') || return 1
    password="${password:0:16}"
    [[ "$password" =~ ^[A-Za-z0-9]{16}$ ]] || return 1
    printf '%s' "$password"
}

singbox_random_ss_password() {
    openssl rand -base64 "$1" 2>/dev/null | tr -d '\r\n'
}

singbox_validate_snell_psk() {
    local bytes
    bytes=$(LC_ALL=C printf '%s' "$1" | wc -c | tr -d ' ')
    [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes >= 12 && bytes <= 255 ))
}

singbox_validate_ss_password() {
    local password="$1" expected_bytes="$2" decoded_bytes
    [[ "$password" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    printf '%s' "$password" | base64 -d >/dev/null 2>&1 || return 1
    decoded_bytes=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [[ "$decoded_bytes" =~ ^[0-9]+$ ]] && (( decoded_bytes == expected_bytes ))
}

singbox_get_current_version() {
    local version_line version
    [[ -x "$SINGBOX_EXEC_PATH" ]] || return 1
    version_line=$("$SINGBOX_EXEC_PATH" version 2>/dev/null | head -n1)
    version=$(printf '%s\n' "$version_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?' | head -n1)
    printf '%s\n' "${version:-未知}"
}

singbox_version_supports_snell() {
    local version="${1#v}" core major minor
    core="${version%%-*}"
    major="${core%%.*}"
    core="${core#*.}"
    minor="${core%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    (( major > 1 || (major == 1 && minor >= 14) ))
}

singbox_supports_snell() {
    local version
    version=$(singbox_get_current_version) || return 1
    singbox_version_supports_snell "$version"
}

singbox_cleanup_stage() {
    [[ -n "$SINGBOX_STAGE_DIR" && -d "$SINGBOX_STAGE_DIR" ]] && rm -rf "$SINGBOX_STAGE_DIR"
    SINGBOX_STAGE_DIR=""
    SINGBOX_STAGE_BIN=""
    SINGBOX_STAGE_VERSION=""
    SINGBOX_STAGE_ASSET=""
    SINGBOX_STAGE_URL=""
    SINGBOX_STAGE_DIGEST=""
}

singbox_get_release_object() {
    local channel="$1" url response http_code

    case "$channel" in
        release) url="${SINGBOX_RELEASE_API}/latest" ;;
        beta) url="${SINGBOX_RELEASE_API}?per_page=30" ;;
        *) return 1 ;;
    esac
    response=$(curl -sSL --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        --write-out '\n%{http_code}' "$url") || return 1
    http_code="${response##*$'\n'}"
    response="${response%$'\n'*}"
    if [[ "$http_code" != 2?? ]]; then
        printf 'GitHub API 返回 HTTP %s\n' "$http_code" >&2
        printf '%s' "$response" | jq -r '.message // empty' >&2 2>/dev/null
        return 1
    fi
    if [[ "$channel" == beta ]]; then
        printf '%s' "$response" | jq -c '[.[] | select(.draft == false and .prerelease == true)][0]'
    else
        printf '%s\n' "$response"
    fi
}

singbox_prepare_release() {
    local channel="$1"
    local arch release_json tag version asset_name url digest

    singbox_cleanup_stage
    arch=$(singbox_get_arch) || return 1
    release_json=$(singbox_get_release_object "$channel") || {
        echo -e "${RED}获取 Sing-box Release 信息失败${PLAIN}"
        return 1
    }
    [[ -n "$release_json" && "$release_json" != "null" ]] || {
        echo -e "${RED}未找到可用的 Sing-box Release${PLAIN}"
        return 1
    }

    tag=$(printf '%s' "$release_json" | jq -r '.tag_name // empty')
    version="${tag#v}"
    [[ -n "$version" ]] || {
        echo -e "${RED}无法读取 Sing-box 版本号${PLAIN}"
        return 1
    }

    asset_name="sing-box-${version}-linux-${arch}.tar.gz"
    IFS='|' read -r url digest < <(
        jq -r --arg name "$asset_name" '([.assets[]? | select(.name == $name)][0] // {}) | [(.browser_download_url // ""), (.digest // "")] | join("|")' <<<"$release_json"
    )
    digest="${digest#sha256:}"
    digest=$(printf '%s' "$digest" | tr '[:upper:]' '[:lower:]')

    [[ -n "$url" ]] || {
        echo -e "${RED}Release 中未找到 ${asset_name}${PLAIN}"
        return 1
    }
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || {
        echo -e "${RED}Release 未提供有效 SHA-256,已拒绝安装未校验文件${PLAIN}"
        return 1
    }

    SINGBOX_STAGE_VERSION="$version"
    SINGBOX_STAGE_ASSET="$asset_name"
    SINGBOX_STAGE_URL="$url"
    SINGBOX_STAGE_DIGEST="$digest"
}

singbox_download_prepared_release() {
    local archive extracted_bin actual_sha

    [[ -n "$SINGBOX_STAGE_VERSION" && -n "$SINGBOX_STAGE_ASSET" && \
       -n "$SINGBOX_STAGE_URL" && "$SINGBOX_STAGE_DIGEST" =~ ^[0-9a-f]{64}$ ]] || {
        echo -e "${RED}Sing-box Release 信息不完整,无法下载${PLAIN}"
        return 1
    }

    SINGBOX_STAGE_DIR=$(mktemp -d /tmp/zero-singbox.XXXXXX) || return 1
    archive="${SINGBOX_STAGE_DIR}/${SINGBOX_STAGE_ASSET}"
    echo -e "${BLUE}正在下载 Sing-box ${SINGBOX_STAGE_VERSION} (${SINGBOX_STAGE_ASSET})...${PLAIN}"
    if ! curl -fL --connect-timeout 10 --max-time 180 "$SINGBOX_STAGE_URL" -o "$archive"; then
        echo -e "${RED}Sing-box 下载失败${PLAIN}"
        singbox_cleanup_stage
        return 1
    fi

    actual_sha=$(sha256sum "$archive" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    if [[ "$actual_sha" != "$SINGBOX_STAGE_DIGEST" ]]; then
        echo -e "${RED}Sing-box SHA-256 校验失败,已删除下载文件${PLAIN}"
        singbox_cleanup_stage
        return 1
    fi

    if ! tar -xzf "$archive" -C "$SINGBOX_STAGE_DIR"; then
        echo -e "${RED}Sing-box 解压失败${PLAIN}"
        singbox_cleanup_stage
        return 1
    fi

    extracted_bin=$(find "$SINGBOX_STAGE_DIR" -type f -name sing-box -perm -u+x | head -n1)
    [[ -n "$extracted_bin" ]] || {
        echo -e "${RED}压缩包中未找到 Sing-box 可执行文件${PLAIN}"
        singbox_cleanup_stage
        return 1
    }
    "$extracted_bin" version >/dev/null 2>&1 || {
        echo -e "${RED}下载的 Sing-box 无法执行${PLAIN}"
        singbox_cleanup_stage
        return 1
    }

    SINGBOX_STAGE_BIN="$extracted_bin"
    echo -e "${GREEN}SHA-256 校验通过${PLAIN}"
}

singbox_version_is_newer() {
    local candidate="${1#v}" current="${2#v}" dpkg_prerelease='~'

    candidate="${candidate/-/$dpkg_prerelease}"
    current="${current/-/$dpkg_prerelease}"
    dpkg --compare-versions "$candidate" gt "$current"
}

singbox_select_cert() {
    zero_select_tls_cert "===== Sing-box 证书配置 =====" || return $?
    SINGBOX_CERT_PATH="$ZERO_SELECTED_CERT"
    SINGBOX_KEY_PATH="$ZERO_SELECTED_KEY"
}

singbox_tag_for_type() {
    case "$1" in
        anytls) echo "anytls-in" ;;
        trojan) echo "trojan-in" ;;
        shadowsocks) echo "ss-in" ;;
        tuic) echo "tuic-in" ;;
        hysteria2) echo "hy2-in" ;;
        snell) echo "snell-in" ;;
        *) return 1 ;;
    esac
}

singbox_proto_for_type() {
    case "$1" in
        anytls|trojan|snell) echo "tcp" ;;
        tuic|hysteria2) echo "udp" ;;
        shadowsocks) echo "both" ;;
        *) return 1 ;;
    esac
}

singbox_default_port_for_type() {
    case "$1" in
        anytls) echo 8443 ;;
        trojan) echo 10819 ;;
        shadowsocks) echo 10818 ;;
        tuic) echo 28443 ;;
        hysteria2) echo 18443 ;;
        snell) echo 10815 ;;
        *) return 1 ;;
    esac
}

singbox_label_for_type() {
    case "$1" in
        anytls) echo "AnyTLS" ;;
        trojan) echo "Trojan + WS + TLS" ;;
        shadowsocks) echo "Shadowsocks 2022" ;;
        tuic) echo "TUIC v5" ;;
        hysteria2) echo "Hysteria2" ;;
        snell) echo "Snell v6" ;;
        *) echo "$1" ;;
    esac
}

singbox_type_uses_tls() {
    case "$1" in
        anytls|trojan|tuic|hysteria2) return 0 ;;
        *) return 1 ;;
    esac
}

singbox_config_has_tag() {
    jq -e --arg tag "$2" '.inbounds[]? | select(.tag == $tag)' "$1" >/dev/null 2>&1
}

singbox_shadowsocks_uses_shadowtls() {
    jq -e --arg tag "$SINGBOX_SHADOWTLS_TAG" \
        '.inbounds[]? | select(.type == "shadowtls" and .tag == $tag and .version == 3 and .detour == "ss-in")' \
        "$1" >/dev/null 2>&1
}

singbox_config_uses_port() {
    local config_file="$1" port="$2" proto="${3:-both}" exclude_tag="${4:-}"
    jq -e --argjson port "$port" --arg proto "$proto" --arg exclude "$exclude_tag" '
        def inb_proto:
            if (.type == "tuic" or .type == "hysteria2" or .type == "hysteria") then "udp"
            elif (.type == "anytls" or .type == "trojan" or .type == "shadowtls" or .type == "snell" or .type == "vmess" or .type == "vless") then "tcp"
            elif (.network == "tcp") then "tcp"
            elif (.network == "udp") then "udp"
            else "both"
            end;
        any(.inbounds[]?;
            .listen_port == $port and .tag != $exclude and
            (inb_proto as $ep | ($proto == "both" or $ep == "both" or $proto == $ep))
        )
    ' "$config_file" >/dev/null 2>&1
}

singbox_port_available() {
    local config_file="$1" port="$2" proto="${3:-both}" exclude_tag="${4:-}"
    local proto_label="TCP/UDP"
    [[ "$proto" == "tcp" ]] && proto_label="TCP"
    [[ "$proto" == "udp" ]] && proto_label="UDP"

    if singbox_config_uses_port "$config_file" "$port" "$proto" "$exclude_tag"; then
        echo -e "${RED}${proto_label} 端口 ${port} 已被另一项 Sing-box 入站使用${PLAIN}" >&2
        return 1
    fi
    if zero_port_is_listening "$port" "$proto"; then
        echo -e "${RED}${proto_label} 端口 ${port} 已被系统中的进程占用${PLAIN}" >&2
        return 1
    fi
    return 0
}

singbox_prompt_password() {
    local label="$1" value
    read -r -s -p "${label}(回车随机生成): " value || return 1
    printf '\n' >&2
    [[ -n "$value" ]] || value=$(singbox_random_password) || return 1
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    printf '%s' "$value"
}

singbox_prompt_port() {
    local label="$1" default_port="$2" config_file="$3" proto="${4:-both}" port

    while true; do
        read -r -p "${BLUE}${label}端口(默认:${default_port}): ${PLAIN}" port || return 1
        port=$(trim_input "$port")
        port="${port:-$default_port}"
        if ! zero_is_valid_port "$port"; then
            echo -e "${RED}端口必须在 1-65535 之间${PLAIN}" >&2
            continue
        fi
        if singbox_port_available "$config_file" "$port" "$proto"; then
            printf '%s' "$port"
            return 0
        fi
    done
}

singbox_validate_ws_path() {
    [[ "$1" =~ ^/[^[:space:]]*$ ]]
}

singbox_prompt_ws_path() {
    local default_path="${1:-/}" path

    while true; do
        read -r -p "${BLUE}WebSocket 路径(默认:${default_path}): ${PLAIN}" path || return 1
        path=$(trim_input "$path")
        path="${path:-$default_path}"
        if singbox_validate_ws_path "$path"; then
            printf '%s' "$path"
            return 0
        fi
        echo -e "${RED}路径必须以 / 开头，且不能包含空白字符${PLAIN}" >&2
    done
}

singbox_prompt_shadowsocks() {
    local config_file="$1" port method="2022-blake3-aes-128-gcm" bytes=16 password proto="both"
    local enable_shadowtls shadowtls_password handshake_server handshake_port

    clear
    echo -e "${BLUE}===== Shadowsocks 2022 配置 =====${PLAIN}"
    echo -e "${GREEN}加密方式: ${method}${PLAIN}"

    read -r -p "${BLUE}开启 ShadowTLS v3? [y/N]: ${PLAIN}" enable_shadowtls || return 1
    [[ "$enable_shadowtls" =~ ^[Yy]$ ]] && proto="tcp"

    port=$(singbox_prompt_port "Shadowsocks " 10818 "$config_file" "$proto") || return 1
    while true; do
        read -r -s -p "密码(回车生成符合密钥长度的 Base64 密码): " password || return 1
        echo
        [[ -n "$password" ]] || password=$(singbox_random_ss_password "$bytes")
        singbox_validate_ss_password "$password" "$bytes" && break
        echo -e "${RED}该加密方式要求 Base64 解码后为 ${bytes} 字节${PLAIN}"
    done

    if [[ "$enable_shadowtls" =~ ^[Yy]$ ]]; then
        while true; do
            read -r -p "${BLUE}伪装握手域名: ${PLAIN}" handshake_server || return 1
            handshake_server=$(trim_input "$handshake_server")
            [[ -n "$handshake_server" ]] && break
            echo -e "${RED}伪装握手域名不能为空${PLAIN}"
        done
        while true; do
            read -r -p "${BLUE}伪装握手端口(默认:443): ${PLAIN}" handshake_port || return 1
            handshake_port=$(trim_input "$handshake_port")
            handshake_port="${handshake_port:-443}"
            zero_is_valid_port "$handshake_port" && break
            echo -e "${RED}端口必须在 1-65535 之间${PLAIN}"
        done
        shadowtls_password=$(singbox_prompt_password "ShadowTLS 密码") || return 1

        SINGBOX_NEW_INBOUND=$(jq -n \
            --arg stls_tag "$SINGBOX_SHADOWTLS_TAG" \
            --arg ss_tag "ss-in" \
            --argjson port "$port" \
            --arg stls_password "$shadowtls_password" \
            --arg handshake_server "$handshake_server" \
            --argjson handshake_port "$handshake_port" \
            --arg method "$method" \
            --arg password "$password" \
            '[
                {
                    type:"shadowtls",tag:$stls_tag,listen:"::",listen_port:$port,
                    version:3,users:[{name:"user1",password:$stls_password}],
                    handshake:{server:$handshake_server,server_port:$handshake_port},detour:$ss_tag
                },
                {type:"shadowsocks",tag:$ss_tag,network:"tcp",method:$method,password:$password}
            ]')
        SINGBOX_NEW_SUMMARY="Shadowsocks 端口: ${port}\n加密: ${method}\n密码: ${password}\nShadowTLS: v3 已开启 (仅 TCP)\nShadowTLS 密码: ${shadowtls_password}\n伪装握手域名: ${handshake_server}:${handshake_port}\n客户端 SNI: ${handshake_server}"
    else
        SINGBOX_NEW_INBOUND=$(jq -n \
            --arg tag "ss-in" \
            --argjson port "$port" \
            --arg method "$method" \
            --arg password "$password" \
            '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$password}')
        SINGBOX_NEW_SUMMARY="Shadowsocks 端口: ${port}\n加密: ${method}\n密码: ${password}"
    fi
}

singbox_prompt_snell() {
    local config_file="$1" port psk option mode

    clear
    echo -e "${BLUE}===== Snell v6 配置 (Sing-box 1.14+) =====${PLAIN}"

    port=$(singbox_prompt_port "Snell " 10815 "$config_file" "tcp") || return 1
    while true; do
        psk=$(singbox_prompt_password "PSK") || return 1
        singbox_validate_snell_psk "$psk" && break
        echo -e "${RED}Snell PSK 必须为 12-255 字节${PLAIN}"
    done

    echo -e "${GREEN}1.${PLAIN}default (推荐)"
    echo -e "${GREEN}2.${PLAIN}unshaped"
    echo -e "${RED}3.${PLAIN}unsafe-raw"
    option=$(read_menu_choice "流量整形模式 [1-3,默认1]: ") || return 1
    case "${option:-1}" in
        1) mode="default" ;;
        2) mode="unshaped" ;;
        3) mode="unsafe-raw" ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            return 1
            ;;
    esac
    SINGBOX_NEW_INBOUND=$(jq -n \
        --argjson port "$port" --arg psk "$psk" --arg mode "$mode" \
        '{type:"snell",tag:"snell-in",listen:"::",listen_port:$port,version:6,psk:$psk,mode:$mode}')
    SINGBOX_NEW_SUMMARY="Snell v6 端口: ${port}\nPSK: ${psk}\n整形模式: ${mode}"
}

singbox_prompt_tls_inbound() {
    local type="$1" config_file="$2"
    local tag label default_port proto port password uuid ws_path cert_rc

    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    default_port=$(singbox_default_port_for_type "$type") || return 1
    proto=$(singbox_proto_for_type "$type") || return 1

    clear
    echo -e "${BLUE}===== ${label} 配置 =====${PLAIN}"
    port=$(singbox_prompt_port "${label} " "$default_port" "$config_file" "$proto") || return 1
    if [[ "$type" == "trojan" ]]; then
        ws_path=$(singbox_prompt_ws_path) || return 1
    fi
    password=$(singbox_prompt_password "密码") || return 1

    uuid=""
    if [[ "$type" == "tuic" ]]; then
        while true; do
            read -r -p "${BLUE}UUID(回车随机生成): ${PLAIN}" uuid || return 1
            uuid=$(trim_input "$uuid")
            if [[ -z "$uuid" ]]; then
                uuid=$(zero_random_uuid) || return 1
            fi
            zero_is_valid_uuid "$uuid" && break
            echo -e "${RED}UUID 格式无效${PLAIN}"
        done
    fi

    singbox_select_cert || { cert_rc=$?; return "$cert_rc"; }
    case "$type" in
        anytls)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg password "$password" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
            SINGBOX_NEW_SUMMARY="AnyTLS 端口: ${port}\n密码: ${password}"
            ;;
        trojan)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg password "$password" --arg ws_path "$ws_path" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key},transport:{type:"ws",path:$ws_path}}')
            SINGBOX_NEW_SUMMARY="Trojan + WS + TLS 端口: ${port}\nWebSocket 路径: ${ws_path}\n密码: ${password}"
            ;;
        tuic)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",uuid:$uuid,password:$password}],congestion_control:"bbr",auth_timeout:"3s",zero_rtt_handshake:false,heartbeat:"10s",tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
            SINGBOX_NEW_SUMMARY="TUIC 端口: ${port}\nUUID: ${uuid}\n密码: ${password}"
            ;;
        hysteria2)
            SINGBOX_NEW_INBOUND=$(jq -n \
                --arg tag "$tag" --argjson port "$port" --arg password "$password" \
                --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
                '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,users:[{name:"user1",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
            SINGBOX_NEW_SUMMARY="Hysteria2 端口: ${port}\n密码: ${password}"
            ;;
        *) return 1 ;;
    esac
}

singbox_prompt_inbound() {
    local type="$1" config_file="$2"
    SINGBOX_NEW_INBOUND=""
    SINGBOX_NEW_SUMMARY=""
    case "$type" in
        shadowsocks) singbox_prompt_shadowsocks "$config_file" ;;
        snell) singbox_prompt_snell "$config_file" ;;
        anytls|trojan|tuic|hysteria2) singbox_prompt_tls_inbound "$type" "$config_file" ;;
        *) return 1 ;;
    esac
}

singbox_append_inbound() {
    local config_file="$1" output_file
    output_file=$(mktemp) || return 1
    if ! jq --argjson inbound "$SINGBOX_NEW_INBOUND" \
        '.inbounds += (if ($inbound | type) == "array" then $inbound else [$inbound] end)' \
        "$config_file" > "$output_file"; then
        rm -f "$output_file"
        return 1
    fi
    if ! mv "$output_file" "$config_file"; then
        rm -f "$output_file"
        return 1
    fi
    chmod 600 "$config_file" || return 1
}

singbox_service_healthy() {
    local config_file="${1:-$SINGBOX_CONFIG_PATH}"
    local i pid pr pt sockets all_bound line
    local -a endpoints=()
    mapfile -t endpoints < <(jq -r '
        .inbounds[]? | select(.listen_port != null) |
        (if (.type == "tuic" or .type == "hysteria2" or .type == "hysteria") then "udp"
         elif (.type == "anytls" or .type == "trojan" or .type == "shadowtls" or .type == "snell" or .type == "vmess" or .type == "vless") then "tcp"
         elif (.network == "tcp") then "tcp"
         elif (.network == "udp") then "udp"
         else "both" end) + " " + (.listen_port | tostring)
    ' "$config_file" 2>/dev/null)

    for ((i = 0; i < 15; i++)); do
        systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" 2>/dev/null || return 1
        pid=$(systemctl show -p MainPID --value "$SINGBOX_SERVICE_NAME" 2>/dev/null || true)
        if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! command -v ss >/dev/null 2>&1 || (( ${#endpoints[@]} == 0 )); then
            (( i >= 1 )) && return 0
            sleep 0.2
            continue
        fi
        all_bound=1
        for line in "${endpoints[@]}"; do
            read -r pr pt <<< "$line"
            if [[ "$pr" == "tcp" || "$pr" == "both" ]]; then
                sockets=$(ss -H -lntp "sport = :$pt" 2>/dev/null || true)
                [[ "$sockets" == *"pid=$pid,"* ]] || { all_bound=0; break; }
            fi
            if [[ "$pr" == "udp" || "$pr" == "both" ]]; then
                sockets=$(ss -H -lunp "sport = :$pt" 2>/dev/null || true)
                [[ "$sockets" == *"pid=$pid,"* ]] || { all_bound=0; break; }
            fi
        done
        (( all_bound == 1 )) && return 0
        sleep 0.2
    done
    return 1
}

singbox_create_systemd_service() {
    local temp_file
    temp_file=$(mktemp) || return 1
    cat > "$temp_file" <<EOF || { rm -f "$temp_file"; return 1; }
[Unit]
Description=Sing-box service managed by Zero.sh
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
ExecStart=${SINGBOX_EXEC_PATH} run -c ${SINGBOX_CONFIG_PATH}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    if singbox_atomic_install "$temp_file" "$SINGBOX_SERVICE_FILE" 644; then
        rm -f "$temp_file"
        return 0
    fi
    rm -f "$temp_file"
    return 1
}

singbox_apply_candidate() {
    local candidate="$1" success_msg="$2" failure_msg="${3:-新配置应用失败}"
    local backup was_active=0

    if ! "$SINGBOX_EXEC_PATH" check -c "$candidate"; then
        echo -e "${RED}配置检查失败,未修改当前配置${PLAIN}"
        return 1
    fi

    backup=$(mktemp) || return 1
    chmod 600 "$backup"
    cp "$SINGBOX_CONFIG_PATH" "$backup" || { rm -f "$backup"; return 1; }
    systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" && was_active=1

    if ! singbox_atomic_install "$candidate" "$SINGBOX_CONFIG_PATH" 600; then
        rm -f "$backup"
        echo -e "${RED}配置写入失败${PLAIN}"
        return 1
    fi

    if (( was_active == 0 )); then
        rm -f "$backup"
        echo -e "${GREEN}${success_msg},服务保持停止状态${PLAIN}"
        return 0
    fi

    if systemctl restart "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 && singbox_service_healthy "$SINGBOX_CONFIG_PATH"; then
        rm -f "$backup"
        echo -e "${GREEN}${success_msg}${PLAIN}"
        return 0
    fi

    if singbox_atomic_install "$backup" "$SINGBOX_CONFIG_PATH" 600 &&
       systemctl restart "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 &&
       singbox_service_healthy "$SINGBOX_CONFIG_PATH"; then
        rm -f "$backup"
        echo -e "${YELLOW}${failure_msg},已恢复上一份可用配置${PLAIN}"
        return 1
    fi

    echo -e "${RED}${failure_msg},自动恢复失败;备份保留在 ${backup}${PLAIN}"
    service_failure_hint "$SINGBOX_SERVICE_NAME"
    return 1
}

singbox_apply_and_cleanup() {
    local candidate="$1" success_msg="$2" failure_msg="$3" result
    singbox_apply_candidate "$candidate" "$success_msg" "$failure_msg"
    result=$?
    rm -f "$candidate"
    return "$result"
}

singbox_jq_apply() {
    local success_msg="$1" failure_msg="$2" candidate
    shift 2
    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    if ! jq "$@" "$SINGBOX_CONFIG_PATH" > "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    singbox_apply_and_cleanup "$candidate" "$success_msg" "$failure_msg"
}

singbox_install() {
    local enable_anytls enable_trojan enable_ss enable_tuic enable_hy2 enable_snell="n"
    local candidate summary="" type install_channel channel_choice dns_strategy="prefer_ipv4" prompt_rc=0
    local -a enabled_types=()

    clear
    if singbox_is_managed; then
        echo -e "${YELLOW}Sing-box 已由 Zero.sh 管理,请使用管理或更新功能${PLAIN}"
        pause_enter_and_clear
        return
    fi
    if [[ -e "$SINGBOX_EXEC_PATH" || -e "$SINGBOX_CONFIG_DIR" || -e "$SINGBOX_SERVICE_FILE" ]]; then
        echo -e "${RED}检测到现有 Sing-box 文件,为避免覆盖非本脚本安装的服务已停止${PLAIN}"
        echo -e "${YELLOW}请先备份并移除现有安装,或继续使用原管理方式${PLAIN}"
        pause_enter_and_clear
        return 1
    fi

    singbox_install_dependencies || { pause_enter_and_clear; return 1; }

    clear
    echo -e "${BLUE}选择 Sing-box 内核:${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}正式版"
    echo -e "${GREEN}2.${PLAIN}测试版"
    channel_choice=$(read_menu_choice "请选择 [1-2,默认1]: ") || return 1
    case "${channel_choice:-1}" in
        1) install_channel="release" ;;
        2) install_channel="beta" ;;
        *)
            echo -e "${RED}无效选项,已取消安装${PLAIN}"
            pause_enter_and_clear
            return 1
            ;;
    esac

    if ! singbox_prepare_release "$install_channel" || ! singbox_download_prepared_release; then
        pause_enter_and_clear
        return 1
    fi

    clear
    echo -e "${BLUE}选择要启用的 Sing-box 入站:${PLAIN}"
    read -r -p "启用 AnyTLS?          [y/N]: " enable_anytls &&
    read -r -p "启用 Trojan + WS + TLS?[y/N]: " enable_trojan &&
    read -r -p "启用 Shadowsocks 2022?[y/N]: " enable_ss &&
    read -r -p "启用 TUIC v5?         [y/N]: " enable_tuic &&
    read -r -p "启用 Hysteria2?       [y/N]: " enable_hy2 &&
    read -r -p "启用 Snell v6?        [y/N]: " enable_snell || { singbox_cleanup_stage; return 1; }
    [[ "$enable_anytls" =~ ^[Yy]$ ]] && enabled_types+=(anytls)
    [[ "$enable_trojan" =~ ^[Yy]$ ]] && enabled_types+=(trojan)
    [[ "$enable_ss" =~ ^[Yy]$ ]] && enabled_types+=(shadowsocks)
    [[ "$enable_tuic" =~ ^[Yy]$ ]] && enabled_types+=(tuic)
    [[ "$enable_hy2" =~ ^[Yy]$ ]] && enabled_types+=(hysteria2)
    [[ "$enable_snell" =~ ^[Yy]$ ]] && enabled_types+=(snell)

    if (( ${#enabled_types[@]} == 0 )); then
        echo -e "${YELLOW}至少需要启用一个入站,已取消安装${PLAIN}"
        singbox_cleanup_stage
        pause_enter_and_clear
        return
    fi

    if [[ "$enable_snell" =~ ^[Yy]$ ]] && ! singbox_version_supports_snell "$SINGBOX_STAGE_VERSION"; then
        echo -e "${RED}当前选择的 Sing-box ${SINGBOX_STAGE_VERSION} 不支持 Snell v6 (需 1.14.0+)，请改选测试版或取消 Snell${PLAIN}"
        singbox_cleanup_stage
        pause_enter_and_clear
        return 1
    fi

    [[ "$(dns_detect_stack)" == "ipv6" ]] && dns_strategy="prefer_ipv6"

    candidate=$(mktemp) || { singbox_cleanup_stage; return 1; }
    chmod 600 "$candidate"
    jq -n --arg dns_strategy "$dns_strategy" '{
        log:{level:"info",timestamp:true},
        dns:{
            servers:[{type:"local",tag:"local"}],
            final:"local",
            strategy:$dns_strategy,
            cache_capacity:4096
        },
        inbounds:[],
        outbounds:[{type:"direct",tag:"direct"}],
        route:{final:"direct",default_domain_resolver:"local"}
    }' > "$candidate"

    for type in "${enabled_types[@]}"; do
        prompt_rc=0
        singbox_prompt_inbound "$type" "$candidate" || prompt_rc=$?
        if (( prompt_rc != 0 )) || ! singbox_append_inbound "$candidate"; then
            rm -f "$candidate"
            singbox_cleanup_stage
            if (( prompt_rc == 2 )); then
                echo -e "${YELLOW}已取消证书选择,安装已取消${PLAIN}"
                pause_enter_and_clear
                return 0
            fi
            echo -e "${RED}生成 $(singbox_label_for_type "$type") 配置失败,安装已取消${PLAIN}"
            pause_enter_and_clear
            return 1
        fi
        [[ -n "$summary" ]] && summary+=$'\n\n'
        summary+="$SINGBOX_NEW_SUMMARY"
    done

    if ! "$SINGBOX_STAGE_BIN" check -c "$candidate"; then
        echo -e "${RED}Sing-box 配置检查失败,安装已取消${PLAIN}"
        rm -f "$candidate"
        singbox_cleanup_stage
        pause_enter_and_clear
        return 1
    fi

    install -d -m 700 "$SINGBOX_CONFIG_DIR" || { rm -f "$candidate"; singbox_cleanup_stage; return 1; }
    if ! singbox_atomic_install "$SINGBOX_STAGE_BIN" "$SINGBOX_EXEC_PATH" 755 ||
       ! singbox_atomic_install "$candidate" "$SINGBOX_CONFIG_PATH" 600 ||
       ! singbox_create_systemd_service ||
       ! printf 'managed_by=Zero.sh\n' > "$SINGBOX_MANAGED_MARKER" ||
       ! chmod 600 "$SINGBOX_MANAGED_MARKER"; then
        echo -e "${RED}Sing-box 文件安装失败${PLAIN}"
        rm -f "$candidate" "$SINGBOX_EXEC_PATH" "$SINGBOX_SERVICE_FILE"
        rm -rf "$SINGBOX_CONFIG_DIR"
        singbox_cleanup_stage
        pause_enter_and_clear
        return 1
    fi
    rm -f "$candidate"

    if ! systemctl daemon-reload >/dev/null 2>&1 ||
       ! systemctl enable "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 ||
       ! systemctl start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 ||
       ! singbox_service_healthy "$SINGBOX_CONFIG_PATH"; then
        echo -e "${RED}Sing-box 服务启动失败,已撤销本次安装${PLAIN}"
        systemctl --no-pager --full status "$SINGBOX_SERVICE_NAME" || true
        systemctl disable --now "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SINGBOX_SERVICE_FILE" "$SINGBOX_EXEC_PATH"
        rm -rf "$SINGBOX_CONFIG_DIR"
        systemctl daemon-reload >/dev/null 2>&1 || true
        singbox_cleanup_stage
        pause_enter_and_clear
        return 1
    fi

    echo -e "${GREEN}Sing-box ${SINGBOX_STAGE_VERSION} 安装完成${PLAIN}"
    echo -e "${YELLOW}请确认防火墙已放行所选 TCP/UDP 端口${PLAIN}"
    echo -e "${BLUE}---------------- 随机/当前凭据 ----------------${PLAIN}"
    echo -e "${GREEN}${summary}${PLAIN}"
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    singbox_cleanup_stage
    pause_enter_and_clear
}

singbox_add_inbound() {
    local type="$1" label candidate result=0 prompt_rc=0
    label=$(singbox_label_for_type "$type")
    if [[ "$type" == "snell" ]] && ! singbox_supports_snell; then
        echo -e "${RED}当前 Sing-box 内核不支持 Snell 入站${PLAIN}"
        echo -e "${YELLOW}请先将 Sing-box 内核更新到 1.14.0 或更高版本${PLAIN}"
        return 1
    fi
    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    cp "$SINGBOX_CONFIG_PATH" "$candidate" || { rm -f "$candidate"; return 1; }

    singbox_prompt_inbound "$type" "$candidate" || prompt_rc=$?
    if (( prompt_rc != 0 )) || ! singbox_append_inbound "$candidate"; then
        rm -f "$candidate"
        if (( prompt_rc == 2 )); then
            echo -e "${YELLOW}已取消添加 ${label}${PLAIN}"
            return 0
        fi
        echo -e "${RED}${label} 配置生成失败${PLAIN}"
        return 1
    fi

    if singbox_apply_candidate "$candidate" "${label} 已启用" "${label} 启动失败"; then
        echo -e "${GREEN}${SINGBOX_NEW_SUMMARY}${PLAIN}"
    else
        result=$?
    fi
    rm -f "$candidate"
    return "$result"
}

singbox_modify_port() {
    local type="$1" tag label proto current_port new_port
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    proto=$(singbox_proto_for_type "$type") || return 1
    if [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
        tag="$SINGBOX_SHADOWTLS_TAG"
        proto="tcp"
    fi
    current_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .listen_port' "$SINGBOX_CONFIG_PATH")
    read -r -p "${BLUE}新端口(当前:${current_port}): ${PLAIN}" new_port
    new_port=$(trim_input "$new_port")
    [[ -n "$new_port" ]] || return 0
    if ! zero_is_valid_port "$new_port"; then
        echo -e "${RED}端口无效${PLAIN}"
        return 1
    fi
    [[ "$new_port" == "$current_port" ]] && return 0
    singbox_port_available "$SINGBOX_CONFIG_PATH" "$new_port" "$proto" "$tag" || return 1

    singbox_jq_apply "${label} 端口已更新为 ${new_port}" "${label} 新端口启动失败" \
        --arg tag "$tag" --argjson port "$new_port" \
        '(.inbounds[] | select(.tag == $tag) | .listen_port) = $port'
}

singbox_modify_auth() {
    local type="$1" tag label password psk uuid current_method bytes
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")

    if [[ "$type" == "shadowsocks" ]]; then
        current_method=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .method' "$SINGBOX_CONFIG_PATH")
        case "$current_method" in
            2022-blake3-aes-128-gcm) bytes=16 ;;
            2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) bytes=32 ;;
            *)
                echo -e "${RED}当前 Shadowsocks 加密方式不在本脚本管理范围${PLAIN}"
                return 1
                ;;
        esac
        while true; do
            read -r -s -p "新密码(回车随机生成): " password || return 1
            echo
            [[ -n "$password" ]] || password=$(singbox_random_ss_password "$bytes")
            singbox_validate_ss_password "$password" "$bytes" && break
            echo -e "${RED}密码 Base64 解码后必须为 ${bytes} 字节${PLAIN}"
        done
        singbox_jq_apply "${label} 认证信息已更新" "${label} 新认证信息启动失败" \
            --arg tag "$tag" --arg password "$password" \
            '(.inbounds[] | select(.tag == $tag) | .password) = $password' || return 1
        echo -e "${GREEN}密码: ${password}${PLAIN}"
    elif [[ "$type" == "snell" ]]; then
        while true; do
            psk=$(singbox_prompt_password "新 PSK") || return 1
            singbox_validate_snell_psk "$psk" && break
            echo -e "${RED}Snell PSK 必须为 12-255 字节${PLAIN}"
        done
        singbox_jq_apply "${label} 认证信息已更新" "${label} 新认证信息启动失败" \
            --arg tag "$tag" --arg psk "$psk" \
            '(.inbounds[] | select(.tag == $tag) | .psk) = $psk' || return 1
        echo -e "${GREEN}PSK: ${psk}${PLAIN}"
    elif [[ "$type" == "tuic" ]]; then
        read -r -p "${BLUE}新 UUID(回车保持,R随机): ${PLAIN}" uuid || return 1
        uuid=$(trim_input "$uuid")
        if [[ "$uuid" =~ ^[Rr]$ ]]; then
            uuid=$(zero_random_uuid) || return 1
        elif [[ -z "$uuid" ]]; then
            uuid=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .users[0].uuid' "$SINGBOX_CONFIG_PATH")
        fi
        if ! zero_is_valid_uuid "$uuid"; then
            echo -e "${RED}UUID 无效${PLAIN}"
            return 1
        fi
        password=$(singbox_prompt_password "新密码") || return 1
        singbox_jq_apply "${label} 认证信息已更新" "${label} 新认证信息启动失败" \
            --arg tag "$tag" --arg uuid "$uuid" --arg password "$password" \
            '(.inbounds[] | select(.tag == $tag) | .users[0]) |= (.uuid = $uuid | .password = $password)' || return 1
        echo -e "${GREEN}UUID: ${uuid}${PLAIN}"
        echo -e "${GREEN}密码: ${password}${PLAIN}"
    else
        password=$(singbox_prompt_password "新密码") || return 1
        singbox_jq_apply "${label} 认证信息已更新" "${label} 新认证信息启动失败" \
            --arg tag "$tag" --arg password "$password" \
            '(.inbounds[] | select(.tag == $tag) | .users[0].password) = $password' || return 1
        echo -e "${GREEN}密码: ${password}${PLAIN}"
    fi
}

singbox_modify_cert() {
    local type="$1" tag label cert_rc=0
    singbox_type_uses_tls "$type" || return 1
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    singbox_select_cert || {
        cert_rc=$?
        (( cert_rc == 2 )) && return 0
        return "$cert_rc"
    }
    singbox_jq_apply "${label} 证书已更新" "${label} 新证书启动失败" \
        --arg tag "$tag" --arg cert "$SINGBOX_CERT_PATH" --arg key "$SINGBOX_KEY_PATH" \
        '(.inbounds[] | select(.tag == $tag) | .tls) |= (.enabled = true | .certificate_path = $cert | .key_path = $key)'
}

singbox_modify_trojan_ws_path() {
    local tag="trojan-in" current_path new_path
    current_path=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | (.transport.path // empty)' "$SINGBOX_CONFIG_PATH")
    new_path=$(singbox_prompt_ws_path "${current_path:-/}") || return 1
    [[ "$new_path" == "$current_path" ]] && return 0

    singbox_jq_apply "Trojan WebSocket 路径已更新为 ${new_path}" "Trojan WebSocket 路径更新后启动失败" \
        --arg tag "$tag" --arg path "$new_path" \
        '(.inbounds[] | select(.tag == $tag) | .transport) = {type:"ws",path:$path}'
}

singbox_modify_snell_mode() {
    local tag="snell-in" option mode description

    clear
    echo -e "${BLUE}===== Snell v6 流量整形 =====${PLAIN}"
    echo -e "${GREEN}1.${PLAIN}v6 / default 整形"
    echo -e "${GREEN}2.${PLAIN}v6 / unshaped"
    echo -e "${RED}3.${PLAIN}v6 / unsafe-raw"
    echo -e "${YELLOW}0.${PLAIN}取消"
    option=$(read_menu_choice "请选择 [0-3]: ") || return 1
    case "$option" in
        1) mode="default"; description="v6 / default" ;;
        2) mode="unshaped"; description="v6 / unshaped" ;;
        3) mode="unsafe-raw"; description="v6 / unsafe-raw" ;;
        0) return ;;
        *) echo -e "${RED}无效选项${PLAIN}"; return 1 ;;
    esac

    singbox_jq_apply "Snell 已切换为 ${description}" "Snell 模式切换后启动失败" \
        --arg tag "$tag" --arg mode "$mode" \
        '(.inbounds[] | select(.tag == $tag) | .mode) = $mode'
}

singbox_modify_shadowtls() {
    local tag="$SINGBOX_SHADOWTLS_TAG" password handshake_server handshake_port
    local current_password current_server current_port

    singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH" || return 1
    current_password=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .users[0].password' "$SINGBOX_CONFIG_PATH")
    current_server=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .handshake.server' "$SINGBOX_CONFIG_PATH")
    current_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .handshake.server_port' "$SINGBOX_CONFIG_PATH")

    clear
    echo -e "${BLUE}===== ShadowTLS v3 配置 =====${PLAIN}"
    echo -e "${YELLOW}当前伪装握手: ${current_server}:${current_port}${PLAIN}"
    read -r -s -p "新 ShadowTLS 密码(回车保持): " password
    echo
    password="${password:-$current_password}"
    read -r -p "${BLUE}伪装握手域名(回车保持): ${PLAIN}" handshake_server
    handshake_server=$(trim_input "$handshake_server")
    handshake_server="${handshake_server:-$current_server}"
    read -r -p "${BLUE}伪装握手端口(当前:${current_port}): ${PLAIN}" handshake_port
    handshake_port=$(trim_input "$handshake_port")
    handshake_port="${handshake_port:-$current_port}"
    if ! zero_is_valid_port "$handshake_port"; then
        echo -e "${RED}端口必须在 1-65535 之间${PLAIN}"
        return 1
    fi

    singbox_jq_apply "ShadowTLS v3 配置已更新" "ShadowTLS v3 新配置启动失败" \
        --arg tag "$tag" --arg password "$password" \
        --arg server "$handshake_server" --argjson port "$handshake_port" \
        '(.inbounds[] | select(.tag == $tag)) |= (.users[0].password = $password | .handshake.server = $server | .handshake.server_port = $port)' || return 1
    echo -e "${GREEN}ShadowTLS 密码: ${password}${PLAIN}"
    echo -e "${GREEN}客户端 SNI: ${handshake_server}${PLAIN}"
}

singbox_remove_inbound() {
    local type="$1" tag label count remove_count=1 confirm use_shadowtls=0
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")
    if [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
        use_shadowtls=1
        remove_count=2
    fi
    count=$(jq '.inbounds | length' "$SINGBOX_CONFIG_PATH")
    if (( count <= remove_count )); then
        echo -e "${RED}至少需要保留一个入站,不能删除 ${label}${PLAIN}"
        return 1
    fi
    read -r -p "${RED}确定禁用 ${label}? [y/N]: ${PLAIN}" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    if (( use_shadowtls == 1 )); then
        singbox_jq_apply "${label} 已禁用" "删除 ${label} 后服务启动失败" \
            --arg ss_tag "$tag" --arg stls_tag "$SINGBOX_SHADOWTLS_TAG" \
            '.inbounds |= map(select(.tag != $ss_tag and .tag != $stls_tag))'
    else
        singbox_jq_apply "${label} 已禁用" "删除 ${label} 后服务启动失败" \
            --arg tag "$tag" '.inbounds |= map(select(.tag != $tag))'
    fi
}

singbox_manage_protocol() {
    local type="$1" tag label confirm option
    tag=$(singbox_tag_for_type "$type") || return 1
    label=$(singbox_label_for_type "$type")

    if ! singbox_config_has_tag "$SINGBOX_CONFIG_PATH" "$tag"; then
        if [[ "$type" == "snell" ]] && ! singbox_supports_snell; then
            echo -e "${RED}当前内核不支持 Snell 入站${PLAIN}"
            echo -e "${YELLOW}请先更新到 Sing-box 1.14.0 或更高版本${PLAIN}"
            sleep 2
            return 1
        fi
        read -r -p "${BLUE}${label} 当前未启用,是否添加? [y/N]: ${PLAIN}" confirm || return 1
        [[ "$confirm" =~ ^[Yy]$ ]] && singbox_add_inbound "$type"
        return
    fi

    while true; do
        clear
        echo -e "${BLUE}===== ${label} 管理 =====${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}修改端口"
        echo -e "${GREEN}2.${PLAIN}修改认证"
        if singbox_type_uses_tls "$type"; then
            echo -e "${GREEN}3.${PLAIN}修改证书"
        elif [[ "$type" == "snell" ]]; then
            echo -e "${GREEN}3.${PLAIN}修改 v6 流量整形模式"
        elif [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
            echo -e "${GREEN}3.${PLAIN}修改 ShadowTLS v3"
        fi
        if [[ "$type" == "trojan" ]]; then
            echo -e "${GREEN}4.${PLAIN}修改 WebSocket 路径"
            echo -e "${RED}5.${PLAIN}禁用入站"
        else
            echo -e "${RED}4.${PLAIN}禁用入站"
        fi
        echo -e "${YELLOW}0.${PLAIN}返回上级"
        option=$(read_menu_choice "请输入选项: ") || return 1
        case "$option" in
            1) singbox_modify_port "$type"; sleep 1 ;;
            2) singbox_modify_auth "$type"; sleep 1 ;;
            3)
                if singbox_type_uses_tls "$type"; then
                    singbox_modify_cert "$type"
                elif [[ "$type" == "snell" ]]; then
                    singbox_modify_snell_mode
                elif [[ "$type" == "shadowsocks" ]] && singbox_shadowsocks_uses_shadowtls "$SINGBOX_CONFIG_PATH"; then
                    singbox_modify_shadowtls
                else
                    echo -e "${RED}${label} 没有可修改的证书或模式${PLAIN}"
                fi
                sleep 1
                ;;
            4)
                if [[ "$type" == "trojan" ]]; then
                    singbox_modify_trojan_ws_path
                    sleep 1
                else
                    singbox_remove_inbound "$type"
                    sleep 1
                    return
                fi
                ;;
            5)
                if [[ "$type" == "trojan" ]]; then
                    singbox_remove_inbound "$type"
                    sleep 1
                    return
                fi
                echo -e "${RED}无效选项${PLAIN}"
                sleep 0.5
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_warp_enabled() {
    jq -e --arg tag "$SINGBOX_WARP_TAG" \
        'any(.endpoints[]?; .type == "wireguard" and .tag == $tag)' \
        "$SINGBOX_CONFIG_PATH" >/dev/null 2>&1
}

singbox_load_or_register_warp_account() {
    local net_mode="$1" arch tmp_acc
    local priv="" pub="" v4="" v6="" raw_ep=""

    if [[ -r "$SINGBOX_WARP_ACCOUNT_FILE" ]]; then
        IFS='|' read -r priv pub v4 v6 raw_ep < <(
            jq -r '[(.private_key // ""), (.public_key // ""), (.v4 // ""), (.v6 // ""), (.endpoint // "")] | join("|")' \
                "$SINGBOX_WARP_ACCOUNT_FILE" 2>/dev/null
        ) || true
    fi

    if [[ -z "$priv" || -z "$pub" || -z "$v4" || -z "$v6" ]] && [[ -r "$SINGBOX_CONFIG_PATH" ]]; then
        IFS='|' read -r priv pub v4 v6 raw_ep < <(
            jq -r --arg tag "$SINGBOX_WARP_TAG" '
                ([.endpoints[]? | select(.type == "wireguard" and .tag == $tag)][0] // {}) as $ep |
                (($ep.address // []) | map(sub("/[0-9]+$"; ""))) as $addrs |
                ($addrs | map(select(test("^[0-9.]+$")))[0] // "") as $ip4 |
                ($addrs | map(select(contains(":") and (contains("cf1:1000") | not)))[0] // "") as $ip6 |
                ($ep.peers[0] // {}) as $peer |
                ($peer.address // "") as $pa |
                [
                    ($ep.private_key // ""),
                    ($peer.public_key // ""),
                    $ip4,
                    $ip6,
                    (if $pa == "" then "" elif ($pa | contains(":")) then "[\($pa)]:\($peer.port // 2408)" else "\($pa):\($peer.port // 2408)" end)
                ] | join("|")
            ' "$SINGBOX_CONFIG_PATH" 2>/dev/null
        ) || true
    fi

    if [[ -n "$priv" && -n "$pub" && -n "$v4" && -n "$v6" ]]; then
        WARP_REG_PRIV="$priv"
        WARP_REG_PUB="$pub"
        WARP_REG_V4="$v4"
        WARP_REG_V6="$v6"
        WARP_REG_ENDPOINT="${raw_ep:-engage.cloudflareclient.com:2408}"
        return 0
    fi

    arch=$(singbox_get_arch) || return 1
    echo -e "${BLUE}正在注册本机独立 WARP 免费凭据 (wgcf)...${PLAIN}"
    if ! warp_register_wgcf_free "$arch" "$net_mode"; then
        echo -e "${RED}WARP 免费凭据注册失败${PLAIN}"
        return 1
    fi

    install -d -m 700 "$SINGBOX_CONFIG_DIR" || return 1
    tmp_acc=$(mktemp "${SINGBOX_WARP_ACCOUNT_FILE}.tmp.XXXXXX") || return 1
    if jq -n \
        --arg priv "$WARP_REG_PRIV" --arg pub "$WARP_REG_PUB" \
        --arg v4 "$WARP_REG_V4" --arg v6 "$WARP_REG_V6" --arg ep "$WARP_REG_ENDPOINT" \
        '{private_key:$priv,public_key:$pub,v4:$v4,v6:$v6,endpoint:$ep}' > "$tmp_acc" &&
       chmod 600 "$tmp_acc" &&
       mv -f "$tmp_acc" "$SINGBOX_WARP_ACCOUNT_FILE"; then
        return 0
    fi
    rm -f "$tmp_acc"
    return 1
}

singbox_enable_warp() {
    local net_mode selected_ep ep_host ep_port

    net_mode=$(warp_detect_net_mode)
    if [[ "$net_mode" == "none" ]]; then
        echo -e "${RED}当前服务器无可用网络,无法配置 WARP 分流${PLAIN}"
        return 1
    fi

    singbox_load_or_register_warp_account "$net_mode" || return 1
    selected_ep=$(warp_select_endpoint "$net_mode" "$WARP_REG_ENDPOINT" "" "" "") || {
        echo -e "${RED}无法解析适配当前网络栈 (${net_mode}) 的 WARP Endpoint${PLAIN}"
        return 1
    }
    ep_host=$(warp_endpoint_host "$selected_ep")
    ep_port=$(warp_endpoint_port "$selected_ep")
    [[ -n "$ep_host" && "$ep_port" =~ ^[0-9]+$ ]] || {
        echo -e "${RED}WARP Endpoint 格式异常: ${selected_ep}${PLAIN}"
        return 1
    }

    singbox_jq_apply "WARP 分流已开启 (Endpoint: ${selected_ep})" "WARP 分流启用后服务启动失败" \
        --arg tag "$SINGBOX_WARP_TAG" \
        --arg addr_v4 "${WARP_REG_V4}/32" \
        --arg addr_v6 "${WARP_REG_V6}/128" \
        --arg private_key "$WARP_REG_PRIV" \
        --arg server "$ep_host" \
        --argjson port "$ep_port" \
        --arg public_key "$WARP_REG_PUB" \
        "${SINGBOX_WARP_JQ_DEFS}
        .endpoints = ((.endpoints // []) | map(select(.tag != \$tag))) |
        .endpoints += [{
            type: \"wireguard\", tag: \$tag, system: false, mtu: 1280,
            address: [\$addr_v4, \$addr_v6], private_key: \$private_key,
            peers: [{
                address: \$server, port: \$port, public_key: \$public_key,
                allowed_ips: [\"0.0.0.0/0\", \"::/0\"], persistent_keepalive_interval: 25
            }]
        }] |
        .route = (.route // {}) |
        .route.rules = ([{
            domain_suffix: [\"challenges.cloudflare.com\", \"googlevideo.com\", \"youtube.com\"],
            action: \"route\", outbound: \$tag
        }] + ((.route.rules // []) | map(select((is_warp_rule | not)))))" || {
        echo -e "${RED}WARP 分流配置失败${PLAIN}"
        return 1
    }
}

singbox_disable_warp() {
    singbox_jq_apply "WARP 分流已关闭" "WARP 分流关闭后服务启动失败" \
        --arg tag "$SINGBOX_WARP_TAG" \
        "${SINGBOX_WARP_JQ_DEFS}
        .endpoints = ((.endpoints // []) | map(select(.tag != \$tag))) |
        if (.endpoints | length) == 0 then del(.endpoints) else . end |
        .route = (.route // {}) |
        .route.rules = ((.route.rules // []) | map(select((is_warp_rule | not)))) |
        if (.route.rules | length) == 0 then del(.route.rules) else . end" || {
        echo -e "${RED}WARP 分流关闭失败${PLAIN}"
        return 1
    }
}

singbox_manage_warp() {
    local confirm
    if singbox_warp_enabled; then
        read -r -p "${RED}WARP 分流当前已启用,是否关闭? [y/N]: ${PLAIN}" confirm || return 1
        [[ "$confirm" =~ ^[Yy]$ ]] && singbox_disable_warp
    else
        read -r -p "${BLUE}WARP 分流当前未启用,是否开启? [y/N]: ${PLAIN}" confirm || return 1
        [[ "$confirm" =~ ^[Yy]$ ]] && singbox_enable_warp
    fi
}

singbox_read_config_summary() {
    local config_file="${1:-$SINGBOX_CONFIG_PATH}"
    jq -r --arg stls "$SINGBOX_SHADOWTLS_TAG" --arg warp "$SINGBOX_WARP_TAG" '
        def status($tag):
            ([.inbounds[]? | select(.tag == $tag)][0]) as $inb |
            if $inb == null then "未启用"
            else "已启用:\($inb.listen_port)"
            end;
        def ss_status:
            ([.inbounds[]? | select(.tag == "ss-in")][0]) as $ss |
            if $ss == null then "未启用"
            else
                ([.inbounds[]? | select(.type == "shadowtls" and .tag == $stls and .version == 3 and .detour == "ss-in")][0]) as $st |
                if $st != null then "已启用:\($st.listen_port) (ShadowTLS v3)"
                else "已启用:\($ss.listen_port)"
                end
            end;
        status("anytls-in"),
        status("trojan-in"),
        ss_status,
        status("tuic-in"),
        status("hy2-in"),
        status("snell-in"),
        (if any(.endpoints[]?; .type == "wireguard" and .tag == $warp) then "已启用" else "未启用" end)
    ' "$config_file" 2>/dev/null
}

singbox_modify_config() {
    local option snell_status snell_ok=0
    local -a summary
    singbox_supports_snell && snell_ok=1
    while true; do
        mapfile -t summary < <(singbox_read_config_summary "$SINGBOX_CONFIG_PATH")
        snell_status="${summary[5]:-未启用}"
        [[ "$snell_status" == "未启用" ]] && (( snell_ok == 0 )) && snell_status="需 Sing-box 1.14+"
        clear
        echo -e "${BLUE}===== Sing-box 配置管理 =====${PLAIN}"
        echo -e "${GREEN}1.${PLAIN}AnyTLS          [${YELLOW}${summary[0]:-未启用}${PLAIN}]"
        echo -e "${GREEN}2.${PLAIN}Trojan + WS + TLS [${YELLOW}${summary[1]:-未启用}${PLAIN}]"
        echo -e "${GREEN}3.${PLAIN}Shadowsocks 2022[${YELLOW}${summary[2]:-未启用}${PLAIN}]"
        echo -e "${GREEN}4.${PLAIN}TUIC v5         [${YELLOW}${summary[3]:-未启用}${PLAIN}]"
        echo -e "${GREEN}5.${PLAIN}Hysteria2       [${YELLOW}${summary[4]:-未启用}${PLAIN}]"
        echo -e "${GREEN}6.${PLAIN}Snell v6        [${YELLOW}${snell_status}${PLAIN}]"
        echo -e "${GREEN}7.${PLAIN}WARP 分流       [${YELLOW}${summary[6]:-未启用}${PLAIN}]"
        echo -e "${YELLOW}0.${PLAIN}返回上级"
        option=$(read_menu_choice "请输入选项 [0-7]: ") || return 1
        case "$option" in
            1) singbox_manage_protocol anytls ;;
            2) singbox_manage_protocol trojan ;;
            3) singbox_manage_protocol shadowsocks ;;
            4) singbox_manage_protocol tuic ;;
            5) singbox_manage_protocol hysteria2 ;;
            6) singbox_manage_protocol snell ;;
            7) singbox_manage_warp; sleep 1 ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_manage_service() {
    local option
    while true; do
        clear
        echo -e "${BLUE}✦ SingBox_Menu ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}查看配置"
        echo -e "${GREEN}  2.${PLAIN}修改配置"
        echo -e "${GREEN}  3.${PLAIN}停止服务"
        echo -e "${GREEN}  4.${PLAIN}重启服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        option=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1
        case "$option" in
            1)
                clear
                echo -e "${BLUE}===== Sing-box 当前状态 =====${PLAIN}"
                systemctl --no-pager --full status "$SINGBOX_SERVICE_NAME" || true
                pause_enter "按回车查看配置..."
                clear
                echo -e "${BLUE}===== Sing-box 当前配置 =====${PLAIN}"
                jq . "$SINGBOX_CONFIG_PATH"
                pause_enter_and_clear
                ;;
            2) singbox_modify_config ;;
            3)
                systemctl stop "$SINGBOX_SERVICE_NAME" && echo -e "${GREEN}Sing-box 已停止${PLAIN}" || echo -e "${RED}Sing-box 停止失败${PLAIN}"
                pause_enter_and_clear
                ;;
            4)
                if "$SINGBOX_EXEC_PATH" check -c "$SINGBOX_CONFIG_PATH" &&
                   systemctl restart "$SINGBOX_SERVICE_NAME" &&
                   singbox_service_healthy "$SINGBOX_CONFIG_PATH"; then
                    echo -e "${GREEN}Sing-box 已重启${PLAIN}"
                else
                    echo -e "${RED}Sing-box 重启失败${PLAIN}"
                    service_failure_hint "$SINGBOX_SERVICE_NAME"
                fi
                pause_enter_and_clear
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_update_channel() {
    local channel="$1" channel_label current_version confirm backup was_active=0

    clear
    if ! singbox_is_managed || ! singbox_is_installed; then
        echo -e "${RED}未检测到由 Zero.sh 管理的 Sing-box${PLAIN}"
        pause_enter_and_clear
        return 1
    fi
    singbox_install_dependencies || { pause_enter_and_clear; return 1; }

    [[ "$channel" == "release" ]] && channel_label="正式版" || channel_label="测试版"
    current_version=$(singbox_get_current_version)
    if [[ -z "$current_version" || "$current_version" == "未知" ]]; then
        echo -e "${RED}无法读取当前 Sing-box 版本,已取消更新${PLAIN}"
        pause_enter_and_clear
        return 1
    fi

    echo -e "${BLUE}正在检查 Sing-box ${channel_label}版本...${PLAIN}"
    singbox_prepare_release "$channel" || { pause_enter_and_clear; return 1; }

    echo -e "${BLUE}当前版本: ${YELLOW}${current_version}${PLAIN}"
    echo -e "${BLUE}最新版本: ${YELLOW}${SINGBOX_STAGE_VERSION}${PLAIN}"
    if ! singbox_version_is_newer "$SINGBOX_STAGE_VERSION" "$current_version"; then
        echo -e "${GREEN}当前已是最新版本,无需更新${PLAIN}"
        singbox_cleanup_stage
        pause_enter_and_clear
        return
    fi

    read -r -p "${BLUE}发现新版本,是否更新到 Sing-box ${SINGBOX_STAGE_VERSION}? [y/N]: ${PLAIN}" confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        singbox_cleanup_stage
        return
    fi

    singbox_download_prepared_release || { pause_enter_and_clear; return 1; }

    if ! "$SINGBOX_STAGE_BIN" check -c "$SINGBOX_CONFIG_PATH"; then
        echo -e "${RED}当前配置与新版本不兼容,已取消更新${PLAIN}"
        singbox_cleanup_stage
        pause_enter_and_clear
        return 1
    fi

    backup=$(mktemp) || { singbox_cleanup_stage; return 1; }
    cp "$SINGBOX_EXEC_PATH" "$backup" || { rm -f "$backup"; singbox_cleanup_stage; return 1; }
    systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" && was_active=1
    if (( was_active == 1 )) && ! systemctl stop "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
        rm -f "$backup"
        singbox_cleanup_stage
        echo -e "${RED}无法停止当前 Sing-box 服务,已取消更新${PLAIN}"
        pause_enter_and_clear
        return 1
    fi

    if ! singbox_atomic_install "$SINGBOX_STAGE_BIN" "$SINGBOX_EXEC_PATH" 755; then
        singbox_cleanup_stage
        if (( was_active == 0 )) || systemctl start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            rm -f "$backup"
            echo -e "${RED}Sing-box 更新失败,旧版本未被替换${PLAIN}"
        else
            echo -e "${RED}Sing-box 更新失败且旧服务恢复失败;备份保留在 ${backup}${PLAIN}"
            service_failure_hint "$SINGBOX_SERVICE_NAME"
        fi
        pause_enter_and_clear
        return 1
    fi

    if (( was_active == 0 )) || ( systemctl start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 && singbox_service_healthy "$SINGBOX_CONFIG_PATH" ); then
        rm -f "$backup"
        echo -e "${GREEN}Sing-box 已更新到 ${SINGBOX_STAGE_VERSION}${PLAIN}"
    else
        if systemctl stop "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 &&
           singbox_atomic_install "$backup" "$SINGBOX_EXEC_PATH" 755 &&
           systemctl start "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 &&
           singbox_service_healthy "$SINGBOX_CONFIG_PATH"; then
            rm -f "$backup"
            echo -e "${YELLOW}新版本启动失败,已恢复旧版本${PLAIN}"
        else
            echo -e "${RED}新版本启动失败且自动恢复失败;备份保留在 ${backup}${PLAIN}"
            service_failure_hint "$SINGBOX_SERVICE_NAME"
        fi
        singbox_cleanup_stage
        pause_enter_and_clear
        return 1
    fi
    singbox_cleanup_stage
    pause_enter_and_clear
}

singbox_update() {
    local option
    while true; do
        clear
        echo -e "${BLUE}✦ SingBox_Update ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}更新正式版"
        echo -e "${GREEN}  2.${PLAIN}更新测试版"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
        option=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1
        case "$option" in
            1) singbox_update_channel release ;;
            2) singbox_update_channel beta ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

singbox_delete() {
    local confirm
    clear
    if ! singbox_is_managed; then
        echo -e "${YELLOW}没有检测到由 Zero.sh 管理的 Sing-box${PLAIN}"
        pause_enter_and_clear
        return
    fi
    read -r -p "${RED}确定删除 Sing-box、配置和服务? [y/N]: ${PLAIN}" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet "$SINGBOX_SERVICE_NAME" &&
           ! systemctl stop "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            echo -e "${RED}Sing-box 服务停止失败,已取消删除${PLAIN}"
            pause_enter_and_clear
            return 1
        fi
        if ! systemctl disable "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1; then
            echo -e "${RED}Sing-box 服务禁用失败,已取消删除${PLAIN}"
            pause_enter_and_clear
            return 1
        fi
        if ! rm -f "$SINGBOX_SERVICE_FILE" "$SINGBOX_EXEC_PATH" ||
           ! rm -rf "$SINGBOX_CONFIG_DIR" ||
           ! systemctl daemon-reload >/dev/null 2>&1; then
            echo -e "${RED}Sing-box 删除不完整,请检查残留文件${PLAIN}"
            pause_enter_and_clear
            return 1
        fi
        systemctl reset-failed "$SINGBOX_SERVICE_NAME" >/dev/null 2>&1 || true
        echo -e "${GREEN}Sing-box 已删除${PLAIN}"
    fi
    pause_enter_and_clear
}

singbox_menu() {
    local option

    while true; do
        clear
        echo -e "${BLUE}✦ SingBox_Ver.1.2 ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}安装服务"
        echo -e "${GREEN}  2.${PLAIN}管理服务"
        echo -e "${GREEN}  3.${PLAIN}更新内核"
        echo -e "${GREEN}  4.${PLAIN}删除服务"
        echo -e "${GREEN}  0.${PLAIN}返回主页"
        option=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1
        case "$option" in
            1) singbox_install ;;
            2)
                if ! singbox_is_managed || ! singbox_is_installed; then
                    echo -e "${RED}未安装由 Zero.sh 管理的 Sing-box${PLAIN}"
                    pause_enter_and_clear
                else
                    singbox_manage_service
                fi
                ;;
            3) singbox_update ;;
            4) singbox_delete ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 0.5 ;;
        esac
    done
}

# ============================ WireProxy ============================

WIREPROXY_BIN="/usr/local/bin/wireproxy"
WIREPROXY_CONF_DIR="/etc/wireproxy"
WIREPROXY_CONF="/etc/wireproxy/wireproxy.conf"
WIREPROXY_WG_WARP_CONF="/etc/wireproxy/wgcf-warp.conf"
WIREPROXY_SERVICE_NAME="wireproxy-warp"
WIREPROXY_SERVICE_FILE="/etc/systemd/system/${WIREPROXY_SERVICE_NAME}.service"

WIREPROXY_REPO="windtf/wireproxy"
WIREPROXY_MIRROR_URL="https://cdn-wireproxy.pages.dev/windtf/wireproxy"

WIREPROXY_ARCH=""
WIREPROXY_NET_MODE=""

WIREPROXY_DEFAULT_SOCKS_BIND="127.0.0.1:40000"
WIREPROXY_SOCKS_BIND="$WIREPROXY_DEFAULT_SOCKS_BIND"
WIREPROXY_SOCKS_USER=""
WIREPROXY_SOCKS_PASS=""

wireproxy_check_dependencies() {
    local cmd
    command -v apt-get >/dev/null 2>&1 || warp_err "仅支持 Debian/Ubuntu（未找到 apt-get）"
    for cmd in curl tar systemctl sha256sum; do
        command -v "$cmd" >/dev/null 2>&1 || warp_err "缺少依赖: $cmd"
    done
}

wireproxy_ensure_wireguard_tools() {
    command -v wg >/dev/null 2>&1 && return 0
    warp_info "安装 wireguard-tools ..."
    ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends wireguard-tools ) || warp_err "wireguard-tools 安装失败"
    command -v wg >/dev/null 2>&1 || warp_err "wireguard-tools 安装后仍未检测到 wg 命令"
}

wireproxy_installed_version() {
    [[ -x "$WIREPROXY_BIN" ]] || return 1
    "$WIREPROXY_BIN" --version 2>/dev/null \
        | grep -oE 'v?[0-9]+(\.[0-9]+){1,3}' \
        | head -n1 \
        | sed 's/^v//'
}

wireproxy_download_binary() {
    local version current_version asset tmpdir bin_path

    WIREPROXY_ARCH=$(zero_get_arch) || warp_err "不支持的架构: $(uname -m)"
    WIREPROXY_NET_MODE="$(warp_detect_net_mode)"
    warp_info "获取 wireproxy 最新版本 ..."
    version="$(warp_release_latest_tag "$WIREPROXY_REPO" "$WIREPROXY_MIRROR_URL" "$WIREPROXY_NET_MODE" || true)"
    if [[ -z "$version" ]]; then
        [[ -x "$WIREPROXY_BIN" ]] && { warp_warn "无法检查最新版本，继续使用现有 wireproxy"; return 0; }
        warp_err "无法获取 wireproxy 最新版本"
    fi

    current_version="$(wireproxy_installed_version || true)"
    if [[ -n "$current_version" && "v${current_version}" == "$version" ]]; then
        warp_ok "wireproxy ${version} 已是最新版本"
        return 0
    fi

    asset="wireproxy_linux_${WIREPROXY_ARCH}.tar.gz"
    tmpdir="$(mktemp -d)" || warp_err "创建临时目录失败"

    if [[ -n "$current_version" ]]; then
        warp_info "更新 wireproxy v${current_version} -> ${version} ..."
    else
        warp_info "下载 wireproxy ${version} ..."
    fi
    if ! warp_download_verified_asset "$WIREPROXY_REPO" "$WIREPROXY_MIRROR_URL" "$version" "$asset" \
        "${tmpdir}/wireproxy.tar.gz" "$WIREPROXY_NET_MODE"; then
        rm -rf "$tmpdir"
        warp_err "wireproxy 下载或 SHA256 校验失败"
    fi
    warp_ok "wireproxy SHA256 校验通过"

    tar -xzf "${tmpdir}/wireproxy.tar.gz" -C "$tmpdir" || {
        rm -rf "$tmpdir"
        warp_err "wireproxy 解压失败"
    }

    bin_path="$(find "$tmpdir" -type f -name wireproxy | head -n1)"
    [[ -n "$bin_path" ]] || {
        rm -rf "$tmpdir"
        warp_err "压缩包中未找到 wireproxy 可执行文件"
    }

    if ! install -d -m 755 "${WIREPROXY_BIN%/*}" || ! install -m 755 "$bin_path" "$WIREPROXY_BIN"; then
        rm -rf "$tmpdir"
        warp_err "安装 wireproxy 可执行文件失败"
    fi
    rm -rf "$tmpdir"
    warp_ok "wireproxy ${version} 已安装到 ${WIREPROXY_BIN}"
}

wireproxy_is_valid_host_port() {
    local value="$1"
    if [[ "$value" =~ ^\*:([0-9]{1,5})$ ]]; then
        zero_is_valid_port "${BASH_REMATCH[1]}"
        return
    fi
    warp_is_valid_endpoint "$value"
}

wireproxy_is_local_bind() {
    [[ "$1" =~ ^127\.([0-9]{1,3}\.){2}[0-9]{1,3}:[0-9]{1,5}$ ||
       "$1" =~ ^localhost:[0-9]{1,5}$ ||
       "$1" =~ ^\[::1\]:[0-9]{1,5}$ ]]
}

wireproxy_socks_connect_addr() {
    local bind="${1-$WIREPROXY_SOCKS_BIND}" host port
    port="$(warp_endpoint_port "$bind")"
    host="$(warp_endpoint_host "$bind")"
    [[ -n "$port" ]] || return 1
    case "$host" in
        0.0.0.0|\*|"")
            printf '127.0.0.1:%s\n' "$port"
            ;;
        "::"|"0:0:0:0:0:0:0:0")
            if [[ "$(cat /proc/sys/net/ipv6/conf/lo/disable_ipv6 2>/dev/null)" == "1" ]]; then
                printf '127.0.0.1:%s\n' "$port"
            else
                printf '[::1]:%s\n' "$port"
            fi
            ;;
        *:*) printf '[%s]:%s\n' "$host" "$port" ;;
        *)   printf '%s:%s\n' "$host" "$port" ;;
    esac
}

wireproxy_extract_ini_value() {
    local file="$1" section="${2:-}" key="$3"
    awk -v section="$section" -v key="$key" '
        BEGIN { in_section = (section == "") }
        /^\[/ { in_section = (section == "" || $0 ~ "^\\[" section "\\][[:space:]]*$"); next }
        in_section {
            line = $0; sub(/^[[:space:]]+/, "", line)
            if (line ~ ("^" key "[[:space:]]*=")) {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                sub(/[[:space:]]+$/, "", line)
                print line; exit
            }
        }
    ' "$file"
}

wireproxy_load_socks_settings() {
    WIREPROXY_SOCKS_BIND="$WIREPROXY_DEFAULT_SOCKS_BIND"
    WIREPROXY_SOCKS_USER=""
    WIREPROXY_SOCKS_PASS=""
    [[ -f "$WIREPROXY_CONF" ]] || return 0

    local bind user pass
    bind="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "BindAddress")"
    user="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "Username")"
    pass="$(wireproxy_extract_ini_value "$WIREPROXY_CONF" "Socks5" "Password")"

    [[ -n "$bind" ]] && WIREPROXY_SOCKS_BIND="$bind"
    [[ -n "$user" ]] && WIREPROXY_SOCKS_USER="$user"
    [[ -n "$pass" ]] && WIREPROXY_SOCKS_PASS="$pass"
}

wireproxy_prompt_socks_settings() {
    local input current_pass confirm

    wireproxy_load_socks_settings
    current_pass="$WIREPROXY_SOCKS_PASS"

    while true; do
        read -rp "SOCKS 监听地址(默认:${WIREPROXY_SOCKS_BIND}): " input || return 1
        input="${input:-$WIREPROXY_SOCKS_BIND}"
        if wireproxy_is_valid_host_port "$input"; then
            WIREPROXY_SOCKS_BIND="$input"
            break
        fi
        warp_warn "监听地址格式无效，请使用 127.0.0.1:40000 或 [::]:40000"
    done

    read -rp "SOCKS 用户名(留空为无认证，当前:${WIREPROXY_SOCKS_USER:-无}): " input || return 1
    if [[ -n "$input" ]]; then
        WIREPROXY_SOCKS_USER="$input"
        read -rsp "SOCKS 密码(留空保持当前，输入 - 清空): " input || return 1
        echo ""
        if [[ "$input" == "-" ]]; then
            WIREPROXY_SOCKS_PASS=""
        elif [[ -n "$input" ]]; then
            WIREPROXY_SOCKS_PASS="$input"
        else
            WIREPROXY_SOCKS_PASS="$current_pass"
        fi

        if [[ -z "$WIREPROXY_SOCKS_PASS" ]]; then
            warp_warn "设置用户名时密码不能为空"
            return 1
        fi
        if [[ "$WIREPROXY_SOCKS_USER" =~ [[:space:]] || "$WIREPROXY_SOCKS_PASS" =~ [[:space:]] ]]; then
            warp_warn "SOCKS 用户名和密码不能包含空白字符"
            return 1
        fi
    else
        WIREPROXY_SOCKS_USER=""
        WIREPROXY_SOCKS_PASS=""
    fi

    if ! wireproxy_is_local_bind "$WIREPROXY_SOCKS_BIND" && [[ -z "$WIREPROXY_SOCKS_USER" ]]; then
        warp_warn "当前监听地址可能暴露到公网，且未设置 SOCKS 认证"
        read -rp "确认继续 [y/N]: " confirm || return 1
        [[ "$confirm" =~ ^[Yy]$ ]] || { warp_warn "已取消"; return 1; }
    fi
}

wireproxy_write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5"

    mkdir -p "$WIREPROXY_CONF_DIR" || return 1
    cat > "$WIREPROXY_WG_WARP_CONF" <<EOF || return 1
[Interface]
PrivateKey = ${priv}
Address = ${v4}/32, ${v6}/128
DNS = 2606:4700:4700::1111
MTU = 1280

[Peer]
PublicKey = ${pub}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}
PersistentKeepalive = 25
EOF
    chmod 600 "$WIREPROXY_WG_WARP_CONF" || return 1
    warp_ok "WireGuard 配置已写入 ${WIREPROXY_WG_WARP_CONF}"
}

wireproxy_write_conf() {
    mkdir -p "$WIREPROXY_CONF_DIR" || return 1
    cat > "$WIREPROXY_CONF" <<EOF || return 1
WGConfig = ${WIREPROXY_WG_WARP_CONF}

[Socks5]
BindAddress = ${WIREPROXY_SOCKS_BIND}
EOF
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        cat >> "$WIREPROXY_CONF" <<EOF || return 1
Username = ${WIREPROXY_SOCKS_USER}
Password = ${WIREPROXY_SOCKS_PASS}
EOF
    fi
    chmod 600 "$WIREPROXY_CONF" || return 1
    warp_ok "wireproxy 配置已写入 ${WIREPROXY_CONF}"
}

wireproxy_create_service() {
    cat > "$WIREPROXY_SERVICE_FILE" <<EOF || return 1
[Unit]
Description=WARP SOCKS proxy via wireproxy
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WIREPROXY_BIN} -c ${WIREPROXY_CONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$WIREPROXY_SERVICE_FILE" || return 1
}

wireproxy_wait_service_ready() {
    local i pid sock_port sockets
    wireproxy_load_socks_settings
    sock_port="$(warp_endpoint_port "$WIREPROXY_SOCKS_BIND")"

    for ((i = 0; i < 15; i++)); do
        systemctl is-active --quiet "$WIREPROXY_SERVICE_NAME" 2>/dev/null || return 1
        pid="$(systemctl show -p MainPID --value "$WIREPROXY_SERVICE_NAME" 2>/dev/null || true)"
        if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! command -v ss >/dev/null 2>&1 || [[ -z "$sock_port" ]]; then
            (( i >= 1 )) && return 0
            sleep 0.2
            continue
        fi
        sockets="$(ss -H -lntp "sport = :$sock_port" 2>/dev/null || true)"
        [[ "$sockets" == *"pid=$pid,"* ]] && return 0
        sleep 0.2
    done
    return 1
}

wireproxy_try_restart_service() {
    local quiet="${1:-0}" validation_log

    validation_log="$(mktemp)" || {
        (( quiet == 0 )) && warp_warn "无法创建配置校验日志"
        return 1
    }

    if ! "$WIREPROXY_BIN" -c "$WIREPROXY_CONF" -n >"$validation_log" 2>&1; then
        if (( quiet == 0 )); then
            warp_warn "配置校验失败"
            cat "$validation_log"
        fi
        rm -f "$validation_log"
        return 1
    fi
    rm -f "$validation_log"

    wireproxy_create_service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || warp_warn "设置开机自启失败"

    if systemctl restart "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 && wireproxy_wait_service_ready; then
        return 0
    fi

    (( quiet == 0 )) && service_failure_hint "$WIREPROXY_SERVICE_NAME"
    return 1
}

wireproxy_restart_service() {
    wireproxy_try_restart_service && warp_ok "${WIREPROXY_SERVICE_NAME} 已启动" || warp_err "${WIREPROXY_SERVICE_NAME} 启动失败"
}

wireproxy_restart_service_with_backup() {
    local backup="$1" target="$2"

    if wireproxy_try_restart_service 1; then
        rm -f "$backup"
        warp_ok "${WIREPROXY_SERVICE_NAME} 已启动"
        return 0
    fi

    cp "$backup" "$target" || {
        warp_warn "无法恢复原配置；备份保留在 $backup"
        return 1
    }
    rm -f "$backup"

    if wireproxy_try_restart_service 1; then
        warp_warn "新配置启动失败，已回滚到上一份可用配置"
    else
        warp_warn "新配置启动失败，回滚后服务仍未启动"
        service_failure_hint "$WIREPROXY_SERVICE_NAME"
    fi
    return 1
}

wireproxy_prepare_install() {
    local account_type="$1"
    if [[ "$account_type" == team ]] && ! command -v jq >/dev/null 2>&1; then
        pkg_install jq || warp_err "jq 安装失败"
    fi
    wireproxy_check_dependencies
    wireproxy_prompt_socks_settings || return 1
    wireproxy_download_binary
    [[ "$account_type" == "team" ]] && wireproxy_ensure_wireguard_tools
    return 0
}

wireproxy_finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" endpoint="$5"
    warp_info "Endpoint: $endpoint"
    wireproxy_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$endpoint" || warp_err "写入 WireGuard 配置失败"
    wireproxy_write_conf || warp_err "写入 SOCKS 配置失败"
    wireproxy_restart_service
}

wireproxy_service_running() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$WIREPROXY_SERVICE_NAME"
}

wireproxy_show_proxy_status() {
    wireproxy_load_socks_settings
    echo -e "  SOCKS: ${CYAN}${WIREPROXY_SOCKS_BIND}${NC}"
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        echo -e "  认证: ${GREEN}${WIREPROXY_SOCKS_USER}${NC}"
    else
        echo -e "  认证: ${YELLOW}无${NC}"
    fi
    if wireproxy_service_running; then
        echo -e "  WARP: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP: ${YELLOW}未运行${NC}"
    fi
}

wireproxy_fetch_trace_via_proxy() {
    local host="$1" connect_addr proxy_url scheme trace=""
    local curl_args=()

    connect_addr="$(wireproxy_socks_connect_addr "$WIREPROXY_SOCKS_BIND")" || return 1
    proxy_url="socks5h://${connect_addr}"
    curl_args=(-g -fsS --proxy "$proxy_url" --connect-timeout 4 --max-time 8)
    [[ -n "$WIREPROXY_SOCKS_USER" ]] && curl_args+=(--proxy-user "${WIREPROXY_SOCKS_USER}:${WIREPROXY_SOCKS_PASS}")

    for scheme in https http; do
        trace="$(curl "${curl_args[@]}" "${scheme}://${host}/cdn-cgi/trace" 2>/dev/null || true)"
        if [[ -n "$trace" && "$trace" == *"warp="* ]]; then
            printf '%s\n' "$trace"
            return 0
        fi
    done
    return 1
}

wireproxy_show_proxy_trace() {
    local v4_trace="" v6_trace="" ip4="" ip6="" warp_status="" tmpdir attempt
    wireproxy_load_socks_settings
    [[ -f "$WIREPROXY_CONF" ]] || { warp_warn "未找到配置文件"; return; }

    tmpdir="$(mktemp -d /tmp/zero-wp-trace.XXXXXX)" || return 1
    for ((attempt = 1; attempt <= 4; attempt++)); do
        [[ -z "$v4_trace" ]] && ( wireproxy_fetch_trace_via_proxy "1.1.1.1" > "$tmpdir/v4" 2>/dev/null || true ) &
        [[ -z "$v6_trace" ]] && ( wireproxy_fetch_trace_via_proxy "[2606:4700:4700::1111]" > "$tmpdir/v6" 2>/dev/null || true ) &
        wait
        [[ -z "$v4_trace" && -s "$tmpdir/v4" ]] && v4_trace="$(<"$tmpdir/v4")"
        [[ -z "$v6_trace" && -s "$tmpdir/v6" ]] && v6_trace="$(<"$tmpdir/v6")"
        [[ -n "$v4_trace" && -n "$v6_trace" ]] && break
        (( attempt < 4 )) && sleep 0.6
    done
    rm -rf "$tmpdir"

    [[ -n "$v4_trace" ]] && ip4="$(warp_trace_value "$v4_trace" "ip")"
    [[ -n "$v6_trace" ]] && ip6="$(warp_trace_value "$v6_trace" "ip")"
    echo -e "  IPv4: ${GREEN}${ip4:-无}${NC}"
    echo -e "  IPv6: ${CYAN}${ip6:-无}${NC}"
    if [[ -n "$v4_trace" || -n "$v6_trace" ]]; then
        warp_status="$(warp_merge_warp_status "$v4_trace" "$v6_trace")"
        echo -e "  Warp: ${YELLOW}${warp_status}${NC}"
    else
        warp_warn "无法通过 SOCKS 代理获取 WARP 出口信息，可稍等几秒后再试一次"
    fi
    echo ""
}

wireproxy_install_free() {
    local endpoint

    echo ""
    warp_info "免费账户 SOCKS 安装"
    echo ""

    wireproxy_prepare_install free || return 1
    warp_info "注册 WARP 免费账户 (wgcf) ..."
    warp_register_wgcf_free "$WIREPROXY_ARCH" "$WIREPROXY_NET_MODE" || warp_err "WARP 免费账户注册或配置提取失败"
    warp_ok "wgcf 校验与免费账户注册成功"

    [[ -n "$WIREPROXY_NET_MODE" ]] || WIREPROXY_NET_MODE="$(warp_detect_net_mode)"
    endpoint="$(warp_require_endpoint "$WIREPROXY_NET_MODE" "$WARP_REG_ENDPOINT" "" "" "")" || return 1
    wireproxy_finish_install "$WARP_REG_PRIV" "$WARP_REG_V4" "$WARP_REG_V6" "$WARP_REG_PUB" "$endpoint"

    echo ""
    warp_ok "WARP SOCKS 配置完成"
    echo -e "  SOCKS: ${GREEN}${WIREPROXY_SOCKS_BIND}${NC}"
    wireproxy_show_proxy_trace
}

wireproxy_install_team() {
    local endpoint

    echo ""
    warp_info "团队账户 SOCKS 安装"
    echo ""

    wireproxy_prepare_install team || return 1
    warp_prompt_and_register_team || { [[ $? -eq 2 ]] && return 0 || return 1; }

    [[ -n "$WIREPROXY_NET_MODE" ]] || WIREPROXY_NET_MODE="$(warp_detect_net_mode)"
    endpoint="$(warp_require_endpoint "$WIREPROXY_NET_MODE" "$WARP_REG_ENDPOINT" "$WARP_REG_EP_V4" "$WARP_REG_EP_V6" "$WARP_REG_EP_PORT")" || return 1
    wireproxy_finish_install "$WARP_REG_PRIV" "$WARP_REG_V4" "$WARP_REG_V6" "$WARP_REG_PUB" "$endpoint"

    echo ""
    warp_ok "团队 WARP SOCKS 配置完成"
    echo -e "  组织: ${CYAN}${WARP_REG_ORG:-unknown}${NC}"
    echo -e "  SOCKS: ${GREEN}${WIREPROXY_SOCKS_BIND}${NC}"
    wireproxy_show_proxy_trace
}

wireproxy_modify_config() {
    local current_endpoint current_mtu new_ep new_bind new_mtu input confirm backup_file
    local auth_label="无" auth_color="$YELLOW" service_label="未运行" service_color="$YELLOW"

    clear
    [[ -f "$WIREPROXY_CONF" && -f "$WIREPROXY_WG_WARP_CONF" ]] || { warp_warn "未找到配置，请先安装"; return; }

    wireproxy_load_socks_settings
    current_endpoint="$(wireproxy_extract_ini_value "$WIREPROXY_WG_WARP_CONF" "Peer" "Endpoint")"
    current_mtu="$(wireproxy_extract_ini_value "$WIREPROXY_WG_WARP_CONF" "Interface" "MTU")"
    [[ -z "$current_mtu" ]] && current_mtu="1280"
    if [[ -n "$WIREPROXY_SOCKS_USER" ]]; then
        auth_label="$WIREPROXY_SOCKS_USER"
        auth_color="$GREEN"
    fi
    if wireproxy_service_running; then
        service_label="运行中"
        service_color="$GREEN"
    fi

    warp_divider
    echo -e "  ${CYAN}WARP:${NC} ${service_color}${service_label}${NC}"
    echo -e "  ${CYAN}Endpoint:${NC} ${current_endpoint}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}  ${CYAN}SOCKS:${NC} ${WIREPROXY_SOCKS_BIND}"
    echo -e "  ${CYAN}认证:${NC} ${auth_color}${auth_label}${NC}"
    warp_divider
    echo -e "  ${GREEN}1)${NC} 改Endpoint     ${CYAN}2)${NC} 改MTU"
    echo -e "  ${YELLOW}3)${NC} 改SOCKS监听    ${GREEN}4)${NC} 改SOCKS认证"
    echo -e "  ${CYAN}5)${NC} 编辑WARP配置 ${RED}  0)${NC} 返回上级"
    echo
    input=$(read_menu_choice "  请选择 [0-5]: ") || return 1

    case "$input" in
        1)
            echo -e "\n  当前 Endpoint: ${current_endpoint}\n"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                wireproxy_is_valid_host_port "$new_ep" || { warp_warn "Endpoint 格式无效"; return; }
                backup_file="$(warp_make_backup "$WIREPROXY_WG_WARP_CONF")" || return 1
                warp_update_conf_key "$WIREPROXY_WG_WARP_CONF" "Peer" "Endpoint" "$new_ep" || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
                warp_ok "Endpoint 已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            fi
            ;;
        2)
            echo -e "\n  当前 MTU: ${current_mtu}\n"
            read -rp "新 MTU [1280-1500]: " new_mtu
            if [[ "$new_mtu" =~ ^[0-9]+$ ]] && (( new_mtu >= 1280 && new_mtu <= 1500 )); then
                backup_file="$(warp_make_backup "$WIREPROXY_WG_WARP_CONF")" || return 1
                warp_update_conf_key "$WIREPROXY_WG_WARP_CONF" "Interface" "MTU" "$new_mtu" || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
                warp_ok "MTU 已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            else
                warp_warn "无效的 MTU 值"
            fi
            ;;
        3)
            echo -e "\n  当前 SOCKS 监听: ${WIREPROXY_SOCKS_BIND}\n"
            read -rp "新 SOCKS 监听地址: " new_bind
            if [[ -n "$new_bind" ]]; then
                wireproxy_is_valid_host_port "$new_bind" || { warp_warn "监听地址格式无效"; return; }
                if ! wireproxy_is_local_bind "$new_bind" && [[ -z "$WIREPROXY_SOCKS_USER" ]]; then
                    warp_warn "该地址可能将未认证的 SOCKS 代理暴露到公网"
                    read -rp "确认继续 [y/N]: " confirm
                    [[ "$confirm" =~ ^[Yy]$ ]] || { warp_warn "已取消"; return; }
                fi
                backup_file="$(warp_make_backup "$WIREPROXY_CONF")" || return 1
                warp_update_conf_key "$WIREPROXY_CONF" "Socks5" "BindAddress" "$new_bind" || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
                warp_ok "SOCKS 监听地址已更新"
                wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            fi
            ;;
        4)
            echo -e "\n  当前认证: ${auth_label}\n"
            backup_file="$(warp_make_backup "$WIREPROXY_CONF")" || return 1
            if ! wireproxy_prompt_socks_settings; then
                rm -f "$backup_file"
                return
            fi
            wireproxy_write_conf || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
            wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_CONF"
            ;;
        5)
            backup_file="$(warp_make_backup "$WIREPROXY_WG_WARP_CONF")" || return 1
            ${EDITOR:-nano} "$WIREPROXY_WG_WARP_CONF" || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
            wireproxy_restart_service_with_backup "$backup_file" "$WIREPROXY_WG_WARP_CONF"
            ;;
        0) return 2 ;;
        *) warp_warn "无效选择" ;;
    esac
}

wireproxy_show_ip() {
    clear
    wireproxy_load_socks_settings
    warp_divider
    echo -e "  ${CYAN}WARP 出口${NC}"
    echo -e "  ${CYAN}SOCKS:${NC} ${WIREPROXY_SOCKS_BIND}"
    warp_divider
    wireproxy_show_proxy_trace
}

wireproxy_uninstall() {
    local yn=""
    clear
    warp_divider
    echo -e "  ${RED}删除 WARP SOCKS 服务${NC}"
    if wireproxy_service_running; then
        echo -e "  ${CYAN}WARP:${NC} ${GREEN}运行中${NC}"
    else
        echo -e "  ${CYAN}WARP:${NC} ${YELLOW}未运行${NC}"
    fi
    warp_divider
    echo -e "  ${RED}将停止服务并删除配置与程序文件${NC}"
    echo
    read -rp "  确认删除 [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if wireproxy_service_running; then
        systemctl stop "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || warp_err "服务停止失败，请先处理后再删除"
        wireproxy_service_running && warp_err "服务仍在运行，请先处理后再删除"
        warp_ok "服务已停止"
    fi

    systemctl disable "$WIREPROXY_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$WIREPROXY_SERVICE_FILE" "$WIREPROXY_BIN"
    rm -rf "$WIREPROXY_CONF_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    warp_ok "WARP SOCKS 服务已删除"
}

wireproxy_menu() {
    local choice
    [[ $EUID -ne 0 ]] && warp_err "请使用 root 用户运行此脚本"
    while true; do
        clear
        echo -e "${BOLD}  ╔══════════════════════════╗"
        echo -e "  ║    WARP SOCKS 管理 v3.0 ║"
        echo -e "  ╚══════════════════════════╝${NC}"
        wireproxy_show_proxy_status
        warp_divider
        echo -e "  ${BOLD}操作:${NC}"
        echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
        echo -e "  ${YELLOW}3)${NC} 修改配置   ${RED}4)${NC} 删除服务"
        echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 返回上级"
        warp_divider
        choice=$(read_menu_choice "  请输入选项 [0-5]: ") || return 1
        case "$choice" in
            1) wireproxy_install_free; pause_enter "回车继续..." ;;
            2) wireproxy_install_team; pause_enter "回车继续..." ;;
            3) wireproxy_modify_config; [[ $? -eq 2 ]] || pause_enter "回车继续..." ;;
            4) wireproxy_uninstall && pause_enter "回车继续..." ;;
            5) wireproxy_show_ip; pause_enter "回车继续..." ;;
            0) return 0 ;;
            *) warp_warn "无效选项"; pause_enter "回车继续..." ;;
        esac
    done
}

# ============================ WarpStack ============================

WARPSTACK_WG_CONF="/etc/wireguard/wg0.conf"
WARPSTACK_WGCF_ARCH=""
WARPSTACK_NET_MODE=""
WARPSTACK_INSTALL_MODE=""
WARPSTACK_APT_UPDATED=0
WARPSTACK_AUTOSTART_STATUS="未设置"
WARPSTACK_V4_ADDR=false
WARPSTACK_V6_ADDR=false
WARPSTACK_V4_READY=false
WARPSTACK_V6_READY=false

warpstack_install_pkg() {
    local packages=("$@")
    command -v apt-get &>/dev/null || warp_err "仅支持 Debian/Ubuntu（未找到 apt-get）"
    if [[ "$WARPSTACK_APT_UPDATED" -eq 0 ]]; then
        ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get update -qq ) || return 1
        WARPSTACK_APT_UPDATED=1
    fi
    ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" )
}

warpstack_detect_network() {
    local pid4="" pid6=""
    WARPSTACK_V4_ADDR=false
    WARPSTACK_V6_ADDR=false
    WARPSTACK_V4_READY=false
    WARPSTACK_V6_READY=false

    dns_has_ipv4 && WARPSTACK_V4_ADDR=true
    dns_has_ipv6 && WARPSTACK_V6_ADDR=true

    if $WARPSTACK_V4_ADDR; then
        warpstack_fetch_trace -4 3 6 >/dev/null &
        pid4=$!
    fi
    if $WARPSTACK_V6_ADDR; then
        warpstack_fetch_trace -6 3 6 >/dev/null &
        pid6=$!
    fi
    [[ -n "$pid4" ]] && wait "$pid4" && WARPSTACK_V4_READY=true
    [[ -n "$pid6" ]] && wait "$pid6" && WARPSTACK_V6_READY=true

    if $WARPSTACK_V4_READY && $WARPSTACK_V6_READY; then
        WARPSTACK_NET_MODE="dual"
    elif $WARPSTACK_V6_READY; then
        WARPSTACK_NET_MODE="v6_only"
    elif $WARPSTACK_V4_READY; then
        WARPSTACK_NET_MODE="v4_only"
    elif $WARPSTACK_V4_ADDR || $WARPSTACK_V6_ADDR; then
        WARPSTACK_NET_MODE="uncertain"
    else
        WARPSTACK_NET_MODE="none"
    fi
}

warpstack_show_network_status() {
    local warp_running=false config_mode="" has_v4=false has_v6=false net_mode="none"
    if ip link show wg0 &>/dev/null 2>&1; then
        warp_running=true
        config_mode="$(warpstack_config_mode 2>/dev/null || true)"
    fi
    dns_has_ipv4 && has_v4=true
    dns_has_ipv6 && has_v6=true
    if $has_v4 && $has_v6; then
        net_mode="dual"
    elif $has_v6; then
        net_mode="v6_only"
    elif $has_v4; then
        net_mode="v4_only"
    elif ip -4 -o addr show scope global 2>/dev/null | grep -Evq 'inet[[:space:]]+(0\.|127\.|169\.254\.)' ||
         ip -6 -o addr show scope global 2>/dev/null | grep -q inet6; then
        net_mode="uncertain"
    fi
    case "$net_mode" in
        dual)
            if $warp_running && [[ "$config_mode" == "add_v4" ]]; then
                echo -e "  网络: ${GREEN}IPv4✓(WARP)${NC} ${GREEN}IPv6✓(原生)${NC}"
            elif $warp_running && [[ "$config_mode" == "add_v6" ]]; then
                echo -e "  网络: ${GREEN}IPv4✓(原生)${NC} ${GREEN}IPv6✓(WARP)${NC}"
            else
                echo -e "  网络: ${GREEN}IPv4✓${NC} ${GREEN}IPv6✓${NC}"
            fi
            ;;
        v6_only)   echo -e "  网络: ${RED}IPv4✗${NC} ${GREEN}IPv6✓${NC}" ;;
        v4_only)   echo -e "  网络: ${GREEN}IPv4✓${NC} ${RED}IPv6✗${NC}" ;;
        uncertain) echo -e "  网络: ${YELLOW}地址存在，但路由异常${NC}" ;;
        none)      echo -e "  网络: ${RED}IPv4✗${NC} ${RED}IPv6✗${NC}" ;;
    esac
    if $warp_running; then
        echo -e "  WARP: ${GREEN}运行中${NC}"
    else
        echo -e "  WARP: ${YELLOW}未运行${NC}"
    fi
}

warpstack_has_wg_firewall_backend() {
    command -v nft >/dev/null 2>&1 && return 0
    command -v iptables-restore >/dev/null 2>&1 && command -v ip6tables-restore >/dev/null 2>&1
}

warpstack_install_wireguard_tools() {
    if ! command -v wg &>/dev/null || ! command -v wg-quick &>/dev/null; then
        warp_info "安装 wireguard-tools ..."
        warpstack_install_pkg --no-install-recommends wireguard-tools || warp_err "wireguard-tools 安装失败"
        command -v wg &>/dev/null && command -v wg-quick &>/dev/null || warp_err "wireguard-tools 安装后仍未检测到 wg/wg-quick 命令"
    fi
    if ! warpstack_has_wg_firewall_backend; then
        warp_info "安装 iptables（wg-quick 默认路由规则依赖）..."
        warpstack_install_pkg --no-install-recommends iptables || warpstack_install_pkg --no-install-recommends nftables ||
            warp_err "无法安装 iptables 或 nftables，wg-quick 无法配置默认路由"
        warpstack_has_wg_firewall_backend || warp_err "安装后仍缺少 iptables-restore/ip6tables-restore 或 nft"
    fi
    if ! command -v sysctl &>/dev/null; then
        warp_info "安装 procps（wg-quick sysctl 依赖）..."
        warpstack_install_pkg --no-install-recommends procps || warp_err "procps 安装失败"
        command -v sysctl &>/dev/null || warp_err "procps 安装后仍未检测到 sysctl 命令"
    fi
    warp_ok "wireguard-tools 及其防火墙依赖已就绪"
}

warpstack_check_dependencies() {
    if ! command -v curl &>/dev/null; then
        warp_info "安装 curl ..."
        warpstack_install_pkg curl || warp_err "curl 安装失败"
    fi
    if ! command -v ip &>/dev/null; then
        warp_info "安装 iproute2 ..."
        warpstack_install_pkg iproute2 || warp_err "iproute2 安装失败"
    fi
    command -v curl &>/dev/null || warp_err "curl 不可用，无法继续"
    command -v ip &>/dev/null || warp_err "ip 不可用，无法继续"
    command -v sha256sum &>/dev/null || warp_err "缺少依赖: sha256sum"
}

warpstack_prepare_install() {
    local account_type="$1"
    if [[ "$account_type" == team ]] && ! command -v jq >/dev/null 2>&1; then
        warpstack_install_pkg jq || warp_err "jq 安装失败"
    fi
    warpstack_check_dependencies
    warpstack_check_wg0_exists
    warpstack_determine_install_mode || return 1
    if [[ "$account_type" == "free" ]]; then
        WARPSTACK_WGCF_ARCH=$(zero_get_arch) || warp_err "不支持的架构: $(uname -m)"
    fi
    warpstack_install_wireguard_tools
}

warpstack_determine_install_mode() {
    warpstack_detect_network
    case "$WARPSTACK_NET_MODE" in
        dual)      warp_warn "已是双栈，无需安装"; return 1 ;;
        uncertain) warp_err "检测到 IP 地址但联网测试失败，为避免误改路由已停止安装" ;;
        v6_only)   WARPSTACK_INSTALL_MODE="add_v4"; warp_info "检测到纯 IPv6，将添加 IPv4 出口" ;;
        v4_only)   WARPSTACK_INSTALL_MODE="add_v6"; warp_info "检测到纯 IPv4，将添加 IPv6 出口" ;;
        none)      warp_err "当前服务器无任何网络连接，无法继续" ;;
    esac
    return 0
}

warpstack_check_wg0_exists() {
    ip link show wg0 &>/dev/null 2>&1 && warp_err "检测到 wg0 接口，请先处理后再安装"
    [[ -e "$WARPSTACK_WG_CONF" || -L "$WARPSTACK_WG_CONF" ]] &&
        warp_err "检测到已有 ${WARPSTACK_WG_CONF}，为避免覆盖已停止安装"
    if command -v systemctl &>/dev/null && systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
        warp_err "检测到 wg-quick@wg0 已启用，请先处理后再安装"
    fi
}

warpstack_write_wg_conf() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5" mode="$6"
    local address allowed_ips conf_dir

    case "$mode" in
        add_v4)
            [[ -n "$v4" ]] || warp_err "缺少 WARP IPv4 地址，无法写入配置"
            address="${v4}/32"
            allowed_ips="0.0.0.0/0"
            ;;
        add_v6)
            [[ -n "$v6" ]] || warp_err "缺少 WARP IPv6 地址，无法写入配置"
            address="${v6}/128"
            allowed_ips="::/0"
            ;;
        *) warp_err "未知的 WARP 安装模式: ${mode}" ;;
    esac

    conf_dir="${WARPSTACK_WG_CONF%/*}"
    mkdir -p "$conf_dir" || warp_err "无法创建 WireGuard 配置目录: ${conf_dir}"
    if ! cat > "$WARPSTACK_WG_CONF" <<EOF || ! chmod 600 "$WARPSTACK_WG_CONF"; then
# Managed by Zero.sh WarpStack
[Interface]
PrivateKey = ${priv}
Address = ${address}
MTU = 1280

[Peer]
PublicKey = ${pub}
AllowedIPs = ${allowed_ips}
Endpoint = ${ep}
PersistentKeepalive = 25
EOF
        rm -f "$WARPSTACK_WG_CONF"
        warp_err "写入 WireGuard 配置失败: ${WARPSTACK_WG_CONF}"
    fi
    warp_ok "wg0.conf 已写入"
}

warpstack_verify_tunnel() {
    local mode="$1" attempts="${2:-3}" family trace attempt
    [[ "$mode" == "add_v4" ]] && family="-4" || family="-6"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        trace="$(warpstack_fetch_trace "$family" || true)"
        warpstack_trace_is_warp "$trace" && return 0
        (( attempt < attempts )) && sleep 1
    done
    return 1
}

warpstack_latest_handshake() {
    wg show wg0 latest-handshakes 2>/dev/null |
        awk '$2 ~ /^[0-9]+$/ && $2 > latest { latest=$2 } END { print latest+0 }'
}

warpstack_cleanup_failed_install() {
    warpstack_down_wg || true
    rm -f "$WARPSTACK_WG_CONF"
}

warpstack_start_and_enable() {
    local mode="$1" handshake endpoint failure_reason
    warp_info "启动 wg0 隧道 ..."
    if ! wg-quick up wg0; then
        warpstack_cleanup_failed_install
        warp_err "wg0 启动失败，本次配置已撤销"
    fi
    if ! warpstack_verify_tunnel "$mode"; then
        handshake="$(warpstack_latest_handshake)"
        endpoint="$(wg show wg0 endpoints 2>/dev/null | awk 'NF { print $2; exit }')"
        if [[ "$handshake" == "0" ]]; then
            failure_reason="WireGuard 未完成握手，请检查 Endpoint 与上游 UDP 放行"
        else
            failure_reason="WireGuard 已完成握手，但隧道内 WARP 出口验证失败，请检查路由或 MTU"
        fi
        [[ -n "$endpoint" ]] && failure_reason="${failure_reason}；Endpoint: ${endpoint}"
        warpstack_cleanup_failed_install
        warp_err "${failure_reason}；本次配置已撤销"
    fi
    warp_ok "wg0 隧道与 WARP 出口验证通过"
    if command -v systemctl &>/dev/null; then
        if systemctl enable wg-quick@wg0 &>/dev/null; then
            WARPSTACK_AUTOSTART_STATUS="已启用"
            warp_ok "已设置开机自启"
        else
            WARPSTACK_AUTOSTART_STATUS="启用失败"
            warp_warn "设置开机自启失败（可能不是 systemd 环境）"
        fi
    else
        WARPSTACK_AUTOSTART_STATUS="不支持(systemctl 不存在)"
        warp_warn "未检测到 systemctl，跳过开机自启设置"
    fi
}

warpstack_show_result() {
    local mode="$1" tmpdir v4a="获取失败" v6a="获取失败"
    warp_ok "配置完成"

    tmpdir="$(mktemp -d /tmp/zero-ws-res.XXXXXX)" || return 1
    ( warpstack_public_ip "-4" "获取失败" > "$tmpdir/v4" ) &
    ( warpstack_public_ip "-6" "获取失败" > "$tmpdir/v6" ) &
    wait
    [[ -s "$tmpdir/v4" ]] && v4a="$(<"$tmpdir/v4")"
    [[ -s "$tmpdir/v6" ]] && v6a="$(<"$tmpdir/v6")"
    rm -rf "$tmpdir"

    if [[ "$mode" == "add_v4" ]]; then
        echo -e "  模式: 纯 IPv6 -> 添加 IPv4"
        echo -e "  IPv4: ${GREEN}${v4a}${NC} (WARP)"
        echo -e "  IPv6: ${CYAN}${v6a}${NC} (原生)"
    else
        echo -e "  模式: 纯 IPv4 -> 添加 IPv6"
        echo -e "  IPv4: ${CYAN}${v4a}${NC} (原生)"
        echo -e "  IPv6: ${GREEN}${v6a}${NC} (WARP)"
    fi
    echo -e "  自启: ${WARPSTACK_AUTOSTART_STATUS}"
    echo -e "  配置: ${YELLOW}${WARPSTACK_WG_CONF}${NC}"
}

warpstack_finish_install() {
    local priv="$1" v4="$2" v6="$3" pub="$4" ep="$5"
    warp_info "Endpoint: $ep"
    warpstack_write_wg_conf "$priv" "$v4" "$v6" "$pub" "$ep" "$WARPSTACK_INSTALL_MODE"
    warpstack_start_and_enable "$WARPSTACK_INSTALL_MODE"
    warpstack_show_result "$WARPSTACK_INSTALL_MODE"
}

warpstack_conf_value() {
    wireproxy_extract_ini_value "$WARPSTACK_WG_CONF" "${2:-}" "$1"
}

warpstack_ip_matches_family() {
    local family="$1" ip="$2"
    [[ -n "$ip" ]] || return 1
    [[ "$family" == "-4" ]] && dns_is_valid_ipv4 "$ip" || dns_is_valid_ipv6 "$ip"
}

warpstack_public_ip() {
    local family="$1" fallback="$2" ip="" trace="" url
    if trace="$(warpstack_fetch_trace "$family" 3 5 2>/dev/null || true)" && [[ -n "$trace" ]]; then
        ip="$(warp_trace_value "$trace" "ip")"
        ip="$(trim_input "${ip//$'\r'/}")"
        if warpstack_ip_matches_family "$family" "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    fi
    for url in https://ip.gs https://icanhazip.com https://api64.ipify.org; do
        ip=$(curl -fsSL "$family" --noproxy '*' --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || true)
        ip="$(trim_input "${ip//$'\r'/}")"
        if warpstack_ip_matches_family "$family" "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    printf '%s' "$fallback"
}

warpstack_fetch_trace() {
    local family="$1" connect_timeout="${2:-5}" max_time="${3:-10}" trace="" literal_url="http://1.1.1.1/cdn-cgi/trace"
    local -a extra_args=()
    if [[ "$family" == "-6" ]]; then
        literal_url="http://[2606:4700:4700::1111]/cdn-cgi/trace"
        extra_args=(-g)
    fi
    trace="$(curl -fsS "$family" ${extra_args[@]+"${extra_args[@]}"} --noproxy '*' --connect-timeout "$connect_timeout" --max-time "$max_time" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if [[ "$trace" != *"ip="* || "$trace" != *"warp="* ]]; then
        trace="$(curl -fsS "$family" ${extra_args[@]+"${extra_args[@]}"} --noproxy '*' --connect-timeout "$connect_timeout" --max-time "$max_time" \
            "$literal_url" 2>/dev/null || true)"
    fi
    [[ "$trace" == *"ip="* && "$trace" == *"warp="* ]] || return 1
    printf '%s\n' "$trace"
}

warpstack_trace_is_warp() {
    local warp
    warp="$(warp_trace_value "$1" "warp")"
    [[ -n "$warp" && "$warp" != "off" ]]
}

warpstack_install_free() {
    local ep
    warpstack_prepare_install free || return 1

    warp_info "注册 WARP 免费账户 (wgcf) ..."
    warp_register_wgcf_free "$WARPSTACK_WGCF_ARCH" "$WARPSTACK_NET_MODE" ||
        warp_err "WARP 免费账户注册或配置提取失败"
    warp_ok "wgcf 校验与免费账户注册成功"
    warp_info "WARP IPv4: ${WARP_REG_V4} | IPv6: ${WARP_REG_V6}"

    [[ -n "$WARPSTACK_NET_MODE" ]] || warpstack_detect_network
    ep="$(warp_require_endpoint "$WARPSTACK_NET_MODE" "$WARP_REG_ENDPOINT" "" "" "")" || return 1
    warpstack_finish_install "$WARP_REG_PRIV" "$WARP_REG_V4" "$WARP_REG_V6" "$WARP_REG_PUB" "$ep"
}

warpstack_install_team() {
    local endpoint
    warpstack_prepare_install team || return 1
    warp_prompt_and_register_team || { [[ $? -eq 2 ]] && return 0 || return 1; }

    [[ -n "$WARPSTACK_NET_MODE" ]] || warpstack_detect_network
    endpoint="$(warp_require_endpoint "$WARPSTACK_NET_MODE" "$WARP_REG_ENDPOINT" "$WARP_REG_EP_V4" "$WARP_REG_EP_V6" "$WARP_REG_EP_PORT")" || return 1
    warpstack_finish_install "$WARP_REG_PRIV" "$WARP_REG_V4" "$WARP_REG_V6" "$WARP_REG_PUB" "$endpoint"
}

warpstack_config_mode() {
    local allowed
    [[ -f "$WARPSTACK_WG_CONF" ]] || return 1
    allowed="$(warpstack_conf_value "AllowedIPs")"
    if [[ "$allowed" == *"0.0.0.0/0"* ]]; then
        printf 'add_v4\n'
    elif [[ "$allowed" == *"::/0"* ]]; then
        printf 'add_v6\n'
    else
        return 1
    fi
}

warpstack_try_restart_wg() {
    local mode
    mode="$(warpstack_config_mode)" || return 1

    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_down_wg || return 1
    fi
    if ! wg-quick up wg0; then
        warpstack_down_wg || true
        return 1
    fi
    if ! warpstack_verify_tunnel "$mode"; then
        warpstack_down_wg || true
        return 1
    fi
    return 0
}

warpstack_restart_wg_with_backup() {
    local backup="$1"

    warp_info "应用配置并验证 WARP 出口 ..."
    if warpstack_try_restart_wg; then
        rm -f "$backup"
        warp_ok "配置已生效，WARP 出口正常"
        return 0
    fi

    cp "$backup" "$WARPSTACK_WG_CONF" || {
        warp_warn "新配置启动失败，且无法恢复原配置；备份保留在 $backup"
        return 1
    }
    rm -f "$backup"

    if warpstack_try_restart_wg; then
        warp_warn "新配置启动失败，已回滚到上一份可用配置"
    else
        warp_warn "新配置启动失败，回滚后隧道仍未启动"
    fi
    return 1
}

warpstack_modify_config() {
    clear
    warp_divider
    [[ ! -f "$WARPSTACK_WG_CONF" ]] && { warp_warn "未找到 ${WARPSTACK_WG_CONF}，请先安装"; return; }

    local current_ep current_mtu sub new_ep backup_file mtu yn
    current_ep=$(warpstack_conf_value "Endpoint" "Peer")
    current_mtu=$(warpstack_conf_value "MTU" "Interface")
    [[ -z "$current_mtu" ]] && current_mtu="1280"

    echo -e "  ${CYAN}Endpoint:${NC} ${current_ep}"
    echo -e "  ${CYAN}MTU:${NC} ${current_mtu}"
    warp_divider
    echo -e "  ${GREEN}1)${NC} 改Endpoint   ${CYAN}2)${NC} 改MTU"
    echo -e "  ${YELLOW}3)${NC} 编辑配置     ${RED}0)${NC} 返回上级"
    echo
    sub=$(read_menu_choice "  请选择 [0-3]: ") || return 1

    case "$sub" in
        1)
            echo -e "  ${CYAN}当前 Endpoint:${NC} ${current_ep}"
            read -rp "新 Endpoint: " new_ep
            if [[ -n "$new_ep" ]]; then
                if ! warp_is_valid_endpoint "$new_ep"; then
                    warp_warn "Endpoint 格式无效，请使用 域名/IP:端口 或 [IPv6]:端口"
                else
                    backup_file="$(warp_make_backup "$WARPSTACK_WG_CONF")" || return 1
                    warp_update_conf_key "$WARPSTACK_WG_CONF" "Peer" "Endpoint" "$new_ep" || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
                    warpstack_restart_wg_with_backup "$backup_file" || true
                fi
            fi
            ;;
        2)
            echo -e "  ${CYAN}当前 MTU:${NC} ${current_mtu}  建议: 1280 或 1420"
            read -rp "新 MTU [1280-1500]: " mtu
            if [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 1280 && mtu <= 1500 )); then
                backup_file="$(warp_make_backup "$WARPSTACK_WG_CONF")" || return 1
                warp_update_conf_key "$WARPSTACK_WG_CONF" "Interface" "MTU" "$mtu" || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
                warpstack_restart_wg_with_backup "$backup_file" || true
            else
                warp_warn "无效的 MTU 值"
            fi
            ;;
        3)
            backup_file="$(warp_make_backup "$WARPSTACK_WG_CONF")" || return 1
            ${EDITOR:-nano} "$WARPSTACK_WG_CONF" || { warp_warn "配置修改失败；备份保留在 $backup_file"; return 1; }
            read -rp "保存并重启验证？[Y/n]: " yn || yn=n
            if [[ "$yn" =~ ^[Nn]$ ]]; then
                cp "$backup_file" "$WARPSTACK_WG_CONF" || {
                    warp_warn "取消编辑时恢复失败；备份保留在 $backup_file"
                    return 1
                }
                rm -f "$backup_file"
                warp_warn "已取消，配置未更改"
            else
                warpstack_restart_wg_with_backup "$backup_file" || true
            fi
            ;;
        0) return 2 ;;
        *) warp_warn "无效选择" ;;
    esac
}

warpstack_down_wg() {
    wg-quick down wg0 2>/dev/null || true
    ! ip link show wg0 &>/dev/null 2>&1
}

warpstack_stop_wg() {
    if ip link show wg0 &>/dev/null 2>&1; then
        warp_info "暂停 wg0 ..."
        warpstack_down_wg || warp_err "wg0 暂停失败"
        warp_ok "wg0 已暂停"
    else
        warp_warn "wg0 未运行"
    fi
}

warpstack_restart_wg() {
    warp_info "启动 wg0 并验证 WARP 出口 ..."
    warpstack_try_restart_wg || warp_err "wg0 启动或 WARP 出口验证失败，隧道已停止"
    warp_ok "wg0 已启动，WARP 出口正常"
}

warpstack_manage_service() {
    local sub
    while true; do
        clear
        warp_divider
        if ip link show wg0 &>/dev/null 2>&1; then
            echo -e "  ${CYAN}WARP 状态:${NC} ${GREEN}运行中${NC}"
        else
            echo -e "  ${CYAN}WARP 状态:${NC} ${YELLOW}未运行${NC}"
        fi
        warp_divider
        echo -e "  ${GREEN}1)${NC} 修改配置  ${CYAN}2)${NC} 暂停服务"
        echo -e "  ${YELLOW}3)${NC} 重启服务  ${RED}0)${NC} 返回上级"
        echo
        sub=$(read_menu_choice "  请选择 [0-3]: ") || return 1

        case "$sub" in
            1) warpstack_modify_config; [[ $? -eq 2 ]] || pause_enter "回车继续..." ;;
            2) warpstack_stop_wg; pause_enter "回车继续..." ;;
            3) warpstack_restart_wg; pause_enter "回车继续..." ;;
            0) return 0 ;;
            *) warp_warn "无效选择"; pause_enter "回车继续..." ;;
        esac
    done
}

warpstack_show_ip() {
    clear
    warp_info "当前出口 IP"
    local v4="无" v6="无" allowed="" v4_trace="" v6_trace="" v4_suffix="" v6_suffix="" warp_status="" has_target=false has_warp=false tmpdir
    tmpdir="$(mktemp -d /tmp/zero-ws-ip.XXXXXX)" || return 1

    [[ -f "$WARPSTACK_WG_CONF" ]] && allowed="$(warpstack_conf_value "AllowedIPs")"

    if [[ "$allowed" == *"0.0.0.0/0"* ]]; then
        has_target=true
        ( warpstack_fetch_trace "-4" > "$tmpdir/t4" 2>/dev/null || warpstack_public_ip "-4" "无" > "$tmpdir/ip4" ) &
    else
        ( warpstack_public_ip "-4" "无" > "$tmpdir/ip4" ) &
    fi

    if [[ "$allowed" == *"::/0"* ]]; then
        has_target=true
        ( warpstack_fetch_trace "-6" > "$tmpdir/t6" 2>/dev/null || warpstack_public_ip "-6" "无" > "$tmpdir/ip6" ) &
    else
        ( warpstack_public_ip "-6" "无" > "$tmpdir/ip6" ) &
    fi
    wait

    if [[ -s "$tmpdir/t4" ]]; then
        v4_trace="$(<"$tmpdir/t4")"
        v4="$(warp_trace_value "$v4_trace" "ip")"
        [[ -z "$v4" ]] && v4="无"
        if warpstack_trace_is_warp "$v4_trace"; then
            has_warp=true
            v4_suffix=" ${GREEN}(WARP)${NC}"
        fi
    elif [[ -s "$tmpdir/ip4" ]]; then
        v4="$(<"$tmpdir/ip4")"
    fi

    if [[ -s "$tmpdir/t6" ]]; then
        v6_trace="$(<"$tmpdir/t6")"
        v6="$(warp_trace_value "$v6_trace" "ip")"
        [[ -z "$v6" ]] && v6="无"
        if warpstack_trace_is_warp "$v6_trace"; then
            has_warp=true
            v6_suffix=" ${GREEN}(WARP)${NC}"
        fi
    elif [[ -s "$tmpdir/ip6" ]]; then
        v6="$(<"$tmpdir/ip6")"
    fi
    rm -rf "$tmpdir"

    echo -e "  IPv4: ${CYAN}${v4}${NC}${v4_suffix}"
    echo -e "  IPv6: ${CYAN}${v6}${NC}${v6_suffix}"
    warp_divider
    if [[ ! -f "$WARPSTACK_WG_CONF" ]]; then
        warp_warn "未找到 ${WARPSTACK_WG_CONF}，无法判断 WARP 状态"
        return
    fi
    [[ "$allowed" == *"0.0.0.0/0"* && -z "$v4_trace" ]] && warp_warn "无法通过 IPv4 获取 Cloudflare trace"
    [[ "$allowed" == *"::/0"* && -z "$v6_trace" ]] && warp_warn "无法通过 IPv6 获取 Cloudflare trace"
    $has_target || warp_warn "配置中未找到可检查的 WARP AllowedIPs"
    if $has_warp; then
        warp_status="$(warp_merge_warp_status "$v4_trace" "$v6_trace")"
        echo -e "  Warp: ${YELLOW}${warp_status}${NC}"
    else
        warp_warn "未检测到 WARP 出口状态"
    fi
}

warpstack_uninstall() {
    local yn
    clear
    warp_info "删除 WARP 服务"
    echo -e "  ${RED}将删除 wg0 与配置文件${NC}"
    if { [[ -f "$WARPSTACK_WG_CONF" ]] || ip link show wg0 &>/dev/null 2>&1; } &&
       ! grep -q '^# Managed by Zero.sh WarpStack$' "$WARPSTACK_WG_CONF" 2>/dev/null; then
        warp_warn "当前 wg0 没有 Zero.sh 标记，可能属于其他 WireGuard 服务"
        read -rp "仍要删除未标记的 wg0 [y/N]: " yn
    else
        read -rp "确认删除 [y/N]: " yn
    fi
    [[ ! "$yn" =~ ^[Yy]$ ]] && return 1

    if ip link show wg0 &>/dev/null 2>&1; then
        warpstack_down_wg || warp_err "隧道关闭失败，请先处理后再删除"
        warp_ok "隧道已关闭"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl disable wg-quick@wg0 &>/dev/null 2>&1 && warp_ok "已取消自启" || warp_warn "取消自启失败"
    else
        warp_warn "未检测到 systemctl，跳过取消自启"
    fi
    rm -f "$WARPSTACK_WG_CONF"
    warp_ok "已删除 $WARPSTACK_WG_CONF"
    warp_ok "WARP 服务已完全删除"
}

warpstack_menu() {
    local choice
    [[ $EUID -ne 0 ]] && warp_err "请使用 root 用户运行此脚本"
    while true; do
        clear
        echo -e "${BOLD}  ╔══════════════════════════╗"
        echo -e "  ║    WARP 出口管理 v2.0 ║"
        echo -e "  ╚══════════════════════════╝${NC}"
        warpstack_show_network_status
        warp_divider
        echo -e "  ${BOLD}操作:${NC}"
        echo -e "  ${GREEN}1)${NC} 免费账户   ${CYAN}2)${NC} 团队账户"
        echo -e "  ${YELLOW}3)${NC} 管理服务   ${RED}4)${NC} 删除服务"
        echo -e "  ${GREEN}5)${NC} 查看出口   ${RED}0)${NC} 返回上级"
        warp_divider
        choice=$(read_menu_choice "  请输入选项 [0-5]: ") || return 1
        case "$choice" in
            1) warpstack_install_free; pause_enter "回车继续..." ;;
            2) warpstack_install_team; pause_enter "回车继续..." ;;
            3) warpstack_manage_service ;;
            4) warpstack_uninstall && pause_enter "回车继续..." ;;
            5) warpstack_show_ip; pause_enter "回车继续..." ;;
            0) return 0 ;;
            *) warp_warn "无效选项"; pause_enter "回车继续..." ;;
        esac
    done
}

# BEGIN ZERO_VOLTO_MODULE
volto_emit_manager_script() {
    cat <<'__ZERO_VOLTO_MANAGER_SCRIPT_V1__'
#!/usr/bin/env bash
# Volto.sh — 独立 MASQUE 服务管理，Zero.sh 选项 11。
# 上游：https://github.com/vcarus/volto
# Surge：https://manual.nssurge.com/policies/masque.html
# shellcheck disable=SC2016

VOLTO_MANAGER_VERSION="1.0.19"
VOLTO_SOURCE="${BASH_SOURCE[0]}"
VOLTO_DIR="/etc/volto"
VOLTO_BIN="/usr/local/bin/volto"
VOLTO_MANAGER="/usr/local/sbin/volto-manager"
VOLTO_SERVICE="volto.service"
VOLTO_UNIT="/etc/systemd/system/volto.service"
VOLTO_CERT_SERVICE="volto-cert-sync.service"
VOLTO_CERT_TIMER="volto-cert-sync.timer"
VOLTO_CERT_UNIT="/etc/systemd/system/volto-cert-sync.service"
VOLTO_CERT_TIMER_UNIT="/etc/systemd/system/volto-cert-sync.timer"
VOLTO_LEGACY_BACKUP_ROOT="/var/backups/volto-manager"
VOLTO_LOCK="/run/lock/volto-manager.lock"
VOLTO_USER="volto"
VOLTO_API="https://api.github.com/repos/vcarus/volto/releases"
VOLTO_MARKER="volto-manager-v1"
VOLTO_WORK=""
VOLTO_NEW=""
VOLTO_INSTALLING=0
VOLTO_WRITING=0
VOLTO_VERSION=""
VOLTO_ASSET=""
VOLTO_URL=""
VOLTO_DIGEST=""
VOLTO_SUMS_URL=""
VOLTO_CERT_CHANGED=0
VOLTO_ACTION=''
RED='' GREEN='' YELLOW='' BLUE='' PLAIN=''

info() { printf '%b%s%b\n' "$BLUE" "$*" "$PLAIN" >&2; }
ok() { printf '%b%s%b\n' "$GREEN" "$*" "$PLAIN" >&2; }
warn() { printf '%b%s%b\n' "$YELLOW" "$*" "$PLAIN" >&2; }
error() { printf '%b%s%b\n' "$RED" "$*" "$PLAIN" >&2; return 1; }
menu_title() { printf '%b%s%b\n' "$BLUE" "$1" "$PLAIN"; }
menu_items() {
    local item
    for item in "$@"; do
        printf '%b  %s.%b%s\n' "$GREEN" "${item%%.*}" "$PLAIN" "${item#*. }"
    done
}
prompt_text() { printf '%b%s%b' "$BLUE" "$1" "$PLAIN"; }

pause_menu() { read -r -p "$(prompt_text '按回车返回...')" _ || return 0; }
screen() { [[ -t 1 && -n "${TERM:-}" ]] && clear; return 0; }
ask_yes() { local answer; read -r -p "$(prompt_text "$1 [y/N]: ")" answer || return 1; [[ "$answer" =~ ^[Yy]$ ]]; }
norm_choice() {
    local v="${1#"${1%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [[ "$v" =~ ^[0-9]+$ ]] && v=$((10#$v))
    printf '%s' "$v"
}

usage() {
    printf '%s\n' \
        "Volto.sh ${VOLTO_MANAGER_VERSION} — volto / Surge 管理脚本" \
        '使用：sudo bash Volto.sh' \
        '安装后：sudo volto-manager' \
        '命令：--status  --show-surge  --check  --renew-cert  --help  --version' \
        '支持 Debian/Ubuntu、systemd、Linux x86_64/ARM64。' \
        'Surge iOS 5.22.0+ / Mac 6.9.0+；服务端使用 UDP。'
}

is_managed() {
    [[ -f "$VOLTO_DIR/.managed" && ! -L "$VOLTO_DIR" ]] &&
        [[ "$(<"$VOLTO_DIR/.managed")" == "$VOLTO_MARKER" ]]
}

managed_revision() {
    local path="$1" tail
    [[ "$path" == "$VOLTO_DIR/revisions/"* ]] || return 1
    tail="${path#"$VOLTO_DIR/revisions/"}"
    [[ "$tail" =~ ^rev\.[A-Za-z0-9]+$ && -d "$path" && ! -L "$path" ]]
}

current_revision() {
    local path
    is_managed && [[ -L "$VOLTO_DIR/current" ]] || return 1
    path=$(readlink "$VOLTO_DIR/current") || return 1
    managed_revision "$path" || return 1
    printf '%s\n' "$path"
}

require_install() {
    current_revision >/dev/null && [[ -x "$VOLTO_BIN" && -f "$VOLTO_UNIT" ]] ||
        error '未找到本脚本的完整安装，请先安装服务。'
}

atomic_install() {
    local source="$1" target="$2" mode="$3" group="${4:-root}" dir tmp
    [[ ! -L "$target" ]] || { error "拒绝覆盖符号链接：$target"; return 1; }
    dir="${target%/*}"
    [[ "$target" != */* || -z "$dir" || -d "$dir" ]] || install -d -m 755 "$dir" || return 1
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if install -o root -g "$group" -m "$mode" "$source" "$tmp" && mv -fT "$tmp" "$target"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

atomic_link() {
    local target="$1" tmp
    managed_revision "$target" || return 1
    tmp=$(mktemp "$VOLTO_DIR/.link.XXXXXX") || return 1
    rm -f -- "$tmp" || return 1
    if ln -s "$target" "$tmp" && mv -fT "$tmp" "$VOLTO_DIR/current"; then return 0; fi
    rm -f -- "$tmp"
    return 1
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_user() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; }
valid_password() { [[ "$1" =~ ^[A-Za-z0-9]{8,128}$ ]]; }

valid_domain() {
    local name="$1" label
    local -a labels
    [[ ${#name} -le 253 && "$name" == *.* && "$name" != *..* && "$name" != *. ]] || return 1
    [[ "$name" =~ [A-Za-z] && "$name" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS='.' read -r -a labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
}

valid_ipv4() {
    local part
    local -a parts
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a parts <<< "$1"
    for part in "${parts[@]}"; do
        (( 10#$part <= 255 )) || return 1
        [[ "$part" == 0 || "$part" != 0* ]] || return 1
    done
}

valid_ipv6() {
    local value="$1" rest group count=0 compressed=0 suffix
    local -a groups
    [[ "$value" == *:* && "$value" != *:::* && "$value" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    if [[ "$value" == *.* ]]; then
        suffix="${value##*:}"
        valid_ipv4 "$suffix" || return 1
        value="${value%:*}:0:0"
    fi
    if [[ "$value" == *::* ]]; then
        compressed=1; rest="${value#*::}"
        [[ "$rest" != *::* ]] || return 1
        [[ "$value" != :* || "$value" == ::* ]] || return 1
        [[ "$value" != *: || "$value" == *:: ]] || return 1
    else
        [[ "$value" != :* && "$value" != *: ]] || return 1
    fi
    IFS=':' read -r -a groups <<< "$value"
    for group in "${groups[@]}"; do
        [[ -n "$group" ]] || continue
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        count=$((count + 1))
    done
    if (( compressed )); then (( count < 8 )); else (( count == 8 )); fi
}

valid_endpoint() { valid_ipv4 "$1" || valid_ipv6 "$1" || valid_domain "$1"; }

random_password() {
    local value
    value=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9') || return 1
    value="${value:0:16}"
    [[ "$value" =~ ^[A-Za-z0-9]{16}$ ]] || return 1
    printf '%s' "$value"
}

prompt_value() {
    local label="$1" default="$2" validator="$3" value
    while true; do
        read -r -p "$(prompt_text "$label${default:+ (默认: $default)}: ")" value || return 1
        value="${value:-$default}"
        if "$validator" "$value"; then printf '%s' "$value"; return 0; fi
        warn '输入格式无效，请重试。'
    done
}

prompt_password() {
    local current="${1:-}" value label='密码 (8–128 位字母数字，回车随机生成 16 位): '
    [[ -z "$current" ]] || label='密码 (8–128 位字母数字，回车保留当前密码): '
    while true; do
        read -r -s -p "$(prompt_text "$label")" value || return 1
        printf '\n' >&2
        value="${value:-$current}"
        [[ -n "$value" ]] || value=$(random_password) || return 1
        if valid_password "$value"; then printf '%s' "$value"; return 0; fi
        warn '密码仅允许 8–128 位大小写字母和数字。'
    done
}

port_free() {
    local output
    output=$(ss -H -lun "sport = :$1") || { error '无法检查 UDP 端口。'; return 1; }
    [[ -z "$output" ]] || { error "UDP $1 已被占用。"; return 1; }
}

prompt_port() {
    local old="${1:-}" value
    while true; do
        value=$(prompt_value '监听 UDP 端口' "${old:-443}" valid_port) || return 1
        value=$((10#$value))
        if [[ "$value" == "$old" ]] || port_free "$value"; then printf '%s' "$value"; return 0; fi
    done
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'aarch64' ;;
        *) error '仅支持 Linux x86_64 和 ARM64。' ;;
    esac
}

curl_get() { curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 "$@"; }

prepare_release() {
    local release arch tag
    arch=$(get_arch) || return 1
    release=$(curl_get "$VOLTO_API/latest") || return 1
    jq -e '.draft == false and .prerelease == false' <<< "$release" >/dev/null || {
        error '上游未返回有效的正式版发布信息。'; return 1;
    }
    tag=$(jq -er '.tag_name | select(type == "string")' <<< "$release") || return 1
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { error '上游版本号格式异常。'; return 1; }
    VOLTO_VERSION="${tag#v}"
    VOLTO_ASSET="volto-${VOLTO_VERSION}-${arch}-unknown-linux-musl.tar.gz"
    VOLTO_URL=$(jq -er --arg name "$VOLTO_ASSET" '[.assets[] | select(.name == $name)] | select(length == 1) | .[0].browser_download_url' <<< "$release") || {
        error "未找到架构对应的发布包：$VOLTO_ASSET"; return 1;
    }
    VOLTO_DIGEST=$(jq -r --arg name "$VOLTO_ASSET" '.assets[] | select(.name == $name) | .digest // ""' <<< "$release") || return 1
    VOLTO_DIGEST="${VOLTO_DIGEST#sha256:}"
    VOLTO_SUMS_URL=$(jq -er '[.assets[] | select(.name == "SHA256SUMS")] | select(length == 1) | .[0].browser_download_url' <<< "$release") || return 1
    [[ "$VOLTO_URL" == "https://github.com/vcarus/volto/releases/download/$tag/$VOLTO_ASSET" &&
       "$VOLTO_SUMS_URL" == "https://github.com/vcarus/volto/releases/download/$tag/SHA256SUMS" ]] || {
        error '上游下载地址异常。'; return 1;
    }
}

download_release() {
    local stage="$VOLTO_WORK/release" expected actual member kind version
    mkdir -p "$stage" || return 1
    info "正在下载 volto $VOLTO_VERSION ($VOLTO_ASSET)..."
    curl_get "$VOLTO_URL" -o "$stage/archive.tar.gz" &&
        curl_get "$VOLTO_SUMS_URL" -o "$stage/SHA256SUMS" || return 1
    expected=$(awk -v name="$VOLTO_ASSET" '$2 == name || $2 == "*" name {n++; digest=$1} END {if(n==1) print tolower(digest); else exit 1}' "$stage/SHA256SUMS") || return 1
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { error 'SHA256SUMS 中没有有效的 SHA-256。'; return 1; }
    actual=$(sha256sum "$stage/archive.tar.gz" | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]] || { error '发布包 SHA-256 校验失败。'; return 1; }
    if [[ -n "$VOLTO_DIGEST" && "$VOLTO_DIGEST" != "$actual" ]]; then
        error '发布包与 GitHub 提供的摘要不一致。'; return 1
    fi
    member="${VOLTO_ASSET%.tar.gz}/volto"
    kind=$(tar -tvzf "$stage/archive.tar.gz" -- "$member") || return 1
    [[ "$kind" == -* && "$kind" != *$'\n'* ]] || { error '发布包中的 volto 不是唯一普通文件。'; return 1; }
    tar -xOzf "$stage/archive.tar.gz" -- "$member" > "$stage/volto" && chmod 700 "$stage/volto" || return 1
    version=$(binary_version "$stage/volto") || return 1
    [[ "$version" == "$VOLTO_VERSION" ]] || { error '下载的内核版本与 Release 不匹配。'; return 1; }
    ok "发布包校验通过：$version"
}

binary_version() {
    local output
    output=$("$1" --version) || return 1
    [[ "$output" =~ ^volto[[:space:]]([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

version_newer() {
    local next="${1#v}" current="${2#v}" prerelease='~'
    next="${next/-/$prerelease}"; current="${current/-/$prerelease}"
    dpkg --compare-versions "$next" gt "$current"
}

refresh_manager() {
    local source="$VOLTO_SOURCE" installed
    require_install >/dev/null 2>&1 || return 0
    [[ "$source" != "$VOLTO_MANAGER" ]] || return 0
    if [[ -e "$VOLTO_MANAGER" ]]; then
        installed=$("$VOLTO_MANAGER" --version) || return 1
        [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            error '无法识别已安装的管理脚本版本。'; return 1;
        }
        version_newer "$VOLTO_MANAGER_VERSION" "$installed" || return 0
    fi
    atomic_install "$source" "$VOLTO_MANAGER" 755 || return 1
    ok "volto-manager 已同步到 ${VOLTO_MANAGER_VERSION}。"
}

json_edit() {
    local file="$1" tmp
    shift
    tmp=$(mktemp "$VOLTO_WORK/json.XXXXXX") || return 1
    if jq "$@" "$file" > "$tmp" && install -m 600 "$tmp" "$file"; then
        rm -f -- "$tmp"; return 0
    fi
    rm -f -- "$tmp"; return 1
}

validate_settings() {
    local file="$1" endpoint sni verify_name
    jq -e '
        .schema == 1 and (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.listen_address == "0.0.0.0" or .listen_address == "[::]") and
        (.verify_mode == "pin" or .verify_mode == "ca") and
        (.certificate_mode == "selfsigned" or .certificate_mode == "import") and
        (.certificate_mode != "selfsigned" or .verify_mode == "pin") and
        (.sni | type == "string") and (.endpoint | type == "string") and
        ((has("verify_name") | not) or (.verify_name | type == "string")) and
        (.cert_source | type == "string") and (.key_source | type == "string") and
        (.congestion_control == "bbr" or .congestion_control == "bbr-capped" or .congestion_control == "bbr-uncapped" or .congestion_control == "cubic" or .congestion_control == "newreno") and
        ((has("mtu_upper_bound") | not) or
         (.mtu_upper_bound | type == "number" and floor == . and . >= 1200 and . <= 1472)) and
        (.ip_family_preference == "ipv4" or .ip_family_preference == "ipv6" or .ip_family_preference == "system") and
        (.max_connections | type == "number" and floor == . and . >= 1 and . <= 256) and
        (.users | type == "array" and length >= 1 and length <= 100) and
        all(.users[]; (.username | type == "string" and test("\\A[A-Za-z0-9_.-]{1,32}\\z")) and
                     (.password | type == "string" and test("\\A[A-Za-z0-9]{8,128}\\z"))) and
        ([.users[].username] | length == (unique | length))
    ' "$file" >/dev/null || { error '配置参数无效，至少保留一个有效账号。'; return 1; }
    endpoint=$(jq -r '.endpoint' "$file") && sni=$(jq -r '.sni' "$file") &&
        verify_name=$(jq -r '.verify_name // .sni' "$file") || return 1
    if ! valid_endpoint "$endpoint" || ! valid_domain "$sni"; then
        error '公网地址或 SNI 无效。'; return 1
    fi
    if [[ "$(jq -r '.verify_mode' "$file")" == ca ]] && ! valid_domain "$verify_name"; then
        error '证书验证域名无效。'; return 1
    fi
}

detect_endpoint() {
    local address url try_v4=1 try_v6=1
    if command -v ip >/dev/null 2>&1; then
        ip -4 route get 1.1.1.1 2>/dev/null | grep -Evq 'unreachable|prohibit|blackhole|throw|dev lo|src (0\.|127\.|169\.254\.)' || try_v4=0
        ip -6 route get 2001:4860:4860::8888 2>/dev/null | grep -Evq 'unreachable|prohibit|blackhole|throw|dev lo' || try_v6=0
    fi
    if (( try_v4 )); then
        for url in https://api64.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
            address=$(curl_get --noproxy '*' -4 --connect-timeout 3 --max-time 4 "$url" 2>/dev/null) || continue
            address="${address//$'\r'/}"; address="${address//$'\n'/}"
            valid_ipv4 "$address" && { printf '%s' "$address"; return 0; }
        done
    fi
    if (( try_v6 )); then
        for url in https://api64.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
            address=$(curl_get --noproxy '*' -6 --connect-timeout 3 --max-time 4 "$url" 2>/dev/null) || continue
            address="${address//$'\r'/}"; address="${address//$'\n'/}"
            valid_ipv6 "$address" && { printf '%s' "$address"; return 0; }
        done
    fi
    error '无法自动获取公网 IP。'
}

default_listener() {
    local endpoint="$1" ipv6="${2:-/proc/sys/net/ipv6}"
    if valid_ipv6 "$endpoint" || {
        [[ -r "$ipv6/conf/all/disable_ipv6" && -r "$ipv6/bindv6only" ]] &&
        [[ "$(<"$ipv6/conf/all/disable_ipv6")" == 0 && "$(<"$ipv6/bindv6only")" == 0 ]];
    }; then
        printf '[::]'
    else
        printf '0.0.0.0'
    fi
}

render_config() {
    local settings="$1" revision="$2"
    validate_settings "$settings" || return 1
    jq -r --arg dir "$revision" '
        "# 由 Volto.sh 生成，请通过 volto-manager 修改。",
        "[server]",
        ("listen = " + ((.listen_address + ":" + (.port|tostring)) | @json)),
        ("cert = " + (($dir + "/cert.pem") | @json)),
        ("key = " + (($dir + "/key.pem") | @json)),
        "alpn = [\"h3\"]", "shutdown_grace = 5", "",
        "[auth]", "users = [",
        (.users[] | "  { username = " + (.username|@json) + ", password = " + (.password|@json) + " },"),
        "]", "", "[limits]",
        ("congestion_control = " + (.congestion_control|@json)),
        ("ip_family_preference = " + (.ip_family_preference|@json)),
        ("max_connections = " + (.max_connections|tostring)),
        "max_targets_per_conn = 256", "max_streams_bidi = 1024",
        "initial_mtu = 1200",
        ("mtu_upper_bound = " + ((.mtu_upper_bound // 1452)|tostring)), "mtu_discovery = true",
        "max_idle_timeout = 60", "keep_alive_interval = 20", "",
        "[security]", "allow_private_networks = false", "denied_ports = [25]", "",
        "[log]", "level = \"info\"", "keylog = false"
    ' "$settings"
}

new_revision() {
    local old
    VOLTO_NEW=$(mktemp -d "$VOLTO_DIR/revisions/rev.XXXXXXXX") || return 1
    if old=$(current_revision); then
        cp -- "$old/settings.json" "$old/cert.pem" "$old/key.pem" "$VOLTO_NEW/" || return 1
    fi
}

choose_certificate() {
    local file="$1" option sni cert key selected i default=1 current_sni cert_default key_default
    local -a files=()
    VOLTO_CERT_CHANGED=0
    current_sni=$(jq -r '.sni' "$file") || return 1
    if [[ -s "${file%/*}/cert.pem" && -s "${file%/*}/key.pem" ]]; then
        default=0
        info "当前 SNI：${current_sni}；保留当前证书后可修改 SNI。"
        menu_items '0. 保留当前证书和验证方式' >&2
    fi
    menu_items '1. 生成自签名证书 + Surge 指纹固定 (无需域名)' \
        '2. 使用已有域名证书 + CA 验证' '3. 使用已有证书 + Surge 指纹固定' >&2
    read -r -p "$(prompt_text "证书方式 [默认 $default]: ")" option || return 1
    option="${option:-$default}"
    [[ "$option" == 0 && "$default" == 0 ]] && return 0
    case "$option" in 1|2|3) ;; *) error '无效选项。'; return 1;; esac
    if [[ "$option" == 2 ]]; then
        current_sni=$(jq -r 'if .verify_mode == "ca" then (.verify_name // .sni) else "" end' "$file") || return 1
    fi
    sni=$(prompt_value '证书域名 / SNI' "$current_sni" valid_domain) || return 1
    if [[ "$option" == 1 ]]; then
        warn '重新生成自签名证书会改变指纹，完成后必须替换 Surge 节点并重新连接。'
        json_edit "$file" --arg sni "$sni" '.sni=$sni | del(.verify_name) | .certificate_mode="selfsigned" | .verify_mode="pin" | .cert_source="" | .key_source=""' || return 1
        VOLTO_CERT_CHANGED=1
        return 0
    fi
    for cert in /etc/cert/*.crt; do [[ -f "$cert" ]] && files+=("$cert"); done
    for ((i=0; i<${#files[@]}; i++)); do menu_items "$((i+1)). ${files[$i]}" >&2; done
    menu_items '0. 自定义证书路径' >&2
    read -r -p "$(prompt_text '选择已有证书 [默认 0]: ')" selected || return 1
    selected="${selected:-0}"
    if [[ "$selected" == 0 ]]; then
        cert_default=$(jq -r '.cert_source' "$file") && key_default=$(jq -r '.key_source' "$file") || return 1
        read -r -p "$(prompt_text "完整证书链 PEM 路径${cert_default:+ (默认: $cert_default)}: ")" cert || return 1
        read -r -p "$(prompt_text "私钥 PEM 路径${key_default:+ (默认: $key_default)}: ")" key || return 1
        cert="${cert:-$cert_default}"; key="${key:-$key_default}"
    elif [[ "$selected" =~ ^[1-9][0-9]{0,3}$ ]] && (( selected <= ${#files[@]} )); then
        cert="${files[$((selected-1))]}"; key="${cert%.crt}.key"
    else error '无效选项。'; return 1
    fi
    [[ "$cert" == /* && "$key" == /* && -f "$cert" && -f "$key" && -r "$cert" && -r "$key" ]] || {
        error '证书和私钥必须是存在且可读的文件，并使用绝对路径。'; return 1;
    }
    [[ "$cert" != "$VOLTO_DIR/"* && "$key" != "$VOLTO_DIR/"* ]] || {
        error '请选择 /etc/volto 以外的原始证书路径。'; return 1;
    }
    json_edit "$file" --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        --arg mode "$([[ "$option" == 2 ]] && printf ca || printf pin)" \
        '.sni=$sni | .verify_name=$sni | .certificate_mode="import" | .verify_mode=$mode | .cert_source=$cert | .key_source=$key' || return 1
    VOLTO_CERT_CHANGED=1
}

make_certificate() {
    local revision="$1" file="$1/settings.json" sni cert key mode
    sni=$(jq -er '.sni' "$file") && mode=$(jq -er '.certificate_mode' "$file") || return 1
    valid_domain "$sni" || return 1
    if [[ "$mode" == selfsigned ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes -days 3650 -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" \
            -addext 'basicConstraints=critical,CA:FALSE' -addext 'extendedKeyUsage=serverAuth' \
            -keyout "$revision/key.pem" -out "$revision/cert.pem" >/dev/null 2>&1 || {
            error '自签名证书生成失败。'; return 1;
        }
    elif [[ "$mode" == import ]]; then
        cert=$(jq -er '.cert_source' "$file") && key=$(jq -er '.key_source' "$file") || return 1
        [[ "$cert" == /* && "$key" == /* && -f "$cert" && -f "$key" && -r "$cert" && -r "$key" ]] || {
            error '原路径中的证书或私钥文件不存在或不可读。'; return 1;
        }
        cp -- "$cert" "$revision/cert.pem" && cp -- "$key" "$revision/key.pem" || return 1
    else return 1
    fi
    chmod 600 "$revision/cert.pem" "$revision/key.pem"
}

check_certificate() {
    local revision="$1" verify_name mode a b
    local -a verify_args
    verify_name=$(jq -er '.verify_name // .sni' "$revision/settings.json") && mode=$(jq -er '.verify_mode' "$revision/settings.json") || return 1
    verify_args=(-purpose sslserver)
    case "$mode" in
        pin) verify_args+=(-trusted "$revision/cert.pem" -partial_chain);;
        ca) verify_args+=(-verify_hostname "$verify_name" -untrusted "$revision/cert.pem");;
        *) error '未知证书验证方式。'; return 1;;
    esac
    if ! openssl verify "${verify_args[@]}" "$revision/cert.pem" >/dev/null; then
        error '证书有效期、用途、SNI 或信任链验证失败。'; return 1;
    fi
    a=$(openssl x509 -in "$revision/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256) || return 1
    b=$(openssl pkey -in "$revision/key.pem" -passin pass: -pubout -outform DER | openssl dgst -sha256) || return 1
    [[ "$a" == "$b" ]] || { error '证书与私钥不匹配。'; return 1; }
}

fingerprint() {
    local fp
    fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256) || return 1
    fp="${fp#*=}"; fp="${fp//:/}"
    [[ "$fp" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s' "$fp"
}

surge_config() {
    local revision="$1" fp=''
    validate_settings "$revision/settings.json" || return 1
    if [[ "$(jq -r '.verify_mode' "$revision/settings.json")" == pin ]]; then
        fp=$(fingerprint "$revision/cert.pem") || return 1
    fi
    jq -r --arg fp "$fp" '
        . as $s | "[Proxy]",
        (.users[] | "Volto-" + .username + " = masque, " +
        $s.endpoint +
        ", " + ($s.port|tostring) + ", sni=" + $s.sni +
        (if $s.verify_mode == "pin" then ", server-cert-fingerprint-sha256=" + $fp
         else ", server-cert-verify-name=" + ($s.verify_name // $s.sni) end) +
        ", username=" + .username + ", password=" + .password)
    ' "$revision/settings.json"
}

seal_revision() {
    local revision="$1" binary="$2"
    render_config "$revision/settings.json" "$revision" > "$revision/config.toml" || return 1
    check_certificate "$revision" || return 1
    "$binary" --check-config --config "$revision/config.toml" || return 1
    surge_config "$revision" > "$revision/surge.conf" || return 1
    chown root:"$VOLTO_USER" "$revision" "$revision/config.toml" "$revision/cert.pem" "$revision/key.pem" &&
        chmod 750 "$revision" && chmod 640 "$revision/config.toml" "$revision/cert.pem" "$revision/key.pem" &&
        chown root:root "$revision/settings.json" "$revision/surge.conf" &&
        chmod 600 "$revision/settings.json" "$revision/surge.conf"
}

config_consistent() {
    local revision="$1"
    render_config "$revision/settings.json" "$revision" > "$VOLTO_WORK/expected.toml" || return 1
    cmp -s "$VOLTO_WORK/expected.toml" "$revision/config.toml" || {
        error '检测到手动修改 config.toml。请先保存改动，并使其与 settings.json 一致后再管理。'; return 1;
    }
}

service_healthy() {
    local revision="$1" port pid sockets i family=inet
    port=$(jq -er '.port' "$revision/settings.json") || return 1
    [[ "$(jq -r '.listen_address' "$revision/settings.json")" == '[::]' ]] && family=inet6
    for ((i=0; i<25; i++)); do
        if systemctl is-active --quiet "$VOLTO_SERVICE" &&
            pid=$(systemctl show -p MainPID --value "$VOLTO_SERVICE") &&
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] &&
            sockets=$(ss -H -lunp -f "$family" "sport = :$port") && [[ "$sockets" == *"pid=$pid,"* ]]; then
            return 0
        fi
        (( i < 24 )) && sleep 0.2
    done
    return 1
}

service_hint() {
    warn "请查看：journalctl -u $VOLTO_SERVICE -n 50 --no-pager"
}

recover_transaction() {
    local tx="$VOLTO_DIR/.transaction" old active
    [[ -f "$tx/ready" ]] || return 0
    is_managed || return 1
    old=$(<"$tx/old_revision"); active=$(<"$tx/was_active")
    managed_revision "$old" && [[ "$active" == 0 || "$active" == 1 ]] || return 1
    warn '正在恢复上一次操作前的内核和配置...'
    systemctl stop "$VOLTO_SERVICE" || return 1
    if [[ -f "$tx/volto" ]]; then atomic_install "$tx/volto" "$VOLTO_BIN" 755 || return 1; fi
    atomic_link "$old" || return 1
    systemctl reset-failed "$VOLTO_SERVICE" >/dev/null 2>&1 || true
    if [[ "$active" == 1 ]]; then
        if ! systemctl start "$VOLTO_SERVICE" || ! service_healthy "$old"; then
            error "恢复失败，备份保留在 $tx"; service_hint; return 1;
        fi
    fi
    rm -rf -- "$tx" || return 1
    ok '已恢复之前的版本及服务启停状态。'
}

apply_revision() {
    local revision="$1" binary="${2:-$VOLTO_BIN}" old active=0 tx="$VOLTO_DIR/.transaction"
    old=$(current_revision) || return 1
    config_consistent "$old" && seal_revision "$revision" "$binary" || return 1
    [[ ! -e "$tx" ]] || { error "存在未完成的事务：$tx"; return 1; }
    if [[ "$binary" == "$VOLTO_BIN" ]] && cmp -s "$old/settings.json" "$revision/settings.json" &&
        cmp -s "$old/cert.pem" "$revision/cert.pem" && cmp -s "$old/key.pem" "$revision/key.pem"; then
        discard_revision || return 1
        ok '配置没有变化，无需重启。'; return 0
    fi
    systemctl is-active --quiet "$VOLTO_SERVICE" && active=1
    mkdir -m 700 "$tx" || return 1
    if ! printf '%s\n' "$old" > "$tx/old_revision" || ! printf '%s\n' "$active" > "$tx/was_active"; then
        rm -rf -- "$tx"; return 1
    fi
    if [[ "$binary" != "$VOLTO_BIN" ]] && ! cp -- "$VOLTO_BIN" "$tx/volto"; then rm -rf -- "$tx"; return 1; fi
    touch "$tx/ready" || { rm -rf -- "$tx"; return 1; }
    if [[ "$binary" != "$VOLTO_BIN" ]] && ! atomic_install "$binary" "$VOLTO_BIN" 755; then
        return 1
    fi
    atomic_link "$revision" || return 1
    if (( active )) && ! { systemctl restart "$VOLTO_SERVICE" && service_healthy "$revision"; }; then
        error '应用后服务未正常监听，回滚本次变更。'
        return 1
    fi
    rm -f -- "$tx/ready" || return 1
    rm -rf -- "$tx" || return 1
    VOLTO_NEW=''
    prune_revisions || warn '旧配置目录未能完全清理，请检查文件权限。'
    if (( active )); then ok '配置已生效。'; else ok '配置已保存，服务保持停止状态。'; fi
}

write_unit() {
    local file="$1"
    cat > "$file" <<EOF
[Unit]
Description=volto MASQUE proxy managed by Volto.sh
Documentation=https://github.com/vcarus/volto
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$VOLTO_USER
Group=$VOLTO_USER
UMask=0077
ExecStart=$VOLTO_BIN --config $VOLTO_DIR/current/config.toml
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
LimitNOFILE=131072
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictSUIDSGID=true
LockPersonality=true
ReadOnlyPaths=$VOLTO_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

sync_certificate_timer() {
    local changed=0
    cat > "$VOLTO_WORK/cert-sync.service" <<EOF
[Unit]
Description=Sync renewed Volto certificate

[Service]
Type=oneshot
ExecStart=$VOLTO_MANAGER --renew-cert
UMask=0077
EOF
    cat > "$VOLTO_WORK/cert-sync.timer" <<EOF
[Unit]
Description=Check Volto certificate every 5 minutes

[Timer]
OnActiveSec=2min
OnUnitActiveSec=5min
Unit=$VOLTO_CERT_SERVICE

[Install]
WantedBy=timers.target
EOF
    if ! cmp -s "$VOLTO_WORK/cert-sync.service" "$VOLTO_CERT_UNIT"; then
        atomic_install "$VOLTO_WORK/cert-sync.service" "$VOLTO_CERT_UNIT" 644 || return 1
        changed=1
    fi
    if ! cmp -s "$VOLTO_WORK/cert-sync.timer" "$VOLTO_CERT_TIMER_UNIT"; then
        atomic_install "$VOLTO_WORK/cert-sync.timer" "$VOLTO_CERT_TIMER_UNIT" 644 || return 1
        changed=1
    fi
    if (( changed )); then systemctl daemon-reload || return 1; fi
    systemctl enable --now "$VOLTO_CERT_TIMER"
}

firewall_hint() {
    local port="$1"
    warn "请在系统防火墙和服务商安全组放行入口地址对应的 IPv4 / IPv6 UDP ${port}。"
    info 'IPv6 入口需要客户端网络支持 IPv6；本地监听成功不代表公网可达。'
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        info "当前 UFW 已启用，可执行：sudo ufw allow $port/udp"
    fi
}

install_service() {
    local port endpoint username password congestion listen load
    if [[ -e "$VOLTO_DIR" || -L "$VOLTO_DIR" || -e "$VOLTO_BIN" || -L "$VOLTO_BIN" ||
          -e "$VOLTO_UNIT" || -L "$VOLTO_UNIT" || -e "$VOLTO_MANAGER" || -L "$VOLTO_MANAGER" ||
          -e "$VOLTO_CERT_UNIT" || -L "$VOLTO_CERT_UNIT" || -e "$VOLTO_CERT_TIMER_UNIT" || -L "$VOLTO_CERT_TIMER_UNIT" ]]; then
        error '检测到已有 volto 文件，请使用原管理方式或先备份卸载。'; return 1
    fi
    load=$(systemctl show -p LoadState --value "$VOLTO_SERVICE") || return 1
    [[ "$load" == 'not-found' ]] || { error '已存在同名 systemd 服务，已取消安装。'; return 1; }
    if getent passwd "$VOLTO_USER" >/dev/null || getent group "$VOLTO_USER" >/dev/null; then
        error '已存在 volto 用户或组，已取消安装以避免共用身份。'; return 1
    fi
    prepare_release && download_release || return 1
    port=$(prompt_port) || return 1
    endpoint=$(detect_endpoint) || endpoint=$(prompt_value '服务器公网 IP 或域名' '' valid_endpoint) || return 1
    listen=$(default_listener "$endpoint") || return 1
    congestion=$(choose_congestion '' "$VOLTO_WORK/release/volto") || return 1
    username=$(prompt_value '用户名' 'surge' valid_user) && password=$(prompt_password) || return 1
    printf '%s' "$password" > "$VOLTO_WORK/password" || return 1
    jq -n --argjson port "$port" --arg endpoint "$endpoint" --arg listen "$listen" \
        --arg username "$username" --arg cc "$congestion" --rawfile password "$VOLTO_WORK/password" \
        '{schema:1,port:$port,endpoint:$endpoint,listen_address:$listen,
          sni:"volto.internal",certificate_mode:"selfsigned",verify_mode:"pin",cert_source:"",key_source:"",
          users:[{username:$username,password:$password}],congestion_control:$cc,mtu_upper_bound:1436,ip_family_preference:"ipv4",max_connections:256}' \
        > "$VOLTO_WORK/settings.json" || return 1
    choose_certificate "$VOLTO_WORK/settings.json" || return 1
    install -d -m 750 "$VOLTO_DIR" || return 1
    printf '%s\n' "$VOLTO_MARKER" > "$VOLTO_DIR/.managed" || return 1
    VOLTO_INSTALLING=1
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$VOLTO_USER" || return 1
    chown root:"$VOLTO_USER" "$VOLTO_DIR" && install -d -o root -g "$VOLTO_USER" -m 750 "$VOLTO_DIR/revisions" || return 1
    new_revision && install -m 600 "$VOLTO_WORK/settings.json" "$VOLTO_NEW/settings.json" &&
        make_certificate "$VOLTO_NEW" && seal_revision "$VOLTO_NEW" "$VOLTO_WORK/release/volto" || return 1
    write_unit "$VOLTO_WORK/volto.service" &&
        atomic_install "$VOLTO_WORK/release/volto" "$VOLTO_BIN" 755 &&
        atomic_install "$VOLTO_WORK/volto.service" "$VOLTO_UNIT" 644 &&
        atomic_install "$VOLTO_SOURCE" "$VOLTO_MANAGER" 755 && atomic_link "$VOLTO_NEW" || return 1
    if ! systemctl daemon-reload || ! systemctl enable "$VOLTO_SERVICE" ||
        ! systemctl start "$VOLTO_SERVICE" || ! service_healthy "$VOLTO_NEW" || ! sync_certificate_timer; then
        error '安装后服务启动失败。'; service_hint; return 1;
    fi
    VOLTO_INSTALLING=0; VOLTO_NEW=''
    ok "volto $VOLTO_VERSION 安装完成。以后执行：sudo volto-manager"
    firewall_hint "$port"
    show_surge
}

cleanup_install() {
    local unit load stopped=1
    (( VOLTO_INSTALLING )) || return 0
    is_managed || return 1
    warn '撤销未完成的首次安装...'
    systemctl daemon-reload >/dev/null 2>&1 || true
    for unit in "$VOLTO_CERT_TIMER" "$VOLTO_CERT_SERVICE" "$VOLTO_SERVICE"; do
        if load=$(systemctl show -p LoadState --value "$unit"); then
            if [[ "$load" != not-found ]]; then systemctl stop "$unit" || stopped=0; fi
        else stopped=0
        fi
    done
    (( stopped )) || { error '服务未能完全停止，已保留安装文件，请重试卸载。'; return 1; }
    systemctl disable "$VOLTO_CERT_TIMER" "$VOLTO_SERVICE" >/dev/null 2>&1 || true
    rm -f -- "$VOLTO_UNIT" "$VOLTO_BIN" "$VOLTO_MANAGER" "$VOLTO_CERT_UNIT" "$VOLTO_CERT_TIMER_UNIT" || return 1
    rm -f -- "${VOLTO_UNIT%/*}/multi-user.target.wants/$VOLTO_SERVICE" \
        "${VOLTO_UNIT%/*}/timers.target.wants/$VOLTO_CERT_TIMER" || return 1
    systemctl daemon-reload || return 1
    systemctl reset-failed "$VOLTO_SERVICE" "$VOLTO_CERT_SERVICE" "$VOLTO_CERT_TIMER" >/dev/null 2>&1 || true
    if getent passwd "$VOLTO_USER" >/dev/null; then userdel "$VOLTO_USER" || return 1; fi
    if getent group "$VOLTO_USER" >/dev/null; then groupdel "$VOLTO_USER" || return 1; fi
    rm -rf -- "$VOLTO_DIR" || return 1
    VOLTO_INSTALLING=0; VOLTO_NEW=''
}

show_surge() {
    local revision
    require_install && revision=$(current_revision) && config_consistent "$revision" || return 1
    info '复制下面的节点行到现有 [Proxy]，再将节点名加入你的策略组：'
    surge_config "$revision" || return 1
    info "完整片段：$revision/surge.conf (含密码，仅 root 可读)"
}

show_status() {
    local revision
    require_install && revision=$(current_revision) || return 1
    systemctl --no-pager --full status "$VOLTO_SERVICE" || true
    printf '\n内核：'; binary_version "$VOLTO_BIN"; printf '\n'
    jq 'del(.users[].password)' "$revision/settings.json" || return 1
    info 'Surge 节点配置：sudo volto-manager --show-surge'
    openssl x509 -in "$revision/cert.pem" -noout -enddate
}

check_install() {
    local revision
    require_install && revision=$(current_revision) && config_consistent "$revision" &&
        check_certificate "$revision" &&
        "$VOLTO_BIN" --check-config --config "$revision/config.toml" || return 1
    ok '配置与证书检查通过。'
}

modify_port() {
    local old port
    old=$(current_revision) || return 1
    port=$(prompt_port "$(jq -r '.port' "$old/settings.json")") || return 1
    new_revision && json_edit "$VOLTO_NEW/settings.json" --argjson port "$port" '.port=$port' &&
        apply_revision "$VOLTO_NEW" || return 1
    firewall_hint "$port"; show_surge
}

modify_endpoint() {
    local old endpoint listen current_ep
    old=$(current_revision) || return 1
    current_ep=$(jq -r '.endpoint // empty' "$old/settings.json" 2>/dev/null || true)
    endpoint=$(detect_endpoint) || endpoint=$(prompt_value '服务器公网 IP 或域名' "$current_ep" valid_endpoint) || return 1
    listen=$(default_listener "$endpoint") || return 1
    new_revision && json_edit "$VOLTO_NEW/settings.json" --arg value "$endpoint" --arg listen "$listen" \
        '.endpoint=$value | .listen_address=$listen' &&
        apply_revision "$VOLTO_NEW" && show_surge
}

modify_auth() {
    local old current_user current_password username password
    old=$(current_revision) || return 1
    current_user=$(jq -er '.users[0].username' "$old/settings.json") &&
        current_password=$(jq -er '.users[0].password' "$old/settings.json") || return 1
    username=$(prompt_value '用户名' "$current_user" valid_user) &&
        password=$(prompt_password "$current_password") || return 1
    if [[ "$username" == "$current_user" && "$password" == "$current_password" ]]; then
        ok '认证没有变化，无需重启。'
        show_surge; return
    fi
    printf '%s' "$password" > "$VOLTO_WORK/password" || return 1
    new_revision && json_edit "$VOLTO_NEW/settings.json" --arg user "$username" \
        --rawfile password "$VOLTO_WORK/password" \
        '.users[0].username=$user | .users[0].password=$password' && apply_revision "$VOLTO_NEW" || return 1
    info '请替换 Surge 中的节点配置，并重新连接。'
    show_surge
}

modify_certificate() {
    local current_sni='' sni=''
    new_revision && choose_certificate "$VOLTO_NEW/settings.json" || return 1
    if (( VOLTO_CERT_CHANGED )); then
        make_certificate "$VOLTO_NEW" || return 1
    else
        current_sni=$(jq -er '.sni' "$VOLTO_NEW/settings.json") || return 1
        sni=$(prompt_value 'Surge SNI (保留当前证书)' "$current_sni" valid_domain) || return 1
        if [[ "$sni" != "$current_sni" ]]; then
            json_edit "$VOLTO_NEW/settings.json" --arg sni "$sni" \
                '.verify_name=(.verify_name // .sni) | .sni=$sni' || return 1
        fi
    fi
    apply_revision "$VOLTO_NEW" || return 1
    if (( VOLTO_CERT_CHANGED )); then warn '请替换 Surge 中的整行节点配置，并断开旧连接后重新连接。'; fi
    if [[ -n "$sni" && "$sni" != "$current_sni" ]]; then
        info '证书和指纹保持不变。请更新 Surge 节点的 sni，并重新连接。'
    fi
    show_surge
}

renew_certificate() {
    local old mode verify_mode
    require_install && old=$(current_revision) || return 1
    mode=$(jq -r '.certificate_mode' "$old/settings.json") || return 1
    [[ "$mode" == import ]] || return 0
    new_revision && make_certificate "$VOLTO_NEW" || return 1
    if cmp -s "$old/cert.pem" "$VOLTO_NEW/cert.pem" && cmp -s "$old/key.pem" "$VOLTO_NEW/key.pem"; then
        config_consistent "$old" && check_certificate "$old" && discard_revision || return 1
        ok '来源证书没有变化。'; return 0
    fi
    verify_mode=$(jq -er '.verify_mode' "$old/settings.json") || return 1
    apply_revision "$VOLTO_NEW" || return 1
    if [[ "$verify_mode" == pin ]]; then
        warn '证书指纹已变化，请执行 volto-manager --show-surge 更新客户端。'
    fi
}

# 返回此版本另行提供的 BBR 变体。1.8 起只提供 bbr、cubic 和 newreno。
bbr_variant() {
    if ! version_newer 1.8.0 "$1"; then return 0; fi
    if ! version_newer 1.2.0 "$1"; then printf 'bbr-uncapped'
    elif ! version_newer 1.1.0 "$1"; then printf 'bbr-capped'
    fi
}

compatible_congestion() {
    local current="$1" variant="$2"
    if [[ ( "$current" == bbr-capped || "$current" == bbr-uncapped ) && "$current" != "$variant" ]]; then
        current=bbr
    fi
    printf '%s' "$current"
}

choose_congestion() {
    local current="$1" binary="${2:-$VOLTO_BIN}" option version variant
    local -a choices=('1. BBR' '2. Cubic' '3. NewReno')
    version=$(binary_version "$binary") || return 1
    variant=$(bbr_variant "$version") || return 1
    case "$variant" in
        bbr-uncapped) choices+=('4. BBR-Uncapped');;
        bbr-capped) choices+=('4. BBR-Capped');;
    esac
    if [[ -z "$current" ]]; then
        current=bbr
        [[ "$variant" != bbr-uncapped ]] || current=bbr-uncapped
    else
        current=$(compatible_congestion "$current" "$variant")
    fi
    menu_items "${choices[@]}" >&2
    read -r -p "$(prompt_text "拥塞控制 [1–${#choices[@]}，回车使用 $current]: ")" option || return 1
    case "$option" in
        '') printf '%s' "$current";;
        1) printf 'bbr';;
        2) printf 'cubic';;
        3) printf 'newreno';;
        4) if [[ -n "$variant" ]]; then printf '%s' "$variant"; else error '无效选项。'; fi;;
        *) error '无效选项。';;
    esac
}

modify_transport() {
    local congestion max old current_max family option default
    old=$(current_revision) || return 1
    congestion=$(jq -er '.congestion_control' "$old/settings.json") || return 1
    congestion=$(choose_congestion "$congestion") || return 1
    family=$(jq -er '.ip_family_preference' "$old/settings.json") || return 1
    case "$family" in system) default=1;; ipv4) default=2;; ipv6) default=3;; *) return 1;; esac
    menu_items '1. 遵循系统设置' '2. 优先 IPv4 (默认)' '3. 优先 IPv6'
    read -r -p "$(prompt_text "出站 IP 优先级 [回车保留 $default]: ")" option || return 1
    case "${option:-$default}" in
        1) family=system;; 2) family=ipv4;; 3) family=ipv6;;
        *) error '无效选项。'; return 1;;
    esac
    current_max=$(jq -er '.max_connections' "$old/settings.json") || return 1
    read -r -p "$(prompt_text "最大 QUIC 连接数 [1–256，回车保留 $current_max]: ")" max || return 1
    max="${max:-$current_max}"
    if [[ ! "$max" =~ ^[1-9][0-9]{0,2}$ ]] || (( max > 256 )); then
        error '连接数必须为 1–256。'; return 1
    fi
    new_revision && json_edit "$VOLTO_NEW/settings.json" --arg cc "$congestion" --arg family "$family" --argjson max "$max" \
        '.congestion_control=$cc | .ip_family_preference=$family | .max_connections=$max' &&
        apply_revision "$VOLTO_NEW"
}

service_action() {
    local action="$1" revision
    require_install && revision=$(current_revision) || return 1
    if [[ "$action" == stop ]]; then systemctl stop "$VOLTO_SERVICE" && ok '服务已停止。'; return; fi
    check_install && systemctl "$action" "$VOLTO_SERVICE" && service_healthy "$revision" && ok '服务正常运行。'
}

update_core() {
    local current settings previous selected variant
    require_install && current=$(binary_version "$VOLTO_BIN") && prepare_release || return 1
    info "当前：${current}；最新正式版：$VOLTO_VERSION"
    if ! version_newer "$VOLTO_VERSION" "$current"; then ok '无需更新，不会自动降级。'; return 0; fi
    ask_yes "更新到正式版 $VOLTO_VERSION?" || return 0
    download_release && new_revision || return 1
    settings="$VOLTO_NEW/settings.json"
    previous=$(jq -er '.congestion_control' "$settings") || return 1
    variant=$(bbr_variant "$VOLTO_VERSION") || return 1
    selected=$(compatible_congestion "$previous" "$variant")
    if [[ "$selected" != "$previous" ]]; then
        info "新内核的拥塞控制将由 $previous 调整为 $selected。"
        json_edit "$settings" --arg cc "$selected" '.congestion_control=$cc' || return 1
    fi
    apply_revision "$VOLTO_NEW" "$VOLTO_WORK/release/volto" || return 1
    ok "内核已更新到 ${VOLTO_VERSION}。"
}

uninstall_service() {
    local unit load file
    is_managed || { error '未找到本脚本管理的安装。'; return 1; }
    ask_yes '删除服务、配置、证书及旧版自动备份? 不创建备份' || return 0
    for unit in "$VOLTO_CERT_TIMER" "$VOLTO_CERT_SERVICE" "$VOLTO_SERVICE"; do
        load=$(systemctl show -p LoadState --value "$unit") || return 1
        if [[ "$load" != not-found ]]; then
            systemctl stop "$unit" || { error "停止 $unit 失败，尚未删除文件。"; return 1; }
        fi
    done
    for unit in "$VOLTO_CERT_TIMER" "$VOLTO_SERVICE"; do
        file="${VOLTO_UNIT%/*}/$unit"
        if [[ -e "$file" || -L "$file" ]]; then
            systemctl disable "$unit" || { error "禁用 $unit 失败，尚未删除文件。"; return 1; }
        fi
    done
    if getent passwd "$VOLTO_USER" >/dev/null; then
        userdel "$VOLTO_USER" || { error '系统用户未移除，请检查是否有其他进程使用后重试卸载。'; return 1; }
    fi
    if getent group "$VOLTO_USER" >/dev/null; then
        groupdel "$VOLTO_USER" || { error '系统组未移除，请检查后重试卸载。'; return 1; }
    fi
    if ! rm -f -- "$VOLTO_UNIT" "$VOLTO_BIN" "$VOLTO_MANAGER" "$VOLTO_CERT_UNIT" "$VOLTO_CERT_TIMER_UNIT" ||
        ! rm -f -- "${VOLTO_UNIT%/*}/multi-user.target.wants/$VOLTO_SERVICE" \
            "${VOLTO_UNIT%/*}/timers.target.wants/$VOLTO_CERT_TIMER" ||
        ! rm -rf -- "$VOLTO_UNIT.d" "$VOLTO_CERT_UNIT.d" "$VOLTO_CERT_TIMER_UNIT.d" ||
        ! systemctl daemon-reload; then
        error '卸载未完成，请检查上方错误后重试。'; return 1;
    fi
    systemctl reset-failed "$VOLTO_SERVICE" "$VOLTO_CERT_SERVICE" "$VOLTO_CERT_TIMER" >/dev/null 2>&1 || true
    if ! rm -rf -- "$VOLTO_LEGACY_BACKUP_ROOT" "$VOLTO_DIR"; then
        error '配置或旧版备份未能完全删除，请检查上方错误。'; return 1;
    fi
    for file in "$VOLTO_UNIT" "$VOLTO_BIN" "$VOLTO_MANAGER" "$VOLTO_CERT_UNIT" "$VOLTO_CERT_TIMER_UNIT" \
        "$VOLTO_DIR" "$VOLTO_LEGACY_BACKUP_ROOT"; do
        [[ ! -e "$file" && ! -L "$file" ]] || { error "卸载仍有残留：$file"; return 1; }
    done
    # All service mutations are complete. A later process may create a fresh lock.
    VOLTO_WRITING=0
    rm -f -- "$VOLTO_LOCK" || return 1
    ok '服务、定时器、用户、内核、管理脚本、配置、证书及旧版自动备份已移除，未创建备份。'
    warn '手动创建的防火墙规则请按需移除。'
}

discard_revision() {
    local current=''
    [[ -n "$VOLTO_NEW" ]] || return 0
    current=$(current_revision) || true
    if [[ "$VOLTO_NEW" != "$current" && ! -f "$VOLTO_DIR/.transaction/ready" ]] && managed_revision "$VOLTO_NEW"; then
        rm -rf -- "$VOLTO_NEW" || return 1
    fi
    VOLTO_NEW=''
}

prune_revisions() {
    local current revision
    [[ ! -e "$VOLTO_DIR/.transaction" ]] || return 0
    current=$(current_revision) || return 1
    for revision in "$VOLTO_DIR"/revisions/rev.*; do
        [[ "$revision" != "$current" ]] || continue
        managed_revision "$revision" || continue
        rm -rf -- "$revision" || return 1
    done
}

after_action() {
    (( $1 == 0 )) || warn '本次操作未完成。'
    pause_menu
}

config_menu() {
    local option
    while true; do
        screen
        menu_title '✦ Volto 配置管理 ✦'
        menu_items '1. 修改 UDP 端口' '2. 更换证书 / SNI' \
            '3. 拥塞控制 / IP 优先级 / QUIC 连接数' '4. 自动刷新服务器地址' \
            '5. 更改认证 (用户名 / 密码)' '0. 返回上级'
        read -r -p "$(prompt_text '✦ Steins Gate ✦ : ')" option || return 0
        option=$(norm_choice "$option")
        case "$option" in
            1) run_action modify_port;; 2) run_action modify_certificate;;
            3) run_action modify_transport;; 4) run_action modify_endpoint;;
            5) run_action modify_auth;;
            0) return 0;; *) warn '无效选项。'; pause_menu; continue;;
        esac
        after_action "$?"
    done
}

service_menu() {
    local option
    require_install || return 1
    while true; do
        screen
        menu_title '✦ Volto 服务管理 ✦'
        menu_items '1. 查看状态 / 配置 (密码隐藏)' '2. 修改配置' \
            '3. 停止服务' '4. 重启服务' '5. 启动服务' '0. 返回主页'
        read -r -p "$(prompt_text '✦ Steins Gate ✦ : ')" option || return 0
        option=$(norm_choice "$option")
        case "$option" in
            1) run_action show_status;; 2) config_menu; continue;; 3) run_action service_action stop;;
            4) run_action service_action restart;; 5) run_action service_action start;;
            0) return 0;; *) warn '无效选项。'; pause_menu; continue;;
        esac
        after_action "$?"
    done
}

main_menu() {
    local option
    while true; do
        screen
        menu_title "✦ Volto_Ver.${VOLTO_MANAGER_VERSION} ✦"
        menu_items '1. 安装服务' '2. 管理服务' '3. 更新内核' '4. 删除服务' "${VOLTO_EXIT_TEXT:-0. 退出脚本}"
        read -r -p "$(prompt_text '✦ Steins Gate ✦ : ')" option || return 0
        option=$(norm_choice "$option")
        case "$option" in
            1) run_action install_service;;
            2) if require_install; then service_menu; continue; fi; false;;
            3) run_action update_core;;
            4) run_action uninstall_service;; 0) return 0;; *) warn '无效选项。'; pause_menu; continue;;
        esac
        after_action "$?"
    done
}

dependencies() {
    local command package
    local -a missing=()
    for command in curl jq openssl tar sha256sum ss flock useradd; do
        command -v "$command" >/dev/null 2>&1 && continue
        case "$command" in sha256sum) package=coreutils;; ss) package=iproute2;; flock) package=util-linux;; useradd) package=passwd;; *) package="$command";; esac
        missing+=("$package")
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    (( ${#missing[@]} )) || return 0
    info "安装依赖：${missing[*]}"
    ( umask 022; DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" )
}

new_workspace() {
    local directory="${VOLTO_BIN%/*}"
    [[ -d "$directory" ]] || install -d -m 755 "$directory" || return 1
    VOLTO_WORK=$(mktemp -d "$directory/.volto-manager.XXXXXXXX")
}

finish() {
    local result=$?
    trap - EXIT INT TERM HUP
    if (( VOLTO_WRITING )); then
        if [[ "$VOLTO_ACTION" != uninstall_service ]]; then
            if (( VOLTO_INSTALLING )); then cleanup_install || result=1; fi
            if [[ -f "$VOLTO_DIR/.transaction/ready" ]]; then recover_transaction || result=1; fi
            if (( VOLTO_INSTALLING == 0 )); then discard_revision || result=1; fi
        fi
        flock -u 9 || result=1
    fi
    if [[ "$VOLTO_WORK" == "${VOLTO_BIN%/*}/.volto-manager."* && -d "$VOLTO_WORK" && ! -L "$VOLTO_WORK" ]]; then
        rm -rf -- "$VOLTO_WORK"
    fi
    exit "$result"
}

run_action() (
    VOLTO_ACTION="$1"
    case "$1" in
        show_status|show_surge|check_install) ;;
        *)
            [[ ! -L "$VOLTO_LOCK" ]] || return 1
            exec 9>"$VOLTO_LOCK" || return 1
            flock -n 9 || { error '另一个窗口正在修改，请稍后再试。'; return 1; }
            [[ /proc/self/fd/9 -ef "$VOLTO_LOCK" ]] || { error '安装状态刚刚变化，请重新执行操作。'; return 1; }
            VOLTO_WRITING=1
            ;;
    esac
    if (( VOLTO_WRITING )) && [[ "$VOLTO_ACTION" != uninstall_service ]] &&
        is_managed && [[ -d "$VOLTO_DIR/.transaction" ]]; then
        if [[ -f "$VOLTO_DIR/.transaction/ready" ]]; then recover_transaction || return 1
        else rm -rf -- "$VOLTO_DIR/.transaction" || return 1
        fi
    fi
    new_workspace || return 1
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if (( VOLTO_WRITING )) && [[ "$VOLTO_ACTION" != uninstall_service ]]; then refresh_manager || return 1; fi
    "$@"
)

cert_timer_ready() {
    [[ -f "$VOLTO_CERT_UNIT" && -f "$VOLTO_CERT_TIMER_UNIT" && -x "$VOLTO_MANAGER" ]] &&
        grep -Fqx "ExecStart=$VOLTO_MANAGER --renew-cert" "$VOLTO_CERT_UNIT" 2>/dev/null &&
        systemctl is-enabled --quiet "$VOLTO_CERT_TIMER" 2>/dev/null &&
        systemctl is-active --quiet "$VOLTO_CERT_TIMER" 2>/dev/null
}

main() {
    local action="${1:---menu}"
    case "$action" in
        --help|-h) usage; return 0;; --version) printf '%s\n' "$VOLTO_MANAGER_VERSION"; return 0;;
        --menu|--status|--show-surge|--check|--renew-cert) ;; *) usage; return 1;;
    esac
    (( $# <= 1 )) || { usage; return 1; }
    [[ "$(uname -s)" == Linux && "$EUID" -eq 0 ]] || { error '请在 Linux 服务器以 root 或 sudo 运行。'; return 1; }
    command -v apt-get >/dev/null && command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || {
        error '需要 Debian/Ubuntu 和运行中的 systemd。'; return 1;
    }
    get_arch >/dev/null || return 1
    umask 077
    set -o pipefail
    export LC_ALL=C.UTF-8
    export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [[ -t 2 ]]; then RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; PLAIN=$'\033[0m'; fi
    dependencies || return 1
    case "$action" in
        --menu)
            if require_install >/dev/null 2>&1 && ! cert_timer_ready; then
                run_action sync_certificate_timer || warn '证书自动同步未能启用，请检查上方错误。'
            fi
            main_menu;;
        --status) run_action show_status;; --show-surge) run_action show_surge;;
        --check) run_action check_install;; --renew-cert) run_action renew_certificate;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
__ZERO_VOLTO_MANAGER_SCRIPT_V1__
}

configure_volto() {
    local rc
    (
        local volto_stage
        umask 077
        volto_stage=$(mktemp -d /tmp/zero-volto.XXXXXXXX) || exit 1
        trap 'rm -f -- "$volto_stage/Volto.sh"; rmdir -- "$volto_stage"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        volto_emit_manager_script > "$volto_stage/Volto.sh" || exit 1
        VOLTO_EXIT_TEXT='0. 返回主页' bash "$volto_stage/Volto.sh" --menu
    )
    rc=$?
    (( rc == 0 )) || press_any_key_to_continue "Volto 已退出，按任意键返回菜单..."
    return 0
}
# END ZERO_VOLTO_MODULE

reboot_system() {
    local confirm
    read -r -p "${YELLOW}确认立即重启 VPS 吗? [y/N]: ${PLAIN}" confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    echo -e "${YELLOW}系统将在 3 秒后重新启动...${PLAIN}"
    sleep 3
    reboot_vps
}

run_subshell_menu() {
    ( "$1" ) || press_any_key_to_continue "${2} 已退出，按任意键返回菜单..."
}

FIREWALL_RULE_DIR="/etc/iptables"
FIREWALL_RULES_V4="$FIREWALL_RULE_DIR/zero.rules.v4"
FIREWALL_RULES_V6="$FIREWALL_RULE_DIR/zero.rules.v6"
ZERO_FIREWALL_SERVICE="/etc/systemd/system/zero-firewall-persistent.service"
ZERO_FIREWALL_SERVICE_NAME="zero-firewall-persistent.service"
ZERO_FW_CHAIN="ZERO_INPUT"
ZERO_PORT_JUMP_CHAIN="ZERO_PORT_JUMP"
FIREWALL_LAST_BACKUP=""

firewall_exec_quiet() {
    local cmd="$1"
    shift
    "$cmd" -w 3 "$@" >/dev/null 2>&1
}

firewall_exec() {
    local cmd="$1" output
    shift
    if output=$("$cmd" -w 3 "$@" 2>&1); then
        return 0
    fi
    [[ -n "$output" ]] && echo -e "${RED}[!] ${cmd} $* 失败: ${output}${PLAIN}"
    return 1
}

firewall_supports_table() {
    local cmd="$1" table="$2" probe_chain="INPUT"
    command -v "$cmd" >/dev/null 2>&1 || return 1
    case "$table" in
        nat)    probe_chain="PREROUTING" ;;
        mangle) probe_chain="FORWARD" ;;
    esac
    firewall_exec_quiet "$cmd" -t "$table" -S "$probe_chain"
}

firewall_chain_exists() {
    firewall_exec_quiet "$1" -t "$2" -S "$3"
}

firewall_ensure_chain() {
    firewall_chain_exists "$1" "$2" "$3" || firewall_exec "$1" -t "$2" -N "$3"
}

firewall_flush_chain() {
    firewall_chain_exists "$1" "$2" "$3" || return 0
    firewall_exec "$1" -t "$2" -F "$3"
}

firewall_delete_chain() {
    firewall_chain_exists "$1" "$2" "$3" || return 0
    firewall_flush_chain "$1" "$2" "$3" && firewall_exec "$1" -t "$2" -X "$3"
}

firewall_rule_exists() {
    local cmd="$1" table="$2" chain="$3"
    shift 3
    firewall_exec_quiet "$cmd" -t "$table" -C "$chain" "$@"
}

firewall_ensure_rule_absent() {
    local cmd="$1" table="$2" chain="$3"
    shift 3
    while firewall_rule_exists "$cmd" "$table" "$chain" "$@"; do
        firewall_exec "$cmd" -t "$table" -D "$chain" "$@" || return 1
    done
}

firewall_ensure_rule_present() {
    local cmd="$1" table="$2" chain="$3"
    shift 3
    firewall_rule_exists "$cmd" "$table" "$chain" "$@" || firewall_exec "$cmd" -t "$table" -A "$chain" "$@"
}

firewall_has_rules() {
    firewall_chain_exists "$1" "$2" "$3" || return 1
    "$1" -t "$2" -S "$3" 2>/dev/null | grep -q '^-A '
}

firewall_prepare_tools() {
    if (command -v iptables >/dev/null 2>&1 || command -v ip6tables >/dev/null 2>&1) && command -v ip >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}[!] 未检测到完整的防火墙工具(iptables/ip6tables/ip),正在尝试安装...${PLAIN}"
    if ! pkg_install iptables iproute2; then
        echo -e "${RED}[!] 无法自动安装防火墙工具,请手动安装 iptables/ip6tables 和 iproute2${PLAIN}"
        return 1
    fi

    if (! command -v iptables >/dev/null 2>&1 && ! command -v ip6tables >/dev/null 2>&1) || ! command -v ip >/dev/null 2>&1; then
        echo -e "${RED}[!] 安装完成后仍缺少可用的防火墙工具或 ip 命令${PLAIN}"
        return 1
    fi
}

firewall_render_restore_service() {
    cat <<EOF
[Unit]
Description=Restore Zero firewall rules
DefaultDependencies=no
Before=network-pre.target shutdown.target
Wants=network-pre.target
After=local-fs.target systemd-modules-load.service
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'set -e; if [ -s "$FIREWALL_RULES_V4" ]; then iptables-restore < "$FIREWALL_RULES_V4"; fi; if [ -s "$FIREWALL_RULES_V6" ] && [ -d /proc/sys/net/ipv6 ]; then ip6tables-restore < "$FIREWALL_RULES_V6"; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

firewall_setup_persistence() {
    mkdir -p "$FIREWALL_RULE_DIR" || return 1

    if command -v systemctl >/dev/null 2>&1; then
        local expected_unit current_unit=""
        expected_unit=$(firewall_render_restore_service)
        [[ -f "$ZERO_FIREWALL_SERVICE" ]] && current_unit=$(<"$ZERO_FIREWALL_SERVICE")
        if [[ "$current_unit" == "$expected_unit" ]] &&
           systemctl is-enabled --quiet "$ZERO_FIREWALL_SERVICE_NAME" 2>/dev/null; then
            return 0
        fi
        printf '%s\n' "$expected_unit" > "$ZERO_FIREWALL_SERVICE" || return 1
        systemctl daemon-reload >/dev/null 2>&1 && systemctl enable "$ZERO_FIREWALL_SERVICE_NAME" >/dev/null 2>&1
        return
    fi

    command -v netfilter-persistent >/dev/null 2>&1 || command -v service >/dev/null 2>&1
}

firewall_save_rule_file() {
    local command="$1" target="$2" temp
    temp=$(mktemp "${target}.XXXXXX") || return 1
    if "$command" > "$temp" 2>/dev/null && mv -f "$temp" "$target"; then
        return 0
    fi
    rm -f "$temp"
    return 1
}

firewall_family_supported() {
    firewall_supports_table "$1" filter || firewall_supports_table "$1" nat
}

firewall_sync_saved_rules_if_enabled() {
    if [[ -s "$FIREWALL_RULES_V4" ]] && command -v iptables-save >/dev/null 2>&1 && firewall_family_supported iptables; then
        firewall_save_rule_file iptables-save "$FIREWALL_RULES_V4" || true
    fi
    if [[ -s "$FIREWALL_RULES_V6" ]] && command -v ip6tables-save >/dev/null 2>&1 && firewall_family_supported ip6tables; then
        firewall_save_rule_file ip6tables-save "$FIREWALL_RULES_V6" || true
    fi
    if command -v netfilter-persistent >/dev/null 2>&1 && [[ -s /etc/iptables/rules.v4 ]] &&
       { ! command -v systemctl >/dev/null 2>&1 || systemctl is-enabled --quiet netfilter-persistent 2>/dev/null; }; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

firewall_save_rules() {
    local persistence_ok=0 legacy_saved=0

    mkdir -p "$FIREWALL_RULE_DIR" || {
        echo -e "${RED}[!] 无法创建规则保存目录: $FIREWALL_RULE_DIR${PLAIN}"
        return 1
    }

    if firewall_family_supported iptables; then
        command -v iptables-save >/dev/null 2>&1 && firewall_save_rule_file iptables-save "$FIREWALL_RULES_V4" || {
            echo -e "${RED}[!] 保存 IPv4 规则失败${PLAIN}"
            return 1
        }
    else
        rm -f "$FIREWALL_RULES_V4"
    fi

    if firewall_family_supported ip6tables; then
        command -v ip6tables-save >/dev/null 2>&1 && firewall_save_rule_file ip6tables-save "$FIREWALL_RULES_V6" || {
            echo -e "${RED}[!] 保存 IPv6 规则失败${PLAIN}"
            return 1
        }
    else
        rm -f "$FIREWALL_RULES_V6"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        firewall_setup_persistence && persistence_ok=1 || echo -e "${RED}[!] 无法启用 systemd 防火墙自恢复服务${PLAIN}"
    elif command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && persistence_ok=1 || echo -e "${RED}[!] netfilter-persistent 保存失败${PLAIN}"
    elif command -v service >/dev/null 2>&1; then
        service iptables save >/dev/null 2>&1 && legacy_saved=1
        service ip6tables save >/dev/null 2>&1 && legacy_saved=1
        (( legacy_saved == 1 )) && persistence_ok=1 || echo -e "${YELLOW}[!] 已写入规则文件,但当前系统未检测到可用的 service 持久化入口${PLAIN}"
    fi

    if (( persistence_ok == 0 )); then
        echo -e "${YELLOW}[!] 规则当前已生效,并已保存到 ${FIREWALL_RULE_DIR},但重启后的自动恢复未完全确认${PLAIN}"
        return 1
    fi
    return 0
}

firewall_create_backup() {
    local v4_backup="" v6_backup="" created=0

    if firewall_family_supported iptables; then
        command -v iptables-save >/dev/null 2>&1 || return 1
        v4_backup=$(mktemp /tmp/zero-fw-v4.XXXXXX) || return 1
        iptables-save > "$v4_backup" 2>/dev/null || { rm -f "$v4_backup"; return 1; }
        created=1
    fi

    if firewall_family_supported ip6tables; then
        command -v ip6tables-save >/dev/null 2>&1 || { rm -f "$v4_backup"; return 1; }
        v6_backup=$(mktemp /tmp/zero-fw-v6.XXXXXX) || { rm -f "$v4_backup"; return 1; }
        ip6tables-save > "$v6_backup" 2>/dev/null || { rm -f "$v4_backup" "$v6_backup"; return 1; }
        created=1
    fi

    (( created == 1 )) || return 1
    echo "${v4_backup}|${v6_backup}"
}

firewall_restore_backup() {
    local backup="$1" v4_backup="" v6_backup="" restored=0
    IFS='|' read -r v4_backup v6_backup <<< "$backup"

    if [[ -n "$v4_backup" && -f "$v4_backup" ]]; then
        command -v iptables-restore >/dev/null 2>&1 && iptables-restore < "$v4_backup" >/dev/null 2>&1 || return 1
        restored=1
    fi

    if [[ -n "$v6_backup" && -f "$v6_backup" ]]; then
        command -v ip6tables-restore >/dev/null 2>&1 && ip6tables-restore < "$v6_backup" >/dev/null 2>&1 || return 1
        restored=1
    fi

    (( restored == 1 ))
}

firewall_remove_backup() {
    local backup="${1:-}" v4_backup="" v6_backup=""
    [[ -n "$backup" ]] || return 0
    IFS='|' read -r v4_backup v6_backup <<< "$backup"
    rm -f "$v4_backup" "$v6_backup"
}

firewall_require_backup() {
    local cancel_label="${1:-本次修改}"
    FIREWALL_LAST_BACKUP=""
    FIREWALL_LAST_BACKUP=$(firewall_create_backup) || {
        echo -e "${RED}创建防火墙备份失败,已取消${cancel_label}${PLAIN}"
        return 1
    }
}

firewall_restore_with_notice() {
    local backup="$1" restored_msg="$2" failed_msg="$3"

    if firewall_restore_backup "$backup"; then
        firewall_save_rules >/dev/null 2>&1 || true
        [[ -n "$restored_msg" ]] && echo -e "${YELLOW}${restored_msg}${PLAIN}"
        return 0
    fi
    echo -e "${RED}${failed_msg}${PLAIN}"
    echo -e "${YELLOW}备份保留在: ${backup}${PLAIN}"
    press_any_key_to_continue
    return 1
}

firewall_current_ssh_port() {
    local port sockets unit socket_listen tok prev_tok _client _client_port _server
    read -r _client _client_port _server port <<< "${SSH_CONNECTION:-}"
    if [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then
        sockets=$(ss -H -lntp "sport = :$port" 2>/dev/null) || sockets=''
        if [[ "$sockets" == *'"sshd"'* ]]; then
            printf '%s\n' "$port"
            return 0
        elif [[ "$sockets" == *'"systemd"'* ]]; then
            for unit in ssh.socket sshd.socket; do
                systemctl is-active --quiet "$unit" 2>/dev/null || continue
                socket_listen=$(systemctl show -p Listen --value "$unit" 2>/dev/null) || continue
                prev_tok=""
                for tok in $socket_listen; do
                    if [[ "$tok" == "(Stream)" && ( "$prev_tok" == "$port" || "$prev_tok" =~ ^([0-9.]+|\[[^]]+\]|\*):${port}(%[^[:space:]]+)?$ ) ]]; then
                        printf '%s\n' "$port"
                        return 0
                    fi
                    prev_tok="$tok"
                done
            done
        fi
    fi
    ssh_get_current_port
}

firewall_read_view_status() {
    local input_scope jump_scope="不支持"
    input_scope=$(firewall_hook_scope filter INPUT "$ZERO_FW_CHAIN")
    if firewall_supports_table "iptables" nat || firewall_supports_table "ip6tables" nat; then
        jump_scope=$(firewall_hook_scope nat PREROUTING "$ZERO_PORT_JUMP_CHAIN")
    fi
    printf '%s\n' "$input_scope" "$jump_scope"
}

firewall_port_spec_contains() {
    local port="$1" spec="$2"
    if [[ "$spec" =~ ^[0-9]+$ ]]; then
        (( port == spec ))
    elif [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        (( port >= ${BASH_REMATCH[1]} && port <= ${BASH_REMATCH[2]} ))
    else
        return 1
    fi
}

firewall_chain_allows_port() {
    local cmd="$1" target_proto="$2" port="$3" line proto dport target

    firewall_supports_table "$cmd" filter || return 0
    firewall_rule_exists "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || return 0
    firewall_chain_exists "$cmd" filter "$ZERO_FW_CHAIN" || return 0

    while IFS= read -r line; do
        [[ "$line" == "-A $ZERO_FW_CHAIN "* ]] || continue
        [[ "$line" == *"-m conntrack --ctstate ESTABLISHED,RELATED"* ]] && continue
        [[ "$line" == *"-m conntrack --ctstate RELATED,ESTABLISHED"* ]] && continue
        [[ "$line" == *"-i lo"* ]] && continue
        [[ "$line" == *"zero-acme-http01"* ]] && continue
        [[ "$line" == *" -s "* || "$line" == *" --sport "* ]] && continue

        proto=""
        dport=""
        target=""
        [[ "$line" =~ -p[[:space:]]+([^[:space:]]+) ]] && proto="${BASH_REMATCH[1]}"
        [[ "$line" =~ --dport[[:space:]]+([^[:space:]]+) ]] && dport="${BASH_REMATCH[1]}"
        [[ "$line" =~ -j[[:space:]]+([^[:space:]]+) ]] && target="${BASH_REMATCH[1]}"

        [[ -n "$proto" && "$proto" != "$target_proto" ]] && continue
        [[ -n "$dport" ]] && ! firewall_port_spec_contains "$port" "$dport" && continue

        case "$target" in
            ACCEPT) return 0 ;;
            DROP|REJECT) return 1 ;;
        esac
    done < <("$cmd" -t filter -S "$ZERO_FW_CHAIN" 2>/dev/null)

    return 0
}

firewall_blocks_port() {
    local proto="$1" port="$2" cmd
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        firewall_rule_exists "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || continue
        firewall_chain_allows_port "$cmd" "$proto" "$port" || return 0
    done
    return 1
}

firewall_can_change_ssh_port() {
    local port="$1" cmd
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        firewall_rule_exists "$cmd" filter INPUT -j "$ZERO_FW_CHAIN" || continue
        firewall_chain_allows_port "$cmd" tcp "$port" || return 1
    done
    return 0
}

firewall_prepare_hook_chain() {
    local cmd="$1" table="$2" parent="$3" chain="$4" first_rule
    command -v "$cmd" >/dev/null 2>&1 || return 1
    first_rule=$("$cmd" -w 3 -t "$table" -S "$parent" 1 2>/dev/null || true)
    [[ "$first_rule" == "-A ${parent} -j ${chain}" ]] && return 0
    firewall_supports_table "$cmd" "$table" || return 1
    firewall_ensure_chain "$cmd" "$table" "$chain" || return 1
    firewall_ensure_rule_absent "$cmd" "$table" "$parent" -j "$chain" || return 1
    firewall_exec "$cmd" -t "$table" -I "$parent" 1 -j "$chain"
}

firewall_prepare_input_chain_for_cmd() {
    firewall_prepare_hook_chain "$1" filter INPUT "$ZERO_FW_CHAIN"
}

firewall_prepare_nat_chain_for_cmd() {
    firewall_prepare_hook_chain "$1" nat PREROUTING "$ZERO_PORT_JUMP_CHAIN"
}

firewall_protocol_label() {
    case "$1" in
        tcp) echo "TCP" ;;
        udp) echo "UDP" ;;
        *)   echo "$1" ;;
    esac
}

firewall_scope_suffix() {
    case "$1" in
        v4) echo " [仅IPv4]" ;;
        v6) echo " [仅IPv6]" ;;
        *)  echo "" ;;
    esac
}

firewall_should_hide_rule_in_view() {
    local chain="$1" rule="$2"
    [[ "$chain" == "$ZERO_FW_CHAIN" ]] || return 1
    [[ "$rule" == *"-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"* ||
       "$rule" == *"-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"* ||
       "$rule" == *"-i lo -j ACCEPT"* ||
       "$rule" == *"-p ipv6-icmp -j ACCEPT"* ||
       "$rule" == *"--sport 547 --dport 546 -j ACCEPT"* ]]
}

firewall_hook_scope() {
    local table="$1" parent_chain="$2" target_chain="$3" has_v4=0 has_v6=0
    firewall_rule_exists "iptables" "$table" "$parent_chain" -j "$target_chain" && has_v4=1
    firewall_rule_exists "ip6tables" "$table" "$parent_chain" -j "$target_chain" && has_v6=1

    if (( has_v4 == 1 && has_v6 == 1 )); then
        echo "v4/v6"
    elif (( has_v4 == 1 )); then
        echo "仅IPv4"
    elif (( has_v6 == 1 )); then
        echo "仅IPv6"
    else
        echo "未挂载"
    fi
}

firewall_humanize_rule() {
    local chain="$1" rule="$2" target="" proto="" dport="" iface="" to_ports=""

    [[ "$rule" =~ -j[[:space:]]+([^[:space:]]+) ]] && target="${BASH_REMATCH[1]}"
    [[ "$rule" =~ -p[[:space:]]+([^[:space:]]+) ]] && proto="${BASH_REMATCH[1]}"
    [[ "$rule" =~ --dport[[:space:]]+([^[:space:]]+) ]] && dport="${BASH_REMATCH[1]}"
    [[ "$rule" =~ -i[[:space:]]+([^[:space:]]+) ]] && iface="${BASH_REMATCH[1]}"
    [[ "$rule" =~ --to-ports[[:space:]]+([^[:space:]]+) ]] && to_ports="${BASH_REMATCH[1]}"

    case "$chain" in
        "$ZERO_FW_CHAIN")
            if [[ "$rule" == *"-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"* || "$rule" == *"-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"* ]]; then
                echo "放行 已建立连接"; return
            fi
            [[ "$rule" == *"-i lo -j ACCEPT"* ]] && { echo "放行 本地回环"; return; }
            [[ "$rule" == *"-p ipv6-icmp -j ACCEPT"* ]] && { echo "放行 IPv6 ICMP"; return; }
            [[ "$rule" == "-j DROP" ]] && { echo "阻断 其他流量"; return; }
            if [[ -n "$target" && -n "$proto" && -n "$dport" ]]; then
                case "$target" in
                    ACCEPT) echo "放行 $(firewall_protocol_label "$proto") ${dport}" ;;
                    DROP)   echo "阻断 $(firewall_protocol_label "$proto") ${dport}" ;;
                    *)      echo "${target} $(firewall_protocol_label "$proto") ${dport}" ;;
                esac
                return
            fi
            ;;
        "$ZERO_PORT_JUMP_CHAIN")
            if [[ "$target" == "REDIRECT" && -n "$proto" && -n "$dport" && -n "$to_ports" ]]; then
                if [[ -n "$iface" ]]; then
                    echo "跳跃 $(firewall_protocol_label "$proto") ${dport} -> ${to_ports} (${iface})"
                else
                    echo "跳跃 $(firewall_protocol_label "$proto") ${dport} -> ${to_ports}"
                fi
                return
            fi
            ;;
    esac
    echo "$rule"
}

firewall_render_merged_chain() {
    local table="$1"
    local chain="$2"
    local title="$3"
    local rendered=""
    local displayed=0

    rendered=$(
        {
            if firewall_has_rules "iptables" "$table" "$chain"; then
                iptables -t "$table" -S "$chain" 2>/dev/null | sed -n "s/^-A ${chain} /v4 /p"
            fi
            if firewall_has_rules "ip6tables" "$table" "$chain"; then
                ip6tables -t "$table" -S "$chain" 2>/dev/null | sed -n "s/^-A ${chain} /v6 /p"
            fi
        } | awk -v compact="$([[ "$chain" == "$ZERO_FW_CHAIN" ]] && echo 1 || echo 0)" '
            function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
            function tok_after(s, flag,    i, n, a) {
                n = split(s, a, /[ \t]+/)
                for (i = 1; i < n; i++) if (a[i] == flag) return a[i + 1]
                return ""
            }
            {
                ver=$1; $1=""
                rule=trim($0)
                if (!(rule in idx)) { idx[rule]=++count; order[count]=rule }
                if (ver=="v4") seen4[rule]=1
                if (ver=="v6") seen6[rule]=1
            }
            END {
                for (i=1; i<=count; i++) {
                    rule=order[i]
                    scope = (seen4[rule] && seen6[rule]) ? "both" : (seen4[rule] ? "v4" : "v6")
                    if (compact && rule !~ /(^|[ \t])(-s|-d|-i|-o|--sport|--comment)([ \t]|$)/) {
                        proto = tok_after(rule, "-p")
                        port  = tok_after(rule, "--dport")
                        tgt   = tok_after(rule, "-j")
                        if ((proto == "tcp" || proto == "udp") && port != "" && (tgt == "ACCEPT" || tgt == "DROP")) {
                            act = (tgt == "ACCEPT") ? "放行" : "阻断"
                            key = scope SUBSEP act SUBSEP port
                            if (!(key in gidx)) {
                                gidx[key] = ++out_n
                                otype[out_n] = "g"
                                gscope[out_n] = scope; gact[out_n] = act; gport[out_n] = port
                            }
                            gi = gidx[key]
                            if (proto == "tcp") gtcp[gi] = 1
                            else gudp[gi] = 1
                            continue
                        }
                    }
                    ++out_n
                    otype[out_n] = "r"
                    oraw[out_n] = scope "|" rule
                }
                for (i=1; i<=out_n; i++) {
                    if (otype[i] == "r") {
                        print oraw[i]
                    } else {
                        plab = (gtcp[i] && gudp[i]) ? "TCP+UDP" : (gtcp[i] ? "TCP" : "UDP")
                        printf "%s|DISPLAY:%s %s %s\n", gscope[i], gact[i], plab, gport[i]
                    }
                }
            }
        '
    )

    echo -e "${YELLOW}${title}:${PLAIN}"
    if [[ -z "$rendered" ]]; then
        if firewall_chain_exists "iptables" "$table" "$chain" || firewall_chain_exists "ip6tables" "$table" "$chain"; then
            echo "  (空)"
        else
            echo "  (未创建)"
        fi
        return
    fi

    while IFS='|' read -r scope rule; do
        [[ -z "$scope" ]] && continue
        firewall_should_hide_rule_in_view "$chain" "$rule" && continue
        displayed=1
        if [[ "$rule" == DISPLAY:* ]]; then
            echo "  - ${rule#DISPLAY:}$(firewall_scope_suffix "$scope")"
        else
            echo "  - $(firewall_humanize_rule "$chain" "$rule")$(firewall_scope_suffix "$scope")"
        fi
    done <<< "$rendered"

    if (( displayed == 0 )); then
        echo "  (无自定义规则)"
    fi
}

port_jump_legacy_rules() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 && firewall_supports_table "$cmd" nat || return 0
    "$cmd" -t nat -S PREROUTING 2>/dev/null | grep -E '^-A PREROUTING .* -j REDIRECT --to-ports '
}

port_jump_has_any_legacy_rules() {
    [[ -n "$(port_jump_legacy_rules iptables)" || -n "$(port_jump_legacy_rules ip6tables)" ]]
}

port_jump_print_legacy_if_any() {
    if port_jump_has_any_legacy_rules; then
        echo -e "${YELLOW}旧版直连 REDIRECT 规则:${PLAIN}"
        port_jump_legacy_rules "iptables"
        port_jump_legacy_rules "ip6tables"
    fi
}

list_firewall_rules() {
    local -a firewall_view_status
    clear
    echo -e "${BLUE}=================== 防火墙规则详情 ===================${PLAIN}"
    mapfile -t firewall_view_status < <(firewall_read_view_status)

    echo -e "${YELLOW}状态:${PLAIN} 入站管理=${firewall_view_status[0]}  |  端口跳跃=${firewall_view_status[1]}"
    firewall_render_merged_chain filter "$ZERO_FW_CHAIN" "端口规则"

    if firewall_supports_table "iptables" nat || firewall_supports_table "ip6tables" nat; then
        firewall_render_merged_chain nat "$ZERO_PORT_JUMP_CHAIN" "端口跳跃"
        port_jump_print_legacy_if_any
    fi
    echo -e "${BLUE}======================================================${PLAIN}"
}

firewall_ensure_input_base_rules() {
    local cmd="$1"
    local -a chain_rules=()
    mapfile -t chain_rules < <("$cmd" -w 3 -t filter -S "$ZERO_FW_CHAIN" 2>/dev/null | grep '^-A ' || true)

    if [[ ( "${chain_rules[0]:-}" == *"-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"* ||
            "${chain_rules[0]:-}" == *"-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"* ) &&
          "${chain_rules[1]:-}" == *"-i lo -j ACCEPT"* ]]; then
        return 0
    fi

    firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
    firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
    firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" -i lo -j ACCEPT || return 1

    if firewall_has_rules "$cmd" filter "$ZERO_FW_CHAIN"; then
        firewall_exec "$cmd" -t filter -I "$ZERO_FW_CHAIN" 1 -i lo -j ACCEPT || return 1
    else
        firewall_exec "$cmd" -t filter -A "$ZERO_FW_CHAIN" -i lo -j ACCEPT || return 1
    fi
    firewall_exec "$cmd" -t filter -I "$ZERO_FW_CHAIN" 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

firewall_insert_port_rule_after_base() {
    local cmd="$1" rule_count
    shift
    firewall_ensure_input_base_rules "$cmd" || return 1
    firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" "$@" || return 1
    rule_count=$("$cmd" -w 3 -t filter -S "$ZERO_FW_CHAIN" 2>/dev/null | grep -c '^-A ' || true)
    if (( rule_count >= 3 )); then
        firewall_exec "$cmd" -t filter -I "$ZERO_FW_CHAIN" 3 "$@"
    else
        firewall_exec "$cmd" -t filter -A "$ZERO_FW_CHAIN" "$@"
    fi
}

firewall_apply_port_rule() {
    local cmd="$1" action="$2" proto="$3" port_spec="$4"
    firewall_prepare_input_chain_for_cmd "$cmd" || return 1
    if [[ "$action" == "open" ]]; then
        firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" -p "$proto" --dport "$port_spec" -j DROP &&
        firewall_insert_port_rule_after_base "$cmd" -p "$proto" --dport "$port_spec" -j ACCEPT
    else
        firewall_ensure_rule_absent "$cmd" filter "$ZERO_FW_CHAIN" -p "$proto" --dport "$port_spec" -j ACCEPT &&
        firewall_insert_port_rule_after_base "$cmd" -p "$proto" --dport "$port_spec" -j DROP
    fi
}

firewall_clear_managed_rules() {
    local cmd
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        firewall_prepare_input_chain_for_cmd "$cmd" && firewall_flush_chain "$cmd" filter "$ZERO_FW_CHAIN" || return 1
    done
}

firewall_lockdown_all() {
    local current_ssh_port="$1" cmd active=0
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" filter || continue
        active=1
        firewall_prepare_input_chain_for_cmd "$cmd" || return 1
        firewall_flush_chain "$cmd" filter "$ZERO_FW_CHAIN" || return 1
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -i lo -j ACCEPT || return 1
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -p tcp --dport "$current_ssh_port" -j ACCEPT || return 1
        if [[ "$cmd" == "ip6tables" ]]; then
            firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -s fe80::/10 -p udp --sport 547 --dport 546 -j ACCEPT || return 1
            firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -p ipv6-icmp -j ACCEPT || return 1
        fi
        firewall_ensure_rule_present "$cmd" filter "$ZERO_FW_CHAIN" -j DROP || return 1
    done
    (( active == 1 ))
}

port_jump_has_managed_config() {
    local cmd
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" nat || continue
        firewall_chain_exists "$cmd" nat "$ZERO_PORT_JUMP_CHAIN" && return 0
        firewall_rule_exists "$cmd" nat PREROUTING -j "$ZERO_PORT_JUMP_CHAIN" && return 0
        firewall_has_rules "$cmd" nat "$ZERO_PORT_JUMP_CHAIN" && return 0
    done
    return 1
}

port_jump_clear_managed_rules() {
    local cmd
    for cmd in iptables ip6tables; do
        firewall_supports_table "$cmd" nat || continue
        firewall_ensure_rule_absent "$cmd" nat PREROUTING -j "$ZERO_PORT_JUMP_CHAIN" &&
        firewall_delete_chain "$cmd" nat "$ZERO_PORT_JUMP_CHAIN" || return 1
    done
}

port_jump_render_status() {
    local -a firewall_view_status
    mapfile -t firewall_view_status < <(firewall_read_view_status)
    echo -e "${BLUE}=================== 端口跳跃状态 ===================${PLAIN}\n"
    echo -e "${YELLOW}状态:${PLAIN} 端口跳跃=${firewall_view_status[1]}"
    firewall_render_merged_chain nat "$ZERO_PORT_JUMP_CHAIN" "端口跳跃"
    port_jump_print_legacy_if_any
    echo -e "${BLUE}====================================================${PLAIN}"
}

port_jump_set() {
    local mode="${1:-create}" backup="" interface user_interface port_range start_port end_port target_port
    local need_v4=0 need_v6=0 ok_v4=0 ok_v6=0

    clear
    echo -e "${BLUE}检查 iptables/ip6tables 是否已安装...${PLAIN}"
    firewall_prepare_tools || { press_any_key_to_continue; return 1; }

    if [[ "$mode" != "overwrite" ]] && port_jump_has_managed_config; then
        echo -e "${YELLOW}已检测到当前脚本管理的端口跳跃规则,请先使用“修改跳跃”或“删除跳跃”${PLAIN}"
        press_any_key_to_continue
        return 0
    fi

    if port_jump_has_any_legacy_rules; then
        echo -e "${YELLOW}检测到旧版直连 PREROUTING REDIRECT 规则。${PLAIN}"
        echo -e "${YELLOW}为避免误删其他 NAT 规则,当前版本只管理本脚本创建的端口跳跃链,请先手动清理旧规则。${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    interface=$(get_default_interface)
    if [[ -z "$interface" ]]; then
        echo -e "${RED}未检测到有效网卡,请检查网络配置${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    read -r -p "${YELLOW}请输入网卡名称(默认:${interface}): ${PLAIN}" user_interface
    user_interface=$(trim_input "$user_interface")
    user_interface=${user_interface:-$interface}
    if ! ip link show "$user_interface" >/dev/null 2>&1; then
        echo -e "${RED}网卡 ${user_interface} 不存在${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    read -r -p "${YELLOW}请输入 UDP 端口范围(默认18443:28444): ${PLAIN}" port_range
    port_range=$(trim_input "$port_range")
    port_range=${port_range:-18443:28444}
    if [[ "$port_range" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
        start_port=$((10#${BASH_REMATCH[1]}))
        end_port=$((10#${BASH_REMATCH[2]}))
    else
        echo -e "${RED}端口范围格式错误,请使用 start:end${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    if (( start_port < 1 || end_port > 65535 || start_port > end_port )); then
        echo -e "${RED}无效端口范围,必须在 1-65535 且起始不大于结束${PLAIN}"
        press_any_key_to_continue
        return 1
    fi
    port_range="$start_port:$end_port"

    read -r -p "${YELLOW}请输入目标 UDP 端口: ${PLAIN}" target_port
    target_port=$(trim_input "$target_port")
    if ! zero_is_valid_port "$target_port"; then
        echo -e "${RED}无效的目标端口,请输入 1-65535${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    firewall_supports_table "iptables" nat && need_v4=1
    firewall_supports_table "ip6tables" nat && need_v6=1
    if (( need_v4 == 0 && need_v6 == 0 )); then
        echo -e "${RED}当前系统未检测到可用的 NAT 表,无法设置端口跳跃${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    firewall_require_backup "本次修改" || { press_any_key_to_continue; return 1; }
    backup="$FIREWALL_LAST_BACKUP"

    if (( need_v4 == 1 )); then
        firewall_prepare_nat_chain_for_cmd "iptables" &&
        firewall_flush_chain "iptables" nat "$ZERO_PORT_JUMP_CHAIN" &&
        firewall_ensure_rule_present "iptables" nat "$ZERO_PORT_JUMP_CHAIN" -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port" &&
        ok_v4=1
    fi

    if (( need_v6 == 1 )); then
        firewall_prepare_nat_chain_for_cmd "ip6tables" &&
        firewall_flush_chain "ip6tables" nat "$ZERO_PORT_JUMP_CHAIN" &&
        firewall_ensure_rule_present "ip6tables" nat "$ZERO_PORT_JUMP_CHAIN" -i "$user_interface" -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port" &&
        ok_v6=1
    fi

    if (( (need_v4 == 1 && ok_v4 == 0) || (need_v6 == 1 && ok_v6 == 0) )); then
        firewall_restore_with_notice "$backup" "端口跳跃规则写入失败,已回滚到修改前状态" "端口跳跃规则写入失败,回滚失败,请检查 NAT 规则" || return 1
        firewall_remove_backup "$backup"
        press_any_key_to_continue
        return 1
    fi

    firewall_save_rules || true
    firewall_remove_backup "$backup"
    clear
    echo -e "${GREEN}端口跳跃规则已写入: ${user_interface} ${port_range} -> ${target_port}/udp${PLAIN}"
    if firewall_blocks_port udp "$target_port"; then
        echo -e "${YELLOW}[!] 提示: 当前 ZERO_INPUT 防火墙阻断了目标端口 UDP ${target_port}，跳跃流量到达本机后会被拦截，请在防火墙「1.放行端口」中放行 ${target_port}${PLAIN}"
    fi
    port_jump_render_status
    press_any_key_to_continue
}

port_jump_delete() {
    local backup=""
    clear
    if ! port_jump_has_managed_config; then
        echo -e "${YELLOW}当前没有由本脚本管理的端口跳跃规则${PLAIN}"
        port_jump_has_any_legacy_rules && echo -e "${YELLOW}检测到旧版直连 REDIRECT 规则,请手动清理 PREROUTING 中的对应条目${PLAIN}"
        press_any_key_to_continue
        return 0
    fi

    firewall_require_backup "删除" || { press_any_key_to_continue; return 1; }
    backup="$FIREWALL_LAST_BACKUP"

    echo -e "${BLUE}正在删除端口跳跃规则...${PLAIN}"
    if ! port_jump_clear_managed_rules; then
        firewall_restore_with_notice "$backup" "删除端口跳跃规则失败,已恢复原状态" "删除端口跳跃规则失败,回滚失败,请检查 NAT 规则" || return 1
        firewall_remove_backup "$backup"
        press_any_key_to_continue
        return 1
    fi

    firewall_save_rules || true
    firewall_remove_backup "$backup"
    echo -e "${GREEN}端口跳跃配置已删除${PLAIN}"
    press_any_key_to_continue
}

port_jump_menu() {
    local pjopt
    while true; do
        clear
        echo -e "${BLUE}✦ Ports Jump ✦${PLAIN}"
        echo -e "${GREEN}  1.${PLAIN}设置跳跃"
        echo -e "${GREEN}  2.${PLAIN}修改跳跃"
        echo -e "${GREEN}  3.${PLAIN}查看跳跃"
        echo -e "${GREEN}  4.${PLAIN}删除跳跃"
        echo -e "${GREEN}  0.${PLAIN}返回上级"
        pjopt=$(read_menu_choice "✦ Steins Gate ✦ : ") || return 1
        case "$pjopt" in
            1) port_jump_set ;;
            2)
                clear
                if ! port_jump_has_managed_config; then
                    echo -e "${YELLOW}当前没有由本脚本管理的端口跳跃规则${PLAIN}"
                    press_any_key_to_continue
                else
                    port_jump_set overwrite
                fi
                ;;
            3) clear; port_jump_render_status; press_any_key_to_continue ;;
            4) port_jump_delete ;;
            0) return ;;
            *) show_invalid_option "无效选项,请重新输入" ;;
        esac
    done
}

handle_firewall_action_choice() {
    local action_choice="$1" current_ssh_port="$2" backup

    case "$action_choice" in
        0) return 1 ;;
        1|2)
            local input_ports protocol_label action_failed=0 port_range start_port end_port port_spec port_failed proto cmd rule_act
            [[ "$action_choice" == "1" ]] && rule_act="open" || rule_act="close"

            read -r -p "请输入端口（如 443 或 1000-2000，可空格分隔多个）: " input_ports
            input_ports=$(trim_input "$input_ports")
            if [[ -z "$input_ports" ]]; then
                echo -e "${YELLOW}[!] 未输入端口,已取消本次操作${PLAIN}"
                press_any_key_to_continue
                return 0
            fi
            firewall_require_backup "本次操作" || { press_any_key_to_continue; return 0; }
            backup="$FIREWALL_LAST_BACKUP"

            for port_range in $input_ports; do
                port_failed=0
                protocol_label="TCP+UDP"
                if [[ "$port_range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
                    start_port=$((10#${BASH_REMATCH[1]}))
                    end_port=$((10#${BASH_REMATCH[2]}))
                elif [[ "$port_range" =~ ^([0-9]{1,5})$ ]]; then
                    start_port=$((10#$port_range))
                    end_port=$start_port
                else
                    echo -e "${RED}[!] 无效端口格式: $port_range${PLAIN}"
                    action_failed=1
                    continue
                fi

                if (( start_port < 1 || end_port > 65535 || start_port > end_port )); then
                    echo -e "${RED}[!] 端口范围无效: $port_range (必须 1-65535 且起始≤结束)${PLAIN}"
                    action_failed=1
                    continue
                fi
                (( start_port == end_port )) && port_spec="$start_port" || port_spec="$start_port:$end_port"

                for proto in tcp udp; do
                    if [[ "$action_choice" == "2" && "$proto" == "tcp" && "$start_port" -le "$current_ssh_port" && "$end_port" -ge "$current_ssh_port" ]]; then
                        echo -e "${YELLOW}[!] 跳过 TCP ${port_range}: 不能阻断当前 SSH 端口 ${current_ssh_port}${PLAIN}"
                        protocol_label="UDP（TCP 已跳过）"
                        continue
                    fi
                    for cmd in iptables ip6tables; do
                        firewall_supports_table "$cmd" filter || continue
                        firewall_apply_port_rule "$cmd" "$rule_act" "$proto" "$port_spec" || { action_failed=1; port_failed=1; }
                    done
                done

                if (( port_failed == 0 )); then
                    if [[ "$action_choice" == "1" ]]; then
                        echo -e "${GREEN}[✓] 端口 $port_range 已按 ${protocol_label} 规则放行${PLAIN}"
                    else
                        echo -e "${RED}[✓] 端口 $port_range 已按 ${protocol_label} 规则阻断${PLAIN}"
                    fi
                else
                    echo -e "${YELLOW}[!] 端口 $port_range 的部分规则写入失败,请查看当前规则${PLAIN}"
                fi
            done

            if (( action_failed == 0 )); then
                firewall_save_rules || true
            else
                firewall_restore_with_notice "$backup" "本次操作存在失败项,已回滚到修改前状态" "本次操作存在失败项,回滚失败,请检查规则" || return 1
            fi
            firewall_remove_backup "$backup"
            press_any_key_to_continue
            ;;
        3)
            firewall_require_backup "清空" || { press_any_key_to_continue; return 0; }
            backup="$FIREWALL_LAST_BACKUP"
            if firewall_clear_managed_rules; then
                firewall_save_rules || true
                echo -e "${GREEN}[✓] 已清空本脚本管理的规则,不再改动系统原有 INPUT/FORWARD/OUTPUT 策略${PLAIN}"
            else
                echo -e "${RED}[!] 清空规则失败${PLAIN}"
                firewall_restore_with_notice "$backup" "清空规则失败,已恢复到清空前状态" "清空规则失败,回滚失败,请检查当前规则" || return 1
            fi
            firewall_remove_backup "$backup"
            press_any_key_to_continue
            ;;
        4)
            firewall_require_backup "本次操作" || { press_any_key_to_continue; return 0; }
            backup="$FIREWALL_LAST_BACKUP"
            echo -e "${YELLOW}[*] 正在配置仅保留 SSH 的入站策略(SSH: ${current_ssh_port})...${PLAIN}"
            if firewall_lockdown_all "$current_ssh_port"; then
                firewall_save_rules || true
                echo -e "${GREEN}[✓] 已应用仅留 SSH 的入站规则${PLAIN}"
            else
                echo -e "${RED}[!] 写入仅保留 SSH 规则失败${PLAIN}"
                firewall_restore_with_notice "$backup" "写入规则失败,已恢复到修改前状态" "写入规则失败,回滚失败,请检查当前规则" || return 1
            fi
            firewall_remove_backup "$backup"
            press_any_key_to_continue
            ;;
        5) list_firewall_rules; press_any_key_to_continue ;;
        6) port_jump_menu ;;
        *) show_invalid_option "[!] 无效选项" "1" ;;
    esac
    return 0
}

configure_firewall() {
    local action_choice current_ssh_port has_iptables=false has_ip6tables=false init_ok=0

    firewall_prepare_tools || { press_any_key_to_continue; return 1; }
    if firewall_prepare_input_chain_for_cmd "iptables" 2>/dev/null; then
        has_iptables=true
        init_ok=1
    fi
    if firewall_prepare_input_chain_for_cmd "ip6tables" 2>/dev/null; then
        has_ip6tables=true
        init_ok=1
    fi
    if (( init_ok == 0 )); then
        echo -e "${RED}[!] 无法初始化防火墙管理链${PLAIN}"
        press_any_key_to_continue
        return 1
    fi

    firewall_setup_persistence || true

    while true; do
        current_ssh_port=$(firewall_current_ssh_port)
        clear
        echo -e "${BLUE}===== iptables 防火墙管理 =====${PLAIN}"
        echo -e "${BLUE}SSH端口:  ${YELLOW}${current_ssh_port}${PLAIN}"
        if [[ "$has_iptables" != "true" || "$has_ip6tables" != "true" ]]; then
            if [[ "$has_iptables" == "true" ]]; then
                echo -e "${YELLOW}当前仅支持 IPv4，规则将只写入 IPv4${PLAIN}"
            elif [[ "$has_ip6tables" == "true" ]]; then
                echo -e "${YELLOW}当前仅支持 IPv6，规则将只写入 IPv6${PLAIN}"
            else
                echo -e "${RED}未检测到可用的 iptables/ip6tables，部分功能可能不可用${PLAIN}"
            fi
        fi
        echo -e "${BLUE}===============================${PLAIN}"
        echo -e "${GREEN}1.放行端口${PLAIN}"
        echo -e "${RED}2.阻断端口${PLAIN}"
        echo -e "${GREEN}3.清空规则${PLAIN}"
        echo -e "${RED}4.仅放行SSH${PLAIN}"
        echo -e "${BLUE}5.查看当前规则${PLAIN}"
        echo -e "${GREEN}6.配置端口跳跃${PLAIN}"
        echo -e "${YELLOW}0.返回主菜单${PLAIN}"
        echo -e "${BLUE}===============================${PLAIN}"
        action_choice=$(read_menu_choice "请输入选项 [0-6]: ") || return 1
        handle_firewall_action_choice "$action_choice" "$current_ssh_port" || return
    done
}

main_menu() {
    local choice
    while true; do
        clear
        echo -e "${BLUE}✦ Steins Gate_Ver.2.4 ✦${PLAIN}"
        echo -e "${GREEN}  01.${PLAIN}系统更新"
        echo -e "${GREEN}  02.${PLAIN}系统清理"
        echo -e "${GREEN}  03.${PLAIN}重装系统"
        echo -e "${GREEN}  04.${PLAIN}设置时区"
        echo -e "${GREEN}  05.${PLAIN}IP优先级"
        echo -e "${GREEN}  06.${PLAIN}配置BBR"
        echo -e "${GREEN}  07.${PLAIN}配置DNS"
        echo -e "${GREEN}  08.${PLAIN}配置SSH"
        echo -e "${GREEN}  09.${PLAIN}重启VPS"
        echo -e "${GREEN}  10.${PLAIN}配置ACME"
        echo -e "${GREEN}  11.${PLAIN}配置Volto"
        echo -e "${GREEN}  12.${PLAIN}配置Mihomo"
        echo -e "${GREEN}  13.${PLAIN}配置SingBox"
        echo -e "${GREEN}  14.${PLAIN}配置FireWall"
        echo -e "${GREEN}  15.${PLAIN}配置WireProxy"
        echo -e "${GREEN}  16.${PLAIN}配置WarpStack"
        echo -e "${GREEN}   0.${PLAIN}退出ByeBye"
        choice=$(read_menu_choice "✦ Choice [0-16] ✦ : ") || break
        case "$choice" in
            1)  linux_update ;;
            2)  linux_clean ;;
            3)  reinstall_menu ;;
            4)  change_timezone ;;
            5)  set_ip_priority ;;
            6)  bbr_manage_menu ;;
            7)  dns_fix ;;
            8)  ssh_config_menu ;;
            9)  reboot_system ;;
            10) acme_menu ;;
            11) configure_volto ;;
            12) ( umask 077; mihomo_menu ) ;;
            13) singbox_menu ;;
            14) configure_firewall ;;
            15) run_subshell_menu wireproxy_menu "WireProxy" ;;
            16) run_subshell_menu warpstack_menu "WarpStack" ;;
            0)
                clear
                echo -e "${BLUE}「命运石之扉の选择,El Psy Kongroo」${PLAIN}"
                sleep 0.6
                clear
                break
                ;;
            *) show_invalid_option "[!] 无效选项，请重新选择" "0.4" "1" ;;
        esac
    done
}

main_menu
