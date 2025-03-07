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

## Daffodil Check Release Container

This container can be used to verify the signatures, checksums, signatures, and
optionally reproducibility.

Note that it is possible to run the src/check-release.sh script standalone
without the container, but the container proviedes an environment that has all
the necessary dependencies and keys already installed, so it may make release
verification easier.

To build or update the build release container image:

    podman build -t daffodil-check-release containers/check-release/

To use the container image to check a release, run the following:

    podman run -it --rm \
      daffodil-check-release "$DIST_URL" "$MAVEN_URL"

Alternatively, if you would like to do the same checks but also check for
reproducibility, use the Release Candidate Container to build a release
directory directory, then run the following:

    podman run -it --rm \
      --volume <RELEASE_DIR>:/release
      daffodil-check-release "<DIST_URL>" "<MAVEN_URL>" /release
