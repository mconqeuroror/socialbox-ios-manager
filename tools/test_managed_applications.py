#!/usr/bin/env python3
"""The stop registry must exactly match the reviewed base's main-app targets."""
import json,re,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class Registry(unittest.TestCase):
    def test_registry_matches_binary_filter(self):
        baseline=json.loads((ROOT/'docs/socialbox-adoption/binary-baseline.json').read_text())
        def find_filter(node):
            if isinstance(node,dict):
                for key,value in node.items():
                    if key=='compiled/var/jb/Library/MobileSubstrate/DynamicLibraries/SocialBox.plist':return value['Filter']['Bundles']
                    result=find_filter(value)
                    if result:return result
            elif isinstance(node,list):
                for value in node:
                    result=find_filter(value)
                    if result:return result
        original=set(find_filter(baseline))
        excluded={'com.socialbox.app','com.apple.Preferences',
                  'com.reddit.Reddit.NotificationServiceExtension','com.reddit.Reddit.ShareExtension',
                  'com.reddit.Reddit.RedditIntents','com.reddit.Reddit.RedditWidgets','com.reddit.Reddit.stickers'}
        declarations=re.findall(r'^LBX_APPLICATION\("([^"\n]+)", "([^"\n]+)"\)$',
            (ROOT/'lucid/Switching/LBXManagedApplications.def').read_text(),re.M)
        self.assertEqual(len(declarations),len(dict(declarations)))
        self.assertEqual(set(dict(declarations)),original-excluded)
        self.assertEqual(len(declarations),16)
if __name__=='__main__':unittest.main()
