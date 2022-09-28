FROM gitpod/workspace-full
# Kubectl
COPY --from=bitnami/kubectl /opt/bitnami/kubectl/bin/kubectl /usr/local/bin/kubectl
RUN echo 'source <(kubectl completion bash)' >> /home/gitpod/.bashrc
# Helm
COPY --from=alpine/helm /usr/bin/helm /usr/local/bin/helm
RUN echo 'source <(helm completion bash)' >> /home/gitpod/.bashrc
# K3sup
RUN curl -sLS https://get.k3sup.dev | sh \
  && sudo install k3sup /usr/local/bin/ \
  && rm -f k3sup \
  && k3sup version
# YQ
COPY --from=mikefarah/yq /usr/bin/yq /usr/local/bin/yq
