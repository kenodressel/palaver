#!/bin/zsh
# Runs the Swift test bundles side by side, each in its own process with its own temporary XDG_CONFIG_HOME and
# PALAVER_HOME (TestIsolation), from a build `swift build --build-tests` already made. `swift test` runs the bundles
# one after another and starts each twice (XCTest, then swift-testing); here the slowest bundle sets the time.
#
#   tools/swift_tests_parallel.sh [-b "PalaverCaptureTests PalaverServerTests=SearchRoutesTests,ReviewSpeedTests"]
#                                 [-f FILTER] [-j JOBS] [-w WIDTH] [-- build args]
#
# -b  the bundles (default: every *Tests.xctest built), each with only some of its suites after a "=";
# -f  a swift-testing --filter for every bundle (a suite or test name, regex);
# -j  how many bundles run at once (default all); -w how many tests each runs at once (default: the cores).
# Runs reniced (PALAVER_TEST_NICE, default 10) so the Mac stays usable. Prints a line per bundle, the failures'
# lines and the log of a failed bundle; exits 1 on any failure.
set -u
ENGINE_DIR=${ENGINE_DIR:-native}
bundles=() filter="" jobs=0 width=0
while getopts "b:f:j:w:" opt; do
  case $opt in
    b) bundles=(${=OPTARG}) ;;
    f) filter=$OPTARG ;;
    j) jobs=$OPTARG ;;
    w) width=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ ${1:-} == "--" ]] && shift
# Bundle=Suite,Suite: that bundle's filter.
typeset -A only
specs=($bundles) bundles=()
for spec in $specs; do
  name=${spec%%=*}
  bundles+=$name
  [[ $spec == *=* ]] && only[$name]="^${name}\.(${${spec#*=}//,/|})(/|\()"
done
bin=$(swift build --package-path "$ENGINE_DIR" --show-bin-path "$@") || exit $?
dev=$(xcode-select -p)
helper=$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper
platform="$dev/Platforms/MacOSX.platform/Developer"
nice_level=${PALAVER_TEST_NICE:-10}
if [[ ! -x $helper || ! -d $platform/Library/Frameworks ]]; then
  # The Command Line Tools alone: no helper, swift test runs the bundles one after another.
  echo "no Xcode testing helper: swift test runs the bundles one after another" >&2
  tmp=$(mktemp -d -t palaver-swift-test) && mkdir -p "$tmp/config" "$tmp/home"
  args=(--package-path "$ENGINE_DIR" --skip-build)
  [[ -n $filter ]] && args+=(--filter "$filter")
  for b in $bundles; do args+=(--filter "${only[$b]:-^${b}\\.}"); done
  XDG_CONFIG_HOME="$tmp/config" PALAVER_HOME="$tmp/home" nice -n $nice_level swift test $args "$@"
  st=$?; rm -rf "$tmp"; exit $st
fi
if (( ${#bundles} == 0 )); then
  for b in "$bin"/*Tests.xctest; do bundles+=${b:t:r}; done
fi
# The longest first: with fewer jobs than bundles they set the time.
order=(PalaverDomainTests PalaverServerTests PalaverDaemonTests PalaverCaptureTests PalaverWorkerTests PalaverLMTests
       PalaverCloudTests PalaverCoreTests PalaverEngineTests PalaverMLXTests)
sorted=()
for b in $order; do (( ${bundles[(Ie)$b]} )) && sorted+=$b; done
for b in $bundles; do (( ${sorted[(Ie)$b]} )) || sorted+=$b; done
(( jobs > 0 )) || jobs=${#sorted}
out=$(mktemp -d -t palaver-swift-tests)
testing_args=(--testing-library swift-testing)
[[ -n $filter ]] && testing_args+=(--filter "$filter")
(( width > 0 )) && testing_args+=(--experimental-maximum-parallelization-width $width)
typeset -A pid_of
running=()
for name in $sorted; do
  b="$bin/$name.xctest"
  if [[ ! -d $b ]]; then echo "✘ $name: not built ($b)"; exit 1; fi
  while (( ${#running} >= jobs )); do
    still=()
    for n in $running; do kill -0 ${pid_of[$n]} 2>/dev/null && still+=$n; done
    running=($still)
    (( ${#running} >= jobs )) && sleep 0.2
  done
  mkdir -p "$out/$name/config" "$out/$name/home"
  ( cd "$ENGINE_DIR" && DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib" \
      XDG_CONFIG_HOME="$out/$name/config" PALAVER_HOME="$out/$name/home" NO_COLOR=1 \
      exec "$helper" --test-bundle-path "$b/Contents/MacOS/$name" $testing_args ${only[$name]:+--filter} ${only[$name]:-} \
      > "$out/$name.log" 2>&1 ) &
  pid=$!
  # renice, not nice: /usr/bin/nice is a system program, and macOS strips the DYLD_ variables when one starts.
  renice -n $nice_level -p $pid >/dev/null 2>&1
  pid_of[$name]=$pid
  running+=$name
done
failed=0
for name in $sorted; do
  wait ${pid_of[$name]}; st=$?
  summary=$(grep -aE "Test run with" "$out/$name.log" | tail -1 | sed -E 's/^[^A-Za-z]*//')
  if [[ $st -eq 69 && ( -n $filter || -n ${only[$name]:-} ) && -z $summary ]]; then
    continue  # EX_UNAVAILABLE: none of this bundle's tests match the filter
  elif [[ $st -ne 0 ]]; then
    failed=1
    grep -aE "✘|recorded an issue|↳|Fatal error|error:" "$out/$name.log" | grep -v "known issue" | head -60
    echo "✘ $name (exit $st): ${summary:-no summary} (log: $out/$name.log)"
  else
    echo "✔ $name: $summary"
  fi
done
if [[ -n ${PALAVER_TEST_LOGS:-} ]]; then mkdir -p "$PALAVER_TEST_LOGS" && cp "$out"/*.log "$PALAVER_TEST_LOGS"/; fi
[[ $failed -eq 0 ]] && rm -rf "$out"
exit $failed
