#include "cshim.h"

void wb_line_buffer_stdout(void) { setvbuf(stdout, NULL, _IOLBF, 0); }
