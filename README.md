# CI/CD Pipeline with Docker and Jenkins

Jenkins runs in a container and builds, tests, scans, publishes and deploys a small Node.js service to Docker Swarm. The pipeline publishes a test report, deploys the exact image digest it scanned and pushed, verifies the running release, and restores the previous release if verification fails. The repository records the cases that matter: a successful release, a build that a failing test stopped before deployment, a build that failed at the registry login, and the rollback paths.

Docker Hub: `kaj1/cicd-demo` (tags are Jenkins build numbers, plus `latest`; builds that fail before the Push stage have no tag, which is why some numbers are missing)

## 1. Problem Statement

A development team wants to automate build, test and deployment of its containerized applications with Jenkins and Docker, for faster and more reliable deployments. The task is to:

- set up a Jenkins server in a Docker container,
- create a Jenkins pipeline that builds a Docker image for a sample application,
- add automated tests to the pipeline,
- push the image to Docker Hub,
- deploy to a Docker Swarm cluster as part of the pipeline,
- document the setup and explain how it improves the workflow.

## 2. Repository Layout

    app/src, app/test              Node.js service and its tests (built-in node:test, 15 tests)
    app/package-lock.json          lockfile (the app has no third-party dependencies)
    Dockerfile                     multi-stage: "test" runs the tests, "test-report" exports the reports, "runtime" is the shipped image
    Jenkinsfile                    Checkout, Test, Build, Scan, Push, Deploy, Smoke test, plus rollback and build summary
    docker-stack.yml               Swarm service: 2 replicas, start-first rolling update, automatic rollback, health check from the image
    jenkins/Dockerfile             Jenkins LTS (base pinned by digest) plus Docker CLI and the buildx plugin
    jenkins/casc.yaml              Jenkins configuration as code: admin user, Docker Hub credential, pipeline job
    jenkins/plugins.txt            all 73 plugins pinned to exact versions
    docker-compose.yml             runs Jenkins itself
    scripts/setup-env.sh           writes the git-ignored .env (token typed at a hidden prompt)
    scripts/jenkins-api.sh         wait, trigger, status and log helpers for the Jenkins API
    scripts/smoke-test.sh          post-deployment verification (see section 4)
    scripts/rollback.sh            restores the previous release and verifies it
    scripts/rollback-drill.sh      proves the Jenkins-level rollback (briefly replaces the live service)
    scripts/swarm-rollback-test.sh proves Swarm's automatic rollback (briefly replaces the live service)
    scripts/demo-failing-test.sh   breaks a test on purpose, checks the release is blocked, reverts, checks the redeploy
    scripts/clean-env-test.sh      builds and starts a throwaway Jenkins from the repository and checks it
    scripts/verify-plugins.sh      compares the live Jenkins plugins with jenkins/plugins.txt
    evidence/                      logs of the runs described below (section 10)

## 3. Steps to Build and Run

Prerequisites: Docker with Swarm active (`docker swarm init`), a GitHub repository holding this code, and a Docker Hub access token with Read and Write scope (see section 8 for how to scope and revoke it).

    # 1. Create .env (random Jenkins admin password, Docker Hub token typed at a hidden prompt)
    ./scripts/setup-env.sh

    # 2. Start Jenkins (the image build installs the pinned plugins)
    docker compose up -d --build
    ./scripts/jenkins-api.sh wait

    # 3. Run the pipeline
    ./scripts/jenkins-api.sh trigger
    ./scripts/jenkins-api.sh status
    ./scripts/jenkins-api.sh log | tail -40

    # 4. Check the deployment
    docker stack services cicd
    curl localhost:8095/version

    # 5. Run the tests without Jenkins (reports land in ./reports; exit-code holds the test result)
    docker build --no-cache-filter test --target test-report --output type=local,dest=reports .
    cat reports/exit-code

    # 6. Demonstrate the safety nets (each pushes commits or replaces the live service briefly)
    ./scripts/demo-failing-test.sh
    ./scripts/rollback-drill.sh
    ./scripts/swarm-rollback-test.sh

Jenkins is at http://localhost:8081 (user `admin`, password in `.env`). The job `docker-cicd` is created from `jenkins/casc.yaml` and polls the repository every minute. The demo script refuses to start unless the working tree is clean, `main` is in sync with origin, and the running app already serves the commit at HEAD.

## 4. The Pipeline

| Stage | What it does |
|---|---|
| Checkout | gets the code and records the commit id |
| Test | builds the Dockerfile's `test-report` target. The test stage always finishes and writes `junit.xml`, `test-output.txt` (with the coverage table) and `exit-code`, so a report exists even when tests fail. Jenkins publishes the JUnit report and archives the files, and only then fails the build if `exit-code` is not 0. The cache is bypassed for that stage |
| Build | builds the `runtime` image, tagged with the build number and `latest` |
| Scan | scans the image with Trivy and archives the HIGH/CRITICAL report. The build fails on a CRITICAL finding that already has a fix |
| Push | logs in with a Jenkins credential, pushes both tags and records the digest of the pushed image |
| Deploy | records the image currently running, then `docker stack deploy` with `tag@digest`: one replica at a time, new task started before the old one stops, Swarm rolls back automatically if the update fails |
| Smoke test | `scripts/smoke-test.sh`: 10 consecutive `/version` responses with the new build number and commit, `/health` returns 200, a valid `/api/greet` request returns the expected greeting, every replica runs the new tag, and every replica runs the pushed digest |

After a failure, the build description says which stage failed (test, scan, push, deployment or smoke test) and what happened to the running release. If the failure happened after the deployment started, `scripts/rollback.sh` restores exactly the image that was recorded before the update and verifies that it is serving again.

**Two different rollbacks.** Swarm's automatic rollback (`failure_action: rollback` in the stack file) reacts to tasks that fail while an update is in progress. The Jenkins rollback reacts to a release whose tasks look healthy to Swarm but fail the smoke test. They are tested separately (section 5). `rollback.sh` uses `docker service update --image <previous>` because that is harmless when Swarm has already rolled back.

## 5. Results

Builds 1 to 5 are the original assignment run. Later rows are the changes made after the review.

| Build | Commit | Result | What happened |
|---|---|---|---|
| 1 | first run | FAILURE | Test stage: `unknown flag: --progress`, because the Docker CLI in the Jenkins image had no buildx plugin |
| 2 | 916f6cb | SUCCESS (41 s) | image `kaj1/cicd-demo:2`, `cicd_app` 2/2 |
| 3 | fd4cd58 | FAILURE | tests deliberately broken: `# pass 2`, `# fail 3`. Build, Push, Deploy and Smoke test were skipped. The app kept serving build 2 |
| 4 | e317ad7 | FAILURE | revert of build 3. Tests passed but Push failed with `unauthorized: incorrect username or password`. Deploy was skipped, so the app stayed on build 2 |
| 5 | e317ad7 | SUCCESS (54 s) | same commit, after the Docker Hub token was replaced. `cicd_app` 2/2 on `kaj1/cicd-demo:5` |
| 6 | 7e70136 | SUCCESS | the commit that was submitted for review |
| 7 | f38bafc | FAILURE | Push failed again with `unauthorized`: the Docker Hub token held by Jenkins was no longer valid. Deploy was skipped and build 6 kept running (`evidence/registry-failure-build7.log`) |
| 8 | 62b1d62 | SUCCESS | first run with rollback support and the stronger smoke test, after the token was replaced |
| 23 | b360add | SUCCESS | Jenkins test report: 15 passed, 0 failed |
| 24 | ce64094 | SUCCESS | Node 24 base image, Trivy scan with 0 findings, deployed and verified by digest `sha256:40a1f684...` on 2 of 2 replicas, `node --version` in the container `v24.22.2` |
| 32 | 3e803e5 | FAILURE | final demo run, scenario 1: the greeting was deliberately broken. The Test stage reported 10 passed and 5 failed; Build, Scan, Push, Deploy and Smoke test were skipped. The app kept serving build 31 |
| 33 | 6ad8630 | SUCCESS | final demo run, scenario 2: the revert was deployed. 15 tests passed, scan clean, deployed as digest `sha256:3239da9d2b17...` on 2 of 2 replicas, `/version` reports build 33 and commit 6ad8630 |

Other results, with their evidence files:

- **Failing test blocked, then revert deployed** (`scripts/demo-failing-test.sh`): `evidence/demo-20261111-211303` has the full Jenkins console log of both builds (32 and 33). Older folders with the same prefix come from earlier versions of the script. The run passed 16 of 16 checks: the broken build failed at Test, the Deploy stage never ran, the old build kept serving, and the revert deployed as the next build with the commit that Git reported. `evidence/failing-test-demo.log` is the log of the first version of this demo and is kept as it was.
- **Jenkins-level rollback** (`evidence/rollback-drill.log`): a release whose tasks run but do not serve the app was deployed. Swarm treated the update as successful, the smoke test failed, and `rollback.sh` restored `kaj1/cicd-demo:6` with 2 of 2 replicas.
- **Swarm automatic rollback** (`evidence/swarm-rollback.log`): a release that fails its health check was deployed. Swarm reported `rollback_completed` by itself, restored the previous image digest, and all 20 requests to `/version` during the test got HTTP 200. The log shows the outcome; it does not name the exact trigger.
- **Clean environment** (`evidence/clean-env-test.log`, 5 of 5): a throwaway Jenkins built from the repository boots, creates the `docker-cicd` job from `casc.yaml`, refuses anonymous access, and installs exactly the pinned plugins.
- **Image scan** (`evidence/trivy-cicd-demo.txt`): Trivy 0.76.1 on `kaj1/cicd-demo:24` reports 0 vulnerabilities on Alpine 3.24.3 and in the Node packages.
- **Image size:** 244 MB as reported by `docker images` (uncompressed) for the current `latest` image. An earlier version of this README quoted 46.1 MB for build 5 without saying how it was measured, so that number is dropped. The compressed size is on the Docker Hub tag page.

## 6. Optimization Techniques Used

- **Test stage inside the Dockerfile:** tests run in a clean container with the exact runtime dependencies. The test stage always succeeds and records its exit status, so reports are exported even for failing runs; the Jenkinsfile decides pass or fail after publishing them.
- **Small, non-root runtime image:** `node:24-alpine` pinned by digest, `USER node`, a health check, and npm and yarn removed from the shipped image (the app does not use them). The runtime image holds only `package.json` and `src`.
- **Image scan before publishing:** the scan found 26 HIGH or CRITICAL findings in the earlier Node 20 image, all with fixes available. After moving to Node 24 and removing npm from the runtime stage, the same scan reports 0.
- **Deploy and verify by digest:** the service runs `tag@digest`, and the smoke test checks that every replica runs the digest that was pushed.
- **Rolling update with `start-first` and `failure_action: rollback`,** plus an explicit Jenkins rollback for failures Swarm cannot see.
- **Smoke test on the deployed service:** "deployed" means the new build and commit are serving, `/health` and `/api/greet` work, and all replicas are on the new image. Timeouts and retries are environment variables.
- **Reproducible Jenkins:** all 73 plugins pinned to exact versions, the Jenkins base image pinned by digest, and a clean-environment test that rebuilds it from the repository.
- **Jenkins configuration as code:** the user, the credential and the job are created from `casc.yaml`.
- **Test reports and coverage:** the JUnit report is published in Jenkins, and the coverage table is archived with the build.
- **Pipeline safety options:** no concurrent builds, a 20 minute timeout, image pruning after each run.
- **Credentials handled by Jenkins:** the Docker Hub token reaches the pipeline through `withCredentials` and `docker login --password-stdin`, and is never written into the repository.

## 7. Challenges Faced and Solutions

| Challenge | Solution |
|---|---|
| Build 1 failed because the Docker CLI inside the Jenkins image did not know `docker build --progress`. | Added the `docker-buildx-plugin` package to `jenkins/Dockerfile` and rebuilt. The next build passed. |
| The Docker Hub login failed twice (build 4 and build 7) with `unauthorized` although it had worked before. I did not find out why the token stopped working. | Generated a new token, replaced it in `.env`, tested it with `docker login` before use, and recreated the Jenkins container so configuration as code applied the new credential. Builds 5 and 8 then passed. Tokens are now short-lived (section 8). |
| The review pointed out that plugins and the Jenkins base image were not pinned. Building from the 7-name plugin list resolved to 73 plugins, and 8 of them had a different version from the running Jenkins. | Pinned all 73 versions and the base image digest. My first digest-pinning command wrote an empty digest and the build failed; the clean-environment test caught it, and the digest is now read from the pull output and validated before the file is edited. |
| The `junit` plugin was not installed, so the test report step could not be added to the pipeline. | Added it to the pinned list, rebuilt the image and restarted Jenkins (a backup of the Jenkins home volume existed from before these changes). |
| A failed test must still produce a report, but a failing `RUN npm test` stops the Docker build before anything can be exported. | The test stage always succeeds and writes an exit-code file; the Jenkinsfile publishes the report first and then fails the build from that file. |
| The first version of the demo reported a broken build as successful. A build of an earlier commit was still running when it started, and it took that build for the broken commit's build. | The demo now requires the app to serve the commit at HEAD before it starts, and it waits for the build whose console log names the commit it pushed. |
| The second version waited six minutes and reported a timeout for a build that had already failed. `jenkins-api.sh log \| grep -q` can fail under `set -o pipefail`, because `grep -q` exits early and cuts the pipe. | The script reads the whole log into a variable before matching it. A test with a 3 MB log reproduced the bug and the fix. |
| The Trivy scan of the Node 20 image found 26 HIGH or CRITICAL issues, including one CRITICAL in `tar`. Node 20 is also past its end of life. | Moved to Node 24, pinned by digest. The findings were in packages bundled with npm, which the app does not use, so npm and yarn are removed from the runtime image. The OpenSSL libraries are upgraded explicitly. The rescan reports 0 findings. |
| A scripted check reported "cannot reach Jenkins" when the real problem was the square brackets in a `curl` URL, which `curl` reads as a range. | Added `curl -g` and a clearer error message. |
| Jenkins cannot receive GitHub webhooks from a host whose IP changes after each stop and start. | Polling every minute, plus a manual trigger helper. |

## 8. Security Notes

- `.env` (admin password and registry token) is git-ignored and created with mode 600.
- **Docker socket:** the Jenkins container mounts the host's Docker socket, and the build uses it. That gives anyone who can change the pipeline root-equivalent control of the host. This is acceptable for a single-user demo and not for a shared or production server. For that, run builds on an isolated agent or a dedicated VM, or use rootless builders. This repository does not implement that.
- **Who can change the pipeline:** the pipeline is read from the GitHub repository, so anyone with push access can run commands with the Docker socket and the Docker Hub credential. Restrict push access to the repository and to the Jenkins configuration.
- **Network exposure:** `docker-compose.yml` publishes Jenkins on port 8081 on all interfaces. On a cloud host the security group must not expose it to the internet; this repository does not enforce that.
- **Command line:** `scripts/jenkins-api.sh` passes the admin password to `curl` on the command line, which other local users could see in the process list. This is acceptable on a single-user demo server.
- **Registry token:** use a Docker Hub personal access token with Read and Write scope only (no delete), restricted to `kaj1/cicd-demo` where the account allows it, with a short expiry. Test it with `docker login` before putting it in `.env`, and delete it from Docker Hub when the demo is finished.
- **Image scanning:** every image is scanned before it is pushed. The scanner runs from the `latest` tag of its image, so the version is written into each report (Trivy 0.76.1 for build 24).
- **Image signing and provenance are not implemented.** Deployment checks the image digest, which proves that the running image is the one that was scanned and pushed, but it does not prove who built it. Signing would need a key management decision that this demo does not make.
- **Image retention policy** (a documented procedure, not automation): keep the last 10 build tags and the tag of the release currently running, because it is the rollback target. Delete older tags from Docker Hub by hand after checking that none is deployed. `latest` is never deployed; the service uses `tag@digest`.
- **Not pinned:** the Docker CLI and buildx plugin in the Jenkins image come from Docker's apt repository at build time without exact versions, and Trivy runs from its `latest` tag. Pinning them would need exact apt versions and a scanner version or digest; this repository records the scanner version in each report instead.
- Back up the Jenkins home volume before upgrading Jenkins, and refresh credentials after any `.env` change by recreating the container (`docker compose up -d --force-recreate jenkins`).

## 9. Deep Dive: Advantages of Docker in CI/CD

This answer comes from general practice, not from a measurement in this repository.

- **Consistent environments:** the same image runs in the test stage, in staging and in production, which removes most "works here, fails there" problems.
- **Isolation:** each build runs in its own container, so builds do not interfere and no tools have to be installed on the build server.
- **Speed through caching:** unchanged layers are reused, so rebuilds are fast.
- **Immutable, versioned artifacts:** an image tagged with the build number, and identified by its digest, can be rolled forward or back exactly.
- **Easy automated rollout and rollback:** orchestrators such as Swarm can start new containers beside old ones, check their health and revert on failure.
- **Faster feedback and reliability:** every commit is tested and scanned, and a failure stops the release automatically, as the failing-test demo shows.

## 10. Evidence

| File | What it shows |
|---|---|
| `evidence/failing-test-demo.log` | first version of the failing-test demo (builds 3, 4, 5) |
| `evidence/registry-failure-build7.log` | build 7: registry login failed, Deploy skipped, previous release kept running |
| `evidence/rollback-drill.log` | Jenkins-level rollback after a failed smoke test |
| `evidence/swarm-rollback.log` | Swarm's automatic rollback of a release that fails its health check |
| `evidence/clean-env-test.log` | throwaway Jenkins built from the repository |
| `evidence/plugin-check.log` | live Jenkins plugins compared with the pinned list |
| `evidence/trivy-cicd-demo.txt` | Trivy report of build 24 |
| `evidence/stack-services.txt` | service snapshot from the original run |
