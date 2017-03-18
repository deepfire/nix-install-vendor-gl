#!/bin/sh
# (c) 2017 Косырев Сергей <_deepfire@feelingofgreen.ru>
#
# Credits:  the original investigation of the issue is due to:
#             clever @ #nixos, https://github.com/cleverca22
#
# To add a new driver stack, the following 6 functions need to be modified:
#
#  compute_system_vendorgl_kind,  compute_system_vendorgl_version,
#  nix_vendorgl_attribute,  nix_vendorgl_version_get_attribute_name,
#  nix_vendorgl_package_compute_url, nix_vendorgl_package_name
#

explain() {
	cat <<EOF

'nix-install-vendor-gl.sh'

  Ensure that a system-compatible OpenGL driver
  is available for nix-shell-encapsulated programs.

 * Why:

  When one uses Nix to run Nix-encapsulated OpenGL software on non-NixOS, it's
  not unlikely to encounter a similarly-looking error:

    [nix-shell:~/src/reflex-glfw]$ dist/build/reflex-glfw-demo/reflex-glfw-demo
    libGL error: unable to load driver: swrast_dri.so
    libGL error: failed to load driver: swrast

  This happens because nix isolates your program from the system, which implies
  a purposeful ignorance of your host GL libraries.

  However, these /particular/ host GL libraries are essential for your program to
  be able to talk to your X server.

  The issue is well-known:

    https://github.com/NixOS/nixpkgs/issues/9415

  So, it's a fairly fundamental conflict, and one solution is to supply a
  sufficiently matching version of GL libraries (yes, that means your nVidia drivers)
  using Nix itself.

  Thankfully, it's not impossible -- this script attempts to be a proof.

EOF
}

###
### Argument defaults
###
default_operation='install-vendor-gl'
run_opengl_driver='/run/opengl-driver'

arg_system_glxinfo='/usr/bin/glxinfo'
arg_nix_glxinfo=${HOME}'/.nix-profile/bin/glxinfo'
arg_nix_vendorgl_attr=
arg_nixpkgs=
arg_dump_and_exit=
arg_verbose=

usage() {
	test $# -ge 1 && { errormsg "$*"; echo >&2; }

	cat <<EOF
  Usage:
    $0 OPTIONS* [OP]

  Context-less operations:

    examine                 Provide an analysis of the system GL libraries
    install-vendor-gl       Ensure that vendor OpenGL libraries are available
                            for Nix applications.
			      This is the default mode of operation.

  Options:

    --nixpkgs PATH          Path to Nixpkgs used by the 'nix-shell' of interest.
                              Default is:  '`nix-instantiate --find-file nixpkgs`'
    --nix-vendor-gl-attr ATTR
                            Nixpkgs attribute path of the vendor GL drivers
                              Defaults are verndor specific, but look like
                              `linuxPackages.nvidia_x11`
    --system-glxinfo PATH   Path to system 'glxinfo'.
                              Default (often good) is:  '${arg_system_glxinfo}'
    --nix-glxinfo PATH      Path to nix-installed 'glxinfo'.
                              Default (rarely bad) is:  '${arg_nix_glxinfo}'

  Debug:

    --dump                  Dump internal variables & exit
    --explain               Explain why this program
    --help                  This.
    --verbose               Verbose operation

EOF
}
info() {
    ${echoe} "INFO: $*" >&2; }
warn() {
    ${echoe} "WARNING: $*" >&2; }
errormsg() {
    ${echoe} "\nFATAL: $*\n" >&2; }
fail() {
    errormsg "$*"
    exit 1; }

alias arg='test $# -ge 1 || usage "missing value for"'
alias argnz='test $# -ge 1 || usage "empty value for"'
alias argnzd='test $# -ge 1 -a -d "$1" || usage "missing directory for"'
alias argnzf='test $# -ge 1 -a -f "$1" || usage "missing file for"'

## Portability:
##
if test -z "${BASH_VERSION}"
then echoe='echo'
else echoe='echo -e'; fi
has_which=
has_typeP=
if test `which /bin/sh` = "/bin/sh"
then has_which=t
elif test `type -P /bin/sh` = "/bin/sh"
then has_typeP=t; fi
resolve_execname() {
	if   test ! -z "${has_which}"
	then which $1
	elif test ! -z "${has_typeP}"
	then type -P $1
	else fail "Broken system: location of executables by name is too hard."; fi; }

###
###
set -ue ## Undefined hardcore. 2017 programming at its best.
while test $# -ge 1
do
    case "$1"
    in
	--nixpkgs )                       arg_nixpkgs=$2; shift;;
	--nix-vendor-gl-attr )  arg_nix_vendorgl_attr=$2; shift;;
	--nix-glxinfo )               arg_nix_glxinfo=$2; shift;;
	--system-glxinfo )         arg_system_glxinfo=$2; shift;;
	###
	--cls )                                  echo -ne "\033c";;
	--verbose )                       arg_verbose='t';;
        --dump )                    arg_dump_and_exit='t';;
        --explain )                           explain; exit 0;;
        --help )                                usage; exit 0;;
        "--"* )                                 usage "unknown option: $1"; exit 1;;
        * ) break;; esac
    shift; done
test -z "${arg_verbose}" || set -x

### Pre-main: establish preconditions & precomputations.
###
### Locate nix and nixpkgs
      nix_build=`resolve_execname nix-build`
nix_instantiate=`resolve_execname nix-instantiate`
if test -z "${arg_nixpkgs}"
then arg_nixpkgs=`nix-instantiate --find-file nixpkgs`
fi
nix_eval() {
	NIX_PATH=nixpkgs=${arg_nixpkgs} ${nix_instantiate} --eval --expr "with import <nixpkgs> {}; $1" | sed 's/^"\(.*\)"$/\1/'; }
if test -z `nix_eval lib.nixpkgsVersion`
then fail "the nixpkgs supplied at '${arg_nixpkgs}' fail the sanity check."
fi

test -x "${nix_build}" ||
	fail "Couldn't find nix-build.  Seems like Nix is not installed:  run $0 --explain"
test -x "${nix_instantiate}" ||
	fail "Couldn't find nix-instantiate.  Seems like Nix is not installed:  run $0 --explain"

### Locate both system and nix glxinfo's
test -x "${arg_system_glxinfo}" ||
	fail "Couldn't find system glxinfo executable at '${arg_system_glxinfo}'.  Please provide one via --system-glxinfo"
test -x "${arg_nix_glxinfo}" ||
	{ warn "Couldn't find nix-installed glxinfo executable at '${arg_nix_glxinfo}'."
	  suggested_action="nix-env --no-build-output --install glxinfo"
	  cat <<EOF
I suggest we install one now, using '${suggested_action}'.

That's what we're gonna run, together, if you agree.

This is a great decision -- of course -- the choice is yours.
EOF
	  echo -n "[Y/n] ? "
	  read ans
	  failure=""
	  if test "${ans}" = "Y" -o "${ans}" = "y" -o "${ans}" = ""
	  then
		  ${suggested_action}
		  if test $? != 0
		  then failure="the script failed an attempt to fix that with execution of '${suggested_action}'"; fi
	  else failure="the user refused to install it"; fi
	  test -z "${failure}" ||
		  fail "Couldn't find nix-provided glxinfo at '${arg_nix_glxinfo}',\nand ${failure} => diagnostics impossible."; }

glxinfo_field() {
	$1 2>/dev/null | grep "^$2: " | cut -d ':' -f2 | cut -d ' ' -f2- || true; }

### query Nix 'glxinfo'
nix_vendorgl_server_string=`glxinfo_field ${arg_nix_glxinfo} 'server glx vendor string'`
nix_vendorgl_client_string=`glxinfo_field ${arg_nix_glxinfo} 'client glx vendor string'`
 nix_opengl_version_string=`glxinfo_field ${arg_nix_glxinfo} 'OpenGL version string'`
         nix_opengl_broken=`${arg_nix_glxinfo} >/dev/null 2>&1 && echo no || echo yes`

### query system 'glxinfo'
system_glxinfo_deplib_path() {
	ldd ${arg_system_glxinfo} | grep "^[[:space:]]*$1 => " | cut -d ' ' -f3; }
   system_vendorgl_server_string=`glxinfo_field ${arg_system_glxinfo} 'server glx vendor string'`
   system_vendorgl_client_string=`glxinfo_field ${arg_system_glxinfo} 'client glx vendor string'`
  system_vendorgl_version_string=`glxinfo_field ${arg_system_glxinfo} 'OpenGL version string'`
              system_libgl1_path=`system_glxinfo_deplib_path 'libGL.so.1'`
          system_vendorgl_broken=`${arg_system_glxinfo} >/dev/null 2>&1 && echo no || echo yes`
compute_system_vendorgl_kind() {
	case "${system_vendorgl_client_string}" in
	     "NVIDIA Corporation" ) echo "nvidia";;
	     "AMD Corporation" )    echo "amd";;
	     "Intel Corporation" )  echo "intel";;
	     "*" )                  echo "unknown";; esac; }
          system_vendorgl_kind=`compute_system_vendorgl_kind`
   compute_system_vendorgl_version() {
	   case $system_vendorgl_kind in
		   nvidia ) echo ${system_vendorgl_version_string} | cut -d ' ' -f3;; esac; }
       system_vendorgl_version=`compute_system_vendorgl_version`

dump() {
     cat <<EOF
--------------------------------- Dumping internal variables:
nix-build:                        ${nix_build}
arg_nixpkgs:                      ${arg_nixpkgs}
arg_system_glxinfo:               ${arg_system_glxinfo}
arg_nix_glxinfo:                  ${arg_nix_glxinfo}

server GLX vendor:                ${system_vendorgl_server_string}
client GLX vendor:                ${system_vendorgl_client_string}
system GL version string:         ${system_vendorgl_version_string}
system GL broken:                 ${system_vendorgl_broken}
system GL kind:                   ${system_vendorgl_kind}
system GL version number:         ${system_vendorgl_version}

system libGL.so.1:                ${system_libgl1_path}
system libGL.so.1 dependencies:
$(ldd ${system_libgl1_path})

Default Nix GL vendor:            ${nix_vendorgl_client_string}
Default Nix GL version:           ${nix_opengl_version_string}
Default Nix GL broken:            ${nix_opengl_broken}
EOF
}
if test ! -z "${arg_verbose}${arg_dump_and_exit}"
then dump
     if test ! -z "${arg_dump_and_exit}"
     then return 0; fi; fi

### Main functionality.
###
if test $# -ge 1
then argnz "OPERATION"; operation=$1; shift
else operation=${default_operation}; fi

test "${nix_opengl_broken}" = "yes" -o "${operation}" == "examine" || {
	info "Nix-available GL seems to be okay (according to glxinfo exit status)."
	return 0; }
test ! -f ${run_opengl_driver}/lib/libGL.so.1 -o "${operation}" == "examine" ||
	! (LD_LIBRARY_PATH=${run_opengl_driver}/lib ${arg_nix_glxinfo} >/dev/null 2>&1) || {
	info "A global libGL.so.1 already seems to be installed at\n${run_opengl_driver}/lib/libGL.so.1, and it appears to be sufficient for\nthe Nix 'glxinfo'.\n\n  export LD_LIBRARY_PATH=${run_opengl_driver}/lib\n"
	export LD_LIBRARY_PATH=${run_opengl_driver}/lib
	return 0; }

test "${system_vendorgl_broken}" = "no" || {
	${arg_system_glxinfo}
	fail "System-wide GL appear to be broken (according to glxinfo exit status),\nnot much can be done."; }
# test -f "${system_libgl1_path}" ||
# 	fail "Couldn't find system libGL.so.1.  Please, report a bug."

vendorgl=`compute_system_vendorgl_kind`
case ${vendorgl} in
       nvidia ) true;;
       * )      fail "unsupported GL vendor: ${vendorgl} (vendor string '${system_vendorgl_client_string}')";; esac

##
## The rest of code assumes valid values of ${vendorgl}.
##
### 1. vendor-specific derivation attribute
nix_vendorgl_attribute() {
	if test ! -z "${arg_nix_vendorgl_attr}"
	then vendorgl_attribute=${arg_nix_vendorgl_attr}
	else case ${vendorgl} in
		     nvidia ) echo 'linuxPackages.nvidia_x11';; esac; fi; }
vendorgl_attribute=`nix_vendorgl_attribute`

### 2. vendor-specific version attribute
nix_vendorgl_version_get_attribute_name() {
        case ${vendorgl} in
		nvidia ) echo 'if builtins.hasAttr "version" '${vendorgl_attribute}' then '${vendorgl_attribute}'.version else '${vendorgl_attribute}'.versionNumber';; esac; }

### 3. vendor GL version
nix_vendorgl_get_driver_version() {
	nix_eval "`nix_vendorgl_version_get_attribute_name`"; }
nix_vendorgl_driver_version=`nix_vendorgl_get_driver_version`
if test -z "${nix_vendorgl_driver_version}"
then fail "Nix vendor GL attribute ${vendorgl_attribute} is wrong, please supply a better one using --nix-vendor-gl-attr"
fi

system_vendorgl_matches_nix_vendorgl() {
        test "${system_vendorgl_version}" = ${nix_vendorgl_driver_version} &&
		echo yes || echo no; }

### 4. vendor GL package URL
nix_vendorgl_package_compute_url() {
        case ${vendorgl} in
		nvidia ) echo "http://download.nvidia.com/XFree86/Linux-x86_64/${system_vendorgl_version}/NVIDIA-Linux-x86_64-${system_vendorgl_version}.run";; esac; }
nix_vendorgl_package_url="`nix_vendorgl_package_compute_url`"

### 5. vendor GL Nix package name
nix_vendorgl_package_name() {
        case ${vendorgl} in
		nvidia ) echo "nvidia-x11-${system_vendorgl_version}-\${pkgs.linuxPackages.kernel.version}";; esac; }

### Main & toplevel command dispatch
###
case ${operation} in
examine )
	dump
	cat <<EOF
--------------------------------- General system info:
$(lsb_release -a 2>&1)
--------------------------------- System GL:
System GL vendor string:          ${system_vendorgl_client_string}
System GL vendor kind:            ${vendorgl}
System GL vendor driver version:  ${system_vendorgl_version}
Vendor GL package URL:            $(nix_vendorgl_package_compute_url)
Vengor GL Nix package name:       $(nix_vendorgl_package_name)
--------------------------------- Nix:
Nix version:                      $(nix-env --version)
Nixpkgs:                          ${arg_nixpkgs}
Nixpkgs ver:                      $(nix_eval lib.nixpkgsVersion)
Nix GL vendor driver version:     ${nix_vendorgl_driver_version}
---------------------------------
Sys vendor GL = Nix vendor GL:    $(system_vendorgl_matches_nix_vendorgl)
EOF
	;;

install-vendor-gl )
	tmpnix=`mktemp`
	if test "`NIX_PATH=${NIX_PATH}:nixpkgs-overlays=/tmp/overlay; system_vendorgl_matches_nix_vendorgl`" != 'yes'
	then
		info "The version of the vendor driver in nixpkgs:  ${nix_vendorgl_driver_version}\ndoesn't match the system vendor driver version:     ${system_vendorgl_version}\n..so a semi-automated vendor GL package download is required.\n"
		nix_vendorgl_package_sha256=`nix-prefetch-url --type sha256 ${nix_vendorgl_package_url}`
		cat >${tmpnix} <<EOF
with import <nixpkgs> {};
let vendorgl = (${vendorgl_attribute}.override {
      libsOnly = true;
      kernel   = null;
    }).overrideAttrs (oldAttrs: rec {
      name = "$(nix_vendorgl_package_name)";
      src = fetchurl {
        url = "${nix_vendorgl_package_url}";
        sha256 = "${nix_vendorgl_package_sha256}";
      };
    });
in buildEnv { name = "opengl-drivers"; paths = [ vendorgl ]; }
EOF
	else
		cat >${tmpnix} <<EOF
with import <nixpkgs> {};
let vendorgl = ${vendorgl_attribute}.override {
      libsOnly = true;
      kernel   = null;
    };
in buildEnv { name = "opengl-drivers"; paths = [ vendorgl ]; }
EOF
	fi

	sudo NIX_PATH=nixpkgs=${arg_nixpkgs} ${nix_build} ${tmpnix} -o ${run_opengl_driver}
	rm -f ${tmpnix}

	cat <<EOF
Nix-compatible vendor GL driver is now installed at ${run_opengl_driver}

To make them available to Nix-build applications you can now issue:

   export LD_LIBRARY_PATH=${run_opengl_driver}/lib

(Doing the export, in case you have sourced the file directly.)
EOF
	export LD_LIBRARY_PATH=${run_opengl_driver}/lib
	;; esac

## Undo the set -eu.  XXX:  what some of that was set before us?  Ah, SHell programming..
set +eu
