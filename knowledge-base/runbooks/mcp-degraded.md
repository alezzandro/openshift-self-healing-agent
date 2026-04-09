# Runbook: MCPDegraded (MachineConfigPool Degraded)

## Alert
MCPDegraded fires when a MachineConfigPool reports Degraded=True.

## Root Cause
The most common cause is a conflicting or invalid MachineConfig applied to
the pool. When a MachineConfig cannot be rendered or applied, the MCP
controller marks the pool as Degraded and stops rolling out changes.

## Approved Remediation
1. Query the MachineConfigPool status for the degraded pool using
   `kubernetes.core.k8s_info` with `api_version: machineconfiguration.openshift.io/v1`
   and `kind: MachineConfigPool`.
2. Extract the error details from the **RenderDegraded** condition (NOT
   the Degraded condition, which often has an empty message). Use a Jinja2
   regex_search on the RenderDegraded message to find the conflicting MC name.
   Example pattern: `not reconcilable against "([^"]+)"` will capture the
   offending MachineConfig name. If the `conflicting_mc` variable is already
   provided via extra_vars, use it directly as a fallback instead of parsing.
3. Delete the conflicting MachineConfig using `kubernetes.core.k8s` with
   `state: absent`.
4. Wait for the MCP to finish updating all nodes and return to
   Updated=True, Degraded=False (retries: 40, delay: 30). Use the conditions
   list on the MCP resource:
   `mcp.resources[0].status.conditions | selectattr('type','equalto','Degraded')
   | map(attribute='status') | first == 'False'`
   and similarly for Updated == 'True'.

## Variables
- `target_mcp`: the name of the degraded MachineConfigPool (required)
- `conflicting_mc`: the name of the MachineConfig to remove (may be provided
  via extra_vars or extracted dynamically from the RenderDegraded message)
