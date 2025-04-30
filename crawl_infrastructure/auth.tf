# module "aws_auth" {
#   source                    = "terraform-aws-modules/eks/aws//modules/aws-auth"
resource "aws_eks_access_entry" "console_user" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = "arn:aws:iam::411623750878:user/olexi"
}

resource "aws_eks_access_policy_association" "console_user_admin" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = aws_eks_access_entry.console_user.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AWSAdministratorAccess"
  access_scope { type = "cluster" }
}