/* Host test for priv/include/mob_midi_parser.h; run by
 * test/mob_midi_c_parser_test.exs. Exits non-zero on any failure. */
#include <stdio.h>
#include <string.h>

#include "mob_midi_parser.h"

static int failures = 0;

#define CHECK(cond)                                                      \
    do {                                                                 \
        if (!(cond)) {                                                   \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                  \
        }                                                                \
    } while (0)

typedef struct {
    mob_midi_msg msgs[32];
    size_t n;
} sink;

static void collect(void *ctx, mob_midi_msg m) {
    sink *s = (sink *)ctx;
    if (s->n < sizeof s->msgs / sizeof s->msgs[0]) s->msgs[s->n] = m;
    s->n++;
}

static void feed(mob_midi_parser *p, sink *s, const uint8_t *bytes, size_t len) {
    mob_midi_parse(p, bytes, len, collect, s);
}

static int is(const sink *s, size_t i, uint8_t status, uint8_t d1, uint8_t d2, uint8_t len) {
    const mob_midi_msg *m;
    if (i >= s->n) return 0;
    m = &s->msgs[i];
    return m->status == status && m->d1 == d1 && m->d2 == d2 && m->len == len;
}

#define FEED(p, s, ...)                                  \
    do {                                                 \
        static const uint8_t in_[] = {__VA_ARGS__};      \
        feed((p), (s), in_, sizeof in_);                 \
    } while (0)

static void test_running_status(void) {
    mob_midi_parser p = {0};
    sink s = {0};
    /* Velocity 0 stays a raw note on. */
    FEED(&p, &s, 0x90, 60, 100, 62, 90, 60, 0);
    CHECK(s.n == 3);
    CHECK(is(&s, 0, 0x90, 60, 100, 3));
    CHECK(is(&s, 1, 0x90, 62, 90, 3));
    CHECK(is(&s, 2, 0x90, 60, 0, 3));

    memset(&s, 0, sizeof s);
    FEED(&p, &s, 0xC1, 5, 6, 0xE0, 0x00, 0x40, 0x7F, 0x7F);
    CHECK(s.n == 4);
    CHECK(is(&s, 0, 0xC1, 5, 0, 2));
    CHECK(is(&s, 1, 0xC1, 6, 0, 2));
    CHECK(is(&s, 2, 0xE0, 0x00, 0x40, 3));
    CHECK(is(&s, 3, 0xE0, 0x7F, 0x7F, 3));
}

static void test_realtime_interleave(void) {
    mob_midi_parser p = {0};
    sink s = {0};
    FEED(&p, &s, 0x90, 0xF8, 60, 0xFA, 100, 0xFE, 62, 90);
    CHECK(s.n == 5);
    CHECK(is(&s, 0, 0xF8, 0, 0, 1));
    CHECK(is(&s, 1, 0xFA, 0, 0, 1));
    CHECK(is(&s, 2, 0x90, 60, 100, 3));
    CHECK(is(&s, 3, 0xFE, 0, 0, 1));
    CHECK(is(&s, 4, 0x90, 62, 90, 3));

    /* Undefined real-time statuses are dropped without disturbing anything. */
    memset(&s, 0, sizeof s);
    FEED(&p, &s, 0xF9, 64, 0xFD, 1);
    CHECK(s.n == 1);
    CHECK(is(&s, 0, 0x90, 64, 1, 3));
}

static void test_system_common(void) {
    mob_midi_parser p = {0};
    sink s = {0};
    /* F3 cancels running status: the trailing 62 90 are dropped. */
    FEED(&p, &s, 0x90, 60, 100, 0xF3, 4, 62, 90, 0xF1, 0x23, 0xF2, 1, 2, 0xF6, 0xF4, 0xF5, 0xF7);
    CHECK(s.n == 5);
    CHECK(is(&s, 0, 0x90, 60, 100, 3));
    CHECK(is(&s, 1, 0xF3, 4, 0, 2));
    CHECK(is(&s, 2, 0xF1, 0x23, 0, 2));
    CHECK(is(&s, 3, 0xF2, 1, 2, 3));
    CHECK(is(&s, 4, 0xF6, 0, 0, 1));
}

static void test_sysex_skip(void) {
    mob_midi_parser p = {0};
    sink s = {0};
    /* Real-time inside SysEx still comes out; the SysEx itself doesn't. */
    FEED(&p, &s, 0xF0, 0x7D, 0xF8, 1, 2, 0xF7, 0x90, 60, 100);
    CHECK(s.n == 2);
    CHECK(is(&s, 0, 0xF8, 0, 0, 1));
    CHECK(is(&s, 1, 0x90, 60, 100, 3));

    /* A status byte ends an unterminated SysEx and counts as itself. */
    memset(&s, 0, sizeof s);
    FEED(&p, &s, 0xF0, 0x7D, 1, 0xB0, 7, 90);
    CHECK(s.n == 1);
    CHECK(is(&s, 0, 0xB0, 7, 90, 3));

    /* SysEx split across packets. */
    memset(&s, 0, sizeof s);
    FEED(&p, &s, 0xF0, 1, 2);
    FEED(&p, &s, 3, 0xF7, 0xC0, 9);
    CHECK(s.n == 1);
    CHECK(is(&s, 0, 0xC0, 9, 0, 2));
}

static void test_split_and_stray(void) {
    mob_midi_parser p = {0};
    sink s = {0};
    /* Stray data with no status is dropped. */
    FEED(&p, &s, 60, 100);
    CHECK(s.n == 0);

    FEED(&p, &s, 0x90, 60);
    CHECK(s.n == 0);
    FEED(&p, &s, 100, 62);
    CHECK(s.n == 1);
    FEED(&p, &s, 90);
    CHECK(s.n == 2);
    CHECK(is(&s, 0, 0x90, 60, 100, 3));
    CHECK(is(&s, 1, 0x90, 62, 90, 3));

    /* A new status abandons the partial message. */
    memset(&s, 0, sizeof s);
    FEED(&p, &s, 0x80, 60, 0xB0, 7, 90);
    CHECK(s.n == 1);
    CHECK(is(&s, 0, 0xB0, 7, 90, 3));

    /* Zeroing resets: running status and the partial message are gone. */
    memset(&s, 0, sizeof s);
    FEED(&p, &s, 0x90, 60);
    memset(&p, 0, sizeof p);
    FEED(&p, &s, 100, 61, 1);
    CHECK(s.n == 0);
}

int main(void) {
    test_running_status();
    test_realtime_interleave();
    test_system_common();
    test_sysex_skip();
    test_split_and_stray();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
