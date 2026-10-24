-- English candidate glosses for librime-lua.
-- Copyright (C) 2026 rime-english-gloss contributors
-- SPDX-License-Identifier: GPL-3.0-or-later
-- No network, subprocesses, input logging, or changes to Chinese candidate ranking.

local M = { filter = {}, processor = {} }
local dictionaries = {}
local warned = {}
local pos_tags = { n=true, v=true, phr=true, adj=true, adv=true, int=true,
  pron=true, num=true, conj=true, m=true, prep=true, part=true }

local function warn(message)
  if warned[message] then return end
  warned[message] = true
  if log and log.warning then log.warning("en_gloss: " .. message) end
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_tsv(path, result, optional)
  local file = io.open(path, "r")
  if not file then
    if not optional then warn("cannot open dictionary: " .. path) end
    return false
  end
  local count = 0
  for line in file:lines() do
    line = line:gsub("^\239\187\191", ""):gsub("\r$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local word, senses = line:match("^([^\t]+)\t(.+)$")
      if word and senses and utf8.len(word) and utf8.len(senses) then
        result[word] = senses
        count = count + 1
      end
    end
  end
  file:close()
  return true, count
end

-- Explicit byte ordering matches the index builder regardless of OS locale.
local function byte_less(a, b)
  for i=1, math.min(#a, #b) do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then return x < y end
  end
  return #a < #b
end

local function remember_alias(dict, word, raw)
  local state = getmetatable(dict)._state
  if not state then return end
  if not state.aliases[word] then
    local slot = state.alias_cursor
    local old = state.alias_order[slot]
    if old then state.aliases[old] = nil end
    state.alias_order[slot] = word
    state.alias_cursor = slot % 256 + 1
  end
  state.aliases[word] = raw
end

local function load_dictionary(path, custom_path)
  local cache_key = path .. "\n" .. custom_path
  local dict = dictionaries[cache_key] or {}
  -- Reinitialization on redeployment also reloads personal overrides. Both the
  -- filter and processor keep the same small proxy, never 232k Lua entries.
  local state = {words={}, offsets={}, lengths={}, custom={}, blocks={},
    block_order={}, cursor=1, aliases={}, alias_order={}, alias_cursor=1}
  read_tsv(custom_path, state.custom, true)
  local index = io.open(path:gsub("%.tsv$", ".idx"), "rb")
  local source = io.open(path, "rb")
  local header = index and index:read("*l")
  local expected_size = header and tonumber(header:match("^# en%-gloss%-index%-v1\t%x+\t(%d+)$"))
  local valid = expected_size and source and source:seek("end") == expected_size
  local next_offset = 0
  if valid then
    for line in index:lines() do
      local word, offset, length = line:match("^([^\t]+)\t(%d+)\t(%d+)$")
      offset, length = tonumber(offset), tonumber(length)
      local previous = state.words[#state.words]
      if not word or not utf8.len(word) or offset ~= next_offset or not length
          or length < 1 or length > 65536 or offset+length > expected_size
          or (previous and not byte_less(previous, word)) then
        valid = false
        break
      end
      local i = #state.words+1
      state.words[i], state.offsets[i], state.lengths[i] = word, offset, length
      next_offset = offset+length
    end
    valid = valid and next_offset == expected_size and #state.words > 0
  end
  if index then index:close() end
  if source then source:close() end
  if not valid then
    state.words = {}
    warn("dictionary or sparse index missing/invalid: " .. path)
  end
  setmetatable(dict, {_state=state, __index=function(_, word)
    if state.custom[word] then return state.custom[word] end
    local low, high, selected = 1, #state.words, nil
    while low <= high do
      local middle = math.floor((low+high)/2)
      if byte_less(word, state.words[middle]) then high = middle-1
      else selected, low = middle, middle+1 end
    end
    if not selected then return nil end
    local block = state.blocks[selected]
    if not block then
      local file = io.open(path, "rb")
      if not file then return nil end
      local position = file:seek("set", state.offsets[selected])
      block = position and file:read(state.lengths[selected])
      file:close()
      if not block or #block ~= state.lengths[selected] then return nil end
      block = "\n" .. block
      local old = state.block_order[state.cursor]
      if old then state.blocks[old] = nil end
      state.block_order[state.cursor] = selected
      state.cursor = state.cursor % 8 + 1
      state.blocks[selected] = block
    end
    local _, finish = block:find("\n" .. word .. "\t", 1, true)
    if not finish then return nil end
    local newline = block:find("\n", finish+1, true)
    return block:sub(finish+1, newline and newline-1 or #block)
  end})
  dictionaries[cache_key] = dict
  return dict
end

local function parse_senses(raw)
  if not raw then return nil end
  local result = {}
  for field in raw:gmatch("[^\t]+") do
    field = trim(field)
    local tag, translation = field:match("^([a-z]+)%.%s+(.+)$")
    if not (tag and pos_tags[tag]) then tag, translation = nil, field end
    -- This glossary's optional reading suffix is display metadata, never output.
    translation = trim(translation:match("^([^|]+)") or translation)
    if translation ~= "" then
      result[#result+1] = { text=translation, pos=tag }
    end
    if #result == 2 then break end
  end
  return #result > 0 and result or nil
end

local function clip(s, limit)
  local n = utf8.len(s)
  if not n or n <= limit then return s end
  return s:sub(1, utf8.offset(s, limit) - 1) .. "…"
end

local function init(env)
  local config = env.engine.schema.config
  local dir = rime_api.get_user_data_dir()
  env.dictionary = load_dictionary(dir .. "/en_gloss/glossary-en.tsv",
                                   dir .. "/en_gloss/custom.tsv")
  env.max_chars = math.max(8, math.min(80,
    config:get_int("en_gloss/max_comment_chars") or 22))
  env.show_pos = config:get_bool("en_gloss/show_pos") ~= false
  env.show_second = config:get_bool("en_gloss/show_second") == true
  env.page_size = config:get_int("menu/page_size") or 9
end

local function lookup(candidate, env)
  if not candidate then return nil end
  local raw = env.dictionary[candidate.text]
  -- Shadow/simplifier candidates retain the original simplified Chinese phrase.
  if not raw then
    local genuine = candidate:get_genuine()
    if genuine then raw = env.dictionary[genuine.text] end
  end
  local metatable = getmetatable(env.dictionary)
  if not raw and metatable and metatable._state then
    raw = metatable._state.aliases[candidate.text]
  end
  if raw and metatable and metatable._state then
    -- A second ShadowCandidate can conceal the original simplified spelling.
    -- Remember only recently displayed variants for the English commit action.
    remember_alias(env.dictionary, candidate.text, raw)
  end
  return parse_senses(raw)
end

M.filter.init = init
function M.filter.func(input, env)
  local context = env.engine.context
  local enabled = context:get_option("english_gloss")
              and not context:get_option("ascii_mode")
  for candidate in input:iter() do
    local senses = enabled and lookup(candidate, env)
    if senses then
      local parts = {}
      for i, sense in ipairs(senses) do
        if i == 1 or env.show_second then
          parts[#parts+1] = (env.show_pos and sense.pos and (sense.pos .. ". ") or "")
                           .. sense.text
        end
      end
      local gloss = clip(table.concat(parts, " / "), env.max_chars)
      local comment = candidate.comment or ""
      if comment ~= "" then comment = comment .. " · " end
      -- A shadow preserves the underlying Phrase and Rime's user learning.
      yield(ShadowCandidate(candidate, candidate.type, candidate.text,
                            comment .. gloss, false))
    else
      yield(candidate)
    end
  end
end

local shifted_digits = { [33]=1, [64]=2, [35]=3, [36]=4, [37]=5,
                         [94]=6, [38]=7, [42]=8, [40]=9 }

-- Collect already selected segments before the candidate without discarding
-- punctuation, partially selected text, or input following the caret.
local function prefix_before(context, stop)
  if stop == 0 then return "" end
  local segmentation = context.composition:toSegmentation()
  local parts, position = {}, 0
  for i=0, segmentation.size-1 do
    local segment = segmentation:get_at(i)
    if segment.start >= stop then break end
    if segment._end > stop then return nil end
    if segment.start > position then
      parts[#parts+1] = context.input:sub(position+1, segment.start)
    end
    local selected = segment:get_selected_candidate()
    if selected then
      parts[#parts+1] = selected.text
    elseif not segment:has_tag("phony") then
      parts[#parts+1] = context.input:sub(segment.start+1, segment._end)
    end
    position = segment._end
  end
  if position < stop then parts[#parts+1] = context.input:sub(position+1, stop) end
  return table.concat(parts)
end

local function commit_translation(env, segment, candidate, translation)
  local context = env.engine.context
  local input = context.input
  local start, finish = candidate.start, candidate._end
  if start ~= segment.start or start < 0 or finish <= start or finish > #input then return 1 end
  local prefix = prefix_before(context, start)
  if prefix == nil then return 1 end
  local suffix = input:sub(finish+1)
  local old_caret = context.caret_pos
  env.engine:commit_text(prefix .. translation)
  context:clear()
  if suffix ~= "" then
    context:push_input(suffix)
    context.caret_pos = math.max(0, math.min(#suffix, old_caret-finish))
  end
  return 1
end

local french_properties = { "protocol", "input", "caret", "page", "number", "candidate", "translation" }
local function commit_french(key, env)
  local context = env.engine.context
  if context:get_property("fr_gloss_protocol") ~= "1" then return nil end
  local request = {}
  -- Always consume the one-shot values before validating or committing. No
  -- later key event may reuse a translation from an earlier composition.
  for _, name in ipairs(french_properties) do
    request[name] = context:get_property("fr_gloss_" .. name)
    context:set_property("fr_gloss_" .. name, "")
  end
  if not key:ctrl() or key:alt() or key:shift() or key:super()
      or not context:get_option("english_gloss") or context:get_option("ascii_mode")
      or not context:has_menu() then return 1 end
  local number = key.keycode >= 49 and key.keycode <= 57 and key.keycode-48
  if not number or number > env.page_size or tonumber(request.number) ~= number
      or request.input ~= context.input or tonumber(request.caret) ~= context.caret_pos then return 1 end
  local segment = context.composition:back()
  if not segment or not segment.menu then return 1 end
  local page = math.floor(segment.selected_index / env.page_size)
  if tonumber(request.page) ~= page then return 1 end
  local candidate = segment:get_candidate_at(page * env.page_size + number - 1)
  local translation = request.translation
  if not candidate or candidate.text ~= request.candidate or not translation
      or trim(translation) == "" or #translation > 16384 or translation:find("\0", 1, true)
      or not utf8.len(translation) then return 1 end
  return commit_translation(env, segment, candidate, translation)
end

M.processor.init = init
function M.processor.func(key, env)
  local context = env.engine.context
  if key:release() then return 2 end -- kNoop: let the normal Rime pipeline run.

  local french = commit_french(key, env)
  if french then return french end

  if key:ctrl() and key:shift() and not key:alt() and not key:super()
      and (key.keycode == 101 or key.keycode == 69) then
    context:set_option("english_gloss", not context:get_option("english_gloss"))
    context:refresh_non_confirmed_composition()
    return 1 -- kAccepted
  end

  if not key:alt() or key:ctrl() or key:super()
      or not context:get_option("english_gloss")
      or context:get_option("ascii_mode") or not context:has_menu() then return 2 end

  local number = key.keycode >= 49 and key.keycode <= 57 and (key.keycode-48)
                 or (key:shift() and shifted_digits[key.keycode])
  if not number then return 2 end
  -- While a menu is open, missing translations deliberately do nothing; do not
  -- accidentally produce macOS Option symbols or commit an unrelated candidate.
  if number > env.page_size then return 1 end
  local segment = context.composition:back()
  if not segment or not segment.menu then return 1 end
  local index = math.floor(segment.selected_index / env.page_size) * env.page_size
                + number - 1
  local candidate = segment:get_candidate_at(index)
  local senses = lookup(candidate, env)
  local sense = senses and senses[key:shift() and 2 or 1]
  if not sense then return 1 end

  return commit_translation(env, segment, candidate, sense.text)
end

-- Pure helpers used by the regression tests, not by the Rime configuration.
M._test = { parse_senses=parse_senses, clip=clip, load_dictionary=load_dictionary,
            lookup=lookup, prefix_before=prefix_before, byte_less=byte_less }
return M
