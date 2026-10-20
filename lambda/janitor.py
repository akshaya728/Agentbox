import datetime
import os
import boto3

ecs = boto3.client("ecs")
CLUSTER = os.environ.get("CLUSTER", "agentbox")


def handler(event, context):
    arns = ecs.list_tasks(cluster=CLUSTER)["taskArns"]
    if not arns:
        return 0
    now = datetime.datetime.now(datetime.timezone.utc)
    stopped = 0
    for t in ecs.describe_tasks(cluster=CLUSTER, tasks=arns)["tasks"]:
        if (now - t["createdAt"]).total_seconds() > 600:
            ecs.stop_task(cluster=CLUSTER, task=t["taskArn"], reason="janitor")
            stopped += 1
    return stopped