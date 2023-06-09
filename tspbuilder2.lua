local eventDispatcher = require("eventDispatcher")
local shell = require("shell")
local model = require("builder/model")
local objectStore = require("objectStore")
local component = require("component")
local smartmove = require("smartmove")
local inventory = require("inventory")
local sides = require("sides")
local util = require("util")
local serializer = require("serializer")
local internet = require("internet")
local os = require("os")
local robot
local ic

local builder = {}
local Builder = {}

local NEEDS_CHARGE_THRESHOLD = 0.20
local FULL_CHARGE_THRESHOLD = 0.95
local MOVE_RETRY_LIMIT = 10


function Builder:loadModel()
  self.options.loadedModel = model.load(self.options.model)
end

function Builder:saveState()
  if self.options.saveState then
    return objectStore.saveObject("builder", self.options)
  end
end

function Builder:loadState()
  local result = objectStore.loadObject("builder")
  if result ~= nil then
    self.options = result
    self:applyDefaults()
    model.prepareState(self.options.loadedModel)
    return true
  end
  return false
end

function Builder:backToStart() --luacheck: no unused args
  -- something went wrong the robot needs to get back home (charge level, etc)
  -- first thing we need to do is get to the droppoint for the level we are on.

  local thisLevel = self.options.loadedModel.levels[self.move.posY] or self.options.loadedModel.levels[self.move.posY-1]
  print("Headed home from level " .. thisLevel.num .. " at " .. model.pointStr({-self.move.posX, self.move.posZ}))
  
  self:moveToXZ(self.options.loadedModel.startPoint[1], self.options.loadedModel.startPoint[2])
  self:moveToY(self.options.loadedModel.startPoint[3])
  
  -- just to look nice and make restarts easy to deal with.
  self.move:faceDirection(self.originalOrient)
  
  -- we should be back on the charger now.
  print("Charging... ")
  -- TODO: Check out the infinite timeout and implement commented part
  if not util.waitUntilCharge(FULL_CHARGE_THRESHOLD, 60) then
    return false, "I'm out of energy sir!"
  end

  return true
end

function Builder:statusCheck()
  if self.toolName and inventory.toolIsBroken() then -- todo: maybe should allow for more durability than normal.
    if not inventory.equipFreshTool(self.toolName) then
      if not self.isReturningToStart then
        -- we dont bail out if returning to start in this case, just hope we dont actually need the tool
        return false, "Lost durability on tool and can't find a fresh one in my inventory!"
      end
    end
  end
  if not self.isReturningToStart then
    local isFull = inventory.isLocalFull()
    if isFull then
      -- inventory is full but maybe we can dump some trash to make room
      if self.options.trashCobble then
        --todo: more specific so we dont drop mossy cobble, for example
        inventory.trash(sides.bottom, {"cobblestone","netherrack"})
        -- if it is STILL full then we're done here
        if inventory.isLocalFull() then
          return false, "Inventory is full!"
        end
      else
        return false, "Inventory is full!"
      end
    else
      self.cachedIsNotFull = true
    end

    -- need charging?
    if util.needsCharging(NEEDS_CHARGE_THRESHOLD) then
      return false, "Charge level is low!"
    end
  end
  return true
end

function Builder:start()
  if not self.options.loadedModel then
    print("Loading model...")
    self:loadModel()
	
    self.options.loadedModel.progress = { level = 1, node = 1 }
	
    print("Saving state...")
    self:saveState()
  end

  if not self.options.resuming then
    -- a new build, make sure we don't think saved statuses are from a previous one.
    model.clearStatuses(true)
  end

  print("Checking things out...")

  -- see what our tool is
  ic.equip()
  local tool = ic.getStackInInternalSlot(1)
  if tool == nil or type(tool.maxDamage) ~= "number" then
    ic.equip()
    print("I dont seem to have a tool equipped! I won't be able to clear any existing blocks, I hope that's ok.")
  else
    self.toolName = tool.name
  end
  ic.equip()
  
  self.move = smartmove:new({ moveTimeout = 60 })
  local startPoint = self.options.loadedModel.startPoint
  self.move.posX = startPoint[1]
  self.move.posZ = startPoint[2]
  self.move.posY = startPoint[3]
  -- the 4th item of the startpoint vector is which way the robot is facing.
  -- we need to adjust smartmove's orientation to match since it defaults to `1` (+x)
  if startPoint[4] == 'v' then
    self.move.orient = -1
  elseif startPoint[4] == '^' then
    self.move.orient = 1
  elseif startPoint[4] == '<' then
    self.move.orient = -2
  elseif startPoint[4] == '>' then
    self.move.orient = 2
  end
  self.originalOrient = self.move.orient

  repeat
    print("I'm off to build stuff, wish me luck!")
    local result, reason = self:iterate()
    if not result then
      print("Oh no! " .. (reason or "Unknown iterate failure."))
      self.isReturningToStart = true
      result, reason = self:backToStart()
      self.isReturningToStart = false
      if not result then
        print("I just can't go on :( " .. reason)
        print("Sorry I let you down, master. I'm at " .. model.pointStr({-self.move.posX,self.move.posY}))
        return false
      end
    else
	  self:backToStart()
      print("Job's done! Do you like it?")
      return true
    end
  until self.returnRequested
  
  --self:moveToXZ(0,0)
  --self:backToStart())

end

function Builder:downloadLevel(l)
  local blocksInfo = l._model._downloadedBlocks
  if blocksInfo and blocksInfo.forLevel == l.num then
    return
  end
  
  
  -- the blocks for this level are loaded from an internet level file
  -- so download the block list
  -- remove it before downloading, for more memory..
  l._model._downloadedBlocks = nil
  -- yield to help gc?
  self:freeMemory()
  
  print("Downloading blocks for level " .. l.num)
  local data = internet.request("https://raw.githubusercontent.com/" .. l._model.blocksBaseUrl
  .. "/" .. string.format("%03d", l.num-1) .. "?" .. math.random())
  
  local tmpFile = io.open("/home/oclib/builder_model_tmp", "w")
  print(tmpFile)
  for chunk in data do
    tmpFile:write(chunk)
  end
  tmpFile:flush()
  tmpFile:close()
  print("Blocks downloaded, parsing...")
  
  self:freeMemory()
  
  l._model._downloadedBlocks = { blocks = serializer.deserializeFile("/home/oclib/builder_model_tmp"), forLevel = l.num }
  print(#l._model._downloadedBlocks.blocks.level)
end

function Builder:iterate()

  -- before we begin, do a resupply run.
  local posX = self.move.posX
  local posZ = self.move.posZ
  local dumped = self:dumpInventoryAndResupply()
  if not dumped then
    self:moveToXZ(posX, posZ)
    self.move:faceDirection(self.originalOrient)
    return false, "Problem dumping inventory or picking up supplies."
  end
  if not self:moveToXZ(posX, posZ) then
    self.move:faceDirection(self.originalOrient)
    return false, "Could not dump inventory, resupply, and return safely."
  end

  local result, reason = self:build()
  if not result then
    return false, reason
  end
  
  -- TODO: model.markLevelComplete(thisLevel)
  
  return true
end

function Builder:build()
  for j = self.options.loadedModel.progress.level, #self.options.loadedModel.levels do
    self.options.loadedModel.progress.level = j
    self:saveState()
	
	result, reason = self:statusCheck()
    if not result then
      return false, reason
    end
	
    self:downloadLevel(self.options.loadedModel.levels[j])
    if not self:moveToY(j + 1) then
	  return false
	end
    
    local level = self.options.loadedModel._downloadedBlocks.blocks.level
	result, reason = self:buildLevel(level)
    if not result then
      return false, reason
    end
  end
  
  return true
end

function Builder:buildLevel(level)
  for i = self.options.loadedModel.progress.node, #level do
	self.options.loadedModel.progress.node = i
    self:saveState()
	local node = level[i]
	
    if not self:moveToXZ(node[1],node[2]) then
	  return false
	end
  
    if(node[3] > 0) then
      local blockName = self.options.loadedModel.mats[tostring(node[3])]
      if not inventory.selectItem(blockName) then
      -- we seem to be out of this material
        return false, "no more " .. blockName
      end
      result, reason = self:tryPlaceDown()
      if not result then
        return false, "could not place block " .. blockName .. ": " .. (reason or "unknown")
      end
    end
  end
  self.options.loadedModel.progress.node = 1
  self:saveState()
  
  return true
end

function Builder:tryPlaceDown()
  local result = robot.placeDown()
  if not result then
    result = self:smartSwingDown()
    if not result then
      return false
    end
	robot.placeDown()
  end
  
  return true
end

function Builder:smartSwingDown() -- luacheck: no unused args
  local isBlocking, entityType = robot.detectDown()
  while isBlocking or entityType ~= "air" do
    -- this is a LOOP because even after clearing the space there might still be something there,
    -- such as when gravel falls, or an entity has moved in the way.
    local result = robot.swingDown()
    if not result then
      -- perhaps the thing is a bee hive, which requires a scoop to clear.
      -- equip a scoop if we have one and try again.
      if inventory.equip("scoop") then
        result = robot.swingDown()
        -- switch back off the scoop
        ic.equip()
      end
      if not result then
        -- something is in the way and we couldnt deal with it
        return false, entityType
      end
    end
    isBlocking, entityType = robot.detectDown()
  end
  return true
end

function Builder:smartSwingUp() -- luacheck: no unused args
  local isBlocking, entityType = robot.detectUp()
  while isBlocking or entityType ~= "air" do
    -- this is a LOOP because even after clearing the space there might still be something there,
    -- such as when gravel falls, or an entity has moved in the way.
    local result = robot.swingUp()
    if not result then
      -- perhaps the thing is a bee hive, which requires a scoop to clear.
      -- equip a scoop if we have one and try again.
      if inventory.equip("scoop") then
        result = robot.swingUp()
        -- switch back off the scoop
        ic.equip()
      end
      if not result then
        -- something is in the way and we couldnt deal with it
        return false, entityType
      end
    end
    isBlocking, entityType = robot.detectUp()
  end
  return true
end

function Builder:smartSwing() -- luacheck: no unused args
  local isBlocking, entityType = robot.detect()
  while isBlocking or entityType ~= "air" do
    -- this is a LOOP because even after clearing the space there might still be something there,
    -- such as when gravel falls, or an entity has moved in the way.
    local result = robot.swing()
    if not result then
      -- perhaps the thing is a bee hive, which requires a scoop to clear.
      -- equip a scoop if we have one and try again.
      if inventory.equip("scoop") then
        result = robot.swing()
        -- switch back off the scoop
        ic.equip()
      end
      if not result then
        -- something is in the way and we couldnt deal with it
        return false, entityType
      end
    end
    isBlocking, entityType = robot.detect()
  end
  return true
end

function Builder:moveToXZ(x,z)
  local result = self.move:moveToXZ(x,z)
  if not result then
    local attemptsCount = 1
    while attemptsCount < MOVE_RETRY_LIMIT do
	  attemptsCount = attemptsCount + 1
      self.move:faceXZ(x,z)
      self:smartSwing()
      result = self.move:moveToXZ(x,z)
      if result then
	    return true
	  end
    end
	return false
  end
  return true
end

function Builder:moveToY(y)
  local result = self.move:moveToY(y)
  if not result then
    local attemptsCount = 1
    while attemptsCount < MOVE_RETRY_LIMIT do
      if y > self.move.posY then
	    self:smartSwingUp()
      elseif y > self.move.posZ then
	    self:smartSwingDown()
      end
      result = self.move:moveToY(y)
      if result then
	    return true
	  end
    end
	return false
  end
  return true
end

function Builder:dumpInventoryAndResupply()
  local maxAttempts = 10
  local missingMaterial = nil
  while maxAttempts > 0 do
    -- find a chest...
    maxAttempts = maxAttempts - 1
    local result = self.move:findInventory(-2, 5, true, 16)
    if result == nil or result <= 0 then
      -- no inventory found within 5 blocks so we're done here.
      -- but, its ok if our inventory is not full and we have at least 1
      -- block of each required material...
      local isLocalFull = inventory.isLocalFull()
      local hasMats = inventory.hasMaterials(self.options.loadedModel.matCounts)
      return not isLocalFull and hasMats
    end

    -- remove excess materials that we probably picked up while building...
    local desupplied = inventory.desupply(sides.bottom, self.options.loadedModel.matCounts, 256)
    -- pick up any materials we are missing, if any are present
    local _, hasZeroOfSomething = inventory.resupply(sides.bottom, self.options.loadedModel.matCounts, 256)

    if not desupplied then
      -- maybe now that we picked stuff up we can successfully desupply again
      desupplied = inventory.desupply(sides.bottom, self.options.loadedModel.matCounts, 256)
    end

    -- drop broken tools and pick up fresh ones, if we had a tool to begin with
    -- we aren't tracking if this succeeds or not, because combined with the de/resupply stuff
    -- its kinda complex. If we end up without a tool we may not even need one, so I dunno.
    if self.toolName then
      inventory.dropBrokenTools(sides.bottom, self.toolName)
      inventory.pickUpFreshTools(sides.bottom, self.toolName)
    end

    -- are we good?
    if desupplied and not hasZeroOfSomething then
      return true
    end
    missingMaterial = missingMaterial or hasZeroOfSomething

    -- hmm, go over to the next chest then.
  end

  if missingMaterial then
    print("I seem to be fresh out of " .. missingMaterial)
  end
  return false
end

function Builder:freeMemory()
  local result = 0
  for i = 1, 10 do
    result = math.max(result, computer.freeMemory())
    os.sleep(0)
  end
  return result
end

function builder.new(o)
  o = o or {}
  builder.require()
  setmetatable(o, { __index = Builder })
  o:applyDefaults()
  o.eventDispatcher = eventDispatcher.new({ debounce = 10 }, o)
  return o
end

function builder.require()
  robot = require("robot")
  computer = require("computer")
  ic = component.inventory_controller
end

function Builder:applyDefaults() --luacheck: no unused args
  self.options.port = tonumber(self.options.port or "888")
  self.options.trashCobble = self.options.trashCobble == true or self.options.trashCobble == "true"
  self.options.saveState = self.options.saveState == nil or self.options.saveState == true
    or self.options.saveState == "true"
end

local args, options = shell.parse( ... )
if args[1] == 'help' then
  print("commands: start, resume, summon")
elseif args[1] == 'start' then
  if (args[2] == 'help') then
    print("usage: builder start --model=mymodel.model")
  else
    local b = builder.new({options = options})
    b:start()
  end
elseif args[1] == 'resume' then
  options.resuming = true
  local b = builder.new({options = options})
  if b:loadState() then
    b:start()
  else
    print("Cannot resume. Make sure the robot has a writable hard drive to save state in.")
  end
  
else
  print("use 'help' to get available commands")
end

return builder
