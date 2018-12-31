#!/bin/bash
product=kltechnduo

force=0
for op in $*; do
    if [ "$op" = "-prepare" ]; then
       mode="prepare";
    elif [ "$op" = "addonsu" ]; then
       mode="addonesu"
    elif [ "$op" = "klte" -o "$op" = "kltechnduo" -o "$op" = "kltechn" ]; then
       product=$op
    elif [ "$op" = "boot" -o "$op" = "-boot" ]; then
       mode="boot"
    elif [ "$op" = "-B" ]; then
       force=1
    fi
done

if [ "$mode" = "prepare" ]; then
    sudo apt install bc bison build-essential ccache curl flex g++-multilib gcc-multilib git gnupg gperf imagemagick lib32ncurses5-dev \
                     lib32readline-dev lib32z1-dev liblz4-tool libncurses5-dev libsdl1.2-dev libssl-dev libwxgtk3.0-dev libxml2 libxml2-utils \
                     lzop pngcrush rsync schedtool squashfs-tools xsltproc zip zlib1g-dev ccache cmake
    exit 0
fi

export USE_CCACHE=1
export CCACHE_COMPRESS=1
workdir=$(dirname $(realpath $0))
curdir=`pwd`
if [ $workdir != "" -a $workdir != "." ]; then
	cd $workdir
fi

[ "$workdir" = "" ] && workdir=`pwd`
export CCACHE_DIR=$workdir/.ccache
if [ _$(which ccache) != "_" ]; then
    ccache -M 30G
else
    $workdir/prebuilts/misc/linux-x86/ccache/ccache -M 30G
fi

export JACK_SERVER_VM_ARGUMENTS="-Dfile.encoding=UTF-8 -XX:+TieredCompilation -Xmx4096m"

. $workdir/build/envsetup.sh

#[ -x $workdir/repopick.sh ] && $workdir/


result=0
if [ "$mode" = "addonsu" ]; then
	breakfast $product
	[ -f $workdir/.mypatches/superuser.rc -a ! -f $workdir/system/extras/su/superuser.rc ] \
		&& cp $workdir/.mypatches/superuser.rc $workdir/system/extras/su/
	make addonsu
        result=$?
else
	if [ "$mode" != "boot" ]; then
		rm -rf $workdir/out/target/product/$product/system
		rm -rf $workdir/out/target/product/$product/root
		rm -rf $workdir/out/target/product/$product/lineage_$product-ota-*.zip
		rm -rf $workdir/out/target/product/$product/obj/PACKAGING/*
	fi

        obootime=0
        nbootime=0
        [ -f $workdir/out/target/product/$product/boot.img ] && obootime=$(stat -c %Y $workdir/out/target/product/$product/boot.img)

        breakfast $product
	if [ "$mode" = "boot" ]; then
	    make  bootimage
            echo "bootimage: $nbootimg build complete."
        elif [ $force -eq 1 ]; then
            LINEAGE_VERSION_APPEND_TIME_OF_DAY=true WITH_SU=true LC_ALL=C REMOVE_OAHL_FROM_BCP=true \
   	    cmka bacon
            result=$?
        else
            LINEAGE_VERSION_APPEND_TIME_OF_DAY=true WITH_SU=true LC_ALL=C REMOVE_OAHL_FROM_BCP=true \
   	    mka bacon
            result=$?
        fi
        [ -f $workdir/out/target/product/$product/boot.img ] && nbootime=$(stat -c %Y $workdir/out/target/product/$product/boot.img)
        if [ $obootime -lt $nbootime ]; then
             nbootimg=boot_$(stat -c %y $workdir/out/target/product/$product/boot.img | cut -d. -f1 | sed -e "s/-//g" -e "s/://g" -e "s/ /_/").img
             cp $workdir/out/target/product/$product/boot.img $workdir/out/target/product/$product/$nbootimg
        fi
fi

if [ -x $workdir/out/host/linux-x86/bin/jack-admin ]; then
   $workdir/out/host/linux-x86/bin/jack-admin kill-server
fi

[ "$curdir" != "$workdir" ] && cd $curdir

exit $result
