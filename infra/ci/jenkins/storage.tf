# Jenkins data on its own disk: the server can be replaced at any time (immutable),
# while build history and job state survive on this volume.
resource "aws_ebs_volume" "jenkins_home" {
  #checkov:skip=CKV_AWS_189:Encrypted with the AWS-managed EBS key (same as the root disk); a CMK for CI build data isn't worth the extra key management here
  availability_zone = aws_subnet.public.availability_zone # must match the instance's AZ
  size              = 20
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.name}-home"
  }

  lifecycle {
    prevent_destroy = true # never delete Jenkins data by accident
  }
}

resource "aws_volume_attachment" "jenkins_home" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.jenkins_home.id
  instance_id                    = aws_instance.jenkins.id
  stop_instance_before_detaching = true # detach cleanly when the server is replaced
}