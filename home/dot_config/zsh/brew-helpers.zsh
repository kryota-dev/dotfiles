function update-brewfile() {
  rm -rf ~/dotfiles/home/dot_Brewfile
  brew bundle dump --file ~/dotfiles/home/dot_Brewfile
  git -C ~/dotfiles add home/dot_Brewfile
  git -C ~/dotfiles commit -m "chore: update Brewfile"
}

function pull-update-brewfile() {
  git -C ~/dotfiles pull
  brew bundle cleanup --force --file ~/dotfiles/home/dot_Brewfile
  brew bundle --file ~/dotfiles/home/dot_Brewfile
}

function push-dotfiles() {
  git -C ~/dotfiles add .
  git -C ~/dotfiles commit -m "chore: update dotfiles"
}

function pull-dotfiles() {
  git -C ~/dotfiles pull
}
