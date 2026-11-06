"""Build and install ``Palaver.app`` — the menu bar app as a real macOS app
that can start at login.

A release (``build_release_app``, #60) is the native app: its executable
``Palaver`` is the Swift app (native/, phase 2), which records, runs the
daemon and the window, and starts Palaver's Python workers through the
bundle's Python host ``palaver-python`` (this app's code on its runtime).
macOS asks for the microphone and system audio under "Palaver" with the
usage texts below. ``PALAVER_LEGACY_APP=1`` (or the ``legacy-app`` marker in
Application Support) makes the Swift app start the Python menu bar app
(``palaver-python -m palaver menubar``) instead, for one release.

``install`` (``palaver app install`` from a checkout) still builds the
development bundle of before: a tiny compiled launcher spawns this venv's
``python -m palaver menubar`` as a *child* process, so macOS attributes its
microphone / system-audio access to the app. Rebuild after moving the venv;
ad-hoc signing means macOS may ask for permissions again after a rebuild.
The app was called "Meeting Transcribe" before; the bundle id stays, so
macOS keeps what was allowed.
"""

from __future__ import annotations

import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from . import __version__
from .daemon import LOG_PATH

APP_NAME = "Palaver"
OLD_APP_NAMES = ["Meeting Transcribe"]
ICON = Path(__file__).parent / "assets" / "Palaver.icns"
BUNDLE_ID = "com.kenodressel.meeting-transcribe"
EXECUTABLE = "Palaver"  # a release's executable: the Swift app (native/.build/release/Palaver)
LAUNCHER = "palaver-launcher"  # the development bundle's executable (``install``): the ObjC launcher below
MENUBAR_ICON = Path(__file__).parent / "assets" / "menubar.png"  # the Swift app's menu bar icon, in Contents/Resources
APPS_DIR = Path.home() / "Applications"
LAUNCH_AGENT = Path.home() / "Library" / "LaunchAgents" / f"{BUNDLE_ID}.plist"
APP_LOG = LOG_PATH.with_name("app.log")

# Released apps (#60) carry Palaver's code in Contents/Resources/python and
# run it on the runtime of their build, found by its id relative to the
# user's home at runtime; "~/" paths are resolved by the launcher from $HOME.
RELEASE_RUNTIMES = "~/Library/Application Support/palaver/runtime"
RELEASE_LOG = "~/Library/Logs/palaver/app.log"
CODE_DIR = "python"  # in Contents/Resources
INSTALL_COMMAND = "curl -fsSL https://raw.githubusercontent.com/kenodressel/palaver/master/install.sh | sh"


def release_python(runtime_id: str) -> str:
    return f"{RELEASE_RUNTIMES}/{runtime_id}/bin/python3"


def info_plist(runtime_id: str | None = None, executable: str = EXECUTABLE) -> dict:
    extra = {"PalaverRuntimeID": runtime_id} if runtime_id else {}
    return {**extra,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundleExecutable": executable,
        "CFBundleIconFile": ICON.name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": __version__,
        "CFBundleVersion": __version__,
        "LSMinimumSystemVersion": "15.0",
        "LSUIElement": True,  # menu bar only, no Dock icon
        "NSMicrophoneUsageDescription":
            "Palaver records your side of meetings to transcribe them locally.",
        "NSAudioCaptureUsageDescription":
            "Palaver records the other participants' audio to transcribe the meeting.",
        "NSCalendarsFullAccessUsageDescription":
            "Palaver reads a meeting's title and invitees from your calendar to name "
            "its speakers. Nothing is changed or sent anywhere.",
        "NSCalendarsUsageDescription":
            "Palaver reads a meeting's title and invitees from your calendar to name "
            "its speakers. Nothing is changed or sent anywhere.",
    }


def launch_agent_plist(app: Path) -> bytes:
    """Opens the app at login through LaunchServices, so it runs as the app
    (with its own permissions), not as a bare launchd job."""
    return plistlib.dumps({
        "Label": BUNDLE_ID,
        "ProgramArguments": ["/usr/bin/open", "-g", "-a", str(app)],
        "RunAtLoad": True,
    })


def _c_string(value: str) -> str:
    out = []
    for byte in value.encode("utf-8"):
        ch = chr(byte)
        if ch in '"\\':
            out.append("\\" + ch)
        elif 0x20 <= byte < 0x7F:
            out.append(ch)
        else:
            out.append(f"\\{byte:03o}")
    return '"' + "".join(out) + '"'


_LAUNCHER_C = r"""
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static pid_t child = 0;
static int app_end = -1;  /* our end of the socket to the app: clicks go there */
static char notify_path[104] = "";
static int log_fd = -1;  /* the app's log: the launcher's own lines too */
static char notify_state[120] = "";
static dispatch_source_t notify_timer;  /* kept: a released timer stops */  /* $PALAVER_NOTIFY_STATE: whether macOS lets the app notify */
static id notifier, notifications;  /* kept for the app's lifetime */

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

static char *home_path(const char *relative) {
    const char *home = getenv("HOME");
    if (home == NULL) home = "";
    size_t size = strlen(home) + strlen(relative) + 2;
    char *path = malloc(size);
    snprintf(path, size, "%%s/%%s", home, relative);
    return path;
}

static void make_parents(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(path, 0755);
            *p = '/';
        }
    }
}

/* Notifications are posted here, as this app, so clicking one opens
   Palaver (osascript's would open Script Editor). */
@interface Notifier : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation Notifier
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))done {
    done(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))done {
    NSString *meeting = response.notification.request.content.userInfo[@"open"];
    const char *line = [[NSString stringWithFormat:@"open %%@", meeting ?: @""] UTF8String];
    send(app_end, line, strlen(line), 0);
    done();
}
@end

static void post(NSDictionary *request) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = [request[@"title"] description] ?: @"";
    content.body = [request[@"message"] description] ?: @"";
    content.userInfo = @{@"open": [request[@"open"] description] ?: @""};
    UNNotificationRequest *note = [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString
                                                                       content:content
                                                                       trigger:nil];
    NSString *title = content.title, *body = content.body;
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:note withCompletionHandler:^(NSError *error) {
        if (!error) return;
        /* macOS doesn't let this app notify (a managed Mac may refuse every
           app it doesn't know): said once in the log, then shown through
           osascript, as Script Editor's; better than none. */
        static BOOL told = NO;
        if (!told && log_fd >= 0) {
            dprintf(log_fd, "notifications refused by macOS (%%s); showing them through osascript\n",
                    error.localizedDescription.UTF8String);
        }
        told = YES;
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments = @[@"-e", @"on run argv", @"-e", @"display notification (item 2 of argv) with title (item 1 of argv)",
                           @"-e", @"end run", title, body];
        [task launchAndReturnError:nil];
    }];
}

/* What macOS says now about this app's notifications, in $PALAVER_NOTIFY_STATE
   ("allowed", "denied", "not_asked"): Settings shows it, and how to allow them.
   Asked again every few seconds, so a change in System Settings shows soon. */
static void write_notify_state(void) {
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:
        ^(UNNotificationSettings *settings) {
            const char *state = settings.authorizationStatus == UNAuthorizationStatusNotDetermined ? "not_asked"
                : settings.authorizationStatus == UNAuthorizationStatusDenied ? "denied" : "allowed";
            char tmp[130];
            snprintf(tmp, sizeof tmp, "%%s.tmp", notify_state);
            FILE *f = fopen(tmp, "w");
            if (!f) return;
            fputs(state, f);
            fclose(f);
            rename(tmp, notify_state);
        }];
}

/* A datagram socket every process under the app finds through
   $PALAVER_NOTIFY: one JSON {title, message, open} per notification. */
static dispatch_source_t listen_for_notifications(void) {
    snprintf(notify_path, sizeof notify_path, "%%spalaver-%%d.sock",
             NSTemporaryDirectory().fileSystemRepresentation, getpid());
    int sock = socket(AF_UNIX, SOCK_DGRAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strlcpy(addr.sun_path, notify_path, sizeof addr.sun_path);
    unlink(notify_path);
    if (sock < 0 || bind(sock, (struct sockaddr *)&addr, sizeof addr) != 0) {
        notify_path[0] = 0;
        return nil;
    }
    fcntl(sock, F_SETFD, FD_CLOEXEC);
    setenv("PALAVER_NOTIFY", notify_path, 1);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char buffer[8192];
        ssize_t size = recv(sock, buffer, sizeof buffer, 0);
        if (size <= 0) return;
        id request = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:size]
                                                     options:0 error:nil];
        if ([request isKindOfClass:[NSDictionary class]]) post(request);
    });
    dispatch_resume(source);
    return source;
}

int main(void) {
    @autoreleasepool {
        char *args[] = { %(args)s, NULL };
        char *log_path = %(log)s;
        make_parents(log_path);
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        int log = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        log_fd = log;
        if (log >= 0) {
            posix_spawn_file_actions_adddup2(&actions, log, STDOUT_FILENO);
            posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO);
        }
        /* Only as the app (run outside a bundle there is no notification
           center); without it the app falls back to osascript. */
        BOOL bundled = NSBundle.mainBundle.bundleIdentifier != nil;
        int pair[2];
        if (bundled && socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) == 0) {
            app_end = pair[0];
            fcntl(pair[0], F_SETFD, FD_CLOEXEC);
            fcntl(pair[1], F_SETFD, FD_CLOEXEC);
            posix_spawn_file_actions_adddup2(&actions, pair[1], 3);
            setenv("PALAVER_LAUNCHER_FD", "3", 1);
            notifications = listen_for_notifications();
            notifier = [Notifier new];
            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            center.delegate = notifier;
            snprintf(notify_state, sizeof notify_state, "%%spalaver-%%d.notifications",
                     NSTemporaryDirectory().fileSystemRepresentation, getpid());
            setenv("PALAVER_NOTIFY_STATE", notify_state, 1);
            [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                                  completionHandler:^(BOOL granted, NSError *error) { write_notify_state(); }];
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC,
                                      NSEC_PER_SEC);
            dispatch_source_set_event_handler(timer, ^{ write_notify_state(); });
            dispatch_resume(timer);
            notify_timer = timer;
        }
        signal(SIGTERM, forward);
        signal(SIGINT, forward);
        signal(SIGHUP, forward);
        if (posix_spawn(&child, args[0], &actions, NULL, args, environ) != 0) return 127;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int status = 0;
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            if (notify_path[0]) unlink(notify_path);
            if (notify_state[0]) unlink(notify_state);
            if (WIFEXITED(status)) exit(WEXITSTATUS(status));
            exit(128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0));
        });
        if (bundled) {
            /* An app, so a click on a notification reaches the delegate. */
            [NSApplication sharedApplication];
            [NSApp run];
        }
        dispatch_main();
    }
}
"""


def _c_path(value: str) -> str:
    """C expression for a path; "~/..." is resolved from $HOME at runtime."""
    if value.startswith("~/"):
        return f"home_path({_c_string(value[2:])})"
    return f"strdup({_c_string(value)})"


ENGINE = "palaver-engine"  # in Contents/MacOS: the Swift speech engine (engine.py finds it there)
HOST = "palaver-python"  # in Contents/MacOS: the Python the Swift app runs its workers with, as Palaver.app

# The host: the runtime's libpython, loaded from the user's home at runtime
# (it is not known at build time), running this bundle's code. A program in
# Contents/MacOS has the bundle as its main bundle; the runtime's python3
# would have none. Children started with sys.executable are the host too.
# The Swift app starts every worker with it (and the legacy menu bar app).
_HOST_C = r"""
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    char exe[PATH_MAX], app[PATH_MAX], runtime[PATH_MAX], code[PATH_MAX], lib[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, app) == NULL) return 70;
    for (int i = 0; i < 3; i++) {  /* .../Palaver.app/Contents/MacOS/palaver-python -> .../Palaver.app */
        char *slash = strrchr(app, '/');
        if (slash) *slash = 0;
    }
    const char *home = getenv("HOME");
    snprintf(runtime, sizeof runtime, "%%s/Library/Application Support/palaver/runtime/%(runtime_id)s", home ? home : "");
    snprintf(code, sizeof code, "%%s/Contents/Resources/%(code)s", app);
    snprintf(lib, sizeof lib, "%%s/lib/libpython%(pyver)s.dylib", runtime);
    setenv("PYTHONHOME", runtime, 1);
    setenv("PYTHONPATH", code, 1);
    setenv("PALAVER_APP", app, 1);
    setenv("PYTHONNOUSERSITE", "1", 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);  /* the signed bundle is never written to */
    void *python = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
    if (python == NULL) {
        fprintf(stderr, "Palaver's runtime is missing (%%s). Run the installer again:\n  %(install)s\n", runtime);
        return 1;
    }
    int (*bytes_main)(int, char **) = (int (*)(int, char **))dlsym(python, "Py_BytesMain");
    if (bytes_main == NULL) {
        fprintf(stderr, "%%s has no Py_BytesMain\n", lib);
        return 70;
    }
    return bytes_main(argc, argv);
}
"""


def compile_host(path: Path, *, runtime_id: str, python_version: str) -> None:
    source = _HOST_C % {"runtime_id": runtime_id, "code": CODE_DIR, "pyver": python_version,
                        "install": INSTALL_COMMAND}
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "host.c"
        src.write_text(source)
        subprocess.run(["clang", "-O2", "-o", str(path), str(src)], check=True)


def sign_identity() -> str:
    """Ad hoc ("-") unless $PALAVER_SIGN_IDENTITY names a certificate: with
    one kept for every release, macOS keeps the microphone and system audio
    permissions across updates (an ad hoc signature differs every build)."""
    import os

    return os.environ.get("PALAVER_SIGN_IDENTITY") or "-"


def compile_launcher(
    path: Path,
    *,
    python: Path | str,
    cli_options: list[str],
    log_path: Path | str = APP_LOG,
) -> None:
    """The development bundle's launcher (``install``); a release has the Swift app instead."""
    argv = [str(python), "-m", "palaver", *cli_options, "menubar"]
    source = _LAUNCHER_C % {
        "args": ", ".join([_c_path(argv[0])] + [f"strdup({_c_string(a)})" for a in argv[1:]]),
        "log": _c_path(str(log_path)),
    }
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "launcher.m"
        src.write_text(source)
        subprocess.run(["clang", "-O2", "-fobjc-arc", "-framework", "AppKit",
                        "-framework", "UserNotifications", "-o", str(path), str(src)], check=True)


def _sign(app: Path) -> None:
    """Nested code first (everything in Contents/MacOS but the executable), then the bundle."""
    executable = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())["CFBundleExecutable"]
    for nested in sorted((app / "Contents" / "MacOS").iterdir()):
        if nested.name != executable:
            subprocess.run(["codesign", "--force", "--sign", sign_identity(), str(nested)], check=True,
                           capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", sign_identity(), str(app)], check=True, capture_output=True)


def _bundle(dest_dir: Path, *, executable: str, runtime_id: str | None = None) -> Path:
    app = dest_dir / f"{APP_NAME}.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    (app / "Contents" / "Resources").mkdir(exist_ok=True)
    shutil.copyfile(ICON, app / "Contents" / "Resources" / ICON.name)
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info_plist(runtime_id, executable)))
    return app


def build_app(
    dest_dir: Path,
    *,
    python: Path | str,
    cli_options: list[str],
    log_path: Path | str = APP_LOG,
) -> Path:
    """The development bundle (``install``): the launcher starting ``python -m palaver menubar``."""
    app = _bundle(dest_dir, executable=LAUNCHER)
    compile_launcher(app / "Contents" / "MacOS" / LAUNCHER, python=python, cli_options=cli_options, log_path=log_path)
    _sign(app)
    return app


# The Python other programs start (Claude Code's MCP server) and the
# command (~/.local/bin/palaver links to it): this app's code on its
# runtime. They find the app through their own path, so a link works.
_WRAPPER = """#!/bin/sh
# Palaver's Python: the app's host, on the runtime the app was built for.
exec "$(dirname "$(readlink -f "$0")")/../../MacOS/{host}" "$@"
"""
_COMMAND = """#!/bin/sh
exec "$(dirname "$(readlink -f "$0")")/../../MacOS/{host}" -m palaver "$@"
"""


def _install_code(app: Path, code: Path, runtime_id: str, version: str, compile_with: str | None,
                  python_version: str | None = None) -> None:
    """Palaver's package (``code``: the folder holding ``palaver/``, as a
    wheel unpacks) into the bundle, compiled ahead: the bundle is signed
    and never written to at runtime."""
    resources = app / "Contents" / "Resources"
    target = resources / CODE_DIR
    shutil.copytree(code, target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    if compile_with:
        subprocess.run([compile_with, "-m", "compileall", "-q", "--invalidation-mode", "unchecked-hash",
                        str(target)], check=True)
    (resources / "runtime.json").write_text(json.dumps({"version": version, "runtime": runtime_id}) + "\n")
    compile_host(app / "Contents" / "MacOS" / HOST, runtime_id=runtime_id,
                 python_version=python_version or ".".join(runtime_id.split(".")[:2]))
    bin_dir = resources / "bin"
    bin_dir.mkdir()
    for name, text in (("python", _WRAPPER), ("palaver", _COMMAND)):
        (bin_dir / name).write_text(text.format(host=HOST))
        (bin_dir / name).chmod(0o755)


def build_release_app(dest_dir: Path, *, runtime_id: str, code: Path, app_binary: Path,
                      version: str = __version__, compile_with: str | None = None,
                      python_version: str | None = None, engine: Path | None = None) -> Path:
    """The app a release publishes (#60): the Swift app (``app_binary``, the
    built ``Palaver``) as the executable, the host that runs Palaver's code
    as Palaver.app (``palaver-python``), the code, the command and the menu
    bar icon; the code runs on runtime ``runtime_id`` in Application Support.
    ``engine``: the built ``palaver-engine``. Every program sits in
    Contents/MacOS and is signed with the rest (nested code before the
    bundle)."""
    app = _bundle(dest_dir, executable=EXECUTABLE, runtime_id=runtime_id)
    macos = app / "Contents" / "MacOS"
    shutil.copyfile(app_binary, macos / EXECUTABLE)
    (macos / EXECUTABLE).chmod(0o755)
    shutil.copyfile(MENUBAR_ICON, app / "Contents" / "Resources" / MENUBAR_ICON.name)
    _install_code(app, code, runtime_id, version, compile_with, python_version)
    if engine is not None:
        shutil.copyfile(engine, macos / ENGINE)
        (macos / ENGINE).chmod(0o755)
    _sign(app)
    return app


def install(*, python: Path, cli_options: list[str], login: bool) -> Path:
    from .menubar import PERMISSIONS_MARKER

    APPS_DIR.mkdir(parents=True, exist_ok=True)
    _remove_old_apps()
    app = build_app(APPS_DIR, python=python, cli_options=cli_options)
    # A new build is a new signature to macOS, which asks for System Audio
    # Recording again: ask at the next launch, not during a meeting.
    PERMISSIONS_MARKER.unlink(missing_ok=True)
    if login or LAUNCH_AGENT.exists():  # an agent from before may open the old name
        set_autostart(True, app)
    return app


def set_autostart(enabled: bool, app: Path | None = None) -> None:
    """Start the app at login (LaunchAgent opening it via LaunchServices)."""
    if enabled:
        LAUNCH_AGENT.parent.mkdir(parents=True, exist_ok=True)
        LAUNCH_AGENT.write_bytes(launch_agent_plist(app or APPS_DIR / f"{APP_NAME}.app"))
    elif LAUNCH_AGENT.exists():
        LAUNCH_AGENT.unlink()


def store_tokens_in_keychain() -> list[str]:
    """Copy NOTION_TOKEN / HF_TOKEN from this shell into the login Keychain,
    where the config loader finds them when the app has no shell env."""
    import os

    import keyring

    from .config import KEYCHAIN_SERVICE

    stored = []
    for name in ("NOTION_TOKEN", "HF_TOKEN"):
        value = os.environ.get(name)
        if value:
            keyring.set_password(KEYCHAIN_SERVICE, name, value)
            stored.append(name)
    return stored


def _quit_and_remove(name: str) -> Path | None:
    app = APPS_DIR / f"{name}.app"
    if not app.exists():
        return None
    subprocess.run(["osascript", "-e", f'tell application "{name}" to quit'], check=False, capture_output=True)
    shutil.rmtree(app)
    return app


def _remove_old_apps() -> list[Path]:
    """The app under a name it had before: one bundle id, one app."""
    return [app for name in OLD_APP_NAMES if (app := _quit_and_remove(name))]


def uninstall() -> list[Path]:
    removed = []
    if LAUNCH_AGENT.exists():
        LAUNCH_AGENT.unlink()
        removed.append(LAUNCH_AGENT)
    if app := _quit_and_remove(APP_NAME):
        removed.append(app)
    return removed + _remove_old_apps()
