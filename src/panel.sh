#!/bin/bash
# Grouped interactive menu for sing-box.

panel_confirm() { local answer; read -r -p "$1 [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]]; }
panel_pause() { read -r -p "按 Enter 返回..." _; }

panel_export_urls() {
    local f n u label out count=0
    mkdir -p "$is_core_dir/exports"
    out="$is_core_dir/exports/personal-subscription.txt"
    : >"$out"
    shopt -s nullglob; local files=("$is_conf_dir"/*.json); shopt -u nullglob
    for f in "${files[@]}"; do
        n=${f##*/}; n=${n%.json}
        u=$( (is_dont_show_info=1; info "$n" >/dev/null 2>&1; printf '%s' "$is_url") )
        [[ $u ]] || continue
        read -r -p "节点显示名称 [$n]: " label
        label=${label:-$n}
        [[ $label =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { msg "名称仅支持字母、数字、点、下划线、短横线；本项跳过。"; continue; }
        printf '%s#%s\n' "${u%%#*}" "$label" >>"$out"
        ((count++))
    done
    if ((count > 0)); then chmod 640 "$out"; msg "订阅已更新: $out（权限 640）"
    else rm -f "$out"; msg "没有可导出的节点链接。"; return 1; fi
}
panel_https_subscription() {
    local domain token snippet tmp backup
    [[ $is_caddy && -x $is_caddy_bin ]] || { msg "需要先安装并启用 Caddy。"; return 1; }
    command -v getent >/dev/null 2>&1 && getent group caddy >/dev/null || { msg "未找到 caddy 组，无法安全授权订阅文件读取。"; return 1; }
    panel_export_urls || return 1
    read -r -p "已解析到本机的订阅域名: " domain
    [[ $domain =~ ^[A-Za-z0-9.-]+[.][A-Za-z]{2,}$ ]] || { msg "域名格式无效。"; return 1; }
    token=$(openssl rand -hex 24) || return 1
    snippet="$is_caddy_conf/sing-box-personal-subscription.conf"
    tmp=$(mktemp) || return 1
    backup=$(mktemp) || { rm -f "$tmp"; return 1; }
    [[ -f $snippet ]] && cp -p "$snippet" "$backup" || : >"$backup"
    mkdir -p "$is_caddy_conf"
    cat >"$tmp" <<EOF
${domain} {
    @private_subscription path /s/${token}
    handle @private_subscription {
        root * ${is_core_dir}/exports
        rewrite * /personal-subscription.txt
        header Content-Type text/plain
        file_server
    }
    handle {
        respond 404
    }
}
EOF
    mv -f "$tmp" "$snippet"
    if ! "$is_caddy_bin" validate --config "$is_caddyfile"; then
        if [[ -s $backup ]]; then cp -p "$backup" "$snippet"; else rm -f "$snippet"; fi
        rm -f "$backup"; msg "Caddy 配置验证失败，已回滚。"; return 1
    fi
    rm -f "$backup"
    chown root:caddy "$is_core_dir/exports/personal-subscription.txt"
    chmod 640 "$is_core_dir/exports/personal-subscription.txt"
    manage restart caddy || return 1
    printf '%s\n' "https://${domain}/s/${token}" >"$is_core_dir/exports/personal-subscription.url"
    chmod 600 "$is_core_dir/exports/personal-subscription.url"
    msg "HTTPS 个人订阅已配置。请确保域名解析到本机且 80/443 可访问。"
    msg "订阅地址: https://${domain}/s/${token}"
}

panel_accounts() {
    load accounts.sh
    account_menu
}
panel_services() {
    local c
    while :; do
        msg "\n=== 服务与日志 ==="
        msg "1 状态  2 启动  3 停止  4 重启  5 日志  6 Argo 状态  0 返回"
        read -r -p "选择: " c
        case $c in
        1) msg "$is_core_name $is_core_ver: $is_core_status"; [[ $is_caddy ]] && msg "Caddy $is_caddy_ver: $is_caddy_status" ;;
        2) manage start ;;
        3) panel_confirm "停止 sing-box?" && manage stop ;;
        4) panel_confirm "重启 sing-box?" && manage restart ;;
        5) load log.sh; log_set ;;
        6) if command -v cloudflared >/dev/null 2>&1; then pgrep -af '[c]loudflared' || msg "cloudflared 未运行。"; else msg "未安装 cloudflared；Argo 未配置。"; fi ;;
        0|"") return ;;
        *) msg "无效选项。" ;;
        esac
        panel_pause
    done
}
panel_resources() {
    uptime; free -h 2>/dev/null || true; df -h / 2>/dev/null || true
    if command -v vnstat >/dev/null 2>&1; then vnstat --oneline 2>/dev/null || vnstat
    else msg "未安装 vnstat，累计流量统计不可用。"; fi
}
panel_firewall() {
    local c port proto
    if ! command -v ufw >/dev/null 2>&1; then msg "未安装 UFW；不会自动启用防火墙，以免中断远程访问。"; return; fi
    while :; do
        ufw status numbered; msg "1 放行端口  2 删除规则  0 返回"
        read -r -p "选择: " c
        case $c in
        1)
            read -r -p "端口 (1-65535): " port
            [[ $port =~ ^[0-9]{1,5}$ ]] && ((port>0 && port<=65535)) || { msg "端口无效。"; continue; }
            read -r -p "协议 [tcp/udp/both，默认 both]: " proto
            case ${proto:-both} in
            tcp|udp) panel_confirm "放行 $port/$proto?" && ufw allow "$port/$proto" ;;
            both|"") panel_confirm "放行 TCP 和 UDP $port?" && { ufw allow "$port/tcp"; ufw allow "$port/udp"; } ;;
            *) msg "协议无效。" ;;
            esac ;;
        2) read -r -p "规则编号: " port; [[ $port =~ ^[0-9]+$ ]] && panel_confirm "删除规则 $port?" && ufw --force delete "$port" ;;
        0|"") return ;;
        *) msg "无效选项。" ;;
        esac
    done
}
panel_initialize() {
    local manager
    [[ $EUID == 0 ]] || { msg "需要 root 权限。"; return 1; }
    manager=$cmd
    [[ $manager ]] || manager=$(command -v apt-get || command -v dnf || command -v yum || command -v zypper || command -v apk)
    [[ $manager ]] || { msg "未识别的包管理器。"; return 1; }
    msg "将安装基础管理依赖 curl、jq、openssl、tar、vnstat。"
    panel_confirm "继续初始化?" || return
    case $manager in
    *apk*) apk add --no-cache curl jq openssl tar vnstat || return 1 ;;
    *apt-get*) apt-get update && apt-get install -y curl jq openssl tar vnstat || return 1 ;;
    *dnf*) dnf install -y curl jq openssl tar vnstat || return 1 ;;
    *yum*) yum install -y curl jq openssl tar vnstat || return 1 ;;
    *zypper*) zypper --non-interactive install curl jq openssl tar vnstat || return 1 ;;
    *) msg "当前包管理器未适配。"; return 1 ;;
    esac
    if [[ $is_systemd ]]; then systemctl enable --now vnstat 2>/dev/null || true
    elif [[ $is_openrc ]]; then rc-update add vnstat default 2>/dev/null || true; rc-service vnstat start 2>/dev/null || true; fi
    msg "初始化完成；vnstat 开始采集后才会显示历史流量。"
}
panel_streaming_connectivity() {
    local name url code
    command -v curl >/dev/null 2>&1 || { msg "请先运行服务器初始化安装 curl。"; return 1; }
    msg "此项只检查服务器到服务首页的 HTTPS 连通性，不判定地区解锁状态。"
    local -a services=(
        "Netflix|https://www.netflix.com/"
        "Disney+|https://www.disneyplus.com/"
        "Prime Video|https://www.primevideo.com/"
        "YouTube|https://www.youtube.com/"
        "TikTok|https://www.tiktok.com/"
    )
    for entry in "${services[@]}"; do
        name=${entry%%|*}; url=${entry#*|}
        code=$(curl -L -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 "$url" 2>/dev/null)
        [[ $code ]] || code=000
        printf '%-12s HTTPS %s\\n' "$name" "$code"
    done
}
panel_network() {
    local c
    while :; do
        msg "\n=== 服务器与网络 ==="
        msg "1 初始化  2 资源/流量  3 UFW  4 BBR  5 WARP 状态  6 sing-box 中转  7 xwPF Realm  8 流媒体连通性  0 返回"
        read -r -p "选择: " c
        case $c in
        1) panel_initialize ;;
        2) panel_resources ;;
        3) panel_firewall ;;
        4) load bbr.sh; _try_enable_bbr ;;
        5) if command -v warp-cli >/dev/null 2>&1; then warp-cli status; elif ip link show 2>/dev/null | grep -qi warp; then ip -brief link | grep -i warp; else msg "未检测到 WARP 客户端/接口。"; fi ;;
        6) msg "$is_core_name $is_core_ver: $is_core_status"; msg "尚无中转拓扑向导；当前管理本机节点配置。" ;;
        7) realm_manager ;;
        8) panel_streaming_connectivity ;;
        0|"") return ;;
        *) msg "无效选项。" ;;
        esac
        panel_pause
    done
}
panel_backup() {
    local dir="$is_core_dir/backups" stamp plain archive password again
    local paths=()
    mkdir -p "$dir" || return 1
    stamp=$(date +%Y%m%d-%H%M%S); archive="$dir/sing-box-$stamp.tar.gz.enc"
    plain=$(mktemp "$dir/.backup-XXXXXX.tar.gz") || return 1
    [[ -d /etc/sing-box ]] && paths+=(etc/sing-box)
    [[ -d /etc/caddy ]] && paths+=(etc/caddy)
    [[ -d /etc/letsencrypt ]] && paths+=(etc/letsencrypt)
    [[ -x /usr/local/bin/sing-box ]] && paths+=(usr/local/bin/sing-box)
    (("${#paths[@]}" == 0)) && { rm -f "$plain"; msg "没有可备份的数据。"; return 1; }
    tar -czf "$plain" -C / "${paths[@]}" || { rm -f "$plain"; return 1; }
    read -r -s -p "设置加密密码: " password; echo
    [[ $password ]] || { rm -f "$plain"; msg "密码不能为空。"; return 1; }
    read -r -s -p "再次输入密码: " again; echo
    [[ $password == "$again" ]] || { unset password again; rm -f "$plain"; msg "两次密码不一致。"; return 1; }
    if printf '%s' "$password" | openssl enc -aes-256-cbc -pbkdf2 -salt -pass stdin -in "$plain" -out "$archive"; then
        chmod 600 "$archive"; rm -f "$plain"; msg "加密备份: $archive"
    else rm -f "$plain" "$archive"; msg "备份加密失败。"; fi
    unset password again
}
panel_restore() {
    local archive temp password confirm
    read -r -p "备份文件 (.tar.gz.enc): " archive
    [[ -f $archive && $archive == *.tar.gz.enc ]] || { msg "备份文件无效。"; return 1; }
    temp=$(mktemp) || return 1
    read -r -s -p "备份密码: " password; echo
    if ! printf '%s' "$password" | openssl enc -d -aes-256-cbc -pbkdf2 -pass stdin -in "$archive" -out "$temp"; then
        rm -f "$temp"; unset password; msg "解密失败。"; return 1
    fi
    unset password
    tar -tzf "$temp" >/dev/null || { rm -f "$temp"; msg "备份内容无效。"; return 1; }
    local bad_entry= entry
    while IFS= read -r entry; do
        case "$entry" in etc/sing-box|etc/sing-box/*|etc/caddy|etc/caddy/*|etc/letsencrypt|etc/letsencrypt/*|usr/local/bin/sing-box) ;;
        *) bad_entry=$entry; break ;; esac
    done < <(tar -tzf "$temp")
    [[ $bad_entry ]] && { rm -f "$temp"; msg "备份含有允许范围之外的路径，已拒绝恢复。"; return 1; }
    msg "恢复将覆盖备份中的 sing-box/Caddy/证书文件。"
    read -r -p "输入 RESTORE 确认: " confirm
    if [[ $confirm == RESTORE ]]; then tar -xzf "$temp" -C /; msg "恢复完成；请检查配置并重启服务。"
    else msg "已取消恢复。"; fi
    rm -f "$temp"
}
panel_updates() {
    local c
    msg "\n1 更新内核  2 更新管理脚本  3 更新 Caddy  4 加密备份  5 恢复备份  6 证书状态  0 返回"
    read -r -p "选择: " c
    case $c in
    1) update core ;; 2) update sh ;; 3) [[ $is_caddy ]] && update caddy || msg "Caddy 尚未安装。" ;;
    4) panel_backup ;; 5) panel_restore ;;
    6) if [[ $is_caddy ]]; then msg "Caddy $is_caddy_ver: $is_caddy_status"; [[ -d /var/lib/caddy ]] && du -sh /var/lib/caddy
       else msg "Caddy/ACME 未配置；域名 TLS 节点可由 Caddy 自动申请证书。"; fi ;;
    0|"") return ;; *) msg "无效选项。" ;;
    esac
}
panel_nodes() {
    local c
    msg "\n1 添加节点/协议  2 修改参数  3 删除节点  4 查看节点  5 不自动申请 TLS 添加  0 返回"
    read -r -p "选择: " c
    case $c in 1) add ;; 2) change ;; 3) del ;; 4) info ;; 5) is_no_auto_tls=1; add; unset is_no_auto_tls ;; 0|"") return ;; *) msg "无效选项。" ;; esac
}
panel_subscriptions() {
    local c
    msg "\n1 节点信息/URL  2 二维码  3 生成/更新订阅文件  4 本地账号管理  5 配置 HTTPS 个人订阅  0 返回"
    read -r -p "选择: " c
    case $c in 1) info ;; 2) url_qr qr ;; 3) panel_export_urls ;; 4) panel_accounts ;; 5) panel_https_subscription ;; 0|"") return ;; *) msg "无效选项。" ;; esac
}
panel_settings() {
    local c
    msg "\n1 使用说明  2 隐私说明  3 卸载  0 返回"
    read -r -p "选择: " c
    case $c in
    1) load help.sh; show_help ;;
    2) msg "配置和订阅凭据保存在本机；导出文件需妥善保管。xwPF 由上游项目维护。" ;;
    3) panel_confirm "将删除 sing-box 配置和管理脚本，继续?" && uninstall ;;
    0|"") return ;; *) msg "无效选项。" ;;
    esac
}
panel_main() {
    local c
    while :; do
        msg "\n========== sing-box 管理面板 =========="
        msg "1 节点安装  2 节点与订阅  3 服务与日志"
        msg "4 服务器与网络  5 更新与备份  6 设置与卸载"
        msg "7 用户与配额  0 退出"
        read -r -p "选择菜单: " c
        case $c in
        1) panel_nodes ;; 2) panel_subscriptions ;; 3) panel_services ;; 4) panel_network ;;
        5) panel_updates ;; 6) panel_settings ;; 7) panel_accounts; panel_pause ;;
        0|"") return ;; *) msg "无效选项。" ;;
        esac
    done
}
