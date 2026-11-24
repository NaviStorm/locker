#!/bin/bash
set -euo pipefail

locker_bundle_id=com.tandreuperouges.locker.documents

usage() {
    cat <<'HELP'
Usage : scripts/install.sh --list
        scripts/install.sh --ios [--device NOM_OU_IDENTIFIANT]
        scripts/install.sh --serial NUMÉRO_DE_SÉRIE_OU_UDID
        scripts/install.sh --macos

--list             Afficher les iPhone physiques connectés.
--ios              Compiler et installer Locker en Release sur iPhone.
--device, --serial Choisir un iPhone par nom exact, UDID ou numéro de série.
                   Sans sélecteur, --ios nécessite un seul iPhone connecté.
--macos            Installer Locker en Release dans /Applications/Locker.app.
--help, -h         Afficher cette aide.
HELP
}

fail() { printf 'Erreur : %s\n' "$*" >&2; exit 1; }

iphone() {
    xcrun devicectl list devices --quiet --json-output - |
        /usr/bin/python3 -c '
import json, sys

mode, selector = sys.argv[1], sys.argv[2].strip().casefold()
phones = []
for device in json.load(sys.stdin)["result"]["devices"]:
    props = device.get("properties", {})
    hw = props.get("hardware") or device.get("hardwareProperties", {})
    conn = props.get("connection") or device.get("connectionProperties", {})
    state = props.get("state") or device.get("deviceProperties", {})
    if hw.get("reality") != "physical" or hw.get("deviceType") != "iPhone":
        continue
    if conn.get("state", conn.get("tunnelState")) != "connected":
        continue
    phones.append((state.get("name", "").strip(), hw["udid"], hw.get("serialNumber") or "",
                   conn.get("transportType") or ""))

def listing(stream):
    if not phones:
        print("Aucun iPhone connecté.", file=stream)
        return
    print("NOM\tUDID\tNUMÉRO DE SÉRIE\tCONNEXION", file=stream)
    for name, udid, serial, transport in sorted(phones):
        link = {"wired": "USB", "localNetwork": "Réseau"}.get(transport, transport)
        print(name, udid, serial, link, sep="\t", file=stream)

if mode == "list":
    listing(sys.stdout)
else:
    matches = [p for p in phones if not selector or selector in [v.casefold() for v in p[:3]]]
    if len(matches) != 1:
        listing(sys.stderr)
        sys.exit("Choisissez un seul iPhone connecté avec --device ou --serial.")
    print(matches[0][1])
' "$1" "$2"
}

verify_signature() {
    local app=$1 extension=$2
    local signer='anchor apple generic and certificate leaf[subject.OU] = "RTMWCLXVLL"'
    codesign --verify --deep --strict --verbose=2 "$app" || return 1
    codesign --verify --strict -R="identifier \"$locker_bundle_id\" and $signer" "$app" || return 1
    codesign --verify --strict -R="identifier \"$locker_bundle_id.share\" and $signer" "$app/$extension"
}

install_mac() (
    local source=$1 directory=$2 target stage
    target="$directory/Locker.app"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ ! -L "$target" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")" == "$locker_bundle_id" ]] ||
            fail "La destination existe déjà et ne correspond pas à Locker : $target"
    fi
    stage=$(mktemp -d "$directory/.locker-install.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    ditto "$source" "$stage/Locker.app"
    verify_signature "$stage/Locker.app" "Contents/PlugIns/LockerShare.appex"

    # Publier la copie vérifiée sur le même volume. Lors d’une mise à jour,
    # l’ancien bundle reste en place jusqu’à l’échange atomique.
    xcrun swift - "$stage/Locker.app" "$target" <<'SWIFT'
import Darwin
import Foundation

let source = CommandLine.arguments[1]
let target = CommandLine.arguments[2]
let flag = FileManager.default.fileExists(atPath: target) ? RENAME_SWAP : RENAME_EXCL
guard renamex_np(source, target, UInt32(flag)) == 0 else {
    perror("Installation de Locker")
    exit(1)
}
SWIFT
    printf 'Locker Release installé dans %s\n' "$target"
)

main() {
    local mode='' selector='' root build app destination extension udid=''
    while (($#)); do
        case "$1" in
            --list|--ios|--macos)
                [[ -z "$mode" ]] || fail "Choisissez une seule action parmi --list, --ios et --macos."
                mode=$1 ;;
            --device|--serial)
                [[ -z "$selector" && -n "${2:-}" && "$2" != -* && "$2" =~ [^[:space:]] ]] ||
                    fail "$1 attend un nom, un UDID ou un numéro de série."
                selector=$2
                shift ;;
            -h|--help) usage; return ;;
            *) fail "Option inconnue : $1 (voir --help)." ;;
        esac
        shift
    done
    if [[ -z "$mode" && -n "$selector" ]]; then mode=--ios; fi
    [[ -n "$mode" ]] || { usage >&2; return 2; }
    [[ -z "$selector" || "$mode" == --ios ]] || fail "Le sélecteur d’iPhone s’utilise avec --ios."
    if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode 27.1 Beta.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode 27.1 Beta.app/Contents/Developer"
    fi
    if [[ "$mode" == --list ]]; then iphone list ""; return; fi

    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
    build="$root/.validation/install-${mode#--}"
    mkdir -p "$build/tmp"
    export TMPDIR="$build/tmp"
    if [[ "$mode" == --ios ]]; then
        udid=$(iphone select "$selector")
        # Compile the same asset catalogue for every iPhone sharing this build cache.
        # Only devicectl needs the selected device when installing the verified bundle.
        destination="generic/platform=iOS"
        app="$build/Build/Products/Release-iphoneos/Locker.app"
        extension="PlugIns/LockerShare.appex"
    else
        destination="platform=macOS,arch=$(uname -m)"
        app="$build/Build/Products/Release/Locker.app"
        extension="Contents/PlugIns/LockerShare.appex"
    fi
    xcrun xcodebuild -project "$root/Locker.xcodeproj" -scheme Locker -configuration Release \
        -destination "$destination" -derivedDataPath "$build" CODE_SIGNING_ALLOWED=YES build
    verify_signature "$app" "$extension"
    if [[ "$mode" == --ios ]]; then
        xcrun devicectl device install app --device "$udid" "$app"
        xcrun devicectl device info apps --device "$udid" --bundle-id "$locker_bundle_id"
    else
        install_mac "$app" /Applications
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
