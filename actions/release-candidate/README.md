# Release Candidate Action

This is a GitHub Action that can be used to create release candidates. Note
that it is somewhat opinionated on how release candidates are organized. This
is not intended to be used by all projects.

## Prerequisites

* Apache Security Team has approved the project for
  [Automated Release Signing](https://infra.apache.org/release-signing.html#automated-release-signing)
  and INFRA has set secrets for the repository, including a GPG signing key,
  SVN username/password, nexus username/password, and optionally SSL.com credentials
* The `runs-on` workflow setting should be Linux based (e.g. `ubuntu-latest`)
* The repository must be checked out using `actions/checkout` prior to
  triggering this action
* The repository must have a `VERSION` file containing the current version of the
  project (e.g. `1.0.0`)
* When triggered from a tag, the tag must follow the pattern `v<VERSION>-*`
  (e.g. `v1.0.0-rc1`)
* When triggered from a tag, the tag must be signed and verified by a key
  listed in `https://downloads.apache.org/<tlp_dir>/KEYS`.

## Setup Operations

Below are the operations this action does to setup the environment for a
release candidate workflow:

* Checkout the project's `dist/dev/` SVN directory and create a directory for
  release artifacts in `https://dist.apache.org/repos/dist/dev/<tlp_dir>/<project_dir>/<version>-rcX`.
  The `artifact_dir` output is set to this directory. Note that `<project_dir>`
  is optional if the artifact directory should be in the root of the
  `<tlp_dir>`
* Delete previous release candidates from `dist/dev/` for the same version
  Useful if an rc fails the VOTE and another is created
* Create a zip source artifact using git archive. The artifact is written to
  `src/apache-<project_id>-<version>-src.zip` in the above artifact directory
* Export `SOURCE_DATE_EPOCH` environment variable to match the timestamp of the
  current commit
* Configure global SBT [Simple Build Tool](https://scala-sbt.org) settings to
  enabling publishing signed jars to the ASF nexus staging repository. Workflow
  steps can use `sbt pubilshSigned` without needing any other configuration. If
  publishing is disabled, SBT is configured to publish to a local maven repo on
  the CI system, so `sbt publishSigned` can still be used without actually
  publishing anything.

## Post Operations

If the workflow job does not succeed, none of the following actions are taken.
Files added to `dist/dev/` will not be committed. If the workflow published
files to the ASF staging nexus repository, those files must be manually
dropped.

If the workflow job successfully completes, the following actions are performed
at the end of the workflow:

* Sign all rpm artifacts with the GPG key with rpmsign
* Sign all exe artifacts with the ssl.com certificates, if publishing is
  enabled and `ssl_com_username` is defined
* Create sha512 checksum files for all artifacts
* Create detached ASCII armored GPG signatures for all artifacts
* Commit all files added to `dist/dev/` to SVN

Note that committing to SVN is is disabled if any of the following are true:
* The `publish` input is not explicitly set to `true`
* The `VERSION` file contains `-SNAPSHOT`
* The workflow is not triggered from the push of a tag
* The repository is not in the `apache` organization

If any of the above are true and publishing is disabled, the artifact directory
is uploaded as a GitHub workflow artifact. It will be retained for one day.
This is useful for testing the workflow using workflow dispatch.

## Inputs

| Input           | Required      | Default | Description |
|-----------------|---------------|---------|-------------|
| tlp_dir         | yes           |         | Directory of the top level project in dist/dev/ |
| project_name    | yes           |         | Human readable name of the project |
| project_id      | yes           |         | ID of the project, used in source artifact file name |
| project_dir     | no            | ""      | Directory for the project in dev/dist/<tlp_dir>/. Omit if at the root |
| gpg_signing_key | if publishing |         | Key used to sign artifacts |
| ssl_com_username| no            |         | Username for signing .exe artifacts using SSL.com |
| ssl_com_password| no            |         | Password for signing .exe artifacts using SSL.com |
| ssl_com_secret  | no            |         | Secret for signing .exe artifacts using SSL.com |
| svn_username    | if publishing |         | Username for publishing release artifacts to SVN dev/dist |
| svn_password    | if publishing |         | Password for publishing release artifacts to SVN dev/dist |
| nexus_username  | if publishing |         | Username for publishing release artifacts to Nexus |
| nexus_password  | if publishing |         | Password for publishing release artifacts to Nexus |
| publish         | no            | false   | Enable/disabling publish artifacts. Must be explicitly set to true to enable publishing. May be ignored depending on other factors. |

## Outputs

| Output          | Description |
|-----------------|-------------|
| artifact_dir    | Directory where additional release artifacts can be added by the workflow. They are automatically signed, checksumed, and published at the end of the workflow |

## Example Workflow

```yaml
name: Release Candidate

# triggered via release candidate tags or manually via workflow dispatch, note
# that publishing is disabled if not triggered from a tag
on:
  push:
    tags:
      - 'v*-rc*'
  workflow_dispatch:

jobs:

  release-candidate:
    name: RC ${{ github.ref_name }}
    runs-on: ubuntu-latest

    steps:

      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: ASF Release Candidate
        id: rc
        uses: apache/daffodil-infrastructure/release-candidate@main
        with:
          tlp_dir: 'daffodil'
          project_name: 'Apache Daffodil'
          project_id: 'daffodil'
          gpg_signing_key: ${{ secrets.GPG_PRIVATE_KEY }}
          svn_username: ${{ secrets.SVN_USERNAME }}
          svn_password: ${{ secrets.SVN_PASSWORD }}
          nexus_username: ${{ secrets.NEXUS_USERNAME }}
          nexus_password: ${{ secrets.NEXUS_PASSWORD }}
          publish: true

      - name: Install Dependencies
        run: |
          sudo apt-get -y install ...
          ...

      - name: Create Binary Artifacts
        run: |
          sbt compile publishSigned ...
          
          ARTIFACT_DIR=${{ steps.rc.outputs.artifact_dir }}
          ARTIFACT_BIN_DIR=$ARTIFACT_DIR/bin

          # copy helper binaries to the artifact bin directory, these will be
          # automatically signed, checksumed, and comitted to dist/dev/
          mkdir -p $ARTIFACT_BIN_DIR
          cp ... $ARTIFACT_BIN_DIR/
```

# Development

GitHub actions require that any changes made to the files in the `src/`
directory are compiled into index.js files in `dist/` subdirectories. To do
this, run the commands:

```bash
npm install
npm run build
```

The changes this makes to `dist/` must be committed along with the changes to
`src/`.

# Testing

Perform the following steps to test changes to the daffodil-infrastructure repo on a GitHub fork:

1. Update the `uses` action of the `ASF Release Candidate` step in the
   `.github/workflows/release-candidate.yml` file of the repository to be tested on. Then, 
    push your changes to your fork of the test repository.
2. Now you can generate a release by going to the Actions tab of your test fork,
    and selecting the workflow that uses the release-candidate action. 
    Click the `Run workflow` button, and select the branch you just pushed to.
3. Once the run is complete, you can download the release from the `Artifacts` 
    tab under `Summary`. After downloading the release, extract it. 

If you want to validate things with the check-release container, follow its steps 
as defined in its README.md. The only modification you need to make is to set the
release label to `rc0`. Then run the checks using the container using the 
following command:

```bash
podman run -it --rm \
--volume <DOWNLOADED-RELEASE-DIR>:/release-download \
--volume <ARTIFACT-DIR>:/release \
daffodil-check-release "NA" "NA" /release
```
> Note: The public key needed to verify the artifacts is available in the release-download directory.
