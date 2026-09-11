--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Remotes = ReplicatedStorage.Remotes
local Enter = Remotes.Enter 
local Cut = Remotes.Cut 
local End = Remotes.End 

local MAX_TILES = #workspace.Tiles:GetChildren()

local QueueService = {}

function QueueService.init(self: QueueService)
	self.tiles = {}

	Players.PlayerAdded:Connect(function(player)
		self:playerAdded(player)

		player.CharacterAdded:Connect(function()
			self:onCharacterAdded(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:playerRemoving(player)
	end)

	for _, player in Players:GetPlayers() do
		self:playerAdded(player)
	end

	Enter.OnServerEvent:Connect(function(player)
		self:enterQueue(player)
	end)

	Cut.OnServerInvoke = function(player)
		return self:cutLine(player)
	end

	End.OnServerInvoke = function(player)
		self:completeTurn(player)
		self:advanceQueue()
	end

end

function QueueService.playerAdded(self: QueueService, player: Player)
	self:registerTile(player)
end

function QueueService.playerRemoving(self: QueueService, player: Player)
	self:unregisterTile(player)
end

function QueueService.onCharacterAdded(self: QueueService, player: Player)
	self:teleportPlayer(player)
end

-- Finds the first free tile slot and claims it for player
function QueueService.registerTile(self: QueueService, player: Player)
	for i = 1, MAX_TILES do
		if self.tiles[i] == nil then
			self.tiles[i] = player.UserId
			return
		end
	end
end

-- Clears player's tile slot, then shifts the queue forward to fill the gap
function QueueService.unregisterTile(self: QueueService, player: Player)
	for i = 1, MAX_TILES do
		if self.tiles[i] == player.UserId then
			self.tiles[i] = nil
			break
		end
	end

	self:advanceQueue()
end

function QueueService.getIndex(self: QueueService, player: Player): number?
	return table.find(self.tiles, player.UserId)
end

function QueueService.getTile(self: QueueService, index: number): Part?
	return workspace.Tiles:FindFirstChild(tostring(index)) :: Part?
end

function QueueService.notifyFrontStatus(self: QueueService, player: Player, index: number)
	task.spawn(function()
		End:InvokeClient(player, index == 1)
	end)
end

-- Teleports player's character to their tile (used on spawn/respawn)
function QueueService.teleportPlayer(self: QueueService, player: Player)
	local index = self:getIndex(player)
	if not index then
		return
	end

	local character = player.Character or player.CharacterAdded:Wait()
	if not character then
		return
	end

	local tile = self:getTile(index)
	if not tile then
		return
	end

	character:PivotTo(tile.CFrame * CFrame.Angles(0, math.rad(90), 0))

	self:notifyFrontStatus(player, index)
end

-- Walks player's character to their tile (used when the queue shifts)
function QueueService.moveTo(self: QueueService, player: Player)
	local index = self:getIndex(player)
	if not index then
		return
	end

	local tile = self:getTile(index)
	if not tile then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid:MoveTo(tile.Position)

	self:notifyFrontStatus(player, index)
end

-- Shifts every occupied slot (2..MAX) one position forward, closing gaps
function QueueService.advanceQueue(self: QueueService)
	for i = 2, MAX_TILES do
		local userId: number? = self.tiles[i]
		if not userId then
			continue
		end

		self.tiles[i - 1] = userId
		self.tiles[i] = nil

		local player = Players:GetPlayerByUserId(userId)
		if player then
			self:moveTo(player)
		end
	end
end

-- Swaps player with the person directly ahead of them in line
function QueueService.swapPlayers(self: QueueService, player: Player)
	local indexA = self:getIndex(player)
	if not indexA then
		return
	end
	local indexB = indexA + 1

	local userIdA: number? = self.tiles[indexA]
	local userIdB: number? = self.tiles[indexB]

	if not userIdA or not userIdB then
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

-- Adds player to the back of the queue if not already in it
function QueueService.enterQueue(self: QueueService, player: Player)
	if self:getIndex(player) then
		return
	end

	self:registerTile(player)
	self:teleportPlayer(player)
end

-- Called when the player at the front finishes their turn; removes them
function QueueService.completeTurn(self: QueueService, player: Player)
	local index = self:getIndex(player)
	if index ~= 1 then
		return
	end

	local character = player.Character
	if character then
		character:PivotTo(workspace.Part.CFrame) -- move them off the tile
	end

	self:unregisterTile(player)
end

-- Swaps player with whoever is directly ahead; fails if already at front
function QueueService.cutLine(self: QueueService, player: Player): boolean
	local index = self:getIndex(player)
	if not index or index <= 1 then
		return false 
	end

	local aheadUserId: number? = self.tiles[index - 1]
	local aheadPlayer = aheadUserId and Players:GetPlayerByUserId(aheadUserId)
	if not aheadPlayer then
		return false
	end

	self:swapPlayers(aheadPlayer)
	return true
end

type QueueService = typeof(QueueService) & {
	tiles: { number },
}

return QueueService :: QueueService
