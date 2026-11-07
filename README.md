# !ErrorLog

Catches every Lua error from every addon and finds out what makes the game
stutter, for World of Warcraft 1.12.1 (build 5875, Interface 11200).

## Features

- **Errors without popups.** Every Lua error is saved with its stack trace, the
  values of the local variables where it happened, zone, time and how often it
  happened, and shown in a window you can copy from. A small
  red counter shows unread errors. ClassicAPI's own error window is off by default.
- **Errors from loading too.** The `!` makes it load first, so it also catches
  errors raised while other addons load.
- **Stutter profiler.** Times every addon's event, update and timer code, its
  hooks on game functions, and the game's own interface scripts. For each
  frame over 100 ms it records how much was addon code and which addon and line
  ran, which events fired in that frame, whether Lua garbage collection ran and inside which addon it started, and
  each addon's CPU use and new Lua memory per second. The addons that make the
  most memory make the next collection, and its stutter, come sooner.
  A stutter with almost no addon time is the game itself.
- **Game checks.** The questions an addon review could not answer outside the
  game wait here: at login it says how many are open, `/check` shows them one
  at a time, runs the test line a check comes with and keeps what it printed,
  and records your answer. VanillaForge's `tools/game_checks.py` brings the
  checks in (with the game closed) and reads the answers back.
- **Kept across sessions** in SavedVariables (`ErrorLog_DB`), up to 100 different
  errors and 40 stutters.

## Commands

| Command | Does |
| --- | --- |
| `/err` | Open the error window (its **Stutters** button switches to the report) |
| `/err clear` | Forget all saved errors |
| `/err popup` | Show ClassicAPI's error window as well |
| `/err test` | Raise a test error |
| `/lag` | Open the stutter report |
| `/lag on` / `/lag off` | Start or stop the profiler (reloads the UI) |
| `/lag clear` | Forget the stutter data |
| `/check` | Show the next open game check |
| `/check ok [note]` / `/check bad <what you saw>` | Answer it |
| `/check run` | Run the check's test line and keep what it printed |
| `/check skip` / `/check list` | The next one / how many are open per addon |

In the window, click **Select All** and press Ctrl+C to copy.

## Requirements

WoW 1.12.1 with **ClassicAPI** loaded (the profiler uses its Lua backports and
precise timer). The profiler adds a small cost while it is on; leave it off when
you are not measuring.

## Installation

Download the code with **Code → Download ZIP**, extract it and rename the folder
to `!ErrorLog` inside `Interface/AddOns`, keeping the `!`. The folder must contain
`Interface/AddOns/!ErrorLog/!ErrorLog.toc`.
