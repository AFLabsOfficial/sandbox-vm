FROM nixos/nix:latest

WORKDIR /src

RUN cat >> /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes
download-buffer-size = 2147483648
system-features = kvm benchmark big-parallel nixos-test
EOF

COPY . /src
