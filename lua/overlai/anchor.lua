-- Anchors tie a thread to a passage of text without touching the file.
--
-- An anchor is a text-quote selector in the spirit of the W3C Web Annotation
-- model: the exact quoted text, a little context on each side, and the line it
-- was last seen on.
--
--   { quote = "the likelihood", prefix = "we multiply by ", suffix = " and",
--     line = 42 }
--
-- Resolution finds the quote again in a (possibly edited) text. Matching is
-- whitespace-insensitive, context breaks ties between repeated quotes, and the
-- line hint breaks the remaining ties. If the quote itself was edited, the
-- context on both sides can still bracket the new wording; the anchor then
-- re-forms around whatever text now sits between them.

local text = require("overlai.text")

local M = {}

M.CONTEXT = 32

--- An index caches the normalization of one text, so resolving many anchors
--- against the same text is cheap.
function M.index(s)
  local norm, starts, ends = text.normalize(s)
  return {
    text = s,
    norm = norm,
    starts = starts,
    ends = ends,
    lines = text.line_starts(s),
  }
end

local function as_index(t)
  if type(t) == "string" then
    return M.index(t)
  end
  return t
end

--- Build an anchor for the half-open byte range [a, b) of `s`.
function M.from_range(s, a, b)
  local n = #s
  local ps = math.max(1, a - M.CONTEXT)
  while ps < a and text.is_continuation(s, ps) do
    ps = ps + 1
  end
  local se = math.min(n, b - 1 + M.CONTEXT)
  while se >= b and text.is_continuation(s, se + 1) do
    se = se - 1
  end
  local starts = text.line_starts(s)
  return {
    quote = s:sub(a, b - 1),
    prefix = s:sub(ps, a - 1),
    suffix = s:sub(b, se),
    line = text.line_of(starts, a),
  }
end

-- Length of the common tail of `a` and the text in `norm` ending at `pos`.
local function common_tail(norm, pos, a)
  local n = 0
  local i, j = pos, #a
  while i >= 1 and j >= 1 and norm:byte(i) == a:byte(j) do
    n, i, j = n + 1, i - 1, j - 1
  end
  return n
end

-- Length of the common head of `a` and the text in `norm` starting at `pos`.
local function common_head(norm, pos, a)
  local n = 0
  local i, j = pos, 1
  while i <= #norm and j <= #a and norm:byte(i) == a:byte(j) do
    n, i, j = n + 1, i + 1, j + 1
  end
  return n
end

-- Normalized quote and context, with the space a quote's leading or trailing
-- whitespace shares with its context counted only once.
local function normalized_parts(anchor)
  local q = text.squash(anchor.quote or "")
  local p = text.squash(anchor.prefix or "")
  local s = text.squash(anchor.suffix or "")
  if q:sub(1, 1) == " " and p:sub(-1) == " " then
    p = p:sub(1, -2)
  end
  if q:sub(-1) == " " and s:sub(1, 1) == " " then
    s = s:sub(2)
  end
  return q, p, s
end

--- Every place the normalized string `q` occurs, as normalized offsets.
function M.occurrences(idx, q)
  local found, init = {}, 1
  if q == "" then
    return found
  end
  while true do
    local s = idx.norm:find(q, init, true)
    if not s then
      break
    end
    found[#found + 1] = s
    init = s + 1
  end
  return found
end

-- Original byte range for normalized range [ns, ne] (inclusive).
local function to_original(idx, ns, ne)
  return idx.starts[ns], idx.ends[ne]
end

local function line_distance(idx, off, hint)
  if not hint then
    return 0
  end
  return math.abs(text.line_of(idx.lines, off) - hint)
end

--- Resolve an anchor in a text (a string or an index).
---
--- Returns `a, b, info` for the half-open range [a, b), or nil when the
--- passage cannot be found. `info.exact` is false when the quote itself has
--- changed and the anchor was re-formed from its context.
function M.resolve(t, anchor)
  local idx = as_index(t)
  local q, p, s = normalized_parts(anchor)
  if q:match("^ ?$") then
    return nil
  end

  local best, best_score
  for _, pos in ipairs(M.occurrences(idx, q)) do
    local a = to_original(idx, pos, pos)
    local score = common_tail(idx.norm, pos - 1, p)
      + common_head(idx.norm, pos + #q, s)
      - line_distance(idx, a, anchor.line) / 1e4
    if not best_score or score > best_score then
      best, best_score = pos, score
    end
  end
  if best then
    local a, b = to_original(idx, best, best + #q - 1)
    return a, b, { exact = true }
  end

  -- The quote is gone. Look for the old context on both sides with a
  -- plausibly sized gap between them, and anchor to what is there now.
  if #p < 8 or #s < 8 then
    return nil
  end
  local max_gap = #q * 3 + 40
  local cand, cand_dist
  for _, ppos in ipairs(M.occurrences(idx, p)) do
    local gap_start = ppos + #p
    local spos = idx.norm:find(s, gap_start, true)
    if spos and spos > gap_start and spos - gap_start <= max_gap then
      local a = to_original(idx, gap_start, gap_start)
      local dist = line_distance(idx, a, anchor.line)
      if not cand_dist or dist < cand_dist then
        cand, cand_dist = { gap_start, spos - 1 }, dist
      end
    end
  end
  if not cand then
    return nil
  end
  -- Leave the surrounding spaces out of the re-formed quote.
  local ns, ne = cand[1], cand[2]
  while ns <= ne and idx.norm:byte(ns) == 32 do
    ns = ns + 1
  end
  while ne >= ns and idx.norm:byte(ne) == 32 do
    ne = ne - 1
  end
  if ns > ne then
    return nil
  end
  local a, b = to_original(idx, ns, ne)
  return a, b, { exact = false }
end

--- Find a quote typed by someone (usually an agent) and return the original
--- byte ranges of every match. `quote` is matched whitespace-insensitively.
function M.find_quote(t, quote)
  local idx = as_index(t)
  local q = text.squash(vim.trim(quote))
  local ranges = {}
  for _, pos in ipairs(M.occurrences(idx, q)) do
    local a, b = to_original(idx, pos, pos + #q - 1)
    ranges[#ranges + 1] = { a, b, line = text.line_of(idx.lines, a) }
  end
  return ranges
end

return M
