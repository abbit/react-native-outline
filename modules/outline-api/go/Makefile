PACKAGE_NAME := "OutlineApiGo"

.PHONY: bind
bind:
	@echo "Building Go bindings..."
	@echo "Building for Android..."
	@mkdir -p ../android/libs
	@gomobile bind -target=android -o=../android/libs/${PACKAGE_NAME}.aar
	@echo "Building for iOS..."
	@gomobile bind -target=ios -o=../ios/${PACKAGE_NAME}.xcframework
	@mkdir -p ../ios/${PACKAGE_NAME}Headers
	@cp ../ios/${PACKAGE_NAME}.xcframework/ios-arm64/${PACKAGE_NAME}.framework/Headers/*.h ../ios/${PACKAGE_NAME}Headers
	@echo "Done."