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
default_remote="github"
script_file="pick.sh"
conflict_resolved=0
checkcount=200

[ "$0" != "bash" ] && script_file=$(realpath $0)
#echo "script_file:$script_file"

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

function patch_local()
{
    cd $(gettop)
    topdir=$(gettop)
    va_patches_dir=$1
    search_dir=".mypatches"

    if [ ! -z $va_patches_dir -a -d "$topdir/.mypatches/$va_patches_dir" ]; then
        search_dir=".mypatches/$va_patches_dir"
    elif [ -d "$topdir/.mypatches/pick/$va_patches_dir" -o -d "$topdir/.mypatches/local/$va_patches_dir" ]; then
        search_dir=".mypatches/local/$va_patches_dir .mypatches/pick/$va_patches_dir"
    fi

    find $search_dir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///" -e "s/\//:/" |sort -t : -k 2 | while read line; do
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
                  echo "==== try apply to $project: "
                  #rm -rf .git/rebase-apply
             fi
             if echo $f | grep -qE "\[WIP\]|\[SKIP\]"; then
                 echo "    skipping: $f"
                 continue
             fi

             ext=${patchfile##*.}
             #rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                       echo "    patching: $f ..."
                       git am -3 -q   --keep-cr --committer-date-is-author-date < $topdir/.mypatches/$f
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
                  else
                       echo "    skipping: $f ...(applied always)"
                  fi
             fi
         fi
    done

    cd $topdir
    if [ "$va_patches_dir" = "local" -a -d $topdir/.mypatches/overwrite ]; then
        search_dir=.mypatches/overwrite
        find $search_dir -type f | sed -e "s/\.mypatches\/overwrite\///"  | while read f; do
             [ -f $line ] && cp $search_dir/$f $f
        done
    fi

}

function reset_overwrite_projects()
{
    cd $topdir
    [ -f .mypatches/overwrite/projects.list ] && rm -f .mypatches/overwrite/projects.list
    [ -d ".mypatches/overwrite" ] || return
    find ".mypatches/overwrite" -type f | sed -e "s/\.mypatches\/overwrite\///"  | while read f; do
        while [ $f != $(dirname $f) -a ! -d $(dirname $f)/.git ]; do
              f=$(dirname $f)
        done
        f=$(dirname $f)
        if [ -d $topdir/$f ]; then
            if ! grep -q $f .mypatches/overwrite/projects.list 2>/dev/null ; then
                git -C $topdir/$f stash >/dev/null
                echo $f >> .mypatches/overwrite/projects.list
            fi
        fi
    done
}

function projects_reset()
{
    cd $(gettop)
    topdir=$(gettop)
    default_branch=$(cat .repo/manifest.xml | grep "default revision" | cut -d= -f2 | sed -e "s/\"//g" -e "s/refs\/heads\///")

    find .mypatches -type d | sed -e "s/\.mypatches\///" |sort -n | while read project; do
         [ "$f" = ".mypatches" ] && continue
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
    snapshot_file=$topdir/.mypatches/snapshot.list
    local vproject=""
    [ "$1" != "" ] && vproject=$(echo $1 | sed -e 's/\/$//')
    rm -f $snapshot_file.new
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


         [ -d $topdir/.mypatches/pick/$project ] || mkdir -p $topdir/.mypatches/pick/$project
         rm -rf $topdir/.mypatches/pick/$project/*.patch
         rm -rf $topdir/.mypatches/pick/$project/*.diff

         git format-patch "$commit_id" -o $topdir/.mypatches/pick/$project/ | sed -e "s:.*/:              :"

         patches_count=$(find $topdir/.mypatches/pick/$project -maxdepth 1 -name "*.patch" -o -name "*.diff" | wc -l)
         if [ $patches_count -eq 0 ]; then
              rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/pick/$project
         elif [ -d $topdir/.mypatches/local/$project ]; then
              find $topdir/.mypatches/local/$project -maxdepth 1 -type f -name "*.patch" -o -name "*.diff" | while read patchfile; do
                   patch_file_name=$(basename $patchfile)
                   changeid=$(grep "Change-Id: " $patchfile | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
                   #echo "$project >  $patchfile  ==== Change-Id:$changeid"
                   if [ "$changeid" != "" ]; then
                       if grep -q "Change-Id: $changeid" -r $topdir/.mypatches/pick/$project; then
                           pick_patch=$(grep -H "Change-Id: $changeid" -r $topdir/.mypatches/pick/$project | sed -n 1p | cut -d: -f1)
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
                               mv $pick_patch $topdir/.mypatches/local/$project/
                           fi
                       elif ! echo $patchfile | grep -qE "\[WIP\]|\[SKIP\]|\[ALWAYS\]"; then
                           rm -f $patchfile
                       fi
                   fi
              done
         fi
         [ -d $topdir/.mypatches/pick/$project ] && find $topdir/.mypatches/pick/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
         [ -d $topdir/.mypatches/local/$project ] && find $topdir/.mypatches/local/$project -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
    done
    find $topdir/.mypatches -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null

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
    snapshot_file=$topdir/.mypatches/snapshot.list
    [ -f "$snapshot_file" ] || return -1
    cat $snapshot_file | while read line; do
         project=$(echo $line | cut -d, -f1 | sed -e "s/^ *//g" -e "s/ *$//g")
         basecommit=$(echo $line | cut -d, -f2 | sed -e "s/^ *//g" -e "s/ *$//g")
         remoteurl=$(echo $line | cut -d, -f3 | sed -e "s/^ *//g" -e "s/ *$//g")

         tmp_skip_dirs=/tmp/skip_dirs_$(echo $project | sed -e "s:/:_:g")
         cd $topdir/$project || resync_project $project;cd $topdir/$project

         echo ">>>  restore project: $project ... "
         git stash -q || resync_project $project;cd $topdir/$project
         LANG=en_US git clean -xdf | sed -e "s/Skipping repository //g" | sed -e "s:/$::"> ${tmp_skip_dirs}
         if git log -n0 $basecommit >/dev/null 2>/dev/null; then
             git checkout -q --detach $basecommit>/dev/null 2>/dev/null
         else
             resync_project $project;cd $topdir/$project
             git fetch $remoteurl $basecommit && git checkout -q FETCH_HEAD >/dev/null 2>/dev/null
         fi 

         searchdir=""
         [ -d $topdir/.mypatches/pick/$project ] && searchdir="$searchdir $topdir/.mypatches/pick/$project"
         [ -d $topdir/.mypatches/local/$project ] && searchdir="$searchdir $topdir/.mypatches/local/$project"
         [ "$searchdir" != "" ] && \
         find $searchdir -type f -name "*.patch" -o -name "*.diff" | sed -e "s:$topdir/.mypatches/::"  -e "s|\/|:|" |sort -t : -k 2 | while read line; do
             rm -rf $topdir/$project/.git/rebase-apply
             f=$(echo $line | sed -e "s/:/\//")
             fdir=$(dirname $f | sed -e "s:$project/::" | sed -e "s:^[^/]*/::g" |sed -e "s:\[.*::g" | sed -e "s:/$::")
             grep -q -E "^$fdir$" ${tmp_skip_dirs} && continue
             patchfile=$(basename $f)
             if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
                  echo "         skipping: $f"
                  continue
             fi
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                      echo "         apply patch: $f ..."
                      git am -3 -q  --keep-cr --committer-date-is-author-date < $topdir/.mypatches/$f
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
         [ -f $topdir/.mypatches/rr-cache/rr-cache.list ] && \
         find $topdir/.mypatches/rr-cache/ -mindepth 1 -maxdepth 1 -type d | xargs rm -rf  &&\
         cat $topdir/.mypatches/rr-cache/rr-cache.list | while read line; do
             project=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f2)
             rrid=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f1)
             if [ -d $topdir/$project/.git/rr-cache/$rrid ]; then
                  rm -rf  $topdir/.mypatches/rr-cache/$project/$rrid
                  rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/rr-cache/$project >/dev/null 2>/dev/null
                  if  [ -d $topdir/$project/.git/rr-cache/$rrid ] && find $topdir/$project/.git/rr-cache/$rrid -name "postimage*" > /dev/null 2>/dev/null; then
                      [ -d $topdir/.mypatches/rr-cache/$project/$rrid ] || mkdir -p $topdir/.mypatches/rr-cache/$project/$rrid
                      cp -r $topdir/$project/.git/rr-cache/$rrid $topdir/.mypatches/rr-cache/$project/
                  fi
             fi
         done
    elif [ "$1" = "-restore" -o "$1" = "restore" ]; then
         [ -f  $topdir/.mypatches/rr-cache/rr-cache.list ] && \
         cat $topdir/.mypatches/rr-cache/rr-cache.list | while read line; do
             project=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f2)
             rrid=$(echo $line | sed -e "s: \{2,\}: :g" | sed -e "s:^ ::g" | cut -d' ' -f1)
             if [ -d $topdir/.mypatches/rr-cache/$project/$rrid ] && [ ! -z "$(ls -A $topdir/.mypatches/rr-cache/$project/$rrid)" ]; then
                   rm -rf $topdir/$project/.git/rr-cache/$rrid
                   [ -d $topdir/$project/.git/rr-cache/$rrid ] || mkdir -p $topdir/$project/.git/rr-cache/$rrid
                   cp -r $topdir/.mypatches/rr-cache/$project/$rrid/* $topdir/$project/.git/rr-cache/$rrid/
             fi
         done
    fi
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
               [ -d $topdir/.mypatches/rr-cache ] || mkdir -p $topdir/.mypatches/rr-cache
               [ "$script_file" == "bash" -a ! -f $topdir/.mypatches/rr-cache/rr_cache_list ] && rr_cache_list="rr-cache.list"
                
               [ -f $topdir/.mypatches/rr-cache/$rr_cache_list ] || touch $topdir/.mypatches/rr-cache/$rr_cache_list
               if ! grep -q "$rrid $project" $topdir/.mypatches/rr-cache/$rr_cache_list; then
                    echo "$rrid $project" >> $topdir/.mypatches/rr-cache/$rr_cache_list
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
    for op in $*; do
        if [ $op_is_m_parent -eq 1 ]; then
             [[ $op =~ ^[0-9]+$ ]] && [ $op -lt 10 ] && m_parent=$op
             op_is_m_parent=0
             continue
        elif [ $op_is_topic -eq 1 ]; then
             topic=$op
             op_is_topic=0
        fi
        [ "$op" = "-m" ] && op_is_m_parent=1 && continue
        [ -z "$changeNumber" ] && [[ $op =~ ^[0-9]+$ ]] && [ $op -gt 1000 ] && changeNumber=$op
        [ "$op" = "-f" ] && op_force_pick=1
        [ "$op" = "-t" ] && op_is_topic=1
        nops="$nops $op"
    done
    if  [ "$changeNumber" = "" ]; then
         if [ "$topic" != "" ]; then
               echo ">>> Picking topic [$topic] ..."
         else
               echo ">>> Picking $nops ..."
         fi
         repopick $nops || exit -1
         return 0
    fi
    echo ">>> Picking change $changeNumber ..."
    LANG=en_US repopick -c $checkcount $nops >$logfile 2>$errfile
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
    #echo " ---subject=$subject"
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
              LANG=en_US https_proxy="$https_proxy" repopick -c $checkcount $nops >$logfile 2>$errfile
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
                    LANG=en_US repopick -c $checkcount $nops >$logfile 2>$errfile
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
          echo "  >>**** repopick failed !"
          breakout=-1
          break
    done

    [ -z $recent_changeid_tmp ] ||  rm -f $recent_changeid_tmp

    if [ $breakout -lt 0 ]; then
        [ -f $errfile ] && cat $errfile
        if [ $0 = "bash" ]; then
           return $breakout
        else
           exit $breakout
        fi
    elif [ -f $logfile ]; then
        [ "$project" = "" ] && project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
        ref=$(grep "\['git fetch" $logfile | cut -d, -f2 | cut -d\' -f2)
        if [ "$project" = "android" ]; then
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
 
        if [ -f $logfile -a ! -z $changeNumber ]; then
            if grep -q -E "Change status is MERGED.|nothing to commit|git command resulted with an empty commit" $logfile; then
               [ ! -f $script_file.tmp -a "$script_file" != "bash" ] && cp $script_file $script_file.tmp
               [ -f $script_file.tmp ] && \
                  eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q -E "Change status is ABANDONED." $logfile; then
               [ ! -f $script_file.tmp -a "$script_file" != "bash" ] && cp $script_file $script_file.tmp
               [ -f $script_file.tmp ] && \
               eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q -E "Change $changeNumber not found, skipping" $logfile; then
               [ ! -f $script_file.tmp -a "$script_file" != "bash" ] && cp $script_file $script_file.tmp
               [ -f $script_file.tmp ] && \
               eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q "could not determine the project path for" $errfile; then
               [ ! -f $script_file.tmp -a "$script_file" != "bash" ] && cp $script_file $script_file.tmp
               [ -f $script_file.tmp ] && \
               eval  sed -E \"/[[:space:]]*kpick[[:space:]]\{1,\}$changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif [ "$changeNumber" != "" -a "$subject" != "" ]; then
               [ ! -f $script_file.tmp -a "$script_file" != "bash" ] && cp $script_file $script_file.tmp
               [ -f $script_file.tmp ] && \
               eval  "sed -e \"s|^[[:space:]]*kpick[[:space:]]\{1,\}\($changeNumber\)[[:space:]]*.*|kpick \1 \# $subject|g\" -i $script_file.tmp"
            fi
         fi
    fi
    rm -f $errfile $logfile
}

function privpick() {
  git -C $1 fetch github $2
  git -C $1 cherry-pick FETCH_HEAD
}

function apply_force_changes(){
    [ -z $topdir ] && topdir=$(gettop)
    [ -d "$topdir/.mypatches/local/vendor/lineage"  ] || return 0
    find $topdir/.mypatches/local/vendor/lineage/ -type f -name "*-\[ALWAYS\]-*.patch" -o -name "*-\[ALWAYS\]-*.diff" \
      | while read f; do
         cd $topdir/vendor/lineage;
         if ! git am -3 -q   --keep-cr --committer-date-is-author-date < $f; then
            exit -1
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
    else
         echo "kpick $op"
         kpick $op
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

if [ $0 != "bash" -a ! -f $0.tmp -a $op_pick_continue -eq 0 ]; then    # continue pick or not
rm -f $topdir/.repo/local_manifests/su.xml
repo sync vendor/lineage >/dev/null
apply_force_changes
reset_overwrite_projects

# android

repo sync android  >/dev/null
cd .repo/manifests
git reset >/dev/null
git stash >/dev/null
git rebase --abort >/dev/null 2>/dev/null
git fetch --all >/dev/null

default_branch=$(grep "^[[:space:]]*<default revision=" $topdir/.repo/manifests/default.xml | sed -e 's:[^"]*"\(.*\)":\1:' | sed -e "s:refs/heads/::g")
git reset --hard $(git branch -a | grep "remotes/m/$default_branch" | cut -d'>' -f 2 | sed -e "s/ //g") >/dev/null
cd $topdir

kpick 223886 # manifest: Re-add hardware/qcom/data/ipacfg-mgr
kpick 227745 # lineage: Enable FM apps
kpick 225583 # manifest: Enable lineage styles overlays
kpick 227747 # lineage: Enable weather apps
kpick 226755 # lineage: Enable cryptfs_hw
kpick 231968 # manifest: android-9.0.0_r10 -> android-9.0.0_r12
kpick 231971 # manifest: sync gcc4.9 from aosp oreo

android_head=$(cd android;git log -n 1 | sed -n 1p | cut -d' ' -f2;cd $topdir)

if [ -d $topdir/system/extras/su/.git ]; then
    cd $topdir/system/extras/su
    git stash >/dev/null
    git reset >/dev/null
    git clean -xdf >/dev/null
    cd $topdir
fi
repo sync --force-sync  || exit $?

cd android;git reset --hard $android_head >/dev/null;cd $topdir

apply_force_changes

fi       # continue pick or not

# ================= DEVICE STUFF =========================

# device/samsung/kltechnduo

# device/samsung/klte-common
kpick 231209 # klte-common: nfc: pn547: Use prebuilt NFC HAL from 15.1
kpick 225192 # klte-common: Align ril.h to samsung_msm8974-common P libril changes
kpick 224917 # DO NOT MERGE: klte-common: Requisite bring-up BS change

# device/samsung/msm8974-common
kpick 231350 # msm8974-common: Set TARGET_NEEDS_NETD_DIRECT_CONNECT_RULE to true
kpick 228677 # msm8974-common: Make the external camera provider ignore internal cameras
kpick 224916 # DO NOT MERGE: msm8974-common: sepolicy: Just make it build

# device/samsung/qcom-common

# kernel/samsung/msm8974

# =============== END DEVICE STUFF ========================

# bionic
kpick 223063 # Restore android_alarm.h kernel uapi header
kpick 223067 # libc fortify: Ignore open() O_TMPFILE mode bits warning
kpick 225463 # bionic: Let popen and system fall back to /sbin/sh
kpick 230099 # Actually restore pre-P mutex behavior
kpick 232002 # Merge android-9.0.0_r12

# boot/recovery
#kpick 230746 # sr: Get a proper shell environment in recovery
kpick 230747 # update_verifier: skip verity to determine successful on lineage builds
kpick 231718 # recovery: Declare a soong namespace

# build/make
kpick 222733 # core: Disable vendor restrictions
kpick 222742 # build: Use project pathmap for recovery
kpick 222760 # Add LOCAL_AIDL_FLAGS
kpick 227111 # releasetools: Store the build.prop file in the OTA zip
kpick 229491 # build: Automatically replace old-style kernel header includes with new header lib

# build/soong
kpick 222648 # Allow providing flex and bison binaries
kpick 224613 # soong: Add LOCAL_AIDL_FLAGS handling
kpick 226443 # soong: Add additional_deps attribute for libraries and binaries
kpick 229411 # soong sbox: Add option to allow copying all generated output
kpick 232004 # Merge android-9.0.0_r12

# dalvik
kpick 225475 # dexdeps: Add option for --include-lineage-classes.
kpick 225476 # dexdeps: Ignore static initializers on analysis.

# device/lineage/sepolicy
#kpick 225945 # sepolicy: Update to match new qcom sepolicy
kpick 229423 # selinux: add domain for snap
kpick 229424 # selinux: add domain for Gallery

# device/qcom/sepolicy
kpick 228566 # qcom: Label vendor files with (vendor|system/vendor) instead of vendor
kpick 228569 # Use set_prop() macro for property sets
kpick 228570 # sepolicy: Allow wcnss_service to set wlan.driver properties
kpick 228571 # sepolicy: allow system_server to read alarm boot prop
kpick 228572 # sepolicy: Allow system_server to 'read' qti_debugfs
kpick 228573 # sepolicy: Add libsdm-disp-vndapis and libsdmutils to SP-HALs
kpick 228574 # sepolicy: Allow thermal-engine to read sysfs_uio[_file]
kpick 228575 # sepolicy: Add libcryptfs_hw to SP HALs
kpick 228576 # sepolicy: Label mpctl_socket as data_file_type
kpick 228578 # sepolicy: rules to allow camera daemon access to app buffer
kpick 228580 # hal_gnss_default: Do not log udp socket failures
kpick 228582 # sepolicy: qti_init_shell needs to read dir too
kpick 228583 # sepolicy: allow vold to read persist dirs
kpick 228584 # sepolicy: Fix video4linux "name" node labeling
kpick 228585 # sepolicy: Allow mm-qcamerad to access v4L "name" node
kpick 228586 # common: Fix labelling of lcd-backlight
kpick 228587 # sepolicy: Allow perf HAL to set freq props

# device/qcom/sepolicy-legacy
kpick 228608 # sepolicy-legacy: Treat BT vendor properties like non-vendor ones.
kpick 230229 # mm-qcamera-daemon: fix denial
kpick 230230 # common: fix sensors denial
kpick 230231 # common: grant cnss-daemon access to sysfs_net
kpick 230232 # common: grant netmgrd access to sysfs_net nodes
kpick 230233 # common: allow sensors HIDL HAL to access /dev/sensors
kpick 230234 # common: allow wifi HIDL HAL to read tombstones
kpick 230235 # common: grant DRM HIDL HAL ownership access to /data/{misc,vendor}/media/
kpick 230236 # common: label /sys/devices/virtual/graphics as sysfs_graphics
kpick 230237 # common: allow vendor_init to create /data/dpm
kpick 230238 # common: create proc_kernel_sched domain to restrict perf hal access
kpick 230239 # common: allow uevent to control sysfs_mmc_host via vold
kpick 230828 # legacy: Label more power_supply sysfs
kpick 230829 # legacy: Resolve hal_gnss_default denial
kpick 230830 # legacy: Resolve hal_bluetooth_default denial
kpick 230831 # sepolicy: Allow android service to write on tombstones
kpick 230833 # legacy: Correctly label display.qservice
kpick 230834 # legacy: allow init to read /proc/device-tree

# development
kpick 232005 # Merge android-9.0.0_r12

# external/ant-wireless/ant_native
kpick 227260 # Update bt vendor callbacks array in vfs code
kpick 227261 # Cast BT_VND_OP_ANT_USERIAL_{OPEN,CLOSE} to bt_vendor_opcode_t in vfs code

# external/perfetto
kpick 223413 # perfetto_cmd: Resolve missing O_CREAT mode

# external/tinycompress
kpick 229414 # tinycompress: Use generated kernel headers

# external/zlib
kpick 225237 # zlib: Fix build under Android 6.0 and higher
kpick 225238 # minizip: Clean up the code
kpick 225239 # zlib: crc optimization for arm64

# frameworks/av
kpick 230387 # CameraService: Support calling addStates in enumerateProviders
kpick 230642 # CameraService: Initialize CameraParameters for the cameras and cache them onFirstRef
kpick 231348 # camera: Allow to use boottime as timestamp reference
kpick 232006 # Merge android-9.0.0_r12

# frameworks/base
kpick 224266 # SystemUI: Add Lineage statusbar item holder
kpick 224267 # SystemUI: Network Traffic [1/3]
kpick 224446 # SystemUI: Make tablets great again
kpick 224513 # SystemUI: Disable config_keyguardUserSwitcher on sw600dp
kpick 224844 # lockscreen: Add support for showing unlock screen directly
kpick 225582 # [TEMP]: Revert "OMS: harden permission checks"
kpick 225754 # SystemUI: Berry styles
kpick 226236 # SystemUI: add navbar layout inversion tuning
kpick 226343 # CameraServiceProxy: Loosen UID check
kpick 226358 # settings: Allow accessing LineageSettings via settings command
kpick 226398 # frameworks: base: Port password retention feature
kpick 226399 # Use fdeCheckPassword error code to indicate pw failure
kpick 226400 # LockSettingsService: Support for separate clear key api
kpick 226401 # AppOps: track op persistence by name instead of id
kpick 226587 # Camera: Expose Aux camera to apps present in the whitelist
kpick 226588 # camera: Check if aux camera whitelist is set before restricting cameras
kpick 226600 # PhoneWindowManager: Check if proposed rotation is in range
kpick 226615 # NavigationBarView: Avoid NPE before mPanelView is created
kpick 227108 # SystemUI: Fix several issues in the ADB over Network tile
kpick 227290 # PowerProfile: allow overriding default power profile
kpick 227291 # [DNM] Revert "Handle public volumes and otherwise invalid UUIDs."
kpick 227821 # GlobalScreenshot: Fix screenshot not saved with some languages
kpick 227839 # storage: Set all sdcards to visible
kpick 227896 # SystemUI: Add Profiles tile
kpick 221716 # Where's my circle battery, dude?
kpick 228664 # [dnm][temp]display: Don't animate screen brightness when turning the screen on
kpick 229166 # NightDisplayController: report unavailable if livedisplay feature is present
kpick 229230 # SystemUI: allow the power menu to be relocated
kpick 229307 # Add CHANNEL_MODE_DUAL_CHANNEL constant
kpick 229308 # Add Dual Channel into Bluetooth Audio Channel Mode developer options menu
kpick 229309 # Allow SBC as HD audio codec in Bluetooth device configuration
kpick 229606 # ConsumerIR: Support Huawei's DSP chip implementation
kpick 229612 # Performance: Memory Optimizations.
kpick 230016 # Implement expanded desktop feature
kpick 230388 # base: show bluetooth battery status when available
kpick 230600 # FingerprintService: add property to prevent cleanup of unused fingerprints
kpick 231796 # SignalClusterView: Hide signal icons for disabled SIMs
kpick 231797 # Keyguard: Remove carrier text for disabled SIMs
kpick 231823 # Do not move the multi-window divider when showing IME
kpick 231824 # Fix StatusBar icons tinting when in split screen
kpick 231827 # Add display shrink mode
kpick 231847 # onehand: Enable debug only on eng builds
kpick 231848 # SystemUI: Add one hand mode triggers
kpick 231851 # onehand: Take into account cutouts
kpick 231852 # onehand: Remove guide link
kpick 232007 # Merge android-9.0.0_r12
kpick 232197 # appops: Privacy Guard for P (1/2)

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
kpick 232008 # Merge android-9.0.0_r12

# frameworks/opt/net/wifi
kpick 224675 # libwifi-hal: add flag to wait for kernel driver to get ready
kpick 224676 # wifi: Check whether dev node is accessible or not before opening
kpick 224677 # wifi: don't check if WIFI_DRIVER_STATE_CTRL_PARAM is readable
kpick 225551 # wifi: Not reset country code for Dual SIM if any slot is active
kpick 232038 # Merge android-9.0.0_r12

# frameworks/opt/telephony
kpick 227125 # RIL: Allow overriding RadioResponse and RadioIndication
kpick 229601 # Implement signal strength hacks used on Huawei devices
kpick 229602 # telephony: Squashed support of dynamic signal strength thresholds
kpick 229603 # telephony: Query LTE thresholds from CarrierConfig
kpick 229604 # Telephony: Use a common prop for Huawei RIL hacks (1/2)
kpick 229605 # Telephony: Don not call onUssdRelease for Huawei RIL
kpick 231595 # Enable vendor Telephony plugin
kpick 231596 # Enable vendor Telephony plugin: MSIM Changes
kpick 231598 # Telephony: Send INITIAL_ATTACH only when it is applicable.
kpick 232039 # Merge android-9.0.0_r12

# hardware/boardcom/libbt
#kpick 225155 # Broadcom BT: Add support fm/bt via v4l2.
#kpick 226447 # libbt: Make sure that we don't load pre-patch when looking for patch

# hardware/boardcom/nfc

# hardware/interfaces
kpick 225506 # Camed HAL extension: Added support in HIDL for Extended FD.
kpick 225507 # camera: Only link and use vendor.qti.hardware.camera.device if specified
kpick 226402 # keymasterV4_0: Tags support for FBE wrapped key.
kpick 232040 # Merge android-9.0.0_r12

# hardware/lineage/interfaces
kpick 223374 # interfaces: Add 2.0 livedisplay interfaces
kpick 223410 # interfaces: Add touch HIDL interface definitions
kpick 223411 # interfaces: Add id HAL definition

# hardware/lineage/lineagehw

# hardware/nxp/nfc
kpick 223192 # nfc: Restore pn548 support to 1.1 HAL
#kpick 223193 # nxp: Rename HAL to @1.1-service-nxp
#kpick 223194 # nxp: Begin restoring pn547

# hardware/qcom/audio
kpick 222690 # audio: Use kernel headers
kpick 223338 # Revert "msm8x74: remove from top level makefile"
kpick 230749 # audio: Use generated kernel headers
kpick 232009 # Merge android-9.0.0_r12

# hardware/qcom/audio-caf/msm8974

# hardware/qcom/bootctl
kpick 232041 # Merge android-9.0.0_r12

# hardware/qcom/bt-caf

# hardware/qcom/display
kpick 223340 # Revert "msm8974: deprecate msm8974"
kpick 223341 # display: Always assume kernel source is present
kpick 223342 # display: add TARGET_PROVIDES_LIBLIGHT
kpick 223343 # msm8974: Move QCOM HALs to vendor partition
kpick 223344 # msm8974: hwcomposer: Fix regression in hwc_sync
kpick 223345 # msm8974: libgralloc: Fix adding offset to the mapped base address
kpick 223346 # msm8974: libexternal should depend on libmedia
kpick 224958 # msm8960/8974: Include string.h where it is necessary

# hardware/qcom/display-caf/msm8974

# hardware/qcom/fm
kpick 226731 # Use BOARD_HAVE_QCOM_FM flag
kpick 226745 # fm_hci/helium: Exclude from OSS builds
kpick 226683 # Bring back libfm_jni for devices using AOSP FM app
kpick 226685 # jni/libfm_jni: fix calibration data path for legacy fm_qsoc_patches
kpick 226692 # jni/libfm_jni: Skip loading FM firmware if requested
kpick 226687 # libfm_jni: Do not come here unless QCOM_HARDWARE is in use
kpick 226688 # libfm_jni: Add support for internal antenna hardware
kpick 226689 # libfm_jni: Improve and fix FM jni logs
kpick 226737 # libfm_jni: Fix strchr implicit char* typecast in ConfFileParser
kpick 226738 # libfm_jni: Add jni core headers dependency
kpick 226742 # jni/libfm_jni: Remove unused variables
kpick 226743 # libfm_jni: Resolve fread assignment to condition cast
kpick 223685 # jni/libfm_jni: Resolve FM_DEVICE_PATH R/O open flag
kpick 226744 # jni/libfm_jni: Ignore unused parameters from APIs
kpick 223678 # libfm_jni: use proper nativehelper headers
kpick 223684 # jni: Resolve equality comparisons with extraneous parentheses
kpick 223687 # jni: Resolve V4L2_CID_AUDIO_MUTE redefinitions
kpick 223692 # jni: Resolve -Wwritable-strings warnings in helium FW library variables
kpick 226741 # Allow library to be used by apps directly
kpick 226694 # FM: Break bootclasspath dependency
kpick 226696 # FM: Re-vamp UI
kpick 226697 # FM: Restore seek arrows
kpick 226710 # FM: Make default country an overlay
kpick 226699 # FM: Re-add RDS fields to UI
kpick 226700 # FM: Scanned frequencies are saved in ascending ordering
kpick 226701 # FM: Call unregister in onPause
kpick 226702 # FM: Switch file extension to aac
kpick 226714 # FM: Add property to force use internal antenna
kpick 226727 # FM: Cleanup resources
kpick 226705 # FM: add Indonesia
kpick 226732 # FM: materialize
kpick 226709 # FM: retune last frequency when resume after call
kpick 226711 # FM: Store tag num/value in sequence
kpick 226712 # FM: reenable radio text visibility after station info updated
kpick 226713 # FM: Launch station list automatically after scan
kpick 226715 # FM: fix mRadioTextScroller usage in transmitter activity
kpick 226716 # FM: Fix status text to reflect when FM is enabled.
kpick 226717 # FM: The collect channel disappear when quit FM
kpick 226718 # FM: Ensure scan state is kept in sync
kpick 226719 # FM: Keep track of scanned frequencies in service
kpick 226721 # FM: Select band based on country
kpick 226722 # FM: improved band selection
kpick 226723 # FM: Localization of band types
kpick 226724 # FM: Fix settings UI bugs
kpick 226725 # FM: Fix headphone icon
kpick 226726 # FM: Update India bands
kpick 226729 # FM: Convert regional band arrays to string references
kpick 226734 # FM: Fix KHz->kHz
kpick 226735 # FM: Convert FM transmitter notifications to use NotificationChannel
kpick 226736 # FM: Revamp notifications
kpick 226740 # FM: adaptive icon

# hardware/qcom/gps
kpick 223351 # Revert "msm8974: deprecate msm8974"
kpick 223352 # Revert "msm8974: remove from top level makefile"
kpick 223353 # msm8974: Add missing liblog dependency
kpick 223354 # msm8974: Default apn ip type to ipv4
kpick 223355 # msm8974: Cleanup obsolete LOCAL_PRELINK_MODULE
kpick 223356 # msm8974: Move device dependent modules to /vendor
kpick 223357 # msm8974: Fix duplicate gps.conf for hammerhead
kpick 223358 # msm8974: Fix logging level and remove nmea log
kpick 223359 # msm8974: Don't rely on transitively included headers
kpick 223360 # msm8974: Return the correct length of nmea sentence
kpick 225034 # msm8974: Add -Wno-error to compile with global -Werror.
kpick 232010 # Merge android-9.0.0_r12

# hardware/qcom/keymaster
kpick 224954 # keymaster: move to /vendor

# hardware/qcom/media
kpick 224289 # Add -Wno-error to compile with global -Werror.
kpick 222695 # media: Add missing links
kpick 224305 # media: Use kernel headers
kpick 230750 # media: Use generated kernel headers
kpick 224955 # Revert "msm8974: remove from top level makefile"
kpick 224956 # mm-video: venc: Correct a typo in variable name
kpick 224957 # media: vdec: Include nativebase headers

# hardware/qcom/media-caf/msm8974

# hardware/qcom/power
kpick 230513 # power: msm8960: Implement performance profiles
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

# hardware/qcom/wlan-caf
kpick 226638 # wcnss_qmi: Generate a fixed random mac address if the NV doesn't provide one
kpick 226643 # wcnss_service: Read serial number from custom property

# hardware/ril
kpick 230736 # libril: Fix manual network selection with old modem

# hardware/ril-caf
kpick 227614 # Disable IOemHook implemenation in rild.
kpick 230737 # libril: Fix manual network selection with old modem

# hardware/samsung
kpick 225628 # Sending empty strings instead of NULL for some RIL requests
kpick 225629 # libril: Remove LOCAL_CLANG
kpick 225630 # libril: Fix Const-Correctness for RIL_RadioFunctions
kpick 225631 # libril: Remove unused code
kpick 225632 # libril: Fix double freeing of memory in SAP service and add null-checks.
kpick 225633 # libril: Store the system time when NITZ is received.
kpick 225634 # libril: Add DISABLE_RILD_OEM_HOOK.
kpick 225635 # libril: Change rild initial sequence to guarantee non-null function pointer before rild register its hidl service
kpick 226075 # libril: remove unused variables/functions
kpick 226076 # libsecril-client-sap: remove unused variables
kpick 226077 # libsecril-client: remove unused variables/functions
kpick 226080 # libril: Replace strncpy with strlcpy.
kpick 227453 # power: remove getFeature functionality
kpick 227454 # power: Add Lineage power hints
kpick 231194 # power: properly initialize cluster states

# kernel/samsung/msm8974

# lineage-sdk
kpick 225581 # lineage-sdk: Make styles init at system services ready
kpick 226810 # lineage-sdk: Bump PREF_HAS_MIGRATED_LINEAGE_SETTINGS for 16.0
kpick 227931 # lineagesdk: Refactor battery icon options
kpick 230272 # sdk: Remove VOLUME_KEYS_CONTROL_RING_STREAM
kpick 230284 # Revert "[3/3] cmsdk: add burnIn protection setting"
kpick 230856 # sdk: Don't clear calling identify when calling IOverlayManager.setEnabled()

# packages/apps/Bluetooth
kpick 229310 # SBC Dual Channel (SBC HD Audio) support
kpick 229311 # Assume optional codecs are supported if were supported previously
kpick 232042 # Merge android-9.0.0_r12

# packages/apps/Calender

# packages/apps/Camera2
kpick 224752 # Use mCameraAgentNg for getting camera info when available
kpick 225265 # Add Storage preference (1/2)
kpick 232011 # Merge android-9.0.0_r12

# packages/apps/Carrierconfig
kpick 232012 # Merge android-9.0.0_r12

# packages/apps/CellBroadcastReciver
kpick 229303 # Only enable presidential CMAS alerts if user is a monkey
kpick 232043 # Merge android-9.0.0_r12

# packages/apps/Contacts
kpick 232013 # Merge android-9.0.0_r12

# packages/apps/DeskClock
kpick 226131 # DeskClock: Add support of power off alarm feature
kpick 232014 # Merge android-9.0.0_r12

# packages/apps/Dialer

# packages/apps/DocumentsUI
kpick 225289 # DocumentsUI: support night mode
kpick 232015 # Merge android-9.0.0_r12

# packages/apps/Eleven

# packages/apps/Email

# packages/apps/Gallery2

# packages/apps/Jelly
kpick 231418 # Automatic translation import
kpick 231710 # Jelly: Set proper mime type when downloading files
kpick 231711 # Jelly: Grant REQUEST_INSTALL_PACKAGES permission

# packages/apps/LatinIME
kpick 232022 # Merge android-9.0.0_r12

# packages/apps/LineageParts
kpick 227930 # LineageParts: Bring back and refactor battery icon options
kpick 221756 # StatusBarSettings: Hide battery preference category based on icon visibility
kpick 229389 # Trust: enforce vendor security patch level check
#kpick 230017 # LineageParts: Re-enable expanded desktop.
kpick 231163 # LineageParts: Add some missing psychedelics
kpick 232146 # LineageParts: Reenable Privacy Guard

# packages/apps/ManagedProvisoning
kpick 232047 # Merge android-9.0.0_r12

# packages/apps/Nfc
kpick 232016 # Merge android-9.0.0_r12

# packages/apps/PackagesInstaller
kpick 232017 # Merge android-9.0.0_r12

# packages/apps/PhoneCommon
kpick 232048 # Merge android-9.0.0_r12

# packages/apps/Settings
kpick 225755 # Settings: Hide AOSP theme-related controllers
kpick 225756 # Settings: fix dark style issues
kpick 226148 # Settings: "Security & location" -> "Security & privacy"
kpick 226142 # Settings: Add developer setting for root access
kpick 226150 # Settings: add Trust interface hook
kpick 226151 # Settings: show Trust brading in confirm_lock_password UI
kpick 226154 # fingerprint: Allow devices to configure sensor location
kpick 227120 # Settings: Check interfaces before enabling ADB over network
kpick 227929 # Settings: Remove battery percentage switch
kpick 229167 # Settings: Hide Night Mode suggestion if LiveDisplay feature is present
kpick 229312 # Add Dual Channel into Bluetooth Audio Channel Mode developer options menu
kpick 229453 # Settings: use LineageHW serial number
kpick 229479 # Settings: Improve phone number preference ordering
kpick 231518 # Settings: Check if we have any color modes declared in overlay
kpick 231590 # SimSettings: Add manual SIM provisioning support
kpick 231826 # Update the white list of Data saver
kpick 232001 # lockscreen: Forward port option to pass swipe-up-to-unlock
kpick 232019 # Merge android-9.0.0_r12
kpick 232198 # settings: appops: privacy guard for p (2/2)

# packages/apps/SettingsIntelligence
kpick 230519 # Fix dark style issues
kpick 231538 # SettingsIntelligence: Match Settings style
kpick 231539 # SettingsIntelligence: Regen database on build version change
kpick 231825 # Increase time limit of search task

# packages/apps/Stk
kpick 232020 # Merge android-9.0.0_r12

# packages/apps/StoreManager
kpick 232049 # Merge android-9.0.0_r12

# packages/apps/Traceur
kpick 232050 # Merge android-9.0.0_r12

# packages/apps/Trebuchet
kpick 223666 # Settings: Hide Notification Dots on low RAM devices

# packages/apps/TvSettings
kpick 232021 # Merge android-9.0.0_r12

# packages/apps/Updater
kpick 229354 # Updater: Allow Cleartext HTTP communications

# packages/providers/DownloadProvider
kpick 232023 # Merge android-9.0.0_r12

# packages/providers/MediaProvider

# packages/providers/TelephonyProvider
kpick 232025 # Merge android-9.0.0_r12

# packages/services/BuiltinPrintService
kpick 232052 # Merge android-9.0.0_r12

# packages/services/Telecomm
kpick 232054 # Merge android-9.0.0_r12

# packages/services/Telephony
kpick 229610 # Telephony: Support muting by RIL command
kpick 229611 # Telephony: Use a common prop for Huawei RIL hacks (2/2)
kpick 232026 # Merge android-9.0.0_r12

# system/bt
kpick 224813 # bt: osi: undef PROPERTY_VALUE_MAX
kpick 225422 # Bluetooth: Read BLE vendor capability to proceed on Secure conn
kpick 223945 # Prevent abort in case of command timeout
kpick 225423 # Add support to force disable enhanced sco commands
kpick 229125 # Increase maximum Bluetooth SBC codec bitpool and bitrate values
kpick 229313 # Explicit SBC Dual Channel (SBC HD) support
kpick 229314 # Allow using alternative (higher) SBC HD bitrates with a property
kpick 229401 # [DNM] Revert "Return early if vendor-specific command fails"
kpick 230382 # Fix for Bluetooth device name is resetting to default name after reboot
kpick 232027 # Merge android-9.0.0_r12

# system/core
privpick system/core refs/changes/19/206119/2 # init: I hate safety net
kpick 223085 # adbd: Disable "adb root" by system property (2/3)
kpick 224264 # debuggerd: Resolve tombstoned missing O_CREAT mode
kpick 226119 # libion: save errno value
kpick 226120 # fs_mgr: Wrapped key support for FBE
kpick 230755 # libsuspend: Bring back earlysuspend
kpick 231716 # init: Always use libbootloader_message from bootable/recovery namespace
kpick 232028 # Merge android-9.0.0_r12

# system/extras
kpick 225426 # f2fs_utils: Add a static libf2fs_sparseblock for minvold
kpick 225427 # ext4_utils: Fix FS creation for filesystems with exactly 32768 blocks.
kpick 232055 # Merge android-9.0.0_r12

cd system/extras/
git stash >/dev/null
git clean -xdf >/dev/null
cd $topdir
kpick 225428 # extras: remove su

if [ -f $topdir/.mypatches/su.xml ]; then
   cp $topdir/.mypatches/su.xml $topdir/.repo/local_manifests/su.xml

   #if [ -d $topdir/system/extras/su ]; then
   #   cd $topdir/system/extras/su
   #   git stash >/dev/null
   #fi
   repo sync --force-sync system/extras/su
fi

# system/extras/su
kpick -P system/extras/su 226017 # su: Fully rebrand
kpick -P system/extras/su 225873 # su: strlcpy is always a friend
kpick -P system/extras/su 225879 # su: Run clang format
kpick -P system/extras/su 225880 # su: Move to cutils/properties.h
kpick -P system/extras/su 225875 # su: Enable Clang Tidy
kpick -P system/extras/su 225885 # su: Remove Sammy hacks
kpick -P system/extras/su 225888 # su: Fix a clang tidy warning
kpick -P system/extras/su 225889 # su: Cleanup includes
kpick -P system/extras/su 225890 # su: Use shared libraries
kpick -P system/extras/su 225936 # su: Remove mount of emulated storage
kpick -P system/extras/su 225937 # su: Initialize windows size

# system/libvintf

# system/netd
kpick 231201 # netd: Allow devices to force-add directly-connected routes
kpick 232029 # Merge android-9.0.0_r12

# system/security
kpick 232030 # Merge android-9.0.0_r12

# system/sepolicy
kpick 223748 # Build sepolicy tools with Android.bp.
kpick 230613 # Allow webview_zygote to read /dev/ion
kpick 232031 # Merge android-9.0.0_r12

# system/tool/aidl
kpick 223133 # AIDL: Add option to generate No-Op methods

# system/update/engine
kpick 225430 # update_engine: run backuptool script before normal postinstall script

# system/vold
kpick 226109 # vold: Add Hardware FDE feature
kpick 226110 # system: vold: Remove crypto block device creation
kpick 226127 # vold: Move QCOM HW FDE inclusion under lineage namespace
kpick 226111 # vold: Wrapped key support for FBE
kpick 229304 # vold: Add texfat and sdfat support
kpick 229954 # Move kMajor* constants to a header file
kpick 229955 # vold: ISO9660 and UDF support
kpick 231717 # vold: Always use libbootloader_message from bootable/recovery namespace
kpick 232032 # Merge android-9.0.0_r12

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
kpick 226126 # soong_config: Add flag for crypto waiting on QSEE to start
kpick 229508 # lineage: Move some kernel definitions to BoardConfigKernel
kpick 229412 # vendor/lineage: Add soong generator module type
kpick 229415 # lineage: Dynamically generate kernel headers using lineage generator
kpick 229505 # vendor/lineage: Remove kernel.mk headers generation
kpick 227392 # lineage: Dynamically add custom APNs
kpick 231219 # kernel: Remove deprecated flag errors
kpick 231220 # kernel: Remove kernel{x}config
kpick 229589 # lineage: Automatically set soong namespace when setting project pathmap
kpick 229590 # lineage: Move qcom pathmap setting into "BoardConfig"
kpick 229620 # backuptool: Support non-A/B system-as-root
kpick 231291 # repopick: add hashtag support
kpick 231981 # HWComposer: HWC2: allow SkipValidate to be force disabled

# vendor/qcom/opensource/cryptfs_hw
kpick 226128 # cryptfs_hw: Add compatibility for pre-O hw crypto
kpick 226129 # cryptfs_hw: Featureize support for waiting on QSEE to start
kpick 226130 # cryptfs_hw: add missing logging tag
kpick 226403 # cryptfs_hw: Remove unused variable
kpick 230271 # cryptfs_hw: Use generated kernel headers

#-----------------------
# translations

##################################
echo
echo "---------------------------------------------------------------"
[ "$op_auto" != "1" ] && read -n1 -r -p "  Picking remote changes finished, Press any key to continue..." key

[ $op_pick_remote_only -eq 0 ] && patch_local local
[ -f $script_file.tmp ] && mv $script_file.tmp $script_file.new
[ -f $topdir/.mypatches/rr-cache/rr-cache.tmp ] && \
   mv $topdir/.mypatches/rr-cache/rr-cache.tmp $topdir/.mypatches/rr-cache/rr-cache.list
rrCache backup # backup rr-cache

