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
  physicalTopology = topology;
  topologyFingerprint = topology.fingerprint;
  topologyName = concatStringsSep "," topology.order;
  nodesById = topology.byId;
  sortedTopology = map (id: nodesById.${id}) topology.order;
  runnerLayers = filter (node: node ? containerName) topology.nodes;
  runnerContainerUnits = map (node: "container@${node.containerName}.service") runnerLayers;
  runnerContainer = concatStringsSep " " runnerContainerUnits;

  nodeStage = node: if node.id == "host" then "$stage/host" else "$stage/layers/${node.id}";
  parentId = node: if node.parent == null then "host" else node.parent;
  nodeRoot = node: if node.id == "host" then "$host_root" else "$scratch/layers/${node.id}";
  nodeMountLower = node: if parentId node == "host"
    then "${nodeStage nodesById.host}/upper:$lower_store"
    else "$scratch/layers/${parentId node}/nix/store";
  unmountAllSnippet = concatMapStrings (node: ''
    if mountpoint -q ${nodeRoot node}/nix/store; then umount ${nodeRoot node}/nix/store; fi
  '') (reverseList sortedTopology);
  urlExpression = ownId: node: root:
    let
      state = if node.id == ownId then "${nodeStage node}/state" else "$scratch/lower-states/${node.id}";
      lower = if node.id == "host" then "$lower_url" else "$(uri_encode \"${urlExpression ownId (nodesById.${parentId node}) (nodeRoot (nodesById.${parentId node}))}\")";
    in
    "local-overlay://?root=${root}&state=${state}&lower-store=${lower}&upper-layer=${nodeStage node}/upper&ignore-gc-delete-failure=true&check-mount=false";

  encodeStoreUri = ''
    uri_encode() {
      local value=$1
      value=''${value//%/%25}
      value=''${value//\?/%3F}
      value=''${value//&/%26}
      value=''${value//=/%3D}
      printf '%s' "$value"
    }
  '';

  stageLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    mkdir -p "${nodeStage node}/upper" "${nodeStage node}/work" "${nodeStage node}/state"
  '') sortedTopology;

  cloneLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    source_path=${"$source_dir"}/layers/${node.id}
    ${optionalString (node.isSingleton or false) ''
      if [ ! -d "$source_path" ]; then source_path=${"$source_dir"}/runner; fi
    ''}
    copy_layer "$source_path" "${nodeStage node}"
    copy_state "$source_path/state" "${nodeStage node}/state"
  '') sortedTopology;

  initialLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    copy_layer ${node.upperDir} "${nodeStage node}"
    copy_state ${node.stateDir} "${nodeStage node}/state"
  '') sortedTopology;

  namespaceLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    node_root="$scratch/layers/${node.id}"
    node_stage="${nodeStage node}"
    mkdir -p "$node_root/nix/store"
    ${optionalString (parentId node == "host") "unmount_all"}
    mount -t overlay overlay -o lowerdir="${nodeMountLower node}",upperdir="$node_stage/upper",workdir="$node_stage/work" "$node_root/nix/store"
    node_url="${urlExpression node.id node "$node_root"}"
    echo "nixtache-overlay: repairing ${node.id}"
    repair_store "$node_url" "$node_stage/state" "$node_root"
    mkdir -p "$scratch/lower-states/${node.id}"
    cp -a "$node_stage/state/." "$scratch/lower-states/${node.id}/"
    echo "nixtache-overlay: prepared ${node.id}"
  '') sortedTopology;

  checkLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    node_root="$scratch/layers/${node.id}"
    node_stage="${nodeStage node}"
    ${optionalString (parentId node == "host") "unmount_all"}
    mount -t overlay overlay -o lowerdir="${nodeMountLower node}",upperdir="$node_stage/upper",workdir="$node_stage/work" "$node_root/nix/store"
    node_url="${urlExpression node.id node "$node_root"}"
    echo "nixtache-overlay: checking ${node.id}"
    check_store "$node_url" "$node_root"
  '') sortedTopology;

  prepareScript = pkgs.writeShellScript "nixtache-overlay-prepare" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux nix sqlite systemd ])}

    mode=''${1:---installed}
    mkdir -p ${runtimeState} ${slotsDir}

    ${discoverySnippet}

    ${metadataValueSnippet}

    ${readyGenerationSnippet}

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
      fi
    }

    quiesced=0
    stopped_units=""
    resume_writers() {
      local unit
      if [ "$quiesced" = 1 ]; then
        for unit in $stopped_units; do systemctl start "$unit" || true; done
        quiesced=0
      fi
    }
    rollback_stage() {
      local status=$?
      trap - EXIT TERM INT HUP
      resume_writers
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
      local target_dump scratch lower_root lower_store host_root runner_root host_url runner_url lower_url
      slot_dir="${slotsDir}/$target_slot"
      generation="$(date +%Y%m%d%H%M%S)-$$"
      stage="$slot_dir/.staging-$generation"
      target_dump="/boot/EFI/nixtache/${imageId}_$target_version.lower-db"
      [ -f "$target_dump" ] || { echo "nixtache-overlay: target lower dump is missing: $target_dump" >&2; return 1; }
      [ "$target_slot" != "$source_slot" ] || [ "$initial" = 1 ] || { echo "nixtache-overlay: active and target slots must differ" >&2; return 1; }
      mkdir -p "$slot_dir/generations"
      rm -rf "$slot_dir"/.staging-*
      while read -r old; do
        [ -n "$old" ] || continue
        if [ "$(metadata_value "$old/metadata" state)" != "ready" ]; then rm -rf "$old"; fi
      done < <(find "$slot_dir/generations" -mindepth 1 -maxdepth 1 -type d)
      mkdir -p "$slot_dir/generations/$generation"
      cat > "$slot_dir/generations/$generation/metadata" <<EOF
    slot=$target_slot
    image_id=${imageId}
    image_version=$target_version
    lower_sha256=$(sha256sum "$target_dump" | awk '{print $1}')
    policy=${cfg.upperOnUpdate}
    topology=${topologyName}
    topology_sha256=${topologyFingerprint}
    graph_sha256=${physicalTopology.generationFingerprint}
    source_slot=$source_slot
    source_generation=$source_generation
    generation=$generation
    state=unready
    EOF
      mkdir -p "$stage/host/upper" "$stage/host/work" "$stage/host/state" "$stage/host/lower-state"
      ${stageLayerSnippets}
      cp "$slot_dir/generations/$generation/metadata" "$stage/metadata"

      if [ "$initial" = 1 ]; then
        copy_layer ${cfg.upperDir} "$stage/host"
        copy_state /nix/var/nix "$stage/host/state"
        ${initialLayerSnippets}
      elif [ "${cfg.upperOnUpdate}" = "reconcile" ]; then
        source_dir=$(readlink -f "${slotsDir}/$source_slot/generations/$source_generation")
        [ "$(metadata_value "$source_dir/metadata" state)" = "ready" ] || { echo "nixtache-overlay: reconcile source is not ready" >&2; return 1; }
        if [ "$mode" = "--installed" ]; then
          for unit in ${runnerContainer} nix-daemon.service nix-daemon.socket; do
            if systemctl is-active --quiet "$unit"; then
              systemctl stop "$unit"
              stopped_units="$unit $stopped_units"
            fi
          done
          quiesced=1
        fi
        copy_layer "$source_dir/host" "$stage/host"
        copy_state "$source_dir/host/state" "$stage/host/state"
        ${cloneLayerSnippets}
        resume_writers
      fi

      scratch=$(mktemp -d /run/nixtache-overlay/prepare.XXXXXX)
      lower_root="$scratch/lower"
      lower_store="$lower_root/nix/store"
      host_root="$scratch/host"
      mkdir -p "$lower_store" "$host_root/nix/store"
      export target_device scratch lower_root lower_store host_root stage target_dump
      # The target lower and both writable layers are private to this namespace.
      unshare -m --propagation private ${pkgs.writeShellScript "nixtache-overlay-verify-namespace" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux nix ])}
            ${encodeStoreUri}
        if [ "$target_device" = "BOOTED" ]; then
          mount --bind /nix/store "$lower_store"
          mount -o remount,ro,bind "$lower_store"
        else
          mount -o ro "$target_device" "$lower_store"
        fi
        seed=$(mktemp -d /run/nixtache-overlay/seed.XXXXXX)
        mkdir -p "$seed/upper" "$seed/work"
        mount -t overlay overlay -o lowerdir="$lower_store",upperdir="$seed/upper",workdir="$seed/work" "$lower_store"
        nix-store --option experimental-features "ca-derivations" --store "local?root=$lower_root&state=$stage/host/lower-state" --load-db < "$target_dump"
        umount "$lower_store"
        mount -t overlay overlay -o lowerdir="$lower_store",upperdir="$stage/host/upper",workdir="$stage/host/work" "$host_root/nix/store"
        lower_url=$(uri_encode "local?root=$lower_root&state=$stage/host/lower-state&read-only=true")
        host_url="${urlExpression "host" nodesById.host "$host_root"}"
        ${repairStoreSnippet}
        ${checkStoreSnippet}
        unmount_all() {
          ${unmountAllSnippet}
        }
        echo "nixtache-overlay: repairing host"
        repair_store "$host_url" "$stage/host/state" "$host_root"
        mkdir -p "$scratch/lower-states/host"
        cp -a "$stage/host/state/." "$scratch/lower-states/host/"
        echo "nixtache-overlay: prepared host"
        ${namespaceLayerSnippets}
        unmount_all
        mount -t overlay overlay -o lowerdir="$lower_store",upperdir="$stage/host/upper",workdir="$stage/host/work" "$host_root/nix/store"
        echo "nixtache-overlay: checking host"
        check_store "$host_url" "$host_root"
        ${checkLayerSnippets}
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
      trap - EXIT
      resume_writers
    }

    if [ "$mode" = "--installed" ]; then
      active_slot=$(discover_booted)
      active_generation=$(ready_generation "$active_slot") || { echo "nixtache-overlay: active upper chain is not ready" >&2; exit 1; }
      source_generation=$(basename "$active_generation")
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
        source_slot=$(metadata_value "$candidate/metadata" source_slot)
        source_generation=$(metadata_value "$candidate/metadata" source_generation)
        [ -n "$source_slot" ] && [ -n "$source_generation" ] && break
      done < <(find "$slot_dir/generations" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
      if [ -z "$source_slot" ]; then
        while read -r candidate; do
          [ -n "$candidate" ] && [ "$candidate" != "$target_slot" ] || continue
          generation=$(readlink -f "${slotsDir}/$candidate/current" 2>/dev/null || true)
          if [ -n "$generation" ] && [ "$(metadata_value "$generation/metadata" state)" = ready ]; then
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
