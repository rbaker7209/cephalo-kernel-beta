im writing this several days after, so i apologize, but blame the long as shit compile. I think this version works. heres how to run it.

sudo rm -rf /home/user/kernels && sudo rm -rf /home/user/kernel_build && sudo rm -rf /home/user/ceph-packs

this only needs to be run if there was an issue with the last build. if it crashed for independant reasons, skip this, the script will pick up where it left off. i think.

sudo HOME=/home/user/ JOBS=2 ./build_multitarget_kernel_0.0.8.sh

pass HOME so it doesnt fuck up your root install. JOBS is only needed on bare bones systems, isnt needed on beefy rigs, but i need JOBS=2 to not crash on 8gb. thats all the testing ive done.


other than that, we're both fucked, dear reader.
