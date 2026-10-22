extends RefCounted
## Test-only nested wall timers. Totals are aggregated per physics tick, not
## per-actor percentiles. Collection itself is included in enclosing buckets.
static var enabled:=false
static var current: Dictionary={}
static var samples: Dictionary={}
static var calls: Dictionary={}

static func add(key: String, started: int) -> void:
	if not enabled: return
	current[key]=int(current.get(key,0))+Time.get_ticks_usec()-started
	calls[key]=int(calls.get(key,0))+1

static func begin_tick() -> void:
	current.clear()

static func end_tick() -> void:
	if not enabled: return
	for key: String in current:
		if not samples.has(key): samples[key]=[]
		samples[key].append(current[key])

static func reset() -> void:
	current.clear();samples.clear();calls.clear()

static func report() -> Dictionary:
	var result: Dictionary={}
	for key: String in samples:
		var ordered: Array=samples[key].duplicate();ordered.sort()
		var total:=0
		for us: int in ordered: total+=us
		var row: Dictionary={"sampled_ticks":ordered.size(),"calls":calls[key],"total_us":total,"mean_ms_per_sampled_tick":total/float(ordered.size())/1000.0,"max_ms":ordered[-1]/1000.0}
		for p: int in [50,95,99]: row["p%d_ms" % p]=ordered[ceili(ordered.size()*p/100.0)-1]/1000.0
		result[key]=row
	return result
