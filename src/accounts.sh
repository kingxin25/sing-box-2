#!/bin/bash
# Local account registry; one account maps to one tagged inbound.
account_db="$is_core_dir/accounts.tsv"
account_stats_bin="$is_sh_dir/bin/account-stats"

account_stats_install() {
    [[ -x $account_stats_bin ]] && return 0
    local asset tmp
    asset="account-stats-linux-$is_arch"
    mkdir -p "$(dirname "$account_stats_bin")"
    tmp=$(mktemp) || return 1
    if ! _wget -qO "$tmp" "https://github.com/$is_sh_repo/releases/latest/download/$asset"; then
        rm -f "$tmp"; msg "下载统计采集器失败，请先安装项目最新 Release 核心。"; return 1
    fi
    install -m 755 "$tmp" "$account_stats_bin"; rm -f "$tmp"
}

account_update_api() {
    local tags_file tmp_config tags config
    [[ -f $account_db ]] || return 0
    tags_file=$(mktemp) || return 1
    while IFS=$'\t' read -r _ config _; do
        [[ $config =~ ^[A-Za-z0-9._-]+$ && -f "$is_conf_dir/$config.json" ]] && printf '%s\n' "$config" >> "$tags_file"
    done < "$account_db"
    tags=$(jq -Rn '[inputs | select(length > 0)]' < "$tags_file") || { rm -f "$tags_file"; return 1; }
    rm -f "$tags_file"
    tmp_config=$(mktemp "${is_config_json}.XXXXXX") || return 1
    if ! jq --argjson tags "$tags" '.experimental = (.experimental // {}) | .experimental.v2ray_api = {listen:"127.0.0.1:12080",stats:{enabled:true,inbounds:$tags}}' "$is_config_json" > "$tmp_config"; then
        rm -f "$tmp_config"; return 1
    fi
    if ! "$is_core_bin" check -c "$tmp_config" -C "$is_conf_dir" >/dev/null 2>&1; then
        rm -f "$tmp_config"; msg "统计 API 配置检查失败，未覆盖现有配置。"; return 1
    fi
    chmod --reference="$is_config_json" "$tmp_config" 2>/dev/null || chmod 600 "$tmp_config"
    mv -f "$tmp_config" "$is_config_json"
}

account_usage_bytes() {
    local used=${2:-0} delta
    [[ $used =~ ^[0-9]+$ ]] || used=0
    delta=$("$account_stats_bin" "$1" 2>/dev/null) || return 1
    [[ $delta =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$((used + delta))"
}
account_quota_exceeded() {
    awk -v used="$1" -v quota="$2" 'BEGIN { exit !(quota > 0 && used >= quota * 1073741824) }'
}

account_list() {
    local account config expiry quota used used_gb
    [[ -s $account_db ]] || { msg "还没有登记本地账号。"; return 0; }
    printf '%-18s %-24s %-12s %-12s %s\n' "账号" "配置" "到期日" "额度(GB)" "已用(GB)"
    while IFS=$'\t' read -r account config expiry quota used; do
        [[ $account && $config ]] || continue
        [[ $expiry == 0 || ! $expiry ]] && expiry="永久" || expiry=$(date -d "@$expiry" '+%F' 2>/dev/null || printf '未知')
        [[ $quota == 0 || ! $quota ]] && quota="不限"
        [[ $used =~ ^[0-9]+$ ]] || used=0
        used_gb=$(awk -v n="$used" 'BEGIN {printf "%.3f", n/1073741824}')
        printf '%-18s %-24s %-12s %-12s %s\n' "$account" "$config" "$expiry" "$quota" "$used_gb"
    done < "$account_db"
    msg "用量按定时采集累计；核心重启前尚未采集的短时流量可能丢失。"
}

account_register() {
    local account config expiry quota epoch temp file used=0
    shopt -s nullglob; local files=("$is_conf_dir"/*.json "$is_conf_dir"/*.json.disabled); shopt -u nullglob
    (("${#files[@]}" == 0)) && { msg "请先添加 sing-box 节点。"; return 1; }
    msg "选择配置（一个配置作为一个本地账号）:"
    select file in "${files[@]##*/}" "取消"; do
        [[ $file == "取消" || ! $file ]] && return
        config=${file##*/}; config=${config%.disabled}; config=${config%.json}; break
    done
    read -r -p "账号名称: " account
    [[ $account =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || { msg "账号名称格式无效。"; return 1; }
    read -r -p "到期日 YYYY-MM-DD（留空为永久）: " expiry
    epoch=0
    if [[ $expiry ]]; then
        [[ $expiry =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { msg "日期格式无效。"; return 1; }
        epoch=$(date -d "$expiry 23:59:59" +%s 2>/dev/null) || { msg "日期无法解析。"; return 1; }
        ((epoch > $(date +%s))) || { msg "到期日必须是未来日期。"; return 1; }
    fi
    read -r -p "流量额度 GB（0 表示不限）: " quota
    [[ ! $quota || $quota =~ ^[0-9]+([.][0-9]+)?$ ]] || { msg "额度必须是非负数字。"; return 1; }
    quota=${quota:-0}
    [[ -s $account_db ]] && used=$(awk -F '\t' -v c="$config" '$2==c {print $5;exit}' "$account_db")
    [[ $used =~ ^[0-9]+$ ]] || used=0
    mkdir -p "$is_core_dir"; touch "$account_db"
    temp=$(mktemp "$is_core_dir/.accounts.XXXXXX") || return 1
    awk -F '\t' -v c="$config" '$2!=c' "$account_db" > "$temp"
    printf '%s\t%s\t%s\t%s\t%s\n' "$account" "$config" "$epoch" "$quota" "$used" >> "$temp"
    chmod 600 "$temp"; mv -f "$temp" "$account_db"
    account_stats_install && account_update_api || return 1
    manage restart
    msg "账号已登记；额度超限后会在下一次检查时停用该配置。"
}

account_enforce_quota() {
    [[ -s $account_db ]] || return 0
    account_stats_install || return 1
    local account config expiry quota used updated temp changed=0
    temp=$(mktemp "$is_core_dir/.accounts.XXXXXX") || return 1
    while IFS=$'\t' read -r account config expiry quota used; do
        [[ $config =~ ^[A-Za-z0-9._-]+$ ]] || continue
        [[ $used =~ ^[0-9]+$ ]] || used=0
        if [[ -f "$is_conf_dir/$config.json" ]]; then
            updated=$(account_usage_bytes "$config" "$used") || { rm -f "$temp"; msg "读取 $config 流量失败，本轮未更新额度数据。"; return 1; }
            used=$updated
            if account_quota_exceeded "$used" "$quota"; then
                mv -- "$is_conf_dir/$config.json" "$is_conf_dir/$config.json.disabled" || { rm -f "$temp"; return 1; }
                changed=1; msg "账号已达到流量额度，配置已停用：$account ($config)"
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$account" "$config" "$expiry" "$quota" "$used" >> "$temp"
    done < "$account_db"
    chmod 600 "$temp"; mv -f "$temp" "$account_db"
    if [[ $changed == 1 ]]; then account_update_api && manage restart; fi
}

account_enforce_expiry() {
    local account config expiry quota used now changed=0
    account_enforce_quota || msg "额度检查未完成；仍将检查账号到期时间。"
    now=$(date +%s); [[ -f $account_db ]] || return 0
    while IFS=$'\t' read -r account config expiry quota used; do
        [[ $config =~ ^[A-Za-z0-9._-]+$ ]] || continue
        if [[ $expiry =~ ^[0-9]+$ ]] && ((expiry > 0 && expiry < now)) && [[ -f "$is_conf_dir/$config.json" ]]; then
            mv -- "$is_conf_dir/$config.json" "$is_conf_dir/$config.json.disabled" && changed=1
            msg "已停用到期账号：$account ($config)"
        elif [[ $expiry =~ ^[0-9]+$ ]] && ((expiry == 0 || expiry >= now)) && [[ -f "$is_conf_dir/$config.json.disabled" ]] && ! account_quota_exceeded "${used:-0}" "$quota"; then
            mv -- "$is_conf_dir/$config.json.disabled" "$is_conf_dir/$config.json" && changed=1
            msg "已恢复未到期且未超额账号：$account ($config)"
        fi
    done < "$account_db"
    if [[ $changed == 1 ]]; then account_update_api && manage restart; fi
}

account_install_timer() {
    if [[ $is_systemd ]]; then
        cat >/etc/systemd/system/sing-box-account-enforce.service <<'UNIT'
[Unit]
Description=Enforce local sing-box account limits
[Service]
Type=oneshot
ExecStart=/usr/local/bin/sing-box account-enforce
UNIT
        cat >/etc/systemd/system/sing-box-account-enforce.timer <<'UNIT'
[Unit]
Description=Check local sing-box account limits
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
        systemctl daemon-reload && systemctl enable --now sing-box-account-enforce.timer || { msg "systemd 定时器启用失败。"; return 1; }
    elif [[ $is_openrc && -d /etc/periodic ]]; then
        mkdir -p /etc/periodic/15min
        printf '%s\n' '#!/bin/sh' '/usr/local/bin/sing-box account-enforce' >/etc/periodic/15min/sing-box-account-enforce
        chmod 700 /etc/periodic/15min/sing-box-account-enforce
        msg "已加入 OpenRC 15 分钟任务；请确认 crond 已启用。"
    else msg "当前系统不支持已知的定时服务。"; return 1; fi
    msg "自动到期与流量限额检查已启用。"
}

account_remove() {
    local account temp
    read -r -p "要解除登记的账号名称: " account
    [[ $account =~ ^[A-Za-z0-9_.-]{1,32}$ && -s $account_db ]] || { msg "账号名称无效。"; return 1; }
    awk -F '\t' -v n="$account" '$1==n {found=1} END {exit !found}' "$account_db" || { msg "未找到账号。"; return 1; }
    panel_confirm "只删除账号登记，不删除节点文件；已停用配置将保持停用?" || return
    temp=$(mktemp "$is_core_dir/.accounts.XXXXXX") || return 1
    awk -F '\t' -v n="$account" '$1!=n' "$account_db" > "$temp"
    chmod 600 "$temp"; mv -f "$temp" "$account_db"
    account_update_api && manage restart
    msg "账号登记已解除。"
}

account_menu() {
    local c
    while :; do
        msg "\n=== 单机本地用户 ==="
        msg "1 登记/更新账号  2 查看账号  3 启用到期/限额检查  4 立即检查  5 解除登记"
        read -r -p "选择: " c
        case $c in
        1) account_register ;; 2) account_list ;; 3) account_install_timer ;; 4) account_enforce_expiry ;; 5) account_remove ;;
        0|"") return ;; *) msg "无效选项。" ;;
        esac
    done
}
