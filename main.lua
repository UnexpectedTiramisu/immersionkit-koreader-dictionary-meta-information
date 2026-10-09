local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local Event = require("ui/event")
local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local RankProvider = require("dict_rankprovider")
local MetaDB = require("meta_db")

local SETTINGS_PROFILE_BY_LANGUAGE = "dictionarymeta_profile_by_language"
local PROFILE_MODULES = {
    "profiles/ja_yomitan",
}

local DictionaryMeta = WidgetContainer:extend{
    name = "dictionarymeta",
    is_doc_only = true,
}

function DictionaryMeta:onDispatcherRegisterActions()
end

function DictionaryMeta:init()
    self:onDispatcherRegisterActions()
    self:installDictionaryHooks()
    self.ui.menu:registerToMainMenu(self)
    self.meta_source_count = 0
    self.meta_buttons = {}
end

function DictionaryMeta:addToMainMenu(menu_items)
    menu_items.dictionarymeta = {
        text = _("Dictionary metadata"),
        sorting_hint = "search_settings",
        sub_item_table_func = function()
            return self:genProfileMenu()
        end,
    }
end

function DictionaryMeta:onWordLookedUp(word, book_title)
    logger.dbg("Word was look up hahaha", word, book_title)

end

function DictionaryMeta:installDictionaryHooks()
    if ReaderDictionary.dictionarymeta_rankprovider_patch_applied then
        return
    end

    local original_showDict = ReaderDictionary.showDict
    ReaderDictionary.showDict = function(dictionary, word, results, boxes, link, dict_close_callback)
        if dictionary.dictsort_rank_provider then
            logger.dbg("DictionaryMeta: rank provider available")
            dictionary.dictsort_rank_provider:fetch(results)
            dictionary.dictionarymeta_sort_original_index = {}
            for index, result in ipairs(results) do
                dictionary.dictionarymeta_sort_original_index[result] = index
            end
            table.sort(results, function(a, b)
                return dictionary:dictionarymetaCompareResults(a, b)
            end)
            dictionary.dictionarymeta_sort_original_index = nil
        end

        local orig_res = original_showDict(dictionary, word, results, boxes, link, dict_close_callback)
        dictionary.ui:handleEvent(Event:new("DictChanged", 1))

        return orig_res
    end

    local original_changeDictionary = DictQuickLookup.changeDictionary
    DictQuickLookup.changeDictionary = function(dict_popup, index, skip_update)
        dict_popup.ui:handleEvent(Event:new("DictChanged", index))
        return original_changeDictionary(dict_popup, index, skip_update)
    end

    ReaderDictionary.dictionarymeta_rankprovider_patch_applied = true
end

function ReaderDictionary:dictionarymetaGetPreferredDictionaryIndex(dict)
    if not self.preferred_dictionaries then
        return nil
    end

    for index, preferred_dict in ipairs(self.preferred_dictionaries) do
        if dict == preferred_dict then
            return index
        end
    end

    return nil
end

function ReaderDictionary:dictionarymetaCompareResults(a, b)
    local a_preferred_index = self:dictionarymetaGetPreferredDictionaryIndex(a.dict)
    local b_preferred_index = self:dictionarymetaGetPreferredDictionaryIndex(b.dict)

    if a_preferred_index ~= b_preferred_index then
        if a_preferred_index and b_preferred_index then
            return a_preferred_index < b_preferred_index
        end
        return a_preferred_index ~= nil
    end

    local a_rank = self.dictsort_rank_provider:get_rank(a)
    local b_rank = self.dictsort_rank_provider:get_rank(b)

    if a_rank ~= b_rank then
        if a_rank and b_rank then
            return a_rank < b_rank
        end
        return a_rank ~= nil
    end

    return self.dictionarymeta_sort_original_index[a] < self.dictionarymeta_sort_original_index[b]
end

function DictionaryMeta:onDictChanged(index)
    if self.ui and self.ui.dictionary and self.ui.dictionary.dict_window then
        local newEntry = self.ui.dictionary.dict_window.results[index]
        self:updateButtons(newEntry)
    end
end

function DictionaryMeta:registerDictButtons()
    self.meta_buttons = {}

    if self.ui and self.ui.dictionary then
        for butc = 1, self.meta_source_count do
            local but = {
                id = "dict_metadata_b" .. tostring(butc),
                menu_text = _("Dict Metadata Slot " .. tostring(butc)),
                text = _("DictMeta B" .. tostring(butc)),
                row_group = "dict_metadata_row",
                source_id = self.meta_source_information.id[butc],
                source_display_name = self.meta_source_information.title[butc],
                show_func = function(dict_popup)
                    return self:hasActiveProfile() and self.meta_buttons[butc] ~= nil
                end,
                callback = function(dict_popup)

                end
            }
            table.insert(self.meta_buttons, but)
            self.ui.dictionary:addToDictButtons(but)
        end
    end
end

function DictionaryMeta:updateButtons(cur_dict_word)
    if not self:hasActiveProfile() then return end

    for butc = 1, self.meta_source_count do
        -- get meta info for this button's associated source
        local cur_button = self.meta_buttons[butc]
        local relevant_meta = ReaderDictionary.dictsort_rank_provider:get_meta_for_source_id(cur_dict_word, cur_button.source_id)

        logger.dbg("Relevant meta for button ", butc, " is ", relevant_meta)

        -- change button caption

        local display_value = self:getMetaDisplayValue(relevant_meta)

        if not display_value then
            cur_button.text = cur_button.source_display_name .. ": -"
        else
            cur_button.text = cur_button.source_display_name .. ": " .. tostring(display_value)
        end

        if self.ui and self.ui.dictionary and self.ui.dictionary.dict_window then
            local button_ref = self.ui.dictionary.dict_window.button_table:getButtonById(cur_button.id)
            if button_ref then
                button_ref:setText(cur_button.text, button_ref.width)
            end
        end
    end
end

function DictionaryMeta:onReaderReady()
    self:setupRankProviderForCurrentDocument()
end

function DictionaryMeta:onCloseDocument()
    self:clearRankProvider()
end

function DictionaryMeta:setupRankProviderForCurrentDocument()
    self:clearRankProvider()

    local lang = self:getDocumentLanguage()
    local profile_id = self:getProfileIdForLanguage(lang)
    local profile = self:loadProfile(profile_id)

    if not profile then
        logger.dbg("DictionaryMeta: no profile for language", lang)
        return
    end

    local meta_db_path = self:getPluginDirectory() .. profile.database.filename
    local metaDB = MetaDB:new({
        db_path = meta_db_path
    })

    ReaderDictionary.dictsort_rank_provider = RankProvider:new({
        meta_db = metaDB,
        profile = profile
    })

    self.active_language = lang
    self.active_profile = profile
    self.meta_db = metaDB
    self.meta_source_information, self.meta_source_count = metaDB:get_meta_source_information()
    logger.dbg("DictionaryMeta: active profile", profile.id, "for language", lang)

    self:registerDictButtons()
end

function DictionaryMeta:clearRankProvider()
    ReaderDictionary.dictsort_rank_provider = nil
    self.active_language = nil
    self.active_profile = nil
    self.meta_db = nil
    self.meta_source_information = nil
    self.meta_source_count = 0
    self.meta_buttons = {}
end

function DictionaryMeta:hasActiveProfile()
    return self.active_profile ~= nil
end

function DictionaryMeta:getPluginDirectory()
    local source = debug.getinfo(1, "S").source
    local lua_file = source:sub(1, 1) == "@" and source:sub(2) or source
    return lua_file:match("^(.*[/\\])") or "./"
end

function DictionaryMeta:getDocumentLanguage()
    local language = self.ui and self.ui.doc_props and self.ui.doc_props.language

    if not language and self.ui and self.ui.document then
        local props = self.ui.document:getProps()
        language = props and props.language
    end

    return self:normalizeLanguage(language)
end

function DictionaryMeta:normalizeLanguage(language)
    if type(language) ~= "string" or language == "" then
        return nil
    end

    language = language:lower():gsub("_", "-")
    return language:match("^([a-z]+)") or language
end

function DictionaryMeta:getProfileIdForLanguage(language)
    if not language then
        return nil
    end

    local profiles_by_language = G_reader_settings:readSetting(SETTINGS_PROFILE_BY_LANGUAGE, {})
    local configured_profile = profiles_by_language[language]

    if configured_profile ~= nil then
        return configured_profile or nil
    end

    local profiles = self:getAvailableProfilesForLanguage(language)
    if #profiles == 1 then
        return profiles[1].id
    end

    return nil
end

function DictionaryMeta:loadProfile(profile_id)
    if not profile_id then
        return nil
    end

    for _, profile in ipairs(self:getAvailableProfiles()) do
        if profile.id == profile_id then
            return profile
        end
    end

    logger.warn("DictionaryMeta: unknown profile", profile_id)
    return nil
end

function DictionaryMeta:getAvailableProfiles()
    if self.available_profiles then
        return self.available_profiles
    end

    self.available_profiles = {}

    for _, module in ipairs(PROFILE_MODULES) do
        local ok, profile = pcall(require, module)
        if ok and profile and profile.id then
            table.insert(self.available_profiles, profile)
        else
            logger.warn("DictionaryMeta: failed to load profile module", module, profile)
        end
    end

    table.sort(self.available_profiles, function(a, b)
        return (a.label or a.id) < (b.label or b.id)
    end)

    return self.available_profiles
end

function DictionaryMeta:getAvailableProfilesForLanguage(language)
    local profiles = {}

    if not language then
        return profiles
    end

    for _, profile in ipairs(self:getAvailableProfiles()) do
        if profile and self:profileSupportsLanguage(profile, language) then
            table.insert(profiles, profile)
        end
    end

    table.sort(profiles, function(a, b)
        return (a.label or a.id) < (b.label or b.id)
    end)

    return profiles
end

function DictionaryMeta:profileSupportsLanguage(profile, language)
    for _, profile_language in ipairs(profile.languages or {}) do
        if self:normalizeLanguage(profile_language) == language then
            return true
        end
    end

    return false
end

function DictionaryMeta:getMetaDisplayValue(meta)
    if not meta or not self.active_profile then
        return nil
    end

    return meta[self.active_profile.database.rank_column]
end

function DictionaryMeta:getProfilesByLanguageSetting()
    local profiles_by_language = G_reader_settings:readSetting(SETTINGS_PROFILE_BY_LANGUAGE)
    if type(profiles_by_language) ~= "table" then
        profiles_by_language = {}
    end

    return profiles_by_language
end

function DictionaryMeta:saveProfileForLanguage(language, profile_id)
    local profiles_by_language = self:getProfilesByLanguageSetting()
    profiles_by_language[language] = profile_id or false
    G_reader_settings:saveSetting(SETTINGS_PROFILE_BY_LANGUAGE, profiles_by_language)
    self:setupRankProviderForCurrentDocument()
end

function DictionaryMeta:genProfileMenu()
    local lang = self:getDocumentLanguage()
    local profiles = self:getAvailableProfilesForLanguage(lang)
    local menu = {
        {
            text = T(_("Current document language: %1"), lang or _("N/A")),
            enabled = false,
        },
    }

    if #profiles == 0 then
        table.insert(menu, {
            text = _("No metadata profiles available"),
            enabled = false,
        })
    else
        for _, profile in ipairs(profiles) do
            local profile_for_menu = profile
            table.insert(menu, {
                text = profile_for_menu.label or profile_for_menu.id,
                checked_func = function()
                    return self:getProfileIdForLanguage(lang) == profile_for_menu.id
                end,
                callback = function()
                    self:saveProfileForLanguage(lang, profile_for_menu.id)
                end,
            })
        end
    end

    table.insert(menu, {
        text = _("Disable metadata for this language"),
        enabled_func = function()
            return lang ~= nil
        end,
        checked_func = function()
            return lang ~= nil and self:getProfilesByLanguageSetting()[lang] == false
        end,
        callback = function()
            self:saveProfileForLanguage(lang, nil)
        end,
    })

    return menu
end

return DictionaryMeta
