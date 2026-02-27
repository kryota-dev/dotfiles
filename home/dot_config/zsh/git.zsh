alias g='git'
alias gb='git branch'
alias gs='git status'
alias gca='git commit --amend'
alias gf='git fetch'
alias gpl='git pull origin HEAD'
alias gps='git push origin HEAD'
alias gac='git reset HEAD .'
alias gcc='git reset --hard HEAD~'
alias gsl='git stash list'

function gcl() {
  local URL=$1
  git clone "${URL}"
}
function gch() {
  local BRANCH=${1:-main}
  git checkout "${BRANCH}"
}
function gcb() {
  local BRANCH=$1
  git checkout -b "${BRANCH}"
}
function ga() {
  local FILE=${1:-.}
  git add "${FILE}"
}
function gc() {
  local MESSAGE=${1:-minor adjustment}
  git commit -m "${MESSAGE}"
}
function gr() {
  local BRANCH=${1:-main}
  git rebase "${BRANCH}"
}
function gss() {
  local MESSAGE=$1
  git stash save "${MESSAGE}"
}
function gsa() {
  local STASH_NAME=$1
  git stash apply "${STASH_NAME}"
}
function gsd() {
  local STASH_NAME=$1
  git stash drop "${STASH_NAME}"
}
