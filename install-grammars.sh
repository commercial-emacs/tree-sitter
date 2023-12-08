#!/usr/bin/env bash

JQ=$(which jq || true)
if [ -z "$JQ" ] ; then
    echo "Requires jq"
    exit -1
fi
TS=$(which tree-sitter || true)
if [ -z "$TS" ] || [[ ! $($TS --version) =~ "0.20.8-alpha" ]] ; then
    echo "Requires tree-sitter cli version 0.20.8-alpha"
    exit -1
fi

function git_refresh {
    local repo
    local url
    local old_commit
    local fetch_commit
    repo=$1
    url=$2
    if [ -d "$repo" ] ; then
	pushd $repo
	old_commit=$(git rev-parse --short FETCH_HEAD)
	fetch_commit=${3:-}
	git fetch -f -q -u origin ${fetch_commit} --depth=1
	if [[ ! $(git rev-parse --short FETCH_HEAD) =~ "${old_commit}" ]] ; then
	    git checkout -f FETCH_HEAD
	    regenerate+=( $repo )
	fi
	popd
    else
	mkdir -p $repo
	pushd $repo
	git init -q
	git remote add origin $url
	git fetch --depth 1 origin ${3:-}
	git checkout -f FETCH_HEAD
	regenerate+=( $repo )
	popd
    fi
}

DIR=$(git rev-parse --show-toplevel)/grammars
mkdir -p $DIR
declare -a official=()
declare -a regenerate=()
git_refresh "$DIR/nvim-treesitter" \
	    "https://github.com/nvim-treesitter/nvim-treesitter.git"

declare -A pinned
while IFS="=" read -r key value
do
    pinned[$key]="$value"
done < <($JQ -r 'to_entries | map("\(.key)=\(.value|.revision)") | .[]' "${DIR}/nvim-treesitter/lockfile.json")

IFS=$'\n'
for url in $(egrep -o "https://github.com/tree-sitter/tree-sitter-[A-Za-z0-9-]+" \
		   docs/index.md | sort -u) ; do
    unset IFS
    repo=$(basename $url)
    official+=( $repo )
    LANG=${repo##*-}
    git_refresh "$DIR/$repo" $url ${pinned[$LANG]}
done
unset IFS

IFS=$'\n'
for url in $(egrep -o "https://github.com/.+/tree-sitter-[A-Za-z0-9-]+" \
		   docs/index.md | sort -u) ; do
    unset IFS
    repo=$(basename $url)
    if [[ ! " ${official[*]} " =~ " ${repo} " ]] ; then
        LANG=${repo##*-}
	git_refresh "$DIR/$repo" $url ${pinned[$LANG]}
    fi
done
unset IFS

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
    if ( cd $repo ; 2>/dev/null ln -s $DIR ./node_modules || true ; 1>/dev/null 2>/dev/null $TS test ) ; then
        if [ -f "$repo/queries/highlights.scm" ] ; then
            LANG=${repo##*-}
            mkdir -p "$QDIR/$LANG"
            cp -p "$repo/queries/highlights.scm" "$QDIR/$LANG"
        fi
        if [ -f "$repo/queries/indents.scm" ] ; then
            LANG=${repo##*-}
            mkdir -p "$QDIR/$LANG"
            cp -p "$repo/queries/indents.scm" "$QDIR/$LANG"
        fi
    fi
done

for dir in "$DIR/nvim-treesitter/queries"/* ; do
    indents="$dir/indents.scm"
    if [ -f "$indents" ] ; then
        LANG=$(basename $dir)
	mkdir -p "$QDIR/$LANG"
	if [ ! -f "$QDIR/$LANG/indents.scm" ] || \
	       [ "$indents" -nt "$QDIR/$LANG/indents.scm" ]; then
	    cp -p "$indents" "$QDIR/$LANG/indents.scm"
	fi
    fi
done

# hack for now
rsync -va "$DIR/../queries/" "$QDIR"
