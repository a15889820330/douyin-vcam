# 编译成普通动态库（不是越狱 tweak，所以不需要 substrate / ellekit）
TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
DEBUG = 0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = DouyinVCam
DouyinVCam_FILES = VCam.m
DouyinVCam_CFLAGS = -fobjc-arc -fblocks -O2 -Wno-deprecated-declarations
DouyinVCam_FRAMEWORKS = Foundation UIKit AVFoundation CoreImage CoreMedia CoreVideo ImageIO
DouyinVCam_LIBRARIES =

include $(THEOS_MAKE_PATH)/library.mk
