// The WebRTC echo canceller (libraven_aec, palaver/_vendored/webrtc_aec) is linked from its prebuilt archives
// (Package.swift's linker settings); its header is used from its own place (include/module.modulemap). SwiftPM
// needs a source file for the target: this one is empty.
