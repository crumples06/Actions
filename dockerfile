FROM ubuntu:22.04
RUN apt-get update && apt-get install -y openssh-server python3 sudo
RUN useradd -rm -d /home/ansible -s /bin/bash -g root -G sudo -u 1000 ansible
RUN echo 'ansible:ansible' | chpasswd
RUN echo 'ansible ALL=(ALL) NOOPASSWD:ALL' >> /etc/sudoers 
RUN mkdir /var/run/sshd
EXPOSE 22 
CMD ["/usr/sbin/sshd", "-D"]