# Triage: write a reply draft

Triage offers your draft to the operator as a Decision, "Post the reply on PR <n> (<its title>)?". A Post tap publishes it
under the operator's own login, so the draft must already be the final words.

1. Write the reply as `<number>.md` (the PR or issue number) in the `drafts` folder named in Triage's
   `config.toml`. Keep nothing else there but verdicts.
2. One paragraph, first person, plain words. Open with the verdict; a plain thank-you may share the first
   sentence ("Thanks @handle, this lands in the next release."). Address people by `@handle`.
3. The house check refuses a draft with: the operator's name, an em dash, a date promise ("by Friday",
   "next week", "Nov 20", "tomorrow"), a praise word ("great", "sharp", "precise", ...), a bullet list or a
   header, an exclamation mark, two paragraphs, or a key, a token or a home path. It also refuses a draft
   when the thread has a newer comment from someone else ("the thread moved"). A refused draft is never
   offered; the operator sees the failing line. Read the thread again and write the file again.
4. For a merge, write `<number>.verdict` beside the draft: first line `approve`, then one line of reason.
   A green PR with that verdict gets a second Decision. Merge has no live path: a tap only writes a record.
5. A thread whose newest comment is the operator's own drops out. Delete the draft then.

Name your session exactly as `reply_session` in Triage's `config.toml`, so the answer comes to you:

    Answer to dc_...
    Option: post            (or edit, hold, merge, not-yet)
    <the operator's words, when there are any>
    Read the decision with: collie hill status dc_...

Run `collie hill status <id>` to see which PR or issue it was. On `edit`, the words say what to change:
rewrite `<number>.md`, and the new text is offered again. On `post`, nothing is left to do; with
`live = false` the post is only recorded. On `hold`, wait: Triage offers the draft again after 24 h.
