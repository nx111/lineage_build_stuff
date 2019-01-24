/*
 * Copyright (C) 2018-2019 The LineageOS Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <dlfcn.h>

#include "Constants.h"
#include "DisplayModes.h"
#include "PictureAdjustment.h"
#include "Types.h"

namespace vendor {
namespace lineage {
namespace livedisplay {
namespace V2_0 {
namespace sdm {

DisplayModes::DisplayModes(void* libHandle, uint64_t cookie) {
    mLibHandle = libHandle;
    mCookie = cookie;
    mCurrentModeId = -1;
    disp_api_get_feature_version =
        reinterpret_cast<int32_t (*)(uint64_t, uint32_t, void*, uint32_t*)>(
            dlsym(mLibHandle, "disp_api_get_feature_version"));
    disp_api_get_num_display_modes =
        reinterpret_cast<int32_t (*)(uint64_t, uint32_t, int32_t, int32_t*, uint32_t*)>(
            dlsym(mLibHandle, "disp_api_get_num_display_modes"));
    disp_api_get_display_modes =
        reinterpret_cast<int32_t (*)(uint64_t, uint32_t, int32_t, void*, int32_t, uint32_t*)>(
            dlsym(mLibHandle, "disp_api_get_display_modes"));
    disp_api_set_active_display_mode =
        reinterpret_cast<int32_t (*)(uint64_t, uint32_t, int32_t, uint32_t)>(
            dlsym(mLibHandle, "disp_api_set_active_display_mode"));
    disp_api_get_default_display_mode =
        reinterpret_cast<int32_t (*)(uint64_t, uint32_t, int32_t*, uint32_t*)>(
            dlsym(mLibHandle, "disp_api_get_default_display_mode"));
    disp_api_set_default_display_mode =
        reinterpret_cast<int32_t (*)(uint64_t, uint32_t, int32_t, uint32_t)>(
            dlsym(mLibHandle, "disp_api_set_default_display_mode"));

    if (isSupported()) {
        DisplayMode mode = getDefaultDisplayModeInternal();
        if (mode.id > 0) {
            setDisplayMode(mode.id, false);
        }
    }
}

bool DisplayModes::isSupported() {
    sdm_feature_version version{};
    int32_t count = 0;
    uint32_t flags = 0;

    if (disp_api_get_feature_version == nullptr ||
        disp_api_get_feature_version(mCookie, DISPLAY_MODES_FEATURE, &version, &flags) != 0) {
        return false;
    }

    if (version.x <= 0 && version.y <= 0 && version.z <= 0) {
        return false;
    }

    if (disp_api_get_num_display_modes != nullptr) {
        if (disp_api_get_num_display_modes(mCookie, 0, 0, &count, &flags) == 0) {
            return count > 0;
        }
    }

    return false;
}

std::vector<DisplayMode> DisplayModes::getDisplayModesInternal() {
    std::vector<DisplayMode> modes;
    int32_t count = 0;
    uint32_t flags = 0;

    if (disp_api_get_num_display_modes == nullptr ||
        disp_api_get_num_display_modes(mCookie, 0, 0, &count, &flags) != 0) {
        return modes;
    }

    if (disp_api_get_display_modes != nullptr) {
        sdm_disp_mode* tmp = new sdm_disp_mode[count];
        for (int i = 0; i < count; i++) {
            tmp[i].id = -1;
            tmp[i].name = new char[128];
            tmp[i].len = 128;
        }

        if (disp_api_get_display_modes(mCookie, 0, 0, tmp, count, &flags) == 0) {
            for (int i = 0; i < count; i++) {
                modes.push_back(DisplayMode{tmp[i].id, std::string(tmp[i].name, tmp[i].len)});
                delete[] tmp[i].name;
            }
        } else {
            for (int i = 0; i < count; i++) {
                delete[] tmp[i].name;
            }
        }

        delete[] tmp;
    }

    return modes;
}

DisplayMode DisplayModes::getDisplayModeById(int32_t id) {
    std::vector<DisplayMode> modes = getDisplayModesInternal();

    for (const DisplayMode& mode : modes) {
        if (mode.id == id) {
            return mode;
        }
    }

    return DisplayMode{-1, ""};
}

DisplayMode DisplayModes::getDefaultDisplayModeInternal() {
    int32_t id = 0;
    uint32_t flags = 0;

    if (disp_api_get_default_display_mode != nullptr) {
        if (disp_api_get_default_display_mode(mCookie, 0, &id, &flags) == 0 && id >= 0) {
            return getDisplayModeById(id);
        }
    }

    return DisplayMode{-1, ""};
}

// Methods from ::vendor::lineage::livedisplay::V2_0::IDisplayModes follow.
Return<void> DisplayModes::getDisplayModes(getDisplayModes_cb _hidl_cb) {
    _hidl_cb(getDisplayModesInternal());
    return Void();
}

Return<void> DisplayModes::getCurrentDisplayMode(getCurrentDisplayMode_cb _hidl_cb) {
    _hidl_cb(getDisplayModeById(mCurrentModeId));
    return Void();
}

Return<void> DisplayModes::getDefaultDisplayMode(getDefaultDisplayMode_cb _hidl_cb) {
    _hidl_cb(getDefaultDisplayModeInternal());
    return Void();
}

Return<bool> DisplayModes::setDisplayMode(int32_t modeID, bool makeDefault) {
    if (mCurrentModeId >= 0 && mCurrentModeId == modeID) {
        return true;
    }

    DisplayMode mode = getDisplayModeById(modeID);
    if (mode.id < 0) {
        return false;
    }

    if (disp_api_set_active_display_mode == nullptr ||
        disp_api_set_active_display_mode(mCookie, 0, modeID, 0)) {
        return false;
    }

    if (makeDefault && (disp_api_set_default_display_mode == nullptr ||
                        disp_api_set_default_display_mode(mCookie, 0, modeID, 0))) {
        return false;
    }

    mCurrentModeId = modeID;

    PictureAdjustment::updateDefaultPictureAdjustment();

    return true;
}

}  // namespace sdm
}  // namespace V2_0
}  // namespace livedisplay
}  // namespace lineage
}  // namespace vendor
