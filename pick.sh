#!/bin/bash
source build/envsetup.sh
topdir=$(gettop)
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_pick_remote_only=0
op_snap_project=""
op_patches_dir=""
op_base_pick=0
default_remote="github"
script_file=$0
conflict_resolved=0

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

    if [ -d "$topdir/.mypatches/$va_patches_dir" ]; then
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
    rm -f $snapshot_file.new
    cat $topdir/.repo/project.list | while read project; do
         [ "$1" != "" -a "$project" != "$(echo $1 | sed -e 's/\/$//')" ] && continue
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

         [ "$1" != "" -a "$project" != "$1" ] || \
         echo "$project, $commit_id, $url" >> $snapshot_file.new

         [ -d $topdir/.mypatches/pick/$project ] || mkdir -p $topdir/.mypatches/pick/$project
         rm -rf $topdir/.mypatches/pick/$project/*.patch
         rm -rf $topdir/.mypatches/pick/$project/*.diff

         git format-patch "$commit_id" -o $topdir/.mypatches/pick/$project/ | sed -e "s:.*/:              :"

         patches_count=$(find $topdir/.mypatches/pick/$project -name "*.patch" -o -name "*.diff" | wc -l)
         if [ $patches_count -eq 0 ]; then
              rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/pick/$project
         elif [ -d $topdir/.mypatches/local/$project ]; then
              find $topdir/.mypatches/local/$project -type f -name "*.patch" -o -name "*.diff" | while read patchfile; do
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

    [ "$1" != "" -a "$project" != "$1" ] || \
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
    [ -f "$md5file" ] || return -1
    rrtmp=/tmp/$(echo $project | sed -e "s:/:_:g")_rr.tmp
    while read line; do
        #key=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f1)
        fil=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f2)
        #typ=$(echo $line | sed -e "s: \{2,\}: :g" | cut -d' ' -f3)
        key=$(md5sum $topdir/$project/$fil | sed -e "s/ .*//g")
        [ -d $topdir/.mypatches/rr-cache ] && \
        find $topdir/$project/.git/rr-cache/ -mindepth 2 -maxdepth 2 -type f -name "postimage*" > $rrtmp
        [ -f "$rrtmp" ] && while read rrf; do
            md5num=$(md5sum $rrf|cut -d' ' -f1)
            #echo "$key ?= $md5num   ----->  $rrf"
            if [ "$key" = "$md5num" ]; then
               rrid=$(basename $(dirname $rrf))
               [ -d $topdir/.mypatches/rr-cache ] || mkdir -p $topdir/.mypatches/rr-cache
               [ -f $topdir/.mypatches/rr-cache/rr-cache.tmp ] || touch $topdir/.mypatches/rr-cache/rr-cache.tmp
               if ! grep -q "$rrid $project" $topdir/.mypatches/rr-cache/rr-cache.tmp; then
                    echo "$rrid $project" >> $topdir/.mypatches/rr-cache/rr-cache.tmp
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
    logfile=/tmp/__repopick_tmp.log
    errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")

    rm -f $errfile
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
    fi

    echo ">>> Picking change $changeNumber ..."
    LANG=en_US repopick -c 50 $nops >$logfile 2>$errfile
    rc=$?
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
              cd $project
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
              LANG=en_US https_proxy="$https_proxy" repopick -c 50 $nops >$logfile 2>$errfile
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
                          rm -f $errfile
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
                    LANG=en_US repopick -c 50 $nops >$logfile 2>$errfile
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
        rm -f $errfile
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
        if [ -f $logfile -a "$script_file" != "bash" ]; then
            if grep -q -E "Change status is MERGED.|nothing to commit" $logfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q -E "Change status is ABANDONED." $logfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q -E "Change $changeNumber not found, skipping" $logfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            elif grep -q "could not determine the project path for" $errfile; then
               [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
               eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
            fi
         fi
    fi
    rm -f $errfile $logfile
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
    elif [ "$op" = "--backup-rr-cache" ]; then
         rrCache -backup
         exit $?
    elif [ "$op" = "--restore-rr-cache" ]; then
         rrCache -restore
         exit $?
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
   cd $topdir/system/core;find  $topdir/.mypatches/local/system/core/ -name "*I-hate-the-safty-net*.patch" | xargs cat \
         | git am -3   --keep-cr --committer-date-is-author-date; cd $topdir
   touch $topdir/.pick_base
   exit 0
fi
#---------------------------------#
###################################

apply_force_changes

# android
repo sync android >/dev/null 2>/dev/null
cd .repo/manifests;
git fetch --all >/dev/null 2>/dev/null
git reset --hard $(git branch -a | grep "/m/" | cut -d'>' -f 2 | sed -e "s/ //g")
cd $topdir

kpick 224442 # lineage: qcom: Fork newest custom audio policy HAL
kpick 224960 # lineage: Enable already working Lineage apps
kpick 223141 # manifest: pie sdk bringup
kpick 223893 # manifest: Re-enable bash, nano and other cmdline tools

android_head=$(cd android;git log -n 1 | sed -n 1p | cut -d' ' -f2;cd $topdir)
repo sync
cd android;git reset --hard $android_head >/dev/null 2>/dev/null;cd $topdir

# bionic
kpick 223063 # bionic: Let popen and system fall back to /sbin/sh
kpick 223065 # linker: Add support for dynamic SHIM libraries
kpick 223067 # libc fortify: Ignore open() O_TMPFILE mode bits warning
kpick 223412 # bionic: Fix compilation
kpick 223943 # bionic: meh
kpick 225463 # bionic: Let popen and system fall back to /sbin/sh
kpick 225464 # bionic: Sort and cache hosts file data for fast lookup
kpick 225465 # libc: Mark libstdc++ as vendor available

# boot/recovery
kpick 222993 # Revert "updater: Remove dead make_parents()."
kpick 222994 # Revert "otautil: Delete dirUnlinkHierarchy()."
kpick 222995 # Revert "kill package_extract_dir"
kpick 222996 # Revert "Remove the obsolete package_extract_dir() test"
kpick 222997 # Revert "updater: Remove some obsoleted functions for file-based OTA."
kpick 222998 # Revert "Format formattable partitions if mount fails"
kpick 223781 # Skip BLKDISCARD if not supported by the device

# build/make
kpick 222733 # core: Disable vendor restrictions
kpick 222742 # build: Use project pathmap for recovery
kpick 222750 # edify: bring back SetPermissionsRecursive
kpick 222754 # build/core: Create means of ignoring subdir layer for packages.
kpick 222760 # Add LOCAL_AIDL_FLAGS
kpick 222761 # Allow finer control over how product variables are inherited.
kpick 222762 # Revert "Remove the obsolete UnpackPackageDir() in edify generator"
kpick 222809 # DO NOT MERGE: disable inclusion of Lineage sepol
kpick 223138 # build/target: Include Lineage platform jars in system server.
kpick 223139 # build: Make sure we're building our secondary resource package as dependency.


# build/soong
kpick 222648 # Allow providing flex and bison binaries
kpick 223315 # soong: Special case org.lineageos.platform-res.apk
kpick 224204 # soong: Add function to return camera parameters library name
kpick 223431 # soong: Enforce absolute path if OUT_DIR is set
kpick 224613 # soong: Add LOCAL_AIDL_FLAGS handling
kpick 224827 # soong: Add java sources overlay support

# dalvik
kpick 225475 # dexdeps: Add option for --include-lineage-classes.
kpick 225476 # dexdeps: Ignore static initializers on analysis.

# device/samsung/kltechnduo

# device/samsung/klte-common
kpick 224917 # klte-common: Requisite bring-up BS change
kpick 225186 # klte-common: wlan: Update supplicant services for new calling sequence
kpick 225187 # klte-common: wifi_supplicant: deprecate entropy.bin
kpick 225188 # klte-common: wpa_supplicant: Move control sockets to /data/vendor
kpick 225189 # klte-common: Don't start supplicant with interfaces
kpick 225190 # klte-common: wpa_supplicant(hidl): Add support for starting HAL lazily
kpick 225191 # klte-common: Add p2p_no_group_iface=1 to p2p_supplicant_overlay
kpick 225192 # klte-common: Apply android-8.1.0_r43->android-9.0.0_r1 changes to ril.h

# device/samsung/msm8974-common
kpick 224851 # msm8974-common: config.fs: Add 'VENDOR' prefix to AIDs
kpick 224916 # DO NOT MERGE: msm8974-common: Disable our and device/qcom sepolicy
kpick 225249 # msm8974-common: Uprev Wi-Fi HAL to 1.2
kpick 225250 # msm8974-common: Uprev to supplicant 1.1
kpick 225251 # msm8974-common: Add hostapd HIDL interface
kpick 225466 # msm8974-common: libril: Remove LOCAL_CLANG
kpick 225467 # msm8974-common: libril: Fix Const-Correctness for RIL_RadioFunctions
kpick 225468 # msm8974-common: libril: Remove unused code
kpick 225469 # msm8974-common: libril: Fix double freeing of memory in SAP service and add ...
kpick 225470 # msm8974-common: libril: Store the system time when NITZ is received.
kpick 225471 # msm8974-common: libril: Add DISABLE_RILD_OEM_HOOK.
kpick 225472 # msm8974-common: libril: Change rild initial sequence to guarantee non-null ...
kpick 225473 # msm8974-common: libril: Add SIM_ABSENT error

# device/samsung/qcom-common

# kernel/samsung/msm8974

# device/lineage/sepolicy
kpick 224765 # sepol: Remove exfat context
kpick 224766 # sepol: Remove recovery access to vold_socket

# device/qcom/sepolicy
kpick 224767 # sepol: Remove duplicated hal_vehicle attribute
kpick 224768 # sepol: hostapd is now hal_wifi_hostapd

# external/openssh
kpick 224032 # openssh: Update for pie boringssl
kpick 224033 # openssh: don't spam warnings as errors

# external/p7zip
kpick 224028 # p7zip: Cleanup if statement braces, whitespace lines, and ifs without paranthesis)
kpick 224029 # p7zip: don't spam warnings as errors

# external/perfetto
kpick 223413 # perfetto_cmd: Resolve missing O_CREAT mode

# external/tinycompress
kpick 223008 # tinycompress: squash tinycompress fixes
kpick 223009 # tinycompress: Add get_metadata() and set_metadata() API support
kpick 223010 # tinycompress: Generate vendor specifc tinycompress
kpick 223011 # tinycompress: Fix compilation on old targets
kpick 223012 # audio: compress error propagation
kpick 223013 # tinycompress: Move [get,set]_metadata to vendor extension
kpick 223014 # Revert "libtinycompress: Android.mk -> Android.bp"
kpick 223015 # tinycompress: include kernel headers

# external/toybox

# external/zlib
kpick 225237 # zlib: Fix build under Android 6.0 and higher
kpick 225238 # minizip: Clean up the code
kpick 225239 # zlib: crc optimization for arm64

# frameworks/av
kpick 223017 # audiopolicy: make audio policy extensible
kpick 224173 # camera: include: Don't override possible overlayed header
kpick 224174 # nuplayer: Avoid crash when codec fails to load
kpick 224176 # camera: Don't segfault if we get a NULL parameter
kpick 224177 # cameraservice: Resolve message vs start/stop preview races
kpick 224178 # libstagefright: Support YVU420SemiPlanar camera format
kpick 224179 # stagefright: omx: Don't signal dataspace change on legacy QCOM
kpick 224180 # stagefright: ACodec: Resolve empty vendor parameters usage
kpick 224181 # libstagefright: Free buffers on observer died
kpick 224182 # libstagefright: use 64-bit usage for native_window_set_usage
kpick 224183 # camera/media: Support legacy HALv1 camera in mediaserver
kpick 224184 # Camera: check metadata type before releasing frame	
#kpick 224203 # camera: Allow devices to load custom CameraParameter code
kpick 224216 # MTP: Fix crash when no storages are available
kpick 224434 # audiopolicy: allow dp device selection for voice usecases
kpick 224863 # audiopolicy: Add AudioSessionInfo API

# frameworks/base
kpick 222961 # androidfw: Squash of declare and load lineage sdk resource package w/ id
kpick 222962 # Add lineage sdk resource APK to Zygote FD whitelist
kpick 222963 # services: Kick off to LineageSystemServer for external service init.
kpick 222964 # Add Profiles.
kpick 222965 # Allow adjusting progress on touch events.
kpick 222966 # services: Include org.lineageos.platform.internal
kpick 222967 # SystemUI: Add lineage-sdk dep
kpick 224514 # fw/base: Enable home button wake
kpick 224616 # [TEMP] fw/b AssetManager: Load lineage resources
kpick 224801 # [DNM][TEMP] services: Avoid NPE if KeyguardManager is not yet available
kpick 224842 # LockPatternUtils: Make settings getter and setters protected
kpick 224844 # lockscreen: Add option for showing unlock screen directly
kpick 224856 # admin: Restore requireSecureKeyguard interface.
kpick 224857 # Check for null callerPackage in getStorageEncryptionStatus
kpick 224861 # perf: Add plumbing for PerformanceManager
kpick 224862 # perf: Adapt for HIDL Lineage power hal
kpick 224895 # ActivityManager: Restore getRecentTasksForUser method
kpick 224919 # Allow lid to send a generic COVER_CHANGED broadcast
kpick 225425 # SettingsLib: Add LineageParts settings to tile list

# frameworks/opt/telephony
kpick 223774 # telephony: Squashed support for simactivation feature

# hardware/interfaces
kpick 224064 # Revert "Bluetooth: Remove random MAC addresses"
kpick 225506 # Camed HAL extension: Added support in HIDL for Extended FD.
kpick 225507 # camera: Only link and use vendor.qti.hardware.camera.device if specified

# hardware/libhardware
kpick 223096 # audio: Add audio amplifier HAL
kpick 223097 # hardware/libhw: Add display_defs.h to declare custom enums/flags
kpick 223098 # audio_amplifier: add hooks for stream parameter manipulation
kpick 223681 # power: Add new power hints
 
# hardware/libhardware_legacy
kpick 223521 # Wifi: Add Qpower interface to libhardware_legacy

# hardware/lineage/interfaces
kpick 223374 # interfaces: Add 2.0 livedisplay interfaces
kpick 223410 # interfaces: Add touch HIDL interface definitions
kpick 223411 # interfaces: Add id HAL definition
kpick 223906 # biometrics: fingerprint: add locking to default impl
kpick 223907 # Use -Werror in hardware/interfaces/biometrics/fingerprint
kpick 223908 # fpc: keep fpc in system-background
#kpick 224525 # lineage/interfaces: Add basic USB HAL that reports no status change

# hardware/lineage/lineagehw
kpick 224046 # DO NOT MERGE: Use generic classes with Android.bp

# hardware/qcom/audio-caf/msm8974
kpick 223436 # Add -Wno-error to compile with global -Werror.
kpick 224441 # audio: Remove policy hal directory
kpick 225193 # hal: Update prefixes for audio system properties

# hardware/qcom/display-caf/msm8974
kpick 223433 # Use libhwui.so instead of libskia.so
kpick 223434 # Include what we use.
kpick 223435 # Add -Wno-error to compile with global -Werror.

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

# hardware/qcom/media-caf/msm8974
kpick 223441 # Add -Wno-error to compile with global -Werror.

# hardware/qcom/power
kpick 223892 # power: Add power hint to set profile
kpick 223890 # Revert "power: Depend on vendor lineage power HAL"

# hardware/samsung
kpick 223882 # resolve compiling warnings/errors
kpick 223982 # DNM: exclude AdvancedDisplay
kpick 224760 # libril: sync with Pie AOSP libril

# lineage-sdk
kpick 223137 # lineage-sdk: Comment out org_lineageos_platform_internal_LineageAudioService.cpp
kpick 223154 # lineage-sdk: Comment out unbuildable code
kpick 223200 # lineage-sdk: Add isPersisted() to lineage-sdk preferences
kpick 224047 # lineage-sdk: Android.mk -> Android.bp
kpick 224608 # [TEMP] LineageSettingsProvider: Do not access system settings during startup
kpick 224614 # lineage-sdk: Update attr.xml for aapt2

# packages/apps/AudioFX
kpick 224892 # AudioFX: Properly depend on Lineage SDK

# packages/apps/Calender
kpick 225253 # 	Calendar: adaptive icon

# packages/apps/Camera2
kpick 224752 # Use mCameraAgentNg for getting camera info when available
kpick 225254 # Camera2: adaptive icon
kpick 225255 # Camera2: Target API 27
kpick 225256 # Don't attempt to convert degree to orientation enum twice
kpick 225257 # Camera2: Only autofocus before a snap if we are actually in "auto" mode.
kpick 225258 # Camera2: Remove settings preferences only once
kpick 225259 # Camera2: Stop using GPS when going to background
kpick 225260 # Camera: Powerkey shutter (2/2)
kpick 225261 # Camera2: Add option to set max screen brightness
kpick 225262 # Camera2: Remove google help preference
kpick 225263 # Camera2: Fix Undo button behaviour
kpick 225264 # Fix crash if Exif-Tag buffer-length and component-count are both 0
kpick 225265 # 	Add Storage preference (1/2)

# packages/apps/CarrierConfig
kpick 225266 # CarrierConfig: Add selected configs for national roaming
kpick 225267 # CarrierConfig: Load ERI configuration for U.S. Cellular
kpick 225268 # Disable OTA for U.S. Cellular since there is no need for it
kpick 225269 # CarrierConfig: HoT and tele.ring (232 07) may roam on T-Mobile (232 03)

# packages/apps/Contacts
kpick 225270 # Contacts: define app category
kpick 225271 # Contacts: adaptive icon
kpick 225272 # Contacts: Enable support for device contact.
kpick 225273 # Place MyInfo shortcut on drawer
kpick 225274 # Place EmergencyInfo shortcut on drawer
kpick 225275 # Contacts: update splash screen to match the new icon
kpick 225276 # Allow calling contacts via specific phone accounts.

# packages/apps/DeskClock
kpick 225277 # DeskClock : Add set and cancel power off alarm actions
kpick 225278 # DeskClock : Improve the priority of power off alarm broadcast
kpick 225279 # DeskClock : update alarm if it is handled in min framework
kpick 225280 # Make new menu entry to link to cLock widget settings.
kpick 225281 # DeskClock: Add back flip and shake actions
kpick 225282 # DeskClock: Use accelerometer instead of orientation sensor
kpick 225283 # Deskclock: define app category
kpick 225284 # Provide upgrade path for cm-14.1 -> lineage-15.1
kpick 225285 # DeskClock: adaptive icon
kpick 225286 # Revert "Fix alarm not firing in memory-pressure situations"

# packages/apps/DocumentsUI
kpick 225287 # DocumentsUI: define appcategory
kpick 225288 # DocumentsUI: adaptive icon
kpick 225289 # DocumentsUI: support night mode

# packages/apps/Email
kpick 225292 # Email: handle databases from cm-14.1
kpick 225293 # Email: adaptive icon
kpick 225294 # Allow account deletion.
kpick 225295 # email: support for auto-sync multiple IMAP folders
kpick 225296 # email: Add an ActionBar to the mail app's PreferenceActivity
kpick 225297 # email: support per-folder notifications
kpick 225298 # Rewrite MailboxSettings loading logic.
kpick 225299 # email: fix eas autodiscover
kpick 225300 # Implement IMAP push using IMAP IDLE.
kpick 225301 # Request battery optimization exemption if IMAP IDLE is used.
kpick 225302 # Fix crash when attempting to view EML files.
kpick 225303 # Allow download of compressed attachments.
kpick 225304 # email: fix empty body update
kpick 225305 # Improve notification coalescence algorithm.
kpick 225306 # Email: Fix the ActivityNotFoundException when click "Update now"
kpick 225307 # Email: Clean duplicated WRITE_CONTACTS permission
kpick 225308 # email: return default folder name for subfolders
kpick 225309 # email: junk icon
kpick 225310 # Search in folder specified via URI parameter, if possible.
kpick 225311 # Remove max aspect ratio.
kpick 225312 # Update strings for crowdin

# packages/apps/FlipFlap

# packages/apps/LineageParts
kpick 223153 # LineageParts: Comment out unbuildable code

# packages/apps/Nfc
kpick 223706 # NFC: Restore legacy NXP stack
kpick 223707 # nxp: jni: Forward-port the stack sources
kpick 223697 # nxp: NativeNfcManager: Implement missing inherited abstract methods
kpick 223698 # nxp: jni: use proper nativehelper headers
kpick 223699 # nxp: jni: Remove unused variables and functions
kpick 223700 # NFC: Adding new vendor specific interface to NFC Service
kpick 223701 # NFC: Clean duplicated and unknown permissions
kpick 223703 # nxp: jni: Implement AOSP P abstract methods

# packages/apps/Recorder
kpick 223673 # Recorder: Upgrade to AOSP P common libraries and AAPT2	
kpick 223674 # Recorder: Request FOREGROUND_SERVICE permission

# packages/apps/SetupWizard

# packages/apps/Stk
kpick 225342 # Stk: adaptive icon

# packages/apps/UnifiedEmail
kpick 225343 # unified email: prefer account display name to sender name
kpick 225344 # email: fix back button
kpick 225345 # unified-email: check notification support prior to create notification objects
kpick 225346 # unified-email: respect swipe user setting
kpick 225347 # email: linkify urls in plain text emails
kpick 225348 # email: do not close the input attachment buffer in Conversion#parseBodyFields
kpick 225349 # email: linkify phone numbers
kpick 225350 # Remove obsolete theme.
kpick 225351 # Don't assume that a string isn't empty
kpick 225352 # Add an ActionBar to the mail app's PreferenceActivity.
kpick 225353 # email: allow move/copy operations to more system folders
kpick 225354 # unifiedemail: junk icon
kpick 225355 # Remove mail signatures from notification text.
kpick 225356 # MimeUtility: ensure streams are always closed
kpick 225357 # Fix cut off notification sounds.
kpick 225358 # Pass selected folder to message search.
kpick 225359 # Properly close body InputStreams.
kpick 225360 # Make navigation drawer extend over status bar.
kpick 225361 # Disable animations for translucent activities.
kpick 225362 # Don't re-show search bar on query click.

# packages/apps/WallpaperPicker
kpick 225363 # WallpaperPicker: bump gradle
kpick 225364 # WallpaperPicker: add adaptive icon
kpick 225365 # WallpaperPicker: materialize delete icon
kpick 225367 # WallpaperPicker: Update for wallpaper API changes
kpick 225370 # WallpaperPicker: add a "No Wallpaper" option
kpick 225371 # WallpaperPicker: Move strings for translation
kpick 225372 # WallpaperPicker: 15.1 wallpapers

# packages/inputmethods/LatinIME
kpick -t pie-keyboard

# packages/providers/BlockedNumberProvider
kpick 225403 # # packages/providers/BlockedNumberProvider

# packages/providers/BookmarkProvider
kpick 225404 # BookmarkProvider: adaptive icon

# packages/providers/CalendarProvider
kpick 225405 # CalendarProvider: adaptive icon

# packages/providers/CallLogProvider
kpick 225406 # CallLogBackup: adaptive icon

# packages/provider/ContackProvider
kpick 225407 # ContactsProvider: adaptive icon
kpick 225408 # ContactsProvider: Prevent device contact being deleted.
kpick 225409 # CallLogDatabase: Bump the version and try to re-run the version 5 upgrade path

# packages/providers/DownloadProvider
kpick 225410 # DownloadProvider: Display download speed in notification
kpick 225411 # DownloadProvider: Add support for manual pause/resume

# packages/providers/MediaProvider
kpick 225412 # Fix mounting of non-FAT formatted SD cards (2/2)
kpick 225413 # MediaProvider: adaptive-icon

# packages/providers/TelephonyProvider
kpick 225414 # 	TelephonyProvider: adaptive icon

# packages/services/Mms
kpick 225416 # Mms: adaptive icon

# packages/services/Telecomm
kpick 223099 # Telecomm: Squashed phone_type switch support
kpick 225417 # Telecomm: adaptive icon

# packages/services/Telephony
kpick 225419 # Telephony: adaptive icon
kpick 225420 # Use proper summary for network select list preference on dsds/dsda/tsts

# packages/wallpapers/LivePicker
kpick 225421 # LivePicker: adaptive icon

# system/bt
kpick 223945 # Prevent abort in case of command timeout
kpick 224813 # bt: osi: undef PROPERTY_VALUE_MAX
kpick 225422 # Bluetooth: Read BLE vendor capability to proceed on Secure conn
kpick 225423 # Add support to force disable enhanced sco commands

# system/core
kpick 223085 # adbd: Disable "adb root" by system property (2/3)
kpick 223147 # init: don't skip starting a service with no domain if permissive
kpick 224264 # debuggerd: Resolve tombstoned missing O_CREAT mode

# system/extra
kpick 225426 # f2fs_utils: Add a static libf2fs_sparseblock for minvold
kpick 225427 # ext4_utils: Fix FS creation for filesystems with exactly 32768 blocks.
kpick 225428 # extras: remove su

# system/sepolicy
kpick 223745 # Allow e2fs to format cache
kpick 223746 # Add rules required for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 223748 # Build sepolicy tools with Android.bp.
kpick 224808 # sepolicy: We need to declare before referencing
kpick 224809 # sepolicy: Allow su by apps on userdebug_or_eng
kpick 224810 # sepolicy: update policies for sudaemon on O
kpick 224811 # sepolicy: add sudaemon to ignore list
kpick 224812 # sepolicy: Allow recovery to write to rootfs

# system/tool/aidl
kpick 223133 # AIDL: Add option to generate No-Op methods

# system/update/engine
kpick 225430 # update_engine: run backuptool script before normal postinstall script
kpick 225431 # update_engine: Add performance mode

# system/vold
kpick 225436 # vold: add support for more filesystems for public storage
kpick 225437 # vold: Fix fsck on public volumes
kpick 225438 # vold: Support internal storage partitions
kpick 225439 # vold: Honor mount options for ext4 partitions
kpick 225440 # vold: Honor mount options for f2fs partitions
kpick 225441 # vold: Mount ext4/f2fs portable storage with sdcard_posix
kpick 225442 # vold: ntfs: Use strlcat
kpick 225443 # Treat removable UFS card as SD card
kpick 225444 # vold: dont't use commas in device names
kpick 225445 # vold ext4/f2fs: do not use dirsync if we're mounting adopted storage
kpick 225446 # Fix the group permissions of the sdcard root.
kpick 225447 # vold: skip first disk change when converting MBR to GPT
kpick 225448 # vold: Allow reset after shutdown
kpick 225449 # vold: Accept Linux GPT partitions on external SD cards
kpick 225450 # vold: Make sure block device exists before formatting it
kpick 225451 # vold: Also wait for dm device when mounting private volume
kpick 225452 # secdiscard: should pin_file to avoid moving blocks in F2FS

# vendor/lineage
kpick 224511 # config/common: Clean up debug packages
kpick 223980 # lineage: Exclude all lineage overlays from RRO
kpick 224421 # overlay: Default materials buttons to not all caps
kpick 224021 # overlay: Fix status bar padding for all devices
kpick 224893 # overlay: Remove deprecated overlay
kpick 224649 # overlay: Enable rounded corners for dialogues and buttons
kpick 224759 # lineage: Ignore neverallows
kpick 224828 # vendor/lineage: Add support for java source overlays
kpick 225495 # config: Use standard inherit-product-if-exists for vendor/extra

# vendor/qcom/opensource/audio
kpick 224975 # [TMP] Align with AOSP

#-----------------------
# translations

##################################
echo
echo "---------------------------------------------------------------"
read -n1 -r -p "  Picking remote changes finished, Press any key to continue..." key

[ $op_pick_remote_only -eq 0 ] && patch_local local
[ -f $script_file.tmp ] && mv $script_file.tmp $script_file.new
[ -f $topdir/.mypatches/rr-cache/rr-cache.tmp ] && \
   mv $topdir/.mypatches/rr-cache/rr-cache.tmp $topdir/.mypatches/rr-cache/rr-cache.list
rrCache backup # backup rr-cache

