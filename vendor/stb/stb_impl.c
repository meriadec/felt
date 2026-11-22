// Compiles the stb single-header libraries once for the whole program.
//
// stb_image allocates several frame-sized buffers per decode. Big blocks get
// their own mapping with transparent huge pages: far fewer page faults on a
// 4K screenshot (see docs/perf.md). Small blocks use malloc.
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <malloc.h>

#define BIG_BLOCK (4u << 20)
#define HDR 64 /* keeps 64-byte alignment and stores the mapping size */

static void *annotate_malloc(size_t n) {
    if (n < BIG_BLOCK) {
        unsigned char *p = malloc(n + HDR);
        if (!p) return NULL;
        *(size_t *)p = 0;
        return p + HDR;
    }
    size_t len = (n + HDR + (2u << 20) - 1) & ~(size_t)((2u << 20) - 1);
    unsigned char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    madvise(p, len, MADV_HUGEPAGE);
    *(size_t *)p = len;
    return p + HDR;
}

static void annotate_free(void *q) {
    if (!q) return;
    unsigned char *p = (unsigned char *)q - HDR;
    size_t len = *(size_t *)p;
    if (len) munmap(p, len); else free(p);
}

static void *annotate_realloc(void *q, size_t n) {
    if (!q) return annotate_malloc(n);
    unsigned char *p = (unsigned char *)q - HDR;
    size_t len = *(size_t *)p;
    if (!len && n < BIG_BLOCK) {
        unsigned char *r = realloc(p, n + HDR);
        return r ? r + HDR : NULL;
    }
    if (len && n + HDR <= len) return q;
    void *r = annotate_malloc(n);
    if (!r) return NULL;
    size_t old = len ? len - HDR : malloc_usable_size(p) - HDR;
    memcpy(r, q, old < n ? old : n);
    annotate_free(q);
    return r;
}

#define STBI_MALLOC(sz) annotate_malloc(sz)
#define STBI_REALLOC(p, sz) annotate_realloc(p, sz)
#define STBI_FREE(p) annotate_free(p)

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
