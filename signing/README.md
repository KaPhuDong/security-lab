# Signing Setup - Cosign Key Pair

## Generate key pair (chạy 1 lần local hoặc trong CI)

```bash
# Install cosign
brew install cosign   # macOS
# hoặc: https://docs.sigstore.dev/cosign/system_config/installation/

# Generate key pair
cosign generate-key-pair
# → sinh ra: cosign.key (private) + cosign.pub (public)
```

## Setup GitHub Secrets

Thêm vào repo Settings → Secrets and variables → Actions:
- `COSIGN_PRIVATE_KEY` = nội dung file `cosign.key`
- `COSIGN_PASSWORD`    = passphrase bạn đặt khi generate

## Commit public key

```bash
cp cosign.pub signing/cosign.pub
git add signing/cosign.pub
git commit -m "feat: add cosign public key for image verification"
```

## KHÔNG commit private key

`cosign.key` phải ở trong `.gitignore` — KHÔNG bao giờ commit.

## Verify thủ công

```bash
cosign verify \
  --key signing/cosign.pub \
  ghcr.io/kaphudong/w10-api:<tag>
```
