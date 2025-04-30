# module "aws_auth" {
#   source                    = "terraform-aws-modules/eks/aws//modules/aws-auth"
resource "aws_eks_access_entry" "console_user" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = "arn:aws:iam::411623750878:user/olexiy"
}

data "aws_eks_access_policy" "admin" {
  name = "AWSAdministratorAccess"
}

resource "aws_eks_access_policy_association" "console_user_admin" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = aws_eks_access_entry.console_user.principal_arn
  policy_arn = data.aws_eks_access_policy.admin.arn   # <- reuse the looked-up ARN
  access_scope { type = "cluster" }
}