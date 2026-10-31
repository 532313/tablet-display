#!/usr/bin/env python3
import ctypes
import json
import sys

cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')

class CGPoint(ctypes.Structure):
    _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]

class CGSize(ctypes.Structure):
    _fields_ = [('width', ctypes.c_double), ('height', ctypes.c_double)]

class CGRect(ctypes.Structure):
    _fields_ = [('origin', CGPoint), ('size', CGSize)]

cg.CGGetActiveDisplayList.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
cg.CGGetActiveDisplayList.restype = ctypes.c_int32
cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
cg.CGDisplayBounds.restype = CGRect
cg.CGDisplayIsMain.argtypes = [ctypes.c_uint32]
cg.CGDisplayIsMain.restype = ctypes.c_bool
cg.CGEventCreate.argtypes = [ctypes.c_void_p]
cg.CGEventCreate.restype = ctypes.c_void_p
cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
cg.CGEventGetLocation.restype = CGPoint
cg.CFRelease.argtypes = [ctypes.c_void_p]

ids = (ctypes.c_uint32 * 16)()
count = ctypes.c_uint32()
if cg.CGGetActiveDisplayList(16, ids, ctypes.byref(count)) != 0:
    raise SystemExit('CGGetActiveDisplayList failed')

displays = []
for index in range(count.value):
    display_id = ids[index]
    rect = cg.CGDisplayBounds(display_id)
    displays.append({
        'id': display_id,
        'main': bool(cg.CGDisplayIsMain(display_id)),
        'x': rect.origin.x,
        'y': rect.origin.y,
        'width': rect.size.width,
        'height': rect.size.height,
    })

event = cg.CGEventCreate(None)
if not event:
    raise SystemExit('CGEventCreate failed')
point = cg.CGEventGetLocation(event)
cg.CFRelease(event)
print(json.dumps({'displays': displays, 'mouse': {'x': point.x, 'y': point.y}}))
