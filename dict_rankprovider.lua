local logger = require "logger"
local RankProvider = {}
RankProvider.__index = RankProvider


function RankProvider:new(args)
    local instance = setmetatable({}, RankProvider)

    instance.meta_db = args.meta_db
    instance.profile = args.profile
    instance.database = instance.profile.database
    instance.fields = instance.meta_db:get_fields(instance.database)
    instance.dict_sort_field = instance.database.rank_column
    instance.cache = {}
    
    return instance
end

function RankProvider:fetch(words)
    logger.dbg("RankProvider fetch: ", words)

    local queried_words = {}
    for _, value in ipairs(words) do
        local lookup_key = self.profile.dictionary.to_lookup_key(value)
        
        if lookup_key ~= nil then
            local db_result_for_this_word, nrows = self.meta_db:fetch_batch(lookup_key, self.database)

            logger.dbg("DB Response for ", lookup_key, " is ", db_result_for_this_word)

            table.insert(queried_words, {
                dictionary_orig_word_str = value.word,
                lookup_key = lookup_key,
                dict = value.dict,
                meta_sort_db_response = db_result_for_this_word,
                meta_sort_db_res_nrows = nrows
            })
        end
    end

    self.cache = queried_words
end

function RankProvider:get_rank(word)
    if not self.cache then return 0 end
    logger.dbg("Cache: ", self.cache)
    local entry = self:find_by_property(self.cache, "dictionary_orig_word_str", word.word)
    logger.dbg("get_rank found: ", entry)

    if not entry then return nil end
    if not entry.meta_sort_db_response then return nil end

    local sort_val = entry.meta_sort_db_response[self.dict_sort_field][1]
    logger.dbg("Sort val: ", sort_val)

    return sort_val
end

function RankProvider:get_meta(word)
    return self.cache[word]
end

function RankProvider:get_meta_for_source_id(dict_word, source_id)
    local entry = self:find_by_property(self.cache, "dictionary_orig_word_str", dict_word.word)

    if not entry then return nil end
    if not entry.meta_sort_db_response then return nil end

    local row_idx_for_id = self:find_db_row_by_property(entry.meta_sort_db_response, entry.meta_sort_db_res_nrows, "source_id", source_id)

    if not row_idx_for_id then return nil end

    local row = {}
    for column_name, column_values in pairs(entry.meta_sort_db_response) do
        row[column_name] = column_values[row_idx_for_id]
    end

    -- return entry.meta_sort_db_response.value_num[row_idx_for_id]
    return row
end

function RankProvider:compare(wordA, wordB)
    local aRank = self:get_rank(wordA)
    local bRank = self:get_rank(wordB)

    if aRank and bRank then
        return aRank < bRank
    elseif aRank then
        return true
    elseif bRank then
        return false
    end

    return nil
end

function RankProvider:find_by_property(items, property, wanted)
    for _, item in ipairs(items) do
        if item[property] == wanted then
            return item
        end
    end

    return nil
end

function RankProvider:find_db_row_by_property(result, nrows, property, wanted)
    local column = result[property]

    if column == nil then
        return nil
    end

    for row = 1, nrows do
        if column[row] == wanted then
            return row
        end
    end

    return nil
end

return RankProvider
