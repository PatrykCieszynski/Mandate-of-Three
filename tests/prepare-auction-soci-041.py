"""Verify v0.4.1 in a separate P0 cache, preserving the S0 v0.4.0 pin."""
import importlib.util
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('s0_release_verifier',ROOT/'tests/prepare-auction-soci-s0.py')
verifier=importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
verifier.LOCK=json.loads((ROOT/'tests/fixtures/auction_soci_release_041.json').read_text(encoding='utf-8'))
verifier.CACHE=ROOT/'.godot/verification/soci-release-041'
if __name__=='__main__':verifier.main()
