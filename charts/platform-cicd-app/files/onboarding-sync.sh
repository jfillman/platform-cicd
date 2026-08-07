#!/usr/bin/env bash

set -euo pipefail
source "${PLATFORM_LIB}/github-app.sh"

owner="$(echo "${APP_REPO_URL}" | sed -E 's#https?://github\.com/([^/]+)/.*#\1#')"
repo="$(echo "${APP_REPO_URL}" | sed -E 's#https?://github\.com/[^/]+/([^/.]+).*#\1#')"
image_repo="ghcr.io/${GITHUB_OWNER}/${APP_NAME}"
token="$(github_app_installation_token "${owner}" "${repo}")"
clone_url="https://x-access-token:${token}@github.com/${owner}/${repo}.git"

workdir="$(mktemp -d)"
git clone --quiet "${clone_url}" "${workdir}/repo"
cd "${workdir}/repo"
mkdir -p .tekt
python - <<'PY'
import json
import os
import textwrap

pipelines = json.loads(os.environ.get("PIPELINES_JSON", "{}"))
root_trigger = None
for flow_name, flow in pipelines.items():
    if isinstance(flow, dict):
        trigger = flow.get("trigger") or {}
        trigger_source = trigger.get("source") or ""
        trigger_event = trigger.get("event") or trigger.get("type") or ""
        if trigger_source == "git" and trigger_event in {"push", "branch.created", "pull_request"}:
            root_trigger = {
                "name": flow_name,
                "type": trigger_event,
                "branch": trigger.get("branch") or trigger.get("branchPattern") or "",
                "filePathPattern": trigger.get("filePathPattern") or [],
            }
            break
        if trigger_source != "git" and trigger_event in {"push", "branch.created", "pull_request"}:
            root_trigger = {
                "name": flow_name,
                "type": trigger_event,
                "branch": trigger.get("branch") or trigger.get("branchPattern") or "",
                "filePathPattern": trigger.get("filePathPattern") or [],
            }
            break
    elif isinstance(flow, list):
        for entry in flow:
            entry_trigger = entry.get("trigger")
            if isinstance(entry_trigger, dict):
                entry_source = entry_trigger.get("source") or ""
                entry_event = entry_trigger.get("event") or entry_trigger.get("type") or ""
            else:
                entry_source = "git"
                entry_event = entry_trigger or ""
            if entry_source == "git" and entry_event in {"push", "branch.created", "pull_request"}:
                root_trigger = {
                    "name": flow_name,
                    "type": entry_event,
                    "branch": entry.get("branch") or entry.get("branchPattern") or "",
                    "filePathPattern": entry.get("filePathPattern") or [],
                }
                break
            if entry_source != "git" and entry_event in {"push", "branch.created", "pull_request"}:
                root_trigger = {
                    "name": flow_name,
                    "type": entry_event,
                    "branch": entry.get("branch") or entry.get("branchPattern") or "",
                    "filePathPattern": entry.get("filePathPattern") or [],
                }
                break
        if root_trigger:
            break

app_namespace = os.environ["APP_NAMESPACE"]
app_name = os.environ["APP_NAME"]
github_owner = os.environ["GITHUB_OWNER"]
gitops_repo_url = os.environ.get("GITOPS_REPO_URL", "")
image_repo = f"ghcr.io/{github_owner}/{app_name}"

push_annotations = [
    '    pipelinesascode.tekton.dev/on-event: "[push]"',
]
if root_trigger and root_trigger.get("branch"):
    push_annotations.append(f'    pipelinesascode.tekton.dev/on-target-branch: "[{root_trigger["branch"]}]"')
else:
    push_annotations.append('    pipelinesascode.tekton.dev/on-target-branch: "[main]"')
if root_trigger and root_trigger.get("filePathPattern"):
    paths = " || ".join([f'.pathChanged("{path}")' for path in root_trigger["filePathPattern"]])
    push_annotations.append(f'    pipelinesascode.tekton.dev/on-cel-expression: \'{paths}\'')

push_doc = textwrap.dedent(f"""\
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: build-
  annotations:
{chr(10).join(push_annotations)}
    pipelinesascode.tekton.dev/max-keep-runs: "5"
spec:
  pipelineRef:
    resolver: cluster
    params:
      - {{ "{{ name: kind, value: pipeline }}" }}
      - {{ "{{ name: name, value: build }}" }}
      - {{ "{{ name: namespace, value: platform-catalog }}" }}
  params:
    - {{ "{{ name: git-url, value: \"{{ repo_url }}\" }}" }}
    - {{ "{{ name: git-revision, value: \"{{ revision }}\" }}" }}
    - {{ "{{ name: image-repo, value: \"{image_repo}\" }}" }}
    - {{ "{{ name: app-namespace, value: \"{app_namespace}\" }}" }}
    - {{ "{{ name: app-name, value: \"{app_name}\" }}" }}
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
  taskRunTemplate:
    serviceAccountName: pipeline-runner
  timeouts:
    pipeline: "1h"
""")

pull_request_doc = textwrap.dedent(f"""\
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: pr-validate-
  annotations:
    pipelinesascode.tekton.dev/on-event: "[pull_request]"
    pipelinesascode.tekton.dev/on-target-branch: "[main]"
    pipelinesascode.tekton.dev/max-keep-runs: "5"
spec:
  pipelineRef:
    resolver: cluster
    params:
      - {{ "{{ name: kind, value: pipeline }}" }}
      - {{ "{{ name: name, value: build }}" }}
      - {{ "{{ name: namespace, value: platform-catalog }}" }}
  params:
    - {{ "{{ name: git-url, value: \"{{ repo_url }}\" }}" }}
    - {{ "{{ name: git-revision, value: \"{{ revision }}\" }}" }}
    - {{ "{{ name: image-repo, value: \"{image_repo}-pr\" }}" }}
    - {{ "{{ name: app-namespace, value: \"{app_namespace}\" }}" }}
    - {{ "{{ name: app-name, value: \"{app_name}\" }}" }}
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
  taskRunTemplate:
    serviceAccountName: pipeline-runner
  timeouts:
    pipeline: "1h"
""")

with open('.tekton/push.yaml', 'w') as fh:
    fh.write(push_doc)
with open('.tekton/pull-request.yaml', 'w') as fh:
    fh.write(pull_request_doc)

with open('.tekton/onboarding-resync.yaml', 'w') as fh:
    fh.write(textwrap.dedent(f"""\
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: onboarding-resync-
  annotations:
    pipelinesascode.tekton.dev/on-event: "[push]"
    pipelinesascode.tekton.dev/on-target-branch: "[main]"
    pipelinesascode.tekton.dev/on-cel-expression: '.pathChanged("cicd.yaml")'
    pipelinesascode.tekton.dev/max-keep-runs: "5"
spec:
  pipelineRef:
    resolver: cluster
    params:
      - {{ "{{ name: kind, value: pipeline }}" }}
      - {{ "{{ name: name, value: onboarding-resync }}" }}
      - {{ "{{ name: namespace, value: platform-catalog }}" }}
  params:
    - {{ "{{ name: git-url, value: \"{{ repo_url }}\" }}" }}
    - {{ "{{ name: app-namespace, value: \"{app_namespace}\" }}" }}
    - {{ "{{ name: app-name, value: \"{app_name}\" }}" }}
    - {{ "{{ name: github-owner, value: \"{github_owner}\" }}" }}
    - {{ "{{ name: gitops-repo-url, value: \"{gitops_repo_url}\" }}" }}
  taskRunTemplate:
    serviceAccountName: pipeline-runner
  timeouts:
    pipeline: "10m"
"""))
PY

if git status --porcelain | grep -q .; then
  git config user.name "platform-cicd onboarding automation"
  git config user.email "onboarding@platform-cicd.invalid"
  branch="onboarding-resync-$(date +%s)"
  git checkout -b "${branch}"
  git add .tekton/push.yaml .tekton/pull-request.yaml .tekton/onboarding-resync.yaml
  git commit --quiet -m "Onboarding: sync .tekton boilerplate"
  git push --quiet "${clone_url}" "${branch}"
  pr_body="$(jq -n --arg title "Onboarding: sync .tekton boilerplate" --arg body "Generated .tekton boilerplate from the platform app chart." --arg head "${branch}" --arg base "main" '{title: $title, body: $body, head: $head, base: $base}')"
  curl --fail --silent --show-error -X POST -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${repo}/pulls" -d "${pr_body}" > /dev/null
  echo "app repo: opened onboarding-sync PR"
else
  echo "app repo: .tekton/ already up to date"
fi
