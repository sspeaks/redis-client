# Rules for text that will be published

The publisher refuses the whole output if any title, summary, body, comment, or table row breaks one of these.

- Write plain Markdown. No HTML, images, entities, hidden characters, footnotes, or link definitions. A closing square bracket must not be followed by a colon.
- In prose, leave a space after a less-than sign.
- Links: only `[text](https://host/path)` or `[text](docs/page.md)`, without a title.
- Name no people. In prose, an at sign may only be inside an address such as a@b.c, or have spaces around it.
- Put Haskell in code. Inline code is one pair of single backticks on one line, with no vertical bar inside. If a paragraph also has a dollar sign, or a backslash next to a backtick, use a block instead when the code holds an at sign, a tag, an entity, or a link.
- A code block starts in the first column and has this form. Nothing follows the closing line. Other languages: bash, c, cabal, console, diff, json, nix, python, sh, shell, text, yaml, or none.

```haskell
f @Int <$> xs
```

- Do not put a closing keyword before an issue reference. Say "part of" or "see". The publisher links the ticket itself.
- Do not write markers that skip CI, or the factory's ticket and comment markers.
- Nothing that looks like a secret, also in patches: tokens, keys, passwords, passwords in URLs, or long random or encoded strings. Use short placeholders such as "password".
- Write commit ids in full only if they are commits of this repository. Other hexadecimal strings must be shorter than 32 digits. Digests cannot be published.
- Titles and table rows are one line. A title has at most 120 characters.
