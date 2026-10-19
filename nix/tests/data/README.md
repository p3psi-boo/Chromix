# HEVC fixtures

Original synthetic 64x64 red video, two frames at 2 fps, no audio. These generated
fixtures and accompanying JSON metadata are dedicated to the public domain
(CC0-1.0). They contain no downloaded media.

- `hevc-main.mp4`: HEVC Main, yuv420p, hvc1 sample entry.
- `hevc-main10.mp4`: HEVC Main10, yuv420p10le, hvc1 sample entry.
- JSON files contain the hvcC decoder description, first length-prefixed key
  sample, codec string and SHA256 of the corresponding MP4.

Generated with Nix FFmpeg 9.0.1 / libx265:

```sh
python3 Chromix/nix/tests/generate-fixtures.py \
  --ffmpeg /nix/store/jzmlspv69xcby6bi634lj8xqfwavdjy8-ffmpeg-9.0.1-bin/bin/ffmpeg
```

The generator records fresh hashes, so it need not produce byte-identical
containers with a different encoder version. Pixel checks tolerate YUV/RGB
conversion rounding. Fixture validation alone does not establish browser decode.
