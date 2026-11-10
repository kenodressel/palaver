"""Build and install ``Palaver.app`` — the menu bar app as a real macOS app
that can start at login.

A release (``build_release_app``, #60) is the native app and holds no Python
(phase 4, 0.6): its executable ``Palaver`` is the Swift app, which records and
runs the daemon; the window's server ``palaver-server``, the pipeline's worker
``palaver-worker``, the language model's worker ``palaver-lm`` and the speech
engine ``palaver-engine`` sit beside it in Contents/MacOS; the ``palaver``
command (built as ``palaver-cli``) is Contents/Resources/bin/palaver, the
window's page files Contents/Resources/web. Every program is signed with one
identity, as 0.5's were (no hardened runtime yet: ``HARDENED_RUNTIME``). macOS asks for the microphone and system
audio under "Palaver" with the usage texts below. The repository's Python
stays only for the developer's fallback (the ``legacy-server`` marker in a
development build with the checkout's .venv) and the parity tooling.

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

INSTALL_COMMAND = "curl -fsSL https://raw.githubusercontent.com/kenodressel/palaver/master/install.sh | sh"


# Local-network names App Transport Security would hold to https (ModelChoice.LOCAL_SUFFIXES but .local, which it
# exempts itself).
LOCAL_NETWORK_DOMAINS = ("lan", "home.arpa")


def info_plist(executable: str = EXECUTABLE) -> dict:
    return {
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
        # Plain http:// to a gateway on the local network (ModelChoice.isLocalNetwork; the programs in Contents/MacOS
        # read this plist too). Measured: .local names, IP addresses and unqualified names pass App Transport Security
        # anyway; .lan and .home.arpa names need the exception. Every other host stays https only.
        "NSAppTransportSecurity": {
            "NSAllowsLocalNetworking": True,
            "NSExceptionDomains": {domain: {"NSIncludesSubdomains": True, "NSExceptionAllowsInsecureHTTPLoads": True}
                                   for domain in LOCAL_NETWORK_DOMAINS},
        },
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


ENGINE = "palaver-engine"  # in Contents/MacOS: the Swift speech engine
SERVER = "palaver-server"  # in Contents/MacOS: the window's server (phase 3), started by the app
WORKER = "palaver-worker"  # in Contents/MacOS: the pipeline's worker (phase 3), started by the app
LM = "palaver-lm"  # in Contents/MacOS: the language model's worker (phase 4), started by the app, server and worker
CLI_IN_BUNDLE = "bin/palaver"  # in Contents/Resources: the `palaver` command (built as palaver-cli); ~/.local/bin links here
MCP_SHIM = "bin/python"  # in Contents/Resources: for 0.6 only, starts `bin/palaver mcp` for Claude entries of before
WEB = "web"  # in Contents/Resources: the window's page files palaver-server serves (AppLocation.WEB_RESOURCES)
METALLIB = "mlx.metallib"  # in Contents/Resources: MLX's Metal shaders, which palaver-lm loads from there
LICENSES = "THIRD_PARTY_LICENSES.md"  # in Contents/Resources: the notices of what the programs link
# The id runtime.json names (tools/build_release.py COMPAT_RUNTIME_ID): the releases before 0.6 compare it with the
# manifest's runtime and unpack that placeholder; the app itself uses no runtime.
COMPAT_RUNTIME_ID = "no-python-1"
ENTITLEMENTS = Path(__file__).resolve().parent.parent / "native" / "Bundle" / "Palaver.entitlements"
# A release signs as 0.5 did, without the hardened runtime: under it the microphone, system audio, the calendar, the
# Keychain's access lists and library validation without a team ID were never tried on a real start. Notarization
# will turn it on, with ENTITLEMENTS (kept for that).
HARDENED_RUNTIME = False


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


def _codesign(path: Path, entitlements: Path | None = None, hardened: bool = True) -> None:
    argv = ["codesign", "--force", "--sign", sign_identity()]
    if hardened:
        argv += ["--options", "runtime"] + (["--entitlements", str(entitlements)] if entitlements else [])
    subprocess.run(argv + [str(path)], check=True, capture_output=True)


def _sign(app: Path, entitlements: Path | None = None, hardened: bool = False) -> None:
    """Nested code first (every program in Contents/MacOS but the executable, and the command in
    Contents/Resources/bin), then the bundle. ``hardened``: the hardened runtime with ``entitlements``
    (a release); the development bundle's launcher is signed plainly."""
    executable = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())["CFBundleExecutable"]
    nested = [p for p in sorted((app / "Contents" / "MacOS").iterdir()) if p.name != executable]
    command = app / "Contents" / "Resources" / CLI_IN_BUNDLE
    for program in nested + ([command] if command.exists() else []):
        _codesign(program, entitlements, hardened)
    _codesign(app, entitlements, hardened)


def _bundle(dest_dir: Path, *, executable: str) -> Path:
    app = dest_dir / f"{APP_NAME}.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    (app / "Contents" / "Resources").mkdir(exist_ok=True)
    shutil.copyfile(ICON, app / "Contents" / "Resources" / ICON.name)
    (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info_plist(executable)))
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


def _program(src: Path, dest: Path) -> None:
    """A program into the bundle without its debug map: the linker's stabs name every object file and source folder
    of the build (the builder's home folder and user name), which `strings` does not show but the file holds."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)
    dest.chmod(0o755)
    subprocess.run(["strip", "-S", str(dest)], check=True, capture_output=True)


def build_release_app(dest_dir: Path, *, app_binary: Path, engine: Path, server: Path, worker: Path, lm: Path,
                      cli: Path, mcp_shim: Path, web: Path, lm_resources: list[Path] | None = None,
                      domain_resources: Path | None = None, licenses: Path | None = None,
                      version: str = __version__, runtime_json_id: str = COMPAT_RUNTIME_ID,
                      entitlements: Path | None = ENTITLEMENTS) -> Path:
    """The app a release publishes (#60), without Python: the Swift app (``app_binary``, the built
    ``Palaver``) as the executable, ``engine``, ``server``, ``worker`` and ``lm`` (palaver-lm, built by
    xcodebuild) beside it in Contents/MacOS. In Contents/Resources: ``cli`` (palaver-cli) as
    ``bin/palaver``, ``mcp_shim`` (native/Bundle/bin/python) as ``bin/python``, ``web`` (the window's
    page files) as ``web/``, ``lm_resources`` (palaver-lm's Metal shaders, any ``*.metallib`` copied as
    ``mlx.metallib``, and the resource bundles it reads, folders copied whole), ``domain_resources``'
    files flat (``zipf.bin``), ``licenses`` as THIRD_PARTY_LICENSES.md, the icons and runtime.json
    (``version``, ``runtime_json_id``: what the updaters before 0.6 check). Every program is signed with
    the one identity, nested code before the bundle; with the hardened runtime and ``entitlements`` only
    once ``HARDENED_RUNTIME`` is on."""
    app = _bundle(dest_dir, executable=EXECUTABLE)
    macos = app / "Contents" / "MacOS"
    resources = app / "Contents" / "Resources"
    _program(app_binary, macos / EXECUTABLE)
    for name, built in ((ENGINE, engine), (SERVER, server), (WORKER, worker), (LM, lm)):
        _program(built, macos / name)
    _program(cli, resources / CLI_IN_BUNDLE)
    shutil.copyfile(mcp_shim, resources / MCP_SHIM)  # a shell script
    (resources / MCP_SHIM).chmod(0o755)
    shutil.copytree(web, resources / WEB, ignore=shutil.ignore_patterns(".*", "__pycache__", "*.py", "*.pyc"))
    shutil.copyfile(MENUBAR_ICON, resources / MENUBAR_ICON.name)
    (resources / "runtime.json").write_text(json.dumps({"version": version, "runtime": runtime_json_id}) + "\n")
    for item in lm_resources or []:
        if item.is_dir():
            shutil.copytree(item, resources / item.name)
        else:
            shutil.copyfile(item, resources / (METALLIB if item.suffix == ".metallib" else item.name))
    if domain_resources is not None:
        for item in sorted(domain_resources.iterdir()):
            if item.is_file() and not item.name.startswith("."):
                shutil.copyfile(item, resources / item.name)
    if licenses is not None:
        shutil.copyfile(licenses, resources / LICENSES)
    _sign(app, entitlements, hardened=HARDENED_RUNTIME)
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
