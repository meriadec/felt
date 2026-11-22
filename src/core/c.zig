//! C bindings for the vendored C libraries: stb (image decode/encode,
//! TrueType) and libdeflate (zlib streams for the fast PNG path).
pub const c = @cImport({
    @cInclude("libdeflate.h");
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
    @cInclude("stb_truetype.h");
});
