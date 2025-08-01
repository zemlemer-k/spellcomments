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
    --files = { "%.c$", "%.cpp$", "%.h$", "%.lua$" }
}, config.plugins.spellcomments )

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
        for word in content:gmatch("[%a%-]+") do  -- any char, any "-"
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

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Spelling
------------------------------------------------------------------------------------------------------------------------------------------------------
local ext_type = {
    regular = "regular",
    c_type = "c_type",
    lua_type = "lua_type"
}

local SpellChecker =
{
    verification_strings = {} -- key {line number, start position}; value - string
}

function SpellChecker:reset()
    self.verification_strings = {}
    collectgarbage("step")
end

function SpellChecker:scan_multiline(doc, string_type)

    local start_sign, end_sign
    if     string_type == ext_type.regular  then start_sign =  "[\"']"
    elseif string_type == ext_type.c_type   then start_sign = "/%*"        end_sign = "%*/"
    elseif string_type == ext_type.lua_type then start_sign = "%[=*%["
    else   core.warn("bad scan_multiline string type");   return false
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
            line = line:gsub("\\[\"']", "")
            line = line:gsub("\\%s*$", "")
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
                --end_pos = line:find(multiline_comment_end, pos, true)
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

function SpellChecker:scan_singleline(doc, string_type)
    local start_sign
    if     string_type == ext_type.c_type   then start_sign = "//"
    elseif string_type == ext_type.lua_type then start_sign = "%-%-"
    else   core.warn("bad scan_multiline string type");   return false
    end

    local start_pos, e
    for line_num = 1, #doc.lines do
        -- doc:set_selection(line_num, 1, line_num, 1)  -- moving to string
        local line  = doc.lines[line_num]
        start_pos, e = line:ufind(start_sign)
        -- Skipping multile lua comments
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
local parent_draw = RootView.draw
function RootView:draw()
    parent_draw(self)

    if false == config.plugins.spellcomments.enabled    then return end
    if not core.active_view:is(DocView)                 then return end
    --if nil == core.active_view.doc.filename             then return end

    local filename = core.active_view.doc.filename
    local doc = core.active_view.doc
    local ext = filename:umatch("^.+(%..+)$") or ""
    ext = ext:sub(2):ulower()

    local file_type = nil
    if ext == "lua"                             then file_type = ext_type.lua_type end
    if ext == "c" or ext == "cpp" or ext == "h" then file_type = ext_type.c_type   end
    if nil == file_type then return end

    SpellChecker:reset()
    assert(SpellChecker:scan_multiline(doc, file_type),  "scan_multiline error")
    assert(SpellChecker:scan_multiline(doc, ext_type.regular),  "scan_multiline error")
    assert(SpellChecker:scan_singleline(doc, file_type), "scan_singleline error")

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
    --config.plugins.spellcomments.enabled = false
end

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Main plugin functions
------------------------------------------------------------------------------------------------------------------------------------------------------
assert(SpellDict:load(), "Failed to load doctionaries")
core.log("SpellChecker loaded")

command.add("core.docview", {
    ["spellcomments:toggle"] = function()
        config.plugins.spellcomments.enabled = not config.plugins.spellcomments.enabled
        core.log("--- spellcomments toggle: %s", config.plugins.spellcomments.enabled and "on" or "off")
    end,

    ["spellcomments:enable"] = function()
        config.plugins.spellcomments.enabled = true
        core.log("--- spellcomments enabled")
    end,

    ["spellcomments:disable"] = function()
        config.plugins.spellcomments.enabled = false
        core.log("--- spellcomments disabled")
    end
})

keymap.add {
    ["ctrl+shift+t"] = "spellcomments:toggle",
}

