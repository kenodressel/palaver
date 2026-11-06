import Foundation
import Testing
@testable import PalaverCore

private func tempLog() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("palaver-test-\(UUID().uuidString)/daemon.log")
}

/// A taskpolicy stand-in: runs what follows `-c <qos>` and records the qos.
private func fakeTaskpolicy() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("taskpolicy")
    try "#!/bin/sh\necho \"qos=$2\"\nshift 2\nexec \"$@\"\n".write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return f.path
}

@Test func spawnWorkerRunsInOwnSessionWithEnv() throws {
    let log = tempLog()
    let p = try spawnWorker(["/bin/sh", "-c", "echo $PALAVER_APP; ps -o pgid= -p $$; echo oops >&2"], qos: .utility,
                            env: ["PALAVER_APP": "/x/Palaver.app"], log: log, taskpolicy: try fakeTaskpolicy())
    #expect(p.waitUntilExit() == 0)
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.first == "qos=utility")
    #expect(lines.contains("/x/Palaver.app"))
    #expect(lines.contains("oops"))  // stderr goes to the log too
    let mine = Int(getpgrp())  // macOS ps has no session column; a session leader leads its own group too
    let theirs = try #require(lines.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first)
    #expect(theirs != mine)
    #expect(theirs == Int(p.pid))  // setsid made it a group (and session) leader
}

@Test func spawnWorkerAppendsToTheLog() throws {
    let log = tempLog()
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "earlier\n".write(to: log, atomically: true, encoding: .utf8)
    let tp = try fakeTaskpolicy()
    try spawnWorker(["/bin/echo", "one"], qos: .background, log: log, taskpolicy: tp).waitUntilExit()
    try spawnWorker(["/bin/echo", "two"], qos: .background, log: log, taskpolicy: tp).waitUntilExit()
    #expect(try String(contentsOf: log, encoding: .utf8) == "earlier\nqos=background\none\nqos=background\ntwo\n")
}

@Test func spawnWorkerReportsExitCodesAndStartFailures() throws {
    let log = tempLog()
    let tp = try fakeTaskpolicy()
    #expect(try spawnWorker(["/bin/sh", "-c", "exit 3"], qos: .utility, log: log, taskpolicy: tp).waitUntilExit() == 3)
    #expect(throws: WorkerError.self) { try spawnWorker(["/bin/true"], qos: .utility, log: log, taskpolicy: "/nonexistent/taskpolicy") }
}

@Test func theRealTaskpolicyRunsTheCommand() throws {
    let log = tempLog()
    let p = try spawnWorker(["/bin/echo", "hello"], qos: .background, log: log)
    #expect(p.waitUntilExit() == 0)
    #expect(try String(contentsOf: log, encoding: .utf8) == "hello\n")
}

private func fakePython(_ body: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palaver-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("python")
    try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return f.path
}

@Test func pythonQueryRunsAppQueryAndParsesJson() async throws {
    // The stand-in prints its own arguments inside the JSON.
    let py = try fakePython(#"printf '{"args": "%s"}\n' "$*""#)
    let r = try await pythonQuery(["missing-models", "/m/a"], python: py, extraArgs: ["--config", "/c.toml"])
    #expect(r["args"] as? String == "-m palaver --config /c.toml app query missing-models /m/a --json")
}

@Test func pythonQueryTurnsAnErrorAnswerOrNoJsonIntoAnError() async throws {
    let bad = try fakePython(#"echo '{"error": "no calendar"}'; exit 1"#)
    await #expect(throws: WorkerError.self) { try await pythonQuery(["next-event"], python: bad) }
    let garbage = try fakePython("echo not json")
    await #expect(throws: WorkerError.self) { try await pythonQuery(["next-event"], python: garbage) }
    await #expect(throws: WorkerError.self) { try await pythonQuery(["x"], python: "/nonexistent/python") }
}

// MARK: fix round 1

@Test func spawnWorkerLeaksNoDescriptors() throws {
    let log = tempLog()
    let leaked = fcntl(open("/dev/null", O_RDONLY), F_DUPFD, 40)  // not close-on-exec, a number no one else uses
    defer { close(leaked) }
    let p = try spawnWorker(["/bin/ls", "/dev/fd"], qos: .utility, log: log, taskpolicy: try fakeTaskpolicy())
    #expect(p.waitUntilExit() == 0)
    let fds = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
    #expect(fds.contains(0) && fds.contains(1) && fds.contains(2))
    #expect(!fds.contains(Int(leaked)))
    #expect(fds.allSatisfy { $0 <= 5 })  // 0,1,2 and ls's own directory handles
}

@Test func spawnWorkerReapsWithoutAWaiter() throws {
    let p = try spawnWorker(["/bin/sh", "-c", "exit 5"], qos: .utility, log: tempLog(), taskpolicy: try fakeTaskpolicy())
    var waited = 0
    while p.exitCode == nil && waited < 500 { usleep(10_000); waited += 1 }
    #expect(p.exitCode == 5)
    errno = 0
    #expect(waitpid(p.pid, nil, WNOHANG) == -1 && errno == ECHILD)  // already reaped: no zombie
    #expect(p.waitUntilExit() == 5)
    #expect(p.waitUntilExit() == 5)
}

@Test func spawnWorkerCallsBackOnExit() async throws {
    let code: Int32 = await withCheckedContinuation { cont in
        do {
            _ = try spawnWorker(["/bin/sh", "-c", "exit 4"], qos: .utility, log: tempLog(),
                                taskpolicy: try fakeTaskpolicy(), onExit: { cont.resume(returning: $0) })
        } catch { cont.resume(returning: -1) }
    }
    #expect(code == 4)
}

@Test func spawnWorkerResetsSignalDispositionsAndMask() throws {
    let old = signal(SIGPIPE, SIG_IGN)
    var block = sigset_t(), prev = sigset_t()
    sigemptyset(&block); sigaddset(&block, SIGUSR1)
    pthread_sigmask(SIG_BLOCK, &block, &prev)
    defer { pthread_sigmask(SIG_SETMASK, &prev, nil); signal(SIGPIPE, old) }
    let tp = try fakeTaskpolicy()
    // A signal sent to itself: with the default disposition the shell dies of it (128+n); an inherited
    // ignore or block would let it carry on and say so.
    let pipe = try spawnWorker(["/bin/sh", "-c", "kill -s PIPE $$; echo survived"], qos: .utility, log: tempLog(), taskpolicy: tp)
    #expect(pipe.waitUntilExit() == 128 + SIGPIPE)
    let usr1 = try spawnWorker(["/bin/sh", "-c", "kill -s USR1 $$; echo survived"], qos: .utility, log: tempLog(), taskpolicy: tp)
    #expect(usr1.waitUntilExit() == 128 + SIGUSR1)
}

// MARK: task 8: never signal a reaped pid

@Test func signalsAfterTheExitAreNotSent() throws {
    let p = try spawnWorker(["/bin/sh", "-c", "exit 0"], qos: .utility, log: tempLog(), taskpolicy: try fakeTaskpolicy())
    #expect(p.waitUntilExit() == 0)
    #expect(p.poll() == 0)
    #expect(!p.signal(SIGTERM))  // reaped: its pid may be someone else's now
    #expect(!p.signal(SIGKILL, group: true))
    p.terminate()
    p.kill()
}

@Test func terminateReachesARunningWorkerAndItsGroup() throws {
    let tp = try fakeTaskpolicy()
    let p = try spawnWorker(["/bin/sleep", "30"], qos: .utility, log: tempLog(), taskpolicy: tp)
    #expect(p.poll() == nil)
    p.terminate()
    #expect(p.waitUntilExit() == 128 + SIGTERM)
    let g = try spawnWorker(["/bin/sh", "-c", "sleep 30 & wait"], qos: .utility, log: tempLog(), taskpolicy: tp)
    usleep(100_000)
    #expect(g.signal(SIGKILL, group: true))
    #expect(g.waitUntilExit() == 128 + SIGKILL)
}

// MARK: task 8 fix 1: a killed worker says so as Popen does

@Test func pollIsPopensReturncode() throws {
    let tp = try fakeTaskpolicy()
    let p = try spawnWorker(["/bin/sleep", "30"], qos: .utility, log: tempLog(), taskpolicy: tp)
    p.kill()
    #expect(p.waitUntilExit() == 128 + SIGKILL)  // the exit code as a shell says it
    #expect(p.poll() == -SIGKILL && p.terminationSignal == SIGKILL)
    let ok = try spawnWorker(["/bin/sh", "-c", "exit 3"], qos: .utility, log: tempLog(), taskpolicy: tp)
    #expect(ok.waitUntilExit() == 3 && ok.poll() == 3 && ok.terminationSignal == nil)
}

// MARK: Task 11: a child with descriptors of its own (the window's server)

private func cloexecPipe() -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    precondition(pipe(&fds) == 0)
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
}

private func outputFile() throws -> (url: URL, fd: Int32) {
    let url = tempLog()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    return (url, fd)
}

@Test func spawnChildPassesTheNamedDescriptorsAtTheirNumbersAndNoOthers() throws {
    let ready = cloexecPipe()
    // Close-on-exec like everything the app opens, at numbers no one else uses (ls's own handles
    // take the lowest free ones): never the child's.
    let pair = cloexecPipe()
    let other = (read: fcntl(pair.read, F_DUPFD_CLOEXEC, 60), write: fcntl(pair.write, F_DUPFD_CLOEXEC, 60))
    close(pair.read); close(pair.write)
    let leaked = fcntl(open("/dev/null", O_RDONLY), F_DUPFD, 41)  // not close-on-exec either
    defer { [ready.read, other.read, other.write, leaked].forEach { close($0) } }
    let out = try outputFile()
    defer { close(out.fd) }
    let p = try spawnChild(["/bin/sh", "-c", "ls /dev/fd; echo ready >&\(ready.write)"], env: ["PATH": "/bin:/usr/bin"],
                           inherit: [ready.write], output: out.fd)
    #expect(fcntl(ready.write, F_GETFD) & FD_CLOEXEC != 0)  // the app's copy stays close-on-exec
    close(ready.write)
    #expect(p.waitUntilExit() == 0)
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(ready.read, &buf, 64)
    #expect(n > 0 && String(decoding: buf.prefix(n), as: UTF8.self) == "ready\n")
    let fds = try String(contentsOf: out.url, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
    #expect(fds.contains(Int(ready.write)))
    #expect(!fds.contains(Int(other.read)) && !fds.contains(Int(other.write)) && !fds.contains(Int(leaked)))
}

@Test func spawnChildReadsStdinFromThePipeAndGetsOnlyTheGivenEnvironment() throws {
    let stdin = cloexecPipe()
    let out = try outputFile()
    defer { close(out.fd) }
    let p = try spawnChild(["/bin/sh", "-c", "echo \"home=${HOME-unset} key=$PALAVER_WEB_KEY\"; /bin/cat; echo eof"],
                           env: ["PALAVER_WEB_KEY": "k1"], stdin: stdin.read, output: out.fd)
    close(stdin.read)
    #expect(p.waitUntilExit(timeout: 0.3) == nil)  // waits on its stdin: the app is still there
    _ = "abc\n".withCString { write(stdin.write, $0, 4) }
    close(stdin.write)  // the app is gone
    #expect(p.waitUntilExit(timeout: 10) == 0)
    #expect(try String(contentsOf: out.url, encoding: .utf8) == "home=unset key=k1\nabc\neof\n")
}

@Test func spawnChildRunsInASessionOfItsOwn() throws {
    let out = try outputFile()
    defer { close(out.fd) }
    let p = try spawnChild(["/bin/sh", "-c", "ps -o pgid= -p $$"], env: ["PATH": "/bin:/usr/bin"], output: out.fd)
    #expect(p.waitUntilExit() == 0)
    let pgid = Int(try String(contentsOf: out.url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(pgid == Int(p.pid))
}
