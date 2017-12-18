#!/bin/bash
source build/envsetup.sh

##### apply patch saved first ########
function patch_saved()
{
    cd $(gettop)
    topdir=$(gettop)

    find .mypatches -type f | sed -e "s/\.mypatches\///" |sort -n | while read f; do
         patchfile=$(basename $f)
         project=$(echo $f | sed "s/\/[^\/]*$//")
         if [ "$f" != "$project" ]; then
             if [ `pwd` != "$topdir/$project" ]; then
                  cd $topdir/$project
                  echo ""
                  echo "==== try apply to $project: "
                  rm -rf .git/rebase-apply
                  basebranch=$(git branch -a | grep '\->' | sed -n 1p | sed -e "s/.*\-> //")
                  basecommit=$(git log --pretty=short -1 $basebranch | sed -n 1p | cut -d' ' -f2)
                  git reset --hard $basecommit
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

if [ $# -ge 1 -a "$1" = "-p" ]; then
    patch_saved
    exit 0
fi

######################################


# fw/base: Enable home button wake
#repopick 191580;

# hardware/qcom/audio
repopick 196377;

# hardware/qcom/display
repopick 196378 196379 196380 196381;

# hardware/qcom/gps
repopick 185676 # Revert "msm8974: remove from top level makefile"
repopick 185675 # Revert "msm8974: deprecate msm8974"

# hardware/qcom/media
repopick 185806 # mm-video: venc: Correct a typo in variable name

# Topic: samsung-libril-oreo
#repopick -t 'samsung-libril-oreo'; ## https://review.lineageos.org/#/q/status:open+topic:samsung-libril-oreo

# macloader: Move device dependent modules to /vendor
repopick 195655;

# system/bt
repopick 185858 # btm_inq: fix build with BTA_HOST_INTERLEAVE_SEARCH

# Recovery updates
#repopick 186687; ## https://review.lineageos.org/#/c/186687 [DNM]
#repopick 187332 187374; ## https://review.lineageos.org/#/q/change:187332+OR+change:187374 [DNM]
#repopick 187155; ## https://review.lineageos.org/#/c/187155 [WIP]

# Native and core updates
repopick -f 185639 # Restore android_alarm.h kernel uapi header
repopick 185671; ## https://review.lineageos.org/#/c/185671 [Review]
repopick 185888 187146; ## https://review.lineageos.org/#/q/change:185888+OR+change:187146 [DNM]
repopick 190614 # linker: allow the linker to shim executables

# Apps and UI updates
repopick 188389 188518-188526; ## https://review.lineageos.org/#/q/project:LineageOS/android_packages_apps_Camera2+branch:lineage-15.0 [Review]
repopick 188527-188529; ## https://review.lineageos.org/#/q/project:LineageOS/android_packages_apps_Gallery2+branch:lineage-15.0 [Review]
repopick -c 30 193830; ## https://review.lineageos.org/#/q/change:193830 [ToFinish]

# Camera HAL1
repopick -Q 'status:open+topic:android-o-camera-hal1'; ## https://review.lineageos.org/#/q/status:open+topic:android-o-camera-hal1 [WIP]

# LineageOS Additions
repopick 191921 187592; ## https://review.lineageos.org/#/q/change:191921+OR+change:187592 [ToFinish]
repopick -c 30 -Q 'status:open+topic:oreo-powermenu'; ## https://review.lineageos.org/#/q/status:open+topic:oreo-powermenu [ToFinish]
repopick -c 30 193025 191736; ## https://review.lineageos.org/#/q/change:193025+OR+change:191736 [ToMerge]
repopick -c 30 -Q 'status:open+topic:oreo-tiles'; ## https://review.lineageos.org/#/q/status:open+topic:oreo-tiles [ToFinish]
repopick -c 30 191940 193758 193249 193258 191905; ## https://review.lineageos.org/#/q/change:191940+OR+change:193758+OR+change:193249+OR+change:193258+OR+change:191905 [Review]
repopick 193544 193770; ## https://review.lineageos.org/#/q/change:193544+OR+change:193770 [ToFinish]
repopick -c 30 -Q 'status:open+topic:dt2s'; ## https://review.lineageos.org/#/q/status:open+topic:dt2s [Review]
repopick -c 30 -Q 'status:open+topic:oreo-network-traffic'; ## https://review.lineageos.org/#/q/status:open+topic:oreo-network-traffic [ToFinish]
repopick -c 30 -Q 'status:open+topic:oreo-proximity-check'; ## https://review.lineageos.org/#/q/status:open+topic:oreo-proximity-check [Review]

