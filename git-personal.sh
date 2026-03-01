#!/bin/bash
# git-personal.sh — Create or switch to a personal repo under chris-donut
#
# Usage:
#   bash scripts/git-personal.sh <project-name>   # Create new personal repo
#   bash scripts/git-personal.sh --list            # List personal repos
#   bash scripts/git-personal.sh --clone <repo>    # Clone existing personal repo
#
# Examples:
#   bash scripts/git-personal.sh my-experiment
#   bash scripts/git-personal.sh --clone donut-cli

set -euo pipefail

PERSONAL_DIR="$HOME/Desktop/Donut/Personal"
GITHUB_USER="chris-donut"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  echo "Usage:"
  echo "  $(basename "$0") <project-name>       Create new personal repo"
  echo "  $(basename "$0") --list               List personal repos (local + remote)"
  echo "  $(basename "$0") --clone <repo-name>  Clone an existing personal repo"
  echo ""
  echo "All personal projects live in: $PERSONAL_DIR/"
}

list_repos() {
  echo -e "${BLUE}=== Local personal projects ===${NC}"
  if [ -d "$PERSONAL_DIR" ]; then
    for d in "$PERSONAL_DIR"/*/; do
      [ -d "$d/.git" ] && echo -e "  ${GREEN}✓${NC} $(basename "$d")" || true
    done
  else
    echo "  (none — $PERSONAL_DIR does not exist yet)"
  fi

  echo ""
  echo -e "${BLUE}=== Remote repos (chris-donut) ===${NC}"
  gh repo list "$GITHUB_USER" --limit 20 --json nameWithOwner,isPrivate \
    --template '{{range .}}  {{if .isPrivate}}🔒{{else}}🌐{{end}} {{.nameWithOwner}}{{"\n"}}{{end}}'
}

clone_repo() {
  local repo_name="$1"
  mkdir -p "$PERSONAL_DIR"
  cd "$PERSONAL_DIR"

  if [ -d "$repo_name" ]; then
    echo -e "${YELLOW}Already cloned:${NC} $PERSONAL_DIR/$repo_name"
    cd "$repo_name"
    git status --short
  else
    echo -e "${GREEN}Cloning${NC} $GITHUB_USER/$repo_name → $PERSONAL_DIR/$repo_name"
    gh repo clone "$GITHUB_USER/$repo_name" "$repo_name"
    cd "$repo_name"
  fi

  echo ""
  echo -e "${GREEN}Ready!${NC} You're now in: $(pwd)"
  echo -e "Remote: $(git remote get-url origin)"
}

create_repo() {
  local project_name="$1"
  mkdir -p "$PERSONAL_DIR"
  cd "$PERSONAL_DIR"

  if [ -d "$project_name" ]; then
    echo -e "${YELLOW}Directory already exists:${NC} $PERSONAL_DIR/$project_name"
    cd "$project_name"
    echo "Remote: $(git remote get-url origin 2>/dev/null || echo 'none')"
    return
  fi

  mkdir "$project_name"
  cd "$project_name"
  git init
  echo "# $project_name" > README.md
  git add README.md
  git commit -m "Initial commit"

  echo ""
  echo -e "Create GitHub repo? ${YELLOW}(public/private/skip)${NC}"
  read -r visibility

  case "$visibility" in
    public)
      gh repo create "$GITHUB_USER/$project_name" --public --source=. --push
      echo -e "${GREEN}✓ Created public repo${NC}: https://github.com/$GITHUB_USER/$project_name"
      ;;
    private)
      gh repo create "$GITHUB_USER/$project_name" --private --source=. --push
      echo -e "${GREEN}✓ Created private repo${NC}: https://github.com/$GITHUB_USER/$project_name"
      ;;
    *)
      echo -e "${BLUE}Skipped.${NC} Repo is local-only. Push later with:"
      echo "  gh repo create $GITHUB_USER/$project_name --public --source=. --push"
      ;;
  esac

  echo ""
  echo -e "${GREEN}Ready!${NC} You're now in: $(pwd)"
}

# --- Main ---

if [ $# -eq 0 ]; then
  usage
  exit 0
fi

case "$1" in
  --list|-l)
    list_repos
    ;;
  --clone|-c)
    [ -z "${2:-}" ] && echo "Error: specify repo name" && exit 1
    clone_repo "$2"
    ;;
  --help|-h)
    usage
    ;;
  *)
    create_repo "$1"
    ;;
esac
