# Dot-sourced by the tool wrappers. Resolution order: $env:GODOT_BIN, then godot / godot4 on PATH.
# Returns $null when nothing is found; each caller emits its own machine-readable failure line.
function Resolve-GodotBin {
    if ($env:GODOT_BIN) {
        if (Test-Path $env:GODOT_BIN) { return $env:GODOT_BIN }
        return $null
    }
    foreach ($name in @("godot", "godot4")) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}
