#include "cshim.h"

#ifdef __linux__
#include <sys/prctl.h>
#endif

void wb_line_buffer_stdout(void) { setvbuf(stdout, NULL, _IOLBF, 0); }

int wb_become_subreaper(void) {
#ifdef PR_SET_CHILD_SUBREAPER
    return prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
#else
    return -1;
#endif
}
