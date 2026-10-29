
local Terminal = {}

local App
local Mouse

local currentDir = ""
local input = ""
local history = {}
local historyIndex = 1

local scrollOffset = 0
local output = {}

local REPO_CONFIG = "OrisOS/UserData/repository.txt"
local DOWNLOADS_DIR = "OrisOS/UserData/Downloads"
local USER_APPS_DIR = "OrisOS/UserData/UserApps"

local terminalColors = {
    title = colors.cyan,
    command = colors.lime,
    success = colors.green,
    error = colors.red,
    warning = colors.yellow,
    info = colors.lightBlue,
    normal = colors.white,
    directory = colors.blue
}

local function AddOutput(text, color)
    text = tostring(text or "")
    color = color or terminalColors.normal

    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(output, {
            text = line,
            color = color
        })
    end

    scrollOffset = 0
end

local function Trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$")
end

local function ResolvePath(path)
    path = path or "."

    if path:sub(1, 1) == "/" then
        return fs.combine("/", path)
    end

    return fs.combine(currentDir, path)
end

local function GetDisplayPath()
    if currentDir == "" then
        return "/"
    end

    return "/" .. currentDir
end

local function ValidURL(url)
    return type(url) == "string"
        and (url:match("^https://") ~= nil
        or url:match("^http://") ~= nil)
end

local function GetFilename(url)
    url = url:gsub("[?#].*$", ""):gsub("/+$", "")

    local filename = url:match("([^/]+)$")

    if not filename or filename == "" then
        return "download.txt"
    end

    filename = filename:gsub("[^%w%._%-]", "_")

    if filename == "" or filename == "." or filename == ".." then
        return "download.txt"
    end

    return filename
end

local function EnsureDirectory(path)
    if fs.exists(path) then
        return fs.isDir(path)
    end

    local ok = pcall(fs.makeDir, path)
    return ok and fs.exists(path) and fs.isDir(path)
end

local function ReadFile(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil, "File not found: " .. path
    end

    local ok, result = pcall(function()
        local file = fs.open(path, "r")

        if not file then
            error("Could not open file")
        end

        local content = file.readAll()
        file.close()

        return content
    end)

    if not ok then
        return nil, tostring(result)
    end

    return result
end

local function SaveFile(path, content, overwrite)
    if fs.exists(path) and not overwrite then
        return false, "File already exists: " .. path
    end

    if fs.exists(path) and fs.isDir(path) then
        return false, "Destination is a directory: " .. path
    end

    local parent = fs.getDir(path)

    if parent ~= "" and not EnsureDirectory(parent) then
        return false, "Could not create directory: " .. parent
    end

    local ok, err = pcall(function()
        local file = fs.open(path, "w")

        if not file then
            error("Could not open destination")
        end

        file.write(content)
        file.close()
    end)

    if not ok then
        return false, tostring(err)
    end

    return true, path
end

local function HTTPGet(url)
    if not ValidURL(url) then
        return nil, "URL must start with http:// or https://"
    end

    if not http or not http.get then
        return nil, "HTTP unavailable. Enable HTTP in your computer settings."
    end

    local ok, response, err = pcall(http.get, url)

    if not ok then
        return nil, tostring(response)
    end

    if not response then
        return nil, tostring(err or "Request failed")
    end

    local readOK, content = pcall(function()
        return response.readAll()
    end)

    pcall(function()
        response.close()
    end)

    if not readOK then
        return nil, tostring(content)
    end

    return content
end

-- Repository configuration

local function LoadRepositoryURL()
    local content = ReadFile(REPO_CONFIG)

    if content then
        content = Trim(content)

        if ValidURL(content) then
            return content
        end
    end

    return nil
end

local function ParseRepository(content)
    local apps = {}

    for line in (content .. "\n"):gmatch("(.-)\n") do
        line = Trim(line)

        if line ~= "" and line:sub(1, 1) ~= "#" then
            local name, url, description =
                line:match("^([^|]+)|([^|]+)|?(.*)$")

            if name and url then
                name = Trim(name)
                url = Trim(url)
                description = Trim(description)

                if name:match("^[%w_%-]+$") and ValidURL(url) then
                    table.insert(apps, {
                        name = name,
                        url = url,
                        description = description
                    })
                end
            end
        end
    end

    table.sort(apps, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    return apps
end

local function FetchRepository()
    local url = LoadRepositoryURL()

    if not url then
        return nil, "No repository configured. Use: repo set <manifest-url>"
    end

    AddOutput("Fetching app repository...", terminalColors.info)

    local content, err = HTTPGet(url)

    if not content then
        return nil, "Repository request failed: " .. tostring(err)
    end

    return ParseRepository(content)
end

local function FindRepositoryApp(apps, name)
    for _, item in ipairs(apps) do
        if item.name:lower() == name:lower() then
            return item
        end
    end

    return nil
end

-- Web downloads always go into the Downloads directory.
-- The optional destination is treated as a filename, not a path.

local function DownloadFile(url, destination)
    if not ValidURL(url) then
        AddOutput("Invalid URL. Use http:// or https://", terminalColors.error)
        return
    end

    if not EnsureDirectory(DOWNLOADS_DIR) then
        AddOutput("Could not create Downloads directory.", terminalColors.error)
        return
    end

    local filename = destination or GetFilename(url)
    filename = fs.getName(filename)

    if filename == "" or filename == "." or filename == ".." then
        AddOutput("Invalid filename.", terminalColors.error)
        return
    end

    local path = fs.combine(DOWNLOADS_DIR, filename)

    if fs.exists(path) then
        AddOutput("File already exists: " .. path, terminalColors.warning)
        AddOutput("Remove or rename it before downloading again.", terminalColors.info)
        return
    end

    AddOutput("Downloading...", terminalColors.info)
    AddOutput(url, terminalColors.info)

    local content, err = HTTPGet(url)

    if not content then
        AddOutput("Download failed: " .. tostring(err), terminalColors.error)
        return
    end

    local ok, result = SaveFile(path, content, false)

    if not ok then
        AddOutput("Save failed: " .. tostring(result), terminalColors.error)
        return
    end

    AddOutput("Download complete!", terminalColors.success)
    AddOutput("Saved to: " .. result, terminalColors.info)
    AddOutput("Bytes received: " .. #content, terminalColors.info)
end

-- App repository installer

local function InstallRepositoryApp(name)
    if not name or name == "" then
        AddOutput("Usage: repo install <app-name>", terminalColors.warning)
        return
    end

    if not name:match("^[%w_%-]+$") then
        AddOutput("Invalid app name.", terminalColors.error)
        return
    end

    local apps, err = FetchRepository()

    if not apps then
        AddOutput(err, terminalColors.error)
        return
    end

    local item = FindRepositoryApp(apps, name)

    if not item then
        AddOutput("App not found: " .. name, terminalColors.error)
        return
    end

    if not EnsureDirectory(USER_APPS_DIR) then
        AddOutput("Could not create UserApps directory.", terminalColors.error)
        return
    end

    local destination = fs.combine(USER_APPS_DIR, item.name .. ".lua")

    if fs.exists(destination) then
        AddOutput("App already installed: " .. destination, terminalColors.warning)
        AddOutput("Remove the existing file before reinstalling.", terminalColors.info)
        return
    end

    AddOutput("Downloading " .. item.name .. "...", terminalColors.info)

    local content, downloadErr = HTTPGet(item.url)

    if not content then
        AddOutput("Download failed: " .. tostring(downloadErr), terminalColors.error)
        return
    end

    if Trim(content) == "" then
        AddOutput("Downloaded app file is empty.", terminalColors.error)
        return
    end

    local ok, result = SaveFile(destination, content, false)

    if not ok then
        AddOutput("Installation failed: " .. tostring(result), terminalColors.error)
        return
    end

    AddOutput("Installed " .. item.name .. "!", terminalColors.success)
    AddOutput("Location: " .. result, terminalColors.info)
    AddOutput("Apps must be loaded from UserApps to launch.", terminalColors.warning)
end

local function RunRepoCommand(args)
    local action = (table.remove(args, 1) or "list"):lower()

    if action == "set" then
        local url = args[1]

        if not url or not ValidURL(url) then
            AddOutput("Usage: repo set <manifest-url>", terminalColors.warning)
            return
        end

        AddOutput("Checking repository...", terminalColors.info)

        local content, err = HTTPGet(url)

        if not content then
            AddOutput("Could not access repository: " .. tostring(err), terminalColors.error)
            return
        end

        if not EnsureDirectory(fs.getDir(REPO_CONFIG)) then
            AddOutput("Could not create repository config directory.", terminalColors.error)
            return
        end

        local ok, saveErr = SaveFile(REPO_CONFIG, url, true)

        if not ok then
            AddOutput("Could not save repository: " .. tostring(saveErr), terminalColors.error)
            return
        end

        AddOutput("Repository configured.", terminalColors.success)
        AddOutput("Apps found: " .. #ParseRepository(content), terminalColors.info)

    elseif action == "url" then
        local url = LoadRepositoryURL()

        if url then
            AddOutput("Repository: " .. url, terminalColors.info)
        else
            AddOutput("No repository configured.", terminalColors.warning)
        end

    elseif action == "list" then
        local apps, err = FetchRepository()

        if not apps then
            AddOutput(err, terminalColors.error)
            return
        end

        if #apps == 0 then
            AddOutput("No apps found.", terminalColors.warning)
            return
        end

        AddOutput("Available apps:", terminalColors.title)

        for _, item in ipairs(apps) do
            AddOutput(item.name, terminalColors.success)

            if item.description ~= "" then
                AddOutput("  " .. item.description, terminalColors.normal)
            end
        end

    elseif action == "install" then
        InstallRepositoryApp(table.concat(args, " "))

    elseif action == "info" then
        local name = table.concat(args, " ")

        if name == "" then
            AddOutput("Usage: repo info <name>", terminalColors.warning)
            return
        end

        local apps, err = FetchRepository()

        if not apps then
            AddOutput(err, terminalColors.error)
            return
        end

        local item = FindRepositoryApp(apps, name)

        if not item then
            AddOutput("App not found: " .. name, terminalColors.error)
            return
        end

        AddOutput("App: " .. item.name, terminalColors.title)
        AddOutput("Description: " .. item.description)
        AddOutput("URL: " .. item.url, terminalColors.info)

    else
        AddOutput("Repository commands:", terminalColors.title)
        AddOutput("  repo set <url>")
        AddOutput("  repo url")
        AddOutput("  repo list")
        AddOutput("  repo info <name>")
        AddOutput("  repo install <name>")
    end
end

-- Terminal commands

local function RunCommand(command)
    command = Trim(command)

    if command == "" then
        return false
    end

    table.insert(history, command)
    historyIndex = #history + 1

    AddOutput(GetDisplayPath() .. "> " .. command, terminalColors.command)

    local args = {}

    for word in command:gmatch("%S+") do
        table.insert(args, word)
    end

    local cmd = (table.remove(args, 1) or ""):lower()

    if cmd == "help" then
        AddOutput("Welcome to OrisOS Terminal!", terminalColors.title)
        AddOutput("Filesystem:", terminalColors.info)
        AddOutput("  ls [path]          List files")
        AddOutput("  cd <path>          Change directory")
        AddOutput("  pwd                Show current directory")
        AddOutput("  mkdir <name>       Create directory")
        AddOutput("  rm <file>          Delete file")
        AddOutput("  rmdir <directory>  Delete directory")
        AddOutput("  cat <file>         Display text file")
        AddOutput("  clear              Clear output")
        AddOutput("  echo <text>        Print text")
        AddOutput("System:", terminalColors.info)
        AddOutput("  apps               List installed apps")
        AddOutput("  launch <name>      Launch an app")
        AddOutput("  date               Show in-game time")
        AddOutput("  whoami             Show user")
        AddOutput("  exit               Close terminal")
        AddOutput("  reboot             Reboot computer")
        AddOutput("  shutdown           Shut down computer")
        AddOutput("Downloads:", terminalColors.info)
        AddOutput("  download <url> [filename]")
        AddOutput("  repo set <url>")
        AddOutput("  repo list")
        AddOutput("  repo info <name>")
        AddOutput("  repo install <name>")
        AddOutput("  repo url")

    elseif cmd == "clear" then
        output = {}
        scrollOffset = 0

    elseif cmd == "echo" then
        AddOutput(table.concat(args, " "), terminalColors.normal)

    elseif cmd == "pwd" then
        AddOutput(GetDisplayPath(), terminalColors.info)

    elseif cmd == "date" then
        AddOutput(textutils.formatTime(os.time(), false), terminalColors.info)

    elseif cmd == "whoami" then
        AddOutput("OrisOS user", terminalColors.success)

    elseif cmd == "ls" or cmd == "dir" then
        local path = ResolvePath(args[1] or ".")

        if not fs.exists(path) then
            AddOutput("Path not found: " .. path, terminalColors.error)
            return false
        end

        if not fs.isDir(path) then
            AddOutput("Not a directory: " .. path, terminalColors.error)
            return false
        end

        local ok, files = pcall(fs.list, path)

        if not ok then
            AddOutput("Could not list directory: " .. tostring(files), terminalColors.error)
            return false
        end

        table.sort(files)

        if #files == 0 then
            AddOutput("(empty directory)", terminalColors.warning)
        else
            for _, file in ipairs(files) do
                local fullPath = fs.combine(path, file)

                if fs.isDir(fullPath) then
                    AddOutput(file .. "/", terminalColors.directory)
                else
                    AddOutput(file, terminalColors.normal)
                end
            end
        end

    elseif cmd == "cd" then
        local path = ResolvePath(args[1] or "/")

        if fs.exists(path) and fs.isDir(path) then
            currentDir = path
            AddOutput("Directory changed to " .. GetDisplayPath(), terminalColors.success)
        else
            AddOutput("Directory not found: " .. path, terminalColors.error)
        end

    elseif cmd == "mkdir" then
        if not args[1] then
            AddOutput("Usage: mkdir <name>", terminalColors.warning)
        else
            local path = ResolvePath(args[1])

            if fs.exists(path) then
                AddOutput("Path already exists: " .. path, terminalColors.warning)
            else
                local ok, err = pcall(fs.makeDir, path)

                if ok then
                    AddOutput("Created directory: " .. path, terminalColors.success)
                else
                    AddOutput("Could not create directory: " .. tostring(err), terminalColors.error)
                end
            end
        end

    elseif cmd == "rm" then
        if not args[1] then
            AddOutput("Usage: rm <file>", terminalColors.warning)
        else
            local path = ResolvePath(args[1])

            if not fs.exists(path) then
                AddOutput("File not found: " .. path, terminalColors.error)
            elseif fs.isDir(path) then
                AddOutput("That is a directory. Use rmdir.", terminalColors.warning)
            else
                local ok, err = pcall(fs.delete, path)

                if ok then
                    AddOutput("Deleted " .. path, terminalColors.success)
                else
                    AddOutput("Delete failed: " .. tostring(err), terminalColors.error)
                end
            end
        end

    elseif cmd == "rmdir" then
        if not args[1] then
            AddOutput("Usage: rmdir <directory>", terminalColors.warning)
        else
            local path = ResolvePath(args[1])

            if not fs.exists(path) or not fs.isDir(path) then
                AddOutput("Directory not found: " .. path, terminalColors.error)
            elseif path == "" or path == "/" then
                AddOutput("Refusing to remove the root directory.", terminalColors.error)
            else
                local ok, err = pcall(fs.delete, path)

                if ok then
                    AddOutput("Removed directory: " .. path, terminalColors.success)
                else
                    AddOutput("Remove failed: " .. tostring(err), terminalColors.error)
                end
            end
        end

    elseif cmd == "cat" then
        if not args[1] then
            AddOutput("Usage: cat <file>", terminalColors.warning)
        else
            local content, err = ReadFile(ResolvePath(args[1]))

            if not content then
                AddOutput(err, terminalColors.error)
            else
                for line in (content .. "\n"):gmatch("(.-)\n") do
                    AddOutput(line, terminalColors.normal)
                end
            end
        end

    elseif cmd == "download" or cmd == "wget" then
        if not args[1] then
            AddOutput("Usage: download <url> [filename]", terminalColors.warning)
        else
            DownloadFile(args[1], args[2])
        end

    elseif cmd == "repo" then
        RunRepoCommand(args)

    elseif cmd == "apps" then
        local names = App.List()

        AddOutput("Installed apps:", terminalColors.title)

        for _, name in ipairs(names) do
            AddOutput("  " .. name, terminalColors.info)
        end

    elseif cmd == "launch" then
        local name = table.concat(args, " ")

        if name == "" then
            AddOutput("Usage: launch <app name>", terminalColors.warning)
        elseif name == "Terminal" then
            AddOutput("Terminal is already running.", terminalColors.warning)
        else
            local ok, err = App.Launch(name)

            if not ok then
                AddOutput(err or "Could not launch app.", terminalColors.error)
            end
        end

    elseif cmd == "exit" then
        App.Close()
        return true

    elseif cmd == "reboot" then
        AddOutput("Rebooting...", terminalColors.warning)
        Terminal.Draw()
        os.reboot()
        return true

    elseif cmd == "shutdown" then
        AddOutput("Shutting down...", terminalColors.warning)
        Terminal.Draw()
        os.shutdown()
        return true

    else
        AddOutput("Unknown command: " .. cmd, terminalColors.error)
        AddOutput("Type 'help' for available commands.", terminalColors.info)
    end

    return false
end

function Terminal.Init(appModule, mouseModule)
    App = appModule
    Mouse = mouseModule

    if #output == 0 then
        AddOutput("Welcome to OrisOS!", terminalColors.title)
        AddOutput("Terminal ready. Type 'help' for commands.", terminalColors.info)
    end
end

function Terminal.Draw()
    local width, height = term.getSize()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    -- Greeting header
    term.setCursorPos(1, 1)
    term.setTextColor(terminalColors.title)
    term.write(("OrisOS Terminal"):sub(1, width))

    term.setCursorPos(1, 2)
    term.setTextColor(terminalColors.info)
    term.write(("Current directory: " .. GetDisplayPath()):sub(1, width))

    -- Scrollable output region
    local firstOutputRow = 4
    local lastOutputRow = height - 1
    local visibleLines = math.max(0, lastOutputRow - firstOutputRow + 1)
    local maxOffset = math.max(0, #output - visibleLines)

    scrollOffset = math.max(0, math.min(scrollOffset, maxOffset))

    local endLine = math.max(0, #output - scrollOffset)
    local startLine = math.max(1, endLine - visibleLines + 1)

    local y = firstOutputRow

    for i = startLine, endLine do
        if y > lastOutputRow then
            break
        end

        local line = output[i]
        local text = type(line) == "table" and tostring(line.text or "") or tostring(line)
        local color = type(line) == "table" and (line.color or terminalColors.normal) or terminalColors.normal

        term.setCursorPos(1, y)
        term.setBackgroundColor(colors.black)
        term.setTextColor(color)
        term.write(text:sub(1, width))

        y = y + 1
    end

    -- Input line
    term.setCursorPos(1, height)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()

    local prompt = GetDisplayPath() .. "> "
    local shownPrompt = prompt:sub(1, width)
    local available = math.max(0, width - #shownPrompt)
    local shownInput = available > 0 and input:sub(-available) or ""

    term.setCursorPos(1, height)
    term.setTextColor(terminalColors.success)
    term.write(shownPrompt)

    term.setTextColor(colors.white)
    term.write(shownInput)

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

function Terminal.HandleEvent(event, p1)
    if event == "char" then
        input = input .. p1
        Terminal.Draw()

    elseif event == "paste" then
        input = input .. p1
        Terminal.Draw()

    elseif event == "key" then
        if p1 == keys.enter then
            local command = input
            input = ""

            local closed = RunCommand(command)

            if not closed and App.GetCurrent() == "Terminal" then
                Terminal.Draw()
            end

        elseif p1 == keys.backspace then
            input = input:sub(1, -2)
            Terminal.Draw()

        elseif p1 == keys.up then
            -- Scroll output upward first; if already at the top,
            -- use command history.
            local _, height = term.getSize()
            local visibleLines = math.max(0, height - 4)

            if scrollOffset < #output - visibleLines then
                scrollOffset = scrollOffset + 1
            elseif historyIndex > 1 then
                historyIndex = historyIndex - 1
                input = history[historyIndex] or ""
            end

            Terminal.Draw()

        elseif p1 == keys.down then
            if scrollOffset > 0 then
                scrollOffset = scrollOffset - 1
            else
                if historyIndex < #history then
                    historyIndex = historyIndex + 1
                    input = history[historyIndex] or ""
                else
                    historyIndex = #history + 1
                    input = ""
                end
            end

            Terminal.Draw()

        elseif p1 == keys.pageUp then
            local _, height = term.getSize()
            scrollOffset = math.min(
                math.max(0, #output - math.max(0, height - 4)),
                scrollOffset + math.max(1, height - 4)
            )
            Terminal.Draw()

        elseif p1 == keys.pageDown then
            local _, height = term.getSize()
            scrollOffset = math.max(0, scrollOffset - math.max(1, height - 4))
            Terminal.Draw()

        elseif p1 == keys.home then
            local _, height = term.getSize()
            scrollOffset = math.max(0, #output - math.max(0, height - 4))
            Terminal.Draw()

        elseif p1 == keys["end"] then
            scrollOffset = 0
            Terminal.Draw()
        end
    end
end

return Terminal
