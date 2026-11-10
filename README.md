# collie-tricks

Four tricks for [Collie](https://github.com/AltanS/collie).

Tricks need a Collie build that has the `collie trick` command. Run `collie trick` to check.

A trick is a small program on your machine. Collie runs it every few minutes and reads one JSON document from its output.
The document says what to show on your phone, and Collie draws it with its own parts, so a trick never ships its own screen.
A trick may also ask you a question, called a Decision, and your answer goes back to the trick.

## The tricks

| Trick | What it does | Needs |
| ----- | ------------ | ----- |
| [`ui-approvals`](ui-approvals/) (UI Approvals) | Asks for your yes, by name, for each visible change a worker lists in a `LOOK.md`, with its screenshot. | `git`, a branch worktree with a `LOOK.md` and a `.look/` folder of PNG shots |
| [`pr-inbox`](pr-inbox/) (PR Inbox) | Offers each reply draft to open pull requests and issues as a Decision, and posts it under your own login after your tap. Dry run by default. | `gh` (logged in), `git`, a folder of `<number>.md` drafts |
| [`release-gates`](release-gates/) (Release Gates) | Reads seven release gates and asks one Decision, "Tag and push?", when all are green. It never tags. Written for one release process: read its README first. | `gh`, `git`, the result files its README names |
| [`running-builds`](running-builds/) (Running Builds) | Shows which commit a running Collie serves, beside the head of each checkout. | `git`, optional `health_url` of a running Collie |

`ui-approvals`, `pr-inbox` and `release-gates` also have a `SKILL.md`. It is the half of the work that an agent reads with
`collie trick skill <name>` while the trick is on.

## Install and switch on

```sh
collie trick add ui-approvals   # a name means that subfolder of this repository
collie trick list              # shows the trick, off
                                # now set your paths in its config.toml; see the trick's README
collie trick on ui-approvals    # the switch
```

Replace `ui-approvals` with the trick you want. A trick is off until you run `collie trick on <name>`. `collie trick off <name>`
switches it off again.

## Safety

- A trick is off until you switch it on.
- The switch approves the code as it is now. It stores a hash of the code.
- A change to a trick's code never runs without your yes.
- A trick never sends a message or types into a session for you. It may show you a Decision, and it acts only after your tap.
- The one write in this repository is `pr-inbox` posting a comment after your tap, and only with `live = true`. It ships with `live = false`.
- `release-gates` never tags and never pushes. A yes is a record.
- Read the code first. A trick runs as you, with your tools and your login. Read `program.ts`, `trick.ts` and
  `config.toml` before you run `collie trick on`.
- `collie trick check <folder>` lists what the code runs and reaches. It is a grep, not a proof.

## Write your own

```sh
collie trick init my-trick
```

This makes a folder with `trick.toml`, `program.ts`, the helper `trick.ts`, `config.toml` and `AGENTS.md`. Edit
`program.ts`. Run it with `collie trick dev <folder>`, which prints what the phone would draw and writes nothing to the
phone. The four folders here are worked examples: each has a `test.sh` that runs the program against fake `gh` and `git`.

To run the tests of this repository you need a Collie source checkout with trick support:

```sh
COLLIE_REPO=/path/to/collie sh ui-approvals/test.sh
```

## Share a trick

Publish your trick in your own repository and give the repository the GitHub topic `collie-trick`. A person can find it by
that topic and read it before they add it. Keep one trick per folder, and keep its `README.md` honest about what it reads,
what it runs and what it can write.

## Licence

MIT. See [LICENSE](LICENSE). The repository is `https://github.com/AltanS/collie-tricks`.
