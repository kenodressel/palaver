#!/bin/sh
# Release signing on GitHub Actions (.github/workflows/release.yml): the kept certificate (CONTRIBUTING.md,
# "Signing releases"), base64 of its .p12 in the repository's secrets, into a temporary keychain on the user's
# keychain search list. tools/app_bundle.py signs with `codesign --sign "$PALAVER_SIGN_IDENTITY"` and no
# --keychain: codesign finds the identity through that search list. The certificate is self-signed, so
# `security find-identity -v` does not count it as valid; codesign signs with it all the same, which `create`
# checks on a copy of /usr/bin/true before the build starts.
#
#   PALAVER_SIGN_P12=<base64 .p12> PALAVER_SIGN_P12_PASSWORD=… PALAVER_SIGN_IDENTITY="Palaver Release" \
#     sh tools/release_keychain.sh create KEYCHAIN    # KEYCHAIN: a new path ending in .keychain-db
#   sh tools/release_keychain.sh delete KEYCHAIN      # off the search list, the keychain and the .p12 gone
#
# Prints no secret; never run it under set -x. The keychain's password is random and forgotten after `create`;
# the keychain stays unlocked for 6 hours (the longest a job runs).
set -eu

fail() { echo "✗ $*" >&2; exit 1; }
[ $# -eq 2 ] || fail "usage: release_keychain.sh create|delete KEYCHAIN"
KEYCHAIN="$2"
case "${KEYCHAIN}" in /*.keychain-db) ;; *) fail "KEYCHAIN must be an absolute path ending in .keychain-db" ;; esac
P12_FILE="${KEYCHAIN%.keychain-db}.p12"

search_list() { security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//'; }
on_search_list() { search_list | grep -qxF "$1"; }

case "$1" in
create)
  [ -n "${PALAVER_SIGN_P12:-}" ] && [ -n "${PALAVER_SIGN_P12_PASSWORD:-}" ] \
    || fail "PALAVER_SIGN_P12 and PALAVER_SIGN_P12_PASSWORD are not set (the repository's secrets)"
  [ -n "${PALAVER_SIGN_IDENTITY:-}" ] || fail "PALAVER_SIGN_IDENTITY is not set"
  [ ! -e "${KEYCHAIN}" ] || fail "${KEYCHAIN} exists"
  umask 077
  T="$(mktemp -d)"
  trap 'rm -f "${P12_FILE}"; rm -rf "${T}"' EXIT
  printf '%s' "${PALAVER_SIGN_P12}" | base64 --decode > "${P12_FILE}" || fail "PALAVER_SIGN_P12 is not base64"
  [ -s "${P12_FILE}" ] || fail "PALAVER_SIGN_P12 decodes to nothing"
  KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
  security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
  security set-keychain-settings -lut 21600 "${KEYCHAIN}"
  security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
  security import "${P12_FILE}" -k "${KEYCHAIN}" -f pkcs12 -P "${PALAVER_SIGN_P12_PASSWORD}" -T /usr/bin/codesign >/dev/null \
    || fail "importing the .p12 failed (wrong PALAVER_SIGN_P12_PASSWORD?)"
  rm -f "${P12_FILE}"
  # codesign may use the key without a prompt (there is no one to answer it here).
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}" >/dev/null
  unset KEYCHAIN_PASSWORD
  # First on the search list, the keychains already there after it.
  search_list | tr '\n' '\0' | xargs -0 security list-keychains -d user -s "${KEYCHAIN}"
  on_search_list "${KEYCHAIN}" || fail "${KEYCHAIN} is not on the keychain search list"
  security find-certificate -c "${PALAVER_SIGN_IDENTITY}" "${KEYCHAIN}" >/dev/null \
    || fail "the .p12 holds no certificate named \"${PALAVER_SIGN_IDENTITY}\""
  security find-identity -p codesigning "${KEYCHAIN}" | sed -n '/Matching identities/,/identities found/p'
  # Sign as tools/app_bundle.py does, through the search list: the build must not fail on the last program.
  cp /usr/bin/true "${T}/probe"
  codesign --force --sign "${PALAVER_SIGN_IDENTITY}" "${T}/probe" || fail "codesign cannot sign with \"${PALAVER_SIGN_IDENTITY}\""
  codesign --verify --strict "${T}/probe" || fail "a probe signed with \"${PALAVER_SIGN_IDENTITY}\" does not verify"
  codesign -dvv "${T}/probe" 2>&1 | grep -qxF "Authority=${PALAVER_SIGN_IDENTITY}" \
    || fail "the probe is not signed by \"${PALAVER_SIGN_IDENTITY}\""
  echo "✓ \"${PALAVER_SIGN_IDENTITY}\" signs from ${KEYCHAIN} (on the keychain search list)"
  ;;
delete)
  rm -f "${P12_FILE}"
  if [ -e "${KEYCHAIN}" ] || on_search_list "${KEYCHAIN}"; then
    security delete-keychain "${KEYCHAIN}" 2>/dev/null || true  # also takes it off the search list
  fi
  if on_search_list "${KEYCHAIN}"; then  # the file was gone already: the search list without it
    REST="$(search_list | grep -vxF "${KEYCHAIN}" || true)"
    [ -n "${REST}" ] || fail "${KEYCHAIN} is the only keychain on the search list; not emptying it"
    printf '%s\n' "${REST}" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
  fi
  rm -f "${KEYCHAIN}"
  ! on_search_list "${KEYCHAIN}" || fail "${KEYCHAIN} is still on the keychain search list"
  echo "✓ ${KEYCHAIN} deleted"
  ;;
*) fail "usage: release_keychain.sh create|delete KEYCHAIN" ;;
esac
