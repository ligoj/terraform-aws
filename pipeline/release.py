#!/usr/bin/env python3
"""Ligoj release CLI.

Runs the full release workflow and watches it until the updated application is
ready:

  1. credentials check (offers the SSO login),
  2. Step Functions release execution (docker images -> terraform deploy -> ECS
     rollout confirmation), with live progress of the underlying pipelines,
  3. ECR check (a new image was really pushed and is the one being rolled out),
  4. ECS rolling update watch, container logs scanned for WARN/ERROR lines,
  5. HTTP readiness of the public endpoint,
  6. summary with per-phase elapsed times; non-zero exit on any failure.

Only needs python3 and the AWS CLI (credentials come from the named profile).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from typing import Any
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------- output

IS_TTY = sys.stdout.isatty()


def color(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if IS_TTY else text


def bold(t: str) -> str:
    return color("1", t)


def green(t: str) -> str:
    return color("32", t)


def yellow(t: str) -> str:
    return color("33", t)


def red(t: str) -> str:
    return color("31", t)


def dim(t: str) -> str:
    return color("2", t)


T0 = time.monotonic()


def elapsed(since: float | None = None) -> str:
    s = int(time.monotonic() - (T0 if since is None else since))
    return f"{s // 60:02d}:{s % 60:02d}"


def now() -> str:
    return dt.datetime.now().strftime("%H:%M:%S")


def log(msg: str) -> None:
    sys.stdout.write("\r\033[K" if IS_TTY else "")
    print(f"{dim(now())} {dim('+' + elapsed())}  {msg}", flush=True)


def status_line(msg: str) -> None:
    """Transient one-line status (overwritten on a TTY, printed sparsely otherwise)."""
    if IS_TTY:
        sys.stdout.write(f"\r\033[K{dim(now())} {dim('+' + elapsed())}  {msg}")
        sys.stdout.flush()
    else:
        if int(time.monotonic()) % 60 < 10:
            print(f"{now()} +{elapsed()}  {msg}", flush=True)


class Phase:
    """Named step with its own elapsed time, recorded for the final summary."""

    records: list[tuple[str, str, str]] = []

    def __init__(self, name: str):
        self.name = name
        self.start = time.monotonic()
        log(bold(f"▶ {name}"))

    def done(self, ok: bool = True, note: str = "") -> None:
        mark = green("✔") if ok else red("✘")
        log(f"{mark} {self.name} {dim('(' + elapsed(self.start) + ')')} {note}".rstrip())
        Phase.records.append((self.name, elapsed(self.start), "ok" if ok else "FAILED"))


# --------------------------------------------------------------------------- aws cli

class AwsError(RuntimeError):
    pass


class Aws:
    def __init__(self, profile: str | None, region: str):
        self.profile = profile
        self.region = region
        if not shutil.which("aws"):
            sys.exit(red("The AWS CLI ('aws') is not installed or not in PATH"))

    def base(self, region: str | None = None) -> list[str]:
        cmd = ["aws", "--region", region or self.region, "--output", "json", "--no-cli-pager"]
        if self.profile:
            cmd += ["--profile", self.profile]
        return cmd

    def __call__(self, *args: str, region: str | None = None, raw: bool = False) -> Any:
        proc = subprocess.run(self.base(region) + list(args), capture_output=True, text=True)
        if proc.returncode != 0:
            raise AwsError(proc.stderr.strip() or f"aws {' '.join(args)} failed")
        if raw or not proc.stdout.strip():
            return proc.stdout
        return json.loads(proc.stdout)

    def try_call(self, *args: str, **kw) -> Any:
        try:
            return self(*args, **kw)
        except AwsError as e:
            log(yellow(f"aws {args[0]} {args[1]}: {str(e).splitlines()[0][:160]}"))
            return None


def check_credentials(aws: Aws, interactive: bool) -> None:
    phase = Phase("Credentials")
    try:
        ident = aws("sts", "get-caller-identity")
    except AwsError as e:
        log(yellow(str(e).splitlines()[0]))
        if not (interactive and aws.profile):
            phase.done(False)
            sys.exit(red(f"No valid credentials. Run: aws sso login --profile {aws.profile}"))
        answer = input(f"Run 'aws sso login --profile {aws.profile}' now? [Y/n] ").strip().lower()
        if answer not in ("", "y", "yes"):
            phase.done(False)
            sys.exit(2)
        subprocess.run(["aws", "sso", "login", "--profile", aws.profile], check=False)
        try:
            ident = aws("sts", "get-caller-identity")
        except AwsError as e2:
            phase.done(False)
            sys.exit(red(f"Still no credentials: {e2}"))
    log(f"account {ident['Account']}, {ident['Arn'].split('/')[-1]} ({aws.profile or 'default'}, {aws.region})")
    phase.done()


def check_ci_tfvars(aws: Aws, app: str, tfvars_path: str, interactive: bool) -> None:
    """The pipeline reads its variables from S3: warn on drift, refuse a 'profile' line."""
    phase = Phase("CI variables (S3)")
    proj = aws.try_call("codebuild", "batch-get-projects", "--names", f"{app}-deploy-apply")
    env = ((proj or {}).get("projects") or [{}])[0].get("environment", {}).get("environmentVariables", [])
    uri = next((v["value"] for v in env if v["name"] == "TFVARS_S3_URI"), "")
    if not uri:
        log(dim("no TFVARS_S3_URI on the apply project: skipped"))
        phase.done()
        return
    remote = aws.try_call("s3", "cp", uri, "-", raw=True) or ""
    local = ""
    if os.path.isfile(tfvars_path):
        local = "".join(l for l in open(tfvars_path, encoding="utf-8") if not re.match(r"^\s*profile\s*=", l))
    has_profile = re.search(r"^\s*profile\s*=", remote, re.M) is not None
    drift = bool(local) and remote.strip() != local.strip()
    if has_profile:
        log(red(f"{uri} contains a 'profile' line: the deploy would fail (no such profile in CodeBuild)"))
    elif drift:
        log(yellow(f"{uri} differs from {os.path.basename(tfvars_path)} (without its profile line)"))
    if (has_profile or drift) and local:
        if interactive and input(f"Publish {os.path.basename(tfvars_path)} (minus profile) to {uri}? [Y/n] ").strip().lower() in ("", "y", "yes"):
            proc = subprocess.run(aws.base() + ["s3", "cp", "-", uri], input=local, text=True, capture_output=True)
            if proc.returncode != 0:
                phase.done(False)
                sys.exit(red(proc.stderr.strip()))
            log(green("published"))
        elif has_profile:
            phase.done(False)
            sys.exit(red("fix the CI tfvars first (see README.saas.md, 'Configuration changes')"))
    else:
        log(f"{uri} is in sync")
    phase.done()


# --------------------------------------------------------------------------- config

def read_tfvars(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    if not os.path.isfile(path):
        return values
    for line in open(path, encoding="utf-8"):
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"', line)
        if m:
            values[m.group(1)] = m.group(2)
    return values


# --------------------------------------------------------------------------- ecr / ecs / logs / http

REPOS = ("ligoj/ligoj-api", "ligoj/ligoj-ui")


def newest_images(aws: Aws) -> dict[str, dict]:
    out = {}
    for repo in REPOS:
        data = aws.try_call("ecr", "describe-images", "--repository-name", repo)
        details = sorted((data or {}).get("imageDetails", []), key=lambda d: d["imagePushedAt"])
        if details:
            d = details[-1]
            out[repo] = {"digest": d["imageDigest"], "tags": d.get("imageTags", []), "pushed": d["imagePushedAt"]}
    return out


def short(digest: str) -> str:
    return digest.replace("sha256:", "")[:12]


def service(aws: Aws, app: str) -> dict:
    data = aws("ecs", "describe-services", "--cluster", app, "--services", app)
    return data["services"][0]


def running_task_images(aws: Aws, app: str) -> dict[str, str]:
    """container name -> image digest of the RUNNING tasks (empty when none)."""
    arns = aws.try_call("ecs", "list-tasks", "--cluster", app, "--service-name", app, "--desired-status", "RUNNING")
    arns = (arns or {}).get("taskArns", [])
    if not arns:
        return {}
    tasks = aws("ecs", "describe-tasks", "--cluster", app, "--tasks", *arns)
    images = {}
    for task in tasks["tasks"]:
        for c in task["containers"]:
            images[c["name"]] = c.get("imageDigest") or c.get("image", "").split("@")[-1]
    return images


def stopped_task_reasons(aws: Aws, app: str, since: dt.datetime) -> list[str]:
    arns = aws.try_call("ecs", "list-tasks", "--cluster", app, "--desired-status", "STOPPED")
    arns = (arns or {}).get("taskArns", [])[:10]
    if not arns:
        return []
    tasks = aws.try_call("ecs", "describe-tasks", "--cluster", app, "--tasks", *arns) or {"tasks": []}
    reasons = []
    for t in tasks["tasks"]:
        stopped = t.get("stoppedAt", "")
        if stopped and dt.datetime.fromisoformat(stopped.replace("Z", "+00:00")) < since:
            continue
        codes = ", ".join(f"{c['name']}:exit={c.get('exitCode', '?')}" for c in t.get("containers", []))
        reason = t.get("stoppedReason", "?")
        if reason.startswith("Scaling activity initiated by (deployment"):
            reason += " (expected: previous task replaced by the rolling update)"
        reasons.append(f"{reason} [{codes}]")
    return reasons


class LogScanner:
    """Follows the WARN/ERROR lines of both containers since a given instant.

    Only the log LEVEL decides: ERROR/FATAL lines and stack traces are errors (they
    fail the release), WARN lines are reported but never fatal, and a benign INFO
    line that merely contains 'Error' or 'Exception' in its text is ignored."""

    PATTERN = "?WARN ?ERROR ?Exception ?FATAL"
    LEVEL = re.compile(r"\b(TRACE|DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\b")
    TRACE = re.compile(r"^(\s+at |Caused by: |[A-Za-z0-9_.$]+(Exception|Error): )")

    @classmethod
    def classify(cls, msg: str) -> str | None:
        """'error', 'warning' or None (not worth reporting)."""
        m = cls.LEVEL.search(msg[:120])
        level = m.group(1) if m else None
        if level in ("ERROR", "FATAL"):
            return "error"
        if level in ("WARN", "WARNING"):
            return "warning"
        if level is None and cls.TRACE.search(msg):
            return "error"
        return None

    def __init__(self, aws: Aws, environment: str, since: dt.datetime):
        self.aws = aws
        self.groups = {"api": f"/ecs/ligoj-api-{environment}", "ui": f"/ecs/ligoj-ui-{environment}"}
        self.since_ms = int(since.timestamp() * 1000)
        self.seen: set[str] = set()
        self.counts = {"api": 0, "ui": 0}
        self.errors = 0
        self.warnings = 0

    def poll(self, max_print: int = 20) -> None:
        printed = 0
        for name, group in self.groups.items():
            data = self.aws.try_call(
                "logs", "filter-log-events", "--log-group-name", group,
                "--start-time", str(self.since_ms), "--filter-pattern", self.PATTERN, "--limit", "200")
            if data is None:
                continue
            for ev in data.get("events", []):
                if ev["eventId"] in self.seen:
                    continue
                self.seen.add(ev["eventId"])
                msg = ev["message"].rstrip()
                kind = self.classify(msg)
                if kind is None:
                    continue
                self.counts[name] += 1
                is_error = kind == "error"
                self.errors += is_error
                self.warnings += not is_error
                if printed < max_print:
                    ts = dt.datetime.fromtimestamp(ev["timestamp"] / 1000).strftime("%H:%M:%S")
                    tag = red(f"[{name}]") if is_error else yellow(f"[{name}]")
                    log(f"{tag} {ts} {msg[:220]}")
                    printed += 1

    def summary(self) -> str:
        return (f"api: {self.counts['api']} lines, ui: {self.counts['ui']} "
                f"(warnings: {self.warnings}, errors: {self.errors})")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


def http_probe(url: str, cookie: str | None = None) -> tuple[int, str]:
    req = urllib.request.Request(url, headers={"User-Agent": "ligoj-release/1.0"})
    if cookie:
        req.add_header("Cookie", cookie)
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=15) as resp:
            return resp.status, resp.headers.get("Location", "")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location", "")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return 0, str(e)


def readiness(dns: str, cookie: str | None, minutes: int) -> bool:
    """/favicon.ico must answer 200 (UI container up through CloudFront/ALB) and /
    must redirect to the Cognito login (private route, ALB authenticate action)."""
    phase = Phase("HTTP readiness")
    deadline = time.monotonic() + minutes * 60
    while True:
        code_fav, _ = http_probe(f"https://{dns}/favicon.ico", cookie)
        code_root, location = http_probe(f"https://{dns}/", cookie)
        ok = code_fav == 200 and code_root == 302 and "oauth2/authorize" in location
        if ok:
            log(f"https://{dns}/favicon.ico -> 200, / -> 302 to Cognito")
            phase.done()
            return True
        status_line(f"favicon={code_fav} root={code_root} {dim(location[:60])} ... retrying")
        if time.monotonic() > deadline:
            log(red(f"favicon={code_fav} root={code_root} location={location[:100]}"))
            if code_root == 403 and not cookie:
                log(yellow("403 with no WAF bypass cookie: pass --health-cookie or --tfvars (web_acl_secret_cookie)"))
            phase.done(False)
            return False
        time.sleep(10)


def recent_container_logs(aws: Aws, environment: str, since: dt.datetime, lines: int = 25) -> None:
    """Last lines of each container (all levels), to see how a task died or what it printed."""
    since_ms = int(since.timestamp() * 1000)
    for name in ("api", "ui"):
        group = f"/ecs/ligoj-{name}-{environment}"
        data = aws.try_call("logs", "filter-log-events", "--log-group-name", group, "--start-time", str(since_ms))
        events = (data or {}).get("events", [])
        log(bold(f"{group}: last {min(lines, len(events))} of {len(events)} lines since {since.strftime('%H:%M:%S')} UTC"))
        for ev in events[-lines:]:
            ts = dt.datetime.fromtimestamp(ev["timestamp"] / 1000).strftime("%H:%M:%S")
            log(dim(f"  [{name}] {ts} ") + ev["message"].rstrip()[:220])


def diagnose_service(aws: Aws, app: str, environment: str, since: dt.datetime) -> None:
    """Why is the application not healthy: ECS view, target group view, container logs."""
    log(bold("Diagnosis"))
    svc = aws.try_call("ecs", "describe-services", "--cluster", app, "--services", app)
    if svc and svc.get("services"):
        s = svc["services"][0]
        for d in s.get("deployments", []):
            log(f"deployment {d['status']}: {d.get('rolloutState', '?')} running {d['runningCount']}/{d['desiredCount']}"
                f" pending {d.get('pendingCount', 0)} failed {d.get('failedTasks', 0)} {dim(d['taskDefinition'].split('/')[-1])}")
            if d.get("rolloutStateReason"):
                log(red(f"  {d['rolloutStateReason']}"))
        for ev in s.get("events", [])[:8]:
            log(dim(f"  event {ev['createdAt'][11:19]} ") + ev["message"][:200])
    for reason in stopped_task_reasons(aws, app, since):
        log((dim if "(expected:" in reason else red)(f"stopped task: {reason}"))
    tgs = aws.try_call("elbv2", "describe-target-groups", "--names", f"ligoj-ui-{environment}")
    for tg in (tgs or {}).get("TargetGroups", []):
        health = aws.try_call("elbv2", "describe-target-health", "--target-group-arn", tg["TargetGroupArn"])
        targets = (health or {}).get("TargetHealthDescriptions", [])
        if not targets:
            log(red(f"target group {tg['TargetGroupName']}: no registered target"))
        for t in targets:
            th = t["TargetHealth"]
            state = th["State"]
            mark = green(state) if state == "healthy" else red(state)
            log(f"target {t['Target']['Id']}:{t['Target'].get('Port', '')} {mark} {th.get('Reason', '')} {th.get('Description', '')}")
    recent_container_logs(aws, environment, since)


# --------------------------------------------------------------------------- pipelines (diagnostics)

def latest_action(aws: Aws, pipeline: str, execution_id: str) -> dict | None:
    data = aws.try_call("codepipeline", "list-action-executions", "--pipeline-name", pipeline,
                        "--filter", f"pipelineExecutionId={execution_id}")
    details = (data or {}).get("actionExecutionDetails", [])
    return details[0] if details else None  # newest first


def build_log_errors(aws: Aws, app: str, external_id: str, lines: int = 40) -> list[str]:
    """CodeBuild id 'project:uuid' -> the error lines of its log stream."""
    project, _, uuid = external_id.partition(":")
    prefix = project.replace(f"{app}-deploy-", "")  # docker | apply | plan
    data = aws.try_call("logs", "get-log-events", "--log-group-name", f"/codebuild/{app}-deploy",
                        "--log-stream-name", f"{prefix}/{uuid}", "--start-from-head")
    msgs = [e["message"].rstrip() for e in (data or {}).get("events", [])]
    hits = [m for m in msgs if re.search(r"Error|error:|FAILED|Exception", m)]
    return hits[-lines:] if hits else msgs[-lines:]


def diagnose_pipeline(aws: Aws, app: str, pipeline: str, execution_id: str) -> None:
    action = latest_action(aws, pipeline, execution_id)
    if not action:
        return
    result = action.get("output", {}).get("executionResult", {})
    log(red(f"{pipeline} / {action['stageName']}.{action['actionName']}: {action['status']}"))
    if result.get("externalExecutionSummary"):
        log(red(result["externalExecutionSummary"][:300]))
    ext = result.get("externalExecutionId", "")
    if ":" in ext:
        for line in build_log_errors(aws, app, ext):
            log(dim("  | ") + line[:220])


class BuildLogTail:
    """Incrementally reads a CodeBuild log stream and surfaces the lines worth showing."""

    # Lines printed permanently (after stripping the BuildKit '#12 34.5 ' prefix)
    INTERESTING = re.compile(
        r"^\[Container\].*(Entering phase|Phase complete|COMMAND_EXECUTION_ERROR)"      # CodeBuild phases
        r"|^Step \d+/\d+ :"                                                          # classic docker build
        r"|^#\d+ \[[^\]]+\] (RUN|COPY|FROM)"                                          # BuildKit steps
        r"|^(Successfully (built|tagged)|.*: digest: sha256:.*size:)"                # image built / pushed
        r"|^\[INFO\] (Building |BUILD (SUCCESS|FAILURE)|--- )|^\[ERROR\]"            # Maven milestones
        r"|^(\S+: (Creating|Modifying|Destroying|Creation complete|Modifications complete|Destruction complete))"
        r"|^\S+: Still (creating|modifying|destroying)\.\.\. \[\d+m0s elapsed\]"       # terraform, once a minute
        r"|^(Plan:|Apply complete|Error:|Waiting for SES|Data API not ready|prepare-build\.sh:)")
    PREFIX = re.compile(r"^#\d+ [\d.]+ ")

    def __init__(self, aws: Aws, app: str, external_id: str):
        project, _, uuid = external_id.partition(":")
        self.aws = aws
        self.group = f"/codebuild/{app}-deploy"
        self.stream = f"{project.replace(f'{app}-deploy-', '')}/{uuid}"
        self.token: str | None = None
        self.last_line = ""
        self.last_shown = ""
        self.last_print = time.monotonic()

    def poll(self, max_print: int = 15) -> None:
        args = ["logs", "get-log-events", "--log-group-name", self.group, "--log-stream-name", self.stream,
                "--start-from-head", "--limit", "500"]
        if self.token:
            args += ["--next-token", self.token]
        data = self.aws.try_call(*args) if self.token else self._first(args)
        if not data:
            return
        self.token = data.get("nextForwardToken", self.token)
        printed = 0
        for ev in data.get("events", []):
            line = self.PREFIX.sub("", ev["message"].rstrip())
            if not line:
                continue
            self.last_line = line
            # BuildKit re-emits a step header each time the step progresses: show it once
            if printed < max_print and line != self.last_shown and self.INTERESTING.search(line):
                self.last_shown = line
                log(dim("  | ") + line[:200])
                printed += 1
                self.last_print = time.monotonic()
        # Heartbeat: something is happening even when nothing matched for a while
        if printed == 0 and self.last_line and time.monotonic() - self.last_print > 120:
            log(dim("  | ... ") + self.last_line[:180])
            self.last_print = time.monotonic()

    def _first(self, args: list[str]):
        # The stream appears a few seconds after the build starts: silent until then
        try:
            return self.aws(*args)
        except AwsError:
            return None


# --------------------------------------------------------------------------- release workflow

STATE_PHASE = {
    "StartBuild": "build", "WaitBuild": "build", "GetBuild": "build",
    "StartDeploy": "deploy", "WaitDeploy": "deploy", "GetDeploy": "deploy",
    "CheckService": "rollout", "WaitService": "rollout",
}


def find_state_machine(aws: Aws, name: str) -> str:
    data = aws("stepfunctions", "list-state-machines")
    for sm in data["stateMachines"]:
        if sm["name"] == name:
            return sm["stateMachineArn"]
    sys.exit(red(f"State machine '{name}' not found: apply the pipeline/ sub-project first"))


def run_release(aws: Aws, cfg: argparse.Namespace, app: str, environment: str) -> tuple[bool, dt.datetime]:
    start_utc = dt.datetime.now(dt.timezone.utc)
    baseline = newest_images(aws)
    for repo, img in baseline.items():
        log(f"ECR {repo}: current newest {short(img['digest'])} {img['tags']} ({img['pushed'][:19]})")

    arn = find_state_machine(aws, f"{app}-deploy-release")
    execution = aws("stepfunctions", "start-execution", "--state-machine-arn", arn,
                    "--input", json.dumps({"build": not cfg.skip_build}))
    exec_arn = execution["executionArn"]
    log(f"release execution {exec_arn.split(':')[-1]} started (build={'no' if cfg.skip_build else 'yes'})")

    pipelines = {"build": f"{app}-deploy-docker", "deploy": f"{app}-deploy"}
    exec_ids: dict[str, str] = {}
    seen_events: set[int] = set()
    phase_obj: Phase | None = None
    phase_name = ""
    scanner: LogScanner | None = None
    deploy_started: dt.datetime | None = None
    final_status = "RUNNING"
    last_action_key = ""
    tail: BuildLogTail | None = None
    deadline = time.monotonic() + cfg.timeout * 60

    while True:
        desc = aws("stepfunctions", "describe-execution", "--execution-arn", exec_arn)
        final_status = desc["status"]
        history = aws.try_call("stepfunctions", "get-execution-history", "--execution-arn", exec_arn,
                               "--max-results", "100", "--reverse-order") or {"events": []}
        for ev in reversed(history["events"]):
            if ev["id"] in seen_events:
                continue
            seen_events.add(ev["id"])
            entered = ev.get("stateEnteredEventDetails", {}).get("name")
            if entered:
                new_phase = STATE_PHASE.get(entered, "")
                if new_phase and new_phase != phase_name:
                    if phase_obj:
                        phase_obj.done()
                    labels = {"build": "Docker images (CodeBuild)", "deploy": "Terraform deploy (CodeBuild)",
                              "rollout": "ECS rollout confirmation"}
                    phase_obj, phase_name = Phase(labels[new_phase]), new_phase
                    if new_phase == "deploy":
                        deploy_started = dt.datetime.now(dt.timezone.utc)
                        scanner = LogScanner(aws, environment, deploy_started)
                        images = newest_images(aws)
                        for repo, img in images.items():
                            changed = baseline.get(repo, {}).get("digest") != img["digest"]
                            mark = green("new") if changed else yellow("unchanged")
                            log(f"ECR {repo}: {mark} {short(img['digest'])} {img['tags']}")
                        if not cfg.skip_build and all(baseline.get(r, {}).get("digest") == i["digest"] for r, i in images.items()):
                            log(yellow("the build pushed no new digest: the deploy will roll out the same images"))
            exited = ev.get("stateExitedEventDetails", {})
            if exited.get("name") in ("StartBuild", "StartDeploy") and exited.get("output"):
                out = json.loads(exited["output"])
                for key, ph in (("build_execution", "build"), ("deploy_execution", "deploy")):
                    if key in out and ph not in exec_ids:
                        exec_ids[ph] = out[key]["PipelineExecutionId"]
                        log(f"{pipelines[ph]} execution {exec_ids[ph]}")

        if final_status != "RUNNING":
            break

        # live detail of the current phase: stage transitions, then the build log itself
        if phase_name in ("build", "deploy") and phase_name in exec_ids:
            action = latest_action(aws, pipelines[phase_name], exec_ids[phase_name])
            if action:
                key = f"{action['stageName']}.{action['actionName']} {action['status']}"
                if key != last_action_key:
                    log(f"{pipelines[phase_name]}: {key}")
                    last_action_key = key
                ext = action.get("output", {}).get("executionResult", {}).get("externalExecutionId", "")
                if ":" in ext and (tail is None or tail.stream.split("/")[-1] != ext.partition(":")[2]):
                    tail = BuildLogTail(aws, app, ext)
                    log(dim(f"tailing CloudWatch {tail.group} {tail.stream}"))
                if tail:
                    tail.poll()
                status_line(f"{key} {dim('(' + elapsed(phase_obj.start) + ')')} {dim(tail.last_line[:100] if tail else '')}")
        if phase_name in ("deploy", "rollout"):
            svc = aws.try_call("ecs", "describe-services", "--cluster", app, "--services", app)
            if svc:
                deps = svc["services"][0]["deployments"]
                primary = next((d for d in deps if d["status"] == "PRIMARY"), deps[0])
                status_line(f"ECS {primary.get('rolloutState', '?')} running {primary['runningCount']}/{primary['desiredCount']}"
                            f" failed={primary.get('failedTasks', 0)} deployments={len(deps)} {dim('(' + elapsed(phase_obj.start) + ')')}")
            if scanner:
                scanner.poll()

        if time.monotonic() > deadline:
            log(red(f"timeout after {cfg.timeout} minutes; the execution keeps running server-side"))
            final_status = "CLIENT_TIMEOUT"
            break
        time.sleep(10)

    if phase_obj:
        phase_obj.done(final_status == "SUCCEEDED")

    if final_status != "SUCCEEDED":
        log(red(f"release execution {final_status}"))
        if desc.get("error") or desc.get("cause"):
            log(red(f"{desc.get('error', '')}: {desc.get('cause', '')}"))
        failed_phase = phase_name
        if failed_phase in exec_ids:
            diagnose_pipeline(aws, app, pipelines[failed_phase], exec_ids[failed_phase])
        if failed_phase in ("deploy", "rollout") and deploy_started:
            if scanner:
                scanner.poll()
                log(scanner.summary())
            diagnose_service(aws, app, environment, deploy_started)
        return False, deploy_started or start_utc

    return True, deploy_started or start_utc


def verify(aws: Aws, cfg: argparse.Namespace, app: str, environment: str, since: dt.datetime) -> bool:
    ok = True
    phase = Phase("Running images vs ECR")
    newest = newest_images(aws)
    running = running_task_images(aws, app)
    if not running:
        log(red("no RUNNING task"))
        ok = False
    for container, digest in running.items():
        repo = f"ligoj/{container}"
        expected = newest.get(repo, {}).get("digest", "")
        same = digest == expected
        mark = green("current") if same else yellow("NOT the newest ECR image")
        log(f"{container}: running {short(digest)} -> {mark} (newest {short(expected)})")
        ok = ok and same
    phase.done(ok)

    ok = readiness(cfg.dns, cfg.health_cookie, cfg.readiness_minutes) and ok

    phase = Phase(f"Container logs ({cfg.grace}s grace)")
    scanner = LogScanner(aws, environment, since)
    end = time.monotonic() + cfg.grace
    while True:
        scanner.poll()
        status_line(f"watching /ecs/ligoj-*-{environment}: {scanner.summary()}")
        if time.monotonic() > end:
            break
        time.sleep(10)
    log(scanner.summary())
    note = "" if scanner.errors == 0 else red("errors logged, review above")
    if scanner.errors == 0 and scanner.warnings:
        note = yellow(f"{scanner.warnings} warning(s), not blocking")
    phase.done(scanner.errors == 0, note)
    healthy = ok and scanner.errors == 0
    if not healthy:
        diagnose_service(aws, app, environment, since)
    return healthy


# --------------------------------------------------------------------------- main

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    default_tfvars = os.path.join(os.path.dirname(here), "main-private.saas.tfvars")
    p = argparse.ArgumentParser(description="Build, deploy and watch a Ligoj release")
    p.add_argument("--profile", default=os.environ.get("AWS_PROFILE", "kloudy-website"))
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "eu-west-3"))
    p.add_argument("--tfvars", default=default_tfvars, help="tfvars providing dns / web_acl_secret_cookie / environment")
    p.add_argument("--dns", help="public host to probe (default: 'dns' of the tfvars)")
    p.add_argument("--health-cookie", help="WAF bypass cookie value (default: web_acl_secret_cookie of the tfvars)")
    p.add_argument("--skip-build", action="store_true", help="deploy the images already in ECR, no docker build")
    p.add_argument("--check-only", action="store_true", help="only run the post-deploy verification")
    p.add_argument("--timeout", type=int, default=75, help="minutes to wait for the release execution")
    p.add_argument("--readiness-minutes", type=int, default=10, help="minutes to wait for the HTTP readiness")
    p.add_argument("--grace", type=int, default=90, help="seconds of container log watching after readiness")
    p.add_argument("--non-interactive", action="store_true", help="never prompt (no SSO login offer)")
    cfg = p.parse_args()

    tfvars = read_tfvars(cfg.tfvars)
    application = tfvars.get("application", "ligoj")
    environment = tfvars.get("environment", "prod")
    app = f"{application}-{environment}"
    cfg.dns = cfg.dns or tfvars.get("dns") or f"{application}.{tfvars.get('dns_zone', '')}"
    cookie_value = cfg.health_cookie or tfvars.get("web_acl_secret_cookie")
    cfg.health_cookie = f"waf_bypass={cookie_value}" if cookie_value else None
    cfg.region = tfvars.get("region", cfg.region)

    aws = Aws(cfg.profile, cfg.region)
    log(bold(f"Ligoj release: {app} in {cfg.region}, https://{cfg.dns}"))
    interactive = not cfg.non_interactive and sys.stdin.isatty()
    check_credentials(aws, interactive=interactive)
    if not cfg.check_only:
        check_ci_tfvars(aws, app, cfg.tfvars, interactive)

    try:
        if cfg.check_only:
            since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=30)
            ok = verify(aws, cfg, app, environment, since)
        else:
            ok, since = run_release(aws, cfg, app, environment)
            if ok:
                ok = verify(aws, cfg, app, environment, since)
    except KeyboardInterrupt:
        print()
        log(yellow("interrupted: a started release execution keeps running server-side "
                   "(aws stepfunctions list-executions --state-machine-arn ... / stop-execution)"))
        return 130
    except AwsError as e:
        log(red(str(e)))
        return 1

    print()
    log(bold("Summary"))
    for name, took, state in Phase.records:
        mark = green("ok    ") if state == "ok" else red("FAILED")
        print(f"   {mark} {took}  {name}")
    print(f"   total {elapsed()}")
    log(green("release ready") if ok else red("release NOT healthy"))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Covers the prompts and the SSO login subprocess too: no stack trace on Ctrl+C
        print()
        print(yellow("interrupted"))
        sys.exit(130)
