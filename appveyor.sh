#!/usr/bin/env bash
#***************************************************************************
#                                  _   _ ____  _
#  Project                     ___| | | |  _ \| |
#                             / __| | | | |_) | |
#                            | (__| |_| |  _ <| |___
#                             \___|\___/|_| \_\_____|
#
# Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.
#
# This software is licensed as described in the file COPYING, which
# you should have received as part of this distribution. The terms
# are also available at https://curl.se/docs/copyright.html.
#
# You may opt to use, copy, modify, merge, publish, distribute and/or sell
# copies of the Software, and permit persons to whom the Software is
# furnished to do so, under the terms of the COPYING file.
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
# KIND, either express or implied.
#
# SPDX-License-Identifier: curl
#
###########################################################################

# shellcheck disable=SC3040,SC2039
set -eux; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

# build

case "${TARGET:-}" in
  *Win32) openssl_suffix='-Win32';;
  *)      openssl_suffix='-Win64';;
esac

if [ "${APPVEYOR_BUILD_WORKER_IMAGE}" = 'Visual Studio 2022' ]; then
  openssl_root_win="C:/OpenSSL-v34${openssl_suffix}"
elif [ "${APPVEYOR_BUILD_WORKER_IMAGE}" = 'Visual Studio 2019' ]; then
  openssl_root_win="C:/OpenSSL${openssl_suffix}"
else
  openssl_root_win="C:/OpenSSL-v111${openssl_suffix}"
fi
openssl_root="$(cygpath "${openssl_root_win}")"

if [ "${BUILD_SYSTEM}" = 'CMake' ]; then
  # Set env CHKPREFILL to the value '_chkprefill' to compare feature detection
  # results with and without the pre-fill feature. They have to match.
  for _chkprefill in '' ${CHKPREFILL:-}; do
    options=''
    [ "${_chkprefill}" = '_chkprefill' ] && options+=' -D_CURL_PREFILL=OFF'
    [[ "${TARGET}" = *'ARM64'* ]] && SKIP_RUN='ARM64 architecture'
    [ -n "${TOOLSET:-}" ] && options+=" -T ${TOOLSET}"
    [ "${OPENSSL}" = 'ON' ] && options+=" -DOPENSSL_ROOT_DIR=${openssl_root_win}"
    [ -n "${CURLDEBUG:-}" ] && options+=" -DENABLE_CURLDEBUG=${CURLDEBUG}"
    [ "${PRJ_CFG}" = 'Debug' ] && options+=' -DCMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG='
    [ "${PRJ_CFG}" = 'Release' ] && options+=' -DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE='
    [[ "${PRJ_GEN}" = *'Visual Studio'* ]] && options+=' -DCMAKE_VS_GLOBALS=TrackFileAccess=false'
    # shellcheck disable=SC2086
    cmake -B "_bld${_chkprefill}" -G "${PRJ_GEN}" ${TARGET} \
      -DCURL_USE_OPENSSL="${OPENSSL}" \
      -DCURL_USE_SCHANNEL="${SCHANNEL}" \
      -DHTTP_ONLY="${HTTP_ONLY}" \
      -DBUILD_SHARED_LIBS="${SHARED}" \
      -DCMAKE_UNITY_BUILD="${UNITY}" \
      -DCURL_TEST_BUNDLES=ON \
      -DCURL_WERROR=ON \
      -DENABLE_DEBUG="${DEBUG}" \
      -DENABLE_UNICODE="${ENABLE_UNICODE}" \
      -DCMAKE_INSTALL_PREFIX='C:/curl' \
      -DCMAKE_BUILD_TYPE="${PRJ_CFG}" \
      -DCURL_USE_LIBPSL=OFF ${options}
  done
  if [ -d _bld_chkprefill ]; then
    diff -u _bld/lib/curl_config.h _bld_chkprefill/lib/curl_config.h
  fi
  if false; then
    cat _bld/CMakeFiles/CMakeConfigureLog.yaml 2>/dev/null || true
  fi
  echo 'curl_config.h'; grep -F '#define' _bld/lib/curl_config.h | sort || true
  # shellcheck disable=SC2086
  cmake --build _bld --config "${PRJ_CFG}" --parallel 2 -- ${BUILD_OPT:-}
  [ "${SHARED}" = 'ON' ] && PATH="$PWD/_bld/lib:$PATH"
  [ "${OPENSSL}" = 'ON' ] && PATH="${openssl_root}:$PATH"
  curl='_bld/src/curl.exe'
elif [ "${BUILD_SYSTEM}" = 'VisualStudioSolution' ]; then
  (
    cd projects
    ./generate.bat "${VC_VERSION}"
    msbuild.exe -maxcpucount "-property:Configuration=${PRJ_CFG}" "Windows/${VC_VERSION}/curl-all.sln"
  )
  curl="build/Win32/${VC_VERSION}/${PRJ_CFG}/curld.exe"
elif [ "${BUILD_SYSTEM}" = 'winbuild_vs2015' ]; then
  (
    cd winbuild
    cat << EOF > _make.bat
      call "C:/Program Files/Microsoft SDKs/Windows/v7.1/Bin/SetEnv.cmd" /x64
      call "C:/Program Files (x86)/Microsoft Visual Studio 14.0/VC/vcvarsall.bat" x86_amd64
      nmake -f Makefile.vc mode=dll VC=14 "SSL_PATH=${openssl_root_win}" WITH_SSL=dll MACHINE=x64 DEBUG=${DEBUG} ENABLE_UNICODE=${ENABLE_UNICODE} WINBUILD_ACKNOWLEDGE_DEPRECATED=yes
EOF
    ./_make.bat
    rm _make.bat
  )
  curl="builds/libcurl-vc14-x64-${PATHPART}-dll-ssl-dll-ipv6-sspi/bin/curl.exe"
elif [ "${BUILD_SYSTEM}" = 'winbuild_vs2017' ]; then
  (
    cd winbuild
    cat << EOF > _make.bat
      call "C:/Program Files (x86)/Microsoft Visual Studio/2017/Community/VC/Auxiliary/Build/vcvars64.bat"
      nmake -f Makefile.vc mode=dll VC=14.10 "SSL_PATH=${openssl_root_win}" WITH_SSL=dll MACHINE=x64 DEBUG=${DEBUG} ENABLE_UNICODE=${ENABLE_UNICODE} WINBUILD_ACKNOWLEDGE_DEPRECATED=yes
EOF
    ./_make.bat
    rm _make.bat
  )
  curl="builds/libcurl-vc14.10-x64-${PATHPART}-dll-ssl-dll-ipv6-sspi/bin/curl.exe"
fi

find . \( -name '*.exe' -o -name '*.dll' -o -name '*.lib' \) -exec file '{}' \;
if [ -z "${SKIP_RUN:-}" ]; then
  "${curl}" --disable --version
else
  echo "Skip running curl.exe. Reason: ${SKIP_RUN}"
fi

# build tests

if [ "${TFLAGS}" != 'skipall' ] && \
   [ "${BUILD_SYSTEM}" = 'CMake' ]; then
  cmake --build _bld --config "${PRJ_CFG}" --parallel 2 --target testdeps
fi

# run tests

if [ "${TFLAGS}" != 'skipall' ] && \
   [ "${TFLAGS}" != 'skiprun' ]; then
  if [ -x "$(cygpath "${SYSTEMROOT}/System32/curl.exe")" ]; then
    TFLAGS+=" -ac $(cygpath "${SYSTEMROOT}/System32/curl.exe")"
  elif [ -x "$(cygpath 'C:/msys64/usr/bin/curl.exe')" ]; then
    TFLAGS+=" -ac $(cygpath 'C:/msys64/usr/bin/curl.exe')"
  fi
  TFLAGS+=' -j0'
  if [ "${BUILD_SYSTEM}" = 'CMake' ]; then
    cmake --build _bld --config "${PRJ_CFG}" --target test-ci
  else
    (
      TFLAGS="-a -p !flaky -r -rm ${TFLAGS}"
      cd _bld/tests
      ./runtests.pl
    )
  fi
fi

# build examples

if [ "${EXAMPLES}" = 'ON' ] && \
   [ "${BUILD_SYSTEM}" = 'CMake' ]; then
  cmake --build _bld --config "${PRJ_CFG}" --parallel 2 --target curl-examples
fi
