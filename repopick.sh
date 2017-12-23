#!/bin/bash
source build/envsetup.sh
branch_reset=0
patch_diff=0
save_patch=0

########## main ###################

for op in $*; do
    [ "$op" = "-p" ] && patch_diff=1
    [ "$op" = "-r" ] && branch_reset=1
    [ "$op" = "-s" ] && save_patch=1
    if [ "$op" = "-rp" -o "$op" = "-pr" ]; then
        patch_diff=1
        branch_reset=1
    fi
done

##### apply patch saved first ########
function patch_saved()
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
function reset_branches()
{
    cd $(gettop)
    topdir=$(gettop)
    default_branch=$(cat .repo/manifest.xml | grep "default revision" | cut -d= -f2 | sed -e "s/\"//g" -e "s/refs\/heads\///")

    find .mypatches -type d | sed -e "s/\.mypatches\///" |sort -n | while read project; do
         [ "$f" = ".mypatches" ] && continue
         if ! grep -q "^$project\$" $topdir/.repo/project.list; then
              continue
         fi
         rm -rf $topdir/.mypatches/$project/*

         cd $topdir/$project
         echo ""
         echo "==== reset $project to $basebranch "
         basebranch=$(git branch -a | grep '\->' | grep "$default_branch" | sed -e "s/.*\-> //")
         basecommit=$(git log --pretty=short -1 $basebranch | sed -n 1p | cut -d' ' -f2)
         git reset --hard $basecommit
    done
    cd $topdir
}

function save_patches()
{
    cd $(gettop)
    topdir=$(gettop)
    default_branch=$(cat .repo/manifest.xml | grep "default revision" | cut -d= -f2 | sed -e "s/\"//g" -e "s/refs\/heads\///")

    find .mypatches -type d | sed -e "s/\.mypatches\///" |sort -n | while read project; do
         [ "$f" = ".mypatches" ] && continue
         if ! grep -q "^$project\$" $topdir/.repo/project.list; then
              continue
         fi
         rm -rf $topdir/.mypatches/$project/*

         cd $topdir/$project
         echo ""
         echo "==== save patches for $project: "
         basebranch=$(git branch -a | grep '\->' | grep "$default_branch" | sed -e "s/.*\-> //")
         git format-patch "$basebranch" -o $(gettop)/.mypatches/$project/
    done
    cd $topdir
}

if [ $# -gt 1 ]; then
   [ $save_patch -eq 1 ] && save_patches
   [ $branch_reset -eq 1 ] && reset_branches
   [ $patch_diff -eq 1 ] && patch_saved
   exit 0
fi

######################################


# fw/base: Enable home button wake
repopick 191580;

# hardware/qcom/audio
repopick 196377;

# hardware/qcom/display
repopick 196378 196379 196380 196381;

# hardware/qcom/gps
repopick 185675 # Revert "msm8974: deprecate msm8974"
repopick 185676 # Revert "msm8974: remove from top level makefile"
repopick 187702 # msm8974: Add missing liblog dependency

# hardware/qcom/media
repopick 185806 # mm-video: venc: Correct a typo in variable name

# Topic: samsung-libril-oreo
repopick -c 30 -Q 'status:open+topic:samsung-libril-oreo+branch:lineage-15.0'; ## https://review.lineageos.org/#/q/status:open+topic:samsung-libril-oreo

# macloader: Move device dependent modules to /vendor
repopick 195655;

# Recovery updates
repopick 187155; ## https://review.lineageos.org/#/c/187155 [WIP]

# Native and core updates
repopick -f 185639 # Restore android_alarm.h kernel uapi header
repopick 185671; ## https://review.lineageos.org/#/c/185671 [Review]
repopick 185888 187146; ## https://review.lineageos.org/#/q/change:185888+OR+change:187146 [DNM]
repopick 190614 # linker: allow the linker to shim executables

# Apps and UI updates
repopick 188389 188518-188526; ## https://review.lineageos.org/#/q/project:LineageOS/android_packages_apps_Camera2+branch:lineage-15.0 [Review]
repopick 188527-188529; ## https://review.lineageos.org/#/q/project:LineageOS/android_packages_apps_Gallery2+branch:lineage-15.0 [Review]

# Camera HAL1
repopick -Q 'status:open+topic:android-o-camera-hal1+branch:lineage-15.0'; ## https://review.lineageos.org/#/q/status:open+topic:android-o-camera-hal1+branch:lineage-15.0 [WIP]

# LineageOS Additions
repopick -f -c 30 197655
repopick -c 30 -Q 'status:open+topic:oreo-powermenu+branch:lineage-15.0'; ## https://review.lineageos.org/#/q/status:open+topic:oreo-powermenu+branch:lineage-15.0 [ToFinish]
repopick -c 30 193025 193758; ## https://review.lineageos.org/#/q/change:193025 [ToMerge]
repopick -f -c 30 197765; ## https://review.lineageos.org/#/q/change:197765 [ToMerge]
repopick -c 30 191736 193029-193031 193033 193026 193027 193032; ## https://review.lineageos.org/#/q/change:191736+OR+change:193029+OR+change:193030+OR+change:193031+OR+change:193033+OR+change:193026+OR+change:193027+OR+change:193032 [ToMerge]
repopick -c 30 193758 193249 193258; ## https://review.lineageos.org/#/q/change:193758+OR+change:193249+OR+change:193258 [Review]
repopick 193544 193770; ## https://review.lineageos.org/#/q/change:193544+OR+change:193770 [ToFinish]
