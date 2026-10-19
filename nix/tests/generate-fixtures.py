"""Generate original CC0 HEVC fixtures with a Nix FFmpeg/libx265 executable."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import subprocess


def box(data: bytes, kind: bytes) -> bytes:
    """Read a known box from these small, locally generated MP4 fixtures."""
    offset = data.index(kind)
    size = struct.unpack_from(">I", data, offset - 4)[0]
    if size < 8 or offset - 4 + size > len(data):
        raise ValueError(f"invalid {kind!r} box")
    return data[offset + 4:offset - 4 + size]


def metadata(mp4: Path) -> dict:
    data = mp4.read_bytes()
    hvcc = box(data, b"hvcC")
    sizes = box(data, b"stsz")
    chunks = box(data, b"stco")
    constant_size, count = struct.unpack_from(">II", sizes, 4)
    if count < 1:
        raise ValueError("fixture contains no samples")
    sample_size = constant_size or struct.unpack_from(">I", sizes, 12)[0]
    sample_offset = struct.unpack_from(">I", chunks, 8)[0]
    sample = data[sample_offset:sample_offset + sample_size]
    if len(sample) != sample_size:
        raise ValueError("truncated fixture sample")
    profile = hvcc[1]
    compatibility = int(f'{int.from_bytes(hvcc[2:6], "big"):032b}'[::-1], 2)
    constraints = hvcc[6:12].rstrip(b"\0")
    profile_space = ("", "A", "B", "C")[profile >> 6]
    tier = "H" if profile & 32 else "L"
    codec = f"hvc1.{profile_space}{profile & 31}.{compatibility:X}.{tier}{hvcc[12]}"
    codec += "".join(f".{byte:02X}" for byte in constraints)
    return {
        "codec": codec, "width": 64, "height": 64,
        "description": base64.b64encode(hvcc).decode(),
        "sample": base64.b64encode(sample).decode(), "mp4": mp4.name,
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent / "data"
    root.mkdir(parents=True, exist_ok=True)
    for name, pixel_format in (("main", "yuv420p"), ("main10", "yuv420p10le")):
        mp4 = root / f"hevc-{name}.mp4"
        subprocess.run([
            str(args.ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=red:s=64x64:r=2", "-frames:v", "2",
            "-an", "-c:v", "libx265", "-profile:v", name, "-pix_fmt", pixel_format,
            "-x265-params", "pools=1:frame-threads=1:bframes=0:keyint=10:log-level=error",
            "-tag:v", "hvc1", "-movflags", "+faststart", str(mp4),
        ], check=True)
        record = metadata(mp4)
        mp4.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n")
        print(name, record["codec"], mp4.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
