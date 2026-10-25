#include "mng_players.h"
#include <math.h>
#include <stddef.h>
#include <string.h>

static struct mng_device *device(struct mng_players *p, uint64_t id) {
    if (id) for (unsigned i=0;i<MNG_DEVICE_COUNT;i++) if (p->devices[i].id==id) return &p->devices[i];
    return NULL;
}
static const struct mng_device *lookup(const struct mng_players *p, uint64_t id) {
    if (id) for (unsigned i=0;i<MNG_DEVICE_COUNT;i++) if (p->devices[i].id==id) return &p->devices[i];
    return NULL;
}
static int capacity(const struct mng_players *p, unsigned count) {
    return count<=UINT64_MAX-p->next_token;
}
static void clear(struct mng_players *p, struct mng_device *d) {
    memset(&d->input,0,sizeof(d->input)); d->pressed_edges=0; d->sequence=0; d->token=++p->next_token;
}
void mng_players_init(struct mng_players *p) {
    if (p) { memset(p,0,sizeof(*p)); p->focused=1; }
}
enum mng_player_status mng_players_connect(struct mng_players *p, uint64_t id) {
    if (!p || !id) return MNG_PLAYER_INVALID;
    if (device(p,id)) return MNG_PLAYER_CONFLICT;
    for (unsigned i=0;i<MNG_DEVICE_COUNT;i++) if (!p->devices[i].id) {
        if (!capacity(p,1)) return MNG_PLAYER_LIMIT;
        p->devices[i].id=id; clear(p,&p->devices[i]); return MNG_PLAYER_OK;
    }
    return MNG_PLAYER_LIMIT;
}
enum mng_player_status mng_players_disconnect(struct mng_players *p, uint64_t id) {
    if (!p || !id) return MNG_PLAYER_INVALID;
    struct mng_device *d=device(p,id);
    if (!d) return MNG_PLAYER_NOT_FOUND;
    for (unsigned i=0;i<MNG_PLAYER_COUNT;i++) if (p->seats[i]==id) p->seats[i]=0;
    memset(d,0,sizeof(*d)); return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_reset_device(struct mng_players *p, uint64_t id) {
    if (!p || !id) return MNG_PLAYER_INVALID;
    struct mng_device *d=device(p,id);
    if (!d) return MNG_PLAYER_NOT_FOUND;
    if (!capacity(p,1)) return MNG_PLAYER_LIMIT;
    clear(p,d); return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_assign(struct mng_players *p, unsigned player, uint64_t id) {
    if (!p || player>=MNG_PLAYER_COUNT || !id) return MNG_PLAYER_INVALID;
    struct mng_device *d=device(p,id);
    if (!d) return MNG_PLAYER_NOT_FOUND;
    if (p->seats[player]==id) return MNG_PLAYER_OK;
    if (p->seats[player]) return MNG_PLAYER_CONFLICT;
    for (unsigned i=0;i<MNG_PLAYER_COUNT;i++) if (p->seats[i]==id) return MNG_PLAYER_CONFLICT;
    if (!capacity(p,1)) return MNG_PLAYER_LIMIT;
    clear(p,d); p->seats[player]=id; return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_unassign(struct mng_players *p, unsigned player) {
    if (!p || player>=MNG_PLAYER_COUNT) return MNG_PLAYER_INVALID;
    struct mng_device *d=device(p,p->seats[player]);
    if (!d) return MNG_PLAYER_OK;
    if (!capacity(p,1)) return MNG_PLAYER_LIMIT;
    clear(p,d); p->seats[player]=0; return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_swap(struct mng_players *p, unsigned first, unsigned second) {
    if (!p || first>=MNG_PLAYER_COUNT || second>=MNG_PLAYER_COUNT) return MNG_PLAYER_INVALID;
    if (first==second) return MNG_PLAYER_OK;
    struct mng_device *a=device(p,p->seats[first]), *b=device(p,p->seats[second]);
    if (!capacity(p,(unsigned)(a!=NULL)+(unsigned)(b!=NULL))) return MNG_PLAYER_LIMIT;
    if (a) clear(p,a);
    if (b) clear(p,b);
    uint64_t temporary=p->seats[first]; p->seats[first]=p->seats[second]; p->seats[second]=temporary;
    return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_focus(struct mng_players *p, int focused) {
    if (!p || (focused!=0 && focused!=1)) return MNG_PLAYER_INVALID;
    if (p->focused==focused) return MNG_PLAYER_OK;
    unsigned count=0;
    for (unsigned i=0;i<MNG_DEVICE_COUNT;i++) count+=(p->devices[i].id!=0);
    if (!capacity(p,count)) {
        /* Losing focus must still release every button even if the practically
         * unreachable token counter is exhausted. No further updates allowed. */
        p->focused=0;
        for (unsigned i=0;i<MNG_DEVICE_COUNT;i++) { memset(&p->devices[i].input,0,sizeof(struct mng_input)); p->devices[i].pressed_edges=0; }
        return MNG_PLAYER_LIMIT;
    }
    for (unsigned i=0;i<MNG_DEVICE_COUNT;i++) if (p->devices[i].id) clear(p,&p->devices[i]);
    p->focused=focused; return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_token(const struct mng_players *p, uint64_t id, uint64_t *token) {
    if (!p || !id || !token) return MNG_PLAYER_INVALID;
    const struct mng_device *d=lookup(p,id);
    if (!d) return MNG_PLAYER_NOT_FOUND;
    *token=d->token; return MNG_PLAYER_OK;
}
static float clamp(float value, float minimum) { return value<minimum ? minimum:value>1 ? 1:value; }
enum mng_player_status mng_players_update(struct mng_players *p, uint64_t id,
    uint64_t token, uint64_t sequence, const struct mng_input *input) {
    if (!p || !id || !input || !token || !sequence || (input->buttons&~MNG_BUTTON_MASK)) return MNG_PLAYER_INVALID;
    struct mng_device *d=device(p,id);
    if (!d) return MNG_PLAYER_NOT_FOUND;
    if (!p->focused) return MNG_PLAYER_INACTIVE;
    if (token!=d->token || sequence<=d->sequence) return MNG_PLAYER_STALE;
    struct mng_input normalized=*input;
    for (unsigned i=0;i<4;i++) {
        if (!isfinite(input->sticks[i])) return MNG_PLAYER_INVALID;
        normalized.sticks[i]=clamp(input->sticks[i],-1);
    }
    for (unsigned i=0;i<2;i++) {
        if (!isfinite(input->triggers[i])) return MNG_PLAYER_INVALID;
        normalized.triggers[i]=clamp(input->triggers[i],0);
    }
    d->pressed_edges|=(normalized.buttons&~d->input.buttons)&MNG_GUEST_BUTTON_MASK;
    d->input=normalized; d->sequence=sequence; return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_consume(struct mng_players *p, unsigned player,
    uint64_t *id, struct mng_input *input) {
    enum mng_player_status status=mng_players_read(p,player,id,input);
    if (status!=MNG_PLAYER_OK) return status;
    struct mng_device *d=device(p,*id);
    if (d && p->focused) { input->buttons|=d->pressed_edges; d->pressed_edges=0; }
    input->buttons&=MNG_GUEST_BUTTON_MASK;
    return MNG_PLAYER_OK;
}
enum mng_player_status mng_players_read(const struct mng_players *p, unsigned player,
    uint64_t *id, struct mng_input *input) {
    if (!p || player>=MNG_PLAYER_COUNT || !id || !input) return MNG_PLAYER_INVALID;
    const struct mng_device *d=lookup(p,p->seats[player]);
    *id=d ? d->id:0;
    memset(input,0,sizeof(*input));
    if (d && p->focused) *input=d->input;
    return MNG_PLAYER_OK;
}
