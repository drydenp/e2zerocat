#!/bin/dash

# Take device file on $1.

# Use dumpe2fs to generate an output that we will interpret as lists of used and unused block ranges.

# We will transform the output into a list of ranges in the format "used xxx-yyy" and "unused xxx-yyy".

{ echo -n "" >&3; } 2> /dev/null || exec 3> /dev/null

into_fours() {
	local res
	begin=$1
	multi=1
	while [ $begin -gt 0 -a $multi -le 4096 ]; do
		for f in `seq 1 $(( begin & 3 ))`; do res="$multi $res"; done
		begin=$(( begin >> 2 ))
		multi=$(( multi << 2 ))
	done

	[ $begin -gt 0 ] && {
		for f in `seq 1 $(( begin * 4 ))`; do res="4096 $res"; done
	}
	echo "${res% }"
}

test_fours() {
	[ "$(into_fours 45)" = "16 16 4 4 4 1" ] || echo false
	[ "$(into_fours 36)" = "16 16 4" ] || echo false
	[ "$(into_fours 18)" = "16 1 1" ] || echo false
	[ "$(into_fours 4097)" = "4096 1" ] || echo false
	[ "$(into_fours 40000)" = "4096 4096 4096 4096 4096 4096 4096 4096 4096 1024 1024 1024 64" ] || echo false
}

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
				ranges=$(echo "$l" | sed "s/.*Free blocks: \?//")

				# The start of a group can either be used or free.
				# If it is free it will be our first free range.
				# If it is used the first free range, if any, will be past
				# the start of the group.

				# Consume the first range.)
				while [ -n "$ranges" -a $start -le $end ]; do
					range=${ranges%%, *}
					fstart=${range%%-*}
					fend=${range##*-}
					ranges=${ranges#*, }
					# If range and ranges are identical, we are done with that:
					[ "$range" = "$ranges" ] && ranges=

					# Normally we are now at the start of a used range.
					# This is because after a free range, we advance our pointer
					# just beyond it.

					# Since there are free ranges left, we are not at the end yet.
					# Therefore, if start equals fstart, we *had* no used range
					# at the beginning and there is nothing to consume there.

					! [ $start -eq $fstart ] && {

						# But since our fstart is now larger, we do have something to consume.
						echo "used: ${start}-$(( fstart-1 ))"
					}

					# We can now consume the free range we came here for:
					echo "unused: ${fstart}-${fend}"

					# And advance the pointer
					start=$(( fend + 1 ))

					# If we are out of ranges in the next cycle but if start
					# has not advanced beyond end yet, there is a used range left.

					# Otherwise, we ended with a free block.
				done

				# So this is the final used range, if any:
				[ $start -le $end ] && {
					echo "used: ${start}-${end}"

					# Coincidentally this also covers the situation of no Free blocks.
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
		amount=$(( ending - beginning + 1 ))
		[ "$amount" -eq 0 ] && {
			echo "amount zero with $beginning and $ending and $l" >&3
		}

		[ "$start" = "used" ] && {
			dd if="$device" bs=$size skip=$beginning count=$amount 2> /dev/null

			# This checksum code makes it twice as slow.
			# But I can't actually use the shell to "save" binary data.
			# Or even split it, so the amount of dd calls goes up considerably.

			# In C if I could read the data myself (in one read) and then calculate
			# the checksums myself 

			# We will split each range into 16MB blocks or smaller.
			sequence=$(into_fours $amount)
			echo "** amount = $amount" >&3
			while [ -n "$sequence" ]; do
				next=${sequence%% *}
				oldsequence=$sequence
				sequence=${sequence#$next }
				[ "$sequence" = "$oldsequence" ] && sequence=

				md5=$(dd if="$device" bs=$size skip=$beginning count=$next 2> /dev/null | md5sum)
				md5=${md5%% *}
				echo "* $beginning $next $md5" >&3
				beginning=$(( beginning + next ))
			done
			echo >&3

			true
		} || {
			dd if=/dev/zero bs=$size count=$amount 2> /dev/null
		}
		total=$(( total + amount ))
	done
	echo "Total blocks written: $total" >&2
	echo "Block count for device: $count" >&2
}
		
list=$(dumpe2fs "$1" 2> /dev/null | transform_dumpe2fs)

echo "$list" | feed_to_dd "$1"
	
