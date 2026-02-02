# LR-S
#### Server Emulator for the game Arknights: Endfield.
![title](assets/img/title.png)

# Getting Started
## Requirements
- Zig 0.16.0-dev.2368: [Linux](https://ziglang.org/builds/zig-x86_64-linux-0.16.0-dev.2368+380ea6fb5.tar.xz)/[Windows](https://ziglang.org/builds/zig-x86_64-windows-0.16.0-dev.2368+380ea6fb5.zip)

#### For additional help, you can join our [discord server](https://discord.xeondev.com)

## Setup
### Building from sources
#### Linux
```sh
git clone https://git.xeondev.com/LR/S.git
cd S
. ./envrc # In case you don't have zig installed, `envrc` can do this for you.
zig build run-confsv &
zig build run-gamesv
```
#### Windows
```bat
# Assuming you have git and zig installed.
git clone https://git.xeondev.com/LR/S.git
cd S
zig build run-confsv -Doptimize=ReleaseSmall
# Open another instance of cmd.exe in this directory, then run:
zig build run-gamesv -Doptimize=ReleaseSmall
```

### Logging in
Currently supported client version is `1.0.14`, you can get it from 3rd party sources.

Next, you have to apply the necessary [client patch](https://git.xeondev.com/LR/C). It allows you to connect to the local server.

## Community
- [Our Discord Server](https://discord.xeondev.com)
- [Our Telegram Channel](https://t.me/reversedrooms)

## Donations
Continuing to produce open source software requires contribution of time, code and -especially for the distribution- money. If you are able to make a contribution, it will go towards ensuring that we are able to continue to write, support and host the high quality software that makes all of our lives easier. Feel free to make a contribution [via Boosty](https://boosty.to/xeondev/donate)!
