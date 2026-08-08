#!/bin/bash
# Manage securetty MCP skills: search, list, install, remove, update.
# Reads skills from two locations:
#   Built-in:       ~/src/agent-mcp-skills/<name>/SKILL.md
#   User-installed: ~/.securetty/skills/<name>/SKILL.md
#
# Usage: securetty-skill-manager.sh <command> [args]
#   skill list                  List all installed skills
#   skill search <query>        Search skills by name or tag
#   skill info <name>           Show full SKILL.md for a skill
#   skill install <git-url>     Clone a skill repo into user skills
#   skill remove <name>         Remove a user-installed skill
#   skill update                Git pull all user-installed skills
set -euo pipefail

BUILTIN_DIR="$HOME/src/agent-mcp-skills"
USER_DIR="$HOME/.securetty/skills"

# =============================================================================
# Helpers
# =============================================================================

_ensure_user_dir() {
    mkdir -p "$USER_DIR"
}

_find_skill_dirs() {
    # Emit lines: <source>\t<dir>
    # Source is "builtin" or "user".
    if [[ -d "$BUILTIN_DIR" ]]; then
        for d in "$BUILTIN_DIR"/*/; do
            [[ -f "${d}SKILL.md" ]] && printf 'builtin\t%s\n' "$d"
        done
    fi
    if [[ -d "$USER_DIR" ]]; then
        for d in "$USER_DIR"/*/; do
            [[ -f "${d}SKILL.md" ]] && printf 'user\t%s\n' "$d"
        done
    fi
}

_parse_frontmatter() {
    # Read YAML frontmatter from a SKILL.md file.
    # Outputs key=value pairs for: name, version, description, tags.
    local file="$1"
    local in_frontmatter=0
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if [[ $in_frontmatter -eq 1 ]]; then
                break
            fi
            in_frontmatter=1
            continue
        fi
        if [[ $in_frontmatter -eq 1 ]]; then
            local key val
            case "$line" in
                name:*)
                    val="${line#name:}"
                    val="${val#"${val%%[![:space:]]*}"}"
                    echo "name=$val"
                    ;;
                version:*)
                    val="${line#version:}"
                    val="${val#"${val%%[![:space:]]*}"}"
                    val="${val//\"/}"
                    echo "version=$val"
                    ;;
                description:*)
                    val="${line#description:}"
                    val="${val#"${val%%[![:space:]]*}"}"
                    echo "description=$val"
                    ;;
                tags:*)
                    val="${line#tags:}"
                    val="${val#"${val%%[![:space:]]*}"}"
                    # Strip YAML list brackets and quotes
                    val="${val//[\[\]]/}"
                    val="${val//\"/}"
                    echo "tags=$val"
                    ;;
            esac
        fi
    done < "$file"
}

_get_field() {
    # Extract a single frontmatter field value from a SKILL.md.
    local file="$1" field="$2"
    _parse_frontmatter "$file" | grep "^${field}=" | head -1 | cut -d= -f2-
}

_skill_name_from_dir() {
    local dir="$1"
    # Strip trailing slash, take basename
    basename "${dir%/}"
}

_format_row() {
    printf '  %-20s %-10s %-10s %s\n' "$@"
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
    local found=0
    _format_row "NAME" "VERSION" "SOURCE" "DESCRIPTION"
    _format_row "----" "-------" "------" "-----------"
    while IFS=$'\t' read -r source dir; do
        local skill_file="${dir}SKILL.md"
        local name version description
        name=$(_get_field "$skill_file" "name")
        version=$(_get_field "$skill_file" "version")
        description=$(_get_field "$skill_file" "description")
        # Fall back to directory name if frontmatter name is empty
        [[ -z "$name" ]] && name=$(_skill_name_from_dir "$dir")
        [[ -z "$version" ]] && version="-"
        [[ -z "$description" ]] && description="(no description)"
        _format_row "$name" "$version" "$source" "$description"
        found=1
    done < <(_find_skill_dirs)
    if [[ $found -eq 0 ]]; then
        echo "No skills found." >&2
        echo "Built-in path:  $BUILTIN_DIR" >&2
        echo "User path:      $USER_DIR" >&2
        exit 1
    fi
}

cmd_search() {
    local query="$1"
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    local found=0
    local results=""

    while IFS=$'\t' read -r source dir; do
        local skill_file="${dir}SKILL.md"
        local name version description tags
        name=$(_get_field "$skill_file" "name")
        version=$(_get_field "$skill_file" "version")
        description=$(_get_field "$skill_file" "description")
        tags=$(_get_field "$skill_file" "tags")
        [[ -z "$name" ]] && name=$(_skill_name_from_dir "$dir")
        [[ -z "$version" ]] && version="-"
        [[ -z "$description" ]] && description="(no description)"

        # Case-insensitive match against name, tags, and description
        local searchable
        searchable=$(echo "${name} ${tags} ${description}" | tr '[:upper:]' '[:lower:]')
        if [[ "$searchable" == *"$query_lower"* ]]; then
            results+="$(printf '  %-20s %-10s %-10s %s\n' "$name" "$version" "$source" "$description")"$'\n'
            found=1
        fi
    done < <(_find_skill_dirs)

    if [[ $found -eq 0 ]]; then
        echo "No skills matching '$query'." >&2
        exit 1
    fi

    _format_row "NAME" "VERSION" "SOURCE" "DESCRIPTION"
    _format_row "----" "-------" "------" "-----------"
    printf '%s' "$results"
}

cmd_info() {
    local target="$1"
    local target_lower
    target_lower=$(echo "$target" | tr '[:upper:]' '[:lower:]')

    while IFS=$'\t' read -r source dir; do
        local skill_file="${dir}SKILL.md"
        local name dir_name
        name=$(_get_field "$skill_file" "name")
        dir_name=$(_skill_name_from_dir "$dir")
        local name_lower dir_lower
        name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

        if [[ "$name_lower" == "$target_lower" || "$dir_lower" == "$target_lower" ]]; then
            echo "Source: $source"
            echo "Path:   ${dir}SKILL.md"
            echo ""
            cat "$skill_file"
            return 0
        fi
    done < <(_find_skill_dirs)

    echo "Skill '$target' not found." >&2
    echo "Run 'securetty-skill-manager.sh list' to see available skills." >&2
    exit 1
}

cmd_install() {
    local git_url="$1"
    _ensure_user_dir

    # Derive skill name from the git URL (last path component, minus .git)
    local repo_name
    repo_name=$(basename "$git_url" .git)

    if [[ -z "$repo_name" ]]; then
        echo "Cannot determine skill name from URL: $git_url" >&2
        exit 1
    fi

    local target_dir="$USER_DIR/$repo_name"

    if [[ -d "$target_dir" ]]; then
        echo "Skill '$repo_name' is already installed at $target_dir" >&2
        echo "Use 'securetty-skill-manager.sh update' to pull latest changes." >&2
        exit 1
    fi

    echo "Installing skill '$repo_name' from $git_url ..."
    git clone --depth 1 "$git_url" "$target_dir"

    if [[ ! -f "$target_dir/SKILL.md" ]]; then
        echo "Warning: cloned repo does not contain a SKILL.md file." >&2
        echo "The skill may not be recognized until SKILL.md is added." >&2
    fi

    echo "Installed to $target_dir"

    # Show skill info if SKILL.md exists
    if [[ -f "$target_dir/SKILL.md" ]]; then
        echo ""
        local name version description
        name=$(_get_field "$target_dir/SKILL.md" "name")
        version=$(_get_field "$target_dir/SKILL.md" "version")
        description=$(_get_field "$target_dir/SKILL.md" "description")
        [[ -z "$name" ]] && name="$repo_name"
        echo "  Name:        $name"
        echo "  Version:     ${version:--}"
        echo "  Description: ${description:-(no description)}"
    fi
}

cmd_remove() {
    local target="$1"
    local target_lower
    target_lower=$(echo "$target" | tr '[:upper:]' '[:lower:]')

    # Check user-installed skills first
    for d in "$USER_DIR"/*/; do
        [[ ! -d "$d" ]] && continue
        local dir_name
        dir_name=$(_skill_name_from_dir "$d")
        local dir_lower
        dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

        # Also check frontmatter name
        local fm_name=""
        if [[ -f "${d}SKILL.md" ]]; then
            fm_name=$(_get_field "${d}SKILL.md" "name")
        fi
        local fm_lower
        fm_lower=$(echo "$fm_name" | tr '[:upper:]' '[:lower:]')

        if [[ "$dir_lower" == "$target_lower" || "$fm_lower" == "$target_lower" ]]; then
            echo "Removing skill '$dir_name' from $d ..."
            rm -rf "$d"
            echo "Removed."
            return 0
        fi
    done

    # Check if it exists as a built-in
    while IFS=$'\t' read -r source dir; do
        if [[ "$source" == "builtin" ]]; then
            local name dir_name
            name=$(_get_field "${dir}SKILL.md" "name")
            dir_name=$(_skill_name_from_dir "$dir")
            local name_lower dir_lower
            name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
            dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')
            if [[ "$name_lower" == "$target_lower" || "$dir_lower" == "$target_lower" ]]; then
                echo "Cannot remove built-in skill '$target'." >&2
                echo "Built-in skills are managed at $BUILTIN_DIR" >&2
                exit 1
            fi
        fi
    done < <(_find_skill_dirs)

    echo "Skill '$target' not found in user-installed skills." >&2
    exit 1
}

cmd_update() {
    _ensure_user_dir

    local updated=0
    local failed=0

    for d in "$USER_DIR"/*/; do
        [[ ! -d "$d" ]] && continue
        local dir_name
        dir_name=$(_skill_name_from_dir "$d")

        if [[ ! -d "${d}.git" ]]; then
            echo "  skip: $dir_name (not a git repository)"
            continue
        fi

        echo "  updating: $dir_name ..."
        if git -C "$d" pull --ff-only 2>&1 | sed 's/^/    /'; then
            updated=$((updated + 1))
        else
            echo "    failed to update $dir_name" >&2
            failed=$((failed + 1))
        fi
    done

    if [[ $updated -eq 0 && $failed -eq 0 ]]; then
        echo "No user-installed skills to update."
        echo "Install skills with: securetty-skill-manager.sh install <git-url>"
        return 0
    fi

    echo ""
    echo "Updated: $updated, Failed: $failed"
}

# =============================================================================
# Main
# =============================================================================

usage() {
    echo "securetty-skill-manager -- manage MCP skills"
    echo ""
    echo "Usage: securetty-skill-manager.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  list                  List all installed skills"
    echo "  search <query>        Search skills by name, tag, or description"
    echo "  info <name>           Show full SKILL.md content for a skill"
    echo "  install <git-url>     Clone a skill repo into user skills"
    echo "  remove <name>         Remove a user-installed skill"
    echo "  update                Git pull all user-installed skills"
    echo ""
    echo "Skill locations:"
    echo "  Built-in:  $BUILTIN_DIR"
    echo "  User:      $USER_DIR"
    exit 0
}

if [[ $# -lt 1 ]]; then
    usage
fi

command="$1"
shift

case "$command" in
    list)
        cmd_list
        ;;
    search)
        if [[ $# -lt 1 ]]; then
            echo "Usage: securetty-skill-manager.sh search <query>" >&2
            exit 1
        fi
        cmd_search "$1"
        ;;
    info)
        if [[ $# -lt 1 ]]; then
            echo "Usage: securetty-skill-manager.sh info <name>" >&2
            exit 1
        fi
        cmd_info "$1"
        ;;
    install)
        if [[ $# -lt 1 ]]; then
            echo "Usage: securetty-skill-manager.sh install <git-url>" >&2
            exit 1
        fi
        cmd_install "$1"
        ;;
    remove)
        if [[ $# -lt 1 ]]; then
            echo "Usage: securetty-skill-manager.sh remove <name>" >&2
            exit 1
        fi
        cmd_remove "$1"
        ;;
    update)
        cmd_update
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        echo "Unknown command: $command" >&2
        echo "Run 'securetty-skill-manager.sh --help' for usage." >&2
        exit 1
        ;;
esac
