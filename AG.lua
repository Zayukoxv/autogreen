local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local RS          = game:GetService("ReplicatedStorage")
local lp          = game:GetService("Players").LocalPlayer

pcall(function() if _G.AGB_UNLOAD then _G.AGB_UNLOAD() end end)

local CFG = {
    ShootKey = 0x45,
    JumpKey  = 0x20,
    PeakY    = -1.475,
    Transit  = 0.015,
}
local CAL_FILE = "agb_calibration.json"

local S = {
    green      = true,
    cal        = true,
    offset     = 0,
    block      = true,
    blockrange = 10,
    blockdelay = 100,
}

local running = true
local conns, drawings = {}, {}
local ch, others = nil, {}
local shot = { active = false, armed = false, released = false, ver = 0 }
local network = { ping = nil, raw = nil, last = -1 }
local calibration, calDirty, calSavedAt = {}, false, -10
local blockAt, nextBlock, lastShotStart = nil, 0, {}
local Library

local function updatePing(now)
    if now - network.last < 0.2 then return end
    network.last = now
    local v = GetPingValue()
    if type(v) ~= "number" or v ~= v or v < 0 or v > 500 then return end
    network.raw = v
    network.ping = network.ping and (network.ping * 0.65 + v * 0.35) or v
end

local function calKey(space, speed, ping)
    local sb = math.floor((tonumber(speed) or 0) * 20 + 0.5) / 20
    local pb = math.floor((ping or 53) / 50 + 0.5) * 50
    return tostring(game.PlaceId) .. ":" .. (space and "S" or "E") .. ":" .. sb .. ":" .. pb
end

local function profile(key)
    local p = calibration[key]
    if not p then
        p = { offset = 0, streak = 0, dir = 0 }
        calibration[key] = p
    end
    return p
end

local function loadCalibration()
    pcall(function()
        if not isfile(CAL_FILE) then return end
        local saved = HttpService:JSONDecode(readfile(CAL_FILE))
        if type(saved) ~= "table" then return end
        for k, v in pairs(saved) do
            if type(k) == "string" and type(v) == "number" then
                calibration[k] = { offset = math.max(-0.05, math.min(0.05, v)), streak = 0, dir = 0 }
            end
        end
    end)
end

local function flushCalibration(now)
    if not calDirty or shot.active or now - calSavedAt < 2 then return end
    local out = {}
    for k, p in pairs(calibration) do out[k] = p.offset end
    local ok = pcall(function() writefile(CAL_FILE, HttpService:JSONEncode(out)) end)
    if ok then calDirty = false calSavedAt = now end
end

local function resetCalibration()
    calibration = {}
    calDirty = true
end

local function learn(rec, fb)
    if not rec or type(fb) ~= "string" or not S.cal then return end
    if rec.maxGap > 0.05 or rec.samples < 3 or rec.reason == "peak" then return end
    if math.abs((rec.rawPing or 53) - (rec.ping or 53)) > 12 then return end
    local p = profile(rec.key)
    local t = string.lower(fb)
    if string.find(t, "perfect", 1, true) then p.streak, p.dir = 0, 0 return end
    local dir = string.find(t, "late", 1, true) and 1 or (string.find(t, "early", 1, true) and -1 or 0)
    if dir == 0 then return end
    if dir == p.dir then p.streak = p.streak + 1 else p.dir, p.streak = dir, 1 end
    if p.streak < 2 then return end
    local step = string.find(t, "slightly", 1, true) and 0.003
        or (string.find(t, "very", 1, true) and 0.008 or 0.005)
    p.offset = math.max(-0.05, math.min(0.05, p.offset + dir * step))
    p.streak = 0
    calDirty = true
end

local function getChar()
    local f = workspace:FindFirstChild("Characters")
    return f and f:FindFirstChild(lp.Name)
end

local function iHaveBall()
    if not ch then return true end
    local a = ch:FindFirstChild("Attributes")
    local b = a and a:FindFirstChild("Basketball")
    return b ~= nil and b.Value ~= nil
end

local function refresh()
    ch = getChar()
    others = {}
    local f = workspace:FindFirstChild("Characters")
    if not f then return end
    for _, c in ipairs(f:GetChildren()) do
        if c.Name ~= lp.Name and c.Name ~= "InvisCharacter" then
            local r = c:FindFirstChild("HumanoidRootPart")
            if r then others[#others + 1] = { model = c, root = r } end
        end
    end
end

local function release(reason, lead)
    if shot.released or not running or not isrbxactive() then return end
    local space = iskeypressed(CFG.JumpKey)
    local did = false
    if iskeypressed(CFG.ShootKey) then keyrelease(CFG.ShootKey) did = true end
    if space then keyrelease(CFG.JumpKey) did = true end
    if not did then return end
    shot.released = true
    shot.record = {
        key = calKey(space, shot.speed, network.ping), reason = reason,
        ping = network.ping, rawPing = network.raw, maxGap = shot.maxGap,
        samples = shot.n, leadMs = lead * 1000,
    }
end

local function onShotEnd(c, rec)
    task.spawn(function()
        wait(0.8)
        local root = c and c:FindFirstChild("HumanoidRootPart")
        local fb = root and root:FindFirstChild("ShotFeedback")
        local t = fb and fb:FindFirstChild("ReleaseTiming", true)
        learn(rec, t and t.Text)
    end)
end

local function scheduleRelease(waitFor, lead, myVer)
    local deadline = tick() + waitFor
    shot.deadline = deadline
    task.spawn(function()
        while tick() < deadline do
            wait(0.001)
            if not running or shot.ver ~= myVer or shot.released then return end
        end
        if not running or shot.ver ~= myVer or shot.released or not shot.active then return end
        if not ch or ch:GetAttribute("ReleasedShot") ~= false then return end
        release("timer", lead)
    end)
end

local function shotStep()
    if not ch then shot.active = false return end

    if ch:GetAttribute("ReleasedShot") ~= false then
        if shot.active then
            shot.active = false
            shot.ver = shot.ver + 1
            shot.deadline = nil
            onShotEnd(ch, shot.record)
        end
        return
    end

    local m = ch:GetAttribute("meterOffset")
    local y = m and m.y
    if type(y) ~= "number" then return end
    local now = tick()

    if not shot.active then
        shot.active, shot.armed, shot.released = true, false, false
        shot.startY, shot.lastY, shot.lastT, shot.minY = y, y, now, y
        shot.rate, shot.n, shot.maxGap, shot.lastStep = 3, 0, 0, now
        shot.record, shot.deadline = nil, nil
        shot.ver = shot.ver + 1
        return
    end
    shot.maxGap = math.max(shot.maxGap, now - shot.lastStep)
    shot.lastStep = now
    if shot.released then return end

    if not shot.armed then
        if y > -0.35 or y < shot.startY - 0.001 then
            shot.armed = true
            shot.lastY, shot.lastT, shot.minY = y, now, y
            shot.speed = ch:GetAttribute("ShotSpeed")
        end
        return
    end

    local dy = y - shot.lastY
    if dy < -0.001 then
        local dt = now - shot.lastT
        if dt > 0.005 and dt < 0.2 then
            local r = -dy / dt
            if r >= 1 and r <= 7 then shot.rate = shot.rate * 0.4 + r * 0.6 end
        end
        shot.lastY, shot.lastT = y, now
        shot.n = shot.n + 1
    elseif dy > 0.25 then
        shot.lastY, shot.lastT, shot.minY = y, now, y
        shot.ver = shot.ver + 1
        shot.deadline = nil
    end
    shot.minY = math.min(shot.minY, y)

    local since = math.min(now - shot.lastT, 0.12)
    local yEst = shot.lastY - shot.rate * since

    local space = iskeypressed(CFG.JumpKey) and not iskeypressed(CFG.ShootKey)
    local p = profile(calKey(space, shot.speed, network.ping))
    local manual = S.offset / 1000
    local ping = (network.ping or 53) / 1000
    local lead = math.max(0, math.min(0.35, ping + CFG.Transit + manual + p.offset))
    local arrival = yEst - shot.rate * lead

    if arrival <= CFG.PeakY then
        release("predicted", lead)
    elseif shot.minY <= CFG.PeakY + 0.04 and dy > 0.003 then
        release("peak", lead)
    elseif shot.n >= 3 then
        local waitFor = (yEst - CFG.PeakY) / shot.rate - lead
        if waitFor > 0 and waitFor <= 0.09 then
            if not shot.deadline or math.abs((tick() + waitFor) - shot.deadline) > 0.008 then
                shot.ver = shot.ver + 1
                scheduleRelease(waitFor, lead, shot.ver)
            end
        end
    end
end

local function fireJump()
    local ok = pcall(function()
        local r = RS.Aero.AeroRemoteServices.InputService.Jump
        r:FireServer()
    end)
    if not ok then
        keypress(CFG.JumpKey)
        wait(0.03)
        keyrelease(CFG.JumpKey)
    end
end

local function blockStep(now)
    if blockAt and now >= blockAt then
        blockAt = nil
        if S.block and isrbxactive() and not iHaveBall() then
            task.spawn(fireJump)
        end
    end
    if not S.block or blockAt or now < nextBlock or shot.active then return end
    if not ch or iHaveBall() then return end
    local root = ch:FindFirstChild("HumanoidRootPart")
    local myPos = root and root.Position
    if not myPos then return end
    local myTeam = ch:GetAttribute("Team") or 0
    for _, o in ipairs(others) do
        local key = o.model.Name
        local p = o.root.Position
        if p and (p - myPos).Magnitude <= S.blockrange then
            local sst = o.model:GetAttribute("ShotStartTime")
            local prev = lastShotStart[key]
            lastShotStart[key] = sst
            if sst and prev and sst ~= prev then
                local team = o.model:GetAttribute("Team")
                if myTeam == 0 or team ~= myTeam then
                    blockAt, nextBlock = now + S.blockdelay / 1000, now + 1.5
                    return
                end
            end
        else
            lastShotStart[key] = nil
        end
    end
end

local function trySet(d, k, v)
    pcall(function() d[k] = v end)
end

local function setFontSize(d, n)
    trySet(d, "FontSize", n)
    trySet(d, "Size", n)
end

local function makeLoader()
    local w, h = 1920, 1080
    pcall(function()
        local v = workspace.CurrentCamera.ViewportSize
        if v and v.X > 0 then w, h = v.X, v.Y end
    end)
    local objs = {}

    local function mkSquare(pos, size, color, z)
        local d = Drawing.new("Square")
        trySet(d, "Filled", true)
        trySet(d, "Color", color)
        trySet(d, "Transparency", 1)
        trySet(d, "Position", pos)
        trySet(d, "Size", size)
        trySet(d, "ZIndex", z)
        trySet(d, "Visible", true)
        objs[#objs + 1] = d
        drawings[#drawings + 1] = d
        return d
    end

    local function mkText(text, pos, color, fontSize, z)
        local d = Drawing.new("Text")
        trySet(d, "Text", text)
        trySet(d, "Center", true)
        trySet(d, "Outline", true)
        trySet(d, "Color", color)
        trySet(d, "Transparency", 1)
        trySet(d, "Position", pos)
        trySet(d, "ZIndex", z)
        setFontSize(d, fontSize)
        trySet(d, "Visible", true)
        objs[#objs + 1] = d
        drawings[#drawings + 1] = d
        return d
    end

    local accent = Color3.fromRGB(90, 220, 130)
    local barW = 420
    local barX, barY = w / 2 - barW / 2, h / 2 + 40

    mkSquare(Vector2.new(0, 0), Vector2.new(w, h), Color3.fromRGB(12, 12, 18), 1)
    mkText("AUTO GREEN", Vector2.new(w / 2, h / 2 - 90), accent, 42, 3)
    mkText("Practical Basketball", Vector2.new(w / 2, h / 2 - 40), Color3.fromRGB(170, 170, 185), 18, 3)
    mkSquare(Vector2.new(barX, barY), Vector2.new(barW, 8), Color3.fromRGB(35, 35, 48), 2)
    local fill = mkSquare(Vector2.new(barX, barY), Vector2.new(1, 8), accent, 3)
    local status = mkText("Starting", Vector2.new(w / 2, barY + 24), Color3.fromRGB(200, 200, 210), 16, 3)

    local cur = 0
    local loader = {}
    function loader.set(p, text)
        trySet(status, "Text", text)
        for i = 1, 10 do
            local v = cur + (p - cur) * (i / 10)
            trySet(fill, "Size", Vector2.new(math.max(1, barW * v), 8))
            wait(0.02)
        end
        cur = p
    end
    function loader.finish()
        for a = 9, 0, -1 do
            for _, d in ipairs(objs) do trySet(d, "Transparency", a / 10) end
            wait(0.03)
        end
        for _, d in ipairs(objs) do pcall(function() d:Remove() end) end
    end
    function loader.kill()
        for _, d in ipairs(objs) do pcall(function() d:Remove() end) end
    end
    return loader
end

local function unload()
    if not running then return end
    running = false
    shot.ver = shot.ver + 1
    flushCalibration(tick() + 10)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    for _, d in ipairs(drawings) do pcall(function() d:Remove() end) end
    if Library and not Library.Unloaded then pcall(function() Library:Destroy() end) end
end
_G.AGB_UNLOAD = unload

local function buildMenu()
    loadstring(httpget("https://scripts.wabisabi.mom/wabi-sabi-ui-lib.lua"))()
    Library = WabiSabi
    Library:OnUnload(unload)

    local Window = Library:CreateWindow({
        Title = "Lilman is poor",
        Size = Vector2.new(520, 420),
        MinSize = Vector2.new(470, 380),
        Resize = true,
        MinimizeKey = "End",
    })
    local Main = Window:AddTab({ Title = "Main", Icon = "house" })

    local Shooting = Main:AddSection("Shooting")
    Shooting:AddToggle({ Id = "agb_green", Title = "Lilman is poor", Default = S.green,
        Callback = function(v) S.green = v end })
    Shooting:AddToggle({ Id = "agb_cal", Title = "Auto calibrate", Default = S.cal,
        Callback = function(v) S.cal = v end })
    Shooting:AddSlider({ Id = "agb_offset", Title = "Release offset (ms, + = earlier)", Min = -30, Max = 30,
        Default = S.offset, Rounding = 0, Callback = function(v) S.offset = v end })
    Shooting:AddButton({ Title = "Reset learned timing", Callback = resetCalibration })

    local Defense = Main:AddSection("Defense")
    Defense:AddToggle({ Id = "agb_block", Title = "Auto block", Default = S.block,
        Callback = function(v) S.block = v end })
    Defense:AddSlider({ Id = "agb_blockrange", Title = "Block range (studs)", Min = 4, Max = 16,
        Default = S.blockrange, Rounding = 1, Callback = function(v) S.blockrange = v end })
    Defense:AddSlider({ Id = "agb_blockdelay", Title = "Block delay (ms)", Min = 0, Max = 400,
        Default = S.blockdelay, Rounding = 0, Callback = function(v) S.blockdelay = v end })

    local Script = Main:AddSection("Script")
    Script:AddParagraph({ Title = "Keys", Content = "Shoot = E or Space. End hides the menu." })
    Script:AddButton({ Title = "Unload", Callback = unload })
end

task.spawn(function()
    local loader = makeLoader()
    local ok = pcall(function()
        loader.set(0.25, "Loading calibration")
        loadCalibration()
        loader.set(0.5, "Finding character")
        refresh()
        updatePing(tick())
        loader.set(0.75, "Building menu")
        buildMenu()
        loader.set(1.0, "Ready")
        wait(0.3)
    end)
    if not ok then loader.kill() end

    local function safeShot()
        if not running or not S.green then return end
        if not isrbxactive() then return end
        local held = iskeypressed(CFG.ShootKey) or iskeypressed(CFG.JumpKey)
        if not held and not shot.active then return end
        pcall(shotStep)
    end
    conns[#conns + 1] = RunService.RenderStepped:Connect(safeShot)
    task.spawn(function()
        while running do
            wait(0.005)
            safeShot()
        end
    end)

    task.spawn(function()
        local lastRefresh = 0
        while running do
            wait(0.03)
            local now = tick()
            pcall(function()
                updatePing(now)
                if now - lastRefresh >= 0.5 then lastRefresh = now refresh() end
                blockStep(now)
                flushCalibration(now)
            end)
        end
    end)

    if ok then loader.finish() end
end)
