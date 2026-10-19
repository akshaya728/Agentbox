import datetime
import boto3

ecs = boto3.client("ecs")


def handler(event, context):
    arns = ecs.list_tasks(cluster="agentbox")["taskArns"]
    if not arns:
        return 0
    now = datetime.datetime.now(datetime.timezone.utc)
    stopped = 0
    for t in ecs.describe_tasks(cluster="agentbox", tasks=arns)["tasks"]:
        if (now - t["createdAt"]).total_seconds() > 600:
            ecs.stop_task(cluster="agentbox", task=t["taskArn"], reason="janitor")
            stopped += 1
    return stopped
