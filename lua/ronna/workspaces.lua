local M = {}

local function arguments(raw)
    local words, word, quote, escaped, started = {}, '', nil, false, false
    for index = 1, #raw do
        local char = raw:sub(index, index)
        if escaped then word = word .. char; escaped = false
        elseif char == '\\' and quote ~= "'" then escaped = true; started = true
        elseif quote then
            if char == quote then quote = nil else word = word .. char end
        elseif char == "'" or char == '"' then quote = char; started = true
        elseif char:match('%s') then
            if started then words[#words + 1] = word; word = ''; started = false end
        else word = word .. char; started = true end
    end
    if quote or escaped then ramp.notify('Unclosed quote or escape in command arguments', 'warn'); return nil end
    if started then words[#words + 1] = word end
    return words
end

local function people(members)
    local names = {}
    for subject, role in pairs(members or {}) do names[#names + 1] = subject .. ' (' .. role .. ')' end
    table.sort(names)
    return table.concat(names, ', ')
end

local function describe(value, action)
    if value.active_workspace then
        local names = {}
        for _, workspace in ipairs(value.workspaces or {}) do names[#names + 1] = workspace.name .. ' [' .. workspace.id .. ']' end
        return 'Active workspace: ' .. value.active_workspace .. (#names > 0 and (' · Workspaces: ' .. table.concat(names, ', ')) or '')
    end
    if action == 'resources' then
        local names = {}
        for _, resource in ipairs(value) do names[#names + 1] = resource.name .. ' [' .. resource.id .. '] · read · controlled by ' .. resource.controller end
        return #names > 0 and ('Available resources: ' .. table.concat(names, '; ')) or 'No resources available'
    end
    if value.creator then
        local level = value.workspace_level ~= ramp.api.null and value.workspace_level or nil
        return 'Creator: ' .. value.creator .. ' · Member access: ' .. people(value.members) .. ' · Workspace access: ' .. (level or 'none')
    end
    if value.controller then
        local audience = value.audience or {}
        local names = audience.members or {}
        local who = audience.workspace and 'workspace members' or #names > 0 and table.concat(names, ', ') or 'controller only'
        return value.name .. ' [' .. value.id .. '] · read · controlled by ' .. value.controller .. ' · available to ' .. who
    end
    if value.members then return value.name .. ' [' .. value.id .. '] · Members: ' .. people(value.members) end
    if value.full_name then return value.session_id .. ' can read ' .. value.full_name end
    if value.consequence then return value.consequence end
    if value.revoked then return 'Future repository access revoked. Cloned data and visible outputs remain.' end
    return 'Workspace access updated'
end

local function call(args, callback)
    return ramp.api.run(require('ronna').command('workspace', table.unpack(args)), nil, function(result)
        if result.code ~= 0 then return ramp.notify(result.stderr or result.error or 'Workspace operation failed', 'error') end
        local ok, value = pcall(ramp.api.json_decode, result.stdout)
        if not ok then return ramp.notify('Could not read workspace response', 'error') end
        if callback then callback(value) else ramp.notify(describe(value, args[1]), 'info') end
    end)
end

function M.list(callback) return call({ 'list' }, callback) end
function M.select(id, callback) return call({ 'select', id }, callback) end
function M.resources(id, callback) return call({ 'resources', id }, callback) end
function M.access(session, callback) return call({ 'access', session }, callback) end

function M.setup()
    local actions = {
        { 'workspace-create', 'Create a workspace', 'ID NAME', 'create' },
        { 'workspace-members', 'Show workspace membership and roles', 'WORKSPACE', 'members' },
        { 'workspace-add', 'Add a Ronna identity as a member or membership admin', 'WORKSPACE IDENTITY [--role admin]', 'add' },
        { 'workspace-remove', 'Remove workspace membership and future access', 'WORKSPACE IDENTITY', 'remove' },
        { 'session-access', 'Show session access policy', 'SESSION', 'access' },
        { 'session-share', 'Share session data and its existing capabilities', 'SESSION --level observe|approve|drive|own [--member IDENTITY]', 'share-session' },
        { 'session-unshare', 'Revoke selected member or workspace session access', 'SESSION [--member IDENTITY]', 'revoke-session' },
        { 'resources', 'Show repository capabilities available in a workspace', 'WORKSPACE', 'resources' },
        { 'repository-share', 'Share a repository for automatic access in authorized workspace sessions', 'WORKSPACE CONNECTION REPOSITORY_ID [--member IDENTITY|--all-members]', 'share-repository' },
        { 'resource-sharing', 'Replace resource sharing policy; no audience makes it private', 'WORKSPACE RESOURCE [--member IDENTITY|--all-members]', 'resource-sharing' },
        { 'resource-grant', 'Add repository access beyond the session creator\'s workspace access', 'SESSION RESOURCE', 'grant' },
        { 'resource-revoke', 'Remove an additional grant; inherited workspace access remains', 'SESSION RESOURCE', 'revoke' },
    }
    for _, action in ipairs(actions) do
        ramp.api.register_command(action[1], {
            desc = action[2], args = action[3],
            run = function(raw)
                local args = arguments(raw or '')
                if not args then return end
                table.insert(args, 1, action[4])
                call(args)
                if action[4] == 'share-session' then ramp.notify('Shared sessions expose existing repository data and capabilities. Revocation does not erase clones or visible outputs.', 'warn') end
            end,
        })
    end
    ramp.api.register_command('workspaces', { desc = 'List workspaces and the active workspace', run = function() M.list() end })
    ramp.api.register_command('workspace', {
        desc = 'Select the active workspace for discovery and new sessions', args = 'WORKSPACE',
        run = function(raw)
            local args = arguments(raw or '')
            if not args then return end
            if #args == 0 then return M.list() end
            if #args ~= 1 then return ramp.notify('Usage: workspace WORKSPACE', 'warn') end
            local id = args[1]
            M.select(id, function() ramp.api.refresh_sessions(); ramp.notify('Active workspace: ' .. id, 'info') end)
        end,
    })
end

return M
