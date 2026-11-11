#!/usr/bin/env python3
"""Bulk-add ssh -L/-R/-D forwards to a tunnel in SSH Tunnel Manager's config.

    import-forwards.py "Tunnel name" [--host user@server] [--port 22] \
        -- -L 1389:10.0.0.1:6058 -L 127.0.0.1:6053:host:1389 ...

If a tunnel with that name exists, the forwards are appended to it (ones it
already has are skipped). Otherwise a new tunnel is created, which needs --host.
Quit the app first: it only reads the file at launch and rewrites it on save.
A backup is written next to the config as tunnels.json.bak.
"""
import argparse
import json
import os
import shutil
import sys
import uuid

CONFIG = os.path.expanduser("~/Library/Application Support/SSHTunnelManager/tunnels.json")


def new_id():
    return str(uuid.uuid4()).upper()


def parse_forwards(tokens):
    mappings, i = [], 0
    while i < len(tokens):
        flag = tokens[i]
        if flag not in ("-L", "-R", "-D") or i + 1 >= len(tokens):
            sys.exit(f"Unexpected argument: {flag!r} (expected -L/-R/-D followed by a spec)")
        parts = tokens[i + 1].split(":")
        i += 2
        try:
            if flag == "-D":  # [bind:]port
                bind, port = (["127.0.0.1"] + parts)[-2:]
                m = dict(forward="dynamic", localHost=bind, localPort=int(port),
                         remoteHost="127.0.0.1", remotePort=int(port))
            else:  # [bind:]port:host:hostport
                if len(parts) == 3:
                    parts = ["127.0.0.1"] + parts
                bind, port, host, hostport = parts
                if flag == "-L":
                    m = dict(forward="local", localHost=bind, localPort=int(port),
                             remoteHost=host, remotePort=int(hostport))
                else:  # -R: the server binds bind:port, forwards to host:hostport here
                    m = dict(forward="remote", localHost=host, localPort=int(hostport),
                             remoteHost=bind, remotePort=int(port))
        except ValueError:
            sys.exit(f"Can't parse forward: {flag} {':'.join(parts)}")
        mappings.append(m)
    return mappings


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("name", help="tunnel name (existing or new)")
    ap.add_argument("--host", help="user@server or SSH alias (required for a new tunnel)")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--config", default=CONFIG)
    # Everything after "--" is the forward list; argparse would otherwise try
    # to read -L/-D as its own options.
    argv = sys.argv[1:]
    split = argv.index("--") if "--" in argv else len(argv)
    args = ap.parse_args(argv[:split])

    tokens = argv[split + 1:]
    mappings = parse_forwards(tokens)
    if not mappings:
        sys.exit("No forwards given.")

    items = []
    if os.path.exists(args.config):
        with open(args.config, encoding="utf-8") as f:
            items = json.load(f)
        shutil.copy2(args.config, args.config + ".bak")
    # Legacy format: a bare list of tunnels rather than sidebar items.
    if items and "kind" not in items[0]:
        items = [{"kind": "tunnel", "tunnel": t} for t in items]

    tunnel = next((it["tunnel"] for it in items
                   if it.get("kind") == "tunnel" and it["tunnel"].get("name") == args.name), None)
    if tunnel is None:
        if not args.host:
            sys.exit(f'No tunnel named "{args.name}" — pass --host to create it.')
        tunnel = dict(id=new_id(), name=args.name, host=args.host, port=args.port,
                      portMappings=[], autoConnect=False, useAlias=False,
                      compression=False, disableTCPKeepAlive=False,
                      skipHostKeyCheck=False, usePassword=False)
        items.append({"kind": "tunnel", "tunnel": tunnel})
        print(f'Created tunnel "{args.name}" ({args.host})')

    key = lambda m: (m.get("forward", "local"), m["localHost"], m["localPort"], m["remoteHost"], m["remotePort"])
    existing = {key(m) for m in tunnel.get("portMappings", [])}
    used_ports = {m["localPort"] for m in tunnel.get("portMappings", []) if m.get("forward") != "remote"}
    added = 0
    for m in mappings:
        if key(m) in existing:
            continue
        if m["forward"] != "remote" and m["localPort"] in used_ports:
            print(f"  warning: local port {m['localPort']} appears more than once in this tunnel")
        existing.add(key(m))
        used_ports.add(m["localPort"])
        tunnel.setdefault("portMappings", []).append(dict(id=new_id(), **m))
        added += 1

    os.makedirs(os.path.dirname(args.config), exist_ok=True)
    with open(args.config, "w", encoding="utf-8") as f:
        json.dump(items, f, indent=2, sort_keys=True, ensure_ascii=False)
    print(f'Added {added} forward(s) to "{args.name}" ({len(mappings) - added} already present). '
          f'Total: {len(tunnel["portMappings"])}')


if __name__ == "__main__":
    main()
