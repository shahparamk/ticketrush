// TicketRush deploy pipeline.
// Runs on throwaway Docker agents using the Jenkins instance role (no keys anywhere).
//   Any branch: terraform plan (dev)
//   main only:  plan -> manual approval -> apply the exact saved plan
pipeline {
  agent none // each stage picks its own agent, so nothing is held open while waiting for approval

  options {
    timestamps()
    disableConcurrentBuilds()          // one deploy at a time (on top of Terraform's S3 lock)
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    TF_IN_AUTOMATION = 'true'
    AWS_REGION       = 'us-east-1'
    TF_DIR           = 'infra/envs/dev'
  }

  stages {
    stage('Plan (dev)') {
      agent { label 'docker-agent' }
      steps {
        dir(env.TF_DIR) {
          script { tfInit() }
          sh 'terraform plan -input=false -lock-timeout=60s -out=tfplan'
        }
        stash name: 'plan', includes: "${env.TF_DIR}/tfplan"
      }
    }

    stage('Approve') {
      when { branch 'main' }
      steps {
        timeout(time: 15, unit: 'MINUTES') {
          input message: 'Apply this plan to dev?', ok: 'Apply'
        }
      }
    }

    stage('Apply (dev)') {
      when { branch 'main' }
      agent { label 'docker-agent' }
      steps {
        unstash 'plan'
        dir(env.TF_DIR) {
          script { tfInit() }
          sh 'terraform apply -input=false -lock-timeout=60s tfplan'
        }
      }
    }
  }
}

// Backend and account come from the instance role at run time: no secrets in Git or Jenkins.
def tfInit() {
  sh '''
    set -eu
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    printf 'bucket = "ticketrush-tfstate-%s"\n' "$ACCOUNT_ID" > backend.hcl
    printf 'account_id = "%s"\n' "$ACCOUNT_ID" > terraform.tfvars
    terraform init -input=false -backend-config=backend.hcl
  '''
}