#!/usr/bin/env bash
# 刷入新内核后的健康检查（只读，不改手机任何设置）。
# 用法：scripts/device/verify.sh [期望模块数，默认 492]
# 需要 adb 已连接且 su 可用（SukiSU 授权 shell）。
set -u
EXPECT_MODULES="${1:-492}"
FAIL=0

# 在手机上以 root 执行一条命令；命令里不要用单引号
r() { adb shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }

ok()   { printf '  [ OK ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=1; }
info() { printf '  [INFO] %s\n' "$1"; }

adb get-state >/dev/null 2>&1 || { echo "adb 未连接设备"; exit 2; }
[ "$(r id -u)" = "0" ] || { echo "su 不可用，请先在 SukiSU 管理器里授权 shell"; exit 2; }

echo "== 内核 =="
info "uname -r: $(r 'uname -r')"
info "uname -v: $(r 'uname -v')"

echo "== 开机状态 =="
[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ] && ok "sys.boot_completed=1" || bad "sys.boot_completed 不是 1"

echo "== vendor 模块 =="
N=$(r 'lsmod | wc -l')
if [ "${N:-0}" -ge "$EXPECT_MODULES" ]; then ok "已加载模块 $N（基线 $EXPECT_MODULES）"; else bad "已加载模块 $N，低于基线 $EXPECT_MODULES"; fi

echo "== dmesg 异常 =="
BAD=$(r 'dmesg | grep -E "disagrees about version of symbol|Unknown symbol|Kernel panic" | head -5')
if [ -z "$BAD" ]; then ok "没有符号版本不一致 / Unknown symbol / panic"; else bad "dmesg 有异常："; printf '%s\n' "$BAD"; fi

echo "== 内存 =="
info "ZRAM 算法: $(r 'cat /sys/block/zram0/comp_algorithm')"
info "ZRAM 大小: $(r 'cat /sys/block/zram0/disksize')"
info "swappiness: $(r 'cat /proc/sys/vm/swappiness')"
info "MGLRU: $(r 'cat /sys/kernel/mm/lru_gen/enabled')"

echo "== 网络 =="
info "TCP 拥塞算法: $(r 'cat /proc/sys/net/ipv4/tcp_congestion_control')"
info "可用算法: $(r 'cat /proc/sys/net/ipv4/tcp_available_congestion_control')"
info "默认 qdisc: $(r 'cat /proc/sys/net/core/default_qdisc')"

echo "== KernelSU / SUSFS / KPM =="
r 'ls /proc/config.gz' >/dev/null && info "存在 /proc/config.gz"
CFG=$(r 'zcat /proc/config.gz | grep -E "^CONFIG_(KSU|KPM)"')
printf '%s\n' "$CFG" | grep -q '^CONFIG_KSU=y' && ok "CONFIG_KSU=y" || bad "CONFIG_KSU 未启用"
printf '%s\n' "$CFG" | grep -q '^CONFIG_KSU_SUSFS=y' && ok "CONFIG_KSU_SUSFS=y" || bad "CONFIG_KSU_SUSFS 未启用"
printf '%s\n' "$CFG" | grep -q '^CONFIG_KPM=y' && ok "CONFIG_KPM=y（运行时桥需刷 AK3 时选「KPM 补丁」）" || info "CONFIG_KPM 未启用"

echo "== pstore =="
P=$(r 'ls /sys/fs/pstore')
[ -z "$P" ] && ok "pstore 为空（上次没有崩溃记录）" || info "pstore 有记录：$P"

echo
[ "$FAIL" = 0 ] && echo "结果：通过" || echo "结果：有失败项"
exit "$FAIL"
