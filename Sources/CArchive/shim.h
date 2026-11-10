// Swift entry point for libarchive.
//
// archive.h / archive_entry.h are the unmodified public headers of
// libarchive 3.7.2 (BSD 2-clause, see the notice at the top of each file).
// They are vendored because the macOS SDK ships libarchive.tbd (the system
// /usr/lib/libarchive.2.dylib, which is what the app links against) but not
// its headers. On Linux the distribution's libarchive (libarchive-dev) is used.
#ifndef CARCHIVE_SHIM_H
#define CARCHIVE_SHIM_H

#include "archive.h"
#include "archive_entry.h"
#include <locale.h>
#include <stdlib.h>
#if defined(__APPLE__)
#include <xlocale.h>
#endif

/// A UTF-8 LC_CTYPE locale, so libarchive converts entry names to/from UTF-8
/// even when the process runs in the "C" locale (apps launched from Finder).
static inline locale_t carchive_utf8_locale(void) {
    static locale_t cached = (locale_t)0;
    if (cached != (locale_t)0) return cached;
    const char *names[] = { "C.UTF-8", "en_US.UTF-8", "UTF-8", "C.utf8" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        locale_t loc = newlocale(LC_CTYPE_MASK, names[i], (locale_t)0);
        if (loc != (locale_t)0) { cached = loc; return loc; }
    }
    return (locale_t)0;
}

/// Switches the calling thread to the UTF-8 locale. Returns the previous
/// locale, to be passed to carchive_restore_locale.
static inline locale_t carchive_begin_utf8(void) {
    locale_t loc = carchive_utf8_locale();
    if (loc == (locale_t)0) return (locale_t)0;
    return uselocale(loc);
}

static inline void carchive_restore_locale(locale_t previous) {
    if (previous != (locale_t)0) uselocale(previous);
}

#endif
