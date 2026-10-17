#ifndef OSMMINI_H
#define OSMMINI_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1. Returned strings are UTF-8 JSON owned by the caller; free exactly once.
 * Jobs are asynchronous. Cancel then poll to a terminal state before Release.
 * TakeEngine transfers an opened engine out of a completed job; Close it once
 * all uses end. Search/route/tile never expose graph pointers to Swift. */
int32_t OSMminiABIVersion(void);
char *OSMminiStart(char *request_json);
char *OSMminiPoll(uint64_t operation);
/* Same response as Poll. A running job waits for its next progress change or
 * completion. timeout_ms <= 0 polls immediately; positive waits are capped at
 * 60000 ms. Call on a worker thread. Cancellation is drained to a terminal
 * state before Release, as with Poll. */
char *OSMminiWait(uint64_t operation, int32_t timeout_ms);
uint64_t OSMminiTakeEngine(uint64_t operation);
void OSMminiCancel(uint64_t operation);
void OSMminiRelease(uint64_t operation);
void OSMminiClose(uint64_t engine);
void OSMminiFree(char *buffer);
#ifdef __cplusplus
}
#endif
#endif
