#!/bin/bash
#======================================================================================================================
# https://github.com/ophub/amlogic-s9xxx-openwrt
# Description: Automatically Packaged OpenWrt for S9xxx-Boxs and Phicomm-N1
# Function: Use Flippy's kernrl files for amlogic-s9xxx to build openwrt for S9xxx-Boxs and Phicomm-N1
# Copyright (C) 2020 Flippy's kernrl files for amlogic-s9xxx
# Copyright (C) 2020 https://github.com/tuanqing/mknop
# Copyright (C) 2020 https://github.com/ophub/amlogic-s9xxx-openwrt
#======================================================================================================================

#===== Do not modify the following parameter settings, Start =====
build_openwrt=("s905x3" "s905x2" "s922x" "s905x" "s905d" "s912")
make_path=${PWD}
tmp_path="tmp"
out_path="out"
amlogic_path="amlogic-s9xxx"
openwrt_path="openwrt-armvirt"
kernel_path="amlogic-kernel"
commonfiles_path="common-files"
uboot_path=${make_path}/${amlogic_path}/u-boot
installfiles_path=${make_path}/${amlogic_path}/install-program/files
#===== Do not modify the following parameter settings, End =======

# Set firmware size ( ROOT_MB must be ≥ 256 )
SKIP_MB=16
BOOT_MB=256
ROOT_MB=1024

tag() {
    echo -e " [ \033[1;36m ${1} \033[0m ]"
}

process() {
    echo -e " [ \033[1;32m ${build} \033[0m - \033[1;32m ${kernel} \033[0m ] ${1}"
}

die() {
    error "${1}" && exit 1
}

error() {
    echo -e " [ \033[1;31m Error \033[0m ] ${1}"
}

loop_setup() {
    loop=$(losetup -P -f --show "${1}")
    [ ${loop} ] || die "losetup ${1} failed."
}

cleanup() {
    cd ${make_path}
    for x in $(lsblk | grep $(pwd) | grep -oE 'loop[0-9]+' | sort | uniq); do
        umount -f /dev/${x}p* 2>/dev/null
        losetup -d /dev/${x} 2>/dev/null
    done
    losetup -D
    rm -rf ${tmp_path}
}

extract_openwrt() {
    cd ${make_path}
    local firmware="${openwrt_path}/${firmware}"
    local suffix="${firmware##*.}"
    mount="${tmp_path}/mount"
    root_comm="${tmp_path}/root_comm"

    mkdir -p ${mount} ${root_comm}
    while true; do
        case "${suffix}" in
        tar)
            tar -xf ${firmware} -C ${root_comm}
            break
            ;;
        gz)
            if ls ${firmware} | grep -q ".tar.gz$"; then
                tar -xzf ${firmware} -C ${root_comm}
                break
            else
                tmp_firmware="${tmp_path}/${firmware##*/}"
                tmp_firmware=${tmp_firmware%.*}
                gzip -d ${firmware} -c > ${tmp_firmware}
                firmware=${tmp_firmware}
                suffix=${firmware##*.}
            fi
            ;;
        img)
            loop_setup ${firmware}
            if ! mount -r ${loop}p2 ${mount}; then
                if ! mount -r ${loop}p1 ${mount}; then
                    die "mount ${loop} failed!"
                fi
            fi
            cp -rf ${mount}/* ${root_comm} && sync
            umount -f ${mount}
            losetup -d ${loop}
            break
            ;;
        ext4)
            if ! mount -r -o loop ${firmware} ${mount}; then
                die "mount ${firmware} failed!"
            fi
            cp -rf ${mount}/* ${root_comm} && sync
            umount -f ${mount}
            break
            ;;
        *)
            die "This script only supports rootfs.tar[.gz], ext4-factory.img[.gz], root.ext4[.gz] six formats."
            ;;
        esac
    done

    rm -rf ${root_comm}/lib/modules/*/
}

extract_armbian() {
    cd ${make_path}
    build_op=${1}
    kernel_dir="${amlogic_path}/${kernel_path}/kernel/${kernel}"
    # root_dir="${amlogic_path}/${kernel_path}/root"
    root="${tmp_path}/${kernel}/${build_op}/root"
    boot="${tmp_path}/${kernel}/${build_op}/boot"

    mkdir -p ${root} ${boot}

    tar -xJf "${amlogic_path}/${commonfiles_path}/boot-common.tar.xz" -C ${boot}
    tar -xJf "${kernel_dir}/kernel.tar.xz" -C ${boot}
    tar -xJf "${amlogic_path}/${commonfiles_path}/firmware.tar.xz" -C ${root}
    tar -xJf "${kernel_dir}/modules.tar.xz" -C ${root}

    cp -rf ${root_comm}/* ${root}
    # [ $(ls ${root_dir} | wc -w) != 0 ] && cp -r ${root_dir}/* ${root}
    sync
}

utils() {
    (
        cd ${root}
        # add other operations below

        echo 'pwm_meson' > etc/modules.d/pwm-meson
        if ! grep -q 'ulimit -n' etc/init.d/boot; then
            sed -i '/kmodloader/i \\tulimit -n 51200\n' etc/init.d/boot
        fi
        if ! grep -q '/tmp/upgrade' etc/init.d/boot; then
            sed -i '/mkdir -p \/tmp\/.uci/a \\tmkdir -p \/tmp\/upgrade' etc/init.d/boot
        fi
        sed -i 's/ttyAMA0/ttyAML0/' etc/inittab
        sed -i 's/ttyS0/tty0/' etc/inittab

        mkdir -p boot run opt
        chown -R 0:0 ./
    )
}

make_image() {
    cd ${make_path}
    build_op=${1}
    build_image_file="${out_path}/openwrt_${build_op}_v${kernel}_$(date +"%Y.%m.%d.%H%M").img"
    rm -f ${build_image_file}
    sync

    [ -d ${out_path} ] || mkdir -p ${out_path}
    fallocate -l $((SKIP_MB + BOOT_MB + rootsize))M ${build_image_file}
}

format_image() {
    cd ${make_path}
    build_op=${1}

    parted -s ${build_image_file} mklabel msdos 2>/dev/null
    parted -s ${build_image_file} mkpart primary ext4 $((SKIP_MB))M $((SKIP_MB + BOOT_MB -1))M 2>/dev/null
    parted -s ${build_image_file} mkpart primary ext4 $((SKIP_MB + BOOT_MB))M 100% 2>/dev/null

    loop_setup ${build_image_file}
    mkfs.vfat -n "BOOT" ${loop}p1 >/dev/null 2>&1
    mke2fs -F -q -t ext4 -L "ROOTFS" -m 0 ${loop}p2 >/dev/null 2>&1

    # Complete file
    if [ ! -f ${root}/root/hk1box-bootloader.img ]; then
       cp -f ${installfiles_path}/{*.img,*.bin} ${root}/root/
       cp -f ${installfiles_path}/*.sh ${root}/usr/bin/
       echo "${root}/etc/config/fstab ${root}/etc/config/fstab.bak" | xargs -n 1 cp -f ${installfiles_path}/fstab 2>/dev/null
    fi

    # Write the specified bootloader
    if [ "${build_op}" = "n1" -o "${build_op}" = "s905x" -o "${build_op}" = "s905d" ]; then
       BTLD_BIN="${root}/root/u-boot-2015-phicomm-n1.bin"
    else
       BTLD_BIN="${root}/root/hk1box-bootloader.img"
    fi

    if [ -f ${BTLD_BIN} ]; then
       dd if=${BTLD_BIN} of=${loop} bs=1 count=442 conv=fsync 2>/dev/null
       dd if=${BTLD_BIN} of=${loop} bs=512 skip=1 seek=1 conv=fsync 2>/dev/null
    fi

    # Add firmware version information to the terminal page
    if  [ -f ${root}/etc/banner ]; then
        op_version=$(echo $(ls ${root}/lib/modules/) 2>/dev/null)
        op_packaged_date=$(date +%Y-%m-%d)
        echo " OpenWrt Kernel: ${op_version}" >> ${root}/etc/banner
        echo " installation command: s9xxx-install.sh" >> ${root}/etc/banner
        echo " Packaged Date: ${op_packaged_date}" >> ${root}/etc/banner
        echo " -----------------------------------------------------" >> ${root}/etc/banner
    fi
}

copy2image() {
    cd ${make_path}
    build_op=${1}
    build_usekernel=${2}
    set -e

    local bootfs="${mount}/${kernel}/${build_op}/bootfs"
    local rootfs="${mount}/${kernel}/${build_op}/rootfs"

    mkdir -p ${bootfs} ${rootfs}
    if ! mount ${loop}p1 ${bootfs}; then
        die "mount ${loop}p1 failed!"
    fi
    if ! mount ${loop}p2 ${rootfs}; then
        die "mount ${loop}p2 failed!"
    fi

    cp -rf ${boot}/* ${bootfs}
    cp -rf ${root}/* ${rootfs}
    sync

    #Write the specified uEnv.txt & copy u-boot for 5.10.* kernel
    cd ${bootfs}
    if [  ! -f "uEnv.txt" ]; then
       die "Error: uEnv.txt Files does not exist"
    fi

    case "${build_op}" in
        s905x3 | x96 | hk1 | h96 | s9xxx)
            new_fdt_dtb="meson-sm1-x96-max-plus-100m.dtb"
            new_uboot="${uboot_path}/u-boot-s905x3-510kernel-x96max.bin"
            ;;
        s905x2 | x96max4g | x96max2g)
            new_fdt_dtb="meson-g12a-x96-max.dtb"
            new_uboot="${uboot_path}/u-boot-s905x2-510kernel-sei510.bin"
            ;;
        s922x | belink | belinkpro | ugoos)
            new_fdt_dtb="meson-g12b-gtking-pro.dtb"
            new_uboot="${uboot_path}/u-boot-s922x-510kernel-gtkingpro.bin"
            ;;
        s905x | s905d | n1)
            new_fdt_dtb="meson-gxl-s905d-phicomm-n1.dtb"
            new_uboot="${uboot_path}/u-boot-s905d-510kernel-phicommn1.bin"
            ;;
        s912 | octopus)
            new_fdt_dtb="meson-gxm-octopus-planet.dtb"
            new_uboot="${uboot_path}/u-boot-s912-510kernel-octopusplanet.bin"
            ;;
        *)
            die "Have no this firmware: [ ${build_op} - ${kernel} ]"
            ;;
    esac

    old_fdt_dtb="meson-gxl-s905d-phicomm-n1.dtb"
    sed -i "s/${old_fdt_dtb}/${new_fdt_dtb}/g" uEnv.txt
    if [ $(echo ${build_usekernel} | grep -oE '^[1-9].[0-9]{1,2}') = "5.10" -a -f ${new_uboot} ]; then
       echo "u-boot.ext u-boot-510kernel.bin" | xargs -n 1 cp -f ${new_uboot} 2>/dev/null
    fi
    sync

    cd ${make_path}
    umount -f ${bootfs} 2>/dev/null
    umount -f ${rootfs} 2>/dev/null
    losetup -d ${loop} 2>/dev/null
}

get_firmwares() {
    firmwares=()
    i=0
    IFS=$'\n'

    [ -d "${openwrt_path}" ] && {
        for x in $(ls ${openwrt_path}); do
            firmwares[i++]=${x}
        done
    }
}

get_kernels() {
    kernels=()
    i=0
    IFS=$'\n'

    local kernel_root="${amlogic_path}/${kernel_path}/kernel"
    [ -d ${kernel_root} ] && {
        work=$(pwd)
        cd ${kernel_root}
        for x in $(ls ./); do
            [[ -f "${x}/kernel.tar.xz" && -f "${x}/modules.tar.xz" ]] && kernels[i++]=${x}
        done
        cd ${work}
    }
}

show_kernels() {
    if [ ${#kernels[*]} = 0 ]; then
        die "No kernel files in [ ${amlogic_path}/${kernel_path}/kernel ] directory!"
    else
        show_list "${kernels[*]}" "kernel"
    fi
}

show_list() {
    echo " ${2}: "
    i=0
    for x in ${1}; do
        echo " ($((++i))) ${x}"
    done
}

choose_firmware() {
    show_list "${firmwares[*]}" "firmware"
    choose_files ${#firmwares[*]} "firmware"
    firmware=${firmwares[opt]}
    tag ${firmware} && echo
}

choose_kernel() {
    show_kernels
    choose_files ${#kernels[*]} "kernel"
    kernel=${kernels[opt]}
    tag ${kernel} && echo
}

choose_files() {
    local len=${1}

    if [ "${len}" = 1 ]; then
        opt=0
    else
        i=0
        while true; do
            echo && read -p " select ${2} above, and press Enter to select the first one: " ${opt}
            [ ${opt} ] || opt=1
            if [[ "${opt}" -ge 1 && "${opt}" -le "${len}" ]]; then
                ((opt--))
                break
            else
                ((i++ >= 2)) && exit 1
                error "Wrong type, try again!"
                sleep 1s
            fi
        done
    fi
}

set_rootsize() {
    i=0
    rootsize=

    while true; do
        read -p " input the rootfs partition size, defaults to 1024m, do not less than 256m
 if you don't know what this means, press Enter to keep default: " ${rootsize}
        [ ${rootsize} ] || rootsize=${ROOT_MB}
        if [[ "${rootsize}" -ge 256 ]]; then
            tag ${rootsize} && echo
            break
        else
            ((i++ >= 2)) && exit 1
            error "wrong type, try again!\n"
            sleep 1s
        fi
    done
}

usage() {
    cat <<EOF
Usage:
    make [option]

Options:
    -c, --clean          clean up the output and temporary directories

    -d, --default        the kernel version is "all", and the rootfs partition size is "1024m"

    -b, --build=BUILD    Specify multiple cores, use "_" to connect
       , -b all          Compile all types of openwrt
       , -b n1           Specify a single openwrt for compilation
       , -b n1_x96_hk1   Specify multiple openwrt, use "_" to connect

    -k=VERSION           set the kernel version, which must be in the "kernel" directory
       , -k all          build all the kernel version
       , -k latest       build the latest kernel version
       , -k 5.4.6        Specify a single kernel for compilation
       , -k 5.4.6_5.9.0  Specify multiple cores, use "_" to connect

    --kernel             show all kernel version in "kernel" directory

    -s, --size=SIZE      set the rootfs partition size, do not less than 256m

    -h, --help           display this help

EOF
}

##
[ $(id -u) = 0 ] || die "please run this script as root: [ sudo ./make ]"
echo -e "Welcome to use the OpenWrt packaging tool!\n"
echo -e "\n $(df -hT) \n"

cleanup
get_firmwares
get_kernels

while [ "${1}" ]; do
    case "${1}" in
    -h | --help)
        usage && exit
        ;;
    -c | --clean)
        cleanup
        rm -rf ${out_path}
        echo "Clean up ok!" && exit
        ;;

    -d | --default)
        : ${rootsize:=${ROOT_MB}}
        : ${firmware:="${firmwares[0]}"}
        : ${kernel:="all"}
        : ${build:="all"}
        ;;
    -b | --build)
        build=${2}
        if   [ "${build}" = "all" ]; then
             shift
        elif [ -n "${build}" ]; then
             unset build_openwrt
             oldIFS=$IFS
             IFS=_
             build_openwrt=(${build})
             IFS=$oldIFS
             unset build
             : ${build:="all"}
        else
             die "Invalid build [ ${2} ]!"
        fi
        shift
        ;;
    -k)
        kernel=${2}
        if   [ "${kernel}" = "all" ]; then
             shift
        elif [ "${kernel}" = "latest" ]; then
             kernel="${kernels[-1]}"
             shift
        elif [ -n "${kernel}" ]; then
             oldIFS=$IFS
             IFS=_
             kernels=(${kernel})
             IFS=$oldIFS
             unset kernel
             : ${kernel:="all"}
             shift
        else
             die "Invalid kernel [ ${2} ]!"
        fi
        ;;
    --kernel)
        show_kernels && exit
        ;;
    -s | --size)
        rootsize=${2}
        if [[ "${rootsize}" -ge 256 ]]; then
            shift
        else
            die "Invalid size [ ${2} ]!"
        fi
        ;;
    *)
        die "Invalid option [ ${1} ]!"
        ;;
    esac
    shift
done

if [ ${#firmwares[*]} = 0 ]; then
    die "No the [ openwrt-armvirt-64-default-rootfs.tar.gz ] file in [ ${openwrt_path} ] directory!"
fi

if [ ${#kernels[*]} = 0 ]; then
    die "No this kernel files in [ ${amlogic_path}/${kernel_path}/kernel ] directory!"
fi

[ ${firmware} ] && echo " firmware   ==>   ${firmware}"
[ ${rootsize} ] && echo " rootsize   ==>   ${rootsize}"
[ ${make_path} ] && echo " make_path   ==>   ${make_path}"

[ ${firmware} ] || [ ${kernel} ] || [ ${rootsize} ] && echo

[ ${firmware} ] || choose_firmware
[ ${kernel} ] || choose_kernel
[ ${rootsize} ] || set_rootsize

[ ${kernel} != "all" ] && kernels=("${kernel}")
[ ${build} != "all" ] && build_openwrt=("${build}")

extract_openwrt

for b in ${build_openwrt[*]}; do
    for x in ${kernels[*]}; do
        {
            kernel=${x}
            build=${b}
            process " extract armbian files."
            extract_armbian ${b}
            utils
            process " make openwrt image."
            make_image ${b}
            process " format openwrt image."
            format_image ${b}
            process " copy files to image."
            copy2image ${b} ${x}
            process " generate success."
        } &
    done
done

wait
echo -e "\n $(df -hT) \n"

cleanup
chmod -R 777 ${out_path}
