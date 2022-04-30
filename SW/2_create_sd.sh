#!/usr/bin/sh

set -e
# set -x

. ./consts.sh

check_root_fs() {
    if [ ! -f "${ROOT_FS}" ] ; then
        wget "${ROOT_FS_DL}"
    fi
}

check_sd_card_is_block_device() {
    _DEVICE=${1}

    if [ -z "${_DEVICE}" ] || [ ! -b "${_DEVICE}" ] ; then
        echo "Error: '${_DEVICE}' is empty or not a block device"
        exit 1
    fi
}

check_required_file() {
    if [ ! -f "${1}" ] ; then
        echo "Missing file: ${1}, did you compile everyhing first?"
        exit 1
    fi
}

probe_partition_separator() {
    _DEVICE=${1}

    [ -b "${_DEVICE}p1" ] && echo 'p' || echo ''
}

DEVICE=${1}

if [ "${USE_CHROOT}" != 0 ] ; then
    # check_deps for arch-chroot on non RISC-V host
    for DEP in arch-install-scripts qemu-user-static-bin binfmt-qemu-static ; do
        check_deps ${DEP}
    done
fi
check_sd_card_is_block_device "${DEVICE}"
check_root_fs
for FILE in 8723ds.ko boot0_sdcard_sun20iw1p1.bin boot.scr Image.gz Image u-boot.toc1 ; do
    check_required_file "${OUT_DIR}/${FILE}"
done

# format disk
echo "Formatting ${DEVICE}, this will REMOVE EVERYTHING on it!"
printf "Continue? (y/N): "
read -r  confirm && [ "${confirm}" = "y" ] || [ "${confirm}" = "Y" ] || exit 1

${SUDO} dd if=/dev/zero of="${DEVICE}" bs=1M count=200
${SUDO} parted -s -a optimal -- "${DEVICE}" mklabel gpt
${SUDO} parted -s -a optimal -- "${DEVICE}" mkpart primary ext2 40MiB 500MiB
${SUDO} parted -s -a optimal -- "${DEVICE}" mkpart primary ext4 540MiB 100%
${SUDO} partprobe "${DEVICE}"
PART_IDENTITYFIER=$(probe_partition_separator "${DEVICE}")
${SUDO} mkfs.ext2 -F -L boot "${DEVICE}${PART_IDENTITYFIER}1"
${SUDO} mkfs.ext4 -F -L root "${DEVICE}${PART_IDENTITYFIER}2"

# flash boot things
${SUDO} dd if="${OUT_DIR}/boot0_sdcard_sun20iw1p1.bin" of="${DEVICE}" bs=8192 seek=16
${SUDO} dd if="${OUT_DIR}/u-boot.toc1" of="${DEVICE}" bs=512 seek=32800

# mount it
mkdir -p "${MNT}"
${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}2" "${MNT}"
${SUDO} mkdir -p "${MNT}/boot"
${SUDO} mount "${DEVICE}${PART_IDENTITYFIER}1" "${MNT}/boot"

# extract rootfs
${SUDO} tar -xv --zstd -f "${ROOT_FS}" -C "${MNT}"

# install kernel and modules
${SUDO} cp "${OUT_DIR}/Image.gz" "${OUT_DIR}/Image" "${MNT}/boot/"
cd build/linux-build
${SUDO} make ARCH="${ARCH}" INSTALL_MOD_PATH="../../${MNT}" KERNELRELEASE="${KERNEL_RELEASE}" modules_install
cd ../..
${SUDO} install -D -p -m 644 "${OUT_DIR}/8723ds.ko" "${MNT}/lib/modules/${KERNEL_RELEASE}/kernel/drivers/net/wireless/8723ds.ko"

${SUDO} rm "${MNT}/lib/modules/${KERNEL_RELEASE}/build"
${SUDO} rm "${MNT}/lib/modules/${KERNEL_RELEASE}/source"

${SUDO} depmod -a -b "${MNT}" "${KERNEL_RELEASE}"
echo '8723ds' >> 8723ds.conf
${SUDO} cp 8723ds.conf "${MNT}/etc/modules-load.d/"
rm 8723ds.conf

# install U-Boot
${SUDO} cp "${OUT_DIR}/boot.scr" "${MNT}/boot/"

# fstab
cat << EOF > fstab
# <device>    <dir>        <type>        <options>            <dump> <pass>
LABEL=boot    /boot        ext2          rw,defaults,noatime  0      1
LABEL=root    /            ext4          rw,defaults,noatime  0      2
EOF
${SUDO} cp fstab "${MNT}/etc/fstab"
rm fstab

# set hostname
echo 'licheerv' > hostname
${SUDO} cp hostname "${MNT}/etc/"
rm hostname

# # updating ...
# ${SUDO} arch-chroot ${MNT} pacman -Syu
# ${SUDO} arch-chroot ${MNT} pacman -S wpa_supplicant
# ${SUDO} arch-chroot ${MNT} pacman -S netctl
# ${SUDO} arch-chroot ${MNT} pacman -S --asdeps dialog

# done
if [ "${USE_CHROOT}" != 0 ] ; then
    echo ''
    echo 'Done! Now configure your new Archlinux!'
    echo ''
    echo 'You might want to update and install an editor as well as configure any network'
    echo ' -> https://wiki.archlinux.org/title/installation_guide#Configure_the_system'
    echo ''
    ${SUDO} arch-chroot "${MNT}"
else
    echo ''
    echo 'Done!'
fi

sync

${SUDO} umount -R "${MNT}"
exit 0
