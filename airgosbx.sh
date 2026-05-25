#!/bin/sh
#============================================================
# Airgosbx - 安全加固版一键代理部署脚本
# 基于 yonggekkk/argosbx 二次开发
# 仓库：github.com/hugobaum/mimic
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
    allocated_port=$(shuf -i 15000-60000 -n 1)
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

enable_system_bbr() {
  # 自动检测并开启 Linux 系统内核的 TCP BBR 拥塞控制加速
  local current_congestion_control
  current_congestion_control=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
  if [ "${current_congestion_control}" = "bbr" ]; then
    echo "提示：检测到当前系统已经启用了 BBR 网络加速，无需重复开启。🚀"
    return
  fi

  echo "正在为您检测并开启系统级 TCP BBR 拥塞控制加速..."
  
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo "TCP BBR 拥塞控制加速已成功开启！🚀"
  else
    modprobe tcp_bbr >/dev/null 2>&1
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
      sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
      sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
      echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
      echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
      sysctl -p >/dev/null 2>&1
      echo "TCP BBR 拥塞控制加速已成功开启！🚀"
    else
      echo "警告：当前 VPS 系统内核版本较低，不支持 BBR 模块。建议您升级内核后再开启网络加速。😿"
    fi
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
[ -z "${xdnspt+x}" ] || xdns=yes
[ -z "${xicmppt+x}" ] || xicp=yes
if find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -Eq 'agsbx/(sing-box|xray)' || pgrep -f 'agsbx/sing-box' >/dev/null 2>&1 || pgrep -f 'agsbx/xray' >/dev/null 2>&1; then
if [ "$1" = "rep" ]; then
[ "$vwp" = yes ] || [ "$sop" = yes ] || [ "$vxp" = yes ] || [ "$ssp" = yes ] || [ "$vlp" = yes ] || [ "$vmp" = yes ] || [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$xhp" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || { echo "提示：rep重置协议时，请在脚本前至少设置一个协议变量哦! 💣"; exit; }
fi
else
[ "$1" = "del" ] || [ "$vwp" = yes ] || [ "$sop" = yes ] || [ "$vxp" = yes ] || [ "$ssp" = yes ] || [ "$vlp" = yes ] || [ "$vmp" = yes ] || [ "$hyp" = yes ] || [ "$tup" = yes ] || [ "$xhp" = yes ] || [ "$anp" = yes ] || [ "$arp" = yes ] || [ "$xhyp" = yes ] || [ "$xdns" = yes ] || [ "$xicp" = yes ] || { echo "提示：未安装airgosbx脚本，请在脚本前至少设置一个协议变量哦！💣"; exit; }
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
export port_xdns=${xdnspt:-''}
export flag_xicmp=${xicmppt:-''}
export xdnsym=${xdnsym:-''}
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
#============================================================
v46url="https://icanhazip.com"
agsbxurl="https://raw.githubusercontent.com/hugobaum/mimic/main/airgosbx.sh"
showmode(){
echo "主脚本：bash <(curl -Ls https://raw.githubusercontent.com/hugobaum/mimic/main/airgosbx.sh) 或 bash <(wget -qO- https://raw.githubusercontent.com/hugobaum/mimic/main/airgosbx.sh)"
echo "显示节点信息命令：agsbx list 【或者】 主脚本 list"
echo "重置变量组命令：自定义各种协议变量组 agsbx rep 【或者】 自定义各种协议变量组 主脚本 rep"
echo "更新脚本命令：原已安装的自定义各种协议变量组 主脚本 rep"
echo "更新Xray或Singbox内核命令：agsbx upx或ups 【或者】 主脚本 upx或ups"
echo "重启脚本命令：agsbx res 【或者】 主脚本 res"
echo "卸载脚本命令：agsbx del 【或者】 主脚本 del"
echo "双栈VPS显示IPv4/IPv6节点配置命令：ippz=4或6 agsbx list 【或者】 ippz=4或6 主脚本 list"
echo "域名证书变量：certym=你的域名（空值或不写则使用自签证书）；可选 certcrt=证书路径 certkey=私钥路径 acmem=邮箱"
echo "---------------------------------------------------------"
echo
}
#============================================================
# [第3段] 启动信息输出、系统环境检测、依赖安装（顺序执行区）
#============================================================
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "项目地址：github.com/hugobaum/sbxrago"
echo "基于 yonggekkk/argosbx 二次开发，已加固安全"
echo "Airgosbx一键无交互小钢炮脚本💣"
echo "当前版本：V26.5.25"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
hostname=$(uname -a | awk '{print $2}')
op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)
[ -z "$(systemd-detect-virt 2>/dev/null)" ] && vi=$(virt-what 2>/dev/null) || vi=$(systemd-detect-virt 2>/dev/null)
case $(uname -m) in
arm64|aarch64) cpu=arm64;;
amd64|x86_64) cpu=amd64;;
*) echo "目前脚本不支持$(uname -m)架构" && exit
esac
mkdir -pm 700 "$HOME/agsbx"
umask 077
if [ ! -f "$HOME/agsbx/sbx_update" ]; then
echo "执行脚本中，请稍后"
if command -v apk >/dev/null 2>&1; then
apk update >/dev/null 2>&1
apk add gcompat libc6-compat >/dev/null 2>&1
elif command -v apt >/dev/null 2>&1; then
apt update >/dev/null 2>&1 && apt install coreutils util-linux -y >/dev/null 2>&1
fi
touch "$HOME/agsbx/sbx_update"
fi
#============================================================
# [第4段] 网络检测与 WARP 配置函数
#   v4v6()   - 检测 VPS 的 IPv4/IPv6 连通性
#   warpsx() - WARP 密钥生成与路由策略配置
#============================================================
v4v6(){
v4=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- "$v46url" 2>/dev/null) )
v6=$( (command -v curl >/dev/null 2>&1 && curl -s6m5 "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 --tries=2 -qO- "$v46url" 2>/dev/null) )
v4dq=$( (command -v curl >/dev/null 2>&1 && curl -s4m5 https://ip.fm | sed -n 's/.*Location: //p' 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -4 --tries=2 -qO- https://ip.fm | grep '<span class="has-text-grey-light">Location:' | tail -n1 | sed -E 's/.*>Location: <\/span>([^<]+)<.*/\1/' 2>/dev/null) )
v6dq=$( (command -v curl >/dev/null 2>&1 && curl -s6m5 https://ip.fm | sed -n 's/.*Location: //p' 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 --tries=2 -qO- https://ip.fm | grep '<span class="has-text-grey-light">Location:' | tail -n1 | sed -E 's/.*>Location: <\/span>([^<]+)<.*/\1/' 2>/dev/null) )
}
warpsx(){
if [ "$wap" = yes ]; then
echo "正在获取安全的本地 WARP 网络身份..."
# 1. 使用 Xray 生成真实可用的 x25519 密钥对，避免回退到无效随机值
pvk=""
pub=""
if [ ! -f "$HOME/agsbx/xray" ]; then
upxray
fi
if [ -f "$HOME/agsbx/xray" ]; then
xkey=$("$HOME/agsbx/xray" x25519 2>/dev/null)
pvk=$(echo "$xkey" | awk '/Private key:/{print $3}')
pub=$(echo "$xkey" | awk '/Public key:/{print $3}')
fi
if [ -z "$pvk" ] || [ -z "$pub" ]; then
echo "错误：无法生成有效的 WARP 密钥对，终止安装。"
exit 1
fi
# 2. 直接向 Cloudflare 官方 API 注册，不经过任何第三方（确保私钥不泄露）
reg_json=$( (command -v curl >/dev/null 2>&1 && curl -sL "https://api.cloudflareclient.com/v0a2158/reg" -H "User-Agent: okhttp/3.12.1" -H "Content-Type: application/json" -d "{\"key\":\"$pub\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"model\":\"Linux\",\"serial_number\":\"\",\"locale\":\"en_US\"}") || echo "")
c_id=$(echo "$reg_json" | awk -F '"client_id":"' '{print $2}' | awk -F '"' '{print $1}')
if [ -n "$c_id" ]; then
wpv6='2606:4700:d0::a29f:c001'
# 从 client_id 解码提取前3个字节作为 reserved 绕过拦截
res=$(echo "$c_id" | base64 -d 2>/dev/null | od -v -An -t u1 | head -n1 | awk '{print "["$1", "$2", "$3"]"}')
if [ -z "$res" ]; then
echo "错误：无法解析 WARP reserved 字段，终止安装。"
exit 1
fi
else
echo "警告：Cloudflare WARP 官方 API 注册失败！网络可能受限。"
exit 1
fi
else
pvk="dummy"
pub="dummy"
res="[0, 0, 0]"
wpv6="2606:4700:d0::a29f:c001"
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
if command -v curl >/dev/null 2>&1; then
curl -s4m5 "$v46url" >/dev/null 2>&1 && v4_ok=true
elif command -v wget >/dev/null 2>&1; then
timeout 3 wget -4 --tries=2 -qO- "$v46url" >/dev/null 2>&1 && v4_ok=true
fi
if command -v curl >/dev/null 2>&1; then
curl -s6m5 "$v46url" >/dev/null 2>&1 && v6_ok=true
elif command -v wget >/dev/null 2>&1; then
timeout 3 wget -6 --tries=2 -qO- "$v46url" >/dev/null 2>&1 && v6_ok=true
fi
if [ "$v4_ok" = true ] && [ "$v6_ok" = true ]; then
case "$warp" in *s4*) sbyx='prefer_ipv4' ;; *) sbyx='prefer_ipv6' ;; esac
case "$warp" in *x4*) xryx='ForceIPv4v6' ;; *x*) xryx='ForceIPv6v4' ;; *) xryx='ForceIPv4v6' ;; esac
elif [ "$v4_ok" = true ] && [ "$v6_ok" != true ]; then
case "$warp" in *s4*) sbyx='ipv4_only' ;; *) sbyx='prefer_ipv6' ;; esac
case "$warp" in *x4*) xryx='ForceIPv4' ;; *x*) xryx='ForceIPv6v4' ;; *) xryx='ForceIPv4v6' ;; esac
elif [ "$v4_ok" != true ] && [ "$v6_ok" = true ]; then
case "$warp" in *s6*) sbyx='ipv6_only' ;; *) sbyx='prefer_ipv4' ;; esac
case "$warp" in *x6*) xryx='ForceIPv6' ;; *x*) xryx='ForceIPv4v6' ;; *) xryx='ForceIPv6v4' ;; esac
fi
}
#============================================================
# [第5段] 内核下载函数（含哈希校验）
#   upxray()    - 从 XTLS/Xray-core 官方下载 + SHA256 校验
#   upsingbox() - 从 SagerNet/sing-box 官方下载
#============================================================
upxray(){
# 从 Xray-core 官方仓库下载，并进行 SHA256 完整性校验
echo "正在从 XTLS/Xray-core 官方仓库下载 Xray 内核……"
case "$cpu" in
  amd64) xray_file="Xray-linux-64.zip" ;;
  arm64) xray_file="Xray-linux-arm64-v8a.zip" ;;
esac
xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/${xray_file}"
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
# 解压并安装
(command -v unzip >/dev/null 2>&1 && unzip -o "$xray_tmp" xray -d "$HOME/agsbx/" >/dev/null 2>&1) || (command -v busybox >/dev/null 2>&1 && busybox unzip -o "$xray_tmp" xray -d "$HOME/agsbx/" >/dev/null 2>&1)
chmod +x "$HOME/agsbx/xray"
rm -f "$xray_tmp" "$xray_dgst_tmp"
sbcore=$("$HOME/agsbx/xray" version 2>/dev/null | awk '/^Xray/{print $2}')
echo "已安装Xray正式版内核：$sbcore（来源：github.com/XTLS/Xray-core）"
}
upsingbox(){
# 从 Sing-box 官方仓库下载，并进行 SHA256 完整性校验
echo "正在从 SagerNet/sing-box 官方仓库下载 Sing-box 内核……"
# 获取最新版本号和 JSON 数据以备校验
sb_json=$( (command -v curl >/dev/null 2>&1 && curl -Ls "https://api.github.com/repos/SagerNet/sing-box/releases/latest") || (command -v wget >/dev/null 2>&1 && wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest") )
sb_ver=$(echo "$sb_json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
sb_ver_num=$(echo "$sb_ver" | sed 's/^v//')
if [ -z "$sb_ver_num" ]; then
  echo "错误：无法获取 Sing-box 最新版本号"
  exit 1
fi
echo "最新版本：$sb_ver"
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
# 解压并安装
tar -xzf "$sb_tmp" -C "$HOME/agsbx/" 2>/dev/null
# 将解压出来的文件夹里的内核提取出来，避免 tar 的 strip-components 不兼容导致的位置偏移
if [ -f "$HOME/agsbx/sing-box-${sb_ver_num}-linux-${cpu}/sing-box" ]; then
    mv -f "$HOME/agsbx/sing-box-${sb_ver_num}-linux-${cpu}/sing-box" "$HOME/agsbx/sing-box"
    rm -rf "$HOME/agsbx/sing-box-${sb_ver_num}-linux-${cpu}"
fi
rm -f "$sb_tmp"
chmod +x "$HOME/agsbx/sing-box"
sbcore=$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}')
echo "已安装Sing-box正式版内核：$sbcore（来源：github.com/SagerNet/sing-box）"
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
echo "========== TLS 证书信息 =========="
echo "证书结果：$cert_result"
[ -n "$cert_domain" ] && echo "申请域名：$cert_domain"
[ -n "$cert_sni" ] && echo "SNI/CN：$cert_sni"
[ -n "$cert_mode_now" ] && echo "证书模式：$cert_mode_now"
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
echo "=================================="
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
openssl req -new -x509 -days 90 -key "$selfsigned_key_file" -out "$selfsigned_cert_file" -subj "/CN=$random_sni" >/dev/null 2>&1
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
    echo -e "\033[33m警告：检测到本机的 80 端口已被其他服务占用！\033[0m"
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
bash "$acme_script" --home "$acme_home" --issue --standalone -d "$acme_domain" --keylength ec-256 --server letsencrypt --force >/dev/null 2>&1 || return 1
bash "$acme_script" --home "$acme_home" --install-cert -d "$acme_domain" --ecc --fullchain-file "$acme_cert_file" --key-file "$acme_key_file" >/dev/null 2>&1 || return 1
[ -s "$acme_cert_file" ] && [ -s "$acme_key_file" ] || return 1
echo "$acme_domain" > "$HOME/agsbx/sni.txt"
echo "ca" > "$HOME/agsbx/cert_mode"
record_tls_cert_paths "$acme_cert_file" "$acme_key_file"
tls_cert_source="ACME 自动申请成功"
}
setup_tls_certificate(){
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
installxray(){
echo
echo "=========启用xray内核========="
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
if [ -z "$port_xh" ] && [ ! -e "$HOME/agsbx/port_xh" ]; then
port_xh=$(get_free_port)
echo "$port_xh" > "$HOME/agsbx/port_xh"
elif [ -n "$port_xh" ]; then
echo "$port_xh" > "$HOME/agsbx/port_xh"
fi
port_xh=$(cat "$HOME/agsbx/port_xh")
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
          "path": "${uuid}-xh",
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
                "paddingMin": 32,
                "paddingMax": 128
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
if [ -z "$port_vx" ] && [ ! -e "$HOME/agsbx/port_vx" ]; then
port_vx=$(get_free_port)
echo "$port_vx" > "$HOME/agsbx/port_vx"
elif [ -n "$port_vx" ]; then
echo "$port_vx" > "$HOME/agsbx/port_vx"
fi
port_vx=$(cat "$HOME/agsbx/port_vx")
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
if [ -z "$port_vw" ] && [ ! -e "$HOME/agsbx/port_vw" ]; then
port_vw=$(get_free_port)
echo "$port_vw" > "$HOME/agsbx/port_vw"
elif [ -n "$port_vw" ]; then
echo "$port_vw" > "$HOME/agsbx/port_vw"
fi
port_vw=$(cat "$HOME/agsbx/port_vw")
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
if [ -z "$port_vl_re" ] && [ ! -e "$HOME/agsbx/port_vl_re" ]; then
port_vl_re=$(get_free_port)
echo "$port_vl_re" > "$HOME/agsbx/port_vl_re"
elif [ -n "$port_vl_re" ]; then
echo "$port_vl_re" > "$HOME/agsbx/port_vl_re"
fi
port_vl_re=$(cat "$HOME/agsbx/port_vl_re")
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
if [ -z "$port_xhy2" ] && [ ! -e "$HOME/agsbx/port_xhy2" ]; then
port_xhy2=$(get_free_port)
echo "$port_xhy2" > "$HOME/agsbx/port_xhy2"
elif [ -n "$port_xhy2" ]; then
echo "$port_xhy2" > "$HOME/agsbx/port_xhy2"
fi
port_xhy2=$(cat "$HOME/agsbx/port_xhy2")
echo "Xray-Hysteria2端口：$port_xhy2"
if [ -n "$xhyjpt" ]; then
setup_port_hopping "$xhyjpt" "$port_xhy2"
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
          "version": 2,
          "quicParams": {
            "congestion": "brutal",
            "force-brutal": true,
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
if [ -n "$xdnspt" ] && [ -n "$xdnsym" ]; then
if [ -z "$port_xdns" ] && [ ! -e "$HOME/agsbx/port_xdns" ]; then
port_xdns=$(get_free_port)
echo "$port_xdns" > "$HOME/agsbx/port_xdns"
elif [ -n "$port_xdns" ]; then
echo "$port_xdns" > "$HOME/agsbx/port_xdns"
fi
port_xdns=$(cat "$HOME/agsbx/port_xdns")
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
          "xdns": {
            "domain": "${xdnsym}",
            "downstreamDataA": true,
            "downstreamDataAAAA": true
          }
        }
      }
    },
EOF
fi
if [ -n "$xicmppt" ]; then
setcap cap_net_raw+ep "$HOME/agsbx/xray"
sysctl -w net.ipv4.icmp_echo_ignore_all=1
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
          "xicmp": {
            "listenIp": "0.0.0.0"
          }
        }
      }
    },
EOF
else
sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
fi
}

installsb(){
echo
echo "=========启用sing-box内核========="
if [ ! -e "$HOME/agsbx/sing-box" ]; then
upsingbox
fi
cat > "$HOME/agsbx/sb.json" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
EOF
insuuid
setup_tls_certificate
if [ -n "$hyp" ]; then
hyp=hypt
insobfspass
if [ -z "$port_hy2" ] && [ ! -e "$HOME/agsbx/port_hy2" ]; then
port_hy2=$(get_free_port)
echo "$port_hy2" > "$HOME/agsbx/port_hy2"
elif [ -n "$port_hy2" ]; then
echo "$port_hy2" > "$HOME/agsbx/port_hy2"
fi
port_hy2=$(cat "$HOME/agsbx/port_hy2")
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
if [ -z "$port_tu" ] && [ ! -e "$HOME/agsbx/port_tu" ]; then
port_tu=$(get_free_port)
echo "$port_tu" > "$HOME/agsbx/port_tu"
elif [ -n "$port_tu" ]; then
echo "$port_tu" > "$HOME/agsbx/port_tu"
fi
port_tu=$(cat "$HOME/agsbx/port_tu")
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
if [ -z "$port_an" ] && [ ! -e "$HOME/agsbx/port_an" ]; then
port_an=$(get_free_port)
echo "$port_an" > "$HOME/agsbx/port_an"
elif [ -n "$port_an" ]; then
echo "$port_an" > "$HOME/agsbx/port_an"
fi
port_an=$(cat "$HOME/agsbx/port_an")
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
if [ -z "$port_ar" ] && [ ! -e "$HOME/agsbx/port_ar" ]; then
port_ar=$(get_free_port)
echo "$port_ar" > "$HOME/agsbx/port_ar"
elif [ -n "$port_ar" ]; then
echo "$port_ar" > "$HOME/agsbx/port_ar"
fi
port_ar=$(cat "$HOME/agsbx/port_ar")
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
if [ -z "$port_ss" ] && [ ! -e "$HOME/agsbx/port_ss" ]; then
port_ss=$(get_free_port)
echo "$port_ss" > "$HOME/agsbx/port_ss"
elif [ -n "$port_ss" ]; then
echo "$port_ss" > "$HOME/agsbx/port_ss"
fi
sskey=$(cat "$HOME/agsbx/sskey")
port_ss=$(cat "$HOME/agsbx/port_ss")
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

#============================================================
# [第7段] 附加协议与出站配置函数
#   xrsbvm()  - Vmess-ws 协议配置
#   xrsbso()  - Socks5 协议配置
#   xrsbout() - JSON 闭合、outbound/routing 写入、服务启动
#============================================================
xrsbvm(){
if [ -n "$vmp" ]; then
vmp=vmpt
if [ -z "$port_vm_ws" ] && [ ! -e "$HOME/agsbx/port_vm_ws" ]; then
port_vm_ws=$(get_free_port)
echo "$port_vm_ws" > "$HOME/agsbx/port_vm_ws"
elif [ -n "$port_vm_ws" ]; then
echo "$port_vm_ws" > "$HOME/agsbx/port_vm_ws"
fi
port_vm_ws=$(cat "$HOME/agsbx/port_vm_ws")
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
if [ -z "$port_so" ] && [ ! -e "$HOME/agsbx/port_so" ]; then
port_so=$(get_free_port)
echo "$port_so" > "$HOME/agsbx/port_so"
elif [ -n "$port_so" ]; then
echo "$port_so" > "$HOME/agsbx/port_so"
fi
port_so=$(cat "$HOME/agsbx/port_so")
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
if [ "$wap" = warp ]; then
cat >> "$HOME/agsbx/xr.json" <<EOF
    ,
    {
      "tag": "x-warp-out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${pvk}",
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
# [第8段] 安装编排主函数
#   ins() - 按用户选择的协议组合调用各安装函数，
#           部署 Argo 隧道，注册快捷方式和 crontab
#============================================================
ins(){
enable_system_bbr
if [ "$hyp" != yes ] && [ "$tup" != yes ] && [ "$anp" != yes ] && [ "$arp" != yes ] && [ "$ssp" != yes ]; then
installxray
xrsbvm
xrsbso
warpsx
xrsbout
hyp="shyptargo"; tup="tuptargo"; anp="anptargo"; arp="arptargo"; ssp="ssptargo"
elif [ "$xhp" != yes ] && [ "$vlp" != yes ] && [ "$vxp" != yes ] && [ "$vwp" != yes ] && [ "$xhyp" != yes ] && [ "$xdns" != yes ] && [ "$xicp" != yes ]; then
installsb
xrsbvm
xrsbso
warpsx
xrsbout
xhp="xhptargo"; vlp="vlptargo"; vxp="vxptargo"; vwp="vwptargo"; xhyp="xhyptargo"; xdns="xdnstargo"; xicp="xicptargo"
else
installsb
installxray
xrsbvm
xrsbso
warpsx
xrsbout
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
echo "=========启用Cloudflared-argo内核========="
if [ ! -e "$HOME/agsbx/cloudflared" ]; then
argocore=$({ command -v curl >/dev/null 2>&1 && curl -Ls https://data.jsdelivr.com/v1/package/gh/cloudflare/cloudflared || wget -qO- https://data.jsdelivr.com/v1/package/gh/cloudflare/cloudflared; } | grep -Eo '"[0-9.]+"' | sed -n 1p | tr -d '",')
echo "下载Cloudflared-argo最新正式版内核：$argocore"
url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"; out="$HOME/agsbx/cloudflared"; (command -v curl>/dev/null 2>&1 && curl -Lo "$out" -# --retry 2 "$url") || (command -v wget>/dev/null 2>&1 && timeout 3 wget -O "$out" --tries=2 "$url")
chmod +x "$HOME/agsbx/cloudflared"
fi
if [ "$argo" = "vmpt" ]; then argoport=$(cat "$HOME/agsbx/port_vm_ws" 2>/dev/null); echo "Vmess" > "$HOME/agsbx/vlvm"; elif [ "$argo" = "vwpt" ]; then argoport=$(cat "$HOME/agsbx/port_vw" 2>/dev/null); echo "Vless" > "$HOME/agsbx/vlvm"; fi; echo "$argoport" > "$HOME/agsbx/argoport.log"
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
else
argoname='临时'
nohup "$HOME/agsbx/cloudflared" tunnel --url http://localhost:$(cat $HOME/agsbx/argoport.log) --edge-ip-version auto --no-autoupdate --protocol http2 > $HOME/agsbx/argo.log 2>&1 &
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
sleep 5
echo
if find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -Eq 'agsbx/(sing-box|xray)' || pgrep -f 'agsbx/sing-box' >/dev/null 2>&1 || pgrep -f 'agsbx/xray' >/dev/null 2>&1 ; then
[ -f ~/.bashrc ] || touch ~/.bashrc
sed -i '/agsbx/d' ~/.bashrc
SCRIPT_PATH="$HOME/bin/agsbx"
mkdir -p "$HOME/bin"
(command -v curl >/dev/null 2>&1 && curl -sL "$agsbxurl" -o "$SCRIPT_PATH") || (command -v wget >/dev/null 2>&1 && wget -qO "$SCRIPT_PATH" "$agsbxurl")
chmod +x "$SCRIPT_PATH"

sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' ~/.bashrc
sed -i '/export PATH="\$PATH:\$HOME\/bin"/d' ~/.bashrc
echo 'export PATH="$PATH:$HOME/bin"' >> "$HOME/.bashrc"
grep -qxF 'source ~/.bashrc' ~/.bash_profile 2>/dev/null || echo 'source ~/.bashrc' >> ~/.bash_profile
. ~/.bashrc 2>/dev/null
crontab -l > /tmp/crontab.tmp 2>/dev/null
if ! pidof systemd >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
sed -i '/agsbx\/sing-box/d' /tmp/crontab.tmp
sed -i '/agsbx\/xray/d' /tmp/crontab.tmp
if find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -q 'agsbx/sing-box' || pgrep -f 'agsbx/sing-box' >/dev/null 2>&1 ; then
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/sing-box run -c $HOME/agsbx/sb.json > $HOME/agsbx/sing-box.log 2>&1 &"' >> /tmp/crontab.tmp
fi
if find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -q 'agsbx/xray' || pgrep -f 'agsbx/xray' >/dev/null 2>&1 ; then
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/xray run -c $HOME/agsbx/xr.json > $HOME/agsbx/xray.log 2>&1 &"' >> /tmp/crontab.tmp
fi
fi
sed -i '/agsbx\/cloudflared/d' /tmp/crontab.tmp
if [ -n "$argo" ] && [ -n "$vmag" ]; then
if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
if ! pidof systemd >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $(cat $HOME/agsbx/sbargotoken.log 2>/dev/null) > $HOME/agsbx/argo.log 2>&1 &"' >> /tmp/crontab.tmp
fi
else
echo '@reboot sleep 10 && /bin/sh -c "nohup $HOME/agsbx/cloudflared tunnel --url http://localhost:$(cat $HOME/agsbx/argoport.log) --edge-ip-version auto --no-autoupdate --protocol http2 > $HOME/agsbx/argo.log 2>&1 &"' >> /tmp/crontab.tmp
fi
fi
crontab /tmp/crontab.tmp >/dev/null 2>&1
rm /tmp/crontab.tmp
echo "Airgosbx脚本进程启动成功，安装完毕" && sleep 2
else
echo "Airgosbx脚本进程未启动，安装失败" && exit
fi
}
#============================================================
# [第9段] 状态查询与节点信息展示函数
#   airgosbxstatus() - 显示三大内核运行状态
#   cip()            - 生成并输出所有节点订阅链接
#============================================================
airgosbxstatus(){
echo "=========当前三大内核运行状态========="
procs=$(find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null)
if echo "$procs" | grep -Eq 'agsbx/sing-box' || pgrep -f 'agsbx/sing-box' >/dev/null 2>&1; then
echo "Sing-box (版本V$("$HOME/agsbx/sing-box" version 2>/dev/null | awk '/version/{print $NF}'))：运行中"
else
echo "Sing-box：未启用"
fi
if echo "$procs" | grep -Eq 'agsbx/xray' || pgrep -f 'agsbx/xray' >/dev/null 2>&1; then
echo "Xray (版本V$("$HOME/agsbx/xray" version 2>/dev/null | awk '/^Xray/{print $2}'))：运行中"
else
echo "Xray：未启用"
fi
if echo "$procs" | grep -Eq 'agsbx/cloudflared' || pgrep -f 'agsbx/cloudflared' >/dev/null 2>&1; then
echo "Argo (版本V$("$HOME/agsbx/cloudflared" version 2>/dev/null | awk '{print $3}'))：运行中"
else
echo "Argo：未启用"
fi
}
cip(){
ipbest(){
serip=$( (command -v curl >/dev/null 2>&1 && (curl -s4m5 "$v46url" 2>/dev/null || curl -s6m5 "$v46url" 2>/dev/null) ) || (command -v wget >/dev/null 2>&1 && (timeout 3 wget -4 -qO- --tries=2 "$v46url" 2>/dev/null || timeout 3 wget -6 -qO- --tries=2 "$v46url" 2>/dev/null) ) )
if echo "$serip" | grep -q ':'; then
server_ip="[$serip]"
echo "$server_ip" > "$HOME/agsbx/server_ip.log"
else
server_ip="$serip"
echo "$server_ip" > "$HOME/agsbx/server_ip.log"
fi
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
echo "=========当前服务器本地IP情况========="
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
echo "*********************************************************"
echo "*********************************************************"
echo "Airgosbx脚本输出节点配置如下："
echo
case "$server_ip" in
104.28*|\[2a09*) echo "检测到有WARP的IP作为客户端地址 (104.28或者2a09开头的IP)，请把客户端地址上的WARP的IP手动更换为VPS本地IPV4或者IPV6地址" && sleep 3 ;;
esac
echo
ym_vl_re=$(cat "$HOME/agsbx/ym_vl_re" 2>/dev/null)
cfip() { echo $((RANDOM % 13 + 1)); }
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
# 构建 XHTTP 专属 Finalmask JSON 并 URL 编码（去除 fragment 避免 TCP 特征穿帮，仅保留 sudoku 强头部加密）
fm_xh_config="{\"tcp\":[{\"type\":\"sudoku\",\"settings\":{\"password\":\"$uuid\",\"paddingMin\":16,\"paddingMax\":64}}]}"
fm_xh_encoded=$(printf '%s' "$fm_xh_config" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
if grep xhttp-reality "$HOME/agsbx/xr.json" >/dev/null 2>&1; then
echo "💣【 Vlessenc-xhttp-reality-vision-fm 】支持ENC加密，节点信息如下："
port_xh=$(cat "$HOME/agsbx/port_xh")
vl_xh_link="vless://$uuid@$server_ip:$port_xh?encryption=$enkey&flow=xtls-rprx-vision&security=reality&sni=$ym_vl_re&fp=chrome&pbk=$public_key_x&sid=$short_id_x&type=xhttp&path=$uuid-xh&mode=auto&extra=$xh_extra_encoded&fm=$fm_xh_encoded#${sxname}vlessenc-xhttp-reality-vision-fm-$hostname"
echo "$vl_xh_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_xh_link"
echo
fi
if grep vless-xhttp "$HOME/agsbx/xr.json" >/dev/null 2>&1; then
echo "💣【 Vlessenc-xhttp-vision 】支持ENC加密，节点信息如下："
port_vx=$(cat "$HOME/agsbx/port_vx")
vl_vx_link="vless://$uuid@$server_ip:$port_vx?encryption=$enkey&flow=xtls-rprx-vision&type=xhttp&path=$uuid-vx&mode=auto&extra=$xh_extra_encoded#${sxname}vlessenc-xhttp-vision-$hostname"
echo "$vl_vx_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vx_link"
echo
if [ -f "$HOME/agsbx/cdnym" ]; then
echo "💣【 Vlessenc-xhttp-vision-cdn 】支持ENC加密，节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vl_vx_cdn_link="vless://$uuid@icook.hk:$port_vx?encryption=$enkey&flow=xtls-rprx-vision&type=xhttp&host=$xvvmcdnym&path=$uuid-vx&mode=auto&extra=$xh_extra_encoded#${sxname}vlessenc-xhttp-vision-cdn-$hostname"
echo "$vl_vx_cdn_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vx_cdn_link"
echo
fi
fi
if grep vless-ws "$HOME/agsbx/xr.json" >/dev/null 2>&1; then
echo "💣【 Vlessenc-ws-vision 】支持ENC加密，节点信息如下："
port_vw=$(cat "$HOME/agsbx/port_vw")
vl_vw_link="vless://$uuid@$server_ip:$port_vw?encryption=$enkey&flow=xtls-rprx-vision&type=ws&path=$uuid-vw#${sxname}vlessenc-ws-vision-$hostname"
echo "$vl_vw_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vw_link"
echo
if [ -f "$HOME/agsbx/cdnym" ]; then
echo "💣【 Vlessenc-ws-vision-cdn 】支持ENC加密，节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vl_vw_cdn_link="vless://$uuid@icook.hk:$port_vw?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$xvvmcdnym&path=$uuid-vw#${sxname}vlessenc-ws-vision-cdn-$hostname"
echo "$vl_vw_cdn_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_vw_cdn_link"
echo
fi
fi
if grep reality-vision "$HOME/agsbx/xr.json" >/dev/null 2>&1; then
echo "💣【 Vless-tcp-reality-vision-fm 】节点信息如下："
port_vl_re=$(cat "$HOME/agsbx/port_vl_re")
vl_link="vless://$uuid@$server_ip:$port_vl_re?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$ym_vl_re&fp=chrome&pbk=$public_key_x&sid=$short_id_x&type=tcp&headerType=none&fm=$fm_tcp_encoded#${sxname}vl-reality-vision-fm-$hostname"
echo "$vl_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_link"
echo
fi
if grep vless-kcp-xdns "$HOME/agsbx/xr.json" >/dev/null 2>&1; then
echo "💣【 Vless-kcp-xdns-fm 】备用DNS隧道，节点信息如下："
port_xdns=$(cat "$HOME/agsbx/port_xdns")
xdns_fm="{\"xdns\":{\"domain\":\"$xdnsym\",\"downstreamDataA\":true,\"downstreamDataAAAA\":true}}"
xdns_fm_encoded=$(printf '%s' "$xdns_fm" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
vl_xdns_link="vless://$uuid@$server_ip:$port_xdns?encryption=none&flow=&type=kcp&headerType=none&fm=$xdns_fm_encoded#${sxname}vless-kcp-xdns-fm-$hostname"
echo "$vl_xdns_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_xdns_link"
echo
fi
if grep vless-kcp-xicmp "$HOME/agsbx/xr.json" >/dev/null 2>&1; then
echo "💣【 Vless-kcp-xicmp-fm 】特种L3 Ping隧道，节点信息如下："
xicmp_fm="{\"xicmp\":{\"listenIp\":\"0.0.0.0\"}}"
xicmp_fm_encoded=$(printf '%s' "$xicmp_fm" | sed 's/{/%7B/g;s/}/%7D/g;s/"/%22/g;s/:/%3A/g;s/,/%2C/g;s/ //g;s/\[/%5B/g;s/\]/%5D/g')
vl_xicmp_link="vless://$uuid@$server_ip:0?encryption=none&flow=&type=kcp&headerType=none&fm=$xicmp_fm_encoded#${sxname}vless-kcp-xicmp-fm-$hostname"
echo "$vl_xicmp_link" >> "$HOME/agsbx/jh.txt"
echo "$vl_xicmp_link"
echo
fi
if grep ss-2022 "$HOME/agsbx/sb.json" >/dev/null 2>&1; then
echo "💣【 Shadowsocks-2022 】节点信息如下："
port_ss=$(cat "$HOME/agsbx/port_ss")
ss_link="ss://$(echo -n "2022-blake3-aes-128-gcm:$sskey@$server_ip:$port_ss" | safe_base64)#${sxname}Shadowsocks-2022-$hostname"
echo "$ss_link" >> "$HOME/agsbx/jh.txt"
echo "$ss_link"
echo
fi
if grep vmess-xr "$HOME/agsbx/xr.json" >/dev/null 2>&1 || grep vmess-sb "$HOME/agsbx/sb.json" >/dev/null 2>&1; then
echo "💣【 Vmess-ws 】节点信息如下："
port_vm_ws=$(cat "$HOME/agsbx/port_vm_ws")
vm_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vm-ws-$hostname\", \"add\": \"$server_ip\", \"port\": \"$port_vm_ws\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"www.bing.com\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
echo "$vm_link" >> "$HOME/agsbx/jh.txt"
echo "$vm_link"
echo
if [ -f "$HOME/agsbx/cdnym" ]; then
echo "💣【 Vmess-ws-cdn 】节点信息如下："
echo "注：默认地址 icook.hk 可自行更换优选IP域名，如是回源端口需手动修改443或者80系端口"
vm_cdn_link="vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${sxname}vm-ws-cdn-$hostname\", \"add\": \"icook.hk\", \"port\": \"$port_vm_ws\", \"id\": \"$uuid\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$xvvmcdnym\", \"path\": \"/$uuid-vm\", \"tls\": \"\"}" | safe_base64)"
echo "$vm_cdn_link" >> "$HOME/agsbx/jh.txt"
echo "$vm_cdn_link"
echo
fi
fi
if grep anytls-sb "$HOME/agsbx/sb.json" >/dev/null 2>&1; then
echo "💣【 AnyTLS 】节点信息如下："
port_an=$(cat "$HOME/agsbx/port_an")
ran_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
if [ "$cert_mode" = "ca" ] && [ -n "$ran_sni" ]; then
an_link="anytls://$uuid@$server_ip:$port_an?sni=$ran_sni&insecure=0&allowInsecure=0#${sxname}anytls-$hostname"
else
an_link="anytls://$uuid@$server_ip:$port_an?insecure=1&allowInsecure=1#${sxname}anytls-$hostname"
fi
echo "$an_link" >> "$HOME/agsbx/jh.txt"
echo "$an_link"
echo
fi
if grep anyreality-sb "$HOME/agsbx/sb.json" >/dev/null 2>&1; then
echo "💣【 Any-Reality 】节点信息如下："
port_ar=$(cat "$HOME/agsbx/port_ar")
ar_link="anytls://$uuid@$server_ip:$port_ar?security=reality&sni=$ym_vl_re&fp=chrome&pbk=$public_key_s&sid=$short_id_s&type=tcp&headerType=none#${sxname}any-reality-$hostname"
echo "$ar_link" >> "$HOME/agsbx/jh.txt"
echo "$ar_link"
echo
fi
if grep hy2-sb "$HOME/agsbx/sb.json" >/dev/null 2>&1; then
echo "💣【 Hysteria2 】节点信息如下："
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
if [ "$cert_mode" = "ca" ] && [ -n "$ran_sni" ]; then
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
fi
if grep hy2-xr "$HOME/agsbx/xr.json" >/dev/null 2>&1; then
echo "💣【 Xray-Hysteria2 】节点信息如下："
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
if [ "$cert_mode" = "ca" ] && [ -n "$ran_sni" ]; then
xhy2_link="hysteria2://$uuid@$server_ip:$port_xhy2?security=tls&alpn=h3&sni=$ran_sni&insecure=0&allowInsecure=0${xby_mport}#${sxname}xray-hy2-$hostname"
else
xhy2_link="hysteria2://$uuid@$server_ip:$port_xhy2?pinSHA256=$cert_hash&alpn=h3&sni=$ran_sni&insecure=1&allowInsecure=1${xby_mport}#${sxname}xray-hy2-$hostname"
fi
echo "$xhy2_link" >> "$HOME/agsbx/jh.txt"
echo "$xhy2_link"
echo
fi
if grep tuic5-sb "$HOME/agsbx/sb.json" >/dev/null 2>&1; then
echo "💣【 Tuic 】节点信息如下："
port_tu=$(cat "$HOME/agsbx/port_tu")
ran_sni=$(cat "$HOME/agsbx/sni.txt" 2>/dev/null)
cert_mode=$(cat "$HOME/agsbx/cert_mode" 2>/dev/null)
if [ "$cert_mode" = "ca" ] && [ -n "$ran_sni" ]; then
tuic5_link="tuic://$uuid:$uuid@$server_ip:$port_tu?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$ran_sni&insecure=0&allow_insecure=0&allowInsecure=0#${sxname}tuic-$hostname"
else
tuic5_link="tuic://$uuid:$uuid@$server_ip:$port_tu?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$ran_sni&allow_insecure=1&allowInsecure=1#${sxname}tuic-$hostname"
fi
echo "$tuic5_link" >> "$HOME/agsbx/jh.txt"
echo "$tuic5_link"
echo
fi
if grep socks5-xr "$HOME/agsbx/xr.json" >/dev/null 2>&1 || grep socks5-sb "$HOME/agsbx/sb.json" >/dev/null 2>&1; then
echo "💣【 Socks5 】客户端信息如下："
port_so=$(cat "$HOME/agsbx/port_so")
echo "请配合其他应用内置代理使用，勿做节点直接使用"
echo "客户端地址：$server_ip"
echo "客户端端口：$port_so"
echo "客户端用户名：$uuid"
echo "客户端密码：$uuid"
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
elif [ "$vlvm" = "Vless" ]; then
vwatls_link1="vless://$uuid@icook.hk:443?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$uuid-vw&security=tls&sni=$argodomain&fp=chrome&insecure=0&allowInsecure=0#${sxname}vlessenc-ws-tls-vision-argo-$hostname"
echo "$vwatls_link1" >> "$HOME/agsbx/jh.txt"
vwa_link2="vless://$uuid@icook.hk:80?encryption=$enkey&flow=xtls-rprx-vision&type=ws&host=$argodomain&path=$uuid-vw&security=none#${sxname}vlessenc-ws-vision-argo-$hostname"
echo "$vwa_link2" >> "$HOME/agsbx/jh.txt"
fi
sbtk=$(cat "$HOME/agsbx/sbargotoken.log" 2>/dev/null)
if [ -n "$sbtk" ]; then
nametn="Argo固定隧道token：$sbtk"
fi
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
echo "---------------------------------------------------------"
echo "$argoshow"
echo
echo "---------------------------------------------------------"
echo "聚合节点信息，请进入 $HOME/agsbx/jh.txt 文件目录查看或者运行 cat $HOME/agsbx/jh.txt 查看"
echo "========================================================="
# 安全加固：全局收紧敏感文件权限（阻断多用户环境下的未授权文件读取）
find "$HOME/agsbx" -type d -exec chmod 700 {} + 2>/dev/null
find "$HOME/agsbx" -type f -exec chmod 600 {} + 2>/dev/null
chmod 700 "$HOME/agsbx/xray" "$HOME/agsbx/sing-box" "$HOME/agsbx/cloudflared" 2>/dev/null
echo "相关快捷方式如下：(首次安装成功后需重连SSH，agsbx快捷方式才可生效)"
showmode
}
#============================================================
# [第10段] 卸载与重启工具函数
#   cleandel()  - 清理进程、服务、crontab、环境变量
#   xrestart()  - 重启 Xray
#   sbrestart() - 重启 Sing-box
#============================================================
cleandel(){
sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
cleanup_port_hopping
for P in /proc/[0-9]*; do if [ -L "$P/exe" ]; then TARGET=$(readlink -f "$P/exe" 2>/dev/null); if echo "$TARGET" | grep -qE '/agsbx/cloudflared|/agsbx/sing-box|/agsbx/xray'; then PID=$(basename "$P"); kill "$PID" 2>/dev/null; fi; fi; done
kill -15 $(pgrep -f 'agsbx/sing-box' 2>/dev/null) $(pgrep -f 'agsbx/cloudflared' 2>/dev/null) $(pgrep -f 'agsbx/xray' 2>/dev/null) >/dev/null 2>&1
sed -i '/agsbx/d' ~/.bashrc
sed -i '/export PATH="\$HOME\/bin:\$PATH"/d' ~/.bashrc
sed -i '/export PATH="\$PATH:\$HOME\/bin"/d' ~/.bashrc
. ~/.bashrc 2>/dev/null
crontab -l > /tmp/crontab.tmp 2>/dev/null
sed -i '/agsbx\/sing-box/d' /tmp/crontab.tmp
sed -i '/agsbx\/xray/d' /tmp/crontab.tmp
sed -i '/agsbx\/cloudflared/d' /tmp/crontab.tmp
crontab /tmp/crontab.tmp >/dev/null 2>&1
rm /tmp/crontab.tmp
rm -rf  "$HOME/bin/agsbx"
if pidof systemd >/dev/null 2>&1; then
for svc in xr sb argo; do
systemctl stop "$svc" >/dev/null 2>&1
systemctl disable "$svc" >/dev/null 2>&1
done
rm -rf /etc/systemd/system/{xr.service,sb.service,argo.service}
elif command -v rc-service >/dev/null 2>&1; then
for svc in sing-box xray argo; do
rc-service "$svc" stop >/dev/null 2>&1
rc-update del "$svc" default >/dev/null 2>&1
done
rm -rf /etc/init.d/{sing-box,xray,argo}
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

#============================================================
# [第11段] 命令路由：根据 $1 参数分发子命令
#   del  - 卸载  |  rep  - 重置协议  |  list - 显示节点
#   upx  - 更新Xray  |  ups - 更新Sing-box  |  res - 重启
#============================================================
if [ "$1" = "del" ]; then
cleandel
rm -rf sbx_update "$HOME/agsbx" "$HOME/agsb"
echo "卸载完成"
echo "欢迎继续使用Airgosbx一键无交互小钢炮脚本💣" && sleep 2
echo
showmode
exit
elif [ "$1" = "rep" ]; then
cleandel
rm -rf "$HOME/agsbx"/{sb.json,xr.json,sbargoym.log,sbargotoken.log,argo.log,argoport.log,cdnym,name}
echo "Airgosbx重置协议完成，开始更新相关协议变量……" && sleep 2
echo
elif [ "$1" = "list" ]; then
cip
exit
elif [ "$1" = "upx" ]; then
for P in /proc/[0-9]*; do [ -L "$P/exe" ] || continue; TARGET=$(readlink -f "$P/exe" 2>/dev/null) || continue; case "$TARGET" in *"/agsbx/x"*) kill "$(basename "$P")" 2>/dev/null ;; esac; done
kill -15 $(pgrep -f 'agsbx/xray' 2>/dev/null) >/dev/null 2>&1
upxray && xrestart && echo "Xray内核更新完成" && sleep 2 && cip
exit
elif [ "$1" = "ups" ]; then
for P in /proc/[0-9]*; do [ -L "$P/exe" ] || continue; TARGET=$(readlink -f "$P/exe" 2>/dev/null) || continue; case "$TARGET" in *"/agsbx/s"*) kill "$(basename "$P")" 2>/dev/null ;; esac; done
kill -15 $(pgrep -f 'agsbx/sing-box' 2>/dev/null) >/dev/null 2>&1
upsingbox && sbrestart && echo "Sing-box内核更新完成" && sleep 2 && cip
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
*"/agsbx/c"*)
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
nohup $HOME/agsbx/cloudflared tunnel --url http://localhost:$(cat $HOME/agsbx/argoport.log 2>/dev/null) --edge-ip-version auto --no-autoupdate --protocol http2 > $HOME/agsbx/argo.log 2>&1 &
fi
fi
;;
esac
done
sleep 5 && echo "重启完成" && sleep 3 && cip
exit
fi
#============================================================
# [第12段] 主入口：检测是否已安装，决定安装流程或显示状态
# 注意：必须放在最后，因为前面的函数定义需要先被 Shell 加载
#============================================================
if ! find /proc/*/exe -type l 2>/dev/null | grep -E '/proc/[0-9]+/exe' | xargs -r readlink 2>/dev/null | grep -Eq 'agsbx/(sing-box|xray)' && ! pgrep -f 'agsbx/sing-box' >/dev/null 2>&1 && ! pgrep -f 'agsbx/xray' >/dev/null 2>&1; then
for P in /proc/[0-9]*; do if [ -L "$P/exe" ]; then TARGET=$(readlink -f "$P/exe" 2>/dev/null); if echo "$TARGET" | grep -qE '/agsbx/cloudflared|/agsbx/sing-box|/agsbx/xray'; then PID=$(basename "$P"); kill "$PID" 2>/dev/null && echo "Killed $PID ($TARGET)" || echo "Could not kill $PID ($TARGET)"; fi; fi; done
kill -15 $(pgrep -f 'agsbx/sing-box' 2>/dev/null) $(pgrep -f 'agsbx/cloudflared' 2>/dev/null) $(pgrep -f 'agsbx/xray' 2>/dev/null) >/dev/null 2>&1

if [ -n "$( (command -v curl >/dev/null 2>&1 && curl -s6m5 "$v46url" 2>/dev/null) || (command -v wget >/dev/null 2>&1 && timeout 3 wget -6 -qO- --tries=2 "$v46url" 2>/dev/null) )" ]; then
sendip="2606:4700:d0::a29f:c001"
xendip="[2606:4700:d0::a29f:c001]"
else
sendip="162.159.192.1"
xendip="162.159.192.1"
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
