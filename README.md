# homebrew-echo

Homebrew tap for the [Echo](https://github.com/joyinfant99/echo) voice
dictation Mac hotkey.

## Install

```bash
brew tap joyinfant99/echo
brew install echo-hotkey
```

Follow the one-time setup steps it prints (backend URL/API key,
Microphone + Accessibility permissions, one System Settings toggle).
After that, hold **Fn** anywhere to record — updates apply themselves
automatically in the background, no `brew upgrade` needed.

This repo contains only the built script + Homebrew formula, kept in sync
automatically from the private source repo. No source code lives here.
