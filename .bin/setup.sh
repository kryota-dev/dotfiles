#!/bin/zsh

# Font Setup
## Moralerspace
echo -e "\033[0;34m- Moralerspace Font Setup...\033[0m"
MORALERSPACE_VERSION=2.0.0
curl -L -O https://github.com/yuru7/moralerspace/releases/download/v${MORALERSPACE_VERSION}/Moralerspace_v${MORALERSPACE_VERSION}.zip
unzip Moralerspace_v${MORALERSPACE_VERSION}.zip
\cp -f Moralerspace_v${MORALERSPACE_VERSION}/*.ttf ~/Library/Fonts/
rm -rf Moralerspace_v${MORALERSPACE_VERSION}.zip Moralerspace_v${MORALERSPACE_VERSION}
