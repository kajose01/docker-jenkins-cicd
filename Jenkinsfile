pipeline {
  agent any
  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 20, unit: 'MINUTES')
  }
  environment {
    IMAGE = 'kaj1/cicd-demo'
    TAG   = "${env.BUILD_NUMBER}"
    STACK = 'cicd'
  }
  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script { env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim() }
        sh 'echo "building commit $GIT_SHA as build $TAG"'
      }
    }
    stage('Test') {
      steps {
        // --no-cache-filter makes sure the tests really run every time, not from cache
        sh 'docker build --progress=plain --no-cache-filter test --target test -t cicd-test:${TAG} .'
      }
    }
    stage('Build') {
      steps {
        sh 'docker build --target runtime --build-arg BUILD_NUMBER=${TAG} --build-arg GIT_SHA=${GIT_SHA} -t ${IMAGE}:${TAG} -t ${IMAGE}:latest .'
      }
    }
    stage('Push') {
      steps {
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
        sh 'IMAGE_TAG=${TAG} docker stack deploy -c docker-stack.yml ${STACK}'
      }
    }
    stage('Smoke test') {
      steps {
        sh '''
          ok=0
          for i in $(seq 1 60); do
            V=$(docker run --rm --network host busybox:1.36 wget -qO- -T 3 http://localhost:8095/version 2>/dev/null | grep -o '"build":"[^"]*"' | cut -d'"' -f4 || true)
            if [ "$V" = "$TAG" ]; then ok=$((ok+1)); else ok=0; fi
            [ $ok -ge 10 ] && { echo "smoke test passed: 10 consecutive responses from build $TAG"; exit 0; }
            sleep 2
          done
          echo "smoke test FAILED: build $TAG did not take over"; exit 1
        '''
      }
    }
  }
  post {
    success { echo "Build ${env.BUILD_NUMBER} deployed" }
    failure { echo "Build ${env.BUILD_NUMBER} failed, the previous release keeps running" }
    always  { sh 'docker image prune -f >/dev/null 2>&1 || true' }
  }
}
