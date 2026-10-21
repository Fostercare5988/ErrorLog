# !ErrorLog

Catches every Lua error from every addon and finds out what makes the game
stutter, for World of Warcraft 1.12.1 (build 5875, Interface 11200).

## Features

- **Errors without popups.** Every Lua error is saved with its stack trace, zone,
  time and how often it happened, and shown in a window you can copy from. A small
  red counter shows unread errors. Blizzard's popup is off by default.
- **Errors from loading too.** The `!` makes it load first, so it also catches
  errors raised while other addons load.
- **Stutter profiler.** Times every addon's event, update and timer code. For each
  frame over 100 ms it records how much was addon code and which addon and line
  ran, whether Lua garbage collection ran, and each addon's CPU use per second.
  A stutter with almost no addon time is the game itself.
- **Kept across sessions** in SavedVariables (`ErrorLog_DB`), up to 100 different
  errors and 40 stutters.

## Commands

| Command | Does |
| --- | --- |
| `/err` | Open the error window (its **Stutters** button switches to the report) |
| `/err clear` | Forget all saved errors |
| `/err popup` | Show Blizzard's error popup as well |
| `/err test` | Raise a test error |
| `/lag` | Open the stutter report |
| `/lag on` / `/lag off` | Start or stop the profiler (reloads the UI) |
| `/lag clear` | Forget the stutter data |

In the window, click **Select All** and press Ctrl+C to copy.

## Requirements

WoW 1.12.1 with **ClassicAPI** loaded (the profiler uses its Lua backports and
precise timer). The profiler adds a small cost while it is on; leave it off when
you are not measuring.

## Installation

Download the code with **Code → Download ZIP**, extract it and rename the folder
to `!ErrorLog` inside `Interface/AddOns`, keeping the `!`. The folder must contain
`Interface/AddOns/!ErrorLog/!ErrorLog.toc`.
