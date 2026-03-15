# Default recipe
default: build

# Build SWUINeovimMac (debug)
build:
    swift build --product SWUINeovimMac

# Build SWUINeovimMac (debug, explicit)
build-debug:
    swift build -c debug --product SWUINeovimMac

# Build SWUINeovimMac (release)
build-release:
    swift build -c release --product SWUINeovimMac

# Run SWUINeovimMac
run:
    swift run SWUINeovimMac

# Test entire workspace
test:
    swift test

# Stage debug app bundle
stage-debug:
    bash scripts/stage_swuineovimmac_app.sh debug

# Stage release app bundle
stage-release:
    bash scripts/stage_swuineovimmac_app.sh release

# Sign release app bundle
sign-release:
    bash scripts/sign_swuineovimmac_app.sh release

# Notarize release app bundle
notarize-release:
    bash scripts/notarize_swuineovimmac_app.sh release

# Store notarytool profile
store-notarytool-profile:
    bash scripts/create_notarytool_profile.sh

# Package signed release
package-signed:
    bash scripts/package_swuineovimmac_release.sh signed

# Package notarized release
package-notarized:
    bash scripts/package_swuineovimmac_release.sh notarized

# Build MsgPack package
build-msgpack:
    cd Packages/MsgPack && swift build

# Build MsgPack tests
build-msgpack-tests:
    cd Packages/MsgPack && swift build --build-tests

# Test MsgPack package
test-msgpack:
    cd Packages/MsgPack && swift test

# Build NvimRPC package
build-nvimrpc:
    cd Packages/NvimRPC && swift build

# Build NvimRPC tests
build-nvimrpc-tests:
    cd Packages/NvimRPC && swift build --build-tests

# Test NvimRPC package
test-nvimrpc:
    cd Packages/NvimRPC && swift test
