#!/bin/bash
#author: jiyin@redhat.com

# https://en.wikichip.org/wiki/irc/colors
ircBold=$'\x02'
ircItalics=$'\x1D'
ircUnderline=$'\x1F'
ircReverse=$'\x16'
ircPlain=$'\x0F'

ircWhite=$'\x03'00
ircBlack=$'\x03'01
ircNavy=$'\x03'02
ircGreen=$'\x03'03
ircRed=$'\x03'04
ircMaroon=$'\x03'05
ircPurple=$'\x03'06
ircOlive=$'\x03'07
ircYellow=$'\x03'08
ircLightGreen=$'\x03'09
ircTeal=$'\x03'10
ircCyan=$'\x03'11
ircRoyalblue=$'\x03'12
ircMagenta=$'\x03'13
ircGray=$'\x03'14
ircLightGray=$'\x03'15

mkdir -p /var/cache/distroDB
pushd /var/cache/distroDB  >/dev/null
baseurl=http://download.devel.redhat.com
supath=compose/metadata/composeinfo.json
mailTo=fs@redhat.com
mailCc=net@redhat.com
from="distro monitor <from@redhat.com>"

kgitDir=/home/yjh/ws/code.repo
VLIST="6 7 8"
DVLIST=$(echo $VLIST)
latestDistroF=.latest.distro
dfList=$(eval echo $latestDistroF{${DVLIST// /,}})
#echo $dfList
debug=$1

distro-list.sh --tag all | sort -r | egrep '^RHEL-'"[${VLIST// /}]" >.distroListr

\cp .distroList .distroList.orig
while read d; do
	pkgList=$(awk -v d=$d 'BEGIN{ret=1} $1 == d {$1=""; print; ret=0} END{exit ret}' .distroList.orig) || {
		r=$d
		[[ "$r" =~ ^RHEL-?[0-9]\.[0-9]$ ]] && r=${r%%-*}-./${r##*-}
		pkgList=$(vershow '^(kernel|nfs-utils|autofs|rpcbind|[^b].*fs-?progs)-[0-9]+\..*' "/$r$" |
			grep -v ^= | sed -r 's/\..?el[0-9]+.?\.(x86_64|i686|noarch|ppc64le)\.rpm//g' |
			sort --unique | xargs | sed -r 's/(.*)(\<kernel-[^ ]* )(.*)/\2\1\3/')
	}
	[ -z "$pkgList" ] && continue
	pkgList=${pkgList%%\"label\":*}
	#read auto kernel nfs rpcbind nil <<<$pkgList
	#echo -n -e "$d\t$kernel  $nfs  $auto  $rpcbind"
	read kernel nil <<<$pkgList
	echo -n "$d  ${pkgList}  "

	dpath=$(vershow -n kernel "$d$" | awk '/RHEL/{if(NR==1) print $1}')
	curl $baseurl/$dpath/$supath 2>/dev/null|grep -o '"label": "[^"]*"' || echo
done <.distroListr >.distroList

test -n "`cat .distroList`" &&
	for V in $DVLIST; do
	    egrep -i "^RHEL-${V}.[0-9]+" .distroList >${latestDistroF}$V.tmp
	done

for f in $dfList; do
	[ ! -f ${f}.tmp ] && continue
	[ -z "`cat ${f}.tmp`" ] && continue
	[ -f ${f} ] || {
		mv ${f}.tmp ${f}
		continue
	}
	[ -n "$debug" ] && {
		echo
		cat ${f}.tmp
		diff -pNur -w ${f} ${f}.tmp | sed 's/^/\t/'
		rm -f ${f}.tmp
		continue
	}

	V=${f/$latestDistroF/}

	available=1
	p=${PWD}/${f}.patch
	# print lines of file "${f}.tmp" for which the first column
	# (distro name) has not been seen in file "$f"
	awk 'NR==FNR{c[$1]++;next};c[$1] == 0' $f ${f}.tmp > $p
	[[ -s "$p" ]] || continue
	# reverse lines to show the newer distro afterwards
	sed -i '1!G;h;$!d;' $p

	while read line; do
		[[ -z "$line" || "$line" =~ ^\+\+\+ ]] && continue

		for chan in "#fs-qe" "#network-qe"; do
			ircmsg.sh -s fs-qe.usersys.redhat.com -p 6667 -n testBot -P rhqerobot:irc.devel.redhat.com -L testBot:testBot -C "$chan" \
				"${ircBold}${ircRoyalblue}{Notice}${ircPlain} new distro: $line"
			sleep 1
		done

		# Highlight the packages whose version is increasing
		if echo $line | egrep -q 'RHEL[-.[:digit:]]+n[.[:digit:]]+'; then
			# nightly
			dtype="n"
		elif echo $line | egrep -q 'RHEL-[.[:digit:]]+-[.[:digit:]]+'; then
			# rtt
			dtype="r"
		else
			# should not be here
			continue
		fi
		echo $line | sed 's/\s\+/\n/g' > ${f}.pkgvers_${dtype}.tmp
		tmpKernel=$(awk -F'-' '/^kernel/{print $3}' ${f}.pkgvers_${dtype}.tmp)
		preKernel=$(awk -F'-' '/^kernel/{print $3}' ${f}.pkgvers_${dtype})
		if [[ $tmpKernel -lt $preKernel ]]; then
			# ignore the distro whose (kernel) version gets reversed
			continue
		fi
		pkgDiff=$(diff -pNur -w ${f}.pkgvers_${dtype} ${f}.pkgvers_${dtype}.tmp | awk '/^+[^+]/{ORS=" "; print $0 }' | cut -d " " -f 2-)
		if [ -n "$pkgDiff" ]; then
			preDistro=$(head -1 ${f}.pkgvers_${dtype})
			ircmsg.sh -s fs-qe.usersys.redhat.com -p 6667 -n testBot -P rhqerobot:irc.devel.redhat.com -L testBot:testBot -C "#fs-qe" \
			    "${ircPlain}highlight newer pkg: ${ircTeal}${pkgDiff} ${ircPlain}(vary to $preDistro)"
		fi
		mv ${f}.pkgvers_${dtype}.tmp ${f}.pkgvers_${dtype}
	done <$p

	#get stable version
	stbVersion=$(grep '^+[^+]' ${p} | awk '$(NF-1) ~ ".label.:"{print $1}' | head -n1)


	# print kernel changelog
	echo >>$p
	echo "#-------------------------------------------------------------------------------" >>$p
	url=ftp://fs-qe.usersys.redhat.com/pub/kernel-changelog/changeLog-$V
	echo "# $url" >>$p
	tagr=$(awk '$1 ~ /^RHEL-/ && $2 ~ /kernel-/ {print $2}' $p | tail -n1 | sed s/$/.el${V}/)
	(echo -e "{Info} ${tagr} change log:"

	vr=${tagr/kernel-/}
	sed -n '/\*.*\['"${vr}a\?"'\]/,/^$/{p}' /var/cache/kernelnvrDB/*changeLog-${V} >changeLog
	sed -n '1p;q' changeLog
	grep '^-' changeLog | sort -k2,2
	echo) >>$p

	echo -e "\n\n#===============================================================================" >>$p
	echo -e "\n#Generated by cron latestDistroCheck" >>$p
	echo -e "\n#cur:" >>$p; cat $f.tmp >>$p
	echo -e "\n#pre:" >>$p; cat $f     >>$p

	[ $available = 1 ] && {
		sendmail.sh -p '[Notice] ' -f "$from" -t "$mailTo" -c "$mailCc" "$p" ": new RHEL${V} distro available"  &>/dev/null
		#cat $p
		mv ${f}.tmp ${f}
	}

	#if there is a stable version released, create testplan run
	[[ "${stbVersion#+}" =~ ^RHEL-(6.7|7.1) ]] && {
		#bkr-autorun-create ${stbVersion#+} /home/yjh/ws/case.repo/nfs-utils/nfs-utils.testlist --name nfs-utils.testplan
		: #bkr-autorun-create ${stbVersion#+} /home/yjh/ws/case.repo/kernel/filesystems/nfs/nfs.testlist --name nfs.testplan
	}

	rm -f $p
done

exit 0

popd  >/dev/null

