#!/bin/bash

# Take device file on $1.

# Use dumpe2fs to generate an output that we will interpret as lists of used and unused block ranges.

# We will transform the output into a list of ranges in the format "used xxx-yyy" and "unused xxx-yyy".

transform_dumpe2fs() {
	# Read until the first newline (empty line):

	out=$(while read l && [ -n "$l" ]; do echo "$l"; done)

	# Grep block count and block size:

	first_block=$(echo "$out" | grep "^First block:" | sed "s/.* //")
	block_count=$(echo "$out" | grep "^Block count:" | sed "s/.* //")
	block_size=$(echo "$out" | grep "^Block size:" | sed "s/.* //")

	# First just output these stats here:

	echo "first: $first_block" 
	echo "blocks: $block_count"
	echo "size: $block_size"
	echo "----"

	# Now process all the groups:

	while read l; do
		[ ! $waitforfree ] && echo "$l" | grep "^Group" > /dev/null && {
			range=$(echo "$l" | sed "s/.*Blocks \([0-9]\+\)-\([0-9]\+\).*/\1 \2/")
			start=${range%% *}
			end=${range##* }
			waitforfree=yes
			continue
		}
		# We must now "substract" the free block ranges from the full range, or otherwise...
		# make sure we identify both parts.

		# The range always starts with a used block.
		[ $waitforfree ] && {
			echo "$l" | grep "^Free blocks" > /dev/null && {
				ranges=$(echo "$l" | sed "s/.*Free blocks: //")

				# Consume the first range.)
				while [ -n "$ranges" -a $start -le $end ]; do
					range=${ranges%%, *}
					fstart=${range%%-*}
					fend=${range##*-}
					ranges=${ranges#*, }
					# If range and ranges are identical, we are done with that:
					[ "$range" = "$ranges" ] && ranges=

					# The first useful range is $start to $fstart, noninclusive:

					echo "used: ${start}-$(( fstart-1 ))"

					# Just update start to the next one:

					start=$(( fend + 1 ))

					echo "unused: ${fstart}-${fend}"

					# Now we "wait" for the next free range. If there is none, or if
					# start is now bigger than end, we are done.
				done
				# Actually that's mistaken. If start < end we have to output the final
				# usable range

				[ $start -le $end ] && {
					echo "used: ${start}-${end}"
				}
					
				# This is because the last range may not be a free range.
				waitforfree=
			}
			# At this point we just have to throw lines away.
		}
	done
}

# Now that we have our output, we can use it to fuel our engine:

feed_to_dd() {
	device=$1

	out=$(for i in `seq 1 4`; do read a; echo "$a"; done)
	first=$(echo "$out" | grep "^first" | sed "s/.* //")
	size=$(echo "$out" | grep "^size" | sed "s/.* //")
	count=$(echo "$out" | grep "^blocks" | sed "s/.* //")

	# This is getting weird, but first dd the blocks leading up to the first block.

	dd if="$device" bs=$size count=$first 2> /dev/null || {
		echo "DD fails, cannot continue"
		exit 1
	}
	total=$first

	while read l; do
        range=${l##* }
		start=${l%%: *}
		beginning=${range%%-*}
		ending=${range##*-}
        [ "$start" = "used" ] && {
			total=$(( total + ending - beginning + 1 ))
			amount=$(( ending - beginning + 1 ))
			output=$(dd if="$device" bs=$size skip=$beginning count=$amount 2> /dev/null)

			true
		} || {
			total=$(( total + ending - beginning + 1 ))
			dd if=/dev/zero bs=$size count=$(( ending - beginning + 1 )) 2> /dev/null
		}
	done
	echo "Total blocks written: $total" >&2
	echo "Block count for device: $count" >&2
}
		
list=$(dumpe2fs "$1" 2> /dev/null | transform_dumpe2fs)

echo "$list" | feed_to_dd "$1"
	
