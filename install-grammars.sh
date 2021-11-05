#!/bin/bash -ex

function git_refresh {
    local repo
    local url
    local branch
    repo=$1
    url=$2
    if [ -d "$repo" ] ; then
	pushd $repo
	branch=$(git rev-parse --abbrev-ref HEAD)
	git fetch -q -u origin $branch:$branch --depth=1
	popd
    else
	git clone --depth=1 --single-branch $url $repo
    fi
}

DIR=$(git rev-parse --show-toplevel)/grammars
mkdir -p $DIR
declare -a official=()
IFS=$'\n'
for url in $(egrep -o "https://github.com/tree-sitter/tree-sitter-[A-Za-z0-9-]+" \
		   docs/index.md | sort -u) ; do
    unset IFS
    repo=$(basename $url)
    official+=( $repo )
    git_refresh "$DIR/$repo" $url
done

IFS=$'\n'
for url in $(egrep -o "https://github.com/.+/tree-sitter-[A-Za-z0-9-]+" \
		   docs/index.md | sort -u) ; do
    unset IFS
    repo=$(basename $url)
    if [[ ! " ${official[*]} " =~ " ${repo} " ]]; then
	git_refresh "$DIR/$repo" $url
    fi
done

cat <<EOF > "$DIR/config.json"
{
  "parser-directories": [
    "$DIR"
  ]
}
EOF

for repo in "$DIR"/tree-sitter-* ; do
    scope=$(cat $repo/package.json | 2>/dev/null jq -r '."tree-sitter"[].scope')
    if [ ! -z "$scope" ] ; then
	TREE_SITTER_DIR="$DIR" 1>/dev/null 2>/dev/null \
		       tree-sitter parse --scope "$scope" /dev/null
    fi
done

# deal with queries
