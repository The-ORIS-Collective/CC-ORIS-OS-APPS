
local Storage = dofile("OrisOS/Storage.lua")

local TextEditor = {}

local App
local Mouse

local title = "Text Editor"
local filePath = nil
local lines = { "" }

local DEFAULT_DIR = "OrisOS/UserData/Documents"

local cursorX = 1
local cursorY = 1
local scrollX = 0
local scrollY = 0

local message = "Ready"
local modified = false
local ctrlDown = false

local promptMode = false
local promptText = ""
local promptLabel = ""
local promptAction = nil

local mouseAreas = {}

local lastOpenRequest = nil
local checkingOpenRequest = false

--------------------------------------------------
-- PATH HELPERS
--------------------------------------------------

local function NormalizePath(path)
    if not path or tostring(path) == "" then
        return nil
    end

    path = tostring(path):gsub("\\", "/")
    path = path:gsub("^/+", "")

    return fs.combine("", path)
end

local function BaseName(path)
    if not path or path == "" then
        return "Untitled"
    end

    return fs.getName(path)
end

local function DisplayPath()
    if filePath then
        return "/" .. filePath
    end

    return "Untitled"
end

local function EnsureDirectory(path)
    path = NormalizePath(path)

    if not path or path == "" then
        return true
    end

    if Storage.Exists(path) then
        if Storage.IsDir(path) then
            return true
        end

        return false, "Path exists but is not a directory"
    end

    return Storage.MakeDir(path)
end

--------------------------------------------------
-- MOUSE HELPERS
--------------------------------------------------

local function UnregisterMouseAreas()
    if not Mouse then
        return
    end

    for _, id in ipairs(mouseAreas) do
        pcall(Mouse.Unregister, id)
    end

    mouseAreas = {}
end

local function RegisterArea(x, y, width, callback)
    if not Mouse or width <= 0 then
        return
    end

    local id = Mouse.Register(x, y, width, 1, callback)

    if id then
        mouseAreas[#mouseAreas + 1] = id
    end
end

--------------------------------------------------
-- CURSOR HELPERS
--------------------------------------------------

local function ClampCursor()
    if #lines < 1 then
        lines = { "" }
    end

    cursorY = math.max(1, math.min(cursorY, #lines))
    cursorX = math.max(1, math.min(cursorX, #lines[cursorY] + 1))
end

local function EnsureCursorVisible(width, height)
    local contentHeight = math.max(1, height - 4)
    local contentWidth = math.max(1, width)

    if cursorY <= scrollY then
        scrollY = cursorY - 1
    elseif cursorY > scrollY + contentHeight then
        scrollY = cursorY - contentHeight
    end

    if cursorX - 1 < scrollX then
        scrollX = cursorX - 1
    elseif cursorX - 1 >= scrollX + contentWidth then
        scrollX = cursorX - contentWidth
    end

    scrollY = math.max(0, scrollY)
    scrollX = math.max(0, scrollX)
end

--------------------------------------------------
-- FILE LOADING
--------------------------------------------------

local function LoadFile(path)
    path = NormalizePath(path)

    if not path then
        message = "No file path received"
        return false
    end

    -- Keep compatibility with older callers that omit "OrisOS/".
    local candidates = { path }

    if path:sub(1, 7) == "OrisOS/" then
        candidates[#candidates + 1] = path:sub(8)
    else
        candidates[#candidates + 1] = "OrisOS/" .. path
    end

    local resolvedPath

    for _, candidate in ipairs(candidates) do
        candidate = NormalizePath(candidate)

        local ok, exists = pcall(Storage.Exists, candidate)

        if ok and exists then
            local dirOK, isDir = pcall(Storage.IsDir, candidate)

            if dirOK and not isDir then
                resolvedPath = candidate
                break
            end
        end
    end

    if not resolvedPath then
        message = "File not found: " .. path
        return false
    end

    local openOK, handle, openError = pcall(Storage.Open, resolvedPath, "r")

    if not openOK then
        message = "Open failed: " .. tostring(handle)
        return false
    end

    if not handle then
        message = "Open failed: " .. tostring(openError)
        return false
    end

    local readOK, content = pcall(function()
        return handle.readAll()
    end)

    pcall(function()
        handle.close()
    end)

    if not readOK then
        message = "Read failed: " .. tostring(content)
        return false
    end

    lines = {}
    content = tostring(content or "")
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in (content .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end

    if #lines == 0 then
        lines = { "" }
    end

    filePath = resolvedPath
    cursorX = 1
    cursorY = 1
    scrollX = 0
    scrollY = 0
    modified = false
    message = "Opened " .. BaseName(resolvedPath)

    ClampCursor()

    return true
end

--------------------------------------------------
-- FILE EXPLORER OPEN REQUESTS
--------------------------------------------------

local function CheckForOpenFileRequest()
    if checkingOpenRequest then
        return false
    end

    local requestedPath = _G.OrisOS_OpenFile

    if not requestedPath or tostring(requestedPath) == "" then
        return false
    end

    requestedPath = tostring(requestedPath)

    -- Consume the request immediately.
    _G.OrisOS_OpenFile = nil

    checkingOpenRequest = true

    local ok, result = pcall(LoadFile, requestedPath)

    if not ok then
        message = "Open error: " .. tostring(result)
    elseif result then
        lastOpenRequest = requestedPath
        promptMode = false
        promptText = ""
        promptLabel = ""
        promptAction = nil
    end

    checkingOpenRequest = false

    return true
end

--------------------------------------------------
-- FILE SAVING
--------------------------------------------------

local function SaveFile(path)
    path = NormalizePath(path or filePath)

    if not path then
        message = "Use Save As to choose a filename"
        return false
    end

    if Storage.Exists(path) and Storage.IsDir(path) then
        message = "Cannot save over a directory"
        return false
    end

    local parent = fs.getDir(path)

    if parent and parent ~= "" then
        local ok, err = EnsureDirectory(parent)

        if not ok then
            message = "Cannot create parent directory: " .. tostring(err)
            return false
        end
    end

    local openOK, handle, openError = pcall(Storage.Open, path, "w")

    if not openOK then
        message = "Save failed: " .. tostring(handle)
        return false
    end

    if not handle then
        message = "Save failed: " .. tostring(openError)
        return false
    end

    local content = table.concat(lines, "\n")

    local writeOK, writeError = pcall(function()
        handle.write(content)
    end)

    local closeOK, closeError = pcall(function()
        handle.close()
    end)

    if not writeOK then
        message = "Write failed: " .. tostring(writeError)
        return false
    end

    if not closeOK then
        message = "Close failed: " .. tostring(closeError)
        return false
    end

    filePath = path
    modified = false
    message = "Saved " .. BaseName(path)

    return true
end

--------------------------------------------------
-- SAVE AS
--------------------------------------------------

local function BeginPrompt(label, action, initialText)
    promptMode = true
    promptLabel = label
    promptText = initialText or ""
    promptAction = action
    message = label

    TextEditor.Draw()
end

local function SaveAs()
    local ok, err = EnsureDirectory(DEFAULT_DIR)

    if not ok then
        message = "Documents unavailable: " .. tostring(err)
        TextEditor.Draw()
        return
    end

    local initial = filePath or (DEFAULT_DIR .. "/Untitled.txt")

    BeginPrompt("Save as", function(value)
        value = tostring(value or ""):gsub("\\", "/")

        if value == "" then
            message = "Save cancelled"
            TextEditor.Draw()
            return
        end

        -- A filename without a directory goes into Documents.
        if not value:find("/", 1, true) then
            value = fs.combine(DEFAULT_DIR, value)
        else
            value = NormalizePath(value)
        end

        if not value or value == "" then
            message = "Invalid path"
            TextEditor.Draw()
            return
        end

        local saved = SaveFile(value)

        if saved then
            lastOpenRequest = nil
        end

        TextEditor.Draw()
    end, initial)
end

local function Save()
    if filePath then
        SaveFile(filePath)
        TextEditor.Draw()
    else
        SaveAs()
    end
end

--------------------------------------------------
-- TEXT EDITING
--------------------------------------------------

local function InsertText(text)
    local line = lines[cursorY]
    local before = line:sub(1, cursorX - 1)
    local after = line:sub(cursorX)

    lines[cursorY] = before .. text .. after
    cursorX = cursorX + #text

    modified = true
    message = "Editing"
end

local function InsertNewLine()
    local line = lines[cursorY]
    local before = line:sub(1, cursorX - 1)
    local after = line:sub(cursorX)

    lines[cursorY] = before
    table.insert(lines, cursorY + 1, after)

    cursorY = cursorY + 1
    cursorX = 1

    modified = true
    message = "Editing"
end

local function Backspace()
    local line = lines[cursorY]

    if cursorX > 1 then
        lines[cursorY] =
            line:sub(1, cursorX - 2) .. line:sub(cursorX)

        cursorX = cursorX - 1
        modified = true

    elseif cursorY > 1 then
        local previousLength = #lines[cursorY - 1]

        lines[cursorY - 1] =
            lines[cursorY - 1] .. lines[cursorY]

        table.remove(lines, cursorY)

        cursorY = cursorY - 1
        cursorX = previousLength + 1

        modified = true
    end

    message = "Editing"
end

local function DeleteForward()
    local line = lines[cursorY]

    if cursorX <= #line then
        lines[cursorY] =
            line:sub(1, cursorX - 1) .. line:sub(cursorX + 1)

        modified = true

    elseif cursorY < #lines then
        lines[cursorY] = lines[cursorY] .. lines[cursorY + 1]
        table.remove(lines, cursorY + 1)

        modified = true
    end

    message = "Editing"
end

local function MoveCursor(dx, dy)
    cursorY = cursorY + dy
    ClampCursor()

    cursorX = cursorX + dx
    ClampCursor()
end

local function PlaceCursorAtMouse(x, y)
    local width, height = term.getSize()

    if y < 2 or y > height - 3 then
        return
    end

    cursorY = scrollY + y - 1
    cursorX = scrollX + x

    ClampCursor()
    EnsureCursorVisible(width, height)

    message = "Editing"
    TextEditor.Draw()
end

--------------------------------------------------
-- DRAWING
--------------------------------------------------

local function DrawHeader(width)
    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()

    local name = DisplayPath()

    if modified then
        name = name .. " *"
    end

    term.setCursorPos(2, 1)
    term.write(name:sub(1, math.max(0, width - 1)))
end

local function DrawStatus(width, height)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)

    term.setCursorPos(1, height - 2)
    term.clearLine()
    term.write(
        ("File: " .. (filePath and fs.getName(filePath) or "Untitled"))
            :sub(1, width)
    )

    term.setCursorPos(1, height - 1)
    term.clearLine()
    term.write(
        ("Folder: /" .. (filePath and fs.getDir(filePath) or DEFAULT_DIR))
            :sub(1, width)
    )

    term.setCursorPos(1, height)
    term.clearLine()
    term.write(
        ("Ln " .. cursorY .. ", Col " .. cursorX
            .. (modified and " | Modified" or " | Saved"))
            :sub(1, width)
    )
end

local function DrawTextCursor(width, height)
    if promptMode then
        local y = height - 3
        local shown = (promptLabel .. ": " .. promptText):sub(1, width)

        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.yellow)
        term.clearLine()
        term.write(shown)

        local cursorPos = math.min(
            width,
            #promptLabel + 3 + #promptText + 1
        )

        term.setCursorPos(math.max(1, cursorPos), y)
        return
    end

    local screenX = cursorX - scrollX
    local screenY = cursorY - scrollY + 1

    if screenX < 1 or screenX > width then
        return
    end

    if screenY < 2 or screenY > height - 3 then
        return
    end

    local line = lines[cursorY] or ""
    local character = line:sub(cursorX, cursorX)

    if character == "" then
        character = " "
    end

    term.setCursorPos(screenX, screenY)
    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)
    term.write(character)
    term.setCursorPos(screenX, screenY)
end

--------------------------------------------------
-- INITIALIZATION
--------------------------------------------------

function TextEditor.Init(appModule, mouseModule)
    App = appModule
    Mouse = mouseModule

    lastOpenRequest = nil
    checkingOpenRequest = false

    promptMode = false
    promptText = ""
    promptLabel = ""
    promptAction = nil
    ctrlDown = false

    if Storage.Refresh then
        pcall(Storage.Refresh)
    end

    local ok, err = EnsureDirectory(DEFAULT_DIR)

    if not ok then
        message = "Documents unavailable: " .. tostring(err)
    end

    local requestedPath = _G.OrisOS_OpenFile
    _G.OrisOS_OpenFile = nil

    if requestedPath then
        requestedPath = tostring(requestedPath)
        lastOpenRequest = requestedPath

        if not LoadFile(requestedPath) then
            filePath = nil
            lines = { "" }
            cursorX = 1
            cursorY = 1
            scrollX = 0
            scrollY = 0
            modified = false
        end
    else
        filePath = nil
        lines = { "" }
        cursorX = 1
        cursorY = 1
        scrollX = 0
        scrollY = 0
        modified = false
        message = "New document - " .. DEFAULT_DIR
    end
end

--------------------------------------------------
-- MAIN DRAW FUNCTION
--------------------------------------------------

function TextEditor.Draw()
    CheckForOpenFileRequest()

    UnregisterMouseAreas()

    local width, height = term.getSize()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    DrawHeader(width)
    EnsureCursorVisible(width, height)

    local contentHeight = math.max(0, height - 4)

    for screenRow = 1, contentHeight do
        local lineIndex = scrollY + screenRow
        local screenY = screenRow + 1

        term.setCursorPos(1, screenY)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)

        if lineIndex <= #lines then
            local line = lines[lineIndex] or ""
            local visible = line:sub(scrollX + 1, scrollX + width)
            term.write(visible)
        end

        RegisterArea(1, screenY, width, function(button, mouseX, mouseY)
            if button == 1 and not promptMode then
                PlaceCursorAtMouse(mouseX or 1, mouseY or screenY)
            end
        end)
    end

    DrawStatus(width, height)
    DrawTextCursor(width, height)

    term.setCursorBlink(not promptMode)
end

--------------------------------------------------
-- EVENT HANDLING
--------------------------------------------------

function TextEditor.HandleEvent(event, p1, p2)
    if CheckForOpenFileRequest() then
        TextEditor.Draw()
        return
    end

    if event == "key_up" then
        if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
            ctrlDown = false
        end

        return
    end

    if event == "key" then
        if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
            ctrlDown = true
            return
        end

        if promptMode then
            if p1 == keys.enter then
                local value = promptText
                local action = promptAction

                promptMode = false
                promptText = ""
                promptAction = nil

                if action then
                    local ok, err = pcall(action, value)

                    if not ok then
                        message = "Action failed: " .. tostring(err)
                    end
                end

                TextEditor.Draw()

            elseif p1 == keys.escape then
                promptMode = false
                promptText = ""
                promptAction = nil
                message = "Cancelled"
                TextEditor.Draw()

            elseif p1 == keys.backspace then
                promptText = promptText:sub(1, -2)
                TextEditor.Draw()
            end

            return
        end

        if ctrlDown and p1 == keys.s then
            Save()
            return
        end

        if p1 == keys.left then
            if cursorX > 1 then
                cursorX = cursorX - 1
            elseif cursorY > 1 then
                cursorY = cursorY - 1
                cursorX = #lines[cursorY] + 1
            end

        elseif p1 == keys.right then
            if cursorX <= #lines[cursorY] then
                cursorX = cursorX + 1
            elseif cursorY < #lines then
                cursorY = cursorY + 1
                cursorX = 1
            end

        elseif p1 == keys.up then
            MoveCursor(0, -1)

        elseif p1 == keys.down then
            MoveCursor(0, 1)

        elseif p1 == keys.home then
            cursorX = 1

        elseif p1 == keys["end"] then
            cursorX = #lines[cursorY] + 1

        elseif p1 == keys.pageUp then
            local _, height = term.getSize()
            MoveCursor(0, -math.max(1, height - 4))

        elseif p1 == keys.pageDown then
            local _, height = term.getSize()
            MoveCursor(0, math.max(1, height - 4))

        elseif p1 == keys.backspace then
            Backspace()

        elseif p1 == keys.delete then
            DeleteForward()

        elseif p1 == keys.enter then
            InsertNewLine()

        elseif p1 == keys.tab then
            InsertText("    ")

        elseif p1 == keys.escape then
            message = "Editing"
        end

        ClampCursor()

        local width, height = term.getSize()
        EnsureCursorVisible(width, height)

        TextEditor.Draw()
        return
    end

    if event == "char" then
        if promptMode then
            promptText = promptText .. tostring(p1)
        else
            InsertText(tostring(p1))
        end

        TextEditor.Draw()
        return
    end

    if event == "mouse_scroll" then
        if promptMode then
            return
        end

        scrollY = math.max(
            0,
            math.min(math.max(0, #lines - 1), scrollY + p1)
        )

        TextEditor.Draw()
    end
end

return TextEditor
