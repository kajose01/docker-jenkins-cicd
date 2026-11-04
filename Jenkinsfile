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
        // --no-cache-filter makes sure the tests really run every time, not from cache
        sh 'docker build --progress=plain --no-cache-filter test --target test -t cicd-test:${TAG} .'
      }
    }
    stage('Build') {
      steps {
        script { env.CURRENT = 'Build' }
        sh 'docker build --target runtime --build-arg BUILD_NUMBER=${TAG} --build-arg GIT_SHA=${GIT_SHA} -t ${IMAGE}:${TAG} -t ${IMAGE}:latest .'
      }
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
        sh 'IMAGE_TAG=${TAG} docker stack deploy -c docker-stack.yml ${STACK}'
      }
    }
    stage('Smoke test') {
      steps {
        script { env.CURRENT = 'Smoke test' }
        sh 'bash scripts/smoke-test.sh "$TAG" "$GIT_SHA"'
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
                     'Push': 'image-push failure', 'Deploy': 'deployment failure', 'Smoke test': 'smoke-test failure']
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
