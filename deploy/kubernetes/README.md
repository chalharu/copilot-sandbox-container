# Kubernetes sample manifests

`deploy/kubernetes/control-plane.example/` is the maintained sample entrypoint for the control-plane Kubernetes deployment.

Apply the shipped sample with:

```bash
kubectl apply -k deploy/kubernetes/control-plane.example
```

## Layout

- `control-plane.example/common/`: shared namespaces, RBAC, Secrets, ConfigMaps, Garage S3 resources, and the one-shot `garage-bootstrap` Job.
- `control-plane.example/base/`: one reusable control-plane instance (`PersistentVolumeClaim`, `Service`, and `Deployment`).
- `control-plane.example/overlays/default/`: the customization point for the shipped sample. It layers on top of `base/` and is composed with `common/` by the root `kustomization.yaml`.

The root `control-plane.example/kustomization.yaml` intentionally keeps the operator path simple: edit the sample files, then keep using one `kubectl apply -k ...` command.

## What to edit first

1. Replace placeholder credentials and cluster-specific defaults in `control-plane.example/common/shared-resources.yaml`.
2. Update the published image tags in `control-plane.example/common/shared-resources.yaml` and `control-plane.example/base/control-plane-instance.yaml`.
3. Replace storage classes and PVC sizes with values that match your cluster.
4. If you need to rename the default instance or change its workspace PVC, start in `control-plane.example/overlays/default/kustomization.yaml`.

## Customizing the default overlay

`control-plane.example/overlays/default/kustomization.yaml` contains commented candidate rewrites for the fields that usually differ per instance:

- the workspace PVC name
- the workspace PVC size when the default `5Gi` is not enough
- the `Service` name and selector label
- the `Deployment` name, selector label, pod template label, and mounted workspace PVC name

The comments are intentionally generic. Uncomment the candidate block, replace the `replace-me-*` values with your instance-specific names, and keep the rest of the sample unchanged.

If you need multiple named instances at the same time, copy `overlays/default/` to a sibling overlay and create another composing kustomization next to the shipped root instead of editing the default overlay in place.
