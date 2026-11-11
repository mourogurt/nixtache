{ lib
, pkgs
, cfg
, imageId
, runtimeState
, slotsDir
, legacyBackup
, stateNames
, discoverySnippet
, metadataValueSnippet
, readyGenerationSnippet
, ...
}:

with lib;

let
  topology = cfg._topology;
  runnerLayers = filter (node: node ? containerName) topology.nodes;
  runnerContainerUnits = map (node: "container@${node.containerName}.service") runnerLayers;
  runnerContainer = concatStringsSep " " runnerContainerUnits;

  plannerSource = pkgs.writeText "nixtache-overlay-planner.py" (builtins.readFile ./planner.py);
  planner = pkgs.writeShellScript "nixtache-overlay-planner" ''
    exec ${pkgs.python3}/bin/python3 ${plannerSource} "$@"
  '';
  descriptorValidator = pkgs.writeShellScript "nixtache-overlay-validate-descriptor" ''
    exec ${planner} validate --image-id ${escapeShellArg imageId} "$@"
  '';
  ephemeralSourceDescriptor = pkgs.writeText "nixtache-overlay-ephemeral-source.json" (builtins.toJSON {
    schema = "nixtache.overlay-topology/v1";
    imageId = imageId;
    imageVersion = "ephemeral";
    lowerDbSha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    logicalTopology = topology.descriptor // {
      nodes = map (node: node // { ephemeral = true; }) topology.descriptor.nodes;
    };
  });

  materializeScript = pkgs.writeShellScript "nixtache-overlay-materialize" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils nix util-linux ])}
    if [ "$#" -ne 5 ]; then
      echo "usage: nixtache-overlay-materialize <rows> <source> <stage> <policy> <initial>" >&2
      exit 2
    fi
    rows=$1
    source_dir=$2
    stage=$3
    policy=$4
    initial=$5
    merge_scratch=$(mktemp -d "''${TMPDIR:-/tmp}/nixtache-overlay-materialize.XXXXXX")
    trap 'rm -rf "$merge_scratch"' EXIT
    mkdir -p "$stage/nodes" "$stage/layers" "$stage/host/lower-state" "$merge_scratch/root/nix/store"
    : > "$stage/persistent-plan.rows"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      IFS='|' read -r physical_id logical_id role parent operation disposition source_consumer source_frozen upper_dir state_dir singleton target_ephemeral <<< "$row"
      if [ "$target_ephemeral" != 1 ]; then
        printf '%s\n' "$row" >> "$stage/persistent-plan.rows"
      fi
    done < "$rows"

    copy_state() {
      local source=$1 destination=$2 name
      mkdir -p "$destination"
      for name in ${concatStringsSep " " stateNames}; do
        if [ -e "$source/$name" ] || [ -L "$source/$name" ]; then
          cp -a --reflink=auto "$source/$name" "$destination/$name"
        else
          mkdir -p "$destination/$name"
        fi
      done
    }

    copy_layer() {
      local source=$1 destination=$2
      mkdir -p "$destination/upper" "$destination/work" "$destination/state"
      if [ -d "$source/upper" ]; then
        cp -a --reflink=auto "$source/upper/." "$destination/upper/"
      elif [ -d "$source" ]; then
        cp -a --reflink=auto "$source/." "$destination/upper/"
      else
        echo "nixtache-overlay: source upper is missing: $source" >&2
        return 1
      fi
    }

    merge_state() {
      local source=$1 destination=$2 name
      mkdir -p "$destination"
      if [ -f "$source/db/db.sqlite" ]; then
        mkdir -p "$destination/db"
        nix-store --option experimental-features "read-only-local-store" \
          --store "local?root=$merge_scratch/root&state=$source&read-only=true" --dump-db |
          nix-store --option experimental-features "ca-derivations" \
            --store "local?root=$merge_scratch/root&state=$destination" --load-db
      fi
      for name in gcroots profiles temproots; do
        mkdir -p "$destination/$name"
        if [ -d "$source/$name" ]; then
          cp -a --reflink=auto "$source/$name/." "$destination/$name/"
        fi
      done
    }

    copy_whole() {
      local source=$1 destination=$2
      copy_layer "$source" "$destination"
      copy_state "$source/state" "$destination/state"
    }

    merge_whole() {
      local source=$1 destination=$2
      copy_layer "$source" "$destination"
      merge_state "$source/state" "$destination/state"
    }

    find_source() {
      local physical_id=$1 logical_id=$2 singleton=$3 candidate
      for candidate in "$source_dir/nodes/$physical_id" "$source_dir/layers/$logical_id"; do
        if [ -d "$candidate" ]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
      if [ "$logical_id" = host ] && [ -d "$source_dir/host" ]; then
        printf '%s\n' "$source_dir/host"
        return 0
      fi
      if [ "$singleton" = 1 ] && [ -d "$source_dir/runner" ]; then
        printf '%s\n' "$source_dir/runner"
        return 0
      fi
      echo "nixtache-overlay: source physical node $physical_id for $logical_id is missing" >&2
      return 1
    }

    copy_legacy() {
      local upper=$1 state=$2 destination=$3
      copy_layer "$upper" "$destination"
      copy_state "$state" "$destination/state"
    }

    while IFS='|' read -r physical_id logical_id role parent operation disposition source_consumer source_frozen upper_dir state_dir singleton target_ephemeral; do
      [ -n "$physical_id" ] || continue
      if [ "$logical_id" = host ] && [ "$role" = runtime ]; then
        destination="$stage/host"
      else
        destination="$stage/nodes/$physical_id"
      fi
      mkdir -p "$destination/upper" "$destination/work" "$destination/state"
      if [ "$initial" = 1 ]; then
        if [ "$role" = frozen-lower ]; then
          copy_legacy "$upper_dir" "$state_dir" "$destination"
        elif [ "$disposition" != empty-continuation ]; then
          copy_legacy "$upper_dir" "$state_dir" "$destination"
        fi
      elif [ "$policy" = reconcile ] && [ "$operation" != add ] && [ "$operation" != storage-reset ]; then
        if [ "$role" = frozen-lower ]; then
          if [ "$source_frozen" != - ]; then
            source_path=$(find_source "$source_frozen" "$logical_id" 0)
            copy_whole "$source_path" "$destination"
            source_path=$(find_source "$source_consumer" "$logical_id" "$singleton")
            merge_whole "$source_path" "$destination"
          else
            source_path=$(find_source "$source_consumer" "$logical_id" "$singleton")
            copy_whole "$source_path" "$destination"
          fi
        elif [ "$disposition" = clone-and-repair ]; then
          source_path=$(find_source "$source_consumer" "$logical_id" "$singleton")
          copy_whole "$source_path" "$destination"
        fi
      fi
    done < "$stage/persistent-plan.rows"

    while IFS='|' read -r physical_id logical_id role rest; do
      [ -n "$physical_id" ] || continue
      [ "$role" = runtime ] || continue
      if [ "$logical_id" = host ]; then
        ln -s ../host "$stage/nodes/$physical_id"
      else
        ln -s "../nodes/$physical_id" "$stage/layers/$logical_id"
      fi
    done < "$stage/persistent-plan.rows"
  '';

  encodeStoreUri = ''
    uri_encode() {
      local value=$1
      value=''${value//%/%25}
      value=''${value//\?/%3F}
      value=''${value//&/%26}
      value=''${value//\=/%3D}
      printf '%s' "$value"
    }
  '';

  prepareScript = pkgs.writeShellScript "nixtache-overlay-prepare" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux nix sqlite systemd ])}

    mode=''${1:---installed}
    descriptor_validator=${descriptorValidator}
    planner=${planner}
    materializer=${materializeScript}
    mkdir -p ${runtimeState}
    if [ "$(findmnt -T ${cfg.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)" != tmpfs ]; then
      mkdir -p ${slotsDir}
    fi

    ${discoverySnippet}

    ${metadataValueSnippet}

    ${readyGenerationSnippet}

    stopped_units=""
    probe=""
    resume_writers() {
      local unit failed=0
      if [ -n "$stopped_units" ]; then
        for unit in $stopped_units; do
          if ! systemctl start "$unit"; then failed=1; fi
        done
        if [ "$failed" = 0 ]; then stopped_units=""; fi
      fi
      return "$failed"
    }
    rollback_stage() {
      local status=$?
      trap - EXIT TERM INT HUP
      resume_writers || true
      if [ -n "$probe" ] && [ -d "$probe" ]; then
        rm -rf "$probe" || true
      fi
      if [ "''${stage:-}" != "" ] && [ -d "$stage" ]; then
        mkdir -p "$slot_dir/generations/$generation"
        cp -a "$stage/." "$slot_dir/generations/$generation/" && rm -rf "$stage" || true
      fi
      exit "$status"
    }
    trap rollback_stage EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP

    ${encodeStoreUri}

    prepare_chain() {
      local target_slot=$1 target_version=$2 target_device=$3 source_slot=$4 source_generation=$5 initial=$6
      local target_dump target_descriptor lower_sha descriptor_sha scratch lower_root lower_store source_dir current_before source_ephemeral
      slot_dir="${slotsDir}/$target_slot"
      generation="$(date +%Y%m%d%H%M%S)-$$"
      stage="$slot_dir/.staging-$generation"
      probe=""
      source_ephemeral=0
      if [ "$source_generation" = ephemeral ]; then source_ephemeral=1; fi
      target_dump="/boot/EFI/nixtache/${imageId}_$target_version.lower-db"
      [ -f "$target_dump" ] || { echo "nixtache-overlay: target lower dump is missing: $target_dump" >&2; return 1; }
      [ "$target_slot" != "$source_slot" ] || [ "$initial" = 1 ] || [ "$source_ephemeral" = 1 ] || { echo "nixtache-overlay: active and target slots must differ" >&2; return 1; }
      lower_sha=$(sha256sum "$target_dump" | awk '{print $1}')
      target_descriptor="/boot/EFI/nixtache/${imageId}_$target_version.overlay-topology.json"
      "$descriptor_validator" "$target_descriptor" "$target_version" "$lower_sha"
      descriptor_sha=$(sha256sum "$target_descriptor" | awk '{print $1}')
      probe=$(mktemp -d "${runtimeState}/target-plan.XXXXXX")
      "$planner" plan \
        --target-descriptor "$target_descriptor" \
        --image-id ${imageId} \
        --image-version "$target_version" \
        --lower-sha256 "$lower_sha" \
        --policy ${cfg.upperOnUpdate} \
        --initial \
        --output-json "$probe/plan.json" \
        --output-rows "$probe/plan.rows" \
        --output-metadata "$probe/plan.metadata"
      if ! grep -q '|0$' "$probe/plan.rows"; then
        rm -rf "$probe"
        probe=""
        printf '%s\n' "$target_slot" > "${runtimeState}/prepared-slot"
        printf 'ephemeral\n' > "${runtimeState}/prepared-generation"
        printf '%s\n' "$source_slot:$source_generation" > "${runtimeState}/prepared-source"
        trap - EXIT
        return 0
      fi
      rm -rf "$probe"
      probe=""
      mkdir -p "$slot_dir"
      exec {prepare_lock_fd}> "$slot_dir/.prepare.lock"
      flock -x "$prepare_lock_fd"
      current_before=$(readlink -f "$slot_dir/current" 2>/dev/null || true)
      if [ "$source_ephemeral" = 0 ] && [ -n "$current_before" ] && [ -f "$current_before/plan.json" ] \
        && [ -f "$current_before/lower-db" ] && [ -f "$current_before/overlay-topology.json" ] \
        && [ "$(metadata_value "$current_before/metadata" state)" = ready ] \
        && [ "$(metadata_value "$current_before/metadata" slot)" = "$target_slot" ] \
        && [ "$(metadata_value "$current_before/metadata" image_id)" = ${imageId} ] \
        && [ "$(metadata_value "$current_before/metadata" image_version)" = "$target_version" ] \
        && [ "$(metadata_value "$current_before/metadata" lower_sha256)" = "$lower_sha" ] \
        && [ "$(metadata_value "$current_before/metadata" descriptor_sha256)" = "$descriptor_sha" ] \
        && [ "$lower_sha" = "$(sha256sum "$current_before/lower-db" | awk '{print $1}')" ] \
        && [ "$descriptor_sha" = "$(sha256sum "$current_before/overlay-topology.json" | awk '{print $1}')" ] \
        && { [ ! -f "${runtimeState}/prepared-generation" ] \
          || [ "$(cat "${runtimeState}/prepared-generation")" != "$(basename "$current_before")" ]; }; then
        printf '%s\n' "$target_slot" > "${runtimeState}/prepared-slot"
        printf '%s\n' "$(basename "$current_before")" > "${runtimeState}/prepared-generation"
        printf '%s\n' "$source_slot:$source_generation" > "${runtimeState}/prepared-source"
        trap - EXIT
        return 0
      fi
      mkdir -p "$slot_dir/generations"
      rm -rf "$slot_dir"/.staging-*
      while read -r old; do
        [ -n "$old" ] || continue
        if [ "$old" = "$current_before" ]; then continue; fi
        rm -rf "$old"
      done < <(find "$slot_dir/generations" -mindepth 1 -maxdepth 1 -type d)
      mkdir -p "$slot_dir/generations/$generation" "$stage"
      cp "$target_dump" "$stage/lower-db"
      cp "$target_descriptor" "$stage/overlay-topology.json"
      target_dump="$stage/lower-db"
      target_descriptor="$stage/overlay-topology.json"
      source_dir=""
      if [ "$initial" != 1 ] && [ "$source_ephemeral" != 1 ] && [ -n "$source_slot" ]; then
        source_dir=$(readlink -f "${slotsDir}/$source_slot/generations/$source_generation")
        [ "$(metadata_value "$source_dir/metadata" state)" = "ready" ] || { echo "nixtache-overlay: transition source is not ready" >&2; return 1; }
        [ -d "$source_dir/host" ] || { echo "nixtache-overlay: transition source has no host consumer" >&2; return 1; }
      fi
      if [ "${cfg.upperOnUpdate}" = reconcile ] && [ "$initial" != 1 ] && [ "$source_ephemeral" != 1 ]; then
        [ -n "$source_dir" ] || { echo "nixtache-overlay: reconcile source is unavailable" >&2; return 1; }
        if [ "$mode" = "--installed" ]; then
          for unit in ${runnerContainer} nix-daemon.service nix-daemon.socket; do
            if systemctl is-active --quiet "$unit"; then
              systemctl stop "$unit"
              stopped_units="$unit $stopped_units"
            fi
          done
        fi
      fi
      plan_args=(
        --target-descriptor "$target_descriptor"
        --image-id ${imageId}
        --image-version "$target_version"
        --lower-sha256 "$lower_sha"
        --policy ${cfg.upperOnUpdate}
        --output-json "$stage/plan.json"
        --output-rows "$stage/plan.rows"
        --output-metadata "$stage/plan.metadata"
      )
      if [ -n "$source_dir" ]; then
        plan_args+=(--source-root "$source_dir" --allow-legacy-source)
      elif [ "$source_ephemeral" = 1 ]; then
        plan_args+=(--source-descriptor ${ephemeralSourceDescriptor})
      else
        plan_args+=(--initial)
      fi
      "$planner" plan "''${plan_args[@]}"
      {
        printf 'slot=%s\n' "$target_slot"
        cat "$stage/plan.metadata"
        printf 'descriptor_sha256=%s\n' "$descriptor_sha"
        printf 'generation=%s\nstate=unready\n' "$generation"
      } > "$slot_dir/generations/$generation/metadata"
      cat >> "$slot_dir/generations/$generation/metadata" <<EOF
    source_slot=$source_slot
    source_generation=$source_generation
    EOF
      cp "$slot_dir/generations/$generation/metadata" "$stage/metadata"
      "$materializer" "$stage/plan.rows" "$source_dir" "$stage" ${cfg.upperOnUpdate} "$initial"
      resume_writers

      scratch=$(mktemp -d /run/nixtache-overlay/prepare.XXXXXX)
      lower_root="$scratch/lower"
      lower_store="$lower_root/nix/store"
      mkdir -p "$lower_store"
      export target_device scratch lower_root lower_store stage target_dump
      unshare -m --propagation private ${pkgs.writeShellScript "nixtache-overlay-verify-namespace" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux nix ])}
        ${encodeStoreUri}
        rows="$stage/persistent-plan.rows"
        if [ "$target_device" = "BOOTED" ]; then
          mount --bind ${topology.physicalHostRoot}/nix/store "$lower_store"
          mount -o remount,ro,bind "$lower_store"
        else
          mount -o ro "$target_device" "$lower_store"
        fi
        seed=$(mktemp -d /run/nixtache-overlay/seed.XXXXXX)
        mkdir -p "$seed/upper" "$seed/work"
        mount -t overlay overlay -o lowerdir="$lower_store",upperdir="$seed/upper",workdir="$seed/work" "$lower_store"
        nix-store --option experimental-features "ca-derivations" --store "local?root=$lower_root&state=$stage/host/lower-state" --load-db < "$target_dump"
        umount "$lower_store"
        lower_url=$(uri_encode "local?root=$lower_root&state=$stage/host/lower-state&read-only=true")

        physical_stage() {
          local physical_id=$1 logical_id=$2 role=$3
          if [ "$role" = runtime ]; then
            if [ "$logical_id" = host ]; then
              printf '%s\n' "$stage/host"
            else
              printf '%s\n' "$stage/layers/$logical_id"
            fi
          else
            printf '%s\n' "$stage/nodes/$physical_id"
          fi
        }
        physical_root() {
          printf '%s\n' "$scratch/nodes/$1"
        }
        physical_parent() {
          local wanted=$1 physical_id logical_id role parent rest
          while IFS='|' read -r physical_id logical_id role parent rest; do
            if [ "$physical_id" = "$wanted" ]; then
              printf '%s\n' "$parent"
              return 0
            fi
          done < "$rows"
          return 1
        }
        physical_role() {
          local wanted=$1 physical_id logical_id role rest
          while IFS='|' read -r physical_id logical_id role rest; do
            if [ "$physical_id" = "$wanted" ]; then
              printf '%s\n' "$role"
              return 0
            fi
          done < "$rows"
          return 1
        }
        physical_logical() {
          local wanted=$1 physical_id logical_id rest
          while IFS='|' read -r physical_id logical_id rest; do
            if [ "$physical_id" = "$wanted" ]; then
              printf '%s\n' "$logical_id"
              return 0
            fi
          done < "$rows"
          return 1
        }
        physical_is_parent() {
          local wanted=$1 physical_id logical_id role parent rest
          while IFS='|' read -r physical_id logical_id role parent rest; do
            if [ "$parent" = "$wanted" ]; then return 0; fi
          done < "$rows"
          return 1
        }
        physical_mount_dir() {
          printf '%s\n' "$scratch/mounted-uppers/$1"
        }
        store_url() {
          local own=$1 current=$2 parent logical role current_stage current_root mount_upper state lower
          parent=$(physical_parent "$current")
          logical=$(physical_logical "$current")
          role=$(physical_role "$current")
          current_stage=$(physical_stage "$current" "$logical" "$role")
          current_root=$(physical_root "$current")
          mount_upper="$(physical_mount_dir "$current")/upper"
          if [ "$own" = "$current" ]; then
            state="$current_stage/state"
          else
            state="$scratch/lower-states/$current"
          fi
          if [ "$parent" = - ]; then
            lower="$lower_url"
          else
            lower=$(uri_encode "$(store_url "$own" "$parent")")
          fi
          printf '%s\n' "local-overlay://?root=$current_root&state=$state&lower-store=$lower&upper-layer=$mount_upper&ignore-gc-delete-failure=true&check-mount=false"
        }
        physical_lower_layers() {
          local ancestor=$1 logical role ancestor_stage alias layers=""
          while [ "$ancestor" != - ]; do
            logical=$(physical_logical "$ancestor")
            role=$(physical_role "$ancestor")
            ancestor_stage=$(physical_stage "$ancestor" "$logical" "$role")
            alias="$scratch/l/$ancestor"
            mkdir -p "$alias"
            if ! mountpoint -q "$alias"; then
              mount --bind "$ancestor_stage/upper" "$alias"
            fi
            mount -o remount,ro,bind "$alias"
            layers="''${layers:+''${layers}:}$alias"
            ancestor=$(physical_parent "$ancestor")
          done
          printf '%s\n' "''${layers:+''${layers}:}$lower_store"
        }
        mount_physical() {
          local physical_id=$1 logical_id=$2 role=$3 parent=$4 node_stage node_root mount_dir lower_layers
          node_stage=$(physical_stage "$physical_id" "$logical_id" "$role")
          node_root=$(physical_root "$physical_id")
          mount_dir=$(physical_mount_dir "$physical_id")
          lower_layers=$(physical_lower_layers "$parent")
          mkdir -p "$node_root/nix/store" "$mount_dir/work"
          if [ ! -d "$mount_dir/upper" ]; then
            mkdir -p "$mount_dir/upper"
            cp -a "$node_stage/upper/." "$mount_dir/upper/"
          fi
          # Private mount uppers avoid upper/lower sharing; independent short
          # aliases avoid nested stacking and new-mount-API option length limits.
          mount -t overlay overlay -o lowerdir="$lower_layers",upperdir="$mount_dir/upper",workdir="$mount_dir/work" "$node_root/nix/store"
        }
        publish_mount_upper() {
          local physical_id=$1 logical_id=$2 role=$3 node_stage mount_dir
          node_stage=$(physical_stage "$physical_id" "$logical_id" "$role")
          mount_dir=$(physical_mount_dir "$physical_id")
          rm -rf "$node_stage/upper"
          mkdir -p "$node_stage/upper"
          cp -a "$mount_dir/upper/." "$node_stage/upper/"
        }
        unmount_all() {
          local physical_id rest node_root
          while IFS='|' read -r physical_id rest; do
            [ -n "$physical_id" ] || continue
            node_root=$(physical_root "$physical_id")
            if mountpoint -q "$node_root/nix/store"; then umount "$node_root/nix/store"; fi
          done < <(tac "$rows")
        }

        ${repairStoreSnippet}
        ${checkStoreSnippet}

        duplicate_visible_metadata() {
          local physical_id=$1 parent=$2 state=$3 merged=$4 parent_state
          if [ "$parent" = - ]; then
            parent_state="$stage/host/lower-state"
          else
            parent_state="$scratch/lower-states/$parent"
          fi
          mkdir -p "$scratch/dump-root/nix/store"
          # Parent-first preparation duplicates the parent's complete visible
          # records into each child upper DB; a local-overlay dump alone would
          # contain only the child's own upper records.
          nix-store --option experimental-features "ca-derivations read-only-local-store" \
            --store "local?root=$scratch/dump-root&state=$parent_state&read-only=true" --dump-db |
            nix-store --option experimental-features "ca-derivations" \
              --store "local?root=$merged&state=$state" --load-db
        }

        while IFS='|' read -r physical_id logical_id role parent operation disposition rest; do
          [ -n "$physical_id" ] || continue
          mount_physical "$physical_id" "$logical_id" "$role" "$parent"
          node_stage=$(physical_stage "$physical_id" "$logical_id" "$role")
          node_root=$(physical_root "$physical_id")
          node_url=$(store_url "$physical_id" "$physical_id")
          echo "nixtache-overlay: repairing $physical_id"
          if [ "$logical_id" = host ] && [ "$role" = runtime ]; then
            host_url=$node_url
            host_root=$node_root
            repair_store "$host_url" "$stage/host/state" "$host_root"
          else
            repair_store "$node_url" "$node_stage/state" "$node_root"
          fi
          ${optionalString (cfg.upperOnUpdate == "reconcile") ''
            if [ "$disposition" != empty ] && [ "$disposition" != empty-continuation ]; then
              duplicate_visible_metadata "$physical_id" "$parent" "$node_stage/state" "$node_root"
            fi
          ''}
          publish_mount_upper "$physical_id" "$logical_id" "$role"
          mkdir -p "$scratch/lower-states/$physical_id"
          cp -a "$node_stage/state/." "$scratch/lower-states/$physical_id/"
          echo "nixtache-overlay: prepared $physical_id"
        done < "$rows"
        unmount_all
        while IFS='|' read -r physical_id logical_id role parent rest; do
          [ -n "$physical_id" ] || continue
          mount_physical "$physical_id" "$logical_id" "$role" "$parent"
          node_stage=$(physical_stage "$physical_id" "$logical_id" "$role")
          node_root=$(physical_root "$physical_id")
          node_url=$(store_url "$physical_id" "$physical_id")
          echo "nixtache-overlay: checking $physical_id"
          if [ "$logical_id" = host ] && [ "$role" = runtime ]; then
            host_url=$node_url
            host_root=$node_root
            check_store "$host_url" "$host_root"
          else
            check_store "$node_url" "$node_root"
          fi
        done < "$rows"
        while IFS='|' read -r physical_id logical_id role parent rest; do
          [ -n "$physical_id" ] || continue
          if ! physical_is_parent "$physical_id"; then continue; fi
          parent_url=$(store_url "$physical_id" "$physical_id")
          parent_merged_root=$(physical_root "$physical_id")
          echo "nixtache-overlay: rechecking parent $physical_id"
          check_store "$parent_url" "$parent_merged_root"
        done < "$rows"
        unmount_all
      ''}

      rm -rf "$slot_dir/generations/$generation"
      mv "$stage" "$slot_dir/generations/$generation"
      sed -i 's/^state=unready$/state=ready/' "$slot_dir/generations/$generation/metadata"
      stage=""
      ln -sfn "generations/$generation" "$slot_dir/.current-$generation"
      mv -Tf "$slot_dir/.current-$generation" "$slot_dir/current"
      printf '%s\n' "$target_slot" > "${runtimeState}/prepared-slot"
      printf '%s\n' "$generation" > "${runtimeState}/prepared-generation"
      printf '%s\n' "$source_slot:$source_generation" > "${runtimeState}/prepared-source"
      resume_writers
      trap - EXIT
    }

    if [ "$mode" = "--installed" ]; then
      active_slot=$(discover_booted)
      if [ "$(findmnt -T ${cfg.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)" = tmpfs ]; then
        source_generation="ephemeral"
      else
        active_generation=$(ready_generation "$active_slot") || { echo "nixtache-overlay: active upper chain is not ready" >&2; exit 1; }
        source_generation=$(basename "$active_generation")
      fi
      mapfile -t candidates < <(lsblk -nrpo NAME,PARTUUID,PARTLABEL | awk -v active="$active_slot" 'BEGIN{IGNORECASE=1} $3 ~ /^nix-store_/ {uuid=tolower($2); if (uuid != active && uuid != "") print $1,uuid,$3}')
      [ "''${#candidates[@]}" = 1 ] || { echo "nixtache-overlay: expected exactly one inactive installed lower, found ''${#candidates[@]}" >&2; exit 1; }
      read -r target_device target_slot target_label <<< "''${candidates[0]}"
      target_version=''${target_label#nix-store_}
      prepare_chain "$target_slot" "$target_version" "$target_device" "$active_slot" "$source_generation" 0
    elif [ "$mode" = "--booted" ]; then
      target_slot=$(discover_booted)
      target_version=$(cat /etc/image-version)
      [ -n "$target_version" ] || { echo "nixtache-overlay: empty image version" >&2; exit 1; }
      source_slot=""
      source_generation=""
      initial=0
      slot_dir="${slotsDir}/$target_slot"
      while read -r candidate; do
        [ -n "$candidate" ] || continue
        source_slot=$(metadata_value "$candidate/metadata" source_slot || true)
        source_generation=$(metadata_value "$candidate/metadata" source_generation || true)
        source_dir=""
        if [ -n "$source_slot" ] && [ "$source_generation" = ephemeral ]; then
          break
        fi
        if [ -n "$source_slot" ] && [ -n "$source_generation" ]; then
          source_dir=$(readlink -f "${slotsDir}/$source_slot/generations/$source_generation" 2>/dev/null || true)
        fi
        if [ -n "$source_dir" ] && [ -d "$source_dir" ] \
          && [ "$(metadata_value "$source_dir/metadata" state)" = ready ]; then
          break
        fi
        source_slot=""
        source_generation=""
      done < <(find "$slot_dir/generations" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
      if [ -z "$source_slot" ]; then
        while read -r candidate; do
          [ -n "$candidate" ] && [ "$candidate" != "$target_slot" ] || continue
          generation=$(readlink -f "${slotsDir}/$candidate/current" 2>/dev/null || true)
          if [ -n "$generation" ] && [ -d "$generation" ] \
            && [ "$(metadata_value "$generation/metadata" state)" = ready ]; then
            source_slot=$candidate
            source_generation=$(basename "$generation")
            break
          fi
        done < <(find "${slotsDir}" -mindepth 1 -maxdepth 1 -type d)
      fi
      if [ -z "$source_slot" ] && [ ! -e "${slotsDir}/$target_slot/current" ]; then initial=1; fi
      prepare_chain "$target_slot" "$target_version" BOOTED "$source_slot" "$source_generation" "$initial"
    else
      echo "usage: nixtache-overlay-prepare --installed|--booted" >&2
      exit 2
    fi
  '';

  repairStoreSnippet = ''
    repair_store() {
      local store_url=$1 state=$2 merged=$3
      local roots link root requisites path listing failed=0
      roots=$({ find "$state/gcroots" -type l 2>/dev/null || true; find "$state/profiles/per-user" -maxdepth 2 -type l 2>/dev/null || true; } | sort -u)
      for link in $roots; do
        root=$(readlink "$link" || true)
        case "$root" in /nix/store/*) ;; *) continue ;; esac
        requisites=$(nix-store --option experimental-features "ca-derivations local-overlay-store read-only-local-store" --store "$store_url" -q --requisites "$root" 2>/dev/null) || requisites=""
        if [ -z "$requisites" ]; then
          nix-store --option experimental-features "ca-derivations local-overlay-store read-only-local-store" --store "$store_url" --repair-path "$root" || failed=1
          requisites=$(nix-store --option experimental-features "ca-derivations local-overlay-store read-only-local-store" --store "$store_url" -q --requisites "$root" 2>/dev/null) || failed=1
        fi
        for path in $requisites; do
          [ -e "$merged$path" ] || nix-store --option experimental-features "ca-derivations local-overlay-store read-only-local-store" --store "$store_url" --repair-path "$path" || failed=1
        done
      done
      nix-store --option experimental-features "ca-derivations local-overlay-store read-only-local-store" --store "$store_url" --verify || true
      if ! listing=$(nix --extra-experimental-features "nix-command ca-derivations local-overlay-store read-only-local-store" path-info --all --store "$store_url"); then
        failed=1
      fi
      while read -r path; do
        case "$path" in /nix/store/*) [ -e "$merged$path" ] || { echo "nixtache-overlay: unresolved target path $path" >&2; failed=1; } ;; esac
      done <<< "$listing"
      [ "$failed" = 0 ]
    }
  '';

  checkStoreSnippet = ''
    check_store() {
      local store_url=$1 merged=$2 path listing failed=0
      nix-store --option experimental-features "ca-derivations local-overlay-store read-only-local-store" --store "$store_url" --verify || failed=1
      if ! listing=$(nix --extra-experimental-features "nix-command ca-derivations local-overlay-store read-only-local-store" path-info --all --store "$store_url"); then
        failed=1
      fi
      while read -r path; do
        case "$path" in /nix/store/*) [ -e "$merged$path" ] || { echo "nixtache-overlay: incoherent target record $path" >&2; failed=1; } ;; esac
      done <<< "$listing"
      [ "$failed" = 0 ]
    }
  '';
in
{
  script = prepareScript;
}
