// The legacy (file-based) Keychain calls Palaver needs and Swift can only reach through deprecated API: an access list
// that trusts several executables, an update that never asks the user, and a throwaway keychain file for tests. Deprecated since macOS 10.10, still the
// only way to do either for the login keychain, which is where the Python app's keys already are.
#ifndef CKEYCHAINACL_H
#define CKEYCHAINACL_H

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

CF_ASSUME_NONNULL_BEGIN

/// A SecAccessRef (as a CFTypeRef, to go into kSecAttrAccess) named `label` whose decrypt entry trusts the calling
/// executable and each of `paths` (CFStrings; one that cannot be read is skipped). NULL when it cannot be made.
/// The caller releases it.
CFTypeRef _Nullable palaver_access_trusting(CFArrayRef paths, CFStringRef label) CF_RETURNS_RETAINED;

/// SecItemUpdate(`query`, `attributes`) that never asks the user (kSecUseAuthenticationUIFail, deprecated in Swift):
/// an update that would need the user fails with a status instead.
OSStatus palaver_update_without_asking(CFDictionaryRef query, CFDictionaryRef attributes);

/// A new keychain file at `path`, unlocked with `password`, never shown to the user: a SecKeychainRef (as a CFTypeRef),
/// NULL with `*status` set when it could not be made. Tests only.
CFTypeRef _Nullable palaver_keychain_create(const char *path, const char *password, OSStatus *status) CF_RETURNS_RETAINED;

/// Deletes the keychain file `keychain` (from palaver_keychain_create).
OSStatus palaver_keychain_delete(CFTypeRef keychain);

CF_ASSUME_NONNULL_END

#endif
