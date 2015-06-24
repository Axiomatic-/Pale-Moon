#!/bin/bash

# Constants
srcdir="$(readlink -e "$(dirname "$0")"/../..)"
objdir="$(readlink -f "$srcdir/../pmbuild")"
logfile="$srcdir/travis.log"

build_palemoon () {
	set -e

	export CC="clang"
	export CXX="clang++"

	case $(uname -m) in
		i*86)
			optflags='-msse2 -mfpmath=sse'
			;;
		*)
			optflags=''
			;;
	esac
	echo \
"
mk_add_options MOZ_MAKE_FLAGS="-j2"
mk_add_options MOZ_CO_PROJECT=browser
ac_add_options --enable-application=browser

mk_add_options MOZ_OBJDIR=\"$objdir\"

ac_add_options --disable-installer
ac_add_options --disable-updater

ac_add_options --disable-tests
ac_add_options --disable-mochitests

ac_add_options --disable-jemalloc
ac_add_options --enable-optimize='$optflags'

ac_add_options --prefix=/usr
ac_add_options --x-libraries=/usr/lib
" > "$srcdir/.mozconfig"

	make -f client.mk build
	cd "$objdir"
	make package
}

upload_build () {
	set +e

	file="$(readlink -e "$1")"

	if [[ ! -f $file ]] || [[ ! -r $file ]]; then
		echo "The path is invalid, or the file could not be read."
		return 0
	fi

	if ! tmpdir="$(mktemp -d /tmp/upload.XXXXXXXXX)"; then
		echo "The temporary directory could not be created."
		return 0
	fi

	cookiejar="$tmpdir/cookies.txt"
	useragent="Mozilla/5.0 (Windows NT 6.1; rv: 31.0) Gecko/20100101 Firefox/31.0"
	homepage_url="http://zippyshare.com/sites/index_old.jsp"
	homepage_file="$tmpdir/zippyshare.homepage"
	response_file="$tmpdir/zippyshare.response"

	if ! curl -sLfc "$cookiejar" "$homepage_url" -A "$useragent" -o "$homepage_file"; then
		echo "Failed to retrieve homepage."
		return 0
	fi

	upload_url="$(grep -Eo 'http://www[0-9]+\.zippyshare\.com/upload' "$homepage_file")"

	if ! [[ $upload_url =~ ^http://www[0-9]+\.zippyshare\.com/upload$ ]]; then
		echo "The upload destination could not be determined!"
		return 0
	fi

	csrf_token="$(grep -Eio "uploadid = '[a-z0-9]+'" "$homepage_file" | sed "s/ //g;s/'//g")"

	if ! [[ $csrf_token =~ ^uploadId=[A-Za-z0-9]+$ ]]; then
		echo "The CSRF token could not be determined!"
		return 0
	fi

	if ! curl -sLfb "$cookiejar" -F "file_upload=@$file" -F "$csrf_token" "$upload_url" -A "$useragent" -o "$response_file"; then
		echo "Failed to upload file."
		return 0
	fi

	file_url="$(grep -Eio 'http://www[0-9]+\.zippyshare\.com/.*/file\.html' "$response_file" | head -n 1)"

	if ! [[ $file_url =~ ^http://www[0-9]+\.zippyshare\.com/.*/file\.html$ ]]; then
		echo "The URL to which the file was uploaded could not be determined."
		return 0
	fi

	echo "File uploaded to: $file_url"
}

cd "$srcdir"

if [[ -z "$1" ]]; then
	echo "Action to be performed was not given."
	exit 1
fi

if [[ -z $CONTINUOUS_INTEGRATION ]]; then
	echo "This build is not running in a CI environment. To force the build, use CONTINUOUS_INTEGRATION=true $0"
	exit 1
fi

if [[ -z $palemoon_ci_logging ]]; then
	# Invoke a background process with the the variable defined.
	palemoon_ci_logging=true "$srcdir/build/travis_ci/travis_ci.sh" "$1" &> "$logfile" &
	ps_pid=$!
	echo -n "Started job $1"

	# Keep Travis-CI from killing the build process, by writing something to the screen.
	while kill -0 $ps_pid &>/dev/null; do
		echo -n ' .'
		sleep 30
	done

	wait $ps_pid
	exitstat=$?

	echo -e "\n\nJob '$1' completed with exit status $exitstat"

	if [[ "$(wc -l < "$logfile")" -ge 0 ]]; then
		# There's a maximum logging limit too (4 MB at the time of this writing.)
		echo "Last 200 lines of output from the log:"
		tail -n 200 "$logfile"
	fi
	exit $exitstat
fi

case "$1" in
	deps)
		install_deps
		;;
	build)
		build_palemoon && upload_build "$objdir"/dist/palemoon-*.tar.bz2
		;;
	*)
		echo "Unknown job type: $1"
		exit 2
esac
