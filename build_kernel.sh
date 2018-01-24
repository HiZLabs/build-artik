#!/bin/bash

set -e

package_check()
{
	command -v $1 >/dev/null 2>&1 || { echo >&2 "${1} not installed. Aborting."; exit 1; }
}

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
		make distclean
	fi

	if $DO_CLEAN || $DO_RECONFIG; then
		make $KERNEL_DEFCONFIG
	fi
	make $KERNEL_IMAGE -j$JOBS EXTRAVERSION="-$BUILD_VERSION"
	make $BUILD_DTB EXTRAVERSION="-$BUILD_VERSION"
	make modules EXTRAVERSION="-$BUILD_VERSION" -j$JOBS
}

build_modules()
{
	mkdir -p $TARGET_DIR/modules
	make modules_install INSTALL_MOD_PATH=$TARGET_DIR/modules INSTALL_MOD_STRIP=1
	make_ext4fs -b 4096 -L modules \
		-l ${MODULE_SIZE}M ${TARGET_DIR}/modules.img \
		${TARGET_DIR}/modules/lib/modules/
	rm -rf ${TARGET_DIR}/modules
}

install_output()
{
	cp arch/$ARCH/boot/$KERNEL_IMAGE $TARGET_DIR
	cp $DTB_PREFIX_DIR/$KERNEL_DTB $TARGET_DIR
	cp vmlinux $TARGET_DIR
}

gen_version_info()
{
	KERNEL_VERSION=`make EXTRAVERSION="-$BUILD_VERSION" kernelrelease | grep -v scripts`
	if [ -e $TARGET_DIR/artik_release ]; then
		sed -i "s/_KERNEL=.*/_KERNEL=${KERNEL_VERSION}/" $TARGET_DIR/artik_release
	fi
}

trap 'error ${LINENO} ${?}' ERR
parse_options "$@"

SCRIPT_DIR=`dirname "$(readlink -f "$0")"`
if [ "$TARGET_BOARD" == "" ]; then
	print_usage
else
	if [ "$KERNEL_DIR" == "" ]; then
		. $SCRIPT_DIR/config/$TARGET_BOARD.cfg
	fi
fi

test -d $TARGET_DIR || mkdir -p $TARGET_DIR

pushd $KERNEL_DIR

package_check ${CROSS_COMPILE}gcc
package_check make_ext4fs

build
build_modules
install_output
gen_version_info

popd
