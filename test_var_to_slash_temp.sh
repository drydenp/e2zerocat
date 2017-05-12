#!/bin/sh

umount /mnt2
./e2zerocat.sh /dev/mapper/var2_crypt | cp --sparse=always /dev/stdin /tmp/test.sparse
mount /tmp/test.sparse /mnt2
find /var2 -xdev -type f | while read f; do diff "$f" /mnt2/${f#/*/} || echo "A file differs ! $f"; echo "CRAP $f" >> log; done
sleep 1s
umount /mnt2
