local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local RS          = game:GetService("ReplicatedStorage")
local lp          = game:GetService("Players").LocalPlayer

pcall(function() if _G.AGB_UNLOAD then _G.AGB_UNLOAD() end end)

local CFG = {
    ShootKey = 0x45,
    JumpKey  = 0x20,
    StealKey = 0x51,
    PeakY    = -1.475,
    Transit  = 0.015,
    ActionFile = "agb_actions.txt",
}
local CAL_FILE = "agb_calibration.json"

local S = {
    green       = true,
    cal         = true,
    offset      = 0,
    block       = true,
    blockrange  = 12,
    blockcone   = 70,
    blockbase   = 1080,
    blocklead   = 250,
    blockmanual = 0,
    blockcd     = 1500,
    rebound     = true,
    gravity     = 196,
    floor       = 3,
    steal       = true,
    stealrange  = 6,
    stealcone   = 60,
    autosteal   = false,
    stealcd     = 700,
}

local running = true
local conns, drawings = {}, {}
local ch, myRoot, others, allChars = nil, nil, {}, {}
local balls, tracks, heldBalls, goals = {}, {}, {}, {}
local shot = { active = false, armed = false, released = false, ver = 0 }
local network = { ping = nil, raw = nil, last = -1 }
local calibration, calDirty, calSavedAt = {}, false, -10
local pending, nextBlock, nextSteal, lastSST = nil, 0, 0, {}
local stealTargets = {}
local actions, actionsDirty, actionsSavedAt = {}, false, 0
local Library

local pool = { Text = {}, Circle = {}, Line = {} }
local used = { Text = 0, Circle = 0, Line = 0 }

local GREEN  = Color3.fromRGB(90, 220, 130)
local YELLOW = Color3.fromRGB(240, 200, 70)
local RED    = Color3.fromRGB(235, 90, 90)
local WHITE  = Color3.fromRGB(230, 230, 235)

local function trySet(d, k, v)
    pcall(function() d[k] = v end)
end

local function setFontSize(d, n)
    trySet(d, "FontSize", n)
    trySet(d, "Size", n)
end

local function getObj(kind)
    local p = pool[kind]
    local i = used[kind] + 1
    used[kind] = i
    local d = p[i]
    if not d then
        d = Drawing.new(kind)
        p[i] = d
        drawings[#drawings + 1] = d
    end
    return d
end

local function beginFrame()
    for k in pairs(used) do used[k] = 0 end
end

local function endFrame()
    for kind, p in pairs(pool) do
        for i = used[kind] + 1, #p do
            trySet(p[i], "Visible", false)
        end
    end
end

local function drawText(text, x, y, color, size)
    local d = getObj("Text")
    trySet(d, "Text", text)
    trySet(d, "Center", true)
    trySet(d, "Outline", true)
    trySet(d, "Color", color)
    trySet(d, "Transparency", 1)
    trySet(d, "Position", Vector2.new(x, y))
    setFontSize(d, size)
    trySet(d, "ZIndex", 5)
    trySet(d, "Visible", true)
end

local function drawCircle(x, y, r, color, thick)
    local d = getObj("Circle")
    trySet(d, "Radius", r)
    trySet(d, "NumSides", 24)
    trySet(d, "Thickness", thick)
    trySet(d, "Filled", false)
    trySet(d, "Color", color)
    trySet(d, "Transparency", 1)
    trySet(d, "Position", Vector2.new(x, y))
    trySet(d, "ZIndex", 4)
    trySet(d, "Visible", true)
end

local function drawLine(x1, y1, x2, y2, color, thick)
    local d = getObj("Line")
    trySet(d, "From", Vector2.new(x1, y1))
    trySet(d, "To", Vector2.new(x2, y2))
    trySet(d, "Thickness", thick)
    trySet(d, "Color", color)
    trySet(d, "Transparency", 1)
    trySet(d, "ZIndex", 3)
    trySet(d, "Visible", true)
end

local function attr(inst, name)
    local ok, v = pcall(function() return inst:GetAttribute(name) end)
    if ok then return v end
    return nil
end

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

local function hasBall(model)
    local a = model:FindFirstChild("Attributes")
    local b = a and a:FindFirstChild("Basketball")
    return b ~= nil and b.Value ~= nil
end

local function refresh()
    ch = getChar()
    myRoot = ch and ch:FindFirstChild("HumanoidRootPart")
    others, allChars = {}, {}
    if ch then allChars[1] = ch end
    local f = workspace:FindFirstChild("Characters")
    if f then
        for _, c in ipairs(f:GetChildren()) do
            if c.Name ~= lp.Name and c.Name ~= "InvisCharacter" then
                local r = c:FindFirstChild("HumanoidRootPart")
                if r then
                    others[#others + 1] = { model = c, root = r, name = c.Name }
                    allChars[#allChars + 1] = c
                end
            end
        end
    end
    balls = {}
    local bf = workspace:FindFirstChild("Basketballs")
    if bf then
        for _, b in ipairs(bf:GetChildren()) do balls[#balls + 1] = b end
    end
end

local function refreshGoals()
    goals = {}
    local hf = workspace:FindFirstChild("Hoops")
    if not hf then return end
    for _, h in ipairs(hf:GetChildren()) do
        local g = h:FindFirstChild("Goal")
        if g then
            local ok, p = pcall(function() return g.Position end)
            if ok and p then goals[#goals + 1] = p end
        end
    end
end

local function updateHeld()
    heldBalls = {}
    for _, m in ipairs(allChars) do
        local a = m:FindFirstChild("Attributes")
        local b = a and a:FindFirstChild("Basketball")
        local v = b and b.Value
        if v then heldBalls[v] = true end
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

local function lookDir(root)
    local ok, x, z = pcall(function()
        local lv = root.CFrame.LookVector
        local m = math.sqrt(lv.X * lv.X + lv.Z * lv.Z)
        return lv.X / m, lv.Z / m
    end)
    if ok then return x, z end
    return nil, nil
end

local function coneOk(fromPos, towardPos, viewerPos, deg)
    local ax, az = towardPos.X - fromPos.X, towardPos.Z - fromPos.Z
    local bx, bz = viewerPos.X - fromPos.X, viewerPos.Z - fromPos.Z
    local am = math.sqrt(ax * ax + az * az)
    local bm = math.sqrt(bx * bx + bz * bz)
    if am < 0.001 or bm < 0.001 then return true end
    return (ax * bx + az * bz) / (am * bm) >= math.cos(math.rad(deg))
end

local function goalFor(o)
    local a = o.model:FindFirstChild("Attributes")
    local g = a and a:FindFirstChild("Goal")
    local part = g and g.Value
    if part then
        local ok, p = pcall(function() return part.Position end)
        if ok and p then return p end
    end
    local lx, lz = lookDir(o.root)
    local sp = o.root.Position
    local best, bestDot = nil, -2
    for _, gp in ipairs(goals) do
        local dx, dz = gp.X - sp.X, gp.Z - sp.Z
        local m = math.sqrt(dx * dx + dz * dz)
        if m > 0.001 then
            local dot = lx and ((dx * lx + dz * lz) / m) or 0
            if dot > bestDot then best, bestDot = gp, dot end
        end
    end
    return best
end

local function isOpponent(model)
    local myTeam = ch and ch:GetAttribute("Team") or 0
    local team = model:GetAttribute("Team")
    return myTeam == 0 or team ~= myTeam
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

local function pressSteal()
    keypress(CFG.StealKey)
    wait(0.03)
    keyrelease(CFG.StealKey)
end

local function scanShots()
    for _, o in ipairs(others) do
        local sst = o.model:GetAttribute("ShotStartTime")
        local prev = lastSST[o.name]
        lastSST[o.name] = sst
        o.started = sst ~= nil and prev ~= nil and sst ~= prev and o.model:GetAttribute("ReleasedShot") == false
    end
end

local function blockStep(now)
    if pending and now >= pending.at then
        pending = nil
        if S.block and isrbxactive() and not iHaveBall() and attr(ch, "InAir") ~= true then
            task.spawn(fireJump)
        end
    end
    if not S.block or pending or now < nextBlock or shot.active then return end
    if not ch or not myRoot or iHaveBall() then return end
    local myPos = myRoot.Position
    for _, o in ipairs(others) do
        if o.started then
            local sp = o.root.Position
            local dx, dy, dz = sp.X - myPos.X, sp.Y - myPos.Y, sp.Z - myPos.Z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist <= S.blockrange and isOpponent(o.model) then
                local gp = goalFor(o)
                if not gp or coneOk(sp, gp, myPos, S.blockcone) then
                    local speed = attr(o.model, "ShotSpeed")
                    if type(speed) ~= "number" or speed <= 0 then speed = 1.8 end
                    local delay = S.blockbase / speed - S.blocklead - (network.ping or 53) + S.blockmanual
                    if delay < 0 then delay = 0 end
                    pending = { at = now + delay / 1000, name = o.name, delay = delay }
                    nextBlock = now + S.blockcd / 1000
                    return
                end
            end
        end
    end
end

local function stealStep(now)
    stealTargets = {}
    if not S.steal or not ch or not myRoot then return end
    if iHaveBall() then return end
    local myPos = myRoot.Position
    local lx, lz = lookDir(myRoot)
    for _, o in ipairs(others) do
        if hasBall(o.model) and isOpponent(o.model) then
            local p = o.root.Position
            local dx, dz = p.X - myPos.X, p.Z - myPos.Z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= S.stealrange * 2 then
                local inCone = true
                if lx and dist > 0.001 then
                    inCone = (dx * lx + dz * lz) / dist >= math.cos(math.rad(S.stealcone))
                end
                local shooting = o.model:GetAttribute("Action") == "Shooting"
                local inRange = dist <= S.stealrange
                local ready = inRange and inCone and not shooting
                stealTargets[#stealTargets + 1] = { pos = p, dist = dist, ready = ready, inRange = inRange }
                if ready and S.autosteal and now >= nextSteal and isrbxactive() then
                    nextSteal = now + S.stealcd / 1000
                    task.spawn(pressSteal)
                end
            end
        end
    end
end

local function trackActions()
    for _, m in ipairs(allChars) do
        local a = m:GetAttribute("Action")
        if type(a) == "string" and a ~= "" then
            actions[a] = (actions[a] or 0) + 1
            actionsDirty = true
        end
    end
end

local function saveActions(now)
    if not actionsDirty or now - actionsSavedAt < 10 then return end
    actionsSavedAt = now
    local keys = {}
    for k in pairs(actions) do keys[#keys + 1] = k end
    table.sort(keys)
    local lines = {}
    for _, k in ipairs(keys) do lines[#lines + 1] = k .. "\t" .. actions[k] end
    local ok = pcall(function() writefile(CFG.ActionFile, table.concat(lines, "\n")) end)
    if ok then actionsDirty = false end
end

local function reboundFrame(now)
    if not myRoot then return end
    local myPos = myRoot.Position
    local floorY = myPos.Y - S.floor
    local g = S.gravity
    for _, ball in ipairs(balls) do
        if heldBalls[ball] then
            tracks[ball] = nil
        else
            local ok, pos = pcall(function() return ball.Position end)
            if ok and pos then
                local tr = tracks[ball]
                if not tr then
                    tracks[ball] = { x = pos.X, y = pos.Y, z = pos.Z, t = now }
                else
                    local dt = now - tr.t
                    if dt > 0.004 then
                        local vx, vy, vz = (pos.X - tr.x) / dt, (pos.Y - tr.y) / dt, (pos.Z - tr.z) / dt
                        if tr.vx then
                            tr.vx, tr.vy, tr.vz = tr.vx * 0.6 + vx * 0.4, tr.vy * 0.6 + vy * 0.4, tr.vz * 0.6 + vz * 0.4
                        else
                            tr.vx, tr.vy, tr.vz = vx, vy, vz
                        end
                        tr.x, tr.y, tr.z, tr.t = pos.X, pos.Y, pos.Z, now
                    end
                    if tr.vx then
                        local speed = math.sqrt(tr.vx * tr.vx + tr.vy * tr.vy + tr.vz * tr.vz)
                        if speed > 4 then
                            local disc = tr.vy * tr.vy + 2 * g * (tr.y - floorY)
                            if disc >= 0 then
                                local t = (tr.vy + math.sqrt(disc)) / g
                                if t > 0.05 and t < 5 then
                                    local lx, lz = tr.x + tr.vx * t, tr.z + tr.vz * t
                                    local sp, on = WorldToScreen(Vector3.new(lx, floorY, lz))
                                    if on then
                                        local dx, dz = lx - myPos.X, lz - myPos.Z
                                        local myDist = math.sqrt(dx * dx + dz * dz)
                                        local closest = true
                                        for _, o in ipairs(others) do
                                            local p = o.root.Position
                                            local ox, oz = lx - p.X, lz - p.Z
                                            if math.sqrt(ox * ox + oz * oz) < myDist then
                                                closest = false
                                                break
                                            end
                                        end
                                        local color = closest and GREEN or RED
                                        drawCircle(sp.X, sp.Y, 16, color, 2)
                                        local label = string.format("%s  %.1fs  %.0f", attr(ball, "MidShot") and "SHOT" or "REB", t, myDist)
                                        drawText(label, sp.X, sp.Y - 30, color, 16)
                                        local bp, bon = WorldToScreen(Vector3.new(tr.x, tr.y, tr.z))
                                        if bon then drawLine(bp.X, bp.Y, sp.X, sp.Y, color, 1) end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function drawSteal()
    for _, t in ipairs(stealTargets) do
        local sp, on = WorldToScreen(t.pos)
        if on then
            local color = t.ready and GREEN or (t.inRange and YELLOW or WHITE)
            drawCircle(sp.X, sp.Y, t.ready and 26 or 20, color, t.ready and 3 or 1)
            drawText(string.format("%.1f", t.dist), sp.X, sp.Y + 30, color, 14)
            if t.ready then drawText("STEAL", sp.X, sp.Y - 44, GREEN, 18) end
        end
    end
end

local function drawBlock(now)
    if not pending then return end
    local left = (pending.at - now) * 1000
    local w, h = 1920, 1080
    pcall(function()
        local v = workspace.CurrentCamera.ViewportSize
        if v and v.X > 0 then w, h = v.X, v.Y end
    end)
    drawText(string.format("BLOCK %dms  %s", math.max(0, left), pending.name), w / 2, h * 0.2, YELLOW, 20)
end

local function frame()
    if not running then return end
    beginFrame()
    local now = tick()
    if S.rebound then pcall(reboundFrame, now) end
    pcall(drawSteal)
    pcall(drawBlock, now)
    endFrame()
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
    actionsDirty = true
    saveActions(tick() + 100)
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
        Title = "Auto Green",
        Size = Vector2.new(540, 620),
        MinSize = Vector2.new(480, 460),
        Resize = true,
        MinimizeKey = "End",
    })
    local Main = Window:AddTab({ Title = "Main", Icon = "house" })

    local Shooting = Main:AddSection("Shooting")
    Shooting:AddToggle({ Id = "agb_green", Title = "Auto green", Default = S.green,
        Callback = function(v) S.green = v end })
    Shooting:AddToggle({ Id = "agb_cal", Title = "Auto calibrate", Default = S.cal,
        Callback = function(v) S.cal = v end })
    Shooting:AddSlider({ Id = "agb_offset", Title = "Release offset (ms, + = earlier)", Min = -30, Max = 30,
        Default = S.offset, Rounding = 0, Callback = function(v) S.offset = v end })
    Shooting:AddButton({ Title = "Reset learned timing", Callback = resetCalibration })

    local Defense = Main:AddSection("Auto block")
    Defense:AddToggle({ Id = "agb_block", Title = "Auto block", Default = S.block,
        Callback = function(v) S.block = v end })
    Defense:AddSlider({ Id = "agb_blockrange", Title = "Range (studs)", Min = 4, Max = 30,
        Default = S.blockrange, Rounding = 0, Callback = function(v) S.blockrange = v end })
    Defense:AddSlider({ Id = "agb_blockcone", Title = "Cone vs hoop (deg)", Min = 20, Max = 120,
        Default = S.blockcone, Rounding = 0, Callback = function(v) S.blockcone = v end })
    Defense:AddSlider({ Id = "agb_blockbase", Title = "Shot length at speed 1.0 (ms)", Min = 600, Max = 1800,
        Default = S.blockbase, Rounding = 0, Callback = function(v) S.blockbase = v end })
    Defense:AddSlider({ Id = "agb_blocklead", Title = "Jump lead (ms)", Min = 0, Max = 600,
        Default = S.blocklead, Rounding = 0, Callback = function(v) S.blocklead = v end })
    Defense:AddSlider({ Id = "agb_blockmanual", Title = "Fine tune (ms)", Min = -200, Max = 200,
        Default = S.blockmanual, Rounding = 0, Callback = function(v) S.blockmanual = v end })
    Defense:AddSlider({ Id = "agb_blockcd", Title = "Cooldown (ms)", Min = 300, Max = 3000,
        Default = S.blockcd, Rounding = 0, Callback = function(v) S.blockcd = v end })

    local Rebound = Main:AddSection("Rebound assist")
    Rebound:AddToggle({ Id = "agb_rebound", Title = "Landing marker", Default = S.rebound,
        Callback = function(v) S.rebound = v end })
    Rebound:AddSlider({ Id = "agb_gravity", Title = "Ball gravity", Min = 50, Max = 400,
        Default = S.gravity, Rounding = 0, Callback = function(v) S.gravity = v end })
    Rebound:AddSlider({ Id = "agb_floor", Title = "Floor offset", Min = 0, Max = 6,
        Default = S.floor, Rounding = 1, Callback = function(v) S.floor = v end })

    local Steal = Main:AddSection("Steal timing")
    Steal:AddToggle({ Id = "agb_steal", Title = "Steal indicator", Default = S.steal,
        Callback = function(v) S.steal = v end })
    Steal:AddSlider({ Id = "agb_stealrange", Title = "Range (studs)", Min = 3, Max = 14,
        Default = S.stealrange, Rounding = 1, Callback = function(v) S.stealrange = v end })
    Steal:AddSlider({ Id = "agb_stealcone", Title = "Facing cone (deg)", Min = 20, Max = 120,
        Default = S.stealcone, Rounding = 0, Callback = function(v) S.stealcone = v end })
    Steal:AddToggle({ Id = "agb_autosteal", Title = "Auto steal", Default = S.autosteal,
        Callback = function(v) S.autosteal = v end })
    Steal:AddSlider({ Id = "agb_stealcd", Title = "Steal cooldown (ms)", Min = 300, Max = 3000,
        Default = S.stealcd, Rounding = 0, Callback = function(v) S.stealcd = v end })

    local Script = Main:AddSection("Script")
    Script:AddParagraph({ Title = "Keys", Content = "Shoot = E or Space. Steal = Q. End hides the menu." })
    Script:AddButton({ Title = "Unload", Callback = unload })
end

task.spawn(function()
    local loader = makeLoader()
    local ok = pcall(function()
        loader.set(0.25, "Loading calibration")
        loadCalibration()
        loader.set(0.5, "Finding character")
        refresh()
        refreshGoals()
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
    conns[#conns + 1] = RunService.RenderStepped:Connect(frame)
    task.spawn(function()
        while running do
            wait(0.005)
            safeShot()
        end
    end)

    task.spawn(function()
        local lastRefresh, lastGoals = 0, 0
        while running do
            wait(0.03)
            local now = tick()
            pcall(function()
                updatePing(now)
                if now - lastRefresh >= 0.5 then lastRefresh = now refresh() end
                if now - lastGoals >= 3 then lastGoals = now refreshGoals() end
                updateHeld()
                scanShots()
                trackActions()
                blockStep(now)
                stealStep(now)
                flushCalibration(now)
                saveActions(now)
            end)
        end
    end)

    if ok then loader.finish() end
end)
