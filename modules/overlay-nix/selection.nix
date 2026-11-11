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
  evalParent = node:
    let parent = topology.frozenParentByLogical.${node.id} or null; in
    if parent == null then "-" else parent;
  consumerNode = node: topology.consumerNodeByLogical.${node.id} or node.id;
  graphFingerprint = topology.generationFingerprint;
  runnerLayers = optionals abEnabled (filter (node: node ? containerName) sortedTopology);
  frozenMounts = optionals abEnabled topology.frozenMounts;
  inherit (topology) parentRoot physicalHostRoot;
  frozenMountByPhysical = topology.frozenMountByPhysical;
  runtimeBackup = "${runtimeState}/activation-backup";
  plannerSource = pkgs.writeText "nixtache-overlay-planner.py" (builtins.readFile ./planner.py);
  planner = pkgs.writeShellScript "nixtache-overlay-planner" ''
    exec ${pkgs.python3}/bin/python3 ${plannerSource} "$@"
  '';
  descriptorValidator = pkgs.writeShellScript "nixtache-overlay-validate-descriptor" ''
    exec ${planner} validate --image-id ${escapeShellArg imageId} "$@"
  '';

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
      source=$(findmnt -n -o SOURCE --target ${physicalHostRoot}/nix/store | grep '^/dev/' | sort -u)
      [ -n "$source" ] && [ -b "$source" ] || { echo "nixtache-overlay: cannot resolve the preserved physical lower block device" >&2; return 1; }
      partuuid=$(blkid -s PARTUUID -o value "$source" | tr 'A-F' 'a-f')
      [ -n "$partuuid" ] || { echo "nixtache-overlay: preserved physical lower $source has no GPT PARTUUID" >&2; return 1; }
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
      local slot=$1 generation metadata dump_sha current_sha metadata_graph metadata_descriptor current_descriptor current_dump image_version booted_system
      generation=$(readlink -f "${slotsDir}/$slot/current" 2>/dev/null || true)
      [ -n "$generation" ] && [ -d "$generation" ] || return 1
      metadata="$generation/metadata"
      image_version=$(cat /etc/image-version 2>/dev/null) || return 1
      [ -n "$image_version" ] || return 1
      [ "$(metadata_value "$metadata" state)" = "ready" ] || return 1
      [ "$(metadata_value "$metadata" slot)" = "$slot" ] || return 1
      [ "$(metadata_value "$metadata" image_id)" = ${imageId} ] || return 1
      [ "$(metadata_value "$metadata" image_version)" = "$image_version" ] || return 1
      [ "$(metadata_value "$metadata" topology_sha256)" = "${topologyFingerprint}" ] || return 1
      current_dump="$generation/lower-db"
      [ -f "$current_dump" ] || return 1
      dump_sha=$(metadata_value "$metadata" lower_sha256)
      current_sha=$(sha256sum "$current_dump" | awk '{print $1}')
      [ "$dump_sha" = "$current_sha" ] || return 1
      booted_system=$(readlink -f /run/booted-system 2>/dev/null) || return 1
      case "$booted_system" in /nix/store/*) ;; *) return 1 ;; esac
      grep -Fqx -- "$booted_system" "$current_dump" || return 1
      metadata_graph=$(metadata_value "$metadata" graph_sha256)
      metadata_descriptor=$(metadata_value "$metadata" descriptor_sha256)
      current_descriptor="$generation/overlay-topology.json"
      if [ -n "$metadata_descriptor" ]; then
        [ -f "$current_descriptor" ] || return 1
        [ "$metadata_descriptor" = "$(sha256sum "$current_descriptor" | awk '{print $1}')" ] || return 1
        ${descriptorValidator} "$current_descriptor" "$image_version" "$dump_sha" >/dev/null 2>&1 || return 1
      else
        [ -z "$metadata_graph" ] || [ "$metadata_graph" = "${graphFingerprint}" ] || return 1
      fi
      printf '%s\n' "$generation"
    }
  '';

  preservePhysicalLowerSnippet = ''
    mkdir -p ${physicalHostRoot}/nix/store
    if ! mountpoint -q ${physicalHostRoot}/nix/store; then
      mount --bind /nix/store ${physicalHostRoot}/nix/store
    fi
    mount -o remount,ro,bind ${physicalHostRoot}/nix/store
  '';

  legacyFrozenActivation = concatMapStrings (mount: ''
    if [ "''${ephemeral_layers[${mount.logicalId}]}" = 1 ]; then
      activate_frozen_state ${if mount.parent == null then lowerStateLink else frozenMountByPhysical.${mount.parent}.stateDir} ${mount.stateDir} ${runtimeBackup}/frozen/${mount.id}
    else
      selected_frozen=$(select_frozen_generation "${mount.id}" "${mount.logicalId}")
      activate_frozen_state "$selected_frozen/state" ${mount.stateDir} ${runtimeBackup}/frozen/${mount.id}
    fi
  '') frozenMounts;

  activateFrozenGenerationSnippets = ''
    if [ -f "$generation/plan.rows" ]; then
      while IFS='|' read -r physical_id logical_id role parent rest; do
        [ -n "$physical_id" ] || continue
        [ "$role" = frozen-lower ] || continue
        frozen_root="${runtimeState}/frozen/$physical_id"
        if [ "''${ephemeral_layers[$logical_id]}" = 1 ]; then
          if [ "$parent" = - ]; then
            frozen_source=${lowerStateLink}
          else
            frozen_source="${runtimeState}/frozen/$parent/nix/var/nix"
          fi
          activate_frozen_state "$frozen_source" "$frozen_root/nix/var/nix" "${runtimeBackup}/frozen/$physical_id"
        else
          selected_frozen="$generation/nodes/$physical_id"
          [ -d "$selected_frozen" ] || { echo "nixtache-overlay: selected frozen node is missing: $physical_id" >&2; exit 1; }
          activate_frozen_state "$selected_frozen/state" "$frozen_root/nix/var/nix" "${runtimeBackup}/frozen/$physical_id"
        fi
      done < "$generation/plan.rows"
    else
      :
      ${legacyFrozenActivation}
    fi
  '';

  activatePhysicalHostSnippet = ''
    ${preservePhysicalLowerSnippet}
    mkdir -p ${physicalHostRoot}/nix/var/nix
    activate_frozen_state ${lowerStateLink} ${physicalHostRoot}/nix/var/nix ${runtimeBackup}/physical-host
  '';

  activateParentLowerSnippets = concatMapStrings (node: ''
    parent_physical=${evalParent node}
    if [ -f "$generation/plan.rows" ]; then
      parent_physical=$(plan_consumer_parent ${node.id})
    fi
    if [ "$parent_physical" = - ]; then
      parent_root=${physicalHostRoot}
    else
      parent_root="${runtimeState}/frozen/$parent_physical"
    fi
    activate_lower_root "$parent_root" ${parentRoot node.id}
    ${optionalString (node ? containerName) ''
      activate_frozen_state "$parent_root/nix/var/nix" ${node.lowerRoot}/nix/var/nix ${runtimeBackup}/lower-roots/${node.id}
    ''}
  '') sortedTopology;

  resetFrozenSnippets = concatMapStrings (mount: ''
    reset_dir ${mount.upperDir}
    for name in ${concatStringsSep " " stateNames}; do reset_frozen_path "${mount.stateDir}/$name"; done
  '') frozenMounts + concatMapStrings (node: ''
    for name in ${concatStringsSep " " stateNames}; do reset_frozen_path "${node.lowerRoot}/nix/var/nix/$name"; done
  '') runnerLayers;

  activateEphemeralFrozenSnippets = concatMapStrings (mount: ''
    bind_frozen_state ${if mount.parent == null then lowerStateLink else frozenMountByPhysical.${mount.parent}.stateDir} ${mount.stateDir}
  '') frozenMounts;

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
      ${if (node.isSingleton or false) || (node ? containerName) then ''
        activate_state_dir "$consumer_generation" ${dirOf node.upperDir} ${legacyBackup}/layers/${node.id}/overlay
      '' else ''
        activate_path "$consumer_generation/upper" ${node.upperDir} ${legacyBackup}/layers/${node.id}/upper
        activate_path "$consumer_generation/work" ${node.workDir} ${legacyBackup}/layers/${node.id}/work
      ''}
      for name in ${concatStringsSep " " stateNames}; do
        activate_persistent_state_dir "$consumer_generation/state/$name" "${node.stateDir}/$name" "${legacyBackup}/layers/${node.id}/state/$name"
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

  lowerRootFunctionsSnippet = ''
    activate_lower_root() {
      local source=$1 destination=$2 name
      mkdir -p "$destination/nix/store" "$destination/nix/var/nix"
      if ! mountpoint -q "$destination/nix/store"; then
        mount --bind "$source/nix/store" "$destination/nix/store"
      fi
      mount -o remount,ro,bind "$destination/nix/store"
      for name in ${concatStringsSep " " stateNames}; do
        mkdir -p "$destination/nix/var/nix/$name"
        if ! mountpoint -q "$destination/nix/var/nix/$name"; then
          mount --bind "$source/nix/var/nix/$name" "$destination/nix/var/nix/$name"
        fi
        mount -o remount,ro,bind "$destination/nix/var/nix/$name"
      done
    }

    plan_consumer_parent() {
      local wanted=$1 physical_id logical_id role parent rest
      while IFS='|' read -r physical_id logical_id role parent rest; do
        if [ "$logical_id" = "$wanted" ] && [ "$role" = runtime ]; then
          printf '%s\n' "$parent"
          return 0
        fi
      done < "$generation/plan.rows"
      echo "nixtache-overlay: selected plan has no runtime row for $wanted" >&2
      return 1
    }
  '';

  parentRootActivationSnippet = ''
    activation_started=0
    activation_complete=0
    activation_log=${runtimeState}/parent-root-activation.log
    ${migration.rollbackActivationSnippet}
    trap rollback_activation EXIT
    ${migration.activatePathSnippet}
    ${migration.activateStateDirSnippet}
    activate_frozen_state() {
      local source=$1 target=$2 backup=$3 name
      for name in ${concatStringsSep " " stateNames}; do
        activate_state_dir "$source/$name" "$target/$name" "$backup/$name"
        mount -o remount,ro,bind "$target/$name"
      done
    }
    activation_started=1
    : > "$activation_log"
    ${lowerRootFunctionsSnippet}
    ${activateParentLowerSnippets}
    activation_complete=1
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
    generation=""
    ${migration.rollbackActivationSnippet}
    trap rollback_activation EXIT

    ${migration.resetDirSnippet}

    ${migration.activatePathSnippet}

    ${migration.activateStateDirSnippet}

    ${migration.activatePersistentStateDirSnippet}

    ${discoverySnippet}

    ${metadataValueSnippet}

    ${readyGenerationSnippet}

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
      ${activatePhysicalHostSnippet}
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
      ${optionalString abEnabled ''
        ${activatePhysicalHostSnippet}
      ''}
      touch ${runtimeState}/selected-chain-ready
      exit 0
    fi

    ${preservePhysicalLowerSnippet}
    slot=$(discover_booted)
    printf '%s\n' "$slot" > ${runtimeState}/selected-slot

    upper_fs=$(findmnt -T ${cfg.upperDir} -n -o FSTYPE 2>/dev/null || echo unknown)
    if [ "$upper_fs" = "tmpfs" ]; then
      reset_dir ${cfg.upperDir}
      reset_dir ${cfg.workDir}
      reset_dir ${lowerStateLink}
      for name in ${concatStringsSep " " stateNames}; do reset_dir "/nix/var/nix/$name"; done
      ${resetAllLayerSnippets}
      ${resetFrozenSnippets}
      ${activateEphemeralFrozenSnippets}
      ${activatePhysicalHostSnippet}
      touch ${runtimeState}/selected-chain-ready
      exit 0
    fi

    ${resetLayerSnippets}
    generation=$(ready_generation "$slot" || true)
    if [ -z "$generation" ]; then
      ${prepareScript} --booted
      generation=$(ready_generation "$slot")
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
  inherit discoverySnippet metadataValueSnippet readyGenerationSnippet parentRootActivationSnippet;
  script = selectionScript;
}
