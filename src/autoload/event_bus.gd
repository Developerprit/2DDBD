extends Node
## EventBus -- a global signal hub so actors never need to know about the UI.
## Every cross-system message in the game goes through here.

# --- Match lifecycle -------------------------------------------------------
signal match_started(role: int, killer_id: String, map_id: String)
signal match_phase_changed(phase: int)
signal match_ended(result: int, summary: Dictionary)
signal generator_completed(count: int, total: int)
signal generators_powered()
signal hatch_state_changed(is_open: bool)
signal exit_gate_progress(gate_id: int, ratio: float)
signal exit_gate_opened(gate_id: int)

# --- Survivor --------------------------------------------------------------
signal survivor_spawned(survivor: Node)
signal survivor_health_changed(survivor_id: int, health: int)
signal survivor_hooked(survivor_id: int, stage: int, hook_pos: Vector2)
signal survivor_unhooked(survivor_id: int)
signal survivor_escaped(survivor_id: int)
signal survivor_died(survivor_id: int)
signal survivor_interact_progress(survivor_id: int, kind: int, ratio: float)
signal survivor_interact_cancelled(survivor_id: int)
signal survivor_state_changed(survivor_id: int, state_name: String)
signal survivor_revealed(survivor_id: int, pos: Vector2, reason: String)

# --- Killer ----------------------------------------------------------------
signal killer_spawned(killer: Node)
signal killer_broke(pos: Vector2)        ## killer smashed a pallet/wall (Alert perk)
signal killer_attack(windup: bool)
signal killer_hit_survivor(killer_id: int, survivor_id: int, healthy: bool)
signal killer_carrying(survivor_id: int, carrying: bool)
signal killer_power_used(power_id: String, data: Dictionary)
signal bloodlust_changed(tier: int)

# --- Skill check -----------------------------------------------------------
signal skill_check_started(survivor_id: int, great_zone: float, good_zone: float, speed: float)
signal skill_check_resolved(survivor_id: int, grade: int)  ## 0 miss, 1 good, 2 great

# --- Perception / feedback -------------------------------------------------
signal terror_level(level: float)          ## 0..1 proximity to killer
signal chase_started(survivor_id: int)
signal chase_ended(survivor_id: int)
signal noise_emitted(pos: Vector2, radius: float, kind: String)

# --- UI / system -----------------------------------------------------------
signal toast(text: String, color: Color)
signal camera_shake(strength: float, duration: float)
signal bloodpoints_earned(category: String, amount: int)
signal pause_requested()
signal settings_changed()

# --- Network ---------------------------------------------------------------
signal net_peer_joined(id: int)
signal net_peer_left(id: int)
signal net_lobby_changed(lobby: Dictionary)
signal net_signal_ready(signal_text: String, kind: String)
