#!/usr/bin/env bash
# 应用 SUSFS 补丁及 android14-6.1 所需的上下文修复（SukiSU Ultra 内置 SUSFS 支持）
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

# 列出当前目录下不属于上游的 .rej（相对路径，已排序）。
# 上游分支可能自带已提交的 .rej，那不是本补丁的冲突；但 patch 失败时会覆盖同名文件，
# 所以只有「被 git 跟踪且未改动」的才视为上游自带。
list_upstream_rej() {
  git ls-files -- '*.rej' 2>/dev/null | while IFS= read -r f; do
    git diff --quiet -- "$f" 2>/dev/null && echo "$f"
  done
}
list_untracked_rej() {
  comm -23 \
    <(find . -type f -name '*.rej' | sed 's|^\./||' | sort) \
    <(list_upstream_rej | sort)
}

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

echo "$KSU_VARIANT 使用内置 SUSFS 支持"

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# 兼容缺少 VMA padding 接口的 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

# 临时调整源码上下文，使 SUSFS 主补丁可以匹配（打完补丁后还原）
if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
  echo "临时调整 Android 14 6.1 sched.h 上下文"
  sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
fi
if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
  echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
  sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
fi
if [[ "$CURRENT_SUB" -ge 157 ]]; then
  echo "临时调整 Android 14 6.1 namespace.c 上下文"
  sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

patch -p1 < "$SUSFS_PATCH" || true

# 为尚未提供 SU 会话 FD 接口的 SukiSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
  EXEC_HELPER="ksu_install_su_fd"
elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
  EXEC_HELPER="ksu_handle_post_execveat_sucompat"
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游补丁可能把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在
# susfs_statfs_by_dentry 之后，clang -Werror 会报隐式声明；声明晚于使用时前移
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c; then
  STATFS_USE=$(grep -n 'if (!susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  STATFS_DECL=$(grep -n '^extern int susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  if [[ -n "$STATFS_USE" && -n "$STATFS_DECL" && "$STATFS_DECL" -gt "$STATFS_USE" ]] \
    && grep -q '^static int susfs_statfs_by_dentry(' fs/statfs.c; then
    echo "前移 statfs.c 中 susfs_sus_kstat_spoof_vfs_statfs 的声明"
    sed -i '/^static int susfs_statfs_by_dentry(/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' fs/statfs.c
  fi
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件，上游自带的 .rej 不计入
mapfile -t SUSFS_REJ_FILES < <(list_untracked_rej)
SUSFS_REJ_COUNT=${#SUSFS_REJ_FILES[@]}
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  printf '%s\n' "${SUSFS_REJ_FILES[@]}"
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$CURRENT_SUB" -le 25 ]]; then
  sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
fi
if [[ "$CURRENT_SUB" -le 141 ]]; then
  echo "还原 Android 14 6.1 base.c 临时调整"
  sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
fi
if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
  echo "还原 Android 14 6.1 namespace.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi
