# UI Approvals: ask for the yes by name

Every change to what a person sees or taps waits for the operator's yes by name. Ask through UI Approvals. The notes file is still called `LOOK.md`, and the shots folder `.look/`. Agents already write these two names, so they stay.

1. At the root of your worktree, keep `LOOK.md` and a folder `.look/` for the shots. Keep both out of git:
   add `LOOK.md` and `.look/` to the file that `git rev-parse --git-path info/exclude` prints.
2. One line per visible change, by name. Never two changes on one line:
   `- <name> | <route or screen> | <one sentence> | <shot> [| <before shot>] [| suggest <yes|no|change>: <why>]`
   - name: short, at most 50 characters, the thing the person sees, such as "The status item". UI Approvals asks
     "Ship “<name>”?", with the options Ship it (yes), Keep the old look (no) and Ask for a change (change).
   - route: a path such as `/settings/sync` (UI Approvals links it on the `lane` in UI Approvals' `config.toml`), or a screen in words.
   - sentence: one sentence of at most 200 characters, what the person sees move where, and why. shot: a PNG in `.look/`, 390 px wide, at most 512 KB.
   - suggest (optional, last): your own advice on the answer, the word `suggest`, then `yes`, `no` or `change`, a
     colon and one plain sentence of at most 200 characters. The operator sees it as a quote from you, with a
     star on that option, never pre-selected. Suggest an answer only when you have a reason the operator can
     check. A field in any other form is ignored, and UI Approvals shows one warn row, "suggest field not understood".
     A changed suggest field is a changed line: the change is asked again.
3. A line with no shot, a shot over the cap, or a LOOK.md that git would commit is not asked: fix it.
4. Keep the line and the shot as they are while you wait. A changed line or shot is asked again,
   because a yes holds only for the words and the picture the operator saw.
5. Do not ship the change before the yes. Keep it on your branch.

Start your session in the worktree root, so the answer comes to you. Failing that, the session named
`reply_session` in UI Approvals' `config.toml` gets it. With neither, the answer stays in UI Approvals' records only.

The answer arrives in your session as the operator's own message, in this form:

    Answer to dc_...
    Option: yes            (or no, or change)
    <the operator's words, when there are any>
    Read the decision with: collie hill status dc_...

The message does not name the change. Run `collie hill status <id>` to read the title
("Ship “<name>”?") and see which line was meant. On `change`, the words say what to change:
change it, take a new shot, and keep the same name. On `no`, take the change out of your branch.
