local M = {}

local function report(_, err)
    if err then ramp.notify(err, 'error') end
end

local function failure(result, command)
    if result.error then return result.error end
    if result.timed_out then return 'ronna group ' .. command .. ' timed out' end
    if result.cancelled then return 'ronna group ' .. command .. ' was cancelled' end
    local message = result.stderr:match('^%s*(.-)%s*$'):gsub('^Error:%s*', ''):match('[^\n]*')
    if message == '' then
        return 'ronna group ' .. command .. ' exited with ' .. tostring(result.code or ('signal ' .. result.signal))
    end
    return message
end

local function call(args, cb, stdin)
    cb = cb or report
    local command = require('ronna').command('group', table.unpack(args))
    return ramp.api.run(command, stdin and { stdin = stdin } or nil, function(result)
        if result.code ~= 0 then return cb(nil, failure(result, args[1])) end
        if result.truncated then return cb(nil, 'ronna group ' .. args[1] .. ' printed more than Ramp reads') end
        local ok, value = pcall(ramp.api.json_decode, result.stdout)
        if not ok then return cb(nil, 'ronna group ' .. args[1] .. ' printed something other than JSON') end
        cb(value ~= ramp.api.null and value or nil)
    end)
end

local function flags(args, options, names)
    options = options or {}
    local known = {}
    for _, name in ipairs(names) do known[name] = true end
    for name in pairs(options) do
        if not known[name] then error('unknown option: ' .. tostring(name), 3) end
    end
    for _, name in ipairs(names) do
        local value = options[name]
        if value ~= nil then args[#args + 1] = '--' .. name:gsub('_', '-') .. '=' .. tostring(value) end
    end
    return args
end

local function optional(options, cb)
    if type(options) == 'function' then return nil, options end
    return options, cb
end

local function run(command, options, names, positional, cb, stdin)
    local args = flags({ command }, options, names)
    args[#args + 1] = '--'
    for _, value in ipairs(positional) do args[#args + 1] = value end
    return call(args, cb, stdin)
end

local function page(command, id, options, cb)
    options, cb = optional(options, cb)
    return run(command, options, { 'after', 'limit' }, { id }, cb)
end

function M.list(cb)
    return call({ 'list' }, cb)
end

function M.create(id, description, cb)
    if type(description) == 'function' then description, cb = nil, description end
    local args = { 'create', '--', id }
    if description and description ~= '' then args[#args + 1] = description end
    return call(args, cb)
end

function M.delete(id, cb)
    return call({ 'delete', '--', id }, cb)
end

function M.overview(id, cb)
    return call({ 'browse', '--format=json', '--', id }, cb)
end

function M.join(id, session, cb)
    return call({ 'join', '--', id, session }, cb)
end

function M.leave(id, session, cb)
    if type(session) == 'function' then session, cb = nil, session end
    return call({ 'leave', '--', id, session }, cb)
end

function M.lead(id, session, cb)
    if type(session) == 'function' then session, cb = nil, session end
    if session == nil then return call({ 'lead', '--clear', '--', id }, cb) end
    return call({ 'lead', '--', id, session }, cb)
end

function M.files(id, cb)
    return call({ 'files', '--', id }, cb)
end

function M.cat(id, path, options, cb)
    options, cb = optional(options, cb)
    local args = flags({ 'cat', '--format=json' }, options, { 'revision' })
    for _, value in ipairs({ '--', id, path }) do args[#args + 1] = value end
    return call(args, cb)
end

function M.put(id, path, content, options, cb)
    options, cb = optional(options, cb)
    return run('put', options, { 'base' }, { id, path }, cb, content)
end

function M.rm(id, path, options, cb)
    options, cb = optional(options, cb)
    return run('rm', options, { 'base' }, { id, path }, cb)
end

function M.history(id, path, cb)
    return call({ 'history', '--', id, path }, cb)
end

function M.message(id, text, options, cb)
    options, cb = optional(options, cb)
    return run('message', options, { 'to', 'reply_to' }, { id, text }, cb)
end

function M.messages(id, options, cb)
    return page('messages', id, options, cb)
end

function M.inbox(id, options, cb)
    return page('inbox', id, options, cb)
end

function M.changes(id, options, cb)
    return page('changes', id, options, cb)
end

function M.pause(id, cb)
    return call({ 'pause', '--', id }, cb)
end

function M.resume(id, cb)
    return call({ 'resume', '--', id }, cb)
end

function M.set(id, options, cb)
    return run('set', options, { 'wake_limit', 'member_limit' }, { id }, cb)
end

function M.launch(ids, options, how)
    local launch, params = {}, {}
    for key, value in pairs(options or {}) do launch[key] = value end
    for key, value in pairs(launch.params or {}) do params[key] = value end
    params.groups = type(ids) == 'string' and { ids } or ids
    launch.launcher = launch.launcher or 'ronna'
    launch.params = params
    ramp.api.new_session(launch, how)
end

local PREFIX = 'ronna:'

function M.target(session)
    return PREFIX .. session
end

function M.session_id(listed)
    if type(listed) ~= 'table' or listed.source ~= 'ronna' or type(listed.target) ~= 'string' then return nil end
    if listed.target:sub(1, #PREFIX) ~= PREFIX then return nil end
    return listed.target:sub(#PREFIX + 1)
end

function M.session(member)
    local target = M.target(member)
    for _, session in ipairs(ramp.api.get_sessions()) do
        if session.target == target then return session end
    end
end

function M.memberships(listed)
    local metadata = type(listed) == 'table' and listed.metadata
    local found = type(metadata) == 'table' and metadata.groups
    local memberships = {}
    if type(found) ~= 'table' then return memberships end
    for _, group in ipairs(found) do
        if type(group) == 'string' then
            memberships[#memberships + 1] = { id = group }
        elseif type(group) == 'table' and type(group.id) == 'string' then
            memberships[#memberships + 1] = group
        end
    end
    return memberships
end

return M
