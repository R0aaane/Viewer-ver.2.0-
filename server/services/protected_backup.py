"""Bounded-memory Windows DPAPI file protection for host backup archives."""
import ctypes
from ctypes import wintypes
import os
import struct
import hashlib

BLOCK = 1024 * 1024
MAGIC = b"PDFVBK2\0"


class Blob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]


def crypt(data, decrypt=False):
    if os.name != "nt":
        raise RuntimeError("This backup format requires Windows DPAPI")
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    result = Blob()
    library = ctypes.WinDLL("crypt32", use_last_error=True)
    function = library.CryptUnprotectData if decrypt else library.CryptProtectData
    function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.POINTER(Blob),
                         ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    function.restype = wintypes.BOOL
    if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(result)):
        raise ctypes.WinError(ctypes.get_last_error())
    free = ctypes.WinDLL("kernel32").LocalFree
    free.argtypes = [ctypes.c_void_p]
    free.restype = ctypes.c_void_p
    try:
        return ctypes.string_at(result.data, result.size)
    finally:
        free(result.data)


def protect(source, destination):
    with source.open("rb") as src, destination.open("xb") as dst:
        dst.write(MAGIC)
        identity = os.urandom(16)
        dst.write(identity)
        index = 0
        checksum = hashlib.sha256()
        while chunk := src.read(BLOCK):
            checksum.update(chunk)
            encrypted = crypt(identity + struct.pack(">Q", index) + b"D" + chunk)
            dst.write(struct.pack(">I", len(encrypted)))
            dst.write(encrypted)
            index += 1
        final = crypt(identity + struct.pack(">Q", index) + b"E" + checksum.digest())
        dst.write(struct.pack(">I", len(final)))
        dst.write(final)
        dst.flush()
        os.fsync(dst.fileno())


def unprotect(source, destination):
    with source.open("rb") as src, destination.open("xb") as dst:
        if src.read(len(MAGIC)) != MAGIC:
            raise ValueError("Unknown protected backup format")
        identity = src.read(16)
        if len(identity) != 16:
            raise ValueError("Missing backup identity")
        index = 0
        checksum = hashlib.sha256()
        complete = False
        while size := src.read(4):
            if len(size) != 4:
                raise ValueError("Truncated backup block")
            count = struct.unpack(">I", size)[0]
            if not 1 <= count <= BLOCK + 65536:
                raise ValueError("Invalid backup block length")
            chunk = src.read(count)
            if len(chunk) != count:
                raise ValueError("Incomplete backup block")
            plain = crypt(chunk, decrypt=True)
            if len(plain) < 25 or plain[:24] != identity + struct.pack(">Q", index):
                raise ValueError("Backup blocks belong to another file or are out of order")
            if plain[24:25] == b"E":
                if plain[25:] != checksum.digest() or src.read(1):
                    raise ValueError("Backup checksum or end marker is invalid")
                complete = True
                break
            if plain[24:25] != b"D":
                raise ValueError("Unknown backup block type")
            checksum.update(plain[25:])
            dst.write(plain[25:])
            index += 1
        if not complete:
            raise ValueError("Backup ended before its protected end marker")
        dst.flush()
        os.fsync(dst.fileno())
