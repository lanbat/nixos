## What and why

<!-- What does this change, and why? Link related issues. -->

## How it was tested

<!-- For example: "evaluated only", or "deployed to my own server". -->

## Checklist

- [ ] Ran `nix fmt`
- [ ] `nix flake check --no-build --all-systems` passes
- [ ] `nix build .#checks.x86_64-linux.assertions` passes (and `.workload-gate` if you have KVM)
- [ ] Docs updated per the checklist in CONTRIBUTING.md (if a service was added or changed)
- [ ] No real IP addresses, domains, keys or plaintext secrets
