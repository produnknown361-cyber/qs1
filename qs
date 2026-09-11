fovoicechat (roblox & discord)
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = ReplicatedStorage.Remotes
local Enter = Remotes.Enter
local Cut = Remotes.Cut
local End = Remotes.End

local MAX_TILES = #workspace.Tiles:GetChildren()

local QueueService = {}

function QueueService.init(self: QueueService)
	-- The queue starts empty. Individual positions are created dynamically as
	-- players register, allowing nil positions to represent unused queue slots.
	self.tiles = {}

	-- PlayerAdded handles players who join after the service has initialized.
	-- Registering them immediately gives every connected player a queue position
	-- that can later be used when their character spawns.
	Players.PlayerAdded:Connect(function(player)
		self:playerAdded(player)

		-- CharacterAdded is separate from PlayerAdded because a Player can exist
		-- without a character, and characters can be destroyed/recreated when a
		-- player respawns. Re-running teleportPlayer ensures the character is
		-- placed at the player's existing queue position after each respawn.
		player.CharacterAdded:Connect(function()
			self:onCharacterAdded(player)
		end)
	end)

	-- PlayerRemoving must clean the player's UserId out of the queue. Otherwise
	-- a disconnected player would leave behind a stale UserId and prevent the
	-- following players from occupying the correct positions.
	Players.PlayerRemoving:Connect(function(player)
		self:playerRemoving(player)
	end)

	-- Players that joined before this service was initialized do not trigger the
	-- PlayerAdded connection above, so they must be registered manually.
	for _, player in Players:GetPlayers() do
		self:playerAdded(player)

		-- These players also need CharacterAdded handling. Without this connection,
		-- an already-connected player who respawns would not be teleported back to
		-- their queue tile.
		player.CharacterAdded:Connect(function()
			self:onCharacterAdded(player)
		end)
	end

	-- Enter is intentionally server-authoritative: the client can request entry,
	-- but enterQueue() checks whether the player is already present before changing
	-- the queue. This prevents clients from directly manipulating queue indexes.
	Enter.OnServerEvent:Connect(function(player)
		self:enterQueue(player)
	end)

	-- Cut uses a RemoteFunction so the caller receives a boolean indicating
	-- whether the requested cut was actually accepted by the server.
	Cut.OnServerInvoke = function(player)
		return self:cutLine(player)
	end

	-- Completing a turn removes the player from the front. `unregisterTile()`
	-- already calls advanceQueue() after removing the player, so calling
	-- advanceQueue() here as well would move everyone forward twice.
	End.OnServerInvoke = function(player)
		self:completeTurn(player)
	end
end

function QueueService.playerAdded(self: QueueService, player: Player)
	-- Queue registration occurs as soon as the Player object exists. This means
	-- the player's queue position is established before their character may
	-- spawn, allowing CharacterAdded to later teleport them to the correct tile.
	self:registerTile(player)
end

function QueueService.playerRemoving(self: QueueService, player: Player)
	-- Removing the player's UserId is necessary before compacting the queue so
	-- that every remaining player can move toward the front without a stale slot.
	self:unregisterTile(player)
end

function QueueService.onCharacterAdded(self: QueueService, player: Player)
	-- The queue position belongs to the Player, not the Character. Therefore a
	-- respawn should preserve the player's place in line and simply move the new
	-- character to the same position.
	self:teleportPlayer(player)
end

-- Finds the first available queue position and assigns the player to it.
-- The search starts at index 1 because lower indexes represent positions closer
-- to the front. Consequently, the first free index produces the earliest
-- possible position for a newly registered player.
function QueueService.registerTile(self: QueueService, player: Player)
	for i = 1, MAX_TILES do
		if self.tiles[i] == nil then
			self.tiles[i] = player.UserId
			return
		end
	end

	-- If every position is occupied, the player cannot be inserted. We simply
	-- leave them unregistered rather than writing outside the configured queue
	-- capacity.
end

-- Removes a player from the queue and then compacts the remaining positions.
-- Compaction is important because queue indexes represent physical positions:
-- if position 2 becomes empty while position 3 is occupied, position 3 must
-- become position 2 so the physical line contains no gaps.
function QueueService.unregisterTile(self: QueueService, player: Player)
	local index = self:getIndex(player)

	if not index then
		-- The player may already have been removed or may never have successfully
		-- registered. In either case there is nothing to remove or compact.
		return
	end

	-- Removing the value creates a gap. advanceQueue() will rebuild the queue
	-- into consecutive positions and move affected characters accordingly.
	self.tiles[index] = nil

	self:advanceQueue()
end

-- Converts a Player into its current queue position by searching for the
-- UserId stored in the queue. Returning nil is meaningful because it indicates
-- that the player is not currently registered.
function QueueService.getIndex(self: QueueService, player: Player): number?
	return table.find(self.tiles, player.UserId)
end

-- Maps a logical queue index to the physical Part representing that position.
-- Tile names are expected to be numeric strings such as "1", "2", "3", etc.,
-- allowing the queue's array index and the workspace representation to stay
-- synchronized.
function QueueService.getTile(self: QueueService, index: number): Part?
	return workspace.Tiles:FindFirstChild(tostring(index)) :: Part?
end

-- Sends the client information about whether it currently occupies the front
-- position. A separate client notification is used instead of exposing the
-- server's entire queue table, keeping queue state authoritative on the server.
function QueueService.notifyFrontStatus(
	self: QueueService,
	player: Player,
	index: number
)
	-- InvokeClient can yield while waiting for the client. Running it in a
	-- separate task prevents the queue operation itself from being unnecessarily
	-- blocked by client-side response behavior.
	task.spawn(function()
		End:InvokeClient(player, index == 1)
	end)
end

-- Places the player's character directly onto their queue tile.
-- This is used for initial spawning and respawning because MoveTo would require
-- the character to physically walk to the position and could therefore leave
-- them temporarily in the wrong location.
function QueueService.teleportPlayer(self: QueueService, player: Player)
	local index = self:getIndex(player)

	if not index then
		-- A player without a queue position should not be teleported to a tile.
		return
	end

	-- Character may not exist immediately when this method is called. Waiting
	-- for CharacterAdded synchronizes the queue position with the character's
	-- lifecycle instead of assuming the character already exists.
	local character = player.Character or player.CharacterAdded:Wait()

	if not character then
		return
	end

	local tile = self:getTile(index)

	if not tile then
		-- The queue can only position the player if the corresponding workspace
		-- tile exists. Failing safely prevents an invalid PivotTo operation.
		return
	end

	-- PivotTo moves the entire character model to the tile. The additional
	-- rotation keeps the character facing the intended direction on the queue.
	character:PivotTo(
		tile.CFrame * CFrame.Angles(0, math.rad(90), 0)
	)

	-- After positioning the character, update the client so it knows whether
	-- this queue position is currently the front.
	self:notifyFrontStatus(player, index)
end

-- Moves a living character toward its newly assigned queue position.
-- Unlike teleportPlayer(), this is used when the queue changes while the player
-- is already present, allowing the character to visibly walk forward.
function QueueService.moveTo(self: QueueService, player: Player)
	local index = self:getIndex(player)

	if not index then
		return
	end

	local tile = self:getTile(index)

	if not tile then
		return
	end

	-- Character can temporarily be unavailable during death/respawn. Since this
	-- function is intended for active movement rather than spawning, we simply
	-- skip the movement until the character exists again.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return
	end

	-- Humanoid:MoveTo causes the character to physically travel to the queue
	-- position rather than instantly teleporting. This visually represents the
	-- queue progressing.
	humanoid:MoveTo(tile.Position)

	-- The player's logical position has changed even though the character is
	-- still travelling, so the client is notified using the new queue index.
	self:notifyFrontStatus(player, index)
end

-- Removes gaps from the queue and shifts every remaining player toward index 1.
-- The previous implementation iterated through existing indexes and could be
-- difficult to reason about when multiple gaps existed. Rebuilding the array
-- from the current values makes the invariant explicit:
--
--     every occupied position must appear consecutively from index 1.
function QueueService.advanceQueue(self: QueueService)
	local newTiles: { number } = {}

	-- Collect every remaining UserId in its existing order. ipairs stops at the
	-- first nil, so we intentionally iterate through the entire configured
	-- capacity to support queues that contain gaps.
	for i = 1, MAX_TILES do
		local userId = self.tiles[i]

		if userId then
			table.insert(newTiles, userId)
		end
	end

	-- Replace the old sparse representation with the compact representation.
	-- This guarantees that the array itself reflects the physical queue order.
	self.tiles = newTiles

	-- Every player is now assigned a new logical position. We move them after
	-- the complete queue has been rebuilt so getIndex() uses the final positions
	-- rather than partially updated data.
	for index, userId in ipairs(self.tiles) do
		local player = Players:GetPlayerByUserId(userId)

		if player then
			self:moveTo(player)
		end
	end
end

-- Swaps two adjacent queue positions. The function itself does not decide why
-- the swap is happening; it simply exchanges the UserIds at indexA and indexA+1.
-- cutLine() uses this primitive to move a player one position toward the front.
function QueueService.swapPlayers(self: QueueService, player: Player)
	local indexA = self:getIndex(player)

	if not indexA then
		return
	end

	local indexB = indexA + 1

	-- Both positions must contain valid players. If the second position is empty,
	-- there is no adjacent player to swap with.
	local userIdA = self.tiles[indexA]
	local userIdB = self.tiles[indexB]

	if not userIdA or not userIdB then
		return
	end

	-- Exchange the UserIds rather than Player objects. The queue therefore
	-- remains consistent with the same representation used everywhere else.
	self.tiles[indexA] = userIdB
	self.tiles[indexB] = userIdA

	-- Resolve the UserIds only after the swap because movement requires actual
	-- Player objects. Both players then walk to the physical tile corresponding
	-- to their new logical position.
	local playerA = Players:GetPlayerByUserId(userIdA)
	local playerB = Players:GetPlayerByUserId(userIdB)

	if playerA then
		self:moveTo(playerA)
	end

	if playerB then
		self:moveTo(playerB)
	end
end

-- Adds a player to the queue only if they are not already registered.
-- The duplicate check is important because the player may already have been
-- registered automatically by PlayerAdded before the client sends Enter.
function QueueService.enterQueue(self: QueueService, player: Player)
	if self:getIndex(player) then
		return
	end

	-- registerTile() determines the first available queue position. If the
	-- queue is full, the player remains unregistered and teleportPlayer() safely
	-- does nothing because getIndex() returns nil.
	self:registerTile(player)

	-- Once registration succeeds, this immediately places the character at the
	-- assigned tile. This is appropriate for entering an existing queue rather
	-- than walking from an arbitrary location.
	self:teleportPlayer(player)
end

-- Only the player occupying index 1 is allowed to complete the current turn.
-- This validation is performed on the server because a client cannot be trusted
-- to identify itself as the player currently at the front.
function QueueService.completeTurn(self: QueueService, player: Player)
	local index = self:getIndex(player)

	if index ~= 1 then
		-- Players behind the front cannot end the active turn. This prevents a
		-- client from removing itself from an arbitrary queue position.
		return
	end

	local character = player.Character

	if character then
		-- Move the completed player away from the queue before removing their
		-- logical position. This prevents them from visually remaining on the
		-- front tile while the next player advances.
		character:PivotTo(workspace.Part.CFrame)
	end

	-- unregisterTile() removes the player and performs the required queue
	-- compaction. It is therefore the single owner of the "remove and advance"
	-- operation, preventing the double-advance bug that previously existed in
	-- the End.OnServerInvoke callback.
	self:unregisterTile(player)
end

-- Moves a player one position forward by swapping them with the player directly
-- ahead of them. A cut is only valid when there is an actual player occupying
-- the preceding position.
function QueueService.cutLine(self: QueueService, player: Player): boolean
	local index = self:getIndex(player)

	if not index or index <= 1 then
		-- A missing index means the player is not queued. Index 1 means the player
		-- is already at the front and therefore has nobody to cut.
		return false
	end

	-- The player at index-1 is the person immediately ahead. We retrieve their
	-- UserId from the server-owned queue rather than trusting the client to
	-- identify which player should be passed to the swap operation.
	local aheadUserId = self.tiles[index - 1]
	local aheadPlayer = aheadUserId
		and Players:GetPlayerByUserId(aheadUserId)

	if not aheadPlayer then
		-- The queue should normally contain a valid Player for this UserId, but
		-- the player could disconnect between queue updates. Failing safely avoids
		-- performing a swap with invalid state.
		return false
	end

	-- swapPlayers() receives the person ahead. Since that player's index is
	-- index-1, swapPlayers() exchanges them with index, effectively moving the
	-- requesting player one place toward the front.
	self:swapPlayers(aheadPlayer)

	return true
end

type QueueService = typeof(QueueService) & {
	tiles: { number },
}

return QueueService :: QueueService
