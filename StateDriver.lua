if not LibStub then return end

local SD = LibStub:NewLibrary('StateDriver-1.0', 0)
if not SD then return end

local Classy = LibStub('Classy-1.0')

local _G = getfenv(0)

function SD:New(name, parent)
    self[name] = Classy:New('Frame', parent)

    return self[name]
end

local function GetAttribute(self, attr)
    return self.__state_driver.attributes[attr]
end

local function SetAttribute(self, attr, value)
    self.__state_driver.attributes[attr] = value

    local func = self.__state_driver.handlers['OnAttributeChanged']
    if func and type(func) == 'function' then
        func(self, attr, value)
    end
end


-- Figure out where to place this
local function initPlayerDrop()
    UnitPopup_ShowMenu(PlayerFrameDropDown, 'SELF', 'player')
    if not (UnitInRaid('player') or GetNumPartyMembers() > 0) or UnitIsPartyLeader('player') and PlayerFrameDropDown.init then
        UIDropDownMenu_AddButton({text = 'Reset Instances', func = ResetInstances, notCheckable = 1}, 1)
        PlayerFrameDropDown.init = nil
    end
end

local function initPartyDrop(self)
    UnitPopup_ShowMenu(getglobal(UIDROPDOWNMENU_OPEN_MENU), "PARTY", self.unit, self.name, self.id)
end

local ToggleMenu = function(self)
    if UnitIsUnit(self.unit, 'player') then
        UIDropDownMenu_Initialize(PlayerFrameDropDown, initPlayerDrop, 'MENU')
        ToggleDropDownMenu(1, nil, PlayerFrameDropDown, 'cursor')
    elseif self.unit == 'pet' then
        ToggleDropDownMenu(1, nil, PetFrameDropDown, 'cursor')
    elseif self.unit == 'target' then
        ToggleDropDownMenu(1, nil, TargetFrameDropDown, 'cursor')
    elseif self.unitGroup == 'party' then
        ToggleDropDownMenu(1, nil, _G['PartyMemberFrame' .. string.sub(self.unit,6) .. 'DropDown'], 'cursor')
    elseif this.unitGroup == 'raid' then
        HideDropDownMenu(1)

        local menuFrame = FriendsDropDown
        menuFrame.displayMode = 'MENU'
        menuFrame.id = string.sub(this.unit,5)
        menuFrame.unit = self.unit
        menuFrame.name = UnitName(this.unit)
        menuFrame.initialize = initPartyDrop

        ToggleDropDownMenu(1, nil, FriendsDropDown, 'cursor')
    end
end

local attr_mappings = {
    ['target'] = function(self) TargetUnit(self.unit) end,
    ['togglemenu'] = ToggleMenu
}

local function TriggerValue(self, value)
    local func = attr_mappings[value]
    if func and self.unit then
        func(self)
    end
end

local CLICK_TYPES = {
    ['type'] = true,
    ['type1'] = 'LeftButton',
    ['type2'] = 'RightButton'
}
local function OnClick(self, button)
    local value, valid

    local alt = IsAltKeyDown() and 'alt-' or ''
    local ctrl = IsControlKeyDown() and 'ctrl-' or ''
    local shift = IsShiftKeyDown() and 'shift-' or ''
    local modifiers = alt .. ctrl .. shift

    local prefix = '*'
    while true do
        -- Check any click combinations followed by modified/unmodified clicks
        for click_type in next, CLICK_TYPES do
            valid = CLICK_TYPES[click_type]

            value = self:GetAttribute(prefix .. click_type)
            if value and ((type(valid) == 'boolean' and valid) or (valid == button)) then
                TriggerValue(self, value)
                return
            end
        end

        if prefix == modifiers then
            return
        end

        prefix = modifiers
    end

end

local function SetScript(self, handler, func)
    if self.__state_driver.handlers[handler] then
        if self:HasScript(handler) and handler == 'OnClick' then
            self.__state_driver._SetScript(self, handler, function(...)
                                               OnClick(this, arg1)
                                               func()
            end)
        else
            self.__state_driver.handlers[handler] = func
        end
    else
        self.__state_driver._SetScript(self, handler, func)
    end
end

local _CreateFrame = CreateFrame
function CreateFrame(...)
    local frame = _CreateFrame(unpack(arg))

    -- State Driver environment
    frame.__state_driver = {}

    frame.__state_driver._SetScript = frame.SetScript
    frame.SetScript = SetScript

    frame.__state_driver.attributes = {}
    frame.__state_driver.handlers = {
        ['OnAttributeChanged'] = true,
        ['OnClick'] = true
    }

    frame.GetAttribute = GetAttribute
    frame.SetAttribute = SetAttribute

    frame:SetScript('OnClick', NOOP)

    return frame
end


--
-- SecureStateDriverManager
-- Automatically sets states based on macro options for state driver frames
-- Also handled showing/hiding frames based on unit existence (code originally by Tem)
--

-- Register a frame attribute to be set automatically with changes in game state
function RegisterAttributeDriver(frame, attribute, values)
    if attribute and values and string.sub(attribute, 1, 1) ~= '_' then
        Manager:SetAttribute('setframe', frame);
        Manager:SetAttribute('setstate', attribute .. ' ' .. values);
    end
end

-- Unregister a frame from the state driver manager.
function UnregisterAttributeDriver(frame, attribute)
    if attribute then
        Manager:SetAttribute('setframe', frame);
        Manager:SetAttribute('setstate', attribute);
    else
        Manager:SetAttribute('delframe', frame);
    end
end

-- Bridge functions for compatibility
function RegisterStateDriver(frame, state, values)
    return RegisterAttributeDriver(frame, 'state-' .. state, values);
end

function UnregisterStateDriver(frame, state)
    return UnregisterAttributeDriver(frame, 'state-' .. state);
end

-- Register a frame to be notified when a unit's existence changes, the
-- unit is obtained from the frame's attributes. If asState is true then
-- notification is via the 'state-unitexists' attribute with values
-- true and false. Otherwise it's via :Show() and :Hide()
function RegisterUnitWatch(frame, asState)
    if asState then
        Manager:SetAttribute('addwatchstate', frame);
    else
        Manager:SetAttribute('addwatch', frame);
    end
end

-- Unregister a frame from the unit existence monitor.
function UnregisterUnitWatch(frame)
    SecureStateDriverManager:SetAttribute('removewatch', frame);
end

--
-- Private implementation
--
local secureAttributeDrivers = {};
local unitExistsWatchers = {};
local unitExistsCache = setmetatable(
    {},
    { __index = function(t,k)
          local v = UnitExists(k) or false;
          t[k] = v;
          return v;
    end
});
local STATE_DRIVER_UPDATE_THROTTLE = 0.2;
local timer = 0;

local wipe = table.wipe;

-- Check to see if a frame is registered
function UnitWatchRegistered(frame)
    return not (unitExistsWatchers[frame] == nil);
end

local function SecureStateDriverManager_UpdateUnitWatch(frame, doState)
    -- Not really so secure, eh?
    local unit = frame.unit;
    local exists = (unit and unitExistsCache[unit]);
    if doState then
        local attr = exists or false;
        if frame:GetAttribute('state-unitexists') ~= attr then
            frame:SetAttribute('state-unitexists', attr);
        end
    else
        if exists then
            frame:Show();
            frame:SetAttribute('statehidden', nil);
        else
            frame:Hide();
            frame:SetAttribute('statehidden', true);
        end
    end
end

local pairs = pairs;

-- consolidate duplicated code for footprint and maintainability
local function resolveDriver(frame, attribute, values)
    local newValue = SecureCmdOptionParse(values);

    if attribute == 'state-visibility' then
        if newValue == 'show' then
            frame:Show();
            frame:SetAttribute('statehidden', nil);
        elseif newValue == 'hide' then
            frame:Hide();
            frame:SetAttribute('statehidden', true);
        end
    elseif newValue then
        if newValue == 'nil' then
            newValue = nil;
        else
            newValue = tonumber(newValue) or newValue;
        end
        local oldValue = frame:GetAttribute(attribute);
        if newValue ~= oldValue then
            frame:SetAttribute(attribute, newValue);
        end
    end
end

local function OnUpdate()
    local self, elapsed = this, arg1

    timer = timer - elapsed
    if timer <= 0 then
        timer = STATE_DRIVER_UPDATE_THROTTLE

        -- Handle state driver updates
        for frame, drivers in next, secureAttributeDrivers do
            for attribute, values in next, drivers do
                resolveDriver(frame, attribute, values)
            end
        end

        -- Handle unit existence changes
        wipe(unitExistsCache)
        for k in next, unitExistsCache do
            unitExistsCache[k] = nil
        end
        for frame, doState in next, unitExistsWatchers do
            SecureStateDriverManager_UpdateUnitWatch(frame, doState)
        end
    end
end

local function OnEvent()
    local self, event = this, arg1

    timer = 0;
end

local function OnAttributeChanged(self, name, value)
    if not value then
        return
    end

    if name == 'setframe' then
        if not secureAttributeDrivers[value] then
            secureAttributeDrivers[value] = {}
        end
        SecureStateDriverManager:Show()
    elseif name == 'delframe' then
        secureAttributeDrivers[value] = nil
    elseif name == 'setstate' then
        local frame = self:GetAttribute('setframe')
        local attribute, values = string.match(value, '^(%S+)%s*(.*)$')
        if values == '' then
            secureAttributeDrivers[frame][attribute] = nil
        else
            secureAttributeDrivers[frame][attribute] = values
            resolveDriver(frame, attribute, values)
        end
    elseif name == 'addwatch' or name == 'addwatchstate' then
        local doState = (name == 'addwatchstate')
        unitExistsWatchers[value] = doState
        SecureStateDriverManager:Show()
        SecureStateDriverManager_UpdateUnitWatch(value, doState)
    elseif name == 'removewatch' then
        unitExistsWatchers[value] = nil
    elseif name == 'updatetime' then
        STATE_DRIVER_UPDATE_THROTTLE = value
    end
end


Manager = SD:New('Manager')
Manager:SetScript('OnUpdate', OnUpdate)
Manager:SetScript('OnEvent', OnEvent);
Manager:SetScript('OnAttributeChanged', OnAttributeChanged);

-- Events that trigger early rescans
Manager:RegisterEvent('MODIFIER_STATE_CHANGED');
Manager:RegisterEvent('ACTIONBAR_PAGE_CHANGED');
Manager:RegisterEvent('UPDATE_BONUS_ACTIONBAR');
Manager:RegisterEvent('PLAYER_ENTERING_WORLD');
Manager:RegisterEvent('UPDATE_SHAPESHIFT_FORM');
Manager:RegisterEvent('UPDATE_STEALTH');
Manager:RegisterEvent('PLAYER_TARGET_CHANGED');
Manager:RegisterEvent('PLAYER_FOCUS_CHANGED');
Manager:RegisterEvent('PLAYER_REGEN_DISABLED');
Manager:RegisterEvent('PLAYER_REGEN_ENABLED');
Manager:RegisterEvent('UNIT_PET');
Manager:RegisterEvent('GROUP_ROSTER_UPDATE');
-- Deliberately ignoring mouseover and others' target changes because they change so much

_G['SecureStateDriverManager'] = Manager
