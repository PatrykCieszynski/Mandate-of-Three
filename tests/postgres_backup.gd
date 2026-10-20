extends "res://tests/postgres_maintenance.gd"
func profile_file() -> String: return directory+("/restored/profiles.db" if round_number>=2 else "/profiles.db")
func account_file() -> String: return directory+("/restored/accounts.tres" if round_number>=2 else "/accounts.tres")
func close_roles(world: int, gateway: int, master: int) -> void:
	await super.close_roles(world,gateway,master)
	if round_number==1:
		# All actual supervised processes have exited and all grants were drained.
		# Close the fixture control session too: offline tooling refuses other SQL.
		pg.close()
		var output: Array=[]
		var code:=OS.execute(OS.get_environment("MANDATE_PG_FIXTURE_PYTHON"),[ProjectSettings.globalize_path("res://tests/postgres_backup_fixture.py")],output,true)
		assert(code==0,"offline bundle/restore: "+str(output))
		print(str(output))
		var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION").replace("dbname=mandate_readiness","dbname=mandate_restored")
		OS.set_environment("MANDATE_PG_FIXTURE_CONNECTION",connection)
		for role: String in ["world","master"]:
			var text: String=FileAccess.get_file_as_string(directory+"/"+role+".cfg")
			text=text.replace(directory+"/profiles.db",directory+"/restored/profiles.db").replace(directory+"/accounts.tres",directory+"/restored/accounts.tres")
			write(role+".cfg",text)
		assert(pg.open("postgresql",connection))
	if round_number==2:
		print("POSTGRES_BACKUP_OK: stopped realm bundle restored into another database/profile/account set, normal login/equipped UID and dirty checkpoint survive")
func blocked_native() -> void:
	pass # Existing maintenance suite separately owns the native blocked-drain case.
