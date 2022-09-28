FROM gitpod/workspace-full
# Kubectl
COPY --from=bitnami/kubectl /opt/bitnami/kubectl/bin/kubectl /usr/local/bin/kubectl
RUN echo 'source <(kubectl completion bash)' >> /home/gitpod/.bashrc
# Helm
COPY --from=alpine/helm /usr/bin/helm /usr/local/bin/helm
RUN echo 'source <(helm completion bash)' >> /home/gitpod/.bashrc
# Terraform
COPY --from=quay.io/terraform-docs/terraform-docs /usr/local/bin/terraform-docs /usr/local/bin/terraform-docs
RUN git clone https://github.com/tfutils/tfenv.git /home/gitpod/.tfenv \
  && sudo ln -s /home/gitpod/.tfenv/bin/* /usr/local/bin \
  && tfenv install \
  && tfenv use latest \
  && curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash
# K3sup
RUN curl -sLS https://get.k3sup.dev | sh \
  && sudo install k3sup /usr/local/bin/ \
  && rm -f k3sup \
  && k3sup version
# YQ
COPY --from=mikefarah/yq /usr/bin/yq /usr/local/bin/yq
# Tools
RUN npm i -g markdown-toc
