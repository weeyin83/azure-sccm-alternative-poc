# Copilot instructions – Azure Arc SCCM Replacement PoC

## Purpose
This repo is a proof of concept showing how Azure Arc and native Azure services
can replace selected Configuration Manager capabilities for Windows Server
management, for a customer demonstration.

## Standing rules
- Never deploy, modify or delete Azure resources without my explicit approval.
- Discovery must use read-only commands only (Get-*, az ... show/list, Resource Graph queries).
- Never assume the Azure environment is empty. Check for existing resources first.
- Never overwrite or duplicate existing monitoring configuration, DCRs, DCR associations, alerts or Action Groups.
- Reuse an existing suitable Log Analytics Workspace rather than creating a new one.
- Never hardcode subscription IDs, resource IDs, tenant IDs, credentials, email addresses or customer-specific values. Use parameters.

## Technology choices
- Bicep is the primary infrastructure-as-code language. Use modules under infra/modules/.
- Use PowerShell and Azure CLI for discovery, validation and operational tasks.
- Use Azure Monitor Agent (AMA) only. Do not use the legacy Log Analytics agent (MMA/OMS).
- Use the current AMA-based Change Tracking and Inventory, not the older Azure Automation-based version.

## Accuracy
- Treat current Microsoft Learn documentation as the source of truth. Verify extension versions, resource API versions and KQL table and column names before using them.
- Do not invent Azure features, resource types, API versions or KQL tables. If unsure, say so.
- Do not claim real-time change detection where collection is scheduled.
- Distinguish Azure resource inventory (Resource Graph) from guest OS inventory.

## Ways of working
- Work in phases: Discovery → Design → Build → Deployment → Validation → Demo.
- Stop and wait for approval at the end of Design and before any Deployment.
- Clearly label stretch goals (for example Workbooks) separately from core scope.
- Note cost, licensing and data-handling implications whenever a resource or data collection is added.
- Use UK English spelling in documentation.