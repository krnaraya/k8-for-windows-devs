FROM quay.io/mhildenb/win-demo-base:latest

USER root

# FIXME: Would rather install this from rpm, but can't get the instructions to work
# https://github.com/kubevirt/kubevirt/releases/download/v0.33.0/virtctl-v0.33.0-linux-x86_64
RUN KUBEVIRT_VERSION=v0.33.0 && wget -O /usr/local/bin/virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64 && \
    chmod +x /usr/local/bin/virtctl

ENV PATH="$PATH:/opt/mssql-tools/bin"

# Best to use the latest version of oc client with 4.6 due to bugs like this: https://bugzilla.redhat.com/show_bug.cgi?id=1860789
RUN wget -qO- https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/4.6.0-rc.2/openshift-client-linux-4.6.0-rc.2.tar.gz | tar -zxvf - -C /usr/local/bin oc && \
    chmod 755 /usr/local/bin/oc && rm /usr/local/bin/kubectl && ln -s /usr/local/bin/oc /usr/local/bin/kubectl

# Use the operator-sdk to deploy the wmco
ENV OPERATOR_SDK_VERSION=v0.18.1
RUN curl -LO https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}/operator-sdk-${OPERATOR_SDK_VERSION}-x86_64-linux-gnu && \
    chmod +x operator-sdk-${OPERATOR_SDK_VERSION}-x86_64-linux-gnu && mkdir -p /usr/local/bin/ && \
    cp operator-sdk-${OPERATOR_SDK_VERSION}-x86_64-linux-gnu /usr/local/bin/operator-sdk && rm operator-sdk-${OPERATOR_SDK_VERSION}-x86_64-linux-gnu

# Add kamel functionality
RUN wget -qO- https://github.com/apache/camel-k/releases/download/v1.2.0/camel-k-client-1.2.0-linux-64bit.tar.gz | tar -zxvf - -C /usr/local/bin ./kamel && \
    chmod 755 /usr/local/bin/kamel

RUN ln -s /usr/local/bin/kubectl /usr/bin/kubectl

USER default