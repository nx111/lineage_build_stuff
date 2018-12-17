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
    grep "^android$" $1
    while read $f; do
        [ "$f" == "android" ] && continue
        echo $f
    done < $1
}

function patch_local()
{
    cd $(gettop)
    topdir=$(gettop)
    va_patches_dir=$1
    search_dir=".myfiles/patches"

    if [ ! -z $va_patches_dir -a -d "$topdir/.myfiles/patches/$va_patches_dir" ]; then
        search_dir=".myfiles/patches/$va_patches_dir"
    elif [ ! -z $va_patches_dir -a -d "$topdir/.myfiles/patches/pick/$va_patches_dir" -o -d "$topdir/.myfiles/patches/local/$va_patches_dir" ]; then
        search_dir=".myfiles/patches/local/$va_patches_dir .myfiles/patches/pick/$va_patches_dir"
    elif  [ ! -z $va_patches_dir ]; then
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
                       echo "    patching: $f ..."
                       git am -3 -q   --keep-cr --committer-date-is-author-date < $topdir/.myfiles/patches/$f
                       rc=$?
                       if [ $rc -ne 0 ]; then
                             first=0
                             echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it ..."
                             while ! git log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                 [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it ..."
                                 first=1
                                 ch=$(sed q </dev/tty)
                                 if [ "$ch" = "s" ]; then
                                    echo "skip it ..."
                                    git am --skip
                                    break
                                  fi
                             done
                       fi
                       if [ "$project" = "android" ]; then
                            git -C $topdir/.repo/manifests am -3 -q --keep-cr --committer-date-is-author-date < $topdir/.myfiles/patches/$f
                            rc=$?
                            if [ $rc -ne 0 ]; then
                                 first=0
                                 echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it ..."
                                 while ! git -C $topdir/.repo/manifests log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                     [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it ..."
                                     first=1
                                     ch=$(sed q </dev/tty)
                                     if [ "$ch" = "s" ]; then
                                        echo "skip it ..."
                                        git -C $topdir/.repo/manifests am --skip
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
                     eval "sed -e \"s|^$project.*|$project,$commit_id, $url|" -i $snapshot_file.new"
              else
                     eval "sed -e \"s|^$project.*|$project,$commit_id, $url|" -i $snapshot_file"
              fi
         fi


         [ -d $topdir/.myfiles/patches/pick/$project ] || mkdir -p $topdir/.myfiles/patches/pick/$project
         rm -rf $topdir/.myfiles/patches/pick/$project/*.patch
         rm -rf $topdir/.myfiles/patches/pick/$project/*.diff

         git format-patch "$commit_id" -o $topdir/.myfiles/patches/pick/$project/ | sed -e "s:.*/:              :"

         patches_count=$(find $topdir/.myfiles/patches/pick/$project -maxdepth 1 -name "*.patch" -o -name "*.diff" | wc -l)
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
                           if echo $patch_file_name | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]" ; then
                               [ "${patch_file_name:5:5}" = "[WIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:5}-${pick_patch_name:5}
                               [ "${patch_file_name:5:6}" = "[SKIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:6}-${pick_patch_name:5}
                               [ "${patch_file_name:5:8}" = "[ALWAYS]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:8}-${pick_patch_name:5}
                           elif echo $(dirname $patchfile) | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]" ; then
                               rm -f $patchfile
                               mv $pick_patch $(dirname $patchfile)/
                           else
                               rm -f $patchfile
                               mv $pick_patch $topdir/.myfiles/patches/local/$project/
                           fi
                       elif ! echo $patchfile | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]"; then
                           rm -f $patchfile
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
                                 echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it ..."
                                 while ! git log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                     [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it ..."
                                     first=1
                                     ch=$(sed q </dev/tty)
                                     if [ "$ch" = "s" ]; then
                                        echo "skip it ..."
                                        git am --skip
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
                                 echo  "  >> git am conflict, please resolv it, then press ENTER to continue,or press 's' skip it ..."
                                 while ! git -C $topdir/.repo/manifests log -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; do
                                     [ $first -ne 0 ] && echo "conflicts not resolved,please fix it,then press ENTER to continue,or press 's' skip it ..."
                                     first=1
                                     ch=$(sed q </dev/tty)
                                     if [ "$ch" = "s" ]; then
                                        echo "skip it ..."
                                        git -C $topdir/.repo/manifests am --skip
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
        eval sed -n "'$bLineNo,\$p'" $logfile > $logfile.fix
        eval sed -n "'1,$(expr $bLineNo - 1)p'" $logfile >> $logfile.fix
        mv $logfile.fix $logfile
    fi
}

function get_active_rrcache()
{
    [ $# -lt 2 ] && return -1
    local project=$1
    [ -d $topdir/$project ] || return -1

    local md5file=$2
    local rr_cache_list="rr-cache.tmp"
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

    logfile=$topdir/.pick_tmp.log
    errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")
    change_number_list=$topdir/.change_number_list
    target_script=""

    rm -f $logfile $errfile $change_number_list

    for op in $*; do
        if [ -z "$changeNumber" ] && [[ $op =~ ^[0-9]+$ || $op =~ ^[0-9]+\/[0-9]+$ ]] && [ $(echo $op | cut -d/ -f1) -gt 1000 ]; then
             changeNumber=$op
        elif [[ "$op" =~ ^[[:digit:]]+\-[[:digit:]]+$ ]]; then
             query="$query $op"
             iRange=$op
        elif  [ "$op" = "-t" -o "$op" = "--topic" ]; then
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
             eval sed -e \"s/\\\([[:space:]]*kpick.*$iQuery\\\)/#\\1/\" -i $target_script
        elif [ "$iTopic" != "" ]; then
             mLine=$(grep -n "^[[:space:]]*kpick.*$iTopic" $target_script | cut -d: -f1 )
             eval sed -e \"s/\\\([[:space:]]*kpick.*$iTopic\\\)/#\\1/\" -i $target_script
        elif [ "$iRange" != "" ]; then
             mLine=$(grep -n "^[[:space:]]*kpick.*$iRange" $target_script | cut -d: -f1 )
             eval sed -e \"s/\\\([[:space:]]*kpick.*$iRange\\\)/#\\1/\" -i $target_script
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
           sed "${mLine}akpick $number" -i  $target_script || exit -1
           mLine=$(grep -n "^[[:space:]]*kpick $number" $target_script | cut -d: -f1 )
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
    logfile=$topdir/.pick_tmp.log
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
    LANG=en_US repopick --test $changeNumber > $logfile 2>$errfile
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
    subject=$(echo $subject | sed "s/\`/\\\\\`/g" | sed -e "s/|/\\\|/g")
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
                     recent_changeid_tmp=/tmp/$(echo $project | sed -e "s:/:_:g")_recent_ids.txt
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


          if grep -q -E "error EOF occurred|httplib\.BadStatusLine|urllib2\.URLError|Connection refused" $errfile; then
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
              md5file=/tmp/$(echo $project | sed -e "s:/:_:g")_rrmd5.txt
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
                    cd $topdir
                    break
              fi
              if [ "$pick_mode" = "fetch" ]; then
                    cd $topdir/$project
                    rchid=$(git log FETCH_HEAD -n 1 | grep Change-Id | cut -d: -f2 | sed -e "s/ //g")
                    recent_changeid_tmp=/tmp/$(echo $project | sed -e "s:/:_:g")_recent_ids.txt
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
        [ "$project" = "" ] && project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
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
 
        if [ ! -z $changeNumber ]; then
            if grep -q -E "Change status is MERGED.|nothing to commit|git command resulted with an empty commit" $logfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
                  eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $target_script
            elif grep -q -E "Change status is ABANDONED." $logfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
               eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $target_script
            elif grep -q -E "Change $changeNumber not found, skipping" $logfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
               eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $target_script
            elif [ -f $errfile ] && grep -q "could not determine the project path for" $errfile; then
               [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
               if [ -f $script_file.tmp ]; then
                    target_script=$script_file.tmp
               elif [ -f $script_file.new ]; then
                    target_script=$script_file.new
               fi
               [ ! -z $target_script -a -f $target_script ] && \
               eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $target_script
            fi
         fi
    fi
    if [ "$changeNumber" != "" -a "$subject" != "" ]; then
           [ ! -f $script_file.tmp -a "${BASH_SOURCE[0]}" = "$runfrom" ] && cp $script_file $script_file.tmp
           if [ -f $script_file.tmp ]; then
                target_script=$script_file.tmp
           elif [ -f $script_file.new ]; then
                target_script=$script_file.new
           fi
           [ ! -z $target_script -a -f $target_script ] && \
           eval  "sed -e \"s|^[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*|kpick $nops \# $subject|g\" -i $target_script"
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

if [ $0 != "bash" -a ! -f $0.tmp -a $op_pick_continue -eq 0 ]; then    # continue pick or not
[ $op_keep_manifests -ne 1 ] && reset_project_dir .repo/manifests
reset_project_dir vendor/lineage
repo sync vendor/lineage >/dev/null
apply_force_changes
reset_overwrite_projects

# android

repo sync android  >/dev/null
[ $op_keep_manifests -ne 1 ] && reset_project_dir .repo/manifests

kpick 223886 # manifest: Re-add hardware/qcom/data/ipacfg-mgr
kpick 227747 # lineage: Enable weather apps
#kpick 227748 # lineage: Enable qcom thermal/vr HALs
kpick 226755 # lineage: Enable cryptfs_hw
kpick 231971 # manifest: sync gcc4.9 from aosp oreo
kpick 232785 # lineage: Ship Snap

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

# ================= DEVICE STUFF =========================

# first pick for repopick
kpick 234859 # repopick: cmp() is not available in Python 3, define it manually

# device/samsung/klte-common
kpick 231209 # klte-common: nfc: pn547: Use prebuilt NFC HAL from 15.1
kpick 225192 # klte-common: Align ril.h to samsung_msm8974-common P libril changes
kpick 224917 # DO NOT MERGE: klte-common: Requisite bring-up BS change

# device/samsung/msm8974-common
kpick 235140 # msm8974-common: sepolicy: Clean up
kpick 235457 # msm8974-common: sepolicy: Limit execmod to specifically labeled files
kpick 234526 # msm8974-common: sepolicy: Resolve mediaserver denials

# kernel/samsung/msm8974
kpick 234754 # Add define for O_TMPFILE

# =============== END DEVICE STUFF ========================

# art
#kpick 233821

# bionic
#kpick 223067 -f # libc fortify: Ignore open() O_TMPFILE mode bits warning

# boot/recovery
kpick 231718 # recovery: Declare a soong namespace
kpick 234952 # uncrypt: write permission for f2fs_pin_file

# build/make
kpick 222742 # build: Use project pathmap for recovery
kpick 222760 # Add LOCAL_AIDL_FLAGS
kpick 227111 # releasetools: Store the build.prop file in the OTA zip

# build/soong
kpick 222648 # Allow providing flex and bison binaries
kpick 224613 # soong: Add LOCAL_AIDL_FLAGS handling
kpick 226443 # soong: Add additional_deps attribute for libraries and binaries

# dalvik

# device/lineage/sepolicy
kpick 229423 # selinux: add domain for snap
kpick 229424 # selinux: add domain for Gallery
kpick 234613 # common: Expand labeling of sysfs_vibrator nodes using genfscon

# device/qcom/sepolicy
kpick 228570 # sepolicy: Allow wcnss_service to set wlan.driver properties
kpick 228572 # sepolicy: Allow system_server to 'read' qti_debugfs
kpick 228573 # sepolicy: Add libsdm-disp-vndapis and libsdmutils to SP-HALs
kpick 228576 # sepolicy: Label mpctl_socket as data_file_type
kpick 228578 # sepolicy: rules to allow camera daemon access to app buffer
kpick 228580 # hal_gnss_default: Do not log udp socket failures
kpick 228582 # sepolicy: qti_init_shell needs to read dir too
kpick 228583 # sepolicy: allow vold to read persist dirs
kpick 234544 # sepol: Allow Settings to read ro.vendor.build.security_patch
kpick 236446 # common: Improve label of I/O sched tuning nodes

# device/qcom/sepolicy-legacy
kpick 230237 # common: allow vendor_init to create /data/dpm
kpick 230229 # mm-qcamera-daemon: fix denial
kpick 230230 # common: fix sensors denial
kpick 230231 # common: grant cnss-daemon access to sysfs_net
kpick 230232 # common: grant netmgrd access to sysfs_net nodes
kpick 230233 # common: allow sensors HIDL HAL to access /dev/sensors
kpick 230234 # common: allow wifi HIDL HAL to read tombstones
kpick 230235 # common: grant DRM HIDL HAL ownership access to /data/{misc,vendor}/media/
kpick 230236 # common: label /sys/devices/virtual/graphics as sysfs_graphics
kpick 230238 # common: create proc_kernel_sched domain to restrict perf hal access
kpick 230239 # common: allow uevent to control sysfs_mmc_host via vold
kpick 234832 # sepolicy: Add additional restricted permissions to vendor_init
kpick 235455 # legacy: Allow platform_app to read qemu_hw_mainkeys_prop

# development
kpick 232511 # make-key: Enforce PBEv1 password-protected signing keys

# external/ant-wireless/ant_native
kpick 227260 # Update bt vendor callbacks array in vfs code
kpick 227261 # Cast BT_VND_OP_ANT_USERIAL_{OPEN,CLOSE} to bt_vendor_opcode_t in vfs code

# external/perfetto
kpick  -f 223413 # perfetto_cmd: Resolve missing O_CREAT mode

# external/tinycompress

# external/zlib

# frameworks/av
kpick 230387 # CameraService: Support calling addStates in enumerateProviders
kpick 230642 # CameraService: Initialize CameraParameters for the cameras and cache them onFirstRef
kpick 231348 # camera: Allow to use boottime as timestamp reference
kpick 234010 # libstagefright: omx: Add support for loading prebuilt ddp decoder lib
kpick 234980 # libcameraservice: force specific cam id for google face unlock

# frameworks/base
kpick 224266 # SystemUI: Add Lineage statusbar item holder
kpick 224267 # SystemUI: Network Traffic [1/3]
kpick 224513 # SystemUI: Disable config_keyguardUserSwitcher on sw600dp
kpick 226343 # CameraServiceProxy: Loosen UID check
kpick 226358 # settings: Allow accessing LineageSettings via settings command
kpick 226398 # frameworks: base: Port password retention feature
kpick 226399 # Use fdeCheckPassword error code to indicate pw failure
kpick 227124 # BatteryService: Add support for oem fast charger detection
kpick 227290 # PowerProfile: allow overriding default power profile
kpick 227291 # [DNM] Revert "Handle public volumes and otherwise invalid UUIDs."
kpick 227896 # SystemUI: Add Profiles tile
kpick 221716 # Where's my circle battery, dude?
kpick 229166 # NightDisplayController: report unavailable if livedisplay feature is present
kpick 229307 # Add CHANNEL_MODE_DUAL_CHANNEL constant
kpick 229308 # Add Dual Channel into Bluetooth Audio Channel Mode developer options menu
kpick 229309 # Allow SBC as HD audio codec in Bluetooth device configuration
kpick 229606 # ConsumerIR: Support Huawei's DSP chip implementation
kpick 229612 # Performance: Memory Optimizations.
kpick 231823 # Do not move the multi-window divider when showing IME
kpick 231824 # Fix StatusBar icons tinting when in split screen
kpick 231827 # Add display shrink mode
kpick 231847 # onehand: Enable debug only on eng builds
kpick 231848 # SystemUI: Add one hand mode triggers
kpick 231851 # onehand: Take into account cutouts
kpick 231852 # onehand: Remove guide link
kpick 232197 # appops: Privacy Guard for P (1/2)
kpick 232796 # NetworkManagement : Add ability to restrict app vpn usage
kpick 233633 # Phone ringtone setting for Multi SIM device
kpick 233717 # [DNM][HACK] Persist user brightness model
kpick 234325 # TunerServiceImpl: Blacklist Lineage settings from tuner reset
kpick 234649 # keyguard: Check for a null errString
kpick 234715 # Rotation related corrections
kpick 235128 # Crash app on foreground service notification error
kpick 235147 # SystemUI: Name Cellular Tile based on carrier
kpick 235986 # frameworks: Add unlinked ringtone and notification volumes
kpick 236156 # CaffeineTile: Mimic old custom tile behavior
kpick 236213 # Revert "SystemUI: Fix several issues in the ADB over Network tile"
kpick 236215 # Revert "SystemUI: add navbar layout inversion tuning"
#kpick 236216 # StatusBarSignalPolicy: Hide signal icons for disabled SIMs
kpick 236476 # DreamBackend: Fix launching settings

# frameworks/native
kpick 224443 # libbinder: Don't log call trace when waiting for vendor service on non-eng builds
kpick 224530 # Triple the available egl function pointers available to a process for certain Nvidia devices.
kpick 225542 # sensorservice: Register orientation sensor if HAL doesn't provide it
kpick 225543 # sensorservice: customize sensor fusion mag filter via prop
kpick 225544 # input: Adjust priority
kpick 225546 # AppOpsManager: Update with the new ops
kpick 229400 # HAXX to allow too large dimensions
kpick 229607 # HACK: SF: Force client composition for all layers
kpick 230610 # APP may display abnormally in landscape LCM
kpick 231828 # Translate pointer motion events for OneHandOperation Display Shrink
kpick 231980 # HWComposer: HWC2: allow SkipValidate to be force disabled

# frameworks/opt/net/wifi

# frameworks/opt/telephony
kpick 227125 # RIL: Allow overriding RadioResponse and RadioIndication
kpick 229601 # Implement signal strength hacks used on Huawei devices
kpick 229602 # telephony: Squashed support of dynamic signal strength thresholds
kpick 229603 # telephony: Query LTE thresholds from CarrierConfig
kpick 229604 # Telephony: Use a common prop for Huawei RIL hacks (1/2)
kpick 229605 # Telephony: Don't call onUssdRelease for Huawei RIL
kpick 234319 # LocaleTracker: Add null check before accessing WifiManager

# hardware/boardcom/libbt
kpick 225155 # Broadcom BT: Add support fm/bt via v4l2.
#kpick  -f 224264 # debuggerd: Resolve tombstoned missing O_CREAT mode

# hardware/boardcom/nfc

# hardware/boardcom/wlan

# hardware/interfaces
kpick 225506 # Camed HAL extension: Added support in HIDL for Extended FD.
kpick 225507 # camera: Only link and use vendor.qti.hardware.camera.device if specified

# hardware/lineage/interfaces
kpick 223374 # interfaces: Add 2.0 livedisplay interfaces
kpick 223410 # interfaces: Add touch HIDL interface definitions

# hardware/lineage/lineagehw

# hardware/nxp/nfc
#kpick 223193 # nxp: Rename HAL to @1.1-service-nxp
#kpick 223194 # nxp: Begin restoring pn547

# hardware/qcom/audio

# hardware/qcom/audio-caf/msm8974

# hardware/qcom/bootctl

# hardware/qcom/bt-caf

# hardware/qcom/display
kpick 223341 # display: Always assume kernel source is present

# hardware/qcom/display-caf/msm8974

# hardware/qcom/fm
kpick 236546 # fm_helium: Update FM_HCI_DIR path

# hardware/qcom/gps

# hardware/qcom/keymaster
kpick 224948 # Keymaster: Support for 64bit userspace and 32bit TZ
kpick 224949 # keymaster: Set HEAP_MASK_COMPATIBILITY by platform for QCOM_HARDWARE
kpick 224950 # Keymaster: Check if keymaster TZ app is loaded
kpick 224951 # keymaster: Featureize support for waiting on QSEE to start
kpick 224952 # keymaster: add TARGET_PROVIDES_KEYMASTER
kpick 224953 # keymaster: Fix compiler warnings
kpick 224954 # keymaster: move to /vendor
kpick 233465 # keymaster: Use generated kernel headers

# hardware/qcom/media

# hardware/qcom/media-caf/msm8974

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
kpick 231894 # VNDK: Added required headers for 8998 target
kpick 231895 # VNDK: Added required libs
kpick 231896 # power: Turn on/off display in SDM439
kpick 231897 # power: qcom: powerHal for sdm439 and sdm429
kpick 231898 # Power: Naming convention change

# hardware/qcom/thermal

# hardware/qcom/vr

# hardware/qcom/wlan-caf
kpick 234861 # Reading the serialno property is forbidden

# hardware/ril

# hardware/ril-caf
kpick 227614 # Disable IOemHook implemenation in rild.

# hardware/samsung
#kpick 228524 # power: Convert power HAL to native binderized HAL
kpick 231194 # power: properly initialize cluster states
kpick 231960 # bauth: Add enumerate function

# lineage-sdk
kpick 227931 # lineagesdk: Refactor battery icon options
kpick 230272 # sdk: Remove VOLUME_KEYS_CONTROL_RING_STREAM
kpick 230284 # Revert "[3/3] cmsdk: add burnIn protection setting"

# packages/apps/Bluetooth
kpick 229310 # SBC Dual Channel (SBC HD Audio) support
kpick 229311 # Assume optional codecs are supported if were supported previously

# packages/apps/Calender

# packages/apps/Camera2
kpick 224752 # Use mCameraAgentNg for getting camera info when available
kpick 225265 # Add Storage preference (1/2)

# packages/apps/Carrierconfig

# packages/apps/CellBroadcastReciver
kpick 229303 # Only enable presidential CMAS alerts if user is a monkey

# packages/apps/Contacts

# packages/apps/DeskClock

# packages/apps/Dialer

# packages/apps/DocumentsUI

# packages/apps/Eleven

# packages/apps/Email

# packages/apps/Gallery2

# packages/apps/Jelly
kpick 231418 # Automatic translation import

# packages/apps/KeyChain

# packages/apps/LineageParts
kpick 227930 # LineageParts: Bring back and refactor battery icon options
kpick 221756 # StatusBarSettings: Hide battery preference category based on icon visibility
kpick 229389 # Trust: enforce vendor security patch level check
kpick 231163 # LineageParts: Add some missing psychedelics
kpick 232146 # LineageParts: Reenable Privacy Guard
kpick 236291 # LineageParts: Correctly initialize trust warning prefs.

# packages/apps/ManagedProvisoning

# packages/apps/Message

# packages/apps/Nfc

# packages/apps/PackagesInstaller

# packages/apps/PhoneCommon

# packages/apps/Settings
kpick 226151 # Settings: show Trust brading in confirm_lock_password UI
kpick 226148 # Settings: "Security & location" -> "Security & privacy"
kpick 226154 # fingerprint: Allow devices to configure sensor location
kpick 227120 # Settings: Check interfaces before enabling ADB over network
kpick 226142 # Settings: Add developer setting for root access
kpick 232198 # Settings: appops: Privacy Guard for P (2/2)
kpick 231590 # SimSettings: Add manual SIM provisioning support
kpick 229167 # Settings: Hide Night Mode suggestion if LiveDisplay feature is present
kpick 229312 # Add Dual Channel into Bluetooth Audio Channel Mode developer options menu
kpick 229453 # Settings: use LineageHW serial number
kpick 231518 # Settings: Check if we have any color modes declared in overlay
kpick 231826 # Update the white list of Data saver
kpick 232442 # Settings: Root appops access in developer settings
kpick 232793 # Settings: per-app VPN data restriction
kpick 233634 # Phone ringtone setting for Multi SIM device
kpick 235978 # Settings: Add switch for linked ring and media notification volumes
kpick 236184 # Settings: Use correct icon for ring volume
kpick 236550 # fingerprint: Remove unnecessary spacing in enroll layout

# packages/apps/SettingsIntelligence

# packages/apps/Snap
kpick 233131 # Revert "SnapdragonCamera: Forbid volume key can take picture"
kpick 233132 # Revert "SnapdragonCamera: Reduce number of countdown timer option"
kpick 233133 # Revert "SnapdragonCamera: Add missing permissions"
kpick 233136 # Rename SnapdragonCamera to Snap
kpick 233137 # tests: fix class name
kpick 233140 # Snap: Use AOSP app label
kpick 233141 # Snap: Remove old icons
kpick 233143 # SnapdragonCamera: Initialize overlay before control-by-intent
kpick 234570 # Snap: Re-enable ZSL after exiting HDR mode
kpick 233145 # SnapdragonCamera: Hide UI after error-checking video preferences
kpick 233146 # camera: Add parameter debugging support
kpick 233148 # camera: Remove the luma-adaptation seekbar
kpick 234571 # Camera: Cleanup and compatibility fixes
kpick 233149 # camera: Add all focus modes, scene modes, and color effects.
kpick 233150 # Camera: Add red-eye flash mode support
kpick 233152 # camera: Check if video sizes are available
kpick 233153 # Camera2: enable antibanding by default
kpick 233154 # camera: Remove ICS hack to stop preview after takePicture
kpick 233156 # Camera: fix preview for landscape devices
kpick 233160 # Camera2: Don't report incorrect supported picture formats
kpick 233161 # Camera2: some aapt warnings cleanup
kpick 233162 # Camera2: Remove CAF video duration code
kpick 233163 # Camera2: implement exposure compensation settings in video mode
kpick 234667 # Camera: separate settings for color effects
kpick 234668 # Camera: Change volume hard key button to zoom function
kpick 233167 # Camera: Powerkey shutter (2/2)
kpick 233169 # Camera: Cleanup hardware key handling
kpick 233170 # Camera: Handle keys only while in app
kpick 233171 # Camera2: Headset shutter mode
kpick 233172 # Camera2: Add option to set max screen brightness
kpick 233173 # SnapdragonCamera: Reset camera state after taking picture
kpick 234536 # Snap: Add support for additional ISO values
kpick 233177 # add support for non-standard iso keys and values
kpick 234572 # Snap: Add support for luminance-condition parameter
kpick 233179 # option to set manufacturer specific parameters on startup
kpick 234573 # Snap: Add options to restart preview onPictureTaken
kpick 233181 # Snap: Make openLegacy an option
kpick 233182 # Snap: Add touch-to-focus timeout duration settings
kpick 234669 # Snap: Add support for shutter speed
kpick 234575 # Snap: Add support for mw_continuous-picture focus mode
kpick 233191 # Snap: Fall back to default quality for invalid video qualities
kpick 233186 # SnapdragonCamera: Fix incorrect viewfinder ratio for 13.1MP shots
kpick 233188 # CameraActivity: Handle NPE when film strip view is null
kpick 233189 # Snap: Remove CAF Chinese translations
kpick 233190 # Snap: Fix aapt warnings
kpick 233192 # Snap: Fix NPE when parameters.getSupportedVideoSizes() is null
kpick 234574 # Snap: Add special handling of hdr-mode parameter for LGE devices
kpick 233195 # Snap: Support for HTC's HDR mode
kpick 234670 # Snap: Remove touch AF/AEC option
kpick 233197 # Snap: Actually select the highest quality video by default
kpick 233198 # SnapdragonCamera: Add option to control antibanding in camcorder
kpick 233199 # SnapdragonCamera: Fix overly-aggressive auto rotation
kpick 233200 # SnapdragonCamera: Remove 'off' option for antibanding
kpick 233202 # SnapdragonCamera: Fix UI alignment glitches when nav-bar is enabled
kpick 233204 # Snap: Don't crash when hardcoded gallery intent fails
kpick 233205 # SnapdragonCamera: Set camera parameters before restarting preview
kpick 233206 # Fix crash if Exif-Tag buffer-length and component-count are both 0
kpick 233208 # Snap: Don't crash if user saved preference is not valid
kpick 233209 # SnapdragonCamera: Scale up bitrate for HSR recordings
kpick 233210 # Snap: Fix filtering of unsupported HFR/HSR modes
kpick 233211 # Snap: Remove auto HDR option when not supported
kpick 233212 # Snap: Remove video snapshot size when not supported
kpick 233213 # Snap: Remove face detection option if not supported
kpick 233215 # Snap: Fix incorrect preview layout surface size in landscape mode
kpick 233216 # Snap: Do not crash when cur-focus-scale is null
kpick 233217 # Snap: Fall back to REVIEW intent before VIEW intent
kpick 233218 # Fix view index tracking.
kpick 233219 # Snap: Support override maker and model exif tag
kpick 233221 # Snap: Extend user menu, disable dev menu
kpick 233222 # Snap: Make developer menu more accessible
kpick 233223 # Snap: Always allow 100% JPEG quality to be set
kpick 233224 # Snap: Unbreak auto-HDR
kpick 233226 # snap: Add constrained longshot mode
kpick 233227 # Snap: Remove storage menu if no external storage available
kpick 233229 # CameraNext: dynamically generate available photo resolutions
kpick 233230 # Snap: add auto-hdr option to photo menu
kpick 233231 # Allow to re-open Snap from recent menu
kpick 233232 # Add orientation correction for landscape devices
kpick 234671 # camera: Touch focus support for camcorder
kpick 233237 # SnapdragonCamera: Add focus-mode option to camcorder
kpick 233238 # SnapdragonCamera: Always lock AE and AWB when auto-focus is used
kpick 233239 # SnapdragonCamera: Lock AE and AWB for tap-to-focus in camcorder
kpick 233240 # SnapdragonCamera: Unlock AE/AWB after taking a photo with ZSL
kpick 233241 # Snap: Expose video snapshot size setting
kpick 233242 # Snap: Add focus time support in camcorder
kpick 234672 # Snap: Add ability to set the tap-to-focus duration to 0 sec
kpick 233245 # Snap: Separate default focus time between camera/video
kpick 233247 # Camera2: Only autofocus before a snap if we are actually in "auto" mode.
kpick 233248 # camera: Keep touch focus intact during back-to-back ZSL shots
kpick 233249 # Snap: Fixes for advanced features and scene modes
kpick 233251 # Snap: grant android.permission.RECEIVE_BOOT_COMPLETED permisions
kpick 234673 # Snap: Materialize
kpick 233253 # Snap: Material toasts
kpick 233255 # Remove unused menu indicators code.
kpick 233257 # Snap: Add icons to all remaining preferences
kpick 233258 # Snap: Add icons to all scene modes
kpick 233259 # snap: Adjust top bar icon order
kpick 233260 # De-uglify menu.
kpick 233261 # Use material versions of share/delete/edit icons.
kpick 233263 # CameraNext: Fallback to do copy exif if exif not exist
kpick 233264 # CameraNext: don't crash when pref is not boolean
kpick 233265 # Show UI when pano stitch starts and remove cancel condition
kpick 233266 # snap: Panorama fixes
kpick 233267 # Fix broken filenames for cropped images
kpick 233268 # CropActivity: notify MediaScanner on save complete
kpick 233269 # CameraNext: stop updating the pano progress bar on pause
kpick 233270 # Grant read URI permission for playback of video capture
kpick 233271 # Make panorama able to go 270 degrees in landscape
kpick 233272 # CameraNext: Update focus behavior for panoramas
kpick 233273 # Stop data loader on activity destroy.
kpick 233274 # Initialize focus manager in onResume().
kpick 233275 # Snap: prevent NPE when checking if controls are visible
kpick 234674 # Snap: Detect and use Camera2 if available
kpick 233277 # Snap: CaptureModule: check if ZSL is supported before using it
kpick 233278 # Snap: Allow switching beyond just 2 cameras
kpick 233279 # Always apply frame size reduction to panorama pictures
kpick 233280 # Snap: Simulate back button press when menu back button is pressed
kpick 233283 # Never ignore finger swipes in gallery mode
kpick 233284 # Initialize focus overlay manager if it is not initialized.
kpick 233285 # Camera: Set preview fps after recording.
kpick 233287 # Snapdragon Camera: Use consistent API for preview fps reset
kpick 233288 # SnapdragonCamera: Longshot with Burst Functionality.
kpick 233289 # Protect against multiple shutter callbacks per frame in longshot mode.
kpick 233290 # ListPreference: prevent ArrayIndexOutOfBoundsException
kpick 233291 # VideoModule: don't set negative HFR value
kpick 233292 # SnapdragonCamera: Fix shutter button clicks in rapid succession getting ignored
kpick 233293 # SnapdragonCamera: Enforce 120ms delay in between shutter clicks
kpick 233294 # Snap: Render zoom circle in the center of the camera preview
kpick 233295 # Snap: Don't do touch-to-focus on top of UI elements
kpick 233296 # SnapdragonCamera: Add missing toast on HSR/HFR override
kpick 233297 # Snap: Show remaining photos on initial start
kpick 233298 # Snap: Disable warped pano preview
kpick 233299 # Snap: Increase default pano capture pixels to 1440x1000
kpick 233300 # Snap: Adjust scene and filter mode layout dimensions
kpick 233301 # Snap: Don't close slide out menu after selecting scene mode
kpick 233302 # Snap: Fix swipe right to open menu
kpick 233303 # Snap: Fix filter mode button after disabling HDR mode
kpick 233304 # Snap: Remove "help screen on first start" feature
kpick 233305 # Snap: Arrange video menu so it's similar to photo menu
kpick 233306 # Snap: Fix panorama layout
kpick 233308 # Removed littlemock dependency and cleanup
kpick 233309 # Snap: Rip out hdr-need-1x option
kpick 233310 # Snap: check tags before using them
kpick 233311 # QuickReader: initial commit
kpick 234675 # Snap: add QReader to module switch
kpick 233315 # Snap: Add missing thumbnails for filter modes
kpick 233317 # Snap: Port all string improvements from cm-14.1
kpick 233319 # Snap: adaptive icon
kpick 233320 # Snap: Convert "save best" dialog text to a quantity string
kpick 233322 # Do not crash if we don't have support for RAW files
kpick 233323 # Snap: don't try to set up cameras with ids greater than MAX_NUM_CAM
kpick 233326 # Drop new focus indicator into Camera2.
kpick 233327 # Snap: Add support for focus distance
kpick 233328 # Snap: Configure focus ring preview dimensions
kpick 233329 # Snap: Check for ACCESS_FINE_LOCATION instead of ACCESS_COARSE_LOCATION
kpick 233331 # SnapdragonCamera: Panorama, replace border drawable
kpick 233332 # Snap: turn developer category title into a translatable string
kpick 233333 # Snap: Allow quickreader to work with secure device
kpick 233334 # CameraSettings: Do not crash if zoom ratios are not exposed
kpick 233335 # Snap: use platform cert
kpick 234175 # Fix force close when launch camera on P
kpick 234236 # SnapdragonCamera: SetParameters use the mParameters Object
kpick 234237 # SnapdragonCamera: Fix parameters NullPointerException
kpick 234238 # Fix to change default mode to Camera1 HAL1
kpick 234239 # Fix get aePref is null in PhotoMenu
kpick 234415 # Snap: Avoid crash with empty RAW output size
kpick 234416 # Snap: Create correct redeye reduction config icon
kpick 234417 # Snap: Fix layout of zoom option
kpick 234418 # Snap: Check various feature support before applying
kpick 234419 # Snap: Add missing NULL check in updateQcfaPictureSize()
kpick 234423 # Snap: Disable debugging of double open issue

# packages/apps/Stk

# packages/apps/StorageManager

# packages/apps/Traceur

# packages/apps/Trebuchet
kpick 234611 # Trebuchet: expand statusbar on swipe down

# packages/apps/TvSettings

# packages/apps/Updater
kpick 234612 # Updater: Implement auto update check interval preference

# packages/inputmethods/LatinIME

# packages/providers/ContactsProvider

# packages/providers/DownloadProvider

# packages/providers/MediaProvider

# packages/providers/TelephonyProvider

# packages/services/BuiltinPrintService

# packages/services/Telecomm
kpick 233635 # Phone ringtone setting for Multi SIM device

# packages/services/Telephony
kpick 229610 # Telephony: Support muting by RIL command
kpick 234321 # Don't start SIP service before decrypted
kpick 236522 # Fix carrier config option not hidden on a CDMA phone

# system/bt
kpick 229125 # Increase maximum Bluetooth SBC codec bitpool and bitrate values
kpick 229313 # Explicit SBC Dual Channel (SBC HD) support
kpick 229314 # Allow using alternative (higher) SBC HD bitrates with a property
kpick 229401 # [DNM] Revert "Return early if vendor-specific command fails"

# system/core
kpick -f 227110 # init: I hate safety net
kpick 223085 # adbd: Disable "adb root" by system property
kpick 234584 # adb: Rework adb root
kpick 231716 # init: Always use libbootloader_message from bootable/recovery namespace
kpick 234860 # init: add install_keyring for TWRP FBE decrypt

# system/extras

# system/extras/su
kpick 232428 # su: strlcpy is always a friend
kpick 232429 # su: Run clang format
kpick 232430 # su: Move to cutils/properties.h
kpick 232431 # su: Enable Clang Tidy
kpick 232432 # su: Remove Sammy hacks
kpick 232433 # su: Fix a clang tidy warning
kpick 232434 # su: Cleanup includes
kpick 232435 # su: Use shared libraries
kpick 232437 # su: Remove mount of emulated storage
kpick 232438 # su: Initialize windows size
kpick 232427 # su: Update AppOps API calls

# system/libvintf

# system/netd
kpick 232794 # NetD : Allow passing in interface names for vpn app restriction
kpick 234190 # netd: Allow devices to opt-out of the tethering active FTP helper

# system/qcom

# system/security

# system/sepolicy
kpick 230613 # Allow webview_zygote to read /dev/ion
kpick 234884 # Allow init to write to /proc/cpu/alignment
kpick 234886 # Allow init to chmod/chown /proc/slabinfo
kpick 234987 # Use LOCAL_ADDITIONAL_M4DEFS for file_contexts
kpick 235196 # Allow dnsmasq to getattr netd unix_stream_socket
kpick 235258 # Allow fsck_untrusted to getattr block_device

# system/tool/aidl
kpick 223133 # AIDL: Add option to generate No-Op methods

# system/update/engine
kpick 234581 # update_engine: Fallback to partition without suffix

# system/vold
kpick 226109 # vold: Add Hardware FDE feature
kpick 226110 # system: vold: Remove crypto block device creation
kpick 226127 # vold: Move QCOM HW FDE inclusion under lineage namespace
kpick 229304 # vold: Add texfat and sdfat support
kpick 231717 # vold: Always use libbootloader_message from bootable/recovery namespace
kpick 235198 # Revert "vold: Also wait for dm device when mounting private volume"
kpick 235199 # Revert "vold: Make sure block device exists before formatting it"
kpick 235200 # pie-gsi

# vendor/lineage
kpick 223773 # Add IPv6 for Oister and 3. The 3.dk and oister.dk carriers now support IPv6 with the APN ”data.tre.dk”.
kpick 225921 # overlay: Update list of GSF/GMS activities
kpick 225938 # roomservice.py: document the hell out of the current behavior of the script
kpick 225939 # roomservice.py: non-depsonly: bootstrap first device repo from Hudson
kpick 225981 # roomservice.py: depsonly: do not look up device repo by name in the manifest
kpick 225982 # roomservice.py: Strip cm.{mk,dependencies} support
kpick 231249 # roomservice.py: adapt to lineage-16.0
kpick 226123 # soong_config: Add new flags for HW FDE
kpick 226125 # soong_config: Add flag for legacy HW FDE
kpick 226126 # soong_config: Add flag to skip crypto waiting on QSEE to start
kpick 229589 # lineage: Automatically set soong namespace when setting project pathmap
kpick 229590 # lineage: Move qcom pathmap setting into "BoardConfig"
kpick 231291 # repopick: add hashtag support
kpick 231981 # HWComposer: HWC2: allow SkipValidate to be force disabled
kpick 232663 # overlay: Hide the option to show battery percentage
kpick 234011 # lineage: Add media_codecs_ddp for AC3 audio
# kpick 234859 # repopick: cmp() is not available in Python 3, define it manually **((picked at first))**

# vendor/qcom/opensource/cryptfs_hw
kpick 226128 # cryptfs_hw: Add compatibility for pre-O hw crypto
kpick 226129 # cryptfs_hw: Featureize support for waiting on QSEE to start
kpick 226130 # cryptfs_hw: add missing logging tag
kpick 226403 # cryptfs_hw: Remove unused variable

# vendor/qcom/opensource/thermal-engine

#-----------------------
# translations

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

