#!/usr/bin/env bash

# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail 

usage() {
      cat >&2 << EOF
usage: $(basename "$0") [all] [codegen] [crdgen] [diff] [docgen] [manifests] [format] [test]
  $(basename "$0") executes presubmit tasks on the respository to prepare code
  before submitting changes. Running with no arguments runs every check
  (i.e. the 'all' subcommand).

EOF
}

SCRIPT_ROOT=$(dirname "${BASH_SOURCE[0]}")/..

codegen_diff() {
  TMPDIR=$(mktemp -d)
  git clone https://github.com/GoogleCloudPlatform/prometheus-engine ${TMPDIR}/prometheus-engine
  git diff -s --exit-code ${SCRIPT_ROOT}/pkg/operator/apis ${TMPDIR}/prometheus-engine/pkg/operator/apis
}

update_codegen() {
  echo ">>> regenerating CRD k8s go code"
  
  # Refresh vendored dependencies to ensure script is found.
  go mod vendor
  
  # Idempotently regenerate by deleting current resources.
  rm -rf $SCRIPT_ROOT/pkg/operator/generated
  
  CODEGEN_PKG=${CODEGEN_PKG:-$(cd "${SCRIPT_ROOT}"; ls -d -1 ./vendor/k8s.io/code-generator 2>/dev/null || echo ../code-generator)}
  
  # Invoke only for deepcopy first as it doesn't accept the pluralization flag
  # of the second invocation.
  bash "${CODEGEN_PKG}"/generate-groups.sh "deepcopy" \
    github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/generated github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/apis \
    monitoring:v1 \
    --go-header-file "${SCRIPT_ROOT}"/hack/boilerplate.go.txt \
    --output-base "${SCRIPT_ROOT}"
  
  bash "${CODEGEN_PKG}"/generate-groups.sh "client,informer,lister" \
    github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/generated github.com/GoogleCloudPlatform/prometheus-engine/pkg/operator/apis \
    monitoring:v1 \
    --go-header-file "${SCRIPT_ROOT}"/hack/boilerplate.go.txt \
    --plural-exceptions "Rules:Rules,ClusterRules:ClusterRules,GlobalRules:GlobalRules" \
    --output-base "${SCRIPT_ROOT}"
  
  cp -r $SCRIPT_ROOT/github.com/GoogleCloudPlatform/prometheus-engine/* $SCRIPT_ROOT
  rm -r $SCRIPT_ROOT/github.com
}

combine() {
  SOURCE_DIR=$1
  REGEX=$2
  DEST_YAML=$3

  SOURCE_YAMLS=$(find ${SOURCE_DIR} -regextype sed -regex ${REGEX} | sort)
  mkdir -p $(dirname $3)
  cat "${SCRIPT_ROOT}"/hack/boilerplate.txt > $DEST_YAML
  printf "\n# NOTE: This file is autogenerated.\n" >> $DEST_YAML
  sed -s '$a---' $SOURCE_YAMLS | sed -e '$ d' -e '/^#/d' -e '/^$/d' >> $DEST_YAML
}

update_crdgen() {
  echo ">>> regenerating CRD yamls"

  which controller-gen || go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.7.0

  API_DIR=${SCRIPT_ROOT}/pkg/operator/apis/...
  CRD_DIR=${SCRIPT_ROOT}/cmd/operator/deploy/crds

  controller-gen crd paths=./$API_DIR output:crd:dir=$CRD_DIR

  CRD_YAMLS=$(find ${CRD_DIR} -iname '*.yaml' | sort)
  for i in $CRD_YAMLS; do
    sed -i '0,/---/{/---/d}' $i
    # Currently controller-gen regenerates the status section of the CRD, which is
    # not ideal.
    # There is an open issue: https://github.com/kubernetes-sigs/controller-tools/issues/456.
    # Until then, we manually delete the status field in the generated CRD yamls here.
    sed -i '/^status:*/,$d' $i
    echo "$(cat ${SCRIPT_ROOT}/hack/boilerplate.txt)$(cat $i)" > $i
  done

  combine $CRD_DIR '^.*/.*.yaml$' ${SCRIPT_ROOT}/manifests/setup.yaml
}

update_docgen() {
  echo ">>> generating API documentation"
  
  which po-docgen || (go get github.com/prometheus-operator/prometheus-operator \
    && go install -mod=mod github.com/prometheus-operator/prometheus-operator/cmd/po-docgen)
  mkdir -p doc
  po-docgen api ./pkg/operator/apis/monitoring/v1/types.go > doc/api.md
  sed -i 's/Prometheus Operator/GMP CRDs/g' doc/api.md
}

update_manifests() {
  echo ">>> regenerating example yamls"

  CRD_DIR=${SCRIPT_ROOT}/cmd/operator/deploy/crds
  OP_DIR=${SCRIPT_ROOT}/cmd/operator/deploy/operator
  RE_DIR=${SCRIPT_ROOT}/cmd/operator/deploy/rule-evaluator

  combine $CRD_DIR '^.*/.*.yaml$' ${SCRIPT_ROOT}/manifests/setup.yaml
  combine $OP_DIR '^.*/[0-9][0-9]-\w.*.yaml$' ${SCRIPT_ROOT}/manifests/operator.yaml
  combine $RE_DIR '^.*/[0-9][0-9]-\w.*.yaml$' ${SCRIPT_ROOT}/manifests/rule-evaluator.yaml
}

run_tests() {
  echo ">>> running unit tests"
  go test `go list ${SCRIPT_ROOT}/... | grep -v operator/e2e | grep -v export/bench`
}

reformat() {
  go mod tidy && go mod vendor && go fmt ${SCRIPT_ROOT}/...
}

exit_msg() {
  echo $1
  exit 1
}

update_all() {
  # As this command can be slow, optimize by only running if there's difference
  # from the origin/main branch.
  codegen_diff || update_codegen
  reformat
  update_crdgen
  update_manifests
  update_docgen
}

main() {
  if [[ -z "$@" ]]; then
    update_all
  else
    for opt in "$@"; do
      case "${opt}" in
        all)
          update_all
          ;;
        codegen)
          update_codegen
          ;;
        crdgen)
          update_crdgen
          ;;
        diff)
          git diff -s --exit-code doc go.mod go.sum '*.go' '*.yaml' || \
            exit_msg "diff found - ensure regenerated code is up-to-date and committed."
          ;;
        docgen)
          update_docgen
          ;;
        manifests)
          update_manifests
          ;;
        format)
          reformat
          ;;
        test)
          run_tests
          ;;
        *)
          printf "unsupported command: \"${opt}\".\n"
          usage
      esac
    done
  fi
}

main "$@"