#!/bin/bash

# Constants
srcdir="$(readlink -e "$(dirname "$0")"/../..)"
objdir="$(readlink -f "$srcdir/../pmbuild")"
logfile="$srcdir/travis.log"

install_deps () {
	set -e

	sudo add-apt-repository ppa:ubuntu-toolchain-r/test -y
	sudo apt-get update -y --force-yes
	sudo apt-get install -y --force-yes zip unzip clang make autoconf2.13 yasm libgtk2.0-dev libglib2.0-dev libdbus-1-dev libdbus-glib-1-dev libasound2-dev libiw-dev libxt-dev mesa-common-dev libgstreamer0.10-dev libgstreamer-plugins-base0.10-dev libpulse-dev m4 flex
}

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
mk_add_options MOZ_CO_PROJECT=browser
ac_add_options --enable-application=browser

mk_add_options MOZ_OBJDIR=\"$objdir\"

ac_add_options --disable-installer
ac_add_options --disable-updater

ac_add_options --disable-tests
ac_add_options --disable-mochitests

ac_add_options --enable-jemalloc
ac_add_options --enable-optimize=\"$optflags\"

ac_add_options --x-libraries=/usr/lib
" > "$srcdir/.mozconfig"

	make -f client.mk build
	cd "$objdir"
	make package
}

upload_file_zippyshare () {
	if ! curl -sLfc "$cookiejar" "$homepage_url" -A "$useragent" -o "$homepage_file"; then
		echo "Failed to retrieve homepage."
		return 1
	fi

	upload_url="$(grep -Eo 'http://www[0-9]+\.zippyshare\.com/upload' "$homepage_file")"

	if ! [[ $upload_url =~ ^http://www[0-9]+\.zippyshare\.com/upload$ ]]; then
		echo "The upload destination could not be determined!"
		return 1
	fi

	csrf_token="$(grep -Eo "uploadId *= *'[A-Za-z0-9]+'" "$homepage_file" | tr -d "' ")"

	if ! [[ $csrf_token =~ ^uploadId=[A-Za-z0-9]+$ ]]; then
		echo "The CSRF token could not be determined!"
		return 1
	fi

	if ! curl -sLfb "$cookiejar" -F "file_upload=@$file" -F "$csrf_token" "$upload_url" -A "$useragent" -o "$response_file"; then
		echo "Failed to upload file."
		return 1
	fi

	file_url="$(grep -Eio 'http://www[0-9]+\.zippyshare\.com/.*/file\.html' "$response_file" | head -n 1)"

	if ! [[ $file_url =~ ^http://www[0-9]+\.zippyshare\.com/.*/file\.html$ ]]; then
		echo "The URL to which the file was uploaded could not be determined."
		return 1
	fi
}

upload_file_devhost () {
	if ! curl -sLf "$homepage_url" -A "$useragent" -o "$homepage_file"; then
		echo "Failed to retrieve homepage."
		return 1
	fi

	upload_url="$(grep -Eo 'http://[a-z0-9.-]+\.d-h\.st/upload\?[A-Za-z0-9_-]+=[A-Za-z0-9]+' "$homepage_file")"

	if ! [[ $upload_url =~ ^http://[a-z0-9.-]+\.d-h\.st/upload\?[A-Za-z0-9_-]+=[A-Za-z0-9]+$ ]]; then
		echo "The upload destination could not be determined!"
		return 1
	fi

	upload_id="$(echo "$upload_url" | grep -Eo '[A-Za-z0-9]+$')"

	if ! [[ $upload_id =~ ^[A-Za-z0-9]+$ ]]; then
		echo "The upload ID could not be determined!"
		return 1
	fi

	if ! curl -sLf -F "UPLOAD_IDENTIFIER=$upload_id" -F "action=upload" -F "uploadfolder=0" -F "public=0" -F "user_id=0" -F "files[]=@$file" -F "file_description=" "$upload_url" -A "$useragent" -o "$response_file"; then
		echo "Failed to upload file."
		return 1
	fi

	file_url="$(grep -Eio 'http:\\/\\/d-h.st\\/[A-Za-z0-9-]+' "$response_file" | tr -d '\\')"

	if ! [[ $file_url =~ ^http://d-h.st/[A-Za-z0-9-]+$ ]]; then
		echo "The URL to which the file was uploaded could not be determined."
		return 1
	fi
}

upload_file () {
	set +e

	file="$(readlink -e "$2")"

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
	homepage_file="$tmpdir/uploadservice.homepage"
	response_file="$tmpdir/uploadservice.response"

	case "$1" in
		zippyshare)
			homepage_url="http://zippyshare.com/sites/index_old.jsp"
			;;
		devhost)
			homepage_url="http://d-h.st/"
			;;
		*)
			echo "Upload requested for unknown service, ignoring..."
			return 0
	esac

	if upload_file_$1 "$file"; then
		echo "$file [SHA256: $(sha256sum "$file" | grep -Eo "^[a-f0-9]+")] uploaded to $file_url"
	fi
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
	echo -n "Started job $1 "

	# Keep Travis-CI from killing the build process, by writing something to the screen.
	while kill -0 $ps_pid &>/dev/null; do
		echo -n '.'
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
		build_palemoon
		;;
	upload_build)
		upload_file zippyshare "$objdir"/dist/palemoon-*.tar.bz2
		;;
	*)
		echo "Unknown job type: $1"
		exit 2
esac
