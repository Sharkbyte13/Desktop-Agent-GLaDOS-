# GLaDOS Desktop Agent

An animated GLaDOS that lives on your Windows desktop. She sits on top of your
other windows, listens for her name, answers out loud in her own voice, and does
small real jobs on your PC: opening apps, reading and writing files in your user
folders, setting timers, adjusting the volume, and reporting on the system.

Everything runs on your own machine. The overlay is plain Windows PowerShell and
.NET, which ship with Windows, so there is nothing to compile and nothing needs
administrator rights. Speech recognition, her voice and her "brain" are separate
local pieces you add if you want them.

The project is built to be customised: most of her behaviour is driven by a
single settings file. It is still in testing, and you are welcome to download
it, change it and make it your own.

> Unofficial fan project. Not affiliated with or endorsed by Valve. See
> [Disclaimer](#disclaimer).

## What she can do

- **Talk.** Type to her in a chat window, or say a phrase with her name in it,
  such as "hey GLaDOS". After she asks you something, the microphone stays open
  for a short while so you can answer without saying her name again.
- **Speak.** She answers in a GLaDOS voice from a local text-to-speech model, or
  in a Windows voice if that model is not installed. Captions appear beside her,
  timed to the audio.
- **Do things.** A fixed set of 21 tools: open and list apps, lock the screen,
  change the volume, set timers and reminders, keep notes, read and set the
  clipboard, report system status, and list, search, read, write and move files.
  Timers appear on the desktop as glowing nixie tubes.
- **Ask first.** Anything that changes your machine, such as writing a file or
  changing the volume, asks for your yes before it runs.
- **Stay out of the way in games.** Game mode notices a running game and frees
  the AI model's video memory between answers.
- **Look at the screen, if you let her.** An optional mode lets her glance at
  your screen now and then and make a remark. It is off by default.

## Requirements

- **Windows 11.** She was built and tested there. Windows PowerShell 5.1 and .NET
  are already part of Windows.
- **Python 3.9 to 3.13** for the optional voice, speech and vision parts. Python
  3.12 from [python.org](https://www.python.org/downloads/) is the safe choice.
  Tick "Add python.exe to PATH" when installing.
- **A brain, optionally.** For real conversation and tool use she needs one of:
  - a local model through [Ollama](https://ollama.com/download), which the brain
    setup installs for you,
  - a local model through [LM Studio](https://lmstudio.ai/), or
  - an Anthropic API key.

  Without any of these she still works, using a built-in offline personality
  that matches patterns rather than thinking.

The local models are several gigabytes each. A graphics card with plenty of
video memory makes them much faster.

## Install

1. **Download the project.** Use the green **Code** button and **Download ZIP**,
   or clone it. Extract it somewhere permanent, such as `Documents\GLaDOS`. Her
   startup shortcut points at this folder, so moving it later breaks the
   shortcut.

2. **Add the optional parts you want.** Each is one double-click, and each can be
   run again later. Do these before step 3 if you can.

   | Script | What it sets up |
   | --- | --- |
   | `brain\Setup-Brain.cmd` | Installs Ollama, downloads a local model that can use tools (first choice `qwen3:8b`), and tests it. |
   | `voice\Setup-Voice.cmd` | Microphone listening. Installs faster-whisper in a private Python environment and tests your microphone. |
   | `tts\Setup-TTS.cmd` | Her voice. Installs PyTorch in a private Python environment and downloads the GLaDOS voice model, about 330 MB, from the [glados-tts](https://github.com/R2D2FISH/glados-tts) project. |
   | `eye\Setup-Eye.cmd` | Screen glances. Only needed if you plan to turn vision on. |

3. **Run `Install.cmd`.** It adds her to your Startup folder, creates desktop
   and Start menu shortcuts, and starts her. She appears in the top-left corner
   and comes back every time you log in.

If Windows shows "Windows protected your PC", that is SmartScreen reacting to an
unsigned script. Click **More info**, then **Run anyway**.

To remove her, run `Uninstall.cmd`. It stops her and her helper processes and
removes the shortcuts. Delete the folder afterwards if you want.

## Using her

| Action | What it does |
| --- | --- |
| Left-click and drag | Move her. The position is remembered. |
| Left-click | Open or close the chat window. |
| Right-click, or the tray icon | Menu: chat, reset position, edit settings, shut down. |
| Say a wake phrase | Get her attention by voice. The phrases are in `voice\wake_phrases.json`. |

Type `/help` in the chat window for the full list of commands:

| Command | What it does |
| --- | --- |
| `/wake` | Show the wake phrases. `/wake edit` opens the list. |
| `/followup` | Keep listening after she asks you something. `/followup always` |
| `/find <words>` | Search everything said so far. |
| `/captions` | The caption box beside her. `on`, `off` or `test` |
| `/tubes` | The timer tubes. `on`, `off` or `here` |
| `/brain` | Which brain is answering. `auto`, `ollama`, `lmstudio`, `anthropic`, `offline` |
| `/game` | Game mode. `auto`, `on` or `off` |
| `/vision` | Screen glances. `on`, `off` or `now` |
| `/glow` | Her halo. `on` or `off` |
| `/listen` | Microphone status. |
| `/voice` | Speech status. `auto`, `http`, `sapi`, `none` or `test` |
| `/say <text>` | Speak a line out loud. |
| `/mute`, `/unmute` | Stop and resume speaking. |
| `/key <api-key>` | Store an Anthropic API key. |
| `/model <name>` | Change the Anthropic model. |
| `/open <thing>` | Launch an app, or open a folder or web address. |
| `/time`, `/date` | The current time or date. |
| `/clear` | Wipe the conversation. |
| `/pos`, `/reset` | Report her position, or send her back to the corner. |
| `/quit` | Shut her down. |

## Choosing her brain

With the default setting, `llmEngine: auto`, she tries these in order:

1. Your preferred local backend, set by `localEngine`. The default is LM Studio.
2. The other local backend.
3. Anthropic, if you have stored an API key.
4. The offline personality.

For LM Studio, load a model that supports tool calling and start its local
server on the default port, 1234. In LM Studio's server settings, check that
"Serve on Local Network" is off, so the model is not offered to other devices on
your network.

## Privacy and safety

- **Local by default.** The microphone audio, the transcripts, her voice and any
  screen glances are all processed on your PC.
- **Except with an API key.** If you add an Anthropic key, your messages and
  anything her tools read for an answer are sent to Anthropic. The key is stored
  in plain text in `config.json`.
- **She only answers to her name.** Speech is transcribed locally, but she only
  responds to phrases containing her name. Transcripts are logged in
  `voice\voice.log`. You can mute the microphone from the tray icon.
- **Limited reach.** Her tools are a fixed list, never a command shell. File
  tools only reach Desktop, Documents, Downloads, Pictures, Videos and Music.
  Text she reads from files or the clipboard is marked as untrusted for the
  model. That is not a guarantee, which is why every change still needs your
  yes.
- **Vision is off until you turn it on.** Screen frames stay in memory and only
  go to a local model. The vision call cannot use any tools.

## Settings

`config.json` is created on first run. Open it from the right-click menu with
**Edit config.json**, and restart her after editing. Many settings also have a
slash command that changes them immediately.

| Setting | Default | Meaning |
| --- | --- | --- |
| `llmEngine` | `auto` | Which brain to use: `auto`, `lmstudio`, `ollama`, `anthropic`, `offline` |
| `localEngine` | `lmstudio` | Which local backend `auto` tries first. |
| `ttsEngine` | `auto` | Her voice model if it is running, otherwise a Windows voice. |
| `visionEngine` | `off` | Screen glances: `off`, `lmstudio` or `ollama` |
| `gameMode` | `auto` | Free video memory between answers while a game runs. |
| `followUp` | `question` | When to keep listening: `question`, `always` or `off` |
| `scale` | `1.0` | Her size. Try `0.7` or `1.5`. |
| `opacity` | `1.0` | `0.1` to `1.0` |

Every setting, with a comment explaining it, is listed in `$script:Defaults`
near the top of `glados.ps1`.

## Troubleshooting

- **She does not appear.** Run her with errors visible:

  ```
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File glados.ps1
  ```

  Also check `glados.log` and `startup-error.txt`. Only one copy can run at a
  time, so a second launch exits silently.
- **Something is wrong at startup.** Run `Diagnose.cmd` and read `diagnose.txt`.
- **Windows Defender says the script "contains malicious content".** This is a
  false positive. Run `Probe.cmd` and read `amsi-probe.txt` to see which file it
  objects to. See [Why so many files](#why-so-many-files).
- **She is silent.** Type `/voice test`, and check `tts\tts.log`.
- **She is hidden behind a game.** Exclusive full-screen mode sits above every
  always-on-top window. Use borderless windowed mode instead.

## For developers

There is no build step: edit a `.ps1` file and restart her. The comments in the
code explain why things are the way they are, usually with the failure that
made them that way.

She runs on Windows PowerShell 5.1, not PowerShell 7. Code that works in a
PowerShell 7 test shell can fail on 5.1, so test with `powershell.exe`, not
`pwsh`. Keep `.ps1` files ASCII-only with no byte-order mark, because 5.1
misreads anything else.

The tests and linters are in `tools\` and `voice\`. Run the PowerShell tests
like this:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_brain_wire.ps1
```

Run the Python tests and the three linters with the voice environment's
Python, after `voice\Setup-Voice.cmd` has built it:

```
voice\.venv\Scripts\python.exe voice\test_wake_match.py
voice\.venv\Scripts\python.exe tools\ps51_lint.py glados.ps1
```

### Why so many files

Windows Defender scores a PowerShell script on everything in it at once. One
file that held window interop, process listing, background threads, web
requests and a startup shortcut was refused as malicious before any of it ran,
even though nothing in it was harmful. Splitting the program into smaller files
keeps each one under that threshold. Before merging files, or adding a lot of
system-level code to `glados.ps1`, run `Probe.cmd` and check that
`amsi-probe.txt` still reports every file as allowed.

Screen capture is a separate case. A PowerShell script that captures, shrinks
and encodes the screen matches a known hacking tool's signature exactly, and is
refused however small it is. That is why the eye is written in Python.

| Path | What it is |
| --- | --- |
| `glados.ps1` | The overlay: window, animation, speech, the event loop. |
| `uilogic.ps1` | Logic with no UI, so it can be tested. |
| `brain\brain.ps1` | The tools, their safety checks, and her personality. |
| `voice\` | Microphone, wake phrases, speech recognition. |
| `tts\` | The voice service. |
| `eye\` | Screen capture for vision. |
| `tools\` | Tests and linters. |

## Credits and licence

- **Original code** in this repository is released under the MIT licence. See
  [LICENSE](LICENSE).
- **Text utilities in `tts\utils\`** come from
  [glados-tts](https://github.com/R2D2FISH/glados-tts) by Timmy Knight, and from
  Keith Ito's [tacotron](https://github.com/keithito/tacotron). Both are MIT
  licensed, and their licences are in `tts\`.
- **The GLaDOS voice model** is not included in this repository. The setup
  script downloads it from the glados-tts project. It is not covered by the MIT
  licence. It was trained on the voice performance of the character from the
  Portal games, so use it for personal, non-commercial fun only. Do not publish
  audio it generates or present it as a real person speaking. See
  `tts\NOTICE.txt`.
- **Python packages** such as faster-whisper, PyTorch and Pillow are installed by
  the setup scripts under their own licences. None of them are included here.

## Disclaimer

This is an unofficial, non-commercial fan project. It is not affiliated with,
endorsed by or sponsored by Valve Corporation.

GLaDOS, Portal, Aperture Science, and the related names, characters, artwork and
logos are trademarks and copyrighted works of Valve Corporation. The character
artwork in `assets\` and the GLaDOS persona are used here for non-commercial fan
purposes only and remain the property of Valve. The MIT licence above covers
only the original code written for this project. It grants no rights in Valve's
material.

This project is free and is not sold. If you are a rights holder and would like
something removed, please open an issue and it will be taken down.
