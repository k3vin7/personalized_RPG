p='maps/zone_5.tscn'
s=open(p,encoding='utf-8',newline='').read()
nl='\r\n' if '\r\n' in s.split('\n',1)[0]+'\n' else '\n'
reps=[('[gd_scene format=3]'+nl,'[gd_scene format=3 uid="uid://dwfx4x32t4g6k"]'+nl),
('[ext_resource type="Script" path="res://scripts/world/building.gd" id="building_script"]','[ext_resource type="Script" uid="uid://b3pn5uy7q5qb8" path="res://scripts/world/building.gd" id="building_script"]'),
('[ext_resource type="Script" path="res://scripts/world/building_interior.gd" id="interior_script"]','[ext_resource type="Script" uid="uid://dmp15amwblyu4" path="res://scripts/world/building_interior.gd" id="interior_script"]'),
('[ext_resource type="Script" path="res://scripts/world/building_stair.gd" id="stair_script"]','[ext_resource type="Script" uid="uid://b8b6rc6gnst5r" path="res://scripts/world/building_stair.gd" id="stair_script"]')]
for a,b in reps:
    assert s.count(a)==1,(a,s.count(a)); s=s.replace(a,b,1)
open(p,'w',encoding='utf-8',newline='').write(s)
print("header ok")
