local Calculator = {}

local expr = ""
local result = ""
local errorMsg = ""

local function Calculate()
    if expr == "" then
        result = ""
        errorMsg = ""
        return
    end

    -- Only allow calculator characters
    if expr:find("[^%d%+%-%*/%%%^%(%)%.%s]") then
        errorMsg = "Invalid expression"
        result = ""
        return
    end

    -- Use a parser instead of executing arbitrary Lua code
    local pos = 1
    local input = expr:gsub("%s+", "")

    local parseExpression
    local parseTerm
    local parseFactor
    local parseNumber

    local function peek()
        return input:sub(pos, pos)
    end

    local function consume(char)
        if peek() == char then
            pos = pos + 1
            return true
        end
        return false
    end

    parseExpression = function()
        local value = parseTerm()

        while true do
            if consume("+") then
                value = value + parseTerm()
            elseif consume("-") then
                value = value - parseTerm()
            else
                break
            end
        end

        return value
    end

    parseTerm = function()
        local value = parseFactor()

        while true do
            if consume("*") then
                value = value * parseFactor()
            elseif consume("/") then
                local divisor = parseFactor()
                if divisor == 0 then error("Division by zero") end
                value = value / divisor
            elseif consume("%") then
                local divisor = parseFactor()
                if divisor == 0 then error("Division by zero") end
                value = value % divisor
            else
                break
            end
        end

        return value
    end

    parseNumber = function()
        local start = pos
        local dots = 0

        while true do
            local c = peek()
            if c:match("%d") then
                pos = pos + 1
            elseif c == "." and dots == 0 then
                dots = dots + 1
                pos = pos + 1
            else
                break
            end
        end

        if start == pos then error("Expected a number") end

        local value = tonumber(input:sub(start, pos - 1))
        if not value then error("Invalid number") end
        return value
    end

    parseFactor = function()
        if consume("+") then
            return parseFactor()
        elseif consume("-") then
            return -parseFactor()
        elseif consume("(") then
            local value = parseExpression()
            if not consume(")") then error("Missing closing parenthesis") end
            return value
        end

        local value = parseNumber()

        if consume("^") then
            value = value ^ parseFactor()
        end

        return value
    end

    local ok, value = pcall(function()
        local answer = parseExpression()
        if pos <= #input then error("Unexpected character") end
        if value == math.huge or value == -math.huge then
            error("Result out of range")
        end
        return answer
    end)

    if not ok then
        errorMsg = tostring(value)
        result = ""
        return
    end

    if value ~= value then
        errorMsg = "Invalid result"
        result = ""
        return
    end

    errorMsg = ""
    result = tostring(value)
end

local function DrawButton(x, y, w, label, bg, fg)
    term.setCursorPos(x, y)
    term.setBackgroundColor(bg)
    term.setTextColor(fg)
    term.write(string.rep(" ", w))

    local textX = x + math.floor((w - #label) / 2)
    term.setCursorPos(textX, y)
    term.write(label)
end

function Calculator.Init()
    expr = ""
    result = ""
    errorMsg = ""
end

function Calculator.Draw()
    local width, height = term.getSize()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.blue)
    term.write(" OrisOS Calculator " .. string.rep(" ", math.max(0, width - 19)))

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 3)
    term.write("Expression:")

    term.setTextColor(colors.white)
    term.setCursorPos(2, 4)
    term.write(expr:sub(-math.max(1, width - 4)))

    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 6)
    term.write("Result:")

    term.setTextColor(colors.lime)
    term.setCursorPos(2, 7)
    term.write(result:sub(1, math.max(1, width - 4)))

    if errorMsg ~= "" then
        term.setTextColor(colors.red)
        term.setCursorPos(2, 8)
        term.write(errorMsg:sub(1, math.max(1, width - 4)))
    end

    local buttons = {
        {"C", "⌫", "(", ")"},
        {"7", "8", "9", "/"},
        {"4", "5", "6", "*"},
        {"1", "2", "3", "-"},
        {"0", ".", "%", "+"},
        {"^", "=", "AC", ""}
    }

    local buttonY = math.max(10, height - #buttons - 1)
    local buttonW = math.max(3, math.floor((width - 5) / 4))

    for row, items in ipairs(buttons) do
        for col, label in ipairs(items) do
            if label ~= "" then
                local x = 2 + (col - 1) * (buttonW + 1)
                local y = buttonY + row - 1

                if y <= height then
                    local bg = colors.gray
                    if label == "=" then bg = colors.green end
                    if label == "C" or label == "AC" then bg = colors.red end

                    DrawButton(x, y, buttonW, label, bg, colors.white)
                end
            end
        end
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, height)
    term.write("Type expression | Enter = calculate")
end

local function PressButton(label)
    if label == "=" then
        Calculate()
    elseif label == "C" then
        expr = expr:sub(1, -2)
        errorMsg = ""
    elseif label == "AC" then
        expr = ""
        result = ""
        errorMsg = ""
    elseif label == "⌫" then
        expr = expr:sub(1, -2)
        errorMsg = ""
    else
        expr = expr .. label
        errorMsg = ""
    end
end

function Calculator.HandleEvent(event, ...)
    local args = {...}

    if event == "char" then
        expr = expr .. args[1]
        errorMsg = ""
        Calculator.Draw()

    elseif event == "paste" then
        expr = expr .. args[1]
        errorMsg = ""
        Calculator.Draw()

    elseif event == "key" then
        local key = args[1]

        if key == keys.enter then
            Calculate()
        elseif key == keys.backspace then
            expr = expr:sub(1, -2)
            errorMsg = ""
        elseif key == keys.escape then
            expr = ""
            result = ""
            errorMsg = ""
        end

        Calculator.Draw()

    elseif event == "mouse_click" then
        local button, x, y = args[1], args[2], args[3]
        if button == 1 then
            local width, height = term.getSize()
            local buttons = {
                {"C", "DEL", "(", ")"},
                {"7", "8", "9", "/"},
                {"4", "5", "6", "*"},
                {"1", "2", "3", "-"},
                {"0", ".", "%", "+"},
                {"^", "=", "AC", ""}
            }

            local buttonY = math.max(10, height - #buttons - 1)
            local buttonW = math.max(3, math.floor((width - 5) / 4))

            local row = y - buttonY + 1
            local col = math.floor((x - 2) / (buttonW + 1)) + 1

            if row >= 1 and row <= #buttons and col >= 1 and col <= 4 then
                local label = buttons[row][col]
                if label ~= "" then
                    PressButton(label)
                end
            end
        end

        Calculator.Draw()
    end
end

return Calculator
