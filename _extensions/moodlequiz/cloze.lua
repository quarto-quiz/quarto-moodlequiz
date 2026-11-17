-- cloze.lua
--
-- Language-agnostic Quarto shortcode implementation of the Moodle "cloze"
-- embedded-answer syntax. This is a Lua port of the format-building logic in
-- the moodlequiz R package's cloze_*() functions (see R/cloze.R in
-- https://github.com/numbats/moodlequiz), moved from R into the pandoc/Lua
-- layer so it can be called from *any* Quarto document regardless of which
-- language engine (knitr, Jupyter, Julia, ...) produced it.
--
-- Usage (see the README for the argument reference):
--
--   {{< cloze 42 tolerance=0.5 >}}
--   {{< cloze-shortanswer "Australia" >}}
--   {{< cloze-singlechoice "Victoria" options="NSW,Victoria,Queensland" >}}
--   {{< cloze-multichoice "a,g" options="a,F,g,V,K" >}}
--   {{< cloze-numerical 5.5 tolerance=0.5 >}}
--
-- Static answers can be written directly in markdown (as above). Computed
-- answers are produced by a language's code cell printing this same
-- shortcode text (e.g. via `#| output: asis`, or R's inline `` `r` ``
-- substitution) -- see the example/ directory.
--
-- Error handling note: validation failures below are signalled by *returning*
-- a visible `[[moodlequiz error: ...]]` marker rather than calling Lua's
-- `error()`. Quarto's shortcode engine does not reliably abort on a raised
-- error in this position -- in testing it sometimes logs the error yet still
-- substitutes content from what looks like a stale/retried invocation of the
-- handler, which would let an invalid cloze question through silently. A
-- normal return value has no such ambiguity.

-- ===========================================================================
-- String helpers
-- ===========================================================================

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- Look up a shortcode keyword argument. Quarto represents an *unset* kwarg
-- as an empty pandoc List (truthy, and not `nil`), not as a missing key --
-- so `kwargs.foo` alone can't tell "not given" apart from "given". A
-- provided value always comes through as a plain (possibly empty) Lua
-- string, so we can tell the two apart that way instead.
local function kw(kwargs, key)
  local v = kwargs[key]
  if type(v) == "string" then return v end
  return nil
end

-- Split a delimited string into trimmed parts. Returns {} for nil/"".
local function split(s, sep)
  sep = sep or ","
  local parts = {}
  if s == nil or s == "" then return parts end
  for part in (s .. sep):gmatch("(.-)" .. sep) do
    table.insert(parts, trim(part))
  end
  return parts
end

-- Returns (number, nil) on success, or (nil, errmsg) on failure.
local function to_number(x, default)
  if x == nil then return default, nil end
  local n = tonumber(x)
  if n == nil then
    return nil, "expected a number, got '" .. tostring(x) .. "'"
  end
  return n, nil
end

local function to_bool(x, default)
  if x == nil then return default end
  return x == "true" or x == "1" or x == "yes"
end

-- Format a number the way R's `paste0()`/`as.character()` would for the
-- round percentages cloze options normally use (e.g. 100, not 100.0).
local function format_number(x)
  if x == math.floor(x) then
    return string.format("%d", x)
  end
  return (string.format("%.10g", x))
end

-- ===========================================================================
-- Cloze answer escaping
--
-- Ported byte-for-byte from moodlequiz::escape_answers() (R/cloze.R). Moodle
-- requires \, }, #, / and " to be backslash-escaped inside cloze answers,
-- and (due to a long-standing Moodle bug) a literal `~` must be written as
-- the HTML entity `&#x007e;` instead.
-- See: https://docs.moodle.org/en/Embedded_Answers_(Cloze)_question_type
-- ===========================================================================

local function escape_answer(x)
  x = x:gsub('([}#/"\\])', '\\%1')
  x = x:gsub('~', '&#x007e;')
  return x
end

-- Convert a cloze fragment (plain text that may contain the literal
-- "&#x007e;" marker produced by escape_answer()) into pandoc Inlines.
--
-- We can't just wrap the whole fragment in a single raw-HTML inline (as the
-- R package does with `` `{...}`{=html} ``): Quarto's shortcode engine
-- stringifies a shortcode's raw-HTML result to "" when the shortcode is used
-- inside a code block/span, which would silently drop
-- the entire answer there. Splitting into Str runs (safe: they contain none
-- of HTML's `&<>` special characters, so pandoc's writer round-trips them
-- unchanged in every context, including inside code) plus a single raw
-- inline per `&#x007e;` (needed so that specific entity survives HTML
-- escaping in normal text) gets both contexts right, with one known
-- exception: a literal `~` inside a
-- cloze answer embedded in a code block is dropped rather than preserved.
local function text_to_inlines(text)
  local inlines = pandoc.Inlines({})
  local rest = text
  while true do
    local s, e = rest:find("&#x007e;", 1, true)
    if not s then
      if #rest > 0 then inlines:insert(pandoc.Str(rest)) end
      break
    end
    if s > 1 then inlines:insert(pandoc.Str(rest:sub(1, s - 1))) end
    inlines:insert(pandoc.RawInline("html", "&#x007e;"))
    rest = rest:sub(e + 1)
  end
  return inlines
end

-- Signal a usage error: log it, and return a visible marker in place of the
-- shortcode's output (see the note on error handling at the top of the file).
local function fail(msg)
  io.stderr:write("moodlequiz: " .. msg .. "\n")
  return text_to_inlines("[[moodlequiz error: " .. msg .. "]]")
end

-- ===========================================================================
-- Cloze option formatting
--
-- `options` is an array of {text = <answer text>, weight = <raw weight>}.
-- `outer_weight` is the question's overall mark, used to normalise the raw
-- weights into percentages (matching moodlequiz's `options/pmax(weight,
-- 0.01)*100`). `feedback` is an array of per-option feedback strings (or a
-- single string, reused for every option).
--
-- Returns (text, nil) on success, or (nil, errmsg) on failure.
-- ===========================================================================

local function format_options(options, outer_weight, feedback)
  local divisor = math.max(outer_weight, 0.01)
  local parts = {}
  local has_full_credit = false
  for i, opt in ipairs(options) do
    local pct = (opt.weight / divisor) * 100
    if pct == 100 then has_full_credit = true end
    local fb = feedback[i] or feedback[1] or ""
    table.insert(
      parts,
      "%" .. format_number(pct) .. "%" .. escape_answer(opt.text) .. "#" .. fb
    )
  end
  if not has_full_credit then
    return nil, "at least one option must have full marks (100%); check " ..
      "the `weight` and `options`/`answer` arguments"
  end
  return table.concat(parts, "~"), nil
end

local function max_weight(options)
  local m = 0
  for _, opt in ipairs(options) do
    if opt.weight > m then m = opt.weight end
  end
  return m
end

-- Parse the power-user `options="text=weight,text=weight,..."` syntax used
-- by cloze-shortanswer for multiple/partial-credit accepted answers. An
-- entry with no explicit weight (just "text") defaults to weight 1.
local function parse_weighted_options(s)
  local out = {}
  for _, entry in ipairs(split(s, ",")) do
    local text, w = entry:match("^(.-)=([%d%.]+)$")
    if text then
      table.insert(out, {text = trim(text), weight = tonumber(w)})
    else
      table.insert(out, {text = entry, weight = 1})
    end
  end
  return out
end

-- ===========================================================================
-- cloze-shortanswer
-- ===========================================================================

local function cloze_shortanswer(args, kwargs)
  local options
  local options_arg = kw(kwargs, "options")
  if options_arg then
    options = parse_weighted_options(options_arg)
  else
    local answer = kw(kwargs, "answer") or args[1]
    if not answer then
      return fail("cloze-shortanswer: an `answer` is required")
    end
    options = {{text = answer, weight = 1}}
  end

  local weight, err = to_number(kw(kwargs, "weight"), max_weight(options))
  if err then return fail("cloze-shortanswer: " .. err) end

  local case_sensitive = to_bool(kw(kwargs, "case_sensitive"), false)
  local feedback = {kw(kwargs, "feedback") or ""}

  local options_text
  options_text, err = format_options(options, weight, feedback)
  if err then return fail("cloze-shortanswer: " .. err) end

  local body = "{" .. format_number(weight) .. ":SHORTANSWER" ..
    (case_sensitive and "_C" or "") .. ":" .. options_text .. "}"
  return text_to_inlines(body)
end

-- ===========================================================================
-- cloze-singlechoice / cloze-multichoice
-- ===========================================================================

-- Build the {text, weight} options array for a choice question from
-- `options=` (all selectable choices) and the correct answer(s) (a
-- comma-separated string), mirroring moodlequiz::choices().
-- Returns (options, nil) on success, or (nil, errmsg) on failure.
local function build_choice_options(kwargs, weight, answer)
  local all_options = split(kw(kwargs, "options"))
  if #all_options == 0 then
    return nil, "`options` is required"
  end
  local answers = split(answer)
  if #answers == 0 then
    return nil, "an `answer` is required"
  end
  local opts = {}
  for _, text in ipairs(all_options) do
    local is_answer = false
    for _, a in ipairs(answers) do
      if a == text then is_answer = true end
    end
    table.insert(opts, {text = text, weight = is_answer and weight or 0})
  end
  return opts, nil
end

local function cloze_singlechoice(args, kwargs)
  local weight, err = to_number(kw(kwargs, "weight"), 1)
  if err then return fail("cloze-singlechoice: " .. err) end

  local answer = kw(kwargs, "answer") or args[1]
  local options
  options, err = build_choice_options(kwargs, weight, answer)
  if err then return fail("cloze-singlechoice: " .. err) end

  local type_ = kw(kwargs, "type") or "dropdown"
  local shuffle = to_bool(kw(kwargs, "shuffle"), false)
  local feedback = {kw(kwargs, "feedback") or ""}

  local type_code = ({dropdown = "", vertical = "V", horizontal = "H"})[type_]
  if type_code == nil then
    return fail("cloze-singlechoice: `type` must be dropdown, vertical or horizontal")
  end
  local suffix = (shuffle or type_ ~= "dropdown") and "_" or ""

  local options_text
  options_text, err = format_options(options, weight, feedback)
  if err then return fail("cloze-singlechoice: " .. err) end

  local body = "{" .. format_number(weight) .. ":MULTICHOICE" .. suffix ..
    type_code .. (shuffle and "S" or "") .. ":" .. options_text .. "}"
  return text_to_inlines(body)
end

local function cloze_multichoice(args, kwargs)
  local weight, err = to_number(kw(kwargs, "weight"), 1)
  if err then return fail("cloze-multichoice: " .. err) end

  local answer = kw(kwargs, "answer") or args[1]
  local options
  options, err = build_choice_options(kwargs, weight, answer)
  if err then return fail("cloze-multichoice: " .. err) end

  local type_ = kw(kwargs, "type") or "vertical"
  local shuffle = to_bool(kw(kwargs, "shuffle"), false)
  local feedback = {kw(kwargs, "feedback") or ""}

  local type_code = ({vertical = "", horizontal = "H"})[type_]
  if type_code == nil then
    return fail("cloze-multichoice: `type` must be vertical or horizontal")
  end
  local suffix = (shuffle or type_ ~= "vertical") and "_" or ""

  local options_text
  options_text, err = format_options(options, weight, feedback)
  if err then return fail("cloze-multichoice: " .. err) end

  local body = "{" .. format_number(weight) .. ":MULTIRESPONSE" .. suffix ..
    type_code .. (shuffle and "S" or "") .. ":" .. options_text .. "}"
  return text_to_inlines(body)
end

-- ===========================================================================
-- cloze-numerical
-- ===========================================================================

local function cloze_numerical(args, kwargs)
  local answer, err = to_number(kw(kwargs, "answer") or args[1])
  if err then return fail("cloze-numerical: " .. err) end
  if answer == nil then
    return fail("cloze-numerical: an `answer` is required")
  end

  local weight
  weight, err = to_number(kw(kwargs, "weight"), 1)
  if err then return fail("cloze-numerical: " .. err) end

  local tolerance
  tolerance, err = to_number(kw(kwargs, "tolerance"), 0)
  if err then return fail("cloze-numerical: " .. err) end

  local feedback = kw(kwargs, "feedback") or ""

  local body = "{" .. format_number(weight) .. ":NUMERICAL:=" ..
    string.format("%f", answer) .. ":" .. string.format("%f", tolerance) ..
    "#" .. feedback .. "}"
  return text_to_inlines(body)
end

-- ===========================================================================
-- cloze: automatic type dispatch, mirroring moodlequiz::cloze()
-- ===========================================================================

local function cloze_auto(args, kwargs)
  local answer = kw(kwargs, "answer") or args[1]
  if answer == nil then
    return fail("cloze: an answer is required, e.g. {{< cloze 42 >}}")
  end
  if kw(kwargs, "options") then
    if answer:find(",") then
      return cloze_multichoice(args, kwargs)
    else
      return cloze_singlechoice(args, kwargs)
    end
  elseif tonumber(answer) then
    return cloze_numerical(args, kwargs)
  else
    return cloze_shortanswer(args, kwargs)
  end
end

return {
  ["cloze"] = cloze_auto,
  ["cloze-shortanswer"] = cloze_shortanswer,
  ["cloze-singlechoice"] = cloze_singlechoice,
  ["cloze-multichoice"] = cloze_multichoice,
  ["cloze-numerical"] = cloze_numerical,
}
