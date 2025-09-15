THEOS_PACKAGE_SCHEME=rootless
FINALPACKAGE=1
INSTALL_TARGET_PROCESSES = YouTube

ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YouStopRotatingUpsideDownForFucksSake
$(TWEAK_NAME)_FILES = $(shell find sources -name "*.x*" -o -name "*.m*")
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"$(THEOS_PACKAGE_BASE_VERSION)"' -I$(THEOS_PROJECT_DIR)/headers
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	find $(THEOS_STAGING_DIR) -name ".DS_Store" -delete
