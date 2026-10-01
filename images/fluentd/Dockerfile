FROM fluent/fluentd:v1.19.3-debian-2.4

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && gem install fluent-plugin-grafana-loki -v 1.3.0 --no-document \
    && gem install fluent-plugin-kubernetes_metadata_filter -v 3.8.0 --no-document \
    && apt-get purge -y build-essential \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && rm -rf /usr/lib/ruby/gems/*/cache/*.gem
USER fluent
