--!strict

--[[
	Builds the worker NPC as a stock R6 rig and poses it.

	It is a real rig, not a lookalike: `Humanoid`, `HumanoidRootPart`, the six
	standard parts under their exact standard names, and the five `Motor6D` joints
	holding them together. Anything that inspects a character — or a later change
	that wants to hand the walk over to Roblox's animation system — finds what it
	expects.

	**But the rig stays `Anchored` and is posed by script.** This is the one place
	the worker deliberately departs from how a player's character works, and it is
	the same choice the belt seeds and fruit already make: players cannot shove a
	worker off course, there is no jitter, and a worker cannot wedge itself against
	a factory base and quietly stop earning. Handing locomotion to the Humanoid
	would mean unanchored server physics and `MoveTo`, which on this map has to
	push past 7x7 colliding machine bases — a stuck worker is a worse bug than a
	simpler walk cycle.

	Two consequences of that, both intentional:

	  - **The Motor6D joints are structural, not what moves the limbs.** Anchored
	    parts ignore their joints, so `setPose` writes each part's CFrame directly.
	    Do not add an `Animation` expecting it to play; unanchor the rig first, and
	    read the paragraph above before you do.
	  - Parts are `CanCollide = false` and `CanQuery = false`. The second matters:
	    `MouseTarget` is the client's only raycast, and a worker crossing the farm
	    would otherwise swallow clicks meant for the ground underneath it.

	`setPose` recomputes every part from the Config spec on each call rather than
	nudging last frame's values, so a worker that has been walking for an hour is
	laid out identically to one that just spawned. Same invariant as
	`PlantModel.layout`, same reason.

	The `Slot` is lifted from FactoryModel: whatever the worker is carrying sits in
	its hands in plain sight, so its state is readable across the map with no GUI to
	open.

	`HirePrompt` and `DismissPrompt` are built here disabled, exactly like
	FactoryModel's own prompt pair — WorkerService decides which one (if either) is
	live and rewrites their ActionText/ObjectText per worker, since the price and
	speed differ candidate to candidate. This module never enables one.
]]

local Config = require(script.Parent.Config)
local Produce = require(script.Parent.Produce)

local WorkerModel = {}

-- R6's joint heights, all measured up from the soles and all derived from the
-- part sizes, so the rig stays self-consistent.
--
-- For a stock character that is: hips at 2, torso 2 to 4, shoulders at 4, head
-- centred at 4.5, five studs from sole to crown.
local function metrics()
	local cfg = Config.Worker
	local hip = cfg.LimbSize.Y
	local chest = hip + cfg.TorsoSize.Y / 2
	local shoulder = hip + cfg.TorsoSize.Y
	return hip, chest, shoulder
end

-- Half a stud further out than the torso's own side, which is where R6 hangs its
-- arms: a 2-wide torso and 1-wide arms put the arm centres at 1.5.
local function armSpacing(): number
	local cfg = Config.Worker
	return cfg.TorsoSize.X / 2 + cfg.LimbSize.X / 2
end

local function newPart(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	-- See the header: the worker must not intercept the client's cursor raycast.
	part.CanQuery = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- One of the rig's five joints. Present so the model is a genuine R6 character;
-- inert while the parts are anchored.
local function joint(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame)
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = part0
end

-- Nameplate. Built once and rewritten by `setStatus`; an autonomous NPC halfway
-- across the map is otherwise indistinguishable from a stuck one.
local function buildStatus(head: BasePart)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Status"
	gui.Size = UDim2.fromOffset(190, 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, Config.Worker.StatusHeight, 0)
	gui.AlwaysOnTop = false
	gui.Adornee = head
	gui.Parent = head

	local owner = Instance.new("TextLabel")
	owner.Name = "Owner"
	owner.Size = UDim2.new(1, 0, 0.45, 0)
	owner.BackgroundTransparency = 1
	owner.Font = Enum.Font.GothamMedium
	owner.TextScaled = true
	owner.TextColor3 = Color3.fromRGB(226, 226, 226)
	owner.TextStrokeTransparency = 0.4
	owner.Text = ""
	owner.Parent = gui

	local activity = Instance.new("TextLabel")
	activity.Name = "Activity"
	activity.Position = UDim2.new(0, 0, 0.45, 0)
	activity.Size = UDim2.new(1, 0, 0.55, 0)
	activity.BackgroundTransparency = 1
	activity.Font = Enum.Font.GothamBold
	activity.TextScaled = true
	activity.TextColor3 = Color3.fromRGB(255, 255, 255)
	activity.TextStrokeTransparency = 0.3
	activity.Text = ""
	activity.Parent = gui
end

-- Hangs a limb from a socket, rotated about the socket rather than about its own
-- centre — a leg pivots at the hip, so the foot swings and the hip stays put.
local function hang(part: BasePart, base: CFrame, socket: Vector3, swing: number)
	part.CFrame = base
		* CFrame.new(socket)
		* CFrame.Angles(swing, 0, 0)
		* CFrame.new(0, -part.Size.Y / 2, 0)
end

--[[
	Stands the worker on `ground` facing `facing`, with its limbs at the point in
	the walk cycle given by `walkPhase`.

	`walkPhase` is accumulated from distance travelled rather than from elapsed
	time, so a worker standing still has still limbs — the same trick the belt
	seeds use for their tumble. `carrying` swaps the arm swing for a fixed carrying
	pose, so a laden worker reads as laden from a distance.
]]
local function setPose(model: Model, ground: Vector3, facing: Vector3, walkPhase: number, carrying: boolean)
	local cfg = Config.Worker
	local hip, chest, shoulder = metrics()
	local reach = armSpacing()

	-- Upright regardless of where it is heading: a worker walking onto the farm
	-- pad should not lean back at the step.
	local flat = Vector3.new(facing.X, 0, facing.Z)
	if flat.Magnitude < 1e-4 then
		flat = Vector3.new(0, 0, -1)
	end

	-- Two bobs per stride, which is what a pair of legs produces.
	local bob = math.abs(math.sin(walkPhase)) * cfg.BobHeight
	local stand = ground + Vector3.new(0, bob, 0)
	local base = CFrame.lookAt(stand, stand + flat.Unit)

	local swing = math.sin(walkPhase) * cfg.LegSwing

	local left = model:FindFirstChild("Left Leg")
	if left and left:IsA("BasePart") then
		hang(left, base, Vector3.new(-cfg.LegSpacing, hip, 0), swing)
	end
	local right = model:FindFirstChild("Right Leg")
	if right and right:IsA("BasePart") then
		-- Half a cycle out of step with its partner, or the worker hops.
		hang(right, base, Vector3.new(cfg.LegSpacing, hip, 0), -swing)
	end

	local leftArm = model:FindFirstChild("Left Arm")
	if leftArm and leftArm:IsA("BasePart") then
		-- Arms counter the legs when free, and both come forward to hold an item.
		local pitch = if carrying then cfg.CarryArmAngle else -swing
		hang(leftArm, base, Vector3.new(-reach, shoulder, 0), pitch)
	end
	local rightArm = model:FindFirstChild("Right Arm")
	if rightArm and rightArm:IsA("BasePart") then
		local pitch = if carrying then cfg.CarryArmAngle else swing
		hang(rightArm, base, Vector3.new(reach, shoulder, 0), pitch)
	end

	local torso = model:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		torso.CFrame = base * CFrame.new(0, chest, 0)
	end

	-- Shares the torso's place, as it does on a real character.
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.CFrame = base * CFrame.new(0, chest, 0)
	end

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		head.CFrame = base * CFrame.new(0, shoulder + cfg.HeadSize.Y / 2, 0)
	end

	local slot = model:FindFirstChild("Slot")
	if slot and slot:IsA("BasePart") then
		-- Placed wherever the carrying pose puts the hands, rather than at a fixed
		-- offset, so the item stays in them if CarryArmAngle changes. Forward is -Z,
		-- which is where CFrame.lookAt points.
		local armLength = cfg.LimbSize.Y
		local handHeight = shoulder - armLength * math.cos(cfg.CarryArmAngle)
		local handForward = -armLength * math.sin(cfg.CarryArmAngle)
		slot.CFrame = base * CFrame.new(0, handHeight, handForward)
	end
end

WorkerModel.setPose = setPose

function WorkerModel.create(): Model
	local cfg = Config.Worker

	local model = Instance.new("Model")
	model.Name = "Worker"

	local torso = newPart("Torso", model)
	torso.Size = cfg.TorsoSize
	torso.Color = cfg.TorsoColor

	-- Invisible, and sharing the torso's place. A Humanoid needs it by this exact
	-- name to consider the model a character at all.
	local root = newPart("HumanoidRootPart", model)
	root.Size = cfg.TorsoSize
	root.Transparency = 1

	local head = newPart("Head", model)
	head.Size = cfg.HeadSize
	head.Color = cfg.HeadColor

	-- What actually makes the head round. Built in, so no asset is fetched.
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = cfg.HeadMeshScale
	mesh.Parent = head

	local face = Instance.new("Decal")
	face.Name = "face"
	face.Face = Enum.NormalId.Front
	face.Texture = cfg.FaceTexture
	face.Parent = head

	-- R6's names carry meaning; "LeftArm" is not the same part as "Left Arm" to
	-- anything that reads a character.
	local limbs: { [string]: BasePart } = {}
	for _, name in ipairs({ "Left Arm", "Right Arm", "Left Leg", "Right Leg" }) do
		local limb = newPart(name, model)
		limb.Size = cfg.LimbSize
		limb.Color = if string.find(name, "Arm") then cfg.ArmColor else cfg.LegColor
		limbs[name] = limb
	end

	-- What the worker is carrying, exactly as a factory displays its contents.
	-- Bodiless until `showItem` gives it one.
	local slot = newPart("Slot", model)
	slot.Size = Vector3.one
	slot.Transparency = 1

	-- One prompt per side of hiring, on the same key-sharing logic as a factory's
	-- InputPrompt/OutputPrompt: WorkerService enables exactly one at a time, so they
	-- are never live together and can share a key. Both ship disabled — whether a
	-- worker is hireable or dismissable is WorkerService's decision, not this
	-- module's, the same contract FactoryModel uses for its own prompts.
	local hire = Instance.new("ProximityPrompt")
	hire.Name = "HirePrompt"
	hire.ActionText = "Hire"
	hire.ObjectText = "Worker"
	hire.HoldDuration = 0
	hire.MaxActivationDistance = cfg.PromptRange
	hire.RequiresLineOfSight = false
	hire.Enabled = false
	hire.Parent = torso

	-- Held rather than tapped, and on its own key, so dismissing can never be hit
	-- while mashing E to hire.
	local dismiss = Instance.new("ProximityPrompt")
	dismiss.Name = "DismissPrompt"
	dismiss.ActionText = "Dismiss"
	dismiss.ObjectText = "Worker"
	dismiss.KeyboardKeyCode = cfg.DismissKey
	dismiss.HoldDuration = cfg.DismissHoldDuration
	dismiss.MaxActivationDistance = cfg.PromptRange
	dismiss.RequiresLineOfSight = false
	dismiss.Enabled = false
	dismiss.Parent = torso

	--[[ The rig. Offsets are relative to each part's own centre, which is why the
		torso side of a hip is half the torso down and the leg side is half the leg
		up: together they meet at the joint. ]]
	local halfTorso = cfg.TorsoSize.Y / 2
	local halfLimb = cfg.LimbSize.Y / 2
	local reach = armSpacing()

	joint("RootJoint", root, torso, CFrame.new(0, 0, 0), CFrame.new(0, 0, 0))
	joint("Neck", torso, head, CFrame.new(0, halfTorso, 0), CFrame.new(0, -cfg.HeadSize.Y / 2, 0))
	joint("Left Shoulder", torso, limbs["Left Arm"],
		CFrame.new(-reach, halfTorso, 0), CFrame.new(0, halfLimb, 0))
	joint("Right Shoulder", torso, limbs["Right Arm"],
		CFrame.new(reach, halfTorso, 0), CFrame.new(0, halfLimb, 0))
	joint("Left Hip", torso, limbs["Left Leg"],
		CFrame.new(-cfg.LegSpacing, -halfTorso, 0), CFrame.new(0, halfLimb, 0))
	joint("Right Hip", torso, limbs["Right Leg"],
		CFrame.new(cfg.LegSpacing, -halfTorso, 0), CFrame.new(0, halfLimb, 0))

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	-- The rig is posed by script, so the state machine has nothing to decide and
	-- would only fight the anchoring.
	humanoid.EvaluateStateMachine = false
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	-- The nameplate above the head is ours; Roblox's would sit on top of it.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.Parent = model

	-- An Animator makes it a complete rig even though nothing plays through it
	-- while the parts are anchored.
	local animator = Instance.new("Animator")
	animator.Parent = humanoid

	-- Says out loud what is true: a script is moving this rig. Left alone a
	-- Humanoid whose root never touches anything settles on `FallingDown`, which
	-- reads as a bug to anyone who inspects a worker.
	--
	-- The order matters. While the state machine is still evaluating it overrules
	-- this immediately and goes back to falling; with evaluation already off, the
	-- change sticks.
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	if cfg.ShowStatus then
		buildStatus(head)
	end

	model.PrimaryPart = root
	-- Laid out at the origin until `setPose` says where the worker is standing.
	setPose(model, Vector3.zero, Vector3.new(0, 0, -1), 0, false)
	return model
end

-- Puts an item in the worker's hands, or empties them when `itemName` is nil.
-- The look comes from Produce, so a carried strawberry matches the one in a
-- Backpack and the one sitting in a factory.
function WorkerModel.showItem(model: Model, itemName: string?)
	local slot = model:FindFirstChild("Slot")
	if not (slot and slot:IsA("BasePart")) then
		return
	end
	local part = slot :: BasePart

	local spec = if itemName then Produce.spec(itemName) else nil
	if not spec then
		part.Transparency = 1
		return
	end

	part.Shape = spec.Shape
	part.Size = spec.Size
	part.Color = spec.Color
	part.Transparency = 0
end

function WorkerModel.setStatus(model: Model, ownerName: string, activity: string)
	local head = model:FindFirstChild("Head")
	local gui = head and head:FindFirstChild("Status")
	if not gui then
		return
	end

	local owner = gui:FindFirstChild("Owner")
	if owner and owner:IsA("TextLabel") then
		owner.Text = ownerName .. "'s worker"
	end

	local label = gui:FindFirstChild("Activity")
	if label and label:IsA("TextLabel") then
		label.Text = activity
	end
end

return WorkerModel
