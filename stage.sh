#!/bin/bash
#
# Copyright (C) 2024 Wind River Systems, Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

if [ -z "$BASE" ]; then
    BASE="/data/staging/wrlinux/"
fi

if [ -z "$REL_NUM" ]; then
    echo "The WRLinux release number must be defined as env variable REL_NUM"
    exit 1
fi

if [ -z "$WR_USERNAME" ]; then
    echo "The WindRiver Delivers username must be defined as env variable WR_USERNAME"
    exit 1
fi

if [ -z "$WR_PASSWORD" ]; then
    echo "The WindRiver Delivers password must be defined as env variable WR_PASSWORD"
    exit 1
fi

REL_BRANCH="WRLINUX_10_${REL_NUM}_LTS"

RELEASE="$BASE/lts${REL_NUM}/"

REMOTE=gateway.delivers.windriver.com/git/linux-lts/release/wrlinux-lts."$REL_NUM"/WRLinux-lts-"$REL_NUM"-Core/wrlinux-x

function main {

    env > staging-env.log

    mkdir -p "$RELEASE"
    cd "$RELEASE" || exit 1

    # declutter log
    if ! git config init.defaultBranch &> /dev/null; then
        git config --global init.defaultBranch master
    fi

    # set the user email and name so that git commit doesn't fail
    if ! git config user.email &> /dev/null; then
        git config --global user.email "wrstudio_installer@windriver.com"
    fi
    if ! git config user.name &> /dev/null; then
        git config --global user.name "Wind River Studio"
    fi

    MIRROR_DIR="$RELEASE"/mirror
    mkdir -p "$MIRROR_DIR"
    cd "$MIRROR_DIR" || exit 1

    # setup credentials
    local ENCODED_USERNAME=${WR_USERNAME//%/%25}
    ENCODED_USERNAME=${ENCODED_USERNAME//@/%40}
    local ENCODED_PASSWORD=${WR_PASSWORD//%/%25}
    ENCODED_PASSWORD=${ENCODED_PASSWORD//@/%40}
    echo "https://${ENCODED_USERNAME}:${ENCODED_PASSWORD}@${REMOTE}" > credentials

    # clone wrlinux from Delivers with support for credentials
    (
        if [ ! -d wrlinux-x ]; then
            mkdir wrlinux-x
            cd wrlinux-x || exit 1
            git init
            git remote add -t "${REL_BRANCH}" origin https://"${REMOTE}"
            git config credential.helper "store --file $MIRROR_DIR/credentials"
        else
            cd wrlinux-x || exit 1
        fi

        # this retrieves all branches and creates local references like when cloning with --mirror
        echo "Fetch and checkout branch $REL_BRANCH from $REMOTE"
        git fetch -u -f origin '+refs/*:refs/*'
        if ! git checkout --force "${REL_BRANCH}"; then
            echo "FATAL: Clone from branch ${REL_BRANCH} on repo ${REMOTE} failed."
            echo "Validate credentials are correct."
            exit 1
        fi
    )
    RET="$?"
    if [ "$RET" -ne '0' ]; then
        exit 1
    fi

    # get all the LTS branches except RCPL0000 and append the release branch to the end of the array so it is downloaded last
    local BRANCHES=()
    mapfile -t BRANCHES < <(git --git-dir wrlinux-x/.git show-ref --heads | grep _LTS_RCPL | grep -v "${REL_BRANCH}_RCPL0000" | cut -d'/' -f 3- | sort)
    BRANCHES+=("$REL_BRANCH")

    local TAGS=()
    mapfile -t TAGS < <(git --git-dir wrlinux-x/.git show-ref --tags | grep LTS | cut -d'/' -f 3-)

    FLAT_BASE="$RELEASE"/flat/
    mkdir -p "$FLAT_BASE"
    FLAT_FINAL="$FLAT_BASE"/flat-final
    mkdir -p "$FLAT_FINAL"

    # setup the initial mirror-index repository so that it is bare and can accept pushes
    if [ ! -d "${FLAT_FINAL}"/mirror-index ]; then
        (
            cd "${FLAT_FINAL}" || exit 1
            mkdir mirror-index
            cd mirror-index || exit 1
            git init --bare
        )
    fi

    for BRANCH in "${BRANCHES[@]}"; do

        # if flat-final already contains the mirror-index for a specific RCPL, then don't bother with the
        # flatten and push for that RCPL
        if git --git-dir "${FLAT_FINAL}/mirror-index" show-ref --tags | grep -q "v${BRANCH}"; then
            # Always process the HEAD branch which doesn't have RCPL in the name
            if [ "${BRANCH:(-8):(-4)}" == "RCPL" ]; then
                continue
            fi
        fi

        # run setup to create a mirror
        (cd wrlinux-x; git checkout --force "$BRANCH")

        # sometimes anspass messes up and this removes the socket
        rm -rf bin/.anspass

        wrlinux-x/setup.sh --mirror --all-layers --dl-layers --user="$WR_USERNAME" --password="$WR_PASSWORD" --accept-eula=yes

        RET="$?"
        if [ "$RET" -ne '0' ]; then
            echo "ERROR: setup.sh failed to download from Gallery. Verify the credentials and retry. Notify Gallery team if issue doesn't resolve."
            exit 1
        fi

        mkdir -p "$RELEASE"
        FLAT_DIR="${FLAT_BASE}/${BRANCH}"

        # flatten the mirror using the subset files for that specific branch
        if [ ! -d "$FLAT_DIR" ]; then
            # flatten the mirror for pushing to gitlab
            wrlinux-x/bin/flatten_mirror.py --strip-git "$FLAT_DIR"
        fi

        # to reduce disk usage, create the flattened dir and then push or move the contents to
        # flat-final and remove the flat dir afterwards. The flat-final tree will contain all the repos
        # and mirror-index information
        (
            cd "$FLAT_DIR" || exit 1
            for REPO in *; do
                REPO_NAME="${REPO##*/}"
                if [ -d "${FLAT_FINAL}/${REPO_NAME}" ]; then
                    (
                        cd "$REPO" || exit 1
                        git push --all --force --no-verify "${FLAT_FINAL}/${REPO_NAME}"
                    )
                else
                    mv "$REPO_NAME" "$FLAT_FINAL"
                fi
            done
        )
        rm -rf "$FLAT_DIR"
    done

    # now that flat-final has all the repos and all the mirror-index information
    # create tags to match the official mirror-index. They won't be signed tags
    (
        cd "${FLAT_FINAL}/mirror-index" || exit 1
        for TAG in "${TAGS[@]}"; do
            if ! git show-ref --tags | grep -q "$TAG"; then
                git tag --force "$TAG" "${TAG:1}"
            fi
        done
    )

    # another hack to workaround gitlab issue with tags on the vim repo
    (
        cd "${FLAT_FINAL}/github.com.vim.vim" || exit 1
        git tag | xargs git tag -d
    )
}

main "$@"
