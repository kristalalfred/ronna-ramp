local M = {}
local VIEW = 'ronna-runners'
local state = { rows = {}, cursor = 1, open = false, loading = false }

local function call(args, callback)
    ramp.api.run(require('ronna').command(table.unpack(args)), nil, function(result)
        if result.code ~= 0 then
            ramp.notify(result.stderr or result.error or 'Runner operation failed', 'error')
            if state.open then M.refresh() end
            return
        end
        local ok, value = pcall(ramp.api.json_decode, result.stdout)
        if not ok then return ramp.notify('Could not read runner response', 'error') end
        callback(value)
    end)
end

local function close()
    state.open = false
    if state.timer then ramp.ui.stop(state.timer); state.timer = nil end
    ramp.ui.float(VIEW, nil)
end

local function launch(runner, directory)
    close()
    ramp.api.new_session({ launcher = 'ronna:runner', cwd = '', params = {
        workspace_id = runner.workspace_id,
        target = { kind = 'runner', runner_id = runner.id, directory_id = directory.id },
    } })
end

local function choose(row)
    if not row then return end
    if row.managed then close(); ramp.api.new_session({ launcher = 'ronna', cwd = '' }); return end
    local runner = row.runner
    if runner.availability ~= 'online' then
        ramp.notify('Runner ' .. runner.availability .. '; bring the selected machine online', 'warn')
        return M.refresh()
    end
    if row.directory then return launch(runner, row.directory) end
    if #runner.directories == 1 then return launch(runner, runner.directories[1]) end
    if #runner.directories == 0 then return ramp.notify('No served directories; add one on the runner', 'warn') end
    state.directory_runner, state.rows, state.cursor = runner, {}, 1
    for _, directory in ipairs(runner.directories) do
        state.rows[#state.rows + 1] = { runner = runner, directory = directory,
            label = directory.name .. ' · ' .. directory.path }
    end
end

function M.refresh()
    if state.loading then return end
    state.loading = true
    ramp.api.run(require('ronna').command('runner', 'list'), nil, function(result)
        state.loading = false
        if result.code ~= 0 then state.error = result.stderr or result.error; return end
        local ok, runners = pcall(ramp.api.json_decode, result.stdout)
        if not ok then state.error = 'Could not read runner inventory'; return end
        state.error, state.directory_runner = nil, nil
        state.rows = { { managed = true, label = 'Managed compute' } }
        table.sort(runners, function(a, b) return a.owner .. '/' .. a.name < b.owner .. '/' .. b.name end)
        for _, runner in ipairs(runners) do
            local names = {}
            for _, directory in ipairs(runner.directories) do names[#names + 1] = directory.name end
            local category = runner.owner == state.subject and 'My runners' or 'Shared runners'
            state.rows[#state.rows + 1] = { runner = runner, label = category .. ' · ' .. runner.owner .. '/' .. runner.name
                .. ' · ' .. runner.workspace_id .. ' · ' .. runner.availability .. ' · ' .. runner.active_sessions .. ' active'
                .. ' · ' .. table.concat(names, ', ') }
        end
        state.cursor = math.max(1, math.min(state.cursor, #state.rows))
        if state.selector then
            local selector = state.selector
            state.selector = nil
            for _, row in ipairs(state.rows) do
                local r = row.runner
                if r and (r.owner .. '/' .. r.name == selector or (r.owner == state.subject and r.name == selector)) then return choose(row) end
            end
            ramp.notify('Runner unavailable in this workspace', 'warn')
        end
    end)
end

function M.open(selector)
    state.open, state.cursor, state.selector = true, 1, selector
    ramp.ui.float(VIEW, { anchor = 'center', width = '90%', height = '70%', enter = true })
    call({ 'auth', 'status', '--json' }, function(identity) state.subject = identity.subject; M.refresh() end)
    M.refresh()
    if state.timer then ramp.ui.stop(state.timer) end
    state.timer = ramp.ui.animate(5000, function() if not state.directory_runner then M.refresh() end end)
end

local function action(verb, workspace, selector)
    local args = { 'runner', verb, selector }
    if verb == 'share' then
        table.insert(args, 1, workspace)
        table.insert(args, 1, '--workspace')
        args[#args + 1] = '--all-members'
        ramp.notify("Members can run code as the runner's OS user, with that user's files, credentials, and network access.", 'warn')
    end
    call(args, function() ramp.api.refresh_sessions(); M.refresh(); ramp.notify('Runner ' .. verb .. ' completed', 'info') end)
end

function M.setup()
    ramp.ui.register_view(VIEW, {
        render = function(ctx)
            local lines = {}
            local height = math.max(1, ctx.height - 5)
            local start = math.max(1, state.cursor - height + 1)
            for index = start, math.min(#state.rows, start + height - 1) do
                lines[#lines + 1] = { { text = (index == state.cursor and ' › ' or '   ') .. state.rows[index].label,
                    hl = index == state.cursor and 'accent' or 'normal' } }
            end
            lines[#lines + 1] = state.error or ''
            lines[#lines + 1] = 'Enter select · j/k move · r refresh · Esc back · q close · :runner-share WORKSPACE OWNER/NAME'
            return { lines = lines, border = true, title = state.directory_runner and 'Remote directory' or 'Launch location' }
        end,
        key = function(event)
            local key = event.key
            if key == 'j' or key == '<Down>' then state.cursor = math.min(#state.rows, state.cursor + 1)
            elseif key == 'k' or key == '<Up>' then state.cursor = math.max(1, state.cursor - 1)
            elseif key == '<Enter>' or key == '<CR>' then choose(state.rows[state.cursor])
            elseif key == 'r' then M.refresh()
            elseif key == ':' then ramp.api.open_commands()
            elseif key == '<Esc>' and state.directory_runner then M.refresh()
            elseif key == '<Esc>' or key == 'q' then close() end
            return true
        end,
    })
    ramp.api.register_command('runners', { desc = 'Choose managed compute, my runners, or shared runners', run = function() M.open() end })
    ramp.api.register_command('runner', { desc = 'Choose a runner and remote directory', args = '[OWNER/NAME]', run = function(raw) M.open(raw and raw:match('%S+')) end })
    for _, verb in ipairs({ 'share', 'unshare', 'stop', 'revoke' }) do
        ramp.api.register_command('runner-' .. verb, { desc = verb .. ' an owned runner', args = verb == 'share' and 'WORKSPACE OWNER/NAME' or 'OWNER/NAME', run = function(raw)
            local args = {}
            for word in (raw or ''):gmatch('%S+') do args[#args + 1] = word end
            local count = verb == 'share' and 2 or 1
            if #args ~= count then return ramp.notify('Usage: runner-' .. verb .. ' ' .. (count == 2 and 'WORKSPACE OWNER/NAME' or 'OWNER/NAME'), 'warn') end
            action(verb, count == 2 and args[1] or nil, args[count])
        end })
    end
end

return M
