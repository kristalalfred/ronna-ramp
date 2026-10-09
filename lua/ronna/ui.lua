local groups = require('ronna.groups')

local M = {}

local VIEW = 'ronna_groups'
local POLL_MS = 15000
local RECENT = 8
local PAGE = 20
local NEAR_LIMIT = 0.8
local VIEWABLE_BYTES = 512 * 1024
local ANNOTATION_CHARS = 200
local HEADING = 'GROUP · '

local LIFECYCLE_HL = { running = 'session_live', starting = 'session_live' }
local DELIVERY = {
    pending = { 'waiting', 'warning' },
    sending = { 'sending', 'accent' },
    delivered = { 'delivered', 'success' },
    uncertain = { 'uncertain', 'warning' },
    failed = { 'failed', 'error' },
    cancelled = { 'cancelled', 'muted' },
}

local state = {
    open = false,
    list = nil,
    error = nil,
    loading = false,
    again = false,
    session = nil,
    marked = 0,
    cursor = 1,
    scroll = 0,
    detail = nil,
    file = nil,
    pick = nil,
    confirm = nil,
    inboxes = {},
    form = nil,
    timer = nil,
}

local listed = nil

local function present(value)
    return value ~= nil and value ~= ramp.api.null
end

local function items(value)
    return type(value) == 'table' and value or {}
end

local function clean(value)
    if not present(value) then return '' end
    return (tostring(value):gsub('%c', ' '))
end

local function first_line(value)
    return clean(present(value) and tostring(value):match('[^\n]*') or '')
end

local function fit(text, width)
    if width <= 0 then return '' end
    local cells = ramp.ui.width(text)
    if cells <= width then return text .. string.rep(' ', width - cells) end
    local kept, used = {}, 0
    for _, code in utf8.codes(text) do
        local char = utf8.char(code)
        local w = ramp.ui.width(char)
        if used + w > width - 1 then break end
        kept[#kept + 1] = char
        used = used + w
    end
    return table.concat(kept) .. '…' .. string.rep(' ', width - 1 - used)
end

local function number(value)
    return math.tointeger(value) or value
end

local function plural(count, noun)
    return number(count) .. ' ' .. noun .. (count == 1 and '' or 's')
end

local function size(bytes)
    if type(bytes) ~= 'number' then return '' end
    if bytes < 1024 then return string.format('%d B', bytes) end
    if bytes < 1024 * 1024 then return string.format('%.1f KB', bytes / 1024) end
    return string.format('%.1f MB', bytes / (1024 * 1024))
end

local function ago(ms)
    if type(ms) ~= 'number' then return '' end
    local seconds = math.max(0, os.time() - math.floor(ms / 1000))
    if seconds < 60 then return 'just now' end
    if seconds < 3600 then return (seconds // 60) .. 'm ago' end
    if seconds < 86400 then return (seconds // 3600) .. 'h ago' end
    return (seconds // 86400) .. 'd ago'
end

local function clock(ms)
    if type(ms) ~= 'number' then return '' end
    local seconds = math.floor(ms / 1000)
    return os.date(os.time() - seconds < 86400 and '%H:%M' or '%d %b', seconds)
end

local function label(session)
    return first_line(session.display_label or session.target)
end

local function listed_sessions()
    if not listed then
        listed = {}
        for _, session in ipairs(ramp.api.get_sessions()) do
            local id = groups.session_id(session)
            if id then listed[id] = session end
        end
    end
    return listed
end

local function session_name(id, name)
    local session = present(id) and listed_sessions()[id]
    if session then return label(session) end
    return first_line(present(name) and name or id)
end

local function person(identity, name, owner)
    if type(identity) == 'table' then
        if identity.type == 'human' and (identity.id == owner or not present(owner)) then return 'you' end
        if identity.type == 'agent' then return session_name(identity.id, name) end
        if identity.type == 'group' then return 'group' end
        if identity.type == 'system' and not present(name) then return 'Ronna' end
    end
    return first_line(present(name) and name or '?')
end

local function member_of(group, session)
    if not session then return false end
    for _, member in ipairs(items(group.members)) do
        if member == session then return true end
    end
    return false
end

local function current_session()
    local now = ramp.api.get_state()
    local sessions = ramp.api.get_sessions()
    if now.screen == 'sessions' then return sessions[now.session_cursor] end
    for _, session in ipairs(sessions) do
        if session.target == now.session_target then return session end
    end
    if now.session_target then
        return {
            target = now.session_target,
            source = now.session_target:match('^([^:]+):'),
            display_label = now.display_label,
        }
    end
end

local function this_session()
    return state.session and groups.session_id(state.session)
end

local function find(id)
    for _, group in ipairs(state.list or {}) do
        if group.id == id then return group end
    end
end

local function overview_of(id)
    local detail = state.detail
    if detail and detail.id == id then return detail.overview end
end

local function paused(id)
    local group = overview_of(id) or find(id)
    return group ~= nil and group.paused == true
end

local function visible()
    local mine, rest = {}, {}
    local session = this_session()
    local filter = state.pick and state.pick.groups
    for _, group in ipairs(state.list or {}) do
        if not filter or filter(group) then
            local rows = member_of(group, session) and mine or rest
            rows[#rows + 1] = group
        end
    end
    for _, group in ipairs(rest) do mine[#mine + 1] = group end
    return mine
end

local function inbox(overview)
    local key = tostring(overview.id) .. ' ' .. tostring(overview.created_ms)
    local feed = state.inboxes[key]
    if not feed then
        feed = { cursor = 0, items = {} }
        state.inboxes[key] = feed
    end
    return feed
end

local function read(fetch, id, into, done)
    if into.busy then return done() end
    into.busy = true
    local function step()
        fetch(id, { after = into.cursor, limit = PAGE }, function(value, err)
            if err or type(value) ~= 'table' then
                into.busy = false
                return done(err)
            end
            local messages = items(value.messages)
            if type(value.total) == 'number' and type(value.cursor) == 'number' and value.total - value.cursor >= RECENT then
                into.items, into.cursor = {}, value.total - RECENT
                return step()
            end
            for _, message in ipairs(messages) do
                into.items[#into.items + 1] = message
                if #into.items > RECENT then table.remove(into.items, 1) end
            end
            local moved = present(value.cursor) and value.cursor ~= into.cursor
            if moved then into.cursor = value.cursor end
            if moved and #messages == PAGE then return step() end
            into.busy = false
            done()
        end)
    end
    step()
end

local function fetch_list()
    if state.loading then
        state.again = true
        return
    end
    state.loading = true
    groups.list(function(list, err)
        state.loading = false
        state.error = err
        if type(list) == 'table' then state.list = list end
        if state.again then
            state.again = false
            fetch_list()
        end
    end)
end

local function fetch_detail()
    local detail = state.detail
    if not detail or detail.pending > 0 then return end
    local id = detail.id
    detail.pending = 1
    local function done(err)
        detail.pending = 0
        detail.error = err
    end
    groups.overview(id, function(overview, err)
        if type(overview) == 'table' then detail.overview = overview end
        if err or not detail.overview then return done(err) end
        read(groups.inbox, id, inbox(detail.overview), done)
    end)
end

local function refresh()
    fetch_list()
    fetch_detail()
end

local function open_detail(id)
    state.detail = { id = id, pending = 0, cursor = 1, scroll = 0, follow = true }
    state.file = nil
    fetch_detail()
end

function M.close()
    if not state.open then return end
    state.open = false
    state.form, state.confirm, state.pick, state.detail, state.file = nil, nil, nil, nil, nil
    if state.timer then ramp.ui.stop(state.timer) end
    state.timer = nil
    ramp.ui.float(VIEW, nil)
end

function M.open(opts)
    opts = opts or {}
    state.session = opts.session or current_session()
    state.cursor, state.scroll = 1, 0
    state.form, state.confirm, state.pick, state.detail, state.file = nil, nil, nil, nil, nil
    if opts.id then open_detail(opts.id) end
    ramp.ui.float(VIEW, { anchor = 'center', width = '80%', height = '86%', enter = true })
    if not state.open then
        state.open = true
        state.timer = ramp.ui.animate(POLL_MS, function() refresh() end)
    end
    fetch_list()
end

local function done(message, after)
    return function(_, err)
        if err then
            ramp.notify(err, 'error')
        else
            ramp.notify(message)
            refresh()
            if after then after() end
        end
    end
end

local function to_member(session)
    return 'agent:' .. session
end

local function recipient_name(to, name)
    if to == 'group' then return 'the group' end
    return session_name(to:match('^agent:(.*)$') or to, name)
end

local function recipients(id, form)
    local overview = overview_of(id)
    local lead = overview and present(overview.lead) and overview.lead or nil
    local list = { { to = 'group', name = 'the group' } }
    if lead then
        list[1].note = 'its lead, ' .. session_name(lead, overview.lead_name) .. ', gets it'
    elseif overview then
        list[1].note = 'it has no lead, so nobody is woken'
    end
    overview = overview or {}
    local seen = false
    for _, member in ipairs(items(overview.members)) do
        list[#list + 1] = {
            to = to_member(member.session),
            name = session_name(member.session, member.name),
            note = member.session == lead and 'the lead' or nil,
        }
        seen = seen or to_member(member.session) == form.to
    end
    if form.to ~= 'group' and not seen then
        list[#list + 1] = { to = form.to, name = recipient_name(form.to, form.name) }
    end
    return list
end

local function recipient(form)
    for _, entry in ipairs(recipients(form.id, form)) do
        if entry.to == form.to then return entry end
    end
    return { to = form.to, name = recipient_name(form.to, form.name) }
end

local function cycle(form, step)
    local list = recipients(form.id, form)
    local index = 1
    for position, entry in ipairs(list) do
        if entry.to == form.to then index = position end
    end
    local entry = list[(index - 1 + step) % #list + 1]
    form.to, form.name = entry.to, entry.name
end

local function send_message(id, text, to, reply_to)
    groups.message(id, text, { to = to, reply_to = reply_to },
        done('Message sent to ' .. recipient_name(to) .. ' in ' .. id))
end

local function toggle_pause(id)
    if paused(id) then
        groups.resume(id, done(id .. ' resumed · held messages go out now'))
    else
        groups.pause(id, done(id .. ' paused · messages wait until you resume it'))
    end
end

local function toggle_lead(id, member, lead)
    local name = session_name(member.session, member.name)
    if member.session == lead then
        groups.lead(id, nil, done(id .. ' has no lead now', ramp.api.refresh_sessions))
    else
        groups.lead(id, member.session, done(name .. ' leads ' .. id .. ' now', ramp.api.refresh_sessions))
    end
end

local function launch(id)
    M.close()
    groups.launch(id)
    ramp.notify('New session for work group ' .. id .. ' · it starts when you send its first prompt')
end

local function join(id, session)
    groups.join(id, session, done(session_name(session) .. ' joined ' .. id, ramp.api.refresh_sessions))
end

local function leave(id, session)
    groups.leave(id, session, done(session_name(session) .. ' left ' .. id, ramp.api.refresh_sessions))
end

local function create(id, description)
    groups.create(id, description, function(_, err)
        if err then return ramp.notify(err, 'error') end
        ramp.notify('Created work group ' .. id)
        fetch_list()
        if state.open and not state.pick then open_detail(id) end
    end)
end

local function delete(id)
    groups.delete(id, function(_, err)
        if err then return ramp.notify(err, 'error') end
        ramp.notify('Deleted work group ' .. id)
        if state.detail and state.detail.id == id then state.detail, state.file = nil, nil end
        refresh()
        ramp.api.refresh_sessions()
    end)
end

local function view_file(id, file)
    local view = { id = id, file = file, scroll = 0, follow = false }
    state.file = view
    if type(file.size) == 'number' and file.size > VIEWABLE_BYTES then
        view.error = clean(file.path) .. ' is ' .. size(file.size) .. ', more than Ramp shows here · ronna group cat '
            .. id .. ' ' .. clean(file.path) .. ' prints it'
        return
    end
    groups.cat(id, file.path, function(value, err)
        if state.file ~= view then return end
        view.error = err
        if type(value) == 'table' then view.value = value end
    end)
end

local function check_id(id)
    if #id > 63 or not id:match('^[%w_][%w._-]*$') then
        return 'A group name has up to 63 letters, digits, dots, dashes and underscores, and does not start with a dot or dash'
    end
end

local FORMS = {
    message = {
        verb = 'send',
        stages = {
            {
                name = 'text',
                prompt = function(form)
                    local entry = recipient(form)
                    local verb = form.reply_to and 'Reply to ' or 'Message to '
                    return verb .. entry.name .. (entry.note and (' · ' .. entry.note) or '')
                end,
            },
        },
        submit = function(form) send_message(form.id, form.values.text, form.to, form.reply_to) end,
    },
    create = {
        verb = 'create',
        stages = {
            { name = 'id', trim = true, check = check_id, prompt = function() return 'Name of the new work group' end },
        },
        submit = function(form) create(form.values.id) end,
    },
}

local function advance(form)
    local stages = FORMS[form.kind].stages
    while stages[form.stage] and form.values[stages[form.stage].name] do form.stage = form.stage + 1 end
    if stages[form.stage] then
        form.field = ramp.ui.input()
        state.form = form
    else
        state.form = nil
        FORMS[form.kind].submit(form)
    end
end

local function start_form(kind, id, extra)
    local form = { kind = kind, id = id, values = {}, stage = 1 }
    for key, value in pairs(extra or {}) do form[key] = value end
    advance(form)
end

local function start_message(id, to, reply_to)
    start_form('message', id, { to = to or 'group', reply_to = reply_to })
end

local function submit_form()
    local form = state.form
    local stage = FORMS[form.kind].stages[form.stage]
    local text = form.field:text()
    if stage.trim then text = text:match('^%s*(.-)%s*$') end
    if not text:find('%S') then
        ramp.notify('Nothing written yet', 'warn')
        return
    end
    local problem = stage.check and stage.check(text)
    if problem then
        ramp.notify(problem, 'warn')
        return
    end
    form.values[stage.name] = text
    advance(form)
end

local function ask(text, verb, yes)
    state.confirm = { text = text, verb = verb, yes = yes }
end

local function pick(spec)
    spec.cursor, spec.scroll = 1, 0
    state.pick = spec
end

local function hint_line(keys)
    local spans = { { text = ' ' } }
    for index, pair in ipairs(keys) do
        if index > 1 then spans[#spans + 1] = { text = ' · ', hl = 'panel_hint' } end
        spans[#spans + 1] = { text = pair[1], hl = 'panel_key' }
        spans[#spans + 1] = { text = ' ' .. pair[2], hl = 'panel_hint' }
    end
    return spans
end

local function heading(lines, text, note)
    lines[#lines + 1] = ''
    local spans = { { text = ' ' .. text, hl = 'panel_section' } }
    if note then spans[#spans + 1] = { text = '  ' .. note, hl = 'panel_note' } end
    lines[#lines + 1] = spans
end

local function row(cells, chosen, width)
    local spans = { { text = chosen and ' › ' or '   ', hl = chosen and 'selected' or 'panel_marker' } }
    for _, cell in ipairs(cells) do
        spans[#spans + 1] = { text = cell[1] .. ' ', hl = chosen and 'selected' or cell[2] }
    end
    if chosen then spans[#spans + 1] = { text = string.rep(' ', width), hl = 'selected' } end
    return spans
end

local function empty(lines, text, hl)
    lines[#lines + 1] = { { text = ' ' .. text, hl = hl or 'panel_empty' } }
    return lines, nil
end

local function note(lines, text)
    lines[#lines + 1] = { { text = '   ' .. text, hl = 'panel_empty' } }
end

local function lead_text(group)
    if not present(group.lead) then return 'no lead' end
    return 'lead ' .. session_name(group.lead, group.lead_name)
end

local function list_lines(width)
    local lines, rows = {}, visible()
    if state.error then
        lines[#lines + 1] = { { text = ' ' .. first_line(state.error), hl = 'error' } }
    end
    if not state.list then return empty(lines, 'Loading work groups') end
    if #rows == 0 then
        return empty(lines, state.pick and state.pick.empty or 'No work groups yet · n creates one')
    end
    local owner = state.pick or state
    owner.cursor = math.max(1, math.min(owner.cursor, #rows))
    local session, selected = this_session(), nil
    state.marked = 0
    for index, group in ipairs(rows) do
        local mine = member_of(group, session)
        if mine then state.marked = state.marked + 1 end
        local chosen = index == owner.cursor
        if chosen then selected = #lines + 1 end
        lines[#lines + 1] = row({
            { mine and '●' or ' ', 'accent' },
            { fit(clean(group.id), 20), 'panel_value' },
            { fit(plural(#items(group.members), 'member'), 10), 'panel_label' },
            { fit(lead_text(group), 24), 'panel_label' },
            { fit(group.paused == true and 'paused' or '', 6), 'warning' },
            { first_line(group.description), 'muted' },
        }, chosen, width)
    end
    return lines, selected
end

local function session_lines(width)
    local owner = state.pick
    owner.rows = owner.sessions()
    if #owner.rows == 0 then return empty({}, owner.empty) end
    owner.cursor = math.max(1, math.min(owner.cursor, #owner.rows))
    local lines, selected = {}, nil
    for index, session in ipairs(owner.rows) do
        local lifecycle = type(session.metadata) == 'table' and clean(session.metadata.lifecycle) or ''
        local chosen = index == owner.cursor
        if chosen then selected = #lines + 1 end
        lines[#lines + 1] = row({
            { fit(label(session), 32), 'panel_value' },
            { fit(lifecycle, 10), LIFECYCLE_HL[lifecycle] or 'muted' },
            { groups.session_id(session), 'panel_note' },
        }, chosen, width)
    end
    return lines, selected
end

local function delivery(message)
    local sent = message.delivery
    if type(sent) ~= 'table' then
        if type(message.recipient) == 'table' and message.recipient.type == 'group' then return 'posted', 'muted' end
        return nil
    end
    if present(sent.held) then return 'held: ' .. first_line(sent.held), 'warning' end
    local status = DELIVERY[sent.status] or { clean(sent.status), 'muted' }
    local text = status[1]
    if sent.status == 'delivered' and type(message.recipient) == 'table' and message.recipient.type == 'group' then
        text = 'delivered to ' .. session_name(sent.session, sent.name)
    elseif sent.status == 'failed' and present(sent.detail) then
        text = 'failed: ' .. first_line(sent.detail)
    end
    return text, status[2]
end

local function message_cells(message, owner, room)
    local from = person(message.sender, message.sender_name, owner)
    local to = person(message.recipient, message.recipient_name, owner)
    local status, hl = delivery(message)
    local when = fit(clock(message.at_ms), 6)
    local names = from .. ' → ' .. to .. ':'
    local used = ramp.ui.width(when) + ramp.ui.width(names) + 2
    local tail = status and ramp.ui.width(status) + 1 or 0
    local cells = {
        { when, 'panel_note' },
        { names, 'panel_label' },
        { fit(first_line(message.text), math.max(12, room - used - tail - 1)), 'panel_value' },
    }
    if status then cells[#cells + 1] = { status, hl } end
    return cells
end

local function selectable(detail)
    local overview = detail.overview
    local rows = {}
    for _, member in ipairs(items(overview.members)) do rows[#rows + 1] = { kind = 'member', item = member } end
    for _, file in ipairs(items(overview.files)) do rows[#rows + 1] = { kind = 'file', item = file } end
    local feed = inbox(overview).items
    for index = #feed, 1, -1 do rows[#rows + 1] = { kind = 'message', item = feed[index] } end
    return rows
end

local function header_lines(lines, id, overview)
    local title = { { text = ' ' .. clean(present(overview.id) and overview.id or id), hl = 'heading' } }
    if present(overview.description) and overview.description ~= '' then
        title[#title + 1] = { text = '  ' .. first_line(overview.description), hl = 'panel_value' }
    end
    lines[#lines + 1] = title
    local lead = present(overview.lead) and overview.lead or nil
    lines[#lines + 1] = { {
        text = lead and (' Lead: ' .. session_name(lead, overview.lead_name) .. ' · messages to the group go to it')
            or ' No lead · messages to the group are posted without waking anyone',
        hl = 'panel_label',
    } }
    if overview.paused == true then
        lines[#lines + 1] = { { text = ' Paused · nothing is delivered until you resume it with p', hl = 'warning' } }
    end
    local used, limit = overview.wakes_used, overview.wake_limit
    if type(used) == 'number' and type(limit) == 'number' and (overview.paused == true or used >= limit * NEAR_LIMIT) then
        local counts = number(used) .. ' of ' .. number(limit)
        if used >= limit then
            lines[#lines + 1] = { {
                text = ' Wake-up limit reached: ' .. counts .. ' in the last hour · deliveries wait until earlier ones are an hour old',
                hl = 'warning',
            } }
        else
            lines[#lines + 1] = { { text = ' Wake-ups in the last hour: ' .. counts, hl = 'panel_note' } }
        end
    end
end

local function detail_lines(width)
    local detail = state.detail
    local lines = {}
    if detail.error then
        lines[#lines + 1] = { { text = ' ' .. first_line(detail.error), hl = 'error' } }
    end
    local overview = detail.overview
    if not overview then return empty(lines, 'Loading ' .. detail.id) end
    detail.rows = selectable(detail)
    detail.cursor = math.max(1, math.min(detail.cursor, #detail.rows))
    local owner = overview.owner
    local lead = present(overview.lead) and overview.lead or nil
    local count, selected = 0, nil
    local function choice(cells)
        count = count + 1
        local chosen = count == detail.cursor
        if chosen then selected = #lines + 1 end
        lines[#lines + 1] = row(cells, chosen, width)
    end

    header_lines(lines, detail.id, overview)

    local members = items(overview.members)
    heading(lines, 'Members', #members .. '')
    if #members == 0 then note(lines, 'No members yet · s starts a session in the group · a adds one of yours') end
    for _, member in ipairs(members) do
        local lifecycle = present(member.lifecycle) and clean(member.lifecycle) or 'gone'
        choice({
            { fit(member.session == lead and 'lead' or '', 4), 'accent' },
            { fit(session_name(member.session, member.name), 32), 'panel_value' },
            { fit(lifecycle, 10), LIFECYCLE_HL[lifecycle] or 'muted' },
            { member.busy == true and 'busy' or (member.archived == true and 'archived' or ''), 'warning' },
        })
    end

    local files = items(overview.files)
    heading(lines, 'Files', #files .. '')
    if #files == 0 then note(lines, 'No files yet') end
    for _, file in ipairs(files) do
        choice({
            { fit(clean(file.path), 32), 'panel_value' },
            { fit(size(file.size), 9), 'panel_note' },
            { fit('by ' .. person(file.author, file.author_name, owner), 24), 'panel_label' },
            { ago(file.updated_ms), 'panel_note' },
        })
    end
    if type(overview.files_total) == 'number' and overview.files_total > #files then
        note(lines, 'and ' .. number(overview.files_total - #files) .. ' more · ronna group files ' .. clean(detail.id) .. ' lists them')
    end

    local held = items(overview.held)
    if #held > 0 then
        local count = type(overview.held_total) == 'number' and overview.held_total or #held
        heading(lines, 'Held', number(count) .. ' · each goes out once its reason clears')
        local texts = {}
        for _, message in ipairs(items(overview.messages)) do texts[message.id] = message.text end
        for _, hold in ipairs(held) do
            local text = texts[hold.message]
            lines[#lines + 1] = row({
                { 'for ' .. session_name(hold.session, hold.name) .. ':', 'panel_label' },
                { first_line(hold.reason), 'warning' },
                { text and ('· ' .. first_line(text)) or '', 'muted' },
            }, false, width)
        end
    end

    local feed = inbox(overview).items
    heading(lines, 'Inbox', 'messages to you')
    if #feed == 0 then note(lines, 'Nothing for you yet') end
    for index = #feed, 1, -1 do choice(message_cells(feed[index], owner, width - 3)) end

    local messages = items(overview.messages)
    heading(lines, 'Messages', #messages > 0 and 'newest first' or nil)
    if #messages == 0 then note(lines, 'No messages yet · m sends one') end
    for index = #messages, 1, -1 do
        lines[#lines + 1] = row(message_cells(messages[index], owner, width - 3), false, width)
    end
    return lines, selected
end

local function file_lines(width)
    local view = state.file
    local file = view.file
    if view.cache and view.cache.width == width then return view.cache.lines, nil end
    local overview = overview_of(view.id) or {}
    local lines = {
        { { text = ' ' .. clean(file.path), hl = 'heading' },
          { text = '  ' .. size(file.size) .. ' · by ' .. person(file.author, file.author_name, overview.owner)
              .. ' · ' .. ago(file.updated_ms), hl = 'panel_note' } },
        '',
    }
    if view.error then return empty(lines, first_line(view.error), 'error') end
    if not view.value then return empty(lines, 'Loading ' .. clean(file.path)) end
    if type(view.value.text) ~= 'string' then
        return empty(lines, clean(file.path) .. ' is not text · ronna group cat ' .. view.id .. ' ' .. clean(file.path) .. ' prints it')
    end
    for _, text in ipairs(ramp.ui.wrap(view.value.text, math.max(1, width - 2))) do lines[#lines + 1] = ' ' .. text end
    view.cache = { width = width, lines = lines }
    return lines, nil
end

local function form_lines(width)
    local form = state.form
    local prompt = FORMS[form.kind].stages[form.stage].prompt(form)
    local wrapped = form.field:wrap(math.max(1, width - 4))
    local rows = wrapped.rows
    local first = math.max(1, math.min(wrapped.cursor.row - 4, #rows - 4))
    local lines = { '', { { text = ' ' .. first_line(prompt), hl = 'panel_label' } } }
    for index = first, math.min(#rows, first + 4) do
        lines[#lines + 1] = { { text = ' › ', hl = 'panel_marker' }, { text = rows[index], hl = 'panel_query' } }
    end
    return lines, { #lines - (math.min(#rows, first + 4) - wrapped.cursor.row), 3 + wrapped.cursor.col }
end

local function selection()
    local detail = state.detail
    return detail and detail.rows and detail.rows[detail.cursor]
end

local function detail_hints()
    local detail = state.detail
    local keys, current = {}, selection()
    if current and current.kind == 'member' then
        local lead = detail.overview and detail.overview.lead
        keys = { { '↵', 'attach' }, { 'L', current.item.session == lead and 'clear lead' or 'make lead' }, { 'x', 'remove' } }
    elseif current and current.kind == 'file' then
        keys = { { '↵', 'view' } }
    elseif current and current.kind == 'message' then
        keys = { { '↵', 'reply' } }
    end
    for _, pair in ipairs({
        { 'm', 'message' }, { 's', 'new session' }, { 'a', 'add session' },
        { 'p', paused(detail.id) and 'resume' or 'pause' }, { 'D', 'delete' }, { 'Esc', 'back' },
    }) do
        keys[#keys + 1] = pair
    end
    return hint_line(keys)
end

local function hints()
    if state.form then
        local spec = FORMS[state.form.kind]
        local last = state.form.stage == #spec.stages
        local keys = { { '↵', last and spec.verb or 'next' } }
        if state.form.kind == 'message' then keys[#keys + 1] = { 'Tab', 'recipient' } end
        keys[#keys + 1] = { 'Esc', 'cancel' }
        return hint_line(keys)
    end
    if state.confirm then
        return hint_line({ { 'y', state.confirm.verb }, { 'n', 'cancel' } })
    end
    if state.pick then
        local keys = { { '↵', state.pick.verb } }
        if state.pick.groups then keys[#keys + 1] = { 'n', 'new group' } end
        keys[#keys + 1] = { 'Esc', 'cancel' }
        return hint_line(keys)
    end
    if state.file then
        return hint_line({ { 'j/k', 'scroll' }, { 'Ctrl-d/u', 'page' }, { 'r', 'reload' }, { 'Esc', 'back' } })
    end
    if state.detail then return detail_hints() end
    return hint_line({
        { '↵', 'open' }, { 'n', 'new group' }, { 's', 'new session' }, { 'D', 'delete' },
        { 'r', 'refresh' }, { 'q', 'close' },
    })
end

local function scrolled(owner, lines, selected, height)
    if selected and owner.follow ~= false then
        if selected <= owner.scroll then owner.scroll = selected - 1 end
        if selected > owner.scroll + height then owner.scroll = selected - height end
    end
    owner.scroll = math.max(0, math.min(owner.scroll, #lines - height))
    local shown = {}
    for index = owner.scroll + 1, math.min(#lines, owner.scroll + height) do
        shown[#shown + 1] = lines[index]
    end
    return shown
end

local function title()
    if state.pick then return ' ' .. state.pick.title .. ' ' end
    if state.file then
        local revision = (state.file.value and state.file.value.revision) or state.file.file.revision
        return ' ' .. state.file.id .. ' · ' .. clean(state.file.file.path)
            .. (present(revision) and (' · revision ' .. number(revision)) or '') .. ' '
    end
    if state.detail then return ' Work group · ' .. state.detail.id .. ' ' end
    local text = ' Work groups' .. (state.list and (' · ' .. #state.list) or '')
    if state.marked > 0 then text = text .. ' · ● this session' end
    return text .. ' '
end

local function owner_of_scroll()
    if state.pick then return state.pick end
    return state.file or state.detail or state
end

local function render(ctx)
    local width, inner = ctx.width - 2, ctx.height - 2
    local body, selected
    if state.pick and state.pick.sessions then
        body, selected = session_lines(width)
    elseif state.file and not state.pick then
        body, selected = file_lines(width)
    elseif state.detail and not state.pick then
        body, selected = detail_lines(width)
    else
        body, selected = list_lines(width)
    end
    local tail, cursor = {}, nil
    if state.form then
        tail, cursor = form_lines(width)
    elseif state.confirm then
        tail = { '', { { text = ' ' .. state.confirm.text, hl = 'warning' } } }
    end
    local height = math.max(1, inner - #tail - 1)
    local lines = scrolled(owner_of_scroll(), body, selected, height)
    while #lines < height do lines[#lines + 1] = '' end
    local offset = #lines
    for _, line in ipairs(tail) do lines[#lines + 1] = line end
    lines[#lines + 1] = hints()
    return {
        lines = lines,
        border = true,
        border_kind = 'rounded',
        border_hl = 'panel_border',
        title = title(),
        title_hl = 'panel_title',
        cursor = (cursor and ctx.focused) and { offset + cursor[1], cursor[2] } or nil,
    }
end

local MOVES = {
    j = 1, ['<Down>'] = 1, ['<C-n>'] = 1,
    k = -1, ['<Up>'] = -1, ['<C-p>'] = -1,
}

local function chosen(owner, rows)
    owner.cursor = math.max(1, math.min(owner.cursor or 1, #rows))
    return rows[owner.cursor]
end

local function selected_group()
    return chosen(state.pick or state, visible())
end

local function form_key(event)
    if event.key == '<Esc>' then
        state.form = nil
    elseif event.key == '<CR>' then
        submit_form()
    elseif (event.key == '<Tab>' or event.key == '<S-Tab>') and state.form.kind == 'message' then
        cycle(state.form, event.key == '<Tab>' and 1 or -1)
    else
        state.form.field:key(event)
    end
    return true
end

local function confirm_key(event)
    local name = event.key
    if name == 'y' or name == '<CR>' then
        local yes = state.confirm.yes
        state.confirm = nil
        yes()
    elseif name == 'n' or name == '<Esc>' or name == 'q' then
        state.confirm = nil
    end
    return true
end

local function back()
    if state.pick then
        local standalone = state.pick.standalone
        state.pick = nil
        if standalone then M.close() end
    elseif state.file then
        state.file = nil
    elseif state.detail then
        state.detail = nil
    else
        M.close()
    end
end

local function pick_key(name)
    local spec = state.pick
    if name == '<CR>' or name == 'l' then
        local item
        if spec.sessions then item = chosen(spec, spec.rows or {}) else item = selected_group() end
        if not item then return end
        state.pick = nil
        spec.choose(item)
    elseif name == 'n' and spec.groups then
        start_form('create')
    end
end

local function add_session(detail)
    local members = {}
    for _, member in ipairs(items(detail.overview and detail.overview.members)) do members[member.session] = true end
    pick({
        title = 'Add a session to ' .. detail.id,
        verb = 'add',
        empty = 'No listed Ronna session is outside ' .. detail.id,
        sessions = function()
            local rows = {}
            for _, session in ipairs(ramp.api.get_sessions()) do
                local id = groups.session_id(session)
                if id and not members[id] and not session.archived then rows[#rows + 1] = session end
            end
            return rows
        end,
        choose = function(session) join(detail.id, groups.session_id(session)) end,
    })
end

local function reply(id, message)
    local sender = message.sender
    if type(sender) == 'table' and sender.type == 'agent' then
        start_message(id, to_member(sender.id), message.id)
    else
        start_message(id, 'group', message.id)
    end
end

local function detail_key(name)
    local detail = state.detail
    local current = selection()
    local member = current and current.kind == 'member' and current.item
    if name == '<CR>' or name == 'l' then
        if not current then return end
        if current.kind == 'member' then
            M.close()
            ramp.api.attach(groups.target(current.item.session))
        elseif current.kind == 'file' then
            view_file(detail.id, current.item)
        else
            reply(detail.id, current.item)
        end
    elseif name == 's' then
        launch(detail.id)
    elseif name == 'a' then
        add_session(detail)
    elseif name == 'x' and member then
        ask('Remove ' .. session_name(member.session, member.name) .. ' from ' .. detail.id .. '?', 'remove', function()
            leave(detail.id, member.session)
        end)
    elseif name == 'L' and member then
        toggle_lead(detail.id, member, detail.overview.lead)
    elseif name == 'm' then
        start_message(detail.id)
    elseif name == 'p' then
        toggle_pause(detail.id)
    elseif name == 'D' then
        ask('Delete work group ' .. detail.id .. ' with its files and messages?', 'delete', function()
            delete(detail.id)
        end)
    end
end

local function file_key(name)
    local view = state.file
    if MOVES[name] then
        view.scroll = math.max(0, view.scroll + MOVES[name])
    elseif name == '<C-d>' or name == '<PageDown>' then
        view.scroll = view.scroll + 10
    elseif name == '<C-u>' or name == '<PageUp>' then
        view.scroll = math.max(0, view.scroll - 10)
    elseif name == 'g' or name == '<Home>' then
        view.scroll = 0
    elseif name == 'G' or name == '<End>' then
        view.scroll = math.huge
    elseif name == 'r' then
        view_file(view.id, view.file)
    elseif name == 'q' then
        M.close()
    elseif name == '<Esc>' or name == 'h' or name == '<BS>' then
        back()
    elseif name == ':' then
        ramp.api.open_commands()
    end
    return true
end

local function list_key(name)
    local group = selected_group()
    if name == 'n' then
        start_form('create')
    elseif not group then
        return
    elseif name == '<CR>' or name == 'l' then
        open_detail(group.id)
    elseif name == 's' then
        launch(group.id)
    elseif name == 'D' then
        ask('Delete work group ' .. group.id .. ' with its files and messages?', 'delete', function()
            delete(group.id)
        end)
    end
end

local function key(event)
    if state.form then return form_key(event) end
    if state.confirm then return confirm_key(event) end
    local name = event.key
    if state.file and not state.pick then return file_key(name) end
    local owner = state.pick or state.detail or state
    if name == ':' then
        ramp.api.open_commands()
    elseif MOVES[name] then
        owner.cursor = (owner.cursor or 1) + MOVES[name]
        owner.follow = true
    elseif name == 'g' or name == '<Home>' then
        owner.cursor, owner.follow = 1, true
    elseif name == 'G' or name == '<End>' then
        owner.cursor, owner.follow = math.huge, true
    elseif name == '<C-d>' or name == '<PageDown>' then
        owner.scroll, owner.follow = owner.scroll + 10, false
    elseif name == '<C-u>' or name == '<PageUp>' then
        owner.scroll, owner.follow = math.max(0, owner.scroll - 10), false
    elseif name == 'r' then
        refresh()
    elseif name == 'q' then
        M.close()
    elseif name == '<Esc>' or name == 'h' or name == '<BS>' then
        back()
    elseif state.pick then
        pick_key(name)
    elseif state.detail then
        detail_key(name)
    else
        list_key(name)
    end
    return true
end

local function paste(event)
    if state.form then state.form.field:paste(event) end
    return true
end

local function capped(text)
    local length = utf8.len(text)
    if not length or length <= ANNOTATION_CHARS then return text end
    return text:sub(1, utf8.offset(text, ANNOTATION_CHARS) - 1) .. '…'
end

function M.annotate(session)
    local id = groups.session_id(session)
    if not id then return nil end
    local names, led = {}, {}
    for _, group in ipairs(groups.memberships(session)) do
        local name = first_line(group.id)
        names[#names + 1] = name
        if present(group.lead) and group.lead == id then led[#led + 1] = name end
    end
    local networking = session.metadata and session.metadata.network
    local mode = type(networking) == 'table' and networking.selected_mode
    local network_label = mode == 'on' and 'On' or mode == 'selected-integrations' and 'Selected integrations' or nil
    local network_detail = network_label and ('Networking: ' .. network_label) or nil
    local runner = session.metadata and session.metadata.runner
    if type(runner) == 'table' then
        network_label = runner.owner .. '/' .. runner.name .. ' · ' .. runner.availability
        network_detail = network_label .. ' · Host-controlled networking'
        if type(runner.directory) == 'table' then network_detail = network_detail .. ' · ' .. runner.directory.name .. ': ' .. runner.directory.path end
    end
    local access = session.metadata and session.metadata.access
    local workspace = session.metadata and session.metadata.workspace_id
    if access and workspace then network_detail = (network_detail and (network_detail .. ' · ') or '') .. 'Access: ' .. access .. ' · Workspace: ' .. (workspace:match('^default%-') and 'My workspace' or workspace) end
    if #names == 0 then
        if network_label then return { label = network_label, detail = network_detail, hl = 'muted' } end
        return nil
    end
    local detail = #led > 0 and ('lead of ' .. table.concat(led, ', ')) or nil
    if network_detail then detail = network_detail .. (detail and (' · ' .. detail) or '') end
    return {
        label = capped(table.concat(names, ', ')),
        hl = 'accent',
        detail = detail and capped(detail) or nil,
        group = capped(HEADING .. names[1]),
        group_open = not check_id(names[1]) and ('groups ' .. names[1]) or nil,
        group_delete = not check_id(names[1]) and ('group-delete ' .. names[1]) or nil,
    }
end

local function choose_group(spec)
    M.open({ session = spec.session })
    spec.standalone = true
    spec.groups = spec.groups or function() return true end
    spec.empty = spec.empty or 'No work groups yet · n creates one'
    pick(spec)
end

local function ronna_session()
    local session = current_session()
    local id = session and groups.session_id(session)
    if not id then ramp.notify('Select or attach to a Ronna session first', 'warn') end
    return session, id
end

local actions = {}

function actions.browse()
    M.open()
end

function actions.create()
    M.open()
    start_form('create')
end

function actions.start()
    choose_group({ title = 'Start a session in a work group', verb = 'start', choose = function(group) launch(group.id) end })
end

function actions.join()
    local session, id = ronna_session()
    if not id then return end
    choose_group({
        title = 'Add ' .. label(session) .. ' to a work group',
        verb = 'add',
        session = session,
        groups = function(group) return not member_of(group, id) end,
        empty = 'This session is in every work group · n creates another',
        choose = function(group)
            M.close()
            join(group.id, id)
        end,
    })
end

function actions.leave()
    local session, id = ronna_session()
    if not id then return end
    choose_group({
        title = 'Remove ' .. label(session) .. ' from a work group',
        verb = 'remove',
        session = session,
        groups = function(group) return member_of(group, id) end,
        empty = 'This session is in no work groups',
        choose = function(group)
            M.close()
            leave(group.id, id)
        end,
    })
end

function actions.message()
    choose_group({
        title = 'Message a work group',
        verb = 'message',
        choose = function(group)
            open_detail(group.id)
            start_message(group.id)
        end,
    })
end

local KEYS = {
    { 'g', actions.browse, 'Browse work groups' },
    { 'n', actions.create, 'New work group' },
    { 's', actions.start, 'Start a session in a group' },
    { 'j', actions.join, 'Add this session to a group' },
    { 'l', actions.leave, 'Remove this session from a group' },
    { 'm', actions.message, 'Message a group' },
}

local function split(args)
    local id, rest = (args or ''):match('^%s*(%S+)%s*(.-)%s*$')
    return id, rest ~= '' and rest or nil
end

local function complete(_, line)
    if not state.list then fetch_list() end
    if (line:match('^%S+%s+(.*)$') or ''):find('%s') then return {} end
    local found = {}
    for _, group in ipairs(state.list or {}) do
        found[#found + 1] = { text = group.id, desc = first_line(group.description) }
    end
    return found
end

local function with_group(usage, fn)
    return function(args)
        local id, rest = split(args)
        if not id then return ramp.notify('Usage: ' .. usage, 'warn') end
        fn(id, rest)
    end
end

local function command(name, spec)
    if spec.complete == nil then spec.complete = complete end
    if spec.complete == false then spec.complete = nil end
    ramp.api.register_command(name, spec)
end

local function membership(fn)
    return function(id)
        local _, session = ronna_session()
        if session then fn(id, session) end
    end
end

function M.setup()
    ramp.ui.register_view(VIEW, { render = render, key = key, paste = paste })
    ramp.ui.annotate_session(M.annotate)
    ramp.api.on('sessions', function() listed = nil end)

    command('network', {
        desc = 'Inspect or change Ronna networking',
        args = '[SESSION] [selected-integrations|on]',
        complete = false,
        run = function(args)
            local id, mode = split(args)
            if not id then local _, current = ronna_session(); id = current end
            if not id then return end
            if mode and mode ~= 'on' and mode ~= 'selected-integrations' then
                return ramp.notify('Usage: network SESSION [selected-integrations|on]', 'warn')
            end
            local command_args = require('ronna').command('network', id)
            if mode then command_args[#command_args + 1] = '--mode'; command_args[#command_args + 1] = mode end
            ramp.api.run(command_args, nil, function(result)
                if result.code ~= 0 then return ramp.notify(result.stderr, 'error') end
                local ok, value = pcall(ramp.api.json_decode, result.stdout)
                if not ok then return ramp.notify('Could not read networking status', 'error') end
                local label = value.selected_mode == 'on' and 'On' or 'Selected integrations'
                local message = 'Networking: ' .. label .. ' (' .. value.application_status .. ')'
                for _, choice in ipairs(value.choices or {}) do
                    if not choice.supported then message = message .. '\n' .. choice.mode .. ': ' .. (choice.reason or 'unavailable') end
                end
                ramp.notify(message)
            end)
        end,
    })
    command('groups', {
        desc = 'Browse work groups',
        args = '[GROUP]',
        run = function(args) M.open({ id = split(args) }) end,
    })
    command('group-create', {
        desc = 'Create a work group',
        args = 'GROUP [DESCRIPTION]',
        complete = false,
        run = with_group('group-create GROUP [DESCRIPTION]', function(id, description)
            local problem = check_id(id)
            if problem then return ramp.notify(problem, 'warn') end
            create(id, description)
        end),
    })
    command('group-delete', {
        desc = 'Delete a work group',
        args = 'GROUP',
        run = with_group('group-delete GROUP', function(id)
            M.open()
            ask('Delete work group ' .. id .. ' with its files and messages?', 'delete', function() delete(id) end)
        end),
    })
    command('group-join', {
        desc = 'Add this session to a work group',
        args = 'GROUP',
        run = with_group('group-join GROUP', membership(join)),
    })
    command('group-leave', {
        desc = 'Remove this session from a work group',
        args = 'GROUP',
        run = with_group('group-leave GROUP', membership(leave)),
    })
    command('group-message', {
        desc = 'Send a message to a work group',
        args = 'GROUP [TEXT]',
        run = with_group('group-message GROUP [TEXT]', function(id, text)
            if text then return send_message(id, text, 'group') end
            M.open({ id = id })
            start_message(id)
        end),
    })
    command('group-launch', {
        desc = 'Start a session in a work group',
        args = 'GROUP',
        run = with_group('group-launch GROUP', function(id) launch(id) end),
    })
    command('group-pause', {
        desc = 'Hold every message in a work group',
        args = 'GROUP',
        run = with_group('group-pause GROUP', function(id)
            groups.pause(id, done(id .. ' paused · messages wait until you resume it'))
        end),
    })
    command('group-resume', {
        desc = 'Deliver a work group\'s held messages',
        args = 'GROUP',
        run = with_group('group-resume GROUP', function(id)
            groups.resume(id, done(id .. ' resumed · held messages go out now'))
        end),
    })

    for mode in ('ntd'):gmatch('%a') do
        ramp.keymap.group(mode, '<Leader>g', 'groups')
        for _, spec in ipairs(KEYS) do
            ramp.keymap.set(mode, '<Leader>g' .. spec[1], spec[2], { desc = spec[3] })
        end
    end
end

return M
