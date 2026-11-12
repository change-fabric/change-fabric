"""Make a silent render copy of the mobile storyboard: no narration, no music.

The final audio (narration plus music) is muxed from the published desktop
mp4, so the render needs neither, and every scene's duration is its min_ms.
"""
import json, os, shutil, sys

src, dst = sys.argv[1], sys.argv[2]
cache = os.path.join(dst, '.cache')
keep = None
if os.path.isdir(cache):
    keep = dst.rstrip('/') + '.cache-keep'
    shutil.move(cache, keep)
if os.path.isdir(dst):
    shutil.rmtree(dst)
shutil.copytree(src, dst, ignore=shutil.ignore_patterns('.cache'))
if keep:
    shutil.move(keep, cache)
p = os.path.join(dst, 'storyboard.json')
b = json.load(open(p))
b['music'] = None
for s in b['scenes']:
    s.pop('narration', None)
json.dump(b, open(p, 'w'), indent=2)
