#!/bin/bash
# ssh_key_generator - designed to work with the Terraform External Data Source provider
#   https://www.terraform.io/docs/providers/external/data_source.html
#  Inpiration https://gist.github.com/irvingpop/968464132ded25a206ced835d50afa6b
#  by Irving Popovetsky <irving@popovetsky.com> 
#

function error_exit() {
  echo "$1" 1>&2
  exit 1
}

function check_deps() {
  test -f $(which aws) || error_exit "aws command not detected in path, please install it"
  test -f $(which jq) || error_exit "jq command not detected in path, please install it"
}

function parse_input() {
  # jq reads from stdin so we don't have to set up any inputs, but let's validate the outputs
  eval "$(jq -r '@sh "export USER_POOL_ID=\(.user_pool) PROFILE=\(.profile) USERNAME=\(.username)"')"
  if [[ -z "${USER_POOL_ID}" ]]; then export USER_POOL_ID=none; fi
  if [[ -z "${PROFILE}" ]]; then export PROFILE=none; fi
  if [[ -z "${USERNAME}" ]]; then export USERNAME=none; fi
}

function create_user() {
    #echo "$(aws cognito-idp admin-get-user --user-pool-id "$USER_POOL_ID" --profile "$PROFILE" --username "$USERNAME")" >> '/Users/fabdouglas/git/live-carto/scripts/ligoj-terraform/out.txt'
    aws cognito-idp admin-get-user --user-pool-id "$USER_POOL_ID" --profile "$PROFILE" --username "$USERNAME" | jq '{username : .Username}'
}

# main()
check_deps
# echo "DEBUG: received: $INPUT" 1>&2
parse_input

create_user
