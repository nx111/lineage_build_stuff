#!/bin/sh
topdir=`pwd`
cat .repo/project.list | while read p; do
    cd $topdir/$p
    echo "Cleaning: $p ..."
    git stash
    git clean -xdf
done

cd $topdir
