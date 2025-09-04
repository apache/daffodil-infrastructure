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

printf "\n==== RPM Embedded Signatures ====\n"
# The "rpm -K ..." command is used to verify that embedded digests and/or
# signatures of an RPM are correct, but it does not require that either
# actually exists. The format of its output is
#
#   <rpm_name>: (digests)? (signatures)? [OK|NOT OK]
#
# where "digests" and "signatures" are optional (depending on if the RPM has
# embedded digests/signatures) and "OK" is output if all embedded digests and
# signatures are valid, or "NOT OK" otherwise. We require that released RPMs
# have both embedded signatures and digests and that they are all valid, so we
# ensure the output of rpm -K contains the expect string that indicates this.
find $DIST_DIR -type f -name '*.rpm' \
	-exec bash -c "rpm -K '{}' | grep 'digests signatures OK' $PRINT_FIND_RESULT" \;

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

# RPM files have an embedded signature which makes reproducibility checking
# difficult since locally built RPMs will not have the embedded signature. The
# RPMs should be identical if we delete that signature, but unfortunately
# rpmsign --delsign does not necessarily make RPMs byte for byte identical--
# sometimes it rebuilds them in slightly different ways that are technically
# the same but not identical. So we sort of delete the signature header
# ourselves. This is done by calculating the size of the signature header in
# the locally built RPM and copying those bytes into the dist RPM. As long as
# the two signature headers are the same size (which they should always be),
# this should work. Since we are changing the dist files, we create a backup of
# them first, replace the signature header, run the diff command, then restore
# the backups.
#
# All signature/checksum data is stored in a "signature header". This header
# starts immediately after the 96-byte "lead". The header format is:
#
#  * magic number: 8 bytes
#  * index_count: 4 bytes (uint32_t)
#  * data_length: 4 bytes (uint32_t)
#  * index: index_count * 16-byte entries
#  * data: data_length bytes
#
# To find the total length of the signature header we read the index_count and
# data_length fields at a known offset (skipping the lead and magic number),
# then add together the length of 3 fixed length fields (16 bytes), the length
# of the index (16 * index_count) and the length of the data (data_length).
BACKUP_DIR=$(mktemp -d)
find $DIST_DIR -name '*.rpm' -exec cp --parents {} $BACKUP_DIR \;
for SRC_RPM in `find $LOCAL_RELEASE_DIR -name '*.rpm'`
do
	find $DIST_DIR -name "$(basename $SRC_RPM)" -exec bash -c '
		LEAD_SIZE=96
		read SIG_INDEX_COUNT SIG_DATA_LENGTH < <(od -An -t u4 -j $((LEAD_SIZE+8)) -N 8 --endian=big "$1")
		SIG_HEADER_LENGTH=$((16 + SIG_INDEX_COUNT*16 + SIG_DATA_LENGTH))
		dd if="$1" of="$2" bs=1 skip=$LEAD_SIZE seek=$LEAD_SIZE count=$SIG_HEADER_LENGTH conv=notrunc
	' _ "$SRC_RPM" {} \; &> /dev/null
done

# Reasons for excluding files from the diff check:
# - The downloaded .rpm file has an embedded signature (which we removed),
#   locally built RPM does not so checksums will be different. RPMs should be
#   exactly the same with the signature removed though.
# - The .asc files can only be generated by the system with the secret key, the
#   locally built releases are not signed
DIFF=$(diff \
	--recursive \
	--brief \
	--exclude=*.rpm.sha512 \
	--exclude=*.asc \
	--exclude=*.asc.md5 \
	--exclude=*.asc.sha1 \
	$RELEASE_DIR/ $LOCAL_RELEASE_DIR/)
[ $? -eq 0 ] && echo -e "$PASS no differences found" || (echo "$DIFF" | xargs -I {} echo -e "$FAIL {}")

# restore and delete the backup directory
cp -R $BACKUP_DIR/. .
rm -rf $BACKUP_DIR
