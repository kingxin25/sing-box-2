#!/bin/bash
# Local account registry: one account maps to one sing-box JSON profile.
account_db="$is_core_dir/accounts.tsv"

account_list() {
    local account config expiry quota
    [[ -s $account_db ]] || { msg "还没有登记本地账号。"; return; }
    printf '%-20s %-32s %-16s %s\n' "账号" "配置" "到期日" "流量额度"
    while IFS=$'\t' read -r account config expiry quota; do
        [[ $account && $config ]] || continue
        [[ $expiry == 0 || ! $expiry ]] && expiry="永久" || expiry=$(date -d "@$expiry" '+%F' 2>/dev/null || printf '未知')
        [[ $quota == 0 || ! $quota ]] && quota="未设置"
        printf '%-20s %-32s %-16s %s GB\n' "$account" "$config" "$expiry" "$quota"
    done < "$account_db"
    msg "流量额度目前仅登记；逐账号流量采集和超额停用尚未接入。"
}
account_register() {
    local account config expiry quota epoch temp file
    shopt -s nullglob; local files=("$is_conf_dir"/*.json); shopt -u nullglob
    (("${#files[@]}" == 0)) && { msg "请先添加 sing-box 节点。"; return 1; }
    msg "选择配置（一个配置作为一个本地账号）:"
    select file in "${files[@]##*/}" "取消"; do
        [[ $file == "取消" || ! $file ]] && return
        config=${file%.json}; break
    done
    read -r -p "账号名称: " account
    [[ $account =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || { msg "名称仅支持 1-32 位字母、数字、点、下划线、短横线。"; return 1; }
    read -r -p "到期日 YYYY-MM-DD（留空为永久）: " expiry
    epoch=0
    if [[ $expiry ]]; then
        [[ $expiry =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { msg "日期格式无效。"; return 1; }
        epoch=$(date -d "$expiry 23:59:59" +%s 2>/dev/null) || { msg "日期无法解析。"; return 1; }
        ((epoch > $(date +%s))) || { msg "到期日必须是未来日期。"; return 1; }
    fi
    read -r -p "流量额度 GB（仅登记，暂不强制）: " quota
    [[ ! $quota || $quota =~ ^[0-9]+([.][0-9]+)?$ ]] || { msg "额度必须是非负数字。"; return 1; }
    quota=${quota:-0}
    mkdir -p "$is_core_dir"; touch "$account_db"
    temp=$(mktemp "$is_core_dir/.accounts.XXXXXX") || return 1
    awk -F '\t' -v c="$config" '$2 != c' "$account_db" > "$temp"
    printf '%s\t%s\t%s\t%s\n' "$account" "$config" "$epoch" "$quota" >> "$temp"
    chmod 600 "$temp"; mv -f "$temp" "$account_db"
    msg "账号资料已保存。启用到期检查后，到期配置会自动停用。"
}
account_enforce_expiry() {
    local account config expiry quota now changed=0 src dst
    now=$(date +%s); [[ -f $account_db ]] || return 0
    while IFS=$'\t' read -r account config expiry quota; do
        [[ $config =~ ^[A-Za-z0-9._-]+$ ]] || continue
        src="$is_conf_dir/$config.json"; dst="$is_conf_dir/$config.json.disabled"
        if [[ $expiry =~ ^[0-9]+$ ]] && ((expiry > 0 && expiry < now)) && [[ -f $src ]]; then
            mv -- "$src" "$dst" && msg "已停用到期账号: $account ($config)" && changed=1
        elif [[ $expiry =~ ^[0-9]+$ ]] && ((expiry == 0 || expiry >= now)) && [[ -f $dst && ! -e $src ]]; then
            mv -- "$dst" "$src" && msg "已恢复未到期账号: $account ($config)" && changed=1
        fi
    done < "$account_db"
    [[ $changed == 1 ]] && manage restart
}
account_install_timer() {
    if [[ $is_systemd ]]; then
        cat >/etc/systemd/system/sing-box-account-enforce.service <<'UNIT'
[Unit]
Description=Enforce local sing-box account expiry
[Service]
Type=oneshot
ExecStart=/usr/local/bin/sing-box account-enforce
UNIT
        cat >/etc/systemd/system/sing-box-account-enforce.timer <<'UNIT'
[Unit]
Description=Check local sing-box account expiry
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
        systemctl daemon-reload && systemctl enable --now sing-box-account-enforce.timer
    elif [[ $is_openrc && -d /etc/periodic ]]; then
        mkdir -p /etc/periodic/5min
        printf '%s\n' '#!/bin/sh' '/usr/local/bin/sing-box account-enforce' >/etc/periodic/5min/sing-box-account-enforce
        chmod 700 /etc/periodic/5min/sing-box-account-enforce
        msg "已加入 OpenRC periodic 任务；请确认 crond 已启用。"
    else msg "当前系统不支持已知的定时服务。"; return 1; fi
    msg "自动到期检查已启用（每 5 分钟）。"
}
account_menu() {
    local c
    while :; do
        msg "\n=== 单机本地用户 ==="
        msg "1 登记/更新账号  2 查看账号  3 启用到期停用  4 立即检查到期"
        msg "流量配额暂为登记项，强制执行后端尚未接入。  0 返回"
        read -r -p "选择: " c
        case $c in
        1) account_register ;; 2) account_list ;; 3) account_install_timer ;; 4) account_enforce_expiry ;;
        0|"") return ;; *) msg "无效选项。" ;;
        esac
    done
}
