# Releases

This page explains how FlowCatalyst releases are cut and where to find them. It deliberately does not
hold a changelog: the authoritative list of what shipped is the project's tags and GitHub releases.

## Where to find releases

Releases are git tags in the repository, one family per released artifact, and each `fcdev` tag has a
GitHub release with the binaries attached.

| Artifact | Tag | Version file |
|---|---|---|
| `fcdev` (the development binary) | `fcdev/vX.Y.Z` | `cmd/fcdev/VERSION` |
| TypeScript SDK | `typescript-sdk/vX.Y.Z` | `clients/typescript-sdk/VERSION` (and `package.json`) |
| Laravel SDK | `laravel-sdk/vX.Y.Z` | `clients/laravel-sdk/VERSION` |
| Java SDK | `java-sdk/vX.Y.Z` | `clients/java-sdk/VERSION` (and `pom.xml`) |

List them with `git tag --list 'fcdev/v*'` (or the prefix you want), or browse the repository's Tags and
Releases pages on GitHub. Release notes for an `fcdev` release are generated on its GitHub release; the
Linux archives are signed, and the notes give the exact `cosign verify-blob` identity.

`fc-server` has no release line of its own. It is built from source or from the repository's
`Dockerfile`, so you deploy it by building a commit you have chosen.

## How a release is cut

Releases are cut from a clean checkout of the main repository, with `make`. Cut one release per command.

```sh
make release-dev BUMP=patch            # fcdev
make release-ts-sdk BUMP=minor         # TypeScript SDK
make release-laravel-sdk BUMP=patch    # Laravel SDK
make release-java-sdk BUMP=patch       # Java SDK
```

`BUMP` is `patch`, `minor`, `major`, or an explicit version such as `0.9.0` or `1.0.0-rc.1`. Each target
runs `scripts/release.sh`, which:

1. refuses to run if the working tree is dirty;
2. works out the current version as the higher of the line's `VERSION` file and its highest existing
   tag of that family, so a hand-cut tag can never collide with the next computed bump (a pre-release
   suffix can only be left by giving an explicit version);
3. refuses if the new tag already exists;
4. writes the new version to the `VERSION` file, and for the TypeScript SDK to `package.json` and for
   the Java SDK to `pom.xml`, so the manifest matches the tag;
5. shows the diff and asks for confirmation;
6. commits `<label> vX.Y.Z`, creates the tag, and pushes the branch and the tag.

### What happens after the tag is pushed

- **`fcdev`**: the *Release fcdev* GitHub Actions workflow runs on `fcdev/v*` tags. It builds the
  web console once, cross-compiles `fcdev` for macOS (arm64 and amd64), Linux (amd64 and arm64) and
  Windows (amd64), packages each with a SHA-256 sidecar, signs the Linux archives with Sigstore cosign
  (keyless, bound to that workflow run), and publishes a GitHub release. The installers
  (`install.sh`, `install.ps1`) and `fcdev upgrade` consume these assets.
- **SDKs**: the tags drive the SDK packaging described by each SDK's own README. The repository also
  contains workflows that mirror the TypeScript and Laravel SDKs to standalone repositories on a tag,
  but they are currently switched off in the workflow files, so check the SDK's package registry or
  README for how a given version is distributed.

## Version numbers

Each line is independent and uses `MAJOR.MINOR.PATCH`. SDK versions
move independently of the platform: an SDK is generated from the platform's OpenAPI document and
tracks the [wire contract](reference/wire-contract.md), which is stable across releases.

## Upgrading

- **fcdev**: `fcdev upgrade` (`--check` to only look). See the [fcdev reference](reference/fcdev.md#fcdev-upgrade).
- **fc-server**: build or pull the commit you want and redeploy. Migrations are embedded and run at
  start-up. See [Deployment](operate/deployment.md#rolling-out).
- **SDKs**: update the dependency in your package manager.
