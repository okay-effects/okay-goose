#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
typedef struct { uint8_t *data; int64_t len; } okay_sl_u8;
/* a shell command run: its exit status (-1 if it could not run) */
int32_t okay_system(okay_sl_u8 cmd) {
    char *c = malloc((size_t)cmd.len + 1);
    if (!c) return -1;
    memcpy(c, cmd.data, (size_t)cmd.len);
    c[cmd.len] = 0;
    int st = system(c);
    free(c);
    if (st == -1) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
