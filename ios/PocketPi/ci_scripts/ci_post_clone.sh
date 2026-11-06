#!/bin/sh
# Xcode Cloud runs this right after cloning, before it looks for the project.
# The .xcodeproj is generated from project.yml rather than committed.
set -e
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH/ios/PocketPi"
xcodegen generate
