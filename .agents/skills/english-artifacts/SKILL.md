# Skill: English-language artifacts

Use this skill for every task. It always applies, alongside whichever
task-specific skills are relevant.

## Rule

Everything the agent generates for this repository is written in English,
regardless of the language of the prompt, the conversation, or any source
material being worked from.

This covers all generated artifacts:

- source code: identifiers, comments, documentation comments, and
  user-facing string literals;
- file names and folder names being created or renamed;
- branch names, commit messages, pull request titles and bodies, and
  issue text;
- documentation, reports, and benchmark result files;
- test names and test descriptions.

## Prompt language does not transfer

The user may prompt in Bahasa Indonesia (or any other language). That
choice governs the conversation only. It never changes the language of
generated code, file names, folder names, commits, or documents: those
stay in English.

Do not create Indonesian-named files or folders (for example `dokumen/`,
`laporan-hasil.md`, `pengujian/`). Use the English equivalent
(`docs/`, `results-report.md`, `tests/`).

Do not translate established English technical terms inside artifacts, and
do not mix languages inside a single artifact.

## Exceptions

- Verbatim quotations of user-provided or external content keep their
  original language.
- When the task itself is a translation, the output language is the
  requested target language.
- Proper nouns keep their original form.

## Existing non-English content

If a file being edited is not in English and the task is not a
translation, keep the edit minimal and flag the language mismatch in the
report instead of silently mixing languages in one artifact. Translating
the file is a separate, explicit task.
