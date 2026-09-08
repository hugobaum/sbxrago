#!/usr/bin/env bash
AIRGOSBX_VERSION='V26.09.08.5'
# 仅在内置 XHTTP 默认参数改变时更新此标记，普通脚本版本更新不使旧命令失效。
XHTTP_DEFAULTS_VERSION='V26.09.08.1'
agsbxurl="${agsbxurl:-https://raw.githubusercontent.com/hugobaum/sbxrago/refs/heads/main/airgosbx.sh}"
# SSL.com EAB 仅在 ACME 注册步骤按需读取，禁止无关子进程继承敏感凭据。
export -n sslcom_eab_kid sslcom_eab_hmac fmpass fmheader \
  vl_fmpass xh_fmpass vx_fmpass vw_fmpass vm_fmpass hy_fmpass \
  vx_fmheader vw_fmheader vm_fmheader hy_fmheader 2>/dev/null || true
export -n xheaders64 xh_xheaders64 vx_xheaders64 xvd_xheaders64 xva_xheaders64 2>/dev/null || true
export -n uuid obfs_pass subid securl naiveuser naivepass mieruuser mierupass agk ARGO_AUTH \
  CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID 2>/dev/null || true
# 说明：脚本使用了花括号展开、echo 转义等 Bash 语法，且安装后的 agsbx 快捷方式会按 shebang 执行；
# 固定使用 bash 可避免在以 dash 作为 /bin/sh 的系统（如 Debian/Ubuntu）上 `agsbx rep` 等命令静默失效。
#============================================================
# Airgosbx - 安全加固版一键代理部署脚本
# 基于 yonggekkk/argosbx
# 仓库：github.com/hugobaum/sbxrago
#============================================================

#============================================================
# [本地保护] 本脚本只允许在 Linux VPS 上运行，防止 macOS 误执行
#============================================================
os_name=$(uname -s 2>/dev/null || echo unknown)
if [ "$os_name" != "Linux" ]; then
echo "安全保护：airgosbx.sh 仅用于 Linux VPS，当前系统为 $os_name，已终止。"
return 1 2>/dev/null || exit 1
fi

is_root(){
  [ "$(id -u 2>/dev/null)" = "0" ]
}

# 进程探测助手：判断 agsbx 管理的 sing-box / xray / caddy 内核或 Mieru 代理是否在运行。
# 此前该长管道在第 1/8/12 段被逐字复制三次，现统一收敛为单一函数，杜绝逻辑漂移与维护遗漏。
agsbx_running(){
  agsbx_component_running xray || agsbx_component_running sing-box || agsbx_component_running caddy \
    || { [ -f "$HOME/agsbx/mita_managed" ] && command -v mita >/dev/null 2>&1 && mita status 2>/dev/null | grep -q 'RUNNING'; }
}

# 一次批量读取 /proc 可执行文件链接；NUL 分隔避免特殊文件名混淆记录。
# GNU find 在单进程内读取链接；其他平台保留逐项 readlink，不降低匹配范围。
agsbx_process_exe_links(){
  local proc_exe resolved
  if [ "$agsbx_find_printf" = yes ]; then
    find /proc -mindepth 2 -maxdepth 2 -name exe -type l -printf '%p\0%l\0' 2>/dev/null
  else
    for proc_exe in /proc/[0-9]*/exe; do
      [ -L "$proc_exe" ] || continue
      resolved=$(readlink -f "$proc_exe" 2>/dev/null) || continue
      printf '%s\0%s\0' "$proc_exe" "$resolved"
    done
  fi
}

# 安装完成判定必须按本轮必需组件逐项检查，不能由另一个仍存活的内核掩盖失败。
agsbx_component_pids(){
  local component="$1" expected_exe proc_exe resolved pid
  case "$component" in
    xray) expected_exe="$HOME/agsbx/xray" ;;
    sing-box) expected_exe="$HOME/agsbx/sing-box" ;;
    caddy) expected_exe="$HOME/agsbx/caddy" ;;
    cloudflared) expected_exe="$HOME/agsbx/cloudflared" ;;
    *) return 1 ;;
  esac
  while IFS= read -r -d '' proc_exe && IFS= read -r -d '' resolved; do
    [[ "$proc_exe" =~ ^/proc/[0-9]+/exe$ ]] || continue
    resolved=${resolved% (deleted)}
    if [ "$resolved" = "$expected_exe" ]; then
      pid=${proc_exe#/proc/}; printf '%s\n' "${pid%/exe}"
    fi
  done < <(agsbx_process_exe_links)
}

agsbx_component_running(){
  [ -n "$(agsbx_component_pids "$1")" ]
}

stop_component_processes(){
  local component="$1" pid attempt
  for pid in $(agsbx_component_pids "$component"); do
    kill -TERM "$pid" 2>/dev/null || { kill -0 "$pid" 2>/dev/null && return 1; }
  done
  for attempt in {1..10}; do
    agsbx_component_running "$component" || return 0
    sleep 1
  done
  echo "错误：$component 进程尚未停止，保留其配置和文件。" >&2
  return 1
}

# 通用服务名仅在路径与受管可执行文件吻合时才属于本脚本。
managed_service_names(){
  case "$1" in
    xray) managed_sd=xr; managed_rc=xray; managed_bin=xray ;;
    sing-box|sb) managed_sd=sb; managed_rc=sing-box; managed_bin=sing-box ;;
    cloudflared|argo) managed_sd=argo; managed_rc=argo; managed_bin=cloudflared ;;
    caddy) managed_sd=agsbx-caddy; managed_rc=agsbx-caddy; managed_bin=caddy ;;
    *) return 1 ;;
  esac
}

service_file_owned(){
  local path="$1" component="$2" backend="$3" executable
  managed_service_names "$component" || return 1
  executable="$HOME/agsbx/$managed_bin"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  case "$backend" in
    systemd) awk -v executable="$executable" '
      /^[[:space:]]*ExecStart=/ {
        line=$0; sub(/^[[:space:]]*/, "", line); count++
        if (index(line, "ExecStart=" executable " ") == 1 || index(line, "ExecStart=\"" executable "\" ") == 1) valid++
      }
      END {exit !(count == 1 && valid == 1)}
    ' "$path" ;;
    openrc) grep -Fxq "command=\"$executable\"" "$path" || { [ "$component" = cloudflared ] && grep -Fxq "command=\"$executable tunnel\"" "$path"; } ;;
    *) return 1 ;;
  esac
}

# 返回 0=受管，1=不存在，2=归属冲突。不得将冲突当作不存在覆盖。
managed_service_state(){
  local component="$1" path fragment
  managed_service_names "$component" || return 2
  if pidof systemd >/dev/null 2>&1; then
    path="/etc/systemd/system/$managed_sd.service"
    if [ -e "$path" ] || [ -L "$path" ]; then
      service_file_owned "$path" "$component" systemd && return 0
      return 2
    fi
    if [ "$component" = caddy ] && service_file_owned /etc/systemd/system/caddy.service caddy systemd; then
      managed_sd=caddy; return 0
    fi
    fragment=$(systemctl show "$managed_sd.service" -p LoadState -p FragmentPath 2>/dev/null)
    if printf '%s\n' "$fragment" | grep -Fxq 'LoadState=not-found'; then return 1; fi
    return 2
  elif command -v rc-service >/dev/null 2>&1; then
    path="/etc/init.d/$managed_rc"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      if [ "$component" = caddy ] && service_file_owned /etc/init.d/caddy caddy openrc; then managed_rc=caddy; return 0; fi
      return 1
    fi
    service_file_owned "$path" "$component" openrc && return 0
    return 2
  fi
  return 1
}

require_service_slot(){
  local state
  managed_service_state "$1" && return 0
  state=$?
  [ "$state" = 1 ] && return 0
  echo "错误：$1 服务名已被其他软件占用或无法确认归属，拒绝操作。" >&2
  return 1
}

stop_managed_service(){
  local component="$1" remove="${2:-no}" state
  if managed_service_state "$component"; then
    if pidof systemd >/dev/null 2>&1; then
      systemctl stop "$managed_sd" || return 1
      if [ "$remove" = yes ]; then
        # 省略 systemd 的链接删除提示，错误输出与返回值仍保留。
        systemctl --quiet disable "$managed_sd" || return 1
        rm -f -- "/etc/systemd/system/$managed_sd.service" || return 1
      fi
    else
      rc-service "$managed_rc" stop || return 1
      if [ "$remove" = yes ]; then
        rc-update del "$managed_rc" default || return 1
        rm -f -- "/etc/init.d/$managed_rc" || return 1
      fi
    fi
  else
    state=$?
    [ "$state" != 2 ] || echo "提示：保留不属于 Airgosbx 的 $component 服务。" >&2
  fi
  stop_component_processes "$component"
}

component_listener_specs(){
  case "$1" in
    xray)
      printf '%s\n' 'xhttp-reality:port_xh:tcp' 'reality-vision:port_vl_re:tcp' \
        'vless-xhttp:port_vx:tcp' 'vless-ws:port_vw:tcp' 'vmess-xr:port_vm_ws:tcp' \
        'socks5-xr:port_so:tcp' 'hy2-xr:port_xhy2:udp' 'vless-kcp-xdns:port_xdns:udp' \
        'vlessenc-xhttp-cdn:port_xvcdn:tcp' 'vlessenc-xhttp-argo:port_xvargo:tcp' \
        'sub-https-proxy:subport.log:tcp' ;;
    sing-box)
      printf '%s\n' 'hy2-sb:port_hy2:udp' 'tuic5-sb:port_tu:udp' 'anytls-sb:port_an:tcp' \
        'anyreality-sb:port_ar:tcp' 'ss-2022:port_ss:tcp' 'vmess-sb:port_vm_ws:tcp' \
        'socks5-sb:port_so:tcp' 'naive-secondary-in:naive_secondary_port:tcp' \
        'sub-https-proxy:subport.log:tcp' ;;
    *) return 1 ;;
  esac
}

component_owns_listener(){
  local core="$1" port="$2" network="$3" output pids
  valid_port "$port" || return 1
  if [ "$#" = 5 ]; then pids="$4"; output="$5"
  else
    pids=$(agsbx_component_pids "$core")
    output=$(ss -H -lntup 2>/dev/null) || return 1
  fi
  [ -n "$pids" ] || return 1
  printf '%s\n' "$output" | awk -v port="$port" -v net="$network" -v pids="$pids" '
    BEGIN {count=split(pids, ids, /[[:space:]]+/)}
    $1 == net && $5 ~ (":" port "$") {
      for (i=1; i<=count; i++) if (ids[i] != "" && index($0, "pid=" ids[i] ",")) found=1
    }
    END {exit !found}'
}

wait_component_listeners(){
  local core="$1" config tag file network port ready attempt pids listeners entry
  local -a planned_ports=()
  if [ "$core" = caddy ]; then
    for attempt in {1..5}; do component_owns_listener caddy 443 tcp && return 0; sleep 1; done
    return 1
  fi
  [ "$core" = xray ] && config=xr.json || config=sb.json
  # 同一次等待只读取一次配置与端口计划；每轮重新采集运行状态，避免跨操作缓存 PID。
  while IFS=: read -r tag file network; do
    grep -Fq "\"$tag\"" "$HOME/agsbx/$config" 2>/dev/null || continue
    IFS= read -r port < "$HOME/agsbx/$file" || return 1
    valid_port "$port" || return 1
    planned_ports+=("$port:$network")
  done < <(component_listener_specs "$core")
  for attempt in {1..5}; do
    ready=yes
    pids=$(agsbx_component_pids "$core")
    listeners=$(ss -H -lntup 2>/dev/null) || return 1
    [ -n "$pids" ] || ready=no
    for entry in "${planned_ports[@]}"; do
      component_owns_listener "$core" "${entry%:*}" "${entry#*:}" "$pids" "$listeners" || ready=no
    done
    [ "$ready" != yes ] || return 0
    sleep 1
  done
  echo "错误：$core 未监听其已配置端口。"
  return 1
}

wait_agsbx_component(){
  local component="$1" attempt
  for attempt in {1..5}; do
    agsbx_component_running "$component" && return 0
    sleep 1
  done
  return 1
}

subscription_http_binary(){
  local candidate path candidates
  if command -v apk >/dev/null 2>&1; then
    candidates="busybox-extras busybox"
  else
    candidates="busybox busybox-extras"
  fi
  for candidate in $candidates; do
    path=$(command -v "$candidate" 2>/dev/null) || continue
    "$path" --list 2>/dev/null | grep -qx 'httpd' || continue
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

subscription_http_managed_pids(){
  local proc proc_exe resolved arg index pid
  local -a args
  while IFS= read -r -d '' proc_exe && IFS= read -r -d '' resolved; do
    [[ "$proc_exe" =~ ^/proc/[0-9]+/exe$ ]] || continue
    proc="${proc_exe%/exe}/cmdline"
    [ -r "$proc" ] || continue
    case "${resolved##*/}" in busybox|busybox-extras) ;; *) continue ;; esac
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done < "$proc"
    [ "${args[1]:-}" = httpd ] || continue
    for ((index=2; index+1<${#args[@]}; index++)); do
      if [ "${args[index]}" = -h ] && [ "${args[index+1]}" = "$HOME/websbx" ]; then
        pid=${proc#/proc/}; printf '%s\n' "${pid%/cmdline}"
        break
      fi
    done
  done < <(agsbx_process_exe_links)
}

subscription_http_managed_is_running(){
  [ -n "$(subscription_http_managed_pids)" ]
}

stop_subscription_http(){
  local pid attempt
  for pid in $(subscription_http_managed_pids); do
    kill -TERM "$pid" 2>/dev/null || { kill -0 "$pid" 2>/dev/null && return 1; }
  done
  for attempt in {1..10}; do
    subscription_http_managed_is_running || return 0
    sleep 1
  done
  echo "错误：订阅服务尚未停止，拒绝替换其文件。" >&2
  return 1
}

read_crontab_or_empty(){
  local destination="$1" error_file
  crontab_read_state=error
  error_file=$(mktemp) || return 1
  if LC_ALL=C crontab -l > "$destination" 2> "$error_file"; then
    crontab_read_state=present
    rm -f "$error_file"
    return 0
  fi
  local user message
  user=$(id -un) || { rm -f "$error_file"; return 1; }
  message=$(cat "$error_file")
  if [ "$message" = "no crontab for $user" ] || [ "$message" = "crontab: no crontab for $user" ] \
    || [ "$message" = "crontab: can't open '$user': No such file or directory" ] \
    || [ "$message" = "crontab: can't open '/var/spool/cron/crontabs/$user': No such file or directory" ] \
    || [ "$message" = "crontab: can't open '/var/spool/cron/$user': No such file or directory" ]; then
    : > "$destination"
    crontab_read_state=absent
    rm -f "$error_file"
    return 0
  fi
  echo "错误：无法读取现有 crontab，拒绝覆盖。"
  rm -f "$error_file"
  return 1
}

managed_script_path(){
  local candidate
  for candidate in /usr/local/bin/agsbx /usr/bin/agsbx "$HOME/bin/agsbx"; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      shortcut_is_owned "$candidate" || { echo "错误：快捷命令路径被其他软件占用：$candidate" >&2; return 1; }
      printf '%s' "$candidate"; return 0
    fi
  done
  printf '%s' /usr/local/bin/agsbx
}

write_managed_cron(){
  local marker="$1" entry="$2" legacy="${3:-}" before after line
  command -v crontab >/dev/null 2>&1 || { echo "错误：无法注册维护任务，缺少 crontab。"; return 1; }
  before=$(mktemp) && after=$(mktemp) || return 1
  read_crontab_or_empty "$before" || { rm -f "$before" "$after"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *"# $marker") continue ;; esac
    [ -z "$legacy" ] || [ "$line" != "$legacy" ] || continue
    printf '%s\n' "$line" >> "$after" || { rm -f "$before" "$after"; return 1; }
  done < "$before"
  printf '%s # %s\n' "$entry" "$marker" >> "$after" \
    && crontab "$after" >/dev/null 2>&1 || { rm -f "$before" "$after"; return 1; }
  rm -f "$before" "$after"
}

shortcut_is_owned(){
  [ -f "$1" ] && [ ! -L "$1" ] && grep -q '^AIRGOSBX_VERSION=' "$1" \
    && grep -Fq '# Airgosbx -' "$1"
}

component_cron_line(){
  local component="$1"
  case "$component" in
    xray|sing-box)
      printf '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/%s run -c $HOME/agsbx/%s.json > $HOME/agsbx/%s.log 2>&1 &"' \
        "$component" "$([ "$component" = xray ] && printf xr || printf sb)" "$component" ;;
    caddy)
      printf '%s' '@reboot sleep 10 && /bin/sh -c "rm -f $HOME/agsbx/caddy-admin.sock; nohup $HOME/agsbx/caddy run --config $HOME/agsbx/Caddyfile > $HOME/agsbx/caddy.log 2>&1 &"' ;;
    *) return 1 ;;
  esac
}

legacy_naive_cron_matches(){
  local naive_secondary_port expected
  naive_secondary_port=$(cat "$HOME/agsbx/naive_secondary_port" 2>/dev/null)
  valid_port "$naive_secondary_port" || return 1
  expected='@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json > $HOME/agsbx/sing-box.log 2>&1 & i=0; while [ \$i -lt 20 ]; do if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -q 127.0.0.1:'"$naive_secondary_port"' && break; elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | grep -q 127.0.0.1:'"$naive_secondary_port"' && break; fi; i=\$((i + 1)); sleep 1; done; rm -f $HOME/agsbx/caddy-admin.sock; nohup $HOME/agsbx/caddy run --config $HOME/agsbx/Caddyfile > $HOME/agsbx/caddy.log 2>&1 &"'
  [ "$1" = "$expected" ]
}

filter_component_cron(){
  local source="$1" destination="$2" mode="$3" line component expected managed
  : > "$destination" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    managed=no
    for component in xray sing-box caddy; do
      case "$component:$mode" in caddy:rep|caddy:runtime-rep) continue ;; esac
      expected=$(component_cron_line "$component") || return 1
      if [ "$line" = "$expected" ] || [ "$line" = "$expected # AIRGOSBX_CORE" ]; then managed=yes; break; fi
    done
    case "$mode:$line" in del:*'# AIRGOSBX_HOPPING'|rep:*'# AIRGOSBX_HOPPING') managed=yes ;; esac
    if argo_cron_line_is_managed "$line"; then managed=yes
    elif [ "$?" = 2 ]; then echo "错误：Argo 旧启动项无法安全识别，已保留。"; return 1; fi
    if subscription_cron_line_is_managed "$line"; then managed=yes
    elif [ "$?" = 2 ]; then echo "错误：订阅旧启动项无法安全识别，已保留。"; return 1; fi
    if [ "$mode" = del ] && legacy_naive_cron_matches "$line"; then managed=yes; fi
    if [ "$mode" = del ]; then
      case "$line" in
        "30 2 * * * /bin/bash $HOME/agsbx/acme.sh --cron --home $HOME/agsbx/acme > /dev/null 2>&1"|\
        "20 3 * * * /bin/bash $HOME/agsbx/caddy_cert_reload.sh > /dev/null 2>&1"|\
        *'# AIRGOSBX_CERT_RENEW'|*'# AIRGOSBX_CERT_RELOAD') managed=yes ;;
      esac
    fi
    [ "$managed" = no ] || continue
    printf '%s\n' "$line" >> "$destination" || return 1
  done < "$source"
}

# 新目录有归属标记；旧目录只接受脚本曾生成的两种订阅符号链接。
subscription_tree_is_owned(){
  local root="$HOME/websbx" directory file target
  [ ! -L "$root" ] && [ -d "$root" ] || return 1
  [ "$(stat -c '%u' "$root" 2>/dev/null)" = 0 ] || return 1
  if [ -f "$root/.airgosbx-subscription" ] && [ ! -L "$root/.airgosbx-subscription" ] \
    && [ "$(cat "$root/.airgosbx-subscription")" = AIRGOSBX_SUBSCRIPTION_V1 ]; then return 0; fi
  for directory in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [ -e "$directory" ] || [ -L "$directory" ] || continue
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    for file in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      [ -L "$file" ] || return 1
      target=$(readlink "$file") || return 1
      case "${file##*/}:$target" in
        "clmi.yaml:$HOME/agsbx/clmi.yaml"|"jhsub.txt:$HOME/agsbx/jh.txt") ;;
        *) return 1 ;;
      esac
    done
  done
}

remove_subscription_tree(){
  [ -e "$HOME/websbx" ] || [ -L "$HOME/websbx" ] || return 0
  subscription_tree_is_owned || { echo "错误：websbx 目录含有非受管内容，已保留。" >&2; return 1; }
  rm -rf -- "$HOME/websbx"
}

prepare_runtime_operation(){
  local action="$1" lock_file="$HOME/.agsbx-operation.lock" directory_mode read_only=no ancestor owner
  case "$HOME" in /*) ;; *) echo "错误：HOME 必须为绝对路径。"; return 1 ;; esac
  case "$HOME" in /|*[!A-Za-z0-9_./-]*) echo "错误：HOME 路径不适合系统服务模板。"; return 1 ;; esac
  [ "$(readlink -f "$HOME")" = "$HOME" ] || { echo "错误：HOME 必须使用规范路径。"; return 1; }
  ancestor="$HOME"
  while :; do
    owner=$(stat -c '%u' "$ancestor") && directory_mode=$(stat -c '%a' "$ancestor") || return 1
    [[ "$directory_mode" =~ ^[0-7]{3,4}$ ]] && [ "$owner" = 0 ] && [ "$((8#$directory_mode & 0022))" = 0 ] \
      || { echo "错误：HOME 及其父目录必须由 root 拥有且不可被其他用户改写；sudo 调用请使用受保护的 root HOME。"; return 1; }
    [ "$ancestor" != / ] || break
    ancestor=${ancestor%/*}; [ -n "$ancestor" ] || ancestor=/
  done
  if [ -e "$HOME/agsbx" ] || [ -L "$HOME/agsbx" ]; then
    [ -d "$HOME/agsbx" ] && [ ! -L "$HOME/agsbx" ] \
      && [ "$(stat -c '%u' "$HOME/agsbx")" = 0 ] || { echo "错误：部署目录类型或属主异常。"; return 1; }
  fi
  if [ -d "$HOME/agsbx" ]; then
    directory_mode=$(stat -c '%a' "$HOME/agsbx") || return 1
    [[ "$directory_mode" =~ ^[0-7]{3,4}$ ]] && [ "$((8#$directory_mode & 0022))" = 0 ] \
      || { echo "错误：部署目录允许其他用户写入，请先核对其内容与权限。"; return 1; }
  fi
  case "$action" in
    list|status|stats|top) read_only=yes ;;
    '') if agsbx_installed && [ "$ipv_request_set" != yes ]; then read_only=yes; fi ;;
  esac
  if [ "$read_only" = yes ] && [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then return 0; fi
  command -v flock >/dev/null 2>&1 || { echo "错误：协调部署需要系统 flock 命令，请先准备该工具。"; return 1; }
  if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] && [ "$(stat -c '%u' "$lock_file")" = 0 ] || return 1
  fi
  if [ "$read_only" = yes ]; then
    exec 8<"$lock_file" || return 1
    flock -sn 8 || { echo "部署正在修改，请稍后查看。"; return 1; }
    return 0
  fi
  exec 8>>"$lock_file" || return 1
  flock -n 8 || { echo "错误：另一个 Airgosbx 修改或证书维护操作正在执行。"; return 1; }
  if [ "$action" = '' ] && ! agsbx_installed; then
    mkdir -pm 700 "$HOME/agsbx" || return 1
  fi
}

subscription_cron_line_is_managed(){
  local line="$1" port binary endpoint expected
  case "$line" in *'# AIRGOSBX_SUBSCRIPTION_HTTP') return 0 ;; @reboot*) ;; *) return 1 ;; esac
  port=$(cat "$HOME/agsbx/subport_real.log" 2>/dev/null)
  if valid_port "$port"; then
    for binary in /bin/busybox /usr/bin/busybox /bin/busybox-extras /usr/bin/busybox-extras; do
      for endpoint in "$port" "127.0.0.1:$port"; do
        expected="@reboot sleep 10 && /bin/bash -c '\"$binary\" httpd -f -p $endpoint -h \"$HOME/websbx\" > /dev/null 2>&1 &'"
        [ "$line" != "$expected" ] || return 0
      done
    done
  fi
  case "$line" in *httpd*websbx*) return 2 ;; *) return 1 ;; esac
}

subscription_cron_has_managed_startup(){
  local line cron_tmp found=no
  cron_tmp=$(mktemp) || return 2
  read_crontab_or_empty "$cron_tmp" || { rm -f "$cron_tmp"; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    if subscription_cron_line_is_managed "$line"; then found=yes; break
    elif [ "$?" = 2 ]; then rm -f "$cron_tmp"; return 2; fi
  done < "$cron_tmp"
  rm -f "$cron_tmp"
  [ "$found" = yes ] && return 0
  return 1
}

filter_managed_subscription_cron(){
  local source="$1" destination="$2" line
  : > "$destination" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if subscription_cron_line_is_managed "$line"; then continue
    elif [ "$?" = 2 ]; then return 1; fi
    printf '%s\n' "$line" >> "$destination" || return 1
  done < "$source"
}

subscription_startup_owned(){
  local path="$1" content port binary endpoint expected
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  content=$(cat "$path") || return 1
  case "$content" in *'# AIRGOSBX_SUBSCRIPTION_HTTP'*) return 0 ;; esac
  expected=$'#!/bin/bash\n# Airgosbx disabled an unsafe legacy subscription startup entry.\nexit 1'
  [ "$content" != "$expected" ] || return 0
  port=$(cat "$HOME/agsbx/subport_real.log" 2>/dev/null)
  valid_port "$port" || return 1
  for binary in /bin/busybox /usr/bin/busybox /bin/busybox-extras /usr/bin/busybox-extras; do
    for endpoint in "$port" "127.0.0.1:$port"; do
      expected=$(printf '#!/bin/bash\nsleep 10\n"%s" httpd -f -p %s -h "%s/websbx" > /dev/null 2>&1 &' "$binary" "$endpoint" "$HOME")
      [ "$content" != "$expected" ] || return 0
    done
  done
  return 1
}

neutralize_subscription_persistent_startup(){
  local cron_tmp filtered_tmp
  if command -v apk >/dev/null 2>&1; then
    subscription_startup_owned /etc/local.d/alpinesubsbx.start || { echo "错误：保留归属不明的 Alpine 订阅启动项。"; return 1; }
    cat > /etc/local.d/alpinesubsbx.start <<'EOF'
#!/bin/bash
# Airgosbx disabled an unsafe legacy subscription startup entry.
exit 1
EOF
    [ $? -eq 0 ] || return 1
    chmod 700 /etc/local.d/alpinesubsbx.start
  else
    cron_tmp=$(mktemp) || return 1
    filtered_tmp=$(mktemp) || { rm -f "$cron_tmp"; return 1; }
    if ! read_crontab_or_empty "$cron_tmp" \
      || ! filter_managed_subscription_cron "$cron_tmp" "$filtered_tmp" \
      || ! crontab "$filtered_tmp" >/dev/null 2>&1; then
      rm -f "$cron_tmp" "$filtered_tmp"
      return 1
    fi
    rm -f "$cron_tmp" "$filtered_tmp"
  fi
}

subscription_http_is_running(){
  local port="${1:-}"
  [ -n "$port" ] || port=$(cat "$HOME/agsbx/subport_real.log" 2>/dev/null)
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  local pid
  for pid in $(subscription_http_managed_pids); do
    tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fxq "127.0.0.1:$port" && return 0
  done
  return 1
}

subscription_http_is_listening(){
  local port="$1" port_hex
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v endpoint="127.0.0.1:$port" '$4 == endpoint {found=1} END {exit !found}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v endpoint="127.0.0.1:$port" '$4 == endpoint {found=1} END {exit !found}'
  else
    printf -v port_hex '%04X' "$port"
    awk -v endpoint="0100007F:$port_hex" '$2 == endpoint && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp 2>/dev/null
  fi
}

subscription_http_responds(){
  local port="$1" status
  exec 9<>"/dev/tcp/127.0.0.1/$port" 2>/dev/null || return 1
  printf 'GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&9
  IFS= read -r -t 2 status <&9 || { exec 9>&-; return 1; }
  exec 9>&-
  case "$status" in HTTP/*) return 0 ;; *) return 1 ;; esac
}

start_subscription_http(){
  local port="$1" binary pid attempt
  valid_port "$port" || { echo "错误：订阅监听端口无效。"; return 1; }
  binary=$(subscription_http_binary) || {
    echo "错误：系统中的 BusyBox 不包含 httpd applet，无法启动订阅服务。"
    return 1
  }
  "$binary" httpd -f -p "127.0.0.1:$port" -h "$HOME/websbx" 8>&- >/dev/null 2>&1 &
  pid=$!
  for attempt in {1..5}; do
    if kill -0 "$pid" >/dev/null 2>&1 \
      && subscription_http_is_running "$port" \
      && subscription_http_is_listening "$port" \
      && subscription_http_responds "$port"; then
      return 0
    fi
    sleep 1
  done
  kill -15 "$pid" >/dev/null 2>&1 || true
  echo "错误：BusyBox 订阅服务未在回环地址 127.0.0.1:$port 正常响应。"
  return 1
}

write_subscription_http_autostart(){
  local port="$1" enable_local="${2:-yes}" binary cron_tmp filtered_tmp
  case "$port" in ''|*[!0-9]*) echo "错误：订阅回源端口无效，拒绝写入启动项。"; return 1 ;; esac
  binary=$(subscription_http_binary) || {
    echo "错误：订阅后端缺少 BusyBox httpd applet，无法写入启动项。"
    return 1
  }
  if command -v apk >/dev/null 2>&1; then
    if [ -e /etc/local.d/alpinesubsbx.start ] || [ -L /etc/local.d/alpinesubsbx.start ]; then
      subscription_startup_owned /etc/local.d/alpinesubsbx.start || return 1
    fi
    cat > /etc/local.d/alpinesubsbx.start <<EOF
#!/bin/bash
# AIRGOSBX_SUBSCRIPTION_HTTP
sleep 10
"$binary" httpd -f -p 127.0.0.1:$port -h "$HOME/websbx" > /dev/null 2>&1 &
EOF
    [ $? -eq 0 ] || return 1
    chmod 700 /etc/local.d/alpinesubsbx.start || return 1
    if [ "$enable_local" = yes ]; then
      rc-update add local default >/dev/null 2>&1 || return 1
    fi
  else
    cron_tmp=$(mktemp) || return 1
    filtered_tmp=$(mktemp) || { rm -f "$cron_tmp"; return 1; }
    if ! read_crontab_or_empty "$cron_tmp" \
      || ! filter_managed_subscription_cron "$cron_tmp" "$filtered_tmp" \
      || ! echo "@reboot sleep 10 && /bin/bash -c '\"$binary\" httpd -f -p 127.0.0.1:$port -h \"$HOME/websbx\" > /dev/null 2>&1 &' # AIRGOSBX_SUBSCRIPTION_HTTP" >> "$filtered_tmp" \
      || ! crontab "$filtered_tmp" >/dev/null 2>&1; then
      rm -f "$cron_tmp" "$filtered_tmp"
      return 1
    fi
    rm -f "$cron_tmp" "$filtered_tmp"
  fi
}

migrate_subscription_persistent_startup(){
  local port query_status
  subscription_persistent_present=no
  if command -v apk >/dev/null 2>&1; then
    [ -e /etc/local.d/alpinesubsbx.start ] || return 0
  else
    command -v crontab >/dev/null 2>&1 || return 0
    if subscription_cron_has_managed_startup; then
      :
    else
      query_status=$?
      [ "$query_status" -eq 1 ] && return 0
      echo "错误：无法确认旧订阅启动项状态，拒绝跳过迁移。"
      return 1
    fi
  fi
  subscription_persistent_present=yes
  neutralize_subscription_persistent_startup || {
    echo "错误：无法禁用旧订阅启动项。"
    return 1
  }
  port=$(cat "$HOME/agsbx/subport_real.log" 2>/dev/null)
  write_subscription_http_autostart "$port" no || {
    echo "错误：无法把旧订阅启动项迁移到 IPv4 回环监听。"
    return 1
  }
}

restart_managed_subscription_http(){
  local port pids pid attempt
  pids=$(subscription_http_managed_pids 2>/dev/null) || pids=""
  if [ -z "$pids" ] && [ "$subscription_persistent_present" != yes ]; then return 0; fi
  port=$(cat "$HOME/agsbx/subport_real.log" 2>/dev/null)
  valid_port "$port" || { echo "错误：订阅端口状态无效，未停止现有进程。"; return 1; }
  if [ -n "$pids" ]; then
    for pid in $pids; do
      kill -15 "$pid" >/dev/null 2>&1 || return 1
    done
    for attempt in {1..5}; do
      subscription_http_managed_is_running || break
      sleep 1
    done
    subscription_http_managed_is_running && {
      echo "错误：旧订阅 HTTP 进程未能停止，拒绝启动新的回环实例。"
      return 1
    }
  elif [ "$subscription_persistent_present" != yes ]; then
    return 0
  fi
  port=$(cat "$HOME/agsbx/subport_real.log" 2>/dev/null)
  start_subscription_http "$port"
}

verify_install_required_components(){
  local include_subscription="${1:-no}" failed=no
  if [ "$install_required_xray" = yes ] && ! { wait_agsbx_component xray && wait_component_listeners xray; }; then
    echo "错误：本轮要求的 Xray 进程未运行。"
    failed=yes
  fi
  if [ "$install_required_singbox" = yes ] && ! { wait_agsbx_component sing-box && wait_component_listeners sing-box; }; then
    echo "错误：本轮要求的 Sing-box 进程未运行。"
    failed=yes
  fi
  if [ "$install_required_caddy" = yes ] && ! { wait_agsbx_component caddy && wait_component_listeners caddy; }; then
    echo "错误：本轮要求的 Caddy 进程未运行。"
    failed=yes
  fi
  if secondary_protocol_is_selected naive && ! port_is_listening "$naive_secondary_port"; then
    echo "错误：Naive 二级链路的 Sing-box 回环转交端口未监听。"
    failed=yes
  fi
  if [ "$install_required_mita" = yes ]; then
    if ! command -v mita >/dev/null 2>&1 || ! mita status 2>/dev/null | grep -q 'RUNNING' \
      || ! mita_port_is_listening "$port_mieru" "$mieru_protocol"; then
      echo "错误：本轮要求的 Mieru/Mita 未处于 RUNNING 状态或未监听预期端口。"
      failed=yes
    fi
    if ! mita_policy_listener_is_ready; then
      echo "错误：Mieru/Mita 未监听 ipv=$effective_ipv_mode 所需的协议族。"
      failed=yes
    fi
  fi
  if [ "$install_required_argo" = yes ] && ! wait_agsbx_component cloudflared; then
    echo "错误：本轮要求的 Cloudflared Argo 进程未运行。"
    failed=yes
  fi
  if [ "$include_subscription" = yes ] && [ "$install_required_subscription" = yes ]; then
    if ! subscription_http_is_running "$subport_real" \
      || ! subscription_http_is_listening "$subport_real" \
      || ! subscription_http_responds "$subport_real"; then
      echo "错误：本轮要求的订阅 HTTP 服务未运行、未监听预期回环端口或未正常响应。"
      failed=yes
    fi
  fi
  [ "$failed" = no ]
}
# 安装态探测：只要内核二进制还在磁盘上就视为"已安装"（rep 只重置配置、stop 只停进程，都不删二进制）。
# 管理类命令(start/stop/restart/reload/list/...)应以"是否已安装"放行，而非"是否正在运行"——
# 否则 stop 停掉最后一个内核后 agsbx_running 变 false，随后的 start 会被前置守卫误判为"未安装"而拦截。
agsbx_installed(){
  [ -s "$HOME/agsbx/sing-box" ] || [ -s "$HOME/agsbx/xray" ] || [ -s "$HOME/agsbx/caddy" ] \
    || { [ -f "$HOME/agsbx/mita_managed" ] && command -v mita >/dev/null 2>&1; }
}

# 终端配色：仅在交互式 TTY 且未设置 NO_COLOR 时启用；输出被重定向到文件/管道时自动留空，
# 避免 ANSI 转义码污染订阅文件（jh.txt / clmi.yaml）。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m');   C_BOLD=$(printf '\033[1m')
  C_RED=$(printf '\033[31m');    C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m'); C_CYAN=$(printf '\033[36m')
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

# 终端排版助手：统一全脚本的分隔线、区块标题与节点卡片标题样式，
# 取代此前手敲长短不一的星号/横线/等号分隔串。仅作用于控制台展示输出，
# 订阅文件 (jh.txt / clmi.yaml) 均为显式重定向写入，不受影响。
hr(){ printf '%s\n' "${C_CYAN}---------------------------------------------------------${C_RESET}"; }
hr2(){ printf '%s\n' "${C_CYAN}=========================================================${C_RESET}"; }
section(){
  hr2
  printf '%s\n' "${C_BOLD}$1${C_RESET}"
  hr2
}
node_title(){ printf '%s\n' "${C_BOLD}${C_CYAN}$1${C_RESET}"; }

# 变量速查表：按功能分组打印所有可用环境变量，解决"功能多→变量多→记不住/易混淆"的痛点。
# vg() 打印分组小标题，vrow() 打印对齐的"变量 — 说明"行（变量名为 ASCII，%-11s 列对齐稳定）。
vg(){ echo; printf '%s\n' "${C_GREEN}${C_BOLD}$1${C_RESET}"; }
vrow(){ printf "  ${C_YELLOW}%-11s${C_RESET} %s\n" "$1" "$2"; }
# XHTTP 扩展字段清单：变量名|Xray 字段|类型和范围|默认值|作用端。
# 与本地 GUI 的 XHTTP_EXTRA_FIELDS 同步。置于帮助入口之前，帮助不执行部署逻辑。
xhttp_extra_schema() {
  cat <<'XHTTP_EXTRA_SCHEMA'
xpadding|xPaddingBytes|range:1:4096|100-1000|both
xpadobfs|xPaddingObfsMode|enum:true,false|true|both
xpadkey|xPaddingKey|token|x_padding|both
xpadheader|xPaddingHeader|token|Referer|both
xpadplacement|xPaddingPlacement|enum:queryInHeader,query,header,cookie|queryInHeader|both
xpadmethod|xPaddingMethod|enum:repeat-x,tokenish|repeat-x|both
xheaders64|headers|headers||client
xnogrpc|noGRPCHeader|enum:true,false|false|client
xnosse|noSSEHeader|enum:true,false|false|server
xupmethod|uplinkHTTPMethod|enum:POST,PUT,PATCH,GET|POST|both
xsessionplacement|sessionPlacement|enum:path,query,header,cookie|path|both
xsessionkey|sessionKey|opt-token||both
xseqplacement|seqPlacement|enum:path,query,header,cookie|path|both
xseqkey|seqKey|opt-token||both
xdataplacement|uplinkDataPlacement|enum:body,auto,header,cookie|body|both
xdatakey|uplinkDataKey|opt-token||both
xchunksize|uplinkChunkSize|range:0:16777216|0|client
xpostbytes|scMaxEachPostBytes|range:1:16777216|1000000|both
xpostinterval|scMinPostsIntervalMs|range:0:60000|30|client
xbufferposts|scMaxBufferedPosts|int:1:4096|30|server
xstreamsecs|scStreamUpServerSecs|range:0:86400|20-80|server
xheaderbytes|serverMaxHeaderBytes|int:0:1048576|8192|server
xmuxcon|xmux.maxConcurrency|range:0:1024|0|client
xmuxmax|xmux.maxConnections|range:0:128|3|client
xmuxreuse|xmux.cMaxReuseTimes|range:0:2147483647|0|client
xmuxrequests|xmux.hMaxRequestTimes|range:0:2147483647|600-900|client
xmuxsecs|xmux.hMaxReusableSecs|range:0:2147483647|1800-3000|client
xmuxkeepalive|xmux.hKeepAlivePeriod|keepalive|0|client
xdownload|downloadSettings|enum:true,false|false|control
xdownaddr|address|address||download
xdownport|port|int:1:65535|443|download
xdownsecurity|security|enum:tls,reality,none|tls|download
xdownsni|serverName|hostname||download
xdownhost|host|host||download
xdownpath|path|path||download
xdownmode|mode|enum:auto,packet-up,stream-up|auto|download
xdownfp|fingerprint|enum:chrome,firefox,safari,edge,random,randomized|chrome|download
xdownpbk|password|pubkey||download
xdownsid|shortId|hex||download
xdowninsecure|allowInsecure|enum:true,false|false|download
xdownfm|finalmask|enum:none,inherit|none|download
XHTTP_EXTRA_SCHEMA
}

showvars(){
printf '%s\n' "${C_CYAN}~~~~~~~~~~~~~~~~~~~~ Airgosbx 变量速查表 ~~~~~~~~~~~~~~~~~~~~${C_RESET}"
printf '%s\n' "${C_BOLD}用法：在脚本前以「变量=值」空格分隔传入，可任意组合${C_RESET}"
echo "示例：xhpt=2087 ipv=\"4;6\" warp=s4x4 sub=y bash <(curl -Ls $agsbxurl)"
echo "取消IP策略并恢复VPS原状态：ipv= agsbx（list/status 等查看命令不改变网络）"
echo "说明：端口类变量留空(如 vlpt)即自动随机分配；带 pt 后缀的为可指定端口版"

vg "① Xray 内核协议（端口留空＝自动分配）"
vrow "xhpt"     "VLESS Encryption＋XHTTP＋REALITY＋Vision（默认无 extra/FM）"
vrow "vlpt"     "VLESS＋TCP/RAW＋REALITY＋Vision（默认无 FM）"
vrow "xhextra"  "仅 xhpt：y 启用内置 XHTTP 扩展参数；n/未设置＝关闭"
vrow "xhfm"     "xhpt 的 FM：sudoku、fragment，逗号多选；none＝关闭"
vrow "vlfm"     "vlpt 的 FM：sudoku、fragment，逗号多选；none＝关闭"
vrow "vxextra"  "vxpt 的 XHTTP extra：y/n（默认 n）"
vrow "vxfm"     "vxpt 的 FM：header-custom、sudoku；套 CDN 时关闭"
vrow "vwfm"     "vwpt 的 FM：header-custom、sudoku；CDN/Argo 时关闭"
vrow "vmfm"     "Xray VMess 的 FM：header-custom、sudoku；Sing-box/CDN/Argo 时关闭"
vrow "xhmode"   "xhpt 客户端模式：auto/packet-up/stream-up/stream-one；含 extra 默认 auto，服务端接受多种模式"
vrow "vxmode"   "vxpt 模式；CDN 默认 packet-up，不开放 stream-one"
echo "             fragment 只进入 TLS/REALITY 客户端，不写入服务端。"
echo "             示例：xhpt=2087 xhextra=y xhfm=sudoku（完整参数随 VLESS URL 导出）"
echo "             rep 按本次选项重建；list 使用已保存的配置，不读取本次增强选项。"
vrow "vxpt"     "Vlessenc-xhttp-vision（裸ENC，配 cdnym 走CDN）"
vrow "vwpt"     "Vlessenc-ws-vision（裸ENC，配 cdnym 走CDN）"
vrow "xhypt"    "Xray-Hysteria2（QUIC，需TLS证书）"
vrow "xhyfm"    "UDP FM：noise，可叠加一个 salamander/sudoku/header-*/mkcp-* 格式掩码"
vrow "xdns"     "Vless-kcp-xdns-fm（备用DNS隧道，需配 xdnsym=域名）"
vrow "xdnsym"   "XDNS 专用域名；该旧模板仍待独立适配，GUI 暂不生成其命令"
vrow "xicmp"    "Vless-kcp-xicmp-fm（特种L3 Ping隧道，独占ICMP）"

vg "② Sing-box 内核协议（端口留空＝自动分配）"
vrow "shypt"    "Hysteria2（QUIC暴力传输，需TLS证书）"
vrow "tupt"     "Tuic v5（QUIC，需TLS证书）"
vrow "anpt"     "AnyTLS（需TLS证书）"
vrow "arpt"     "Any-Reality（AnyTLS over Reality）"
vrow "sspt"     "Shadowsocks-2022（blake3-aes-128-gcm）"

vg "③ 通用协议（落在当前激活的内核上）"
vrow "vmpt"     "Vmess-ws（Xray或Sing-box，可走 Argo/CDN）"
vrow "sopt"     "Socks5（无加密；可作应用代理或二级代理上游）"

vg "④ 出站方式（默认直连；可选 WARP 或二级代理）"
vrow "warp"     "出站经WARP，值选：s/x/sx 或 s4x4/s6x6 等"
echo "             s=sing-box核走WARP  x=xray核走WARP  4/6=锁IPv4/IPv6"
vrow "secp"     "二级代理出站选择器：协议名逗号分隔，或 xr / sb；Naive 显式用 naive"
vrow "securl"   "B节点URL：ss:// / socks5:// / http:// / https://（留空隐藏输入；socks5/http无加密）"
echo "             secp 命中 Sing-box 或 naive 时，B 地址须使用 IPv4 或 [IPv6]；Xray 可使用域名"

vg "⑤ Cloudflare Argo 隧道（纯出站，VPS无需开放端口）"
vrow "argo"     "指定哪个协议走隧道：vmpt / vwpt / xvargopt"
vrow "xvargopt" "VLESS Encryption＋XHTTP＋Vision（回环 HTTP，packet-up；自动绑定 Argo）"
vrow "xvargoextra" "Argo XHTTP extra：y/n；始终关闭 SSE 响应头"
vrow "xvargofm" "Argo 客户端 FM：none/fragment；禁止私有包头、sudoku"
vrow "agn"      "固定隧道域名（留空＝临时trycloudflare隧道）"
vrow "agk"      "固定隧道 Token（与 agn 配对使用）"

vg "⑥ Cloudflare CDN 回源 / 优选"
vrow "xvcdnpt"  "VLESS Encryption＋XHTTP＋TLS＋Vision CDN（默认 2087，必须配 cdnym）"
vrow "xvcdnextra" "CDN XHTTP extra：y/n（默认 n）"
vrow "xvcdnmode" "CDN 模式：packet-up（默认）或 stream-up（需 CDN 支持流式上传）"
vrow "xvcdnfm"  "CDN 客户端 FM：none/fragment；禁止私有包头、sudoku"
vrow "cdnym"    "CDN host域名/优选IP域名（须已解析到CF）"

vg "⑦ TLS 证书（无订阅时可自动自签；开启订阅必须使用公信 CA）"
vrow "alns"     "acme.sh 证书开关：y＝需要证书时交互选择申请方式"
vrow "acmemode" "预设方式：ip / http / alpn / dns（留空则交互选择）"
vrow "certip"   "IP 短期证书的一个或两个公网 IP（空格分隔）"
vrow "certym"   "域名；兼容旧用法：单独设置时默认 HTTP-01"
vrow "certwild" "DNS-01 时填 y，同时申请根域名与泛域名"
vrow "certcrt"  "外部导入：证书(fullchain)文件路径"
vrow "certkey"  "外部导入：私钥文件路径"
vrow "acmem"    "ACME 注册邮箱（ZeroSSL 备用签发需要）"
vrow "acmetimeout" "单家 CA 签发超时秒数（默认 HTTP/IP/ALPN 60、DNS 120；范围 5-600）"
vrow "sslcom_eab_kid" "SSL.com 第三备用 CA 的 EAB Key ID（可选）"
vrow "sslcom_eab_hmac" "SSL.com 第三备用 CA 的 EAB HMAC Key（可选）"
vrow "certdns"  "兼容旧用法：填 cf 走 Cloudflare DNS-01（免占用80/443端口）"
vrow "CF_Token" "Cloudflare Token（Zone.DNS 编辑；自动发现时还需 Zone.Zone 读取）"
vrow "CF_Account_ID" "Cloudflare 账户 ID（可选，用于缩小 Zone 查询范围）"
vrow "CF_Zone_ID" "Cloudflare Zone ID（可选，已知时可直接指定）"

vg "⑧ Web 订阅分发（Clash/聚合，强制TLS加密）"
vrow "sub"      "订阅分发开关（sub=y 启用；亦可只设 subpt/subid）；必须复用公信 CA 或通过 ACME 申请"
vrow "subpt"    "订阅服务对外端口（留空自动分配）"
vrow "subid"    "独立订阅 token（16-128 位安全字符；留空自动生成并保存）"

vg "⑨ Hysteria2 端口跳跃（抗QoS限速）"
vrow "hyjpt"    "全局跳跃端口，自动分配给激活的hy2核"
vrow "shyjpt"   "专属：Sing-box Hysteria2 跳跃端口"
vrow "xhyjpt"   "专属：Xray Hysteria2 跳跃端口"

vg "⑩ 通用 / 全局选项"
vrow "uuid"     "协议 UUID/密码（留空自动生成；SOCKS 与订阅使用独立凭据）"
vrow "name"     "所有节点名称前缀"
vrow "reym"     "自定义 Reality 伪装域名（留空＝按地区智能选）"
vrow "obfs_pass" "Hysteria2 混淆密码（留空＝自动生成）"
vrow "ipv"      "系统IP栈：4／6／\"4;6\"／\"6;4\"；未设置＝保持，显式空值＝恢复原状态"
vrow "ippz"     "list时只显示指定栈：4 或 6（双栈VPS用）"

vg "⑪ NaiveProxy（Caddy 内核·独立于 xray/sb，需真实域名）"
vrow "naive"     "y＝交互输入域名；域名＝直接启用（须已解析到本机）"
vrow "naiveuser" "basic_auth 用户名（留空＝自动生成）"
vrow "naivepass" "basic_auth 密码（留空＝自动生成）"
vrow "naivebuild" "内核获取：dl=下载预编译(仅amd64)／build=现场编译(arm64必走)"
vrow "naivesite" "reverse_proxy 伪装站域名（留空＝默认公共镜像）"

vg "⑫ Mieru（Mita 官方服务端·独立于 xray/sb）"
vrow "mieru"      "y＝启用交互配置（推荐，只需记这个变量）"
vrow "mierupt"    "可选预设：端口（留空＝随机高位端口）"
vrow "mieruuser"  "可选预设：用户名（留空＝自动生成）"
vrow "mierupass"  "可选预设：密码（留空＝自动生成）"
vrow "mierutrans" "可选预设：tcp（默认）或 udp"

vg "⑬ Xray 扩展参数（仅作用于本次启用的对应扩展）"
vrow "xpadding" "XHTTP 填充范围：1-4096 字节，默认 100-1000"
vrow "xmuxcon"  "XMUX 并发数：0-1024，默认 0；不能与 xmuxmax 同时为正"
vrow "xmuxmax"  "XMUX 连接数：0-128，默认 3"
vrow "fmpass"   "FM 共用密钥（可选；留空按协议生成独立密钥）"
vrow "fmascii"  "Sudoku 外观：prefer_entropy（默认）/prefer_ascii"
vrow "fmpadding" "Sudoku 额外填充率：0-100，默认 0-0；不是字节数"
vrow "fmheader" "header-custom 的配套十六进制前缀，1-128 字节；留空随机"
vrow "fmdomain" "header-dns 的外观域名；仅选择该掩码时必填"
vrow "fmnoise"  "UDP 噪声长度：1-1200 字节，默认 32-128"
vrow "fmreset"  "UDP 噪声重置：0-3600 秒，默认 30-60"
vrow "fmdelay"  "UDP 噪声延迟：0-1000 毫秒，默认 0"
vrow "fmfraglen" "TLS 客户端分片长度：1-16384，默认 100-200"
vrow "fmfragdelay" "TLS 分片延迟：0-1000 毫秒，默认 0"
vrow "fmfragsplit" "TLS 分片数量：1-64，默认 3-6"
vrow "xhycc"    "Xray Hysteria2 QUIC：auto/bbr/reno/brutal/force-brutal"
vrow "xhyup"    "客户端上行 Mbps：0-100000；force-brutal 需明确正值"
vrow "xhydown"  "客户端下行 Mbps：0-100000；force-brutal 需明确正值"
echo "             FM 多项必须使用匹配的 Xray 客户端实现；完整参数随 URL 导出。"

vg "⑭ Xray 按协议覆盖（未设置或空值＝沿用上方通用参数）"
echo "             GUI 为每个协议独立传参；范围与同名通用参数一致。"
vrow "vl_fmpass" "vlpt 专用 fmpass，仅作用于该协议"
vrow "vl_fmascii" "vlpt 专用 fmascii，仅作用于该协议"
vrow "vl_fmpadding" "vlpt 专用 fmpadding，仅作用于该协议"
vrow "vl_fmfraglen" "vlpt 专用 fmfraglen，仅作用于该协议"
vrow "vl_fmfragdelay" "vlpt 专用 fmfragdelay，仅作用于该协议"
vrow "vl_fmfragsplit" "vlpt 专用 fmfragsplit，仅作用于该协议"
vrow "xh_xpadding" "xhpt 专用 xpadding，仅作用于该协议"
vrow "xh_xmuxcon" "xhpt 专用 xmuxcon，仅作用于该协议"
vrow "xh_xmuxmax" "xhpt 专用 xmuxmax，仅作用于该协议"
vrow "xh_fmpass" "xhpt 专用 fmpass，仅作用于该协议"
vrow "xh_fmascii" "xhpt 专用 fmascii，仅作用于该协议"
vrow "xh_fmpadding" "xhpt 专用 fmpadding，仅作用于该协议"
vrow "xh_fmfraglen" "xhpt 专用 fmfraglen，仅作用于该协议"
vrow "xh_fmfragdelay" "xhpt 专用 fmfragdelay，仅作用于该协议"
vrow "xh_fmfragsplit" "xhpt 专用 fmfragsplit，仅作用于该协议"
vrow "vx_xpadding" "vxpt 专用 xpadding，仅作用于该协议"
vrow "vx_xmuxcon" "vxpt 专用 xmuxcon，仅作用于该协议"
vrow "vx_xmuxmax" "vxpt 专用 xmuxmax，仅作用于该协议"
vrow "vx_fmpass" "vxpt 专用 fmpass，仅作用于该协议"
vrow "vx_fmascii" "vxpt 专用 fmascii，仅作用于该协议"
vrow "vx_fmpadding" "vxpt 专用 fmpadding，仅作用于该协议"
vrow "vx_fmheader" "vxpt 专用 fmheader，仅作用于该协议"
vrow "vw_fmpass" "vwpt 专用 fmpass，仅作用于该协议"
vrow "vw_fmascii" "vwpt 专用 fmascii，仅作用于该协议"
vrow "vw_fmpadding" "vwpt 专用 fmpadding，仅作用于该协议"
vrow "vw_fmheader" "vwpt 专用 fmheader，仅作用于该协议"
vrow "vm_fmpass" "vmpt 专用 fmpass，仅作用于该协议"
vrow "vm_fmascii" "vmpt 专用 fmascii，仅作用于该协议"
vrow "vm_fmpadding" "vmpt 专用 fmpadding，仅作用于该协议"
vrow "vm_fmheader" "vmpt 专用 fmheader，仅作用于该协议"
vrow "hy_fmpass" "xhypt 专用 fmpass，仅作用于该协议"
vrow "hy_fmascii" "xhypt 专用 fmascii，仅作用于该协议"
vrow "hy_fmpadding" "xhypt 专用 fmpadding，仅作用于该协议"
vrow "hy_fmheader" "xhypt 专用 fmheader，仅作用于该协议"
vrow "hy_fmdomain" "xhypt 专用 fmdomain，仅作用于该协议"
vrow "hy_fmnoise" "xhypt 专用 fmnoise，仅作用于该协议"
vrow "hy_fmreset" "xhypt 专用 fmreset，仅作用于该协议"
vrow "hy_fmdelay" "xhypt 专用 fmdelay，仅作用于该协议"
vrow "xvd_xpadding" "xvcdnpt 专用 xpadding，仅作用于该协议"
vrow "xvd_xmuxcon" "xvcdnpt 专用 xmuxcon，仅作用于该协议"
vrow "xvd_xmuxmax" "xvcdnpt 专用 xmuxmax，仅作用于该协议"
vrow "xvd_fmfraglen" "xvcdnpt 专用 fmfraglen，仅作用于该协议"
vrow "xvd_fmfragdelay" "xvcdnpt 专用 fmfragdelay，仅作用于该协议"
vrow "xvd_fmfragsplit" "xvcdnpt 专用 fmfragsplit，仅作用于该协议"
vrow "xva_xpadding" "xvargopt 专用 xpadding，仅作用于该协议"
vrow "xva_xmuxcon" "xvargopt 专用 xmuxcon，仅作用于该协议"
vrow "xva_xmuxmax" "xvargopt 专用 xmuxmax，仅作用于该协议"
vrow "xva_fmfraglen" "xvargopt 专用 fmfraglen，仅作用于该协议"
vrow "xva_fmfragdelay" "xvargopt 专用 fmfragdelay，仅作用于该协议"
vrow "xva_fmfragsplit" "xvargopt 专用 fmfragsplit，仅作用于该协议"

vg "⑮ 完整 XHTTP Extra（空值继承默认；GUI 仅传入偏离默认的值）"
vrow "cfgver" "默认配置版本标记，与脚本/GUI 版本配套，避免历史命令静默套用新默认"
echo "             通用变量可加 xh_ / vx_ / xvd_ / xva_ 前缀，分别覆盖直连/CDN/Tunnel。"
local extra_key extra_name extra_type extra_default extra_side
while IFS='|' read -r extra_key extra_name extra_type extra_default extra_side; do
  vrow "$extra_key" "$extra_name；默认 ${extra_default:-空}；$extra_type；$extra_side"
done < <(xhttp_extra_schema)
echo "             xheaders64：最多 24 行请求头的 Base64；GUI 接受逐行文本，自动编码。"
echo "             SessionPlacement/Key 兼容输出 sessionIDPlacement/Key；新主分支 Table/Length 暂不生成。"
echo
hr
echo "命令速查见 ${C_YELLOW}agsbx cmds${C_RESET} ｜ 完整帮助 ${C_YELLOW}agsbx help${C_RESET}"
hr
echo
}

# 命令速查表：与 vars 同款排版（vg 分组小标题 + vrow 对齐行），把所有子命令按用途分组列清。
# 与 showvars 配套：agsbx cmds 看命令、agsbx vars 看变量、agsbx help 同时输出两表。
showcmds(){
printf '%s\n' "${C_CYAN}~~~~~~~~~~~~~~~~~~~~ Airgosbx 命令速查表 ~~~~~~~~~~~~~~~~~~~~${C_RESET}"
printf '%s\n' "${C_BOLD}用法：agsbx <命令> [参数]　（已安装后任意目录可直接调用 agsbx）${C_RESET}"

vg "① 脚本管理"
vrow "update"   "更新脚本自身到最新版（不动配置与内核）"
vrow "rep"      "事务重置非Caddy协议；保留Naive/Caddy，开启订阅时可复用或申请CA证书"
vrow "del"      "卸载 agsbx（清进程/服务/定时任务/文件）"

vg "② 查看 / 信息"
vrow "list"     "只读展示节点与已发布订阅（ippz=4或6 可只看单栈）"
vrow "status"   "内核资源 + 流量监控（别名 stats / top）"
vrow "vars"     "变量速查表"
vrow "cmds"     "命令速查表（本表）"
vrow "help"     "完整帮助（vars + cmds）"

vg "③ 内核启停（用法：agsbx <动作> [内核]）"
echo "             内核 = xray ｜ sb ｜ caddy ｜ mita ｜ all(省略即全部；已配置 Naive 时包含 Caddy，Mita 需单独指定)"
vrow "start"    "启动内核"
vrow "stop"     "停止内核（释放其占用的端口）"
vrow "restart"  "重启内核"
vrow "reload"   "热重载配置（sb/caddy/mita 支持；xray 自动 restart）"
vrow "res"      "重启 Xray/Sing-box/Argo，并在已配置 Naive 时重启 Caddy（不含 Mita）"

vg "④ 内核版本"
vrow "upx"      "升级 Xray（upx [版本]，不带版本=最新）"
vrow "ups"      "升级 Sing-box（ups [版本]）"
vrow "downx"    "降级 Xray（downx <版本>，如 downx v26.2.6）"
vrow "downs"    "降级 Sing-box（downs <版本>）"
echo
hr
echo
}

# 早退分发：vars/help 为纯文本速查，无需 root、无需联网安装，提前响应避免空跑整套启动流程
case "$1" in
  vars)               showvars; exit 0 ;;
  cmds)               showcmds; exit 0 ;;
  help|--help|-h)     showvars; showcmds; exit 0 ;;
esac

if ! is_root; then
  echo "安全保护：部署 airgosbx 脚本需要 root 系统权限以注册系统服务（systemd/openrc）或执行依赖项更新！请使用 sudo 或以 root 身份运行本脚本。"
  exit 1
fi

safe_base64() {
  tr -d '\r\n' | base64 | tr -d '\r\n'
}

# 仅检测已有工具能力，不安装依赖；能力结果可缓存，进程状态不缓存。
agsbx_find_printf=no
find --version >/dev/null 2>&1 && agsbx_find_printf=yes

# URI 组件编码：只保留 RFC 3986 unreserved 字符，其余按 UTF-8 字节转为大写 %HH。
uri_percent_encode() {
  local input="$1" output="" char hex i
  local LC_ALL=C
  for ((i=0; i<${#input}; i++)); do
    char=${input:i:1}
    case "$char" in
      [A-Za-z0-9._~-]) output+="$char" ;;
      *) printf -v hex '%02X' "'$char"; output+="%$hex" ;;
    esac
  done
  printf '%s' "$output"
}

# URI 组件解码：严格要求每个百分号后跟两个十六进制字符；加号保持字面含义，不按表单空格处理。
uri_percent_decode() {
  local input="$1" output="" char hex i=0
  local LC_ALL=C
  while [ "$i" -lt "${#input}" ]; do
    char=${input:i:1}
    if [ "$char" = '%' ]; then
      [ $((i + 2)) -lt "${#input}" ] || return 1
      hex=${input:i+1:2}
      case "$hex" in *[!0-9A-Fa-f]*) return 1 ;; esac
      case "$hex" in [01][0-9A-Fa-f]|7[Ff]) return 1 ;; esac
      printf -v char '%b' "\\x$hex"
      output+="$char"
      i=$((i + 3))
    else
      output+="$char"
      i=$((i + 1))
    fi
  done
  printf '%s' "$output"
}

# 同时兼容标准 Base64 与 Base64URL，并自动补齐省略的 padding；仅用于解析旧式 SS 链接。
base64_decode_compat() {
  local input="$1" remainder
  input=${input//-/+}
  input=${input//_/\/}
  remainder=$((${#input} % 4))
  case "$remainder" in
    0) ;;
    2) input="${input}==" ;;
    3) input="${input}=" ;;
    *) return 1 ;;
  esac
  # 必须在命令替换前检查；否则 Bash 会静默剥离解码结果末尾的换行符。
  if printf '%s' "$input" | base64 -d 2>/dev/null | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
  printf '%s' "$input" | base64 -d 2>/dev/null
}

# 所有 URL 解码字段进入 heredoc 前统一做 JSON 字符串转义。
json_escape() {
  local input="$1"
  input=${input//\\/\\\\}
  input=${input//\"/\\\"}
  input=${input//$'\n'/\\n}; input=${input//$'\r'/\\r}; input=${input//$'\t'/\\t}
  printf '%s' "$input"
}

# Xray 扩展按传输与接入路径校验；fragment 仅生成到 TLS/REALITY 客户端。
# 只使用固定变量名、枚举和结构化渲染，不接收 eval/source 或未校验的原始 JSON。
xray_range_valid() {
  local value="$1" minimum="$2" maximum="$3" first last
  [[ "$value" =~ ^[0-9]{1,10}(-[0-9]{1,10})?$ ]] || return 1
  first=${value%%-*}; last=${value##*-}
  first=$((10#$first)); last=$((10#$last))
  [ "$first" -ge "$minimum" ] && [ "$last" -le "$maximum" ] && [ "$first" -le "$last" ]
}

xray_mask_selected() {
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

xray_normalize_masks() {
  local value="${1:-none}" transport="$2" token normalized='' format_count=0
  local -a tokens
  [ "$value" != none ] || { printf 'none'; return 0; }
  case "$value" in ''|,*|*,|*,,*|*[!a-z0-9,-]*) return 1 ;; esac
  IFS=',' read -r -a tokens <<< "$value"
  for token in "${tokens[@]}"; do
    case "$transport:$token" in
      tcp:sudoku|tcp:header-custom|tcp:fragment) ;;
      udp:noise|udp:salamander|udp:sudoku|udp:header-custom|udp:header-dns|udp:header-dtls|udp:header-srtp|udp:header-utp|udp:header-wechat|udp:header-wireguard|udp:mkcp-original|udp:mkcp-aes128gcm) ;;
      *) return 1 ;;
    esac
    xray_mask_selected "$normalized" "$token" && continue
    if [ "$transport" = udp ] && [ "$token" != noise ]; then format_count=$((format_count + 1)); fi
    normalized="${normalized:+$normalized,}$token"
  done
  # UDP 只开放一个格式转换掩码，可叠加 noise；专用 XDNS/XICMP 不混入通用 QUIC 链路。
  [ "$format_count" -le 1 ] || return 1
  # 固定序列，不依赖勾选顺序。两端必须使用兼容的核心；不能跨版本假定包裹顺序不变。
  value=''
  for token in noise header-custom header-dns header-dtls header-srtp header-utp header-wechat header-wireguard mkcp-original mkcp-aes128gcm salamander sudoku fragment; do
    xray_mask_selected "$normalized" "$token" && value="${value:+$value,}$token"
  done
  printf '%s' "$value"
}

# 协议覆盖参数白名单，与 HTML 的 XRAY_PROFILES 同步。未设置时沿用通用参数。
# 仅固定名称可间接取值；不读取任意前缀、不解析命令，也不执行用户输入。

# 覆盖顺序：协议专用值、通用值、脚本默认。变量名仅来自固定 schema。
xhttp_extra_value() {
  local profile="$1" key="$2" fallback="$3" scoped="${1}_${2}" resolved_extra_value
  [ "$profile:$key" != xva:xnosse ] || fallback=true
  if [ -n "${!scoped}" ]; then resolved_extra_value=${!scoped}
  elif [ -n "${!key}" ]; then resolved_extra_value=${!key}
  else resolved_extra_value=$fallback; fi
  # 热循环直接赋给调用者的局部变量，避免为每个字段创建命令替换子进程。
  if [ "$#" = 4 ]; then printf -v "$4" '%s' "$resolved_extra_value"
  else printf '%s' "$resolved_extra_value"; fi
}

# 请求头以 Base64 传入，逐行验证后转义为 JSON，不接收原始 JSON。
xhttp_headers_json() {
  local encoded="$1" decoded canonical line name value lower seen='|' output='' count=0
  [ -n "$encoded" ] || { printf '{}'; return 0; }
  [ "${#encoded}" -le 8192 ] && [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
  decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null) || return 1
  canonical=$(printf '%s' "$decoded" | base64 | tr -d '\r\n') || return 1
  [ "$canonical" = "$encoded" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *:* ]] || return 1
    name=${line%%:*}; value=${line#*:}
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && [ "${#name}" -le 128 ] || return 1
    while [[ "$value" == ' '* ]]; do value=${value# }; done
    [ "${#value}" -le 2048 ] && ! printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]' || return 1
    lower=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
    case "$lower" in host|content-length|transfer-encoding|connection) return 1 ;; esac
    case "$seen" in *"|$lower|"*) return 1 ;; esac
    seen="$seen$lower|"; count=$((count + 1)); [ "$count" -le 24 ] || return 1
    output="${output:+$output,}\"$(json_escape "$name")\":\"$(json_escape "$value")\""
  done <<< "$decoded"
  printf '{%s}' "$output"
}

xhttp_validate_extra() {
  local profile="$1" mode="$2" key field kind fallback side value minimum maximum choice
  local LC_ALL=C
  local download method placement security mask_key masks
  download=$(xhttp_extra_value "$profile" xdownload false)
  while IFS='|' read -r key field kind fallback side; do
    xhttp_extra_value "$profile" "$key" "$fallback" value
    [ "${#value}" -le 8192 ] && [[ ! "$value" =~ [[:cntrl:]] ]] \
      || { echo "错误：${profile}_${key} 太长或含有控制字符。"; return 1; }
    case "$kind" in
      range:*|int:*)
        IFS=: read -r choice minimum maximum <<< "$kind"
        [ "$choice" != int ] || [[ "$value" =~ ^[0-9]{1,10}$ ]] || { echo "错误：${profile}_${key} 应为整数。"; return 1; }
        xray_range_valid "$value" "$minimum" "$maximum" || { echo "错误：${profile}_${key} 的范围无效。"; return 1; } ;;
      keepalive) [ "$value" = -1 ] || xray_range_valid "$value" 0 86400 && [[ "$value" != *-* || "$value" = -1 ]] || { echo "错误：HTTP 保活间隔仅支持 -1 或 0-86400 的整数。"; return 1; } ;;
      enum:*) case ",${kind#enum:}," in *",$value,"*) ;; *) echo "错误：${profile}_${key} 不在允许的枚举中。"; return 1 ;; esac ;;
      headers) xhttp_headers_json "$value" >/dev/null || { echo "错误：${profile}_${key} 不是有效的 Base64 请求头列表。"; return 1; } ;;
      token|opt-token)
        { [ "$kind" = opt-token ] && [ -z "$value" ]; } || [[ "$value" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] \
          || { echo "错误：${profile}_${key} 只允许 1-128 位字母、数字、点、短横线和下划线。"; return 1; } ;;
      address|hostname|host)
        [ -z "$value" ] || { [ "${#value}" -le 1024 ] && [[ "$value" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._:-]+)$ ]]; } \
          || { echo "错误：${profile}_${key} 需填写地址，不含 URL 协议头或路径。"; return 1; } ;;
      path) [ -z "$value" ] || { [ "${#value}" -le 1024 ] && [[ "$value" == /* ]]; } || { echo "错误：下载路径应以 / 开头。"; return 1; } ;;
      pubkey) [ -z "$value" ] || [[ "$value" =~ ^[A-Za-z0-9_-]{43}$ ]] || { echo "错误：下载 REALITY 公钥格式无效。"; return 1; } ;;
      hex) [[ "$value" =~ ^([0-9A-Fa-f]{2}){0,8}$ ]] || { echo "错误：下载 Short ID 必须为不超过 16 位的偶数位十六进制。"; return 1; } ;;
      *) return 1 ;;
    esac
  done < <(xhttp_extra_schema)
  method=$(xhttp_extra_value "$profile" xupmethod POST)
  placement=$(xhttp_extra_value "$profile" xdataplacement body)
  if { [ "$method" = GET ] || [ "$placement" = header ] || [ "$placement" = cookie ]; } && [ "$mode" != packet-up ]; then
    echo "错误：$profile 的 GET/header/cookie 上传必须显式选择 packet-up。"; return 1
  fi
  if [ "$method" = GET ] && [ "$placement" != header ] && [ "$placement" != cookie ]; then
    echo "错误：GET 上传需要将数据放入 header 或 cookie。"; return 1
  fi
  if [ "$profile" = xva ] && [ "$(xhttp_extra_value "$profile" xnosse true)" != true ]; then
    echo "错误：Tunnel 的 noSSEHeader 必须保持 true。"; return 1
  fi
  if [ "$download" = true ]; then
    [ "$mode" != stream-one ] || { echo "错误：stream-one 不能使用独立 downloadSettings。"; return 1; }
    [ -n "$(xhttp_extra_value "$profile" xdownaddr '')" ] || { echo "错误：独立下载需要目标地址。"; return 1; }
    security=$(xhttp_extra_value "$profile" xdownsecurity tls)
    if [ "$security" = reality ]; then
      [ -n "$(xhttp_extra_value "$profile" xdownpbk '')" ] && [ -n "$(xhttp_extra_value "$profile" xdownsni '')" ] \
        || { echo "错误：REALITY 下载需要 SNI 与公钥。"; return 1; }
    fi
    if [ "$method" = GET ] || [ "$placement" = header ] || [ "$placement" = cookie ]; then
      [ "$(xhttp_extra_value "$profile" xdownmode auto)" = packet-up ] \
        || { echo "错误：下载侧继承了 GET/header/cookie 设置，其模式也应设为 packet-up。"; return 1; }
    fi
    if [ "$(xhttp_extra_value "$profile" xdownfm none)" = inherit ]; then
      case "$profile" in xh) mask_key=xhfm ;; vx) mask_key=vxfm ;; xvd) mask_key=xvcdnfm ;; xva) mask_key=xvargofm ;; esac
      masks=${!mask_key}
      if [ "$security" = none ] && xray_mask_selected "$masks" fragment; then echo "错误：无 TLS 的下载侧不能继承 tlshello 分片。"; return 1; fi
      if [ "$security" = reality ] && xray_mask_selected "$masks" header-custom; then echo "错误：REALITY 下载侧不开放 header-custom。"; return 1; fi
    fi
  fi
}

xray_profile_keys() {
  case "$1" in xh|vx|xvd|xva) printf '%s ' 'xpadobfs xpadkey xpadheader xpadplacement xpadmethod xheaders64 xnogrpc xnosse xupmethod xsessionplacement xsessionkey xseqplacement xseqkey xdataplacement xdatakey xchunksize xpostbytes xpostinterval xbufferposts xstreamsecs xheaderbytes xmuxreuse xmuxrequests xmuxsecs xmuxkeepalive xdownload xdownaddr xdownport xdownsecurity xdownsni xdownhost xdownpath xdownmode xdownfp xdownpbk xdownsid xdowninsecure xdownfm' ;; esac
  case "$1" in
    vl) printf '%s' 'fmpass fmascii fmpadding fmfraglen fmfragdelay fmfragsplit' ;;
    xh) printf '%s' 'xpadding xmuxcon xmuxmax fmpass fmascii fmpadding fmfraglen fmfragdelay fmfragsplit' ;;
    vx) printf '%s' 'xpadding xmuxcon xmuxmax fmpass fmascii fmpadding fmheader' ;;
    vw|vm) printf '%s' 'fmpass fmascii fmpadding fmheader' ;;
    hy) printf '%s' 'fmpass fmascii fmpadding fmheader fmdomain fmnoise fmreset fmdelay' ;;
    xvd|xva) printf '%s' 'xpadding xmuxcon xmuxmax fmfraglen fmfragdelay fmfragsplit' ;;
    *) return 1 ;;
  esac
}

xray_apply_profile_tuning() {
  local profile="$1" keys key scoped
  keys=$(xray_profile_keys "$profile") || return 1
  for key in $keys; do
    case "$key" in xpadding|xmuxcon|xmuxmax|fm*) ;; *) continue ;; esac
    scoped="${profile}_${key}"
    [ -n "${!scoped}" ] || continue
    printf -v "$key" '%s' "${!scoped}"
  done
}

xray_validate_tuning() {
  local context="$1"
  xray_range_valid "$xpadding" 1 4096 && xray_range_valid "$xmuxcon" 0 1024 && xray_range_valid "$xmuxmax" 0 128 \
    && xray_range_valid "$fmpadding" 0 100 && xray_range_valid "$fmnoise" 1 1200 \
    && xray_range_valid "$fmreset" 0 3600 && xray_range_valid "$fmdelay" 0 1000 \
    && xray_range_valid "$fmfraglen" 1 16384 && xray_range_valid "$fmfragdelay" 0 1000 && xray_range_valid "$fmfragsplit" 1 64 \
    || { echo "错误：$context 的 XHTTP/FM 范围参数无效，请查看 agsbx vars。"; return 1; }
  [ "$((10#${xmuxcon##*-}))" = 0 ] || [ "$((10#${xmuxmax##*-}))" = 0 ] || { echo "错误：$context 的 xmuxcon 与 xmuxmax 不能同时为正值。"; return 1; }
  case "$fmascii" in prefer_entropy|prefer_ascii) ;; *) echo "错误：$context 的 fmascii 仅支持 prefer_entropy/prefer_ascii。"; return 1 ;; esac
  if [ -n "$fmheader" ] && ! [[ "$fmheader" =~ ^([0-9A-Fa-f]{2}){1,128}$ ]]; then echo "错误：$context 的 fmheader 应为 1 至 128 字节的十六进制字符串。"; return 1; fi
  if ! valid_plain_text "$fmpass" 256; then echo "错误：$context 的 fmpass 过长或包含控制字符。"; return 1; fi
  if [ "$context" = hy ] && xray_mask_selected "$xhyfm" header-dns \
    && ! [[ "$fmdomain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$ ]]; then
    echo "错误：header-dns 需要有效的 hy_fmdomain 或通用 fmdomain。"; return 1
  fi
}

xray_validate_profile_tuning() {
  # Bash 动态作用域：覆盖只写入本函数的局部变量，不污染其他协议。
  local xpadding="$xpadding" xmuxcon="$xmuxcon" xmuxmax="$xmuxmax"
  local fmpass="$fmpass" fmascii="$fmascii" fmpadding="$fmpadding" fmheader="$fmheader" fmdomain="$fmdomain"
  local fmnoise="$fmnoise" fmreset="$fmreset" fmdelay="$fmdelay"
  local fmfraglen="$fmfraglen" fmfragdelay="$fmfragdelay" fmfragsplit="$fmfragsplit"
  xray_apply_profile_tuning "$1" && xray_validate_tuning "$1"
}

validate_xray_options() {
  local option flag transport normalized spec mode allowed has_xray=no has_singbox=no
  if [ -n "$cfgver" ] && [ "$cfgver" != "$XHTTP_DEFAULTS_VERSION" ] && [ "$cfgver" != V26.09.07 ]; then
    echo "错误：命令的默认配置版本为 $cfgver，当前预设为 $XHTTP_DEFAULTS_VERSION；请使用配套版本。"; return 1
  fi
  for spec in xhextra:xhp vxextra:vxp xvcdnextra:xvcdn xvargoextra:xvargo; do
    option=${spec%:*}; flag=${spec#*:}
    case "${!option:-n}" in
      y|yes|1) printf -v "$option" '%s' yes ;;
      n|no|0) printf -v "$option" '%s' no ;;
      *) echo "错误：$option 仅支持 y/yes/1 或 n/no/0。"; return 1 ;;
    esac
    if [ "${!option}" = yes ] && [ "${!flag}" != yes ]; then echo "错误：$option 必须同时启用对应的协议端口变量。"; return 1; fi
  done
  for spec in xhfm:xhp:tcp vlfm:vlp:tcp vxfm:vxp:tcp vwfm:vwp:tcp vmfm:vmp:tcp xhyfm:xhyp:udp xvcdnfm:xvcdn:tcp xvargofm:xvargo:tcp; do
    IFS=: read -r option flag transport <<< "$spec"
    normalized=$(xray_normalize_masks "${!option:-none}" "$transport") || {
      echo "错误：$option 的掩码类型或组合不受支持。TCP 支持 header-custom/sudoku/fragment；UDP 允许一个格式掩码加 noise。"
      return 1
    }
    printf -v "$option" '%s' "$normalized"
    if [ "$normalized" != none ] && [ "${!flag}" != yes ]; then echo "错误：$option 必须同时启用对应协议。"; return 1; fi
  done
  for option in xvcdnfm xvargofm; do
    case "${!option}" in none|fragment) ;; *) echo "错误：$option 只允许客户端 TLS 分片，Cloudflare 不解码私有 FM。"; return 1 ;; esac
  done
  for option in vxfm vwfm vmfm; do
    if xray_mask_selected "${!option}" fragment; then echo "错误：$option 的直连入口没有外层 TLS，不能使用 tlshello 分片。"; return 1; fi
  done
  for option in xhfm vlfm; do
    if xray_mask_selected "${!option}" header-custom; then echo "错误：REALITY 入站的 header-custom 连接接口兼容性未确认，当前仅开放 sudoku 与客户端 fragment。"; return 1; fi
  done
  if [ -n "$cdnym" ] && { [ "$vxfm" != none ] || [ "$vwfm" != none ] || [ "$vmfm" != none ]; }; then
    echo "错误：cdnym 会为 vxpt/vwpt/vmpt 生成 CDN 节点，这些共享入站不能同时启用私有 TCP FM。"; return 1
  fi
  case "$argo" in
    '') [ "$xvargo" != yes ] || argo=xvargopt ;;
    vmpt) [ "$vmp" = yes ] && [ "$vmfm" = none ] || { echo "错误：argo=vmpt 需要 vmpt，且不能启用 vmfm。"; return 1; } ;;
    vwpt) [ "$vwp" = yes ] && [ "$vwfm" = none ] || { echo "错误：argo=vwpt 需要 vwpt，且不能启用 vwfm。"; return 1; } ;;
    xvargopt) [ "$xvargo" = yes ] || { echo "错误：argo=xvargopt 需要设置 xvargopt。"; return 1; } ;;
    *) echo "错误：argo 仅支持 vmpt、vwpt、xvargopt。"; return 1 ;;
  esac
  [ "$xvargo" != yes ] || [ "$argo" = xvargopt ] || { echo "错误：xvargopt 必须作为本次唯一的 Argo 绑定协议。"; return 1; }
  if [ -n "$argo" ]; then
    if { [ -n "$agn" ] && [ -z "$agk" ]; } || { [ -z "$agn" ] && [ -n "$agk" ]; }; then echo "错误：固定隧道需要同时填写 agn 与 agk。"; return 1; fi
    if [ -n "$agn" ] && ! [[ "$agn" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$ ]]; then echo "错误：agn 必须是有效的固定隧道域名。"; return 1; fi
  fi
  for option in vlpt xhpt vxpt vwpt vmpt xhypt xvcdnpt xvargopt; do
    [ -n "${!option}" ] || continue
    [[ "${!option}" =~ ^[0-9]{1,6}$ ]] && xray_range_valid "${!option}" 1 65535 || { echo "错误：$option 必须是 1 至 65535 的端口或空值。"; return 1; }
    printf -v "$option" '%s' "$((10#${!option}))"
  done
  for option in xhyjpt shyjpt hyjpt; do
    normalized=${!option}; [ -n "$normalized" ] || continue
    normalized=${normalized//:/-}
    xray_range_valid "$normalized" 1 65535 || { echo "错误：$option 必须是有效端口或连续范围。"; return 1; }
    printf -v "$option" '%s' "$normalized"
  done
  for flag in xhp vlp vxp vwp xhyp xdns xicp xvcdn xvargo; do [ "${!flag}" != yes ] || has_xray=yes; done
  for flag in hyp tup anp arp ssp; do [ "${!flag}" != yes ] || has_singbox=yes; done
  if [ "$vmfm" != none ] && [ "$has_xray" = no ] && [ "$has_singbox" = yes ]; then
    echo "错误：本次 vmpt 归属 Sing-box，不能使用 Xray 的 vmfm。"; return 1
  fi
  for spec in xhmode:xhp vxmode:vxp xvcdnmode:xvcdn; do
    option=${spec%:*}; flag=${spec#*:}; mode=auto
    # 已标记的旧命令保留原默认；新 GUI/命令使用 auto，显式模式始终优先。
    if [ "$flag" = xhp ] && [ "$xhextra" = yes ] && [ "$cfgver" = V26.09.07 ]; then mode=stream-one; fi
    if [ "$flag" = vxp ] && [ "$vxextra" = yes ]; then mode=packet-up; fi
    mode=${!option:-$mode}
    case "$mode" in auto|packet-up|stream-up|stream-one) ;; *) echo "错误：$option 模式无效。"; return 1 ;; esac
    if [ "$flag" = xvcdn ] || { [ "$flag" = vxp ] && [ -n "$cdnym" ]; }; then
      [ "$mode" != auto ] || mode=packet-up
      [ "$mode" != stream-one ] || { echo "错误：CDN 不开放 stream-one，请用 packet-up，或确认支持流式上传后用 stream-up。"; return 1; }
    fi
    printf -v "$option" '%s' "$mode"
  done
  # 在依赖安装前完成纯文本域名/端口检查，避免输入错误时仍改动系统。
  if [ "$xvcdn" = yes ]; then
    [[ "$cdnym" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$ ]] && [[ "$cdnym" != *..* ]] || { echo "错误：xvcdnpt 必须提供有效的 cdnym 域名。"; return 1; }
    xvcdnpt=${xvcdnpt:-2087}
    case "$xvcdnpt" in 443|2053|2083|2087|2096|8443) ;; *) echo "错误：xvcdnpt 需使用 Cloudflare HTTPS 代理端口：443/2053/2083/2087/2096/8443。"; return 1 ;; esac
  fi
  xpadding=${xpadding:-100-1000}; xmuxcon=${xmuxcon:-0}; xmuxmax=${xmuxmax:-3}
  fmascii=${fmascii:-prefer_entropy}; fmpadding=${fmpadding:-0-0}
  fmnoise=${fmnoise:-32-128}; fmreset=${fmreset:-30-60}; fmdelay=${fmdelay:-0}
  fmfraglen=${fmfraglen:-100-200}; fmfragdelay=${fmfragdelay:-0}; fmfragsplit=${fmfragsplit:-3-6}
  xhycc=${xhycc:-auto}; xhyup=${xhyup:-0}; xhydown=${xhydown:-0}
  case "$xhycc" in auto|bbr|reno|brutal|force-brutal) ;; *) echo "错误：xhycc 拥塞控制无效。"; return 1 ;; esac
  [[ "$xhyup" =~ ^[0-9]{1,6}$ ]] && [[ "$xhydown" =~ ^[0-9]{1,6}$ ]] && xray_range_valid "$xhyup" 0 100000 && xray_range_valid "$xhydown" 0 100000 || { echo "错误：xhyup/xhydown 必须是 0-100000 的整数 Mbps。"; return 1; }
  xhyup=$((10#$xhyup)); xhydown=$((10#$xhydown))
  if [ "$xhycc" = force-brutal ] && { [ "$xhyup" = 0 ] || [ "$xhydown" = 0 ]; }; then echo "错误：force-brutal 需要明确设置正值 xhyup/xhydown。"; return 1; fi
  if [ "$xhyp" != yes ] && { [ "$xhycc" != auto ] || [ "$xhyup" != 0 ] || [ "$xhydown" != 0 ]; }; then echo "错误：Xray QUIC 参数必须同时启用 xhypt。"; return 1; fi
  xray_validate_tuning '通用参数' || return 1
  for spec in vl xh vx vw vm hy xvd xva; do xray_validate_profile_tuning "$spec" || return 1; done
  [ "$xhextra" != yes ] || xhttp_validate_extra xh "$xhmode" || return 1
  [ "$vxextra" != yes ] || xhttp_validate_extra vx "$vxmode" || return 1
  [ "$xvcdnextra" != yes ] || xhttp_validate_extra xvd "$xvcdnmode" || return 1
  [ "$xvargoextra" != yes ] || xhttp_validate_extra xva packet-up || return 1
}

# 显式的内置参数组，不声称是所有网络的最佳值。未启用 extra 时完全省略该对象。
# XMUX 为客户端连接复用策略，必须放在 extra.xmux，不写入服务端接收参数。
# 默认会话/序号位于路径；会话字段兼容输出新旧名称，仅在启用时生成 downloadSettings。
render_xhttp_extra() {
  local side="$1" profile="$2" inherited_fm="$3" key field kind fallback target value rendered body='' mux='' result
  local address port security sni host path mode fingerprint public_key short_id tls_fields='' down_fm=''
  while IFS='|' read -r key field kind fallback target; do
    case "$target" in control|download) continue ;; esac
    [ "$target" = both ] || [ "$target" = "$side" ] || continue
    xhttp_extra_value "$profile" "$key" "$fallback" value
    case "$kind" in
      headers) rendered=$(xhttp_headers_json "$value") || return 1 ;;
      enum:true,false) rendered="$value" ;;
      int:*|keepalive) if [ "$value" = -1 ]; then rendered=-1; else rendered=$((10#$value)); fi ;;
      *) rendered="\"$(json_escape "$value")\"" ;;
    esac
    case "$field" in
      xmux.*) mux="${mux:+$mux,}\"${field#xmux.}\":$rendered" ;;
      *)
        body="${body:+$body,}\"$field\":$rendered"
        case "$field" in
          sessionPlacement) body="$body,\"sessionIDPlacement\":$rendered" ;;
          sessionKey) body="$body,\"sessionIDKey\":$rendered" ;;
        esac ;;
    esac
  done < <(xhttp_extra_schema)
  [ -z "$mux" ] || body="$body,\"xmux\":{$mux}"
  result="{$body}"
  if [ "$side" = client ] && [ "$(xhttp_extra_value "$profile" xdownload false)" = true ]; then
    address=$(xhttp_extra_value "$profile" xdownaddr '')
    port=$(xhttp_extra_value "$profile" xdownport 443); port=$((10#$port))
    security=$(xhttp_extra_value "$profile" xdownsecurity tls)
    sni=$(xhttp_extra_value "$profile" xdownsni ''); [ -n "$sni" ] || sni="$address"
    host=$(xhttp_extra_value "$profile" xdownhost '')
    path=$(xhttp_extra_value "$profile" xdownpath ''); [ -n "$path" ] || path=$(transport_path "$profile")
    mode=$(xhttp_extra_value "$profile" xdownmode auto)
    fingerprint=$(xhttp_extra_value "$profile" xdownfp chrome)
    case "$security" in
      tls) tls_fields=",\"tlsSettings\":{\"serverName\":\"$(json_escape "$sni")\",\"fingerprint\":\"$fingerprint\",\"alpn\":[\"h2\"],\"allowInsecure\":$(xhttp_extra_value "$profile" xdowninsecure false)}" ;;
      reality)
        public_key=$(xhttp_extra_value "$profile" xdownpbk '')
        short_id=$(xhttp_extra_value "$profile" xdownsid '')
        tls_fields=",\"realitySettings\":{\"serverName\":\"$(json_escape "$sni")\",\"fingerprint\":\"$fingerprint\",\"password\":\"$public_key\",\"shortId\":\"$short_id\"}" ;;
    esac
    if [ "$(xhttp_extra_value "$profile" xdownfm none)" = inherit ] && [ -n "$inherited_fm" ]; then down_fm=",\"finalmask\":$inherited_fm"; fi
    body="$body,\"downloadSettings\":{\"address\":\"$(json_escape "$address")\",\"port\":$port,\"network\":\"xhttp\",\"security\":\"$security\"$tls_fields$down_fm,\"xhttpSettings\":{\"host\":\"$(json_escape "$host")\",\"path\":\"$(json_escape "$path")\",\"mode\":\"$mode\",\"extra\":$result}}"
  fi
  printf '{%s}' "$body"
}

# 按接入路径生成配套参数。客户端分片不进入服务端，其余所选掩码两端配套。
# paddingMin/Max 是额外填充率，不是字节数；FM 默认不复用 VLESS UUID。
prepare_xray_profile() {
  local protocol="$1" mode=none password extra_client='' fm_json='' server_json='' target tmp extra=no transport=tcp token settings masks='' server_masks='' header pad_min pad_max
  local xpadding="$xpadding" xmuxcon="$xmuxcon" xmuxmax="$xmuxmax"
  local fmpass="$fmpass" fmascii="$fmascii" fmpadding="$fmpadding" fmheader="$fmheader" fmdomain="$fmdomain"
  local fmnoise="$fmnoise" fmreset="$fmreset" fmdelay="$fmdelay"
  local fmfraglen="$fmfraglen" fmfragdelay="$fmfragdelay" fmfragsplit="$fmfragsplit"
  xray_apply_profile_tuning "$protocol" || return 1
  direct_server_extra=''
  direct_server_fm=''
  direct_client_mode=auto
  direct_server_mode=auto
  direct_no_sse=false
  case "$protocol" in
    xh) mode="$xhfm"; extra="$xhextra"; direct_client_mode="$xhmode" ;;
    vl) mode="$vlfm" ;;
    vx) mode="$vxfm"; extra="$vxextra"; direct_client_mode="$vxmode" ;;
    vw) mode="$vwfm" ;;
    vm) mode="$vmfm" ;;
    hy) mode="$xhyfm"; transport=udp ;;
    xvd) mode="$xvcdnfm"; extra="$xvcdnextra"; direct_client_mode="$xvcdnmode" ;;
    xva) mode="$xvargofm"; extra="$xvargoextra"; direct_client_mode=packet-up; direct_no_sse=true ;;
    *) return 1 ;;
  esac
  if [ "$extra" = yes ]; then
    # 客户端选择不应限制服务端接受能力；服务端保持 auto。
    direct_server_extra=$(render_xhttp_extra server "$protocol" '') || return 1
    direct_server_extra=", \"extra\": $direct_server_extra"
  elif [ "$direct_no_sse" = true ]; then
    # Tunnel 的基础兼容行为，不是用户启用的可选 extra 参数组。
    direct_server_extra=', "noSSEHeader": true'
  fi
  if [ "$mode" != none ]; then
    password=''; header=''
    if xray_mask_selected "$mode" sudoku || xray_mask_selected "$mode" salamander || xray_mask_selected "$mode" mkcp-aes128gcm; then
      password=${fmpass:-$(openssl rand -hex 32)}; [ -n "$password" ] || return 1
      password=$(json_escape "$password")
    fi
    if xray_mask_selected "$mode" header-custom; then
      header=${fmheader:-$(openssl rand -hex 16)}; [ -n "$header" ] || return 1
    fi
    pad_min=${fmpadding%%-*}; pad_max=${fmpadding##*-}
    pad_min=$((10#$pad_min)); pad_max=$((10#$pad_max))
    local -a selected_masks
    IFS=',' read -r -a selected_masks <<< "$mode"
    for token in "${selected_masks[@]}"; do
      case "$token" in
        fragment) settings="{\"packets\":\"tlshello\",\"length\":\"$fmfraglen\",\"delay\":\"$fmfragdelay\",\"maxSplit\":\"$fmfragsplit\"}" ;;
        sudoku) settings="{\"password\":\"$password\",\"ascii\":\"$fmascii\",\"paddingMin\":$pad_min,\"paddingMax\":$pad_max}" ;;
        salamander|mkcp-aes128gcm) settings="{\"password\":\"$password\"}" ;;
        noise) settings="{\"reset\":\"$fmreset\",\"noise\":[{\"rand\":\"$fmnoise\",\"randRange\":\"0-255\",\"delay\":\"$fmdelay\"}]}" ;;
        header-custom)
          if [ "$transport" = tcp ]; then settings="{\"clients\":[[{\"type\":\"hex\",\"packet\":\"$header\"}]],\"servers\":[[{\"type\":\"hex\",\"packet\":\"$header\"}]]}"
          else settings="{\"client\":[{\"type\":\"hex\",\"packet\":\"$header\"}],\"server\":[{\"type\":\"hex\",\"packet\":\"$header\"}]}"; fi ;;
        header-dns) settings="{\"domain\":\"$fmdomain\"}" ;;
        *) settings='{}' ;;
      esac
      masks="${masks:+$masks,}{\"type\":\"$token\",\"settings\":$settings}"
      [ "$token" = fragment ] || server_masks="${server_masks:+$server_masks,}{\"type\":\"$token\",\"settings\":$settings}"
    done
    fm_json="\"$transport\":[$masks]"
    [ -z "$server_masks" ] || server_json="\"$transport\":[$server_masks]"
  fi
  if [ "$protocol" = hy ] && { [ -n "$xhyjpt" ] || [ "$xhycc" != auto ] || [ "$xhyup" != 0 ] || [ "$xhydown" != 0 ]; }; then
    local hopping=${xhyjpt//:/-} congestion=${xhycc/auto/brutal} hop_json=''
    [ -z "$hopping" ] || hop_json=",\"udpHop\":{\"ports\":\"$hopping\",\"interval\":15}"
    fm_json="${fm_json:+$fm_json,}\"quicParams\":{\"congestion\":\"$congestion\",\"brutalUp\":\"${xhyup}mbps\",\"brutalDown\":\"${xhydown}mbps\"$hop_json}"
    server_json="${server_json:+$server_json,}\"quicParams\":{\"congestion\":\"$congestion\",\"brutalUp\":\"${xhydown}mbps\",\"brutalDown\":\"${xhyup}mbps\"$hop_json}"
  fi
  [ -z "$fm_json" ] || fm_json="{$fm_json}"
  [ -z "$server_json" ] || direct_server_fm=", \"finalmask\": {$server_json}"
  if [ "$extra" = yes ]; then extra_client=$(render_xhttp_extra client "$protocol" "$fm_json") || return 1; fi
  local extra_encoded fm_encoded
  extra_encoded=$(uri_percent_encode "$extra_client")
  fm_encoded=$(uri_percent_encode "$fm_json")
  [ "${#extra_encoded}" -le 65536 ] && [ "${#fm_encoded}" -le 65536 ] || { echo "错误：配套 URL 参数过长。"; return 1; }
  # 精确保存已生成的 URL 参数，而不是只保存开关；以后修改内置参数也不改变旧部署的 list。
  # 版本 2：版本、客户端模式、extra、fm。旧直连版本 1 仍可读取，禁止 source/eval。
  target="$HOME/agsbx/xray_${protocol}_profile"
  [ -d "$HOME/agsbx" ] && [ ! -L "$HOME/agsbx" ] && [ ! -L "$target" ] || return 1
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    echo "错误：直连配置状态不是普通文件：$target"; return 1
  fi
  tmp=$(mktemp "$HOME/agsbx/.direct-profile.XXXXXX") || return 1
  if ! printf '%s\n' '2' "$direct_client_mode" "$extra_encoded" "$fm_encoded" > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    echo "错误：无法保存直连增强配置。"
    return 1
  fi
}

load_xray_profile() {
  local protocol="$1" legacy_extra="$2" legacy_fm="$3" target version trailing='' field decoded current=no expected_version=2
  case "$protocol" in xh|vl|vx|vw|vm|hy|xvd|xva) ;; *) return 1 ;; esac
  target="$HOME/agsbx/xray_${protocol}_profile"
  direct_extra_encoded=''
  direct_fm_encoded=''
  direct_url_options=''
  direct_extra_label=''
  direct_fm_label=''
  direct_client_mode=auto
  if grep -Fq "\"agsbx-profile-${protocol}-v2\"" "$HOME/agsbx/xr.json" 2>/dev/null; then current=yes
  elif grep -Fq "\"agsbx-direct-${protocol}-v1\"" "$HOME/agsbx/xr.json" 2>/dev/null; then current=yes; expected_version=1; target="$HOME/agsbx/direct_${protocol}_profile"; fi
  if [ "$current" = no ]; then
    # update 只替换脚本；没有新生成器 email 标记的旧入站，仍使用历史参数。
    # 标记同时防止回退旧脚本重建后，误用遗留的新状态文件。
    direct_extra_encoded=$(uri_percent_encode "$legacy_extra")
    direct_fm_encoded=$(uri_percent_encode "$legacy_fm")
  else
    if [ ! -f "$target" ] || [ -L "$target" ]; then
      echo "错误：当前直连缺少有效的配套状态文件，拒绝生成不匹配的节点链接：$target"; return 1
    fi
    if ! {
      IFS= read -r version && [ "$version" = "$expected_version" ] && { [ "$version" = 1 ] || { [ "$version" = 2 ] && IFS= read -r direct_client_mode; }; } \
        && IFS= read -r direct_extra_encoded && IFS= read -r direct_fm_encoded \
        && ! { IFS= read -r trailing || [ -n "$trailing" ]; }
    } < "$target"; then
      echo "错误：直连配置状态损坏，拒绝生成不匹配的节点链接：$target"; return 1
    fi
    for field in "$direct_extra_encoded" "$direct_fm_encoded"; do
      # 只接受完整、规范的 URI 组件，不能让损坏状态注入额外查询参数。
      [ "${#field}" -le 65536 ] || return 1
      decoded=$(uri_percent_decode "$field") || return 1
      [ "$(uri_percent_encode "$decoded")" = "$field" ] || return 1
      case "$decoded" in ''|\{*\}) ;; *) echo "错误：直连参数状态不是 JSON 对象。"; return 1 ;; esac
    done
    case "$direct_client_mode" in auto|packet-up|stream-up|stream-one) ;; *) return 1 ;; esac
    case "$protocol" in vl|vw|vm|hy) [ -z "$direct_extra_encoded" ] || return 1 ;; esac
  fi
  if [ -n "$direct_extra_encoded" ]; then
    direct_url_options="&extra=$direct_extra_encoded"
    direct_extra_label='(extra)'
  fi
  if [ -n "$direct_fm_encoded" ]; then
    direct_url_options="$direct_url_options&fm=$direct_fm_encoded"
    direct_fm_label='-fm'
  fi
}

# Caddyfile 双引号参数转义：防止 Naive 自定义凭据中的空格、引号或反斜杠破坏配置结构。
caddyfile_quote() {
  local input="$1"
  input=${input//\\/\\\\}
  input=${input//\"/\\\"}
  printf '"%s"' "$input"
}

valid_port(){
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

valid_plain_text(){
  local value="$1" maximum="${2:-1024}"
  [ "${#value}" -le "$maximum" ] || return 1
  local LC_ALL=C
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [[ ! "$value" =~ [[:cntrl:]] ]]
}

deployment_port_specs(){
  printf '%s\n' \
    'vlp:port_vl_re:port_vl_re:tcp' 'xhp:port_xh:port_xh:tcp' 'vxp:port_vx:port_vx:tcp' \
    'vwp:port_vw:port_vw:tcp' 'vmp:port_vm_ws:port_vm_ws:tcp' 'hyp:port_hy2:port_hy2:udp' \
    'xhyp:port_xhy2:port_xhy2:udp' 'tup:port_tu:port_tu:udp' 'anp:port_an:port_an:tcp' \
    'arp:port_ar:port_ar:tcp' 'ssp:port_ss:port_ss:both' 'sop:port_so:port_so:both' \
    'xvcdn:port_xvcdn:port_xvcdn:tcp' 'xvargo:port_xvargo:port_xvargo:tcp' \
    'xdns:port_xdns:port_xdns:udp' "mierup:port_mieru:port_mieru:$(printf '%s' "$mieru_protocol" | tr A-Z a-z)" \
    'sub:subpt:subport.log:tcp'
}

validate_deployment_inputs(){
  local flag variable file network value key
  while IFS=: read -r flag variable file network; do
    [ "${!flag}" = yes ] || continue
    value=${!variable}
    [ -z "$value" ] || valid_port "$value" || { echo "错误：$variable 必须为 1-65535 的端口。"; return 1; }
    [ -z "$value" ] || printf -v "$variable" '%s' "$((10#$value))"
  done < <(deployment_port_specs)
  for key in uuid obfs_pass name naiveuser naivepass mieruuser mierupass acmem naivesite; do
    valid_plain_text "${!key}" 1024 || { echo "错误：$key 太长或包含控制字符。"; return 1; }
  done
  [ -z "$subid" ] || [[ "$subid" =~ ^[A-Za-z0-9_-]{16,128}$ ]] \
    || { echo "错误：subid 仅支持 16-128 位字母、数字、短横线和下划线。"; return 1; }
  [ "$mierup" != yes ] || [ -z "$port_mieru" ] || validate_mita_port_value "$port_mieru" || return 1
  [ "$xdns" != yes ] || valid_domain "$xdnsym" || { echo "错误：XDNS 必须提供有效的 xdnsym。"; return 1; }
  [ -z "$ym_vl_re" ] || valid_domain "$ym_vl_re" || { echo "错误：reym 域名格式无效。"; return 1; }
  [ -z "$cdnym" ] || valid_domain "$cdnym" || { echo "错误：cdnym 域名格式无效。"; return 1; }
  case "$warp" in ''|s|x|sx|xs|s4|s6|x4|x6|s4x4|x4s4|s4x6|x6s4|s6x4|x4s6|s6x6|x6s6|sx4|x4s|sx6|x6s|xs4|s4x|xs6|s6x) ;; *) echo "错误：warp 值无效，拒绝退回直连。"; return 1 ;; esac
  if [ "$hyp" = yes ] && [ "$xhyp" = yes ] && [ -n "$shyjpt" ] && [ -n "$xhyjpt" ]; then
    local a="${shyjpt//:/-}" b="${xhyjpt//:/-}"
    if [ "$((10#${a%%-*}))" -le "$((10#${b##*-}))" ] && [ "$((10#${b%%-*}))" -le "$((10#${a##*-}))" ]; then
      echo "错误：两个 Hysteria2 跳跃范围重叠，请分别设置 shyjpt 与 xhyjpt。"; return 1
    fi
  fi
}

preflight_service_slots(){
  local flag xr=no sb=no
  [ "$sub" != yes ] || command -v timeout >/dev/null 2>&1 \
    || { echo "错误：订阅需要 timeout 以限制 ACME 和 TLS 校验时间；未开始部署。"; return 1; }
  for flag in xhp vlp vxp vwp xhyp xdns xicp xvcdn xvargo; do [ "${!flag}" != yes ] || xr=yes; done
  for flag in hyp tup anp arp ssp; do [ "${!flag}" != yes ] || sb=yes; done
  if [ "$vmp" = yes ] || [ "$sop" = yes ]; then
    determine_secondary_common_core
    [ "$secondary_common_core" = xr ] && xr=yes || sb=yes
  fi
  if [ "$sub" = yes ] && [ "$xr" = no ]; then sb=yes; fi
  case ",$secp," in *,naive,*) sb=yes ;; esac
  [ "$xr" != yes ] || require_service_slot xray || return 1
  [ "$sb" != yes ] || require_service_slot sing-box || return 1
  [ -z "$argo" ] || require_service_slot cloudflared || return 1
  [ -z "$naive" ] || require_service_slot caddy || return 1
  managed_script_path >/dev/null || return 1
}

port_requested_for_deployment(){
  local candidate="$1" wanted_network="$2" flag variable file network value
  while IFS=: read -r flag variable file network; do
    [ "${!flag}" = yes ] || continue
    value=${!variable}
    if [ -z "$value" ] && [ -f "$HOME/agsbx/$file" ]; then value=$(cat "$HOME/agsbx/$file") || return 1; fi
    [ -n "$value" ] && valid_port "$value" || continue
    [ "$((10#$value))" = "$candidate" ] || continue
    if [ "$network" = "$wanted_network" ] || [ "$network" = both ] || [ "$wanted_network" = both ]; then return 0; fi
  done < <(deployment_port_specs)
  return 1
}

port_plan_conflicts(){
  local port="$1" network="$2" key="${3:-}"
  [ -n "$port_plan_file" ] && [ -f "$port_plan_file" ] || return 1
  awk -v port="$port" -v net="$network" -v key="$key" \
    '$1 == port && $3 != key && ($2 == net || $2 == "both" || net == "both") {found=1} END {exit !found}' "$port_plan_file"
}

port_in_use(){
  local port="$1" network="$2" output
  command -v ss >/dev/null 2>&1 || return 2
  case "$network" in tcp) output=$(ss -ltn 2>/dev/null) ;; udp) output=$(ss -lun 2>/dev/null) ;; *) output=$(ss -ltun 2>/dev/null) ;; esac
  [ $? -eq 0 ] || return 2
  printf '%s\n' "$output" | awk -v port="$port" '$4 ~ (":" port "$") {found=1} END {exit !found}'
}

plan_deployment_ports(){
  local flag variable file network value status candidate
  port_plan_file=$(mktemp "$HOME/agsbx/.port-plan.XXXXXX") || return 1
  [ -z "$naive" ] || printf '443 both caddy\n80 tcp caddy-http\n' >> "$port_plan_file"
  [ -z "$naive_secondary_port" ] || printf '%s tcp naive-secondary\n' "$naive_secondary_port" >> "$port_plan_file"
  while IFS=: read -r flag variable file network; do
    [ "${!flag}" = yes ] || continue
    value=${!variable}
    if [ -z "$value" ] && [ -f "$HOME/agsbx/$file" ]; then value=$(cat "$HOME/agsbx/$file") || return 1; fi
    if [ -z "$value" ] && [ -n "$cdnym" ]; then
      case "$variable" in
        port_vx|port_vw|port_vm_ws)
          for candidate in 8080 8880 2052 2082 2086 2095 80; do
            port_plan_conflicts "$candidate" "$network" && continue
            port_requested_for_deployment "$candidate" "$network" && continue
            if port_in_use "$candidate" "$network"; then continue
            else [ "$?" = 1 ] || return 1; fi
            value="$candidate"; break
          done ;;
      esac
    fi
    [ -n "$value" ] || value=$(get_free_port "$network") || return 1
    valid_port "$value" || { echo "错误：$file 中的历史端口无效。"; return 1; }
    value=$((10#$value))
    if port_plan_conflicts "$value" "$network"; then echo "错误：$variable 与本次其他入口端口冲突：$value/$network"; return 1; fi
    if port_in_use "$value" "$network"; then
      echo "错误：端口 $value/$network 已被占用。"; return 1
    else
      status=$?; [ "$status" = 1 ] || { echo "错误：无法确认端口占用。"; return 1; }
    fi
    if [ -n "$cdnym" ]; then
      case "$variable" in
        port_vx|port_vw|port_vm_ws) case "$value" in 80|8080|8880|2052|2082|2086|2095) ;; *) echo "错误：CDN HTTP 端口不受 Cloudflare 支持：$value"; return 1 ;; esac ;;
        subpt) case "$value" in 443|2053|2083|2087|2096|8443) ;; *) echo "错误：CDN 订阅需显式使用支持的 HTTPS subpt。"; return 1 ;; esac ;;
      esac
    fi
    printf '%s\n' "$value" > "$HOME/agsbx/$file" || return 1
    printf -v "$variable" '%s' "$value"
    printf '%s %s %s\n' "$value" "$network" "$variable" >> "$port_plan_file" || return 1
  done < <(deployment_port_specs)
  if [ "$sub" = yes ]; then
    value=$(get_free_port tcp) || return 1
    printf '%s\n' "$value" > "$HOME/agsbx/subport_real.log" || return 1
    printf '%s tcp subport_real\n' "$value" >> "$port_plan_file" || return 1
  fi
  validate_hopping_ports_against_plan
}

validate_hopping_ports_against_plan(){
  local hops target variable port network key first last
  for variable in shyjpt xhyjpt; do
    hops=${!variable}; [ -n "$hops" ] || continue
    [ "$variable" = shyjpt ] && target=port_hy2 || target=port_xhy2
    hops=${hops//:/-}; first=$((10#${hops%%-*})); last=$((10#${hops##*-}))
    while read -r port network key; do
      [ "$key" = "$target" ] && continue
      [ "$network" = tcp ] && continue
      if [ "$port" -ge "$first" ] && [ "$port" -le "$last" ]; then
        echo "错误：$variable 会截获 $key 的 UDP 端口 $port。"; return 1
      fi
    done < "$port_plan_file"
  done
}

get_free_port() {
  local allocated_port network="${1:-both}" attempt status
  for attempt in {1..200}; do
    allocated_port=$((15000 + (RANDOM * 32768 + RANDOM) % 45001))
    port_plan_conflicts "$allocated_port" "$network" && continue
    port_requested_for_deployment "$allocated_port" "$network" && continue
    if port_in_use "$allocated_port" "$network"; then continue
    else status=$?; [ "$status" = 1 ] || return 1; fi
    printf '%s\n' "$allocated_port"
    return 0
  done
  echo "错误：未能分配空闲端口。" >&2
  return 1
}

# Naive sidecar 使用受内核特权端口阈值保护的回环端口，避免普通本地进程在 Sing-box 停机时抢占监听。
get_free_privileged_port() {
  local upper="$1" span start attempt allocated_port
  [ "$upper" -ge 200 ] 2>/dev/null || return 1
  span=$((upper - 199))
  start=$((RANDOM % span))
  for ((attempt=0; attempt<span; attempt++)); do
    allocated_port=$((200 + (start + attempt) % span))
    [ "$allocated_port" -eq 443 ] && continue
    port_requested_for_deployment "$allocated_port" tcp && continue
    if ! port_is_listening "$allocated_port"; then
      printf '%s\n' "$allocated_port"
      return 0
    fi
  done
  return 1
}

# 端口分配与持久化助手：统一收敛此前在各协议装配段逐字复制十余次的同构逻辑。
# 规则：用户显式指定值（$1 非空）优先并落盘覆盖；否则复用历史落盘值；首次安装才随机分配。
# 用法：port_xh=$(init_port "$port_xh" port_xh)
init_port() {
  local port_file="$HOME/agsbx/$2"
  if [ -n "$1" ]; then
    echo "$1" > "$port_file"
  elif [ ! -e "$port_file" ]; then
    get_free_port > "$port_file"
  fi
  local value
  value=$(cat "$port_file") || return 1
  valid_port "$value" || return 1
  printf '%s\n' "$((10#$value))"
}

# 订阅回源端口专用助手：随机分配时需避开与外部订阅端口 ($1) 撞车
init_subport_real() {
  local port_file="$HOME/agsbx/subport_real.log" p
  if [ ! -e "$port_file" ]; then
    p=$(get_free_port)
    while [ "$p" -eq "$1" ]; do
      p=$(get_free_port)
    done
    echo "$p" > "$port_file"
  fi
  cat "$port_file"
}

# 版本号比较助手：输出 gt/eq/lt，表示 $1 相对 $2 的 高/同/低。
# 按 "." 分段做数值比较，自动忽略前导 v，纯 awk 实现（兼容无 sort -V 的 busybox）。
# 用途：upx/downx 方向校验——升级命令拒绝更低版本、降级命令拒绝更高版本，防止用反命令。
vercmp() {
  awk -v a="${1#v}" -v b="${2#v}" 'BEGIN{
    na=split(a,x,"."); nb=split(b,y,"."); n=(na>nb)?na:nb
    for(i=1;i<=n;i++){ xi=x[i]+0; yi=y[i]+0; if(xi>yi){print "gt";exit} if(xi<yi){print "lt";exit} }
    print "eq"
  }'
}

enable_system_bbr() {
  # 系统网络加速：① UDP/QUIC 收发缓冲区调优；② 内核 TCP BBR 拥塞控制与自适应系统网络栈加速。
  # 确保 /etc/sysctl.conf 存在，防止 sed 报 can't read 错误
  [ -f /etc/sysctl.conf ] || touch /etc/sysctl.conf

  # 自适应内存检测：通过 /proc/meminfo 获取 VPS 物理内存总量 (单位: MB)
  local mem_total_kb mem_total_mb tcp_max_buf udp_buf
  mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
  case "$mem_total_kb" in ''|*[!0-9]*) mem_total_kb=0 ;; esac
  mem_total_mb=$((mem_total_kb / 1024))

  # 自适应分级缓冲区配置策略：
  #   - 极速小鸡 (≤512MB RAM): 限制最大缓冲区为 8MB (防止 OOM)
  #   - 标准 VPS (512MB < RAM ≤ 1536MB, 如1C1G): 最大缓冲区为 16MB (平衡安全与带宽)
  #   - 高配 VPS (>1536MB RAM): 最大充盈 32MB (最大化释放高带宽高延迟长距离传输性能)
  if [ "$mem_total_mb" -gt 0 ] && [ "$mem_total_mb" -le 512 ]; then
    tcp_max_buf=8388608
    udp_buf=8388608
    echo "检测到 VPS 物理内存为 ${mem_total_mb}MB (低配型)，已自适应将网络最大缓冲区限制为 8MB 以防内存溢出(OOM)。🔒"
  elif [ "$mem_total_mb" -gt 512 ] && [ "$mem_total_mb" -le 1536 ]; then
    tcp_max_buf=16777216
    udp_buf=16777216
    echo "检测到 VPS 物理内存为 ${mem_total_mb}MB (标准型)，已自适应将网络最大缓冲区设置为 16MB (平衡型)。🚀"
  else
    tcp_max_buf=33554432
    udp_buf=33554432
    if [ "$mem_total_mb" -gt 0 ]; then
      echo "检测到 VPS 物理内存为 ${mem_total_mb}MB (高配型)，已自适应将网络最大缓冲区设置为 32MB 以最大化吞吐性能。🔥"
    else
      # 内存读取异常时兜底采用标准配置
      tcp_max_buf=16777216
      udp_buf=16777216
    fi
  fi

  # —— ① UDP/QUIC 缓冲区自适应调优 ——
  # UDP 缓冲区太小时 quic-go 会告警并降速，调大上限可显著提升 QUIC 吞吐。
  local cur_rmem
  cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
  case "$cur_rmem" in ''|*[!0-9]*) cur_rmem=0 ;; esac
  if [ "$cur_rmem" -lt "$udp_buf" ]; then
    sed -i '/net.core.rmem_max/d;/net.core.wmem_max/d' /etc/sysctl.conf
    echo "net.core.rmem_max = $udp_buf" >> /etc/sysctl.conf
    echo "net.core.wmem_max = $udp_buf" >> /etc/sysctl.conf
    sysctl -w net.core.rmem_max=$udp_buf >/dev/null 2>&1
    sysctl -w net.core.wmem_max=$udp_buf >/dev/null 2>&1
    echo "已调大 UDP 收发缓冲区至 $((udp_buf / 1024 / 1024))MiB，提升 QUIC(Hysteria2/TUIC/HTTP3)吞吐。🚀"
  else
    echo "提示：UDP 缓冲区已为 $((cur_rmem / 1024 / 1024))MiB，无需下调。"
  fi

  # —— ② 内核 TCP BBR 拥塞控制与系统网络栈自适应加速 ——
  echo "正在为您检测并开启系统级 TCP BBR 与网络栈自适应优化加速..."

  # 内核未内置 bbr 时先尝试加载模块
  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
    modprobe tcp_bbr >/dev/null 2>&1
  fi

  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
    # 批量清理已存在的参数，防止多次运行脚本堆积垃圾配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fin_timeout/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_keepalive_time/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_syn_backlog/d' /etc/sysctl.conf
    sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
    sed -i '/net.core.netdev_max_backlog/d' /etc/sysctl.conf

    # 写入自适应和通用加速配置
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_slow_start_after_idle = 0" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_rmem = 4096 87380 $tcp_max_buf" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_wmem = 4096 65536 $tcp_max_buf" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_notsent_lowat = 131072" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_fin_timeout = 30" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_keepalive_time = 1200" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 8192" >> /etc/sysctl.conf
    echo "net.core.somaxconn = 8192" >> /etc/sysctl.conf
    echo "net.core.netdev_max_backlog = 16384" >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1

    # 再次读取系统实时拥塞控制算法以验证是否真正启用成功
    local current_congestion_control
    current_congestion_control=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "${current_congestion_control}" = "bbr" ]; then
      echo "TCP BBR 拥塞控制及系统网络栈自适应优化已成功应用！🚀"
    else
      echo "警告：网络参数配置已写入，但 BBR 实时加载失败，可能处于受限虚拟化环境。😿"
    fi
  else
    echo "警告：当前 VPS 系统内核版本较低，不支持 BBR 模块。建议您升级内核后再开启网络加速。😿"
  fi
}

get_reality_domain() {
  # 优先获取IP所在地理位置字符串，合并IPv4与IPv6位置
  local loc=""
  if [ -n "$v4dq" ]; then
    loc="$v4dq"
  elif [ -n "$v6dq" ]; then
    loc="$v6dq"
  fi

  local domains=""
  # 将位置信息转换为小写进行模糊匹配
  local loc_lower=$(echo "$loc" | tr '[:upper:]' '[:lower:]' 2>/dev/null)

  # 根据地理位置关键字分配最优伪装域名池
  case "$loc_lower" in
    *japan*|*jp*|*日本*|*tokyo*)
      domains="www.lovelive-anime.jp www.sony.co.jp www.nintendo.co.jp www.line.me"
      ;;
    *singapore*|*sg*|*新加坡*|*hong*|*hk*|*香港*|*taiwan*|*tw*|*台湾*|*korea*|*kr*|*韩国*|*asia*|*亚洲*)
      domains="www.samsung.com www.asus.com www.lazada.com www.hkex.com.hk"
      ;;
    *germany*|*de*|*德国*|*united*kingdom*|*uk*|*gb*|*英国*|*france*|*fr*|*法国*|*netherlands*|*nl*|*荷兰*|*europe*|*欧洲*|*italy*|*it*|*意大利*|*spain*|*es*|*西班牙*|*spotify*|*ikea*|*bmw*)
      domains="www.pepsico.com www.spotify.com www.ikea.com www.bmw.com"
      ;;
    *united*states*|*us*|*美国*|*america*)
      domains="www.apple.com images.apple.com www.microsoft.com www.nvidia.com www.intel.com"
      ;;
    *)
      # 默认兜底域名池（选取全球大厂CDN良好支持的静态节点）
      domains="www.apple.com images.apple.com www.microsoft.com www.pepsico.com"
      ;;
  esac

  # 在选定的域名池中随机挑选一个
  if command -v shuf >/dev/null 2>&1; then
    echo "$domains" | tr ' ' '\n' | shuf -n 1
  else
    # 极精简系统回退方案，使用当前微秒/秒与进程PID哈希得到伪随机数
    local rand_num=$(date +%s%N 2>/dev/null | cut -c 9-15)
    [ -z "$rand_num" ] && rand_num=42
    local count=0
    for d in $domains; do count=$((count + 1)); done
    local idx=$(( (rand_num % count) + 1 ))
    local curr=1
    for d in $domains; do
      if [ $curr -eq $idx ]; then
        echo "$d"
        break
      fi
      curr=$((curr + 1))
    done
  fi
}

#============================================================
# [第1段] 环境初始化：解析用户传入的协议变量，校验运行前提
#------------------------------------------------------------
# 🎯 架构维护提示与变量数据流向：
# 1. xvcdnpt/xvcdn 关联超旗舰 CDN 节点 (VLESSenc+XHTTP+TLS+Vision+Finalmask)
#    - 数据流向：Xray/Sing-box Inbound 配置文件装配 -> 终端大卡片打印 -> 客户端订阅
# 2. xvargopt/xvargo 关联超旗舰 Argo 隧道节点 (VLESSenc+XHTTP+TLS+Vision+Finalmask)
#    - 数据流向：后台拉起 cloudflared 进程 -> 本地 Xray/Sing-box Inbound 隧道接收
# 3. subpt/subid/sub 关联 Clash/Mihomo 本地加密 Web 订阅分发服务
#    - 关联逻辑：在 Xray/Sing-box 中增量装配 TLS 卸载 Inbound 反代本地 127.0.0.1 上的 Web 服务
#============================================================
export LANG=en_US.UTF-8
# 系统级 IP 栈策略只接受四个精确值。未设置代表保持现状；显式空值代表取消受管策略并恢复原状态。
# 语法校验必须早于依赖安装和任何系统写入，避免拼写错误时仍改变 VPS。
ipv_request_set=no
ipv_request_mode=''
case "$1" in
  ''|rep)
    [ -z "${ipv+x}" ] || ipv_request_set=yes
    ipv_request_mode="${ipv-}"
    case "$ipv_request_mode" in
      ''|4|6|'4;6'|'6;4') ;;
      *)
        echo "错误：ipv 仅支持 4、6、\"4;6\"、\"6;4\"；未设置表示保持，ipv= 表示恢复原状态。"
        exit 1
        ;;
    esac
    ;;
esac
# 每次调用从公开协议参数推导内部标志，不继承父进程中的中间状态或展示名称。
vlp='' vmp='' vwp='' vmag='' hyp='' xhyp='' tup='' xhp='' vxp='' anp='' ssp='' arp='' sop='' wap='' xicp='' xvcdn='' xvargo='' mierup=''
tls_cert_ready=no tls_cert_file='' tls_key_file='' tls_caddy_reuse_notice_shown=no
rep_manage_certificate=no
[ -z "${vlpt+x}" ] || vlp=yes
[ -z "${vmpt+x}" ] || { vmp=yes; vmag=yes; }
[ -z "${vwpt+x}" ] || { vwp=yes; vmag=yes; }
[ -z "${shypt+x}" ] || hyp=yes
[ -z "${xhypt+x}" ] || xhyp=yes
[ -z "${tupt+x}" ] || tup=yes
[ -z "${xhpt+x}" ] || xhp=yes
[ -z "${vxpt+x}" ] || vxp=yes
[ -z "${anpt+x}" ] || anp=yes
[ -z "${sspt+x}" ] || ssp=yes
[ -z "${arpt+x}" ] || arp=yes
[ -z "${sopt+x}" ] || sop=yes
[ -z "${warp+x}" ] || wap=yes
[ -z "${xdns+x}" ] || xdns=yes
[ -z "${xdnspt+x}" ] || xdns=yes
[ -z "${xicmp+x}" ] || xicp=yes
[ -z "${xicmppt+x}" ] || xicp=yes
[ -z "${xvcdnpt+x}" ] || xvcdn=yes
case "${mieru:-}" in
  y|Y|yes|YES|1|true|TRUE) mierup=yes ;;
  ''|n|N|no|NO|0|false|FALSE) ;;
  *) echo "错误：mieru 开关仅支持 y/yes/1 或 n/no/0。"; exit 1 ;;
esac
[ -z "${mierupt+x}" ] || { mierup=yes; mieru_port_preset=yes; }
[ -z "${mieruuser+x}" ] || mieru_user_preset=yes
[ -z "${mierupass+x}" ] || mieru_pass_preset=yes
[ -z "${mierutrans+x}" ] || mieru_transport_preset=yes
# vmag 是"存在可走 Argo 隧道的协议"总开关，决定第8段是否拉起 cloudflared。
# 此前仅 vmpt/vwpt 置位，导致单独设 xvargopt+argo=xvargopt 时隧道被静默跳过；补齐 xvargo。
[ -z "${xvargopt+x}" ] || { xvargo=yes; vmag=yes; }
case "$1" in
  ''|rep) validate_xray_options || exit 1 ;;
  del|list|status|stats|top|update|res|start|stop|restart|reload|upx|ups|downx|downs|__cert_renew|__cert_reload|__restore_hops) ;;
  *) echo "错误：未知命令 $1，请使用 agsbx help。"; exit 1 ;;
esac
# 布尔开关 sub 归一化：仅 sub=y/yes/1 视为显式启用，其余值或空/未设一律=关闭，统一规范（禁用 sub=on 之类写法）。
# 随后 subpt/subid 一旦设值仍视为启用（向后兼容旧用法）。naive=<域名>、argo=<协议> 属「带值即启用」，不在此归一化。
case "${sub:-}" in y|yes|1) sub=yes ;; *) sub='' ;; esac
[ -z "${subpt+x}" ] || sub=yes
[ -z "${subid+x}" ] || sub=yes
if agsbx_installed || agsbx_running; then
if [ "$1" = "rep" ]; then
[ -n "$naive" ] || [ "$mierup" = yes ] || [ "$vwp" = yes ] || [ "$sop" = yes ] || [ "$vxp" = yes ] || [ "$ssp" = yes ] || [ "$vlp" = yes ] || [ "$vmp" = yes ] || [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$xhp" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || [ "$xvcdn" = yes ] || [ "$xvargo" = yes ] || { echo "提示：rep重置协议时，请在脚本前至少设置一个协议变量哦! 💣"; exit; }
fi
else
[ "$1" = "del" ] || [ -n "$naive" ] || [ "$mierup" = yes ] || [ "$vwp" = yes ] || [ "$sop" = yes ] || [ "$vxp" = yes ] || [ "$ssp" = yes ] || [ "$vlp" = yes ] || [ "$vmp" = yes ] || [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$xhp" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || [ "$xvcdn" = yes ] || [ "$xvargo" = yes ] || { echo "提示：未安装airgosbx脚本，请在脚本前至少设置一个协议变量哦！💣"; exit; }
fi
uuid=${uuid:-''}
obfs_pass=${obfs_pass:-''}
export port_vl_re=${vlpt:-''}
export port_vm_ws=${vmpt:-''}
export port_vw=${vwpt:-''}
export port_hy2=${shypt:-''}
export port_xhy2=${xhypt:-''}
export port_tu=${tupt:-''}
export port_xh=${xhpt:-''}
export port_vx=${vxpt:-''}
export port_an=${anpt:-''}
export port_ar=${arpt:-''}
export port_ss=${sspt:-''}
export port_so=${sopt:-''}
export port_xdns=53
export flag_xicmp=${xicmppt:-''}
export xdnsym=${xdnsym:-''}
export port_xvcdn=${xvcdnpt:-''}
export port_xvargo=${xvargopt:-''}
export port_mieru=${mierupt:-''}
export subpt=${subpt:-''}
subid=${subid:-''}
export ym_vl_re=${reym:-''}
export cdnym=${cdnym:-''}
export argo=${argo:-''}
export ARGO_DOMAIN=${agn:-''}
ARGO_AUTH=${agk:-''}
export -n ARGO_AUTH 2>/dev/null || true
unset agk
export ippz=${ippz:-''}
export warp=${warp:-''}
secp=${secp:-''}
securl=${securl:-''}
export name=${name:-''}
export alns=${alns:-''}
export acmemode=${acmemode:-''}
export certip=${certip:-''}
export certym=${certym:-''}
export certwild=${certwild:-''}
export certcrt=${certcrt:-''}
export certkey=${certkey:-''}
export acmem=${acmem:-''}
export acmetimeout=${acmetimeout:-''}
sslcom_eab_kid=${sslcom_eab_kid:-''}
sslcom_eab_hmac=${sslcom_eab_hmac:-''}
export certdns=${certdns:-''}
export shyjpt=${shyjpt:-''}
export xhyjpt=${xhyjpt:-''}
export hyjpt=${hyjpt:-''}
mieruuser=${mieruuser:-''}
mierupass=${mierupass:-''}
mierutrans=${mierutrans:-tcp}
case "$mierutrans" in
  tcp|TCP) mieru_protocol=TCP ;;
  udp|UDP) mieru_protocol=UDP ;;
  *)
    if [ "$mierup" = yes ]; then
      echo "错误：mierutrans 仅支持 tcp 或 udp。"
      exit 1
    fi
    mieru_protocol=TCP ;;
esac

# 跳跃端口智能自适应回退：如果用户仅设置了全局 hyjpt 而未设置专属变量，
# 则自动将 hyjpt 分配给当前激活的对应内核。
# 专属变量 shyjpt/xhyjpt 一旦显式设置，则始终优先于全局 hyjpt。
if [ -n "$hyjpt" ]; then
  [ -z "$shyjpt" ] && [ "$hyp" = yes ] && shyjpt="$hyjpt"
  [ -z "$xhyjpt" ] && [ "$xhyp" = yes ] && xhyjpt="$hyjpt"
fi

#============================================================
# [第2段] 全局常量与帮助信息函数
#------------------------------------------------------------
# 🎯 架构说明：
# - 本大段定义了脚本基本版本号、帮助菜单展示函数 showmode()。
# - 关联性：由第 12 段（主入口流程决策）在检测到已有安装或用户输入无效协议时调用以展示帮助说明。
#============================================================
v46url="https://icanhazip.com"
# 默认安装、重置和更新 main 分支脚本；显式传入 agsbxurl 时仍允许覆盖默认来源。
agsbxurl="${agsbxurl:-https://raw.githubusercontent.com/hugobaum/sbxrago/refs/heads/main/airgosbx.sh}"
showmode(){
printf '%s\n' "${C_BOLD}核心命令速查（完整命令 ${C_YELLOW}agsbx cmds${C_RESET}${C_BOLD} ｜ 变量 ${C_YELLOW}agsbx vars${C_RESET}${C_BOLD} ｜ 全部 ${C_YELLOW}agsbx help${C_RESET}${C_BOLD}）：${C_RESET}"
echo "  · 主脚本：bash <(curl -Ls $agsbxurl)  或  bash <(wget -qO- $agsbxurl)"
echo "  · 节点信息：agsbx list      ｜ 资源/流量：agsbx status"
echo "  · 修改型操作需要系统 flock；证书维护任务与部署操作互斥"
echo "  · rep 后请重新导入链接；新 SOCKS 凭据、传输路径及订阅令牌独立保存"
echo "  · 重置配置：变量组 agsbx rep ｜ 更新脚本：agsbx update ｜ 卸载：agsbx del"
echo "    rep 保留 Naive/Caddy 与全部证书；如需变更这些内容，必须先 agsbx del 再重装"
echo "  · 内核启停：agsbx start｜stop｜restart｜reload [xray｜sb｜caddy｜mita｜all]"
echo "  · 升级内核：agsbx upx/ups [版本]  ｜ 降级：agsbx downx/downs <版本>"
hr
echo
}
#============================================================
# [第3段] 启动信息输出、系统环境检测、依赖安装（顺序执行区）
#------------------------------------------------------------
# 🎯 架构说明：
# - 本大段处理启动的控制台文字渲染、自适应 VPS 架构识别 (amd64/arm64) 以及无人值守依赖静默补全。
# - 关联性：为后续第 4 段 (ACME证书 socat 依赖) 和第 10 段 (Web订阅 busybox httpd 依赖) 奠定系统级环境基础。
#============================================================
printf '%s\n' "${C_CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${C_RESET}"
printf '%s\n' "${C_BOLD}Airgosbx 小钢炮脚本 💣${C_RESET}"
echo "项目地址：github.com/hugobaum/sbxrago"
echo "基于 yonggekkk/argosbx"
printf '%s\n' "当前版本：${C_GREEN}${AIRGOSBX_VERSION}${C_RESET}"
printf '%s\n' "${C_CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${C_RESET}"
hostname=$(uname -n)
op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)
case $(uname -m) in
arm64|aarch64) cpu=arm64;;
amd64|x86_64) cpu=amd64;;
*) echo "目前脚本不支持$(uname -m)架构" && exit
esac
umask 077
argo_token_file="$HOME/agsbx/sbargotoken.log"
# 依赖自检与按需补全：每次运行先逐个 command -v 检测脚本真正用到的外部命令，仅对缺失项调用系统包管理器安装；
# 已具备则零操作、不联网。跨发行版覆盖 apt/dnf/yum/pacman/apk/zypper，包名差异(ss/pgrep/crontab)按系映射。
# 仅在 Debian 这类精简系统上首次补齐工具，coreutils/util-linux 等基础包默认存在故不重复纳入。
ensure_deps(){
  local pm="" miss="" cmd pkg
  if command -v apt-get >/dev/null 2>&1; then pm=apt
  elif command -v dnf >/dev/null 2>&1; then pm=dnf
  elif command -v yum >/dev/null 2>&1; then pm=yum
  elif command -v pacman >/dev/null 2>&1; then pm=pacman
  elif command -v apk >/dev/null 2>&1; then pm=apk
  elif command -v zypper >/dev/null 2>&1; then pm=zypper
  fi
  # 取某命令在当前包管理器下的包名（差异项分系处理，其余与命令同名）
  pkg_of(){
    case "$1" in
      ip|ss)   case "$pm" in dnf|yum) echo iproute ;; *) echo iproute2 ;; esac ;;
      pgrep)   case "$pm" in dnf|yum|pacman) echo procps-ng ;; *) echo procps ;; esac ;;
      crontab) case "$pm" in apt) echo cron ;; dnf|yum|pacman) echo cronie ;; *) echo "" ;; esac ;;
      xz)      case "$pm" in apt) echo xz-utils ;; *) echo xz ;; esac ;;
      *)       echo "$1" ;;
    esac
  }
  # 脚本真正依赖的命令清单（curl/wget 二选一，单独判断）
  for cmd in openssl socat iptables unzip tar xz ip ss pgrep crontab; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    pkg=$(pkg_of "$cmd"); [ -z "$pkg" ] && continue
    case " $miss " in *" $pkg "*) ;; *) miss="$miss $pkg" ;; esac
  done
  # curl 与 wget 至少需其一，两者都缺才补 curl
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    miss="$miss curl"
  fi
  # 订阅后端才需要 BusyBox httpd；按发行版补包后仍以实际 applet 能力为准。
  if [ "$sub" = yes ] && ! subscription_http_binary >/dev/null; then
    if [ "$pm" = apk ]; then pkg=busybox-extras; else pkg=busybox; fi
    case " $miss " in *" $pkg "*) ;; *) miss="$miss $pkg" ;; esac
  fi
  if [ "$pm" = apk ] && [ ! -f "$HOME/agsbx/sbx_update" ]; then
    # Alpine 的兼容层准备仅属于首次安装，不得在 list/res 等命令中触发。
    if ! apk update >/dev/null 2>&1 || ! apk add gcompat libc6-compat bash >/dev/null 2>&1; then
      echo "错误：Alpine 基础兼容依赖准备失败。"
      return 1
    fi
    atomic_text_file "$HOME/agsbx/sbx_update" prepared || return 1
  fi
  [ -z "$miss" ] && return 0
  if [ -z "$pm" ]; then
    echo "未识别系统包管理器，请手动安装依赖：$miss"
    return 1
  fi
  echo "检测到缺失依赖：$miss，正在通过 $pm 自动安装……"
  case "$pm" in
    apt)    export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1 && apt-get install -y $miss >/dev/null 2>&1 ;;
    dnf)    dnf install -y $miss >/dev/null 2>&1 ;;
    yum)    yum install -y $miss >/dev/null 2>&1 ;;
    pacman) pacman -S --needed --noconfirm $miss >/dev/null 2>&1 ;;
    apk)    apk add $miss >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive install $miss >/dev/null 2>&1 ;;
  esac
  [ $? -eq 0 ] || { echo "错误：依赖安装失败，已停止部署。"; return 1; }
  for cmd in openssl socat iptables unzip tar xz ip ss pgrep crontab; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "错误：仍缺少依赖 $cmd。"; return 1; }
  done
  if [ "$sub" = yes ] && ! subscription_http_binary >/dev/null; then
    echo "错误：安装完成后仍未找到包含 httpd applet 的 BusyBox。"
    return 1
  fi
  return 0
}
# 依赖补全只由首次安装入口调用；查看、启停、重置、更新均不得隐式安装依赖。
#============================================================
# [第4段] 网络检测与 WARP 配置函数
#------------------------------------------------------------
# 🎯 架构说明：
# - 本大段包含 IPv4/IPv6 双栈网络探测函数 v4v6()、WARP 住宅网络出口配置函数 warpsx()。
# - 关联性：探测并取得的真实公网 IP `$server_ip` 将作为后续第 9 段（卡片打印）和第 10 段（Web 订阅链接拼接）的数据基础。
#============================================================
v4v6(){
# 结果缓存：同一次运行内 IP 与归属地不会变化，避免重复发起最多 4 次外网探测（每次最长阻塞 5 秒）
if [ "$v4v6_probed" = yes ]; then
return
fi
v4v6_probed=yes
v4=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- "$v46url" 2>/dev/null) )
v6=$( (command -v curl >/dev/null 2>&1 && curl -s6m5 "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 --tries=2 -qO- "$v46url" 2>/dev/null) )
v4=$(printf '%s\n' "$v4" | sed -n '1{s/[[:space:]]//g;p;}')
v6=$(printf '%s\n' "$v6" | sed -n '1{s/[[:space:]]//g;p;}')
valid_ipv4 "$v4" || v4=''
valid_ipv6 "$v6" || v6=''
v4dq=''; v6dq=''
if [ -n "$v4" ]; then
v4dq=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 https://ip.fm | sed -n 's/.*Location: //p' 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- https://ip.fm | grep '<span class="has-text-grey-light">Location:' | tail -n1 | sed -E 's/.*>Location: <\/span>([^<]+)<.*/\1/' 2>/dev/null) )
fi
if [ -n "$v6" ]; then
v6dq=$( (command -v curl >/dev/null 2>&1 && curl -s6m5 https://ip.fm | sed -n 's/.*Location: //p' 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 --tries=2 -qO- https://ip.fm | grep '<span class="has-text-grey-light">Location:' | tail -n1 | sed -E 's/.*>Location: <\/span>([^<]+)<.*/\1/' 2>/dev/null) )
fi
[ -n "$v4" ] || v4dq=''
[ -n "$v6" ] || v6dq=''
}
show_vps_info(){
# 依赖安装完成后集中展示部署决策真正需要的 VPS 信息；公网 IP 复用 v4v6() 缓存，后续不重复联网探测。
local kernel_version cpu_model cpu_cores mem_total_kb mem_available_kb mem_total_mb mem_available_mb
local disk_total disk_used disk_available disk_usage current_cc bbr_support
kernel_version=$(uname -r 2>/dev/null)
cpu_model=$(awk -F: '
  /model name|Hardware|Processor/ {
    value=$2
    sub(/^[[:space:]]+/, "", value)
    if (value != "") { print value; exit }
  }
' /proc/cpuinfo 2>/dev/null)
[ -n "$cpu_model" ] || cpu_model=$(uname -m 2>/dev/null)
cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
case "$cpu_cores" in ''|*[!0-9]*) cpu_cores=$(awk '/^processor[[:space:]]*:/{count++} END{print count+0}' /proc/cpuinfo 2>/dev/null) ;; esac
[ "$cpu_cores" -gt 0 ] 2>/dev/null || cpu_cores="未知"
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
mem_available_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
case "$mem_total_kb" in ''|*[!0-9]*) mem_total_mb="未知" ;; *) mem_total_mb="$((mem_total_kb / 1024)) MiB" ;; esac
case "$mem_available_kb" in ''|*[!0-9]*) mem_available_mb="未知" ;; *) mem_available_mb="$((mem_available_kb / 1024)) MiB" ;; esac
read -r disk_total disk_used disk_available disk_usage <<EOF
$(df -hP / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')
EOF
disk_total=${disk_total:-未知}; disk_used=${disk_used:-未知}; disk_available=${disk_available:-未知}; disk_usage=${disk_usage:-未知}
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
[ -n "$current_cc" ] || current_cc="未知"
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  bbr_support="当前可用"
else
  bbr_support="当前未加载或内核不支持"
fi
v4v6
section "VPS 配置信息"
printf "  %-12s %s\n" "操作系统：" "${op:-未知}"
printf "  %-12s %s\n" "内核版本：" "${kernel_version:-未知}"
printf "  %-12s %s\n" "CPU 架构：" "$cpu"
printf "  %-12s %s\n" "CPU 型号：" "${cpu_model:-未知}"
printf "  %-12s %s\n" "CPU 核心：" "$cpu_cores 核"
printf "  %-12s %s\n" "内存：" "总计 $mem_total_mb / 可用 $mem_available_mb"
printf "  %-12s %s\n" "系统盘：" "总计 $disk_total / 已用 $disk_used（$disk_usage）/ 可用 $disk_available"
printf "  %-12s %s\n" "公网 IPv4：" "${v4:-未检测到}${v4dq:+（$v4dq）}"
printf "  %-12s %s\n" "公网 IPv6：" "${v6:-未检测到}${v6dq:+（$v6dq）}"
printf "  %-12s %s\n" "TCP 拥塞算法：" "$current_cc"
printf "  %-12s %s\n" "BBR 状态：" "$bbr_support"
echo "  网络调优：接下来将按内存容量自动调整 TCP/UDP 缓冲区，并尝试启用 BBR。"
hr2
echo
}
warpsx(){
if [ "$wap" = yes ]; then
echo "正在获取安全的本地 WARP 网络身份..."
# 1. 生成 WireGuard 标准 Curve25519 密钥对（WARP API 要求标准 Base64 编码）
pvk=""
pub=""
    # 优先复用 wg；缺少时使用已有 OpenSSL，不在重置过程中安装额外工具。
    # 方案 A：使用 wireguard-tools 的 wg genkey/pubkey（最标准、最可靠）
    if command -v wg >/dev/null 2>&1; then
      pvk=$(wg genkey 2>/dev/null)
      if [ -n "$pvk" ]; then
        pub=$(echo "$pvk" | wg pubkey 2>/dev/null)
      fi
      if [ -n "$pvk" ] && [ -n "$pub" ]; then
        echo "WireGuard 密钥对已通过 wg 工具生成 ✓"
      else
        echo "[诊断提示] wg genkey/pubkey 执行异常，尝试 openssl 回退..."
        pvk=""; pub=""
      fi
    fi
    # 方案 B：使用 openssl 生成 x25519 密钥并提取原始 32 字节 Base64（几乎所有 VPS 均有 openssl）
    if [ -z "$pvk" ] || [ -z "$pub" ]; then
      if command -v openssl >/dev/null 2>&1; then
        wg_pem=$(mktemp)
        openssl genpkey -algorithm x25519 -out "$wg_pem" 2>/dev/null
        if [ -s "$wg_pem" ]; then
          pvk=$(openssl pkey -in "$wg_pem" -outform DER 2>/dev/null | tail -c 32 | base64 2>/dev/null)
          pub=$(openssl pkey -in "$wg_pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 2>/dev/null)
          if [ -n "$pvk" ] && [ -n "$pub" ]; then
            echo "WireGuard 密钥对已通过 openssl x25519 生成 ✓"
          else
            echo "[诊断提示] openssl 提取 x25519 原始密钥失败，密钥对为空。"
            pvk=""; pub=""
          fi
        else
          echo "[诊断提示] openssl genpkey -algorithm x25519 执行失败（可能 openssl 版本 < 1.1.0 不支持 x25519）。"
        fi
        rm -f "$wg_pem"
      else
        echo "[诊断提示] 系统未安装 openssl，无法生成 WireGuard 密钥对。"
      fi
    fi

  if [ -n "$pvk" ] && [ -n "$pub" ]; then
    # 2. 直接向 Cloudflare 官方 API 注册，不经过任何第三方（确保私钥不泄露）
    reg_err=$(mktemp)
    reg_json=""
    if command -v curl >/dev/null 2>&1; then
      reg_json=$(curl -sSL -w "\nHTTP_CODE:%{http_code}" "https://api.cloudflareclient.com/v0a2158/reg" \
        -H "User-Agent: okhttp/3.12.1" \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$pub\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Linux\",\"serial_number\":\"\",\"locale\":\"en_US\"}" \
        2> "$reg_err")
    else
      reg_json=$(timeout 10 wget -qO- --save-headers --post-data="{\"key\":\"$pub\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Linux\",\"serial_number\":\"\",\"locale\":\"en_US\"}" \
        --header="User-Agent: okhttp/3.12.1" \
        --header="Content-Type: application/json" \
        "https://api.cloudflareclient.com/v0a2158/reg" 2> "$reg_err")
    fi

    # 分离 HTTP 状态码与响应体
    http_code=$(echo "$reg_json" | grep "HTTP_CODE" | cut -d: -f2)
    response_body=$(echo "$reg_json" | grep -v "HTTP_CODE")

    c_id=$(echo "$response_body" | awk -F '"client_id":"' '{print $2}' | awk -F '"' '{print $1}')
    if [ -n "$c_id" ]; then
      # 从 WARP 注册 API 响应中动态提取客户端专属虚拟 IPv6 地址（config.interface.addresses.v6）
      # 提取策略：先截取 "addresses" 之后的 JSON 片段，避开前面出现的 peers.endpoint.v6
      wpv6=$(printf '%s' "$response_body" | sed 's/.*"addresses"://' | awk -F'"v6":"' '{split($2,a,"\""  );print a[1]}')
      if [ -z "$wpv6" ]; then
        echo "[诊断提示] 未能从 WARP API 响应中提取客户端专属虚拟 IPv6 地址，WARP IPv6 隧道可能不可用。"
        rm -f "$reg_err"
        return 1
      fi
      res=$(echo "$c_id" | base64 -d 2>/dev/null | od -v -An -t u1 | head -n1 | awk '{print "["$1", "$2", "$3"]"}')
      if [ -z "$res" ]; then
hr
        echo "[诊断提示] 步骤 3：解析 Cloudflare 返回数据失败！"
        echo "-> 错误详情: 无法从 client_id 解码提取 Reserved 字段（base64 或 od 解码异常）"
        echo "-> 原始 client_id: $c_id"
hr
        rm -f "$reg_err"
        echo "错误：WARP Reserved 数据无效，已停止部署。"
        return 1
      fi
    else
hr
      echo "[诊断提示] 步骤 2：Cloudflare WARP 官方 API 注册失败！"
      echo "-> 请求接口: https://api.cloudflareclient.com/v0a2158/reg"
      [ -n "$http_code" ] && echo "-> 接口返回 HTTP 状态码: $http_code"
      if echo "$response_body" | grep -q "Invalid public key"; then
        echo "-> 错误原因: 提交的公钥格式不被 Cloudflare 接受 (Invalid public key)"
        echo "-> 排查方向: 密钥生成工具输出了非 WireGuard 标准格式的公钥，请检查 wg/openssl 是否正常"
      else
        echo "-> 物理连接错误信息: $(cat "$reg_err" 2>/dev/null)"
        echo "-> 响应内容已省略，避免输出可能包含的账户凭据。"
        if [ -z "$http_code" ]; then
          echo "-> 常见原因: VPS 物理网络出站受阻，api.cloudflareclient.com 被防火墙屏蔽或连接超时。"
        else
          echo "-> 常见原因: Cloudflare API 拒绝了请求，请检查请求参数是否有效。"
        fi
      fi
hr
      rm -f "$reg_err"
      echo "错误：WARP 注册失败，已停止部署，未降级到直连。"
      return 1
    fi
    rm -f "$reg_err"
  else
hr
    echo "[诊断提示] 步骤 1：WireGuard 密钥生成失败！"
    echo "-> wg 工具和 openssl 均无法在当前系统下成功生成 WireGuard Curve25519 密钥对。"
    echo "-> 建议: 安装 wireguard-tools (apt install wireguard-tools) 或升级 openssl >= 1.1.0。"
    echo "-> 请求的 WARP 身份未就绪，拒绝改用直连出站。"
hr
    echo "错误：WARP 密钥生成失败，已停止部署。"
    return 1
  fi
fi
if [ -n "$name" ]; then
sxname=$name-
echo "$sxname" > "$HOME/agsbx/name"
echo
echo "所有节点名称前缀：$name"
fi
v4v6
if [ "$wap" != yes ]; then
s1outtag=direct; s2outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warpargo
else
case "$warp" in
""|sx|xs) s1outtag=warp-out; s2outtag=warp-out; x1outtag=warp-out; x2outtag=warp-out; xip='"::/0", "0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warp ;;
s ) s1outtag=warp-out; s2outtag=warp-out; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warp ;;
s4) s1outtag=warp-out; s2outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; sip='"0.0.0.0/0"'; wap=warp ;;
s6) s1outtag=warp-out; s2outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; sip='"::/0"'; wap=warp ;;
x ) s1outtag=direct; s2outtag=direct; x1outtag=warp-out; x2outtag=warp-out; xip='"::/0", "0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warp ;;
x4) s1outtag=direct; s2outtag=direct; x1outtag=warp-out; x2outtag=direct; xip='"0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warp ;;
x6) s1outtag=direct; s2outtag=direct; x1outtag=warp-out; x2outtag=direct; xip='"::/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warp ;;
s4x4|x4s4) s1outtag=warp-out; s2outtag=direct; x1outtag=warp-out; x2outtag=direct; xip='"0.0.0.0/0"'; sip='"0.0.0.0/0"'; wap=warp ;;
s4x6|x6s4) s1outtag=warp-out; s2outtag=direct; x1outtag=warp-out; x2outtag=direct; xip='"::/0"'; sip='"0.0.0.0/0"'; wap=warp ;;
s6x4|x4s6) s1outtag=warp-out; s2outtag=direct; x1outtag=warp-out; x2outtag=direct; xip='"0.0.0.0/0"'; sip='"::/0"'; wap=warp ;;
s6x6|x6s6) s1outtag=warp-out; s2outtag=direct; x1outtag=warp-out; x2outtag=direct; xip='"::/0"'; sip='"::/0"'; wap=warp ;;
sx4|x4s) s1outtag=warp-out; s2outtag=warp-out; x1outtag=warp-out; x2outtag=direct; xip='"0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warp ;;
sx6|x6s) s1outtag=warp-out; s2outtag=warp-out; x1outtag=warp-out; x2outtag=direct; xip='"::/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warp ;;
xs4|s4x) s1outtag=warp-out; s2outtag=direct; x1outtag=warp-out; x2outtag=warp-out; xip='"::/0", "0.0.0.0/0"'; sip='"0.0.0.0/0"'; wap=warp ;;
xs6|s6x) s1outtag=warp-out; s2outtag=direct; x1outtag=warp-out; x2outtag=warp-out; xip='"::/0", "0.0.0.0/0"'; sip='"::/0"'; wap=warp ;;
* ) s1outtag=direct; s2outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warpargo ;;
esac
fi
case "$warp" in *x4*) wxryx='ForceIPv4' ;; *x6*) wxryx='ForceIPv6' ;; *) wxryx='ForceIPv6v4' ;; esac
# 复用本函数开头 v4v6() 已探测到的结果，避免再发起两次 icanhazip 探测（每次最多阻塞 5 秒）。
# $v4 / $v6 非空即代表对应协议栈的出站连通性已确认。
[ -n "$v4" ] && v4_ok=true
[ -n "$v6" ] && v6_ok=true
if [ "$v4_ok" = true ] && [ "$v6_ok" = true ]; then
case "$warp" in *s4*) sbyx='prefer_ipv4' ;; *) sbyx='prefer_ipv6' ;; esac
case "$warp" in *x4*) xryx='ForceIPv4v6' ;; *x*) xryx='ForceIPv6v4' ;; *) xryx='ForceIPv4v6' ;; esac
elif [ "$v4_ok" = true ] && [ "$v6_ok" != true ]; then
case "$warp" in *s4*) sbyx='ipv4_only' ;; *) sbyx='prefer_ipv6' ;; esac
case "$warp" in *x4*) xryx='ForceIPv4' ;; *x*) xryx='ForceIPv6v4' ;; *) xryx='ForceIPv4v6' ;; esac
elif [ "$v4_ok" != true ] && [ "$v6_ok" = true ]; then
case "$warp" in *s6*) sbyx='ipv6_only' ;; *) sbyx='prefer_ipv4' ;; esac
case "$warp" in *x6*) xryx='ForceIPv6' ;; *x*) xryx='ForceIPv4v6' ;; *) xryx='ForceIPv6v4' ;; esac
else
# 双栈探测均失败（如临时断网）时兜底默认值，避免向内核配置写入空的 domainStrategy 导致启动失败
sbyx='prefer_ipv4'
xryx='ForceIPv4v6'
fi
# 系统 IP 策略负责原生 direct 出站；WARP 中显式的 s4/s6/x4/x6 仍独立决定隧道内协议族。
[ -z "$ip_policy_xray_strategy" ] || xryx="$ip_policy_xray_strategy"
case "$warp" in
  *s4*|*s6*) ;;
  *) [ -z "$ip_policy_sing_strategy" ] || sbyx="$ip_policy_sing_strategy" ;;
esac
}
#============================================================
# [第5段] 内核下载函数（含哈希校验）
#------------------------------------------------------------
# 🎯 架构说明：
# - 本大段包含 upxray() (Xray下载与SHA256校验)、upsingbox() (Singbox下载)。
# - 关联性：由第 8 段 (安装编排主函数 ins()) 在初次部署或第 11 段 (upx/ups内核更新) 运行时调用，提供可运行的物理二进制文件。
#============================================================
release_json(){
  local repository="$1" version="${2:-latest}" url
  if [ "$version" = latest ]; then url="https://api.github.com/repos/$repository/releases/latest"
  else
    [[ "$version" =~ ^v?[0-9]+(\.[0-9]+){1,3}([-A-Za-z0-9.]*)?$ ]] || return 1
    url="https://api.github.com/repos/$repository/releases/tags/$version"
  fi
  if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$url"
  elif command -v wget >/dev/null 2>&1; then wget -qO- --timeout=30 --tries=2 "$url"
  else return 1; fi
}

release_tag(){
  local tag
  tag=$(printf '%s\n' "$1" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+){1,3}([-A-Za-z0-9.]*)?$ ]] || return 1
  printf '%s' "$tag"
}

release_asset_digest(){
  local digest
  digest=$(printf '%s\n' "$1" | awk -v target="$2" '
    /"name":[[:space:]]*"/ {
      name=$0; sub(/^.*"name":[[:space:]]*"/, "", name); sub(/".*$/, "", name)
      wanted=(name == target)
    }
    wanted && /"digest":[[:space:]]*"sha256:/ {
      value=$0; sub(/^.*"digest":[[:space:]]*"sha256:/, "", value); sub(/".*$/, "", value)
      print value; exit
    }
  ')
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}

activate_core_candidate(){
  local core="$1" candidate="$2" binary="$HOME/agsbx/$1" config target backup was_running=no
  case "$core" in xray) config=xr.json; target=xray ;; sing-box) config=sb.json; target=sb ;; caddy) config=Caddyfile; target=caddy ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ ! -L "$binary" ] || return 1
  chmod 700 "$candidate" && "$candidate" version >/dev/null 2>&1 || return 1
  if [ -s "$HOME/agsbx/$config" ]; then
    case "$core" in
      xray) "$candidate" run -test -c "$HOME/agsbx/$config" >/dev/null 2>&1 || return 1 ;;
      sing-box) "$candidate" check -c "$HOME/agsbx/$config" >/dev/null 2>&1 || return 1 ;;
      caddy) "$candidate" validate --config "$HOME/agsbx/$config" >/dev/null 2>&1 || return 1 ;;
    esac
  fi
  agsbx_component_running "$core" && was_running=yes
  backup=$(mktemp -d "$HOME/agsbx/.kernel-rollback.XXXXXX") || return 1
  if [ -e "$binary" ]; then cp -a -- "$binary" "$backup/previous" || { rmdir "$backup"; return 1; }; fi
  if ! mv -f -- "$candidate" "$binary"; then rm -rf -- "$backup"; return 1; fi
  if [ "$was_running" = yes ] && ! kctl restart "$target"; then
    echo "错误：新 $core 未正常启动，尝试恢复原内核。"
    if ! stop_managed_service "$core"; then echo "恢复备份保留在：$backup"; return 1; fi
    if [ -f "$backup/previous" ]; then
      cp -a -- "$backup/previous" "$backup/restore" && mv -f -- "$backup/restore" "$binary" \
        && kctl start "$target" || { echo "错误：旧内核恢复不完整，备份：$backup"; return 1; }
    fi
    rm -rf -- "$backup"
    return 1
  fi
  rm -rf -- "$backup"
}

install_script_shortcut(){
  local mode="$1" destination source temporary downloaded_version
  destination=$(managed_script_path) || return 1
  source="${BASH_SOURCE[0]}"
  mkdir -p "${destination%/*}" || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    shortcut_is_owned "$destination" || { echo "错误：快捷命令路径不属于 Airgosbx。"; return 1; }
  fi
  temporary=$(mktemp "${destination%/*}/.agsbx-script.XXXXXX") || return 1
  if [ "$mode" = current ] && [ -f "$source" ] && [ ! -L "$source" ]; then
    cp -- "$source" "$temporary" || { rm -f "$temporary"; return 1; }
  else
    fetch_file "$agsbxurl" "$temporary" || { rm -f "$temporary"; return 1; }
    if [ "$mode" = current ]; then
      downloaded_version=$(sed -n "s/^AIRGOSBX_VERSION='\\([^']*\\)'.*/\\1/p" "$temporary")
      [ "$downloaded_version" = "$AIRGOSBX_VERSION" ] || {
        rm -f "$temporary"; echo "错误：下载期间脚本版本已变化，请保存脚本到文件后重新部署。"; return 1;
      }
    fi
  fi
  if ! shortcut_is_owned "$temporary" || ! env -u BASH_ENV -u ENV bash --noprofile --norc -n "$temporary" \
    || ! chmod 700 "$temporary" || ! mv -f -- "$temporary" "$destination"; then
    rm -f "$temporary"; echo "错误：快捷命令验证或替换失败，已保留可用版本。"; return 1
  fi
  SCRIPT_PATH="$destination"
}

refresh_runtime_cron(){
  local before after component cfg mode=runtime
  [ "$rep_mode" != yes ] || mode=runtime-rep
  before=$(mktemp) && after=$(mktemp) || return 1
  read_crontab_or_empty "$before" && filter_component_cron "$before" "$after" "$mode" \
    || { rm -f "$before" "$after"; return 1; }
  if ! pidof systemd >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
    for component in xray sing-box caddy; do
      [ "$component:$rep_mode" != caddy:yes ] || continue
      case "$component" in xray) cfg=xr.json ;; sing-box) cfg=sb.json ;; caddy) cfg=Caddyfile ;; esac
      [ -s "$HOME/agsbx/$cfg" ] || continue
      printf '%s # AIRGOSBX_CORE\n' "$(component_cron_line "$component")" >> "$after" || return 1
    done
  fi
  if [ "$install_required_argo" = yes ]; then
    if [ -s "$argo_token_file" ]; then
      if ! pidof systemd >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
        printf '%s\n' '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $HOME/agsbx/sbargotoken.log > $HOME/agsbx/argo.log 2>&1 &" # AIRGOSBX_ARGO' >> "$after"
      fi
    else
      valid_port "$argoport" || { rm -f "$before" "$after"; return 1; }
      printf '@reboot sleep 10 && %s/agsbx/cloudflared tunnel --url %s://%s:%s %s--edge-ip-version auto --no-autoupdate --protocol http2 > %s/agsbx/argo.log 2>&1 # AIRGOSBX_ARGO\n' \
        "$HOME" "$argoscheme" "$argo_origin_host" "$argoport" "$argoxtls" "$HOME" >> "$after"
    fi
  fi
  crontab "$after" >/dev/null 2>&1 || { rm -f "$before" "$after"; return 1; }
  rm -f "$before" "$after"
}

upxray(){
  local version="${1:-latest}" metadata tag asset stage expected actual
  [ "$version" = latest ] || { case "$version" in v*) ;; *) version="v$version" ;; esac; }
  metadata=$(release_json XTLS/Xray-core "$version") && tag=$(release_tag "$metadata") || return 1
  case "$cpu" in amd64) asset=Xray-linux-64.zip ;; arm64) asset=Xray-linux-arm64-v8a.zip ;; *) return 1 ;; esac
  stage=$(mktemp -d "$HOME/agsbx/.stage-xray.XXXXXX") || return 1
  if ! fetch_file "https://github.com/XTLS/Xray-core/releases/download/$tag/$asset" "$stage/archive.zip" \
    || ! fetch_file "https://github.com/XTLS/Xray-core/releases/download/$tag/$asset.dgst" "$stage/archive.dgst"; then
    rm -rf -- "$stage"; return 1
  fi
  expected=$(grep -iE 'sha2-256|sha256' "$stage/archive.dgst" | head -1 | awk -F= '{print $NF}' | tr -d '[:space:]' | tr A-F a-f)
  actual=$(sha256sum "$stage/archive.zip" | awk '{print $1}') || return 1
  if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || [ "$expected" != "$actual" ]; then
    rm -rf -- "$stage"; echo "错误：Xray 完整性校验失败，未替换原内核。"; return 1
  fi
  if ! unzip -o "$stage/archive.zip" xray -d "$stage" >/dev/null 2>&1 \
    || ! activate_core_candidate xray "$stage/xray"; then
    rm -rf -- "$stage"; echo "错误：Xray 候选版本未成功启用。"; return 1
  fi
  rm -rf -- "$stage"
  echo "Xray 内核已安装：$tag"
}
upsingbox(){
  local version="${1:-latest}" metadata tag asset stage expected actual
  [ "$version" = latest ] || { case "$version" in v*) ;; *) version="v$version" ;; esac; }
  metadata=$(release_json SagerNet/sing-box "$version") && tag=$(release_tag "$metadata") || return 1
  asset="sing-box-${tag#v}-linux-$cpu.tar.gz"
  expected=$(release_asset_digest "$metadata" "$asset") || {
    echo "错误：GitHub 未提供该 Sing-box 资产的 SHA256，拒绝无校验下载。"; return 1;
  }
  stage=$(mktemp -d "$HOME/agsbx/.stage-singbox.XXXXXX") || return 1
  if ! fetch_file "https://github.com/SagerNet/sing-box/releases/download/$tag/$asset" "$stage/archive.tar.gz"; then rm -rf -- "$stage"; return 1; fi
  actual=$(sha256sum "$stage/archive.tar.gz" | awk '{print $1}') || return 1
  if [ "$actual" != "$expected" ]; then rm -rf -- "$stage"; echo "错误：Sing-box SHA256 不匹配。"; return 1; fi
  if ! tar -xzf "$stage/archive.tar.gz" -C "$stage" "sing-box-${tag#v}-linux-$cpu/sing-box" \
    || ! activate_core_candidate sing-box "$stage/sing-box-${tag#v}-linux-$cpu/sing-box"; then
    rm -rf -- "$stage"; echo "错误：Sing-box 候选版本未成功启用。"; return 1
  fi
  rm -rf -- "$stage"
  echo "Sing-box 内核已安装：$tag"
}
upcaddy(){
# NaiveProxy 服务端＝带 forwardproxy@naive 分支的 Caddy。两种获取方式，按 CPU 架构与用户选择决定：
#   · 官方预编译（仅 amd64，klzgrad/forwardproxy 发布页）——1C1G 小机首选，零编译；
#   · xcaddy 现场编译（arm64 必走 / amd64 可选）——用 go.dev 官方 tarball 引导唯一标准 Go，全程自包含在暂存区。
# 预编译分支每次动态解析 GitHub Latest，不在脚本内固定或回退到旧版本号。
# 同一次 API 响应必须同时给出实际 tag、目标资产 URL 与该资产 SHA256；任一缺失都失败关闭。
local method="$naivebuild" ans
# 未显式指定获取方式时：交互终端按架构给菜单选一次；非交互(管道运行)则 amd64 默认下载、arm64 直接报错给指引。
if [ -z "$method" ]; then
  if [ -t 1 ] || [ -t 2 ]; then
    if [ "$cpu" = amd64 ]; then
      echo "请选择 NaiveProxy(Caddy) 内核获取方式："
      echo "  [1] 下载官方预编译二进制（推荐，1C1G 小机友好，零编译）"
      echo "  [2] 用 xcaddy 现场编译（需下载 Go，耗时数分钟）"
      printf "输入 1 或 2（默认 1）："; read -r ans
      case "$ans" in 2) method=build ;; *) method=dl ;; esac
    else
      echo "检测到 $cpu 架构：官方未提供预编译二进制，只能现场编译。"
      echo "  [1] 用 xcaddy 现场编译（需下载 Go，arm 性能足够，耗时数分钟）"
      echo "  [2] 放弃安装 NaiveProxy"
      printf "输入 1 或 2（默认 1）："; read -r ans
      case "$ans" in 2) echo "已跳过 NaiveProxy 安装。"; return 1 ;; *) method=build ;; esac
    fi
  else
    if [ "$cpu" = amd64 ]; then
      method=dl
    else
      echo "错误：$cpu 架构无官方预编译 Caddy(naive)，且当前为非交互环境无法选择。"
      echo "请在交互终端重试，或显式指定 naivebuild=build 启用现场编译。"
      return 1
    fi
  fi
fi
# 只接受文档公开的两种方式，避免拼写错误静默落入现场编译分支。
case "$method" in
  dl|build) ;;
  *)
    echo "错误：naivebuild 仅支持 dl 或 build，当前值为：$method"
    return 1
    ;;
esac
# arm64 没有预编译，纵使误选 dl 也强制改为 build
if [ "$method" = dl ] && [ "$cpu" != amd64 ]; then
  echo "注意：$cpu 无官方预编译，自动改为现场编译。"; method=build
fi
local cstage="$HOME/agsbx/.stage_caddy"
rm -rf "$cstage"; mkdir -p "$cstage"
if [ "$method" = dl ]; then
  local caddy_api latest_tag caddy_digest caddy_actual caddy_asset caddy_url
  caddy_asset="caddy-forwardproxy-naive.tar.xz"
  caddy_api=$( (command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 5 "https://api.github.com/repos/klzgrad/forwardproxy/releases/latest") || (command -v wget >/dev/null 2>&1 && wget -qO- --timeout=5 "https://api.github.com/repos/klzgrad/forwardproxy/releases/latest") )
  latest_tag=$(printf '%s' "$caddy_api" | grep '"tag_name":' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  caddy_url=$(printf '%s\n' "$caddy_api" | awk -v target="$caddy_asset" '
    /"name":[[:space:]]*"/ { wanted = index($0, "\"" target "\"") > 0 }
    wanted && /"browser_download_url":[[:space:]]*"/ {
      line=$0
      sub(/^.*"browser_download_url":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ')
  caddy_digest=$(printf '%s\n' "$caddy_api" | awk -v target="$caddy_asset" '
    /"name":[[:space:]]*"/ { wanted = index($0, "\"" target "\"") > 0 }
    wanted && /"digest":[[:space:]]*"sha256:/ {
      line=$0
      sub(/^.*"digest":[[:space:]]*"sha256:/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ')
  if [ -z "$latest_tag" ] || [ -z "$caddy_url" ]; then
    echo "错误：无法从 GitHub Latest API 确认当前版本及目标资产，已拒绝无来源下载。"
    rm -rf "$cstage"; return 1
  fi
  if ! printf '%s' "$caddy_digest" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "错误：当前 Latest 版本 $latest_tag 未提供资产 $caddy_asset 的有效 SHA256，已终止安装。"
    rm -rf "$cstage"; return 1
  fi
  echo "正在从 klzgrad/forwardproxy 官方发布页下载最新版预编译 Caddy(naive)：$latest_tag ……"
  local url="$caddy_url"
  local tmp="$cstage/caddy.tar.xz"
  (command -v curl >/dev/null 2>&1 && curl -fLo "$tmp" -# --retry 2 "$url") || (command -v wget >/dev/null 2>&1 && wget -O "$tmp" --tries=2 "$url")
  if [ ! -s "$tmp" ]; then echo "错误：Caddy 最新版下载失败（网络不可达或 Latest 发布缺少对应资源）。"; rm -rf "$cstage"; return 1; fi
  # SHA256 必须来自同一 Latest API 响应中、名称精确匹配的目标资产；取不到时已在下载前失败关闭。
  caddy_actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
  if [ "$caddy_digest" != "$caddy_actual" ]; then
    echo "错误：Caddy 文件 SHA256 校验失败！下载可能已被篡改或资源损坏，终止安装。"
    echo "预期: $caddy_digest"
    echo "实际: $caddy_actual"
    rm -rf "$cstage"; return 1
  fi
  echo "SHA256 校验通过 ✓ ($caddy_actual)"
  printf 'source=github-release\ntag=%s\nasset=%s\nsha256=%s\n' \
    "$latest_tag" "$caddy_asset" "$caddy_digest" > "$cstage/caddy-build-info"
  # .tar.xz 解压：优先 GNU tar -J，缺则用 xz 管道兜底（兼容 busybox tar）。xz 已在 ensure_deps 中预置。
  if ! ( tar -xJf "$tmp" -C "$cstage" 2>/dev/null || ( xz -dc "$tmp" 2>/dev/null | tar -xf - -C "$cstage" 2>/dev/null ) ); then
    echo "错误：解压失败，可能缺少 xz 工具。请确认已安装 xz/xz-utils 后重试。"; rm -rf "$cstage"; return 1
  fi
else
  echo "正在引导 Go 工具链并用 xcaddy 编译 Caddy(naive)（下载约 150MB、耗时数分钟、建议 ≥1G 内存）……"
  local go_version_text gover go_meta go_file go_sha go_actual gotar
  go_version_text=$( (command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 10 --retry 2 "https://go.dev/VERSION?m=text") || (command -v wget >/dev/null 2>&1 && wget -qO- --timeout=10 --tries=2 "https://go.dev/VERSION?m=text") )
  gover=$(printf '%s\n' "$go_version_text" | head -1)
  if [[ ! "$gover" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?((beta|rc)[0-9]+)?$ ]]; then
    echo "错误：go.dev 未返回有效的 Go 版本号：${gover:-空值}"
    rm -rf "$cstage"; return 1
  fi
  go_file="${gover}.linux-${cpu}.tar.gz"
  go_meta=$( (command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 10 --retry 2 "https://go.dev/dl/?mode=json") || (command -v wget >/dev/null 2>&1 && wget -qO- --timeout=10 --tries=2 "https://go.dev/dl/?mode=json") )
  if [ -z "$go_meta" ]; then echo "错误：无法从 go.dev 获取 Go 下载校验信息。"; rm -rf "$cstage"; return 1; fi
  # 官方 JSON 中 filename 与 sha256 位于同一文件对象内；只提取当前版本、Linux、当前 CPU 对应归档的哈希。
  go_sha=$(printf '%s\n' "$go_meta" | awk -v target="$go_file" '
    index($0, target) && /"filename"/ { found=1 }
    found && /"sha256"/ {
      line=$0
      sub(/^.*"sha256":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
    found && /"filename"/ && !index($0, target) { exit }
  ')
  if [[ ! "$go_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "错误：go.dev 未返回 $go_file 的有效 SHA256，已拒绝下载未验证的 Go 工具链。"
    rm -rf "$cstage"; return 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "错误：系统缺少 sha256sum，无法安全校验 Go 工具链。"
    rm -rf "$cstage"; return 1
  fi
  gotar="$cstage/$go_file"
  echo "下载 Go 官方 tarball：$go_file ……"
  if ! ( (command -v curl >/dev/null 2>&1 && curl -fLo "$gotar" -# --connect-timeout 10 --retry 2 "https://go.dev/dl/$go_file") || (command -v wget >/dev/null 2>&1 && wget -O "$gotar" --timeout=10 --tries=2 "https://go.dev/dl/$go_file") ); then
    echo "错误：Go 官方 tarball 下载失败。"; rm -rf "$cstage"; return 1
  fi
  go_actual=$(sha256sum "$gotar" 2>/dev/null | awk '{print $1}')
  if [ "$go_actual" != "$go_sha" ]; then
    echo "错误：Go 工具链 SHA256 校验失败，下载可能损坏或被篡改，已终止编译。"
    echo "预期: $go_sha"
    echo "实际: ${go_actual:-无法计算}"
    rm -rf "$cstage"; return 1
  fi
  echo "Go 工具链 SHA256 校验通过 ✓ ($go_actual)"
  if ! tar -xzf "$gotar" -C "$cstage" 2>/dev/null; then
    echo "错误：Go 工具链解压失败。"; rm -rf "$cstage"; return 1
  fi
  if [ ! -x "$cstage/go/bin/go" ]; then echo "错误：Go 解压失败。"; rm -rf "$cstage"; return 1; fi
  # Go、xcaddy、模块/构建缓存、临时 HOME 与临时文件全部关在 cstage 子 shell；
  # 禁用继承的 Go/xcaddy 定制项，强制官方模块代理与校验数据库，失败时不作不安全降级。
  if ! mkdir -p "$cstage/home" "$cstage/gopath" "$cstage/gobin" "$cstage/gocache" "$cstage/gomodcache" "$cstage/gotmp" "$cstage/tmp" "$cstage/xdg_cache" "$cstage/xdg_config"; then
    echo "错误：无法创建隔离的 Caddy 编译目录。"; rm -rf "$cstage"; return 1
  fi
  if ! (
         unset GOBIN GOCACHE GOMODCACHE GOTMPDIR GOENV GOWORK GOPROXY GOSUMDB GOPRIVATE GONOPROXY GONOSUMDB GOINSECURE GOFLAGS GOAUTH GOEXPERIMENT GODEBUG GOVCS
         unset GOOS GOARCH GOAMD64 GO386 GOARM GOARM64 GOMIPS GOMIPS64 GOPPC64 GORISCV64
         unset CADDY_VERSION XCADDY_WHICH_GO XCADDY_GO_BUILD_FLAGS XCADDY_GO_MOD_FLAGS XCADDY_RACE_DETECTOR XCADDY_DEBUG XCADDY_SKIP_BUILD XCADDY_SETCAP
         unset GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS SSH_ASKPASS GIT_PROXY_COMMAND
         export HOME="$cstage/home"
         export GOROOT="$cstage/go" GOPATH="$cstage/gopath" GOBIN="$cstage/gobin"
         export GOCACHE="$cstage/gocache" GOMODCACHE="$cstage/gomodcache" GOTMPDIR="$cstage/gotmp" TMPDIR="$cstage/tmp"
         export XDG_CACHE_HOME="$cstage/xdg_cache" XDG_CONFIG_HOME="$cstage/xdg_config"
         export GOENV=off GOWORK=off GO111MODULE=on GOTOOLCHAIN=local
         export GOPROXY="https://proxy.golang.org,direct" GOSUMDB="sum.golang.org"
         export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
         export PATH="$GOROOT/bin:$GOBIN:/usr/sbin:/usr/bin:/sbin:/bin"
         echo "Go 就绪：$("$GOROOT/bin/go" version 2>/dev/null)"
         caddy_version=$("$GOROOT/bin/go" list -m -f '{{.Version}}' github.com/caddyserver/caddy/v2@latest) &&
         xcaddy_version=$("$GOROOT/bin/go" list -m -f '{{.Version}}' github.com/caddyserver/xcaddy@latest) &&
         forwardproxy_api=$( (command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 5 "https://api.github.com/repos/klzgrad/forwardproxy/branches/naive") || (command -v wget >/dev/null 2>&1 && wget -qO- --timeout=5 "https://api.github.com/repos/klzgrad/forwardproxy/branches/naive") ) &&
         forwardproxy_commit=$(printf '%s\n' "$forwardproxy_api" | grep '"sha":' | head -1 | sed -E 's/.*"sha": *"([0-9a-f]+)".*/\1/') &&
         [ -n "$caddy_version" ] && [ -n "$xcaddy_version" ] && printf '%s' "$forwardproxy_commit" | grep -Eq '^[0-9a-f]{40}$' &&
         echo "安装当前最新版 xcaddy 构建器：$xcaddy_version ……" &&
         "$GOROOT/bin/go" install github.com/caddyserver/xcaddy/cmd/xcaddy@"$xcaddy_version" &&
         echo "编译当前最新版 Caddy $caddy_version + forwardproxy naive@$forwardproxy_commit（请耐心等待）……" &&
         cd "$cstage" &&
         "$GOBIN/xcaddy" build "$caddy_version" --output "$cstage/caddy" --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@"$forwardproxy_commit" &&
         printf 'source=xcaddy-build\ncaddy=%s\nxcaddy=%s\nforwardproxy=%s\n' \
           "$caddy_version" "$xcaddy_version" "$forwardproxy_commit" > "$cstage/caddy-build-info"
       ); then
    echo "错误：Go/xcaddy 编译失败（可看上方报错；网络或内存不足是常见原因）。"; rm -rf "$cstage"; return 1
  fi
fi
# 定位产物：下载包内为 caddy，编译产物在 cstage/caddy
local newcaddy="$cstage/caddy"
[ -f "$newcaddy" ] || newcaddy=$(find "$cstage" -maxdepth 2 -type f -name caddy 2>/dev/null | head -1)
if [ ! -s "$newcaddy" ]; then echo "错误：未找到 caddy 可执行文件。"; rm -rf "$cstage"; return 1; fi
chmod +x "$newcaddy"
# 功能性硬校验：version 验证架构/文件可执行性，list-modules 精确确认 NaiveProxy 必需模块。
# 任一校验失败均丢弃暂存产物，绝不把普通 Caddy 或损坏内核安装到正式路径。
echo "正在对 Caddy(naive) 内核进行可执行性与功能组件校验……"
if ! "$newcaddy" version >/dev/null 2>&1; then echo "错误：caddy 不可执行（架构不符或文件损坏）。"; rm -rf "$cstage"; return 1; fi
if "$newcaddy" list-modules 2>/dev/null | grep -qx 'http.handlers.forward_proxy'; then
  if [ "$method" = dl ]; then
    echo "forward_proxy 模块校验通过 ✓（官方预编译内核已包含 NaiveProxy 插件）"
  else
    echo "forward_proxy 模块校验通过 ✓（Caddy + forwardproxy@naive 编译产物完整）"
  fi
else
  if [ "$method" = dl ]; then
    echo "错误：官方预编译 Caddy 中未检出 forward_proxy 模块，已拒绝安装。"
  else
    echo "错误：自行编译的 Caddy 中未检出 forward_proxy 模块，编译产物无效，已拒绝安装。"
  fi
  rm -rf "$cstage"; return 1
fi

activate_core_candidate caddy "$newcaddy" || { rm -rf -- "$cstage"; return 1; }
[ -s "$cstage/caddy-build-info" ] && mv -f "$cstage/caddy-build-info" "$HOME/agsbx/caddy_build_info"
rm -rf "$cstage"
if [ "$method" = dl ]; then
  echo "已安装 Caddy(naive) 官方预编译内核：$("$HOME/agsbx/caddy" version 2>/dev/null | head -1)"
else
  echo "已安装 VPS 自行编译的 Caddy(naive) 内核：$("$HOME/agsbx/caddy" version 2>/dev/null | head -1)"
fi
}
#============================================================
# [第6段] UUID 生成 + 协议配置生成函数
#   insuuid()     - 生成或读取 UUID
#   installxray() - 生成 Xray 的 inbound 配置（xr.json）
#   installsb()   - 生成 Sing-box 的 inbound 配置（sb.json）
#============================================================
atomic_text_file(){
  local target="$1" content="$2" temporary
  [ ! -L "$target" ] && { [ ! -e "$target" ] || [ -f "$target" ]; } || return 1
  temporary=$(mktemp "${target%/*}/.agsbx-text.XXXXXX") || return 1
  if ! printf '%s' "$content" > "$temporary" || ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"; return 1
  fi
}

prepare_transport_paths(){
  local profile flag value prepared=no
  for profile in xh vx vw vm xvd xva; do
    case "$profile" in xh) flag="$xhp" ;; vx) flag="$vxp" ;; vw) flag="$vwp" ;; vm) flag="$vmp" ;; xvd) flag="$xvcdn" ;; xva) flag="$xvargo" ;; esac
    [ "$flag" = yes ] || continue
    value="/$(openssl rand -hex 16)" || return 1
    [[ "$value" =~ ^/[0-9a-f]{32}$ ]] || return 1
    atomic_text_file "$HOME/agsbx/transport_$profile" "$value" || return 1
    prepared=yes
  done
  if [ "$prepared" = yes ]; then atomic_text_file "$HOME/agsbx/transport_paths_version" 1 || return 1; fi
  return 0
}

transport_path(){
  local profile="$1" value
  case "$profile" in xh|vx|vw|vm|xvd|xva) ;; *) return 1 ;; esac
  if [ -e "$HOME/agsbx/transport_$profile" ]; then
    value=$(cat "$HOME/agsbx/transport_$profile") || return 1
    [[ "$value" =~ ^/[0-9a-f]{32}$ ]] || return 1
  else
    [ ! -e "$HOME/agsbx/transport_paths_version" ] || { echo "错误：新部署缺少传输路径状态。" >&2; return 1; }
    # 旧部署只用于展示；其历史路径仍须与正在运行的配置一致。
    value="/$uuid-$profile"
  fi
  printf '%s' "$value"
}

inssockscred(){
  socks_user="agsbx-$(openssl rand -hex 8)" && socks_pass=$(openssl rand -hex 32) || return 1
  [[ "$socks_user" =~ ^agsbx-[0-9a-f]{16}$ ]] && [[ "$socks_pass" =~ ^[0-9a-f]{64}$ ]] || return 1
  atomic_text_file "$HOME/agsbx/socks_user" "$socks_user" \
    && atomic_text_file "$HOME/agsbx/socks_pass" "$socks_pass" \
    && atomic_text_file "$HOME/agsbx/socks_credentials_version" 2
}

load_socks_credentials(){
  if [ -e "$HOME/agsbx/socks_credentials_version" ]; then
    [ "$(cat "$HOME/agsbx/socks_credentials_version")" = 2 ] || return 1
    socks_user=$(cat "$HOME/agsbx/socks_user") && socks_pass=$(cat "$HOME/agsbx/socks_pass") || return 1
    [ -n "$socks_user" ] && [ -n "$socks_pass" ] || return 1
  else
    socks_user="$uuid"; socks_pass="$uuid"
  fi
  valid_plain_text "$socks_user" 255 && valid_plain_text "$socks_pass" 255
}

vmess_payload(){
  printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s","fp":"chrome"}' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$(json_escape "$uuid")" \
    "$(json_escape "$4")" "$(json_escape "$5")" "$(json_escape "$6")" "$(json_escape "$7")" | safe_base64
}

append_node_link(){
  [ -n "$1" ] || return 1
  node_links="${node_links}$1"$'\n'
}

publish_node_outputs(){
  local stage token="$subtoken"
  if [ "$sub" = yes ]; then
    subscription_certificate_host >/dev/null || return 1
    [[ "$token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || return 1
    stage=$(mktemp -d "$HOME/agsbx/.subscription.XXXXXX") || return 1
    mkdir -m 700 "$stage/$token" || { rm -rf -- "$stage"; return 1; }
    printf '%s\n' AIRGOSBX_SUBSCRIPTION_V1 > "$stage/.airgosbx-subscription" \
      && printf '%s' "$node_links" > "$stage/$token/jhsub.txt" || { rm -rf -- "$stage"; return 1; }
    if [ -n "$clash_config" ]; then printf '%s\n' "$clash_config" > "$stage/$token/clmi.yaml" || { rm -rf -- "$stage"; return 1; }; fi
    # 只在安装/rep 事务中发布；目录整体替换，同时撤销旧令牌和旧文件。
    if ! stop_subscription_http || ! remove_subscription_tree || ! mv -- "$stage" "$HOME/websbx"; then
      rm -rf -- "$stage"; return 1
    fi
    start_subscription_http "$subport_real" && write_subscription_http_autostart "$subport_real" yes || return 1
    verify_subscription_https "$token" || return 1
    atomic_text_file "$HOME/agsbx/subtoken.log" "$token" || return 1
  fi
  atomic_text_file "$HOME/agsbx/jh.txt" "$node_links" || return 1
  if [ -n "$clash_config" ]; then atomic_text_file "$HOME/agsbx/clmi.yaml" "$clash_config" || return 1
  else rm -f -- "$HOME/agsbx/clmi.yaml" || return 1; fi
}

insuuid(){
if [ -z "$uuid" ] && [ ! -e "$HOME/agsbx/uuid" ]; then
if [ -e "$HOME/agsbx/sing-box" ]; then
uuid=$("$HOME/agsbx/sing-box" generate uuid)
else
uuid=$("$HOME/agsbx/xray" uuid)
fi
echo "$uuid" > "$HOME/agsbx/uuid"
elif [ -n "$uuid" ]; then
echo "$uuid" > "$HOME/agsbx/uuid"
fi
uuid=$(cat "$HOME/agsbx/uuid") || return 1
[ -n "$uuid" ] && valid_plain_text "$uuid" 256 || { echo "错误：UUID/密码状态无效。"; return 1; }
echo "协议凭据已保存。"
}

insobfspass(){
if [ -z "$obfs_pass" ] && [ ! -e "$HOME/agsbx/obfs_pass" ]; then
  obfs_pass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  echo "$obfs_pass" > "$HOME/agsbx/obfs_pass"
elif [ -n "$obfs_pass" ]; then
  echo "$obfs_pass" > "$HOME/agsbx/obfs_pass"
fi
obfs_pass=$(cat "$HOME/agsbx/obfs_pass")
echo "Hysteria2 混淆密码：$obfs_pass"
}

insnaivecred(){
# NaiveProxy 凭据：用户名 + 密码。支持环境变量预设、终端交互设置（可自选用户名、密码回车随机）与幂等复用。
# 交互模式判别使用标准输出/错误 [ -t 1 ] || [ -t 2 ] 以兼容一键拉取管道代换场景
local can_prompt=0
if [ -t 1 ] || [ -t 2 ]; then can_prompt=1; fi

if [ -n "$naiveuser" ]; then
  echo "$naiveuser" > "$HOME/agsbx/naive_user"
elif [ ! -e "$HOME/agsbx/naive_user" ]; then
  if [ "$can_prompt" = 1 ]; then
    printf "请输入 NaiveProxy 用户名（直接回车=自动随机生成）："; read -r naiveuser
  fi
  if [ -z "$naiveuser" ]; then
    # 自动生成 20 位随机规范用户名
    naiveuser=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20)
  fi
  echo "$naiveuser" > "$HOME/agsbx/naive_user"
fi
naiveuser=$(cat "$HOME/agsbx/naive_user")

if [ -n "$naivepass" ]; then
  echo "$naivepass" > "$HOME/agsbx/naive_pass"
elif [ ! -e "$HOME/agsbx/naive_pass" ]; then
  if [ "$can_prompt" = 1 ]; then
    printf "请输入 NaiveProxy 密码（直接回车=自动随机生成）："; read -r naivepass
  fi
  if [ -z "$naivepass" ]; then
    # 自动生成 20 位随机规范密码，兼顾防爆破强度与 URL 分享链接兼容性
    naivepass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20)
  fi
  echo "$naivepass" > "$HOME/agsbx/naive_pass"
fi
naivepass=$(cat "$HOME/agsbx/naive_pass")
echo "NaiveProxy 账号：$naiveuser"
echo "NaiveProxy 密码：$naivepass"
}
fetch_file(){
  local fetch_url="$1" fetch_out="$2"
  case "$fetch_url" in https://*) ;; *) echo "错误：下载地址必须使用 HTTPS。" >&2; return 1 ;; esac
  if command -v curl >/dev/null 2>&1; then
    curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 600 --retry 2 -o "$fetch_out" "$fetch_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$fetch_out" --timeout=30 --tries=2 "$fetch_url"
  else return 1; fi
}
valid_domain(){
printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9][A-Za-z0-9.-]*$' || return 1
printf '%s' "$1" | grep -Eq '(^-|-$|\.\.|\.-|-\.)' && return 1
return 0
}
is_yes(){
case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
  y|yes|1|true) return 0 ;;
  *) return 1 ;;
esac
}
valid_ipv4(){
local ip="$1" part
local -a parts
IFS='.' read -r -a parts <<< "$ip"
[ "${#parts[@]}" -eq 4 ] || return 1
for part in "${parts[@]}"; do
  case "$part" in ''|*[!0-9]*) return 1 ;; esac
  [ "$part" -le 255 ] 2>/dev/null || return 1
done
return 0
}
valid_ipv6(){
local ip="$1" group compact
local -a groups
case "$ip" in
  *[!0-9A-Fa-f:]*) return 1 ;;
  *:*) ;;
  *) return 1 ;;
esac
case "$ip" in *:::*) return 1 ;; esac
case "$ip" in *::*::*) return 1 ;; esac
compact=no
case "$ip" in *::*) compact=yes ;; esac
IFS=':' read -r -a groups <<< "$ip"
if [ "$compact" = yes ]; then
  [ "${#groups[@]}" -le 7 ] || return 1
else
  [ "${#groups[@]}" -eq 8 ] || return 1
fi
for group in "${groups[@]}"; do
  [ -z "$group" ] && continue
  [ "${#group}" -le 4 ] || return 1
done
return 0
}
valid_ip(){ valid_ipv4 "$1" || valid_ipv6 "$1"; }

#============================================================
# Airgosbx 系统 IP 栈策略
# - 只保存 Airgosbx 将要改动的原值，不执行 source，避免状态文件变成代码入口。
# - 非空 ipv 负责应用策略；曾应用策略后取消 ipv，或卸载脚本时，恢复 VPS 原状态。
#============================================================
ip_policy_dir="$HOME/agsbx/ip_policy"
ip_policy_marker='AIRGOSBX_IP_POLICY_V1'
ip_policy_sysctl_file='/etc/sysctl.d/99-agsbx-ip-policy.conf'
ip_policy_gai_file='/etc/gai.conf'
ip_policy_gai_begin='# BEGIN AIRGOSBX IP POLICY'
ip_policy_gai_end='# END AIRGOSBX IP POLICY'
effective_ipv_mode=''
public_listen_address='::'
mita_dns_policy='USE_FIRST_IP'

ip_policy_atomic_write(){
  local target="$1" mode="$2" parent tmp
  [ ! -L "$target" ] || { echo "错误：拒绝写入符号链接：$target"; return 1; }
  parent=$(dirname "$target")
  [ -d "$parent" ] && [ ! -L "$parent" ] || { echo "错误：策略目录异常：$parent"; return 1; }
  tmp=$(mktemp "$parent/.agsbx-ip-policy.XXXXXX") || return 1
  if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}

ip_policy_state_write(){
  local key="$1" value="$2" target
  case "$key" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  target="$ip_policy_dir/$key"
  printf '%s\n' "$value" | ip_policy_atomic_write "$target" 600
}

ip_policy_state_read(){
  local key="$1" target="$ip_policy_dir/$1"
  case "$key" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  cat "$target"
}

ip_policy_prepare_state(){
  if [ -L "$ip_policy_dir" ]; then
    echo "错误：IP 策略状态目录不能是符号链接：$ip_policy_dir"
    return 1
  fi
  if [ ! -d "$ip_policy_dir" ]; then
    mkdir -m 700 "$ip_policy_dir" || return 1
  fi
  chmod 700 "$ip_policy_dir" || return 1
  if [ -e "$ip_policy_dir/marker" ]; then
    [ -f "$ip_policy_dir/marker" ] && [ ! -L "$ip_policy_dir/marker" ] \
      && [ "$(cat "$ip_policy_dir/marker" 2>/dev/null)" = "$ip_policy_marker" ] \
      || { echo "错误：IP 策略状态标记损坏。"; return 1; }
  else
    if find "$ip_policy_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      echo "错误：拒绝接管非 Airgosbx 创建的 IP 策略目录。"
      return 1
    fi
    ip_policy_state_write marker "$ip_policy_marker" || return 1
  fi
}

ip_policy_configure_runtime(){
  effective_ipv_mode="$1"
  public_listen_address='::'
  mita_dns_policy='USE_FIRST_IP'
  ip_policy_xray_strategy=''
  ip_policy_sing_strategy=''
  ip_policy_preferred_family=4
  case "$effective_ipv_mode" in
    4) public_listen_address='0.0.0.0'; mita_dns_policy='ONLY_IPv4'; ip_policy_xray_strategy='ForceIPv4'; ip_policy_sing_strategy='ipv4_only' ;;
    6) mita_dns_policy='ONLY_IPv6'; ip_policy_xray_strategy='ForceIPv6'; ip_policy_sing_strategy='ipv6_only'; ip_policy_preferred_family=6 ;;
    '4;6') mita_dns_policy='PREFER_IPv4'; ip_policy_xray_strategy='ForceIPv4v6'; ip_policy_sing_strategy='prefer_ipv4' ;;
    '6;4') mita_dns_policy='PREFER_IPv6'; ip_policy_xray_strategy='ForceIPv6v4'; ip_policy_sing_strategy='prefer_ipv6'; ip_policy_preferred_family=6 ;;
    '') ;;
    *) echo "错误：磁盘上的 Airgosbx IP 策略值无效。"; return 1 ;;
  esac
}

ip_policy_load_runtime(){
  local saved_mode
  if [ ! -e "$ip_policy_dir" ]; then
    ip_policy_configure_runtime ''
    return
  fi
  [ -d "$ip_policy_dir" ] && [ ! -L "$ip_policy_dir" ] \
    || { echo "错误：IP 策略状态目录类型异常。"; return 1; }
  [ "$(ip_policy_state_read marker 2>/dev/null)" = "$ip_policy_marker" ] \
    || { echo "错误：IP 策略状态标记缺失或损坏。"; return 1; }
  saved_mode=$(ip_policy_state_read mode 2>/dev/null) \
    || { echo "错误：IP 策略状态不完整，缺少当前模式。"; return 1; }
  case "$saved_mode" in 4|6|'4;6'|'6;4') ;; *) echo "错误：已保存的 ipv 模式无效。"; return 1 ;; esac
  ip_policy_configure_runtime "$saved_mode"
}

ip_policy_remove_state(){
  [ -d "$ip_policy_dir" ] && [ ! -L "$ip_policy_dir" ] \
    && [ "$(ip_policy_state_read marker 2>/dev/null)" = "$ip_policy_marker" ] \
    || { echo "错误：拒绝删除异常的 IP 策略状态目录。"; return 1; }
  rm -rf -- "$ip_policy_dir"
}

reset_v4v6_probe(){
  v4v6_probed=''
  v4=''; v6=''; v4dq=''; v6dq=''
}

ip_family_topology(){
  local family="$1" devices count dev
  devices=$(ip "-$family" route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev" && (i+1)<=NF) print $(i+1)}' | sort -u)
  count=$(printf '%s\n' "$devices" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$count" in
    0) printf '%s' no; return ;;
    1) dev=$(printf '%s\n' "$devices" | sed -n '1p') ;;
    *) printf '%s' unknown; return ;;
  esac
  case "$dev" in lo|wg*|warp*|tun*|tap*|tailscale*|docker*|br-*|veth*|virbr*|zt*) printf '%s' unknown; return ;; esac
  if ip "-$family" -o address show dev "$dev" scope global 2>/dev/null \
      | grep -Ev ' tentative| dadfailed' | grep -q .; then
    printf '%s' yes
  else
    printf '%s' no
  fi
}

probe_ip_capabilities(){
  local top4 top6
  reset_v4v6_probe
  v4v6
  top4=$(ip_family_topology 4)
  top6=$(ip_family_topology 6)
  case "$top4:${v4:+yes}" in yes:yes) ipv4_capability=yes ;; no:) ipv4_capability=no ;; *) ipv4_capability=unknown ;; esac
  case "$top6:${v6:+yes}" in yes:yes) ipv6_capability=yes ;; no:) ipv6_capability=no ;; *) ipv6_capability=unknown ;; esac
}

ip_policy_guard_session(){
  local disabled_family="$1" ssh_server ancestor_pid ancestor_name depth=0
  if [ -n "${SSH_CONNECTION:-}" ]; then
    ssh_server=$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $3}')
    if { [ "$disabled_family" = 4 ] && valid_ipv4 "$ssh_server"; } \
      || { [ "$disabled_family" = 6 ] && valid_ipv6 "$ssh_server"; }; then
      echo "错误：当前 SSH 正使用即将关闭的 IPv${disabled_family}，请先用目标协议族重新连接。"
      return 1
    fi
    valid_ip "$ssh_server" || { echo "错误：无法确认当前 SSH 使用的协议族，已停止切换。"; return 1; }
  else
    ancestor_pid=$PPID
    while [ "$ancestor_pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 12 ]; do
      ancestor_name=$(cat "/proc/$ancestor_pid/comm" 2>/dev/null)
      case "$ancestor_name" in sshd*) echo "错误：检测到 SSH 父进程但无法确认会话协议族，请从目标协议族 SSH 或云控制台执行。"; return 1 ;; esac
      ancestor_pid=$(awk '{print $4}' "/proc/$ancestor_pid/stat" 2>/dev/null)
      case "$ancestor_pid" in ''|*[!0-9]*) break ;; esac
      depth=$((depth + 1))
    done
    if [ ! -t 0 ] && [ ! -t 1 ] && [ ! -t 2 ]; then
      echo "错误：没有 SSH 会话信息时，单栈切换只允许从交互式本地或云控制台执行。"
      return 1
    fi
  fi
}

ip_policy_sysctl_owned(){
  [ -f "$ip_policy_sysctl_file" ] && [ ! -L "$ip_policy_sysctl_file" ] \
    && awk '
      NR == 1 {ok = ($0 == "# Airgosbx managed IP policy")}
      NR == 2 {ok = ok && ($0 == "net.ipv6.conf.all.disable_ipv6 = 1")}
      NR == 3 {ok = ok && ($0 == "net.ipv6.conf.default.disable_ipv6 = 1")}
      NR == 4 {ok = ok && ($0 == "net.ipv6.conf.lo.disable_ipv6 = 1")}
      NR == 5 {ok = ok && ($0 == "# End Airgosbx managed IP policy")}
      END {exit !(ok && NR == 5)}
    ' "$ip_policy_sysctl_file"
}

ip_policy_save_sysctl(){
  local key value interface index table records=''
  if [ -e "$ip_policy_dir/sysctl_saved" ]; then
    [ "$(ip_policy_state_read sysctl_saved 2>/dev/null)" = yes ] && [ -s "$ip_policy_dir/sysctl_interfaces" ]
    return $?
  fi
  [ ! -e "$ip_policy_sysctl_file" ] && [ ! -L "$ip_policy_sysctl_file" ] || {
    echo "错误：IP sysctl 文件已存在且没有对应快照。"; return 1;
  }
  for key in all default lo; do
    value=$(sysctl -n "net.ipv6.conf.$key.disable_ipv6" 2>/dev/null) || return 1
    case "$value" in 0|1) ;; *) return 1 ;; esac
    ip_policy_state_write "sysctl_$key" "$value" || return 1
  done
  for table in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    interface=${table%/disable_ipv6}; interface=${interface##*/}
    case "$interface" in all|default) continue ;; *[!A-Za-z0-9_.:-]*) return 1 ;; esac
    value=$(cat "$table") && index=$(cat "/sys/class/net/$interface/ifindex") || return 1
    case "$value:$index" in [01]:*) ;; *) return 1 ;; esac
    records="${records}$interface $index $value
"
  done
  [ -n "$records" ] || return 1
  ip_policy_state_write sysctl_interfaces "$records" || return 1
  ip -6 address save > "$ip_policy_dir/ipv6_addresses.save" \
    && ip -6 route save table all > "$ip_policy_dir/ipv6_routes.save" || return 1
  ip_policy_state_write sysctl_saved yes
}

ip_policy_apply_ipv4_only_sysctl(){
  ip_policy_prepare_state || return 1
  ip_policy_save_sysctl || return 1
  if [ -e "$ip_policy_sysctl_file" ] && ! ip_policy_sysctl_owned; then
    echo "错误：拒绝覆盖非 Airgosbx 管理的 sysctl 文件。"
    return 1
  fi
  {
    echo '# Airgosbx managed IP policy'
    echo 'net.ipv6.conf.all.disable_ipv6 = 1'
    echo 'net.ipv6.conf.default.disable_ipv6 = 1'
    echo 'net.ipv6.conf.lo.disable_ipv6 = 1'
    echo '# End Airgosbx managed IP policy'
  } | ip_policy_atomic_write "$ip_policy_sysctl_file" 600 || return 1
  sysctl -p "$ip_policy_sysctl_file" >/dev/null 2>&1 || return 1
  [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = 1 ] \
    && [ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" = 1 ] \
    && [ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)" = 1 ]
}

ip_policy_restore_sysctl(){
  local all_value default_value interface index value current_index
  [ -e "$ip_policy_dir/sysctl_saved" ] || return 0
  [ "$(ip_policy_state_read sysctl_saved 2>/dev/null)" = yes ] || return 1
  if [ ! -s "$ip_policy_dir/sysctl_interfaces" ] || [ ! -f "$ip_policy_dir/ipv6_addresses.save" ] || [ ! -f "$ip_policy_dir/ipv6_routes.save" ]; then
    echo "错误：旧 IPv6 快照不含接口与地址记录，无法声称完整恢复；已保留原值供人工核对。"
    return 1
  fi
  all_value=$(ip_policy_state_read sysctl_all) && default_value=$(ip_policy_state_read sysctl_default) || return 1
  case "$all_value:$default_value" in [01]:[01]) ;; *) return 1 ;; esac
  if [ -e "$ip_policy_sysctl_file" ] || [ -L "$ip_policy_sysctl_file" ]; then
    ip_policy_sysctl_owned || { echo "错误：sysctl 文件被外部修改，拒绝覆盖。"; return 1; }
  fi
  while read -r interface index value; do
    [ -n "$interface" ] || continue
    case "$interface" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
    case "$value" in 0|1) ;; *) return 1 ;; esac
    current_index=$(cat "/sys/class/net/$interface/ifindex" 2>/dev/null) || return 1
    [ "$index" = "$current_index" ] || { echo "错误：接口标识已变化，保留 IPv6 恢复记录。"; return 1; }
  done < "$ip_policy_dir/sysctl_interfaces"
  # all 会覆盖所有接口与 default，必须先写，再恢复各自的原值。
  sysctl -w "net.ipv6.conf.all.disable_ipv6=$all_value" >/dev/null 2>&1 \
    && sysctl -w "net.ipv6.conf.default.disable_ipv6=$default_value" >/dev/null 2>&1 || return 1
  while read -r interface index value; do
    [ -n "$interface" ] || continue
    printf '%s\n' "$value" > "/proc/sys/net/ipv6/conf/$interface/disable_ipv6" || return 1
  done < "$ip_policy_dir/sysctl_interfaces"
  ip -6 address restore < "$ip_policy_dir/ipv6_addresses.save" \
    && ip -6 route restore < "$ip_policy_dir/ipv6_routes.save" || return 1
  if [ -e "$ip_policy_sysctl_file" ]; then rm -f -- "$ip_policy_sysctl_file" || return 1; fi
  return 0
}

ip_policy_gai_markers_valid(){
  [ ! -L "$ip_policy_gai_file" ] || return 1
  [ -e "$ip_policy_gai_file" ] || return 0
  [ -f "$ip_policy_gai_file" ] || return 1
  awk -v begin="$ip_policy_gai_begin" -v end="$ip_policy_gai_end" '
    $0 == begin {if (opened || closed) bad=1; opened=1; begins++; next}
    $0 == end {if (!opened || closed) bad=1; closed=1; ends++; next}
    END {
      if (bad) exit 1
      if (begins == 0 && ends == 0) exit 0
      exit !(begins == 1 && ends == 1 && opened && closed)
    }
  ' "$ip_policy_gai_file"
}

ip_policy_gai_has_external_precedence(){
  [ -f "$ip_policy_gai_file" ] || return 1
  awk -v begin="$ip_policy_gai_begin" -v end="$ip_policy_gai_end" '
    $0 == begin {managed=1; next}
    $0 == end {managed=0; next}
    !managed {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      if (line !~ /^#/ && line ~ /^precedence[[:space:]]+/) found=1
    }
    END {exit !found}
  ' "$ip_policy_gai_file"
}

ip_policy_strip_gai_block(){
  awk -v begin="$ip_policy_gai_begin" -v end="$ip_policy_gai_end" '
    $0 == begin {managed=1; next}
    $0 == end {managed=0; next}
    !managed {print}
  ' "$ip_policy_gai_file"
}

ip_policy_apply_precedence(){
  local mode="$1" mapped_precedence created=no managed_begin_count=0
  getconf GNU_LIBC_VERSION 2>/dev/null | grep -q '^glibc ' \
    || { echo "错误：双栈优先级只支持 glibc 系统。"; return 1; }
  ip_policy_gai_markers_valid || { echo "错误：/etc/gai.conf 类型或 Airgosbx 标记异常。"; return 1; }
  if ip_policy_gai_has_external_precedence; then
    echo "错误：/etc/gai.conf 已有管理员 precedence 规则，Airgosbx 不会覆盖。"
    return 1
  fi
  if [ -f "$ip_policy_gai_file" ]; then
    managed_begin_count=$(grep -Fxc "$ip_policy_gai_begin" "$ip_policy_gai_file" 2>/dev/null || true)
    if [ "$managed_begin_count" != 0 ] && [ ! -e "$ip_policy_dir/gai_touched" ]; then
      echo "错误：gai.conf 已有同名 Airgosbx 标记，但缺少原状态记录，拒绝接管。"
      return 1
    fi
  fi
  [ -e "$ip_policy_gai_file" ] || created=yes
  case "$mode" in '4;6') mapped_precedence=100 ;; '6;4') mapped_precedence=10 ;; *) return 1 ;; esac
  ip_policy_prepare_state || return 1
  if [ ! -e "$ip_policy_dir/gai_touched" ]; then
    ip_policy_state_write gai_created "$created" || return 1
    ip_policy_state_write gai_touched yes || return 1
  fi
  {
    [ -f "$ip_policy_gai_file" ] && ip_policy_strip_gai_block
    printf '%s\n' "$ip_policy_gai_begin"
    printf '%s\n' 'precedence ::1/128 50'
    printf '%s\n' 'precedence ::/0 40'
    printf '%s\n' 'precedence 2002::/16 30'
    printf '%s\n' 'precedence ::/96 20'
    printf 'precedence ::ffff:0:0/96 %s\n' "$mapped_precedence"
    printf '%s\n' "$ip_policy_gai_end"
  } | ip_policy_atomic_write "$ip_policy_gai_file" 644
}

ip_policy_restore_gai(){
  local created
  [ -e "$ip_policy_dir/gai_touched" ] || return 0
  [ "$(ip_policy_state_read gai_touched 2>/dev/null)" = yes ] || return 1
  created=$(ip_policy_state_read gai_created 2>/dev/null) || return 1
  case "$created" in yes|no) ;; *) return 1 ;; esac
  ip_policy_gai_markers_valid || { echo "错误：受管 gai.conf 标记已损坏，拒绝自动改写。"; return 1; }
  [ -f "$ip_policy_gai_file" ] || return 0
  ip_policy_strip_gai_block | ip_policy_atomic_write "$ip_policy_gai_file" 644 || return 1
  if [ "$created" = yes ] && ! grep -q '[^[:space:]]' "$ip_policy_gai_file" 2>/dev/null; then
    rm -f -- "$ip_policy_gai_file"
  fi
}

ip_policy_state_write_b64(){
  local key="$1" value="$2" encoded
  encoded=$(printf '%s' "$value" | safe_base64) || return 1
  ip_policy_state_write "$key" "$encoded"
}

ip_policy_state_read_b64(){
  local key="$1" encoded
  encoded=$(ip_policy_state_read "$key" 2>/dev/null) || return 1
  case "$encoded" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
  printf '%s' "$encoded" | base64 -d 2>/dev/null
}

ip_policy_find_nm_uplink(){
  local devices count connection
  command -v nmcli >/dev/null 2>&1 \
    || { echo "错误：从双栈切换 IPv6-only 仅支持 NetworkManager。"; return 1; }
  if [ -d /etc/netplan ] && find /etc/netplan -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print -quit 2>/dev/null | grep -q .; then
    echo "错误：检测到 Netplan，Airgosbx 不会自动改写云网络配置。"
    return 1
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    echo "错误：检测到活动的 systemd-networkd，IPv6-only 自动切换已停止。"
    return 1
  fi
  if [ -f /etc/network/interfaces ] \
    && awk '!/^[[:space:]]*(#|$)/ && /iface[[:space:]]+/ && $0 !~ /iface[[:space:]]+lo[[:space:]]/ {found=1} END{exit !found}' /etc/network/interfaces; then
    echo "错误：检测到 ifupdown 上联配置，IPv6-only 自动切换已停止。"
    return 1
  fi
  devices=$(
    {
      ip -4 route show default 2>/dev/null
      ip -6 route show default 2>/dev/null
    } | awk '{for(i=1;i<=NF;i++) if($i=="dev" && (i+1)<=NF) print $(i+1)}' | sort -u
  )
  count=$(printf '%s\n' "$devices" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || { echo "错误：IPv6-only 要求唯一活动默认上联，当前检测到 ${count:-0} 个。"; return 1; }
  nm_policy_device=$(printf '%s\n' "$devices" | sed -n '1p')
  case "$nm_policy_device" in ''|*[!A-Za-z0-9_.:@-]*) echo "错误：默认上联设备名异常。"; return 1 ;; esac
  nm_policy_uuid=$(LC_ALL=C nmcli -e no -g GENERAL.CON-UUID device show "$nm_policy_device" 2>/dev/null | sed -n '1p')
  if ! printf '%s' "$nm_policy_uuid" | grep -Eq '^[0-9A-Fa-f-]{32,36}$'; then
    connection=$(LC_ALL=C nmcli -e no -g GENERAL.CONNECTION device show "$nm_policy_device" 2>/dev/null | sed -n '1p')
    [ -n "$connection" ] && [ "$connection" != '--' ] \
      || { echo "错误：默认上联不属于活动的 NetworkManager 连接。"; return 1; }
    nm_policy_uuid=$(LC_ALL=C nmcli -e no -g connection.uuid connection show "$connection" 2>/dev/null | sed -n '1p')
  fi
  printf '%s' "$nm_policy_uuid" | grep -Eq '^[0-9A-Fa-f-]{32,36}$' \
    || { echo "错误：无法确认 NetworkManager 上联 UUID。"; return 1; }
}

ip_policy_nm_property_value(){
  local uuid="$1" property="$2" raw separator
  raw=$(LC_ALL=C nmcli -e no -g "$property" connection show "$uuid" 2>/dev/null) || return 1
  case "$property" in
    ipv4.addresses|ipv4.routes) separator=',' ;;
    ipv4.dns) separator=' ' ;;
    *) printf '%s\n' "$raw" | sed -n '1p'; return ;;
  esac
  printf '%s\n' "$raw" | awk -v separator="$separator" '
    {if (NR > 1) printf "%s", separator; printf "%s", $0}
  '
}

ip_policy_save_nm(){
  local property key value saved_uuid saved_device
  local -a properties=(ipv4.method ipv4.addresses ipv4.gateway ipv4.routes ipv4.dns ipv4.link-local ipv4.may-fail)
  if [ -e "$ip_policy_dir/nm_saved" ]; then
    [ "$(ip_policy_state_read nm_saved 2>/dev/null)" = yes ] || return 1
    saved_uuid=$(ip_policy_state_read_b64 nm_uuid 2>/dev/null) || return 1
    saved_device=$(ip_policy_state_read_b64 nm_device 2>/dev/null) || return 1
    [ "$saved_uuid" = "$nm_policy_uuid" ] && [ "$saved_device" = "$nm_policy_device" ] \
      || { echo "错误：默认上联已变化，拒绝套用旧 NetworkManager 状态。"; return 1; }
    return
  fi
  ip_policy_state_write_b64 nm_uuid "$nm_policy_uuid" || return 1
  ip_policy_state_write_b64 nm_device "$nm_policy_device" || return 1
  for property in "${properties[@]}"; do
    value=$(ip_policy_nm_property_value "$nm_policy_uuid" "$property") \
      || { echo "错误：无法保存 NetworkManager 字段 $property。"; return 1; }
    key="nm_${property//./_}"
    ip_policy_state_write_b64 "$key" "$value" || return 1
  done
  ip_policy_state_write nm_saved yes
}

ip_policy_restore_nm(){
  local uuid device property key value
  local -a properties=(ipv4.method ipv4.addresses ipv4.gateway ipv4.routes ipv4.dns ipv4.link-local ipv4.may-fail)
  local -a modify_args
  [ -e "$ip_policy_dir/nm_saved" ] || return 0
  [ "$(ip_policy_state_read nm_saved 2>/dev/null)" = yes ] || return 1
  command -v nmcli >/dev/null 2>&1 || { echo "错误：恢复原 IPv4 上联需要 nmcli。"; return 1; }
  uuid=$(ip_policy_state_read_b64 nm_uuid 2>/dev/null) || return 1
  device=$(ip_policy_state_read_b64 nm_device 2>/dev/null) || return 1
  printf '%s' "$uuid" | grep -Eq '^[0-9A-Fa-f-]{32,36}$' || return 1
  case "$device" in ''|*[!A-Za-z0-9_.:@-]*) return 1 ;; esac
  nmcli -g connection.uuid connection show "$uuid" >/dev/null 2>&1 \
    || { echo "错误：原 NetworkManager 连接已不存在。"; return 1; }
  modify_args=(nmcli connection modify "$uuid")
  for property in "${properties[@]}"; do
    key="nm_${property//./_}"
    value=$(ip_policy_state_read_b64 "$key" 2>/dev/null) || return 1
    modify_args+=("$property" "$value")
  done
  "${modify_args[@]}" >/dev/null 2>&1 || return 1
  nmcli connection verify "$uuid" >/dev/null 2>&1 || return 1
  nmcli device reapply "$device" >/dev/null 2>&1 || return 1
}

ip_policy_apply_ipv6_only_nm(){
  local uuid device
  ip_policy_find_nm_uplink || return 1
  ip_policy_prepare_state || return 1
  ip_policy_save_nm || return 1
  uuid="$nm_policy_uuid"
  device="$nm_policy_device"
  if ! nmcli connection modify "$uuid" \
      ipv4.method disabled ipv4.addresses '' ipv4.gateway '' ipv4.routes '' ipv4.dns '' \
      ipv4.link-local disabled ipv4.may-fail yes >/dev/null 2>&1 \
    || ! nmcli connection verify "$uuid" >/dev/null 2>&1 \
    || ! nmcli device reapply "$device" >/dev/null 2>&1; then
    echo "错误：NetworkManager 无法安全地即时禁用 IPv4，正在恢复原连接设置。"
    ip_policy_restore_nm >/dev/null 2>&1 || echo "严重错误：NetworkManager 原设置自动恢复失败，请使用云控制台处理。"
    return 1
  fi
}

ip_policy_restore_base(){
  ip_policy_restore_nm || { echo "错误：恢复原 NetworkManager 设置失败。"; return 1; }
  ip_policy_restore_sysctl || { echo "错误：恢复原 IPv6 sysctl 失败。"; return 1; }
  ip_policy_restore_gai || { echo "错误：恢复原 gai.conf 失败。"; return 1; }
}

ip_policy_prune_backups_for_mode(){
  local mode="$1" file
  case "$mode" in
    4)
      for file in nm_saved nm_uuid nm_device nm_ipv4_method nm_ipv4_addresses nm_ipv4_gateway nm_ipv4_routes nm_ipv4_dns nm_ipv4_link-local nm_ipv4_may-fail gai_touched gai_created; do
        rm -f -- "$ip_policy_dir/$file"
      done
      ;;
    6)
      for file in sysctl_saved sysctl_all sysctl_default sysctl_lo gai_touched gai_created; do
        rm -f -- "$ip_policy_dir/$file"
      done
      ;;
    '4;6'|'6;4')
      for file in sysctl_saved sysctl_all sysctl_default sysctl_lo nm_saved nm_uuid nm_device nm_ipv4_method nm_ipv4_addresses nm_ipv4_gateway nm_ipv4_routes nm_ipv4_dns nm_ipv4_link-local nm_ipv4_may-fail; do
        rm -f -- "$ip_policy_dir/$file"
      done
      ;;
    *) return 1 ;;
  esac
}

ip_policy_reapply_previous_mode(){
  local mode="$1"
  case "$mode" in
    4)
      [ -e "$ip_policy_dir/sysctl_saved" ] || return 0
      ip_policy_apply_ipv4_only_sysctl
      ;;
    6)
      [ -e "$ip_policy_dir/nm_saved" ] || return 0
      ip_policy_apply_ipv6_only_nm
      ;;
    '4;6'|'6;4')
      [ -e "$ip_policy_dir/gai_touched" ] || return 0
      ip_policy_apply_precedence "$mode"
      ;;
    *) return 1 ;;
  esac
}

ip_policy_mode_configuration_matches(){
  local mode="$1" uuid expected_precedence
  case "$mode" in
    4)
      [ -e "$ip_policy_dir/sysctl_saved" ] || return 0
      ip_policy_sysctl_owned \
        && [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = 1 ] \
        && [ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" = 1 ] \
        && [ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)" = 1 ]
      ;;
    6)
      [ -e "$ip_policy_dir/nm_saved" ] || return 0
      uuid=$(ip_policy_state_read_b64 nm_uuid 2>/dev/null) || return 1
      command -v nmcli >/dev/null 2>&1 \
        && [ "$(nmcli -g ipv4.method connection show "$uuid" 2>/dev/null | sed -n '1p')" = disabled ]
      ;;
    '4;6'|'6;4')
      [ -e "$ip_policy_dir/gai_touched" ] || return 0
      case "$mode" in '4;6') expected_precedence=100 ;; *) expected_precedence=10 ;; esac
      ip_policy_gai_markers_valid && [ -f "$ip_policy_gai_file" ] \
        && awk -v begin="$ip_policy_gai_begin" -v end="$ip_policy_gai_end" -v want="$expected_precedence" '
          $0 == begin {managed=1; next}
          $0 == end {managed=0}
          managed && $1 == "precedence" && $2 == "::ffff:0:0/96" && $3 == want {found=1}
          END {exit !found}
        ' "$ip_policy_gai_file"
      ;;
    *) return 1 ;;
  esac
}

ip_policy_verify_mode(){
  local mode="$1" expected_precedence
  probe_ip_capabilities
  case "$mode" in
    4) [ "$ipv4_capability" = yes ] && [ "$ipv6_capability" = no ] ;;
    6) [ "$ipv4_capability" = no ] && [ "$ipv6_capability" = yes ] ;;
    '4;6'|'6;4')
      { [ "$ipv4_capability" = yes ] && [ "$ipv6_capability" = no ]; } \
        || { [ "$ipv4_capability" = no ] && [ "$ipv6_capability" = yes ]; } \
        || {
          [ "$ipv4_capability" = yes ] && [ "$ipv6_capability" = yes ] || return 1
          case "$mode" in '4;6') expected_precedence=100 ;; *) expected_precedence=10 ;; esac
          [ -f "$ip_policy_gai_file" ] \
            && awk -v begin="$ip_policy_gai_begin" -v end="$ip_policy_gai_end" -v want="$expected_precedence" '
              $0 == begin {managed=1; next}
              $0 == end {managed=0}
              managed && $1 == "precedence" && $2 == "::ffff:0:0/96" && $3 == want {found=1}
              END {exit !found}
            ' "$ip_policy_gai_file"
        }
      ;;
    *) return 1 ;;
  esac
}

ip_policy_apply_mode_from_base(){
  local mode="$1"
  probe_ip_capabilities
  case "$mode" in
    4)
      [ "$ipv4_capability" = yes ] \
        || { echo "错误：ipv=4 要求已确认可用的 IPv4，上联状态为 $ipv4_capability。"; return 1; }
      case "$ipv6_capability" in
        no) return 0 ;;
        unknown) echo "错误：IPv6 状态无法确认，禁止误判后执行单栈切换。"; return 1 ;;
        yes) ;;
      esac
      ip_policy_guard_session 6 || return 1
      ip_policy_apply_ipv4_only_sysctl || return 1
      ip_policy_verify_mode 4 || { echo "错误：IPv4-only 应用后的公网栈验证失败。"; return 1; }
      ;;
    6)
      [ "$ipv6_capability" = yes ] \
        || { echo "错误：ipv=6 要求已确认可用的 IPv6，上联状态为 $ipv6_capability。"; return 1; }
      case "$ipv4_capability" in
        no) return 0 ;;
        unknown) echo "错误：IPv4 状态无法确认，禁止误判后执行单栈切换。"; return 1 ;;
        yes) ;;
      esac
      ip_policy_guard_session 4 || return 1
      ip_policy_apply_ipv6_only_nm || return 1
      ip_policy_verify_mode 6 || { echo "错误：IPv6-only 应用后的公网栈验证失败。"; return 1; }
      ;;
    '4;6'|'6;4')
      if [ "$ipv4_capability" = unknown ] || [ "$ipv6_capability" = unknown ]; then
        echo "错误：至少一个协议族状态无法确认，未修改双栈优先级。"
        return 1
      fi
      if [ "$ipv4_capability" = no ] && [ "$ipv6_capability" = no ]; then
        echo "错误：未确认任何可用公网协议族。"
        return 1
      fi
      if [ "$ipv4_capability" = yes ] && [ "$ipv6_capability" = yes ]; then
        ip_policy_apply_precedence "$mode" || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

ip_policy_cancel_and_restore(){
  [ -e "$ip_policy_dir" ] || { ip_policy_configure_runtime ''; return 0; }
  ip_policy_load_runtime || return 1
  echo "正在恢复 Airgosbx 修改前的 VPS IP 状态……"
  ip_policy_restore_base || return 1
  ip_policy_remove_state || return 1
  ip_policy_configure_runtime ''
  reset_v4v6_probe
  echo "VPS IP 原状态已恢复。"
}

apply_requested_ip_policy(){
  local old_mode target_mode="$ipv_request_mode"
  ip_policy_load_runtime || return 1
  old_mode="$effective_ipv_mode"

  # 完全不传 ipv 只加载当前受管模式；显式 ipv="" 才取消并恢复原状态。
  [ "$ipv_request_set" = yes ] || return 0
  [ -n "$target_mode" ] || { ip_policy_cancel_and_restore; return $?; }
  if [ "$target_mode" = 6 ] && [ "$xicp" = yes ]; then
    echo "错误：ipv=6 不支持 XICMP；当前 XICMP FinalMask 必须监听 IPv4 地址 0.0.0.0。"
    return 1
  fi
  if [ "$old_mode" = "$target_mode" ] && ip_policy_mode_configuration_matches "$target_mode"; then
    ip_policy_configure_runtime "$target_mode"
    echo "ipv=$target_mode 已处于目标状态，无需重复切换。"
    return 0
  fi

  ip_policy_prepare_state || return 1
  if [ -n "$old_mode" ]; then
    echo "正在恢复基础网络状态，再从 ipv=$old_mode 切换到 ipv=$target_mode ……"
    ip_policy_restore_base || return 1
  fi
  if ip_policy_apply_mode_from_base "$target_mode" \
    && ip_policy_state_write mode "$target_mode" \
    && ip_policy_prune_backups_for_mode "$target_mode"; then
    ip_policy_configure_runtime "$target_mode"
    echo "VPS IP 策略已应用：ipv=$target_mode"
    return 0
  fi

  echo "目标 IP 策略未通过验证，正在恢复切换前状态……"
  if ! ip_policy_restore_base; then
    echo "严重错误：IP 原状态恢复失败，已保留全部快照：$ip_policy_dir"
    return 1
  fi
  if [ -n "$old_mode" ] && ip_policy_reapply_previous_mode "$old_mode" \
    && ip_policy_state_write mode "$old_mode" \
    && ip_policy_prune_backups_for_mode "$old_mode"; then
    ip_policy_configure_runtime "$old_mode"
    echo "已恢复切换前状态：ipv=$old_mode"
  elif [ -z "$old_mode" ]; then
    ip_policy_remove_state >/dev/null 2>&1 || true
    ip_policy_configure_runtime ''
  else
    echo "严重错误：切换前 IP 状态未能自动恢复，请立即使用云控制台处理。"
  fi
  return 1
}

port_is_listening(){
local port="$1"
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") { found=1 } END { exit !found }'
elif command -v netstat >/dev/null 2>&1; then
  netstat -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") { found=1 } END { exit !found }'
else
  return 1
fi
}

# Mieru 服务端使用官方 Mita 系统包。脚本仅管理带有 mita_managed 标记的安装，
# 遇到用户自行安装的 mita 时立即停止，避免覆盖其配置或在卸载时误删。
detect_mita_package_target(){
  if [ -f /etc/debian_version ] && command -v dpkg >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
    mita_pkg_type=deb
    case "$cpu" in amd64) mita_pkg_arch=amd64 ;; arm64) mita_pkg_arch=arm64 ;; *) return 1 ;; esac
  elif command -v rpm >/dev/null 2>&1; then
    mita_pkg_type=rpm
    case "$cpu" in amd64) mita_pkg_arch=x86_64 ;; arm64) mita_pkg_arch=aarch64 ;; *) return 1 ;; esac
  else
    return 1
  fi
}

mita_package_installed(){
  case "$mita_pkg_type" in
    deb) dpkg-query -W -f='${Status}' mita 2>/dev/null | grep -q '^install ok installed$' ;;
    rpm) rpm -q mita >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

mita_package_present(){
  case "$mita_pkg_type" in
    deb) dpkg-query -W mita >/dev/null 2>&1 ;;
    rpm) rpm -q mita >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

mita_system_residue_present(){
  mita_package_present \
    || command -v mita >/dev/null 2>&1 \
    || [ -d /etc/mita ] \
    || [ -d /var/lib/mita ] \
    || [ -e /var/run/mita ] \
    || [ -e /var/run/mita.sock ] \
    || [ -e /var/spool/mail/mita ] \
    || [ -e /lib/systemd/system/mita.service ] \
    || [ -e /usr/lib/systemd/system/mita.service ] \
    || [ -e /etc/systemd/system/mita.service ] \
    || [ -d /etc/systemd/system/mita.service.d ] \
    || [ -e /etc/sysctl.d/mieru_tcp_bbr.conf ] \
    || id -u mita >/dev/null 2>&1 \
    || { command -v getent >/dev/null 2>&1 && getent group mita >/dev/null 2>&1; }
}

validate_mita_platform(){
  if ! pidof systemd >/dev/null 2>&1; then
    echo "错误：Mieru 官方 Mita 安装方式需要 systemd；当前系统不支持。其他协议不受影响。"
    return 1
  fi
  if ! detect_mita_package_target; then
    echo "错误：Mita 目前仅接入 Debian/Ubuntu 的 deb 与 RHEL 系的 rpm，架构限 amd64/arm64。"
    return 1
  fi
  if [ ! -f "$HOME/agsbx/mita_managed" ] && mita_system_residue_present; then
    echo "错误：检测到并非由 Airgosbx 安装的 Mita，已停止以保护现有配置。"
    echo "请先自行备份并卸载原 Mita，再重新执行 Mieru 安装。"
    return 1
  fi
}

mita_fetch(){
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fLsS --retry 2 --connect-timeout 8 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=2 --timeout=15 -O "$out" "$url"
  else
    return 1
  fi
}

upmita(){
  local stage="$HOME/agsbx/.stage_mita" api tag version current asset base expected actual install_log
  validate_mita_platform || return 1
  rm -rf "$stage"; mkdir -p "$stage"
  api="$stage/release.json"
  echo "正在读取 enfein/mieru 官方 Latest 发布信息……"
  if ! mita_fetch "https://api.github.com/repos/enfein/mieru/releases/latest" "$api"; then
    echo "错误：无法获取 Mieru 官方 Latest 版本。"; rm -rf "$stage"; return 1
  fi
  tag=$(grep '"tag_name"' "$api" | head -1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  if ! printf '%s' "$tag" | grep -Eq '^v[0-9]+(\.[0-9]+){2,3}([.-][A-Za-z0-9.-]+)?$'; then
    echo "错误：官方 Latest 版本号格式异常，已停止安装。"; rm -rf "$stage"; return 1
  fi
  version=${tag#v}
  case "$mita_pkg_type" in
    deb) asset="mita_${version}_${mita_pkg_arch}.deb" ;;
    rpm) asset="mita-${version}-1.${mita_pkg_arch}.rpm" ;;
  esac
  current=$(mita version 2>/dev/null | grep -Eo 'v?[0-9]+(\.[0-9]+){2,3}' | head -1 | sed 's/^v//')
  if [ "$current" = "$version" ] && mita_package_installed; then
    rm -rf "$stage"
    echo "官方 Mita 已是 Latest：v$current"
    return 0
  fi
  base="https://github.com/enfein/mieru/releases/download/${tag}"
  echo "下载 Mita ${tag} 官方 ${mita_pkg_type} 包并校验 SHA256……"
  if ! mita_fetch "$base/$asset" "$stage/$asset" || ! mita_fetch "$base/$asset.sha256.txt" "$stage/$asset.sha256.txt"; then
    echo "错误：Mita 安装包或官方 SHA256 文件下载失败。"; rm -rf "$stage"; return 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "错误：系统缺少 sha256sum，无法安全校验 Mita 安装包。"; rm -rf "$stage"; return 1
  fi
  expected=$(awk -v file="$asset" '$2 == file || $2 == "*" file {print $1; exit}' "$stage/$asset.sha256.txt" | tr 'A-F' 'a-f')
  actual=$(sha256sum "$stage/$asset" 2>/dev/null | awk '{print $1}')
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "错误：Mita 官方包 SHA256 校验失败，已停止安装。"
    rm -rf "$stage"; return 1
  fi
  echo "SHA256 校验通过 ✓"
  # 标记在包管理器写入前创建：即使安装中途失败，也能明确这次残留由脚本创建并允许后续安全清理。
  touch "$HOME/agsbx/mita_managed" || { echo "错误：无法写入 Mita 归属标记。"; rm -rf "$stage"; return 1; }
  install_log="$stage/install.log"
  if [ "$mita_pkg_type" = deb ]; then
    dpkg -i "$stage/$asset" >"$install_log" 2>&1
  else
    rpm -Uvh --force "$stage/$asset" >"$install_log" 2>&1
  fi
  if [ $? -ne 0 ]; then
    echo "错误：Mita 系统包安装失败："
    tail -n 5 "$install_log"
    rm -rf "$stage"; return 1
  fi
  if ! command -v mita >/dev/null 2>&1 || ! mita_package_installed; then
    echo "错误：包管理器执行完成，但未检测到可用的 mita 命令。"
    rm -rf "$stage"; return 1
  fi
  rm -rf "$stage"
  echo "已安装官方 Mita：$(mita version 2>/dev/null | head -1)"
}

configure_mieru_inputs(){
  local choice candidate
  if [ "$mieru_transport_preset" = yes ] && [ "$mieru_port_preset" = yes ] && \
    [ "$mieru_user_preset" = yes ] && [ "$mieru_pass_preset" = yes ]; then
    return 0
  fi
  [ -t 0 ] || return 0
  echo
  printf '%s\n' "${C_CYAN}========= Mieru 交互配置 =========${C_RESET}"
  if [ "$mieru_transport_preset" != yes ]; then
    while true; do
      printf "传输协议 [1] TCP（推荐） [2] UDP（默认 1）："; read -r choice
      case "$choice" in
        ''|1|tcp|TCP) mierutrans=tcp; mieru_protocol=TCP; break ;;
        2|udp|UDP) mierutrans=udp; mieru_protocol=UDP; break ;;
        *) echo "请输入 1 或 2。" ;;
      esac
    done
  fi
  if [ "$mieru_port_preset" != yes ]; then
    while true; do
      printf "监听端口（回车＝随机高位端口，范围 1025～65535）："; read -r candidate
      if [ -z "$candidate" ]; then
        port_mieru=''
        break
      fi
      if validate_mita_port_value "$candidate" >/dev/null 2>&1; then
        port_mieru="$candidate"
        break
      fi
      echo "端口必须是 1025～65535 的整数；443 不符合 Mita 官方范围。"
    done
  fi
  if [ "$mieru_user_preset" != yes ]; then
    printf "用户名（回车＝自动生成或沿用已有值）："; read -r mieruuser
  fi
  if [ "$mieru_pass_preset" != yes ]; then
    printf "密码（回车＝自动生成或沿用已有值）："; IFS= read -r -s mierupass; echo
  fi
  hr
}

insmierucred(){
  local user_len pass_len
  if [ -n "$mieruuser" ]; then
    printf '%s\n' "$mieruuser" > "$HOME/agsbx/mieru_user"
  elif [ ! -s "$HOME/agsbx/mieru_user" ]; then
    [ -n "$mieruuser" ] || mieruuser=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20)
    printf '%s\n' "$mieruuser" > "$HOME/agsbx/mieru_user"
  fi
  mieruuser=$(cat "$HOME/agsbx/mieru_user" 2>/dev/null)

  if [ -n "$mierupass" ]; then
    printf '%s\n' "$mierupass" > "$HOME/agsbx/mieru_pass"
  elif [ ! -s "$HOME/agsbx/mieru_pass" ]; then
    [ -n "$mierupass" ] || mierupass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20)
    printf '%s\n' "$mierupass" > "$HOME/agsbx/mieru_pass"
  fi
  mierupass=$(cat "$HOME/agsbx/mieru_pass" 2>/dev/null)

  user_len=$(LC_ALL=C printf '%s' "$mieruuser" | wc -c | tr -d ' ')
  pass_len=$(LC_ALL=C printf '%s' "$mierupass" | wc -c | tr -d ' ')
  if [ -z "$mieruuser" ] || [ -z "$mierupass" ] || [ "$user_len" -gt 64 ] || [ "$pass_len" -gt 64 ]; then
    echo "错误：Mieru 用户名和密码必须为 1～64 字节。"; return 1
  fi
  if LC_ALL=C printf '%s' "$mieruuser$mierupass" | grep -q '[[:cntrl:]]'; then
    echo "错误：Mieru 用户名或密码不能包含控制字符。"; return 1
  fi
  echo "Mieru 凭据已生成并保存。"
}

mita_port_is_listening(){
  local port="$1" protocol="$2"
  if command -v ss >/dev/null 2>&1; then
    if [ "$protocol" = TCP ]; then
      ss -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") {found=1} END {exit !found}'
    else
      ss -lun 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") {found=1} END {exit !found}'
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if [ "$protocol" = TCP ]; then
      netstat -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") {found=1} END {exit !found}'
    else
      netstat -lun 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") {found=1} END {exit !found}'
    fi
  else
    return 1
  fi
}

mita_port_is_listening_family(){
  local port="$1" protocol="$2" family="$3" port_hex table dual_table
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  case "$family" in 4|6) ;; *) return 1 ;; esac
  printf -v port_hex '%04X' "$port"
  if [ "$protocol" = TCP ]; then
    table="/proc/net/tcp"
    [ "$family" = 6 ] && table="/proc/net/tcp6"
    awk -v suffix=":$port_hex" '$2 ~ (suffix "$" ) && $4 == "0A" {found=1} END {exit !found}' "$table" 2>/dev/null && return 0
  else
    table="/proc/net/udp"
    [ "$family" = 6 ] && table="/proc/net/udp6"
    awk -v suffix=":$port_hex" '$2 ~ (suffix "$" ) {found=1} END {exit !found}' "$table" 2>/dev/null && return 0
  fi
  # IPv4 还可能由 bindv6only=0 的 IPv6 通配 socket 接收；只把明确绑定全零地址的双栈 socket 视为有效。
  [ "$family" = 4 ] && [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null)" = 0 ] || return 1
  [ "$protocol" = TCP ] && dual_table=/proc/net/tcp6 || dual_table=/proc/net/udp6
  awk -v port="$port_hex" -v tcp="$protocol" '
    $2 == "00000000000000000000000000000000:" port && (tcp != "TCP" || $4 == "0A") {found=1}
    END {exit !found}
  ' "$dual_table" 2>/dev/null
}

mita_policy_listener_is_ready(){
  case "$effective_ipv_mode" in
    4|6)
      mita_port_is_listening_family "$port_mieru" "$mieru_protocol" "$effective_ipv_mode"
      ;;
    '4;6'|'6;4')
      v4v6
      [ -z "$v4" ] || mita_port_is_listening_family "$port_mieru" "$mieru_protocol" 4 || return 1
      [ -z "$v6" ] || mita_port_is_listening_family "$port_mieru" "$mieru_protocol" 6 || return 1
      [ -n "$v4" ] || [ -n "$v6" ]
      ;;
    *) return 0 ;;
  esac
}

mita_port_reserved_by_agsbx(){
  local candidate="$1" requested port_file
  if [ -f "$port_plan_file" ]; then port_plan_conflicts "$candidate" "$(printf '%s' "$mieru_protocol" | tr A-Z a-z)" port_mieru; return $?; fi
  for requested in "$port_vl_re" "$port_vm_ws" "$port_vw" "$port_hy2" "$port_xhy2" "$port_tu" "$port_xh" "$port_vx" "$port_an" "$port_ar" "$port_ss" "$port_so" "$port_xvcdn" "$port_xvargo" "$subpt"; do
    [ -n "$requested" ] && [ "$candidate" = "$requested" ] && return 0
  done
  for port_file in "$HOME/agsbx"/port_*; do
    [ -f "$port_file" ] || continue
    [ "$port_file" = "$HOME/agsbx/port_mieru" ] && continue
    [ "$(cat "$port_file" 2>/dev/null)" = "$candidate" ] && return 0
  done
  return 1
}

validate_mita_port_value(){
  valid_port "$1" && [ "$((10#$1))" -ge 1025 ] || {
    echo "错误：Mieru 端口必须在 1025-65535 之间。"; return 1;
  }
}

init_mita_port(){
  local port_file="$HOME/agsbx/port_mieru" candidate attempt
  if [ -n "$port_mieru" ]; then
    validate_mita_port_value "$port_mieru" >&2 || return 1
    port_mieru=$((10#$port_mieru))
    if mita_port_reserved_by_agsbx "$port_mieru"; then
      echo "错误：Mieru 端口 $port_mieru 已被其他 Airgosbx 协议保留。" >&2; return 1
    fi
    printf '%s\n' "$port_mieru" > "$port_file"
  elif [ ! -s "$port_file" ]; then
    for attempt in {1..100}; do
      candidate=$(get_free_port)
      if ! mita_port_reserved_by_agsbx "$candidate"; then
        printf '%s\n' "$candidate" > "$port_file"
        break
      fi
    done
    [ -s "$port_file" ] || { echo "错误：无法为 Mieru 分配空闲端口。" >&2; return 1; }
  fi
  cat "$port_file"
}

ufw_is_active(){
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status 2>/dev/null | head -1 | grep -qi '^Status:[[:space:]]*active'
}

ufw_rule_is_allowed(){
  local rule="$1"
  ufw status 2>/dev/null | awk -v rule="$rule" '$1 == rule && $0 ~ /ALLOW/ {found=1} END {exit !found}'
}

ufw_rule_is_configured(){
  local rule="$1"
  ufw show added 2>/dev/null | awk -v rule="$rule" '$0 ~ ("^ufw allow " rule "([[:space:]]|$)") {found=1} END {exit !found}'
}

cleanup_mieru_ufw(){
  local marker="$HOME/agsbx/mieru_ufw_rule" rule
  [ -s "$marker" ] || return 0
  rule=$(cat "$marker" 2>/dev/null)
  if ! command -v ufw >/dev/null 2>&1; then
    echo "错误：找不到 ufw，无法回收 Airgosbx 创建的 Mieru 防火墙规则。"
    return 1
  fi
  if ufw_rule_is_configured "$rule" && ! ufw --force delete allow "$rule" >/dev/null 2>&1; then
    echo "错误：无法删除 Airgosbx 创建的 Mieru UFW 规则。"
    return 1
  fi
  if ufw_rule_is_configured "$rule"; then
    echo "错误：Mieru 的 UFW 规则未能完全删除，已保留卸载状态供重试。"
    return 1
  fi
  rm -f "$marker"
}

ensure_mieru_ufw(){
  local protocol rule marker="$HOME/agsbx/mieru_ufw_rule" old_rule
  ufw_is_active || return 0
  protocol=$(printf '%s' "$mieru_protocol" | tr 'A-Z' 'a-z')
  rule="$port_mieru/$protocol"
  old_rule=$(cat "$marker" 2>/dev/null)
  if [ -n "$old_rule" ] && [ "$old_rule" != "$rule" ]; then
    cleanup_mieru_ufw || return 1
  fi
  # 已有管理员规则时直接复用，不记录归属，del 时也不会删除它。
  ufw_rule_is_allowed "$rule" && return 0
  if ! ufw --force allow "$rule" comment 'Airgosbx-Mieru' >/dev/null 2>&1; then
    echo "错误：UFW 已启用，但无法静默放行 Mieru 的 $rule。"
    return 1
  fi
  printf '%s\n' "$rule" > "$marker"
  if ! ufw_rule_is_allowed "$rule" || ! ufw_rule_is_configured "$rule"; then
    ufw --force delete allow "$rule" >/dev/null 2>&1 || true
    rm -f "$marker"
    echo "错误：已执行 UFW 放行，但复查时未发现 Mieru 的 $rule。"
    return 1
  fi
}

reset_mita_config(){
  [ -f "$HOME/agsbx/mita_managed" ] || return 0
  command -v mita >/dev/null 2>&1 && mita stop >/dev/null 2>&1 || true
  if command -v mita >/dev/null 2>&1 || [ -e /lib/systemd/system/mita.service ] || [ -e /usr/lib/systemd/system/mita.service ] || [ -e /etc/systemd/system/mita.service ]; then
    systemctl stop mita >/dev/null 2>&1 || { echo "错误：Mita daemon 未停止，未删除配置。"; return 1; }
  fi
  # apply config 在不同 Mita 版本间曾有合并/替换差异；先清掉脚本拥有的内部配置，确保 rep 不残留旧端口和用户。
  rm -f /etc/mita/server.conf.pb
}

wait_mita_daemon(){
  local attempt
  for attempt in {1..12}; do
    if systemctl is-active --quiet mita && mita status >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

wait_mita_running(){
  local attempt
  for attempt in {1..10}; do
    mita status 2>&1 | grep -q 'RUNNING' && return 0
    sleep 1
  done
  return 1
}

init_mieru_traffic_seed(){
  local seed_file="$HOME/agsbx/mieru_traffic_seed" seed
  seed=$(cat "$seed_file" 2>/dev/null)
  case "$seed" in
    ''|*[!0-9]*) seed='' ;;
    *)
      if [ "${#seed}" -gt 10 ] || [ "$seed" -lt 1 ] || [ "$seed" -gt 2147483647 ]; then seed=''; fi
      ;;
  esac
  if [ -z "$seed" ]; then
    if command -v od >/dev/null 2>&1; then
      seed=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d '[:space:]')
    fi
    case "$seed" in ''|*[!0-9]*) seed=$(date +%s 2>/dev/null) ;; esac
    seed=$((seed % 2147483647 + 1))
    printf '%s\n' "$seed" > "$seed_file" || { echo "错误：无法保存 Mieru Traffic Pattern 种子。"; return 1; }
  fi
  chmod 600 "$seed_file"
  printf '%s' "$seed"
}

validate_mieru_traffic_pattern(){
  local pattern="$1"
  case "$pattern" in
    ''|*[!A-Za-z0-9+/_=-]*) return 1 ;;
  esac
}

export_mieru_traffic_pattern(){
  local pattern pattern_file="$HOME/agsbx/mieru_traffic_pattern"
  pattern=$(mita export traffic-pattern 2>/dev/null)
  if [ $? -ne 0 ] || ! validate_mieru_traffic_pattern "$pattern" || \
    ! mita explain traffic-pattern "$pattern" >/dev/null 2>&1; then
    rm -f "$pattern_file"
    echo "错误：Mita 未能导出 Shadowrocket 所需的 Traffic Pattern。"
    return 1
  fi
  printf '%s\n' "$pattern" > "$pattern_file" || { echo "错误：无法保存 Mieru Traffic Pattern。"; return 1; }
  chmod 600 "$pattern_file"
}

write_mita_config(){
  local user_json pass_json traffic_seed
  validate_mita_port_value "$port_mieru" || return 1
  if mita_port_is_listening "$port_mieru" "$mieru_protocol"; then
    echo "错误：Mieru 的 ${mieru_protocol} 端口 $port_mieru 已被其他程序占用。"; return 1
  fi
  user_json=$(json_escape "$mieruuser")
  pass_json=$(json_escape "$mierupass")
  traffic_seed=$(init_mieru_traffic_seed) || return 1
  cat > "$HOME/agsbx/mita.json" <<EOF
{
  "portBindings": [
    {"port": $port_mieru, "protocol": "$mieru_protocol"}
  ],
  "users": [
    {"name": "$user_json", "password": "$pass_json"}
  ]
EOF
  if [ -n "$effective_ipv_mode" ]; then
    cat >> "$HOME/agsbx/mita.json" <<EOF
  ,"dns": {"dualStack": "$mita_dns_policy"}
EOF
  fi
  cat >> "$HOME/agsbx/mita.json" <<EOF
  ,"loggingLevel": "INFO",
  "mtu": 1400,
  "trafficPattern": {
    "seed": $traffic_seed,
    "unlockAll": false
  }
}
EOF
  printf '%s\n' "$mieru_protocol" > "$HOME/agsbx/mieru_protocol"
  chmod 600 "$HOME/agsbx/mita.json" "$HOME/agsbx/mieru_user" "$HOME/agsbx/mieru_pass" \
    "$HOME/agsbx/mieru_protocol" "$HOME/agsbx/mieru_traffic_seed"
}

installmita(){
  local apply_out status_out
  validate_mita_platform || return 1
  configure_mieru_inputs
  reset_mita_config || return 1
  port_mieru=$(init_mita_port) || return 1
  insmierucred || return 1
  write_mita_config || return 1
  if [ "$rep_mode" = yes ] && [ -f "$HOME/agsbx/mita_managed" ] && command -v mita >/dev/null 2>&1; then
    echo "rep 模式：复用现有 Mita 系统包，只重建并验证 Mieru 配置。"
  else
    upmita || return 1
  fi
  # 官方包安装后会自动拉起 daemon；再次停止并清除内部配置，确保只应用当前脚本生成的单一用户/端口。
  reset_mita_config || return 1
  ensure_mieru_ufw || return 1
  systemctl enable mita >/dev/null 2>&1 || { echo "错误：无法设置 Mita 开机启动。"; return 1; }
  systemctl start mita >/dev/null 2>&1 || { echo "错误：Mita daemon 启动失败。"; return 1; }
  if ! wait_mita_daemon; then
    echo "错误：Mita daemon 未就绪，请运行 journalctl -u mita -n 30 --no-pager 检查。"; return 1
  fi
  apply_out=$(mita apply config "$HOME/agsbx/mita.json" 2>&1)
  if [ $? -ne 0 ]; then
    echo "错误：Mita 配置写入失败："; printf '%s\n' "$apply_out" | tail -n 5; return 1
  fi
  mita stop >/dev/null 2>&1 || true
  if ! mita start >/dev/null 2>&1; then
    echo "错误：Mieru 代理启动失败，请运行 mita describe config 检查。"; return 1
  fi
  if ! wait_mita_running; then
    status_out=$(mita status 2>&1)
    echo "错误：Mieru 代理未进入 RUNNING 状态：$status_out"; return 1
  fi
  if ! mita_policy_listener_is_ready; then
    echo "错误：Mieru 未监听 ipv=$effective_ipv_mode 所需的协议族。"
    mita stop >/dev/null 2>&1 || true
    return 1
  fi
  export_mieru_traffic_pattern || { mita stop >/dev/null 2>&1 || true; return 1; }
  echo "Mieru/Mita 已启动：${mieru_protocol} $port_mieru ✓"
  echo "请确认云平台安全组及其他非 UFW 防火墙已放行 ${mieru_protocol} 端口 $port_mieru。"
}

uninstall_mita_managed(){
  cleanup_mieru_ufw || return 1
  [ -f "$HOME/agsbx/mita_managed" ] || return 0
  detect_mita_package_target || { echo "错误：无法识别 Mita 包管理器，已保留 Mita 以免误删。"; return 1; }
  reset_mita_config || return 1
  systemctl disable mita >/dev/null 2>&1 || true
  if [ "$mita_pkg_type" = deb ] && dpkg-query -W mita >/dev/null 2>&1; then
    dpkg -P mita >/dev/null 2>&1 || { echo "错误：Mita deb 包卸载失败，已保留归属标记。"; return 1; }
  elif [ "$mita_pkg_type" = rpm ] && rpm -q mita >/dev/null 2>&1; then
    rpm -e mita >/dev/null 2>&1 || { echo "错误：Mita rpm 包卸载失败，已保留归属标记。"; return 1; }
  fi
  # 对齐官方 setup.py --uninstall 的清理范围，并补清 systemd 启用链接/覆盖目录与包路径残留。
  rm -rf /etc/mita /var/lib/mita /var/run/mita /var/spool/mail/mita /etc/systemd/system/mita.service.d
  rm -f /var/run/mita.sock /usr/bin/mita \
    /lib/systemd/system/mita.service /usr/lib/systemd/system/mita.service /etc/systemd/system/mita.service \
    /etc/systemd/system/multi-user.target.wants/mita.service /etc/sysctl.d/mieru_tcp_bbr.conf
  userdel mita >/dev/null 2>&1 || true
  groupdel mita >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed mita >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  if mita_system_residue_present; then
    echo "错误：检测到 Mita 系统残留，已保留 Airgosbx 目录和归属标记供再次卸载。"
    return 1
  fi
  echo "已卸载由 Airgosbx 管理的 Mita。"
}
install_socat_if_needed(){
command -v socat >/dev/null 2>&1 && return 0
is_root || return 1
if command -v apk >/dev/null 2>&1; then
apk add socat >/dev/null 2>&1
elif command -v apt >/dev/null 2>&1; then
apt update >/dev/null 2>&1 && apt install socat -y >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
yum install socat -y >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
dnf install socat -y >/dev/null 2>&1
fi
command -v socat >/dev/null 2>&1
}
certificate_fingerprint(){
  local file="${1:-${tls_cert_file:-$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)}}" fingerprint
  [ -s "$file" ] || return 1
  fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$file" 2>/dev/null | awk -F= '{print $2}' | tr -d ':' | tr A-F a-f)
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$fingerprint"
}

neutralize_legacy_acme_reload(){
  local identifier="$1" config line encoded decoded expected content
  valid_ip "$identifier" || valid_domain "$identifier" || return 1
  config="$HOME/agsbx/acme/${identifier}_ecc/$identifier.conf"
  [ -f "$config" ] && [ ! -L "$config" ] || { echo "错误：ACME 当前证书的续期配置缺失。"; return 1; }
  line=$(sed -n '/^Le_ReloadCmd=/p' "$config")
  case "$line" in
    "Le_ReloadCmd='true'") return 0 ;;
    "Le_ReloadCmd='__ACME_BASE64__START_"*"__ACME_BASE64__END_'")
      encoded=${line#"Le_ReloadCmd='__ACME_BASE64__START_"}
      encoded=${encoded%"__ACME_BASE64__END_'"}
      [[ "$encoded" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
      decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null) || return 1
      ;;
    *) echo "错误：ACME 重载钩子格式无法确认，保留原配置。"; return 1 ;;
  esac
  expected="if pidof systemd >/dev/null 2>&1; then systemctl restart xr 2>/dev/null; systemctl restart sb 2>/dev/null; elif command -v rc-service >/dev/null 2>&1; then rc-service xray restart 2>/dev/null; rc-service sing-box restart 2>/dev/null; else kill -15 \$(pgrep -f 'agsbx/xray') \$(pgrep -f 'agsbx/sing-box') 2>/dev/null; sleep 2; [ -x $HOME/agsbx/xray ] && nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json > $HOME/agsbx/xray.log 2>&1 & [ -x $HOME/agsbx/sing-box ] && nohup $HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json > $HOME/agsbx/sing-box.log 2>&1 & fi; true"
  [ "$decoded" = true ] && return 0
  [ "$decoded" = "$expected" ] || { echo "错误：ACME 有自定义重载钩子，未自动覆盖。"; return 1; }
  content=$(awk '!/^Le_ReloadCmd=/' "$config") || return 1
  content="$content
Le_ReloadCmd='true'
"
  atomic_text_file "$config" "$content"
}

migrate_certificate_jobs(){
  local source identifier
  source=$(cat "$HOME/agsbx/cert_source" 2>/dev/null)
  case "$source" in
    caddy) setup_caddy_cert_reload ;;
    acme-*)
      identifier=$(cat "$HOME/agsbx/cert_identifier") || return 1
      neutralize_legacy_acme_reload "$identifier" && register_acme_cron ;;
    *) return 0 ;;
  esac
}

write_cert_fingerprint(){
  local fingerprint
  fingerprint=$(certificate_fingerprint) || return 1
  atomic_text_file "$HOME/agsbx/cert_sha256.txt" "$fingerprint"
}
record_tls_cert_paths(){
tls_cert_file="$1"
tls_key_file="$2"
echo "$tls_cert_file" > "$HOME/agsbx/cert_file_path"
echo "$tls_key_file" > "$HOME/agsbx/key_file_path"
}
record_cert_source(){
echo "$1" > "$HOME/agsbx/cert_source"
echo "$2" > "$HOME/agsbx/cert_identifier"
}
validate_certificate_bundle(){
local cert_file="$1" key_file="$2" source="$3" identifier threshold cert_public key_public
shift 3
[ -s "$cert_file" ] && [ -s "$key_file" ] || return 1
openssl x509 -noout -in "$cert_file" >/dev/null 2>&1 || return 1
openssl pkey -noout -in "$key_file" >/dev/null 2>&1 || return 1
cert_public=$(openssl x509 -pubkey -noout -in "$cert_file" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
key_public=$(openssl pkey -in "$key_file" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)
[ -n "$cert_public" ] && [ "$cert_public" = "$key_public" ] || return 1
case "$source" in
  acme-ip) threshold=86400 ;;
  acme-http|acme-alpn|acme-dns) threshold=2592000 ;;
  *) threshold=0 ;;
esac
openssl x509 -checkend "$threshold" -noout -in "$cert_file" >/dev/null 2>&1 || return 1
if [ "$source" != selfsigned ]; then
  openssl x509 -noout -ext subjectAltName -in "$cert_file" 2>/dev/null | grep -Eq 'DNS:|IP Address:' || return 1
fi
for identifier in "$@"; do
  case "$identifier" in
    \*.*)
      valid_domain "${identifier#\*.}" || return 1
      openssl x509 -noout -ext subjectAltName -in "$cert_file" 2>/dev/null \
        | tr ',' '\n' \
        | sed -n 's/.*DNS:[[:space:]]*//p' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -Fqx -- "$identifier" || return 1
      ;;
    *)
      if valid_ip "$identifier"; then
        openssl x509 -checkip "$identifier" -noout -in "$cert_file" >/dev/null 2>&1 || return 1
      elif valid_domain "$identifier"; then
        openssl x509 -checkhost "$identifier" -noout -in "$cert_file" >/dev/null 2>&1 || return 1
      else
        return 1
      fi
      ;;
  esac
done
}
register_acme_cron(){
  local script_path
  script_path=$(managed_script_path) || return 1
  write_managed_cron AIRGOSBX_CERT_RENEW \
    "30 2 * * * /bin/bash $script_path __cert_renew > /dev/null 2>&1" \
    "30 2 * * * /bin/bash $HOME/agsbx/acme.sh --cron --home $HOME/agsbx/acme > /dev/null 2>&1"
}
# ca/caddy 是来源标记；订阅仍须实际校验证书链与 SAN，不能仅凭标记认定可信。
cert_trusted(){ [ "$1" = "ca" ] || [ "$1" = "caddy" ]; }

# 订阅必须同时通过证书身份、私钥配对和系统信任库校验，不能只相信磁盘上的 ca 标记。
validate_public_certificate(){
  validate_certificate_bundle "$1" "$2" subscription "$3" || return 1
  # 订阅客户端按 URL 校验 SAN，不接受只有 CN 的域名匹配。
  if valid_ip "$3"; then
    openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null | grep -q 'IP Address:' || return 1
  else
    openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null | grep -q 'DNS:' || return 1
  fi
  openssl verify -purpose sslserver -untrusted "$1" "$1" >/dev/null 2>&1
}

# 纯读取：用于发布前校验与 list 展示，不签发证书、不修改任何状态。
subscription_certificate_host(){
  local mode cert key identifier candidate
  mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
  cert_trusted "$mode" || { echo "错误：订阅分享必须使用公信 CA 证书；请启用 sub=y 并通过 ACME 申请 IP 或域名证书。" >&2; return 1; }
  cert=$(cat "$HOME/agsbx/cert_file_path") && key=$(cat "$HOME/agsbx/key_file_path") \
    && identifier=$(cat "$HOME/agsbx/cert_identifier") || return 1
  { valid_ip "$identifier" || valid_domain "$identifier"; } \
    && validate_public_certificate "$cert" "$key" "$identifier" \
    || { echo "错误：订阅证书未通过公信证书链、有效期或地址匹配校验，未输出分享链接。" >&2; return 1; }
  candidate="${1:-$(cat "$HOME/agsbx/cdnym" 2>/dev/null)}"
  if [ -n "$candidate" ]; then
    valid_domain "$candidate" || { echo "错误：已保存的 CDN 域名无效，未输出订阅链接。" >&2; return 1; }
    # CDN 接入域名可能与 Caddy/ACME 证书不同；不匹配时使用证书本身的已验证身份。
    if validate_certificate_bundle "$cert" "$key" subscription "$candidate"; then identifier="$candidate"; fi
  fi
  if valid_ipv6 "$identifier"; then printf '[%s]' "$identifier"; else printf '%s' "$identifier"; fi
}

# 校验 HTTP/1.0 的完整响应，正文必须与将要发布的文件逐字节一致。
subscription_response_matches(){
  local expected="$1" response="$2" status line lower length='' headers=0 ended=no wanted actual size
  [ -s "$expected" ] && [ -s "$response" ] || return 1
  size=$(wc -c < "$expected") || return 1
  {
    IFS= read -r status || return 1
    status=${status%$'\r'}
    case "$status" in 'HTTP/1.0 200 '*|'HTTP/1.1 200 '*) ;; *) return 1 ;; esac
    while IFS= read -r line; do
      line=${line%$'\r'}
      [ -n "$line" ] || { ended=yes; break; }
      headers=$((headers + 1))
      [ "$headers" -le 64 ] && [ "${#line}" -le 8192 ] || return 1
      lower=$(printf '%s' "$line" | tr A-Z a-z)
      case "$lower" in
        content-length:*)
          [ -z "$length" ] || return 1
          [[ "$lower" =~ ^content-length:[[:space:]]*([0-9]{1,10})[[:space:]]*$ ]] || return 1
          length=${BASH_REMATCH[1]}
          [ "$((10#$length))" -eq "$size" ] || return 1 ;;
        transfer-encoding:*) return 1 ;;
      esac
    done
    [ "$ended" = yes ] || return 1
    actual=$(sha256sum) && wanted=$(sha256sum < "$expected") || return 1
    [ "${actual%% *}" = "${wanted%% *}" ]
  } < "$response"
}

# 发布时实际下载订阅：只连接本机，令牌通过请求标准输入传递，不放进进程参数。
verify_subscription_https(){
  local token="$1" host verify_host port endpoint temporary file expected failed=no
  local -a args
  command -v timeout >/dev/null 2>&1 || { echo "错误：缺少 timeout，无法限制订阅 HTTPS 下载校验时间。"; return 1; }
  [[ "$token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || return 1
  host=$(subscription_certificate_host) || return 1
  verify_host=${host#[}; verify_host=${verify_host%]}
  port=$(cat "$HOME/agsbx/subport.log") && valid_port "$port" || return 1
  if [ "$public_listen_address" = '::' ]; then endpoint="[::1]:$port"; else endpoint="127.0.0.1:$port"; fi
  args=(-connect "$endpoint" -alpn http/1.1 -verify_return_error -quiet -ign_eof)
  if valid_ip "$verify_host"; then args+=(-verify_ip "$verify_host")
  else args+=(-servername "$verify_host" -verify_hostname "$verify_host"); fi
  temporary=$(mktemp -d "$HOME/agsbx/.subscription-check.XXXXXX") || return 1
  chmod 700 "$temporary" || { rmdir "$temporary"; return 1; }
  for file in jhsub.txt clmi.yaml; do
    expected="$HOME/websbx/$token/$file"
    [ "$file" != clmi.yaml ] || [ -e "$expected" ] || continue
    if [ ! -s "$expected" ]; then
      echo "错误：待发布的 $file 缺失或为空。"
      failed=yes; break
    fi
    if ! printf 'GET /%s/%s HTTP/1.0\r\nHost: %s:%s\r\nConnection: close\r\n\r\n' "$token" "$file" "$host" "$port" \
      | timeout -k 1 10 openssl s_client "${args[@]}" > "$temporary/response" 2> "$temporary/tls-error"; then
      echo "错误：$file 的本机 HTTPS 下载失败，未输出分享链接。"
      tail -n 6 "$temporary/tls-error"
      failed=yes; break
    fi
    if ! subscription_response_matches "$expected" "$temporary/response"; then
      echo "错误：$file 的 HTTPS 响应状态、长度或正文与发布文件不一致，未输出分享链接。"
      failed=yes; break
    fi
  done
  rm -rf -- "$temporary" || return 1
  [ "$failed" = no ]
}
# Caddy(naive) 证书续期联动重载：Caddy 自动续期会原地更新证书文件，但 xray/sing-box 仅在启动时读取证书、
# 不会热感知续期。此处生成助手脚本并注册每日 cron——每天比对证书指纹，仅当证书真正变化(续期)时，
# 才重启「配置里确实引用了该 Caddy 证书路径」的内核，平时零打断；首次运行只记录基线指纹。
# 助手脚本用单引号 heredoc 写入，内部 $HOME/$cf 等在 cron 运行时(而非安装时)求值。
setup_caddy_cert_reload(){
  local script_path
  script_path=$(managed_script_path) || return 1
  write_managed_cron AIRGOSBX_CERT_RELOAD \
    "20 3 * * * /bin/bash $script_path __cert_reload > /dev/null 2>&1" \
    "20 3 * * * /bin/bash $HOME/agsbx/caddy_cert_reload.sh > /dev/null 2>&1" || return 1
  # 注册时只建立基线，不能启动管理员已停止的内核。
  local cf fp
  cf=$(cat "$HOME/agsbx/cert_file_path") || return 1
  fp=$(certificate_fingerprint "$cf") || return 1
  printf '%s\n' "$fp" | ip_policy_atomic_write "$HOME/agsbx/.caddy_cert_fp" 600
}

reload_shared_certificate(){
  local cf kf identifier fp previous core cfg old tmp
  cf=$(cat "$HOME/agsbx/cert_file_path") && kf=$(cat "$HOME/agsbx/key_file_path") \
    && identifier=$(cat "$HOME/agsbx/cert_identifier") || return 1
  validate_certificate_bundle "$cf" "$kf" reload "$identifier" || return 1
  if [ -s "$HOME/agsbx/subtoken.log" ] && [ -d "$HOME/websbx" ]; then subscription_certificate_host >/dev/null || return 1; fi
  fp=$(certificate_fingerprint "$cf") || return 1
  previous=$(cat "$HOME/agsbx/.caddy_cert_fp" 2>/dev/null)
  previous=${previous#*=}; previous=${previous//:/}; previous=$(printf '%s' "$previous" | tr A-F a-f)
  [ "$fp" != "$previous" ] || return 0
  for core in xray sing-box; do
    [ "$core" = xray ] && cfg=xr.json || cfg=sb.json
    grep -Fq "$cf" "$HOME/agsbx/$cfg" 2>/dev/null || continue
    agsbx_component_running "$core" || continue
    # Sing-box 原生监听证书文件变化；Xray 的受管实例确认重启成功后再提交指纹。
    if [ "$core" = xray ]; then kctl restart xray || return 1; fi
  done
  write_cert_fingerprint || return 1
  printf '%s\n' "$fp" | ip_policy_atomic_write "$HOME/agsbx/.caddy_cert_fp" 600
}
show_tls_cert_summary(){
cert_result="$1"
cert_domain="$2"
cert_file=${tls_cert_file:-$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)}
key_file=${tls_key_file:-$(cat "$HOME/agsbx/key_file_path" 2>/dev/null)}
cert_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode_now=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
cert_source_now=$(cat "$HOME/agsbx/cert_source" 2>/dev/null)
cert_issuer=$(openssl x509 -noout -issuer -in "$cert_file" 2>/dev/null | sed 's/^issuer=//')
cert_subject=$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null | sed 's/^subject=//')
cert_not_before=$(openssl x509 -noout -startdate -in "$cert_file" 2>/dev/null | sed 's/^notBefore=//')
cert_not_after=$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null | sed 's/^notAfter=//')
cert_serial=$(openssl x509 -noout -serial -in "$cert_file" 2>/dev/null | sed 's/^serial=//')
cert_fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" 2>/dev/null | awk -F= '{print $2}')
printf '%s\n' "${C_CYAN}========== TLS 证书信息 ==========${C_RESET}"
echo "证书结果：$cert_result"
[ -n "$cert_domain" ] && echo "申请标识：$cert_domain"
[ -n "$cert_sni" ] && echo "SNI/CN：$cert_sni"
[ -n "$cert_mode_now" ] && echo "证书模式：$cert_mode_now"
[ -n "$cert_source_now" ] && echo "证书来源：$cert_source_now"
# 签发方式：把内部 cert_mode 翻译成人类可读来源，明确区分「ACME 命令申请」与「Caddy 自动托管申请」。
case "$cert_mode_now" in
  ca)
    case "$cert_source_now" in
      external)   echo "签发方式：外部导入的受信任证书" ;;
      acme-ip)    echo "签发方式：acme.sh + Let's Encrypt IP 短期证书" ;;
      acme-http)  echo "签发方式：acme.sh + HTTP-01" ;;
      acme-alpn)  echo "签发方式：acme.sh + TLS-ALPN-01" ;;
      acme-dns)   echo "签发方式：acme.sh + Cloudflare DNS-01" ;;
      *)          echo "签发方式：ACME 命令申请或外部导入证书" ;;
    esac
    ;;
  caddy)      echo "签发方式：Caddy(naive) 自动托管申请（Caddy 内置 ACME，自动续期）" ;;
  selfsigned) echo "签发方式：OpenSSL 本地自签（无需域名，有效期 100 年）" ;;
  *)          echo "签发方式：未知" ;;
esac
echo "颁发机构：${cert_issuer:-未知}"
echo "证书主体：${cert_subject:-未知}"
echo "有效期开始：${cert_not_before:-未知}"
echo "有效期结束：${cert_not_after:-未知}"
echo "证书序列号：${cert_serial:-未知}"
echo "SHA256指纹：${cert_fingerprint:-未知}"
echo "证书文件：$cert_file"
echo "私钥文件：$key_file"
echo "指纹文件：$HOME/agsbx/cert_sha256.txt"
case "$cert_source_now" in acme-*) echo "ACME工作目录：$HOME/agsbx/acme" ;; esac
[ "$cert_mode_now" = "caddy" ] && echo "Caddy证书存储目录：$HOME/agsbx/caddy_storage/caddy/certificates"
printf '%s\n' "${C_CYAN}==================================${C_RESET}"
}
setup_selfsigned_certificate(){
  [ "$sub" != yes ] || { echo "错误：订阅分享不能使用自签证书，必须复用或申请公信 CA 证书。"; return 1; }
  local directory="$HOME/agsbx/openssl" cert="$HOME/agsbx/openssl/cert.pem" key="$HOME/agsbx/openssl/private.key" identifier tmp
  identifier=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
  if [ -e "$cert" ] || [ -e "$key" ]; then
    [ -n "$identifier" ] && validate_certificate_bundle "$cert" "$key" selfsigned "$identifier" \
      || { echo "错误：已有自签证书无效，已保留原证书，请明确更换证书后重试。"; return 1; }
  else
    # 纯 REALITY 或失败安装可能从未创建证书；允许首次创建，但不能掩盖旧证书丢失。
    if [ "$rep_mode" = yes ]; then
      local saved_cert_state
      for saved_cert_state in cert_mode cert_source cert_identifier cert_file_path key_file_path acmecer/cert.pem acmecer/private.key; do
        if [ -e "$HOME/agsbx/$saved_cert_state" ] || [ -L "$HOME/agsbx/$saved_cert_state" ]; then
          echo "错误：rep 检测到旧证书记录但证书文件缺失，拒绝用新自签证书替换；请恢复原证书或完整重装。"
          return 1
        fi
      done
    fi
    mkdir -p "$directory" || return 1
    tmp=$(mktemp -d "$directory/.new.XXXXXX") || return 1
    identifier="$(openssl rand -hex 8).invalid"
    if ! openssl ecparam -genkey -name prime256v1 -out "$tmp/key" \
      || ! openssl req -new -x509 -days 36500 -key "$tmp/key" -out "$tmp/cert" -subj "/CN=$identifier" -addext "subjectAltName=DNS:$identifier" \
      || ! validate_certificate_bundle "$tmp/cert" "$tmp/key" selfsigned "$identifier"; then
      rm -rf -- "$tmp"; return 1
    fi
    mv "$tmp/key" "$key" && mv "$tmp/cert" "$cert" || { rm -rf -- "$tmp"; return 1; }
    rmdir "$tmp"
  fi
  printf '%s\n' "$identifier" > "$HOME/agsbx/sni.txt" || return 1
  printf '%s\n' selfsigned > "$HOME/agsbx/cert_mode" || return 1
  record_cert_source selfsigned "$identifier"
  record_tls_cert_paths "$cert" "$key"
  write_cert_fingerprint
}
ensure_official_acme(){
local mode="$1"
# 主脚本与 DNS hook 必须固定到同一官方提交；升级时同步更新此值并重新审阅，禁止直接执行可变 master。
local acme_ref="2feb392bd0e3964d9bf68871ae804578d9d5ca80"
local acme_script="$HOME/agsbx/acme.sh"
local acme_tmp="$HOME/agsbx/.acme.sh.$$"
local acme_ref_file="$HOME/agsbx/acme_upstream_ref"
local cf_hook="$HOME/agsbx/dnsapi/dns_cf.sh"
local cf_hook_tmp="$HOME/agsbx/dnsapi/.dns_cf.sh.$$"
local cf_hook_ref_file="$HOME/agsbx/dnsapi/.dns_cf_ref"
local refresh=no
[ -s "$acme_script" ] || refresh=yes
[ "$(cat "$acme_ref_file" 2>/dev/null)" = "$acme_ref" ] || refresh=yes
if [ "$refresh" = yes ]; then
  echo "准备安装固定到官方提交 ${acme_ref:0:12} 的 acme.sh。"
  fetch_file "https://raw.githubusercontent.com/acmesh-official/acme.sh/$acme_ref/acme.sh" "$acme_tmp" || {
    rm -f "$acme_tmp"
    echo "错误：无法从 acmesh-official/acme.sh 官方仓库下载脚本。"
    return 1
  }
  head -n 1 "$acme_tmp" | grep -q '^#!/' || {
    rm -f "$acme_tmp"
    echo "错误：下载到的 acme.sh 文件格式异常。"
    return 1
  }
  mv "$acme_tmp" "$acme_script" || return 1
  echo "$acme_ref" > "$acme_ref_file"
fi
chmod 700 "$acme_script" 2>/dev/null
if [ "$mode" = ip ] && ! grep -q -- '--certificate-profile' "$acme_script"; then
  echo "错误：固定版本的 acme.sh 不支持 IP 证书参数。"
  return 1
fi
if [ "$mode" = dns ] && { [ ! -s "$cf_hook" ] || [ "$(cat "$cf_hook_ref_file" 2>/dev/null)" != "$acme_ref" ]; }; then
  mkdir -p "$HOME/agsbx/dnsapi"
  fetch_file "https://raw.githubusercontent.com/acmesh-official/acme.sh/$acme_ref/dnsapi/dns_cf.sh" "$cf_hook_tmp" || {
    rm -f "$cf_hook_tmp"
    echo "错误：无法从官方仓库下载 Cloudflare DNS hook。"
    return 1
  }
  grep -q 'dns_cf_add()' "$cf_hook_tmp" || {
    rm -f "$cf_hook_tmp"
    echo "错误：下载到的 Cloudflare DNS hook 格式异常。"
    return 1
  }
  mv "$cf_hook_tmp" "$cf_hook" || return 1
  echo "$acme_ref" > "$cf_hook_ref_file"
  chmod 700 "$cf_hook" 2>/dev/null
fi
}
setup_external_certificate(){
local acme_cert_file="$HOME/agsbx/acmecer/cert.pem"
local acme_key_file="$HOME/agsbx/acmecer/private.key"
local cert_identifier
mkdir -p "$HOME/agsbx/acmecer"
if [ ! -s "$certcrt" ] || [ ! -s "$certkey" ]; then
  echo "错误：certcrt 与 certkey 必须同时指向有效的证书和私钥文件。"
  return 1
fi
openssl x509 -noout -in "$certcrt" >/dev/null 2>&1 || {
  echo "错误：certcrt 不是 OpenSSL 可识别的 PEM 证书。"
  return 1
}
openssl pkey -noout -in "$certkey" >/dev/null 2>&1 || {
  echo "错误：certkey 不是 OpenSSL 可识别的私钥。"
  return 1
}
cert_identifier=$(printf '%s' "$certym" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
if [ -z "$cert_identifier" ]; then
  cert_identifier=$(openssl x509 -noout -ext subjectAltName -in "$certcrt" 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS:[[:space:]]*//p' | head -n 1 | tr -d '[:space:]')
fi
if [ -z "$cert_identifier" ]; then
  cert_identifier=$(openssl x509 -noout -ext subjectAltName -in "$certcrt" 2>/dev/null | tr ',' '\n' | sed -n 's/.*IP Address:[[:space:]]*//p' | head -n 1 | tr -d '[:space:]')
fi
if [ -z "$cert_identifier" ]; then
  cert_identifier=$(openssl x509 -noout -subject -in "$certcrt" 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p' | tr -d '[:space:]')
fi
if [ -z "$cert_identifier" ]; then
  echo "错误：无法从外部证书提取 SAN/CN；请同时设置 certym 指定客户端 SNI。"
  return 1
fi
if ! valid_ip "$cert_identifier" && ! valid_domain "$cert_identifier"; then
  echo "错误：外部证书需要一个具体的域名或 IP 作为 SNI；泛域名证书请通过 certym 指定实际子域名。"
  return 1
fi
if ! validate_certificate_bundle "$certcrt" "$certkey" external "$cert_identifier"; then
  echo "错误：外部证书已过期、与私钥不匹配，或不包含 certym=$cert_identifier。"
  return 1
fi
if ! openssl verify -purpose sslserver -untrusted "$certcrt" "$certcrt" >/dev/null 2>&1; then
  echo "错误：外部证书未通过系统信任库校验；请使用完整的受信任服务器证书链。"
  return 1
fi
cp "$certcrt" "$acme_cert_file" && cp "$certkey" "$acme_key_file" || return 1
chmod 600 "$acme_key_file" 2>/dev/null
echo "$cert_identifier" > "$HOME/agsbx/sni.txt"
echo "ca" > "$HOME/agsbx/cert_mode"
record_cert_source "external" "$cert_identifier"
record_tls_cert_paths "$acme_cert_file" "$acme_key_file"
tls_cert_source="外部导入的受信任证书"
}
reuse_existing_trusted_certificate(){
local wanted_type="$1"
shift
local acme_cert_file="$HOME/agsbx/acmecer/cert.pem"
local acme_key_file="$HOME/agsbx/acmecer/private.key"
local source identifier validation_source
[ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" = ca ] || return 1
[ -s "$acme_cert_file" ] && [ -s "$acme_key_file" ] || return 1
source=$(cat "$HOME/agsbx/cert_source" 2>/dev/null)
[ -n "$source" ] || source=acme-http
case "$source" in
  acme-ip|acme-http|acme-alpn|acme-dns) ;;
  external) openssl verify -purpose sslserver -untrusted "$acme_cert_file" "$acme_cert_file" >/dev/null 2>&1 || return 1 ;;
  *) return 1 ;;
esac
identifier=$(cat "$HOME/agsbx/cert_identifier" 2>/dev/null)
[ -n "$identifier" ] || identifier=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
[ "$sub" != yes ] || validate_public_certificate "$acme_cert_file" "$acme_key_file" "$identifier" || return 1
validation_source="$source"
[ "$sub" != yes ] || validation_source=subscription
if [ "$#" -eq 0 ]; then
  case "$wanted_type" in
    ip) valid_ip "$identifier" || return 1 ;;
    domain) valid_domain "$identifier" || return 1 ;;
  esac
  validate_certificate_bundle "$acme_cert_file" "$acme_key_file" "$validation_source" || return 1
else
  validate_certificate_bundle "$acme_cert_file" "$acme_key_file" "$validation_source" "$@" || return 1
fi
tls_cert_file="$acme_cert_file"
tls_key_file="$acme_key_file"
echo "ca" > "$HOME/agsbx/cert_mode"
record_cert_source "$source" "$identifier"
record_tls_cert_paths "$acme_cert_file" "$acme_key_file"
atomic_text_file "$HOME/agsbx/sni.txt" "$identifier" || return 1
case "$source" in acme-*) register_acme_cron ;; esac
tls_cert_source="本地已有且有效的受信任证书"
echo "检测到本地已有有效证书，直接复用，避免重复申请触发 CA 限制。"
}
choose_acme_mode(){
local requested choice
requested=$(printf '%s' "$acmemode" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
if [ "${acme_force_menu:-no}" != yes ]; then
  if [ -z "$requested" ]; then
    case "$(printf '%s' "$certdns" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
      cf|cloudflare) requested=dns ;;
    esac
  fi
  [ -z "$requested" ] && [ -n "$certip" ] && requested=ip
  [ -z "$requested" ] && [ -n "$certym" ] && requested=http
fi
if [ -z "$requested" ]; then
  if [ ! -t 0 ]; then
    echo "错误：非交互运行启用了 ACME，但未设置 acmemode/certip/certym/certdns。"
    return 1
  fi
  echo ""
  printf '%s\n' "${C_CYAN}请选择 acme.sh 证书申请方式：${C_RESET}"
  echo "1. IP 短期证书：HTTP-01，需公网 80/TCP 可达"
  echo "2. 域名证书：HTTP-01，域名需指向本机且 80/TCP 可达"
  echo "3. 域名证书：TLS-ALPN-01，域名需指向本机且 443/TCP 可达"
  echo "4. Cloudflare DNS-01：无需开放 80/443，可申请泛域名"
  echo "0. 终止本次安装"
  printf "请输入数字 [0-4]：" >&2
  read -r choice
  requested="$choice"
fi
case "$requested" in
  1|ip|ip-http) acme_mode_selected=ip ;;
  2|http|standalone|domain) acme_mode_selected=http ;;
  3|alpn|tls-alpn) acme_mode_selected=alpn ;;
  4|dns|cf|cloudflare) acme_mode_selected=dns ;;
  0|abort|quit) return 2 ;;
  *)
    echo "错误：不支持的 acmemode=$requested；可选 ip/http/alpn/dns。"
    return 1
    ;;
esac
}
setup_acme_certificate(){
local mode="$1"
local acme_script="$HOME/agsbx/acme.sh"
local acme_home="$HOME/agsbx/acme"
local acme_cert_file="$HOME/agsbx/acmecer/cert.pem"
local acme_key_file="$HOME/agsbx/acmecer/private.key"
local acme_log="$HOME/agsbx/acme_issue.log"
local input identifier source required_port reload_cmd cf_prompted=no index
local ca_index ca_server ca_label ca_status
local ca_timeout register_timeout=15 selected_ca="" default_ca_server zerossl_ca_conf sslcom_ca_conf ca_succeeded=no
local -a identifiers issue_args register_args ca_servers ca_labels
mkdir -p "$HOME/agsbx/acmecer" "$acme_home"
chmod 700 "$acme_home" 2>/dev/null
case "$mode" in
  ip)
    input=$(printf '%s' "$certip" | tr ',' ' ')
    if [ -z "$(printf '%s' "$input" | tr -d '[:space:]')" ]; then
      if [ ! -t 0 ]; then
        echo "错误：IP 证书模式缺少 certip。"
        return 1
      fi
      printf "请输入一个或两个公网 IP（空格分隔）：" >&2
      read -r input
    fi
    read -r -a identifiers <<< "$input"
    if [ "${#identifiers[@]}" -lt 1 ] || [ "${#identifiers[@]}" -gt 2 ]; then
      echo "错误：certip 只能包含一个或两个公网 IP。"
      return 1
    fi
    for index in "${!identifiers[@]}"; do
      identifier="${identifiers[$index]}"
      identifier=${identifier#[}
      identifier=${identifier%]}
      valid_ip "$identifier" || {
        echo "错误：certip 中包含无效 IP：$identifier"
        return 1
      }
      identifiers[$index]="$identifier"
    done
    certip="${identifiers[*]}"
    required_port=80
    source=acme-ip
    ;;
  http|alpn|dns)
    identifier=$(printf '%s' "$certym" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    if [ -z "$identifier" ]; then
      if [ ! -t 0 ]; then
        echo "错误：$mode 模式缺少 certym。"
        return 1
      fi
      printf "请输入申请证书的域名：" >&2
      read -r identifier
      identifier=$(printf '%s' "$identifier" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    fi
    if [ "${identifier#\*.}" != "$identifier" ]; then
      if [ "$mode" != dns ]; then
        echo "错误：泛域名证书只能通过 DNS-01 申请，请改选模式 4。"
        return 1
      fi
      certwild=y
      identifier=${identifier#\*.}
    fi
    valid_domain "$identifier" || {
      echo "错误：certym=$identifier 不是有效域名。"
      return 1
    }
    certym="$identifier"
    identifiers=("$identifier")
    case "$mode" in
      http) required_port=80; source=acme-http ;;
      alpn) required_port=443; source=acme-alpn ;;
      dns)
        required_port=""
        source=acme-dns
        if [ -z "$certwild" ] && [ -t 0 ]; then
          printf "是否同时申请 *.$identifier 泛域名证书？[y/N]：" >&2
          read -r certwild
        fi
        is_yes "$certwild" && identifiers+=("*.$identifier")
        ;;
    esac
    ;;
  *)
    echo "错误：未知 ACME 模式：$mode"
    return 1
    ;;
esac
if [ -n "$required_port" ] && port_is_listening "$required_port"; then
  echo "错误：$mode 模式需要独占 $required_port/TCP，但该端口当前已被占用。"
  echo "脚本不会停止现有服务；请释放端口，或改选 Cloudflare DNS-01。"
  return 1
fi
if [ "$mode" != dns ]; then
  install_socat_if_needed || {
    echo "错误：$mode 模式需要 socat，自动安装失败。"
    return 1
  }
fi
if [ "$mode" = dns ]; then
  CF_Token=${CF_Token:-}
  CF_Account_ID=${CF_Account_ID:-}
  CF_Zone_ID=${CF_Zone_ID:-}
  CF_Key=${CF_Key:-}
  CF_Email=${CF_Email:-}
  if [ -z "$CF_Token" ] && { [ -z "$CF_Key" ] || [ -z "$CF_Email" ]; }; then
    if [ ! -t 0 ]; then
      echo "错误：Cloudflare DNS-01 缺少 CF_Token，或 CF_Key + CF_Email。"
      return 1
    fi
    printf "请输入 Cloudflare API Token（Zone.DNS 编辑权限，输入不回显）：" >&2
    read -r -s CF_Token
    echo >&2
    cf_prompted=yes
  fi
  if [ -z "$CF_Token" ] && { [ -z "$CF_Key" ] || [ -z "$CF_Email" ]; }; then
    echo "错误：Cloudflare DNS-01 凭据不完整。"
    return 1
  fi
  if [ "$cf_prompted" = yes ]; then
    printf "Cloudflare Account ID（可选，回车自动发现 Zone）：" >&2
    read -r CF_Account_ID
    printf "Cloudflare Zone ID（可选，回车自动发现）：" >&2
    read -r CF_Zone_ID
  fi
  # 凭据仅由下面的 ACME 子进程按需继承。
  echo "ACME 验证方式：Cloudflare DNS-01；域名须由 Cloudflare 权威 DNS 托管，无需 A/AAAA 指向本机。"
elif [ "$mode" = alpn ]; then
  echo "ACME 验证方式：TLS-ALPN-01；域名须指向本机，公网 443/TCP 必须可达。"
else
  echo "ACME 验证方式：HTTP-01；申请标识须指向本机，公网 80/TCP 必须可达。"
fi
ensure_official_acme "$mode" || return 1
ca_timeout=$(printf '%s' "$acmetimeout" | tr -d '[:space:]')
if [ -z "$ca_timeout" ]; then
  if [ "$mode" = dns ]; then
    ca_timeout=120
  else
    ca_timeout=60
  fi
fi
case "$ca_timeout" in
  ''|*[!0-9]*)
    echo "错误：acmetimeout 必须是 5-600 之间的整数秒。"
    return 1
    ;;
esac
if [ "$ca_timeout" -lt 5 ] || [ "$ca_timeout" -gt 600 ]; then
  echo "错误：acmetimeout=$ca_timeout 超出允许范围 5-600 秒。"
  return 1
fi
command -v timeout >/dev/null 2>&1 || {
  echo "错误：系统缺少 timeout 命令，无法安全执行多 CA 超时切换。"
  return 1
}

# IP 短期证书使用 Let's Encrypt 的 shortlived profile；TLS-ALPN 也只使用已确认兼容的 CA。
# 普通 HTTP-01 与 DNS-01 才启用三家 CA 容灾，顺序固定为 Let's Encrypt、ZeroSSL、SSL.com。
case "$mode" in
  ip|alpn)
    ca_servers=(letsencrypt)
    ca_labels=("Let's Encrypt")
    echo "ACME CA：$mode 模式仅使用已确认兼容的 Let's Encrypt。"
    ;;
  *)
    ca_servers=(letsencrypt zerossl sslcom)
    ca_labels=("Let's Encrypt" "ZeroSSL" "SSL.com")
    echo "ACME CA优先级：Let's Encrypt → ZeroSSL → SSL.com；注册上限 ${register_timeout} 秒，签发上限 ${ca_timeout} 秒。"
    if [ -z "$acmem" ] && [ -t 0 ]; then
      printf "请输入 ACME 注册邮箱（ZeroSSL/SSL.com 备用需要；回车则缺少凭据时跳过）：" >&2
      read -r acmem
      acmem=$(printf '%s' "$acmem" | tr -d '[:space:]')
    fi
    ;;
esac

: > "$acme_log"
for ca_index in "${!ca_servers[@]}"; do
  ca_server="${ca_servers[$ca_index]}"
  ca_label="${ca_labels[$ca_index]}"

  if [ "$ca_server" = zerossl ]; then
    zerossl_ca_conf="$acme_home/ca/acme.zerossl.com/v2/DV90/ca.conf"
    if [ -z "$acmem" ] && ! grep -q '^CA_EAB_KEY_ID=' "$zerossl_ca_conf" 2>/dev/null; then
      echo "跳过 ZeroSSL：首次注册未提供 acmem，无法自动获取 EAB 凭据。"
      printf '\n===== 跳过 ZeroSSL：首次注册缺少 acmem =====\n' >> "$acme_log"
      continue
    fi
  fi
  if [ "$ca_server" = sslcom ]; then
    sslcom_ca_conf="$acme_home/ca/acme.ssl.com/sslcom-dv-ecc/ca.conf"
    if ! { grep -q '^CA_EAB_KEY_ID=' "$sslcom_ca_conf" 2>/dev/null && grep -q '^CA_EAB_HMAC_KEY=' "$sslcom_ca_conf" 2>/dev/null; } \
      && { [ -z "$sslcom_eab_kid" ] || [ -z "$sslcom_eab_hmac" ]; } && [ -t 0 ]; then
      echo "SSL.com 作为第三备用 CA 需要预先从 SSL.com 账户获取 EAB 凭据。"
      if [ -z "$sslcom_eab_kid" ]; then
        printf "SSL.com EAB Key ID（回车跳过该 CA）：" >&2
        read -r sslcom_eab_kid
      fi
      if [ -n "$sslcom_eab_kid" ] && [ -z "$sslcom_eab_hmac" ]; then
        printf "SSL.com EAB HMAC Key（输入不回显）：" >&2
        read -r -s sslcom_eab_hmac
        echo >&2
      fi
    fi
    if ! { grep -q '^CA_EAB_KEY_ID=' "$sslcom_ca_conf" 2>/dev/null && grep -q '^CA_EAB_HMAC_KEY=' "$sslcom_ca_conf" 2>/dev/null; }; then
      if [ -z "$acmem" ]; then
        echo "跳过 SSL.com：首次注册缺少 acmem。"
        printf '\n===== 跳过 SSL.com：首次注册缺少邮箱 =====\n' >> "$acme_log"
        continue
      fi
      if [ -z "$sslcom_eab_kid" ] || [ -z "$sslcom_eab_hmac" ]; then
        echo "跳过 SSL.com：缺少 SSL.com EAB 凭据。"
        printf '\n===== 跳过 SSL.com：缺少 EAB 凭据 =====\n' >> "$acme_log"
        continue
      fi
      case "$sslcom_eab_kid" in
        *[!A-Za-z0-9_-]*)
          echo "跳过 SSL.com：EAB Key ID 含有非法字符。"
          continue
          ;;
      esac
      case "$sslcom_eab_hmac" in
        *[!A-Za-z0-9_=-]*)
          echo "跳过 SSL.com：EAB HMAC Key 不是有效的 Base64URL 字符串。"
          continue
          ;;
      esac
      (
        umask 077
        mkdir -p "$(dirname "$sslcom_ca_conf")" || exit 1
        printf "CA_EAB_KEY_ID='%s'\nCA_EAB_HMAC_KEY='%s'\n" "$sslcom_eab_kid" "$sslcom_eab_hmac" >> "$sslcom_ca_conf"
      ) || {
        echo "跳过 SSL.com：无法安全写入 EAB 配置。"
        continue
      }
      chmod 600 "$sslcom_ca_conf" 2>/dev/null
    fi
    if ! grep -q '^CA_EAB_KEY_ID=' "$sslcom_ca_conf" 2>/dev/null || ! grep -q '^CA_EAB_HMAC_KEY=' "$sslcom_ca_conf" 2>/dev/null; then
      echo "跳过 SSL.com：缺少 acmem 或 SSL.com EAB 凭据。"
      printf '\n===== 跳过 SSL.com：缺少邮箱或 EAB 凭据 =====\n' >> "$acme_log"
      continue
    fi
  fi

  echo "正在尝试 $ca_label（注册最多 ${register_timeout} 秒，签发最多 ${ca_timeout} 秒）..."
  printf '\n===== CA 尝试：%s；注册超时：%s 秒；签发超时：%s 秒 =====\n' "$ca_label" "$register_timeout" "$ca_timeout" >> "$acme_log"
  register_args=(bash "$acme_script" --home "$acme_home" --register-account --server "$ca_server")
  [ -n "$acmem" ] && register_args+=(-m "$acmem")
  [ "$ca_server" = sslcom ] && register_args+=(--ecc)
  ( export CF_Token CF_Account_ID CF_Zone_ID CF_Key CF_Email; timeout -k 2 "$register_timeout" "${register_args[@]}" 8>&- ) >> "$acme_log" 2>&1
  ca_status=$?
  if [ "$ca_server" = sslcom ]; then
    unset sslcom_eab_kid sslcom_eab_hmac
  fi
  if [ "$ca_status" -ne 0 ]; then
    if [ "$ca_status" -eq 124 ] || [ "$ca_status" -eq 137 ]; then
      echo "$ca_label 注册超时，切换下一家 CA。"
    else
      echo "$ca_label 账户注册失败，切换下一家 CA。"
    fi
    continue
  fi

  issue_args=(--home "$acme_home" --issue --server "$ca_server" --keylength ec-256)
  case "$mode" in
    ip)
      issue_args+=(--standalone --certificate-profile shortlived --days 4)
      ;;
    http) issue_args+=(--standalone) ;;
    alpn) issue_args+=(--alpn) ;;
    dns) issue_args+=(--dns dns_cf) ;;
  esac
  for identifier in "${identifiers[@]}"; do
    issue_args+=(-d "$identifier")
  done
  ( export CF_Token CF_Account_ID CF_Zone_ID CF_Key CF_Email; timeout -k 2 "$ca_timeout" bash 8>&- "$acme_script" "${issue_args[@]}" ) >> "$acme_log" 2>&1
  ca_status=$?
  if [ "$ca_status" -eq 0 ]; then
    ca_succeeded=yes
    selected_ca="$ca_label"
    default_ca_server="$ca_server"
    [ "$ca_server" = sslcom ] && default_ca_server="https://acme.ssl.com/sslcom-dv-ecc"
    bash 8>&- "$acme_script" --home "$acme_home" --set-default-ca --server "$default_ca_server" >> "$acme_log" 2>&1 || true
    echo "$default_ca_server" > "$HOME/agsbx/acme_ca"
    echo "$ca_label 签发成功。"
    break
  fi
  if [ "$ca_status" -eq 124 ] || [ "$ca_status" -eq 137 ]; then
    echo "$ca_label 在 ${ca_timeout} 秒内未完成签发，切换下一家 CA。"
  else
    echo "$ca_label 签发失败，切换下一家 CA。"
  fi
done
chmod 600 "$acme_home/account.conf" 2>/dev/null
if [ "$ca_succeeded" != yes ]; then
  echo "错误：所有可用 ACME CA 均未完成签发，详情见 $acme_log"
  return 1
fi
identifier="${identifiers[0]}"
reload_cmd="true"
bash 8>&- "$acme_script" --home "$acme_home" --install-cert -d "$identifier" --ecc --fullchain-file "$acme_cert_file" --key-file "$acme_key_file" --reloadcmd "$reload_cmd" >> "$acme_log" 2>&1 || return 1
if ! validate_certificate_bundle "$acme_cert_file" "$acme_key_file" "$source" "${identifiers[@]}"; then
  echo "错误：ACME 已签发，但运行目录中的证书未通过有效期、SAN 或私钥匹配校验，详情见 $acme_log"
  return 1
fi
[ "$sub" != yes ] || validate_public_certificate "$acme_cert_file" "$acme_key_file" "$identifier" || {
  echo "错误：新证书未通过系统信任库校验，不能用于订阅分享。"
  return 1
}
chmod 600 "$acme_key_file" 2>/dev/null
register_acme_cron || return 1
unset CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID
echo "$identifier" > "$HOME/agsbx/sni.txt"
echo "ca" > "$HOME/agsbx/cert_mode"
record_cert_source "$source" "$identifier"
record_tls_cert_paths "$acme_cert_file" "$acme_key_file"
tls_cert_source="ACME 自动申请成功（$selected_ca）"
}
setup_tls_certificate(){
  local reuse_cert reuse_key reuse_identifier wanted wanted_type mode_hint dns_requested=no reuse_allowed=yes acme_requested=no choose_status retry_choice index
  local -a wanted_identifiers
  if [ "$tls_cert_ready" = yes ]; then
    [ -s "$tls_cert_file" ] && [ -s "$tls_key_file" ] || {
      echo "错误：TLS 就绪标记与证书文件不一致，已停止生成配置。"
      return 1
    }
    if [ "$sub" = yes ] && ! { cert_trusted "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" \
      && validate_public_certificate "$tls_cert_file" "$tls_key_file" "$(cat "$HOME/agsbx/cert_identifier" 2>/dev/null)"; }; then
      tls_cert_ready=no
    else
      if [ "${tls_caddy_reuse_notice_shown:-no}" != yes ] \
        && [ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" = caddy ]; then
        echo "TLS证书模式：复用 Caddy(naive) 已签发的真实证书"
        tls_caddy_reuse_notice_shown=yes
      fi
      return 0
    fi
  fi
  # Caddy 内置 ACME 仍保持最高优先级；新进程复用磁盘上的既有证书时重新校验一次，
  # 同一进程内刚由 installcaddy 校验通过的证书则由 tls_cert_ready 直接复用。
  if [ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" = caddy ]; then
    reuse_cert=$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)
    reuse_key=$(cat "$HOME/agsbx/key_file_path" 2>/dev/null)
    reuse_identifier=$(cat "$HOME/agsbx/cert_identifier" 2>/dev/null)
    [ -n "$reuse_identifier" ] || reuse_identifier=$(cat "$HOME/agsbx/naive_domain" 2>/dev/null)
    if [ -n "$reuse_identifier" ] && validate_certificate_bundle "$reuse_cert" "$reuse_key" caddy "$reuse_identifier" \
      && { [ "$sub" != yes ] || validate_public_certificate "$reuse_cert" "$reuse_key" "$reuse_identifier"; }; then
      tls_cert_file="$reuse_cert"
      tls_key_file="$reuse_key"
      record_cert_source caddy "$reuse_identifier" && record_tls_cert_paths "$reuse_cert" "$reuse_key" \
        && atomic_text_file "$HOME/agsbx/sni.txt" "$reuse_identifier" && write_cert_fingerprint || return 1
      echo "TLS证书模式：复用 Caddy(naive) 已签发的真实证书"
      tls_caddy_reuse_notice_shown=yes
      show_tls_cert_summary "复用 Caddy(naive) 已签发证书" "$(cat "$HOME/agsbx/naive_domain" 2>/dev/null)"
      tls_cert_ready=yes
      return 0
    fi
    if [ "$rep_mode" = yes ] && [ "$sub" != yes ]; then
      echo "错误：rep 保留的 Caddy 证书未通过有效期、SAN 或私钥匹配校验。"
      echo "如需更换或重新申请 Caddy 证书，请先执行 agsbx del，再重新运行脚本。"
      return 1
    fi
  fi
  # 订阅优先复用已有 CA；GUI 中的申请/导入方案仅在没有可复用 CA 时生效。
  if [ "$sub" = yes ] && reuse_existing_trusted_certificate '' && write_cert_fingerprint; then
    echo "TLS证书模式：订阅与节点复用已有公信 CA 证书"
    show_tls_cert_summary "$tls_cert_source" "$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)"
    tls_cert_ready=yes
    return 0
  fi
  # 调用位置已经确认需要 TLS；协议标志在装配过程中会变成展示名称，不能据此跳过证书。
  if ! command -v openssl >/dev/null 2>&1; then
    echo "错误：系统未安装 openssl，无法准备 TLS 证书。"
    echo "请先安装 openssl 后重试：apt install openssl 或 yum install openssl"
    exit 1
  fi
  # 显式导入的证书优先于独立 acme.sh 证书；缺一项或校验失败时直接终止，避免悄悄换成其他证书。
  if [ -n "$certcrt" ] || [ -n "$certkey" ]; then
    if setup_external_certificate && write_cert_fingerprint; then
      echo "TLS证书模式：外部导入的受信任证书"
      show_tls_cert_summary "$tls_cert_source" "$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)"
      tls_cert_ready=yes
      return 0
    fi
    echo "错误：外部证书导入失败，终止安装。"
    exit 1
  fi
  wanted=""
  wanted_type=""
  mode_hint=$(printf '%s' "$acmemode" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  case "$mode_hint" in
    1|ip|ip-http) wanted_type=ip ;;
    2|http|standalone|domain|3|alpn|tls-alpn|4|dns|cf|cloudflare) wanted_type=domain ;;
  esac
  case "$mode_hint" in 4|dns|cf|cloudflare) dns_requested=yes ;; esac
  case "$(printf '%s' "$certdns" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
    cf|cloudflare) wanted_type=domain; dns_requested=yes ;;
  esac
  if [ -n "$certip" ]; then
    wanted_type=ip
    read -r -a wanted_identifiers <<< "$(printf '%s' "$certip" | tr ',' ' ')"
    if [ "${#wanted_identifiers[@]}" -lt 1 ] || [ "${#wanted_identifiers[@]}" -gt 2 ]; then
      reuse_allowed=no
    fi
    for index in "${!wanted_identifiers[@]}"; do
      wanted="${wanted_identifiers[$index]}"
      wanted=${wanted#[}
      wanted=${wanted%]}
      wanted_identifiers[$index]="$wanted"
    done
  elif [ -n "$certym" ]; then
    wanted_type=domain
    wanted=$(printf '%s' "$certym" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    if [ "${wanted#\*.}" != "$wanted" ]; then
      if [ "$dns_requested" = yes ]; then
        wanted=${wanted#\*.}
        wanted_identifiers=("$wanted" "*.$wanted")
      else
        reuse_allowed=no
      fi
    else
      wanted_identifiers=("$wanted")
      if [ "$dns_requested" = yes ] && is_yes "$certwild"; then
        wanted_identifiers+=("*.$wanted")
      fi
    fi
  elif [ "$dns_requested" = yes ] && is_yes "$certwild"; then
    reuse_allowed=no
  fi
  if [ "$sub" != yes ] && [ "$reuse_allowed" = yes ] && reuse_existing_trusted_certificate "$wanted_type" "${wanted_identifiers[@]}" && write_cert_fingerprint; then
    echo "TLS证书模式：复用本地受信任证书"
    show_tls_cert_summary "$tls_cert_source" "$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)"
    tls_cert_ready=yes
    return 0
  fi
  if [ "$rep_mode" = yes ] && [ "$sub" != yes ] && [ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" = ca ]; then
    echo "错误：rep 保留的 ACME/外部受信任证书未通过复用验证。"
    echo "如需更换或重新申请证书，请先执行 agsbx del，再重新运行脚本。"
    return 1
  fi
  is_yes "$alns" && acme_requested=yes
  [ -n "$acmemode" ] && acme_requested=yes
  [ -n "$certip" ] && acme_requested=yes
  [ -n "$certym" ] && acme_requested=yes
  [ -n "$certdns" ] && acme_requested=yes
  if [ "$sub" = yes ]; then
    acme_requested=yes
    echo "订阅分享需要公信 CA 证书，未找到可复用证书，将申请 IP 或域名证书。"
    # CDN 回源已经给出了明确域名；无显式方案时默认申请此域名的 HTTP-01 证书。
    if [ -n "$cdnym" ] && [ -z "$certym" ] && [ -z "$certip" ] && [ -z "$acmemode" ]; then certym="$cdnym"; fi
  fi
  if [ "$acme_requested" = yes ]; then
    acme_force_menu=no
    while :; do
      choose_acme_mode
      choose_status=$?
      if [ "$choose_status" -eq 2 ]; then
        echo "已取消 ACME 证书申请，安装终止。"
        exit 1
      elif [ "$choose_status" -ne 0 ]; then
        if [ -t 0 ]; then
          echo "请重新选择有效的 ACME 申请方式。"
          acmemode=""
          acme_force_menu=yes
          continue
        fi
        echo "错误：无法确定 ACME 申请方式，安装终止。"
        exit 1
      fi
      if setup_acme_certificate "$acme_mode_selected" && write_cert_fingerprint; then
        echo "TLS证书模式：ACME 受信任证书（$acme_mode_selected）"
        show_tls_cert_summary "$tls_cert_source" "$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)"
        tls_cert_ready=yes
        return 0
      fi
      echo "ACME 证书申请失败；按安全策略不会自动降级为自签证书。"
      if [ ! -t 0 ]; then
        echo "错误：非交互运行无法重新选择申请方式，安装终止。"
        exit 1
      fi
      printf "输入 y 返回方式菜单重试，其他输入终止安装：[y/N] " >&2
      read -r retry_choice
      if ! is_yes "$retry_choice"; then
        echo "ACME 证书未就绪，安装终止。"
        exit 1
      fi
      acmemode=""
      acme_force_menu=yes
    done
  fi
  if setup_selfsigned_certificate; then
    echo "TLS证书模式：自签证书 ($(cat "$HOME/agsbx/sni.txt" 2>/dev/null))"
    show_tls_cert_summary "OpenSSL 自签证书可用" "$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)"
    tls_cert_ready=yes
  else
    echo "错误：TLS 证书生成失败，终止安装。"
    exit 1
  fi
}
#============================================================
# [第5.5段] Hysteria 2 端口跳跃防火墙控制函数
#   setup_port_hopping()   - 创建专属 AGSBX_HY2 自定义链并追加 DNAT 规则
#   cleanup_port_hopping() - 彻底清除专属链及其所有规则
#============================================================
remove_legacy_hopping_persistence(){
  local path content temporary
  for path in /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/iptables/rules-save /etc/ip6tables/rules-save /var/lib/iptables/rules-save /var/lib/ip6tables/rules-save; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] || continue
    if grep -q 'AGSBX_HY2' "$path"; then :
    elif [ "$?" = 1 ]; then continue
    else echo "错误：无法读取防火墙持久化文件：$path"; return 1; fi
    [ ! -L "$path" ] || { echo "错误：历史跳跃规则位于符号链接中，已保留：$path"; return 1; }
    [ "$(stat -c '%u' "$path")" = 0 ] || return 1
    content=$(awk '
      $1 == ":AGSBX_HY2" {next}
      $1 == "-A" && $2 == "AGSBX_HY2" {next}
      $0 == "-A PREROUTING -p udp -j AGSBX_HY2" {next}
      $0 == "-A PREROUTING -p udp -m udp -j AGSBX_HY2" {next}
      {for(i=1;i<NF;i++) if (($i == "-j" || $i == "-g") && $(i+1) == "AGSBX_HY2") bad=1; print}
      END {exit bad}
    ' "$path") || { echo "错误：$path 有自定义跳跃链引用，已保留文件。"; return 1; }
    temporary=$(mktemp "${path%/*}/.agsbx-firewall.XXXXXX") || return 1
    if ! cp -p -- "$path" "$temporary" || ! printf '%s\n' "$content" > "$temporary" || ! mv -f -- "$temporary" "$path"; then
      rm -f -- "$temporary"; return 1
    fi
  done
}

setup_port_hopping(){
  local hop_ports="$1" target_port="$2" command path
  [ -n "$hop_ports" ] || return 0
  hop_ports=${hop_ports//:/-}
  xray_range_valid "$hop_ports" 1 65535 && valid_port "$target_port" || return 1
  local ipt_ports="${hop_ports//-/:}"
  command -v iptables >/dev/null 2>&1 || return 1
  if [ ! -f "$HOME/agsbx/hopping_managed" ] && [ ! -s "$HOME/agsbx/shyjpt" ] && [ ! -s "$HOME/agsbx/xhyjpt" ]; then
    for path in /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/iptables/rules-save /etc/ip6tables/rules-save /var/lib/iptables/rules-save /var/lib/ip6tables/rules-save; do
      if [ -f "$path" ] && grep -q 'AGSBX_HY2' "$path"; then echo "错误：发现归属不明的历史跳跃规则，请先核对：$path"; return 1; fi
    done
  fi
  for command in iptables ip6tables; do
    if ! command -v "$command" >/dev/null 2>&1; then
      [ -z "$v6" ] || { echo "错误：IPv6 跳跃规则需要 ip6tables。"; return 1; }
      continue
    fi
    if [ -z "$HOPPING_INITED" ]; then
      if "$command" -t nat -S AGSBX_HY2 >/dev/null 2>&1; then
        [ -f "$HOME/agsbx/hopping_managed" ] || [ -s "$HOME/agsbx/shyjpt" ] || [ -s "$HOME/agsbx/xhyjpt" ] \
          || { echo "错误：保留归属不明的 AGSBX_HY2 链。"; return 1; }
        "$command" -t nat -F AGSBX_HY2 || return 1
      else
        "$command" -t nat -N AGSBX_HY2 || return 1
      fi
      printf '%s\n' AIRGOSBX_HOPPING_V1 > "$HOME/agsbx/hopping_managed" || return 1
      "$command" -t nat -C PREROUTING -p udp -j AGSBX_HY2 2>/dev/null \
        || "$command" -t nat -I PREROUTING -p udp -j AGSBX_HY2 || return 1
    fi
    "$command" -t nat -A AGSBX_HY2 -p udp --dport "$ipt_ports" -j DNAT --to-destination ":$target_port" \
      && "$command" -t nat -C AGSBX_HY2 -p udp --dport "$ipt_ports" -j DNAT --to-destination ":$target_port" || return 1
  done
  HOPPING_INITED=yes
  remove_legacy_hopping_persistence || return 1
  local script_path
  script_path=$(managed_script_path) || return 1
  write_managed_cron AIRGOSBX_HOPPING "@reboot /bin/bash $script_path __restore_hops" || return 1
  echo "Hysteria2 跳跃规则已确认：$hop_ports -> $target_port"
}
cleanup_port_hopping(){
  local command
  [ -f "$HOME/agsbx/hopping_managed" ] || [ -s "$HOME/agsbx/shyjpt" ] || [ -s "$HOME/agsbx/xhyjpt" ] || return 0
  for command in iptables ip6tables; do
    if ! command -v "$command" >/dev/null 2>&1; then
      [ "$command" != iptables ] || { echo "错误：无法清理跳跃规则，缺少 iptables。"; return 1; }
      continue
    fi
    "$command" -t nat -S >/dev/null 2>&1 || return 1
    if "$command" -t nat -S AGSBX_HY2 >/dev/null 2>&1; then
      while "$command" -t nat -C PREROUTING -p udp -j AGSBX_HY2 >/dev/null 2>&1; do
        "$command" -t nat -D PREROUTING -p udp -j AGSBX_HY2 || return 1
      done
      "$command" -t nat -F AGSBX_HY2 && "$command" -t nat -X AGSBX_HY2 || return 1
    fi
  done
  remove_legacy_hopping_persistence || return 1
  unset HOPPING_INITED
  rm -f "$HOME/agsbx/hopping_managed"
}
save_xicmp_state(){
  [ -e "$HOME/agsbx/xicmp_enabled" ] && return
  if [ -r /proc/sys/net/ipv4/icmp_echo_ignore_all ]; then
    cat /proc/sys/net/ipv4/icmp_echo_ignore_all > "$HOME/agsbx/xicmp_echo_ignore_all.prev" 2>/dev/null
  fi
  echo "yes" > "$HOME/agsbx/xicmp_enabled"
}
restore_xicmp_state(){
  [ -e "$HOME/agsbx/xicmp_enabled" ] || return 0
  prev_xicmp=$(cat "$HOME/agsbx/xicmp_echo_ignore_all.prev" 2>/dev/null)
  case "$prev_xicmp" in
    0|1) sysctl -w net.ipv4.icmp_echo_ignore_all="$prev_xicmp" >/dev/null 2>&1 || return 1 ;;
    *) echo "错误：XICMP 原状态记录无效，已保留。"; return 1 ;;
  esac
  rm -f "$HOME/agsbx/xicmp_enabled" "$HOME/agsbx/xicmp_echo_ignore_all.prev"
}
installxray(){
echo
printf '%s\n' "${C_CYAN}=========启用xray内核=========${C_RESET}"
mkdir -p "$HOME/agsbx/xrk"
if [ ! -e "$HOME/agsbx/xray" ]; then
upxray || return 1
fi
[ -x "$HOME/agsbx/xray" ] || { echo "错误：Xray 内核不存在或不可执行。"; return 1; }
local xray_version
xray_version=$("$HOME/agsbx/xray" version 2>/dev/null | awk '/^Xray/{print $2}')
[[ "$xray_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$(vercmp "$xray_version" 26.3.27)" != lt ] \
  || { echo "错误：当前配置需要 Xray 26.3.27 或更新版本；请先更新核心。"; return 1; }
cat > "$HOME/agsbx/xr.json" <<EOF
{
  "log": {
  "loglevel": "none"
  },
  "dns": {
    "servers": [
      "https+local://dns.google/dns-query",
      "https+local://cloudflare-dns.com/dns-query",
      "8.8.8.8",
      "1.1.1.1"
    ]
  },
  "inbounds": [
EOF
insuuid || return 1
if [ -n "$xhp" ] || [ -n "$vlp" ]; then
if [ -z "$ym_vl_re" ]; then
ym_vl_re=$(get_reality_domain)
fi
echo "$ym_vl_re" > "$HOME/agsbx/ym_vl_re"
echo "Reality域名：$ym_vl_re"
if [ ! -e "$HOME/agsbx/xrk/private_key" ]; then
key_pair=$("$HOME/agsbx/xray" x25519)
private_key=$(echo "$key_pair" | awk -F':' '/PrivateKey/ {print $2}' | xargs)
public_key=$(echo "$key_pair" | awk -F':' '/Password/ {print $2}' | xargs)
short_id=$(date +%s%N | sha256sum | cut -c 1-8)
echo "$private_key" > "$HOME/agsbx/xrk/private_key"
echo "$public_key" > "$HOME/agsbx/xrk/public_key"
echo "$short_id" > "$HOME/agsbx/xrk/short_id"
fi
private_key_x=$(cat "$HOME/agsbx/xrk/private_key")
public_key_x=$(cat "$HOME/agsbx/xrk/public_key")
short_id_x=$(cat "$HOME/agsbx/xrk/short_id")
fi
if [ -n "$xhp" ] || [ -n "$vxp" ] || [ -n "$vwp" ] || [ "$xvcdn" = yes ] || [ "$xvargo" = yes ]; then
[ ! -L "$HOME/agsbx/xrk/dekey" ] && [ ! -L "$HOME/agsbx/xrk/enkey" ] || { echo "错误：ENC 密钥文件不能是符号链接。"; return 1; }
if [ ! -e "$HOME/agsbx/xrk/dekey" ] && [ ! -e "$HOME/agsbx/xrk/enkey" ]; then
vlkey=$("$HOME/agsbx/xray" vlessenc) || { echo "错误：无法生成 VLESS Encryption 密钥。"; return 1; }
dekey=$(echo "$vlkey" | grep '"decryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
enkey=$(echo "$vlkey" | grep '"encryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
case "$dekey:$enkey" in mlkem768x25519plus.*:mlkem768x25519plus.*) ;; *) echo "错误：核心输出的 ENC 密钥格式无法识别。"; return 1 ;; esac
printf '%s\n' "$dekey" > "$HOME/agsbx/xrk/dekey" && printf '%s\n' "$enkey" > "$HOME/agsbx/xrk/enkey" || return 1
fi
dekey=$(cat "$HOME/agsbx/xrk/dekey") && enkey=$(cat "$HOME/agsbx/xrk/enkey") || return 1
case "$dekey:$enkey" in mlkem768x25519plus.*:mlkem768x25519plus.*) ;; *) echo "错误：现有 ENC 密钥不完整，已停止生成配置。"; return 1 ;; esac
chmod 600 "$HOME/agsbx/xrk/dekey" "$HOME/agsbx/xrk/enkey" || return 1
fi

if [ -n "$xhp" ]; then
xhp=xhpt
port_xh=$(init_port "$port_xh" port_xh)
prepare_xray_profile xh || return 1
echo "VLESS Encryption＋XHTTP＋REALITY＋Vision 端口：$port_xh（extra=$xhextra，FM=$xhfm）"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag":"xhttp-reality",
      "listen": "${public_listen_address}",
      "port": ${port_xh},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(json_escape "$uuid")",
            "email": "agsbx-profile-xh-v2",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "dest": "${ym_vl_re}:443",
          "serverNames": [
            "${ym_vl_re}"
          ],
          "privateKey": "$private_key_x",
          "shortIds": ["$short_id_x"]
        },
        "xhttpSettings": {
          "path": "$(json_escape "$(transport_path xh)")",
          "mode": "$direct_server_mode"$direct_server_extra
        }$direct_server_fm
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    },
EOF
else
xhp=xhptargo
fi
if [ -n "$vxp" ]; then
vxp=vxpt
port_vx=$(init_port "$port_vx" port_vx)
prepare_xray_profile vx || return 1
echo "Vlessenc-xhttp-vision端口：$port_vx"
if [ -n "$cdnym" ]; then
echo "$cdnym" > "$HOME/agsbx/cdnym"
echo "80系CDN或者回源CDN的host域名 (确保IP已解析在CF域名)：$cdnym"
fi
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag":"vless-xhttp",
      "listen": "${public_listen_address}",
      "port": ${port_vx},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(json_escape "$uuid")",
            "email": "agsbx-profile-vx-v2",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$(json_escape "$(transport_path vx)")",
          "mode": "$direct_server_mode"$direct_server_extra
        }$direct_server_fm
      },
        "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    },
EOF
else
vxp=vxptargo
fi
if [ -n "$vwp" ]; then
vwp=vwpt
port_vw=$(init_port "$port_vw" port_vw)
prepare_xray_profile vw || return 1
echo "Vlessenc-ws-vision端口：$port_vw"
if [ -n "$cdnym" ]; then
echo "$cdnym" > "$HOME/agsbx/cdnym"
echo "80系CDN或者回源CDN的host域名 (确保IP已解析在CF域名)：$cdnym"
fi
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag":"vless-ws",
      "listen": "${public_listen_address}",
      "port": ${port_vw},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(json_escape "$uuid")",
            "email": "agsbx-profile-vw-v2",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$(json_escape "$(transport_path vw)")"
        }$direct_server_fm
      },
        "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    },
EOF
else
vwp=vwptargo
fi
if [ -n "$vlp" ]; then
vlp=vlpt
port_vl_re=$(init_port "$port_vl_re" port_vl_re)
prepare_xray_profile vl || return 1
echo "VLESS＋TCP/RAW＋REALITY＋Vision 端口：$port_vl_re（FM=$vlfm）"
cat >> "$HOME/agsbx/xr.json" <<EOF
        {
            "tag":"reality-vision",
            "listen": "${public_listen_address}",
            "port": $port_vl_re,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$(json_escape "$uuid")",
                        "email": "agsbx-profile-vl-v2",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "${ym_vl_re}:443",
                    "serverNames": [
                      "${ym_vl_re}"
                    ],
                    "privateKey": "$private_key_x",
                    "shortIds": ["$short_id_x"]
                }$direct_server_fm
            },
          "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"],
          "metadataOnly": false
      }
    },
EOF
else
vlp=vlptargo
fi
if [ "$xhyp" = yes ]; then
xhyp=xhypt
port_xhy2=$(init_port "$port_xhy2" port_xhy2)
setup_tls_certificate || return 1
prepare_xray_profile hy || return 1
[ -s "$tls_cert_file" ] && [ -s "$tls_key_file" ] || {
  echo "错误：Xray-Hysteria2 所需的 TLS 证书或私钥不可用，未写入入站。"
  return 1
}
echo "Xray-Hysteria2 端口：$port_xhy2（UDP FM=$xhyfm）"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "port": ${port_xhy2},
      "protocol": "hysteria",
      "tag": "hy2-xr",
      "settings": {
        "version": 2,
        "clients": [{"auth": "$(json_escape "$uuid")", "email": "agsbx-profile-hy-v2"}]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [{"certificateFile": "$tls_cert_file", "keyFile": "$tls_key_file"}]
        },
        "hysteriaSettings": {"version": 2}$direct_server_fm
      }
    },
EOF
else
xhyp=xhyptargo
fi
if [ "$xdns" = yes ]; then
if valid_domain "$xdnsym"; then
atomic_text_file "$HOME/agsbx/xdns_domain" "$xdnsym" || return 1
echo "$port_xdns" > "$HOME/agsbx/port_xdns"
echo "Vless-kcp-xdns-fm端口：$port_xdns"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "vless-kcp-xdns",
      "listen": "${public_listen_address}",
      "port": ${port_xdns},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(json_escape "$uuid")"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "kcp",
        "kcpSettings": {
          "uplinkCapacity": 5,
          "downlinkCapacity": 20,
          "congestion": true,
          "header": {
            "type": "none"
          }
        },
        "finalmask": {
          "udp": [
            {
              "type": "xdns",
              "settings": {
                "domains": ["${xdnsym}"]
              }
            }
          ]
        }
      }
    },
EOF
else
echo "警告：启用了 XDNS，但 xdnsym=$xdnsym 不是有效域名，已跳过 XDNS 配置。"
fi
fi
if [ "$xicp" = yes ]; then
save_xicmp_state
if command -v setcap >/dev/null 2>&1; then
setcap cap_net_raw+ep "$HOME/agsbx/xray" 2>/dev/null || echo "警告：XICMP 需要 CAP_NET_RAW，但 setcap 执行失败。"
else
echo "警告：系统未安装 setcap，XICMP 可能无法获得 CAP_NET_RAW 权限。"
fi
sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null 2>&1
echo "Vless-kcp-xicmp-fm 特种L3协议已激活✓"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "vless-kcp-xicmp",
      "listen": "${public_listen_address}",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(json_escape "$uuid")"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "kcp",
        "kcpSettings": {
          "uplinkCapacity": 5,
          "downlinkCapacity": 20,
          "congestion": true,
          "header": {
            "type": "none"
          }
        },
        "finalmask": {
          "udp": [
            {
              "type": "xicmp",
              "settings": {
                "listenIp": "0.0.0.0",
                "id": 0
              }
            }
          ]
        }
      }
    },
EOF
fi
if [ "$xvcdn" = yes ]; then
port_xvcdn=$(init_port "$port_xvcdn" port_xvcdn)
printf '%s\n' "$cdnym" > "$HOME/agsbx/cdnym" || return 1
setup_tls_certificate || return 1
[ -s "$tls_cert_file" ] && [ -s "$tls_key_file" ] || return 1
prepare_xray_profile xvd || return 1
echo "VLESS Encryption＋XHTTP＋TLS＋Vision CDN 端口：$port_xvcdn（客户端模式=$direct_client_mode）"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "vlessenc-xhttp-cdn",
      "listen": "${public_listen_address}",
      "port": ${port_xvcdn},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$(json_escape "$uuid")", "email": "agsbx-profile-xvd-v2", "flow": "xtls-rprx-vision"}],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2", "http/1.1"],
          "certificates": [{"certificateFile": "$tls_cert_file", "keyFile": "$tls_key_file"}]
        },
        "xhttpSettings": {
          "path": "$(json_escape "$(transport_path xvd)")",
          "mode": "$direct_server_mode"$direct_server_extra
        }
      }
    },
EOF
fi
if [ "$xvargo" = yes ]; then
port_xvargo=$(init_port "$port_xvargo" port_xvargo)
prepare_xray_profile xva || return 1
echo "VLESS Encryption＋XHTTP＋Vision Argo 回环端口：$port_xvargo（HTTP / packet-up）"
# 客户端到 Cloudflare 为 HTTPS；cloudflared 到同机回环端口为 HTTP。
# VLESS Encryption 保留端到端加密；本地不添加需要 cloudflared 解码的 FM。
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "vlessenc-xhttp-argo",
      "listen": "127.0.0.1",
      "port": ${port_xvargo},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$(json_escape "$uuid")", "email": "agsbx-profile-xva-v2", "flow": "xtls-rprx-vision"}],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "$(json_escape "$(transport_path xva)")",
          "mode": "packet-up"$direct_server_extra
        }
      }
    },
EOF
fi
# ------------------------------------------------------------
# 🎯 任务 H 模块 C：Xray-core TLS 卸载 Inbound 注入段
# - 功能描述：订阅使用 Trojan TLS fallback，固定回落到本机 HTTP 服务。
# - dokodemo-door 的原始连接拷贝路径不适合终止此 TLS，可能绕过响应加密。
# - 端口机制：
#   - subport (外部 HTTPS 端口，持久化于 subport.log)：供客户端从公网拉取订阅。
#   - subport_real (本地回源端口，持久化于 subport_real.log)：只监听在 127.0.0.1，防外网直连。
# - 关联映射：此处 dokodemo-door 反代的目标端口与最尾部 (L3120之后) 启动 busybox httpd 监听的真实端口强关联一致。
# ------------------------------------------------------------
if [ "$sub" = yes ] && [ "$subscription_core" = xray ]; then
subport=$(init_port "$subpt" subport.log)
subport_real=$(init_subport_real "$subport")
echo "Xray-core TLS fallback 订阅服务端口：$subport (内部回源端口：$subport_real)"
setup_tls_certificate || return 1
[ -s "$tls_cert_file" ] && [ -s "$tls_key_file" ] || return 1
local sub_tls_guard
sub_tls_guard=$(openssl rand -hex 32) || return 1
[[ "$sub_tls_guard" =~ ^[0-9a-f]{64}$ ]] || return 1
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "sub-https-proxy",
      "listen": "${public_listen_address}",
      "port": ${subport},
      "protocol": "trojan",
      "settings": {
        "clients": [{"password": "${sub_tls_guard}", "email": "subscription-fallback-guard"}],
        "fallbacks": [{"dest": "127.0.0.1:${subport_real}", "xver": 0}]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "$tls_cert_file",
              "keyFile": "$tls_key_file"
            }
          ]
        }
      }
    },
EOF
fi
}

installsb(){
echo
printf '%s\n' "${C_CYAN}=========启用sing-box内核=========${C_RESET}"
local min_sb_ver="1.12.0" local_sb_ver sb_version_state sub_tls_guard
if [ ! -e "$HOME/agsbx/sing-box" ]; then
upsingbox || return 1
else
  # 1.12.0 只是最低准入门槛，不是目标下载版本；upsingbox 不传版本时始终获取最新稳定版。
  # 当前脚本生成的配置要求稳定版 Sing-box >= 1.12.0。
  # 低于门槛或版本不可识别时先升级；升级失败或升级后仍不合格则停止，不能继续生成配置。
  local_sb_ver=$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}' | tr -d 'v')
  if printf '%s' "$local_sb_ver" | grep -Eq '^[0-9]+(\.[0-9]+){2}$'; then
    sb_version_state=$(vercmp "$local_sb_ver" "$min_sb_ver")
    if [ "$sb_version_state" = lt ]; then
      echo "检测到本地已有的 Sing-box 版本为 v$local_sb_ver（低于最低合格版本 v$min_sb_ver）。"
      echo "系统正在自动执行无人值守的平滑升级，以满足 Sing-box 1.12.0+ 配置要求..."
      upsingbox || return 1
    fi
  else
    echo "无法识别本地已有的 Sing-box 版本信息。"
    echo "系统正在自动执行无人值守的平滑升级，以满足 Sing-box 1.12.0+ 配置要求..."
    upsingbox || return 1
  fi
fi
local_sb_ver=$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}' | tr -d 'v')
if ! printf '%s' "$local_sb_ver" | grep -Eq '^[0-9]+(\.[0-9]+){2}$' || [ "$(vercmp "$local_sb_ver" "$min_sb_ver")" = lt ]; then
  echo "错误：当前 Sing-box 版本 v${local_sb_ver:-未知} 未达到最低合格版本 v$min_sb_ver，已停止生成配置。"
  return 1
fi
if secondary_protocol_is_selected naive && [ ! -s "$HOME/agsbx/sing-box" ]; then
  secondary_error "Naive 二级出站依赖 Sing-box sidecar，但内核未成功下载或不可用。"
  return 1
fi
cat > "$HOME/agsbx/sb.json" <<EOF
{
  "log": {
    "disabled": false,
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
EOF
insuuid || return 1
if [ "$sub" = yes ] && [ "$subscription_core" = singbox ]; then
subport=$(init_port "$subpt" subport.log)
subport_real=$(init_subport_real "$subport")
echo "Sing-box TLS fallback 订阅服务端口：$subport (内部回源端口：$subport_real)"
setup_tls_certificate || return 1
if [ ! -s "$tls_cert_file" ] || [ ! -s "$tls_key_file" ]; then
  echo "错误：Sing-box 订阅入站所需的 TLS 证书或私钥不可用。"
  return 1
fi
sub_tls_guard=$("$HOME/agsbx/sing-box" generate rand --hex 32 2>/dev/null)
if [ "${#sub_tls_guard}" -ne 64 ] || ! printf '%s' "$sub_tls_guard" | grep -Eq '^[0-9a-fA-F]+$'; then
  echo "错误：无法生成 Sing-box 订阅 fallback 防护凭据。"
  return 1
fi
cat >> "$HOME/agsbx/sb.json" <<EOF
    {
      "type": "trojan",
      "tag": "sub-https-proxy",
      "listen": "${public_listen_address}",
      "listen_port": ${subport},
      "users": [
        {
          "name": "subscription-fallback-guard",
          "password": "${sub_tls_guard}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["http/1.1"],
        "certificate_path": "$tls_cert_file",
        "key_path": "$tls_key_file"
      },
      "fallback": {
        "server": "127.0.0.1",
        "server_port": ${subport_real}
      }
    },
EOF
fi
if [ -n "$hyp" ]; then
hyp=hypt
insobfspass || return 1
port_hy2=$(init_port "$port_hy2" port_hy2)
echo "Hysteria2端口：$port_hy2"
setup_tls_certificate || return 1
cat >> "$HOME/agsbx/sb.json" <<EOF
    {
        "type": "hysteria2",
        "tag": "hy2-sb",
        "listen": "${public_listen_address}",
        "listen_port": ${port_hy2},
        "users": [
            {
                "password": "$(json_escape "$uuid")"
            }
        ],
        "ignore_client_bandwidth":false,
        "obfs": {
            "type": "salamander",
            "password": "$(json_escape "$obfs_pass")"
        },
        "tls": {
            "enabled": true,
            "alpn": [
                "h3"
            ],
            "certificate_path": "$tls_cert_file",
            "key_path": "$tls_key_file"
        }
    },
EOF
else
hyp=hyptargo
fi
if [ -n "$tup" ]; then
tup=tupt
port_tu=$(init_port "$port_tu" port_tu)
echo "Tuic端口：$port_tu"
setup_tls_certificate || return 1
cat >> "$HOME/agsbx/sb.json" <<EOF
        {
            "type":"tuic",
            "tag": "tuic5-sb",
            "listen": "${public_listen_address}",
            "listen_port": ${port_tu},
            "users": [
                {
                    "uuid": "$(json_escape "$uuid")",
                    "password": "$(json_escape "$uuid")"
                }
            ],
            "congestion_control": "bbr",
            "tls":{
                "enabled": true,
                "alpn": [
                    "h3"
                ],
                "certificate_path": "$tls_cert_file",
                "key_path": "$tls_key_file"
            }
        },
EOF
else
tup=tuptargo
fi
if [ -n "$anp" ]; then
anp=anpt
port_an=$(init_port "$port_an" port_an)
echo "Anytls端口：$port_an"
setup_tls_certificate || return 1
cat >> "$HOME/agsbx/sb.json" <<EOF
        {
            "type":"anytls",
            "tag":"anytls-sb",
            "listen":"${public_listen_address}",
            "listen_port":${port_an},
            "users":[
                {
                  "password":"$(json_escape "$uuid")"
                }
            ],
            "padding_scheme":[],
            "tls":{
                "enabled": true,
                "certificate_path": "$tls_cert_file",
                "key_path": "$tls_key_file"
            }
        },
EOF
else
anp=anptargo
fi
if [ -n "$arp" ]; then
arp=arpt
if [ -z "$ym_vl_re" ]; then
ym_vl_re=$(get_reality_domain)
fi
echo "$ym_vl_re" > "$HOME/agsbx/ym_vl_re"
echo "Reality域名：$ym_vl_re"
mkdir -p "$HOME/agsbx/sbk"
if [ ! -e "$HOME/agsbx/sbk/private_key" ]; then
key_pair=$("$HOME/agsbx/sing-box" generate reality-keypair)
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
short_id=$("$HOME/agsbx/sing-box" generate rand --hex 4)
echo "$private_key" > "$HOME/agsbx/sbk/private_key"
echo "$public_key" > "$HOME/agsbx/sbk/public_key"
echo "$short_id" > "$HOME/agsbx/sbk/short_id"
fi
private_key_s=$(cat "$HOME/agsbx/sbk/private_key")
public_key_s=$(cat "$HOME/agsbx/sbk/public_key")
short_id_s=$(cat "$HOME/agsbx/sbk/short_id")
port_ar=$(init_port "$port_ar" port_ar)
echo "Any-Reality端口：$port_ar"
cat >> "$HOME/agsbx/sb.json" <<EOF
        {
            "type":"anytls",
            "tag":"anyreality-sb",
            "listen":"${public_listen_address}",
            "listen_port":${port_ar},
            "users":[
                {
                  "password":"$(json_escape "$uuid")"
                }
            ],
            "padding_scheme":[],
            "tls": {
            "enabled": true,
            "server_name": "${ym_vl_re}",
             "reality": {
              "enabled": true,
              "handshake": {
              "server": "${ym_vl_re}",
              "server_port": 443
             },
             "private_key": "$private_key_s",
             "short_id": ["$short_id_s"]
            }
          }
        },
EOF
else
arp=arptargo
fi
if [ -n "$ssp" ]; then
ssp=sspt
if [ ! -e "$HOME/agsbx/sskey" ]; then
sskey=$("$HOME/agsbx/sing-box" generate rand 16 --base64)
echo "$sskey" > "$HOME/agsbx/sskey"
fi
port_ss=$(init_port "$port_ss" port_ss)
sskey=$(cat "$HOME/agsbx/sskey")
echo "Shadowsocks-2022端口：$port_ss"
cat >> "$HOME/agsbx/sb.json" <<EOF
        {
            "type": "shadowsocks",
            "tag":"ss-2022",
            "listen": "${public_listen_address}",
            "listen_port": $port_ss,
            "method": "2022-blake3-aes-128-gcm",
            "password": "$sskey"
    },
EOF
else
ssp=ssptargo
fi

# Caddy 解密 Naive 后仅通过独立凭据认证的回环 HTTP 代理转交；不开放任何新的公网监听。
if secondary_protocol_is_selected naive; then
secondary_validate_naive_credentials || return 1
naive_sidecar_user_json=$(json_escape "$naive_secondary_user")
naive_sidecar_pass_json=$(json_escape "$naive_secondary_pass")
cat >> "$HOME/agsbx/sb.json" <<EOF
    {
      "type": "http",
      "tag": "naive-secondary-in",
      "listen": "127.0.0.1",
      "listen_port": ${naive_secondary_port},
      "users": [
        {
          "username": "$naive_sidecar_user_json",
          "password": "$naive_sidecar_pass_json"
        }
      ]
    },
EOF
echo "Naive 二级代理本地转交端口：127.0.0.1:${naive_secondary_port}（HTTP CONNECT，仅 TCP）"
fi
}

installcaddy(){
echo
printf '%s\n' "${C_CYAN}=========启用 NaiveProxy(Caddy) 内核=========${C_RESET}"
# 关键参数（域名/伪装站/账号/密码）两种来源任选：环境变量预置，或交互终端按提示输入。
# naive=<域名> 既是开关也是域名；若传入的不是合法域名(如 naive=on)，交互终端会提示补输。
# NaiveProxy 必须有真实域名 + DNS 指向本机（不同于 reality 可裸 IP）。
local interactive_naive=0
if ! valid_domain "$naive"; then
if [ -t 1 ] || [ -t 2 ]; then
interactive_naive=1
while :; do
printf "请输入 NaiveProxy 域名（须已将 DNS A/AAAA 指向本机，直接回车=放弃）："; read -r naive
[ -z "$naive" ] && { echo "已放弃 NaiveProxy 安装。"; return 1; }
valid_domain "$naive" && break
echo "域名格式不正确，请重输。"
done
else
echo "错误：naive=$naive 不是合法域名。NaiveProxy 需要已解析到本机的真实域名，例如 naive=proxy.example.com。已跳过。"
return 1
fi
fi
# 交互模式(域名为现场输入)下，仅就伪装站给出可选提示；账号/密码统一交由 insnaivecred 处理，
# 避免与其重复提问（此前这里与 insnaivecred 各问一次用户名/密码，回车取默认时会被连问两遍）。
if [ "$interactive_naive" = 1 ]; then
[ -z "$naivesite" ] && { printf "伪装站域名（直接回车=默认 mirror.us.leaseweb.net）："; read -r naivesite; }
fi
# 在更新内核或覆盖配置前先确认 Airgosbx 专属服务名没有被其他软件占用。
if pidof systemd >/dev/null 2>&1 && is_root; then
  if { systemctl cat agsbx-caddy.service >/dev/null 2>&1 && [ ! -e /etc/systemd/system/agsbx-caddy.service ]; } || \
     [ -L /etc/systemd/system/agsbx-caddy.service ] || \
     { [ -e /etc/systemd/system/agsbx-caddy.service ] && ! grep -Fq "ExecStart=$HOME/agsbx/caddy run" /etc/systemd/system/agsbx-caddy.service; }; then
    echo "错误：agsbx-caddy.service 已存在但不属于 Airgosbx，已拒绝覆盖。"
    return 1
  fi
elif command -v rc-service >/dev/null 2>&1 && is_root; then
  if [ -L /etc/init.d/agsbx-caddy ] || \
     { [ -e /etc/init.d/agsbx-caddy ] && ! grep -Fq "command=\"$HOME/agsbx/caddy\"" /etc/init.d/agsbx-caddy; }; then
    echo "错误：OpenRC agsbx-caddy 服务已存在但不属于 Airgosbx，已拒绝覆盖。"
    return 1
  fi
fi
# 获取/编译 Caddy 二进制。已有内核默认复用；显式指定 naivebuild 或交互确认后，才更新到当时的最新版。
if [ -s "$HOME/agsbx/caddy" ]; then
  echo "检测到现有 Caddy(naive) 内核：$("$HOME/agsbx/caddy" version 2>/dev/null | head -1)"
  local refresh_caddy=no refresh_answer
  if [ -n "$naivebuild" ]; then
    refresh_caddy=yes
  elif [ -t 1 ] || [ -t 2 ]; then
    printf "是否重新获取并校验当前最新版 Caddy(naive)？[y/N]："; read -r refresh_answer
    case "$refresh_answer" in y|Y|yes|YES) refresh_caddy=yes ;; esac
  fi
  if [ "$refresh_caddy" = yes ]; then
    upcaddy || { echo "Caddy 最新版更新失败，原内核已保留，已停止本次 NaiveProxy 配置生成。"; return 1; }
  else
    echo "继续复用现有 Caddy(naive) 内核；如需非交互更新，可显式指定 naivebuild=dl 或 naivebuild=build。"
  fi
else
  upcaddy || { echo "NaiveProxy 内核未就位，已跳过 Caddy 配置。"; return 1; }
fi
insnaivecred
secondary_validate_naive_credentials || return 1
local naiveuser_caddy naivepass_caddy naive_upstream_user naive_upstream_pass
naiveuser_caddy=$(caddyfile_quote "$naiveuser")
naivepass_caddy=$(caddyfile_quote "$naivepass")
if secondary_protocol_is_selected naive; then
  naive_upstream_user=$(uri_percent_encode "$naive_secondary_user")
  naive_upstream_pass=$(uri_percent_encode "$naive_secondary_pass")
fi
# [80/443端口占用预检] Caddy 自管 ACME 与 Naive 入站需要这些端口；占用则告警，最终由服务启动结果判定成败。
if command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -qE ':(80|443)([[:space:]]|$)'; then
printf '%s\n' "${C_YELLOW}警告：检测到 80 或 443 端口已被占用，Caddy 证书申请或 NaiveProxy 启动可能失败。${C_RESET}"
echo "如有其它服务占用端口（如 nginx 或独立 Caddy），请先确认归属；Airgosbx 不会接管不属于自己的服务。"
fi
# 生成 Caddyfile（硬化模板：代理优先、私网 ACL、统一伪装响应、净化回源请求头）
local naivemail="${acmem:-admin@$naive}"
local naivesite="${naivesite:-mirror.us.leaseweb.net}"
local naivesite_regex
local caddyfile_tmp="$HOME/agsbx/.Caddyfile.new"
local caddy_admin_socket="$HOME/agsbx/caddy-admin.sock"
local caddy_admin_address="unix/$caddy_admin_socket"
# 容错：伪装站允许带或不带 scheme，统一剥离后由模板固定以 https 回源（伪装站须支持 HTTPS）
naivesite="${naivesite#http://}"; naivesite="${naivesite#https://}"
valid_domain "$naivesite" || { echo "错误：naivesite 必须是 HTTPS 伪装站域名，不含端口、路径或配置片段。"; return 1; }
[[ "$naivemail" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || { echo "错误：ACME 邮箱格式无效。"; return 1; }
# Location 改写使用 RE2 正则；域名中的点必须转义，避免被解释为任意字符。
naivesite_regex="${naivesite//./\\.}"
# 持久化域名：供后续 agsbx list 渲染节点卡片时读取（彼时 naive 环境变量已不在作用域）
echo "$naive" > "$HOME/agsbx/naive_domain"
cat > "$caddyfile_tmp" <<EOF
{
  # 认证代理请求必须最先进入 forward_proxy；未认证请求再落到后面的统一伪装站路由。
  order forward_proxy first
  # 管理 API 仅绑定在 /root/agsbx 的权限化 Unix socket；不再暴露默认 localhost:2019。
  admin ${caddy_admin_address}|0600
  storage file_system "$HOME/agsbx/caddy_storage"
  log {
    exclude http.log.error
  }
}
:443, $naive {
  tls $naivemail
  encode

  # 1. 防收录标记与基础指纹收敛；避免加入会改变源站正常浏览行为的额外响应策略。
  header {
    X-Robots-Tag "noindex, nofollow, noarchive"
    -Server
    -X-Powered-By
  }

  # 2. 本地拦截 robots.txt 请求，防止爬虫进一步探索
  handle /robots.txt {
    respond 200 {
      body "User-agent: *
Disallow: /"
      close
    }
  }

  # 3. 只拦截主动声明身份的常见爬虫；不把普通浏览器、命令行客户端或探针当作爬虫。
  @obvious_crawler header_regexp User-Agent (?i)(Googlebot|bingbot|Baiduspider|YandexBot|PetalBot|Applebot|DuckDuckBot|AhrefsBot|SemrushBot|MJ12bot|DotBot|BLEXBot|Bytespider|GPTBot|OAI-SearchBot|ClaudeBot|CCBot|Amazonbot|crawler|spider|scrapy)
  handle @obvious_crawler {
    respond 404
  }

  # 4. NaiveProxy 代理核心组件
  forward_proxy {
    basic_auth $naiveuser_caddy $naivepass_caddy
    hide_ip
    hide_via
    probe_resistance
EOF
if secondary_protocol_is_selected naive; then
cat >> "$caddyfile_tmp" <<EOF

    # Caddy 只负责 Naive/TLS 解密；目标地址通过唯一的回环 HTTP upstream 交给 Sing-box。
    # upstream 失败会直接失败，不保留 Caddy 直拨目标的回退路径。
    upstream http://${naive_upstream_user}:${naive_upstream_pass}@127.0.0.1:${naive_secondary_port}
EOF
else
cat >> "$caddyfile_tmp" <<'EOF'

    # 未启用二级出站时保留 Caddy 本地 ACL；upstream 模式与 acl 不兼容，二级模式由 Sing-box 等价拒绝。
    acl {
      deny 10.0.0.0/8
      deny 100.64.0.0/10
      deny 127.0.0.0/8
      deny 169.254.0.0/16
      deny 172.16.0.0/12
      deny 192.168.0.0/16
      deny ::1/128
      deny fc00::/7
      deny fe80::/10
      allow all
    }
EOF
fi
cat >> "$caddyfile_tmp" <<EOF
  }

  # 5. 未认证的普通网站请求全部反代到真实 Linux 镜像，保留原始 URI 与查询参数。
  reverse_proxy https://$naivesite {
    header_up Host {upstream_hostport}
    header_up -Forwarded
    header_up -Via
    header_up -X-Forwarded-*
    header_up -X-Real-IP
    header_up -X-Client-IP
    header_up -Proxy-Connection
    header_up -Proxy-Authorization
    header_up -Cookie
    header_up -Origin
    header_up -Referer
    header_down -Server
    header_down -X-Powered-By
    header_down -Set-Cookie
    # 源站常把 /debian 等目录规范化为带源站域名的绝对 Location；统一改回 Naive 自定义域名。
    header_down Location "^https?://${naivesite_regex}([/?#].*)?$" "https://$naive\$1"
  }
}
EOF
# 先用目标 Caddy 内核完整适配并预配模块；通过后再原子替换正式配置，失败时不注册服务、不覆盖旧配置。
# rep 会复用已安装的 Caddy；若旧版收尾加固曾将其权限收紧为 600，这里先恢复执行权限再校验。
if [ ! -x "$HOME/agsbx/caddy" ]; then
chmod 700 "$HOME/agsbx/caddy" 2>/dev/null || {
printf '%s\n' "${C_RED}错误：当前 Caddy(naive) 内核缺少执行权限且无法恢复，已终止 Caddy 安装。${C_RESET}"
return 1
}
fi
if ! "$HOME/agsbx/caddy" validate --config "$caddyfile_tmp" --adapter caddyfile >/dev/null 2>&1; then
printf '%s\n' "${C_RED}错误：新 Caddyfile 与当前 Caddy(naive) 内核不兼容，已终止 Caddy 安装。${C_RESET}"
"$HOME/agsbx/caddy" validate --config "$caddyfile_tmp" --adapter caddyfile 2>&1 | head -5
echo "待检查配置保留在：$caddyfile_tmp"
return 1
fi
mv -f "$caddyfile_tmp" "$HOME/agsbx/Caddyfile"
# 服务注册三后端（systemd / openrc / 裸 nohup），对齐 xr/argo 既有写法；root 运行 + NoNewPrivileges 收敛。
local caddy_systemd_after="After=network.target network-online.target"
local caddy_systemd_wants="Wants=network-online.target"
local caddy_openrc_sidecar=""
if secondary_protocol_is_selected naive; then
  # 软依赖只约束开机顺序；Sing-box 故障时 Caddy 仍须保留 TLS/伪装站并让代理请求失败关闭。
  caddy_systemd_after="After=network.target network-online.target sb.service"
  caddy_systemd_wants="Wants=network-online.target sb.service"
  caddy_openrc_sidecar="    use sing-box
    after sing-box"
fi
if pidof systemd >/dev/null 2>&1 && is_root; then
local caddy_unit="/etc/systemd/system/agsbx-caddy.service"
local caddy_unit_tmp="$HOME/agsbx/.agsbx-caddy.service.new"
local legacy_caddy_unit="/etc/systemd/system/caddy.service"
if [ -L "$caddy_unit" ] || { [ -e "$caddy_unit" ] && ! grep -Fq "ExecStart=$HOME/agsbx/caddy run" "$caddy_unit"; }; then
  echo "错误：$caddy_unit 已存在但不属于 Airgosbx，已拒绝覆盖。"
  return 1
fi
if [ -f "$legacy_caddy_unit" ] && grep -Fq "ExecStart=$HOME/agsbx/caddy run" "$legacy_caddy_unit"; then
  systemctl stop caddy >/dev/null 2>&1 || true
  if systemctl is-active --quiet caddy; then
    echo "错误：旧版 Airgosbx caddy.service 无法停止，已保留原 Unit 并终止迁移。"
    return 1
  fi
  systemctl disable caddy >/dev/null 2>&1 || { echo "错误：无法禁用旧版 Airgosbx caddy.service，已终止迁移。"; return 1; }
  rm -f "$legacy_caddy_unit" || { echo "错误：无法移除旧版 Airgosbx caddy.service。"; return 1; }
fi
cat > "$caddy_unit_tmp" <<EOF
[Unit]
Description=Airgosbx Caddy NaiveProxy Service
$caddy_systemd_after
$caddy_systemd_wants
[Service]
Type=notify
NoNewPrivileges=yes
PrivateTmp=true
ProtectSystem=full
UMask=0077
LimitNOFILE=1048576
TimeoutStartSec=0
TimeoutStopSec=5s
WorkingDirectory=$HOME/agsbx
ExecStartPre=-/bin/rm -f $caddy_admin_socket
ExecStart=$HOME/agsbx/caddy run --config $HOME/agsbx/Caddyfile
ExecReload=$HOME/agsbx/caddy reload --config $HOME/agsbx/Caddyfile --address $caddy_admin_address --force
RestartPreventExitStatus=1
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
mv -f "$caddy_unit_tmp" "$caddy_unit" || { echo "错误：无法安装 $caddy_unit。"; return 1; }
systemctl daemon-reload >/dev/null 2>&1 || { echo "错误：systemctl daemon-reload 失败。"; return 1; }
systemctl enable agsbx-caddy >/dev/null 2>&1 || { echo "错误：无法启用 agsbx-caddy.service。"; return 1; }
if ! systemctl restart agsbx-caddy >/dev/null 2>&1 || ! systemctl is-active --quiet agsbx-caddy; then
  echo "错误：agsbx-caddy.service 启动失败，请运行 journalctl -u agsbx-caddy -n 30 --no-pager 查看日志。"
  return 1
fi
elif command -v rc-service >/dev/null 2>&1 && is_root; then
local caddy_init="/etc/init.d/agsbx-caddy"
local caddy_init_tmp="$HOME/agsbx/.agsbx-caddy.init.new"
local legacy_caddy_init="/etc/init.d/caddy"
if [ -L "$caddy_init" ] || { [ -e "$caddy_init" ] && ! grep -Fq "command=\"$HOME/agsbx/caddy\"" "$caddy_init"; }; then
  echo "错误：$caddy_init 已存在但不属于 Airgosbx，已拒绝覆盖。"
  return 1
fi
if [ -f "$legacy_caddy_init" ] && grep -Fq "command=\"$HOME/agsbx/caddy\"" "$legacy_caddy_init"; then
  rc-service caddy stop >/dev/null 2>&1 || true
  rc-update del caddy default >/dev/null 2>&1 || true
  rm -f "$legacy_caddy_init" || { echo "错误：无法移除旧版 Airgosbx OpenRC caddy 服务。"; return 1; }
fi
cat > "$caddy_init_tmp" <<EOF
#!/sbin/openrc-run
description="Airgosbx Caddy NaiveProxy Service"
command="$HOME/agsbx/caddy"
command_args="run --config $HOME/agsbx/Caddyfile"
command_background=yes
pidfile="/run/agsbx-caddy.pid"
start_pre() {
    rm -f "$caddy_admin_socket"
}
depend() {
need net
$caddy_openrc_sidecar
}
EOF
mv -f "$caddy_init_tmp" "$caddy_init" || { echo "错误：无法安装 $caddy_init。"; return 1; }
chmod 700 "$caddy_init" || { echo "错误：无法设置 $caddy_init 权限。"; return 1; }
rc-update add agsbx-caddy default >/dev/null 2>&1 || { echo "错误：无法启用 OpenRC agsbx-caddy 服务。"; return 1; }
rc-service agsbx-caddy stop >/dev/null 2>&1 || true
if ! rc-service agsbx-caddy start 8>&- >/dev/null 2>&1 || ! agsbx_component_running caddy; then
  echo "错误：OpenRC agsbx-caddy 服务启动失败，请查看 $HOME/agsbx/caddy.log 或系统日志。"
  return 1
fi
else
rm -f "$caddy_admin_socket"
stop_component_processes caddy || return 1
sleep 1
nohup "$HOME/agsbx/caddy" run --config "$HOME/agsbx/Caddyfile" 8>&- > "$HOME/agsbx/caddy.log" 2>&1 &
sleep 1
if ! agsbx_component_running caddy; then
  echo "错误：Caddy 后台进程启动失败，请查看 $HOME/agsbx/caddy.log。"
  return 1
fi
fi
# 等待并完整校验 Caddy 证书生成情况
local detect_sec=60
local caddy_cert=""
local caddy_key=""
local caddy_cert_valid=no
printf "正在等待 Caddy 自动托管申请证书（最长 60 秒，签发成功将立刻退出）"
while [ $detect_sec -gt 0 ]; do
  printf "."
  # 同一签发目录中的证书与私钥必须配对；旧签发者的过期文件不能挡住新证书。
  while IFS= read -r -d '' caddy_cert; do
    caddy_key="${caddy_cert%.*}.key"
    if validate_certificate_bundle "$caddy_cert" "$caddy_key" caddy "$naive"; then
      caddy_cert_valid=yes
      break
    fi
  done < <(find "$HOME/agsbx/caddy_storage" -type f -iname "$naive.crt" -print0 2>/dev/null)
  if [ "$caddy_cert_valid" = yes ]; then
    echo " [成功]"
    break
  fi
  sleep 1
  detect_sec=$((detect_sec - 1))
done
echo

if [ "$caddy_cert_valid" = yes ]; then
  echo "caddy" > "$HOME/agsbx/cert_mode" || return 1
  record_cert_source "caddy" "$naive" || return 1
  echo "$caddy_cert" > "$HOME/agsbx/cert_file_path" || return 1
  echo "$caddy_key" > "$HOME/agsbx/key_file_path" || return 1
  echo "$naive" > "$HOME/agsbx/sni.txt" || return 1
  # 本次运行已经完成有效期、SAN 和私钥匹配校验；缓存结果，避免后续 TLS 节点重复校验。
  tls_cert_file="$caddy_cert"
  tls_key_file="$caddy_key"
  write_cert_fingerprint || return 1
  tls_cert_ready=yes
  # 调用 show_tls_cert_summary 展示详细证书信息并标记来源
  show_tls_cert_summary "Caddy 自动托管申请成功" "$naive"
  # 注册续期联动重载：Caddy 自动续期后，复用该证书的 xray/sing-box 能加载到新证书
  setup_caddy_cert_reload || return 1
else
  printf '%s\n' "${C_RED}错误：60 秒内未检测到通过有效期、SAN 与私钥匹配校验的 Caddy TLS 证书。${C_RESET}"
  echo "Caddy 可能仍在后台获取证书中，或者 80/443 端口被占用/DNS 解析未生效。"
  echo "建议稍后运行 journalctl -u agsbx-caddy -f 或查看 $HOME/agsbx/caddy.log 查看具体证书申请进度。"
  return 1
fi

echo "NaiveProxy(Caddy) 已部署：https://$naive"
}

#============================================================
# [第7段] 附加协议与出站/路由配置生成函数
#------------------------------------------------------------
# 🎯 架构说明：
# - 本大段包含 xrsbvm() (Vmess-ws)、xrsbso() (Socks5) 协议写入，以及 xrsbout() (JSON最终闭合、DNS及路由规则写入、服务启动运行)。
# - 关联性：由第 8 段 (安装编排主函数 ins()) 调用以完成 Xray/Sing-box 底层配置文件的最终组装落地与后台拉起运行。
#============================================================
xrsbvm(){
if [ -n "$vmp" ]; then
vmp=vmpt
port_vm_ws=$(init_port "$port_vm_ws" port_vm_ws)
echo "Vmess-ws端口：$port_vm_ws"
if [ -n "$cdnym" ]; then
echo "$cdnym" > "$HOME/agsbx/cdnym"
echo "80系CDN或者回源CDN的host域名 (确保IP已解析在CF域名)：$cdnym"
fi
if [ -e "$HOME/agsbx/xr.json" ]; then
prepare_xray_profile vm || return 1
cat >> "$HOME/agsbx/xr.json" <<EOF
        {
            "tag": "vmess-xr",
            "listen": "${public_listen_address}",
            "port": ${port_vm_ws},
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "$(json_escape "$uuid")",
                        "email": "agsbx-profile-vm-v2"
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "security": "none",
                "wsSettings": {
                  "path": "$(json_escape "$(transport_path vm)")"
            }$direct_server_fm
        },
            "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"],
            "metadataOnly": false
            }
         },
EOF
else
cat >> "$HOME/agsbx/sb.json" <<EOF
{
        "type": "vmess",
        "tag": "vmess-sb",
        "listen": "${public_listen_address}",
        "listen_port": ${port_vm_ws},
        "users": [
            {
                "uuid": "$(json_escape "$uuid")",
                "alterId": 0
            }
        ],
        "transport": {
            "type": "ws",
            "path": "$(json_escape "$(transport_path vm)")",
            "max_early_data":2048,
            "early_data_header_name": "Sec-WebSocket-Protocol"
        }
    },
EOF
fi
else
vmp=vmptargo
fi
}

xrsbso(){
if [ -n "$sop" ]; then
sop=sopt
port_so=$(init_port "$port_so" port_so) || return 1
inssockscred || return 1
echo "Socks5端口：$port_so"
if [ -e "$HOME/agsbx/xr.json" ]; then
cat >> "$HOME/agsbx/xr.json" <<EOF
        {
         "tag": "socks5-xr",
         "port": ${port_so},
         "listen": "${public_listen_address}",
         "protocol": "socks",
         "settings": {
            "auth": "password",
             "accounts": [
               {
               "user": "$socks_user",
               "pass": "$socks_pass"
               }
            ],
            "udp": true
          },
            "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"],
            "metadataOnly": false
            }
         },
EOF
else
cat >> "$HOME/agsbx/sb.json" <<EOF
    {
      "tag": "socks5-sb",
      "type": "socks",
      "listen": "${public_listen_address}",
      "listen_port": ${port_so},
      "users": [
      {
      "username": "$socks_user",
      "password": "$socks_pass"
      }
     ]
    },
EOF
fi
else
sop=soptargo
fi
}

#============================================================
# [阶段一/阶段二] Xray / Sing-box / Naive 二级代理出站
#------------------------------------------------------------
# secp 选择 A VPS 上哪些入站协议的后续流量改走 secondary-out；实现层通过对应 inbound tag 精确匹配。
# 客户端接入 A 的直连/CDN/Argo 方式不变。
# 未被 secp 选中的协议继续沿用原有出站规则（直连或 WARP）。
# B 节点 URL 只解析一次并归一化，再分别渲染两套内核配置，避免协议段内重复拼装出站 JSON。
#============================================================
secondary_error(){
  printf '%s\n' "${C_RED}二级代理配置错误：$1${C_RESET}"
  return 1
}

secondary_valid_text(){
  valid_plain_text "$1" "${2:-1024}"
}

secondary_valid_ascii(){
  LC_ALL=C grep -q '^[ -~]*$' <<< "$1"
}

secondary_add_protocol(){
  local protocol="$1"
  case ",${secondary_protocols}," in
    *",${protocol},"*) ;;
    *) secondary_protocols="${secondary_protocols:+$secondary_protocols,}$protocol" ;;
  esac
}

# 只读取归一化后的选择结果；Naive 不参与 xr/sb 分组展开，必须由用户显式选择。
secondary_protocol_is_selected(){
  case ",${secondary_protocols}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

secondary_saved_protocol_is_selected(){
  local saved
  [ -s "$HOME/agsbx/secondary_secp" ] || return 1
  saved=$(tr -d '[:space:]' < "$HOME/agsbx/secondary_secp" 2>/dev/null)
  case ",$saved," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

secondary_protocol_is_active(){
  case "$1" in
    xhpt)     [ "$xhp" = yes ] ;;
    vlpt)     [ "$vlp" = yes ] ;;
    vxpt)     [ "$vxp" = yes ] ;;
    vwpt)     [ "$vwp" = yes ] ;;
    xhypt)    [ "$xhyp" = yes ] ;;
    xdns)     [ "$xdns" = yes ] ;;
    xicmp)    [ "$xicp" = yes ] ;;
    xvcdnpt)  [ "$xvcdn" = yes ] ;;
    xvargopt) [ "$xvargo" = yes ] ;;
    shypt)    [ "$hyp" = yes ] ;;
    tupt)     [ "$tup" = yes ] ;;
    anpt)     [ "$anp" = yes ] ;;
    arpt)     [ "$arp" = yes ] ;;
    sspt)     [ "$ssp" = yes ] ;;
    vmpt)     [ "$vmp" = yes ] ;;
    sopt)     [ "$sop" = yes ] ;;
    naive)    [ -n "$naive" ] ;;
    *) return 1 ;;
  esac
}

determine_secondary_common_core(){
  local has_xray_fixed=no has_singbox_fixed=no
  if [ "$xhp" = yes ] || [ "$vlp" = yes ] || [ "$vxp" = yes ] || [ "$vwp" = yes ] || \
    [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || \
    [ "$xvcdn" = yes ] || [ "$xvargo" = yes ]; then
    has_xray_fixed=yes
  fi
  if [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || \
    [ "$ssp" = yes ]; then
    has_singbox_fixed=yes
  fi
  if [ "$has_singbox_fixed" = yes ] && [ "$has_xray_fixed" = no ]; then
    secondary_common_core=sb
  else
    secondary_common_core=xr
  fi
}

secondary_protocol_core(){
  case "$1" in
    xhpt|vlpt|vxpt|vwpt|xhypt|xdns|xicmp|xvcdnpt|xvargopt) printf 'xr' ;;
    shypt|tupt|anpt|arpt|sspt) printf 'sb' ;;
    # Naive 入站仍由 Caddy 驱动；这里的 sb 仅表示本地转交和二级出站由 Sing-box 承载。
    naive) printf 'sb' ;;
    vmpt|sopt) printf '%s' "$secondary_common_core" ;;
    *) return 1 ;;
  esac
}

secondary_expand_group(){
  local group="$1" protocol matched=no
  for protocol in xhpt vlpt vxpt vwpt xhypt xdns xicmp xvcdnpt xvargopt shypt tupt anpt arpt sspt vmpt sopt; do
    secondary_protocol_is_active "$protocol" || continue
    [ "$(secondary_protocol_core "$protocol")" = "$group" ] || continue
    matched=yes
    secondary_add_protocol "$protocol"
  done
  [ "$matched" = yes ] || secondary_error "secp=$group 没有匹配到本次启用的 $group 内核协议。"
}

normalize_secondary_selectors(){
  local raw token normalized
  local -a tokens
  determine_secondary_common_core
  raw=$(printf '%s' "$secp" | tr -d '[:space:]')
  [ -n "$raw" ] || { secondary_error "secp 不能为空或只包含空白字符。"; return 1; }
  case "$raw" in ,*|*,|*,,*) secondary_error "secp 中存在空选择项，请使用逗号分隔有效协议名。"; return 1 ;; esac
  secondary_protocols=''
  IFS=',' read -r -a tokens <<< "$raw"
  for token in "${tokens[@]}"; do
    normalized=$(printf '%s' "$token" | tr 'A-Z' 'a-z')
    case "$normalized" in
      xdnspt) normalized=xdns ;;
      xicmppt) normalized=xicmp ;;
    esac
    case "$normalized" in
      xr|sb) secondary_expand_group "$normalized" || return 1 ;;
      naive)
        [ -n "$naive" ] && valid_domain "$naive" || {
          secondary_error "secp=naive 必须同时提供合法的 naive=<域名>。"
          return 1
        }
        secondary_add_protocol naive
        ;;
      ca|all)
        secondary_error "不支持 secp=$normalized；NaiveProxy 二级出站请显式使用 secp=naive。"
        return 1
        ;;
      xhpt|vlpt|vxpt|vwpt|xhypt|xdns|xicmp|xvcdnpt|xvargopt|shypt|tupt|anpt|arpt|sspt|vmpt|sopt)
        secondary_protocol_is_active "$normalized" || {
          secondary_error "secp=$normalized 已被选择，但本次没有启用对应协议变量。"
          return 1
        }
        secondary_add_protocol "$normalized"
        ;;
      *)
        secondary_error "未知 secp 选择项：$token（支持协议名、xr、sb，以及显式的 naive）。"
        return 1
        ;;
    esac
  done
  [ -n "$secondary_protocols" ] || { secondary_error "secp 没有匹配到任何可用协议。"; return 1; }
  secp="$secondary_protocols"
}

secondary_split_hostport(){
  local authority="$1" host port suffix
  if [[ "$authority" == \[* ]]; then
    case "$authority" in *']:'*) ;; *) secondary_error "IPv6 地址必须使用 [IPv6]:端口 格式。"; return 1 ;; esac
    host=${authority#\[}
    host=${host%%\]*}
    suffix=${authority#*\]}
    port=${suffix#:}
    [ "$authority" = "[$host]:$port" ] || { secondary_error "B 节点地址包含不支持的路径或字符。"; return 1; }
  else
    case "$authority" in *:*) ;; *) secondary_error "B 节点 URL 必须显式包含端口。"; return 1 ;; esac
    host=${authority%:*}
    port=${authority##*:}
    case "$host" in *:*) secondary_error "IPv6 地址必须放在方括号中。"; return 1 ;; esac
  fi
  case "$port" in ''|*[!0-9]*) secondary_error "B 节点端口必须是数字。"; return 1 ;; esac
  [ "${#port}" -le 5 ] || { secondary_error "B 节点端口超出 1-65535。"; return 1; }
  port=$((10#$port))
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { secondary_error "B 节点端口超出 1-65535。"; return 1; }
  [ -n "$host" ] || { secondary_error "B 节点服务器地址为空。"; return 1; }
  case "$host" in *%*) secondary_error "当前不支持带 zone-id 的 IPv6 地址。"; return 1 ;; esac
  if ! valid_ipv4 "$host" && ! valid_ipv6 "$host" && ! valid_domain "$host"; then
    secondary_error "B 节点服务器地址不是有效的 IPv4、IPv6 或域名：$host"
    return 1
  fi
  case "$host" in 0.0.0.0|::) secondary_error "B 节点服务器地址不能是未指定地址 $host。"; return 1 ;; esac
  sec_server="$host"
  sec_port="$port"
}

secondary_normalize_ipv4(){
  local input="$1" first second third fourth
  valid_ipv4 "$input" || return 1
  IFS='.' read -r first second third fourth <<< "$input"
  printf '%d.%d.%d.%d' "$((10#$first))" "$((10#$second))" "$((10#$third))" "$((10#$fourth))"
}

# 将不含 IPv4 尾缀的 IPv6 展开为八组小写十六进制，供防递归做等价地址比较。
secondary_normalize_ipv6(){
  local input lower left right missing group normalized_group output=''
  local -a left_groups=() right_groups=() groups=()
  input="$1"
  valid_ipv6 "$input" || return 1
  lower=$(printf '%s' "$input" | tr 'A-F' 'a-f')
  if [[ "$lower" == *::* ]]; then
    left=${lower%%::*}
    right=${lower#*::}
    [ -z "$left" ] || IFS=':' read -r -a left_groups <<< "$left"
    [ -z "$right" ] || IFS=':' read -r -a right_groups <<< "$right"
    missing=$((8 - ${#left_groups[@]} - ${#right_groups[@]}))
    [ "$missing" -ge 1 ] || return 1
    groups=("${left_groups[@]}")
    while [ "$missing" -gt 0 ]; do groups+=(0); missing=$((missing - 1)); done
    groups+=("${right_groups[@]}")
  else
    IFS=':' read -r -a groups <<< "$lower"
    [ "${#groups[@]}" -eq 8 ] || return 1
  fi
  [ "${#groups[@]}" -eq 8 ] || return 1
  for group in "${groups[@]}"; do
    [ -n "$group" ] || return 1
    printf -v normalized_group '%04x' "$((16#$group))"
    output="${output:+$output:}$normalized_group"
  done
  printf '%s' "$output"
}

secondary_server_is_local_address(){
  local candidate="$1" local_address normalized_candidate normalized_local
  command -v ip >/dev/null 2>&1 || return 1
  if valid_ipv4 "$candidate"; then
    normalized_candidate=$(secondary_normalize_ipv4 "$candidate") || return 1
    while IFS= read -r local_address; do
      local_address=${local_address%/*}
      normalized_local=$(secondary_normalize_ipv4 "$local_address") || continue
      [ "$normalized_candidate" = "$normalized_local" ] && return 0
    done < <(ip -o -4 addr show 2>/dev/null | awk '{print $4}')
  else
    normalized_candidate=$(secondary_normalize_ipv6 "$candidate") || return 1
    while IFS= read -r local_address; do
      local_address=${local_address%/*}
      normalized_local=$(secondary_normalize_ipv6 "$local_address") || continue
      [ "$normalized_candidate" = "$normalized_local" ] && return 0
    done < <(ip -o -6 addr show 2>/dev/null | awk '{print $4}')
  fi
  return 1
}

# Naive sidecar 的 B 地址必须是可直接拨号的远端 IP，拒绝明显的本机、链路本地和保留地址。
# RFC1918/ULA 不在此一刀切禁止，保留 A/B 通过受信私网互联的部署能力。
secondary_validate_naive_server(){
  secondary_protocol_is_selected naive || return 0
  local first second lower_server normalized_v4 normalized_v6
  if valid_ipv4 "$sec_server"; then
    sec_server=$(secondary_normalize_ipv4 "$sec_server") || return 1
    IFS='.' read -r first second _ _ <<< "$sec_server"
    if [ "$first" -eq 0 ] || [ "$first" -eq 127 ] || \
      { [ "$first" -eq 169 ] && [ "$second" -eq 254 ]; } || [ "$first" -ge 224 ]; then
      secondary_error "secp=naive 的 B 地址不能使用本机、链路本地、组播或保留 IPv4：$sec_server"
      return 1
    fi
  elif valid_ipv6 "$sec_server"; then
    lower_server=$(printf '%s' "$sec_server" | tr 'A-F' 'a-f')
    case "$lower_server" in
      ::|0:0:0:0:0:0:0:0|::1|0:0:0:0:0:0:0:1|fe[89ab]*:*|ff*:*)
        secondary_error "secp=naive 的 B 地址不能使用本机、链路本地、组播或未指定 IPv6：$sec_server"
        return 1
        ;;
    esac
    sec_server=$(secondary_normalize_ipv6 "$sec_server") || {
      secondary_error "无法规范化 B 节点 IPv6 地址：$sec_server"
      return 1
    }
  else
    secondary_error "secp=naive 的 B 地址必须是 IPv4 或 [IPv6]。"
    return 1
  fi

  # 提前复用本轮公网 IP 探测结果；在停止旧服务前阻止 B 明确指回 A 自身形成递归。
  v4v6
  normalized_v4=$(secondary_normalize_ipv4 "$v4" 2>/dev/null)
  normalized_v6=$(secondary_normalize_ipv6 "$v6" 2>/dev/null)
  [ -n "$normalized_v4" ] && [ "$sec_server" = "$normalized_v4" ] && {
    secondary_error "B 地址与 A VPS 的公网 IPv4 相同，已停止以防递归。"
    return 1
  }
  [ -n "$normalized_v6" ] && [ "$sec_server" = "$normalized_v6" ] && {
    secondary_error "B 地址与 A VPS 的公网 IPv6 相同，已停止以防递归。"
    return 1
  }
  secondary_server_is_local_address "$sec_server" && {
    secondary_error "B 地址属于 A VPS 的本地接口，已停止以防递归：$sec_server"
    return 1
  }
  # B 地址通过全部拒绝条件即为合法远端；必须显式成功，不能继承上一个“不是本机地址”的状态 1。
  return 0
}

secondary_init_naive_sidecar(){
  secondary_protocol_is_selected naive || return 0
  local port_file="$HOME/agsbx/naive_secondary_port" pass_file="$HOME/agsbx/naive_secondary_pass"
  local unprivileged_start upper
  unprivileged_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null)
  case "$unprivileged_start" in ''|*[!0-9]*) unprivileged_start=1024 ;; esac
  [ "$unprivileged_start" -gt 200 ] || {
    secondary_error "当前系统允许普通进程绑定全部可用低位端口，无法安全建立 Naive TCP sidecar。"
    return 1
  }
  upper=$((unprivileged_start - 1))
  [ "$upper" -le 1023 ] || upper=1023
  naive_secondary_port=$(cat "$port_file" 2>/dev/null)
  case "$naive_secondary_port" in
    ''|*[!0-9]*) naive_secondary_port='' ;;
  esac
  if [ -z "$naive_secondary_port" ] || [ "$naive_secondary_port" -lt 200 ] || \
    [ "$naive_secondary_port" -gt "$upper" ] || [ "$naive_secondary_port" -eq 443 ] || \
    port_requested_for_deployment "$naive_secondary_port" tcp || port_is_listening "$naive_secondary_port"; then
    naive_secondary_port=$(get_free_privileged_port "$upper") || {
      secondary_error "未找到可用且受权限保护的 Naive 回环端口。"
      return 1
    }
    printf '%s\n' "$naive_secondary_port" > "$port_file"
  fi

  naive_secondary_user="agsbx-sidecar"
  if [ ! -s "$pass_file" ]; then
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32 > "$pass_file"
  fi
  naive_secondary_pass=$(cat "$pass_file" 2>/dev/null)
  if [ "${#naive_secondary_pass}" -ne 32 ]; then
    secondary_error "Naive sidecar 内部密码状态无效。"
    return 1
  fi
  case "$naive_secondary_pass" in *[!A-Za-z0-9]*) secondary_error "Naive sidecar 内部密码包含非法字符。"; return 1 ;; esac
  chmod 600 "$port_file" "$pass_file" 2>/dev/null
}

secondary_validate_naive_credentials(){
  [ -n "$naiveuser" ] && [ -n "$naivepass" ] || {
    secondary_error "Naive 公网认证的用户名和密码不能为空。"
    return 1
  }
  secondary_valid_text "$naiveuser" 255 && secondary_valid_text "$naivepass" 1024 || {
    secondary_error "Naive 凭据过长或包含控制字符，不能安全写入 Caddyfile/JSON。"
    return 1
  }
  case "$naiveuser" in
    *:*) secondary_error "Naive 用户名不能包含冒号，否则 HTTP Basic 认证无法无歧义转交。"; return 1 ;;
  esac
}

secondary_parse_userinfo(){
  local userinfo="$1" user_raw pass_raw
  [ -n "$userinfo" ] || { sec_has_auth=no; sec_username=''; sec_password=''; return 0; }
  case "$userinfo" in *:*) ;; *) secondary_error "代理认证信息必须使用 用户名:密码 格式。"; return 1 ;; esac
  user_raw=${userinfo%%:*}
  pass_raw=${userinfo#*:}
  sec_username=$(uri_percent_decode "$user_raw") || { secondary_error "代理用户名包含无效百分号编码。"; return 1; }
  sec_password=$(uri_percent_decode "$pass_raw") || { secondary_error "代理密码包含无效百分号编码。"; return 1; }
  [ -n "$sec_username" ] && [ -n "$sec_password" ] || { secondary_error "代理用户名和密码都不能为空。"; return 1; }
  secondary_valid_text "$sec_username" 255 && secondary_valid_text "$sec_password" 1024 && \
    secondary_valid_ascii "$sec_username" && secondary_valid_ascii "$sec_password" || {
    secondary_error "SOCKS/HTTP 二级代理认证仅支持可打印 ASCII，且认证信息不能过长。"
    return 1
  }
  sec_has_auth=yes
}

secondary_validate_ss_method(){
  case "$sec_method" in
    2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;;
    *) secondary_error "SS 二级出站仅支持三种 Shadowsocks-2022 加密方法：$sec_method"; return 1 ;;
  esac
}

secondary_validate_ss_key(){
  local expected actual
  case "$sec_method" in
    2022-blake3-aes-128-gcm) expected=16 ;;
    *) expected=32 ;;
  esac
  printf '%s' "$sec_password" | base64 -d >/dev/null 2>&1 || {
    secondary_error "Shadowsocks-2022 密钥不是有效 Base64。"
    return 1
  }
  actual=$(printf '%s' "$sec_password" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')
  [ "$actual" = "$expected" ] || {
    secondary_error "$sec_method 密钥解码后应为 ${expected} 字节，当前为 ${actual:-0} 字节。"
    return 1
  }
}

secondary_parse_ss_url(){
  local body="$1" userinfo hostport decoded credentials method_raw password_raw
  case "$body" in *\?*) secondary_error "当前不支持带 query/plugin 的 SS URL。"; return 1 ;; esac
  if [[ "$body" == *@* ]]; then
    body=${body%/}
    hostport=${body##*@}
    userinfo=${body%@*}
    case "$userinfo" in *@*) secondary_error "SS 用户信息中的 @ 必须进行百分号编码。"; return 1 ;; esac
    if [[ "$userinfo" == *:* ]]; then
      method_raw=${userinfo%%:*}
      password_raw=${userinfo#*:}
      sec_method=$(uri_percent_decode "$method_raw") || { secondary_error "SS method 包含无效百分号编码。"; return 1; }
      sec_password=$(uri_percent_decode "$password_raw") || { secondary_error "SS 密钥包含无效百分号编码。"; return 1; }
      sec_source_format=sip002
    else
      decoded=$(base64_decode_compat "$userinfo") || { secondary_error "SS SIP002 userinfo Base64 解码失败。"; return 1; }
      case "$decoded" in *:*) ;; *) secondary_error "SS userinfo 缺少 method:password。"; return 1 ;; esac
      sec_method=${decoded%%:*}
      sec_password=${decoded#*:}
      case "$sec_method" in 2022-*) secondary_error "AEAD-2022 的 SIP002 userinfo 不能使用 Base64URL。"; return 1 ;; esac
      sec_source_format=sip002-base64
    fi
  else
    decoded=$(base64_decode_compat "$body") || { secondary_error "旧式 SS URL Base64 解码失败。"; return 1; }
    secondary_valid_text "$decoded" 4096 || { secondary_error "旧式 SS URL 解码结果包含控制字符或过长。"; return 1; }
    case "$decoded" in *:*@*) ;; *) secondary_error "旧式 SS URL 缺少 method:password@server:port。"; return 1 ;; esac
    credentials=${decoded%@*}
    hostport=${decoded##*@}
    sec_method=${credentials%%:*}
    sec_password=${credentials#*:}
    sec_source_format=legacy
  fi
  secondary_valid_text "$sec_method" 64 && secondary_valid_text "$sec_password" 512 || {
    secondary_error "SS method 或密钥过长、为空或包含控制字符。"
    return 1
  }
  [ -n "$sec_method" ] && [ -n "$sec_password" ] || { secondary_error "SS method 和密钥不能为空。"; return 1; }
  secondary_validate_ss_method || return 1
  secondary_validate_ss_key || return 1
  secondary_split_hostport "$hostport" || return 1
  sec_scheme=ss
  sec_outbound_type=shadowsocks
  sec_username=''
  sec_has_auth=no
  sec_tls_enabled=false
  sec_network=tcp_udp
}

secondary_parse_generic_url(){
  local scheme="$1" body="$2" authority userinfo='' has_userinfo=no
  case "$body" in *\?*) secondary_error "$scheme URL 不支持 query 参数。"; return 1 ;; esac
  body=${body%/}
  case "$body" in */*) secondary_error "$scheme URL 只允许空路径或结尾的 /。"; return 1 ;; esac
  authority="$body"
  if [[ "$authority" == *@* ]]; then
    has_userinfo=yes
    userinfo=${authority%@*}
    authority=${authority##*@}
    case "$userinfo" in *@*) secondary_error "认证信息中的 @ 必须进行百分号编码。"; return 1 ;; esac
  fi
  [ "$has_userinfo" = no ] || [ -n "$userinfo" ] || { secondary_error "$scheme URL 的认证信息为空。"; return 1; }
  secondary_parse_userinfo "$userinfo" || return 1
  if [ "$scheme" = socks5 ] && [ "$sec_has_auth" = yes ] && ! secondary_valid_text "$sec_password" 255; then
    secondary_error "SOCKS5 用户名和密码分别不能超过 255 字节。"
    return 1
  fi
  if [ "$scheme" = http ] || [ "$scheme" = https ]; then
    case "$sec_username" in *:*) secondary_error "HTTP Basic 用户名不能包含冒号。"; return 1 ;; esac
  fi
  secondary_split_hostport "$authority" || return 1
  sec_scheme="$scheme"
  case "$scheme" in
    socks5) sec_outbound_type=socks; sec_tls_enabled=false; sec_network=tcp_udp ;;
    http)   sec_outbound_type=http;  sec_tls_enabled=false; sec_network=tcp ;;
    https)  sec_outbound_type=http;  sec_tls_enabled=true;  sec_network=tcp ;;
  esac
  sec_method=''
  sec_source_format=uri
}

parse_secondary_url(){
  local raw="$1" body scheme rest label_raw=''
  [ -n "$raw" ] || { secondary_error "B 节点 URL 不能为空。"; return 1; }
  [ "${#raw}" -le 4096 ] && secondary_valid_text "$raw" 4096 || {
    secondary_error "B 节点 URL 过长或包含控制字符。"
    return 1
  }
  body=${raw%%#*}
  if [ "$body" != "$raw" ]; then
    label_raw=${raw#*#}
    case "$label_raw" in *'#'*) secondary_error "URL fragment 中的 # 必须进行百分号编码。"; return 1 ;; esac
  fi
  sec_label=$(uri_percent_decode "$label_raw") || { secondary_error "URL 节点名称包含无效百分号编码。"; return 1; }
  secondary_valid_text "$sec_label" 256 || { secondary_error "URL 节点名称过长或包含控制字符。"; return 1; }
  case "$body" in *://*) ;; *) secondary_error "B 节点 URL 缺少协议头。"; return 1 ;; esac
  scheme=$(printf '%s' "${body%%://*}" | tr 'A-Z' 'a-z')
  rest=${body#*://}
  case "$scheme" in
    ss) secondary_parse_ss_url "$rest" ;;
    socks5|http|https) secondary_parse_generic_url "$scheme" "$rest" ;;
    *) secondary_error "不支持的 B 节点 URL：$scheme://（支持 ss、socks5、http、https）。"; return 1 ;;
  esac
}

secondary_has_singbox_selection(){
  local protocol
  local -a secondary_check_protocols
  IFS=',' read -r -a secondary_check_protocols <<< "$secondary_protocols"
  for protocol in "${secondary_check_protocols[@]}"; do
    [ "$(secondary_protocol_core "$protocol")" = sb ] && return 0
  done
  return 1
}

prepare_secondary_proxy(){
  [ "$secondary_prepared" = yes ] && return 0
  [ -n "$secp" ] || {
    [ -z "$securl" ] || { secondary_error "设置 securl 时必须同时设置 secp。"; return 1; }
    return 0
  }
  normalize_secondary_selectors || return 1
  case ",$secondary_protocols," in
    *,xdns,*)
      valid_domain "$xdnsym" || {
        secondary_error "secp 包含 xdns，但没有同时提供有效的 xdnsym=域名。"
        return 1
      }
      ;;
  esac
  if [ -z "$securl" ]; then
    [ -t 0 ] || {
      secondary_error "非交互环境无法读取 B 节点 URL，请同时传入 securl='完整URL'。"
      return 1
    }
    echo
    printf '%s\n' "${C_CYAN}=========配置二级代理出站=========${C_RESET}"
    echo "已选择协议：$secp"
    printf "请粘贴 B VPS 的 ss://、socks5://、http:// 或 https:// URL（输入内容隐藏）："
    IFS= read -r -s securl
    echo
  fi
  parse_secondary_url "$securl" || return 1
  unset securl
  if secondary_has_singbox_selection && ! valid_ipv4 "$sec_server" && ! valid_ipv6 "$sec_server"; then
    secondary_error "当前脚本要求 Sing-box 1.12+；为避免新版域名解析字段不兼容，Sing-box 二级出站的 B 地址必须使用 IP。"
    return 1
  fi
  secondary_validate_naive_server || return 1
  secondary_prepared=yes
  secondary_display_host="$sec_server"
  valid_ipv6 "$sec_server" && secondary_display_host="[$sec_server]"
  echo "二级代理出站已解析：$sec_scheme://$secondary_display_host:$sec_port（认证信息已隐藏）"
  echo "应用二级出站的 A VPS 入站协议：$secp"
}

persist_secondary_proxy_state(){
  if [ "$secondary_prepared" = yes ]; then
    printf '%s\n' "$secp" > "$HOME/agsbx/secondary_secp"
    printf '%s\n%s\n%s\n' "$sec_scheme" "$sec_server" "$sec_port" > "$HOME/agsbx/secondary_meta"
    chmod 600 "$HOME/agsbx/secondary_secp" "$HOME/agsbx/secondary_meta" 2>/dev/null
  fi
}

secondary_tag_for_protocol(){
  local core="$1" protocol="$2"
  case "$core:$protocol" in
    xr:xhpt) printf 'xhttp-reality' ;;
    xr:vlpt) printf 'reality-vision' ;;
    xr:vxpt) printf 'vless-xhttp' ;;
    xr:vwpt) printf 'vless-ws' ;;
    xr:xhypt) printf 'hy2-xr' ;;
    xr:xdns) printf 'vless-kcp-xdns' ;;
    xr:xicmp) printf 'vless-kcp-xicmp' ;;
    xr:xvcdnpt) printf 'vlessenc-xhttp-cdn' ;;
    xr:xvargopt) printf 'vlessenc-xhttp-argo' ;;
    xr:vmpt) printf 'vmess-xr' ;;
    xr:sopt) printf 'socks5-xr' ;;
    sb:shypt) printf 'hy2-sb' ;;
    sb:tupt) printf 'tuic5-sb' ;;
    sb:anpt) printf 'anytls-sb' ;;
    sb:arpt) printf 'anyreality-sb' ;;
    sb:sspt) printf 'ss-2022' ;;
    sb:vmpt) printf 'vmess-sb' ;;
    sb:sopt) printf 'socks5-sb' ;;
    sb:naive) printf 'naive-secondary-in' ;;
    *) return 1 ;;
  esac
}

secondary_append_runtime_tag(){
  local core="$1" tag="$2" current
  if [ "$core" = xr ]; then current="$secondary_xray_tags"; else current="$secondary_singbox_tags"; fi
  case ",$current," in *",\"$tag\","*) return 0 ;; esac
  if [ "$core" = xr ]; then
    secondary_xray_tags="${current:+$current, }\"$tag\""
  else
    secondary_singbox_tags="${current:+$current, }\"$tag\""
  fi
}

secondary_build_runtime_tags(){
  local protocol core tag config_file current
  local -a protocols
  secondary_xray_tags=''
  secondary_singbox_tags=''
  secondary_singbox_remote_dns_tags=''
  [ "$secondary_prepared" = yes ] || return 0
  IFS=',' read -r -a protocols <<< "$secondary_protocols"
  for protocol in "${protocols[@]}"; do
    core=$(secondary_protocol_core "$protocol")
    tag=$(secondary_tag_for_protocol "$core" "$protocol") || {
      secondary_error "无法将 secp=$protocol 映射到 $core 内核入站 tag。"
      return 1
    }
    if [ "$core" = xr ]; then config_file="$HOME/agsbx/xr.json"; else config_file="$HOME/agsbx/sb.json"; fi
    [ -s "$config_file" ] && grep -q "\"$tag\"" "$config_file" 2>/dev/null || {
      secondary_error "secp=$protocol 对应的 $core 入站 tag=$tag 未实际生成，已停止以防错误路由。"
      return 1
    }
    secondary_append_runtime_tag "$core" "$tag"
    # 普通 Sing-box 入站应在 A 本地解析前直接送往 B，由 B 解析目标域名。
    # Naive 仍需先解析并执行私网 IP 拦截，留在后面的专用规则中处理。
    if [ "$core" = sb ] && [ "$protocol" != naive ]; then
      current="$secondary_singbox_remote_dns_tags"
      case ",$current," in
        *",\"$tag\","*) ;;
        *) secondary_singbox_remote_dns_tags="${current:+$current, }\"$tag\"" ;;
      esac
    fi
  done
}

append_xray_secondary_outbound(){
  local address method password username auth_fields stream_fields tls_server_name
  [ -n "$secondary_xray_tags" ] || return 0
  address=$(json_escape "$sec_server")
  method=$(json_escape "$sec_method")
  password=$(json_escape "$sec_password")
  username=$(json_escape "$sec_username")
  auth_fields=''
  if [ "$sec_has_auth" = yes ]; then
    printf -v auth_fields ',\n        "user": "%s",\n        "pass": "%s"' "$username" "$password"
  fi
  # 不设置 dialerProxy=direct：该字段表示通过另一个 Xray 出站建立连接，
  # 省略后才是由当前协议出站直接连接 B 节点。
  stream_fields=''
  if [ "$sec_tls_enabled" = true ]; then
    tls_server_name="$address"
    valid_ipv6 "$sec_server" && tls_server_name="[$address]"
    printf -v stream_fields ',\n      "streamSettings": {"security": "tls", "tlsSettings": {"serverName": "%s"}}' "$tls_server_name"
  fi
  case "$sec_outbound_type" in
    shadowsocks)
      cat >> "$HOME/agsbx/xr.json" <<EOF
    ,
    {
      "tag": "secondary-out",
      "protocol": "shadowsocks",
      "settings": {
        "address": "$address",
        "port": $sec_port,
        "method": "$method",
        "password": "$password"
      }$stream_fields
    }
EOF
      ;;
    socks|http)
      cat >> "$HOME/agsbx/xr.json" <<EOF
    ,
    {
      "tag": "secondary-out",
      "protocol": "$sec_outbound_type",
      "settings": {
        "address": "$address",
        "port": $sec_port$auth_fields
      }$stream_fields
    }
EOF
      ;;
  esac
}

append_singbox_secondary_outbound(){
  local server method password username auth_fields tls_fields
  [ -n "$secondary_singbox_tags" ] || return 0
  server=$(json_escape "$sec_server")
  method=$(json_escape "$sec_method")
  password=$(json_escape "$sec_password")
  username=$(json_escape "$sec_username")
  auth_fields=''
  if [ "$sec_has_auth" = yes ]; then
    printf -v auth_fields ',\n      "username": "%s",\n      "password": "%s"' "$username" "$password"
  fi
  tls_fields=''
  if [ "$sec_tls_enabled" = true ]; then
    printf -v tls_fields ',\n      "tls": {"enabled": true, "server_name": "%s"}' "$server"
  fi
  # 不设置 detour=direct：当前 Sing-box 会在实际拨号时拒绝把空 direct 出站作为上游；
  # 省略 detour 即由系统网络直接连接 B 节点，也不会重新进入入站路由形成递归。
  case "$sec_outbound_type" in
    shadowsocks)
      cat >> "$HOME/agsbx/sb.json" <<EOF
    ,
    {
      "type": "shadowsocks",
      "tag": "secondary-out",
      "server": "$server",
      "server_port": $sec_port,
      "method": "$method",
      "password": "$password"
    }
EOF
      ;;
    socks)
      cat >> "$HOME/agsbx/sb.json" <<EOF
    ,
    {
      "type": "socks",
      "tag": "secondary-out",
      "server": "$server",
      "server_port": $sec_port,
      "version": "5"$auth_fields
    }
EOF
      ;;
    http)
      cat >> "$HOME/agsbx/sb.json" <<EOF
    ,
    {
      "type": "http",
      "tag": "secondary-out",
      "server": "$server",
      "server_port": $sec_port$auth_fields$tls_fields
    }
EOF
      ;;
  esac
}

validate_generated_core_config(){
  local core="$1" binary config output
  case "$core" in
    xray)
      binary="$HOME/agsbx/xray"
      config="$HOME/agsbx/xr.json"
      [ -x "$binary" ] && [ -s "$config" ] || { echo "错误：Xray 内核或配置文件不存在。"; return 1; }
      output=$("$binary" run -test -c "$config" 2>&1) || {
        echo "错误：Xray 配置检查失败，未注册服务。"
        printf '%s\n' "$output" | tail -n 5
        return 1
      }
      ;;
    sing-box)
      binary="$HOME/agsbx/sing-box"
      config="$HOME/agsbx/sb.json"
      [ -x "$binary" ] && [ -s "$config" ] || { echo "错误：Sing-box 内核或配置文件不存在。"; return 1; }
      output=$("$binary" check -c "$config" 2>&1) || {
        echo "错误：Sing-box 配置检查失败，未注册服务。"
        printf '%s\n' "$output" | tail -n 5
        return 1
      }
      ;;
    *) return 1 ;;
  esac
}

start_agsbx_core(){
  local core="$1" binary config service init_name description unit_path init_path core_pid
  case "$core" in
    xray)
      binary="$HOME/agsbx/xray"; config="$HOME/agsbx/xr.json"; service="xr"; init_name="xray"; description="xr service"
      ;;
    sing-box)
      binary="$HOME/agsbx/sing-box"; config="$HOME/agsbx/sb.json"; service="sb"; init_name="sing-box"; description="sb service"
      ;;
    *) return 1 ;;
  esac

  validate_generated_core_config "$core" || return 1
  require_service_slot "$core" || return 1
  if pidof systemd >/dev/null 2>&1 && is_root; then
    unit_path="/etc/systemd/system/${service}.service"
    cat > "$unit_path" <<EOF
[Unit]
Description=$description
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=$binary run -c $config
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    if [ $? -ne 0 ]; then
      echo "错误：无法写入 $unit_path。"
      return 1
    fi
    systemctl daemon-reload >/dev/null 2>&1 || { echo "错误：systemctl daemon-reload 失败。"; return 1; }
    systemctl enable "$service" >/dev/null 2>&1 || { echo "错误：无法启用 ${service}.service。"; return 1; }
    systemctl start "$service" >/dev/null 2>&1 || { echo "错误：无法启动 ${service}.service。"; return 1; }
    systemctl is-active --quiet "$service" || { echo "错误：${service}.service 启动后未保持 active。"; return 1; }
  elif command -v rc-service >/dev/null 2>&1 && is_root; then
    init_path="/etc/init.d/$init_name"
    cat > "$init_path" <<EOF
#!/sbin/openrc-run
description="$description"
command="$binary"
command_args="run -c $config"
command_background=yes
pidfile="/run/${init_name}.pid"
depend() {
need net
}
EOF
    if [ $? -ne 0 ]; then
      echo "错误：无法写入 $init_path。"
      return 1
    fi
    chmod 700 "$init_path" || { echo "错误：无法设置 $init_path 执行权限。"; return 1; }
    rc-update add "$init_name" default >/dev/null 2>&1 || { echo "错误：无法启用 OpenRC $init_name 服务。"; return 1; }
    rc-service "$init_name" start 8>&- >/dev/null 2>&1 || { echo "错误：无法启动 OpenRC $init_name 服务。"; return 1; }
  else
    nohup "$binary" run -c "$config" 8>&- > "$HOME/agsbx/${core}.log" 2>&1 &
    core_pid=$!
    sleep 1
    kill -0 "$core_pid" >/dev/null 2>&1 || { echo "错误：$core 后台进程启动失败。"; return 1; }
  fi
  wait_agsbx_component "$core" || { echo "错误：$core 启动后未检测到对应进程。"; return 1; }
}

xrsbout(){
local naive_dns_strategy=prefer_ipv4
valid_ipv6 "$sec_server" && naive_dns_strategy=prefer_ipv6
secondary_build_runtime_tags || return 1
if [ -e "$HOME/agsbx/xr.json" ]; then
sed -i '$ s/,[[:space:]]*$//' "$HOME/agsbx/xr.json" 2>/dev/null || sed -i '$s/,$//' "$HOME/agsbx/xr.json"
cat >> "$HOME/agsbx/xr.json" <<EOF
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
      "domainStrategy":"${xryx}"
     }
    }
EOF
append_xray_secondary_outbound
# 普通 HTTPS 由固定 fallback 处理；防护凭据即使被使用，也不开放通用 Trojan 代理。
if [ "$subscription_core" = xray ]; then
cat >> "$HOME/agsbx/xr.json" <<EOF
    ,
    {"protocol": "blackhole", "tag": "subscription-reject"}
EOF
fi
# WARP 隧道两端 (xr/sb) 均显式锁定 mtu=1280（官方 WARP 客户端取值）：
# 内核默认 1420/1408 在 IPv6 外层封装下逼近 1500 上限，途经 PMTUD 黑洞时大包静默丢失，
# 表现为"能握手、小流量正常、大流量卡死"，内层 IPv6 (s6/x6) 模式受害最深。
if [ "$wap" = warp ]; then
cat >> "$HOME/agsbx/xr.json" <<EOF
    ,
    {
      "tag": "x-warp-out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${pvk}",
        "mtu": 1280,
        "address": [
          "172.16.0.2/32",
          "${wpv6}/128"
        ],
        "peers": [
          {
            "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ],
            "endpoint": "${xendip}:2408"
          }
        ],
        "reserved": ${res}
        }
    },
    {
      "tag":"warp-out",
      "protocol":"freedom",
        "settings":{
        "domainStrategy":"${wxryx}"
       },
       "proxySettings":{
       "tag":"x-warp-out"
     }
    }
EOF
fi
cat >> "$HOME/agsbx/xr.json" <<EOF
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
EOF
if [ "$subscription_core" = xray ]; then
cat >> "$HOME/agsbx/xr.json" <<EOF
      {
        "type": "field",
        "inboundTag": ["sub-https-proxy"],
        "outboundTag": "subscription-reject"
      },
EOF
fi
if [ -n "$secondary_xray_tags" ]; then
# 二级代理规则必须保持在所有 IP 规则之前，避免 IPOnDemand 在 A 上触发目标域名解析。
cat >> "$HOME/agsbx/xr.json" <<EOF
      {
        "type": "field",
        "inboundTag": [$secondary_xray_tags],
        "outboundTag": "secondary-out"
      },
EOF
fi
cat >> "$HOME/agsbx/xr.json" <<EOF
      {
        "type": "field",
        "ip": [ ${xip} ],
        "network": "tcp,udp",
        "outboundTag": "${x1outtag}"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "${x2outtag}"
      }
    ]
  }
}
EOF
start_agsbx_core xray || return 1
fi
if [ -e "$HOME/agsbx/sb.json" ]; then
sed -i '$ s/,[[:space:]]*$//' "$HOME/agsbx/sb.json" 2>/dev/null || sed -i '$s/,$//' "$HOME/agsbx/sb.json"
cat >> "$HOME/agsbx/sb.json" <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
EOF
append_singbox_secondary_outbound
cat >> "$HOME/agsbx/sb.json" <<EOF
  ]
EOF
if [ "$wap" = warp ]; then
cat >> "$HOME/agsbx/sb.json" <<EOF
  ,
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "${wpv6}/128"
      ],
      "private_key": "${pvk}",
      "peers": [
        {
          "address": "${sendip}",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": [
            "0.0.0.0/0",
            "::/0"
          ],
          "reserved": $res
        }
      ]
    }
  ]
EOF
fi
if secondary_protocol_is_selected naive; then
# Naive 需要在 A 上保留解析结果以执行私网 ACL，但 DNS 查询本身必须经 B 发出。
# 使用固定 IP 的 DoH 服务器可避免解析 DNS 服务器自身；Naive 模式已强制 B 节点地址为 IP，不会形成拨号循环。
cat >> "$HOME/agsbx/sb.json" <<EOF
  ,"dns": {
    "servers": [
      {
        "type": "https",
        "tag": "secondary-dns",
        "server": "1.1.1.1",
        "server_port": 443,
        "path": "/dns-query",
        "tls": {
          "enabled": true,
          "server_name": "cloudflare-dns.com"
        },
        "detour": "secondary-out"
      }
    ]
  }
EOF
fi
cat >> "$HOME/agsbx/sb.json" <<EOF
  ,"route": {
    "rules": [
EOF
if [ "$subscription_core" = singbox ]; then
cat >> "$HOME/agsbx/sb.json" <<EOF
      {
        "inbound": ["sub-https-proxy"],
        "action": "route",
        "outbound": "direct"
      },
EOF
fi
cat >> "$HOME/agsbx/sb.json" <<EOF
      {
        "action": "sniff"
      },
EOF
# 普通 Sing-box 二级代理入站先执行最终路由，保留目标域名并交由 B VPS 解析。
# Naive 不进入此标签组，继续执行后面的本地解析和私网 IP 拦截。
if [ -n "$secondary_singbox_remote_dns_tags" ]; then
cat >> "$HOME/agsbx/sb.json" <<EOF
      {
        "inbound": [$secondary_singbox_remote_dns_tags],
        "action": "route",
        "outbound": "secondary-out"
      },
EOF
fi
if secondary_protocol_is_selected naive; then
cat >> "$HOME/agsbx/sb.json" <<EOF
      {
        "inbound": ["naive-secondary-in"],
        "action": "resolve",
        "server": "secondary-dns",
        "strategy": "${naive_dns_strategy}"
      },
      {
        "inbound": ["naive-secondary-in"],
        "ip_cidr": [
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "action": "reject"
      },
      {
        "inbound": ["naive-secondary-in"],
        "network": "tcp",
        "action": "route",
        "outbound": "secondary-out"
      },
      {
        "inbound": ["naive-secondary-in"],
        "action": "reject"
      },
EOF
fi
cat >> "$HOME/agsbx/sb.json" <<EOF
      {
        "action": "resolve",
        "strategy": "${sbyx}"
      },
      {
        "ip_cidr": [ ${sip} ],
        "outbound": "${s1outtag}"
      },
      {
        "outbound": "${s2outtag}"
      }
    ]
  }
}
EOF
start_agsbx_core sing-box || return 1
fi
}
#============================================================
# [第8段] 全流程安装编排主函数
#------------------------------------------------------------
# 🎯 架构说明:
# - 本大段定义了安装编排的总发动机函数 ins()。负责协调内核下载、UUID分配、防火墙端口跳跃控制、Xray/Sing-box Inbound装配、配置文件最终闭合、Argo 隧道守护以及系统快捷键注入。
# - 关联性: 由第 12 段 (主入口流程决策) 在判定为新安装或重置时调用，是串联整个 3300 行脚本全流程安装逻辑的核心中枢。
#============================================================
argo_origin_from_state(){
  argoscheme=http; argoxtls=''; argo_origin_host=localhost
  case "$(cat "$HOME/agsbx/vlvm" 2>/dev/null)" in
    Vlessenc-xhttp-tls-vision-fm) argoscheme=https; argoxtls='--no-tls-verify ' ;;
    Vlessenc-xhttp-vision) argo_origin_host=127.0.0.1 ;;
  esac
}

cloudflared_supports_token_file(){
  [ -x "$HOME/agsbx/cloudflared" ] \
    && "$HOME/agsbx/cloudflared" tunnel run --help 2>&1 | grep -Fq -- '--token-file'
}

write_argo_systemd_service(){
require_service_slot cloudflared || return 1
cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=argo service
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=$HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file "$argo_token_file"
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
}

write_argo_openrc_service(){
require_service_slot cloudflared || return 1
cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
description="argo service"
command="$HOME/agsbx/cloudflared"
command_args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $argo_token_file"
pidfile="/run/argo.pid"
command_background="yes"
depend() {
need net
}
EOF
[ $? -eq 0 ] || return 1
chmod 700 /etc/init.d/argo
}

argo_cron_line_is_managed(){
  local line="$1" prefix suffix token scheme host extra expected
  case "$line" in *'# AIRGOSBX_ARGO') return 0 ;; @reboot*) ;; *) return 1 ;; esac
  prefix='@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token '
  suffix=' > $HOME/agsbx/argo.log 2>&1 &"'
  if [[ "$line" == "$prefix"*"$suffix" ]]; then
    token=${line#"$prefix"}; token=${token%"$suffix"}
    [[ "$token" =~ ^[A-Za-z0-9_+/=-]+$ ]] && return 0
  fi
  expected='@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $HOME/agsbx/sbargotoken.log > $HOME/agsbx/argo.log 2>&1 &"'
  [ "$line" != "$expected" ] || return 0
  for scheme in http https; do
    extra=''; [ "$scheme" != https ] || extra='--no-tls-verify '
    for host in localhost 127.0.0.1; do
      expected='@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --url '"$scheme"'://'"$host"':$(cat $HOME/agsbx/argoport.log) '"$extra"'--edge-ip-version auto --no-autoupdate --protocol http2 > $HOME/agsbx/argo.log 2>&1 &"'
      [ "$line" != "$expected" ] || return 0
    done
  done
  case "$line" in *'agsbx/cloudflared'*) return 2 ;; *) return 1 ;; esac
}

inspect_argo_noinit_cron(){
  local cron_tmp line found_fixed=no found_temporary=no
  argo_cron_mode=none
  argo_cron_legacy=no
  cron_tmp=$(mktemp) || return 1
  read_crontab_or_empty "$cron_tmp" || { rm -f "$cron_tmp"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    if argo_cron_line_is_managed "$line"; then :
    elif [ "$?" = 2 ]; then rm -f "$cron_tmp"; echo "错误：Argo 启动项无法安全识别。"; return 1
    else continue; fi
    case "$line" in
      *" --token "*) found_fixed=yes; argo_cron_legacy=yes ;;
      *" --token-file "*) found_fixed=yes ;;
      *" --url "*) found_temporary=yes ;;
      *) rm -f "$cron_tmp"; echo "错误：发现无法识别的 Airgosbx Argo cron 启动项。"; return 1 ;;
    esac
  done < "$cron_tmp"
  rm -f "$cron_tmp"
  if [ "$found_fixed" = yes ] && [ "$found_temporary" = yes ]; then
    echo "错误：同时发现固定和临时 Argo cron 启动项，拒绝猜测当前模式。"
    return 1
  elif [ "$found_fixed" = yes ]; then
    argo_cron_mode=fixed
  elif [ "$found_temporary" = yes ]; then
    argo_cron_mode=temporary
  fi
}

secure_existing_argo_token_file(){
  local owner
  [ -d "$HOME/agsbx" ] && [ ! -L "$HOME/agsbx" ] \
    || { echo "错误：Argo token 目录不安全。"; return 1; }
  [ -s "$argo_token_file" ] && [ -f "$argo_token_file" ] && [ ! -L "$argo_token_file" ] \
    || { echo "错误：Argo token 文件缺失或不是安全的普通文件。"; return 1; }
  owner=$(stat -c '%u' "$argo_token_file" 2>/dev/null) || return 1
  [ "$owner" = "$(id -u)" ] \
    || { echo "错误：Argo token 文件属主不正确。"; return 1; }
  chmod 600 "$argo_token_file"
}

filter_managed_argo_cron(){
  local source="$1" destination="$2" line
  : > "$destination" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if argo_cron_line_is_managed "$line"; then continue
    elif [ "$?" = 2 ]; then return 1; fi
    printf '%s\n' "$line" >> "$destination" || return 1
  done < "$source"
}

write_argo_noinit_cron(){
  local cron_tmp filtered_tmp
  cron_tmp=$(mktemp) || return 1
  filtered_tmp=$(mktemp) || { rm -f "$cron_tmp"; return 1; }
  if ! read_crontab_or_empty "$cron_tmp" \
    || ! filter_managed_argo_cron "$cron_tmp" "$filtered_tmp" \
    || ! echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $HOME/agsbx/sbargotoken.log > $HOME/agsbx/argo.log 2>&1 &" # AIRGOSBX_ARGO' >> "$filtered_tmp" \
    || ! crontab "$filtered_tmp" >/dev/null 2>&1; then
    rm -f "$cron_tmp" "$filtered_tmp"
    return 1
  fi
  rm -f "$cron_tmp" "$filtered_tmp"
}

migrate_argo_persistent_startup(){
  local legacy_inline=no init_backend=none init_mode=none
  argo_persistent_mode=none
  argo_persistent_backend=none
  argo_cron_mode=none
  argo_cron_legacy=no

  if command -v crontab >/dev/null 2>&1; then
    inspect_argo_noinit_cron || return 1
  fi

  if pidof systemd >/dev/null 2>&1; then
    if [ -e /etc/systemd/system/argo.service ] \
      && grep -Fq "ExecStart=$HOME/agsbx/cloudflared tunnel" /etc/systemd/system/argo.service 2>/dev/null; then
      init_backend=systemd
      if grep -Fq -- ' --token ' /etc/systemd/system/argo.service 2>/dev/null; then
        init_mode=fixed
        legacy_inline=yes
      elif grep -Fq -- ' --token-file ' /etc/systemd/system/argo.service 2>/dev/null; then
        init_mode=fixed
      elif grep -Fq -- ' --url ' /etc/systemd/system/argo.service 2>/dev/null; then
        init_mode=temporary
      else
        echo "错误：发现无法识别的 Airgosbx Argo systemd 启动项。"
        return 1
      fi
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    if [ -e /etc/init.d/argo ] \
      && service_file_owned /etc/init.d/argo cloudflared openrc; then
      init_backend=openrc
      if grep -Fq -- ' --token ' /etc/init.d/argo 2>/dev/null; then
        init_mode=fixed
        legacy_inline=yes
      elif grep -Fq -- ' --token-file ' /etc/init.d/argo 2>/dev/null; then
        init_mode=fixed
      elif grep -Fq -- ' --url ' /etc/init.d/argo 2>/dev/null; then
        init_mode=temporary
      else
        echo "错误：发现无法识别的 Airgosbx Argo OpenRC 启动项。"
        return 1
      fi
    fi
  fi

  if [ "$init_mode" != none ] && [ "$argo_cron_mode" != none ]; then
    echo "错误：同时发现 Airgosbx Argo init 服务与 cron 启动项，拒绝猜测当前模式。"
    return 1
  elif [ "$init_mode" != none ]; then
    argo_persistent_mode="$init_mode"
    argo_persistent_backend="$init_backend"
  elif [ "$argo_cron_mode" != none ]; then
    argo_persistent_mode="$argo_cron_mode"
    argo_persistent_backend=cron
    legacy_inline="$argo_cron_legacy"
  else
    return 0
  fi

  [ "$argo_persistent_mode" != temporary ] || return 0

  case "$argo_persistent_backend" in
  systemd)
    if [ "$legacy_inline" = yes ]; then
      write_argo_systemd_service && systemctl daemon-reload >/dev/null 2>&1 \
        || { echo "错误：无法清除旧 Argo systemd 服务中的内联 token。"; return 1; }
    fi
    secure_existing_argo_token_file \
      || { echo "错误：固定 Argo systemd 服务缺少安全 token 文件。"; return 1; }
    cloudflared_supports_token_file \
      || { echo "错误：旧 Cloudflared 不支持安全迁移固定隧道 systemd 服务。"; return 1; }
    write_argo_systemd_service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    ;;
  openrc)
    if [ "$legacy_inline" = yes ]; then
      write_argo_openrc_service \
        || { echo "错误：无法清除旧 Argo OpenRC 服务中的内联 token。"; return 1; }
    fi
    secure_existing_argo_token_file \
      || { echo "错误：固定 Argo OpenRC 服务缺少安全 token 文件。"; return 1; }
    cloudflared_supports_token_file \
      || { echo "错误：旧 Cloudflared 不支持安全迁移固定隧道 OpenRC 服务。"; return 1; }
    write_argo_openrc_service || return 1
    ;;
  cron)
    if [ "$legacy_inline" = yes ]; then
      write_argo_noinit_cron \
        || { echo "错误：无法清除旧 Argo crontab 中的内联 token。"; return 1; }
    fi
    secure_existing_argo_token_file \
      || { echo "错误：固定 Argo crontab 缺少安全 token 文件。"; return 1; }
    cloudflared_supports_token_file \
      || { echo "错误：旧 Cloudflared 不支持安全迁移固定隧道 crontab。"; return 1; }
    write_argo_noinit_cron || return 1
    ;;
  *)
    echo "错误：固定 Argo 持久化载体无法识别。"
    return 1
    ;;
  esac
}

ins(){
local argo_pid ins_started_at=$SECONDS phase_started_at=$SECONDS
install_required_xray=no
install_required_singbox=no
install_required_caddy=no
install_required_mita=no
install_required_argo=no
install_required_subscription=no
if [ "$rep_mode" = yes ]; then
  install_required_caddy="${rep_preserved_caddy_running:-no}"
else
  [ -n "$naive" ] && install_required_caddy=yes
fi
[ "$mierup" = yes ] && install_required_mita=yes
[ -n "$argo" ] && [ -n "$vmag" ] && install_required_argo=yes
[ "$sub" = yes ] && install_required_subscription=yes
if [ "$mierup" = yes ]; then
  validate_mita_platform || exit 1
fi
secondary_init_naive_sidecar || return 1
plan_deployment_ports || return 1
prepare_transport_paths || return 1
printf '端口与路径准备完成（耗时 %s 秒）。\n' "$((SECONDS - phase_started_at))"
[ "$rep_mode" = yes ] || enable_system_bbr
# Mieru/Mita 是独立系统服务，不参与 Xray/Sing-box 内核归属判断；设置 mieru=y（或预设 mierupt）时单独安装。
if [ "$mierup" = yes ]; then
  installmita || exit 1
fi
# Naive 二级出站的 Caddy 与 Sing-box 必须引用同一个持久化回环端口。
secondary_init_naive_sidecar || exit 1
# Caddy 必须先启动以获取证书；先落盘不含密码的链路契约，确保后续 sidecar 失败也能被状态页识别为失败关闭。
secondary_protocol_is_selected naive && persist_secondary_proxy_state
# NaiveProxy（Caddy）优先装配：先让 Caddy 起来并自动托管签发真实域名证书，
# 之后 hy2/tuic/anytls/xhy2 等 TLS 节点在 setup_tls_certificate 中复用该证书（SNI=naive 域名）。
# 仅当显式设置 naive=<域名> 时执行，与 xray/sing-box 隔离并存；Caddy 用独立端口(443)，不与代理内核抢占。
if [ -n "$naive" ] && [ "$rep_mode" = yes ]; then
  echo "rep 模式：保留现有 Naive/Caddy 服务、配置和证书，不重新安装或重载 Caddy。"
elif [ -n "$naive" ]; then
  if secondary_protocol_is_selected naive; then
    installcaddy || { secondary_error "Naive 二级出站依赖 Caddy，配置失败后已停止安装。"; exit 1; }
  else
    installcaddy || { echo "NaiveProxy(Caddy) 配置或证书校验失败，已停止安装。"; exit 1; }
  fi
fi
# 先满足订阅的公信 CA 要求，再生成任意核心配置，所有 TLS 入口复用同一份最终证书。
if [ "$sub" = yes ]; then
  setup_tls_certificate || return 1
  subscription_certificate_host "$cdnym" >/dev/null || return 1
fi
local need_xray=no need_singbox=no
# 先按阶段一既有规则决定原生协议归属，再额外加入 Naive sidecar 的 Sing-box 需求；
# 这样仅启用 vmpt/sopt 时仍默认落在 Xray，不会因 sidecar 被悄悄迁移到 Sing-box。
if [ "$xhp" = yes ] || [ "$vlp" = yes ] || [ "$vxp" = yes ] || [ "$vwp" = yes ] || \
  [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || [ "$xvcdn" = yes ] || [ "$xvargo" = yes ]; then
  need_xray=yes
fi
if [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$ssp" = yes ]; then
  need_singbox=yes
fi
if [ "$vmp" = yes ] || [ "$sop" = yes ]; then
  determine_secondary_common_core
  if [ "$secondary_common_core" = sb ]; then need_singbox=yes; else need_xray=yes; fi
fi
secondary_protocol_is_selected naive && need_singbox=yes
subscription_core=''
if [ "$sub" = yes ]; then
  if [ "$need_xray" = yes ]; then
    subscription_core=xray
  else
    subscription_core=singbox
    need_singbox=yes
  fi
fi
install_required_xray="$need_xray"
install_required_singbox="$need_singbox"

if [ "$need_xray" = yes ] || [ "$need_singbox" = yes ]; then
  if [ "$need_xray" = yes ] && [ "$need_singbox" = no ]; then
    installxray || return 1
    xrsbvm || return 1
    xrsbso || return 1
    warpsx || return 1
    xrsbout || return 1
    hyp="shyptargo"; tup="tuptargo"; anp="anptargo"; arp="arptargo"; ssp="ssptargo"
  elif [ "$need_xray" = no ] && [ "$need_singbox" = yes ]; then
    installsb || return 1
    xrsbvm || return 1
    xrsbso || return 1
    warpsx || return 1
    xrsbout || return 1
    xhp="xhptargo"; vlp="vlptargo"; vxp="vxptargo"; vwp="vwptargo"; xhyp="xhyptargo"; xdns="xdnstargo"; xicp="xicptargo"; xvcdn="xvcdnptargo"; xvargo="xvargoptargo"
  else
    installsb || return 1
    installxray || return 1
    xrsbvm || return 1
    xrsbso || return 1
    warpsx || return 1
    xrsbout || return 1
  fi
fi

# B 节点凭据只保留在 xr.json/sb.json；状态卡仅落盘无密码的协议、地址与端口。
persist_secondary_proxy_state

# 双内核 Hysteria 2 跳跃端口规则解耦挂载
# Sing-box 驱动的 Hysteria 2：shyjpt -> port_hy2
if [ -n "$shyjpt" ]; then
  local_hy2_port=$(cat "$HOME/agsbx/port_hy2" 2>/dev/null)
  if [ -n "$local_hy2_port" ]; then
    setup_port_hopping "$shyjpt" "$local_hy2_port" || return 1
    echo "$shyjpt" > "$HOME/agsbx/shyjpt"
  fi
fi
# Xray 驱动的 Hysteria 2：xhyjpt -> port_xhy2
if [ -n "$xhyjpt" ]; then
  local_xhy2_port=$(cat "$HOME/agsbx/port_xhy2" 2>/dev/null)
  if [ -n "$local_xhy2_port" ]; then
    setup_port_hopping "$xhyjpt" "$local_xhy2_port" || return 1
    echo "$xhyjpt" > "$HOME/agsbx/xhyjpt"
  fi
fi

if [ -n "$argo" ] && [ -n "$vmag" ]; then
local argo_fixed=no argo_token_tmp
if { [ -n "${ARGO_DOMAIN}" ] && [ -z "${ARGO_AUTH}" ]; } \
  || { [ -z "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; }; then
  echo "错误：固定 Argo 隧道必须同时提供 agn 域名和 agk token。"
  return 1
fi
if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
  argo_fixed=yes
  case "$ARGO_AUTH" in
  *$'\n'*|*$'\r'*) echo "错误：Argo token 不得包含换行符。"; return 1 ;;
  esac
fi
echo
printf '%s\n' "${C_CYAN}=========启用Cloudflared-argo内核=========${C_RESET}"
if [ ! -e "$HOME/agsbx/cloudflared" ]; then
local metadata tag expected actual stage asset="cloudflared-linux-$cpu"
metadata=$(release_json cloudflare/cloudflared latest) && tag=$(release_tag "$metadata") \
  && expected=$(release_asset_digest "$metadata" "$asset") || { echo "错误：无法确认 Cloudflared 资产及 SHA256。"; return 1; }
stage=$(mktemp "$HOME/agsbx/.cloudflared.XXXXXX") || return 1
if ! fetch_file "https://github.com/cloudflare/cloudflared/releases/download/$tag/$asset" "$stage"; then rm -f "$stage"; return 1; fi
actual=$(sha256sum "$stage" | awk '{print $1}')
if [ "$expected" != "$actual" ] || ! chmod 700 "$stage" || ! "$stage" --version >/dev/null 2>&1; then
  rm -f "$stage"; echo "错误：Cloudflared 完整性或可执行性检查失败。"; return 1
fi
mv -f -- "$stage" "$HOME/agsbx/cloudflared" || { rm -f "$stage"; return 1; }
fi
if [ "$argo" = "vmpt" ]; then argoport=$(cat "$HOME/agsbx/port_vm_ws" 2>/dev/null); echo "Vmess" > "$HOME/agsbx/vlvm"; elif [ "$argo" = "vwpt" ]; then argoport=$(cat "$HOME/agsbx/port_vw" 2>/dev/null); echo "Vless" > "$HOME/agsbx/vlvm"; elif [ "$argo" = "xvargopt" ]; then argoport=$(cat "$HOME/agsbx/port_xvargo" 2>/dev/null); echo "Vlessenc-xhttp-vision" > "$HOME/agsbx/vlvm"; fi; echo "$argoport" > "$HOME/agsbx/argoport.log"
# 新 XHTTP 使用回环 HTTP；旧 HTTPS 部署的 res/回滚仍从原状态恢复。
argo_origin_from_state
if [ "$argo_fixed" = yes ]; then
if ! cloudflared_supports_token_file; then
  echo "错误：当前 Cloudflared 不支持 --token-file（需 2025.4.0 或更高版本）。"
  echo "为避免 token 暴露在进程参数中，脚本不会回退到 --token。"
  return 1
fi
[ -d "$HOME/agsbx" ] && [ ! -L "$HOME/agsbx" ] \
  || { echo "错误：Argo token 目录不安全。"; return 1; }
[ ! -L "$argo_token_file" ] || { echo "错误：拒绝将 Argo token 写入符号链接。"; return 1; }
argo_token_tmp=$(mktemp "$HOME/agsbx/.sbargotoken.XXXXXX") || { echo "错误：无法创建 Argo token 临时文件。"; return 1; }
if ! printf '%s' "$ARGO_AUTH" > "$argo_token_tmp" \
  || ! chmod 600 "$argo_token_tmp" \
  || ! mv -f -- "$argo_token_tmp" "$argo_token_file"; then
  rm -f -- "$argo_token_tmp"
  echo "错误：无法安全保存 Argo token。"
  return 1
fi
unset ARGO_AUTH
argoname='固定'
if pidof systemd >/dev/null 2>&1 && is_root; then
write_argo_systemd_service || { echo "错误：无法写入 argo.service。"; return 1; }
systemctl daemon-reload >/dev/null 2>&1 || { echo "错误：Argo systemd daemon-reload 失败。"; return 1; }
systemctl enable argo >/dev/null 2>&1 || { echo "错误：无法启用 argo.service。"; return 1; }
systemctl start argo >/dev/null 2>&1 || { echo "错误：无法启动 argo.service。"; return 1; }
systemctl is-active --quiet argo || { echo "错误：argo.service 启动后未保持 active。"; return 1; }
elif command -v rc-service >/dev/null 2>&1 && is_root; then
write_argo_openrc_service || { echo "错误：无法写入 OpenRC argo 服务。"; return 1; }
rc-update add argo default >/dev/null 2>&1 || { echo "错误：无法启用 OpenRC argo 服务。"; return 1; }
rc-service argo start 8>&- >/dev/null 2>&1 || { echo "错误：无法启动 OpenRC argo 服务。"; return 1; }
else
nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file "$argo_token_file" 8>&- > "$HOME/agsbx/argo.log" 2>&1 &
argo_pid=$!
sleep 1
kill -0 "$argo_pid" >/dev/null 2>&1 || { echo "错误：Cloudflared Argo 后台进程启动失败。"; return 1; }
fi
echo "${ARGO_DOMAIN}" > "$HOME/agsbx/sbargoym.log"
[ "$argo" = "xvargopt" ] && echo "固定隧道回源需配置为 http://127.0.0.1:${argoport}（HTTP，无需 noTLSVerify 或 HTTP/2 回源）。"
else
argoname='临时'
nohup "$HOME/agsbx/cloudflared" tunnel --url "${argoscheme}://${argo_origin_host}:${argoport}" ${argoxtls}--edge-ip-version auto --no-autoupdate --protocol http2 8>&- > "$HOME/agsbx/argo.log" 2>&1 &
argo_pid=$!
sleep 1
kill -0 "$argo_pid" >/dev/null 2>&1 || { echo "错误：临时 Argo 后台进程启动失败。"; return 1; }
fi
echo "申请Argo$argoname隧道中……请稍等"
sleep 2
if [ "$argo_fixed" = yes ]; then
  argodomain=$(cat "$HOME/agsbx/sbargoym.log" 2>/dev/null)
else
  # [弹性轮询解析] 使用最大 15 秒的正则匹配轮询提取已分配的 trycloudflare 域名
  local retry=0
  while [ $retry -lt 15 ]; do
    argodomain=$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' "$HOME/agsbx/argo.log" 2>/dev/null | head -n1)
    [ -n "$argodomain" ] && break
    sleep 1
    retry=$((retry + 1))
  done
fi
if [ -n "${argodomain}" ]; then
echo "Argo$argoname隧道申请成功"
else
echo "Argo$argoname隧道申请失败，请稍后再试"
return 1
fi
fi
# NaiveProxy（Caddy）已在本函数开头优先装配并签发证书（供 TLS 节点复用），此处不再重复。
# 下方按组件重试就绪检查，无需所有安装都固定等待 5 秒。
echo
verify_install_required_components no || return 1
# 把 agsbx 装进 /usr/local/bin（root 默认 PATH 内）：安装完当前 SSH 会话即可直接用 agsbx，
# 无需改 PATH、无需退出重连。旧版装在 $HOME/bin 并往 .bashrc 注入 PATH，因子进程改不了父 shell 环境才被迫要重登录。
# 首次安装/完整重装时清理旧版残留；rep 不处理用户 shell 配置或旧快捷方式。
install_script_shortcut current || return 1
refresh_runtime_cron || return 1
migrate_certificate_jobs || return 1
[ -z "$port_plan_file" ] || rm -f -- "$port_plan_file"
printf '安装编排完成（耗时 %s 秒；不含前置检查和订阅输出）。\n' "$((SECONDS - ins_started_at))"
}
#============================================================
# [第9段] 状态查询与节点大卡片渲染函数
#------------------------------------------------------------
# 🎯 架构说明:
# - 本大段包含 airgosbxstatus() (核心服务运行状态轮询)、cip() (所有订阅生成、Clash 动态片段拼接、卡片高维度精美排版打印)。
# - 关联性: 由第 12 段 (主入口) 在初始化完毕或第 11 段 (upx/ups内核更新/list查看) 时调用，是负责对用户渲染输出的最强表现层。
#============================================================
airgosbxstatus(){
local procs mita_status mita_ver
printf '%s\n' "${C_CYAN}========= 当前内核运行状态 =========${C_RESET}"

# 内核状态判定助手：进程是否在跑，叠加"配置 × 二进制"两个独立条件，共五种输出。
#   运行中        ：进程在（优先级最高，与配置/二进制无关）
#   启用失败/未运行：配置在 + 二进制在，但进程不在 → 配置已生成却没跑起来，指向日志
#   未下载        ：配置在 + 二进制不在 → 本次启用了该内核但下载失败
#   已下载但未启用：配置不在 + 二进制在 → rep 只重置配置、不删二进制，残留内核本次未配置
#   未配置        ：配置不在 + 二进制不在 → 本次未启用且无内核，中性提示
# $1显示名 $2二进制 $3配置文件(判定本应运行) $4进程匹配 $5版本类型 $6日志路径
kstat(){
  local name="$1" bin="$2" cfg="$3" pat="$4" kind="$5" log="$6" ver=""
  # ① 进程在 → 运行中
  if agsbx_component_running "${bin##*/}"; then
    case "$kind" in
      xray) ver=$("$bin" version 2>/dev/null | awk '/^Xray/{print $2}') ;;
      sb)   ver=$("$bin" version 2>/dev/null | awk '/version/{print $NF}') ;;
      argo) ver=$("$bin" version 2>/dev/null | awk '{print $3}') ;;
      caddy) ver=$("$bin" version 2>/dev/null | awk '{print $1}' | sed 's/^v//') ;;
    esac
    printf '%s\n' "${name} (版本V${ver})：${C_GREEN}运行中${C_RESET}"
    return
  fi
  # ② 进程不在 → 按"配置是否存在 × 二进制是否存在"四象限细分
  if [ -s "$cfg" ]; then
    if [ -s "$bin" ]; then
      printf '%s\n' "${name}：${C_RED}启用失败/未运行${C_RESET}（配置已生成但进程不在，查日志：$log）"
    else
      printf '%s\n' "${name}：${C_YELLOW}未下载（内核下载失败，请重试 upx/ups）${C_RESET}"
    fi
  else
    if [ -s "$bin" ]; then
      printf '%s\n' "${name}：已下载但未启用（内核已存在，本次未配置该协议）"
    else
      printf '%s\n' "${name}：未配置（本次未启用且无内核）"
    fi
  fi
}
kstat "Sing-box" "$HOME/agsbx/sing-box"    "$HOME/agsbx/sb.json"      'agsbx/sing-box'   sb   "$HOME/agsbx/sing-box.log"
kstat "Xray"     "$HOME/agsbx/xray"        "$HOME/agsbx/xr.json"      'agsbx/xray'       xray "$HOME/agsbx/xray.log"
kstat "Caddy"    "$HOME/agsbx/caddy"       "$HOME/agsbx/Caddyfile"    'agsbx/caddy'      caddy "$HOME/agsbx/caddy.log"
kstat "Argo"     "$HOME/agsbx/cloudflared" "$HOME/agsbx/argoport.log" 'agsbx/cloudflared' argo "$HOME/agsbx/argo.log"
if [ -f "$HOME/agsbx/mita_managed" ]; then
  if [ ! -s "$HOME/agsbx/mita.json" ]; then
    printf '%s\n' "Mita：已安装但未启用（执行 mieru=y agsbx rep 可重新启用）"
  else
    mita_status=$(mita status 2>&1)
    mita_ver=$(mita version 2>/dev/null | head -1 | awk '{print $NF}' | sed 's/^v//')
    if printf '%s' "$mita_status" | grep -q 'RUNNING'; then
      printf '%s\n' "Mita (版本V${mita_ver})：${C_GREEN}Mieru 代理运行中${C_RESET}"
    elif printf '%s' "$mita_status" | grep -q 'IDLE'; then
      printf '%s\n' "Mita (版本V${mita_ver})：${C_YELLOW}daemon 在线，代理已停止${C_RESET}"
    else
      printf '%s\n' "Mita：${C_RED}daemon 不可用${C_RESET}（检查：systemctl status mita）"
    fi
  fi
fi
if secondary_saved_protocol_is_selected naive; then
  local caddy_online=no sb_online=no sidecar_ready=no sidecar_port
  if agsbx_component_running caddy; then caddy_online=yes; fi
  if agsbx_component_running sing-box; then sb_online=yes; fi
  sidecar_port=$(cat "$HOME/agsbx/naive_secondary_port" 2>/dev/null)
  if [ -n "$sidecar_port" ] && \
    grep -Fq "@127.0.0.1:$sidecar_port" "$HOME/agsbx/Caddyfile" 2>/dev/null && \
    grep -q '"tag"[[:space:]]*:[[:space:]]*"naive-secondary-in"' "$HOME/agsbx/sb.json" 2>/dev/null && \
    grep -q '"tag"[[:space:]]*:[[:space:]]*"secondary-out"' "$HOME/agsbx/sb.json" 2>/dev/null && \
    port_is_listening "$sidecar_port"; then
    sidecar_ready=yes
  fi
  if [ "$caddy_online" = yes ] && [ "$sb_online" = yes ] && [ "$sidecar_ready" = yes ]; then
    printf '%s\n' "Naive 二级链路：${C_GREEN}本地转交就绪${C_RESET}（Caddy → Sing-box → B；未主动探测 B）"
  elif [ "$caddy_online" = yes ]; then
    printf '%s\n' "Naive 二级链路：${C_YELLOW}失败关闭${C_RESET}（伪装站在线；sidecar/配置未就绪；不会回退直连）"
  elif [ "$sb_online" = yes ]; then
    printf '%s\n' "Naive 二级链路：${C_YELLOW}Naive 入站不可用${C_RESET}（Sing-box sidecar 在线，Caddy 未运行）"
  else
    printf '%s\n' "Naive 二级链路：${C_RED}未运行${C_RESET}"
  fi
fi
}
cip(){
local cip_mode="${1:-show}" node_links='' clash_config='' subtoken='' server_host render_cert_hash
if [ "$cip_mode" = publish ]; then
  [ "$sub" != yes ] || setup_tls_certificate || return 1
else
  sub=''
  if [ -s "$HOME/agsbx/subtoken.log" ] && [ -d "$HOME/websbx" ]; then sub=yes; fi
fi
render_cert_hash=$(certificate_fingerprint 2>/dev/null)
local direct_xh_options='' direct_xh_title='' direct_vl_options='' direct_vl_title='' direct_vl_export_yaml=no
# 同一进程重复展示时，不能复用上次定义的可选协议订阅函数。
unset -f clvlpt clvlpt1 clvmpt clvmpt1 clxhypt clxhypt1 clmierupt clmierupt1
ipbest(){
# 优先复用 v4v6() 已探测到的地址，两者皆空时才重新发起外网探测
first_family="$ip_policy_preferred_family"
if [ "$first_family" = 6 ]; then
  serip="${v6:-$v4}"
  second_family=4
else
  serip="${v4:-$v6}"
  second_family=6
fi
if [ -z "$serip" ]; then
  serip=$( (command -v curl >/dev/null 2>&1 && (curl -s"$first_family"m5 "$v46url" 2>/dev/null || curl -s"$second_family"m5 "$v46url" 2>/dev/null) ) \
    || (command -v wget >/dev/null 2>&1 && (timeout 3 wget -"$first_family" -qO- --tries=2 "$v46url" 2>/dev/null || timeout 3 wget -"$second_family" -qO- --tries=2 "$v46url" 2>/dev/null) ) )
fi
serip=$(printf '%s\n' "$serip" | sed -n '1{s/[[:space:]]//g;p;}')
valid_ip "$serip" || { echo "错误：无法取得有效的 VPS 公网地址。"; return 1; }
if echo "$serip" | grep -q ':'; then
server_ip="[$serip]"
else
server_ip="$serip"
fi
if [ "$cip_mode" = publish ]; then atomic_text_file "$HOME/agsbx/server_ip.log" "$server_ip" || return 1; fi
}
ipchange(){
v4v6
if [ -z "$v4" ]; then
vps_ipv4='无IPV4'
vps_ipv6="$v6"
location="$v6dq"
elif [ -n "$v4" ] && [ -n "$v6" ]; then
vps_ipv4="$v4"
vps_ipv6="$v6"
location="$v4dq"
else
vps_ipv4="$v4"
vps_ipv6='无IPV6'
location="$v4dq"
fi
if echo "$v6" | grep -q '^2a09'; then
w6="【WARP】"
fi
if echo "$v4" | grep -q '^104.28'; then
w4="【WARP】"
fi
echo
airgosbxstatus
echo
printf '%s\n' "${C_CYAN}=========当前服务器本地IP情况=========${C_RESET}"
echo "本地IPV4地址：$vps_ipv4 $w4"
echo "本地IPV6地址：$vps_ipv6 $w6"
echo "服务器地区：$location"
echo
sleep 2
if [ "$ippz" = "4" ]; then
if [ -z "$v4" ]; then
ipbest
else
server_ip="$v4"
if [ "$cip_mode" = publish ]; then atomic_text_file "$HOME/agsbx/server_ip.log" "$server_ip" || return 1; fi
fi
elif [ "$ippz" = "6" ]; then
if [ -z "$v6" ]; then
ipbest
else
server_ip="[$v6]"
if [ "$cip_mode" = publish ]; then atomic_text_file "$HOME/agsbx/server_ip.log" "$server_ip" || return 1; fi
fi
else
ipbest
fi
}
ipchange || return 1
uuid=$(cat "$HOME/agsbx/uuid" 2>/dev/null)
server_host=${server_ip#[}; server_host=${server_host%]}
sxname=$(cat "$HOME/agsbx/name" 2>/dev/null)
valid_plain_text "$uuid" 256 && valid_plain_text "$sxname" 1024 || { echo "错误：节点凭据或名称状态无效。"; return 1; }
xvvmcdnym=$(cat "$HOME/agsbx/cdnym" 2>/dev/null)
section "Airgosbx 脚本输出节点配置如下"
echo
if [ -s "$HOME/agsbx/secondary_secp" ] && [ -s "$HOME/agsbx/secondary_meta" ]; then
secondary_saved_secp=$(cat "$HOME/agsbx/secondary_secp" 2>/dev/null)
secondary_saved_scheme=$(sed -n '1p' "$HOME/agsbx/secondary_meta" 2>/dev/null)
secondary_saved_server=$(sed -n '2p' "$HOME/agsbx/secondary_meta" 2>/dev/null)
secondary_saved_port=$(sed -n '3p' "$HOME/agsbx/secondary_meta" 2>/dev/null)
secondary_saved_display="$secondary_saved_server"
valid_ipv6 "$secondary_saved_server" && secondary_saved_display="[$secondary_saved_server]"
node_title "💣【 二级代理出站 】A VPS 经 B VPS 访问目标服务器："
echo "生效范围（A VPS 入站协议）：$secondary_saved_secp"
echo "上游端点（B VPS 入站）：$secondary_saved_scheme://$secondary_saved_display:$secondary_saved_port（认证信息已隐藏）"
echo
fi
case "$server_ip" in
104.28*|\[2a09*) echo "检测到有WARP的IP作为客户端地址 (104.28或者2a09开头的IP)，请把客户端地址上的WARP的IP手动更换为VPS本地IPV4或者IPV6地址" && sleep 3 ;;
esac
echo
ym_vl_re=$(cat "$HOME/agsbx/ym_vl_re" 2>/dev/null)
if [ -e "$HOME/agsbx/xray" ]; then
private_key_x=$(cat "$HOME/agsbx/xrk/private_key" 2>/dev/null)
public_key_x=$(cat "$HOME/agsbx/xrk/public_key" 2>/dev/null)
short_id_x=$(cat "$HOME/agsbx/xrk/short_id" 2>/dev/null)
enkey=$(cat "$HOME/agsbx/xrk/enkey" 2>/dev/null)
fi
if [ -e "$HOME/agsbx/sing-box" ]; then
private_key_s=$(cat "$HOME/agsbx/sbk/private_key" 2>/dev/null)
public_key_s=$(cat "$HOME/agsbx/sbk/public_key" 2>/dev/null)
short_id_s=$(cat "$HOME/agsbx/sbk/short_id" 2>/dev/null)
sskey=$(cat "$HOME/agsbx/sskey" 2>/dev/null)
fi
# 旧参数仅用于 update 后尚未重建的入站；新直连/CDN/Tunnel 都读取配套 profile。
xh_extra='{"noGRPCHeader":false,"noSSEHeader":false,"xPaddingObfsMode":true,"xPaddingBytes":"100-1000","xPaddingKey":"cf_clearance","xPaddingHeader":"Referer","xPaddingPlacement":"queryInHeader","xPaddingMethod":"repeat-x","uplinkHTTPMethod":"POST","sessionPlacement":"path","sessionKey":"","seqPlacement":"path","seqKey":"","uplinkDataPlacement":"body","uplinkDataKey":"","uplinkChunkSize":0,"scMaxEachPostBytes":1000000,"scMinPostsIntervalMs":"10-50","scMaxBufferedPosts":30,"scStreamUpServerSecs":"20-80","maxConcurrency":"16-32","maxConnections":"0-0","cMaxReuseTimes":"64-128","hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":45,"downloadTargetHost":"","downloadTargetPort":0,"downloadServerName":"","downloadHTTPHost":""}'
# 旧 TCP 入站的历史链保持原样；新建/rep 的 fragment 只存在于客户端参数中。
legacy_direct_tcp_fm="{\"tcp\":[{\"type\":\"fragment\",\"settings\":{\"packets\":\"tlshello\",\"length\":\"100-200\",\"delay\":\"10-20\",\"maxSplit\":\"3-6\"}},{\"type\":\"sudoku\",\"settings\":{\"password\":\"$uuid\",\"paddingMin\":16,\"paddingMax\":64}}]}"
# 旧 XHTTP FM 同样只供兼容展示，不再写入新的 CDN/Tunnel 入站。
fm_xh_config="{\"tcp\":[{\"type\":\"sudoku\",\"settings\":{\"password\":\"$uuid\",\"paddingMin\":16,\"paddingMax\":64}}],\"udp\":[{\"type\":\"noise\",\"settings\":{\"reset\":\"30-60\",\"noise\":[{\"rand\":\"32-128\",\"randRange\":\"0-255\",\"delay\":\"10-20\"}]}}]}"
local profile_key profile_tag legacy_extra legacy_fm profile_spec
for profile_spec in xh:xhttp-reality vl:reality-vision vx:vless-xhttp vw:vless-ws vm:vmess-xr hy:hy2-xr xvd:vlessenc-xhttp-cdn xva:vlessenc-xhttp-argo; do
  profile_key=${profile_spec%%:*}; profile_tag=${profile_spec#*:}
  local "profile_${profile_key}_options=" "profile_${profile_key}_mode=auto" "profile_${profile_key}_suffix=" "profile_${profile_key}_fm=" "profile_${profile_key}_transport=xhttp"
  grep -Fq "\"$profile_tag\"" "$HOME/agsbx/xr.json" 2>/dev/null || continue
  legacy_extra=''; legacy_fm=''
  case "$profile_key" in
    xh|xvd|xva) legacy_extra="$xh_extra"; legacy_fm="$fm_xh_config" ;;
    vx) legacy_extra="$xh_extra" ;;
    vl) legacy_fm="$legacy_direct_tcp_fm" ;;
  esac
  load_xray_profile "$profile_key" "$legacy_extra" "$legacy_fm" || return 1
  printf -v "profile_${profile_key}_options" '%s' "$direct_url_options"
  printf -v "profile_${profile_key}_mode" '%s' "$direct_client_mode"
  printf -v "profile_${profile_key}_suffix" '%s' "$direct_fm_label"
  printf -v "profile_${profile_key}_transport" '%s' "xhttp$direct_extra_label"
  printf -v "profile_${profile_key}_fm" '%s' "$direct_fm_encoded"
done
direct_xh_options="$profile_xh_options"
direct_xh_title="${sxname}vlessenc-${profile_xh_transport}-reality-vision${profile_xh_suffix}-$hostname"
direct_vl_options="$profile_vl_options"
direct_vl_title="${sxname}vless-tcp-reality-vision${profile_vl_suffix}-$hostname"
[ -n "$profile_vl_fm" ] || direct_vl_export_yaml=yes
# 配套状态全部读取成功后才重建聚合链接，避免状态损坏时清空旧节点文件。
node_links=''
if grep -q xhttp-reality "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 $direct_xh_title 】节点信息如下："
port_xh=$(cat "$HOME/agsbx/port_xh")
vl_xh_link="vless://$(uri_percent_encode "$uuid")@$server_ip:$port_xh?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&security=reality&sni=$(uri_percent_encode "$ym_vl_re")&fp=chrome&pbk=$(uri_percent_encode "$public_key_x")&sid=$(uri_percent_encode "$short_id_x")&type=xhttp&path=$(uri_percent_encode "$(transport_path xh)")&mode=$profile_xh_mode${direct_xh_options}#$(uri_percent_encode "$direct_xh_title")"
append_node_link "$vl_xh_link" || return 1
echo "$vl_xh_link"
echo
if [ "$sub" = yes ]; then
echo "提示：xhpt 的完整 ENC/extra/FM 参数包含在上方 VLESS URL 和聚合订阅中；当前 Clash 模板不输出这个 ENC 节点。"
fi
fi
if grep -q vlessenc-xhttp-cdn "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 VLESS Encryption＋${profile_xvd_transport}＋TLS＋Vision CDN$profile_xvd_suffix 】"
port_xvcdn=$(cat "$HOME/agsbx/port_xvcdn")
xvvmcdnym=$(cat "$HOME/agsbx/cdnym" 2>/dev/null)
valid_domain "$xvvmcdnym" || { echo "错误：CDN 域名状态缺失，无法生成正确的 Host/SNI。"; return 1; }
vl_xvcdn_link="vless://$(uri_percent_encode "$uuid")@$xvvmcdnym:$port_xvcdn?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&security=tls&alpn=h2&sni=$(uri_percent_encode "$xvvmcdnym")&host=$(uri_percent_encode "$xvvmcdnym")&type=xhttp&path=$(uri_percent_encode "$(transport_path xvd)")&mode=$profile_xvd_mode${profile_xvd_options}#$(uri_percent_encode "${sxname}vlessenc-${profile_xvd_transport}-tls-vision-cdn${profile_xvd_suffix}-$hostname")"
append_node_link "$vl_xvcdn_link" || return 1
echo "$vl_xvcdn_link"
echo
[ "$sub" != yes ] || echo "CDN ENC 节点使用完整 VLESS URL/聚合订阅；不输出缺少 ENC/extra/FM 的 Clash 节点。"
fi
if grep -q vless-xhttp "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 VLESS Encryption＋${profile_vx_transport}＋Vision$profile_vx_suffix 】"
port_vx=$(cat "$HOME/agsbx/port_vx")
vl_vx_link="vless://$(uri_percent_encode "$uuid")@$server_ip:$port_vx?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&security=none&type=xhttp&path=$(uri_percent_encode "$(transport_path vx)")&mode=$profile_vx_mode${profile_vx_options}#$(uri_percent_encode "${sxname}vlessenc-${profile_vx_transport}-vision${profile_vx_suffix}-$hostname")"
append_node_link "$vl_vx_link" || return 1
echo "$vl_vx_link"
echo
if [ -f "$HOME/agsbx/cdnym" ] && [ -z "$profile_vx_fm" ]; then
xvvmcdnym=$(cat "$HOME/agsbx/cdnym")
valid_domain "$xvvmcdnym" || return 1
vl_vx_cdn_link="vless://$(uri_percent_encode "$uuid")@$xvvmcdnym:$port_vx?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&security=none&type=xhttp&host=$(uri_percent_encode "$xvvmcdnym")&path=$(uri_percent_encode "$(transport_path vx)")&mode=$profile_vx_mode${profile_vx_options}#$(uri_percent_encode "${sxname}vlessenc-${profile_vx_transport}-vision-cdn${profile_vx_suffix}-$hostname")"
append_node_link "$vl_vx_cdn_link" || return 1
echo "$vl_vx_cdn_link"
echo
fi
fi
if grep -q vless-ws "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vlessenc-ws-vision 】支持ENC加密，节点信息如下："
port_vw=$(cat "$HOME/agsbx/port_vw")
vl_vw_link="vless://$(uri_percent_encode "$uuid")@$server_ip:$port_vw?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&security=none&type=ws&path=$(uri_percent_encode "$(transport_path vw)")${profile_vw_options}#$(uri_percent_encode "${sxname}vlessenc-ws-vision${profile_vw_suffix}-$hostname")"
append_node_link "$vl_vw_link" || return 1
echo "$vl_vw_link"
echo
if [ -f "$HOME/agsbx/cdnym" ] && [ -z "$profile_vw_fm" ]; then
node_title "💣【 Vlessenc-ws-vision-cdn 】支持ENC加密，节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vl_vw_cdn_link="vless://$(uri_percent_encode "$uuid")@icook.hk:$port_vw?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&type=ws&host=$xvvmcdnym&path=$(uri_percent_encode "$(transport_path vw)")#$(uri_percent_encode "${sxname}vlessenc-ws-vision-cdn-$hostname")"
append_node_link "$vl_vw_cdn_link" || return 1
echo "$vl_vw_cdn_link"
echo
fi
fi
if grep -q reality-vision "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 $direct_vl_title 】节点信息如下："
port_vl_re=$(cat "$HOME/agsbx/port_vl_re")
vl_link="vless://$(uri_percent_encode "$uuid")@$server_ip:$port_vl_re?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(uri_percent_encode "$ym_vl_re")&fp=chrome&pbk=$(uri_percent_encode "$public_key_x")&sid=$(uri_percent_encode "$short_id_x")&type=tcp&headerType=none${direct_vl_options}#$(uri_percent_encode "$direct_vl_title")"
append_node_link "$vl_link" || return 1
echo "$vl_link"
echo
if [ "$sub" = yes ] && [ "$direct_vl_export_yaml" = yes ]; then
clvlpt(){
cat <<EOF
- name: "$(json_escape "$direct_vl_title")"
  type: vless
  server: "$(json_escape "$server_host")"
  port: $port_vl_re
  uuid: "$(json_escape "$uuid")"
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $ym_vl_re
  reality-opts:
    public-key: $public_key_x
    short-id: $short_id_x
  client-fingerprint: chrome
EOF
}
clvlpt1(){
printf -- '- "%s"\n' "$(json_escape "$direct_vl_title")"
}
elif [ "$sub" = yes ]; then
echo "提示：带 FM 的 vlpt 请使用完整 VLESS URL 或聚合订阅；当前 Clash 模板不输出缺少掩码的节点。"
fi
fi
if grep -q vless-kcp-xdns "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vless-kcp-xdns-fm 】备用DNS隧道，节点信息如下："
port_xdns=$(cat "$HOME/agsbx/port_xdns")
xdnsym=$(cat "$HOME/agsbx/xdns_domain" 2>/dev/null)
[ -n "$xdnsym" ] || xdnsym=$(sed -n 's/.*"domains": \["\([^"]*\)"\].*/\1/p' "$HOME/agsbx/xr.json" | head -1)
valid_domain "$xdnsym" || { echo "错误：XDNS 域名状态无效。"; return 1; }
xdns_fm="{\"udp\":[{\"type\":\"xdns\",\"settings\":{\"domains\":[\"$xdnsym\"]}}]}"
xdns_fm_encoded=$(printf '%s' "$xdns_fm" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
vl_xdns_link="vless://$(uri_percent_encode "$uuid")@$server_ip:$port_xdns?encryption=none&flow=&type=kcp&headerType=none&fm=$xdns_fm_encoded#$(uri_percent_encode "${sxname}vless-kcp-xdns-fm-$hostname")"
append_node_link "$vl_xdns_link" || return 1
echo "$vl_xdns_link"
echo
fi
if grep -q vless-kcp-xicmp "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vless-kcp-xicmp-fm 】特种L3 Ping隧道，节点信息如下："
xicmp_fm="{\"udp\":[{\"type\":\"xicmp\",\"settings\":{\"listenIp\":\"0.0.0.0\",\"id\":0}}]}"
xicmp_fm_encoded=$(printf '%s' "$xicmp_fm" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
vl_xicmp_link="vless://$(uri_percent_encode "$uuid")@$server_ip:0?encryption=none&flow=&type=kcp&headerType=none&fm=$xicmp_fm_encoded#$(uri_percent_encode "${sxname}vless-kcp-xicmp-fm-$hostname")"
append_node_link "$vl_xicmp_link" || return 1
echo "$vl_xicmp_link"
echo
fi
if grep -q ss-2022 "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Shadowsocks-2022 】节点信息如下："
port_ss=$(cat "$HOME/agsbx/port_ss")
ss_method="2022-blake3-aes-128-gcm"
ss_link="ss://$(uri_percent_encode "$ss_method"):$(uri_percent_encode "$sskey")@$server_ip:$port_ss#$(uri_percent_encode "${sxname}Shadowsocks-2022-$hostname")"
append_node_link "$ss_link" || return 1
echo "$ss_link"
echo
if [ "$sub" = yes ]; then
clsspt(){
cat <<EOF
- name: "$(json_escape "${sxname}Shadowsocks-2022-$hostname")"
  type: ss
  server: "$(json_escape "$server_host")"
  port: $port_ss
  cipher: 2022-blake3-aes-128-gcm
  password: "$sskey"
  udp: true
  udp-over-tcp: true
  udp-over-tcp-version: 2
EOF
}
clsspt1(){
printf -- '- "%s"\n' "$(json_escape "${sxname}Shadowsocks-2022-$hostname")"
}
fi
fi
if grep -q vmess-xr "$HOME/agsbx/xr.json" 2>/dev/null || grep -q vmess-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Vmess-ws 】节点信息如下："
port_vm_ws=$(cat "$HOME/agsbx/port_vm_ws")
if [ -n "$profile_vm_fm" ]; then
# v2rayN 的标准 VMess URI 解析器读取 fm；旧 Base64 VMess 格式没有配套字段。
vm_link="vmess://$(uri_percent_encode "$uuid")@$server_ip:$port_vm_ws?encryption=auto&security=none&type=ws&path=$(uri_percent_encode "$(transport_path vm)")${profile_vm_options}#$(uri_percent_encode "${sxname}vmess-ws-fm-$hostname")"
else
vm_link="vmess://$(vmess_payload "${sxname}vm-ws-$hostname" "$server_host" "$port_vm_ws" "www.bing.com" "$(transport_path vm)" "" "")"
fi
append_node_link "$vm_link" || return 1
echo "$vm_link"
echo
if [ "$sub" = yes ] && [ -z "$profile_vm_fm" ]; then
clvmpt(){
cat <<EOF
- name: "$(json_escape "${sxname}vmess-ws-$hostname")"
  type: vmess
  server: "$(json_escape "$server_host")"
  port: $port_vm_ws
  uuid: "$(json_escape "$uuid")"
  alterId: 0
  cipher: auto
  udp: true
  tls: false
  network: ws
  servername: www.bing.com
  ws-opts:
    path: "$(transport_path vm)"
    headers:
      Host: www.bing.com
EOF
}
clvmpt1(){
printf -- '- "%s"\n' "$(json_escape "${sxname}vmess-ws-$hostname")"
}
fi
if [ -f "$HOME/agsbx/cdnym" ] && [ -z "$profile_vm_fm" ]; then
node_title "💣【 Vmess-ws-cdn 】节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vm_cdn_link="vmess://$(vmess_payload "${sxname}vm-ws-cdn-$hostname" "icook.hk" "$port_vm_ws" "$xvvmcdnym" "$(transport_path vm)" "" "")"
append_node_link "$vm_cdn_link" || return 1
echo "$vm_cdn_link"
echo
if [ "$sub" = yes ]; then
clvmcdnpt(){
cat <<EOF
- name: "$(json_escape "${sxname}vmess-ws-cdn-$hostname")"
  type: vmess
  server: icook.hk
  port: $port_vm_ws
  uuid: "$(json_escape "$uuid")"
  alterId: 0
  cipher: auto
  udp: true
  tls: false
  network: ws
  servername: "$xvvmcdnym"
  ws-opts:
    path: "$(transport_path vm)"
    headers:
      Host: "$xvvmcdnym"
EOF
}
clvmcdnpt1(){
printf -- '- "%s"\n' "$(json_escape "${sxname}vmess-ws-cdn-$hostname")"
}
fi
fi
fi
if grep -q anytls-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 AnyTLS 】节点信息如下："
port_an=$(cat "$HOME/agsbx/port_an")
ran_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
if cert_trusted "$cert_mode" && [ -n "$ran_sni" ]; then
an_link="anytls://$(uri_percent_encode "$uuid")@$server_ip:$port_an?sni=$(uri_percent_encode "$ran_sni")&insecure=0&allowInsecure=0#$(uri_percent_encode "${sxname}anytls-$hostname")"
else
an_link="anytls://$(uri_percent_encode "$uuid")@$server_ip:$port_an?sni=$(uri_percent_encode "$ran_sni")&insecure=0&allowInsecure=0#$(uri_percent_encode "${sxname}anytls-$hostname")"
fi
append_node_link "$an_link" || return 1
if ! cert_trusted "$cert_mode"; then echo "此节点使用自签证书；请先信任证书或固定指纹 $render_cert_hash，勿仅关闭验证。"; fi
echo "$an_link"
echo
fi
if grep -q anyreality-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Any-Reality 】节点信息如下："
port_ar=$(cat "$HOME/agsbx/port_ar")
ar_link="anytls://$(uri_percent_encode "$uuid")@$server_ip:$port_ar?security=reality&sni=$(uri_percent_encode "$ym_vl_re")&fp=chrome&pbk=$(uri_percent_encode "$public_key_s")&sid=$(uri_percent_encode "$short_id_s")&type=tcp&headerType=none#$(uri_percent_encode "${sxname}any-reality-$hostname")"
append_node_link "$ar_link" || return 1
echo "$ar_link"
echo
fi
if grep -q hy2-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Hysteria2 】节点信息如下："
port_hy2=$(cat "$HOME/agsbx/port_hy2")
obfs_pass=$(cat "$HOME/agsbx/obfs_pass" 2>/dev/null)
cert_hash="$render_cert_hash"
[[ "$cert_hash" =~ ^[0-9a-f]{64}$ ]] || { echo "错误：当前证书指纹无效，拒绝生成 TLS 链接。"; return 1; }
ran_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
# 读取 Sing-box 专属的跳跃端口配置，格式化为客户端标准的中划线分隔
sby_mport=""
sby_hop=$(cat "$HOME/agsbx/shyjpt" 2>/dev/null)
[ -z "$sby_hop" ] && sby_hop="$shyjpt"
if [ -n "$sby_hop" ]; then
  sby_mport="&mport=$(echo "$sby_hop" | tr ':' '-')"
  echo "Hysteria2 跳跃端口已启用：$sby_hop"
fi
if cert_trusted "$cert_mode" && [ -n "$ran_sni" ]; then
if [ -n "$obfs_pass" ]; then
hy2_link="hysteria2://$(uri_percent_encode "$uuid")@$server_ip:$port_hy2?security=tls&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=0&allowInsecure=0&obfs=salamander&obfs-password=$(uri_percent_encode "$obfs_pass")${sby_mport}#$(uri_percent_encode "${sxname}hy2-$hostname")"
else
hy2_link="hysteria2://$(uri_percent_encode "$uuid")@$server_ip:$port_hy2?security=tls&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=0&allowInsecure=0${sby_mport}#$(uri_percent_encode "${sxname}hy2-$hostname")"
fi
else
if [ -n "$obfs_pass" ]; then
hy2_link="hysteria2://$(uri_percent_encode "$uuid")@$server_ip:$port_hy2?pinSHA256=$cert_hash&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=1&allowInsecure=1&obfs=salamander&obfs-password=$(uri_percent_encode "$obfs_pass")${sby_mport}#$(uri_percent_encode "${sxname}hy2-$hostname")"
else
hy2_link="hysteria2://$(uri_percent_encode "$uuid")@$server_ip:$port_hy2?pinSHA256=$cert_hash&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=1&allowInsecure=1${sby_mport}#$(uri_percent_encode "${sxname}hy2-$hostname")"
fi
fi
append_node_link "$hy2_link" || return 1
echo "$hy2_link"
echo
if [ "$sub" = yes ]; then
clhypt(){
local sby_hop_clean=$(echo "$sby_hop" | tr ':' '-')
local cl_skip_cert="false"
cert_trusted "$cert_mode" && cl_skip_cert="false"
local cl_obfs=""
[ -z "$obfs_pass" ] || cl_obfs=$(printf '  obfs: salamander\n  obfs-password: "%s"' "$(json_escape "$obfs_pass")")
cat <<EOF
- name: "$(json_escape "${sxname}hy2-$hostname")"
  type: hysteria2
  server: "$(json_escape "$server_host")"
  port: $port_hy2
  ports: "$sby_hop_clean"
  password: "$(json_escape "$uuid")"
  alpn:
    - h3
  sni: "${ran_sni:-www.bing.com}"
  skip-cert-verify: $cl_skip_cert
$(if ! cert_trusted "$cert_mode"; then printf '  fingerprint: "%s"\n' "$cert_hash"; fi)
  fast-open: true
$(printf '%s' "$cl_obfs")
EOF
}
clhypt1(){
printf -- '- "%s"\n' "$(json_escape "${sxname}hy2-$hostname")"
}
fi
fi
if grep -q hy2-xr "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Xray-Hysteria2 】节点信息如下："
port_xhy2=$(cat "$HOME/agsbx/port_xhy2")
cert_hash="$render_cert_hash"
[[ "$cert_hash" =~ ^[0-9a-f]{64}$ ]] || { echo "错误：当前证书指纹无效，拒绝生成 TLS 链接。"; return 1; }
ran_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
# 读取 Xray 专属的跳跃端口配置，格式化为客户端标准的中划线分隔
xby_mport=""
xby_hop=$(cat "$HOME/agsbx/xhyjpt" 2>/dev/null)
[ -z "$xby_hop" ] && xby_hop="$xhyjpt"
if [ -n "$xby_hop" ]; then
  xby_mport="&mport=$(echo "$xby_hop" | tr ':' '-')"
  echo "Xray-Hysteria2 跳跃端口已启用：$xby_hop"
fi
if cert_trusted "$cert_mode" && [ -n "$ran_sni" ]; then
xhy2_link="hysteria2://$(uri_percent_encode "$uuid")@$server_ip:$port_xhy2?security=tls&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=0&allowInsecure=0${xby_mport}${profile_hy_options}#$(uri_percent_encode "${sxname}xray-hy2${profile_hy_suffix}-$hostname")"
else
xhy2_link="hysteria2://$(uri_percent_encode "$uuid")@$server_ip:$port_xhy2?security=tls&pinSHA256=$(uri_percent_encode "$cert_hash")&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=1&allowInsecure=1${xby_mport}${profile_hy_options}#$(uri_percent_encode "${sxname}xray-hy2${profile_hy_suffix}-$hostname")"
fi
append_node_link "$xhy2_link" || return 1
echo "$xhy2_link"
echo
if [ "$sub" = yes ] && [ -z "$profile_hy_fm" ]; then
clxhypt(){
local xby_hop_clean=$(echo "$xby_hop" | tr ':' '-')
local cl_skip_cert="false"
cert_trusted "$cert_mode" && cl_skip_cert="false"
cat <<EOF
- name: "$(json_escape "${sxname}xray-hy2-$hostname")"
  type: hysteria2
  server: "$(json_escape "$server_host")"
  port: $port_xhy2
  ports: "$xby_hop_clean"
  password: "$(json_escape "$uuid")"
  alpn:
    - h3
  sni: "${ran_sni:-www.bing.com}"
  skip-cert-verify: $cl_skip_cert
$(if ! cert_trusted "$cert_mode"; then printf '  fingerprint: "%s"\n' "$cert_hash"; fi)
  fast-open: true
EOF
}
clxhypt1(){
printf -- '- "%s"\n' "$(json_escape "${sxname}xray-hy2-$hostname")"
}
fi
fi
if grep -q tuic5-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Tuic 】节点信息如下："
port_tu=$(cat "$HOME/agsbx/port_tu")
cert_hash="$render_cert_hash"
[[ "$cert_hash" =~ ^[0-9a-f]{64}$ ]] || { echo "错误：当前证书指纹无效，拒绝生成 TLS 链接。"; return 1; }
ran_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
if cert_trusted "$cert_mode" && [ -n "$ran_sni" ]; then
tuic5_link="tuic://$(uri_percent_encode "$uuid"):$(uri_percent_encode "$uuid")@$server_ip:$port_tu?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=0&allow_insecure=0&allowInsecure=0#$(uri_percent_encode "${sxname}tuic-$hostname")"
else
tuic5_link="tuic://$(uri_percent_encode "$uuid"):$(uri_percent_encode "$uuid")@$server_ip:$port_tu?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$(uri_percent_encode "$ran_sni")&insecure=0&allow_insecure=0&allowInsecure=0#$(uri_percent_encode "${sxname}tuic-$hostname")"
fi
append_node_link "$tuic5_link" || return 1
if ! cert_trusted "$cert_mode"; then echo "此节点使用自签证书；客户端须先信任该证书。请勿仅关闭证书验证。"; fi
echo "$tuic5_link"
echo
if [ "$sub" = yes ]; then
cltupt(){
local cl_skip_cert="false"
cert_trusted "$cert_mode" && cl_skip_cert="false"
cat <<EOF
- name: "$(json_escape "${sxname}tuic5-$hostname")"
  server: "$(json_escape "$server_host")"
  port: $port_tu
  type: tuic
  uuid: "$(json_escape "$uuid")"
  password: "$(json_escape "$uuid")"
  alpn:
    - h3
  disable-sni: false
  reduce-rtt: true
  udp-relay-mode: native
  congestion-controller: bbr
  sni: "${ran_sni:-www.bing.com}"
  skip-cert-verify: $cl_skip_cert
$(if ! cert_trusted "$cert_mode"; then printf '  fingerprint: "%s"\n' "$cert_hash"; fi)
EOF
}
cltupt1(){
printf -- '- "%s"\n' "$(json_escape "${sxname}tuic5-$hostname")"
}
fi
fi
if grep -q socks5-xr "$HOME/agsbx/xr.json" 2>/dev/null || grep -q socks5-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Socks5 】客户端信息如下："
port_so=$(cat "$HOME/agsbx/port_so")
load_socks_credentials || return 1
socks_link="socks5://$(uri_percent_encode "$socks_user"):$(uri_percent_encode "$socks_pass")@$server_ip:$port_so#$(uri_percent_encode "${sxname}Socks5-$hostname")"
echo "注意：SOCKS5 本身不加密；其独立凭据仍需在受信网络或加密隧道中使用。"
echo "客户端地址：$server_ip"
echo "客户端端口：$port_so"
echo "客户端用户名：$socks_user"
echo "客户端密码：$socks_pass"
echo "分享链接：$socks_link"
echo
fi
# NaiveProxy 同时提供原生与 Shadowrocket URI；Mihomo 没有 Naive 类型，不伪装成普通 HTTP 代理。
if [ -s "$HOME/agsbx/naive_domain" ]; then
naivedomain=$(cat "$HOME/agsbx/naive_domain")
naiveuser=$(cat "$HOME/agsbx/naive_user" 2>/dev/null)
naivepass=$(cat "$HOME/agsbx/naive_pass" 2>/dev/null)
naiveuser_uri=$(uri_percent_encode "$naiveuser")
naivepass_uri=$(uri_percent_encode "$naivepass")
naive_h2_title=$(uri_percent_encode "${sxname}naive-h2-$hostname")
naive_h3_title=$(uri_percent_encode "${sxname}naive-h3-$hostname")
naive_h2_link="naive+https://${naiveuser_uri}:${naivepass_uri}@$naivedomain:443?security=tls&sni=$naivedomain&insecure=0&allowInsecure=0#${naive_h2_title}"
naive_h3_link="naive+quic://${naiveuser_uri}:${naivepass_uri}@$naivedomain:443?congestion_control=bbr&security=tls&sni=$naivedomain&insecure=0&allowInsecure=0#${naive_h3_title}"
# Shadowrocket 使用 http2/http3 scheme 和 padding 参数，格式对照 YG argosbx 的 Naive 分享输出。
naive_sr_h2_link="http2://${naiveuser_uri}:${naivepass_uri}@$naivedomain:443?security=tls&sni=$naivedomain&insecure=0&allowInsecure=0&padding=1&tfo=1#${naive_h2_title}"
naive_sr_h3_link="http3://${naiveuser_uri}:${naivepass_uri}@$naivedomain:443?security=tls&sni=$naivedomain&insecure=0&allowInsecure=0&padding=1&tfo=1#${naive_h3_title}"
append_node_link "$naive_h2_link" || return 1
append_node_link "$naive_h3_link" || return 1
append_node_link "$naive_sr_h2_link" || return 1
append_node_link "$naive_sr_h3_link" || return 1
node_title "💣【 NaiveProxy 】Caddy 转发代理，节点信息如下："
echo "账号：$naiveuser"
echo "密码：$naivepass"
echo "分享链接(HTTPS·H1/H2，TCP)：$naive_h2_link"
echo "分享链接(QUIC·H3，UDP)：$naive_h3_link"
echo "Shadowrocket 单节点分享（HTTP2，TCP）："
echo "$naive_sr_h2_link"
echo "Shadowrocket 单节点分享（HTTP3，UDP）："
echo "$naive_sr_h3_link"
echo "以上四条链接参与 jh.txt / jhsub.txt 聚合订阅，不写入 clmi.yaml；Shadowrocket 使用 http2/http3 格式，H3 需放行 UDP/443。"
echo
fi
# Mieru 同时导出原生 URI 与 Mihomo YAML，保留实际传输方式和 Traffic Pattern。
if [ -s "$HOME/agsbx/mita.json" ] && [ -s "$HOME/agsbx/mieru_user" ] && [ -s "$HOME/agsbx/mieru_pass" ] && [ -s "$HOME/agsbx/port_mieru" ]; then
mieruuser=$(cat "$HOME/agsbx/mieru_user")
mierupass=$(cat "$HOME/agsbx/mieru_pass")
port_mieru=$(cat "$HOME/agsbx/port_mieru")
mieru_protocol=$(cat "$HOME/agsbx/mieru_protocol" 2>/dev/null)
[ -n "$mieru_protocol" ] || mieru_protocol=TCP
mieru_traffic_pattern=$(cat "$HOME/agsbx/mieru_traffic_pattern" 2>/dev/null)
mieru_address=${server_ip#[}
mieru_address=${mieru_address%]}
mieru_link="mierus://$(uri_percent_encode "$mieruuser"):$(uri_percent_encode "$mierupass")@$server_ip?profile=default&mtu=1400&port=$port_mieru&protocol=$mieru_protocol"
if validate_mieru_traffic_pattern "$mieru_traffic_pattern"; then
  mieru_link+="&traffic-pattern=$(uri_percent_encode "$mieru_traffic_pattern")"
  mieru_traffic_display="$mieru_traffic_pattern"
else
  mieru_traffic_display="未配置，请执行 mieru=y agsbx rep"
fi
if [ "$cip_mode" = publish ] && ! validate_mieru_traffic_pattern "$mieru_traffic_pattern"; then
  echo "错误：Mieru Traffic Pattern 缺失或格式异常，拒绝发布缺少该参数的订阅；请执行 mieru=y agsbx rep。"
  return 1
fi
append_node_link "$mieru_link" || return 1
if [ "$sub" = yes ] && validate_mieru_traffic_pattern "$mieru_traffic_pattern"; then
  valid_port "$port_mieru" || { echo "错误：Mieru 订阅端口无效。"; return 1; }
  case "$mieru_protocol" in TCP|UDP) ;; *) echo "错误：Mieru 订阅传输方式必须为 TCP 或 UDP。"; return 1 ;; esac
clmierupt(){
cat <<EOF
- name: "$(json_escape "${sxname}mieru-$hostname")"
  type: mieru
  server: "$(json_escape "$mieru_address")"
  port: $port_mieru
  transport: $mieru_protocol
  username: "$(json_escape "$mieruuser")"
  password: "$(json_escape "$mierupass")"
  traffic-pattern: "$(json_escape "$mieru_traffic_pattern")"
  udp: true
EOF
}
clmierupt1(){
printf -- '- "%s"\n' "$(json_escape "${sxname}mieru-$hostname")"
}
fi
node_title "💣【 Mieru 】节点信息如下："
echo "类型：Mieru"
echo "地址：$mieru_address"
echo "端口：$port_mieru"
echo "用户名：$mieruuser"
echo "密码：$mierupass"
echo "Transport：$(printf '%s' "$mieru_protocol" | tr 'A-Z' 'a-z')"
echo "Traffic Pattern：$mieru_traffic_display"
echo "复制下一行完整链接导入："
echo "$mieru_link"
echo
fi
argodomain=$(cat "$HOME/agsbx/sbargoym.log" 2>/dev/null)
if [ -z "$argodomain" ]; then
  argodomain=$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' "$HOME/agsbx/argo.log" 2>/dev/null | head -n1)
fi
if [ -n "$argodomain" ]; then
vlvm=$(cat $HOME/agsbx/vlvm 2>/dev/null)
if [ "$vlvm" = "Vmess" ]; then
      vmatls_link1="vmess://$(vmess_payload "${sxname}vmess-ws-tls-argo-$hostname-443" "icook.hk" "443" "$argodomain" "$(transport_path vm)" "tls" "$argodomain")"
      append_node_link "$vmatls_link1" || return 1
      vmatls_link2="vmess://$(vmess_payload "${sxname}vmess-ws-tls-argo-$hostname-8443" "icook.hk" "8443" "$argodomain" "$(transport_path vm)" "tls" "$argodomain")"
      append_node_link "$vmatls_link2" || return 1
      vmatls_link3="vmess://$(vmess_payload "${sxname}vmess-ws-tls-argo-$hostname-2053" "icook.hk" "2053" "$argodomain" "$(transport_path vm)" "tls" "$argodomain")"
      append_node_link "$vmatls_link3" || return 1
      vmatls_link4="vmess://$(vmess_payload "${sxname}vmess-ws-tls-argo-$hostname-2083" "icook.hk" "2083" "$argodomain" "$(transport_path vm)" "tls" "$argodomain")"
      append_node_link "$vmatls_link4" || return 1
      vmatls_link5="vmess://$(vmess_payload "${sxname}vmess-ws-tls-argo-$hostname-2087" "icook.hk" "2087" "$argodomain" "$(transport_path vm)" "tls" "$argodomain")"
      append_node_link "$vmatls_link5" || return 1
      vmatls_link6="vmess://$(vmess_payload "${sxname}vmess-ws-tls-argo-$hostname-2096" "2606:4700::0" "2096" "$argodomain" "$(transport_path vm)" "tls" "$argodomain")"
      append_node_link "$vmatls_link6" || return 1
      vma_link7="vmess://$(vmess_payload "${sxname}vmess-ws-argo-$hostname-80" "icook.hk" "80" "$argodomain" "$(transport_path vm)" "" "")"
      append_node_link "$vma_link7" || return 1
      vma_link8="vmess://$(vmess_payload "${sxname}vmess-ws-argo-$hostname-8080" "icook.hk" "8080" "$argodomain" "$(transport_path vm)" "" "")"
      append_node_link "$vma_link8" || return 1
      vma_link9="vmess://$(vmess_payload "${sxname}vmess-ws-argo-$hostname-8880" "icook.hk" "8880" "$argodomain" "$(transport_path vm)" "" "")"
      append_node_link "$vma_link9" || return 1
      vma_link10="vmess://$(vmess_payload "${sxname}vmess-ws-argo-$hostname-2052" "icook.hk" "2052" "$argodomain" "$(transport_path vm)" "" "")"
      append_node_link "$vma_link10" || return 1
      vma_link11="vmess://$(vmess_payload "${sxname}vmess-ws-argo-$hostname-2082" "icook.hk" "2082" "$argodomain" "$(transport_path vm)" "" "")"
      append_node_link "$vma_link11" || return 1
      vma_link12="vmess://$(vmess_payload "${sxname}vmess-ws-argo-$hostname-2086" "icook.hk" "2086" "$argodomain" "$(transport_path vm)" "" "")"
      append_node_link "$vma_link12" || return 1
      vma_link13="vmess://$(vmess_payload "${sxname}vmess-ws-argo-$hostname-2095" "2400:cb00:2049::0" "2095" "$argodomain" "$(transport_path vm)" "" "")"
      append_node_link "$vma_link13" || return 1
      if [ "$sub" = yes ]; then
      clvmargopt(){
      cat <<EOF
- name: "$(json_escape "${sxname}vmess-ws-tls-argo-$hostname-443")"
  type: vmess
  server: icook.hk
  port: 443
  uuid: "$(json_escape "$uuid")"
  alterId: 0
  cipher: auto
  udp: true
  tls: true
  network: ws
  servername: "$argodomain"
  ws-opts:
    path: "$(transport_path vm)"
    headers:
      Host: "$argodomain"
- name: "$(json_escape "${sxname}vmess-ws-argo-$hostname-80")"
  type: vmess
  server: icook.hk
  port: 80
  uuid: "$(json_escape "$uuid")"
  alterId: 0
  cipher: auto
  udp: true
  tls: false
  network: ws
  servername: "$argodomain"
  ws-opts:
    path: "$(transport_path vm)"
    headers:
      Host: "$argodomain"
EOF
      }
      clvmargopt1(){
      printf -- '- "%s"\n' "$(json_escape "${sxname}vmess-ws-tls-argo-$hostname-443")"
      printf -- '- "%s"\n' "$(json_escape "${sxname}vmess-ws-argo-$hostname-80")"
      }
      fi
elif [ "$vlvm" = "Vless" ]; then
vwatls_link1="vless://$(uri_percent_encode "$uuid")@icook.hk:443?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$(uri_percent_encode "$(transport_path vw)")&security=tls&sni=$argodomain&fp=chrome&insecure=0&allowInsecure=0#$(uri_percent_encode "${sxname}vlessenc-ws-tls-vision-argo-$hostname")"
append_node_link "$vwatls_link1" || return 1
vwa_link2="vless://$(uri_percent_encode "$uuid")@icook.hk:80?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$(uri_percent_encode "$(transport_path vw)")&security=none#$(uri_percent_encode "${sxname}vlessenc-ws-vision-argo-$hostname")"
append_node_link "$vwa_link2" || return 1
elif [ "$vlvm" = "Vlessenc-xhttp-tls-vision-fm" ] || [ "$vlvm" = "Vlessenc-xhttp-vision" ]; then
vwa_xvargo_link="vless://$(uri_percent_encode "$uuid")@$argodomain:443?encryption=$(uri_percent_encode "$enkey")&flow=xtls-rprx-vision&security=tls&alpn=h2&sni=$(uri_percent_encode "$argodomain")&host=$(uri_percent_encode "$argodomain")&type=xhttp&path=$(uri_percent_encode "$(transport_path xva)")&mode=$profile_xva_mode${profile_xva_options}#$(uri_percent_encode "${sxname}vlessenc-${profile_xva_transport}-vision-argo${profile_xva_suffix}-$hostname")"
append_node_link "$vwa_xvargo_link" || return 1
[ "$sub" != yes ] || echo "Argo ENC 节点通过完整 VLESS URL/聚合订阅导入，不生成缺失 ENC 参数的 Clash 节点。"
fi
if [ -s "$argo_token_file" ]; then
nametn="Argo固定隧道token：已安全保存（不显示）"
else
nametn=""
fi
if [ "$vlvm" = "Vlessenc-xhttp-tls-vision-fm" ] || [ "$vlvm" = "Vlessenc-xhttp-vision" ]; then
argoshow=$(
echo "Argo隧道端口正在使用$vlvm主协议端口：$(cat $HOME/agsbx/argoport.log 2>/dev/null)
Argo域名：$argodomain
$nametn

💣【 VLESS Encryption＋${profile_xva_transport}＋Vision Argo${profile_xva_suffix} 节点 】
$vwa_xvargo_link
"
)
else
argoshow=$(
echo "Argo隧道端口正在使用$vlvm-ws主协议端口：$(cat $HOME/agsbx/argoport.log 2>/dev/null)
Argo域名：$argodomain
$nametn

1、💣443端口的$vlvm-ws-tls-argo节点(优选IP与443系端口随便换)
${vmatls_link1}${vwatls_link1}

2、💣80端口的$vlvm-ws-argo节点(优选IP与80系端口随便换)
${vma_link7}${vwa_link2}
"
)
fi
fi
if [ "$sub" = yes ] && [ "$cip_mode" = publish ]; then
get_func() {
  local f=$1
  if declare -F "$f" >/dev/null 2>&1; then
    local out
    out=$("$f") || return 1
    [ -n "$out" ] && printf "%s\n" "$out"
  fi
}
# 当前 Mihomo 已有 ENC/XHTTP 能力，但本脚本尚未建立其完整 extra/FM 版本映射。
# 这类节点暂只导出完整 URL，不能生成遗漏 ENC 或掩码参数的 YAML。
clxy="$(get_func clvlpt; get_func clsspt; get_func clvmpt; get_func clvmcdnpt; get_func clhypt; get_func clxhypt; get_func cltupt; get_func clvmargopt; get_func clmierupt)"
clgz="$({ get_func clvlpt1; get_func clsspt1; get_func clvmpt1; get_func clvmcdnpt1; get_func clhypt1; get_func clxhypt1; get_func cltupt1; get_func clvmargopt1; get_func clmierupt1; } | sed '2,$s/^/    /')"
if [ -n "$clxy" ] && [ -n "$clgz" ]; then
clash_config=$(cat <<EOF
port: 7890
allow-lan: false
mode: rule
log-level: info
unified-delay: true
dns:
  enable: true
  listen: "127.0.0.1:1053"
  ipv6: true
  prefer-h3: false
  respect-rules: true
  use-system-hosts: false
  cache-algorithm: "arc"
  enhanced-mode: "fake-ip"
  fake-ip-range: "198.18.0.1/16"
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "localhost.ptlogin2.qq.com"
    - "localhost.sec.qq.com"
    - "+.in-addr.arpa"
    - "+.ip6.arpa"
    - "time.*.com"
    - "time.*.gov"
    - "pool.ntp.org"
    - "localhost.work.weixin.qq.com"
  default-nameserver: ["223.5.5.5", "119.29.29.29"]
  nameserver:
    - "https://1.1.1.1/dns-query"
    - "https://8.8.8.8/dns-query"
  proxy-server-nameserver:
    - "https://223.5.5.5/dns-query"
    - "https://doh.pub/dns-query"
  nameserver-policy:
    "geosite:cn":
      - "https://223.5.5.5/dns-query"
      - "https://doh.pub/dns-query"
proxies:
$clxy

proxy-groups:
- name: 负载均衡
  type: load-balance
  url: https://www.gstatic.com/generate_204
  interval: 300
  strategy: round-robin
  proxies:
    $clgz
- name: 自动选择
  type: url-test
  url: https://www.gstatic.com/generate_204
  interval: 300
  tolerance: 50
  proxies:
    $clgz
- name: 🌍选择代理节点
  type: select
  proxies:
    - 负载均衡
    - 自动选择
    - DIRECT
    $clgz
rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🌍选择代理节点
EOF
)
fi
fi
if [ "$sub" = yes ]; then
  subtoken=$(cat "$HOME/agsbx/subtoken.log" 2>/dev/null)
  if [ "$cip_mode" = publish ]; then
    if [ -n "$subid" ]; then subtoken="$subid"
    elif [ "$subtoken" = "$uuid" ] || ! [[ "$subtoken" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
      subtoken=$(openssl rand -hex 32) || return 1
    fi
  fi
  [[ "$subtoken" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || { echo "错误：旧订阅令牌过短或含路径字符，请用 sub=y agsbx rep 迁移。"; return 1; }
  subport_show=$(cat "$HOME/agsbx/subport.log") && subport_real=$(cat "$HOME/agsbx/subport_real.log") || return 1
  valid_port "$subport_show" && valid_port "$subport_real" || return 1
  clash_sub_info=''
  if subdomain=$(subscription_certificate_host); then
    suburl="https://${subdomain}:${subport_show}/${subtoken}"
    if { [ "$cip_mode" = publish ] && [ -n "$clash_config" ]; } || { [ "$cip_mode" != publish ] && [ -f "$HOME/websbx/$subtoken/clmi.yaml" ]; }; then
      clash_sub_info="Clash/Mihomo 本地订阅链接：${suburl}/clmi.yaml"
    fi
  else
    [ "$cip_mode" != publish ] || return 1
    echo "现有订阅未满足公信 CA 要求，已隐藏分享链接；请用 sub=y 并指定 ACME 方式执行 agsbx rep 迁移。"
    sub=''
  fi
fi
if [ "$cip_mode" = publish ]; then publish_node_outputs || return 1; fi
hr
echo "$argoshow"
echo
if [ "$sub" = yes ]; then
hr2
if [ -n "$clash_sub_info" ]; then echo "$clash_sub_info"; else echo "本次没有可完整导出的 Mihomo 节点，请使用聚合协议链接。"; fi
echo "聚合协议本地订阅地址：${suburl}/jhsub.txt"
echo "clmi.yaml 仅包含可完整导出的 Mihomo 节点（含 Mieru，不含 Naive）；jhsub.txt 包含 Mieru 与 Naive 链接，Naive 另附 Shadowrocket 的 http2/http3 格式。"
echo "订阅地址使用共享 CA 证书覆盖的域名或 IP；域名应解析到订阅服务，客户端保持证书验证开启。"
hr2
echo
fi
hr
[ -s "$HOME/agsbx/jh.txt" ] && echo "聚合节点信息，请进入 $HOME/agsbx/jh.txt 文件目录查看或者运行 cat $HOME/agsbx/jh.txt 查看"
hr2
# 安全加固：全局收紧敏感文件权限（阻断多用户环境下的未授权文件读取）
if [ "$cip_mode" = publish ]; then
if [ "$rep_mode" = yes ]; then
  for permission_path in "$HOME/agsbx"/* "$HOME/agsbx"/.[!.]* "$HOME/agsbx"/..?*; do
    [ -e "$permission_path" ] || [ -L "$permission_path" ] || continue
    rep_entry_is_preserved "${permission_path##*/}" && continue
    if [ -d "$permission_path" ]; then
      find "$permission_path" -type d -exec chmod 700 {} + 2>/dev/null
      find "$permission_path" -type f -exec chmod 600 {} + 2>/dev/null
    fi
    [ -f "$permission_path" ] && chmod 600 "$permission_path" 2>/dev/null
  done
  chmod 700 "$HOME/agsbx/xray" "$HOME/agsbx/sing-box" "$HOME/agsbx/cloudflared" 2>/dev/null
else
  find "$HOME/agsbx" -type d -exec chmod 700 {} + 2>/dev/null
  find "$HOME/agsbx" -type f -exec chmod 600 {} + 2>/dev/null
  chmod 700 "$HOME/agsbx/xray" "$HOME/agsbx/sing-box" "$HOME/agsbx/cloudflared" "$HOME/agsbx/caddy" 2>/dev/null
fi
[ ! -f "$HOME/agsbx/acme.sh" ] || chmod 700 "$HOME/agsbx/acme.sh" || return 1
fi
echo "相关快捷方式如下（无需重连 SSH）："
showmode
return 0
}
#============================================================
# [第10段] 系统清理、卸载与内核服务重启自愈函数
#------------------------------------------------------------
# 🎯 架构说明:
# - 本大段包含 cleandel() (系统级清理服务与进程、清洗除 ACME 定时检查外的 crontab 任务)、xrestart()/sbrestart() (Xray/Sing-box的重启自愈与前后台运行方式平滑自适应)。
# - 关联性: 为后续第 11 段 (命令路由) 处理 del(卸载)、rep(重置协议) 或 res(重启) 提供底层物理清理与状态复原支撑。
#============================================================
rep_entry_is_preserved(){
  if [ "$rep_manage_certificate" = yes ]; then
    case "$1" in acme*|dnsapi|ca.conf) return 1 ;; esac
  fi
  case "$1" in
    caddy|caddy*|.caddy*|Caddyfile|naive_*|acme*|acmecer|dnsapi|ca.conf|sbx_update)
      return 0 ;;
    *) return 1 ;;
  esac
}

rep_validate_preserved_certificate(){
  local mode source cert_file key_file identifier
  # 订阅允许升级为 CA；签发/复用在快照完成且进入安装编排后执行。
  [ "$sub" != yes ] || return 0
  if [ "$sub" != yes ] && [ "$hyp" != yes ] && [ "$xhyp" != yes ] \
    && [ "$tup" != yes ] && [ "$ssp" != yes ] && [ "$anp" != yes ] \
    && [ "$xvcdn" != yes ]; then
    return 0
  fi
  mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
  if [ "$rep_preserved_caddy" = yes ] && [ "$mode" != caddy ]; then
    echo "错误：检测到需要保留的 Caddy，但现有证书模式不是 caddy；为避免错误复用，请先执行 agsbx del。"
    return 1
  fi
  case "$mode" in
    caddy)
      if [ "$rep_preserved_caddy" != yes ]; then
        echo "错误：检测到 Caddy 证书状态，但缺少可安全保留的 Caddy 配置；请先执行 agsbx del。"
        return 1
      fi
      cert_file=$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)
      key_file=$(cat "$HOME/agsbx/key_file_path" 2>/dev/null)
      identifier=$(cat "$HOME/agsbx/cert_identifier" 2>/dev/null)
      [ -n "$identifier" ] || identifier="$rep_preserved_naive_domain"
      if ! valid_domain "$identifier" \
        || ! validate_certificate_bundle "$cert_file" "$key_file" caddy "$identifier"; then
        echo "错误：rep 保留的 Caddy 证书未通过有效期、SAN 或私钥匹配校验。"
        echo "如需更换或重新申请 Caddy 证书，请先执行 agsbx del，再重新运行脚本。"
        return 1
      fi
      tls_cert_source="rep 前置校验通过的 Caddy 证书"
      ;;
    ca)
      cert_file=$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)
      key_file=$(cat "$HOME/agsbx/key_file_path" 2>/dev/null)
      [ -n "$cert_file" ] || cert_file="$HOME/agsbx/acmecer/cert.pem"
      [ -n "$key_file" ] || key_file="$HOME/agsbx/acmecer/private.key"
      source=$(cat "$HOME/agsbx/cert_source" 2>/dev/null)
      identifier=$(cat "$HOME/agsbx/cert_identifier" 2>/dev/null)
      [ -n "$identifier" ] || identifier=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
      case "$source" in
        acme-ip|acme-http|acme-alpn|acme-dns|external) ;;
        *)
          echo "错误：rep 保留的受信任证书来源无法识别；请先执行 agsbx del。"
          return 1 ;;
      esac
      if { ! valid_ip "$identifier" && ! valid_domain "$identifier"; } \
        || ! validate_certificate_bundle "$cert_file" "$key_file" "$source" "$identifier"; then
        echo "错误：rep 保留的 ACME/外部证书未通过有效期、SAN 或私钥匹配校验。"
        echo "如需更换或重新申请证书，请先执行 agsbx del，再重新运行脚本。"
        return 1
      fi
      if [ "$source" = external ]; then
        openssl verify -purpose sslserver -untrusted "$cert_file" "$cert_file" >/dev/null 2>&1 || { echo "错误：外部证书不受系统信任库信任。"; return 1; }
      fi
      tls_cert_source="rep 前置校验通过的本地受信任证书"
      ;;
    selfsigned|"")
      return 0
      ;;
    *)
      echo "错误：无法识别现有证书模式 $mode；为避免 rep 误改证书，请先执行 agsbx del。"
      return 1
      ;;
  esac
  tls_cert_file="$cert_file"
  tls_key_file="$key_file"
  write_cert_fingerprint || {
    echo "错误：rep 无法记录已验证证书的 SHA-256 指纹。"
    return 1
  }
  tls_cert_ready=yes
  echo "rep 前置检查：现有 $mode 证书已重新验证，本次运行后续直接复用且不重复校验。"
}

rep_validate_preserved_scope(){
  local option value
  rep_manage_certificate=no
  [ "$sub" != yes ] || rep_manage_certificate=yes
  for option in naive naiveuser naivepass naivebuild naivesite alns acmemode certip certym certwild certcrt certkey acmem acmetimeout certdns CF_Token CF_Key CF_Email CF_Account_ID CF_Zone_ID sslcom_eab_kid sslcom_eab_hmac; do
    if [ "$rep_manage_certificate" = yes ]; then
      case "$option" in naive|naiveuser|naivepass|naivebuild|naivesite) ;; *) continue ;; esac
    fi
    value=${!option-}
    if [ -n "$value" ]; then
      echo "错误：agsbx rep 不允许设置 $option；Naive/Caddy 保留不变，证书参数仅在启用订阅时接受。"
      echo "如需变更这些内容，请先执行 agsbx del，再重新运行脚本。"
      return 1
    fi
  done
  case ",$(printf '%s' "$secp" | tr 'A-Z' 'a-z' | tr -d ' ')," in
    *,naive,*)
      echo "错误：agsbx rep 不允许新增或重建 Naive 二级链路；请先执行 agsbx del。"
      return 1 ;;
  esac
  if secondary_saved_protocol_is_selected naive; then
    echo "错误：现有部署使用 Naive 二级链路，rep 无法在不改动 Caddyfile 的前提下安全重建其 Sing-box sidecar。"
    echo "请先执行 agsbx del，再重新运行脚本。"
    return 1
  fi

  rep_preserved_caddy=no
  rep_preserved_caddy_running=no
  if [ -s "$HOME/agsbx/Caddyfile" ] || agsbx_component_running caddy; then
    rep_preserved_naive_domain=$(cat "$HOME/agsbx/naive_domain" 2>/dev/null)
    if ! valid_domain "$rep_preserved_naive_domain"; then
      echo "错误：检测到需要保留的 Caddy，但 naive_domain 缺失或无效；为避免误改，请先执行 agsbx del。"
      return 1
    fi
    rep_preserved_caddy=yes
    naive="$rep_preserved_naive_domain"
    agsbx_component_running caddy && rep_preserved_caddy_running=yes
  fi
  rep_validate_preserved_certificate || return 1
}

rep_service_is_enabled(){
  local service="$1" systemd_name openrc_name component="$1"
  if [ "$service" = mita ]; then [ -f "$HOME/agsbx/mita_managed" ] || return 1
  else
    [ "$component" != argo ] || component=cloudflared
    managed_service_state "$component" || return 1
  fi
  case "$service" in
    xray) systemd_name=xr; openrc_name=xray ;;
    sing-box) systemd_name=sb; openrc_name=sing-box ;;
    argo) systemd_name=argo; openrc_name=argo ;;
    mita) systemd_name=mita; openrc_name=mita ;;
    *) return 1 ;;
  esac
  if pidof systemd >/dev/null 2>&1; then
    systemctl is-enabled --quiet "$systemd_name"
  elif command -v rc-update >/dev/null 2>&1; then
    rc-update show default 2>/dev/null | awk -v name="$openrc_name" '$1 == name {found=1} END {exit !found}'
  else
    return 1
  fi
}

rep_snapshot_mutable_entries(){
  local destination="$1" path name
  mkdir -p "$destination" || return 1
  for path in "$HOME/agsbx"/* "$HOME/agsbx"/.[!.]* "$HOME/agsbx"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=${path##*/}
    rep_entry_is_preserved "$name" && continue
    cp -a -- "$path" "$destination/" || return 1
  done
}

rep_remove_mutable_entries(){
  local agsbx_dir="$HOME/agsbx" path name
  [ -n "$HOME" ] && [ "$HOME" != / ] && [ "$agsbx_dir" = "$HOME/agsbx" ] || {
    echo "错误：rep 回滚目录边界检查失败。"
    return 1
  }
  [ -d "$agsbx_dir" ] || return 0
  for path in "$agsbx_dir"/* "$agsbx_dir"/.[!.]* "$agsbx_dir"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=${path##*/}
    rep_entry_is_preserved "$name" && continue
    rm -rf -- "$path" || return 1
  done
}

rep_begin_transaction(){
  local unit path component
  rep_backup_dir=$(mktemp -d "$HOME/.agsbx-rep-rollback.XXXXXX") || {
    echo "错误：无法创建 rep 回滚快照目录。"
    return 1
  }
  chmod 700 "$rep_backup_dir" || { rep_remove_backup >/dev/null 2>&1 || true; return 1; }
  mkdir -p "$rep_backup_dir/agsbx" "$rep_backup_dir/systemd" "$rep_backup_dir/openrc" \
    "$rep_backup_dir/local.d" "$rep_backup_dir/mita" "$rep_backup_dir/shortcuts" \
    || { rep_remove_backup >/dev/null 2>&1 || true; return 1; }
  rep_snapshot_mutable_entries "$rep_backup_dir/agsbx" \
    || { rep_remove_backup >/dev/null 2>&1 || true; return 1; }

  if [ -e "$HOME/websbx" ] && ! cp -a -- "$HOME/websbx" "$rep_backup_dir/websbx"; then
    rep_remove_backup >/dev/null 2>&1 || true; return 1
  fi
  for unit in xr.service sb.service argo.service; do
    path="/etc/systemd/system/$unit"
    case "$unit" in xr.service) component=xray ;; sb.service) component=sing-box ;; argo.service) component=cloudflared ;; esac
    service_file_owned "$path" "$component" systemd || continue
    if [ -e "$path" ] && ! cp -a -- "$path" "$rep_backup_dir/systemd/"; then
      rep_remove_backup >/dev/null 2>&1 || true; return 1
    fi
  done
  for unit in xray sing-box argo; do
    path="/etc/init.d/$unit"
    component="$unit"; [ "$component" != argo ] || component=cloudflared
    service_file_owned "$path" "$component" openrc || continue
    if [ -e "$path" ] && ! cp -a -- "$path" "$rep_backup_dir/openrc/"; then
      rep_remove_backup >/dev/null 2>&1 || true; return 1
    fi
  done
  if subscription_startup_owned /etc/local.d/alpinesubsbx.start && ! cp -a -- /etc/local.d/alpinesubsbx.start "$rep_backup_dir/local.d/"; then
    rep_remove_backup >/dev/null 2>&1 || true; return 1
  fi
  if [ -f "$HOME/agsbx/mita_managed" ] && [ -e /etc/mita/server.conf.pb ] && ! cp -a -- /etc/mita/server.conf.pb "$rep_backup_dir/mita/"; then
    rep_remove_backup >/dev/null 2>&1 || true; return 1
  fi
  if shortcut_is_owned "$HOME/bin/agsbx" && ! cp -a -- "$HOME/bin/agsbx" "$rep_backup_dir/shortcuts/home-bin-agsbx"; then
    rep_remove_backup >/dev/null 2>&1 || true; return 1
  fi
  if shortcut_is_owned /usr/local/bin/agsbx && ! cp -a -- /usr/local/bin/agsbx "$rep_backup_dir/shortcuts/usr-local-bin-agsbx"; then
    rep_remove_backup >/dev/null 2>&1 || true; return 1
  fi
  if shortcut_is_owned /usr/bin/agsbx && ! cp -a -- /usr/bin/agsbx "$rep_backup_dir/shortcuts/usr-bin-agsbx"; then
    rep_remove_backup >/dev/null 2>&1 || true; return 1
  fi
  if ! read_crontab_or_empty "$rep_backup_dir/crontab"; then
    rep_remove_backup >/dev/null 2>&1 || true
    return 1
  fi
  if [ "$crontab_read_state" = present ]; then
    : > "$rep_backup_dir/had_crontab"
  fi
  [ -f "$rep_backup_dir/crontab" ] || { rep_remove_backup >/dev/null 2>&1 || true; return 1; }
  chmod -R go-rwx "$rep_backup_dir" 2>/dev/null \
    || { rep_remove_backup >/dev/null 2>&1 || true; return 1; }

  rep_old_xray_running=no; agsbx_component_running xray && rep_old_xray_running=yes
  rep_old_singbox_running=no; agsbx_component_running sing-box && rep_old_singbox_running=yes
  rep_old_argo_running=no; agsbx_component_running cloudflared && rep_old_argo_running=yes
  rep_old_mita_daemon_running=no
  [ -f "$HOME/agsbx/mita_managed" ] && systemctl is-active --quiet mita && rep_old_mita_daemon_running=yes
  rep_old_mita_running=no

  [ -f "$HOME/agsbx/mita_managed" ] && command -v mita >/dev/null 2>&1 && mita status 2>/dev/null | grep -q RUNNING && rep_old_mita_running=yes
  rep_old_mita_managed=no; [ -f "$HOME/agsbx/mita_managed" ] && rep_old_mita_managed=yes
  rep_old_subscription_running=no; subscription_http_managed_is_running && rep_old_subscription_running=yes
  rep_old_xray_enabled=no; rep_service_is_enabled xray && rep_old_xray_enabled=yes
  rep_old_singbox_enabled=no; rep_service_is_enabled sing-box && rep_old_singbox_enabled=yes
  rep_old_argo_enabled=no; rep_service_is_enabled argo && rep_old_argo_enabled=yes
  rep_old_mita_enabled=no; rep_service_is_enabled mita && rep_old_mita_enabled=yes

  rep_transaction_active=yes
  trap 'rep_transaction_exit_handler $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

ip_policy_restore_transaction(){
  [ "$rep_ip_policy_changed" = yes ] || return 0
  ip_policy_restore_base || return 1
  if [ -d "$ip_policy_dir" ]; then ip_policy_remove_state || return 1; fi
  if [ -d "$rep_backup_dir/agsbx/ip_policy" ]; then
    cp -a -- "$rep_backup_dir/agsbx/ip_policy" "$ip_policy_dir" || return 1
    ip_policy_load_runtime || return 1
    ip_policy_reapply_previous_mode "$effective_ipv_mode" || return 1
  else
    ip_policy_configure_runtime ''
  fi
  reset_v4v6_probe
}

rep_restore_snapshot_files(){
  local unit component path backend saved
  rep_remove_mutable_entries || return 1
  mkdir -p "$HOME/agsbx" || return 1
  cp -a -- "$rep_backup_dir/agsbx/." "$HOME/agsbx/" || return 1

  remove_subscription_tree || return 1
  if [ -e "$rep_backup_dir/websbx" ]; then
    cp -a -- "$rep_backup_dir/websbx" "$HOME/websbx" || return 1
  fi

  for backend in systemd openrc; do
    for component in xray sing-box cloudflared; do
      managed_service_names "$component" || return 1
      if [ "$backend" = systemd ]; then unit="$managed_sd.service"; path="/etc/systemd/system/$unit"
      else unit="$managed_rc"; path="/etc/init.d/$unit"; fi
      saved="$rep_backup_dir/$backend/$unit"
      if [ -e "$path" ] || [ -L "$path" ]; then
        if ! service_file_owned "$path" "$component" "$backend"; then
          [ ! -e "$saved" ] || { echo "错误：恢复期间服务归属发生变化，已保留：$path"; return 1; }
          continue
        fi
        rm -f -- "$path" || return 1
      fi
      [ ! -e "$saved" ] || cp -a -- "$saved" "$path" || return 1
    done
  done
  path=/etc/local.d/alpinesubsbx.start
  saved="$rep_backup_dir/local.d/alpinesubsbx.start"
  if [ -e "$saved" ]; then
    if [ -e "$path" ] || [ -L "$path" ]; then subscription_startup_owned "$path" || return 1; fi
    cp -a -- "$saved" "$path" || return 1
  elif subscription_startup_owned "$path"; then
    rm -f -- "$path" || return 1
  fi
  if [ "$rep_old_mita_managed" = yes ]; then
    rm -f /etc/mita/server.conf.pb || return 1
  fi
  if [ "$rep_old_mita_managed" = yes ] && [ -e "$rep_backup_dir/mita/server.conf.pb" ]; then
    mkdir -p /etc/mita || return 1
    cp -a -- "$rep_backup_dir/mita/server.conf.pb" /etc/mita/server.conf.pb || return 1
  fi

  for unit in home-bin-agsbx usr-local-bin-agsbx usr-bin-agsbx; do
    case "$unit" in home-bin-agsbx) path="$HOME/bin/agsbx" ;; usr-local-bin-agsbx) path=/usr/local/bin/agsbx ;; usr-bin-agsbx) path=/usr/bin/agsbx ;; esac
    saved="$rep_backup_dir/shortcuts/$unit"
    if [ -e "$path" ] || [ -L "$path" ]; then
      if ! shortcut_is_owned "$path"; then
        [ ! -e "$saved" ] || { echo "错误：快捷命令归属已变化，未覆盖：$path"; return 1; }
        continue
      fi
      rm -f -- "$path" || return 1
    fi
    if [ -e "$saved" ]; then mkdir -p "${path%/*}" && cp -a -- "$saved" "$path" || return 1; fi
  done

  if [ -e "$rep_backup_dir/had_crontab" ]; then
    crontab "$rep_backup_dir/crontab" >/dev/null 2>&1 || return 1
  else
    crontab -r >/dev/null 2>&1 || true
  fi
  rep_argo_persistence_ready=yes
  rep_subscription_persistence_ready=yes
  migrate_argo_persistent_startup || rep_argo_persistence_ready=no
  migrate_subscription_persistent_startup || rep_subscription_persistence_ready=no
  migrate_certificate_jobs || return 1
}

rep_restore_argo_runtime(){
  local action="${1:-start}" restored_argo_port
  case "$action" in start|restart) ;; *) return 1 ;; esac
  case "$argo_persistent_mode" in
  fixed)
    secure_existing_argo_token_file \
      || { echo "错误：无法从安全 token 文件恢复固定隧道。"; return 1; }
    cloudflared_supports_token_file \
      || { echo "错误：旧 Cloudflared 不支持从 token 文件安全恢复固定隧道。"; return 1; }
    case "$argo_persistent_backend" in
    systemd)
      write_argo_systemd_service || return 1
      systemctl daemon-reload >/dev/null 2>&1 || return 1
      systemctl "$action" argo >/dev/null 2>&1 || return 1
      ;;
    openrc)
      write_argo_openrc_service || return 1
      rc-service argo "$action" 8>&- >/dev/null 2>&1 || return 1
      ;;
    cron)
      nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run \
        --token-file "$argo_token_file" 8>&- > "$HOME/agsbx/argo.log" 2>&1 &
      ;;
    *) echo "错误：固定 Argo 持久化载体无法识别。"; return 1 ;;
    esac
    ;;
  temporary)
    case "$argo_persistent_backend" in
    systemd) systemctl "$action" argo >/dev/null 2>&1 || return 1 ;;
    openrc) rc-service argo "$action" 8>&- >/dev/null 2>&1 || return 1 ;;
    cron)
      restored_argo_port=$(cat "$HOME/agsbx/argoport.log" 2>/dev/null)
      argo_origin_from_state
      nohup "$HOME/agsbx/cloudflared" tunnel --url "${argoscheme}://${argo_origin_host}:${restored_argo_port}" \
        $argoxtls --edge-ip-version auto --no-autoupdate --protocol http2 8>&- > "$HOME/agsbx/argo.log" 2>&1 &
      ;;
    *) echo "错误：临时 Argo 持久化载体无法识别。"; return 1 ;;
    esac
    ;;
  *)
    echo "错误：Argo 持久化模式无法识别，拒绝猜测恢复方式。"
    return 1
    ;;
  esac
  wait_agsbx_component cloudflared
}

rep_restore_runtime(){
  local failed=no restored_hops restored_port
  [ "$rep_argo_persistence_ready" = yes ] || failed=yes
  [ "$rep_subscription_persistence_ready" = yes ] || failed=yes
  if pidof systemd >/dev/null 2>&1; then systemctl daemon-reload >/dev/null 2>&1 || failed=yes; fi

  if [ "$rep_old_xray_enabled" = yes ]; then
    if pidof systemd >/dev/null 2>&1; then systemctl enable xr >/dev/null 2>&1 || failed=yes
    elif command -v rc-update >/dev/null 2>&1; then rc-update add xray default >/dev/null 2>&1 || failed=yes; fi
  fi
  if [ "$rep_old_singbox_enabled" = yes ]; then
    if pidof systemd >/dev/null 2>&1; then systemctl enable sb >/dev/null 2>&1 || failed=yes
    elif command -v rc-update >/dev/null 2>&1; then rc-update add sing-box default >/dev/null 2>&1 || failed=yes; fi
  fi
  if [ "$rep_old_argo_enabled" = yes ]; then
    if pidof systemd >/dev/null 2>&1; then systemctl enable argo >/dev/null 2>&1 || failed=yes
    elif command -v rc-update >/dev/null 2>&1; then rc-update add argo default >/dev/null 2>&1 || failed=yes; fi
  fi
  if [ "$rep_old_mita_enabled" = yes ] && pidof systemd >/dev/null 2>&1; then
    systemctl enable mita >/dev/null 2>&1 || failed=yes
  fi

  if [ "$rep_old_xray_running" = yes ]; then
    validate_generated_core_config xray && kctl start xray || failed=yes
  fi
  if [ "$rep_old_singbox_running" = yes ]; then
    validate_generated_core_config sing-box && kctl start sb || failed=yes
  fi
  if [ "$rep_old_argo_running" = yes ]; then
    if [ "$rep_argo_persistence_ready" = yes ]; then rep_restore_argo_runtime || failed=yes
    else failed=yes
    fi
  fi
  if [ "$rep_old_mita_daemon_running" = yes ]; then
    if systemctl start mita >/dev/null 2>&1 && wait_mita_daemon; then
      if [ "$rep_old_mita_running" = yes ]; then
        if ! mita status 2>/dev/null | grep -q RUNNING; then mita start >/dev/null 2>&1 && wait_mita_running || failed=yes; fi
      else
        mita stop >/dev/null 2>&1 || failed=yes
      fi
    else failed=yes; fi
  fi
  if [ -s "$HOME/agsbx/mieru_ufw_rule" ]; then
    port_mieru=$(cat "$HOME/agsbx/port_mieru" 2>/dev/null)
    mieru_protocol=$(cat "$HOME/agsbx/mieru_protocol" 2>/dev/null)
    ensure_mieru_ufw || failed=yes
  fi

  cleanup_port_hopping || failed=yes
  unset HOPPING_INITED
  restored_hops=$(cat "$HOME/agsbx/shyjpt" 2>/dev/null); restored_port=$(cat "$HOME/agsbx/port_hy2" 2>/dev/null)
  if [ -n "$restored_hops" ] && [ -n "$restored_port" ]; then setup_port_hopping "$restored_hops" "$restored_port" || failed=yes; fi
  restored_hops=$(cat "$HOME/agsbx/xhyjpt" 2>/dev/null); restored_port=$(cat "$HOME/agsbx/port_xhy2" 2>/dev/null)
  if [ -n "$restored_hops" ] && [ -n "$restored_port" ]; then setup_port_hopping "$restored_hops" "$restored_port" || failed=yes; fi
  if [ -e "$HOME/agsbx/xicmp_enabled" ]; then
    command -v setcap >/dev/null 2>&1 && setcap cap_net_raw+ep "$HOME/agsbx/xray" 2>/dev/null
    sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null 2>&1 || failed=yes
  fi

  if [ "$rep_old_subscription_running" = yes ]; then
    if [ "$rep_subscription_persistence_ready" = yes ]; then
      restored_port=$(cat "$HOME/agsbx/subport_real.log" 2>/dev/null)
      start_subscription_http "$restored_port" || failed=yes
    else
      failed=yes
    fi
  fi
  [ "$failed" = no ]
}

rep_remove_backup(){
  case "$rep_backup_dir" in
    "$HOME"/.agsbx-rep-rollback.*)
      [ ! -e "$rep_backup_dir" ] || rm -rf -- "$rep_backup_dir"
      ;;
    *) echo "警告：rep 快照路径边界异常，未自动删除：$rep_backup_dir"; return 1 ;;
  esac
}

rep_rollback_transaction(){
  local external_restore_failed=no
  rep_transaction_active=restoring
  echo "rep 新部署失败，正在恢复旧部署……"
  if [ "$rep_old_mita_managed" = no ] && [ -f "$HOME/agsbx/mita_managed" ]; then
    uninstall_mita_managed >/dev/null 2>&1 || external_restore_failed=yes
  fi
  if ! cleanup_mieru_ufw || ! cleandel rep; then
    echo "错误：新部署未能安全停止，未覆盖运行文件；恢复快照保留在：$rep_backup_dir"
    return 1
  fi
  if ! ip_policy_restore_transaction; then
    echo "错误：系统 IP 状态恢复失败；恢复快照保留在：$rep_backup_dir"
    return 1
  fi
  if rep_restore_snapshot_files && rep_restore_runtime && [ "$external_restore_failed" = no ]; then
    echo "旧部署已恢复。"
    rep_remove_backup || true
    return 0
  fi
  echo "错误：旧部署自动恢复不完整。回滚快照保留在：$rep_backup_dir"
  return 1
}

rep_transaction_exit_handler(){
  if [ "$rep_transaction_active" = yes ]; then
    rep_rollback_transaction || true
  fi
}

rep_commit_transaction(){
  [ "$rep_transaction_active" = yes ] || return 0
  rep_transaction_active=no
  trap - EXIT INT TERM
  rep_remove_backup || echo "警告：rep 已成功，但旧快照未能自动删除，请按上方路径人工检查。"
  echo "rep 新部署已通过本地启动检查，事务提交完成。"
  return 0
}

cleandel(){
local cleanup_mode="${1:-del}" cron_tmp filtered_tmp component path
case "$cleanup_mode" in del|rep) ;; *) echo "错误：未知清理模式 $cleanup_mode。"; return 1 ;; esac
for component in xray sing-box cloudflared; do
  stop_managed_service "$component" yes || return 1
done
if [ "$cleanup_mode" = del ]; then
  stop_managed_service caddy yes || return 1
  for path in /etc/systemd/system/caddy.service /etc/init.d/caddy; do
    if service_file_owned "$path" caddy systemd; then
      systemctl stop caddy && systemctl --quiet disable caddy && rm -f -- "$path" || return 1
    elif service_file_owned "$path" caddy openrc; then
      rc-service caddy stop && rc-update del caddy default && rm -f -- "$path" || return 1
    fi
  done
fi
stop_subscription_http || return 1
restore_xicmp_state || return 1
cleanup_port_hopping || return 1
if [ -f "$HOME/agsbx/mita_managed" ] && { command -v mita >/dev/null 2>&1 || [ -e /lib/systemd/system/mita.service ] || [ -e /usr/lib/systemd/system/mita.service ] || [ -e /etc/systemd/system/mita.service ]; }; then
  if command -v mita >/dev/null 2>&1 && systemctl is-active --quiet mita; then
    mita stop >/dev/null 2>&1 || echo "提示：Mita RPC 停止失败，继续停止受管 daemon。"
  fi
  systemctl stop mita >/dev/null 2>&1 && systemctl disable mita >/dev/null 2>&1 || return 1
fi
cron_tmp=$(mktemp) || { echo "错误：无法创建 crontab 清理临时文件。"; return 1; }
if ! read_crontab_or_empty "$cron_tmp"; then
  rm -f "$cron_tmp"
  echo "错误：无法安全读取现有 crontab，已停止清理以避免覆盖用户任务。"
  return 1
fi
filtered_tmp=$(mktemp) || { rm -f "$cron_tmp"; return 1; }
if ! filter_component_cron "$cron_tmp" "$filtered_tmp" "$cleanup_mode" \
  || ! crontab "$filtered_tmp" >/dev/null 2>&1; then
  rm -f "$cron_tmp" "$filtered_tmp"
  echo "错误：无法安全清理 crontab，已保留部署文件。"
  return 1
fi
rm -f "$cron_tmp" "$filtered_tmp"
# 快捷命令由 del 入口在全部组件与文件清理成功后删除。
remove_subscription_tree || return 1
if pidof systemd >/dev/null 2>&1; then
systemctl daemon-reload >/dev/null 2>&1 || return 1
elif command -v rc-service >/dev/null 2>&1; then
  if subscription_startup_owned /etc/local.d/alpinesubsbx.start; then
    rm -f /etc/local.d/alpinesubsbx.start || return 1
  fi
fi
[ "$cleanup_mode" = del ] && rm -f "$HOME/agsbx/caddy-admin.sock"
if [ "$cleanup_mode" = rep ]; then
  sleep 1
  if agsbx_component_running xray || agsbx_component_running sing-box || agsbx_component_running cloudflared \
    || subscription_http_is_running; then
    echo "错误：rep 清理后仍有旧的 Xray、Sing-box、Argo 或订阅进程运行。"
    return 1
  fi
  if [ -f "$HOME/agsbx/mita_managed" ] && command -v mita >/dev/null 2>&1 \
    && mita status 2>/dev/null | grep -q RUNNING; then
    echo "错误：rep 清理后 Mieru 代理仍在运行。"
    return 1
  fi
fi
return 0
}
xrestart(){
kctl restart xray
}
sbrestart(){
kctl restart sb
}
# 内核生命周期统一入口：start / stop / restart / reload，自适应 systemd / openrc / 裸 nohup 三种后端。
# 用法：kctl <动作> <内核>，内核 ∈ xray｜sb｜caddy（all 在已配置 Naive 时也包含 Caddy）。
# 关键约束：
#   · stop/start 在 systemd/openrc 下必须经服务管理器，否则 Restart 策略会立刻把内核重新拉起，停不掉、端口释放不了。
#   · reload：sing-box 支持 SIGHUP 热重载（校验后重建实例）；Xray 官方不支持热重载 → 自动改为 restart；caddy 预留。
kctl(){
  local action="$1" kernel="$2" name bin cfg pat sd rc log
  local caddy_admin_address="unix/$HOME/agsbx/caddy-admin.sock"
  case "$kernel" in
    xray|x)      name="Xray";     bin="$HOME/agsbx/xray";     cfg="$HOME/agsbx/xr.json"; pat='agsbx/xray';     sd="xr"; rc="xray";     log="$HOME/agsbx/xray.log" ;;
    sb|sing-box) name="Sing-box"; bin="$HOME/agsbx/sing-box"; cfg="$HOME/agsbx/sb.json"; pat='agsbx/sing-box'; sd="sb"; rc="sing-box"; log="$HOME/agsbx/sing-box.log" ;;
    caddy)       name="Caddy";     bin="$HOME/agsbx/caddy";     cfg="$HOME/agsbx/Caddyfile"; pat='agsbx/caddy';    sd="agsbx-caddy"; rc="agsbx-caddy"; log="$HOME/agsbx/caddy.log" ;;
    *)           echo "未知内核：$kernel（可选 xray｜sb｜caddy｜all）"; return 1 ;;
  esac
  if [ ! -s "$bin" ]; then echo "${name}：内核未下载，无法执行 ${action}。"; return 1; fi
  require_service_slot "${bin##*/}" || return 1
  sd="$managed_sd"; rc="$managed_rc"
  if [ "$action" != stop ]; then
    command -v ss >/dev/null 2>&1 || { echo "错误：缺少 ss，无法确认监听状态；未启动或重启内核。"; return 1; }
    [ -s "$cfg" ] || { echo "${name}：尚未配置。"; return 1; }
    case "$kernel" in xray|x) validate_generated_core_config xray || return 1 ;; sb|sing-box) validate_generated_core_config sing-box || return 1 ;; esac
  fi
  # Xray 无配置热重载，reload 自动降级为 restart
  if [ "$action" = "reload" ] && [ "$sd" = "xr" ]; then
    echo "Xray 不支持配置热重载（官方设计），已自动改为 restart。"; action="restart"
  fi
  # Caddy：start/restart/reload 前先做配置语法预检，坏配置直接拦截，不推上线、不动正在运行的服务
  if [ "$kernel" = caddy ] && { [ "$action" = start ] || [ "$action" = restart ] || [ "$action" = reload ]; } && [ -s "$cfg" ]; then
    if ! "$bin" validate --config "$cfg" >/dev/null 2>&1; then
      echo "Caddy：配置校验未通过，已拦截 ${action}（不影响正在运行的服务）："
      "$bin" validate --config "$cfg" 2>&1 | grep -iE 'error|invalid' | head -3
      return 1
    fi
  fi
  # 启动参数：xray/sing-box 用 run -c，caddy 用 run --config
  local runflag="-c"; [ "$kernel" = caddy ] && runflag="--config"
  case "$action" in
    start|restart)
      if pidof systemd >/dev/null 2>&1; then
        if ! systemctl "$action" "$sd" >/dev/null 2>&1; then
          echo "${name}：systemctl ${action} ${sd} 失败 ✗"
          echo "    journalctl -u $sd -n 30 --no-pager"
          return 1
        fi
      elif command -v rc-service >/dev/null 2>&1; then
        if ! rc-service "$rc" "$action" 8>&- >/dev/null 2>&1; then
          echo "${name}：OpenRC ${action} ${rc} 失败 ✗"
          return 1
        fi
      else
        if [ "$action" = start ] && agsbx_component_running "${bin##*/}"; then echo "${name}：已在运行。"; return 0; fi
        stop_component_processes "${bin##*/}" || return 1
        [ "$kernel" = caddy ] && rm -f "$HOME/agsbx/caddy-admin.sock"
        nohup "$bin" run "$runflag" "$cfg" 8>&- > "$log" 2>&1 &
      fi
      sleep 1
      wait_agsbx_component "${bin##*/}" && wait_component_listeners "${bin##*/}" || return 1
      if { pidof systemd >/dev/null 2>&1 && systemctl is-active --quiet "$sd"; } || \
         { ! pidof systemd >/dev/null 2>&1 && agsbx_component_running "${bin##*/}"; }; then
        [ "$action" = start ] && echo "${name}：已启动 ✓" || echo "${name}：已重启 ✓"
      else
        echo "${name}：${action} 后进程未起来 ✗，请查看日志定位原因："
        if pidof systemd >/dev/null 2>&1; then
          echo "    journalctl -u $sd -n 30 --no-pager"
        else
          echo "    tail -n 30 $log"
        fi
        return 1
      fi ;;
    stop)
      if pidof systemd >/dev/null 2>&1; then
        systemctl stop "$sd" >/dev/null 2>&1 || { echo "${name}：systemctl stop ${sd} 失败 ✗"; return 1; }
      elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$rc" stop >/dev/null 2>&1 || { echo "${name}：OpenRC stop ${rc} 失败 ✗"; return 1; }
      else
        stop_component_processes "${bin##*/}" || return 1
      fi
      sleep 1
      if agsbx_component_running "${bin##*/}"; then
        echo "${name}：停止命令已执行，但进程仍在运行 ✗"
        return 1
      fi
      [ "$kernel" = caddy ] && rm -f "$HOME/agsbx/caddy-admin.sock"
      echo "${name}：已停止（占用端口已释放）。" ;;
    reload)
      if [ "$kernel" = caddy ]; then
        # caddy 原生热重载（配置已在上方预检通过）：systemd 下走 systemctl reload，否则直接 caddy reload
        if pidof systemd >/dev/null 2>&1; then
          systemctl reload "$sd" >/dev/null 2>&1 || {
            echo "Caddy：systemctl reload ${sd} 失败 ✗"
            echo "    journalctl -u $sd -n 30 --no-pager"
            return 1
          }
        else
          "$bin" reload --config "$cfg" --address "$caddy_admin_address" >/dev/null 2>&1 || {
            echo "Caddy：通过权限化管理 socket 热重载失败 ✗，请查看 $log"
            return 1
          }
        fi
        echo "Caddy：配置校验通过，已热重载（连接不断）✓"
      elif agsbx_component_running "${bin##*/}"; then
        kill -HUP $(agsbx_component_pids "${bin##*/}") >/dev/null 2>&1 || return 1
        echo "${name}：已发送热重载信号（SIGHUP）。"
      else
        echo "${name}：进程未运行，无法 reload，请改用 start。"; return 1
      fi ;;
    *) echo "未知动作：$action（可选 start｜stop｜restart｜reload）"; return 1 ;;
  esac
  if secondary_saved_protocol_is_selected naive; then
    if [ "$sd" = sb ] && [ "$action" = stop ]; then
      echo "提示：Naive 二级链路已失败关闭；Caddy 伪装站仍可继续访问，不会回退为 A VPS 直连目标。"
    elif [ "$kernel" = caddy ] && { [ "$action" = start ] || [ "$action" = restart ] || [ "$action" = reload ]; } && \
      ! pgrep -f 'agsbx/sing-box' >/dev/null 2>&1; then
      echo "提示：Sing-box sidecar 未运行；Caddy 伪装站可用，但 Naive 二级代理保持失败关闭。"
    elif [ "$sd" = sb ] && { [ "$action" = start ] || [ "$action" = restart ] || [ "$action" = reload ]; } && \
      pgrep -f 'agsbx/sing-box' >/dev/null 2>&1; then
      echo "提示：Sing-box sidecar 已恢复；Caddy 的新代理请求会自动恢复，无需重启 Caddy（未探测 B）。"
    fi
  fi
}

# Mita 的 systemd daemon 与 Mieru 代理监听是两层状态；启停命令控制代理本身，stop 后 daemon 保持在线以便再次 start。
mitactl(){
  local action="$1" status_out
  if [ ! -f "$HOME/agsbx/mita_managed" ]; then
    echo "Mita：不属于 Airgosbx 管理，已拒绝操作。"; return 1
  fi
  if ! command -v mita >/dev/null 2>&1; then
    echo "Mita：系统包不存在，无法执行 ${action}。"; return 1
  fi
  if [ "$action" != stop ] && [ ! -s "$HOME/agsbx/mita.json" ]; then
    echo "Mita：已安装但没有 Mieru 配置，请先用 mieru=y agsbx rep 启用。"; return 1
  fi
  case "$action" in
    start|restart|reload)
      systemctl enable mita >/dev/null 2>&1 || true
      systemctl start mita >/dev/null 2>&1 || { echo "Mita daemon 启动失败。"; return 1; }
      wait_mita_daemon || { echo "Mita daemon 未就绪。"; return 1; } ;;
  esac
  status_out=$(mita status 2>&1)
  case "$action" in
    start)
      if printf '%s' "$status_out" | grep -q 'RUNNING'; then
        echo "Mieru：已在运行。"
      elif mita start >/dev/null 2>&1 && wait_mita_running; then
        echo "Mieru：已启动 ✓"
      else
        echo "Mieru：启动失败，请运行 mita describe config 检查。"; return 1
      fi ;;
    stop)
      if ! systemctl is-active --quiet mita || printf '%s' "$status_out" | grep -q 'IDLE'; then
        echo "Mieru：已停止。"
      elif mita stop >/dev/null 2>&1; then
        echo "Mieru：已停止（代理端口已释放，daemon 保持在线）。"
      else
        echo "Mieru：停止失败。"; return 1
      fi ;;
    restart)
      printf '%s' "$status_out" | grep -q 'RUNNING' && mita stop >/dev/null 2>&1
      if mita start >/dev/null 2>&1 && wait_mita_running; then
        echo "Mieru：已重启 ✓"
      else
        echo "Mieru：重启失败。"; return 1
      fi ;;
    reload)
      if ! printf '%s' "$status_out" | grep -q 'RUNNING'; then
        echo "Mieru：代理未运行，无法 reload，请改用 start。"; return 1
      fi
      if mita reload >/dev/null 2>&1; then
        echo "Mieru：已按官方方式热重载用户与日志设置 ✓"
      else
        echo "Mieru：热重载失败；端口或传输变更请使用 mieru=y agsbx rep。"; return 1
      fi ;;
    *) echo "未知动作：$action（可选 start｜stop｜restart｜reload）"; return 1 ;;
  esac
}

# 内核资源 / 流量监控：纯读 /proc + ss，零依赖、不改动任何配置，兼容 busybox(无 ps -o 的精简系统)。
# CPU% 用 /proc/<pid>/stat 的 utime+stime 做 1 秒前后采样差；内存取 VmRSS 常驻集；运行时长由 starttime 反推。
showstats(){
local clk; clk=$(getconf CLK_TCK 2>/dev/null || echo 100)
# 字节数转人类可读单位（B/KiB/MiB/GiB）
human(){ awk -v b="${1:-0}" 'BEGIN{u="B KiB MiB GiB TiB";n=split(u,a," ");i=1;while(b>=1024&&i<n){b/=1024;i++}printf (i==1?"%d %s":"%.2f %s"),b,a[i]}'; }
section "Airgosbx 内核资源 / 流量监控"
printf '%s\n' "${C_GREEN}${C_BOLD}【内核进程】${C_RESET}"
printf "  ${C_CYAN}%-10s %-7s %-7s %-11s %-9s %-6s${C_RESET}\n" Core PID CPU% Mem-RSS Uptime Conn
local any=0 kv k label pid s b0 st b1 cpu rss up conn
for kv in "xray:Xray" "sing-box:Sing-box" "caddy:Caddy" "cloudflared:Argo" "mita:Mita"; do
  k=${kv%%:*}; label=${kv##*:}
  if [ "$k" = mita ]; then
    [ -f "$HOME/agsbx/mita_managed" ] && [ -s "$HOME/agsbx/mita.json" ] || continue
    pid=$(pgrep -x mita 2>/dev/null | head -1)
  else
    pid=$(agsbx_component_pids "$k" | head -1)
  fi
  if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
    printf "  %-10s ${C_RED}%s${C_RESET}\n" "$label" "未运行"
    continue
  fi
  any=1
  # 去掉 "pid (comm) " 前缀后，utime/stime/starttime 分别落在第 12/13/20 个字段
  s=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null); set -- $s
  b0=$(( ${12:-0} + ${13:-0} )); st=${20:-0}
  sleep 1
  s=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null); set -- $s
  b1=$(( ${12:-0} + ${13:-0} ))
  cpu=$(awk -v d=$((b1-b0)) -v c="$clk" 'BEGIN{printf "%.1f%%", d*100/c}')
  rss=$(awk '/^VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null)
  rss=$(awk -v kb="${rss:-0}" 'BEGIN{printf "%.1f MiB", kb/1024}')
  up=$(awk -v su="$(awk '{print $1}' /proc/uptime 2>/dev/null)" -v st="$st" -v c="$clk" 'BEGIN{s=su-st/c;d=int(s/86400);h=int((s%86400)/3600);m=int((s%3600)/60); if(d>0)printf "%dd%dh",d,h; else if(h>0)printf "%dh%dm",h,m; else printf "%dm",m}')
  conn=$(ss -tnp 2>/dev/null | grep -c "pid=$pid,")
  printf "  %-10s %-7s %-7s %-11s %-9s %-6s\n" "$label" "$pid" "$cpu" "$rss" "$up" "${conn:-0}"
done
[ "$any" = 0 ] && echo "  （各内核进程均未运行）"
echo
printf '%s\n' "${C_GREEN}${C_BOLD}【系统概况】${C_RESET}"
printf "  负载(1/5/15分)：%s\n" "$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)"
awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{if(t)printf "  内存：已用 %.0f MiB / 共 %.0f MiB（可用 %.0f MiB）\n",(t-a)/1024,t/1024,a/1024}' /proc/meminfo 2>/dev/null
echo
printf '%s\n' "${C_GREEN}${C_BOLD}【网卡流量】入站=接收(下行)／出站=发送(上行)，自系统开机累计，多数 VPS 据此计费${C_RESET}"
printf "  ${C_CYAN}%-10s %-16s %-16s${C_RESET}\n" NIC "RX-Inbound↓" "TX-Outbound↑"
# 逐网卡列出 RX/TX（/proc/net/dev：把 ifname: 的冒号换成空格后重新分列，$2=接收字节 $10=发送字节）。
# 过滤回环及常见虚拟网卡，避免污染计费口径；awk 内置 h() 直接转人类可读单位，保证对齐。
awk 'function h(b,  u,a,i,n){u="B KiB MiB GiB TiB";n=split(u,a," ");i=1;while(b>=1024&&i<n){b/=1024;i++}return sprintf((i==1?"%d %s":"%.2f %s"),b,a[i])}
NR>2{sub(/:/," "); ifc=$1; if(ifc=="lo"||ifc~/^(docker|veth|br-|virbr|tailscale|wg|tun|cni)/)next; printf "  %-10s %-16s %-16s\n",ifc,h($2),h($10); trx+=$2;ttx+=$10;c++}
END{if(c>1)printf "  %-10s %-16s %-16s\n","Total",h(trx),h(ttx); if(c==0)print "  （未发现可计费网卡）"}' /proc/net/dev 2>/dev/null
# Cloudflare 互联实时快照：按官方公布 IP 段匹配当前活跃连接的累计收发（含 CDN回源/Argo隧道/WARP出站）
if command -v ss >/dev/null 2>&1; then
  cf_ranges="104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 162.158.0.0/15 173.245.48.0/20 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 198.41.128.0/17 131.0.72.0/22 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 197.234.240.0/22 2606:4700::/32 2400:cb00::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
  cf_filt=""; for r in $cf_ranges; do cf_filt="${cf_filt:+$cf_filt or }dst $r"; done; cf_filt="( $cf_filt )"
  # bytes_sent=本机发出=出站；bytes_received=本机收到=入站
  set -- $(ss -tinH state established "$cf_filt" 2>/dev/null | awk '/bytes_sent:/{for(i=1;i<=NF;i++){if($i~/^bytes_sent:/){split($i,a,":");s+=a[2]}if($i~/^bytes_received:/){split($i,a,":");r+=a[2]}}}END{print s+0, r+0}')
  cf_out="$1"; cf_in="$2"
  cf_conn=$(ss -tnH state established "$cf_filt" 2>/dev/null | grep -c .)
  printf "  ${C_YELLOW}↳ 其中 Cloudflare 互联${C_RESET}：活跃 %s 连接，入站↓ %s ／ 出站↑ %s\n" "${cf_conn:-0}" "$(human "${cf_in:-0}")" "$(human "${cf_out:-0}")"
  echo "    （此行为当前活跃连接的累计快照，非自开机口径；含 CDN回源/Argo/WARP，按 Cloudflare 官方IP段匹配，仅供占比参考）"
fi
hr
echo "口径：网卡累计=自开机起(计费参考)；CPU%=1秒采样瞬时(多核可>100%)；连接=各内核当前 ESTABLISHED 数。"
hr
echo
}

#============================================================
# [第11段] 命令路由与运行状态分发路由段
#------------------------------------------------------------
# 🎯 架构说明:
# - 本大段处理传入脚本的 `$1` 参数并路由分发到特定行为: `del`(卸载整个 agsbx 目录)、`rep`(重置配置)、`list`(卡片打印)、`upx/ups`(内核更新) 或 `res`(内核服务快速重启)。
# - 关联性: 为终端控制台调用或 systemd/OpenRC 守护指令提供物理分发网关。
#============================================================
prepare_runtime_operation "$1" || exit 1
# 首次部署或半完成部署必须先有管理入口；失败后仍可执行 del/list。
# 在 rep 快照之前补齐缺失入口，避免回滚再次把入口恢复为缺失状态。
case "$1" in
  ''|rep)
    # 已安装后的无参数调用持有共享锁，仅展示状态，不在此补写文件。
    if [ "$1" = rep ] || ! agsbx_installed; then
      management_entry=$(managed_script_path) || exit 1
      if [ ! -e "$management_entry" ]; then
        install_script_shortcut current || { echo "错误：无法准备 agsbx 管理入口，尚未开始部署。"; exit 1; }
      fi
    fi
    ;;
esac
case "$1" in
  ''|rep|del) ip_policy_load_runtime || exit 1 ;;
  *) ip_policy_load_runtime >/dev/null 2>&1 || ip_policy_configure_runtime '' ;;
esac
case "$1" in
  rep)
    if [ "${ipv_request_mode:-$effective_ipv_mode}" = 6 ] && [ "$xicp" = yes ]; then
      echo "错误：ipv=6 不支持 XICMP；请删除 xicmp/xicmppt 后再重置配置。"
      exit 1
    fi
    ;;
  '')
    if agsbx_installed || agsbx_running; then
      if [ "$ipv_request_set" = yes ] && [ -z "$ipv_request_mode" ]; then
        ip_policy_cancel_and_restore || exit 1
        exit 0
      elif [ "$ipv_request_set" = yes ] && [ -n "$ipv_request_mode" ]; then
        echo "错误：已安装状态切换非空 ipv 必须与配置重建同步，请使用协议变量加 agsbx rep。"
        exit 1
      fi
    fi
    ;;
  *)
    # list/status/start/stop/update 等命令不应用本次 ipv，只读取已保存模式供展示或地址选择。
    ;;
esac

case "$1" in
  __cert_renew)
    identifier=$(cat "$HOME/agsbx/cert_identifier") || exit 1
    neutralize_legacy_acme_reload "$identifier" || exit 1
    [ -s "$HOME/agsbx/acme.sh" ] || exit 1
    bash 8>&- "$HOME/agsbx/acme.sh" --home "$HOME/agsbx/acme" --renew -d "$identifier" --ecc
    renew_status=$?
    [ "$renew_status" = 0 ] || [ "$renew_status" = 2 ] || exit 1
    reload_shared_certificate
    exit $? ;;
  __cert_reload)
    reload_shared_certificate
    exit $? ;;
  __restore_hops)
    for hop_spec in shyjpt:port_hy2 xhyjpt:port_xhy2; do
      hop_value=$(cat "$HOME/agsbx/${hop_spec%:*}" 2>/dev/null)
      hop_target=$(cat "$HOME/agsbx/${hop_spec#*:}" 2>/dev/null)
      [ -z "$hop_value" ] || setup_port_hopping "$hop_value" "$hop_target" || exit 1
    done
    exit 0 ;;
esac
if [ "$1" = "del" ]; then
ip_policy_cancel_and_restore || exit 1
cleandel del || exit 1
uninstall_mita_managed || exit 1
# 注：sbx_update 标记文件位于 $HOME/agsbx 内，随该目录一并删除；此前裸写的相对路径 sbx_update
# 只删除当前受管目录；不自动清理缺少归属记录的历史 agsb 目录。
rm -rf -- "$HOME/agsbx" || { echo "错误：部署目录未完全删除。"; exit 1; }
for shortcut in "$HOME/bin/agsbx" /usr/local/bin/agsbx /usr/bin/agsbx; do
  if shortcut_is_owned "$shortcut"; then rm -f -- "$shortcut" || exit 1; fi
done
echo "卸载完成；未改动无归属记录的旧目录和 shell 配置。"
echo "欢迎继续使用Airgosbx一键无交互小钢炮脚本💣" && sleep 2
echo
showmode
exit
elif [ "$1" = "rep" ]; then
[ -n "$HOME" ] && [ "$HOME" != / ] && [ -d "$HOME/agsbx" ] \
  || { echo "错误：rep 目录边界检查失败。"; exit 1; }
validate_deployment_inputs || exit 1
for required_command in ip ss openssl crontab sha256sum; do
  command -v "$required_command" >/dev/null 2>&1 || { echo "错误：rep 缺少 $required_command，未停止现有部署。"; exit 1; }
done
preflight_service_slots || exit 1
rep_validate_preserved_scope || exit 1
prepare_secondary_proxy || exit 1
rep_mode=yes
rep_begin_transaction || exit 1
rep_ip_policy_changed="$ipv_request_set"
apply_requested_ip_policy || exit 1
cleandel rep || exit 1
cleanup_mieru_ufw || exit 1
reset_mita_config || exit 1
rm -rf "$HOME/agsbx"/{sb.json,xr.json,sbargoym.log,sbargotoken.log,argo.log,argoport.log,cdnym,name,secondary_secp,secondary_meta,direct_xh_profile,direct_vl_profile,xray_xh_profile,xray_vl_profile,xray_vx_profile,xray_vw_profile,xray_vm_profile,xray_hy_profile,xray_xvd_profile,xray_xva_profile,mita.json,mieru_user,mieru_pass,port_mieru,mieru_protocol,mieru_traffic_seed,mieru_traffic_pattern,mieru_ufw_rule,shyjpt,xhyjpt,socks_user,socks_pass,transport_vm,transport_vw,transport_vx,transport_xh,transport_xvd,transport_xva} \
  || { echo "错误：rep 无法清理旧的可变协议状态。"; exit 1; }
echo "Airgosbx重置协议完成，开始更新相关协议变量……" && sleep 2
echo
elif [ "$1" = "list" ]; then
cip
exit
elif [ "$1" = "upx" ] || [ "$1" = "downx" ]; then
# upx [版本]=升级(不带=最新)；downx <版本>=降级。方向校验：升级拒绝更低版本、降级拒绝更高版本，防用反命令。
reqver="$2"
if [ "$1" = "downx" ] && [ -z "$reqver" ]; then echo "用法：agsbx downx <版本号>，例如 agsbx downx v26.2.6（升级到最新请用 agsbx upx）"; exit 1; fi
curver=$("$HOME/agsbx/xray" version 2>/dev/null | awk '/^Xray/{print $2}')
if [ -n "$reqver" ] && [ -n "$curver" ]; then
  rel=$(vercmp "$reqver" "$curver")
  if [ "$1" = "upx" ] && [ "$rel" = "lt" ]; then echo "错误：目标版本 ${reqver#v} 低于当前运行的 v${curver}，这是降级。请改用：agsbx downx ${reqver}"; exit 1; fi
  if [ "$1" = "downx" ] && [ "$rel" = "gt" ]; then echo "错误：目标版本 ${reqver#v} 高于当前运行的 v${curver}，这是升级。请改用：agsbx upx ${reqver}"; exit 1; fi
fi
# 先在暂存区下载+预检；仅当通过、新内核已就位后才停掉旧进程重启。失败则原内核继续运行，全程不中断。
upxray "$reqver" || exit 1
cip
exit $?
elif [ "$1" = "ups" ] || [ "$1" = "downs" ]; then
# ups [版本]=升级(不带=最新)；downs <版本>=降级。同样做版本方向校验。
reqver="$2"
if [ "$1" = "downs" ] && [ -z "$reqver" ]; then echo "用法：agsbx downs <版本号>，例如 agsbx downs v1.11.0（升级到最新请用 agsbx ups）"; exit 1; fi
curver=$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}')
if [ -n "$reqver" ] && [ -n "$curver" ]; then
  rel=$(vercmp "$reqver" "$curver")
  if [ "$1" = "ups" ] && [ "$rel" = "lt" ]; then echo "错误：目标版本 ${reqver#v} 低于当前运行的 v${curver}，这是降级。请改用：agsbx downs ${reqver}"; exit 1; fi
  if [ "$1" = "downs" ] && [ "$rel" = "gt" ]; then echo "错误：目标版本 ${reqver#v} 高于当前运行的 v${curver}，这是升级。请改用：agsbx ups ${reqver}"; exit 1; fi
fi
upsingbox "$reqver" || exit 1
cip
exit $?
elif [ "$1" = "status" ] || [ "$1" = "stats" ] || [ "$1" = "top" ]; then
showstats
exit
elif [ "$1" = "res" ]; then
res_failed=0
migrate_argo_persistent_startup || res_failed=1
migrate_subscription_persistent_startup || res_failed=1
if [ "$res_failed" = 0 ]; then
  restart_managed_subscription_http || res_failed=1
fi
for component in xray sing-box caddy; do
  case "$component" in xray) cfg=xr.json; target=xray ;; sing-box) cfg=sb.json; target=sb ;; caddy) cfg=Caddyfile; target=caddy ;; esac
  [ ! -s "$HOME/agsbx/$cfg" ] || kctl restart "$target" || res_failed=1
done
if [ "$argo_persistent_mode" != none ] && [ "$res_failed" = 0 ]; then
  stop_managed_service cloudflared || res_failed=1
  [ "$res_failed" != 0 ] || rep_restore_argo_runtime || res_failed=1
fi
[ "$res_failed" = 0 ] || { echo "重启未全部完成，请检查上方错误。"; exit 1; }
migrate_certificate_jobs || exit 1
echo "所有已配置组件均已重启。"
cip
exit $?
elif [ "$1" = "update" ]; then
install_script_shortcut update || exit 1
echo "脚本已更新；配置与运行内核保持原样。"
exit 0
elif [ "$1" = "start" ] || [ "$1" = "stop" ] || [ "$1" = "restart" ] || [ "$1" = "reload" ]; then
# 内核生命周期：agsbx <动作> [内核]，内核省略=all；已配置 Naive 时按依赖顺序一并处理 Caddy，Mita 仍显式操作。
action="$1"; target="${2:-all}"
case "$target" in
  all)
    lifecycle_failed=0
    if [ "$action" = stop ]; then lifecycle_order="caddy xray sb"; else lifecycle_order="xray sb caddy"; fi
    for target in $lifecycle_order; do
      case "$target" in xray) cfg=xr.json ;; sb) cfg=sb.json ;; caddy) cfg=Caddyfile ;; esac
      [ -s "$HOME/agsbx/$cfg" ] || continue
      kctl "$action" "$target" || lifecycle_failed=1
    done
    exit "$lifecycle_failed"
    ;;
  xray|x)      kctl "$action" xray ;;
  sb|sing-box) kctl "$action" sb ;;
  caddy)       kctl "$action" caddy ;;
  mita|mieru)  mitactl "$action" ;;
  *)           echo "未知内核：$target（可选 xray｜sb｜caddy｜mita｜all，省略=all）"; exit 1 ;;
esac
exit
fi
#============================================================
# [第12段] 脚本主入口流程决策段 (最尾部逻辑控制区)
#------------------------------------------------------------
# 🎯 架构说明:
# - 本段为脚本的物理大门。校验系统当前是否已安装 agsbx，如果未安装则校验协议变量合法性后拉起 ins() 安装编排；如果已存在安装，则进入交互式节点状态卡片。
# - 关联性: 必须置于脚本最尾部，以确保其调用前面所有段落声明的工具函数与安装函数时已由 Shell 完全预加载完毕。
#============================================================
if [ "$rep_mode" = yes ] || ! agsbx_installed; then
if [ "$rep_mode" != yes ]; then
  validate_deployment_inputs || exit 1
  preflight_service_slots || exit 1
  ensure_deps || exit 1
  prepare_secondary_proxy || exit 1
  apply_requested_ip_policy || exit 1
fi

# WARP 对端 (engage.cloudflareclient.com) 出口协议栈选择：
# 默认优先 IPv4 外层封装；ipv=6 或 ipv="6;4" 时优先 IPv6，对应栈不可用才回退另一栈。
# 此前无条件优先 IPv6 对端，叠加未设 MTU，是 warp=s6x6 等内层 IPv6 模式"连接不通畅"的主要诱因。
# 复用集中 VPS 信息展示所需的双栈探测结果，避免这里单独再请求一次公网 IPv4。
v4v6
warp_outer_first="$ip_policy_preferred_family"
if { [ "$warp_outer_first" = 6 ] && [ -n "$v6" ]; } || { [ -z "$v4" ] && [ -n "$v6" ]; }; then
  sendip="2606:4700:d0::a29f:c001"
  xendip="[2606:4700:d0::a29f:c001]"
else
  sendip="162.159.192.1"
  xendip="162.159.192.1"
fi
echo "开始准备本次 Airgosbx 部署……" && sleep 1
show_vps_info
ins || { echo "Airgosbx 安装编排失败。"; exit 1; }
cip publish || { echo "Airgosbx 节点与订阅生成失败。"; exit 1; }
if ! verify_install_required_components yes; then
  echo "Airgosbx 必需组件检查失败，安装未完成。"
  exit 1
fi
rep_commit_transaction || exit 1
echo "Airgosbx 必需组件的本地启动检查通过；客户端连通性仍需确认。" && sleep 2
echo
else
echo "Airgosbx脚本已安装"
echo
airgosbxstatus
echo
echo "相关快捷方式如下："
showmode
exit
fi
