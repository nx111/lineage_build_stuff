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
    local m_parent=1
    local nops=""
    for op in $*; do
        if [ $op_is_m_parent -eq 1 ]; then
             [[ $op =~ ^[0-9]+$ ]] && [ $op -lt 10 ] && m_parent=$op
             op_is_m_parent=0
             continue
        fi
        [ "$op" = "-m" ] && op_is_m_parent=1 && continue
        [ -z "$changeNumber" ] && [[ $op =~ ^[0-9]+$ ]] && [ $op -gt 1000 ] && changeNumber=$op
        [ "$op" = "-f" ] && op_force_pick=1
        nops="$nops $op"
    done
    if  [ "$changeNumber" = "" ]; then
         echo ">>> Picking $nops ..."
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
        if [ -f $logfile -a "$script_file" != "bash" ] && grep -q -E "Change status is MERGED.|nothing to commit" $logfile; then
           [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
           eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
        elif [ -f $logfile ] && grep -q -E "Change status is ABANDONED." $logfile; then
           [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
           eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
        elif [ -f $logfile ] && grep -q -E "Change $changeNumber not found, skipping" $logfile; then
           [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
           eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
        elif [ -f $errfile ] && grep -q "could not determine the project path for" $errfile; then
           [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
           eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
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
repo sync android
cd .repo/manifests;
git fetch --all >/dev/null
git reset --hard $(git branch -a | grep "/m/" | cut -d'>' -f 2 | sed -e "s/ //g") >/dev/null
cd $topdir

kpick 213705 # 	Build Exchange
#android_head=$(cd android;git log -n 1 | sed -n 1p | cut -d' ' -f2;cd $topdir)
#repo sync
#cd android;git reset --hard $android_head >/dev/null;cd $topdir
repo sync packages/apps/Exchange

# bionic
kpick 217311 # linker: add support for odm partition
kpick 217312 # libc: add /odm/bin to the DEFPATH
kpick 221709 # libc: Add generated copyrights

# bootable/recovery
kpick 219194 # minui: drm: ARGB8888 support
kpick 219195 # minui: drm: wait for page flip event before next flip	
kpick 222457 # backup: Fix compiler warnings

# build/make
kpick 208381 # build: Add ability for device to specify additional targets
kpick 208567 # [DNM] updater: Don't check fingerprint for incrementals
kpick 209023 # build: Add script to generate extra images
kpick 209024 # Generate extra userdata partition if needed
kpick 209025 # Strip out unused extra image generation
kpick 210238 # releasetools: Store the build.prop file in the OTA zip
kpick 212820 # build: Implement prebuilt caching
kpick 213515 # build: Use minimial compression when zipping targetfiles
kpick 213572 # Allow to exclude imgs from target-files zip
kpick 218985 # releasetools: Fix the rebuilding of vbmeta.img.
kpick 218986 # releasetools: Allow building AVB-enabled recovery.img.
kpick 218987 # Reorder assert-max-image-size and AVB signing
kpick 218988 # AVB: If building recovery.img, add AVB hash footer.
kpick 218989 # releasetools: Fix the size check for AVB images.
kpick 218990 # releasetools: Always create IMAGES/ directory.
kpick 218991 # releasetools: Move the AVB salt setup into common.LoadInfoDict().
kpick 219020 # build: Disable backuptool for A/B on -user
kpick 222016 # releasetools: Add system-as-root handling for non-A/B backuptool
kpick 222017 # core: Add bootimage only cmdline flag

# build/soong
kpick 223432 # soong: Enforce absolute path if OUT_DIR is set

# device/lineage/sepolicy
kpick 219022 # sepolicy: Fix neverallow for user builds

# device/qcom/sepolicy
kpick 211273 # qcom/sepol: Fix timeservice app context

# device/samsung/klte-common
#kpick 212648 # klte-common: Enable AOD
kpick 220435 # Add HFR/HSR support

# device/samsung/kltechnduo

# device/samsung/msm8974-common
kpick 210313 # msm8974-common: Binderize them all

# kernel/samsung/msm8974
kpick 210665 # wacom: Follow-up from gestures patch
kpick 210666 # wacom: Report touch when pen button is pressed if gestures are off
#kpick 221437 # msm: ADSPRPC: Use ID in response to get context pointer

# external/ant-wireless/ant_native

# external/chromium-webview

# external/f2fs-tools

# external/tinecompress
kpick 215115 # tinycompress: Replace deprecated kernel header path

# external/toybox
kpick 209019 # toybox: Use ISO C/clang compatible __typeof__ in minof/maxof macros

# frameworks/av
kpick 206069 # stagefright: add changes related to high-framerates in CameraSource
kpick 209904 # Camera2Client: Add support for QTI parameters in Camera2Client
kpick 209905 # Camera2Client: Add support for QTI specific ZSL feature
kpick 209906 # Camera2Client: Add support for QTI specific AE bracketing feature
kpick 209907 # Camera2Client: Add support for QTI specific HFR feature
kpick 209908 # Camera2Client: Add support for non-HDR frame along with HDR
kpick 209909 # Camera2Client: Add support for enabling QTI DIS feature
kpick 209910 # Camera2Client: Add support for enabling QTI Video/Sensor HDR feature
kpick 209911 # Camera2Client: Add support for QTI specific AutoHDR and Histogram feature
kpick 209912 # Camera: Skip stream size check for whitelisted apps
kpick 213115 # camera: Disable extra HDR frame on QCOM_HARDWARE
kpick 220018 # Camera2Client: Add support for Raw snapshot in Camera2Client
kpick 220019 # Camera2Client: Integrate O-MR1 changes for QTI camera2client
kpick 220020 # Camera2Client: Disable ZSL by default in QTI camera2client
kpick 220021 # Camera: Skip stream size check for whitelisted apps.
kpick 220022 # Camera2Client: Use Max YUV Resolution instead of active array size.
kpick 220023 # Camera2Client: Fix issue with supported scene modes.
kpick 220024 # Camera2Client: Update vendor tag only if it is present
kpick 220025 # Camera2Client: Fix issue with AE Bracketing mode.
kpick 223145 # av: camera: Allow disabling shutter sound for specific packages

# frameworks/base
kpick -f 206054 # SystemUI: use vector drawables for navbar icons
kpick -f 206055 # SystemUI: Add a reversed version of OPA layout
kpick -f 206056 # opalayout: Actually implement setDarkIntensity
kpick -f 206057 # opapayout: Update for r23 smaller navbar
kpick -f 206058 # opalayout/home: Fix icons and darkintensity
kpick -f 206059 # OpaLayout: misc code fixes
kpick 206568 # base: audioservice: Set BT_SCO status
kpick 207583 # BatteryService: Add support for oem fast charger detection
kpick 209031 # TelephonyManager: Prevent NPE when registering phone state listener
kpick 206940 # Avoid crash when the actionbar is disabled in settings
kpick 214262 # Bind app name to menu row when notification updated
kpick 214263 # Fix intercepting touch events for guts
kpick 214265 # Better QS detail clip animation
kpick 215031 # Keyguard: Fix ConcurrentModificationException in KeyguardUpdateMonitor
kpick 215128 # Make the startup of SoundTrigger service conditional
kpick 216872 # SystemUI: Fix systemui crash when showing data usage detail
kpick 217594 # Fingerprint: Speed up wake-and-unlock scenario
kpick 217595 # display: Don't animate screen brightness when turning the screen on
kpick 218317 # SystemUI: Remove duplicate permission
kpick 218359 # Revert "SystemUI: disable wallpaper-based tint for scrim"
kpick 218430 # SystemUI: Require unlock to toggle airplane mode
kpick 218431 # SystemUI: Require unlock to toggle location
kpick 218437 # SystemUI: Add activity alias for LockscreenFragment
kpick 219930 # Telephony: Stop using rssnr, it falsly shows wrong signal bars Pixel and other devices drop this
kpick 221518 # 	[1/2] base: allow disable of screenshot shutter sound
kpick 221557 # Make volume steps adjustable for the alarm and ringtone streams
kpick 221654 # 	Disable restrictions on swipe to dismiss and action bars
kpick 221716 # Where's my circle battery, dude?
kpick 221805 # System Profiles in QS Tiles
kpick 222226 # [1/3] SystemUI: add burnIn protection setting
kpick 222305 # SettingsLib: add action callbacks to CustomDialogPreferences
kpick 222474 # Tiles: SystemProfiles: Adapt behaviour
kpick 222475 # LocationTile: Replace deprecated MetricsLogger calls
kpick 222511 # SystemUI: Fix inconsistent disabled state tile color
kpick 223332 # Animation and style adjustments to make UI stutter go away
kpick 223333 # Set windowElevation to 0 on watch dialogs.
kpick 223334 # Update device default colors for darker UI
kpick 224392 # VibratorService: Apply vibrator intensity setting.
kpick 224757 # webkit: Add AOSP WebView provider by default

# frameworks/native
kpick 213549 # SurfaceFlinger: Support get/set ActiveConfigs

# frameworks/opt/chips

# frameworks/opt/net/wifi

# frameworks/opt/telephony
kpick 214316 # RIL: Allow overriding RadioResponse and RadioIndication
kpick 215450 # Add changes for sending ATEL UI Ready to RIL.
kpick 219860 # Clean up Icc Refresh handling
kpick 219861 # Fix SIM refresh issue
kpick 220429 # telephony: Allow overriding getRadioProxy

# hardware/broadcom/libbt

# hardware/broadcom/wlan

# hardware/interfaces
kpick 206140 # gps.default.so: fix crash on access to unset AGpsRilCallbacks::request_refloc
kpick 224430 # fpc: keep fpc in system-background

# hardware/lineage/interfaces
kpick 219211 # livedisplay: Move HIDL service to late_start
kpick 219885 # livedisplay: Add a system variant
kpick 220840 # livedisplay: Enable cabl via mm-pp-daemon.
kpick 220841 # livedisplay: Query active state via native call.
kpick 221642 # interfaces: Add vendor.lineage.stache@1.0::ISecureStorage
kpick 221643 # interfaces: Do not add custom interfaces to VNDK
kpick 221644 # stache: Add default ext4 crypto implementation
kpick 223909 # biometrics: fingerprint: add locking to default impl
kpick 224208 # camera: 1.0-legacy: Build with BOARD_VNDK_VERSION=current

# hardware/lineage/lineagehw
kpick 222510 # Remove deprecated VibratorHW

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

# hardware/qcom/media-caf/msm8974

# hardware/qcom/keymaster

# hardware/qcom/power

# hardware/qcom/thermal
kpick 218360 # thermal: use log/log.h header

# haedware/qcom/vr

# hardware/qcom/wlan-caf

# hardware/samsung
kpick 218823 # audio: Add flag to opt in/out amplifier support
kpick 220853 # dtbhtool: Add new DTBH_MODEL entry

# lineage/charter
kpick 213574 # charter: Add some new USB rules
kpick 213836 # charter: add vendor patch level requirement 
kpick 215665 # Add hardware codecs section and exempt some tegra chipsets
kpick 218728 # charter: Add recovery requirement
kpick 218835 # verity: change wording, as this is required for a/b builds

# lineage/jenkins

# lineage/scripts
kpick 207545 # Add batch gerrit script

# lineage/website(LineageOS/www)

# lineage/wiki
kpick 219164 # Introduce a supported versions column in device tables
kpick 219543 # wiki: add workaround for booting into TWRP recovery

# lineage-sdk
kpick 213367 # NetworkTraffic: Include tethering traffic statistics
kpick 214854 # [3/3] lineagesdk: single hand for hw keys
kpick 216978 # sdk: add torch accent
#kpick 218679 # lineage-sdk: Use ILight.getSupportedTypes for lights capabilities
kpick 220407 # lineagesdk: Refactor battery icon options
kpick 220417 # TelephonyExtUtils: Add possible error codes, and return with them
kpick 222035 # sdk: Add migration for /missing/ custom button actions
kpick 222512 # Fix inconsistent disabled state color for LiveDisplay tile
kpick 222513 # Remove deprecated VibratorHW
kpick 223458 # Regen lineage_current

# lineage-sdk/samples/weatherproviderservice/YahooWeatherProvider
kpick 207864 # Updated Gradle to 3.0.1; The Lineage-SDK jar is now contained in the project files

# packages/apps/AudioFX

# packages/apps/Bluetooth
kpick 218319 # Bluetooth: Remove duplicate permission

# packages/apps/Camera2

# packages/apps/Contacts

# packages/apps/Dialer
kpick 211135 # Show proper call duration
#kpick 222240 # Dialer: add to support multi-language smart search

# packages/apps/DeskClock
#kpick 213051 # Deskclock: set targetSdk to 27
kpick 222493 # Overlay layouts for round-watch

# packages/apps/Eleven
kpick 221891 # Eleven: bump to api26

# packages/apps/Email

# packages/apps/Exchange
kpick 211382 # Exchange: request permissions
kpick 221488 # Failure in testAllSystemAppsUsingRuntimePermissionsTargetMncAndAboveSdk	
kpick 221489 # Automatic translation import

# packages/apps/Flipflap

# packages/apps/Gallery2
kpick 222465 # Gallery2: Fix wrong string for empty albums

# packages/apps/Jelly

# packages/apps/LineageParts
kpick 217171 # Trust: enforce vendor security patch level check
kpick 217642 # Align learn more and got it horizontally
kpick 217644 # LineageParts: Set proper PreferenceTheme parent	
kpick 218315 # LineageParts: Fix brightness section
kpick 219527 # LiveDisplay: Remove advanced settings category if empty
kpick 220533 # Trust: String changes for accuracy of language
kpick 220422 # LineageParts: Bring back and refactor battery icon options
kpick 221359 # Remove actionbar calls
kpick 221756 # StatusBarSettings: Hide battery preference category based on icon visibility
kpick 222323 # LineageParts: (Not-so-)Small cleanup
kpick 222572 # Remove icons and center layouts

# packages/apps/lockClock
kpick 208127 # Update LockClock to use Job APIs 

# packages/apps/Nfc

# packages/apps/Recoder

# packages/apps/Settings
#kpick 209583 # [2/2] Settings: battery styles
kpick 215672 # SimSettings: Fix dialog in dark mode
kpick 216687 # settings: wifi: Default to numeric keyboard for static IP items
kpick 216822 # Settings: Allow setting device phone number
kpick 216871 # Utils: Always show SIM Settings menu
kpick 216909 # Settings: Apply accent color to on-body detection icon
kpick 218438 # Settings: Add lockscreen shortcuts customization to lockscreen settings
kpick 218775 # Settings: Cleanup SimSettings additions
kpick 219299 # Settings: Remove battery percentage switch
kpick 221519 # [2/2] Settings: allow disable of screenshot shutter sound
kpick 221840 # Fixed translation
#kpick 222227 # [2/3] Settings: add burnIn protection setting
#kpick 222306 # Settings: add HIDL vibration intensity preference

# packages/apps/SetupWizard
kpick 217580 # Add original-package to AndroidManifest

# packages/apps/Snap
kpick 206595 # Use transparent navigation bar
kpick 218826 # CameraSettings:Do not crash if zoom ratios are not exposed.
kpick 222005 # Snap: Add Denoise to video menu

# packages/apps/Trebuchet
kpick 214336 # Trebuchet: initial protected apps implementation

# packages/apps/UnifiedEmail

# packages/apps/Updater
kpick 219924 # Updater: Allow to suspend A/B updates
kpick 220536 # Updater: Clarify A/B Performance mode string
kpick 221499 # Updater: Use SharedPreference listener to get perf mode setting

# packages/overlays/Lineage
kpick 215846 # dark: Add Theme.DeviceDefault.Settings.Dialog.NoActionBar style
kpick 216979 # overlays: add torch accent

# packages/providers/ContactsProvider

# packages/providers/DownloadProvider
kpick 222467 # Fix plural translatability for download speed

# packages/resources/devicesettings

# pakcages/service/Telecomm

# packages/service/Telephony
kpick 209045 # Telephony: Fallback gracefully for emergency calls if suitable app isn't found

# system/bt

# system/core
kpick 206029 # init: Add command to disable verity
kpick 213876 # healthd: charger: Add tricolor led to indicate battery capacity
kpick 215626 # Add vendor hook to handle_control_message
kpick 217313 # add odm partition to ld.config.legacy
kpick 217314 # Allow firmware loading from ODM partition
kpick 218837 # libsuspend: Add property support for timeout of autosuspend
kpick 219304 # init: Allow devices to opt-out of fsck'ing on power off
kpick 221647 # healthd: BatteryMonitor: Fix compiler warning
kpick 222237 # Add back atomic symbols

# system/extras
kpick 211210 # ext4: Add /data/stache/ to encryption exclusion list

# system/extras/su

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
kpick 209189 # vold: Conditionally remove secdiscard command
kpick 218416 # vold: utils: Introduce ForkCallp

# vendor/lineage
kpick 206154 # Include build manifest on target
kpick 210664 # extract_utils: Support multidex
kpick 216977 # lineage: build torch accent
kpick 217527 # tools: Rewrite sdat2img
kpick 217528 # sdat2img: Add support for brotli compressed files
kpick 217628 # lineage: add generic x86_64 target
kpick 217629 # kernel: Add TARGET_KERNEL_ADDITIONAL_FLAGS to allow setting extra cflags
kpick 217630 # kernel: Add kernelversion recipe to generate MAJOR.MINOR kernel version
kpick 218717 # verity_tool: Implement status getter
kpick 218801 # libbfqio: Open bfqio once
kpick 218817 # kernel: Do not attempt to build modules if there aren't
kpick 218832 # lineage: Add prebuilt patchelf binaries and patch_blob function
kpick 219388 # config: Add more GMS client base ID props
kpick 219389 # lineage: Always disable google SystemUpdateService
kpick 220398 # extract_utils: Skip unneeded md5sum	
kpick 220399 # extract_utils: Extract files from brotli compressed images
kpick 221505 # config/common: Clean up debug packages
#kpick 222564 # extract-utils: initial support for brotli packaged images.
kpick 222612 # build: Update vdexExtractor

# vendor/nxp/opensource/packages/apps/Nfc

# vendor/nxp/opensource/external/libnfc-nci

# vendor/qcom/opensource/cryptfs_hw

#-----------------------
# translations

kpick 224535-224566

##################################
echo
echo "---------------------------------------------------------------"
read -n1 -r -p "  Picking remote changes finished, Press any key to continue..." key

[ $op_pick_remote_only -eq 0 ] && patch_local local
[ -f $script_file.tmp ] && mv $script_file.tmp $script_file.new
[ -f $topdir/.mypatches/rr-cache/rr-cache.tmp ] && \
   mv $topdir/.mypatches/rr-cache/rr-cache.tmp $topdir/.mypatches/rr-cache/rr-cache.list
rrCache backup # backup rr-cache

