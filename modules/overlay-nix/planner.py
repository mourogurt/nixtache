#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import sys

SCHEMA = "nixtache.overlay-topology/v1"
PLAN_SCHEMA = "nixtache.overlay-plan/v1"
ID_PATTERN = re.compile(r"[A-Za-z0-9._-]+\Z")


class PlanError(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def fingerprint(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        raise PlanError(f"target topology descriptor is missing: {path}")
    except (OSError, json.JSONDecodeError) as error:
        raise PlanError(f"cannot read topology descriptor {path}: {error}")


def require(condition, message):
    if not condition:
        raise PlanError(message)


def path_components(path):
    return [component for component in path.split("/") if component not in ("", ".")]


def paths_overlap(left, right):
    left_components = path_components(left)
    right_components = path_components(right)
    shared = min(len(left_components), len(right_components))
    return left_components[:shared] == right_components[:shared]


def validate_node(node, location):
    require(isinstance(node, dict), f"{location} must be an object")
    for field in ("id", "upperDir", "workDir", "stateDir", "lowerRoot"):
        require(isinstance(node.get(field), str), f"{location}.{field} must be a string")
    node_id = node["id"]
    require(ID_PATTERN.fullmatch(node_id) is not None and node_id not in (".", ".."),
            f"{location}.id is not a safe path component")
    require(node.get("parent") is None or isinstance(node.get("parent"), str),
            f"{location}.parent must be null or a string")
    for field in ("upperDir", "workDir", "stateDir"):
        value = node[field]
        require(value.startswith("/") and ".." not in value.split("/"),
                f"{location}.{field} must be absolute and cannot contain '..'")
    for field in ("upperDir", "workDir", "stateDir", "lowerRoot"):
        require(not any(character in node[field] for character in ("|", "\t", "\n", "\r")),
                f"{location}.{field} contains a reserved control character")
    if "containerName" in node:
        require(isinstance(node["containerName"], str), f"{location}.containerName must be a string")
    if "isSingleton" in node:
        require(isinstance(node["isSingleton"], bool), f"{location}.isSingleton must be a boolean")


def validate_logical(logical):
    require(isinstance(logical, dict), "logicalTopology must be an object")
    require(isinstance(logical.get("fingerprint"), str), "logicalTopology.fingerprint must be a string")
    require(isinstance(logical.get("order"), list), "logicalTopology.order must be an array")
    require(isinstance(logical.get("nodes"), list), "logicalTopology.nodes must be an array")
    require(all(isinstance(node_id, str) for node_id in logical["order"]),
            "logicalTopology.order entries must be strings")
    for index, node in enumerate(logical["nodes"]):
        validate_node(node, f"logicalTopology.nodes[{index}]")
    by_id = {node["id"]: node for node in logical["nodes"]}
    require(len(by_id) == len(logical["nodes"]), "duplicate logical node identity")
    require(len(set(logical["order"])) == len(logical["order"]), "duplicate logical order entry")
    require(set(logical["order"]) == set(by_id), "logical order and nodes describe different graphs")
    require("host" in by_id and by_id["host"].get("parent") is None,
            "the logical graph must have one host root")
    require(logical["order"] and logical["order"][0] == "host", "host must be first in logical order")
    seen = set()
    for node_id in logical["order"]:
        node = by_id[node_id]
        parent = node.get("parent")
        if node_id != "host":
            require(parent is None or parent in by_id, f"logical node {node_id} has a missing parent")
            effective_parent = "host" if parent is None else parent
            require(effective_parent in seen, f"logical node {node_id} is not parent-first or is cyclic")
        seen.add(node_id)
    expected_fingerprint = fingerprint([
        {"id": node_id, "parent": by_id[node_id].get("parent")}
        for node_id in logical["order"]
    ])
    require(logical["fingerprint"] == expected_fingerprint,
            "logicalTopology.fingerprint does not match its ordered logical nodes")
    entries = [
        (f"{node['id']}.{field}", node[field])
        for node in logical["nodes"]
        for field in ("upperDir", "workDir", "stateDir")
    ]
    for index, (left_owner, left_path) in enumerate(entries):
        for right_owner, right_path in entries[index + 1:]:
            if left_owner != right_owner:
                require(not paths_overlap(left_path, right_path),
                        f"managed paths collide: {left_owner} and {right_owner}")
    return by_id


def load_descriptor(path, expected=None):
    descriptor = read_json(path)
    require(isinstance(descriptor, dict), f"descriptor {path} must contain an object")
    require(descriptor.get("schema") == SCHEMA, f"descriptor {path} has an unsupported schema")
    for field in ("imageId", "imageVersion", "lowerDbSha256"):
        require(isinstance(descriptor.get(field), str), f"descriptor {path}.{field} must be a string")
    require(re.fullmatch(r"[0-9a-f]{64}", descriptor["lowerDbSha256"]) is not None,
            f"descriptor {path}.lowerDbSha256 is malformed")
    if expected is not None:
        require(descriptor["imageId"] == expected["image_id"],
                f"descriptor {path} has the wrong image identity")
        require(descriptor["imageVersion"] == expected["image_version"],
                f"descriptor {path} has the wrong image version")
        require(descriptor["lowerDbSha256"] == expected["lower_sha256"],
                f"descriptor {path} does not match the target lower dump")
    by_id = validate_logical(descriptor.get("logicalTopology"))
    logical = descriptor["logicalTopology"]
    ordered_nodes = [by_id[node_id] for node_id in logical["order"]]
    return descriptor, ordered_nodes


def children_of(logical_nodes, parent):
    return [
        node for node in logical_nodes
        if node["id"] != "host" and ("host" if node.get("parent") is None else node["parent"]) == parent
    ]


def derive(logical_nodes, previous_physical=None):
    previous_physical = previous_physical or []
    logical_by_id = {node["id"]: node for node in logical_nodes}
    logical_ids = [node["id"] for node in logical_nodes]
    require("host" in logical_by_id, "logical graph has no host")

    def visit(parent, path):
        require(parent not in path, "overlay topology cycle: " + " -> ".join(path + [parent]))
        return [parent] + [
            descendant
            for node in children_of(logical_nodes, parent)
            for descendant in visit(node["id"], path + [parent])
        ]

    ordered_ids = visit("host", [])
    require(len(ordered_ids) == len(logical_nodes), "logical graph is not reachable from host")
    sorted_logical = [logical_by_id[node_id] for node_id in ordered_ids]
    previous_split_ids = [
        node["logicalId"] for node in previous_physical
        if node.get("role") == "frozen-lower" and isinstance(node.get("logicalId"), str)
    ]
    parent_ids = [node["id"] for node in logical_nodes if children_of(logical_nodes, node["id"])]
    split_ids = []
    for node_id in parent_ids + previous_split_ids:
        if node_id in logical_ids and node_id not in split_ids:
            split_ids.append(node_id)

    def is_split(node_id):
        return node_id in split_ids

    def physical_parent(node):
        if node["id"] == "host":
            return None
        parent = "host" if node.get("parent") is None else node["parent"]
        return f"{parent}-lower" if is_split(parent) else parent

    def runtime_node(node, node_id, parent):
        result = {
            "id": node_id,
            "parent": parent,
            "logicalId": node["id"],
            "role": "runtime",
            "upperDir": node["upperDir"],
            "workDir": node["workDir"],
            "stateDir": node["stateDir"],
            "lowerRoot": node["lowerRoot"],
        }
        if is_split(node["id"]) and node_id == f"{node['id']}-runtime":
            result["rebasedFrom"] = None
        return result

    physical_nodes = []
    for node in sorted_logical:
        if is_split(node["id"]):
            physical_nodes.append({
                "id": f"{node['id']}-lower",
                "logicalId": node["id"],
                "role": "frozen-lower",
                "parent": physical_parent(node),
                "upperDir": None,
                "workDir": None,
                "stateDir": None,
                "lowerRoot": None,
                "viewFingerprint": None,
            })
            physical_nodes.append(runtime_node(node, f"{node['id']}-runtime", f"{node['id']}-lower"))
        else:
            physical_nodes.append(runtime_node(node, node["id"], physical_parent(node)))
    seen_physical_ids = set()
    duplicate_physical_ids = set()
    for node in physical_nodes:
        if node["id"] in seen_physical_ids:
            duplicate_physical_ids.add(node["id"])
        seen_physical_ids.add(node["id"])
    require(not duplicate_physical_ids,
            "derived physical node identities must be unique; collisions: "
            + ", ".join(sorted(map(str, duplicate_physical_ids))))
    physical_by_id = {node["id"]: node for node in physical_nodes}
    consumer = {
        node["id"]: f"{node['id']}-runtime" if is_split(node["id"]) else node["id"]
        for node in sorted_logical
    }
    frozen = {node_id: f"{node_id}-lower" for node_id in split_ids}

    def lineage(node_id):
        node = physical_by_id[node_id]
        return {
            "logicalId": node["logicalId"],
            "role": node["role"],
            "parent": lineage(node["parent"]) if node["parent"] is not None else None,
            "storage": {
                "upperDir": node["upperDir"],
                "workDir": node["workDir"],
                "stateDir": node["stateDir"],
            } if node["role"] == "runtime" else None,
            "viewFingerprint": node.get("viewFingerprint"),
            "rebasedFrom": node.get("rebasedFrom"),
        }

    lineage_by_physical = {node_id: lineage(node_id) for node_id in physical_by_id}
    graph_fingerprint = fingerprint({
        "logical": [
            {
                "id": node["id"],
                "parent": node.get("parent"),
                "upperDir": node["upperDir"],
                "workDir": node["workDir"],
                "stateDir": node["stateDir"],
            }
            for node in sorted_logical
        ],
        "physical": lineage_by_physical,
    })
    return {
        "nodes": sorted_logical,
        "byId": logical_by_id,
        "order": [node["id"] for node in sorted_logical],
        "physical": {
            "nodes": physical_nodes,
            "byId": physical_by_id,
            "order": [node["id"] for node in physical_nodes],
        },
        "consumerNodeByLogical": consumer,
        "frozenLowerByLogical": frozen,
        "lineageByPhysical": lineage_by_physical,
        "generationFingerprint": graph_fingerprint,
    }


def metadata_value(path, key):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith(key + "="):
                    return line.rstrip("\n").split("=", 1)[1]
    except FileNotFoundError:
        pass
    return None


def legacy_source(source_root, target_nodes):
    metadata = os.path.join(source_root, "metadata")
    topology = metadata_value(metadata, "topology")
    require(topology is not None and topology != "",
            "legacy source has no explicit logical topology; refusing to assume the target graph")
    source_ids = topology.split(",")
    require(len(set(source_ids)) == len(source_ids) and "host" in source_ids,
            "legacy source topology metadata is inconsistent")
    target_by_id = {node["id"]: node for node in target_nodes}
    common = [target_by_id[node_id] for node_id in source_ids if node_id in target_by_id]
    common_by_id = {node["id"]: node for node in common}
    ordered_common = [node for node in target_nodes if node["id"] in common_by_id]
    removed = [
        {
            "id": node_id,
            "parent": None,
            "upperDir": "",
            "workDir": "",
            "stateDir": "",
            "lowerRoot": "",
        }
        for node_id in source_ids if node_id not in target_by_id
    ]
    return ordered_common + removed, ordered_common


def load_source_plan(path):
    if path is None or not os.path.isfile(path):
        return None
    plan = read_json(path)
    require(isinstance(plan, dict) and plan.get("schema") == PLAN_SCHEMA,
            f"source physical plan is inconsistent: {path}")
    require(isinstance(plan.get("physical"), dict)
            and isinstance(plan["physical"].get("nodes"), list)
            and isinstance(plan.get("consumerNodeByLogical"), dict)
            and isinstance(plan.get("logicalTopology"), dict),
            f"source physical plan has no coherent physical graph: {path}")
    return plan


def source_from_arguments(args, target_nodes):
    if args.initial:
        return [], [], {}, {}, "initial"
    source_root = args.source_root
    source_descriptor_path = args.source_descriptor
    source_plan_path = args.source_plan
    if source_root is not None:
        candidate = os.path.join(source_root, "overlay-topology.json")
        if source_descriptor_path is None and os.path.isfile(candidate):
            source_descriptor_path = candidate
        if source_plan_path is None:
            source_plan_path = os.path.join(source_root, "plan.json")
    require(source_descriptor_path is not None or source_root is not None,
            "a source descriptor or source generation is required")
    if source_descriptor_path is not None:
        source_descriptor, source_logical = load_descriptor(source_descriptor_path)
        require(source_descriptor["imageId"] == read_json(args.target_descriptor)["imageId"],
                "source and target descriptors have different image identities")
        derivable_logical = source_logical
        compatibility = "descriptor"
    else:
        require(args.allow_legacy_source,
                "source descriptor is missing; use the explicit legacy compatibility adapter")
        source_logical, derivable_logical = legacy_source(source_root, target_nodes)
        compatibility = "legacy"
    source_plan = load_source_plan(source_plan_path) if source_descriptor_path is not None else None
    if source_plan is not None:
        require(source_plan["logicalTopology"] == source_descriptor["logicalTopology"],
                "source physical plan does not match the source logical descriptor")
        for field in ("imageId", "imageVersion", "lowerDbSha256"):
            require(source_plan.get(field) == source_descriptor[field],
                    f"source physical plan has a different {field}")
        expected_source = derive(derivable_logical, source_plan["physical"]["nodes"])
        for field in ("physical", "consumerNodeByLogical", "frozenLowerByLogical",
                      "lineageByPhysical", "generationFingerprint"):
            require(source_plan.get(field) == expected_source[field],
                    f"source physical plan is inconsistent at {field}")
    previous_splits = []
    if source_root is not None and source_plan is None:
        nodes_dir = os.path.join(source_root, "nodes")
        if os.path.isdir(nodes_dir):
            for logical_id in {node["id"] for node in derivable_logical}:
                if os.path.isdir(os.path.join(nodes_dir, logical_id + "-lower")):
                    previous_splits.append({"logicalId": logical_id, "role": "frozen-lower"})
    if source_plan is None:
        derived_source = derive(derivable_logical, previous_splits)
        source_physical = derived_source["physical"]["nodes"]
        if source_root is not None:
            source_physical = [
                node for node in source_physical
                if node.get("role") != "frozen-lower"
                or os.path.isdir(os.path.join(source_root, "nodes", node["id"]))
            ]
        source_consumer = derived_source["consumerNodeByLogical"]
    else:
        derived_source = expected_source
        source_physical = source_plan["physical"]["nodes"]
        source_consumer = source_plan["consumerNodeByLogical"]
    return source_logical, source_physical, source_consumer, derived_source, compatibility


def transition(source_logical, previous_physical, target_logical, policy):
    derived = derive(target_logical, previous_physical)
    source_by_id = {node["id"]: node for node in source_logical}
    target_by_id = {node["id"]: node for node in target_logical}
    all_ids = list(dict.fromkeys([node["id"] for node in source_logical] + [node["id"] for node in target_logical]))
    operations = {}
    for node_id in all_ids:
        if node_id not in target_by_id:
            operation = "remove"
        elif node_id not in source_by_id:
            operation = "add"
        elif (source_by_id[node_id]["upperDir"] != target_by_id[node_id]["upperDir"]
              or source_by_id[node_id]["stateDir"] != target_by_id[node_id]["stateDir"]):
            operation = "storage-reset"
        elif source_by_id[node_id].get("parent") != target_by_id[node_id].get("parent"):
            operation = "reparent"
        elif (f"{node_id}-lower" not in {node["id"] for node in previous_physical}
              and f"{node_id}-lower" in derived["physical"]["byId"]):
            operation = "promote"
        elif (source_by_id[node_id]["workDir"] != target_by_id[node_id]["workDir"]
              or source_by_id[node_id].get("lowerRoot") != target_by_id[node_id].get("lowerRoot")
              or source_by_id[node_id].get("containerName") != target_by_id[node_id].get("containerName")):
            operation = "rewire"
        else:
            operation = "unchanged"
        operations[node_id] = operation
    dispositions = {}
    for node in derived["physical"]["nodes"]:
        if node["role"] == "frozen-lower":
            disposition = "freeze"
        elif policy == "wipe":
            disposition = "empty"
        elif operations[node["logicalId"]] in ("add", "storage-reset"):
            disposition = "empty"
        elif node["id"] == f"{node['logicalId']}-runtime":
            disposition = "empty-continuation"
        else:
            disposition = "clone-and-repair"
        dispositions[node["id"]] = disposition
    result = dict(derived)
    result["operations"] = operations
    result["dispositions"] = dispositions
    return result


def write_text(path, content):
    if path:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)


def make_plan(args):
    target_descriptor, target_logical = load_descriptor(
        args.target_descriptor,
        {
            "image_id": args.image_id,
            "image_version": args.image_version,
            "lower_sha256": args.lower_sha256,
        },
    )
    source_logical, source_physical, source_consumer, source_derived, compatibility = source_from_arguments(
        args, target_logical
    )
    result = transition(source_logical, source_physical, target_logical, args.policy)
    result.update({
        "schema": PLAN_SCHEMA,
        "imageId": target_descriptor["imageId"],
        "imageVersion": target_descriptor["imageVersion"],
        "lowerDbSha256": target_descriptor["lowerDbSha256"],
        "logicalTopology": target_descriptor["logicalTopology"],
        "policy": args.policy,
        "sourceCompatibility": compatibility,
        "sourcePhysical": source_physical,
        "sourceConsumerNodeByLogical": source_consumer,
        "sourceDerived": source_derived,
    })
    write_text(args.output_json, canonical(result) + "\n")
    logical_by_id = {node["id"]: node for node in target_logical}
    source_frozen = {
        node["logicalId"]: node["id"]
        for node in source_physical
        if node.get("role") == "frozen-lower"
    }
    rows = []
    for node in result["physical"]["nodes"]:
        logical = logical_by_id[node["logicalId"]]
        values = [
            node["id"],
            node["logicalId"],
            node["role"],
            node["parent"],
            result["operations"][node["logicalId"]],
            result["dispositions"][node["id"]],
            source_consumer.get(node["logicalId"]),
            source_frozen.get(node["logicalId"]),
            logical["upperDir"],
            logical["stateDir"],
            "1" if logical.get("isSingleton", False) else "0",
        ]
        rows.append("|".join("-" if value is None else value for value in values) + "\n")
    write_text(args.output_rows, "".join(rows))
    metadata = {
        "image_id": target_descriptor["imageId"],
        "image_version": target_descriptor["imageVersion"],
        "lower_sha256": target_descriptor["lowerDbSha256"],
        "policy": args.policy,
        "topology": ",".join(result["order"]),
        "topology_sha256": target_descriptor["logicalTopology"]["fingerprint"],
        "graph_sha256": result["generationFingerprint"],
        "source_compatibility": compatibility,
    }
    write_text(args.output_metadata, "".join(f"{key}={value}\n" for key, value in metadata.items()))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("descriptor")
    validate.add_argument("image_version")
    validate.add_argument("lower_sha256")
    validate.add_argument("--image-id", required=True)
    plan = subparsers.add_parser("plan")
    plan.add_argument("--target-descriptor", required=True)
    plan.add_argument("--image-id", required=True)
    plan.add_argument("--image-version", required=True)
    plan.add_argument("--lower-sha256", required=True)
    plan.add_argument("--policy", choices=("reconcile", "wipe"), required=True)
    plan.add_argument("--source-root")
    plan.add_argument("--source-descriptor")
    plan.add_argument("--source-plan")
    plan.add_argument("--allow-legacy-source", action="store_true")
    plan.add_argument("--initial", action="store_true")
    plan.add_argument("--output-json", required=True)
    plan.add_argument("--output-rows", required=True)
    plan.add_argument("--output-metadata", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            load_descriptor(args.descriptor, {
                "image_id": args.image_id,
                "image_version": args.image_version,
                "lower_sha256": args.lower_sha256,
            })
        else:
            make_plan(args)
    except PlanError as error:
        print(f"nixtache-overlay: {error}", file=sys.stderr)
        return 1
    except (KeyError, TypeError, ValueError) as error:
        print(f"nixtache-overlay: inconsistent topology plan: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
