--// Services
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

-- Wait for LocalPlayer
local LocalPlayer
repeat
    LocalPlayer = Players.LocalPlayer
    task.wait()
until LocalPlayer

--// USER CONFIG – set these in your script-executor UI or via getgenv()
--  webhooks for the 3 value brackets
--// state
local visitedJobIds = {[game.JobId] = true}
local hops = 0
local maxHopsBeforeReset = 50
local teleportFails = 0
local maxTeleportRetries = 3
local detectedPets = {}       -- [model] = true
local webhookSent = false
local stopHopping = false

--// teleport fail handler
TeleportService.TeleportInitFailed:Connect(function(_, result)
    teleportFails += 1
    if result == Enum.TeleportResult.GameFull then
        warn("⚠️ Game full. Retrying teleport...")
    elseif result == Enum.TeleportResult.Unauthorized then
        warn("❌ Unauthorized/private server. Blacklisting...")
        visitedJobIds[game.JobId] = true
    else
        warn("❌ Other teleport error:", result)
    end

    if teleportFails >= maxTeleportRetries then
        warn("⚠️ Too many fails – forcing fresh server")
        teleportFails = 0
        task.wait(1)
        TeleportService:Teleport(game.PlaceId)
    else
        task.wait(1)
        serverHop()
    end
end)

--// ESP
local function addESP(model)
    if model:FindFirstChild("PetESP") then return end
    local b = Instance.new("BillboardGui")
    b.Name  = "PetESP"
    b.Adornee = model
    b.Size  = UDim2.new(0,100,0,30)
    b.StudsOffset = Vector3.new(0,3,0)
    b.AlwaysOnTop = true
    b.Parent = model
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1,0,1,0)
    l.BackgroundTransparency = 1
    l.Text = "🎯 Target Pet"
    l.TextColor3 = Color3.new(1,0,0)
    l.TextStrokeTransparency = .5
    l.Font = Enum.Font.SourceSansBold
    l.TextScaled = true
    l.Parent = b
end

--// value parser – returns number (1 000 000) from "$1m/s" or "$100m/s" etc
local function extractValue(str)
    if type(str) ~= "string" then return 0 end
    local cleaned = str:lower():match("%$([%d%.]+)([kmb]?)")
    if not cleaned then return 0 end
    local num = tonumber(cleaned:match("[%d%.]+")) or 0
    local suffix = cleaned:match("[kmb]")
    if suffix == "k" then num = num * 1e3
    elseif suffix == "m" then num = num * 1e6
    elseif suffix == "b" then num = num * 1e9
    end
    return num
end

--// pick webhook url by value
local function pickWebhook(val)
    if val >= 20_000_000 then return getgenv().webhook20mUp end
    if val >= 6_000_000  then return getgenv().webhook6m20m end
    if val >= 1_000_000  then return getgenv().webhook1m5m   end
    return nil
end

--// webhook sender
local function sendWebhook(batch)
    -- batch = { {name="Foo",gen="Bar",val=5_000_000}, ... }
    if #batch == 0 then return end
    stopHopping = true

    -- group by bracket
    local groups = {        -- bracket -> { totalVal = 0, pets = {name=count} }
        ["1m-5m"]   = {pets={}, totalVal=0},
        ["6m-20m"]  = {pets={}, totalVal=0},
        ["20m+"]    = {pets={}, totalVal=0}
    }
    for _,p in ipairs(batch) do
        local bracket =
            p.val >= 20_000_000 and "20m+"  or
            p.val >= 6_000_000  and "6m-20m" or "1m-5m"
        local g = groups[bracket]
        g.pets[p.name] = (g.pets[p.name] or 0) + 1
        g.totalVal = g.totalVal + p.val
    end

    -- send 1 webhook per bracket that has stuff
    for bracket, g in pairs(groups) do
        if next(g.pets) == nil then continue end
        local url =
            bracket == "20m+"   and getgenv().webhook20mUp or
            bracket == "6m-20m" and getgenv().webhook6m20m or
            getgenv().webhook1m5m
        if not url or url == "" then continue end

        local lines = {}
        for name,count in pairs(g.pets) do
            table.insert(lines, count==1 and name or name.." x"..count)
        end
        local serverLink = "[Join](https://fern.wtf/joiner?placeId="..game.PlaceId.."&gameInstanceId="..game.JobId..")"
        local plrCount = #Players:GetPlayers()
        local maxPlrs   = Players.MaxPlayers
        local embed = {
            title = "🧠 Pet(s) Found! ("..bracket..")",
            description = "Brainrot-worthy pet(s) detected!",
            fields = {
                {name="User", value=LocalPlayer.Name},
                {name="Pet(s)", value=table.concat(lines,"\n")},
                {name="Players", value=plrCount.."/"..maxPlrs, inline=true},
                {name="Server Link", value=serverLink},
                {name="Time", value=os.date("%Y-%m-%d %H:%M:%S")}
            },
            color = 0xff00ff
        }
        local payload = HttpService:JSONEncode({content="🚨 SECRET PET DETECTED!", embeds={embed}})

        local req = http_request or request or syn and syn.request
        if req then
            local ok,err = pcall(function()
                req({Url=url, Method="POST", Headers={["Content-Type"]="application/json"}, Body=payload})
            end)
            if ok then print("✅ Webhook sent ("..bracket..")") else warn("❌ Webhook fail:",err) end
        else
            warn("❌ Executor doesn't support HTTP")
        end
    end

    task.delay(2, function()
        stopHopping = false
        serverHop()
    end)
end

--// scan 1 FastOverheadTemplate
local function scanTemplate(temp)
    local results = {}
    if not temp:FindFirstChild("AnimalOverhead") then return results end
    local ah = temp.AnimalOverhead
    local display = ah:FindFirstChild("DisplayName")
    local generation = ah:FindFirstChild("Generation")
    local contentText = ah:FindFirstChild("ContentText")
    if not (display and generation and contentText) then return results end

    local name = display.Value or display.Text or ""
    local gen  = generation.Value or generation.Text or ""
    local val  = extractValue(contentText.Value or contentText.Text or "")
    if val >= 1_000_000 then
        table.insert(results, {name=name, gen=gen, val=val, model=temp})
    end
    return results
end

--// full scan
local function checkForPets()
    local found = {}
    local debris = workspace:FindFirstChild("Debris")
    if not debris then return found end
    for _,obj in ipairs(debris:GetChildren()) do
        if obj.Name == "FastOverheadTemplate" and not detectedPets[obj] then
            for _,pet in ipairs(scanTemplate(obj)) do
                table.insert(found, pet)
                detectedPets[obj] = true
                addESP(obj)
            end
        end
    end
    return found
end

--// live detection
workspace.DescendantAdded:Connectfunction(inst)
    task.wait(.25)
    if inst.Name == "FastOverheadTemplate" and inst.Parent == workspace:FindFirstChild("Debris") then
        local batch = scanTemplate(inst)
        if #batch > 0 and not detectedPets[inst] then
            detectedPets[inst] = true
            for _,p in ipairs(batch) do addESP(p.model) end
            sendWebhook(batch)
        end
    end
end)

--// server hop
function serverHop()
    if stopHopping then return end
    task.wait(1.5)
    local cursor = nil
    local PlaceId,JobId = game.PlaceId,game.JobId
    local tries = 0
    hops += 1
    if hops >= maxHopsBeforeReset then
        visitedJobIds = {[JobId]=true}
        hops = 0
        print("♻️ Reset visited JobIds")
    end
    while tries < 3 do
        local url = "https://games.roblox.com/v1/games/"..PlaceId.."/servers/Public?sortOrder=Asc&limit=100"
        if cursor then url = url.."&cursor="..cursor end
        local ok,resp = pcall(function() return HttpService:JSONDecode(game:HttpGet(url)) end)
        if ok and resp and resp.data then
            local list = {}
            for _,s in ipairs(resp.data) do
                if tonumber(s.playing or 0) < tonumber(s.maxPlayers or 1) and s.id ~= JobId and not visitedJobIds[s.id] then
                    table.insert(list, s.id)
                end
            end
            if #list > 0 then
                local pick = list[math.random(1,#list)]
                print("✅ Hopping to",pick)
                teleportFails = 0
                TeleportService:TeleportToPlaceInstance(PlaceId,pick)
                return
            end
            cursor = resp.nextPageCursor
            if not cursor then tries += 1 cursor = nil task.wait(.5) end
        else
            warn("⚠️ Failed to fetch servers")
            tries += 1
            task.wait(.5)
        end
    end
    warn("❌ No servers – forcing random")
    TeleportService:Teleport(PlaceId)
end

--// start
task.wait(6)
local batch = checkForPets()
if #batch > 0 then
    sendWebhook(batch)
else
    print("🔍 Nothing found – hopping")
    task.delay(1.5, serverHop)
end
