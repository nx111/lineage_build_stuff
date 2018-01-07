#!/bin/bash


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

if [ $# -ge 1 -a "$1" = "addonsu" ]; then
	breakfast kltechnduo
	[ -f $workdir/.mypatches/superuser.rc -a ! -f $workdir/system/extras/su/superuser.rc ] \
		&& cp $workdir/.mypatches/superuser.rc $workdir/system/extras/su/
	make addonsu
elif [ $# -ge 1 -a "$1" = "boot" ]; then
	breakfast kltechnduo
	make -B bootimage
#elif [ $# -ge 1 -a "$1" = "multirom" ]; then
#	breakfast kltechnduo
#	make multirom_zip
else

	rm -rf $workdir/out/target/product/kltechnduo/system
	rm -rf $workdir/out/target/product/kltechnduo/root
	rm -rf $workdir/out/target/product/kltechnduo/lineage_kltechnduo-ota-*.zip
	rm -rf $workdir/out/target/product/kltechnduo/obj/PACKAGING/*
        ALLOW_MISSING_DEPENDENCIES=true \
        LINEAGE_VERSION_APPEND_TIME_OF_DAY=true \
	brunch kltechnduo
fi

if [ -x $workdir/out/host/linux-x86/bin/jack-admin ]; then
   $workdir/out/host/linux-x86/bin/jack-admin kill-server
fi

[ "$curdir" != "$workdir" ] && cd $curdir
