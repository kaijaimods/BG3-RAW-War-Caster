local MAX_CHAR_SLOTS = 16
local SLOTS_PER_CHAR = 12
local WAR_CASTER_PASSIVE = "WarCaster_OpportunitySpell"

local syncChannel = Ext.Net.CreateChannel(ModuleUUID, "KJ_WarCaster_SyncPools")
local requestChannel = Ext.Net.CreateChannel(ModuleUUID, "KJ_WarCaster_RequestSync")

local EligibleSpellTiers = {}

local ABILITY_SHORT = {
    Intelligence = "INT",
    Wisdom = "WIS",
    Charisma = "CHA",
}

local function GetCharPassiveName(charIndex, slotIndex)
    return string.format("KJ_WarCaster_Char%d_%d", charIndex, slotIndex)
end

local function GetCharSpellInterruptName(charIndex, spellName)
    return string.format("KJ_WC_Char%d_Interrupt_%s", charIndex, spellName)
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

local function GetTrueRootSpell(spellName)
    local current = spellName
    local visited = {}
    while current ~= nil and current ~= "" and not visited[current] do
        visited[current] = true
        local stat = Ext.Stats.Get(current)
        if stat == nil then
            break
        end
        if stat.RootSpellID ~= nil and stat.RootSpellID ~= "" and stat.RootSpellID ~= current then
            current = stat.RootSpellID
        else
            break
        end
    end
    return current
end

local function IsEligibleWarCasterSpell(spellName, stat)
    if stat == nil or stat.ModifierList ~= "SpellData" then
        return false
    end

    local areaRadius = tonumber(stat.AreaRadius or 0) or 0
    local aoeCond = stat.AoEConditions or ""
    if areaRadius > 0 and aoeCond ~= "false" then
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
    if targetCond == "" or targetCond == "Self()" or string.find(targetCond, "Ground%(%)") then
        return false
    end

    if string.find(targetCond, "not%s+Combat%(%)") then
        return false
    end

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

local function BuildUnifiedConditions(stdCond, pmCond, spellStat)
    local cleanStd = CleanKhonCondition(stdCond)
    local cleanPm = CleanKhonCondition(pmCond)
    local cleanTarget = CleanKhonCondition(spellStat.TargetConditions)

    local triggerCond = cleanStd
    if cleanPm ~= "" then
        local pmBranch = string.format("((%s) and HasPassive('PolearmMaster_AttackOfOpportunity', context.Observer))", cleanPm)
        if triggerCond ~= "" then
            triggerCond = string.format("((%s) or %s)", triggerCond, pmBranch)
        else
            triggerCond = pmBranch
        end
    end

    local spellBlockCond = "not HasSpellCastBlocked(context.Observer)"
    if HasFlag(spellStat.SpellFlags, "HasVerbalComponent") then
        spellBlockCond = spellBlockCond .. " and not HasStatus('SG_Silenced', context.Observer)"
    end

    local targetRadius = tostring(spellStat.TargetRadius or "")
    local rangeGuard = ""
    if targetRadius == "1.5" then
        rangeGuard = " and DistanceToTarget() <= 2.0"
    end

    local guardCond = string.format(
        "not Self(context.Observer, context.Target) and Enemy() and (%s) and HasPassive('WarCaster_OpportunitySpell', context.Observer)%s",
        spellBlockCond,
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

local function GetOrCreateAbilitySpell(spellName, abilityStatName)
    local shortKey = ABILITY_SHORT[abilityStatName]
    if shortKey == nil then
        return spellName
    end

    local newSpellName = string.format("KJ_WC_Spell_%s_%s", shortKey, spellName)
    local newSpell = Ext.Stats.Get(newSpellName) or Ext.Stats.Create(newSpellName, "SpellData", spellName)
    if newSpell == nil then
        return spellName
    end

    local ok = pcall(function()
        newSpell.SpellCastingAbility = abilityStatName
    end)
    if ok then
        newSpell:Sync()
        return newSpellName
    end
    return spellName
end

local function BuildLiveAbilityCondition(ability, abilitySet)
    local checks = {}
    if ability == "Intelligence" then
        if abilitySet.Wisdom then
            table.insert(checks, "context.Source.Intelligence >= context.Source.Wisdom")
        end
        if abilitySet.Charisma then
            table.insert(checks, "context.Source.Intelligence >= context.Source.Charisma")
        end
    elseif ability == "Wisdom" then
        if abilitySet.Intelligence then
            table.insert(checks, "context.Source.Wisdom > context.Source.Intelligence")
        end
        if abilitySet.Charisma then
            table.insert(checks, "context.Source.Wisdom >= context.Source.Charisma")
        end
    elseif ability == "Charisma" then
        if abilitySet.Intelligence then
            table.insert(checks, "context.Source.Charisma > context.Source.Intelligence")
        end
        if abilitySet.Wisdom then
            table.insert(checks, "context.Source.Charisma > context.Source.Wisdom")
        end
    end
    return table.concat(checks, " and ")
end

local function SetDynamicAbilityUseSpells(newInt, baseInt, spellName, abilitiesList)
    local templateInt = Ext.Stats.Get("Interrupt_WarCaster") or baseInt
    if templateInt == nil or templateInt.Properties == nil then
        return
    end

    local baseExport = Ext.DumpExport(templateInt.Properties)
    if baseExport == nil or baseExport[1] == nil or baseExport[1].Functors == nil or #baseExport[1].Functors == 0 then
        return
    end

    local abilitySet = {}
    for _, ab in ipairs(abilitiesList) do
        abilitySet[ab] = true
    end

    local newFunctors = {}
    for _, ab in ipairs(abilitiesList) do
        local clonedExport = Ext.Json.Parse(Ext.Json.Stringify(baseExport))
        local targetSpell = GetOrCreateAbilitySpell(spellName, ab)
        local condStr = BuildLiveAbilityCondition(ab, abilitySet)

        for _, functor in ipairs(clonedExport[1].Functors) do
            if functor.TypeId == "UseSpell" then
                functor.SpellId = targetSpell
                if condStr ~= "" then
                    functor.Condition = condStr
                end
            end
            table.insert(newFunctors, functor)
        end
    end

    baseExport[1].Functors = newFunctors
    newInt.Properties = baseExport
end

local function CreateOrUpdateCharSpellInterrupt(newIntName, spellName, abilitiesList)
    local spellStat = Ext.Stats.Get(spellName)
    local stdInt = Ext.Stats.Get("Interrupt_AttackOfOpportunity")
    local pmInt = Ext.Stats.Get("Interrupt_PolearmMaster")
    if spellStat == nil or stdInt == nil then
        return false
    end

    local newInt = Ext.Stats.Get(newIntName) or Ext.Stats.Create(newIntName, "InterruptData", stdInt.Name)
    if newInt == nil then
        return false
    end

    newInt.DisplayName = spellStat.DisplayName
    newInt.Description = spellStat.Description
    newInt.Icon = spellStat.Icon
    newInt.Cost = BuildInterruptCostFromSpell(spellStat.UseCosts)

    if pmInt ~= nil then
        newInt.InterruptContext = MergeInterruptContexts(stdInt.InterruptContext, pmInt.InterruptContext)
        newInt.Conditions = BuildUnifiedConditions(stdInt.Conditions, pmInt.Conditions, spellStat)
    else
        newInt.Conditions = BuildUnifiedConditions(stdInt.Conditions, nil, spellStat)
    end

    SetDynamicAbilityUseSpells(newInt, stdInt, spellName, abilitiesList)
    newInt:Sync()
    return true
end

local function ScanEligibleWarCasterSpells()
    EligibleSpellTiers = {}
    local allSpells = Ext.Stats.GetStats("SpellData") or {}
    local count = 0

    for _, spellName in ipairs(allSpells) do
        local stat = Ext.Stats.Get(spellName)
        if IsEligibleWarCasterSpell(spellName, stat) then
            EligibleSpellTiers[spellName] = GetSpellSlotTier(stat.UseCosts)
            count = count + 1
        end
    end

    _P("[KJ_WarCaster] Indexed " .. tostring(count) .. " eligible War Caster spell(s).")
end

local function EnsureWarCasterSpellsScanned()
    if next(EligibleSpellTiers) == nil then
        ScanEligibleWarCasterSpells()
    end
end

Ext.Events.StatsLoaded:Subscribe(function()
    ScanEligibleWarCasterSpells()
end)

if Ext.IsClient() then
    syncChannel:SetHandler(function(data)
        local packet = Ext.Json.Parse(data)
        for _, spec in ipairs(packet.interrupts or {}) do
            CreateOrUpdateCharSpellInterrupt(spec.name, spec.spell, spec.abilities)
        end
        for passiveName, boosts in pairs(packet.passives or {}) do
            local pStat = Ext.Stats.Get(passiveName)
            if pStat ~= nil then
                pStat.Boosts = boosts
                pStat:Sync()
            end
        end
    end)

    Ext.Events.GameStateChanged:Subscribe(function(e)
        if e.ToState == "Running" then
            EnsureWarCasterSpellsScanned()
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
                payload.passives[pName] = ""
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

    local CLASS_DEFAULT_ABILITY = {
        ["a865965f-501b-46e9-9eaa-7748e8c04d09"] = "Intelligence", -- Wizard
        ["114e7aee-d1d4-4371-8d90-8a2080592faf"] = "Wisdom",       -- Cleric
        ["457d0a6e-9da8-4f95-a225-18382f0e94b5"] = "Wisdom",       -- Druid
        ["36be18ba-23db-4dff-bfa6-10ae9ce3bdf5"] = "Wisdom",       -- Ranger
        ["784001e2-c96d-4153-beb6-2adbef5abc92"] = "Charisma",     -- Sorcerer
        ["b4225a4b-4bbe-4d97-9e3c-4719dbd1487c"] = "Charisma",     -- Warlock
        ["92cd50b6-eb1b-4824-8adb-853e90c34c90"] = "Charisma",     -- Bard
        ["ff4d9497-023c-434a-bd14-82fc367e991c"] = "Charisma",     -- Paladin
    }

    local function GetCharacterClassAbilities(entity)
        local classAbilities = {}
        if entity ~= nil and entity.Classes ~= nil and entity.Classes.Classes ~= nil then
            for _, cls in ipairs(entity.Classes.Classes) do
                local classUuid = tostring(cls.ClassUUID or "")
                local mapped = CLASS_DEFAULT_ABILITY[classUuid]
                if mapped ~= nil then
                    classAbilities[mapped] = true
                end
            end
        end
        return classAbilities
    end

    local function BuildSpellToSourceAbilitiesMap(entity)
        local abilityMap = {}
        local fallbackClassAbilities = GetCharacterClassAbilities(entity)

        local function RecordAbility(spellName, rawAbility)
            if spellName == nil or spellName == "" then
                return
            end
            local ab = tostring(rawAbility or "")
            abilityMap[spellName] = abilityMap[spellName] or {}

            if ABILITY_SHORT[ab] ~= nil then
                abilityMap[spellName][ab] = true
            else
                for classAb, _ in pairs(fallbackClassAbilities) do
                    abilityMap[spellName][classAb] = true
                end
            end

            local rootId = GetTrueRootSpell(spellName)
            if rootId ~= "" and rootId ~= spellName then
                abilityMap[rootId] = abilityMap[rootId] or {}
                for k, _ in pairs(abilityMap[spellName]) do
                    abilityMap[rootId][k] = true
                end
            end
        end

        if entity.SpellBook ~= nil and entity.SpellBook.Spells ~= nil then
            for _, entry in ipairs(entity.SpellBook.Spells) do
                local id = entry.Id
                if id ~= nil and id.Prototype ~= nil and id.Prototype ~= "" then
                    local ok, rawAb = pcall(function()
                        return entry.SpellCastingAbility
                    end)
                    RecordAbility(id.Prototype, ok and rawAb or "")
                end
            end
        end

        return abilityMap
    end

    local function GetOrderedAbilitiesForSpell(spellName, abilityMap)
        local rootId = GetTrueRootSpell(spellName)
        local set = abilityMap[spellName] or (rootId ~= "" and abilityMap[rootId]) or nil
        local ordered = {}

        if set ~= nil then
            for _, ab in ipairs({ "Intelligence", "Wisdom", "Charisma" }) do
                if set[ab] then
                    table.insert(ordered, ab)
                end
            end
        end

        if #ordered == 0 then
            return { "Charisma" }
        end
        return ordered
    end

    local function CompileCharacterWarCaster(entity, uuid, payload)
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

        local abilityMap = BuildSpellToSourceAbilitiesMap(entity)

        -- Expand linked spell containers (e.g. Chromatic Orb -> Acid, Cold, Fire, Lightning, Poison, Thunder)
        local containerChildren = {}
        for spellName, _ in pairs(knownSpells) do
            local sStat = Ext.Stats.Get(spellName)
            if sStat ~= nil and sStat.ModifierList == "SpellData" then
                local cSpells = sStat.ContainerSpells or ""
                if cSpells ~= "" then
                    for subSpell in string.gmatch(cSpells, "[^;]+") do
                        containerChildren[subSpell] = true
                        if abilityMap[spellName] ~= nil then
                            abilityMap[subSpell] = abilityMap[subSpell] or {}
                            for ab, _ in pairs(abilityMap[spellName]) do
                                abilityMap[subSpell][ab] = true
                            end
                        end
                    end
                end
            end
        end
        for subSpell, _ in pairs(containerChildren) do
            knownSpells[subSpell] = true
        end

        -- Include only leveled upcast variants (slotTier > 0) whose RootSpellID is in knownSpells
        for _, spellName in ipairs(Ext.Stats.GetStats("SpellData") or {}) do
            if not IsNpcOrIgnoredSpell(spellName) then
                local sStat = Ext.Stats.Get(spellName)
                if sStat ~= nil and sStat.ModifierList == "SpellData" then
                    local slotTier = GetSpellSlotTier(sStat.UseCosts)
                    if slotTier > 0 then
                        local rootId = GetTrueRootSpell(spellName)
                        if rootId ~= "" and rootId ~= spellName and knownSpells[rootId] then
                            knownSpells[spellName] = true
                        end
                    end
                end
            end
        end

        local maxTier = GetMaxAvailableSpellTier(uuid)
        local boostsList = {}
        local seenInts = {}

        local sortedSpells = {}
        for spellName, _ in pairs(knownSpells) do
            table.insert(sortedSpells, spellName)
        end
        table.sort(sortedSpells)

        for _, spellName in ipairs(sortedSpells) do
            local slotTier = EligibleSpellTiers[spellName]
            if slotTier ~= nil then
                local tierAllowed = (slotTier == 0) or (maxTier ~= 0 and math.floor(maxTier / slotTier) ~= 0)
                local intName = GetCharSpellInterruptName(charIdx, spellName)
                if tierAllowed and not seenInts[intName] then
                    local abilitiesList = GetOrderedAbilitiesForSpell(spellName, abilityMap)
                    if CreateOrUpdateCharSpellInterrupt(intName, spellName, abilitiesList) then
                        seenInts[intName] = true
                        table.insert(payload.interrupts, {
                            name = intName,
                            spell = spellName,
                            abilities = abilitiesList,
                        })
                        table.insert(boostsList, string.format("UnlockInterrupt(%s)", intName))
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
                payload.passives[pName] = chunk
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

        EnsureWarCasterSpellsScanned()
        local payload = { interrupts = {}, passives = {} }

        CompileCharacterWarCaster(entity, uuid, payload)

        if next(payload.passives) ~= nil or #payload.interrupts > 0 then
            syncChannel:Broadcast(Ext.Json.Stringify(payload))
        end

        Ext.Timer.WaitFor(100, function()
            ApplyCharacterPassives(uuid)
        end)
    end

    local function RebuildAllCharacters()
        EnsureWarCasterSpellsScanned()
        local payload = { interrupts = {}, passives = {} }

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
                    CompileCharacterWarCaster(entity, uuid, payload)
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