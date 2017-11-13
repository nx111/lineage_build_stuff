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
if [ -x $workdir/out/host/linux-x86/bin/jack-admin ]; then
   $workdir/out/host/linux-x86/bin/jack-admin kill-server
   $workdir/out/host/linux-x86/bin/jack-admin start-server
fi

. $workdir/build/envsetup.sh

#[ -x $workdir/repopick.sh ] && $workdir/

brunch kltechnduo

if [ -x $workdir/out/host/linux-x86/bin/jack-admin ]; then
   $workdir/out/host/linux-x86/bin/jack-admin kill-server
fi

[ "$curdir" != "$workdir" ] && cd $curdir
