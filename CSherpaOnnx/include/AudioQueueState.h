#ifndef HOLDTOTALK_AUDIO_QUEUE_STATE_H
#define HOLDTOTALK_AUDIO_QUEUE_STATE_H
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

// SPSC publication cursors for the preallocated Swift PCM pool. Supported on macOS 14.
// Producer publishes after copying PCM; consumer releases a slot only after processing it.
typedef struct {
    _Atomic(uint64_t) read;
    _Atomic(uint64_t) write;
    _Atomic(bool) failed;
    _Atomic(bool) closed;
} HTTAudioQueueState;
static inline void *HTTAudioQueueCreate(void) {
    HTTAudioQueueState *state = calloc(1, sizeof(HTTAudioQueueState));
    if (state) {
        atomic_init(&state->read, 0);
        atomic_init(&state->write, 0);
        atomic_init(&state->failed, false);
        atomic_init(&state->closed, false);
    }
    return state;
}
static inline void HTTAudioQueueDestroy(void *state) { free(state); }
static inline uint64_t HTTAudioQueueRead(void *state) {
    return atomic_load_explicit(&((HTTAudioQueueState *)state)->read, memory_order_acquire);
}
static inline uint64_t HTTAudioQueueWrite(void *state) {
    return atomic_load_explicit(&((HTTAudioQueueState *)state)->write, memory_order_acquire);
}
static inline void HTTAudioQueuePublish(void *state, uint64_t value) {
    atomic_store_explicit(&((HTTAudioQueueState *)state)->write, value, memory_order_release);
}
static inline void HTTAudioQueueRelease(void *state, uint64_t value) {
    atomic_store_explicit(&((HTTAudioQueueState *)state)->read, value, memory_order_release);
}
static inline bool HTTAudioQueueFail(void *state) {
    return !atomic_exchange_explicit(&((HTTAudioQueueState *)state)->failed, true, memory_order_relaxed);
}
static inline bool HTTAudioQueueFailed(void *state) {
    return atomic_load_explicit(&((HTTAudioQueueState *)state)->failed, memory_order_relaxed);
}
static inline bool HTTAudioQueueClosed(void *state) {
    return atomic_load_explicit(&((HTTAudioQueueState *)state)->closed, memory_order_relaxed);
}
static inline void HTTAudioQueueClose(void *state) {
    atomic_store_explicit(&((HTTAudioQueueState *)state)->closed, true, memory_order_relaxed);
}
#endif
