#!/bin/zsh
# `make test`: the tests of what changed since master (TEST_BASE; tools/changed_tests.py), `make test-all` all of them,
# `make test-long` all of them with the long ones (PALAVER_LONG_TESTS=1).
#
#   tools/test.sh [--all] [--long]
#
# One build (`make test-build`: native/.build/test, debug and optimized) serves the Swift tests, the programs they
# start and the e2e tests' palaver-server and palaver-lm. Then the Swift bundles (tools/swift_tests_parallel.sh) and
# pytest run at the same time. Everything runs reniced, on about half the cores (TEST_JOBS), so the Mac stays usable
# in a call. Exits 1 when anything failed.
set -u
cd "${0:A:h}/.."
all=0 long=0
for arg; do
  case $arg in
    --all) all=1 ;;
    --long) all=1 long=1 ;;
    *) echo "usage: tools/test.sh [--all] [--long]" >&2; exit 2 ;;
  esac
done
cores=$(sysctl -n hw.ncpu)
# make test: half the cores; make test-all and test-long: all but two (reniced all the same).
if (( all )); then jobs=${TEST_JOBS:-$(( cores > 3 ? cores - 2 : 1 ))}; else jobs=${TEST_JOBS:-$(( cores > 3 ? cores / 2 : 1 ))}; fi
nice_level=${PALAVER_TEST_NICE:-10}
export PALAVER_TEST_NICE=$nice_level
(( long )) && export PALAVER_LONG_TESTS=1

if (( all )); then
  swift_specs=(all) py=(tests)
else
  base=${TEST_BASE:-master}
  swift_specs=(${(f)"$(python3 tools/changed_tests.py --swift --base $base)"})
  py=(${(f)"$(python3 tools/changed_tests.py --base $base)"})
fi
if (( ${#swift_specs} == 0 && ${#py} == 0 )); then
  echo "nothing changed that a test covers (make test-all runs everything)"
  exit 0
fi
echo "Swift: ${swift_specs:-none}"
echo "pytest: ${py:-none}"

# The build, unless only tests that need none run (the page's JS, the release tooling).
needs_build=0
(( ${#swift_specs} )) && needs_build=1
for p in $py; do [[ $p == tests || $p == tests/e2e* || $p == tests/test_worker_helpers.py ]] && needs_build=1; done
start=$SECONDS
# Nothing of the package changed since the last build (a git checkout touches what it changes): no swift build,
# whose look at the package alone takes 5 to 10 s.
stamp=native/.build/test/.palaver-built
if (( needs_build )) && [[ -f $stamp ]] && \
   [[ -z $(find native/Sources native/Tests native/Package.swift native/Package.resolved native/vendor/.patched \
            -newer $stamp -print -quit 2>/dev/null) ]]; then
  needs_build=0
  echo "the build is up to date"
fi
if (( needs_build )); then
  log=$(mktemp -t palaver-test-build)
  # The stamp takes the time the build started: a file saved during the build is built next time.
  build_started=$(mktemp -t palaver-test-build-start)
  if ! nice -n $nice_level make --no-print-directory test-build TEST_JOBS=$jobs >"$log" 2>&1; then
    grep -E "error:|✗" "$log" | head -40
    echo "✘ the build failed (log: $log)"
    exit 1
  fi
  rm -f "$log"
  touch -r "$build_started" "$stamp" 2>/dev/null; rm -f "$build_started"
  echo "built in $(( SECONDS - start )) s"
fi

# Side by side: the Swift bundles and pytest (its workers: TEST_JOBS - 1).
swift_status=0 py_status=0 swift_pid=0 py_pid=0
if (( ${#swift_specs} )); then
  spec=""; [[ $swift_specs != all ]] && spec="${swift_specs[*]}"
  # Every bundle at once, each as many tests at once as there are cores: most of them wait (on a process, a lock,
  # a timeout), and a bundle queued behind another only adds its time to the run's. nice keeps the Mac usable; with
  # pytest alongside the Swift tests are niced further: the page's tests wait on a browser with 8 to 10 s timeouts.
  swift_nice=$nice_level
  (( ${#py} && nice_level < 15 )) && swift_nice=$(( nice_level + 5 ))
  PALAVER_TEST_NICE=$swift_nice tools/swift_tests_parallel.sh ${spec:+-b} ${spec:+"$spec"} -w $cores \
    -- $(make --no-print-directory -s test-build-args) &
  swift_pid=$!
fi
if (( ${#py} )); then
  workers=$(( jobs > 2 ? jobs - 1 : 1 )) dist=loadscope
  e2e_files=${#${(M)py:#tests/e2e/*}}
  if (( ${py[(I)tests]} || ${py[(I)tests/e2e]} )); then
    :  # the suite: a module's tests on one worker, its browser and shared server made once
  elif (( e2e_files )); then
    dist=load  # a few e2e files: their tests spread over the workers (a module's fixtures once per worker)
  elif (( ${#py} <= 2 )); then
    workers=0  # a test file or two of the tooling: no workers to start
  fi
  ( PALAVER_E2E_REQUIRED=1 exec uv run --extra dev pytest -q $( (( workers )) && echo "-n $workers --dist $dist") $py ) &
  py_pid=$!
  renice -n $nice_level -p $py_pid >/dev/null 2>&1
fi
(( swift_pid )) && { wait $swift_pid; swift_status=$?; }
(( py_pid )) && { wait $py_pid; py_status=$?; }
echo "tests done in $(( SECONDS - start )) s"
if (( swift_status || py_status )); then
  (( swift_status )) && echo "✘ Swift tests failed"
  (( py_status )) && echo "✘ pytest failed"
  exit 1
fi
