import argparse
from pathlib import Path

from server.core.config import load_settings
from server.services.host_backup import create_backup, restore_backup, repair_host
from server.services.host_snapshot_settings import load_host_settings


def main():
    parser = argparse.ArgumentParser(description="Offline Windows host backup and verified restore")
    parser.add_argument("--data-dir", type=Path, help="Read the settings recorded by this host")
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("create").add_argument("destination", type=Path)
    restore = commands.add_parser("restore")
    restore.add_argument("source", type=Path)
    restore.add_argument("destination", type=Path)
    commands.add_parser("repair")
    args = parser.parse_args()
    settings = load_settings()
    if args.action != "restore" and args.data_dir:
        settings = load_host_settings(settings, args.data_dir)
    if args.action == "create":
        count = create_backup(settings, args.destination)
    elif args.action == "restore":
        count = restore_backup(args.source, args.destination)
    else:
        count = repair_host(settings)
    print(f"Verified files: {count}")


if __name__ == "__main__":
    main()
