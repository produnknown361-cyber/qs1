fovoicechat (roblox & discord)
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = ReplicatedStorage:WaitForChild("Remotes") 
local Enter = Remotes:WaitForChild("Enter") :: RemoteEvent 
local Cut = Remotes:WaitForChild("Cut") :: RemoteFunction 
local End = Remotes:WaitForChild("End") :: RemoteFunction 

local TILES = workspace:WaitForChild("Tiles")
local EXIT_PART = workspace:WaitForChild("Part") :: BasePart
local MAX_TILES = #TILES:GetChildren() 
local TURN_TIME = 30 -- seconds the front player has before the server ends their turn

local QueueService = {}

function QueueService.init(self: QueueService) -- called once by the server entry script
	self.tiles = {} -- array of UserIds; array index doubles as tile number
	self.timers = {} -- UserId -> task.delay thread for the front player's turn

	Players.PlayerAdded:Connect(function(player) -- fires for everyone who joins later
		self:setupPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player) -- frees the tile so the line closes the gap
		self:playerRemoving(player)
	end)

	for _, player in Players:GetPlayers() do -- covers players who joined before init ran
		self:setupPlayer(player)
	end

	Enter.OnServerEvent:Connect(function(player) -- Roblox passes the firing player automatically
		self:enterQueue(player)
	end)

	Cut.OnServerInvoke = function(player : Player) -- assigned, not connected: one callback per RemoteFunction
		return self:cutLine(player) -- must return or the client receives nil
	end

	End.OnServerInvoke = function(player : Player)
		return self:completeTurn(player)
	end
end

function QueueService.setupPlayer(self: QueueService, player: Player) -- one entry point for join + init loop
	self:registerTile(player)

	player.CharacterAdded:Connect(function() -- respawns reset position, so snap back to the tile
		self:teleportPlayer(player)
	end)

	if player.Character then -- character may already exist if init ran late
		self:teleportPlayer(player)
	end
end

function QueueService.playerRemoving(self: QueueService, player: Player)
	self:unregisterTile(player)
end

function QueueService.registerTile(self: QueueService, player: Player): boolean
	if #self.tiles >= MAX_TILES then -- no tile left for another player
		return false
	end

	table.insert(self.tiles, player.UserId) -- appends to the back of the line

	return true
end

function QueueService.unregisterTile(self: QueueService, player: Player)
	local index = self:getIndex(player)

	if not index then
		return
	end

	self:syncTurnTimer(player, false) -- a departing player must not leave a live timer behind
	table.remove(self.tiles, index) -- shifts everyone up, so the array never has gaps

	self:advanceQueue()
end

function QueueService.getIndex(self: QueueService, player: Player): number?
	return table.find(self.tiles, player.UserId) -- linear search is fine at tile-count scale
end

function QueueService.getTile(self: QueueService, index: number): Part?
	return TILES:FindFirstChild(tostring(index)) :: Part? -- tiles are named by position, so no lookup table needed
end

-- Starts the turn timer for the front player and cancels it for anyone else
function QueueService.syncTurnTimer(self: QueueService, player: Player, isFront: boolean)
	local userId = player.UserId
	local running = self.timers[userId]

	if isFront and not running then -- "not running" stops queue shifts from resetting the clock
		self.timers[userId] = task.delay(TURN_TIME, function()
			self.timers[userId] = nil -- cleared first so unregisterTile doesn't cancel this thread
			self:completeTurn(player)
		end)
	elseif not isFront and running then
		task.cancel(running) -- stops the delayed call from ever firing
		self.timers[userId] = nil
	end
end

function QueueService.notifyFrontStatus(self: QueueService, player: Player, index: number)
	self:syncTurnTimer(player, index == 1)

	task.spawn(function() -- own thread so a slow client can't stall the queue
		pcall(End.InvokeClient, End, player, index == 1) -- pcall: InvokeClient errors if the client leaves
	end)
end

function QueueService.teleportPlayer(self: QueueService, player: Player)
	local index = self:getIndex(player)
	local character = player.Character -- no :Wait(); CharacterAdded calls us again on spawn

	if not index or not character then
		return
	end

	local tile = self:getTile(index)

	if not tile then
		return
	end

	character:PivotTo(tile.CFrame * CFrame.Angles(0, math.rad(90), 0)) -- PivotTo moves the whole model; CFrame.Angles turns it to face along the line

	self:notifyFrontStatus(player, index)
end

function QueueService.moveTo(self: QueueService, player: Player)
	local index = self:getIndex(player)
	local character = player.Character -- no :Wait(); yielding here would stall everyone behind
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") -- MoveTo lives on Humanoid

	if not index or not humanoid then
		return
	end

	local tile = self:getTile(index)

	if not tile then
		return
	end

	humanoid:MoveTo(tile.Position) -- walks the player instead of snapping them
	self:notifyFrontStatus(player, index)
end

function QueueService.advanceQueue(self: QueueService)
	for _, userId in ipairs(self.tiles) do -- ipairs keeps line order
		local player = Players:GetPlayerByUserId(userId) -- nil if that player just left

		if player then
			self:moveTo(player)
		end
	end
end

function QueueService.swapPlayers(self: QueueService, indexA: number) -- swaps indexA with the player behind
	local indexB = indexA + 1

	local userIdA = self.tiles[indexA]
	local userIdB = self.tiles[indexB]

	if not userIdA or not userIdB then -- no one behind: nothing to swap
		return
	end

	self.tiles[indexA] = userIdB
	self.tiles[indexB] = userIdA

	local playerA = Players:GetPlayerByUserId(userIdA)
	local playerB = Players:GetPlayerByUserId(userIdB)

	if playerA then
		self:moveTo(playerA)
	end

	if playerB then
		self:moveTo(playerB)
	end
end

function QueueService.enterQueue(self: QueueService, player: Player)
	if self:getIndex(player) then -- already queued: ignore repeat fires
		return
	end

	if not self:registerTile(player) then -- line is full
		return
	end

	self:teleportPlayer(player)
end

function QueueService.completeTurn(self: QueueService, player: Player): boolean
	if self:getIndex(player) ~= 1 then -- server-side check: only the front player may finish
		return false
	end

	local character = player.Character

	if character then
		character:PivotTo(EXIT_PART.CFrame)
	end

	self:unregisterTile(player) -- also pulls the rest of the line forward

	return true
end

function QueueService.cutLine(self: QueueService, player: Player): boolean
	local index = self:getIndex(player)

	if not index or index <= 1 then -- not queued, or nobody ahead to cut
		return false
	end

	self:swapPlayers(index - 1) -- swapping the player ahead with the caller

	return true
end

type QueueService = typeof(QueueService) & {
	tiles: { number },
	timers: { [number]: thread },
}

return QueueService :: QueueService
