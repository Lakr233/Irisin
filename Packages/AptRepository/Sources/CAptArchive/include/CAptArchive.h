// The part of libarchive that AptRepository calls, declared here so that no
// Swift file imports the binary's own module.
//
// The libarchive.xcframework package ships a Swift wrapper named `LibArchive`
// around a binary module named `libarchive`. xcodebuild puts
// `LibArchive.swiftmodule` in one flat Products directory, and on a
// case-insensitive volume a Swift compiler asked for `libarchive` opens that
// file and refuses it: "cannot load module 'LibArchive' as 'libarchive'".
// A C target never asks for a Swift module, so the question is not put.
//
// These are libarchive's prototypes, spelled with the types its own headers
// resolve to on Apple platforms. CAptArchive.c includes both, so a prototype
// that drifts from the binary's stops the build. Add a function here when
// Swift needs another one.

#ifndef CAPTARCHIVE_H
#define CAPTARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define	ARCHIVE_EOF	  1	/* Found end of archive. */
#define	ARCHIVE_OK	  0	/* Operation was successful. */

typedef ssize_t archive_read_callback(struct archive *, void *_client_data, const void **_buffer);
typedef int archive_open_callback(struct archive *, void *_client_data);
typedef int archive_close_callback(struct archive *, void *_client_data);

struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_ar(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_open(
    struct archive *,
    void *_client_data,
    archive_open_callback *,
    archive_read_callback *,
    archive_close_callback *
);
int archive_read_open_filename(struct archive *, const char *_filename, size_t _block_size);
int archive_read_open_memory(struct archive *, const void *buff, size_t size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
const char *archive_error_string(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_uname(struct archive_entry *);
const char *archive_entry_gname(struct archive_entry *);
int64_t archive_entry_uid(struct archive_entry *);
int64_t archive_entry_gid(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);

#endif
