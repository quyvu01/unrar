// Swift-friendly wrapper around the UnRAR DLL interface.
//
// The UnRAR library in ./unrar is unmodified UnRAR source code by
// Alexander Roshal. License excerpt, as required by the UnRAR license:
//
//   UnRAR source code may be used in any software to handle RAR archives
//   without limitations free of charge, but cannot be used to develop RAR
//   (WinRAR) compatible archiver and to re-create RAR compression algorithm,
//   which is proprietary. Distribution of modified UnRAR source code in
//   separate form or as a part of other software is permitted, provided that
//   full text of this paragraph, starting from "UnRAR source code" words, is
//   included in license, or in documentation if license is not available,
//   and in source code comments of resulting package.

#include "rar.hpp"
#include "cunrar.h"

#include <string>
#include <vector>
#ifndef __APPLE__
#include <locale.h>
#endif

namespace {

// UnRAR converts file names with the C library multibyte functions on
// non-Apple platforms (Apple always uses UTF-8). Make sure they run under a
// UTF-8 locale for the duration of every call, without touching the global
// locale of the host process.
class Utf8LocaleScope {
 public:
  Utf8LocaleScope() {
#ifndef __APPLE__
    static locale_t utf8 = [] {
      const char *names[] = {"C.UTF-8", "C.utf8", "en_US.UTF-8", "UTF-8"};
      for (const char *name : names) {
        locale_t l = newlocale(LC_CTYPE_MASK, name, (locale_t)0);
        if (l != (locale_t)0) return l;
      }
      return (locale_t)0;
    }();
    if (utf8 != (locale_t)0) previous_ = uselocale(utf8);
#endif
  }
  ~Utf8LocaleScope() {
#ifndef __APPLE__
    if (previous_ != (locale_t)0) uselocale(previous_);
#endif
  }

 private:
#ifndef __APPLE__
  locale_t previous_ = (locale_t)0;
#endif
};

const size_t kNameCapacity = 8192;      // wide chars for long file names
const size_t kCommentCapacity = 65536;  // wide chars for archive comments

}  // namespace

struct cunrar_archive {
  HANDLE handle = nullptr;
  uint32_t flags = 0;
  std::wstring password;
  bool has_password = false;
  bool password_requested = false;
  bool cancelled = false;
  std::string missing_volume;
  std::string comment;
  bool has_comment = false;

  cunrar_progress_fn progress = nullptr;
  void *progress_context = nullptr;

  std::vector<wchar_t> name_buffer = std::vector<wchar_t>(kNameCapacity);
  std::string name_utf8;
};

static std::string WideToUtf8(const wchar_t *src) {
  std::wstring w(src);
  std::string out;
  WideToUtf(w, out);
  return out;
}

static int CALLBACK ShimCallback(UINT msg, LPARAM user_data, LPARAM p1,
                                 LPARAM p2) {
  cunrar_archive *a = reinterpret_cast<cunrar_archive *>(user_data);
  if (a == nullptr) return -1;

  switch (msg) {
    case UCM_NEEDPASSWORDW: {
      if (!a->has_password) {
        a->password_requested = true;
        return -1;
      }
      wchar_t *buf = reinterpret_cast<wchar_t *>(p1);
      size_t size = static_cast<size_t>(p2);
      if (buf == nullptr || size == 0) return -1;
      size_t n = a->password.size();
      if (n >= size) n = size - 1;
      wcsncpy(buf, a->password.c_str(), n);
      buf[n] = 0;
      return 1;
    }
    case UCM_NEEDPASSWORD:
      // The wide variant is always asked first; if we reached here the
      // password is genuinely missing.
      if (!a->has_password) a->password_requested = true;
      return -1;
    case UCM_CHANGEVOLUMEW:
      if (p2 == RAR_VOL_ASK) {
        a->missing_volume = WideToUtf8(reinterpret_cast<wchar_t *>(p1));
        return -1;
      }
      return 1;
    case UCM_CHANGEVOLUME:
      if (p2 == RAR_VOL_ASK) {
        if (a->missing_volume.empty())
          a->missing_volume = reinterpret_cast<char *>(p1);
        return -1;
      }
      return 1;
    case UCM_PROCESSDATA:
      if (a->progress != nullptr &&
          a->progress(a->progress_context, static_cast<int64_t>(p2)) != 0) {
        a->cancelled = true;
        return -1;
      }
      return 1;
    case UCM_LARGEDICT:
      // Allow archives created with large (RAR 7) dictionaries.
      return 1;
    default:
      return 0;
  }
}

extern "C" {

cunrar_archive *cunrar_open(const char *path, int list_only,
                            const char *password, int *error) {
  Utf8LocaleScope locale_scope;
  if (error) *error = CUNRAR_SUCCESS;
  if (path == nullptr) {
    if (error) *error = CUNRAR_EOPEN;
    return nullptr;
  }

  cunrar_archive *a = new cunrar_archive();
  if (password != nullptr && *password != 0) {
    UtfToWide(password, a->password);
    a->has_password = true;
  }

  std::wstring path_w;
  UtfToWide(path, path_w);
  std::vector<wchar_t> path_buf(path_w.begin(), path_w.end());
  path_buf.push_back(0);

  std::vector<wchar_t> comment_buf(kCommentCapacity, 0);

  RAROpenArchiveDataEx data;
  memset(&data, 0, sizeof(data));
  data.ArcNameW = path_buf.data();
  data.OpenMode = list_only ? RAR_OM_LIST : RAR_OM_EXTRACT;
  data.CmtBufW = comment_buf.data();
  data.CmtBufSize = static_cast<unsigned int>(comment_buf.size());
  data.Callback = ShimCallback;
  data.UserData = reinterpret_cast<LPARAM>(a);

  a->handle = RAROpenArchiveEx(&data);
  if (a->handle == nullptr || data.OpenResult != ERAR_SUCCESS) {
    int code = static_cast<int>(data.OpenResult);
    if (code == ERAR_SUCCESS) code = CUNRAR_EOPEN;
    if (a->password_requested && code != ERAR_BAD_PASSWORD)
      code = CUNRAR_MISSING_PASSWORD;
    if (error) *error = code;
    if (a->handle) RARCloseArchive(a->handle);
    delete a;
    return nullptr;
  }

  a->flags = data.Flags;
  if (data.CmtState == 1 && data.CmtSize > 0) {
    comment_buf[comment_buf.size() - 1] = 0;
    a->comment = WideToUtf8(comment_buf.data());
    a->has_comment = !a->comment.empty();
  }
  if (a->has_password) {
    std::string pw;
    WideToUtf(a->password, pw);
    RARSetPassword(a->handle, const_cast<char *>(pw.c_str()));
    cleandata(&pw[0], pw.size());
  }
  return a;
}

void cunrar_close(cunrar_archive *a) {
  Utf8LocaleScope locale_scope;
  if (a == nullptr) return;
  if (a->handle) RARCloseArchive(a->handle);
  if (!a->password.empty())
    cleandata(&a->password[0], a->password.size() * sizeof(wchar_t));
  delete a;
}

uint32_t cunrar_archive_flags(const cunrar_archive *a) {
  return a ? a->flags : 0;
}

const char *cunrar_comment(const cunrar_archive *a) {
  if (a == nullptr || !a->has_comment) return nullptr;
  return a->comment.c_str();
}

void cunrar_set_progress(cunrar_archive *a, cunrar_progress_fn fn,
                         void *context) {
  if (a == nullptr) return;
  a->progress = fn;
  a->progress_context = context;
}

static int MapError(cunrar_archive *a, int code) {
  if (a->cancelled) return CUNRAR_CANCELLED;
  if (!a->missing_volume.empty() &&
      (code == ERAR_EOPEN || code == ERAR_BAD_DATA || code == ERAR_EREAD ||
       code == ERAR_UNKNOWN))
    return CUNRAR_MISSING_VOLUME;
  if (a->password_requested && code != ERAR_BAD_PASSWORD &&
      code != ERAR_SUCCESS && code != ERAR_END_ARCHIVE)
    return CUNRAR_MISSING_PASSWORD;
  return code;
}

int cunrar_read_header(cunrar_archive *a, cunrar_entry *entry) {
  Utf8LocaleScope locale_scope;
  if (a == nullptr || entry == nullptr) return CUNRAR_EREFERENCE;

  RARHeaderDataEx header;
  memset(&header, 0, sizeof(header));
  a->name_buffer.assign(kNameCapacity, 0);
  header.FileNameEx = a->name_buffer.data();
  header.FileNameExSize = static_cast<unsigned int>(kNameCapacity);

  int code = RARReadHeaderEx(a->handle, &header);
  if (code != ERAR_SUCCESS) return MapError(a, code);

  a->name_buffer[kNameCapacity - 1] = 0;
  const wchar_t *name_w =
      a->name_buffer[0] != 0 ? a->name_buffer.data() : header.FileNameW;
  a->name_utf8 = WideToUtf8(name_w);

  entry->name = a->name_utf8.c_str();
  entry->unpacked_size =
      (static_cast<uint64_t>(header.UnpSizeHigh) << 32) | header.UnpSize;
  entry->packed_size =
      (static_cast<uint64_t>(header.PackSizeHigh) << 32) | header.PackSize;
  entry->flags = header.Flags;
  entry->crc32 = header.FileCRC;
  entry->host_os = header.HostOS;
  entry->method = header.Method;
  entry->attributes = header.FileAttr;
  entry->unpack_version = header.UnpVer;
  entry->dictionary_size = static_cast<uint64_t>(header.DictSize) * 1024;
  entry->redirect_type = header.RedirType;

  uint64_t filetime =
      (static_cast<uint64_t>(header.MtimeHigh) << 32) | header.MtimeLow;
  // Windows FILETIME: 100 ns intervals since 1601-01-01.
  const uint64_t kEpochDelta = 116444736000000000ULL;
  if (filetime > kEpochDelta)
    entry->modification_time =
        static_cast<double>(filetime - kEpochDelta) / 10000000.0;
  else
    entry->modification_time = 0;
  return CUNRAR_SUCCESS;
}

int cunrar_process(cunrar_archive *a, int operation, const char *dest_path) {
  Utf8LocaleScope locale_scope;
  if (a == nullptr) return CUNRAR_EREFERENCE;

  int op = RAR_SKIP;
  if (operation == CUNRAR_OP_TEST) op = RAR_TEST;
  if (operation == CUNRAR_OP_EXTRACT) op = RAR_EXTRACT;

  int code;
  if (op == RAR_EXTRACT && dest_path != nullptr) {
    std::wstring dest_w;
    UtfToWide(dest_path, dest_w);
    std::vector<wchar_t> dest_buf(dest_w.begin(), dest_w.end());
    dest_buf.push_back(0);
    code = RARProcessFileW(a->handle, op, nullptr, dest_buf.data());
  } else {
    code = RARProcessFileW(a->handle, op, nullptr, nullptr);
  }
  if (code == ERAR_SUCCESS && a->cancelled) return CUNRAR_CANCELLED;
  if (code == ERAR_SUCCESS) return CUNRAR_SUCCESS;
  return MapError(a, code);
}

int cunrar_password_requested(const cunrar_archive *a) {
  return (a && a->password_requested) ? 1 : 0;
}

const char *cunrar_missing_volume(const cunrar_archive *a) {
  if (a == nullptr || a->missing_volume.empty()) return nullptr;
  return a->missing_volume.c_str();
}

int cunrar_version(void) { return RARGetDllVersion(); }

}  // extern "C"
