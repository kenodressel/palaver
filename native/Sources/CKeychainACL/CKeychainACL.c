#include "CKeychainACL.h"
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

CFTypeRef palaver_access_trusting(CFArrayRef paths, CFStringRef label) {
    CFMutableArrayRef trusted = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (trusted == NULL) return NULL;
    SecTrustedApplicationRef me = NULL;
    if (SecTrustedApplicationCreateFromPath(NULL, &me) == errSecSuccess && me != NULL) {
        CFArrayAppendValue(trusted, me);
        CFRelease(me);
    }
    char buffer[PATH_MAX * 2];
    for (CFIndex i = 0; i < CFArrayGetCount(paths); i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(paths, i);
        if (CFGetTypeID(item) != CFStringGetTypeID()) continue;
        if (!CFStringGetFileSystemRepresentation((CFStringRef)item, buffer, sizeof buffer)) continue;
        SecTrustedApplicationRef app = NULL;
        if (SecTrustedApplicationCreateFromPath(buffer, &app) == errSecSuccess && app != NULL) {
            CFArrayAppendValue(trusted, app);
            CFRelease(app);
        }
    }
    SecAccessRef access = NULL;
    OSStatus status = SecAccessCreate(label, trusted, &access);
    CFRelease(trusted);
    return status == errSecSuccess ? (CFTypeRef)access : NULL;
}

CFTypeRef palaver_keychain_create(const char *path, const char *password, OSStatus *status) {
    SecKeychainRef keychain = NULL;
    *status = SecKeychainCreate(path, (UInt32)strlen(password), password, false, NULL, &keychain);
    if (*status == errSecSuccess) {
        *status = SecKeychainUnlock(keychain, (UInt32)strlen(password), password, true);
    }
    if (*status != errSecSuccess && keychain != NULL) {
        SecKeychainDelete(keychain);
        CFRelease(keychain);
        return NULL;
    }
    return keychain;
}

OSStatus palaver_update_without_asking(CFDictionaryRef query, CFDictionaryRef attributes) {
    CFMutableDictionaryRef q = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (q == NULL) return errSecAllocate;
    CFDictionarySetValue(q, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
    OSStatus status = SecItemUpdate(q, attributes);
    CFRelease(q);
    return status;
}

OSStatus palaver_keychain_delete(CFTypeRef keychain) {
    return SecKeychainDelete((SecKeychainRef)keychain);
}

#pragma clang diagnostic pop
