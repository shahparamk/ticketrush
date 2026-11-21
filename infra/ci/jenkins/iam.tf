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
  description        = "Jenkins on EC2: SSM access now; deploy permissions added in Session 2"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Lets you open a session / port-forward through Systems Manager (no SSH, no open ports)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
  name = local.name
  role = aws_iam_role.jenkins.name
}