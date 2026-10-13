#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import statistics
from dataclasses import asdict, dataclass
from pathlib import Path


SEPARATOR = "============================================================"
REQUESTS_PER_SECOND = re.compile(
    r"Requests/sec:\s+([0-9]+(?:\.[0-9]+)?)"
)
LATENCY_PERCENTILE = re.compile(
    r"^\s*(50|90|99)%\s+"
    r"([0-9]+(?:\.[0-9]+)?)(ns|us|ms|s)\s*$"
)


@dataclass(frozen=True)
class Measurement:
    sample: str
    case: str
    requests_per_second: float
    p50_us: float | None
    p90_us: float | None
    p99_us: float | None


def latency_to_microseconds(
    value: float,
    unit: str,
) -> float:
    if unit == "ns":
        return value / 1_000
    if unit == "us":
        return value
    if unit == "ms":
        return value * 1_000
    if unit == "s":
        return value * 1_000_000

    raise ValueError(f"Unsupported latency unit: {unit}")


def case_boundaries(lines: list[str]) -> list[tuple[int, str]]:
    boundaries: list[tuple[int, str]] = []

    for index, line in enumerate(lines):
        if line.strip() != SEPARATOR:
            continue

        if index + 2 >= len(lines):
            continue

        label = lines[index + 1].strip()
        metadata = lines[index + 2].strip()

        if not label:
            continue

        if not (
            metadata.startswith("route=")
            or metadata.startswith("threads=")
            or metadata.startswith("workers=")
        ):
            continue

        boundaries.append((index, label))

    return boundaries


def parse_section(
    sample_name: str,
    case_name: str,
    lines: list[str],
) -> Measurement | None:
    requests_per_second: float | None = None
    percentiles: dict[str, float] = {}

    for line in lines:
        requests_match = REQUESTS_PER_SECOND.search(line)

        if requests_match:
            requests_per_second = float(
                requests_match.group(1)
            )
            continue

        latency_match = LATENCY_PERCENTILE.match(line)

        if latency_match:
            percentile = latency_match.group(1)
            value = float(latency_match.group(2))
            unit = latency_match.group(3)

            percentiles[percentile] = latency_to_microseconds(
                value,
                unit,
            )

    if requests_per_second is None:
        return None

    return Measurement(
        sample=sample_name,
        case=case_name,
        requests_per_second=requests_per_second,
        p50_us=percentiles.get("50"),
        p90_us=percentiles.get("90"),
        p99_us=percentiles.get("99"),
    )


def parse_sample(path: Path) -> list[Measurement]:
    lines = path.read_text(
        encoding="utf-8",
        errors="replace",
    ).splitlines()
    boundaries = case_boundaries(lines)

    if not boundaries:
        measurement = parse_section(
            path.name,
            "Benchmark",
            lines,
        )
        return [measurement] if measurement else []

    measurements: list[Measurement] = []

    for index, (start, case_name) in enumerate(boundaries):
        end = (
            boundaries[index + 1][0]
            if index + 1 < len(boundaries)
            else len(lines)
        )

        measurement = parse_section(
            path.name,
            case_name,
            lines[start:end],
        )

        if measurement:
            measurements.append(measurement)

    return measurements


def optional_median(
    values: list[float | None],
) -> float | None:
    present = [
        value
        for value in values
        if value is not None
    ]

    if not present:
        return None

    return statistics.median(present)


def summarize(
    measurements: list[Measurement],
) -> list[dict[str, object]]:
    grouped: dict[str, list[Measurement]] = {}

    for measurement in measurements:
        grouped.setdefault(
            measurement.case,
            [],
        ).append(measurement)

    summary: list[dict[str, object]] = []

    for case_name, case_measurements in grouped.items():
        requests = [
            item.requests_per_second
            for item in case_measurements
        ]

        summary.append(
            {
                "case": case_name,
                "samples": len(case_measurements),
                "requests_per_second": {
                    "median": statistics.median(requests),
                    "min": min(requests),
                    "max": max(requests),
                },
                "latency_us": {
                    "p50_median": optional_median(
                        [item.p50_us for item in case_measurements]
                    ),
                    "p90_median": optional_median(
                        [item.p90_us for item in case_measurements]
                    ),
                    "p99_median": optional_median(
                        [item.p99_us for item in case_measurements]
                    ),
                },
            }
        )

    return summary


def format_rps(value: float) -> str:
    return f"{value:,.2f}"


def format_latency(value: float | None) -> str:
    if value is None:
        return "n/a"

    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f} s"

    if value >= 1_000:
        return f"{value / 1_000:.2f} ms"

    return f"{value:.2f} us"


def markdown(
    summary: list[dict[str, object]],
) -> str:
    lines = [
        "# Benchmark summary",
        "",
        "| Case | Samples | Median RPS | Min RPS | Max RPS | Median p50 | Median p90 | Median p99 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for item in summary:
        requests = item["requests_per_second"]
        latency = item["latency_us"]

        assert isinstance(requests, dict)
        assert isinstance(latency, dict)

        lines.append(
            "| "
            + " | ".join(
                [
                    str(item["case"]),
                    str(item["samples"]),
                    format_rps(float(requests["median"])),
                    format_rps(float(requests["min"])),
                    format_rps(float(requests["max"])),
                    format_latency(latency["p50_median"]),
                    format_latency(latency["p90_median"]),
                    format_latency(latency["p99_median"]),
                ]
            )
            + " |"
        )

    lines.append("")
    lines.append(
        "Summary values are medians across the raw wrk samples. "
        "Keep the raw sample files when publishing results."
    )
    lines.append("")

    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Summarize Hudhud wrk benchmark sample files."
        )
    )
    parser.add_argument(
        "directory",
        type=Path,
        help="Benchmark result directory containing sample-*.txt",
    )
    arguments = parser.parse_args()

    directory: Path = arguments.directory
    sample_files = sorted(
        directory.glob("sample-*.txt")
    )

    if not sample_files:
        raise SystemExit(
            f"No sample-*.txt files found in {directory}"
        )

    measurements = [
        measurement
        for path in sample_files
        for measurement in parse_sample(path)
    ]

    if not measurements:
        raise SystemExit(
            "No wrk measurements could be parsed."
        )

    summary = summarize(measurements)

    json_payload = {
        "measurements": [
            asdict(measurement)
            for measurement in measurements
        ],
        "summary": summary,
    }

    (directory / "summary.json").write_text(
        json.dumps(
            json_payload,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    markdown_output = markdown(summary)

    (directory / "summary.md").write_text(
        markdown_output,
        encoding="utf-8",
    )

    print(markdown_output)


if __name__ == "__main__":
    main()
