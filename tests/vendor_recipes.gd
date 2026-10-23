extends Node
## Observable allocation contracts, not fixed production balance values.
func _ready() -> void:
	var inventory: Array=[]
	var selection: Array=[]
	for i: int in 10:
		var book:=ItemInstance.create(ItemDefinitions.BOOK_AURA,1,[])
		inventory.append(book.to_snapshot())
		selection.append({"uid":book.uid,"revision":0,"amount":1})
	for count: int in [1,4,5,10]:
		var result:=VendorResolver.resolve(selection.slice(0,count),inventory,VendorRecipes.definitions(),VendorRecipes.pools())
		assert(result.ok)
		assert(result.rewards.size()==(0 if count<5 else 1))
		if count>=5: assert(result.rewards[0].quantity==count/5 and result.yang==0)
		else: assert(result.yang==count*ItemDefinitions.BOOK_AURA.vendor_price)
	var sword:=ItemInstance.create(ItemDefinitions.IRON_SWORD,1,[])
	inventory.append(sword.to_snapshot())
	var mixed:=selection.slice(0,5)
	mixed.append({"uid":sword.uid,"revision":0,"amount":1})
	var result:=VendorResolver.resolve(mixed,inventory,VendorRecipes.definitions(),VendorRecipes.pools())
	assert(result.ok and result.yang==ItemDefinitions.IRON_SWORD.vendor_price and result.rewards[0].quantity==1)
	mixed.reverse()
	assert(VendorResolver.resolve(mixed,inventory,VendorRecipes.definitions(),VendorRecipes.pools())==result,"drag order cannot change allocation")
	var no_recipe:=selection.slice(0,4);no_recipe.append({"uid":sword.uid,"revision":0,"amount":1})
	result=VendorResolver.resolve(no_recipe,inventory,VendorRecipes.definitions(),VendorRecipes.pools())
	assert(result.rewards.is_empty() and result.yang==4*ItemDefinitions.BOOK_AURA.vendor_price+ItemDefinitions.IRON_SWORD.vendor_price)
	var competing:=VendorRecipeDefinition.new()
	competing.recipe_id=&"priority_fixture";competing.priority=200
	competing.inputs=[{"definition_id":"skill_book_aura","quantity":3}]
	competing.reward_pool=&"random_skill_book"
	result=VendorResolver.resolve(selection.slice(0,5),inventory,[VendorRecipes.RECYCLE,competing],VendorRecipes.pools())
	assert(result.recipes.get("priority_fixture")==1 and not result.recipes.has("recycle_skill_books"),"units cannot feed overlapping recipes")
	assert(result.yang==2*ItemDefinitions.BOOK_AURA.vendor_price)
	competing.inputs=[{"category":"book","quantity":2}]
	assert(VendorResolver.resolve(selection.slice(0,4),inventory,[competing],VendorRecipes.pools()).rewards[0].quantity==2)
	var duplicate:=mixed.duplicate(true);duplicate.append(mixed[0])
	assert(VendorResolver.cart(duplicate).is_empty())
	var stale:=selection.slice(0,1).duplicate(true);stale[0].revision=1
	assert(VendorResolver.resolve(stale,inventory,[],{}).error=="stale")
	inventory[0].location="equipment"
	assert(VendorResolver.resolve(selection.slice(0,1),inventory,[],{}).error=="owner")
	inventory[0].location="bag";inventory[0].locked=true
	assert(VendorResolver.resolve(selection.slice(0,1),inventory,[],{}).error=="unsellable")
	var ore:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,1,[]);ore.amount=10
	assert(VendorResolver.resolve([{"uid":ore.uid,"revision":0,"amount":3}],[ore.to_snapshot()],[],{}).yang==3*ItemDefinitions.UPGRADE_ORE.vendor_price)
	var material_mix:=selection.slice(0,5);material_mix.append({"uid":ore.uid,"revision":0,"amount":3})
	var material_inventory:=inventory.duplicate(true);material_inventory[0].erase("locked");material_inventory.append(ore.to_snapshot())
	result=VendorResolver.resolve(material_mix,material_inventory,VendorRecipes.definitions(),VendorRecipes.pools())
	assert(result.rewards[0].quantity==1 and result.yang==3*ItemDefinitions.UPGRADE_ORE.vendor_price)
	var unsellable:=ItemInstance.create(ItemDefinitions.DEV_TRACE_SWORD,1,[])
	assert(VendorResolver.resolve([{"uid":unsellable.uid,"revision":0,"amount":1}],[unsellable.to_snapshot()],[],{}).error=="unsellable")
	var old_price:=ItemDefinitions.UPGRADE_ORE.vendor_price
	var definition: ItemDefinition=ItemDefinitions.UPGRADE_ORE
	definition.vendor_price=VendorResolver.MAX_YANG
	assert(VendorResolver.resolve([{"uid":ore.uid,"revision":0,"amount":3}],[ore.to_snapshot()],[],{}).error=="overflow")
	definition.vendor_price=old_price
	print("VENDOR_RECIPES_OK deterministic priority, repeat/mixed baskets, quantities, eligibility and overflow")
	get_tree().quit()
