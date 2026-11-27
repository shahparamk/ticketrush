# check=skip=InvalidDefaultArgInFrom
# Jenkins build agent: the pinned inbound-agent base plus pinned, verified tools.
# Built on the Jenkins host at boot; Jenkins starts one fresh container per build.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG TERRAFORM_VERSION
ARG AWSCLI_VERSION
ARG NODE_VERSION

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Terraform, checksum-verified against HashiCorp's published SHA256SUMS (a tampered download fails the build)
RUN set -eux; cd /tmp; \
    base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"; \
    curl -fsSLO "$base/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"; \
    curl -fsSLO "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep "linux_amd64.zip" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -o "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -d /usr/local/bin; \
    rm -f terraform_*; \
    terraform version

# AWS CLI v2, pinned to the same version as the laptop
RUN set -eux; cd /tmp; \
    curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip"; \
    unzip -q awscliv2.zip; \
    ./aws/install; \
    rm -rf aws awscliv2.zip; \
    aws --version

# Node.js (for building the Lambda functions), checksum-verified against nodejs.org's SHASUMS256.txt
RUN set -eux; cd /tmp; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    file="node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    curl -fsSLO "$base/$file"; \
    curl -fsSLO "$base/SHASUMS256.txt"; \
    grep " $file\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "$file" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "$file" SHASUMS256.txt; \
    node --version; \
    npm --version

# Don't let Terraform phone home on every run ("out of date" notices)
ENV CHECKPOINT_DISABLE=1

# Builds run as the unprivileged jenkins user, never root
USER jenkins