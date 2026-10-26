#!/usr/bin/env bash
# 可重复的 A/B 测量（不修改手机设置，只产生短时负载）。
# 用法：scripts/device/bench.sh <标签> [cold|sustain|mem|all]
# 输出同时写入 docs/bench/<标签>-<日期>.txt。
# 测试前请：充电线拔掉或固定为同一状态、屏幕常亮、室温和电量尽量一致、关闭省电模式。
set -u
LABEL="${1:?用法: bench.sh <标签> [cold|sustain|mem|all]}"
WHAT="${2:-all}"
APPS="${BENCH_APPS:-com.android.settings com.android.chrome com.miui.gallery com.android.mms com.miui.calculator}"
RUNS="${BENCH_RUNS:-10}"
SUSTAIN_SECS="${BENCH_SUSTAIN_SECS:-600}"
OUT="$(cd "$(dirname "$0")/../.." && pwd)/docs/bench/${LABEL}-$(date +%Y%m%d).txt"

r() { adb shell "su -c '$1'" 2>/dev/null | tr -d '\r'; }
adb get-state >/dev/null 2>&1 || { echo "adb 未连接设备"; exit 2; }
exec > >(tee "$OUT") 2>&1

median() { sort -n | awk '{a[NR]=$1} END{if(NR==0)print "NA"; else print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

echo "# bench $LABEL $(date)"
echo "kernel: $(r 'uname -r')  $(r 'uname -v')"
echo "zram: $(r 'cat /sys/block/zram0/comp_algorithm')  tcp: $(r 'cat /proc/sys/net/ipv4/tcp_congestion_control')"
echo "battery: $(r 'cat /sys/class/power_supply/battery/capacity')%  temp(0.1C): $(r 'cat /sys/class/power_supply/battery/temp')"

if [ "$WHAT" = all ] || [ "$WHAT" = cold ]; then
  echo
  echo "## 冷启动 am start -W TotalTime（ms），$RUNS 次取中位数"
  for pkg in $APPS; do
    if ! adb shell pm list packages "$pkg" | grep -q "package:$pkg$"; then echo "$pkg: 未安装，跳过"; continue; fi
    T=""
    for _ in $(seq "$RUNS"); do
      adb shell am force-stop "$pkg" >/dev/null
      sleep 2
      t=$(adb shell "am start -W -S \$(cmd package resolve-activity --brief $pkg | tail -1)" | tr -d '\r' | awk '/TotalTime/{print $2}')
      [ -n "$t" ] && T="$T$t"$'\n'
      adb shell input keyevent KEYCODE_HOME >/dev/null
      sleep 1
    done
    echo "$pkg: median=$(printf '%s' "$T" | median)  samples=$(printf '%s' "$T" | tr '\n' ' ')"
    adb shell am force-stop "$pkg" >/dev/null
  done
fi

if [ "$WHAT" = all ] || [ "$WHAT" = sustain ]; then
  echo
  echo "## 持续性能：全核满载 ${SUSTAIN_SECS}s，每 10s 记录各簇频率和最高温"
  CORES=$(r 'grep -c ^processor /proc/cpuinfo')
  # 每个核一个 busy loop，由 timeout 到点自行退出，不依赖 pkill
  LOAD=$(mktemp)
  printf '#!/system/bin/sh\nfor i in $(seq %s); do timeout %s sh -c "while :; do :; done" &\ndone\nwait\n' "$CORES" "$((SUSTAIN_SECS + 5))" > "$LOAD"
  adb push "$LOAD" /data/local/tmp/bench_load.sh >/dev/null && rm -f "$LOAD"
  adb shell "su -c 'sh /data/local/tmp/bench_load.sh'" >/dev/null 2>&1 &
  LOADER=$!
  POLICIES=$(r 'ls -d /sys/devices/system/cpu/cpufreq/policy*' | xargs -n1 basename)
  echo "time_s $(for p in $POLICIES; do printf '%s_khz ' "$p"; done) max_temp_mC"
  : > /tmp/bench_sustain.$$
  for t in $(seq 0 10 "$SUSTAIN_SECS"); do
    FREQS=$(r "for p in $POLICIES; do cat /sys/devices/system/cpu/cpufreq/\$p/scaling_cur_freq; done" | tr '\n' ' ')
    TEMP=$(r 'cat /sys/class/thermal/thermal_zone*/temp' | sort -n | tail -1)
    echo "$t $FREQS$TEMP" | tee -a /tmp/bench_sustain.$$ >/dev/null
    echo "$t $FREQS$TEMP"
    sleep 10
  done
  kill "$LOADER" 2>/dev/null
  r 'rm -f /data/local/tmp/bench_load.sh' >/dev/null
  # 降频比例：大核簇（最后一个 policy）后 5 分钟均值 / 前 60 秒均值
  awk -v n="$(echo "$POLICIES" | wc -w)" -v total="$SUSTAIN_SECS" '
    { f=$(1+n) } $1<=60 {a+=f;na++} $1>=total-300 {b+=f;nb++}
    END { if(na&&nb) printf "降频比例（最后一簇后5分钟/前60秒）: %.3f\n", (b/nb)/(a/na) }' /tmp/bench_sustain.$$
  rm -f /tmp/bench_sustain.$$
  echo "结束电池温度(0.1C): $(r 'cat /sys/class/power_supply/battery/temp')"
fi

if [ "$WHAT" = all ] || [ "$WHAT" = mem ]; then
  echo
  echo "## 内存"
  echo "mm_stat: $(r 'cat /sys/block/zram0/mm_stat')"
  r 'awk "{print}" /sys/block/zram0/mm_stat' | awk '{ if($2>0) printf "压缩比: %.2f:1\n", $1/$2 }'
  echo "PSI memory: $(r 'cat /proc/pressure/memory' | tr '\n' ' ')"
  echo "MemAvailable/SwapFree: $(r 'grep -E "MemAvailable|SwapFree" /proc/meminfo' | tr -s ' ' | tr '\n' ' ')"
fi
echo
echo "已保存: $OUT"
