# quarto-moodlequiz

A Quarto extension for authoring [Moodle](https://moodle.org/) quiz XML
files with full markdown/computational support -- a Quarto port of
[moodlequiz](https://github.com/numbats/moodlequiz), the R Markdown format
this is based on.

Unlike the R package, this extension is **language agnostic**: questions
and their cloze answers are written using Quarto shortcodes, which work the
same way regardless of which computational engine (R, Python, Julia, or no
engine at all) produced the document.

## Installing

```sh
quarto add quarto-quiz/quarto-moodlequiz
```

This installs the extension under `_extensions/moodlequiz/` in your current
project.

## Usage

Set `format: moodlequiz-md` in a document's YAML, organize questions with
headers, and write answers with cloze shortcodes:

```md
---
title: A simple quiz
format: moodlequiz-md
moodlequiz:
  category: my-quiz
---

# Basics

## Where is the best coffee?

Where is the best coffee? {{< cloze-shortanswer "Melbourne" >}}

## Discuss {type=essay}

Discuss your favourite coffee.
```

Then render it:

```sh
quarto render quiz.qmd
```

which produces `quiz.xml`, ready to import into a Moodle question bank
(**Question bank > Import > Moodle XML format**).

See `example/quiz.qmd` for a fuller tour (all four cloze question types,
native Moodle question types, categories), and `example/computed-r.qmd` /
`example/computed-python.qmd` for computed (randomised) answers.

### Document structure

- **H1** headers create a question category (nested by further H1s); set a
  base category for the whole document via the `moodlequiz.category` YAML
  key.
- **H2** headers create a question. A question's type defaults to `cloze`
  if its content contains a cloze shortcode, or `description` otherwise --
  override with `## Heading {type=essay}` (or `multichoice`, `truefalse`,
  `shortanswer`, `numerical`, ... -- any Moodle question type, including
  ones from Moodle plugins). Extra header attributes become question
  options, e.g. `{type=multichoice shuffleanswers=1}`.
- Don't put body text directly under an H1 (before its first H2), or at the
  very top of the file before any heading -- it becomes an unintended,
  unnamed `description` question.
- Question types that need explicit answers (`multichoice`, `truefalse`,
  `matching`, ...) take them as fenced divs, plain markdown, no shortcode
  involved:

  ```md
  ## Which of these is a prime number? {type=multichoice shuffleanswers=1}

  ::: {.answer fraction="100"}
  7
  :::

  ::: {.answer fraction="0"}
  8
  :::
  ```

### Cloze shortcodes

```md
{{< cloze 42 tolerance=0.5 >}}
{{< cloze-shortanswer "Australia" >}}
{{< cloze-singlechoice "Victoria" options="NSW,Victoria,Queensland" >}}
{{< cloze-multichoice "a,g" options="a,F,g,V,K" >}}
{{< cloze-numerical 5.5 tolerance=0.5 >}}
```

`cloze` auto-detects the question type from its answer (numeric -> numerical,
`options=` given -> single/multiple-choice depending on whether the answer
has a comma, otherwise -> short answer).

Static answers need no code at all -- just write the shortcode in markdown.
**Computed** answers (the actual point of a literate-programming quiz tool:
an answer that depends on randomly generated data) are produced by a
language printing this same shortcode text:

- **R**: inline code substitutes as text before shortcodes are expanded, so
  `` `r sprintf("{{< cloze-numerical %f tolerance=0.5 >}}", mean(x))` ``
  works directly -- see `example/computed-r.qmd`.
- **Python/Julia/other Jupyter kernels**: no inline-expression syntax
  exists, so a `#| output: asis` cell prints the shortcode text as its
  output instead -- see `example/computed-python.qmd`.
- **Observable JS** runs client-side, after the document is already
  rendered, so it can't feed a shortcode.

No per-language helper package is required or provided; the cloze-building
logic lives once, in the extension's Lua shortcode implementation.
