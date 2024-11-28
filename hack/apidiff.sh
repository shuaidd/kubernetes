#!/usr/bin/env bash

# Copyright 2024 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script checks the coding style for the Go language files using
# golangci-lint. Which checks are enabled depends on command line flags. The
# default is a minimal set of checks that all existing code passes without
# issues.

usage () {
  cat <<EOF >&2
Usage: $0 [-r <revision>] [directory ...]"
   -t <revision>: Report changes in code up to and including this revision.
                  Default is the current working tree instead of a revision.
   -r <revision>: Report change in code added since this revision. Default is
                  the common base of origin/master and HEAD.
   -b <directory> Build all packages in that directory after replacing
                  Kubernetes dependencies with the current content of the
                  staging repo. May be given more than once. Must be an
                  absolute path.
                  WARNING: this will modify the go.mod in that directory.
   [directory]:   Check one or more specific directory instead of everything.
EOF
  exit 1
}

set -o errexit
set -o nounset
set -o pipefail

KUBE_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
source "${KUBE_ROOT}/hack/lib/init.sh"

base=
target=
builds=()
while getopts "r:t:b:" o; do
    case "${o}" in
        r)
            base="${OPTARG}"
            if [ ! "$base" ]; then
                echo "ERROR: -${o} needs a non-empty parameter" >&2
                echo >&2
                usage
            fi
            ;;
       t)
            target="${OPTARG}"
            if [ ! "$target" ]; then
                echo "ERROR: -${o} needs a non-empty parameter" >&2
                echo >&2
                usage
            fi
            ;;
       b)
            if [ ! "${OPTARG}" ]; then
                echo "ERROR: -${o} needs a non-empty parameter" >&2
                echo >&2
                usage
            fi
            builds+=("${OPTARG}")
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

# Check specific directory or everything.
targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
    shopt -s globstar
    # Modules are discovered by looking for go.mod rather than asking go
    # to ensure that modules that aren't part of the workspace and/or are
    # not dependencies are checked too.
    # . and staging are listed explicitly here to avoid _output
    for module in ./go.mod ./staging/**/go.mod; do
        module="${module%/go.mod}"
        targets+=("$module")
    done
fi

# Must be a something that git can resolve to a commit.
# "git rev-parse --verify" checks that and prints a detailed
# error.
if [ -n "${target}" ]; then
    target="$(git rev-parse --verify "${target}")"
fi

# Determine defaults.
if [ -z "${base}" ]; then
    if ! base="$(git merge-base origin/master "${target:-HEAD}")"; then
        echo >&2 "Could not determine default base revision. -r must be used explicitly."
        exit 1
    fi
fi
base="$(git rev-parse --verify "${base}")"

# Give some information about what's happening. Failures from "git describe" are ignored
# silently, that's optional information.
describe () {
    local rev="$1"
    local descr
    echo -n "$rev"
    if descr=$(git describe --tags "${rev}" 2>/dev/null); then
        echo -n " (= ${descr})"
    fi
    echo
}
echo "Checking $(if [ -n "${target}" ]; then describe "${target}"; else echo "current working tree"; fi) for API changes since $(describe "${base}")."

kube::golang::setup_env
kube::util::ensure-temp-dir

# Install apidiff and make sure it's found.
export GOBIN="${KUBE_TEMP}"
PATH="${GOBIN}:${PATH}"
echo "Installing apidiff into ${GOBIN}."
go install golang.org/x/exp/cmd/apidiff@latest

cd "${KUBE_ROOT}"

# output_name targets a target directory and prints the base name of
# an output file for that target.
output_name () {
    what="$1"

    echo "${what}" | sed -e 's/[^a-zA-Z0-9_-]/_/g' -e 's/$/.out/'
}

# run invokes apidiff once per target and stores the output
# file(s) in the given directory.
#
# shellcheck disable=SC2317 # "Command appears to be unreachable" - gets called indirectly.
run () {
    out="$1"
    mkdir -p "$out"
    for d in "${targets[@]}"; do
        # cd to the path for modules that are intree but not part of the go workspace
        # per example staging/src/k8s.io/code-generator/examples
        (
            cd "${d}"
            apidiff -m -w "${out}/$(output_name "${d}")" .
        )
    done
}

# inWorktree checks out a specific revision, then invokes the given
# command there.
#
# shellcheck disable=SC2317 # "Command appears to be unreachable" - gets called indirectly.
inWorktree () {
    local worktree="$1"
    shift
    local rev="$1"
    shift

    # Create a copy of the repo with the specific revision checked out.
    # Might already have been done before.
    if ! [ -d "${worktree}" ]; then
        git worktree add -f -d "${worktree}" "${rev}"
        # Clean up the copy on exit.
        kube::util::trap_add "git worktree remove -f ${worktree}" EXIT
    fi

    # Ready for apidiff.
    (
        cd "${worktree}"
        "$@"
    )
}

# inTarget runs the given command in the target revision of Kubernetes,
# checking it out in a work tree if necessary.
inTarget () {
    if [ -z "${target}" ]; then
        "$@"
    else
        inWorktree "${KUBE_TEMP}/target" "${target}" "$@"
    fi
}

# Dump old and new api state.
inTarget run "${KUBE_TEMP}/after"
inWorktree "${KUBE_TEMP}/base" "${base}" run "${KUBE_TEMP}/before"

# Now produce a report. All changes get reported because exporting some API
# unnecessarily might also be good to know, but the final exit code will only
# be non-zero if there are incompatible changes.
#
# The report is Markdown-formatted and can be copied into a PR comment verbatim.
res=0
echo
compare () {
    what="$1"
    before="$2"
    after="$3"
    changes=$(apidiff -m "${before}" "${after}" 2>&1 | grep -v -e "^Ignoring internal package") || true
    echo "## ${what}"
    if [ -z "$changes" ]; then
        echo "no changes"
    else
        echo "$changes"
        echo
    fi
    incompatible=$(apidiff -incompatible -m "${before}" "${after}" 2>&1) || true
    if [ -n "$incompatible" ]; then
        res=1
    fi
}

for d in "${targets[@]}"; do
    compare "${d}" "${KUBE_TEMP}/before/$(output_name "${d}")" "${KUBE_TEMP}/after/$(output_name "${d}")"
done

# tryBuild checks whether some other project builds with the staging repos
# of the current Kubernetes directory.
#
# shellcheck disable=SC2317 # "Command appears to be unreachable" - gets called indirectly.
tryBuild () {
    local build="$1"

    # Replace all staging repos, whether the project uses them or not (playing it safe...).
    local repo
    for repo in $(cd staging/src; find k8s.io -name go.mod); do
        local path
        repo=$(dirname "${repo}")
        path="$(pwd)/staging/src/${repo}"
        (
            cd "$build"
            go mod edit -replace "${repo}"="${path}"
        )
    done

    # We only care about building. Breaking compilation of unit tests is also
    # annoying, but does not affect downstream consumers.
    (
        cd "$build"
        rm -rf vendor
        go mod tidy
        go build ./...
    )
}

if [ $res -ne 0 ]; then
    cat <<EOF

Some notes about API differences:

Changes in internal packages are usually okay.
However, remember that custom schedulers
and scheduler plugins depend on pkg/scheduler/framework.

API changes in staging repos are more critical.
Try to avoid them as much as possible.
But sometimes changing an API is the lesser evil
and/or the impact on downstream consumers is low.
Use common sense and code searches.
EOF

    if [ ${#builds[@]} -gt 0 ]; then

cat <<EOF

To help with assessing the real-world impact of an
API change, $0 will now try to build code in
${builds[@]}.
EOF

        if [[ "${builds[*]}" =~ controller-runtime ]]; then
cat <<EOF

controller-runtime is used because
- It tends to use advanced client-go functionality.
- Breaking it has additional impact on controller
  built on top of it.

This doesn't mean that an API change isn't allowed
if it breaks controller runtime, it just needs additional
scrutiny.

https://github.com/kubernetes-sigs/controller-runtime?tab=readme-ov-file#compatibility
explicitly states that a controller-runtime
release cannot be expected to work with a newer
release of the Kubernetes Go packages.
EOF
        fi

        for build in "${builds[@]}"; do
            echo
            echo "vvvvvvvvvvvvvvvv ${build} vvvvvvvvvvvvvvvvvv"
            if inTarget tryBuild "${build}"; then
                echo "${build} builds without errors."
            else
                cat <<EOF

WARNING: Building ${build} failed. This may or may not be because of the API changes!
EOF
            fi
            echo "^^^^^^^^^^^^^^^^ ${build} ^^^^^^^^^^^^^^^^^^"
        done
    fi
fi

exit "$res"
