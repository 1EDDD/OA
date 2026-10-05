TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotifyLocalFiles

SpotifyLocalFiles_FILES = Tweak.xm
SpotifyLocalFiles_FRAMEWORKS = UIKit Foundation AVFoundation UniformTypeIdentifiers
SpotifyLocalFiles_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
