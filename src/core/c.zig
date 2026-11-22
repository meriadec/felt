//! C bindings for the vendored stb libraries (image decode/encode, TrueType).
pub const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
    @cInclude("stb_truetype.h");
});
