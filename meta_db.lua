local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local MetaDB = {}
MetaDB.__index = MetaDB

function MetaDB:new(args)
    local metadb = setmetatable({}, MetaDB)

    metadb.conn = assert(SQ3.open(args.db_path), "Failed to open database: " .. args.db_path)

    return metadb
end

function MetaDB:fetch_batch(lookup_key, database)
    logger.dbg("Fetching word", lookup_key)

    local fields = self:get_fields(database)
    local where_clauses = {}
    local partition_columns = { "tm.source_id" }
    local bind_values = {}

    for _, lookup_column in ipairs(database.lookup_columns) do
        table.insert(where_clauses, "tm." .. lookup_column.column .. " = ?")
        table.insert(partition_columns, "tm." .. lookup_column.column)
        table.insert(bind_values, lookup_key[lookup_column.key])
    end

    -- in the statement, we can already join with meta_source and sort by value_num and sort_priority so the 
    -- first row returned is already the relevant one for sorting priority
    local batch_statement = assert(self.conn:prepare(string.format([[
SELECT *
FROM (
    SELECT
        %s,
        ms.sort_priority,
        ROW_NUMBER() OVER (
            PARTITION BY %s
            ORDER BY tm.%s ASC
        ) AS row_rank
    FROM term_meta AS tm
    JOIN meta_source AS ms
        ON tm.source_id = ms.id
    WHERE %s
)
WHERE row_rank = 1
ORDER BY sort_priority DESC, %s ASC;
    ]],
        self:prefix_columns("tm", fields),
        table.concat(partition_columns, ", "),
        database.rank_column,
        table.concat(where_clauses, " AND "),
        database.rank_column
    )))

    batch_statement:bind(unpack(bind_values))

    local result, nrows = batch_statement:resultset()

    logger.dbg("Rows fetched: rowcount", nrows, " result ",  result)

    batch_statement:reset()

    return result, nrows
end

function MetaDB:get_fields(database)
    local fields = { "source_id" }
    local seen = { source_id = true }

    for _, lookup_column in ipairs(database.lookup_columns) do
        if not seen[lookup_column.column] then
            table.insert(fields, lookup_column.column)
            seen[lookup_column.column] = true
        end
    end

    if not seen[database.rank_column] then
        table.insert(fields, database.rank_column)
        seen[database.rank_column] = true
    end

    for _, column in ipairs(database.display_columns or {}) do
        if not seen[column] then
            table.insert(fields, column)
            seen[column] = true
        end
    end

    return fields
end

function MetaDB:prefix_columns(prefix, columns)
    local prefixed_columns = {}

    for _, column in ipairs(columns) do
        table.insert(prefixed_columns, prefix .. "." .. column)
    end

    return table.concat(prefixed_columns, ", ")
end

function MetaDB:get_meta_source_information()
    local stmt = assert(self.conn:prepare([[
    SELECT * FROM meta_source
]]))
-- later do config things here as well, i.e. have a user-configurable configuration table and join based on config etc

local result, nrows = stmt:resultset()

stmt:reset()

return result, nrows

end

function MetaDB:make_placeholders(n)
    assert(n >= 1, "expected at least one value")

    local t = {}
    for i = 1, n do
        t[i] = "?"
    end

    return table.concat(t, ", ")
end

function tablelength(T)
  local count = 0
  for _ in pairs(T) do count = count + 1 end
  return count
end

return MetaDB
