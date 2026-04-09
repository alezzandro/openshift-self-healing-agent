# Reference: Filtering OAuth Identity Providers by Secret Existence

When the authentication operator is degraded due to a missing secret, use
this approach to filter the identity provider list and remove broken entries.

## Strategy
Query ALL secrets in the `openshift-config` namespace once, then filter the
IDP list in a single loop using `set_fact`.

## Step A — Get All Existing Secret Names

```yaml
- name: Get all secrets in openshift-config
  kubernetes.core.k8s_info:
    api_version: v1
    kind: Secret
    namespace: openshift-config
  register: config_secrets

- name: Build list of existing secret names
  ansible.builtin.set_fact:
    existing_secrets: "{{ config_secrets.resources | map(attribute='metadata.name') | list }}"
```

## Step B — Filter IDPs by Secret Existence

Initialize `valid_idps` to an empty list before the loop, then append only
those IDPs whose referenced secret exists.

```yaml
- name: Initialize valid IDP list
  ansible.builtin.set_fact:
    valid_idps: []

- name: Keep only IDPs with existing secrets
  ansible.builtin.set_fact:
    valid_idps: "{{ valid_idps + [item] }}"
  loop: "{{ current_idps }}"
  when: >-
    (item.type == 'HTPasswd' and item.htpasswd.fileData.name in existing_secrets)
    or (item.type == 'OpenID' and (item.openID.clientSecret.name | default('')) in existing_secrets)
    or (item.type == 'LDAP' and (item.ldap.bindPassword.name | default('')) in existing_secrets)
    or (item.type not in ['HTPasswd', 'OpenID', 'LDAP'])
```

## Type-Aware Secret Name Extraction
- **HTPasswd**: `.htpasswd.fileData.name`
- **OpenID**: `.openID.clientSecret.name`
- **LDAP**: `.ldap.bindPassword.name`
- **Other types**: kept by default (no secret check needed)

## After Filtering — Patch the OAuth Resource

```yaml
- name: Patch OAuth with valid identity providers
  kubernetes.core.k8s:
    state: present
    api_version: config.openshift.io/v1
    kind: OAuth
    name: cluster
    definition:
      spec:
        identityProviders: "{{ valid_idps }}"
```

## Important
- ALWAYS initialize `valid_idps` to `[]` before the loop.
- Use `| default('')` for secret names that may not exist on all IDP types.
- After patching, wait for the authentication ClusterOperator to recover.
