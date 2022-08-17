#!/usr/bin/env bash

JQ=$(which jq || true)
if [ -z "$JQ" ] ; then
    echo "Requires jq https://github.com/stedolan/jq/wiki/Installation"
    exit -1
fi

TS=$(which tree-sitter || true)
if [ -z "$TS" ] || [[ ! $($TS --version) =~ "0.20.6-alpha" ]] ; then
    echo "Requires tree-sitter cli version 0.20.6-alpha"
    exit -1
fi

function git_refresh {
    local repo
    local url
    local branch
    local commit
    repo=$1
    url=$2
    if [ -d "$repo" ] ; then
	pushd $repo
	branch=$(git rev-parse --abbrev-ref HEAD)
	commit=$(git rev-parse --short HEAD)
	git fetch -f -q -u origin $branch:$branch --depth=1
	if [[ ! $(git rev-parse --short HEAD) =~ "$commit" ]] ; then
	    regenerate+=( $repo )
	fi
	popd
    else
	git clone --depth=1 --single-branch $url $repo
	regenerate+=( $repo )
    fi
}

DIR=$(git rev-parse --show-toplevel)/grammars
mkdir -p $DIR
declare -a official=()
declare -a regenerate=()
IFS=$'\n'
for url in $(egrep -o "https://github.com/tree-sitter/tree-sitter-[A-Za-z0-9-]+" \
		   docs/index.md | sort -u) ; do
    unset IFS
    repo=$(basename $url)
    official+=( $repo )
    git_refresh "$DIR/$repo" $url
done
unset IFS

IFS=$'\n'
for url in $(egrep -o "https://github.com/.+/tree-sitter-[A-Za-z0-9-]+" \
		   docs/index.md | sort -u) ; do
    unset IFS
    repo=$(basename $url)
    if [[ ! " ${official[*]} " =~ " ${repo} " ]] ; then
	git_refresh "$DIR/$repo" $url
    fi
done
unset IFS

git_refresh "$DIR/nvim-treesitter" \
	    "https://github.com/nvim-treesitter/nvim-treesitter.git"

cat <<EOF > "$DIR/config.json"
{
  "parser-directories": [
    "$DIR"
  ]
}
EOF

QDIR="$($TS dump-libpath)"/../queries
mkdir -p "$QDIR"
for repo in "${regenerate[@]}" ; do
    scope=$(cat $repo/package.json | 2>/dev/null jq -r '."tree-sitter"[].scope')
    if [ ! -z "$scope" ] ; then
	if ( cd $repo ; 1>/dev/null 2>/dev/null $TS generate ) ; then
	    if TREE_SITTER_DIR="$DIR" 1>/dev/null 2>/dev/null \
			      $TS parse --scope "$scope" /dev/null ; then
		if [ -f "$repo/queries/highlights.scm" ] ; then
		    LANG=${repo##*-}
		    mkdir -p "$QDIR/$LANG"
		    cp -p "$repo/queries/highlights.scm" "$QDIR/$LANG"
		fi
	    fi
	fi
    fi
done

for dir in "$DIR/nvim-treesitter/queries"/* ; do
    indents="$dir/indents.scm"
    if [ -f "$indents" ] ; then
        LANG=$(basename $dir)
	if [ -d "$QDIR/$LANG" ] ; then
	    if [ ! -f "$QDIR/$LANG/indents.scm" ] || \
		   [ "$indents" -nt "$QDIR/$LANG/indents.scm" ]; then
		cp -p "$indents" "$QDIR/$LANG/indents.scm"
	    fi
	fi
    fi
done
