-- question.lua
--
-- Converts the question/category divs produced by header.lua into Moodle
-- XML <question> elements. Ported from moodlequiz's inst/question.lua --
-- pure pandoc-AST manipulation with no R dependency -- with three changes:
--
-- 1. Question/answer text is wrapped in a real `<![CDATA[ ... ]]>` block
--    directly, rather than the `<cdata>`/`</cdata>` placeholder tags the R
--    package emits and then string-replaces in a post-processing step.
--    Quarto's custom-format pipeline has no equivalent post-processing hook,
--    but it turns out unnecessary anyway: raw HTML survives this
--    extension's custom format completely unmangled, `]]>`/`<![CDATA[`
--    included, so we can just write the real thing.
-- 2. Stray Quarto-internal "vault" placeholder divs (class "hidden") are
--    stripped.
-- 3. A question's content is rendered to an HTML *string* right here (via
--    `blocks_to_html`, the same helper the R package already used for
--    `.answer` divs), instead of being left as pandoc blocks for the
--    document's own writer to serialise later. This sidesteps a Quarto
--    behaviour, present only for computational (knitr/Jupyter-engine)
--    documents, that reparses the whole rendered file as HTML5 before this
--    extension's own filters ever get a say -- which silently corrupts a
--    literal `<![CDATA[...]]>` (not a valid HTML5 construct, so an HTML5
--    parser treats it as a "bogus comment"). Pre-rendering to an opaque raw
--    HTML string here means the document's own writer never has to
--    serialise the question's actual content, only pass our string through
--   .

local question_before = [=[
<question type="%s">
<questiontext format="html">
<text><![CDATA[
]=]

local question_after = [=[
]]></text>
</questiontext>
]=]

local question_end = [[
</question>
]]

-- pandoc.write() with no WriterOptions override uses pandoc's own library
-- defaults, not the options this document was actually invoked with (e.g.
-- our format's `wrap: none`) -- so long option values can otherwise come
-- back with a hard line break inserted mid-string, which would corrupt a
-- cloze answer. Pass wrap_text through explicitly to every internal write.
local write_options = {wrap_text = "wrap-none"}

-- Helper: convert blocks to plain text
local function blocks_to_plain(blocks)
  -- stringify: convert blocks to a Pandoc doc and then to plain text
  local doc = pandoc.Pandoc(blocks)
  return pandoc.write(doc, "plain", write_options)
end


-- Helper: convert blocks to rich html text
local function blocks_to_html(blocks)
  local doc = pandoc.Pandoc(blocks)
  return pandoc.write(doc, "html", write_options)
end

local function open_dom_elements(element, kv)
  local attributes = ""
  for key, value in pairs(kv) do
    attributes = attributes .. string.format(' %s="%s"', key, value)
  end

  -- Create the <answer> opening tag
  return "<" .. element .. attributes .. ">"
end

local function answer_block(answers, plaintext)
  plaintext = plaintext ~= false  -- default true

  -- Get the content as a single string
  local content, answer_fmt
  if plaintext then
    content = blocks_to_plain(answers.content)
    answer_fmt = [=[
<text>
%s
</text>
]=]
  else
    content = blocks_to_html(answers.content)
    answer_fmt = [=[
<text><![CDATA[
%s
]]></text>
]=]
  end

  -- New list of blocks we will return
  local out = {}

  -- Construct <answer></answer> tags with attributes
  local answer_open_tag = open_dom_elements("answer", answers.attr.attributes)
  local answer_close_tag = "</answer>"

  ans = answer_open_tag .. string.format(answer_fmt, content) .. answer_close_tag

  table.insert(out, pandoc.RawBlock("html", ans))

  return out
end

function Div (elem)
  if elem.classes:includes("hidden") then
    -- Drop Quarto-internal placeholder/vault divs. These can be inserted
    -- around headers carrying custom attributes (e.g. `{type=essay}`)
    -- before header.lua/question.lua ever see the document, and have no
    -- meaning for Moodle.
    return {}
  end

  if elem.classes[1] == "question" then
    local answers = {}

    -- Walk question content for answer and subquestion divs
    local question_content = elem.content:walk {
      Div = function(el)
        -- Drop stray Quarto placeholder divs nested inside a question too
        if el.classes:includes("hidden") then
          return {}
        end
        -- Check if the div has the class "answer"
        if el.classes[1] == "answer" then
          -- Append the content of the answer div to the answers table
          table.insert(answers, answer_block(el, elem.attributes['type'] == 'truefalse'))

          -- Remove the div from the question content
          return {}
        end
        -- Otherwise, return the element unchanged
        return el
      end
    }

    -- Render the remaining question content to HTML ourselves -- see the
    -- note at the top of this file for why.
    local question_text = string.format(question_before, elem.attributes['type']) ..
      blocks_to_html(question_content) ..
      question_after
    local question = {pandoc.RawBlock('html', question_text)}

    -- Add answers
    if #answers > 0 then
      for _, answer in ipairs(answers) do
        for _, part in ipairs(answer) do
          table.insert(question, part)
        end
      end
    end

    -- Add question attributes
    for k,v in pairs(elem.attributes) do
      if k~='type' then
        if k=='name' then v = string.format([[<text>%s</text>]], v) end
        if k=='generalfeedback' then v = string.format([[<text>%s</text>]], v) end
        if k=='category' then v = string.format([[<text>$course$/%s</text>]], v) end
        table.insert(question, pandoc.RawBlock('html', string.format([[<%s>%s</%s>]], k, v, k)))
      end
    end

    table.insert(question, pandoc.RawBlock('html', question_end))

    return question
  else
    return elem
  end
end
