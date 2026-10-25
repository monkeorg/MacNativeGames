#ifndef MNG_FILE_H
#define MNG_FILE_H
#include "mng_container.h"

/* Inspect a caller-owned, open regular file. out must be empty. The descriptor
 * remains open and its seek position is unchanged. A stable before/after stat
 * is required, including size, device/inode, and nanosecond mtime/ctime.
 * Detectable source changes return MNG_IO and discard the inventory. This is
 * not a filesystem snapshot or authentication of the source's contents. */
enum mng_status mng_inspect_fd(int fd, struct mng_inventory *out);
#endif
