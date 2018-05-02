#!/bin/bash
product=kltechnduo

if [ "$1" = "-prepare" ]; then
    sudo apt install bc bison build-essential ccache curl flex g++-multilib gcc-multilib git gnupg gperf imagemagick lib32ncurses5-dev \
                     lib32readline-dev lib32z1-dev liblz4-tool libncurses5-dev libsdl1.2-dev libssl-dev libwxgtk3.0-dev libxml2 libxml2-utils \
                     lzop pngcrush rsync schedtool squashfs-tools xsltproc zip zlib1g-dev ccache cmake
    exit 0
fi

export USE_CCACHE=1
export CCACHE_COMPRESS=1
workdir=`dirname $0`
curdir=`pwd`
if [ $workdir != "" -a $workdir != "." ]; then
	cd $workdir
fi

[ "$workdir" = "" ] && workdir=`pwd`
export CCACHE_DIR=$workdir/.ccache
$workdir/prebuilts/misc/linux-x86/ccache/ccache -M 30G

export JACK_SERVER_VM_ARGUMENTS="-Dfile.encoding=UTF-8 -XX:+TieredCompilation -Xmx4096m"

. $workdir/build/envsetup.sh

#[ -x $workdir/repopick.sh ] && $workdir/

if [ "$1" = "addonsu" ]; then
	breakfast $product
	[ -f $workdir/.mypatches/superuser.rc -a ! -f $workdir/system/extras/su/superuser.rc ] \
		&& cp $workdir/.mypatches/superuser.rc $workdir/system/extras/su/
	make addonsu
elif [ "$1" = "boot" -o "$1" = "-boot" ]; then
        obootime=0
        nbootime=0
        [ -f $workdir/out/target/product/$product/boot.img ] && obootime=$(stat -c %Y $workdir/out/target/product/$product/boot.img)
	breakfast $product
	make  bootimage
        [ -f $workdir/out/target/product/$product/boot.img ] && nbootime=$(stat -c %Y $workdir/out/target/product/$product/boot.img)
        if [ $obootime -lt $nbootime ]; then
             nbootimg=boot_$(stat -c %y $workdir/out/target/product/$product/boot.img | cut -d. -f1 | sed -e "s/-//g" -e "s/://g" -e "s/ /_/").img
             cp $workdir/out/target/product/$product/boot.img $workdir/out/target/product/$product/$nbootimg
             echo "bootimage: $nbootimg build complete."
        fi
elif [ $# -eq 1 -a "$1" = "-B" ]; then
	rm -rf $workdir/out/target/product/$product/system
	rm -rf $workdir/out/target/product/$product/root
	rm -rf $workdir/out/target/product/$product/lineage_$product-ota-*.zip
	rm -rf $workdir/out/target/product/$product/obj/PACKAGING/*

        breakfast $product
        LINEAGE_VERSION_APPEND_TIME_OF_DAY=true WITH_SU=true \
	cmka bacon

else
	rm -rf $workdir/out/target/product/$product/system
	rm -rf $workdir/out/target/product/$product/root
	rm -rf $workdir/out/target/product/$product/lineage_$product-ota-*.zip
	rm -rf $workdir/out/target/product/$product/obj/PACKAGING/*

        LINEAGE_VERSION_APPEND_TIME_OF_DAY=true WITH_SU=true LC_ALL=C \
	brunch $product
fi

if [ -x $workdir/out/host/linux-x86/bin/jack-admin ]; then
   $workdir/out/host/linux-x86/bin/jack-admin kill-server
fi

[ "$curdir" != "$workdir" ] && cd $curdir
