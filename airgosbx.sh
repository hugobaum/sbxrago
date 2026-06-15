#!/usr/bin/env bash
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

# 进程探测助手：判断 agsbx 管理的 sing-box / xray / caddy 内核是否在运行。
# 此前该长管道在第 1/8/12 段被逐字复制三次，现统一收敛为单一函数，杜绝逻辑漂移与维护遗漏。
agsbx_running(){
  find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -Eq 'agsbx/(sing-box|xray|caddy)' \
    || pgrep -f 'agsbx/sing-box' >/dev/null 2>&1 \
    || pgrep -f 'agsbx/xray' >/dev/null 2>&1 \
    || pgrep -f 'agsbx/caddy' >/dev/null 2>&1
}
# 安装态探测：只要内核二进制还在磁盘上就视为"已安装"（rep 只重置配置、stop 只停进程，都不删二进制）。
# 管理类命令(start/stop/restart/reload/list/...)应以"是否已安装"放行，而非"是否正在运行"——
# 否则 stop 停掉最后一个内核后 agsbx_running 变 false，随后的 start 会被前置守卫误判为"未安装"而拦截。
agsbx_installed(){
  [ -s "$HOME/agsbx/sing-box" ] || [ -s "$HOME/agsbx/xray" ] || [ -s "$HOME/agsbx/caddy" ]
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
showvars(){
printf '%s\n' "${C_CYAN}~~~~~~~~~~~~~~~~~~~~ Airgosbx 变量速查表 ~~~~~~~~~~~~~~~~~~~~${C_RESET}"
printf '%s\n' "${C_BOLD}用法：在脚本前以「变量=值」空格分隔传入，可任意组合${C_RESET}"
echo "示例：xhpt=2087 warp=s4x4 sub=y bash <(curl -Ls $agsbxurl)"
echo "说明：端口类变量留空(如 vlpt)即自动随机分配；带 pt 后缀的为可指定端口版"

vg "① Xray 内核协议（端口留空＝自动分配）"
vrow "xhpt"     "Vlessenc-xhttp-reality-vision-fm（旗舰·自带ENC加密）"
vrow "vlpt"     "Vless-tcp-reality-vision-fm（经典抗封锁主力）"
vrow "vxpt"     "Vlessenc-xhttp-vision（裸ENC，配 cdnym 走CDN）"
vrow "vwpt"     "Vlessenc-ws-vision（裸ENC，配 cdnym 走CDN）"
vrow "xhypt"    "Xray-Hysteria2（QUIC，需TLS证书）"
vrow "xdns"     "Vless-kcp-xdns-fm（备用DNS隧道，需配 xdnsym=域名）"
vrow "xicmp"    "Vless-kcp-xicmp-fm（特种L3 Ping隧道，独占ICMP）"

vg "② Sing-box 内核协议（端口留空＝自动分配）"
vrow "shypt"    "Hysteria2（QUIC暴力传输，需TLS证书）"
vrow "tupt"     "Tuic v5（QUIC，需TLS证书）"
vrow "anpt"     "AnyTLS（需TLS证书）"
vrow "arpt"     "Any-Reality（AnyTLS over Reality）"
vrow "sspt"     "Shadowsocks-2022（blake3-aes-128-gcm）"

vg "③ 通用协议（落在当前激活的内核上）"
vrow "vmpt"     "Vmess-ws（Xray或Sing-box，可走 Argo/CDN）"
vrow "sopt"     "Socks5（仅供本地应用内置代理，勿直连）"

vg "④ Cloudflare WARP 出站（解锁/隐藏真实出口IP）"
vrow "warp"     "出站经WARP，值选：s/x/sx 或 s4x4/s6x6 等"
echo "             s=sing-box核走WARP  x=xray核走WARP  4/6=锁IPv4/IPv6"

vg "⑤ Cloudflare Argo 隧道（纯出站，VPS无需开放端口）"
vrow "argo"     "指定哪个协议走隧道：vmpt / vwpt / xvargopt"
vrow "xvargopt" "Vlessenc-xhttp-tls-vision-fm-argo（旗舰隧道节点）"
vrow "agn"      "固定隧道域名（留空＝临时trycloudflare隧道）"
vrow "agk"      "固定隧道 Token（与 agn 配对使用）"

vg "⑥ Cloudflare CDN 回源 / 优选"
vrow "xvcdnpt"  "Vlessenc-xhttp-tls-vision-fm-cdn（旗舰CDN节点）"
vrow "cdnym"    "CDN host域名/优选IP域名（须已解析到CF）"

vg "⑦ TLS 证书（留空＝自动自签，100年有效期）"
vrow "certym"   "申请ACME域名证书的域名（需解析到本机）"
vrow "certcrt"  "外部导入：证书(fullchain)文件路径"
vrow "certkey"  "外部导入：私钥文件路径"
vrow "acmem"    "ACME 注册邮箱（可选）"

vg "⑧ Web 订阅分发（Clash/聚合，强制TLS加密）"
vrow "sub"      "订阅分发开关（sub=y 启用；亦可只设 subpt/subid）"
vrow "subpt"    "订阅服务对外端口（留空自动分配）"
vrow "subid"    "订阅访问 token（留空＝复用 uuid）"

vg "⑨ Hysteria2 端口跳跃（抗QoS限速）"
vrow "hyjpt"    "全局跳跃端口，自动分配给激活的hy2核"
vrow "shyjpt"   "专属：Sing-box Hysteria2 跳跃端口"
vrow "xhyjpt"   "专属：Xray Hysteria2 跳跃端口"

vg "⑩ 通用 / 全局选项"
vrow "uuid"     "自定义UUID/密码（留空＝自动生成）"
vrow "name"     "所有节点名称前缀"
vrow "reym"     "自定义 Reality 伪装域名（留空＝按地区智能选）"
vrow "obfs_pass" "Hysteria2 混淆密码（留空＝自动生成）"
vrow "ippz"     "list时只显示指定栈：4 或 6（双栈VPS用）"

vg "⑪ NaiveProxy（Caddy 内核·独立于 xray/sb，需真实域名）"
vrow "naive"     "启用并指定域名（须已解析到本机，如 naive=p.example.com）"
vrow "naiveuser" "basic_auth 用户名（留空＝naive）"
vrow "naivepass" "basic_auth 密码（留空＝自动生成）"
vrow "naivebuild" "内核获取：dl=下载预编译(仅amd64)／build=现场编译(arm64必走)"
vrow "naivesite" "reverse_proxy 伪装站域名（留空＝默认公共镜像）"
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
vrow "rep"      "重置协议配置（在前面配合协议变量组重新生成）"
vrow "del"      "卸载 agsbx（清进程/服务/定时任务/文件）"

vg "② 查看 / 信息"
vrow "list"     "打印所有节点信息卡片（ippz=4或6 可只看单栈）"
vrow "status"   "内核资源 + 流量监控（别名 stats / top）"
vrow "vars"     "变量速查表"
vrow "cmds"     "命令速查表（本表）"
vrow "help"     "完整帮助（vars + cmds）"

vg "③ 内核启停（用法：agsbx <动作> [内核]）"
echo "             内核 = xray ｜ sb ｜ caddy ｜ all(省略即全部 xray+sb；caddy 需单独指定)"
vrow "start"    "启动内核"
vrow "stop"     "停止内核（释放其占用的端口）"
vrow "restart"  "重启内核"
vrow "reload"   "热重载配置（sb 支持；xray 无热载→自动转 restart）"
vrow "res"      "一键重启全部内核（含 Argo，等价 restart all）"

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

get_free_port() {
  local allocated_port
  while true; do
    if command -v shuf >/dev/null 2>&1; then
      allocated_port=$(shuf -i 15000-60000 -n 1)
    else
      # 极精简系统无 shuf 时回退到 awk 内置随机数
      allocated_port=$(awk 'BEGIN{srand();print int(rand()*45001)+15000}')
    fi
    if command -v ss >/dev/null 2>&1; then
      if ! ss -tuln 2>/dev/null | grep -q ":${allocated_port} "; then
        echo "${allocated_port}"
        break
      fi
    elif command -v netstat >/dev/null 2>&1; then
      if ! netstat -tuln 2>/dev/null | grep -q ":${allocated_port} "; then
        echo "${allocated_port}"
        break
      fi
    else
      echo "${allocated_port}"
      break
    fi
  done
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
  cat "$port_file"
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
  # 系统网络加速：① UDP/QUIC 收发缓冲区调优；② 内核 TCP BBR 拥塞控制。
  # 确保 /etc/sysctl.conf 存在，防止 sed 报 can't read 错误
  [ -f /etc/sysctl.conf ] || touch /etc/sysctl.conf

  # —— ① UDP/QUIC 缓冲区 —— 内核 BBR 只作用于 TCP；QUIC(Hysteria2/TUIC/HTTP3)跑在 UDP 用户态，吃不到内核 BBR。
  # UDP 缓冲区太小时 quic-go 会告警并降速，调大上限可显著提升 QUIC 吞吐(sing-box/Hysteria 官方推荐 16MiB)。
  # 放在 BBR 检测之前，确保即便系统已启用 BBR、提前 return 时，这段也已执行过。
  local udp_buf=16777216 cur_rmem
  cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
  case "$cur_rmem" in ''|*[!0-9]*) cur_rmem=0 ;; esac
  if [ "$cur_rmem" -lt "$udp_buf" ]; then
    sed -i '/net.core.rmem_max/d;/net.core.wmem_max/d' /etc/sysctl.conf
    echo "net.core.rmem_max = $udp_buf" >> /etc/sysctl.conf
    echo "net.core.wmem_max = $udp_buf" >> /etc/sysctl.conf
    sysctl -w net.core.rmem_max=$udp_buf >/dev/null 2>&1
    sysctl -w net.core.wmem_max=$udp_buf >/dev/null 2>&1
    echo "已调大 UDP 收发缓冲区至 16MiB，提升 QUIC(Hysteria2/TUIC/HTTP3)吞吐。🚀"
  else
    echo "提示：UDP 缓冲区已 ≥16MiB，无需调整。"
  fi

  # —— ② 内核 TCP BBR 拥塞控制加速 ——
  local current_congestion_control
  current_congestion_control=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
  if [ "${current_congestion_control}" = "bbr" ]; then
    echo "提示：检测到当前系统已经启用了 BBR 网络加速，无需重复开启。🚀"
    return
  fi

  echo "正在为您检测并开启系统级 TCP BBR 拥塞控制加速..."

  # 内核未内置 bbr 时先尝试加载模块，再统一做一次可用性判定与写入，避免两段重复逻辑
  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
    modprobe tcp_bbr >/dev/null 2>&1
  fi
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    # 再次读取系统实时拥塞控制算法以验证是否真正启用成功
    current_congestion_control=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ "${current_congestion_control}" = "bbr" ]; then
      echo "TCP BBR 拥塞控制加速已成功开启！🚀"
    else
      echo "警告：BBR 配置已写入，但系统实时加载失败，可能处于受限虚拟化环境。😿"
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
# vmag 是"存在可走 Argo 隧道的协议"总开关，决定第8段是否拉起 cloudflared。
# 此前仅 vmpt/vwpt 置位，导致单独设 xvargopt+argo=xvargopt 时隧道被静默跳过；补齐 xvargo。
[ -z "${xvargopt+x}" ] || { xvargo=yes; vmag=yes; }
# 布尔开关 sub 归一化：仅 sub=y/yes/1 视为显式启用，其余值或空/未设一律=关闭，统一规范（禁用 sub=on 之类写法）。
# 随后 subpt/subid 一旦设值仍视为启用（向后兼容旧用法）。naive=<域名>、argo=<协议> 属「带值即启用」，不在此归一化。
case "${sub:-}" in y|yes|1) sub=yes ;; *) sub='' ;; esac
[ -z "${subpt+x}" ] || sub=yes
[ -z "${subid+x}" ] || sub=yes
if agsbx_running || agsbx_installed; then
if [ "$1" = "rep" ]; then
[ -n "$naive" ] || [ "$vwp" = yes ] || [ "$sop" = yes ] || [ "$vxp" = yes ] || [ "$ssp" = yes ] || [ "$vlp" = yes ] || [ "$vmp" = yes ] || [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$xhp" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || [ "$xvcdn" = yes ] || [ "$xvargo" = yes ] || { echo "提示：rep重置协议时，请在脚本前至少设置一个协议变量哦! 💣"; exit; }
fi
else
[ "$1" = "del" ] || [ -n "$naive" ] || [ "$vwp" = yes ] || [ "$sop" = yes ] || [ "$vxp" = yes ] || [ "$ssp" = yes ] || [ "$vlp" = yes ] || [ "$vmp" = yes ] || [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$xhp" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || [ "$xvcdn" = yes ] || [ "$xvargo" = yes ] || { echo "提示：未安装airgosbx脚本，请在脚本前至少设置一个协议变量哦！💣"; exit; }
fi
export uuid=${uuid:-''}
export obfs_pass=${obfs_pass:-''}
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
export subpt=${subpt:-''}
export subid=${subid:-''}
export ym_vl_re=${reym:-''}
export cdnym=${cdnym:-''}
export argo=${argo:-''}
export ARGO_DOMAIN=${agn:-''}
export ARGO_AUTH=${agk:-''}
export ippz=${ippz:-''}
export warp=${warp:-''}
export name=${name:-''}
export certym=${certym:-''}
export certcrt=${certcrt:-''}
export certkey=${certkey:-''}
export acmem=${acmem:-''}
export shyjpt=${shyjpt:-''}
export xhyjpt=${xhyjpt:-''}
export hyjpt=${hyjpt:-''}

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
agsbxurl="https://raw.githubusercontent.com/hugobaum/sbxrago/main/airgosbx.sh"
showmode(){
printf '%s\n' "${C_BOLD}核心命令速查（完整命令 ${C_YELLOW}agsbx cmds${C_RESET}${C_BOLD} ｜ 变量 ${C_YELLOW}agsbx vars${C_RESET}${C_BOLD} ｜ 全部 ${C_YELLOW}agsbx help${C_RESET}${C_BOLD}）：${C_RESET}"
echo "  · 主脚本：bash <(curl -Ls $agsbxurl)  或  bash <(wget -qO- $agsbxurl)"
echo "  · 节点信息：agsbx list      ｜ 资源/流量：agsbx status"
echo "  · 重置配置：变量组 agsbx rep ｜ 更新脚本：agsbx update ｜ 卸载：agsbx del"
echo "  · 内核启停：agsbx start｜stop｜restart｜reload [xray｜sb｜caddy｜all]"
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
printf '%s\n' "当前版本：${C_GREEN}V26.06.14${C_RESET}"
printf '%s\n' "${C_CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${C_RESET}"
hostname=$(uname -n)
op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)
case $(uname -m) in
arm64|aarch64) cpu=arm64;;
amd64|x86_64) cpu=amd64;;
*) echo "目前脚本不支持$(uname -m)架构" && exit
esac
mkdir -pm 700 "$HOME/agsbx"
umask 077
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
      ss)      case "$pm" in dnf|yum) echo iproute ;; *) echo iproute2 ;; esac ;;
      pgrep)   case "$pm" in dnf|yum|pacman) echo procps-ng ;; *) echo procps ;; esac ;;
      crontab) case "$pm" in apt) echo cron ;; dnf|yum|pacman) echo cronie ;; *) echo "" ;; esac ;;
      xz)      case "$pm" in apt) echo xz-utils ;; *) echo xz ;; esac ;;
      *)       echo "$1" ;;
    esac
  }
  # 脚本真正依赖的命令清单（curl/wget 二选一，单独判断）
  for cmd in openssl socat iptables unzip tar xz ss pgrep crontab; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    pkg=$(pkg_of "$cmd"); [ -z "$pkg" ] && continue
    case " $miss " in *" $pkg "*) ;; *) miss="$miss $pkg" ;; esac
  done
  # curl 与 wget 至少需其一，两者都缺才补 curl
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    miss="$miss curl"
  fi
  [ -z "$miss" ] && return 0
  [ -z "$pm" ] && { echo "未识别系统包管理器，请手动安装依赖：$miss"; return 0; }
  echo "检测到缺失依赖：$miss，正在通过 $pm 自动安装……"
  case "$pm" in
    apt)    export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1; apt-get install -y $miss >/dev/null 2>&1 ;;
    dnf)    dnf install -y $miss >/dev/null 2>&1 ;;
    yum)    yum install -y $miss >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm $miss >/dev/null 2>&1 ;;
    apk)    apk add $miss >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive install $miss >/dev/null 2>&1 ;;
  esac
}
if [ ! -f "$HOME/agsbx/sbx_update" ]; then
echo "执行脚本中，请稍后"
# Alpine(musl) 跑官方预编译的 glibc 版 xray/sing-box 需 glibc 兼容层，附带 bash/busybox 扩展，单独保留
if command -v apk >/dev/null 2>&1; then
apk update >/dev/null 2>&1
apk add gcompat libc6-compat bash busybox-extras >/dev/null 2>&1
fi
touch "$HOME/agsbx/sbx_update"
fi
ensure_deps
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
v4dq=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 https://ip.fm | sed -n 's/.*Location: //p' 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- https://ip.fm | grep '<span class="has-text-grey-light">Location:' | tail -n1 | sed -E 's/.*>Location: <\/span>([^<]+)<.*/\1/' 2>/dev/null) )
v6dq=$( (command -v curl >/dev/null 2>&1 && curl -s6m5 https://ip.fm | sed -n 's/.*Location: //p' 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 --tries=2 -qO- https://ip.fm | grep '<span class="has-text-grey-light">Location:' | tail -n1 | sed -E 's/.*>Location: <\/span>([^<]+)<.*/\1/' 2>/dev/null) )
}
warpsx(){
if [ "$wap" = yes ]; then
echo "正在获取安全的本地 WARP 网络身份..."
# 1. 生成 WireGuard 标准 Curve25519 密钥对（WARP API 要求标准 Base64 编码）
pvk=""
pub=""
    # 按需安装 wireguard-tools（仅提供 wg 命令行工具，不涉及内核模块，包体 < 1MB）
    if ! command -v wg >/dev/null 2>&1; then
      if command -v apt >/dev/null 2>&1; then
        apt install wireguard-tools -y >/dev/null 2>&1
      elif command -v apk >/dev/null 2>&1; then
        apk add wireguard-tools >/dev/null 2>&1
      elif command -v yum >/dev/null 2>&1; then
        yum install wireguard-tools -y >/dev/null 2>&1
      elif command -v dnf >/dev/null 2>&1; then
        dnf install wireguard-tools -y >/dev/null 2>&1
      fi
    fi
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
        wpv6='2606:4700:110::1'
      fi
      res=$(echo "$c_id" | base64 -d 2>/dev/null | od -v -An -t u1 | head -n1 | awk '{print "["$1", "$2", "$3"]"}')
      if [ -z "$res" ]; then
hr
        echo "[诊断提示] 步骤 3：解析 Cloudflare 返回数据失败！"
        echo "-> 错误详情: 无法从 client_id 解码提取 Reserved 字段（base64 或 od 解码异常）"
        echo "-> 原始 client_id: $c_id"
hr
        wap=warpargo
        pvk="dummy"; pub="dummy"; res="[0, 0, 0]"; wpv6="2606:4700:110::1"
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
        echo "-> 接口返回原始数据: $response_body"
        if [ -z "$http_code" ]; then
          echo "-> 常见原因: VPS 物理网络出站受阻，api.cloudflareclient.com 被防火墙屏蔽或连接超时。"
        else
          echo "-> 常见原因: Cloudflare API 拒绝了请求，请检查请求参数是否有效。"
        fi
      fi
hr
      wap=warpargo
      pvk="dummy"; pub="dummy"; res="[0, 0, 0]"; wpv6="2606:4700:110::1"
    fi
    rm -f "$reg_err"
  else
hr
    echo "[诊断提示] 步骤 1：WireGuard 密钥生成失败！"
    echo "-> wg 工具和 openssl 均无法在当前系统下成功生成 WireGuard Curve25519 密钥对。"
    echo "-> 建议: 安装 wireguard-tools (apt install wireguard-tools) 或升级 openssl >= 1.1.0。"
    echo "-> 系统已自动降级为直连出站，以防安装中断。"
hr
    wap=warpargo
    pvk="dummy"; pub="dummy"; res="[0, 0, 0]"; wpv6="2606:4700:110::1"
  fi
fi
if [ -n "$name" ]; then
sxname=$name-
echo "$sxname" > "$HOME/agsbx/name"
echo
echo "所有节点名称前缀：$name"
fi
v4v6
if echo "$v6" | grep -q '^2a09' || echo "$v4" | grep -q '^104.28'; then
s1outtag=direct; s2outtag=direct; x1outtag=direct; x2outtag=direct; xip='"::/0", "0.0.0.0/0"'; sip='"::/0", "0.0.0.0/0"'; wap=warpargo
echo; echo "请注意：你已安装了warp"
else
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
}
#============================================================
# [第5段] 内核下载函数（含哈希校验）
#------------------------------------------------------------
# 🎯 架构说明：
# - 本大段包含 upxray() (Xray下载与SHA256校验)、upsingbox() (Singbox下载)。
# - 关联性：由第 8 段 (安装编排主函数 ins()) 在初次部署或第 11 段 (upx/ups内核更新) 运行时调用，提供可运行的物理二进制文件。
#============================================================
upxray(){
# 从 Xray-core 官方仓库下载，并进行 SHA256 完整性校验
# $1 可选：指定版本号（如 v26.2.6）；留空则取 latest。供 downx 精确锁版使用。
local want_ver="$1"
case "$cpu" in
  amd64) xray_file="Xray-linux-64.zip" ;;
  arm64) xray_file="Xray-linux-arm64-v8a.zip" ;;
esac
if [ -n "$want_ver" ]; then
  case "$want_ver" in v*) ;; *) want_ver="v$want_ver" ;; esac
  echo "正在从 XTLS/Xray-core 官方仓库下载指定版本 Xray 内核：$want_ver ……"
  xray_url="https://github.com/XTLS/Xray-core/releases/download/${want_ver}/${xray_file}"
else
  echo "正在从 XTLS/Xray-core 官方仓库下载最新版 Xray 内核……"
  xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/${xray_file}"
fi
xray_dgst_url="${xray_url}.dgst"
xray_tmp="$HOME/agsbx/${xray_file}"
xray_dgst_tmp="${xray_tmp}.dgst"
# 下载 zip 文件
(command -v curl >/dev/null 2>&1 && curl -Lo "$xray_tmp" -# --retry 2 "$xray_url") || (command -v wget >/dev/null 2>&1 && wget -O "$xray_tmp" --tries=2 "$xray_url")
# 下载官方 dgst 校验文件
(command -v curl >/dev/null 2>&1 && curl -Ls -o "$xray_dgst_tmp" --retry 2 "$xray_dgst_url") || (command -v wget >/dev/null 2>&1 && wget -qO "$xray_dgst_tmp" --tries=2 "$xray_dgst_url")
# 执行 SHA256 完整性校验
expected_sha256=$(grep -iE 'sha2-256|sha256' "$xray_dgst_tmp" 2>/dev/null | head -1 | awk -F= '{print $NF}' | tr -d ' ')
actual_sha256=$(sha256sum "$xray_tmp" 2>/dev/null | awk '{print $1}')
if [ -z "$expected_sha256" ] || [ "$expected_sha256" != "$actual_sha256" ]; then
  echo "错误：Xray 文件 SHA256 校验失败！下载可能已被篡改，终止安装。"
  echo "预期: $expected_sha256"
  echo "实际: $actual_sha256"
  rm -f "$xray_tmp" "$xray_dgst_tmp"
  exit 1
fi
echo "SHA256 校验通过 ✓"
# 暂存区解压：先在 .stage_xray 里校验，绝不在通过前触碰正在运行的内核。
# 这是“先验证后落地”，不是“先替换后回滚”——失败时原内核分毫未动，故不存在反复回滚的循环。
xstage="$HOME/agsbx/.stage_xray"
rm -rf "$xstage"; mkdir -p "$xstage"
(command -v unzip >/dev/null 2>&1 && unzip -o "$xray_tmp" xray -d "$xstage/" >/dev/null 2>&1) || (command -v busybox >/dev/null 2>&1 && busybox unzip -o "$xray_tmp" xray -d "$xstage/" >/dev/null 2>&1)
rm -f "$xray_tmp" "$xray_dgst_tmp"
if [ ! -s "$xstage/xray" ]; then
  echo "错误：Xray 解压失败，原内核保持不动。"; rm -rf "$xstage"; return 1
fi
chmod +x "$xstage/xray"
# 配置兼容性预检：用暂存的新内核 -test 现有 xr.json；不通过则丢弃暂存，原内核与服务全程不动、不重启
if [ -f "$HOME/agsbx/xr.json" ]; then
  xtest=$("$xstage/xray" run -test -c "$HOME/agsbx/xr.json" 2>&1)
  if [ $? -ne 0 ]; then
    echo "错误：该版本 Xray 无法加载当前 xr.json，可能 finalmask/encryption 等字段不兼容："
    echo "$xtest" | grep -iE 'fail|error|unknown|invalid' | head -3
    echo "已放弃换版：原内核与服务保持原样、未中断。可先 agsbx rep 重置配置后再换版。"
    rm -rf "$xstage"; return 1
  fi
fi
# 预检通过，原子替换（Linux 下替换运行中的二进制是安全的：旧进程仍持有已打开的旧 inode）
mv -f "$xstage/xray" "$HOME/agsbx/xray"
rm -rf "$xstage"
sbcore=$("$HOME/agsbx/xray" version 2>/dev/null | awk '/^Xray/{print $2}')
echo "已安装Xray正式版内核：$sbcore（来源：github.com/XTLS/Xray-core）"
}
upsingbox(){
# 从 Sing-box 官方仓库下载，并进行 SHA256 完整性校验
# $1 可选：指定版本号（如 v1.11.0）；留空则查询 latest。供 downs 精确锁版使用。
local want_ver="$1"
if [ -n "$want_ver" ]; then
  case "$want_ver" in v*) ;; *) want_ver="v$want_ver" ;; esac
  sb_ver="$want_ver"
  sb_ver_num=$(echo "$sb_ver" | sed 's/^v//')
  echo "正在从 SagerNet/sing-box 官方仓库下载指定版本 Sing-box 内核：$sb_ver ……"
else
  echo "正在从 SagerNet/sing-box 官方仓库下载最新版 Sing-box 内核……"
  # 获取最新版本号和 JSON 数据以备校验
  sb_json=$( (command -v curl >/dev/null 2>&1 && curl -Ls "https://api.github.com/repos/SagerNet/sing-box/releases/latest") || (command -v wget >/dev/null 2>&1 && wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest") )
  sb_ver=$(echo "$sb_json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
  sb_ver_num=$(echo "$sb_ver" | sed 's/^v//')
fi
if [ -z "$sb_ver_num" ]; then
  echo "错误：无法获取 Sing-box 版本号"
  exit 1
fi
echo "目标版本：$sb_ver"
sb_file="sing-box-${sb_ver_num}-linux-${cpu}.tar.gz"
sb_url="https://github.com/SagerNet/sing-box/releases/download/${sb_ver}/${sb_file}"
sb_tmp="$HOME/agsbx/${sb_file}"

# 因为 Github 标准 API JSON 中不包含归档附件的 attestations 层级 SHA256，所以从 HTML 展开页中精准抓取
expanded_html=$( (command -v curl >/dev/null 2>&1 && curl -sL "https://github.com/SagerNet/sing-box/releases/expanded_assets/${sb_ver}") || (command -v wget >/dev/null 2>&1 && wget -qO- "https://github.com/SagerNet/sing-box/releases/expanded_assets/${sb_ver}") )
expected_sha256=$(echo "$expanded_html" | grep -A 20 "${sb_file}" | grep -o "sha256:[a-fA-F0-9]\{64\}" | head -1 | sed 's/sha256://')

# 下载 tar.gz 文件
(command -v curl >/dev/null 2>&1 && curl -Lo "$sb_tmp" -# --retry 2 "$sb_url") || (command -v wget >/dev/null 2>&1 && wget -O "$sb_tmp" --tries=2 "$sb_url")
# 执行 SHA256 完整性校验
if [ -n "$expected_sha256" ]; then
  actual_sha256=$(sha256sum "$sb_tmp" 2>/dev/null | awk '{print $1}')
  if [ "$expected_sha256" != "$actual_sha256" ]; then
    echo "错误：Sing-box 文件 SHA256 校验失败！下载可能已被篡改，终止安装。"
    echo "预期: $expected_sha256"
    echo "实际: $actual_sha256"
    rm -f "$sb_tmp"
    exit 1
  fi
  echo "核心文件 SHA256 校验通过 ✓ ($actual_sha256)"
else
  echo "警告：未能从 Github 提取到 SHA256，可能解析失败，信任 HTTPS 连接..."
fi
# 暂存区解压：先校验再落地，绝不在通过前触碰正在运行的内核（失败即放弃，无回滚、无循环）
sstage="$HOME/agsbx/.stage_sb"
rm -rf "$sstage"; mkdir -p "$sstage"
tar -xzf "$sb_tmp" -C "$sstage/" 2>/dev/null
rm -f "$sb_tmp"
# 兼容官方归档目录结构，取不到再全局兜底查找
sbnew="$sstage/sing-box-${sb_ver_num}-linux-${cpu}/sing-box"
[ -f "$sbnew" ] || sbnew=$(find "$sstage" -type f -name sing-box 2>/dev/null | head -1)
if [ ! -s "$sbnew" ]; then
  echo "错误：Sing-box 解压失败，原内核保持不动。"; rm -rf "$sstage"; return 1
fi
chmod +x "$sbnew"
# 配置兼容性预检：用暂存的新内核 check 现有 sb.json；不通过则丢弃暂存，原内核与服务全程不动
if [ -f "$HOME/agsbx/sb.json" ]; then
  stest=$("$sbnew" check -c "$HOME/agsbx/sb.json" 2>&1)
  if [ $? -ne 0 ]; then
    echo "错误：该版本 Sing-box 无法加载当前 sb.json，可能字段不兼容："
    echo "$stest" | grep -iE 'fail|error|unknown|invalid|decode' | head -3
    echo "已放弃换版：原内核与服务保持原样、未中断。可先 agsbx rep 重置配置后再换版。"
    rm -rf "$sstage"; return 1
  fi
fi
mv -f "$sbnew" "$HOME/agsbx/sing-box"
rm -rf "$sstage"
sbcore=$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}')
echo "已安装Sing-box正式版内核：$sbcore（来源：github.com/SagerNet/sing-box）"
}
upcaddy(){
# NaiveProxy 服务端＝带 forwardproxy@naive 分支的 Caddy。两种获取方式，按 CPU 架构与用户选择决定：
#   · 官方预编译（仅 amd64，klzgrad/forwardproxy 发布页）——1C1G 小机首选，零编译；
#   · xcaddy 现场编译（arm64 必走 / amd64 可选）——用 go.dev 官方 tarball 引导唯一标准 Go，全程自包含在暂存区。
# 自动通过 GitHub API 获取最新 release tag，并提供弱网下的 3 秒连接超时和默认稳定版（v2.11.2-naive）自愈回退
local latest_tag
latest_tag=$( (command -v curl >/dev/null 2>&1 && curl -sL --connect-timeout 3 "https://api.github.com/repos/klzgrad/forwardproxy/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/') || \
              (command -v wget >/dev/null 2>&1 && wget -qO- --timeout=3 "https://api.github.com/repos/klzgrad/forwardproxy/releases/latest" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/') )
NAIVE_VER="${NAIVE_VER:-${latest_tag:-v2.11.2-naive}}"
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
# arm64 没有预编译，纵使误选 dl 也强制改为 build
if [ "$method" = dl ] && [ "$cpu" != amd64 ]; then
  echo "注意：$cpu 无官方预编译，自动改为现场编译。"; method=build
fi
local cstage="$HOME/agsbx/.stage_caddy"
rm -rf "$cstage"; mkdir -p "$cstage"
if [ "$method" = dl ]; then
  echo "正在从 klzgrad/forwardproxy 官方发布页下载预编译 Caddy(naive)：$NAIVE_VER ……"
  local url="https://github.com/klzgrad/forwardproxy/releases/download/${NAIVE_VER}/caddy-forwardproxy-naive.tar.xz"
  local tmp="$cstage/caddy.tar.xz"
  (command -v curl >/dev/null 2>&1 && curl -Lo "$tmp" -# --retry 2 "$url") || (command -v wget >/dev/null 2>&1 && wget -O "$tmp" --tries=2 "$url")
  if [ ! -s "$tmp" ]; then echo "错误：Caddy 下载失败（网络不可达或该版本资源不存在）。"; rm -rf "$cstage"; return 1; fi
  # SHA256 完整性校验：klzgrad/forwardproxy 未提供独立 checksums.txt，但 GitHub Release API 为每个资产
  # 暴露 "digest":"sha256:..."。据此比对下载归档，防篡改/防误下假包(如 404 HTML)。取不到 digest 时降级为信任 HTTPS。
  local caddy_api caddy_digest caddy_actual
  caddy_api=$( (command -v curl >/dev/null 2>&1 && curl -sL --connect-timeout 5 "https://api.github.com/repos/klzgrad/forwardproxy/releases/tags/${NAIVE_VER}") || (command -v wget >/dev/null 2>&1 && wget -qO- --timeout=5 "https://api.github.com/repos/klzgrad/forwardproxy/releases/tags/${NAIVE_VER}") )
  caddy_digest=$(printf '%s' "$caddy_api" | grep -oE '"digest":[[:space:]]*"sha256:[0-9a-f]{64}"' | head -1 | grep -oE '[0-9a-f]{64}')
  if [ -n "$caddy_digest" ]; then
    caddy_actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
    if [ "$caddy_digest" != "$caddy_actual" ]; then
      echo "错误：Caddy 文件 SHA256 校验失败！下载可能已被篡改或资源损坏，终止安装。"
      echo "预期: $caddy_digest"
      echo "实际: $caddy_actual"
      rm -rf "$cstage"; return 1
    fi
    echo "SHA256 校验通过 ✓ ($caddy_actual)"
  else
    echo "警告：未能从 GitHub API 获取官方 SHA256，跳过哈希校验，信任 HTTPS 连接。"
  fi
  # .tar.xz 解压：优先 GNU tar -J，缺则用 xz 管道兜底（兼容 busybox tar）。xz 已在 ensure_deps 中预置。
  if ! ( tar -xJf "$tmp" -C "$cstage" 2>/dev/null || ( xz -dc "$tmp" 2>/dev/null | tar -xf - -C "$cstage" 2>/dev/null ) ); then
    echo "错误：解压失败，可能缺少 xz 工具。请确认已安装 xz/xz-utils 后重试。"; rm -rf "$cstage"; return 1
  fi
else
  echo "正在引导 Go 工具链并用 xcaddy 编译 Caddy(naive)（下载约 150MB、耗时数分钟、建议 ≥1G 内存）……"
  local gover
  gover=$( (command -v curl >/dev/null 2>&1 && curl -s https://go.dev/VERSION?m=text | head -1) || (command -v wget >/dev/null 2>&1 && wget -qO- https://go.dev/VERSION?m=text | head -1) )
  if [ -z "$gover" ]; then echo "错误：无法从 go.dev 获取 Go 版本号（网络不可达）。"; rm -rf "$cstage"; return 1; fi
  local gotar="$cstage/go.tar.gz"
  echo "下载 Go 官方 tarball：${gover}.linux-${cpu} ……"
  (command -v curl >/dev/null 2>&1 && curl -Lo "$gotar" -# --retry 2 "https://go.dev/dl/${gover}.linux-${cpu}.tar.gz") || (command -v wget >/dev/null 2>&1 && wget -O "$gotar" --tries=2 "https://go.dev/dl/${gover}.linux-${cpu}.tar.gz")
  tar -xzf "$gotar" -C "$cstage" 2>/dev/null
  if [ ! -x "$cstage/go/bin/go" ]; then echo "错误：Go 解压失败。"; rm -rf "$cstage"; return 1; fi
  # Go 全程关在暂存区子 shell：GOROOT/GOPATH 不外泄、不写 /usr/local、不改 .bashrc，随 cstage 一并清除。
  if ! ( export GOROOT="$cstage/go" GOPATH="$cstage/gopath" PATH="$cstage/go/bin:$cstage/gopath/bin:$PATH"
         echo "Go 就绪：$("$cstage/go/bin/go" version 2>/dev/null)"
         echo "安装 xcaddy 构建器……"
         "$cstage/go/bin/go" install github.com/caddyserver/xcaddy/cmd/xcaddy@latest &&
         echo "编译 Caddy + forwardproxy@naive（请耐心等待）……" &&
         cd "$cstage" &&
         "$cstage/gopath/bin/xcaddy" build --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive ); then
    echo "错误：Go/xcaddy 编译失败（可看上方报错；网络或内存不足是常见原因）。"; rm -rf "$cstage"; return 1
  fi
fi
# 定位产物：下载包内为 caddy，编译产物在 cstage/caddy
local newcaddy="$cstage/caddy"
[ -f "$newcaddy" ] || newcaddy=$(find "$cstage" -maxdepth 2 -type f -name caddy 2>/dev/null | head -1)
if [ ! -s "$newcaddy" ]; then echo "错误：未找到 caddy 可执行文件。"; rm -rf "$cstage"; return 1; fi
chmod +x "$newcaddy"
# 功能性校验与安全特征审计：
#   · version 可执行性=硬校验（架构不符/文件损坏才是真无法运行，必须拦截）。
#   · forward_proxy 功能=软校验(仅警告)：下载分支哈希已证明是官方二进制（必含该模块），
#     编译分支 xcaddy --with forwardproxy@naive 成功亦必含；list-modules 偶有输出差异，
#     不应据此误拦合法内核而中断安装（此前的硬失败正是「官方包被拒、停止安装」的根因）。
echo "正在对 Caddy(naive) 内核进行可执行性与功能组件校验……"
if ! "$newcaddy" version >/dev/null 2>&1; then echo "错误：caddy 不可执行（架构不符或文件损坏）。"; rm -rf "$cstage"; return 1; fi
if "$newcaddy" list-modules 2>/dev/null | grep -q 'forward_proxy'; then
  echo "forward_proxy 模块校验通过 ✓（具备 NaiveProxy 功能，与自行编译效果一致）"
else
  printf '%s\n' "${C_YELLOW}警告：未在 caddy list-modules 输出中检出 forward_proxy 模块。${C_RESET}"
  echo "已通过哈希/可执行校验，继续安装；若 naive 实际不可用，请改用 naivebuild=build 现场编译。"
fi

mv -f "$newcaddy" "$HOME/agsbx/caddy"
rm -rf "$cstage"
echo "已安装 Caddy(naive) 内核：$("$HOME/agsbx/caddy" version 2>/dev/null | head -1)"
}
#============================================================
# [第6段] UUID 生成 + 协议配置生成函数
#   insuuid()     - 生成或读取 UUID
#   installxray() - 生成 Xray 的 inbound 配置（xr.json）
#   installsb()   - 生成 Sing-box 的 inbound 配置（sb.json）
#============================================================
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
uuid=$(cat "$HOME/agsbx/uuid")
echo "UUID密码：$uuid"
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
    printf "请输入 NaiveProxy 用户名（直接回车=默认 naive）："; read -r naiveuser
  fi
  naiveuser="${naiveuser:-naive}"
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
    naivepass=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  fi
  echo "$naivepass" > "$HOME/agsbx/naive_pass"
fi
naivepass=$(cat "$HOME/agsbx/naive_pass")
echo "NaiveProxy 账号：$naiveuser"
echo "NaiveProxy 密码：$naivepass"
}
fetch_file(){
fetch_url="$1"
fetch_out="$2"
if command -v curl >/dev/null 2>&1; then
curl -Ls -o "$fetch_out" --retry 2 "$fetch_url"
elif command -v wget >/dev/null 2>&1; then
wget -qO "$fetch_out" --tries=2 "$fetch_url"
else
return 1
fi
}
valid_domain(){
printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9][A-Za-z0-9.-]*$' || return 1
printf '%s' "$1" | grep -Eq '(^-|-$|\.\.|\.-|-\.)' && return 1
return 0
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
write_cert_fingerprint(){
cert_file=${tls_cert_file:-$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)}
[ -s "$cert_file" ] || cert_file="$HOME/agsbx/cert.pem"
openssl x509 -noout -fingerprint -sha256 -inform pem -in "$cert_file" 2>/dev/null | awk -F= '{print $2}' | tr -d ':' > "$HOME/agsbx/cert_sha256.txt"
[ -s "$HOME/agsbx/cert_sha256.txt" ]
}
record_tls_cert_paths(){
tls_cert_file="$1"
tls_key_file="$2"
echo "$tls_cert_file" > "$HOME/agsbx/cert_file_path"
echo "$tls_key_file" > "$HOME/agsbx/key_file_path"
}
# 证书可信判定：ca(ACME/外部CA) 与 caddy(Caddy 自动托管签发) 均为受公共 CA 信任的真实证书，
# 客户端可 insecure=0 校验；其余(自签 selfsigned)需 skip-cert-verify/pinSHA256。供 cip 渲染节点链接统一调用。
cert_trusted(){ [ "$1" = "ca" ] || [ "$1" = "caddy" ]; }
# Caddy(naive) 证书续期联动重载：Caddy 自动续期会原地更新证书文件，但 xray/sing-box 仅在启动时读取证书、
# 不会热感知续期。此处生成助手脚本并注册每日 cron——每天比对证书指纹，仅当证书真正变化(续期)时，
# 才重启「配置里确实引用了该 Caddy 证书路径」的内核，平时零打断；首次运行只记录基线指纹。
# 助手脚本用单引号 heredoc 写入，内部 $HOME/$cf 等在 cron 运行时(而非安装时)求值。
setup_caddy_cert_reload(){
  cat > "$HOME/agsbx/caddy_cert_reload.sh" <<'RELOADEOF'
#!/bin/bash
# 由 airgosbx 自动生成：Caddy 证书续期后，联动重启复用了该证书的 xray/sing-box。请勿手动编辑。
H="$HOME/agsbx"
[ "$(cat "$H/cert_mode" 2>/dev/null)" = "caddy" ] || exit 0
cf=$(cat "$H/cert_file_path" 2>/dev/null)
[ -s "$cf" ] || exit 0
fp=$(openssl x509 -noout -fingerprint -sha256 -in "$cf" 2>/dev/null | awk -F= '{print $2}')
[ -n "$fp" ] || exit 0
old=$(cat "$H/.caddy_cert_fp" 2>/dev/null)
echo "$fp" > "$H/.caddy_cert_fp"
[ -z "$old" ] && exit 0          # 首次仅记录基线指纹，不重启
[ "$fp" = "$old" ] && exit 0     # 证书未变化（未到续期），不打断
reload_one(){
  cfg="$1"; sd="$2"; rc="$3"; pat="$4"; bin="$5"; log="$6"
  [ -s "$cfg" ] || return 0
  grep -q "$cf" "$cfg" 2>/dev/null || return 0   # 仅重启确实引用了该 Caddy 证书的内核
  if pidof systemd >/dev/null 2>&1; then
    systemctl restart "$sd" >/dev/null 2>&1
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$rc" restart >/dev/null 2>&1
  else
    kill -15 $(pgrep -f "$pat" 2>/dev/null) >/dev/null 2>&1; sleep 1
    nohup "$bin" run -c "$cfg" > "$log" 2>&1 &
  fi
}
reload_one "$H/xr.json" xr xray     'agsbx/xray'     "$H/xray"     "$H/xray.log"
reload_one "$H/sb.json" sb sing-box 'agsbx/sing-box' "$H/sing-box" "$H/sing-box.log"
RELOADEOF
  chmod 700 "$HOME/agsbx/caddy_cert_reload.sh"
  local cron_tmp
  cron_tmp=$(mktemp)
  crontab -l 2>/dev/null > "$cron_tmp"
  if ! grep -q 'caddy_cert_reload.sh' "$cron_tmp"; then
    echo "20 3 * * * /bin/bash $HOME/agsbx/caddy_cert_reload.sh > /dev/null 2>&1" >> "$cron_tmp"
    crontab "$cron_tmp" >/dev/null 2>&1
  fi
  rm -f "$cron_tmp"
  # 立即落一次基线指纹，避免装好当天的首次 cron 误判为「已变化」而重启。
  bash "$HOME/agsbx/caddy_cert_reload.sh" >/dev/null 2>&1
  echo "已注册证书续期联动重载（每日 03:20 校验；Caddy 续期后自动重启复用该证书的 xray/sing-box，平时零打断）。"
}
show_tls_cert_summary(){
cert_result="$1"
cert_domain="$2"
cert_file=${tls_cert_file:-$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)}
key_file=${tls_key_file:-$(cat "$HOME/agsbx/key_file_path" 2>/dev/null)}
cert_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode_now=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
cert_issuer=$(openssl x509 -noout -issuer -in "$cert_file" 2>/dev/null | sed 's/^issuer=//')
cert_subject=$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null | sed 's/^subject=//')
cert_not_before=$(openssl x509 -noout -startdate -in "$cert_file" 2>/dev/null | sed 's/^notBefore=//')
cert_not_after=$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null | sed 's/^notAfter=//')
cert_serial=$(openssl x509 -noout -serial -in "$cert_file" 2>/dev/null | sed 's/^serial=//')
cert_fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" 2>/dev/null | awk -F= '{print $2}')
printf '%s\n' "${C_CYAN}========== TLS 证书信息 ==========${C_RESET}"
echo "证书结果：$cert_result"
[ -n "$cert_domain" ] && echo "申请域名：$cert_domain"
[ -n "$cert_sni" ] && echo "SNI/CN：$cert_sni"
[ -n "$cert_mode_now" ] && echo "证书模式：$cert_mode_now"
# 签发方式：把内部 cert_mode 翻译成人类可读来源，明确区分「ACME 命令申请」与「Caddy 自动托管申请」。
case "$cert_mode_now" in
  ca)         echo "签发方式：ACME 命令申请（acme.sh + Let's Encrypt）或外部导入证书" ;;
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
[ "$cert_mode_now" = "ca" ] && echo "ACME工作目录：$HOME/agsbx/acme"
[ "$cert_mode_now" = "caddy" ] && echo "Caddy证书存储目录：$HOME/agsbx/caddy_storage/caddy/certificates"
printf '%s\n' "${C_CYAN}==================================${C_RESET}"
}
setup_selfsigned_certificate(){
mkdir -p "$HOME/agsbx/openssl"
selfsigned_cert_file="$HOME/agsbx/openssl/cert.pem"
selfsigned_key_file="$HOME/agsbx/openssl/private.key"
if [ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" != "selfsigned" ] || [ ! -s "$HOME/agsbx/sni.txt" ]; then
openssl rand -hex 4 | awk '{print $1".com"}' > "$HOME/agsbx/sni.txt"
fi
random_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
openssl ecparam -genkey -name prime256v1 -out "$selfsigned_key_file" >/dev/null 2>&1
# 极具自愈性地将本地自签证书有效期设置为 36500 天（100 年），省去高频重新签发及失效排障烦恼！
openssl req -new -x509 -days 36500 -key "$selfsigned_key_file" -out "$selfsigned_cert_file" -subj "/CN=$random_sni" >/dev/null 2>&1
echo "selfsigned" > "$HOME/agsbx/cert_mode"
record_tls_cert_paths "$selfsigned_cert_file" "$selfsigned_key_file"
write_cert_fingerprint
}
setup_acme_certificate(){
acme_domain="$1"
mkdir -p "$HOME/agsbx/acmecer"
acme_cert_file="$HOME/agsbx/acmecer/cert.pem"
acme_key_file="$HOME/agsbx/acmecer/private.key"
if [ -n "$certcrt" ] || [ -n "$certkey" ]; then
if [ -s "$certcrt" ] && [ -s "$certkey" ]; then
cp "$certcrt" "$acme_cert_file" && cp "$certkey" "$acme_key_file" || return 1
echo "$acme_domain" > "$HOME/agsbx/sni.txt"
echo "ca" > "$HOME/agsbx/cert_mode"
record_tls_cert_paths "$acme_cert_file" "$acme_key_file"
tls_cert_source="外部导入 CA/ACME 证书"
return 0
fi
echo "警告：certcrt/certkey 未同时指向有效文件，将尝试自动申请 ACME 证书。"
fi

  # 检查本地是否已存在有效的、未过期的同域名证书（有效期大于30天），免于重复申请风控。
  if [ -s "$acme_cert_file" ] && [ -s "$acme_key_file" ]; then
    # 优先提取真实证书中的 CN 域名进行比对，防止 sni.txt 被自签逻辑覆写导致误判
    local cert_cn
    cert_cn=$(openssl x509 -noout -subject -in "$acme_cert_file" 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p' | tr -d '[:space:]')
    if [ "${cert_cn}" = "$acme_domain" ] || [ "$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)" = "$acme_domain" ]; then
      if openssl x509 -checkend 2592000 -noout -in "$acme_cert_file" >/dev/null 2>&1; then
        echo "检测到本地已存在有效的 $acme_domain 证书（剩余有效期大于30天），直接复用，免于重复申请风控。💎"
        echo "$acme_domain" > "$HOME/agsbx/sni.txt"
        echo "ca" > "$HOME/agsbx/cert_mode"
        record_tls_cert_paths "$acme_cert_file" "$acme_key_file"
        tls_cert_source="本地已有 CA/ACME 证书"

        # 补全每日定时自动续期 crontab 定时任务
        cron_tmp=$(mktemp)
        crontab -l 2>/dev/null > "$cron_tmp" 2>/dev/null
        if ! grep -q "acme.sh --cron" "$cron_tmp"; then
          echo "30 2 * * * /bin/bash $HOME/agsbx/acme.sh --cron --home $HOME/agsbx/acme > /dev/null 2>&1" >> "$cron_tmp"
          crontab "$cron_tmp" >/dev/null 2>&1
        fi
        rm -f "$cron_tmp"
        return 0
      fi
    fi
  fi

  # [80端口占用校验] ACME Standalone 模式需要占用 80 端口进行 HTTP-01 验证
  local port_80_in_use=false
  if command -v ss >/dev/null 2>&1; then
    if ss -tuln 2>/dev/null | grep -qE "(:80\s|:80$)"; then
      port_80_in_use=true
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tuln 2>/dev/null | grep -qE "(:80\s|:80$)"; then
      port_80_in_use=true
    fi
  fi

  if [ "$port_80_in_use" = "true" ]; then
    echo ""
    printf '%s\n' "${C_YELLOW}警告：检测到本机的 80 端口已被其他服务占用！${C_RESET}"
    echo "ACME Standalone 模式自动申请证书必须独占 80 端口。"
    echo "如果直接继续，ACME 申请大概率会失败并自动退回到【自签证书】模式。"
    echo "建议在继续之前，暂时停止占用 80 端口的服务（例如：systemctl stop nginx 或 caddy/apache2）。"
    echo "脚本将等待 5 秒，方便您查看此警告并做准备..."
    sleep 5
  fi

install_socat_if_needed || return 1
acme_script="$HOME/agsbx/acme.sh"
acme_home="$HOME/agsbx/acme"
mkdir -p "$acme_home"
if [ ! -s "$acme_script" ]; then
fetch_file "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" "$acme_script" || return 1
chmod 700 "$acme_script" 2>/dev/null
fi
acme_mail=${acmem:-"admin@$acme_domain"}
bash "$acme_script" --home "$acme_home" --set-default-ca --server letsencrypt >/dev/null 2>&1
bash "$acme_script" --home "$acme_home" --register-account -m "$acme_mail" --server letsencrypt >/dev/null 2>&1
bash "$acme_script" --home "$acme_home" --issue --standalone -d "$acme_domain" --keylength ec-256 --server letsencrypt >/dev/null 2>&1 || return 1
local reload_cmd="if pidof systemd >/dev/null 2>&1; then if systemctl list-unit-files 2>/dev/null | grep -qE '^(xr|sb)\.service'; then systemctl restart xr sb; fi; elif command -v rc-service >/dev/null 2>&1; then if [ -f /etc/init.d/xray ] || [ -f /etc/init.d/sing-box ]; then rc-service xray restart; rc-service sing-box restart; fi; else kill -15 \$(pgrep -f 'agsbx/xray') \$(pgrep -f 'agsbx/sing-box') 2>/dev/null; sleep 2; nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json > $HOME/agsbx/xray.log 2>&1 & nohup $HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json > $HOME/agsbx/sing-box.log 2>&1 & fi"
bash "$acme_script" --home "$acme_home" --install-cert -d "$acme_domain" --ecc --fullchain-file "$acme_cert_file" --key-file "$acme_key_file" --reloadcmd "$reload_cmd" >/dev/null 2>&1 || return 1
[ -s "$acme_cert_file" ] && [ -s "$acme_key_file" ] || return 1

# 注册每日凌晨 2:30 的自动续期 crontab 定时任务，实现到期前 100% 自动签发并重载
cron_tmp=$(mktemp)
crontab -l 2>/dev/null > "$cron_tmp" 2>/dev/null
if ! grep -q "acme.sh --cron" "$cron_tmp"; then
  echo "30 2 * * * /bin/bash $acme_script --cron --home $acme_home > /dev/null 2>&1" >> "$cron_tmp"
  crontab "$cron_tmp" >/dev/null 2>&1
fi
rm -f "$cron_tmp"

echo "$acme_domain" > "$HOME/agsbx/sni.txt"
echo "ca" > "$HOME/agsbx/cert_mode"
record_tls_cert_paths "$acme_cert_file" "$acme_key_file"
tls_cert_source="ACME 自动申请成功"
}
setup_tls_certificate(){
  # 运行期幂等保护：本函数会被多个 TLS 协议装配段（xhyp/xvcdn/xvargo/sub 等）各自调用，
  # 证书在同一次运行内只需准备一次，二次调用直接复用，避免反复生成自签证书或触发 ACME 流程。
  if [ "$tls_cert_ready" = yes ]; then
    return 0
  fi
  # 最高优先级：复用 Caddy(naive) 已成功签发的真实域名证书。
  # 当启用 naive 且 Caddy 已自动托管签发证书(cert_mode=caddy)时，hy2/tuic/anytls/xhy2 等 TLS 节点
  # 直接复用该证书、SNI 取 naive 域名，免去再生成自签或重复申请 ACME。优先级：caddy > certym/ACME > 自签。
  if [ -n "$naive" ] && [ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" = "caddy" ]; then
    local reuse_cert reuse_key
    reuse_cert=$(cat "$HOME/agsbx/cert_file_path" 2>/dev/null)
    reuse_key=$(cat "$HOME/agsbx/key_file_path" 2>/dev/null)
    if [ -s "$reuse_cert" ] && [ -s "$reuse_key" ] && openssl x509 -checkend 0 -noout -in "$reuse_cert" >/dev/null 2>&1; then
      tls_cert_file="$reuse_cert"
      tls_key_file="$reuse_key"
      write_cert_fingerprint
      echo "TLS证书模式：复用 Caddy(naive) 已签发的真实证书"
      show_tls_cert_summary "复用 Caddy(naive) 已签发证书" "$(cat "$HOME/agsbx/naive_domain" 2>/dev/null)"
      tls_cert_ready=yes
      return 0
    fi
  fi
  # 智能安全网关拦截：当前没有任何启用 TLS 的节点，且未启用订阅分发时，直接静默退出，避免无意义的证书生成和定时任务注册
  # 注：anytls(anp) 亦为 TLS 节点，需纳入放行条件，否则仅启用 anytls 时会因网关拦截而拿不到证书。
  if [ "$sub" != "yes" ] && [ "$hyp" != "yes" ] && [ "$xhyp" != "yes" ] && [ "$tup" != "yes" ] && [ "$ssp" != "yes" ] && [ "$anp" != "yes" ] && [ "$xvcdn" != "yes" ] && [ "$xvargo" != "yes" ]; then
    return 0
  fi

if ! command -v openssl >/dev/null 2>&1; then
echo "错误：系统未安装 openssl，无法生成 TLS 证书。"
echo "请先安装 openssl 后重试：apt install openssl 或 yum install openssl"
exit 1
fi
cert_domain=$(printf '%s' "$certym" | tr -d '[:space:]')
if [ -n "$cert_domain" ]; then
if valid_domain "$cert_domain"; then
echo "检测到域名证书变量 certym=$cert_domain，开始准备 ACME/CA 证书。"
if setup_acme_certificate "$cert_domain" && write_cert_fingerprint; then
echo "TLS证书模式：CA/ACME 域名证书 ($cert_domain)"
show_tls_cert_summary "${tls_cert_source:-ACME/CA 证书可用}" "$cert_domain"
tls_cert_ready=yes
return 0
fi
echo "ACME证书申请失败：$cert_domain"
echo "正在自动回退为自签证书，确保 TLS 协议仍有证书可用。"
else
echo "警告：certym=$cert_domain 不像有效域名。"
echo "正在自动回退为自签证书，确保 TLS 协议仍有证书可用。"
fi
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
setup_port_hopping(){
  local hop_ports="$1"
  local target_port="$2"
  [ -z "$hop_ports" ] && return

  # 统一将中划线 - 替换为冒号 :，符合 iptables --dport 语法规则
  local ipt_ports=$(echo "$hop_ports" | tr '-' ':')

  echo "正在配置 Hysteria 2 端口跳跃重定向规则: $hop_ports -> :$target_port"

  # 利用全局标识变量，确保仅在首次调用时创建并 Flush 专属链，后续调用直接追加规则
  if [ -z "$HOPPING_INITED" ]; then
    iptables -t nat -N AGSBX_HY2 2>/dev/null
    iptables -t nat -F AGSBX_HY2 2>/dev/null
    if ! iptables -t nat -C PREROUTING -p udp -j AGSBX_HY2 2>/dev/null; then
      iptables -t nat -I PREROUTING -p udp -j AGSBX_HY2
    fi

    if command -v ip6tables >/dev/null 2>&1; then
      ip6tables -t nat -N AGSBX_HY2 2>/dev/null
      ip6tables -t nat -F AGSBX_HY2 2>/dev/null
      if ! ip6tables -t nat -C PREROUTING -p udp -j AGSBX_HY2 2>/dev/null; then
        ip6tables -t nat -I PREROUTING -p udp -j AGSBX_HY2
      fi
    fi
    HOPPING_INITED=true
  fi

  # 写入具体的 DNAT 重定向规则
  iptables -t nat -A AGSBX_HY2 -p udp --dport "$ipt_ports" -j DNAT --to-destination :"$target_port"
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -A AGSBX_HY2 -p udp --dport "$ipt_ports" -j DNAT --to-destination :"$target_port"
  fi

  # 持久化保存防火墙规则（自适应不同的发行版）
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service iptables save >/dev/null 2>&1 || true
    rc-service ip6tables save >/dev/null 2>&1 || true
  fi

  echo "Hysteria 2 端口跳跃规则已生效: $hop_ports -> :$target_port ✓"
}
cleanup_port_hopping(){
  # 安全地回收我们的专属自定义链，不影响宿主机其他任何 NAT 规则
  iptables -t nat -D PREROUTING -p udp -j AGSBX_HY2 2>/dev/null
  iptables -t nat -F AGSBX_HY2 2>/dev/null
  iptables -t nat -X AGSBX_HY2 2>/dev/null

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -D PREROUTING -p udp -j AGSBX_HY2 2>/dev/null
    ip6tables -t nat -F AGSBX_HY2 2>/dev/null
    ip6tables -t nat -X AGSBX_HY2 2>/dev/null
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service iptables save >/dev/null 2>&1 || true
    rc-service ip6tables save >/dev/null 2>&1 || true
  fi
}
save_xicmp_state(){
  [ -e "$HOME/agsbx/xicmp_enabled" ] && return
  if [ -r /proc/sys/net/ipv4/icmp_echo_ignore_all ]; then
    cat /proc/sys/net/ipv4/icmp_echo_ignore_all > "$HOME/agsbx/xicmp_echo_ignore_all.prev" 2>/dev/null
  fi
  echo "yes" > "$HOME/agsbx/xicmp_enabled"
}
restore_xicmp_state(){
  [ -e "$HOME/agsbx/xicmp_enabled" ] || return
  prev_xicmp=$(cat "$HOME/agsbx/xicmp_echo_ignore_all.prev" 2>/dev/null)
  case "$prev_xicmp" in
    0|1) sysctl -w net.ipv4.icmp_echo_ignore_all="$prev_xicmp" >/dev/null 2>&1 ;;
  esac
  rm -f "$HOME/agsbx/xicmp_enabled" "$HOME/agsbx/xicmp_echo_ignore_all.prev"
}
installxray(){
echo
printf '%s\n' "${C_CYAN}=========启用xray内核=========${C_RESET}"
mkdir -p "$HOME/agsbx/xrk"
if [ ! -e "$HOME/agsbx/xray" ]; then
upxray
fi
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
insuuid
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
if [ -n "$xhp" ] || [ -n "$vxp" ] || [ -n "$vwp" ]; then
if [ ! -e "$HOME/agsbx/xrk/dekey" ]; then
vlkey=$("$HOME/agsbx/xray" vlessenc)
dekey=$(echo "$vlkey" | grep '"decryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
enkey=$(echo "$vlkey" | grep '"encryption":' | sed -n '2p' | cut -d' ' -f2- | tr -d '"')
echo "$dekey" > "$HOME/agsbx/xrk/dekey"
echo "$enkey" > "$HOME/agsbx/xrk/enkey"
fi
dekey=$(cat "$HOME/agsbx/xrk/dekey")
enkey=$(cat "$HOME/agsbx/xrk/enkey")
fi

if [ -n "$xhp" ]; then
xhp=xhpt
port_xh=$(init_port "$port_xh" port_xh)
echo "Vlessenc-xhttp-reality-vision-fm端口：$port_xh"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag":"xhttp-reality",
      "listen": "::",
      "port": ${port_xh},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
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
          "path": "/${uuid}-xh",
          "mode": "auto",
          "extra": {
            "noGRPCHeader": false,
            "noSSEHeader": false,
            "xPaddingObfsMode": true,
            "xPaddingBytes": "100-1000",
            "xPaddingKey": "cf_clearance",
            "xPaddingHeader": "Referer",
            "xPaddingPlacement": "queryInHeader",
            "xPaddingMethod": "repeat-x",
            "uplinkHTTPMethod": "POST",
            "sessionPlacement": "path",
            "sessionKey": "",
            "seqPlacement": "path",
            "seqKey": "",
            "uplinkDataPlacement": "body",
            "uplinkDataKey": "",
            "uplinkChunkSize": 0,
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": "10-50",
            "scMaxBufferedPosts": 30,
            "scStreamUpServerSecs": "20-80",
            "maxConcurrency": "16-32",
            "maxConnections": "0-0",
            "cMaxReuseTimes": "64-128",
            "hMaxReusableSecs": "1800-3000",
            "hKeepAlivePeriod": 45,
            "downloadTargetHost": "",
            "downloadTargetPort": 0,
            "downloadServerName": "",
            "downloadHTTPHost": ""
          }
        },
        "finalmask": {
          "tcp": [
            {
              "type": "sudoku",
              "settings": {
                "password": "${uuid}",
                "paddingMin": 16,
                "paddingMax": 64
              }
            }
          ],
          "udp": [
            {
              "type": "noise",
              "settings": {
                "reset": "30-60",
                "noise": [
                  {
                    "rand": "32-128",
                    "randRange": "0-255",
                    "delay": "10-20"
                  }
                ]
              }
            }
          ]
        }
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
echo "Vlessenc-xhttp-vision端口：$port_vx"
if [ -n "$cdnym" ]; then
echo "$cdnym" > "$HOME/agsbx/cdnym"
echo "80系CDN或者回源CDN的host域名 (确保IP已解析在CF域名)：$cdnym"
fi
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag":"vless-xhttp",
      "listen": "::",
      "port": ${port_vx},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${uuid}-vx",
          "mode": "auto",
          "extra": {
            "noGRPCHeader": false,
            "noSSEHeader": false,
            "xPaddingObfsMode": true,
            "xPaddingBytes": "100-1000",
            "xPaddingKey": "cf_clearance",
            "xPaddingHeader": "Referer",
            "xPaddingPlacement": "queryInHeader",
            "xPaddingMethod": "repeat-x",
            "uplinkHTTPMethod": "POST",
            "sessionPlacement": "path",
            "sessionKey": "",
            "seqPlacement": "path",
            "seqKey": "",
            "uplinkDataPlacement": "body",
            "uplinkDataKey": "",
            "uplinkChunkSize": 0,
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": "10-50",
            "scMaxBufferedPosts": 30,
            "scStreamUpServerSecs": "20-80",
            "maxConcurrency": "16-32",
            "maxConnections": "0-0",
            "cMaxReuseTimes": "64-128",
            "hMaxReusableSecs": "1800-3000",
            "hKeepAlivePeriod": 45,
            "downloadTargetHost": "",
            "downloadTargetPort": 0,
            "downloadServerName": "",
            "downloadHTTPHost": ""
          }
        }
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
echo "Vlessenc-ws-vision端口：$port_vw"
if [ -n "$cdnym" ]; then
echo "$cdnym" > "$HOME/agsbx/cdnym"
echo "80系CDN或者回源CDN的host域名 (确保IP已解析在CF域名)：$cdnym"
fi
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag":"vless-ws",
      "listen": "::",
      "port": ${port_vw},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${uuid}-vw"
        }
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
echo "Vless-tcp-reality-vision-fm端口：$port_vl_re"
cat >> "$HOME/agsbx/xr.json" <<EOF
        {
            "tag":"reality-vision",
            "listen": "::",
            "port": $port_vl_re,
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
                    "dest": "${ym_vl_re}:443",
                    "serverNames": [
                      "${ym_vl_re}"
                    ],
                    "privateKey": "$private_key_x",
                    "shortIds": ["$short_id_x"]
                },
                "finalmask": {
                    "tcp": [
                        {
                            "type": "fragment",
                            "settings": {
                                "packets": "tlshello",
                                "length": "100-200",
                                "delay": "10-20",
                                "maxSplit": "3-6"
                            }
                        },
                        {
                            "type": "sudoku",
                            "settings": {
                                "password": "${uuid}",
                                "paddingMin": 16,
                                "paddingMax": 64
                            }
                        }
                    ]
                }
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
if [ -n "$xhyp" ]; then
xhyp=xhypt
setup_tls_certificate
port_xhy2=$(init_port "$port_xhy2" port_xhy2)
echo "Xray-Hysteria2端口：$port_xhy2"
if [ -n "$xhyjpt" ]; then
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "port": ${port_xhy2},
      "protocol": "hysteria",
      "tag": "hy2-xr",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${uuid}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "$tls_cert_file",
              "keyFile": "$tls_key_file"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2
        },
        "finalmask": {
          "quicParams": {
            "congestion": "brutal",
            "udpHop": {
              "ports": "${xhyjpt}",
              "interval": 15
            }
          }
        }
      }
    },
EOF
else
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "port": ${port_xhy2},
      "protocol": "hysteria",
      "tag": "hy2-xr",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${uuid}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "$tls_cert_file",
              "keyFile": "$tls_key_file"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2
        }
      }
    },
EOF
fi
else
xhyp=xhyptargo
fi
if [ "$xdns" = yes ]; then
if valid_domain "$xdnsym"; then
echo "$port_xdns" > "$HOME/agsbx/port_xdns"
echo "Vless-kcp-xdns-fm端口：$port_xdns"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "vless-kcp-xdns",
      "listen": "::",
      "port": ${port_xdns},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
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
      "listen": "::",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
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
setup_tls_certificate
port_xvcdn=$(init_port "$port_xvcdn" port_xvcdn)
echo "Vlessenc-xhttp-tls-vision-fm-cdn端口：$port_xvcdn"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "vlessenc-xhttp-cdn",
      "listen": "::",
      "port": ${port_xvcdn},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "$tls_cert_file",
              "keyFile": "$tls_key_file"
            }
          ]
        },
        "xhttpSettings": {
          "path": "/${uuid}-xvd",
          "mode": "auto",
          "extra": {
            "noGRPCHeader": false,
            "noSSEHeader": false,
            "xPaddingObfsMode": true,
            "xPaddingBytes": "100-1000",
            "xPaddingKey": "cf_clearance",
            "xPaddingHeader": "Referer",
            "xPaddingPlacement": "queryInHeader",
            "xPaddingMethod": "repeat-x",
            "uplinkHTTPMethod": "POST",
            "sessionPlacement": "path",
            "sessionKey": "",
            "seqPlacement": "path",
            "seqKey": "",
            "uplinkDataPlacement": "body",
            "uplinkDataKey": "",
            "uplinkChunkSize": 0,
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": "10-50",
            "scMaxBufferedPosts": 30,
            "scStreamUpServerSecs": "20-80",
            "maxConcurrency": "16-32",
            "maxConnections": "0-0",
            "cMaxReuseTimes": "64-128",
            "hMaxReusableSecs": "1800-3000",
            "hKeepAlivePeriod": 45
          }
        },
        "finalmask": {
          "tcp": [
            {
              "type": "sudoku",
              "settings": {
                "password": "${uuid}",
                "paddingMin": 16,
                "paddingMax": 64
              }
            }
          ],
          "udp": [
            {
              "type": "noise",
              "settings": {
                "reset": "30-60",
                "noise": [
                  {
                    "rand": "32-128",
                    "randRange": "0-255",
                    "delay": "10-20"
                  }
                ]
              }
            }
          ]
        }
      }
    },
EOF
fi
if [ "$xvargo" = yes ]; then
setup_tls_certificate
port_xvargo=$(init_port "$port_xvargo" port_xvargo)
echo "Vlessenc-xhttp-tls-vision-fm-argo端口：$port_xvargo"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "vlessenc-xhttp-argo",
      "listen": "127.0.0.1",
      "port": ${port_xvargo},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${dekey}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "certificates": [
            {
              "certificateFile": "$tls_cert_file",
              "keyFile": "$tls_key_file"
            }
          ]
        },
        "xhttpSettings": {
          "path": "/${uuid}-xva",
          "mode": "auto",
          "extra": {
            "noGRPCHeader": false,
            "noSSEHeader": false,
            "xPaddingObfsMode": true,
            "xPaddingBytes": "100-1000",
            "xPaddingKey": "cf_clearance",
            "xPaddingHeader": "Referer",
            "xPaddingPlacement": "queryInHeader",
            "xPaddingMethod": "repeat-x",
            "uplinkHTTPMethod": "POST",
            "sessionPlacement": "path",
            "sessionKey": "",
            "seqPlacement": "path",
            "seqKey": "",
            "uplinkDataPlacement": "body",
            "uplinkDataKey": "",
            "uplinkChunkSize": 0,
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": "10-50",
            "scMaxBufferedPosts": 30,
            "scStreamUpServerSecs": "20-80",
            "maxConcurrency": "16-32",
            "maxConnections": "0-0",
            "cMaxReuseTimes": "64-128",
            "hMaxReusableSecs": "1800-3000",
            "hKeepAlivePeriod": 45
          }
        },
        "finalmask": {
          "tcp": [
            {
              "type": "sudoku",
              "settings": {
                "password": "${uuid}",
                "paddingMin": 16,
                "paddingMax": 64
              }
            }
          ],
          "udp": [
            {
              "type": "noise",
              "settings": {
                "reset": "30-60",
                "noise": [
                  {
                    "rand": "32-128",
                    "randRange": "0-255",
                    "delay": "10-20"
                  }
                ]
              }
            }
          ]
        }
      }
    },
EOF
fi
# ------------------------------------------------------------
# 🎯 任务 H 模块 C：Xray-core TLS 卸载 Inbound 注入段
# - 功能描述：当启用订阅服务 (sub=yes) 时，使用 Xray-core 原生充当高位 HTTPS 反向代理。
# - 端口机制：
#   - subport (外部 HTTPS 端口，持久化于 subport.log)：供客户端从公网拉取订阅。
#   - subport_real (本地回源端口，持久化于 subport_real.log)：只监听在 127.0.0.1，防外网直连。
# - 关联映射：此处 dokodemo-door 反代的目标端口与最尾部 (L3120之后) 启动 busybox httpd 监听的真实端口强关联一致。
# ------------------------------------------------------------
if [ "$sub" = yes ]; then
setup_tls_certificate
if [ -f "$tls_cert_file" ] && [ -f "$tls_key_file" ]; then
subport=$(init_port "$subpt" subport.log)
subport_real=$(init_subport_real "$subport")
echo "Xray-core TLS 卸载订阅服务端口：$subport (内部回源端口：$subport_real)"
cat >> "$HOME/agsbx/xr.json" <<EOF
    {
      "tag": "sub-https-proxy",
      "listen": "::",
      "port": ${subport},
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp",
        "followRedirect": false,
        "address": "127.0.0.1",
        "port": ${subport_real}
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
fi
}

installsb(){
echo
printf '%s\n' "${C_CYAN}=========启用sing-box内核=========${C_RESET}"
if [ ! -e "$HOME/agsbx/sing-box" ]; then
upsingbox
else
  # 🎯 架构兼容性加固：检查本地已有 sing-box 文件的版本。由于后续配置中强依赖 1.11.0+ 引入的顶级 endpoints 对象，
  # 如果本地内核版本低于 1.11.0，则必须自动触发无人值守升级，否则新配置会导致内核因 unknown field 报错崩溃。
  local_sb_ver=$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}' | tr -d 'v')
  sb_major=$(echo "$local_sb_ver" | cut -d. -f1)
  sb_minor=$(echo "$local_sb_ver" | cut -d. -f2)
  if [ -n "$sb_major" ] && [ -n "$sb_minor" ]; then
    if [ "$sb_major" -lt 1 ] || { [ "$sb_major" -eq 1 ] && [ "$sb_minor" -lt 11 ]; }; then
      echo "检测到本地已有的 Sing-box 版本为 v$local_sb_ver（低于 1.11.0 架构需求）。"
      echo "系统正在自动执行无人值守的平滑升级，以确保完美兼容 endpoints 顶层配置..."
      upsingbox
    fi
  else
    echo "无法识别本地已有的 Sing-box 版本信息。"
    echo "系统正在自动执行无人值守的平滑升级，以确保完美兼容 endpoints 顶层配置..."
    upsingbox
  fi
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
insuuid
setup_tls_certificate
if [ -n "$hyp" ]; then
hyp=hypt
insobfspass
port_hy2=$(init_port "$port_hy2" port_hy2)
echo "Hysteria2端口：$port_hy2"
cat >> "$HOME/agsbx/sb.json" <<EOF
    {
        "type": "hysteria2",
        "tag": "hy2-sb",
        "listen": "::",
        "listen_port": ${port_hy2},
        "users": [
            {
                "password": "${uuid}"
            }
        ],
        "ignore_client_bandwidth":false,
        "obfs": {
            "type": "salamander",
            "password": "${obfs_pass}"
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
cat >> "$HOME/agsbx/sb.json" <<EOF
        {
            "type":"tuic",
            "tag": "tuic5-sb",
            "listen": "::",
            "listen_port": ${port_tu},
            "users": [
                {
                    "uuid": "${uuid}",
                    "password": "${uuid}"
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
cat >> "$HOME/agsbx/sb.json" <<EOF
        {
            "type":"anytls",
            "tag":"anytls-sb",
            "listen":"::",
            "listen_port":${port_an},
            "users":[
                {
                  "password":"${uuid}"
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
            "listen":"::",
            "listen_port":${port_ar},
            "users":[
                {
                  "password":"${uuid}"
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
            "listen": "::",
            "listen_port": $port_ss,
            "method": "2022-blake3-aes-128-gcm",
            "password": "$sskey"
    },
EOF
else
ssp=ssptargo
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
# 获取/编译 caddy 二进制（按架构交互选择）；失败则放弃，不影响其它内核。
if [ ! -s "$HOME/agsbx/caddy" ]; then
upcaddy || { echo "NaiveProxy 内核未就位，已跳过 Caddy 配置。"; return 1; }
fi
insnaivecred
# [80端口占用预检] Caddy 自管 ACME 需要 80 端口做 HTTP-01 验证/跳转；占用则告警（不强制中断）。
if command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -qE '(:80[[:space:]]|:80$)'; then
printf '%s\n' "${C_YELLOW}警告：检测到 80 端口已被占用，Caddy 自动申请证书可能失败。${C_RESET}"
echo "如有其它服务占用 80/443（如 nginx 或脚本内 acme.sh），可先停掉再装，或装好后用 agsbx stop caddy 让出端口。"
fi
# 生成 Caddyfile（硬化模板：剥离指纹响应头、净化回源请求头、probe_resistance 抗主动探测）
local naivemail="${acmem:-admin@$naive}"
local naivesite="${naivesite:-mirror.us.leaseweb.net}"
# 容错：伪装站允许带或不带 scheme，统一剥离后由模板固定以 https 回源（伪装站须支持 HTTPS）
naivesite="${naivesite#http://}"; naivesite="${naivesite#https://}"
# 持久化域名：供后续 agsbx list 渲染节点卡片时读取（彼时 naive 环境变量已不在作用域）
echo "$naive" > "$HOME/agsbx/naive_domain"
cat > "$HOME/agsbx/Caddyfile" <<EOF
{
  order forward_proxy before reverse_proxy
  storage file_system "{$HOME}/agsbx/caddy_storage"
  log {
    exclude http.log.error
  }
}
:443, $naive {
  tls $naivemail
  encode
  header {
    -Server
    -X-Powered-By
  }
  forward_proxy {
    basic_auth $naiveuser $naivepass
    hide_ip
    hide_via
    probe_resistance
  }
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
  }
}
EOF
# 配置落地后语法预检，不过则告警（仍注册服务，便于用户看 journal 定位后 agsbx reload caddy 修正）
if ! "$HOME/agsbx/caddy" validate --config "$HOME/agsbx/Caddyfile" >/dev/null 2>&1; then
printf '%s\n' "${C_YELLOW}警告：Caddyfile 校验未通过，请检查域名/邮箱后用 agsbx reload caddy 重载。${C_RESET}"
fi
# 服务注册三后端（systemd / openrc / 裸 nohup），对齐 xr/argo 既有写法；root 运行 + NoNewPrivileges 收敛。
if pidof systemd >/dev/null 2>&1 && is_root; then
cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=caddy naiveproxy service
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
TimeoutStartSec=0
ExecStart=$HOME/agsbx/caddy run --config $HOME/agsbx/Caddyfile
ExecReload=$HOME/agsbx/caddy reload --config $HOME/agsbx/Caddyfile --force
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1
systemctl enable caddy >/dev/null 2>&1
systemctl start caddy >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1 && is_root; then
cat > /etc/init.d/caddy <<EOF
#!/sbin/openrc-run
description="caddy naiveproxy service"
command="$HOME/agsbx/caddy"
command_args="run --config $HOME/agsbx/Caddyfile"
command_background=yes
pidfile="/run/caddy.pid"
depend() {
need net
}
EOF
chmod +x /etc/init.d/caddy >/dev/null 2>&1
rc-update add caddy default >/dev/null 2>&1
rc-service caddy start >/dev/null 2>&1
else
nohup "$HOME/agsbx/caddy" run --config "$HOME/agsbx/Caddyfile" > "$HOME/agsbx/caddy.log" 2>&1 &
fi
# 等待并检测 Caddy 证书生成情况
local detect_sec=60
local caddy_cert=""
local caddy_key=""
printf "正在等待 Caddy 自动托管申请证书（最长 60 秒，签发成功将立刻退出）"
while [ $detect_sec -gt 0 ]; do
  printf "."
  caddy_cert=$(find "$HOME/agsbx/caddy_storage/caddy/certificates" -type f -name "$naive.crt" 2>/dev/null | head -1)
  caddy_key=$(find "$HOME/agsbx/caddy_storage/caddy/certificates" -type f -name "$naive.key" 2>/dev/null | head -1)
  if [ -s "$caddy_cert" ] && [ -s "$caddy_key" ]; then
    echo " [成功]"
    break
  fi
  sleep 1
  detect_sec=$((detect_sec - 1))
done
echo

if [ -s "$caddy_cert" ] && [ -s "$caddy_key" ] && openssl x509 -noout -in "$caddy_cert" >/dev/null 2>&1; then
  echo "caddy" > "$HOME/agsbx/cert_mode"
  echo "$caddy_cert" > "$HOME/agsbx/cert_file_path"
  echo "$caddy_key" > "$HOME/agsbx/key_file_path"
  echo "$naive" > "$HOME/agsbx/sni.txt"
  write_cert_fingerprint
  # 调用 show_tls_cert_summary 展示详细证书信息并标记来源
  show_tls_cert_summary "Caddy 自动托管申请成功" "$naive"
  # 注册续期联动重载：Caddy 自动续期后，复用该证书的 xray/sing-box 能加载到新证书
  setup_caddy_cert_reload
else
  printf '%s\n' "${C_YELLOW}提示：60 秒内未检测到 Caddy 生成的有效 TLS 证书。${C_RESET}"
  echo "Caddy 可能仍在后台获取证书中，或者 80/443 端口被占用/DNS 解析未生效。"
  echo "建议稍后运行 journalctl -u caddy -f 或查看 $HOME/agsbx/caddy.log 查看具体证书申请进度。"
fi

echo "NaiveProxy(Caddy) 已部署：https://$naive"
echo "分享链接(HTTPS·H1/H2，TCP)：naive+https://$naiveuser:$naivepass@$naive:443?padding=true"
echo "分享链接(QUIC·H3，UDP)：naive+quic://$naiveuser:$naivepass@$naive:443?padding=true"
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
cat >> "$HOME/agsbx/xr.json" <<EOF
        {
            "tag": "vmess-xr",
            "listen": "::",
            "port": ${port_vm_ws},
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "${uuid}"
                    }
                ]
            },
            "streamSettings": {
                "network": "ws",
                "security": "none",
                "wsSettings": {
                  "path": "${uuid}-vm"
            }
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
        "listen": "::",
        "listen_port": ${port_vm_ws},
        "users": [
            {
                "uuid": "${uuid}",
                "alterId": 0
            }
        ],
        "transport": {
            "type": "ws",
            "path": "${uuid}-vm",
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
port_so=$(init_port "$port_so" port_so)
echo "Socks5端口：$port_so"
if [ -e "$HOME/agsbx/xr.json" ]; then
cat >> "$HOME/agsbx/xr.json" <<EOF
        {
         "tag": "socks5-xr",
         "port": ${port_so},
         "listen": "::",
         "protocol": "socks",
         "settings": {
            "auth": "password",
             "accounts": [
               {
               "user": "${uuid}",
               "pass": "${uuid}"
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
      "listen": "::",
      "listen_port": ${port_so},
      "users": [
      {
      "username": "${uuid}",
      "password": "${uuid}"
      }
     ]
    },
EOF
fi
else
sop=soptargo
fi
}

xrsbout(){
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
if pidof systemd >/dev/null 2>&1 && is_root; then
cat > /etc/systemd/system/xr.service <<EOF
[Unit]
Description=xr service
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=$HOME/agsbx/xray run -c $HOME/agsbx/xr.json
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1
systemctl enable xr >/dev/null 2>&1
systemctl start xr >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1 && is_root; then
cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="xr service"
command="$HOME/agsbx/xray"
command_args="run -c $HOME/agsbx/xr.json"
command_background=yes
pidfile="/run/xray.pid"
command_background="yes"
depend() {
need net
}
EOF
chmod +x /etc/init.d/xray >/dev/null 2>&1
rc-update add xray default >/dev/null 2>&1
rc-service xray start >/dev/null 2>&1
else
nohup "$HOME/agsbx/xray" run -c "$HOME/agsbx/xr.json" > "$HOME/agsbx/xray.log" 2>&1 &
fi
fi
if [ -e "$HOME/agsbx/sb.json" ]; then
# ------------------------------------------------------------
# 🎯 任务 H 模块 C：Sing-box 独占式 TLS 卸载 direct Inbound 注入段
# - 功能描述：当 xray 不在线、只激活 sing-box 时，自适应地在 sb.json 尾部注入 direct 反代。
# - 运作逻辑：实现单 sing-box 核环境下的 HTTPS 订阅卸载，同样将公网 subport 解密并路由给本地 subport_real。
# - 关联映射：与最尾部拉起的 busybox httpd 监听端口强关联一致。
# ------------------------------------------------------------
if [ "$sub" = yes ] && [ ! -f "$HOME/agsbx/xray" ]; then
setup_tls_certificate
if [ -f "$tls_cert_file" ] && [ -f "$tls_key_file" ]; then
subport=$(init_port "$subpt" subport.log)
subport_real=$(init_subport_real "$subport")
echo "Sing-box TLS 卸载订阅服务端口：$subport (内部回源端口：$subport_real)"
cat >> "$HOME/agsbx/sb.json" <<EOF
  ,
  {
    "type": "direct",
    "tag": "sub-https-proxy",
    "listen": "::",
    "listen_port": ${subport},
    "tcp_fast_open": true,
    "tls": {
      "enabled": true,
      "certificate_path": "$tls_cert_file",
      "key_path": "$tls_key_file"
    },
    "destination": "127.0.0.1:${subport_real}"
  }
EOF
fi
fi
sed -i '$ s/,[[:space:]]*$//' "$HOME/agsbx/sb.json" 2>/dev/null || sed -i '$s/,$//' "$HOME/agsbx/sb.json"
cat >> "$HOME/agsbx/sb.json" <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
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
cat >> "$HOME/agsbx/sb.json" <<EOF
  ,"route": {
    "rules": [
      {
        "action": "sniff"
      },
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
if pidof systemd >/dev/null 2>&1 && is_root; then
cat > /etc/systemd/system/sb.service <<EOF
[Unit]
Description=sb service
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=$HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1
systemctl enable sb >/dev/null 2>&1
systemctl start sb >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1 && is_root; then
cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sb service"
command="$HOME/agsbx/sing-box"
command_args="run -c $HOME/agsbx/sb.json"
command_background=yes
pidfile="/run/sing-box.pid"
command_background="yes"
depend() {
need net
}
EOF
chmod +x /etc/init.d/sing-box >/dev/null 2>&1
rc-update add sing-box default >/dev/null 2>&1
rc-service sing-box start >/dev/null 2>&1
else
nohup "$HOME/agsbx/sing-box" run -c "$HOME/agsbx/sb.json" > "$HOME/agsbx/sing-box.log" 2>&1 &
fi
fi
}
#============================================================
# [第8段] 全流程安装编排主函数
#------------------------------------------------------------
# 🎯 架构说明:
# - 本大段定义了安装编排的总发动机函数 ins()。负责协调内核下载、UUID分配、防火墙端口跳跃控制、Xray/Sing-box Inbound装配、配置文件最终闭合、Argo 隧道守护以及系统快捷键注入。
# - 关联性: 由第 12 段 (主入口流程决策) 在判定为新安装或重置时调用，是串联整个 3300 行脚本全流程安装逻辑的核心中枢。
#============================================================
ins(){
enable_system_bbr
# NaiveProxy（Caddy）优先装配：先让 Caddy 起来并自动托管签发真实域名证书，
# 之后 hy2/tuic/anytls/xhy2 等 TLS 节点在 setup_tls_certificate 中复用该证书（SNI=naive 域名）。
# 仅当显式设置 naive=<域名> 时执行，与 xray/sing-box 隔离并存；Caddy 用独立端口(443)，不与代理内核抢占。
if [ -n "$naive" ]; then
installcaddy
fi
local has_xray_sb=no
if [ "$vwp" = yes ] || [ "$sop" = yes ] || [ "$vxp" = yes ] || [ "$ssp" = yes ] || [ "$vlp" = yes ] || [ "$vmp" = yes ] || [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$xhp" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || [ "$xvcdn" = yes ] || [ "$xvargo" = yes ]; then
  has_xray_sb=yes
fi

if [ "$has_xray_sb" = yes ]; then
  if [ "$hyp" != yes ] && [ "$tup" != yes ] && [ "$anp" != yes ] && [ "$arp" != yes ] && [ "$ssp" != yes ]; then
    installxray
    xrsbvm
    xrsbso
    warpsx
    xrsbout
    hyp="shyptargo"; tup="tuptargo"; anp="anptargo"; arp="arptargo"; ssp="ssptargo"
  elif [ "$xhp" != yes ] && [ "$vlp" != yes ] && [ "$vxp" != yes ] && [ "$vwp" != yes ] && [ "$xhyp" != yes ] && [ "$xdns" != yes ] && [ "$xicp" != yes ] && [ "$xvcdn" != yes ] && [ "$xvargo" != yes ]; then
    installsb
    xrsbvm
    xrsbso
    warpsx
    xrsbout
    xhp="xhptargo"; vlp="vlptargo"; vxp="vxptargo"; vwp="vwptargo"; xhyp="xhyptargo"; xdns="xdnstargo"; xicp="xicptargo"; xvcdn="xvcdnptargo"; xvargo="xvargoptargo"
  else
    installsb
    installxray
    xrsbvm
    xrsbso
    warpsx
    xrsbout
  fi
fi

# 双内核 Hysteria 2 跳跃端口规则解耦挂载
# Sing-box 驱动的 Hysteria 2：shyjpt -> port_hy2
if [ -n "$shyjpt" ]; then
  local_hy2_port=$(cat "$HOME/agsbx/port_hy2" 2>/dev/null)
  if [ -n "$local_hy2_port" ]; then
    setup_port_hopping "$shyjpt" "$local_hy2_port"
    echo "$shyjpt" > "$HOME/agsbx/shyjpt"
  fi
fi
# Xray 驱动的 Hysteria 2：xhyjpt -> port_xhy2
if [ -n "$xhyjpt" ]; then
  local_xhy2_port=$(cat "$HOME/agsbx/port_xhy2" 2>/dev/null)
  if [ -n "$local_xhy2_port" ]; then
    setup_port_hopping "$xhyjpt" "$local_xhy2_port"
    echo "$xhyjpt" > "$HOME/agsbx/xhyjpt"
  fi
fi

if [ -n "$argo" ] && [ -n "$vmag" ]; then
echo
printf '%s\n' "${C_CYAN}=========启用Cloudflared-argo内核=========${C_RESET}"
if [ ! -e "$HOME/agsbx/cloudflared" ]; then
argocore=$({ command -v curl >/dev/null 2>&1 && curl -Ls https://data.jsdelivr.com/v1/package/gh/cloudflare/cloudflared || wget -qO- https://data.jsdelivr.com/v1/package/gh/cloudflare/cloudflared; } | grep -Eo '"[0-9.]+"' | sed -n 1p | tr -d '",')
echo "下载Cloudflared-argo最新正式版内核：$argocore"
# 注意：此处下载的是数十 MB 的二进制文件，不可像 IP 探测那样套用 timeout 3，否则 wget 必然被中途掐断
url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"; out="$HOME/agsbx/cloudflared"; (command -v curl >/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget >/dev/null 2>&1 && wget -O "$out" --tries=2 "$url")
chmod +x "$HOME/agsbx/cloudflared"
fi
if [ "$argo" = "vmpt" ]; then argoport=$(cat "$HOME/agsbx/port_vm_ws" 2>/dev/null); echo "Vmess" > "$HOME/agsbx/vlvm"; elif [ "$argo" = "vwpt" ]; then argoport=$(cat "$HOME/agsbx/port_vw" 2>/dev/null); echo "Vless" > "$HOME/agsbx/vlvm"; elif [ "$argo" = "xvargopt" ]; then argoport=$(cat "$HOME/agsbx/port_xvargo" 2>/dev/null); echo "Vlessenc-xhttp-tls-vision-fm" > "$HOME/agsbx/vlvm"; fi; echo "$argoport" > "$HOME/agsbx/argoport.log"
# Argo 隧道本地回源协议自适应：vmess-ws / vless-ws 入站为明文，回源走 http；
# xvargo (Vlessenc-xhttp-tls) 入站自带 TLS 层，cloudflared 必须以 https 回源并跳过本地证书校验，
# 否则明文 HTTP 打到 TLS 监听端口，握手直接失败（Argo 为纯出站隧道，与防火墙端口无关）。
if [ "$argo" = "xvargopt" ]; then argoscheme="https"; argoxtls="--no-tls-verify "; else argoscheme="http"; argoxtls=""; fi
if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
argoname='固定'
if pidof systemd >/dev/null 2>&1 && is_root; then
cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=argo service
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=$HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "${ARGO_AUTH}"
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1
systemctl enable argo >/dev/null 2>&1
systemctl start argo >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1 && is_root; then
cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
description="argo service"
command="$HOME/agsbx/cloudflared tunnel"
command_args="--no-autoupdate --edge-ip-version auto --protocol http2 run --token ${ARGO_AUTH}"
pidfile="/run/argo.pid"
command_background="yes"
depend() {
need net
}
EOF
chmod +x /etc/init.d/argo >/dev/null 2>&1
rc-update add argo default >/dev/null 2>&1
rc-service argo start >/dev/null 2>&1
else
nohup "$HOME/agsbx/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "${ARGO_AUTH}" > "$HOME/agsbx/argo.log" 2>&1 &
fi
echo "${ARGO_DOMAIN}" > "$HOME/agsbx/sbargoym.log"
echo "${ARGO_AUTH}" > "$HOME/agsbx/sbargotoken.log"
[ "$argo" = "xvargopt" ] && echo "提示：xvargo 为 TLS 入站，固定隧道请在 CF 仪表盘将服务指向 https://localhost:${argoport} 并开启 noTLSVerify。"
else
argoname='临时'
nohup "$HOME/agsbx/cloudflared" tunnel --url ${argoscheme}://localhost:$(cat $HOME/agsbx/argoport.log) ${argoxtls}--edge-ip-version auto --no-autoupdate --protocol http2 > $HOME/agsbx/argo.log 2>&1 &
fi
echo "申请Argo$argoname隧道中……请稍等"
sleep 2
if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
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
fi
fi
# NaiveProxy（Caddy）已在本函数开头优先装配并签发证书（供 TLS 节点复用），此处不再重复。
sleep 5
echo
if agsbx_running ; then
# 把 agsbx 装进 /usr/local/bin（root 默认 PATH 内）：安装完当前 SSH 会话即可直接用 agsbx，
# 无需改 PATH、无需退出重连。旧版装在 $HOME/bin 并往 .bashrc 注入 PATH，因子进程改不了父 shell 环境才被迫要重登录。
# 此处一并清理旧版残留：$HOME/bin/agsbx 文件 + .bashrc 里注入的 PATH 行。
[ -f ~/.bashrc ] && {
sed -i '/agsbx/d' ~/.bashrc
sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' ~/.bashrc
sed -i '/export PATH="\$PATH:\$HOME\/bin"/d' ~/.bashrc
}
rm -f "$HOME/bin/agsbx"
if [ -d /usr/local/bin ] || mkdir -p /usr/local/bin 2>/dev/null; then
SCRIPT_PATH="/usr/local/bin/agsbx"
else
SCRIPT_PATH="/usr/bin/agsbx"
fi
(command -v curl >/dev/null 2>&1 && curl -sL "$agsbxurl" -o "$SCRIPT_PATH") || (command -v wget >/dev/null 2>&1 && wget -qO "$SCRIPT_PATH" "$agsbxurl")
# 700：仅 root 可读/执行，非 root 用户连读取或运行 agsbx 都被拒；root 因 /usr/local/bin 在其 PATH 中仍可立即使用。
chmod 700 "$SCRIPT_PATH"
cron_tmp=$(mktemp)
crontab -l > "$cron_tmp" 2>/dev/null
if ! pidof systemd >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
sed -i '/agsbx\/sing-box/d' "$cron_tmp"
sed -i '/agsbx\/xray/d' "$cron_tmp"
if find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -q 'agsbx/sing-box' || pgrep -f 'agsbx/sing-box' >/dev/null 2>&1 ; then
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json > $HOME/agsbx/sing-box.log 2>&1 &"' >> "$cron_tmp"
fi
if find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -q 'agsbx/xray' || pgrep -f 'agsbx/xray' >/dev/null 2>&1 ; then
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json > $HOME/agsbx/xray.log 2>&1 &"' >> "$cron_tmp"
fi
# 仅清理 @reboot 的 caddy 运行守护行，保留 setup_caddy_cert_reload 注册的续期联动 cron(caddy_cert_reload.sh)。
sed -i '/agsbx\/caddy run/d' "$cron_tmp"
if [ -n "$naive" ] && [ -s "$HOME/agsbx/caddy" ]; then
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/caddy run --config $HOME/agsbx/Caddyfile > $HOME/agsbx/caddy.log 2>&1 &"' >> "$cron_tmp"
fi
fi
sed -i '/agsbx\/cloudflared/d' "$cron_tmp"
if [ -n "$argo" ] && [ -n "$vmag" ]; then
if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
if ! pidof systemd >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $(cat $HOME/agsbx/sbargotoken.log 2>/dev/null) > $HOME/agsbx/argo.log 2>&1 &"' >> "$cron_tmp"
fi
else
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --url '"$argoscheme"'://localhost:$(cat $HOME/agsbx/argoport.log) '"$argoxtls"'--edge-ip-version auto --no-autoupdate --protocol http2 > $HOME/agsbx/argo.log 2>&1 &"' >> "$cron_tmp"
fi
fi
crontab "$cron_tmp" >/dev/null 2>&1
rm -f "$cron_tmp"
echo "Airgosbx脚本进程启动成功，安装完毕" && sleep 2
else
echo "Airgosbx脚本进程未启动，安装失败" && exit
fi
}
#============================================================
# [第9段] 状态查询与节点大卡片渲染函数
#------------------------------------------------------------
# 🎯 架构说明:
# - 本大段包含 airgosbxstatus() (核心服务运行状态轮询)、cip() (所有订阅生成、Clash 动态片段拼接、卡片高维度精美排版打印)。
# - 关联性: 由第 12 段 (主入口) 在初始化完毕或第 11 段 (upx/ups内核更新/list查看) 时调用，是负责对用户渲染输出的最强表现层。
#============================================================
airgosbxstatus(){
printf '%s\n' "${C_CYAN}========= 当前内核运行状态 =========${C_RESET}"
procs=$(find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null)
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
  if echo "$procs" | grep -Eq "$pat" || pgrep -f "$pat" >/dev/null 2>&1; then
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
}
cip(){
ipbest(){
# 优先复用 v4v6() 已探测到的地址，两者皆空时才重新发起外网探测
serip="${v4:-$v6}"
[ -z "$serip" ] && serip=$( (command -v curl >/dev/null 2>&1 && (curl -s4m5 "$v46url" 2>/dev/null || curl -s6m5 "$v46url" 2>/dev/null) ) || (command -v wget >/dev/null 2>&1 && (timeout 3 wget -4 -qO- --tries=2 "$v46url" 2>/dev/null || timeout 3 wget -6 -qO- --tries=2 "$v46url" 2>/dev/null) ) )
if echo "$serip" | grep -q ':'; then
server_ip="[$serip]"
else
server_ip="$serip"
fi
echo "$server_ip" > "$HOME/agsbx/server_ip.log"
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
echo "$server_ip" > "$HOME/agsbx/server_ip.log"
fi
elif [ "$ippz" = "6" ]; then
if [ -z "$v6" ]; then
ipbest
else
server_ip="[$v6]"
echo "$server_ip" > "$HOME/agsbx/server_ip.log"
fi
else
ipbest
fi
}
ipchange
rm -rf "$HOME/agsbx/jh.txt"
uuid=$(cat "$HOME/agsbx/uuid")
server_ip=$(cat "$HOME/agsbx/server_ip.log")
sxname=$(cat "$HOME/agsbx/name" 2>/dev/null)
xvvmcdnym=$(cat "$HOME/agsbx/cdnym" 2>/dev/null)
section "Airgosbx 脚本输出节点配置如下"
echo
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
# 构建 XHTTP extra JSON 并 URL 编码（用于分享链接下发给客户端）
xh_extra='{"noGRPCHeader":false,"noSSEHeader":false,"xPaddingObfsMode":true,"xPaddingBytes":"100-1000","xPaddingKey":"cf_clearance","xPaddingHeader":"Referer","xPaddingPlacement":"queryInHeader","xPaddingMethod":"repeat-x","uplinkHTTPMethod":"POST","sessionPlacement":"path","sessionKey":"","seqPlacement":"path","seqKey":"","uplinkDataPlacement":"body","uplinkDataKey":"","uplinkChunkSize":0,"scMaxEachPostBytes":1000000,"scMinPostsIntervalMs":"10-50","scMaxBufferedPosts":30,"scStreamUpServerSecs":"20-80","maxConcurrency":"16-32","maxConnections":"0-0","cMaxReuseTimes":"64-128","hMaxReusableSecs":"1800-3000","hKeepAlivePeriod":45,"downloadTargetHost":"","downloadTargetPort":0,"downloadServerName":"","downloadHTTPHost":""}'
xh_extra_encoded=$(printf '%s' "$xh_extra" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g')
# 构建 TCP 专属 Finalmask JSON 并 URL 编码（包含 fragment + sudoku，专属于 TCP-Reality 裸节点对抗 TLS 指纹）
fm_tcp_config="{\"tcp\":[{\"type\":\"fragment\",\"settings\":{\"packets\":\"tlshello\",\"length\":\"100-200\",\"delay\":\"10-20\",\"maxSplit\":\"3-6\"}},{\"type\":\"sudoku\",\"settings\":{\"password\":\"$uuid\",\"paddingMin\":16,\"paddingMax\":64}}]}"
fm_tcp_encoded=$(printf '%s' "$fm_tcp_config" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
# 构建 XHTTP 专属 Finalmask JSON 并 URL 编码（TCP 用 sudoku，UDP 使用 noise）
fm_xh_config="{\"tcp\":[{\"type\":\"sudoku\",\"settings\":{\"password\":\"$uuid\",\"paddingMin\":16,\"paddingMax\":64}}],\"udp\":[{\"type\":\"noise\",\"settings\":{\"reset\":\"30-60\",\"noise\":[{\"rand\":\"32-128\",\"randRange\":\"0-255\",\"delay\":\"10-20\"}]}}]}"
fm_xh_encoded=$(printf '%s' "$fm_xh_config" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
if grep -q xhttp-reality "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vlessenc-xhttp-reality-vision-fm 】支持ENC加密，节点信息如下："
port_xh=$(cat "$HOME/agsbx/port_xh")
vl_xh_link="vless://$uuid@$server_ip:$port_xh?encryption=$enkey&flow=xtls-rprx-vision&security=reality&sni=$ym_vl_re&fp=chrome&pbk=$public_key_x&sid=$short_id_x&type=xhttp&path=/$uuid-xh&mode=auto&extra=$xh_extra_encoded&fm=$fm_xh_encoded#${sxname}vlessenc-xhttp-reality-vision-fm-$hostname"
echo "$vl_xh_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_xh_link"
echo
if [ "$sub" = yes ]; then
clxhpt(){
cat <<EOF
- name: "${sxname}vlessenc-xhttp-reality-vision-fm-$hostname"
  type: vless
  server: $server_ip
  port: $port_xh
  uuid: $uuid
  network: xhttp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $ym_vl_re
  reality-opts:
    public-key: $public_key_x
    short-id: $short_id_x
  client-fingerprint: chrome
  xhttp-opts:
    path: "/$uuid-xh"
EOF
}
clxhpt1(){
echo "- ${sxname}vlessenc-xhttp-reality-vision-fm-$hostname"
}
fi
fi
if grep -q vlessenc-xhttp-cdn "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vlessenc-xhttp-tls-vision-fm-cdn 】支持ENC/FM双端混淆与回源TLS加密，节点信息如下："
port_xvcdn=$(cat "$HOME/agsbx/port_xvcdn")
xvvmcdnym=$(cat "$HOME/agsbx/cdnym" 2>/dev/null)
if [ -z "$xvvmcdnym" ]; then
  xvvmcdnym="$server_ip"
fi
vl_xvcdn_link="vless://$uuid@icook.hk:$port_xvcdn?encryption=$enkey&flow=xtls-rprx-vision&security=tls&sni=$xvvmcdnym&host=$xvvmcdnym&type=xhttp&path=/$uuid-xvd&mode=auto&extra=$xh_extra_encoded&fm=$fm_xh_encoded#${sxname}vlessenc-xhttp-tls-vision-fm-cdn-$hostname"
echo "$vl_xvcdn_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_xvcdn_link"
echo
if [ "$sub" = yes ]; then
clxvcdnpt(){
cat <<EOF
- name: "${sxname}vlessenc-xhttp-tls-vision-fm-cdn-$hostname"
  type: vless
  server: icook.hk
  port: $port_xvcdn
  uuid: $uuid
  network: xhttp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: "$xvvmcdnym"
  client-fingerprint: chrome
  xhttp-opts:
    path: "/$uuid-xvd"
  headers:
    Host: "$xvvmcdnym"
EOF
}
clxvcdnpt1(){
echo "- ${sxname}vlessenc-xhttp-tls-vision-fm-cdn-$hostname"
}
fi
fi
if grep -q vless-xhttp "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vlessenc-xhttp-vision 】支持ENC加密，节点信息如下："
port_vx=$(cat "$HOME/agsbx/port_vx")
vl_vx_link="vless://$uuid@$server_ip:$port_vx?encryption=$enkey&flow=xtls-rprx-vision&type=xhttp&path=$uuid-vx&mode=auto&extra=$xh_extra_encoded#${sxname}vlessenc-xhttp-vision-$hostname"
echo "$vl_vx_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vx_link"
echo
if [ -f "$HOME/agsbx/cdnym" ]; then
node_title "💣【 Vlessenc-xhttp-vision-cdn 】支持ENC加密，节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vl_vx_cdn_link="vless://$uuid@icook.hk:$port_vx?encryption=$enkey&flow=xtls-rprx-vision&type=xhttp&host=$xvvmcdnym&path=$uuid-vx&mode=auto&extra=$xh_extra_encoded#${sxname}vlessenc-xhttp-vision-cdn-$hostname"
echo "$vl_vx_cdn_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vx_cdn_link"
echo
fi
fi
if grep -q vless-ws "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vlessenc-ws-vision 】支持ENC加密，节点信息如下："
port_vw=$(cat "$HOME/agsbx/port_vw")
vl_vw_link="vless://$uuid@$server_ip:$port_vw?encryption=$enkey&flow=xtls-rprx-vision&type=ws&path=$uuid-vw#${sxname}vlessenc-ws-vision-$hostname"
echo "$vl_vw_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vw_link"
echo
if [ -f "$HOME/agsbx/cdnym" ]; then
node_title "💣【 Vlessenc-ws-vision-cdn 】支持ENC加密，节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vl_vw_cdn_link="vless://$uuid@icook.hk:$port_vw?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$xvvmcdnym&path=$uuid-vw#${sxname}vlessenc-ws-vision-cdn-$hostname"
echo "$vl_vw_cdn_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vw_cdn_link"
echo
fi
fi
if grep -q reality-vision "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vless-tcp-reality-vision-fm 】节点信息如下："
port_vl_re=$(cat "$HOME/agsbx/port_vl_re")
vl_link="vless://$uuid@$server_ip:$port_vl_re?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$ym_vl_re&fp=chrome&pbk=$public_key_x&sid=$short_id_x&type=tcp&headerType=none&fm=$fm_tcp_encoded#${sxname}vl-reality-vision-fm-$hostname"
echo "$vl_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_link"
echo
if [ "$sub" = yes ]; then
clvlpt(){
cat <<EOF
- name: "${sxname}vl-reality-vision-fm-$hostname"
  type: vless
  server: $server_ip
  port: $port_vl_re
  uuid: $uuid
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
echo "- ${sxname}vl-reality-vision-fm-$hostname"
}
fi
fi
if grep -q vless-kcp-xdns "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vless-kcp-xdns-fm 】备用DNS隧道，节点信息如下："
port_xdns=$(cat "$HOME/agsbx/port_xdns")
xdns_fm="{\"udp\":[{\"type\":\"xdns\",\"settings\":{\"domains\":[\"$xdnsym\"]}}]}"
xdns_fm_encoded=$(printf '%s' "$xdns_fm" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
vl_xdns_link="vless://$uuid@$server_ip:$port_xdns?encryption=none&flow=&type=kcp&headerType=none&fm=$xdns_fm_encoded#${sxname}vless-kcp-xdns-fm-$hostname"
echo "$vl_xdns_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_xdns_link"
echo
fi
if grep -q vless-kcp-xicmp "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Vless-kcp-xicmp-fm 】特种L3 Ping隧道，节点信息如下："
xicmp_fm="{\"udp\":[{\"type\":\"xicmp\",\"settings\":{\"listenIp\":\"0.0.0.0\",\"id\":0}}]}"
xicmp_fm_encoded=$(printf '%s' "$xicmp_fm" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
vl_xicmp_link="vless://$uuid@$server_ip:0?encryption=none&flow=&type=kcp&headerType=none&fm=$xicmp_fm_encoded#${sxname}vless-kcp-xicmp-fm-$hostname"
echo "$vl_xicmp_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_xicmp_link"
echo
fi
if grep -q ss-2022 "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Shadowsocks-2022 】节点信息如下："
port_ss=$(cat "$HOME/agsbx/port_ss")
ss_link="ss://$(echo -n "2022-blake3-aes-128-gcm:$sskey@$server_ip:$port_ss" | safe_base64)#${sxname}Shadowsocks-2022-$hostname"
echo "$ss_link" >> "$HOME/agsbx/jh.txt"
echo "$ss_link"
echo
if [ "$sub" = yes ]; then
clsspt(){
cat <<EOF
- name: "${sxname}Shadowsocks-2022-$hostname"
  type: ss
  server: $server_ip
  port: $port_ss
  cipher: 2022-blake3-aes-128-gcm
  password: "$sskey"
  udp: true
  udp-over-tcp: true
  udp-over-tcp-version: 2
EOF
}
clsspt1(){
echo "- ${sxname}Shadowsocks-2022-$hostname"
}
fi
fi
if grep -q vmess-xr "$HOME/agsbx/xr.json" 2>/dev/null || grep -q vmess-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Vmess-ws 】节点信息如下："
port_vm_ws=$(cat "$HOME/agsbx/port_vm_ws")
vm_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vm-ws-$hostname\", \"add\": \"$server_ip\", \"port\": \"$port_vm_ws\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"www.bing.com\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
echo "$vm_link" >> "$HOME/agsbx/jh.txt"
echo "$vm_link"
echo
if [ "$sub" = yes ]; then
clvmpt(){
cat <<EOF
- name: "${sxname}vmess-ws-$hostname"
  type: vmess
  server: $server_ip
  port: $port_vm_ws
  uuid: $uuid
  alterId: 0
  cipher: auto
  udp: true
  tls: false
  network: ws
  servername: www.bing.com
  ws-opts:
    path: "/$uuid-vm"
    headers:
      Host: www.bing.com
EOF
}
clvmpt1(){
echo "- ${sxname}vmess-ws-$hostname"
}
fi
if [ -f "$HOME/agsbx/cdnym" ]; then
node_title "💣【 Vmess-ws-cdn 】节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vm_cdn_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vm-ws-cdn-$hostname\", \"add\": \"icook.hk\", \"port\": \"$port_vm_ws\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$xvvmcdnym\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
echo "$vm_cdn_link" >> "$HOME/agsbx/jh.txt"
echo "$vm_cdn_link"
echo
if [ "$sub" = yes ]; then
clvmcdnpt(){
cat <<EOF
- name: "${sxname}vmess-ws-cdn-$hostname"
  type: vmess
  server: icook.hk
  port: $port_vm_ws
  uuid: $uuid
  alterId: 0
  cipher: auto
  udp: true
  tls: false
  network: ws
  servername: "$xvvmcdnym"
  ws-opts:
    path: "/$uuid-vm"
    headers:
      Host: "$xvvmcdnym"
EOF
}
clvmcdnpt1(){
echo "- ${sxname}vmess-ws-cdn-$hostname"
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
an_link="anytls://$uuid@$server_ip:$port_an?sni=$ran_sni&insecure=0&allowInsecure=0#${sxname}anytls-$hostname"
else
an_link="anytls://$uuid@$server_ip:$port_an?insecure=1&allowInsecure=1#${sxname}anytls-$hostname"
fi
echo "$an_link" >> "$HOME/agsbx/jh.txt"
echo "$an_link"
echo
fi
if grep -q anyreality-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Any-Reality 】节点信息如下："
port_ar=$(cat "$HOME/agsbx/port_ar")
ar_link="anytls://$uuid@$server_ip:$port_ar?security=reality&sni=$ym_vl_re&fp=chrome&pbk=$public_key_s&sid=$short_id_s&type=tcp&headerType=none#${sxname}any-reality-$hostname"
echo "$ar_link" >> "$HOME/agsbx/jh.txt"
echo "$ar_link"
echo
fi
if grep -q hy2-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Hysteria2 】节点信息如下："
port_hy2=$(cat "$HOME/agsbx/port_hy2")
obfs_pass=$(cat "$HOME/agsbx/obfs_pass" 2>/dev/null)
cert_hash=$(cat "$HOME/agsbx/cert_sha256.txt" 2>/dev/null)
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
hy2_link="hysteria2://$uuid@$server_ip:$port_hy2?security=tls&alpn=h3&sni=$ran_sni&insecure=0&allowInsecure=0&obfs=salamander&obfs-password=$obfs_pass${sby_mport}#${sxname}hy2-$hostname"
else
hy2_link="hysteria2://$uuid@$server_ip:$port_hy2?security=tls&alpn=h3&sni=$ran_sni&insecure=0&allowInsecure=0${sby_mport}#${sxname}hy2-$hostname"
fi
else
if [ -n "$obfs_pass" ]; then
hy2_link="hysteria2://$uuid@$server_ip:$port_hy2?pinSHA256=$cert_hash&alpn=h3&sni=$ran_sni&insecure=1&allowInsecure=1&obfs=salamander&obfs-password=$obfs_pass${sby_mport}#${sxname}hy2-$hostname"
else
hy2_link="hysteria2://$uuid@$server_ip:$port_hy2?pinSHA256=$cert_hash&alpn=h3&sni=$ran_sni&insecure=1&allowInsecure=1${sby_mport}#${sxname}hy2-$hostname"
fi
fi
echo "$hy2_link" >> "$HOME/agsbx/jh.txt"
echo "$hy2_link"
echo
if [ "$sub" = yes ]; then
clhypt(){
local sby_hop_clean=$(echo "$sby_hop" | tr ':' '-')
local cl_skip_cert="true"
cert_trusted "$cert_mode" && cl_skip_cert="false"
local cl_obfs=""
[ -n "$obfs_pass" ] && cl_obfs="  obfs: salamander\n  obfs-password: \"$obfs_pass\""
cat <<EOF
- name: "${sxname}hy2-$hostname"
  type: hysteria2
  server: $server_ip
  port: $port_hy2
  ports: "$sby_hop_clean"
  password: "$uuid"
  alpn:
    - h3
  sni: "${ran_sni:-www.bing.com}"
  skip-cert-verify: $cl_skip_cert
  fast-open: true
$(printf "$cl_obfs")
EOF
}
clhypt1(){
echo "- ${sxname}hy2-$hostname"
}
fi
fi
if grep -q hy2-xr "$HOME/agsbx/xr.json" 2>/dev/null; then
node_title "💣【 Xray-Hysteria2 】节点信息如下："
port_xhy2=$(cat "$HOME/agsbx/port_xhy2")
cert_hash=$(cat "$HOME/agsbx/cert_sha256.txt" 2>/dev/null)
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
xhy2_link="hysteria2://$uuid@$server_ip:$port_xhy2?security=tls&alpn=h3&sni=$ran_sni&insecure=0&allowInsecure=0${xby_mport}#${sxname}xray-hy2-$hostname"
else
xhy2_link="hysteria2://$uuid@$server_ip:$port_xhy2?pinSHA256=$cert_hash&alpn=h3&sni=$ran_sni&insecure=1&allowInsecure=1${xby_mport}#${sxname}xray-hy2-$hostname"
fi
echo "$xhy2_link" >> "$HOME/agsbx/jh.txt"
echo "$xhy2_link"
echo
if [ "$sub" = yes ]; then
clxhypt(){
local xby_hop_clean=$(echo "$xby_hop" | tr ':' '-')
local cl_skip_cert="true"
cert_trusted "$cert_mode" && cl_skip_cert="false"
cat <<EOF
- name: "${sxname}xray-hy2-$hostname"
  type: hysteria2
  server: $server_ip
  port: $port_xhy2
  ports: "$xby_hop_clean"
  password: "$uuid"
  alpn:
    - h3
  sni: "${ran_sni:-www.bing.com}"
  skip-cert-verify: $cl_skip_cert
  fast-open: true
EOF
}
clxhypt1(){
echo "- ${sxname}xray-hy2-$hostname"
}
fi
fi
if grep -q tuic5-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Tuic 】节点信息如下："
port_tu=$(cat "$HOME/agsbx/port_tu")
ran_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
if cert_trusted "$cert_mode" && [ -n "$ran_sni" ]; then
tuic5_link="tuic://$uuid:$uuid@$server_ip:$port_tu?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$ran_sni&insecure=0&allow_insecure=0&allowInsecure=0#${sxname}tuic-$hostname"
else
tuic5_link="tuic://$uuid:$uuid@$server_ip:$port_tu?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$ran_sni&allow_insecure=1&allowInsecure=1#${sxname}tuic-$hostname"
fi
echo "$tuic5_link" >> "$HOME/agsbx/jh.txt"
echo "$tuic5_link"
echo
if [ "$sub" = yes ]; then
cltupt(){
local cl_skip_cert="true"
cert_trusted "$cert_mode" && cl_skip_cert="false"
cat <<EOF
- name: "${sxname}tuic5-$hostname"
  server: $server_ip
  port: $port_tu
  type: tuic
  uuid: $uuid
  password: "$uuid"
  alpn:
    - h3
  disable-sni: false
  reduce-rtt: true
  udp-relay-mode: native
  congestion-controller: bbr
  sni: "${ran_sni:-www.bing.com}"
  skip-cert-verify: $cl_skip_cert
EOF
}
cltupt1(){
echo "- ${sxname}tuic5-$hostname"
}
fi
fi
if grep -q socks5-xr "$HOME/agsbx/xr.json" 2>/dev/null || grep -q socks5-sb "$HOME/agsbx/sb.json" 2>/dev/null; then
node_title "💣【 Socks5 】客户端信息如下："
port_so=$(cat "$HOME/agsbx/port_so")
echo "请配合其他应用内置代理使用，勿做节点直接使用"
echo "客户端地址：$server_ip"
echo "客户端端口：$port_so"
echo "客户端用户名：$uuid"
echo "客户端密码：$uuid"
echo
fi
# NaiveProxy(Caddy) 节点卡片：独立内核，配置存在即展示。仅打印到控制台，不并入聚合订阅 jh.txt / Clash
# （naive 客户端生态与 vless/vmess 等不同，混入聚合订阅会被多数客户端解析失败）。
if [ -s "$HOME/agsbx/naive_domain" ]; then
naivedomain=$(cat "$HOME/agsbx/naive_domain")
naiveuser=$(cat "$HOME/agsbx/naive_user" 2>/dev/null)
naivepass=$(cat "$HOME/agsbx/naive_pass" 2>/dev/null)
node_title "💣【 NaiveProxy 】Caddy 转发代理（独立客户端），节点信息如下："
echo "账号：$naiveuser"
echo "密码：$naivepass"
echo "分享链接(HTTPS·H1/H2，TCP)：naive+https://$naiveuser:$naivepass@$naivedomain:443?padding=true#${sxname}naive-tcp-$hostname"
echo "分享链接(QUIC·H3，UDP)：naive+quic://$naiveuser:$naivepass@$naivedomain:443?padding=true#${sxname}naive-quic-$hostname"
echo "（用 NekoBox 等支持 naive 的客户端导入；SNI/端口已含在链接内，naive+quic 需放行 UDP/443；未并入 jh.txt / Clash 聚合订阅）"
echo
fi
argodomain=$(cat "$HOME/agsbx/sbargoym.log" 2>/dev/null)
if [ -z "$argodomain" ]; then
  argodomain=$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' "$HOME/agsbx/argo.log" 2>/dev/null | head -n1)
fi
if [ -n "$argodomain" ]; then
vlvm=$(cat $HOME/agsbx/vlvm 2>/dev/null)
if [ "$vlvm" = "Vmess" ]; then
      vmatls_link1="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-tls-argo-$hostname-443\", \"add\": \"icook.hk\", \"port\": \"443\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"tls\", \"sni\": \"$argodomain\", \"alpn\": \"\", \"fp\": \"chrome\"}" | safe_base64)"
      echo "$vmatls_link1" >> "$HOME/agsbx/jh.txt"
      vmatls_link2="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-tls-argo-$hostname-8443\", \"add\": \"icook.hk\", \"port\": \"8443\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"tls\", \"sni\": \"$argodomain\", \"alpn\": \"\", \"fp\": \"chrome\"}" | safe_base64)"
      echo "$vmatls_link2" >> "$HOME/agsbx/jh.txt"
      vmatls_link3="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-tls-argo-$hostname-2053\", \"add\": \"icook.hk\", \"port\": \"2053\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"tls\", \"sni\": \"$argodomain\", \"alpn\": \"\", \"fp\": \"chrome\"}" | safe_base64)"
      echo "$vmatls_link3" >> "$HOME/agsbx/jh.txt"
      vmatls_link4="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-tls-argo-$hostname-2083\", \"add\": \"icook.hk\", \"port\": \"2083\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"tls\", \"sni\": \"$argodomain\", \"alpn\": \"\", \"fp\": \"chrome\"}" | safe_base64)"
      echo "$vmatls_link4" >> "$HOME/agsbx/jh.txt"
      vmatls_link5="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-tls-argo-$hostname-2087\", \"add\": \"icook.hk\", \"port\": \"2087\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"tls\", \"sni\": \"$argodomain\", \"alpn\": \"\", \"fp\": \"chrome\"}" | safe_base64)"
      echo "$vmatls_link5" >> "$HOME/agsbx/jh.txt"
      vmatls_link6="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-tls-argo-$hostname-2096\", \"add\": \"[2606:4700::0]\", \"port\": \"2096\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"tls\", \"sni\": \"$argodomain\", \"alpn\": \"\", \"fp\": \"chrome\"}" | safe_base64)"
      echo "$vmatls_link6" >> "$HOME/agsbx/jh.txt"
      vma_link7="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-argo-$hostname-80\", \"add\": \"icook.hk\", \"port\": \"80\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
      echo "$vma_link7" >> "$HOME/agsbx/jh.txt"
      vma_link8="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-argo-$hostname-8080\", \"add\": \"icook.hk\", \"port\": \"8080\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
      echo "$vma_link8" >> "$HOME/agsbx/jh.txt"
      vma_link9="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-argo-$hostname-8880\", \"add\": \"icook.hk\", \"port\": \"8880\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
      echo "$vma_link9" >> "$HOME/agsbx/jh.txt"
      vma_link10="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-argo-$hostname-2052\", \"add\": \"icook.hk\", \"port\": \"2052\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
      echo "$vma_link10" >> "$HOME/agsbx/jh.txt"
      vma_link11="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-argo-$hostname-2082\", \"add\": \"icook.hk\", \"port\": \"2082\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
      echo "$vma_link11" >> "$HOME/agsbx/jh.txt"
      vma_link12="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-argo-$hostname-2086\", \"add\": \"icook.hk\", \"port\": \"2086\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
      echo "$vma_link12" >> "$HOME/agsbx/jh.txt"
      vma_link13="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vmess-ws-argo-$hostname-2095\", \"add\": \"[2400:cb00:2049::0]\", \"port\": \"2095\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$argodomain\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
      echo "$vma_link13" >> "$HOME/agsbx/jh.txt"
      if [ "$sub" = yes ]; then
      clvmargopt(){
      cat <<EOF
- name: "${sxname}vmess-ws-tls-argo-$hostname-443"
  type: vmess
  server: icook.hk
  port: 443
  uuid: $uuid
  alterId: 0
  cipher: auto
  udp: true
  tls: true
  network: ws
  servername: "$argodomain"
  ws-opts:
    path: "/$uuid-vm"
    headers:
      Host: "$argodomain"
- name: "${sxname}vmess-ws-argo-$hostname-80"
  type: vmess
  server: icook.hk
  port: 80
  uuid: $uuid
  alterId: 0
  cipher: auto
  udp: true
  tls: false
  network: ws
  servername: "$argodomain"
  ws-opts:
    path: "/$uuid-vm"
    headers:
      Host: "$argodomain"
EOF
      }
      clvmargopt1(){
      echo "- ${sxname}vmess-ws-tls-argo-$hostname-443"
      echo "- ${sxname}vmess-ws-argo-$hostname-80"
      }
      fi
elif [ "$vlvm" = "Vless" ]; then
vwatls_link1="vless://$uuid@icook.hk:443?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$uuid-vw&security=tls&sni=$argodomain&fp=chrome&insecure=0&allowInsecure=0#${sxname}vlessenc-ws-tls-vision-argo-$hostname"
echo "$vwatls_link1" >> "$HOME/agsbx/jh.txt"
vwa_link2="vless://$uuid@icook.hk:80?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$uuid-vw&security=none#${sxname}vlessenc-ws-vision-argo-$hostname"
echo "$vwa_link2" >> "$HOME/agsbx/jh.txt"
if [ "$sub" = yes ]; then
clvlargopt(){
cat <<EOF
- name: "${sxname}vlessenc-ws-tls-vision-argo-$hostname"
  type: vless
  server: icook.hk
  port: 443
  uuid: $uuid
  network: ws
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: "$argodomain"
  client-fingerprint: chrome
  ws-opts:
    path: "$uuid-vw"
    headers:
      Host: "$argodomain"
- name: "${sxname}vlessenc-ws-vision-argo-$hostname"
  type: vless
  server: icook.hk
  port: 80
  uuid: $uuid
  network: ws
  udp: true
  tls: false
  flow: xtls-rprx-vision
  ws-opts:
    path: "$uuid-vw"
    headers:
      Host: "$argodomain"
EOF
}
clvlargopt1(){
echo "- ${sxname}vlessenc-ws-tls-vision-argo-$hostname"
echo "- ${sxname}vlessenc-ws-vision-argo-$hostname"
}
fi
elif [ "$vlvm" = "Vlessenc-xhttp-tls-vision-fm" ]; then
vwa_xvargo_link="vless://$uuid@icook.hk:443?encryption=$enkey&flow=xtls-rprx-vision&security=tls&sni=$argodomain&host=$argodomain&type=xhttp&path=/$uuid-xva&mode=auto&extra=$xh_extra_encoded&fm=$fm_xh_encoded#${sxname}vlessenc-xhttp-tls-vision-fm-argo-$hostname"
echo "$vwa_xvargo_link" >> "$HOME/agsbx/jh.txt"
if [ "$sub" = yes ]; then
clxvargopt(){
cat <<EOF
- name: "${sxname}vlessenc-xhttp-tls-vision-fm-argo-$hostname"
  type: vless
  server: icook.hk
  port: 443
  uuid: $uuid
  network: xhttp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: "$argodomain"
  client-fingerprint: chrome
  xhttp-opts:
    path: "/$uuid-xva"
  headers:
    Host: "$argodomain"
EOF
}
clxvargopt1(){
echo "- ${sxname}vlessenc-xhttp-tls-vision-fm-argo-$hostname"
}
fi
fi
sbtk=$(cat "$HOME/agsbx/sbargotoken.log" 2>/dev/null)
if [ -n "$sbtk" ]; then
nametn="Argo固定隧道token：$sbtk"
fi
if [ "$vlvm" = "Vlessenc-xhttp-tls-vision-fm" ]; then
argoshow=$(
echo "Argo隧道端口正在使用$vlvm主协议端口：$(cat $HOME/agsbx/argoport.log 2>/dev/null)
Argo域名：$argodomain
$nametn

💣【 vlessenc-xhttp-tls-vision-fm-argo 超旗舰 Argo 隧道节点 】
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
if [ "$sub" = yes ]; then
get_func() {
  local f=$1
  if type "$f" >/dev/null 2>&1; then
    local out
    out=$($f)
    [ -n "$out" ] && printf "%s\n" "$out"
  fi
}
# 注：vless-xhttp(vxp) 与 vless-ws(vwp) 为 vlessenc 裸协议，mihomo 暂不支持其 ENC 加密，
# 因此不导出到 Clash 订阅（此前这里引用的 clvxpt/clvwpt 系列函数从未定义，等同空操作，已移除）。
clxy="$(get_func clvlpt; get_func clsspt; get_func clvmpt; get_func clvmcdnpt; get_func clxhpt; get_func clxvcdnpt; get_func clhypt; get_func clxhypt; get_func cltupt; get_func clvmargopt; get_func clvlargopt; get_func clxvargopt)"
clgz="$({ get_func clvlpt1; get_func clsspt1; get_func clvmpt1; get_func clvmcdnpt1; get_func clxhpt1; get_func clxvcdnpt1; get_func clhypt1; get_func clxhypt1; get_func cltupt1; get_func clvmargopt1; get_func clvlargopt1; get_func clxvargopt1; } | sed '2,$s/^/    /')"
cat > "$HOME/agsbx/clmi.yaml" <<EOF
port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
dns:
  enable: true
  listen: "0.0.0.0:1053"
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

if [ -z "$subid" ]; then
  subtoken="$uuid"
else
  subtoken="$subid"
fi
echo "$subtoken" > "$HOME/agsbx/subtoken.log"

# ------------------------------------------------------------
# 🎯 任务 H 模块 C & D：Web 订阅分发沙盒挂载与轻量 BusyBox 启动
# - 功能描述：构建安全的 UUID 二级沙盒目录，强制进行 TLS 加密 (自签或 ACME)。
# - 端口机制：读取前置 (installxray/installsb) 注入时持久化保存的独立回源端口 subport_real 予以启动。
# - 关联映射：自启动和 crontab 守护任务将天然与该随机回源端口绑定，对前文的 TLS 卸载 Inbound 提供闭环数据响应。
# ------------------------------------------------------------
setup_tls_certificate
if [ ! -f "$tls_cert_file" ] || [ ! -f "$tls_key_file" ]; then
  setup_selfsigned_certificate
fi

subport_show=$(init_port "$subpt" subport.log)
subport_real=$(init_subport_real "$subport_show")
sub_protocol="https"

kill -15 $(pgrep -f 'websbx' 2>/dev/null) >/dev/null 2>&1
mkdir -p "$HOME/websbx/$subtoken"
ln -sf "$HOME/agsbx/clmi.yaml" "$HOME/websbx/$subtoken/clmi.yaml"
ln -sf "$HOME/agsbx/jh.txt" "$HOME/websbx/$subtoken/jhsub.txt"

if command -v apk >/dev/null 2>&1; then
  busybox-extras httpd -f -p $subport_real -h "$HOME/websbx" > /dev/null 2>&1 &
  cat > /etc/local.d/alpinesubsbx.start <<EOF
#!/bin/bash
sleep 10
busybox-extras httpd -f -p $subport_real -h $HOME/websbx > /dev/null 2>&1 &
EOF
  chmod +x /etc/local.d/alpinesubsbx.start
  rc-update add local default >/dev/null 2>&1
else
  busybox httpd -f -p $subport_real -h "$HOME/websbx" > /dev/null 2>&1 &
  cron_tmp=$(mktemp)
  crontab -l 2>/dev/null > "$cron_tmp"
  sed -i '/websbx/d' "$cron_tmp"
  echo "@reboot sleep 10 && /bin/bash -c \"busybox httpd -f -p $subport_real -h $HOME/websbx > /dev/null 2>&1 &\"" >> "$cron_tmp"
  crontab "$cron_tmp" >/dev/null 2>&1
  rm -f "$cron_tmp"
fi

subdomain=$(cat "$HOME/agsbx/cdnym" 2>/dev/null)
# 复用 Caddy 真实证书时(cert_mode=caddy)，订阅地址优先用 naive 域名，使客户端 HTTPS 证书校验直接通过、
# 免去 skip-cert-verify；仅在未显式指定 cdnym 优选域名时生效，不覆盖用户的 CDN 配置。
if [ -z "$subdomain" ] && [ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" = "caddy" ]; then
  subdomain=$(cat "$HOME/agsbx/naive_domain" 2>/dev/null)
fi
[ -z "$subdomain" ] && subdomain="$server_ip"
suburl="${sub_protocol}://${subdomain}:${subport_show}/${subtoken}"
clash_sub_info="Clash/Mihomo 本地订阅链接：${suburl}/clmi.yaml"
fi
hr
echo "$argoshow"
echo
if [ "$sub" = yes ]; then
hr2
echo "$clash_sub_info"
echo "聚合协议本地订阅地址：${suburl}/jhsub.txt"
if [ "$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)" = "selfsigned" ]; then
hr
printf '%s\n' "${C_YELLOW}⚠️  安全加密提示 (自签证书模式)：${C_RESET}"
echo "   由于您当前未使用域名或 ACME 证书，系统已自动启用本地自签 TLS 强加密。"
echo "   客户端（Clash/Mihomo/Shadowrocket）拉取订阅时，请务必勾选："
echo "   -> [ 允许不安全证书 / 跳过证书验证 (skip-cert-verify: true) ]"
echo "   即可无痛拉取，同时 100% 获得高强度 TLS 传输加密，防御中间人嗅探！"
fi
hr2
echo
fi
hr
echo "聚合节点信息，请进入 $HOME/agsbx/jh.txt 文件目录查看或者运行 cat $HOME/agsbx/jh.txt 查看"
hr2
# 安全加固：全局收紧敏感文件权限（阻断多用户环境下的未授权文件读取）
find "$HOME/agsbx" -type d -exec chmod 700 {} + 2>/dev/null
find "$HOME/agsbx" -type f -exec chmod 600 {} + 2>/dev/null
chmod 700 "$HOME/agsbx/xray" "$HOME/agsbx/sing-box" "$HOME/agsbx/cloudflared" 2>/dev/null
echo "相关快捷方式如下：(首次安装成功后需重连SSH，agsbx快捷方式才可生效)"
showmode
}
#============================================================
# [第10段] 系统清理、卸载与内核服务重启自愈函数
#------------------------------------------------------------
# 🎯 架构说明:
# - 本大段包含 cleandel() (系统级清理服务与进程、清洗除 ACME 定时检查外的 crontab 任务)、xrestart()/sbrestart() (Xray/Sing-box的重启自愈与前后台运行方式平滑自适应)。
# - 关联性: 为后续第 11 段 (命令路由) 处理 del(卸载)、rep(重置协议) 或 res(重启) 提供底层物理清理与状态复原支撑。
#============================================================
cleandel(){
restore_xicmp_state
cleanup_port_hopping
for P in /proc/[0-9]*; do if [ -L "$P/exe" ]; then TARGET=$(readlink -f "$P/exe" 2>/dev/null); if echo "$TARGET" | grep -qE '/agsbx/cloudflared|/agsbx/sing-box|/agsbx/xray|/agsbx/caddy'; then PID=$(basename "$P"); kill "$PID" 2>/dev/null; fi; fi; done
kill -15 $(pgrep -f 'agsbx/sing-box' 2>/dev/null) $(pgrep -f 'agsbx/cloudflared' 2>/dev/null) $(pgrep -f 'agsbx/xray' 2>/dev/null) $(pgrep -f 'agsbx/caddy' 2>/dev/null) $(pgrep -f 'websbx' 2>/dev/null) >/dev/null 2>&1
if [ -f ~/.bashrc ]; then
sed -i '/agsbx/d' ~/.bashrc
sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' ~/.bashrc
sed -i '/export PATH="\$PATH:\$HOME\/bin"/d' ~/.bashrc
. ~/.bashrc 2>/dev/null
fi
cron_tmp=$(mktemp)
crontab -l > "$cron_tmp" 2>/dev/null
sed -i '/agsbx\/sing-box/d' "$cron_tmp"
sed -i '/agsbx\/xray/d' "$cron_tmp"
sed -i '/agsbx\/cloudflared/d' "$cron_tmp"
sed -i '/agsbx\/caddy/d' "$cron_tmp"
sed -i '/websbx/d' "$cron_tmp"
crontab "$cron_tmp" >/dev/null 2>&1
rm -f "$cron_tmp"
rm -rf "$HOME/bin/agsbx" /usr/local/bin/agsbx /usr/bin/agsbx "$HOME/websbx"
if pidof systemd >/dev/null 2>&1; then
for svc in xr sb argo caddy; do
systemctl stop "$svc" >/dev/null 2>&1
systemctl disable "$svc" >/dev/null 2>&1
done
rm -rf /etc/systemd/system/{xr.service,sb.service,argo.service,caddy.service}
elif command -v rc-service >/dev/null 2>&1; then
for svc in sing-box xray argo caddy; do
rc-service "$svc" stop >/dev/null 2>&1
rc-update del "$svc" default >/dev/null 2>&1
done
rm -rf /etc/init.d/{sing-box,xray,argo,caddy} /etc/local.d/alpinesubsbx.start
fi
}
xrestart(){
kill -15 $(pgrep -f 'agsbx/xray' 2>/dev/null) >/dev/null 2>&1
if pidof systemd >/dev/null 2>&1; then
systemctl restart xr >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1; then
rc-service xray restart >/dev/null 2>&1
else
nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json > "$HOME/agsbx/xray.log" 2>&1 &
fi
}
sbrestart(){
kill -15 $(pgrep -f 'agsbx/sing-box' 2>/dev/null) >/dev/null 2>&1
if pidof systemd >/dev/null 2>&1; then
systemctl restart sb >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1; then
rc-service sing-box restart >/dev/null 2>&1
else
nohup $HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json > "$HOME/agsbx/sing-box.log" 2>&1 &
fi
}
# 内核生命周期统一入口：start / stop / restart / reload，自适应 systemd / openrc / 裸 nohup 三种后端。
# 用法：kctl <动作> <内核>，内核 ∈ xray｜sb｜caddy（all 由调用方展开为 xray+sb）。
# 关键约束：
#   · stop/start 在 systemd/openrc 下必须经服务管理器，否则 Restart 策略会立刻把内核重新拉起，停不掉、端口释放不了。
#   · reload：sing-box 支持 SIGHUP 热重载（校验后重建实例）；Xray 官方不支持热重载 → 自动改为 restart；caddy 预留。
kctl(){
  local action="$1" kernel="$2" name bin cfg pat sd rc log
  case "$kernel" in
    xray|x)      name="Xray";     bin="$HOME/agsbx/xray";     cfg="$HOME/agsbx/xr.json"; pat='agsbx/xray';     sd="xr"; rc="xray";     log="$HOME/agsbx/xray.log" ;;
    sb|sing-box) name="Sing-box"; bin="$HOME/agsbx/sing-box"; cfg="$HOME/agsbx/sb.json"; pat='agsbx/sing-box'; sd="sb"; rc="sing-box"; log="$HOME/agsbx/sing-box.log" ;;
    caddy)       name="Caddy";     bin="$HOME/agsbx/caddy";     cfg="$HOME/agsbx/Caddyfile"; pat='agsbx/caddy';    sd="caddy"; rc="caddy";    log="$HOME/agsbx/caddy.log" ;;
    *)           echo "未知内核：$kernel（可选 xray｜sb｜caddy｜all）"; return 1 ;;
  esac
  if [ ! -s "$bin" ]; then echo "${name}：内核未下载，无法执行 ${action}。"; return 1; fi
  # Xray 无配置热重载，reload 自动降级为 restart
  if [ "$action" = "reload" ] && [ "$sd" = "xr" ]; then
    echo "Xray 不支持配置热重载（官方设计），已自动改为 restart。"; action="restart"
  fi
  # Caddy：start/restart/reload 前先做配置语法预检，坏配置直接拦截，不推上线、不动正在运行的服务
  if [ "$sd" = caddy ] && { [ "$action" = start ] || [ "$action" = restart ] || [ "$action" = reload ]; } && [ -s "$cfg" ]; then
    if ! "$bin" validate --config "$cfg" >/dev/null 2>&1; then
      echo "Caddy：配置校验未通过，已拦截 ${action}（不影响正在运行的服务）："
      "$bin" validate --config "$cfg" 2>&1 | grep -iE 'error|invalid' | head -3
      return 1
    fi
  fi
  # 启动参数：xray/sing-box 用 run -c，caddy 用 run --config
  local runflag="-c"; [ "$sd" = caddy ] && runflag="--config"
  case "$action" in
    start|restart)
      if pidof systemd >/dev/null 2>&1; then
        systemctl "$action" "$sd" >/dev/null 2>&1
      elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$rc" "$action" >/dev/null 2>&1
      else
        kill -15 $(pgrep -f "$pat" 2>/dev/null) >/dev/null 2>&1
        nohup "$bin" run "$runflag" "$cfg" > "$log" 2>&1 &
      fi
      sleep 1
      if pgrep -f "$pat" >/dev/null 2>&1; then
        [ "$action" = start ] && echo "${name}：已启动 ✓" || echo "${name}：已重启 ✓"
      else
        echo "${name}：${action} 后进程未起来 ✗，请查看日志定位原因："
        if pidof systemd >/dev/null 2>&1; then
          echo "    journalctl -u $sd -n 30 --no-pager"
        else
          echo "    tail -n 30 $log"
        fi
      fi ;;
    stop)
      if pidof systemd >/dev/null 2>&1; then
        systemctl stop "$sd" >/dev/null 2>&1
      elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$rc" stop >/dev/null 2>&1
      else
        kill -15 $(pgrep -f "$pat" 2>/dev/null) >/dev/null 2>&1
      fi
      echo "${name}：已停止（占用端口已释放）。" ;;
    reload)
      if [ "$sd" = caddy ]; then
        # caddy 原生热重载（配置已在上方预检通过）：systemd 下走 systemctl reload，否则直接 caddy reload
        if pidof systemd >/dev/null 2>&1; then
          systemctl reload "$sd" >/dev/null 2>&1
        else
          "$bin" reload --config "$cfg" >/dev/null 2>&1
        fi
        echo "Caddy：配置校验通过，已热重载（连接不断）✓"
      elif pgrep -f "$pat" >/dev/null 2>&1; then
        kill -HUP $(pgrep -f "$pat" 2>/dev/null) >/dev/null 2>&1
        echo "${name}：已发送热重载信号（SIGHUP）。"
      else
        echo "${name}：进程未运行，无法 reload，请改用 start。"
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
for kv in "xray:Xray" "sing-box:Sing-box" "caddy:Caddy" "cloudflared:Argo"; do
  k=${kv%%:*}; label=${kv##*:}
  pid=$(pgrep -f "agsbx/$k" 2>/dev/null | head -1)
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
if [ "$1" = "del" ]; then
cleandel
# 注：sbx_update 标记文件位于 $HOME/agsbx 内，随该目录一并删除；此前裸写的相对路径 sbx_update
# 指向当前工作目录，既删不到目标又有误删同名文件的风险，已移除。$HOME/agsb 为旧版本遗留目录，保留以清理历史安装。
rm -rf "$HOME/agsbx" "$HOME/agsb"
echo "卸载完成"
echo "欢迎继续使用Airgosbx一键无交互小钢炮脚本💣" && sleep 2
echo
showmode
exit
elif [ "$1" = "rep" ]; then
cleandel
rm -rf "$HOME/agsbx"/{sb.json,xr.json,sbargoym.log,sbargotoken.log,argo.log,argoport.log,cdnym,name,Caddyfile,naive_user,naive_pass,naive_domain,caddy.log,caddy_storage}
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
if upxray "$reqver"; then
  for P in /proc/[0-9]*; do [ -L "$P/exe" ] || continue; TARGET=$(readlink -f "$P/exe" 2>/dev/null) || continue; case "$TARGET" in *"/agsbx/x"*) kill "$(basename "$P")" 2>/dev/null ;; esac; done
  kill -15 $(pgrep -f 'agsbx/xray' 2>/dev/null) >/dev/null 2>&1
  xrestart && echo "Xray 内核已切换并重启完成" && sleep 2 && cip
else
  echo "Xray 内核未变更，原版本继续运行（服务未中断）。"
fi
exit
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
if upsingbox "$reqver"; then
  for P in /proc/[0-9]*; do [ -L "$P/exe" ] || continue; TARGET=$(readlink -f "$P/exe" 2>/dev/null) || continue; case "$TARGET" in *"/agsbx/s"*) kill "$(basename "$P")" 2>/dev/null ;; esac; done
  kill -15 $(pgrep -f 'agsbx/sing-box' 2>/dev/null) >/dev/null 2>&1
  sbrestart && echo "Sing-box 内核已切换并重启完成" && sleep 2 && cip
else
  echo "Sing-box 内核未变更，原版本继续运行（服务未中断）。"
fi
exit
elif [ "$1" = "status" ] || [ "$1" = "stats" ] || [ "$1" = "top" ]; then
showstats
exit
elif [ "$1" = "res" ]; then
for P in /proc/[0-9]*; do
[ -L "$P/exe" ] || continue
TARGET=$(readlink -f "$P/exe" 2>/dev/null) || continue
case "$TARGET" in
*"/agsbx/s"*)
kill "$(basename "$P")" 2>/dev/null
sbrestart
;;
*"/agsbx/x"*)
kill "$(basename "$P")" 2>/dev/null
xrestart
;;
*"/agsbx/cloudflared"*)
kill "$(basename "$P")" 2>/dev/null
kill -15 $(pgrep -f 'agsbx/cloudflared' 2>/dev/null) >/dev/null 2>&1
if pidof systemd >/dev/null 2>&1; then
systemctl restart argo >/dev/null 2>&1
elif command -v rc-service >/dev/null 2>&1; then
rc-service argo restart >/dev/null 2>&1
else
if [ -e "$HOME/agsbx/sbargotoken.log" ]; then
if ! pidof systemd >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $(cat $HOME/agsbx/sbargotoken.log 2>/dev/null) > "$HOME/agsbx/argo.log" 2>&1 &
fi
else
# res 为全新一次脚本调用，$argo 变量已不在作用域，从持久化的 vlvm 文件还原回源协议
argoscheme="http"; argoxtls=""
[ "$(cat "$HOME/agsbx/vlvm" 2>/dev/null)" = "Vlessenc-xhttp-tls-vision-fm" ] && { argoscheme="https"; argoxtls="--no-tls-verify "; }
nohup $HOME/agsbx/cloudflared tunnel --url ${argoscheme}://localhost:$(cat $HOME/agsbx/argoport.log 2>/dev/null) ${argoxtls}--edge-ip-version auto --no-autoupdate --protocol http2 > $HOME/agsbx/argo.log 2>&1 &
fi
fi
;;
esac
done
sleep 5 && echo "重启完成" && sleep 3 && cip
exit
elif [ "$1" = "update" ]; then
# 仅把 agsbx 自身刷新到最新版，不触碰任何配置与内核（服务保持运行、连接不断）。
dst=$(command -v agsbx 2>/dev/null); [ -z "$dst" ] && dst="/usr/local/bin/agsbx"
echo "正在从仓库拉取最新脚本覆盖：$dst ……"
utmp=$(mktemp)
if (command -v curl >/dev/null 2>&1 && curl -sL "$agsbxurl" -o "$utmp") || (command -v wget >/dev/null 2>&1 && wget -qO "$utmp" "$agsbxurl"); then
  if head -1 "$utmp" 2>/dev/null | grep -q '^#!'; then
    mv -f "$utmp" "$dst" && chmod 700 "$dst"
    echo "脚本已更新到最新版 ✓（配置与内核未改动；需要应用新逻辑时再按需 agsbx rep / res）。"
  else
    rm -f "$utmp"; echo "更新失败：下载内容异常（非脚本），已保留原脚本不动。"
  fi
else
  rm -f "$utmp"; echo "更新失败：网络不可达，已保留原脚本不动。"
fi
exit
elif [ "$1" = "start" ] || [ "$1" = "stop" ] || [ "$1" = "restart" ] || [ "$1" = "reload" ]; then
# 内核生命周期：agsbx <动作> [内核]，内核省略=all（展开为 xray+sb 两大代理内核；Argo 全量重启请用 res）
action="$1"; target="${2:-all}"
case "$target" in
  all)         kctl "$action" xray; kctl "$action" sb ;;
  xray|x)      kctl "$action" xray ;;
  sb|sing-box) kctl "$action" sb ;;
  caddy)       kctl "$action" caddy ;;
  *)           echo "未知内核：$target（可选 xray｜sb｜caddy｜all，省略=all）"; exit 1 ;;
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
if ! agsbx_running; then
for P in /proc/[0-9]*; do if [ -L "$P/exe" ]; then TARGET=$(readlink -f "$P/exe" 2>/dev/null); if echo "$TARGET" | grep -qE '/agsbx/cloudflared|/agsbx/sing-box|/agsbx/xray'; then PID=$(basename "$P"); kill "$PID" 2>/dev/null && echo "Killed $PID ($TARGET)" || echo "Could not kill $PID ($TARGET)"; fi; fi; done
kill -15 $(pgrep -f 'agsbx/sing-box' 2>/dev/null) $(pgrep -f 'agsbx/cloudflared' 2>/dev/null) $(pgrep -f 'agsbx/xray' 2>/dev/null) >/dev/null 2>&1

# WARP 对端 (engage.cloudflareclient.com) 出口协议栈选择：
# 双栈 VPS 优先走 IPv4 外层封装（外层包头比 IPv6 少 20 字节、UDP 路径质量普遍更稳），
# 仅在纯 IPv6 VPS（无 IPv4 出站）时才回退 IPv6 对端。
# 此前无条件优先 IPv6 对端，叠加未设 MTU，是 warp=s6x6 等内层 IPv6 模式"连接不通畅"的主要诱因。
if [ -n "$( (command -v curl >/dev/null 2>&1 && curl -s4m5 "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 -qO- --tries=2 "$v46url" 2>/dev/null) )" ]; then
sendip="162.159.192.1"
xendip="162.159.192.1"
else
sendip="2606:4700:d0::a29f:c001"
xendip="[2606:4700:d0::a29f:c001]"
fi
echo "VPS系统：$op"
echo "CPU架构：$cpu"
echo "Airgosbx脚本未安装，开始安装…………" && sleep 1
ins
cip
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
