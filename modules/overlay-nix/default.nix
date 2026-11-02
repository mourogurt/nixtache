{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nixtache.overlay-nix;
  abCfg = config.services.nixtache.ab-image or { };
  abEnabled = abCfg.enable or false;
  imageId = abCfg.imageId or "nixtache";
  runnerCfg = config.services.nixtache.runner or { };
  runnerStore = runnerCfg.store or { };
  runnerOverlay = (runnerCfg.enable or false)
    && (runnerStore.path or "/") != "/"
    && (runnerStore.mode or "clone") == "overlay";
  runnerHostBackup = runnerStore.hostBackup or "/srv/bincache";
  runnerContainer = "container@${runnerCfg.containerName or "runner"}.service";

  layerType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Stable overlay node identity used in the metaslot topology and on-disk layer path.";
      };
      parent = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Parent overlay node identity, or null for a direct child of the host overlay.";
      };
      upperDir = mkOption {
        type = types.str;
        description = "Stable runtime path for this node's writable OverlayFS upper directory.";
      };
      workDir = mkOption {
        type = types.str;
        description = "Stable runtime path for this node's OverlayFS work directory.";
      };
      stateDir = mkOption {
        type = types.str;
        description = "Stable runtime path for this node's upper-owned Nix state directory.";
      };
      lowerRoot = mkOption {
        type = types.str;
        default = "/run/nixtache-runner-lower";
        description = "Read-only parent-lower root outside the child's relocated `/nix`.";
      };
    };
  };

  configuredLayers = cfg.layers or [ ];
  topologyNodes = [
    {
      id = "host";
      parent = null;
      inherit (cfg) upperDir workDir;
      stateDir = "/nix/var/nix";
      lowerRoot = "";
    }
  ] ++ configuredLayers ++ lib.optional runnerOverlay {
    id = "runner";
    parent = null;
    upperDir = "${runnerHostBackup}/overlay/upper";
    workDir = "${runnerHostBackup}/overlay/work";
    stateDir = "${runnerHostBackup}/nix/var/nix";
    lowerRoot = "/run/nixtache-runner-lower";
  };
  topologyIds = map (node: node.id) topologyNodes;
  childrenOf = parent: builtins.filter (node: node.id != "host" && (if node.parent == null then "host" else node.parent) == parent) topologyNodes;
  visitTopology = parent: path:
    if builtins.elem parent path then
      throw "services.nixtache.overlay-nix.layers: topology cycle detected: ${concatStringsSep " -> " (path ++ [ parent ])}"
    else
      [ parent ] ++ builtins.concatLists (map
        (node: visitTopology node.id (path ++ [ parent ]))
        (childrenOf parent));
  sortedNodeIds = visitTopology "host" [ ];
  sortedTopology = map (id: builtins.head (builtins.filter (node: node.id == id) topologyNodes)) sortedNodeIds;
  nodesById = listToAttrs (map (node: nameValuePair node.id node) topologyNodes);
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
      lower = if node.id == "host" then "$lower_url" else "$(uri_encode \"${urlExpression ownId (nodesById.${parentId node}) root}\")";
    in
    "local-overlay://?root=${root}&state=${state}&lower-store=${lower}&upper-layer=${nodeStage node}/upper&ignore-gc-delete-failure=true&check-mount=false";
  topologyFingerprint = builtins.hashString "sha256" (builtins.toJSON
    (map (node: { inherit (node) id parent; }) sortedTopology));
  topologyName = concatStringsSep "," sortedNodeIds;

  stateDir = "/var/lib/nixtache";
  runtimeState = "/run/nixtache-overlay";
  overlayBase = dirOf cfg.upperDir;
  slotsDir = "${overlayBase}/upper-slots";
  lowerStateLink = "${overlayBase}/lower-state";
  legacyBackup = "${overlayBase}/legacy-backup";
  stateNames = [ "db" "gcroots" "profiles" "temproots" ];

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

  overlayStoreUrl = "local-overlay://"
    + "?lower-store=${if abEnabled then "local%3Fstate%3D${lowerStateLink}%26read-only%3Dtrue" else "local"}"
    + "&upper-layer=${cfg.upperDir}"
    + "&ignore-gc-delete-failure=true"
    + "&remount-hook=${remountHook}"
    + "&check-mount=false";

  remountHook = pkgs.writeShellScript "nixtache-overlay-remount" ''
    export PATH=${lib.makeBinPath [ pkgs.util-linux pkgs.coreutils ]}
    mountpoint="''${1:-/nix/store}"
    i=0
    while ! umount "$mountpoint"; do
      i=$((i + 1))
      if [ "$i" -ge 10 ]; then
        echo "nixtache-overlay-remount: $mountpoint still busy after 10 tries" >&2
        exit 0
      fi
      sleep 1
    done
    mount -t overlay overlay -o lowerdir="$mountpoint" -o upperdir=${cfg.upperDir} -o workdir=${cfg.workDir} "$mountpoint"
  '';

  stageLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    mkdir -p "${nodeStage node}/upper" "${nodeStage node}/work" "${nodeStage node}/state"
  '') sortedTopology;

  cloneLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    source_path=${"$source_dir"}/layers/${node.id}
    ${optionalString (node.id == "runner") ''
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

  activationLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    if [ "''${ephemeral_layers[${parentId node}]}" = 1 ] || [ "$(findmnt -T ${node.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)" = tmpfs ]; then
      ephemeral_layers[${node.id}]=1
      reset_dir ${node.upperDir}
      reset_dir ${node.workDir}
      for name in ${concatStringsSep " " stateNames}; do reset_dir "${node.stateDir}/$name"; done
    else
      ephemeral_layers[${node.id}]=0
      ${if node.id == "runner" then ''
        activate_state_dir "$generation/layers/runner" ${runnerHostBackup}/overlay ${legacyBackup}/layers/runner/overlay
      '' else ''
        activate_path "$generation/layers/${node.id}/upper" ${node.upperDir} ${legacyBackup}/layers/${node.id}/upper
        activate_path "$generation/layers/${node.id}/work" ${node.workDir} ${legacyBackup}/layers/${node.id}/work
      ''}
      for name in ${concatStringsSep " " stateNames}; do
        activate_state_dir "$generation/layers/${node.id}/state/$name" "${node.stateDir}/$name" "${legacyBackup}/layers/${node.id}/state/$name"
      done
    fi
  '') sortedTopology;

  mkdirLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    mkdir -p ${node.upperDir} ${node.workDir} ${node.stateDir}
  '') sortedTopology;

  resetLayerSnippets = ''
    declare -A ephemeral_layers
    ephemeral_layers[host]=0
  '' + concatMapStrings (node: optionalString (node.id != "host") ''
    if [ "''${ephemeral_layers[${parentId node}]}" = 1 ] || [ "$(findmnt -T ${node.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)" = tmpfs ]; then
      ephemeral_layers[${node.id}]=1
      reset_dir ${node.upperDir}
      reset_dir ${node.workDir}
      for name in ${concatStringsSep " " stateNames}; do reset_dir "${node.stateDir}/$name"; done
    else
      ephemeral_layers[${node.id}]=0
    fi
  '') sortedTopology;

  resetAllLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    reset_dir ${node.upperDir}
    reset_dir ${node.workDir}
    for name in ${concatStringsSep " " stateNames}; do reset_dir "${node.stateDir}/$name"; done
  '') sortedTopology;

  prepareScript = pkgs.writeShellScript "nixtache-overlay-prepare" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux nix sqlite systemd ])}

    mode=''${1:---installed}
    mkdir -p ${runtimeState} ${slotsDir}

    discover_booted() {
      local source partuuid resolved selected
      if [ -r ${runtimeState}/selected-slot ]; then
        selected=$(cat ${runtimeState}/selected-slot)
        resolved=$(readlink -f "/dev/disk/by-partuuid/$selected")
        [ -n "$selected" ] && [ -b "$resolved" ] || { echo "nixtache-overlay: selected lower PARTUUID is unavailable" >&2; return 1; }
        partuuid=$(blkid -s PARTUUID -o value "$resolved" | tr 'A-F' 'a-f')
        [ "$partuuid" = "$selected" ] || { echo "nixtache-overlay: selected lower PARTUUID is ambiguous" >&2; return 1; }
        printf '%s\n' "$selected"
        return 0
      fi
      source=$(findmnt -n -o SOURCE --target /nix/store | grep '^/dev/' | sort -u)
      [ -n "$source" ] && [ -b "$source" ] || { echo "nixtache-overlay: cannot resolve the mounted lower block device" >&2; return 1; }
      partuuid=$(blkid -s PARTUUID -o value "$source" | tr 'A-F' 'a-f')
      [ -n "$partuuid" ] || { echo "nixtache-overlay: mounted lower $source has no GPT PARTUUID" >&2; return 1; }
      resolved=$(readlink -f "/dev/disk/by-partuuid/$partuuid")
      [ "$resolved" = "$source" ] || { echo "nixtache-overlay: ambiguous PARTUUID $partuuid for $source" >&2; return 1; }
      printf '%s\n' "$partuuid"
    }

    metadata_value() {
      local file=$1 key=$2
      [ -f "$file" ] && sed -n "s/^$key=//p" "$file" | head -n 1
    }

    ready_generation() {
      local slot=$1 generation metadata dump_sha current_sha
      generation=$(readlink -f "${slotsDir}/$slot/current" 2>/dev/null || true)
      [ -n "$generation" ] && [ -d "$generation" ] || return 1
      metadata="$generation/metadata"
      [ "$(metadata_value "$metadata" state)" = "ready" ] || return 1
      [ "$(metadata_value "$metadata" slot)" = "$slot" ] || return 1
      [ "$(metadata_value "$metadata" topology_sha256)" = "${topologyFingerprint}" ] || return 1
      if [ -f "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" ]; then
        dump_sha=$(metadata_value "$metadata" lower_sha256)
        current_sha=$(sha256sum "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" | awk '{print $1}')
        [ "$dump_sha" = "$current_sha" ] || return 1
      fi
      printf '%s\n' "$generation"
    }

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

  selectionScript = pkgs.writeShellScript "nixtache-overlay-select" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux systemd ])}
    mkdir -p ${runtimeState} ${cfg.upperDir} ${cfg.workDir}
    ${mkdirLayerSnippets}
    rm -f ${runtimeState}/selected-chain-ready
    activation_started=0
    activation_complete=0
    activation_log=${runtimeState}/activation.log
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
    trap rollback_activation EXIT

    reset_dir() {
      local path=$1
      if [ -L "$path" ]; then rm -f "$path"; fi
      mkdir -p "$path"
      find "$path" -mindepth 1 -delete
    }

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

    activate_generation() {
      local generation=$1 name
      activation_started=1
      : > "$activation_log"
      activate_path "$generation/host/upper" ${cfg.upperDir} ${legacyBackup}/host/upper
      activate_path "$generation/host/work" ${cfg.workDir} ${legacyBackup}/host/work
      activate_path "$generation/host/lower-state" ${lowerStateLink} ${legacyBackup}/host/lower-state
      for name in ${concatStringsSep " " stateNames}; do
        activate_state_dir "$generation/host/state/$name" "/nix/var/nix/$name" "${legacyBackup}/host/state/$name"
      done
      ${activationLayerSnippets}
      printf '%s\n' "$1" > ${runtimeState}/selected-generation
      touch ${runtimeState}/selected-chain-ready
      activation_complete=1
    }

    if [ "${boolToString abEnabled}" != true ] || [ ! -f /etc/image-version ]; then
      upper_fs=$(findmnt -T ${cfg.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)
      if [ "$upper_fs" = "tmpfs" ]; then
        reset_dir ${cfg.upperDir}
        reset_dir ${cfg.workDir}
        for name in ${concatStringsSep " " stateNames}; do reset_dir "/nix/var/nix/$name"; done
        ${resetAllLayerSnippets}
      else
        mkdir -p ${cfg.upperDir} ${cfg.workDir} ${lowerStateLink}
        for name in ${concatStringsSep " " stateNames}; do mkdir -p "/nix/var/nix/$name"; done
        ${mkdirLayerSnippets}
        ${resetLayerSnippets}
      fi
      touch ${runtimeState}/selected-chain-ready
      exit 0
    fi

    upper_fs=$(findmnt -T ${cfg.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)
    if [ "$upper_fs" = "tmpfs" ]; then
      reset_dir ${cfg.upperDir}
      reset_dir ${cfg.workDir}
      reset_dir ${lowerStateLink}
      for name in ${concatStringsSep " " stateNames}; do reset_dir "/nix/var/nix/$name"; done
      ${resetAllLayerSnippets}
      touch ${runtimeState}/selected-chain-ready
      exit 0
    fi

    ${resetLayerSnippets}
    lower_source=$(findmnt -n -o SOURCE --target /nix/store | grep '^/dev/' | sort -u)
    [ -n "$lower_source" ] && [ -b "$lower_source" ] || { echo "nixtache-overlay: mounted lower is not one block device" >&2; exit 1; }
    slot=$(blkid -s PARTUUID -o value "$lower_source" | tr 'A-F' 'a-f')
    [ -n "$slot" ] || { echo "nixtache-overlay: cannot select an upper without a lower PARTUUID" >&2; exit 1; }
    [ "$(readlink -f "/dev/disk/by-partuuid/$slot")" = "$lower_source" ] || { echo "nixtache-overlay: ambiguous lower PARTUUID" >&2; exit 1; }
    generation=$(readlink -f "${slotsDir}/$slot/current" 2>/dev/null || true)
    ready=0
    if [ -n "$generation" ] && [ "$(sed -n 's/^state=//p' "$generation/metadata" 2>/dev/null)" = ready ]; then
      if [ "$(sed -n 's/^topology_sha256=//p' "$generation/metadata")" = "${topologyFingerprint}" ]; then
        if [ ! -f "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" ] || [ "$(sed -n 's/^lower_sha256=//p' "$generation/metadata")" = "$(sha256sum "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" | awk '{print $1}')" ]; then ready=1; fi
      fi
    fi
    if [ "$ready" = 0 ]; then
      ${prepareScript} --booted
      generation=$(readlink -f "${slotsDir}/$slot/current")
    fi
    [ -n "$generation" ] && [ -d "$generation/host/upper" ] || { echo "nixtache-overlay: selected chain is not ready" >&2; exit 1; }
    activate_generation "$generation"
    printf '%s\n' "$slot" > ${runtimeState}/selected-slot
    while read -r other; do
      [ -n "$other" ] || continue
      other_uuid=$(blkid -s PARTUUID -o value "$other" | tr 'A-F' 'a-f')
      [ -n "$other_uuid" ] && [ "$other_uuid" != "$slot" ] || continue
      mkdir -p "${slotsDir}/$other_uuid"
      if [ ! -e "${slotsDir}/$other_uuid/current" ] && [ ! -f "${slotsDir}/$other_uuid/unready" ]; then
        printf 'slot=%s\nstate=unready\n' "$other_uuid" > "${slotsDir}/$other_uuid/unready"
      fi
    done < <(lsblk -nrpo NAME,PARTLABEL | awk '$2 ~ /^nix-store_/ || $2 == "_empty" {print $1}')
  '';
in
{
  options.services.nixtache.overlay-nix = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Layer a writable OverlayFS over `/nix/store` through Nix's experimental
        `local-overlay-store`. On A/B appliances, persistent upper files and Nix
        state are selected with the physical lower partition and preserved for
        rollback. Requires Nix >= 2.19.
      '';
    };

    upperDir = mkOption {
      type = types.str;
      default = "/var/lib/nix-overlay/upper";
      description = ''
        Stable runtime path for the writable OverlayFS upper layer. On A/B
        appliances this path selects the current physical slot's upper
        metaslot. It must share a filesystem with `workDir`; use tmpfs for an
        ephemeral chain.
      '';
    };

    workDir = mkOption {
      type = types.str;
      default = "/var/lib/nix-overlay/work";
      description = ''
        Stable runtime path for OverlayFS work metadata. Each slot generation
        receives an empty work directory on the same filesystem as `upperDir`.
      '';
    };

    upperOnUpdate = mkOption {
      type = types.enum [ "wipe" "reconcile" ];
      default = "wipe";
      description = ''
        Preparation policy for the inactive physical slot after a lower image
        installs. `"wipe"` creates an empty target upper and upper-owned Nix
        state. `"reconcile"` quiesces module-managed writers, clones the active
        upper chain, and repairs only that target copy against the new lower.
        The active upper is never wiped or repaired for a slot swap. An
        interrupted or incoherent target remains unready; booting an unprepared
        slot attempts target-only recovery before upper consumers start.
        Rollback selects the earlier slot's preserved chain without applying
        the policy again. Tmpfs uppers and all dependent overlay layers reset
        on every boot instead of using persistent metaslots.
      '';
    };

    layers = mkOption {
      type = types.listOf layerType;
      default = [ ];
      description = ''
        Additional local-overlay nodes in the physical slot's upper metaslot.
        Each node has a stable identity and names its parent, forming one
        validated rooted tree with the host overlay. Duplicate identities,
        missing parents and cycles fail evaluation. Parents are prepared and
        verified before children; all nodes share one readiness result.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = (builtins.compareVersions config.nix.package.version "2.19") >= 0;
          message = "services.nixtache.overlay-nix requires Nix >= 2.19 for local-overlay-store";
        }
        {
          assertion = builtins.all (id: builtins.match "[A-Za-z0-9._-]+" id != null) topologyIds;
          message = "services.nixtache.overlay-nix.layers: node identities may contain only letters, digits, '.', '_' and '-'.";
        }
        {
          assertion = builtins.length topologyIds == builtins.length (lists.unique topologyIds);
          message = "services.nixtache.overlay-nix.layers: duplicate node identity in the upper topology.";
        }
        {
          assertion = builtins.all (node: node.parent == null || builtins.elem node.parent topologyIds) configuredLayers;
          message = "services.nixtache.overlay-nix.layers: every parent must name an existing overlay node.";
        }
        {
          assertion = builtins.length sortedNodeIds == builtins.length topologyIds;
          message = "services.nixtache.overlay-nix.layers: every node must be reachable from the host root.";
        }
      ];

      nix.enable = mkOverride 99 true;
      nix.settings.store = overlayStoreUrl;
      nix.settings.extra-experimental-features = [ "nix-command" "flakes" "local-overlay-store" "ca-derivations" "read-only-local-store" ];
      nix.settings.flake-registry = "";

      systemd.services.nixtache-overlay-select = {
        description = "Select and recover the physical slot's Nix upper metaslot";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "zfs-mount.service" ];
        before = [ "nixtache-lower-store-db-load.service" "nix-daemon-overlay-mount.service" "nix-daemon.service" ];
        path = with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux systemd nix sqlite ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = readFile selectionScript;
      };

      systemd.services.nixtache-overlay-prepare = {
        description = "Prepare the inactive physical slot's Nix upper metaslot";
        path = with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux systemd nix sqlite ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "1h";
        };
        script = "${prepareScript} --installed";
      };

      systemd.services.nix-daemon-overlay-mount = {
        description = "Mount the selected upper over the physical lower Nix store";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "nixtache-overlay-select.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
        requires = [ "nixtache-overlay-select.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
        before = [ "nix-daemon.service" ];
        path = with pkgs; [ util-linux coreutils gnugrep ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          if mount | grep 'overlay on /nix/store ' | grep -q 'upperdir=${cfg.upperDir}'; then
            exit 0
          fi
          mount -t overlay overlay -o lowerdir=/nix/store -o upperdir=${cfg.upperDir} -o workdir=${cfg.workDir} /nix/store
        '';
      };

      systemd.services.nix-daemon = {
        after = [ "nix-daemon-overlay-mount.service" "nixtache-overlay-ready.target" ];
        requires = [ "nix-daemon-overlay-mount.service" "nixtache-overlay-ready.target" ];
      };

      systemd.targets.nixtache-overlay-ready = {
        description = "Selected lower, upper files and Nix metadata are coherent";
        wantedBy = [ "multi-user.target" ];
        after = [ "nixtache-overlay-select.service" "nix-daemon-overlay-mount.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
        requires = [ "nixtache-overlay-select.service" "nix-daemon-overlay-mount.service" ]
          ++ optional abEnabled "nixtache-lower-store-db-load.service";
      };

      systemd.targets.boot-complete = mkIf abEnabled {
        after = [ "nixtache-overlay-ready.target" ];
        requires = [ "nixtache-overlay-ready.target" ];
      };
    }

    (mkIf abEnabled {
      environment.etc."image-version".text = mkDefault config.system.image.version;
      systemd.services.nixtache-lower-store-db-load = {
        after = [ "nixtache-overlay-select.service" ];
        requires = [ "nixtache-overlay-select.service" ];
        before = [ "nix-daemon-overlay-mount.service" "nix-daemon.service" ];
      };
      systemd.services.systemd-sysupdate-reboot = {
        after = [ "nixtache-overlay-prepare.service" ];
        requires = [ "nixtache-overlay-prepare.service" ];
      };
    })

    (mkIf runnerOverlay {
      systemd.services."container@${runnerCfg.containerName}" = {
        after = [ "nixtache-overlay-ready.target" ];
        requires = [ "nixtache-overlay-ready.target" ];
      };
    })
  ]);
}
