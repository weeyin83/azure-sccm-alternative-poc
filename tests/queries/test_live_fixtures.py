"""Validate KQL using empty scopes and synthetic fixtures without returning guest records."""

import json
import os
import subprocess
import unittest
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = os.environ.get("POC_WORKSPACE_EVIDENCE")


def get_token(resource):
    return subprocess.run(
        [
            "az", "account", "get-access-token", "--resource", resource,
            "--query", "accessToken", "--output", "tsv",
        ],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def parse_query_result(result):
    if not isinstance(result, dict) or result.get("error") is not None:
        raise AssertionError("Log Analytics returned an error or partial result")
    tables = result.get("tables")
    if not isinstance(tables, list) or len(tables) != 1 or not isinstance(tables[0], dict):
        raise AssertionError("Log Analytics returned an unexpected table shape")
    columns = tables[0].get("columns")
    rows = tables[0].get("rows")
    if not isinstance(columns, list) or not columns or not isinstance(rows, list):
        raise AssertionError("Log Analytics returned an unexpected row shape")
    names = [column.get("name") if isinstance(column, dict) else None for column in columns]
    if any(not isinstance(name, str) or not name for name in names) or len(set(names)) != len(names):
        raise AssertionError("Log Analytics returned invalid column names")
    if any(not isinstance(row, list) or len(row) != len(names) for row in rows):
        raise AssertionError("Log Analytics returned an unexpected row shape")
    return [dict(zip(names, row)) for row in rows]


def run_query(query):
    with open(EVIDENCE, encoding="utf-8") as stream:
        workspace = json.load(stream)["properties"]["customerId"]
    token = get_token("https://api.loganalytics.io")
    request = urllib.request.Request(
        f"https://api.loganalytics.azure.com/v1/workspaces/{workspace}/query",
        data=json.dumps({"query": query, "timespan": "P2D"}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace").replace(workspace, "[workspace]")
        error.close()
        raise AssertionError(f"Log Analytics query failed ({error.code}): {detail}") from None
    return parse_query_result(result)


class QueryResponseShape(unittest.TestCase):
    def test_valid_results_and_empty_rows(self):
        table = {"columns": [{"name": "Name"}, {"name": "Count"}], "rows": [["example", 2]]}
        self.assertEqual(parse_query_result({"tables": [table]}), [{"Name": "example", "Count": 2}])
        table["rows"] = []
        self.assertEqual(parse_query_result({"tables": [table]}), [])

    def test_partial_results_are_rejected_even_when_rows_exist(self):
        result = {
            "error": {"code": "PartialError"},
            "tables": [{"columns": [{"name": "Value"}], "rows": [[1]]}],
        }
        with self.assertRaisesRegex(AssertionError, "partial result"):
            parse_query_result(result)

    def test_malformed_tables_columns_and_rows_are_rejected(self):
        for result in (
            {},
            {"tables": []},
            {"tables": [{"columns": [], "rows": []}]},
            {"tables": [{"columns": [{"name": "a"}, {"name": "a"}], "rows": [[1, 2]]}]},
            {"tables": [{"columns": [{"name": "a"}], "rows": [[1, 2]]}]},
        ):
            with self.subTest(result=result), self.assertRaises(AssertionError):
                parse_query_result(result)


@unittest.skipUnless(EVIDENCE, "Set POC_WORKSPACE_EVIDENCE to a private workspace evidence JSON file")
class SyntheticQueryFixtures(unittest.TestCase):
    def test_guest_queries_compile_without_returning_estate_data(self):
        for path in sorted((ROOT / "queries").glob("*.kql")):
            if path.name.endswith(".resource-graph.kql"):
                continue
            with self.subTest(query=path.name):
                rows = run_query(path.read_text())
                self.assertEqual(len(rows), 0, "An empty query scope must not return any rows")

    def test_resource_graph_queries_compile_without_returning_estate_data(self):
        with open(Path(EVIDENCE).parent / "report.json", encoding="utf-8") as stream:
            subscriptions = json.load(stream)["SubscriptionScope"]
        token = get_token("https://management.azure.com/")
        for path in sorted((ROOT / "queries").glob("*.resource-graph.kql")):
            with self.subTest(query=path.name):
                request = urllib.request.Request(
                    "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01",
                    data=json.dumps({
                        "subscriptions": subscriptions,
                        "query": path.read_text() + "\n| take 0",
                        "options": {"resultFormat": "objectArray", "allowPartialScopes": False},
                    }).encode(),
                    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                )
                try:
                    with urllib.request.urlopen(request, timeout=60) as response:
                        result = json.load(response)
                except urllib.error.HTTPError as error:
                    detail = error.read().decode("utf-8", errors="replace")
                    error.close()
                    for subscription in subscriptions:
                        detail = detail.replace(subscription, "[subscription]")
                    raise AssertionError(f"Resource Graph query failed ({error.code}): {detail}") from None
                self.assertEqual(result["data"], [])

    def test_software_removal_and_conflicting_evidence(self):
        query = (ROOT / "queries/software-current.kql").read_text()
        query = query.replace('dynamic([])', 'dynamic(["s1", "s2", "s3"])', 1)
        fixtures = """
let ConfigurationData = datatable(Minutes:long, _ResourceId:string, Computer:string, SoftwareName:string, Publisher:string, CurrentVersion:string, ConfigDataType:string)
[
  30,"S1","s1","Removed App","Vendor","1.0","Software",
  30,"s2","s2","Kept App","Vendor","2.0","Software",
  10,"s3","s3","Ambiguous App","Vendor","3.0","Software"
] | extend TimeGenerated = now() - Minutes * 1m;
let ConfigurationChange = datatable(Minutes:long, _ResourceId:string, Computer:string, SoftwareName:string, Publisher:string, ChangeCategory:string, ConfigChangeType:string)
[
  10,"s1","s1","removed app","vendor","Removed","Software",
  10,"s3","s3","Ambiguous App","Vendor","Removed","Software"
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixtures + query)}
        self.assertEqual(set(rows), {"s2", "s3"})
        self.assertEqual(rows["s2"]["State"], "Present")
        self.assertEqual(rows["s2"]["CurrentVersion"], "2.0")
        self.assertEqual(rows["s3"]["State"], "Unknown: conflicting observations")

    def test_service_changes_reconcile_and_unknown_is_not_healthy(self):
        query = (ROOT / "queries/services-expected-running.kql").read_text()
        query = query.replace(
            "datatable(ResourceId:string, SvcName:string)[]",
            'datatable(ResourceId:string, SvcName:string)["s1","svc","s2","svc",'
            '"s3","svc","s4","svc","s5","svc","s6","svc","s7","svc","s8","svc"]',
        )
        fixtures = """
let ConfigurationData = datatable(Minutes:long, _ResourceId:string, Computer:string, SvcName:string, SvcState:string, SvcStartupType:string, ConfigDataType:string)
[
  45,"S1","s1","svc","Running","Automatic","WindowsServices",
  50,"s2","s2","svc","Running","Automatic","WindowsServices",
  90,"s4","s4","svc","Running","Automatic","WindowsServices",
  10,"s5","s5","svc","Running","Automatic","WindowsServices"
] | extend TimeGenerated = now() - Minutes * 1m;
let ConfigurationChange = datatable(Minutes:long, _ResourceId:string, Computer:string, SvcName:string, SvcState:string, SvcStartupType:string, ConfigChangeType:string)
[
  30,"s1","s1","svc","Stopped","","WindowsServices",
  10,"s1","s1","svc","Running","","WindowsServices",
  10,"s2","s2","svc","Stopped","","WindowsServices",
  5,"s2","s2","svc","","Manual","WindowsServices",
  10,"s5","s5","svc","Stopped","","WindowsServices",
  3000,"s6","s6","svc","Stopped","","WindowsServices",
  90,"s7","s7","svc","Stopped","","WindowsServices",
  -1,"s8","s8","svc","Running","","WindowsServices"
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixtures + query)}
        self.assertEqual(set(rows), {"s2", "s3", "s4", "s5", "s6", "s7", "s8"})
        self.assertEqual(rows["s2"]["MonitoringState"], "Not running")
        self.assertEqual(json.loads(rows["s2"]["ObservedStartupTypes"]), ["manual"])
        self.assertEqual(rows["s3"]["MonitoringState"], "Unknown: no state in history")
        self.assertEqual(rows["s4"]["MonitoringState"], "Unknown: stale state")
        self.assertEqual(rows["s5"]["MonitoringState"], "Unknown: conflicting state observations")
        self.assertEqual(rows["s6"]["MonitoringState"], "Unknown: no state in history")
        self.assertEqual(rows["s7"]["MonitoringState"], "Unknown: stale state")
        self.assertEqual(rows["s8"]["MonitoringState"], "Unknown: future state observation")

    def test_heartbeat_grace_and_bounded_history(self):
        query = (ROOT / "queries/heartbeat-missing.kql").read_text()
        query = query.replace(
            "datatable(ResourceId:string, ExpectedOnlineSince:datetime)[]",
            'datatable(ResourceId:string, Minutes:long)["s1",60,"s2",60,"s3",60,'
            '"s4",5,"s5",60,"s6",5000,"s7",60] | extend ExpectedOnlineSince = now() - Minutes * 1m',
        )
        fixtures = """
let Heartbeat = datatable(Minutes:long, _ResourceId:string)
[
  30,"S2",
  2,"s3",
  1500,"s5",
  1500,"s6",
  -1,"s7",
  1,"offline-server"
] | extend TimeGenerated = now() - Minutes * 1m;
"""
        rows = {row["ResourceId"]: row for row in run_query(fixtures + query)}
        self.assertEqual(set(rows), {"s1", "s2", "s5", "s6", "s7"})
        self.assertEqual(rows["s1"]["MonitoringState"], "No heartbeat observed in available history during expected-online period")
        self.assertEqual(rows["s2"]["MonitoringState"], "Stale heartbeat")
        self.assertEqual(rows["s5"]["MonitoringState"], "No heartbeat observed in available history during expected-online period")
        self.assertEqual(rows["s6"]["MonitoringState"], "No heartbeat observed in available history during expected-online period")
        self.assertEqual(rows["s7"]["MonitoringState"], "Unknown: future heartbeat")


if __name__ == "__main__":
    unittest.main()
