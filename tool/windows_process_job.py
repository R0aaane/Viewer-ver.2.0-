"""Keep build children in a Windows job so a crashed watcher leaves no builders."""
import ctypes
from ctypes import wintypes
import os

_handle = None


def contain_children():
    global _handle
    if os.name != "nt" or _handle is not None:
        return

    class BasicLimits(ctypes.Structure):
        _fields_ = [("processTime", ctypes.c_longlong), ("jobTime", ctypes.c_longlong),
                    ("flags", wintypes.DWORD), ("minWorkingSet", ctypes.c_size_t),
                    ("maxWorkingSet", ctypes.c_size_t), ("activeProcesses", wintypes.DWORD),
                    ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in ("readOps", "writeOps", "otherOps", "readBytes", "writeBytes", "otherBytes")]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [("basic", BasicLimits), ("io", IoCounters), ("processMemory", ctypes.c_size_t),
                    ("jobMemory", ctypes.c_size_t), ("peakProcessMemory", ctypes.c_size_t), ("peakJobMemory", ctypes.c_size_t)]

    api = ctypes.WinDLL("kernel32", use_last_error=True)
    api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    api.CreateJobObjectW.restype = wintypes.HANDLE
    api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    api.SetInformationJobObject.restype = wintypes.BOOL
    api.GetCurrentProcess.restype = wintypes.HANDLE
    api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    api.AssignProcessToJobObject.restype = wintypes.BOOL
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = api.CreateJobObjectW(None, None)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    limits = ExtendedLimits()
    limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not api.SetInformationJobObject(handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
        error = ctypes.WinError(ctypes.get_last_error())
        api.CloseHandle(handle)
        raise error
    if not api.AssignProcessToJobObject(handle, api.GetCurrentProcess()):
        error = ctypes.WinError(ctypes.get_last_error())
        api.CloseHandle(handle)
        raise error
    # Non-inheritable handle intentionally lives until this process exits.
    # The OS then closes it and terminates any remaining descendant builders.
    _handle = handle
