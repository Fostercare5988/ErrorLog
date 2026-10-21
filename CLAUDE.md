# !ErrorLog

The workspace's measuring tool: an error catcher and a stutter profiler. The
folder name must keep its `!` so it loads before every other addon. GitHub repo:
`Fostercare5988/ErrorLog`.

| File | Job |
| --- | --- |
| `ErrorLog.lua` | Error handler, saved error list, window, red counter, `/err`; shares `ErrorLog` (onLoad hooks, `ShowReport`, `Print`) with the profiler |
| `Profiler.lua` | `/lag`: wraps every addon's OnEvent, OnUpdate, OnShow, OnHide and C_Timer callbacks, records slow frames, garbage collections and CPU per addon |

Things to know:

- Saved data loads on our own `ADDON_LOADED`, before later addons load, so the
  profiler hooks their frames from the start. Hooks only go in at load, so
  `/lag on` and `/lag off` reload the UI.
- The profiler replaces `SetScript`/`GetScript` on every widget type and
  `C_Timer.After`/`NewTimer`/`NewTicker`. `GetScript` hands back the original
  handler. Blizzard's own code is never wrapped.
- Never create a widget that can take keyboard focus without clearing it: the
  sample EditBox once swallowed all key presses.
- A repeated error costs one table lookup; keep the error handler cheap because
  an addon can error every frame.
- Data: `WTF\Account\<account>\SavedVariables\!ErrorLog.lua`, written on
  `/reload` or logout.
