# The instance's identity. AWS gives it short-lived credentials automatically:
# no access keys stored anywhere, the same idea as OIDC for GitHub.

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = local.name
  description        = "Jenkins on EC2: SSM access and its own config parameters; deploy permissions added in Session 2b"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Lets you open a session / port-forward through Systems Manager (no SSH, no open ports)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read ONLY Jenkins's own parameters (e.g. the admin password) at boot
data "aws_iam_policy_document" "jenkins_params" {
  statement {
    sid       = "ReadJenkinsParameters"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:us-east-1:${var.account_id}:parameter/ticketrush/jenkins/*"]
  }
}

resource "aws_iam_role_policy" "jenkins_params" {
  name   = "read-jenkins-parameters"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_params.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = local.name
  role = aws_iam_role.jenkins.name
}