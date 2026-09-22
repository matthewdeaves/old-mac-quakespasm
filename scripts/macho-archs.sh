#!/bin/sh
# Print a Mach-O file's slices as `lipo -archs` would: "ppc750 ppc7400 ppc970
# i386 x86_64 arm64". Reads the header bytes itself instead of asking lipo.
#
# Why: the workstation's lipo (Xcode / CLT 27, macOS 26.6, measured 2026-09-22)
# no longer knows PowerPC. `lipo -info` on a g3 slice prints only
# "big-endian-mach-o: <path>" and `lipo -detailed_info` on the fat binary says
# "cputype unknown" for all three PPC slices, so every check that named a PPC
# subtype through lipo broke on the orchestration host. The exact subtype is
# what the hard rule cares about (ADR 0002), and it is four bytes in the
# header, so read those.
#
# Plain sh + od: runs on the workstation, imac-2019 and a Tiger host alike.
# An unrecognised cputype/subtype prints as "cpu<type>/<subtype>", never as a
# guess, so a check comparing names fails instead of passing on noise.
#
# usage: scripts/macho-archs.sh FILE      exit 1 if FILE is not Mach-O

f="${1:?usage: $0 FILE}"
[ -r "$f" ] || { echo "macho-archs: cannot read $f" >&2; exit 1; }

# u32 at byte offset $1, big-endian ($2=be) or little-endian ($2=le), as decimal.
u32 () {
	set -- $(od -An -tu1 -j "$1" -N4 "$f") "$2"
	[ "$#" -eq 5 ] || { echo 0; return; }
	if [ "$5" = be ]; then
		echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
	else
		echo $(( ($4 << 24) | ($3 << 16) | ($2 << 8) | $1 ))
	fi
}

name () {  # cputype cpusubtype (decimal, subtype with capability bits masked)
	case "$1/$2" in
	18/0)          echo ppc ;;       # generic ppc (ALL): a launch blocker on Tiger/Leopard
	18/9)          echo ppc750 ;;
	18/10)         echo ppc7400 ;;
	18/11)         echo ppc7450 ;;
	18/100)        echo ppc970 ;;
	7/3)           echo i386 ;;
	16777223/3)    echo x86_64 ;;
	16777223/8)    echo x86_64h ;;
	16777228/0)    echo arm64 ;;
	16777228/2)    echo arm64e ;;
	*)             echo "cpu$1/$2" ;;
	esac
}

magic=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
case "$magic" in
cafebabe)                                  # fat: header is always big-endian
	n=$(u32 4 be)
	[ "$n" -ge 1 ] && [ "$n" -le 16 ] || { echo "macho-archs: bad fat header in $f" >&2; exit 1; }
	out="" i=0
	while [ "$i" -lt "$n" ]; do
		o=$((8 + i * 20))
		out="$out $(name "$(u32 $o be)" $(( $(u32 $((o + 4)) be) & 16777215 )))"
		i=$((i + 1))
	done
	echo "${out# }"
	;;
feedface|feedfacf)                         # thin, big-endian (PowerPC)
	name "$(u32 4 be)" $(( $(u32 8 be) & 16777215 ))
	;;
cefaedfe|cffaedfe)                         # thin, little-endian (Intel, arm64)
	name "$(u32 4 le)" $(( $(u32 8 le) & 16777215 ))
	;;
*)
	echo "macho-archs: not a Mach-O file: $f (magic $magic)" >&2
	exit 1
	;;
esac
