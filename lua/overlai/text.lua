-- Text utilities: whitespace normalization with a map back to the original
-- bytes, and conversion between byte offsets and buffer positions.
--
-- Offsets are 1-based byte indices into the whole text (lines joined by
-- "\n"). A range is half-open: [a, b) covers text:sub(a, b - 1).

local M = {}

--- Collapse every run of whitespace to a single space.
---
--- Returns the normalized string plus two arrays indexed by normalized byte:
--- `starts[k]` is the original byte where normalized byte k came from, and
--- `ends[k]` is the original byte just past it (past the whole run, for a
--- collapsed space). Matching on the normalized text makes anchors survive
--- re-wrapping, which prettier and `gq` do to prose all the time.
function M.normalize(s)
  local pieces, starts, ends = {}, {}, {}
  local k, i, n = 0, 1, #s
  while i <= n do
    local _, ws_end = s:find("^%s+", i)
    if ws_end then
      k = k + 1
      pieces[#pieces + 1] = " "
      starts[k], ends[k] = i, ws_end + 1
      i = ws_end + 1
    else
      local next_ws = s:find("%s", i) or (n + 1)
      pieces[#pieces + 1] = s:sub(i, next_ws - 1)
      for j = i, next_ws - 1 do
        k = k + 1
        starts[k], ends[k] = j, j + 1
      end
      i = next_ws
    end
  end
  return table.concat(pieces), starts, ends
end

--- Normalized string only.
function M.squash(s)
  return (s:gsub("%s+", " "))
end

function M.join(lines)
  return table.concat(lines, "\n")
end

function M.is_continuation(s, i)
  local b = s:byte(i)
  return b ~= nil and b >= 0x80 and b < 0xC0
end

--- Line index for a text: `starts[i]` is the offset of line i's first byte.
function M.line_starts(s)
  local starts = { 1 }
  local i = 1
  while true do
    local nl = s:find("\n", i, true)
    if not nl then
      break
    end
    starts[#starts + 1] = nl + 1
    i = nl + 1
  end
  return starts
end

--- Offset -> 0-based (row, col) as used by the extmark API.
function M.offset_to_pos(starts, off)
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= off then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo - 1, off - starts[lo]
end

--- 0-based (row, col) -> offset. Columns past the end of a line clamp to it.
function M.pos_to_offset(starts, text_len, row, col)
  local start = starts[row + 1]
  if not start then
    return text_len + 1
  end
  local next_start = starts[row + 2] or (text_len + 2)
  return math.min(start + col, next_start - 1)
end

--- 1-based line number of an offset.
function M.line_of(starts, off)
  local row = M.offset_to_pos(starts, off)
  return row + 1
end

return M
