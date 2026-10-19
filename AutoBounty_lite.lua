-- AutoBounty Lite: bounty-only features, no map scans or metatable hooks.

-- Stop a previous copy if it exposed a Stop function
if getgenv then
    local old = getgenv().ABLite
    if type(old) == "table" and type(old.Stop) == "function" then pcall(old.Stop) end
end

repeat task.wait() until game:IsLoaded() and game:GetService("Players").LocalPlayer

-- ═══════════════ SETTINGS ═══════════════
local CFG = {
    LockTime = 90,
    SkipTime = 30,
    MaxStay = 360,
    MinBounty = 3000000,
    MinPlayers = 1,
    MaxPlayers = 12,
    Weapon = "Melee",
    SkillKeys = { "Z", "X", "C" },
    HoldTime = 0.1,
    Team = "Pirates",
    SCRIPT_URL = "",
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
    return string.find(txt, "risk") ~= nil
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
        if s.Job ~= game.JobId then
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
    local s = pickServer(fetchServers())
    if s then
        if CFG.SCRIPT_URL ~= "" then
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

-- ═══════════════ FAST ATTACK KILL AURA (Quantum Onyx port) ═══════════════
local FastAttackSystem = nil
do
    local FA_Workspace = workspace
    local FA_Enemies = FA_Workspace:WaitForChild("Enemies")
    local FA_Remotes = ReplicatedStorage:WaitForChild("Remotes")
    local FA_Modules = ReplicatedStorage:WaitForChild("Modules")
    local FA_Net = FA_Modules:WaitForChild("Net")
    local FA_Character = LP.Character or LP.CharacterAdded:Wait()
    local FA_Humanoid = FA_Character:WaitForChild("Humanoid")
    local FA_Root = FA_Character:WaitForChild("HumanoidRootPart")

    LP.CharacterAdded:Connect(function(c)
        FA_Character = c
        FA_Humanoid = c:WaitForChild("Humanoid")
        FA_Root = c:WaitForChild("HumanoidRootPart")
    end)

    local FA_CombatUtil = require(FA_Modules:WaitForChild("CombatUtil"))
    local FA_CombatController = require(ReplicatedStorage.Controllers.CombatController)
    local FA_Validator2 = FA_Remotes:WaitForChild("Validator2")
    local FA_RegisterAttack = FA_Net:WaitForChild("RE/RegisterAttack")
    local FA_ShootGunEvent = FA_Net:FindFirstChild("RE/ShootGunEvent")
    local FA_RegisterHit = require(FA_Net):RemoteEvent("RegisterHit", true)

    local FA_Obj = setmetatable({}, {
        __index = {
            BodyParts = { "RightLowerArm", "RightUpperArm", "LeftLowerArm", "LeftUpperArm", "RightHand", "LeftHand" },
            LastCombo = 0,
            ComboTime = 0,
            GunDebounce = 0,
            MaxHits = 2,
            IgnoredTools = {},
            OverheatData = {
                Dragonstorm = { MaxOverheat = 3, Cooldown = 0, TotalOverheat = 0, Distance = 500, Shooting = false },
            },
            ShootsPerTarget = { ["Dual Flintlock"] = 2 },
            ShootStyles = {
                ["Skull Guitar"] = "TAP",
                Bazooka = "Position",
                Cannon = "Position",
                Dragonstorm = "Overheat",
            },
            RemoteFruits = { ["Blade-Blade"] = true, ["Gas-Gas"] = true },
            NormalFruits = { ["Light-Light"] = true, ["Ice-Ice"] = true },
        },
    })

    local FA_Cfg = {
        FastSettings = "Fast Attack",
        FastAttackDelay = 0,
        attackmobs = true,
        attackplayers = true,
        AutoKillPlayerinTrial = false,
        MasteryFarm = false,
        HealthMob = 50,
        DoubleAttack = false,
        RemoveAnimationFast = false,
    }

    local function FA_IsReady(obj)
        if not obj or not obj.Parent or not obj:IsDescendantOf(FA_Workspace) then return false end
        if obj.Parent == FA_Workspace:FindFirstChild("Boats") or obj:GetAttribute("IsBoat") or obj.Name:find("Brigade") or obj.Name:find("Boat") or obj.Name:find("Ship") then
            local hp = obj:FindFirstChild("Health")
            if hp then
                if hp:IsA("ValueBase") and hp.Value <= 0 then return false end
                if type(hp.Value) == "number" and hp.Value <= 0 then return false end
            end
            local hum = obj:FindFirstChildOfClass("Humanoid") or obj:FindFirstChild("Humanoid")
            if hum then
                if hum:IsA("Humanoid") and hum.Health <= 0 then return false end
                if hum:IsA("ValueBase") and hum.Value <= 0 then return false end
            end
            if obj:GetAttribute("Dead") == true or obj:GetAttribute("Sunk") == true then return false end
            local engine = obj:FindFirstChild("Engine") or obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
            if not engine or engine.Position.Y < -15 then return false end
            return true
        end
        if obj.Parent == FA_Workspace:FindFirstChild("SeaBeasts") then
            local hp = obj:FindFirstChild("Health")
            return hp and hp.Value > 0
        end
        local hum = obj:FindFirstChildOfClass("Humanoid")
        local root = obj:FindFirstChild("HumanoidRootPart") or obj.PrimaryPart
        return hum and hum.Health > 0 and root and true
    end

    local function FA_ShouldAttackPlayer(player)
        local flag = not (player.Team == LP.Team and tostring(player.Team) == "Marines")
        if flag then
            flag = not (player:HasTag("Ally" .. LP.Name) or LP:HasTag("Ally" .. player.Name))
        end
        return flag
    end

    local FA_UpvalueResult = nil
    pcall(function() FA_UpvalueResult = getupvalue(FA_CombatController.Attack, 9) end)

    local FA_Tbl8 = {}

    local function FA_Validator()
        if not FA_UpvalueResult then
            pcall(function() FA_UpvalueResult = getupvalue(FA_CombatController.Attack, 9) end)
        end
        if not FA_UpvalueResult then return 0, 0 end
        local v19 = getupvalue(FA_UpvalueResult, 15)
        local v20 = getupvalue(FA_UpvalueResult, 13)
        local v21 = getupvalue(FA_UpvalueResult, 16)
        local v22 = getupvalue(FA_UpvalueResult, 17)
        local v23 = getupvalue(FA_UpvalueResult, 14)
        local v24 = getupvalue(FA_UpvalueResult, 18)
        local v25 = getupvalue(FA_UpvalueResult, 19)
        if not v19 or not v20 or not v21 or not v22 or not v23 or not v24 or not v25 then return 0, 0 end
        local n = ((v19 * v23 + v20 * v21) % v22 * v22 + v20 * v23) % v24
        local n2 = math.floor(n / v22)
        local n3 = n - n2 * v22
        local n4 = v25 + 1
        pcall(function()
            setupvalue(FA_UpvalueResult, 15, n2)
            setupvalue(FA_UpvalueResult, 13, n3)
            setupvalue(FA_UpvalueResult, 19, n4)
        end)
        return math.floor(n / v24 * 16777215), n4
    end

    local function FA_PlayAnim()
        pcall(function()
            local eq = FA_Character:FindFirstChild("EquippedWeapon")
            if not FA_Humanoid or not eq then return end
            local cache = FA_CombatUtil:GetMovesetAnimCache(FA_Humanoid)
            local wname = FA_CombatUtil:GetWeaponName(eq)
            local anim = cache[FA_CombatUtil:GetPureWeaponName(wname) .. "-basic" .. math.random(1, #FA_CombatUtil:GetWeaponData(wname).Moveset.Basic)]
            if anim and not FA_Cfg.RemoveAnimationFast then
                anim:Play(0, 1, (anim:GetAttribute("SpeedMult") or 1) * 5)
                anim.TimePosition = 0.01
            end
        end)
    end

    local function FA_MaxHits()
        if FA_Root and FA_Root:FindFirstChild("Buddha") then return 10 end
        return FA_Obj.MaxHits
    end

    local function FA_GetHits(skipMastery, radius)
        local result = {}
        local bodyPart = FA_Obj.BodyParts[math.random(#FA_Obj.BodyParts)]
        radius = radius or 50
        local refRoot = FA_Character and (FA_Character:FindFirstChild("HumanoidRootPart") or FA_Character.PrimaryPart)
        if not refRoot then return result end
        local maxHits = FA_MaxHits()
        local candidates = {}

        if FA_Cfg.attackmobs then
            for i = 1, #FA_Enemies:GetChildren() do
                local ent = FA_Enemies:GetChildren()[i]
                if not ent:GetAttribute("IsBoat") and FA_IsReady(ent) then
                    local entRoot = ent:FindFirstChild("HumanoidRootPart") or ent.PrimaryPart
                    if entRoot then
                        local dist = (entRoot.Position - refRoot.Position).Magnitude
                        if dist <= radius then
                            local skip = false
                            if not skipMastery and FA_Cfg.MasteryFarm then
                                local hum = ent:FindFirstChildOfClass("Humanoid")
                                if hum and hum.Health / hum.MaxHealth <= FA_Cfg.HealthMob / 100 then
                                    skip = true
                                end
                            end
                            if not skip then
                                local part = ent:FindFirstChild(bodyPart) or entRoot
                                table.insert(candidates, { ent, part, dist })
                            end
                        end
                    end
                end
            end
        end

        if FA_Cfg.attackplayers and not LP:GetAttribute("PvpDisabled") then
            local chars = FA_Workspace:FindFirstChild("Characters")
            if chars then
                for _, child in pairs(chars:GetChildren()) do
                    if child ~= FA_Character then
                        local plr = Players:GetPlayerFromCharacter(child)
                        local shouldAttack
                        if plr then
                            shouldAttack = FA_Cfg.AutoKillPlayerinTrial or FA_ShouldAttackPlayer(plr)
                        else
                            shouldAttack = plr
                        end
                        if shouldAttack then
                            local entRoot = child:FindFirstChild("HumanoidRootPart") or child.PrimaryPart
                            if entRoot then
                                local dist = (entRoot.Position - refRoot.Position).Magnitude
                                if dist <= radius then
                                    table.insert(candidates, { child, entRoot, dist })
                                end
                            end
                        end
                    end
                end
            end
        end

        table.sort(candidates, function(a, b) return a[3] < b[3] end)
        for i = 1, math.min(#candidates, maxHits) do
            table.insert(result, { candidates[i][1], candidates[i][2] })
        end
        return result
    end

    local function FA_FillTargets(radius, includePlayers, includeBoats)
        FA_Tbl8 = {}
        radius = radius or 500
        local refChar = FA_Character
        local refRoot
        if refChar then
            refRoot = refChar:FindFirstChild("HumanoidRootPart") or refChar.PrimaryPart
        end
        if not refRoot then return end
        local found = {}

        if includePlayers or FA_Cfg.attackmobs then
            for _, child in ipairs(FA_Enemies:GetChildren()) do
                local notBoat = not child:GetAttribute("IsBoat")
                if notBoat and FA_IsReady(child) and child ~= refChar then
                    local part = child.PrimaryPart or child:FindFirstChild("HumanoidRootPart")
                    local plr = Players:GetPlayerFromCharacter(child)
                    local inChars = child.Parent == FA_Workspace:FindFirstChild("Characters")
                    if part and (not inChars or (plr and FA_ShouldAttackPlayer(plr))) then
                        local dist = (refRoot.Position - part.Position).Magnitude
                        if dist <= radius then
                            table.insert(found, { child, part, dist })
                        end
                    end
                end
            end
        end

        if includePlayers or (FA_Cfg.attackplayers and not LP:GetAttribute("PvpDisabled")) then
            local chars = FA_Workspace:FindFirstChild("Characters")
            if chars then
                for _, child in ipairs(chars:GetChildren()) do
                    if child ~= refChar then
                        local plr = Players:GetPlayerFromCharacter(child)
                        local shouldAttack
                        if plr then
                            shouldAttack = FA_Cfg.AutoKillPlayerinTrial or FA_ShouldAttackPlayer(plr)
                        else
                            shouldAttack = plr
                        end
                        if shouldAttack then
                            local entRoot = child:FindFirstChild("HumanoidRootPart") or child.PrimaryPart
                            if entRoot then
                                local dist = (refRoot.Position - entRoot.Position).Magnitude
                                if dist <= radius then
                                    table.insert(found, { child, entRoot, dist })
                                end
                            end
                        end
                    end
                end
            end
        end

        if includeBoats then
            local sb = FA_Workspace:FindFirstChild("SeaBeasts")
            if sb then
                for _, child in ipairs(sb:GetChildren()) do
                    local part = child:FindFirstChildOfClass("MeshPart") or child:FindFirstChild("HumanoidRootPart") or child.PrimaryPart
                    if FA_IsReady(child) and part then
                        local dist = (refRoot.Position - part.Position).Magnitude
                        if dist < radius then
                            table.insert(found, { child, part, dist })
                        end
                    end
                end
            end
            for _, child in ipairs(FA_Enemies:GetChildren()) do
                if child:GetAttribute("IsBoat") then
                    local part = child:FindFirstChildOfClass("MeshPart") or child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
                    if FA_IsReady(child) and part then
                        local dist = (refRoot.Position - part.Position).Magnitude
                        if dist < radius then
                            table.insert(found, { child, part, dist })
                        end
                    end
                end
            end
        end

        table.sort(found, function(a, b) return a[3] < b[3] end)
        for _, v in ipairs(found) do
            table.insert(FA_Tbl8, { v[1], v[2] })
        end
    end

    local function FA_GetFirst()
        if #FA_Tbl8 == 0 then return nil, nil end
        local v = FA_Tbl8[1]
        if not v or not v[2] then return nil, nil end
        return v[2].Position, v[2]
    end

    local function FA_GetNearest(radius)
        FA_FillTargets(radius, true, true)
        if #FA_Tbl8 > 0 and FA_Tbl8[1] and FA_Tbl8[1][2] then
            return FA_Tbl8[1][2]
        end
        return nil
    end

    local FA_Handlers = {
        ["Skull Guitar"] = function(tool, pos)
            tool.RemoteEvent:FireServer("TAP", pos)
        end,
    }

    local function FA_ShootGun()
        local tool = FA_Character and FA_Character:FindFirstChildOfClass("Tool")
        if not tool or tool.ToolTip ~= "Gun" then
            local bp = LP:FindFirstChild("Backpack")
            if bp then
                for _, child in ipairs(bp:GetChildren()) do
                    if child:IsA("Tool") and child.ToolTip == "Gun" then
                        if FA_Character and FA_Character:FindFirstChildOfClass("Humanoid") then
                            FA_Character.Humanoid:EquipTool(child)
                            tool = child
                            task.wait(0.05)
                        end
                        break
                    end
                end
            end
        end
        if not tool or not tool.Enabled then return end
        tool.Enabled = true
        tool:SetAttribute("IsReloading_Client", false)
        tool:SetAttribute("LocalShotsLeft", 100)
        tool:SetAttribute("LocalTotalShots", (tool:GetAttribute("LocalTotalShots") or 0) + 1)
        local dist = 500
        if FA_Obj.OverheatData[tool.Name] then dist = FA_Obj.OverheatData[tool.Name].Distance end

        FA_FillTargets(dist, false, true)
        if #FA_Tbl8 == 0 then
            local nearest = FA_GetNearest(dist)
            if nearest then
                table.insert(FA_Tbl8, { nearest.Parent, nearest })
            end
        end
        if #FA_Tbl8 == 0 then return end

        local pos, part = FA_GetFirst()
        if not pos or not part then return end

        if FA_Handlers[tool.Name] then
            FA_Handlers[tool.Name](tool, pos)
            return
        end

        local style = FA_Obj.ShootStyles[tool.Name]
        if not style then
            style = tool:FindFirstChild("RemoteEvent") and "TAP" or "Normal"
        end
        local shots = FA_Obj.ShootsPerTarget[tool.Name] or 1

        pcall(function()
            local code, seq = FA_Validator()
            FA_Validator2:FireServer(code, seq)
            if tool:FindFirstChild("RemoteEvent") and (style == "TAP" or tool.Name == "Skull Guitar") then
                tool.RemoteEvent:FireServer("TAP", pos)
            elseif FA_ShootGunEvent then
                for i = 1, shots do
                    FA_ShootGunEvent:FireServer(pos, { part })
                end
            end
        end)
    end

    local function FA_BloxFruitClick(combo, tool)
        if not tool or not tool:FindFirstChild("LeftClickRemote") then return end
        local root = FA_Character and FA_Character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local myPos = root.Position

        for _, child in ipairs(FA_Enemies:GetChildren()) do
            if FA_IsReady(child) and not child:GetAttribute("IsBoat") then
                local part = child.PrimaryPart or child:FindFirstChild("HumanoidRootPart")
                if part and (part.Position - myPos).Magnitude <= 60 then
                    tool.LeftClickRemote:FireServer((part.Position - myPos).Unit, combo)
                end
            end
        end

        local sb = FA_Workspace:FindFirstChild("SeaBeasts")
        if sb then
            for _, child in ipairs(sb:GetChildren()) do
                if FA_IsReady(child) then
                    local part = child:FindFirstChildOfClass("MeshPart") or child.PrimaryPart
                    if part and (part.Position - myPos).Magnitude <= 70 then
                        tool.LeftClickRemote:FireServer(Vector3.new(0.01, -500, 0.01), 1, true)
                    end
                end
            end
        end
    end

    local function FA_FindFruitInBackpack()
        local bp = LP:FindFirstChild("Backpack")
        if not bp then return nil end
        for _, child in ipairs(bp:GetChildren()) do
            if child:IsA("Tool") and child.ToolTip == "Blox Fruit" and child:FindFirstChild("LeftClickRemote") then
                return child
            end
        end
        return nil
    end

    local function FA_Attack()
        local tool = FA_Character and FA_Character:FindFirstChildOfClass("Tool")
        local tooltip = tool and tool.ToolTip

        if FA_Cfg.DoubleAttack then
            local fruit = FA_FindFruitInBackpack()
            if fruit and fruit:FindFirstChild("LeftClickRemote") then
                pcall(function()
                    fruit.LeftClickRemote:FireServer(Vector3.new(0.01, -500, 0.01), 1, true)
                end)
            end
        end

        if not tool then
            if not FA_Cfg.DoubleAttack then return end
            local fruit = FA_FindFruitInBackpack()
            if not fruit then return end
            tool = fruit
            tooltip = "Blox Fruit"
        end

        if not table.find({ "Melee", "Blox Fruit", "Sword", "Gun" }, tooltip) then return end

        if FA_Cfg.FastSettings == "Fast Attack" then
            if tooltip == "Gun" then
                FA_ShootGun()
                return
            end
            local lcr = tool:FindFirstChild("LeftClickRemote")
            local hits = FA_GetHits(tooltip == "Blox Fruit" and lcr ~= nil)

            if tooltip == "Blox Fruit" and not FA_Obj.NormalFruits[tool.Name] and not FA_Obj.RemoteFruits[tool.Name] then
                if tool:FindFirstChild("LeftClickRemote") and (FA_Cfg.DoubleAttack or FA_Character:FindFirstChildOfClass("Tool") == tool) then
                    pcall(function()
                        tool.LeftClickRemote:FireServer(Vector3.new(0.01, -500, 0.01), 1, true)
                    end)
                end
            elseif tooltip == "Blox Fruit" and FA_Obj.RemoteFruits[tool.Name] then
                local last = FA_Obj.LastCombo
                local ct = FA_Obj.ComboTime
                if tick() - ct > 0.65 then last = 0 end
                local nextCombo
                if last >= 5 then nextCombo = 1 else nextCombo = last + 1 end
                FA_Obj.LastCombo = nextCombo
                FA_Obj.ComboTime = tick()
                if tool:FindFirstChild("LeftClickRemote") then
                    FA_BloxFruitClick(nextCombo, tool)
                end
            else
                FA_RegisterAttack:FireServer(FA_Cfg.FastAttackDelay or 0.3)
                FA_PlayAnim()
                local hitsArr = {}
                local firstPart = nil
                for _, hit in ipairs(hits) do
                    if hit[1] and hit[2] then
                        table.insert(hitsArr, hit)
                        firstPart = firstPart or hit[2]
                    end
                end
                if firstPart and FA_RegisterHit then
                    FA_RegisterHit:FireServer(firstPart, hitsArr, nil, nil, tostring(LP.UserId):sub(2, 4) .. tostring(coroutine.running()):sub(11, 15))
                end
            end

            if FA_Cfg.DoubleAttack and tooltip == "Blox Fruit" then
                local fruit = FA_FindFruitInBackpack()
                if fruit and fruit ~= tool and fruit:FindFirstChild("LeftClickRemote") then
                    if FA_Obj.RemoteFruits and FA_Obj.RemoteFruits[fruit.Name] then
                        FA_BloxFruitClick(FA_Obj.LastCombo or 1, fruit)
                    else
                        pcall(function()
                            fruit.LeftClickRemote:FireServer(Vector3.new(0.01, -500, 0.01), 1, true)
                        end)
                    end
                end
            end
        end
    end

    FastAttackSystem = setmetatable({
        Attack = FA_Attack,
        ShootGun = FA_ShootGun,
        GetHits = FA_GetHits,
    }, {
        __call = function(self)
            return FA_Attack()
        end,
    })
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

-- fast attack kill aura loop
task.spawn(function()
    while S.running do
        task.wait(0.1)
        pcall(function()
            if not S.on or S.hopping then return end
            if not FastAttackSystem then return end
            local c = LP.Character
            if not c then return end
            local h = c:FindFirstChildOfClass("Humanoid")
            if not h or h.Health <= 0 then return end
            FastAttackSystem()
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