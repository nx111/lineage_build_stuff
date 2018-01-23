#!/bin/bash
source build/envsetup.sh
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_pick_remote_only=0
op_patches_dir=""
default_remote="github"

########## main ###################

for op in $*; do
    [ "$op" = "-pl" -o "$op" = "--patch_local" ] && op_patch_local=1
    [ "$op" = "--reset" -o "$op" = "-r" ] && op_reset_projects=1
    [ "$op" = "--snap" -o "$op" = "-s" ] && op_project_snapshot=1
    [ "$op" = "--restore" -o "$op" = "--restore-snap" ] && op_restore_snapshot=1
    [ "$op" = "--remote-only" -o "$op" = "-ro" ] && op_pick_remote_only=1
    if [ "$op" = "-rp" -o "$op" = "-pr" ]; then
        op_reset_projects=1
    fi
    if [ $op_patch_local -eq 1 ] && [ "$op" = "pick" -o "$op" = "local" ]; then
        op_patches_dir="$op"
    fi
done

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
get_defaul_remote

function patch_local()
{
    cd $(gettop)
    topdir=$(gettop)
    va_patches_dir=$1
    search_dir=".mypatches"

    [ "$va_patches_dir" = "local" ] && search_dir=".mypatches/local"
    [ "$va_patches_dir" = "pick" ] && search_dir=".mypatches/pick"

    find $search_dir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///" -e "s/\//:/" |sort -t : -k 2 | while read line; do
         f=$(echo $line | sed -e "s/:/\//")
         patchfile=$(basename $f)
         if [ "${patchfile:5:5}" = "[WIP]" -o "${patchfile:5:6}" = "[SKIP]" ]; then
             echo "    skipping: $f"
             continue
         fi
         project=$(echo $f |  sed -e "s/^pick\///" -e "s/^local\///"  | sed "s/\/[^\/]*$//")
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
              ex_patches_count=$(find $topdir/.mypatches/local/$project -name "*.patch" -o -name "*.diff" | wc -l)
              [ $ex_patches_count -eq 0 ] && rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/local/$project
         fi
    done
    find $topdir/.mypatches -type d | xargs rmdir --ignore-fail-on-non-empty >/dev/null 2>/dev/null
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
                      echo "         skipping: $f ...(applied always)"
                  fi
              fi
         done

    done
    cd $topdir
}

if [ $# -ge 1 ]; then
   [ $op_project_snapshot -eq 1 ] && projects_snapshot
   [ $op_reset_projects -eq 1 ] && projects_reset
   [ $op_patch_local -eq 1 ] && patch_local $op_patches_dir
   [ $op_restore_snapshot -eq 1 ] && restore_snapshot
   [ $op_pick_remote_only -eq 0 ] && exit 0
fi

######################################

function kpick()
{
    logfile=/tmp/__repopick_tmp.log
    errfile=$(echo $logfile | sed -e "s/\.log$/\.err/")

    rm -f $errfile
    echo ""
    LANG=en_US repopick -c 50 $* >$logfile 2>$errfile
    rc=$?
    cat $logfile | sed -e "/ERROR: git command failed/d"
    local tries=0
    local breakout=0
    while [ $rc -ne 0 -a -f $errfile ] ; do
          #cat  $errfile
          if [ $tries -ge 30 ]; then
                echo "    >> pick faild !!!!!"
                cat $errfile
                breakout=-1
                break
           fi

          grep -q -E "nothing to commit|allow-empty" $errfile && breakout=1 && break

          if grep -q -E "error EOF occurred|httplib\.BadStatusLine" $errfile; then
              echo "  >> pick was interrupted, retry..."
              echo ""
              LANG=en_US repopick -c 20 $* >$logfile 2>$errfile
              rc=$?
              if [ $rc -ne 0 ]; then
                  cat $logfile | sed -e "/ERROR: git command failed/d"
                  tries=$(expr $tries + 1)
                  continue
              else
                  breakout=0
                  break
              fi
          fi
          if grep -q "conflicts" $errfile; then
              cat $errfile
              echo  "  >> pick changes conflict, please resolv it, then press ENTER to continue ..."
              sed -n q </dev/tty
              echo ""
              LANG=en_US repopick -c 20 $* >$logfile 2>$errfile
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

          echo "  >>**** repopick failed !"
          cat $errfile
          rm -f $errfile
          exit -1

    done
    rm -f $errfile
    [ $breakout -lt 0 ] && cat $errfile && exit $breakouit
}

# build/make
kpick 202441 # core: config: Add inline kernel headers to AOSP kernel header path
kpick 203381 # Revert "build: don't dex preopt by default on linux"

# device/samsung/klte-common
kpick 203304 # klte-common: power: Add legacy qcom HAL compat code

# device/samsung/kltechnduo

# device/samsung/msm8974
kpick 203120 # msm8974: Enable full dex preopt
kpick 203303 # Revert "msm8974-common: Use QTI HIDL power HAL" 

# device/lineage/sepolicy
kpick 198594 # sepolicy: qcom: Import bluetooth_loader/hci_attach rules
kpick 199572 # sepolicy: SELinux policy for persistent properties API
kpick 201552 # Squashed import of superuser SELinux policies
kpick 201582 # sepolicy: adapt sudaemon policy for O
kpick 203433 # sepolicy: Allow apps with API level <= 25 to access services
kpick 203558 # sepolicy: Add policy for vendor.lineage.power HAL
kpick 203578 # qcom: Allow fsck to check /persist

# device/qcom/common
kpick 201274 # power: Update power hal extension for new qti hal

# device/qcom/sepolicy
kpick 199559 # sepolicy: Allow dataservice_app to read/write to IPA device
kpick 202830 # legacy: Add back legacy sensors rules
kpick 202995 # legacy: Address mpdecision denials

# frameworks/av
kpick 198113 # camera/media: Support for legacy camera HALv1
kpick 198114 # libstagefright: Support for legacy camera/encoder buffers
kpick 198116 # CameraService: Fix deadlock in binder death cleanup.
kpick 201731 # libstagefright: use 64-bit usage for native_window_set_usage
kpick 203520 # media: fix infinite wait at source for HAL1 based recording
kpick 203521 # libstagefright: Free buffers on observer died
kpick 203522 # stagefright: ACodec: Resolve empty vendor parameters usage
kpick 203523 # Camera: fix use after disconnect error

# frameworks/base
kpick 198701 # AppOps: track op persistence by name instead of id
kpick 200969 # SystemUI: Power menu customizations
kpick 201879 # frameworks: Privacy Guard for O
kpick 199947 # PowerManager: Re-integrate button brightness
kpick 202423 # Screenshot: append app name to filename
kpick 202874 # Show infinity for large notification counts
kpick 203053 # perf: Add plumbing for PerformanceManager
kpick 203054 # perf: Adapt for HIDL Lineage power hal
kpick 203441 # Fix double action performed when pressing menu key
kpick 203457 # Add auth framework for outgoing SMS messages
kpick 203583 # storage: Allow browseIntent for external storage
kpick 203584 # storage: Allow to set sdcards to visible

# frameworks/native
kpick 201530 # AppOpsManager: Update with the new ops
kpick 203294 # surfaceflinger: set a prop when initialization is complete

# frameworks/opt/Telephony
kpick 203256 # MMS: Update apnProfileID for MMS only apn


# hardware/libhardware-legacy
kpick 202996 # Wifi: Add Qpower interface to libhardware_legacy

# hardware/lineage/interfaces
kpick 201226 # gps.default.so: fix crash on access to unset AGpsRilCallbacks::request_refloc
kpick 203061 # lineage/interfaces: power: Add binderized service

# hardware/qcom/power
kpick 203055 # power: Prepare for power profile support
kpick 203066 # power: Add known perf hint IDs
kpick 203067 # power: msm8996: Add support for power profile and cpu boost
kpick 203115 # power: Enable interaction boost unconditionally

# lineage-sdk
kpick 203030 # lineage-sdk: Add overlay support for disabling hardware features
kpick 203011 # lineage-sdk: Reenable performance profiles

# packages/apps/Dialer
kpick 201346 # Re-add dialer lookup.
kpick 201634 # Allow using private framework API. 

# packages/apps/LineageParts
#kpick 200069 # LineageParts: Deprecate few button settings
#kpick 199198 # LineageParts: Bring up buttons settings
kpick 199948 # LineageParts: Bring up button backlight settings
kpick 201528 # PrivacyGuard: Bring up and inject into Settings
kpick 203010 # LineageParts: enable perf profiles
kpick 203440 # LineageParts: Match default menu long press action with actual config
kpick 203550 # LineageParts: Fix up additional styles for O

# packages/apps/Settings
kpick 201529 # Settings: Privacy Guard
kpick 201531 # Settings: Add developer setting for root access
kpick 203009 # Settings: battery: Add LineageParts perf profiles
kpick 203599 # Settings: port manual provisiong support
kpick 203600 # SimSettings: Correctly disabling sim switch without sim card
kpick 203626 # SimSettings: improve dialogs

# packages/apps/Snap
kpick 202685 # Snap: Rebrand to org.lineageos.snap
kpick 203342 # Snap: update shutter buttons on CaptureUI

# packages/service/Telephony
kpick 199006 # Add TD-SCDMA related network mode options
kpick 199007 # Telephony: Fix translatability of network modes

# system/core
kpick 202596 # fs_config: fix fileperms for su-binary

# system/sepolicy
kpick 198106 # Add rules required for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 198107 # Adapt add_service uses for TARGET_HAS_LEGACY_CAMERA_HAL1
kpick 201553 # sepolicy: We need to declare before referencing
kpick 201583 # sepolicy: Allow su by apps on userdebug_or_eng
kpick 201584 # sepolicy: update policies for sudaemon on O
kpick 201732 # sepilocy: add sudaemon to ignore list
kpick 203330 # treble sepolicy tests: Workaround /sbin services labels

#vendor/lineage
kpick 201336 # soong_config: Add TARGET_HAS_LEGACY_CAMERA_HAL1 variable
#kpick 202692 # lineage: Enable boot and system server dex-preopt

##################################

[ $op_pick_remote_only -eq 0 ] && patch_local local

