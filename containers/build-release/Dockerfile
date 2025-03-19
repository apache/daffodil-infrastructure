#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# To make for reproducibility, this should match the version used by GitHub
# actions CI release candidate workflow
FROM docker.io/library/ubuntu:22.04

ENV TZ=UTC

# Install/configure dependencies. Note that these are not pinned to any
# specific version, so buidls might different depending on when this Docker
# image is built. Note that the sbt and yarn versions don't really matter all
# too much since they are just used to bootstrap--the daffodil projects specify
# the actual versions of yarn/sbt to use/download when building. We also need
# to install SBT separtely since we need to install dependencies like curl and
# gpg to verify SBT signature
RUN \
  dpkg --add-architecture i386 && \
  apt-get update && \
  apt-get install -qy \
    clang \
    curl \
    git \
    gpg \
    libmxml-dev \
    llvm \
    npm \
    openjdk-8-jdk-headless \
    rpm \
    unzip \
    wine32 \
    winetricks \
    xvfb && \
  echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" > /etc/apt/sources.list.d/sbt.list && \
  curl -sL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" | \
    gpg --no-default-keyring --keyring gnupg-ring:/etc/apt/trusted.gpg.d/scalasbt-release.gpg --import && \
  chmod 644 /etc/apt/trusted.gpg.d/scalasbt-release.gpg && \
  apt-get update && \
  apt-get install -y \
    sbt && \
  npm --no-update-notifier install --global yarn@1.22.19 node@20

# Download and install Inno Setup via wine. Even though we provide options to
# make Inno Setup a headless install, wine still thinks it wants to open a
# window so we need install with a temporary virtual X server with xvfb-run.
# Also ensure it is installed in the directory where the deafult Daffodil SBT
# configuration expects it--different wine configurations could install it
# somewhere else.
RUN \
  INNO_SETUP_EXE="innosetup-6.4.1.exe" && \
  EXPECTED_SHA=5dfc9999e2feafa28754baaf80cf73ac96414228b94a1132a919554a822c892810197305d9355885b9ac408c214691cd45279fc2df3a891fbebc4f8eb86bac87 && \
  curl -L https://files.jrsoftware.org/is/6/$INNO_SETUP_EXE -o $INNO_SETUP_EXE && \
  echo "$EXPECTED_SHA $INNO_SETUP_EXE" | sha512sum --quiet -c - && \
  winetricks -q win10 && \
  xvfb-run wine $INNO_SETUP_EXE /VERYSILENT /SUPPRESSMSGBOXES /TASKS= '/DIR=C:\\Program Files (x86)\\Inno Setup 6' && \
  rm $INNO_SETUP_EXE

# We expect users to mount the project repo to /root/project, so we change that
# to our working directory so the daffodil-build-release command is run from
# the repo directory
WORKDIR "/project/"

# Install and set the entrypoint
COPY src/daffodil-build-release /usr/bin/
ENTRYPOINT ["/usr/bin/daffodil-build-release"]
