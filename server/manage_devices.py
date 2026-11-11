"""Host CLI. Issued plaintext tokens are printed once for transfer to the device."""
import argparse
import json
from pathlib import Path

from server.core.config import load_settings
from server.services.device_tokens import DeviceTokens


def main():
    parser = argparse.ArgumentParser(description="Manage device tokens on this host")
    parser.add_argument("--data-dir", type=Path, help="Use the same data directory as the running host")
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("issue").add_argument("name")
    commands.add_parser("list")
    commands.add_parser("revoke").add_argument("id")
    args = parser.parse_args()
    store = DeviceTokens((args.data_dir or load_settings().data_dir) / "device_tokens.sqlite")
    if args.action == "issue":
        identifier, token = store.issue(args.name)
        print(json.dumps({"id": identifier, "token": token}))
    elif args.action == "list":
        print(json.dumps(store.list(), ensure_ascii=False))
    elif not store.revoke(args.id):
        parser.error("Unknown device ID")


if __name__ == "__main__":
    main()
