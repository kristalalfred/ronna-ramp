local M = {}

local OPTIONS = { binary = true, args = true, launch_args = true, default_ui = true, network_mode = true, prewarm_chars = true, runner_picker = true, signin_ui = true }

local function build(config, ...)
    local command = { config.binary }
    for _, list in ipairs({ config.args, { ... } }) do
        for _, arg in ipairs(list) do command[#command + 1] = arg end
    end
    return command
end

local function defaults()
    return { binary = os.getenv('RONNA_BIN') or 'ronna', args = {} }
end

function M.command(...)
    return build(M.config or defaults(), ...)
end

function M.setup(opts)
    if M.config then return M end
    opts = opts or {}
    for key in pairs(opts) do
        if not OPTIONS[key] then error('unknown ronna option: ' .. tostring(key), 2) end
    end
    local config = defaults()
    local prewarm_chars = opts.prewarm_chars
    if prewarm_chars == nil then prewarm_chars = 6 end
    if prewarm_chars ~= false and (type(prewarm_chars) ~= 'number' or prewarm_chars < 1 or prewarm_chars % 1 ~= 0) then
        error('ronna prewarm_chars must be a positive integer or false', 2)
    end
    config.binary = opts.binary or config.binary
    config.args = opts.args or config.args
    local function command(...) return build(config, ...) end
    if opts.network_mode and opts.network_mode ~= 'on' and opts.network_mode ~= 'selected-integrations' then error('invalid ronna network_mode', 2) end
    local launch = command('launch', '--format', 'ramp', '--progress')
    if opts.network_mode then launch[#launch + 1] = '--network-mode'; launch[#launch + 1] = opts.network_mode end
    for _, arg in ipairs(opts.launch_args or {}) do launch[#launch + 1] = arg end

    ramp.api.register_discovery({
        name = 'ronna',
        command = command('discover', '--format', 'ramp', '--all'),
        start = command('resume', '--format', 'ramp', '--progress'),
        prepare = command('resume', '--wake', '--format', 'ramp', '--progress'),
        prewarm_chars = prewarm_chars or nil,
        command_timeout_ms = 240000,
        action_timeout_ms = 600000,
        stop = command('sleep'),
        delete = command('delete'),
        archive = command('archive'),
        unarchive = command('unarchive'),
        timeout_ms = 5000,
    })
    ramp.api.register_launcher({
        name = 'ronna',
        command = launch,
        providers = command('providers', '--format', 'ramp'),
        source = 'ronna',
        timeout_ms = 600000,
        prewarm_chars = prewarm_chars or nil,
    })
    ramp.api.register_launcher({
        name = 'ronna:runner',
        command = command('launch', '--format', 'ramp', '--progress'),
        providers = command('providers', '--format', 'ramp'),
        source = 'ronna',
        timeout_ms = 180000,
    })

    config.default_ui = opts.default_ui ~= false
    M.config = config
    if opts.signin_ui ~= false then require('ronna.auth').setup() end
    require("ronna.workspaces").setup()
    if opts.runner_picker ~= false then require('ronna.runners').setup() end
    if config.default_ui then require('ronna.ui').setup() end
    return M
end

return M
