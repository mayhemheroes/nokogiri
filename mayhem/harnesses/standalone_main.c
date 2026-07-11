/*
 * standalone_main.c — a minimal run-once driver for the libFuzzer entrypoint, so the
 * parse_fuzzer harness can be rebuilt as a self-contained reproducer (no libFuzzer runtime).
 * Reads each path given on argv, feeds its bytes to LLVMFuzzerTestOneInput exactly once.
 * Mirrors $STANDALONE_FUZZ_MAIN from the org base, kept here so the build is self-contained.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

extern int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    FILE *f = fopen(argv[i], "rb");
    if (!f) { perror(argv[i]); continue; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    if (n < 0) { fclose(f); continue; }
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = (uint8_t *)malloc((size_t)n ? (size_t)n : 1);
    if (!buf) { fclose(f); return 1; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    LLVMFuzzerTestOneInput(buf, got);
    free(buf);
  }
  return 0;
}
