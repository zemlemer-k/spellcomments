-- mod-version:3

-----------------------------------------------------------------------
-- NAME       : spellcomments
-- DESCRIPTION: Plugin for spell checking in c and lua files
-- AUTHOR     : Kirill Gribovskiy
-----------------------------------------------------------------------

-- Include section
local core = require "core"
local style = require "core.style"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
local DocView = require "core.docview"
local Highlighter = require "core.doc.highlighter"
local Doc = require "core.doc"
local RootView = require "core.rootview"
local keymap = require "core.keymap"

config.plugins.spellcomments = common.merge({
    enabled = false,
    underline_color = {255, 0, 0}
    --files = { "%.c$", "%.cpp$", "%.h$", "%.lua$", "%.txt", "%.md" }
}, config.plugins.spellcomments)


local rclick_pos_x, rclick_pos_y = 0, 0

------------------------------------------------------------------------------------------------------------------------------------------------------
-- local functions
------------------------------------------------------------------------------------------------------------------------------------------------------
local function pick_word(from_submenu)
    local line, pos = 0, 0
    local word = nil
    local doc = core.active_view.doc
    local start_pos = 1

    if false == from_submenu then
        line, pos  = doc:get_selection()
    else
        line, pos = core.active_view:resolve_screen_position(rclick_pos_x, rclick_pos_y)
    end

    local searchline = doc.lines[line]

    while start_pos < #searchline do
        local s, e = searchline:ufind("[%a]+", start_pos)
        if nil == s then return end
        local word = searchline:usub(s, e)
        if pos >= s and pos <= e + 1 then return word end
        start_pos = e + 1
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Dictionary
------------------------------------------------------------------------------------------------------------------------------------------------------
local SpellDict =
{
    platform_dictionary_file = nil,
    dictionary = {},
    dictionary_loaded = false,
    word_count = 0,
    user_dictionary_file = USERDIR .. PATHSEP .. "words.txt"
}

function SpellDict:reset()
    self.dictionary = {}
    self.word_count = 0
    self.dictionary_loaded = false
    collectgarbage("step")
end

function SpellDict:load_dict(path)
    if not path then return false end

    local file = io.open(path, "r")
    if not file then
        core.warn(string.format("Warning: dictionary not found - %s", path))
        return false
    end

    local content = file:read("*a")
    file:close()
    core.add_thread(function()
        for word in content:gmatch("[%a]+") do  -- any char, any "-"
            if word ~= "" then
                self.dictionary[word:ulower()] = true
                self.word_count = self.word_count + 1
                if self.word_count % 1001 == 0 then coroutine.yield() end
            end
        end
    end)

    return true
end

function SpellDict:load()
    self:reset()

    if PLATFORM == "Windows" then
        self.platform_dictionary_file = EXEDIR .. "/words.txt"
    else
        self.platform_dictionary_file = "/usr/share/dict/words"
    end

    local success = self:load_dict(self.platform_dictionary_file)
    if not success then
        core.error(string.format("system dictionary not found - %s", self.platform_dictionary_file))
        return false
    end

    if self.user_dictionary_file then
        self:load_dict(self.user_dictionary_file)
    end

    self.dictionary_loaded = true

    core.log_quiet("-- spellcomments: Loading dictionaries done")
    return true
end


function SpellDict:check(word)
    return self.dictionary[word:ulower()] ~= nil
end

function SpellDict:add_word(from_submenu)
   if false == config.plugins.spellcomments.enabled    then return end

   local word = pick_word(from_submenu)
   if nil == word then
      core.warn("spellcomments: Unable to find word")
   end
   word = word:ulower()

   if true == self:check(word) then
      core.warn("spellcomments: word is already in dictionary")
      return
   end

   self.dictionary_loaded = false
   local user_dict = io.open(self.user_dictionary_file, 'a')
   user_dict:write(word.."\n")
   user_dict:close()
   self:load()

   core.log("User dictionary updated")

end

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Spelling
------------------------------------------------------------------------------------------------------------------------------------------------------
local ext_type = {
    regular = "regular",
    c_type = "c_type",
    lua_type = "lua_type",
    md_type = "md_type",
    txt_type = "txt_type"
}

local SpellChecker =
{
    verification_strings = {} -- key {line number, start position}; value - string
}

function SpellChecker:reset()
    self.verification_strings = {}
    collectgarbage("step")
end

function SpellChecker:scan_multiline_code(doc, string_type)

    local start_sign, end_sign
    if     string_type == ext_type.regular  then start_sign =  "[\"']"
    elseif string_type == ext_type.c_type   then start_sign = "/%*"        end_sign = "%*/"
    elseif string_type == ext_type.lua_type then start_sign = "%[=*%["
    else   core.warn("bad scan_multiline_code string type");   return false
    end

    local inside_line = false
    local pos = 1
    local substring
    local start_pos, end_pos, e

    for line_num = 1, #doc.lines do
        local line  = doc.lines[line_num]
        pos = 1
        -- removing esc symbols and line feed
        if string_type == ext_type.regular then
            line = line:ugsub("\\[\"']", "")
            line = line:ugsub("\\%s*$", "")
        end

        while(pos < #line) do
            if not inside_line then
                start_pos, e = line:ufind(start_sign, pos)
                if start_pos then
                    inside_line = true
                    if string_type == ext_type.regular then
                        end_sign = line:usub(start_pos, start_pos)    -- Choosing between chars \" and \'
                    elseif string_type == ext_type.lua_type then
                        local lua_str_start= line:usub(start_pos, e)
                        end_sign = lua_str_start:ugsub("%[", "]")
                    end

                    pos = e + 1
                    end_pos = line:ufind(end_sign, pos)

                    if end_pos then -- multiline comment inside one string
                        inside_line = false
                        pos = end_pos + #end_sign
                    else -- multiline comment in several strings
                        end_pos = #line
                        pos = #line
                    end
                    substring = line:usub(start_pos, end_pos)
                    self.verification_strings[{l = line_num, s = start_pos}] = substring
                else
                    break;
                end
            else --inside comment in multiple comment string
                start_pos = 1
                end_pos = line:ufind(end_sign, pos)
                if end_pos then -- found end in mutilple comment string
                    pos = end_pos + #end_sign
                    inside_line = false
                else  -- next full string comment
                    end_pos = #line
                    pos = #line
                end
                substring = line:usub(start_pos, end_pos)
                self.verification_strings[{l = line_num, s = start_pos}] = substring
            end -- if not inside_line then
        end -- while(pos < #line) do
    end -- for line_num cycle
    return true
end

function SpellChecker:scan_singleline_code(doc, string_type)
    local start_sign
    if     string_type == ext_type.c_type   then start_sign = "//"
    elseif string_type == ext_type.lua_type then start_sign = "%-%-"
    else   core.warn("bad scan_singleline_code string type");   return false
    end

    local start_pos, e
    for line_num = 1, #doc.lines do
        -- doc:set_selection(line_num, 1, line_num, 1)  -- moving to string
        local line  = doc.lines[line_num]
        start_pos, e = line:ufind(start_sign)
        -- Skipping multiline lua comments
        if nil ~= start_pos and string_type == ext_type.lua_type then
            local next_char = line.usub(e + 1, e + 1)
            if next_char == "[" then
                start_pos = nil
            end
        end
        if start_pos then
            local commentsubstring = line:usub(start_pos)
            self.verification_strings[{l = line_num, s = start_pos}] = commentsubstring
        end
    end
    return true
end


function SpellChecker:scan_text(doc, string_type)

    if string_type ~= ext_type.md_type and string_type ~= ext_type.txt_type then
        core.error("bad call of scan_text") return false
    end
    local quote_md_sign = "^%s*>"
    local code_md_block_sign = "^%s*```"
    local inside_quote = false
    local inside_block = false

    for line_num = 1, #doc.lines do
        local line  = doc.lines[line_num]
        local substring
        local start_pos = 1
        if(string_type == ext_type.txt_type) then
            self.verification_strings[{l = line_num, s = start_pos}] = line
        else
            if line:ufind(code_md_block_sign, start_pos) then
                inside_block = not inside_block
            end
            if line:ufind(quote_md_sign, start_pos) then
                inside_quote = true
            else
                inside_quote = false
            end

            if false == inside_quote and false == inside_block then
                while start_pos < #line do
                    local quote_pos = line:ufind("`", start_pos)
                    if nil == quote_pos then
                        self.verification_strings[{l = line_num, s = start_pos}] = line:usub(start_pos, #line)
                        start_pos = #line + 1

                    else
                        substring = line:usub(start_pos, quote_pos)
                        self.verification_strings[{l = line_num, s = start_pos}] = substring
                        start_pos = line:ufind("`", quote_pos + 1)
                        if nil == start_pos then break end
                        start_pos = start_pos + 1
                    end
                end
            end
        end
    end
    return true
end

function SpellChecker:spell_iter(chk_sting)
    local start_shift = 1
    return function()
        while start_shift < #chk_sting do
            local s, e = chk_sting:ufind("[%a]+", start_shift)
            if s then
                start_shift = e + 1
                local word = chk_sting:usub(s, e):ulower()
                return (s - 1), word
            else
                start_shift = start_shift + 1
            end
        end
        return nil
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------------------------------------------------------------------------------------
-- Captue cursor position for menu
local root_view_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
    local res = root_view_on_mouse_pressed(self, button, x, y, clicks)
    if button == "right" then
        rclick_pos_x, rclick_pos_y = x, y
    end
   return res
end

-- Main redraw function
local parent_draw = RootView.draw
function RootView:draw()
    parent_draw(self)

    if not core.active_view:is(DocView)                 then return end
    if false == config.plugins.spellcomments.enabled    then return end
    if false == SpellChecker.dictionary_loaded          then return end

    SpellChecker:reset()

    local filename = core.active_view.doc.filename
    local doc = core.active_view.doc
    local ext = filename:umatch("^.+(%..+)$") or ""
    ext = ext:sub(2):ulower()


    if ext == "lua" then
        assert(SpellChecker:scan_multiline_code(doc, ext_type.lua_type),  "scan multiline code error")
        assert(SpellChecker:scan_singleline_code(doc, ext_type.lua_type), "scan singleline code error")
        assert(SpellChecker:scan_multiline_code(doc, ext_type.regular),   "scan regular strings error")
    elseif ext == "c" or ext == "cpp" or ext == "h" then
        assert(SpellChecker:scan_multiline_code(doc, ext_type.c_type),   "scan_multiline_code error")
        assert(SpellChecker:scan_singleline_code(doc, ext_type.c_type),  "scan singleline code error")
        assert(SpellChecker:scan_multiline_code(doc, ext_type.regular),  "scan regular strings error")
    elseif ext == "md" then
        assert(SpellChecker:scan_text(doc, ext_type.md_type),            "scan markdown strings error")
    elseif ext == "txt" then
        assert(SpellChecker:scan_text(doc, ext_type.txt_type),           "scan text strings error")
    end

    local docview = core.active_view
    local l_top, l_bot = docview:get_visible_line_range()
    local vert_shift = core.active_view:get_line_height() - 2

    for pos, chk_string in pairs(SpellChecker.verification_strings) do
        local line_num = pos.l
        local start_shift = pos.s
        if line_num >= l_top and line_num <= l_bot then
            for pos_shift, word in SpellChecker:spell_iter(chk_string) do
                if false == SpellDict:check(word) then
                    local shift = start_shift + pos_shift
                    local x1, y = docview:get_line_screen_position(line_num, shift)
                    local x2, _ = docview:get_line_screen_position(line_num, shift + #word)
                    y = y + vert_shift
                    renderer.draw_rect(x1, y, x2 - x1, 1, config.plugins.spellcomments.underline_color)
                end -- misspelled word
            end -- words iterator
        end -- line in visible range
    end -- strings iterator
end

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Main plugin setup
------------------------------------------------------------------------------------------------------------------------------------------------------
command.add("core.docview", {
    ["spellcomments:toggle"] = function()
        config.plugins.spellcomments.enabled = not config.plugins.spellcomments.enabled
        core.log("spellcomments: %s", config.plugins.spellcomments.enabled and "on" or "off")
    end,

    ["spellcomments:enable"] = function()
        config.plugins.spellcomments.enabled = true
        core.log("spellcomments on")
    end,

    ["spellcomments:disable"] = function()
        config.plugins.spellcomments.enabled = false
        core.log("spellcomments off")
    end,

    ["spellcomments:add to dictionary"] = function()
        SpellDict:add_word(false)
        -- core.log("adding word to dictionary")
    end,

    ["spellcomments:add to dictionary from submenu"] = function()
        SpellDict:add_word(true)
        -- core.log("adding word to dictionary")
    end


})

local contextmenu = require "plugins.contextmenu"
contextmenu:register("core.docview", {
  contextmenu.DIVIDER,
  { text = "Add To Dictionary", command = "spellcomments:add to dictionary from submenu" }
})

keymap.add {
    ["ctrl+shift+t"] = "spellcomments:toggle",
}

assert(SpellDict:load(), "Failed to load dictionaries")
core.log("SpellChecker loaded")

