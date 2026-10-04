-- LocalScript: coloque em StarterPlayer > StarterPlayerScripts.
-- Cliente completo em um arquivo, sem ModuleScripts locais.
-- Requer o servidor NanoSystem do pacote anterior e os RemoteEvents em
-- ReplicatedStorage.NanoSystem.Remotes: Request, Control e Feedback.
-- Substitua a pasta NanoClient anterior por este LocalScript; não use os dois.
-- Remova ToolClient do Tool anterior: o clique é tratado aqui.

local Config = (function()
-- NanoSystem: configuração compartilhada. O servidor sempre usa a sua cópia.
local Config = {
	ToolName = "NanoTool",
	Color = Color3.fromRGB(52, 235, 196),
	Accent = Color3.fromRGB(190, 255, 244),
	Dark = Color3.fromRGB(16, 42, 47),
	BlockSize = 0.17,
	SizeVariation = 0.45,
	Attraction = 13,
	FormationSpeed = 8,
	OrbitRadius = 3.2,
	OrbitSpeed = 1.1,
	AimDistance = 48,
	AimDefaultDistance = 15,
	CloneOffset = Vector3.new(5, 0, 1),
	CloneMaxDistance = 12,
	CloneDelay = 0.16,
	CloneBuildTime = 2.1,
	CloneReturnTime = 0.9,
	CloneDuration = 40,
	PoseSampleRate = 30,
	FlightSpeed = 42,
	FlightVerticalSpeed = 25,
	FlightAcceleration = 4.5,
	FlightDeceleration = 6,
	FlightFOVBoost = 6, -- 0 para não tocar no FOV da câmera.
	TakeoffTime = 0.9,
	TakeoffSpeed = 7,
	LandingSpeed = 9,
	LandingTimeout = 8,
	InputTimeout = 0.65,
	InputRate = 12,
	StateRate = 10,
	ArmorDuration = 12,
	ArmorReduction = 0.45,
	ShieldDuration = 10,
	ShieldHealth = 160,
	ShieldSize = Vector3.new(6, 5, 0.45),
	ShieldDistance = 4,
	PlatformDuration = 10,
	PlatformSize = Vector3.new(8, 0.6, 8),
	RecallTime = 0.8,
	Cooldowns = {
		Follow = 0.3, Cloud = 0.3, Flight = 1.2,
		Clone = 5, Armor = 14, Shield = 12, Platform = 12, Recall = 1,
	},
	-- Quantidade é de blocos geométricos, não de peças físicas.
	Quality = "Auto", -- Auto, Low, Medium ou High
	QualityLevels = {
		Low = { Swarm = 100, Clone = 180, ParticleRate = 35 },
		Medium = { Swarm = 180, Clone = 280, ParticleRate = 75 },
		High = { Swarm = 300, Clone = 440, ParticleRate = 120 },
	},
	MaxPooledParts = 2200, -- Limite global por cliente, incluindo partes ociosas.
	RemoteMultiplier = 0.55,
	NearDistance = 70,
	FarDistance = 140,
	CullDistance = 220,
	LODEvery = 1,
	RemoteFPS = 30,
	FarFPS = 15,
	ParticleLifetime = NumberRange.new(0.3, 0.7),
	AllowFlight = true,
	AllowPlatform = true,
	MaxFlightAltitude = 1200, -- Coordenada Y absoluta.
	RequestBurst = 12,
	RequestRefill = 6,
	ControlBurst = 24,
	ControlRefill = 18,
}
return table.freeze(Config)
end)()

local Math = (function()
local M = {}
function M.alpha(speed, dt)
	return 1 - math.exp(-speed * math.max(0, dt))
end
function M.finite(n)
	return type(n) == "number" and n == n and math.abs(n) < 1e7
end
function M.vector(v)
	return typeof(v) == "Vector3" and M.finite(v.X) and M.finite(v.Y) and M.finite(v.Z)
end
function M.clampVector(v, maximum)
	local magnitude = v.Magnitude
	return magnitude > maximum and v.Unit * maximum or v
end
function M.smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end
function M.hash(i)
	return (math.sin(i * 127.1 + 311.7) * 43758.5453) % 1
end
function M.flat(v, fallback)
	local p = Vector3.new(v.X, 0, v.Z)
	return p.Magnitude > 0.001 and p.Unit or fallback or Vector3.new(0, 0, -1)
end
return M
end)()

local Pool = (function()
local Workspace = game:GetService("Workspace")
local Pool = {}
Pool.__index = Pool
function Pool.new(config)
	local folder = Instance.new("Folder")
	folder.Name = "NanoLocalEffects"
	folder.Parent = Workspace
	return setmetatable({
		config = config, folder = folder, free = {}, total = 0,
		inUse = {}, parts = {}, frames = {},
	}, Pool)
end
function Pool:Acquire(seed, origin)
	local part = table.remove(self.free)
	if not part then
		if self.total >= self.config.MaxPooledParts then return nil end
		part = Instance.new("Part")
		part.Name = "NanoVoxel"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Parent = self.folder
		self.total += 1
	end
	self.inUse[part] = true
	local h = (math.sin(seed * 27.19) * 9173.17) % 1
	local size = self.config.BlockSize * (1 + (h - 0.5) * self.config.SizeVariation)
	part.Size = Vector3.new(size, size, size)
	part.Color = h > 0.8 and self.config.Accent or self.config.Color
	part.CFrame = origin
	part.Transparency = 1
	return part
end
function Pool:Release(part)
	if not self.inUse[part] then return end
	self.inUse[part] = nil
	part.Transparency = 1
	table.insert(self.free, part)
end
function Pool:Queue(part, cf)
	table.insert(self.parts, part)
	table.insert(self.frames, cf)
end
function Pool:Flush()
	if #self.parts > 0 then
		Workspace:BulkMoveTo(self.parts, self.frames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(self.parts)
		table.clear(self.frames)
	end
end
function Pool:Destroy()
	self.folder:Destroy()
	table.clear(self.free)
	table.clear(self.inUse)
end
return Pool
end)()

local PoseHistory = (function()
-- Amostra a pose REAL do avatar, não carrega nem duplica AnimationTracks.
local PoseHistory = {}
PoseHistory.__index = PoseHistory
local function rank(name)
	if string.find(name, "Leg") or string.find(name, "Foot") then return 1 end
	if string.find(name, "Torso") then return 2 end
	if string.find(name, "Arm") or string.find(name, "Hand") then return 3 end
	return 4
end
function PoseHistory.new(character, config)
	local body = {}
	for _, p in character:GetChildren() do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
			table.insert(body, p)
		end
	end
	table.sort(body, function(a, b)
		local ra, rb = rank(a.Name), rank(b.Name)
		return ra == rb and a.Name < b.Name or ra < rb
	end)
	return setmetatable({ body = body, frames = {}, elapsed = 0, config = config }, PoseHistory)
end
function PoseHistory:Capture(root, dt, now)
	self.elapsed += dt
	if self.elapsed < 1 / self.config.PoseSampleRate and #self.frames > 0 then return end
	self.elapsed = 0
	local frame = { time = now, root = root.CFrame, bones = {} }
	for i, part in self.body do
		if part.Parent then frame.bones[i] = root.CFrame:ToObjectSpace(part.CFrame) end
	end
	table.insert(self.frames, frame)
	local keep = math.max(1, self.config.CloneDelay + 0.15)
	while #self.frames > 2 and self.frames[2].time < now - keep do
		table.remove(self.frames, 1)
	end
end
function PoseHistory:Sample(now, delay)
	local frames = self.frames
	if #frames == 0 then return nil end
	local wanted = now - delay
	for i = #frames - 1, 1, -1 do
		local a, b = frames[i], frames[i + 1]
		if a.time <= wanted then
			local t = math.clamp((wanted - a.time) / math.max(0.001, b.time - a.time), 0, 1)
			local bones = {}
			for n, cf in a.bones do bones[n] = cf:Lerp(b.bones[n] or cf, t) end
			return { root = a.root:Lerp(b.root, t), bones = bones }
		end
	end
	return frames[1]
end
function PoseHistory:Surface(index, count)
	-- Distribuição por área, ordenada para formação: pernas, tronco, braços, cabeça.
	local total = 0
	local weights = {}
	for i, part in self.body do
		local s = part.Size
		local area = 2 * (s.X * s.Y + s.X * s.Z + s.Y * s.Z)
		total += area
		weights[i] = area
	end
	if total == 0 then return nil end
	local position = ((index - 0.5) / math.max(1, count)) * total
	local bone = #self.body
	for i, weight in weights do
		if position <= weight then bone = i break end
		position -= weight
	end
	local part = self.body[bone]
	local size = part.Size * 0.5
	local u = ((index * 0.61803398875) % 1) * 2 - 1
	local v = ((index * 0.754877666) % 1) * 2 - 1
	local face = index % 6
	local p
	if face == 0 then p = Vector3.new(size.X, u * size.Y, v * size.Z)
	elseif face == 1 then p = Vector3.new(-size.X, u * size.Y, v * size.Z)
	elseif face == 2 then p = Vector3.new(u * size.X, size.Y, v * size.Z)
	elseif face == 3 then p = Vector3.new(u * size.X, -size.Y, v * size.Z)
	elseif face == 4 then p = Vector3.new(u * size.X, v * size.Y, size.Z)
	else p = Vector3.new(u * size.X, v * size.Y, -size.Z) end
	return { bone = bone, point = p, order = index / math.max(1, count) }
end
return PoseHistory
end)()

local Formations = (function()
local F = {}
local TAU = math.pi * 2
function F.cloud(i, count, cf, time, config)
	local f = (i - 0.5) / math.max(1, count)
	local y = 1 - 2 * f
	local r = math.sqrt(math.max(0, 1 - y * y))
	local a = i * 2.399963 + time * config.OrbitSpeed
	local pulse = config.OrbitRadius + math.sin(time * 1.7 + i) * 0.18
	return cf:PointToWorldSpace(Vector3.new(math.cos(a) * r * pulse, y * 2.5, math.sin(a) * r * pulse))
end
function F.follow(i, count, center, time)
	local a = i * 2.399963 + time * 1.4
	local f = (i - 0.5) / math.max(1, count)
	local radius = math.sqrt(f) * 2.4
	return center + Vector3.new(math.cos(a) * radius, math.sin(a * 2 + time) * 0.55, math.sin(a) * radius)
end
function F.feet(i, count, character, root, time)
	local left = character:FindFirstChild("LeftFoot") or character:FindFirstChild("Left Leg")
	local right = character:FindFirstChild("RightFoot") or character:FindFirstChild("Right Leg")
	local foot = i % 2 == 0 and left or right
	local center = foot and foot.CFrame * CFrame.new(0, -foot.Size.Y / 2 - 0.2, 0)
		or root.CFrame * CFrame.new(i % 2 == 0 and -0.6 or 0.6, -3, 0)
	local a = i * 2.399963 + time * 3
	local radius = 0.4 + math.sqrt((i / math.max(1, count))) * 1.5
	local depth = i % 5 == 0 and -((time * 4 + i * 0.13) % 1.8) or math.sin(a * 2) * 0.12
	return center:PointToWorldSpace(Vector3.new(math.cos(a) * radius, depth, math.sin(a) * radius))
end
function F.shield(i, count, root, time, config)
	local width = math.max(3, math.floor(math.sqrt(count * config.ShieldSize.X / config.ShieldSize.Y)))
	local rows = math.ceil(count / width)
	local x = ((i - 1) % width + 0.5) / width - 0.5
	local y = (math.floor((i - 1) / width) + 0.5) / rows - 0.5
	return root.CFrame:PointToWorldSpace(Vector3.new(
		x * config.ShieldSize.X, y * config.ShieldSize.Y,
		-config.ShieldDistance + math.sin(time * 3 + x * 4 + y * 2) * 0.08))
end
function F.platform(i, count, cf, time, config)
	local side = math.max(2, math.ceil(math.sqrt(count)))
	local x = ((i - 1) % side + 0.5) / side - 0.5
	local z = (math.floor((i - 1) / side) + 0.5) / side - 0.5
	return cf:PointToWorldSpace(Vector3.new(
		x * config.PlatformSize.X, 0.35 + math.sin(time * 2 + i) * 0.08, z * config.PlatformSize.Z))
end
function F.drone(i, count, root, time)
	local drone = i % 3
	local a = time * 0.65 + drone * TAU / 3
	local center = root.CFrame:PointToWorldSpace(Vector3.new(math.cos(a) * 3.3, 2.3 + math.sin(time + drone) * 0.3, math.sin(a) * 3.3))
	local small = i * 2.399963 + time * 4
	return center + Vector3.new(math.cos(small) * 0.35, math.sin(i * 0.8) * 0.25, math.sin(small) * 0.35)
end
return F
end)()

local Renderer = (function()
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Renderer = {}
Renderer.__index = Renderer

local function newBlock(pool, index, root)
	local part = pool:Acquire(index, root.CFrame)
	if not part then return nil end
	return { part = part, cf = root.CFrame, index = index, fade = 1, born = os.clock() }
end

function Renderer.new()
	local self = setmetatable({
		pool = Pool.new(Config), entities = {}, running = false,
		smoothedFrame = 1 / 60, quality = "Medium", lodClock = 0,
	}, Renderer)
	self.running = true
	self.connection = RunService.RenderStepped:Connect(function(dt) self:Step(dt) end)
	return self
end

function Renderer:Create(player, character, root)
	local attachment = Instance.new("Attachment")
	attachment.Name = "NanoLocalEmitter"
	attachment.Parent = root
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "NanoSpark"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(Config.Color, Config.Accent)
	emitter.LightEmission = 0.8
	emitter.Lifetime = Config.ParticleLifetime
	emitter.Speed = NumberRange.new(0.8, 2.2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.10),
		NumberSequenceKeypoint.new(0.4, 0.06),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(25)
	local light = Instance.new("PointLight")
	light.Color = Config.Color
	light.Brightness = 0
	light.Range = 8
	light.Shadows = false
	light.Parent = attachment
	local now = Workspace:GetServerTimeNow()
	local entity = {
		player = player, character = character, root = root,
		swarm = {}, clone = {}, history = PoseHistory.new(character, Config),
		attachment = attachment, emitter = emitter, light = light,
		amount = 0, cloneAmount = 0, accumulator = 0,
		aim = root.Position + root.CFrame.LookVector * Config.AimDefaultDistance,
		started = now, cloneOn = false, cloneEnded = nil, visible = 0,
		lodAt = -math.huge, burstAt = 0,
	}
	self.entities[player] = entity
	return entity
end

function Renderer:Dispose(entity)
	for _, block in entity.swarm do self.pool:Release(block.part) end
	for _, block in entity.clone do self.pool:Release(block.part) end
	entity.attachment:Destroy()
	self.entities[entity.player] = nil
end

function Renderer:Resize(entity, list, amount, clone)
	while #list > amount do
		self.pool:Release(table.remove(list).part)
	end
	while #list < amount do
		local block = newBlock(self.pool, #list + 1 + (clone and 900 or 0), entity.root)
		if not block then break end
		table.insert(list, block)
	end
	if clone then
		for i, block in list do block.surface = entity.history:Surface(i, #list) end
	end
end

function Renderer:LOD(entity, distance, now)
	local level = Config.QualityLevels[self.quality]
	local mult = entity.player == Players.LocalPlayer and 1 or Config.RemoteMultiplier
	if distance > Config.FarDistance then mult *= 0.3
	elseif distance > Config.NearDistance then mult *= 0.6 end
	entity.amount = math.max(20, math.floor(level.Swarm * mult))
	entity.cloneAmount = math.max(50, math.floor(level.Clone * mult))
	local active = entity.character:GetAttribute("NanoEnabled") == true
	self:Resize(entity, entity.swarm, active and entity.amount or (entity.visible > 0.01 and #entity.swarm or 0), false)
	if entity.cloneOn then self:Resize(entity, entity.clone, entity.cloneAmount, true) end
	entity.emitter.Rate = distance < Config.NearDistance and level.ParticleRate * mult or 0
	entity.lodAt = now
end

function Renderer:Draw(entity, dt, now, distance)
	local character, root = entity.character, entity.root
	local equipped = character:GetAttribute("NanoEquipped") == true
	local enabled = equipped and character:GetAttribute("NanoEnabled") == true
	local recalled = character:GetAttribute("NanoRecallAt") or -100
	local recallAge = now - recalled
	local recalling = recallAge >= 0 and recallAge < Config.RecallTime
	local flight = character:GetAttribute("NanoFlight") == true
	local armor = (character:GetAttribute("NanoArmorUntil") or 0) > now
	local shield = (character:GetAttribute("NanoShieldUntil") or 0) > now
	local platform = (character:GetAttribute("NanoPlatformUntil") or 0) > now
	local cloneOn = enabled and character:GetAttribute("NanoClone") == true
	if entity.lastEnabled ~= enabled then
		entity.lastEnabled = enabled
		entity.lodAt = -math.huge
	end
	local cloneAt = character:GetAttribute("NanoCloneAt") or now
	if cloneOn ~= entity.cloneOn then
		entity.cloneOn = cloneOn
		if cloneOn then
			entity.cloneEnded = nil
			self:Resize(entity, entity.clone, entity.cloneAmount > 0 and entity.cloneAmount or 180, true)
			entity.emitter:Emit(30)
		else
			entity.cloneEnded = now
			for _, block in entity.clone do block.departure = block.cf end
			entity.emitter:Emit(20)
		end
	end
	entity.history:Capture(root, dt, now)
	local pose = entity.history:Sample(now, Config.CloneDelay)
	if now - entity.lodAt >= Config.LODEvery then self:LOD(entity, distance, now) end
	local aim = character:GetAttribute("NanoAim")
	if entity.player == Players.LocalPlayer and self.localAim then aim = self.localAim end
	if Math.vector(aim) then entity.aim = entity.aim:Lerp(aim, Math.alpha(Config.FormationSpeed, dt)) end
	entity.visible += ((enabled and not recalling and 1 or 0) - entity.visible) * Math.alpha(7, dt)
	entity.light.Brightness = entity.visible * (flight and 1.6 or 0.45)
	if not enabled or recalling then entity.emitter.Rate = 0 end
	local follow = character:GetAttribute("NanoMode") == "Follow"
	local platformCF = character:GetAttribute("NanoPlatformCFrame")
	local count = #entity.swarm
	local droneCount = math.floor(count * 0.12)
	local mainCount = math.max(1, count - droneCount)
	-- Repartição evita que uma habilidade apague os efeitos de outra.
	local groups = {}
	if flight then table.insert(groups, { name = "Feet", weight = 1.2 }) end
	if shield then table.insert(groups, { name = "Shield", weight = 1 }) end
	if armor then table.insert(groups, { name = "Armor", weight = 1 }) end
	if platform and typeof(platformCF) == "CFrame" then table.insert(groups, { name = "Platform", weight = 0.8 }) end
	table.insert(groups, { name = follow and "Follow" or "Cloud", weight = #groups == 0 and 1 or 0.35 })
	local totalWeight = 0
	for _, group in groups do totalWeight += group.weight end
	local used = 0
	for index, group in groups do
		group.first = used + 1
		group.count = index == #groups and mainCount - used or math.floor(mainCount * group.weight / totalWeight)
		used += group.count
		group.last = used
		if group.name == "Armor" then
			if entity.armorCount ~= group.count then
				entity.armorCount = group.count
				entity.armorSurfaces = {}
				for n = 1, group.count do entity.armorSurfaces[n] = entity.history:Surface(n, group.count) end
			end
		end
	end
	entity.attachment.Position = flight and Vector3.new(0, -2.6, 0) or Vector3.zero
	local a = Math.alpha(Config.Attraction, dt)
	for i, block in entity.swarm do
		local position
		if not enabled or recalling then
			local angle = i * 2.399963 + now * 12
			local radius = recalling and math.max(0.08, (1 - recallAge / Config.RecallTime) * 1.2) or 0.1
			position = root.Position + Vector3.new(math.cos(angle) * radius, math.sin(angle) * radius, 0)
		elseif i <= droneCount then
			position = Formations.drone(i, droneCount, root, now)
		else
			local n = i - droneCount
			local selected = groups[#groups]
			for _, group in groups do
				if n >= group.first and n <= group.last then selected = group break end
			end
			local localIndex = n - selected.first + 1
			local groupCount = math.max(1, selected.count)
			if selected.name == "Feet" then
				position = Formations.feet(localIndex, groupCount, character, root, now)
			elseif selected.name == "Shield" then
				position = Formations.shield(localIndex, groupCount, root, now, Config)
			elseif selected.name == "Armor" then
				local surface = entity.armorSurfaces[localIndex]
				local bodyPart = surface and entity.history.body[surface.bone]
				position = bodyPart and bodyPart.Parent and bodyPart.CFrame:PointToWorldSpace(surface.point * 1.14)
					or root.Position
			elseif selected.name == "Platform" then
				position = Formations.platform(localIndex, groupCount, platformCF, now, Config)
			elseif selected.name == "Follow" then
				position = Formations.follow(localIndex, groupCount, entity.aim, now)
			else
				position = Formations.cloud(localIndex, groupCount, root.CFrame, now, Config)
			end
		end
		local rotation = CFrame.Angles(now * 0.6 + i, now * 0.4 + i * 0.3, i * 0.7)
		local target = CFrame.new(position) * rotation
		block.cf = block.cf:Lerp(target, a)
		local birth = Math.smooth((os.clock() - block.born - (i / math.max(1, count)) * 0.35) / 0.5)
		local transparency = 1 - entity.visible * birth * (i % 5 == 0 and 0.6 or 0.95)
		if math.abs(block.part.Transparency - transparency) > 0.015 then block.part.Transparency = transparency end
		self.pool:Queue(block.part, block.cf)
	end
	local cloneCount = #entity.clone
	local offset = Math.clampVector(Config.CloneOffset, Config.CloneMaxDistance)
	for i, block in entity.clone do
		local target, opacity
		if cloneOn and pose and block.surface then
			local surface = block.surface
			local bone = pose.bones[surface.bone]
			local wantedCenter = pose.root:PointToWorldSpace(offset)
			local center = root.Position + Math.clampVector(wantedCenter - root.Position, Config.CloneMaxDistance)
			local cloneRoot = CFrame.new(center) * pose.root.Rotation
			local body = bone and cloneRoot * bone or cloneRoot
			local destination = body:PointToWorldSpace(surface.point)
			local age = now - cloneAt
			local progress = Math.smooth((age - surface.order * Config.CloneBuildTime * 0.7) / (Config.CloneBuildTime * 0.3))
			local origin = root.Position + Vector3.new(math.sin(i) * 0.6, math.cos(i * 2) * 1.5, 0)
			local path = origin:Lerp(destination, progress)
			path += Vector3.new(0, math.sin(progress * math.pi) * (1.5 + (i % 5) * 0.2), 0)
			local flicker = math.sin(now * 4 + i * 1.7) * 0.025
			target = CFrame.new(path + Vector3.new(flicker, 0, -flicker)) * body.Rotation
			opacity = math.clamp((age - surface.order * Config.CloneBuildTime * 0.65) * 4, 0, 0.93)
		else
			local progress = Math.smooth((now - (entity.cloneEnded or now)) / Config.CloneReturnTime)
			local start = block.departure or block.cf
			local destination = root.Position + Vector3.new(0, math.sin(i) * 0.4, 0)
			local scatter = Vector3.new(math.sin(i * 3), math.cos(i * 7), math.cos(i * 5))
			local path = start.Position:Lerp(destination, progress) + scatter * math.sin(progress * math.pi) * 2
			target = CFrame.new(path) * start.Rotation
			opacity = (1 - progress) * 0.9
		end
		block.cf = block.cf:Lerp(target, Math.alpha(cloneOn and 24 or 12, dt))
		local transparency = 1 - opacity
		if math.abs(block.part.Transparency - transparency) > 0.015 then block.part.Transparency = transparency end
		self.pool:Queue(block.part, block.cf)
	end
	if not cloneOn and entity.cloneEnded and now - entity.cloneEnded > Config.CloneReturnTime + 0.1 then
		self:Resize(entity, entity.clone, 0, true)
		entity.cloneEnded = nil
	end
	if not enabled and entity.visible < 0.01 then self:Resize(entity, entity.swarm, 0, false) end
	if not equipped and entity.visible < 0.01 and cloneCount == 0 then self:Dispose(entity) end
end

function Renderer:Step(dt)
	if not self.running then return end
	self.smoothedFrame += (dt - self.smoothedFrame) * Math.alpha(0.5, dt)
	if Config.Quality ~= "Auto" and Config.QualityLevels[Config.Quality] then
		self.quality = Config.Quality
	elseif self.smoothedFrame > 1 / 35 then
		self.quality = "Low"
	elseif self.smoothedFrame < 1 / 55 then
		self.quality = "High"
	else
		self.quality = "Medium"
	end
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local now = Workspace:GetServerTimeNow()
	local players = Players:GetPlayers()
	table.sort(players, function(a, b)
		if a == b then return false end
		if a == Players.LocalPlayer then return true end
		if b == Players.LocalPlayer then return false end
		local ar = a.Character and a.Character:FindFirstChild("HumanoidRootPart")
		local br = b.Character and b.Character:FindFirstChild("HumanoidRootPart")
		local ad = ar and (ar.Position - camera.CFrame.Position).Magnitude or math.huge
		local bd = br and (br.Position - camera.CFrame.Position).Magnitude or math.huge
		return ad < bd
	end)
	for _, player in players do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local entity = self.entities[player]
		if entity and (entity.character ~= char or not entity.root.Parent) then
			self:Dispose(entity)
			entity = nil
		end
		if root then
			local distance = (root.Position - camera.CFrame.Position).Magnitude
			if distance <= Config.CullDistance then
				if not entity and char:GetAttribute("NanoEquipped") then entity = self:Create(player, char, root) end
				if entity then
					entity.accumulator += dt
					local interval = player == Players.LocalPlayer and 0
						or 1 / (distance > Config.FarDistance and Config.FarFPS or Config.RemoteFPS)
					if entity.accumulator >= interval then
						local elapsed = math.min(entity.accumulator, 0.15)
						entity.accumulator = 0
						self:Draw(entity, elapsed, now, distance)
					end
				end
			elseif entity then self:Dispose(entity) end
		end
	end
	for player, entity in self.entities do
		if not player.Parent then self:Dispose(entity) end
	end
	self.pool:Flush()
end

function Renderer:SetAim(position) self.localAim = position end
function Renderer:Destroy()
	self.running = false
	self.connection:Disconnect()
	for _, entity in self.entities do self:Dispose(entity) end
	self.pool:Destroy()
end
return Renderer
end)()

local InputController = (function()
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Nano = ReplicatedStorage:WaitForChild("NanoSystem")
local Input = {}
Input.__index = Input

local definitions = {
	{ "Toggle", "Ativar", Enum.KeyCode.Q },
	{ "Follow", "Seguir mira", nil },
	{ "Cloud", "Nuvem", Enum.KeyCode.R },
	{ "Flight", "Voo / pousar", Enum.KeyCode.F },
	{ "Clone", "Clone", Enum.KeyCode.C },
	{ "Armor", "Armadura", Enum.KeyCode.Z },
	{ "Shield", "Escudo", Enum.KeyCode.X },
	{ "Platform", "Plataforma", Enum.KeyCode.V },
	{ "Recall", "Recolher", Enum.KeyCode.T },
}

local function label(parent, text, size)
	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.Text = text
	value.Font = Enum.Font.GothamMedium
	value.TextSize = size or 14
	value.TextColor3 = Config.Accent
	value.Size = UDim2.new(1, 0, 0, 24)
	value.TextXAlignment = Enum.TextXAlignment.Left
	value.Parent = parent
	return value
end

function Input.new(renderer)
	local self = setmetatable({
		renderer = renderer, player = Players.LocalPlayer, connections = {},
		up = false, down = false, touchUp = false, touchDown = false,
		accumulator = 0, uiClock = 0, targetScreen = nil,
		touch = nil, buttons = {}, actionNames = {},
	}, Input)
	self:BuildUI()
	self:Bind()
	return self
end

function Input:IsEquipped()
	local char = self.player.Character
	if not char then return false end
	for _, item in char:GetChildren() do
		if item:IsA("Tool") and item.Name == Config.ToolName and item:GetAttribute("NanoTool") then return true end
	end
	return false
end

function Input:Action(action)
	if self:IsEquipped() and not UserInputService:GetFocusedTextBox() then
		Nano.Remotes.Request:FireServer(action)
	end
end

function Input:Connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(self.connections, connection)
	return connection
end

function Input:BuildUI()
	local gui = Instance.new("ScreenGui")
	gui.Name = "NanoControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 15
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = self.player:WaitForChild("PlayerGui")
	self.gui = gui
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -16, 0, 16)
	panel.Size = UDim2.fromOffset(224, 350)
	panel.BackgroundColor3 = Config.Dark
	panel.BackgroundTransparency = 0.15
	panel.Visible = false
	panel.Parent = gui
	self.panel = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Config.Color
	stroke.Transparency = 0.45
	stroke.Parent = panel
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.Parent = panel
	local title = label(panel, "NANO / CONTROLE", 16)
	title.Position = UDim2.fromOffset(0, 0)
	self.status = label(panel, "Equipando...", 12)
	self.status.Position = UDim2.fromOffset(0, 26)
	self.status.Size = UDim2.new(1, 0, 0, 34)
	self.status.TextWrapped = true
	local grid = Instance.new("Frame")
	grid.Name = "Abilities"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromOffset(0, 68)
	grid.Size = UDim2.new(1, 0, 0, 190)
	grid.Parent = panel
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0.5, -3, 0, 32)
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	for n, def in definitions do
		local button = Instance.new("TextButton")
		button.Name = def[1]
		button.Text = def[2]
		if not UserInputService.TouchEnabled then
			button.Text = (def[3] and def[3].Name or "Clique") .. " · " .. def[2]
		end
		button.Font = Enum.Font.GothamMedium
		button.TextSize = 12
		button.TextColor3 = Config.Accent
		button.BackgroundColor3 = Color3.fromRGB(25, 67, 69)
		button.AutoButtonColor = true
		button.LayoutOrder = n
		button.Parent = grid
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 6)
		round.Parent = button
		self.buttons[def[1]] = button
		self:Connect(button.Activated, function() self:Action(def[1]) end)
	end
	local lift = Instance.new("Frame")
	lift.Name = "Altitude"
	lift.Position = UDim2.fromOffset(0, 260)
	lift.Size = UDim2.new(1, 0, 0, 36)
	lift.BackgroundTransparency = 1
	lift.Parent = panel
	self.lift = lift
	for n, text in { "Subir", "Descer" } do
		local button = Instance.new("TextButton")
		button.Name = text
		button.Position = UDim2.new((n - 1) * 0.5, n == 1 and 0 or 3, 0, 0)
		button.Size = UDim2.new(0.5, -3, 1, 0)
		button.Text = UserInputService.TouchEnabled and text or (n == 1 and "Espaço: subir" or "Ctrl: descer")
		button.TextColor3 = Config.Accent
		button.BackgroundColor3 = Color3.fromRGB(25, 67, 69)
		button.Font = Enum.Font.GothamMedium
		button.TextSize = 12
		button.Parent = lift
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0, 6)
		round.Parent = button
		self:Connect(button.InputBegan, function(event)
			if event.UserInputType == Enum.UserInputType.Touch or event.UserInputType == Enum.UserInputType.MouseButton1 then
				if n == 1 then self.touchUp = true else self.touchDown = true end
				if n == 1 then self.upInput = event else self.downInput = event end
			end
		end)
		self:Connect(button.InputEnded, function(event)
			if event.UserInputType == Enum.UserInputType.Touch or event.UserInputType == Enum.UserInputType.MouseButton1 then
				if n == 1 then self.touchUp = false else self.touchDown = false end
			end
		end)
	end
	self.hint = label(panel, "WASD / analógico: direção", 11)
	self.hint.Position = UDim2.fromOffset(0, 301)
	-- Em telas baixas o painel fica menor sem invadir o botão padrão de pulo.
	local scale = Instance.new("UIScale")
	scale.Parent = panel
	self.scale = scale
end

function Input:Bind()
	for _, def in definitions do
		if def[3] then
			local name = "Nano_" .. def[1]
			table.insert(self.actionNames, name)
			ContextActionService:BindAction(name, function(_, state)
				if not self:IsEquipped() or UserInputService:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
				if state == Enum.UserInputState.Begin then self:Action(def[1]) end
				return Enum.ContextActionResult.Sink
			end, false, def[3])
		end
	end
	local function vertical(name, state)
		local char = self.player.Character
		if not self:IsEquipped() or not char or not char:GetAttribute("NanoFlight")
			or UserInputService:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
		local pressed = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
		if name == "Nano_Up" then self.up = pressed else self.down = pressed end
		return Enum.ContextActionResult.Sink
	end
	ContextActionService:BindAction("Nano_Up", vertical, false, Enum.KeyCode.Space)
	ContextActionService:BindAction("Nano_Down", vertical, false, Enum.KeyCode.LeftControl)
	table.insert(self.actionNames, "Nano_Up")
	table.insert(self.actionNames, "Nano_Down")
	self:Connect(UserInputService.InputEnded, function(event)
		if event.KeyCode == Enum.KeyCode.Space then self.up = false end
		if event.KeyCode == Enum.KeyCode.LeftControl then self.down = false end
		if event.UserInputType == Enum.UserInputType.MouseButton1 then
			self.touchUp, self.touchDown = false, false
		end
		if event == self.touch then self.touch = nil end
		if event == self.upInput then self.touchUp = false self.upInput = nil end
		if event == self.downInput then self.touchDown = false self.downInput = nil end
	end)
	self:Connect(UserInputService.WindowFocusReleased, function()
		self.up, self.down, self.touchUp, self.touchDown = false, false, false, false
	end)
	self:Connect(UserInputService.TouchStarted, function(event, processed)
		if processed or not self:IsEquipped() or self.touch then return end
		local camera = Workspace.CurrentCamera
		if not camera then return end
		local p = event.Position
		-- Reserva o lado esquerdo para o analógico e a base direita para o pulo.
		if p.X < camera.ViewportSize.X * 0.38 or p.Y > camera.ViewportSize.Y * 0.78 then return end
		local items = self.player.PlayerGui:GetGuiObjectsAtPosition(p.X, p.Y)
		for _, item in items do if item:IsDescendantOf(self.gui) then return end end
		self.touch = event
		self.targetScreen = Vector2.new(p.X, p.Y)
	end)
	self:Connect(UserInputService.TouchMoved, function(event)
		if self.touch == event then self.targetScreen = Vector2.new(event.Position.X, event.Position.Y) end
	end)
	self:Connect(Nano.Remotes.Feedback.OnClientEvent, function(success, _, message)
		self.status.Text = message
		self.status.TextColor3 = success and Config.Accent or Color3.fromRGB(255, 185, 110)
		self.messageUntil = os.clock() + 2.5
		local stroke = self.panel:FindFirstChildOfClass("UIStroke")
		stroke.Transparency = 0.05
		if self.strokeTween then self.strokeTween:Cancel() end
		self.strokeTween = TweenService:Create(stroke, TweenInfo.new(0.5), { Transparency = 0.45 })
		self.strokeTween:Play()
	end)
end

function Input:Aim(root)
	local camera = Workspace.CurrentCamera
	if not camera then return root.Position end
	local screen
	local lastType = UserInputService:GetLastInputType()
	if lastType == Enum.UserInputType.Touch then
		screen = self.targetScreen or camera.ViewportSize * 0.5
	else screen = UserInputService:GetMouseLocation() end
	local ray = camera:ScreenPointToRay(screen.X, screen.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.player.Character, self.renderer.pool.folder }
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * Config.AimDistance * 2, params)
	local point = hit and hit.Position or ray.Origin + ray.Direction * Config.AimDefaultDistance
	return root.Position + Math.clampVector(point - root.Position, Config.AimDistance)
end

function Input:Move(humanoid)
	if UserInputService:GetFocusedTextBox() then return Vector3.zero end
	local x, z = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then x -= 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then x += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then z += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then z -= 1 end
	if x ~= 0 or z ~= 0 then
		local camera = Workspace.CurrentCamera
		if not camera then return Vector3.zero end
		local forward = Math.flat(camera.CFrame.LookVector)
		local right = Vector3.new(-forward.Z, 0, forward.X)
		return Math.clampVector(right * x + forward * z, 1)
	end
	-- O analógico padrão do Roblox continua funcionando; não importamos módulos privados.
	return Math.clampVector(Vector3.new(humanoid.MoveDirection.X, 0, humanoid.MoveDirection.Z), 1)
end

function Input:Step(dt)
	local char = self.player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local equipped = root ~= nil and humanoid ~= nil and self:IsEquipped()
	self.panel.Visible = equipped
	if not equipped then
		self.up, self.down, self.touchUp, self.touchDown = false, false, false, false
		self.touch, self.targetScreen = nil, nil
	end
	local camera = Workspace.CurrentCamera
	local flying = equipped and char:GetAttribute("NanoFlight") == true
	if camera and Config.FlightFOVBoost > 0 then
		if flying and not self.baseFOV then self.baseFOV = camera.FieldOfView self.fovCamera = camera end
		if self.baseFOV and self.fovCamera == camera then
			local target = self.baseFOV + (flying and Config.FlightFOVBoost or 0)
			camera.FieldOfView += (target - camera.FieldOfView) * Math.alpha(4, dt)
			if not flying and math.abs(camera.FieldOfView - self.baseFOV) < 0.02 then
				camera.FieldOfView = self.baseFOV
				self.baseFOV = nil
			end
		elseif self.fovCamera and self.fovCamera ~= camera then self.baseFOV = nil end
	end
	if not equipped then return end
	self.scale.Scale = camera and math.clamp(camera.ViewportSize.Y / 760, 0.65, 1) or 1
	local aim = self:Aim(root)
	self.renderer:SetAim(aim)
	self.accumulator += dt
	if self.accumulator >= 1 / Config.InputRate then
		self.accumulator = 0
		local vertical = (self.up or self.touchUp) and 1 or 0
		if self.down or self.touchDown then vertical -= 1 end
		if UserInputService:GetFocusedTextBox() then vertical = 0 end
		Nano.Remotes.Control:FireServer(aim, self:Move(humanoid), vertical, camera and camera.CFrame.LookVector or root.CFrame.LookVector)
	end
	self.uiClock += dt
	if self.uiClock >= 0.15 then
		self.uiClock = 0
		local now = Workspace:GetServerTimeNow()
		local active = {
			Toggle = char:GetAttribute("NanoEnabled"),
			Follow = char:GetAttribute("NanoMode") == "Follow",
			Cloud = char:GetAttribute("NanoMode") ~= "Follow",
			Flight = flying, Clone = char:GetAttribute("NanoClone"),
			Armor = (char:GetAttribute("NanoArmorUntil") or 0) > now,
			Shield = (char:GetAttribute("NanoShieldUntil") or 0) > now,
			Platform = (char:GetAttribute("NanoPlatformUntil") or 0) > now,
		}
		for name, button in self.buttons do
			button.BackgroundColor3 = active[name] and Color3.fromRGB(29, 109, 99) or Color3.fromRGB(25, 67, 69)
		end
		self.lift.Visible = flying
		self.hint.Text = flying and "WASD / analógico: direção" or "Clique / Seguir mira: enxame"
		if os.clock() > (self.messageUntil or 0) then
			self.status.Text = "Qualidade: " .. self.renderer.quality .. " | blocos: " .. tostring(self.renderer.pool.total)
			self.status.TextColor3 = Config.Accent
		end
	end
end

function Input:Destroy()
	for _, name in self.actionNames do ContextActionService:UnbindAction(name) end
	for _, connection in self.connections do connection:Disconnect() end
	if self.strokeTween then self.strokeTween:Cancel() end
	if self.baseFOV and self.fovCamera then self.fovCamera.FieldOfView = self.baseFOV end
	self.gui:Destroy()
end
return Input
end)()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local request = ReplicatedStorage:WaitForChild("NanoSystem"):WaitForChild("Remotes"):WaitForChild("Request")
local renderer = Renderer.new()
local input = InputController.new(renderer)
local connection = RunService.RenderStepped:Connect(function(dt) input:Step(dt) end)
local toolConnections = {}
local childConnection

local function bindTool(tool)
    if not tool:IsA("Tool") or tool.Name ~= Config.ToolName or toolConnections[tool] then return end
    if tool:GetAttribute("NanoTool") ~= true then return end
    local activated = tool.Activated:Connect(function()
        if tool.Parent == player.Character and UserInputService:GetLastInputType() ~= Enum.UserInputType.Touch then
            request:FireServer("Follow")
        end
    end)
    toolConnections[tool] = activated
end

local function bindCharacter(character)
    if childConnection then childConnection:Disconnect() end
    for tool, conn in toolConnections do conn:Disconnect() toolConnections[tool] = nil end
    for _, item in character:GetChildren() do bindTool(item) end
    childConnection = character.ChildAdded:Connect(bindTool)
end

local characterConnection = player.CharacterAdded:Connect(bindCharacter)
if player.Character then bindCharacter(player.Character) end
script.Destroying:Connect(function()
    connection:Disconnect()
    characterConnection:Disconnect()
    if childConnection then childConnection:Disconnect() end
    for _, conn in toolConnections do conn:Disconnect() end
    input:Destroy()
    renderer:Destroy()
end)
