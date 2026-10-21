extends Node
## Report/coverage contracts only: no SQL, performance targets or scheduler changes.
const Harness = preload("res://tests/postgres_economy_representative.gd")

func _ready() -> void:
	var expected: Dictionary={"search":100.0,"visit":100.0,"purchase":10.0,"dispersed_shops":100.0}
	var observed: Dictionary={"search":true,"visit":true,"purchase":true,"dispersed_shops":true}
	assert(Harness.sanity(expected,observed,[{"index":1,"expected_opportunities":20,"executed":true}]).passed)
	for missing: String in expected:
		var broken:=observed.duplicate();broken[missing]=false
		assert(not Harness.sanity(expected,broken,[]).passed,"missing declared scenario must fail")
	assert(not Harness.sanity(expected,observed,[{"index":1,"expected_opportunities":20,"executed":false}]).passed)
	# Tiny diagnostics/partial peaks and browser-only configurations are legitimate.
	assert(Harness.sanity({"search":0.1,"visit":0.1,"purchase":0.0,"dispersed_shops":0.0},{},[{"index":1,"expected_opportunities":0.01,"executed":false}]).passed)
	assert(Harness.sanity(expected,observed,[]).passed,"no configured peak in window requires none")
	var harness:=Harness.new()
	harness.started_us=1000000;harness.duration=90;harness.peak_every=30;harness.peak_seconds=5;harness.measuring=true;harness.window_open=true
	# Normal -> peak and peak -> normal retain start cohort and callback duration.
	for times: Array in [[29000000,31000000,"normal","peak"],[31000000,36000000,"peak","normal"],[90000000,91000000,"normal","tail"]]:
		var start: int=times[0];var end: int=times[1]
		harness.request_started(7,"buy",start)
		harness.request_admitted(7,"buy")
		harness.request_sample(7,"action_ok:buy",end-start,end)
		harness.request_finished(7,"buy",{"ok":true},end,true)
		assert(harness.phase_transitions[str(times[2])+"->"+str(times[3])+":ok:buy"]==1)
	assert(harness.histograms["phase:peak:action_ok:buy"].count==1)
	assert(harness.histograms["phase:normal:action_ok:buy"].count==2)
	assert(harness.histograms["action_ok:buy"].total==8000000,"callback-derived durations unchanged")
	assert(harness.request_contexts.is_empty())
	harness.world.free();harness.simulation.free();harness.free()
	print("REPRESENTATIVE_PROFILE_CONTRACT_OK")
	get_tree().quit()
