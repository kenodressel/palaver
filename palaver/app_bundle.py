"""Build and install ``Palaver.app`` — the menu bar app as a real macOS app
that can start at login.

The bundle holds no Python: a tiny compiled launcher spawns this venv's
``python -m palaver menubar`` as a *child* process. macOS
attributes a child's microphone / system-audio access to the app
that launched it, so permissions are asked for — and remembered — under
"Palaver" with the usage texts below. (``exec`` would make the
process the Python binary itself and lose that.) Rebuild after moving the
venv; ad-hoc signing means macOS may ask for permissions again after a
rebuild. The app was called "Meeting Transcribe" before; the bundle id stays,
so macOS keeps what was allowed.
"""

from __future__ import annotations

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
EXECUTABLE = "palaver-launcher"
APPS_DIR = Path.home() / "Applications"
LAUNCH_AGENT = Path.home() / "Library" / "LaunchAgents" / f"{BUNDLE_ID}.plist"
APP_LOG = LOG_PATH.with_name("app.log")

# Released apps (built in CI, installed by install.sh) find their venv and
# log relative to the user's home at runtime; "~/" paths are resolved by
# the launcher from $HOME.
RELEASE_VENV = "~/Library/Application Support/palaver/venv"
RELEASE_PYTHON = f"{RELEASE_VENV}/bin/python"
RELEASE_LOG = "~/Library/Logs/palaver/app.log"


def info_plist() -> dict:
    return {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundleExecutable": EXECUTABLE,
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
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:note withCompletionHandler:nil];
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
            [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                                  completionHandler:^(BOOL granted, NSError *error) {}];
        }
        signal(SIGTERM, forward);
        signal(SIGINT, forward);
        signal(SIGHUP, forward);
        if (posix_spawn(&child, args[0], &actions, NULL, args, environ) != 0) return 127;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int status = 0;
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            if (notify_path[0]) unlink(notify_path);
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


def compile_launcher(
    path: Path,
    *,
    python: Path | str,
    cli_options: list[str],
    log_path: Path | str = APP_LOG,
) -> None:
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


def build_app(
    dest_dir: Path,
    *,
    python: Path | str,
    cli_options: list[str],
    log_path: Path | str = APP_LOG,
) -> Path:
    app = dest_dir / f"{APP_NAME}.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    (app / "Contents" / "Resources").mkdir(exist_ok=True)
    shutil.copyfile(ICON, app / "Contents" / "Resources" / ICON.name)
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info_plist()))
    compile_launcher(macos / EXECUTABLE, python=python, cli_options=cli_options, log_path=log_path)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def build_release_app(dest_dir: Path) -> Path:
    """The app CI publishes: runs the venv install.sh creates."""
    return build_app(dest_dir, python=RELEASE_PYTHON, cli_options=[], log_path=RELEASE_LOG)


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
