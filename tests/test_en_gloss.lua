-- Execute from the project directory with Lua 5.4.
local plugin = dofile("lua/en_gloss.lua")
local tested = 0
local function equal(actual, expected, label)
  assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  tested = tested + 1
end

local senses = plugin._test.parse_senses("v. study\tv. learn")
equal(senses[1].text, "study", "first sense")
equal(senses[2].text, "learn", "second sense")
equal(senses[1].pos, "v", "part of speech")
equal(plugin._test.parse_senses("Dr. Smith")[1].text, "Dr. Smith", "preserve non-POS prefix")
equal(plugin._test.parse_senses("swish")[1].text, "swish", "no part of speech")
equal(plugin._test.parse_senses(nil), nil, "missing translation")
equal(plugin._test.clip("English", 9), "English", "short comment")
equal(plugin._test.clip("中文释义123456", 8), "中文释义123…", "UTF8 clipping")

local dict = plugin._test.load_dictionary("en_gloss/glossary-en.tsv", "en_gloss/custom.tsv")
equal(plugin._test.parse_senses(dict["开发"])[1].text, "develop", "real glossary")
equal(plugin._test.parse_senses(dict["开发"])[2].text, "exploit", "real second sense")
equal(plugin._test.parse_senses(dict["你好"])[1].text, "hello", "real greeting")
equal(dict[""], nil, "before first index entry")
equal(dict["zzzz-no-such-entry"], nil, "missing ASCII entry")
equal(dict["这是没有译词的测试条目"], nil, "missing Chinese entry")
-- Check every boundary and every original value against indexed disk lookup.
local rows = 0
for line in io.lines("en_gloss/glossary-en.tsv") do
  if line:sub(1, 1) ~= "#" then
    local word, raw = line:match("^([^\t]+)\t(.+)$")
    assert(dict[word] == raw, "indexed value mismatch: " .. word)
    rows = rows+1
  end
end
equal(rows, 232213, "all original TSV entries readable")
local state = getmetatable(dict)._state
local blocks = 0
for _ in pairs(state.blocks) do blocks = blocks+1 end
equal(blocks <= 8, true, "disk block cache bounded")

local function candidate(text, comment, original)
  local c = {text=text, comment=comment or "", type="phrase", start=0, _end=4}
  c.get_genuine = function() return original or c end
  return c
end
local simplified = candidate("开发")
equal(plugin._test.lookup(candidate("開發", "", simplified), {dictionary=dict})[1].text,
      "develop", "traditional shadow lookup")
equal(plugin._test.lookup(candidate("開發"), {dictionary=dict})[1].text,
      "develop", "traditional lookup after second shadow hides source")
for i=1, 300 do
  plugin._test.lookup(candidate("variant" .. i, "", simplified), {dictionary=dict})
end
local aliases = 0
for _ in pairs(state.aliases) do aliases=aliases+1 end
equal(aliases, 256, "variant lookup cache bounded")

local custom_path = os.tmpname()
local function write_override(text)
  local f = assert(io.open(custom_path, "w"))
  f:write(text); f:close()
end
write_override("学习\tv. custom first\n")
local custom_dict = plugin._test.load_dictionary("en_gloss/glossary-en.tsv", custom_path)
equal(custom_dict["学习"], "v. custom first", "personal override takes priority")
write_override("学习\tv. custom second\n")
plugin._test.load_dictionary("en_gloss/glossary-en.tsv", custom_path)
equal(custom_dict["学习"], "v. custom second", "reinitialization reloads personal dictionary")
local unavailable = plugin._test.load_dictionary(custom_path.."-missing.tsv", custom_path)
equal(unavailable["开发"], nil, "unavailable source fails without raising")
equal(unavailable["学习"], "v. custom second", "personal dictionary usable without main source")
os.remove(custom_path)

local original = candidate("开发", "existing note")
local unmapped = candidate("这是一句词表里没有的测试文本")
local result = {}
_G.yield = function(c) result[#result+1] = c end
_G.ShadowCandidate = function(c, kind, text, comment)
  local new = candidate(text, comment, c)
  new.type = kind
  return new
end
local options = {english_gloss=true, ascii_mode=false}
local env = {dictionary=dict, max_chars=22, show_pos=true, show_second=false,
  engine={context={get_option=function(_, name) return options[name] end}}}
local input = {iter=function()
  local list, i = {original, unmapped}, 0
  return function() i=i+1; return list[i] end
end}
plugin.filter.func(input, env)
equal(result[1].text, original.text, "Chinese text unchanged")
equal(result[1].comment, "existing note · v. develop", "original comment preserved")
equal(original.comment, "existing note", "underlying candidate not mutated")
equal(result[1]:get_genuine(), original, "underlying Phrase retained")
equal(result[2], unmapped, "missing gloss leaves original object")
options.english_gloss = false
result = {}
plugin.filter.func(input, env)
equal(result[1], original, "toggle bypass")
options.english_gloss, options.ascii_mode = true, true
result = {}
plugin.filter.func(input, env)
equal(result[1], original, "English mode bypass")
-- Native French selection is a one-shot request. Lua independently validates
-- every boundary before using it, including the current page and raw caret.
local function french_case(overrides)
  local properties = {fr_gloss_protocol="1", fr_gloss_input="nihkbzj;",
    fr_gloss_caret="8", fr_gloss_page="0", fr_gloss_number="2",
    fr_gloss_candidate="你好", fr_gloss_translation="bonjour"}
  for key, value in pairs(overrides or {}) do properties["fr_gloss_"..key] = value end
  local target = candidate("你好")
  local segment = {start=0, selected_index=0, menu={}, get_candidate_at=function(_, index)
    if index == 1 then return target end
  end}
  local context = {input="nihkbzj;", caret_pos=8,
    composition={back=function() return segment end},
    get_property=function(_, name) return properties[name] or "" end,
    set_property=function(_, name, value) properties[name] = value end,
    get_option=function(_, name) return name == "english_gloss" end,
    has_menu=function() return true end,
    clear=function(self) self.input=""; self.caret_pos=0 end,
    push_input=function(self, value) self.input=self.input..value end}
  local committed
  local environment = {page_size=9, engine={context=context,
    commit_text=function(_, value) committed=value end}}
  local key = {keycode=50, release=function() return false end, ctrl=function() return true end,
    alt=function() return false end, shift=function() return false end, super=function() return false end}
  local handled = plugin.processor.func(key, environment)
  return handled, committed, context, properties
end
local handled, committed, context, properties = french_case()
equal(handled, 1, "French request accepted")
equal(committed, "bonjour", "French text committed")
equal(context.input, "bzj;", "French preserves unconverted suffix")
equal(context.caret_pos, 4, "French restores suffix caret")
equal(properties.fr_gloss_protocol, "", "French one-shot token consumed")
equal(properties.fr_gloss_translation, "", "French one-shot text consumed")
for _, invalid in ipairs({{input="changed"}, {caret="7"}, {page="1"}, {number="1"},
                         {candidate="other"}, {translation=""}, {translation="\0bad"},
                         {translation=string.rep("a",16385)}, {translation="\255"}}) do
  local result, text, after, values = french_case(invalid)
  equal(result, 1, "invalid French request consumed")
  equal(text, nil, "invalid French request never committed")
  equal(after.input, "nihkbzj;", "invalid French request preserves input")
  equal(values.fr_gloss_translation, "", "invalid French request cannot be replayed")
end
print("PASS: " .. tested .. " Lua assertions")
