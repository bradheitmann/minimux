#include <stdint.h>
#include <string.h>

#include "minimux.h"

int main(void) {
    _Static_assert(MINIMUX_METHOD_COUNT == 15, "v0.1.0 method count changed");
    _Static_assert(MINIMUX_ERROR_CODE_COUNT == 14, "v0.1.0 error count changed");
    _Static_assert(MINIMUX_ERROR_METHOD_NOT_FOUND == -32601, "JSON-RPC method error changed");
    _Static_assert(MINIMUX_ERROR_SESSION_NOT_FOUND == 1001, "session error changed");
    _Static_assert(MINIMUX_ERROR_VALIDATION_NON_MONOTONIC_SEQUENCE == 2003, "validation error changed");

    const char *argv[] = { "bash" };
    struct minimux_pane_create_options pane_options = {
        .argv = argv,
        .argv_len = 1,
        .env = 0,
        .env_len = 0,
        .cwd = "/tmp",
        .size = {
            .cols = 80,
            .rows = 24,
        },
    };
    struct minimux_session_options session_options = { .flags = 0 };
    struct minimux_record_policy record_policy = { .flags = 0 };
    struct minimux_tap_filter tap_filter = { .flags = 0 };

    if (strcmp(MINIMUX_PROTOCOL_VERSION, "0.1.0") != 0) return 1;
    if (pane_options.size.cols != 80) return 2;
    if (session_options.flags != 0) return 3;
    if (record_policy.flags != 0) return 4;
    if (tap_filter.flags != 0) return 5;
    return 0;
}
