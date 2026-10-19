import json, os, secrets, time, urllib.request
import boto3

ecs = boto3.client("ecs")
ec2 = boto3.client("ec2")

CLUSTER = os.environ["CLUSTER"]
TASK_DEF = os.environ["TASK_DEF"]
SUBNET = os.environ["SUBNET_ID"]
SG = os.environ["SG_ID"]
API_KEY = os.environ["API_KEY"]


def resp(code, body):
    return {"statusCode": code,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body)}


def task_ip_and_token(arn):
    t = ecs.describe_tasks(cluster=CLUSTER, tasks=[arn])["tasks"][0]
    eni = next(d["value"] for d in t["attachments"][0]["details"]
               if d["name"] == "networkInterfaceId")
    nic = ec2.describe_network_interfaces(NetworkInterfaceIds=[eni])
    ip = nic["NetworkInterfaces"][0]["Association"]["PublicIp"]
    env = t["overrides"]["containerOverrides"][0]["environment"]
    token = next(e["value"] for e in env if e["name"] == "RUNNER_TOKEN")
    return ip, token


def create():
    token = secrets.token_hex(16)
    r = ecs.run_task(
        cluster=CLUSTER, taskDefinition=TASK_DEF, launchType="FARGATE",
        networkConfiguration={"awsvpcConfiguration": {
            "subnets": [SUBNET], "securityGroups": [SG],
            "assignPublicIp": "ENABLED"}},
        overrides={"containerOverrides": [{
            "name": "runner",
            "environment": [{"name": "RUNNER_TOKEN", "value": token}]}]})
    if not r["tasks"]:
        raise RuntimeError(str(r.get("failures")))
    arn = r["tasks"][0]["taskArn"]
    ecs.get_waiter("tasks_running").wait(
        cluster=CLUSTER, tasks=[arn],
        WaiterConfig={"Delay": 3, "MaxAttempts": 40})
    ip, _ = task_ip_and_token(arn)
    for _ in range(20):
        try:
            urllib.request.urlopen(f"http://{ip}:8080/health", timeout=3)
            break
        except Exception:
            time.sleep(1)
    return arn


def run_cmd(arn, cmd, timeout=10):
    ip, token = task_ip_and_token(arn)
    req = urllib.request.Request(
        f"http://{ip}:8080/exec",
        data=json.dumps({"cmd": cmd, "timeout": timeout}).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, timeout=timeout + 5) as r:
        return json.loads(r.read())


def destroy(arn):
    ecs.stop_task(cluster=CLUSTER, task=arn, reason="agentbox destroy")


def handler(event, context):
    h = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not secrets.compare_digest(h.get("x-api-key", ""), API_KEY):
        return resp(401, {"error": "unauthorized"})
    try:
        body = json.loads(event.get("body") or "{}")
        action = body.get("action")
        if action == "create":
            return resp(200, {"session_id": create()})
        if action == "exec":
            return resp(200, run_cmd(body["session_id"], body["cmd"],
                                     int(body.get("timeout", 10))))
        if action == "destroy":
            destroy(body["session_id"])
            return resp(200, {"destroyed": True})
        if action == "run":
            arn = create()
            try:
                return resp(200, run_cmd(arn, body["cmd"],
                                         int(body.get("timeout", 10))))
            finally:
                destroy(arn)
        return resp(400, {"error": "unknown action"})
    except Exception as e:
        return resp(500, {"error": str(e)})