New PC
======

1. Install NixOS (UEFI, user `benji`).

2. SSH key for GitHub (the repo is private):

       ssh-keygen -t ed25519
       cat ~/.ssh/id_ed25519.pub     # add at https://github.com/settings/ssh/new

3. Clone to exactly ~/nixcfg (a fresh install has no git yet):

       nix-shell -p git --run 'git clone git@github.com:Oibadaohnana/configs.git ~/nixcfg'

4. Run the setup checklist and follow it:

       ~/nixcfg/scripts/setup.sh

   It checks everything before the first build (host entry, disk UUIDs,
   untracked files, dotfile symlinks, a dry evaluation), runs the build, and
   after the reboot walks through keys, server access, Nextcloud and the
   manual steps. Run it again any time; it picks up where it stopped.
   `setup.sh --list` only prints the checklist.
