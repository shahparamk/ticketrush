<#
.SYNOPSIS
  Start, stop, or connect to the TicketRush Jenkins server.
.EXAMPLE
  .\scripts\jenkins.ps1 start      # boot the instance
  .\scripts\jenkins.ps1 password   # print the first-login admin password
  .\scripts\jenkins.ps1 connect    # tunnel http://localhost:8080 through SSM (leave it running)
  .\scripts\jenkins.ps1 stop       # stop the instance (only the disk keeps costing)
  .\scripts\jenkins.ps1 status
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("start", "stop", "connect", "status", "password")]
    [string]$Action
)
$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$region = "us-east-1"
$repoRoot = (git rev-parse --show-toplevel).Trim()
$id = (terraform "-chdir=$repoRoot/infra/ci/jenkins" output -raw instance_id).Trim()

switch ($Action) {
    "start" {
        aws ec2 start-instances --instance-ids $id --region $region --output text | Out-Null
        Write-Host "Starting $id..."
        aws ec2 wait instance-running --instance-ids $id --region $region
        Write-Host "Running. Give Jenkins ~1-2 minutes, then: .\scripts\jenkins.ps1 connect" -ForegroundColor Green
    }
    "stop" {
        aws ec2 stop-instances --instance-ids $id --region $region --output text | Out-Null
        Write-Host "Stopping $id (only the disk keeps costing)." -ForegroundColor Green
    }
    "status" {
        aws ec2 describe-instances --instance-ids $id --region $region --query "Reservations[0].Instances[0].State.Name" --output text
    }
    "connect" {
        Write-Host "Open http://localhost:8080 in your browser. Press Ctrl+C here to close the tunnel." -ForegroundColor Cyan
        aws ssm start-session --target $id --region $region --document-name AWS-StartPortForwardingSession --parameters "portNumber=8080,localPortNumber=8080"
    }
    "password" {
        $cmd = aws ssm send-command --instance-ids $id --region $region --document-name AWS-RunShellScript --parameters "commands=cat /opt/jenkins_home/secrets/initialAdminPassword" --query "Command.CommandId" --output text
        Start-Sleep 3
        aws ssm get-command-invocation --command-id $cmd --instance-id $id --region $region --query "StandardOutputContent" --output text
    }
}