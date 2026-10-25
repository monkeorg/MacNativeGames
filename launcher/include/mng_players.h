#ifndef MNG_PLAYERS_H
#define MNG_PLAYERS_H
#include <stdint.h>

#define MNG_PLAYER_COUNT 4u
#define MNG_DEVICE_COUNT 8u
/* Button bits: A,B,X,Y,L,R,ZL,ZR,plus,minus,left-stick,right-stick,
 * up,down,left,right,home,capture, respectively. */
#define MNG_BUTTON_MASK UINT64_C(0x3ffff)
#define MNG_GUEST_BUTTON_MASK UINT64_C(0xffff)
struct mng_input { uint64_t buttons; float sticks[4]; float triggers[2]; };
enum mng_player_status {
    MNG_PLAYER_OK, MNG_PLAYER_INVALID, MNG_PLAYER_NOT_FOUND,
    MNG_PLAYER_CONFLICT, MNG_PLAYER_LIMIT, MNG_PLAYER_STALE, MNG_PLAYER_INACTIVE
};
struct mng_device {
    uint64_t id, token, sequence;
    uint64_t pressed_edges;
    struct mng_input input;
};
/* Fixed storage; initialize once, then mutate only through this API. All calls
 * must be serialized by the host (including reads). IDs are caller-owned,
 * stable and nonzero. No automatic assignment or input merging occurs.
 * Tokens remain monotonic for this router's lifetime: do not reinitialize it
 * while callbacks from its previous lifetime can still arrive. */
struct mng_players {
    struct mng_device devices[MNG_DEVICE_COUNT];
    uint64_t seats[MNG_PLAYER_COUNT], next_token;
    int focused;
};
void mng_players_init(struct mng_players *players);
enum mng_player_status mng_players_connect(struct mng_players *, uint64_t id);
enum mng_player_status mng_players_disconnect(struct mng_players *, uint64_t id);
/* Clear held/latched input and invalidate callbacks, retaining assignment. */
enum mng_player_status mng_players_reset_device(struct mng_players *, uint64_t id);
/* Assign requires a vacant seat and an unassigned device; assigning the same
 * device to its existing seat is a no-op. Other conflicts require explicit
 * unassign or swap. Player indices are zero-based. */
enum mng_player_status mng_players_assign(struct mng_players *, unsigned player, uint64_t id);
enum mng_player_status mng_players_unassign(struct mng_players *, unsigned player);
enum mng_player_status mng_players_swap(struct mng_players *, unsigned first, unsigned second);
/* Focus transitions clear all held state and invalidate all tokens; assignments
 * persist. While unfocused updates are refused. */
enum mng_player_status mng_players_focus(struct mng_players *, int focused);
/* The adapter obtains a token after every routing/focus event and samples anew.
 * Do not relabel queued old events with a new token. Sequence is nonzero and
 * strictly increasing within that token. Invalid/stale updates change nothing.
 * Finite sticks clamp to [-1,1], triggers to [0,1]; NaN/infinity are refused. */
enum mng_player_status mng_players_token(const struct mng_players *, uint64_t id, uint64_t *token);
enum mng_player_status mng_players_update(struct mng_players *, uint64_t id,
    uint64_t token, uint64_t sequence, const struct mng_input *input);
/* Returns neutral input and id=0 for an empty seat. A connected assigned device
 * still reports its id while unfocused, with neutral input. */
enum mng_player_status mng_players_read(const struct mng_players *, unsigned player,
    uint64_t *id, struct mng_input *input);
/* Gameplay read: also delivers guest-button rising edges once, preserving taps
 * that completed between polls. Home/Capture remain separate host commands.
 * Focus/assignment/disconnect/reset clears pending edges; peek read is unchanged. */
enum mng_player_status mng_players_consume(struct mng_players *, unsigned player,
    uint64_t *id, struct mng_input *input);
#endif
