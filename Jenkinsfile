// TicketRush deploy pipeline.
// Runs on throwaway Docker agents using the Jenkins instance role (no keys anywhere).
//   Any branch: build + test every service, terraform plan (dev)
//   main only:  plan -> manual approval -> apply the exact saved plan -> smoke-test both regions
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
    stage('Build + Plan (dev)') {
      agent { label 'docker-agent' }
      steps {
        sh '''
          set -eu
          for svc in services/*/; do
            echo "=== $svc"
            (cd "$svc" && npm ci --no-audit --no-fund && npm run typecheck && npm test && npm run build)
          done
        '''
        dir(env.TF_DIR) {
          script { tfInit() }
          sh "terraform plan -input=false -lock-timeout=60s -var app_version=${env.GIT_COMMIT.take(7)} -out=tfplan"
        }
        // The apply must use the SAME bundles the plan was made from
        stash name: 'plan', includes: "${env.TF_DIR}/tfplan,services/*/dist/**"
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

    stage('Apply + Smoke test (dev)') {
      when {
        beforeAgent true // check the branch BEFORE starting an agent, so branches don't start one for nothing
        branch 'main'
      }
      agent { label 'docker-agent' }
      steps {
        unstash 'plan'
        dir(env.TF_DIR) {
          script { tfInit() }
          sh 'terraform apply -input=false -lock-timeout=60s tfplan'
          // Each region must answer, report ITS OWN region, and (for the seat map) show the demo event's 100 seats
          sh '''
            set -eu
            check() {
              url="$1"; region="$2"; seats="$3"
              body=$(curl -fsS --retry 5 --retry-delay 3 --retry-all-errors "$url")
              echo "$url -> $(echo "$body" | head -c 300)"
              echo "$body" | node -e '
                let s=""; process.stdin.on("data", d => s += d).on("end", () => {
                  const b = JSON.parse(s), [region, seats] = process.argv.slice(1);
                  if (b.region !== region) { console.error("expected region " + region + ", got " + b.region); process.exit(1); }
                  if (seats !== "-" && b.summary?.total !== Number(seats)) { console.error("expected " + seats + " seats, got " + b.summary?.total); process.exit(1); }
                });' "$region" "$seats"
            }
            check "$(terraform output -raw hello_url_primary)"   us-east-1 -
            check "$(terraform output -raw hello_url_secondary)" us-west-2 -
            check "$(terraform output -raw ticketing_url_primary)/events/demo-boston/seats"   us-east-1 100
            check "$(terraform output -raw ticketing_url_secondary)/events/demo-boston/seats" us-west-2 100
          '''
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