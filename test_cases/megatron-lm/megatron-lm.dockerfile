FROM nvcr.io/nvidia/pytorch:23.01-py3

ARG EFA_INSTALLER_VERSION=latest
ARG AWS_OFI_NCCL_VERSION=v1.6.0
ARG NCCL_TESTS_VERSION=master
ARG OPEN_MPI_PATH=/opt/amazon/openmpi
######################

RUN apt-get update -y
RUN apt-get remove -y --allow-change-held-packages \
                      libmlx5-1 ibverbs-utils libibverbs-dev libibverbs1 \
                      libnccl2 libnccl-dev
RUN rm -rf /opt/hpcx \
    && rm -rf /usr/local/mpi \
    && rm -rf /usr/local/ucx \
    && rm -f /etc/ld.so.conf.d/hpcx.conf \
    && ldconfig

######################
# Set this enviroment variable for SageMaker to launch SMDDP correctly.
######################
ENV SAGEMAKER_TRAINING_MODULE=sagemaker_pytorch_container.training:main
######################
# Add enviroment variable for processes to be able to call fork()
######################
ENV RDMAV_FORK_SAFE=1
######################
# Indicate the container type
######################
ENV DLC_CONTAINER_TYPE=training

RUN DEBIAN_FRONTEND=noninteractive apt install -y --allow-unauthenticated \
    git \
    gcc \
    vim \
    kmod \
    openssh-client \
    openssh-server \
    build-essential \
    curl \
    autoconf \
    libtool \
    gdb \
    automake \
    cmake \
    apt-utils && \
    DEBIAN_FRONTEND=noninteractive apt autoremove -y


RUN mkdir -p /var/run/sshd && \
    sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config && \
    sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd


RUN rm -rf /root/.ssh/ \
 && mkdir -p /root/.ssh/ \
 && ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa \
 && cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys \
 && printf "Host *\n  StrictHostKeyChecking no\n" >> /root/.ssh/config

ENV LD_LIBRARY_PATH=/usr/local/cuda/extras/CUPTI/lib64:/opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/aws-ofi-nccl/install/lib:$LD_LIBRARY_PATH
ENV PATH=/opt/amazon/openmpi/bin/:/opt/amazon/efa/bin:/usr/bin:/usr/local/bin:$PATH

#################################################
## Install EFA installer
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && tar -xf $HOME/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y --skip-kmod

###################################################
## Install NCCL
RUN git clone https://github.com/NVIDIA/nccl /opt/nccl \
    && cd /opt/nccl \
    && git checkout v2.15.5-1 \
    && make -j$(nproc) src.build CUDA_HOME=/usr/local/cuda \
    NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86 -gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_75,code=sm_75 -gencode=arch=compute_70,code=sm_70 -gencode=arch=compute_60,code=sm_60"

###################################################
## Install AWS-OFI-NCCL plugin
RUN export OPAL_PREFIX="" \
    && git clone https://github.com/aws/aws-ofi-nccl.git /opt/aws-ofi-nccl \
    && cd /opt/aws-ofi-nccl \
    && env \
    && git checkout ${AWS_OFI_NCCL_VERSION} \
    && ./autogen.sh \
    && ./configure --prefix=/opt/aws-ofi-nccl/install \
       --with-libfabric=/opt/amazon/efa \
       --with-cuda=/usr/local/cuda \
       --with-mpi=/opt/amazon/openmpi/ \
       --enable-platform-aws \
    && make && make install

###################################################
## Install NCCL-tests
RUN git clone https://github.com/NVIDIA/nccl-tests.git /workspace/nccl-tests \
    && cd /workspace/nccl-tests \
    && git checkout ${NCCL_TESTS_VERSION} \
    && make MPI=1 \
       MPI_HOME=/opt/amazon/openmpi/ \
       CUDA_HOME=/usr/local/cuda \
       NCCL_HOME=/opt/nccl/build \
       NVCC_GENCODE="-gencode=arch=compute_86,code=sm_86 -gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_75,code=sm_75 -gencode=arch=compute_70,code=sm_70 -gencode=arch=compute_60,code=sm_60"

RUN rm -rf /var/lib/apt/lists/*
ENV LD_PRELOAD=/opt/nccl/build/lib/libnccl.so


RUN echo "hwloc_base_binding_policy = none" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf \
 && echo "rmaps_base_mapping_policy = slot" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf

#RUN pip3 install awscli pynvml sagemaker-training mpi4py
RUN pip3 install awscli
RUN pip3 install pynvml
RUN pip3 install sagemaker-training
#RUN PATH=$OPEN_MPI_PATH/bin/mpicc:$PATH pip3 install mpi4py
#RUN pip3 install mpi4py

RUN mv $OPEN_MPI_PATH/bin/mpirun $OPEN_MPI_PATH/bin/mpirun.real \
 && echo '#!/bin/bash' > $OPEN_MPI_PATH/bin/mpirun \
 && echo '/opt/amazon/openmpi/bin/mpirun.real "$@"' >> $OPEN_MPI_PATH/bin/mpirun \
 && chmod a+x $OPEN_MPI_PATH/bin/mpirun

######################
# Install SageMaker PyTorch training.
######################
WORKDIR /root
RUN pip install --no-cache-dir -U \
    smclarify \
    "sagemaker>=2,<3" \
    sagemaker-experiments==0.* \
    sagemaker-pytorch-training

######################
# Install libboost from source.
# This package is needed for smdataparallel functionality (for networking asynchronous IO).
######################
WORKDIR /
RUN wget https://sourceforge.net/projects/boost/files/boost/1.73.0/boost_1_73_0.tar.gz/download -O boost_1_73_0.tar.gz \
    && tar -xzf boost_1_73_0.tar.gz \
    && cd boost_1_73_0 \
    && ./bootstrap.sh \
    && ./b2 threading=multi -j 64 cxxflags=-fPIC cflags=-fPIC install || true \
    && cd .. \
    && rm -rf boost_1_73_0.tar.gz \
    && rm -rf boost_1_73_0

######################
# Install SageMaker data parallel binary (SMDDP)
# Start with dependencies
######################
RUN apt-get update && apt-get install -y  --no-install-recommends \
        jq \
        libhwloc-dev \
        libnuma1 \
        libnuma-dev \
        libssl1.1 \
        libtool \
        hwloc \
    && rm -rf /var/lib/apt/lists/*

######################
# Add boost and SMDDP to LD_LIBRARY path
######################
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib/python3.8/dist-packages/smdistributed/dataparallel/lib:$LD_LIBRARY_PATH

######################
# Transformers dependencies used in the model
######################
RUN pip install transformers==4.21.0

#####################
# Install megatron-lm
#####################
RUN cd /tmp && git clone https://github.com/NVIDIA/Megatron-LM.git \
        && cd Megatron-LM \
        && python3 -m pip install pybind11 \
        && python -m pip install python-etcd==0.4.5


WORKDIR /tmp/Megatron-LM