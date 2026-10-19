/*
 * hg_plugin.h — the hyprglaze effect ABI.
 *
 * An effect is a shared object exporting `hg_module_entry`. The host loads it
 * with dlopen(RTLD_NOW|RTLD_LOCAL), checks `abi_version`, and drives one
 * instance through create/update/upload/destroy. Plugins may call GL directly;
 * the host guarantees a current GL ES 3.0 context for `upload` and (as a
 * convenience) for Create-time state, but a plugin must create GL objects
 * lazily in `upload`, never in `create` (a fresh plugin may be built while the
 * previous GL context is being torn down).
 *
 * Bump HG_ABI_VERSION on any incompatible change to these structs. The host
 * refuses a module whose version differs.
 */
#ifndef HG_PLUGIN_H
#define HG_PLUGIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HG_ABI_VERSION 2

/* A window rectangle in surface pixels, plus its Hyprland address. */
typedef struct hg_rect {
    float    x, y, w, h;
    uint64_t address;
} hg_rect;

/* Truncated class/title of one mapped window, parallel to hg_frame.windows. */
typedef struct hg_window_info {
    char    class[64];
    uint8_t class_len;
    char    title[64];
    uint8_t title_len;
} hg_window_info;

/*
 * One frame of desktop state. All pointers are valid only for the duration of
 * `update`; copy anything kept past the call.
 */
typedef struct hg_frame {
    float    dt;                 /* clamped seconds since the last frame    */
    double   time;               /* seconds since the daemon started        */
    float    cursor[2];          /* smoothed cursor, surface pixels         */
    hg_rect  focused_win;        /* smoothed focused-window rect            */
    const hg_rect*        windows;      uint64_t windows_len;
    const hg_window_info* window_info;
    char     focused_class[64];  uint8_t focused_class_len;
    char     focused_title[64];  uint8_t focused_title_len;
    const float*  palette;       uint32_t palette_len;   /* 3*len rgb        */
    float    palette_bg[3];
    float    palette_fg[3];
    float    workspace_slide;    /* 0 = switch mid-slide, 1 = settled       */
    uint32_t workspace_switches; /* bumped on every workspace change        */
    const uint64_t* closed_windows; uint64_t closed_windows_len;
    const float*  wave;          uint64_t wave_len;      /* 128L+128R stereo */
} hg_frame;

/*
 * Per-effect config accessors, backed by the host's TOML `[<effect>]`
 * section. `key` is NUL-terminated. Strings are borrowed for the call only.
 */
typedef struct hg_params {
    float    (*get_f32)(void* ctx, const char* key, float def);
    int64_t  (*get_i64)(void* ctx, const char* key, int64_t def);
    int      (*get_bool)(void* ctx, const char* key, int def);
    const char* (*get_str)(void* ctx, const char* key, uint64_t* out_len);
} hg_params;

typedef struct hg_host {
    uint32_t   abi_version;
    hg_params  params;
    void*      params_ctx;
} hg_host;

typedef struct hg_module {
    uint32_t    abi_version;
    const char* id;       /* stable effect name, e.g. "weft"             */
    const char* shader;   /* .frag next to the module, or NULL for default */
    /*
     * Config section the host reads this module's params and audio settings
     * (`music`, `sink`) from. NULL means the module's `id`. Effects that
     * intentionally share another effect's section (starfield and milkdrop
     * read the shared [visualizer] knobs) set this to that name.
     */
    const char* config_section;
    int         wants_audio; /* nonzero: host fills hg_frame.wave        */

    void* (*create)(const hg_host* host, float width, float height);
    void  (*update)(void* self, const hg_frame* frame);
    void  (*upload)(void* self, uint32_t program);
    void  (*destroy)(void* self);
} hg_module;

/* The single export every effect shared object must provide. */
const hg_module* hg_module_entry(void);

#ifdef __cplusplus
}
#endif

#endif /* HG_PLUGIN_H */
