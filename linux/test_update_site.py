#!/usr/bin/env python3
"""Plattformauswahl darf einen vorhandenen Feed nicht zurücksetzen."""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('update_site', pathlib.Path(__file__).with_name('prepare-update-site.py'))
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


def release(tag, names, **flags):
    return dict(tag_name=tag, assets=[dict(name=name) for name in names], **flags)


class UpdateSiteTests(unittest.TestCase):
    def test_linux_release_keeps_latest_mac_release(self):
        releases = [release('v0.9.46', ['Mac.dmg']), release('v0.9.48', ['linux-stable.json', 'linux-stable.json.sig'])]
        self.assertEqual(site.select_release(releases, ['.dmg'])['tag_name'], 'v0.9.46')
        self.assertEqual(site.select_release(releases, ['linux-stable.json', 'linux-stable.json.sig'])['tag_name'], 'v0.9.48')

    def test_numeric_order_and_unordered_releases(self):
        releases = [release('v0.9.9', ['Mac.dmg']), release('v0.9.48', ['Mac.dmg']), release('v0.9.10', ['Mac.dmg'])]
        self.assertEqual(site.select_release(releases, ['.dmg'])['tag_name'], 'v0.9.48')

    def test_drafts_prereleases_duplicates_and_missing_pairs_are_excluded(self):
        releases = [release('v0.9.99', ['Mac.dmg'], draft=True), release('v0.9.98', ['Mac.dmg'], prerelease=True), release('v0.9.97', ['One.dmg', 'Two.dmg']), release('main', ['Mac.dmg'])]
        self.assertIsNone(site.select_release(releases, ['.dmg']))
        self.assertIsNone(site.select_release([release('v0.9.48', ['linux-stable.json'])], ['linux-stable.json', 'linux-stable.json.sig']))


if __name__ == '__main__':
    unittest.main()
