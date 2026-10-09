local M = {}
local VIEW = 'ronna-signin'
local state = { open = false, phase = 'email', field = nil, generation = 0 }

local function call(args, stdin, callback)
    return ramp.api.run(require('ronna').command(table.unpack(args)), { stdin = stdin, timeout_ms = 30000 }, function(result)
        if result.cancelled then return end
        if result.code ~= 0 then return callback(nil, (result.stderr or result.error or 'Ronna sign-in failed'):gsub('^Error: ', '')) end
        if result.stdout == '' or args[1] == 'logout' then return callback(true) end
        local ok, value = pcall(ramp.api.json_decode, result.stdout)
        if not ok then return callback(nil, 'Could not read the Ronna response') end
        callback(value)
    end)
end

local function reset()
    state.phase, state.challenge, state.error, state.busy = 'email', nil, nil, false
    state.field = ramp.ui.input(state.email or '')
end

function M.close()
    state.open = false
    state.generation = state.generation + 1
    if state.handle then ramp.api.run_cancel(state.handle); state.handle = nil end
    if state.challenge then
        call({ 'auth', 'cancel' }, ramp.api.json_encode({ challenge = state.challenge, code = '' }), function() end)
    end
    reset()
    ramp.ui.float(VIEW, nil)
end

function M.open()
    if state.open then return end
    reset()
    state.open = true
    ramp.ui.float(VIEW, { anchor = 'center', width = '74%', height = '60%', enter = true })
end

local function submit()
    if state.busy then return end
    local text = state.field:text():match('^%s*(.-)%s*$')
    if text == '' then state.error = 'Enter your ' .. (state.phase == 'email' and 'email address.' or 'six-digit email code.'); return end
    state.error, state.busy = nil, true
    local generation = state.generation
    if state.phase == 'email' then
        state.email = text
        state.handle = call({ 'auth', 'code', text }, nil, function(value, err)
            if generation ~= state.generation then return end
            state.handle, state.busy, state.error = nil, false, err
            if not value then return end
            state.phase, state.challenge = 'code', value.challenge
            state.resend_at, state.expires_at = os.time() + value.retry_after, os.time() + value.expires_in
            state.field = ramp.ui.input()
        end)
    else
        if not text:match('^%d%d%d%d%d%d$') then state.error, state.busy = 'Enter the six-digit code from your email.', false; return end
        state.handle = call({ 'auth', 'verify' }, ramp.api.json_encode({ challenge = state.challenge, code = text }), function(value, err)
            if generation ~= state.generation then return end
            state.handle, state.busy, state.error = nil, false, err
            state.field = ramp.ui.input()
            if not value then return end
            state.challenge = nil
            M.close()
            ramp.api.refresh_sessions()
            ramp.notify('Signed in to Ronna as ' .. value.name, 'info')
        end)
    end
end

function M.setup()
    ramp.ui.register_view(VIEW, {
        render = function(ctx)
            local lines = { 'Sign in to Ronna', '' }
            local prompt
            if state.phase == 'email' then
                lines[#lines + 1] = 'Use the email address your administrator invited.'
                prompt = 'Email address'
            else
                lines[#lines + 1] = 'If ' .. state.email .. ' has access, a code is on its way.'
                lines[#lines + 1] = 'Check your inbox and spam folder. Codes expire in 10 minutes.'
                prompt = 'Email code'
            end
            lines[#lines + 1], lines[#lines + 2] = '', prompt
            local start = #lines
            local wrapped = state.field:wrap(math.max(1, ctx.width - 4))
            for _, line in ipairs(wrapped.rows) do lines[#lines + 1] = line end
            lines[#lines + 1] = ''
            if state.busy then lines[#lines + 1] = state.phase == 'email' and 'Requesting code…' or 'Signing in…' end
            if state.error then
                for _, line in ipairs(ramp.ui.wrap(state.error, math.max(1, ctx.width - 4))) do lines[#lines + 1] = line end
            end
            lines[#lines + 1] = state.phase == 'code' and 'Enter sign in · Ctrl-R request again · Ctrl-B change email · Esc cancel' or 'Enter send code · Esc cancel'
            return { lines = lines, border = true, cursor = ctx.focused and not state.busy and { start + wrapped.cursor.row, wrapped.cursor.col } or nil }
        end,
        key = function(event)
            if event.key == '<Esc>' then M.close()
            elseif event.key == '<Enter>' or event.key == '<CR>' then submit()
            elseif event.key == '<C-b>' and not state.busy then
                if state.challenge then call({ 'auth', 'cancel' }, ramp.api.json_encode({ challenge = state.challenge, code = '' }), function() end) end
                reset()
            elseif event.key == '<C-r>' and state.phase == 'code' and not state.busy then
                if os.time() < state.resend_at then state.error = 'Wait ' .. (state.resend_at - os.time()) .. ' seconds before requesting another code.'
                else reset(); submit() end
            elseif not state.busy then state.field:key(event) end
            return true
        end,
        paste = function(event) if not state.busy then return state.field:paste(event) end end,
    })
    ramp.api.register_command('ronna-login', { desc = 'Sign in to Ronna with an email code', run = M.open })
    ramp.api.register_command('ronna-logout', { desc = 'Sign out of Ronna on this device', run = function()
        call({ 'logout' }, nil, function(_, err)
            if err then return ramp.notify(err, 'error') end
            ramp.api.refresh_sessions()
            ramp.notify('Signed out of Ronna', 'info')
            M.open()
        end)
    end })
    ramp.api.register_command('ronna-account', { desc = 'Show your signed-in Ronna identity', run = function()
        call({ 'auth', 'status', '--json' }, nil, function(value, err)
            if err then M.open(); return end
            ramp.notify('Ronna: ' .. value.name .. ' (' .. value.subject .. ')', 'info')
        end)
    end })
    ramp.api.register_command('ronna-invite', { desc = 'Invite someone to Ronna by email (admins)', args = 'EMAIL [NAME]', run = function(raw)
        local email, name = (raw or ''):match('^%s*(%S+)%s*(.-)%s*$')
        if not email then return ramp.notify('Usage: ronna-invite EMAIL [NAME]', 'warn') end
        local args = { 'auth', 'admin', 'invite', email }
        if name ~= '' then args[#args + 1] = '--name'; args[#args + 1] = name end
        call(args, nil, function(value, err)
            if err then return ramp.notify(err, 'error') end
            ramp.notify('Invitation emailed to ' .. value.email, 'info')
        end)
    end })
    ramp.api.register_command('ronna-revoke', { desc = 'Revoke someone’s Ronna access (admins)', args = 'EMAIL', run = function(raw)
        local email = (raw or ''):match('^%s*(%S+)%s*$')
        if not email then return ramp.notify('Usage: ronna-revoke EMAIL', 'warn') end
        call({ 'auth', 'admin', 'revoke', email }, nil, function(_, err)
            ramp.notify(err or ('Access revoked for ' .. email), err and 'error' or 'info')
        end)
    end })
    call({ 'auth', 'status', '--json' }, nil, function(_, err)
        if err and (err:find('not logged in', 1, true) or err:find('not signed in', 1, true)) then M.open() end
    end)
end

return M
