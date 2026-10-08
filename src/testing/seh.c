/* Windows verification fixture; never linked into the reactor module. */
#include <windows.h>
int reactor_seh(void *context, void (*callback)(void *), unsigned *marker) {
    volatile unsigned char frame[96 * 1024];
    for (unsigned i = 0; i < sizeof frame; i += 4096) frame[i] = 17;
    __try {
        __try {
            callback(context);
            RaiseException(0xe0456a01, 0, 0, 0);
        } __finally {
            *marker |= 1;
        }
    } __except(GetExceptionCode() == 0xe0456a01 ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        *marker |= 2;
        return frame[0] == 17;
    }
    return 0;
}
