#include <stdio.h>

// Swift 6 rejects reading the C global `stdout` on glibc, so the one call that needs it lives here.
void wb_line_buffer_stdout(void);
