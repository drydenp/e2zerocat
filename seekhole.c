/* Changelog
 *
 * 9 nov 2016: first version
 *
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/fiemap.h>
#include <linux/fs.h>

#include <linux/fs.h>
#include <fcntl.h>
#include <unistd.h>

int fd;

struct fiemap *map;
const int SIZE = 4096;
int start;
int newblocksize; // !!

int nextblock(int start, int *next, int *length, int *value) {
	map->fm_start = newblocksize * start;
	int ret= ioctl(fd, FS_IOC_FIEMAP, map);
	if (ret >= 0) {
		*next = map->fm_extents[0].fe_logical / newblocksize;
		*length = map->fm_extents[0].fe_length / newblocksize;
		*value = map->fm_extents[0].fe_flags;
		printf("Starting at %d, next block is at %d with length %d\n", start, *next, *length);
	}
	return ret;
}

int main(int argc, char **args) {
	fd = open(args[1], O_RDONLY);
	
	map = malloc(sizeof (struct fiemap) + (2 * sizeof(struct fiemap_extent)));

	if (!map) {
		perror("Could not allocate fiemap buffers");
		exit(1);
	}

	start = atoi(args[2]);

	map->fm_length = ~0ULL;
	map->fm_extent_count = 2;

	if (ioctl(fd, FIGETBSZ, &newblocksize) < 0) {
		perror("Can't get block size");
		close(fd);
		exit(1);
	}
	printf ("New block size is %d\n", newblocksize);

	// to find the next hole.
	printf ("First hole is at:\n");

	int s = 0;
	int n, l, v, prevlength;
	int count = 0;
	while (nextblock(s, &n, &l, &v) >= 0 && count <= 10) {
		if (s == n) {
			s += l;
		} else {
			printf ("Hole from %d to %d with length %d\n", s, n-1, n-s);
			s = n + l;
			count++;
		}
	}
}


