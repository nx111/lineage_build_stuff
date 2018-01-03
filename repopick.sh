#!/bin/bash
source build/envsetup.sh
op_reset_projects=0
op_patch_local=0
op_project_snapshot=0
op_restore_snapshot=0

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
    default_branch=$(cat .repo/manifest.xml | grep "default revision" | cut -d= -f2 | sed -e "s/\"//g" -e "s/refs\/heads\///")

    find .mypatches -type f | sed -e "s/\.mypatches\///" |sort -n | while read f; do
         patchfile=$(basename $f)
         project=$(echo $f | sed "s/\/[^\/]*$//")
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo "==== try apply to $project: "
                  rm -rf .git/rebase-apply
             fi
             ext=${patchfile##*.}
             rm -rf .git/rebase-apply
             if [ "$ext" = "patch" -o "$ext" = "diff" ]; then
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

         [ -d $topdir/.mypatches/$project ] || mkdir -p $topdir/.mypatches/$project
         rm -rf $topdir/.mypatches/$project/*.patch
         rm -rf $topdir/.mypatches/$project/*.diff

         git format-patch "$commit_id" -o $(gettop)/.mypatches/$project/
         patches_count=$(find $topdir/.mypatches/$project -name "*.patch" -o -name "*.diff" | wc -l)
         [ $patches_count -eq 0 ] && rmdir -p --ignore-fail-on-non-empty $topdir/.mypatches/$project

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

         [ -d .mypatches/$project ] && \
         find .mypatches/$project -type f | sed -e "s/\.mypatches\///" |sort -n | while read f; do
             patchfile=$(basename $f)
             ext=${patchfile##*.}
             rm -rf .git/rebase-apply
             if [ "$ext" = "patch" -o "$ext" = "diff" ]; then
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
             fi
         done

    done
    cd $topdir
}

if [ $# -ge 1 ]; then
   [ $op_project_snapshot -eq 1 ] && projects_snapshot
   [ $op_reset_projects -eq 1 ] && projects_reset
   [ $op_patch_local -eq 1 ] && patch_local
   [ $op_restore_snapshot -eq 1 ] && restore_snapshot
   exit 0
fi

######################################
#### repicks from haggertk #####

function kpick() {
  repopick $1 
}

:<<_COMMENT_
CAF_HALS="audio display media"
for hal in $CAF_HALS; do
  d=`pwd`
  cd hardware/qcom/${hal}-caf/msm8974 || exit 1
  git remote remove bgcngm 2>/dev/null
  git remote add bgcngm https://github.com/bgcngm/android_hardware_qcom_${hal}.git || exit 1
  git fetch bgcngm staging/lineage-15.1-caf-8974-rebase-LA.BF.1.1.3_rb1.15  || exit 1
  git checkout bgcngm/staging/lineage-15.1-caf-8974-rebase-LA.BF.1.1.3_rb1.15 || exit 1
  cd $d
done
_COMMENT_

kpick 199120 # tinycompress: HAXXX: Move libtinycompress_vendor back to Android.mk

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

# hardware/broadcom/libbt
kpick 200115 # libbt: Add btlock support
kpick 200116 # libbt: Add prepatch support
kpick 200117 # libbt: Add support for using two stop bits
kpick 200118 # libbt-vendor: add support for samsung bluetooth
kpick 200119 # libbt-vendor: Add support for Samsung wisol flavor
kpick 200121 # libbt-vendor: Fix Samsung patchfile detection.
kpick 200122 # Avoid an annoying bug that only hits BCM chips running at less than 3MBps
kpick 200123 # libbt-vendor: add support for Samsung semco
kpick 200124 # Broadcom BT: Add support fm/bt via v4l2.
kpick 200126 # libbt: Import CID_PATH from samsung_macloader.h
kpick 200127 # libbt: Only allow upio_start_stop_timer on 32bit arm

# hardware/samsung
kpick 200133 # macloader: Stop allowing G and O write perms to the cidfile

# system/sepolicy
kpick 199664 # sepolicy: Fix up exfat and ntfs support

########## more picks ################

#exit 0

######## repopicks from afaneh92 ##############

repopick  198959 # PackageManager: Add configuration to specify vendor platform signatures
repopick  198950 # Enable NSRM (Network Socket Request Manager).
repopick  198951 # CamcorderProfiles: Add new camcorder profiles
repopick  198952 # HAX: add LPCM to list
#repopick  198953 # kernel: Handle kernel modules correctly
repopick  198954 # build: Make systemimage depend on installed kernel if system is root
repopick  198960 # update_verifier: skip verity to determine successful on lineage builds
repopick  198955 # init: don't reboot to bootloader on panic
repopick  198958 # init: I hate safety net

repopick  198956 # envsetup: Update default path for SDCLANG 4.0
repopick  198962 # Init: Support bootdevice symlink for early mount.
repopick  198961 # frameworks/base: Support for third party NFC features and extensions

repopick  198949 # kernel: don't build for TARGET_NO_KERNEL targets
repopick  198957 # NFC: Adding new vendor specific interface to NFC Service
#repopick  198036 # softap: sdk: Declare VNDK usage
#repopick  198029 # bash: Disable clang
repopick  198050 # nxp: NativeNfcManager: Implement missing inherited abstract methods
repopick  198095 # sepolicy: Ignore custom lineage additions

repopick  198967 # InputMethodManagerService: adjust grip mode for input enable/disable

repopick 198593 # fw/base: Enable home button wake

repopick 199357 # FMRadio: fix missing libfmjni and include liblog
repopick 198902 # Remove include for dtbhtool
#repopick 199143 # macloader: Move device dependent modules to /vendor
#repopick 199144 # Revert "msm8x74: remove from top level makefile"
# hardware/qcom/display
repopick 199145 199146 199147
# Topic: samsung-libril-oreo
repopick -c 30 -Q 'status:open+topic:samsung-libril-oreo+branch:staging/lineage-15.1'
# Native and core updates
repopick 198955;
# Apps and UI updates
repopick -P packages/apps/Camera2 188389 188518-188526
repopick -P packages/apps/Gallery2 188527-188529
# WIP repopick -Q 'status:open+topic:android-o-mr1-camera-hal1';
# LineageOS Additions
repopick -c 30 -Q 'status:open+topic:oreo-visualizer+branch:staging/lineage-15.1'
repopick -c 30 -Q 'status:open+topic:oreo-tiles+branch:staging/lineage-15.1'
repopick -c 30 -Q 'status:open+topic:oreo-network-traffic+branch:staging/lineage-15.1'
