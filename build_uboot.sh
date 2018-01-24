#!/bin/bash

set -e

print_usage()
{
	echo "-h/--help         Show help options"
	echo "-b [TARGET_BOARD]	Target board ex) -b artik710|artik530|artik5|artik10"

	exit 0
}

parse_options()
{
	DO_CLEAN=false
	DO_RECONFIG=false

	for opt in "$@"
	do
		case "$opt" in
			-h|--help)
				print_usage
				shift ;;
			-b)
				TARGET_BOARD="$2"
				shift ;;
			--clean)
				DO_CLEAN=true
				;;
			--reconfig)
				DO_RECONFIG=true
				;;
		esac
	done
}

build()
{
	if $DO_CLEAN; then
		rm -rf $UBOOT_DIR/last_output
		make ARCH=arm distclean
		make ARCH=arm distclean O=$UBOOT_DIR/output
	fi

	if $DO_CLEAN || $DO_RECONFIG; then
		make ARCH=arm $UBOOT_DEFCONFIG O=$UBOOT_DIR/output
		make ARCH=arm EXTRAVERSION="-$BUILD_VERSION" ${UBOOT_BUILD_OPT} -j$JOBS O=$UBOOT_DIR/output
		rm -rf $UBOOT_DIR/last_output
		cp -pr $UBOOT_DIR/output $UBOOT_DIR/last_output
	else
		cp -prv $UBOOT_DIR/last_output $UBOOT_DIR/output
	fi
}

gen_envs()
{
	cp `find . -name "env_common.o"` copy_env_common.o
	${CROSS_COMPILE}objcopy -O binary --only-section=$UBOOT_ENV_SECTION \
		`find . -name "copy_env_common.o"`

	tr '\0' '\n' < copy_env_common.o | grep '=' > default_envs.txt
	cp default_envs.txt default_envs.txt.orig
	tools/mkenvimage -s 16384 -o params.bin default_envs.txt

	# Generate recovery param
	sed -i -e 's/rootdev=.*/rootdev=1/g' default_envs.txt
	sed -i -e 's/bootcmd=run .*/bootcmd=run recoveryboot/g' default_envs.txt
	tools/mkenvimage -s 16384 -o params_recovery.bin default_envs.txt

	# Generate mmcboot param
	cp default_envs.txt.orig default_envs.txt
	sed -i -e 's/bootcmd=run .*/bootcmd=run mmcboot/g' default_envs.txt
	tools/mkenvimage -s 16384 -o params_mmcboot.bin default_envs.txt

	# Generate sd-boot param
	cp default_envs.txt.orig default_envs.txt
	sed -i -e 's/rootdev=.*/rootdev=1/g' default_envs.txt
	tools/mkenvimage -s 16384 -o params_sdboot.bin default_envs.txt

	# Generate sd-vboot param
	sed -i -e 's/bootcmd=run .*/bootcmd=run vboot/g' default_envs.txt
	tools/mkenvimage -s 16384 -o params_sdvboot.bin default_envs.txt

	# Generate vboot param
	cp default_envs.txt.orig default_envs.txt
	sed -i -e 's/bootcmd=run .*/bootcmd=run vboot/g' default_envs.txt
	tools/mkenvimage -s 16384 -o params_vboot.bin default_envs.txt

	sed -i -e 's/bootcmd=run .*/bootcmd=run recoveryvboot/g' default_envs.txt
	tools/mkenvimage -s 16384 -o params_recovery_vboot.bin default_envs.txt
}

install_output()
{
	cp u-boot.bin $TARGET_DIR
	chmod 664 params.bin params_*.bin
	cp params.bin params_* $TARGET_DIR
	cp u-boot $TARGET_DIR
	[ -e u-boot.dtb ] && cp u-boot.dtb $TARGET_DIR
	if [ "$UBOOT_SPL" != "" ]; then
		cp spl/$UBOOT_SPL $TARGET_DIR
	fi
	cp tools/mkimage $TARGET_DIR
}

gen_version_info()
{
	PLAIN_VERSION=`cat include/generated/version_autogenerated.h | \
		grep "define PLAIN_VERSION" | awk -F \" '{print $2}'`
	UBOOT_VERSION="U-Boot $PLAIN_VERSION"
	if [ -e $TARGET_DIR/artik_release ]; then
		sed -i "s/_UBOOT=.*/_UBOOT=${UBOOT_VERSION}/" \
			$TARGET_DIR/artik_release
	fi
}

gen_fip_image()
{
	if [ "$UBOOT_IMAGE" == "fip-nonsecure.img" ]; then
		$UBOOT_DIR/output/tools/fip_create/fip_create \
			--dump --bl33 $TARGET_DIR/u-boot.bin \
			$TARGET_DIR/fip-nonsecure.bin
	fi
}


gen_nexell_image()
{
	local chip_name=$(echo -n ${CHIP_NAME} | awk '{print toupper($0)}')
	case "$CHIP_NAME" in
		s5p6818)
			nsih_name=raptor-64.txt
			input_file=fip-nonsecure.bin
			output_file=fip-nonsecure.img
			hash_file=fip-nonsecure.bin.hash
			gen_tool=SECURE_BINGEN
			launch_addr=0x00000000
			;;
		s5p4418)
			nsih_name=raptor-sd.txt
			input_file=u-boot.bin
			hash_file=u-boot.bin.hash
			output_file=$UBOOT_IMAGE
			gen_tool=SECURE_BINGEN
			launch_addr=$FIP_LOAD_ADDR
			;;
		*)
			return 0 ;;
	esac

	$UBOOT_DIR/output/tools/nexell/${gen_tool} \
		-c $chip_name -t 3rdboot \
		-n $UBOOT_DIR/tools/nexell/nsih/${nsih_name} \
		-i $TARGET_DIR/${input_file} \
		-o $TARGET_DIR/${output_file} \
		-l $FIP_LOAD_ADDR -e ${launch_addr}


	if [ "$SECURE_BOOT" == "enable" ] && [ "$RSA_SIGN_TOOL" != "" ] ; then
		chmod a+x ${RSA_SIGN_TOOL}
		${RSA_SIGN_TOOL} -sign $TARGET_DIR/${output_file}
	fi
}

check_rsa_sign_tool()
{
	if [ "${TARGET_BOARD}" == "artik530s" ] || [ "${TARGET_BOARD}" == "artik533s" ] || [ "${TARGET_BOARD}" == "artik710s" ]; then
		test -e $SECURE_PREBUILT_DIR/${TARGET_BOARD}_codesigner && cp -f $SECURE_PREBUILT_DIR/${TARGET_BOARD}_codesigner ${RSA_SIGN_TOOL}
		if [ ! -e ${RSA_SIGN_TOOL} ]; then
			echo -e "\e[1;31mERROR: cannot find ${RSA_SIGN_TOOL}\e[0m"
			echo -e "\e[1;31mBuild process has been terminated since the mandatory security binaries do not exist in your source code.\e[0m"
			echo -e "\e[1;31mPlease download those files from artik.io with SLA agreement to continue to build.\e[0m"
			echo -e "\e[1;31mOnce you download those files, please locate them to the following path.\e[0m"
			echo -e ""
			echo -e "\e[1;31m${TARGET_BOARD}_codesigner\e[0m"
			echo -e "\e[1;31mcopy to ../boot-firmwares-${TARGET_BOARD}/\e[0m"

			exit 1
		fi
	fi
}

trap 'error ${LINENO} ${?}' ERR
parse_options "$@"

SCRIPT_DIR=`dirname "$(readlink -f "$0")"`

if [ "$TARGET_BOARD" == "" ]; then
	print_usage
else
	if [ "$UBOOT_DIR" == "" ]; then
		. $SCRIPT_DIR/config/$TARGET_BOARD.cfg
	fi
fi

check_rsa_sign_tool

test -d $TARGET_DIR || mkdir -p $TARGET_DIR

pushd $UBOOT_DIR

build

pushd output

gen_envs
install_output
gen_fip_image
gen_nexell_image
gen_version_info

popd
rm -rf output
popd
