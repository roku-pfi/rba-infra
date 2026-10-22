# EKS with one managed Graviton node group in the private subnets (ADR-0031).

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.f.vpc_id
  subnet_ids = local.f.private_subnet_ids

  # The API is public so `tofu`, `helm` and `kubectl` work from a laptop;
  # authentication is IAM (the SSO role), nothing anonymous.
  endpoint_public_access = true
  # Whoever runs `tofu apply` administers the cluster.
  enable_cluster_creator_admin_permissions = true

  # Per-session cluster: no customer-managed KMS key (US$1/month each, a new
  # one per apply; EKS already encrypts Secrets with an AWS-owned key) and no
  # control-plane logs in CloudWatch (billed per GB, the audit log is chatty).
  create_kms_key              = false
  encryption_config           = null
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  addons = {
    vpc-cni                = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    # Keeps the HPA working as it does on k3d.
    metrics-server = {}
  }

  eks_managed_node_groups = {
    graviton = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = var.node_count
      max_size       = var.node_count + 1
      desired_size   = var.node_count
      # Nodes need the NAT route to bootstrap and pull images. Referencing the
      # route here orders the node group after it, without delaying the rest
      # of the module (a module-level depends_on defers its data sources).
      subnet_ids = [for id in local.f.private_subnet_ids : id if aws_route.private_default.id != ""]
    }
  }
}

# ---------------------------------------------------------------- load balancer controller
# Turns the chart's Ingress objects into one ALB (ADR-0031). Its AWS
# permissions come through EKS Pod Identity, not node credentials.

module "lb_controller_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                            = "aws-load-balancer-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.13.4"

  set = [
    { name = "clusterName", value = module.eks.cluster_name },
    { name = "vpcId", value = local.f.vpc_id },
    { name = "region", value = var.region },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
  ]

  depends_on = [module.eks, module.lb_controller_identity]
}
