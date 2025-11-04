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
const github = require("@actions/github");
const { exec } = require('@actions/exec');

async function run() {
	try {
		const tlp_dir = core.getInput("tlp_dir", { required: true });
		const project_id = core.getInput("project_id", { required: true });
		const project_dir = core.getInput("project_dir");
		const publish = core.getBooleanInput("publish");

		// get the actual project version, this requires a 'VERSION' file at
		// the root of the repository
		const project_version = fs.readFileSync("VERSION").toString().trim();
		const is_snapshot = project_version.includes("-SNAPSHOT");
		const is_apache = process.env.GITHUB_REPOSITORY_OWNER == "apache";
		const gitTagPrefix = "refs/tags/";
		const is_tagged = github.context.eventName == "push" && github.context.ref.startsWith(gitTagPrefix);
		// The publish setting must be explicitly set to true to actually publish artifacts. Note that
		// this is required but not sufficient as even if this setting is true, a number of other factors (usually
		// related to testing) can disable publishing (e.g. non-tagged, snapshot build, non-ASF repository)
		const do_publish = publish && is_tagged && !is_snapshot && is_apache

		if (!do_publish) {
			core.warning("Publishing disabled:")
			if (!publish) core.warning("- Published releases must set the 'publish' setting to 'true'")
			if (!is_tagged) core.warning("- Published releases must be triggered via a tag")
			if (is_snapshot) core.warning("- Published releases must have non-snapshot versions")
			if (!is_apache) core.warning("- Published releases must come from an ASF repository")
		}

		// we only require the gpg_singing_key if we are actually going to publish artifacts. If it is
		// not required and not provided, we generate a temporary key so the workflow can still
		// sign artifacts
		const gpg_signing_key = core.getInput("gpg_signing_key", {required: do_publish});
		if (gpg_signing_key.trim() === "") {
			// Generate keypair (non-interactive)
			await exec("gpg", ["--batch", "--yes", "--passphrase", '', "--quick-generate-key",
				"Apache Daffodil Test Release <dev@daffodil.apache.org>" , "default", "default", "1d"], {
				silent: true
			});
		} else {
			// import signing key into gpg
			await exec("gpg", ["--batch", "--import", "--import-options", "import-show"], {
				input: Buffer.from(gpg_signing_key)
			});
		}

		// Capture the key id of the most recent generated/imported key
		let gpg_list_secret_keys_stdout = "";
		await exec("gpg", ["--list-secret-keys", "--with-colons"], {
			silent: true,
			listeners: {
				stdout: (data) => {
					gpg_list_secret_keys_stdout += data.toString();
				}
			}
		});
		const gpg_signing_key_id = gpg_list_secret_keys_stdout
			.split('\n')
			.findLast(l => l.startsWith("fpr"))
			.split(':')[9];

		console.info("Using gpgp key id: " + gpg_signing_key_id);

		// figure out the release version. This should follow the pattern
		// 'v<VERSION>-rcX', where <VERSION> is the value from the VERSION file
		let release_version = "";
		if (is_tagged) {
			// this was triggered by the push of a tag, the tag name will be the
			// version used
			release_version = github.context.ref.slice(gitTagPrefix.length);

			// make sure the tag name matches the actual project version
			if (!release_version.startsWith(`v${project_version}-`)) {
				throw new Error(`Tag ${ release_version } does not match project version: v${ project_version }`);
			}

			// The github checkout action does not fetch tag information when
			// triggered from a tag, so we fetch it manually so we can verify its tag
			await exec("git", ["fetch", "origin", "--deepen=1", `+${ github.context.ref }:${ github.context.ref }`]);

			if (do_publish) {
				// if publishing, tags must be signed with a committers key, download and import committer
				// keys for verification
				let committer_keys = "";
				await exec("curl", [`https://downloads.apache.org/${tlp_dir}/KEYS`], {
					silent: true,
					listeners: {
						stdout: (data) => {
							committer_keys += data.toString();
						}
					}
				});
				await exec("gpg", ["--batch", "--import"], {
					input: Buffer.from(committer_keys)
				});

				// make sure the tag is signed by a committer in the KEYS file, this
				// command fails if the tag does not verify.
				await exec("git", ["tag", "--verify", release_version]);
			}
		} else {
			// this was not triggered by a tag, maybe it was manually triggered via
			// workflow_dispatch or a normal commit. We also set the release_version so that it has the
			// same format as a tag (e.g. v1.2.3-rc1)
			release_version = `v${ project_version }-rc0`;
		}
		// the name of the directory where we store release artifacts doesn't actually
		// matter since it is never published anywhere. The one time where this isn't true
		// is if publishing is disabled, in which case this directory is made available as
		// a downloadable GitHub artifact. Naming it "release-download" makes it more
		// clear this is a downloaded artifact rather than locally built--this
		// differentiates it from artifacts created with the build-release container and
		// follows the naming convention expected by the check-release script.
		const release_dir = `${ os.tmpdir() }/release-download`;
		fs.mkdirSync(release_dir);

		// enable and configure SBT for signing and publishing. Note that the
		// sbt-pgp plugin version should not be updated unless there is a
		// compelling reason. Release signing has been known to break with newer
		// versions.
		const sbt_dir = `${ os.homedir }/.sbt/1.0`
		fs.mkdirSync(`${ sbt_dir }/plugins`, { recursive: true });
		fs.appendFileSync(`${ sbt_dir }/plugins/build.sbt`, 'addSbtPlugin("com.github.sbt" % "sbt-pgp" % "2.1.2")\n');
		fs.appendFileSync(`${ sbt_dir }/build.sbt`, `pgpSigningKey := Some("${ gpg_signing_key_id }")\n`);

		// enable SBT for publishing SBOM either locally or remotely
		fs.appendFileSync(`${ sbt_dir }/plugins/build.sbt`, 'addSbtPlugin("com.github.sbt" %% "sbt-sbom" % "0.4.0")\n');
		fs.appendFileSync(`${ sbt_dir }/build.sbt`, 'bomFormat := "xml"\n');

		if (do_publish) {
			// if publishing is enabled, we must configure sbt to write to a config file for
			// post to read from
			const svn_username = core.getInput("svn_username", { required: true });
			const svn_password = core.getInput("svn_password", { required: true });

			// Create the default config directory if it doesn't exist
			const svn_config_dir = `${ os.homedir }/.subversion`;
			fs.mkdirSync(`${ svn_config_dir }`, { recursive: true });

			// Write to/Overwrite the 'servers' file inside it
			const servers_file = path.join(svn_config_dir, 'servers');
			const servers_content = `
[global]
store-plaintext-passwords = yes
store-plaintext-creds = yes

[groups]
default = *

[default]
username = ${svn_username}
password = ${svn_password}
`;
			fs.writeFileSync(servers_file, servers_content.trim(), { mode: 0o600 });

			// if publishing is enabled, publishing to the apache staging repository
			// with the provided credentials. We must diable gigahorse since that fails
			// to publish on some systems
			const nexus_username = core.getInput("nexus_username", { required: true });
			const nexus_password = core.getInput("nexus_password", { required: true });
			fs.appendFileSync(`${ sbt_dir }/build.sbt`, 'ThisBuild / updateOptions := updateOptions.value.withGigahorse(false)\n');
			fs.appendFileSync(`${ sbt_dir }/build.sbt`, `ThisBuild / credentials += Credentials("Sonatype Nexus Repository Manager", "repository.apache.org", "${ nexus_username }", "${ nexus_password }")\n`);
			fs.appendFileSync(`${ sbt_dir }/build.sbt`, 'ThisBuild / publishTo := Some("Apache Staging Distribution Repository" at "https://repository.apache.org/service/local/staging/deploy/maven2")\n');
		} else {
			// if publishing is not enabled, we still want the ability for workflows to
			// run 'sbt publishSigned' so they don't have to change logic depending on
			// if they are publishing or not. To support this, configure sbt to publish
			// to a local maven repo
			const maven_local_dir = `${ release_dir }/maven-local`;
			fs.mkdirSync(maven_local_dir);
			fs.appendFileSync(`${ sbt_dir }/build.sbt`, `ThisBuild / publishTo := Some(MavenCache("maven-local", file("${ maven_local_dir }")))\n`);
		}

		// checkout artifact dist directory
		const project_dist_dir = `${ release_dir }/asf-dist`;
		await exec("svn", ["checkout", `https://dist.apache.org/repos/dist/dev/${ tlp_dir }/${ project_dir }`, project_dist_dir]);

		// remove previous release candidates of this version (i.e. any
		// directories that have the same project_version followed by a
		// hyphen). These changes will only be commited if the job succeeds and
		// publishing is enabled
		const direntries = fs.readdirSync(project_dist_dir, { withFileTypes: true });
		for(const dirent of direntries) {
			if (dirent.isDirectory && dirent.name.startsWith(`${ project_version }-`)) {
				await exec("svn", ["delete", "--force", `${ dirent.parentPath }/${ dirent.name }`]);
			}
		}

		// create the directory for artifacts, this is the version without the leading
		// 'v', but keeping any -rcX or -SNAPSHOT suffixes
		const artifact_dir = `${ project_dist_dir }/${ release_version.slice(1) }`;
		fs.mkdirSync(artifact_dir);

		// create the source artifact
		const src_artifact_dir = `${ artifact_dir }/src`;
		const src_artifact_name = `apache-${ project_id }-${ project_version }-src`;
		fs.mkdirSync(src_artifact_dir);
		await exec("git", ["archive", "--format=zip", `--prefix=${ src_artifact_name }/`, "--output", `${ src_artifact_dir }/${ src_artifact_name }.zip`, "HEAD"]);

		// get the reproducible build epoch
		let source_date_epoch = "";
		await exec("git", ["show", "--no-patch", "--format=%ct", "HEAD"], {
			listeners: {
				stdout: (data) => { source_date_epoch += data.toString().trim(); }
			}
		});

		// we are done with all the filesystem setup, we now export environment
		// variables, output variables, and state needed by the post script

		// export environment variables
		core.exportVariable("SOURCE_DATE_EPOCH", source_date_epoch);

		// export step output variables
		core.setOutput("artifact_dir", artifact_dir);

		// export state information for the post step
		core.saveState("artifact_dir", artifact_dir);
		core.saveState("gpg_signing_key_id", gpg_signing_key_id);
		core.saveState("do_publish", do_publish);
		core.saveState("release_version", release_version);

	} catch (error) {
		core.setFailed(error.message);
	}
}

run();
