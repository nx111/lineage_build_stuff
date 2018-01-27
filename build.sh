#!/bin/bash
product=kltechnduo
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
elif [ "$1" = "boot" ]; then
	breakfast $product
	make -B bootimage
elif [ $# -eq 1 -a "$1" = "-B" ]; then
	rm -rf $workdir/out/target/product/$product/system
	rm -rf $workdir/out/target/product/$product/root
	rm -rf $workdir/out/target/product/$product/lineage_$product-ota-*.zip
	rm -rf $workdir/out/target/product/$product/obj/PACKAGING/*

        breakfast $product
        LINEAGE_VERSION_APPEND_TIME_OF_DAY=true WITH_SU=true \
	cmka $product

else
	rm -rf $workdir/out/target/product/$product/system
	rm -rf $workdir/out/target/product/$product/root
	rm -rf $workdir/out/target/product/$product/lineage_$product-ota-*.zip
	rm -rf $workdir/out/target/product/$product/obj/PACKAGING/*

        LINEAGE_VERSION_APPEND_TIME_OF_DAY=true WITH_SU=true \
	brunch $product
fi

if [ -x $workdir/out/host/linux-x86/bin/jack-admin ]; then
   $workdir/out/host/linux-x86/bin/jack-admin kill-server
fi

[ "$curdir" != "$workdir" ] && cd $curdir
