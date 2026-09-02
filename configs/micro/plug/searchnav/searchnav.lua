VERSION = "1.0.0"

-- Down/Up step through search matches while a search is armed. Bound in
-- bindings.json as "lua:searchnav.down|CursorDown": returning false here is
-- what makes micro fall through to plain cursor movement.

local micro = import("micro")

local armed = false     -- last search still current, arrows walk matches
local touched = false   -- a find action ran during this event
local prompted = false  -- infobar held a prompt during the last event

local function arm()
    armed = true
    touched = true
end

function down(bp)
    if armed and bp.Cursor:HasSelection() then
        bp:FindNext()
        touched = true
        return true
    end
    armed = false
    return false
end

function up(bp)
    if armed and bp.Cursor:HasSelection() then
        bp:FindPrevious()
        touched = true
        return true
    end
    armed = false
    return false
end

-- Every entry point into a search.
function onFind(bp) arm() end
function onFindLiteral(bp) arm() end
function onFindNext(bp) arm() end
function onFindPrevious(bp) arm() end

-- Runs after every event. onFind fires when the prompt opens, not when the
-- search runs, so stay armed while the infobar holds it -- the search term is
-- typed into that prompt, and would otherwise look like unrelated keys.
function onAnyEvent()
    if micro.InfoBar().HasPrompt then
        prompted = true
    elseif prompted then
        prompted = false
    elseif touched then
        touched = false
    else
        armed = false
    end
end
