"""Contract and synthetic checks for draft log alert queries."""

import json
import re
import subprocess
import unittest
from pathlib import Path

from test_live_fixtures import EVIDENCE, run_query


ROOT = Path(__file__).resolve().parents[2]
ALERT_QUERIES = ROOT / "queries" / "alerts"


def alert_query(name):
    return (ALERT_QUERIES / name).read_text(encoding="utf-8")


def replace_once(query, marker, replacement):
    if query.count(marker) != 1:
        raise AssertionError("The expected alert template marker must occur exactly once")
    return query.replace(marker, replacement, 1)


class AlertQueryContracts(unittest.TestCase):
    def test_alert_queries_use_literal_ago_arguments(self):
        paths = list(ALERT_QUERIES.glob("*.kql")) + [
            ROOT / "queries" / "services-expected-running.kql",
            ROOT / "queries" / "heartbeat-missing.kql",
        ]
        self.assertEqual(len(paths), 8)
        for path in paths:
            with self.subTest(query=path.name):
                arguments = re.findall(r"\bago\(([^)]+)\)", path.read_text(encoding="utf-8"))
                self.assertTrue(arguments)
                for argument in arguments:
                    self.assertRegex(argument.strip(), r"^\d+(?:\.\d+)?(?:s|m|h|d)$")

    def test_fixture_marker_must_occur_exactly_once(self):
        self.assertEqual(replace_once("before MARK after", "MARK", "value"), "before value after")
        for query in ("no marker", "MARK and MARK"):
            with self.subTest(query=query), self.assertRaisesRegex(AssertionError, "exactly once"):
                replace_once(query, "MARK", "value")


@unittest.skipUnless(EVIDENCE, "Set POC_WORKSPACE_EVIDENCE to a private workspace evidence JSON file")
class SyntheticAlertFixtures(unittest.TestCase):
    def test_generated_alert_queries_against_synthetic_data(self):
        result = subprocess.run(
            [
                "pwsh", "-NoLogo", "-NoProfile", "-File",
                str(ROOT / "tests" / "deployment" / "New-ArcAlertParameters.Tests.ps1"),
                "-EmitSyntheticQueries",
            ],
            check=True, capture_output=True, text=True,
        )
        generated = json.loads(result.stdout)
        server = '@"' + generated["Server1"].replace('"', '""') + '"'
        alerts = {item["name"]: item["query"] for item in generated["Alerts"]}
        self.assertEqual(len(alerts), 8)
        fixtures = {
            "test-cpu": f'''
let Perf = datatable(Minutes:long, _ResourceId:string, ObjectName:string, CounterName:string, InstanceName:string, CounterValue:real)
[1,{server},"Processor","% Processor Time","_Total",95.0,
 2,{server},"Processor","% Processor Time","_Total",95.0,
 3,{server},"Processor","% Processor Time","_Total",95.0]
| extend TimeGenerated = now() - Minutes * 1m;
''',
            "test-memory": f'''
let Perf = datatable(Minutes:long, _ResourceId:string, ObjectName:string, CounterName:string, CounterValue:real)
[1,{server},"Memory","Available MBytes",500.0,
 2,{server},"Memory","Available MBytes",500.0,
 3,{server},"Memory","Available MBytes",500.0]
| extend TimeGenerated = now() - Minutes * 1m;
''',
            "test-disk": f'''
let Perf = datatable(Minutes:long, _ResourceId:string, ObjectName:string, CounterName:string, InstanceName:string, CounterValue:real)
[1,{server},"LogicalDisk","% Free Space","C:",9.0,
 1,{server},"LogicalDisk","Free Megabytes","C:",4000.0]
| extend TimeGenerated = now() - Minutes * 1m;
''',
            "test-events": f'''
let Event = datatable(Minutes:long, _ResourceId:string, EventLog:string, EventLevel:int, Source:string, EventID:int)
[1,{server},"System",1,@"Quote""Provider ] | union Other",42]
| extend TimeGenerated = now() - Minutes * 1m;
''',
            "test-service": f'''
let ConfigurationData = datatable(Minutes:long, _ResourceId:string, Computer:string, SvcName:string, SvcState:string, SvcStartupType:string, ConfigDataType:string)
[30,{server},"synthetic","SyntheticService","Running","Automatic","WindowsServices"]
| extend TimeGenerated = now() - Minutes * 1m;
let ConfigurationChange = datatable(Minutes:long, _ResourceId:string, Computer:string, SvcName:string, SvcState:string, SvcStartupType:string, ConfigChangeType:string)
[10,{server},"synthetic","SyntheticService","Stopped","","WindowsServices"]
| extend TimeGenerated = now() - Minutes * 1m;
''',
            "test-software": f'''
let ConfigurationChange = datatable(Minutes:long, _ResourceId:string, ConfigChangeType:string, ChangeCategory:string, SoftwareName:string, Publisher:string)
[1,{server},"Software","Added","Unexpected App","Other"]
| extend TimeGenerated = now() - Minutes * 1m;
''',
            "test-configuration": rf'''
let ConfigurationChange = datatable(Minutes:long, _ResourceId:string, ConfigChangeType:string, Hive:string, RegistryKey:string, ValueName:string, FileSystemPath:string)
[1,{server},"Registry",@"HKEY_LOCAL_MACHINE",@"SOFTWARE\Demo","","",
 2,{server},"Files","","","",@"C:\Demo\Test.txt"]
| extend TimeGenerated = now() - Minutes * 1m;
''',
            "test-heartbeat": '''
let Heartbeat = datatable(_ResourceId:string, TimeGenerated:datetime)[];
''',
        }
        expected_states = {
            "test-cpu": "High CPU",
            "test-memory": "Low available memory",
            "test-disk": "Low disk space",
            "test-events": "Critical event observed",
            "test-service": "Not running",
            "test-software": "Unexpected software addition observed",
            "test-configuration": "Monitored configuration change observed",
            "test-heartbeat": "No heartbeat observed in available history during expected-online period",
        }
        self.assertEqual(set(alerts), set(fixtures))
        for name, query in alerts.items():
            with self.subTest(alert=name):
                rows = run_query(fixtures[name] + query)
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["ResourceId"], generated["Server1"].lower())
                self.assertEqual(rows[0]["MonitoringState"], expected_states[name])
                if name == "test-configuration":
                    self.assertEqual(rows[0]["ChangeCount"], 2)

    def test_kql_verbatim_strings_and_scientific_real_literals(self):
        query = r'''datatable(Value:string, Threshold:real)
[@"Quote""Provider\Path", 1E-20]
| project Value, Threshold'''
        rows = run_query(query)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["Value"], 'Quote"Provider\\Path')
        self.assertEqual(rows[0]["Threshold"], 1e-20)

    def test_empty_alert_scopes_return_no_guest_records(self):
        for path in sorted(ALERT_QUERIES.glob("*.kql")):
            with self.subTest(query=path.name):
                rows = run_query(path.read_text(encoding="utf-8"))
                self.assertEqual(len(rows), 0, "An empty alert scope must not return any rows")

    def test_cpu_thresholds_and_missing_samples(self):
        query = replace_once(
            alert_query("high-cpu.kql"),
            "datatable(ResourceId:string)[]",
            'datatable(ResourceId:string)["s1","s2","s3","s4","s5","s6","s7","s8","s9","s10"]',
        )
        fixture = """
let Perf = datatable(Minutes:long, _ResourceId:string, ObjectName:string, CounterName:string, InstanceName:string, CounterValue:real)
[
  1,"S1","Processor","% Processor Time","_Total",91.0,
  2,"s1","Processor","% Processor Time","_Total",95.0,
  3,"s1","Processor","% Processor Time","_Total",100.0,
  1,"s2","Processor","% Processor Time","_Total",90.0,
  2,"s2","Processor","% Processor Time","_Total",90.0,
  3,"s2","Processor","% Processor Time","_Total",90.0,
  1,"s4","Processor","% Processor Time","_Total",99.0,
  2,"s4","Processor","% Processor Time","_Total",99.0,
  16,"s5","Processor","% Processor Time","_Total",99.0,
  1,"s6","Processor","% Processor Time","_Total",-1.0,
  2,"s6","Processor","% Processor Time","_Total",101.0,
  3,"s6","Processor","% Processor Time","_Total",100.0,
  1,"s7","Processor","% Processor Time","_Total",99.0,
  1,"s7","Processor","% Processor Time","_Total",99.0,
  1,"s7","Processor","% Processor Time","_Total",99.0,
  1,"s8","Processor","% Processor Time","_Total",10.0,
  1,"s8","Processor","% Processor Time","_Total",100.0,
  2,"s8","Processor","% Processor Time","_Total",100.0,
  3,"s8","Processor","% Processor Time","_Total",100.0,
  6,"s9","Processor","% Processor Time","_Total",10.0,
  7,"s9","Processor","% Processor Time","_Total",10.0,
  8,"s9","Processor","% Processor Time","_Total",10.0,
  -1,"s10","Processor","% Processor Time","_Total",10.0,
  1,"s10","Processor","% Processor Time","_Total",10.0,
  2,"s10","Processor","% Processor Time","_Total",10.0,
  1,"other","Processor","% Processor Time","_Total",100.0
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixture + query)}
        self.assertEqual(set(rows), {"s1", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10"})
        self.assertEqual(rows["s1"]["MonitoringState"], "High CPU")
        self.assertEqual(rows["s1"]["Samples"], 3)
        self.assertAlmostEqual(rows["s1"]["MeanCpuPercent"], 286.0 / 3)
        for resource in ("s3", "s4", "s5", "s6", "s7"):
            self.assertEqual(rows[resource]["MonitoringState"], "Unknown: insufficient CPU samples")
        self.assertEqual(rows["s3"]["Samples"], 0)
        self.assertEqual(rows["s6"]["Samples"], 1)
        self.assertEqual(rows["s7"]["Samples"], 1)
        self.assertEqual(rows["s8"]["MonitoringState"], "Unknown: conflicting CPU samples")
        self.assertIsNone(rows["s8"]["MeanCpuPercent"])
        self.assertEqual(rows["s9"]["MonitoringState"], "Unknown: stale CPU samples")
        self.assertEqual(rows["s10"]["MonitoringState"], "Unknown: future CPU sample")

    def test_memory_threshold_and_missing_samples(self):
        query = replace_once(
            alert_query("low-memory.kql"),
            "datatable(ResourceId:string)[]",
            'datatable(ResourceId:string)["s1","s2","s3","s4","s5","s6","s7"]',
        )
        fixture = """
let Perf = datatable(Minutes:long, _ResourceId:string, ObjectName:string, CounterName:string, CounterValue:real)
[
  1,"s1","Memory","Available MBytes",100.0,
  2,"s1","Memory","Available MBytes",200.0,
  3,"s1","Memory","Available MBytes",300.0,
  1,"s2","Memory","Available MBytes",500.0,
  2,"s2","Memory","Available MBytes",500.0,
  3,"s2","Memory","Available MBytes",500.0,
  1,"s4","Memory","Available MBytes",1.0,
  2,"s4","Memory","Available MBytes",-1.0,
  1,"s5","Memory","Available MBytes",1.0,
  1,"s5","Memory","Available MBytes",1000.0,
  2,"s5","Memory","Available MBytes",1000.0,
  3,"s5","Memory","Available MBytes",1000.0,
  6,"s6","Memory","Available MBytes",1000.0,
  7,"s6","Memory","Available MBytes",1000.0,
  8,"s6","Memory","Available MBytes",1000.0,
  -1,"s7","Memory","Available MBytes",1000.0,
  1,"s7","Memory","Available MBytes",1000.0,
  2,"s7","Memory","Available MBytes",1000.0
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixture + query)}
        self.assertEqual(set(rows), {"s1", "s3", "s4", "s5", "s6", "s7"})
        self.assertEqual(rows["s1"]["MonitoringState"], "Low available memory")
        self.assertEqual(rows["s1"]["Samples"], 3)
        self.assertEqual(rows["s1"]["MeanAvailableMBytes"], 200.0)
        self.assertEqual(rows["s3"]["MonitoringState"], "Unknown: insufficient memory samples")
        self.assertEqual(rows["s4"]["Samples"], 1)
        self.assertEqual(rows["s5"]["MonitoringState"], "Unknown: conflicting memory samples")
        self.assertIsNone(rows["s5"]["MeanAvailableMBytes"])
        self.assertEqual(rows["s6"]["MonitoringState"], "Unknown: stale memory samples")
        self.assertEqual(rows["s7"]["MonitoringState"], "Unknown: future memory sample")

    def test_disk_requires_both_thresholds_and_paired_samples(self):
        query = replace_once(
            alert_query("low-disk-space.kql"),
            "datatable(ResourceId:string, Volume:string)[]",
            'datatable(ResourceId:string, Volume:string)["s1","C:","s2","D:","s3","E:",'
            '"s4","F:","s5","G:","s6","H:","s7","I:","s8","J:","s9","K:","s10","L:","s11","M:"]',
        )
        fixture = """
let Perf = datatable(Minutes:long, _ResourceId:string, ObjectName:string, CounterName:string, InstanceName:string, CounterValue:real)
[
  1,"S1","LogicalDisk","% Free Space","C:",9.0,
  1,"s1","LogicalDisk","Free Megabytes","c:",5000.0,
  1,"s2","LogicalDisk","% Free Space","D:",10.0,
  1,"s2","LogicalDisk","Free Megabytes","D:",4000.0,
  1,"s3","LogicalDisk","% Free Space","E:",9.0,
  1,"s3","LogicalDisk","Free Megabytes","E:",5120.0,
  1,"s4","LogicalDisk","% Free Space","F:",9.0,
  1,"s5","LogicalDisk","% Free Space","G:",9.0,
  4,"s5","LogicalDisk","Free Megabytes","G:",1000.0,
  1,"s6","LogicalDisk","% Free Space","H:",-1.0,
  1,"s6","LogicalDisk","Free Megabytes","H:",1000.0,
  1,"s7","LogicalDisk","% Free Space","I:",9.0,
  1,"s7","LogicalDisk","% Free Space","I:",90.0,
  1,"s7","LogicalDisk","Free Megabytes","I:",1000.0,
  1,"s8","LogicalDisk","% Free Space","J:",9.0,
  1,"s8","LogicalDisk","Free Megabytes","J:",1000.0,
  1,"s8","LogicalDisk","Free Megabytes","J:",10000.0,
  6,"s9","LogicalDisk","% Free Space","K:",90.0,
  6,"s9","LogicalDisk","Free Megabytes","K:",10000.0,
  -1,"s10","LogicalDisk","% Free Space","L:",90.0,
  -1,"s10","LogicalDisk","Free Megabytes","L:",10000.0,
  1,"s11","LogicalDisk","% Free Space","M:",9.0,
  1,"s11","LogicalDisk","Free Megabytes","M:",8000.0
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixture + query)}
        self.assertEqual(set(rows), {"s1", "s4", "s5", "s6", "s7", "s8", "s9", "s10"})
        self.assertEqual(rows["s1"]["MonitoringState"], "Low disk space")
        self.assertEqual(rows["s4"]["MonitoringState"], "Unknown: missing disk counter")
        self.assertEqual(rows["s5"]["MonitoringState"], "Unknown: disk counters out of sync")
        self.assertEqual(rows["s6"]["MonitoringState"], "Unknown: missing disk counter")
        self.assertEqual(rows["s7"]["MonitoringState"], "Unknown: conflicting disk counters")
        self.assertIsNone(rows["s7"]["PercentFree"])
        self.assertEqual(rows["s8"]["MonitoringState"], "Unknown: conflicting disk counters")
        self.assertIsNone(rows["s8"]["FreeMBytes"])
        self.assertEqual(rows["s9"]["MonitoringState"], "Unknown: stale disk counter")
        self.assertEqual(rows["s10"]["MonitoringState"], "Unknown: future disk counter")

    def test_critical_event_filters(self):
        query = replace_once(
            alert_query("critical-windows-events.kql"),
            "datatable(ResourceId:string, EventLog:string, Source:string, EventID:int)[]",
            'datatable(ResourceId:string, EventLog:string, Source:string, EventID:int)'
            '["s1","System","TestProvider",42,"s2","Application","TestProvider",7]',
        )
        fixture = """
let Event = datatable(Minutes:long, _ResourceId:string, EventLog:string, EventLevel:int, Source:string, EventID:int)
[
  1,"S1","system",1,"testprovider",42,
  2,"s1","System",1,"TestProvider",42,
  1,"s1","System",2,"TestProvider",42,
  1,"s1","System",1,"Other",42,
  1,"s1","System",1,"TestProvider",43,
  9,"s2","Application",1,"TestProvider",7,
  11,"s2","Application",1,"TestProvider",7,
  1,"other","System",1,"TestProvider",42
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixture + query)}
        self.assertEqual(set(rows), {"s1", "s2"})
        self.assertEqual(rows["s1"]["EventCount"], 2)
        self.assertEqual(rows["s2"]["EventCount"], 1)
        self.assertEqual(set(rows["s1"]), {"ResourceId", "MonitoringState", "EventCount", "LastEvent"})

    def test_software_baseline_and_incomplete_identity(self):
        query = replace_once(
            alert_query("unexpected-software.kql"),
            "datatable(ResourceId:string)[]", 'datatable(ResourceId:string)["s1","s2"]',
        )
        query = replace_once(
            query,
            "datatable(ResourceId:string, SoftwareName:string, Publisher:string)[]",
            'datatable(ResourceId:string, SoftwareName:string, Publisher:string)["s1","Approved","Vendor"]',
        )
        fixture = """
let ConfigurationChange = datatable(Minutes:long, _ResourceId:string, ConfigChangeType:string, ChangeCategory:string, SoftwareName:string, Publisher:string)
[
  1,"S1","Software","Added","approved","vendor",
  2,"s1","Software","Added","Approved","Other Vendor",
  3,"s1","Software","Added","Unknown Publisher","",
  4,"s1","Software","Modified","Other","Vendor",
  61,"s1","Software","Added","Old","Vendor",
  1,"s2","Software","Added","New","Vendor",
  1,"other","Software","Added","New","Vendor"
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixture + query)}
        self.assertEqual(set(rows), {"s1", "s2"})
        self.assertEqual(rows["s1"]["AdditionCount"], 2)
        self.assertEqual(rows["s2"]["AdditionCount"], 1)
        self.assertEqual(set(rows["s1"]), {"ResourceId", "MonitoringState", "AdditionCount", "LastAddition"})

    def test_only_exact_watched_registry_values_and_files_match(self):
        query = replace_once(
            alert_query("configuration-changes.kql"),
            "datatable(ResourceId:string, Hive:string, RegistryKey:string, ValueName:string)[]",
            r'datatable(ResourceId:string, Hive:string, RegistryKey:string, ValueName:string)'
            r'[@"s1",@"HKEY_LOCAL_MACHINE",@"SOFTWARE\Demo",@"Setting"]',
        )
        query = replace_once(
            query,
            "datatable(ResourceId:string, FileSystemPath:string)[]",
            r'datatable(ResourceId:string, FileSystemPath:string)[@"s2",@"C:\Demo\Test.txt"]',
        )
        fixture = r"""
let ConfigurationChange = datatable(Minutes:long, _ResourceId:string, ConfigChangeType:string, Hive:string, RegistryKey:string, ValueName:string, FileSystemPath:string)
[
  1,"S1","Registry",@"hkey_local_machine",@"software\demo","setting","",
  1,"s1","Registry",@"HKEY_LOCAL_MACHINE",@"SOFTWARE\Demo","other","",
  1,"s1","Files","","","",@"C:\Demo\Test.txt",
  1,"s2","Files","","","",@"c:\demo\test.txt",
  1,"s2","Files","","","",@"C:\Demo\Other.txt",
  121,"s2","Files","","","",@"C:\Demo\Test.txt",
  1,"other","Registry",@"HKEY_LOCAL_MACHINE",@"SOFTWARE\Demo","Setting",""
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixture + query)}
        self.assertEqual(set(rows), {"s1", "s2"})
        self.assertEqual(rows["s1"]["ChangeCount"], 1)
        self.assertEqual(rows["s2"]["ChangeCount"], 1)
        self.assertEqual(set(rows["s1"]), {"ResourceId", "MonitoringState", "ChangeCount", "LastChange"})


if __name__ == "__main__":
    unittest.main()
