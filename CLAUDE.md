# !ErrorLog

The workspace's measuring tool: an error catcher and a stutter profiler. The
folder name must keep its `!` so it loads before every other addon. GitHub repo:
`Fostercare5988/ErrorLog`.

| File | Job |
| --- | --- |
| `ErrorLog.lua` | Error handler, saved error list, window, red counter, `/err`; shares `ErrorLog` (onLoad hooks, `ShowReport`, `Print`) with the profiler |
| `Profiler.lua` | `/lag`: wraps every addon's OnEvent, OnUpdate, OnShow, OnHide, C_Timer callbacks and hooksecurefunc hooks, and after login every XML script; records slow frames with their events, garbage collections, CPU and new Lua memory per addon |

Things to know:

- Saved data loads on our own `ADDON_LOADED`, before later addons load, so the
  profiler hooks their frames from the start. Hooks only go in at load, so
  `/lag on` and `/lag off` reload the UI.
- The profiler replaces `SetScript`/`GetScript` on every widget type,
  `C_Timer.After`/`NewTimer`/`NewTicker` and `hooksecurefunc`. `GetScript` hands
  back the original handler. On `PLAYER_LOGIN` it walks `EnumerateFrames` and
  wraps every script not yet wrapped (XML files, the game's own UI) as
  "Game UI and XML", under the frame's name; frames built from XML templates
  later stay unwrapped. Each call is charged only its own time (nested calls go
  to their own addon).
- The frame time is `debugprofilestop` between two driver ticks, the same window
  the handlers are charged in; the engine's `elapsed` is not used. A frame that
  registers all events counts them per frame, and each slow frame keeps the
  most frequent ones (2026-11-03: Stratholme stutters showed 0 ms with the old
  `elapsed` window and no hooks or XML timed).
- Never create a widget that can take keyboard focus without clearing it: the
  sample EditBox once swallowed all key presses.
- Memory per addon is the rise in `gcinfo()` across each handler call: two cheap
  reads, no heap walk. `UpdateAddOnMemoryUsage` recounts the whole heap and would
  cause stutters of its own, so the profiler does not use it.
- A saved stack starts at the code that raised the error: `GetErrorCallstackHeight`
  (ClassicAPI 1.19) names its level. The handler chains to the handler that was
  there at load, ClassicAPI's Lua error window, only with `/err popup` on.
- A repeated error costs one table lookup; keep the error handler cheap because
  an addon can error every frame.
- Data: `WTF\Account\<account>\SavedVariables\!ErrorLog.lua`, written on
  `/reload` or logout.
