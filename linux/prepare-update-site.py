#!/usr/bin/env python3
"""Gemeinsame Pages-Ausgabe: signierten Linux-Feed übernehmen, Mac-Release wählen."""
import argparse, json, pathlib, re, subprocess, sys


def release_version(release):
    match = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)', release.get('tag_name', ''))
    if not match or release.get('draft') or release.get('prerelease'):
        return None
    return tuple(map(int, match.groups()))


def select_release(releases, suffixes):
    candidates = []
    for release in releases:
        version = release_version(release)
        names = [asset['name'] for asset in release.get('assets', [])]
        if version and all(sum(name.endswith(suffix) for name in names) == 1 for suffix in suffixes):
            candidates.append((version, release))
    return max(candidates, key=lambda item: item[0])[1] if candidates else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--releases', required=True)
    parser.add_argument('--site', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--openssl', default='openssl')
    args = parser.parse_args()
    pages = json.loads(pathlib.Path(args.releases).read_text())
    releases = [release for page in pages for release in page]
    mac = select_release(releases, ['.dmg'])
    if not mac:
        raise SystemExit('Kein stabiles macOS-Release mit genau einem DMG.')
    linux = select_release(releases, ['linux-stable.json', 'linux-stable.json.sig'])
    if linux:
        target = pathlib.Path(args.site) / 'linux'
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(['gh', 'release', 'download', linux['tag_name'], '-R', args.repository,
                        '--pattern', 'linux-stable.json*', '--dir', str(target)], check=True)
        manifest = target / 'linux-stable.json'
        signature = target / 'linux-stable.json.sig'
        if manifest.stat().st_size > 65536 or signature.stat().st_size != 64:
            raise SystemExit('Ungültige Feedgröße.')
        key = pathlib.Path(__file__).with_name('update-public.pem')
        subprocess.run([args.openssl, 'pkeyutl', '-verify', '-pubin', '-inkey', str(key),
                        '-rawin', '-in', str(manifest), '-sigfile', str(signature)],
                       check=True, capture_output=True)
        value = json.loads(manifest.read_bytes())
        version = '.'.join(map(str, release_version(linux)))
        expected_url = f'https://github.com/{args.repository}/releases/download/v{version}/StillePost-{version}-linux-x86_64.tar.gz'
        if (value.get('product') != 'io.github.danielmuellerir.stillepost'
                or value.get('channel') != 'stable' or value.get('arch') != 'x86_64'
                or value.get('version') != version or value.get('url') != expected_url
                or not re.fullmatch(r'[0-9a-f]{64}', value.get('sha256', ''))):
            raise SystemExit('Signierter Feed passt nicht zum ausgewählten Linux-Release.')
        manifest.rename(target / 'stable.json')
        signature.rename(target / 'stable.json.sig')
    # Nur der Mac-Tag geht nach stdout in GITHUB_ENV; kein geheimer Inhalt.
    print('RELEASE_TAG=' + mac['tag_name'])


if __name__ == '__main__':
    main()
