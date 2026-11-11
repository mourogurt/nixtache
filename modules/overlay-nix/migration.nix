{ pkgs, ... }:

{
  rollbackActivationSnippet = ''
    migration_paths_match() {
      ${pkgs.diffutils}/bin/diff -r --no-dereference -- "$1" "$2" >/dev/null 2>&1
    }

    migration_dir_is_empty() {
      local path=$1 entry
      if ! entry=$(find "$path" -mindepth 1 -print -quit); then return 1; fi
      [ -z "$entry" ]
    }

    publish_migration_journal() {
      local journal=$1 temporary
      if [ -f "$journal" ]; then return 0; fi
      if ! temporary=$(mktemp "$journal.tmp.XXXXXX"); then
        echo "nixtache-overlay: failed to create migration journal for $journal" >&2
        return 1
      fi
      if ! printf 'backup=published-and-verified\n' > "$temporary"; then
        rm -f -- "$temporary"
        echo "nixtache-overlay: failed to write migration journal $journal" >&2
        return 1
      fi
      if ! mv -T -- "$temporary" "$journal"; then
        rm -f -- "$temporary"
        echo "nixtache-overlay: failed to publish migration journal $journal" >&2
        return 1
      fi
    }

    remove_migrated_source() {
      local link=$1
      if ! rm -rf -- "$link"; then
        echo "nixtache-overlay: failed to remove migrated legacy source $link" >&2
        return 1
      fi
      if [ -e "$link" ] || [ -L "$link" ]; then
        echo "nixtache-overlay: migrated legacy source still exists: $link" >&2
        return 1
      fi
    }

    rollback_activation() {
      local status=$? kind link data
      if [ "$activation_started" = 1 ] && [ "$activation_complete" = 0 ]; then
        while IFS='|' read -r kind link data; do
          if mountpoint -q "$link"; then umount "$link" || true; fi
          case "$kind" in
            M)
              if [ -e "$data" ] || [ -L "$data" ]; then
                if [ -e "$link" ] && [ ! -L "$link" ] && migration_paths_match "$link" "$data"; then
                  rm -rf -- "$data"
                  rm -f -- "$data.migration-ready"
                else
                  rm -rf "$link"
                  if mv "$data" "$link"; then rm -f -- "$data.migration-ready"; fi
                fi
              else
                echo "nixtache-overlay: recovery backup is missing, preserving $link" >&2
              fi
              ;;
            S) rm -rf "$link"; ln -s "$data" "$link" || true ;;
            N) rm -rf "$link" ;;
            # Bind-only activation preserves the underlying store; rollback
            # needs only the unmount performed before this case is dispatched.
            U) ;;
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
      local journal source_device backup_device staging temporary
      journal="$backup.migration-ready"
      mkdir -p "$(dirname "$link")" "$(dirname "$backup")"
      if [ -L "$link" ]; then
        printf 'S|%s|%s\n' "$link" "$(readlink "$link")" >> "$activation_log"
        rm -f "$link"
      elif [ -e "$link" ]; then
        if [ -e "$backup" ] || [ -L "$backup" ]; then
          if [ -d "$link" ] && migration_dir_is_empty "$link"; then
            if ! rm -rf -- "$link"; then
              echo "nixtache-overlay: failed to clear an empty mountpoint at $link" >&2
              return 1
            fi
            printf 'N|%s|\n' "$link" >> "$activation_log"
          else
            if [ ! -f "$journal" ]; then
              if ! migration_paths_match "$link" "$backup"; then
                echo "nixtache-overlay: existing backup does not match legacy state: $backup" >&2
                return 1
              fi
              if ! publish_migration_journal "$journal"; then return 1; fi
            fi
            if ! printf 'M|%s|%s\n' "$link" "$backup" >> "$activation_log"; then
              echo "nixtache-overlay: failed to journal verified legacy backup $backup" >&2
              return 1
            fi
            if ! remove_migrated_source "$link"; then return 1; fi
          fi
        else
          if ! source_device=$(stat -c %d -- "$link"); then
            echo "nixtache-overlay: failed to inspect legacy source filesystem: $link" >&2
            return 1
          fi
          if ! backup_device=$(stat -c %d -- "$(dirname "$backup")"); then
            echo "nixtache-overlay: failed to inspect legacy backup filesystem: $backup" >&2
            return 1
          fi
          if [ "$source_device" = "$backup_device" ]; then
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
            if ! staging=$(mktemp -d "$backup.tmp.XXXXXX"); then
              echo "nixtache-overlay: failed to create temporary backup beside $backup" >&2
              return 1
            fi
            temporary="$staging/content"
            if ! cp -a -- "$link" "$temporary"; then
              rm -rf -- "$staging"
              echo "nixtache-overlay: failed to copy legacy state to a temporary backup for $backup" >&2
              return 1
            fi
            if ! migration_paths_match "$link" "$temporary"; then
              rm -rf -- "$staging"
              echo "nixtache-overlay: temporary backup failed integrity verification: $temporary" >&2
              return 1
            fi
            if ! mv -T -- "$temporary" "$backup"; then
              rm -rf -- "$staging"
              echo "nixtache-overlay: failed to publish verified legacy backup $backup" >&2
              return 1
            fi
            if ! publish_migration_journal "$journal"; then
              rmdir -- "$staging"
              return 1
            fi
            rmdir -- "$staging"
            if ! printf 'M|%s|%s\n' "$link" "$backup" >> "$activation_log"; then
              echo "nixtache-overlay: failed to journal published legacy backup $backup" >&2
              return 1
            fi
            if ! remove_migrated_source "$link"; then return 1; fi
          fi
        fi
      elif [ -e "$backup" ] || [ -L "$backup" ]; then
        if ! printf 'M|%s|%s\n' "$link" "$backup" >> "$activation_log"; then
          echo "nixtache-overlay: failed to recover published legacy backup $backup" >&2
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
      activate_path "$source" "$link" "$backup"
      rm -f "$link"
      mkdir -p "$link"
      mount --bind "$source" "$link"
    }
  '';

  activatePersistentStateDirSnippet = ''
    activate_persistent_state_dir() {
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
      elif [ -L "$link" ]; then
        activate_state_dir "$source" "$link" "$backup"
        return 0
      else
        # Runner state can coexist with an additive clone at the same path.
        # Cover it with a bind instead of moving the only clone DB to a backup.
        printf 'U|%s|\n' "$link" >> "$activation_log"
      fi
      mkdir -p "$link"
      mount --bind "$source" "$link"
    }
  '';
}
