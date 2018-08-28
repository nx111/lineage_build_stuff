#!/usr/bin/env bash

adb shell 'echo "persist.service.adb.enable=1" >> default.prop'
adb shell 'echo "persist.service.debuggable=1" >> default.prop'
adb shell 'echo "persist.sys.usb.config=mtp,adb" >> default.prop'
adb shell 'echo "persist.service.adb.enable=1" >> /system/build.prop'
adb shell 'echo "persist.service.debuggable=1" >> /system/build.prop'
adb shell 'echo "persist.sys.usb.config=mtp,adb" >> /system/build.prop'
adb push ~/.android/adbkey.pub /data/misc/adb/adb_keys
