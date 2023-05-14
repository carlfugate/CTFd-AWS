provider "aws" {
  region = local.region
}

locals {
  prefix     = "ctfd"
  rds_user   = "ctfd_admin"
  rds_pass   = "StrongPasswordHere"
  region     = "us-east-1"
  ctfd_image = "ctfd/ctfd:3.5.1"
  ctfd_secret_key = "JusT@bunch0fR@nd0mStuff!" #This is needed if you will be running more than one front end instance
}



####################################################
# Setup VPC, Subnets and Internet GW for CTFd
####################################################

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "${local.prefix}-vpc"
  }
}

resource "aws_subnet" "public1" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.prefix}-public1-subnet"
  }
}

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.prefix}-public2-subnet"
  }
}

resource "aws_subnet" "private_ecs" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "${local.prefix}-private-ecs-subnet"
  }
}

resource "aws_subnet" "private_rds1" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "${local.prefix}-private-rds-subnet"
  }
}

resource "aws_subnet" "private_rds2" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.5.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "${local.prefix}-private-rds-subnet"
  }
}

# Setup Internet for Public Subnets
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.prefix}-internet-gateway"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.prefix}-public-route-table"
  }
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public1_subnet" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public2_subnet" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}

# Setup Internet access for the ECS subnet to get the images from docker.io

resource "aws_eip" "nat" {
  vpc = true
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public1.id
}

resource "aws_route_table" "private_ecs" {
  vpc_id = aws_vpc.this.id
}

resource "aws_route" "private_ecs_nat" {
  route_table_id         = aws_route_table.private_ecs.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private_ecs" {
  subnet_id      = aws_subnet.private_ecs.id
  route_table_id = aws_route_table.private_ecs.id
}


####################################################
# Deploy ALB for ECS Cluster for CTFd
####################################################

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb"
  description = "Allow inbound traffic for ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public1.id, aws_subnet.public2.id]
}

resource "aws_lb_target_group" "this" {
  name        = "${local.prefix}-target-group"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200-399" # Add 302 as a valid code for new CTFd installations
  }
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

####################################################
# Deploy ECS Fargate Cluster for CTFd
####################################################

resource "aws_ecs_cluster" "this" {
  name = "${local.prefix}-cluster"
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${local.prefix}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.ecs_execution_role.arn

  depends_on = [
  aws_iam_role_policy_attachment.ecs_execution_role_policy_attachment]

  container_definitions = jsonencode([
    {
      name  = "${local.prefix}-container"
      image = "${local.ctfd_image}"
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        # Pass in the RDS endpoint to the CTFd task
        {
          name  = "DATABASE_URL"
          value = "mysql+pymysql://${aws_db_instance.this.username}:${aws_db_instance.this.password}@${aws_db_instance.this.endpoint}/ctfd"

        },
        # Pass in the Redis endpoint to the CTFd task
        {
          name  = "REDIS_URL"
          value = "redis://${aws_elasticache_cluster.this.cache_nodes.0.address}:6379"
        },
        {
          name = "SECRET_KEY"
          value = "${local.ctfd_secret_key}"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-region"        = local.region
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-stream-prefix" = "ecs-${local.prefix}"
        }
      }
    }
  ])
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "${local.prefix}-logs"
  retention_in_days = 14
}

# Create IAM role to allow ECS to do logging
resource "aws_iam_role" "ecs_execution_role" {
  name = "${local.prefix}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.ecs_execution_role.name
}


resource "aws_ecs_service" "this" {
  name            = "${local.prefix}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private_ecs.id]
    security_groups  = [aws_security_group.alb.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "${local.prefix}-container"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.this, aws_elasticache_cluster.this, aws_db_instance.this]
}


####################################################
# Deploy RDS Cluster for CTFd
####################################################

resource "aws_db_subnet_group" "this" {
  name       = "${local.prefix}-db-subnet-group"
  subnet_ids = [aws_subnet.private_rds1.id, aws_subnet.private_rds2.id]

  tags = {
    Name = "${local.prefix}-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.prefix}-rds"
  description = "Allow inbound traffic for RDS"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
}

resource "aws_db_instance" "this" {
  allocated_storage          = 20
  storage_type               = "gp2"
  engine                     = "mysql"
  engine_version             = "8.0"
  instance_class             = "db.t2.micro"
  db_name                    = "${local.prefix}_rds"
  username                   = local.rds_user
  password                   = local.rds_pass
  vpc_security_group_ids     = [aws_security_group.rds.id]
  db_subnet_group_name       = aws_db_subnet_group.this.name
  identifier                 = "${local.prefix}-rds"
  skip_final_snapshot        = true
  publicly_accessible        = false
  multi_az                   = false
  backup_retention_period    = 0
  auto_minor_version_upgrade = true

  tags = {
    Name = "${local.prefix}-rds"
  }
}


####################################################
# Deploy Redis Cluster for CTFd
####################################################

resource "aws_security_group" "elasticache" {
  name        = "${local.prefix}-elasticache-sg"
  description = "ElastiCache security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = {
    Name = "${local.prefix}-elasticache-sg"
  }
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.prefix}-elasticache-subnet-group"
  subnet_ids = [aws_subnet.private_rds1.id, aws_subnet.private_rds2.id]
}

resource "aws_elasticache_cluster" "this" {
  cluster_id           = "${local.prefix}-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis6.x"
  engine_version       = "6.x"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.elasticache.id]
}
