# shellcheck shell=sh disable=SC2154,SC2016
sources_lock=$script_dir/../sources.lock.json
lock_names() {
    jaq -r '.inputs[].name' "$sources_lock"
}
lock_field() {
    jaq -r --arg name "$1" --arg field "$2" '.inputs[] | select(.name == $name) | .[$field] // empty' "$sources_lock"
}
