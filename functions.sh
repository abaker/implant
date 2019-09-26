#!/bin/bash

prebuild() {
    if [ -z "$PREBUILD" ]; then
        return 0
    fi
    printf "prebuild..." 1>&2
    eval "$PREBUILD" >> $LOG 2>&1
    if [ $? -ne 0 ]; then
        printf "FAILED\n" 1>&2
        exit 1
    fi
    printf "OK\n" 1>&2
}

setup_ndk() {
    if [ -z "$NDK" ]; then
        return 0
    fi
    NDK_DIR=android-ndk-$NDK
    NDK_ZIP=$NDK_DIR-linux-x86_64.zip
    NDK_URL=https://dl.google.com/android/repository/$NDK_ZIP &&
    export ANDROID_NDK_HOME=/$NDK_DIR
    printf "downloading ndk..." 1>&2
    wget -o /dev/null -c -O $DOWNLOADS/$NDK_ZIP $NDK_URL
    if [ $? -ne 0 ]; then
        printf "FAILED\n" 1>&2
        exit 1
    fi
    printf "OK\n" 1>&2
    printf "unzipping ndk..." 1>&2
    unzip -oq $DOWNLOADS/$NDK_ZIP -d /
    if [ $? -ne 0 ]; then
        printf "FAILED\n" 1>&2
        exit 1
    fi
    printf "OK\n" 1>&2
}

get_config() {
    PROP=$1
    DEFAULT=$2
    value=`yq r $CONFIG $PROP`
    if [ "$value" != null ]; then
        echo $value
    else
        echo $DEFAULT
    fi
}

install_deps() {
    if [ -z "$DEPS" ]; then
        return 0
    fi
    printf "installing dependencies..." 1>&2
    apt-get update >> $LOG 2>&1
    apt-get install -y $DEPS >> $LOG 2>&1
    if [ $? -ne 0 ]; then
        printf "FAILED\n" 1>&2
        return 1
    fi
    printf "OK\n" 1>&2
}

install_apk() {
    APK=$1
    printf "installing $APK..." 1>&2
    $ADB -H host.docker.internal install $APK >> $LOG
    if [ $? -ne 0 ]; then
        printf "FAILED\n" 1>&2
        return 1
    fi
    printf "OK\n" 1>&2
}

clone_and_patch() {
    printf "cloning $GIT_URL\n" 1>&2
    git clone --recurse-submodules $GIT_URL $PACKAGE >> $LOG 2>&1
    cd $PACKAGE
    printf "resetting HEAD to $GIT_SHA\n" 1>&2
    git reset --hard $GIT_SHA >> $LOG 2>&1
    git submodule update >> $LOG 2>&1

    if [ -f $METADATA/patch ]; then
        printf "applying patch\n" 1>&2
        git apply $METADATA/patch >> $LOG
    fi
}

download_gradle() {
    DISTRIBUTION=$(grep -e "^distributionUrl=https\\\\://services.gradle.org/" gradle/wrapper/gradle-wrapper.properties)
    GRADLE_VERSION=$(echo $DISTRIBUTION | grep -o "[0-9]\+\(\.[0-9]\+\)\+")
    GRADLE_ZIP=$DOWNLOADS/gradle-$GRADLE_VERSION-bin.zip
    GRADLE_SHA=$GRADLE_ZIP.sha256
    GRADLE_ZIP_URL=https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip
    GRADLE_SHA_URL=$GRADLE_ZIP_URL.sha256
    GRADLE=/gradle-$GRADLE_VERSION/bin/gradle

    if [ ! -f $GRADLE_SHA ]; then
        printf "downloading gradle-$GRADLE_VERSION checksum\n" 1>&2
        wget --quiet $GRADLE_SHA_URL -O $GRADLE_SHA
    fi

    if [ ! -f $GRADLE_ZIP ]; then
        printf "downloading gradle-$GRADLE_VERSION\n" 1>&2
        wget --quiet $GRADLE_ZIP_URL -O $GRADLE_ZIP
    fi

    sha256sum $GRADLE_ZIP | awk '{ printf $1 }' | diff $GRADLE_SHA -

    if [ $? != 0 ]; then
        rm $GRADLE_ZIP $GRADLE_SHA
        printf "gradle download failed\n" 1>&2
        exit 1;
    fi

    printf "unzipping gradle-$GRADLE_VERSION\n" 1>&2

    unzip -oq $GRADLE_ZIP -d /
}

