if not getgenv().AutoTradingConfig then
    error("❌ ไม่พบ AutoTradingConfig! กรุณาโหลด Config ก่อน")
    return
end

local config = getgenv().AutoTradingConfig

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer


------------------------------------------------
-- Anti AFK (VirtualUser - กันหลุดแน่นอน)
------------------------------------------------
local VirtualUser = game:GetService("VirtualUser")
Players.LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new(0, 0))
    if config.printLogs then
        print("🛡️ [Anti-AFK] VirtualUser prevented kick")
    end
end)


-- ตัวแปรสำหรับระบบ
local AutoTradingSystem = {
    sellingActive = false,
    buyingActive = false,
    autoClaimActive = false,
    antiAfkActive = false,
    lastRichestCoins = 0,
    statusLabel = nil,
    moneyLabel = nil,
    gui = nil,
    retryCount = 0,
    lastAfkTime = 0
}

-- ฟังก์ชัน Debug Log
local function debugPrint(message)
    if config.debugMode and config.printLogs then
        print("🔧 [AutoTrading] " .. message)
    end
end

-- ฟังก์ชัน Error Handler
local function handleError(funcName, error)
    warn("❌ [AutoTrading Error in " .. funcName .. "] " .. tostring(error))
    
    if config.safeMode then
        AutoTradingSystem.retryCount = AutoTradingSystem.retryCount + 1
        if AutoTradingSystem.retryCount >= config.maxRetries then
            warn("🛑 หยุดการทำงานเนื่องจากข้อผิดพลาดเกินกำหนด")
            AutoTradingSystem:stopAll()
        end
    end
end

-- ฟังก์ชันตรวจสอบและวาร์ปไปโลกเป้าหมาย
function AutoTradingSystem:teleportIfNeeded()
    if game.PlaceId ~= config.targetWorldId then
        debugPrint("กำลังวาร์ปไปโลกเป้าหมาย...")
        local success, error = pcall(function()
            local teleportArgs = {config.targetWorldId, {}}
            local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("WorldTeleportRemote")
            remote:InvokeServer(unpack(teleportArgs))
        end)
        
        if not success then
            handleError("teleportIfNeeded", error)
        end
        return success
    end
    return false
end
-- ฟังก์ชันวาร์ปไปตลาด (แบบตรวจสอบ Part จริงก่อน)
-- ฟังก์ชันวาร์ปไปตลาด (ตรวจสอบตำแหน่งทีละขั้น)
function AutoTradingSystem:teleportToMarket()
    if not config.autoTeleportToMarket then return false end

    local success, error = pcall(function()
        local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
        local hrp = character:WaitForChild("HumanoidRootPart", 10)

        if not hrp then
            warn("❌ ไม่สามารถหา HumanoidRootPart ได้")
            return false
        end

        if character.PrimaryPart == nil then
            character.PrimaryPart = hrp
        end

        -- ✅ ขั้นแรก: วาร์ปไปตำแหน่งเริ่มต้น
        local startPos = Vector3.new(-1262, 298, -1379)
        character:SetPrimaryPartCFrame(CFrame.new(startPos))
        debugPrint("✅ วาร์ปไปตำแหน่งเริ่มต้นแล้ว")

        -- รอ 1 วิ แล้วตรวจสอบว่าอยู่ใกล้จริงหรือไม่
        task.wait(1)
        local distance = (hrp.Position - startPos).Magnitude
        if distance > 10 then
            warn("❌ ไม่ได้วาร์ปมาตำแหน่งเริ่มต้น ระยะห่าง:", distance)
            return false
        end
        debugPrint("✅ อยู่ที่ตำแหน่งเริ่มต้นเรียบร้อย")

        task.wait(1)

        -- ✅ ขั้นสอง: หา BillboardPart
        local interactions = workspace:FindFirstChild("Interactions")
        if not interactions then return warn("❌ ไม่มี Interactions ใน workspace") end

        local playerMarket = interactions:FindFirstChild("PlayerMarket")
        if not playerMarket then return warn("❌ ไม่มี PlayerMarket ใน Interactions") end

        local billboardPart = playerMarket:FindFirstChild("BillboardPart")
        if not billboardPart then return warn("❌ ไม่มี BillboardPart ใน PlayerMarket") end

        -- ✅ วาร์ปไป BillboardPart
        character:SetPrimaryPartCFrame(billboardPart.CFrame + Vector3.new(0, 5, 0))
        debugPrint("✅ วาร์ปไป BillboardPart สำเร็จ")

        -- ตรวจสอบว่ามาถึงจริงหรือยัง
        task.wait(1)
        local distance2 = (hrp.Position - billboardPart.Position).Magnitude
        if distance2 > 10 then
            warn("❌ ไม่ได้มาถึง BillboardPart ระยะห่าง:", distance2)
            return false
        end

        debugPrint("🎯 มาถึง BillboardPart เรียบร้อย")
        return true
    end)

    if not success then
        handleError("teleportToMarket", error)
    end
    return success
end


-- ฟังก์ชันหาผู้เล่นที่มีเงินมากที่สุด
function AutoTradingSystem:getRichestPlayer()
    local richestPlayer = nil
    local maxCoins = 0
    
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local success, coins = pcall(function()
                return player:WaitForChild("Data", 2):WaitForChild("Currency", 2):WaitForChild("Coins", 2).Value
            end)
            
            if success and coins > maxCoins then
                maxCoins = coins
                richestPlayer = player
            end
        end
    end
    
    return richestPlayer, maxCoins
end

-- ฟังก์ชันรับเงินของตัวเอง
function AutoTradingSystem:getMyMoney()
    local success, coins = pcall(function()
        return LocalPlayer:WaitForChild("Data", 2):WaitForChild("Currency", 2):WaitForChild("Coins", 2).Value
    end)
    
    return success and coins or 0
end

-- ฟังก์ชันขายไอเทม
function AutoTradingSystem:sellItem(price)
    local success, error = pcall(function()
        local args = {{
            Price = price,
            ItemType = config.sellItemType,
            Name = config.sellItemName,
            Amount = config.sellAmount
        }}
        ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SellPlayerMarketRemote"):InvokeServer(unpack(args))
    end)
    
    if not success then
        handleError("sellItem", error)
    end
    return success
end

-- ฟังก์ชันซื้อจากตลาด
function AutoTradingSystem:buyFromMarket(index, playerName)
    local success, error = pcall(function()
        local args = {{
            Index = tostring(index),
            Player = Players:WaitForChild(playerName)
        }}
        ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PurchasePlayerMarketRemote"):FireServer(unpack(args))
    end)
    
    if not success then
        handleError("buyFromMarket", error)
    end
    return success
end

-- ฟังก์ชันรับเงินจากตลาด
function AutoTradingSystem:claimMoney()
    local claimRange = config.claimIndexRange
    for i = claimRange[1], claimRange[2] do
        pcall(function()
            local args = {tostring(i)}
            ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ClaimPlayerMarketRemote"):FireServer(unpack(args))
        end)
        task.wait(0.1)
    end
end

-- ระบบรับเงินอัตโนมัติ
function AutoTradingSystem:startAutoClaim()
    if not config.autoClaimEnabled then return end
    
    self.autoClaimActive = true
    debugPrint("เริ่มรับเงินอัตโนมัติ")
    
    task.spawn(function()
        while self.autoClaimActive do
            self:claimMoney()
            task.wait(config.claimInterval)
        end
    end)
end

-- ระบบ Anti-AFK
function AutoTradingSystem:startAntiAfk()
    if not config.antiAfkEnabled then return end
    if self.antiAfkActive then return end

    self.antiAfkActive = true
    debugPrint("🛡️ เริ่ม Anti-AFK (ทุก " .. config.antiAfkInterval .. " วินาที)")

    task.spawn(function()
        while self.antiAfkActive do
            task.wait(config.antiAfkInterval) -- ⏱️ 60 วิจริง
            if not self.antiAfkActive then break end

            pcall(function()
                self:performAntiAfkActions()
            end)
        end
    end)
end

-- ทำการกระทำป้องกัน AFK
function AutoTradingSystem:performAntiAfkActions()
    local character = LocalPlayer.Character
    if not character then return end
    
    local humanoid = character:FindFirstChild("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    
    debugPrint("ทำการป้องกัน AFK...")
    
    -- กระโดด
    if config.antiAfkMethods.jumpEnabled and humanoid then
        pcall(function()
            humanoid.Jump = true
        end)
    end
    
    -- เดินสั้นๆ
    if config.antiAfkMethods.moveEnabled and humanoid then
        pcall(function()
            local moveVector = Vector3.new(
                math.random(-1, 1) * 0.1,
                0,
                math.random(-1, 1) * 0.1
            )
            humanoid:Move(moveVector)
            task.wait(0.1)
            humanoid:Move(Vector3.new(0, 0, 0)) -- หยุดเดิน
        end)
    end
    
    -- หมุนกล้อง
    if config.antiAfkMethods.cameraEnabled then
        pcall(function()
            local camera = workspace.CurrentCamera
            if camera and rootPart then
                local originalCFrame = camera.CFrame
                local randomAngle = math.rad(math.random(-10, 10))
                camera.CFrame = camera.CFrame * CFrame.Angles(0, randomAngle, 0)
                task.wait(0.2)
                camera.CFrame = originalCFrame
            end
        end)
    end
    
    -- ส่งแชท (ใช้ระวัง)
    if config.antiAfkMethods.chatEnabled and #config.antiAfkMessages > 0 then
        pcall(function()
            local randomMessage = config.antiAfkMessages[math.random(1, #config.antiAfkMessages)]
            local chatRemote = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            if chatRemote then
                chatRemote = chatRemote:FindFirstChild("SayMessageRequest")
                if chatRemote then
                    chatRemote:FireServer(randomMessage, "All")
                end
            end
        end)
    end
    
    debugPrint("ป้องกัน AFK เสร็จแล้ว")
end

-- หยุดระบบ Anti-AFK
function AutoTradingSystem:stopAntiAfk()
    self.antiAfkActive = false
    debugPrint("หยุดระบบ Anti-AFK")
end

-- อัพเดทข้อมูลเงินในเกม
function AutoTradingSystem:updateMoneyDisplay()
    if self.moneyLabel and config.showMoneyDisplay then
        local myMoney = self:getMyMoney()
        self.moneyLabel.Text = "💰 เงิน: " .. tostring(myMoney) .. " Coins"
    end
end

-- ระบบขายอัตโนมัติ
function AutoTradingSystem:startAutoSelling()
    if not config.autoSellEnabled then return end
    
    self.sellingActive = true
    debugPrint("เริ่มขายอัตโนมัติ")
    
    -- เช็คโลกและวาร์ปก่อน
    if self:teleportIfNeeded() then
        task.wait(5)
    end
    self:teleportToMarket()
    
    task.spawn(function()
        while self.sellingActive do
            if config.advancedSettings.sellOnlyToRichest then
                local richestPlayer, coins = self:getRichestPlayer()
                
                if richestPlayer and coins > 0 then
                    if not config.advancedSettings.waitForMoneyChange or coins ~= self.lastRichestCoins then
                        debugPrint("ขายให้ " .. richestPlayer.Name .. " ราคา " .. coins)
                        self:sellItem(coins)
                        self.lastRichestCoins = coins
                        
                        if self.statusLabel then
                            self.statusLabel.Text = "สถานะ: ขายให้ " .. richestPlayer.Name .. " ราคา " .. coins
                        end
                        
                        task.wait(2)
                    else
                        debugPrint("รอเงินเปลี่ยนแปลง...")
                        if self.statusLabel then
                            self.statusLabel.Text = "สถานะ: รอเงินเปลี่ยนแปลง..."
                        end
                        task.wait(config.sellCheckInterval)
                    end
                else
                    debugPrint("ไม่มีผู้เล่นที่มีเงิน")
                    if self.statusLabel then
                        self.statusLabel.Text = "สถานะ: ไม่มีผู้เล่นที่มีเงิน"
                    end
                    task.wait(5)
                end
            end
        end
    end)
end

-- ระบบซื้ออัตโนมัติ
function AutoTradingSystem:startAutoBuying()
    if not config.autoBuyEnabled then return end
    
    self.buyingActive = true
    debugPrint("เริ่มซื้ออัตโนมัติจาก " .. config.targetBuyerName)
    
    task.spawn(function()
        while self.buyingActive do
            local buyRange = config.buyIndexRange
            for i = buyRange[1], buyRange[2] do
                if not self.buyingActive then break end
                
                local success = self:buyFromMarket(i, config.targetBuyerName)
                if success then
                    debugPrint("ซื้อสำเร็จ Index " .. i)
                    if self.statusLabel then
                        self.statusLabel.Text = "สถานะ: ซื้อสำเร็จ Index " .. i
                    end
                else
                    if not config.advancedSettings.skipEmptySlots then
                        debugPrint("ซื้อไม่สำเร็จ Index " .. i)
                    end
                end
                task.wait(config.buyCheckInterval)
            end
            
            -- รีเฟรชหน้าร้าน
            if config.advancedSettings.autoRefreshMarket then
                debugPrint("รีเฟรชหน้าร้าน...")
                self:teleportToMarket()
                task.wait(config.buyRefreshInterval)
            end
        end
    end)
end

-- หยุดระบบทั้งหมด
function AutoTradingSystem:stopAll()
    self.sellingActive = false
    self.buyingActive = false
    self.autoClaimActive = false
    self.antiAfkActive = false
    debugPrint("หยุดระบบทั้งหมด")
end

-- ฟังก์ชันทำให้ GUI ลากได้
function AutoTradingSystem:makeDraggable(frame)
    if not config.guiSettings.draggable then return end
    
    local dragging = false
    local dragStart = nil
    local startPos = nil
    
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    
    frame.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- สร้าง GUI
function AutoTradingSystem:createGUI()
    if not config.guiSettings.enabled then return end
    
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "AutoTradingGUI"
    screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    self.gui = screenGui
    
    local guiSize = config.guiSettings.size
    local guiPos = config.guiSettings.position
    local colors = config.guiSettings.colors
    
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, guiSize[1], 0, guiSize[2])
    frame.Position = UDim2.new(guiPos[1], -guiSize[1]/2, guiPos[2], -guiSize[2]/2)
    frame.BackgroundColor3 = Color3.fromRGB(colors.background[1], colors.background[2], colors.background[3])
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Parent = screenGui
    
    self:makeDraggable(frame)
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame
    
    -- Title
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Text = "🍎 Auto Trading System v2.0"
    title.BackgroundTransparency = 1
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.Parent = frame
    
    local yOffset = 45
    
    -- Player Name Display
    if config.showPlayerInfo then
        local playerLabel = Instance.new("TextLabel")
        playerLabel.Size = UDim2.new(1, -20, 0, 25)
        playerLabel.Position = UDim2.new(0, 10, 0, yOffset)
        playerLabel.Text = "👤 ผู้เล่น: " .. LocalPlayer.Name
        playerLabel.BackgroundTransparency = 1
        playerLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
        playerLabel.Font = Enum.Font.GothamBold
        playerLabel.TextSize = 16
        playerLabel.TextXAlignment = Enum.TextXAlignment.Left
        playerLabel.Parent = frame
        yOffset = yOffset + 30
    end
    
    -- Money Display
    if config.showMoneyDisplay then
        self.moneyLabel = Instance.new("TextLabel")
        self.moneyLabel.Size = UDim2.new(1, -20, 0, 25)
        self.moneyLabel.Position = UDim2.new(0, 10, 0, yOffset)
        self.moneyLabel.Text = "💰 เงิน: 0 Coins"
        self.moneyLabel.BackgroundTransparency = 1
        self.moneyLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
        self.moneyLabel.Font = Enum.Font.GothamBold
        self.moneyLabel.TextSize = 16
        self.moneyLabel.TextXAlignment = Enum.TextXAlignment.Left
        self.moneyLabel.Parent = frame
        
        -- อัพเดทเงินทุก 2 วินาที
        task.spawn(function()
            while screenGui.Parent do
                self:updateMoneyDisplay()
                task.wait(config.moneyUpdateInterval)
            end
        end)
        yOffset = yOffset + 30
    end
    
    -- Target Buyer Input
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -20, 0, 25)
    nameLabel.Position = UDim2.new(0, 10, 0, yOffset)
    nameLabel.Text = "ชื่อผู้เล่นที่จะซื้อจาก:"
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextColor3 = Color3.new(1, 1, 1)
    nameLabel.Font = Enum.Font.Gotham
    nameLabel.TextSize = 14
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Parent = frame
    yOffset = yOffset + 25
    
    local nameInput = Instance.new("TextBox")
    nameInput.Size = UDim2.new(1, -20, 0, 30)
    nameInput.Position = UDim2.new(0, 10, 0, yOffset)
    nameInput.Text = config.targetBuyerName
    nameInput.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    nameInput.BorderSizePixel = 0
    nameInput.TextColor3 = Color3.new(1, 1, 1)
    nameInput.Font = Enum.Font.Gotham
    nameInput.TextSize = 14
    nameInput.Parent = frame
    
    local inputCorner = Instance.new("UICorner")
    inputCorner.CornerRadius = UDim.new(0, 5)
    inputCorner.Parent = nameInput
    yOffset = yOffset + 40
    
    -- Status Label
    self.statusLabel = Instance.new("TextLabel")
    self.statusLabel.Size = UDim2.new(1, -20, 0, 25)
    self.statusLabel.Position = UDim2.new(0, 10, 0, yOffset)
    self.statusLabel.Text = "สถานะ: พร้อมใช้งาน"
    self.statusLabel.BackgroundTransparency = 1
    self.statusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
    self.statusLabel.Font = Enum.Font.Gotham
    self.statusLabel.TextSize = 14
    self.statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    self.statusLabel.Parent = frame
    yOffset = yOffset + 35
    
    -- สร้างปุ่มต่างๆ
    local buttons = {}
    
    -- Selling Buttons
    if config.autoSellEnabled then
        buttons.sellStart = self:createButton(frame, "🚀 เริ่มขาย", {0.05, 0, 0, yOffset}, {0.45, 0, 0, 35}, colors.sellButton)
        buttons.sellStop = self:createButton(frame, "🛑 หยุดขาย", {0.52, 0, 0, yOffset}, {0.45, 0, 0, 35}, colors.stopButton)
        yOffset = yOffset + 45
    end
    
    -- Buying Buttons
    if config.autoBuyEnabled then
        buttons.buyStart = self:createButton(frame, "🛒 เริ่มซื้อ", {0.05, 0, 0, yOffset}, {0.45, 0, 0, 35}, colors.buyButton)
        buttons.buyStop = self:createButton(frame, "⏹️ หยุดซื้อ", {0.52, 0, 0, yOffset}, {0.45, 0, 0, 35}, colors.stopButton)
        yOffset = yOffset + 45
    end
    
    -- Claim Buttons
    if config.autoClaimEnabled then
        buttons.claimStart = self:createButton(frame, "💰 เริ่มรับเงิน", {0.05, 0, 0, yOffset}, {0.45, 0, 0, 35}, colors.claimButton)
        buttons.claimStop = self:createButton(frame, "💸 หยุดรับเงิน", {0.52, 0, 0, yOffset}, {0.45, 0, 0, 35}, colors.stopButton)
        yOffset = yOffset + 45
    end
    
    -- Anti-AFK Buttons
    if config.antiAfkEnabled then
        buttons.afkStart = self:createButton(frame, "🛡️ เริ่ม Anti-AFK", {0.05, 0, 0, yOffset}, {0.45, 0, 0, 35}, {76, 175, 80})
        buttons.afkStop = self:createButton(frame, "🔴 หยุด Anti-AFK", {0.52, 0, 0, yOffset}, {0.45, 0, 0, 35}, colors.stopButton)
        yOffset = yOffset + 45
    end
    
    -- Teleport Button
    if config.autoTeleportToMarket then
        buttons.teleport = self:createButton(frame, "📍 วาร์ปตลาด", {0, 10, 0, yOffset}, {1, -20, 0, 35}, colors.teleportButton)
        yOffset = yOffset + 45
    end
    
    -- Close Button
    buttons.close = self:createButton(frame, "✕ ปิด", {0, 10, 0, yOffset}, {1, -20, 0, 35}, colors.stopButton)
    
    -- Event Handlers
    nameInput.FocusLost:Connect(function()
        config.targetBuyerName = nameInput.Text
        debugPrint("เปลี่ยนเป้าหมายเป็น: " .. config.targetBuyerName)
    end)
    
    if buttons.sellStart then
        buttons.sellStart.MouseButton1Click:Connect(function()
            if not self.sellingActive then
                self:startAutoSelling()
                self.statusLabel.Text = "สถานะ: กำลังขาย..."
                self.statusLabel.TextColor3 = Color3.fromRGB(255, 165, 0)
            end
        end)
    end
    
    if buttons.sellStop then
        buttons.sellStop.MouseButton1Click:Connect(function()
            self.sellingActive = false
            self.statusLabel.Text = "สถานะ: หยุดขาย"
            self.statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        end)
    end
    
    if buttons.buyStart then
        buttons.buyStart.MouseButton1Click:Connect(function()
            if not self.buyingActive then
                self:startAutoBuying()
                self.statusLabel.Text = "สถานะ: กำลังซื้อ..."
                self.statusLabel.TextColor3 = Color3.fromRGB(100, 150, 255)
            end
        end)
    end
    
    if buttons.buyStop then
        buttons.buyStop.MouseButton1Click:Connect(function()
            self.buyingActive = false
            self.statusLabel.Text = "สถานะ: หยุดซื้อ"
            self.statusLabel.TextColor3 = Color3.fromRGB(200, 100, 255)
        end)
    end
    
    if buttons.claimStart then
        buttons.claimStart.MouseButton1Click:Connect(function()
            if not self.autoClaimActive then
                self:startAutoClaim()
                self.statusLabel.Text = "สถานะ: กำลังรับเงิน..."
                self.statusLabel.TextColor3 = Color3.fromRGB(255, 193, 7)
            end
        end)
    end
    
    if buttons.claimStop then
        buttons.claimStop.MouseButton1Click:Connect(function()
            self.autoClaimActive = false
            self.statusLabel.Text = "สถานะ: หยุดรับเงิน"
            self.statusLabel.TextColor3 = Color3.fromRGB(255, 87, 34)
        end)
    end
    
    if buttons.afkStart then
        buttons.afkStart.MouseButton1Click:Connect(function()
            if not self.antiAfkActive then
                self:startAntiAfk()
                self.statusLabel.Text = "สถานะ: Anti-AFK เปิดแล้ว"
                self.statusLabel.TextColor3 = Color3.fromRGB(76, 175, 80)
            end
        end)
    end
    
    if buttons.afkStop then
        buttons.afkStop.MouseButton1Click:Connect(function()
            self:stopAntiAfk()
            self.statusLabel.Text = "สถานะ: Anti-AFK ปิดแล้ว"
            self.statusLabel.TextColor3 = Color3.fromRGB(244, 67, 54)
        end)
    end
    
    if buttons.teleport then
        buttons.teleport.MouseButton1Click:Connect(function()
            self:teleportToMarket()
            self.statusLabel.Text = "สถานะ: วาร์ปไปตลาดแล้ว"
            self.statusLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
        end)
    end
    
    buttons.close.MouseButton1Click:Connect(function()
        self:stopAll()
        screenGui:Destroy()
        debugPrint("ปิด GUI")
    end)
    
    debugPrint("GUI สร้างเสร็จแล้ว!")
end

-- ฟังก์ชันสร้างปุ่ม
function AutoTradingSystem:createButton(parent, text, position, size, color)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(size[1], size[2], size[3], size[4])
    button.Position = UDim2.new(position[1], position[2], position[3], position[4])
    button.Text = text
    button.BackgroundColor3 = Color3.fromRGB(color[1], color[2], color[3])
    button.BorderSizePixel = 0
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Font = Enum.Font.GothamBold
    button.TextSize = 14
    button.Parent = parent
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 5)
    corner.Parent = button
    
    return button
end

-- ฟังก์ชันเริ่มต้นระบบ
function AutoTradingSystem:initialize()
    debugPrint("เริ่มต้น Auto Trading System v2.0")
    
    -- วาร์ปโลกและตลาดถ้าจำเป็น
    task.spawn(function()
        if self:teleportIfNeeded() then
            task.wait(5)
        end
        if config.autoTeleportToMarket then
            self:teleportToMarket()
        end
    end)
    
    -- สร้าง GUI
    self:createGUI()
    
    -- เริ่มระบบอัตโนมัติตาม config
    if config.autoSellEnabled then
        task.wait(2)
        self:startAutoSelling()
    end
    
    if config.autoBuyEnabled then
        task.wait(2)
        self:startAutoBuying()
    end
    
    if config.autoClaimEnabled then
        task.wait(2)
        self:startAutoClaim()
    end
    
    if config.antiAfkEnabled then
        task.wait(1)
        self:startAntiAfk()
    end
    
    debugPrint("ระบบพร้อมใช้งาน!")
end

-- เริ่มต้นระบบ
AutoTradingSystem:initialize()

-- เก็บไว้ใน global environment
getgenv().AutoTradingSystem = AutoTradingSystem
return AutoTradingSystem
