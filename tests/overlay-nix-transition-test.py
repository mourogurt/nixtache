#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PLANNER = os.environ["OVERLAY_PLANNER"]
MATERIALIZER = os.environ["OVERLAY_MATERIALIZER"]
NIX_STORE = os.environ["OVERLAY_NIX_STORE"]
BUNDLE = Path(os.environ["OVERLAY_ORACLE_BUNDLE"])
SCHEMA = "nixtache.overlay-topology/v1"
PLAN_SCHEMA = "nixtache.overlay-plan/v1"


def run(arguments, expected=True):
    result = subprocess.run(arguments, text=True, capture_output=True)
    if expected and result.returncode != 0:
        raise AssertionError(
            f"command failed: {arguments}\nstdout: {result.stdout}\nstderr: {result.stderr}"
        )
    if not expected and result.returncode == 0:
        raise AssertionError(f"command unexpectedly succeeded: {arguments}")
    return result


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def plan(source_root, target_descriptor, work, policy="reconcile", legacy=False):
    work.mkdir(parents=True, exist_ok=True)
    arguments = [
        PLANNER,
        "plan",
        "--target-descriptor", str(target_descriptor),
        "--image-id", "nixtache",
        "--image-version", "2",
        "--lower-sha256", "b" * 64,
        "--policy", policy,
        "--source-root", str(source_root),
        "--output-json", str(work / "plan.json"),
        "--output-rows", str(work / "plan.rows"),
        "--output-metadata", str(work / "plan.metadata"),
    ]
    if legacy:
        arguments.append("--allow-legacy-source")
    run(arguments)
    return json.loads((work / "plan.json").read_text())


def source_descriptor(case):
    return {
        "schema": SCHEMA,
        "imageId": "nixtache",
        "imageVersion": "1",
        "lowerDbSha256": "a" * 64,
        "logicalTopology": case["source"],
    }


def target_descriptor(case):
    return {
        "schema": SCHEMA,
        "imageId": "nixtache",
        "imageVersion": "2",
        "lowerDbSha256": "b" * 64,
        "logicalTopology": case["target"],
    }


def consumer_path(root, logical_id, physical_id):
    if logical_id == "host" and physical_id in ("host", "host-runtime"):
        return root / "host"
    return root / "nodes" / physical_id


def marker_upper(directory, name):
    upper = directory / "upper"
    upper.mkdir(parents=True, exist_ok=True)
    (upper / name).write_text(name + "\n")


def marker_state(directory, name):
    for state_name in ("db", "gcroots", "profiles", "temproots"):
        (directory / "state" / state_name).mkdir(parents=True, exist_ok=True)
    (directory / "state" / "gcroots" / name).write_text(name + "\n")


def create_source(source_root, case, compatibility_aliases=True):
    source_root.mkdir(parents=True)
    descriptor = source_descriptor(case)
    write_json(source_root / "overlay-topology.json", descriptor)
    write_json(source_root / "plan.json", dict(case["sourceExpected"], **{
        "schema": PLAN_SCHEMA,
        "imageId": "nixtache",
        "imageVersion": "1",
        "lowerDbSha256": "a" * 64,
        "logicalTopology": case["source"],
    }))
    order = ",".join(case["source"]["order"])
    (source_root / "metadata").write_text(
        f"state=ready\ntopology={order}\ntopology_sha256={case['source']['fingerprint']}\n"
    )
    for node in case["sourcePhysical"]:
        directory = consumer_path(source_root, node["logicalId"], node["id"])
        (directory / "work").mkdir(parents=True, exist_ok=True)
        for state_name in ("db", "gcroots", "profiles", "temproots"):
            (directory / "state" / state_name).mkdir(parents=True, exist_ok=True)
        if node["role"] == "frozen-lower":
            marker_upper(directory, f"frozen-{node['logicalId']}")
            marker_state(directory, f"frozen-root-{node['logicalId']}")
    for logical_id, physical_id in case["sourceConsumer"].items():
        directory = consumer_path(source_root, logical_id, physical_id)
        marker_upper(directory, f"consumer-{logical_id}")
        marker_state(directory, f"consumer-root-{logical_id}")
        if compatibility_aliases and logical_id != "host":
            alias = source_root / "layers" / f"{logical_id}"
            alias.parent.mkdir(parents=True, exist_ok=True)
            alias.symlink_to(Path("..") / "nodes" / physical_id)
    return source_root


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        digest.update(relative.encode())
        if path.is_symlink():
            digest.update(b"link")
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            digest.update(b"file")
            digest.update(path.read_bytes())
        elif path.is_dir():
            digest.update(b"dir")
    return digest.hexdigest()


def assert_marker(directory, name, expected):
    upper_marker = directory / "upper" / name
    state_marker = directory / "state" / "gcroots" / name.replace("consumer-", "consumer-root-").replace("frozen-", "frozen-root-")
    assert upper_marker.exists() == expected, f"upper marker {upper_marker}: expected={expected}"
    if name.startswith("consumer-") or name.startswith("frozen-"):
        assert state_marker.exists() == expected, f"state marker {state_marker}: expected={expected}"


def assert_runtime_layout(stage, result):
    for logical_id, physical_id in result["consumerNodeByLogical"].items():
        if logical_id == "host":
            assert (stage / "nodes" / physical_id).is_symlink()
            assert (stage / "nodes" / physical_id).resolve() == (stage / "host").resolve()
        else:
            alias = stage / "layers" / logical_id
            assert alias.is_symlink(), f"missing consumer alias {alias}"
            assert alias.resolve() == (stage / "nodes" / physical_id).resolve()
    physical_ids = {node["id"] for node in result["physical"]["nodes"]}
    for node in result["physical"]["nodes"]:
        logical_id = node["logicalId"]
        if node["parent"] is not None:
            assert node["parent"] in physical_ids
        if node["logicalId"] != "host":
            logical = result["byId"][node["logicalId"]]
            if node["role"] == "frozen-lower":
                continue
            if node["id"] == f"{logical_id}-runtime":
                expected_parent = f"{logical_id}-lower"
            else:
                parent = "host" if logical["parent"] is None else logical["parent"]
                expected_parent = result["frozenLowerByLogical"].get(parent, parent)
            assert node["parent"] == expected_parent, (
                f"consumer {node['id']} does not consume its frozen parent: "
                f"{node['parent']} != {expected_parent}"
            )


def assert_materialized(stage, source_root, case, result, policy):
    assert_runtime_layout(stage, result)
    source_frozen = {
        node["logicalId"]: node["id"]
        for node in case["sourcePhysical"]
        if node["role"] == "frozen-lower"
    }
    for node in result["physical"]["nodes"]:
        logical_id = node["logicalId"]
        directory = consumer_path(stage, logical_id, node["id"])
        operation = result["operations"][logical_id]
        reset = policy == "wipe" or operation in ("add", "storage-reset")
        if node["role"] == "frozen-lower":
            assert_marker(directory, f"consumer-{logical_id}", not reset)
            assert_marker(directory, f"frozen-{logical_id}", not reset and logical_id in source_frozen)
        else:
            retained = result["dispositions"][node["id"]] == "clone-and-repair" and not reset
            assert_marker(directory, f"consumer-{logical_id}", retained)
            assert not (directory / "upper" / f"frozen-{logical_id}").exists()
    target_ids = {node["id"] for node in result["physical"]["nodes"]}
    for node in case["sourcePhysical"]:
        if node["id"] not in target_ids:
            assert not (stage / "nodes" / node["id"]).exists()
    for logical_id in case["sourceConsumer"]:
        if logical_id not in result["consumerNodeByLogical"] and logical_id != "host":
            assert not (stage / "layers" / logical_id).exists()


def register_store_path(work, directory, label):
    payload = work / f"{label}.input"
    payload.write_text(label + "\n")
    store_root = work / f"{label}-store-root"
    result = run([
        NIX_STORE,
        "--store", f"local?root={store_root}&state={directory}/state",
        "--add", str(payload),
    ])
    store_path = result.stdout.strip()
    shutil.copy(store_root / store_path.lstrip("/"), directory / "upper" / Path(store_path).name)
    return store_path


def execute_case(root, name, case):
    work = root / name
    work.mkdir()
    source_root = create_source(work / "source", case)
    merged_db_paths = []
    if name == "add-sibling":
        merged_db_paths = [
            register_store_path(work, source_root / "nodes" / "b-lower", "frozen-validity"),
            register_store_path(work, source_root / "nodes" / "b-runtime", "continuation-validity"),
        ]
    target = target_descriptor(case)
    target_path = work / "target.json"
    write_json(target_path, target)
    source_digest = tree_digest(source_root)
    result = plan(source_root, target_path, work, case["policy"])
    for key, expected in case["expected"].items():
        assert result[key] == expected, f"{name}: planner differs from physical.transition for {key}"
    stage = work / "stage"
    stage.mkdir()
    shutil.copy(work / "plan.rows", stage / "plan.rows")
    run([MATERIALIZER, str(stage / "plan.rows"), str(source_root), str(stage), case["policy"], "0"])
    assert_materialized(stage, source_root, case, result, case["policy"])
    if merged_db_paths:
        dump = run([
            NIX_STORE,
            "--option", "experimental-features", "read-only-local-store",
            "--store", f"local?root={work}/verify-store-root&state={stage}/nodes/b-lower/state&read-only=true",
            "--dump-db",
        ]).stdout
        for store_path in merged_db_paths:
            assert store_path in dump, f"frozen lower lost validity record {store_path}"
    assert tree_digest(source_root) == source_digest, f"{name}: active source changed during materialization"
    if case["policy"] == "wipe":
        for node in result["physical"]["nodes"]:
            directory = consumer_path(stage, node["logicalId"], node["id"])
            assert not any((directory / "upper").iterdir()), f"wipe retained upper content in {node['id']}"
            roots = directory / "state" / "gcroots"
            assert not roots.exists() or not any(roots.iterdir()), f"wipe retained roots in {node['id']}"
    print(f"ok {name}: oracle, physical layout, state disposition and active-source isolation")


def execute_legacy(root, case):
    work = root / "legacy"
    work.mkdir()
    source_root = create_source(work / "source", case, compatibility_aliases=False)
    (source_root / "overlay-topology.json").unlink()
    (source_root / "plan.json").unlink()
    shutil.rmtree(source_root / "nodes")
    for logical_id, physical_id in case["sourceConsumer"].items():
        if logical_id == "host":
            continue
        legacy = source_root / "layers" / logical_id
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.mkdir(exist_ok=True)
        marker_upper(legacy, f"consumer-{logical_id}")
        marker_state(legacy, f"consumer-root-{logical_id}")
    metadata = source_root / "metadata"
    metadata.write_text(metadata.read_text().replace("topology=", "topology=legacy-removed,"))
    target_path = work / "target.json"
    write_json(target_path, target_descriptor(case))
    source_digest = tree_digest(source_root)
    result = plan(source_root, target_path, work, legacy=True)
    assert result["sourceCompatibility"] == "legacy"
    assert result["operations"]["legacy-removed"] == "remove"
    assert result["operations"]["c"] == "add"
    stage = work / "stage"
    stage.mkdir()
    shutil.copy(work / "plan.rows", stage / "plan.rows")
    run([MATERIALIZER, str(stage / "plan.rows"), str(source_root), str(stage), "reconcile", "0"])
    assert_runtime_layout(stage, result)
    assert (stage / "nodes" / "b-lower" / "upper" / "consumer-b").exists()
    assert (stage / "nodes" / "e" / "upper" / "consumer-e").exists()
    assert not (stage / "nodes" / "c" / "upper" / "consumer-c").exists()
    assert tree_digest(source_root) == source_digest
    print("ok legacy: explicit adapter preserves old consumer paths without assuming the target graph")


def logical(nodes):
    ordered = sorted(nodes, key=lambda node: (node["id"] != "host", node["id"]))
    by_id = {node["id"]: node for node in nodes}
    ordered = []
    def visit(parent):
        ordered.append(by_id[parent])
        for node in nodes:
            effective = "host" if node["parent"] is None else node["parent"]
            if node["id"] != "host" and effective == parent:
                visit(node["id"])
    visit("host")
    projection = [{"id": node["id"], "parent": node["parent"]} for node in ordered]
    fingerprint = hashlib.sha256(json.dumps(projection, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"fingerprint": fingerprint, "order": [node["id"] for node in ordered], "nodes": ordered}


def execute_singleton(root):
    work = root / "singleton"
    work.mkdir()
    base = Path("/var/lib/layers/runner")
    runner = {
        "id": "runner",
        "parent": None,
        "upperDir": str(base / "upper"),
        "workDir": str(base / "work"),
        "stateDir": str(base / "state"),
        "lowerRoot": "/run/nixtache-runner-lower",
        "containerName": "runner",
        "isSingleton": True,
    }
    host = {
        "id": "host",
        "parent": None,
        "upperDir": "/var/lib/nix-overlay/upper",
        "workDir": "/var/lib/nix-overlay/work",
        "stateDir": "/nix/var/nix",
        "lowerRoot": "",
    }
    graph = logical([host, runner])
    case = {
        "source": graph,
        "target": graph,
        "sourcePhysical": [],
        "sourceConsumer": {},
        "policy": "reconcile",
    }
    source_root = work / "source"
    source_root.mkdir()
    (source_root / "metadata").write_text(f"state=ready\ntopology=host,runner\ntopology_sha256={graph['fingerprint']}\n")
    for logical_id in ("host", "runner"):
        directory = source_root / ("host" if logical_id == "host" else "runner")
        marker_upper(directory, f"consumer-{logical_id}")
        marker_state(directory, f"consumer-root-{logical_id}")
    target_path = work / "target.json"
    write_json(target_path, target_descriptor(case))
    result = plan(source_root, target_path, work, legacy=True)
    stage = work / "stage"
    stage.mkdir()
    shutil.copy(work / "plan.rows", stage / "plan.rows")
    run([MATERIALIZER, str(stage / "plan.rows"), str(source_root), str(stage), "reconcile", "0"])
    assert (stage / "layers" / "runner" / "upper" / "consumer-runner").exists()
    assert (stage / "nodes" / "host-lower" / "upper" / "consumer-host").exists()
    print("ok singleton: legacy runner directory remains an explicit compatible source")


def execute_descriptor_failures(root, case):
    work = root / "descriptors"
    work.mkdir()
    source_root = create_source(work / "source", case)
    target = target_descriptor(case)
    different = work / "different.json"
    write_json(different, target)
    plan(source_root, different, work / "different")
    malformed = target.copy()
    malformed["logicalTopology"] = dict(target["logicalTopology"])
    malformed["logicalTopology"]["fingerprint"] = "0" * 64
    malformed_path = work / "malformed.json"
    write_json(malformed_path, malformed)
    result = run([
        PLANNER, "validate", "--image-id", "nixtache", str(malformed_path), "2", "b" * 64
    ], expected=False)
    assert "fingerprint" in result.stderr
    result = run([
        PLANNER, "validate", "--image-id", "nixtache", str(work / "missing.json"), "2", "b" * 64
    ], expected=False)
    assert "missing" in result.stderr
    print("ok descriptors: different target graphs pass and missing/inconsistent targets fail closed")


def main():
    bundle = json.loads(BUNDLE.read_text())
    with tempfile.TemporaryDirectory(prefix="overlay-transition-test-") as temporary:
        root = Path(temporary)
        for name, case in bundle["cases"].items():
            execute_case(root, name, case)
        execute_legacy(root, bundle["cases"]["add-first-child"])
        execute_singleton(root)
        execute_descriptor_failures(root, bundle["cases"]["add-first-child"])
    print("PASS: descriptor-driven physical transitions")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise
