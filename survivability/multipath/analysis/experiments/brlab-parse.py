import json, sys
label, mode = sys.argv[1], sys.argv[2]
try:
    j = json.load(sys.stdin); e = j["end"]
    r = e["sum_received"]["bits_per_second"] / 1e6
    rt = e["sum_sent"].get("retransmits", 0)
    print(f"{label:<44} {mode} {r:6.1f} Mbit/s  inner retrans {rt}")
except Exception as ex:
    print(f"{label:<44} {mode}  FAILED ({ex})")
