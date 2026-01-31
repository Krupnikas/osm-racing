#!/usr/bin/env python3
"""
Анализирует лог performance теста и извлекает статистику draw calls
Использование: python3 tools/analyze_draw_calls.py test_feature_analysis.log
"""

import sys
import re
from collections import defaultdict

def parse_draw_call_breakdown(log_file):
    """Извлекает breakdown draw calls из лога"""

    breakdowns = []
    current_breakdown = {}

    with open(log_file, 'r') as f:
        in_breakdown = False
        for line in f:
            # Detect start of breakdown
            if '📊 DRAW CALL BREAKDOWN:' in line:
                in_breakdown = True
                current_breakdown = {}
                continue

            # Detect end of breakdown
            if in_breakdown and ('💡 RECOMMENDATIONS' in line or '🚗 Traffic:' in line):
                if current_breakdown:
                    breakdowns.append(current_breakdown.copy())
                in_breakdown = False
                current_breakdown = {}
                continue

            # Parse breakdown lines
            if in_breakdown:
                # Format: "  Lamps       :   729 ( 34.3%) ██████"
                match = re.match(r'\s+(\w+)\s+:\s+(\d+)\s+\(\s*([\d.]+)%\)', line)
                if match:
                    category = match.group(1)
                    count = int(match.group(2))
                    percent = float(match.group(3))
                    current_breakdown[category] = {'count': count, 'percent': percent}

    return breakdowns

def parse_bottleneck_reports(log_file):
    """Извлекает bottleneck analysis reports"""

    reports = []

    with open(log_file, 'r') as f:
        in_report = False
        current_report = {'metrics': {}, 'bottlenecks': []}

        for line in f:
            if '========== Bottleneck Analysis Report ==========' in line:
                in_report = True
                current_report = {'metrics': {}, 'bottlenecks': []}
                continue

            if in_report and '=====' in line and line.count('=') > 20:
                if current_report['metrics']:
                    reports.append(current_report.copy())
                in_report = False
                continue

            if in_report:
                # Parse metrics
                if 'FPS:' in line:
                    match = re.search(r'FPS:\s+([\d.]+)\s+avg\s+\|\s+([\d.]+)\s+min', line)
                    if match:
                        current_report['metrics']['fps_avg'] = float(match.group(1))
                        current_report['metrics']['fps_min'] = float(match.group(2))

                if 'Frame Time:' in line:
                    match = re.search(r'Frame Time:\s+([\d.]+)\s+ms avg\s+\|\s+([\d.]+)\s+ms max', line)
                    if match:
                        current_report['metrics']['frame_time_avg'] = float(match.group(1))
                        current_report['metrics']['frame_time_max'] = float(match.group(2))

                if 'Draw Calls:' in line:
                    match = re.search(r'Draw Calls:\s+(\d+)\s+avg\s+\|\s+(\d+)\s+max', line)
                    if match:
                        current_report['metrics']['draw_calls_avg'] = int(match.group(1))
                        current_report['metrics']['draw_calls_max'] = int(match.group(2))

                if 'Vertices:' in line:
                    match = re.search(r'Vertices:\s+(\d+)\s+avg', line)
                    if match:
                        current_report['metrics']['vertices_avg'] = int(match.group(1))

                if 'Physics Bodies:' in line:
                    match = re.search(r'Physics Bodies:\s+(\d+)', line)
                    if match:
                        current_report['metrics']['physics_bodies'] = int(match.group(1))

                # Parse bottlenecks
                if '[CRITICAL]' in line or '[HIGH]' in line or '[MEDIUM]' in line:
                    match = re.search(r'\[(CRITICAL|HIGH|MEDIUM|LOW)\]\s+(.+)', line)
                    if match:
                        current_report['bottlenecks'].append({
                            'severity': match.group(1),
                            'name': match.group(2).strip()
                        })

    return reports

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 tools/analyze_draw_calls.py <log_file>")
        sys.exit(1)

    log_file = sys.argv[1]

    print("\n" + "="*60)
    print("DRAW CALL BREAKDOWN ANALYSIS")
    print("="*60)

    breakdowns = parse_draw_call_breakdown(log_file)

    if not breakdowns:
        print("❌ No draw call breakdowns found in log")
        sys.exit(1)

    # Average across all breakdowns
    totals = defaultdict(lambda: {'count': 0, 'percent': 0.0})
    for bd in breakdowns:
        for category, data in bd.items():
            totals[category]['count'] += data['count']
            totals[category]['percent'] += data['percent']

    num_breakdowns = len(breakdowns)
    for category in totals:
        totals[category]['count'] //= num_breakdowns
        totals[category]['percent'] /= num_breakdowns

    # Sort by count descending
    sorted_totals = sorted(totals.items(), key=lambda x: x[1]['count'], reverse=True)

    print(f"\n📊 Average Draw Call Distribution ({num_breakdowns} samples):\n")

    total_draw_calls = sum(data['count'] for _, data in sorted_totals)

    for category, data in sorted_totals:
        bar_length = int(data['percent'] / 5)  # 5% per bar
        bar = "█" * bar_length
        print(f"  {category:12} : {data['count']:5} ({data['percent']:5.1f}%) {bar}")

    print(f"\n  TOTAL        : {total_draw_calls:5} draw calls/frame")

    # Bottleneck analysis
    print("\n" + "="*60)
    print("BOTTLENECK REPORTS")
    print("="*60)

    reports = parse_bottleneck_reports(log_file)

    if reports:
        print(f"\nFound {len(reports)} bottleneck reports\n")

        # Average metrics
        avg_metrics = {}
        for report in reports:
            for key, value in report['metrics'].items():
                if key not in avg_metrics:
                    avg_metrics[key] = []
                avg_metrics[key].append(value)

        print("📈 Average Performance Metrics:\n")
        if 'fps_avg' in avg_metrics:
            print(f"  FPS           : {sum(avg_metrics['fps_avg'])/len(avg_metrics['fps_avg']):.1f} avg")
        if 'frame_time_avg' in avg_metrics:
            print(f"  Frame Time    : {sum(avg_metrics['frame_time_avg'])/len(avg_metrics['frame_time_avg']):.2f} ms avg")
        if 'draw_calls_avg' in avg_metrics:
            print(f"  Draw Calls    : {int(sum(avg_metrics['draw_calls_avg'])/len(avg_metrics['draw_calls_avg']))} avg")
        if 'vertices_avg' in avg_metrics:
            print(f"  Vertices      : {int(sum(avg_metrics['vertices_avg'])/len(avg_metrics['vertices_avg'])):,} avg")
        if 'physics_bodies' in avg_metrics:
            print(f"  Physics Bodies: {int(sum(avg_metrics['physics_bodies'])/len(avg_metrics['physics_bodies']))} avg")

        # Bottleneck frequency
        bottleneck_freq = defaultdict(int)
        severity_count = defaultdict(int)

        for report in reports:
            for bn in report['bottlenecks']:
                bottleneck_freq[bn['name']] += 1
                severity_count[bn['severity']] += 1

        if bottleneck_freq:
            print("\n🔴 Most Common Bottlenecks:\n")
            sorted_bns = sorted(bottleneck_freq.items(), key=lambda x: x[1], reverse=True)
            for name, count in sorted_bns[:10]:
                freq = 100.0 * count / len(reports)
                print(f"  {name:30} : {freq:5.1f}% of reports")

            print(f"\n⚠️  Severity Distribution:\n")
            for severity in ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']:
                if severity in severity_count:
                    print(f"  {severity:10} : {severity_count[severity]} occurrences")
    else:
        print("\n❌ No bottleneck reports found")

    # Recommendations
    print("\n" + "="*60)
    print("💡 OPTIMIZATION RECOMMENDATIONS (PRIORITIZED)")
    print("="*60 + "\n")

    if sorted_totals:
        top_3 = sorted_totals[:3]
        print("Top 3 draw call contributors:\n")
        for i, (category, data) in enumerate(top_3, 1):
            print(f"{i}. {category}: {data['count']} draw calls ({data['percent']:.1f}%)")

            # Category-specific recommendations
            if category == "Lamps":
                print("   → Use MultiMesh batching for street lamps")
                print("   → Consider LOD for distant lamps")
                print("   → Reduce lamp density on minor roads")
            elif category == "Vegetation":
                print("   → Batch trees by type using MultiMesh")
                print("   → Implement billboard LOD for distant trees")
                print("   → Reduce tree density based on distance")
            elif category == "Buildings":
                print("   → Use MultiMesh batching for simple buildings")
                print("   → Implement LOD system (simple box → detailed)")
                print("   → Lazy load distant buildings")
            elif category == "Roads":
                print("   → Reduce road smoothing subdivisions further")
                print("   → Batch road segments by material")
                print("   → Use single mesh per chunk")
            elif category == "Windows":
                print("   → Already using QuadMesh (optimized)")
                print("   → Consider disabling for distant buildings")
                print("   → Lazy load only for visible chunks")
            elif category == "Curbs":
                print("   → Use MultiMesh for curb segments")
                print("   → Simplify curb geometry (fewer subdivisions)")
                print("   → Consider disabling for minor roads")
            elif category == "Signs":
                print("   → Already simple geometry")
                print("   → Use MultiMesh for standard signs")
                print("   → Cull by distance")
            print()

if __name__ == '__main__':
    main()
