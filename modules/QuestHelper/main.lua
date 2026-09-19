PFEXQuestHelper = {
    PANEL_WIDTH = 250,     -- 侧边面板宽度
    BUTTON_SIZE = 32,      -- 按钮大小
    BUTTON_OFFSET_X = -40, -- 按钮相对于地图右上角的X偏移
    BUTTON_OFFSET_Y = -25, -- 按钮相对于地图右上角的Y偏移
    panel = nil,
    mapButton = nil,
    isPanelOpen = false,
    TreeData = {},
    plevel = nil,
    pclass = nil,
    prace = nil,
    pfaction = nil,
    expandToId = nil,
    zone = nil,
    cacheKey = nil,      -- 上次构建TreeData时的缓存键
    skillsVersion = 0    -- 专业技能变动计数（用于缓存失效）
}




-- Same detection convention used across the ShowLoots conversion: a live
-- capability check on the provider, not a hardcoded dependency on the addon.
-- Checked fresh every call, not cached: pfExtend.toc only depends on pfQuest,
-- not on the HDB provider addon, so load order between the two isn't
-- guaranteed -- a one-time check at file-load could see pfQuestHearthDB as
-- nil and lock this module onto the (here, empty) legacy path all session.
local function HasHDB()
    return pfQuestHearthDB and type(pfQuestHearthDB.GetQuestStartPinsAsync) == "function"
        and type(pfQuestHearthDB.GetQuestEligibilityAsync) == "function"
end

-- GetQuestStartPinsAsync (called once in UpdateDatabase) already carries a
-- quest's title and which start "routes" it has (direct NPC/object talk vs.
-- item-start); both are cached here since they cost nothing extra to keep.
local questTitleCache = {}
local questStartFlagCache = {}

-- Raw start-pin rows (zone/x/y/targetKind/targetID/title/level/respawn) per
-- quest id, stashed from the same sweep. This is what lets map-pin placement
-- (see AddMapNodeHDB in browser.lua) be synchronous instead of firing a
-- GetQuestMapPinsAsync per tree node -- a zone's tree can have 100+ nodes,
-- and that's exactly the per-node-burst pattern that already crashed the
-- client twice this session (loot browser rows, then quest metadata).
local questStartPinRows = {}

-- Per-quest level/race/class/skill/event/prerequisites, from
-- GetQuestEligibilityAsync. GetQuestStartPinsAsync doesn't carry the race/class
-- masks QuestFilter needs, so this is fetched lazily per quest instead, and
-- cached since the same quest reappears across zones/sorts/re-renders.
local QUEST_NOT_FOUND = {}
local questMetaCache = {}
local questMetaPending = {}

-- A zone's full tree (root quests plus everything reachable through
-- QuestAfter) can be dozens of ids, and PrefetchQuestMeta used to fire a
-- GetQuestEligibilityAsync for every one of them in the same frame -- the
-- same pattern that crashed the client when ShowLoots's browser fired one
-- GetItemSourcesAsync per loot row on open. Serialize the actual queries
-- through this queue instead; FetchQuestMeta enqueues rather than firing
-- directly, so every caller (this prefetch, QuestFilter's opportunistic
-- fetch, FindPreUndo) is covered without needing its own throttling. Holds
-- generic jobs (not just quest ids) so the title backfill below can share it.
local workQueue = {}
local workActive = false
local workPaused = false

local function PumpWorkQueue()
    if workActive or workPaused then return end
    local job = table.remove(workQueue, 1)
    if not job then return end
    workActive = true
    job(function()
        workActive = false
        PumpWorkQueue()
    end)
end

local function QueueWork(job)
    table.insert(workQueue, job)
    PumpWorkQueue()
end

-- Pauses/resumes the queue without cancelling anything in flight or dropping
-- pending callbacks, so closing the panel mid-fetch can't leave a callback
-- waiting forever. Wired to the browser's OnHide/OnShow.
PFEXQuestHelper.SetMetaFetchPaused = function(paused)
    workPaused = paused
    if not paused then PumpWorkQueue() end
end

local function FetchQuestMeta(id, callback)
    local cached = questMetaCache[id]
    if cached ~= nil then
        callback(cached ~= QUEST_NOT_FOUND and cached or nil)
        return
    end
    if questMetaPending[id] then
        table.insert(questMetaPending[id], callback)
        return
    end
    questMetaPending[id] = { callback }

    QueueWork(function(jobDone)
        pfQuestHearthDB:GetQuestEligibilityAsync(id, function(record, err)
            local result = (not err) and record or nil
            questMetaCache[id] = result or QUEST_NOT_FOUND
            jobDone() -- release this queue slot; a title backfill below queues separately

            local function Resolve()
                local waiting = questMetaPending[id]
                questMetaPending[id] = nil
                if waiting then
                    for _, cb in ipairs(waiting) do cb(result) end
                end
            end

            -- GetQuestStartPinsAsync only carries a title for quests with a
            -- recorded, spawn-joined start location -- roughly 8% of quests
            -- have none (confirmed against the actual DB: 538 of 6701),
            -- concentrated in auto-offered chain follow-ups, i.e. exactly
            -- what QuestAfter pulls into a tree. Those never got a
            -- questTitleCache entry from the pins sweep and would otherwise
            -- show "Unknown" forever despite having valid quest_meta data.
            -- Backfill from quest_text directly, only for the ids that
            -- actually need it, still through this same serial queue.
            if result and not questTitleCache[id] then
                QueueWork(function(titleJobDone)
                    pfQuestHearthDB:GetQuestTextAsync(id, function(textRecord, textErr)
                        if not textErr and textRecord and textRecord.title then
                            questTitleCache[id] = textRecord.title
                        end
                        titleJobDone()
                        Resolve()
                    end)
                end)
            else
                Resolve()
            end
        end)
    end)
end

-- Fetches metadata for a batch of quest ids and calls back once every one of
-- them has resolved (or is already cached). Used to prime the cache for a
-- whole tree before QuestChainBuilder walks it synchronously.
local function PrefetchQuestMeta(idList, callback)
    local pending = table.getn(idList)
    if pending == 0 then callback(); return end
    local done = false
    for _, id in ipairs(idList) do
        FetchQuestMeta(id, function()
            pending = pending - 1
            if pending == 0 and not done then
                done = true
                callback()
            end
        end)
    end
end

-- Pure local walk over the already-resident QuestAfter graph: everything
-- reachable forward from the zone's quest list, i.e. every id the tree
-- builder could touch. No DB access -- QuestAfter is built once up front.
local function CollectTreeQuestIDs(questList)
    local seen, result = {}, {}
    local function Walk(id)
        if seen[id] then return end
        seen[id] = true
        table.insert(result, id)
        local after = PfExtend_Database["QuestHelper"]["QuestAfter"][id]
        if after then
            for _, nextId in ipairs(after) do
                Walk(nextId)
            end
        end
    end
    for _, id in ipairs(questList) do
        Walk(id)
    end
    return result
end

-- Exposed for chainviewer.lua, which builds a chain tree from a single click
-- (outside the OnMapChange flow) and needs the same "prefetch before building"
-- sequencing.
PFEXQuestHelper.HasHDB = HasHDB
PFEXQuestHelper.CollectTreeQuestIDs = CollectTreeQuestIDs
PFEXQuestHelper.PrefetchQuestMeta = PrefetchQuestMeta
PFEXQuestHelper.QueueWork = QueueWork

-- browser.lua's AddMapNodeHDB reads this directly (synchronous, no query)
-- to place start-location pins.
PFEXQuestHelper.GetQuestStartPinRows = function(id)
    return questStartPinRows[id]
end

PFEXQuestHelper.GetQuestTitle = function(id)
    if questTitleCache[id] then return questTitleCache[id] end
    if pfDB and pfDB.quests and pfDB.quests.loc and pfDB.quests.loc[id] then
        return pfDB.quests.loc[id]["T"]
    end
    return nil
end

local items, units, objects, quests, zones, refloot, itemreq, areatrigger, professions
PFEXQuestHelper.Reload = function()
    items = pfDB["items"]["data"]
    units = pfDB["units"]["data"]
    objects = pfDB["objects"]["data"]
    quests = pfDB["quests"]["data"]
    zones = pfDB["zones"]["data"]
    refloot = pfDB["refloot"]["data"]
    itemreq = pfDB["quests-itemreq"]["data"]
    areatrigger = pfDB["areatrigger"]["data"]
    professions = pfDB["professions"]["loc"]
    if PfExtend_Database["QuestHelper"] == nil then
        PfExtend_Database["QuestHelper"] = {
            ["QuestZoneData"] = {},
            ["ZoneQuestData"] = {},
            ["QuestAfter"] = {},
            ["updated"] = false,
            ["version"] = nil,
        };
    end
    -- Defensive per-field, not just on the outer table: a saved table from a
    -- shape predating one of these fields would otherwise skip the block
    -- above entirely (it already exists) and leave that field nil, which
    -- every direct index into it downstream assumes never happens.
    local qh = PfExtend_Database["QuestHelper"]
    if qh["QuestZoneData"] == nil then qh["QuestZoneData"] = {} end
    if qh["ZoneQuestData"] == nil then qh["ZoneQuestData"] = {} end
    if qh["QuestAfter"] == nil then qh["QuestAfter"] = {} end
end

PFEXQuestHelper.Reload()

PFEXQuestHelper.GetPlayerData = function()
    PFEXQuestHelper.plevel = UnitLevel("player")
    local pfaction = UnitFactionGroup("player")
    if pfaction == "Horde" then
        PFEXQuestHelper.pfaction = "H"
    elseif pfaction == "Alliance" then
        PFEXQuestHelper.pfaction = "A"
    else
        PFEXQuestHelper.pfaction = "GM"
    end
    local _, race = UnitRace("player")
    PFEXQuestHelper.prace = pfDatabase:GetBitByRace(race)
    local _, class = UnitClass("player")
    PFEXQuestHelper.pclass = pfDatabase:GetBitByClass(class)
end

PFEXQuestHelper.FindPreUndo = function(id)
    local pre
    if HasHDB() then
        local meta = questMetaCache[id]
        if meta and meta ~= QUEST_NOT_FOUND and table.getn(meta.prerequisites) > 0 then
            pre = meta.prerequisites
        end
    elseif quests[id]["pre"] then
        pre = quests[id]["pre"]
    end

    if pre then
        local one_complete = nil
        local level = 0
        local thislevel = 0
        for _, prequest in pairs(pre) do
            thislevel = 1
            if not pfQuest_history[prequest] then
                local flag = PFEXQuestHelper.QuestFilter(prequest)
                thislevel = 2
                if not flag.WRONGRACE and not flag.WRONGCLASS then
                    thislevel = 3
                end
            end
            if thislevel > level then
                one_complete = prequest
                level = thislevel
            end
        end
        if one_complete and PfExtend_Database["QuestHelper"]["QuestZoneData"][one_complete] ~= {} then
            return one_complete, PfExtend_Database["QuestHelper"]["QuestZoneData"][one_complete][1]
        end
    end
end



PFEXQuestHelper.QuestFilter = function(id)
    local ret = {
        min = 999,             --最低等级
        lvl = 999,             --等级
        DOING = false,         --正在做的
        FINISHED = false,      --完成的
        AFTERFINISHED = false, --后续全部完成或无后续任务的
        UNKNOWN = false,       --数据损坏的或未知的
        HASPRE = false,        --有前置
        UNDOPRE = false,       --前置没做
        WRONGRACE = false,     --种族不对
        WRONGCLASS = false,    --职业不对
        WRONGSKILL = false,    --专业不对
        WRONGFACTION = false,  --阵营不对
        LOWLEVEL = false,      --等级不够
        EVENT = false,         --事件任务
        STARTUNIT = false,     --从生物接取
        STARTOBJECT = false,   --从实体单位接取
        STARTITEM = false,     --从物品接取
    }

    if HasHDB() then
        local meta = questMetaCache[id]
        if meta == nil then
            -- Not prefetched (e.g. a prerequisite outside the displayed
            -- tree, reached via FindPreUndo). Kick off a fetch so it's ready
            -- next time; this call itself has to report something now.
            FetchQuestMeta(id, function() end)
            ret.UNKNOWN = true
            return ret
        end
        if meta == QUEST_NOT_FOUND then ret.UNKNOWN = true return ret end

        if meta.level and meta.level ~= "" then ret.lvl = tonumber(meta.level) end
        if meta.minLevel and meta.minLevel ~= "" then
            ret.min = tonumber(meta.minLevel)
            if ret.min > PFEXQuestHelper.plevel then ret.LOWLEVEL = true end
        end
        if pfQuest.questlog[id] then ret.DOING = true end
        if pfQuest_history[id] then ret.FINISHED = true end
        if not PFEXQuestHelper.GetQuestTitle(id) then ret.UNKNOWN = true end
        if table.getn(meta.prerequisites) > 0 then
            ret.HASPRE = true
            local one_complete = nil
            for _, prequest in ipairs(meta.prerequisites) do
                if pfQuest_history[prequest] then
                    one_complete = true
                end
            end
            if not one_complete then ret.UNDOPRE = true end
        end
        local raceMask = tonumber(meta.raceMask)
        local classMask = tonumber(meta.classMask)
        if raceMask and not (bit.band(raceMask, PFEXQuestHelper.prace) == PFEXQuestHelper.prace) then ret.WRONGRACE = true end
        if classMask and not (bit.band(classMask, PFEXQuestHelper.pclass) == PFEXQuestHelper.pclass) then ret.WRONGCLASS = true end
        if meta.skill and meta.skill ~= "" and not pfDatabase:GetPlayerSkill(meta.skill) then ret.WRONGSKILL = true end
        if meta.event and meta.event ~= "" then ret.EVENT = true end

        -- Faction is already applied when the zone index is built (HDB is
        -- queried scoped to the player's own faction in UpdateDatabase), so
        -- an entry that made it into the index is reachable by construction;
        -- there's no separate WRONGFACTION signal left to recompute here.
        local flags = questStartFlagCache[id]
        if flags then
            ret.STARTUNIT = flags.U
            ret.STARTOBJECT = flags.O
            ret.STARTITEM = flags.I
        end
        return ret
    end

    if not quests[id] then ret.UNKNOWN = true return ret end

    if quests[id]["lvl"] then ret.lvl = quests[id]["lvl"] end
    if quests[id]["min"] then ret.min = quests[id]["min"] end
    if pfQuest.questlog[id] then ret.DOING = true end
    if pfQuest_history[id] then ret.FINISHED = true end
    if not pfDB.quests.loc[id] or not pfDB.quests.loc[id].T then ret.UNKNOWN = true end
    if quests[id]["pre"] then
        ret.HASPRE = true
        local one_complete = nil
        for _, prequest in pairs(quests[id]["pre"]) do
            if pfQuest_history[prequest] then
                one_complete = true
            end
        end
        if not one_complete then ret.UNDOPRE = true end
    end
    if quests[id]["race"] and not (bit.band(quests[id]["race"], PFEXQuestHelper.prace) == PFEXQuestHelper.prace) then ret.WRONGRACE = true end
    if quests[id]["class"] and not (bit.band(quests[id]["class"], PFEXQuestHelper.pclass) == PFEXQuestHelper.pclass) then ret.WRONGCLASS = true end
    if quests[id]["skill"] and not pfDatabase:GetPlayerSkill(quests[id]["skill"]) then ret.WRONGSKILL = true end
    if quests[id]["min"] and quests[id]["min"] > PFEXQuestHelper.plevel then ret.LOWLEVEL = true end
    if quests[id]["event"] then ret.EVENT = true end
    if quests[id]["start"] then
        if quests[id]["start"]["U"] then
            for _, unit in pairs(quests[id]["start"]["U"]) do
                if units[unit] and units[unit]["fac"] and not strfind(units[unit]["fac"], PFEXQuestHelper.pfaction) then
                    ret.WRONGFACTION = true;
                end
            end
            ret.STARTUNIT = true;
        end
        if quests[id]["start"]["O"] then
            for _, object in pairs(quests[id]["start"]["O"]) do
                if objects[object] and objects[object]["fac"] and not strfind(objects[object]["fac"], PFEXQuestHelper.pfaction) then
                    ret.WRONGFACTION = true;
                end
            end
            ret.STARTOBJECT = true;
        end
        if quests[id]["start"]["I"] then
            ret.STARTITEM = true;
        end
    end
    return ret
end

-- 根据任务状态flag生成带颜色标签的显示文本（Browser与任务链窗口共用）
PFEXQuestHelper.FormatQuestText = function(flag, id)
    local color, tag

    if flag.UNKNOWN then
        return "|cff9d9d9dUnknown|r"
    elseif flag.FINISHED and not flag.AFTERFINISHED then
        color = "|cffffff2b"
        tag = pfExtend_Loc["QuestHelper_FLAG_Finished"]
    elseif flag.FINISHED and flag.AFTERFINISHED then
        color = "|cff5a5a5a"
        tag = pfExtend_Loc["QuestHelper_FLAG_Finished"]
    elseif flag.DOING then
        color = "|cff3eff2b"
        tag = pfExtend_Loc["QuestHelper_FLAG_Active"]
    elseif flag.WRONGRACE then
        color = "|cff5a5a5a"
        tag = pfExtend_Loc["QuestHelper_FLAG_Race"]
    elseif flag.WRONGCLASS then
        color = "|cff5a5a5a"
        tag = pfExtend_Loc["QuestHelper_FLAG_Class"]
    elseif flag.WRONGSKILL then
        color = "|cff5a5a5a"
        tag = pfExtend_Loc["QuestHelper_FLAG_Skill"]
    elseif flag.EVENT then
        color = "|cff2b3eff"
        tag = pfExtend_Loc["QuestHelper_FLAG_Event"]
    elseif flag.UNDOPRE then
        color = "|cffff2b2b"
        tag = pfExtend_Loc["QuestHelper_FLAG_Prereq"]
    elseif flag.LOWLEVEL then
        color = "|cffff2b2b"
        tag = pfExtend_Loc["QuestHelper_FLAG_High-Level"]
    elseif flag.STARTITEM then
        color = "|cffffff2b"
        tag = pfExtend_Loc["QuestHelper_FLAG_Hidden"]
    else
        color = "|cffffff2b"
        tag = pfExtend_Loc["QuestHelper_FLAG_Available"]
    end

    local title = PFEXQuestHelper.GetQuestTitle(id)
    if title then
        return color .. tag .. "  " .. title
    end
    return "|cff9d9d9dUnknown|r"
end

PFEXQuestHelper.ReadCoords = function(id, type)
    local ret = {};
    local data = {
        ["U"] = units,
        ["V"] = units,
        ["O"] = objects
    };

    if data[type][id] and data[type][id]["coords"] then
        for k, v in pairs(data[type][id]["coords"]) do
            table.insert(ret, v[3])
        end
    end
    return table.unique(ret)
end

PFEXQuestHelper.GetStartZones = function(id)
    local ret = {}
    if quests[id]["start"] then
        if quests[id]["start"]["U"] then
            for _, unit in pairs(quests[id]["start"]["U"]) do
                for _, v in ipairs(PFEXQuestHelper.ReadCoords(unit, "U")) do
                    table.insert(ret, v)
                end
            end
        end
        if quests[id]["start"]["O"] then
            for _, object in pairs(quests[id]["start"]["O"]) do
                for _, v in ipairs(PFEXQuestHelper.ReadCoords(object, "O")) do
                    table.insert(ret, v)
                end
            end
        end
        if quests[id]["start"]["I"] then
            for _, item in pairs(quests[id]["start"]["I"]) do --V,U,O,R
                if items[item] then
                    for lootType, lootSources in pairs(items[item]) do
                        if lootType == "R" then
                            for id, chance in pairs(lootSources) do
                                if refloot[id] then
                                    for refLootType, refLootSources in pairs(refloot[id]) do
                                        for refId, _ in pairs(refLootSources) do
                                            for _, v in ipairs(PFEXQuestHelper.ReadCoords(refId, refLootType)) do
                                                table.insert(ret, v)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                        if lootType == "V" or lootType == "U" or lootType == "O" then
                            for id, chance in pairs(lootSources) do
                                for _, v in ipairs(PFEXQuestHelper.ReadCoords(id, lootType)) do
                                    table.insert(ret, v)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return table.unique(ret)
end

-- Builds QuestZoneData/ZoneQuestData/QuestAfter from a single
-- GetQuestStartPinsAsync sweep instead of walking the whole quest+item+unit
-- database: the "resolved_start" query on the provider side already expands
-- item-start quests through their loot sources, so this only needs to fold
-- its rows into the same three indexes the legacy walk built by hand.
-- Scoped to the player's own faction/masks disabled (0), matching the
-- original's "build the full static index once" shape -- WRONGRACE/CLASS
-- stay QuestFilter's job, applied per player state at render time.
PFEXQuestHelper.UpdateDatabaseHDB = function()
    local faction = PFEXQuestHelper.pfaction == "H" and "H" or "A"
    local accepted = pfQuestHearthDB:GetQuestStartPinsAsync({
        raceMask = 0, classMask = 0, faction = faction,
        includeAllLevels = true, includeLow = true, includeEvents = true,
    }, function(pins, err)
        if err or not pins then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080" .. pfExtend_Loc["Update_Error_Hint"]);
            return
        end

        local zoneSets = {}
        local seenPrereqEdge = {}
        wipe(PfExtend_Database["QuestHelper"]["QuestAfter"])
        wipe(questStartFlagCache)
        wipe(questStartPinRows)

        for _, pin in ipairs(pins) do
            local qid = pin.questID
            questTitleCache[qid] = pin.quest

            zoneSets[qid] = zoneSets[qid] or {}
            if pin.zoneID then zoneSets[qid][pin.zoneID] = true end

            if pin.zoneID and pin.x and pin.y then
                if questStartPinRows[qid] == nil then questStartPinRows[qid] = {} end
                table.insert(questStartPinRows[qid], {
                    zoneID = pin.zoneID, x = pin.x, y = pin.y,
                    targetKind = pin.targetKind, targetID = pin.targetID,
                    title = pin.title, level = pin.level, respawn = pin.respawn,
                })
            end

            local flags = questStartFlagCache[qid]
            if not flags then
                flags = { U = false, O = false, I = false }
                questStartFlagCache[qid] = flags
            end
            if pin.originKind == "I" then
                flags.I = true
            elseif pin.originKind == pin.targetKind and pin.targetKind == "U" then
                flags.U = true
            elseif pin.originKind == pin.targetKind and pin.targetKind == "O" then
                flags.O = true
            end

            -- GROUP_CONCAT gives the same string on every pin row for this
            -- quest; only fold it into QuestAfter once per quest id.
            if pin.prerequisites and not seenPrereqEdge[qid] then
                seenPrereqEdge[qid] = true
                for prereq in string.gfind(pin.prerequisites, "[^,]+") do
                    local prereqId = tonumber(prereq)
                    if prereqId then
                        local after = PfExtend_Database["QuestHelper"]["QuestAfter"]
                        if after[prereqId] == nil then after[prereqId] = {} end
                        if not table.contain(after[prereqId], qid) then
                            table.insert(after[prereqId], qid)
                        end
                    end
                end
            end
        end

        local questZoneData, zoneQuestData = {}, {}
        for qid, zoneSet in pairs(zoneSets) do
            local zoneList = {}
            for zoneId in pairs(zoneSet) do table.insert(zoneList, zoneId) end
            questZoneData[qid] = zoneList
            local multiNum = table.getn(zoneList)
            for _, zoneId in ipairs(zoneList) do
                if zoneQuestData[zoneId] == nil then zoneQuestData[zoneId] = {} end
                zoneQuestData[zoneId][qid] = multiNum
            end
        end

        PfExtend_Database["QuestHelper"]["QuestZoneData"] = questZoneData
        PfExtend_Database["QuestHelper"]["ZoneQuestData"] = zoneQuestData
        PfExtend_Database["QuestHelper"]["updated"] = true
        PFEXQuestHelper.cacheKey = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080" .. pfExtend_Loc["Update_Success_Hint"])

        -- This is a single unfiltered sweep of the whole quest database, so
        -- it can easily still be running when the player opens the map right
        -- after login -- OnMapChange would then cache an empty tree built
        -- before any data existed, and nothing would ever rebuild it since
        -- the cache key alone doesn't know the data was incomplete. Rebuild
        -- now if the panel is already open instead of waiting for the next
        -- zone change to notice the cache was cleared above.
        if PFEXQuestHelper.Browser and PFEXQuestHelper.Browser:IsShown() then
            PFEXQuestHelper.OnMapChange()
        end
    end)

    if not accepted then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080" .. pfExtend_Loc["Update_Error_Hint"]);
        return false;
    end
    return true;
end

PFEXQuestHelper.UpdateDatabase = function()
    if HasHDB() then return PFEXQuestHelper.UpdateDatabaseHDB() end

    if pfDB == nil or (pfDB["zones"]["data"] == nil and pfDB["quests"]["data"] == nil) then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080" .. pfExtend_Loc["Update_Error_Hint"]);
        return false;
    end

    for questId, data in pairs(quests) do
        local questInWhatZone = PFEXQuestHelper.GetStartZones(questId)
        local multiNum = table.getn(questInWhatZone);
        PfExtend_Database["QuestHelper"]["QuestZoneData"][questId] = questInWhatZone;
        for _, zone in pairs(questInWhatZone) do
            if PfExtend_Database["QuestHelper"]["ZoneQuestData"][zone] == nil then
                PfExtend_Database["QuestHelper"]["ZoneQuestData"][zone] = {}
            end
            PfExtend_Database["QuestHelper"]["ZoneQuestData"][zone][questId] = multiNum;
        end
        if PfExtend_Database["QuestHelper"]["QuestAfter"][questId] == nil then PfExtend_Database["QuestHelper"]["QuestAfter"][questId] = {} end
        if data["pre"] then
            for _, pre in pairs(data["pre"]) do
                if PfExtend_Database["QuestHelper"]["QuestAfter"][pre] == nil then PfExtend_Database["QuestHelper"]["QuestAfter"][pre] = {} end
                if not table.contain(PfExtend_Database["QuestHelper"]["QuestAfter"][pre], questId) then
                    table.insert(PfExtend_Database["QuestHelper"]["QuestAfter"][pre], questId)
                end
            end
        end
    end
    PfExtend_Database["QuestHelper"]["LootData"] = db;
    PfExtend_Database["QuestHelper"]["updated"] = true;
    PFEXQuestHelper.cacheKey = nil; -- 数据库重建后使缓存失效
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080" .. pfExtend_Loc["Update_Success_Hint"])
    return true;
end



PFEXQuestHelper.findZoneByLocation = function(location)
    if zones[location] then
        return zones[location][1]
    end
end
PFEXQuestHelper.findLocationByZone = function(Zone)
    local ret = {}
    for k, v in pairs(zones) do
        if v[1] == Zone then
            table.insert(ret, k)
        end
    end
    return table.unique(ret)
end


















local function MapToggleButtonOnClick()

end







PFEXQuestHelper.MapToggleButton = CreateFrame("Button", "PFEXQuestHelperMapToggleButton", WorldMapFrame,
    "UIPanelButtonTemplate")
PFEXQuestHelper.MapToggleButton:SetWidth(40)
PFEXQuestHelper.MapToggleButton:SetHeight(40)
PFEXQuestHelper.MapToggleButton:SetFont(STANDARD_TEXT_FONT, 24)
PFEXQuestHelper.MapToggleButton:SetPoint("TOPLEFT", WorldMapFrame, "TOPRIGHT", 0, 0)
PFEXQuestHelper.MapToggleButton:SetText("QH")
PFEXQuestHelper.MapToggleButton:Show()
PFEXQuestHelper.MapToggleButton:SetScript("OnClick", function()
    PFEXQuestHelper.Browser:Show()
    PFEXQuestHelper.MapToggleButton:Hide()
end)
pfUI.api.SkinButton("PFEXQuestHelperMapToggleButton")


function PFEXQuestHelper.QuestChainBuilder(questList)
    local QuestAfter = PfExtend_Database["QuestHelper"]["QuestAfter"]
    local processed = {}
    local roots = {}
    local hasParent = {}
    local hide = {
        class = PfExtend_Global.ReadSetting("QuestHelper", "hideClass"),
        race = PfExtend_Global.ReadSetting("QuestHelper", "hideRace"),
        skill = PfExtend_Global.ReadSetting("QuestHelper", "hideSkill"),
        event = PfExtend_Global.ReadSetting("QuestHelper", "hideEvent")
    }
    -- 第一遍：标记父节点
    local function MarkParents(id)
        if processed[id] then return end

        processed[id] = true

        local after = QuestAfter[id]
        if after then
            for _, nextId in ipairs(after) do
                hasParent[nextId] = true
                MarkParents(nextId)
            end
        end
    end

    for _, id in ipairs(questList) do
        MarkParents(id)
    end

    for _, id in ipairs(questList) do
        if not hasParent[id] then
            table.insert(roots, id)
        end
    end

    if table.countNum(roots) == 0 and table.countNum(questList) > 0 then
        table.insert(roots, questList[1])
    end

    wipe(processed)

    -- 构建树结构
    local function BuildNode(id)
        if processed[id] then
            return nil
        end

        processed[id] = true

        local node = {
            id = id,
            flag = PFEXQuestHelper.QuestFilter(id),
            children = {},
        }
        if node.flag.WRONGCLASS and hide.class then return nil end
        if node.flag.WRONGRACE and hide.race then return nil end
        if node.flag.WRONGSKILL and hide.skill then return nil end
        if node.flag.EVENT and hide.event then return nil end
        local after = QuestAfter[id]
        if after then
            for _, nextId in ipairs(after) do
                local child = BuildNode(nextId)
                if child then
                    table.insert(node.children, child)
                end
            end
        end

        return node
    end

    local result = {}
    for _, rootId in ipairs(roots) do
        wipe(processed)
        local tree = BuildNode(rootId)
        if tree then
            table.insert(result, tree)
        end
    end

    -- 自底向上计算 AFTERFINISHED
    local function CalculateAfterFinished(node)
        local allChildrenFinished = true
        local hasChildren = table.countNum(node.children) > 0

        for _, child in ipairs(node.children) do
            CalculateAfterFinished(child)
            if not child.flag.AFTERFINISHED then
                allChildrenFinished = false
            end
        end

        if not hasChildren then
            node.flag.AFTERFINISHED = node.flag.FINISHED or node.flag.WRONGSKILL or node.flag.WRONGCLASS or
                node.flag.WRONGRACE
        else
            node.flag.AFTERFINISHED = (node.flag.FINISHED or node.flag.WRONGSKILL or node.flag.WRONGCLASS or node.flag.WRONGRACE) and
                allChildrenFinished
        end
    end

    for _, tree in ipairs(result) do
        CalculateAfterFinished(tree)
    end

    -- 优先级位定义（从前到后，前面的优先级高，对应低位）
    local PRIORITY = {
        HAS_PRE     = 1,   -- 00000001  有前置（倒数第八）
        FINISHED    = 2,   -- 00000010  已完成（倒数第七）
        AFTER_FIN   = 4,   -- 00000100  后续全完成（倒数第六）
        EVENT       = 8,   -- 00001000  事件任务（倒数第五）
        WRONG_SKILL = 16,  -- 00010000  专业不对（倒数第四）
        WRONG_CLASS = 32,  -- 00100000  职业不对（倒数第三）
        WRONG_RACE  = 64,  -- 01000000  种族不对（倒数第二）
        UNKNOWN     = 128, -- 10000000  数据损坏（最后）
    }

    -- 计算优先级分数（位运算组合）
    local function GetPriorityScore(flag, hasPre)
        local score = 0

        if hasPre then
            score = bit.bor(score, PRIORITY.HAS_PRE)
        end
        if flag.FINISHED then
            score = bit.bor(score, PRIORITY.FINISHED)
        end
        if flag.AFTERFINISHED then
            score = bit.bor(score, PRIORITY.AFTER_FIN)
        end
        if flag.EVENT then
            score = bit.bor(score, PRIORITY.EVENT)
        end
        if flag.WRONGSKILL then
            score = bit.bor(score, PRIORITY.WRONG_SKILL)
        end
        if flag.WRONGCLASS then
            score = bit.bor(score, PRIORITY.WRONG_CLASS)
        end
        if flag.WRONGRACE then
            score = bit.bor(score, PRIORITY.WRONG_RACE)
        end
        if flag.UNKNOWN then
            score = bit.bor(score, PRIORITY.UNKNOWN)
        end

        return score
    end

    -- 对树进行层级排序
    local function SortTree(node, hasPre)
        -- 先递归排序子节点（子节点都有前置）
        for _, child in ipairs(node.children) do
            SortTree(child, true)
        end

        -- 对当前节点的子节点进行排序
        if table.countNum(node.children) > 1 then
            table.sort(node.children, function(a, b)
                local scoreA = GetPriorityScore(a.flag, true) -- 子节点都有前置
                local scoreB = GetPriorityScore(b.flag, true)

                -- 优先级不同，按优先级（分数小的在前）
                if scoreA ~= scoreB then
                    return scoreA < scoreB
                end

                -- 同优先级按等级从小到大
                local lvlA = a.flag.lvl or 999
                local lvlB = b.flag.lvl or 999
                return lvlA < lvlB
            end)
        end
    end

    -- 对所有树进行排序
    for _, tree in ipairs(result) do
        SortTree(tree, false)
    end

    -- 对根节点列表本身也进行排序（根节点没有前置）
    if table.countNum(result) > 1 then
        table.sort(result, function(a, b)
            local scoreA = GetPriorityScore(a.flag, false) -- 根节点无前置
            local scoreB = GetPriorityScore(b.flag, false)

            if scoreA ~= scoreB then
                return scoreA < scoreB
            end

            local lvlA = a.flag.lvl or 999
            local lvlB = b.flag.lvl or 999
            return lvlA < lvlB
        end)
    end

    return result
end

-- 任务日志指纹（接取/放弃任务会改变）
local function GetQuestLogFingerprint()
    local count, sum = 0, 0
    for id in pairs(pfQuest.questlog) do
        -- pfQuest.questlog can carry non-numeric bookkeeping keys alongside
        -- quest ids on this build; only real quest ids count toward the
        -- fingerprint, and a stray key just gets left out of it.
        local numericId = tonumber(id)
        if numericId then
            count = count + 1
            sum = sum + numericId
        end
    end
    return count .. ":" .. sum
end

-- 已完成任务数量（完成任务只会增长）
local function GetHistoryCount()
    local count = 0
    for _ in pairs(pfQuest_history) do count = count + 1 end
    return count
end

-- 构建缓存键：任何影响列表结果的因素变动都会导致键变化
PFEXQuestHelper.BuildCacheKey = function(zone)
    return table.concat({
        zone or 0,
        PFEXQuestHelper.plevel or 0,
        PFEXQuestHelper.pfaction or "",
        PFEXQuestHelper.prace or 0,
        PFEXQuestHelper.pclass or 0,
        PFEXQuestHelper.skillsVersion,
        PfExtend_Database["QuestHelper"]["version"] or "",
        tostring(PfExtend_Global.ReadSetting("QuestHelper", "hideClass")),
        tostring(PfExtend_Global.ReadSetting("QuestHelper", "hideRace")),
        tostring(PfExtend_Global.ReadSetting("QuestHelper", "hideSkill")),
        tostring(PfExtend_Global.ReadSetting("QuestHelper", "hideEvent")),
        GetQuestLogFingerprint(),
        GetHistoryCount(),
    }, "|")
end

PFEXQuestHelper.OnMapChange = function()
    -- 面板未显示时不做任何构建（打开面板时OnShow会触发本函数）
    if not PFEXQuestHelper.Browser or not PFEXQuestHelper.Browser:IsShown() then return end
    PFEXQuestHelper.GetPlayerData()
    PFEXQuestHelper.zone = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())

    -- 缓存键未变化则直接复用上次的树，避免重复构建
    local key = PFEXQuestHelper.BuildCacheKey(PFEXQuestHelper.zone)
    if PFEXQuestHelper.cacheKey == key and PFEXQuestHelper.TreeData then
        return
    end
    PFEXQuestHelper.cacheKey = key

    local questList = {}
    local z2q = PfExtend_Database["QuestHelper"]["ZoneQuestData"]
    if z2q[PFEXQuestHelper.zone] then
        for k, _ in pairs(z2q[PFEXQuestHelper.zone]) do
            table.insert(questList, k)
        end
    end
    local locations = PFEXQuestHelper.findLocationByZone(PFEXQuestHelper.zone)

    for _, location in pairs(locations) do
        if z2q[location] then
            for k, _ in pairs(z2q[location]) do
                table.insert(questList, k)
            end
        end
    end
    questList = table.unique(questList)

    local requestKey = key
    local function BuildAndShow()
        -- The zone can change again while metadata is still in flight; a
        -- tree built for a request that's no longer current is stale.
        if PFEXQuestHelper.cacheKey ~= requestKey then return end
        PFEXQuestHelper.TreeData = PFEXQuestHelper.QuestChainBuilder(questList);
        PFEXQuestHelper.Browser:BuildTree(PFEXQuestHelper.TreeData)
    end

    if HasHDB() then
        -- QuestChainBuilder calls QuestFilter synchronously while recursing,
        -- so every id it could touch (the zone's quests plus everything
        -- reachable forward through QuestAfter) needs its metadata cached
        -- before the tree gets built, not looked up as it goes.
        PrefetchQuestMeta(CollectTreeQuestIDs(questList), BuildAndShow)
    else
        BuildAndShow()
    end
end





local frame = CreateFrame("Frame")
PFEXQuestHelper.OnLoad = function()

end
local zone, last_zone

PFEXQuestHelper.OnEvent = function(event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
    if (event == "SKILL_LINES_CHANGED" or event == "CHAT_MSG_SKILL") then
        -- 专业技能变动会使缓存失效（下次打开地图时重建）
        -- 注意：即使模块当前被禁用也要计数，避免重新启用后用到过期缓存
        PFEXQuestHelper.skillsVersion = PFEXQuestHelper.skillsVersion + 1
        return
    end
    if not PfExtend_Global.ReadSetting("QuestHelper", "enable") then
        if PFEXQuestHelper.MapToggleButton then
            PFEXQuestHelper.MapToggleButton:Hide()
        end
        if PFEXQuestHelper.Browser then
            PFEXQuestHelper.Browser:Hide()
        end
        return
    else
        if PFEXQuestHelper.MapToggleButton:IsShown() and PFEXQuestHelper.Browser:IsShown() then
            PFEXQuestHelper.MapToggleButton:Hide()
        elseif not (PFEXQuestHelper.MapToggleButton:IsShown() or PFEXQuestHelper.Browser:IsShown()) then
            PFEXQuestHelper.MapToggleButton:Show()
        end
    end
    zone = GetCurrentMapZone()
    if (event == "PLAYER_ENTERING_WORLD") then
        PFEXQuestHelper.Reload()
        PFEXQuestHelper.GetPlayerData()
        local version = PfExtend_Config_Template["About"].Version().text
        version = version .. "|" .. tostring(GetAddOnMetadata("pfQuest-octo", "Version") or "nopack")
        if HasHDB() then
            -- Gate on questStartPinRows, not on PfExtend_Database's own
            -- updated/version/ZoneQuestData flags: this session already
            -- caught PfExtend_Database (a SavedVariable) retaining old field
            -- values in ways this addon's own reset code doesn't fully
            -- explain (see the itemNameData self-healing fix in ShowLoots).
            -- Concretely: ZoneQuestData from an earlier session looked
            -- populated enough to skip the rebuild, so questStartPinRows --
            -- added in a later pass -- never got populated this session even
            -- though the quest tree still rendered fine from the leftover
            -- data. questStartPinRows is a plain session-local Lua table, not
            -- a SavedVariable, so it cannot carry that same stale state
            -- across a reload -- empty reliably means "not swept yet this
            -- session" without re-running the sweep on every zone change.
            if next(questStartPinRows) == nil then
                PFEXQuestHelper.UpdateDatabase();
            end
            PfExtend_Database["QuestHelper"]["version"] = version
        elseif not PfExtend_Database["QuestHelper"]["updated"] or PfExtend_Database["QuestHelper"]["version"] ~= version then
            -- Legacy path: the full Lua-table walk is genuinely expensive,
            -- so skipping it when nothing changed is worth keeping here.
            PFEXQuestHelper.UpdateDatabase();
            PfExtend_Database["QuestHelper"]["version"] = version
        end
    elseif (event == "WORLD_MAP_UPDATE" and last_zone ~= zone) then
        last_zone = zone;
        PFEXQuestHelper.OnMapChange()
    end
end
