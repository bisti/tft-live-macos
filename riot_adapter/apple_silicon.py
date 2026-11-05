"""Keep only Apple Silicon code in a private Riot runtime copy."""
from pathlib import Path
import shutil
import struct
import subprocess


def thin_binary(path):
    with path.open("rb") as source:
        magic, count = struct.unpack(">4sI", source.read(8))
        if magic not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") or not 1 <= count <= 32:
            raise RuntimeError(f"Unsupported universal binary format. {path}")
        layout = ">IIQQII" if magic == b"\xca\xfe\xba\xbf" else ">IIIII"
        entries = [struct.unpack(layout, source.read(struct.calcsize(layout))) for _ in range(count)]
        matches = [entry for entry in entries if entry[0] == 0x100000c and entry[1] & 0xffffff in (0, 1)]
        if len(matches) != 1:
            raise RuntimeError(f"Component does not have a unique Apple Silicon slice. {path}")
        _, _, offset, size, *_ = matches[0]
        if offset < source.tell() or offset + size > path.stat().st_size:
            raise RuntimeError(f"Invalid Apple Silicon slice. {path}")
        temporary = path.with_name(path.name + ".arm64-tmp")
        source.seek(offset)
        with temporary.open("wb") as output:
            remaining = size
            while remaining:
                block = source.read(min(remaining, 1024 * 1024))
                if not block:
                    raise RuntimeError(f"Incomplete component. {path}")
                output.write(block)
                remaining -= len(block)
    temporary.chmod(path.stat().st_mode & 0o777)
    temporary.replace(path)


def thin_tree(directory):
    directory = Path(directory)
    for obsolete in directory.rglob("Krisp/x64"):
        if obsolete.is_dir() and not obsolete.is_symlink():
            shutil.rmtree(obsolete)
    for path in directory.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(8)
        magic = header[:4]
        if magic == b"\xcf\xfa\xed\xfe" and struct.unpack_from("<I", header, 4)[0] != 0x100000c:
            raise RuntimeError(f"Component has no Apple Silicon slice. {path}")
        if magic not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            continue
        thin_binary(path)
        subprocess.run([
            "codesign", "--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements", str(path),
        ], check=True)
