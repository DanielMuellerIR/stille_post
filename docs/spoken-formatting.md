# Spoken formatting

Enable the option under **Settings → Cleanup → Spoken formatting**. It is off by
default. **Profiles → Formatting** can inherit the global setting or override it
independently of LLM cleanup. With LLM cleanup off, formatting is entirely local.

| German command | English command | Output |
| --- | --- | --- |
| Format neuer Absatz | format new paragraph | Paragraph with a blank line |
| Format neue Zeile | format new line | Line break |
| Format Liste Anfang | format list start | First bullet, `• ` |
| Format Listenpunkt | format bullet point | Next bullet on a new line |
| Format Liste Ende | format list end | Return to prose on a new line |
| Format Anführungszeichen Anfang | format quote start | Start a literal quotation |
| Format Anführungszeichen Ende | format quote end | End that quotation |

Commands ignore case and accept recognition punctuation between their words.
Ordinary words such as “new line”, “list” or “quote” do nothing. Full command forms
used as examples must be quoted or placed in a literal block. These commands only
format text; they perform no system or shell actions.

A list start creates the first item and separates preceding prose with a line
break. A bullet command creates the next item; a list end returns to prose. An open
list continues to the end of the text. Paragraph and line commands inside an item
retain their usual effect without ending the list. Lists have one level: a nested
list or an empty item makes the entire affected list block literal, including its
commands. A bullet or end without a start also stays literal. Multiple lists and
explicit leading/trailing breaks are supported. Command-only input never loses its
words or becomes an empty result.

A closed spoken quotation produces “…” for an English start or „…“ for a German
start. The end may use either language. Its contents stay exactly literal,
including Unicode, line breaks and any formatting commands inside. Only delimiter
whitespace at the commands is removed. Open or nested spoken quotes remain literal,
including their commands; an end without a start stays text. No closing quote is
invented. The first literal or quote opener protects its contents; a second spoken
quote start makes that quote invalid.

Example:

```text
format list start 128, not 256. format bullet point format quote start Version 1.2 format quote end format list end Afterwards.
```

becomes:

```text
• 128, not 256.
• “Version 1.2”
Afterwards.
```

Existing straight or typographic quotations stay literal; apostrophes within words
do not open a quote. An open written quote protects the rest of the text. Explicit
literal blocks use **format literal start … format literal end**, or **Format
wörtlich Anfang … Format wörtlich Ende**. Delimiters disappear, but the contents
remain exact. A missing end retains the opener and protects the rest.

Intent is recognized only from the complete, unchanged raw transcript. Model output
cannot create new commands. One logical cleanup processes all ordered segments.
Random markers must retain their exact identity, count, order and position relative
to content words and Unicode symbols. Unambiguous hesitations and immediate word
repetitions may be removed within a region; word substitutions are too uncertain
for the position check. Literal contents are restored from the raw transcript.
The additional marker-free fidelity check still protects numbers, negations and
vocabulary. Confirmed variants apply only outside protected regions.

Changed, missing or moved markers immediately return safely formatted raw text,
without trying another endpoint. The origin is **Raw fallback**. With LLM cleanup
off, an action is **Formatted locally**, with no text network request; without an
action it is **Raw text**. Successful model cleanup is **Cleaned up**.

Recording, test dictation, imports, retries, CLI, bridge, explicit recleanup and
selection cleanup retain their start snapshot. Changing profiles affects future
requests. CLI `transcribe --raw` and bridge `/v1/dictate?raw=1` bypass formatting.
Old configurations keep it off and profile IDs stay stable. History retains raw
text, original output and up to three previous versions. Explicit recleanup first
shows a preview; accepting it saves without automatic insertion.

Selection cleanup through the menu or macOS Service uses the same cleaner. Its
input and preview stay in RAM without history or changing the last dictation.
Unknown Service origins remain exclusively local without replacement. Replacement
still requires the exact original target and explicit acceptance; activating a
foreign app blocks replacement even after returning. Accessibility offers no
atomic compare-and-write transaction.
