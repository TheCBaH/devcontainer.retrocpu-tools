/* Minimal FST reader (GTKWave libfst, as bundled with Verilator).
 *   fstdump <file.fst> vars               one "path width" line per variable
 *   fstdump <file.fst> final <path>...    last value (hex) of each path
 *   fstdump <file.fst> changes <path>     "time value" per change
 * Paths are dotted, e.g. i8080_tb.dut.acc. Values are printed in hex when the
 * variable has no x/z bits, otherwise as the raw bit string. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fstapi.h"

#define MAXV 4096
static char *names[MAXV];
static int widths[MAXV];
static fstHandle handles[MAXV];
static int nv;
static const char *want[64];
static int nwant;
static char last[64][160];
static int mode_changes;

static void fmt(char *out, size_t cap, const unsigned char *v, int w)
{
    int bad = 0;
    for (int i = 0; i < w; i++)
        if (v[i] != '0' && v[i] != '1') bad = 1;
    if (bad) { snprintf(out, cap, "%.*s", w, v); return; }
    char *p = out;
    int digits = (w + 3) / 4;
    for (int d = digits - 1; d >= 0 && (size_t)(p - out) < cap - 2; d--) {
        int x = 0;
        for (int b = 3; b >= 0; b--) {
            int bit = d * 4 + b;
            x = x * 2 + (bit < w && v[w - 1 - bit] == '1');
        }
        *p++ = "0123456789abcdef"[x];
    }
    *p = 0;
}

static void cb(void *user, uint64_t time, fstHandle h, const unsigned char *value)
{
    (void)user;
    for (int i = 0; i < nv; i++) {
        if (handles[i] != h) continue;
        for (int k = 0; k < nwant; k++) {
            if (strcmp(names[i], want[k])) continue;
            char buf[160];
            fmt(buf, sizeof buf, value, widths[i]);
            if (mode_changes) printf("%llu %s\n", (unsigned long long)time, buf);
            else strcpy(last[k], buf);
        }
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: fstdump file.fst vars|final|changes [path...]\n"); return 2; }
    void *ctx = fstReaderOpen(argv[1]);
    if (!ctx) { fprintf(stderr, "fstdump: cannot read %s\n", argv[1]); return 1; }
    char scope[1024] = "";
    int depth = 0, lens[64];
    struct fstHier *h;
    while ((h = fstReaderIterateHier(ctx))) {
        if (h->htyp == FST_HT_SCOPE) {
            lens[depth++] = (int)strlen(scope);
            if (scope[0]) strcat(scope, ".");
            strncat(scope, h->u.scope.name, sizeof scope - strlen(scope) - 1);
        } else if (h->htyp == FST_HT_UPSCOPE) {
            scope[lens[--depth]] = 0;
        } else if (h->htyp == FST_HT_VAR && nv < MAXV) {
            size_t n = strlen(scope) + strlen(h->u.var.name) + 2;
            names[nv] = malloc(n);
            snprintf(names[nv], n, "%s%s%s", scope, scope[0] ? "." : "", h->u.var.name);
            char *sp = strchr(names[nv], ' ');       /* Verilator appends " [msb:lsb]" */
            if (sp) *sp = 0;
            widths[nv] = (int)h->u.var.length;
            handles[nv] = h->u.var.handle;
            nv++;
        }
    }
    if (!strcmp(argv[2], "vars")) {
        for (int i = 0; i < nv; i++) printf("%s %d\n", names[i], widths[i]);
    } else {
        mode_changes = !strcmp(argv[2], "changes");
        for (int i = 3; i < argc && nwant < 64; i++) {
            want[nwant] = argv[i];
            for (int j = 0; j < nv; j++)
                if (!strcmp(names[j], argv[i])) fstReaderSetFacProcessMask(ctx, handles[j]);
            last[nwant][0] = 0;
            nwant++;
        }
        fstReaderIterBlocks(ctx, cb, NULL, NULL);
        if (!mode_changes)
            for (int k = 0; k < nwant; k++) printf("%s %s\n", want[k], last[k][0] ? last[k] : "none");
    }
    fstReaderClose(ctx);
    return 0;
}
