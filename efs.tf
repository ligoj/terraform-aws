resource "aws_efs_file_system" "main" {
  creation_token = local.name
  encrypted      = var.storage_encrypted
  tags           = local.tags
}

# The Ligoj images run as uid/gid 1001 with a read-only root filesystem: the
# access point forces ownership so /home/ligoj is writable by the container
resource "aws_efs_access_point" "ligoj" {
  file_system_id = aws_efs_file_system.main.id
  tags           = merge(local.tags, { "Name" = "${local.name}-ligoj" })

  posix_user {
    uid = 1001
    gid = 1001
  }

  root_directory {
    path = "/ligoj"
    creation_info {
      owner_uid   = 1001
      owner_gid   = 1001
      permissions = "750"
    }
  }
}

resource "aws_efs_mount_target" "main" {
  count           = var.nb_subnets
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = aws_subnet.main[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "Security Group pour EFS"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { "Name" = "${local.name}-efs" })
}
resource "aws_security_group_rule" "efs" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs.id
  security_group_id        = aws_security_group.efs.id
}

resource "aws_security_group_rule" "efs_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.efs.id
}
