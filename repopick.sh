#!/bin/bash
source build/envsetup.sh
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0
op_patches_dir=""
default_remote="github"

########## main ###################

for op in $*; do
    [ "$op" = "-pl" -o "$op" = "--patch_local" ] && op_patch_local=1
    [ "$op" = "--reset" -o "$op" = "-r" ] && op_reset_projects=1
    [ "$op" = "--snap" -o "$op" = "-s" ] && op_project_snapshot=1
    [ "$op" = "--restore" -o "$op" = "--restore-snap" ] && op_restore_snapshot=1
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
         project=$(echo $f |  sed -e "s/^pick\///" -e "s/^local\///"  | sed "s/\/[^\/]*$//")
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo "==== try apply to $project: "
                  rm -rf .git/rebase-apply
             fi
             ext=${patchfile##*.}
             rm -rf .git/rebase-apply
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                       echo "    patching: $f ..."
                       git am -3 -q < $topdir/.mypatches/$f
                       [ $? -ne 0 ] && exit -1
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
                   changeid=$(grep "Change-Id: " $f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
                   if [ "$changeid" != "" ]; then
                       rm -f $patchfile
                       if grep -q "Change-Id: $changeid" -r $topdir/.mypatches/pick/$project; then
                           pick_patch=$(grep -H "Change-Id: $changeid" -r $topdir/.mypatches/pick/$project | sed -n 1p | cut -d: -f1)
                           mv $pick_patch $topdir/.mypatches/local/$project/
                       fi
                   fi
              done
              ex_patches_count=$(find $topdir/.mypatches/local/$project -name "*.patch" -o -name "*.diff" | wc -l)
              [ $ex_patches_count -eq 0 ] && rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/local/$project
         fi
    done
    mv $snapshot_file.new $snapshot_file
    cd $topdir
}

function restore_snapshot()
{
    cd $(gettop)
    topdir=$(gettop)
    snapshot_file=$topdir/.mypatches/snapshot.list
    [ -f "$snapshot_file" ] || return -1
    cat $snapshot_file | while read line; do
         project=$(echo $line | cut -d, -f1 | sed -e "s/^ *//g" -e "s/ *$//g")
         basecommit=$(echo $line | cut -d, -f2 | sed -e "s/^ *//g" -e "s/ *$//g")
         remoteurl=$(echo $line | cut -d, -f3 | sed -e "s/^ *//g" -e "s/ *$//g")

         cd $topdir/$project


         echo ">>>  restore project: $project ... "
         git stash; git clean -xdf
         if git log -n0 $basecommit 2>/dev/null; then
             git -q checkout --detach $basecommit
         else
             git fetch $remoteurl $basecommit && git checkout -q FETCH_HEAD
         fi 

         searchdir=""
         [ -d .mypatches/pick/$project ] && searchdir="$searchdir .mypatches/pick/$project"
         [ -d .mypatches/local/$project ] && searchdir="$searchdir .mypatches/local/$project"

         find $searchdir -type f -name "*.patch" -o -name "*.diff" | sed -e "s/\.mypatches\///"  -e "s/\//:/" |sort -t : -k 2 | while read line; do
             rm -rf .git/rebase-apply
             f=$(echo $line | sed -e "s/:/\//")
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                      echo "          apply patch: $f ..."
                      git am -3 -q < $topdir/.mypatches/$f
                      [ $? -ne 0 ] && exit -1
                  else
                      echo "          skip patch: $f ...(applied always)"
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
   exit 0
fi

######################################

function kpick()
{
    tmpfile=/tmp/__repopick_tmp.log
    rm -f $tmpfile
    repopick -c 20 $* 2>$tmpfile
    if [ $? -eq 1 -a -f $tmpfile ] ; then
          #cat  $tmpfile
          if ! grep -q "allow-empty" $tmpfile; then
              cat $tmpfile
              rm -f $tmpfile
              exit -1
          fi
    fi
    rm -f $tmpfile
}



if [ $USER != haggertk ]; then
  d=`pwd`
  cd vendor/samsung || exit 1
  git remote remove haggertk > /dev/null 2>&1
  git remote add haggertk https://github.com/haggertk/proprietary_vendor_samsung.git || exit 1
  git fetch haggertk lineage-15.1 || exit 1
  git checkout haggertk/lineage-15.1 || exit 1
  cd "$d"
fi

# device/samsung/klte-common
kpick 199932 # [DNM] klte-common: import libril from hardware/ril-caf
kpick 199933 # [DNM] klte-common: libril: Add Samsung changes
kpick 199934 # klte-common: libril: Fix RIL_Call structure
kpick 199935 # klte-common: libril: Fix SMS on certain variants
kpick 199936 # klte-common: libril: fix network operator search
kpick 199937 # klte-common: Update RIL_REQUEST_QUERY_AVAILABLE_NETWORKS response prop
kpick 200757 # klte-common: libril: Add workaround for "ring of death" bug
kpick 199941 # klte-common: libril: Fix RIL_UNSOL_NITZ_TIME_RECEIVED Parcel
kpick 200495 # klte-common: Fixup RIL_Call structure
kpick 201182 # klte-common: libril: Get off my back
kpick 199943 # [DNM] klte-common: selinux permissive for O bringup
kpick 199944 # [DNM] klte-common: Kill blur overlay
kpick 199946 # [DNM] klte-common: sepolicy: Rewrite for O
kpick 200643 # klte-common: Move hardware key overlays from fw/b to lineage-sdk
kpick 200805 # klte-common: Fragment NFC support to chip type
kpick 201051 # klte-common: Move charger service into the charger domain

# device/samsung/kltechnduo
kpick 200524 # kltechnduo: Rework launch of second RIL daemon
kpick 200736 # kltechnduo: Use rild2.libpath property for ril-daemon2
#kpick 200874 # kltechnduo: Use fragmented NFC support from -common

# device/samsung/msm8974
kpick 200634 # msm8974-common: Setup localctors for shared blobs
kpick 200635 # msm8974-common: Use shared blobs from vendor/
kpick 200636 # msm8974-common: Ship RenderScript HAL
kpick 200637 # msm8974-common: Enable boot and system server dex-preopt
kpick 200538 # msm8974-common: Use QTI power hal
kpick 201237 # msm8974-common: Add seccomp policy

# external/tinycompress
kpick 199120 # tinycompress: HAXXX: Move libtinycompress_vendor back to Android.mk

# hardware/samsung
kpick 200068 # AdvancedDisplay: cyanogenmod -> lineageos

# device/lineage/sepolicy
kpick 198594 # sepolicy: qcom: Import bluetooth_loader/hci_attach rules
kpick 199347 # sepolicy: Set the context for fsck.exfat/ntfs to fsck_exec
kpick 199348 # sepolicy: Add domain for mkfs binaries
kpick 199349 # sepolicy: label exfat and ntfs mkfs executables
kpick 199350 # sepolicy: treat fuseblk as sdcard_external
kpick 199351 # sepolicy: fix denials for external storage
kpick 199352 # sepolicy: Allow vold to `getattr` on mkfs_exec
kpick 199353 # sepolicy: allow vold to mount fuse-based sdcard
kpick 199515 # sepolicy: Add policy for sysinit
kpick 199516 # sepolicy: allow userinit to set its property
kpick 199517 # sepolicy: Permissions for userinit
kpick 199518 # sepolicy: Fix sysinit denials
kpick 199571 # sepolicy: Move fingerprint 2.0 service out of private sepolicy
kpick 199572 # sepolicy: SELinux policy for persistent properties API

# device/qcom/common
kpick 201274 # power: Update power hal extension for new qti hal

# device/qcom/sepolicy
kpick 198620 # sepolicy: Let keystore load firmware
kpick 198703 # Revert "sepolicy: Allow platform app to find nfc service"
kpick 198707 # sepolicy: Include legacy rild policies
kpick 198141 # Use set_prop() macro for property sets
kpick 198303 # sepolicy: Add sysfs labels for devices using 'soc.0'
kpick 199557 # sepolicy: Readd perfd policies
kpick 199558 # sepolicy: Allow system_app to connect to time_daemon socket
kpick 199559 # sepolicy: Allow dataservice_app to read/write to IPA device
kpick 199560 # sepolicy: Allow bluetooth to connect to wcnss_filter socket
kpick 199562 # sepolicy: Allow netmgrd to communicate with netd
kpick 199562 # sepolicy: Allow netmgrd to communicate with netd
kpick 199564 # sepolicy: Allow energyawareness to read sysfs files
kpick 199565 # sepolicy: Label pre-O location data and socket file paths
kpick 199554 # sepolicy: Add /data/vendor/time label for old oreo blobs
kpick 199600 # sepolicy: Allow 'sys_admin' capability for rmt_storage

# system/sepolicy
kpick 199664 # sepolicy: Fix up exfat and ntfs support

# frameworks/base
kpick 199835 # Runtime toggle of navbar
kpick 198564 # Long-press power while display is off for torch
kpick 199897 # Reimplement hardware keys custom rebinding
kpick 199860 # Reimplement device hardware wake keys support
kpick 199199 # PhoneWindowManager: add LineageButtons volumekey hook
kpick 199200 # Framework: Volume key cursor control
kpick 199203 # Forward port 'Swap volume buttons' (1/3)
kpick 199865 # PhoneWindowManager: Tap volume buttons to answer call
kpick 199906 # PhoneWindowManager: Implement press home to answer call
kpick 199982 # SystemUI: add left and right virtual buttons while typing
kpick 200112 # Framework: Forward port Long press back to kill app (2/2)
kpick 200188 # Allow screen unpinning on devices without navbar
kpick 199947 # PowerManager: Re-integrate button brightness
kpick 200968 # statusbar: Add arguments to shutdown and reboot to allow confirmation
kpick 200969 # SystemUI: Power menu customizations

# frameworks/native
kpick 199204 # Forward port 'Swap volume buttons' (2/3)
#kpick 201530 # AppOpsManager: Update with the new ops

# packages/apps/Settings
kpick 200113 # Settings: Add kill app back button toggle
kpick 199839 # Settings: Add advanced restart switch
#kpick 201529 # Settings: Privacy Guard

# packages/apps/LineageParts
kpick 200069 # LineageParts: Deprecate few button settings
kpick 199198 # LineageParts: Bring up buttons settings
kpick 199948 # LineageParts: Bring up button backlight settings
kpick 201309 # LineageParts: Re-enable PowerMenuActions and adapt to SDK updates
#kpick 201528 # PrivacyGuard: Bring up and inject into Settings


# lineage-sdk
kpick 199196 # lineage-sdk internal: add LineageButtons
kpick 199197 # lineage-sdk: Import device hardware keys configs and constants
kpick 199898 # lineage-sdk: Import device keys custom rebinding configs and add helpers
kpick 200106 # lineage-sdk: Import ActionUtils class
kpick 200114 # lineage-sdk: Add kill app back button configs and strings
kpick 200970 # sdk: Move isAdvancedRebootEnabled to SDK from global access
kpick 201311 # lineage-sdk: Add broadcast action for power menu update

# packages/apps/Dialer
kpick 201346
kpick 201634

# vendor/lineage
kpick 201560

patch_local local

