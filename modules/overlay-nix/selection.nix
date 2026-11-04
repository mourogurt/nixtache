{ lib
, pkgs
, cfg
, abEnabled
, imageId
, runtimeState
, slotsDir
, lowerStateLink
, legacyBackup
, stateNames
, prepareScript
, migration
, ...
}:

with lib;

let
  topology = cfg._topology;
  topologyFingerprint = topology.fingerprint;
  nodesById = topology.byId;
  sortedTopology = map (id: nodesById.${id}) topology.order;
  parentId = node: if node.parent == null then "host" else node.parent;
  consumerNode = node: topology.consumerNodeByLogical.${node.id} or node.id;
  graphFingerprint = topology.generationFingerprint;
  runnerLayers = optionals abEnabled (filter (node: node ? containerName) sortedTopology);
  frozenMounts = optionals abEnabled topology.frozenMounts;
  frozenMountByPhysical = topology.frozenMountByPhysical;
  frozenParentMount = node: frozenMountByPhysical.${topology.frozenParentByLogical.${node.id}};
  runtimeBackup = "${runtimeState}/activation-backup";

  activateFrozenGenerationSnippets = concatMapStrings (mount: ''
    if [ "''${ephemeral_layers[${mount.logicalId}]}" = 1 ]; then
      activate_frozen_state ${if mount.parent == null then lowerStateLink else frozenMountByPhysical.${mount.parent}.stateDir} ${mount.stateDir} ${runtimeBackup}/frozen/${mount.id}
    else
      selected_frozen=$(select_frozen_generation "${mount.id}" "${mount.logicalId}")
      activate_frozen_state "$selected_frozen/state" ${mount.stateDir} ${runtimeBackup}/frozen/${mount.id}
    fi
  '') frozenMounts;

  activateRunnerLowerSnippets = concatMapStrings (node:
    let mount = frozenParentMount node; in ''
      if [ "''${ephemeral_layers[${mount.logicalId}]}" = 1 ]; then
        activate_frozen_state ${mount.stateDir} ${node.lowerRoot}/nix/var/nix ${runtimeBackup}/lower-roots/${node.id}
      else
        selected_frozen=$(select_frozen_generation "${mount.id}" "${mount.logicalId}")
        activate_frozen_state "$selected_frozen/state" ${node.lowerRoot}/nix/var/nix ${runtimeBackup}/lower-roots/${node.id}
      fi
    ''
  ) runnerLayers;

  resetFrozenSnippets = concatMapStrings (mount: ''
    reset_dir ${mount.upperDir}
    for name in ${concatStringsSep " " stateNames}; do reset_frozen_path "${mount.stateDir}/$name"; done
  '') frozenMounts + concatMapStrings (node: ''
    for name in ${concatStringsSep " " stateNames}; do reset_frozen_path "${node.lowerRoot}/nix/var/nix/$name"; done
  '') runnerLayers;

  activateEphemeralFrozenSnippets = concatMapStrings (mount: ''
    bind_frozen_state ${if mount.parent == null then lowerStateLink else frozenMountByPhysical.${mount.parent}.stateDir} ${mount.stateDir}
  '') frozenMounts + concatMapStrings (node:
    let mount = frozenParentMount node; in ''
      bind_frozen_state ${mount.stateDir} ${node.lowerRoot}/nix/var/nix
    ''
  ) runnerLayers;

  activationLayerSnippets = concatMapStrings (node: optionalString (node.id != "host") ''
    consumer_generation=""
    if [ -f "$generation/plan.rows" ]; then
      while IFS='|' read -r physical_id logical_id role rest; do
        if [ "$logical_id" = "${node.id}" ] && [ "$role" = runtime ]; then
          consumer_generation="$generation/nodes/$physical_id"
          break
        fi
      done < "$generation/plan.rows"
    fi
    if [ -z "$consumer_generation" ]; then consumer_generation="$generation/nodes/${consumerNode node}"; fi
    if [ ! -d "$consumer_generation" ]; then consumer_generation="$generation/layers/${node.id}"; fi
    if [ "''${ephemeral_layers[${parentId node}]}" = 1 ] || [ "$(findmnt -T ${node.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)" = tmpfs ]; then
      ephemeral_layers[${node.id}]=1
      reset_dir ${node.upperDir}
      reset_dir ${node.workDir}
      for name in ${concatStringsSep " " stateNames}; do reset_dir "${node.stateDir}/$name"; done
    else
      ephemeral_layers[${node.id}]=0
      ${if node.isSingleton or false then ''
        activate_state_dir "$consumer_generation" ${dirOf node.upperDir} ${legacyBackup}/layers/${node.id}/overlay
      '' else ''
        activate_path "$consumer_generation/upper" ${node.upperDir} ${legacyBackup}/layers/${node.id}/upper
        activate_path "$consumer_generation/work" ${node.workDir} ${legacyBackup}/layers/${node.id}/work
      ''}
      for name in ${concatStringsSep " " stateNames}; do
        activate_state_dir "$consumer_generation/state/$name" "${node.stateDir}/$name" "${legacyBackup}/layers/${node.id}/state/$name"
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

  selectionScript = pkgs.writeShellScript "nixtache-overlay-select" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils findutils gnugrep gnused gawk util-linux systemd ])}
    mkdir -p ${runtimeState} ${cfg.upperDir} ${cfg.workDir}
    ${mkdirLayerSnippets}
    rm -f ${runtimeState}/selected-chain-ready
    activation_started=0
    activation_complete=0
    activation_log=${runtimeState}/activation.log
    ${migration.rollbackActivationSnippet}
    trap rollback_activation EXIT

    ${migration.resetDirSnippet}

    ${migration.activatePathSnippet}

    ${migration.activateStateDirSnippet}

    reset_frozen_path() {
      local path=$1
      if mountpoint -q "$path"; then umount "$path"; fi
      reset_dir "$path"
    }

    bind_frozen_state() {
      local source=$1 target=$2 name
      for name in ${concatStringsSep " " stateNames}; do
        mkdir -p "$source/$name" "$target/$name"
        mount --bind "$source/$name" "$target/$name"
        mount -o remount,ro,bind "$target/$name"
      done
    }

    activate_frozen_state() {
      local source=$1 target=$2 backup=$3 name
      for name in ${concatStringsSep " " stateNames}; do
        activate_state_dir "$source/$name" "$target/$name" "$backup/$name"
        mount -o remount,ro,bind "$target/$name"
      done
    }

    select_frozen_generation() {
      local physical_id=$1 logical_id=$2 candidate
      candidate="$generation/nodes/$physical_id"
      if [ ! -d "$candidate" ] && [ "$logical_id" = host ]; then candidate="$generation/host"; fi
      if [ ! -d "$candidate" ]; then candidate="$generation/layers/$logical_id"; fi
      printf '%s\n' "$candidate"
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
      ${activateFrozenGenerationSnippets}
      ${activateRunnerLowerSnippets}
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
      ${resetFrozenSnippets}
      ${activateEphemeralFrozenSnippets}
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
      ${resetFrozenSnippets}
      ${activateEphemeralFrozenSnippets}
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
        metadata_graph=$(sed -n 's/^graph_sha256=//p' "$generation/metadata")
        metadata_descriptor=$(sed -n 's/^descriptor_sha256=//p' "$generation/metadata")
        current_descriptor="/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).overlay-topology.json"
        identity_ready=0
        if [ -n "$metadata_descriptor" ]; then
          if [ -f "$current_descriptor" ] && [ "$metadata_descriptor" = "$(sha256sum "$current_descriptor" | awk '{print $1}')" ]; then identity_ready=1; fi
        elif [ -z "$metadata_graph" ] || [ "$metadata_graph" = "${graphFingerprint}" ]; then
          identity_ready=1
        fi
        if [ "$identity_ready" = 1 ]; then
          if [ ! -f "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" ] || [ "$(sed -n 's/^lower_sha256=//p' "$generation/metadata")" = "$(sha256sum "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" | awk '{print $1}')" ]; then ready=1; fi
        fi
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
  discoverySnippet = ''
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
  '';

  metadataValueSnippet = ''
    metadata_value() {
      local file=$1 key=$2
      [ -f "$file" ] && sed -n "s/^$key=//p" "$file" | head -n 1
    }
  '';

  readyGenerationSnippet = ''
    ready_generation() {
      local slot=$1 generation metadata dump_sha current_sha metadata_graph metadata_descriptor current_descriptor
      generation=$(readlink -f "${slotsDir}/$slot/current" 2>/dev/null || true)
      [ -n "$generation" ] && [ -d "$generation" ] || return 1
      metadata="$generation/metadata"
      [ "$(metadata_value "$metadata" state)" = "ready" ] || return 1
      [ "$(metadata_value "$metadata" slot)" = "$slot" ] || return 1
      [ "$(metadata_value "$metadata" topology_sha256)" = "${topologyFingerprint}" ] || return 1
      metadata_graph=$(metadata_value "$metadata" graph_sha256)
      metadata_descriptor=$(metadata_value "$metadata" descriptor_sha256)
      current_descriptor="/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).overlay-topology.json"
      if [ -n "$metadata_descriptor" ]; then
        [ -f "$current_descriptor" ] || return 1
        [ "$metadata_descriptor" = "$(sha256sum "$current_descriptor" | awk '{print $1}')" ] || return 1
      else
        [ -z "$metadata_graph" ] || [ "$metadata_graph" = "${graphFingerprint}" ] || return 1
      fi
      if [ -f "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" ]; then
        dump_sha=$(metadata_value "$metadata" lower_sha256)
        current_sha=$(sha256sum "/boot/EFI/nixtache/${imageId}_$(cat /etc/image-version).lower-db" | awk '{print $1}')
        [ "$dump_sha" = "$current_sha" ] || return 1
      fi
      printf '%s\n' "$generation"
    }
  '';

  script = selectionScript;
}
