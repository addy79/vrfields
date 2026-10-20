# Addon patches

Local fixes to third-party addons that must be reapplied whenever an addon is
updated or reinstalled. The addons in `addons/` already have these applied.

## xr-tools-4.5.1-godot-4.7.patch

**Addon:** Godot XR Tools 4.5.1 (`addons/godot-xr-tools`)
**Engine:** Godot 4.7

Godot 4.7 rejects functions that don't return a value on every code path.
Two XR Tools scripts have a `_property_get_revert()` without a final return,
which shows up in the editor's Output panel as:

```
SCRIPT ERROR: Parse Error: Not all code paths return a value.
   at: res://addons/godot-xr-tools/functions/function_teleport.gd
   at: res://addons/godot-xr-tools/objects/viewport_2d_in_3d.gd
```

The patch adds `return null` at the end of both functions. Behaviour is
unchanged: GDScript already returned `null` in those paths.

### Reapplying after an addon update

Run from the project root (`~/VR APPs/VRFields`):

```bash
# 1. Check whether it is still needed / still applies
git apply --check patches/xr-tools-4.5.1-godot-4.7.patch

# 2. Apply it
git apply patches/xr-tools-4.5.1-godot-4.7.patch
#    (or, without git:  patch -p1 < patches/xr-tools-4.5.1-godot-4.7.patch)

# 3. Confirm it is applied
git apply --reverse --check patches/xr-tools-4.5.1-godot-4.7.patch && echo applied
```

Then reopen the editor and check the Output panel is clean.

- If step 1 fails and step 3 succeeds, the patch is already applied.
- If both fail, the new addon version changed these files. Open them and check
  whether `_property_get_revert()` still lacks a final return. If upstream fixed
  it, delete this patch and this section of the README.

## Related project setting (not a patch)

XR Tools' `start_xr.gd` reads `xr/openxr/extensions/hand_tracking`, which
Godot 4.7 no longer defines. `project.godot` sets it
(`openxr/extensions/hand_tracking=true` under `[xr]`) to silence the
"Property not found" warning. Keep that line when updating XR Tools.
