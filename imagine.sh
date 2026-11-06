#!/bin/bash
# ============================================================================
# 个人自建节点 - 菜单安装脚本 imagine.sh
#
# 用法：bash imagine.sh
# 首次用 root 运行后会自动安装快捷键，之后在任何目录输入 x 或 X
# （不区分大小写）即可打开菜单。
#
# 菜单结构：
#   主菜单
#     1. 搭建节点
#        1. hy2
#           1. 搭建 hy2（没有域名自签 / 有域名）
#           2. 查看节点
#           3. 更换端口
#           4. 卸载 hy2
#        2. vless+reality（Xray）
#           1. 搭建 reality
#           2. 查看节点
#           3. 更换端口
#           4. 卸载 reality
#        （以后加新协议时在这里另起一行，如 3. xhttp）
#
# 说明：
# - 安装步骤需要 root 权限，请用 sudo bash imagine.sh 运行。
# - systemd 服务需要机器支持 systemd；不支持时脚本会给出手动启动命令。
# - 被 source 引入时只定义函数、不跑主菜单，方便单独测试某个函数：
#     source imagine.sh && CONFIG_DIR=/tmp/hy2test gen_self_signed_cert "1.2.3.4"
# ============================================================================

set -u  # 引用未定义变量就报错（不加 -e，避免菜单里某个命令失败就直接退出）

# ---------- 可配置路径（测试时可通过环境变量覆盖） ----------
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/hysteria}"
SERVICE_DIR="${SERVICE_DIR:-/etc/systemd/system}"
# 脚本自身的下载地址（管道运行时用来下载一份再装快捷键）
IMAGINE_URL="${IMAGINE_URL:-https://raw.githubusercontent.com/xx554/imagine/main/imagine.sh}"
# reality（Xray）用的路径：官方安装脚本的固定位置
REALITY_CONFIG_DIR="${REALITY_CONFIG_DIR:-/usr/local/etc/xray}"
XRAY_BIN="${XRAY_BIN:-xray}"
# reality 内网端口：dokodemo-door 转发给本机 reality 入站的端口
REALITY_INTERNAL_PORT=4431

# ---------- 小工具 ----------

pause() {
    read -n 1 -s -rp "按任意键返回..." _key
    echo
}

random_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
    echo
}

# 读端口：留空用默认值，非数字或越界就重问
read_port() {
    local default_port="$1"
    local port=""
    while true; do
        read -rp "请输入端口（留空默认 ${default_port}）: " port
        port="${port:-$default_port}"
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            echo "$port"
            return
        fi
        echo "端口无效，请输入 1-65535 的数字。" >&2
    done
}

# 读密码：留空随机生成
read_password() {
    local password=""
    read -rp "请输入密码（留空则随机生成）: " password
    if [ -z "$password" ]; then
        password="$(random_password)"
        # 提示走 stderr，避免 $(read_password) 把提示也当成密码 captur
        echo "已随机生成密码：${password}" >&2
    fi
    echo "$password"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请用 root 身份运行：sudo bash imagine.sh"
        return 1
    fi
    return 0
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

# 尝试获取本机公网 IP，拿不到返回空
detect_public_ip() {
    local ip=""
    ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
    if [ -z "$ip" ]; then
        ip="$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)"
    fi
    echo "$ip"
}

# ---------- hy2 安装步骤 ----------

install_hysteria_binary() {
    if [ -x "${INSTALL_DIR}/hysteria" ]; then
        echo "hysteria 已安装，跳过下载。"
        return 0
    fi
    local arch
    arch="$(detect_arch)"
    if [ -z "$arch" ]; then
        echo "不支持的架构：$(uname -m)"
        return 1
    fi
    local url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
    echo "正在下载 hysteria：${url}"
    mkdir -p "$INSTALL_DIR"
    if ! curl -L --max-time 120 -o "${INSTALL_DIR}/hysteria" "$url"; then
        echo "下载失败，请检查网络后重试。"
        return 1
    fi
    chmod +x "${INSTALL_DIR}/hysteria"
    echo "hysteria 已安装。"
}

# 自签证书：参数为 CN（IP 或域名），生成到 $CONFIG_DIR
gen_self_signed_cert() {
    local cn="$1"
    mkdir -p "$CONFIG_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${CONFIG_DIR}/key.pem" \
        -out "${CONFIG_DIR}/cert.pem" \
        -days 3650 \
        -subj "/CN=${cn}" \
        -addext "subjectAltName=DNS:${cn},IP:${cn}" 2>/dev/null
    if [ -f "${CONFIG_DIR}/cert.pem" ] && [ -f "${CONFIG_DIR}/key.pem" ]; then
        echo "自签证书已生成：${CONFIG_DIR}/cert.pem"
        return 0
    fi
    echo "自签证书生成失败。"
    return 1
}

# 生成服务端配置：参数依次为 端口 密码 证书路径 密钥路径
gen_config() {
    local port="$1" password="$2" cert="$3" key="$4"
    mkdir -p "$CONFIG_DIR"
    cat > "${CONFIG_DIR}/config.yaml" <<EOF
listen: :${port}

tls:
  cert: ${cert}
  key: ${key}

auth:
  type: password
  password: ${password}
EOF
    echo "服务端配置已生成：${CONFIG_DIR}/config.yaml"
}

# 安装并启动 systemd 服务；没有 systemctl 时给出手动启动命令
install_service() {
    local service_file="${SERVICE_DIR}/hysteria-server.service"
    mkdir -p "$SERVICE_DIR"
    cat > "$service_file" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/hysteria server -c ${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "本机没有 systemctl，无法安装系统服务，请手动启动："
        echo "  ${INSTALL_DIR}/hysteria server -c ${CONFIG_DIR}/config.yaml"
        return 0
    fi
    if systemctl daemon-reload && systemctl enable --now hysteria-server; then
        echo "服务已启动：hysteria-server"
        return 0
    fi
    echo "systemd 服务启动失败，请手动检查或手动启动："
    echo "  ${INSTALL_DIR}/hysteria server -c ${CONFIG_DIR}/config.yaml"
    return 1
}

# 打印连接信息：参数依次为 密码 IP或域名 端口 SNI 是否跳过证书验证（1/0）
show_link() {
    local password="$1" host="$2" port="$3" sni="$4" insecure="$5"
    echo
    echo "==================== 搭建完成 ===================="
    echo "地址：${host}"
    echo "端口：${port}"
    echo "密码：${password}"
    echo "SNI：${sni}"
    if [ "$insecure" = "1" ]; then
        echo "证书：自签，客户端需开启“跳过证书验证”"
    else
        echo "证书：域名有效证书"
    fi
    echo
    echo "连接链接（可导入 v2rayN / Clash-Meta 等客户端）："
    echo "hy2://${password}@${host}:${port}/?sni=${sni}&insecure=${insecure}#hy2-node"
    echo "=================================================="
    echo
}

# ---------- 搭建 hy2 的两条路线 ----------

# 路线 1：没有域名（自签证书）
install_hy2_no_domain() {
    check_root || return
    echo "---------- 搭建 hy2：没有域名（自签证书） ----------"
    local port password ip
    port="$(read_port 443)"
    password="$(read_password)"
    install_hysteria_binary || return
    ip="$(detect_public_ip)"
    if [ -z "$ip" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    if [ -z "$ip" ]; then
        read -rp "未能自动获取服务器 IP，请手动输入： " ip
    fi
    gen_self_signed_cert "$ip" || return
    gen_config "$port" "$password" "${CONFIG_DIR}/cert.pem" "${CONFIG_DIR}/key.pem"
    save_node_info "$ip" "$port" "$password" "$ip" 1
    install_service
    show_link "$password" "$ip" "$port" "$ip" 1
}

# ---------- DNS 验证签发（有域名路线用，不需要 80 端口） ----------

# DNS 验证签发：用 DNS 服务商 API 自动添加 TXT 记录，签发后可自动续期
# 参数为 域名 acme.sh 路径；成功返回 0，失败返回 1
issue_cert_dns() {
    local domain="$1" acme="$2"
    echo "请选择 DNS 服务商："
    echo "1. Cloudflare"
    echo "2. 阿里云"
    echo "3. DNSPod"
    local provider=""
    read -rp "请选择 [1/2/3]: " provider
    local dns_arg=""
    case "$provider" in
        1)
            dns_arg="dns_cf"
            local cf_token=""
            echo "建议用 API Token：权限只给 Zone:DNS:Edit + Zone:Zone:Read，"
            echo "区域限定为你的域名即可；不要用 Global API Key，那是账号全权限。"
            read -rp "请输入 Cloudflare API Token（留空则改用 Global API Key）: " cf_token
            if [ -n "$cf_token" ]; then
                export CF_Token="$cf_token"
            else
                read -rsp "请输入 Cloudflare Global API Key: " CF_Key
                echo
                read -rp "请输入 Cloudflare 账号邮箱: " CF_Email
                export CF_Key CF_Email
            fi
            ;;
        2)
            dns_arg="dns_ali"
            read -rp "请输入阿里云 AccessKey ID: " Ali_Key
            read -rsp "请输入阿里云 AccessKey Secret: " Ali_Secret
            echo
            export Ali_Key Ali_Secret
            ;;
        3)
            dns_arg="dns_dp"
            read -rp "请输入 DNSPod ID: " DP_Id
            read -rsp "请输入 DNSPod Key: " DP_Key
            echo
            export DP_Id DP_Key
            ;;
        *)
            echo "输入无效。"
            return 1
            ;;
    esac
    # 注意：acme.sh 会把上面这些 API 密钥保存下来，用于以后自动续期，这是正常行为
    echo "正在为 ${domain} 申请证书（DNS 验证）..."
    if ! "$acme" --issue -d "$domain" --dns "$dns_arg"; then
        echo "证书申请失败：请检查 API 密钥是否正确、域名是否在该服务商解析。"
        return 1
    fi
    return 0
}

# 路线 2：有域名（acme.sh 申请有效证书）
install_hy2_with_domain() {
    check_root || return
    echo "---------- 搭建 hy2：有域名 ----------"
    echo "前提：你能修改该域名的 DNS 解析记录。"
    echo "说明：签证书用 DNS 验证，不需要 80 端口，签发时也不要求域名解析到本机；"
    echo "但节点建好后要能用，还得给域名加一条 A 记录指向本服务器 IP（灰云），"
    echo "否则客户端找不到服务器，连不上。"
    local domain port password acme
    read -rp "请输入域名： " domain
    if [ -z "$domain" ]; then
        echo "域名不能为空。"
        return
    fi
    port="$(read_port 443)"
    password="$(read_password)"
    install_hysteria_binary || return
    # 找 acme.sh，没有就装一个
    if [ -x "$HOME/.acme.sh/acme.sh" ]; then
        acme="$HOME/.acme.sh/acme.sh"
    elif command -v acme.sh >/dev/null 2>&1; then
        acme="acme.sh"
    else
        echo "正在安装 acme.sh..."
        if ! curl https://get.acme.sh | sh; then
            echo "acme.sh 安装失败，请手动安装后重试。"
            return
        fi
        acme="$HOME/.acme.sh/acme.sh"
    fi
    mkdir -p "$CONFIG_DIR"
    # 固定用 Let's Encrypt：新版 acme.sh 默认是 ZeroSSL，需要邮箱注册账号；
    # Let's Encrypt 不用邮箱，最稳
    "$acme" --set-default-ca --server letsencrypt
    if ! issue_cert_dns "$domain" "$acme"; then
        echo "证书申请失败。"
        return
    fi
    "$acme" --install-cert -d "$domain" \
        --key-file "${CONFIG_DIR}/key.pem" \
        --fullchain-file "${CONFIG_DIR}/cert.pem"
    gen_config "$port" "$password" "${CONFIG_DIR}/cert.pem" "${CONFIG_DIR}/key.pem"
    save_node_info "$domain" "$port" "$password" "$domain" 0
    install_service
    show_link "$password" "$domain" "$port" "$domain" 0
    echo "提醒：请确认已给 ${domain} 添加 A 记录指向本服务器 IP（灰云），"
    echo "否则客户端无法解析到服务器，依然连不上。"
}

# ---------- 节点管理：查看 / 换端口 / 卸载 ----------

# 保存节点信息（供查看、换端口时复用）：参数依次为 地址 端口 密码 SNI 是否跳过证书验证
save_node_info() {
    local host="$1" port="$2" password="$3" sni="$4" insecure="$5"
    mkdir -p "$CONFIG_DIR"
    {
        printf 'NODE_HOST=%q\n' "$host"
        printf 'NODE_PORT=%q\n' "$port"
        printf 'NODE_PASSWORD=%q\n' "$password"
        printf 'NODE_SNI=%q\n' "$sni"
        printf 'NODE_INSECURE=%q\n' "$insecure"
    } > "${CONFIG_DIR}/node.info"
}

# 读取节点信息到 NODE_HOST/NODE_PORT/NODE_PASSWORD/NODE_SNI/NODE_INSECURE；
# 没有 node.info 时从 config.yaml 和证书推断；没有配置返回 1
load_node_info() {
    NODE_HOST=""; NODE_PORT=""; NODE_PASSWORD=""; NODE_SNI=""; NODE_INSECURE=""
    if [ -f "${CONFIG_DIR}/node.info" ]; then
        # shellcheck disable=SC1090
        . "${CONFIG_DIR}/node.info"
    fi
    if [ -n "$NODE_PORT" ]; then
        return 0
    fi
    if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
        return 1
    fi
    NODE_PORT="$(grep '^listen:' "${CONFIG_DIR}/config.yaml" | sed 's/^listen: *://;s/ *$//')"
    NODE_PASSWORD="$(grep '^  password:' "${CONFIG_DIR}/config.yaml" | sed 's/^  password: *//')"
    NODE_HOST="$(detect_public_ip)"
    if [ -z "$NODE_HOST" ]; then
        NODE_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    NODE_INSECURE=1
    NODE_SNI="$NODE_HOST"
    if [ -f "${CONFIG_DIR}/cert.pem" ]; then
        local subject issuer san
        subject="$(openssl x509 -noout -subject -in "${CONFIG_DIR}/cert.pem" 2>/dev/null | sed 's/^subject= *//')"
        issuer="$(openssl x509 -noout -issuer -in "${CONFIG_DIR}/cert.pem" 2>/dev/null | sed 's/^issuer= *//')"
        if [ -n "$subject" ] && [ "$subject" != "$issuer" ]; then
            # 颁发者与主题不同，是有效证书
            NODE_INSECURE=0
            san="$(openssl x509 -noout -ext subjectAltName -in "${CONFIG_DIR}/cert.pem" 2>/dev/null | grep -o 'DNS:[^,]*' | head -n 1 | cut -d: -f2)"
            if [ -n "$san" ]; then
                NODE_SNI="$san"
            fi
        fi
    fi
    return 0
}

# 打印节点信息（含可复制到 v2rayN 的链接）
print_node_info() {
    load_node_info || return 1
    if [ -z "$NODE_PORT" ] || [ -z "$NODE_PASSWORD" ]; then
        echo "节点信息不完整（缺少端口或密码）。"
        return 1
    fi
    echo "地址：${NODE_HOST}"
    echo "端口：${NODE_PORT}"
    echo "密码：${NODE_PASSWORD}"
    echo "SNI：${NODE_SNI}"
    if [ "$NODE_INSECURE" = "1" ]; then
        echo "证书：自签，客户端需开启“跳过证书验证”"
    else
        echo "证书：域名有效证书"
    fi
    if [ -n "$NODE_HOST" ]; then
        echo "链接：hy2://${NODE_PASSWORD}@${NODE_HOST}:${NODE_PORT}/?sni=${NODE_SNI}&insecure=${NODE_INSECURE}#hy2-node"
    else
        echo "链接：无法确定服务器地址，请把下面链接中的“服务器地址”换成你的 IP 或域名："
        echo "hy2://${NODE_PASSWORD}@服务器地址:${NODE_PORT}/?sni=${NODE_SNI}&insecure=${NODE_INSECURE}#hy2-node"
    fi
    return 0
}

# 查看节点：当前状态 + 节点信息
view_node() {
    echo "---------- 查看节点 ----------"
    if [ ! -f "${CONFIG_DIR}/config.yaml" ] && [ ! -x "${INSTALL_DIR}/hysteria" ]; then
        echo "未检测到 hy2 节点，请先搭建。"
        return
    fi
    local status="未运行"
    if command -v systemctl >/dev/null 2>&1 && [ -f "${SERVICE_DIR}/hysteria-server.service" ]; then
        local s enabled
        s="$(systemctl is-active hysteria-server 2>/dev/null || true)"
        case "$s" in
            active) status="运行中" ;;
            inactive) status="已停止" ;;
            failed) status="启动失败" ;;
            *) status="未知" ;;
        esac
        enabled="$(systemctl is-enabled hysteria-server 2>/dev/null || true)"
        if [ "$enabled" = "enabled" ]; then
            status="${status}（开机自启：已启用）"
        fi
    elif pgrep -f "hysteria server" >/dev/null 2>&1; then
        status="运行中（未用 systemd）"
    fi
    echo "运行状态：${status}"
    load_node_info
    if [ -n "$NODE_PORT" ]; then
        local port_hex listening
        port_hex="$(printf '%04X' "$NODE_PORT")"
        listening="否"
        if grep -qi ":${port_hex} " /proc/net/udp /proc/net/udp6 2>/dev/null; then
            listening="是"
        fi
        echo "监听端口：${NODE_PORT}（正在监听：${listening}）"
    fi
    echo
    echo "---------- 节点信息（可复制到 v2rayN） ----------"
    print_node_info
    echo "--------------------------------------------------"
    echo "提示：复制上面的链接，v2rayN 里用“从剪贴板导入”即可添加。"
}

# 更换端口
change_port() {
    echo "---------- 更换端口 ----------"
    if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
        echo "未检测到 hy2 节点，请先搭建。"
        return
    fi
    check_root || return
    local current_port new_port
    current_port="$(grep '^listen:' "${CONFIG_DIR}/config.yaml" | sed 's/^listen: *://;s/ *$//')"
    echo "当前端口：${current_port}"
    new_port="$(read_port "$current_port")"
    if [ "$new_port" = "$current_port" ]; then
        echo "端口未变，无需操作。"
        return
    fi
    sed -i "s/^listen: :.*/listen: :${new_port}/" "${CONFIG_DIR}/config.yaml"
    if [ -f "${CONFIG_DIR}/node.info" ]; then
        sed -i "s/^NODE_PORT=.*/NODE_PORT=${new_port}/" "${CONFIG_DIR}/node.info"
    fi
    if [ -f "${SERVICE_DIR}/hysteria-server.service" ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl daemon-reload && systemctl restart hysteria-server; then
            echo "服务已重启，新端口已生效。"
        else
            echo "服务重启失败，请手动检查。"
        fi
    else
        echo "未使用 systemd 服务，请手动重启 hy2 服务使新端口生效："
        echo "  先停掉旧进程，再跑：${INSTALL_DIR}/hysteria server -c ${CONFIG_DIR}/config.yaml"
    fi
    echo "端口已更换为 ${new_port}。"
    echo
    echo "---------- 新节点信息 ----------"
    print_node_info
}

# 卸载 hy2
uninstall_hy2() {
    echo "---------- 卸载 hy2 ----------"
    if [ ! -f "${CONFIG_DIR}/config.yaml" ] && [ ! -x "${INSTALL_DIR}/hysteria" ]; then
        echo "未检测到 hy2 节点，无需卸载。"
        return
    fi
    check_root || return
    local confirm=""
    read -rp "确认卸载吗？这会删除服务、程序、配置和证书，操作不可撤销。(y/N): " confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) echo "已取消卸载。"; return ;;
    esac
    if [ -f "${SERVICE_DIR}/hysteria-server.service" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop hysteria-server 2>/dev/null || true
        systemctl disable hysteria-server 2>/dev/null || true
        rm -f "${SERVICE_DIR}/hysteria-server.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    pkill -f "hysteria server" 2>/dev/null || true
    rm -f "${INSTALL_DIR}/hysteria"
    if [ -n "$CONFIG_DIR" ] && [ "$CONFIG_DIR" != "/" ]; then
        rm -rf "$CONFIG_DIR"
    fi
    echo "hy2 已卸载（服务、程序、配置和证书已删除）。"
    echo "注意：acme.sh 的证书数据（~/.acme.sh/域名）未删除，如需彻底清理可手动删除；"
    echo "重装同域名时会复用已有证书数据。"
}

# ---------- vless+reality（Xray） ----------
# 做法按 https://jollyroger.top/sites/512.html 的 Reality 一节：
# Xray 官方安装脚本安装，配置用官方防偷流量模板——dokodemo-door 监听对外端口，
# 转发给本机 127.0.0.1 内网端口的 reality 入站；不匹配伪装域名的流量直接丢弃。

# 安装 Xray：已安装就跳过，否则用官方安装脚本安装
install_xray() {
    if command -v "$XRAY_BIN" >/dev/null 2>&1; then
        echo "xray 已安装，跳过下载。"
        return 0
    fi
    echo "正在安装 xray（官方安装脚本）..."
    local installer=""
    installer="$(curl -fsSL --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" || {
        echo "安装脚本下载失败：连不上 GitHub，请检查网络后重试。"
        return 1
    }
    if [ -z "$installer" ]; then
        echo "安装脚本下载失败：下载到空文件，请检查网络后重试。"
        return 1
    fi
    # 注意：新版官方安装脚本没有 -u 选项，服务默认以 xray 用户运行；
    # 教程里写的 -u root 是旧版的写法，现在传了会报 unknown option
    if ! bash -c "$installer" @ install; then
        echo "xray 安装失败：上面是官方安装脚本的报错，请把上面几行发给我再定位。"
        return 1
    fi
    echo "xray 已安装。"
}

# 生成 UUID：优先用 xray uuid，失败时用系统随机 UUID
gen_reality_uuid() {
    local uuid=""
    uuid="$("$XRAY_BIN" uuid 2>/dev/null)"
    if [ -z "$uuid" ]; then
        uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
    fi
    echo "$uuid"
}

# 生成 x25519 密钥对：设置 REALITY_PRIVKEY / REALITY_PUBKEY
# 新版 xray 输出是 "PrivateKey: ..." / "Password (PublicKey): ..."，
# 旧版是 "Private key: ..." / "Public key: ..."，两种都兼容
gen_reality_keypair() {
    local output=""
    output="$("$XRAY_BIN" x25519 2>/dev/null)"
    REALITY_PRIVKEY="$(echo "$output" | grep -i 'private' | head -n 1 | sed 's/^[^:]*:[[:space:]]*//;s/[[:space:]]//g')"
    REALITY_PUBKEY="$(echo "$output" | grep -i 'public' | head -n 1 | sed 's/^[^:]*:[[:space:]]*//;s/[[:space:]]//g')"
}

# 生成 reality 服务端配置：参数依次为 对外端口 内网端口 UUID 私钥 shortId 伪装域名
gen_reality_config() {
    local ext_port="$1" int_port="$2" uuid="$3" privkey="$4" shortid="$5" sni="$6"
    mkdir -p "$REALITY_CONFIG_DIR"
    cat > "${REALITY_CONFIG_DIR}/config.json" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "dokodemo-in",
            "port": ${ext_port},
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1",
                "port": ${int_port},
                "network": "tcp"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "tls"
                ],
                "routeOnly": true
            }
        },
        {
            "listen": "127.0.0.1",
            "port": ${int_port},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${uuid}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "${sni}:443",
                    "serverNames": [
                        "${sni}"
                    ],
                    "privateKey": "${privkey}",
                    "shortIds": [
                        "",
                        "${shortid}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "routing": {
        "rules": [
            {
                "inboundTag": [
                    "dokodemo-in"
                ],
                "domain": [
                    "${sni}"
                ],
                "outboundTag": "direct"
            },
            {
                "inboundTag": [
                    "dokodemo-in"
                ],
                "outboundTag": "block"
            }
        ]
    }
}
EOF
    echo "服务端配置已生成：${REALITY_CONFIG_DIR}/config.json"
}

# 安装并启动 xray 服务；官方安装脚本一般已建好服务文件，没有就按官方格式补一个；
# 没有 systemctl 时给出手动启动命令
install_reality_service() {
    local xray_path service_file
    xray_path="$(command -v "$XRAY_BIN" 2>/dev/null || echo /usr/local/bin/xray)"
    service_file="${SERVICE_DIR}/xray.service"
    if [ ! -f "$service_file" ]; then
        mkdir -p "$SERVICE_DIR"
        cat > "$service_file" <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=${xray_path} run -config ${REALITY_CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "本机没有 systemctl，无法安装系统服务，请手动启动："
        echo "  ${xray_path} run -config ${REALITY_CONFIG_DIR}/config.json"
        return 0
    fi
    if systemctl daemon-reload && systemctl enable --now xray; then
        echo "服务已启动：xray"
        return 0
    fi
    echo "systemd 服务启动失败，请手动检查或手动启动："
    echo "  ${xray_path} run -config ${REALITY_CONFIG_DIR}/config.json"
    return 1
}

# 保存 reality 节点信息（供查看、换端口时复用）：
# 参数依次为 地址 端口 UUID 公钥 私钥 shortId 伪装域名
save_reality_node_info() {
    local host="$1" port="$2" uuid="$3" pubkey="$4" privkey="$5" shortid="$6" sni="$7"
    mkdir -p "$REALITY_CONFIG_DIR"
    {
        printf 'REALITY_HOST=%q\n' "$host"
        printf 'REALITY_PORT=%q\n' "$port"
        printf 'REALITY_UUID=%q\n' "$uuid"
        printf 'REALITY_PUBKEY=%q\n' "$pubkey"
        printf 'REALITY_PRIVKEY=%q\n' "$privkey"
        printf 'REALITY_SHORTID=%q\n' "$shortid"
        printf 'REALITY_SNI=%q\n' "$sni"
    } > "${REALITY_CONFIG_DIR}/node.info"
}

# 读取 reality 节点信息；
# 没有 node.info 时从 config.json 推断（公钥用私钥反推）；没有配置返回 1
load_reality_node_info() {
    REALITY_HOST=""; REALITY_PORT=""; REALITY_UUID=""; REALITY_PUBKEY=""; REALITY_PRIVKEY=""; REALITY_SHORTID=""; REALITY_SNI=""
    if [ -f "${REALITY_CONFIG_DIR}/node.info" ]; then
        # shellcheck disable=SC1090
        . "${REALITY_CONFIG_DIR}/node.info"
    fi
    if [ -n "$REALITY_PORT" ]; then
        return 0
    fi
    if [ ! -f "${REALITY_CONFIG_DIR}/config.json" ]; then
        return 1
    fi
    local cfg="${REALITY_CONFIG_DIR}/config.json"
    REALITY_PORT="$(grep -m1 '"port"' "$cfg" | sed 's/[^0-9]//g')"
    REALITY_UUID="$(grep -m1 '"id"' "$cfg" | sed 's/.*"id": *"\([^"]*\)".*/\1/')"
    REALITY_PRIVKEY="$(grep -m1 '"privateKey"' "$cfg" | sed 's/.*"privateKey": *"\([^"]*\)".*/\1/')"
    REALITY_SNI="$(grep -m1 '"serverNames"' -A2 "$cfg" | grep -o '"[^"]*"' | tail -n 1 | tr -d '"')"
    REALITY_SHORTID="$(grep -m1 '"shortIds"' -A3 "$cfg" | grep -o '"[0-9a-f]*"' | tail -n 1 | tr -d '"')"
    REALITY_HOST="$(detect_public_ip)"
    if [ -z "$REALITY_HOST" ]; then
        REALITY_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    if [ -n "$REALITY_PRIVKEY" ] && command -v "$XRAY_BIN" >/dev/null 2>&1; then
        REALITY_PUBKEY="$("$XRAY_BIN" x25519 -i "$REALITY_PRIVKEY" 2>/dev/null | grep -i 'public' | head -n 1 | sed 's/^[^:]*:[[:space:]]*//;s/[[:space:]]//g')"
    fi
    return 0
}

# 打印 reality 节点信息（含可复制到 v2rayN 的链接）
print_reality_node_info() {
    load_reality_node_info || return 1
    if [ -z "$REALITY_PORT" ] || [ -z "$REALITY_UUID" ]; then
        echo "节点信息不完整（缺少端口或 UUID）。"
        return 1
    fi
    echo "地址：${REALITY_HOST}"
    echo "端口：${REALITY_PORT}"
    echo "UUID：${REALITY_UUID}"
    echo "伪装域名（SNI）：${REALITY_SNI}"
    echo "公钥：${REALITY_PUBKEY}"
    echo "shortId：${REALITY_SHORTID}"
    if [ -n "$REALITY_HOST" ] && [ -n "$REALITY_PUBKEY" ]; then
        echo "链接：vless://${REALITY_UUID}@${REALITY_HOST}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBKEY}&sid=${REALITY_SHORTID}&type=tcp#reality-node"
    else
        echo "链接：无法确定服务器地址或公钥，请把下面链接中的“服务器地址”换成你的 IP："
        echo "vless://${REALITY_UUID}@服务器地址:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBKEY}&sid=${REALITY_SHORTID}&type=tcp#reality-node"
    fi
    return 0
}

# 搭建 reality
install_reality() {
    check_root || return
    echo "---------- 搭建 vless+reality ----------"
    echo "说明：用 Xray 官方安装脚本安装，配置按防偷流量模板生成；"
    echo "不需要域名和证书，伪装域名默认 speed.cloudflare.com。"
    local port sni uuid shortid int_port host
    port="$(read_port 443)"
    read -rp "请输入伪装域名（留空默认 speed.cloudflare.com）: " sni
    sni="${sni:-speed.cloudflare.com}"
    install_xray || return
    uuid="$(gen_reality_uuid)"
    if [ -z "$uuid" ]; then
        echo "UUID 生成失败。"
        return
    fi
    gen_reality_keypair
    if [ -z "$REALITY_PRIVKEY" ] || [ -z "$REALITY_PUBKEY" ]; then
        echo "密钥生成失败。"
        return
    fi
    shortid="$(openssl rand -hex 8 2>/dev/null)"
    if [ -z "$shortid" ]; then
        shortid="0123456789abcdef"
    fi
    int_port="$REALITY_INTERNAL_PORT"
    if [ "$port" = "$int_port" ]; then
        int_port=4432
    fi
    gen_reality_config "$port" "$int_port" "$uuid" "$REALITY_PRIVKEY" "$shortid" "$sni"
    echo "正在检查配置..."
    if ! "$XRAY_BIN" -test -config "${REALITY_CONFIG_DIR}/config.json"; then
        echo "配置文件检查失败，请检查上面的报错。"
        return
    fi
    host="$(detect_public_ip)"
    if [ -z "$host" ]; then
        host="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    if [ -z "$host" ]; then
        read -rp "未能自动获取服务器 IP，请手动输入： " host
    fi
    save_reality_node_info "$host" "$port" "$uuid" "$REALITY_PUBKEY" "$REALITY_PRIVKEY" "$shortid" "$sni"
    install_reality_service
    echo
    echo "==================== 搭建完成 ===================="
    print_reality_node_info
    echo "=================================================="
    echo
}

# 查看 reality 节点：当前状态 + 节点信息
view_reality_node() {
    echo "---------- 查看节点 ----------"
    if [ ! -f "${REALITY_CONFIG_DIR}/config.json" ] && ! command -v "$XRAY_BIN" >/dev/null 2>&1; then
        echo "未检测到 reality 节点，请先搭建。"
        return
    fi
    local status="未运行"
    if command -v systemctl >/dev/null 2>&1 && [ -f "${SERVICE_DIR}/xray.service" ]; then
        local s enabled
        s="$(systemctl is-active xray 2>/dev/null || true)"
        case "$s" in
            active) status="运行中" ;;
            inactive) status="已停止" ;;
            failed) status="启动失败" ;;
            *) status="未知" ;;
        esac
        enabled="$(systemctl is-enabled xray 2>/dev/null || true)"
        if [ "$enabled" = "enabled" ]; then
            status="${status}（开机自启：已启用）"
        fi
    elif pgrep -f "xray run" >/dev/null 2>&1; then
        status="运行中（未用 systemd）"
    fi
    echo "运行状态：${status}"
    load_reality_node_info
    if [ -n "$REALITY_PORT" ]; then
        local port_hex listening
        port_hex="$(printf '%04X' "$REALITY_PORT")"
        listening="否"
        if grep -qi ":${port_hex} " /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
            listening="是"
        fi
        echo "监听端口：${REALITY_PORT}（正在监听：${listening}）"
    fi
    echo
    echo "---------- 节点信息（可复制到 v2rayN） ----------"
    print_reality_node_info
    echo "--------------------------------------------------"
    echo "提示：复制上面的链接，v2rayN 里用“从剪贴板导入”即可添加。"
}

# 更换 reality 端口（只改对外端口，内网端口不变）
change_reality_port() {
    echo "---------- 更换端口 ----------"
    if [ ! -f "${REALITY_CONFIG_DIR}/config.json" ]; then
        echo "未检测到 reality 节点，请先搭建。"
        return
    fi
    check_root || return
    local current_port new_port int_port
    current_port="$(grep -m1 '"port"' "${REALITY_CONFIG_DIR}/config.json" | sed 's/[^0-9]//g')"
    echo "当前端口：${current_port}"
    new_port="$(read_port "$current_port")"
    if [ "$new_port" = "$current_port" ]; then
        echo "端口未变，无需操作。"
        return
    fi
    load_reality_node_info
    if [ -z "$REALITY_UUID" ] || [ -z "$REALITY_PRIVKEY" ]; then
        echo "节点信息不完整（缺少 UUID 或私钥），无法重新生成配置。"
        return
    fi
    int_port="$REALITY_INTERNAL_PORT"
    if [ "$new_port" = "$int_port" ]; then
        int_port=4432
    fi
    gen_reality_config "$new_port" "$int_port" "$REALITY_UUID" "$REALITY_PRIVKEY" "$REALITY_SHORTID" "$REALITY_SNI"
    if [ -f "${REALITY_CONFIG_DIR}/node.info" ]; then
        sed -i "s/^REALITY_PORT=.*/REALITY_PORT=${new_port}/" "${REALITY_CONFIG_DIR}/node.info"
    fi
    if [ -f "${SERVICE_DIR}/xray.service" ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl daemon-reload && systemctl restart xray; then
            echo "服务已重启，新端口已生效。"
        else
            echo "服务重启失败，请手动检查。"
        fi
    else
        echo "未使用 systemd 服务，请手动重启 reality 服务使新端口生效："
        echo "  先停掉旧进程，再跑：$(command -v "$XRAY_BIN" 2>/dev/null || echo /usr/local/bin/xray) run -config ${REALITY_CONFIG_DIR}/config.json"
    fi
    echo "端口已更换为 ${new_port}。"
    echo
    echo "---------- 新节点信息 ----------"
    print_reality_node_info
}

# 卸载 reality
uninstall_reality() {
    echo "---------- 卸载 reality ----------"
    if [ ! -f "${REALITY_CONFIG_DIR}/config.json" ] && ! command -v "$XRAY_BIN" >/dev/null 2>&1; then
        echo "未检测到 reality 节点，无需卸载。"
        return
    fi
    check_root || return
    local confirm=""
    read -rp "确认卸载吗？这会删除服务、程序、配置，操作不可撤销。(y/N): " confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) echo "已取消卸载。"; return ;;
    esac
    if [ -f "${SERVICE_DIR}/xray.service" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        rm -f "${SERVICE_DIR}/xray.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    pkill -f "xray run" 2>/dev/null || true
    local xray_path=""
    xray_path="$(command -v "$XRAY_BIN" 2>/dev/null || true)"
    if [ -n "$xray_path" ]; then
        rm -f "$xray_path"
    fi
    if [ -n "$REALITY_CONFIG_DIR" ] && [ "$REALITY_CONFIG_DIR" != "/" ]; then
        rm -rf "$REALITY_CONFIG_DIR"
    fi
    echo "reality 已卸载（服务、程序、配置已删除）。"
}

# ---------- 菜单 ----------

# hy2 安装子菜单：选搭建方式
menu_hy2_install() {
    while true; do
        echo
        echo "========== 搭建 hy2 =========="
        echo "1. 没有域名（自签证书）"
        echo "2. 有域名"
        echo "0. 返回"
        echo "=============================="
        read -rp "请输入数字: " choice
        case "$choice" in
            1) install_hy2_no_domain; pause ;;
            2) install_hy2_with_domain; pause ;;
            0) return ;;
            *) echo "输入无效，请重新输入。" ;;
        esac
    done
}

# hy2 菜单：搭建、查看、换端口、卸载都归在这里
menu_hy2() {
    while true; do
        echo
        echo "========== hy2 =========="
        echo "1. 搭建 hy2"
        echo "2. 查看节点"
        echo "3. 更换端口"
        echo "4. 卸载 hy2"
        echo "0. 返回"
        echo "=============================="
        read -rp "请输入数字: " choice
        case "$choice" in
            1) menu_hy2_install ;;
            2) view_node; pause ;;
            3) change_port; pause ;;
            4) uninstall_hy2; pause ;;
            0) return ;;
            *) echo "输入无效，请重新输入。" ;;
        esac
    done
}

# reality 菜单：搭建、查看、换端口、卸载都归在这里
menu_reality() {
    while true; do
        echo
        echo "========== vless+reality =========="
        echo "1. 搭建 reality"
        echo "2. 查看节点"
        echo "3. 更换端口"
        echo "4. 卸载 reality"
        echo "0. 返回"
        echo "=============================="
        read -rp "请输入数字: " choice
        case "$choice" in
            1) install_reality; pause ;;
            2) view_reality_node; pause ;;
            3) change_reality_port; pause ;;
            4) uninstall_reality; pause ;;
            0) return ;;
            *) echo "输入无效，请重新输入。" ;;
        esac
    done
}

# 搭建节点菜单：按协议分行，以后加新协议（xhttp 等）时在这里另起一行
menu_build() {
    while true; do
        echo
        echo "========== 搭建节点 =========="
        echo "1. hy2"
        echo "2. vless+reality"
        echo "0. 返回"
        echo "=============================="
        read -rp "请输入数字: " choice
        case "$choice" in
            1) menu_hy2 ;;
            2) menu_reality ;;
            0) return ;;
            *) echo "输入无效，请重新输入。" ;;
        esac
    done
}

# 安装快捷键：把脚本本体放到 /usr/local/bin/imagine.sh，
# 并创建 x 和 X 两个软链（不区分大小写），之后输入 x 或 X 即可打开菜单。
# 已存在且指向别处的同名文件不会被覆盖；非 root 运行时跳过安装。
install_shortcut() {
    if [ "$(id -u)" -ne 0 ]; then
        return 0
    fi
    local self_path target link created
    target="/usr/local/bin/imagine.sh"
    case "${BASH_SOURCE[0]}" in
        /dev/fd/*)
            # 通过管道/进程替换运行（如 bash <(curl ...)）时，脚本不在真实文件里，
            # 从仓库下载一份再安装快捷键
            echo "正在从仓库下载脚本以安装快捷键..."
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL "$IMAGINE_URL" -o "$target" || { echo "下载失败，未安装快捷键。"; return 0; }
            elif command -v wget >/dev/null 2>&1; then
                wget -q "$IMAGINE_URL" -O "$target" || { echo "下载失败，未安装快捷键。"; return 0; }
            else
                echo "提示：本机没有 curl 或 wget，无法安装快捷键；"
                echo "请先装 curl 再运行：apt install -y curl"
                return 0
            fi
            chmod +x "$target"
            ;;
        *)
            self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")"
            if [ -z "$self_path" ]; then
                return 0
            fi
            if [ "$self_path" != "$target" ]; then
                cp "$self_path" "$target" && chmod +x "$target"
            fi
            ;;
    esac
    # 复制/下载失败就不要建快捷键，避免留下指向不存在文件的坏链接
    if [ ! -s "$target" ]; then
        echo "提示：快捷键安装失败（无法获取脚本文件）。"
        return 0
    fi
    created=0
    for link in /usr/local/bin/x /usr/local/bin/X; do
        if [ -L "$link" ]; then
            if [ "$(readlink -f "$link")" != "$target" ]; then
                echo "提示：${link} 已存在且指向别处，未覆盖。"
            fi
        elif [ -e "$link" ]; then
            echo "提示：${link} 已存在且不是快捷键，未覆盖。"
        else
            ln -s "$target" "$link"
            created=1
        fi
    done
    if [ "$created" = "1" ]; then
        echo "快捷键已安装：输入 x 或 X 即可打开菜单。"
    fi
}

menu_main() {
    install_shortcut
    while true; do
        echo
        echo "========== 主菜单 =========="
        echo "1. 搭建节点"
        echo "0. 退出"
        echo "============================="
        read -rp "请输入数字: " choice
        case "$choice" in
            1) menu_build ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "输入无效，请重新输入。" ;;
        esac
    done
}

# 被 source 引入时只定义函数，不跑主菜单；直接执行时跑主菜单
if (return 0 2>/dev/null); then
    return 0
fi
menu_main
