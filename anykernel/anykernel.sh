### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Xiaomi 14（houji）6.1.138 内核的刷入脚本（基于 WildKernels/AnyKernel3 gki-2.0 的 tools/）

### AnyKernel setup
# global properties
properties() { '
kernel.string=GKI SukiSU Ultra + SUSFS (Emqo/GKI_SukiSU_6.1)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
do.check_boot_version=0
device.name1=houji
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
keycheck.timeout=10
'; } # end properties


### AnyKernel install
## boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

# GKI 检查：本包只含 6.1 内核
kernel_version=$(cat /proc/version | awk -F '-' '{print $1}' | awk '{print $3}')
case $kernel_version in
    6.1*) gki_supported=true ;;
    *) gki_supported=false ;;
esac

ui_print " " "  -> 当前内核: $kernel_version, 6.1 GKI: $gki_supported"
$gki_supported || abort "  -> 当前不是 6.1 GKI 内核，中止。"

# boot install
split_boot

if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
    unpack_ramdisk
    write_boot
else
    flash_boot
fi

ui_print " "
ui_print "提示：本内核已内置 KernelSU (SukiSU Ultra)。"
ui_print "如果 init_boot 之前被管理器修补过（LKM 模式），"
ui_print "请先把 init_boot 还原成原厂镜像，否则会出现两套 KernelSU。"
ui_print " "
ui_print "https://github.com/Emqo/GKI_SukiSU_6.1"
ui_print " "
