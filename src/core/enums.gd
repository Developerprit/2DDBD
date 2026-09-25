## Global enumerations shared across the whole project.
## Loaded via class_name so any script can use Enums.HEALTH.HEALTHY etc.
class_name Enums
extends RefCounted

enum Team { SURVIVOR, KILLER }

## Survivor health ladder. Mirrors Dead by Daylight's health states.
enum Health {
	HEALTHY,   ## full hp
	INJURED,   ## 1 hit taken
	DOWNED,    ## crawling, can be picked up
	DYING,     ## on the ground bleeding out (unhook-less down)
	HOOKED,    ## hanging on a hook
	ESCAPED,   ## left through gate / hatch
	DEAD,      ## sacrificed / bled out
}

## Hook stages: 1st hook is a full stage, struggle phase, then sacrifice.
enum HookStage { NONE, FIRST, STRUGGLE, SACRIFICED }

## Match phases, used to gate hatch spawn, exit gates and pacing.
enum MatchPhase { PREP, EARLY, MID, LATE, ENDED }

enum MatchResult { KILLER_WIN, SURVIVOR_WIN, DRAW }

## Movement gaits shared by both teams.
enum Gait { IDLE, WALK, RUN, CROUCH, CRAWL, CARRY }

## Direction sprite facing (8-way is generated, 4-way is rendered).
enum Facing { DOWN, UP, LEFT, RIGHT }

## Interaction kinds understood by Interactable.
enum InteractionKind {
	NONE,
	GENERATOR,
	HOOK,
	HOOKED_SELF,
	PALLET_DROP,
	PALLET_VAULT,
	PALLET_BREAK,
	WINDOW_VAULT,
	LOCKER_HIDE,
	LOCKER_GRAB,
	HATCH,
	EXIT_SWITCH,
	CHEST,
	HEAL_SELF,
	HEAL_OTHER,
	REVIVE,
	UNHOOK,
	TRAP_PLACE,
	TRAP_DISARM,
	TRAP_PICKUP,
	TRAP_ESCAPE,
	PICKUP_BODY,
	GRAB_CARRY,
}

## Perk trigger points. Each perk declares one hook into the pipeline.
enum PerkTrigger {
	PASSIVE,
	ON_GENERATOR_PROGRESS,
	ON_SKILLCHECK,
	ON_INJURED,
	ON_HOOKED,
	ON_UNHOOK,
	ON_HEAL,
	ON_VAULT,
	ON_CHASE,
	ON_MATCH_START,
	ON_MATCH_END,
	ON_KILLER_NEAR,
}

enum ItemKind { NONE, MEDKIT, FLASHLIGHT, TOOLBOX, MAP }

enum PowerKind { NONE, BEAR_TRAP }

enum NetMode { OFFLINE, LAN, P2P }

## Small helper so UI can pick a red=increase style tint (CN convention kept
## for numbers, but this game uses red for danger/heartbeat instead).
static func health_to_string(h: int) -> String:
	match h:
		Health.HEALTHY: return "healthy"
		Health.INJURED: return "injured"
		Health.DOWNED: return "downed"
		Health.DYING: return "dying"
		Health.HOOKED: return "hooked"
		Health.ESCAPED: return "escaped"
		Health.DEAD: return "dead"
	return "unknown"


static func is_out(h: int) -> bool:
	return h == Health.ESCAPED or h == Health.DEAD
