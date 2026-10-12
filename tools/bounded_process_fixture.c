#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Test executable only. It never runs against device paths or real services.
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "success")) { puts("bounded-output"); return 0; }
    if (!strcmp(argv[1], "failure")) { puts("private-helper-output"); return 19; }
    if (!strcmp(argv[1], "signal")) { raise(SIGTERM); return 3; }
    if (!strcmp(argv[1], "flood")) {
        char bytes[4096]; memset(bytes, 'x', sizeof(bytes));
        for (;;) if (write(STDOUT_FILENO, bytes, sizeof(bytes)) < 0) return 3;
    }
    if (!strcmp(argv[1], "descendant") || !strcmp(argv[1], "orphan")) {
        if (argc != 3) return 2;
        signal(SIGTERM, SIG_IGN);
        pid_t child = fork();
        if (child < 0) return 3;
        if (!child) {
            sleep(2);
            int fd = open(argv[2], O_CREAT | O_EXCL | O_WRONLY, 0600);
            if (fd >= 0) { write(fd, "escaped", 7); close(fd); }
            for (;;) pause();
        }
        printf("leader=%d child=%d\n", getpid(), child); fflush(stdout);
        if (!strcmp(argv[1], "orphan")) return 0;
        for (;;) pause();
    }
    return 2;
}
