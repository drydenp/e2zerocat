#!/bin/sh

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
	awk '
		BEGIN {
			waitforfree = 0
		}
		/^Group/ {
			if (! waitforfree) {
				range = gensub(/.*Blocks ([0-9]+)-([0-9]+).*/, "\\1 \\2", "g")
				$0 = range
				start = $1
				end = $2
				waitforfree = 1
				next
			}
		}

		# We must now "substract" the free block ranges from the full range, or otherwise...
		# make sure we identify both parts.

		# The range always starts with a used block.
		/Free blocks/ {
			if (waitforfree) {
				sub(/^ *Free blocks: ?/,"")

				# The start of a group can either be used or free.
				# If it is free it will be our first free range.
				# If it is used the first free range, if any, will be past
				# the start of the group.

				# Split the string into an array of ranges
				number_ranges = split($0, ranges, ", ")

				# Traverse all the ranges in order:
				for (i = 1; i <= number_ranges; i++) {
					if (start > end) break

					range = ranges[i]

					fstart = gensub(/-.*/, "", "g", range)  # get the part before the dash
					fend = gensub(/.*-/, "", "g", range)    # get the part after the dash

					# Normally we are now at the start of a used range.
					# This is because after a free range, we advance our pointer
					# just beyond it.

					# Since there are free ranges left, we are not at the end yet.
					# Therefore, if start equals fstart, we *had* no used range
					# at the beginning and there is nothing to consume there.

					if (start != fstart) {
						# But since our fstart is now larger, we do have something to consume.
						print "used: " start "-" fstart-1
					}

					# We can now consume the free range we came here for:
					print "unused: " fstart "-" fend

					# And advance the pointer
					start = fend + 1

					# If we are out of ranges in the next cycle but if start
					# has not advanced beyond end yet, there is a used range left.

					# Otherwise, we ended with a free block.
				}

				# So this is the final used range, if any:
				if (start <= end) {
					print "used: " start "-" end
					
					# Coincidentally this also covers the situation of no Free blocks.
				}
					
				# This is because the last range may not be a free range.
				waitforfree = 0
			}
		}
		# At this point we just have to throw lines away.
	'
}

verify_transform() {
	# The used and unused blocks we get have to be consecutive and span the entire range.

	start=0
	error=0
	total=0
	while read header content; do
		case $header in
			blocks:)
				block_count=$content
				;;
			used:|unused:)
				begin=${content%-*}
				if [ -z "$first" ]; then
					first=$begin
				fi
				end=${content#*-}
				amount=$(( end - begin + 1 ))
				if [ $begin -ne $start ]; then
					echo "We have a range that doesn't start at the beginning of the next range: begins at $begin, should begin at $start" >&2
					error=1
				fi
				start=$(( end + 1 ))
				total=$(( total + amount ))
				;;
		esac
	done
	echo "First block range starts at $first" >&2
	echo "Last block range ends at $end" >&2
	[ $total -ne $block_count ] && {
		echo "Total amount of blocks found in ranges does not coincide with total block size for device: $block_count blocks but $total counted" >&2
		error=1
	}
	if [ $error -eq 0 ]; then
		echo "No errors found" >&2
	fi
	return $error
}

# Now that we have our output, we can use it to fuel our engine:

feed_to_dd() {
	device=$1

	out=$(for i in `seq 1 4`; do read a; echo "$a"; done)
	first=$(echo "$out" | grep "^first" | sed "s/.* //")
	size=$(echo "$out" | grep "^size" | sed "s/.* //")
	count=$(echo "$out" | grep "^blocks" | sed "s/.* //")

	# The first block may not be at 0, so we dd the blocks leading up to it first.

	dd if="$device" bs=$size count=$first 2> /dev/null || {
		echo "DD fails, cannot continue"
		exit 1
	}

	# Counter

	total=$first

	while read l; do
		range=${l##* }
		start=${l%%: *}
		beginning=${range%%-*}
		ending=${range##*-}
		amount=$(( ending - beginning + 1 ))
		[ "$amount" -le 0 ] && {
			echo "Bug in the script. Amount cannot be zero or negative at $beginning and $ending and $l" >&2
		}

		[ "$start" = "used" ] && {
			# This outputs the blockrange to stdout

			dd if="$device" bs=$size skip=$beginning count=$amount 2> /dev/null

			# This code calls md5sum on pieces of the block range to get checksums
			# for individual chunks not larger than 16 MB normally.

			# It basically uses the filesystem cache to reread an already read and copied block.
			# On slow systems the bottleneck is in the md5sum code, not in the calling.

			sequence=$(into_fours $amount)

			# This is verification code, the individual amounts must sum up to $amount
			echo "* amount = $amount" >&3

			while [ -n "$sequence" ]; do
				next=${sequence%% *}
				oldsequence=$sequence
				sequence=${sequence#$next }
				[ "$sequence" = "$oldsequence" ] && sequence=

				md5=$(dd if="$device" bs=$size skip=$beginning count=$next 2> /dev/null | md5sum)
				md5=${md5%% *}
				echo "$beginning $next $md5" >&3
				beginning=$(( beginning + next ))
			done

			# Splitting the individual block ranges with a newline:
			echo >&3

			true
		} || {
			dd if=/dev/zero bs=$size count=$amount 2> /dev/null
		}
		total=$(( total + amount ))
	done

	# This is some verification code
	echo "Total blocks written: $total" >&2
	echo "Block count for device: $count" >&2
	# These numbers have to match
}
		
list=$(dumpe2fs "$1" 2> /dev/null | transform_dumpe2fs) || echo "Dump transform failed." >&2

printf "%s\n" "$list" | feed_to_dd "$1"
	
