#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 {commit|anonymize-commit}" >&2
}

commit_changes() {
    local issue_number
    local commit_message

    read -r -p "Issue number: " issue_number
    read -r -p "Commit message: " commit_message

    if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
        echo "Error: issue number must contain digits only." >&2
        exit 1
    fi

    if [[ -z "${commit_message//[[:space:]]/}" ]]; then
        echo "Error: commit message must not be empty." >&2
        exit 1
    fi

    git commit -m "${commit_message} #${issue_number}"
}

anonymize_commit() {
    local current_name="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-}}"
    local current_email="${GIT_AUTHOR_EMAIL:-${GIT_COMMITTER_EMAIL:-}}"
    local suggested_email
    local public_email

    case "${current_email}:${current_name}" in
        darko.palic@xenovation.com:*|*:Darko|*:Darko\ Palic)
            suggested_email="1399203+dpalic@users.noreply.github.com"
            ;;
        *@users.noreply.github.com:*)
            suggested_email="$current_email"
            ;;
        *)
            suggested_email=""
            ;;
    esac

    if [[ -n "$suggested_email" ]]; then
        read -r -p "Public Git email [$suggested_email]: " public_email
        public_email="${public_email:-$suggested_email}"
    else
        read -r -p "Public Git email (for example, 1399203+dpalic@users.noreply.github.com): " public_email
    fi

    if [[ ! "$public_email" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
        echo "Error: enter a valid Git email address." >&2
        exit 1
    fi

    export GIT_AUTHOR_EMAIL="$public_email"
    export GIT_COMMITTER_EMAIL="$public_email"

    git config --local user.email "$public_email"
    git commit --amend --no-edit --reset-author
}

case "${1:-}" in
    commit)
        commit_changes
        ;;
    anonymize-commit)
        anonymize_commit
        ;;
    *)
        usage
        exit 1
        ;;
esac
