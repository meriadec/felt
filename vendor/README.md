# Vendored dependencies

All third-party code and data live here. Update a file only in its own commit.

| File | Source | Version | License |
|---|---|---|---|
| `stb/stb_image.h` | https://raw.githubusercontent.com/nothings/stb/master/stb_image.h | v2.34, stb commit `6b5799bae8a1fe3792691ef4b72ae26434c3e799` | Public domain / MIT |
| `stb/stb_image_write.h` | https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h | v1.19, same commit | Public domain / MIT |
| `stb/stb_truetype.h` | https://raw.githubusercontent.com/nothings/stb/master/stb_truetype.h | v1.28, same commit | Public domain / MIT |
| `stb/stb_impl.c` | ours: compiles stb, routes big stb buffers to huge pages | - | - |
| `libdeflate/` | https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.26.tar.gz: `lib/` (without `gzip_*`), `common_defs.h`, `libdeflate.h`, `COPYING` | v1.26 | MIT, see `libdeflate/COPYING` |
| `fonts/DejaVuSans-Bold.ttf` | Debian `fonts-dejavu-core` (`/usr/share/fonts/truetype/dejavu/`), DejaVu 2.37 | 2.37 | Bitstream Vera, see `fonts/LICENSE-DejaVu.txt` |

build.zig compiles only the libdeflate files that zlib (de)compression needs.

To update stb: download the three headers from the URLs above, record the new
commit (`curl -s https://api.github.com/repos/nothings/stb/commits/master | grep -m1 sha`),
then run `zig build test`.
