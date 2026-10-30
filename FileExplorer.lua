
local Storage = dofile("OrisOS/Storage.lua")

local Explorer = {}
local App
local Mouse

-- Configuration
local rowStart = 4
local menuWidth = 22

local trashPath = "OrisOS/UserData/Trash"
local documentsPath = "OrisOS/UserData/Documents"
local downloadsPath = "OrisOS/UserData/Downloads"
local homePath = "OrisOS/UserData"

local currentPath = homePath
local entries = {}
local selectedEntry = nil
local message = ""
local pageSize = 0
local scrollOffset = 0
local clickAreas = {}

local menuOpen = false
local menuX = 1
local menuY = 2
local menuItems = {}
local menuEntry = nil

local inputMode = false
local inputText = ""
local inputLabel = ""
local pendingAction = nil

local ShowOpenWithMenu
local ShowContextMenu

--------------------------------------------------
-- PATH HELPERS
--------------------------------------------------

local function ResolvePath(path)
    if not path or path == "" or path == "/" then
        return ""
    end

    return fs.combine("", path)
end

local function DisplayPath()
    if currentPath == "" then
        return "/"
    end

    return "/" .. currentPath
end

local function IsInTrash()
    local path = ResolvePath(currentPath)
    local trash = ResolvePath(trashPath)

    return path == trash
        or path:sub(1, #trash + 1) == trash .. "/"
end

local function EnsurePath(path)
    path = ResolvePath(path)

    if Storage.Exists(path) then
        return Storage.IsDir(path)
    end

    local ok, err = Storage.MakeDir(path)

    if not ok then
        return false, err
    end

    return true
end

local function IsValidName(name)
    return type(name) == "string"
        and name ~= ""
        and name ~= "."
        and name ~= ".."
        and not name:find("[/\\]")
        and not name:find("[%c]")
end

local function IsInsidePath(path, parent)
    path = ResolvePath(path)
    parent = ResolvePath(parent)

    return path == parent
        or path:sub(1, #parent + 1) == parent .. "/"
end

local function SafeStorageCall(callback, ...)
    local ok, result, err = pcall(callback, ...)

    if not ok then
        return false, tostring(result)
    end

    if result == false or result == nil then
        return false, tostring(err or "Operation failed")
    end

    return true, result
end

--------------------------------------------------
-- MOUSE HELPERS
--------------------------------------------------

local function ClearClickAreas()
    if not Mouse then
        return
    end

    for _, id in ipairs(clickAreas) do
        pcall(Mouse.Unregister, id)
    end

    clickAreas = {}
end

local function RegisterArea(x, y, width, height, callback)
    if not Mouse or width <= 0 or height <= 0 then
        return
    end

    local id = Mouse.Register(x, y, width, height, callback)

    if id then
        clickAreas[#clickAreas + 1] = id
    end
end

local function RegisterButton(x, y, width, height, callback)
    if menuOpen or inputMode then
        return
    end

    RegisterArea(x, y, width, height, function(button)
        if menuOpen or inputMode then
            return
        end

        if button == 1 then
            callback()
        end
    end)
end

--------------------------------------------------
-- DISPLAY HELPERS
--------------------------------------------------

local function FormatSize(bytes)
    bytes = tonumber(bytes) or 0

    if bytes < 1024 then
        return tostring(bytes) .. " B"
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    end
end

local function WriteClipped(x, y, text, maxWidth)
    if maxWidth <= 0 then
        return
    end

    term.setCursorPos(x, y)
    term.write(tostring(text):sub(1, maxWidth))
end

--------------------------------------------------
-- DIRECTORY LOADING
--------------------------------------------------

local function LoadDirectory()
    entries = {}
    selectedEntry = nil
    scrollOffset = 0

    local path = ResolvePath(currentPath)

    local existsOK, exists = pcall(Storage.Exists, path)

    if not existsOK or not exists then
        message = "Directory does not exist"
        return
    end

    local dirOK, isDirectory = pcall(Storage.IsDir, path)

    if not dirOK or not isDirectory then
        message = "Path is not a directory"
        return
    end

    local ok, files = pcall(Storage.List, path)

    if not ok or type(files) ~= "table" then
        message = "Unable to read directory: " .. tostring(files)
        return
    end

    table.sort(files, function(a, b)
        local pathA = fs.combine(path, a)
        local pathB = fs.combine(path, b)

        local dirA = Storage.IsDir(pathA)
        local dirB = Storage.IsDir(pathB)

        if dirA ~= dirB then
            return dirA
        end

        return a:lower() < b:lower()
    end)

    for _, name in ipairs(files) do
        local fullPath = fs.combine(path, name)
        local isDir = Storage.IsDir(fullPath)
        local size = 0

        if not isDir then
            local sizeOK, result = pcall(Storage.GetSize, fullPath)

            if sizeOK then
                size = tonumber(result) or 0
            end
        end

        entries[#entries + 1] = {
            name = name,
            path = fullPath,
            isDir = isDir,
            size = size
        }
    end

    message = #entries .. " item(s)"
end

--------------------------------------------------
-- MENU HELPERS
--------------------------------------------------

local function CloseMenu()
    menuOpen = false
    menuItems = {}
    menuEntry = nil
end

local function BeginInput(label, action, defaultText)
    CloseMenu()

    inputMode = true
    inputLabel = label
    pendingAction = action
    inputText = defaultText or ""
    message = label .. ":"

    Explorer.Draw()
end

--------------------------------------------------
-- NAVIGATION
--------------------------------------------------

local function GoUp()
    if menuOpen or inputMode or currentPath == "" then
        return
    end

    currentPath = fs.getDir(currentPath)

    LoadDirectory()
    Explorer.Draw()
end

local function OpenEntry(entry)
    if not entry or menuOpen or inputMode then
        return
    end

    if entry.isDir then
        currentPath = entry.path
        LoadDirectory()
    else
        selectedEntry = entry
        message = "Selected: " .. entry.name
    end

    Explorer.Draw()
end

--------------------------------------------------
-- CREATE FILE
--------------------------------------------------

local function CreateFile(name)
    if not IsValidName(name) then
        message = "Invalid file name"
        return
    end

    local path = fs.combine(ResolvePath(currentPath), name)

    if Storage.Exists(path) then
        message = "That name already exists"
        return
    end

    local ok, fileOrError = pcall(Storage.Open, path, "w")

    if not ok or not fileOrError then
        message = "Create failed: " .. tostring(fileOrError)
        return
    end

    local file = fileOrError
    local closeOK, closeError = pcall(function()
        file.close()
    end)

    if not closeOK then
        message = "Close failed: " .. tostring(closeError)
        return
    end

    message = "Created file: " .. name
    LoadDirectory()
end

--------------------------------------------------
-- CREATE FOLDER
--------------------------------------------------

local function CreateFolder(name)
    if not IsValidName(name) then
        message = "Invalid folder name"
        return
    end

    local path = fs.combine(ResolvePath(currentPath), name)

    if Storage.Exists(path) then
        message = "That name already exists"
        return
    end

    local ok, err = Storage.MakeDir(path)

    if not ok then
        message = "Create failed: " .. tostring(err)
    else
        message = "Created folder: " .. name
        LoadDirectory()
    end
end

--------------------------------------------------
-- RENAME
--------------------------------------------------

local function RenameEntry(entry, newName)
    if not entry or not IsValidName(newName) then
        message = "Invalid name"
        return
    end

    local parent = fs.getDir(entry.path)
    local newPath = fs.combine(parent, newName)

    if newPath == entry.path then
        message = "Name unchanged"
        return
    end

    if IsInsidePath(newPath, entry.path) then
        message = "Cannot move a folder into itself"
        return
    end

    if Storage.Exists(newPath) then
        message = "That name already exists"
        return
    end

    local ok, err = Storage.Move(entry.path, newPath)

    if not ok then
        message = "Rename failed: " .. tostring(err)
    else
        message = "Renamed to " .. newName
        LoadDirectory()
    end
end

--------------------------------------------------
-- TRASH
--------------------------------------------------

local function MoveToTrash(entry)
    if not entry then
        message = "Nothing selected"
        return
    end

    local source = ResolvePath(entry.path)
    local trash = ResolvePath(trashPath)

    if source == trash or IsInsidePath(source, trash) then
        message = "Item is already in Trash"
        return
    end

    if IsInsidePath(trash, source) then
        message = "Cannot move a folder containing Trash"
        return
    end

    local ensureOK, ensureError = EnsurePath(trashPath)

    if not ensureOK then
        message = "Trash unavailable: " .. tostring(ensureError)
        return
    end

    if not Storage.Exists(source) then
        message = "Source item no longer exists"
        return
    end

    local destination = fs.combine(trashPath, entry.name)
    local counter = 1

    while Storage.Exists(destination) do
        destination = fs.combine(
            trashPath,
            entry.name .. " (" .. counter .. ")"
        )

        counter = counter + 1
    end

    local ok, err = Storage.Move(source, destination)

    if ok then
        selectedEntry = nil
        message = "Moved to Trash: " .. entry.name
        LoadDirectory()
    else
        message = "Trash failed: " .. tostring(err)
    end
end

--------------------------------------------------
-- RESTORE
--------------------------------------------------

local function RestoreEntry(entry)
    if not entry then
        message = "Nothing selected"
        return
    end

    if not IsInTrash() then
        message = "Restore is only available in Trash"
        return
    end

    local destination = fs.combine(homePath, entry.name)
    local counter = 1

    while Storage.Exists(destination) do
        destination = fs.combine(
            homePath,
            entry.name .. " (restored " .. counter .. ")"
        )

        counter = counter + 1
    end

    local ok, err = Storage.Move(entry.path, destination)

    if ok then
        selectedEntry = nil
        message = "Restored to UserData: " .. entry.name
        LoadDirectory()
    else
        message = "Restore failed: " .. tostring(err)
    end
end

--------------------------------------------------
-- PERMANENT DELETE
--------------------------------------------------

local function PermanentlyDelete(entry)
    if not entry then
        message = "Nothing selected"
        return
    end

    local ok, err = Storage.Delete(entry.path)

    if ok then
        selectedEntry = nil
        message = "Permanently deleted: " .. entry.name
        LoadDirectory()
    else
        message = "Delete failed: " .. tostring(err)
    end
end

local function StartDeleteConfirmation(entry)
    if not entry then
        CloseMenu()
        message = "Nothing selected"
        Explorer.Draw()
        return
    end

    menuEntry = entry
    menuOpen = true

    menuItems = {
        {
            label = "Yes, delete",
            action = function()
                local target = menuEntry
                CloseMenu()
                PermanentlyDelete(target)
                Explorer.Draw()
            end
        },
        {
            label = "Cancel",
            action = function()
                CloseMenu()
                Explorer.Draw()
            end
        }
    }

    Explorer.Draw()
end

--------------------------------------------------
-- CONTEXT MENU
--------------------------------------------------

ShowContextMenu = function(x, y, entry)
    menuEntry = entry
    menuOpen = true
    menuItems = {}

    if entry then
        table.insert(menuItems, {
            label = "Open",
            action = function()
                local target = menuEntry
                CloseMenu()
                OpenEntry(target)
            end
        })

        if not entry.isDir then
            table.insert(menuItems, {
                label = "Open with >",
                action = function()
                    ShowOpenWithMenu(menuEntry)
                end
            })
        end

        table.insert(menuItems, {
            label = "Rename",
            action = function()
                local target = menuEntry

                if target then
                    BeginInput("Rename", function(value)
                        RenameEntry(target, value)
                        Explorer.Draw()
                    end, target.name)
                end
            end
        })

        if IsInTrash() then
            table.insert(menuItems, {
                label = "Restore",
                action = function()
                    local target = menuEntry
                    CloseMenu()
                    RestoreEntry(target)
                    Explorer.Draw()
                end
            })
        else
            table.insert(menuItems, {
                label = "Move to Trash",
                action = function()
                    local target = menuEntry
                    CloseMenu()
                    MoveToTrash(target)
                    Explorer.Draw()
                end
            })
        end

        table.insert(menuItems, {
            label = "Delete permanently",
            action = function()
                StartDeleteConfirmation(menuEntry)
            end
        })
    end

    table.insert(menuItems, {
        label = "New file",
        action = function()
            BeginInput("New file name", function(value)
                CreateFile(value)
                Explorer.Draw()
            end)
        end
    })

    table.insert(menuItems, {
        label = "New folder",
        action = function()
            BeginInput("New folder name", function(value)
                CreateFolder(value)
                Explorer.Draw()
            end)
        end
    })

    table.insert(menuItems, {
        label = "Cancel",
        action = function()
            CloseMenu()
            Explorer.Draw()
        end
    })

    local width, height = term.getSize()
    local actualWidth = math.min(menuWidth, width)

    menuX = math.max(1, math.min(x, width - actualWidth + 1))
    menuY = math.max(2, math.min(y, height - #menuItems))

    Explorer.Draw()
end

--------------------------------------------------
-- OPEN WITH MENU
--------------------------------------------------

ShowOpenWithMenu = function(entry)
    if not entry or entry.isDir then
        return
    end

    menuEntry = entry
    menuOpen = true
    menuItems = {}

    local apps = {}

    if App and type(App.List) == "function" then
        local ok, result = pcall(App.List)

        if ok and type(result) == "table" then
            for _, app in ipairs(result) do
                local name

                if type(app) == "string" then
                    name = app
                elseif type(app) == "table" then
                    name = app.name or app.title or app.id
                end

                if type(name) == "string" and name ~= "" then
                    apps[#apps + 1] = name
                end
            end
        end
    end

    table.sort(apps, function(a, b)
        return a:lower() < b:lower()
    end)

    table.insert(menuItems, {
        label = "< Back",
        action = function()
            ShowContextMenu(menuX, menuY, menuEntry)
        end
    })

    for _, appName in ipairs(apps) do
        local selectedAppName = appName

        table.insert(menuItems, {
            label = selectedAppName,
            action = function()
                local target = menuEntry
                CloseMenu()

                if not target then
                    return
                end

                -- This is the logical path. Apps that open user files
                -- must use Storage.Open() to read unified-storage files.
                _G.OrisOS_OpenFile = target.path

                local ok, err = pcall(function()
                    App.Launch(selectedAppName)
                end)

                if not ok then
                    _G.OrisOS_OpenFile = nil
                    message = "Could not launch " .. selectedAppName
                        .. ": " .. tostring(err)
                    Explorer.Draw()
                end
            end
        })
    end

    if #apps == 0 then
        table.insert(menuItems, {
            label = "No apps found",
            action = function()
                CloseMenu()
                message = "No apps found"
                Explorer.Draw()
            end
        })
    end

    local width, height = term.getSize()
    local actualWidth = math.min(menuWidth, width)

    menuX = math.max(1, math.min(menuX, width - actualWidth + 1))
    menuY = math.max(2, math.min(menuY, height - #menuItems))

    Explorer.Draw()
end

--------------------------------------------------
-- SCROLLING
--------------------------------------------------

local function Scroll(amount)
    if menuOpen or inputMode then
        return
    end

    local maxOffset = math.max(0, #entries - pageSize)

    scrollOffset = math.max(
        0,
        math.min(maxOffset, scrollOffset + amount)
    )

    Explorer.Draw()
end

--------------------------------------------------
-- INITIALIZATION
--------------------------------------------------

function Explorer.Init(appModule, mouseModule)
    App = appModule
    Mouse = mouseModule

    if Storage.Refresh then
        local ok, result = pcall(Storage.Refresh)

        if not ok then
            message = "Storage initialization failed: " .. tostring(result)
        end
    end

    local requiredPaths = {
        homePath,
        trashPath,
        documentsPath,
        downloadsPath
    }

    for _, path in ipairs(requiredPaths) do
        local ok, err = EnsurePath(path)

        if not ok then
            message = "Storage setup failed: " .. tostring(err)
            break
        end
    end

    LoadDirectory()
end

--------------------------------------------------
-- DRAW
--------------------------------------------------

function Explorer.Draw()
    ClearClickAreas()

    local width, height = term.getSize()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    -- Navigation bar
    term.setCursorPos(1, 2)
    term.setBackgroundColor(colors.lightGray)
    term.setTextColor(colors.white)
    term.clearLine()

    WriteClipped(1, 2, " Back ", width)

    RegisterButton(1, 2, 6, 1, function()
        if selectedEntry and not selectedEntry.isDir then
            selectedEntry = nil
            message = #entries .. " item(s)"
            Explorer.Draw()
        else
            GoUp()
        end
    end)

    WriteClipped(8, 2, " Up ", math.max(0, width - 7))
    RegisterButton(8, 2, 4, 1, GoUp)

    WriteClipped(14, 2, " Trash ", math.max(0, width - 13))
    RegisterButton(14, 2, 7, 1, function()
        currentPath = trashPath
        CloseMenu()
        LoadDirectory()
        Explorer.Draw()
    end)

    WriteClipped(21, 2, " Documents ", math.max(0, width - 20))
    RegisterButton(21, 2, 11, 1, function()
        currentPath = documentsPath
        CloseMenu()
        LoadDirectory()
        Explorer.Draw()
    end)

    WriteClipped(32, 2, " Downloads ", math.max(0, width - 31))
    RegisterButton(32, 2, 11, 1, function()
        currentPath = downloadsPath
        CloseMenu()
        LoadDirectory()
        Explorer.Draw()
    end)

    -- Current path
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    term.setCursorPos(1, 3)
    term.clearLine()
    term.write(DisplayPath():sub(1, width))

    -- File list
    pageSize = math.max(0, height - rowStart)

    local visibleCount = math.min(
        pageSize,
        math.max(0, #entries - scrollOffset)
    )

    for i = 1, visibleCount do
        local entryIndex = i + scrollOffset
        local entry = entries[entryIndex]
        local y = rowStart + i - 1

        local prefix = entry.isDir and "[D] " or "[F] "
        local sizeText = entry.isDir and "" or FormatSize(entry.size)

        local sizeWidth = #sizeText
        local nameWidth = math.max(1, width - sizeWidth - 1)
        local displayName = (prefix .. entry.name):sub(1, nameWidth)
        local padding = math.max(0, width - #displayName - sizeWidth)

        local line = displayName
            .. string.rep(" ", padding)
            .. sizeText

        term.setCursorPos(1, y)
        term.setBackgroundColor(
            selectedEntry == entry and colors.blue or colors.black
        )
        term.setTextColor(colors.white)
        term.write(line:sub(1, width))

        if not menuOpen then
            local clickedEntry = entry
            local clickedY = y

            RegisterArea(1, clickedY, width, 1, function(button)
                if menuOpen or inputMode then
                    return
                end

                if button == 1 then
                    OpenEntry(clickedEntry)
                elseif button == 2 then
                    selectedEntry = clickedEntry
                    ShowContextMenu(2, clickedY, clickedEntry)
                end
            end)
        end
    end

    -- Right-click empty space for create actions.
    for y = rowStart + visibleCount, height - 1 do
        if y >= rowStart and not menuOpen then
            local clickedY = y

            RegisterArea(1, clickedY, width, 1, function(button)
                if menuOpen or inputMode then
                    return
                end

                if button == 2 then
                    selectedEntry = nil
                    ShowContextMenu(2, clickedY, nil)
                end
            end)
        end
    end

    -- Status bar
    term.setCursorPos(1, height)
    term.setBackgroundColor(colors.lightGray)
    term.setTextColor(colors.white)
    term.clearLine()

    if inputMode then
        term.write((inputLabel .. ": " .. inputText):sub(1, width))
    else
        term.write(tostring(message):sub(1, width))
    end

    -- Context menu
    if menuOpen then
        local menuHeight = #menuItems
        local actualWidth = math.min(menuWidth, width)
        local actualX = math.max(1, math.min(menuX, width - actualWidth + 1))
        local actualY = math.max(2, math.min(menuY, height - menuHeight))

        for i, item in ipairs(menuItems) do
            local y = actualY + i - 1

            if y < height then
                term.setCursorPos(actualX, y)
                term.setBackgroundColor(colors.gray)
                term.setTextColor(colors.white)

                local label = item.label:sub(1, actualWidth)
                term.write(label)

                if #label < actualWidth then
                    term.write(string.rep(" ", actualWidth - #label))
                end

                local selectedItem = item

                RegisterArea(actualX, y, actualWidth, 1, function(button)
                    if button == 1 and menuOpen then
                        selectedItem.action()
                    end
                end)
            end
        end
    end

    -- Input cursor
    if inputMode then
        local cursorX = math.min(width, #inputLabel + #inputText + 3)

        term.setCursorPos(math.max(1, cursorX), height)
        term.setCursorBlink(true)
    else
        term.setCursorBlink(false)
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

--------------------------------------------------
-- EVENTS
--------------------------------------------------

function Explorer.HandleEvent(event, p1, p2)
    if inputMode then
        if event == "char" then
            inputText = inputText .. tostring(p1)
            Explorer.Draw()

        elseif event == "key" then
            if p1 == keys.backspace then
                inputText = inputText:sub(1, -2)
                Explorer.Draw()

            elseif p1 == keys.enter then
                local value = inputText
                local action = pendingAction

                inputMode = false
                pendingAction = nil
                inputText = ""

                if action then
                    local ok, err = pcall(action, value)

                    if not ok then
                        message = "Action failed: " .. tostring(err)
                    end
                end

                Explorer.Draw()

            elseif p1 == keys.escape then
                inputMode = false
                pendingAction = nil
                inputText = ""
                message = "Cancelled"
                Explorer.Draw()
            end
        end

        return
    end

    if event == "key" then
        if p1 == keys.backspace then
            if menuOpen then
                CloseMenu()
                Explorer.Draw()
            else
                GoUp()
            end

        elseif p1 == keys.enter and selectedEntry then
            OpenEntry(selectedEntry)

        elseif p1 == keys.up then
            Scroll(-1)

        elseif p1 == keys.down then
            Scroll(1)

        elseif p1 == keys.escape and menuOpen then
            CloseMenu()
            Explorer.Draw()
        end

    elseif event == "mouse_scroll" then
        Scroll(p1)
    end
end

return Explorer
