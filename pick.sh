#!/bin/bash
source build/envsetup.sh
topdir=$(gettop)
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_pick_remote_only=0
op_pick_continue=0
op_snap_project=""
op_patches_dir=""
op_base_pick=0
op_keep_manifests=0
default_remote="github"
script_file="$(realpath ${BASH_SOURCE[0]})"
runfrom=$0
conflict_resolved=0
maxCount=500
minCount=20
tmp_picks_info_file=$(dirname $script_file)/.tmp_picks_info_file
start_check_classification=0

int_handler()
{
    # Kill the parent process of the script.
    kill $PPID
    exit 1
}

##### apply patch saved first ########
function get_defaul_remote()
{
      manifest=$(gettop)/.repo/manifest.xml
      lineno=$(grep -n "<default revision=" $manifest | cut -d: -f1)
      for ((n=$lineno;n < lineno + 6; n++)) do
          if sed -n ${n}p $manifest | grep -q " remote="; then
              remote=$(sed -n ${n}p $manifest | sed -e "s/ remote=\"\([^\"]*\)\".*/\1/")
              if [ "$remote" != "" ]; then
                  default_remote=$remote
                  break
              fi
           fi
      done
}

function sort_projects()
{
    [ $# -lt 1 -o ! -f "$1" ] && return
    local project_list=$1
    local project
    local line

    grep "^android," $project_list
    while read line; do
        project=$(echo $line | cut -d, -f 1)
        [ "$project" == "android" ] && continue
        echo $line
    done < $project_list
}

function patch_local()
{
    cd $(gettop)
    topdir=$(gettop)
    va_patches_dir=$1
    search_dir=".myfiles/patches"

    if [ ! -z $va_patches_dir ]; then
        if [ -d "$topdir/.myfiles/patches/$va_patches_dir" ]; then
            search_dir=".myfiles/patches/$va_patches_dir"
        elif [ -d "$topdir/.myfiles/patches/pick/$va_patches_dir" -o -d "$topdir/.myfiles/patches/local/$va_patches_dir" ]; then
            search_dir=".myfiles/patches/local/$va_patches_dir .myfiles/patches/pick/$va_patches_dir"
        else
            return -1
        fi
    else
        return -1
    fi

    find $search_dir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.myfiles\/\patches\///" -e "s/\//:/" |sort -t : -k 2 | while read line; do
         f=$(echo $line | sed -e "s/:/\//")
         patchfile=$(basename $f)
         project=$(echo $f |  sed -e "s/^pick\///" -e "s/^local\///"  | sed "s/\/[^\/]*$//")
         if [ ! -d "$topdir/$project" ]; then
            if [ -d "$topdir/$(dirname $project)" ]; then
               project=$(dirname $project)
            else
                continue
            fi
         fi
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo ">>> Applying patches to $project: "
                  #rm -rf .git/rebase-apply
             fi
             if echo $f | grep -qE "\[WIP\]|\[SKIP\]"; then
                 echo "    skipping: $f"
                 continue
             fi

             ext=${patchfile##*.}
             #rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.myfiles/patches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then
                       echo "    patching: $(basename $f) ..."
                       git am -3 -q   --keep-cr --committer-date-is-author-date < $topdir/.myfiles/patches/$f
                       rc=$?
                       if [ $rc -ne 0 ]; then
                             first=0
                             echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it, 'd' drop it and delete it ..."
                             while ! git log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                 [ $first -ne 0 ] && echo "conflicts not resolved,please fix it, then press ENTER to continue, or press 's' skip it, 'd' drop it and delete it ..."
                                 first=1
                                 ch=$(sed q </dev/tty)
                                 if [ "$ch" = "s" -o "$ch" = "d" ]; then
                                    echo "skip it ..."
                                    git am --skip
                                    [ "$ch" = "d" ] && rm $topdir/.myfiles/patches/$f
                                    break
                                  fi
                             done
                       fi
                       if [ "$project" = "android" ]; then
                            git -C $topdir/.repo/manifests am -3 -q --keep-cr --committer-date-is-author-date < $topdir/.myfiles/patches/$f
                            rc=$?
                            if [ $rc -ne 0 ]; then
                                 first=0
                                 echo  "  >> git am conflict, please resolv it, then press ENTER to continue, or press 's' skip it, 'd' drop it and delete it ..."
                                 while ! git -C $topdir/.repo/manifests log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                     [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it, 'd' drop it and delete it ..."
                                     first=1
                                     ch=$(sed q </dev/tty)
                                     if [ "$ch" = "s" -o "$ch" = "a" ]; then
                                        git -C $topdir/.repo/manifests am --skip
                                        [ "$ch" = "d" ] && rm $topdir/.myfiles/patches/$f
                                        break
                                     fi
                                 done
                           fi
                       fi
                  else
                       echo "    skipping: $f ...(applied always)"
                  fi
             fi
         fi
    done

    cd $topdir
    if [ "$va_patches_dir" = "local" -a -d $topdir/.myfiles/patches/overwrite ]; then
        search_dir=.myfiles/patches/overwrite
        find $search_dir -type f | sed -e "s/\.myfiles\/\patches\/overwrite\///"  | while read f; do
             [ -f $line ] && cp $search_dir/$f $f
        done
    fi

}

function reset_overwrite_projects()
{
    cd $topdir
    [ -f .myfiles/patches/overwrite/projects.list ] && rm -f .myfiles/patches/overwrite/projects.list
    [ -d ".myfiles/patches/overwrite" ] || return
    find ".myfiles/patches/overwrite" -type f | sed -e "s/\.myfiles\/\patches\/overwrite\///"  | while read f; do
        while [ $f != $(dirname $f) -a ! -d $(dirname $f)/.git ]; do
              f=$(dirname $f)
        done
        f=$(dirname $f)
        if [ -d $topdir/$f ]; then
            if ! grep -q $f .myfiles/patches/overwrite/projects.list 2>/dev/null ; then
                git -C $topdir/$f stash >/dev/null
                echo $f >> .myfiles/patches/overwrite/projects.list
            fi
        fi
    done
}

function projects_reset()
{
    cd $(gettop)
    topdir=$(gettop)
    default_branch=$(cat .repo/manifest.xml | grep "default revision" | cut -d= -f2 | sed -e "s/\"//g" -e "s/refs\/heads\///")

    find .myfiles/patches -type d | sed -e "s/\.myfiles\/\patches\///" |sort -n | while read project; do
         [ "$f" = "patches" ] && continue
         if ! grep -q "^$project\$" $topdir/.repo/project.list; then
              continue
         fi
         cd $topdir/$project
         echo ""
         echo "==== reset $project to $basebranch "
         basebranch=$(git branch -a | grep '\->' | grep "$default_branch" | sed -e "s/.*\-> //")
         basecommit=$(git log --pretty=short -1 $basebranch | sed -n 1p | cut -d' ' -f2)
         git reset --hard $basecommit
    done
    cd $topdir
}

function projects_snapshot()
{
    cd $(gettop)
    topdir=$(gettop)
    snapshot_file=$topdir/.myfiles/patches/snapshot.list
    local vproject=""
    [ "$1" != "" ] && vproject=$(echo $1 | sed -e 's/\/$//')
    rm -f $snapshot_file.new
    trap 'int_handler' INT

    cat $topdir/.repo/project.list | while read project; do
         [ "$1" != "" -a "$project" != "$vproject" ] && continue
         [ -d "$topdir/$project" ] || continue
         cd $topdir/$project
         echo ">>>  project: $project ... "

         commit_id=""
         url=""

         git log --pretty="format:%H|%s|%D" --max-count=250 > /tmp/gitlog.txt
         echo >>/tmp/gitlog.txt
         while read line; do
             commit_id=$(echo $line | cut -d"|" -f1)
             branches=$(echo $line | cut -d"|" -f3)
             [ "$branches" = "" -o "$commit_id" = "" ] && continue
             if echo $branches | grep -q -e "[[:space:]]*m\/"; then
                 remotetmp=/tmp/projects_snapshot_$(basename $project).list
                 git remote show > $remotetmp
                 local count=$(cat $remotetmp | wc -l)
                 if grep -qw $default_remote $remotetmp; then
                      remote=$default_remote
                 else
                      remote=$(sed -n 1p $remotetmp)
                 fi
                 rm -f $remotetmp

                 if [ "$remote" != "" ]; then
                      url=$(git remote get-url $remote)
                      break
                 fi
             fi
         done < /tmp/gitlog.txt
         rm -f /tmp/gitlog.txt

         if [ "$1" = "" ];  then
              echo "$project, $commit_id, $url" >> $snapshot_file.new
         elif [ "$1" != "" -a "$project" = "$vproject" ]; then
              if [ -f $snapshot_file.new ]; then
                     sed -e "s|^${project}.*|${project},${commit_id}, ${url}|" -i $snapshot_file.new
              else
                     sed -e "s|^${project}.*|${project},${commit_id}, ${url}|" -i $snapshot_file
              fi
         fi


         [ -d $topdir/.myfiles/patches/pick/$project ] || mkdir -p $topdir/.myfiles/patches/pick/$project
         rm -rf $topdir/.myfiles/patches/pick/$project/*.patch
         rm -rf $topdir/.myfiles/patches/pick/$project/*.diff

         git format-patch "$commit_id" -o $topdir/.myfiles/patches/pick/$project/ | sed -e "s:.*/:              :"

         patches_count=$(find $topdir/.myfiles/patches/pick/$project -maxdepth 1 -name "*.patch" -o -name "*.diff" | wc -l)
         local number=$((patches_count + 1))
         if [ $patches_count -eq 0 ]; then
              rmdir -p --ignore-fail-on-non-empty $topdir/.myfiles/patches/pick/$project
         elif [ -d $topdir/.myfiles/patches/local/$project ]; then
              find $topdir/.myfiles/patches/local/$project -maxdepth 1 -type f -name "*.patch" -o -name "*.diff" | while read patchfile; do
                   patch_file_name=$(basename $patchfile)
                   changeid=$(grep "Change-Id: " $patchfile | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
                   #echo "$project >  $patchfile  ==== Change-Id:$changeid"
                   if [ "$changeid" != "" ]; then
                       if grep -q "Change-Id: $changeid" -r $topdir/.myfiles/patches/pick/$project; then
                           pick_patch=$(grep -H "Change-Id: $changeid" -r $topdir/.myfiles/patches/pick/$project | sed -n 1p | cut -d: -f1)
                           pick_patch_name=$(basename $pick_patch)
                           if echo $patch_file_name | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]|\[KEEP\]" ; then
                               [ "${patch_file_name:5:5}" = "[WIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:5}-${pick_patch_name:5}
                               [ "${patch_file_name:5:6}" = "[SKIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:6}-${pick_patch_name:5}
                               [ "${patch_file_name:5:8}" = "[ALWAYS]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:8}-${pick_patch_name:5}
                               [ "${patch_file_name:5:8}" = "[KEEP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:6}-${pick_patch_name:5}
                           elif echo $(dirname $patchfile) | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]|\[KEEP\]" ; then
                               rm -f $patchfile
                               mv $pick_patch $(dirname $patchfile)/
                           else
                               rm -f $patchfile
                               mv $pick_patch $topdir/.myfiles/patches/local/$project/
                           fi
                       elif ! echo $patchfile | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]|\[KEEP\]"; then
                           rm -f $patchfile
                       elif echo $patchfile | grep -q "^[[:digit:]]\{4,4\}-"; then
                           prefixNumber=$(echo $number| awk '{printf("%04d\n",$0)}')
                           mv $patchfile $prefixNumber-${patchfile:5}
                           number=$((number + 1))
                       fi
                   fi
              done
         fi
         [ -d $topdir/.myfiles/patches/pick/$project ] && find $topdir/.myfiles/patches/pick/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
         [ -d $topdir/.myfiles/patches/local/$project ] && find $topdir/.myfiles/patches/local/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
    done
    find $topdir/.myfiles/patches -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null

    [ "$1" = "" -a -f $snapshot_file.new ] && \
    mv $snapshot_file.new $snapshot_file

    cd $topdir
}

function resync_project()
{
    [ $# -lt 1 ] && return -1
    project=$1
    topdir=$(gettop)
    curdir=`pwd`
    cd $topdir
    rm -rf $topdir/$project
    [ -d $topdir/.repo/projects/$project.git/object ] && rm -rf $(dirname $(realpath $topdir/.repo/projects/$project.git/object))
    [ -d $topdir/.repo/projects/$project.git ] && rm -rf $topdir/.repo/projects/$project.git
    repo sync $project
    cd $curdir
}

function restore_snapshot()
{
    topdir=$(gettop)
    cd $topdir
    snapshot_file=$topdir/.myfiles/patches/snapshot.list
    [ -f "$snapshot_file" ] || return -1

    trap 'int_handler' INT
    sort_projects $snapshot_file | while read line; do
         project=$(echo $line | cut -d, -f1 | sed -e "s/^ *//g" -e "s/ *$//g")
         basecommit=$(echo $line | cut -d, -f2 | sed -e "s/^ *//g" -e "s/ *$//g")
         remoteurl=$(echo $line | cut -d, -f3 | sed -e "s/^ *//g" -e "s/ *$//g")

         [ "$project" = "android" ] && reset_project_dir .repo/manifests

         tmp_skip_dirs=/tmp/skip_dirs_$(echo $project | sed -e "s:/:_:g")
         cd $topdir/$project >/dev/null 2>/dev/null || resync_project $project && cd $topdir/$project

         echo ">>>  restore project: $project ... "
         git stash -q || resync_project $project && cd $topdir/$project
         LANG=en_US git clean -xdf | sed -e "s/Skipping repository //g" | sed -e "s:/$::"> ${tmp_skip_dirs}
         if git log -n0 $basecommit >/dev/null 2>/dev/null; then
             git checkout -q --detach $basecommit>/dev/null 2>/dev/null
         else
             resync_project $project;cd $topdir/$project
             git fetch $remoteurl $basecommit && git checkout -q FETCH_HEAD >/dev/null 2>/dev/null
         fi

         searchdir=""
         [ -d $topdir/.myfiles/patches/pick/$project ] && searchdir="$searchdir $topdir/.myfiles/patches/pick/$project"
         [ -d $topdir/.myfiles/patches/local/$project ] && searchdir="$searchdir $topdir/.myfiles/patches/local/$project"
         [ "$searchdir" != "" ] && \
         find $searchdir -type f -name "*.patch" -o -name "*.diff" | sed -e "s:$topdir/.myfiles/patches/::"  -e "s|\/|:|" |sort -t : -k 2 | while read line; do
             rm -rf $topdir/$project/.git/rebase-apply
             f=$(echo $line | sed -e "s/:/\//")
             fdir=$(dirname $f | sed -e "s:$project/::" | sed -e "s:^[^/]*/::g" |sed -e "s:\[.*::g" | sed -e "s:/$::")
             grep -q -E "^$fdir$" ${tmp_skip_dirs} && continue
             patchfile=$(basename $f)
             if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
                  echo "         skipping: $f"
                  continue
             fi
             changeid=$(grep "Change-Id: " $topdir/.myfiles/patches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then
                      echo "         apply patch: $f ..."
                      git am -3 -q  --keep-cr --committer-date-is-author-date < $topdir/.myfiles/patches/$f
                      rc=$?
                      if [ $rc -ne 0 ]; then
                             first=0
                             resolved=0
                             if grep -q "using previous resolution" $errfile; then
                                 grep "using previous resolution" $errfile | sed -e "s/Resolved '\(.*\)' using previous resolution.*/\1/" | xargs git add -f
                                 if git am --continue; then
                                      resolved=1
                                 fi
                             fi
                             if [ $resolved -eq 0 ]; then
                                 echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it, 'd' to skip and delete it ..."
                                 while ! git log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                     [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it, 'd' to skip and delete it ..."
                                     first=1
                                     ch=$(sed q </dev/tty)
                                     if [ "$ch" = "s" -o "$ch" = "d" ]; then
                                        echo "skip it ..."
                                        git am --skip
                                        [ "$ch" = "d" ] && rm $topdir/.myfiles/patches/$f
                                        break
                                     fi
                                 done
                              fi
                      fi
                      if [ "$project" = "android" ]; then
                            git -C $topdir/.repo/manifests am -3 -q --keep-cr --committer-date-is-author-date < $topdir/.myfiles/patches/$f
                            rc=$?
                            if [ $rc -ne 0 ]; then
                                 first=0
                                 echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it, 'd' to skip and delete it ..."
                                 while ! git -C $topdir/.repo/manifests log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                     [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it, 'd' to skip and delete it ..."
                                     first=1
                                     ch=$(sed q </dev/tty)
                                     if [ "$ch" = "s" -o "$ch" = "d" ]; then
                                        echo "skip it ..."
                                        git -C $topdir/.repo/manifests am --skip
                                        [ "$ch" = "d" ] && rm $topdir/.myfiles/patches/$f
                                        break
                                      fi
                                 done
                           fi
                      fi

                  else
                      echo "         skipping: $f ...(applied always)"
                  fi
              fi
         done
         rm -f ${tmp_skip_dirs}
    done
    cd $topdir
}

function rrCache()
{
    [ $# -eq 0 ] && return -1
    if [ "$1" = "-backup" -o "$1" = "backup" ]; then
         [ -f $topdir/.myfiles/patches/rr-cache/rr-cache.list ] && \
         find $topdir/.myfiles/patches/rr-cache/ -mindepth 1 -maxdepth 1 -type d | xargs rm -rf  &&\
         cat $topdir/.myfiles/patches/rr-cache/rr-cache.list | while read line; do
             project=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f2)
             rrid=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f1)
             if [ -d $topdir/$project/.git/rr-cache/$rrid ]; then
                  rm -rf  $topdir/.myfiles/patches/rr-cache/$project/$rrid
                  rmdir -p --ignore-fail-on-non-empty $topdir/.myfiles/patches/rr-cache/$project >/dev/null 2>/dev/null
                  if  [ -d $topdir/$project/.git/rr-cache/$rrid ] && find $topdir/$project/.git/rr-cache/$rrid -name "postimage*" > /dev/null 2>/dev/null; then
                      [ -d $topdir/.myfiles/patches/rr-cache/$project/$rrid ] || mkdir -p $topdir/.myfiles/patches/rr-cache/$project/$rrid
                      cp -r $topdir/$project/.git/rr-cache/$rrid $topdir/.myfiles/patches/rr-cache/$project/
                  fi
             fi
         done
    elif [ "$1" = "-restore" -o "$1" = "restore" ]; then
         [ -f  $topdir/.myfiles/patches/rr-cache/rr-cache.list ] && \
         cat $topdir/.myfiles/patches/rr-cache/rr-cache.list | while read line; do
             project=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f2)
             rrid=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f1)
             if [ -d $topdir/.myfiles/patches/rr-cache/$project/$rrid ] && [ ! -z "$(ls -A $topdir/.myfiles/patches/rr-cache/$project/$rrid)" ]; then
                   rm -rf $topdir/$project/.git/rr-cache/$rrid
                   [ -d $topdir/$project/.git/rr-cache/$rrid ] || mkdir -p $topdir/$project/.git/rr-cache/$rrid
                   cp -r $topdir/.myfiles/patches/rr-cache/$project/$rrid/* $topdir/$project/.git/rr-cache/$rrid/
             fi
         done
    fi
}

function reset_project_dir()
{
    [ $# -lt 1 -o ! -d "$topdir/$1" ] && return -1
    cd $topdir/$1
    git reset >/dev/null 2>/dev/null
    git cherry-pick --abort>/dev/null 2>/dev/null
    git am --abort>/dev/null 2>/dev/null
    git rebase --abort>/dev/null 2>/dev/null
    git merge --abort>/dev/null 2>/dev/null
    git stash >/dev/null 2>/dev/null
    if [ "$1" = ".repo/manifests" ]; then
         default_branch=$(cat $topdir/.repo/manifest.xml | grep "default revision" | cut -d= -f2 | sed -e "s/\"//g" -e "s/refs\/heads\///")
         git checkout default >/dev/null 2>/dev/null
         git fetch --all >/dev/null 2>/dev/null
         git reset --hard origin/$default_branch >/dev/null 2>/dev/null
    fi
    cd $topdir
}

##################################
function fix_repopick_output()
{
    [ $# -lt 1 -o ! -f "$1" ] && return -1
    logfile=$1
    count=$(grep -c "Applying change number" $logfile)
    if [ $count -ne 1 ]; then
       return 1
    fi
    bLineNo=$(grep -n "Applying change number" $logfile | cut -d: -f1 )
    if [ $bLineNo -gt 1 ]; then
        sed -n "${bLineNo},\$p" $logfile > $logfile.fix
        sed -n "1,$(expr $bLineNo - 1)p" $logfile >> $logfile.fix
        mv $logfile.fix $logfile
    fi
}

function get_active_rrcache()
{
    [ $# -lt 2 ] && return -1
    local project=$1
    [ -d $topdir/$project ] || return -1

    local md5file=$2
    local rr_cache_list="rr-cache.list"
    [ "${BASH_SOURCE[0]}" = "$runfrom" -o -f "${rr_cache_list%.*}.tmp" ] \
        && rr_cache_list="${rr_cache_list%.*}.tmp"
    [ -f "$md5file" ] || return -1
    rrtmp=/tmp/$(echo $project | sed -e "s:/:_:g")_rr.tmp
    while read line; do
        #key=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f1)
        fil=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f2)
        #typ=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f3)
        key=$(md5sum $topdir/$project/$fil | sed -e "s/ .*//g")
        [ -d $topdir/$project/.git/rr-cache ] && \
        find $topdir/$project/.git/rr-cache/ -mindepth 2 -maxdepth 2 -type f -name "postimage*" > $rrtmp
        [ -f "$rrtmp" ] && while read rrf; do
            md5num=$(md5sum $rrf|cut -d' ' -f1)
            #echo "$key ?= $md5num   ----->  $rrf"
            if [ "$key" = "$md5num" ]; then
               rrid=$(basename $(dirname $rrf))
               [ -d $topdir/.myfiles/patches/rr-cache ] || mkdir -p $topdir/.myfiles/patches/rr-cache
               [ "${BASH_SOURCE[0]}" = "$runfrom" -a ! -f $topdir/.myfiles/patches/rr-cache/rr_cache_list ] && rr_cache_list="rr-cache.list"

               [ -f $topdir/.myfiles/patches/rr-cache/$rr_cache_list ] || touch $topdir/.myfiles/patches/rr-cache/$rr_cache_list
               if ! grep -q "$rrid $project" $topdir/.myfiles/patches/rr-cache/$rr_cache_list; then
                    echo "$rrid $project" >> $topdir/.myfiles/patches/rr-cache/$rr_cache_list
               fi
            fi
        done < $rrtmp
        rm -rf $rrtmp
    done < $md5file
    rm -rf $md5file
}

function kpick()
{
    topdir=$(gettop)
    local vars=""
    local query=""
    local is_topic_op=0
    local is_query_op=0
    local is_path_op=0
    local iTopic=""
    local iQuery=""
    local iRange=""
    local extract_changeset=0
    local changeNumber

    local logfile=$topdir/.pick_tmp_$(basename $(mktemp) | cut -d. -f2).log
    local errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")
    local change_number_list=$topdir/.change_number_list_$(basename $(mktemp) | cut -d. -f2)
    local target_script=""

    rm -f $logfile $errfile $change_number_list

    for op in $*; do
        if  [ "$op" = "-t" -o "$op" = "--topic" ]; then
             is_topic_op=1
             query="$query $op"
        elif [ "$op" = "-x" ]; then
             extract_changeset=1
        elif  [ "$op" = "-Q" -o "$op" = "--query" ]; then
             is_query_op=1
             query="$query $op"
        elif  [ "$op" = "-P" -o "$op" = "--path" ]; then
             is_path_op=1
             query="$query $op"
             vars="$vars $op"
        elif [ $is_topic_op -eq 1 ]; then
             query="$query $op"
             iTopic=$op
             is_topic_op=0
        elif [ $is_query_op -eq 1 ]; then
             query="$query $op"
             iQuery=$op
             is_query_op=0
        elif [ -z "$changeNumber" ] && [[ $op =~ ^[0-9]+$ || $op =~ ^[0-9]+\/[0-9]+$ ]] && [ $(echo $op | cut -d/ -f1) -gt 1000 ]; then
             changeNumber=$op
        elif [[ "$op" =~ ^[[:digit:]]+\-[[:digit:]]+$ ]]; then
             query="$query $op"
             iRange=$op
        elif [ $is_path_op -eq 1 ]; then
             query="$query $op"
             vars="$vars $op"
             is_path_op=0
        elif [ "$op" = "-f" -o "$op" = "--force" ]; then
             query="$query $op"
             vars="$vars $op"
        else
             vars="$vars $op"
        fi
    done
    query=$(echo $query | sed -e "s/^ //g" -e "s/ $//g")
    vars=$(echo $vars | sed -e "s/^ //g" -e "s/ $//g")

    if  [ "$changeNumber" != "" ]; then
         rm -f $logfile $errfile $change_number_list
         kpick_action $changeNumber $vars
         return 0
    fi
    LANG=en_US repopick --test > $logfile 2>$errfile

    if [ -f $errfile ] && grep -q "error: unrecognized arguments: --test" $errfile; then
         echo "repopick not support --test options"
         rm -f $logfile $errfile $change_number_list
         return -1
    fi

    [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
    if [ -f $script_file.tmp ]; then
         target_script=$script_file.tmp
    elif [ -f $script_file.new ]; then
         target_script=$script_file.new
    fi

    local mLine=0
    if [ ! -z $target_script -a -f $target_script ] && [ $extract_changeset -eq 1 ]; then
        if [ "$iQuery" != "" ]; then
             mLine=$(grep -n "^[[:space:]]*kpick.*$iQuery" $target_script | cut -d: -f1 )
             sed -e "s|\([[:space:]]*kpick.*${iQuery}\)|#\1|" -i $target_script
        elif [ "$iTopic" != "" ]; then
             mLine=$(grep -n "^[[:space:]]*kpick.*$iTopic" $target_script | cut -d: -f1 )
             sed -e "s|\([[:space:]]*kpick.*${iTopic}\)|#\1|" -i $target_script
        elif [ "$iRange" != "" ]; then
             mLine=$(grep -n "^[[:space:]]*kpick.*$iRange" $target_script | cut -d: -f1 )
             sed -e "s|\([[:space:]]*kpick.*${iRange}\\)|#\1|" -i $target_script
        fi
        if [ $? -ne 0 ]; then
            if [ "${BASH_SOURCE[0]}" = "$runfrom" ]; then
                 exit -1
            else
                 return -1
            fi
        fi
    fi

    LANG=en_US repopick --test $query | grep "Testing change number" | cut -d" " -f 4 > $change_number_list || return -1
    [ -f $change_number_list ] || return 0
    while read line; do
        number=$(echo $line | sed -e "s/  / /g")
        if [ ! -z $target_script -a -f $target_script ] && [ $extract_changeset -eq 1 ]; then
           sed "${mLine}akpick $number" -i  $target_script
           if [ $? -ne 0 ]; then
               if [ "${BASH_SOURCE[0]}" != "$runfrom" ]; then
                    return $?
               else
                    exit -1
               fi
           fi
           mLine=$((mLine + 1))
        fi
    done < $change_number_list

    while read line; do
        number=$(echo $line | cut -d" " -f 3)
        kpick_action $number $vars
    done < $change_number_list
    rm -f $logfile $errfile $change_number_list
}

function kpick_action()
{
    topdir=$(gettop)
    conflict_resolved=0
    op_force_pick=0
    logfile=$topdir/.pick_tmp_$(basename $(mktemp) | cut -d. -f2).log
    errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")

    rm -f $errfile $logfile
    echo ""
    local changeNumber=""
    local op_is_m_parent=0
    local op_is_topic=0
    local topic=""
    local m_parent=1
    local nops=""
    local op
    local count=$maxCount
    local recent_changeid_tmp
    local md5file
    local pick_skiped=0

    for op in $*; do
        if [ $op_is_m_parent -eq 1 ]; then
             [[ $op =~ ^[0-9]+$ ]] && [ $op -lt 10 ] && m_parent=$op
             op_is_m_parent=0
             continue
        elif [ $op_is_topic -eq 1 ]; then
             topic=$op
             op_is_topic=0
        elif [ "$op" = "-m" ]; then
             op_is_m_parent=1
             continue
        fi
        [ -z "$changeNumber" ] &&  [[ $op =~ ^[0-9]+$ || $op =~ ^[0-9]+\/[0-9]+$ ]] && [ $(echo $op | cut -d/ -f1) -gt 1000 ] && changeNumber=$op
        [ "$op" = "-f" -o "$op" = "--force" ] && op_force_pick=1
        [ "$op" = "-t" -o "$op" = "--topic" ] && op_is_topic=1
        if [ "$nops" = "" ]; then
             nops=$op
        else
             nops="$nops $op"
        fi
    done
    if  [ "$changeNumber" = "" ]; then
         return -1
    fi
    # calculate check Count
    LANG=en_US repopick --test $changeNumber >$logfile 2>$errfile
    if [ -f $errfile ] && ! grep -q "error: unrecognized arguments: --test" $errfile; then
          if grep -q "\--> Project path:" $logfile; then
              local project_dir=$(grep "\--> Project path:" $logfile | cut -d: -f2 | sed  "s/ //g")
              if [ ! -z $project_dir -a -d $topdir/$project_dir ]; then
                  cd $topdir/$project_dir
                  default_branch=$(grep "^[[:space:]]*<default revision=" $topdir/.repo/manifests/default.xml | sed -e 's:[^"]*"\(.*\)":\1:' | sed -e "s:refs/heads/::g")
                  count=$(git log --pretty="format:%D" --max-count=$maxCount | grep -n "m/$default_branch" | cut -d: -f1)
                  [ -z $count ] && count=$maxCount
                  cd $topdir
              fi
          fi
    fi

    [ $count -lt $minCount ] && count=$minCount

    echo ">>> Picking change $changeNumber ..."
    LANG=en_US repopick -c $count $nops >$logfile 2>$errfile
    rc=$?
    local subject=$(grep -Ri -- '--> Subject:' $logfile | sed 's/--> Subject:[[:space:]]*//g')
    if [ "${subject:0:1}" = '"' ]; then
          subject=$(echo $subject | sed 's/^"//' | sed 's/"$//' )
    fi
    if [ $(echo $subject | wc -c) -gt 120 ]; then
          subject="${subject:0:115} ..."
    fi
    subject=$(echo $subject | sed "s/\"/\\\\\"/g" | sed "s/'/\\\\\'/g" | sed "s/\&/\\\&/g")
    subject=$(echo $subject | sed "s/\`/\\\\\`/g" | sed -e "s/|/\\\|/g" | sed "s:/:\\\/:g")
    fix_repopick_output $logfile
    cat $logfile | sed -e "/ERROR: git command failed/d" | sed "/Force-picking a closed change/d"
    project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
    [ -d $topdir/$project ] || project=""
    local tries=0
    local breakout=0
    local pick_mode="reopick"
    while [ $rc -ne 0 -a -f $errfile ];  do
          [ $tries -ge 1 ] && echo ".... try "$(expr $tries + 1)"..."
          #cat  $errfile
          if [ $tries -ge 30 ]; then
                echo "    >> pick faild !!!!!"
                breakout=-1
                break
          fi

          if grep -q "is a merge but no -m option was given" $errfile; then
              pick_mode="fetch"
              project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
              ref=$(cat $logfile | grep "\['git"  | cut -d, -f2 | sed -e "s: u'\(.*\)']:\1:")
              url=$(cat $errfile | grep "^From " | sed -e "s/From //" | sed -e "s/git:/https:/")
              cd $topdir/$project
              #echo "git fetch $url $ref && git cherry-pick -m $m_parent FETCH_HEAD"
              if git fetch $url $ref; then
                     rchid=$(git log FETCH_HEAD -n 1 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g")
                     recent_changeid_tmp=/tmp/$(echo $project | sed -e "s:/:_:g")_recent_ids_$(basename $(mktemp) | cut -d. -f2).txt
                     git log -n 50 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g" > $recent_changeid_tmp
                     if grep -q $rchid $recent_changeid_tmp; then
                         echo "Change is  cherry-picked always! skipping it..."
                     else
                         LANG=en_US git cherry-pick -m $m_parent FETCH_HEAD >$logfile 2>$errfile
                     fi
              fi
              rc=$?
              cd $topdir
              if [ $rc -eq 0 ]; then
                   rm -f $errfile
                   [ -z $recent_changeid_tmp ] ||  rm -f $recent_changeid_tmp
                   breakout=0
                   break
              fi
          fi

          grep -q -E "nothing to commit|allow-empty" $errfile && breakout=1 && break


          if grep -q -E "error EOF occurred|httplib\.BadStatusLine|urllib2\.URLError|urllib2\.HTTPError|Connection refused" $errfile; then
              #echo "  >> pick was interrupted, retry ("$(expr $tries + 1)")..."
              #cat $logfile | sed -e "/ERROR: git command failed/d"
              #cat $errfile
              echo ""
              sleep 2
              [ $tries -ge 2 ] && https_proxy=""
              LANG=en_US https_proxy="$https_proxy" repopick -c $count $nops >$logfile 2>$errfile
              rc=$?
              if [ $rc -ne 0 ]; then
                  #cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              else
                  fix_repopick_output $logfile
                  cat $logfile
                  breakout=0
                  rm -f $errfile
                  break
              fi
          fi

          if grep -q "conflicts" $errfile; then
              echo "!!!!!!!!!!!!!"
              cat $errfile
              [ -z $project ] && project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
              md5file=/tmp/$(echo $project | sed -e "s:/:_:g")_rrmd5_$(basename $(mktemp) | cut -d. -f2).txt
              rm -rf $md5file
              if [ "$project" != "" -a -d $topdir/$project ]; then
                    touch $md5file
                    if LANG=en_US git -C $topdir/$project status | grep -q "Untracked files:"; then
                        git -C $topdir/$project clean -xdf
                        if git -C $topdir/$project commit --no-edit; then
                             breakout=0
                             break
                        fi
                    fi
                    if grep -q "using previous resolution" $errfile; then
                       echo "------------"
                       cd $topdir/$project
                       grep "using previous resolution" $errfile | sed -e "s|Resolved '\(.*\)' using previous resolution.*|\1|" \
                           | xargs md5sum | sed -e "s/\(.*\)/\1 postimage/" >>$md5file
                       grep "using previous resolution" $errfile | sed -e "s|Resolved '\(.*\)' using previous resolution.*|\1|" \
                           | xargs git add -f
                       if git commit --no-edit; then
                          breakout=0
                          conflict_resolved=1
                          get_active_rrcache $project $md5file
                          cd $topdir
                          break
                       fi
                       cd $topdir
                       echo "------------"
                    fi
                    if grep -q "Recorded preimage for" $errfile; then
                       cd $topdir/$project
                       grep "Recorded preimage for" $errfile | cut -d\' -f2 | xargs md5sum | sed -e "s/\(.*\)/\1 preimage/" >>$md5file
                       cd $topdir
                    fi
                    if LANG=en_US git -C $topdir/$project status | grep -q "Untracked files:"; then
                        git -C $topdir/$project clean -xdf
                    fi
              fi
              echo  "  >> pick changes conflict, please resolv it, then press ENTER to continue, or press 's' skip it ..."
              ch=$(sed q </dev/tty)
              if [ "$ch" = "s" ]; then
                    echo "skip it ..."
                    cd $topdir/$project
                    git cherry-pick --abort >/dev/null 2>/dev/null
                    pick_skiped=1
                    cd $topdir
                    break
              fi
              if [ "$pick_mode" = "fetch" ]; then
                    cd $topdir/$project
                    rchid=$(git log FETCH_HEAD -n 1 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g")
                    recent_changeid_tmp=/tmp/$(echo $project | sed -e "s:/:_:g")_recent_ids_$(basename $(mktemp) | cut -d. -f2).txt
                    git log -n 50 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g" > $recent_changeid_tmp
                    grep -q $rchid $recent_changeid_tmp || \
                       LANG=en_US git cherry-pick -m $m_parent FETCH_HEAD >$logfile 2>$errfile
                    rc=$?
                    cd $topdir
              else
                    cd $topdir
                    LANG=en_US repopick -c $count $nops >$logfile 2>$errfile
                    rc=$?
              fi
              if [ $rc -eq 0 ]; then
                  echo "  conflicts resolved,continue ..."
                  breakout=0
                  conflict_resolved=1
                  get_active_rrcache $project $md5file
                  break
              else
                  cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              fi
          fi
          if grep -q "could not determine the project path for" $errfile; then
              echo "Not determine the project, skipping it ..."
              breakout=0
              break
          fi

          [ -f $errfile ] && cat $errfile
          echo  "  >> please resolv it, then press ENTER to continue, or press 'a' abort it ..."
          ch=$(sed q </dev/tty)
          if [ "$ch" != "a" ]; then
                cd $topdir
                LANG=en_US repopick -c $count $nops >$logfile 2>$errfile
                rc=$?
                continue
          fi

          echo "  >>**** repopick failed !"
          breakout=-1
          break
    done

    [ -z $recent_changeid_tmp ] ||  rm -f $recent_changeid_tmp

    if [ $breakout -lt 0 ]; then
        [ -f $errfile ] && cat $errfile
        if [ "${BASH_SOURCE[0]}" != "$runfrom" ]; then
           return $breakout
        else
          [ -f $errfile ] && cat $errfile
          echo  "  >> please resolv it, then press ENTER to continue, or press 'a' abort it ..."
          ch=$(sed q </dev/tty)
          if [ "$ch" = "a" ]; then
               exit  $breakout
          fi
        fi
    elif [ -f $logfile ]; then
        [ "$project" = "" ] && project=$(cat $logfile | grep "Project path" | cut -d: -f2)
        [ "$project" = "" ] || project=$(echo $project | sed "s/ //g")
        ref=$(grep "\['git fetch" $logfile | cut -d, -f2 | cut -d\' -f2)
        if [ "$project" = "android" -a $op_keep_manifests -ne 1 ]; then
             cd $topdir/android
             git format-patch HEAD^ --stdout > /tmp/change_$changeNumber.patch
             local changeid=$(grep "Change-Id:" /tmp/change_$changeNumber.patch | cut -d' ' -f 2)
             cd $topdir/.repo/manifests
             git log -n 50 | grep "Change-Id:"  | cut -d: -f2 | sed -e "s/ //g" > /tmp/manifest_changeids.txt
             if ! grep -q "$changeid" /tmp/manifest_changeids.txt;  then
                 if ! git am -3 < /tmp/change_$changeNumber.patch >/dev/null 2>/tmp/change_$changeNumber.err; then
                      echo  "  >> git am conflict, please resolv it, then press ENTER to continue ..."
                      sed q </dev/tty
                 fi
             fi
             rm -f /tmp/change_$changeNumber.patch /tmp/change_$changeNumber.err /tmp/manifest_changeids.txt
             cd $topdir
        fi
        local finish_doing=0
        if [ ! -z $changeNumber ]; then
            if grep -q -E "Change status is MERGED.|nothing to commit|git command resulted with an empty commit" $logfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
                    sed "/^[[:space:]]*kpick[[:space:]]\{1,\}${changeNumber}[[:space:]]*.*/d" -i $target_script
               finish_doing=1
            elif grep -q -E "Change status is ABANDONED." $logfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
               sed  "/^[[:space:]]*kpick[[:space:]]\{1,\}${changeNumber}[[:space:]]*.*/d" -i $target_script
               finish_doing=1
            elif grep -q -E "Change $changeNumber not found, skipping" $logfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
               sed "/^[[:space:]]*kpick[[:space:]]\{1,\}${changeNumber}[[:space:]]*.*/d" -i $target_script
               finish_doing=1
            elif [ -f $errfile ] && grep -q "could not determine the project path for" $errfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
               sed "s/^[[:space:]]*\(kpick[[:space:]]\{1,\}${changeNumber}[[:space:]]*.*\)/# \1/" -i $target_script
               finish_doing=1
            elif [ $pick_skiped -eq 1 ]; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
              sed "s/^[[:space:]]*\(kpick[[:space:]]\{1,\}${changeNumber}[[:space:]]*.*\)/# \1/" -i $target_script
               finish_doing=1
            fi
         fi
    fi

    if [ "$changeNumber" != "" -a "$subject" != "" -a "$project" != "" -a $finish_doing -eq 0 ];  then
           [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
           if [ -f $script_file.tmp ]; then
                target_script=$script_file.tmp
           elif [ -f $script_file.new ]; then
                target_script=$script_file.new
           fi
           [ ! -z $target_script -a -f $target_script ] && \
           if [ "$last_project" != "$project" -a "${BASH_SOURCE[0]}" = "$runfrom" -a "$start_check_classification" = "1" ]; then
               if [ "$last_project" != "" -a "$last_changeNumber" != "" ]; then
                    [ -f $tmp_picks_info_file ] || touch $tmp_picks_info_file
                    if ! grep -q "$project" $tmp_picks_info_file; then
                        echo "$last_project $last_changeNumber" >>$tmp_picks_info_file
                        last_project=$project
                        last_changeNumber=$changeNumber
                        if grep -iq "^[[:space:]]*#[[:space:]]*$project[[:space:]]*$" $target_script; then
                            sed "/^[[:space:]]*kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${changeNumber}/d" -i $target_script
                            project_offset=$(grep -in "^[[:space:]]*#[[:space:]]*$project[[:space:]]*$" $target_script | cut -d: -f 1 | head -n 1)
                            sed "${project_offset} akpick ${nops} \# ${subject}" -i $target_script
                        else
                            sed "/^[[:space:]]*kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${changeNumber}/i\# ${project}" -i $target_script
                            sed -e "s/^\([[:space:]]*\)kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${changeNumber}[[:space:]]*.*/\1kpick ${nops} # ${subject}/g" -i $target_script
                            sed "/^[[:space:]]*kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${changeNumber}/a\\\r" -i $target_script
                        fi
                    else
                        if grep -q "already picked in" $logfile; then
                           if [ $(grep "^[[:space:]]*kpick[[:space:]]*\(.*[[:space:]]\{1,\}\|\)$changeNumber[[:space:]]*" $target_script | wc -l) -ge 2 ]; then
                                local first_find_lineNo=$(grep -n "kpick[[:space:]]*\(.*[[:space:]]\{1,\}\|\)$changeNumber" $target_script | cut -d: -f1 | head -n 1)
                                first_find_lineNo=$(( first_find_lineNo + 1 ))
                                local second_find_lineNo=$(sed -n "${first_find_lineNo},\$p" $target_script | grep -n "kpick[[:space:]]*.*$changeNumber" | cut -d: -f1 | head -n 1 )
                                second_find_lineNo=$(( $second_find_lineNo - 1 ))
                                second_find_lineNo=$(( $first_find_lineNo + $second_find_lineNo ))
                                sed "${second_find_lineNo}d" -i $target_script
                           fi
                        else
                            sed "/^[[:space:]]*kpick[[:space:]]*\(.*[[:space:]]\{1,\}\|\)${changeNumber}/d" -i $target_script
                            project_lastpick=$(grep  "$project" $tmp_picks_info_file | cut -d" " -f2)
                            sed "/^[[:space:]]*kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${project_lastpick}/a\\kpick ${nops} \# ${subject}" -i $target_script
                            sed "s:${last_project} .*:${last_project} ${changeNumber}:g" -i $tmp_picks_info_file
                        fi
                    fi
               else
                    [ "$last_project" = "" ] && last_project=$project
                    [ "$last_changeNumber" = "" ] && last_changeNumber=$changeNumber
                    sed -e "s/^\([[:space:]]*\)kpick[[:space:]]\{1,\}${changeNumber}[[:space:]]*.*/\1kpick ${nops} \# ${subject}/g" -i $target_script
                    sed -e "s/^\([[:space:]]*\)kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${changeNumber}[[:space:]]*.*/\1kpick ${nops} # ${subject}/g" -i $target_script
               fi
           else
               sed -e "s/^\([[:space:]]*\)kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${changeNumber}[[:space:]]*.*/\1kpick ${nops} # ${subject}/g" -i $target_script
               sed -e "s/^\([[:space:]]*\)kpick[[:space:]]\{1,\}\(.*[[:space:]]\{1,\}\|\)${changeNumber}[[:space:]]*.*/\1kpick ${nops} # ${subject}/g" -i $target_script
               last_changeNumber=$changeNumber
           fi
    fi
    rm -f $errfile $logfile
}

function privpick() {
    [ $# -lt 2 ] && return 1
    git -C $1 fetch github $2
    git -C $1 cherry-pick FETCH_HEAD
}

# merge_from_aosp <path> <aosp_project> <tag or branch>
function merge_from_aosp() {
    [ $# -lt 3 ] && return 1
    #git -C $topdir/$1 merge https://android.googlesource.com/$2 $3
     git -C $topdir/$1 fetch https://android.googlesource.com/$2 $3:$3
     if git -C $topdir/$1 tag | grep -q $3 || git -C $topdir/$1 branch | grep -q $3; then
         if ! git -C $topdir/$1 merge $3 --no-edit; then
                 echo  "  >> please resolv it, then press ENTER to continue, or press 's' skip it ..."
                 ch=$(sed q </dev/tty)
                 if [ "$ch" = "s" ]; then
                     git git -C $topdir/$1 merge --abort
                 fi
         fi
     fi
     return $?
}

function apply_force_changes(){
    [ -z $topdir ] && topdir=$(gettop)
    [ -d "$topdir/.myfiles/patches/local/vendor/lineage"  ] || return 0
    find $topdir/.myfiles/patches/local/vendor/lineage/ -type f -name "*-\[ALWAYS\]-*.patch" -o -name "*-\[ALWAYS\]-*.diff" \
      | sort | while read f; do
         cd $topdir/vendor/lineage;
         if ! git am -3 -q   --keep-cr --committer-date-is-author-date < $f; then
             if [ "${BASH_SOURCE[0]}" = "$runfrom" ]; then
                 echo  "  >> please resolv it, then press ENTER to continue, or press 's' skip it ..."
                 ch=$(sed q </dev/tty)
                 if [ "$ch" = "s" ]; then
                     git am --skip
                 fi
             else
                 return -1
             fi
         fi
    done
}
########## main ###################

get_defaul_remote

for op in $*; do
    if [ "$op" = "-pl" -o "$op" = "--patch_local" ]; then
         op_patch_local=1
    elif [ "$op" = "--reset" -o "$op" = "-r" ]; then
         op_reset_projects=1
    elif [ "$op" = "--snap" -o "$op" = "-s" ] && [ ! -f $topdir/.pick_base ]; then
         op_project_snapshot=1
    elif [ "$op" = "--restore" -o "$op" = "--restore-snap" ]; then
         op_restore_snapshot=1
    elif [ "$op" = "--remote-only" -o "$op" = "-ro" ]; then
         op_pick_remote_only=1
    elif [ "$op" = "-rp" -o "$op" = "-pr" ]; then
         op_reset_projects=1
    elif [ "$op" = "-c" -o "$op" = "--continue" ]; then
         op_pick_continue=1
    elif [ "$op" = "--backup-rr-cache" ]; then
         rrCache -backup
         exit $?
    elif [ "$op" = "--restore-rr-cache" ]; then
         rrCache -restore
         exit $?
    elif [ "$op" = "-a" -o "$op" = "--auto" ]; then
         op_auto=1
    elif [ $op_patch_local -eq 1 ]; then
            op_patches_dir="$op"
    elif [ $op_project_snapshot -eq 1 -a  -d "$(gettop)/$op" ]; then
         op_snap_project=$op
    elif [ "$op" = "-nop" ]; then
          return 0
    elif [ "$op" = "-base" ]; then
         op_base_pick=1
    elif [ "$op" = "--keep-manifests" ]; then
         op_keep_manifests=1
    else
         echo "kpick $op"
         kpick $op
         exit $?
    fi
done

if [ $# -ge 1 ]; then
   if [ $op_project_snapshot -eq 1 ]; then
         projects_snapshot $op_snap_project
         exit $?
   fi
   if [ $op_reset_projects -eq 1 ]; then
         projects_reset
         exit $?
   fi
   if [ $op_patch_local -eq 1 ]; then
         patch_local $op_patches_dir
         exit $?
   fi
   if [ $op_restore_snapshot -eq 1 ]; then
         restore_snapshot
         exit $?
   fi
   [ $op_pick_remote_only -eq 1 ] && exit 0
fi

###############################################################
# patch repopick first
topdir=$(gettop)
rm -rf $topdir/.pick_base

rrCache restore # restore rr-cache


###################################
#---------base pick --------------#
if [ $op_base_pick -eq 1 ]; then
   cd $topdir/.repo/manifests; git reset --hard $(git log -20 --all --decorate | grep commit | grep "m/lineage-" | cut -d' ' -f 2);
   cd $topdir
   repo sync
   [ $? -ne 0 ] && exit
   apply_force_changes


   echo
   echo "Apply I hate the safty net..."
   privpick system/core refs/changes/19/206119/2 # init: I hate safety net
   touch $topdir/.pick_base
   exit 0
fi
#---------------------------------#
###################################

trap 'int_handler' INT

if [ "${BASH_SOURCE[0]}" = "$runfrom" -a ! -f ${BASH_SOURCE[0]}.tmp -a $op_pick_continue -eq 0 ]; then    # continue pick or not
    [ $op_keep_manifests -ne 1 ] && reset_project_dir .repo/manifests
    reset_project_dir vendor/lineage
    repo sync vendor/lineage >/dev/null
    [ $? -ne 0 ] && exit
    apply_force_changes
    rm -f $tmp_picks_info_file
    reset_overwrite_projects

    # android

    repo sync android  >/dev/null
    [ $op_keep_manifests -ne 1 ] && reset_project_dir .repo/manifests

    #=========== pick changes ==========================


    #===================================================

    patch_local local/android
    echo

    android_head=$(cd android;git log -n 1 | sed -n 1p | cut -d' ' -f2;cd $topdir)
    if [ $op_keep_manifests -ne 1 ]; then
       repo sync --force-sync
       rc_sync=$?
    fi
    cd android;git reset --hard $android_head >/dev/null;cd $topdir

    apply_force_changes

    [ $op_keep_manifests -ne 1 -a $rc_sync -ne 0 ] && exit -1

fi       # continue pick or not

# ==========================================================

# first pick for repopick
# kpick 234859 # repopick: cmp() is not available in Python 3, define it manually

# start check classification of picking project is correct or not
rm -f $tmp_picks_info_file
start_check_classification=1

# *******************************************************
# **            MAIN PICKS                             **
# *******************************************************

# ==== DEVICE STUFF ======

# device/samsung/klte-common
#kpick 212648 # klte-common: Enable AOD
kpick 220435 # klte-common: Add HFR/HSR support

# device/samsung/kltechnduo

# device/samsung/msm8974-common

# kernel/samsung/msm8974

# ====== OTHER ==============
# bionic
kpick 217311 # linker: add support for odm partition
kpick 217312 # libc: add /odm/bin to the DEFPATH
kpick 221709 # libc: Add generated copyrights

# bootable/recovery
kpick 219194 # minui: drm: ARGB8888 support
kpick 219195 # minui: drm: wait for page flip event before next flip

# build/make
kpick 208381 # build: Add ability for device to specify additional targets
kpick 208567 # [DNM] updater: Don't check fingerprint for incrementals
kpick 209023 # build: Add script to generate extra images
kpick 209024 # Generate extra userdata partition if needed
kpick 209025 # Strip out unused extra image generation
kpick 210238 # releasetools: Store the build.prop file in the OTA zip
kpick 212820 # build: Implement prebuilt caching
kpick 213515 # build: Use minimal compression when zipping targetfiles
kpick 213572 # Allow to exclude imgs from target-files zip
kpick 222016 # releasetools: Add system-as-root handling for non-A/B backuptool
kpick 222017 # core: Add bootimage only cmdline flag
kpick 222034 # build: Allow using prebuilt vbmeta images in signed builds

# build/soong

# device/lineage/sepolicy

# device/qcom/sepolicy
kpick 211273 # qcom/sepol: Fix timeservice app context

# external/ant-wireless/ant_native

# external/chromium-webview

# external/f2fs-tools

# external/tinecompress
# external/tinycompress
kpick 215115 # tinycompress: Replace deprecated kernel header path


# external/toybox

# frameworks/av
kpick 209904 # Camera2Client: Add support for QTI parameters in Camera2Client
kpick 209905 # Camera2Client: Add support for QTI specific ZSL feature
kpick 209906 # Camera2Client: Add support for QTI specific AE bracketing feature
kpick 209907 # Camera2Client: Add support for QTI specific HFR feature
kpick 209908 # Camera2Client: Add support for non-HDR frame along with HDR
kpick 209909 # Camera2Client: Add support for enabling QTI DIS feature
kpick 209910 # Camera2Client: Add support for enabling QTI Video/Sensor HDR feature
kpick 209911 # Camera2Client: Add support for QTI specific AutoHDR and Histogram feature
kpick 209912 # Camera: Skip stream size check for whitelisted apps.
kpick 220018 # Camera2Client: Add support for Raw snapshot in Camera2Client
kpick 220019 # Camera2Client: Integrate O-MR1 changes for QTI camera2client
kpick 220020 # Camera2Client: Disable ZSL by default in QTI camera2client
kpick 220021 # Camera2Client: Use Max YUV Resolution instead of active array size.
kpick 220022 # Camera2Client: Use StreamConfiguration to find available raw sizes.
kpick 220023 # Camera2Client: Fix issue with supported scene modes.
kpick 220024 # Camera2Client: Update vendor tag only if it is present
kpick 220025 # Camera2Client: Fix issue with AE Bracketing mode.
kpick 223145 # av: camera: Allow disabling shutter sound for specific packages
kpick 234657 # camera: Allow to use boottime as timestamp reference

# frameworks/base
kpick 206054 -f # SystemUI: use vector drawables for navbar icons
kpick 206055 -f # SystemUI: Add a reversed version of OPA layout
kpick 206056 -f # opalayout: Actually implement setDarkIntensity
kpick 206057 -f # opapayout: Update for r23 smaller navbar
kpick 206058 -f # opalayout/home: Fix icons and darkintensity
kpick 206059 -f # OpaLayout: misc code fixes
kpick 206568 # base: audioservice: Set BT_SCO status
kpick 207583 # BatteryService: Add support for oem fast charger detection
kpick 209031 # TelephonyManager: Prevent NPE when registering phone state listener.
kpick 206940 # Avoid crash when the actionbar is disabled in settings
kpick 216872 # SystemUI: Fix systemui crash when showing data usage detail
kpick 218359 # Revert "SystemUI: disable wallpaper-based tint for scrim"
kpick 218430 # SystemUI: Require unlock to toggle airplane mode
kpick 218431 # SystemUI: Require unlock to toggle location
kpick 218437 # SystemUI: Add activity alias for LockscreenFragment
kpick 219930 # Telephony: Stop using rssnr, it falsly shows wrong signal bars Pixel and other devices drop this
kpick 221518 # [1/2] base: allow disable of screenshot shutter sound
kpick 221654 # Disable restrictions on swipe to dismiss and action bars
kpick 222226 # [1/3] SystemUI: add burnIn protection setting
kpick 223332 # Animation and style adjustments to make UI stutter go away
kpick 223333 # Set windowElevation to 0 on watch dialogs.
kpick 223334 # Update device default colors for darker UI
kpick 224392 # VibratorService: Apply vibrator intensity setting.
kpick 226009 # Make volume steps and defaults adjustable for all audio streams
kpick 228542 # Add CHANNEL_MODE_DUAL_CHANNEL constant
kpick 228543 # Add Dual Channel into Bluetooth Audio Channel Mode developer options menu
kpick 228544 # Allow SBC as HD audio codec in Bluetooth device configuration
kpick 229239 # fw/b: fix adb restore of apks
kpick 229251 # Allow media to read sdcards
kpick 231005 # SystemUI: Make scrims dark & text white by pretending wallpaper is black
kpick 235091 # Button action pull status bar
kpick 237124 # power: disable the proximity sensor screen-off function after user set.

# frameworks/native
kpick 213549 # SurfaceFlinger: Support get/set ActiveConfigs.

# frameworks/opt/chips

# frameworks/opt/net/wifi

# frameworks/opt/telephony
kpick 215450 # Add changes for sending ATEL UI Ready to RIL.
kpick 220429 # telephony: Allow overriding getRadioProxy

# hardware/broadcom/libbt

# hardware/broadcom/wlan

# hardware/interfaces

# hardware/libhardware
kpick 228545 # Add CHANNEL_MODE_DUAL_CHANNEL

# hardware/lineage/interfaces
kpick 219211 # livedisplay: Move HIDL service to late_start
# kpick 219885 # livedisplay: Add a system variant
kpick 221642 # interfaces: Add vendor.lineage.stache@1.0::ISecureStorage
kpick 221643 # interfaces: Do not add custom interfaces to VNDK
kpick 221644 # stache: Add default ext4 crypto implementation
kpick 224208 # camera: 1.0-legacy: Build with BOARD_VNDK_VERSION=current

# hardware/lineage/lineagehw
#kpick 222510 # Remove deprecated VibratorHW

# hardware/lineage/telephony

# hardware/qcom/audio-caf/msm8974

# hardware/qcom/bootctrl

# hardware/qcom/bt
kpick 220887 # bt: use TARGET_BOARD_AUTO to override qcom hals

# hardware/qcom/bt-caf

# hardware/qcom/display
kpick 209093 # msm8974: hwc: Set ioprio for vsync thread
kpick 220883 # hwc2: Do not treat color mode errors as fatal at init
kpick 220885 # color_manager: Update display color api libname

# hardware/qcom/display-caf/msm8974

# hardware/qcom/gps
kpick 220877 # gps: use TARGET_BOARD_AUTO to override qcom hals

# hardware/qcom/media

# hardware/qcom/media-caf/apq8084

# hardware/qcom/media-caf/msm8960
kpick 227337 # mm-video-v4l2: Protect buffer access and increase input buffer size

# hardware/qcom/media-caf/msm8974

# hardware/qcom/media-caf/msm8994

# hardware/qcom/keymaster

# hardware/qcom/power
#kpick 226912 # power: only start power HAL service after mpdecision running
#kpick 227390 # power: Clean up hint IDs

# hardware/qcom/thermal

# haedware/qcom/vr

# hardware/qcom/wlan-caf

# hardware/samsung
kpick 218823 # audio: Add flag to opt in/out amplifier support

# lineage/charter
kpick 213574 # charter: Add some new USB rules
kpick 218835 # verity: change wording, as this is required for a/b builds
kpick 237802 # charter: Make changes for the jira to gitlab move
kpick 218728 # charter: Add recovery requirement
kpick 225930 # Clarify LVT patch requirements
kpick 213836 # charter: add vendor patch level requirement

# lineage/jenkins

# lineage/scripts
kpick 207545 # Add batch gerrit script

# lineage/website(LineageOS/www)

# lineage/wiki
kpick 219543 # wiki: add workaround for booting into TWRP recovery
# kpick 219164 # Introduce a supported versions column in device tables

# lineage-sdk
kpick 213367 # NetworkTraffic: Include tethering traffic statistics
kpick 235090 # Button action pull status bar. Expands the status bar when it is collapsed otherwise it gets collapsed.

# packages/apps/Bluetooth
kpick 228546 # SBC Dual Channel (SBC HD Audio) support

# packages/apps/Camera2

# packages/apps/Contacts

# packages/apps/Dialer
kpick 211135 # Show proper call duration
#kpick 222240 # Dialer: add to support multi-language smart search

# packages/apps/DeskClock
kpick 222493 # Overlay layouts for round-watch

# packages/apps/Eleven

# packages/apps/Email

# packages/apps/Exchange
kpick 211382 # Exchange: request permissions

# packages/apps/Flipflap
kpick 230989 # Add an option to keep brightness unchanged

# packages/apps/Gallery2

# packages/apps/Jelly

# packages/apps/LineageParts
kpick 218315 # LineageParts: Fix brightness section
kpick 222572 # DNM: Remove icons and center layouts
kpick 235089 # Button action pull status bar. Expands the status bar when it is collapsed otherwise it gets collapsed.

# packages/apps/lockClock
kpick 208127 # WIP: Update LockClock to use Job APIs

# packages/apps/Messaging

# packages/apps/Nfc

# packages/apps/Recoder

# packages/apps/Settings
kpick 216687 # settings: wifi: Default to numeric keyboard for static IP items
kpick 218438 # Settings: Add lockscreen shortcuts customization to lockscreen settings
kpick 221519 # [2/2] Settings: allow disable of screenshot shutter sound
kpick 221840 # Fixed translation
kpick 227965 # Settings / Data usage: Add menu option to switch off captive portal
kpick 237269 # fingerprint: Remove unnecessary spacing in enroll layout
kpick 237312 # Settings: More space on fingerprint enrollment

# packages/apps/Snap
kpick 206595 # Use transparent navigation bar.
kpick 222005 # Snap: Add Denoise to video menu

# packages/apps/Trebuchet

# packages/apps/UnifiedEmail

# packages/apps/Updater
kpick 219924 # Updater: Allow to suspend A/B updates

# packages/overlays/Lineage

# packages/providers/ContactsProvider

# packages/providers/DownloadProvider

# packages/resources/devicesettings

# pakcages/service/Telecomm

# packages/service/Telephony

# prebuilts/build-tools

# prebuilts/misc

# system/bt
kpick 228592 # Allow using alternative (higher) SBC HD bitrates with a property
kpick 239015 # Increase maximum Bluetooth SBC codec bitrate for SBC HD
kpick 228548 # Explicit SBC Dual Channel (SBC HD) support

# system/core
kpick 206029 # init: Add command to disable verity
privpick system/core refs/changes/19/206119/2 # init: I hate safety net
kpick 213876 # healthd: charger: Add tricolor led to indicate battery capacity
kpick 215626 # Add vendor hook to handle_control_message
kpick 217313 # add odm partition to ld.config.legacy
kpick 217314 # Allow firmware loading from ODM partition
kpick 218837 # libsuspend: Add property support for timeout of autosuspend
kpick 219304 # init: Allow devices to opt-out of fsck'ing on power off
kpick 222237 # DO NOT MERGE: Add back atomic symbols
kpick 234734 # fs_mgr: Implement external resize fstab option

# system/extras
kpick 211210 # ext4: Add /data/stache/ to encryption exclusion list

# system/extras/su
kpick 225873 # su: strlcpy is always a friend
kpick 225875 # su: Enable Clang Tidy
kpick 225879 # su: Run clang format
kpick 225880 # su: Move to cutils/properties.h
kpick 225885 # su: Remove Sammy hacks
kpick 225888 # su: Fix a clang tidy warning
kpick 225889 # su: Cleanup includes
kpick 225890 # su: Use shared libraries
kpick 225936 # su: Remove mount of emulated storage
kpick 225937 # su: Initialize windows size

# system/libhidl

# system/netd

# system/nfc
kpick 219760 # Fix SDCLANG-6.0 warnings

# system/qcom
kpick 215122 # libQWiFiSoftApCfg: Replace deprecated kernel header path

# system/security

# system/sepolicy

# system/update/engine

# system/vold
kpick 218416 # vold: utils: Introduce ForkCallp

# vendor/lineage
kpick 206154 # Include build manifest on target
kpick 210664 # extract_utils: Support multidex
kpick 217527 # tools: Rewrite sdat2img
kpick 217528 # sdat2img: Add support for brotli compressed files
kpick 217628 # lineage: add generic x86_64 target
kpick 217629 # kernel: Add TARGET_KERNEL_ADDITIONAL_FLAGS to allow setting extra cflags
kpick 217630 # kernel: Add kernelversion recipe to generate MAJOR.MINOR kernel version
kpick 218817 # kernel: Do not attempt to build modules if there aren't any
kpick 218832 # lineage: Add prebuilt patchelf binaries and patch_blob function
kpick 219388 # config: Add more GMS client base ID props
kpick 219389 # lineage: Always disable google SystemUpdateService
kpick 220398 # extract_utils: Skip unneeded md5sum
kpick 220399 # extract_utils: Extract files from brotli compressed images
#kpick 222564 # extract-utils: initial support for brotli packaged images.
kpick 222612 # build: Update vdexExtractor


#-----------------------
# translations

######## topic ##########

##################################
echo
if [ ! -f $topdir/.pick_remote_only ]; then
    echo "---------------------------------------------------------------"
    [ "$op_auto" != "1" ] && read -n1 -r -p "  Picking remote changes finished, Press any key to continue..." key

    [ $op_pick_remote_only -eq 0 ] && patch_local local
else
   rm -f $topdir/.pick_remote_only
fi
[ -f $script_file.tmp ] && mv $script_file.tmp $script_file.new
[ -f $topdir/.myfiles/patches/rr-cache/rr-cache.tmp ] && \
   mv $topdir/.myfiles/patches/rr-cache/rr-cache.tmp $topdir/.myfiles/patches/rr-cache/rr-cache.list
rrCache backup # backup rr-cache
rm -f $tmp_picks_info_file
rm -f $topdir/.pick_tmp_* $topdir/.change_number_list_*
