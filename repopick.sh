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
                   changeid=$(grep "Change-Id: " $patchfile | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
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
             changeid=$(grep "Change-Id: " $topdir/.mypatches/$f | tail -n 1 | sed -e "s/ \{1,\}/ /g" -e "s/^ //g" | cut -d' ' -f2)
             if [ "$changeid" != "" ]; then
                  if ! git log  -100 | grep "Change-Id: $changeid" >/dev/null 2>/dev/null; then 
                      echo "         apply patch: $f ..."
                      git am -3 -q < $topdir/.mypatches/$f
                      [ $? -ne 0 ] && exit -1
                  else
                      echo "         skip  patch: $f ...(applied always)"
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
    LANG=en_US repopick -c 20 $* >$logfile 2>$errfile
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
kpick 199946 # [DNM] klte-common: sepolicy: Rewrite for O
kpick 201051 # klte-common: Move charger service into the charger domain
kpick 202457 # klte-common: HAXX: Fix seeming RIL start race condition

# device/samsung/kltechnduo
kpick 200524 # kltechnduo: Rework launch of second RIL daemon
kpick 200736 # kltechnduo: Use rild2.libpath property for ril-daemon2

# device/samsung/msm8974
kpick 200538 # msm8974-common: Use QTI power hal

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
kpick 199572 # sepolicy: SELinux policy for persistent properties API
kpick 201552 # Squashed import of superuser SELinux policies
kpick 201582 # sepolicy: adapt sudaemon policy for O


# device/qcom/common
kpick 201274 # power: Update power hal extension for new qti hal

# device/qcom/sepolicy
kpick 198620 # sepolicy: Let keystore load firmware
kpick 198141 # Use set_prop() macro for property sets
kpick 202377 # Revert "sepolicy: Address netmgrd denials on non-fully trebelized devices"
kpick 202378 # legacy: add back perfd sepolicy 
kpick 202379 # legacy: add back radio rules
kpick 202380 # legacy: add back nfc rules
kpick 202381 # legacy: add back rules for non-treble devices
kpick 202382 # legacy: allow rmt_storage sys_admin capability
kpick 202383 # legacy: let rfs_access do msm ipc ioctls
kpick 202384 # legacy: label old hardcoded data paths
kpick 202385 # legacy: label old msm_irqbalance prop
kpick 202386 # legacy: add back ipacm rules
kpick 202387 # legacy: add back imscm support into ims
kpick 202388 # legacy: allow rild to access radio data files
kpick 202389 # legacy: Fix labeling the thermal sockets
kpick 202390 # legacy: let audioserver connect to thermal engine sockets
kpick 202391 # legacy: label per_mgr as a binder service

kpick 198303 # sepolicy: Add sysfs labels for devices using 'soc.0'
kpick 199559 # sepolicy: Allow dataservice_app to read/write to IPA device
kpick 199564 # sepolicy: Allow energyawareness to read sysfs files

# frameworks/base
kpick 199947 # PowerManager: Re-integrate button brightness
kpick 200968 # statusbar: Add arguments to shutdown and reboot to allow confirmation
kpick 200969 # SystemUI: Power menu customizations
kpick 201879 # frameworks: Privacy Guard for O
#kpick 202423 # Screenshot: append app name to filename

# frameworks/native
kpick 201530 # AppOpsManager: Update with the new ops
kpick 201893 # sensor: Skip additional permission request checks

# hardware/samsung
kpick 200068 # AdvancedDisplay: cyanogenmod -> lineageos

# hardware/qcom/power
kpick 201924 # power: Fix up some legacy stats code

# lineage-sdk
kpick 200970 # sdk: Move isAdvancedRebootEnabled to SDK from global access
kpick 201311 # lineage-sdk: Add broadcast action for power menu update
kpick 202152 # lineage-sdk: Add config to define camera key type

# packages/apps/Dialer
kpick 201346 # Re-add dialer lookup.
kpick 201634 # Allow using private framework API. 
kpick 201337 # Dialer: disable anti-falsing for call answer screen

# packages/apps/LineageParts
#kpick 200069 # LineageParts: Deprecate few button settings
#kpick 199198 # LineageParts: Bring up buttons settings
kpick 199948 # LineageParts: Bring up button backlight settings
kpick 201309 # LineageParts: Re-enable PowerMenuActions and adapt to SDK updates
kpick 201528 # PrivacyGuard: Bring up and inject into Settings

# packages/apps/Settings
#kpick 200113 # Settings: Add kill app back button toggle
kpick 199839 # Settings: Add advanced restart switch
kpick 201529 # Settings: Privacy Guard
kpick 201531 # Settings: Add developer setting for root access

# system/extra/su
kpick 201990 # su: Remove EUID vs UID check
# kpick 202051 # rc: Ensure su binary is world executable

# system/sepolicy
kpick 199664 # sepolicy: Fix up exfat and ntfs support
kpick 201553 # sepolicy: We need to declare before referencing
kpick 201732 # sepilocy: add sudaemon to ignore list
kpick 201583 # sepolicy: Allow su by apps on userdebug_or_eng
kpick 201584 # sepolicy: update policies for sudaemon on O

#vendor/lineage
kpick 201931 # overlay: Disable SystemUI anti-falsing on lockscreen

##################################

[ $op_pick_remote_only -eq 0 ] && patch_local local

