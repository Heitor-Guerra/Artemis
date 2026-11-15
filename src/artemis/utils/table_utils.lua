--- Small table and validation helpers shared by Artemis data modules.
--- @module 'artemis.utils.table_utils'

local TableUtils = {}

--- Create a recursive copy of a Lua value, including table keys.
--- @generic T
--- @param value T
--- @return T
function TableUtils.deep_copy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[TableUtils.deep_copy(key)] = TableUtils.deep_copy(item)
    end
    return copy
end

--- Check whether a value is a non-empty string.
--- @param value any
--- @return boolean
function TableUtils.is_non_empty_string(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

--- Validate a dense, one-based array containing only non-empty strings.
--- @param value any
--- @param field_name string
--- @return string[] errors
function TableUtils.validate_string_array(value, field_name)
    local errors = {}
    if type(value) ~= "table" then
        errors[#errors + 1] = string.format("'%s' must be an array of strings.", field_name)
        return errors
    end

    local count = 0
    local highest_index = 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            errors[#errors + 1] = string.format("'%s' must contain only array elements.", field_name)
        else
            count = count + 1
            if key > highest_index then
                highest_index = key
            end
            if not TableUtils.is_non_empty_string(item) then
                errors[#errors + 1] = string.format("Every item in '%s' must be a non-empty string.", field_name)
            end
        end
    end

    if count ~= highest_index then
        errors[#errors + 1] = string.format("'%s' must not be a sparse array.", field_name)
    end
    return errors
end

--- Return sorted string keys from a map.
--- @param value  table
--- @return string[]
function TableUtils.sorted_string_keys(value)
    local keys = {}

    for key in pairs(value) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end

    table.sort(keys)
    return keys
end

--- Check whether a value is a dense, one-based array.
--- @param value  table
--- @return boolean
function TableUtils.is_dense_array(value)
    local count = 0
    local highest_index = 0

    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end

        count = count + 1
        if key > highest_index then
            highest_index = key
        end
    end

    return count == highest_index
end

return TableUtils
