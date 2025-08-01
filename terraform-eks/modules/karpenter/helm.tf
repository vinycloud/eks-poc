resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.5.0"
  wait                = false

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.this.arn
  }

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.endpoint
  }

  set {
    name  = "enable_pod_identity"
    value = "true"
  }

  set {
    name  = "create_pod_identity_association"
    value = "true"
  }

  set {
    name  = "node_iam_role_additional_policies.AmazonSSMManagedInstanceCore"
    value = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = 1
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = 1
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }

  set {
    name  = "logLevel"
    value = "debug"
  }

  set {
    name  = "settings.aws.defaultInstanceProfile"
    value = aws_iam_instance_profile.karpenter.name
  }

  set {
    name  = "settings.aws.interruptionQueueName"
    value = "${var.cluster_name}-karpenter"
  }

  set {
    name  = "nodeSelector"
    value = ""
  }

  set {
    name  = "tolerations[0].key"
    value = "CriticalAddonsOnly"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "affinity"
    value = ""
  }

  set {
    name  = "tolerations[0].key"
    value = "node-role.kubernetes.io/master"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "controller.tolerations[0].key"
    value = "karpenter.sh/nodepool"
  }
  set {
    name  = "controller.tolerations[0].operator"
    value = "Exists"
  }

}



resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2
      role: ${aws_iam_role.karpenterNodeRole.name}
      amiSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
        - name: "amazon-eks-node-1.32-*"
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      tags:
        karpenter.sh/discovery: ${var.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}



resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["spot", "on-demand"]
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["c", "m", "r", "t"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["2", "4", "8", "16"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-generation"
              operator: Gt
              values: ["3"]
            - key: "node.kubernetes.io/instance-type"
              operator: In
              values: ["t3.medium", "t3.large", "c5.large", "m5.large", "m5.xlarge"]
      limits:
        cpu: 1000
        memory: 1000Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 30s
        expireAfter: 30m
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}





resource "kubectl_manifest" "karpenter_example_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: inflate
      namespace: default
    spec:
      replicas: 0
      selector:
        matchLabels:
          app: inflate
      template:
        metadata:
          labels:
            app: inflate
        spec:
          terminationGracePeriodSeconds: 0
          containers:
            - name: inflate
              image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
              resources:
                requests:
                  cpu: 500m
                  memory: "1Gi"
                limits:
                  cpu: 500m
                  memory: "1Gi"
  YAML

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.karpenter_node_class,
    kubectl_manifest.karpenter_node_pool
  ]
}
