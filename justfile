default:
    just --list

sync source="../ronna":
    python3 scripts/sync.py "{{source}}"
