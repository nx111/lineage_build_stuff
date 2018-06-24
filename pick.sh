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
         if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
             echo "    skipping: $f"
             continue
         fi
         project=$(echo $f |  sed -e "s/^pick\///" -e "s/^local\///"  | sed "s/\/[^\/]*$//")
         [ -d "$topdir/$project" ] || continue
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo "==== try apply to $project: "
                  #rm -rf .git/rebase-apply
             fi
             ext=${patchfile##*.}
             #rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                       echo "    patching: $f ..."
                       git am -3 -q < $topdir/.mypatches/$f
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
                           if [ "${patch_file_name:5:5}" != "[WIP]" -a "${patch_file_name:5:6}" != "[SKIP]" -a "${patch_file_name:5:8}" != "[ALWAYS]" ]; then
                               rm -f $patchfile
                               mv $pick_patch $topdir/.mypatches/local/$project/
                           else
                               [ "${patch_file_name:5:5}" = "[WIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:5}-${pick_patch_name:5}
                               [ "${patch_file_name:5:6}" = "[SKIP]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:6}-${pick_patch_name:5}
                               [ "${patch_file_name:5:8}" = "[ALWAYS]" ] && rm -f $patchfile && \
                                      mv $pick_patch $(dirname $patchfile)/${pick_patch_name:0:4}-${patch_file_name:5:8}-${pick_patch_name:5}
                           fi
                       elif [ "${patch_file_name:5:5}" != "[WIP]" -a "${patch_file_name:5:6}" != "[SKIP]" -a "${patch_file_name:5:8}" != "[ALWAYS]" ]; then
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

         cd $topdir/$project || resync_project $project;cd $topdir/$project

         echo ">>>  restore project: $project ... "
         git stash -q || resync_project $project;cd $topdir/$project
         git clean -xdf
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
             patchfile=$(basename $f)
             if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
                  echo "         skipping: $f"
                  continue
             fi
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                      echo "         apply patch: $f ..."
                      git am -3 -q < $topdir/.mypatches/$f
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
        find $topdir/$project/.git/rr-cache/ -mindepth 2 -maxdepth 2 -type f -name "postimage*" > $rrtmp
        [ -f "$rrtmp" ] && while read rrf; do
            md5num=$(md5sum $rrf|cut -d' ' -f1)
            #echo "$key ?= $md5num   ----->  $rrf"
            if [ "$key" = "$md5num" ]; then
               rrid=$(basename $(dirname $rrf))
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
    logfile=/tmp/__repopick_tmp.log
    errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")

    rm -f $errfile
    echo ""
    for op in $*; do
        if [[ $op =~ ^[0-9]+$ ]]; then
            changeNumber=$op
            break
        fi
    done
    if  [ "$changeNumber" = "" ]; then
         echo ">>> Picking $* ..."
         repopick $* || exit -1
    fi

    echo ">>> Picking change $changeNumber ..."
    LANG=en_US repopick -c 50 $* >$logfile 2>$errfile
    rc=$?
    fix_repopick_output $logfile
    cat $logfile | sed -e "/ERROR: git command failed/d"
    local tries=0
    local breakout=0
    while [ $rc -ne 0 -a -f $errfile ];  do
          echo ".... try "$(expr $tries + 1)"..."
          #cat  $errfile
          if [ $tries -ge 30 ]; then
                echo "    >> pick faild !!!!!"
                breakout=-1
                break
          fi

          grep -q -E "nothing to commit|allow-empty" $errfile && breakout=1 && break

          if grep -q -E "error EOF occurred|httplib\.BadStatusLine|Connection refused" $errfile; then
              echo "  >> pick was interrupted, retry ("$(expr $tries + 1)")..."
              #cat $logfile | sed -e "/ERROR: git command failed/d"
              #cat $errfile
              echo ""
              sleep 2
              [ $tries -ge 2 ] && https_proxy=""
              LANG=en_US https_proxy="$https_proxy" repopick -c 50 $* >$logfile 2>$errfile
              rc=$?
              if [ $rc -ne 0 ]; then
                  #cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              else
                  fix_repopick_output $logfile
                  cat $logfile
                  breakout=0
                  break
              fi
          fi
          if grep -q "conflicts" $errfile; then
              echo "!!!!!!!!!!!!!"
              cat $errfile
              project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
              md5file=/tmp/$(echo $project | sed -e "s:/:_:g")_rrmd5.txt
              rm -rf $md5file
              if [ "$project" != "" -a -d $topdir/$project ]; then
                    touch $md5file
                    if grep -q "using previous resolution" $errfile; then
                       echo "------------"
                       cd $project
                       grep "using previous resolution" $errfile | sed -e "s/Resolved '\(.*\)' using previous resolution.*/\1/" \
                           | xargs md5sum | sed -e "s/\(.*\)/\1 postimage/" >>$md5file
                       grep "using previous resolution" $errfile | sed -e "s/Resolved '\(.*\)' using previous resolution.*/\1/" \
                           | xargs git add -f
                       if git cherry-pick --continue; then
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
                       cd $project
                       grep "Recorded preimage for" $errfile | cut -d\' -f2 | xargs md5sum | sed -e "s/\(.*\)/\1 preimage/" >>$md5file
                       cd $topdir
                    fi
              fi
              echo  "  >> pick changes conflict, please resolv it, then press ENTER to continue, or press 's' skip it ..."
              ch=$(sed q </dev/tty)
              if [ "$ch" = "s" ]; then
                    curdir=$(pwd)
                    echo "skip it ..."
                    cd $topdir/$project
                    git cherry-pick --abort
                    cd $curdir
                    break
              fi
              echo ""
              LANG=en_US repopick -c 50 $* >$logfile 2>$errfile
              rc=$?
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
          [ -f $errfile ] && cat $errfile
          echo "  >>**** repopick failed !"
          breakout=-1
          break
    done
    if [ $breakout -lt 0 ]; then
        [ -f $errfile ] && cat $errfile
        rm -f $errfile
        exit $breakouit
    else
        project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
        ref=$(grep "\['git fetch" $logfile | cut -d, -f2 | cut -d\' -f2)
        if [ "$project" = "android" ]; then
             url=$(cat $topdir/$project/.git/config | grep "url" | cut -d= -f2 | sed -e "s/ //g")
             cd $topdir/.repo/manifests
             git fetch $url $ref >/dev/null 2>/dev/null && git cherry-pick FETCH_HEAD >/dev/null 2>/dev/null
             cd $topdir
        fi
        if grep -q -E "Change status is MERGED." $logfile; then
           [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
           eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
        elif grep -q -E "Change status is ABANDONED." $logfile; then
           [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
           eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
        elif grep -q -E "Change $changeNumber not found, skipping" $logfile; then
           [ -f $script_file.tmp ] || cp $script_file $script_file.tmp
           eval  sed -e \"/[[:space:]]*kpick $changeNumber[[:space:]]*.*/d\" -i $script_file.tmp
        fi
    fi
}

########## main ###################

get_defaul_remote

for op in $*; do
    if [ "$op" = "-pl" -o "$op" = "--patch_local" ]; then
         op_patch_local=1
    elif [ "$op" = "--reset" -o "$op" = "-r" ]; then
         op_reset_projects=1
    elif [ "$op" = "--snap" -o "$op" = "-s" ]; then
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
   [ $op_pick_remote_only -eq 0 ] && exit 0
fi

###############################################################
# patch repopick first
topdir=$(gettop)

rrCache restore # restore rr-cache

find $topdir/.mypatches/local/vendor/lineage/ -type f -name "*-\[ALWAYS\]-*.patch" -o -name "*-\[ALWAYS\]-*.diff" \
  | while read f; do
     cd $topdir/vendor/lineage;
     if ! git am -3 -q < $f; then
        exit -1
     fi
done

# android
kpick 213705 # 	Build Exchange
repo sync --force-sync packages/apps/Exchange

# bionic
kpick 212920 # libc: Mark libstdc++ as vendor available
kpick 217311 # linker: add support for odm partition
kpick 217312 # libc: add /odm/bin to the DEFPATH
kpick 218402 # linker: Ensure active matching pairs
kpick 218403 # linker: Don't involve shim in for_each_dt_needed

# bootable/recovery
#kpick 217627 # recovery: Do not show emulated when data is encrypted

# build/make
kpick 208102 # Adapt ijar for WSL
kpick 208567 # [DNM] updater: Don't check fingerprint for incrementals
kpick 213515 # build: Use minimial compression when zipping targetfiles
kpick 213572 # Allow to exclude imgs from target-files zip
kpick 214842 # dex2oat: disable multithreading
kpick 214883 # core: config: Use host ijar if requested
kpick 214892 # Add detection for WSL

# build/soong

# device/lineage/sepolicy

# device/qcom/sepolicy
kpick 211273 # qcom/sepol: Fix timeservice app context
kpick 212643 # qcom/sepol: Allow mm-qcamerad to use binder even in vendor

# device/samsung/klte-common
#kpick 212648 # klte-common: Enable AOD
kpick 218432 # klte-common: Define Vendor security patch level
kpick 218434 # klte-common: Reorder tetherable connection types

# device/samsung/kltechnduo

# device/samsung/msm8974-common
kpick 210313 # msm8974-common: Binderize them all

# kernel/samsung/msm8974
kpick 210665 # wacom: Follow-up from gestures patch
kpick 210666 # wacom: Report touch when pen button is pressed if gestures are off

# external/chromium-webview

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
#kpick 215693 # stagefright: Add support for loading a custom OMXPlugin

# frameworks/base
kpick 206568 # base: audioservice: Set BT_SCO status
kpick 207583 # BatteryService: Add support for oem fast charger detection
kpick 209031 # TelephonyManager: Prevent NPE when registering phone state listener
kpick 206940 # Avoid crash when the actionbar is disabled in settings
kpick 214262 # Bind app name to menu row when notification updated
kpick 214263 # Fix intercepting touch events for guts
kpick 214265 # Better QS detail clip animation
kpick 215031 # Keyguard: Fix ConcurrentModificationException in KeyguardUpdateMonitor
kpick 215128 # Make the startup of SoundTrigger service conditional
kpick 216417 # SignalClusterView: Hide signal icons for disabled SIMs
kpick 216854 # Keyguard: Remove carrier text for disabled SIMs
kpick 216872 # SystemUI: Fix systemui crash when showing data usage detail
kpick 217039 # Make berry overlays selection more generic	
kpick 217042 # Add support for black berry style
kpick 217594 # Fingerprint: Speed up wake-and-unlock scenario
kpick 217595 # display: Don't animate screen brightness when turning the screen on
kpick 217952 # SystemUI: Resolve status bar VPN icon tints
kpick 217953 # SystemUI: Resolve status bar battery percentage tints
kpick 218166 # Add an option to change the device hostname (1/2).
kpick 218317 # SystemUI: Remove duplicate permission
kpick 218359 # Add tip to compile Heimdall from source.
kpick 218427 # SystemUI: CellularTile: Don't call showDetail() when device is locked
kpick 218430 # SystemUI: Require unlock to toggle airplane mode

# frameworks/native
kpick 213549 # SurfaceFlinger: Support get/set ActiveConfigs

# frameworks/opt/chips

# frameworks/opt/net/wifi

# frameworks/opt/telephony
kpick 214316 # RIL: Allow overriding RadioResponse and RadioIndication
kpick 215450 # Add changes for sending ATEL UI Ready to RIL.
kpick 216412 # Revert "Don't assume 3GPP as active app on CDMA with LTE device"
kpick 217091 # Revert "PhoneFactory: fix creating a cdma phone type"
kpick 217092 # TelephonyComponentFactory: Fix invalid phone creation another way

# hardware/broadcom/libbt

# hardware/broadcom/wlan

# hardware/interfaces
kpick 206140 # gps.default.so: fix crash on access to unset AGpsRilCallbacks::request_refloc

# hardware/lineage/interfaces
kpick 213865 # lineage/interfaces: move vibrator to the proper directory
kpick 213866 # lineage/interfaces: extend android.hardware.vibrator@1.0
kpick 213867 # lineage/interfaces: vibrator: read light/medium/strong voltage from sysfs
kpick 213868 # lineage/interfaces: vibrator: implement vendor.lineage methods

# hardware/lineage/lineagehw

# hardware/qcom/audio-caf/msm8974

# hardware/qcom/bt-caf

# hardware/qcom/display
kpick 209093 # msm8974: hwc: Set ioprio for vsync thread

# hardware/qcom/display-caf/msm8974

# hardware/qcom/gps
kpick 218114 # msm8974: Support moving conf files to /vendor/etc
kpick 218115 # msm8974: Support moving conf files to /vendor/etc

# hardware/qcom/media-caf/msm8974

# hardware/qcom/keymaster

# hardware/qcom/power

# hardware/qcom/thermal
kpick 218360 # thermal: use log/log.h header

# haedware/qcom/vr

# hardware/qcom/wlan-caf

# hardware/samsung

# lineage/charter
kpick 213574 # charter: Add some new USB rules
kpick 213836 # charter: add vendor patch level requirement 
kpick 215665 # Add hardware codecs section and exempt some tegra chipsets
#kpick 216518 # Treble exemptions

# lineage/jenkins

# lineage/scripts
kpick 207545 # Add batch gerrit script

# lineage/website(LineageOS/www)

# lineage/wiki
kpick 218356 # Add tip to compile Heimdall from source.

# lineage-sdk
kpick 213367 # NetworkTraffic: Include tethering traffic statistics
kpick 214854 # [3/3] lineagesdk: single hand for hw keys
kpick 216505 # Regen lineage_current
kpick 216915 # lineage-sdk: Introduce TelephonyExtUtils
kpick 216978 # sdk: add torch accent
kpick 217041 # sdk: add black berry style support
kpick 217419 # Add vendor security patch level to device info
kpick 217521 # Trust: warn if build is signed with insecure keys	
kpick 217951 # NetworkTraffic: Resolve status bar indicators tints

# packages/apps/Bluetooth
kpick 218319 # Bluetooth: Remove duplicate permission

# packages/apps/Camera2

# packages/apps/Contacts

# packages/apps/Dialer
kpick 211135 # Show proper call duration

# packages/apps/DeskClock
kpick 213051 # Deskclock: set targetSdk to 27

# packages/apps/Eleven

# packages/apps/Email
kpick 218318 # Email: Remove duplicate permission
:<<EOF
kpick 218368 # email: add an option for delete the account
kpick 218369 # email: support for auto-sync multiple IMAP folders
kpick 218370 # email: support per-folder notifications
kpick 218371 # email: finish the settings activity after delete its account
kpick 218372 # Fix NPE in getHierarchicalFolder
kpick 218373 # email: fix eas autodiscover
kpick 218374 # Implement IMAP push using IMAP IDLE.
kpick 218375 # Fix crash when attempting to view EML files.
kpick 218376 # Allow download of compressed attachments.
kpick 218377 # email: fix empty body update
kpick 218378 # Improve notification coalescence algorithm.
kpick 218379 # email: Add an ActionBar to the mail app's PreferenceActivity
kpick 218380 # Email: Fix the ActivityNotFoundException when click "Update now"
kpick 218381 # Email: Clean duplicated WRITE_CONTACTS permission
kpick 218382 # email: return default folder name for subfolders
kpick 218383 # email: junk icon
kpick 218384 # Search in folder specified via URI parameter, if possible.
EOF

# packages/apps/Exchange
kpick 209820 # Revert changes to make Exchange buildable.
kpick 211382 # correct the targeted SDK version to avoid permission fails otherwise not manually granted permissions lead to fc on account setup

# packages/apps/Flipflap

# packages/apps/Gallery2
kpick 217843 # Revert "Gallery2: Get rid of packages monitor"
kpick 217844 # SDGallery:Fix focus close when receive package changed intent
kpick 217845 # Fix focus close when select video in picker

# packages/apps/Jelly

# packages/apps/LineageParts
#kpick 216887 # LineageParts: Add an option to force pre-O apps to use full screen aspect ratio
kpick 217044 # LineageParts: add black theme support
kpick 217171 # Trust: enforce vendor security patch level check
#kpick 217197 # LineageParts: remove unused network mode picker intent
kpick 217642 # Align learn more and got it horizontally
kpick 217644 # LineageParts: Set proper PreferenceTheme parent	
kpick 217839 # LineageParts: Add Trust entry summary
kpick 218315 # LineageParts: Fix brightness section

# packages/apps/lockClock
kpick 208127 # Update LockClock to use Job APIs 

# packages/apps/Nfc

# packages/apps/OpenWeatherMapProvider
kpick 207864 # Updated Gradle to 3.0.1; The Lineage-SDK jar is now contained in the project files

# packages/apps/Recoder

# packages/apps/Settings
kpick 215672 # SimSettings: Fix dialog in dark mode
kpick 216687 # settings: wifi: Default to numeric keyboard for static IP items
kpick 216822 # Settings: Allow setting device phone number
kpick 216871 # Utils: Always show SIM Settings menu
kpick 216909 # Settings: Apply accent color to on-body detection icon
kpick 216918 # SimSettings: Use TelephonyExtUtils from Lineage SDK
kpick 217420 # Add vendor security patch level to device info
kpick 218131 # settings: Add platform to "Model & Hardware" dialog
kpick 218165 # Add an option to change the device hostname (1/2).

# packages/apps/Snap
kpick 206595 # Use transparent navigation bar
kpick 217087 # Snap: turn developer category title into a translatable string
kpick 217842 # SnapdragonCamera: Fix compilation issues for AOSP upgrade

# packages/apps/Trebuchet
kpick 214336 # [WIP] Trebuchet: initial protected apps implementation

# packages/apps/UnifiedEmail
:<<EOF
kpick 218385 # unified email: prefer account display name to sender name
kpick 218386 # email: fix back button
kpick 218387 # unified-email: check notification support prior to create notification objects
kpick 218388 # unified-email: respect swipe user setting
kpick 218389 # email: linkify urls in plain text emails
kpick 218390 # email: do not close the input attachment buffer in Conversion#parseBodyFields
kpick 218391 # email: linkify phone numbers
kpick 218392 # Remove obsolete theme.
kpick 218393 # Don't assume that a string isn't empty
kpick 218394 # Add an ActionBar to the mail app's PreferenceActivity.
kpick 218395 # email: allow move/copy operations to more system folders
kpick 218396 # unifiedemail: junk icon
kpick 218397 # Remove mail signatures from notification text.
kpick 218398 # MimeUtility: ensure streams are always closed
kpick 218399 # Fix cut off notification sounds.
kpick 218400 # Pass selected folder to message search.
kpick 218401 # Properly close body InputStreams.
EOF

# packages/overlays/Lineage
kpick 215846 # dark: Add Theme.DeviceDefault.Settings.Dialog.NoActionBar style
kpick 216979 # overlays: add torch accent
kpick 217046 # Add support for black berry style

# packages/providers/ContactsProvider

# packages/resources/devicesettings

# pakcages/service/Telecomm

# packages/service/Telephony
kpick 209045 # Telephony: Fallback gracefully for emergency calls if suitable app isn't found
kpick 216722 # phone: Add option for setting device phone number (squashed)

# system/core
kpick 206029 # init: Add command to disable verity
kpick 213876 # healthd: charger: Add tricolor led to indicate battery capacity
kpick 214001 # camera: Add L-compatible camera feature enums
kpick 215626 # Add vendor hook to handle_control_message
kpick 217313 # add odm partition to ld.config.legacy
kpick 217314 # Allow firmware loading from ODM partition

# system/extras
kpick 211210 # ext4: Add /data/stache/ to encryption exclusion list
kpick 217086 # ext4_utils: Fix FS creation for filesystems with exactly 32768 blocks.

# system/netd

# system/nfc

# system/qcom
kpick 215122 # libQWiFiSoftApCfg: Replace deprecated kernel header path

# system/security
kpick 217069 # key_store:Using euid instead of uid when upgrade wifi blobs

# system/sepolicy
kpick 206037 # sepolicy: Allow init to modify system_blk_device

# system/vold
kpick 209189 # vold: Conditionally remove secdiscard command
kpick 218416 # vold: utils: Introduce ForkCallp
#kpick 218417 # vold: Put recovery fstools in minivold
#kpick 218418 # vold: Use ForkCallp for e2fsck

# vendor/lineage
kpick 206154 # Include build manifest on target
#kpick 210664 # extract_utils: Support multidex
kpick 213815 # Place ADB auth property override to system
kpick 215341 # backuptool: Revert "Temporarily render version check permissive"
kpick 214400 # backuptool: Resolve incompatible version grep syntax
kpick 216977 # lineage: build torch accent
kpick 217045 # vendor: build black berry theme
kpick 217088 # Revert "extract_utils: Fix makefile generation issues"
kpick 217089 # Revert "extract_files: Add support for paths without system/"
kpick 217090 # extract_utils: cleanup in extract() function
kpick 217358 # extract_utils: do not strip target_args from the output of prefix_match
kpick 217628 # lineage: add generic x86_64 target
kpick 217629 # kernel: Add TARGET_KERNEL_ADDITIONAL_FLAGS to allow setting extra cflags
kpick 217630 # kernel: Add kernelversion recipe to generate MAJOR.MINOR kernel version
kpick 217837 # envsetup: Fix adb recovery state detections
kpick 217846 # Fix focus close when select video in picker

# vendor/qcom/opensource/cryptfs_hw

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

