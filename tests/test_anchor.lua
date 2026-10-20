local anchor = require("overlai.anchor")
local text = require("overlai.text")

local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

-- Anchor the first occurrence of `quote` in `s`.
local function anchor_on(s, quote, init)
  local a = assert(s:find(quote, init or 1, true), "quote not in text")
  return anchor.from_range(s, a, a + #quote)
end

local function resolved(s, anc)
  local a, b, info = anchor.resolve(s, anc)
  if not a then
    return nil
  end
  return s:sub(a, b - 1), info.exact
end

T["normalize"] = MiniTest.new_set()

T["normalize"]["collapses whitespace runs and maps back"] = function()
  local s = "a  b\n\tc"
  local norm, starts, ends = text.normalize(s)
  eq(norm, "a b c")
  eq(starts, { 1, 2, 4, 5, 7 })
  eq(ends, { 2, 4, 5, 7, 8 })
end

T["normalize"]["handles leading and trailing whitespace"] = function()
  local norm = text.normalize("  x  ")
  eq(norm, " x ")
end

T["positions"] = MiniTest.new_set()

T["positions"]["round-trip offsets and (row, col)"] = function()
  local s = "ab\ncde\n\nf"
  local starts = text.line_starts(s)
  eq(starts, { 1, 4, 8, 9 })
  eq({ text.offset_to_pos(starts, 1) }, { 0, 0 })
  eq({ text.offset_to_pos(starts, 5) }, { 1, 1 })
  eq({ text.offset_to_pos(starts, 8) }, { 2, 0 })
  eq({ text.offset_to_pos(starts, 10) }, { 3, 1 })
  eq(text.pos_to_offset(starts, #s, 1, 1), 5)
  eq(text.pos_to_offset(starts, #s, 1, 99), 7) -- clamps to the line's end
  eq(text.pos_to_offset(starts, #s, 9, 0), #s + 1)
end

T["from_range"] = MiniTest.new_set()

T["from_range"]["records quote, context and line"] = function()
  local s = "one\ntwo three four\nfive"
  local anc = anchor_on(s, "three")
  eq(anc.quote, "three")
  eq(anc.prefix, "one\ntwo ")
  eq(anc.suffix, " four\nfive")
  eq(anc.line, 2)
end

T["from_range"]["limits context to CONTEXT bytes"] = function()
  local s = string.rep("x", 100) .. "Q" .. string.rep("y", 100)
  local anc = anchor_on(s, "Q")
  eq(#anc.prefix, anchor.CONTEXT)
  eq(#anc.suffix, anchor.CONTEXT)
end

T["from_range"]["never splits a UTF-8 character in the context"] = function()
  -- "é" is two bytes; arrange for the context cut to fall inside one.
  local s = string.rep("é", 40) .. "Q" .. string.rep("é", 40)
  local anc = anchor_on(s, "Q")
  -- Every character is two bytes, so whole characters mean even lengths.
  eq(anc.prefix:match("^[\128-\191]"), nil)
  eq(#anc.prefix % 2, 0)
  eq(#anc.suffix % 2, 0)
end

T["resolve"] = MiniTest.new_set()

T["resolve"]["finds an unchanged passage"] = function()
  local s = "The prior times the likelihood gives the posterior."
  eq({ resolved(s, anchor_on(s, "the likelihood")) }, { "the likelihood", true })
end

T["resolve"]["survives re-wrapping"] = function()
  local s = "We multiply the prior by the likelihood and normalize."
  local anc = anchor_on(s, "the likelihood and normalize")
  local wrapped = "We multiply the prior by the\nlikelihood   and\n  normalize."
  eq({ resolved(wrapped, anc) }, { "the\nlikelihood   and\n  normalize", true })
end

T["resolve"]["survives edits elsewhere"] = function()
  local s = "Alpha beta gamma.\n\nDelta epsilon zeta."
  local anc = anchor_on(s, "epsilon")
  local edited = "A new first paragraph.\n\nAlpha beta gamma, rewritten.\n\nDelta epsilon zeta."
  eq({ resolved(edited, anc) }, { "epsilon", true })
end

T["resolve"]["uses context to choose between repeated quotes"] = function()
  local s = "the cat sat. the dog ran. the cat ran."
  local anc = anchor_on(s, "cat", 20) -- the second "cat"
  local a = anchor.resolve(s, anc)
  eq(a, 31)
end

T["resolve"]["uses the line hint when context ties"] = function()
  local s = "same\nsame\nsame"
  local anc = { quote = "same", prefix = "", suffix = "", line = 3 }
  local a = anchor.resolve(s, anc)
  eq(a, 11)
end

T["resolve"]["re-forms around an edited quote from its context"] = function()
  local s = "In short, the posterior is proportional to the prior times the likelihood here."
  local anc = anchor_on(s, "proportional to")
  local edited = "In short, the posterior is roughly equal to the prior times the likelihood here."
  eq({ resolved(edited, anc) }, { "roughly equal to", false })
end

T["resolve"]["returns nil when the passage and its context are gone"] = function()
  local s = "Keep this. Delete this sentence entirely. Keep that."
  local anc = anchor_on(s, "sentence")
  eq(anchor.resolve("Something completely different.", anc), nil)
end

T["resolve"]["returns nil when the quote was deleted outright"] = function()
  local s = "In short, the posterior is proportional to the prior times the likelihood here."
  local anc = anchor_on(s, "proportional to ")
  local edited = "In short, the posterior is the prior times the likelihood here."
  eq(anchor.resolve(edited, anc), nil)
end

T["resolve"]["rejects empty quotes"] = function()
  eq(anchor.resolve("abc", { quote = "", prefix = "", suffix = "" }), nil)
  eq(anchor.resolve("a b", { quote = " ", prefix = "", suffix = "" }), nil)
end

T["resolve"]["handles quotes with surrounding whitespace"] = function()
  local s = "alpha beta gamma"
  local anc = anchor.from_range(s, 6, 12) -- " beta "
  eq(anc.quote, " beta ")
  eq({ resolved(s, anc) }, { " beta ", true })
end

T["resolve"]["works on multi-byte text"] = function()
  local s = "Über die Wahrscheinlichkeit — ein Überblick."
  local anc = anchor_on(s, "Wahrscheinlichkeit — ein")
  eq({ resolved("Prolog.\n" .. s, anc) }, { "Wahrscheinlichkeit — ein", true })
end

T["resolve"]["accepts a prebuilt index"] = function()
  local s = "one two three"
  local idx = anchor.index(s)
  local a, b = anchor.resolve(idx, anchor_on(s, "two"))
  eq(s:sub(a, b - 1), "two")
end

T["find_quote"] = MiniTest.new_set()

T["find_quote"]["finds every match with its line"] = function()
  local s = "a likelihood\nthe likelihood\nlikelihood"
  local r = anchor.find_quote(s, "likelihood")
  eq(#r, 3)
  eq({ r[1].line, r[2].line, r[3].line }, { 1, 2, 3 })
  eq(s:sub(r[2][1], r[2][2] - 1), "likelihood")
end

T["find_quote"]["ignores whitespace differences and trims"] = function()
  local s = "the\nlikelihood   and normalize"
  local r = anchor.find_quote(s, "  the likelihood and\nnormalize ")
  eq(#r, 1)
  eq(s:sub(r[1][1], r[1][2] - 1), "the\nlikelihood   and normalize")
end

return T
