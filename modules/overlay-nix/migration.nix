{ ... }:

{
  rollbackActivationSnippet = ''
    rollback_activation() {
      local status=$? kind link data
      if [ "$activation_started" = 1 ] && [ "$activation_complete" = 0 ]; then
        while IFS='|' read -r kind link data; do
          if mountpoint -q "$link"; then umount "$link" || true; fi
          case "$kind" in
            M) rm -rf "$link"; mv "$data" "$link" || true ;;
            S) rm -rf "$link"; ln -s "$data" "$link" || true ;;
            N) rm -rf "$link" ;;
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
        printf 'M|%s|%s\n' "$link" "$backup" >> "$activation_log"
        mv "$link" "$backup"
      else
        printf 'N|%s|\n' "$link" >> "$activation_log"
      fi
      ln -s "$source" "$link"
    }
  '';

  activateStateDirSnippet = ''
    activate_state_dir() {
      local source=$1 link=$2 backup=$3
      if mountpoint -q "$link"; then umount "$link"; fi
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
