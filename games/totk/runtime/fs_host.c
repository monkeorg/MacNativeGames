/* nn::fs host implementation for the functions main imports. RomFS paths and handles go to the
   verified read-only backend (romfs.c); save, temporary and cache storage are host directories under
   the profile directory. Application save data is created on first start, as the system launcher does
   for titles that declare save data. Writes reach the host file immediately; Commit flushes them.
   Because of that, quitting in the middle of a save (the game writes several files, then commits) would leave a slot half
   written: runtime_fs_save_busy tells the window close to wait until the save is done (runtime/frontend.m). */
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
/* Both native iOS launchers retain guest-closed save descriptors until a real
 * successful flush. Standalone Mac behavior remains on its original path. */
#if defined(CANOPY_HOST_RUNTIME) || (defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE)
#define TOTK_SAFE_SAVE_FLUSH 1
#else
#define TOTK_SAFE_SAVE_FLUSH 0
#endif
#include "autoload.h"
#include "runtime.h"
#include "fs_host.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

#define R_PATH_NOT_FOUND 0x202u
#define R_ALREADY_EXISTS 0x402u
#define R_NOT_EMPTY 0x1002u
#define R_TARGET_NOT_FOUND 0x7d402u
#define R_INVALID_ARGUMENT 0x2ee202u
#define R_INVALID_PATH 0x2ee602u
#define R_OPEN_MODE 0x307402u
#define R_APPEND_REQUIRED 0x2f5e02u
#ifdef GAME_BOTW
#define TOTK_APPLICATION_ID 0x01007ef00011e000ULL   /* Breath of the Wild: its own save data is the one that exists */
#else
#define TOTK_APPLICATION_ID 0x0100f2c0115b6000ULL
#endif
enum { M_FREE, M_SAVE, M_TEMP, M_CACHE };
enum { OPEN_READ = 1, OPEN_WRITE = 2, OPEN_APPEND = 4 };
#define FILE_BASE 0x200000000ULL
#define DIR_BASE 0x300000000ULL
#define NFILES 1024
#define NDIRS 256

typedef struct { int kind; char name[32]; char root[1024]; } Mount;
typedef struct { int fd, mode, save; } File;   /* save: on a save-data mount (counts for runtime_fs_save_busy) */
typedef struct { DIR *dir; char path[1024]; int mode; } Dir;
static Mount mounts[16];
static File files[NFILES];
static Dir dirs[NDIRS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
#if TOTK_SAFE_SAVE_FLUSH
/* Serialize mutating host operations with flush/close. Guest-closed save
 * descriptors remain owned in the existing bounded table with mode0 until a
 * successful save commit. They are neither guest handles nor reusable slots.
 * This is payload flush correctness, not a CPU-stop or crash-transaction ACK. */
static pthread_mutex_t canopy_io_lock = PTHREAD_MUTEX_INITIALIZER;
static int canopy_sync_fd(int fd) {
    int result;
    do { result=fcntl(fd,F_FULLFSYNC); } while (result<0 && errno==EINTR);
    return result;
}
#endif
static char profile[1024], save_root[1024];
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void need(int c, const char *m) { if (!c) runtime_fail(m); }

/* Save in progress: a save-data file open for writing, or save data changed in the last 3 s and not committed yet (TOTK
   writes a slot's files back to back and then commits; between the files nothing is open for a moment). */
static _Atomic int save_writers, save_dirty;
static _Atomic uint64_t save_changed_ns;
static void save_touched(void) { atomic_store(&save_changed_ns, runtime_now_ns()); atomic_store(&save_dirty, 1); }
int runtime_fs_save_busy(void) {
    if (atomic_load(&save_writers) > 0) return 1;
#if TOTK_SAFE_SAVE_FLUSH
    /* An unsuccessful flush never ages into an apparent clean state. This
     * signal still is not a guest-thread stop or multi-file transaction ACK. */
    return atomic_load(&save_dirty);
#else
    return atomic_load(&save_dirty) && runtime_now_ns() - atomic_load(&save_changed_ns) < 3000000000ull;
#endif
}
static void make_dir(const char *p) { if (mkdir(p, 0700) && errno != EEXIST) runtime_fail("create profile storage directory"); }
static int remove_tree(const char *path) {
    DIR *d = opendir(path); if (!d) return errno == ENOENT ? 0 : -1;
    struct dirent *e; int ok = 0; char child[2048];
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        snprintf(child, sizeof child, "%s/%s", path, e->d_name);
        ok |= e->d_type == DT_DIR ? remove_tree(child) : unlink(child);
    }
    closedir(d);
    return ok | rmdir(path);
}
#if defined(CANOPY_HOST_RUNTIME)
static int canopy_save_path(const char *p) {
    if (!p || *p!='/' || strnlen(p,sizeof(save_root))>=sizeof(save_root)) return 0;
    const char *part=p+1;
    while (*part) {
        const char *end=strchr(part,'/'); size_t n=end ? (size_t)(end-part):strlen(part);
        if (!n || (n==1 && part[0]=='.') || (n==2 && part[0]=='.' && part[1]=='.')) return 0;
        if (!end) return 1;
        part=end+1;
    }
    return 0;
}
#endif
static void init(void) {
    const char *dir = getenv("TOTK_PROFILE_DIR"); if (!dir) dir = "user-data";
    need(snprintf(profile, sizeof profile, "%s", dir) < (int)sizeof profile, "profile path");
    uint64_t uid[2]; runtime_account_uid(uid);
    char p[1100]; make_dir(profile);
#if defined(CANOPY_HOST_RUNTIME)
    const char *canopy_save = getenv("CANOPY_SAVE_DIR");
    if (canopy_save) {
        /* Account identity remains outside active save replacement. */
        need(canopy_save_path(canopy_save), "Canopy save path");
        need(snprintf(save_root,sizeof(save_root),"%s",canopy_save)<(int)sizeof(save_root), "Canopy save path");
    } else {
#endif
    snprintf(p, sizeof p, "%s/save", profile); make_dir(p);
    need(snprintf(save_root, sizeof save_root, "%s/save/%016llx%016llx", profile, (unsigned long long)uid[1], (unsigned long long)uid[0]) < (int)sizeof save_root, "save path");
#if defined(CANOPY_HOST_RUNTIME)
    }
#endif
    make_dir(save_root);                                   /* launcher-style EnsureSaveData */
    snprintf(p, sizeof p, "%s/temp", profile); remove_tree(p); make_dir(p);
    snprintf(p, sizeof p, "%s/cache", profile); make_dir(p);
#if defined(CANOPY_HOST_RUNTIME)
    fprintf(stderr, "[totk] host save storage initialized\n");
#else
    fprintf(stderr, "[totk] host save storage: %s\n", save_root);
#endif
}
static void ready(void) { pthread_once(&once, init); }

/* ---------- mounts and paths ---------- */
static unsigned mount_add(const char *name, int kind, const char *root) {
    if (!name || !*name || strlen(name) >= 32 || strchr(name, ':') || strchr(name, '/')) return R_INVALID_ARGUMENT;
    pthread_mutex_lock(&lock);
    int slot = -1;
    for (int i = 0; i < 16; i++) { if (mounts[i].kind && !strcmp(mounts[i].name, name)) { pthread_mutex_unlock(&lock); return R_ALREADY_EXISTS; } if (!mounts[i].kind && slot < 0) slot = i; }
    if (slot < 0) runtime_fail("fs mount table full");
    mounts[slot].kind = kind; strcpy(mounts[slot].name, name); snprintf(mounts[slot].root, sizeof mounts[slot].root, "%s", root);
    pthread_mutex_unlock(&lock);
#if defined(CANOPY_HOST_RUNTIME)
    fprintf(stderr, "[totk] fs mount initialized\n");
#else
    fprintf(stderr, "[totk] fs mount %s: -> %s\n", name, root);
#endif
    return 0;
}
static int component_ok(const char *c, size_t n) { return n && !(n == 1 && c[0] == '.') && !(n == 2 && c[0] == '.' && c[1] == '.'); }
/* "name:/a/b" -> host path; 0 on success; *kind = the mount's kind (M_SAVE ...) when kind is given */
static unsigned host_path_kind(const char *path, char *out, size_t cap, int *kind) {
    if (!path) return R_INVALID_PATH;
    const char *colon = strchr(path, ':');
    if (!colon || colon[1] != '/') return R_INVALID_PATH;
    size_t n = (size_t)(colon - path);
    pthread_mutex_lock(&lock);
    const Mount *m = NULL;
    for (int i = 0; i < 16; i++) if (mounts[i].kind && strlen(mounts[i].name) == n && !strncmp(mounts[i].name, path, n)) m = &mounts[i];
    char root[1024]; if (m) strcpy(root, m->root);
    int k = m ? m->kind : M_FREE;
    pthread_mutex_unlock(&lock);
    if (!m) return R_PATH_NOT_FOUND;
    if (kind) *kind = k;
    const char *rest = colon + 1;
    for (const char *q = rest + 1; *q;) { const char *e = strchr(q, '/'); size_t len = e ? (size_t)(e - q) : strlen(q); if (!e && !len) break; if (!component_ok(q, len) || memchr(q, '\\', len)) return R_INVALID_PATH; q = e ? e + 1 : q + len; }
    if (snprintf(out, cap, "%s%s", root, rest) >= (int)cap) return R_INVALID_PATH;
    size_t L = strlen(out); while (L > strlen(root) && out[L - 1] == '/') out[--L] = 0;
    return 0;
}
static unsigned host_path(const char *path, char *out, size_t cap) { return host_path_kind(path, out, cap, NULL); }
/* A change to save data through a path (create, delete, rename, directories): marks the save as in progress. */
static unsigned save_change_path(const char *path, char *out, size_t cap) {
    int kind = M_FREE; unsigned r = host_path_kind(path, out, cap, &kind);
    if (!r && kind == M_SAVE) save_touched();
    return r;
}
static unsigned errno_result(void) { return errno == ENOENT || errno == ENOTDIR ? R_PATH_NOT_FOUND : errno == EEXIST ? R_ALREADY_EXISTS : errno == ENOTEMPTY ? R_NOT_EMPTY : R_INVALID_ARGUMENT; }

/* ---------- storage mounts ---------- */
static unsigned mount_save(const char *name, const uint64_t *uid) {
    ready(); uint64_t me[2]; runtime_account_uid(me);
    if (!uid || uid[0] != me[0] || uid[1] != me[1]) return R_TARGET_NOT_FOUND;
    return mount_add(name, M_SAVE, save_root);
}
static unsigned char save_exists(uint64_t application, const uint64_t *uid) {
    ready(); uint64_t me[2]; runtime_account_uid(me);
    return application == TOTK_APPLICATION_ID && uid && uid[0] == me[0] && uid[1] == me[1];
}
/* Other titles' save data (e.g. data-link bonuses) is not present on this host. */
static unsigned mount_save_ro(const char *name, uint64_t application, const uint64_t *uid) {
    if (!save_exists(application, uid)) return R_TARGET_NOT_FOUND;
    return mount_add(name, M_SAVE, save_root);
}
static unsigned mount_temp(const char *name) { ready(); char p[1100]; snprintf(p, sizeof p, "%s/temp", profile); return mount_add(name, M_TEMP, p); }
static void cache_dir(int index, char *out, size_t cap) { snprintf(out, cap, "%s/cache/%d", profile, index); }
static unsigned create_cache(int index, int64_t size, int64_t journal) {
    ready(); if (index < 0 || size < 0 || journal < 0) return R_INVALID_ARGUMENT;
    char p[1100]; cache_dir(index, p, sizeof p);
    if (mkdir(p, 0700)) return errno == EEXIST ? R_ALREADY_EXISTS : errno_result();
    return 0;
}
static unsigned delete_cache(int index) { ready(); char p[1100]; cache_dir(index, p, sizeof p); return remove_tree(p) ? R_TARGET_NOT_FOUND : 0; }
static unsigned mount_cache(const char *name, int index) {
    ready(); char p[1100]; cache_dir(index, p, sizeof p); struct stat st;
    if (stat(p, &st) || !S_ISDIR(st.st_mode)) return R_TARGET_NOT_FOUND;
    return mount_add(name, M_CACHE, p);
}
typedef struct { int32_t index; uint8_t reserved[0x1c]; } CacheStorageInfo;
typedef struct { int list[64]; int count, next; } CacheList;
static unsigned open_cache_list(uint64_t *out) {
    ready(); if (!out) return R_INVALID_ARGUMENT;
    CacheList *l = calloc(1, sizeof *l); need(l != NULL, "cache list allocation");
    char p[1100]; snprintf(p, sizeof p, "%s/cache", profile); DIR *d = opendir(p); struct dirent *e;
    while (d && (e = readdir(d)) && l->count < 64) { char *end; long v = strtol(e->d_name, &end, 10); if (*e->d_name && !*end && v >= 0) l->list[l->count++] = (int)v; }
    if (d) closedir(d);
    *out = (uint64_t)(uintptr_t)l; return 0;
}
static unsigned read_cache_list(int *count, CacheStorageInfo *out, uint64_t h, int max) {
    CacheList *l = (CacheList *)(uintptr_t)h; if (!l || !count || max < 0 || (!out && max)) return R_INVALID_ARGUMENT;
    int n = 0; while (n < max && l->next < l->count) { memset(&out[n], 0, sizeof *out); out[n++].index = l->list[l->next++]; }
    *count = n; return 0;
}
static void close_cache_list(uint64_t h) { free((void *)(uintptr_t)h); }
static void unmount(const char *name) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < 16; i++) if (mounts[i].kind && !strcmp(mounts[i].name, name)) { mounts[i].kind = M_FREE; pthread_mutex_unlock(&lock); return; }
    pthread_mutex_unlock(&lock);
    BOTW_AOC_UNMOUNT(name) if (!runtime_romfs_owns(name)) runtime_fail("unmount of unknown fs mount");
}
static unsigned commit(const char *name) {
#if TOTK_SAFE_SAVE_FLUSH
    if (!name)return R_INVALID_ARGUMENT;
#endif
    pthread_mutex_lock(&lock); int found = 0, save = 0;
    for (int i = 0; i < 16; i++) if (mounts[i].kind && !strcmp(mounts[i].name, name)) { found = 1; save = mounts[i].kind == M_SAVE; }
    pthread_mutex_unlock(&lock);
    if (!found) return R_PATH_NOT_FOUND;
#if TOTK_SAFE_SAVE_FLUSH
    pthread_mutex_lock(&canopy_io_lock);
    unsigned result=0;
    for (int i=0;i<NFILES;i++) {
        /* All safe-path open/write/resize/close paths hold canopy_io_lock, so
         * this descriptor cannot close or be reused during F_FULLFSYNC. */
        if (files[i].fd>0 && (save ? files[i].save : (files[i].mode&OPEN_WRITE))) {
            if (canopy_sync_fd(files[i].fd)) { result=errno_result();break; }
        }
    }
    if (save) {
        if (result) atomic_store(&save_dirty,1);
        else {
            pthread_mutex_lock(&lock);
            for (int i=0;i<NFILES;i++) if (files[i].fd>0 && files[i].save && !files[i].mode) {
                close(files[i].fd);memset(files+i,0,sizeof(files[i]));
            }
            pthread_mutex_unlock(&lock);
            atomic_store(&save_dirty,0);
        }
    }
    pthread_mutex_unlock(&canopy_io_lock);
    return result;
#else
    for (int i = 0; i < NFILES; i++) { pthread_mutex_lock(&lock); int fd = files[i].fd; pthread_mutex_unlock(&lock); if (fd > 0) fcntl(fd, F_FULLFSYNC); }
    if (save && !(getenv("TOTK_PROBE_NEGATIVE") && atoi(getenv("TOTK_PROBE_NEGATIVE")) == 23)) atomic_store(&save_dirty, 0);   /* 23: probe-save's negative control */
#endif
    return 0;
}

/* ---------- files ---------- */
static File *file_of(uint64_t h, int *fd, int *mode) {
    if (h < FILE_BASE || h >= FILE_BASE + NFILES) return NULL;
    pthread_mutex_lock(&lock); File *f = &files[h - FILE_BASE]; int v = f->fd; if (fd) *fd = f->fd; if (mode) *mode = f->mode;
#if TOTK_SAFE_SAVE_FLUSH
    int active=f->mode;
#endif
    pthread_mutex_unlock(&lock);
#if TOTK_SAFE_SAVE_FLUSH
    return v>0 && active ? f:NULL; /* mode0 is an owned, guest-closed save fd */
#else
    return v > 0 ? f : NULL;
#endif
}
void runtime_fs_log(const char *what, const char *path);
static unsigned open_file(uint64_t *out, const char *path, int mode) {
    if (path && !runtime_romfs_owns(path)) runtime_fs_log(mode & 2 ? "write" : "read", path);
    if (runtime_romfs_owns(path)) return runtime_romfs_open(out, path, mode); BOTW_AOC_OPEN(out, path, mode)
    if (!out || !(mode & (OPEN_READ | OPEN_WRITE)) || (mode & ~7)) return R_INVALID_ARGUMENT;
    char p[1100]; int kind = M_FREE; unsigned r = host_path_kind(path, p, sizeof p, &kind); if (r) return r;
#if TOTK_SAFE_SAVE_FLUSH
    pthread_mutex_lock(&canopy_io_lock);
    struct stat st; unsigned result=0;
    if (stat(p,&st) || !S_ISREG(st.st_mode)) { result=R_PATH_NOT_FOUND;goto canopy_open_done; }
    int save_writer=kind==M_SAVE && (mode&OPEN_WRITE);
    int fd=open(p,(mode&OPEN_WRITE ? (mode&OPEN_READ ? O_RDWR:O_WRONLY):O_RDONLY)|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) { result=errno_result();goto canopy_open_done; }
    if (!fd) { int copy=fcntl(fd,F_DUPFD_CLOEXEC,3);int saved=errno;close(fd);fd=copy;errno=saved; }
    if (fd<0) { result=errno_result();goto canopy_open_done; }
    pthread_mutex_lock(&lock);
    int slot=-1;for (int i=0;i<NFILES;i++) if (files[i].fd<=0) {slot=i;break;}
    if (slot>=0) { files[slot]=(File){fd,mode,save_writer};*out=FILE_BASE+(uint64_t)slot; }
    pthread_mutex_unlock(&lock);
    if (slot<0) { close(fd);result=R_INVALID_ARGUMENT;goto canopy_open_done; }
    runtime_autoload_save_file_opened(path);
    if (save_writer) { atomic_fetch_add(&save_writers,1);save_touched(); }
canopy_open_done:
    pthread_mutex_unlock(&canopy_io_lock);return result;
#else
    struct stat st; if (stat(p, &st)) return R_PATH_NOT_FOUND; if (!S_ISREG(st.st_mode)) return R_PATH_NOT_FOUND;
    int save_writer = kind == M_SAVE && (mode & OPEN_WRITE);
    int fd = open(p, (mode & OPEN_WRITE ? (mode & OPEN_READ ? O_RDWR : O_WRONLY) : O_RDONLY) | O_NOFOLLOW);
    if (fd < 0) return errno_result();
    runtime_autoload_save_file_opened(path);   /* TOTK_AUTOLOAD: a slot's caption.sav starts the presses, its progress.sav ends them */
    pthread_mutex_lock(&lock);
    for (int i = 0; i < NFILES; i++) if (files[i].fd <= 0) {
        files[i] = (File){fd, mode, save_writer}; *out = FILE_BASE + (uint64_t)i; pthread_mutex_unlock(&lock);
        if (save_writer) { atomic_fetch_add(&save_writers, 1); save_touched(); }
        return 0;
    }
    pthread_mutex_unlock(&lock); runtime_fail("host file handle table full");
#endif
}
static unsigned read_file(uint64_t *out, uint64_t h, int64_t offset, void *buffer, uint64_t size) {
    if (runtime_romfs_handle(h)) return runtime_romfs_read(out, h, offset, buffer, size); BOTW_AOC_READ(out, h, offset, buffer, size)
    int fd, mode; if (!out || offset < 0 || (!buffer && size) || !file_of(h, &fd, &mode)) return R_INVALID_ARGUMENT;
    if (!(mode & OPEN_READ)) return R_OPEN_MODE;
    dm_guest_write_prepare(buffer, (size_t)size);
    uint64_t done = 0;
    while (done < size) { ssize_t n = pread(fd, (uint8_t *)buffer + done, (size_t)(size - done), offset + (off_t)done); if (n < 0) runtime_fail("host save read failure"); if (!n) break; done += (uint64_t)n; }
    *out = done; return 0;
}
static unsigned read_options(uint64_t *out, uint64_t h, int64_t off, void *buf, uint64_t size, const void *options) { (void)options; return read_file(out, h, off, buf, size); }
static unsigned read_exact(uint64_t h, int64_t off, void *buf, uint64_t size) { uint64_t n = 0; unsigned r = read_file(&n, h, off, buf, size); return r ? r : n == size ? 0 : R_INVALID_ARGUMENT; }
static unsigned write_file(uint64_t h, int64_t offset, const void *buffer, uint64_t size, const int32_t *option) {
#if TOTK_SAFE_SAVE_FLUSH
    pthread_mutex_lock(&canopy_io_lock);
    unsigned result=0;int fd,mode;struct stat st;
    File *f=offset<0 || (!buffer&&size) ? NULL:file_of(h,&fd,&mode);
    if (!f) { result=R_INVALID_ARGUMENT;goto canopy_write_done; }
    if (!(mode&OPEN_WRITE)) { result=R_OPEN_MODE;goto canopy_write_done; }
    if (fstat(fd,&st)) { result=errno_result();goto canopy_write_done; }
    if (size>(uint64_t)INT64_MAX-(uint64_t)offset) { result=R_INVALID_ARGUMENT;goto canopy_write_done; }
    if ((uint64_t)offset+size>(uint64_t)st.st_size && !(mode&OPEN_APPEND)) { result=R_APPEND_REQUIRED;goto canopy_write_done; }
    if (f->save)save_touched();
    for (uint64_t done=0;done<size;) {
        size_t request=size-done>65536 ? 65536:(size_t)(size-done);
        ssize_t n=pwrite(fd,(const uint8_t *)buffer+done,request,offset+(off_t)done);
        if (n<0 && errno==EINTR)continue;
        if (n<=0) { result=n<0 ? errno_result():R_INVALID_ARGUMENT;goto canopy_write_done; }
        done+=(uint64_t)n;
    }
    if (option && (*option&1) && canopy_sync_fd(fd)) { if (f->save)atomic_store(&save_dirty,1);result=errno_result(); }
canopy_write_done:
    pthread_mutex_unlock(&canopy_io_lock);return result;
#else
    int fd, mode; File *f = offset < 0 || (!buffer && size) ? NULL : file_of(h, &fd, &mode); if (!f) return R_INVALID_ARGUMENT;
    if (!(mode & OPEN_WRITE)) return R_OPEN_MODE;
    struct stat st; if (fstat(fd, &st)) runtime_fail("host save stat");
    if ((uint64_t)offset + size > (uint64_t)st.st_size && !(mode & OPEN_APPEND)) return R_APPEND_REQUIRED;
    uint64_t done = 0;
    if (f->save) {
        save_touched();
        static int delay_ms = -1; if (delay_ms < 0) { const char *e = getenv("TOTK_SAVE_WRITE_DELAY_MS"); delay_ms = e ? atoi(e) : 0; }
        if (delay_ms > 0) usleep((useconds_t)delay_ms * 1000);   /* tests only: slow saves down so a window close lands in the middle of one */
    }
    while (done < size) { ssize_t n = pwrite(fd, (const uint8_t *)buffer + done, (size_t)(size - done), offset + (off_t)done); if (n <= 0) runtime_fail("host save write failure"); done += (uint64_t)n; }
    if (option && (*option & 1)) fcntl(fd, F_FULLFSYNC);
    return 0;
#endif
}
static unsigned file_size(int64_t *out, uint64_t h) {
    if (runtime_romfs_handle(h)) return runtime_romfs_size(out, h); BOTW_AOC_SIZE(out, h)
    int fd; struct stat st; if (!out || !file_of(h, &fd, NULL) || fstat(fd, &st)) return R_INVALID_ARGUMENT;
    *out = st.st_size; return 0;
}
static unsigned set_file_size(uint64_t h, int64_t size) {
#if TOTK_SAFE_SAVE_FLUSH
    pthread_mutex_lock(&canopy_io_lock);
    int fd,mode;unsigned result=0;
    if (size<0 || !file_of(h,&fd,&mode)) result=R_INVALID_ARGUMENT;
    else if (!(mode&OPEN_WRITE))result=R_OPEN_MODE;
    else { if (files[h-FILE_BASE].save)save_touched();if (ftruncate(fd,size))result=errno_result(); }
    pthread_mutex_unlock(&canopy_io_lock);return result;
#else
    int fd, mode; if (size < 0 || !file_of(h, &fd, &mode)) return R_INVALID_ARGUMENT;
    if (!(mode & OPEN_WRITE)) return R_OPEN_MODE;
    if (files[h - FILE_BASE].save) save_touched();
    return ftruncate(fd, size) ? errno_result() : 0;
#endif
}
static unsigned flush_file(uint64_t h) {
#if TOTK_SAFE_SAVE_FLUSH
    pthread_mutex_lock(&canopy_io_lock);int fd;unsigned result=0;
    File *f=file_of(h,&fd,NULL);
    if (!f)result=R_INVALID_ARGUMENT;
    else if (canopy_sync_fd(fd)) { if (f->save)atomic_store(&save_dirty,1);result=errno_result(); }
    pthread_mutex_unlock(&canopy_io_lock);return result;
#else
    int fd; if (!file_of(h, &fd, NULL)) return R_INVALID_ARGUMENT; fcntl(fd, F_FULLFSYNC); return 0;
#endif
}
static void close_file(uint64_t h) {
    if (runtime_romfs_handle(h)) { runtime_romfs_close(h); return; } BOTW_AOC_CLOSE(h)
#if TOTK_SAFE_SAVE_FLUSH
    pthread_mutex_lock(&canopy_io_lock);
    if (!file_of(h,NULL,NULL)) { pthread_mutex_unlock(&canopy_io_lock);runtime_fail("close invalid file handle"); }
    pthread_mutex_lock(&lock);File *f=files+(h-FILE_BASE);int fd=f->fd,save=f->save;
    if (save)f->mode=0;else memset(f,0,sizeof(*f));
    pthread_mutex_unlock(&lock);
    if (save) { save_touched();atomic_fetch_sub(&save_writers,1); } else close(fd);
    pthread_mutex_unlock(&canopy_io_lock);
#else
    if (!file_of(h, NULL, NULL)) runtime_fail("close invalid file handle");
    pthread_mutex_lock(&lock); int fd = files[h - FILE_BASE].fd, save = files[h - FILE_BASE].save; files[h - FILE_BASE].fd = 0; pthread_mutex_unlock(&lock);
    close(fd);
    if (save) { save_touched(); atomic_fetch_sub(&save_writers, 1); }
#endif
}
#if TOTK_SAFE_SAVE_FLUSH
#define create_file canopy_create_file_body
#define delete_file canopy_delete_file_body
#define rename_file canopy_rename_file_body
#define create_directory canopy_create_directory_body
#define delete_recursive canopy_delete_recursive_body
#endif
static unsigned create_file(const char *path, int64_t size) {
#if TOTK_SAFE_SAVE_FLUSH
    char p[1100];int kind=M_FREE;unsigned r=host_path_kind(path,p,sizeof(p),&kind);
    if (r)return r;if (size<0)return R_INVALID_ARGUMENT;
    int slot=-1;
    if (kind==M_SAVE) {
        pthread_mutex_lock(&lock);for (int i=0;i<NFILES;i++)if(files[i].fd<=0){slot=i;break;}pthread_mutex_unlock(&lock);
        if (slot<0)return R_INVALID_ARGUMENT;
        save_touched();
    }
    int fd=open(p,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0)return errno_result();
    if (!fd) { int copy=fcntl(fd,F_DUPFD_CLOEXEC,3);int saved=errno;close(fd);fd=copy;errno=saved; }
    if (fd<0)return errno_result();
    int bad=ftruncate(fd,size),saved=errno;
    if (kind==M_SAVE) { pthread_mutex_lock(&lock);files[slot]=(File){fd,0,1};pthread_mutex_unlock(&lock); }
    else close(fd);
    errno=saved;return bad ? errno_result():0;
#else
    char p[1100]; unsigned r = save_change_path(path, p, sizeof p); if (r) return r; if (size < 0) return R_INVALID_ARGUMENT;
    int fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600); if (fd < 0) return errno_result();
    int bad = ftruncate(fd, size); close(fd); return bad ? errno_result() : 0;
#endif
}
static unsigned delete_file(const char *path) { char p[1100]; unsigned r = save_change_path(path, p, sizeof p); if (r) return r; return unlink(p) ? errno_result() : 0; }
static unsigned rename_file(const char *from, const char *to) {
#if TOTK_SAFE_SAVE_FLUSH
    char a[1100],b[1100];int from_kind=M_FREE,to_kind=M_FREE;
    unsigned r=host_path_kind(from,a,sizeof(a),&from_kind);
    if (!r)r=host_path_kind(to,b,sizeof(b),&to_kind);
    if (r)return r;
    /* Compare the exact root strings captured in the translated paths, not
     * just kinds: separate cache/save mounts can share a kind. Aliases of the
     * same root are allowed; different root spellings refuse conservatively.
     * A temp->save move cannot bypass save descriptor ownership/dirty state. */
    const char *from_rest=strchr(from,':')+1,*to_rest=strchr(to,':')+1;
    size_t from_length=strlen(from_rest),to_length=strlen(to_rest);
    while (from_length && from_rest[from_length-1]=='/')from_length--;
    while (to_length && to_rest[to_length-1]=='/')to_length--;
    size_t a_length=strlen(a),b_length=strlen(b);
    if (from_kind!=to_kind || from_length>a_length || to_length>b_length ||
        a_length-from_length!=b_length-to_length || memcmp(a,b,a_length-from_length))return R_INVALID_PATH;
    if (from_kind==M_SAVE)save_touched();
    struct stat st;if (!stat(b,&st))return R_ALREADY_EXISTS;
    return rename(a,b) ? errno_result():0;
#else
    char a[1100], b[1100]; unsigned r = save_change_path(from, a, sizeof a); if (!r) r = host_path(to, b, sizeof b); if (r) return r;
    struct stat st; if (!stat(b, &st)) return R_ALREADY_EXISTS;
    return rename(a, b) ? errno_result() : 0;
#endif
}
static unsigned entry_type(int *out, const char *path) {
    if (runtime_romfs_owns(path)) return runtime_romfs_entry_type(out, path); BOTW_AOC_TYPE(out, path)
    char p[1100]; unsigned r = host_path(path, p, sizeof p); if (r) return r; struct stat st;
    if (!out) return R_INVALID_ARGUMENT; if (stat(p, &st)) return R_PATH_NOT_FOUND;
    *out = S_ISDIR(st.st_mode) ? 0 : 1; return 0;
}

/* ---------- directories ---------- */
typedef struct { char name[769]; uint8_t pad0[3]; int8_t type; uint8_t pad1[3]; int64_t size; } DirectoryEntry;
_Static_assert(sizeof(DirectoryEntry) == 0x310, "nn::fs::DirectoryEntry");
static unsigned create_directory(const char *path) { char p[1100]; unsigned r = save_change_path(path, p, sizeof p); if (r) return r; return mkdir(p, 0700) ? errno_result() : 0; }
static unsigned delete_recursive(const char *path) { char p[1100]; unsigned r = save_change_path(path, p, sizeof p); if (r) return r; struct stat st; if (stat(p, &st)) return R_PATH_NOT_FOUND; return remove_tree(p) ? R_INVALID_ARGUMENT : 0; }
#if TOTK_SAFE_SAVE_FLUSH
#undef create_file
#undef delete_file
#undef rename_file
#undef create_directory
#undef delete_recursive
static unsigned create_file(const char *path,int64_t size) { pthread_mutex_lock(&canopy_io_lock);unsigned r=canopy_create_file_body(path,size);pthread_mutex_unlock(&canopy_io_lock);return r; }
static unsigned delete_file(const char *path) { pthread_mutex_lock(&canopy_io_lock);unsigned r=canopy_delete_file_body(path);pthread_mutex_unlock(&canopy_io_lock);return r; }
static unsigned rename_file(const char *from,const char *to) { pthread_mutex_lock(&canopy_io_lock);unsigned r=canopy_rename_file_body(from,to);pthread_mutex_unlock(&canopy_io_lock);return r; }
static unsigned create_directory(const char *path) { pthread_mutex_lock(&canopy_io_lock);unsigned r=canopy_create_directory_body(path);pthread_mutex_unlock(&canopy_io_lock);return r; }
static unsigned delete_recursive(const char *path) { pthread_mutex_lock(&canopy_io_lock);unsigned r=canopy_delete_recursive_body(path);pthread_mutex_unlock(&canopy_io_lock);return r; }
#endif
static unsigned open_directory(uint64_t *out, const char *path, int mode) {
    if (runtime_romfs_owns(path)) { fprintf(stderr, "[totk] OpenDirectory on RomFS %s\n", path); runtime_fail("RomFS directory listing not implemented"); }
    char p[1100]; unsigned r = host_path(path, p, sizeof p); if (r) return r; if (!out || mode < 1 || mode > 3) return R_INVALID_ARGUMENT;
    DIR *d = opendir(p); if (!d) return errno_result();
    pthread_mutex_lock(&lock);
    for (int i = 0; i < NDIRS; i++) if (!dirs[i].dir) { dirs[i].dir = d; dirs[i].mode = mode; strcpy(dirs[i].path, p); *out = DIR_BASE + (uint64_t)i; pthread_mutex_unlock(&lock); return 0; }
    pthread_mutex_unlock(&lock); runtime_fail("host directory handle table full");
}
static unsigned read_directory(int64_t *count, DirectoryEntry *out, uint64_t h, int64_t max) {
    if (h < DIR_BASE || h >= DIR_BASE + NDIRS || !count || max < 0 || (!out && max)) return R_INVALID_ARGUMENT;
    Dir *d = &dirs[h - DIR_BASE]; if (!d->dir) return R_INVALID_ARGUMENT;
    int64_t n = 0; struct dirent *e;
    while (n < max && (e = readdir(d->dir))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..") || strlen(e->d_name) > 768) continue;
        char child[2048]; snprintf(child, sizeof child, "%s/%s", d->path, e->d_name); struct stat st; if (stat(child, &st)) continue;
        int is_dir = S_ISDIR(st.st_mode); if (!(d->mode & (is_dir ? 1 : 2))) continue;
        memset(&out[n], 0, sizeof *out); strcpy(out[n].name, e->d_name); out[n].type = is_dir ? 0 : 1; out[n].size = is_dir ? 0 : st.st_size; n++;
    }
    *count = n; return 0;
}
static void close_directory(uint64_t h) {
    if (h < DIR_BASE || h >= DIR_BASE + NDIRS || !dirs[h - DIR_BASE].dir) runtime_fail("close invalid directory handle");
    pthread_mutex_lock(&lock); closedir(dirs[h - DIR_BASE].dir); dirs[h - DIR_BASE].dir = NULL; pthread_mutex_unlock(&lock);
}
/* The fs priority only orders I/O inside the system fs process; host I/O is unordered. */
static void set_priority(int priority) { (void)priority; }

/* make probe-save: the "save in progress" state the window close waits on, through the fs entry points the game uses
   (a fresh profile in build/probe-save-profile; no game). */
void runtime_save_probe(void) {
    const char *dir = "build/probe-save-profile";   /* a fresh profile each run (a failed run leaves it for a look) */
    remove_tree(dir); setenv("TOTK_PROFILE_DIR", dir, 1);
    unsigned checks = 0; uint64_t uid[2]; runtime_account_uid(uid); uint64_t h = 0;
#define CHECK(c, what) do { checks++; if (!(c)) { fprintf(stderr, "save probe: %s\n", what); runtime_fail("save probe failed"); } } while (0)
    CHECK(mount_save("save", uid) == 0 && mount_temp("temp") == 0, "mount save and temporary storage");
    CHECK(!runtime_fs_save_busy(), "idle at start");
    CHECK(create_file("save:/a.sav", 16) == 0 && runtime_fs_save_busy(), "creating a save file starts a save");
    CHECK(commit("save") == 0 && !runtime_fs_save_busy(), "commit ends it");
    CHECK(open_file(&h, "save:/a.sav", OPEN_WRITE) == 0 && runtime_fs_save_busy(), "a save file open for writing");
    static const char data[16] = "progress";
    CHECK(write_file(h, 0, data, sizeof data, NULL) == 0 && runtime_fs_save_busy(), "writing");
    atomic_store(&save_changed_ns, runtime_now_ns() - 10000000000ull);
    CHECK(runtime_fs_save_busy(), "a file open for writing is busy however long ago it was written");
    close_file(h);
    CHECK(runtime_fs_save_busy(), "closed but not committed yet (the next file of the save follows)");
    CHECK(commit("save") == 0 && !runtime_fs_save_busy(), "committed");
    CHECK(open_file(&h, "save:/a.sav", OPEN_READ) == 0 && !runtime_fs_save_busy(), "reading is not saving");
    close_file(h);
    CHECK(create_file("save:/b.sav", 4) == 0 && runtime_fs_save_busy(), "second change");
    atomic_store(&save_changed_ns, runtime_now_ns() - 4000000000ull);
#if TOTK_SAFE_SAVE_FLUSH
    CHECK(runtime_fs_save_busy(), "iOS/Canopy uncommitted changes do not age into clean state");
    CHECK(commit("save")==0 && !runtime_fs_save_busy(), "explicit safe flush clears dirty state");
#else
    CHECK(!runtime_fs_save_busy(), "uncommitted changes older than 3 s are not a save in progress");
#endif
    CHECK(create_file("temp:/t.bin", 4) == 0 && !runtime_fs_save_busy(), "temporary storage does not count");
    CHECK(rename_file("save:/b.sav", "save:/c.sav") == 0 && runtime_fs_save_busy(), "renaming save data");
    CHECK(commit("save") == 0 && !runtime_fs_save_busy() && delete_file("save:/c.sav") == 0 && runtime_fs_save_busy() && commit("save") == 0, "delete and commit");
#undef CHECK
    remove_tree(dir);
#if TOTK_SAFE_SAVE_FLUSH
    printf("{\"status\":\"pass\",\"probe\":\"probe-save\",\"checks\":%u,\"scope\":\"iOS/Canopy owned save-descriptor flushing and dirty state; no multi-file transaction or CPU teardown ACK\"}\n",checks);
#else
    printf("{\"status\":\"pass\",\"probe\":\"probe-save\",\"checks\":%u,\"scope\":\"save-in-progress state (runtime_fs_save_busy) through open / write / close / create / rename / delete / commit on a save mount; reads and temporary storage do not count; stale uncommitted changes do not hold a close\"}\n", checks);
#endif
}

void *runtime_fs_host_override(const char *name) {
    static const struct { const char *name; void *fn; } map[] = {
        {"_ZN2nn2fs8OpenFileEPNS0_10FileHandleEPKci", open_file}, {"_ZN2nn2fs11GetFileSizeEPlNS0_10FileHandleE", file_size}, BOTW_AOC_TABLE
        {"_ZN2nn2fs9CloseFileENS0_10FileHandleE", close_file}, {"_ZN2nn2fs12GetEntryTypeEPNS0_18DirectoryEntryTypeEPKc", entry_type},
        {"_ZN2nn2fs8ReadFileEPmNS0_10FileHandleElPvm", read_file}, {"_ZN2nn2fs8ReadFileEPmNS0_10FileHandleElPvmRKNS0_10ReadOptionE", read_options},
        {"_ZN2nn2fs8ReadFileENS0_10FileHandleElPvm", read_exact},
        {"_ZN2nn2fs9WriteFileENS0_10FileHandleElPKvmRKNS0_11WriteOptionE", write_file},
        {"_ZN2nn2fs11SetFileSizeENS0_10FileHandleEl", set_file_size}, {"_ZN2nn2fs9FlushFileENS0_10FileHandleE", flush_file},
        {"_ZN2nn2fs10CreateFileEPKcl", create_file}, {"_ZN2nn2fs10DeleteFileEPKc", delete_file}, {"_ZN2nn2fs10RenameFileEPKcS2_", rename_file},
        {"_ZN2nn2fs15CreateDirectoryEPKc", create_directory}, {"_ZN2nn2fs26DeleteDirectoryRecursivelyEPKc", delete_recursive},
        {"_ZN2nn2fs13OpenDirectoryEPNS0_15DirectoryHandleEPKci", open_directory},
        {"_ZN2nn2fs13ReadDirectoryEPlPNS0_14DirectoryEntryENS0_15DirectoryHandleEl", read_directory},
        {"_ZN2nn2fs14CloseDirectoryENS0_15DirectoryHandleE", close_directory},
        {"_ZN2nn2fs13MountSaveDataEPKcRKNS_7account3UidE", mount_save},
        {"_ZN2nn2fs21MountSaveDataReadOnlyEPKcNS_13ApplicationIdERKNS_7account3UidE", mount_save_ro},
        {"_ZN2nn2fs18IsSaveDataExistingENS_13ApplicationIdERKNS_7account3UidE", save_exists},
        {"_ZN2nn2fs21MountTemporaryStorageEPKc", mount_temp}, {"_ZN2nn2fs7UnmountEPKc", unmount}, {"_ZN2nn2fs6CommitEPKc", commit},
#ifdef GAME_BOTW
        {"_ZN2nn2fs14CommitSaveDataEPKc", commit},   /* SDK 7 (Breath of the Wild 1.6.0) */
#endif
       
        {"_ZN2nn2fs18CreateCacheStorageEill", create_cache}, {"_ZN2nn2fs18DeleteCacheStorageEi", delete_cache},
        {"_ZN2nn2fs17MountCacheStorageEPKci", mount_cache},
        {"_ZN2nn2fs20OpenCacheStorageListEPNS0_22CacheStorageListHandleE", open_cache_list},
        {"_ZN2nn2fs20ReadCacheStorageListEPiPNS0_16CacheStorageInfoENS0_22CacheStorageListHandleEi", read_cache_list},
        {"_ZN2nn2fs21CloseCacheStorageListENS0_22CacheStorageListHandleE", close_cache_list},
        {"_ZN2nn2fs26SetPriorityOnCurrentThreadENS0_8PriorityE", set_priority},
    };
    for (size_t i = 0; i < sizeof map / sizeof *map; i++) if (!strcmp(name, map[i].name)) return map[i].fn;
    return NULL;
}
