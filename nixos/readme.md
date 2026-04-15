on the pc:

git:
cd ~
mv nixcfg nixcfg.bak
mkdir nixcfg
git clone git@github.com:Oibadaohnana/configs.git ~/nixcfg

hardware:
adjust the labels in hardware/pc.nix!

to do so you can list them in /dev/disk/by-uuid or just copy them from the (probably?) working config thats on your desktop in /etc/nixos/hardware-configuration.nix

then build ONCE without using buildsys but by using 

sudo nixos-rebuild switch --flake /home/benji/nixcfg/nixos#benji-desktop


after that, the buildsys alias should work since you dont need to add the #benji-desktop anymore.

