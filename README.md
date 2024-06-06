# Scripts for installation of WRLinux into internal Gitlab server

## Staging

The staging script does several things:

1) Create a local mirror from WindRiver Delivers that contains all RCPLs for
a specific release.

2) Use wrlinux-x/bin/flatten_mirror.py for each RCPL to create a merged
flattened directory that contains all the WRLinux content for a specific
release.

The script handles both initial staging and upgrades. By default content
will be cached and reused, but the cache can be deleted and recreated.

The stage.sh script takes four environment variables as input:

1) BASE - The location where the mirror and flattened tree are stored

2) REL_NUM - The WRLinux release number, i.e. 22 or 23

3) WR_USERNAME - The WindRiver Delivers account username

4) WR_PASSWORD - The WindRiver Delivers account password

Recommend at least 200GB local disk space to hold all the mirrors

## Install to Gitlab

The install.sh script will push all the content from the flat-final
directory to a Gitlab server.

The install.sh script takes three environment variables as input:

1) BASE - The location where the mirror and flattened tree are stored

2) REL_NUM - The WRLinux release number, i.e. 22 or 23

3) GITLAB_HOST - The FQDN of the gitlab server

The script defaults to wrlx/release/WRL10_$REL_NUM/WRLinux-lts-$REL_NUM-Core
as the location of the git repositories.

### Requirements

- git and glab binary in $PATH

- A valid access token with group create and push access must be located in access_token.txt

- The script will create and set all the groups and projects to public visibility
