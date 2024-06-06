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

BASE="/data/staging/wrlinux/"

if [ -z "$REL_NUM" ]; then
    echo "The WRLinux release number must be defined as env variable REL_NUM"
    exit 1
fi

if [ -z "$GITLAB_HOST" ]; then
    echo "The fqdn of the Gitlab server must be defined as env variable GITLAB_HOST"
    exit 1
fi

if [ ! -f access_token.txt ]; then
    echo "Gitlab access token file access_token.txt not found"
    exit 1
fi

GLAB=(glab)

function get_top_level_group_id {
    # the search param is actually a regexp search, so it will return any groups containing that name
    # so it is necessary to loop over the results and check against the exact name
    mapfile -t GROUP_IDS < <("${GLAB[@]}" api groups -X GET -F top_level_only=true -F search="$1" | jq -r .[].id)
    for GROUP_ID in "${GROUP_IDS[@]}"; do
        GROUP_NAME=$("${GLAB[@]}" api groups/"$GROUP_ID" -X GET | jq -r .name)
        if [ "$GROUP_NAME" == "$1" ]; then
            echo "$GROUP_ID"
            break
        fi
    done
}

function get_subgroup_id {
    "${GLAB[@]}" api groups/"$1"/subgroups -X GET -F search="$2" | jq -r .[].id
}

function get_project_id {
    "${GLAB[@]}" api groups/"$1"/projects?search="$2" | jq -r .[].id
}

function main {
    echo "Script Checksum $(sha256sum $0)" | tee install-shasum.log
    env > install-env.log

    "${GLAB[@]}" config --global set check_update false
    "${GLAB[@]}" auth login --hostname "$GITLAB_HOST" --stdin < access_token.txt
    GITLAB_TOKEN=$(tr -d '\n' < access_token.txt)

    # create top level group if it is not available
    WRLX=wrlx
    WRLX_ID=$(get_top_level_group_id "$WRLX" )
    if [ -z "$WRLX_ID" ]; then
        "${GLAB[@]}" api groups -F name="$WRLX" -F path="$WRLX" -F visibility=public -F lfs_enabled=false
        WRLX_ID=$(get_top_level_group_id "$WRLX" )
    fi

    if [ -z "$WRLX_ID" ]; then
        echo "ERROR: Couldn't find or create top level $WRLX group. Exiting"
        exit 1
    fi

    # If top level group was created by another process make sure that it is visible and has lfs disabled
    "${GLAB[@]}" api "groups/$WRLX_ID" -X PUT -F visibility=public -F lfs_enabled=false --silent

    # Create subgroups for compatibility
    RELEASE_ID=$(get_subgroup_id "$WRLX_ID" "release" )
    if [ -z "$RELEASE_ID" ]; then
        "${GLAB[@]}" api groups -F name=release -F path=release -F visibility=public -F lfs_enabled=false -F parent_id="$WRLX_ID"
        RELEASE_ID=$(get_subgroup_id "$WRLX_ID" "release")
    fi
    if [ -z "$RELEASE_ID" ]; then
        echo "ERROR: Couldn't find or create release group. Exiting"
        exit 1
    fi

    BASE_FOLDER="WRL10_$REL_NUM"
    BASE_ID=$(get_subgroup_id "$RELEASE_ID" "$BASE_FOLDER" )
    if [ -z "$BASE_ID" ]; then
        "${GLAB[@]}" api groups -F name="$BASE_FOLDER" -F path="$BASE_FOLDER" -F visibility=public  -F lfs_enabled=false -F parent_id="$RELEASE_ID"
        BASE_ID=$(get_subgroup_id "$RELEASE_ID" "$BASE_FOLDER")
    fi
    if [ -z "$BASE_ID" ]; then
        echo "ERROR: Couldn't find or create $BASE_FOLDER group. Exiting"
        exit 1
    fi

    CORE_FOLDER="WRLinux-lts-${REL_NUM}-Core"
    CORE_ID=$(get_subgroup_id "$BASE_ID" "$CORE_FOLDER" )
    if [ -z "$CORE_ID" ]; then
        "${GLAB[@]}" api groups -F name="$CORE_FOLDER" -F path="$CORE_FOLDER" -F visibility=public -F lfs_enabled=false -F parent_id="$BASE_ID"
        CORE_ID=$(get_subgroup_id "$BASE_ID" "$CORE_FOLDER")
    fi
    if [ -z "$CORE_ID" ]; then
        echo "ERROR: Couldn't find or create $CORE_FOLDER group. Exiting"
        exit 1
    fi

    # make sure that the groups are visible, have lfs disabled and branch protection turned off
    "${GLAB[@]}" api "groups/$RELEASE_ID" -X PUT -F visibility=public -F lfs_enabled=false -F default_branch_protection=0 --silent
    "${GLAB[@]}" api "groups/$BASE_ID" -X PUT -F visibility=public -F lfs_enabled=false -F default_branch_protection=0 --silent
    "${GLAB[@]}" api "groups/$CORE_ID" -X PUT -F visibility=public -F lfs_enabled=false -F default_branch_protection=0 --silent

    push_repo() {
        local REPO=$1
        REPO_ID=$(get_project_id "$CORE_ID" "$REPO" )
        if [ -z "$REPO_ID" ]; then
            "${GLAB[@]}" api projects -F name="$REPO" -F path="$REPO" -F visibility=public -F namespace_id="$CORE_ID"
        fi

        # remove any protected branches
        local BRANCHES=()
        mapfile -t BRANCHES < <("${GLAB[@]}" api projects/"$REPO_ID"/protected_branches -X GET | jq -r .[].name)
        for BRANCH in "${BRANCHES[@]}"; do
            "${GLAB[@]}" api projects/"$REPO_ID"/protected_branches/"$BRANCH" -X DELETE
        done

        (
            cd "$REPO" || exit 1

            # Use git ls-remote to compare local and remote repositories to verify that push succeeded
            # Only compare the branches(heads) because tag discrepancies can usually be ignored
            HOST_REFS=$(git ls-remote --refs --heads --sort 'v:refname' . | sha256sum)

            # Only compare the branches that are on the local branch. Ignore branches that are on the remote for the comparison
            # use xargs to strip the trailing whitespace
            HOST_HEADS=($(git ls-remote --refs --heads  . | awk '{print $2}' | tr -s '\n' ' ' | xargs))
            REMOTE_REPO=https://"${MY_USER}:${GITLAB_TOKEN}@$GITLAB_HOST"/"$WRLX"/release/"$BASE_FOLDER"/"$CORE_FOLDER"/"$REPO".git
            REMOTE_REPO_NOCREDS=https://"$GITLAB_HOST"/"$WRLX"/release/"$BASE_FOLDER"/"$CORE_FOLDER"/"$REPO".git
            REMOTE_REFS=
            PUSH_COUNTER=0

            while [ "$HOST_REFS" != "$REMOTE_REFS" ] && [ "$PUSH_COUNTER" -lt 3 ]; do
                echo "INFO: Push attempt $PUSH_COUNTER on repository $REMOTE_REPO_NOCREDS"
                PUSH_OPTIONS=(--force --no-verify --tags)
                # add timeout in case the git push hangs
                LOGS=$(timeout --kill-after=10s 30m git push "${PUSH_OPTIONS[@]}" "$REMOTE_REPO" "+refs/heads/*:refs/heads/*" 2>&1)
                REMOTE_REFS=$(git ls-remote --refs --heads --sort 'v:refname' "$REMOTE_REPO" "${HOST_HEADS[@]}" | sha256sum )
                if [ "$HOST_REFS" != "$REMOTE_REFS" ]; then
                    echo "$LOGS"
                fi
                sleep "$((PUSH_COUNTER*5))" # sleep for 0, 5, 10
                ((++PUSH_COUNTER))
            done

            if [ "$HOST_REFS" != "$REMOTE_REFS" ]; then
                echo "ERROR: Push to $REMOTE_REPO failed!!"
                echo "Staged Refs:"
                git ls-remote --refs --heads --sort 'v:refname' .
                echo "Remote Refs:"
                git ls-remote --refs --heads --sort 'v:refname' "$REMOTE_REPO" "${HOST_HEADS[@]}"
                exit 1
            fi
        )
        # the exit from the subshell will be lost unless it is captured here and propagated
        RET="$?"
        if [ "$RET" -ne '0' ]; then
            echo "ERROR: Push of $REPO failed so terminating install"
            exit "$RET"
        fi
    }

    cd "$RELEASE/flat/flat-final/" || exit 1
    for REPO in *; do
        # delay the push of the mirror-index until the end to reduce chance that metadata service will read incomplete installation
        if [ "$REPO" != 'mirror-index' ]; then
            push_repo "$REPO"
        fi
    done
    push_repo "mirror-index"

    # there is a race condition with glab and repository creation and
    # occassionaly a group or projects doesn't have public visibility so
    # this will force the visibility to public
    recurse_groups() {
        local GROUP_ID=$1
        local GROUP=
        local GROUPS_=() # GROUPS is a reserved bash variable
        echo "INFO: Setting visibility of group $GROUP_ID to public"
        # First change recursively all the sub groups
        "${GLAB[@]}" api "groups/$GROUP_ID" -X PUT -F visibility=public -F lfs_enabled=false --silent
        mapfile -t GROUPS_ < <("${GLAB[@]}" api groups/"$GROUP_ID"/subgroups -X GET | jq -r .[].id)
        for GROUP in "${GROUPS_[@]}"; do
            recurse_groups "$GROUP"
        done
        # Now change each project in the group
        local PROJECT_ID=
        local PROJECTS=()
        mapfile -t PROJECTS < <("${GLAB[@]}" api groups/"$GROUP_ID"/projects -X GET --paginate | jq .[].id)
        for PROJECT_ID in "${PROJECTS[@]}"; do
            echo "INFO: Setting visibility of project $PROJECT_ID to public"
            "${GLAB[@]}" api "projects/$PROJECT_ID" -X PUT -F visibility=public --silent
        done
    }

    echo "INFO: Attempting to set visibility public on all WRLinux groups and projects"
    "${GLAB[@]}" api "groups/$WRLX_ID" -X PUT -F visibility=public -F lfs_enabled=false --silent
    "${GLAB[@]}" api "groups/$RELEASE_ID" -X PUT -F visibility=public -F lfs_enabled=false --silent
    recurse_groups "$BASE_ID"

}

main "$@"
