import struct
import zlib


def member(name, data=b"", mode=0o100644, links=1):
    encoded = name.encode("utf-8") + b"\0"
    # POSIX portable ASCII (odc): seven 6-octal fields, mtime(11), namesize(6), filesize(11).
    fields = (0, 1, mode, 0, 0, links, 0)
    header = "070707" + "".join("%06o" % value for value in fields)
    header += "%011o%06o%011o" % (0, len(encoded), len(data))
    return header.encode("ascii") + encoded + data


def archive(entries):
    return b"".join(member(name, data) for name, data in entries) + member("TRAILER!!!", mode=0)


def dvzip(data, stored=False, block_size=128 * 1024):
    output = bytearray()
    for offset in range(0, len(data), block_size):
        block = data[offset:offset + block_size]
        payload = block if stored else zlib.compress(block)
        value = len(payload) | (0x80000000 if stored else 0)
        output.extend(struct.pack(">I", value))
        output.extend(payload)
    return bytes(output)


def request(ident, name="test.txt"):
    return {"TransferID": {"id": ident}, "TransferType": {"files": {}},
            "SenderComputerName": "Test iPhone", "Files": [{"FileName": name}]}
