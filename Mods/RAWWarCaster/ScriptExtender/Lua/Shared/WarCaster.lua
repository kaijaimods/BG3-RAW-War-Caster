local MAX_CHAR_SLOTS = 16
local SLOTS_PER_CHAR = 12
local WAR_CASTER_PASSIVE = "WarCaster_OpportunitySpell"

local syncChannel = Ext.Net.CreateChannel(ModuleUUID, "KJ_WarCaster_SyncPools")
local requestChannel = Ext.Net.CreateChannel(ModuleUUID, "KJ_WarCaster_RequestSync")

local SpellToWCInterrupt = {}
local RootToUpcasts = {}

local CASTING_ABILITIES = {
    { key = "INT", statName = "Intelligence" },
    { key = "WIS", statName = "Wisdom" },
    { key = "CHA", statName = "Charisma" },
}

local ABILITY_SHORT = {}
for _, ab in ipairs(CASTING_ABILITIES) do
    ABILITY_SHORT[ab.statName] = ab.key
end

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

local function ChunkBoostsList(items, separator, maxLen)
    local chunks = {}
    local current = ""
    for _, item in ipairs(items) do
        local candidate = current == "" and item or (current .. separator .. item)
        if #candidate > maxLen then
            if current ~= "" then
                table.insert(chunks, current)
            end
            current = item
        else
            current = candidate
        end
    end
    if current ~= "" then
        table.insert(chunks, current)
    end
    return chunks
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

local function ResolveInheritedDisplayName(statName)
    local current = Ext.Stats.Get(statName)
    local visited = {}
    while current ~= nil do
        if current.Name ~= nil then
            if visited[current.Name] then
                break
            end
            visited[current.Name] = true
        end

        local rawHandle = current.DisplayName or ""
        if rawHandle ~= "" then
            local cleanHandle = string.gsub(rawHandle, ";%d+$", "")
            local translated = Ext.Loca.GetTranslatedString(cleanHandle)
            if translated ~= nil and translated ~= "" then
                return translated
            end
            if not string.match(cleanHandle, "^h[%x]+g[%x]+g[%x]+g[%x]+g[%x]+$") then
                return cleanHandle
            end
        end

        local parentName = current.Using
        if parentName ~= nil and parentName ~= "" then
            current = Ext.Stats.Get(parentName)
        else
            break
        end
    end
    return statName
end

local function IsEligibleWarCasterSpell(spellName, stat)
    if stat == nil or stat.ModifierList ~= "SpellData" or IsNpcOrIgnoredSpell(spellName) then
        return false
    end

    local areaRadius = tonumber(stat.AreaRadius or 0) or 0
    if areaRadius > 0 and (stat.AoEConditions or "") ~= "false" then
        return false
    end

    local spellType = stat.SpellType or ""
    if (spellType ~= "Target" and spellType ~= "Projectile") or not HasFlag(stat.SpellFlags, "IsSpell") then
        return false
    end

    if (stat.InterruptPrototype or "") ~= "" or HasFlag(stat.SpellFlags, "IsLinkedSpellContainer") then
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

    if (stat.Level or 0) ~= 0 and not string.find(useCosts, "SpellSlots?G?r?o?u?p?:") then
        return false
    end

    local targetCond = stat.TargetConditions or ""
    if targetCond == "" or targetCond == "Self()" or string.find(targetCond, "Ground%(%)") or string.find(targetCond, "not%s+Combat%(%)") then
        return false
    end

    local intent = stat.VerbalIntent or ""
    local isDamageSpell = (intent == "Damage")
    if (stat.SpellRoll or "") == "" and not isDamageSpell then
        return false
    end

    return isDamageSpell or (intent == "Debuff") or (intent == "Control") or HasFlag(stat.SpellFlags, "IsHarmful")
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
    return string.gsub(trimmed, "%s+$", "")
end

local SINGLE_ARG_KHON_FUNCS = {
    "Character", "Item", "Dead", "Player", "Party", "Summon",
    "Familiar", "Companion", "Follower", "Origin", "Avatar", "Boss",
    "Humanoid", "Undead", "Construct", "Beast", "Animal", "Dragon",
    "Elemental", "Fey", "Fiend", "Giant", "Monstrosity", "Ooze",
    "Plant", "Insect", "Aberration", "Celestial", "Shapechanger", "Spirit",
    "IsDowned", "IsCrowdControlled", "Incapacitated", "Unconscious",
    "Prone", "Blinded", "Charmed", "Frightened", "Paralyzed",
    "Petrified", "Poisoned", "Restrained", "Stunned", "Silenced",
    "Banished", "Surprised", "Invisible", "Hidden", "Sneaking",
    "Concentration", "Concentrating",
    "Combat", "TurnBased", "Grounded", "Flying", "Falling",
    "Climbing", "Swimming", "Jumping", "InSunlight",
    "Obscured", "HeavilyObscured", "LightlyObscured",
}

local SPELLDATA_ONLY_FUNCS = {
    "CanUseWeaponActions", "CanUseSpellActions", "HasActionPoint",
    "HasBonusActionPoint", "HasReactionActionPoint", "IsWeaponAttack",
    "IsSpellAttack", "CanSee", "HasLineOfSight", "InRange",
    "HasSpell", "IsSpellPrepared",
}

local function ScrubSpellDataOnlyFunctions(condStr)
    local clean = CleanKhonCondition(condStr)
    if clean == "" then
        return ""
    end

    for _, fnName in ipairs(SPELLDATA_ONLY_FUNCS) do
        local callPat = "%f[%w_]" .. fnName .. "%b()"
        clean = string.gsub(clean, callPat .. "%s*and%s*", "")
        clean = string.gsub(clean, "%s*and%s*" .. callPat, "")
        clean = string.gsub(clean, "^%s*%(?%s*" .. callPat .. "%s*%)?%s*$", "")
    end

    return CleanKhonCondition(clean)
end

local function TranslateConditionContext(rawCond, entityCtx, selfCtx)
    local clean = ScrubSpellDataOnlyFunctions(rawCond)
    if clean == "" then
        return ""
    end

    clean = string.gsub(clean, "Self%(%)", selfCtx)
    for _, fnName in ipairs(SINGLE_ARG_KHON_FUNCS) do
        clean = string.gsub(clean, "(%f[%w_]" .. fnName .. ")%(%)", "%1(" .. entityCtx .. ")")
    end
    clean = string.gsub(clean, "(%f[%w_]Tagged)%(([^,)]+)%)", "%1(%2, " .. entityCtx .. ")")
    clean = string.gsub(clean, "(%f[%w_]HasStatus)%(([^,)]+)%)", "%1(%2, " .. entityCtx .. ")")

    return clean
end

local function BuildWarCasterConditions(stdCond, pmCond, spellStat, isPM)
    local cleanStd = CleanKhonCondition(stdCond)
    local cleanPm = CleanKhonCondition(pmCond)

    local triggerCond = cleanStd
    if isPM and cleanPm ~= "" then
        triggerCond = triggerCond ~= "" and string.format("((%s) or (%s))", triggerCond, cleanPm) or cleanPm
    end

    local featCond = isPM
        and "HasPassive('WarCaster_OpportunitySpell', context.Observer) and HasPassive('PolearmMaster_AttackOfOpportunity', context.Observer)"
        or "HasPassive('WarCaster_OpportunitySpell', context.Observer)"

    local spellBlockCond = "not HasSpellCastBlocked(context.Observer)"
    if HasFlag(spellStat.SpellFlags, "HasVerbalComponent") then
        spellBlockCond = spellBlockCond .. " and not HasStatus('SG_Silenced', context.Observer)"
    end

    local rangeGuard = tostring(spellStat.TargetRadius or "") == "1.5" and " and DistanceToTarget() <= 2.0" or ""

    local extraClauses = {}
    local translatedTarget = TranslateConditionContext(spellStat.TargetConditions, "context.Target", "Self(context.Observer, context.Target)")
    if translatedTarget ~= "" then
        table.insert(extraClauses, string.format("(%s)", translatedTarget))
    end

    local translatedReq = TranslateConditionContext(spellStat.RequirementConditions, "context.Observer", "Self(context.Observer, context.Observer)")
    if translatedReq ~= "" then
        table.insert(extraClauses, string.format("(%s)", translatedReq))
    end

    local extraStr = #extraClauses > 0 and (" and " .. table.concat(extraClauses, " and ")) or ""
    local guardCond = string.format("(%s) and (%s)%s%s", spellBlockCond, featCond, rangeGuard, extraStr)

    return triggerCond ~= "" and string.format("(%s) and (%s)", triggerCond, guardCond) or guardCond
end

local function GetSpellRollString(spellStat)
    local current = spellStat
    local visited = {}
    while current ~= nil do
        if current.Name ~= nil then
            if visited[current.Name] then
                break
            end
            visited[current.Name] = true
        end

        if current.SpellRoll ~= nil then
            local ok, defVal = pcall(function()
                return current.SpellRoll.Default
            end)
            if ok and type(defVal) == "string" and defVal ~= "" then
                return defVal
            end
            if type(current.SpellRoll) == "string" and current.SpellRoll ~= "" then
                return current.SpellRoll
            end
            local dumped = Ext.DumpExport(current.SpellRoll)
            if type(dumped) == "table" and type(dumped.Default) == "string" and dumped.Default ~= "" then
                return dumped.Default
            end
        end

        local parentName = current.Using
        if parentName ~= nil and parentName ~= "" then
            current = Ext.Stats.Get(parentName)
        else
            break
        end
    end
    return ""
end

local function GetOrCreateAbilitySpell(spellName, abilityStatName, rollStr)
    local shortKey = ABILITY_SHORT[abilityStatName]
    if shortKey == nil then
        return spellName
    end

    local newSpellName = string.format("KJ_WC_Spell_%s_%s", shortKey, spellName)
    local newSpell = Ext.Stats.Get(newSpellName) or Ext.Stats.Create(newSpellName, "SpellData", spellName)
    if newSpell == nil then
        return spellName
    end

    if rollStr ~= "" and string.find(rollStr, "SourceSpellDC%(%)") then
        local updatedRoll = string.gsub(rollStr, "SourceSpellDC%(%)", "SourceSpellDC(Ability." .. abilityStatName .. ")")
        newSpell:SetRawAttribute("SpellRoll", updatedRoll)
    end

    newSpell:Sync()
    return newSpellName
end

local function CreateWarCasterInterruptVariant(intName, baseTemplate, pmInt, spellName, spellStat, isPM, abilityStatName, rollStr)
    local newInt = Ext.Stats.Get(intName) or Ext.Stats.Create(intName, "InterruptData", baseTemplate.Name)
    if newInt == nil then
        return false
    end

    local targetSpell = GetOrCreateAbilitySpell(spellName, abilityStatName, rollStr)

    newInt.DisplayName = spellStat.DisplayName
    newInt.Description = spellStat.Description
    newInt.Icon = spellStat.Icon
    newInt.Cost = BuildInterruptCostFromSpell(spellStat.UseCosts)

    if isPM and pmInt ~= nil then
        newInt.InterruptContext = MergeInterruptContexts(baseTemplate.InterruptContext, pmInt.InterruptContext)
        newInt.Conditions = BuildWarCasterConditions(baseTemplate.Conditions, pmInt.Conditions, spellStat, true)
    else
        newInt.Conditions = BuildWarCasterConditions(baseTemplate.Conditions, nil, spellStat, false)
    end

    newInt:SetRawAttribute("Properties", string.format("TARGET,AOE:UseSpell(%s,true,true,true)", targetSpell))
    newInt:Sync()
    return true
end

local function GenerateWarCasterReactions()
    SpellToWCInterrupt = {}
    RootToUpcasts = {}

    local allSpells = Ext.Stats.GetStats("SpellData") or {}
    local wcInt = Ext.Stats.Get("Interrupt_WarCaster")
    local stdInt = Ext.Stats.Get("Interrupt_AttackOfOpportunity")
    local pmInt = Ext.Stats.Get("Interrupt_PolearmMaster")
    local baseTemplate = wcInt or stdInt
    if baseTemplate == nil then
        return
    end

    for _, spellName in ipairs(allSpells) do
        local spellStat = Ext.Stats.Get(spellName)
        if IsEligibleWarCasterSpell(spellName, spellStat) then
            local slotTier = GetSpellSlotTier(spellStat.UseCosts)
            if slotTier > 0 then
                local rootId = GetTrueRootSpell(spellName)
                if rootId ~= "" and rootId ~= spellName then
                    RootToUpcasts[rootId] = RootToUpcasts[rootId] or {}
                    table.insert(RootToUpcasts[rootId], spellName)
                end
            end

            local rollStr = GetSpellRollString(spellStat)
            local needsAbility = (rollStr ~= "" and string.find(rollStr, "SourceSpellDC%(%)") ~= nil)
            SpellToWCInterrupt[spellName] = {}

            local variants = needsAbility and CASTING_ABILITIES or { { key = "DEF", statName = "Default" } }

            for _, ab in ipairs(variants) do
                local stdName = (ab.key == "DEF")
                    and ("KJ_WC_Interrupt_" .. spellName)
                    or string.format("KJ_WC_%s_Interrupt_%s", ab.key, spellName)

                if CreateWarCasterInterruptVariant(stdName, baseTemplate, nil, spellName, spellStat, false, ab.statName, rollStr) then
                    table.insert(SpellToWCInterrupt[spellName], {
                        interrupt = stdName,
                        level = slotTier,
                        isPM = false,
                        ability = ab.statName,
                    })
                end

                if pmInt ~= nil then
                    local pmName = (ab.key == "DEF")
                        and ("KJ_WC_PM_Interrupt_" .. spellName)
                        or string.format("KJ_WC_%s_PM_Interrupt_%s", ab.key, spellName)

                    if CreateWarCasterInterruptVariant(pmName, baseTemplate, pmInt, spellName, spellStat, true, ab.statName, rollStr) then
                        table.insert(SpellToWCInterrupt[spellName], {
                            interrupt = pmName,
                            level = slotTier,
                            isPM = true,
                            ability = ab.statName,
                        })
                    end
                end
            end
        end
    end
end

local function EnsureWarCasterReactionsPrepared()
    if next(SpellToWCInterrupt) == nil then
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

    local ClientNeedsSync = true
	Ext.Events.GameStateChanged:Subscribe(function(e)
		if e.ToState == "LoadLevel" or e.ToState == "LoadSession" or e.ToState == "UnloadLevel" then
			ClientNeedsSync = true
		elseif e.ToState == "Running" and ClientNeedsSync then
			ClientNeedsSync = false
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

    local function GetMaxAvailableSpellTier(uuid)
        local lvl = uuid ~= nil and Osi.GetLevel(uuid) or 1
        if lvl == 0 then
            return 1
        end
        local maxTier = math.ceil(lvl / 2)
        return math.floor(maxTier / 7) ~= 0 and 6 or maxTier
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
				pStat:Sync()
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

    local function CharacterHasInterrupt(uuid, targetInterrupt)
        if targetInterrupt == nil or targetInterrupt == "" then
            return true
        end
        local ent = Ext.Entity.Get(uuid)
        if ent == nil or ent.InterruptContainer == nil or ent.InterruptContainer.Interrupts == nil then
            return false
        end
        for _, ie in ipairs(ent.InterruptContainer.Interrupts) do
            if ie ~= nil and ie.InterruptData ~= nil and ie.InterruptData.Interrupt == targetInterrupt then
                return true
            end
        end
        return false
    end

    local function GetLastInterruptInPassive(passiveName)
        local pStat = Ext.Stats.Get(passiveName)
        if pStat == nil or pStat.Boosts == nil or pStat.Boosts == "" then
            return nil
        end
        local lastInt = nil
        for intId in string.gmatch(pStat.Boosts, "UnlockInterrupt%(([^%)]+)%)") do
            lastInt = intId
        end
        return lastInt
    end

    local function ApplyPassivesSequentially(uuid, passiveList, index)
        if index > #passiveList then
            return
        end

        local pName = passiveList[index]
        local expectedLastInt = GetLastInterruptInPassive(pName)

        local removeAttempts = 0
        local function WaitForRemovalThenAdd()
            removeAttempts = removeAttempts + 1
            if Osi.HasPassive(uuid, pName) == 0 or removeAttempts >= 60 then
                Osi.AddPassive(uuid, pName)

                local applyAttempts = 0
                local function WaitUntilApplied()
                    applyAttempts = applyAttempts + 1
                    if (Osi.HasPassive(uuid, pName) == 1 and CharacterHasInterrupt(uuid, expectedLastInt)) or applyAttempts >= 120 then
                        ApplyPassivesSequentially(uuid, passiveList, index + 1)
                    else
                        Ext.Timer.WaitFor(1, WaitUntilApplied)
                    end
                end

                Ext.Timer.WaitFor(1, WaitUntilApplied)
            else
                Ext.Timer.WaitFor(1, WaitForRemovalThenAdd)
            end
        end

        WaitForRemovalThenAdd()
    end

    local function ApplyCharacterPassives(uuid)
        local cleanUuid = NormalizeUuid(uuid)
        ApplyPassivesSequentially(cleanUuid, CharacterActivePassives[cleanUuid] or {}, 1)
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

    local function GetCharacterAbilityScores(entity, uuid)
        local scores = { Intelligence = 10, Wisdom = 10, Charisma = 10 }
        if uuid ~= nil and Osi.GetAbility ~= nil then
            scores.Intelligence = tonumber(Osi.GetAbility(uuid, "Intelligence")) or 10
            scores.Wisdom = tonumber(Osi.GetAbility(uuid, "Wisdom")) or 10
            scores.Charisma = tonumber(Osi.GetAbility(uuid, "Charisma")) or 10
        elseif entity ~= nil and entity.Stats ~= nil and entity.Stats.Abilities ~= nil then
            scores.Intelligence = tonumber(entity.Stats.Abilities[5]) or 10
            scores.Wisdom = tonumber(entity.Stats.Abilities[6]) or 10
            scores.Charisma = tonumber(entity.Stats.Abilities[7]) or 10
        end
        return scores
    end

    local function GetBestSpellAbilityForCharacter(entity, uuid)
        local scores = GetCharacterAbilityScores(entity, uuid)
        local classAbilities = {}
        if entity ~= nil and entity.Classes ~= nil and entity.Classes.Classes ~= nil then
            for _, cls in ipairs(entity.Classes.Classes) do
                local mapped = CLASS_DEFAULT_ABILITY[tostring(cls.ClassUUID or "")]
                if mapped ~= nil then
                    classAbilities[mapped] = true
                end
            end
        end

        local fallbackAb = "Charisma"
        local fallbackScore = -1
        for _, ab in ipairs({ "Intelligence", "Wisdom", "Charisma" }) do
            if classAbilities[ab] and scores[ab] > fallbackScore then
                fallbackAb = ab
                fallbackScore = scores[ab]
            end
        end
        if fallbackScore < 0 then
            for _, ab in ipairs({ "Intelligence", "Wisdom", "Charisma" }) do
                if scores[ab] > fallbackScore then
                    fallbackAb = ab
                    fallbackScore = scores[ab]
                end
            end
        end

        local spellToBest = {}
        if entity.SpellBook ~= nil and entity.SpellBook.Spells ~= nil then
            for _, entry in ipairs(entity.SpellBook.Spells) do
                local id = entry.Id
                if id ~= nil and id.Prototype ~= nil and id.Prototype ~= "" then
                    local ok, rawAb = pcall(function()
                        return tostring(entry.SpellCastingAbility or "")
                    end)
                    local ab = (ok and ABILITY_SHORT[rawAb] ~= nil) and rawAb or fallbackAb
                    local prev = spellToBest[id.Prototype]
                    if prev == nil or scores[ab] > scores[prev] then
                        spellToBest[id.Prototype] = ab
                    end
                    local rootId = GetTrueRootSpell(id.Prototype)
                    if rootId ~= "" then
                        local prevRoot = spellToBest[rootId]
                        if prevRoot == nil or scores[ab] > scores[prevRoot] then
                            spellToBest[rootId] = ab
                        end
                    end
                end
            end
        end

        return spellToBest, fallbackAb
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

        local containerChildren = {}
        for spellName, _ in pairs(knownSpells) do
            local sStat = Ext.Stats.Get(spellName)
            if sStat ~= nil and sStat.ModifierList == "SpellData" and (sStat.ContainerSpells or "") ~= "" then
                for subSpell in string.gmatch(sStat.ContainerSpells, "[^;]+") do
                    containerChildren[subSpell] = true
                end
            end
        end
        for subSpell, _ in pairs(containerChildren) do
            knownSpells[subSpell] = true
        end

        local upcastAdditions = {}
        for spellName, _ in pairs(knownSpells) do
            for _, upcastSpell in ipairs(RootToUpcasts[spellName] or {}) do
                upcastAdditions[upcastSpell] = true
            end
        end
        for upcastSpell, _ in pairs(upcastAdditions) do
            knownSpells[upcastSpell] = true
        end

        local spellToBest, fallbackAb = GetBestSpellAbilityForCharacter(entity, uuid)
        local maxTier = GetMaxAvailableSpellTier(uuid)
        local hasPM = (Osi.HasPassive(uuid, "PolearmMaster_AttackOfOpportunity") == 1)
            or (Osi.HasPassive(uuid, "PolearmMaster") == 1)
        local boostsList = {}
        local seenInts = {}
        local sortedSpells = {}
        for spellName, _ in pairs(knownSpells) do
            table.insert(sortedSpells, spellName)
        end

        local displayNameCache = {}
        local function GetSpellSortKey(spellName)
            if displayNameCache[spellName] ~= nil then
                return displayNameCache[spellName]
            end
            local resolved = ResolveInheritedDisplayName(spellName)
            local cleanBase = string.gsub(resolved, "%s*%([Ll]evel%s*%d+%)", "")
            local sStat = Ext.Stats.Get(spellName)
            local tier = GetSpellSlotTier(sStat ~= nil and sStat.UseCosts or "")
            local sortKey = string.format("%s_%02d_%s", string.lower(cleanBase), tier, spellName)
            displayNameCache[spellName] = sortKey
            return sortKey
        end

        table.sort(sortedSpells, function(a, b)
            return GetSpellSortKey(a) < GetSpellSortKey(b)
        end)

        for _, spellName in ipairs(sortedSpells) do
            local rootId = GetTrueRootSpell(spellName)
            local targetAb = spellToBest[spellName] or (rootId ~= "" and spellToBest[rootId]) or fallbackAb
            local wcList = SpellToWCInterrupt[spellName]
            if wcList ~= nil then
                for _, info in ipairs(wcList) do
                    local tierAllowed = (info.level == 0) or (maxTier ~= 0 and math.floor(maxTier / info.level) ~= 0)
                    local featAllowed = (hasPM and info.isPM) or ((not hasPM) and (not info.isPM))
                    local abilityAllowed = (info.ability == "Default") or (info.ability == targetAb)
                    if tierAllowed and featAllowed and abilityAllowed and not seenInts[info.interrupt] then
                        seenInts[info.interrupt] = true
                        table.insert(boostsList, string.format("UnlockInterrupt(%s)", info.interrupt))
                    end
                end
            end
        end

        local chunks = ChunkBoostsList(boostsList, ";", 1600)
        for slotIdx = 1, math.min(#chunks, SLOTS_PER_CHAR) do
            local pName = GetCharPassiveName(charIdx, slotIdx)
            local pStat = Ext.Stats.Get(pName)
            if pStat ~= nil then
                pStat.Boosts = chunks[slotIdx]
                pStat:Sync()
                payload[pName] = chunks[slotIdx]
                table.insert(CharacterActivePassives[uuid], pName)
            end
        end
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
        local payload = {}
        CompileCharacterWarCaster(entity, uuid, payload)

        if next(payload) ~= nil then
            syncChannel:Broadcast(Ext.Json.Stringify(payload))
        end

        Ext.Timer.WaitFor(100, function()
            ApplyCharacterPassives(uuid)
        end)
    end

    local function RebuildAllCharacters()
        EnsureWarCasterReactionsPrepared()
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

        for _, row in ipairs(rows) do
            local rawGuid = table.unpack(row)
            local uuid = NormalizeUuid(rawGuid)
            if uuid ~= nil and not seen[uuid] then
                seen[uuid] = true
                local entity = Ext.Entity.Get(uuid)
                if entity ~= nil then
                    CompileCharacterWarCaster(entity, uuid, payload)
                end
            end
        end

        syncChannel:Broadcast(Ext.Json.Stringify(payload))

        Ext.Timer.WaitFor(100, function()
            for uuid, _ in pairs(CharacterSlotMap) do
                ApplyCharacterPassives(uuid)
            end
        end)
    end

    local PartyRebuildToken = 0
    local function SchedulePartyRebuild(delayMs)
        PartyRebuildToken = PartyRebuildToken + 1
        local token = PartyRebuildToken
        Ext.Timer.WaitFor(delayMs, function()
            if PartyRebuildToken == token then
                RebuildAllCharacters()
            end
        end)
    end

    function KJ_RebuildWarCaster()
        RebuildAllCharacters()
    end

    requestChannel:SetHandler(function()
        SchedulePartyRebuild(100)
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

        Ext.Entity.OnChange("PassiveContainer", function(entity)
            if entity ~= nil and entity.Uuid ~= nil and entity.Uuid.EntityUuid ~= nil then
                local uuid = NormalizeUuid(entity.Uuid.EntityUuid)
                if uuid ~= nil then
                    local hasWC = (Osi.HasPassive(uuid, WAR_CASTER_PASSIVE) == 1)
                    local hasSlot = (CharacterSlotMap[uuid] ~= nil)
                    if hasWC ~= hasSlot then
                        DelayedRebuild(uuid)
                    end
                end
            end
        end)

        local LastClassSpellSignature = {}

        local function ComputeClassSpellSignature(entity)
            local list = {}
            local seen = {}
            if entity.SpellBookPrepares ~= nil and entity.SpellBookPrepares.PreparedSpells ~= nil then
                for _, entry in ipairs(entity.SpellBookPrepares.PreparedSpells) do
                    local proto = entry.OriginatorPrototype
                    local src = entry.ProgressionSource ~= nil and tostring(entry.ProgressionSource) or ""
                    local srcType = tostring(entry.SourceType or "")
                    if proto ~= nil and proto ~= ""
                        and src ~= "" and src ~= "00000000-0000-0000-0000-000000000000"
                        and srcType ~= "Boost" and srcType ~= "WeaponSpell"
                        and not seen[proto] then
                        seen[proto] = true
                        table.insert(list, proto)
                    end
                end
            elseif entity.SpellBook ~= nil and entity.SpellBook.Spells ~= nil then
                for _, entry in ipairs(entity.SpellBook.Spells) do
                    local id = entry.Id
                    if id ~= nil and id.Prototype ~= nil and id.Prototype ~= "" then
                        local src = id.ProgressionSource ~= nil and tostring(id.ProgressionSource) or ""
                        if src ~= "" and src ~= "00000000-0000-0000-0000-000000000000" and not seen[id.Prototype] then
                            seen[id.Prototype] = true
                            table.insert(list, id.Prototype)
                        end
                    end
                end
            end
            table.sort(list)
            return table.concat(list, ";")
        end

        local function OnSpellBookChanged(entity)
            if entity ~= nil and entity.Uuid ~= nil and entity.Uuid.EntityUuid ~= nil then
                local uuid = NormalizeUuid(entity.Uuid.EntityUuid)
                if uuid ~= nil then
                    if Osi.HasPassive(uuid, WAR_CASTER_PASSIVE) == 1 then
                        local sig = ComputeClassSpellSignature(entity)
                        if sig ~= LastClassSpellSignature[uuid] then
                            LastClassSpellSignature[uuid] = sig
                            DelayedRebuild(uuid)
                        end
                    else
                        LastClassSpellSignature[uuid] = nil
                    end
                end
            end
        end

        Ext.Entity.OnChange("SpellBookPrepares", OnSpellBookChanged)
        Ext.Entity.OnChange("SpellBook", OnSpellBookChanged)

        Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(character)
            DelayedRebuild(character)
        end)

        Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(character)
            DelayedRebuild(character)
        end)

        Ext.Osiris.RegisterListener("UserConnected", 3, "after", function()
            SchedulePartyRebuild(750)
        end)
    end)
end