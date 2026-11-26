/* A counter actor. It keeps a running total in its own memory: `add(n)`
 * adds n to it and posts `added(total)` to wherever the host wired this
 * actor's output. The host calls `handle` once per message, one message at
 * a time, so the total needs no lock. */
#include "counter_actor.h"

static uint32_t total;

void exports_counter_actor_handle(counter_actor_message_t *msg) {
    if (msg->tag != DEMO_ACTORS_PROTOCOL_MESSAGE_ADD)
        return;
    total += msg->val.add;
    counter_actor_message_t out = {
        .tag = DEMO_ACTORS_PROTOCOL_MESSAGE_ADDED,
        .val.added = total,
    };
    counter_actor_send_error_t err;
    /* A refused post (the destination is full or closed) is dropped: the
     * total is still right, and the next post carries it. */
    (void) counter_actor_post(&out, &err);
}
