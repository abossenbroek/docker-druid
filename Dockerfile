FROM phusion/baseimage:0.11

# Set version and github repo which you want to build from
ENV GITHUB_OWNER apache
ENV DRUID_VERSION 0.14.0-incubating
ENV ZOOKEEPER_VERSION 3.4.14

#
# UTF-8 by default
#
RUN locale-gen en_US.UTF-8

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Java 8
RUN apt-get update \
      && apt-get install -y software-properties-common \
      && apt-add-repository -y ppa:webupd8team/java \
      && apt-get purge --auto-remove -y software-properties-common \
      && apt-get update \
      && apt-get install -y openjdk-8-jdk-headless \
                            mysql-server \
                            supervisor \
                            git \
                            wget \
      && apt-get clean \
      && rm -rf /var/cache/oracle-jdk8-installer \
      && rm -rf /var/lib/apt/lists/*

# Maven
RUN wget -q -O - http://archive.apache.org/dist/maven/maven-3/3.5.3/binaries/apache-maven-3.5.3-bin.tar.gz | tar -xzf - -C /usr/local \
      && ln -s /usr/local/apache-maven-3.5.3 /usr/local/apache-maven \
      && ln -s /usr/local/apache-maven/bin/mvn /usr/local/bin/mvn

# Zookeeper
RUN wget -q -O - http://www.us.apache.org/dist/zookeeper/zookeeper-$ZOOKEEPER_VERSION/zookeeper-$ZOOKEEPER_VERSION.tar.gz | tar -xzf - -C /usr/local \
      && cp /usr/local/zookeeper-$ZOOKEEPER_VERSION/conf/zoo_sample.cfg /usr/local/zookeeper-$ZOOKEEPER_VERSION/conf/zoo.cfg \
      && ln -s /usr/local/zookeeper-$ZOOKEEPER_VERSION /usr/local/zookeeper

# Druid system user
RUN adduser --system --group --no-create-home druid \
      && mkdir -p /var/lib/druid \
      && chown druid:druid /var/lib/druid


# trigger rebuild only if branch changed
ADD https://api.github.com/repos/$GITHUB_OWNER/incubator-druid/git/refs/heads/$DRUID_VERSION druid-version.json
RUN git clone -q --branch $DRUID_VERSION --depth 1 https://github.com/$GITHUB_OWNER/druid.git /tmp/druid
WORKDIR /tmp/druid
ENTRYPOINT /bin/bash
# package and install Druid locally
# use versions-maven-plugin 2.1 to work around https://jira.codehaus.org/browse/MVERSIONS-285
RUN mvn -U -B org.codehaus.mojo:versions-maven-plugin:2.1:set -DgenerateBackupPoms=false -DnewVersion=$DRUID_VERSION \
  && mvn -U -B clean install -DskipTests=true -Dmaven.javadoc.skip=true -Pdist \
  && cd distribution/target \
  && cp apache-druid-$DRUID_VERSION-bin.tar.gz /usr/local \
  && cd /usr/local \
  && tar -zxvf apache-druid-$DRUID_VERSION-bin.tar.gz \
  && rm apache-druid-$DRUID_VERSION-bin.tar.gz \
  && ln -s apache-druid-$DRUID_VERSION druid \
  && cd druid \
  && ln -s ../zookeeper-3.4.14 zk \
  && cd /usr/local/apache-druid-$DRUID_VERSION/extensions/mysql-metadata-storage \
  && wget http://central.maven.org/maven2/mysql/mysql-connector-java/5.1.38/mysql-connector-java-5.1.38.jar \
  && apt-get purge --auto-remove -y git \
  && apt-get clean \
  && rm -rf /tmp/* \
            /var/tmp/* \
            /usr/local/apache-maven-3.5.3 \
            /usr/local/apache-maven \
            /root/.m2

WORKDIR /root

# Setup metadata store and add sample data
ADD sample-data.sql sample-data.sql
RUN find /var/lib/mysql -type f -exec touch {} \; \
      && /etc/init.d/mysql start \
      && mysql -u root -e "GRANT ALL ON druid.* TO 'druid'@'localhost' IDENTIFIED BY 'diurd'; CREATE database druid CHARACTER SET utf8;" \
      && export DRUID_CLASSPATH=$(echo /usr/local/apache-druid-0.14.0-incubating/lib/*.jar | tr ' ' ':'):$(echo /usr/local/apache-druid-0.14.0-incubating/extensions/*jar | tr ' ' ':') \
      && cd /usr/local/druid/ \
      && java  \
          -Ddruid.metadata.storage.type=mysql \
          -Ddruid.metadata.storage.connector.connectURI=jdbc\:mysql\://localhost\:3306/druid \
          -Ddruid.metadata.storage.connector.user=druid \
          -Ddruid.metadata.storage.connector.password=diurd \
          -Ddruid.extensions.loadList=[\"mysql-metadata-storage\"] \
          -Ddruid.storage.type=local \
          -Ddruid.storage.storageDirectory=/var/lib/druid/ \
          -cp $DRUID_CLASSPATH  org.apache.druid.cli.Main tools metadata-init \
          --connectURI="jdbc:mysql://localhost:3306/druid" \
          --user=druid --password=diurd \
      && mysql -u root druid < /root/sample-data.sql \
      && /etc/init.d/mysql stop



# Setup supervisord
ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Expose ports:
# - 8081: HTTP (coordinator)
# - 8082: HTTP (broker)
# - 8083: HTTP (historical)
# - 8090: HTTP (overlord)
# - 3306: MySQL
# - 2181 2888 3888: ZooKeeper
EXPOSE 8081
EXPOSE 8082
EXPOSE 8083
EXPOSE 8090
EXPOSE 3306
EXPOSE 2181 2888 3888

WORKDIR /var/lib/druid
ENTRYPOINT export DRUID_CLASSPATH=$(echo /usr/local/apache-druid-0.14.0-incubating/lib/*.jar | tr ' ' ':'):$(echo /usr/local/apache-druid-0.14.0-incubating/extensions/*jar | tr ' ' ':') \
export HOSTIP="$(resolveip -s $HOSTNAME)" && find /var/lib/mysql -type f -exec touch {} \; && exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
