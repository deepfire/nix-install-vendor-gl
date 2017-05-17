#!/bin/sh
# (c) 2017 Косырев Сергей <_deepfire@feelingofgreen.ru>
#
# Credits:  the original investigation of the issue is due to:
#             clever @ #nixos, https://github.com/cleverca22
#
# To add a new driver stack, the following 6 functions need to be modified:
#
#  compute_system_vendorgl_kind,  compute_system_vendorgl_version,
#  nixpkgs_vendorgl_attribute,  nixpkgs_vendorgl_version_get_attribute_name,
#  nixpkgs_vendorgl_package_id, nixpkgs_vendorgl_package_name,
#  vendorgl_package_compute_url
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
run_opengl_driver_drvref='/tmp/run-opengl-driver.drv'
cachedir="${XDG_CACHE_DIR:-${HOME}/.cache}/nix-install-vendor-gl"
fix_attempted=
vendorgl_deriv_log=

arg_system_glxinfo='/usr/bin/glxinfo'
arg_nix_glxinfo=${HOME}'/.nix-profile/bin/glxinfo'
arg_nixpkgs_vendorgl_attr=
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
                              'linuxPackages.nvidia_x11'
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
DEBUG=
debug() {
    if test "${DEBUG}"; then echo "$*" >&2; fi; }
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
then echoe='echo';    debug "escape-aware echo is 'echo'";
else echoe='echo -e'; debug "escape-aware echo is 'echo -e'"; fi
has_which=
has_typeP=
if test `which /bin/sh` = "/bin/sh"
then has_which=t;     debug "PATH-locator is 'which'";
elif test `type -P /bin/sh` = "/bin/sh"
then has_typeP=t;     debug "PATH-locator is 'type -P'"; fi
resolve_execname() {
	# Fail lazily -- only when we really need to execute something.
	if   test ! -z "${has_which}"
	then which $1 || true
	elif test ! -z "${has_typeP}"
	then type -P $1 || true
	else fail "Broken system: location of executables by name is too hard."; fi; }

###
###
set -u -e ## Undefined hardcore. 2017 programming at its best.

while test $# -ge 1
do
    case "$1"
    in
	--nixpkgs )                       arg_nixpkgs=$2; shift;;
	--nix-vendor-gl-attr )  arg_nixpkgs_vendorgl_attr=$2; shift;;
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

nix_eval() {
	NIX_PATH=nixpkgs=${arg_nixpkgs} ${nix_instantiate} --eval --expr "with import <nixpkgs> { config = { allowUnfree = true; }; }; $1" | sed 's/^"\(.*\)"$/\1/'; }

glxinfo_field() {
	$1 2>/dev/null | grep "^$2: "     | cut -d ':' -f2 | cut -d ' ' -f2- || true; }
glxinfo_query_renderer_field() {
	$1 2>/dev/null | grep "^    $2: " | cut -d ':' -f2 | cut -d ' ' -f2- || true; }

system_glxinfo_deplib_path() {
	ldd ${arg_system_glxinfo} | grep "^[[:space:]]*$1 => " | cut -d ' ' -f3; }

###
### The aspiring GPU driver portability layer
###
compute_system_vendorgl_kind() {
    if test "${nix_mesagl_vendor}" = "X.Org"
    then case "${nix_mesagl_device}" in
	     'AMD' )                echo 'amd-mesa';;
	     * )                    echo 'unknown';; esac
    else case "${system_vendorgl_client_string}" in
	     'NVIDIA Corporation' ) echo 'nvidia';;
	     'AMD Corporation' )    echo 'amd';;
	     'Intel Corporation' )  echo 'intel';;
	     * )                    echo 'unknown';; esac; fi; }

validate_system_vendorgl_kind() {
        case ${vendorgl} in
                nvidia ) true;;
                * )      fail "unsupported GL vendor: ${vendorgl} (vendor string '${system_vendorgl_client_string}')";; esac
}

compute_system_vendorgl_version() {
        case ${vendorgl} in
	        amd-mesa ) echo ${nix_mesagl_version};;
	        nvidia   ) echo ${system_vendorgl_version_string} | cut -d ' ' -f3;; esac; }

nix_glxinfo_libgl_path() {
        ldd ${arg_nix_glxinfo} 2>/dev/null | grep 'libGL\.so\.1' | cut -d'>' -f2 | cut -d' ' -f2 | xargs realpath -e 2>/dev/null | xargs dirname || true; }

nix_opengl_state() {
        local stderr="`${arg_nix_glxinfo} 2>&1 >/dev/null || true`"
        if   test -n "$stderr"
        then echo "broken"
        elif test "$(nix_glxinfo_libgl_path)" = "$(realpath -e ${run_opengl_driver}/lib 2>/dev/null || true)";
        then echo "ok, fixed"
        elif true
        then echo "ok, unknown reason"
        fi; }

nixpkgs_vendorgl_attribute() {
	if test ! -z "${arg_nixpkgs_vendorgl_attr}"
	then vendorgl_attribute=${arg_nixpkgs_vendorgl_attr}
	else case ${vendorgl} in
		     nvidia ) echo 'linuxPackages.nvidia_x11';; esac; fi; }

nixpkgs_vendorgl_version_get_attribute_name() {
        case ${vendorgl} in
		nvidia ) echo 'if builtins.hasAttr "version" '${vendorgl_attribute}' then '${vendorgl_attribute}'.version else '${vendorgl_attribute}'.versionNumber';; esac; }

vendorgl_package_compute_url() {
	case ${vendorgl} in
		nvidia ) echo "http://download.nvidia.com/XFree86/Linux-x86_64/${system_vendorgl_version}/NVIDIA-Linux-x86_64-${system_vendorgl_version}.run";; esac; }

nixpkgs_vendorgl_package_id() {
	case ${vendorgl} in
		nvidia ) echo "nvidia-x11";; esac; }

nixpkgs_vendorgl_package_name() {
	case ${vendorgl} in
		nvidia ) echo "nvidia-x11-${system_vendorgl_version}-\${pkgs.linuxPackages.kernel.version}";; esac; }

###
###
nixpkgs_vendorgl_version() {
	nix_eval "`nixpkgs_vendorgl_version_get_attribute_name`"; }

system_vendorgl_matches_nixpkgs_vendorgl() {
	test "${system_vendorgl_version}" = ${nixpkgs_vendorgl_driver_version} &&
		echo yes || echo no; }

dump_internal_vars() {
     cat <<EOF
nix-build:                        ${nix_build}
arg_nixpkgs:                      ${arg_nixpkgs}
arg_system_glxinfo:               ${arg_system_glxinfo}
arg_nix_glxinfo:                  ${arg_nix_glxinfo}

MESA_query_renderer vendor:       ${nix_mesagl_vendor}
MESA_query_renderer device:       ${nix_mesagl_device}
MESA_query_renderer drv version:  ${nix_mesagl_version}

server GLX vendor:                ${system_vendorgl_server_string}
client GLX vendor:                ${system_vendorgl_client_string}
system GL version string:         ${system_vendorgl_version_string}
system GL broken:                 ${system_vendorgl_broken}
system GL kind:                   ${vendorgl}
system GL version number:         ${system_vendorgl_version}

system libGL.so.1:                ${system_libgl1_path}
system libGL.so.1 dependencies:
$(ldd ${system_libgl1_path})

Default Nix GL vendor:            ${nix_vendorgl_client_string}
Default Nix GL version:           ${nix_opengl_version_string}
Nix GL state:                     $(nix_opengl_state)
EOF
}

examine() {
        local state="$(nix_opengl_state)"
	dump_internal_vars
	cat <<EOF
--------------------------------- General system info:
$(lsb_release -a 2>&1)
--------------------------------- Nix 'glxinfo' linkage:
$(ldd ${arg_nix_glxinfo} || true)
--------------------------------- ${run_opengl_driver}/lib:
EOF
        ls -l ${run_opengl_driver}/lib || true
        ls ${run_opengl_driver}/lib/ || true
	cat <<EOF
Has libGL.so.1:                   $(realpath -e ${run_opengl_driver}/lib/libGL.so.1 2>&1 || true)
--------------------------------- 'glxinfo' stderr:
EOF
	${arg_nix_glxinfo} 2>&1 >/dev/null || true
        if test -n "${fix_attempted}"
        then
                cat <<EOF
--------------------------------- Attempted fix traces:
Vendor GL derivation:             ${vendorgl_deriv}
Date:                             $(date)
Vendor GL log:                    ${vendorgl_deriv_log}
EOF
                bzcat ${vendorgl_deriv_log}
        fi
        cat <<EOF
--------------------------------- System GL:
System kernel version		  ${system_kernel_version}
System GL vendor string:	  ${system_vendorgl_client_string}
System GL vendor kind:		  ${vendorgl}
System GL vendor driver version:  ${system_vendorgl_version}
Vendor GL Nix attribute:	  ${vendorgl_attribute}
Vendor GL package URL:		  $(vendorgl_package_compute_url)
Vengor GL Nix package name:	  $(nixpkgs_vendorgl_package_name)
--------------------------------- Nix:
Nix kernel version:		  ${nix_kernel_version}
Nix version:			  $(nix-env --version)
Nixpkgs:			  ${arg_nixpkgs}
Nixpkgs ver:			  $(nix_eval lib.nixpkgsVersion)
Nix default GL driver version:	  ${nixpkgs_vendorgl_driver_version}
Nix glxinfo libGL path:           $(nix_glxinfo_libgl_path)
${run_opengl_driver}/lib is:        $(realpath -e ${run_opengl_driver}/lib 2>/dev/null || true)
LD_LIBRARY_PATH:                  $LD_LIBRARY_PATH
---------------------------------
Sys vend. GL = Nixpkgs vend. GL:  $(system_vendorgl_matches_nixpkgs_vendorgl)
Nix GL state:                     ${state}
EOF
}

main() {
        ### Establish preconditions & precomputations.
        ###
        ### Locate nix and nixpkgs

	nix_build=`resolve_execname nix-build`
        test -x "${nix_build}" ||
	        fail "Couldn't find nix-build.	Seems like Nix is not installed:  run $0 --explain"

	nix_instantiate=`resolve_execname nix-instantiate`
        test -x "${nix_instantiate}" ||
	        fail "Couldn't find nix-instantiate.  Seems like Nix is not installed:	run $0 --explain"

        if test -z "${arg_nixpkgs}"
        then arg_nixpkgs=`nix-instantiate --find-file nixpkgs`
        fi
        if test -z `nix_eval lib.nixpkgsVersion`
        then fail "the nixpkgs supplied at '${arg_nixpkgs}' fail the sanity check."
        fi

        ### Obtain kernel version info
        nix_kernel_version=`nix_eval linuxPackages.kernel.version`
        system_kernel_version=`uname -r | cut -d- -f1`

        ### Locate both system and nix glxinfo's
        test -x "${arg_system_glxinfo}" ||
	        cat <<EOF
Couldn't find system glxinfo executable at '${arg_system_glxinfo}'.
Please, either install it:

  Fedora:  dnf install glx-utils
  Ubuntu:  apt install mesa-utils

..or provide via --system-glxinfo.
EOF
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
	          if test "${ans}" = "Y" || test "${ans}" = "y" || test "${ans}" = ""
	          then
		          ${suggested_action}
		          if test $? != 0
		          then failure="the script failed an attempt to fix that with execution of '${suggested_action}'"; fi
	          else failure="the user refused to install it"; fi
	          test -z "${failure}" ||
		          fail "Couldn't find nix-provided glxinfo at '${arg_nix_glxinfo}',\nand ${failure} => diagnostics impossible."; }

        ### query Nix 'glxinfo'
        nix_mesagl_vendor=`glxinfo_query_renderer_field ${arg_system_glxinfo} 'Vendor'  | cut -d' ' -f1`
        nix_mesagl_device=`glxinfo_query_renderer_field ${arg_system_glxinfo} 'Device'  | cut -d' ' -f1`
        nix_mesagl_version=`glxinfo_query_renderer_field ${arg_system_glxinfo} 'Version' | cut -d' ' -f1`

        nix_vendorgl_server_string=`glxinfo_field ${arg_nix_glxinfo} 'server glx vendor string'`
        nix_vendorgl_client_string=`glxinfo_field ${arg_nix_glxinfo} 'client glx vendor string'`
        nix_opengl_version_string=`glxinfo_field ${arg_nix_glxinfo} 'OpenGL version string'`

        ### query system 'glxinfo'
        system_vendorgl_server_string=`glxinfo_field ${arg_system_glxinfo} 'server glx vendor string'`
        system_vendorgl_client_string=`glxinfo_field ${arg_system_glxinfo} 'client glx vendor string'`
        system_vendorgl_version_string=`glxinfo_field ${arg_system_glxinfo} 'OpenGL version string'`
        system_libgl1_path=`system_glxinfo_deplib_path 'libGL.so.1'`
        system_vendorgl_broken=`${arg_system_glxinfo} >/dev/null 2>&1 && echo no || echo yes`
        vendorgl=`compute_system_vendorgl_kind`
        system_vendorgl_version=`compute_system_vendorgl_version`

        if test ! -z "${arg_verbose}${arg_dump_and_exit}"
        then dump_internal_vars
             if test ! -z "${arg_dump_and_exit}"
             then return 0; fi; fi

        ### Main functionality.
        ###
        if test $# -ge 1
        then argnz "OPERATION"; operation=$1; shift
        else   operation=${default_operation}; fi
        case ${operation} in
                examine | install-vendor-gl );;
                * ) fail 'Unknown operation: '${operation};; esac

        test "$(nix_opengl_state)" = "broken" || test "${operation}" = "examine" || {
	                info "Nix-available GL seems to be okay (according to glxinfo exit status)."
	                return 0; }
        test ! -f ${run_opengl_driver}/lib/libGL.so.1 || test "${operation}" = "examine" ||
	        ! (LD_LIBRARY_PATH=${run_opengl_driver}/lib ${arg_nix_glxinfo} >/dev/null 2>&1) || {
	                info "libGL.so.1 already seems to be installed at\n${run_opengl_driver}/lib/libGL.so.1, and it appears to be sufficient for\nthe Nix 'glxinfo'.\n\n  export LD_LIBRARY_PATH=${run_opengl_driver}/lib\n"
	                export LD_LIBRARY_PATH=${run_opengl_driver}/lib
	                return 0; }

        test "${system_vendorgl_broken}" = "no" || {
	        ${arg_system_glxinfo}
	        fail "System-wide GL appear to be broken (according to glxinfo exit status),\nnot much can be done."; }

        validate_system_vendorgl_kind

        ## The rest of code assumes valid values of ${vendorgl}.
        ##
        vendorgl_attribute=`nixpkgs_vendorgl_attribute`

        nixpkgs_vendorgl_driver_version=`nixpkgs_vendorgl_version`
        if test -z "${nixpkgs_vendorgl_driver_version}"
        then fail "Nix vendor GL attribute ${vendorgl_attribute} is wrong, please supply a better one using --nix-vendor-gl-attr"
        fi

        vendorgl_package_url="`vendorgl_package_compute_url`"


        ### Main & toplevel command dispatch
        ###
        case ${operation} in
        examine ) examine;;
        install-vendor-gl )
	        tmpnix=`mktemp`
	        if test "`NIX_PATH=${NIX_PATH}:nixpkgs-overlays=/tmp/overlay; system_vendorgl_matches_nixpkgs_vendorgl`" != 'yes'
	        then
	                info "The version of the vendor driver in nixpkgs:  ${nixpkgs_vendorgl_driver_version}\ndoesn't match the system vendor driver version:     ${system_vendorgl_version}\n..so a semi-automated vendor GL package installation is required.\n"
	                vendorgl_package_sha256_file="${cachedir}/${system_vendorgl_version}"
	                mkdir -p "${cachedir}"
	                vendorgl_package_sha256_cached="$(test ! -f ${vendorgl_package_sha256_file} || cat ${vendorgl_package_sha256_file})"
	                vendorgl_package_sha256=`nix-prefetch-url --type sha256 ${vendorgl_package_url} ${vendorgl_package_sha256_cached}`
	                echo -n "${vendorgl_package_sha256}" > "${vendorgl_package_sha256_file}"
	                cat >${tmpnix} <<EOF
with import <nixpkgs> { config = { allowUnfree = true; }; };
let vendorgl = (${vendorgl_attribute}.override {
      libsOnly = true;
      kernel   = null;
    }).overrideAttrs (oldAttrs: rec {
      name = "$(nixpkgs_vendorgl_package_name)";
      src = fetchurl {
	url = "${vendorgl_package_url}";
	sha256 = "${vendorgl_package_sha256}";
      };
      useGLVND = 0;
    });
in buildEnv { name = "opengl-drivers"; paths = [ vendorgl ]; }
EOF
	        else
                        info "Both the host system and Nix provide matching vendor GL driver versions."
		        cat >${tmpnix} <<EOF
with import <nixpkgs> { config = { allowUnfree = true; }; };
let vendorgl = ${vendorgl_attribute}.override {
      libsOnly = true;
      kernel   = null;
    };
in buildEnv { name = "opengl-drivers"; paths = [ vendorgl ]; }
EOF
	        fi

	        echo; echo "Installing the vendor driver into: ${run_opengl_driver}"
	        nix_build_options='--no-build-output --max-jobs 4 --cores 0'
	        # NIX_PATH=nixpkgs=${arg_nixpkgs} ${nix_build} ${nix_build_options} ${tmpnix} ${arg_verbose:+-v}
	        sudo NIX_PATH=nixpkgs=${arg_nixpkgs} ${nix_build} ${nix_build_options} ${tmpnix} ${arg_verbose:+-v} \
                     --out-link ${run_opengl_driver} \
                     --drv-link ${run_opengl_driver_drvref}
	        rm -f ${tmpnix}
                run_opengl_driver_drv=`realpath -e ${run_opengl_driver_drvref} || true`
                vendorgl_deriv=`nix-store --query --references ${run_opengl_driver_drv} | grep $(nixpkgs_vendorgl_package_id)`
                vendorgl_deriv_hash=`echo ${vendorgl_deriv} | cut -c12- | cut -d- -f1`
                vendorgl_deriv_log=`realpath /nix/var/log/nix/drvs/$(echo ${vendorgl_deriv_hash} | cut -c-2)/$(echo ${vendorgl_deriv_hash} | cut -c3-)-$(nixpkgs_vendorgl_package_id)-*`
                echo
                echo "GL driver derivation:      ${run_opengl_driver_drv}"
                echo "Vendor driver derivation:  ${vendorgl_deriv}"
                echo "Vendor driver build log:   ${vendorgl_deriv_log}"

		export LD_LIBRARY_PATH=${run_opengl_driver}/lib
                fix_attempted=true

	        case $(nix_opengl_state) in
	                "ok"* ) cat <<EOF

Nix-compatible vendor GL driver is now installed at ${run_opengl_driver}

To make them available to Nix-build applications you can now issue:

   export LD_LIBRARY_PATH=${run_opengl_driver}/lib

(Doing the export, in case you have sourced the file directly.)
EOF
	                     ;;
                        broken ) cat <<EOF

Nix-compatible vendor GL was installed at ${run_opengl_driver},

..yet, for some reason, Nix-provided 'glxinfo' is still broken.

Please, sumbit the output below '--- 8< ---', along with output of

   ./nix-install-vendor-gl.sh examine

as a bug report to:

   https://github.com/deepfire/nix-install-vendor-gl/issues

EOF
		echo '--------------------------- 8< ---------------------------'
                examine
		echo '--------------------------- 8< ---------------------------'
		cat <<EOF

Nix-compatible vendor GL was installed at ${run_opengl_driver},

..yet, for some reason, Nix-provided 'glxinfo' is still broken.

Please, sumbit the outpug above '--- 8< ---', along with output of

   ./nix-install-vendor-gl.sh examine

as a bug report to:

   https://github.com/deepfire/nix-install-vendor-gl/issues

EOF
		;;
	    * )
		fail "INTERNAL ERROR: unhandled output of 'nix_opengl_state': $(nix_opengl_state)";; esac;; esac
}

main "$@"
set +e +u
