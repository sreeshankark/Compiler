#!/bin/bash

printf "\e[1;32m \u2730 Recovery Compiler\e[0m\n\n"

# Echo Loop
while ((${SECONDS_LEFT:=10} > 0)); do
    printf "Please wait %.fs ...\n" "${SECONDS_LEFT}"
    sleep 1
    SECONDS_LEFT=$((SECONDS_LEFT - 1))
done
unset SECONDS_LEFT

echo "::group::Free Space Checkup"
if [[ ! $(df / --output=avail | tail -1 | awk '{print $NF}') -ge 41943040 ]]; then
    printf "Please use 'slimhub_actions@main' Action prior to this Recovery Compiler Action to gain at least 40 GB space\n"
    exit 1
else
    printf "You have %s space available\n" "$(df -h / --output=avail | tail -1 | awk '{print $NF}')"
fi
echo "::endgroup::"

echo "::group::Mandatory Variables Checkup"
if [[ -z ${MANIFEST} ]]; then
    printf "Please Provide A Manifest URL with/without Branch\n"
    exit 1
fi
if [[ -z ${VENDOR} || -z ${CODENAME} ]]; then
    # Assume the workflow runs in the device tree
    # And the naming is exactly like android_device_vendor_codename(_split_codename)(-pbrp)
    # Optimized for PBRP Device Trees
	VenCode=$(echo ${GITHUB_REPOSITORY#*/} | sed 's/android_device_//;s/-pbrp//;')
    export VENDOR=$(echo ${VenCode} | cut -d'_' -f1)
    export CODENAME=$(echo ${VenCode} | cut -d'_' -f2-)
	unset VenCode
fi
if [[ -z ${DT_LINK} ]]; then
    # Assume the workflow runs in the device tree with the current checked-out branch
    DT_BR=${GITHUB_REF##*/}
    export DT_LINK="https://github.com/${GITHUB_REPOSITORY} -b ${DT_BR}"
	unset DT_BR
fi
# Default TARGET will be recoveryimage if not provided
export TARGET=${TARGET:-recoveryimage}
# Default FLAVOR will be eng if not provided
export FLAVOR=${FLAVOR:-eng}
# Default TZ (Timezone) will be set as UTC if not provided
export TZ=${TZ:-UTC}
if [[ ! ${TZ} == "UTC" ]]; then
    sudo timedatectl set-timezone ${TZ}
fi
echo "::endgroup::"

printf "We are going to build ${FLAVOR}-flavored ${TARGET} for ${CODENAME} from the manufacturer ${VENDOR}\n"

echo "::group::Installation Of Recommended Programs"
export \
    DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    JAVA_OPTS=" -Xmx7G " JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
sudo apt-get -qqy update &>/dev/null
sudo apt -y install gperf gcc-multilib gcc-10-multilib g++-multilib g++-10-multilib libc6-dev lib32ncurses5-dev x11proto-core-dev libx11-dev tree lib32z-dev libgl1-mesa-dev libxml2-utils xsltproc bc ccache lib32readline-dev lib32z1-dev liblz4-tool libncurses5-dev libsdl1.2-dev libwxgtk3.0-gtk3-dev libxml2 lzop pngcrush schedtool squashfs-tools imagemagick libbz2-dev lzma ncftp qemu-user-static libstdc++-10-dev libtinfo5 &>/dev/null
printf "Cleaning Some Programs...\n"
sudo apt-get -qqy purge default-jre-headless openjdk-11-jre-headless &>/dev/null
sudo apt-get -qy clean &>/dev/null && sudo apt-get -qy autoremove &>/dev/null
sudo rm -rf -- /var/lib/apt/lists/* /var/cache/apt/archives/* &>/dev/null
echo "::endgroup::"

echo "::group::Installation Of git-repo and ghr"
cd /home/runner || exit 1
printf "Adding latest stable git-repo and ghr binary...\n"
curl -sL https://gerrit.googlesource.com/git-repo/+/refs/heads/stable/repo?format=TEXT | base64 --decode  > repo
curl -s https://api.github.com/repos/tcnksm/ghr/releases/latest | jq -r '.assets[] | select(.browser_download_url | contains("linux_amd64")) | .browser_download_url' | wget -qi -
tar -xzf ghr_*_amd64.tar.gz --wildcards 'ghr*/ghr' --strip-components 1 && rm -rf ghr_*_amd64.tar.gz
chmod a+rx ./repo && chmod a+x ./ghr && sudo mv ./repo ./ghr /usr/local/bin/
echo "::endgroup::"

echo "::group::Installation Of Latest make and ccache"
mkdir -p /home/runner/extra &>/dev/null
{
    cd /home/runner/extra || exit 1
    wget -q https://ftp.gnu.org/gnu/make/make-4.3.tar.gz
    tar xzf make-4.3.tar.gz && cd make-*/ || exit
    ./configure && bash ./build.sh && sudo install ./make /usr/local/bin/make
    cd /home/runner/extra || exit 1
    git clone -q https://github.com/ccache/ccache.git
    cd ccache && git checkout -q v4.2
    mkdir build && cd build || exit
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DZSTD_FROM_INTERNET=ON ..
    make -j6 && sudo make install
} &>/dev/null
cd /home/runner || exit 1
rm -rf /home/runner/extra
echo "::endgroup::"

echo "::group::Doing Some Random Stuff"
if [ -e /lib/x86_64-linux-gnu/libncurses.so.6 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libncurses.so.5 ]; then
    ln -s /lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5
fi
export \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    USE_CCACHE=1 CCACHE_COMPRESS=1 CCACHE_COMPRESSLEVEL=8 CCACHE_DIR=/opt/ccache \
    TERM=xterm-256color
. /home/runner/.bashrc 2>/dev/null
echo "::endgroup::"

echo "::group::Setting ccache"
mkdir -p /opt/ccache &>/dev/null
sudo chown runner:docker /opt/ccache
CCACHE_DIR=/opt/ccache ccache -M 5G &>/dev/null
printf "All Preparation Done.\nReady To Build Recoveries...\n"
echo "::endgroup::"

# cd To An Absolute Path
mkdir -p /home/runner/builder &>/dev/null
cd /home/runner/builder || exit 1

echo "::group::Source Repo Sync"
printf "Initializing Repo\n"
printf "We will be using %s for Manifest source\n" "${MANIFEST}"
repo init -q -u ${MANIFEST} --depth=1 --groups=all,-notdefault,-device,-darwin,-x86,-mips || { printf "Repo Initialization Failed.\n"; exit 1; }
repo sync -c -q --force-sync --no-clone-bundle --no-tags -j6 || { printf "Git-Repo Sync Failed.\n"; exit 1; }
echo "::endgroup::"

echo "::group::Device and Kernel Tree Cloning"
printf "Cloning Device Tree\n"
git clone ${DT_LINK} --depth=1 device/${VENDOR}/${CODENAME}
# omni.dependencies file is a must inside DT, otherwise lunch fails
[[ ! -f device/${VENDOR}/${CODENAME}/omni.dependencies ]] && printf "[\n]\n" > device/${VENDOR}/${CODENAME}/omni.dependencies
if [[ ! -z "${KERNEL_LINK}" ]]; then
    printf "Using Manual Kernel Compilation\n"
    git clone ${KERNEL_LINK} --depth=1 kernel/${VENDOR}/${CODENAME}
else
    printf "Using Prebuilt Kernel For The Build.\n"
fi
echo "::endgroup::"

echo "::group::Secret Bootable"
if [[ $USE_SECRET_BOOTABLE == 'true' ]] && [[ -z "$SECRET_BR" ]]; then
    printf "Secret Branch is Not Defined\n"
elif [[ $USE_SECRET_BOOTABLE == 'true' ]] && [[ ! -z "$SECRET_BR" ]]; then
    rm -rf bootable/recovery
    printf "Cloning Secret Bootable\n"
    git clone --quiet --progress https://pbrp-bot:$GH_BOT_TOKEN@github.com/PitchBlackRecoveryProject/pbrp_recovery_secrets -b ${SECRET_BR} --single-branch bootable/recovery
else
    printf "Using Default Bootable\n"
fi
echo "::endgroup::"

echo "::group::Extra Commands"
if [[ ! -z "$EXTRA_CMD" ]]; then
    printf "Executing Extra Commands\n"
    eval "${EXTRA_CMD}" || { printf "Failed While Executing Extra Commands.\n"; exit 1; }
    cd /home/runner/builder || exit
fi
echo "::endgroup::"

echo "::group::Pre-Compilation"
printf "Compiling Recovery...\n"
export ALLOW_MISSING_DEPENDENCIES=true

# Only for (Unofficial) TWRP Building...
# If lunch throws error for roomservice, saying like `device tree not found` or `fetching device already present`,
# replace the `roomservice.py` with appropriate one according to platform version from here
# >> https://gist.github.com/rokibhasansagar/247ddd4ef00dcc9d3340397322051e6a/
# and then `source` and `lunch` again

source build/envsetup.sh
lunch omni_${CODENAME}-${FLAVOR} || lunch twrp_${CODENAME}-${FLAVOR} || { printf "Compilation failed.\n"; exit 1; }
echo "::endgroup::"

echo "::group::Compilation"
mka -j 2 ${TARGET} || { printf "Compilation failed.\n "; free -h; exit 1; }
echo "::endgroup::"

# Export VENDOR, CODENAME and BuildPath for next steps
echo "VENDOR=${VENDOR}" >> ${GITHUB_ENV}
echo "CODENAME=${CODENAME}" >> ${GITHUB_ENV}
echo "BuildPath=/home/runner/builder" >> ${GITHUB_ENV}

# TODO:: Add GitHub Release Script Here
