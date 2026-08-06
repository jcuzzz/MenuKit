@tool
class_name MKJsonCodec
extends RefCounted
## The ONE JSON type-envelope implementation for MenuKit's shipped default stores (plan §4.3, §4.5).
##
## JSON carries strings, numbers, bools, null, arrays and objects — and exactly one number type. Two
## consequences bite a persisted store: a [Vector2i] has no JSON form at all, and an [int] comes back
## as a [float]. This class wraps both cases in a self-describing envelope
## [code]{"__mk_type": "<type>", "v": <payload>}[/code] and unwraps it on the way in, recursing
## through arrays and dictionaries because a stored value can be a container of them.
##
## [b]Why it is static and shared.[/b] [MKJsonSettingsBackend] carried this logic as private
## [code]_encode[/code]/[code]_decode[/code] methods first; [MKJsonProfileBackend] then needed the
## same thing. Copying the pair into the second backend would be two implementations of one persisted
## format — the shape that drifts into two backends decoding the same bytes differently, which is
## unrecoverable by the time anyone notices. Both backends now delegate here. Static, like [MKFocus]
## and [MKTheme], because there is no per-instance state to hold: encoding is a pure function of the
## value.
##
## [b]Why [code]envelope_ints[/code] is a flag rather than always-on.[/b] The two callers genuinely
## want different things, and the difference is not a preference:
## [br]- [MKJsonSettingsBackend] passes [code]false[/code]. Its persisted format predates the int
##   envelope and is already shipped in this repo, and every application site in that class coerces
##   with an explicit [code]int(...)[/code] anyway (window mode, vsync, max FPS, resolution
##   components). Enveloping its ints would change bytes for values nothing reads as an int, for
##   zero behavioural gain, and would make every settings file this repo has ever written a
##   mixed-format file.
## [br]- [MKJsonProfileBackend] passes [code]true[/code]. Its payloads are [i]opaque host
##   dictionaries[/i] (plan §4.5: the creation flow's payload is stored verbatim and handed back
##   verbatim). MenuKit has no idea which fields are meant to be ints, so it cannot coerce at the
##   read site the way the settings backend does — its only options are int fidelity or a silent
##   lossy conversion of somebody else's data. Fidelity wins.
##
## [b]The tag vocabulary is a persisted-format surface[/b] (plan §4.8's versioning rule). ADDING a
## tag is additive: an old reader meets an unknown tag as a plain dictionary, which is what it
## already did with any object it did not recognise. RENAMING or repurposing one is [b]Breaking[/b]
## and belongs in the CHANGELOG as such, because files already on users' disks carry the old spelling.
##
## Decoding is deliberately tolerant of BOTH tags regardless of which backend is reading: the bytes
## on disk are the authority, not the flag the current caller happens to pass. That is what lets a
## file written by one configuration be read by another without a migration step.

## The discriminator key. Chosen with the [code]__mk_[/code] prefix so it cannot collide with a host
## payload field by accident — a host field literally named [code]__mk_type[/code] is a wiring
## mistake, not a coincidence.
const TYPE_TAG := "__mk_type"

## The payload key inside an envelope.
const TYPE_PAYLOAD := "v"

## The tag values themselves. Named [code]TAG_*[/code] rather than [code]TYPE_*[/code] on purpose:
## a [code]const TYPE_INT := "int"[/code] here would SHADOW [constant @GlobalScope.TYPE_INT] for the
## whole script, so every [method @GlobalScope.typeof] comparison below would silently be comparing
## an int against the String "int" — always false, and the int envelope would quietly never fire.
const TAG_VECTOR2I := "Vector2i"
const TAG_INT := "int"


## Wraps the types JSON cannot carry faithfully, recursing through containers.
##
## [param envelope_ints] gates the [int] envelope only; [Vector2i] is always enveloped, because
## without it the value is not merely imprecise but absent from the format entirely.
static func encode_value(value: Variant, envelope_ints: bool) -> Variant:
	if value is Vector2i:
		var v := value as Vector2i
		return {TYPE_TAG: TAG_VECTOR2I, TYPE_PAYLOAD: [v.x, v.y]}
	if envelope_ints and typeof(value) == TYPE_INT:
		# typeof(), not `value is int`, and the distinction is the point: a bool must stay a JSON
		# `true`/`false`. GDScript's `is` operator answers false for a bool tested against int (they
		# are separate Variant types), so `value is int` would in fact be correct here — but the
		# guard is written as an explicit type equality anyway, because "bools must not be enveloped"
		# is a rule of this format and a reader should not have to know an operator's edge-case
		# behaviour to see that it is enforced. A bool that ever reached the int branch would come
		# back from disk as 0/1 and every `if profile["hardcore"]:` in a host project would still
		# pass, which is the kind of wrong that is never noticed.
		return {TYPE_TAG: TAG_INT, TYPE_PAYLOAD: int(value)}
	if value is Array:
		var out: Array = []
		for item in value as Array:
			out.append(encode_value(item, envelope_ints))
		return out
	if value is Dictionary:
		var out_d := {}
		for key in (value as Dictionary).keys():
			out_d[key] = encode_value((value as Dictionary)[key], envelope_ints)
		return out_d
	return value


## The inverse. Decodes every known tag unconditionally — see the class note on tolerance.
##
## [param context] is only ever used to name the file in a malformed-envelope warning; it is optional
## so the documented call form [code]decode_value(value)[/code] stays valid, and callers that have a
## resolved path pass it so the warning names the file the user has to go look at (plan §4.8 wants
## the resolved [code]user://[/code] path in a diagnostic).
##
## A malformed envelope — right tag, wrong payload shape — decodes to [code]null[/code] with a
## warning naming the tag. That is the settings backend's long-standing behaviour, preserved
## verbatim: a hand-edited or truncated file is recoverable misconfiguration, so it warns rather than
## erroring, and it must not return a plausible-looking wrong value that then gets applied.
static func decode_value(value: Variant, context := "") -> Variant:
	if value is Dictionary:
		var d := value as Dictionary
		# Read the tag as a String rather than comparing the raw Variant: a hand-edited file can put
		# anything under the key, and a mismatched-type `==` is the kind of comparison that raises a
		# script error rather than answering false. An absent key stringifies to "", which matches no
		# tag and falls through to the plain-dictionary branch — the correct reading of an ordinary
		# host object.
		var tag := String(d.get(TYPE_TAG, ""))
		if tag == TAG_VECTOR2I:
			var payload: Variant = d.get(TYPE_PAYLOAD, null)
			if payload is Array and (payload as Array).size() == 2:
				return Vector2i(int((payload as Array)[0]), int((payload as Array)[1]))
			_warn_malformed(TAG_VECTOR2I, context)
			return null
		if tag == TAG_INT:
			var payload_i: Variant = d.get(TYPE_PAYLOAD, null)
			# int and float both accepted: JSON.stringify writes a whole number without a decimal
			# point, but a hand-edited file (or a re-encode through another tool) can present 3.0.
			# Rejecting that would quarantine-by-null a value that is unambiguous.
			if typeof(payload_i) == TYPE_INT or typeof(payload_i) == TYPE_FLOAT:
				return int(payload_i)
			_warn_malformed(TAG_INT, context)
			return null
		var out_d := {}
		for key in d.keys():
			out_d[key] = decode_value(d[key], context)
		return out_d
	if value is Array:
		var out: Array = []
		for item in value as Array:
			out.append(decode_value(item, context))
		return out
	return value


## Named so both malformed branches produce one message shape. The wording is the settings backend's
## original, generalised over the tag.
static func _warn_malformed(tag: String, context: String) -> void:
	var where := context if not context.is_empty() else "a MenuKit JSON store"
	MKLog.warn("%s: malformed %s envelope in %s — dropping it to null"
		% [MKLog.context("MKJsonCodec"), tag, where])
