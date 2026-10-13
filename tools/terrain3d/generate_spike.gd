extends SceneTree
## Recreates the authored V4 baseline; never runs automatically over editor edits.
const DIR := "res://source/common/gameplay/maps/terrain3d_spike"
const SIZE := 64

func _initialize() -> void:
	call_deferred("generate")

static func height_at(x: float, z: float) -> float:
	x *= 4.0
	z *= 4.0
	var hill: float = 12.0*exp(-((x-80.0)*(x-80.0)+(z-128.0)*(z-128.0))/1250.0)
	var ridge: float = 28.0*exp(-(x-148.0)*(x-148.0)/72.0-(z-120.0)*(z-120.0)/2450.0)
	var hollow: float = -3.5*exp(-((x-85.0)*(x-85.0)+(z-195.0)*(z-195.0))/648.0)
	var shore: float = -5.0*smoothstep(196.0,222.0,x)
	return (hill+ridge+hollow+shore+0.12*sin(x*0.07)*sin(z*0.09))/4.0

static func path_x(z: float) -> float:
	return (52.0+22.0*sin((z*4.0-25.0)*0.018))/4.0

func generate() -> void:
	if not ClassDB.class_exists("Terrain3D"):
		push_error("Install tools/terrain3d/setup.py before generating V4")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(DIR+"/data")
	DirAccess.make_dir_recursive_absolute(DIR+"/materials")
	var terrain = ClassDB.instantiate("Terrain3D")
	root.add_child(terrain)
	terrain.collision.mode = 3
	terrain.collision.layer = 17
	terrain.material.world_background = 0
	terrain.material.auto_shader = true
	terrain.material.set_shader_param("auto_base_texture",3)
	terrain.material.set_shader_param("auto_overlay_texture",0)
	terrain.material.set_shader_param("auto_slope",4.0)
	terrain.material.set_shader_param("blend_sharpness",0.75)
	var assets = ClassDB.instantiate("Terrain3DAssets")
	for id: int in 4:
		assets.set_texture(id,make_texture(id))
	terrain.assets = assets
	var heights := Image.create(SIZE,SIZE,false,Image.FORMAT_RF)
	var bytes := PackedByteArray()
	bytes.resize(SIZE*SIZE*4)
	var colors := Image.create(SIZE,SIZE,false,Image.FORMAT_RGBA8)
	for z: int in SIZE:
		for x: int in SIZE:
			var h: float = height_at(x,z)
			heights.set_pixel(x,z,Color(h,0,0))
			var road: float = 1.0-smoothstep(0.55,1.125,absf(x-path_x(z)))
			var dirt: float = clampf(0.35+0.3*sin(x*0.22)*sin(z*0.26),0,1)
			var base: int = 0
			var overlay: int = 3
			var blend: float = 0.0
			var automatic: int = 1
			if x<26 and z<26:
				overlay = 1
				blend = dirt
				automatic = 0
			if road > 0.0:
				overlay = 2
				blend = road
				automatic = 0
			var navigable: int = 2 if h > -0.35 and x>2 and x<61 and z>2 and z<61 else 0
			var control: int = (base<<27)|(overlay<<22)|(int(blend*255.0)<<14)|navigable|automatic
			bytes.encode_u32((z*SIZE+x)*4,control)
			var macro: float = 0.94+0.06*sin(x*0.14)*cos(z*0.16)
			colors.set_pixel(x,z,Color(macro,macro,macro,0.5))
	var control := Image.create_from_data(SIZE,SIZE,false,Image.FORMAT_RF,bytes)
	# Size belongs to persisted Terrain3DRegion, not a Terrain3D scene migration.
	var region = ClassDB.instantiate("Terrain3DRegion")
	region.region_size = SIZE
	region.vertex_spacing = 1.0
	region.location = Vector2i.ZERO
	region.set_maps([heights,control,colors])
	region.calc_height_range()
	assert(region.save(DIR+"/data/terrain3d_00_00.res") == OK)
	assert(ResourceSaver.save(assets,DIR+"/terrain_assets.tres") == OK)
	assert(ResourceSaver.save(terrain.material,DIR+"/terrain_material.tres") == OK)
	print("TERRAIN3D_SPIKE_GENERATED: persisted 64m region, 1m samples, four packed PBR layers; navigation deferred until persistence gate")
	quit()

func make_texture(id: int) -> Resource:
	var names: Array[String] = ["grass","dirt","path","rock"]
	var bases: Array[Color] = [Color("53663d"),Color("77604a"),Color("ab956f"),Color("727b7d")]
	var albedo := Image.create(256,256,false,Image.FORMAT_RGBA8)
	var normal := Image.create(256,256,false,Image.FORMAT_RGBA8)
	# Periodic analytic grain keeps these modest temporary textures seamless.
	for z: int in 256:
		for x: int in 256:
			var u: float = TAU*x/256.0
			var v: float = TAU*z/256.0
			var grain: float = 0.5+0.18*sin(u*5+id)*cos(v*7)+0.12*sin(u*19+v*13)
			var c: Color = bases[id]*(0.78+0.4*grain)
			c.a = grain
			albedo.set_pixel(x,z,c)
			var dx: float = 0.18*5*cos(u*5+id)*cos(v*7)+0.12*19*cos(u*19+v*13)
			var dz: float = -0.18*7*sin(u*5+id)*sin(v*7)+0.12*13*cos(u*19+v*13)
			var n: Vector3 = Vector3(-dx*0.08,-dz*0.08,1).normalized()
			normal.set_pixel(x,z,Color(n.x*0.5+0.5,n.y*0.5+0.5,n.z*0.5+0.5,0.82 if id!=3 else 0.9))
	albedo.generate_mipmaps()
	normal.generate_mipmaps()
	var a := ImageTexture.create_from_image(albedo)
	var n := ImageTexture.create_from_image(normal)
	assert(ResourceSaver.save(a,DIR+"/materials/"+names[id]+"_albedo_height.res") == OK)
	assert(ResourceSaver.save(n,DIR+"/materials/"+names[id]+"_normal_roughness.res") == OK)
	var texture = ClassDB.instantiate("Terrain3DTextureAsset")
	texture.name = names[id].capitalize()
	texture.id = id
	texture.albedo_texture = load(DIR+"/materials/"+names[id]+"_albedo_height.res")
	texture.normal_texture = load(DIR+"/materials/"+names[id]+"_normal_roughness.res")
	texture.uv_scale = 0.22
	texture.detiling_rotation = 0.12
	texture.detiling_shift = 0.15
	texture.normal_depth = 0.35
	return texture
