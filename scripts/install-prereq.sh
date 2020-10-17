#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="k8-win"
declare KEYNAME="windows-node"
declare WMCO_PRJ="windows-machine-config-operator"
declare WMCO_OPERATOR_IMAGE="quay.io/mhildenb/wmco:1.0"

display_usage() {
cat << EOF
$0: Install k8 Windows Demo Prerequisites --

  Usage: ${0##*/} [ OPTIONS ]
  

EOF
}

get_and_validate_options() {
  # Transform long options to short ones
#   for arg in "$@"; do
#     shift
#     case "$arg" in
#       "--long-x") set -- "$@" "-x" ;;
#       "--long-y") set -- "$@" "-y" ;;
#       *)        set -- "$@" "$arg"
#     esac
#   done

  
  # parse options
  while getopts ':h' option; do
      case "${option}" in
#          s  ) sup_prj="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

}

wait_for_crd()
{
    local CRD=$1
    local PROJECT=$(oc project -q)
    if [[ "${2:-}" ]]; then
        # set to the project passed in
        PROJECT=$2
    fi

    # Wait for the CRD to appear
    while [ -z "$(oc get $CRD 2>/dev/null)" ]; do
        sleep 1
    done 
    oc wait --for=condition=Established $CRD --timeout=6m -n $PROJECT
}

# Creates a temporary directory to hold edited manifests, validates the operator bundle
# and prepares the cluster to run the operator and runs the operator on the cluster using OLM
# Parameters:
# 1: path to the operator-sdk binary to use
run_WMCO() {
  local OSDK=$1

  # Create a temporary directory to hold the edited manifests which will be removed on exit
  MANIFEST_LOC=`mktemp -d`
  trap "rm -r $MANIFEST_LOC" EXIT
  cp -r $DEMO_HOME/install/windows-nodes/wmco/olm-catalog/windows-machine-config-operator/ $MANIFEST_LOC
  sed -i "s|REPLACE_IMAGE|$WMCO_OPERATOR_IMAGE|g" $MANIFEST_LOC/windows-machine-config-operator/manifests/windows-machine-config-operator.clusterserviceversion.yaml

  # Validate the operator bundle manifests
  $OSDK bundle validate "$MANIFEST_LOC"/windows-machine-config-operator/
  if [ $? -ne 0 ] ; then
      error-exit "operator bundle validation failed"
  fi

  oc get ns $WMCO_PRJ 2>/dev/null  || { 
      oc new-project $WMCO_PRJ
  }

  echo "Creating ssh secret for wmc operator"
  # FIXME: KEYNAME should be driven by incoming parameters
  oc create secret generic cloud-private-key --from-file=private-key.pem=$HOME/.ssh/$KEYNAME -n $WMCO_PRJ

  # Run the operator in the windows-machine-config-operator namespace
  OSDK_WMCO_management run $OSDK $MANIFEST_LOC

  # Additional guard that ensures that operator was deployed given the SDK flakes in error reporting
  if ! oc rollout status deployment windows-machine-config-operator -n windows-machine-config-operator --timeout=5s; then
    return 1
  fi
}

OSDK_WMCO_management() {
  if [ "$#" -lt 2 ]; then
    echo incorrect parameter count for OSDK_WMCO_management $#
    return 1
  fi
  if [[ "$1" != "run" && "$1" != "cleanup" ]]; then
    echo $1 does not match either run or cleanup
    return 1
  fi

  local COMMAND=$1
  local OSDK_PATH=$2
  local INCLUDE=""

  if [[ "$1" = "run" ]]; then
    INCLUDE="--include "$3"/windows-machine-config-operator/manifests/windows-machine-config-operator.clusterserviceversion.yaml"
  fi

  # Currently this fails even on successes, adding this check to ignore the failure
  # https://github.com/operator-framework/operator-sdk/issues/2938
  if ! $OSDK_PATH $COMMAND packagemanifests --olm-namespace openshift-operator-lifecycle-manager --operator-namespace windows-machine-config-operator \
  --operator-version 0.0.0 $INCLUDE; then
    echo operator-sdk $1 failed
  fi
}

main()
{
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    #
    # Subscribe to additional Catalogs
    #
    # redhat-operators-45 is the legacy operators provided with ocp-4.5.  Until pipelines operator is available in the 4.6
    # redhat-operators stream, we need to use this
    SOURCE_FILES=( "redhat-operators-45.yaml" )
    for SOURCE_FILE in ${SOURCE_FILES[@]}; do
      OUTPUT=$(oc apply -o name -f $DEMO_HOME/install/kube/catalog-source/${SOURCE_FILE})
      CATALOG_SOURCE=$(echo ${OUTPUT} | head -n 1)
      echo "Waiting for catalog source (${CATALOG_SOURCE}) to be ready"
      while [[ "$(oc get ${CATALOG_SOURCE} -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)" != "READY" ]]; do
        echo -n "."
        sleep 1
      done
    done

    #
    # Install Pipelines (Tekton)
    #
    echo "Installing OpenShift pipelines"
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  # NOTE: Only preview will work on ocp-4.6
  channel: preview
  installPlanApproval: Automatic
  name: openshift-pipelines-operator-rh
  source: redhat-operators-45
  sourceNamespace: openshift-marketplace
EOF

    #
    # Install virtualization
    #
    oc apply -f $DEMO_HOME/install/kube/ocp-virt/subscription.yaml

    # Ensure pipelines is installed
    # wait_for_crd "crd/pipelines.tekton.dev"

    echo "Waiting for virtualization operator installation"
    oc rollout status deploy/hco-operator -n openshift-cnv

    # Ensure we can create a CNV instance to start virtualization support
    wait_for_crd "crd/hyperconvergeds.hco.kubevirt.io"

    echo "Creating hyperconverged cluster custom resource"
    cat <<EOF | oc apply -f - 
apiVersion: hco.kubevirt.io/v1alpha1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  BareMetalPlatform: false
EOF

    echo "Waiting for virtualization support to finish installation"
    oc wait --for=condition=Available hyperconvergeds/kubevirt-hyperconverged --timeout=6m -n openshift-cnv

    echo "Prerequisites installed successfully!"

    echo "Creating Windows Machine Config Operator"
    run_WMCO $(which operator-sdk)

    # CATALOG_SOURCE=$(oc apply -o name -n $WMCO_PRJ -f $DEMO_HOME/install/windows-nodes/wmco/catalogsource.yaml)
    # echo "waiting for catalog source to be ready"
    # while [[ "$(oc get ${CATALOG_SOURCE} -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)" != "READY" ]]; do
    #   echo -n "."
    #   sleep 1
    # done
    
    # oc apply -n $WMCO_PRJ -f $DEMO_HOME/install/windows-nodes/wmco/operatorgroup.yaml

    # oc apply -n $WMCO_PRJ -f $DEMO_HOME/install/windows-nodes/wmco/subscription.yaml

}

main "$@"



