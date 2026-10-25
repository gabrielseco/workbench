#include <stdio.h>

// Swift 6 rejects reading the C global `stdout` on glibc, so the one call that needs it lives here.
void wb_line_buffer_stdout(void);

// `prctl` is variadic, which Swift cannot call. 0 when this process now adopts the orphans beneath it, -1 otherwise
// (always -1 off Linux).
int wb_become_subreaper(void);
