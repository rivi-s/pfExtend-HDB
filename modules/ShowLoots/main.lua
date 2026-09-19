PfExtend_Database["ShowLoots"] = {
    ["LootData"] = {},
    ["itemQualityData"] = {},
    ["itemNameData"] = {},
    ["updated"] = false,
    ["version"] = nil
};

PFEXShowLoots = {
    LootListShown = {},
    focus_name = nil,
    isBrowse = false,
    closeTime = 0
}


local isShown = false;
local compat = pfExtendCompat;

-- HDB owns unit drops when the SQLite provider is loaded. Follows the same
-- detection convention as the rest of the pfQuest-HDB family (patchtable.lua
-- etc.): a live capability check, not a hardcoded dependency on the addon name.
-- Checked fresh every call rather than cached once: pfExtend.toc only depends
-- on pfQuest, not on the HDB provider addon, so there's no guarantee
-- pfQuestHearthDB exists yet at the moment this file's top level runs.
local function HasHDB()
    return pfQuestHearthDB and type(pfQuestHearthDB.GetUnitDropsAsync) == "function"
        and type(pfQuestHearthDB.GetEntitiesByTitleAsync) == "function"
end

-- Resolves an item's display name from whichever source has it: the HDB
-- title cached off the last drop query, the legacy Lua database, or (last
-- resort, since it may not be client-cached yet) the game's own item info.
-- Defensive: PfExtend_Database is a SavedVariable, and the top-level literal
-- above only sets itemNameData on a *fresh* table. If this saved table
-- somehow survives from a session predating this field (observed in testing:
-- itemNameData missing at runtime despite the load-time literal setting it),
-- self-heal instead of erroring on every mouseover.
local function GetShowLootsCache()
    local db = PfExtend_Database["ShowLoots"]
    if db.itemNameData == nil then db.itemNameData = {} end
    if db.itemQualityData == nil then db.itemQualityData = {} end
    return db
end

-- Exposed for browser.lua, which reads/writes the same quality cache from a
-- separate file scope and needs the same self-healing guard.
PFEXShowLoots.GetItemQualityData = function()
    return GetShowLootsCache().itemQualityData
end

PFEXShowLoots.GetItemName = function(id)
    local name = GetShowLootsCache().itemNameData[id]
    if name then return name end
    if pfDB and pfDB.items and pfDB.items.loc and pfDB.items.loc[id] then
        return pfDB.items.loc[id]
    end
    return GetItemInfo(id) or UNKNOWN
end




PFEXShowLoots.UpdateDatabase = function()
    if HasHDB() then
        -- No precomputed cache to build: GetUnitDropsAsync is queried per
        -- unit on hover and caches itself inside the provider.
        PfExtend_Database["ShowLoots"]["LootData"] = {};
        PfExtend_Database["ShowLoots"]["updated"] = true;
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080"..pfExtend_Loc["Update_Success_Hint"])
        return true;
    end

    if pfDB == nil or pfDB["items"]["data"] == nil then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080"..pfExtend_Loc["Update_Error_Hint"]);
        return false;
    end
    local db = { U = {}, O = {} }
    for itemId, itemData in pairs(pfDB["items"]["data"]) do
        for lootType, LootData in pairs(itemData) do
            for from, probability in pairs(LootData) do
                if probability > 0 then
                    if lootType == "U" or lootType == "O" then
                        if db[lootType] == nil then
                            db[lootType] = {};
                        end
                        if db[lootType][from] == nil then
                            db[lootType][from] = {};
                        end

                        db[lootType][from][itemId] = probability;
                    elseif lootType == "R" then
                        if pfDB["refloot"]["data"][from] then
                            for refLootType, refLootData in pairs(pfDB["refloot"]["data"][from]) do
                                for refFrom, refProbability in pairs(refLootData) do
                                    if db[refLootType] == nil then
                                        db[refLootType] = {};
                                    end
                                    if db[refLootType][refFrom] == nil then
                                        db[refLootType][refFrom] = {};
                                    end
                                    db[refLootType][refFrom][itemId] = probability;
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    PfExtend_Database["ShowLoots"]["LootData"] = db;
    PfExtend_Database["ShowLoots"]["updated"] = true;
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8080"..pfExtend_Loc["Update_Success_Hint"])
    return true;
end




-- Shared between the legacy and HDB tooltip builders: turns a flat drop list
-- into the {id, chance, r, g, b} rows the tooltip/browser already expect,
-- applying the same favorite-item bump the Lua-table path used.
local function BuildLootRows(drops)
    local itemNameData = GetShowLootsCache().itemNameData
    local sortLootList = {}
    for _, drop in ipairs(drops) do
        local chance = drop.chance
        if pfBrowser_fav and pfBrowser_fav["items"] and pfBrowser_fav["items"][drop.item] then
            chance = chance + 100;
        end
        sortLootList[drop.item] = chance;
        if drop.title then
            itemNameData[drop.item] = drop.title;
        end
    end

    local ret = {};
    for _, v in ipairs(PfExtend_Global.sortKeyValueTable(sortLootList, "value", true)) do
        local value = v.value > 100 and v.value - 100 or v.value;
        local r, g, b = pfMap.tooltip:GetColor(tonumber(value), 100)
        table.insert(ret, { v.key, value, r, g, b })
    end
    return ret;
end

-- HDB path: resolves the hovered name to a creature id via GetEntitiesByTitleAsync
-- (filtered to the current zone, same as the old coords-match loop below), then
-- fetches its drops directly instead of scanning a flattened whole-database cache.
PFEXShowLoots.ModifyTooltipHDB = function()
    local focus = GetMouseFocus();
    if focus and focus.title then return end
    if focus and focus.GetName and strsub((focus:GetName() or ""), 0, 10) == "QuestTimer" then return end

    PFEXShowLoots.focus_name = getglobal("GameTooltipTextLeft1") and getglobal("GameTooltipTextLeft1"):GetText() or
        "__NONE__"
    PFEXShowLoots.focus_name = string.gsub(PFEXShowLoots.focus_name, "|c%x%x%x%x%x%x%x%x", "");
    PFEXShowLoots.focus_name = string.gsub(PFEXShowLoots.focus_name, "|r", "");

    local requestName = PFEXShowLoots.focus_name;
    local focus_zone = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())

    pfQuestHearthDB:GetEntitiesByTitleAsync("U", requestName, function(records, err)
        -- The cursor can move to a different unit before this resolves; a
        -- result for a name that's no longer under the mouse is stale, drop it.
        if PFEXShowLoots.focus_name ~= requestName then return end
        if err or not records then return end

        local matchID;
        for _, record in ipairs(records) do
            if record.zones[focus_zone] then
                matchID = record.id;
                break;
            end
        end
        if not matchID then return end

        pfQuestHearthDB:GetUnitDropsAsync(matchID, function(drops, dropErr)
            if PFEXShowLoots.focus_name ~= requestName then return end
            if dropErr or not drops then return end
            PFEXShowLoots.LootListShown = BuildLootRows(drops);
            isShown = false;
        end)
    end)
end

PFEXShowLoots.ModifyTooltip = function()
    local focus = GetMouseFocus();
    local ret = {};
    local db = PfExtend_Database["ShowLoots"]["LootData"]
    if focus and focus.title then return end
    if focus and focus.GetName and strsub((focus:GetName() or ""), 0, 10) == "QuestTimer" then return end
    PFEXShowLoots.focus_name = getglobal("GameTooltipTextLeft1") and getglobal("GameTooltipTextLeft1"):GetText() or
        "__NONE__"
    local focus_zone = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
    PFEXShowLoots.focus_name = string.gsub(PFEXShowLoots.focus_name, "|c%x%x%x%x%x%x%x%x", "");
    PFEXShowLoots.focus_name = string.gsub(PFEXShowLoots.focus_name, "|r", "");
    for id in pairs(pfDatabase:GetIDByName(PFEXShowLoots.focus_name, "units")) do
        for _, data in pairs(pfDB["units"]["data"][id]["coords"]) do
            local x, y, zone, respawn = unpack(data)
            if zone == focus_zone and db["U"] and type(db["U"][id]) == "table" then
                local lootList = db["U"][id]
                local sortLootList = table.shallowCopy(lootList)
                for itemid, chance in pairs(sortLootList) do
                    if pfBrowser_fav and pfBrowser_fav["items"] and pfBrowser_fav["items"][itemid] then
                        sortLootList[itemid] = chance + 100;
                    end
                end

                for _, v in ipairs(PfExtend_Global.sortKeyValueTable(sortLootList, "value", true)) do
                    if v.value > 100 then
                        v.value = v.value - 100;
                    end
                    local r, g, b = pfMap.tooltip:GetColor(tonumber(v.value), 100)
                    table.insert(ret, { v.key, v.value, r, g, b })
                    --GameTooltip:AddLine(itemLink ..  " |cff555555[|r" .. v.value .. "%|cff555555]", r,g,b)
                end
                break
            end
        end
    end
    return ret;
end





local altKey = CreateFrame("Frame", "pfQuestShowLootsAltKey", UIParent)
altKey:SetScript("OnUpdate", function()
    altKey.pressed = false;
    if not isShown then return end
    if PFEXShowLoots.isBrowse then return end
    if (this.throttle or .05) > GetTime() then return else this.throttle = GetTime() + .05 end
    if GameTooltip:IsShown() and GetTime() - PFEXShowLoots.closeTime > .2 then
        altKey.pressed = IsAltKeyDown() and IsControlKeyDown()
    end
end)

pfMap.tooltip:SetScript("OnUpdate", function()
    if not PfExtend_Global.ReadSetting("ShowLoots", "enable") then return end
    -- The browser window shows this same list properly; there's no reason
    -- for the world-hover tooltip to do any work (let alone the string-heavy
    -- rebuild below) while it's up. Belt-and-suspenders against the mouseover
    -- OnEvent path that already skips itself while isBrowse is true.
    if PFEXShowLoots.isBrowse then return end
    local num = table.getn(PFEXShowLoots.LootListShown);
    if not isShown then
        local i = 0;
        local j = 0;
        local miniq = PfExtend_Global.ReadSetting("ShowLoots", "itemQualityFilter")
        local showlines = {}
        local itemQualityData = GetShowLootsCache().itemQualityData
        for _, l in ipairs(PFEXShowLoots.LootListShown) do
            local id, chance, r, g, b = unpack(l)


            local itemQuality = itemQualityData[id];
            if itemQuality == nil then
                local _, _, iq = GetItemInfo(id);
                itemQuality = iq;
            end
            local itemLink;
            if type(itemQuality) == "number" then
                itemQualityData[id] = itemQuality;
                local itemColor                                       = "|c" .. string.format("%02x%02x%02x%02x", 255,
                    ITEM_QUALITY_COLORS[itemQuality].r * 255,
                    ITEM_QUALITY_COLORS[itemQuality].g * 255,
                    ITEM_QUALITY_COLORS[itemQuality].b * 255)
                itemLink                                              = itemColor ..
                    "|Hitem:" .. id .. compat.itemsuffix .. "|h[" .. PFEXShowLoots.GetItemName(id) .. "]|h|r"
            end
            if type(itemQuality) ~= "number" or itemQuality >= miniq then
                if i < tonumber(PfExtend_Global.ReadSetting("ShowLoots", "showNum")) then
                    itemLink = itemLink or "[" .. PFEXShowLoots.GetItemName(id) .. "]"
                    table.insert(showlines,
                        { ["itemLink"] = itemLink, ["chance"] = chance, ["r"] = r, ["g"] = g, ["b"] = b })
                    i = i + 1;
                end
                j = j + 1;
            end
        end
        if num == 0 then
            GameTooltip:AddLine(pfExtend_Loc["No loots"], 0.55, 0.55, 0.55);
        elseif miniq > 0 and i == 0 then
            GameTooltip:AddLine(
                string.format(pfExtend_Loc["No %s or better loots"],
                    pfExtend_Loc["Config_ShowLoots_itemQualityFilter_" .. miniq] .. "|r"), 0.55, 0.55, 0.55);
        elseif miniq > 0 and i > 0 then
            GameTooltip:AddLine(
                string.format(pfExtend_Loc["%d %s or better loots(of %d)"], j,
                    pfExtend_Loc["Config_ShowLoots_itemQualityFilter_" .. miniq] .. "|r", num), 0.55, 0.55, 0.55);
        elseif miniq == 0 then
            GameTooltip:AddLine(string.format(pfExtend_Loc["All %d loots"], num), 0.55, 0.55, 0.55);
        end
        GameTooltip:SetHeight(GameTooltip:GetHeight() + 14);
        for _, line in pairs(showlines) do
            GameTooltip:AddLine(
                line.itemLink .. " |cff555555[|r" .. string.format("%.2f", line.chance) .. "%|cff555555]", line.r, line
                .g,
                line.b)
            GameTooltip:SetHeight(GameTooltip:GetHeight() + 14);
        end
        if num - i > 0 then
            GameTooltip:AddLine(string.format(pfExtend_Loc["... %d loots hidden ..."], num - i), 0.55, 0.55, 0.55)
            GameTooltip:SetHeight(GameTooltip:GetHeight() + 14);
        end
        if num > 0 then
            GameTooltip:AddLine(pfExtend_Loc["Press <Alt> for details"], 0.55, 0.55, 0.55);
            GameTooltip:SetHeight(GameTooltip:GetHeight() + 14);
        end
        local width = 0
        for line = 1, GameTooltip:NumLines() do
            width = math.max(width, getglobal(GameTooltip:GetName() .. "TextLeft" .. line):GetWidth())
        end
        GameTooltip:SetWidth(20 + width);

        isShown = true;
    end
    if altKey.pressed and isShown and not PFEXShowLoots.isBrowse and num > 0 then
        if PFEXShowLoots.Browser then PFEXShowLoots.Browser:Show() end
    end
end)

function PFEXShowLoots.OnLoad()

end

function PFEXShowLoots.OnEvent(event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
    if not PfExtend_Global.ReadSetting("ShowLoots", "enable") then return end
    if (event == "PLAYER_ENTERING_WORLD") then
        -- .text, not the table. Version() builds a fresh {text=...} every call,
        -- so comparing the table itself was never equal to the stored one and
        -- UpdateDatabase() -- a walk over every item in the pfQuest database
        -- with refloot expansion, written straight into SavedVariables -- ran on
        -- every single login instead of only when the version changed.
        local version = PfExtend_Config_Template["About"].Version().text
        -- Key the cache to the database pack too: the loot DB is BUILT from
        -- pack data, so a pack update must invalidate it. Before this, a data
        -- correction in pfQuest-octo left every existing install showing the
        -- old loot until pfExtend itself changed version.
        version = version .. "|" .. tostring(GetAddOnMetadata("pfQuest-octo", "Version") or "nopack")
        if not PfExtend_Database["ShowLoots"]["updated"] or PfExtend_Database["ShowLoots"]["version"] ~= version then
            PFEXShowLoots.UpdateDatabase();
            PfExtend_Database["ShowLoots"]["version"] = version
        end
    elseif (event == "UPDATE_MOUSEOVER_UNIT") then
        -- Leaving a unit fires this too, with no mouseover unit. Rebuilding on
        -- that emptied LootListShown -- and moving the cursor off the mob is
        -- exactly what you do to reach the browser window, so by the time you
        -- clicked a sort button the list it re-reads was already gone and every
        -- row vanished. Leave the list alone while the window is open.
        if PFEXShowLoots.isBrowse then return end

        -- The loss-fire used to fall through to the rebuild below: it flagged
        -- isShown false with an empty list while the old unit's tooltip was
        -- still on screen fading out, so the ticker stamped "No loots" right
        -- under the loot lines it had just written. Both stacks now fire this
        -- event on losing the unit as well (ClassicAPI always did; SuperAPI
        -- gained it recently). Nothing under the cursor, nothing to describe --
        -- and keeping the last list is what the browser flow above wants.
        if not UnitExists("mouseover") then return end

        PFEXShowLoots.LootListShown = {}
        isShown = false;
        if (not UnitPlayerControlled("mouseover")) then
            if HasHDB() then
                -- Async: populates PFEXShowLoots.LootListShown itself once the
                -- HDB query resolves, a tick or more from now.
                PFEXShowLoots.ModifyTooltipHDB();
            else
                -- ModifyTooltip returns nil for a focus it refuses to describe, and
                -- nil here makes the next ipairs() over the list an error.
                PFEXShowLoots.LootListShown = PFEXShowLoots.ModifyTooltip() or {};
            end
        end
    end
end