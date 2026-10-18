class_name ClientWorldInstance3D
extends Node
## Minimal 3D instance host. The world owns gameplay, input and join RPCs.
## Keep this node between InstanceManagerClient and GameWorld for stable paths.

var identity: Dictionary = {}
