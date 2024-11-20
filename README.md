GREAT tool, if you have like 100 (or more? ;-) files to extract and some of them are with a password.

for me the original script was too slow inbetween (on  a Mac) the extraction so that i modified it to just 
search for the next level with the find switch: -maxdepth 1, like this:

```
## Check FIND binary exists
#if ! type -P "${FIND}" > /dev/null 2>&1 ; then
#  message error "Cannot find the \"find\" binary (\"${FIND}\") in your path"
#  exit 1
#fi
#
## FIXME: Require -iregex support for now. We should try to teach the wrappers
## how to fall back to `-regex` or something...
#if [ "$(${FIND} /dev/null -iregex 'test' > /dev/null 2>&1 ; echo $?)" -ne "0" ]; then
#  message error "Your version of find (\"${FIND}\") does not support the \"-iregex\" flag"
#  exit 1
#fi
#
#if [ "X$(${FIND} --version >/dev/null 2>&1 ; echo $?)" == "X0" ]; then
#  # GNU find supports `--version`
#  [ $VERBOSE -eq 1 ] && message info "Detected GNU find"
#  function find_wrapper() {
#    if [ $# -lt 2 ]; then
#      message error "Invalid args to find_wrapper"
#      exit 1
#    fi
#    args=("$@")
#    unset args[0]
#    ${FIND} "$1" -regextype posix-egrep "${args[@]}"
#  }
#else
#  # Assume *BSD/macOS find
#  [ $VERBOSE -eq 1 ] && message info "Detected BSD find"
#  function find_wrapper() {
#    ${FIND} -E "$@" -maxdepth 1 "${@:2}"
#  }
#fi
#[ $VERBOSE -eq 1 ] && message info "Using find: ${FIND}"

if [ "X$(${FIND} --version >/dev/null 2>&1 ; echo $?)" == "X0" ]; then
  # GNU find supports `--version`
  [ $VERBOSE -eq 1 ] && message info "Detected GNU find"
  function find_wrapper() {
    if [ $# -lt 2 ]; then
      message error "Invalid args to find_wrapper"
      exit 1
    fi
    args=("$@")
    unset args[0]
    ${FIND} "$1" -maxdepth 1 -regextype posix-egrep "${args[@]}"
  }
else
  # Assume *BSD/macOS find
  [ $VERBOSE -eq 1 ] && message info "Detected BSD find"
  function find_wrapper() {
    ${FIND} -E "$1" -maxdepth 1 "${@:2}"
  }
fi
```

## unrarall

[![Build Status](https://travis-ci.org/arfoll/unrarall.svg?branch=master)](https://travis-ci.org/arfoll/unrarall)

unrarall attemps to extract all rar files in a given directory (and its
sub-directories) and once successfully extracted remove all the rar files to
cleanup (you must pass --clean= for this to happen and use the rar hook). Other
unwanted files can be removed by the use of the other available hooks (see the
list shown in --help ). It is meant to be more error proof and quicker than
cleaning by hand. You can also set an output folder, use different backends,
perform sfv checks automatically etc...

If there's something you would liked removed by unrarall then you can implement
your own hook (See HACKING).

## INSTALL

1. You just need to make sure you set execute permission on the script. This
   can be done using the following command:

```
chmod u+x unrarall
```

2. Place the script wherever you want it and rename it to whatever you want. I
   prefer unrarall.

## USAGE

Run unrarall with all cleanups on current directory
```
unrarall --clean=all .
```

Run with an output directory on the current directory
```
unrarall --output /tmp/mystuff .
```

Run unrarall -h to get the help for much more details.

Enjoy.

## ACKNOWLEDGEMENTS

Name and idea comes from "jeremy" see -
http://askubuntu.com/questions/7059/script-app-to-unrar-files-and-only-delete-the-archives-which-were-sucessfully

[![Analytics](https://ga-beacon.appspot.com/UA-11959363-2/arfoll/unrarall)](https://github.com/igrigorik/ga-beacon)
