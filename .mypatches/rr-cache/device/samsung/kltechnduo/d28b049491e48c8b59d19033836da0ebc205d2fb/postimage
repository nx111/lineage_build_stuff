/*
   Copyright (c) 2013, The Linux Foundation. All rights reserved.
   Copyright (c) 2017, The LineageOS Project. All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions are
   met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of The Linux Foundation nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED
   WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT
   ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS
   BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
   CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
   BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
   WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
   OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
   IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <stdlib.h>
#include <stdio.h>

#include <android-base/logging.h>
#include <android-base/properties.h>

#include "property_service.h"
#include "vendor_init.h"

#include "init_msm8974.h"

using android::base::GetProperty;
using android::init::property_set;

void set_rild_libpath(char const *variant)
{
    std::string libpath("/system/vendor/lib/libsec-ril.");
    libpath += variant;
    libpath += ".so";

    property_override("rild.libpath", libpath.c_str());
}

void gsm_properties(char const default_network[],
        char const *rild_lib_variant)
{
    set_rild_libpath(rild_lib_variant);

    property_set("telephony.lteOnGsmDevice", "1");
    property_set("ro.telephony.default_network", default_network);
}

void cdma_properties(char const default_cdma_sub[], char const operator_numeric[],
        char const operator_alpha[],
        char const default_network[],
        char const *rild_lib_variant)
{
    set_rild_libpath(rild_lib_variant);

    property_set("ril.subscription.types", "NV,RUIM");
    property_set("ro.cdma.home.operator.numeric", operator_numeric);
    property_set("ro.cdma.home.operator.alpha", operator_alpha);
    property_set("ro.telephony.default_cdma_sub", default_cdma_sub);
    property_set("ro.telephony.default_network", default_network);
    property_set("telephony.lteOnCdmaDevice", "1");
}

void init_target_properties()
{
    std::string platform = GetProperty("ro.board.platform", "");
    if (platform != ANDROID_TARGET)
        return;

    std::string bootloader = GetProperty("ro.bootloader", "");

    if (bootloader.find("G9006W") == 0) {
        /* klteduoszn */
        property_override("ro.build.fingerprint", "samsung/klteduoszn/klteduoszn:6.0.1/MMB29M/G9006WZNU1CPJ2:user/release-keys");
        property_override("ro.build.description", "klteduoszn-user 6.0.1 MMB29M G9006WZNU1CPJ2 release-keys");
        property_override("ro.product.model", "SM-G9006W");
        property_override("ro.product.device", "klteduoszn");
        gsm_properties("9", "06w");
    } else if (bootloader.find("G9008W") == 0) {
        /* klteduoszm */
        property_override("ro.build.fingerprint", "samsung/klteduoszm/klte:6.0.1/MMB29M/G9008WZMU1CQB1:user/release-keys");
        property_override("ro.build.description", "klteduoszm-user 6.0.1 MMB29M G9008WZMU1CQB1 release-keys");
        property_override("ro.product.model", "SM-G9008W");
        property_override("ro.product.device", "klte");
        gsm_properties("17", "06w");
    } else if (bootloader.find("G9009W") == 0) {
        /* klteduosctc */
        property_override("ro.build.fingerprint", "samsung/klteduosctc/klte:6.0.1/MMB29M/G9009WKEU1CQB2:user/release-keys");
        property_override("ro.build.description", "klteduosctc-user 6.0.1 MMB29M G9009WKEU1CQB2 release-keys");
        property_override("ro.product.model", "SM-G9009W");
        property_override("ro.product.device", "klte");
        property_set("gsm.current.vsid", "0");
        property_set("gsm.current.vsid2", "1");
        cdma_properties("0", "46003", "中国电信", "10", "09w");
    } 

    std::string device = GetProperty("ro.product.device", "");
    LOG(ERROR) << "Found bootloader id " << bootloader <<  " setting build properties for "
        << device <<  " device" << std::endl;
}

