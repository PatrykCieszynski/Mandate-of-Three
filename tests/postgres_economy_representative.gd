extends "res://tests/postgres_realm_workload.gd"
## Separate arrival policy; reuse real runtimes, correlation/recovery and exact audits.
## No fixture SQL is executed during the measured arrival window.
var economic_accounts:=300
var peak_every:=450
var peak_seconds:=45
var peak_multiplier:=3.0
var started_us:=0
var initial_offers:=0
var offline_shops: Array[int]=[]
var visited_shops: Dictionary={}
var selected_offers: Dictionary={}
var demand: Dictionary={}
var outcomes_by_phase: Dictionary={}
var time_buckets: Dictionary={}
var request_contexts: Dictionary={}
var outcomes_by_start_phase: Dictionary={}
var phase_transitions: Dictionary={}
var successful_visited_shops: Dictionary={}
var peak_activity: Dictionary={}

func _ready() -> void:
	economic_accounts=int(OS.get_environment("MANDATE_ECONOMY_ACCOUNTS"))
	peak_every=int(OS.get_environment("MANDATE_ECONOMY_PEAK_EVERY"))
	peak_seconds=int(OS.get_environment("MANDATE_ECONOMY_PEAK_SECONDS"))
	peak_multiplier=float(OS.get_environment("MANDATE_ECONOMY_PEAK_MULTIPLIER"))
	if economic_accounts<=int(OS.get_environment("MANDATE_REALM_PLAYERS")) or peak_every<=peak_seconds or peak_seconds<1 or not is_finite(peak_multiplier) or peak_multiplier<=1:
		die("invalid representative population/peak configuration");return
	super._ready()

func population() -> Array[String]:
	var roles: Array[String]=[]
	for index: int in requested:
		roles.append("browser" if index%4==0 else ("heavy_buyer" if index%20==1 else "buyer"))
	return roles

func execute_seed(sql: String, bindings: Dictionary = {}) -> void:
	var result: Dictionary=pg.execute(sql,bindings)
	assert(result.ok,str(result))

func seed_catalogue() -> void:
	# The measured operations use normal runtime APIs. Direct SQL only prepares
	# legal, offline, independently owned shops before workers/measurement start.
	var sellers:=economic_accounts-requested
	execute_seed("INSERT INTO economy.accounts SELECT 10000+n FROM generate_series(0,CAST(:last AS INTEGER)) n;",{"last":sellers-1})
	execute_seed("INSERT INTO economy.characters SELECT 20000+n,10000+n FROM generate_series(0,CAST(:last AS INTEGER)) n;",{"last":sellers-1})
	execute_seed("INSERT INTO economy.account_wallets(account_id) SELECT 10000+n FROM generate_series(0,CAST(:last AS INTEGER)) n;",{"last":sellers-1})
	execute_seed("INSERT INTO economy.account_shops(shop_id,account_id,display_name,status) SELECT 10000+n,10000+n,'Offline shop '||n,'active' FROM generate_series(0,CAST(:last AS INTEGER)) n;",{"last":sellers-1})
	for shop: int in sellers: offline_shops.append(10000+shop)
	initial_offers=sellers*20
	for first: int in range(0,initial_offers,400):
		var batch: Dictionary={"first":first,"last":mini(first+399,initial_offers-1)}
		assert(pg.begin())
		execute_seed("INSERT INTO economy.item_instances(uid,owner_character_id,definition_id,amount,upgrade_level,affixes_json,sockets_json,revision) SELECT lpad(to_hex(100000+n),32,'0'),20000+n/20,'iron_sword',1,n%10,jsonb_build_array(jsonb_build_object('stat','monster_damage','value',CASE WHEN n%3=0 THEN 15 ELSE 5 END))::text,'[]',0 FROM generate_series(CAST(:first AS INTEGER),CAST(:last AS INTEGER)) n;",batch)
		execute_seed("INSERT INTO economy.item_custody(uid,location,owner_id,position,escrow_account_id,shop_id,offer_id) SELECT lpad(to_hex(100000+n),32,'0'),'shop_escrow',20000+n/20,n%5+(n%20/5)*10,10000+n/20,10000+n/20,lpad(to_hex(200000+n),32,'0') FROM generate_series(CAST(:first AS INTEGER),CAST(:last AS INTEGER)) n;",batch)
		execute_seed("INSERT INTO economy.shop_offers(offer_id,shop_id,account_id,item_uid,position,price_yang) SELECT lpad(to_hex(200000+n),32,'0'),10000+n/20,10000+n/20,lpad(to_hex(100000+n),32,'0'),n%5+(n%20/5)*10,10+n%997 FROM generate_series(CAST(:first AS INTEGER),CAST(:last AS INTEGER)) n;",batch)
		execute_seed("INSERT INTO economy.shop_cells SELECT c.shop_id,c.position+5*v,c.uid FROM economy.item_custody c CROSS JOIN generate_series(0,1) v WHERE c.offer_id BETWEEN :first AND :last;",{"first":"%032x" % (200000+int(batch.first)),"last":"%032x" % (200000+int(batch.last))})
		assert(pg.commit())
	for table: String in ["item_instances","shop_offers","item_affix_index"]: execute_seed("ANALYZE economy."+table+";")

func begin_window() -> void: started_us=Time.get_ticks_usec()
func phase_at(at_us: int) -> String:
	var elapsed: float=(at_us-started_us)/1000000.0
	if elapsed>=duration: return "tail"
	return "peak" if elapsed>=peak_every and fmod(elapsed,peak_every)<peak_seconds else "normal"
func phase() -> String:
	if not window_open: return "tail"
	# Preserve the generator's original window flag/clock policy exactly.
	var elapsed: float=(Time.get_ticks_usec()-started_us)/1000000.0
	return "peak" if elapsed>=peak_every and fmod(elapsed,peak_every)<peak_seconds else "normal"

func sample(key: String, us: int) -> void:
	super.sample(key,us)
	# Simulation/native-pool observations retain their observation-time cohort.
	if measuring: super.sample("phase:"+phase()+":"+key,us)

func request_started(peer: int, action: String, at_us: int) -> void:
	var cohort:=phase_at(at_us)
	request_contexts[peer]={"phase":cohort,"at_us":at_us}
	count_phase(outcomes_by_phase,"offered:"+action,at_us)
	increment(outcomes_by_start_phase,cohort+":offered:"+action)
	if cohort=="peak": increment(peak_row(at_us),"requests_started")

func request_admitted(peer: int, action: String) -> void:
	increment(outcomes_by_start_phase,str(request_contexts[peer].phase)+":admitted:"+action)

func request_sample(peer: int, key: String, us: int, at_us: int) -> void:
	# Same callback timestamps/latency; classify each request by its ORIGINAL start.
	super.sample(key,us)
	super.sample("phase:"+str(request_contexts[peer].phase)+":"+key,us)
	super.sample("completion_phase:"+phase_at(at_us)+":"+key,us)

func request_finished(peer: int, action: String, result: Dictionary, at_us: int, admitted: bool) -> void:
	var outcome: String="ok" if result.get("ok",false) else ("terminal_rejected" if admitted else "admission_refused")
	var cohort: String=request_contexts[peer].phase
	increment(outcomes_by_start_phase,cohort+":"+outcome+":"+action)
	increment(phase_transitions,cohort+"->"+phase_at(at_us)+":"+outcome+":"+action)
	count_phase(outcomes_by_phase,outcome+":"+action,at_us)
	request_contexts.erase(peer)

func increment(target: Dictionary, key: String) -> void: target[key]=int(target.get(key,0))+1
func peak_row(at_us: int) -> Dictionary:
	var index:=int((at_us-started_us)/1000000.0/peak_every)
	var key:=str(index)
	if not peak_activity.has(key): peak_activity[key]={}
	return peak_activity[key]

func count_phase(target: Dictionary, key: String, at_us: int = 0) -> void:
	if at_us==0: at_us=Time.get_ticks_usec()
	var cohort:=phase_at(at_us)
	var bucket: String=cohort+":"+key
	target[bucket]=int(target.get(bucket,0))+1
	# Thirty-second demand/outcome series exposes the onset and recovery of peaks.
	var interval:=str(maxi(0,int((at_us-started_us)/30000000)))
	if not time_buckets.has(interval): time_buckets[interval]={}
	var row: Dictionary=time_buckets[interval]
	row[key]=int(row.get(key,0))+1
	if cohort=="peak" and key in ["scheduled","started"]: increment(peak_row(at_us),key)

func error(action: String, reason: String) -> void:
	super.error(action,reason)
	count_phase(outcomes_by_phase,"error:"+action+":"+reason)

func search_payload(actor: Dictionary) -> Dictionary:
	var payload:=SEARCH.duplicate(true)
	# Different interests and price bands, not every account's cheapest first page.
	payload.upgrade_min=actor.rng.randi_range(0,7)
	payload.upgrade_max=mini(9,int(payload.upgrade_min)+2)
	payload.price_min=actor.rng.randi_range(0,7)*100
	payload.price_max=int(payload.price_min)+300
	payload.sort="price_asc" if actor.rng.randf()<0.5 else "price_desc"
	return payload

func actor_loop(actor: Dictionary) -> void:
	active_loops+=1;actor.busy=false
	var budget: float=actor.rng.randf()
	var previous:=Time.get_ticks_usec()
	while running and not failed:
		await get_tree().create_timer(0.1).timeout
		if not running: break
		var now:=Time.get_ticks_usec()
		var interval:=3.0 if actor.role=="heavy_buyer" else 8.0
		budget+=(now-previous)/1000000.0/interval*(peak_multiplier if phase()=="peak" else 1.0)
		previous=now
		while budget>=1.0:
			budget-=1.0;count_phase(demand,"scheduled")
			if actor.busy: count_phase(demand,"account_busy");continue
			if not ready(actor.peer): count_phase(demand,"runtime_not_ready");continue
			actor.busy=true;count_phase(demand,"started")
			story(actor) # At most one in-flight story/account, no hidden backlog.
	active_loops-=1

func story(actor: Dictionary) -> void:
	active_loops+=1;stats.stories_started+=1;actor.stories+=1
	var began:=Time.get_ticks_usec();var ok:=true
	# Browsers never buy. Heavy traders generate more reads; purchases per active
	# buyer remain bounded by pacing, not a runtime-capacity override.
	var buy_probability:=0.04 if actor.role=="heavy_buyer" else 0.12
	var purchase: bool=actor.role!="browser" and actor.rng.randf()<buy_probability
	if actor.rng.randf()<0.65:
		var found: Dictionary=await search(actor,"",actor.rng.randf()<0.3)
		ok=found.get("ok",false)
	if purchase or actor.rng.randf()<0.45:
		await pause(actor,0.15,0.6)
		var shop: int=offline_shops[actor.rng.randi_range(0,offline_shops.size()-1)]
		visited_shops[shop]=int(visited_shops.get(shop,0))+1
		var visit: Dictionary=await command(actor,"visit",{"shop_id":shop})
		if visit.get("ok",false): successful_visited_shops[shop]=true
		ok=ok and visit.get("ok",false)
		if purchase and visit.get("ok",false):
			var offers: Array=visit.offers.duplicate()
			var limit:=5 if actor.rng.randf()<0.02 else 1
			for _index: int in mini(limit,offers.size()):
				var at: int=actor.rng.randi_range(0,offers.size()-1)
				var offer: Dictionary=offers.pop_at(at)
				selected_offers[offer.offer_id]=int(selected_offers.get(offer.offer_id,0))+1
				await pause(actor,0.15,0.6)
				var bought: Dictionary=await command(actor,"buy",{"shop_id":shop,"offer_id":offer.offer_id,"revision":int(offer.revision),"price":int(offer.price)})
				ok=ok and bought.get("ok",false)
	if ok: stats.stories_completed+=1;actor.completed+=1
	else: stats.stories_failed+=1
	sample("story:"+actor.role,Time.get_ticks_usec()-began)
	actor.busy=false;active_loops-=1

static func coverage(expected: float, observed: bool) -> Dictionary:
	# Eligibility is a coverage-confidence heuristic, never a throughput target.
	# A small/role-restricted diagnostic can legitimately miss a random action.
	var required: bool=expected>=8.0
	return {"expected_opportunities":expected,"required":required,"observed":observed,
		"status":"PASS" if observed else ("FAIL" if required else ("NOT_APPLICABLE" if expected==0 else "DIAGNOSTIC_NOT_OBSERVED"))}

static func sanity(expected: Dictionary, observed: Dictionary, planned_peaks: Array) -> Dictionary:
	var checks: Dictionary={}
	for key: String in ["search","visit","purchase","dispersed_shops"]:
		checks[key]=coverage(float(expected[key]),bool(observed.get(key,false)))
	for peak: Dictionary in planned_peaks:
		checks["peak:"+str(peak.index)]=coverage(float(peak.expected_opportunities),bool(peak.executed))
	var passed:=true
	for check: Dictionary in checks.values():
		if check.status=="FAIL": passed=false
	return {"passed":passed,"checks":checks,"eligibility":"expected opportunities >= 8; no performance or success-rate gate; bulk never required"}

func extend_report(report: Dictionary) -> void:
	var remaining: int=pg.query("SELECT count(*) AS n FROM economy.shop_offers;").rows[0].n
	var repeats:=0
	for attempts: int in selected_offers.values(): repeats+=maxi(attempts-1,0)
	report.case="Representative Economy"
	report.scenario_version=1 # Arrival policy is unchanged.
	report.metrics_version=4 # Request cohorts now refer to start, not observation.
	report["workload_configuration"]={"economic_accounts":economic_accounts,"offline_sellers":offline_shops.size(),"offers_per_seller":20,"peak_every_seconds":peak_every,"peak_seconds":peak_seconds,"peak_multiplier":peak_multiplier}
	report["representative"]={
		"economic_accounts":economic_accounts,"offline_sellers":offline_shops.size(),
		"initial_offers":initial_offers,"remaining_offers":remaining,
		"unsold_share":remaining/float(initial_offers),
		"visited_shops":visited_shops.size(),"visits_by_shop":visited_shops,
		"repeated_offer_attempts":repeats,"demand":demand,
		"outcomes_by_phase":outcomes_by_phase,"outcomes_by_start_phase":outcomes_by_start_phase,
		"request_phase_transitions":phase_transitions,"successful_visited_shops":successful_visited_shops.size(),
		"normal_interarrival_seconds":8,"heavy_interarrival_seconds":3,
		"buyer_purchase_probability":0.12,"heavy_purchase_probability":0.04,
		"bulk_probability":0.02,"latency_phase_at":"request start; completion_phase uses terminal callback timestamp",
		"responsiveness_acceptance":"not yet agreed","max_throughput_claim":false,
		"successful_read_actions":int(stats.searches_ok)+int(action_successes.get("visit",0)),
		"successful_write_actions":int(action_successes.get("buy",0))
	}
	report.mechanisms=["auction_search","offline_shop_visit","dispersed_purchase","rare_bulk_purchase","bounded_account_admission","controlled_peaks"]
	var peak_time:=0
	for at: int in range(peak_every,duration,peak_every): peak_time+=mini(peak_seconds,duration-at)
	var opportunity_rate:=0.0;var purchase_rate:=0.0
	for actor: Dictionary in actors:
		var rate:=1.0/(3.0 if actor.role=="heavy_buyer" else 8.0)
		opportunity_rate+=rate
		if actor.role!="browser": purchase_rate+=rate*(0.04 if actor.role=="heavy_buyer" else 0.12)
	var weighted_seconds: float=duration-peak_time+peak_time*peak_multiplier
	var expected: Dictionary={"search":weighted_seconds*opportunity_rate*0.65,"visit":weighted_seconds*opportunity_rate*0.45,"purchase":weighted_seconds*purchase_rate,"dispersed_shops":weighted_seconds*opportunity_rate*0.45 if offline_shops.size()>1 else 0.0}
	var peaks: Array=[]
	for at: int in range(peak_every,duration,peak_every):
		var index:=at/peak_every
		var activity: Dictionary=peak_activity.get(str(index),{})
		peaks.append({"index":index,"start_seconds":at,"seconds":mini(peak_seconds,duration-at),"expected_opportunities":mini(peak_seconds,duration-at)*peak_multiplier*opportunity_rate,"activity":activity,"executed":int(activity.get("scheduled",0))>0 and int(activity.get("started",0))>0 and int(activity.get("requests_started",0))>0})
	var checked:=sanity(expected,{"search":int(stats.searches_ok)>0,"visit":int(action_successes.get("visit",0))>0,"purchase":int(action_successes.get("buy",0))>0,"dispersed_shops":successful_visited_shops.size()>1},peaks)
	report.representative["planned_peaks"]=peaks
	report.representative["profile_sanity"]=checked
	report.representative["phase_seconds"]={"normal":duration-peak_time,"peak":peak_time,"tail":report.tail_seconds}
	report.representative["thirty_second_buckets"]=time_buckets
	report.representative["profile_checks"]={"most_offers_unsold":remaining>initial_offers/2,"purchases_observed":int(action_successes.get("buy",0))>0}
	report.limits["constant_background_simulation"]=true
	# Accounting identities describe the report, not a target completion count.
	assert(int(stats.attempts)==int(stats.admitted)+int(stats.get("terminal_admission_refused",0)))
	assert(int(stats.admitted)==int(stats.completed)+int(stats.conflicts))
	assert(request_contexts.is_empty(),"all observed requests must terminate")
	var scheduled:=0;var classified:=0
	for label: String in ["normal","peak","tail"]:
		scheduled+=int(demand.get(label+":scheduled",0))
		for key: String in ["started","account_busy","runtime_not_ready"]: classified+=int(demand.get(label+":"+key,0))
	assert(scheduled==classified,"each opportunity is started or skipped exactly once")
	if not checked.passed: die("representative profile coverage: "+JSON.stringify(checked))
