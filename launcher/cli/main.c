#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include "mng_file.h"
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Constant error codes deliberately omit private paths and platform errors. */
static int error(const char *code, int exit_code) {
    fprintf(stderr,"{\"error\":\"%s\",\"execution_verified\":false}\n",code);
    return exit_code;
}
static void json_string(const char *text) {
    putchar('"');
    for (const unsigned char *p=(const unsigned char *)text;*p;p++) {
        if (*p=='"' || *p=='\\') { putchar('\\'); putchar(*p); }
        else if (*p<0x20) printf("\\u%04x",(unsigned)*p);
        else putchar(*p); /* parser has already validated UTF-8 */
    }
    putchar('"');
}
int main(int argc, char **argv) {
    if (argc!=3 || strcmp(argv[1],"inspect")) return error("usage",2);
    int fd=open(argv[2],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) return error("open_failed",3);
    struct stat before, after;
    if (fstat(fd,&before)) { close(fd); return error("read_failed",4); }
    struct mng_inventory result={0};
    enum mng_status status=mng_inspect_fd(fd,&result);
    /* Bind source_size in the report to the inspected descriptor, including a
     * final check rather than reopening the pathname for a separate stat. */
    int size_valid=!fstat(fd,&after) && before.st_size==after.st_size;
    close(fd);
    if (status!=MNG_OK || !size_valid) {
        mng_inventory_free(&result);
        switch (status) {
            case MNG_INVALID: return error("invalid_container",4);
            case MNG_LIMIT: return error("resource_limit",4);
            case MNG_NOMEM: return error("out_of_memory",5);
            default: return error("read_failed",4);
        }
    }
    printf("{\"format\":\"%s\",\"count\":%zu,\"source_size\":%" PRIu64
           ",\"execution_verified\":false,\"entries\":[",
           result.kind==MNG_NSP ? "nsp":"xci",result.count,(uint64_t)before.st_size);
    for (size_t i=0;i<result.count;i++) {
        if (i) putchar(',');
        fputs("{\"name\":",stdout); json_string(result.entries[i].name);
        printf(",\"offset\":%" PRIu64 ",\"size\":%" PRIu64 "}",
               result.entries[i].offset,result.entries[i].size);
    }
    puts("]}");
    mng_inventory_free(&result);
    return ferror(stdout) ? 5:0;
}
