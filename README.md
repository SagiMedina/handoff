# Handoff

Leave your Mac. Pick up your terminal on your phone.

## What it does

You're working in a terminal on your Mac. You need to leave - meeting, commute, couch. You type `handoff`. Your phone buzzes with a connection ready. You tap it and you're in the same session, same directory, same everything.

## First-time setup (5 minutes)

**Mac:**
```bash
brew install handoff
handoff setup
```

This:
- Installs and starts Tailscale (secure private network)
- Enables SSH on your Mac
- Configures iTerm2 to run inside tmux automatically (invisible - your terminal looks and feels exactly the same)
- Generates an SSH key for passwordless phone access

**Phone:**
1. Install [Termux](https://play.google.com/store/apps/details?id=com.termux) from Google Play, or from [F-Droid](https://f-droid.org/packages/com.termux/) for the full-featured version
2. Open Termux
3. On your Mac, run `handoff pair` - it shows a QR code
4. Scan it with Termux (installs the handoff script, copies SSH key, done)

You now have a **Handoff** widget on your home screen.

## Daily use

You don't change anything about how you work. Open iTerm2, run `claude`, run `vim`, run whatever. Everything is quietly running inside tmux - you won't notice.

When you need to leave:

```bash
$ handoff

  * piko        (claude, 2 windows)
  * dotfiles    (vim)

  Ready. Open Handoff on your phone.
```

On your phone, tap the Handoff widget:

```
  * piko
  * dotfiles

  > piko

  Connecting...
  [you're in]
```

Same session. Same state. Keep going.

When you're back at your Mac - it's still there. Both sides stay in sync.
