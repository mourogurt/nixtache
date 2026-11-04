{ ... }:

{
  rollbackActivationSnippet = ''
    rollback_activation() {
      local status=$? kind link data
      if [ "$activation_started" = 1 ] && [ "$activation_complete" = 0 ]; then
        while IFS='|' read -r kind link data; do
          if mountpoint -q "$link"; then umount "$link" || true; fi
          case "$kind" in
            M)
              if [ -e "$data" ] || [ -L "$data" ]; then
                rm -rf "$link"
                mv "$data" "$link" || true
              else
                echo "nixtache-overlay: recovery backup is missing, preserving $link" >&2
              fi
              ;;
            S) rm -rf "$link"; ln -s "$data" "$link" || true ;;
            N) rm -rf "$link" ;;
            B)
              if [ -d "$data" ]; then
                mkdir -p "$link"
                mount --bind "$data" "$link" || true
              else
                echo "nixtache-overlay: previous mount source is missing, preserving $link" >&2
              fi
              ;;
          esac
        done < <(tac "$activation_log")
      fi
      exit "$status"
    }
  '';

  resetDirSnippet = ''
    reset_dir() {
      local path=$1
      if [ -L "$path" ]; then rm -f "$path"; fi
      mkdir -p "$path"
      find "$path" -mindepth 1 -delete
    }
  '';

  activatePathSnippet = ''
    activate_path() {
      local source=$1 link=$2 backup=$3
      mkdir -p "$(dirname "$link")" "$(dirname "$backup")"
      if [ -L "$link" ]; then
        printf 'S|%s|%s\n' "$link" "$(readlink "$link")" >> "$activation_log"
        rm -f "$link"
      elif [ -e "$link" ]; then
        if [ -e "$backup" ]; then
          echo "nixtache-overlay: legacy backup already exists: $backup" >&2
          return 1
        fi
        if ! mv "$link" "$backup"; then
          echo "nixtache-overlay: failed to move legacy state to $backup" >&2
          return 1
        fi
        if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
          echo "nixtache-overlay: recovery backup is unusable: $backup" >&2
          return 1
        fi
        if ! printf 'M|%s|%s\n' "$link" "$backup" >> "$activation_log"; then
          mv "$backup" "$link" || true
          return 1
        fi
      else
        printf 'N|%s|\n' "$link" >> "$activation_log"
      fi
      ln -s "$source" "$link"
    }
  '';

  activateStateDirSnippet = ''
    activate_state_dir() {
      local source=$1 link=$2 backup=$3 previous_source=""
      if mountpoint -q "$link"; then
        previous_source=$(findmnt -n -o FSROOT --target "$link" | head -n 1)
        if [ -z "$previous_source" ] || [ "$previous_source" = / ]; then
          previous_source=$(findmnt -n -o SOURCE --target "$link" | head -n 1)
        fi
        if [ -n "$previous_source" ]; then
          printf 'B|%s|%s\n' "$link" "$previous_source" >> "$activation_log"
        fi
        umount "$link"
      fi
      if [ -d "$link" ] && [ ! -L "$link" ] && [ -e "$backup" ]; then
        rm -rf "$link"
      fi
      activate_path "$source" "$link" "$backup"
      rm -f "$link"
      mkdir -p "$link"
      mount --bind "$source" "$link"
    }
  '';
}
