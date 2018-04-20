#!/bin/bash
source build/envsetup.sh
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_pick_remote_only=0
op_patches_dir=""
default_remote="github"


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
         [ "$1" != "" -a "$project" != "$1" ] && continue
         cd $topdir/$project
         echo ">>>  project: $project ... "

         commit_id=""
         url=""

         git log --pretty=oneline --max-count=250 > /tmp/gitlog.txt
         while read line; do
             commit_id=$(echo $line | cut -d' ' -f1)
             rbranch=$(git branch --all --contain $commit_id | grep "remotes" | sed -e "s/^ *remotes\///")
             [ "$rbranch" = "" ] && continue
             remote=$(echo $rbranch | cut -d/ -f1)
             branch=$(echo $rbranch | cut -d/ -f2)
             if [ "$remote" = "m" ]; then
                remotetmp=/tmp/projects_snapshot_$(basename $project).list
                git remote show > $remotetmp
                local count=$(cat $remotetmp | wc -l)
                if grep -qw $default_remote $remotetmp; then
                     remote=$default_remote
                else
                     remote=$(sed -n 1p $remotetmp)
                fi
                rm -f $remotetmp
             fi
             url=$(git remote get-url $remote)
             if [ "$remote" != "" ]; then
                  break
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
                           rm -f $patchfile
                           mv $pick_patch $topdir/.mypatches/local/$project/
                       elif [ "${patchfile:5:5}" != "[WIP]" -a "${patchfile:5:6}" != "[SKIP]" ]; then
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
    changeNumber=$(echo  $* | sed -e "s/-f //g")
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
              cat $errfile
              project=$(cat $logfile | grep "Project path" | cut -d: -f2 | sed "s/ //g")
              if [ "$project" != "" -a -d $topdir/$project ]; then
                    if grep -q "using previous resolution" $errfile; then
                       cd $project
                       grep "using previous resolution" $errfile | sed -e "s/Resolved '\(.*\)' using previous resolution.*/\1/" \
                           | xargs git add -f
                       if git cherry-pick --continue; then
                          breakout=0
                          cd $topdir
                          break
                       fi
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
         projects_snapshot $op
         exit $?
    else
         echo "kpick $op"
         kpick $op
    fi
done

if [ $# -ge 1 ]; then
   if [ $op_project_snapshot -eq 1 ]; then
         projects_snapshot
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
# android

# bionic
kpick 212920 # libc: Mark libstdc++ as vendor available

# bootable/recovery
kpick 211098 # recovery/ui: Hide emulated storage for encrypted devices
kpick 212711 # Revert "updater: Fix and improve allowing devices to suppress BLKDISCARD"
kpick 212944 # recovery: Don't try to set ro.adb.secure
kpick 212945 # recovery: Fix loading time from /persist

# build

# build/make
kpick 208567 # [DNM] updater: Don't check fingerprint for incrementals
kpick 209323 # envsetup: stop jack server once build completed

# device/lineage/sepolicy
kpick 210014 # sepolicy: Label aw2013 HIDL light HAL
kpick 207610 # sepolicy: Add rules for LiveDisplay HIDL HAL
kpick 212622 # Remove duplicated genfscon
kpick 212836 # Revert "sepolicy: suppress denial logspam"
kpick 212946 # Remove adb.secure recovery property context
kpick 212947 # Allow recovery write to sysfs_graphics

# device/qcom/sepolicy
kpick 209960 # sepolicy: rules to allow camera daemon access to app buffer
kpick 209961 # sepolicy : add secontext for eMMC blocks
kpick 209962 # sepolicy: Ignore more hal_memtrack denials
kpick 209963 # hal_gnss_default: Do not log udp socket failures
#kpick 209964 # legacy: Allow qcom power HAL to interact with perfd
kpick 209965 # legacy: Allow perfd write to sysfs_kgsl
kpick 209966 # legacy: Address msm8916 perfd denials
kpick 209967 # legacy: Allow bluetooth_loader read persist
kpick 209968 # legacy: Address binderized hwcomposer denial
kpick 210018 # legacy: Allow hal_graphics_allocator_default access sysfs_graphics
kpick 210019 # legacy: Add debugfs rules for rmt_storage
kpick 210020 # legacy: Allow thermal-engine to read sysfs_spmi_dev
kpick 210021 # legacy: Address mm-pp-daemon denials
kpick 210022 # legacy: Address perfd denials
kpick 210023 # legacy: allow graphics composer to set postprocessing props
kpick 210024 # legacy: allow hal_camera_default to connect to camera socket
kpick 211273 # qcom/sepol: Fix timeservice app context
kpick 212643 # qcom/sepol: Allow mm-qcamerad to use binder even in vendor
kpick 212957 # Squashed merge of LA.UM.6.4.r1-07600-8x98.0
kpick 212958 # Squashed merge of LA.UM.6.6.r1-07200-89xx.0

# device/samsung/klte-common
kpick 212647 # klte-common: Use passthrough manifest for all NFC chips
#kpick 212648 # klte-common: Enable AOD

# device/samsung/kltechnduo

# device/samsung/msm8974-common
kpick 210313 # msm8974-common: Binderize them all

# kernel/samsung/msm8974
kpick 210665 # wacom: Follow-up from gestures patch
kpick 210666 # wacom: Report touch when pen button is pressed if gestures are off

# external/chromium-webview
kpick 213143 # Update arm/arm64 webviews to Chromium 66.0.3359.117

# external/toybox
kpick 209019 # toybox: Use ISO C/clang compatible __typeof__ in minof/maxof macros

# frameworks/av
kpick 206427 # camera/media: Support legacy HALv1 camera in mediaserver
kpick 206430 # CameraService: Fix deadlock in binder death cleanup.
kpick 206431 # libstagefright: Free buffers on observer died
kpick 206432 # Camera: fix use after disconnect error
kpick 206433 # stagefright: ACodec: Resolve empty vendor parameters usage
kpick 206434 # media: fix infinite wait at source for HAL1 based recording
kpick 206435 # libstagefright: use 64-bit usage for native_window_set_usage
kpick 206968 # libstagefright: encoder must exist when source starting
kpick 206969 # Camera: Add support for preview frame fd
kpick 213062 # Camera: check metadata type before releasing frame

# frameworks/base
kpick 206400 # SystemUI: Forward-port notification counters
kpick 206701 # NetworkManagement : Add ability to restrict app data/wifi usage
kpick 207583 # BatteryService: Add support for oem fast charger detection
kpick 209031 # TelephonyManager: Prevent NPE when registering phone state listener
kpick 206940 # Avoid crash when the actionbar is disabled in settings
kpick 209929 # SystemUI: fix black scrim when turning screen on from AOD
kpick 213038 # Fix migration from pre-O for AndroidTV devices (1/2)
kpick 213128 # SystemUI: Fix navigation bar arrows visibility handling

# frameworks/native

# frameworks/opt/telephony
#kpick 211280 # telephony: Respect user nw mode, handle DSDS non-multi-rat
#kpick 211338 # Add the user set network mode to the siminfo table

# hardware/broadcom/libbt
#kpick 212921 # libbt: fixup build errors when building the library under vndk.

# hardware/broadcom/wlan
kpick 212922 # wlan:bcmdhd: fixup build errors when building the library under vndk.

# hardware/interfaces
kpick 206140 # gps.default.so: fix crash on access to unset AGpsRilCallbacks::request_refloc

# hardware/lineage/interfaces
kpick 206443 # lineage/interfaces: Add binderized LiveDisplay HAL
kpick 207411 # lineage/interfaces: Add IColor SDM backend implementation
kpick 210009 # lineage/interfaces: Add aw2013 lights HIDL HAL implementation

# hardware/lineage/lineagehw
kpick 207412 # lineagehw: Use HIDL for livedisplay vendor impl

# hardware/qcom/bt-caf

# hardware/qcom/display
kpick 209093 # msm8974: hwc: Set ioprio for vsync thread

# hardware/qcom/display-caf/msm8974

# hardware/qcom/power
kpick 210269 # power: Compile with -Wall -Wextra -Werror
kpick 210302 # power: Consistent skipping of non perf profile hints

# hardware/samsung

# lineage/scripts

# lineage/wiki
kpick 212483 # This command line is more universal, it works too in foreign langages
kpick 212615 # gts28vewifi: Add reminder to check that bootloader is unlocked

# lineage-sdk
kpick 206683 # lineage-sdk: Switch back to AOSP TwilightService
kpick 212943 # lineage-sdk: Allow adjusting brightness of non-RGB LEDs
kpick 213134 # sdk: Introduce Trust Interface

# packages/apps/Camera2
kpick 212625 # Camera2: Fix photo snap delay on front cam.

# packages/apps/Contacts

# packages/apps/Dialer
kpick 209824 # Add setting to enable Do Not Disturb during calls
kpick 211135 # Show proper call duration

# packages/apps/DeskClock
kpick 210074 # Adding Notification Channel
kpick 213051 # Deskclock: set targetSdk to 27

# packages/apps/Eleven
kpick 211302 # Eleven: Catch unsupported bitmap exception

# packages/apps/Gallery2

# packages/apps/LineageParts
kpick 206402 # SystemUI: Forward-port notification counters
kpick 207463 # LineageParts: Fix removing LED brightness settings
kpick 212918 # LineageParts: Fix loading default colors for non-RGB lights
kpick 212942 # LineageParts: Allow adjusting brightness of non-RGB LEDs
kpick 212964 # Parts: Fix notification light app hint

# packages/apps/Settings
kpick 206700 # Settings: per-app cellular data and wifi restrictions
kpick 209208 # Settings: Hide Night Mode suggestion if LiveDisplay feature is present

# packages/services/Telephony
# kpick 211270 # Telephony: add external network selection activity

# packages/apps/Trebuchet
kpick 212749 # Icons: fix non-adaptive icon handling
kpick 212750 # Icons: wrap all legacy icons to adaptive icons
kpick 212751 # config: enable LEGACY_ICON_TREATMENT
kpick 212752 # IconCache: fix crash if icon is an AdaptiveIconDrawable
kpick 212761 # Trebuchet: make forced adaptive icons optional
kpick 212762 # Trebuchet: update build.gradle

# packages/providers/ContactsProvider
kpick 209030 # ContactsProvider: Prevent device contact being deleted.

# system/core
kpick 209385 # init: optimize shutdown time
kpick 210316 # init: Don't run update_sys_usb_config if /data isn't mounted
kpick 212626 # Revert "logd: add "+passcred" for logdw socket"
kpick 212642 # init: do not load persistent properties from temporary /data

# system/extras
kpick 211210 # ext4: Add /data/stache/ to encryption exclusion list

# system/netd
kpick 208353 # NetD : Allow passing in interface names for wifi/data app restriction

# system/qcom

# system/sepolicy
kpick 206428 # Add rules required for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 206429 # Adapt add_service uses for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 212806 # system_server: allow writing to timerslack_ns
kpick 212807 # Allow system_server to update timerslack_ns for hal_audio_default
kpick 212808 # Suppress denials from sdcardfs (b/67454004)
kpick 212809 # priv_app: move logspam suppression to core policy
kpick 212857 # Suppress denials for non-API access  (must before 212821)
kpick 212821 # priv_app: suppress denials for /proc/stat

# vendor/lineage
kpick 206426 # soong_config: Add TARGET_HAS_LEGACY_CAMERA_HAL1 variable
kpick 210664 # extract_utils: Support multidex
kpick 210939 # envsetup: Fix lineageremote for caf projects
kpick 212640 # repopick: Update SSH queries result to match HTTP queries
kpick 213050 # Fix migration from pre-O for AndroidTV devices (2/2)

#-----------------------
# translations
repopick 213165-213177

##################################

[ $op_pick_remote_only -eq 0 ] && patch_local local

