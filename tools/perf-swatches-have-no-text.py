#!/usr/bin/env python3
"""3178: the actual mac load swatch contains only gradient geometry.

Windows asserts its actual returned Draw variants in perf_color's tests.
This gate checks the SwiftUI drawing, excluded from the logic package.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent

def body(source, name):
    start = source.index(name)
    start = source.index('{', start)
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def valid(source):
    swatch = body(source, 'private func loadSwatch()')
    return 'LinearGradient(' in swatch and not re.search(r'\b(?:Text|overlay)\s*\(', swatch)

source = (ROOT/'macos/Sources/Features/ControlRoom/ControlRoomPerfPage.swift').read_text()
if not valid(source):
    raise SystemExit('FAIL: 3178 load swatch must contain colour geometry only, no text or overlay')
planted = source.replace('private func loadSwatch() -> some View {', 'private func loadSwatch() -> some View { Text("!")', 1)
if valid(planted):
    raise SystemExit('FAIL: 3178 source probe did not reject text inside the swatch')
print('3178: scanned actual SwiftUI loadSwatch; no internal text/overlay; planted text rejected')
