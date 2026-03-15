FROM jenkins/jenkins:lts

USER root
COPY plugins/docker /usr/local/bin/docker
RUN chmod +x /usr/local/bin/docker
USER jenkins

COPY plugins/*.hpi /usr/share/jenkins/ref/plugins/

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"