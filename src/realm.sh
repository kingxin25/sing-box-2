#!/bin/bash

# Realm network forwarding manager integration for xwPF.
# xwPF is maintained at https://github.com/zywe03/realm-xwPF (MIT License).

realm_manager() {
    local entry="/usr/local/bin/xwPF.sh"
    local module_dir="/usr/local/bin/lib"
    local script_url="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh"
    local tmp_file module rc

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        msg "Realm 管理需要 root 权限。请使用: sudo sing-box realm"
        return 1
    fi

    if [[ -e "$entry" || -L "$entry" ]]; then
        if [[ -L "$entry" || ! -f "$entry" ]] || ! grep -q '^# xwPF - Realm' "$entry"; then
            msg "检测到 /usr/local/bin/xwPF.sh 已存在，但无法确认它属于 xwPF。为避免执行或覆盖其他文件，已停止。"
            return 1
        fi
        if [[ "${1:-}" == "install" && ( -e /usr/local/bin/pf || -L /usr/local/bin/pf ) ]]; then
            if [[ ! -L /usr/local/bin/pf || "$(readlink -f /usr/local/bin/pf 2>/dev/null)" != "$entry" ]]; then
                msg "检测到 /usr/local/bin/pf 指向其他文件。为避免覆盖现有命令，已停止 xwPF 更新。"
                return 1
            fi
        fi
        if [[ $# -eq 0 ]]; then
            for module in core.sh rules.sh server.sh realm.sh ui.sh; do
                if [[ ! -f "$module_dir/$module" ]]; then
                    msg "xwPF 模块不完整。请运行: sing-box realm install"
                    return 1
                fi
            done
        fi
        bash "$entry" "$@"
        return $?
    fi

    if [[ $# -gt 0 && "$1" != "install" ]]; then
        msg "xwPF 尚未安装。请先运行: sing-box realm install"
        return 1
    fi

    # xwPF's installer creates /usr/local/bin/pf and writes five modules to
    # /usr/local/bin/lib. Avoid overwriting unrelated commands or files.
    if [[ -e /usr/local/bin/pf || -L /usr/local/bin/pf ]]; then
        msg "检测到 /usr/local/bin/pf 已存在。为避免覆盖现有命令，请先检查冲突后再安装 xwPF。"
        return 1
    fi
    if [[ -L "$module_dir" ]]; then
        msg "检测到 $module_dir 是符号链接。为避免写入其他目录，已停止安装 xwPF。"
        return 1
    fi
    for module in core.sh rules.sh server.sh realm.sh ui.sh; do
        if [[ -e "$module_dir/$module" || -L "$module_dir/$module" ]]; then
            msg "检测到 $module_dir/$module 已存在。为避免覆盖现有文件，已停止安装 xwPF。"
            return 1
        fi
    done

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        msg "安装 xwPF 需要 curl 或 wget。"
        return 1
    fi

    tmp_file=$(mktemp) || {
        msg "无法创建 xwPF 临时下载文件。"
        return 1
    }

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 90 "$script_url" -o "$tmp_file"
        rc=$?
    else
        wget -qO "$tmp_file" "$script_url"
        rc=$?
    fi
    if [[ $rc -ne 0 || ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        msg "下载 xwPF 失败，请检查网络后重试。"
        return 1
    fi

    bash "$tmp_file" install
    rc=$?
    rm -f "$tmp_file"
    return "$rc"
}
