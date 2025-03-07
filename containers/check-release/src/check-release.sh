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

if [[ "$#" -lt "2" || "$#" -gt 3 ]]
then
	echo "error: incorrect number of arguments" >&2
	echo "Usage: $0 <DIST_URL> <MAVEN_URL> [LOCAL_RELEASE_DIR]" >&2
	exit 1
fi

# URL of release candidate directory in dev/dist/, e.g. https://dist.apache.org/repos/dist/dev/daffodil/1.0.0-rc1
DIST_URL=$1

# URL of maven staging repository, e.g. https://repository.apache.org/content/repositories/orgapachedaffodil-1234
MAVEN_URL=$2

# optional path to release directory built by running the daffodil-build-release
# container. If not provided, only signature/checksum checks are done
LOCAL_RELEASE_DIR=$3

require_command() {
	command -v "$1" &> /dev/null || { echo "error: command $1 not found in PATH"; exit 1; }
}

# error early if needed tools are missing
require_command diff
require_command gpg
require_command md5sum
require_command rpm
require_command sha1sum
require_command sha512sum
require_command wget
if [ -n "$LOCAL_RELEASE_DIR" ]
then
	require_command msidiff
	require_command rpmsign
fi

WGET="wget --recursive --level=inf -e robots=off --no-parent --no-host-directories --reject=index.html,robots.txt"

RELEASE_DIR=release-download
DIST_DIR=$RELEASE_DIR/asf-dist
MAVEN_DIR=$RELEASE_DIR/maven-local

printf "\n==== Downloading Release Files ====\n"

# download dist/dev/ files
mkdir -p $DIST_DIR
pushd $DIST_DIR &>/dev/null
$WGET --cut-dirs=4 $DIST_URL/
popd &>/dev/null

# download maven repository, delete nexus generated files
if [ -n "$MAVEN_URL" ]
then
	mkdir -p $MAVEN_DIR
	pushd $MAVEN_DIR &>/dev/null
	$WGET --cut-dirs=3 $MAVEN_URL/
	find . -type f \( -name 'archetype-catalog.xml' -o -name 'maven-metadata.xml*' \) -delete
	popd &>/dev/null
fi

printf "\n==== Download Complete ====\n"

RED="\x1b[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
PASS="$GREEN✔$RESET"
FAIL="$RED✘$RESET"
WARN="$YELLOW‼$RESET"

# used in the string of a find -exec command. Outputs a string representing
# pass/fail depending on how the previous command ran, followed by the filename
# from the find command
PRINT_FIND_RESULT="&> /dev/null && echo -ne '$PASS' || echo -ne '$FAIL'; echo ' {}'"

printf "\n==== Dist SHA512 Checksum ====\n"
find $DIST_DIR -type f ! -name '*.sha512' ! -name '*.asc' \
	-exec bash -c "cd \"\$(dirname '{}')\" && sha512sum --check \$(basename '{}').sha512 $PRINT_FIND_RESULT" \;

printf "\n==== Dist GPG Signatures ====\n"
find $DIST_DIR -type f ! -name '*.sha512' ! -name '*.asc' \
	-exec bash -c "gpg --verify '{}.asc' '{}' $PRINT_FIND_RESULT" \;

printf "\n==== RPM Signatures ====\n"
find $DIST_DIR -type f -name '*.rpm' \
	-exec bash -c "rpm -K '{}' $PRINT_FIND_RESULT" \;

if [ -n "$MAVEN_URL" ]
then
	printf "\n==== Maven SHA1 Checksums ====\n"
	find $MAVEN_DIR -type f ! -name '*.sha1' ! -name '*.md5' ! -name '*.asc' \
		-exec bash -c "diff <(sha1sum '{}' | cut -d' ' -f1 | tr -d '\n') <(cat '{}'.sha1) $PRINT_FIND_RESULT" \;

	printf "\n==== Maven MD5 Checksums ====\n"
	find $MAVEN_DIR -type f ! -name '*.sha1' ! -name '*.md5' ! -name '*.asc' \
		-exec bash -c "diff <(md5sum '{}' | cut -d' ' -f1 | tr -d '\n' ) <(cat '{}'.md5) $PRINT_FIND_RESULT" \;

	printf "\n==== Maven GPG Signatures ====\n"
	find $MAVEN_DIR -type f ! -name '*.sha1' ! -name '*.md5' ! -name '*.asc' \
		-exec bash -c "gpg --verify '{}.asc' '{}' $PRINT_FIND_RESULT" \;
fi

printf "\n==== Reproducible Builds ====\n"
if [ -z "$LOCAL_RELEASE_DIR" ]
then
	echo -e "$WARN no local release directory provided, skipping reproducible build check"
	exit 0
fi

printf "\n==== Calculating Differences ====\n"

# The released rpm file has an embedded signature, deleting the signature
# should cause the RPMs to be byte-for-byte the same
find $DIST_DIR -name '*.rpm' -execdir rpmsign --delsign {} \; &>/dev/null

# Reasons for excluding files from the diff check:
# - The downloaded .rpm file has an embedded signature (which we removed),
#   locally built RPM does not so checksums will be different. RPMs should be
#   exactly the same with the signature removed though.
# - The downloaded .msi file has an embedded UUID and timestamps that cannot be
#   changed, so msi and its checksum will be different. We use msidiff later to
#   verify differences are only where expected
# - The .asc files can only be generated by the system with the secret key, the
#   locally built releases are not signed
DIFF=$(diff \
	--recursive \
	--brief \
	--exclude=*.rpm.sha512 \
	--exclude=*.msi \
	--exclude=*.msi.sha512 \
	--exclude=*.asc \
	--exclude=*.asc.md5 \
	--exclude=*.asc.sha1 \
	$RELEASE_DIR/ $LOCAL_RELEASE_DIR/)
[ $? -eq 0 ] && echo -e "$PASS no differences found" || (echo "$DIFF" | xargs -I {} echo -e "$FAIL {}")

printf "\n==== MSI Differences ====\n"
echo -e "$WARN manual verification needed, diff should include only one UUID and two timestamps"
echo -e "$WARN ignore for VS Code Extension and SBT Plugin"
find $DIST_DIR $LOCAL_RELEASE_DIR -name *.msi -exec msidiff {} \+
