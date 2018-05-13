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

function kpick()
{
    topdir=$(gettop)
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
              if [ "$project" != "" -a -d $topdir/$project ]; then
                    if grep -q "using previous resolution" $errfile; then
                       echo "------------"
                       cd $project
                       grep "using previous resolution" $errfile | sed -e "s/Resolved '\(.*\)' using previous resolution.*/\1/" \
                           | xargs git add -f
                       if git cherry-pick --continue; then
                          breakout=0
                          cd $topdir
                          break
                       fi
                       cd $topdir
                       echo "------------"
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
           #eval  sed -e \"s/\\\(^[[:space:]]*kpick $changeNumber[[:space:]]*.*\\\)/#\[A\] \\1/\" -i $script_file.tmp
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
    elif [ $op_patch_local -eq 1 ]; then
            op_patches_dir="$op"
    elif [ $op_project_snapshot -eq 1 -a  -d "$(gettop)/$op" ]; then
         op_snap_project=$op
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
find $topdir/.mypatches/local/vendor/lineage/ -type f -name "*-\[ALWAYS\]-*.patch" -o -name "*-\[ALWAYS\]-*.diff" \
  | while read f; do
     cd $topdir/vendor/lineage;
     if ! git am -3 -q < $f; then
        exit -1
     fi
done

# android
#kpick 213704 # Track our own chips
#kpick 213705 # 	Build Exchange
#repo sync --force-sync frameworks/opt/chips
#repo sync --force-sync packages/apps/Exchange
repo sync --force-sync frameworks/opt/datetimepicker

# bionic
kpick 212920 # libc: Mark libstdc++ as vendor available

# bootable/recovery
kpick 211098 # recovery/ui: Hide emulated storage for encrypted devices
kpick 213265 # recovery: Do not load time from /persist

# build/make
kpick 208102 # Adapt ijar for WSL
kpick 208567 # [DNM] updater: Don't check fingerprint for incrementals
kpick 209323 # envsetup: stop jack server once build completed
kpick 213515 # build: Use minimial compression when zipping targetfiles
kpick 213572 # Allow to exclude imgs from target-files zip
kpick 214842 # dex2oat: disable multithreading
kpick 214883 # core: config: Use host ijar if requested
kpick 214892 # Add detection for WSL
kpick 214964 # build: Include LineageOS specific properties in build.prop

# build/soong

# device/lineage/sepolicy
kpick 210014 # sepolicy: Label aw2013 HIDL light HAL
kpick 212763 # sepolicy: introduce Trust interface
kpick 214121 # sepolicy: Add legacy-mm livedisplay label
#kpick 214160 # sepolicy: Allow priv_app rw-access to system_app_data_file

# device/qcom/sepolicy
kpick 211273 # qcom/sepol: Fix timeservice app context
kpick 212643 # qcom/sepol: Allow mm-qcamerad to use binder even in vendor
kpick 214799 # sepolicy: qti_init_shell needs to read dir too

# device/samsung/klte-common
#kpick 212648 # klte-common: Enable AOD
kpick 213270 # klte-common: Stop absuing global contexts for fingerprint

# device/samsung/kltechnduo

# device/samsung/msm8974-common
kpick 210313 # msm8974-common: Binderize them all

# kernel/samsung/msm8974
kpick 210665 # wacom: Follow-up from gestures patch
kpick 210666 # wacom: Report touch when pen button is pressed if gestures are off
kpick 214900 # ANDROID: sdcardfs: Don't d_drop in d_revalidate

# external/chromium-webview

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

# frameworks/base
kpick 206568 # base: audioservice: Set BT_SCO status
kpick 207583 # BatteryService: Add support for oem fast charger detection
kpick 209031 # TelephonyManager: Prevent NPE when registering phone state listener
kpick 206940 # Avoid crash when the actionbar is disabled in settings
kpick 209929 # SystemUI: fix black scrim when turning screen on from AOD
#kpick 211300 # Add the user set network mode to the siminfo table
#kpick 211301 # Store Network Mode selected in subId Table.
kpick 213133 # base: introduce trust interface
kpick 213371 # Add an option to let pre-O apps to use full screen aspect ratio
kpick 214043 # UsbDeviceManager: Use isNormalBoot() where possible
kpick 214044 # UsbDeviceManager: Allow custom boot modes to be treated as normal mode
kpick 214262 # Bind app name to menu row when notification updated
kpick 214263 # Fix intercepting touch events for guts
kpick 214264 # Update text size of overflow number view
kpick 214265 # Better QS detail clip animation
kpick 214856 # SystemUI: Enable dualTarget on CellularTile
kpick 214864 # SystemUI: Don't append app name to file on lockscreen
#kpick 214867 # Expose isAutonomousGroupOwner [1/2]
#kpick 214868 # Expose cancelWps [1/2]
#kpick 214869 # Allow activing a saved autonomous group [1/2]

# frameworks/native
kpick 213549 # SurfaceFlinger: Support get/set ActiveConfigs

# frameworks/opt/chips
#kpick 211435 # chips: bring up changes from cm14.1

# frameworks/opt/telephony
#kpick 211280 # telephony: Respect user nw mode, handle DSDS non-multi-rat.
#kpick 211338 # Add the user set network mode to the siminfo table
kpick 213487 # GsmCdmaPhone: Return dummy ICCID serial for NV sub
kpick 213488 # GsmCdmaPhone: Fix GSM SIM card ICCID on NV sub CDMA devices
kpick 214316 # RIL: Allow overriding RadioResponse and RadioIndication

# frameworks/opt/net/wifi
#kpick 214870 # Expose cancelWps [2/2]
#kpick 214871 # Allow activing a saved autonomous group [2/2]
#kpick 214872 # Expose isAutonomousGroupOwner [2/2]

# hardware/broadcom/libbt

# hardware/broadcom/wlan
kpick 212922 # wlan:bcmdhd: fixup build errors when building the library under vndk.

# hardware/interfaces
kpick 206140 # gps.default.so: fix crash on access to unset AGpsRilCallbacks::request_refloc

# hardware/lineage/interfaces
kpick 210009 # lineage/interfaces: Add aw2013 lights HIDL HAL implementation
kpick 213817 # livedisplay: Don't use singletons for the stack
kpick 213865 # lineage/interfaces: move vibrator to the proper directory
kpick 213866 # lineage/interfaces: extend android.hardware.vibrator@1.0
kpick 213867 # lineage/interfaces: vibrator: read light/medium/strong voltage from sysfs
kpick 213868 # lineage/interfaces: vibrator: implement vendor.lineage methods
kpick 214027 # livedisplay: Port mm-disp implementation
kpick 214095 # livedisplay: Move extra inclusions out of header files
kpick 214096 # livedisplay: Avoid using::xxxx in header files

# hardware/lineage/lineagehw

# hardware/qcom/audio-caf/msm8974
kpick 213856 # hal: msim_voice_extn: Cleanup code a bit
kpick 213857 # hal: msim_voice_extn: Set msim_phone based on phone_type parameter

# hardware/qcom/bt-caf

# hardware/qcom/display
kpick 209093 # msm8974: hwc: Set ioprio for vsync thread

# hardware/qcom/display-caf/msm8974

# hardware/qcom/power

# hardware/samsung

# lineage/charter
kpick 213574 # charter: Add some new USB rules
kpick 214349 # charger: Improve 'Stability' compliances details

# lineage/jenkins

# lineage/scripts
kpick 207545 # Add batch gerrit script

# lineage/wiki
kpick 212483 # This command line is more universal, it works too in foreign langages
kpick 212615 # gts28vewifi: Add reminder to check that bootloader is unlocked

# lineage-sdk
kpick 213134 # sdk: Introduce Trust Interface
kpick 213367 # NetworkTraffic: Include tethering traffic statistics
kpick 213641 # lineage-sdk lights: Genericize adjustable brightness capability
kpick 214025 # sdk: Add an option to force pre-O apps to use full screen aspect ratio

# packages/apps/Camera2

# packages/apps/Contacts

# packages/apps/Dialer
kpick 209824 # Add setting to enable Do Not Disturb during calls
kpick 211135 # Show proper call duration

# packages/apps/DeskClock
kpick 210074 # Adding Notification Channel
kpick 213051 # Deskclock: set targetSdk to 27

# packages/apps/Eleven
kpick 211302 # Eleven: Catch unsupported bitmap exception

# packages/apps/Email
#kpick 211380 # Email: bring up changes from cm14.1 migrate to lineage-sdk LightsCapabilities revert parts from acc49fed1 ...

# packages/apps/Exchange
#kpick 211382 # Exchange: correct the targeted SDK version to avoid permission fails

# packages/apps/Flipflap

# packages/apps/Gallery2

# packages/apps/Jelly

# packages/apps/LineageParts
kpick 213135 # LineageParts: introduce Trust interface
kpick 213642 # LineageParts: Update for generic adjustable brightness capability
kpick 214309 # Parts: add NIGHT_DISPLAY_SETTINGS intent to LiveDisplay

# packages/apps/Settings
kpick 212764 # Settings: add Trust interface hook
kpick 212765 # Settings: show Trust branding in confirm_lock_password UI
kpick 213372 # Settings: Add an option to let pre-O apps to use full screen aspect ratio
kpick 214283 # Settings: center USB mode selection title

# packages/apps/Snap
kpick 206595 # Use transparent navigation bar

# packages/apps/Trebuchet
kpick 212749 # Icons: fix non-adaptive icon handling
kpick 212750 # Icons: wrap all legacy icons to adaptive icons
kpick 212751 # config: enable LEGACY_ICON_TREATMENT
kpick 212752 # IconCache: fix crash if icon is an AdaptiveIconDrawable
kpick 212761 # Trebuchet: make forced adaptive icons optional

# packages/apps/UnifiedEmail
#kpick 211379 # UnifiedEmail: bring up changes from cm14.1 migrate to lineage-sdk LightsCapabilities and LineageNotification

# packages/apps/Updater
kpick 213136 # Updater: show Trust branding when the update has been verified

# packages/providers/ContactsProvider
kpick 209030 # ContactsProvider: Prevent device contact being deleted.

# packages/resources/devicesettings

# pakcages/service/Telecomm
kpick 214244 # Telecomm: Fix in-call audio edge case for legacy MSIM devices

# packages/service/Telephony
kpick 209045 # Telephony: Fallback gracefully for emergency calls if suitable app isn't found
#kpick 211270 # Telephony: add external network selection activity (******WIP*****)

# system/core
kpick 209385 # init: optimize shutdown time
kpick 213918 # Add system-background cgroup to the schedtune controller hierarchy.
kpick 213876 # healthd: charger: Add tricolor led to indicate battery capacity
kpick 214001 # camera: Add L-compatible camera feature enums

# system/extras
kpick 211210 # ext4: Add /data/stache/ to encryption exclusion list

# system/netd

# system/nfc
kpick 213184 # Fix GKI task release twice issue
kpick 213185 # Fix TASKPTR's definition to match actual function signatures
kpick 213186 # Correct the parameter length for core_initialized()
kpick 213187 # Memory leak fix in NFA_SetRfDiscoveryDuration()

# system/qcom

# system/sepolicy
kpick 206136 # sepolicy: allow update_engine to bypass neverallows for backuptool

# vendor/lineage
kpick 206138 # vendor: add custom backuptools and postinstall script for A/B OTAs
kpick 206139 # backuptool: introduce addon.d script versioning
kpick 210664 # extract_utils: Support multidex
kpick 212640 # repopick: Update SSH queries result to match HTTP queries
kpick 212766 # vendor: introduce Trust interface
kpick 213815 # Place ADB auth property override to system
kpick 214400 # backuptool: Resolve incompatible version grep syntax
#kpick 214572 # backuptool: Temporarily render version check permissive
kpick 214782 # lineage: extract_utils: Fix rootfs targets after a48b9fe9b6c25746940a2410db640d5e5438363d 
kpick 214899 # lineage: Keep LineageOS versions properties in build.prop

# vendor/qcom/opensource/cryptfs_hw

#-----------------------
# translations

##################################

[ $op_pick_remote_only -eq 0 ] && patch_local local
[ -f $script_file.tmp ] && mv $script_file.tmp $script_file.new

