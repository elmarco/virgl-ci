#!/bin/bash
#
# Run virgl tests with up to date renderer, qemu & mesa

set -e
#set -x

PREFIX="$(pwd)"
me=`basename "$0"`

guest_type=fedora-23
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:$LD_LIBRARY_PATH"
SSH_OPTS="-q -o ConnectTimeout=1 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
HOST_PKGS="libguestfs-tools libguestfs-xfs virt-install autoreconf spice-server-devel"
HOST_BUILD_PKGS="qemu virglrenderer"

git-pull() {
    mkdir -p "$PREFIX/src"
    cd "$PREFIX/src"
    [ ! -d "$2" ] && git clone "$1/$2"
    cd "$PREFIX/src/$2"
    git pull
}

ssh_vm_help="Ssh on the test VM"
ssh_vm_args="CMD..."
ssh-vm() {
    ssh $SSH_OPTS user@virgl-test.local "$@"
}

scp-vm() {
    scp -r $SSH_OPTS user@virgl-test.local:$1 $2
}

build_vm_help="Build a new test VM"
build-vm() {
    export LIBGUESTFS_MEMSIZE=4096

    TEMP="$(mktemp)"
    cat <<'EOF' > "$TEMP"
    curl -s https://repos.fedorapeople.org/repos/thl/kernel-vanilla.repo | tee /etc/yum.repos.d/kernel-vanilla.repo
    dnf -y --enablerepo=kernel-vanilla-mainline update
EOF

    cd "$PREFIX"
    virt-builder \
        $guest_type \
        --output virgl-test.qcow2 \
        --format qcow2 \
        --size 20G \
        --hostname virgl-test \
        --mkdir /home/user \
        --run "$TEMP" \
        --install qemu-guest-agent,avahi,waffle,yum-utils,ccache,gcc-c++,git,automake,libtool,python3-numpy,python3-mako,'@Basic Desktop',@GNOME \
        --run-command "sed -i -e 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=0/g' /etc/default/grub" \
        --run-command "echo kernel.sysrq=1 >> /etc/sysctl.conf" \
        --run-command "grub2-mkconfig -o /boot/grub2/grub.cfg" \
        --firstboot-command 'dnf builddep -y mesa piglit glmark2' \
        --firstboot-command 'useradd -m -p "" user' \
        --firstboot-command 'gpasswd wheel -a user' \
        --firstboot-command 'poweroff'

    virt-install \
        -n virgl-test \
        --boot emulator="$PREFIX/bin/qemu-system-x86_64" \
        --memory 2048 \
        --vcpus 4 \
        --cpu host \
        --os-type=linux \
        --os-variant=fedora22 \
        -w bridge=virbr0,model=virtio \
        --disk virgl-test.qcow2 \
        --import \
        --graphics spice,gl=yes \
        --noautoconsole

    while [ "$(virsh domstate virgl-test)" != 'shut off' ]; do sleep 1 ; done

    virt-customize \
        -d virgl-test \
        --ssh-inject user \
        --run-command 'chown user.user -R /home/user' \
        --selinux-relabel
}

startx-vm() {
    ssh-vm "nohup sudo Xorg -nolisten tcp -noreset :42 vt5 -auth /tmp/xauth >/dev/null 2>&1 &"
    ssh-vm "DISPLAY=:42 nohup mutter >/dev/null 2>&1 &"
}

check-vm() {
    ssh-vm dmesg | grep "virgl 3d acceleration enabled" > /dev/null || echo "No 3D!"
    ssh-vm sudo /usr/bin/wflinfo --platform=gbm --api=gl | grep "Gallium 0.4 on virgl" >/dev/null
}

start_vm_help="Start the test VM"
start-vm() {
    virsh dominfo virgl-test | grep running >/dev/null || virsh start virgl-test
    while ! ssh-vm true 2>/dev/null ; do true ; done
    startx-vm
    check-vm
}

stop_vm_help="Stop the test VM"
stop-vm() {
    if virsh dominfo virgl-test | grep running >/dev/null ; then
	virsh destroy --graceful virgl-test
    fi
}


make-install-mesa() {
    cd "$PREFIX/src/mesa"
    ./autogen.sh \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --enable-osmesa \
        --enable-selinux \
        --enable-glx-tls \
        --enable-texture-float=yes \
        --with-egl-platforms=x11,drm,surfaceless,wayland \
        --enable-gallium-llvm --enable-llvm-shared-libs \
        --with-gallium-drivers=virgl,swrast \
        --with-dri-drivers=swrast
    make -j4
    sudo make install
}

update_mesa_vm_help="Update mesa in VM"
update-mesa-vm() {
    start-vm
    ssh-vm "$(< "$me")
git-pull git://anongit.freedesktop.org/mesa mesa
make-install-mesa"
}

make-piglit() {
    cd "$PREFIX/src/piglit"
    cmake .
    make
}

update_piglit_vm_help="Update piglit in VM"
update-piglit-vm() {
    start-vm
    ssh-vm "$(< "$me")
git-pull git://anongit.freedesktop.org piglit
make-piglit
"
}

piglit-sanity-vm() {
    start-vm
    startx-vm

    ssh-vm "DISPLAY=:42 ~/src/piglit/piglit run -o sanity results/sanity"
}

piglit_vm_help="Run piglit in vm"
piglit-vm() {
    start-vm
    startx-vm

    ssh-vm "DISPLAY=:42 src/piglit/piglit run -o -x glean -x max-input-components -x 2-buffers-bug -v tests/all results/all
    ~/src/piglit/piglit summary --overwrite html summary/all results/all"
}

make-install-glmark2() {
    cd "$PREFIX/src/glmark2"
    ./waf configure --prefix=~ --with-flavors=drm-gl
    ./waf build
    ./waf install
}

update_glmark2_vm_help="Update glmark2 in VM"
update-glmark2-vm() {
    start-vm
    ssh-vm "$(< "$me")
git-pull https://github.com/elmarco glmark2
make-install-glmark2
"
}

#update_ezbench_vm_help="Update ezbench in VM"
update-ezbench-vm() {
    start-vm
    ssh-vm "$(< "$me")
git-pull git://anongit.freedesktop.org ezbench
"
}

make-install-virgl() {
    cd "$PREFIX/src/virglrenderer"
    ./autogen.sh --prefix="$PREFIX" CFLAGS="$CFLAGS"
    make -j4
    make install
}

make-install-qemu() {
    cd "$PREFIX/src/qemu"
    ./configure --prefix="$PREFIX" \
                --target-list=x86_64-softmmu \
                --enable-kvm \
                --disable-werror \
                --enable-spice \
                --enable-virglrenderer \
                --extra-cflags="$CFLAGS"
    make -j4
    make install
}

make-install-spice() {
    cd "$PREFIX/src/spice-protocol"
    ./autogen.sh --prefix="$PREFIX"
    make -j4
    make install

    cd "$PREFIX/src/spice"
    ./autogen.sh --prefix="$PREFIX" 
    make -j4
    make install

}

update_host_help="Update virgl & qemu on host for the test (current dir)"
update-host() {
    git-pull git://anongit.freedesktop.org virglrenderer
    git-pull git://git.qemu.org qemu
    git-pull git://anongit.freedesktop.org/spice spice-protocol
    git-pull git://anongit.freedesktop.org/spice spice

    make-install-virgl
    make-install-spice
    make-install-qemu
    cd "$PREFIX"
}

run() {
    stop-vm
    DIR="run/$(date +"%m-%d-%Y-%T")"
    mkdir -p "$DIR"/{xonotic,glmark2,piglit}
    rpm -qa > "$DIR/rpm-qa"
    update-host | tee "$DIR/update-host"
    for proj in qemu virglrenderer spice ; do 
        GIT_DIR="src/$proj/.git" git show > "$DIR/$proj-git"
    done
    start-vm
    ssh-vm rpm -qa > "$DIR/rpm-qa-vm"
    ssh-vm DISPLAY=:42 xonotic-glx -benchmark demos/xonotic-0-8-d1 | egrep -e '[0-9]+ frames' | tee "$DIR/xonotic/output"
    ssh-vm DISPLAY=:42 glmark2 | tee "$DIR/glmark2/output"
    ssh-vm DISPLAY=:42 src/piglit/piglit run -x glean -x max-input-components -x 2-buffers-bug -x time-elap -x timestamp -o -v tests/all results/all
    scp-vm results "$DIR/piglit"
    piglit summary console -s "$DIR/piglit/results/all" > "$DIR/piglit/summary"
    stop-vm
}

help() {
    echo "$me COMMAND ARGS

This script has the following commands:
"
    for i in $(compgen -A function); do
        cmd=$(echo $i | tr - _)
        help=$(eval 'echo $'$cmd'_help')
        args=$(eval 'echo $'$cmd'_args')
        if [ -z "$help" ]; then continue ; fi
        echo $i $args
        echo "    $help"
    done
}

$@
