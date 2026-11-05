pipeline {
  agent any
  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 20, unit: 'MINUTES')
  }
  environment {
    IMAGE   = 'kaj1/cicd-demo'
    TAG     = "${env.BUILD_NUMBER}"
    STACK   = 'cicd'
    SERVICE = 'cicd_app'
    // Smoke-test tuning: raise these if deployments are slower in another environment.
    SMOKE_ATTEMPTS    = '60'
    SMOKE_SLEEP       = '2'
    SMOKE_CONSECUTIVE = '10'
    // Vulnerability scan before publishing: the full HIGH/CRITICAL report is archived; the build fails only on a
    // CRITICAL finding that already has a fix.
    TRIVY = 'docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ aquasec/trivy:latest'
    TRIVY_FAIL_SEVERITY = 'CRITICAL'
    SMOKE_GREET_PATH   = '/api/greet?name=Smoke'
    SMOKE_GREET_EXPECT = 'Hello, Smoke!'
  }
  stages {
    stage('Checkout') {
      steps {
        script { env.CURRENT = 'Checkout' }
        checkout scm
        script { env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim() }
        sh 'echo "building commit $GIT_SHA as build $TAG"'
      }
    }
    stage('Test') {
      steps {
        script { env.CURRENT = 'Test' }
        // --no-cache-filter makes sure the tests really run every time, not from cache.
        // The test stage always succeeds and writes reports/exit-code, so the reports exist even when tests fail;
        // the verdict is taken after the report has been published.
        sh 'rm -rf reports && docker build --progress=plain --no-cache-filter test --target test-report --output type=local,dest=reports .'
        junit testResults: 'reports/junit.xml', allowEmptyResults: false
        archiveArtifacts artifacts: 'reports/**', fingerprint: true
        sh 'test "$(cat reports/exit-code)" = "0"'
      }
    }
    stage('Build') {
      steps {
        script { env.CURRENT = 'Build' }
        sh 'docker build --target runtime --build-arg BUILD_NUMBER=${TAG} --build-arg GIT_SHA=${GIT_SHA} -t ${IMAGE}:${TAG} -t ${IMAGE}:latest .'
      }
    }
    stage('Scan') {
      steps {
        script { env.CURRENT = 'Scan' }
        sh '''
          mkdir -p reports
          { echo "Trivy scan of ${IMAGE}:${TAG} on $(date -u +%FT%TZ), scanner: $($TRIVY --version | head -1)"; echo; $TRIVY image --quiet --severity HIGH,CRITICAL ${IMAGE}:${TAG}; } | tee reports/trivy-${TAG}.txt
          $TRIVY image --quiet --ignore-unfixed --severity ${TRIVY_FAIL_SEVERITY} --exit-code 1 ${IMAGE}:${TAG}
        '''
      }
      post { always { archiveArtifacts artifacts: 'reports/trivy-*.txt', allowEmptyArchive: true } }
    }
    stage('Push') {
      steps {
        script { env.CURRENT = 'Push' }
        withCredentials([usernamePassword(credentialsId: 'dockerhub', usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
          sh '''
            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
            docker push ${IMAGE}:${TAG}
            docker push ${IMAGE}:latest
            docker logout
          '''
        }
        script {
          env.DIGEST = sh(returnStdout: true, script: 'docker inspect --format "{{index .RepoDigests 0}}" ${IMAGE}:${TAG} | cut -d@ -f2').trim()
          if (!(env.DIGEST ==~ /sha256:[0-9a-f]{64}/)) { error("could not read the digest of the pushed image: '${env.DIGEST}'") }
          echo "pushed ${env.IMAGE}:${env.TAG} as ${env.DIGEST}"
        }
      }
    }
    stage('Deploy') {
      steps {
        script {
          env.CURRENT = 'Deploy'
          // Record what is running BEFORE the update, so exactly that release can be restored.
          env.PREV_IMAGE = sh(returnStdout: true,
            script: 'docker service inspect "$SERVICE" --format "{{.Spec.TaskTemplate.ContainerSpec.Image}}" 2>/dev/null || true').trim()
          echo "previous release: ${env.PREV_IMAGE ?: 'none (first deployment)'}"
          env.DEPLOY_STARTED = 'true'
        }
        // tag@digest: the service runs exactly the image that was scanned and pushed
        sh 'IMAGE_TAG=${TAG}@${DIGEST} docker stack deploy -c docker-stack.yml ${STACK}'
      }
    }
    stage('Smoke test') {
      steps {
        script { env.CURRENT = 'Smoke test' }
        sh 'EXPECT_DIGEST="$DIGEST" bash scripts/smoke-test.sh "$TAG" "$GIT_SHA"'
      }
    }
  }
  post {
    success {
      script {
        currentBuild.description = "SUCCESS: build ${env.BUILD_NUMBER} (commit ${env.GIT_SHA}) deployed and verified"
        echo currentBuild.description
      }
    }
    failure {
      script {
        def kinds = ['Checkout': 'checkout failure', 'Test': 'test failure', 'Build': 'image-build failure',
                     'Scan': 'vulnerability-scan failure', 'Push': 'image-push failure', 'Deploy': 'deployment failure', 'Smoke test': 'smoke-test failure']
        def kind = kinds[env.CURRENT] ?: 'failure'
        def outcome = 'no deployment was started, so the running release was not touched'
        if (env.DEPLOY_STARTED == 'true') {
          try {
            sh 'bash scripts/rollback.sh "$PREV_IMAGE"'
            outcome = "rolled back to ${env.PREV_IMAGE} and verified"
          } catch (err) {
            outcome = 'ROLLBACK FAILED, manual action needed'
          }
        }
        currentBuild.description = "FAILED (${kind}, stage ${env.CURRENT}): ${outcome}"
        echo currentBuild.description
      }
    }
    always { sh 'docker image prune -f >/dev/null 2>&1 || true' }
  }
}
