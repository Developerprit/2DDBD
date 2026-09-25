class_name StateMachine
extends Node
## A tiny, allocation-light finite state machine.
##
## States are plain objects registered by name; the machine owns the transition
## bookkeeping. Both the survivor and the killer drive every behaviour through
## one of these, which keeps the actor scripts readable and makes it trivial to
## reason about "what can happen next".

class State:
	extends RefCounted
	var machine: StateMachine
	var actor: Node
	var state_name := "state"

	func _init(m: StateMachine, a: Node) -> void:
		machine = m
		actor = a

	func enter(_msg: Dictionary = {}) -> void:
		pass

	func exit() -> void:
		pass

	func update(_delta: float) -> void:
		pass

	func physics(_delta: float) -> void:
		pass

	## Return true to allow the transition into `to`.
	func can_transition_to(_to: String) -> bool:
		return true

	func debug_color() -> Color:
		return Color.WHITE


signal state_changed(from: String, to: String)

## The owning node. States reach it through State.actor; the machine keeps its
## own reference so it can report state changes back to the actor.
var actor: Node = null

var states: Dictionary = {}
var current: State = null
var current_name := ""
var previous_name := ""
var time_in_state := 0.0
var locked := false

var history: Array[String] = []
const HISTORY_MAX := 12


func _ready() -> void:
	set_physics_process(true)
	set_process(true)


func register(state_name: String, state: State) -> void:
	state.state_name = state_name
	states[state_name] = state


func has_state(n: String) -> bool:
	return states.has(n)


func change(to: String, msg: Dictionary = {}) -> bool:
	if not states.has(to):
		push_warning("StateMachine: unknown state '%s'" % to)
		return false
	if current != null and current.state_name == to:
		return false
	if current != null and not current.can_transition_to(to):
		return false

	var from := current_name
	if current != null:
		current.exit()
	previous_name = from
	current = states[to]
	current_name = to
	time_in_state = 0.0
	current.enter(msg)

	history.append(to)
	if history.size() > HISTORY_MAX:
		history.pop_front()

	var owner_actor: Node = current.actor if current != null else null
	if owner_actor != null and owner_actor.has_method("on_state_changed"):
		owner_actor.on_state_changed(from, to)
	state_changed.emit(from, to)
	return true


func force(to: String, msg: Dictionary = {}) -> bool:
	if current != null:
		current.exit()
	current = null
	current_name = ""
	return change(to, msg)


func _process(delta: float) -> void:
	if current == null:
		return
	time_in_state += delta
	if not locked:
		current.update(delta)


func _physics_process(delta: float) -> void:
	if current != null and not locked:
		current.physics(delta)
