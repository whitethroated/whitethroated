#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path


def load_summarizer():
    path = Path(__file__).with_name("summarize.py")
    spec = importlib.util.spec_from_file_location(
        "hudhud_benchmark_summarizer",
        path,
    )

    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load summarizer module")

    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> None:
    module = load_summarizer()

    sample = """============================================================
Hudhud prepared response
workers=4 threads=4 connections=128 duration=30s
============================================================

Running 30s test @ http://127.0.0.1:3000/prepared
  4 threads and 128 connections
  Latency   500.00us    100.00us   2.00ms   90.00%
  Req/Sec   100.00k     5.00k   110.00k    80.00%
  Latency Distribution
     50%  450.00us
     90%  700.00us
     99%    1.20ms
  12000000 requests in 30.00s, 1.80GB read
Requests/sec: 400000.00
Transfer/sec:     61.44MB
"""

    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        path = directory / "sample-1.txt"
        path.write_text(sample, encoding="utf-8")

        measurements = module.parse_sample(path)

        assert len(measurements) == 1

        measurement = measurements[0]

        assert measurement.case == "Hudhud prepared response"
        assert measurement.requests_per_second == 400000.0
        assert measurement.p50_us == 450.0
        assert measurement.p90_us == 700.0
        assert measurement.p99_us == 1200.0

        summary = module.summarize(measurements)

        assert len(summary) == 1
        assert (
            summary[0]["requests_per_second"]["median"]
            == 400000.0
        )

    print("benchmark summarizer tests passed")


if __name__ == "__main__":
    main()
