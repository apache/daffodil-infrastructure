<!--
  Licensed to the Apache Software Foundation (ASF) under one or more
  contributor license agreements.  See the NOTICE file distributed with
  this work for additional information regarding copyright ownership.
  The ASF licenses this file to You under the Apache License, Version 2.0
  (the "License"); you may not use this file except in compliance with
  the License.  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-->

## Daffodil Build Release Container

Daffodil release artifacts are built using GitHub actions. This container can
be used to build those same artifacts for testing or verifying reproducibility.
This can be used for all Daffodil projects, including the Daffodil VS Code
Extension and the SBT plugin.

To build or update the build release container image:

    podman build -t daffodil-build-release containers/build-release/

To use the container image to build a release, run the following from the root
of the project git repository, replacing `<REPO_DIR>` with the path to the git
repository of the project to build and `<ARTIFACT_DIR>` with the directory
where you want the artifacts saved:

    podman run -it --rm \
      --hostname daffodil.build \
      --volume <REPO_DIR>:/project:O \
      --volume <ARTIFACT_DIR>:/artifacts \
      daffodil-build-release

Note that the `<REPO_DIR>` volume uses the `:O` suffix so that changes to the
repository inside the container do not affect the repository outside the
container.

When run, the container will ask for an optional pre-release label (e.g. rc1)
and the project to build. The resulting artifacts will be written to the
`<ARTIFACT_DIR>/release/` directory.
