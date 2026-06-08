-- =============================================================================
-- VAS Bulk Crew Promotion -- Lua side
-- =============================================================================
-- Implements the three actions exposed by the MD (md/bulk_crew_promotion.xml):
--
--   VAS_BCP.PromoteSelected  -- in-place promote on each ship in the selection
--                               (selection passed via player.entity.$vas_bcp_ships)
--   VAS_BCP.PromoteAll       -- in-place promote on every player ship empire-wide
--   VAS_BCP.Reshuffle        -- cross-ship reshuffle: pull service / marine /
--                               unassigned crew from the empire-wide pool,
--                               sort them by piloting first, then promote good
--                               candidates to captain slots. Runs cooperatively
--                               over onUpdate so large empires stay responsive.
--                               Full target ships get one low-value service or
--                               marine moved to the donor and a delayed retry.
--
-- Promote actions report a simple count to MD via AddUITriggeredEvent.
-- Reshuffles publish structured progress data on the player blackboard and
-- signal translated lifecycle notifications from MD.
--
-- Debug logging is driven by the MD-side `$debugchance` value
-- (player.entity.$vas_bcp_debug_chance). Defaults to 0 (silent). Large
-- reshuffles flush the noisy promotion-success lines in batches so the engine's
-- debug message size cap does not hide most of the run.
-- =============================================================================

local ffi = require("ffi")
local C = ffi.C

-- ----------------------------------------------------------------------------
-- FFI cdefs. All lifted verbatim from menu_map.lua / menu_playerinfo.lua.
-- ----------------------------------------------------------------------------
ffi.cdef[[
    typedef uint64_t UniverseID;
    typedef uint64_t NPCSeed;

    typedef struct {
        UniverseID entity;
        UniverseID personcontrollable;
        NPCSeed    personseed;
    } GenericActor;

    typedef struct {
        const char* id;
        const char* name;
        const char* desc;
        uint32_t    amount;
        uint32_t    numtiers;
        bool        canhire;
    } PeopleInfo;

    typedef struct {
        const char* name;
        int32_t     skilllevel;
        uint32_t    amount;
    } RoleTierData;
    typedef struct {
        const char* id;
        uint32_t    textid;
        uint32_t    descriptionid;
        uint32_t    value;
        uint32_t    relevance;
        const char* ware;
    } SkillInfo;

    UniverseID GetPlayerID(void);
    double     GetCurrentGameTime(void);
    uint32_t   GetNumAllRoles(void);
    uint32_t   GetNumAllFactionShips(const char* factionid);
    uint32_t   GetAllFactionShips(UniverseID* result, uint32_t resultlen, const char* factionid);
    uint32_t   GetNumAllFactionStations(const char* factionid);
    uint32_t   GetAllFactionStations(UniverseID* result, uint32_t resultlen, const char* factionid);
    bool       IsComponentClass(UniverseID componentid, const char* classname);
    bool       IsUnit(UniverseID controllableid);
    bool       CanControllableHaveControlEntity(UniverseID controllableid, const char* postid);
    float      GetPersonCombinedSkill(UniverseID controllableid, NPCSeed personseed, const char* role, const char* post);
    const char* AssignHiredActor(GenericActor actor, UniverseID targetcontrollableid, const char* postid, const char* roleid, bool checkonly);
    uint32_t   GetNumSkills(void);
    uint32_t   GetPeople2(PeopleInfo* result, uint32_t resultlen, UniverseID controllableid, bool includearriving);
    uint32_t   GetPeopleCapacity(UniverseID controllableid, const char* macroname, bool includepilot);
    uint32_t   GetPersonSkills3(SkillInfo* result, uint32_t resultlen, NPCSeed person, UniverseID controllableid);
    uint32_t   GetRoleTiers(RoleTierData* result, uint32_t resultlen, UniverseID controllableid, const char* role);
    uint32_t   GetRoleTierNPCs(NPCSeed* result, uint32_t resultlen, UniverseID controllableid, const char* role, int32_t skilllevel);
]]

-- ----------------------------------------------------------------------------
-- Debug logging (MD-driven, same pattern as the other VAS mods).
-- ----------------------------------------------------------------------------
local cachedPlayerID
local function isDebugEnabled()
    if not cachedPlayerID then
        cachedPlayerID = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    end
    local chance = GetNPCBlackboard(cachedPlayerID, "$vas_bcp_debug_chance")
    return type(chance) == "number" and chance > 0
end

local logBuffer = {}
local pendingRetries = {}
local activeReshuffles = {}
local updateRegistered = false
local notifyPromote
local promotionLogLinesSinceFlush = 0
local verboseLogLinesSinceFlush = 0
local PROMOTION_LOG_FLUSH_INTERVAL = 60
local VERBOSE_LOG_FLUSH_INTERVAL = 60
local RESHUFFLE_PROGRESS_LOG_INTERVAL = 5.0
local BUSY_PILOT_RETRY_DELAYS = { 10, 60, 120 }

-- Local-only debug verbosity for reshuffle decision spam.
-- "each"    = old firehose: every skip/assignment line.
-- "grouped" = compact counters by reason/role.
-- "none"    = only high-level start/done lines.
local LOG_REASONS = "grouped"
local safePlayerID

local function getLogReasonsMode()
    local mode = GetNPCBlackboard(safePlayerID(), "$vas_bcp_log_reasons")
    if mode == "each" or mode == "grouped" or mode == "none" then
        return mode
    end
    return LOG_REASONS
end

local function debug(msg)
    if not isDebugEnabled() then return end
    table.insert(logBuffer, "[VAS-BCP] " .. tostring(msg))
end

local function flushDebug()
    if #logBuffer == 0 then return end
    if type(DebugError) == "function" then
        DebugError(table.concat(logBuffer, "\n"))
    end
    logBuffer = {}
    promotionLogLinesSinceFlush = 0
    verboseLogLinesSinceFlush = 0
end

local function pushReshuffleMessage(kind, data)
    local msg = {}
    for i, value in ipairs(data or {}) do
        msg[i] = tostring(value == nil and 0 or value)
    end
    SetNPCBlackboard(safePlayerID(), "$vas_bcp_reshuffle_" .. string.lower(kind) .. "_message", msg)
    AddUITriggeredEvent("VAS_BCP_Reshuffle" .. kind, "changed")
end

local function notePromotionLogLine()
    promotionLogLinesSinceFlush = promotionLogLinesSinceFlush + 1
    if promotionLogLinesSinceFlush >= PROMOTION_LOG_FLUSH_INTERVAL then
        promotionLogLinesSinceFlush = 0
        flushDebug()
    end
end

local function noteVerboseLogLine()
    verboseLogLinesSinceFlush = verboseLogLinesSinceFlush + 1
    if verboseLogLinesSinceFlush >= VERBOSE_LOG_FLUSH_INTERVAL then
        verboseLogLinesSinceFlush = 0
        flushDebug()
    end
end

local function logReasonsEach()
    return getLogReasonsMode() == "each"
end

local function logReasonsGrouped()
    return getLogReasonsMode() == "grouped"
end

local function addStat(stats, bucket, key, amount)
    if not stats or not bucket or not key then return end
    stats[bucket] = stats[bucket] or {}
    stats[bucket][key] = (stats[bucket][key] or 0) + (amount or 1)
end

local function compactReason(reason)
    reason = tostring(reason or "unknown")
    local openParen = string.find(reason, " %(")
    if openParen then
        return string.sub(reason, 1, openParen - 1)
    end
    return reason
end

local function logStatBucket(title, bucket)
    if not logReasonsGrouped() or not bucket then return end
    local keys = {}
    for key in pairs(bucket) do
        keys[#keys + 1] = key
    end
    if #keys == 0 then return end
    table.sort(keys)
    debug(title)
    for _, key in ipairs(keys) do
        debug(string.format("    %s: %s", key, tostring(bucket[key])))
        noteVerboseLogLine()
    end
end

local function logGroupedReshuffleStats(job)
    if job.groupedStatsLogged then return end
    logStatBucket("Grouped donor ship skips:", job.donorShipSkipStats)
    logStatBucket("Grouped target ship skips:", job.targetShipSkipStats)
    logStatBucket("Grouped candidate skips:", job.candidateSkipStats)
    logStatBucket("Grouped delayed retry queues:", job.retryStats)
    logStatBucket("Grouped assignments:", job.assignmentStats)
    job.groupedStatsLogged = true
end

local function sumStatBucket(bucket)
    local total = 0
    if not bucket then return total end
    for _, count in pairs(bucket) do
        total = total + (tonumber(count) or 0)
    end
    return total
end

-- ----------------------------------------------------------------------------
-- Constants & small helpers
-- ----------------------------------------------------------------------------

-- Roles to consider as reshuffle candidates. Captains ("aipilot"), managers
-- ("manager"), ship traders ("shiptrader"), terraformers, etc. are deliberately
-- excluded because they hold posts the player or the game assigned explicitly.
local PROMOTABLE_ROLES = { service = true, marine = true, unassigned = true }

-- For the in-place A-mode pool. Vanilla's replace-pilot button uses only
-- service + marine for the on-ship candidate pool; we match that.
local ONSHIP_PROMOTABLE_ROLES = { service = true, marine = true }

-- Crew roles that can be moved away from a full target ship to free one bunk
-- before a cross-ship captain swap. "unassigned" can be read from GetPeople2,
-- but vanilla's AssignHiredActor role options expose service/marine, so keep
-- this conservative.
local SPACE_MAKER_ROLES = { service = true, marine = true }

local PILOT_POST = "aipilot"
local MANAGER_POST = "manager"
local PILOTING_SKILL = "piloting"
local MANAGEMENT_SKILL = "management"
local BOARDING_SKILL = "boarding"
local MAX_SKILL_LEVEL = 15
local RESHUFFLE_SLOT_DELAY = 0.1
local getPersonSkill
local getNonPilotCrewCapacity
local isMilitaryShip

local DEFAULT_RESHUFFLE_CONFIG = {
    targetIncludeMilitary = true,
    targetIncludeMiners = true,
    targetIncludeTraders = true,
    targetIncludeBuilders = true,
    targetIncludeSalvage = true,
    targetIncludeAuxiliary = true,
    targetIncludeOther = true,
    targetIncludeShipS = true,
    targetIncludeShipM = true,
    targetIncludeShipL = true,
    targetIncludeShipXL = true,
    donorIncludeMilitary = true,
    donorIncludeMiners = true,
    donorIncludeTraders = true,
    donorIncludeBuilders = true,
    donorIncludeSalvage = true,
    donorIncludeAuxiliary = true,
    donorIncludeOther = true,
    donorIncludeShipS = true,
    donorIncludeShipM = true,
    donorIncludeShipL = true,
    donorIncludeShipXL = true,
    candidateService = true,
    candidateMarine = true,
    candidateUnassigned = true,
    donorReserveCivilianService = 0,
    donorReserveCivilianMarine = 0,
    donorReserveMilitaryService = 0,
    donorReserveMilitaryMarine = 0,
    recipientMinHull = 0,
    recipientMinShield = 0,
    minPilotingImprovement = 0,
    minCombinedImprovementPercent = 0,
    sameCommanderOnly = false,
    unassignedShipsOnly = false,
    withoutCaptainOnly = false,
    includeStationManagers = false,
    preserveEliteMarines = false,
    eliteMarineBoardingThreshold = MAX_SKILL_LEVEL,
}

safePlayerID = function()
    if not cachedPlayerID then
        cachedPlayerID = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    end
    return cachedPlayerID
end

local function isValidUniverseComponent(id)
    if not id or id == 0 then return false end
    local luaid = ConvertStringToLuaID(tostring(id))
    return luaid and IsValidComponent(luaid)
end

local function shipName(id)
    if not id or id == 0 then return "<nil>" end
    if not isValidUniverseComponent(id) then return "<invalid #" .. tostring(id) .. ">" end
    local n = GetComponentData(id, "name")
    return (n and n ~= "") and n or ("<#" .. tostring(id) .. ">")
end

local function shipLabel(id)
    local name = shipName(id)
    if not isValidUniverseComponent(id) then return name end
    local idcode = GetComponentData(id, "idcode")
    if idcode and idcode ~= "" then
        return string.format("%s (%s)", name, idcode)
    end
    return name
end

local function targetLabel(id)
    return shipLabel(id)
end

local function readReshuffleConfig()
    local stored = GetNPCBlackboard(safePlayerID(), "$vas_bcp_config")
    local config = {}
    for key, value in pairs(DEFAULT_RESHUFFLE_CONFIG) do
        local storedValue = nil
        if type(stored) == "table" then
            storedValue = stored[key]
            if storedValue == nil then
                storedValue = stored["$" .. key]
            end
        end
        if storedValue ~= nil then
            if type(value) == "boolean" then
                config[key] = storedValue == true or storedValue == 1
            elseif type(value) == "number" then
                config[key] = tonumber(storedValue) or value
            else
                config[key] = storedValue
            end
        else
            config[key] = value
        end
    end
    return config
end

local function defaultReshuffleConfig()
    local config = {}
    for key, value in pairs(DEFAULT_RESHUFFLE_CONFIG) do
        config[key] = value
    end
    return config
end

local function hasCommander(ship)
    local commander = GetCommander(ship)
    return commander ~= nil and commander ~= 0
end

local function haveSameCommander(leftShip, rightShip)
    if not leftShip or not rightShip then return false end
    local leftCommander = GetCommander(leftShip)
    local rightCommander = GetCommander(rightShip)
    return leftCommander ~= nil
        and leftCommander ~= 0
        and rightCommander ~= nil
        and rightCommander ~= 0
        and tostring(leftCommander) == tostring(rightCommander)
end

local function shipClassInfo(ship)
    local purpose, shiptype = GetComponentData(ship, "primarypurpose", "shiptype")
    local sizeClass = "unknown"
    if C.IsComponentClass(ship, "ship_s") then
        sizeClass = "ship_s"
    elseif C.IsComponentClass(ship, "ship_m") then
        sizeClass = "ship_m"
    elseif C.IsComponentClass(ship, "ship_l") then
        sizeClass = "ship_l"
    elseif C.IsComponentClass(ship, "ship_xl") then
        sizeClass = "ship_xl"
    end
    return purpose or "", shiptype or "", sizeClass
end

local function describeShipForConfig(ship)
    local purpose, shiptype, sizeClass = shipClassInfo(ship)
    return string.format("purpose=%s, shiptype=%s, sizeClass=%s, isMilitary=%s, hasCommander=%s",
        purpose, shiptype, sizeClass, tostring(isMilitaryShip(ship)), tostring(hasCommander(ship)))
end

function isMilitaryShip(ship)
    local purpose = GetComponentData(ship, "primarypurpose")
    return purpose == "fight"
end

local function crewCountByRole(ship, roleid)
    local rolemax = C.GetNumAllRoles()
    if rolemax == 0 then return 0 end

    local pbuf = ffi.new("PeopleInfo[?]", rolemax)
    local n = C.GetPeople2(pbuf, rolemax, ship, true)
    for i = 0, n - 1 do
        if ffi.string(pbuf[i].id) == roleid then
            return tonumber(pbuf[i].amount) or 0
        end
    end
    return 0
end

local function shipPurposeAllowedByConfig(ship, config, prefix)
    local purpose, shiptype, sizeClass = shipClassInfo(ship)
    local sizeKey = ({
        ship_s = "IncludeShipS",
        ship_m = "IncludeShipM",
        ship_l = "IncludeShipL",
        ship_xl = "IncludeShipXL",
    })[sizeClass]
    if sizeKey and not config[prefix .. sizeKey] then
        return false, sizeClass .. " ships disabled"
    end

    if shiptype == "resupplier" then
        return config[prefix .. "IncludeAuxiliary"], "auxiliaries/resuppliers disabled"
    elseif shiptype == "tug" or shiptype == "compactor" or purpose == "salvage" then
        return config[prefix .. "IncludeSalvage"], "salvage ships disabled"
    elseif purpose == "mine" then
        return config[prefix .. "IncludeMiners"], "miners disabled"
    elseif purpose == "trade" then
        return config[prefix .. "IncludeTraders"], "traders disabled"
    elseif purpose == "build" then
        return config[prefix .. "IncludeBuilders"], "builders disabled"
    elseif purpose == "fight" then
        return config[prefix .. "IncludeMilitary"], "military ships disabled"
    else
        return config[prefix .. "IncludeOther"], "other ship purposes disabled"
    end
end

local function isTargetShipAllowedByConfig(ship, config)
    local ok, reason = shipPurposeAllowedByConfig(ship, config, "target")
    if not ok then return false, reason end

    if config.unassignedShipsOnly and hasCommander(ship) then
        return false, "has commander"
    end
    if config.withoutCaptainOnly then
        local pilot = GetComponentData(ship, "assignedaipilot")
        if pilot and IsValidComponent(pilot) then
            return false, "already has captain"
        end
    end
    local hull, shield = GetComponentData(ship, "hullpercent", "shieldpercent")
    if (tonumber(hull) or 0) < (tonumber(config.recipientMinHull) or 0) then
        return false, "below minimum hull"
    end
    if (tonumber(shield) or 0) < (tonumber(config.recipientMinShield) or 0) then
        return false, "below minimum shield"
    end
    return true
end

local function isDonorShipAllowedByConfig(ship, config)
    return shipPurposeAllowedByConfig(ship, config, "donor")
end

-- Composite key for "this donor ship + this crew role".
-- Used to count how many service/marine NPCs this reshuffle job already plans
-- to remove from that exact donor-role bucket.
local function donorRoleCompositeKey(person)
    return tostring(person.container) .. ":" .. tostring(person.roleid)
end

local function isCandidateCrewAllowedByConfig(person, targetShip, config, alreadyReserved)
    if person.roleid == "service" and not config.candidateService then
        return false, "service candidates disabled"
    elseif person.roleid == "marine" and not config.candidateMarine then
        return false, "marine candidates disabled"
    elseif person.roleid == "unassigned" and not config.candidateUnassigned then
        return false, "unassigned candidates disabled"
    elseif not PROMOTABLE_ROLES[person.roleid] then
        return false, "role not promotable"
    end

    if targetShip and config.sameCommanderOnly and not haveSameCommander(targetShip, person.container) then
        return false, "different commander"
    end

    if person.roleid == "service" or person.roleid == "marine" then
        local reserveKey
        if isMilitaryShip(person.container) then
            reserveKey = (person.roleid == "service") and "donorReserveMilitaryService" or "donorReserveMilitaryMarine"
        else
            reserveKey = (person.roleid == "service") and "donorReserveCivilianService" or "donorReserveCivilianMarine"
        end

        local capacity = getNonPilotCrewCapacity(person.container)
        local roleCount = crewCountByRole(person.container, person.roleid)
        local reservePercent = tonumber(config[reserveKey]) or 0
        local minimumToKeep = math.ceil(capacity * reservePercent / 100)
        if (roleCount - (tonumber(alreadyReserved) or 0) - 1) < minimumToKeep then
            return false, string.format(
                "donor reserve protected (%s: capacity=%s, roleCount=%s, reserved=%s, keep=%s/%s%%)",
                reserveKey, tostring(capacity), tostring(roleCount),
                tostring(tonumber(alreadyReserved) or 0), tostring(minimumToKeep), tostring(reservePercent))
        end
    end

    if person.roleid == "marine" and config.preserveEliteMarines then
        local boarding = getPersonSkill(person.container, person.seed, BOARDING_SKILL)
        if boarding >= (tonumber(config.eliteMarineBoardingThreshold) or MAX_SKILL_LEVEL) then
            return false, "elite marine protected"
        end
    end
    return true
end

local function markCandidateReserved(job, person)
    if person.roleid ~= "service" and person.roleid ~= "marine" then return end
    local key = donorRoleCompositeKey(person)
    job.donorRoleReservations[key] = (job.donorRoleReservations[key] or 0) + 1
end

-- A "promotable" player ship: actually a ship (not a deployable / lasertower /
-- unit drone) and capable of carrying crew. Matches Zoinks' isShip check.
local function isPromotableShip(id)
    if not id or id == 0 then return false end
    if not isValidUniverseComponent(id) then return false end
    if not C.IsComponentClass(id, "ship") then return false end
    if C.IsUnit(id) then return false end
    local macro, isdeployable = GetComponentData(id, "macro", "isdeployable")
    if isdeployable then return false end
    local islasertower, ware = GetMacroData(macro, "islasertower", "ware")
    if islasertower then return false end
    if not ware then return false end
    return true
end

function getNonPilotCrewCapacity(ship)
    if not isPromotableShip(ship) then return 0 end
    -- Vanilla uses includepilot=false for non-pilot crew capacity. A value of 0
    -- means tiny captain-only ships such as Dart cannot donate spacer crew.
    return tonumber(C.GetPeopleCapacity(ship, "", false)) or 0
end

local function getEntitySkill(entityLuaID, skillid)
    local skills = GetComponentData(entityLuaID, "skills") or {}
    for _, entry in ipairs(skills) do
        if entry.name == skillid then
            return tonumber(entry.value) or -1
        end
    end
    return -1
end

function getPersonSkill(controllable, seed, skillid)
    local numskills = C.GetNumSkills()
    if numskills == 0 then return -1 end

    local buf = ffi.new("SkillInfo[?]", numskills)
    local n = C.GetPersonSkills3(buf, numskills, seed, controllable)
    for i = 0, n - 1 do
        if ffi.string(buf[i].id) == skillid then
            return tonumber(buf[i].value) or -1
        end
    end
    return -1
end

-- Read the current pilot, the post they hold, their combined assignment skill
-- on this ship, and their raw piloting skill. Combined skill decides whether a
-- candidate improves the slot; raw piloting decides whether a pilot is already
-- capped and can be skipped.
-- Returns (entityOrNil, seedOrZero, post, combinedSkill, pilotingSkill).
local function getCurrentPilot(ship)
    local pilot = GetComponentData(ship, "assignedaipilot")
    if not pilot or not IsValidComponent(pilot) then
        return nil, 0, PILOT_POST, -1, -1
    end
    local pilotLuaID = ConvertStringToLuaID(tostring(pilot))
    local post = GetComponentData(pilotLuaID, "poststring") or PILOT_POST
    local skill = tonumber(GetComponentData(pilotLuaID, "combinedskill")) or -1
    local piloting = getEntitySkill(pilotLuaID, PILOTING_SKILL)
    -- The pilot's seed: GetComponentData entity returns the entity ID; we use
    -- the entity form in the actor table (entity field) for AssignHiredActor.
    return pilot, 0, post, skill, piloting
end

local function getCurrentManager(station)
    local manager = GetComponentData(station, "tradenpc")
    if not manager or not IsValidComponent(manager) then
        return nil, 0, MANAGER_POST, -1, -1
    end
    local manager64 = ConvertIDTo64Bit(manager)
    local managerLuaID = ConvertStringToLuaID(tostring(manager))
    local post = GetComponentData(managerLuaID, "poststring") or MANAGER_POST
    local skill = tonumber(GetComponentData(managerLuaID, "combinedskill")) or -1
    local management = getEntitySkill(managerLuaID, MANAGEMENT_SKILL)
    return manager64, 0, post, skill, management
end

-- Enumerate the crew of `ship` that match `allowedRoles` (a set keyed by
-- role id strings: { service=true, marine=true, unassigned=true }).
-- Returns a list of { seed, container, roleid }.
local function collectCrewByRoles(ship, allowedRoles)
    local out = {}
    local rolemax = C.GetNumAllRoles()
    if rolemax == 0 then return out end

    local pbuf = ffi.new("PeopleInfo[?]", rolemax)
    local n = C.GetPeople2(pbuf, rolemax, ship, true)
    for i = 0, n - 1 do
        local roleid = ffi.string(pbuf[i].id)
        if allowedRoles[roleid] then
            local numtiers = pbuf[i].numtiers
            if numtiers > 0 then
                local tbuf = ffi.new("RoleTierData[?]", numtiers)
                local ntiers = C.GetRoleTiers(tbuf, numtiers, ship, pbuf[i].id)
                for j = 0, ntiers - 1 do
                    local nperson = tbuf[j].amount
                    if nperson > 0 then
                        local seeds = ffi.new("NPCSeed[?]", nperson)
                        nperson = C.GetRoleTierNPCs(seeds, nperson, ship, pbuf[i].id, tbuf[j].skilllevel)
                        for k = 0, nperson - 1 do
                            out[#out + 1] = { seed = seeds[k], container = ship, roleid = roleid }
                        end
                    end
                end
            elseif roleid == "unassigned" then
                -- Unassigned often reports no tiers; ask at skilllevel 0.
                local nperson = pbuf[i].amount
                if nperson > 0 then
                    local seeds = ffi.new("NPCSeed[?]", nperson)
                    nperson = C.GetRoleTierNPCs(seeds, nperson, ship, pbuf[i].id, 0)
                    for k = 0, nperson - 1 do
                        out[#out + 1] = { seed = seeds[k], container = ship, roleid = roleid }
                    end
                end
            end
        end
    end
    return out
end

local function makePersonActor(container, seed)
    local actor = ffi.new("GenericActor")
    actor.entity = 0
    actor.personcontrollable = container
    actor.personseed = seed
    return actor
end

local function makeEntityActor(entity)
    local actor = ffi.new("GenericActor")
    actor.entity = entity or 0
    actor.personcontrollable = 0
    actor.personseed = 0
    return actor
end

local function logCaptainAssignment(job, slot, cand, totalSkill, note)
    local statKey = string.format("%s candidate%s",
        tostring(cand.roleid), note and (" (" .. note .. ")") or "")
    addStat(job, "assignmentStats", statKey)
    if not logReasonsEach() then return end

    local noteText = note and (note .. "; ") or ""
    debug(string.format("  %s <- %s candidate from %s (%spilotingSkill %s -> %s, totalSkill %s -> %s)",
        shipLabel(slot.ship), cand.roleid, shipLabel(cand.container), noteText,
        tostring(slot.oldPiloting), tostring(cand.sortPiloting),
        tostring(slot.oldSkill), tostring(totalSkill)))
    notePromotionLogLine()
end

local function logManagerAssignment(job, slot, cand, totalSkill, note)
    local statKey = string.format("%s manager candidate%s",
        tostring(cand.roleid), note and (" (" .. note .. ")") or "")
    addStat(job, "assignmentStats", statKey)
    if not logReasonsEach() then return end

    local noteText = note and (note .. "; ") or ""
    debug(string.format("  %s manager <- %s candidate from %s (%smanagementSkill %s -> %s, totalSkill %s -> %s)",
        targetLabel(slot.station), cand.roleid, shipLabel(cand.container), noteText,
        tostring(slot.oldManagement), tostring(cand.sortManagement),
        tostring(slot.oldSkill), tostring(totalSkill)))
    notePromotionLogLine()
end

local function assignToRolePreserving(actor, target, roleid, checkonly)
    local role = roleid or "service"
    local reason = ffi.string(C.AssignHiredActor(actor, target, "", role, checkonly))
    if reason ~= "" and role ~= "service" then
        reason = ffi.string(C.AssignHiredActor(actor, target, "", "service", checkonly))
        role = "service"
    end
    return reason, role
end

local function logReshuffleProgress(job, gameNow, realNow)
    if gameNow < (job.nextProgressLog or 0) then return end

    local totalSlots = #job.slots
    local processedSlots = math.max(0, math.min(totalSlots, (tonumber(job.nextSlot) or 1) - 1))
    local pendingDelay = math.max(0, (tonumber(job.nextTime) or realNow) - realNow)
    debug(string.format(
        "Reshuffle progress [%s]: slots %d/%d, promoted=%d, noCandidate=%d, capacitySkips=%d, pendingRetries=%d, nextSlotDelay=%.1fs",
        tostring(job.mode),
        processedSlots,
        totalSlots,
        tonumber(job.promoted) or 0,
        tonumber(job.skippedNoCandidate) or 0,
        tonumber(job.skippedCapacity) or 0,
        tonumber(job.pendingRetries) or 0,
        pendingDelay))
    job.nextProgressLog = gameNow + RESHUFFLE_PROGRESS_LOG_INTERVAL
    flushDebug()

    local pendingRetryCount = tonumber(job.pendingRetries) or 0
    local retryTailActive = processedSlots >= totalSlots and pendingRetryCount > 0
    if processedSlots < totalSlots and not job.retryTailReported then
        pushReshuffleMessage("Progress", {
            processedSlots,
            totalSlots,
            tonumber(job.promoted) or 0,
            pendingRetryCount,
        })
    end

    if retryTailActive and not job.retryTailReported then
        logGroupedReshuffleStats(job)
        debug(string.format("Reshuffle slot pass complete: %d promoted, %d slots without candidate, %d delayed retry/retries still pending",
            tonumber(job.promoted) or 0,
            tonumber(job.skippedNoCandidate) or 0,
            pendingRetryCount))
        flushDebug()
        job.retryTailReported = true
        pushReshuffleMessage("Waiting", {
            tonumber(job.promoted) or 0,
            pendingRetryCount,
        })
    end
end

local function onUpdate()
    -- Two independent clocks:
    --   realNow  = real UI time; drives the per-slot processing cadence so the
    --              empire walk keeps grinding one slot per tick regardless of pause.
    --   gameNow  = in-game simulation time; freezes on pause, scales with SETA.
    --              Drives retry delays and the progress heartbeat so those only
    --              advance while the game is actually running.
    local realNow = getElapsedTime()
    local gameNow = C.GetCurrentGameTime()
    local remaining = {}

    for _, retry in ipairs(pendingRetries) do
        if gameNow < retry.time then
            remaining[#remaining + 1] = retry
        else
            local actor = makePersonActor(retry.cand.container, retry.cand.seed)
            local target = retry.slot.station or retry.slot.ship
            local reason = ffi.string(C.AssignHiredActor(actor, target, retry.slot.post, nil, true))
            if reason == "" then
                ffi.string(C.AssignHiredActor(actor, target, retry.slot.post, nil, false))
                retry.job.promoted = retry.job.promoted + 1
                if retry.slot.kind == "manager" then
                    logManagerAssignment(retry.job, retry.slot, retry.cand, retry.totalSkill, "delayed retry")
                else
                    logCaptainAssignment(retry.job, retry.slot, retry.cand, retry.totalSkill, "delayed retry")
                end
                retry.job.pendingRetries = retry.job.pendingRetries - 1
            elseif reason == "previouspilotbusy" and retry.busyDelayIndex and retry.busyDelayIndex <= #BUSY_PILOT_RETRY_DELAYS then
                local delay = BUSY_PILOT_RETRY_DELAYS[retry.busyDelayIndex]
                retry.busyDelayIndex = retry.busyDelayIndex + 1
                retry.time = gameNow + delay
                remaining[#remaining + 1] = retry
                if logReasonsEach() then
                    debug(string.format("    %s: current post holder still busy; retry again in %ss",
                        targetLabel(target), tostring(delay)))
                    noteVerboseLogLine()
                end
            else
                addStat(retry.job, "candidateSkipStats", retry.cand.roleid .. " | delayed retry failed: " .. compactReason(reason))
                if logReasonsEach() then
                    debug(string.format("    delayed retry failed for %s <- %s candidate from %s: %s",
                        targetLabel(target), retry.cand.roleid, shipLabel(retry.cand.container), reason))
                    noteVerboseLogLine()
                end
                retry.job.skippedCapacity = retry.job.skippedCapacity + 1
                retry.job.pendingRetries = retry.job.pendingRetries - 1
            end
        end
    end

    pendingRetries = remaining

    local remainingReshuffles = {}
    for _, job in ipairs(activeReshuffles) do
        logReshuffleProgress(job, gameNow, realNow)
        if realNow < job.nextTime then
            remainingReshuffles[#remainingReshuffles + 1] = job
        else
            local slot = job.slots[job.nextSlot]
            if slot then
                job.processSlot(job, slot)
                job.nextSlot = job.nextSlot + 1
                job.nextTime = realNow + RESHUFFLE_SLOT_DELAY
                remainingReshuffles[#remainingReshuffles + 1] = job
            elseif job.pendingRetries > 0 then
                remainingReshuffles[#remainingReshuffles + 1] = job
            else
                logGroupedReshuffleStats(job)
                debug(string.format("Reshuffle done: %d promoted, %d slots without candidate, %d capacity skips",
                    job.promoted, job.skippedNoCandidate, job.skippedCapacity))
                pushReshuffleMessage("Done", {
                    job.promoted,
                    job.skippedNoCandidate,
                    job.skippedCapacity,
                })
            end
        end
    end
    activeReshuffles = remainingReshuffles

    if #pendingRetries == 0 and #activeReshuffles == 0 then
        updateRegistered = false
        RemoveScript("onUpdate", onUpdate)
        flushDebug()
    end
end

local function scheduleRetry(job, slot, cand, totalSkill, delay, busyDelayIndex)
    job.pendingRetries = job.pendingRetries + 1
    pendingRetries[#pendingRetries + 1] = {
        job = job,
        -- Retry delays count down on in-game time (see onUpdate): they pause with
        -- the game and accelerate under SETA.
        time = C.GetCurrentGameTime() + delay,
        slot = {
            kind = slot.kind,
            ship = slot.ship,
            station = slot.station,
            post = slot.post,
            oldSkill = slot.oldSkill,
            oldPiloting = slot.oldPiloting,
            oldManagement = slot.oldManagement,
        },
        cand = {
            seed = cand.seed,
            container = cand.container,
            roleid = cand.roleid,
            sortPiloting = cand.sortPiloting,
            sortManagement = cand.sortManagement,
        },
        totalSkill = totalSkill,
        busyDelayIndex = busyDelayIndex,
    }
    if not updateRegistered then
        updateRegistered = true
        SetScript("onUpdate", onUpdate)
    end
end

local function tryMoveOneCrewToDonor(slotShip, donorShip)
    if slotShip == donorShip then
        return nil, "samecontainer"
    end

    local crew = collectCrewByRoles(slotShip, SPACE_MAKER_ROLES)
    table.sort(crew, function(a, b)
        local askill = C.GetPersonCombinedSkill(a.container, a.seed, nil, PILOT_POST)
        local bskill = C.GetPersonCombinedSkill(b.container, b.seed, nil, PILOT_POST)
        return askill < bskill
    end)

    for _, p in ipairs(crew) do
        local actor = makePersonActor(p.container, p.seed)
        local reason, assignedRole = assignToRolePreserving(actor, donorShip, p.roleid, true)
        if reason == "" then
            assignToRolePreserving(actor, donorShip, p.roleid, false)
            p.assignedRole = assignedRole
            return p, ""
        end
    end

    return nil, "nodonorroom"
end

local function tryMoveCurrentManagerToDonor(slot, donorShip)
    if not slot or not slot.managerEntity or slot.managerEntity == 0 then
        return nil, "nomanager"
    end

    local actor = makeEntityActor(slot.managerEntity)
    local reason, assignedRole = assignToRolePreserving(actor, donorShip, "service", true)
    if reason == "" then
        assignToRolePreserving(actor, donorShip, "service", false)
        return { entity = slot.managerEntity, assignedRole = assignedRole or "service" }, ""
    end

    return nil, reason ~= "" and reason or "nomove"
end

-- All player ships, filtered to promotable. Returns a Lua list.
local function allPromotableShips()
    local n = C.GetNumAllFactionShips("player")
    if n == 0 then return {} end
    local buf = ffi.new("UniverseID[?]", n)
    n = C.GetAllFactionShips(buf, n, "player")
    local out = {}
    for i = 0, n - 1 do
        local id = ConvertStringTo64Bit(tostring(buf[i]))
        if isPromotableShip(id) then
            out[#out + 1] = id
        end
    end
    return out
end

local function allPlayerStations()
    local n = C.GetNumAllFactionStations("player")
    if n == 0 then return {} end
    local buf = ffi.new("UniverseID[?]", n)
    n = C.GetAllFactionStations(buf, n, "player")
    local out = {}
    for i = 0, n - 1 do
        local id = ConvertStringTo64Bit(tostring(buf[i]))
        if isValidUniverseComponent(id) and C.IsComponentClass(id, "station") then
            out[#out + 1] = id
        end
    end
    return out
end

-- ============================================================================
-- A: In-place promote on a single ship.
-- Returns true if a change happened.
-- ============================================================================

local function promoteInPlace(ship)
    if not isPromotableShip(ship) then return false end

    local pilotEntity, _, post, oldSkill, oldPiloting = getCurrentPilot(ship)
    if not C.CanControllableHaveControlEntity(ship, post) then
        debug(string.format("  %s: cannot hold post '%s' (skip)", shipLabel(ship), post))
        return false
    end

    local crew = collectCrewByRoles(ship, ONSHIP_PROMOTABLE_ROLES)
    local bestSeed, bestSkill, bestPiloting = nil, oldSkill, oldPiloting
    for _, p in ipairs(crew) do
        local s = C.GetPersonCombinedSkill(ship, p.seed, nil, post)
        if s > bestSkill then
            bestSeed = p.seed
            bestSkill = s
            bestPiloting = getPersonSkill(ship, p.seed, PILOTING_SKILL)
        end
    end

    if not bestSeed then
        debug(string.format("  %s: no better on-board candidate (current skill %s)",
            shipName(ship), tostring(oldSkill)))
        return false
    end

    local actor = ffi.new("GenericActor")
    actor.entity = 0
    actor.personcontrollable = ship
    actor.personseed = bestSeed

    local reason = ffi.string(C.AssignHiredActor(actor, ship, post, nil, false))
    if reason ~= "" then
        debug(string.format("  %s: AssignHiredActor failed: %s",
            shipName(ship), reason))
        return false
    end

    debug(string.format("  %s: promoted (pilotingSkill %s -> %s, totalSkill %s -> %s)",
        shipName(ship), tostring(oldPiloting), tostring(bestPiloting), tostring(oldSkill), tostring(bestSkill)))
    return true
end

-- ============================================================================
-- B: Empire-wide reshuffle.
-- ============================================================================

-- For each promotable player ship, snapshot { ship, currentPilotEntity,
-- currentSkill, post }.
local function buildCaptainSlots(ships, config)
    local slots = {}
    local stats = {
        targetShipSkipStats = {},
    }
    for _, ship in ipairs(ships) do
        if not isPromotableShip(ship) then
            addStat(stats, "targetShipSkipStats", "not a valid promotable ship")
            if logReasonsEach() then
                debug(string.format("  %s: not a valid promotable ship (skip)", shipLabel(ship)))
                noteVerboseLogLine()
            end
        else
            if logReasonsEach() then
                debug(string.format("  %s: target classification (%s)", shipLabel(ship), describeShipForConfig(ship)))
                noteVerboseLogLine()
            end
            local allowed, configReason = isTargetShipAllowedByConfig(ship, config)
            local pilotEntity, _, post, oldSkill, oldPiloting = getCurrentPilot(ship)
            if not allowed then
                addStat(stats, "targetShipSkipStats", compactReason(configReason))
                if logReasonsEach() then
                    debug(string.format("  %s: target config skip (%s)", shipLabel(ship), configReason))
                    noteVerboseLogLine()
                end
            elseif oldPiloting >= MAX_SKILL_LEVEL then
                addStat(stats, "targetShipSkipStats", "pilot already piloting-capped")
                if logReasonsEach() then
                    debug(string.format("  %s: pilot already piloting-capped (%s/%s, combined=%s), skip",
                        shipLabel(ship), tostring(oldPiloting), tostring(MAX_SKILL_LEVEL), tostring(oldSkill)))
                    noteVerboseLogLine()
                end
            elseif getNonPilotCrewCapacity(ship) < 1 and pilotEntity then
                addStat(stats, "targetShipSkipStats", "captain-only ship")
                if logReasonsEach() then
                    debug(string.format("  %s: no non-pilot crew capacity (captain-only ship, skip)",
                        shipLabel(ship)))
                    noteVerboseLogLine()
                end
            elseif C.CanControllableHaveControlEntity(ship, post) then
                slots[#slots + 1] = {
                    ship = ship,
                    post = post,
                    pilotEntity = pilotEntity,
                    oldSkill = oldSkill,
                    oldPiloting = oldPiloting,
                }
            end
        end
    end
    return slots, stats
end

local function buildManagerSlots(stations)
    local slots = {}
    local stats = {
        targetShipSkipStats = {},
    }
    for _, station in ipairs(stations or {}) do
        if not isValidUniverseComponent(station) or not C.IsComponentClass(station, "station") then
            addStat(stats, "targetShipSkipStats", "not a valid station")
        else
            -- managerEntity may be nil: an UNMANAGED station is still a valid
            -- target (a candidate fills the empty manager post). oldManagement is
            -- -1 then, so any real candidate beats it and the post gets filled.
            local managerEntity, _, _, oldSkill, oldManagement = getCurrentManager(station)
            if oldManagement >= MAX_SKILL_LEVEL then
                addStat(stats, "targetShipSkipStats", "manager already management-capped")
                if logReasonsEach() then
                    debug(string.format("  %s: manager already management-capped (%s/%s, combined=%s), skip",
                        targetLabel(station), tostring(oldManagement), tostring(MAX_SKILL_LEVEL), tostring(oldSkill)))
                    noteVerboseLogLine()
                end
            elseif C.CanControllableHaveControlEntity(station, MANAGER_POST) then
                slots[#slots + 1] = {
                    kind = "manager",
                    station = station,
                    post = MANAGER_POST,
                    managerEntity = managerEntity,
                    oldSkill = oldSkill,
                    oldManagement = oldManagement,
                }
            else
                addStat(stats, "targetShipSkipStats", "station cannot have manager")
                if logReasonsEach() then
                    debug(string.format("  %s: cannot hold manager post (skip)", targetLabel(station)))
                    noteVerboseLogLine()
                end
            end
        end
    end
    return slots, stats
end

-- Walk every ship and collect every promotable-role crew member into the
-- empire-wide pool. Each entry: { seed, container, roleid, sortPiloting,
-- sortSkill }. Raw piloting is the primary ordering key; combined assignment
-- skill is only the tie-breaker.
local function buildEmpirePool(ships, config)
    local pool = {}
    local stats = {
        donorShipSkipStats = {},
        candidateSkipStats = {},
    }
    for _, ship in ipairs(ships) do
        local allowed, configReason = isDonorShipAllowedByConfig(ship, config)
        if not allowed then
            addStat(stats, "donorShipSkipStats", compactReason(configReason))
            if logReasonsEach() then
                debug(string.format("  %s: donor config skip (%s)", shipLabel(ship), configReason))
                noteVerboseLogLine()
            end
        else
            local crew = collectCrewByRoles(ship, PROMOTABLE_ROLES)
            for _, p in ipairs(crew) do
                local candidateAllowed, candidateReason = isCandidateCrewAllowedByConfig(p, nil, config)
                if candidateAllowed then
                    p.sortPiloting = getPersonSkill(p.container, p.seed, PILOTING_SKILL)
                    p.sortSkill = C.GetPersonCombinedSkill(p.container, p.seed, nil, PILOT_POST)
                    pool[#pool + 1] = p
                else
                    addStat(stats, "candidateSkipStats", p.roleid .. " | " .. compactReason(candidateReason))
                    if logReasonsEach() then
                        debug(string.format("  %s: %s candidate skip (%s)",
                            shipLabel(ship), p.roleid, candidateReason))
                        noteVerboseLogLine()
                    end
                end
            end
        end
    end
    table.sort(pool, function(a, b)
        if a.sortPiloting ~= b.sortPiloting then
            return a.sortPiloting > b.sortPiloting
        end
        return a.sortSkill > b.sortSkill
    end)
    return pool, stats
end

local function buildManagerPoolFrom(pool)
    local managerPool = {}
    for _, p in ipairs(pool or {}) do
        p.sortManagement = getPersonSkill(p.container, p.seed, MANAGEMENT_SKILL)
        p.managerSortSkill = C.GetPersonCombinedSkill(p.container, p.seed, nil, MANAGER_POST)
        managerPool[#managerPool + 1] = p
    end
    table.sort(managerPool, function(a, b)
        if a.sortManagement ~= b.sortManagement then
            return a.sortManagement > b.sortManagement
        end
        return a.managerSortSkill > b.managerSortSkill
    end)
    return managerPool
end

-- Process one captain slot. The active reshuffle job calls this once per
-- onUpdate tick, avoiding one huge UI freeze for large fleets. For each slot,
-- walk the empire-wide pool top-down; the first unused candidate whose combined
-- assignment skill on THIS slot beats the current pilot and passes
-- AssignHiredActor(checkonly) gets the post.
--
-- `captainSlotShips` defines which ships get captain-promoted (the slot list).
-- The candidate pool is ALWAYS empire-wide (every player ship's service /
-- marine / unassigned crew), regardless of `captainSlotShips`. That's the whole
-- point of "reshuffle" vs "promote".
--
-- Capacity-aware: if the target is full, first try to move one low-value
-- service/marine from the target to the donor ship, preserving role when
-- possible, then retry the captain assignment one second later. If the donor is
-- also full, mark that donor as unusable for this slot and keep scanning.
-- Other repeated failures still bail out after MAX_FAILURES_PER_SLOT.
local MAX_FAILURES_PER_SLOT = 3

local function processReshuffleCaptainSlot(job, slot)
    local found = false
    local failuresInARow = 0
    local slotCapacityBlocked = false
    local donorsWithoutRoom = {}
    for poolIdx = 1, #job.pool do
        local cand = job.pool[poolIdx]
        local candidateIdKey = tostring(cand.seed)
        local donorShipIdKey = tostring(cand.container)
        if not job.used[candidateIdKey] and not donorsWithoutRoom[donorShipIdKey] then
            -- Construct the shipId:role key to see how many NPCs this job has
            -- already moved/planned from the same donor role bucket.
            local donorRoleKey = donorRoleCompositeKey(cand)
            local reserveUsed = job.donorRoleReservations[donorRoleKey] or 0
            local candidateAllowed, candidateReason = isCandidateCrewAllowedByConfig(cand, slot.ship, job.config, reserveUsed)
            -- GetPersonCombinedSkill looks up the NPC on their CURRENT container
            -- (cand.container), then projects skill for the requested post.
            -- Passing the destination ship here makes the engine log
            -- "Failed to retrieve NPC from person seed" 1000x per slot.
            local s = C.GetPersonCombinedSkill(cand.container, cand.seed, nil, slot.post)
            local pilotingImprovement = (tonumber(cand.sortPiloting) or -1) - (tonumber(slot.oldPiloting) or -1)
            local combinedImprovement = s - slot.oldSkill
            local minPilotingImprovement = tonumber(job.config.minPilotingImprovement) or 0
            local minCombinedImprovementPercent = tonumber(job.config.minCombinedImprovementPercent) or 0
            local combinedImprovementPercent = 100
            if slot.oldSkill > 0 then
                combinedImprovementPercent = (combinedImprovement / slot.oldSkill) * 100
            end
            if not candidateAllowed then
                addStat(job, "candidateSkipStats", cand.roleid .. " | " .. compactReason(candidateReason))
            elseif combinedImprovement <= 0 then
                addStat(job, "candidateSkipStats", cand.roleid .. " | no totalSkill improvement")
            elseif pilotingImprovement < minPilotingImprovement then
                addStat(job, "candidateSkipStats", cand.roleid .. " | below piloting improvement threshold")
            elseif combinedImprovementPercent < minCombinedImprovementPercent then
                addStat(job, "candidateSkipStats", cand.roleid .. " | below totalSkill improvement threshold")
            else
                local actor = makePersonActor(cand.container, cand.seed)

                local reason = ffi.string(C.AssignHiredActor(actor, slot.ship, slot.post, nil, true))
                if reason == "" then
                    ffi.string(C.AssignHiredActor(actor, slot.ship, slot.post, nil, false))
                    job.used[candidateIdKey] = true
                    -- Add this NPC to the shipId:role reserved map for future
                    -- reserve-threshold checks in this same reshuffle job.
                    markCandidateReserved(job, cand)
                    job.promoted = job.promoted + 1
                    logCaptainAssignment(job, slot, cand, s)
                    found = true
                    break
                elseif reason == "previouspilotbusy" then
                    job.used[candidateIdKey] = true
                    markCandidateReserved(job, cand)
                    scheduleRetry(job, slot, cand, s, BUSY_PILOT_RETRY_DELAYS[1], 2)
                    addStat(job, "retryStats", cand.roleid .. " candidate | current pilot busy")
                    if logReasonsEach() then
                        debug(string.format("    %s: current pilot busy; delayed retry queued in %ss for %s candidate",
                            shipLabel(slot.ship), tostring(BUSY_PILOT_RETRY_DELAYS[1]), cand.roleid))
                        noteVerboseLogLine()
                    end
                    found = true
                    break
                elseif reason == "nofreespace" then
                    local moved, moveReason = tryMoveOneCrewToDonor(slot.ship, cand.container)
                    if moved then
                        job.used[candidateIdKey] = true
                        -- Add this NPC to the shipId:role reserved map even
                        -- though assignment is delayed; it is already claimed.
                        markCandidateReserved(job, cand)
                        job.used[tostring(moved.seed)] = true
                        scheduleRetry(job, slot, cand, s, 1.0)
                        addStat(job, "retryStats", cand.roleid .. " candidate | spacer moved")
                        if logReasonsEach() then
                            debug(string.format("    moved %s crew from %s to donor %s as %s; delayed retry queued for %s candidate",
                                moved.roleid, shipLabel(slot.ship), shipLabel(cand.container), moved.assignedRole or moved.roleid, cand.roleid))
                            noteVerboseLogLine()
                        end
                        found = true
                        break
                    elseif moveReason == "nodonorroom" then
                        donorsWithoutRoom[donorShipIdKey] = true
                        addStat(job, "candidateSkipStats", cand.roleid .. " | no donor room for spacer crew")
                        if logReasonsEach() then
                            debug(string.format("    donor %s has no room for spacer crew; trying next donor for %s",
                                shipLabel(cand.container), shipLabel(slot.ship)))
                            noteVerboseLogLine()
                        end
                    elseif moveReason == "samecontainer" then
                        addStat(job, "candidateSkipStats", cand.roleid .. " | same-container spacer move")
                        if logReasonsEach() then
                            debug(string.format("    skip same-container candidate for %s; cannot free space by moving crew to itself",
                                shipLabel(slot.ship)))
                            noteVerboseLogLine()
                        end
                    else
                        failuresInARow = failuresInARow + 1
                        slotCapacityBlocked = true
                        addStat(job, "candidateSkipStats", cand.roleid .. " | nofreespace: " .. compactReason(moveReason))
                        if logReasonsEach() then
                            debug(string.format("    skip cand for %s (nofreespace; could not move crew to donor: %s)",
                                shipLabel(slot.ship), moveReason))
                            noteVerboseLogLine()
                        end
                        if failuresInARow >= MAX_FAILURES_PER_SLOT then
                            if logReasonsEach() then
                                debug(string.format("    %s: bailing after %d nofreespace failures",
                                    shipLabel(slot.ship), failuresInARow))
                                noteVerboseLogLine()
                            end
                            break
                        end
                    end
                else
                    failuresInARow = failuresInARow + 1
                    slotCapacityBlocked = true
                    addStat(job, "candidateSkipStats", cand.roleid .. " | capacity/incompat: " .. compactReason(reason))
                    if logReasonsEach() then
                        debug(string.format("    skip %s cand for %s (capacity/incompat: %s)",
                            cand.roleid, shipLabel(slot.ship), reason))
                        noteVerboseLogLine()
                    end
                    if failuresInARow >= MAX_FAILURES_PER_SLOT then
                        if logReasonsEach() then
                            debug(string.format("    %s: bailing after %d failures (likely at crew capacity)",
                                shipLabel(slot.ship), failuresInARow))
                            noteVerboseLogLine()
                        end
                        break
                    end
                end
            end
        end
    end
    if not found then
        if slotCapacityBlocked then
            job.skippedCapacity = job.skippedCapacity + 1
        else
            job.skippedNoCandidate = job.skippedNoCandidate + 1
        end
    end
end

local function processReshuffleManagerSlot(job, slot)
    local found = false
    local failuresInARow = 0
    local slotCapacityBlocked = false
    local donorsWithoutRoom = {}
    for poolIdx = 1, #job.managerPool do
        local cand = job.managerPool[poolIdx]
        local candidateIdKey = tostring(cand.seed)
        local donorShipIdKey = tostring(cand.container)
        if not job.used[candidateIdKey] and not donorsWithoutRoom[donorShipIdKey] then
            local donorRoleKey = donorRoleCompositeKey(cand)
            local reserveUsed = job.donorRoleReservations[donorRoleKey] or 0
            local candidateAllowed, candidateReason = isCandidateCrewAllowedByConfig(cand, nil, job.config, reserveUsed)
            local s = C.GetPersonCombinedSkill(cand.container, cand.seed, nil, slot.post)
            local combinedImprovement = s - slot.oldSkill
            local minCombinedImprovementPercent = tonumber(job.config.minCombinedImprovementPercent) or 0
            local combinedImprovementPercent = 100
            if slot.oldSkill > 0 then
                combinedImprovementPercent = (combinedImprovement / slot.oldSkill) * 100
            end

            if not candidateAllowed then
                addStat(job, "candidateSkipStats", cand.roleid .. " | " .. compactReason(candidateReason))
            elseif combinedImprovement <= 0 then
                addStat(job, "candidateSkipStats", cand.roleid .. " | no totalSkill improvement")
            elseif combinedImprovementPercent < minCombinedImprovementPercent then
                addStat(job, "candidateSkipStats", cand.roleid .. " | below totalSkill improvement threshold")
            else
                local actor = makePersonActor(cand.container, cand.seed)
                local reason = ffi.string(C.AssignHiredActor(actor, slot.station, slot.post, nil, true))
                if reason == "" then
                    ffi.string(C.AssignHiredActor(actor, slot.station, slot.post, nil, false))
                    job.used[candidateIdKey] = true
                    markCandidateReserved(job, cand)
                    job.promoted = job.promoted + 1
                    logManagerAssignment(job, slot, cand, s)
                    found = true
                    break
                elseif reason == "postoccupied" or reason == "nofreespace" then
                    -- Real X4 station edge: a just-assigned/in-flight manager can
                    -- reserve the manager post before GetComponentData("tradenpc")
                    -- exposes an arrived manager entity. In that state we cannot
                    -- move the current manager aside; treat it as this station slot
                    -- being blocked for now, not as a missing candidate.
                    local moved, moveReason = tryMoveCurrentManagerToDonor(slot, cand.container)
                    if moved then
                        job.used[candidateIdKey] = true
                        markCandidateReserved(job, cand)
                        scheduleRetry(job, slot, cand, s, 1.0)
                        addStat(job, "retryStats", cand.roleid .. " manager candidate | manager moved")
                        if logReasonsEach() then
                            debug(string.format("    moved current manager from %s to donor %s as %s; delayed retry queued for %s candidate",
                                targetLabel(slot.station), shipLabel(cand.container), moved.assignedRole or "service", cand.roleid))
                            noteVerboseLogLine()
                        end
                        found = true
                        break
                    elseif moveReason == "nodonorroom" or moveReason == "nofreespace" then
                        donorsWithoutRoom[donorShipIdKey] = true
                        slotCapacityBlocked = true
                        addStat(job, "candidateSkipStats", cand.roleid .. " | no donor room for current manager")
                        if logReasonsEach() then
                            debug(string.format("    donor %s has no room for current manager; trying next donor for %s",
                                shipLabel(cand.container), targetLabel(slot.station)))
                            noteVerboseLogLine()
                        end
                    elseif moveReason == "nomanager" then
                        slotCapacityBlocked = true
                        addStat(job, "targetShipSkipStats", "manager post occupied by pending manager")
                        if logReasonsEach() then
                            debug(string.format("    %s: manager post occupied, but no arrived manager entity yet; skip slot",
                                targetLabel(slot.station)))
                            noteVerboseLogLine()
                        end
                        break
                    else
                        failuresInARow = failuresInARow + 1
                        slotCapacityBlocked = true
                        addStat(job, "candidateSkipStats", cand.roleid .. " | manager move failed: " .. compactReason(moveReason))
                        if logReasonsEach() then
                            debug(string.format("    skip cand for %s (could not move current manager to donor: %s)",
                                targetLabel(slot.station), moveReason))
                            noteVerboseLogLine()
                        end
                    end
                elseif reason == "previouspilotbusy" then
                    job.used[candidateIdKey] = true
                    markCandidateReserved(job, cand)
                    scheduleRetry(job, slot, cand, s, BUSY_PILOT_RETRY_DELAYS[1], 2)
                    addStat(job, "retryStats", cand.roleid .. " manager candidate | current manager busy")
                    if logReasonsEach() then
                        debug(string.format("    %s: current manager busy; delayed retry queued in %ss for %s candidate",
                            targetLabel(slot.station), tostring(BUSY_PILOT_RETRY_DELAYS[1]), cand.roleid))
                        noteVerboseLogLine()
                    end
                    found = true
                    break
                else
                    failuresInARow = failuresInARow + 1
                    slotCapacityBlocked = true
                    addStat(job, "candidateSkipStats", cand.roleid .. " | manager capacity/incompat: " .. compactReason(reason))
                    if logReasonsEach() then
                        debug(string.format("    skip %s cand for %s manager slot (capacity/incompat: %s)",
                            cand.roleid, targetLabel(slot.station), reason))
                        noteVerboseLogLine()
                    end
                end

                if failuresInARow >= MAX_FAILURES_PER_SLOT then
                    if logReasonsEach() then
                        debug(string.format("    %s: bailing after %d manager assignment failure(s)",
                            targetLabel(slot.station), failuresInARow))
                        noteVerboseLogLine()
                    end
                    break
                end
            end
        end
    end
    if not found then
        if slotCapacityBlocked then
            job.skippedCapacity = job.skippedCapacity + 1
        else
            job.skippedNoCandidate = job.skippedNoCandidate + 1
        end
    end
end

local function runReshuffle(captainSlotShips, mode, config)
    if not captainSlotShips or #captainSlotShips == 0 then
        debug("Reshuffle: no slot ships, nothing to do")
        pushReshuffleMessage("Done", { 0, 0, 0 })
        return 0
    end

    config = config or defaultReshuffleConfig()
    local includeManagerTargets = config.includeStationManagers and mode == "ReshuffleAll"
    local empireShips = allPromotableShips()
    local pool, poolStats = buildEmpirePool(empireShips, config)
    local managerPool = includeManagerTargets and buildManagerPoolFrom(pool) or {}
    flushDebug()
    local slots, slotStats = buildCaptainSlots(captainSlotShips, config)
    local captainSlotCount = #slots
    local managerSlots, managerSlotStats = {}, nil
    if includeManagerTargets then
        managerSlots, managerSlotStats = buildManagerSlots(allPlayerStations())
        -- ONE job for both slot kinds: fold station skip reasons into the shared
        -- stats, and append manager slots AFTER the captain slots so the single
        -- slot pass runs captains first, then station managers -- one monotonic
        -- progress bar and one Started/Done lifecycle on the shared UI channel.
        for key, count in pairs((managerSlotStats and managerSlotStats.targetShipSkipStats) or {}) do
            addStat(slotStats, "targetShipSkipStats", key, count)
        end
        for _, mslot in ipairs(managerSlots) do
            slots[#slots + 1] = mslot
        end
    end
    debug(string.format("Reshuffle: %d captain slot ship(s), %d station manager slot(s), empire pool = %d candidate(s)",
        captainSlotCount, #managerSlots, #pool))
    pushReshuffleMessage("Started", {
        #slots,
        #pool,
        sumStatBucket(poolStats and poolStats.donorShipSkipStats),
        sumStatBucket(poolStats and poolStats.candidateSkipStats),
    })

    activeReshuffles[#activeReshuffles + 1] = {
        mode = mode,
        config = config,
        pool = pool,
        managerPool = managerPool,
        slots = slots,
        used = {},
        donorRoleReservations = {},
        donorShipSkipStats = poolStats and poolStats.donorShipSkipStats or {},
        targetShipSkipStats = slotStats and slotStats.targetShipSkipStats or {},
        candidateSkipStats = poolStats and poolStats.candidateSkipStats or {},
        assignmentStats = {},
        retryStats = {},
        groupedStatsLogged = false,
        retryTailReported = false,
        promoted = 0,
        skippedNoCandidate = 0,
        skippedCapacity = 0,
        pendingRetries = 0,
        nextSlot = 1,
        nextTime = getElapsedTime(),
        nextProgressLog = C.GetCurrentGameTime() + RESHUFFLE_PROGRESS_LOG_INTERVAL,
        -- Dispatch by slot kind. The two processors stay fully separate, but share
        -- one job: one `used` set, one pool of reservations, one UI lifecycle.
        processSlot = function(j, slot)
            if slot.kind == "manager" then
                processReshuffleManagerSlot(j, slot)
            else
                processReshuffleCaptainSlot(j, slot)
            end
        end,
    }
    if not updateRegistered then
        updateRegistered = true
        SetScript("onUpdate", onUpdate)
    end
    return nil
end

-- ============================================================================
-- Event handlers
-- ============================================================================

-- The MD stashes { target = X, others = [list] }. We return the deduped union:
-- the right-clicked target first, then any other map-selected player ships.
-- This also tolerates the sector/free-space right-click case; stale or invalid
-- ids are filtered later by isPromotableShip before touching sensitive C calls.
local function readShipsFromBlackboard()
    local data = GetNPCBlackboard(safePlayerID(), "$vas_bcp_ships")
    if type(data) ~= "table" then return nil end

    local seen = {}
    local out = {}
    local function add(v)
        if v == nil then return end
        local id = ConvertStringTo64Bit(tostring(v))
        if not id or id == 0 then return end
        local key = tostring(id)
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = id
    end

    add(data.target)
    if type(data.others) == "table" then
        for _, v in ipairs(data.others) do add(v) end
    end
    return out
end

notifyPromote = function(mode, count)
    AddUITriggeredEvent("VAS_BCP_" .. mode, tostring(count))
end

local function onPromoteSelected(_, _)
    local ok, err = pcall(function()
        debug("== PromoteSelected ==")
        local ships = readShipsFromBlackboard() or {}
        if #ships == 0 then
            debug("no ships in blackboard, aborting")
            notifyPromote("PromoteSelected", 0)
            return
        end
        local promoted = 0
        for _, ship in ipairs(ships) do
            if promoteInPlace(ship) then promoted = promoted + 1 end
        end
        debug(string.format("PromoteSelected done: %d / %d promoted", promoted, #ships))
        notifyPromote("PromoteSelected", promoted)
    end)
    if not ok then
        debug("ERROR: " .. tostring(err))
        notifyPromote("PromoteSelected", 0)
    end
    flushDebug()
end

local function onPromoteAll(_, _)
    local ok, err = pcall(function()
        debug("== PromoteAll ==")
        local ships = allPromotableShips()
        debug(string.format("walking %d promotable player ship(s)", #ships))
        local promoted = 0
        for _, ship in ipairs(ships) do
            if promoteInPlace(ship) then promoted = promoted + 1 end
        end
        debug(string.format("PromoteAll done: %d / %d promoted", promoted, #ships))
        notifyPromote("PromoteAll", promoted)
    end)
    if not ok then
        debug("ERROR: " .. tostring(err))
        notifyPromote("PromoteAll", 0)
    end
    flushDebug()
end

local function onReshuffleSelected(_, _)
    local ok, err = pcall(function()
        debug("== ReshuffleSelected ==")
        local ships = readShipsFromBlackboard() or {}
        if #ships == 0 then
            debug("no ships in blackboard, aborting")
            pushReshuffleMessage("Done", { 0, 0, 0 })
            return
        end
        runReshuffle(ships, "ReshuffleSelected")
    end)
    if not ok then
        debug("ERROR: " .. tostring(err))
        pushReshuffleMessage("Done", { 0, 0, 0 })
    end
    flushDebug()
end

local function onReshuffleAll(_, _)
    local ok, err = pcall(function()
        debug("== ReshuffleAll ==")
        runReshuffle(allPromotableShips(), "ReshuffleAll")
    end)
    if not ok then
        debug("ERROR: " .. tostring(err))
        pushReshuffleMessage("Done", { 0, 0, 0 })
    end
    flushDebug()
end

local function onConfiguredReshuffleSelected(_, _)
    local ok, err = pcall(function()
        debug("== ReshuffleSelected (configured) ==")
        local ships = readShipsFromBlackboard() or {}
        if #ships == 0 then
            debug("no ships in blackboard, aborting")
            pushReshuffleMessage("Done", { 0, 0, 0 })
            return
        end
        runReshuffle(ships, "ReshuffleSelected", readReshuffleConfig())
    end)
    if not ok then
        debug("ERROR: " .. tostring(err))
        pushReshuffleMessage("Done", { 0, 0, 0 })
    end
    flushDebug()
end

local function onConfiguredReshuffleAll(_, _)
    local ok, err = pcall(function()
        debug("== ReshuffleAll (configured) ==")
        runReshuffle(allPromotableShips(), "ReshuffleAll", readReshuffleConfig())
    end)
    if not ok then
        debug("ERROR: " .. tostring(err))
        pushReshuffleMessage("Done", { 0, 0, 0 })
    end
    flushDebug()
end

-- ============================================================================
-- Init
-- ============================================================================

RegisterEvent("VAS_BCP.PromoteSelected",  onPromoteSelected)
RegisterEvent("VAS_BCP.PromoteAll",       onPromoteAll)
RegisterEvent("VAS_BCP.ReshuffleSelected", onReshuffleSelected)
RegisterEvent("VAS_BCP.ReshuffleAll",      onReshuffleAll)
RegisterEvent("VAS_BCP.ReshuffleSelectedConfigured", onConfiguredReshuffleSelected)
RegisterEvent("VAS_BCP.ReshuffleAllConfigured",      onConfiguredReshuffleAll)
