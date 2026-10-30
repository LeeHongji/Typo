# Typo performance frames

Renders key frames of `TypoPerformance` on light and dark backgrounds, using the
app's own Typo sources, so motion and the white sticker edge can be checked
without launching the app.

```bash
cd design/typo/stage
S=../../../Sources/Type4Me/UI/Typo
swiftc -O -o /tmp/typo-stage main.swift $S/TypoReferenceGeometry.swift $S/TypoRenderer.swift $S/TypoPerformance.swift
/tmp/typo-stage ../typo-performance-frames.png
```
