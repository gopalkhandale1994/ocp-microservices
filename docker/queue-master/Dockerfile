FROM eclipse-temurin:8-jre-alpine

ENV	SERVICE_USER=myuser \
	SERVICE_UID=10001 \
	SERVICE_GROUP=mygroup \
	SERVICE_GID=10001

RUN	addgroup -g ${SERVICE_GID} ${SERVICE_GROUP} && \
	adduser -g "${SERVICE_NAME} user" -D -H -G ${SERVICE_GROUP} -s /sbin/nologin -u ${SERVICE_UID} ${SERVICE_USER}
# No setcap/libcap here: this used to grant java cap_net_bind_service so it
# could bind privileged port 80 as non-root. We now bind on 8080 instead (see
# the k8s Deployment's command override), so it's unneeded -- and actively
# harmful, since OpenShift's no_new_privs enforcement blocks execution of any
# binary carrying a file capability, which made java fail to exec at all.

WORKDIR /usr/src/app
COPY ./target/*.jar ./app.jar

RUN	chown -R ${SERVICE_USER}:${SERVICE_GROUP} ./app.jar

USER ${SERVICE_USER}

ENTRYPOINT ["java","-Djava.security.egd=file:/dev/urandom","-jar","./app.jar", "--port=80"]
