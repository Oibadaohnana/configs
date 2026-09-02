VERSION = "1.0.0"

-- Ctrl+B / Ctrl+U wrap the selection -- or the word under the cursor -- in
-- **bold** and <u>underline</u>, and strip them again on a second press.
-- syntax/markdown.yaml and syntax/plaintext.yaml render the result.

local buffer = import("micro/buffer")
local util = import("micro/util")

-- Selections carry rune offsets, so widen the selection to read the
-- neighbouring text rather than slicing Line() by bytes -- umlauts count once.
local function runesInLine(buf, y)
    return util.CharacterCountInString(buf:Line(y))
end

local function reselect(cursor, sx, sy, ex, ey)
    cursor:SetSelectionStart(buffer.Loc(sx, sy))
    cursor:SetSelectionEnd(buffer.Loc(ex, ey))
    cursor:GotoLoc(buffer.Loc(ex, ey))
end

local function toggle(bp, open, close)
    local buf, c = bp.Buf, bp.Cursor
    local olen, clen = open:len(), close:len()

    if not c:HasSelection() then
        c:SelectWord()
    end
    -- On blank space SelectWord grabs the single character under the cursor.
    if c:HasSelection() and util.String(c:GetSelection()):match("^%s*$") then
        c:ResetSelection()
    end

    if not c:HasSelection() then
        local x, y = c.Loc.X, c.Loc.Y
        buf:Insert(buffer.Loc(x, y), open .. close)
        c:GotoLoc(buffer.Loc(x + olen, y))
        return
    end

    -- CurSelection hands out live pointers; keep plain numbers instead.
    local sx, sy = c.CurSelection[1].X, c.CurSelection[1].Y
    local ex, ey = c.CurSelection[2].X, c.CurSelection[2].Y

    -- Selecting upwards or leftwards leaves the pair the wrong way round,
    -- which shows as </u>text<u>.
    if sy > ey or (sy == ey and sx > ex) then
        sx, sy, ex, ey = ex, ey, sx, sy
    end

    -- A whole-line selection reaches column 0 of the line below, and the
    -- closing marker would land there on its own -- markdown needs the pair
    -- to close on the text it opened on.
    while ey > sy and ex == 0 do
        ey = ey - 1
        ex = runesInLine(buf, ey)
    end

    -- Trailing/leading blanks inside the selection push the markers off the
    -- text ("** bold **"), which no longer reads as emphasis. Whitespace is
    -- single-byte, so these byte counts are rune counts.
    if sy == ey then
        reselect(c, sx, sy, ex, ey)
        local text = util.String(c:GetSelection())
        sx = sx + #text:match("^%s*")
        ex = ex - #text:match("%s*$")
        if ex <= sx then
            c:ResetSelection()
            buf:Insert(buffer.Loc(sx, sy), open .. close)
            c:GotoLoc(buffer.Loc(sx + olen, sy))
            return
        end
    end
    reselect(c, sx, sy, ex, ey)

    if sx >= olen and ex + clen <= runesInLine(buf, ey) then
        reselect(c, sx - olen, sy, ex + clen, ey)
        local wide = util.String(c:GetSelection())
        if wide:sub(1, olen) == open and wide:sub(-clen) == close then
            buf:Remove(buffer.Loc(ex, ey), buffer.Loc(ex + clen, ey))
            buf:Remove(buffer.Loc(sx - olen, sy), buffer.Loc(sx, sy))
            reselect(c, sx - olen, sy, ey == sy and ex - olen or ex, ey)
            return
        end
        reselect(c, sx, sy, ex, ey)
    end

    buf:Insert(buffer.Loc(ex, ey), close)
    buf:Insert(buffer.Loc(sx, sy), open)
    reselect(c, sx + olen, sy, ey == sy and ex + olen or ex, ey)
end

function bold(bp)
    toggle(bp, "**", "**")
    return true
end

function underline(bp)
    toggle(bp, "<u>", "</u>")
    return true
end
