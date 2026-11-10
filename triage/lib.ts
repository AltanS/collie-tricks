// The house check: the rules a public reply passes before Triage offers it. Triage's own; everything shared
// (the mask, the records, the cache, the time) is Collie's helper, trick.ts.

import { firstSentence, mask } from "./trick.ts";

const PRAISE = ["great", "awesome", "excellent", "sharp", "precise", "amazing", "fantastic", "brilliant", "wonderful", "superb", "impressive", "outstanding", "stellar", "perfect", "nice work", "good catch", "well done", "kudos"];
const MONTHS = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?";
const WEEKDAYS = "monday|tuesday|wednesday|thursday|friday|saturday|sunday";
const DATE_PROMISES: RegExp[] = [
  /\b(?:next|this) (?:week|month|weekend)\b/i,
  /\b(?:today|tonight|tomorrow)\b/i,
  /\bend of (?:the )?(?:day|week|month)\b/i,
  /\bwithin (?:a|one|two|three|\d+) (?:days?|weeks?)\b/i,
  /\bin (?:a|one|two|three|\d+) (?:days?|weeks?)\b/i,
  new RegExp("\\b(?:by|on|this|next|until) (?:" + WEEKDAYS + ")\\b", "i"),
  new RegExp("\\b(?:" + MONTHS + ")\\.? \\d{1,2}(?:st|nd|rd|th)?\\b", "i"),
  new RegExp("\\b\\d{1,2}(?:st|nd|rd|th)? (?:of )?(?:" + MONTHS + ")\\b", "i"),
  /\b20\d\d-\d\d-\d\d\b/,
];
/** The rules a draft passes, in the words of the Decision's chips. */
export const HOUSE_RULES = ["no key", "no name", "no em dash", "no date", "no praise", "plain"];
const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const firstLine = (text: string): string => (text.trim().split("\n")[0] ?? "").trim() || text;

/** The first rule a draft breaks, with the line that breaks it, or null when it passes every rule. */
export function checkDraft(text: string, names: string[]): { why: string; line: string } | null {
  const prose = text.replace(/`[^`\n]*`/g, "code");
  const sentences = text.replace(/\s+/g, " ").trim().split(/(?<=[.!?])\s+/);
  const find = (re: RegExp): string => sentences.find((s) => re.test(s)) ?? firstLine(text);
  if (mask(text) !== text) return { why: "a key, a token or a home path", line: find(/sk-|gh[pousr]_|github_pat_|eyJ|\/home\//) };
  if (names.length === 0) return { why: "the name check has no name: set names in config.toml", line: firstSentence(text) };
  for (const n of names) if (new RegExp(escapeRe(n), "i").test(text)) return { why: "the operator's name", line: find(new RegExp(escapeRe(n), "i")) };
  if (text.includes("—")) return { why: "an em dash", line: find(/—/) };
  for (const re of DATE_PROMISES) {
    const m = prose.match(re);
    if (m) return { why: 'a date promise: "' + m[0] + '"', line: find(re) };
  }
  for (const w of PRAISE) if (new RegExp("\\b" + escapeRe(w) + "\\b", "i").test(prose)) return { why: 'a praise word: "' + w + '"', line: find(new RegExp("\\b" + escapeRe(w) + "\\b", "i")) };
  const listLine = text.split("\n").find((l) => /^\s*(?:[-*+]|\d+[.)])\s/.test(l) || /^\s*#/.test(l));
  if (listLine !== undefined) return { why: "a bullet list or a header", line: listLine };
  if (prose.includes("!")) return { why: "an exclamation mark", line: find(/!/) };
  if (/\n\s*\n/.test(text.trim())) return { why: "more than one paragraph", line: firstLine(text.trim().split(/\n\s*\n/)[1] ?? "the second paragraph") };
  return null;
}
/** Hides the operator's names in a line a card shows, so the card never carries the name it refused. */
export function hideNames(text: string, names: string[]): string {
  return names.reduce((out, n) => out.replace(new RegExp(escapeRe(n), "gi"), "[name]"), text);
}
/** Several lines kept, control characters out, cut to `max` (the mask runs on the whole document). */
export function clipBlock(text: string, max: number): string {
  const kept = text.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, " ").trim();
  return kept.length <= max ? kept : kept.slice(0, max - 3).trimEnd() + "...";
}
