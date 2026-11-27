//! C bindings for the vendored C libraries: stb (image decode/encode,
//! TrueType) and libdeflate (zlib streams for the fast PNG path).
pub const c = @import("c_api");
