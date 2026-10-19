# CI/CD Pipeline with Docker and Jenkins

Jenkins runs in a container and builds, tests, publishes and deploys a small Node.js service to Docker Swarm. The repository shows three builds worth looking at: a successful release, a build that a failing test stopped before deployment, and a build that failed at the registry login.

Docker Hub: `kaj1/cicd-demo` (tags are Jenkins build numbers, plus `latest`)

## 1. Problem Statement

A development team wants to automate build, test and deployment of its containerized applications with Jenkins and Docker, for faster and more reliable deployments. The task is to:

- set up a Jenkins server in a Docker container,
- create a Jenkins pipeline that builds a Docker image for a sample application,
- add automated tests to the pipeline,
- push the image to Docker Hub,
- deploy to a Docker Swarm cluster as part of the pipeline,
- document the setup and explain how it improves the workflow.

## 2. Repository Layout

    app/src, app/test            Node.js service and its unit and integration tests (built-in node:test)
    Dockerfile                   multi-stage: "test" stage runs the tests, "runtime" stage is the shipped image
    Jenkinsfile                  Checkout, Test, Build, Push, Deploy, Smoke test
    docker-stack.yml             Swarm service: 2 replicas, start-first rolling update, automatic rollback
    jenkins/Dockerfile           Jenkins LTS plus Docker CLI and the buildx plugin
    jenkins/casc.yaml            Jenkins configuration as code: admin user, Docker Hub credential, pipeline job
    jenkins/plugins.txt          plugin list
    docker-compose.yml           runs Jenkins itself
    scripts/setup-env.sh         writes the git-ignored .env (token typed at a hidden prompt)
    scripts/jenkins-api.sh       wait, trigger, status and log helpers for the Jenkins API
    scripts/demo-failing-test.sh breaks a test on purpose, then reverts
    evidence/                    failing-test-demo.log, stack-services.txt

## 3. Steps to Build and Run

Prerequisites: Docker with Swarm active (`docker swarm init`), a GitHub repository holding this code, and a Docker Hub access token with Read and Write scope.

    # 1. Create .env (random Jenkins admin password, Docker Hub token typed at a hidden prompt)
    ./scripts/setup-env.sh

    # 2. Start Jenkins (the image build downloads the plugins)
    docker compose up -d --build
    ./scripts/jenkins-api.sh wait

    # 3. Run the pipeline
    ./scripts/jenkins-api.sh trigger
    ./scripts/jenkins-api.sh status
    ./scripts/jenkins-api.sh log | tail -40

    # 4. Check the deployment
    docker stack services cicd
    curl localhost:8095/version

    # 5. Demonstrate the safety net
    ./scripts/demo-failing-test.sh

Jenkins is at http://localhost:8081 (user `admin`, password in `.env`). The job `docker-cicd` is created from `jenkins/casc.yaml` and is set to poll the repository every minute.

## 4. The Pipeline

| Stage | What it does |
|---|---|
| Checkout | gets the code and records the commit id |
| Test | builds the Dockerfile's `test` target, which runs the unit and integration tests (the cache is bypassed for that stage, so the tests really run every time) |
| Build | builds the `runtime` image, tagged with the build number and `latest` |
| Push | logs in with a Jenkins credential and pushes both tags |
| Deploy | `docker stack deploy` with the new tag, one replica at a time, new task started before the old one stops, automatic rollback on failure |
| Smoke test | requires 10 consecutive responses from `/version` carrying the new build number |

## 5. Results

| Build | Commit | Result | What happened |
|---|---|---|---|
| 1 | first run | FAILURE | Test stage: `unknown flag: --progress`, because the Docker CLI in the Jenkins image had no buildx plugin |
| 2 | 916f6cb | SUCCESS (41 s) | image `kaj1/cicd-demo:2`, `cicd_app` 2/2 |
| 3 | fd4cd58 | FAILURE | tests deliberately broken: `# pass 2`, `# fail 3`. Build, Push, Deploy and Smoke test were skipped. The app kept serving build 2 |
| 4 | e317ad7 | FAILURE | revert of build 3. Tests passed (`# pass 5`, `# fail 0`) but Push failed with `unauthorized: incorrect username or password`. Deploy was skipped, so the app stayed on build 2 |
| 5 | e317ad7 | SUCCESS (54 s) | same commit, after the Docker Hub token was replaced. `cicd_app` 2/2 on `kaj1/cicd-demo:5`, `/version` reports build 5 |

Details are in `evidence/failing-test-demo.log`. The demo script expected build 4 to deploy, and it did not, which is why the log carries an explanation. The deployed image is 46.1 MB (Docker Hub).

Builds 3 and 4 show the pipeline doing its job: a bad commit never reaches production, and a failed release step leaves the previous release running.

## 6. Optimization Techniques Used

- **Test stage inside the Dockerfile:** tests run in a clean container with the exact runtime dependencies, so "works on my machine" cannot hide a failure. The shipped image comes from a separate stage and contains no test code.
- **Small, non-root runtime image** (`node:20-alpine`, `USER node`, a health check).
- **Rolling update with `start-first` and `failure_action: rollback`:** zero-gap deploys, and a bad release reverts automatically.
- **Smoke test on the deployed service,** so "deployed" means "serving the new build".
- **Jenkins configuration as code:** the user, the credential and the job are created from `casc.yaml`, so the server can be rebuilt without clicking through a wizard.
- **Pipeline safety options:** no concurrent builds, a 20 minute timeout, image pruning after each run.
- **Credentials handled by Jenkins:** the Docker Hub token reaches the pipeline through `withCredentials` and `docker login --password-stdin`, and is never written into the repository.

## 7. Challenges Faced and Solutions

| Challenge | Solution |
|---|---|
| Build 1 failed because the Docker CLI inside the Jenkins image did not know `docker build --progress`. | Added the `docker-buildx-plugin` package to `jenkins/Dockerfile` and rebuilt. The next build passed. |
| Build 4 failed at the Docker Hub login (`unauthorized`) although the same login worked in build 2. I did not find out why the old token stopped working. | Generated a new token, recreated `.env` and restarted Jenkins. Jenkins applied the new credential from configuration, and build 5 succeeded from the same commit. |
| The demo expected the revert build to deploy. | Documented the actual outcome in the evidence log instead of rewriting it. |
| Jenkins cannot receive GitHub webhooks from a host whose IP changes after each stop and start. | Configured polling every minute, plus a manual trigger helper. |

## 8. Security Notes

- `.env` (admin password and registry token) is git-ignored and created with mode 600.
- The Jenkins container mounts the host's Docker socket. That gives it root-equivalent control of the host, which is acceptable for a demo and not for a shared production server. A build agent in a separate VM or rootless builders would reduce the risk.
- Tokens should be deleted after the demo.

## 9. Deep Dive: Advantages of Docker in CI/CD

This answer comes from general practice, not from a measurement in this repository.

- **Consistent environments:** the same image runs in the test stage, in staging and in production, which removes most "works here, fails there" problems.
- **Isolation:** each build runs in its own container, so builds do not interfere and no tools have to be installed on the build server.
- **Speed through caching:** unchanged layers are reused, so rebuilds are fast.
- **Immutable, versioned artifacts:** an image tagged with the build number can be rolled forward or back exactly.
- **Easy automated rollout and rollback:** orchestrators such as Swarm can start new containers beside old ones, check their health and revert on failure.
- **Faster feedback and reliability:** every commit is tested and a failure stops the release automatically, as builds 3 and 4 show here.
