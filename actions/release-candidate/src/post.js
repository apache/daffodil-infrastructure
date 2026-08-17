/**
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements. See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

const fs = require("fs");
const os = require("os");
const core = require("@actions/core");
const { DefaultArtifactClient } = require('@actions/artifact')
const { exec, getExecOutput } = require('@actions/exec');

// Sign and publish all release artifacts. If publishing is disabled, we just
// upload all the release candidate artifacts as GitHub workflow artifacts.
// The post-if condition in action.yml ensures this is only ever run if a job
// succeeds.
async function run() {
	try {
		const project_name = core.getInput("project_name", { required: true });

		const artifact_dir = core.getState("artifact_dir");
		const gpg_signing_key_id = core.getState("gpg_signing_key_id");
		const do_publish = core.getState("do_publish") === "true";
		const release_version = core.getState("release_version");

		// ssl.com credentials are optional, if not provided we will not sign
		// exe artifacts. Also, each ssl.com signature costs ASF money, so we
		// only sign exe artifacts if we are actually going to publish things
		// (e.g. this isn't a test run)
		const esigner_storepass = core.getInput("esigner_storepass");
		const esigner_keypass = core.getInput("esigner_keypass");
		const do_esigner = esigner_storepass;

		// sign/checksum all artifacts
		const artifacts = fs.readdirSync(artifact_dir, { recursive: true, withFileTypes: true });
		for(const artifact of artifacts) {
			if (artifact.isFile()) {
				// must sign rpms and exes before sha/gpg since rpmsign/jsign modifies the files
				if (artifact.name.endsWith(".rpm")) {
					await exec("rpmsign", ["--define", `_gpg_name ${ gpg_signing_key_id }`, "--define", "_binary_filedigest_algorithm 10", "--addsign", `${ artifact.parentPath }/${ artifact.name }`]);
				}
				if (artifact.name.endsWith(".exe") && do_esigner) {
					// see https://infra.apache.org/code-signing-use.html for more information
					// note that ssl.com does not suppport SHA512 signature algorithm
					const cert_uuid = "d97c5110-c66a-4c0c-ac0c-1cd6af812ee6";
					await exec("jsign", ["--storetype", "ESIGNER", "--alias", cert_uuid, "--storepass", esigner_storepass, "--keypass", esigner_keypass, "--tsaurl=http://ts.ssl.com", "--tsmode", "RFC3161", "--alg", "SHA256", `${ artifact.parentPath }/${ artifact.name }`]);
				}
				const shasum_output = await getExecOutput("sha512sum", ["--binary", artifact.name], {
					cwd: artifact.parentPath
				});
				fs.appendFileSync(`${ artifact.parentPath }/${ artifact.name }.sha512`, shasum_output.stdout);
				await exec("gpg", ["--default-key", gpg_signing_key_id, "--batch", "--yes", "--detach-sign", "--armor", "--output", `${ artifact.name }.asc`, artifact.name], {
					cwd: artifact.parentPath
				});
			}
		}

		if (do_publish) {
			await exec("svn", ["add", artifact_dir]);
			await exec("svn", ["commit", "--message", `Stage ${ project_name } ${ release_version }`, artifact_dir]);
		} else {
			// if publishing was disabled then this action was likely just triggered
			// just for testing, so upload the maven-local and artifact directories so
			// they can be verified. Note that we do not just recurse the
			// release-download directory since it could contain files that already
			// exist in the SVN checkout and were not artifacts created by this action
			const release_dir = `${ os.tmpdir() }/release-download`;

			const public_key_file = `${ release_dir }/public-key.asc`;
			// if publishing is disabled, store public key as artifact so it can be downloaded
			// by the post step for verification
			const gpg_export_output = await getExecOutput("gpg", ["--armor", "--export", gpg_signing_key_id], {
				silent: true
			});
			fs.appendFileSync(`${ public_key_file }`, gpg_export_output.stdout);

			const svn_artifacts = fs.readdirSync(artifact_dir, { recursive: true, withFileTypes: true });
			const maven_artifacts = fs.readdirSync(`${ release_dir }/maven-local`, { recursive: true, withFileTypes: true });
			const upload_artifacts = [...svn_artifacts, ...maven_artifacts]
				.filter((dirent) => dirent.isFile())
				.filter((dirent) => !dirent.parentPath.split("/").includes(".svn"))
				.map((dirent) => `${ dirent.parentPath }/${ dirent.name }`);
			const artifact_client = new DefaultArtifactClient();
			artifact_client.uploadArtifact("release-download", [...upload_artifacts, public_key_file], os.tmpdir(), {
				compressionLevel: 0,
				retentionDays: 1
			});
		}

	} catch (error) {
		core.setFailed(error.message);
	}
}

run();
