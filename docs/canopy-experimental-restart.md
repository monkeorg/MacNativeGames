# Experimental game-only restart (#55)

Authority: [issue #55](https://github.com/monkeorg/MacNativeGames/issues/55),
updated 2026-10-25T13:09:22Z, with no issue comments at audit time. The related
[draft PR #33](https://github.com/monkeorg/MacNativeGames/pull/33), head
`ad432e9e3a8f45a8252be2bb8501fdd22505233b`, records the same unresolved mechanism.
The user has explicitly accepted unsaved-progress loss and crash risk. That risk
acceptance is already authorization for the experimental feature; guaranteed
save completion or safe whole-runtime teardown is not a prerequisite.

## Requirement inventory

| Requirement | Current evidence / remaining work |
| --- | --- |
| A red **Restart game** button beside **Keep playing** | Not wired into the shared overlay. New restart-only source must be integrated by its assigned UI owner. |
| First confirmation explains possible unsaved-progress loss | Native controller policy tested; UIKit presentation still unwired. Required text and behavior: **Cancel**, red **Continue**. This is the first of the two requested confirmations, not another permission request. |
| Second confirmation asks for the final decision | Native controller policy tested; UIKit presentation still unwired. Required actions: **Cancel**, red **Restart game**. Only its affirmative action may submit the engine request. |
| Cancel at the first confirmation | Native fixture verifies zero engine calls and unchanged session canaries; UIKit integration remains open. Must make zero restart/engine calls and leave the current session, input/focus policy, settings, saves and identity untouched by the restart controller. |
| Cancel at the second confirmation | Same native-fixture evidence; UIKit integration remains open. Same invariant. The first Continue action must not have submitted or prepared a destructive engine operation. |
| Actual game-only restart | Still missing: a verified request that selects Title or the supported load sequence, with its arguments and valid guest-thread context. An absent or disabled dispatcher is not a restart mechanism. |
| UIKit and app process stay alive | Required during the actual transition; neither app exit/relaunch nor calling the loader/main entry twice qualifies. |
| Requests cannot overlap | The native controller enforces this, including synchronous completion while submission is still on the stack. Actual host wiring remains open. A real request remains single flight through engine acceptance and its actual completion/failure observation. Repeated button presses or stale dialog callbacks must not dispatch again. |
| Actual completion evidence | Observe the requested Title scenery or an actual game-owned reload. A submitted request, callback return, HUD change or simulated fixture is insufficient game acceptance. |
| Graphics preferences remain separate | A title/save reload does not by itself rebuild host graphics. Pending host startup settings keep their full-app-restart label until an actual coordinated apply path exists. |
| Preserve account identity, backups and private inputs | No all-data reset, account replacement, backup deletion, container rewrite or private-input mutation is authorized by this feature. The accepted risk concerns unsaved game progress and crashes. |
| Record physical outcomes and failures | Required for the exact candidate, title/version and device. No commercial game transition or physical restart has been executed in this cloud environment. |
| Keep work reviewable | No merges or releases. No private game bytes, keys, saves or private research outputs are uploaded. |

## Existing mechanism evidence

The issue reports that private 1.4.3 metadata verifies the original return-to-title
sequence and its scene-lifecycle callback chain. The inspected public checkout
contains no corresponding callable selector, typed request layout or validated
guest-thread hook. PR #33's current body/status diff also says that the request
selecting **Title** and the permitted guest-thread context remain unidentified.
Those statements are evidence of private research, not evidence that this cloud
checkout can safely identify or invoke a game function.

The missing operation is target selection plus transition context. Calling the
known lifecycle callback alone may consume a different pending transition. An
unidentified factory, debug all-data reset or guessed request object must not be
invoked. Replaying game-menu inputs is explicitly excluded as the restart
mechanism.

The next engine investigation is to observe one normal, original return-to-title
transition and trace the request that selects its target. A usable handoff needs
the exact original input/version pin, verified target-selection entry/hook,
argument and ownership layout, how the valid guest-thread context is obtained,
and how the resulting Title/load transition is observed. Keep private instruction
bytes, memory, saves and captures local. No address, factory or scenery enum is
guessed from the request's English name.

## Independent cloud work and scope

`launcher/include/mng_restart.h` and `launcher/src/mng_restart.c` implement the
confirmation/cancellation/single-flight control plane against a mandatory real
dispatcher interface. There is no default provider. Monotonic tickets reject stale
dialog/completion events. Final confirmation submits once without holding the
controller lock; an actual engine observer must later acknowledge Title/reload
completion or definitive failure. Submission alone never means completion. A
no-op provider remains pending, rather than reporting a restart. A timeout while
an old request could still complete is not definitive failure and must not permit
a new overlapping request.

`tests/test_canopy_restart.py` runs six strict native C/UBSan fixture cases. An
original background engine thread performs its own fixture-owned Title
transition, drops its invented unsaved progress and preserves identity/backup/
input canaries. Both cancels make zero engine calls; duplicates, overlap, stale
events, refusal and synchronous completion are checked. They cannot prove a
TOTK restart. The C component is not added to shared build/UI/host files yet. The production mechanism and its shared host/UI wiring remain open
until the original engine request and guest-thread contract are established.
There must be no default successful no-op dispatcher or advertised restart
capability derived from imported/prepared JSON.

The current ABI3 main-worker observation is separate work. Cleanup observation,
an actual main-thread join, zero owned guest-child records or an unexpected SDK
return do not reload a game. They do not reset frontend, audio, IPC, graphics,
module or cached patch ownership. They neither supply this experimental engine
request nor make a second loader invocation an implemented restart.

A fallback full-session implementation may still be investigated, but its
teardown complexity must not be presented as a mandatory prerequisite for an
engine-owned reload. Conversely, accepting experimental crash risk does not
identify an unknown factory or justify reporting success before a real transition.
