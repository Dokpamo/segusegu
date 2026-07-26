# C ABI binding

`include/lorepia.h` is the stable Windows interop contract. The ABI exposes an
opaque core handle and owned byte buffers; callers release every returned buffer
with `lorepia_buffer_free` and every handle with `lorepia_core_destroy`.

The C# application must call this API only through `Lorepia.Native`.
