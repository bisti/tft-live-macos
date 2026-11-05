"""Locate the ARM64 platform getter without version-specific file offsets."""
import struct


def patch_windows_sdk(path):
    data = bytearray(path.read_bytes())
    if data[:8] != struct.pack("<II", 0xfeedfacf, 0x100000c):
        raise RuntimeError("The SDK must contain only the ARM64 slice.")
    sections = {}
    image_address = 0
    command = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        kind, size = struct.unpack_from("<II", data, command)
        if kind == 0x19:
            if bytes(data[command + 8:command + 24]).split(b"\0")[0] == b"__TEXT":
                image_address = struct.unpack_from("<Q", data, command + 24)[0]
            for index in range(struct.unpack_from("<I", data, command + 64)[0]):
                position = command + 72 + index * 80
                name = bytes(data[position:position + 16]).split(b"\0")[0]
                address, length, offset = struct.unpack_from("<QQI", data, position + 32)
                sections[name] = (address, length, offset)
        command += size
    text_address, text_size, text_offset = sections[b"__text"]
    string_address, string_size, string_offset = sections[b"__cstring"]
    strings = bytes(data[string_offset:string_offset + string_size])
    windows = strings.find(b"\0windows\0")
    if windows < 0:
        raise RuntimeError("The SDK does not provide the expected Windows platform.")
    windows_address = string_address + windows + 1
    candidates = []
    for offset in range(text_offset, text_offset + text_size - 11, 4):
        adrp, add, ret = struct.unpack_from("<III", data, offset)
        if adrp & 0x9f00001f != 0x90000000 or add & 0xffc003ff != 0x91000000 or ret != 0xd65f03c0:
            continue
        address = text_address + offset - text_offset
        immediate = ((adrp >> 29) & 3) | (((adrp >> 5) & 0x7ffff) << 2)
        if immediate & (1 << 20):
            immediate -= 1 << 21
        target = (address & ~4095) + (immediate << 12) + ((add >> 10) & 4095)
        position = target - string_address
        if 0 <= position <= len(strings) - 4 and strings[position:position + 4] == b"mac\0":
            candidates.append((offset, address))
    if len(candidates) != 1:
        raise RuntimeError("The new SDK platform function cannot be identified unambiguously.")
    offset, address = candidates[0]
    pages = ((windows_address & ~4095) - (address & ~4095)) // 4096
    if not -(1 << 20) <= pages < (1 << 20):
        raise RuntimeError("The SDK platform string is out of range.")
    immediate = pages & 0x1fffff
    adrp = 0x90000000 | ((immediate & 3) << 29) | ((immediate >> 2) << 5)
    add = 0x91000000 | ((windows_address & 4095) << 10)
    struct.pack_into("<II", data, offset, adrp, add)
    path.write_bytes(data)
    return address - image_address
