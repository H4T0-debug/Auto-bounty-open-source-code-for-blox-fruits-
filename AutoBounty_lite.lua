-- AutoBounty Lite: bounty-only features, no map scans or metatable hooks.

-- Stop a previous copy if it exposed a Stop function
if getgenv then
    local old = getgenv().ABLite
    if type(old) == "table" and type(old.Stop) == "function" then pcall(old.Stop) end
end

repeat task.wait() until game:IsLoaded() and game:GetService("Players").LocalPlayer

-- ═══════════════ SETTINGS ═══════════════
local CFG = {
    LockTime = 90,            -- seconds on one target before switching
    SkipTime = 30,            -- seconds to skip a player after a lock timeout
    MaxStay = 360,            -- seconds on one server before hopping (when safe)
    MinBounty = 3000000,      -- only hop to servers with at least this bounty
    MinPlayers = 1,
    MaxPlayers = 12,
    Weapon = "Melee",         -- ToolTip to hold: "Melee", "Sword", "Blox Fruit", "Gun"
    SkillKeys = { "Z", "X", "C" },
    HoldTime = 0.1,
    Team = "Pirates",
    SCRIPT_URL = "",          -- paste your hosted copy's raw URL to auto-run after a hop
}

-- ═══════════════ SERVICES ═══════════════
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local LP = Players.LocalPlayer
local CommF = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CommF_")

-- ═══════════════ STATE ═══════════════
local S = {
    on = false,
    running = true,
    target = nil,
    targetRoot = nil,
    lockStart = 0,
    skip = {},
    enterServer = tick(),
    startT = tick(),
    startBounty = 0,
    hopping = false,
    lastPick = 0,
    tLong = 0,
    angle = 0,
    angleT = 0,
    tween = nil,
    tweenGoal = nil,
}

local partsCache = {}

-- ═══════════════ HELPERS ═══════════════
local function hrpOf(p)
    local c = (p or LP).Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function humOf(p)
    local c = (p or LP).Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function myBounty()
    local ls = LP:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Bounty/Honor")
    return v and tonumber(v.Value) or 0
end

local function levelOf(p)
    local d = p:FindFirstChild("Data")
    local l = d and d:FindFirstChild("Level")
    return l and tonumber(l.Value) or nil
end

local function commas(n)
    local s = tostring(math.floor(n))
    local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (r:gsub("^,", ""))
end

local function fmtTime(sec)
    sec = math.floor(sec)
    return string.format("%02d:%02d:%02d", math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60)
end

local function ensureTeam()
    local t = LP.Team
    if t and t.Name == CFG.Team then return end
    pcall(function() CommF:InvokeServer("SetTeam", CFG.Team) end)
end

local function refreshParts(c)
    partsCache = {}
    if not c then return end
    for _, d in ipairs(c:GetDescendants()) do
        if d:IsA("BasePart") then table.insert(partsCache, d) end
    end
end

local function setCollide(v)
    for i = #partsCache, 1, -1 do
        local p = partsCache[i]
        if p.Parent then p.CanCollide = v else table.remove(partsCache, i) end
    end
end

local function noclip()
    for i = #partsCache, 1, -1 do
        local p = partsCache[i]
        if p.Parent then
            if p.CanCollide then p.CanCollide = false end
        else
            table.remove(partsCache, i)
        end
    end
end

-- ═══════════════ FAST ATTACK (QuantumOnyx style) ═══════════════
local Net = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net"))
local reRegisterAttack = Net:RemoteEvent("RegisterAttack")
local RegisterHit = Net:RemoteEvent("RegisterHit", true)

pcall(function()
    local CombatUtil = require(ReplicatedStorage.Modules.CombatUtil)
    if CombatUtil and CombatUtil.CanAttack and hookfunction then
        hookfunction(CombatUtil.CanAttack, function() return true end)
    end
end)

local BodyParts = {
    "RightLowerArm", "RightUpperArm", "LeftLowerArm", "LeftUpperArm", "RightHand", "LeftHand",
}

local function getHits(radius)
    radius = radius or 60
    local hits = {}
    local my = hrpOf()
    if not my then return hits end
    local partName = BodyParts[math.random(#BodyParts)]
    if S.target and validTarget(S.target) then
        local char = S.target.Character
        if char then
            local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
            if hrp and (hrp.Position - my.Position).Magnitude <= radius then
                local part = char:FindFirstChild(partName) or hrp
                table.insert(hits, { char, part })
            end
        end
    end
    return hits
end

local function fastAttack()
    local char = LP.Character
    if not char then return end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return end
    local tip = tool.ToolTip
    if tip \~= "Melee" and tip \~= "Sword" and tip \~= "Blox Fruit" and tip \~= "Gun" then return end

    if tip == "Blox Fruit" and tool:FindFirstChild("LeftClickRemote") then
        pcall(function()
            tool.LeftClickRemote:FireServer(Vector3.new(0.01, -500, 0.01), 1, true)
        end)
        return
    end

    local hits = getHits(60)
    if #hits == 0 then return end

    pcall(function()
        reRegisterAttack:FireServer(0)
    end)

    local firstPart = hits[1] and hits[1][2]
    if firstPart and RegisterHit then
        pcall(function()
            RegisterHit:FireServer(firstPart, hits, nil, nil, tostring(LP.UserId):sub(2, 4) .. tostring(coroutine.running()):sub(11, 15))
        end)
    end
end

-- ═══════════════ TARGETING ═══════════════
local function validTarget(p)
    if not p or p == LP or not p.Parent then return false end
    local hrp, hum = hrpOf(p), humOf(p)
    if not hrp or not hum or hum.Health <= 0 then return false end
    if p:GetAttribute("PvpDisabled") == true then return false end
    if hrp.Position.Y < -100 then return false end
    if p.Character:FindFirstChild("TempSafeZone") then return false end
    local my, th = LP.Team, p.Team
    if my and th and my.Name == "Marines" and th.Name == "Marines" then return false end
    local myLv, tgLv = levelOf(LP), levelOf(p)
    if myLv and tgLv and math.abs(myLv - tgLv) > 700 then return false end
    return true
end

local function pickTarget()
    local my = hrpOf()
    if not my then return nil end
    local best, bestDist = nil, math.huge
    local now = tick()
    for _, p in ipairs(Players:GetPlayers()) do
        if (not S.skip[p] or now >= S.skip[p]) and validTarget(p) then
            local d = (hrpOf(p).Position - my.Position).Magnitude
            if d < bestDist and d <= 30000 then best, bestDist = p, d end
        end
    end
    return best
end

local function setTarget(p)
    S.target = p
    S.targetRoot = hrpOf(p)
    S.lockStart = tick()
    S.angle = math.random() * 6.28
    S.angleT = tick()
end

local function clearTarget()
    S.target = nil
    S.targetRoot = nil
    if S.tween then
        pcall(function() S.tween:Cancel() end)
        S.tween = nil
    end
    setCollide(true)
end

local function bountyAtRisk()
    local gui = LP:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local hud = main and main:FindFirstChild("BottomHUDList")
    local ic = hud and hud:FindFirstChild("InCombat")
    if not ic or not ic.Visible then return false end
    local lbl = ic:IsA("TextLabel") and ic or ic:FindFirstChildWhichIsA("TextLabel", true)
    local txt = lbl and string.lower(lbl.Text) or ""
    return string.find(txt, "risk") \~= nil
end

-- ═══════════════ MOVEMENT ═══════════════
local function moveTo(rootCF, off)
    local my = hrpOf()
    if not my then return end
    local goal = rootCF * CFrame.new(off.X, 0, off.Z)
    local d = (my.Position - goal.Position).Magnitude
    if d <= 85 then
        if S.tween then
            pcall(function() S.tween:Cancel() end)
            S.tween = nil
        end
        my.AssemblyLinearVelocity = Vector3.zero
        my.CFrame = goal
    else
        local t = S.tween
        if t and t.PlaybackState == Enum.PlaybackState.Playing and S.tweenGoal
            and (S.tweenGoal - goal.Position).Magnitude < 4 then
            return
        end
        if t then pcall(function() t:Cancel() end) end
        local nt = TweenService:Create(my, TweenInfo.new(d / 200, Enum.EasingStyle.Linear), { CFrame = goal })
        S.tween = nt
        S.tweenGoal = goal.Position
        nt:Play()
    end
end

-- ═══════════════ SERVER HOP ═══════════════
local function fetchServers()
    local browser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
    local list = {}
    if not browser then return list end
    for page = 1, 10 do
        local ok, res = pcall(function() return browser:InvokeServer(page) end)
        if ok and type(res) == "table" then
            local any = false
            for job, info in pairs(res) do
                any = true
                if type(info) == "table" then
                    list[#list + 1] = {
                        Job = job,
                        Count = tonumber(info.Count) or 0,
                        Bounty = tonumber(info.Bounty) or 0,
                    }
                end
            end
            if not any then break end
        end
        task.wait(0.05)
    end
    return list
end

local function pickServer(list)
    local good, any = {}, {}
    for _, s in ipairs(list) do
        if s.Job \~= game.JobId then
            any[#any + 1] = s
            if s.Count >= CFG.MinPlayers and s.Count <= CFG.MaxPlayers and s.Bounty >= CFG.MinBounty then
                good[#good + 1] = s
            end
        end
    end
    local pool = (#good > 0) and good or any
    if #pool == 0 then return nil end
    return pool[math.random(1, #pool)]
end

local function doHop()
    -- caller has already set S.hopping = true
    local s = pickServer(fetchServers())
    if s then
        if CFG.SCRIPT_URL \~= "" then
            local src = 'loadstring(game:HttpGet("' .. CFG.SCRIPT_URL .. '"))()'
            if type(queue_on_teleport) == "function" then
                pcall(queue_on_teleport, src)
            elseif type(queueonteleport) == "function" then
                pcall(queueonteleport, src)
            end
        end
        local browser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
        if browser then
            pcall(function() browser:InvokeServer("teleport", s.Job) end)
        end
        task.wait(8)
    else
        task.wait(3)
    end
    S.enterServer = tick()
    S.hopping = false
end

local function startHop()
    if S.hopping then return end
    S.hopping = true
    task.spawn(doHop)
end

-- ═══════════════ MAIN STEP (every 0.1s) ═══════════════
local function step()
    local now = tick()

    if now - S.tLong >= 1 then
        S.tLong = now
        if S.on then
            ensureTeam()
            pcall(function() CommF:InvokeServer("EnablePvp") end)
            local c = LP.Character
            if c and not c:FindFirstChild("HasBuso") then
                pcall(function() CommF:InvokeServer("Buso") end)
            end
        end
    end

    if not S.on or S.hopping then return end

    local hum = humOf()
    if not hrpOf() or not hum or hum.Health <= 0 then
        clearTarget()
        return
    end

    if S.target then
        if not validTarget(S.target) then
            clearTarget()
        elseif now - S.lockStart >= CFG.LockTime then
            S.skip[S.target] = now + CFG.SkipTime
            clearTarget()
        else
            S.targetRoot = hrpOf(S.target)
        end
    end

    local stayed = now - S.enterServer >= CFG.MaxStay

    if not S.target and now - S.lastPick >= 0.5 then
        S.lastPick = now
        local p = pickTarget()
        if p then setTarget(p) end
    end

    if not bountyAtRisk() then
        if not S.target and (stayed or now - S.enterServer > 3) then
            startHop()
            return
        end
        if S.target and stayed then
            clearTarget()
            startHop()
            return
        end
    end
end

-- ═══════════════ UI ═══════════════
local guiParent = game:GetService("CoreGui")
pcall(function()
    if gethui then guiParent = gethui() end
end)
local oldGui = guiParent:FindFirstChild("ABLiteGui")
if oldGui then oldGui:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "ABLiteGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 80
gui.Parent = guiParent

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, 8)
panel.Size = UDim2.new(0, 260, 0, 44)
panel.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
panel.BackgroundTransparency = 0.15
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local function makeLabel(pos, text)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Position = pos
    l.Size = UDim2.new(0, 120, 0, 36)
    l.Font = Enum.Font.GothamBold
    l.TextSize = 14
    l.TextColor3 = Color3.new(1, 1, 1)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = text
    l.Parent = panel
    return l
end

local bountyLbl = makeLabel(UDim2.new(0, 10, 0, 4), "-")
local timeLbl = makeLabel(UDim2.new(0, 135, 0, 4), "00:00:00")

local toggle = Instance.new("TextButton")
toggle.Position = UDim2.new(0, 10, 0, 64)
toggle.Size = UDim2.new(0, 110, 0, 40)
toggle.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
toggle.BorderSizePixel = 0
toggle.AutoButtonColor = false
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 14
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.Text = "AUTO: OFF"
toggle.Parent = gui
Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 8)

toggle.MouseButton1Click:Connect(function()
    S.on = not S.on
    toggle.Text = S.on and "AUTO: ON" or "AUTO: OFF"
    toggle.BackgroundColor3 = S.on and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(60, 60, 70)
    if not S.on then clearTarget() end
end)

-- ═══════════════ STOP ═══════════════
local function stop()
    S.running = false
    S.on = false
    clearTarget()
    setCollide(true)
    if gui then gui:Destroy() end
end

if getgenv then getgenv().ABLite = { Stop = stop } end

-- ═══════════════ LOOPS ═══════════════
S.startBounty = myBounty()
refreshParts(LP.Character)

LP.CharacterAdded:Connect(function(c)
    clearTarget()
    task.wait(0.5)
    refreshParts(c)
end)

LP.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

-- main logic
task.spawn(function()
    while S.running do
        task.wait(0.1)
        pcall(step)
    end
end)

-- movement
task.spawn(function()
    while S.running do
        task.wait(0.05)
        pcall(function()
            if not S.on or S.hopping or not S.target or not S.targetRoot or not S.targetRoot.Parent then return end
            local now = tick()
            if now - S.angleT >= 0.7 then
                S.angle = math.random() * 6.28
                S.angleT = now
            end
            local off = Vector3.new(math.cos(S.angle) * 8, 0, math.sin(S.angle) * 8)
            moveTo(S.targetRoot.CFrame, off)
            noclip()
        end)
    end
end)

-- skills
local function pressKey(k, hold)
    local code = Enum.KeyCode[k]
    if not code then return end
    VirtualInputManager:SendKeyEvent(true, code, false, game)
    task.wait(hold)
    VirtualInputManager:SendKeyEvent(false, code, false, game)
end

local function equipWeapon()
    local c = LP.Character
    if not c then return end
    local equipped = c:FindFirstChildOfClass("Tool")
    if equipped and equipped.ToolTip == CFG.Weapon then return end
    local tool
    local backpack = LP:FindFirstChild("Backpack")
    for _, container in ipairs({ c, backpack }) do
        if container and not tool then
            for _, item in ipairs(container:GetChildren()) do
                if item:IsA("Tool") and item.ToolTip == CFG.Weapon then
                    tool = item
                    break
                end
            end
        end
    end
    local h = humOf()
    if tool and h then pcall(function() h:EquipTool(tool) end) end
end

task.spawn(function()
    while S.running do
        task.wait(0.2)
        pcall(function()
            if not S.on or S.hopping or not S.target or not S.targetRoot or not S.targetRoot.Parent then return end
            local my = hrpOf()
            if not my then return end
            if (S.targetRoot.Position - my.Position).Magnitude > 120 then return end
            equipWeapon()
            for _, k in ipairs(CFG.SkillKeys) do
                if not S.on or S.hopping or not S.target then return end
                pressKey(k, CFG.HoldTime)
                task.wait(0.3)
            end
            task.wait(0.4)
        end)
    end
end)

-- fast attack kill aura
task.spawn(function()
    while S.running do
        task.wait(0.03)
        pcall(function()
            if not S.on or S.hopping or not S.target or not S.targetRoot or not S.targetRoot.Parent then return end
            local my = hrpOf()
            if not my then return end
            if (S.targetRoot.Position - my.Position).Magnitude > 80 then return end
            equipWeapon()
            fastAttack()
        end)
    end
end)

-- panel updater
task.spawn(function()
    while S.running do
        task.wait(0.5)
        pcall(function()
            bountyLbl.Text = commas(myBounty())
            timeLbl.Text = fmtTime(tick() - S.startT)
        end)
    end
end)