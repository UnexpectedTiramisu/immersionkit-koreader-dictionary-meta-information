local Profile = {
    -- Unique ID saved in the user's profile selection.
    id = "ja_yomitan",
    -- Name shown in the profile menu.
    label = "Japanese Yomitan frequency",
    -- Document languages supported (case and regional suffixes are ignored).
    languages = { "ja", "jp", "jpn" },
}

Profile.database = {
    -- Local SQLite file, relative to the plugin directory.
    filename = "yomitan_freq.db",
    -- Map returned lookup keys to term_meta columns; all must match exactly.
    lookup_columns = {
        { key = "headword", column = "headword" },
        { key = "reading", column = "reading" },
    },
    -- Numeric rank used for sorting (lower first) and metadata button text.
    rank_column = "value_num",
    -- Extra columns to fetch; these do not currently change button text.
    display_columns = { "value_text" },
}

Profile.dictionary = {}

-- Receives a KOReader dictionary result table, including word (the heading)
-- and dict (the dictionary name). This profile only needs dict_word.word.
-- Example input: { word = "食べる【たべる】", dict = "My dictionary", ... }
-- Return a table containing every key configured in lookup_columns:
-- { headword = "食べる", reading = "たべる" }. Return nil to skip a result.
function Profile.dictionary.to_lookup_key(dict_word)
    -- This profile expects Japanese headings in headword【reading】 form.
    local outside, inside = dict_word.word:match("^(.-)【(.-)】")

    if not outside or not inside then
        -- Without brackets, use the heading for both headword and reading.
        local word = Profile.dictionary.get_first_part(dict_word.word)
        return {
            headword = word,
            reading = word,
        }
    end

    return {
        headword = Profile.dictionary.get_first_part(outside),
        reading = Profile.dictionary.get_first_part(inside),
    }
end

-- Helper for this dictionary heading format, not a required profile function.
-- Keeps the first alternative separated by the Japanese middle dot (・),
-- e.g. "食べる・喰べる" becomes "食べる". Adapt/remove for other formats.
function Profile.dictionary.get_first_part(value)
    local separator = value:find("・", 1, true)
    return separator and value:sub(1, separator - 1) or value
end

return Profile
