#!/bin/bash
# ssh_key_generator - designed to work with the Terraform External Data Source provider
#   https://www.terraform.io/docs/providers/external/data_source.html
#  Inpiration: https://gist.github.com/irvingpop/968464132ded25a206ced835d50afa6b
#  by Irving Popovetsky <irving@popovetsky.com> 
#

MESSAGES="[]"
function log_info() {
  local MSG="$1"
  MESSAGES="$(echo "$MESSAGES" | jq  --arg MSG "$MSG" '. += [$MSG|gsub("^(\\s|\\n)+|(\\s|\\n)+$";"")]')"
}
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
  eval "$(jq -r '@sh "export RDS_ARN=\(.rds_arn) RDS_SECRET_ARN=\(.rds_secret_arn) PROFILE=\(.profile) REGION=\(.region) USERNAME=\(.username) POOL_ID=\(.user_pool) DATABASE=\(.database) API_TOKEN_NAME=\(.api_token_name) API_TOKEN=\(.api_token)"')"
  if [[ -z "${RDS_ARN}" ]]; then export RDS_ARN=none; fi
  if [[ -z "${RDS_SECRET_ARN}" ]]; then export RDS_SECRET_ARN=none; fi
  if [[ -z "${PROFILE}" ]]; then export PROFILE=none; fi
  if [[ -z "${REGION}" ]]; then export REGION=none; fi
  if [[ -z "${USERNAME}" ]]; then export USERNAME=none; fi
  if [[ -z "${POOL_ID}" ]]; then export POOL_ID=none; fi
  if [[ -z "${DATABASE}" ]]; then export DATABASE=none; fi
  if [[ -z "${API_TOKEN_NAME}" ]]; then export API_TOKEN_NAME=none; fi
  if [[ -z "${API_TOKEN}" ]]; then export API_TOKEN=none; fi
}

function execute_sql() {
  local SQL="$1"
  echo "$(aws rds-data execute-statement --region "$REGION" --database "$DATABASE" --resource-arn "$RDS_ARN" --secret-arn "$RDS_SECRET_ARN" --profile "$PROFILE" --sql "$SQL")"
}

function next_id() {
  local TABLE="$1"
  local result="$(execute_sql "SELECT next_val FROM ${TABLE}_seq")"
  local next_id="$(echo "$result" | jq -r '.records[0][0].longValue')"
  if [ "$next_id" == "null" ]; then
      error_exit "Unable to get the next id of $TABLE table"
  fi
  increment_next_id "$TABLE"
  echo "$next_id"
}

function increment_next_id() {
  local TABLE="$1"
  local result="$(execute_sql "UPDATE ${TABLE}_seq SET next_val=next_val+1")"
  local inserted="$(echo "$result" | jq -r '.numberOfRecordsUpdated')"
  if [ "$inserted" != "1" ]; then
    error_exit "Unable to get the next id of $TABLE table"
  fi
}

function insert() {
  local SQL="$1"
  local error="$2"
  local result="$(execute_sql "$SQL")"
  local inserted="$(echo "$result" | jq -r '.numberOfRecordsUpdated')"
  if [ "$inserted" != "1" ]; then
    error_exit "$error: $result"
  fi
}

function select_from() {
  local SQL="$1"
  local error="$2"
  local result="$(execute_sql "$SQL")"
  local id="$(echo "$result" | jq -r '.records[0][0].longValue')"
  if [ "$id" == "null" ]; then
    error_exit "$error: $result"
  fi
  echo "$id"
}

function create_user() {

  # Check user
  log_info "Check user $USERNAME exists..."
  local result="$(execute_sql "SELECT 1 FROM s_user WHERE login = \"$USERNAME\"")"
  local user_exists="$(echo "$result" | jq -r '.records|length')"

  # Create user as needed
  if [ "$user_exists" != "1" ]; then
   log_info "User $USERNAME does not exist"
   insert "INSERT INTO s_user (login) VALUES (\"$USERNAME\")" "Unable to create user $USERNAME"
  else
    log_info "User $USERNAME exists"
  fi

  # Check role
  log_info "Check role ADMIN..."
  local role_id="$(select_from 'SELECT id FROM s_role WHERE name = "ADMIN"' 'ADMIN Role does not exist yet')"
 
  # Associate ADMIN role
  log_info "Check role assignment for ADMIN role ($role_id) and user $USERNAME ..."
  result="$(execute_sql "SELECT 1 FROM s_role_assignment WHERE user = \"$USERNAME\" AND role = $role_id")"
  local assignment_exists="$(echo "$result" | jq -r '.records|length')"
  if [ "$assignment_exists" != "1" ]; then
    log_info "Get next role assignment id for ADMIN role ($role_id) and user $USERNAME ..."
    local next_assignment_id="$(next_id s_role_assignment)"
    log_info "Create role assignment ($next_assignment_id) for ADMIN role ($role_id) and user $USERNAME ..."
    insert "INSERT INTO s_role_assignment (id, role, user) VALUES ($next_assignment_id, $role_id,\"$USERNAME\")" "Unable to associate user $USERNAME to ADMIN role ($role_id)"
  fi

  # Create API KEY
  log_info "Check API key $API_TOKEN_NAME of user $USERNAME ..."
  result="$(execute_sql "SELECT 1 FROM s_api_token WHERE name = \"$API_TOKEN_NAME\" AND user = \"$USERNAME\"")"
  local token_exists="$(echo "$result" | jq -r '.records|length')"
  if [ "$token_exists" != "1" ]; then
    log_info "Get next API key id for user $USERNAME ..."
    local next_api_id="$(next_id s_api_token)"
    log_info "Create API key ($next_api_id) for user $USERNAME and named $API_TOKEN_NAME ..."
    insert "INSERT INTO s_api_token (id, name, user, token, hash) VALUES ($next_api_id, \"$API_TOKEN_NAME\",\"$USERNAME\",\"$API_TOKEN\", \"_plain_\")" "Unable to create a token $API_TOKEN_NAME for user $USERNAME"
    # Return the given token
    log_info "$API_TOKEN"
  else
    # Update the token
    log_info "$(echo "$result" | jq -r '.records[0][0].stringValue')"
  fi
  echo '{}' | jq -r --arg API_TOKEN_NAME "$API_TOKEN_NAME" --arg API_TOKEN "$API_TOKEN" --argjson MESSAGES "$MESSAGES" '
        {api_token:$API_TOKEN, message: $MESSAGES[0],api_token_name:$API_TOKEN_NAME}'
}
check_deps
parse_input
create_user
