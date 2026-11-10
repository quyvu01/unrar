// A small, Swift-friendly C API on top of the UnRAR library (unrar/dll.hpp).
//
// All strings crossing this boundary are UTF-8. The underlying UnRAR source
// code is © Alexander Roshal and distributed under the UnRAR license, see
// Sources/CUnrar/unrar/license.txt.

#ifndef CUNRAR_H
#define CUNRAR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Error codes (mirror ERAR_* from unrar/dll.hpp).
enum {
  CUNRAR_SUCCESS = 0,
  CUNRAR_END_ARCHIVE = 10,
  CUNRAR_NO_MEMORY = 11,
  CUNRAR_BAD_DATA = 12,
  CUNRAR_BAD_ARCHIVE = 13,
  CUNRAR_UNKNOWN_FORMAT = 14,
  CUNRAR_EOPEN = 15,
  CUNRAR_ECREATE = 16,
  CUNRAR_ECLOSE = 17,
  CUNRAR_EREAD = 18,
  CUNRAR_EWRITE = 19,
  CUNRAR_SMALL_BUF = 20,
  CUNRAR_UNKNOWN = 21,
  CUNRAR_MISSING_PASSWORD = 22,
  CUNRAR_EREFERENCE = 23,
  CUNRAR_BAD_PASSWORD = 24,
  CUNRAR_LARGE_DICT = 25,
  // Shim specific
  CUNRAR_CANCELLED = 1000,
  CUNRAR_MISSING_VOLUME = 1001
};

// Operations for cunrar_process.
enum {
  CUNRAR_OP_SKIP = 0,
  CUNRAR_OP_TEST = 1,
  CUNRAR_OP_EXTRACT = 2
};

// Archive flags (mirror ROADF_*).
enum {
  CUNRAR_ARC_VOLUME = 0x0001,
  CUNRAR_ARC_COMMENT = 0x0002,
  CUNRAR_ARC_LOCK = 0x0004,
  CUNRAR_ARC_SOLID = 0x0008,
  CUNRAR_ARC_NEW_NUMBERING = 0x0010,
  CUNRAR_ARC_SIGNED = 0x0020,
  CUNRAR_ARC_RECOVERY = 0x0040,
  CUNRAR_ARC_ENCRYPTED_HEADERS = 0x0080,
  CUNRAR_ARC_FIRST_VOLUME = 0x0100
};

// Entry flags (mirror RHDF_*).
enum {
  CUNRAR_ENTRY_SPLIT_BEFORE = 0x01,
  CUNRAR_ENTRY_SPLIT_AFTER = 0x02,
  CUNRAR_ENTRY_ENCRYPTED = 0x04,
  CUNRAR_ENTRY_SOLID = 0x10,
  CUNRAR_ENTRY_DIRECTORY = 0x20
};

typedef struct cunrar_archive cunrar_archive;

typedef struct cunrar_entry {
  // UTF-8 path inside the archive, '/' separated. Valid until the next
  // cunrar_read_header / cunrar_close call on the same archive.
  const char *name;
  uint64_t unpacked_size;
  uint64_t packed_size;
  uint32_t flags;
  uint32_t crc32;
  uint32_t host_os;
  uint32_t method;
  uint32_t attributes;
  uint32_t unpack_version;
  uint64_t dictionary_size;
  // Seconds since 1970-01-01 UTC, or 0 when unknown.
  double modification_time;
  // Non-zero when the entry is a symbolic link, hard link or junction.
  uint32_t redirect_type;
} cunrar_entry;

// Progress callback. `bytes` is the number of unpacked bytes processed since
// the previous call. Return 0 to continue or non-zero to cancel.
typedef int (*cunrar_progress_fn)(void *context, int64_t bytes);

// Opens an archive. `list_only` selects header-only mode (fast listing).
// `password` may be NULL. On failure returns NULL and stores the error code
// in `*error`.
cunrar_archive *cunrar_open(const char *path, int list_only,
                            const char *password, int *error);

void cunrar_close(cunrar_archive *archive);

uint32_t cunrar_archive_flags(const cunrar_archive *archive);

// UTF-8 archive comment or NULL.
const char *cunrar_comment(const cunrar_archive *archive);

void cunrar_set_progress(cunrar_archive *archive, cunrar_progress_fn fn,
                         void *context);

// Reads the next header. Returns CUNRAR_SUCCESS, CUNRAR_END_ARCHIVE or an
// error code.
int cunrar_read_header(cunrar_archive *archive, cunrar_entry *entry);

// Skips, tests or extracts the entry returned by the last read_header call.
// For extraction `dest_path` is the full destination path of the file.
int cunrar_process(cunrar_archive *archive, int operation,
                   const char *dest_path);

// Non-zero when the library asked for a password that was not supplied.
int cunrar_password_requested(const cunrar_archive *archive);

// UTF-8 name of the missing volume, or NULL.
const char *cunrar_missing_volume(const cunrar_archive *archive);

int cunrar_version(void);

#ifdef __cplusplus
}
#endif

#endif
