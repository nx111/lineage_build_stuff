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

   kpick 209019 # toybox: Use ISO C/clang compatible __typeof__ in minof/maxof macros

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

    kpick 231971 # manifest: sync gcc4.9 from aosp oreo

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
kpick 234859 # repopick: cmp() is not available in Python 3, define it manually

# start check classification of picking project is correct or not
rm -f $tmp_picks_info_file
start_check_classification=1

# *******************************************************
# **            MAIN PICKS                             **
# *******************************************************

# ==== DEVICE STUFF ======

# device/samsung/klte-common
kpick 225192 # klte-common: Align ril.h to samsung_msm8974-common P libril changes
kpick 238522 # klte-common: Add IGloveMode to device manifest
kpick 242366 # klte-common: Update power profile for Pie

# device/samsung/msm8974-common
kpick 235457 # msm8974-common: sepolicy: Limit execmod to specifically labeled files
kpick 238521 # msm8974-common: Build vendor.lineage.touch HAL from hardware/samsung
kpick 241858 # msm8974-common: Build Samsung LiveDisplay service

# kernel/samsung/msm8974
# kpick 240451 # fuse: fix possibly missed wake-up after abort

# ====== OTHERS =======

# art

# bionic
kpick 238738 # bionic: Prefer /sbin/sh if it exists

# bootable/recovery
kpick 238951 # Revert "recovery: Fork a process for fuse when sideloading from SD card."
kpick 239450 # recovery: Remove HOST_OS guard for f2fs tools
kpick 230746 # recovery: Get a proper shell environment in recovery
kpick 238952 # recovery: ui: Default to touch enabled
kpick 238953 # recovery: ui: Minor cleanup for touch code
kpick 238954 # recovery: ui: Support hardware virtual keys
kpick 238955 # recovery: Puke out an /etc/fstab so stuff like busybox/toybox is happy
kpick 238956 # recovery: Enable gunzip/gzip/unzip/zip commands
kpick 238957 # recovery: Add fstools
kpick 239451 # recovery: Add resize2fs, tune2fs to fstools
kpick 238958 # recovery: Include vendor init trigger
kpick 238959 # recovery: Allow device-specific recovery modules
kpick 238960 # recovery: Implement a volume manager
kpick 238961 # recovery: Blank screen during shutdown and reboot
kpick 238962 # recovery: Provide sideload cancellation
kpick 238963 # recovery: bu: Implement backup/restore
kpick 238964 # recovery: Provide caching for sideload files
kpick 238965 # recovery: Add wipe system partition option
kpick 238966 # recovery: Return to main menu after selection
kpick 238967 # recovery: Fix the progress bar
kpick 238968 # recovery: Dejank the menus, fix colors
kpick 238969 # recovery: updater: Fix multi-stage docs
kpick 238970 # recovery: Allow devices to reboot to download mode
kpick 238971 # minui: support to pan display (FBIOPAN_DISPLAY)
kpick 238973 # recovery: Remove "Supported API" message
kpick 238974 # recovery: Enable the menu for User builds
kpick 238975 # minui: accept RGBA and treat it as RGBX
kpick 238976 # recovery: init: mount pstore fs
kpick 238977 # recovery: Add performance control
kpick 238978 # minui: Skip EV_REL input devices.
kpick 238979 # recovery: Graphical UI
kpick 238980 # recovery: New install/progress animation
kpick 238981 # recovery: Respect margins in background and foreground screens
kpick 238982 # recovery: Add awk lib and driver
kpick 238983 # recovery: Fix redraws, flickering, and animation
kpick 238985 # recovery: Do not show emulated when data is encrypted
kpick 238986 # recovery: Add statusbar margin for panels with rounded corners
kpick 238987 # recovery: Allow device specific backlight path
kpick 238988 # recovery: Rework sideload threading code for flexibility
kpick 238989 # recovery: Allow detecting user/release build at compile time
kpick 238990 # recovery: Allow bypassing signature verification on non-release builds
kpick 238991 # recovery: minui: Implement image scaling
kpick 238992 # recovery: Scale logo image if necessary
kpick 238993 # recovery: Add runtime checks for A/B vs traditional updates

# build/make
kpick 222742 # build: Use project pathmap for recovery
kpick 222760 # Add LOCAL_AIDL_FLAGS
kpick 239296 # build: Remove charger from recovery unless needed
kpick 241427 # build: Allow build-image-kernel-modules to be called from shell

# build/soong
kpick 222648 # Allow providing flex and bison binaries
kpick 224613 # soong: Add LOCAL_AIDL_FLAGS handling
kpick 226443 # soong: Add additional_deps attribute for libraries and binaries
kpick 241473 # Fix formatting

# device/lineage/sepolicy
kpick 240542 # Revert "sepolicy: recovery: Allow (re)mounting system"
kpick 241664 # sepolicy: Dynamically build trust policy into system/vendor
kpick 241665 # sepolicy: Move livedisplay hal policy to dynamic
kpick 241666 # sepolicy: Move touch hal policy to dynamic
kpick 241667 # sepolicy: Move power hal service label to dynamic
kpick 241676 # sepolicy: qcom: Rename common to vendor to avoid confusion
kpick 241677 # sepolicy: Break livedisplay hal policy into impl independent ones
kpick 241903 # sepolicy: Label all the livedisplay service implementations
kpick 242792 # Allow Gallery to access system_app_data_file

# device/qcom/sepolicy
kpick 228573 # sepolicy: Add libsdm-disp-vndapis and libsdmutils to SP-HALs
kpick 228582 # sepolicy: qti_init_shell needs to read dir too
kpick 240951 # qcom: label persist files with /(mnt/vendor)/persist instead of /mnt/vendor/persist
kpick 241794 # sepolicy: Add core_data_file_type type to cnd_data_file
kpick 242976 # sepolicy: Label persist partition for all SoCs

# device/qcom/sepolicy-legacy
kpick 230230 # common: fix sensors denial
kpick 239741 # common: permit libqdutils operation (linked by mediaserver) during WFD
kpick 240028 # sepolicy: vendor_init: allow vendor_init to read firmware files

# development
kpick 240579 # idegen: Add functionality to set custom ipr file name

# external/ant-wireless/ant_native
kpick 227260 # Update bt vendor callbacks array in vfs code
kpick 227261 # Cast BT_VND_OP_ANT_USERIAL_{OPEN,CLOSE} to bt_vendor_opcode_t in vfs code

# external/bash

# external/e2fsprogs
kpick 225215 # e2fsprogs: Prepare for adding and using static libs
kpick 225216 # e2fsprogs: Build static libs for recovery
kpick 225217 # e2fsprogs: Build libresize2fs for recovery
kpick 239459 # e2fsprogs: Fix resize2fs_static build

# external/exfat
kpick 239376 # exfat: Add static libs for recovery
kpick 239377 # exfat: Rename utf conversion symbols

# external/f2fs-tools
kpick 225225 # f2fs-tools: Add static libs for recovery
kpick 225226 # f2fs-tools: Rename quota symbols
kpick 225227 # f2fs-tools: Rename utf conversion symbols
kpick 239378 # f2fs-tools: Add sload.f2fs support to libf2fs_fsck

# external/fsck_msdos
kpick 239460 # fsck_msdos: Build static lib for recovery

# external/gptfdisk
kpick 225228 # gptfdisk: Build static lib for recovery fstools
kpick 239254 # gptfdisk: Provide sgdisk_read for direct reads of the partition table

# external/libtar
kpick 238626 # libtar: Build fixes

# external/ntfs-3g
kpick 239379 # ntfs-3g: Add static libs for recovery

# external/one-true-awk
kpick 225231 # awk: Add libawk_main for recovery and fixup symbols

# external/openssh

# external/p7zip

# external/perfetto
kpick 223413 -f # perfetto_cmd: Resolve missing O_CREAT mode

# external/proguard

# external/rsync

# external/toybox
kpick 225232 # toybox: Use toybox for dd and grep in recovery
kpick 225233 # toybox: Add install to symlinks

# external/unrar

# external/zip

# external/zlib
kpick 225237 # minizip: Fix build under Android 6.0 and higher
kpick 225238 # minizip: Clean up the code
kpick 238630 # minizip: More build fixes

# frameworks/av
kpick 230387 # CameraService: Support calling addStates in enumerateProviders
kpick 230642 # CameraService: Initialize CameraParameters for the cameras and cache them onFirstRef
kpick 231348 # camera: Allow to use boottime as timestamp reference
kpick 234010 # libstagefright: omx: Add support for loading prebuilt ddp decoder lib
kpick 238927 # Revert "Removed unused class and its test"
kpick 238928 # Revert "stagefright: remove Miracast sender code"
kpick 238929 # libstagefright_wfd: libmediaplayer2: compilation fixes
kpick 238931 # stagefright: Fix SurfaceMediaSource getting handle from wrong position issue
kpick 238932 # stagefright: Fix buffer handle retrieval in signalBufferReturned
kpick 239642 # libstagefright_wfd: video encoder does not actually release MediaBufferBase when done
kpick 242705 # effects: Initialize volume at -96

# frameworks/base
kpick 224513 # SystemUI: Disable config_keyguardUserSwitcher on sw600dp
kpick 229307 # Add CHANNEL_MODE_DUAL_CHANNEL constant
kpick 229308 # Add Dual Channel into Bluetooth Audio Channel Mode developer options menu
kpick 229309 # Allow SBC as HD audio codec in Bluetooth device configuration
kpick 231823 # Do not move the multi-window divider when showing IME
kpick 231824 # Fix StatusBar icons tinting when in split screen
kpick 231827 # Add display shrink mode
kpick 231847 # onehand: Enable debug only on eng builds
kpick 231848 # SystemUI: Add one hand mode triggers
kpick 231851 # onehand: Take into account cutouts
kpick 231852 # onehand: Remove guide link
kpick 232796 # NetworkManagement : Add ability to restrict app vpn usage
kpick 233633 # Phone ringtone setting for Multi SIM device
kpick 233717 # [DNM][HACK] Persist user brightness model
kpick 234649 # keyguard: Check for a null errString
kpick 235986 # frameworks: Add unlinked ringtone and notification volumes
kpick 236765 # Sounds: Squashed cleanup of sound files
#kpick 227142 # Battery: add Battery Moto Mod Support
kpick 237142 # Battery: update mod support to P
kpick 237143 # AudioService: Fix Audio mod volume steps
kpick 239520 # Reset all package signatures on boot
kpick 240084 # ServiceRegistry: Don't throw an exception if OEM_LOCK is missing
#kpick 240411 # Keyguard: Avoid starting FP authentication right after cancelling
kpick 240766 # Proper supplementary service notification handling (1/5).
kpick 241326 # SettingsLib: add action callbacks to CustomDialogPreferences
kpick 241327 # VibratorService: Apply vibrator intensity setting.
kpick 242737 # Skip one-shot sensors for WindowOrientationListener

# frameworks/native
kpick 224530 # Triple the available egl function pointers available to a process for certain Nvidia devices.
kpick 231828 # Translate pointer motion events for OneHandOperation Display Shrink
kpick 231980 # HWComposer: HWC2: allow SkipValidate to be force disabled
kpick 237645 # sf: Add support for multiple displays

# frameworks/opt/telephony
kpick 240767 # Proper supplementary service notification handling (2/5).

# hardware/broadcom/libbt
kpick 225155 # Broadcom BT: Add support fm/bt via v4l2.

# hardware/interfaces

# hardware/lineage/interfaces

# hardware/lineage/livedisplay
kpick 242994 # livedisplay: sysfs: Simplify setCalibration

# hardware/nxp/nfc
kpick 239927 # hardware: nxp: Restore pn547 support

# hardware/qcom/bt-caf
kpick 240345 # qcom/bt: update bt_firmware path

# hardware/qcom/data/ipacfg-mgr
kpick 241715 # Add kernel header dep for ipanat

# hardware/qcom/display
kpick 223341 # display: Always assume kernel source is present

# hardware/qcom/display-caf/msm8974

# hardware/qcom/fm
kpick 236546 # fm_helium: Update FM_HCI_DIR path

# hardware/qcom/media-caf/msm8974
kpick 237154 # Add -Wno-error to compile with global -Werror.

# hardware/qcom/power
kpick 231884 # sdm670:power: Turn on/off display
kpick 231885 # Rename sdm670 to sdm710
kpick 231886 # power: Notify touch of display status
kpick 231887 # power: Fix VNDK Compilation Errors
kpick 231888 # power: Fix for VNDK compliance issue
kpick 231889 # Add touch boost override
kpick 231890 # power: Turn on/off display
kpick 231891 # sdm710 : fixed VNDK compilation for warlock
kpick 231892 # VNDK: Added required libs
kpick 231893 # Power: Fixing the header inclusion for VNDK.
kpick 231895 # VNDK: Added required libs
kpick 231896 # power: Turn on/off display in SDM439
kpick 231897 # power: qcom: powerHal for sdm439 and sdm429
kpick 231898 # Power: Naming convention change
kpick 241622 # power: don't use SCROLL_PREFILING
kpick 242164 # power: Pass NULL parameter in powerHint if data is zero
kpick 241818 # Revert "power: Remove interaction_with_handle"
kpick 241814 # power: Release launch boost perflock when launch is completed

# hardware/samsung
kpick 231194 # power: properly initialize cluster states
kpick 238519 # samsung: Add dummy lineagehw HIDL interfaces for vendor.lineage.touch
kpick 238520 # hidl: touch: Add binderized service implementation
kpick 239597 # samsung: Add dummy lineagehw HIDL interfaces for vendor.lineage.livedisplay
kpick 239598 # hidl: livedisplay: Add binderized service implementation

# lineage-sdk
kpick 230272 # sdk: Remove VOLUME_KEYS_CONTROL_RING_STREAM
kpick 241779 # sdk: Change night/day mode transition behavior
kpick 242398 # Trust: Onboarding: Listen for locale changes

# packages/apps/Bluetooth
kpick 229311 # Assume optional codecs are supported if were supported previously

# packages/apps/Calendar

# packages/apps/Camera2
kpick 224752 # Use mCameraAgentNg for getting camera info when available

# packages/apps/CellBroadcastReceiver
kpick 242969 # Fix resource warnings.
kpick 242970 # Fix a warning in generating id in android namespace.

# packages/apps/Contacts

# packages/apps/Dialer
kpick 240770 # Proper supplementary service notification handling (5/5).

# packages/apps/Eleven
kpick 242736 # Eleven: bump to api26

# packages/apps/Email
kpick 242677 # Email: Fix generating id in android namespace

# packages/apps/Messaging
kpick 242678 # Messaging: Fix generating id in android namespace

# packages/apps/PackageInstaller
kpick 242682 # PackageInstaller: Fix generating id in android namespace

# packages/apps/Settings
kpick 235978 # Settings: Add switch for linked ring and media notification volumes
kpick 236184 # Settings: Use correct icon for ring volume
kpick 233634 # Phone ringtone setting for Multi SIM device
kpick 227120 # Settings: Check interfaces before enabling ADB over network
kpick 229312 # Add Dual Channel into Bluetooth Audio Channel Mode developer options menu
kpick 231826 # Update the white list of Data saver
kpick 232793 # Settings: per-app VPN data restriction
kpick 237183 # settings: hide appendix of app list for power usage.
kpick 240083 # Settings: Add null checks for OemLockService
#kpick 241325 # Settings: add vibration intensity preference
kpick 241758 # Settings: Show root options when certain third party root is present

# packages/apps/SetupWizard
kpick 241766 # SUW: Update wizard scripts for Pie
kpick 241767 # SUW: Don't make google suw use material_light

# packages/apps/Snap
kpick 242496 # Snap: Fix bad grammar "Long shot not support<ed>"
kpick 242966 # Snap: Add back original-package in manifest

# packages/apps/Updater
kpick 239289 # Updater: put identical code to helper method

# packages/providers/CalendarProvider

# packages/services/Telecomm
kpick 233635 # Phone ringtone setting for Multi SIM device
kpick 240768 # Proper supplementary service notification handling (3/5)

# packages/services/Telephony
kpick 240769 # Proper supplementary service notification handling (4/5).
kpick 242884 # Revert "Use proper summary for network select list preference on dsds/dsda/tsts"
kpick 242885 # Fix an issue wrong network operator name is displayed on MSIM devices
kpick 242886 # Don't save network selection to prefs
kpick 242971 # Fix resource warnings.
kpick 242972 # Stop generating ids in android namespace.

# system/bt
kpick 239040 # Increase maximum Bluetooth SBC codec bitrate for SBC HD
kpick 229313 # Explicit SBC Dual Channel (SBC HD) support
kpick 229314 # Allow using alternative (higher) SBC HD bitrates with a property

# system/core
kpick 227110 -f # init: I hate safety net
kpick 231716 # init: Always use libbootloader_message from bootable/recovery namespace
kpick 234584 # adb: Rework adb root
kpick 234860 # init: add install_keyring for TWRP FBE decrypt
#kpick 237140 # healthd: add Battery Moto Mod Support
kpick 237141 # core: update battery mod support for P
kpick 240018 # Fix path for treble default prop
kpick 241757 # adb: Allow adb root when certain third party root is present

# system/extras
kpick 242968 # Remove -Wno-error from system/extras

# system/extras/su
kpick 232428 # su: strlcpy is always a friend
kpick 232431 # su: Enable Clang Tidy
kpick 232433 # su: Fix a clang tidy warning
kpick 232438 # su: Initialize windows size

# system/netd
kpick 232794 # NetD : Allow passing in interface names for vpn app restriction

# system/sepolicy
kpick 242951 # sepolicy: Allow init to chown sysfs LED files

# system/tools/aidl
kpick 223133 # AIDL: Add option to generate No-Op methods

# system/vold
kpick 231717 # vold: Always use libbootloader_message from bootable/recovery namespace

# vendor/lineage
kpick 225921 # overlay: Update list of GSF/GMS activities
kpick 225938 # roomservice: document the hell out of the current behavior of the script
kpick 225939 # roomservice: non-depsonly: bootstrap first device repo from Hudson
kpick 225981 # roomservice: depsonly: do not look up device repo by name in the manifest
kpick 225982 # roomservice: Strip cm.{mk,dependencies} support
kpick 231249 # roomservice: adapt to lineage-16.0 realities
kpick 229589 # lineage: Automatically set soong namespace when setting project pathmap
kpick 229590 # lineage: Move qcom pathmap setting into "BoardConfig"
kpick 231291 # repopick: add hashtag support
kpick 231981 # HWComposer: HWC2: allow SkipValidate to be force disabled
kpick 234011 # lineage: Add media_codecs_ddp for AC3 audio
# kpick 234859 # repopick: cmp() is not available in Python 3, define it manually **((picked at first))**
kpick 237118 # extract_utils: introduce support for executing blob fixups
kpick 239526 # extract_utils: add option to print dependency graph for elf files
kpick 239527 # extract_utils: template: add support for the dependency graph function
kpick 237209 # lineage: Set default ringtone for second SIM
kpick 241422 # kernel: Add more threads to kernel build process
kpick 241423 # kernel: Move kernel module dir cleanup/creation to module install target
kpick 241424 # kernel: Detect kernel module usage better
kpick 241425 # kernel: Use a macro for kernel build targets
kpick 241426 # kernel: Use build-image-kernel-modules instead of copying it
kpick 241466 # kernel: Move full kernel build guard flag below all targets
kpick 241783 # envsetup: Fix lineagegerrit push for zsh
kpick 242432 # RIP libhealthd.lineage
kpick 242433 # Make custom off-mode charging screen great again

# vendor/qcom/opensource/cryptfs_hw
kpick 243032 # cryptfs_hw: Cleanup should_use_keymaster
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
