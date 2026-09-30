-- Physical VR weapon recoil, including independent akimbo muzzles.
if not _G.IS_VR then
    return
end

_G.PD2VRPhysicalSpread = _G.PD2VRPhysicalSpread or {}
local P = _G.PD2VRPhysicalSpread
P.installed = P.installed or {}
P.wrapped = P.wrapped or {}
P.camera_before = P.camera_before or setmetatable({}, { __mode = "k" })
P.pending_by_base = P.pending_by_base or setmetatable({}, { __mode = "k" })
P.laser_owner = P.laser_owner or setmetatable({}, { __mode = "k" })
P.fire_sequence = P.fire_sequence or 0
P.enabled = true

local CLASS_MULTIPLIERS = {
    lmg = { one = 2.21, two = 0.70 },
    minigun = { one = 2.21, two = 0.70 },
    smg = { one = 1.68, two = 0.80 },
    pistol = { one = 1.43, two = 0.90 },
    assault_rifle = { one = 1.65, two = 0.80 },
    shotgun = { one = 1.75, two = 0.80 },
    snp = { one = 1.80, two = 0.80 },
    grenade_launcher = { one = 2.00, two = 0.85 }
}
local CLASS_ORDER = { "lmg", "minigun", "smg", "pistol", "assault_rifle", "shotgun", "snp", "grenade_launcher" }
local EXCLUDED_CATEGORIES = { "bow", "crossbow", "saw", "flamethrower", "rocket_launcher" }
local WEAPON_MULTIPLIERS = {
    kacchainsaw = { one = 2.21, two = 0.70 }
}
local STIFFNESS = 85       -- degrees/s^2 per degree of displacement
local DAMPING = 17         -- 1/s
local PC_VERTICAL_GAIN = 1.5
local PC_HORIZONTAL_GAIN = 1.0
local MAX_ANGLE = 7        -- degrees
local MAX_YAW = 5          -- degrees

local function emit(message)
    if log then
        pcall(log, "[PD2 VR PHYSICAL 0.13.1] " .. message)
    end
end

local function no_recoil_reason(base)
    if not base or type(base.is_category) ~= "function" then
        return nil
    end
    for _, category in ipairs(EXCLUDED_CATEGORIES) do
        if base:is_category(category) then
            return category
        end
    end
    -- RPG-7 and Ray Launcher share the grenade_launcher category with
    -- powder-driven launchers. Their projectile type identifies the rocket.
    if base:is_category("grenade_launcher") and type(base.weapon_tweak_data) == "function" then
        local tweak = base:weapon_tweak_data()
        if tweak and type(tweak.projectile_type) == "string" and tweak.projectile_type:find("^rocket") then
            return "rocket"
        end
    end
    return nil
end

local function weapon_profile(base)
    if not base or type(base.is_category) ~= "function" then
        return nil
    end
    if type(base.gadget_overrides_weapon_functions) == "function" and base:gadget_overrides_weapon_functions() then
        return nil
    end
    local id = base._name_id or (type(base.get_name_id) == "function" and base:get_name_id()) or base.name_id
    if no_recoil_reason(base) then
        return nil
    end
    if WEAPON_MULTIPLIERS[id] then
        return WEAPON_MULTIPLIERS[id], id
    end
    for _, category in ipairs(CLASS_ORDER) do
        if base:is_category(category) then
            return CLASS_MULTIPLIERS[category], category
        end
    end
    return nil
end

local function is_local_weapon(base)
    if not base or not base._setup or not managers or not managers.player then
        return false
    end
    local player = managers.player:player_unit()
    return player and base._setup.user_unit == player and weapon_profile(base) ~= nil
end

local function should_zero_spread(base)
    if not base or not base._setup or not managers or not managers.player or
       base._setup.user_unit ~= managers.player:player_unit() or type(base.is_category) ~= "function" then
        return false
    end
    if type(base.gadget_overrides_weapon_functions) == "function" and base:gadget_overrides_weapon_functions() then
        return false
    end
    -- Shotgun pellet dispersion is physical and must survive the VR aim fix.
    if base:is_category("shotgun") then
        return false
    end
    -- Rocket launchers have no muzzle recoil, but a launched projectile must
    -- still leave along the barrel instead of getting an arbitrary cone roll.
    return base:is_category("grenade_launcher") or weapon_profile(base) ~= nil
end

local function active_state(state)
    if not P.enabled or not state or not state._weapon_unit or not alive(state._weapon_unit) then
        return false
    end
    return is_local_weapon(state._weapon_unit:base())
end

local function reset_for_weapon(state)
    if state._pd2_physical_unit ~= state._weapon_unit then
        state._pd2_physical_unit = state._weapon_unit
        state._pd2_physical_angle = 0
        state._pd2_physical_velocity = 0
        state._pd2_physical_yaw = 0
        state._pd2_physical_yaw_velocity = 0
        state._pd2_physical_secondary = false
        state._pd2_physical_base_local_rot = state._weapon_unit:local_rotation()
    end
end

local function grip_for(state)
    local base = state._weapon_unit:base()
    local hsm = state:hsm()
    local other = hsm and hsm:other_hand()
    local akimbo = not not (base.parent_weapon or (base.is_category and base:is_category("akimbo")) or
                             (state.name and state:name() == "akimbo"))
    local two_handed = akimbo or (other and other:current_state_name() == "weapon_assist")
    local profile = weapon_profile(base)
    return two_handed and "two" or "one",
           profile and profile[two_handed and "two" or "one"] or 1
end

local function soft_limited_impulse(current, impulse, limit)
    if impulse == 0 then
        return current
    end
    local room = impulse > 0 and limit - current or limit + current
    if room <= 0 then
        return impulse > 0 and limit or -limit
    end
    local change = room * (1 - math.exp(-math.abs(impulse) / room))
    return current + (impulse > 0 and change or -change)
end

local function add_impulse(state, amount)
    if not active_state(state) or type(amount) ~= "number" then
        emit("IMPULSE_SKIPPED amount=" .. tostring(amount) .. " unit=" .. tostring(state and state._weapon_unit) ..
             " weapon=" .. tostring(state and state._weapon_unit and alive(state._weapon_unit) and state._weapon_unit:base()._name_id))
        return
    end
    reset_for_weapon(state)
    local base = state._weapon_unit:base()
    local pc = P.pending_by_base[base]
    P.pending_by_base[base] = nil
    if pc and (P.current_fire_base ~= base or pc.sequence ~= P.current_fire_sequence) then
        emit("KICK_BIND_MISMATCH weapon=" .. tostring(base._name_id) .. " sequence=" .. tostring(pc.sequence))
        pc = nil
    end
    if not pc then
        emit("IMPULSE_SKIPPED no_matching_camera_kick weapon=" .. tostring(base._name_id) ..
             " amount=" .. tostring(amount))
        return
    end
    local old_angle = state._pd2_physical_angle
    local old_yaw = state._pd2_physical_yaw
    local grip, grip_multiplier = grip_for(state)
    local angle_impulse = math.min(math.max(pc.vertical * PC_VERTICAL_GAIN, 0), 5)
    local yaw_impulse = math.max(-3, math.min(3, pc.horizontal * PC_HORIZONTAL_GAIN))
    angle_impulse = angle_impulse * grip_multiplier
    yaw_impulse = yaw_impulse * grip_multiplier
    state._pd2_physical_angle = soft_limited_impulse(old_angle, angle_impulse, MAX_ANGLE)
    state._pd2_physical_yaw = soft_limited_impulse(old_yaw, yaw_impulse, MAX_YAW)
    local actual_angle_impulse = state._pd2_physical_angle - old_angle
    local actual_yaw_impulse = state._pd2_physical_yaw - old_yaw
    local vertical_speed = actual_angle_impulse * 3
    state._pd2_physical_velocity = math.min(state._pd2_physical_velocity + vertical_speed, 80)
    state._pd2_physical_yaw_velocity = math.max(-50, math.min(50, state._pd2_physical_yaw_velocity + actual_yaw_impulse * 3))
    state._pd2_physical_grip = grip
    state._pd2_physical_secondary = not not base.parent_weapon
end

local function update_weapon(state, dt)
    if not active_state(state) then
        return
    end
    reset_for_weapon(state)
    dt = math.min(math.max(type(dt) == "number" and dt or 0, 0), 0.05)
    local angle = state._pd2_physical_angle
    local velocity = state._pd2_physical_velocity
    local yaw = state._pd2_physical_yaw
    local yaw_velocity = state._pd2_physical_yaw_velocity
    local stiffness = state._pd2_physical_grip == "one" and STIFFNESS * 0.82 or STIFFNESS
    local damping = state._pd2_physical_grip == "one" and DAMPING * 0.88 or DAMPING
    velocity = velocity + (-stiffness * angle - damping * velocity) * dt
    angle = math.max(0, math.min(MAX_ANGLE, angle + velocity * dt))
    yaw_velocity = yaw_velocity + (-stiffness * yaw - damping * yaw_velocity) * dt
    yaw = math.max(-MAX_YAW, math.min(MAX_YAW, yaw + yaw_velocity * dt))
    if angle == 0 and velocity < 0 then
        velocity = 0
    end
    state._pd2_physical_angle = angle
    state._pd2_physical_velocity = velocity
    state._pd2_physical_yaw = yaw
    state._pd2_physical_yaw_velocity = yaw_velocity
    local weapon_base = state._weapon_unit:base()
    if type(weapon_base.get_active_gadget) == "function" then
        local gadget = weapon_base:get_active_gadget()
        if gadget and gadget.GADGET_TYPE == "laser" then
            P.laser_owner[gadget] = weapon_base
        end
    end
    if angle < 0.001 and math.abs(yaw) < 0.001 then
        if state._pd2_physical_secondary then
            state._weapon_unit:set_local_rotation(state._pd2_physical_base_local_rot)
        end
        return
    end

    -- Vanilla sets the fresh controller rotation each update. Add a local
    -- pitch after that update, so the visible muzzle and fire_object agree.
    -- Weapon.update supplies a fresh controller rotation. Akimbo.update only
    -- moves the hand, so rebuild its base from the hand to avoid compounding.
    local base_rotation = state._pd2_physical_secondary and state._hand_unit:rotation() or state._weapon_unit:rotation()
    local rotation = Rotation()
    mrotation.multiply(rotation, base_rotation)
    mrotation.multiply(rotation, Rotation(yaw, angle, 0))
    if state._pd2_physical_secondary then
        local local_rotation = Rotation()
        mrotation.multiply(local_rotation, state._pd2_physical_base_local_rot)
        mrotation.multiply(local_rotation, Rotation(yaw, angle, 0))
        state._weapon_unit:set_local_rotation(local_rotation)
    else
        state._weapon_unit:set_rotation(rotation)
    end
    state._weapon_unit:base():set_gadget_rotation(state._weapon_unit:rotation())
end

local function install(key, fn)
    if P.installed[key] then
        return
    end
    local ok, err = pcall(fn)
    if ok then
        P.installed[key] = true
    else
        emit("INSTALL_ERROR " .. key .. " " .. tostring(err))
    end
end

local function wrap_spread(class, label)
    if not class or type(rawget(class, "_get_spread")) ~= "function" or P.wrapped[class] then
        return
    end
    install(label .. "._get_spread", function()
        local original = class._get_spread
        class._get_spread = function(self, ...)
            if P.enabled and should_zero_spread(self) then
                return 0, 0
            end
            return original(self, ...)
        end
        P.wrapped[class] = true
    end)
end

wrap_spread(RaycastWeaponBase, "RaycastWeaponBase")
wrap_spread(NewRaycastWeaponBase, "NewRaycastWeaponBase")
wrap_spread(NewRaycastWeaponBaseVR, "NewRaycastWeaponBaseVR")

if FPCameraPlayerBase then
    install("FPCameraPlayerBase.suppress_nonfirearm_kick", function()
        local original = FPCameraPlayerBase.recoil_kick
        FPCameraPlayerBase.recoil_kick = function(self, ...)
            local base = P.current_fire_base
            local reason = no_recoil_reason(base)
            if P.enabled and reason then
                return
            end
            return original(self, ...)
        end
    end)
    install("FPCameraPlayerBase.recoil_kick", function()
        Hooks:PreHook(FPCameraPlayerBase, "recoil_kick", "PD2VRPhysical05_CameraBefore", function(self)
            local kick = self._recoil_kick
            if kick and kick.h then
                P.camera_before[self] = { vertical = kick.accumulated or 0, horizontal = kick.h.accumulated or 0 }
            end
        end)
        Hooks:PostHook(FPCameraPlayerBase, "recoil_kick", "PD2VRPhysical05_CameraAfter", function(self, up, down, left, right)
            local before = P.camera_before[self]
            local kick = self._recoil_kick
            P.camera_before[self] = nil
            if before and kick and kick.h then
                local vertical_delta = (kick.accumulated or 0) - before.vertical
                local capped = math.abs(before.vertical) >= 20
                -- Vanilla stops accumulating vertical camera recoil at 20. Keep
                -- sampling its weapon-specific kick for the VR muzzle after that.
                local vertical = capped and math.lerp(up, down, math.random()) or vertical_delta
                local base = P.current_fire_base
                if not base then
                    return
                end
                P.pending_by_base[base] = {
                    sequence = P.current_fire_sequence,
                    vertical = vertical,
                    horizontal = (kick.h.accumulated or 0) - before.horizontal
                }
            end
        end)
    end)
end

if PlayerStandardVR then
    install("PlayerStandardVR._check_fire_per_weapon", function()
        Hooks:PreHook(PlayerStandardVR, "_check_fire_per_weapon", "PD2VRPhysical10_FireBefore", function(self, _, _, _, _, base)
            P.fire_sequence = P.fire_sequence + 1
            P.current_fire_sequence = P.fire_sequence
            P.current_fire_base = base
        end)
        Hooks:PostHook(PlayerStandardVR, "_check_fire_per_weapon", "PD2VRPhysical10_FireAfter", function()
            P.current_fire_base = nil
            P.current_fire_sequence = nil
        end)
    end)
end

if PlayerHandStateWeapon then
    install("Weapon.suppress_nonfirearm_kick", function()
        local original = PlayerHandStateWeapon.set_wanted_weapon_kick
        PlayerHandStateWeapon.set_wanted_weapon_kick = function(self, amount)
            local base = self._weapon_unit and alive(self._weapon_unit) and self._weapon_unit:base()
            local reason = no_recoil_reason(base)
            if P.enabled and reason then
                return
            end
            return original(self, amount)
        end
    end)
    install("Weapon.set_wanted_weapon_kick", function()
        Hooks:PostHook(PlayerHandStateWeapon, "set_wanted_weapon_kick", "PD2VRPhysical04_Impulse", function(self, amount)
            local ok, err = pcall(add_impulse, self, amount)
            if not ok then emit("UPDATE_ERROR impulse " .. tostring(err)) end
        end)
    end)
    install("Weapon.update", function()
        Hooks:PostHook(PlayerHandStateWeapon, "update", "PD2VRPhysical04_Update", function(self, _, dt)
            local ok, err = pcall(update_weapon, self, dt)
            if not ok then emit("UPDATE_ERROR rotation " .. tostring(err)) end
        end)
    end)
end

if PlayerHandStateAkimbo then
    install("Akimbo.set_wanted_weapon_kick", function()
        Hooks:PostHook(PlayerHandStateAkimbo, "set_wanted_weapon_kick", "PD2VRPhysical10_AkimboImpulse", function(self, amount)
            local ok, err = pcall(add_impulse, self, amount)
            if not ok then emit("UPDATE_ERROR akimbo_impulse " .. tostring(err)) end
        end)
    end)
    install("Akimbo.update", function()
        Hooks:PostHook(PlayerHandStateAkimbo, "update", "PD2VRPhysical10_AkimboUpdate", function(self, _, dt)
            local ok, err = pcall(update_weapon, self, dt)
            if not ok then emit("UPDATE_ERROR akimbo_rotation " .. tostring(err)) end
        end)
    end)
end

if WeaponLaser then
    install("WeaponLaser.update", function()
        Hooks:PreHook(WeaponLaser, "update", "PD2VRPhysical13_LaserTransformAlign", function(self)
            local ok, err = pcall(function()
                local base = P.laser_owner[self]
                if not P.enabled or not base or not base._unit or not alive(base._unit) or
                   base:get_active_gadget() ~= self or not self._laser_obj then
                    return
                end
                local fire_object = base:fire_object()
                if not fire_object then
                    return
                end
                -- VR Fixes' hand-based position drifts from the laser emitter.
                self._custom_position = nil
                self:set_rotation(fire_object:rotation())
            end)
            if not ok then emit("LASER_ALIGN_ERROR " .. tostring(err)) end
        end)
    end)
end

emit("READY enabled=" .. tostring(P.enabled))
