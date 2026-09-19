ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = BiliBili

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiliDanmaku120
BiliDanmaku120_FILES = Tweak.xm
BiliDanmaku120_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
BiliDanmaku120_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
