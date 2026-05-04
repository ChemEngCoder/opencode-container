#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ROOTFS="/opt/runtime-rootfs"

declare -A PROCESSED_BINARIES=()
declare -A PROCESSED_PYTHON_INTERPRETERS=()

usage() {
  echo "Usage: $0 [rootfs-destination] <executable> [<executable> ...]" >&2
}

fail_invalid_rootfs_destination() {
  local rootfs="$1"

  echo "Invalid rootfs destination '${rootfs}': must not be empty, '/', '.', '..', '~', or contain ambiguous '.'/'..' path segments." >&2
  exit 1
}

validate_rootfs_destination() {
  local rootfs="$1"
  local normalized_rootfs

  if [ -z "${rootfs}" ]; then
    fail_invalid_rootfs_destination "${rootfs}"
  fi

  case "${rootfs}" in
    /|.|..|~|~/)
      fail_invalid_rootfs_destination "${rootfs}"
      ;;
  esac

  if [[ "${rootfs}" =~ (^|/)\.{1,2}(/|$) ]]; then
    fail_invalid_rootfs_destination "${rootfs}"
  fi

  normalized_rootfs="$(readlink -m -- "${rootfs}" 2>/dev/null || true)"
  if [ -z "${normalized_rootfs}" ] || [ "${normalized_rootfs}" = "/" ]; then
    fail_invalid_rootfs_destination "${rootfs}"
  fi
}

looks_like_rootfs_path() {
  case "$1" in
    */*|.|..|~|./*|../*|~/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

copy_file_with_parents() {
  local source="$1"
  local destination
  local symlink_target=""
  local target_path=""
  local resolved

  destination="${ROOTFS}${source}"
  mkdir -p "$(dirname "${destination}")"

  if [ -L "${source}" ]; then
    cp -a "${source}" "${destination}"
    symlink_target="$(readlink "${source}" 2>/dev/null || true)"
    if [ -n "${symlink_target}" ]; then
      if [[ "${symlink_target}" == /* ]]; then
        target_path="${symlink_target}"
      else
        target_path="$(dirname "${source}")/${symlink_target}"
      fi

      if [ -e "${target_path}" ] || [ -L "${target_path}" ]; then
        copy_file_with_parents "${target_path}"
      fi
    fi

    resolved="$(readlink -f "${source}" 2>/dev/null || true)"
    if [ -n "${resolved}" ] && [ -e "${resolved}" ]; then
      copy_file_with_parents "${resolved}"
    fi
  else
    cp -a "${source}" "${destination}"
  fi
}

copy_path_if_present() {
  local source="$1"
  local destination

  if [ -d "${source}" ]; then
    destination="${ROOTFS}${source}"
    mkdir -p "${destination}"
    cp -a "${source}"/. "${destination}"/
  elif [ -e "${source}" ] || [ -L "${source}" ]; then
    copy_file_with_parents "${source}"
  fi
}

collect_ldd_deps() {
  local binary="$1"
  local line
  local token
  local path_token

  while IFS= read -r line; do
    for token in ${line}; do
      if [[ "${token}" == /* ]]; then
        path_token="${token%%(*}"
        path_token="${path_token%)}"
        if [ -e "${path_token}" ] || [ -L "${path_token}" ]; then
          copy_file_with_parents "${path_token}"
        fi
      fi
    done
  done < <(ldd "${binary}" 2>/dev/null || true)
}

collect_shebang_interpreter_deps() {
  local candidate="$1"
  local first_line
  local shebang
  local interpreter
  local remainder
  local first_arg=""
  local env_arg=""
  local split_string=""
  local split_remainder=""
  local env_command=""
  local env_resolved

  if [ ! -f "${candidate}" ]; then
    return
  fi

  if ! IFS= read -r first_line < "${candidate}"; then
    return
  fi

  first_line="${first_line%$'\r'}"
  if [[ "${first_line}" != '#!'* ]]; then
    return
  fi

  shebang="${first_line#\#!}"
  shebang="${shebang#"${shebang%%[![:space:]]*}"}"
  if [ -z "${shebang}" ]; then
    return
  fi

  interpreter="${shebang%%[[:space:]]*}"
  remainder="${shebang#"${interpreter}"}"
  remainder="${remainder#"${remainder%%[![:space:]]*}"}"
  if [ -n "${remainder}" ]; then
    first_arg="${remainder%%[[:space:]]*}"
  fi

  if [ -e "${interpreter}" ] || [ -L "${interpreter}" ]; then
    process_executable_with_deps "${interpreter}"
  fi

  if [ "${interpreter}" = "/usr/bin/env" ] && [ -n "${remainder}" ]; then
    split_remainder="${remainder}"

    while [ -n "${split_remainder}" ]; do
      env_arg="${split_remainder%%[[:space:]]*}"
      split_remainder="${split_remainder#"${env_arg}"}"
      split_remainder="${split_remainder#"${split_remainder%%[![:space:]]*}"}"

      case "${env_arg}" in
        -S)
          split_string="${split_remainder}"
          ;;
        --split-string)
          split_string="${split_remainder}"
          ;;
        --split-string=*)
          split_string="${env_arg#--split-string=}"
          ;;
        --)
          env_command="${split_remainder%%[[:space:]]*}"
          break
          ;;
        -*)
          continue
          ;;
        *=*)
          continue
          ;;
        *)
          env_command="${env_arg}"
          break
          ;;
      esac

      if [ -n "${split_string}" ]; then
        if [ "${split_string#\"}" != "${split_string}" ]; then
          split_string="${split_string#\"}"
          env_command="${split_string%%\"*}"
        elif [ "${split_string#\'}" != "${split_string}" ]; then
          split_string="${split_string#\'}"
          env_command="${split_string%%\'*}"
        else
          env_command="${split_string%%[[:space:]]*}"
        fi
        break
      fi
    done
  fi

  if [ "${interpreter}" = "/usr/bin/env" ] && [ -n "${env_command}" ] && [[ "${env_command}" != -* ]]; then
    if env_resolved="$(command -v "${env_command}" 2>/dev/null)"; then
      process_executable_with_deps "${env_resolved}"
    fi
  fi
}

is_python_executable_name() {
  case "$1" in
    python|python3|python3.[0-9]*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_node_tooling_executable_name() {
  case "$1" in
    node|nodejs|npm|npx|corepack)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

collect_node_runtime_deps() {
  if [ -e "/bin/sh" ] || [ -L "/bin/sh" ]; then
    process_executable_with_deps "/bin/sh"
  fi

  copy_path_if_present "/usr/bin/npm"
  copy_path_if_present "/usr/bin/npx"
  copy_path_if_present "/usr/bin/corepack"

  copy_path_if_present "/usr/lib/node_modules/npm"
  copy_path_if_present "/usr/share/nodejs/npm"
  copy_path_if_present "/usr/lib/node_modules/corepack"

  if [ -d "/usr/share/nodejs" ] && { [ -d "/usr/share/nodejs/npm" ] || [ ! -d "/usr/lib/node_modules/npm" ]; }; then
    copy_path_if_present "/usr/share/nodejs"
  fi
}

collect_python_runtime_deps() {
  local interpreter_path="$1"
  local resolved_path
  local python_path

  resolved_path="$(readlink -f "${interpreter_path}" 2>/dev/null || true)"
  if [ -z "${resolved_path}" ]; then
    resolved_path="${interpreter_path}"
  fi

  if [ -n "${PROCESSED_PYTHON_INTERPRETERS[${resolved_path}]+x}" ]; then
    return
  fi
  PROCESSED_PYTHON_INTERPRETERS["${resolved_path}"]=1

  while IFS= read -r python_path; do
    [ -n "${python_path}" ] || continue
    copy_path_if_present "${python_path}"
  done < <("${resolved_path}" - <<'PY' 2>/dev/null || true
import os
import site
import sys
import sysconfig

paths = set()

def add_path(value):
    if not value:
        return
    if not isinstance(value, str):
        return
    real = os.path.realpath(value)
    if not os.path.isabs(real):
        return
    if not (real.startswith('/usr/') or real.startswith('/lib/')):
        return
    paths.add(real)

version = sysconfig.get_python_version()
if version:
    add_path(f'/usr/lib/python{version}')

sysconfig_paths = sysconfig.get_paths() or {}
for key in ('stdlib', 'platstdlib', 'purelib', 'platlib'):
    add_path(sysconfig_paths.get(key))

stdlib = sysconfig_paths.get('stdlib')
if stdlib:
    add_path(os.path.join(stdlib, 'lib-dynload'))

for key in ('LIBDEST', 'DESTSHARED', 'LIBPL'):
    add_path(sysconfig.get_config_var(key))

for entry in sys.path:
    if isinstance(entry, str) and ('site-packages' in entry or 'dist-packages' in entry):
        add_path(entry)

for getter in ('getsitepackages',):
    func = getattr(site, getter, None)
    if callable(func):
        try:
            for entry in func():
                add_path(entry)
        except Exception:
            pass

for path in sorted(paths):
    print(path)
PY
)
}

process_executable_with_deps() {
  local executable_path="$1"
  local resolved_path
  local resolved_name

  resolved_path="$(readlink -f "${executable_path}" 2>/dev/null || true)"
  if [ -z "${resolved_path}" ]; then
    resolved_path="${executable_path}"
  fi

  if [ -n "${PROCESSED_BINARIES[${resolved_path}]+x}" ]; then
    return
  fi
  PROCESSED_BINARIES["${resolved_path}"]=1

  copy_file_with_parents "${executable_path}"
  collect_ldd_deps "${executable_path}"
  collect_shebang_interpreter_deps "${executable_path}"

  resolved_name="$(basename "${resolved_path}")"
  if is_python_executable_name "${resolved_name}"; then
    collect_python_runtime_deps "${resolved_path}"
  fi
}

ROOTFS="${DEFAULT_ROOTFS}"

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

if [ "$#" -eq 1 ] && looks_like_rootfs_path "$1"; then
  usage
  exit 1
fi

if [ "$#" -ge 2 ] && looks_like_rootfs_path "$1"; then
  ROOTFS="$1"
  shift
fi

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

validate_rootfs_destination "${ROOTFS}"

declare -a EXECUTABLE_PATHS=()
NODE_TOOLING_REQUESTED=0

for executable_name in "$@"; do
  if ! executable_path="$(command -v "${executable_name}")"; then
    echo "Executable not found in PATH: ${executable_name}" >&2
    exit 1
  fi

  EXECUTABLE_PATHS+=("${executable_path}")

  if is_node_tooling_executable_name "${executable_name}" || is_node_tooling_executable_name "$(basename "${executable_path}")"; then
    NODE_TOOLING_REQUESTED=1
  fi
done

mkdir -p "${ROOTFS}"

for executable_path in "${EXECUTABLE_PATHS[@]}"; do
  process_executable_with_deps "${executable_path}"
done

copy_path_if_present "/etc/ssl/certs"
copy_path_if_present "/etc/passwd"
copy_path_if_present "/etc/group"
copy_path_if_present "/etc/ld.so.cache"
copy_path_if_present "/etc/ld.so.conf"
copy_path_if_present "/etc/ld.so.conf.d"
copy_path_if_present "/usr/share/python-wheels"
copy_path_if_present "/usr/share/zoneinfo"

if [ "${NODE_TOOLING_REQUESTED}" -eq 1 ]; then
  collect_node_runtime_deps
fi
