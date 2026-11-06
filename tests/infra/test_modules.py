"""Offline contract checks for the independently compiled Bicep modules."""

import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULES = ROOT / "infra" / "modules"


def compile_module(name):
    result = subprocess.run(
        ["az", "bicep", "build", "--file", str(MODULES / name), "--stdout"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


class ModuleContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.templates = {
            path.name: compile_module(path.name)
            for path in sorted(MODULES.glob("*.bicep"))
        }

    def resource(self, name):
        resources = self.templates[name]["resources"]
        self.assertEqual(len(resources), 1)
        return resources[0]

    def test_performance_events_are_windows_and_workspace_only(self):
        template = self.templates["performance-events-dcr.bicep"]
        resource = self.resource("performance-events-dcr.bicep")
        self.assertEqual(resource["kind"], "Windows")
        properties = resource["properties"]
        self.assertEqual(set(properties["dataSources"]), {"performanceCounters", "windowsEventLogs"})
        self.assertEqual(set(properties["destinations"]), {"logAnalytics"})
        self.assertEqual(len(properties["destinations"]["logAnalytics"]), 1)
        self.assertEqual(properties["dataFlows"][0]["streams"], ["Microsoft-Perf", "Microsoft-Event"])
        parameters = template["parameters"]
        self.assertEqual(parameters["samplingFrequencyInSeconds"]["defaultValue"], 60)
        self.assertTrue(all(not selector.startswith("Security!") for selector in parameters["eventXPathQueries"]["defaultValue"]))
        self.assertNotIn("defaultValue", parameters["workspaceResourceId"])

    def test_change_tracking_is_dedicated_and_bounded(self):
        template = self.templates["change-tracking-dcr.bicep"]
        properties = self.resource("change-tracking-dcr.bicep")["properties"]
        self.assertEqual(set(properties["dataSources"]), {"extensions"})
        self.assertEqual(len(properties["dataSources"]["extensions"]), 1)
        source = properties["dataSources"]["extensions"][0]
        self.assertEqual(source["extensionName"], "ChangeTracking-Windows")
        self.assertEqual(
            source["streams"],
            ["Microsoft-ConfigurationChange", "Microsoft-ConfigurationChangeV2", "Microsoft-ConfigurationData"],
        )
        self.assertEqual(source["streams"], properties["dataFlows"][0]["streams"])
        self.assertNotIn("transformKql", properties["dataFlows"][0])
        self.assertEqual(len(properties["destinations"]["logAnalytics"]), 1)
        params = template["parameters"]
        self.assertEqual(params["serviceCollectionFrequency"]["minValue"], 600)
        self.assertEqual(params["serviceCollectionFrequency"]["maxValue"], 1800)
        self.assertEqual(params["fileCollectionFrequency"]["minValue"], 1800)
        self.assertEqual(params["fileCollectionFrequency"]["maxValue"], 2400)
        for item in ("registryInfo", "fileInfo", "workspaceResourceId"):
            self.assertNotIn("defaultValue", params[item])

    def test_extensions_require_version_and_do_not_create_machines(self):
        for name, publisher, extension_type in (
            ("ama-extension.bicep", "Microsoft.Azure.Monitor", "AzureMonitorWindowsAgent"),
            ("change-tracking-extension.bicep", "Microsoft.Azure.ChangeTrackingAndInventory", "ChangeTracking-Windows"),
        ):
            with self.subTest(name=name):
                template = self.templates[name]
                resource = self.resource(name)
                self.assertEqual(resource["type"], "Microsoft.HybridCompute/machines/extensions")
                self.assertEqual(resource["properties"]["publisher"], publisher)
                self.assertEqual(resource["properties"]["type"], extension_type)
                self.assertTrue(resource["properties"]["enableAutomaticUpgrade"])
                self.assertNotIn("defaultValue", template["parameters"]["typeHandlerVersion"])

    def test_association_uses_existing_arc_machine(self):
        resource = self.resource("dcr-association.bicep")
        self.assertEqual(resource["type"], "Microsoft.Insights/dataCollectionRuleAssociations")
        self.assertIn("Microsoft.HybridCompute/machines", resource["scope"])
        self.assertEqual(resource["properties"]["dataCollectionRuleId"], "[parameters('dataCollectionRuleId')]")

    def test_action_group_requires_explicit_recipient_and_is_disabled_by_default(self):
        template = self.templates["action-group.bicep"]
        resource = self.resource("action-group.bicep")
        self.assertEqual(resource["type"], "Microsoft.Insights/actionGroups")
        self.assertFalse(template["parameters"]["enabled"]["defaultValue"])
        self.assertNotIn("defaultValue", template["parameters"]["emailReceivers"])
        emailReceivers = resource["properties"]["copy"][0]
        self.assertEqual(emailReceivers["name"], "emailReceivers")
        self.assertEqual(
            emailReceivers["input"]["emailAddress"],
            "[parameters('emailReceivers')[copyIndex('emailReceivers')].emailAddress]",
        )

    def test_log_alert_is_workspace_scoped_and_disabled_by_default(self):
        template = self.templates["log-alert.bicep"]
        resource = self.resource("log-alert.bicep")
        properties = resource["properties"]
        self.assertEqual(resource["type"], "Microsoft.Insights/scheduledQueryRules")
        self.assertEqual(resource["kind"], "LogAlert")
        self.assertEqual(resource["location"], "[parameters('location')]")
        self.assertNotIn("defaultValue", template["parameters"]["location"])
        self.assertFalse(template["parameters"]["enabled"]["defaultValue"])
        self.assertEqual(properties["enabled"], "[parameters('enabled')]")
        self.assertEqual(properties["scopes"], ["[parameters('workspaceResourceId')]"])
        self.assertEqual(properties["actions"]["actionGroups"], ["[parameters('actionGroupResourceId')]"])
        for name in ("query", "queryTimeRange", "autoMitigate", "splitByResourceId"):
            self.assertNotIn("defaultValue", template["parameters"][name])
        self.assertEqual(properties["overrideQueryTimeRange"], "[parameters('queryTimeRange')]")
        self.assertEqual(properties["autoMitigate"], "[parameters('autoMitigate')]")
        condition = properties["criteria"]["allOf"][0]
        self.assertIn("parameters('splitByResourceId')", condition["dimensions"])
        self.assertIn("ResourceId", condition["dimensions"])


class EntrypointContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["az", "bicep", "build", "--file", str(ROOT / "infra" / "main.bicep"), "--stdout"],
            check=True, capture_output=True, text=True,
        )
        cls.template = json.loads(result.stdout)

    def test_stages_are_explicit_and_plan_arrays_default_empty(self):
        parameters = self.template["parameters"]
        self.assertNotIn("defaultValue", parameters["stage"])
        self.assertNotIn("defaultValue", parameters["workspaceResourceId"])
        self.assertEqual(
            set(parameters["stage"]["allowedValues"]),
            {"ama", "collection-rules", "associations", "change-tracking-extension", "alerting"},
        )
        for name in (
            "amaExtensions", "changeTrackingExtensions", "performanceRules",
            "changeTrackingRules", "associations", "actionGroups", "alerts",
        ):
            self.assertEqual(parameters[name]["defaultValue"], [])
        stages = {
            "ama": "ama", "changeTracking": "change-tracking-extension",
            "performance": "collection-rules", "trackingRule": "collection-rules",
            "association": "associations", "actionGroup": "alerting", "alert": "alerting",
        }
        resources = self.template["resources"]
        self.assertEqual(set(resources), set(stages))
        for name, stage in stages.items():
            resource = resources[name]
            self.assertEqual(resource["condition"], f"[equals(parameters('stage'), '{stage}')]")
            self.assertIn(".scope.subscriptionId", resource["subscriptionId"])
            self.assertIn(".scope.resourceGroupName", resource["resourceGroup"])

    def test_notifications_and_alerts_cannot_be_enabled_by_entrypoint(self):
        for name in ("actionGroup", "alert"):
            parameters = self.template["resources"][name]["properties"]["parameters"]
            self.assertFalse(parameters["enabled"]["value"])
        alert_params = self.template["resources"]["alert"]["properties"]["parameters"]
        self.assertIn(".location", alert_params["location"]["value"])
        for name in ("queryTimeRange", "autoMitigate", "splitByResourceId"):
            self.assertIn(f".{name}", alert_params[name]["value"])


if __name__ == "__main__":
    unittest.main()
