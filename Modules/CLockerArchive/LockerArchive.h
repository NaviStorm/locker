// Public libarchive reader ABI provided by the Apple SDK's libarchive.tbd.
#pragma once
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>

struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_format(struct archive *);
int archive_filter_code(struct archive *, int);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);

enum { LOCKER_ARCHIVE_EOF = 1, LOCKER_ARCHIVE_RAW = 0x90000 };
