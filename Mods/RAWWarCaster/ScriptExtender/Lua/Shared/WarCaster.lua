local MAX_CHAR_SLOTS = 16
local SLOTS_PER_CHAR = 12
local WAR_CASTER_PASSIVE = "WarCaster_OpportunitySpell"
local POLEARM_MASTER_PASSIVE = "PolearmMaster_AttackOfOpportunity"

local syncChannel = Ext.Net.CreateChannel(ModuleUUID, "KJ_WarCaster_SyncPools")
local requestChannel = Ext.Net.CreateChannel(ModuleUUID, "KJ_WarCaster_RequestSync")

local SpellToWCInterrupts = {}
local CachedChildrenMap = nil

local function GetCharPassiveName(charIndex, slotIndex)
    return string.format("KJ_WarCaster_Char%d_%d", charIndex, slotIndex)
end

local function IsNpcOrIgnoredSpell(spellName)
    if string.find(spellName, "^KJ_") or string.find(spellName, "^AI_") or string.find(spellName, "^Quest_") or string.find(spellName, "^DEBUG_") then
        return true
    end
    if string.find(spellName, "_LOW_") or string.find(spellName, "_END_") or string.find(spellName, "_TUT_")
        or string.find(spellName, "_UND_") or string.find(spellName, "_SCL_") or string.find(spellName, "_HAG_")
        or string.find(spellName, "_GOB_") or string.find(spellName, "_CRE_") or string.find(spellName, "_SHA_") then
        return true
    end
    return false
end

local function HasFlag(flagList, targetFlag)
    if flagList == nil then
        return false
    end
    for _, flag in ipairs(flagList) do
        if flag == targetFlag then
            return true
        end
    end
    return false
end

local function IsEligibleWarCasterSpell(spellName, stat)
    if stat == nil or stat.ModifierList ~= "SpellData" then
        return false
    end
    if IsNpcOrIgnoredSpell(spellName) then
        return false
    end

    local spellType = stat.SpellType or ""
    if spellType ~= "Target" and spellType ~= "Projectile" then
        return false
    end

    if not HasFlag(stat.SpellFlags, "IsSpell") then
        return false
    end

    local intProto = stat.InterruptPrototype or ""
    if intProto ~= "" then
        return false
    end

    local useCosts = stat.UseCosts or ""
    if not string.find(useCosts, "ActionPoint:1") then
        return false
    end

    local cooldown = stat.Cooldown or ""
    if cooldown ~= "" and cooldown ~= "None" then
        return false
    end

    local level = stat.Level or 0
    local usesSpellSlot = string.find(useCosts, "SpellSlots?G?r?o?u?p?:") ~= nil
    if level ~= 0 and not usesSpellSlot then
        return false
    end

    local targetCond = stat.TargetConditions or ""
    if targetCond == "" or targetCond == "Self()" or not string.find(targetCond, "Character%(%)") then
        return false
    end

    -- Exclude out-of-combat social cantrips/spells like Friends (which require 'not Combat()')
    if string.find(targetCond, "not%s+Combat%(%)") then
        return false
    end

    -- Require an attack roll/saving throw (e.g. Hold Person, Booming Blade, Ray of Sickness)
    -- or direct damage intent (e.g. Magic Missile) so harmless utility/social spells are excluded
    local spellRoll = stat.SpellRoll or ""
    local intent = stat.VerbalIntent or ""
    local hasRollOrSave = spellRoll ~= ""
    local isDamageSpell = (intent == "Damage")

    if not hasRollOrSave and not isDamageSpell then
        return false
    end

    local isHostile = isDamageSpell or (intent == "Debuff") or (intent == "Control") or HasFlag(stat.SpellFlags, "IsHarmful")
    if not isHostile then
        return false
    end

    -- Skip sub-spells or container root spells that cannot be cast directly
    if HasFlag(stat.SpellFlags, "IsLinkedSpellContainer") then
        return false
    end

    return true
end

local function BuildInterruptCostFromSpell(useCosts)
    local parts = { "ReactionActionPoint:1" }
    for token in string.gmatch(useCosts or "", "[^;]+") do
        if not string.find(token, "^ActionPoint:") and not string.find(token, "^BonusActionPoint:") then
            table.insert(parts, token)
        end
    end
    return table.concat(parts, ";")
end

local function GetSpellSlotTier(useCosts)
    local slotStr = string.match(useCosts or "", "[%w_]*SpellSlots?G?r?o?u?p?:%d+:%d+:(%d+)")
    return tonumber(slotStr) or 0
end

local function SetInterruptUseSpell(newInt, baseInt, spellName)
    local templateInt = Ext.Stats.Get("Interrupt_WarCaster") or baseInt
    if templateInt ~= nil and templateInt.Properties ~= nil then
        local exported = Ext.DumpExport(templateInt.Properties)
        if exported ~= nil and exported[1] ~= nil and exported[1].Functors ~= nil then
            for _, functor in ipairs(exported[1].Functors) do
                if functor.TypeId == "UseSpell" then
                    functor.SpellId = spellName
                end
            end
            newInt.Properties = exported
            return
        end
    end

    if newInt.Properties ~= nil then
        for _, group in ipairs(newInt.Properties) do
            if group.Functors ~= nil then
                for _, functor in ipairs(group.Functors) do
                    if functor.TypeId == "UseSpell" then
                        functor.SpellId = spellName
                    end
                end
            end
        end
    end
end

local function MergeInterruptContexts(ctxA, ctxB)
    local seen = {}
    local merged = {}
    for _, list in ipairs({ ctxA, ctxB }) do
        if type(list) == "table" then
            for _, token in ipairs(list) do
                if not seen[token] then
                    seen[token] = true
                    table.insert(merged, token)
                end
            end
        elseif type(list) == "string" and list ~= "" then
            for token in string.gmatch(list, "[^;]+") do
                if not seen[token] then
                    seen[token] = true
                    table.insert(merged, token)
                end
            end
        end
    end
    return merged
end

local function CleanKhonCondition(cond)
    if cond == nil then
        return ""
    end
    local trimmed = string.gsub(cond, ";+%s*$", "")
    trimmed = string.gsub(trimmed, "^%s+", "")
    trimmed = string.gsub(trimmed, "%s+$", "")
    return trimmed
end

local function BuildCombinedConditions(stdCond, pmCond, spellStat, isPM)
    local cleanStd = CleanKhonCondition(stdCond)
    local cleanPm = CleanKhonCondition(pmCond)
    local cleanTarget = CleanKhonCondition(spellStat.TargetConditions)

    local triggerCond = cleanStd
    if isPM and cleanPm ~= "" then
        if triggerCond ~= "" then
            triggerCond = string.format("((%s) or (%s))", triggerCond, cleanPm)
        else
            triggerCond = cleanPm
        end
    end

    local featCond = isPM
        and "HasPassive('WarCaster_OpportunitySpell', context.Observer) and HasPassive('PolearmMaster_AttackOfOpportunity', context.Observer)"
        or "HasPassive('WarCaster_OpportunitySpell', context.Observer)"

    local spellBlockCond = "not HasSpellCastBlocked(context.Observer)"
    if HasFlag(spellStat.SpellFlags, "HasVerbalComponent") then
        spellBlockCond = spellBlockCond .. " and not HasStatus('SG_Silenced', context.Observer)"
    end

    -- Restrict touch/melee spells (1.5m) to standard melee range even when wielding a 10ft (3m) reach weapon
    local targetRadius = tostring(spellStat.TargetRadius or "")
    local rangeGuard = ""
    if targetRadius == "1.5" then
        rangeGuard = " and DistanceToTarget() <= 2.0"
    end

    local guardCond = string.format(
        "not Self(context.Observer, context.Target) and Enemy() and (%s) and (%s)%s",
        spellBlockCond,
        featCond,
        rangeGuard
    )

    local combined = guardCond
    if triggerCond ~= "" then
        combined = string.format("(%s) and (%s)", triggerCond, guardCond)
    end

    if cleanTarget ~= "" then
        return string.format("(%s) and (%s)", combined, cleanTarget)
    end
    return combined
end

local function CreateWarCasterInterruptVariant(newIntName, stdInt, pmInt, spellName, spellStat, isPM)
    local baseInt = (isPM and pmInt ~= nil) and pmInt or stdInt
    if baseInt == nil then
        return false
    end

    local newInt = Ext.Stats.Get(newIntName) or Ext.Stats.Create(newIntName, "InterruptData", baseInt.Name)
    if newInt == nil then
        return false
    end

    newInt.DisplayName = spellStat.DisplayName
    newInt.Description = spellStat.Description
    newInt.Icon = spellStat.Icon
    newInt.Cost = BuildInterruptCostFromSpell(spellStat.UseCosts)

    if isPM and pmInt ~= nil and stdInt ~= nil then
        newInt.InterruptContext = MergeInterruptContexts(stdInt.InterruptContext, pmInt.InterruptContext)
        newInt.Conditions = BuildCombinedConditions(stdInt.Conditions, pmInt.Conditions, spellStat, true)
    else
        newInt.Conditions = BuildCombinedConditions(stdInt.Conditions, nil, spellStat, false)
    end

    SetInterruptUseSpell(newInt, baseInt, spellName)
    newInt:Sync()

    return true
end

local function GenerateWarCasterReactions()
    SpellToWCInterrupts = {}
    local allSpells = Ext.Stats.GetStats("SpellData") or {}
    local stdInt = Ext.Stats.Get("Interrupt_AttackOfOpportunity")
    local pmInt = Ext.Stats.Get("Interrupt_PolearmMaster")
    local createdCount = 0

    for _, spellName in ipairs(allSpells) do
        local stat = Ext.Stats.Get(spellName)
        if IsEligibleWarCasterSpell(spellName, stat) then
            local slotTier = GetSpellSlotTier(stat.UseCosts)
            local stdIntName = "KJ_WC_Interrupt_" .. spellName

            if CreateWarCasterInterruptVariant(stdIntName, stdInt, nil, spellName, stat, false) then
                SpellToWCInterrupts[spellName] = SpellToWCInterrupts[spellName] or {}
                table.insert(SpellToWCInterrupts[spellName], {
                    interrupt = stdIntName,
                    level = slotTier,
                    isPM = false,
                })
                createdCount = createdCount + 1
            end

            if pmInt ~= nil then
                local pmIntName = "KJ_WC_PM_Interrupt_" .. spellName
                if CreateWarCasterInterruptVariant(pmIntName, stdInt, pmInt, spellName, stat, true) then
                    SpellToWCInterrupts[spellName] = SpellToWCInterrupts[spellName] or {}
                    table.insert(SpellToWCInterrupts[spellName], {
                        interrupt = pmIntName,
                        level = slotTier,
                        isPM = true,
                    })
                    createdCount = createdCount + 1
                end
            end
        end
    end

    _P("[KJ_WarCaster] Generated " .. tostring(createdCount) .. " War Caster opportunity attack reaction(s).")
end

local function EnsureWarCasterReactionsPrepared()
    if next(SpellToWCInterrupts) == nil then
        GenerateWarCasterReactions()
    end
end

Ext.Events.StatsLoaded:Subscribe(function()
    GenerateWarCasterReactions()
end)

if Ext.IsClient() then
    syncChannel:SetHandler(function(data)
        local updates = Ext.Json.Parse(data)
        for passiveName, boosts in pairs(updates) do
            local pStat = Ext.Stats.Get(passiveName)
            if pStat ~= nil then
                pStat.Boosts = boosts
                pStat:Sync()
            end
        end
    end)

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            EnsureWarCasterReactionsPrepared()
            Ext.Timer.WaitFor(500, function()
                requestChannel:SendToServer("")
            end)
        end
    end)
end

if Ext.IsServer() then
    local CharacterSlotMap = {}
    local CharacterActivePassives = {}
    local PendingRebuilds = {}

    local function NormalizeUuid(guid)
        if guid ~= nil and math.floor(#guid / 36) ~= 0 then
            return string.sub(guid, -36)
        end
        return guid
    end

    local function GetSpellChildrenMap()
        if CachedChildrenMap ~= nil then
            return CachedChildrenMap
        end
        CachedChildrenMap = {}
        for _, spellName in ipairs(Ext.Stats.GetStats("SpellData") or {}) do
            if not IsNpcOrIgnoredSpell(spellName) then
                local stat = Ext.Stats.Get(spellName)
                if stat ~= nil and stat.Using ~= nil and stat.Using ~= "" then
                    CachedChildrenMap[stat.Using] = CachedChildrenMap[stat.Using] or {}
                    table.insert(CachedChildrenMap[stat.Using], spellName)
                end
            end
        end
        return CachedChildrenMap
    end

    local function CollectSpellFamily(rootSpell, childrenMap, collected)
        if collected[rootSpell] or IsNpcOrIgnoredSpell(rootSpell) then
            return
        end
        collected[rootSpell] = true
        local children = childrenMap[rootSpell]
        if children ~= nil then
            for _, childName in ipairs(children) do
                CollectSpellFamily(childName, childrenMap, collected)
            end
        end
    end

    local function GetMaxAvailableSpellTier(uuid)
        local lvl = uuid ~= nil and Osi.GetLevel(uuid) or 1
        if lvl == 0 then
            return 1
        end
        local maxTier = math.ceil(lvl / 2)
        if math.floor(maxTier / 7) ~= 0 then
            return 6
        end
        return maxTier
    end

    local function RemoveAllCharPassives(uuid)
        for charIdx = 1, MAX_CHAR_SLOTS do
            for slot = 1, SLOTS_PER_CHAR do
                local pName = GetCharPassiveName(charIdx, slot)
                if Osi.HasPassive(uuid, pName) == 1 then
                    Osi.RemovePassive(uuid, pName)
                end
            end
        end
    end

    local function ClearCharSlotPassives(charIdx, payload)
        for slot = 1, SLOTS_PER_CHAR do
            local pName = GetCharPassiveName(charIdx, slot)
            local pStat = Ext.Stats.Get(pName)
            if pStat ~= nil then
                pStat.Boosts = ""
                payload[pName] = ""
            end
        end
    end

    local function GetOrAssignCharSlot(uuid)
        if CharacterSlotMap[uuid] ~= nil then
            return CharacterSlotMap[uuid]
        end
        local used = {}
        for _, idx in pairs(CharacterSlotMap) do
            used[idx] = true
        end
        for idx = 1, MAX_CHAR_SLOTS do
            if not used[idx] then
                CharacterSlotMap[uuid] = idx
                return idx
            end
        end
        return nil
    end

    local function ApplyCharacterPassives(uuid)
        local cleanUuid = NormalizeUuid(uuid)
        for _, pName in ipairs(CharacterActivePassives[cleanUuid] or {}) do
            if Osi.HasPassive(cleanUuid, pName) == 0 then
                Osi.AddPassive(cleanUuid, pName)
            end
        end
    end

    local function CompileCharacterWarCaster(entity, uuid, childrenMap, payload)
        RemoveAllCharPassives(uuid)

        if Osi.HasPassive(uuid, WAR_CASTER_PASSIVE) == 0 then
            local oldSlot = CharacterSlotMap[uuid]
            if oldSlot ~= nil then
                ClearCharSlotPassives(oldSlot, payload)
                CharacterSlotMap[uuid] = nil
            end
            CharacterActivePassives[uuid] = nil
            return
        end

        local charIdx = GetOrAssignCharSlot(uuid)
        if charIdx == nil then
            return
        end

        ClearCharSlotPassives(charIdx, payload)
        CharacterActivePassives[uuid] = {}

        local knownSpells = {}
        if entity.SpellBookPrepares ~= nil and entity.SpellBookPrepares.PreparedSpells ~= nil then
            for _, entry in ipairs(entity.SpellBookPrepares.PreparedSpells) do
                local proto = entry.OriginatorPrototype
                local src = entry.ProgressionSource ~= nil and tostring(entry.ProgressionSource) or ""
                local srcType = tostring(entry.SourceType or "")
                if proto ~= nil and proto ~= ""
                    and src ~= "" and src ~= "00000000-0000-0000-0000-000000000000"
                    and srcType ~= "Boost" and srcType ~= "WeaponSpell" then
                    knownSpells[proto] = true
                end
            end
        elseif entity.SpellBook ~= nil and entity.SpellBook.Spells ~= nil then
            for _, entry in ipairs(entity.SpellBook.Spells) do
                local id = entry.Id
                if id ~= nil and id.Prototype ~= nil and id.Prototype ~= "" then
                    local src = id.ProgressionSource ~= nil and tostring(id.ProgressionSource) or ""
                    if src ~= "" and src ~= "00000000-0000-0000-0000-000000000000" then
                        knownSpells[id.Prototype] = true
                    end
                end
            end
        end

        local maxTier = GetMaxAvailableSpellTier(uuid)
        local hasPM = (Osi.HasPassive(uuid, "PolearmMaster_AttackOfOpportunity") == 1)
            or (Osi.HasPassive(uuid, "PolearmMaster") == 1)
        local boostsList = {}
        local seenInts = {}

        for spellName, _ in pairs(knownSpells) do
            local wcList = SpellToWCInterrupts[spellName]
            if wcList ~= nil then
                for _, info in ipairs(wcList) do
                    local tierAllowed = (info.level == 0) or (maxTier ~= 0 and math.floor(maxTier / info.level) ~= 0)
                    local featAllowed = (hasPM and info.isPM) or ((not hasPM) and (not info.isPM))
                    if not seenInts[info.interrupt] and tierAllowed and featAllowed then
                        seenInts[info.interrupt] = true
                        table.insert(boostsList, string.format("UnlockInterrupt(%s)", info.interrupt))
                    end
                end
            end
        end

        local slotIdx = 1
        local currentChunk = ""

        local function FlushChunk(chunk)
            if chunk == "" or slotIdx == SLOTS_PER_CHAR + 1 then
                return
            end
            local pName = GetCharPassiveName(charIdx, slotIdx)
            local pStat = Ext.Stats.Get(pName)
            if pStat ~= nil then
                pStat.Boosts = chunk
                pStat:Sync()
                payload[pName] = chunk
                table.insert(CharacterActivePassives[uuid], pName)
            end
            slotIdx = slotIdx + 1
        end

        for _, boost in ipairs(boostsList) do
            local candidate = currentChunk == "" and boost or (currentChunk .. ";" .. boost)
            if math.floor(#candidate / 1600) ~= 0 then
                FlushChunk(currentChunk)
                currentChunk = boost
            else
                currentChunk = candidate
            end
        end

        FlushChunk(currentChunk)
    end

    local function RebuildSingleCharacter(characterGuid)
        local uuid = NormalizeUuid(characterGuid)
        if uuid == nil then
            return
        end
        local entity = Ext.Entity.Get(uuid)
        if entity == nil then
            return
        end

        EnsureWarCasterReactionsPrepared()
        local childrenMap = GetSpellChildrenMap()
        local payload = {}

        CompileCharacterWarCaster(entity, uuid, childrenMap, payload)

        if next(payload) ~= nil then
            syncChannel:Broadcast(Ext.Json.Stringify(payload))
        end

        Ext.Timer.WaitFor(100, function()
            ApplyCharacterPassives(uuid)
        end)
    end

    local function RebuildAllCharacters()
        EnsureWarCasterReactionsPrepared()
        local childrenMap = GetSpellChildrenMap()
        local payload = {}

        CharacterSlotMap = {}
        CharacterActivePassives = {}

        for charIdx = 1, MAX_CHAR_SLOTS do
            ClearCharSlotPassives(charIdx, payload)
        end

        local seen = {}
        local rows = {}
        for _, r in ipairs(Osi.DB_PartOfTheTeam:Get(nil) or {}) do
            table.insert(rows, r)
        end
        for _, r in ipairs(Osi.DB_InCamp:Get(nil) or {}) do
            table.insert(rows, r)
        end

        local count = 0
        for _, row in ipairs(rows) do
            local rawGuid = table.unpack(row)
            local uuid = NormalizeUuid(rawGuid)
            if uuid ~= nil and not seen[uuid] then
                seen[uuid] = true
                local entity = Ext.Entity.Get(uuid)
                if entity ~= nil then
                    CompileCharacterWarCaster(entity, uuid, childrenMap, payload)
                    if CharacterSlotMap[uuid] ~= nil then
                        count = count + 1
                    end
                end
            end
        end

        syncChannel:Broadcast(Ext.Json.Stringify(payload))

        Ext.Timer.WaitFor(100, function()
            for uuid, _ in pairs(CharacterSlotMap) do
                ApplyCharacterPassives(uuid)
            end
        end)

        _P("[KJ_WarCaster] Initialized War Caster reactions for " .. tostring(count) .. " character(s).")
    end

    function KJ_RebuildWarCaster()
        RebuildAllCharacters()
    end

    requestChannel:SetHandler(function()
        RebuildAllCharacters()
    end)

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            RebuildAllCharacters()
        end
    end)

    Ext.Events.SessionLoaded:Subscribe(function()
        local function DelayedRebuild(character)
            local uuid = NormalizeUuid(character)
            if uuid == nil then
                return
            end

            local token = (PendingRebuilds[uuid] or 0) + 1
            PendingRebuilds[uuid] = token

            Ext.Timer.WaitFor(500, function()
                if PendingRebuilds[uuid] == token then
                    PendingRebuilds[uuid] = nil
                    RebuildSingleCharacter(uuid)
                end
            end)
        end

        Ext.Entity.OnChange("SpellBookPrepares", function(entity)
            if entity ~= nil and entity.Uuid ~= nil and entity.Uuid.EntityUuid ~= nil then
                DelayedRebuild(entity.Uuid.EntityUuid)
            end
        end)

        Ext.Entity.OnChange("SpellBook", function(entity)
            if entity ~= nil and entity.Uuid ~= nil and entity.Uuid.EntityUuid ~= nil then
                DelayedRebuild(entity.Uuid.EntityUuid)
            end
        end)

        Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(character)
            DelayedRebuild(character)
        end)

        Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(character)
            DelayedRebuild(character)
        end)

		Ext.Osiris.RegisterListener("UserConnected", 3, "after", function()
			Ext.Timer.WaitFor(500, function()
				RebuildAllCharacters()
			end)
		end)
	end)
end