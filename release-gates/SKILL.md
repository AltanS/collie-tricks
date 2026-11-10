# Release Gates: the release session's half

The Release Gates trick reads seven gates for the `version` in its `config.toml` and asks the operator one Decision,
"Tag and push v<version>?", when all seven are green. The trick never tags. You do, after the yes.

Keep these files, so the gates can read them:

- Counsel note: after a second-opinion review of the release (counsel), write the file named by `counsel` in Release Gates' `config.toml`. It must name the version
  (`counsel v2.4.0-rc.1: no blocker`) and be newer than the newest tag.
- Hold file: while a peer release is in flight, write the file named by `hold` with one line of
  reason. Delete it when the peer release is done. No file: gate 6 is green.
- Windows rehearsal (a minor): save the output of your Windows rehearsal as
  the file named by `rehearsal`. Its last line must be `rollback: ok`.
- Name your session exactly as `release_session` in the config ("release"), so the Decision carries your
  replyTo and the answer comes to you.

The answer arrives in your session as the operator's own message, in this form:

    Answer to dc_...
    Option: tag            (or not-yet)
    Read the decision with: collie hill status dc_...

Run `collie hill status <id>` to read the title and confirm the version. On `tag`, tag and push the release
head, then clear `version` in Release Gates' config. On `not-yet`, wait: Release Gates asks again after 24 h while the gates
stay green. The Decision takes no words, so no line of text comes with it.
