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

download_dir() {
	# force a trailing slash by removing a slash it if exists and then adding
	# it back. This is required for maven URLs to download the right thing--it
	# doesn't matter either way for dist urls
	URL="${1%/}/"
	# non-greedily delete the schema and domain part of the URL, giving just
	# the path part
	URL_PATH="${URL#*://*/}"
	# we want to use --cut-dirs to ignore all directories but the final target
	# directory. This number is different depending on the URL, so we extract
	# and count the nubmer of slash-separated fields of the url path and
	# subtract 2 (one because we want to keep the last field, and one because
	# there is an extra field because the path ends in a slash)
	CUT_DIRS=$(echo "$URL_PATH" | awk -F/ '{print NF - 2}')
	wget \
		--recursive \
		--level=inf \
		-e robots=off \
		--no-parent \
		--no-host-directories \
		--reject=index.html,robots.txt \
		--cut-dirs=$CUT_DIRS \
		"$URL"

	# wget on some systems (e.g. Ubuntu 22.04) leaves behind .tmp files used
	# when downloading files, likely related to --reject=index.html. Delete
	# those if they exist.
	find "$(basename "$URL")" -name '*.tmp' -delete
}

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
require_command cmp
require_command gpg
require_command md5sum
require_command rpm
require_command sha1sum
require_command sha512sum
require_command wget


RELEASE_DIR=release-download
DIST_DIR=$RELEASE_DIR/asf-dist
MAVEN_DIR=$RELEASE_DIR/maven-local

printf "\n==== Downloading Release Files ====\n"

# download dist/dev/ files
mkdir -p $DIST_DIR
pushd $DIST_DIR &>/dev/null
download_dir $DIST_URL
popd &>/dev/null

# download maven repository, delete nexus generated files, and remove the
# orgapachedaffodil-1234 dir since the build-release container does not have
# this directory
if [ -n "$MAVEN_URL" ]
then
	mkdir -p $MAVEN_DIR
	pushd $MAVEN_DIR &>/dev/null
	download_dir $MAVEN_URL
	find . -type f \( -name 'archetype-catalog.xml' -o -name 'maven-metadata.xml*' \) -delete
	REPO_DIR=(*/)
	mv $REPO_DIR/* .
	rmdir $REPO_DIR
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

FAILURE_COUNT=0

# Read a list of newline separated paths from a file ($1) and commands from
# stdin to evaluate for each line in the file. Each line in the file is
# expected to be a path to a file, but it is not enforced. All {} strings in the
# commands are replaced with the current line in the file prior to evaluation.
# The commands are also evaluated in a new bash process, so they are free to
# include commands like 'cd' or 'exit' without affecting the main script. Note
# this means they cannot access variables or functions in the current process
# scope. For each line, this outputs a pass/fail icon (based on the exit code
# of the last command) followed by the line. A count of all failures is tallied
# in the FAILURE_COUNT variable.
#
# Usage tips:
#
# It is recommended to wrap {} in apostrophes to avoid unexpected variable or
# other expansions.
#
# Process substitution can be used for the file list to to avoid the need to
# create actual files.
#
# Commands are read from stdin to support the recommended use of heredocs. In
# general, tests should use <<-'CMD' commands CMD, especially if no variable
# expansion or process substitution is wanted or needed. If that is needed,
# tests should usually use <<-CMD commands CMD.
#
# Usage examples:
#
# test_files all_text_files.txt <<-'CMD'
#     gpg --verify '{}.asc' '{}'
# CMD
#
# test_files <(find dir/ -name '*.txt') <<-CMD
#     cmp '{}' "$OTHER_DIR"/'{}'
# CMD
#
test_files() {
	FILE_LIST="$1"
	CMDS=$(cat)
	while IFS= read -r LINE
	do
		CMDS_TO_EVAL="${CMDS//\{\}/$LINE}"
		bash -c "$CMDS_TO_EVAL" &> /dev/null
		RC=$?
		print_result $RC $LINE
		[ $RC -eq 0 ] || FAILURE_COUNT=$((FAILURE_COUNT + 1))
	done < "$FILE_LIST"
}

print_result() {
	RC=$1
	MESSAGE=$2
	[ $RC -eq 0 ] && echo -ne "$PASS" || echo -ne "$FAIL"
	echo " $MESSAGE"
}

printf "\n==== Dist SHA512 Checksum ====\n"
test_files <(find "$DIST_DIR" -type f ! -name '*.sha512' ! -name '*.asc') <<-'CMD'
	cd "$(dirname '{}')"
	sha512sum --check "$(basename '{}').sha512"
CMD

printf "\n==== Dist GPG Signatures ====\n"
test_files <(find "$DIST_DIR" -type f ! -name '*.sha512' ! -name '*.asc') <<-'CMD'
	gpg --verify '{}.asc' '{}'
CMD

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
test_files <(find "$DIST_DIR" -type f -name '*.rpm') <<-'CMD'
	rpm -K '{}' | grep 'digests signatures OK'
CMD

if [ -n "$MAVEN_URL" ]
then
	printf "\n==== Maven SHA1 Checksums ====\n"
	test_files <(find "$MAVEN_DIR" -type f ! -name '*.sha1' ! -name '*.md5' ! -name '*.asc') <<-'CMD'
		cmp <(sha1sum '{}' | cut -d' ' -f1 | tr -d '\n') '{}.sha1'
	CMD

	printf "\n==== Maven MD5 Checksums ====\n"
	test_files <(find "$MAVEN_DIR" -type f ! -name '*.sha1' ! -name '*.md5' ! -name '*.asc') <<-'CMD'
		cmp <(md5sum '{}' | cut -d' ' -f1 | tr -d '\n' ) '{}.md5'
	CMD

	printf "\n==== Maven GPG Signatures ====\n"
	test_files <(find "$MAVEN_DIR" -type f ! -name '*.sha1' ! -name '*.md5' ! -name '*.asc') <<-'CMD'
		gpg --verify '{}.asc' '{}'
	CMD
fi

printf "\n==== Reproducible Builds ====\n"
if [ -z "$LOCAL_RELEASE_DIR" ]
then
	echo -e "$WARN no local release directory provided, skipping reproducible build check"
else
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
	BACKUP_DIR="$(mktemp -d)"
	find "$RELEASE_DIR" -name '*.rpm' -exec cp --parents '{}' "$BACKUP_DIR" \;
	while IFS= read -r RPM_PATH
	do
		LOCAL_RPM="$LOCAL_RELEASE_DIR/$RPM_PATH"
		RELEASE_RPM="$RELEASE_DIR/$RPM_PATH"
		LEAD_SIZE=96
		read SIG_INDEX_COUNT SIG_DATA_LENGTH < <(od -An -t u4 -j $((LEAD_SIZE+8)) -N 8 --endian=big "$LOCAL_RPM")
		SIG_HEADER_LENGTH=$((16 + SIG_INDEX_COUNT*16 + SIG_DATA_LENGTH))
		dd if="$LOCAL_RPM" of="$RELEASE_RPM" skip=$LEAD_SIZE seek=$LEAD_SIZE \
			bs=1 count=$SIG_HEADER_LENGTH conv=notrunc &> /dev/null
	done < <(find "$LOCAL_RELEASE_DIR/" -name '*.rpm' -printf '%P\n')

	# Reasons for excluding files from the diff check:
	# - The downloaded .rpm file has an embedded signature (which we removed),
	#   locally built RPM does not so checksums will be different. RPMs should be
	#   exactly the same with the signature removed though.
	# - The .asc files can only be generated by the system with the secret key, the
	#   locally built releases are not signed
	test_files <(find "$RELEASE_DIR/" "$LOCAL_RELEASE_DIR/" \
			-type f \
			! -name '*.rpm.sha512' \
			! -name '*.asc' \
			! -name '*.asc.md5' \
			! -name '*.asc.sha1' \
			-printf '%P\n' | sort -u) <<-CMD
		cmp "$RELEASE_DIR"/'{}' "$LOCAL_RELEASE_DIR"/'{}'
	CMD

	# restore and delete the backup directory
	cp -R "$BACKUP_DIR/." .
	rm -rf "$BACKUP_DIR"
fi

printf "\n==== Results ====\n"
print_result $FAILURE_COUNT "Total Failed Checks: $FAILURE_COUNT"
