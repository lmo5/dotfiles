mount /dev/nvme0n1p4 -t ntfs-3g -o permissions 

sudo umount /path/to/mount/point
sudo mount -t ntfs-3g -o uid=$(id -u),gid=$(id -g),umask=022 /dev/nvme0n1p4 /media/ayoub/data


/media/ayoub/data/private/albums/organized/2020/03/IMG-20200324-WA0005.jpg

/media/ayoub/data/private/albums/organized/2020/03/PLTP3455.JPG