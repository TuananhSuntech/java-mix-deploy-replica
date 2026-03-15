pipeline {
    agent any

    environment {
        DOCKER_IMAGE      = 'java-mix-deploy-replica'
        REGISTRY          = 'anh2019'
        STAGING_IP        = '18.141.25.13'
        PRODUCTION_IP     = '13.213.63.57'
        REPO_URL          = 'https://github.com/TuananhSuntech/java-mix-deploy-replica.git'
    }

    stages {

        // ── 1. CHECKOUT ────────────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                git url: "${REPO_URL}", branch: "${env.BRANCH_NAME}"
            }
        }

        // ── 2. TEST ────────────────────────────────────────────────────────────
        stage('Test') {
            steps {
                sh 'mvn test'
            }
            post {
                always {
                    junit allowEmptyResults: true,
                          testResults: 'target/surefire-reports/**/*.xml'
                }
            }
        }

        // ── 3. BUILD & PUSH TO REGISTRY ────────────────────────────────────────
        stage('Build & Push Docker Image') {
            steps {
                script {
                    def fullImage = "${REGISTRY}/${DOCKER_IMAGE}:${BUILD_NUMBER}"
                    def latestImage = "${REGISTRY}/${DOCKER_IMAGE}:latest"

                    withCredentials([usernamePassword(
                            credentialsId: 'dockerhub-credentials',
                            usernameVariable: 'DOCKER_USER',
                            passwordVariable: 'DOCKER_PASS')]) {
                        sh "echo \${DOCKER_PASS} | docker login -u \${DOCKER_USER} --password-stdin"
                    }

                    sh "docker build -t ${fullImage} -t ${latestImage} ."
                    sh "docker push ${fullImage}"
                    sh "docker push ${latestImage}"

                    // Dọn image local sau khi push xong
                    sh "docker rmi ${fullImage} ${latestImage} || true"
                    sh "docker logout"
                }
            }
        }

        // ── 4. DEPLOY TO STAGING ───────────────────────────────────────────────
        stage('Deploy to Staging') {
            when {
                changeRequest target: 'dev'
            }
            steps {
                echo 'Deploying to Staging...'
                // STAGING_SSH_KEY_FILE: tên biến riêng, tránh conflict với production
                withCredentials([sshUserPrivateKey(
                        credentialsId: 'staging-ssh-key',
                        keyFileVariable: 'STAGING_SSH_KEY_FILE')]) {
                    deploy("${STAGING_IP}", 'staging', "${STAGING_SSH_KEY_FILE}")
                }
            }
        }

        // ── 5. DEPLOY TO PRODUCTION ────────────────────────────────────────────
        stage('Deploy to Production') {
            when {
                changeRequest target: 'staging'
            }
            // Yêu cầu phê duyệt thủ công trước khi deploy production
            input {
                message 'Deploy lên Production?'
                ok 'Xác nhận Deploy'
                submitter 'admin,lead-dev'
            }
            steps {
                echo 'Deploying to Production...'
                // PRODUCTION_SSH_KEY_FILE: tên biến riêng, tránh conflict với staging
                withCredentials([sshUserPrivateKey(
                        credentialsId: 'production-ssh-key',
                        keyFileVariable: 'PRODUCTION_SSH_KEY_FILE')]) {
                    deploy("${PRODUCTION_IP}", 'production', "${PRODUCTION_SSH_KEY_FILE}")
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline thành công — Build #${BUILD_NUMBER}"
        }
        failure {
            echo "Pipeline thất bại — Build #${BUILD_NUMBER}"
            // Có thể gửi Slack/email notification ở đây
        }
        cleanup {
            // Xóa workspace sau mỗi build để tiết kiệm disk
            cleanWs()
        }
    }
}

// ── HÀM DEPLOY ─────────────────────────────────────────────────────────────────
def deploy(String serverIp, String profile, String sshKey) {

    def fullImage = "${env.REGISTRY}/${env.DOCKER_IMAGE}:${env.BUILD_NUMBER}"
    def sshOpts   = "-i ${sshKey} -o StrictHostKeyChecking=no"
    // Lưu ý: thêm host key của server vào known_hosts để bỏ StrictHostKeyChecking=no
    // ssh-keyscan -H <server_ip> >> ~/.ssh/known_hosts

    // ── Copy docker-compose và migration scripts lên server
    sh """
        scp ${sshOpts} docker-compose.yml ec2-user@${serverIp}:/home/ec2-user/
        scp ${sshOpts} -r migration       ec2-user@${serverIp}:/home/ec2-user/
    """

    // ── Deploy & chạy migration trên server
    sh """
        ssh ${sshOpts} ec2-user@${serverIp} '
            set -e

            # Pull image từ registry (không cần truyền .tar qua mạng)
            docker pull ${fullImage}

            cd /home/ec2-user

            export PROFILE=${profile}
            export IMAGE_TAG=${env.BUILD_NUMBER}
            export REGISTRY=${env.REGISTRY}
            export DOCKER_IMAGE=${env.DOCKER_IMAGE}

            # Dừng container cũ; xóa orphan container nếu có
            docker compose down --remove-orphans --timeout 30

            # Khởi động container mới và chờ healthcheck pass
            docker compose up -d --wait

            # ── Chờ PostgreSQL sẵn sàng (thay vì sleep cố định) ──────────────
            echo "Waiting for PostgreSQL to be ready..."
            for i in \$(seq 1 30); do
                if docker exec postgres pg_isready -U postgres -d demo -q; then
                    echo "PostgreSQL is ready after \${i}s"
                    break
                fi
                if [ "\$i" -eq 30 ]; then
                    echo "PostgreSQL not ready after 60s — aborting"
                    exit 1
                fi
                sleep 2
            done

            # ── Chạy migration ────────────────────────────────────────────────
            docker cp /home/ec2-user/migration/00_create_migration_history.sql postgres:/tmp/
            docker exec postgres psql -U postgres -d demo \
                -f /tmp/00_create_migration_history.sql

            for f in \$(ls /home/ec2-user/migration/*.sql | sort); do
                SCRIPT_NAME=\$(basename \$f)

                if [ "\$SCRIPT_NAME" = "00_create_migration_history.sql" ]; then
                    continue
                fi

                ALREADY_RUN=\$(docker exec postgres psql -U postgres -d demo \
                    -tAc "SELECT COUNT(*) FROM migration_history WHERE script_name = '"'"'\$SCRIPT_NAME'"'"'")

                if [ "\$ALREADY_RUN" = "0" ]; then
                    echo "Running migration: \$SCRIPT_NAME"
                    docker cp \$f postgres:/tmp/
                    docker exec postgres psql -U postgres -d demo \
                        -f /tmp/\$SCRIPT_NAME
                    docker exec postgres psql -U postgres -d demo \
                        -c "INSERT INTO migration_history (script_name) VALUES ('"'"'\$SCRIPT_NAME'"'"')"
                else
                    echo "Skipping (already run): \$SCRIPT_NAME"
                fi
            done

            # ── Dọn image cũ trên server ──────────────────────────────────────
            docker image prune -f
        '
    """
}