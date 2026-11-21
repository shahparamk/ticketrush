# Latest Amazon Linux 2023 (comes with the SSM agent preinstalled)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "jenkins" {
  #checkov:skip=CKV_AWS_88:Public IP is for OUTBOUND traffic only (no NAT gateway); the security group has no inbound rules
  ami                         = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = true
  ebs_optimized               = true
  monitoring                  = true

  # IMDSv2 only. Hop limit 2 lets the Jenkins *container* reach instance credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    jenkins_image = var.jenkins_image
  })
  user_data_replace_on_change = true

  tags = {
    Name = local.name
  }

  lifecycle {
    ignore_changes = [ami] # don't rebuild Jenkins every time Amazon publishes a new AMI
  }
}

output "instance_id" {
  value = aws_instance.jenkins.id
}