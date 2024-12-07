```
das zweite  bash script 'unpack' am besten nach /usr/local/bin/ packen und dann kann es in einem Verzeichnis aufrufen, in dem man sich gerade befindet und dort Archive liegen (*.zip;*.rar;*.001;*.7z)
im scrkpt hardgecoded findet ihr einen verweis zu einem passwortfile, welches das script durchgeht um das passwort für das zu entpackende Archiv zu entschlüsseln.

+´Klappt richtig gut ;)+

Bei Fragen gerne melden! :D
```

GREAT tool, if you have like 100 (or more? ;-) files to extract and some of them are with a password.

for me the original script was too slow inbetween (on  a Mac) the extraction so that i modified it to just 
search for the next level with the find switch: -maxdepth 2, like this:

```
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
       # Remove or adjust the following debug statement if needed for clearer separation
       #[ $VERBOSE -eq 1 ] && message info "Running GNU find command: ${FIND} \"$1\" -depth -maxdepth 2 -regextype posix-egrep \"${args[@]}\""
       ${FIND} "$1" -depth -maxdepth 2 -regextype posix-egrep "${args[@]}"
     }
   else
     # Assume BSD/macOS find
     [ $VERBOSE -eq 1 ] && message info "Detected BSD find"
     function find_wrapper() {
       args=("$@")
       unset args[0]
       # Remove or adjust the following debug statement if needed for clearer separation
       #[ $VERBOSE -eq 1 ] && message info "Running BSD find command: ${FIND} -E \"$1\" -depth -maxdepth 2 \"${args[@]}\""
       ${FIND} -E "$1" -depth -maxdepth 2 "${args[@]}"
     }
   fi
   [ $VERBOSE -eq 1 ] && message info "Using find: ${FIND}"
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
