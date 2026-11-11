# Morph

Morph adds a view of a session to ColliePWA, beside Terminal and Chat. In that view the session's own agent answers you
with one screen you can tap, not a wall of text: a short answer, a diff, a table, a picture, two or three buttons.

Morph has no program. Nothing of it runs on your machine. It is two files: `trick.toml`, and `rules.md`, the instructions
your agent reads when you write to it from the view. The agent draws the screen with Collie's own parts, so the screen
looks like the rest of the app.

Files: `trick.toml` (no `run` line, `places = ["agent-view"]`, `rules = "rules.md"`, `contract = 2`), `rules.md`, and
this README.

## Add it

On the machine that runs Collie:

```sh
collie trick add morph
# or name the repository and the folder:
collie trick add https://github.com/AltanS/collie-tricks//morph
```

Once Morph is on the official list, Settings, Tricks also offers it with an Add button. Morph needs a Collie build that
knows agent views (trick contract 2). An older build refuses it with a line that names the contract.

## Switch it on

1. Read `rules.md`. Morph's About sheet in Settings, Tricks shows the same text in full, under Read the instructions.
2. Switch the trick on in Settings, Tricks (or run `collie trick on morph`).
3. Open a session, and switch Morph on for that session in the session menu. It is off for every other session.

Then write to the agent from the Morph view. The agent answers by drawing one screen.

## What a tap sends

A tap on a button sends the button's visible words, and nothing else, to that session, as a message in your name. It
reads like this in the chat:

```text
[view:morph <session>] from operator: tapped "Fix both tests"
```

A button carries no hidden value. What you see on the button is what the agent gets.

## Limits

- It works for sessions on the lead machine only, or on a Collie with no crew. Sessions on other machines of a crew
  have no Morph view.
- The agent can be wrong. A screen is the agent's answer, not a check by Collie. Read it as you would read its reply in
  the terminal.
- `rules.md` is the author's words to your agents. Read it before you switch Morph on. A change to it is a new version,
  and Collie asks for your yes before your agents get it.
- `rules.md` tells the agent never to draw a permission prompt on its screen. Answer a permission only in Collie's own
  prompt.

## Write your own

An agent-view trick is a folder with `trick.toml` and a rules file. To write your own, copy this folder, give it a new
name, and change three things:

1. In `trick.toml`, set `id` to the folder's name, and set `name`, `description` and `about`.
2. Rewrite `rules.md`: what your view is for, and how a screen should read. Collie gives every agent the commands, the
   parts and the safety rules, so your rules need not repeat them.
3. Check the folder with `collie trick check <folder>`.

`rules.md` takes plain ASCII text only: no tab, no line over 160 characters, no space at the end of a line, at most
8 KiB, and a line break at the end. `collie trick check` names each line that breaks this.
